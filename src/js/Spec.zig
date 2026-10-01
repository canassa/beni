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
//!      called by a hand-written file or the entry file (`Input.escaping`,
//!      `Input.entry`) —
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
    /// Per name: its whole-program property-name id when it is a plain name
    /// (a key or a member's name may be one), or `none`.
    prop: []const u32 = &.{},
    /// The tables lowering handed the optimiser, which a function written
    /// where it is called (slice 5) extends with each copy of a listed
    /// node or name. Null: nothing is copied into this module.
    tables: ?*Tables = null,
    /// The module's own name, the qualifier of a top-level binding slice 5
    /// makes here.
    self: JsIr.Symbol.Optional = .none,
};

/// `Lower.Result`'s `effect_keep`, `pure_discards`, `unobserved` and
/// `mutable`, as lists slice 5 may append to.
pub const Tables = struct {
    keep: std.ArrayList(Index) = .empty,
    discards: std.ArrayList(Index) = .empty,
    unobserved: std.ArrayList(Index) = .empty,
    mutable: std.ArrayList(NameIndex) = .empty,
};

pub const Input = struct {
    modules: []const Module,
    /// How many whole-program ids `Module.global` uses.
    globals: u32,
    /// How many property-name ids `Module.prop` uses.
    props: u32 = 0,
    /// The property-name ids of the names `Object.prototype` has
    /// (`toString`, `constructor`, …): an object literal without one does
    /// not read as `undefined` there.
    builtin_props: []const u32 = &.{},
    /// The property-name ids of `node_makers`' names: a call of one on a
    /// value the program did not allocate is a node (fact 5's host fact).
    node_makers: []const u32 = &.{},
    /// Whole-program names some file the pass cannot see reads or calls:
    /// the entry file's `start` and `flush` (and `main` and `run` when
    /// `entry` is null), and what the markup runtime imports from the
    /// runtime module.
    escaping: []const u32,
    /// The entry file's `run(main)`, when `run` is the program's own
    /// (backend.md §9, *The entry's call is a call*): fact 3 reads it as a
    /// call, facts 1 and 2 and `prune` as names that escape.
    entry: ?Entry = null,
    /// The property-name id of `insertBefore` and the pooled symbol of
    /// `appendChild`, when the program names the first: slice 4's
    /// `appendChild` rewrite.
    insert_before: ?struct { insert_before: u32, append_child: JsIr.Symbol } = null,
    /// A symbol of the session's pool, the text of every name slice 5
    /// invents (each told apart by its disambiguator). `.none` turns
    /// slice 5 off.
    fresh: JsIr.Symbol.Optional = .none,
    /// The build is one scope-hoisted file, so any module may name any
    /// top-level declaration of another (slice 6, `nameIn`).
    one_scope: bool = false,
    /// Per property-name id: its length, for slice 8's size model.
    prop_len: []const u8 = &.{},
};

/// A call the entry file makes of a top-level function: the whole-program
/// names of the callee and of each argument, a name read whole.
pub const Entry = struct {
    callee: u32,
    args: []const u32,
};

/// Every name `Input.escaping` lists, then the entry call's.
fn eachRoot(in: Input, i: usize) ?u32 {
    if (i < in.escaping.len) return in.escaping[i];
    const e = in.entry orelse return null;
    const j = i - in.escaping.len;
    if (j == 0) return e.callee;
    return if (j - 1 < e.args.len) e.args[j - 1] else null;
}

/// Whether whole-program name `g` is one `eachRoot` lists: a file the pass
/// cannot see names it.
fn isRoot(in: Input, g: u32) bool {
    var i: usize = 0;
    while (eachRoot(in, i)) |r| : (i += 1) if (r == g) return true;
    return false;
}

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
    s.pts = .init(&s);
    defer s.pts.deinit();
    try s.rounds();
    // Slices 5, 7 and 8, once the facts are spent: what is called from one
    // place, and a small function wherever it is called, is written there;
    // an object nothing but its own reads and writes can see is its keys;
    // reachability drops what went; and the facts are asked again of what
    // that exposed — a literal now passed, a field of a literal now read.
    var pass: u32 = 0;
    while (pass < max_passes) : (pass += 1) {
        var changed = false;
        if (try s.inlineSmall()) changed = true;
        if (try s.inlineOnce()) changed = true;
        if (try s.scalarReplace()) changed = true;
        if (!changed) break;
        _ = try s.prune();
        try s.grow();
        try s.rounds();
    }
    s.releaseKeeps();
    try s.finish();
}

/// How many times the inlining passes and the facts after them repeat.
const max_passes = 3;

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

/// `name`: an object or function a top-level declaration makes (`const f = (…) => …`,
/// `const o = {…}`, `function f`), by its whole-program id in `bytes`
/// (four bytes): a constant written as the declaration's name (slice 6).
const Kind = enum(u8) { number, string, true_lit, false_lit, null_lit, undefined_lit, name };

/// A literal, interned: `Spec.lits` holds its kind and bytes.
const Lit = struct {
    kind: Kind,
    bytes: []const u8 = "",
};

