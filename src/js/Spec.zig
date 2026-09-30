//! `backend.md` §9, *Whole-program specialisation*: a `--release`
//! application's lowered modules, all at once, rewritten to what the
//! program's own calls make of them. Run on the calling thread after every
//! module is lowered and before the release optimiser (`Opt`) plans any.
//!
//! **The facts** are may-analyses whose unknowns are ⊤, each computed to a
//! fixpoint over the whole program:
//!
//!   1. **Constant arguments.** Per parameter of every top-level function,
//!      the one literal every call passes it, or ⊤. A function whose name
//!      appears anywhere but as the callee of a call — passed, stored,
//!      called by a hand-written file or the entry file (`Input.escaping`) —
//!      has every parameter ⊤, and so does one called with a different
//!      number of arguments than it has parameters. An argument that is a
//!      caller's own parameter takes that parameter's value, so the fact
//!      runs down call chains.
//!   2. **Constant variables.** A `let` or `const`, module-level or local,
//!      whose initialiser is a literal (or folds to one) and which nothing
//!      assigns.
//!
//! The iteration is optimistic (SCCP's): a parameter no call has reached yet
//! is ⊥, and an expression reading one is ⊥ until one does. At the fixpoint a
//! ⊥ parameter belongs to a function no live code calls, and nothing is
//! rewritten from a ⊥.
//!
//! **What is rewritten.** A parameter with a constant is replaced by the
//! constant in its body and dropped, from the function and from every call
//! (its arguments are literals or names, which have no effect). Constant
//! folding follows, exact or nothing — arithmetic whose result is a safe
//! integer, bitwise operators, comparisons, `===`/`!==`, `!`, `typeof`,
//! `&&`/`||` with a literal left side, `c ? a : b` and `if (c)` with a literal
//! `c`: a folded `if` keeps one arm, spliced into its list when no name it
//! declares is declared twice in the declaration, else as a block.
//!
//! **Why the pass rewrites the IR rather than handing the printer a plan.**
//! The spec says a plan; folding makes literals that are in no module's IR
//! and parameter lists that are shorter, and two printers (recursive and
//! iterative) would each have to spend every kind of edit. Patching the
//! lowered IR in place — a node's tag and data, and new ranges appended to
//! `extra` — keeps every node index, so the side tables lowering handed the
//! optimiser (`effect_keep`, `pure_discards`, `unobserved`) stay valid, and
//! `Opt` then plans over the specialised program exactly as it planned over
//! any other. Nothing reads the unspecialised IR after this pass.
//!
//! **Determinism** (CLAUDE.md rule 5): modules in module order, statements in
//! IR order, no map is iterated for an answer, and the literals' table is
//! filled in visit order. The result is a function of the IR.
//!
//! **What must not change**: behaviour, exactly. Every rewrite is licensed
//! by a fact alone, and a program the analysis cannot see through is
//! printed as it was.

const std = @import("std");
const Allocator = std.mem.Allocator;
const JsIr = @import("JsIr.zig");

const Node = JsIr.Node;
const Index = Node.Index;
const NameIndex = JsIr.NameIndex;
const ExtraIndex = JsIr.ExtraIndex;

pub const none: u32 = std.math.maxInt(u32);

/// One lowered module. `ir` is rewritten in place; `global` maps each of its
/// names to a whole-program id (`none` for a local).
pub const Module = struct {
    ir: *JsIr,
    global: []const u32,
};

pub const Input = struct {
    modules: []const Module,
    /// How many whole-program ids `Module.global` uses.
    globals: u32,
    /// Whole-program names some file the pass cannot see reads or calls:
    /// the entry file's `main`, `run`, `start` and `flush`, and what the
    /// markup runtime imports from the runtime module.
    escaping: []const u32,
};

/// How many rounds of facts-then-rewrite the pass takes at most. Each round
/// is sound on its own; a later one only finds more (a dropped call site
/// can make a parameter constant).
const max_rounds = 4;
/// How many sweeps one round's fixpoint may take before the round gives up
/// and rewrites nothing: stopping short of the fixpoint would be unsound,
/// declining is not.
const max_sweeps = 24;
/// How deep a statement nesting the rewriting walk follows by recursion.
const max_depth = 200;

