//! `backend.md` §9's release optimiser, **item 1**: local dead bindings, and
//! the single use that follows them. One pass over `JsIr`, per function body,
//! between `Lower.lower` and `Print.print` and under `--release` only.
//!
//! `Reach` decided which declarations exist; this decides what is left inside
//! one. Two rules, one walk:
//!
//!   - **Zero uses: the binding goes WHOLE**, initialiser included, whatever
//!     the initialiser is. `language.md` §6's *What an optimiser may assume*
//!     is the licence in so many words — "a binding whose value is never used
//!     may be dropped whole, everything inside it included, a `Debug.log`
//!     among it" — so the pass asks nothing about the right-hand side and a
//!     call of a `foreign` is droppable. The alternative, a "does the
//!     initialiser call a `foreign`?" test, would pin `Node.done` in every
//!     platform module and is the `sideEffects: false` guesswork §9's purity
//!     paragraph exists to replace.
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
//! construction (a binding is inlined only into a LATER statement), and
//! `resolve` carries a budget anyway so that a malformed plan is a wrong
//! spelling and never a hang.
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

    /// The plan a development build runs under: nothing dropped, nothing
    /// substituted.
    pub const none: Plan = .{};

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
    if (ir.nodes.len == 0) return .none;

    var o: Opt = .{
        .ir = ir,
        .uses = try arena.alloc(u32, ir.names.len),
        .decls = try arena.alloc(u32, ir.names.len),
        .assigned = try arena.alloc(bool, ir.names.len),
        .stamp = try arena.alloc(u32, ir.names.len),
        .dropped = try arena.alloc(u32, (ir.nodes.len + 31) / 32),
        .inlined = try arena.alloc(Node.OptionalIndex, ir.nodes.len),
    };
    @memset(o.stamp, 0);
    @memset(o.dropped, 0);
    @memset(o.inlined, .none);

    for (ir.extraSlice(ir.body, Index)) |top| {
        o.current += 1;
        o.countStmt(top);
        o.planStmt(top);
    }
    return .{ .dropped = o.dropped, .inlined = o.inlined };
}

