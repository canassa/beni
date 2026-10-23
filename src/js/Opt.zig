//! `backend.md` §9's release optimiser, **item 1**: local dead bindings, and
//! the single use that follows them. One pass over `JsIr`, per function body,
//! between `Lower.lower` and `Print.print` and under `--release` only.
//!
//! `Reach` decided which declarations exist; this decides what is left inside
//! one. Two rules, one walk:
//!
//!   - **Zero uses: the binding goes WHOLE**, initialiser included — unless
//!     lowering listed it in `keep`. `language.md` §6's *What an optimiser
//!     may assume* is the licence: a binding nothing reads may be dropped
//!     whole when evaluating it has no effect. Since 2026-09-30 that is
//!     asked of the checker, not guessed: `Lower` lists every binding whose
//!     right-hand side reaches a call the checker answered `impure` (or
//!     `suspends`, which implies it) — `Debug.log` among them — and this pass
//!     asks nothing more about any right-hand side. A call of a `foreign
//!     pure` is still droppable, so `Node.done` pins nothing; the
//!     alternative, a "does the initialiser call a `foreign`?" test, is the
//!     `sideEffects: false` guesswork §9's purity paragraph exists to replace.
//!   - **Exactly one use: the binding is inlined**, under §9's five
//!     conditions, which `inlinable` and `findUse` below implement one for
//!     one. The wider licence — any initialiser, use on the very next
//!     statement — was measured and loses on `Dictionaries` (§9, table C).
//!     A value made only of beni field reads, names and literals
//!     (`pureValue`, §9 item 1 as amended 2026-10-18) moves to its use past
//!     statements that may write nothing: a field read does nothing, but a
//!     write of its record would change it (the ordering rule).
//!
//! **Nothing here mutates the IR.** The pass produces a `Plan`: a bitset of
//! statement nodes the printer must not print, and one replacement node per
//! `ident` NODE the printer substitutes. Two flat arrays, no allocation per
//! node, and dev output is the plan being empty rather than a second code
//! path.
//!
//! **Why substitution at print time needs no fixpoint and no backward pass.**
//! §9 reaches the same conclusion by rewriting backwards; resolving through
//! the plan when the printer reaches an `ident` gets there for free, because a
//! chain — `const x = p.a; const y = x.b; return f(y);` — collapses as the
//! printer follows `y` to `x.b` and then `x` to `p.a`. The chain is acyclic by
//! construction (a binding is inlined only into a LATER statement), and it
//! is COMPRESSED as it is recorded (`compress`): for `const x = p;
//! const y = x; f(y)` the use of `y` records `p` directly and not the `x`
//! that `y`'s initialiser reads, so the printer follows exactly one step per
//! `ident` whatever the chain's length. It used to follow up to 64
//! and then print a dropped binding's name — a budget whose exhaustion was a
//! wrong program, which no budget in this pass or the printer may be: each
//! either finishes or declines the optimisation.
//!
//! **Determinism** (CLAUDE.md rule 5): the pass reads only `JsIr`, visits the
//! module body in emission order and every statement list inside it in
//! emission order, iterates no map, and shares no counter. Its output is a
//! function of the input IR.

const std = @import("std");
const Allocator = std.mem.Allocator;
const JsIr = @import("JsIr.zig");

const Node = JsIr.Node;
const Index = Node.Index;
const NameIndex = JsIr.NameIndex;

/// What the printer does differently. Both halves are empty for a dev build,
/// which is how `--release` costs development output exactly nothing.
pub const Plan = struct {
    /// One bit per node index: a `const_decl` or `let_decl` the printer skips.
    dropped: []const u32 = &.{},
    /// One slot per NODE index: for the `ident` that is a binding's single
    /// use, the node whose value takes its place.
    ///
    /// **Keyed by the use site and not by the name**, and that is not a
    /// detail. A local's `NameIndex` is shared across the whole module —
    /// `localName`'s disambiguator restarts at every top-level declaration —
    /// so `n$2` is one name in `firstWins` and in `laterWins` both. A
    /// name-keyed table lets the second declaration's substitution overwrite
    /// the first's, and the printer then folds `xs$1.a` into the branch that
    /// wanted `xs$1.b.a`: a silently wrong answer, which
    /// `run/MatchRowOrder.beni` catches and which is the reason this array is
    /// as long as `nodes` rather than as long as `names`.
    inlined: []const Node.OptionalIndex = &.{},
    /// One bit per NODE: a declaration statement whose name is bound more
    /// than once in its own top-level declaration (the compiler's
    /// positional names can repeat). A statement list that holds none of
    /// these may be printed as part of the list around it — the printer's
    /// `else` that follows an arm that jumps — since no name in it can then
    /// come to mean another. Keyed by the statement, not by the name: one
    /// `NameIndex` is shared by every declaration that holds that name.
    repeated: []const u32 = &.{},

    /// The plan a development build runs under: nothing dropped, nothing
    /// substituted.
    pub const none: Plan = .{};

    /// Whether declaration statement `node` binds a name its top-level
    /// declaration binds more than once; true for anything the plan does
    /// not cover, which is the safe answer.
    pub fn isRepeated(p: *const Plan, node: Index) bool {
        const i = node.int();
        const word = i / 32;
        if (word >= p.repeated.len) return true;
        return p.repeated[word] & (@as(u32, 1) << @intCast(i % 32)) != 0;
    }

    pub fn isDropped(p: *const Plan, node: Index) bool {
        const i = node.int();
        const word = i / 32;
        if (word >= p.dropped.len) return false;
        return p.dropped[word] & (@as(u32, 1) << @intCast(i % 32)) != 0;
    }

    pub fn replacement(p: *const Plan, node: Index) ?Index {
        const i = node.int();
        if (i >= p.inlined.len) return null;
        return p.inlined[i].unwrap();
    }
};

/// How far the forward scan for the single use will look before giving up.
///
/// The scan stops on its own at the first statement that is neither a
/// pure-read `const` nor the use, so in the output this slice is written for
/// it runs to a handful: §7's leaf prologue and §8's loop prologue are the
/// runs it exists for. The cap is here so that the pass is linear in a body
/// with a hundred adjacent `const`s rather than quadratic — §9's throughput
/// paragraph says what would breach the budget is "a sort per function or a
/// fixpoint", and an unbounded quadratic scan is the third thing on that list.
const scan_limit: usize = 64;

/// Plan `ir`. Everything returned is allocated from `arena` and lives as long
/// as the printing of this module.
///
/// **One top-level declaration at a time**, which is what §9 item 1's "per
/// function body" means and what makes the counting arrays correct.
/// `localName` gives every local of ONE declaration a distinct disambiguator
/// (`src/js/Lower.zig:1255-1271`) and restarts for the next one, so `a$2` of
/// `sum` and `a$2` of `square` are the same `NameIndex` — a module-wide count
/// would see two declarations and four reads where there is one and two, and
/// would decline every fold in the module. The counters are therefore reset
/// per declaration, by a stamp rather than a `@memset`, so the reset is O(1)
/// and the pass stays linear in the module.
pub fn run(arena: Allocator, ir: *const JsIr) Allocator.Error!Plan {
    return runKeeping(arena, ir, &.{}, &.{}, &.{});
}