/// The lattice: ⊥ (nothing yet), one literal, *nonnull* — some value that is
/// neither `null` nor `undefined` (slice 4, fact 5) — or ⊤. A literal that is
/// not nullish is below nonnull; `Spec.join` is the join, which needs to
/// know the literal's kind.
const Lat = packed struct(u32) {
    state: State,
    lit: u30 = 0,

    const State = enum(u2) { bot, lit, top, nonnull };
    const bot: Lat = .{ .state = .bot };
    const top: Lat = .{ .state = .top };
    const nonnull: Lat = .{ .state = .nonnull };

    fn of(id: u32) Lat {
        return .{ .state = .lit, .lit = @intCast(id) };
    }

    fn eql(a: Lat, b: Lat) bool {
        return a.state == b.state and (a.state != .lit or a.lit == b.lit);
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
    /// `global`, grown when a name of another module is written here.
    global_list: std.ArrayList(u32) = .empty,
    /// `prop` of the names added after it (`Pts.propId`).
    prop_more: std.ArrayList(u32) = .empty,
    /// `Module.prop`, and where this module is in `Spec.mods`.
    prop: []const u32,
    index: u32,
    extra: std.ArrayList(u32),
    string_bytes: std.ArrayList(u8),
    names: std.ArrayList(JsIr.Name),
    tables: ?*Tables,
    self: JsIr.Symbol.Optional,
    /// The next disambiguator no name of the module has (slice 5).
    next_tag: u32 = 0,
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
    /// Per node, while `patchStmt` walks a statement: it is the object of
    /// another read.
    objects: std.DynamicBitSetUnmanaged = .{},

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

    /// Append a node (slice 5, which copies a body into its caller). The
    /// per-node tables of the facts are not grown: nothing reads them
    /// after slice 5.
    fn addNode(m: *Mod, gpa: Allocator, tag: Node.Tag, pos: u32, lhs: u32, rhs: u32) Allocator.Error!Index {
        var list = m.ir.nodes.toMultiArrayList();
        try list.append(gpa, .{ .tag = tag, .pos = pos, .data = .{ .lhs = lhs, .rhs = rhs } });
        m.ir.nodes = list.slice();
        return @enumFromInt(@as(u32, @intCast(list.len - 1)));
    }

    /// Append a name, keeping the IR's view of the column current.
    fn addName(m: *Mod, gpa: Allocator, n: JsIr.Name) Allocator.Error!NameIndex {
        const at: u32 = @intCast(m.names.items.len);
        try m.names.append(gpa, n);
        m.ir.names = m.names.items;
        return @enumFromInt(at);
    }

    /// Append string bytes, keeping the IR's view current.
    fn addBytes(m: *Mod, gpa: Allocator, text: []const u8) Allocator.Error!u32 {
        const at: u32 = @intCast(m.string_bytes.items.len);
        try m.string_bytes.appendSlice(gpa, text);
        m.ir.string_bytes = m.string_bytes.items;
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
    /// The top-level statement being walked, which keys `Pts`'s locals.
    cur_top: Index = undefined,
    pts: Pts = undefined,
    changed: bool = false,
    /// Whether this sweep counts the reads of whole-program names: the
    /// first of a round only, so that `reads` is a count and not a
    /// multiple of one.
    counting: bool = false,
    /// Slice 4, facts 4 and 5: per abstract object and property, the join
    /// of every value written to it; the object sites whose literal has a
    /// spread; per function, the join of what it returns, and the function
    /// the walk is in; and the conditionals fact 5 decides though their
    /// test is no literal, with the branch each takes. Refilled each round.
    prop_lat: std.AutoHashMapUnmanaged(SiteProp, Lat) = .empty,
    spread_sites: []bool = &.{},
    ret_lat: std.AutoHashMapUnmanaged(NodeRef, Lat) = .empty,
    cur_fn: ?NodeRef = null,
    decided_conds: std.AutoHashMapUnmanaged(NodeRef, Index) = .empty,
    /// `nameIn`'s answers, keyed by module and whole-program id; cleared
    /// each rewrite.
    name_in: std.AutoHashMapUnmanaged(SiteProp, u32) = .empty,

    const Frame = struct { node: Index, post: bool };
    const SiteProp = struct { site: u32, prop: u32 };
    const NodeRef = struct { module: u32, node: u32 };

    /// The join of the lattice: a literal and nonnull, or two different
    /// literals, meet at nonnull when no side is `null` or `undefined`.
    fn join(s: *Spec, a: Lat, b: Lat) Lat {
        if (a.state == .bot) return b;
        if (b.state == .bot) return a;
        if (a.state == .top or b.state == .top) return .top;
        if (a.state == .lit and b.state == .lit and a.lit == b.lit) return a;
        if (s.maybeNullish(a) or s.maybeNullish(b)) return .top;
        return .nonnull;
    }

    fn maybeNullish(s: *Spec, v: Lat) bool {
        return switch (v.state) {
            .bot, .nonnull => false,
            .top => true,
            .lit => switch (s.litOf(v).kind) {
                .null_lit, .undefined_lit => true,
                else => false,
            },
        };
    }

    /// What a value that must not be written as its literal says: nonnull
    /// when it is neither `null` nor `undefined`.
    fn demote(s: *Spec, v: Lat) Lat {
        return switch (v.state) {
            .lit => if (s.maybeNullish(v)) .top else .nonnull,
            else => v,
        };
    }

    fn joinInto(s: *Spec, slot: *Lat, v: Lat) void {
        const joined = s.join(slot.*, v);
        if (!joined.eql(slot.*)) {
            slot.* = joined;
            s.changed = true;
        }
    }

    fn joinProp(s: *Spec, site: u32, prop: u32, v: Lat) Allocator.Error!void {
        if (prop == none) return;
        const gop = try s.prop_lat.getOrPut(s.arena, .{ .site = site, .prop = prop });
        if (!gop.found_existing) {
            gop.value_ptr.* = .bot;
            if (v.state != .bot) s.changed = true;
        }
        s.joinInto(gop.value_ptr, v);
    }

    fn joinRet(s: *Spec, v: Lat) Allocator.Error!void {
        const f = s.cur_fn orelse return;
        const gop = try s.ret_lat.getOrPut(s.arena, f);
        if (!gop.found_existing) {
            gop.value_ptr.* = .bot;
            if (v.state != .bot) s.changed = true;
        }
        s.joinInto(gop.value_ptr, v);
    }

    fn init(gpa: Allocator, arena: Allocator, in: Input) Allocator.Error!Spec {
        const mods = try arena.alloc(Mod, in.modules.len);
        for (mods, in.modules, 0..) |*m, src, mi| {
            const ir = src.ir;
            m.* = .{
                .ir = ir,
                .global = src.global,
                .prop = src.prop,
                .index = @intCast(mi),
                .extra = .{ .items = @constCast(ir.extra), .capacity = ir.extra.len },
                .string_bytes = .{ .items = @constCast(ir.string_bytes), .capacity = ir.string_bytes.len },
                .names = .{ .items = @constCast(ir.names), .capacity = ir.names.len },
                .tables = src.tables,
                .self = src.self,
                .memo = try arena.alloc(Lat, ir.nodes.len),
                .lit_of = try arena.alloc(u32, ir.nodes.len),
                .stamp = try arena.alloc(u32, ir.names.len),
                .decls = try arena.alloc(u32, ir.names.len),
                .uses = try arena.alloc(u32, ir.names.len),
                .assigned = try arena.alloc(bool, ir.names.len),
                .value = try arena.alloc(Lat, ir.names.len),
                .param = try arena.alloc(u32, ir.names.len),
                .objects = try .initEmpty(arena, ir.nodes.len),
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

    /// Facts-then-rewrite to their fixpoint (at most `max_rounds`).
    fn rounds(s: *Spec) Allocator.Error!void {
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
    }

    /// Size every per-node and per-name table to the module as it now is:
    /// a body written where it is called added both.
    fn grow(s: *Spec) Allocator.Error!void {
        for (s.mods) |*m| {
            const nodes = m.ir.nodes.len;
            if (m.memo.len < nodes) {
                m.memo = try growSlice(s.arena, Lat, m.memo, nodes, .top);
                m.lit_of = try growSlice(s.arena, u32, m.lit_of, nodes, none);
                try m.objects.resize(s.arena, nodes, false);
            }
            const names = m.names.items.len;
            if (m.stamp.len < names) {
                m.stamp = try growSlice(s.arena, u32, m.stamp, names, 0);
                m.decls = try growSlice(s.arena, u32, m.decls, names, 0);
                m.uses = try growSlice(s.arena, u32, m.uses, names, 0);
                m.assigned = try growSlice(s.arena, bool, m.assigned, names, false);
                m.value = try growSlice(s.arena, Lat, m.value, names, .top);
                m.param = try growSlice(s.arena, u32, m.param, names, none);
            }
        }
    }

    /// Hand every module its columns back, owned and exactly sized.
    fn finish(s: *Spec) Allocator.Error!void {
        for (s.mods) |*m| {
            m.ir.extra = try m.extra.toOwnedSlice(s.gpa);
            m.ir.string_bytes = try m.string_bytes.toOwnedSlice(s.gpa);
            m.ir.names = try m.names.toOwnedSlice(s.gpa);
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
            .name => 2,
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
        s.prop_lat.clearRetainingCapacity();
        s.ret_lat.clearRetainingCapacity();
        s.decided_conds.clearRetainingCapacity();
        var ri: usize = 0;
        while (eachRoot(s.in, ri)) |g| : (ri += 1) if (g < s.escaped.len) {
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
        // Fact 3 first: a read it proves `undefined` folds like a literal.
        try s.pts.analyse();
        s.spread_sites = try s.arena.alloc(bool, s.pts.sites.items.len);
        @memset(s.spread_sites, false);
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
        s.cur_top = stmt;
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
            .try_stmt => {
                const t = ir.extraData(@enumFromInt(d.rhs), JsIr.Try);
                try s.countList(m, t.body());
                try s.countList(m, t.finalBody());
            },
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
            .func_decl, .gen_decl => try s.evalFunc(m, mi, @enumFromInt(d.rhs), stmt),
            .assign_stmt => {
                const target: Index = @enumFromInt(d.lhs);
                if (ir.tag(target) != .ident) _ = try s.eval(m, mi, target);
                const value = try s.eval(m, mi, @enumFromInt(d.rhs));
                // Facts 4 and 5: what `o.p = v` writes, on every object `o`
                // may be.
                if (ir.tag(target) == .member and s.pts.ok) {
                    const td = ir.data(target);
                    const obj = s.pts.vals[mi][td.lhs];
                    const id = s.pts.propId(mi, @enumFromInt(td.rhs));
                    for (obj.sites) |site| try s.joinProp(site, id, value);
                }
            },
            .return_stmt => {
                const v: Lat = if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| try s.eval(m, mi, v) else .of(try s.intern(.{ .kind = .undefined_lit }));
                try s.joinRet(v);
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
            // Both blocks are walked; facts 1 and 2 are flow-insensitive, so
            // a cleanup that runs after a throw part-way through the body
            // sees nothing they could have assumed.
            .try_stmt => {
                const t = ir.extraData(@enumFromInt(d.rhs), JsIr.Try);
                try s.evalList(m, mi, t.body());
                try s.evalList(m, mi, t.finalBody());
            },
            else => {},
        }
    }

    fn evalList(s: *Spec, m: *Mod, mi: u32, range: JsIr.SubRange) Allocator.Error!void {
        for (m.ir.extraSlice(range, Index)) |stmt| try s.evalStmt(m, mi, stmt);
    }

    /// A function's body, `node` the arrow or the declaration: what its
    /// `return`s give, and `undefined` when it may run off its end, join
    /// its entry of `ret_lat` (fact 5).
    fn evalFunc(s: *Spec, m: *Mod, mi: u32, record: ExtraIndex, node: Index) Allocator.Error!void {
        const saved = s.cur_fn;
        defer s.cur_fn = saved;
        s.cur_fn = .{ .module = mi, .node = node.int() };
        const f = m.ir.extraData(record, JsIr.Func);
        try s.evalList(m, mi, f.body());
        if (fallsThrough(m.ir, f.body())) try s.joinRet(.of(try s.intern(.{ .kind = .undefined_lit })));
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
                        m.memo[f.node.int()] = .nonnull;
                        try s.evalFunc(m, mi, @enumFromInt(ir.data(f.node).lhs), f.node);
                        continue;
                    },
                    // A leaf has no operands to wait for.
                    .ident, .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .template_chunk => {
                        m.memo[f.node.int()] = try s.combine(m, f.node);
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
            // Every operator but `yield`, `&&` and `||` gives a primitive
            // that is neither `null` nor `undefined`.
            .unary => blk: {
                const op: JsIr.UnaryOp = @enumFromInt(d.rhs);
                const v = try s.unary(op, m.memo[d.lhs]);
                break :blk if (op != .yield and v.state == .top) .nonnull else v;
            },
            .binary => blk: {
                const b = ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
                const op: JsIr.BinaryOp = @enumFromInt(d.rhs);
                const l = m.memo[b.left.int()];
                const r = m.memo[b.right.int()];
                // Facts 5 and 6: an identity test decided by what the two
                // sides may be, when neither side's evaluation can do
                // anything the fold would lose.
                if ((op == .strict_eq or op == .strict_ne) and l.state != .bot and r.state != .bot) if (try s.identity(m, b.left, b.right, l, r)) |same| {
                    break :blk try s.boolean(if (op == .strict_eq) same else !same);
                };
                const v = try s.binary(op, l, r);
                break :blk if (op != .logical_and and op != .logical_or and v.state == .top) .nonnull else v;
            },
            .cond => blk: {
                const c = ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
                const t = m.memo[d.lhs];
                break :blk switch (t.state) {
                    .bot => .bot,
                    .top, .nonnull => undecided: {
                        // Fact 5's second case: a test of a nonnull read
                        // against `null`, whose taken branch is that read.
                        if (try s.nullTestTaken(m, @enumFromInt(d.lhs), c)) |taken| {
                            try s.decided_conds.put(s.arena, .{ .module = m.index, .node = node.int() }, taken);
                            break :undecided m.memo[taken.int()];
                        }
                        const a = m.memo[c.consequent.int()];
                        const e = m.memo[c.alternate.int()];
                        if (a.state == .bot and e.state == .bot) break :undecided .bot;
                        break :undecided s.demote(s.join(a, e));
                    },
                    .lit => switch (s.truthy(s.litOf(t))) {
                        .yes => m.memo[c.consequent.int()],
                        .no => m.memo[c.alternate.int()],
                        .unknown => .top,
                    },
                };
            },
            .call => blk: {
                try s.callSite(m, node);
                break :blk try s.callValue(m, node);
            },
            .template => try s.templateValue(m, node),
            .new_call, .object, .array => blk: {
                if (ir.tag(node) == .object) try s.objectWrites(m, node);
                break :blk .nonnull;
            },
            .member => try s.memberValue(m, node),
            else => .top,
        };
    }

    /// A template whose every substitution is a literal is the string it
    /// makes (fact 4's reads end in one: `${m.n}` is `"null"`), when that
    /// string prints no longer than the template did. A number converts
    /// only when its spelling is how JavaScript writes it back.
    fn templateValue(s: *Spec, m: *Mod, node: Index) Allocator.Error!Lat {
        const ir = m.ir;
        var text: std.ArrayList(u8) = .empty;
        var template_len: usize = 2;
        for (ir.extraSlice(JsIr.inlineRange(ir.data(node)), Index)) |part| {
            if (ir.tag(part) == .template_chunk) {
                const chunk = ir.bytes(part);
                try text.appendSlice(s.arena, chunk);
                template_len += chunk.len;
                for (chunk) |c| template_len += @intFromBool(c == '`' or c == '\\' or c == '$');
                continue;
            }
            const v = m.memo[part.int()];
            if (v.state == .bot) return .bot;
            if (v.state != .lit) return .nonnull;
            const lit = s.litOf(v);
            const spelled: []const u8 = switch (lit.kind) {
                .string => lit.bytes,
                .number => blk: {
                    const back = try s.number(parseNumber(lit.bytes) orelse return .nonnull);
                    if (back.state != .lit or !std.mem.eql(u8, s.litOf(back).bytes, lit.bytes)) return .nonnull;
                    break :blk lit.bytes;
                },
                .true_lit => "true",
                .false_lit => "false",
                .null_lit => "null",
                .undefined_lit => "undefined",
                .name => return .nonnull,
            };
            try text.appendSlice(s.arena, spelled);
            template_len += 3 + printedLen(lit);
        }
        if (text.items.len > 256) return .nonnull;
        var string_len: usize = 2 + text.items.len;
        for (text.items) |c| string_len += @intFromBool(c == '"' or c == '\\' or c < 0x20);
        if (string_len > template_len) return .nonnull;
        return .of(try s.intern(.{ .kind = .string, .bytes = text.items }));
    }

    /// Fact 3, then facts 4 and 5: what a read `x.p` gives. A property no
    /// object `x` may be ever holds is `undefined`, and one whose every
    /// write is one literal is that literal — both only through a name or
    /// properties of one, whose evaluation does nothing the fold could
    /// lose, on objects that are all the program's own. A read whose every
    /// write is nonnull is nonnull wherever it does not throw.
    fn memberValue(s: *Spec, m: *Mod, node: Index) Allocator.Error!Lat {
        const ir = m.ir;
        const d = ir.data(node);
        const id = s.pts.propId(m.index, @enumFromInt(d.rhs));
        const chain = try s.pts.chain(m.index, s.cur_top, @enumFromInt(d.lhs));
        if (chain) |obj| if (s.pts.neverWritten(obj, id)) {
            return .of(try s.intern(.{ .kind = .undefined_lit }));
        };
        if (!s.pts.ok) return .top;
        const obj = chain orelse s.pts.vals[m.index][d.lhs];
        const v = s.propValue(obj, id);
        if (v.state == .lit and chain != null and s.pts.known(obj)) return v;
        return s.demote(v);
    }

    /// The join of what is written to property `id` of every object `obj`
    /// may be: ⊤ unless each is a program object literal that nothing
    /// unseen holds, none written under an unknown key or copied from by a
    /// spread, each with the key in its literal. Reading a property of a
    /// primitive gives `undefined` or a builtin, so a primitive `obj` is ⊤;
    /// a nullish one throws and gives nothing.
    fn propValue(s: *Spec, obj: Pts.Val, id: u32) Lat {
        if (id == none or obj.top or obj.prim or obj.sites.len == 0) return .top;
        var out: Lat = .bot;
        for (obj.sites) |site| {
            const st = &s.pts.sites.items[site];
            if (st.kind != .object or st.escaped or st.any_written) return .top;
            if (site >= s.spread_sites.len or s.spread_sites[site]) return .top;
            const pr = s.pts.findProp(site, id) orelse return .top;
            if (!pr.init) return .top;
            out = s.join(out, s.prop_lat.get(.{ .site = site, .prop = id }) orelse .bot);
        }
        return out;
    }

    /// An object literal's keys, joined into what its site's properties
    /// may hold (facts 4 and 5); a spread makes every one ⊤.
    fn objectWrites(s: *Spec, m: *Mod, node: Index) Allocator.Error!void {
        const ir = m.ir;
        const site = s.pts.site_at.get(.{ .module = m.index, .node = node.int() }) orelse return;
        for (ir.extraSlice(JsIr.inlineRange(ir.data(node)), Index)) |child| {
            const cd = ir.data(child);
            switch (ir.tag(child)) {
                .property => try s.joinProp(site, s.pts.propId(m.index, @enumFromInt(cd.lhs)), m.memo[cd.rhs]),
                else => {
                    if (site < s.spread_sites.len and !s.spread_sites[site]) {
                        s.spread_sites[site] = true;
                        s.changed = true;
                    }
                },
            }
        }
    }

    /// Fact 5: a call's value is the join of what the functions it may call
    /// return, and a call of one of the DOM's node-making methods on a host
    /// value is a node. Never a literal: the call is still made.
    fn callValue(s: *Spec, m: *Mod, node: Index) Allocator.Error!Lat {
        if (!s.pts.ok) return .top;
        const ir = m.ir;
        const callee: Index = @enumFromInt(ir.data(node).lhs);
        const vc = s.pts.vals[m.index][callee.int()];
        if (ir.tag(callee) == .member) {
            const id = s.pts.propId(m.index, @enumFromInt(ir.data(callee).rhs));
            const host = id != none and std.mem.indexOfScalar(u32, s.in.node_makers, id) != null;
            const receiver = s.pts.vals[m.index][ir.data(callee).lhs];
            if (host and receiver.sites.len == 0 and !receiver.prim) return .nonnull;
        }
        if (vc.top or vc.prim or vc.sites.len == 0) return .top;
        var out: Lat = .bot;
        for (vc.sites) |site| {
            const st = &s.pts.sites.items[site];
            if (st.kind != .func) return .top;
            const ref: NodeRef = .{ .module = st.module, .node = st.node.int() };
            if (s.mods[st.module].ir.tag(st.node) == .gen_decl) {
                out = s.join(out, .nonnull);
                continue;
            }
            out = s.join(out, s.ret_lat.get(ref) orelse .bot);
        }
        return s.demote(out);
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
        for (args, 0..) |a, i| s.joinInto(&s.params.items[decl.params + i], m.memo[a.int()]);
    }

    /// Facts 5 and 6: whether `left === right`, from what each side may be,
    /// or null. Each side must be a chain whose evaluation cannot throw nor
    /// run a getter (`Pts.safeChain`), so dropping it loses nothing.
    ///
    /// - A side that may be neither `null` nor `undefined` against a
    ///   `null` or `undefined` literal: never the same.
    /// - Two sides whose objects are disjoint, neither a host value, and
    ///   not both possibly a primitive of the same kind: never the same.
    /// - Two sides that may each be only the one object an allocation site
    ///   made once: the same.
    fn identity(s: *Spec, m: *Mod, left: Index, right: Index, l: Lat, r: Lat) Allocator.Error!?bool {
        if (!s.pts.ok) return null;
        if (l.state == .lit and r.state == .lit) return null;
        const lv = try s.pts.safeChain(m.index, s.cur_top, left);
        const rv = try s.pts.safeChain(m.index, s.cur_top, right);
        const lnull = l.state == .lit and s.maybeNullish(l);
        const rnull = r.state == .lit and s.maybeNullish(r);
        if (lnull and r.state == .nonnull and rv != null) return false;
        if (rnull and l.state == .nonnull and lv != null) return false;
        const a = lv orelse return null;
        const b = rv orelse return null;
        if (a.top or b.top) return null;
        if (a.sites.len == 0 and !a.prim and !a.nullish()) return null;
        if (b.sites.len == 0 and !b.prim and !b.nullish()) return null;
        const scalar_a = a.prim or a.nullish();
        const scalar_b = b.prim or b.nullish();
        if (!scalar_a and !scalar_b and a.sites.len == 1 and b.sites.len == 1 and a.sites[0] == b.sites[0] and s.pts.sites.items[a.sites[0]].once) return true;
        if (a.prim and b.prim) return null;
        if (a.nul and b.nul) return null;
        if (a.undef and b.undef) return null;
        for (a.sites) |x| if (std.mem.indexOfScalar(u32, b.sites, x) != null) return null;
        return false;
    }

    /// Fact 5's second case: of `c ? t : f` whose test is `x.p === null`
    /// (or `!==`, either way round) with `x.p` nonnull, the branch the test
    /// takes — when that branch is the read `x.p` itself, which evaluated
    /// first throws, or gives `undefined`, exactly where the test did.
    fn nullTestTaken(s: *Spec, m: *Mod, test_node: Index, c: JsIr.Cond) Allocator.Error!?Index {
        _ = s;
        const ir = m.ir;
        if (ir.tag(test_node) != .binary) return null;
        const op: JsIr.BinaryOp = @enumFromInt(ir.data(test_node).rhs);
        if (op != .strict_eq and op != .strict_ne) return null;
        const b = ir.extraData(@enumFromInt(ir.data(test_node).lhs), JsIr.Binary);
        const tested, const other = if (ir.tag(b.right) == .null_lit) .{ b.left, b.right } else .{ b.right, b.left };
        if (ir.tag(other) != .null_lit or ir.tag(tested) != .member) return null;
        if (m.memo[tested.int()].state != .nonnull) return null;
        const taken = if (op == .strict_eq) c.alternate else c.consequent;
        if (!sameChain(ir, tested, taken)) return null;
        return taken;
    }

    /// What reading `n` gives, from the facts.
    fn nameValue(s: *Spec, m: *Mod, n: NameIndex) Lat {
        if (m.globalOf(n)) |g| {
            // Slice 6: a declaration that makes an object or a function, and
            // that nothing assigns, is that one object wherever it is read.
            if (s.decl[g]) |decl| if (!s.assigned[g]) {
                const dm = &s.mods[decl.module];
                const fresh = switch (dm.ir.tag(decl.stmt)) {
                    .func_decl => true,
                    .const_decl => switch (dm.ir.tag(@enumFromInt(dm.ir.data(decl.stmt).rhs))) {
                        .arrow, .object, .array => true,
                        else => false,
                    },
                    else => false,
                };
                if (fresh) return s.nameLat(g) catch .nonnull;
            };
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
            const v = s.literalValue(dm, value) catch Lat.top;
            // Fact 5: an object, an array, a function, a template or a
            // `new` is never `null` (a read before the declaration throws).
            if (v.state == .top) switch (dm.ir.tag(value)) {
                .object, .array, .arrow, .template, .new_call => return .nonnull,
                else => {},
            };
            return v;
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
            .true_lit, .name => .yes,
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
                    .name => return .top,
                };
                return .of(try s.intern(.{ .kind = .string, .bytes = text }));
            },
            .yield => return .top,
        }
    }

    fn binary(s: *Spec, op: JsIr.BinaryOp, a: Lat, b: Lat) Allocator.Error!Lat {
        switch (op) {
            .logical_and, .logical_or => {
                if (a.state == .bot) return .bot;
                // Either side may be the value, unless a literal left side
                // decides; nonnull only when both are.
                if (a.state != .lit) return s.demote(s.join(a, b));
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
        s.name_in.clearRetainingCapacity();
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
                // A name is written only where the module has it.
                if (s.litOf(v).kind == .name and try s.nameIn(m, nameId(s.litOf(v))) == null) continue;
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
        var ri: usize = 0;
        while (eachRoot(s.in, ri)) |g| : (ri += 1) if (g < referenced.len) {
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
        // The reads that stand as the object of another read (`Mod.objects`,
        // cleared on the way out): fact 4 does not write one as `null`
        // (`null.parentNode` says nothing shorter).
        var marked: std.ArrayList(u32) = .empty;
        defer {
            for (marked.items) |i| m.objects.unset(i);
            marked.deinit(s.arena);
        }
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
                // Fact 3: a key no reachable read reaches goes from its
                // literal, when its value does nothing.
                .object => _ = try s.dropKeys(m, node),
                .call => try s.appendChild(m, node),
                else => {},
            }
            // What this reports is whether the program SHRANK in a way the
            // next round's facts can see: a branch or a read gone. A name or
            // an operator written as its value takes no call site, no
            // assignment and no read with it (`prune` sees the name's
            // reference go).
            const was = ir.tag(node);
            const shrinks = switch (was) {
                .member, .cond => true,
                .binary => switch (@as(JsIr.BinaryOp, @enumFromInt(ir.data(node).rhs))) {
                    .logical_and, .logical_or => true,
                    else => false,
                },
                else => false,
            };
            const v = m.memo[node.int()];
            if (v.state == .lit and try s.patchLiteral(m, node, v, m.objects.isSet(node.int()))) {
                if (shrinks) any = true;
                continue;
            }
            // A conditional or a logical operator whose left side decides.
            const d = ir.data(node);
            switch (tag) {
                .member, .index_get => if (!m.objects.isSet(d.lhs)) {
                    m.objects.set(d.lhs);
                    try marked.append(s.arena, d.lhs);
                },
                .cond => {
                    // Fact 5's second case: the branch the test takes is the
                    // read it tested.
                    if (s.decided_conds.get(.{ .module = m.index, .node = node.int() })) |b| {
                        m.copyNode(node, b);
                        m.memo[node.int()] = m.memo[b.int()];
                        try stack.append(s.arena, node);
                        any = true;
                        continue;
                    }
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
            .try_stmt => {
                const t = ir.extraData(@enumFromInt(d.rhs), JsIr.Try);
                for (ir.extraSlice(t.body(), Index)) |b| try stack.append(s.arena, b);
                for (ir.extraSlice(t.finalBody(), Index)) |b| try stack.append(s.arena, b);
            },
            else => {},
        }
    }

    /// Write `node` as the literal `v`, when the rule allows. A name read is
    /// replaced only under `substitutes`; anything else that folded is
    /// written as its value (it is at least as long as the literal, but for
    /// a string that grew by concatenation, which `binary` caps).
    fn patchLiteral(s: *Spec, m: *Mod, node: Index, v: Lat, object_position: bool) Allocator.Error!bool {
        const ir = m.ir;
        const lit = s.litOf(v);
        // Fact 4: a read is written as its literal when that is no longer
        // than 5 bytes, and never as the object of another read. Fact 3's
        // `undefined` is written wherever it folds, as before.
        if (ir.tag(node) == .member and lit.kind != .undefined_lit) {
            if (printedLen(lit) > 5) return false;
            if (object_position and (lit.kind == .null_lit)) return false;
        }
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
            .name => {
                const n = try s.nameIn(m, nameId(lit)) orelse return false;
                if (ir.tag(node) == .ident and ir.data(node).lhs == n.int()) return false;
                m.setNode(node, .ident, n.int(), 0);
            },
        }
        return true;
    }

    /// Slice 6: the value of a declaration's name, `name` and its id.
    fn nameLat(s: *Spec, g: u32) Allocator.Error!Lat {
        const bytes = std.mem.toBytes(g);
        return .of(try s.intern(.{ .kind = .name, .bytes = &bytes }));
    }

    fn nameId(lit: Lit) u32 {
        return std.mem.bytesToValue(u32, lit.bytes[0..4]);
    }

    /// Module `m`'s name for whole-program name `g`, when a live statement
    /// of it already mentions `g` (`namedIn`), so writing it needs no import
    /// the module lacks; cached for the round's rewrite.
    fn nameIn(s: *Spec, m: *Mod, g: u32) Allocator.Error!?NameIndex {
        const gop = try s.name_in.getOrPut(s.arena, .{ .site = m.index, .prop = g });
        if (!gop.found_existing) {
            gop.value_ptr.* = if (try s.namedIn(m, g)) |n| n.int() else none;
            // In one scope-hoisted file every top-level name is one binding
            // of the one scope, spelled from its `Name` alone: the
            // declaring module's, copied in.
            if (gop.value_ptr.* == none and s.in.one_scope) if (s.decl[g]) |decl| {
                const dm = &s.mods[decl.module];
                const name = dm.ir.name(@enumFromInt(dm.ir.data(decl.stmt).lhs));
                const at = try m.addName(s.gpa, name);
                if (m.global_list.items.len == 0) try m.global_list.appendSlice(s.arena, m.global);
                while (m.global_list.items.len < at.int()) try m.global_list.append(s.arena, none);
                try m.global_list.append(s.arena, g);
                m.global = m.global_list.items;
                gop.value_ptr.* = at.int();
            };
        }
        return if (gop.value_ptr.* == none) null else @enumFromInt(gop.value_ptr.*);
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
            if (s.decided(m, @enumFromInt(raw)) != null or try s.deadWrite(m, @enumFromInt(raw))) changed = true;
        }
        if (!changed) return any;
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(s.arena);
        for (items) |raw| {
            const stmt: Index = @enumFromInt(raw);
            // Fact 3: a write of a property no reachable read reaches is not
            // written; its value is still evaluated when it may do something.
            if (try s.deadWrite(m, stmt)) {
                const value: Index = @enumFromInt(m.ir.data(stmt).rhs);
                // A read of a program object's property does nothing
                // either: no getter, no throw (`Pts.safeChain`).
                if (inert(m.ir, value) or try s.pts.safeChain(m.index, s.cur_top, value) != null) continue;
                m.setNode(stmt, .expr_stmt, value.int(), 0);
                try out.append(s.arena, raw);
                continue;
            }
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

    /// `x.insertBefore(n, r)` whose reference `r` is `null` — a literal, or
    /// a name the facts say is — on a host value `x` (one the program did
    /// not allocate: a DOM node, by fact 5's host contract) is
    /// `x.appendChild(n)`: the DOM defines appending as inserting before
    /// `null`, and both return `n`. `r` is not evaluated, which a literal
    /// or a name cannot notice.
    fn appendChild(s: *Spec, m: *Mod, node: Index) Allocator.Error!void {
        const ids = s.in.insert_before orelse return;
        if (!s.pts.ok) return;
        const ir = m.ir;
        const d = ir.data(node);
        const callee: Index = @enumFromInt(d.lhs);
        if (ir.tag(callee) != .member) return;
        if (s.pts.propId(m.index, @enumFromInt(ir.data(callee).rhs)) != ids.insert_before) return;
        const args = ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index);
        if (args.len != 2) return;
        const r = args[1];
        switch (ir.tag(r)) {
            .null_lit, .ident => {},
            else => return,
        }
        const v = m.memo[r.int()];
        if (v.state != .lit or s.litOf(v).kind != .null_lit) return;
        const receiver = s.pts.vals[m.index][ir.data(callee).lhs];
        if (receiver.sites.len != 0 or receiver.prim) return;
        // The module's name for `appendChild` (every plain name is in the
        // session's pool by now), made when it has none; the callee is
        // rewritten in place, so no node is added while the facts' tables
        // are sized.
        const want: JsIr.Name = .{ .module = .none, .base = ids.append_child, .tag = JsIr.Name.no_tag };
        const name: NameIndex = for (m.names.items, 0..) |x, i| {
            if (x.eql(want)) break @enumFromInt(@as(u32, @intCast(i)));
        } else try m.addName(s.gpa, want);
        m.setData(callee, ir.data(callee).lhs, name.int());
        const start = try m.append(s.gpa, &.{args[0].int()});
        const record = try m.append(s.gpa, &.{ start, start + 1 });
        m.setData(node, d.lhs, record);
    }

    /// Drop from object literal `node` every key fact 3 says no reachable
    /// read reaches, whose value does nothing when evaluated. True when any
    /// went.
    fn dropKeys(s: *Spec, m: *Mod, node: Index) Allocator.Error!bool {
        if (!s.pts.ok) return false;
        const ir = m.ir;
        const props = try s.arena.dupe(Index, ir.extraSlice(JsIr.inlineRange(ir.data(node)), Index));
        var kept: std.ArrayList(u32) = .empty;
        var dropped = false;
        for (props) |prop| {
            if (ir.tag(prop) == .property) {
                const d = ir.data(prop);
                const id = s.pts.propId(m.index, @enumFromInt(d.lhs));
                if (s.pts.keyUnread(m.index, node, id) and inert(ir, @enumFromInt(d.rhs))) {
                    dropped = true;
                    continue;
                }
            }
            try kept.append(s.arena, prop.int());
        }
        if (!dropped) return false;
        const start = try m.append(s.gpa, kept.items);
        m.setData(node, start, start + @as(u32, @intCast(kept.items.len)));
        return true;
    }

    /// Whether statement `stmt` writes a property fact 3 says no reachable
    /// read reaches, on an object named by a chain that does nothing when
    /// evaluated.
    fn deadWrite(s: *Spec, m: *Mod, stmt: Index) Allocator.Error!bool {
        if (!s.pts.ok) return false;
        const ir = m.ir;
        if (ir.tag(stmt) != .assign_stmt) return false;
        const target: Index = @enumFromInt(ir.data(stmt).lhs);
        if (ir.tag(target) != .member) return false;
        const td = ir.data(target);
        const obj = try s.pts.chain(m.index, s.cur_top, @enumFromInt(td.lhs)) orelse return false;
        if (s.pts.neverRead(obj, s.pts.propId(m.index, @enumFromInt(td.rhs)))) return true;
        // Slice 8: `x.p = x.p` on program objects — no getter, no setter,
        // no throw — changes nothing (an identity written in place).
        return sameChain(ir, target, @enumFromInt(ir.data(stmt).rhs)) and try s.pts.safeChain(m.index, s.cur_top, target) != null;
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
            // The two ranges are the record's words 0–1 and 2–3, as an
            // `if`'s are.
            .try_stmt => {
                const at = d.rhs;
                if (try s.foldList(m, at, ir.extraData(@enumFromInt(at), JsIr.Try).body(), depth + 1)) any = true;
                if (try s.foldList(m, at + 2, m.ir.extraData(@enumFromInt(at), JsIr.Try).finalBody(), depth + 1)) any = true;
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

    /// A binding lowering kept for what its initialiser might do, whose
    /// initialiser the facts folded to something that does nothing (a
    /// literal, a name): kept no more, so the optimiser drops it when
    /// nothing reads it.
    fn releaseKeeps(s: *Spec) void {
        for (s.mods) |*m| {
            const t = m.tables orelse continue;
            var kept: usize = 0;
            for (t.keep.items) |node| {
                const value: ?Index = switch (m.ir.tag(node)) {
                    .const_decl => @enumFromInt(m.ir.data(node).rhs),
                    .let_decl => @as(Node.OptionalIndex, @enumFromInt(m.ir.data(node).rhs)).unwrap(),
                    else => null,
                };
                if (value) |v| if (inert(m.ir, v)) continue;
                t.keep.items[kept] = node;
                kept += 1;
            }
            t.keep.shrinkRetainingCapacity(kept);
        }
    }

    // ---- Slice 7: scalar replacement --------------------------------------

    /// `backend.md` §9, *Scalar replacement*: a local `const x = {…}` (or a
    /// `let` nothing reassigns) of an object literal of plain keys, whose
    /// every mention in its declaration is `x.k` — read, or written by an
    /// assignment — for a key `k` of the literal, is one binding per key:
    /// `const x$k = v` in the literal's order (`let` when a write reaches
    /// it), and each `x.k` is that binding. Nothing else can see the object,
    /// so nothing can tell it was never made. True when any was replaced.
    fn scalarReplace(s: *Spec) Allocator.Error!bool {
        if (s.in.fresh == .none) return false;
        var any = false;
        for (s.mods) |*m| {
            const body = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.body, Index));
            for (body) |top| switch (m.ir.tag(top)) {
                .const_decl, .let_decl, .func_decl => if (try s.srBelow(m, top, top, 0)) {
                    any = true;
                },
                else => {},
            };
        }
        return any;
    }

    /// The statement lists below `stmt`, each replaced in its owner.
    fn srBelow(s: *Spec, m: *Mod, stmt: Index, top: Index, depth: u32) Allocator.Error!bool {
        if (depth > max_depth) return false;
        const ir = m.ir;
        const d = ir.data(stmt);
        var any = false;
        switch (ir.tag(stmt)) {
            .const_decl, .let_decl, .assign_stmt, .return_stmt, .expr_stmt, .throw_stmt => {
                var stack: std.ArrayList(Index) = .empty;
                try operandsOf(s.arena, ir, stmt, &stack);
                while (JsIr.popOperand(&stack)) |node| {
                    if (m.ir.tag(node) == .arrow) {
                        const at = m.ir.data(node).lhs;
                        if (try s.srList(m, at + 2, m.ir.extraData(@enumFromInt(at), JsIr.Func).body(), top, depth + 1)) any = true;
                        continue;
                    }
                    try m.ir.pushOperands(s.arena, &stack, node);
                }
            },
            .func_decl, .gen_decl => any = try s.srList(m, d.rhs + 2, ir.extraData(@enumFromInt(d.rhs), JsIr.Func).body(), top, depth + 1),
            .if_stmt => {
                if (try s.srBelowExpr(m, @enumFromInt(d.lhs), top, depth)) any = true;
                if (try s.srList(m, d.rhs, m.ir.extraData(@enumFromInt(d.rhs), JsIr.If).thenBody(), top, depth + 1)) any = true;
                if (try s.srList(m, d.rhs + 2, m.ir.extraData(@enumFromInt(d.rhs), JsIr.If).elseBody(), top, depth + 1)) any = true;
            },
            .while_true, .block_stmt, .switch_case => any = try s.srList(m, d.rhs, ir.subRange(@enumFromInt(d.rhs)), top, depth + 1),
            .for_of => any = try s.srList(m, d.rhs + 1, ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf).body(), top, depth + 1),
            .switch_stmt => for (try s.arena.dupe(Index, ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index))) |c| {
                if (try s.srBelow(m, c, top, depth + 1)) any = true;
            },
            .try_stmt => {
                if (try s.srList(m, d.rhs, m.ir.extraData(@enumFromInt(d.rhs), JsIr.Try).body(), top, depth + 1)) any = true;
                if (try s.srList(m, d.rhs + 2, m.ir.extraData(@enumFromInt(d.rhs), JsIr.Try).finalBody(), top, depth + 1)) any = true;
            },
            else => {},
        }
        return any;
    }

    fn srBelowExpr(s: *Spec, m: *Mod, root: Index, top: Index, depth: u32) Allocator.Error!bool {
        var any = false;
        var stack: std.ArrayList(Index) = .empty;
        try stack.append(s.arena, root);
        while (JsIr.popOperand(&stack)) |node| {
            if (m.ir.tag(node) == .arrow) {
                const at = m.ir.data(node).lhs;
                if (try s.srList(m, at + 2, m.ir.extraData(@enumFromInt(at), JsIr.Func).body(), top, depth + 1)) any = true;
                continue;
            }
            try m.ir.pushOperands(s.arena, &stack, node);
        }
        return any;
    }

    /// One list: the lists below first, then each declaration of it that
    /// can be replaced, written as its bindings.
    fn srList(s: *Spec, m: *Mod, owner: u32, range: JsIr.SubRange, top: Index, depth: u32) Allocator.Error!bool {
        if (depth > max_depth) return false;
        const items = try s.arena.dupe(u32, m.ir.extraSlice(range, u32));
        var any = false;
        for (items) |raw| if (try s.srBelow(m, @enumFromInt(raw), top, depth + 1)) {
            any = true;
        };
        var out: std.ArrayList(u32) = .empty;
        var changed = false;
        for (items) |raw| {
            if (try s.replaceScalars(m, @enumFromInt(raw), top, &out)) {
                changed = true;
                continue;
            }
            try out.append(s.arena, raw);
        }
        if (!changed) return any;
        const start = try m.append(s.gpa, out.items);
        m.extra.items[owner] = start;
        m.extra.items[owner + 1] = start + @as(u32, @intCast(out.items.len));
        return true;
    }

    /// When `stmt` declares an object that can be replaced by its keys, its
    /// bindings onto `out` and every `x.k` of `top` rewritten; false, with
    /// nothing changed, otherwise.
    fn replaceScalars(s: *Spec, m: *Mod, stmt: Index, top: Index, out: *std.ArrayList(u32)) Allocator.Error!bool {
        const ir = m.ir;
        const tag = ir.tag(stmt);
        if (tag != .const_decl and tag != .let_decl) return false;
        const x: NameIndex = @enumFromInt(ir.data(stmt).lhs);
        if (x == .none or m.globalOf(x) != null) return false;
        const value = (@as(Node.OptionalIndex, @enumFromInt(ir.data(stmt).rhs))).unwrap() orelse return false;
        if (ir.tag(value) != .object) return false;
        const props = try s.arena.dupe(Index, ir.extraSlice(JsIr.inlineRange(ir.data(value)), Index));
        if (props.len == 0 or props.len > 32) return false;
        const ids = try s.arena.alloc(u32, props.len);
        for (props, ids, 0..) |p, *id, i| {
            if (ir.tag(p) != .property) return false;
            id.* = s.pts.propId(m.index, @enumFromInt(ir.data(p).lhs));
            if (id.* == none) return false;
            if (std.mem.indexOfScalar(u32, ids[0..i], id.*) != null) return false;
        }
        // Every mention of `x` in its declaration.
        var members: std.ArrayList(Index) = .empty;
        const written = try s.arena.alloc(bool, props.len);
        @memset(written, false);
        const seen = try s.arena.alloc(bool, props.len);
        @memset(seen, false);
        var decls: u32 = 0;
        var stack: std.ArrayList(Index) = .empty;
        try stack.append(s.arena, top);
        var budget: u32 = 1 << 16;
        while (JsIr.popOperand(&stack)) |node| {
            if (budget == 0) return false;
            budget -= 1;
            const d = ir.data(node);
            switch (ir.tag(node)) {
                .ident => if (d.lhs == x.int()) return false,
                .const_decl, .let_decl, .func_decl, .gen_decl, .for_of => if (d.lhs == x.int()) {
                    decls += 1;
                },
                .member => {
                    const obj: Index = @enumFromInt(d.lhs);
                    if (ir.tag(obj) == .ident and ir.data(obj).lhs == x.int()) {
                        const id = s.pts.propId(m.index, @enumFromInt(d.rhs));
                        const k = std.mem.indexOfScalar(u32, ids, id) orelse return false;
                        try members.append(s.arena, node);
                        seen[k] = true;
                        continue;
                    }
                },
                .assign_stmt => {
                    const target: Index = @enumFromInt(d.lhs);
                    if (ir.tag(target) == .member) {
                        const obj: Index = @enumFromInt(ir.data(target).lhs);
                        if (ir.tag(obj) == .ident and ir.data(obj).lhs == x.int()) {
                            const id = s.pts.propId(m.index, @enumFromInt(ir.data(target).rhs));
                            const k = std.mem.indexOfScalar(u32, ids, id) orelse return false;
                            written[k] = true;
                        }
                    }
                },
                else => {},
            }
            switch (ir.tag(node)) {
                .arrow, .func_decl, .gen_decl => {
                    const record: ExtraIndex = @enumFromInt(if (ir.tag(node) == .arrow) d.lhs else d.rhs);
                    const f = ir.extraData(record, JsIr.Func);
                    for (ir.extraSlice(f.params(), NameIndex)) |p| if (p == x) {
                        decls += 1;
                    };
                },
                else => {},
            }
            try pushChildren(s.arena, ir, node, &stack);
        }
        if (decls != 1) return false;

        const kept = if (m.tables) |t| std.mem.indexOfScalar(Index, t.keep.items, stmt) != null else false;
        // How many reads each key has: a key never written whose value is
        // an atom — a short literal, any literal read once, or a name
        // nothing assigns — is that atom where it is read.
        const uses = try s.arena.alloc(u32, props.len);
        @memset(uses, 0);
        for (members.items, 0..) |node, i| {
            if (std.mem.indexOfScalar(Index, members.items[0..i], node) != null) continue;
            uses[std.mem.indexOfScalar(u32, ids, s.pts.propId(m.index, @enumFromInt(m.ir.data(node).rhs))).?] += 1;
        }
        const names = try s.arena.alloc(NameIndex, props.len);
        const atoms = try s.arena.alloc(?Index, props.len);
        for (props, names, atoms, 0..) |p, *n, *a, k| {
            const v: Index = @enumFromInt(m.ir.data(p).rhs);
            a.* = null;
            n.* = .none;
            if (!seen[k] and !written[k] and inert(m.ir, v)) continue;
            if (!written[k]) {
                const atom = switch (m.ir.tag(v)) {
                    .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => literalLen(m.ir, v) <= 5 or uses[k] <= 1,
                    // A name declared twice in the declaration may mean
                    // another binding where the key is read.
                    .ident => try s.atomArgument(m, v, top, s.assigned) and
                        (m.globalOf(@enumFromInt(m.ir.data(v).lhs)) != null or try declCount(s.arena, m.ir, top, @enumFromInt(m.ir.data(v).lhs)) <= 1),
                    else => false,
                };
                if (atom) {
                    a.* = v;
                    continue;
                }
            }
            n.* = try s.freshLocal(m);
            const decl = try m.addNode(s.gpa, if (written[k]) .let_decl else .const_decl, m.ir.pos(p), n.*.int(), v.int());
            try out.append(s.arena, decl.int());
            if (m.tables) |t| if (kept and !inert(m.ir, v)) try t.keep.append(s.arena, decl);
        }
        for (members.items) |node| {
            // A node two parents share is met twice.
            if (m.ir.tag(node) != .member) continue;
            const id = s.pts.propId(m.index, @enumFromInt(m.ir.data(node).rhs));
            const k = std.mem.indexOfScalar(u32, ids, id).?;
            if (atoms[k]) |a| m.copyNode(node, a) else m.setNode(node, .ident, names[k].int(), 0);
        }
        return true;
    }

    /// A local name no name of the module has.
    fn freshLocal(s: *Spec, m: *Mod) Allocator.Error!NameIndex {
        if (m.next_tag == 0) {
            var max: u32 = 0;
            // A record field's `Name.field` disambiguates nothing.
            for (m.names.items) |x| if (x.tag != JsIr.Name.field) {
                max = @max(max, x.tag);
            };
            m.next_tag = max + 1;
        }
        const tag = m.next_tag;
        m.next_tag += 1;
        return m.addName(s.gpa, .{ .module = .none, .base = s.in.fresh.unwrap().?, .tag = tag });
    }

    // ---- Slice 8: a small function, wherever it is called ------------------

    /// A top-level function whose body is one `return e`, as slice 8 sees it.
    const Small = struct {
        module: u32,
        params: []const NameIndex,
        ret: Index,
        /// Nodes of `e`, the size model's unit.
        cost: u32,
        /// Per parameter: reads in `e`.
        reads: []u32,
        /// Per parameter read once: the read is the first thing `e`
        /// evaluates that could do anything, and it is evaluated whenever
        /// `e` is (`firstUse`).
        first: []bool,
    };

    /// `backend.md` §9, *Slice 8*: a call of a top-level function whose
    /// body is one `return e` is `e`, its parameters the arguments, wherever
    /// that is no larger than the call — an identity, a function that
    /// returns a name, a wrapper of another call. Every argument is an atom,
    /// or one non-atom read exactly once, first, and unconditionally, so
    /// that each is evaluated once and in its order. True when any was.
    fn inlineSmall(s: *Spec) Allocator.Error!bool {
        if (s.in.fresh == .none) return false;
        var any = false;
        var pass: u32 = 0;
        while (pass < 4) : (pass += 1) {
            // Fact 3 answers for the program as the last facts saw it: the
            // first pass only, before any body is written in.
            if (!try s.inlineSmallPass(pass == 0 and s.pts.ok)) break;
            any = true;
        }
        return any;
    }

    /// Arrow `value` of module `module` as slice 8 sees it, or null: one
    /// `return e`, `e` small, holding no function and no `yield`, naming
    /// nothing but its parameters and whole-program names — and not `self`,
    /// the name it is declared by, when it has one.
    fn smallOf(s: *Spec, module: u32, value: Index, self: ?u32) Allocator.Error!?Small {
        const fm = &s.mods[module];
        if (fm.ir.tag(value) != .arrow or fm.ir.data(value).rhs != Node.arrow_plain) return null;
        const f = fm.ir.extraData(@enumFromInt(fm.ir.data(value).lhs), JsIr.Func);
        const body = fm.ir.extraSlice(f.body(), Index);
        if (body.len != 1 or fm.ir.tag(body[0]) != .return_stmt) return null;
        const ret = (@as(Node.OptionalIndex, @enumFromInt(fm.ir.data(body[0]).lhs))).unwrap() orelse return null;
        // Copied: writing a body in appends to `extra`, which may move it.
        const params = try s.arena.dupe(NameIndex, fm.ir.extraSlice(f.params(), NameIndex));
        for (params, 0..) |p, i| if (std.mem.indexOfScalar(NameIndex, params[0..i], p) != null) return null;
        const reads = try s.arena.alloc(u32, params.len);
        @memset(reads, 0);
        var cost: u32 = 0;
        var stack: std.ArrayList(Index) = .empty;
        try stack.append(s.arena, ret);
        while (JsIr.popOperand(&stack)) |node| {
            cost += 1;
            if (cost > 24) return null;
            switch (fm.ir.tag(node)) {
                // A function in it is made on each call: kept out, with its
                // declarations and captures.
                .arrow => return null,
                .ident => {
                    const x: NameIndex = @enumFromInt(fm.ir.data(node).lhs);
                    if (std.mem.indexOfScalar(NameIndex, params, x)) |i| {
                        reads[i] += 1;
                    } else if (fm.globalOf(x)) |h| {
                        // Itself: a recursion is no expression.
                        if (self != null and h == self.?) return null;
                    } else return null;
                },
                .unary => if (@as(JsIr.UnaryOp, @enumFromInt(fm.ir.data(node).rhs)) == .yield) return null,
                else => {},
            }
            try fm.ir.pushOperands(s.arena, &stack, node);
        }
        const first = try s.arena.alloc(bool, params.len);
        for (params, first, reads) |p, *fi, r| fi.* = r == 1 and firstUse(fm.ir, ret, p, 0) == .found;
        return .{ .module = module, .params = params, .ret = ret, .cost = nodeCount(fm.ir, ret, &s.pts, module), .reads = reads, .first = first };
    }

    fn inlineSmallPass(s: *Spec, resolve: bool) Allocator.Error!bool {
        const n = s.in.globals;
        const smalls = try s.arena.alloc(?Small, n);
        @memset(smalls, null);
        for (s.decl, 0..) |maybe, gi| {
            const decl = maybe orelse continue;
            const g: u32 = @intCast(gi);
            if (s.assigned[g]) continue;
            const fm = &s.mods[decl.module];
            if (fm.ir.tag(decl.stmt) != .const_decl) continue;
            if (std.mem.indexOfScalar(Index, fm.ir.extraSlice(fm.ir.body, Index), decl.stmt) == null) continue;
            smalls[g] = try s.smallOf(decl.module, @enumFromInt(fm.ir.data(decl.stmt).rhs), g);
        }
        // A function a call reaches through a property — `kind.m(…)` — when
        // fact 3 says the callee is that one function, reading it does
        // nothing, and the facts are of the program as it stands.
        // Per site: unasked, not small, or its `Small`.
        const by_site = try s.arena.alloc(?Small, if (resolve) s.pts.sites.items.len else 0);
        const asked = try s.arena.alloc(bool, by_site.len);
        @memset(asked, false);
        // Every call of one, in module order.
        var any = false;
        var stack: std.ArrayList(Index) = .empty;
        for (s.mods, 0..) |*m, mi| {
            const ir = m.ir;
            var calls: std.ArrayList(struct { top: Index, call: Index, small: Small }) = .empty;
            for (ir.extraSlice(ir.body, Index)) |top| {
                stack.clearRetainingCapacity();
                try stack.append(s.arena, top);
                while (JsIr.popOperand(&stack)) |node| {
                    if (ir.tag(node) == .call) {
                        const callee: Index = @enumFromInt(ir.data(node).lhs);
                        if (ir.tag(callee) == .ident) {
                            if (m.globalOf(@enumFromInt(ir.data(callee).lhs))) |g| if (smalls[g]) |small| {
                                try calls.append(s.arena, .{ .top = top, .call = node, .small = small });
                            };
                        } else if (resolve and ir.tag(callee) == .member and callee.int() < s.pts.vals[mi].len) {
                            const v = s.pts.vals[mi][callee.int()];
                            if (!v.top and !v.prim and !v.nullish() and v.sites.len == 1) {
                                const site = v.sites[0];
                                const st = s.pts.sites.items[site];
                                if (st.kind == .func and !st.escaped and try s.pts.safeChain(@intCast(mi), top, callee) != null) {
                                    if (!asked[site]) by_site[site] = try s.smallOf(st.module, st.node, null);
                                    asked[site] = true;
                                    if (by_site[site]) |small| try calls.append(s.arena, .{ .top = top, .call = node, .small = small });
                                }
                            }
                        }
                    }
                    try pushChildren(s.arena, ir, node, &stack);
                }
            }
            for (calls.items) |c| {
                if (m.ir.tag(c.call) != .call) continue;
                if (try s.inlineSmallAt(m, @intCast(mi), c.top, c.call, c.small)) any = true;
            }
        }
        return any;
    }

    fn inlineSmallAt(s: *Spec, m: *Mod, mi: u32, top: Index, call: Index, small: Small) Allocator.Error!bool {
        const fm = &s.mods[small.module];
        const args = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.subRange(@enumFromInt(m.ir.data(call).rhs)), Index));
        if (args.len != small.params.len) return false;
        // Arguments: atoms, or one non-atom read once and first.
        // The callee, the brackets and the commas.
        var call_cost: u32 = 3 + @as(u32, @intCast(if (args.len > 0) args.len - 1 else 0));
        var inlined: u32 = small.cost;
        var non_atoms: u32 = 0;
        for (args, 0..) |a, i| {
            const c = nodeCount(m.ir, a, &s.pts, mi);
            call_cost += c;
            inlined = inlined - small.reads[i] + small.reads[i] * c;
            // A name nothing assigns is the same value wherever the body
            // reads it; the call's place is the body's, so it names the
            // same binding.
            const atom = switch (m.ir.tag(a)) {
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => literalLen(m.ir, a) <= 5 or small.reads[i] <= 1,
                .ident => try s.atomArgument(m, a, top, s.assigned),
                else => false,
            };
            if (atom) continue;
            if (small.reads[i] == 0 and inert(m.ir, a)) continue;
            if (!small.first[i]) return false;
            non_atoms += 1;
        }
        if (non_atoms > 1) return false;
        if (non_atoms == 1) for (args, 0..) |a, i| {
            // The others are evaluated before it in the call: they must be
            // names or literals, which evaluating later cannot tell.
            if (small.first[i] and small.reads[i] == 1) continue;
            switch (m.ir.tag(a)) {
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit, .ident => {},
                else => return false,
            }
        };
        if (inlined > call_cost) return false;

        // Names the body mentions of the whole program, as the caller
        // module spells them.
        const cross = small.module != mi;
        var c: Copy = .{
            .s = s,
            .src = fm,
            .dst = m,
            .cross = cross,
            .renamed = try s.arena.alloc(u32, fm.ir.names.len),
            .subst = try s.arena.alloc(Node.OptionalIndex, fm.ir.names.len),
        };
        @memset(c.renamed, none);
        @memset(c.subst, .none);
        if (cross) {
            var stack: std.ArrayList(Index) = .empty;
            try stack.append(s.arena, small.ret);
            while (JsIr.popOperand(&stack)) |node| {
                if (fm.ir.tag(node) == .ident) {
                    const x: NameIndex = @enumFromInt(fm.ir.data(node).lhs);
                    if (std.mem.indexOfScalar(NameIndex, small.params, x) == null) {
                        const h = fm.globalOf(x).?;
                        const to = try s.nameIn(m, h) orelse return false;
                        c.renamed[x.int()] = to.int();
                    }
                }
                try fm.ir.pushOperands(s.arena, &stack, node);
            }
        }
        for (small.params, args) |p, a| if (p.unwrap()) |pi| {
            c.subst[pi] = a.toOptional();
        };
        const e = try c.expr(small.ret, 0);
        m.copyNode(call, e);
        return true;
    }

    // ---- Slice 5: a function called once, once the whole program is seen ----

    /// `backend.md` §9, *A function called once is written where it is
    /// called*, *Once the whole program is in view*: every top-level
    /// function the program calls from exactly one place, written there,
    /// one at a time, each on the program as the last one left it. After
    /// the facts, whose per-node tables it does not grow. True when any was.
    fn inlineOnce(s: *Spec) Allocator.Error!bool {
        if (s.in.fresh == .none) return false;
        var any = false;
        var left: u32 = max_inlines;
        while (left > 0) : (left -= 1) {
            if (!try s.inlineOne()) break;
            any = true;
        }
        return any;
    }

    const CallSite = struct { module: u32, top: Index, call: Index };

    /// Count every whole-program name's mentions, and write in the first
    /// function, by whole-program id, mentioned once as a callee and fit to
    /// be written there.
    fn inlineOne(s: *Spec) Allocator.Error!bool {
        const n = s.in.globals;
        const refs = try s.arena.alloc(u32, n);
        @memset(refs, 0);
        const sites = try s.arena.alloc(?CallSite, n);
        @memset(sites, null);
        const assigned = try s.arena.alloc(bool, n);
        @memset(assigned, false);
        var stack: std.ArrayList(Index) = .empty;
        defer stack.deinit(s.arena);
        for (s.mods, 0..) |*m, mi| {
            const ir = m.ir;
            for (ir.extraSlice(ir.body, Index)) |top| {
                stack.clearRetainingCapacity();
                try stack.append(s.arena, top);
                while (JsIr.popOperand(&stack)) |node| {
                    const d = ir.data(node);
                    switch (ir.tag(node)) {
                        .ident => if (m.globalOf(@enumFromInt(d.lhs))) |g| {
                            refs[g] +|= 1;
                        },
                        .call => {
                            const callee: Index = @enumFromInt(d.lhs);
                            if (ir.tag(callee) == .ident) if (m.globalOf(@enumFromInt(ir.data(callee).lhs))) |g| {
                                sites[g] = .{ .module = @intCast(mi), .top = top, .call = node };
                            };
                        },
                        .assign_stmt => {
                            const target: Index = @enumFromInt(d.lhs);
                            if (ir.tag(target) == .ident) if (m.globalOf(@enumFromInt(ir.data(target).lhs))) |g| {
                                assigned[g] = true;
                            };
                        },
                        else => {},
                    }
                    try pushChildren(s.arena, ir, node, &stack);
                }
            }
        }
        // Which are candidates at all.
        const fit = try s.arena.alloc(bool, n);
        @memset(fit, false);
        for (0..n) |gi| {
            const g: u32 = @intCast(gi);
            if (refs[g] != 1) continue;
            const site = sites[g] orelse continue;
            const decl = s.decl[g] orelse continue;
            if (isRoot(s.in, g)) continue;
            const fm = &s.mods[decl.module];
            if (fm.ir.tag(decl.stmt) != .const_decl) continue;
            // Still written: reachability may have dropped it.
            if (std.mem.indexOfScalar(Index, fm.ir.extraSlice(fm.ir.body, Index), decl.stmt) == null) continue;
            const value: Index = @enumFromInt(fm.ir.data(decl.stmt).rhs);
            if (fm.ir.tag(value) != .arrow or fm.ir.data(value).rhs != Node.arrow_plain) continue;
            if (site.module == decl.module and site.top == decl.stmt) continue;
            fit[g] = true;
        }
        // The innermost first: a function called from inside another
        // candidate is written there before that one is written anywhere,
        // where its call may stand where only an expression can.
        for ([_]bool{ true, false }) |inner| {
            for (0..n) |gi| {
                const g: u32 = @intCast(gi);
                if (!fit[g]) continue;
                const site = sites[g].?;
                const in_candidate = blk: {
                    const cm = &s.mods[site.module];
                    const t = cm.ir.tag(site.top);
                    if (t != .const_decl and t != .func_decl) break :blk false;
                    const h = cm.globalOf(@enumFromInt(cm.ir.data(site.top).lhs)) orelse break :blk false;
                    break :blk fit[h];
                };
                if (in_candidate != inner) continue;
                const decl = s.decl[g].?;
                const value: Index = @enumFromInt(s.mods[decl.module].ir.data(decl.stmt).rhs);
                if (try s.inlineAt(decl, value, site, assigned)) return true;
            }
        }
        return false;
    }

    /// What `scanBody` learns of a function's body.
    const BodyScan = struct {
        nodes: u32 = 0,
        /// Per name of the module: how many times the function declares it —
        /// its parameters, its nested functions', `const`, `let`,
        /// `function`, `for…of` and labels — and those names in the order
        /// first met.
        counts: []u32 = &.{},
        declared: std.ArrayList(u32) = .empty,
        /// The names its body's own statement list declares, which become
        /// top-level bindings when that list is written at a module's top.
        top_names: std.ArrayList(u32) = .empty,
        /// Every name an `ident` of it reads or assigns.
        mentioned: std.ArrayList(u32) = .empty,
        /// Per parameter: reads, and whether the body assigns it.
        reads: []u32 = &.{},
        /// Per parameter: a read of it may run more than once — in a loop
        /// or a nested function.
        repeated: []bool = &.{},
        /// How many loops and nested functions the walk is in.
        repeat: u32 = 0,
        assigns: []bool = &.{},
        /// Its own `return`s (not a nested function's): how many, whether
        /// any says a value, and whether its last statement is one.
        returns: u32 = 0,
        valued: bool = false,
        final_return: bool = false,
        ok: bool = true,
    };

    /// Walk the callee's body once; false when it is too big or too deep to
    /// copy by recursion.
    fn scanBody(s: *Spec, fm: *Mod, f: JsIr.Func, out: *BodyScan) Allocator.Error!bool {
        const params = fm.ir.extraSlice(f.params(), NameIndex);
        out.reads = try s.arena.alloc(u32, params.len);
        @memset(out.reads, 0);
        out.repeated = try s.arena.alloc(bool, params.len);
        @memset(out.repeated, false);
        out.assigns = try s.arena.alloc(bool, params.len);
        @memset(out.assigns, false);
        out.counts = try s.arena.alloc(u32, fm.ir.names.len);
        @memset(out.counts, 0);
        for (params) |p| try s.declared(out, p);
        const body = fm.ir.extraSlice(f.body(), Index);
        for (body) |stmt| switch (fm.ir.tag(stmt)) {
            .const_decl, .let_decl, .func_decl, .gen_decl => try out.top_names.append(s.arena, fm.ir.data(stmt).lhs),
            else => {},
        };
        if (body.len != 0 and fm.ir.tag(body[body.len - 1]) == .return_stmt) out.final_return = true;
        try s.scanList(fm, f.body(), params, out, 0, true);
        return out.ok;
    }

    fn declared(s: *Spec, out: *BodyScan, n: NameIndex) Allocator.Error!void {
        const i = n.unwrap() orelse return;
        if (i >= out.counts.len) {
            out.ok = false;
            return;
        }
        if (out.counts[i] == 0) try out.declared.append(s.arena, i);
        out.counts[i] += 1;
    }

    fn scanList(s: *Spec, fm: *Mod, range: JsIr.SubRange, params: []const NameIndex, out: *BodyScan, depth: u32, own: bool) Allocator.Error!void {
        for (fm.ir.extraSlice(range, Index)) |stmt| try s.scanNode(fm, stmt, params, out, depth + 1, own);
    }

    /// One node of the body; `own` is whether a `return` here is the
    /// callee's own (not a nested function's).
    fn scanNode(s: *Spec, fm: *Mod, node: Index, params: []const NameIndex, out: *BodyScan, depth: u32, own: bool) Allocator.Error!void {
        if (!out.ok) return;
        out.nodes += 1;
        if (depth > max_inline_depth or out.nodes > max_inline_nodes) {
            out.ok = false;
            return;
        }
        const ir = fm.ir;
        const d = ir.data(node);
        switch (ir.tag(node)) {
            .ident => {
                const n: NameIndex = @enumFromInt(d.lhs);
                try out.mentioned.append(s.arena, d.lhs);
                if (std.mem.indexOfScalar(NameIndex, params, n)) |i| {
                    out.reads[i] += 1;
                    if (out.repeat != 0) out.repeated[i] = true;
                }
            },
            .const_decl => {
                try s.declared(out, @enumFromInt(d.lhs));
                try s.scanNode(fm, @enumFromInt(d.rhs), params, out, depth + 1, own);
            },
            .let_decl => {
                try s.declared(out, @enumFromInt(d.lhs));
                if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| try s.scanNode(fm, v, params, out, depth + 1, own);
            },
            .func_decl, .gen_decl => {
                try s.declared(out, @enumFromInt(d.lhs));
                try s.scanFunc(fm, @enumFromInt(d.rhs), params, out, depth);
            },
            .arrow => try s.scanFunc(fm, @enumFromInt(d.lhs), params, out, depth),
            .assign_stmt => {
                const target: Index = @enumFromInt(d.lhs);
                if (ir.tag(target) == .ident) {
                    const n: NameIndex = @enumFromInt(ir.data(target).lhs);
                    if (std.mem.indexOfScalar(NameIndex, params, n)) |i| out.assigns[i] = true;
                }
                try s.scanNode(fm, target, params, out, depth + 1, own);
                try s.scanNode(fm, @enumFromInt(d.rhs), params, out, depth + 1, own);
            },
            .return_stmt => {
                if (own) {
                    out.returns += 1;
                    if (d.lhs != @intFromEnum(Node.OptionalIndex.none)) out.valued = true;
                }
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| try s.scanNode(fm, v, params, out, depth + 1, own);
            },
            .if_stmt => {
                try s.scanNode(fm, @enumFromInt(d.lhs), params, out, depth + 1, own);
                const b = ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                try s.scanList(fm, b.thenBody(), params, out, depth, own);
                try s.scanList(fm, b.elseBody(), params, out, depth, own);
            },
            .while_true, .block_stmt => {
                const loops = ir.tag(node) == .while_true;
                if (loops) out.repeat += 1;
                defer if (loops) {
                    out.repeat -= 1;
                };
                try s.declared(out, @enumFromInt(d.lhs));
                try s.scanList(fm, ir.subRange(@enumFromInt(d.rhs)), params, out, depth, own);
            },
            .for_of => {
                try s.declared(out, @enumFromInt(d.lhs));
                const loop = ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                try s.scanNode(fm, loop.iterable, params, out, depth + 1, own);
                out.repeat += 1;
                defer out.repeat -= 1;
                try s.scanList(fm, loop.body(), params, out, depth, own);
            },
            .switch_stmt => {
                try s.scanNode(fm, @enumFromInt(d.lhs), params, out, depth + 1, own);
                try s.scanList(fm, ir.subRange(@enumFromInt(d.rhs)), params, out, depth, own);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| try s.scanNode(fm, t, params, out, depth + 1, own);
                try s.scanList(fm, ir.subRange(@enumFromInt(d.rhs)), params, out, depth, own);
            },
            .break_stmt, .continue_stmt, .number, .string, .template_chunk, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this => {},
            .expr_stmt, .throw_stmt => try s.scanNode(fm, @enumFromInt(d.lhs), params, out, depth + 1, own),
            // A `return` in either block is the callee's own: written where
            // the call stood, it leaves the caller from inside the same
            // `try`, and the cleanup still runs first. The body's last
            // statement is the `try`, never a `return`, so a call whose value
            // is wanted is written there only in `return` position.
            .try_stmt => {
                const t = ir.extraData(@enumFromInt(d.rhs), JsIr.Try);
                try s.scanList(fm, t.body(), params, out, depth, own);
                try s.scanList(fm, t.finalBody(), params, out, depth, own);
            },
            .import_stmt, .export_stmt => out.ok = false,
            else => {
                var children: std.ArrayList(Index) = .empty;
                try ir.pushOperands(s.arena, &children, node);
                for (children.items) |c| try s.scanNode(fm, c, params, out, depth + 1, own);
            },
        }
    }

    fn scanFunc(s: *Spec, fm: *Mod, record: ExtraIndex, params: []const NameIndex, out: *BodyScan, depth: u32) Allocator.Error!void {
        const f = fm.ir.extraData(record, JsIr.Func);
        for (fm.ir.extraSlice(f.params(), NameIndex)) |p| try s.declared(out, p);
        out.repeat += 1;
        defer out.repeat -= 1;
        try s.scanList(fm, f.body(), params, out, depth, false);
    }

    /// Whether argument `a` of a call in top-level statement `top` is an
    /// atom: a literal, or a name nothing assigns — a whole-program name no
    /// statement assigns, or a local its declaration never does.
    fn atomArgument(s: *Spec, m: *Mod, a: Index, top: Index, assigned: []const bool) Allocator.Error!bool {
        const ir = m.ir;
        switch (ir.tag(a)) {
            .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => return true,
            .ident => {},
            else => return false,
        }
        const n: NameIndex = @enumFromInt(ir.data(a).lhs);
        if (m.globalOf(n)) |g| return !assigned[g];
        var stack: std.ArrayList(Index) = .empty;
        defer stack.deinit(s.arena);
        try stack.append(s.arena, top);
        while (JsIr.popOperand(&stack)) |node| {
            if (ir.tag(node) == .assign_stmt) {
                const target: Index = @enumFromInt(ir.data(node).lhs);
                if (ir.tag(target) == .ident and ir.data(target).lhs == n.int()) return false;
            }
            try pushChildren(s.arena, ir, node, &stack);
        }
        return true;
    }

    /// Whether every name inert expression `root` reads outside the
    /// functions in it is an atom (`atomArgument`): nothing can have changed
    /// it by the time the expression is made later.
    fn immutableNames(s: *Spec, m: *Mod, root: Index, top: Index, assigned: []const bool) Allocator.Error!bool {
        var stack: std.ArrayList(Index) = .empty;
        defer stack.deinit(s.arena);
        try stack.append(s.arena, root);
        while (JsIr.popOperand(&stack)) |node| {
            switch (m.ir.tag(node)) {
                .ident => if (!try s.atomArgument(m, node, top, assigned)) return false,
                .arrow => {},
                else => try m.ir.pushOperands(s.arena, &stack, node),
            }
        }
        return true;
    }

    /// Module `m`'s name for whole-program name `g`, when a live statement
    /// of it mentions `g` — reads, calls or declares it at its top level,
    /// so the module has it bound in either layout; null otherwise.
    fn namedIn(s: *Spec, m: *Mod, g: u32) Allocator.Error!?NameIndex {
        const ir = m.ir;
        var stack: std.ArrayList(Index) = .empty;
        defer stack.deinit(s.arena);
        for (ir.extraSlice(ir.body, Index)) |top| {
            switch (ir.tag(top)) {
                .import_stmt, .export_stmt => continue,
                .const_decl, .let_decl, .func_decl, .gen_decl => {
                    const n: NameIndex = @enumFromInt(ir.data(top).lhs);
                    if (m.globalOf(n) == g) return n;
                },
                else => {},
            }
            stack.clearRetainingCapacity();
            try stack.append(s.arena, top);
            while (JsIr.popOperand(&stack)) |node| {
                if (ir.tag(node) == .ident) {
                    const n: NameIndex = @enumFromInt(ir.data(node).lhs);
                    if (m.globalOf(n) == g) return n;
                }
                try pushChildren(s.arena, ir, node, &stack);
            }
        }
        return null;
    }

    /// Whether anything reads name `n`, declared in top-level statement
    /// `top` of module `m`: a whole-program name anywhere, a local there.
    fn nameRead(s: *Spec, m: *Mod, top: Index, n: NameIndex) Allocator.Error!bool {
        const g = m.globalOf(n);
        var stack: std.ArrayList(Index) = .empty;
        defer stack.deinit(s.arena);
        for (s.mods) |*other| {
            if (g == null and other != m) continue;
            const ir = other.ir;
            stack.clearRetainingCapacity();
            if (g == null) try stack.append(s.arena, top) else try stack.appendSlice(s.arena, ir.extraSlice(ir.body, Index));
            while (JsIr.popOperand(&stack)) |node| {
                if (ir.tag(node) == .ident) {
                    const x: NameIndex = @enumFromInt(ir.data(node).lhs);
                    if (g) |want| {
                        if (other.globalOf(x) == want) return true;
                    } else if (x == n) return true;
                }
                try pushChildren(s.arena, ir, node, &stack);
            }
        }
        return false;
    }

    /// Where a call stands in its caller.
    const Place = struct {
        kind: enum { expr, ret, stmt, decl },
        /// The statement the call is the whole expression of.
        stmt: Index = undefined,
        /// Where that statement's list's range is stored: two words of
        /// `extra`, or the module body when null.
        owner: ?u32 = null,
        /// The statement is the last of a function's body.
        tail: bool = false,
        /// The list is the module body.
        top_level: bool = false,
    };

    fn placeOf(s: *Spec, m: *Mod, site: CallSite) Allocator.Error!?Place {
        if (try s.placeAmong(m, null, &.{site.top}, false, true, site.call, 0)) |p| return p;
        return null;
    }

    /// Look for `call` in the statements `list`, whose range lives at
    /// `owner`.
    fn placeAmong(s: *Spec, m: *Mod, owner: ?u32, list: []const Index, fn_body: bool, top_level: bool, call: Index, depth: u32) Allocator.Error!?Place {
        if (depth > max_depth) return null;
        const ir = m.ir;
        for (list, 0..) |stmt, i| {
            const d = ir.data(stmt);
            const root: ?Index = switch (ir.tag(stmt)) {
                .expr_stmt, .const_decl => @enumFromInt(if (ir.tag(stmt) == .expr_stmt) d.lhs else d.rhs),
                .return_stmt => @as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap(),
                .let_decl => @as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap(),
                else => null,
            };
            if (root) |r| if (r == call) return .{
                .kind = switch (ir.tag(stmt)) {
                    .expr_stmt => .stmt,
                    .return_stmt => .ret,
                    else => .decl,
                },
                .stmt = stmt,
                .owner = owner,
                .tail = fn_body and i + 1 == list.len,
                .top_level = top_level,
            };
            if (try s.placeIn(m, stmt, call, depth + 1)) |p| return p;
        }
        return null;
    }

    /// Look for `call` inside statement `stmt`: its lists, and its
    /// expressions and the functions in them.
    fn placeIn(s: *Spec, m: *Mod, stmt: Index, call: Index, depth: u32) Allocator.Error!?Place {
        const ir = m.ir;
        const d = ir.data(stmt);
        switch (ir.tag(stmt)) {
            .func_decl, .gen_decl => {
                const at = d.rhs;
                return s.placeAmong(m, at + 2, ir.extraSlice(ir.extraData(@enumFromInt(at), JsIr.Func).body(), Index), true, false, call, depth);
            },
            .if_stmt => {
                if (try s.placeExpr(m, @enumFromInt(d.lhs), call, depth)) |p| return p;
                const b = ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                if (try s.placeAmong(m, d.rhs, ir.extraSlice(b.thenBody(), Index), false, false, call, depth)) |p| return p;
                return s.placeAmong(m, d.rhs + 2, ir.extraSlice(b.elseBody(), Index), false, false, call, depth);
            },
            .while_true, .block_stmt => return s.placeAmong(m, d.rhs, ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index), false, false, call, depth),
            .for_of => {
                const loop = ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                if (try s.placeExpr(m, loop.iterable, call, depth)) |p| return p;
                return s.placeAmong(m, d.rhs + 1, ir.extraSlice(loop.body(), Index), false, false, call, depth);
            },
            .switch_stmt => {
                if (try s.placeExpr(m, @enumFromInt(d.lhs), call, depth)) |p| return p;
                for (ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index)) |c| {
                    const cd = ir.data(c);
                    if (@as(Node.OptionalIndex, @enumFromInt(cd.lhs)).unwrap()) |t| if (try s.placeExpr(m, t, call, depth)) |p| return p;
                    if (try s.placeAmong(m, cd.rhs, ir.extraSlice(ir.subRange(@enumFromInt(cd.rhs)), Index), false, false, call, depth)) |p| return p;
                }
                return null;
            },
            .const_decl => return s.placeExpr(m, @enumFromInt(d.rhs), call, depth),
            .let_decl, .return_stmt => {
                const v = @as(Node.OptionalIndex, @enumFromInt(if (ir.tag(stmt) == .let_decl) d.rhs else d.lhs)).unwrap() orelse return null;
                return s.placeExpr(m, v, call, depth);
            },
            .assign_stmt => {
                if (try s.placeExpr(m, @enumFromInt(d.lhs), call, depth)) |p| return p;
                return s.placeExpr(m, @enumFromInt(d.rhs), call, depth);
            },
            .expr_stmt, .throw_stmt => return s.placeExpr(m, @enumFromInt(d.lhs), call, depth),
            // A call in either block is written into that block, which is
            // where its statements then run: inside the guard, or as part
            // of the cleanup. Neither block is a function's body, so a call
            // that ends one is never taken for a tail.
            .try_stmt => {
                const t = ir.extraData(@enumFromInt(d.rhs), JsIr.Try);
                if (try s.placeAmong(m, d.rhs, ir.extraSlice(t.body(), Index), false, false, call, depth)) |p| return p;
                return s.placeAmong(m, d.rhs + 2, ir.extraSlice(t.finalBody(), Index), false, false, call, depth);
            },
            else => return null,
        }
    }

    fn placeExpr(s: *Spec, m: *Mod, root: Index, call: Index, depth: u32) Allocator.Error!?Place {
        var stack: std.ArrayList(Index) = .empty;
        defer stack.deinit(s.arena);
        try stack.append(s.arena, root);
        while (JsIr.popOperand(&stack)) |node| {
            if (node == call) return .{ .kind = .expr };
            if (m.ir.tag(node) == .arrow) {
                const at = m.ir.data(node).lhs;
                if (try s.placeAmong(m, at + 2, m.ir.extraSlice(m.ir.extraData(@enumFromInt(at), JsIr.Func).body(), Index), true, false, call, depth + 1)) |p| return p;
                continue;
            }
            try m.ir.pushOperands(s.arena, &stack, node);
        }
        return null;
    }

    /// Write function `value` (declared by `decl`) at its one call `site`,
    /// when every rule allows; false, with nothing changed, otherwise.
    fn inlineAt(s: *Spec, decl: Decl, value: Index, site: CallSite, assigned: []const bool) Allocator.Error!bool {
        const fm = &s.mods[decl.module];
        const cm = &s.mods[site.module];
        const cross = decl.module != site.module;
        const f = fm.ir.extraData(@enumFromInt(fm.ir.data(value).lhs), JsIr.Func);
        const params = try s.arena.dupe(NameIndex, fm.ir.extraSlice(f.params(), NameIndex));
        const body = try s.arena.dupe(Index, fm.ir.extraSlice(f.body(), Index));
        const args = try s.arena.dupe(Index, cm.ir.extraSlice(cm.ir.subRange(@enumFromInt(cm.ir.data(site.call).rhs)), Index));
        if (args.len != params.len) return false;

        var scan: BodyScan = .{};
        if (!try s.scanBody(fm, f, &scan)) return false;
        // A parameter declared again inside is not one name to substitute.
        for (params) |p| if (p.unwrap()) |i| if (scan.counts[i] > 1) return false;
        // Another module's function names nothing but its own locals and
        // whole-program names the caller's module already names — so the
        // caller needs no import it lacks, in either layout.
        var outer: std.ArrayList(struct { from: u32, to: u32 }) = .empty;
        if (cross) for (scan.mentioned.items) |n| {
            if (n < scan.counts.len and scan.counts[n] != 0) continue;
            const g = fm.globalOf(@enumFromInt(n)) orelse return false;
            const to = try s.namedIn(cm, g) orelse return false;
            try outer.append(s.arena, .{ .from = n, .to = to.int() });
        };
        // Arguments: atoms — or an argument that makes a value and nothing
        // else, of immutable names, whose parameter is read once and not
        // again by a loop or a later call: it is made where it is read,
        // once, as it was made once before the body.
        for (args, 0..) |a, i| {
            if (try s.atomArgument(cm, a, site.top, assigned)) continue;
            if (!inert(cm.ir, a) or scan.reads[i] > 1 or scan.repeated[i] or scan.assigns[i]) return false;
            if (!try s.immutableNames(cm, a, site.top, assigned)) return false;
        }

        const place = try s.placeOf(cm, site) orelse return false;
        const single = body.len == 1 and scan.final_return and scan.valued and scan.returns == 1;
        const Form = enum { expr, ret, stmt, decl };
        const form: Form = if (single) .expr else switch (place.kind) {
            .expr => return false,
            .ret => .ret,
            .stmt => blk: {
                if (scan.returns == 0 or (scan.returns == 1 and scan.final_return)) break :blk .stmt;
                if (place.tail and !scan.valued) break :blk .ret;
                return false;
            },
            .decl => if (scan.returns == 1 and scan.final_return and scan.valued) .decl else return false,
        };
        const top = form == .decl and place.top_level;
        if (top and cm.self == .none) return false;
        // A call the optimiser drops — a discarded pure call, or a binding
        // nothing reads whose initialiser may not do anything — would come
        // back as the body's statements: written as the call it is.
        if (form == .stmt or form == .ret or form == .decl) if (cm.tables) |t| {
            if (form == .stmt and std.mem.indexOfScalar(Index, t.discards.items, place.stmt) != null) return false;
            if (form == .decl and std.mem.indexOfScalar(Index, t.keep.items, place.stmt) == null and
                !try s.nameRead(cm, site.top, @enumFromInt(cm.ir.data(place.stmt).lhs))) return false;
        };

        // Each parameter: its argument, written where it is read, or a
        // binding of its own — where a statement can stand.
        const bind = try s.arena.alloc(bool, params.len);
        for (params, args, 0..) |_, a, i| {
            const long = switch (cm.ir.tag(a)) {
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => literalLen(cm.ir, a) > 5 and scan.reads[i] > 1,
                else => false,
            };
            bind[i] = scan.assigns[i] or long;
            if (bind[i] and form == .expr) return false;
        }

        var c: Copy = .{
            .s = s,
            .src = fm,
            .dst = cm,
            .cross = cross,
            .renamed = try s.arena.alloc(u32, fm.ir.names.len),
            .subst = try s.arena.alloc(Node.OptionalIndex, fm.ir.names.len),
        };
        @memset(c.renamed, none);
        @memset(c.subst, .none);
        for (outer.items) |o| c.renamed[o.from] = o.to;
        // Fresh names for every name the function declares: its top list's
        // are the caller module's top-level bindings when that list is
        // written at the module's top.
        for (scan.declared.items) |n| {
            if (std.mem.indexOfScalar(NameIndex, params, @enumFromInt(n)) != null) continue;
            const global = top and std.mem.indexOfScalar(u32, scan.top_names.items, n) != null;
            try c.fresh(n, global);
        }
        var bindings: std.ArrayList(u32) = .empty;
        for (params, args, bind) |p, a, b| {
            const pi = p.unwrap() orelse continue;
            if (b) {
                try c.fresh(pi, top);
                const name = c.renamed[pi];
                const first = try c.atom(a);
                const tag: Node.Tag = if (scan.assigns[std.mem.indexOfScalar(NameIndex, params, p).?]) .let_decl else .const_decl;
                try bindings.append(s.arena, (try cm.addNode(s.gpa, tag, Node.no_pos, name, first.int())).int());
            } else c.subst[pi] = a.toOptional();
        }

        switch (form) {
            .expr => {
                const ret: Index = @enumFromInt(fm.ir.data(body[0]).lhs);
                const e = try c.expr(ret, 0);
                cm.copyNode(site.call, e);
            },
            .ret => {
                var out: std.ArrayList(u32) = .empty;
                try out.appendSlice(s.arena, bindings.items);
                for (body) |stmt| try out.append(s.arena, (try c.stmt(stmt, 0)).int());
                try s.splice(cm, place, out.items, false);
            },
            .stmt => {
                var out: std.ArrayList(u32) = .empty;
                try out.appendSlice(s.arena, bindings.items);
                for (body, 0..) |stmt, i| {
                    if (i + 1 == body.len and fm.ir.tag(stmt) == .return_stmt) {
                        // The last `return`'s value, kept as a statement when
                        // evaluating it may do something.
                        const v = @as(Node.OptionalIndex, @enumFromInt(fm.ir.data(stmt).lhs)).unwrap() orelse continue;
                        if (inert(fm.ir, v)) continue;
                        const e = try c.expr(v, 0);
                        try out.append(s.arena, (try cm.addNode(s.gpa, .expr_stmt, Node.no_pos, e.int(), 0)).int());
                        continue;
                    }
                    try out.append(s.arena, (try c.stmt(stmt, 0)).int());
                }
                try s.splice(cm, place, out.items, false);
            },
            .decl => {
                var out: std.ArrayList(u32) = .empty;
                try out.appendSlice(s.arena, bindings.items);
                for (body[0 .. body.len - 1]) |stmt| try out.append(s.arena, (try c.stmt(stmt, 0)).int());
                const ret: Index = @enumFromInt(fm.ir.data(body[body.len - 1]).lhs);
                const e = try c.expr(ret, 0);
                const d = cm.ir.data(place.stmt);
                cm.setData(place.stmt, d.lhs, e.int());
                try out.append(s.arena, place.stmt.int());
                try s.splice(cm, place, out.items, true);
            },
        }
        return true;
    }

    /// Put `stmts` where `place.stmt` stands in its list (they include it
    /// when `kept`).
    fn splice(s: *Spec, m: *Mod, place: Place, stmts: []const u32, kept: bool) Allocator.Error!void {
        _ = kept;
        const list = if (place.owner) |o| m.ir.extraSlice(.{ .start = @enumFromInt(m.extra.items[o]), .end = @enumFromInt(m.extra.items[o + 1]) }, u32) else m.ir.extraSlice(m.ir.body, u32);
        var out: std.ArrayList(u32) = .empty;
        for (list) |raw| {
            if (raw == place.stmt.int()) {
                try out.appendSlice(s.arena, stmts);
                continue;
            }
            try out.append(s.arena, raw);
        }
        const start = try m.append(s.gpa, out.items);
        const end: u32 = start + @as(u32, @intCast(out.items.len));
        if (place.owner) |o| {
            m.extra.items[o] = start;
            m.extra.items[o + 1] = end;
        } else m.ir.body = .{ .start = @enumFromInt(start), .end = @enumFromInt(end) };
    }

    /// A body copied from one module into another (or into itself): every
    /// node new, every name the function declares fresh, every parameter
    /// its argument or its binding, and every table entry of a node or a
    /// name repeated for its copy.
    const Copy = struct {
        s: *Spec,
        src: *Mod,
        dst: *Mod,
        cross: bool,
        /// A declared name of the source, and its new name.
        renamed: []u32,
        /// A parameter of the source, and the argument (a node of the
        /// destination) each read of it is.
        subst: []Node.OptionalIndex,

        fn gpa(c: *Copy) Allocator {
            return c.s.gpa;
        }

        /// A new name for source name `n`: a local, or a top-level binding
        /// of the destination module.
        fn fresh(c: *Copy, n: u32, global: bool) Allocator.Error!void {
            if (n >= c.renamed.len or c.renamed[n] != none) return;
            if (c.dst.next_tag == 0) {
                var max: u32 = 0;
                // A record field's `Name.field` disambiguates nothing.
                for (c.dst.names.items) |x| if (x.tag != JsIr.Name.field) {
                    max = @max(max, x.tag);
                };
                c.dst.next_tag = max + 1;
            }
            const tag = c.dst.next_tag;
            c.dst.next_tag += 1;
            const name: JsIr.Name = .{
                .module = if (global) c.dst.self else .none,
                .base = c.s.in.fresh.unwrap().?,
                .tag = tag,
            };
            const at = try c.dst.addName(c.gpa(), name);
            c.renamed[n] = at.int();
            if (c.src.tables) |t| if (std.mem.indexOfScalar(NameIndex, t.mutable.items, @enumFromInt(n)) != null) {
                if (c.dst.tables) |dt| try dt.mutable.append(c.s.arena, at);
            };
        }

        /// A binding's name: the new one of a declared name, else itself.
        fn binding(c: *Copy, n: NameIndex) Allocator.Error!NameIndex {
            const i = n.unwrap() orelse return .none;
            if (i < c.renamed.len and c.renamed[i] != none) return @enumFromInt(c.renamed[i]);
            return c.property(n);
        }

        /// A property name: itself in its own module; in another, the
        /// destination's name of the same text (the session pools every
        /// plain name before the pass), added when it has none.
        fn property(c: *Copy, n: NameIndex) Allocator.Error!NameIndex {
            if (!c.cross or n == .none) return n;
            const name = c.src.ir.name(n);
            for (c.dst.names.items, 0..) |x, i| if (x.eql(name)) return @enumFromInt(@as(u32, @intCast(i)));
            return c.dst.addName(c.gpa(), name);
        }

        fn node(c: *Copy, from: Index, tag: Node.Tag, lhs: u32, rhs: u32) Allocator.Error!Index {
            const pos: u32 = if (c.cross) Node.no_pos else c.src.ir.pos(from);
            return c.dst.addNode(c.gpa(), tag, pos, lhs, rhs);
        }

        /// A copy of an argument: an atom of the destination.
        fn atom(c: *Copy, a: Index) Allocator.Error!Index {
            const d = c.dst.ir.data(a);
            return c.dst.addNode(c.gpa(), c.dst.ir.tag(a), c.dst.ir.pos(a), d.lhs, d.rhs);
        }

        fn bytesOf(c: *Copy, from: Index) Allocator.Error!u32 {
            const d = c.src.ir.data(from);
            if (!c.cross) return d.lhs;
            return c.dst.addBytes(c.gpa(), c.src.ir.bytes(from));
        }

        fn list(c: *Copy, range: JsIr.SubRange, depth: u32) Allocator.Error!JsIr.SubRange {
            var out: std.ArrayList(u32) = .empty;
            for (try c.s.arena.dupe(Index, c.src.ir.extraSlice(range, Index))) |n| try out.append(c.s.arena, (try c.stmt(n, depth + 1)).int());
            const start = try c.dst.append(c.gpa(), out.items);
            return .{ .start = @enumFromInt(start), .end = @enumFromInt(start + @as(u32, @intCast(out.items.len))) };
        }

        /// A `SubRange` record of `extra`: its two words, appended.
        fn record(c: *Copy, r: JsIr.SubRange) Allocator.Error!u32 {
            return c.dst.append(c.gpa(), &.{ @intFromEnum(r.start), @intFromEnum(r.end) });
        }

        fn exprs(c: *Copy, items: []const Index, depth: u32) Allocator.Error!JsIr.SubRange {
            var out: std.ArrayList(u32) = .empty;
            for (try c.s.arena.dupe(Index, items)) |n| try out.append(c.s.arena, (try c.expr(n, depth + 1)).int());
            const start = try c.dst.append(c.gpa(), out.items);
            return .{ .start = @enumFromInt(start), .end = @enumFromInt(start + @as(u32, @intCast(out.items.len))) };
        }

        fn func(c: *Copy, record_at: ExtraIndex, depth: u32) Allocator.Error!u32 {
            const f = c.src.ir.extraData(record_at, JsIr.Func);
            var params: std.ArrayList(u32) = .empty;
            for (try c.s.arena.dupe(NameIndex, c.src.ir.extraSlice(f.params(), NameIndex))) |p| try params.append(c.s.arena, (try c.binding(p)).int());
            const pstart = try c.dst.append(c.gpa(), params.items);
            const pend = pstart + @as(u32, @intCast(params.items.len));
            const body = try c.list(f.body(), depth);
            return c.dst.append(c.gpa(), &.{ pstart, pend, @intFromEnum(body.start), @intFromEnum(body.end) });
        }

        fn listed(c: *Copy, from: Index, to: Index, which: enum { keep, discards, unobserved }) Allocator.Error!void {
            const st = c.src.tables orelse return;
            const dt = c.dst.tables orelse return;
            const src_list, const dst_list = switch (which) {
                .keep => .{ st.keep.items, &dt.keep },
                .discards => .{ st.discards.items, &dt.discards },
                .unobserved => .{ st.unobserved.items, &dt.unobserved },
            };
            if (std.mem.indexOfScalar(Index, src_list, from) != null) try dst_list.append(c.s.arena, to);
        }

        fn expr(c: *Copy, from: Index, depth: u32) Allocator.Error!Index {
            const ir = c.src.ir;
            const d = ir.data(from);
            const tag = ir.tag(from);
            switch (tag) {
                .ident => {
                    if (d.lhs < c.subst.len) if (c.subst[d.lhs].unwrap()) |a| return c.atom(a);
                    return c.node(from, .ident, (try c.binding(@enumFromInt(d.lhs))).int(), 0);
                },
                .number, .string, .template_chunk => return c.node(from, tag, try c.bytesOf(from), d.rhs),
                .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this => return c.node(from, tag, 0, 0),
                .template, .object, .array => {
                    const r = try c.exprs(ir.extraSlice(JsIr.inlineRange(d), Index), depth);
                    return c.node(from, tag, @intFromEnum(r.start), @intFromEnum(r.end));
                },
                .property => return c.node(from, .property, (try c.property(@enumFromInt(d.lhs))).int(), (try c.expr(@enumFromInt(d.rhs), depth + 1)).int()),
                .spread_property => return c.node(from, .spread_property, (try c.expr(@enumFromInt(d.lhs), depth + 1)).int(), 0),
                .call, .new_call => {
                    const callee = try c.expr(@enumFromInt(d.lhs), depth + 1);
                    const args = try c.exprs(ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index), depth);
                    return c.node(from, tag, callee.int(), try c.record(args));
                },
                .member => return c.node(from, .member, (try c.expr(@enumFromInt(d.lhs), depth + 1)).int(), (try c.property(@enumFromInt(d.rhs))).int()),
                .index_get => {
                    const obj = try c.expr(@enumFromInt(d.lhs), depth + 1);
                    const key = try c.expr(@enumFromInt(d.rhs), depth + 1);
                    return c.node(from, .index_get, obj.int(), key.int());
                },
                .arrow => {
                    const to = try c.node(from, .arrow, try c.func(@enumFromInt(d.lhs), depth), d.rhs);
                    try c.listed(from, to, .unobserved);
                    return to;
                },
                .cond => {
                    const cd = ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
                    const t = try c.expr(@enumFromInt(d.lhs), depth + 1);
                    const a = try c.expr(cd.consequent, depth + 1);
                    const b = try c.expr(cd.alternate, depth + 1);
                    return c.node(from, .cond, t.int(), try c.dst.append(c.gpa(), &.{ a.int(), b.int() }));
                },
                .binary => {
                    const b = ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
                    const l = try c.expr(b.left, depth + 1);
                    const r = try c.expr(b.right, depth + 1);
                    return c.node(from, .binary, try c.dst.append(c.gpa(), &.{ l.int(), r.int() }), d.rhs);
                },
                .unary => return c.node(from, .unary, (try c.expr(@enumFromInt(d.lhs), depth + 1)).int(), d.rhs),
                else => return c.stmt(from, depth),
            }
        }

        fn optional(c: *Copy, v: u32, depth: u32) Allocator.Error!u32 {
            const o: Node.OptionalIndex = @enumFromInt(v);
            const n = o.unwrap() orelse return v;
            return (try c.expr(n, depth + 1)).int();
        }

        fn stmt(c: *Copy, from: Index, depth: u32) Allocator.Error!Index {
            const ir = c.src.ir;
            const d = ir.data(from);
            const tag = ir.tag(from);
            switch (tag) {
                .const_decl => {
                    const to = try c.node(from, .const_decl, (try c.binding(@enumFromInt(d.lhs))).int(), (try c.expr(@enumFromInt(d.rhs), depth + 1)).int());
                    try c.listed(from, to, .keep);
                    return to;
                },
                .let_decl => {
                    const to = try c.node(from, .let_decl, (try c.binding(@enumFromInt(d.lhs))).int(), try c.optional(d.rhs, depth));
                    try c.listed(from, to, .keep);
                    return to;
                },
                .func_decl, .gen_decl => {
                    const to = try c.node(from, tag, (try c.binding(@enumFromInt(d.lhs))).int(), try c.func(@enumFromInt(d.rhs), depth));
                    try c.listed(from, to, .unobserved);
                    return to;
                },
                .assign_stmt => {
                    const target = try c.expr(@enumFromInt(d.lhs), depth + 1);
                    return c.node(from, .assign_stmt, target.int(), (try c.expr(@enumFromInt(d.rhs), depth + 1)).int());
                },
                .return_stmt => return c.node(from, .return_stmt, try c.optional(d.lhs, depth), 0),
                .if_stmt => {
                    const b = ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                    const t = try c.expr(@enumFromInt(d.lhs), depth + 1);
                    const then = try c.list(b.thenBody(), depth);
                    const els = try c.list(b.elseBody(), depth);
                    const rec = try c.dst.append(c.gpa(), &.{ @intFromEnum(then.start), @intFromEnum(then.end), @intFromEnum(els.start), @intFromEnum(els.end) });
                    return c.node(from, .if_stmt, t.int(), rec);
                },
                .while_true, .block_stmt => {
                    const body = try c.list(ir.subRange(@enumFromInt(d.rhs)), depth);
                    return c.node(from, tag, (try c.binding(@enumFromInt(d.lhs))).int(), try c.record(body));
                },
                .for_of => {
                    const loop = ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                    const iterable = try c.expr(loop.iterable, depth + 1);
                    const body = try c.list(loop.body(), depth);
                    const rec = try c.dst.append(c.gpa(), &.{ iterable.int(), @intFromEnum(body.start), @intFromEnum(body.end) });
                    return c.node(from, .for_of, (try c.binding(@enumFromInt(d.lhs))).int(), rec);
                },
                .break_stmt, .continue_stmt => return c.node(from, tag, (try c.binding(@enumFromInt(d.lhs))).int(), 0),
                .switch_stmt => {
                    const disc = try c.expr(@enumFromInt(d.lhs), depth + 1);
                    const cases = try c.list(ir.subRange(@enumFromInt(d.rhs)), depth);
                    return c.node(from, .switch_stmt, disc.int(), try c.record(cases));
                },
                .switch_case => {
                    const t = try c.optional(d.lhs, depth);
                    const body = try c.list(ir.subRange(@enumFromInt(d.rhs)), depth);
                    return c.node(from, .switch_case, t, try c.record(body));
                },
                .expr_stmt => {
                    const to = try c.node(from, .expr_stmt, (try c.expr(@enumFromInt(d.lhs), depth + 1)).int(), 0);
                    try c.listed(from, to, .discards);
                    return to;
                },
                .throw_stmt => return c.node(from, .throw_stmt, (try c.expr(@enumFromInt(d.lhs), depth + 1)).int(), 0),
                .try_stmt => {
                    const t = ir.extraData(@enumFromInt(d.rhs), JsIr.Try);
                    const body = try c.list(t.body(), depth);
                    const final = try c.list(t.finalBody(), depth);
                    const rec = try c.dst.append(c.gpa(), &.{ @intFromEnum(body.start), @intFromEnum(body.end), @intFromEnum(final.start), @intFromEnum(final.end) });
                    return c.node(from, .try_stmt, 0, rec);
                },
                // `scanBody` refused a body holding one.
                .import_stmt, .export_stmt => unreachable,
                else => return c.expr(from, depth),
            }
        }
    };
};