pub fn run(gpa: Allocator, arena: Allocator, in: Input) Allocator.Error!void {
    var s: Spec = try .init(gpa, arena, in);
    var round: u32 = 0;
    while (round < max_rounds) : (round += 1) {
        if (!try s.analyse()) break;
        const rewrote = try s.rewrite();
        // Slice 2: what no longer has a reference goes, and with it the
        // calls and assignments it made, which the next round's facts no
        // longer see.
        const pruned = try s.prune();
        if (!rewrote and !pruned) break;
    }
    try s.finish();
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

const Kind = enum(u8) { number, string, true_lit, false_lit, null_lit, undefined_lit };

/// A literal, interned: `Spec.lits` holds its kind and bytes.
const Lit = struct {
    kind: Kind,
    bytes: []const u8 = "",
};

/// The lattice: ⊥ (nothing yet), one literal, or ⊤.
const Lat = packed struct(u32) {
    state: State,
    lit: u30 = 0,

    const State = enum(u2) { bot, lit, top };
    const bot: Lat = .{ .state = .bot };
    const top: Lat = .{ .state = .top };

    fn of(id: u32) Lat {
        return .{ .state = .lit, .lit = @intCast(id) };
    }

    fn eql(a: Lat, b: Lat) bool {
        return a.state == b.state and (a.state != .lit or a.lit == b.lit);
    }

    fn join(a: Lat, b: Lat) Lat {
        return switch (a.state) {
            .bot => b,
            .top => top,
            .lit => switch (b.state) {
                .bot => a,
                .top => top,
                .lit => if (a.lit == b.lit) a else top,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// The pass
// ---------------------------------------------------------------------------

/// A top-level declaration of some module, by its whole-program name.
const Decl = struct {
    module: u32,
    stmt: Index,
    /// The function's record when it is one the pass tracks: a top-level
    /// `const` of a plain arrow, or a top-level `function`.
    func: ?ExtraIndex = null,
    /// Where its parameters' facts start in `Spec.params`.
    params: u32 = 0,
    arity: u32 = 0,
};

/// One module's working state for the round: the IR's growable columns,
/// and the per-name tables of the top-level declaration being walked.
const Mod = struct {
    ir: *JsIr,
    global: []const u32,
    extra: std.ArrayList(u32),
    string_bytes: std.ArrayList(u8),
    /// Per node: the value the evaluating walk computed.
    memo: []Lat,
    /// Per literal node: its literal's id, once looked up.
    lit_of: []u32,
    /// Per name, valid when `stamp` is the current declaration's.
    stamp: []u32,
    decls: []u32,
    uses: []u32,
    assigned: []bool,
    value: []Lat,
    /// The parameter position of the top-level function, or `none`.
    param: []u32,
    /// Per literal id: its offset in `string_bytes`, once appended.
    lit_at: std.ArrayList(u32) = .empty,

    /// The whole-program id of `n`, or null for a local.
    fn globalOf(m: *const Mod, n: NameIndex) ?u32 {
        const i = n.unwrap() orelse return null;
        if (i >= m.global.len) return null;
        const g = m.global[i];
        return if (g == none) null else g;
    }

    fn setNode(m: *Mod, node: Index, tag: Node.Tag, lhs: u32, rhs: u32) void {
        m.ir.nodes.items(.tag)[node.int()] = tag;
        m.ir.nodes.items(.data)[node.int()] = .{ .lhs = lhs, .rhs = rhs };
    }

    fn setData(m: *Mod, node: Index, lhs: u32, rhs: u32) void {
        m.ir.nodes.items(.data)[node.int()] = .{ .lhs = lhs, .rhs = rhs };
    }

    /// Make `node` what `from` is: same tag and operands. Every operand is
    /// an index, so the two nodes now share their children; `from` itself
    /// is no longer reached from anywhere but `node`.
    fn copyNode(m: *Mod, node: Index, from: Index) void {
        const d = m.ir.data(from);
        m.setNode(node, m.ir.tag(from), d.lhs, d.rhs);
    }

    /// Append `words` to `extra`, keeping the IR's view of it current.
    fn append(m: *Mod, gpa: Allocator, words: []const u32) Allocator.Error!u32 {
        const at: u32 = @intCast(m.extra.items.len);
        try m.extra.appendSlice(gpa, words);
        m.ir.extra = m.extra.items;
        return at;
    }
};

const Spec = struct {
    gpa: Allocator,
    arena: Allocator,
    in: Input,
    mods: []Mod,
    /// Per whole-program id.
    decl: []?Decl,
    /// Used as a value, escaping, or called with another arity: every
    /// parameter ⊤.
    escaped: []bool,
    assigned: []bool,
    /// Reads of each whole-program name, for the substitution rule.
    reads: []u32,
    params: std.ArrayList(Lat) = .empty,
    lits: std.ArrayList(Lit) = .empty,
    lit_ids: std.StringHashMapUnmanaged(u32) = .empty,
    key: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Frame) = .empty,
    /// `countExpr`'s stack, shared by the walks it nests: each owns the
    /// entries above the length it found.
    names: std.ArrayList(Index) = .empty,
    /// `eval`'s children of one node, between `pushOperands` and the stack.
    children: std.ArrayList(Index) = .empty,
    /// The declaration the walk is in, and the counter its stamps use.
    current: u32 = 0,
    top_func: ?Decl = null,
    changed: bool = false,
    /// Whether this sweep counts the reads of whole-program names: the
    /// first of a round only, so that `reads` is a count and not a
    /// multiple of one.
    counting: bool = false,

    const Frame = struct { node: Index, post: bool };

    fn init(gpa: Allocator, arena: Allocator, in: Input) Allocator.Error!Spec {
        const mods = try arena.alloc(Mod, in.modules.len);
        for (mods, in.modules) |*m, src| {
            const ir = src.ir;
            m.* = .{
                .ir = ir,
                .global = src.global,
                .extra = .{ .items = @constCast(ir.extra), .capacity = ir.extra.len },
                .string_bytes = .{ .items = @constCast(ir.string_bytes), .capacity = ir.string_bytes.len },
                .memo = try arena.alloc(Lat, ir.nodes.len),
                .lit_of = try arena.alloc(u32, ir.nodes.len),
                .stamp = try arena.alloc(u32, ir.names.len),
                .decls = try arena.alloc(u32, ir.names.len),
                .uses = try arena.alloc(u32, ir.names.len),
                .assigned = try arena.alloc(bool, ir.names.len),
                .value = try arena.alloc(Lat, ir.names.len),
                .param = try arena.alloc(u32, ir.names.len),
            };
            @memset(m.stamp, 0);
            @memset(m.lit_of, none);
        }
        const s: Spec = .{
            .gpa = gpa,
            .arena = arena,
            .in = in,
            .mods = mods,
            .decl = try arena.alloc(?Decl, in.globals),
            .escaped = try arena.alloc(bool, in.globals),
            .assigned = try arena.alloc(bool, in.globals),
            .reads = try arena.alloc(u32, in.globals),
        };
        return s;
    }

    /// Hand every module its columns back, owned and exactly sized.
    fn finish(s: *Spec) Allocator.Error!void {
        for (s.mods) |*m| {
            m.ir.extra = try m.extra.toOwnedSlice(s.gpa);
            m.ir.string_bytes = try m.string_bytes.toOwnedSlice(s.gpa);
        }
    }

    // ---- Literals -----------------------------------------------------------

    fn intern(s: *Spec, lit: Lit) Allocator.Error!u32 {
        // The key is the kind's byte and the bytes, built in a buffer the
        // lookups share; only a new literal's key is kept.
        s.key.clearRetainingCapacity();
        try s.key.append(s.arena, @intFromEnum(lit.kind));
        try s.key.appendSlice(s.arena, lit.bytes);
        if (s.lit_ids.get(s.key.items)) |id| return id;
        const key = try s.arena.dupe(u8, s.key.items);
        const id: u32 = @intCast(s.lits.items.len);
        try s.lits.append(s.arena, .{ .kind = lit.kind, .bytes = key[1..] });
        try s.lit_ids.put(s.arena, key, id);
        return id;
    }

    fn litOf(s: *Spec, v: Lat) Lit {
        return s.lits.items[v.lit];
    }

    fn boolean(s: *Spec, b: bool) Allocator.Error!Lat {
        return .of(try s.intern(.{ .kind = if (b) .true_lit else .false_lit }));
    }

    fn number(s: *Spec, x: f64) Allocator.Error!Lat {
        if (!exactInteger(x)) return .top;
        var buf: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intFromFloat(x))}) catch return .top;
        return .of(try s.intern(.{ .kind = .number, .bytes = text }));
    }

    /// The printed length of a literal, for the substitution rule.
    fn printedLen(lit: Lit) usize {
        return switch (lit.kind) {
            .number => lit.bytes.len,
            .string => lit.bytes.len + 2,
            .true_lit => 4,
            .false_lit => 5,
            .null_lit => 4,
            .undefined_lit => 9,
        };
    }

    // ---- The analysis --------------------------------------------------------

    /// Facts 1 and 2 to their fixpoint. False when the fixpoint was not
    /// reached, and the round must rewrite nothing.
    fn analyse(s: *Spec) Allocator.Error!bool {
        @memset(s.decl, null);
        @memset(s.escaped, false);
        @memset(s.assigned, false);
        @memset(s.reads, 0);
        s.params.clearRetainingCapacity();
        for (s.in.escaping) |g| if (g < s.escaped.len) {
            s.escaped[g] = true;
        };
        // Every top-level declaration, by its whole-program name.
        for (s.mods, 0..) |*m, mi| {
            const ir = m.ir;
            for (ir.extraSlice(ir.body, Index)) |stmt| {
                const d = ir.data(stmt);
                const n: NameIndex = switch (ir.tag(stmt)) {
                    .const_decl, .let_decl, .func_decl, .gen_decl => @enumFromInt(d.lhs),
                    else => continue,
                };
                const g = m.globalOf(n) orelse continue;
                // Two declarations of one name: nothing is concluded about it.
                if (s.decl[g] != null) {
                    s.escaped[g] = true;
                    s.assigned[g] = true;
                    continue;
                }
                var decl: Decl = .{ .module = @intCast(mi), .stmt = stmt };
                const record: ?ExtraIndex = switch (ir.tag(stmt)) {
                    .const_decl => if (ir.tag(@enumFromInt(d.rhs)) == .arrow and ir.data(@enumFromInt(d.rhs)).rhs == Node.arrow_plain)
                        @enumFromInt(ir.data(@enumFromInt(d.rhs)).lhs)
                    else
                        null,
                    .func_decl => @enumFromInt(d.rhs),
                    else => null,
                };
                if (record) |r| {
                    const f = ir.extraData(r, JsIr.Func);
                    decl.func = r;
                    decl.params = @intCast(s.params.items.len);
                    decl.arity = f.params().len();
                    try s.params.appendNTimes(s.arena, .bot, decl.arity);
                }
                s.decl[g] = decl;
            }
        }
        var sweep: u32 = 0;
        while (sweep < max_sweeps) : (sweep += 1) {
            s.changed = false;
            s.counting = sweep == 0;
            try s.walkAll();
            if (!s.changed) return true;
        }
        return false;
    }

    fn walkAll(s: *Spec) Allocator.Error!void {
        for (s.mods, 0..) |*m, mi| {
            for (m.ir.extraSlice(m.ir.body, Index)) |stmt| try s.walkTop(m, @intCast(mi), stmt);
        }
    }

    /// One top-level statement: its names counted, then its values.
    fn walkTop(s: *Spec, m: *Mod, mi: u32, stmt: Index) Allocator.Error!void {
        const ir = m.ir;
        s.current += 1;
        s.top_func = null;
        // The declaration's own function, whose parameters are tracked.
        switch (ir.tag(stmt)) {
            .const_decl, .func_decl => if (m.globalOf(@enumFromInt(ir.data(stmt).lhs))) |g| {
                if (s.decl[g]) |d| if (d.func != null and d.module == mi and d.stmt == stmt) {
                    s.top_func = d;
                };
            },
            else => {},
        }
        try s.count(m, stmt);
        if (s.top_func) |d| {
            const f = ir.extraData(d.func.?, JsIr.Func);
            for (ir.extraSlice(f.params(), NameIndex), 0..) |n, i| {
                const at = n.unwrap() orelse continue;
                if (m.decls[at] == 1) m.param[at] = @intCast(i);
            }
        }
        try s.evalStmt(m, mi, stmt);
    }

    // ---- Counting: declarations, reads and assignments of names --------------

    fn touch(s: *Spec, m: *Mod, i: u32) void {
        if (m.stamp[i] == s.current) return;
        m.stamp[i] = s.current;
        m.decls[i] = 0;
        m.uses[i] = 0;
        m.assigned[i] = false;
        m.value[i] = .top;
        m.param[i] = none;
    }

    fn declare(s: *Spec, m: *Mod, n: NameIndex) void {
        const i = n.unwrap() orelse return;
        if (i >= m.stamp.len) return;
        s.touch(m, i);
        m.decls[i] += 1;
    }

    fn count(s: *Spec, m: *Mod, stmt: Index) Allocator.Error!void {
        const ir = m.ir;
        const d = ir.data(stmt);
        switch (ir.tag(stmt)) {
            .import_stmt, .export_stmt => {},
            .const_decl => {
                s.declare(m, @enumFromInt(d.lhs));
                try s.countExpr(m, @enumFromInt(d.rhs));
            },
            .let_decl => {
                s.declare(m, @enumFromInt(d.lhs));
                if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| try s.countExpr(m, v);
            },
            .func_decl, .gen_decl => {
                s.declare(m, @enumFromInt(d.lhs));
                try s.countFunc(m, @enumFromInt(d.rhs));
            },
            .assign_stmt => {
                const target: Index = @enumFromInt(d.lhs);
                if (ir.tag(target) == .ident) {
                    const n: NameIndex = @enumFromInt(ir.data(target).lhs);
                    if (m.globalOf(n)) |g| {
                        s.assigned[g] = true;
                    } else if (n.unwrap()) |i| if (i < m.stamp.len) {
                        s.touch(m, i);
                        m.assigned[i] = true;
                    };
                } else try s.countExpr(m, target);
                try s.countExpr(m, @enumFromInt(d.rhs));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| try s.countExpr(m, v),
            .if_stmt => {
                try s.countExpr(m, @enumFromInt(d.lhs));
                const branches = ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                try s.countList(m, branches.thenBody());
                try s.countList(m, branches.elseBody());
            },
            .while_true, .block_stmt => {
                s.declare(m, @enumFromInt(d.lhs));
                try s.countList(m, ir.subRange(@enumFromInt(d.rhs)));
            },
            .for_of => {
                const f = ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                s.declare(m, @enumFromInt(d.lhs));
                try s.countExpr(m, f.iterable);
                try s.countList(m, f.body());
            },
            .break_stmt, .continue_stmt => {},
            .switch_stmt => {
                try s.countExpr(m, @enumFromInt(d.lhs));
                for (ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index)) |c| try s.count(m, c);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| try s.countExpr(m, t);
                try s.countList(m, ir.subRange(@enumFromInt(d.rhs)));
            },
            .expr_stmt, .throw_stmt => try s.countExpr(m, @enumFromInt(d.lhs)),
            else => {},
        }
    }

    fn countList(s: *Spec, m: *Mod, range: JsIr.SubRange) Allocator.Error!void {
        for (m.ir.extraSlice(range, Index)) |stmt| try s.count(m, stmt);
    }

    fn countFunc(s: *Spec, m: *Mod, record: ExtraIndex) Allocator.Error!void {
        const f = m.ir.extraData(record, JsIr.Func);
        for (m.ir.extraSlice(f.params(), NameIndex)) |n| s.declare(m, n);
        try s.countList(m, f.body());
    }

    /// Reads of names, and the uses of whole-program names that are not a
    /// call's callee: those make a function's parameters ⊤.
    fn countExpr(s: *Spec, m: *Mod, root: Index) Allocator.Error!void {
        const ir = m.ir;
        const stack = &s.names;
        const base = stack.items.len;
        defer stack.shrinkRetainingCapacity(base);
        try stack.append(s.arena, root);
        while (stack.items.len > base) {
            const node = JsIr.popOperand(stack).?;
            switch (ir.tag(node)) {
                .ident => try s.read(m, @enumFromInt(ir.data(node).lhs), false),
                .arrow => try s.countFunc(m, @enumFromInt(ir.data(node).lhs)),
                .call => {
                    const d = ir.data(node);
                    const callee: Index = @enumFromInt(d.lhs);
                    for (ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index)) |a| try stack.append(s.arena, a);
                    if (ir.tag(callee) == .ident) {
                        try s.read(m, @enumFromInt(ir.data(callee).lhs), true);
                    } else try stack.append(s.arena, callee);
                },
                else => try ir.pushOperands(s.arena, stack, node),
            }
        }
    }

    fn read(s: *Spec, m: *Mod, n: NameIndex, callee: bool) Allocator.Error!void {
        if (m.globalOf(n)) |g| {
            if (s.counting) s.reads[g] +|= 1;
            if (!callee) s.escaped[g] = true;
            return;
        }
        const i = n.unwrap() orelse return;
        if (i >= m.stamp.len) return;
        s.touch(m, i);
        m.uses[i] += 1;
    }

    // ---- Evaluating: every expression's value, and the calls' arguments ------

    fn evalStmt(s: *Spec, m: *Mod, mi: u32, stmt: Index) Allocator.Error!void {
        const ir = m.ir;
        const d = ir.data(stmt);
        switch (ir.tag(stmt)) {
            .import_stmt, .export_stmt => {},
            .const_decl, .let_decl => {
                const n: NameIndex = @enumFromInt(d.lhs);
                const rhs: Node.OptionalIndex = if (ir.tag(stmt) == .const_decl) @enumFromInt(d.rhs) else @enumFromInt(d.rhs);
                const v: Lat = if (rhs.unwrap()) |r| try s.eval(m, mi, r) else .top;
                if (m.globalOf(n) == null) if (n.unwrap()) |i| if (i < m.stamp.len) {
                    s.touch(m, i);
                    if (m.decls[i] == 1 and !m.assigned[i]) m.value[i] = v;
                };
            },
            .func_decl, .gen_decl => try s.evalFunc(m, mi, @enumFromInt(d.rhs)),
            .assign_stmt => {
                const target: Index = @enumFromInt(d.lhs);
                if (ir.tag(target) != .ident) _ = try s.eval(m, mi, target);
                _ = try s.eval(m, mi, @enumFromInt(d.rhs));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| {
                _ = try s.eval(m, mi, v);
            },
            .if_stmt => {
                _ = try s.eval(m, mi, @enumFromInt(d.lhs));
                const branches = ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                try s.evalList(m, mi, branches.thenBody());
                try s.evalList(m, mi, branches.elseBody());
            },
            .while_true, .block_stmt => try s.evalList(m, mi, ir.subRange(@enumFromInt(d.rhs))),
            .for_of => {
                const f = ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                _ = try s.eval(m, mi, f.iterable);
                try s.evalList(m, mi, f.body());
            },
            .switch_stmt => {
                _ = try s.eval(m, mi, @enumFromInt(d.lhs));
                for (ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index)) |c| try s.evalStmt(m, mi, c);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| _ = try s.eval(m, mi, t);
                try s.evalList(m, mi, ir.subRange(@enumFromInt(d.rhs)));
            },
            .expr_stmt, .throw_stmt => _ = try s.eval(m, mi, @enumFromInt(d.lhs)),
            else => {},
        }
    }

    fn evalList(s: *Spec, m: *Mod, mi: u32, range: JsIr.SubRange) Allocator.Error!void {
        for (m.ir.extraSlice(range, Index)) |stmt| try s.evalStmt(m, mi, stmt);
    }

    fn evalFunc(s: *Spec, m: *Mod, mi: u32, record: ExtraIndex) Allocator.Error!void {
        try s.evalList(m, mi, m.ir.extraData(record, JsIr.Func).body());
    }

    /// The value of `root`, bottom-up over an explicit stack, every node's
    /// into `memo`. An arrow's body is walked as the statements it is.
    fn eval(s: *Spec, m: *Mod, mi: u32, root: Index) Allocator.Error!Lat {
        const ir = m.ir;
        const base = s.stack.items.len;
        defer s.stack.shrinkRetainingCapacity(base);
        try s.stack.append(s.arena, .{ .node = root, .post = false });
        const children = &s.children;
        while (s.stack.items.len > base) {
            const f = s.stack.pop().?;
            if (!f.post) {
                switch (ir.tag(f.node)) {
                    .arrow => {
                        m.memo[f.node.int()] = .top;
                        try s.evalFunc(m, mi, @enumFromInt(ir.data(f.node).lhs));
                        continue;
                    },
                    else => {},
                }
                try s.stack.append(s.arena, .{ .node = f.node, .post = true });
                children.clearRetainingCapacity();
                try ir.pushOperands(s.arena, children, f.node);
                for (children.items) |c| try s.stack.append(s.arena, .{ .node = c, .post = false });
                continue;
            }
            m.memo[f.node.int()] = try s.combine(m, f.node);
        }
        return m.memo[root.int()];
    }

    fn combine(s: *Spec, m: *Mod, node: Index) Allocator.Error!Lat {
        const ir = m.ir;
        const d = ir.data(node);
        return switch (ir.tag(node)) {
            .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => s.literalValue(m, node),
            .ident => s.nameValue(m, @enumFromInt(d.lhs)),
            .unary => try s.unary(@enumFromInt(d.rhs), m.memo[d.lhs]),
            .binary => blk: {
                const b = ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
                break :blk try s.binary(@enumFromInt(d.rhs), m.memo[b.left.int()], m.memo[b.right.int()]);
            },
            .cond => blk: {
                const c = ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
                const t = m.memo[d.lhs];
                break :blk switch (t.state) {
                    .bot => .bot,
                    .top => .top,
                    .lit => switch (s.truthy(s.litOf(t))) {
                        .yes => m.memo[c.consequent.int()],
                        .no => m.memo[c.alternate.int()],
                        .unknown => .top,
                    },
                };
            },
            .call => blk: {
                try s.callSite(m, node);
                break :blk .top;
            },
            else => .top,
        };
    }

    /// A call: its arguments join the parameters of the function it names.
    fn callSite(s: *Spec, m: *Mod, node: Index) Allocator.Error!void {
        const ir = m.ir;
        const d = ir.data(node);
        const callee: Index = @enumFromInt(d.lhs);
        if (ir.tag(callee) != .ident) return;
        const g = m.globalOf(@enumFromInt(ir.data(callee).lhs)) orelse return;
        const decl = s.decl[g] orelse return;
        if (decl.func == null) return;
        const args = ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index);
        if (args.len != decl.arity) {
            s.escaped[g] = true;
            return;
        }
        for (args, 0..) |a, i| {
            const slot = &s.params.items[decl.params + i];
            const joined = slot.join(m.memo[a.int()]);
            if (!joined.eql(slot.*)) {
                slot.* = joined;
                s.changed = true;
            }
        }
    }

    /// What reading `n` gives, from the facts.
    fn nameValue(s: *Spec, m: *Mod, n: NameIndex) Lat {
        if (m.globalOf(n)) |g| {
            if (s.escaped[g] and s.decl[g] != null and s.decl[g].?.func != null) return .top;
            if (s.assigned[g]) return .top;
            const decl = s.decl[g] orelse return .top;
            const dm = &s.mods[decl.module];
            const d = dm.ir.data(decl.stmt);
            const value: Index = switch (dm.ir.tag(decl.stmt)) {
                .const_decl => @enumFromInt(d.rhs),
                .let_decl => (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap() orelse return .top),
                else => return .top,
            };
            return s.literalValue(dm, value) catch .top;
        }
        const i = n.unwrap() orelse return .top;
        if (i >= m.stamp.len or m.stamp[i] != s.current) return .top;
        if (m.decls[i] != 1 or m.assigned[i]) return .top;
        if (m.param[i] != none) {
            const f = s.top_func orelse return .top;
            if (s.escaped[s.globalOfDecl(f)]) return .top;
            return s.params.items[f.params + m.param[i]];
        }
        return m.value[i];
    }

    fn globalOfDecl(s: *Spec, d: Decl) u32 {
        const m = &s.mods[d.module];
        return m.globalOf(@enumFromInt(m.ir.data(d.stmt).lhs)).?;
    }

    /// A literal node's value; ⊤ for anything else. A module-level
    /// constant is only ever a literal as written: its initialiser's value
    /// is not re-derived across modules.
    fn literalValue(s: *Spec, m: *Mod, node: Index) Allocator.Error!Lat {
        const ir = m.ir;
        const kind: Kind = switch (ir.tag(node)) {
            .number => .number,
            .string => .string,
            .true_lit => .true_lit,
            .false_lit => .false_lit,
            .null_lit => .null_lit,
            .undefined_lit => .undefined_lit,
            else => return .top,
        };
        // A literal node stays the literal it is (the rewrite replaces only
        // nodes that are not), so its id is looked up once.
        const cached = &m.lit_of[node.int()];
        if (cached.* == none) cached.* = try s.intern(.{
            .kind = kind,
            .bytes = if (kind == .number or kind == .string) ir.bytes(node) else "",
        });
        return .of(cached.*);
    }

    // ---- Folding: exact or nothing ------------------------------------------

    const Truth = enum { yes, no, unknown };

    fn truthy(s: *Spec, lit: Lit) Truth {
        _ = s;
        return switch (lit.kind) {
            .true_lit => .yes,
            .false_lit, .null_lit, .undefined_lit => .no,
            .string => if (lit.bytes.len != 0) .yes else .no,
            .number => {
                const x = parseNumber(lit.bytes) orelse return .unknown;
                return if (x != 0 and !std.math.isNan(x)) .yes else .no;
            },
        };
    }

    fn unary(s: *Spec, op: JsIr.UnaryOp, a: Lat) Allocator.Error!Lat {
        if (a.state != .lit) return a;
        const lit = s.litOf(a);
        switch (op) {
            .not => return switch (s.truthy(lit)) {
                .yes => s.boolean(false),
                .no => s.boolean(true),
                .unknown => .top,
            },
            .neg => {
                if (lit.kind != .number) return .top;
                const x = parseNumber(lit.bytes) orelse return .top;
                if (x == 0) return .top; // -0
                return s.number(-x);
            },
            .type_of => {
                const text: []const u8 = switch (lit.kind) {
                    .number => "number",
                    .string => "string",
                    .true_lit, .false_lit => "boolean",
                    .null_lit => "object",
                    .undefined_lit => "undefined",
                };
                return .of(try s.intern(.{ .kind = .string, .bytes = text }));
            },
            .yield => return .top,
        }
    }

    fn binary(s: *Spec, op: JsIr.BinaryOp, a: Lat, b: Lat) Allocator.Error!Lat {
        switch (op) {
            .logical_and, .logical_or => {
                if (a.state != .lit) return a;
                const t = s.truthy(s.litOf(a));
                if (t == .unknown) return .top;
                const left_wins = (op == .logical_and) == (t == .no);
                return if (left_wins) a else b;
            },
            else => {},
        }
        if (a.state == .bot or b.state == .bot) return .bot;
        if (a.state != .lit or b.state != .lit) return .top;
        const x = s.litOf(a);
        const y = s.litOf(b);
        switch (op) {
            .strict_eq, .strict_ne => {
                const eq = strictEquals(x, y) orelse return .top;
                return s.boolean(if (op == .strict_eq) eq else !eq);
            },
            .loose_eq => {
                const xn = x.kind == .null_lit or x.kind == .undefined_lit;
                const yn = y.kind == .null_lit or y.kind == .undefined_lit;
                if (xn or yn) return s.boolean(xn and yn);
                if (sameType(x, y)) return s.boolean(strictEquals(x, y) orelse return .top);
                return .top;
            },
            .add => {
                if (x.kind == .string and y.kind == .string) {
                    if (x.bytes.len + y.bytes.len > 64) return .top;
                    const joined = try std.mem.concat(s.arena, u8, &.{ x.bytes, y.bytes });
                    return .of(try s.intern(.{ .kind = .string, .bytes = joined }));
                }
            },
            else => {},
        }
        if (x.kind == .string and y.kind == .string) switch (op) {
            .lt, .le, .gt, .ge => {
                if (!ascii(x.bytes) or !ascii(y.bytes)) return .top;
                const order = std.mem.order(u8, x.bytes, y.bytes);
                return s.boolean(switch (op) {
                    .lt => order == .lt,
                    .le => order != .gt,
                    .gt => order == .gt,
                    .ge => order != .lt,
                    else => unreachable,
                });
            },
            else => return .top,
        };
        if (x.kind != .number or y.kind != .number) return .top;
        const p = parseNumber(x.bytes) orelse return .top;
        const q = parseNumber(y.bytes) orelse return .top;
        return switch (op) {
            .add => s.number(p + q),
            .sub => s.number(p - q),
            .mul => s.number(p * q),
            .div => if (q == 0) .top else s.number(p / q),
            .rem => if (q == 0) .top else s.number(@rem(p, q)),
            .lt => s.boolean(p < q),
            .le => s.boolean(p <= q),
            .gt => s.boolean(p > q),
            .ge => s.boolean(p >= q),
            .bit_and => s.number(@floatFromInt(toInt32(p) & toInt32(q))),
            .bit_or => s.number(@floatFromInt(toInt32(p) | toInt32(q))),
            .bit_xor => s.number(@floatFromInt(toInt32(p) ^ toInt32(q))),
            .shl => s.number(@floatFromInt(toInt32(p) << @intCast(toUint32(q) & 31))),
            .sar => s.number(@floatFromInt(toInt32(p) >> @intCast(toUint32(q) & 31))),
            .shr => s.number(@floatFromInt(toUint32(p) >> @intCast(toUint32(q) & 31))),
            .pow, .logical_and, .logical_or, .strict_eq, .strict_ne, .loose_eq => .top,
        };
    }

    // ---- The rewrite ----------------------------------------------------------

    /// Spend the facts. True when anything changed, so another round may
    /// find more.
    fn rewrite(s: *Spec) Allocator.Error!bool {
        var any = false;
        s.counting = false;
        // Which parameters go: a constant the substitution rule allows.
        const drop = try s.arena.alloc(bool, s.params.items.len);
        @memset(drop, false);
        for (s.decl, 0..) |maybe, g| {
            const decl = maybe orelse continue;
            if (decl.func == null or s.escaped[g]) continue;
            const m = &s.mods[decl.module];
            const f = m.ir.extraData(decl.func.?, JsIr.Func);
            // Counted afresh: the parameters' reads and whether one is
            // assigned.
            s.current += 1;
            try s.count(m, decl.stmt);
            for (m.ir.extraSlice(f.params(), NameIndex), 0..) |n, i| {
                const v = s.params.items[decl.params + i];
                if (v.state != .lit) continue;
                const at = n.unwrap() orelse continue;
                if (m.decls[at] != 1 or m.assigned[at]) continue;
                if (!substitutes(s.litOf(v), m.uses[at])) continue;
                drop[decl.params + i] = true;
            }
        }

        // `memo` holds one declaration's values only while it is walked, so
        // each declaration is walked again, with the facts at their fixpoint,
        // just before it is patched.
        for (s.mods, 0..) |*m, mi| {
            const body = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.body, Index));
            for (body) |stmt| {
                try s.walkTop(m, @intCast(mi), stmt);
                if (try s.patchStmt(m, stmt)) any = true;
                // The `if`s whose test is now a literal, while the
                // declaration's counts are the ones `spliceable` reads.
                if (try s.foldBelow(m, stmt, 0)) any = true;
            }
        }
        // Parameters and arguments.
        for (s.decl) |maybe| {
            const decl = maybe orelse continue;
            if (decl.func == null) continue;
            const flags = drop[decl.params..][0..decl.arity];
            if (std.mem.indexOfScalar(bool, flags, true) == null) continue;
            const m = &s.mods[decl.module];
            const f = m.ir.extraData(decl.func.?, JsIr.Func);
            var kept: std.ArrayList(u32) = .empty;
            for (m.ir.extraSlice(f.params(), u32), flags) |n, gone| if (!gone) try kept.append(s.arena, n);
            const start = try m.append(s.gpa, kept.items);
            const at = @intFromEnum(decl.func.?);
            m.extra.items[at] = start;
            m.extra.items[at + 1] = start + @as(u32, @intCast(kept.items.len));
            any = true;
        }
        // Every call of such a function the patched program still makes. Found
        // by walking it again rather than from the analysis's list: a folded
        // conditional may have become a copy of a call, and the copy is the
        // one that is reached.
        for (s.mods) |*m| try s.rewriteCalls(m, drop);
        return any;
    }

    /// Drop the arguments of the dropped parameters from every call `m`
    /// reaches. Each call node once, whatever reaches it twice; a new
    /// argument list for each, so a list two nodes share is never cut twice.
    // ---- Slice 2: reachability again, over the specialised program ----------

    /// Drop every top-level declaration nothing live refers to any more,
    /// when evaluating it could do nothing, and every `import` and `export`
    /// of a name that went or that nothing reads. True when anything went.
    ///
    /// The roots are every other top-level statement — a declaration whose
    /// initialiser may do something when evaluated is kept whether or not it
    /// is read, as `Reach` keeps it — and the names `Input.escaping` lists.
    fn prune(s: *Spec) Allocator.Error!bool {
        const referenced = try s.arena.alloc(bool, s.in.globals);
        @memset(referenced, false);
        const live = try s.arena.alloc(bool, s.in.globals);
        @memset(live, false);
        var work: std.ArrayList(u32) = .empty;
        for (s.in.escaping) |g| if (g < referenced.len) {
            referenced[g] = true;
            try work.append(s.arena, g);
        };
        for (s.mods) |*m| {
            for (m.ir.extraSlice(m.ir.body, Index)) |stmt| {
                switch (m.ir.tag(stmt)) {
                    .import_stmt, .export_stmt => continue,
                    else => {},
                }
                if (s.candidate(m, stmt) != null) continue;
                try s.references(m, stmt, referenced, &work);
            }
        }
        while (work.pop()) |g| {
            const decl = s.decl[g] orelse continue;
            if (live[g]) continue;
            live[g] = true;
            const m = &s.mods[decl.module];
            try s.references(m, decl.stmt, referenced, &work);
        }

        var any = false;
        for (s.mods) |*m| {
            var kept: std.ArrayList(u32) = .empty;
            var dropped = false;
            const body = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.body, Index));
            for (body) |stmt| {
                if (s.candidate(m, stmt)) |g| if (!live[g]) {
                    dropped = true;
                    continue;
                };
                const d = m.ir.data(stmt);
                switch (m.ir.tag(stmt)) {
                    .import_stmt => {
                        const at = d.lhs;
                        const imp = m.ir.extraData(@enumFromInt(at), JsIr.Import);
                        const specs = m.ir.extraSlice(imp.specs(), JsIr.Specifier);
                        var out: std.ArrayList(u32) = .empty;
                        for (specs) |spec| {
                            if (m.globalOf(spec.local)) |g| if (!referenced[g]) continue;
                            try out.appendSlice(s.arena, &.{ @intFromEnum(spec.imported), @intFromEnum(spec.local) });
                        }
                        if (out.items.len != specs.len * JsIr.Specifier.words) {
                            const start = try m.append(s.gpa, out.items);
                            m.extra.items[at + 2] = start;
                            m.extra.items[at + 3] = start + @as(u32, @intCast(out.items.len));
                            any = true;
                        }
                    },
                    .export_stmt => {
                        const names = m.ir.extraSlice(JsIr.inlineRange(d), NameIndex);
                        var out: std.ArrayList(u32) = .empty;
                        for (names) |n| {
                            if (m.globalOf(n)) |g| if (s.decl[g] != null and !live[g]) continue;
                            try out.append(s.arena, @intFromEnum(n));
                        }
                        if (out.items.len != names.len) {
                            const start = try m.append(s.gpa, out.items);
                            m.setData(stmt, start, start + @as(u32, @intCast(out.items.len)));
                            any = true;
                        }
                    },
                    else => {},
                }
                try kept.append(s.arena, @intFromEnum(stmt));
            }
            if (!dropped) continue;
            const start = try m.append(s.gpa, kept.items);
            m.ir.body = .{ .start = @enumFromInt(start), .end = @enumFromInt(start + @as(u32, @intCast(kept.items.len))) };
            any = true;
        }
        return any;
    }

    /// The whole-program name of a top-level declaration that may go when
    /// nothing reads it: its one declaration, of a function or of a value
    /// whose evaluation can do nothing. Null for every other statement.
    fn candidate(s: *Spec, m: *Mod, stmt: Index) ?u32 {
        const ir = m.ir;
        const d = ir.data(stmt);
        const value: ?Index = switch (ir.tag(stmt)) {
            .const_decl => @enumFromInt(d.rhs),
            .let_decl => @as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap(),
            .func_decl, .gen_decl => null,
            else => return null,
        };
        const g = m.globalOf(@enumFromInt(d.lhs)) orelse return null;
        const decl = s.decl[g] orelse return null;
        if (decl.stmt != stmt or &s.mods[decl.module] != m) return null;
        if (value) |v| if (!inert(ir, v)) return null;
        return g;
    }

    /// Every whole-program name `stmt` mentions — read, called or assigned —
    /// marked referenced and queued.
    fn references(s: *Spec, m: *Mod, stmt: Index, referenced: []bool, work: *std.ArrayList(u32)) Allocator.Error!void {
        var stack: std.ArrayList(Index) = .empty;
        defer stack.deinit(s.arena);
        try stack.append(s.arena, stmt);
        while (JsIr.popOperand(&stack)) |node| {
            const ir = m.ir;
            const d = ir.data(node);
            switch (ir.tag(node)) {
                .ident => if (m.globalOf(@enumFromInt(d.lhs))) |g| if (!referenced[g]) {
                    referenced[g] = true;
                    try work.append(s.arena, g);
                },
                .arrow => {
                    const f = ir.extraData(@enumFromInt(d.lhs), JsIr.Func);
                    for (ir.extraSlice(f.body(), Index)) |b| try stack.append(s.arena, b);
                },
                .assign_stmt => {
                    try stack.append(s.arena, @enumFromInt(d.lhs));
                    try stack.append(s.arena, @enumFromInt(d.rhs));
                },
                .import_stmt, .export_stmt => {},
                else => if (ir.tag(node).isStatement())
                    try s.pushStmtExprs(m, node, &stack)
                else
                    try ir.pushOperands(s.arena, &stack, node),
            }
        }
    }

    fn rewriteCalls(s: *Spec, m: *Mod, drop: []const bool) Allocator.Error!void {
        var seen: std.DynamicBitSetUnmanaged = try .initEmpty(s.arena, m.ir.nodes.len);
        var stack: std.ArrayList(Index) = .empty;
        defer stack.deinit(s.arena);
        for (m.ir.extraSlice(m.ir.body, Index)) |stmt| try stack.append(s.arena, stmt);
        while (JsIr.popOperand(&stack)) |node| {
            const ir = m.ir;
            const tag = ir.tag(node);
            if (tag.isStatement()) {
                try s.pushStmtExprs(m, node, &stack);
                continue;
            }
            if (seen.isSet(node.int())) continue;
            seen.set(node.int());
            switch (tag) {
                .arrow => {
                    const f = ir.extraData(@enumFromInt(ir.data(node).lhs), JsIr.Func);
                    for (ir.extraSlice(f.body(), Index)) |b| try stack.append(s.arena, b);
                    continue;
                },
                .call => {
                    const d = ir.data(node);
                    const callee: Index = @enumFromInt(d.lhs);
                    if (ir.tag(callee) == .ident) if (m.globalOf(@enumFromInt(ir.data(callee).lhs))) |g| if (s.decl[g]) |decl| if (decl.func != null) {
                        const flags = drop[decl.params..][0..decl.arity];
                        const args = ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), u32);
                        if (args.len == decl.arity and std.mem.indexOfScalar(bool, flags, true) != null) {
                            var kept: std.ArrayList(u32) = .empty;
                            for (args, flags) |a, gone| if (!gone) try kept.append(s.arena, a);
                            const start = try m.append(s.gpa, kept.items);
                            const record = try m.append(s.gpa, &.{ start, start + @as(u32, @intCast(kept.items.len)) });
                            m.setData(node, d.lhs, record);
                        }
                    };
                },
                else => {},
            }
            try m.ir.pushOperands(s.arena, &stack, node);
        }
    }

    /// Whether a name read `uses` times may be written as `lit` in each
    /// place: a short literal always, a long one only where it is read once.
    fn substitutes(lit: Lit, uses: u32) bool {
        return printedLen(lit) <= 5 or uses <= 1;
    }

    /// Replace, in one top-level statement just walked, every expression
    /// whose value is a literal by the literal, and every conditional whose
    /// test is by the branch it takes.
    fn patchStmt(s: *Spec, m: *Mod, stmt: Index) Allocator.Error!bool {
        var any = false;
        var stack: std.ArrayList(Index) = .empty;
        defer stack.deinit(s.arena);
        try s.pushStmtExprs(m, stmt, &stack);
        while (JsIr.popOperand(&stack)) |node| {
            const ir = m.ir;
            const tag = ir.tag(node);
            if (tag.isStatement()) {
                try s.pushStmtExprs(m, node, &stack);
                continue;
            }
            switch (tag) {
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit, .template_chunk, .global_this => continue,
                .arrow => {
                    const f = ir.extraData(@enumFromInt(ir.data(node).lhs), JsIr.Func);
                    for (ir.extraSlice(f.body(), Index)) |b| try stack.append(s.arena, b);
                    continue;
                },
                else => {},
            }
            const v = m.memo[node.int()];
            if (v.state == .lit and try s.patchLiteral(m, node, v)) {
                any = true;
                continue;
            }
            // A conditional or a logical operator whose left side decides.
            const d = ir.data(node);
            switch (tag) {
                .cond => {
                    const t = m.memo[d.lhs];
                    if (t.state == .lit) {
                        const c = ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
                        const taken: ?Index = switch (s.truthy(s.litOf(t))) {
                            .yes => c.consequent,
                            .no => c.alternate,
                            .unknown => null,
                        };
                        if (taken) |b| {
                            m.copyNode(node, b);
                            m.memo[node.int()] = m.memo[b.int()];
                            try stack.append(s.arena, node);
                            any = true;
                            continue;
                        }
                    }
                },
                .binary => {
                    const op: JsIr.BinaryOp = @enumFromInt(d.rhs);
                    if (op == .logical_and or op == .logical_or) {
                        const b = ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
                        const l = m.memo[b.left.int()];
                        if (l.state == .lit) {
                            const t = s.truthy(s.litOf(l));
                            if (t != .unknown and (op == .logical_and) == (t == .yes)) {
                                m.copyNode(node, b.right);
                                m.memo[node.int()] = m.memo[b.right.int()];
                                try stack.append(s.arena, node);
                                any = true;
                                continue;
                            }
                        }
                    }
                },
                else => {},
            }
            try ir.pushOperands(s.arena, &stack, node);
        }
        return any;
    }

    /// The expressions a statement evaluates, and its nested statements,
    /// onto `stack` — but never an assignment's target name.
    fn pushStmtExprs(s: *Spec, m: *Mod, stmt: Index, stack: *std.ArrayList(Index)) Allocator.Error!void {
        const ir = m.ir;
        const d = ir.data(stmt);
        switch (ir.tag(stmt)) {
            .const_decl => try stack.append(s.arena, @enumFromInt(d.rhs)),
            .let_decl => if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| try stack.append(s.arena, v),
            .func_decl, .gen_decl => {
                const f = ir.extraData(@enumFromInt(d.rhs), JsIr.Func);
                for (ir.extraSlice(f.body(), Index)) |b| try stack.append(s.arena, b);
            },
            .assign_stmt => {
                const target: Index = @enumFromInt(d.lhs);
                if (ir.tag(target) != .ident) try ir.pushOperands(s.arena, stack, target);
                try stack.append(s.arena, @enumFromInt(d.rhs));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| try stack.append(s.arena, v),
            .if_stmt => {
                try stack.append(s.arena, @enumFromInt(d.lhs));
                const branches = ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                for (ir.extraSlice(branches.thenBody(), Index)) |b| try stack.append(s.arena, b);
                for (ir.extraSlice(branches.elseBody(), Index)) |b| try stack.append(s.arena, b);
            },
            .while_true, .block_stmt, .switch_case => {
                if (ir.tag(stmt) == .switch_case) if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| try stack.append(s.arena, t);
                for (ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index)) |b| try stack.append(s.arena, b);
            },
            .for_of => {
                const f = ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                try stack.append(s.arena, f.iterable);
                for (ir.extraSlice(f.body(), Index)) |b| try stack.append(s.arena, b);
            },
            .switch_stmt => {
                try stack.append(s.arena, @enumFromInt(d.lhs));
                for (ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index)) |c| try stack.append(s.arena, c);
            },
            .expr_stmt, .throw_stmt => try stack.append(s.arena, @enumFromInt(d.lhs)),
            else => {},
        }
    }

    /// Write `node` as the literal `v`, when the rule allows. A name read is
    /// replaced only under `substitutes`; anything else that folded is
    /// written as its value (it is at least as long as the literal, but for
    /// a string that grew by concatenation, which `binary` caps).
    fn patchLiteral(s: *Spec, m: *Mod, node: Index, v: Lat) Allocator.Error!bool {
        const ir = m.ir;
        const lit = s.litOf(v);
        if (ir.tag(node) == .ident) {
            const n: NameIndex = @enumFromInt(ir.data(node).lhs);
            const uses: u32 = if (m.globalOf(n)) |g| s.reads[g] else if (n.unwrap()) |i| (if (i < m.stamp.len and m.stamp[i] == s.current) m.uses[i] else 2) else 2;
            if (!substitutes(lit, uses)) return false;
        }
        switch (lit.kind) {
            .number, .string => {
                if (m.lit_at.items.len <= v.lit) try m.lit_at.appendNTimes(s.arena, none, v.lit + 1 - m.lit_at.items.len);
                const at = &m.lit_at.items[v.lit];
                if (at.* == none) {
                    at.* = @intCast(m.string_bytes.items.len);
                    try m.string_bytes.appendSlice(s.gpa, lit.bytes);
                    m.ir.string_bytes = m.string_bytes.items;
                }
                m.setNode(node, if (lit.kind == .number) .number else .string, at.*, @intCast(lit.bytes.len));
            },
            .true_lit => m.setNode(node, .true_lit, 0, 0),
            .false_lit => m.setNode(node, .false_lit, 0, 0),
            .null_lit => m.setNode(node, .null_lit, 0, 0),
            .undefined_lit => m.setNode(node, .undefined_lit, 0, 0),
        }
        return true;
    }

    /// Fold the `if`s of one statement list whose test is now a literal,
    /// and every list below it. `owner` is where the list's range is
    /// stored: two words of `extra`, or the module body when null.
    fn foldList(s: *Spec, m: *Mod, owner: ?u32, range: JsIr.SubRange, depth: u32) Allocator.Error!bool {
        if (depth > max_depth) return false;
        var any = false;
        // Copied: folding below appends to `extra`, which may move it.
        const items = try s.arena.dupe(u32, m.ir.extraSlice(range, u32));
        // First the lists below, each rewritten in its own owner.
        for (items) |raw| {
            if (try s.foldBelow(m, @enumFromInt(raw), depth)) any = true;
        }
        // Then this one.
        var changed = false;
        for (items) |raw| {
            if (s.decided(m, @enumFromInt(raw)) != null) changed = true;
        }
        if (!changed) return any;
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(s.arena);
        for (items) |raw| {
            const stmt: Index = @enumFromInt(raw);
            const arm = s.decided(m, stmt) orelse {
                try out.append(s.arena, raw);
                continue;
            };
            if (arm.len() == 0) continue;
            if (s.spliceable(m, arm)) {
                try out.appendSlice(s.arena, m.ir.extraSlice(arm, u32));
                continue;
            }
            // A block of its own: the arm declares a name the declaration
            // declares elsewhere too.
            const at = try m.append(s.gpa, &.{ @intFromEnum(arm.start), @intFromEnum(arm.end) });
            m.setNode(stmt, .block_stmt, @intFromEnum(NameIndex.none), at);
            try out.append(s.arena, raw);
        }
        const start = try m.append(s.gpa, out.items);
        const end: u32 = start + @as(u32, @intCast(out.items.len));
        if (owner) |o| {
            m.extra.items[o] = start;
            m.extra.items[o + 1] = end;
        } else {
            m.ir.body = .{ .start = @enumFromInt(start), .end = @enumFromInt(end) };
        }
        return true;
    }

    /// The arm an `if` with a literal test takes, or null.
    fn decided(s: *Spec, m: *Mod, stmt: Index) ?JsIr.SubRange {
        const ir = m.ir;
        if (ir.tag(stmt) != .if_stmt) return null;
        const d = ir.data(stmt);
        const test_node: Index = @enumFromInt(d.lhs);
        const lit: Lit = switch (ir.tag(test_node)) {
            .true_lit => .{ .kind = .true_lit },
            .false_lit => .{ .kind = .false_lit },
            .null_lit => .{ .kind = .null_lit },
            .undefined_lit => .{ .kind = .undefined_lit },
            .number => .{ .kind = .number, .bytes = ir.bytes(test_node) },
            .string => .{ .kind = .string, .bytes = ir.bytes(test_node) },
            else => return null,
        };
        const branches = ir.extraData(@enumFromInt(d.rhs), JsIr.If);
        return switch (s.truthy(lit)) {
            .yes => branches.thenBody(),
            .no => branches.elseBody(),
            .unknown => null,
        };
    }

    /// Whether an arm's statements may join the list around it: no name it
    /// declares at its own level is declared anywhere else in the
    /// declaration, so nothing in the list can come to mean it.
    fn spliceable(s: *Spec, m: *Mod, arm: JsIr.SubRange) bool {
        const ir = m.ir;
        for (ir.extraSlice(arm, Index)) |stmt| {
            const n: NameIndex = switch (ir.tag(stmt)) {
                .const_decl, .let_decl, .func_decl, .gen_decl => @enumFromInt(ir.data(stmt).lhs),
                .while_true, .block_stmt => @enumFromInt(ir.data(stmt).lhs),
                else => continue,
            };
            if (n == .none) continue;
            if (m.globalOf(n) != null) return false;
            const i = n.unwrap() orelse return false;
            if (i >= m.stamp.len or m.stamp[i] != s.current or m.decls[i] != 1) return false;
        }
        return true;
    }

    /// The statement lists below one statement, each folded in its owner.
    fn foldBelow(s: *Spec, m: *Mod, stmt: Index, depth: u32) Allocator.Error!bool {
        const ir = m.ir;
        const d = ir.data(stmt);
        var any = false;
        switch (ir.tag(stmt)) {
            .const_decl => any = try s.foldExprLists(m, @enumFromInt(d.rhs), depth),
            .let_decl => if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| {
                any = try s.foldExprLists(m, v, depth);
            },
            .func_decl, .gen_decl => any = try s.foldFunc(m, @enumFromInt(d.rhs), depth),
            .assign_stmt => {
                if (try s.foldExprLists(m, @enumFromInt(d.lhs), depth)) any = true;
                if (try s.foldExprLists(m, @enumFromInt(d.rhs), depth)) any = true;
            },
            .return_stmt, .expr_stmt, .throw_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| {
                any = try s.foldExprLists(m, v, depth);
            },
            .if_stmt => {
                if (try s.foldExprLists(m, @enumFromInt(d.lhs), depth)) any = true;
                const at = d.rhs;
                const branches = ir.extraData(@enumFromInt(at), JsIr.If);
                if (try s.foldList(m, at, branches.thenBody(), depth + 1)) any = true;
                const again = m.ir.extraData(@enumFromInt(at), JsIr.If);
                if (try s.foldList(m, at + 2, again.elseBody(), depth + 1)) any = true;
            },
            .while_true, .block_stmt, .switch_case => {
                if (ir.tag(stmt) == .switch_case) if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| {
                    if (try s.foldExprLists(m, t, depth)) any = true;
                };
                if (try s.foldList(m, d.rhs, ir.subRange(@enumFromInt(d.rhs)), depth + 1)) any = true;
            },
            .for_of => {
                const f = ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                if (try s.foldExprLists(m, f.iterable, depth)) any = true;
                // The body's range is the record's second and third words.
                if (try s.foldList(m, d.rhs + 1, m.ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf).body(), depth + 1)) any = true;
            },
            .switch_stmt => {
                if (try s.foldExprLists(m, @enumFromInt(d.lhs), depth)) any = true;
                const cases = try s.arena.dupe(Index, ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index));
                for (cases) |c| {
                    if (try s.foldBelow(m, c, depth + 1)) any = true;
                }
            },
            else => {},
        }
        return any;
    }

    fn foldFunc(s: *Spec, m: *Mod, record: ExtraIndex, depth: u32) Allocator.Error!bool {
        const at = @intFromEnum(record);
        return s.foldList(m, at + 2, m.ir.extraData(record, JsIr.Func).body(), depth + 1);
    }

    /// The function bodies inside an expression.
    fn foldExprLists(s: *Spec, m: *Mod, root: Index, depth: u32) Allocator.Error!bool {
        var any = false;
        var stack: std.ArrayList(Index) = .empty;
        defer stack.deinit(s.arena);
        try stack.append(s.arena, root);
        while (JsIr.popOperand(&stack)) |node| {
            if (m.ir.tag(node) == .arrow) {
                if (try s.foldFunc(m, @enumFromInt(m.ir.data(node).lhs), depth)) any = true;
                continue;
            }
            try m.ir.pushOperands(s.arena, &stack, node);
        }
        return any;
    }
};