const Opt = struct {
    ir: *const JsIr,
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
    /// Whether any `assign_stmt` in this declaration targets the name. §8
    /// reassigns an `$in$<i>` slot per iteration, so a read of one is not a
    /// stable read and a chain rooted at one may not move.
    assigned: []bool,
    dropped: []u32,
    inlined: []Node.OptionalIndex,
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
    fn countStmt(o: *Opt, stmt: Index) void {
        const d = o.ir.data(stmt);
        switch (o.ir.tag(stmt)) {
            .import_stmt => {
                const imp = o.ir.extraData(@enumFromInt(d.lhs), JsIr.Import);
                for (o.ir.extraSlice(imp.specs(), JsIr.Specifier)) |spec| o.declare(spec.local);
            },
            .export_stmt => for (o.ir.extraSlice(JsIr.inlineRange(d), NameIndex)) |n| o.use(n),
            .const_decl => {
                o.declare(@enumFromInt(d.lhs));
                o.countExpr(@enumFromInt(d.rhs));
            },
            .let_decl => {
                o.declare(@enumFromInt(d.lhs));
                if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| o.countExpr(v);
            },
            .func_decl => {
                o.declare(@enumFromInt(d.lhs));
                o.countFunc(@enumFromInt(d.rhs));
            },
            .assign_stmt => {
                o.markAssigned(@enumFromInt(d.lhs));
                o.countExpr(@enumFromInt(d.lhs));
                o.countExpr(@enumFromInt(d.rhs));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| o.countExpr(v),
            .if_stmt => {
                o.countExpr(@enumFromInt(d.lhs));
                const branches = o.ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                o.countStmts(branches.thenBody());
                o.countStmts(branches.elseBody());
            },
            // A label shares the binding namespace (§9 item 2), so a name a
            // label holds is not a name a binding may be dropped under.
            .while_true, .block_stmt => {
                o.use(@enumFromInt(d.lhs));
                o.countStmts(o.ir.subRange(@enumFromInt(d.rhs)));
            },
            .break_stmt, .continue_stmt => o.use(@enumFromInt(d.lhs)),
            .switch_stmt => {
                o.countExpr(@enumFromInt(d.lhs));
                for (o.ir.extraSlice(o.ir.subRange(@enumFromInt(d.rhs)), Index)) |c| o.countStmt(c);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| o.countExpr(t);
                o.countStmts(o.ir.subRange(@enumFromInt(d.rhs)));
            },
            .expr_stmt, .throw_stmt => o.countExpr(@enumFromInt(d.lhs)),
            else => {},
        }
    }

    fn countStmts(o: *Opt, range: JsIr.SubRange) void {
        for (o.ir.extraSlice(range, Index)) |s| o.countStmt(s);
    }

    /// Mark the root of an assignment target. `a.b = c` mutates `a`'s object
    /// and not `a`, but a chain rooted at `a` is refused either way: the
    /// cheaper rule is the one nobody has to reason about at a call site.
    fn markAssigned(o: *Opt, target: Index) void {
        var node = target;
        var budget: u32 = 64;
        while (budget > 0) : (budget -= 1) {
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

    fn countFunc(o: *Opt, record: JsIr.ExtraIndex) void {
        const f = o.ir.extraData(record, JsIr.Func);
        // A parameter is counted as a READ, not as a declaration. It shadows
        // rather than binds anything this pass may touch, and counting it as
        // a read is the conservative half of the two.
        for (o.ir.extraSlice(f.params(), NameIndex)) |n| o.use(n);
        o.countStmts(f.body());
    }

    fn countExpr(o: *Opt, node: Index) void {
        const d = o.ir.data(node);
        switch (o.ir.tag(node)) {
            .ident => o.use(@enumFromInt(d.lhs)),
            .member, .unary, .spread_property => o.countExpr(@enumFromInt(d.lhs)),
            .index_get => {
                o.countExpr(@enumFromInt(d.lhs));
                o.countExpr(@enumFromInt(d.rhs));
            },
            .property => o.countExpr(@enumFromInt(d.rhs)),
            .call => {
                o.countExpr(@enumFromInt(d.lhs));
                for (o.ir.extraSlice(o.ir.subRange(@enumFromInt(d.rhs)), Index)) |arg| o.countExpr(arg);
            },
            .object, .array, .template => for (o.ir.extraSlice(JsIr.inlineRange(d), Index)) |c| o.countExpr(c),
            .cond => {
                o.countExpr(@enumFromInt(d.lhs));
                const c = o.ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
                o.countExpr(c.consequent);
                o.countExpr(c.alternate);
            },
            .binary => {
                const b = o.ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
                o.countExpr(b.left);
                o.countExpr(b.right);
            },
            .arrow => o.countFunc(@enumFromInt(d.lhs)),
            else => {},
        }
    }

    /// Every statement list BELOW one top-level declaration, in emission
    /// order. The module body itself is never a list here: its bindings are
    /// top-level declarations, `Reach` owns what those ship (§9), another
    /// file reads them through an `import`, and "per function body" is what
    /// §9 item 1 says. A name that carries a module qualifier is refused a
    /// second time in `list`, so the exclusion holds either way.
    fn planStmt(o: *Opt, stmt: Index) void {
        const d = o.ir.data(stmt);
        switch (o.ir.tag(stmt)) {
            .const_decl => o.planExpr(@enumFromInt(d.rhs)),
            .let_decl => if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| o.planExpr(v),
            .func_decl => o.planFunc(@enumFromInt(d.rhs)),
            .assign_stmt => {
                o.planExpr(@enumFromInt(d.lhs));
                o.planExpr(@enumFromInt(d.rhs));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| o.planExpr(v),
            .if_stmt => {
                o.planExpr(@enumFromInt(d.lhs));
                const branches = o.ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                o.planList(branches.thenBody());
                o.planList(branches.elseBody());
            },
            .while_true, .block_stmt => o.planList(o.ir.subRange(@enumFromInt(d.rhs))),
            .switch_stmt => {
                o.planExpr(@enumFromInt(d.lhs));
                for (o.ir.extraSlice(o.ir.subRange(@enumFromInt(d.rhs)), Index)) |c| o.planStmt(c);
            },
            .switch_case => o.planList(o.ir.subRange(@enumFromInt(d.rhs))),
            .expr_stmt, .throw_stmt => o.planExpr(@enumFromInt(d.lhs)),
            else => {},
        }
    }

    fn planList(o: *Opt, range: JsIr.SubRange) void {
        o.list(range);
        for (o.ir.extraSlice(range, Index)) |s| o.planStmt(s);
    }

    fn planFunc(o: *Opt, record: JsIr.ExtraIndex) void {
        o.planList(o.ir.extraData(record, JsIr.Func).body());
    }

    /// Find the `arrow`s an expression holds; their bodies are statement
    /// lists like any other.
    fn planExpr(o: *Opt, node: Index) void {
        const d = o.ir.data(node);
        switch (o.ir.tag(node)) {
            .arrow => o.planFunc(@enumFromInt(d.lhs)),
            .member, .unary, .spread_property => o.planExpr(@enumFromInt(d.lhs)),
            .index_get => {
                o.planExpr(@enumFromInt(d.lhs));
                o.planExpr(@enumFromInt(d.rhs));
            },
            .property => o.planExpr(@enumFromInt(d.rhs)),
            .call => {
                o.planExpr(@enumFromInt(d.lhs));
                for (o.ir.extraSlice(o.ir.subRange(@enumFromInt(d.rhs)), Index)) |arg| o.planExpr(arg);
            },
            .object, .array, .template => for (o.ir.extraSlice(JsIr.inlineRange(d), Index)) |c| o.planExpr(c),
            .cond => {
                o.planExpr(@enumFromInt(d.lhs));
                const c = o.ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
                o.planExpr(c.consequent);
                o.planExpr(c.alternate);
            },
            .binary => {
                const b = o.ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
                o.planExpr(b.left);
                o.planExpr(b.right);
            },
            else => {},
        }
    }

    fn list(o: *Opt, range: JsIr.SubRange) void {
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
                o.drop(stmt);
                continue;
            }
            if (t != .const_decl) continue;
            if (o.readOf(idx, "uses") != 1 or o.readOf(idx, "decls") != 1) continue;
            const value: Index = @enumFromInt(d.rhs);
            const base = o.chainBase(value) orelse continue;
            if (base.unwrap()) |b| {
                if (b < o.assigned.len and o.stamp[b] == o.current and o.assigned[b]) continue;
            }
            const at = o.findUse(stmts[i + 1 ..], n) orelse continue;
            o.drop(stmt);
            o.inlined[at.int()] = value.toOptional();
        }
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
    fn chainBase(o: *Opt, node: Index) ?NameIndex {
        var n = node;
        var budget: u32 = 64;
        while (budget > 0) : (budget -= 1) {
            const d = o.ir.data(n);
            switch (o.ir.tag(n)) {
                .ident => return @enumFromInt(d.lhs),
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => return .none,
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
    fn findUse(o: *Opt, rest: []const Index, n: NameIndex) ?Index {
        for (rest, 0..) |stmt, seen| {
            if (seen >= scan_limit) return null;
            o.found = .none;
            const own = o.ownUses(stmt, n);
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
    fn ownUses(o: *Opt, stmt: Index, n: NameIndex) u32 {
        const d = o.ir.data(stmt);
        return switch (o.ir.tag(stmt)) {
            .const_decl => o.exprUses(@enumFromInt(d.rhs), n),
            .let_decl => if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| o.exprUses(v, n) else 0,
            .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| o.exprUses(v, n) else 0,
            .assign_stmt => o.exprUses(@enumFromInt(d.lhs), n) + o.exprUses(@enumFromInt(d.rhs), n),
            .if_stmt, .switch_stmt => o.exprUses(@enumFromInt(d.lhs), n),
            .expr_stmt, .throw_stmt => o.exprUses(@enumFromInt(d.lhs), n),
            else => 0,
        };
    }

    /// Reads of `n` inside one expression, stopping at an `arrow`: a closure
    /// body is evaluated a different number of times than the table in
    /// `language.md` §6 gives, so a use in one is not a use the inliner may
    /// move to.
    fn exprUses(o: *Opt, node: Index, n: NameIndex) u32 {
        const d = o.ir.data(node);
        return switch (o.ir.tag(node)) {
            .ident => blk: {
                if (@as(NameIndex, @enumFromInt(d.lhs)) != n) break :blk 0;
                o.found = node.toOptional();
                break :blk 1;
            },
            .member, .unary, .spread_property => o.exprUses(@enumFromInt(d.lhs), n),
            .index_get => o.exprUses(@enumFromInt(d.lhs), n) + o.exprUses(@enumFromInt(d.rhs), n),
            .property => o.exprUses(@enumFromInt(d.rhs), n),
            .call => blk: {
                var total = o.exprUses(@enumFromInt(d.lhs), n);
                for (o.ir.extraSlice(o.ir.subRange(@enumFromInt(d.rhs)), Index)) |arg| total += o.exprUses(arg, n);
                break :blk total;
            },
            .object, .array, .template => blk: {
                var total: u32 = 0;
                for (o.ir.extraSlice(JsIr.inlineRange(d), Index)) |child| total += o.exprUses(child, n);
                break :blk total;
            },
            .cond => blk: {
                const c = o.ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
                break :blk o.exprUses(@enumFromInt(d.lhs), n) + o.exprUses(c.consequent, n) + o.exprUses(c.alternate, n);
            },
            .binary => blk: {
                const b = o.ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
                break :blk o.exprUses(b.left, n) + o.exprUses(b.right, n);
            },
            // An `arrow`'s body is a statement list of its own, so a use
            // inside it is a use inside a closure and this walk stops here.
            // It does not need to report one: `uses[n] == 1` is the caller's
            // precondition, so a zero from a statement that is not a pure-read
            // `const` stops the scan anyway — and a pure-read `const` is an
            // atom or a member chain and can hold no `arrow` to hide it in.
            else => 0,
        };
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