/// `run`, keeping the bindings `keep` names whatever their uses: each is a
/// `let` whose right-hand side may be impure or may suspend, evaluated for
/// its effect whether or not anything reads it (`backend.md` §9 item 1, as
/// amended 2026-09-30). `discarded` are the statements of a `let _ = e` whose
/// `e` cannot have an effect, which `Lower` wrote as statements with no
/// binding (`backend.md` §4, *A discarded value is a statement*): dropped
/// whole, as their `const` was when there was one. `mutable` are the names
/// of `Js.Ref`s written as a `let` (`Lower.Result.mutable`): a write in
/// another declaration may rebind one, so no binding whose initialiser reads
/// one is folded into a later statement.
pub fn runKeeping(arena: Allocator, ir: *const JsIr, keep: []const Index, discarded: []const Index, mutable: []const NameIndex) Allocator.Error!Plan {
    if (ir.nodes.len == 0) return .none;

    const kept = try arena.alloc(u32, (ir.nodes.len + 31) / 32);
    @memset(kept, 0);
    for (keep) |node| {
        const i = node.int();
        if (i < ir.nodes.len) kept[i / 32] |= @as(u32, 1) << @intCast(i % 32);
    }

    var o: Opt = .{
        .kept = kept,
        .ir = ir,
        .arena = arena,
        .uses = try arena.alloc(u32, ir.names.len),
        .use_at = try arena.alloc(Opt.Use, ir.names.len),
        .decls = try arena.alloc(u32, ir.names.len),
        .binds = try arena.alloc(u32, ir.names.len),
        .assigned = try arena.alloc(bool, ir.names.len),
        .rebound = try arena.alloc(bool, ir.names.len),
        .stamp = try arena.alloc(u32, ir.names.len),
        .dropped = try arena.alloc(u32, (ir.nodes.len + 31) / 32),
        .inlined = try arena.alloc(Node.OptionalIndex, ir.nodes.len),
        .repeated = try arena.alloc(u32, (ir.nodes.len + 31) / 32),
        .mutable = mutable,
    };
    @memset(o.stamp, 0);
    @memset(o.repeated, 0);
    @memset(o.dropped, 0);
    @memset(o.inlined, .none);
    // A statement that runs a store of a record update written in place
    // is the update, never an unused pure value (`ownership-checker.md`
    // §31.10, *The optimiser barrier*).
    for (discarded) |node| if (node.int() < ir.nodes.len and !try ir.holdsStore(arena, &o.stack, node)) o.drop(node);

    for (ir.extraSlice(ir.body, Index)) |top| {
        o.current += 1;
        o.binders.clearRetainingCapacity();
        try o.countStmt(top);
        for (o.binders.items) |stmt| {
            const i = @as(NameIndex, @fromBackingInt(@intCast(ir.data(stmt).lhs))).unwrap() orelse continue;
            if (i < o.binds.len and o.readOf(i, "binds") > 1) o.repeated[stmt.int() / 32] |= @as(u32, 1) << @intCast(stmt.int() % 32);
        }
        try o.planStmt(top);
    }
    return .{ .dropped = o.dropped, .inlined = o.inlined, .repeated = o.repeated };
}