// ---------------------------------------------------------------------------
// The release peephole: one module at a time, after specialisation
// ---------------------------------------------------------------------------

/// `backend.md` §9, *Compact statements*: rewrites of one module's IR that
/// are exact where they apply, run on every `--release` module (a library's
/// too) just before `Opt` plans it.
///
/// **A flag test is the bits.** In a TEST position — an `if`'s test, a
/// conditional's, the operand of `!`, and either side of `&&`/`||` in one —
/// `(x & k) !== 0` is `x & k` and `(x & k) === 0` is `!(x & k)`: a bitwise
/// operator's value is an integer, never `NaN`, so it is truthy exactly when
/// it is not zero. Only a node nothing else refers to is rewritten, so a
/// comparison lowering shared with a value position keeps its `boolean`.
pub fn peephole(gpa: Allocator, ir: *JsIr) Allocator.Error!void {
    const refs = try gpa.alloc(u8, ir.nodes.len);
    defer gpa.free(refs);
    @memset(refs, 0);
    var children: std.ArrayList(Index) = .empty;
    defer children.deinit(gpa);
    for (0..ir.nodes.len) |i| {
        const node: Index = @enumFromInt(@as(u32, @intCast(i)));
        children.clearRetainingCapacity();
        try operandsOf(gpa, ir, node, &children);
        for (children.items) |c| refs[c.int()] +|= 1;
    }
    var tests: std.ArrayList(Index) = .empty;
    defer tests.deinit(gpa);
    for (0..ir.nodes.len) |i| {
        const node: Index = @enumFromInt(@as(u32, @intCast(i)));
        const d = ir.data(node);
        // `!(a === b)` is `a !== b`, and the other way round, anywhere.
        if (ir.tag(node) == .unary and @as(JsIr.UnaryOp, @enumFromInt(d.rhs)) == .not) {
            const inner: Index = @enumFromInt(d.lhs);
            if (ir.tag(inner) == .binary and refs[inner.int()] == 1) {
                const flipped: ?JsIr.BinaryOp = switch (@as(JsIr.BinaryOp, @enumFromInt(ir.data(inner).rhs))) {
                    .strict_eq => .strict_ne,
                    .strict_ne => .strict_eq,
                    else => null,
                };
                if (flipped) |op| {
                    ir.nodes.items(.tag)[node.int()] = .binary;
                    ir.nodes.items(.data)[node.int()] = .{ .lhs = ir.data(inner).lhs, .rhs = @intFromEnum(op) };
                    continue;
                }
            }
        }
        switch (ir.tag(node)) {
            .if_stmt, .cond => try tests.append(gpa, @enumFromInt(d.lhs)),
            .unary => if (@as(JsIr.UnaryOp, @enumFromInt(d.rhs)) == .not) try tests.append(gpa, @enumFromInt(d.lhs)),
            else => {},
        }
        while (tests.pop()) |t| {
            if (ir.tag(t) != .binary) continue;
            const td = ir.data(t);
            const op: JsIr.BinaryOp = @enumFromInt(td.rhs);
            const b = ir.extraData(@enumFromInt(td.lhs), JsIr.Binary);
            switch (op) {
                .logical_and, .logical_or => try tests.appendSlice(gpa, &.{ b.left, b.right }),
                .strict_eq, .strict_ne => {
                    if (refs[t.int()] > 1) continue;
                    const bits: Index = if (isZero(ir, b.right) and isBits(ir, b.left))
                        b.left
                    else if (isZero(ir, b.left) and isBits(ir, b.right))
                        b.right
                    else
                        continue;
                    const tags = ir.nodes.items(.tag);
                    const datas = ir.nodes.items(.data);
                    if (op == .strict_ne) {
                        tags[t.int()] = .binary;
                        datas[t.int()] = ir.data(bits);
                    } else {
                        tags[t.int()] = .unary;
                        datas[t.int()] = .{ .lhs = bits.int(), .rhs = @intFromEnum(JsIr.UnaryOp.not) };
                    }
                },
                else => {},
            }
        }
    }
}