/// How many functions slice 5 writes where they are called, at most.
const max_inlines = 256;
/// The largest body slice 5 copies, in nodes, and its deepest nesting: the
/// copy recurses.
const max_inline_nodes = 4096;
const max_inline_depth = 150;

/// Where the read of `p` stands in `node`'s evaluation (slice 8): `found`
/// when it is evaluated unconditionally and nothing evaluated before it
/// could do anything — run code, throw, or depend on when it runs (a name,
/// a literal and `===` cannot); `clean` when `node` evaluates no read of
/// `p` and does nothing; `dirty` when it reads no `p` but may do something;
/// `fail` when the read is conditional, deferred, or after such a thing.
const Use = enum { found, clean, dirty, fail };

fn firstUse(ir: *const JsIr, node: Index, p: NameIndex, depth: u32) Use {
    if (depth > 64) return .fail;
    const d = ir.data(node);
    switch (ir.tag(node)) {
        .ident => return if (d.lhs == p.int()) .found else .clean,
        .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit, .template_chunk, .global_this => return .clean,
        .member => return seq(&.{firstUse(ir, @enumFromInt(d.lhs), p, depth + 1)}, true),
        .index_get => return seq(&.{ firstUse(ir, @enumFromInt(d.lhs), p, depth + 1), firstUse(ir, @enumFromInt(d.rhs), p, depth + 1) }, true),
        .unary => {
            const op: JsIr.UnaryOp = @enumFromInt(d.rhs);
            return seq(&.{firstUse(ir, @enumFromInt(d.lhs), p, depth + 1)}, op != .not and op != .type_of);
        },
        .binary => {
            const b = ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
            const op: JsIr.BinaryOp = @enumFromInt(d.rhs);
            const l = firstUse(ir, b.left, p, depth + 1);
            const r = firstUse(ir, b.right, p, depth + 1);
            switch (op) {
                // The right side is evaluated only sometimes.
                .logical_and, .logical_or => {
                    if (r == .found or r == .fail) return if (l == .clean or l == .dirty) .fail else l;
                    return seq(&.{ l, r }, false);
                },
                .strict_eq, .strict_ne => return seq(&.{ l, r }, false),
                else => return seq(&.{ l, r }, true),
            }
        },
        .cond => {
            const c = ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
            const t = firstUse(ir, @enumFromInt(d.lhs), p, depth + 1);
            const a = firstUse(ir, c.consequent, p, depth + 1);
            const e = firstUse(ir, c.alternate, p, depth + 1);
            if (a == .found or a == .fail or e == .found or e == .fail) return if (t == .found) .found else .fail;
            return seq(&.{ t, a, e }, false);
        },
        .call, .new_call => {
            var parts: [17]Use = undefined;
            const args = ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index);
            if (args.len > 16) return .fail;
            parts[0] = firstUse(ir, @enumFromInt(d.lhs), p, depth + 1);
            for (args, 1..) |a, i| parts[i] = firstUse(ir, a, p, depth + 1);
            return seq(parts[0 .. args.len + 1], true);
        },
        .object, .array, .template => {
            var parts: [16]Use = undefined;
            const items = ir.extraSlice(JsIr.inlineRange(d), Index);
            if (items.len > 16) return .fail;
            for (items, 0..) |item, i| parts[i] = firstUse(ir, item, p, depth + 1);
            // A template converts what it holds to a string.
            return seq(parts[0..items.len], ir.tag(node) == .template);
        },
        .property => return firstUse(ir, @enumFromInt(d.rhs), p, depth + 1),
        .spread_property => return seq(&.{firstUse(ir, @enumFromInt(d.lhs), p, depth + 1)}, true),
        else => return .fail,
    }
}