const Opt = struct {
    ir: *const JsIr,
    /// One bit per node: a binding never dropped for want of a use
    /// (`runKeeping`). A bitset rather than the list, because a module may
    /// hold one per effectful `let`.
    kept: []const u32,
    /// Where `stack` grows. The plan's own arena: nothing here is freed early.
    arena: Allocator,
    /// The explicit stack every expression walk shares: each walk
    /// owns the entries above the length it found, so the walks nest.
    stack: std.ArrayList(Index) = .empty,
    /// Which top-level declaration `uses`, `decls` and `assigned` describe.
    /// Starts at 1 so that a zeroed `stamp` means "not yet touched".
    current: u32 = 0,
    /// Whose counts each slot holds. A slot from an earlier declaration reads
    /// as zero and is reset on first touch.
    stamp: []u32,
    /// Reads of each name, within the declaration being planned. **An
    /// over-count is safe and an under-count is not**, which is why a
    /// parameter counts as a read and an assignment target counts as one too.
    uses: []u32,
    /// The last expression read of each name, recorded by the counting walk.
    /// With exactly one read this is its use, including the list and statement
    /// that evaluate it; no forward search or distance limit is needed.
    use_at: []Use,
    use_list: u32 = std.math.maxInt(u32),
    use_stmt: u32 = 0,
    /// How many `const_decl`/`let_decl`/`func_decl` introduce each name in
    /// this declaration. A name introduced twice is never inlined: the single
    /// use the scan finds would then be one of two bindings' uses, and the
    /// compiler-made names that are positional rather than counted —
    /// `$in$<i>`, `$m$k`, `$j$<d>$<b>` — can repeat inside one declaration.
    decls: []u32,
    /// Declarations and parameters of each name in this declaration: what
    /// `repeated` is decided on.
    binds: []u32,
    /// Whether any `assign_stmt` in this declaration targets the name. §8
    /// reassigns an `$in$<i>` slot per iteration, so a read of one is not a
    /// stable read and a chain rooted at one may not move.
    assigned: []bool,
    /// Whether an `assign_stmt` in this declaration targets the name
    /// itself — `x = v`, not `x.p = v`: what `copy` asks, since writing a
    /// property of a binding's object leaves the binding the same name.
    rebound: []bool,
    dropped: []u32,
    inlined: []Node.OptionalIndex,
    /// `Plan.repeated`.
    repeated: []u32,
    /// The declaration statements of the top-level declaration being
    /// counted, whose `repeated` bit is decided once its count is whole.
    binders: std.ArrayList(Index) = .empty,
    /// `runKeeping`'s `mutable`: bases no fold may rest on.
    mutable: []const NameIndex = &.{},
    /// The `ident` node `exprUses` last matched, which `findUse` reads back
    /// as the use site. One slot rather than a returned pair, because the
    /// count and the node are wanted at different depths of the same walk.
    found: Node.OptionalIndex = .none,
    /// The statement `findUse` found its use in.
    found_in: Index = undefined,
    /// Whether the value `pureValue` last accepted reads a field.
    reads_field: bool = false,
    /// `copy`'s use sites, found by `ownUsesInto`.
    found_all: std.ArrayList(Index) = .empty,

    const Use = struct {
        list: u32 = std.math.maxInt(u32),
        stmt: u32 = 0,
        node: Node.OptionalIndex = .none,
    };

    // ---- The counting walk ------------------------------------------------

    /// Reset a slot the first time this declaration touches it.
    fn touch(o: *Opt, i: u32) void {
        if (o.stamp[i] == o.current) return;
        o.stamp[i] = o.current;
        o.uses[i] = 0;
        o.decls[i] = 0;
        o.binds[i] = 0;
        o.assigned[i] = false;
        o.rebound[i] = false;
    }

    fn use(o: *Opt, n: NameIndex) void {
        const i = n.unwrap() orelse return;
        if (i >= o.uses.len) return;
        o.touch(i);
        o.uses[i] += 1;
        o.use_at[i] = .{};
    }

    fn declare(o: *Opt, n: NameIndex) void {
        const i = n.unwrap() orelse return;
        if (i >= o.decls.len) return;
        o.touch(i);
        o.decls[i] += 1;
        o.bind(i);
    }

    /// One more binding of name `i`, a declaration or a parameter.
    fn bind(o: *Opt, i: u32) void {
        o.binds[i] += 1;
    }

    fn readOf(o: *Opt, i: u32, comptime field: []const u8) u32 {
        if (o.stamp[i] != o.current) return 0;
        return @field(o, field)[i];
    }

    /// One walk of a top-level declaration's statements. Every name-carrying
    /// slot is either a DECLARATION (the name slot of a declaration
    /// statement), a PROPERTY (a `member`'s key, a `property`'s key, the
    /// `imported` half of a sibling specifier — none of which is a binding at
    /// all) or a use. An `assign_stmt`'s target is an `ident` and is therefore
    /// counted as a use too, which is exactly right: it is what keeps §7's
    /// `let $t$n;` above an `if`/`else` chain from being dropped out from
    /// under the assignments that fill it.
    fn countStmt(o: *Opt, stmt: Index) Allocator.Error!void {
        const d = o.ir.data(stmt);
        switch (o.ir.tag(stmt)) {
            .import_stmt => {
                const imp = o.ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Import);
                for (o.ir.extraSlice(imp.specs(), JsIr.Specifier)) |spec| o.declare(spec.local);
            },
            .export_stmt => for (o.ir.extraSlice(JsIr.inlineRange(d), NameIndex)) |n| o.use(n),
            .const_decl => {
                try o.binders.append(o.arena, stmt);
                o.declare(@fromBackingInt(@intCast(d.lhs)));
                try o.countExpr(@fromBackingInt(@intCast(d.rhs)));
            },
            .let_decl => {
                try o.binders.append(o.arena, stmt);
                o.declare(@fromBackingInt(@intCast(d.lhs)));
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| try o.countExpr(v);
            },
            .func_decl, .gen_decl => {
                try o.binders.append(o.arena, stmt);
                o.declare(@fromBackingInt(@intCast(d.lhs)));
                try o.countFunc(@fromBackingInt(@intCast(d.rhs)));
            },
            .assign_stmt => {
                o.markAssigned(@fromBackingInt(@intCast(d.lhs)));
                if (o.ir.tag(@fromBackingInt(@intCast(d.lhs))) == .ident) if (@as(NameIndex, @fromBackingInt(@intCast(o.ir.data(@fromBackingInt(@intCast(d.lhs))).lhs))).unwrap()) |i| if (i < o.rebound.len) {
                    o.touch(i);
                    o.rebound[i] = true;
                };
                try o.countExpr(@fromBackingInt(@intCast(d.lhs)));
                try o.countExpr(@fromBackingInt(@intCast(d.rhs)));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try o.countExpr(v),
            .if_stmt => {
                try o.countExpr(@fromBackingInt(@intCast(d.lhs)));
                const branches = o.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                try o.countStmts(branches.thenBody());
                try o.countStmts(branches.elseBody());
            },
            // A label shares the binding namespace (§9 item 2), so a name a
            // label holds is not a name a binding may be dropped under.
            .while_true, .block_stmt => {
                o.use(@fromBackingInt(@intCast(d.lhs)));
                try o.countStmts(o.ir.subRange(@fromBackingInt(@intCast(d.rhs))));
            },
            .break_stmt, .continue_stmt => o.use(@fromBackingInt(@intCast(d.lhs))),
            // The loop variable is bound per iteration, like a parameter.
            .for_of => {
                const n: NameIndex = @fromBackingInt(@intCast(d.lhs));
                o.use(n);
                if (n.unwrap()) |i| if (i < o.binds.len) o.bind(i);
                const f = o.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                // The iterable is in the loop binding's scope when printed
                // (ownUses), so it is never an indexed substitution site.
                const old_list = o.use_list;
                o.use_list = std.math.maxInt(u32);
                try o.countExpr(f.iterable);
                o.use_list = old_list;
                try o.countStmts(f.body());
            },
            .switch_stmt => {
                try o.countExpr(@fromBackingInt(@intCast(d.lhs)));
                for (o.ir.extraSlice(o.ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |c| try o.countStmt(c);
            },
            .switch_case => {
                const old_list = o.use_list;
                defer o.use_list = old_list;
                o.use_list = std.math.maxInt(u32);
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| try o.countExpr(t);
                try o.countStmts(o.ir.subRange(@fromBackingInt(@intCast(d.rhs))));
            },
            .expr_stmt, .throw_stmt => try o.countExpr(@fromBackingInt(@intCast(d.lhs))),
            .try_stmt => {
                const t = o.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                try o.countStmts(t.body());
                try o.countStmts(t.finalBody());
                try o.countStmts(t.catchBody());
            },
            else => {},
        }
    }

    fn countStmts(o: *Opt, range: JsIr.SubRange) Allocator.Error!void {
        const old_list = o.use_list;
        const old_stmt = o.use_stmt;
        defer {
            o.use_list = old_list;
            o.use_stmt = old_stmt;
        }
        o.use_list = @backingInt(range.start);
        for (o.ir.extraSlice(range, Index), 0..) |stmt, i| {
            o.use_stmt = @intCast(i);
            try o.countStmt(stmt);
        }
    }

    /// Mark the root of an assignment target. `a.b = c` mutates `a`'s object
    /// and not `a`, but a chain rooted at `a` is refused either way: the
    /// cheaper rule is the one nobody has to reason about at a call site.
    ///
    /// No budget: running out of one here would leave the
    /// root unmarked — "not assigned", the unsafe answer — so the walk goes
    /// to the root of the chain. It is linear in the chain and the IR is a
    /// tree, so it ends.
    fn markAssigned(o: *Opt, target: Index) void {
        var node = target;
        while (true) {
            const d = o.ir.data(node);
            switch (o.ir.tag(node)) {
                .ident => {
                    const i = @as(NameIndex, @fromBackingInt(@intCast(d.lhs))).unwrap() orelse return;
                    if (i >= o.assigned.len) return;
                    o.touch(i);
                    o.assigned[i] = true;
                    return;
                },
                .member, .index_get => node = @fromBackingInt(@intCast(d.lhs)),
                else => return,
            }
        }
    }

    fn countFunc(o: *Opt, record: JsIr.ExtraIndex) Allocator.Error!void {
        const f = o.ir.extraData(record, JsIr.Func);
        // A parameter is counted as a READ, not as a declaration. It shadows
        // rather than binds anything this pass may touch, and counting it as
        // a read is the conservative half of the two.
        for (o.ir.extraSlice(f.params(), NameIndex)) |n| {
            o.use(n);
            const i = n.unwrap() orelse continue;
            if (i < o.binds.len) o.bind(i);
        }
        try o.countStmts(f.body());
    }

    /// Iterative, over `stack` (`JsIr.pushOperands`): an expression
    /// is as deep as the longest chain the compiler built.
    fn countExpr(o: *Opt, root: Index) Allocator.Error!void {
        const base = o.stack.items.len;
        defer o.stack.shrinkRetainingCapacity(base);
        try o.stack.append(o.arena, root);
        while (o.stack.items.len > base) {
            const node = JsIr.popOperand(&o.stack).?;
            switch (o.ir.tag(node)) {
                .ident => {
                    const n: NameIndex = @fromBackingInt(@intCast(o.ir.data(node).lhs));
                    o.use(n);
                    if (n.unwrap()) |i| if (i < o.use_at.len) {
                        o.use_at[i] = .{ .list = o.use_list, .stmt = o.use_stmt, .node = node.toOptional() };
                    };
                },
                .arrow => try o.countFunc(@fromBackingInt(@intCast(o.ir.data(node).lhs))),
                // A store of an in-place update (`JsIr.Node.Tag.assign`): its
                // target's root is marked as an `assign_stmt`'s is, so no
                // chain rooted there moves.
                .assign => {
                    o.markAssigned(@fromBackingInt(@intCast(o.ir.data(node).lhs)));
                    try o.ir.pushOperands(o.arena, &o.stack, node);
                },
                else => try o.ir.pushOperands(o.arena, &o.stack, node),
            }
        }
    }

    /// Every statement list BELOW one top-level declaration, in emission
    /// order. The module body itself is never a list here: its bindings are
    /// top-level declarations, `Reach` owns what those ship (§9), another
    /// file reads them through an `import`, and "per function body" is what
    /// §9 item 1 says. A name that carries a module qualifier is refused a
    /// second time in `list`, so the exclusion holds either way.
    fn planStmt(o: *Opt, stmt: Index) Allocator.Error!void {
        const d = o.ir.data(stmt);
        switch (o.ir.tag(stmt)) {
            .const_decl => try o.planExpr(@fromBackingInt(@intCast(d.rhs))),
            .let_decl => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| try o.planExpr(v),
            .func_decl, .gen_decl => try o.planFunc(@fromBackingInt(@intCast(d.rhs))),
            .assign_stmt => {
                try o.planExpr(@fromBackingInt(@intCast(d.lhs)));
                try o.planExpr(@fromBackingInt(@intCast(d.rhs)));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try o.planExpr(v),
            .if_stmt => {
                try o.planExpr(@fromBackingInt(@intCast(d.lhs)));
                const branches = o.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                try o.planList(branches.thenBody());
                try o.planList(branches.elseBody());
            },
            .while_true, .block_stmt => try o.planList(o.ir.subRange(@fromBackingInt(@intCast(d.rhs)))),
            .for_of => {
                const f = o.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                try o.planExpr(f.iterable);
                try o.planList(f.body());
            },
            .switch_stmt => {
                try o.planExpr(@fromBackingInt(@intCast(d.lhs)));
                for (o.ir.extraSlice(o.ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |c| try o.planStmt(c);
            },
            .switch_case => try o.planList(o.ir.subRange(@fromBackingInt(@intCast(d.rhs)))),
            .expr_stmt, .throw_stmt => try o.planExpr(@fromBackingInt(@intCast(d.lhs))),
            // Each block is a list of its own, planned as one: `findUse`
            // never leaves a list and stops at the `try` itself, which
            // evaluates nothing of its own, so no binding moves across
            // the boundary in either direction — into the guarded block,
            // where a throw would now run the cleanup, or out of it.
            .try_stmt => {
                const t = o.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                try o.planList(t.body());
                try o.planList(t.finalBody());
                try o.planList(t.catchBody());
            },
            else => {},
        }
    }

    fn planList(o: *Opt, range: JsIr.SubRange) Allocator.Error!void {
        try o.list(range);
        for (o.ir.extraSlice(range, Index)) |s| try o.planStmt(s);
    }

    fn planFunc(o: *Opt, record: JsIr.ExtraIndex) Allocator.Error!void {
        try o.planList(o.ir.extraData(record, JsIr.Func).body());
    }

    /// Find the `arrow`s an expression holds; their bodies are statement
    /// lists like any other. Iterative, like `countExpr`.
    fn planExpr(o: *Opt, root: Index) Allocator.Error!void {
        const base = o.stack.items.len;
        defer o.stack.shrinkRetainingCapacity(base);
        try o.stack.append(o.arena, root);
        while (o.stack.items.len > base) {
            const node = JsIr.popOperand(&o.stack).?;
            switch (o.ir.tag(node)) {
                .arrow => try o.planFunc(@fromBackingInt(@intCast(o.ir.data(node).lhs))),
                else => try o.ir.pushOperands(o.arena, &o.stack, node),
            }
        }
    }

    fn list(o: *Opt, range: JsIr.SubRange) Allocator.Error!void {
        const stmts = o.ir.extraSlice(range, Index);
        for (stmts, 0..) |stmt, i| {
            const t = o.ir.tag(stmt);
            if (t != .const_decl and t != .let_decl) continue;
            const d = o.ir.data(stmt);
            const n: NameIndex = @fromBackingInt(@intCast(d.lhs));
            const idx = n.unwrap() orelse continue;
            if (idx >= o.uses.len) continue;
            // A qualified name crosses a file (§9 item 2's first namespace);
            // nothing local may be concluded about it here.
            if (o.ir.name(n).module != .none) continue;

            if (o.readOf(idx, "uses") == 0) {
                const at = stmt.int();
                if (o.kept[at / 32] & (@as(u32, 1) << @intCast(at % 32)) == 0 and !try o.ir.holdsStore(o.arena, &o.stack, stmt)) o.drop(stmt);
                continue;
            }
            if (try o.copy(stmts[i + 1 ..], stmt, n, idx)) continue;
            if (t != .const_decl) continue;
            if (o.readOf(idx, "uses") != 1 or o.readOf(idx, "decls") != 1) continue;
            const value: Index = @fromBackingInt(@intCast(d.rhs));
            // A function made once and used once: made where it is used
            // (`backend.md` §9 item 1, amended 2026-10-17). Making one does
            // nothing and reads nothing until it is called, so it moves past
            // any statement; the use is in a later statement's own
            // expressions, so it is still made once.
            if (o.ir.tag(value) == .arrow) {
                if (o.findAnyUse(range, i, n)) |at| {
                    o.drop(stmt);
                    o.inlined[at.int()] = value.toOptional();
                }
                continue;
            }
            // A property read that may have an effect — a `Js.get` of a
            // property some call may write — is evaluated where it stands:
            // folded into its use it would move past whatever that use's
            // statement evaluates first. A name or a literal cannot change.
            const here = stmt.int();
            const listed = o.kept[here / 32] & (@as(u32, 1) << @intCast(here % 32)) != 0;
            if (listed and o.ir.tag(value) == .member) continue;
            // A value made only of beni field reads, names and literals
            // (`backend.md` §9 item 1, amended 2026-10-18). It does nothing
            // and cannot throw, but a write of the record it reads would
            // change its answer, so it moves only past statements that
            // can write nothing (`findUseAcross`). One that reads no field
            // — a literal, a name nothing reassigns — answers the same
            // anywhere, and moves past any statement.
            // A name: the object it holds is the same object wherever it is
            // read, whatever writes a property of it (a record written in
            // place, `ownership-checker.md` §31.10), so only a rebinding of
            // the name — `rebound`, not `assigned` — keeps it where it is.
            // A name an earlier fold wrote a value at is that value, which the
            // rules below judge.
            if (!listed and o.ir.tag(value) == .ident and o.inlined[value.int()] == .none) bare: {
                const vn: NameIndex = @fromBackingInt(@intCast(o.ir.data(value).lhs));
                const vi = vn.unwrap() orelse break :bare;
                if (vi >= o.rebound.len or (o.stamp[vi] == o.current and o.rebound[vi])) break :bare;
                if (o.ir.name(vn).module != .none or o.readOf(vi, "binds") != 1) break :bare;
                if (std.mem.indexOfScalar(NameIndex, o.mutable, vn) != null) break :bare;
                if (o.findAnyUse(range, i, n)) |at| {
                    o.drop(stmt);
                    o.inlined[at.int()] = o.compress(value).toOptional();
                }
                continue;
            }
            if (!listed) {
                o.reads_field = false;
                if (o.pureValue(value, 0) != null) {
                    const found = if (o.reads_field) try o.findUseAcross(stmts[i + 1 ..], n) else o.findAnyUse(range, i, n);
                    if (found) |at| {
                        o.drop(stmt);
                        o.inlined[at.int()] = o.compress(value).toOptional();
                    }
                    continue;
                }
            }
            const base = o.chainBase(value) orelse continue;
            if (base.unwrap()) |b| {
                if (b < o.assigned.len and o.stamp[b] == o.current and o.assigned[b]) continue;
                if (std.mem.indexOfScalar(NameIndex, o.mutable, base) != null) continue;
            }
            const at = try o.findUse(stmts[i + 1 ..], n) orelse continue;
            // A member chain is a read some call may change: in its use's
            // statement nothing that may write is evaluated before it.
            const target = o.compress(value);
            if (o.ir.tag(target) == .member and !o.cleanBefore(o.found_in, at)) continue;
            o.drop(stmt);
            o.inlined[at.int()] = target.toOptional();
        }
    }

    /// **A copy of a name** (`backend.md` §9 item 1, amended 2026-10-02):
    /// `const f = e` (or a `let` nothing assigns) read more than once,
    /// whose initialiser is — after `compress` — a local `e` bound once in
    /// the declaration and assigned nowhere, is `e` at every use, when every
    /// use is in the own expressions of the statements after it in its list
    /// (`ownUses`: none in a branch, a loop body or a function, where
    /// another binding could come to be spelt as `e`). `e` holds one value
    /// from its binding on and is in scope wherever `f` is, so each use
    /// reads what it read. True when the binding is planned away.
    fn copy(o: *Opt, rest: []const Index, stmt: Index, n: NameIndex, idx: u32) Allocator.Error!bool {
        const t = o.ir.tag(stmt);
        const uses = o.readOf(idx, "uses");
        if (uses < 2 or o.readOf(idx, "binds") != 1 or o.stamp[idx] != o.current or o.rebound[idx]) return false;
        const at = stmt.int();
        if (o.kept[at / 32] & (@as(u32, 1) << @intCast(at % 32)) != 0) return false;
        const init: Index = switch (t) {
            .const_decl => @fromBackingInt(@intCast(o.ir.data(stmt).rhs)),
            .let_decl => @as(Node.OptionalIndex, @fromBackingInt(@intCast(o.ir.data(stmt).rhs))).unwrap() orelse return false,
            else => return false,
        };
        const value = o.compress(init);
        if (o.ir.tag(value) != .ident) return false;
        const e: NameIndex = @fromBackingInt(@intCast(o.ir.data(value).lhs));
        const ei = e.unwrap() orelse return false;
        if (ei >= o.binds.len or o.ir.name(e).module != .none) return false;
        if (o.readOf(ei, "binds") != 1 or (o.stamp[ei] == o.current and o.rebound[ei])) return false;
        if (std.mem.indexOfScalar(NameIndex, o.mutable, e) != null) return false;
        const base = o.found_all.items.len;
        defer o.found_all.shrinkRetainingCapacity(base);
        for (rest) |later| {
            if (o.found_all.items.len - base >= uses) break;
            try o.ownUsesInto(later, n);
        }
        if (o.found_all.items.len - base != uses) return false;
        o.drop(stmt);
        for (o.found_all.items[base..]) |use_site| o.inlined[use_site.int()] = value.toOptional();
        return true;
    }

    /// `ownUses`, every `ident` of `n` found appended to `found_all`.
    fn ownUsesInto(o: *Opt, stmt: Index, n: NameIndex) Allocator.Error!void {
        const d = o.ir.data(stmt);
        switch (o.ir.tag(stmt)) {
            .const_decl => try o.exprUsesInto(@fromBackingInt(@intCast(d.rhs)), n),
            .let_decl => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| try o.exprUsesInto(v, n),
            .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try o.exprUsesInto(v, n),
            .assign_stmt => {
                try o.exprUsesInto(@fromBackingInt(@intCast(d.lhs)), n);
                try o.exprUsesInto(@fromBackingInt(@intCast(d.rhs)), n);
            },
            .if_stmt, .switch_stmt => try o.exprUsesInto(@fromBackingInt(@intCast(d.lhs)), n),
            // Never into a loop's head (`ownUses`): none is recorded, so a
            // copy with a use there is declined.
            .for_of => {},
            .expr_stmt, .throw_stmt => try o.exprUsesInto(@fromBackingInt(@intCast(d.lhs)), n),
            else => {},
        }
    }

    fn exprUsesInto(o: *Opt, root: Index, n: NameIndex) Allocator.Error!void {
        const base = o.stack.items.len;
        defer o.stack.shrinkRetainingCapacity(base);
        try o.stack.append(o.arena, root);
        while (o.stack.items.len > base) {
            const node = JsIr.popOperand(&o.stack).?;
            switch (o.ir.tag(node)) {
                .ident => if (@as(NameIndex, @fromBackingInt(@intCast(o.ir.data(node).lhs))) == n) try o.found_all.append(o.arena, node),
                .arrow => {},
                else => try o.ir.pushOperands(o.arena, &o.stack, node),
            }
        }
    }

    /// The node a substitution records: `value` itself, or — when `value` is
    /// an `ident` that is already some earlier binding's single use — what
    /// THAT substitution records. **Path compression at creation**,
    /// and the reason `Plan.replacement` is one step with no budget.
    ///
    /// The invariant is that no recorded target is itself a substituted
    /// node, and it holds by induction over the order `list` visits
    /// bindings. A target is the initialiser of a binding at or before the
    /// one being planned; a node is substituted only as the use site of a
    /// binding planned LATER, and `findUse` finds a use only AFTER its
    /// binding in the same list — so no later binding can substitute a
    /// target already recorded. A nested statement list is planned after
    /// the list that holds it, but its bindings' uses are inside it, and a
    /// target is an atom or a member chain, which holds no list.
    ///
    /// Before this, `Printer.resolve` followed the chain for 64 steps and
    /// then printed the name it stopped at — a name whose binding this pass
    /// had dropped, which `Rename` spelt as whatever a live top-level held:
    /// `let x1 = x0 … x130 = x129 in x130` printed an unrelated constant.
    fn compress(o: *Opt, value: Index) Index {
        const target = if (o.ir.tag(value) == .ident) o.inlined[value.int()].unwrap() orelse value else value;
        std.debug.assert(o.ir.tag(target) != .ident or o.inlined[target.int()] == .none);
        return target;
    }

    fn drop(o: *Opt, node: Index) void {
        const i = node.int();
        o.dropped[i / 32] |= @as(u32, 1) << @intCast(i % 32);
    }

    /// §9's first condition: the initialiser is an atom or a member chain — a
    /// name, a literal, or `a.b.c` on one. Returns the chain's base name, or
    /// `.none` for a literal, or null when the initialiser is neither.
    ///
    /// A `template` is not an atom: its interpolations are work, and repeating
    /// work is the one thing the condition exists to forbid. `index_get` is
    /// not one either — `xs[i]` reads `i` as well, and `i` may be assigned.
    ///
    /// The budget is a conservative one: a member chain deeper than it
    /// answers null, which declines the fold (and, in `isPureReadConst`,
    /// stops the scan). Output is then unoptimised, never wrong.
    fn chainBase(o: *Opt, node: Index) ?NameIndex {
        var n = node;
        var budget: u32 = 64;
        while (budget > 0) : (budget -= 1) {
            const d = o.ir.data(n);
            switch (o.ir.tag(n)) {
                .ident => return @fromBackingInt(@intCast(d.lhs)),
                .field_name, .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit => return .none,
                .member => n = @fromBackingInt(@intCast(d.lhs)),
                else => return null,
            }
        }
        return null;
    }

    /// §9's remaining conditions, as one forward scan of the statements after
    /// the binding.
    ///
    ///   - **the use is in the same statement list**: the scan never leaves
    ///     `rest`, and `ownUses` never descends into a nested statement range
    ///     — an `if`'s branches, a `switch`'s cases, a block's body, a loop's
    ///     body — nor into an `arrow`, whose body is a statement list of its
    ///     own. So a use inside a closure or a loop or a branch is seen as
    ///     "this statement does not use it in its own expressions" and stops
    ///     the scan, which is the last two rows of §9's table.
    ///   - **every statement between them is another such binding**: the scan
    ///     walks past a `const` whose initialiser is an atom or a member chain
    ///     and past nothing else. Nothing that survives is evaluated in
    ///     between, so nothing is reordered (`language.md` §6).
    ///
    /// The single use is declaration-wide (`uses[n] == 1` is the caller's
    /// precondition), so finding it in one statement's own expressions proves
    /// there is no other — which is why no subtree count is needed and the
    /// scan is cheap. Returns the `ident` node the substitution is recorded
    /// against.
    fn findUse(o: *Opt, rest: []const Index, n: NameIndex) Allocator.Error!?Index {
        for (rest, 0..) |stmt, seen| {
            if (seen >= scan_limit) return null;
            o.found = .none;
            const own = try o.ownUses(stmt, n);
            if (own == 1) {
                o.found_in = stmt;
                return o.found.unwrap();
            }
            if (own != 0) return null;
            if (!o.isPureReadConst(stmt)) return null;
        }
        return null;
    }

    /// A value whose making does nothing and reads nothing can move to
    /// its one read in a later statement's own expressions. The counting
    /// walk recorded its list, so a branch, closure, loop or try boundary
    /// cannot become a substitution site, however far away the read is.
    fn findAnyUse(o: *Opt, range: JsIr.SubRange, after: usize, n: NameIndex) ?Index {
        const site = o.use_at[n.unwrap().?];
        if (site.list != @backingInt(range.start) or site.stmt <= after) return null;
        const at = site.node.unwrap() orelse return null;
        o.found_in = o.ir.extraSlice(range, Index)[site.stmt];
        return at;
    }

    /// `findUse` for a value that reads a field (`pureValue`): the owner's
    /// ordering rule (`backend.md` §9 item 1, amended 2026-10-18). A field
    /// read is effect-free but not invariant: a write of its record, or of
    /// anything aliasing it, changes what it answers. So it moves past a
    /// statement only when that statement can write nothing (`writeFree`),
    /// and in its use's statement only when nothing that may write is
    /// evaluated before it (`cleanBefore`). Any call or `new` is taken as a
    /// write: nothing here proves a callee writes no record.
    fn findUseAcross(o: *Opt, rest: []const Index, n: NameIndex) Allocator.Error!?Index {
        for (rest, 0..) |stmt, seen| {
            if (seen >= scan_limit) return null;
            o.found = .none;
            const own = try o.ownUses(stmt, n);
            if (own == 1) {
                const at = o.found.unwrap() orelse return null;
                return if (o.cleanBefore(stmt, at)) at else null;
            }
            if (own != 0) return null;
            if (!o.writeFree(stmt)) return null;
        }
        return null;
    }

    /// A `const` or `let` whose initialiser calls nothing, constructs
    /// nothing and yields nothing (a function it makes runs nowhere here):
    /// a statement that can write no record. Every other statement — an
    /// assignment, a call standing alone, a branch or a loop — may.
    fn writeFree(o: *Opt, stmt: Index) bool {
        const d = o.ir.data(stmt);
        const init: Index = switch (o.ir.tag(stmt)) {
            .const_decl => @fromBackingInt(@intCast(d.rhs)),
            .let_decl => @as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap() orelse return true,
            else => return false,
        };
        return o.mayWriteIn(init, null, 0) == .clean;
    }

    const Before = enum { clean, dirty, found_clean, found_dirty };

    /// Whether `site` is reached in statement `stmt`'s own expressions, in
    /// evaluation order, before anything that may write.
    fn cleanBefore(o: *Opt, stmt: Index, site: Index) bool {
        const d = o.ir.data(stmt);
        var roots: [2]Index = undefined;
        const own: []const Index = switch (o.ir.tag(stmt)) {
            .const_decl => blk: {
                roots[0] = @fromBackingInt(@intCast(d.rhs));
                break :blk roots[0..1];
            },
            .let_decl, .return_stmt => blk: {
                const raw = if (o.ir.tag(stmt) == .let_decl) d.rhs else d.lhs;
                roots[0] = @as(Node.OptionalIndex, @fromBackingInt(@intCast(raw))).unwrap() orelse return false;
                break :blk roots[0..1];
            },
            .assign_stmt => blk: {
                roots[0] = @fromBackingInt(@intCast(d.lhs));
                roots[1] = @fromBackingInt(@intCast(d.rhs));
                break :blk roots[0..2];
            },
            .if_stmt, .switch_stmt, .expr_stmt, .throw_stmt => blk: {
                roots[0] = @fromBackingInt(@intCast(d.lhs));
                break :blk roots[0..1];
            },
            else => return false,
        };
        for (own) |root| switch (o.mayWriteIn(root, site, 0)) {
            .clean => {},
            .found_clean => return true,
            .dirty, .found_dirty => return false,
        };
        return false;
    }

    /// Walk `node` in evaluation order: whether `site` is met (when given),
    /// and whether a call, a `new` or a `yield` is evaluated before it — or
    /// anywhere, when it is not met. An `arrow`'s body runs elsewhere. Too
    /// deep counts as a write, so the fold is declined.
    fn mayWriteIn(o: *Opt, node: Index, site: ?Index, depth: u32) Before {
        if (site) |u| if (node == u) return .found_clean;
        if (depth > 128) return .dirty;
        const tag = o.ir.tag(node);
        if (tag == .arrow) return .clean;
        var dirty = false;
        var kids: std.ArrayList(Index) = .empty;
        o.ir.pushOperands(o.arena, &kids, node) catch return .dirty;
        // `pushOperands` pushes in reverse, so the last is evaluated first.
        var k = kids.items.len;
        while (k > 0) {
            k -= 1;
            switch (o.mayWriteIn(kids.items[k], site, depth + 1)) {
                .clean => {},
                .dirty => dirty = true,
                .found_clean => return if (dirty) .found_dirty else .found_clean,
                .found_dirty => return .found_dirty,
            }
        }
        const writes = switch (tag) {
            .call, .new_call, .assign => true,
            .unary => @as(JsIr.UnaryOp, @fromBackingInt(@intCast(o.ir.data(node).rhs))) == .yield,
            else => false,
        };
        return if (dirty or writes) .dirty else .clean;
    }

    /// What `pureValue` knows of a value it accepts: whether it is surely a
    /// primitive, which an operator may convert without running code.
    const Shape = enum { primitive, any };

    /// Whether evaluating `node` does nothing, cannot throw, and answers the
    /// same at every point of the declaration (`backend.md` §9 item 1,
    /// amended 2026-10-18), or null:
    ///
    ///   - a literal, and a name no `assign_stmt` of the declaration targets
    ///     and no `Js.Ref` rebinds (`mutable`);
    ///   - a read of a beni record's field (`JsIr.isFieldRead`) of such a
    ///     value: a beni value has no getter and no beni code writes it;
    ///   - `!`, `typeof`, `===`, `!==`, `&&`, `||` and `?:` of such, which
    ///     convert nothing;
    ///   - an arithmetic, comparison or bitwise operator, `-`, and a
    ///     template, of such values that are surely primitives — a literal,
    ///     a field read, or another operator's result — so no `valueOf` or
    ///     `toString` runs. A field read is one there because beni writes an
    ///     operator only on a primitive type (`==` and `<` of anything else
    ///     call `eq` and `compare`, §4). A name is not: a platform's
    ///     lowering may hold a host value in one.
    ///
    /// A member read that is not a field's — a tuple's or constructor's
    /// slot, a tag, a host property — is not accepted; the atom and
    /// member-chain rule still takes the bare chain.
    fn pureValue(o: *Opt, node: Index, depth: u32) ?Shape {
        if (depth > 64) return null;
        const d = o.ir.data(node);
        switch (o.ir.tag(node)) {
            .field_name, .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => return .primitive,
            .ident => {
                // A name an earlier fold already wrote a value at is that
                // value: `n = c.v; three = n == 3` judges `c.v == 3`.
                if (o.inlined[node.int()].unwrap()) |v| return o.pureValue(v, depth + 1);
                const n: NameIndex = @fromBackingInt(@intCast(d.lhs));
                if (n.unwrap()) |i| if (i < o.assigned.len and o.stamp[i] == o.current and o.assigned[i]) return null;
                if (std.mem.indexOfScalar(NameIndex, o.mutable, n) != null) return null;
                return .any;
            },
            .member => {
                if (!o.ir.isFieldRead(node)) return null;
                _ = o.pureValue(@fromBackingInt(@intCast(d.lhs)), depth + 1) orelse return null;
                o.reads_field = true;
                return .primitive;
            },
            .unary => {
                const shape = o.pureValue(@fromBackingInt(@intCast(d.lhs)), depth + 1) orelse return null;
                return switch (@as(JsIr.UnaryOp, @fromBackingInt(@intCast(d.rhs)))) {
                    .not, .type_of => .primitive,
                    .neg => if (shape == .primitive) .primitive else null,
                    .yield => null,
                };
            },
            .binary => {
                const b = o.ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                const left = o.pureValue(b.left, depth + 1) orelse return null;
                const right = o.pureValue(b.right, depth + 1) orelse return null;
                const both: Shape = if (left == .primitive and right == .primitive) .primitive else .any;
                return switch (@as(JsIr.BinaryOp, @fromBackingInt(@intCast(d.rhs)))) {
                    .strict_eq, .strict_ne => .primitive,
                    .logical_and, .logical_or => both,
                    .instance_of => null,
                    else => if (both == .primitive) .primitive else null,
                };
            },
            .cond => {
                const c = o.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                _ = o.pureValue(@fromBackingInt(@intCast(d.lhs)), depth + 1) orelse return null;
                const yes = o.pureValue(c.consequent, depth + 1) orelse return null;
                const no = o.pureValue(c.alternate, depth + 1) orelse return null;
                return if (yes == .primitive and no == .primitive) .primitive else .any;
            },
            .template => {
                for (o.ir.extraSlice(JsIr.inlineRange(d), Index)) |part| {
                    if (o.ir.tag(part) == .template_chunk) continue;
                    if ((o.pureValue(part, depth + 1) orelse return null) != .primitive) return null;
                }
                return .primitive;
            },
            else => return null,
        }
    }

    /// A `const` whose initialiser is an atom or a member chain: the only
    /// statement the scan walks past.
    fn isPureReadConst(o: *Opt, stmt: Index) bool {
        if (o.ir.tag(stmt) != .const_decl) return false;
        return o.chainBase(@fromBackingInt(@intCast(o.ir.data(stmt).rhs))) != null;
    }

    /// Reads of `n` in a statement's OWN expressions: everything evaluated
    /// when control reaches the statement, and nothing that a branch, a loop
    /// iteration or a closure decides to evaluate later. Every statement that
    /// owns a nested statement RANGE — `if`, `while_true`, `switch`, a block —
    /// contributes only the expression it evaluates before entering one, and a
    /// `func_decl` contributes nothing at all.
    fn ownUses(o: *Opt, stmt: Index, n: NameIndex) Allocator.Error!u32 {
        const d = o.ir.data(stmt);
        return switch (o.ir.tag(stmt)) {
            .const_decl => o.exprUses(@fromBackingInt(@intCast(d.rhs)), n),
            .let_decl => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| o.exprUses(v, n) else 0,
            .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| o.exprUses(v, n) else 0,
            .assign_stmt => (try o.exprUses(@fromBackingInt(@intCast(d.lhs)), n)) + (try o.exprUses(@fromBackingInt(@intCast(d.rhs)), n)),
            .if_stmt, .switch_stmt => o.exprUses(@fromBackingInt(@intCast(d.lhs)), n),
            // A use in a loop's iterable is never a fold's: the printer would
            // write the value in the loop's head, where the loop's own binding
            // is in scope, and `Rename`, which reads the IR as written, may
            // give that binding a name the value reads. Counted as more than
            // one, so every rule declines it.
            .for_of => if (try o.exprUses(o.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf).iterable, n) != 0) 2 else 0,
            .expr_stmt, .throw_stmt => o.exprUses(@fromBackingInt(@intCast(d.lhs)), n),
            else => 0,
        };
    }

    /// Reads of `n` inside one expression, stopping at an `arrow`: a closure
    /// body is evaluated a different number of times than the table in
    /// `language.md` §6 gives, so a use in one is not a use the inliner may
    /// move to. Iterative, like `countExpr`.
    ///
    /// An `arrow`'s body is a statement list of its own, so a use inside it
    /// is a use inside a closure and this walk stops there. It does not need
    /// to report one: `uses[n] == 1` is the caller's precondition, so a zero
    /// from a statement that is not a pure-read `const` stops the scan anyway
    /// — and a pure-read `const` is an atom or a member chain and can hold no
    /// `arrow` to hide it in.
    fn exprUses(o: *Opt, root: Index, n: NameIndex) Allocator.Error!u32 {
        const base = o.stack.items.len;
        defer o.stack.shrinkRetainingCapacity(base);
        try o.stack.append(o.arena, root);
        var total: u32 = 0;
        while (o.stack.items.len > base) {
            const node = JsIr.popOperand(&o.stack).?;
            switch (o.ir.tag(node)) {
                .ident => {
                    if (@as(NameIndex, @fromBackingInt(@intCast(o.ir.data(node).lhs))) != n) continue;
                    o.found = node.toOptional();
                    total += 1;
                },
                .arrow => {},
                else => try o.ir.pushOperands(o.arena, &o.stack, node),
            }
        }
        return total;
    }
};

// ---------------------------------------------------------------------------
// Tests
//
// The plan only. What the printer DOES with a plan is `Print.zig`'s, what the
// emitted program computes is `tests/corpus/run/`'s (every fixture of which is
// built a second time under `--release`), and the shapes are
// `tests/corpus/emit/release/`'s.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an empty module needs no plan" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const p = try run(arena_state.allocator(), &JsIr.empty);
    try testing.expectEqual(@as(usize, 0), p.dropped.len);
    try testing.expectEqual(@as(usize, 0), p.inlined.len);
}

test "the empty plan drops nothing and substitutes nothing" {
    const p: Plan = .none;
    try testing.expect(!p.isDropped(@fromBackingInt(@intCast(0))));
    try testing.expect(!p.isDropped(@fromBackingInt(@intCast(9999))));
    try testing.expectEqual(@as(?Index, null), p.replacement(@fromBackingInt(@intCast(0))));
    try testing.expectEqual(@as(?Index, null), p.replacement(@fromBackingInt(@intCast(9999))));
}

const small_stack = @import("../small_stack.zig");

/// Twice the depth a walk that recursed once per link fails at on
/// `small_stack.size`: a `countExpr` that recursed into each `&&`'s operands
/// finished 2 000 links on the Debug test binary and overflowed at 5 000.
const deep_chain = 10_000;

test "a function returning a && chain deeper than a recursive walk survives is planned down to its deepest link" {
    // A derived `eq` is one left-nested `&&` as long as its record is wide.
    // Every walk here keeps its own stack (`JsIr.pushOperands`), so the
    // plan is made on `small_stack`'s few pages. The chain's deepest link
    // reads a binding that has exactly one use, so the plan inlines it only
    // if the counting walk and the scan for the use both reached the bottom.
    try small_stack.run(planDeepChain, .{});
}

/// `function f(a) { const t = a; return t && a && … && a; }`.
fn planDeepChain() !void {
    const gpa = testing.allocator;
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    const a = try b.intern(.local(@fromBackingInt(@intCast(0))));
    const t = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const f = try b.intern(.local(@fromBackingInt(@intCast(2))));
    const value = try testNode(&b, .ident, a.int(), 0);
    const bind = try testNode(&b, .const_decl, t.int(), value.int());
    const use = try testNode(&b, .ident, t.int(), 0);
    var chain = use;
    for (1..deep_chain) |_| {
        const operand = try testNode(&b, .ident, a.int(), 0);
        const pair = try b.addRecord(JsIr.Binary{ .left = chain, .right = operand });
        chain = try testNode(&b, .binary, @backingInt(pair), @backingInt(JsIr.BinaryOp.logical_and));
    }
    const ret = try testNode(&b, .return_stmt, chain.int(), 0);
    const params = try b.addNames(&.{a});
    const stmts = try b.addRange(&.{ bind, ret });
    const func = try b.addRecord(JsIr.Func{
        .params_start = params.start,
        .params_end = params.end,
        .body_start = stmts.start,
        .body_end = stmts.end,
    });
    const decl = try testNode(&b, .func_decl, f.int(), @backingInt(func));
    var ir = try b.toOwned(try b.addRange(&.{decl}));
    defer ir.deinit(gpa);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const plan = try run(arena_state.allocator(), &ir);
    try testing.expect(plan.isDropped(bind));
    try testing.expectEqual(@as(?Index, value), plan.replacement(use));
    try testing.expect(!plan.isDropped(ret));
}

fn testNode(b: *JsIr.Builder, tag: Node.Tag, lhs: u32, rhs: u32) !Index {
    return b.addNode(.{ .tag = tag, .pos = Node.no_pos, .data = .{ .lhs = lhs, .rhs = rhs } });
}

test "a binding nothing reads is kept when it writes a record in place" {
    // `function f(r) { const x = (r.a = true, r); const y = r; return 0; }`:
    // `y` goes, `x` stays — its store is the update (`ownership-checker.md`
    // §31.10, *The optimiser barrier*).
    const gpa = testing.allocator;
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    const r = try b.intern(.local(@fromBackingInt(@intCast(0))));
    const x = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const y = try b.intern(.local(@fromBackingInt(@intCast(2))));
    const f = try b.intern(.local(@fromBackingInt(@intCast(3))));
    const a = try b.intern(.local(@fromBackingInt(@intCast(4))));
    const target = try testNode(&b, .member, (try testNode(&b, .ident, r.int(), 0)).int(), a.int());
    const store = try testNode(&b, .assign, target.int(), (try testNode(&b, .true_lit, 0, 0)).int());
    const parts = try b.addRange(&.{ store, try testNode(&b, .ident, r.int(), 0) });
    const seq = try testNode(&b, .sequence, @backingInt(parts.start), @backingInt(parts.end));
    const keep_x = try testNode(&b, .const_decl, x.int(), seq.int());
    const drop_y = try testNode(&b, .const_decl, y.int(), (try testNode(&b, .ident, r.int(), 0)).int());
    const ret = try testNode(&b, .return_stmt, (try testNode(&b, .null_lit, 0, 0)).int(), 0);
    const params = try b.addNames(&.{r});
    const stmts = try b.addRange(&.{ drop_y, keep_x, ret });
    const func = try b.addRecord(JsIr.Func{
        .params_start = params.start,
        .params_end = params.end,
        .body_start = stmts.start,
        .body_end = stmts.end,
    });
    const decl = try testNode(&b, .func_decl, f.int(), @backingInt(func));
    var ir = try b.toOwned(try b.addRange(&.{decl}));
    defer ir.deinit(gpa);
    try ir.verify();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const plan = try run(arena_state.allocator(), &ir);
    try testing.expect(!plan.isDropped(keep_x));
    try testing.expect(plan.isDropped(drop_y));
}