/// The expression operands of any node, statements' included.
fn operandsOf(gpa: Allocator, ir: *const JsIr, node: Index, out: *std.ArrayList(Index)) Allocator.Error!void {
    const d = ir.data(node);
    switch (ir.tag(node)) {
        .const_decl, .let_decl => if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| try out.append(gpa, v),
        .assign_stmt => try out.appendSlice(gpa, &.{ @enumFromInt(d.lhs), @enumFromInt(d.rhs) }),
        .return_stmt, .switch_case => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| try out.append(gpa, v),
        .if_stmt, .switch_stmt, .expr_stmt, .throw_stmt => try out.append(gpa, @enumFromInt(d.lhs)),
        .for_of => try out.append(gpa, ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf).iterable),
        .import_stmt, .export_stmt, .func_decl, .gen_decl, .while_true, .break_stmt, .continue_stmt, .block_stmt => {},
        else => try ir.pushOperands(gpa, out, node),
    }
}

fn isZero(ir: *const JsIr, node: Index) bool {
    if (ir.tag(node) != .number) return false;
    const x = parseNumber(ir.bytes(node)) orelse return false;
    return x == 0;
}

/// A bitwise operator: its value is an integer, never `NaN`.
fn isBits(ir: *const JsIr, node: Index) bool {
    if (ir.tag(node) != .binary) return false;
    return switch (@as(JsIr.BinaryOp, @enumFromInt(ir.data(node).rhs))) {
        .bit_and, .bit_or, .bit_xor, .shl, .sar, .shr => true,
        else => false,
    };
}