/// Parts evaluated in order, then something that `acts` (may do anything)
/// when it is true.
fn seq(parts: []const Use, acts: bool) Use {
    var dirty = false;
    for (parts) |u| switch (u) {
        .found => return if (dirty) .fail else .found,
        .fail => return .fail,
        .dirty => dirty = true,
        .clean => {},
    };
    return if (dirty or acts) .dirty else .clean;
}

/// About how many bytes expression `root` prints in, short names one byte
/// each (slice 8's size model), capped.
fn nodeCount(ir: *const JsIr, root: Index, pts: *Pts, mi: u32) u32 {
    var stack: [64]Index = undefined;
    var len: usize = 1;
    stack[0] = root;
    var count: u32 = 0;
    while (len > 0) {
        len -= 1;
        const node = stack[len];
        const d = ir.data(node);
        count += switch (ir.tag(node)) {
            .ident, .true_lit, .null_lit => 1,
            .number, .string => @intCast(literalLen(ir, node)),
            .false_lit => 2,
            .undefined_lit => 9,
            // `.name`: a property name is its text.
            .member => blk: {
                const id = pts.propId(mi, @enumFromInt(d.rhs));
                break :blk 1 + if (id < pts.s.in.prop_len.len) @as(u32, pts.s.in.prop_len[id]) else 5;
            },
            .index_get, .call, .new_call, .object, .array, .template => blk: {
                const items: usize = switch (ir.tag(node)) {
                    .call, .new_call => ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index).len,
                    .index_get => 1,
                    else => ir.extraSlice(JsIr.inlineRange(d), Index).len,
                };
                break :blk 2 + @as(u32, @intCast(if (items > 0) items - 1 else 0));
            },
            .binary => @intCast(JsIr.BinaryOp.text(@enumFromInt(d.rhs)).len),
            .unary => 1,
            .cond => 2,
            .property => 6,
            else => 4,
        };
        if (count > 4096) return count;
        var children: [16]Index = undefined;
        var n: usize = 0;
        switch (ir.tag(node)) {
            .member, .unary, .spread_property => {
                children[0] = @enumFromInt(d.lhs);
                n = 1;
            },
            .property => {
                children[0] = @enumFromInt(d.rhs);
                n = 1;
            },
            .index_get => {
                children[0] = @enumFromInt(d.lhs);
                children[1] = @enumFromInt(d.rhs);
                n = 2;
            },
            .binary => {
                const b = ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
                children[0] = b.left;
                children[1] = b.right;
                n = 2;
            },
            .cond => {
                const c = ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
                children[0] = @enumFromInt(d.lhs);
                children[1] = c.consequent;
                children[2] = c.alternate;
                n = 3;
            },
            .call, .new_call => {
                const args = ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index);
                if (args.len > 15) return 4096;
                children[0] = @enumFromInt(d.lhs);
                for (args, 1..) |a, i| children[i] = a;
                n = args.len + 1;
            },
            .object, .array, .template => {
                const items = ir.extraSlice(JsIr.inlineRange(d), Index);
                if (items.len > 16) return 4096;
                for (items, 0..) |a, i| children[i] = a;
                n = items.len;
            },
            // A function counts as big.
            .arrow => return 4096,
            else => {},
        }
        if (len + n > stack.len) return 4096;
        for (children[0..n]) |c| {
            stack[len] = c;
            len += 1;
        }
    }
    return count;
}

