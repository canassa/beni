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
    /// One bit per NAME: declared more than once in some top-level
    /// declaration (the compiler's positional names can repeat). A
    /// statement list that declares none of these may be printed as part
    /// of the list around it — the printer's `else` that follows an arm
    /// that jumps — since no name in it can then come to mean another.
    repeated: []const u32 = &.{},

    /// The plan a development build runs under: nothing dropped, nothing
    /// substituted.
    pub const none: Plan = .{};

    /// Whether `n` is declared twice in a declaration; true for anything
    /// the plan does not cover, which is the safe answer.
    pub fn isRepeated(p: *const Plan, n: NameIndex) bool {
        const i = n.unwrap() orelse return false;
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
        .decls = try arena.alloc(u32, ir.names.len),
        .binds = try arena.alloc(u32, ir.names.len),
        .assigned = try arena.alloc(bool, ir.names.len),
        .stamp = try arena.alloc(u32, ir.names.len),
        .dropped = try arena.alloc(u32, (ir.nodes.len + 31) / 32),
        .inlined = try arena.alloc(Node.OptionalIndex, ir.nodes.len),
        .repeated = try arena.alloc(u32, (ir.names.len + 31) / 32),
        .mutable = mutable,
    };
    @memset(o.stamp, 0);
    @memset(o.repeated, 0);
    @memset(o.dropped, 0);
    @memset(o.inlined, .none);
    for (discarded) |node| if (node.int() < ir.nodes.len) o.drop(node);

    for (ir.extraSlice(ir.body, Index)) |top| {
        o.current += 1;
        try o.countStmt(top);
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
    dropped: []u32,
    inlined: []Node.OptionalIndex,
    /// `Plan.repeated`.
    repeated: []u32,
    /// `runKeeping`'s `mutable`: bases no fold may rest on.
    mutable: []const NameIndex = &.{},
    /// The `ident` node `exprUses` last matched, which `findUse` reads back
    /// as the use site. One slot rather than a returned pair, because the
    /// count and the node are wanted at different depths of the same walk.
    found: Node.OptionalIndex = .none,

    // ---- The counting walk ------------------------------------------------

    /// Reset a slot the first time this declaration touches it.
    fn touch(o: *Opt, i: u32) void {
        if (o.stamp[i] == o.current) return;
        o.stamp[i] = o.current;
        o.uses[i] = 0;
        o.decls[i] = 0;
        o.binds[i] = 0;
        o.assigned[i] = false;
    }

    fn use(o: *Opt, n: NameIndex) void {
        const i = n.unwrap() orelse return;
        if (i >= o.uses.len) return;
        o.touch(i);
        o.uses[i] += 1;
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
        if (o.binds[i] > 1) o.repeated[i / 32] |= @as(u32, 1) << @intCast(i % 32);
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
                const imp = o.ir.extraData(@enumFromInt(d.lhs), JsIr.Import);
                for (o.ir.extraSlice(imp.specs(), JsIr.Specifier)) |spec| o.declare(spec.local);
            },
            .export_stmt => for (o.ir.extraSlice(JsIr.inlineRange(d), NameIndex)) |n| o.use(n),
            .const_decl => {
                o.declare(@enumFromInt(d.lhs));
                try o.countExpr(@enumFromInt(d.rhs));
            },
            .let_decl => {
                o.declare(@enumFromInt(d.lhs));
                if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| try o.countExpr(v);
            },
            .func_decl, .gen_decl => {
                o.declare(@enumFromInt(d.lhs));
                try o.countFunc(@enumFromInt(d.rhs));
            },
            .assign_stmt => {
                o.markAssigned(@enumFromInt(d.lhs));
                try o.countExpr(@enumFromInt(d.lhs));
                try o.countExpr(@enumFromInt(d.rhs));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| try o.countExpr(v),
            .if_stmt => {
                try o.countExpr(@enumFromInt(d.lhs));
                const branches = o.ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                try o.countStmts(branches.thenBody());
                try o.countStmts(branches.elseBody());
            },
            // A label shares the binding namespace (§9 item 2), so a name a
            // label holds is not a name a binding may be dropped under.
            .while_true, .block_stmt => {
                o.use(@enumFromInt(d.lhs));
                try o.countStmts(o.ir.subRange(@enumFromInt(d.rhs)));
            },
            .break_stmt, .continue_stmt => o.use(@enumFromInt(d.lhs)),
            // The loop variable is bound per iteration, like a parameter.
            .for_of => {
                const n: NameIndex = @enumFromInt(d.lhs);
                o.use(n);
                if (n.unwrap()) |i| if (i < o.binds.len) o.bind(i);
                const f = o.ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                try o.countExpr(f.iterable);
                try o.countStmts(f.body());
            },
            .switch_stmt => {
                try o.countExpr(@enumFromInt(d.lhs));
                for (o.ir.extraSlice(o.ir.subRange(@enumFromInt(d.rhs)), Index)) |c| try o.countStmt(c);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| try o.countExpr(t);
                try o.countStmts(o.ir.subRange(@enumFromInt(d.rhs)));
            },
            .expr_stmt, .throw_stmt => try o.countExpr(@enumFromInt(d.lhs)),
            else => {},
        }
    }

    fn countStmts(o: *Opt, range: JsIr.SubRange) Allocator.Error!void {
        for (o.ir.extraSlice(range, Index)) |s| try o.countStmt(s);
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
                    const i = @as(NameIndex, @enumFromInt(d.lhs)).unwrap() orelse return;
                    if (i >= o.assigned.len) return;
                    o.touch(i);
                    o.assigned[i] = true;
                    return;
                },
                .member, .index_get => node = @enumFromInt(d.lhs),
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
                .ident => o.use(@enumFromInt(o.ir.data(node).lhs)),
                .arrow => try o.countFunc(@enumFromInt(o.ir.data(node).lhs)),
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
            .const_decl => try o.planExpr(@enumFromInt(d.rhs)),
            .let_decl => if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| try o.planExpr(v),
            .func_decl, .gen_decl => try o.planFunc(@enumFromInt(d.rhs)),
            .assign_stmt => {
                try o.planExpr(@enumFromInt(d.lhs));
                try o.planExpr(@enumFromInt(d.rhs));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| try o.planExpr(v),
            .if_stmt => {
                try o.planExpr(@enumFromInt(d.lhs));
                const branches = o.ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                try o.planList(branches.thenBody());
                try o.planList(branches.elseBody());
            },
            .while_true, .block_stmt => try o.planList(o.ir.subRange(@enumFromInt(d.rhs))),
            .for_of => {
                const f = o.ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                try o.planExpr(f.iterable);
                try o.planList(f.body());
            },
            .switch_stmt => {
                try o.planExpr(@enumFromInt(d.lhs));
                for (o.ir.extraSlice(o.ir.subRange(@enumFromInt(d.rhs)), Index)) |c| try o.planStmt(c);
            },
            .switch_case => try o.planList(o.ir.subRange(@enumFromInt(d.rhs))),
            .expr_stmt, .throw_stmt => try o.planExpr(@enumFromInt(d.lhs)),
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
                .arrow => try o.planFunc(@enumFromInt(o.ir.data(node).lhs)),
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
            const n: NameIndex = @enumFromInt(d.lhs);
            const idx = n.unwrap() orelse continue;
            if (idx >= o.uses.len) continue;
            // A qualified name crosses a file (§9 item 2's first namespace);
            // nothing local may be concluded about it here.
            if (o.ir.name(n).module != .none) continue;

            if (o.readOf(idx, "uses") == 0) {
                const at = stmt.int();
                if (o.kept[at / 32] & (@as(u32, 1) << @intCast(at % 32)) == 0) o.drop(stmt);
                continue;
            }
            if (t != .const_decl) continue;
            if (o.readOf(idx, "uses") != 1 or o.readOf(idx, "decls") != 1) continue;
            const value: Index = @enumFromInt(d.rhs);
            // A property read that may have an effect — a `Js.get` of a
            // property some call may write — is evaluated where it stands:
            // folded into its use it would move past whatever that use's
            // statement evaluates first. A name or a literal cannot change.
            const here = stmt.int();
            if (o.kept[here / 32] & (@as(u32, 1) << @intCast(here % 32)) != 0 and o.ir.tag(value) == .member) continue;
            const base = o.chainBase(value) orelse continue;
            if (base.unwrap()) |b| {
                if (b < o.assigned.len and o.stamp[b] == o.current and o.assigned[b]) continue;
                if (std.mem.indexOfScalar(NameIndex, o.mutable, base) != null) continue;
            }
            const at = try o.findUse(stmts[i + 1 ..], n) orelse continue;
            o.drop(stmt);
            o.inlined[at.int()] = o.compress(value).toOptional();
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
                .ident => return @enumFromInt(d.lhs),
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this => return .none,
                .member => n = @enumFromInt(d.lhs),
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
            if (own == 1) return o.found.unwrap();
            if (own != 0) return null;
            if (!o.isPureReadConst(stmt)) return null;
        }
        return null;
    }

    /// A `const` whose initialiser is an atom or a member chain: the only
    /// statement the scan walks past.
    fn isPureReadConst(o: *Opt, stmt: Index) bool {
        if (o.ir.tag(stmt) != .const_decl) return false;
        return o.chainBase(@enumFromInt(o.ir.data(stmt).rhs)) != null;
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
            .const_decl => o.exprUses(@enumFromInt(d.rhs), n),
            .let_decl => if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| o.exprUses(v, n) else 0,
            .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| o.exprUses(v, n) else 0,
            .assign_stmt => (try o.exprUses(@enumFromInt(d.lhs), n)) + (try o.exprUses(@enumFromInt(d.rhs), n)),
            .if_stmt, .switch_stmt => o.exprUses(@enumFromInt(d.lhs), n),
            .for_of => o.exprUses(o.ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf).iterable, n),
            .expr_stmt, .throw_stmt => o.exprUses(@enumFromInt(d.lhs), n),
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
                    if (@as(NameIndex, @enumFromInt(o.ir.data(node).lhs)) != n) continue;
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
    try testing.expect(!p.isDropped(@enumFromInt(0)));
    try testing.expect(!p.isDropped(@enumFromInt(9999)));
    try testing.expectEqual(@as(?Index, null), p.replacement(@enumFromInt(0)));
    try testing.expectEqual(@as(?Index, null), p.replacement(@enumFromInt(9999)));
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
    const a = try b.intern(.local(@enumFromInt(0)));
    const t = try b.intern(.local(@enumFromInt(1)));
    const f = try b.intern(.local(@enumFromInt(2)));
    const value = try testNode(&b, .ident, a.int(), 0);
    const bind = try testNode(&b, .const_decl, t.int(), value.int());
    const use = try testNode(&b, .ident, t.int(), 0);
    var chain = use;
    for (1..deep_chain) |_| {
        const operand = try testNode(&b, .ident, a.int(), 0);
        const pair = try b.addRecord(JsIr.Binary{ .left = chain, .right = operand });
        chain = try testNode(&b, .binary, @intFromEnum(pair), @intFromEnum(JsIr.BinaryOp.logical_and));
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
    const decl = try testNode(&b, .func_decl, f.int(), @intFromEnum(func));
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