/// Whether evaluating `root` can do nothing but make a value: a function, a
/// literal, a name, or an object, array or template of those. Anything
/// else — a call, a property read (a getter), an operator (`valueOf`), a
/// spread — may, and a declaration it initialises is kept.
fn inert(ir: *const JsIr, root: Index) bool {
    var stack: [64]Index = undefined;
    var len: usize = 1;
    stack[0] = root;
    var budget: u32 = 4096;
    while (len > 0) {
        len -= 1;
        const node = stack[len];
        if (budget == 0) return false;
        budget -= 1;
        const d = ir.data(node);
        switch (ir.tag(node)) {
            .arrow, .ident, .number, .string, .template_chunk, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this => {},
            .property => {
                if (len == stack.len) return false;
                stack[len] = @enumFromInt(d.rhs);
                len += 1;
            },
            .object, .array, .template => for (ir.extraSlice(JsIr.inlineRange(d), Index)) |child| {
                if (len == stack.len) return false;
                stack[len] = child;
                len += 1;
            },
            else => return false,
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Numbers: exact or nothing
// ---------------------------------------------------------------------------

/// A JavaScript numeric literal as beni writes one: decimal with an optional
/// fraction and exponent, or `0x` hexadecimal. Null for anything else,
/// which then folds nowhere.
fn parseNumber(text: []const u8) ?f64 {
    if (text.len == 0) return null;
    for (text) |c| if (c == '_') return null;
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        const v = std.fmt.parseInt(u64, text[2..], 16) catch return null;
        if (v > (1 << 53)) return null;
        return @floatFromInt(v);
    }
    for (text) |c| switch (c) {
        '0'...'9', '.', 'e', 'E', '+', '-' => {},
        else => return null,
    };
    return std.fmt.parseFloat(f64, text) catch null;
}

/// Whether `x` prints as an integer literal that reads back as `x`: a safe
/// integer, and not negative zero.
fn exactInteger(x: f64) bool {
    if (std.math.isNan(x) or std.math.isInf(x)) return false;
    if (@trunc(x) != x) return false;
    if (@abs(x) > 9007199254740992.0) return false;
    if (x == 0 and std.math.signbit(x)) return false;
    return true;
}

fn toInt32(x: f64) i32 {
    return @bitCast(toUint32(x));
}

fn toUint32(x: f64) u32 {
    if (std.math.isNan(x) or std.math.isInf(x)) return 0;
    const t = @trunc(x);
    const m = @mod(t, 4294967296.0);
    return @intFromFloat(m);
}

fn ascii(text: []const u8) bool {
    for (text) |c| if (c >= 0x80) return false;
    return true;
}

fn sameType(x: Lit, y: Lit) bool {
    const bx = x.kind == .true_lit or x.kind == .false_lit;
    const by = y.kind == .true_lit or y.kind == .false_lit;
    if (bx or by) return bx and by;
    return x.kind == y.kind;
}

/// `x === y` on two literals, or null when it cannot be decided exactly.
fn strictEquals(x: Lit, y: Lit) ?bool {
    if (!sameType(x, y)) return false;
    return switch (x.kind) {
        .number => {
            const p = parseNumber(x.bytes) orelse return null;
            const q = parseNumber(y.bytes) orelse return null;
            return p == q;
        },
        .string => std.mem.eql(u8, x.bytes, y.bytes),
        .true_lit, .false_lit => x.kind == y.kind,
        .null_lit, .undefined_lit => true,
    };
}