fn growSlice(arena: Allocator, comptime T: type, old: []T, len: usize, fill: T) Allocator.Error![]T {
    const out = try arena.alloc(T, len);
    @memcpy(out[0..old.len], old);
    @memset(out[old.len..], fill);
    return out;
}

/// The printed length of a literal node, for slice 5's substitution rule.
fn literalLen(ir: *const JsIr, node: Index) usize {
    return switch (ir.tag(node)) {
        .number => ir.bytes(node).len,
        .string => ir.bytes(node).len + 2,
        .true_lit, .null_lit => 4,
        .false_lit => 5,
        .undefined_lit => 9,
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Slice 3: allocation sites
// ---------------------------------------------------------------------------

/// The DOM's methods that return a node or throw, never `null` or
/// `undefined` (slice 4, fact 5's one host fact): called on a value the
/// program did not allocate, their result is nonnull. A platform's
/// hand-written file is trusted to honour the DOM's contract for them.
pub const node_makers = [_][]const u8{
    "cloneNode",      "importNode",    "createElement",          "createElementNS",
    "createTextNode", "createComment", "createDocumentFragment",
};

/// The names `Object.prototype` has: an object literal that holds none of
/// these still has one to read (`Input.builtin_props`).
pub const prototype_names = [_][]const u8{
    "constructor",      "hasOwnProperty",   "isPrototypeOf",    "propertyIsEnumerable",
    "toLocaleString",   "toString",         "valueOf",          "__proto__",
    "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__",
};

/// `backend.md` §9, *Whole-program specialisation*, fact 3: a
/// flow-insensitive, allocation-site points-to analysis, field-sensitive by
/// property name. An abstract object per object literal, array literal and
/// function; `top` for anything the program did not allocate or cannot
/// follow; `prim` for a value that is no object. Values flow through
/// bindings, assignments, arguments to parameters, returns to call results,
/// and property writes and reads. A value handed to code the pass cannot see
/// — a host call, a hand-written file, a `throw`, a function that escapes —
/// escapes: every property of it is read and may be written, and what it
/// holds escapes with it.
///
/// **The iteration is optimistic where nothing can be unsound**: a call of
/// a value that holds nothing yet does nothing, and neither does a read or a
/// write through one — at the fixpoint such a value is never an object. What
/// the program does not declare (a hand-written import) is `top` from the
/// start.
const Pts = struct {
    s: *Spec,
    vars: std.ArrayList(VSet) = .empty,
    sites: std.ArrayList(Site) = .empty,
    site_at: std.AutoHashMapUnmanaged(NodeKey, u32) = .empty,
    locals: std.AutoHashMapUnmanaged(LocalKey, VarId) = .empty,
    globals: []VarId = &.{},
    /// Each module's per-node value of the sweep in progress.
    vals: [][]Val = &.{},
    /// Where one sweep's temporary values live.
    tmp: std.heap.ArenaAllocator,
    changed: bool = false,
    /// The fixpoint was reached this round: the facts may be read.
    ok: bool = false,
    stack: std.ArrayList(Frame) = .empty,
    children: std.ArrayList(Index) = .empty,
    /// The top-level statement the walk is in: locals are keyed by it.
    top: Index = undefined,
    /// Whether what the walk is in runs at most once: a module's top level,
    /// outside any function and any loop. A site made there is `once`.
    once_ctx: bool = false,
    /// The guards of the branches the walk is in (slice 4): each a chain
    /// the branch's test showed is not `null` (or `undefined`), live until
    /// something runs that may change what it reads. Those below
    /// `guard_base` belong to an enclosing function and are not in view.
    guards: std.ArrayList(Guard) = .empty,
    guard_base: usize = 0,
    /// Definite initialisation (*Amended 2026-10-03*): per object literal
    /// node, the keys it lacks that every call of the one function
    /// returning it writes before anything can read them. Kept across the
    /// runs of one `analyse`, which grow it.
    extra_init: std.AutoHashMapUnmanaged(NodeKey, std.ArrayList(u32)) = .empty,
    /// Per call node the initialiser of a `const` or `let`: the list it
    /// stands in and where (`writesAfter`).
    decl_call: std.AutoHashMapUnmanaged(NodeKey, DeclAt) = .empty,

    const DeclAt = struct { range: JsIr.SubRange, index: u32 };

    const Guard = struct {
        module: u32,
        chain: Index,
        nul: bool,
        undef: bool,
        live: bool = true,
    };

    const VarId = u32;
    const Frame = struct { node: Index, post: bool };
    const LocalKey = struct { module: u32, top: u32, name: u32 };
    const NodeKey = struct { module: u32, node: u32 };
    const elem_prop: u32 = std.math.maxInt(u32) - 1;
    /// A var holding more sites than this is `top`, its sites escaped: the
    /// sets stay small and the analysis linear in the program.
    const max_sites = 48;
    const max_pts_sweeps = 64;

    /// `prim` is a primitive that is neither `null` nor `undefined`; `nul`
    /// and `undef` are those two (slice 4). Reading a property of either
    /// throws, so it contributes nothing to what the read may be.
    const VSet = struct {
        top: bool = false,
        prim: bool = false,
        nul: bool = false,
        undef: bool = false,
        sites: std.ArrayList(u32) = .empty,
    };

    const Val = struct {
        top: bool = false,
        prim: bool = false,
        nul: bool = false,
        undef: bool = false,
        sites: []const u32 = &.{},

        const top_val: Val = .{ .top = true };
        const prim_val: Val = .{ .prim = true };
        const nul_val: Val = .{ .nul = true };
        const undef_val: Val = .{ .undef = true };

        fn nullish(v: Val) bool {
            return v.nul or v.undef;
        }
    };

    const SiteKind = enum(u8) { object, array, func };

    /// `init`: the object literal has the key, so the property exists from
    /// the moment the object does (slice 4); a read of one it lacks may be
    /// `undefined`.
    const Prop = struct { id: u32, vals: VarId, read: bool = false, written: bool = false, init: bool = false };

    const Site = struct {
        kind: SiteKind,
        module: u32,
        node: Index,
        /// Allocated at most once: made at a module's top level, outside
        /// any function and any loop (slice 4, fact 6).
        once: bool = false,
        escaped: bool = false,
        /// Every property read: a computed read, a spread, `for…of`.
        all_read: bool = false,
        /// Values written under a key the pass does not know.
        any: VarId,
        any_written: bool = false,
        props: std.ArrayList(Prop) = .empty,
        /// A function's return and parameters.
        ret: VarId = none,
        params: []const VarId = &.{},
        /// An object literal that is the value of a `return` of this
        /// function site: its only way out (definite initialisation).
        fresh_fn: u32 = none,
        /// A function's: every call node that may call it, and whether
        /// something else does (the entry file, `new`).
        callers: std.ArrayList(NodeKey) = .empty,
        odd_caller: bool = false,
    };

    fn init(s: *Spec) Pts {
        return .{ .s = s, .tmp = .init(s.gpa) };
    }

    fn deinit(p: *Pts) void {
        p.tmp.deinit();
    }

    fn arena(p: *Pts) Allocator {
        return p.s.arena;
    }

    // ---- Sets ----------------------------------------------------------------

    fn newVar(p: *Pts) Allocator.Error!VarId {
        const id: VarId = @intCast(p.vars.items.len);
        try p.vars.append(p.arena(), .{});
        return id;
    }

    fn view(p: *Pts, v: VarId) Val {
        const set = &p.vars.items[v];
        return .{ .top = set.top, .prim = set.prim, .nul = set.nul, .undef = set.undef, .sites = set.sites.items };
    }

    fn addSite(p: *Pts, v: VarId, site: u32) Allocator.Error!void {
        const set = &p.vars.items[v];
        if (set.top) {
            // A var that is `top` holds no list: what joins it escapes.
            try p.escapeSite(site);
            return;
        }
        const at = std.sort.lowerBound(u32, set.sites.items, site, orderU32);
        if (at < set.sites.items.len and set.sites.items[at] == site) return;
        try set.sites.insert(p.arena(), at, site);
        p.changed = true;
        if (set.sites.items.len > max_sites) try p.makeTop(v);
    }

    fn makeTop(p: *Pts, v: VarId) Allocator.Error!void {
        const set = &p.vars.items[v];
        if (set.top) return;
        set.top = true;
        p.changed = true;
        for (set.sites.items) |site| try p.escapeSite(site);
        set.sites.clearRetainingCapacity();
    }

    fn join(p: *Pts, v: VarId, val: Val) Allocator.Error!void {
        if (val.top) try p.makeTop(v);
        if (val.prim and !p.vars.items[v].prim) {
            p.vars.items[v].prim = true;
            p.changed = true;
        }
        if (val.nul and !p.vars.items[v].nul) {
            p.vars.items[v].nul = true;
            p.changed = true;
        }
        if (val.undef and !p.vars.items[v].undef) {
            p.vars.items[v].undef = true;
            p.changed = true;
        }
        for (val.sites) |site| try p.addSite(v, site);
    }

    fn escapeSite(p: *Pts, site: u32) Allocator.Error!void {
        const st = &p.sites.items[site];
        if (st.escaped) return;
        st.escaped = true;
        p.changed = true;
    }

    fn escape(p: *Pts, val: Val) Allocator.Error!void {
        for (val.sites) |site| try p.escapeSite(site);
    }

    fn unionOf(p: *Pts, a: Val, b: Val) Allocator.Error!Val {
        const flags: Val = .{ .top = a.top or b.top, .prim = a.prim or b.prim, .nul = a.nul or b.nul, .undef = a.undef or b.undef };
        if (a.sites.len == 0) return .{ .top = flags.top, .prim = flags.prim, .nul = flags.nul, .undef = flags.undef, .sites = b.sites };
        if (b.sites.len == 0) return .{ .top = flags.top, .prim = flags.prim, .nul = flags.nul, .undef = flags.undef, .sites = a.sites };
        var out: std.ArrayList(u32) = .empty;
        try out.ensureTotalCapacity(p.tmp.allocator(), a.sites.len + b.sites.len);
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.sites.len or j < b.sites.len) {
            if (j == b.sites.len or (i < a.sites.len and a.sites[i] < b.sites[j])) {
                out.appendAssumeCapacity(a.sites[i]);
                i += 1;
            } else if (i == a.sites.len or b.sites[j] < a.sites[i]) {
                out.appendAssumeCapacity(b.sites[j]);
                j += 1;
            } else {
                out.appendAssumeCapacity(a.sites[i]);
                i += 1;
                j += 1;
            }
        }
        return .{ .top = flags.top, .prim = flags.prim, .nul = flags.nul, .undef = flags.undef, .sites = out.items };
    }

    fn orderU32(a: u32, b: u32) std.math.Order {
        return std.math.order(a, b);
    }

    // ---- Names and sites -----------------------------------------------------

    fn localVar(p: *Pts, mi: u32, n: NameIndex) Allocator.Error!VarId {
        const gop = try p.locals.getOrPut(p.arena(), .{ .module = mi, .top = p.top.int(), .name = n.int() });
        if (!gop.found_existing) gop.value_ptr.* = try p.newVar();
        return gop.value_ptr.*;
    }

    fn nameVar(p: *Pts, mi: u32, n: NameIndex) Allocator.Error!VarId {
        if (p.s.mods[mi].globalOf(n)) |g| return p.globals[g];
        return p.localVar(mi, n);
    }

    fn propId(p: *Pts, mi: u32, n: NameIndex) u32 {
        const m = &p.s.mods[mi];
        const i = n.unwrap() orelse return none;
        if (i < m.prop.len) return m.prop[i];
        // A name a body copied here added: plain names are the session's
        // symbols, so the same name in the module it was copied from is
        // numbered. Found once, then kept in the module's column.
        const at = i - @as(u32, @intCast(m.prop.len));
        const unknown = none - 1;
        while (m.prop_more.items.len <= at) m.prop_more.append(p.arena(), unknown) catch return none;
        if (m.prop_more.items[at] != unknown) return m.prop_more.items[at];
        const name = m.names.items[i];
        var found: u32 = none;
        if (name.module == .none and (name.tag == JsIr.Name.no_tag or name.tag == JsIr.Name.field)) search: for (p.s.mods) |*other| {
            for (other.prop, 0..) |id, j| if (id != none and other.names.items[j].eql(name)) {
                found = id;
                break :search;
            };
        };
        m.prop_more.items[at] = found;
        return found;
    }

    fn siteOf(p: *Pts, mi: u32, node: Index, kind: SiteKind) Allocator.Error!u32 {
        const gop = try p.site_at.getOrPut(p.arena(), .{ .module = mi, .node = node.int() });
        if (gop.found_existing) return gop.value_ptr.*;
        const id: u32 = @intCast(p.sites.items.len);
        gop.value_ptr.* = id;
        try p.sites.append(p.arena(), .{ .kind = kind, .module = mi, .node = node, .once = p.once_ctx, .any = try p.newVar() });
        // Keys written before anything can read them exist from the moment
        // the object does, as a literal's own do.
        if (kind == .object) if (p.extra_init.get(.{ .module = mi, .node = node.int() })) |ids| {
            for (ids.items) |pid| (try p.prop(id, pid)).init = true;
        };
        return id;
    }

    /// A function's site, its parameters' vars and its return's.
    fn funcSite(p: *Pts, mi: u32, node: Index, record: ExtraIndex) Allocator.Error!u32 {
        const seen = p.site_at.contains(.{ .module = mi, .node = node.int() });
        const site = try p.siteOf(mi, node, .func);
        if (seen) return site;
        const ir = p.s.mods[mi].ir;
        const f = ir.extraData(record, JsIr.Func);
        const names = ir.extraSlice(f.params(), NameIndex);
        const params = try p.arena().alloc(VarId, names.len);
        for (params, names) |*v, n| v.* = try p.localVar(mi, n);
        p.sites.items[site].params = params;
        p.sites.items[site].ret = try p.newVar();
        return site;
    }

    fn prop(p: *Pts, site: u32, id: u32) Allocator.Error!*Prop {
        const st = &p.sites.items[site];
        for (st.props.items) |*pr| if (pr.id == id) return pr;
        const v = try p.newVar();
        const st2 = &p.sites.items[site];
        try st2.props.append(p.arena(), .{ .id = id, .vals = v });
        return &st2.props.items[st2.props.items.len - 1];
    }

    fn findProp(p: *const Pts, site: u32, id: u32) ?*const Prop {
        for (p.sites.items[site].props.items) |*pr| if (pr.id == id) return pr;
        return null;
    }

    // ---- Reads and writes ----------------------------------------------------

    /// What reading property `id` of `obj` may give. A `null` or
    /// `undefined` object throws, and gives nothing; a property the
    /// object's literal lacks may be `undefined` (slice 4).
    fn read(p: *Pts, obj: Val, id: u32, mark: bool) Allocator.Error!Val {
        var out: Val = .{ .top = obj.top or obj.prim };
        for (obj.sites) |site| {
            const st = &p.sites.items[site];
            if (st.kind != .object or st.escaped or id == none) {
                out.top = true;
                continue;
            }
            if (mark) {
                const pr = try p.prop(site, id);
                if (!pr.read) {
                    pr.read = true;
                    p.changed = true;
                }
                if (!pr.init) out.undef = true;
                out = try p.unionOf(out, p.view(pr.vals));
            } else if (p.findProp(site, id)) |pr| {
                if (!pr.init) out.undef = true;
                out = try p.unionOf(out, p.view(pr.vals));
            } else out.undef = true;
            out = try p.unionOf(out, p.view(p.sites.items[site].any));
        }
        return out;
    }

    /// Every property of every object `obj` may be, read.
    fn readAll(p: *Pts, obj: Val) Allocator.Error!Val {
        var out: Val = .{ .top = obj.top or obj.prim };
        for (obj.sites) |site| {
            const st = &p.sites.items[site];
            if (st.kind == .func or st.escaped) {
                out.top = true;
                continue;
            }
            if (!st.all_read) {
                st.all_read = true;
                p.changed = true;
            }
            for (p.sites.items[site].props.items) |pr| out = try p.unionOf(out, p.view(pr.vals));
            out = try p.unionOf(out, p.view(p.sites.items[site].any));
        }
        return out;
    }

    fn write(p: *Pts, obj: Val, id: u32, value: Val) Allocator.Error!void {
        if (obj.top or obj.prim) try p.escape(value);
        for (obj.sites) |site| {
            const st = &p.sites.items[site];
            if (st.kind != .object or st.escaped or id == none) {
                try p.escape(value);
                if (id == none) try p.writeAnyOne(site, value);
                continue;
            }
            const pr = try p.prop(site, id);
            if (!pr.written) {
                pr.written = true;
                p.changed = true;
            }
            try p.join(pr.vals, value);
        }
    }

    fn writeAnyOne(p: *Pts, site: u32, value: Val) Allocator.Error!void {
        const st = &p.sites.items[site];
        if (!st.any_written) {
            st.any_written = true;
            p.changed = true;
        }
        try p.join(st.any, value);
        if (p.sites.items[site].escaped) try p.escape(value);
    }

    fn writeAny(p: *Pts, obj: Val, value: Val) Allocator.Error!void {
        if (obj.top or obj.prim) try p.escape(value);
        for (obj.sites) |site| try p.writeAnyOne(site, value);
    }

    // ---- The analysis --------------------------------------------------------

    /// How many times one `analyse` runs the fixpoint again for keys
    /// definite initialisation found.
    const max_init_runs = 3;

    /// Fact 3 to its fixpoint over the program as it stands this round,
    /// then again while definite initialisation finds keys every object of
    /// a site has before it can be read: what a site may hold does not
    /// depend on them (only whether a read may be `undefined` does), so
    /// the next run's call graph is this one's.
    fn analyse(p: *Pts) Allocator.Error!void {
        p.extra_init = .empty;
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            try p.fixpoint();
            if (!p.ok or attempt == max_init_runs) return;
            if (!try p.definiteInit()) return;
        }
    }

    fn fixpoint(p: *Pts) Allocator.Error!void {
        const s = p.s;
        p.ok = false;
        p.vars = .empty;
        p.sites = .empty;
        p.site_at = .empty;
        p.locals = .empty;
        p.decl_call = .empty;
        p.globals = try p.arena().alloc(VarId, s.in.globals);
        for (p.globals) |*g| g.* = try p.newVar();
        // What no module declares — an import of a hand-written file's
        // export — is anything at all.
        for (s.decl, p.globals) |d, g| if (d == null) try p.makeTop(g);
        p.vals = try p.arena().alloc([]Val, s.mods.len);
        // A node no sweep reached (in code nothing runs) is anything.
        for (p.vals, s.mods) |*v, *m| {
            v.* = try p.arena().alloc(Val, m.ir.nodes.len);
            @memset(v.*, Val.top_val);
        }
        var sweep: u32 = 0;
        while (sweep < max_pts_sweeps) : (sweep += 1) {
            p.changed = false;
            _ = p.tmp.reset(.retain_capacity);
            for (s.mods, 0..) |*m, mi| {
                for (m.ir.extraSlice(m.ir.body, Index)) |top| {
                    p.top = top;
                    p.once_ctx = true;
                    try p.stmt(@intCast(mi), top, null);
                }
            }
            // What files the pass cannot see read.
            for (s.in.escaping) |g| if (g < p.globals.len) try p.escape(p.view(p.globals[g]));
            if (s.in.entry) |e| try p.entryCall(e);
            try p.propagate();
            if (!p.changed) {
                p.ok = true;
                return;
            }
        }
    }

    /// What an escaped site holds escapes, and an escaped function is
    /// called with anything and returns to anyone.
    fn propagate(p: *Pts) Allocator.Error!void {
        var i: usize = 0;
        while (i < p.sites.items.len) : (i += 1) {
            if (!p.sites.items[i].escaped) continue;
            const st = &p.sites.items[i];
            if (!st.all_read or !st.any_written) {
                st.all_read = true;
                st.any_written = true;
                p.changed = true;
            }
            for (p.sites.items[i].props.items) |pr| try p.escape(p.view(pr.vals));
            try p.escape(p.view(p.sites.items[i].any));
            if (p.sites.items[i].kind == .func) {
                for (p.sites.items[i].params) |v| try p.makeTop(v);
                try p.escape(p.view(p.sites.items[i].ret));
            }
        }
    }

    fn stmt(p: *Pts, mi: u32, node: Index, func: ?u32) Allocator.Error!void {
        const ir = p.s.mods[mi].ir;
        const d = ir.data(node);
        switch (ir.tag(node)) {
            .import_stmt, .export_stmt, .break_stmt, .continue_stmt => {},
            .const_decl, .let_decl => {
                const v: Node.OptionalIndex = @enumFromInt(d.rhs);
                const val = if (v.unwrap()) |value| try p.expr(mi, value, func) else Val.undef_val;
                try p.join(try p.nameVar(mi, @enumFromInt(d.lhs)), val);
                // A name declared in a guarded branch may shadow the chain.
                p.kill();
            },
            .func_decl, .gen_decl => {
                const site = try p.funcSite(mi, node, @enumFromInt(d.rhs));
                if (ir.tag(node) == .gen_decl) try p.escapeSite(site);
                try p.join(try p.nameVar(mi, @enumFromInt(d.lhs)), .{ .sites = &.{site} });
                try p.body(mi, @enumFromInt(d.rhs), site);
                p.kill();
            },
            .assign_stmt => {
                defer p.kill();
                const value = try p.expr(mi, @enumFromInt(d.rhs), func);
                const target: Index = @enumFromInt(d.lhs);
                const td = ir.data(target);
                switch (ir.tag(target)) {
                    .ident => try p.join(try p.nameVar(mi, @enumFromInt(td.lhs)), value),
                    .member => try p.write(try p.expr(mi, @enumFromInt(td.lhs), func), p.propId(mi, @enumFromInt(td.rhs)), value),
                    .index_get => {
                        _ = try p.expr(mi, @enumFromInt(td.rhs), func);
                        try p.writeAny(try p.expr(mi, @enumFromInt(td.lhs), func), value);
                    },
                    else => {
                        _ = try p.expr(mi, target, func);
                        try p.escape(value);
                    },
                }
            },
            .return_stmt => {
                const value: ?Index = @as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap();
                const val = if (value) |v| try p.expr(mi, v, func) else Val.undef_val;
                if (func) |site| try p.join(p.sites.items[site].ret, val) else try p.escape(val);
                // An object literal returned as it is made leaves its
                // function by the call alone (definite initialisation).
                if (func) |site| if (value) |v| if (ir.tag(v) == .object) {
                    if (p.site_at.get(.{ .module = mi, .node = v.int() })) |o| p.sites.items[o].fresh_fn = site;
                };
            },
            .if_stmt => {
                _ = try p.expr(mi, @enumFromInt(d.lhs), func);
                const branches = ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                const test_guard = nullTest(ir, @enumFromInt(d.lhs));
                try p.branch(mi, branches.thenBody(), func, if (test_guard) |t| (if (t.null_in_then) null else t.guard(mi)) else null);
                try p.branch(mi, branches.elseBody(), func, if (test_guard) |t| (if (t.null_in_then) t.guard(mi) else null) else null);
            },
            .block_stmt => try p.list(mi, ir.subRange(@enumFromInt(d.rhs)), func),
            .while_true => {
                // A later turn runs after whatever this one did.
                p.kill();
                const saved = p.once_ctx;
                defer p.once_ctx = saved;
                p.once_ctx = false;
                try p.list(mi, ir.subRange(@enumFromInt(d.rhs)), func);
            },
            .for_of => {
                const f = ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                const items = try p.readAll(try p.expr(mi, f.iterable, func));
                // Iterating calls the iterator.
                p.kill();
                try p.join(try p.nameVar(mi, @enumFromInt(d.lhs)), items);
                const saved = p.once_ctx;
                defer p.once_ctx = saved;
                p.once_ctx = false;
                try p.list(mi, f.body(), func);
            },
            .switch_stmt => {
                _ = try p.expr(mi, @enumFromInt(d.lhs), func);
                for (ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index)) |c| try p.stmt(mi, c, func);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| _ = try p.expr(mi, t, func);
                try p.list(mi, ir.subRange(@enumFromInt(d.rhs)), func);
            },
            .expr_stmt => _ = try p.expr(mi, @enumFromInt(d.lhs), func),
            .throw_stmt => try p.escape(try p.expr(mi, @enumFromInt(d.lhs), func)),
            // The body, then the cleanup, which may begin after any
            // statement of the body: a guard dies at the first statement
            // that kills it and never comes back, so walking the body
            // whole first leaves in view only the guards no statement of it
            // could have broken. Anything the body throws is a value that
            // escapes, as at a `throw`, and no guard the cleanup is under
            // is one a `throw` could skip.
            .try_stmt => {
                const t = ir.extraData(@enumFromInt(d.rhs), JsIr.Try);
                try p.list(mi, t.body(), func);
                p.kill();
                try p.list(mi, t.finalBody(), func);
                p.kill();
            },
            else => _ = try p.expr(mi, node, func),
        }
    }

    fn list(p: *Pts, mi: u32, range: JsIr.SubRange, func: ?u32) Allocator.Error!void {
        const ir = p.s.mods[mi].ir;
        for (ir.extraSlice(range, Index), 0..) |node, k| {
            // A call a `const` or `let` binds: where it stands, for the
            // writes that follow it (`writesAfter`).
            switch (ir.tag(node)) {
                .const_decl, .let_decl => {
                    const v: Node.OptionalIndex = @enumFromInt(ir.data(node).rhs);
                    if (v.unwrap()) |value| if (ir.tag(value) == .call) {
                        try p.decl_call.put(p.arena(), .{ .module = mi, .node = value.int() }, .{ .range = range, .index = @intCast(k) });
                    };
                },
                else => {},
            }
            try p.stmt(mi, node, func);
        }
    }

    /// Definite initialisation: of an object literal that is the value of
    /// a `return`, so that the call is the only way it leaves its function,
    /// each key that every call of that function — bound by a `const` or
    /// `let` — writes in the statements right after it, before anything
    /// runs that could read the new object, exists from the moment any code
    /// can see the object. True when a key was found that the last run did
    /// not have.
    fn definiteInit(p: *Pts) Allocator.Error!bool {
        var grew = false;
        var found: std.ArrayList(u32) = .empty;
        var here: std.ArrayList(u32) = .empty;
        for (0..p.sites.items.len) |si| {
            const st = p.sites.items[si];
            if (st.kind != .object or st.escaped or st.fresh_fn == none) continue;
            const f = &p.sites.items[st.fresh_fn];
            if (f.escaped or f.odd_caller or f.callers.items.len == 0) continue;
            found.clearRetainingCapacity();
            for (f.callers.items, 0..) |c, ci| {
                here.clearRetainingCapacity();
                try p.writesAfter(c, &here);
                if (ci == 0) {
                    try found.appendSlice(p.arena(), here.items);
                    continue;
                }
                var kept: usize = 0;
                for (found.items) |id| if (std.mem.indexOfScalar(u32, here.items, id) != null) {
                    found.items[kept] = id;
                    kept += 1;
                };
                found.shrinkRetainingCapacity(kept);
                if (found.items.len == 0) break;
            }
            for (found.items) |id| {
                if (p.findProp(@intCast(si), id)) |pr| if (pr.init) continue;
                const gop = try p.extra_init.getOrPut(p.arena(), .{ .module = st.module, .node = st.node.int() });
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                if (std.mem.indexOfScalar(u32, gop.value_ptr.items, id) != null) continue;
                try gop.value_ptr.append(p.arena(), id);
                grew = true;
            }
        }
        return grew;
    }

    /// The keys written to `x` right after `const x = call` (or `let`): the
    /// run of `x.k = v` statements that follow it, each `v` evaluated
    /// without running code or reading `x` (`harmless`).
    fn writesAfter(p: *Pts, c: NodeKey, out: *std.ArrayList(u32)) Allocator.Error!void {
        const at = p.decl_call.get(c) orelse return;
        const mi = c.module;
        const ir = p.s.mods[mi].ir;
        const items = ir.extraSlice(at.range, Index);
        if (at.index >= items.len) return;
        const decl = items[at.index];
        // Still this call's binding: the list may have been folded since.
        if (ir.data(decl).rhs != c.node) return;
        const x: NameIndex = @enumFromInt(ir.data(decl).lhs);
        for (items[at.index + 1 ..]) |next| {
            if (ir.tag(next) != .assign_stmt) return;
            const target: Index = @enumFromInt(ir.data(next).lhs);
            if (ir.tag(target) != .member) return;
            const obj: Index = @enumFromInt(ir.data(target).lhs);
            if (ir.tag(obj) != .ident or ir.data(obj).lhs != x.int()) return;
            const id = p.propId(mi, @enumFromInt(ir.data(target).rhs));
            if (id == none) return;
            if (!p.harmless(mi, @enumFromInt(ir.data(next).rhs), x)) return;
            if (std.mem.indexOfScalar(u32, out.items, id) == null) try out.append(p.arena(), id);
        }
    }

    /// Whether evaluating `root` can neither run code nor throw nor read
    /// `x`: a literal, a name other than `x`, or a property of such an
    /// expression whose objects are all the program's own, none escaped
    /// (no getter), none `null` or `undefined`.
    fn harmless(p: *Pts, mi: u32, root: Index, x: NameIndex) bool {
        const ir = p.s.mods[mi].ir;
        var node = root;
        var depth: u32 = 0;
        while (depth < 64) : (depth += 1) {
            switch (ir.tag(node)) {
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => return true,
                .ident => return ir.data(node).lhs != x.int(),
                .member => {
                    const obj: Index = @enumFromInt(ir.data(node).lhs);
                    const v = p.vals[mi][obj.int()];
                    if (v.top or v.prim or v.nullish() or v.sites.len == 0) return false;
                    for (v.sites) |site| if (p.sites.items[site].escaped) return false;
                    node = obj;
                },
                else => return false,
            }
        }
        return false;
    }

    /// A branch's statements, under `guard` when its test narrows a chain.
    fn branch(p: *Pts, mi: u32, range: JsIr.SubRange, func: ?u32, guard: ?Guard) Allocator.Error!void {
        const base = p.guards.items.len;
        defer p.guards.shrinkRetainingCapacity(base);
        if (guard) |g| try p.guards.append(p.arena(), g);
        try p.list(mi, range, func);
    }

    /// Every guard in view dies: something ran that may change what a
    /// chain reads.
    fn kill(p: *Pts) void {
        for (p.guards.items[p.guard_base..]) |*g| g.live = false;
    }

    /// `v`, what chain `node` read, less what a live guard in view says
    /// it cannot be. A member read through a host value may run a getter,
    /// which a guard cannot vouch for.
    fn narrowed(p: *Pts, mi: u32, node: Index, v: Val) Val {
        var out = v;
        const ir = p.s.mods[mi].ir;
        if (ir.tag(node) == .member and p.vals[mi][ir.data(node).lhs].top) return out;
        for (p.guards.items[p.guard_base..]) |g| {
            if (!g.live or g.module != mi or !sameChain(ir, g.chain, node)) continue;
            if (g.nul) out.nul = false;
            if (g.undef) out.undef = false;
        }
        return out;
    }

    /// A function's body: walked as what may run many times, and when it
    /// may run off its end, `undefined` is among what it returns. No guard
    /// outside it is in view: it runs later.
    fn body(p: *Pts, mi: u32, record: ExtraIndex, site: u32) Allocator.Error!void {
        const ir = p.s.mods[mi].ir;
        const saved = p.once_ctx;
        defer p.once_ctx = saved;
        p.once_ctx = false;
        const saved_base = p.guard_base;
        defer p.guard_base = saved_base;
        p.guard_base = p.guards.items.len;
        const f = ir.extraData(record, JsIr.Func);
        try p.list(mi, f.body(), site);
        if (fallsThrough(ir, f.body())) try p.join(p.sites.items[site].ret, Val.undef_val);
    }

    /// What `root` may be, bottom-up over an explicit stack, every node's
    /// into `vals`. An arrow is its site, its body walked as the statements
    /// it is.
    fn expr(p: *Pts, mi: u32, root: Index, func: ?u32) Allocator.Error!Val {
        // Where a `return` goes is the statements' business; an expression
        // holds none, and an arrow in it is a function of its own.
        _ = func;
        const ir = p.s.mods[mi].ir;
        const vals = p.vals[mi];
        const base = p.stack.items.len;
        defer p.stack.shrinkRetainingCapacity(base);
        try p.stack.append(p.arena(), .{ .node = root, .post = false });
        while (p.stack.items.len > base) {
            const f = p.stack.pop().?;
            if (!f.post) {
                if (ir.tag(f.node) == .arrow) {
                    const record: ExtraIndex = @enumFromInt(ir.data(f.node).lhs);
                    const site = try p.funcSite(mi, f.node, record);
                    try p.body(mi, record, site);
                    vals[f.node.int()] = .{ .sites = try p.tmp.allocator().dupe(u32, &.{site}) };
                    continue;
                }
                switch (ir.tag(f.node)) {
                    // A leaf has no operands to wait for.
                    .ident, .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .template_chunk => {
                        vals[f.node.int()] = try p.combine(mi, f.node);
                        continue;
                    },
                    else => {},
                }
                try p.stack.append(p.arena(), .{ .node = f.node, .post = true });
                p.children.clearRetainingCapacity();
                try ir.pushOperands(p.arena(), &p.children, f.node);
                for (p.children.items) |c| try p.stack.append(p.arena(), .{ .node = c, .post = false });
                continue;
            }
            vals[f.node.int()] = try p.combine(mi, f.node);
        }
        return vals[root.int()];
    }

    fn combine(p: *Pts, mi: u32, node: Index) Allocator.Error!Val {
        const ir = p.s.mods[mi].ir;
        const vals = p.vals[mi];
        const d = ir.data(node);
        return switch (ir.tag(node)) {
            .number, .string, .template, .template_chunk, .true_lit, .false_lit => Val.prim_val,
            .null_lit => Val.nul_val,
            .undefined_lit => Val.undef_val,
            .global_this => Val.top_val,
            .ident => p.narrowed(mi, node, p.view(try p.nameVar(mi, @enumFromInt(d.lhs)))),
            .member => blk: {
                const v = p.narrowed(mi, node, try p.read(vals[d.lhs], p.propId(mi, @enumFromInt(d.rhs)), true));
                // A read through a host value may run a getter.
                if (vals[d.lhs].top) p.kill();
                break :blk v;
            },
            // An index past the end is `undefined`.
            .index_get => blk: {
                var v = try p.readAll(vals[d.lhs]);
                if (vals[d.lhs].sites.len != 0) v.undef = true;
                if (vals[d.lhs].top) p.kill();
                break :blk v;
            },
            .property => vals[d.rhs],
            .spread_property => vals[d.lhs],
            .object => blk: {
                const site = try p.siteOf(mi, node, .object);
                for (ir.extraSlice(JsIr.inlineRange(d), Index)) |child| {
                    const cd = ir.data(child);
                    switch (ir.tag(child)) {
                        .property => {
                            const pr = try p.prop(site, p.propId(mi, @enumFromInt(cd.lhs)));
                            if (!pr.written) {
                                pr.written = true;
                                p.changed = true;
                            }
                            // The literal has the key: the property exists
                            // from the moment the object does. Set before
                            // the site reaches any var, so no read of it
                            // ever saw it missing.
                            pr.init = true;
                            try p.join(pr.vals, vals[cd.rhs]);
                        },
                        // `{...x}` copies what `x` holds, reading all of it.
                        else => {
                            const from = vals[cd.lhs];
                            _ = try p.readAll(from);
                            if (from.top or from.prim) try p.writeAnyOne(site, Val.top_val);
                            for (from.sites) |other| {
                                if (p.sites.items[other].kind != .object) {
                                    try p.writeAnyOne(site, Val.top_val);
                                    continue;
                                }
                                var k: usize = 0;
                                while (k < p.sites.items[other].props.items.len) : (k += 1) {
                                    const src = p.sites.items[other].props.items[k];
                                    const pr = try p.prop(site, src.id);
                                    if (!pr.written) {
                                        pr.written = true;
                                        p.changed = true;
                                    }
                                    try p.join(pr.vals, p.view(src.vals));
                                }
                                if (p.sites.items[other].any_written) try p.writeAnyOne(site, p.view(p.sites.items[other].any));
                            }
                        },
                    }
                }
                break :blk .{ .sites = try p.tmp.allocator().dupe(u32, &.{site}) };
            },
            .array => blk: {
                const site = try p.siteOf(mi, node, .array);
                const pr = try p.prop(site, elem_prop);
                const pv = pr.vals;
                for (ir.extraSlice(JsIr.inlineRange(d), Index)) |child| try p.join(pv, vals[child.int()]);
                break :blk .{ .sites = try p.tmp.allocator().dupe(u32, &.{site}) };
            },
            .arrow => vals[node.int()],
            .cond => blk: {
                const c = ir.extraData(@enumFromInt(d.rhs), JsIr.Cond);
                break :blk p.unionOf(vals[c.consequent.int()], vals[c.alternate.int()]);
            },
            .binary => blk: {
                const b = ir.extraData(@enumFromInt(d.lhs), JsIr.Binary);
                break :blk switch (@as(JsIr.BinaryOp, @enumFromInt(d.rhs))) {
                    .logical_and, .logical_or => p.unionOf(vals[b.left.int()], vals[b.right.int()]),
                    else => Val.prim_val,
                };
            },
            .unary => if (@as(JsIr.UnaryOp, @enumFromInt(d.rhs)) == .yield) blk: {
                p.kill();
                break :blk Val.top_val;
            } else Val.prim_val,
            .call => blk: {
                defer p.kill();
                break :blk p.call(mi, node);
            },
            .new_call => blk: {
                p.kill();
                for (vals[d.lhs].sites) |site| p.sites.items[site].odd_caller = true;
                for (ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index)) |a| try p.escape(vals[a.int()]);
                break :blk Val.top_val;
            },
            else => Val.top_val,
        };
    }

    /// A call: its arguments join the parameters of every function its
    /// callee may be, and its value is what they return. A callee that may
    /// be anything else is code the pass cannot see: the arguments escape,
    /// and so does the object whose method it is.
    /// The entry file's call (`Input.entry`), as `call` reads one whose
    /// callee and arguments are names: each argument's objects join the
    /// parameter it is passed to, and escape when the callee may be
    /// something the program did not make.
    fn entryCall(p: *Pts, e: Entry) Allocator.Error!void {
        if (e.callee >= p.globals.len) return;
        for (e.args) |a| if (a >= p.globals.len) return;
        const vc = p.view(p.globals[e.callee]);
        var unknown = vc.top or vc.prim;
        for (vc.sites) |site| {
            if (p.sites.items[site].kind != .func) {
                unknown = true;
                continue;
            }
            p.sites.items[site].odd_caller = true;
            const params = p.sites.items[site].params;
            for (params, 0..) |v, i| try p.join(v, if (i < e.args.len) p.view(p.globals[e.args[i]]) else Val.undef_val);
        }
        if (unknown) for (e.args) |a| try p.escape(p.view(p.globals[a]));
    }

    fn call(p: *Pts, mi: u32, node: Index) Allocator.Error!Val {
        const ir = p.s.mods[mi].ir;
        const vals = p.vals[mi];
        const d = ir.data(node);
        const callee: Index = @enumFromInt(d.lhs);
        const vc = vals[callee.int()];
        const args = ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index);
        var out: Val = .{};
        var unknown = vc.top or vc.prim;
        for (vc.sites) |site| {
            if (p.sites.items[site].kind != .func) {
                unknown = true;
                continue;
            }
            const params = p.sites.items[site].params;
            for (params, 0..) |v, i| try p.join(v, if (i < args.len) vals[args[i].int()] else Val.undef_val);
            out = try p.unionOf(out, p.view(p.sites.items[site].ret));
            const key: NodeKey = .{ .module = mi, .node = node.int() };
            const callers = &p.sites.items[site].callers;
            const known_caller = for (callers.items) |k| {
                if (k.module == key.module and k.node == key.node) break true;
            } else false;
            if (!known_caller) try callers.append(p.arena(), key);
        }
        if (unknown) {
            for (args) |a| try p.escape(vals[a.int()]);
            if (ir.tag(callee) == .member) try p.escape(vals[ir.data(callee).lhs]);
            out.top = true;
        }
        return out;
    }

    // ---- The facts -----------------------------------------------------------

    /// What an effect-free chain — a name, or properties of one — may be,
    /// read without recording anything. Null for anything else.
    fn chain(p: *Pts, mi: u32, top: Index, node: Index) Allocator.Error!?Val {
        const ir = p.s.mods[mi].ir;
        const d = ir.data(node);
        return switch (ir.tag(node)) {
            .ident => blk: {
                const n: NameIndex = @enumFromInt(d.lhs);
                if (p.s.mods[mi].globalOf(n)) |g| break :blk p.view(p.globals[g]);
                const v = p.locals.get(.{ .module = mi, .top = top.int(), .name = n.int() }) orelse break :blk null;
                break :blk p.view(v);
            },
            .member => blk: {
                const obj = try p.chain(mi, top, @enumFromInt(d.lhs)) orelse break :blk null;
                break :blk try p.read(obj, p.propId(mi, @enumFromInt(d.rhs)), false);
            },
            else => null,
        };
    }

    /// What a chain may be, when evaluating it can neither throw nor run
    /// code: a name, or a property of a chain every object of which is a
    /// program object literal (`known`) — no getter, no `null`. Null for
    /// anything else.
    fn safeChain(p: *Pts, mi: u32, top: Index, node: Index) Allocator.Error!?Val {
        const ir = p.s.mods[mi].ir;
        const d = ir.data(node);
        return switch (ir.tag(node)) {
            .ident => try p.chain(mi, top, node),
            .member => blk: {
                const obj = try p.safeChain(mi, top, @enumFromInt(d.lhs)) orelse break :blk null;
                if (!p.known(obj)) break :blk null;
                break :blk try p.read(obj, p.propId(mi, @enumFromInt(d.rhs)), false);
            },
            else => null,
        };
    }

    /// Whether every object `obj` may be is an object literal the program
    /// made and nothing it cannot see holds.
    fn known(p: *const Pts, obj: Val) bool {
        // A `null` or `undefined` object makes the read throw, which a
        // fold would lose.
        if (!p.ok or obj.top or obj.prim or obj.nullish() or obj.sites.len == 0) return false;
        for (obj.sites) |site| {
            const st = &p.sites.items[site];
            if (st.kind != .object or st.escaped) return false;
        }
        return true;
    }

    /// Property `id` is never written on any object `obj` may be: reading
    /// it gives `undefined`.
    fn neverWritten(p: *const Pts, obj: Val, id: u32) bool {
        if (id == none or !p.known(obj)) return false;
        for (p.s.in.builtin_props) |b| if (b == id) return false;
        for (obj.sites) |site| {
            if (p.sites.items[site].any_written) return false;
            if (p.findProp(site, id)) |pr| if (pr.written) return false;
        }
        return true;
    }

    /// Property `id` is never read on any object `obj` may be: writing it
    /// changes nothing anyone can see.
    fn neverRead(p: *const Pts, obj: Val, id: u32) bool {
        if (id == none or !p.known(obj)) return false;
        for (obj.sites) |site| {
            if (p.sites.items[site].all_read) return false;
            if (p.findProp(site, id)) |pr| if (pr.read) return false;
        }
        return true;
    }

    /// Of object literal `node`, a site: whether key `id` is never read.
    fn keyUnread(p: *const Pts, mi: u32, node: Index, id: u32) bool {
        if (!p.ok or id == none) return false;
        const site = p.site_at.get(.{ .module = mi, .node = node.int() }) orelse return false;
        const st = &p.sites.items[site];
        if (st.escaped or st.all_read) return false;
        if (p.findProp(site, id)) |pr| if (pr.read) return false;
        return true;
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
    // Counted over what the module still writes: a node lowering or
    // specialisation left behind (a conditional written as an `if`, a
    // folded branch) refers to its operands too, and would make a test
    // look shared that is not.
    var seen: std.DynamicBitSetUnmanaged = try .initEmpty(gpa, ir.nodes.len);
    defer seen.deinit(gpa);
    var stack: std.ArrayList(Index) = .empty;
    defer stack.deinit(gpa);
    try stack.appendSlice(gpa, ir.extraSlice(ir.body, Index));
    while (JsIr.popOperand(&stack)) |node| {
        if (seen.isSet(node.int())) continue;
        seen.set(node.int());
        children.clearRetainingCapacity();
        try operandsOf(gpa, ir, node, &children);
        for (children.items) |c| refs[c.int()] +|= 1;
        try pushChildren(gpa, ir, node, &stack);
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

/// Every child of `node` onto `stack`: a statement's expressions and
/// statements, an expression's operands, and a function's body.
fn pushChildren(gpa: Allocator, ir: *const JsIr, node: Index, stack: *std.ArrayList(Index)) Allocator.Error!void {
    const d = ir.data(node);
    switch (ir.tag(node)) {
        .import_stmt, .export_stmt, .break_stmt, .continue_stmt => {},
        .const_decl => try stack.append(gpa, @enumFromInt(d.rhs)),
        .let_decl => if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| try stack.append(gpa, v),
        .func_decl, .gen_decl => try stack.appendSlice(gpa, ir.extraSlice(ir.extraData(@enumFromInt(d.rhs), JsIr.Func).body(), Index)),
        .arrow => try stack.appendSlice(gpa, ir.extraSlice(ir.extraData(@enumFromInt(d.lhs), JsIr.Func).body(), Index)),
        .assign_stmt => try stack.appendSlice(gpa, &.{ @enumFromInt(d.lhs), @enumFromInt(d.rhs) }),
        .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| try stack.append(gpa, v),
        .if_stmt => {
            try stack.append(gpa, @enumFromInt(d.lhs));
            const b = ir.extraData(@enumFromInt(d.rhs), JsIr.If);
            try stack.appendSlice(gpa, ir.extraSlice(b.thenBody(), Index));
            try stack.appendSlice(gpa, ir.extraSlice(b.elseBody(), Index));
        },
        .while_true, .block_stmt => try stack.appendSlice(gpa, ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index)),
        .for_of => {
            const loop = ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
            try stack.append(gpa, loop.iterable);
            try stack.appendSlice(gpa, ir.extraSlice(loop.body(), Index));
        },
        .switch_stmt => {
            try stack.append(gpa, @enumFromInt(d.lhs));
            try stack.appendSlice(gpa, ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index));
        },
        .switch_case => {
            if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| try stack.append(gpa, t);
            try stack.appendSlice(gpa, ir.extraSlice(ir.subRange(@enumFromInt(d.rhs)), Index));
        },
        .expr_stmt, .throw_stmt => try stack.append(gpa, @enumFromInt(d.lhs)),
        .try_stmt => {
            const t = ir.extraData(@enumFromInt(d.rhs), JsIr.Try);
            try stack.appendSlice(gpa, ir.extraSlice(t.body(), Index));
            try stack.appendSlice(gpa, ir.extraSlice(t.finalBody(), Index));
        },
        else => try ir.pushOperands(gpa, stack, node),
    }
}

/// How many times `top` declares name `n`: a `const`, `let`, `function` or
/// `for…of` binding, or a parameter of a function in it.
fn declCount(gpa: Allocator, ir: *const JsIr, top: Index, n: NameIndex) Allocator.Error!u32 {
    var count: u32 = 0;
    var stack: std.ArrayList(Index) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, top);
    while (JsIr.popOperand(&stack)) |node| {
        const d = ir.data(node);
        switch (ir.tag(node)) {
            .const_decl, .let_decl, .for_of => if (d.lhs == n.int()) {
                count += 1;
            },
            .func_decl, .gen_decl, .arrow => {
                if (ir.tag(node) != .arrow and d.lhs == n.int()) count += 1;
                const record: ExtraIndex = @enumFromInt(if (ir.tag(node) == .arrow) d.lhs else d.rhs);
                for (ir.extraSlice(ir.extraData(record, JsIr.Func).params(), NameIndex)) |p| if (p == n) {
                    count += 1;
                };
            },
            else => {},
        }
        try pushChildren(gpa, ir, node, &stack);
    }
    return count;
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
        .import_stmt, .export_stmt, .func_decl, .gen_decl, .while_true, .break_stmt, .continue_stmt, .block_stmt, .try_stmt => {},
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

/// A test of a chain against `null`: `X === null` (`!==`), or `X == null`
/// (`!=`), either way round, where `X` is a name or properties of one.
const NullTest = struct {
    chain: Index,
    /// The branch where the test is true is the one where `X` is null.
    null_in_then: bool,
    /// `==`: `undefined` too.
    loose: bool,

    fn guard(t: NullTest, mi: u32) Pts.Guard {
        return .{ .module = mi, .chain = t.chain, .nul = true, .undef = t.loose };
    }
};

fn nullTest(ir: *const JsIr, node: Index) ?NullTest {
    if (ir.tag(node) != .binary) return null;
    const op: JsIr.BinaryOp = @enumFromInt(ir.data(node).rhs);
    const b = ir.extraData(@enumFromInt(ir.data(node).lhs), JsIr.Binary);
    const chain, const other = if (ir.tag(b.right) == .null_lit) .{ b.left, b.right } else .{ b.right, b.left };
    if (ir.tag(other) != .null_lit) return null;
    switch (ir.tag(chain)) {
        .ident, .member => {},
        else => return null,
    }
    var x = chain;
    while (ir.tag(x) == .member) x = @enumFromInt(ir.data(x).lhs);
    if (ir.tag(x) != .ident) return null;
    return switch (op) {
        .strict_eq => .{ .chain = chain, .null_in_then = true, .loose = false },
        .strict_ne => .{ .chain = chain, .null_in_then = false, .loose = false },
        .loose_eq => .{ .chain = chain, .null_in_then = true, .loose = true },
        else => null,
    };
}

/// Whether two chains — a name, or properties of one — are the same one.
fn sameChain(ir: *const JsIr, a: Index, b: Index) bool {
    var x = a;
    var y = b;
    var depth: u32 = 0;
    while (depth < 64) : (depth += 1) {
        if (ir.tag(x) != ir.tag(y)) return false;
        const dx = ir.data(x);
        const dy = ir.data(y);
        switch (ir.tag(x)) {
            .ident => return dx.lhs == dy.lhs,
            .member => {
                if (dx.rhs != dy.rhs) return false;
                x = @enumFromInt(dx.lhs);
                y = @enumFromInt(dy.lhs);
            },
            else => return false,
        }
    }
    return false;
}

/// Whether a function body may run off its end, returning `undefined`: its
/// last statement is not a `return` or a `throw`, nor an `if` both of whose
/// arms end in one. A loop may be left by a `break`, so it may.
fn fallsThrough(ir: *const JsIr, range: JsIr.SubRange) bool {
    var list = ir.extraSlice(range, Index);
    var depth: u32 = 0;
    while (depth < 64) : (depth += 1) {
        if (list.len == 0) return true;
        const last = list[list.len - 1];
        switch (ir.tag(last)) {
            .return_stmt, .throw_stmt => return false,
            .if_stmt => {
                const branches = ir.extraData(@enumFromInt(ir.data(last).rhs), JsIr.If);
                if (fallsThrough(ir, branches.thenBody())) return true;
                list = ir.extraSlice(branches.elseBody(), Index);
            },
            .block_stmt => {
                // A labelled block may be left by its `break`.
                if (@as(NameIndex, @enumFromInt(ir.data(last).lhs)) != .none) return true;
                list = ir.extraSlice(ir.subRange(@enumFromInt(ir.data(last).rhs)), Index);
            },
            else => return true,
        }
    }
    return true;
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
        // Two declarations each make an object of their own.
        .string, .name => std.mem.eql(u8, x.bytes, y.bytes),
        .true_lit, .false_lit => x.kind == y.kind,
        .null_lit, .undefined_lit => true,
    };
}
