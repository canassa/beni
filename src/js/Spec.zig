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
//! declares is declared twice in the declaration, else as a block. A test
//! that is always truthy or always falsy without being a literal (`x ||
//! true`, `Lat`'s truthiness) folds the same way where skipping it loses
//! nothing (`effectFreeTest`), and what follows a statement that cannot
//! complete goes (`deadTail`).
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
const RepKeys = @import("RepKeys.zig");
const lists = @import("../lists.zig");
const Arena = @import("../Arena.zig");

const Node = JsIr.Node;
const Index = Node.Index;
const NameIndex = JsIr.NameIndex;
const ExtraIndex = JsIr.ExtraIndex;

pub const none: u32 = std.math.maxInt(u32);

/// A map keyed by a struct of `u32`s, hashed by a multiply-and-shift mix of
/// them: the pass looks keys up in its innermost walks, where hashing the
/// key's bytes cost more than the rest of the lookup. No map's order is
/// ever an answer (`Determinism` above), so the hash is free to be cheap.
///
/// Open addressing with linear probing, at most half full, written here
/// rather than `std.HashMapUnmanaged`: Zig's own backend, which builds the
/// tests' compiler, inlines none of that map's generic layers, and a probe
/// cost over a thousand instructions in the specialiser's walks. The
/// interface is the part of std's the pass uses, with the same rule that
/// an insertion invalidates every pointer handed out before it.
fn KeyMap(comptime K: type, comptime V: type) type {
    return struct {
        const Map = @This();

        slots: []Slot = &.{},
        len: u32 = 0,

        pub const empty: Map = .{};

        const Slot = struct { key: K, value: V, used: bool };

        pub const GetOrPutResult = struct { key_ptr: *K, value_ptr: *V, found_existing: bool };
        pub const KV = struct { key_ptr: *K, value_ptr: *V };

        inline fn hash(k: K) u64 {
            var h: u64 = 0x9E3779B97F4A7C15;
            inline for (@typeInfo(K).@"struct".field_names) |field_name| {
                h = (h ^ @as(u32, @field(k, field_name))) *% 0xFF51AFD7ED558CCD;
                h ^= h >> 29;
            }
            return h;
        }

        inline fn eql(a: K, b: K) bool {
            inline for (@typeInfo(K).@"struct".field_names) |field_name| {
                if (@field(a, field_name) != @field(b, field_name)) return false;
            }
            return true;
        }

        /// The slot holding `k`, or the free one it would take. The table
        /// is never full, so the probe ends.
        fn find(m: *const Map, k: K) usize {
            const mask = m.slots.len - 1;
            var i: usize = @intCast(hash(k) & mask);
            while (true) : (i = (i + 1) & mask) {
                const slot = &m.slots[i];
                if (!slot.used or eql(slot.key, k)) return i;
            }
        }

        pub fn count(m: Map) u32 {
            return m.len;
        }

        pub fn get(m: Map, k: K) ?V {
            if (m.len == 0) return null;
            const slot = &m.slots[m.find(k)];
            return if (slot.used) slot.value else null;
        }

        pub fn getOrPut(m: *Map, gpa: Allocator, k: K) Allocator.Error!GetOrPutResult {
            if ((m.len + 1) * 2 > m.slots.len) try m.grow(gpa);
            const slot = &m.slots[m.find(k)];
            if (!slot.used) {
                slot.* = .{ .key = k, .value = undefined, .used = true };
                m.len += 1;
                return .{ .key_ptr = &slot.key, .value_ptr = &slot.value, .found_existing = false };
            }
            return .{ .key_ptr = &slot.key, .value_ptr = &slot.value, .found_existing = true };
        }

        pub fn put(m: *Map, gpa: Allocator, k: K, v: V) Allocator.Error!void {
            (try m.getOrPut(gpa, k)).value_ptr.* = v;
        }

        /// Takes `k` out, if it is in. Every entry after it in its probe
        /// run that may sit in its slot moves back into it (backward-shift
        /// deletion), so `find` needs no tombstones.
        pub fn remove(m: *Map, k: K) void {
            if (m.len == 0) return;
            const mask = m.slots.len - 1;
            var hole = m.find(k);
            if (!m.slots[hole].used) return;
            var j = hole;
            while (true) {
                j = (j + 1) & mask;
                if (!m.slots[j].used) break;
                const home: usize = @intCast(hash(m.slots[j].key) & mask);
                // The entry may move into the hole unless its home lies in
                // the cyclic interval (hole, j].
                const stays = if (hole < j) home > hole and home <= j else home > hole or home <= j;
                if (!stays) {
                    m.slots[hole] = m.slots[j];
                    hole = j;
                }
            }
            m.slots[hole].used = false;
            m.len -= 1;
        }

        fn grow(m: *Map, gpa: Allocator) Allocator.Error!void {
            const old = m.slots;
            m.slots = try gpa.alloc(Slot, if (old.len == 0) 16 else old.len * 2);
            for (m.slots) |*slot| slot.used = false;
            for (old) |slot| if (slot.used) {
                m.slots[m.find(slot.key)] = slot;
            };
            gpa.free(old);
        }

        pub fn clearRetainingCapacity(m: *Map) void {
            for (m.slots) |*slot| slot.used = false;
            m.len = 0;
        }

        pub fn clone(m: Map, gpa: Allocator) Allocator.Error!Map {
            return .{ .slots = try gpa.dupe(Slot, m.slots), .len = m.len };
        }

        pub const Iterator = struct {
            slots: []Slot,
            i: usize = 0,

            pub fn next(it: *Iterator) ?KV {
                while (it.i < it.slots.len) {
                    const slot = &it.slots[it.i];
                    it.i += 1;
                    if (slot.used) return .{ .key_ptr = &slot.key, .value_ptr = &slot.value };
                }
                return null;
            }
        };

        pub fn iterator(m: *const Map) Iterator {
            return .{ .slots = m.slots };
        }
    };
}

/// The literals' table's keys (`Spec.intern`), hashed by the same kind of
/// mix as `KeyMap`'s, a byte at a time: the keys are a kind's byte and a
/// literal's spelling, a few bytes each, and every literal of the program
/// is looked up once.
const LitContext = struct {
    pub fn hash(_: LitContext, k: []const u8) u64 {
        return litHash(k[0], k[1..]);
    }
    pub fn eql(_: LitContext, a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }
};

/// A `Lit` looked up in the table without its key being built.
const LitAdapter = struct {
    pub fn hash(_: LitAdapter, lit: Lit) u64 {
        return litHash(@backingInt(lit.kind), lit.bytes);
    }
    pub fn eql(_: LitAdapter, lit: Lit, k: []const u8) bool {
        return k[0] == @backingInt(lit.kind) and std.mem.eql(u8, k[1..], lit.bytes);
    }
};

fn litHash(kind: u8, bytes: []const u8) u64 {
    var h: u64 = (0x9E3779B97F4A7C15 ^ @as(u64, kind)) *% 0xFF51AFD7ED558CCD;
    for (bytes) |b| h = (h ^ b) *% 0xFF51AFD7ED558CCD;
    return h ^ (h >> 29);
}

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
/// A record's field: its representation key under a property id.
pub const FieldKey = struct {
    record: u32,
    prop: u32,
    key: JsIr.RepKey,

    pub fn lessThan(_: void, a: FieldKey, b: FieldKey) bool {
        if (a.record != b.record) return a.record < b.record;
        return a.prop < b.prop;
    }
};

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
    /// The property-name ids of `implicit_host_keys`. A key of one is not
    /// unread. The host reads it with no member expression in the program.
    implicit_props: []const u32 = &.{},
    /// The property-name id of `prototype_assign`, or `none` when the
    /// program never names it. A write of it assigns `[[Prototype]]`.
    proto_prop: u32 = none,
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
    /// The property-name id of `$`, a constructor's tag (slice 9), or
    /// `none`.
    tag_prop: u32 = none,
    /// `--points-to-largest`, the hidden flag (`src/Cli.zig`): each var keeps
    /// where it came from, so that `Stats.pts_largest` can name the var that
    /// held `Stats.pts_max_set` sites. It changes no fact and no byte.
    trace_largest: bool = false,
    /// `--check-call-graph` (`src/Cli.zig`): every function body fact 3's call
    /// graph leaves unreached in any solve throws when it runs
    /// (`Spec.checkCallGraph`). Tests only: the corpus's release passes run
    /// with it, so a body the program calls that the graph missed (#685)
    /// fails a gate.
    check_call_graph: bool = false,
    /// `--release`: the build's representation keys, which say which of
    /// the keys in the IR's columns are wild (`backend.md` §9,
    /// *Declared-type filtering of fact 3*). Null: every key is.
    rep_keys: ?*const RepKeys = null,
    /// Per record representation and property: the representation key of
    /// that field, sorted by record then property. A site's own var of the
    /// property holds only sites of that key (*Declared-type filtering of
    /// fact 3*, amended for #722).
    field_keys: []const FieldKey = &.{},
    /// The build's workers (`backend.md` §9, *The combined solver — Where
    /// it runs*): the combined solver extracts the modules that changed on
    /// them. Null: on the calling thread.
    parallel: ?Parallel = null,
};

/// A way to run `call(task, scratch, item)` for every item of `items` on
/// threads at once: each call writes only what its item owns, and
/// `scratch` is its thread's, emptied before each item. `work` is how
/// much there is to do in all (nodes), which says how many threads help.
pub const Parallel = struct {
    context: *anyopaque,
    run: *const fn (
        context: *anyopaque,
        items: []const u32,
        work: usize,
        task: *const anyopaque,
        call: *const fn (task: *const anyopaque, scratch: Allocator, item: u32) Allocator.Error!void,
    ) Allocator.Error!void,
};

/// A call the entry file makes of a top-level function: the whole-program
/// names of the callee and of each argument, a name read whole.
pub const Entry = struct {
    callee: u32,
    args: []const u32,
};

/// Where one of fact 3's vars came from (`Input.trace_largest`), for a
/// person reading `--points-to-largest`'s line: what kind of var it is, the
/// module (an index of `Input.modules`) and node it belongs to, its name and
/// its property. A summary's var and a load cell of a var's property name
/// the var they are of (`of`), by its kind, module, node and name.
pub const VarOrigin = struct {
    kind: Role,
    /// `kind`'s, for a summary's var or a load cell of a var; else `kind`.
    of: Role,
    /// `none` for a global.
    module: u32 = none,
    /// The top-level statement of a local; the object, array or function a
    /// site's var belongs to; the read of a load cell of an expression.
    node: u32 = none,
    /// That node's byte offset in its module's source, or `JsIr.Node.no_pos`.
    pos: u32 = JsIr.Node.no_pos,
    /// A local's name, as its module has it; a global's whole-program id is
    /// `global`.
    name: ?JsIr.Name = null,
    global: u32 = none,
    /// The property-name id of a site's, a summary's or a load cell's
    /// property, `elem_prop` for an element; `none` else.
    prop: u32 = none,
    /// The property of the var it is of (`of`), when that is a site's.
    of_prop: u32 = none,
    /// How many sites it held.
    sites: u32 = 0,

    pub const Role = enum(u8) { global, local, site_any, site_prop, ret, summary_any, summary_prop, load };
};

/// One site of `Stats.pts_largest_sites`: the node that made it, in module
/// `module` of `Input.modules`, and that node's byte offset in its source.
pub const SiteOrigin = struct { module: u32, node: u32, pos: u32 };

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

/// How many times the rewrite patches one statement at most, each time by
/// the counts the last left (`rewrite`).
const max_patch_turns = 7;
/// How deep a statement nesting the rewriting walk follows by recursion.
const max_depth = 200;
/// On a node index in an evaluating walk's stack: its operands are done.
const post_bit: u32 = 1 << 31;

/// What the pass did, for `--self-profile`'s counters: work that must not
/// grow with code the pass leaves as it was.
pub const Stats = struct {
    /// Statement lists a list sweep (`srList`) copied to rewrite, of those
    /// holding a statement it could act on (`listActs`).
    lists_examined: u64 = 0,
    /// Per whole-program id of `Input.globals`: a body was copied out of
    /// that top-level declaration into another statement (slices 5, 8 and
    /// 9), so what it wrote may live on where it is not. Per module: a body
    /// was copied out of one of its statements the pass cannot name. Field
    /// names are decided after the pass from what it left
    /// (`backend.md` §9, *Field names are decided after specialisation*).
    copied: []const bool = &.{},
    copied_modules: []const bool = &.{},
    /// Solves (`analyse`): fact 3 to its fixpoint, then facts 1, 2, 4 and
    /// 5 to theirs, each from ⊥ — one per structural pass, each read by one
    /// rewrite (`backend.md` §9, *The combined solver*, slice 6).
    solves: u64 = 0,
    /// The combined solver (`backend.md` §9, *The combined solver*, slice
    /// 4), over every analysis: the modules it extracted, and those whose
    /// constraints it kept because the module had not changed; the
    /// constraints it solved and how many evaluations that took; and the
    /// solves that hit the work budget and set what was still changing to ⊤.
    solve_extracted: u64 = 0,
    solve_kept: u64 = 0,
    solve_constraints: u64 = 0,
    solve_evaluations: u64 = 0,
    solve_budget_hit: u64 = 0,
    /// The top-level statements an extraction walked, and those whose
    /// constraints it kept from the last one (`Extractor.reuse`).
    solve_stmts_walked: u64 = 0,
    solve_stmts_kept: u64 = 0,
    /// Fact 3's fixpoints (`Pts.fixpoint`: one per analysis, and one more
    /// each time definite initialisation finds keys) and their sweeps: the
    /// first walk, then each pass over the constraints waiting
    /// (`Pts.byConstraints`).
    points_to_runs: u64 = 0,
    points_to_sweeps: u64 = 0,
    /// Analyses that kept the last fact-3 state instead of solving again:
    /// nothing fact 3 reads changed since that solve (`Spec.fact3Kept`).
    points_to_reused: u64 = 0,
    /// Passes of the structural loop in `run` that changed the program.
    passes: u64 = 0,
    /// The caps, each counted where it stopped work that would have gone
    /// on — the counters to read first when an output grew (research 52
    /// §3.7). The structural loop stopped at `max_passes` after a pass that did;
    /// definite initialisation stopped at `max_init_runs` while it still
    /// found keys; and an inlining pass stopped at its own cap
    /// (`copyLimit`, the nodes `inlineOnce` and `fuseCalls` may copy;
    /// `inlineSmall`'s four turns; `foldConstructors`' budget of a list).
    passes_capped: u64 = 0,
    init_capped: u64 = 0,
    inline_capped: u64 = 0,
    /// Slice 5 (`inlineOnce`): the counts of the program it made
    /// (`inlineBatch`), the functions it wrote, the candidates it left for
    /// the next count because a write in the same count touched them, and
    /// those it did not ask again because `inlineAt` declined them before
    /// and neither module changed since (`Refusal`).
    inline_scans: u64 = 0,
    inlined: u64 = 0,
    inline_waits: u64 = 0,
    inline_refusals_kept: u64 = 0,
    /// Fact 3's sets (`plans/type-directed-points-to.md` slice 0), over
    /// every fixpoint but a safety build's reference (`Pts.fixpoint`): the
    /// most sites one var held at once; the site words its set table holds
    /// (`Pts.Sets`: each distinct set once, whichever var, union or
    /// difference made it); the copy edges and the load cells it made.
    pts_max_set: u64 = 0,
    pts_set_words: u64 = 0,
    pts_edges: u64 = 0,
    pts_load_cells: u64 = 0,
    /// The batches a var took (`Pts.joinNow`), and those that added no
    /// site and no flag to it.
    pts_joins: u64 = 0,
    pts_joins_empty: u64 = 0,
    /// Under `Input.trace_largest`: where the var that first held
    /// `pts_max_set` sites came from.
    pts_largest: ?VarOrigin = null,
    /// And the sites it held then: what flowed into it.
    pts_largest_sites: []const SiteOrigin = &.{},
};

pub fn run(gpa: Allocator, arena: Allocator, in: Input) Allocator.Error!Stats {
    var s: Spec = try .init(gpa, arena, in);
    s.pts = .init(&s);
    defer s.pts.deinit();
    // The structural passes first, with no facts (`backend.md` §9, *Where it
    // runs*, amended 2026-10-22): what they write in, the one solve sees.
    try s.structureFirst();
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
        if (try s.fuseCalls()) changed = true;
        if (try s.constructors()) changed = true;
        if (try s.scalarReplace()) changed = true;
        // The list modes that change the program and read no fact, in the
        // loop (`backend.md` §9, *Where it runs*, G9): `x = x` gone, and a
        // function called where it is made written there (`betaReduce`).
        s.list_mode = .tidy;
        if (try s.eachFunctionList()) changed = true;
        if (!changed) break;
        s.stats.passes += 1;
        if (pass + 1 == max_passes) s.stats.passes_capped += 1;
        _ = try s.prune();
        try s.grow();
        try s.rounds();
    }
    // Identical functions are one, once nothing else will change their
    // code; reachability drops the copies.
    if (try s.mergeSame()) _ = try s.prune();
    // Last of the sweeps: a short `switch` on a name is its `if`s.
    s.list_mode = .switches;
    _ = try s.eachFunctionList();
    // Last, so that slice 8, which writes a call through a property in
    // only with every argument, has seen them all.
    try s.trimArguments();
    try s.forwardEntry();
    // Slice 10, after every fact: a value made at start-up and read once
    // there is made where it is read; reachability drops its declaration.
    if (try s.inlineReads()) _ = try s.prune();
    if (in.check_call_graph) try s.poisonMissed();
    try s.finish();
    s.stats.copied = s.copied[0..@min(s.copied.len, in.globals)];
    s.stats.copied_modules = s.copied_modules;
    return s.stats;
}

/// How many times the inlining passes and the facts after them repeat.
const max_passes = 3;

/// How many nodes a program may have for a safety build to check the
/// combined solver against the sweeps (`Spec.checkedSolve`).
const max_solve_checked_nodes = Pts.max_checked_nodes;

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
///
/// Beside the value, its truthiness (research 52 §3.4, Click's combined
/// lattice for conditions): ⊥, always truthy, always falsy, or either. A
/// literal's is its literal's (`Spec.truthOf`), so `truth` is stored only
/// for nonnull and ⊤ — `x || true` is ⊤ and always truthy. It is joined on
/// its own, and only the rewrite spends it, where what it skips evaluating
/// does nothing (`Spec.effectFreeTest`): a value that is a literal stays one
/// only where evaluating the expression does nothing the literal could lose.
const Lat = packed struct(u32) {
    state: State,
    truth: Truth = .bot,
    lit: u28 = 0,

    const State = enum(u2) { bot, lit, top, nonnull };
    const Truth = enum(u2) {
        bot,
        yes,
        no,
        unknown,

        fn join(a: Truth, b: Truth) Truth {
            if (a == .bot) return b;
            if (b == .bot or a == b) return a;
            return .unknown;
        }

        fn not(t: Truth) Truth {
            return switch (t) {
                .yes => .no,
                .no => .yes,
                else => t,
            };
        }
    };
    const bot: Lat = .{ .state = .bot };
    const top: Lat = .{ .state = .top, .truth = .unknown };
    const nonnull: Lat = .{ .state = .nonnull, .truth = .unknown };
    /// An object, an array or a function: never `null`, always truthy.
    const object: Lat = .{ .state = .nonnull, .truth = .yes };

    fn of(id: u32) Lat {
        return .{ .state = .lit, .lit = @intCast(id) };
    }

    fn eql(a: Lat, b: Lat) bool {
        return a.state == b.state and switch (a.state) {
            .bot => true,
            .lit => a.lit == b.lit,
            .top, .nonnull => a.truth == b.truth,
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
    /// Its place among every module's top-level statements, in order.
    index: u32 = none,
    /// The function's record when it is one the pass tracks: a top-level
    /// `const` of a plain arrow, or a top-level `function`.
    func: ?ExtraIndex = null,
    /// Where its parameters' facts start in `Spec.params`.
    params: u32 = 0,
    arity: u32 = 0,
};

// ---------------------------------------------------------------------------
// The combined solver's constraints (backend.md §9, *The combined solver*)
// ---------------------------------------------------------------------------

/// A constraint's kind, one `switch` arm of `Solver.eval` (slice 4). There
/// is one constraint per node a walk of the program evaluates
/// (`Spec.eval`), in the order the walk evaluates them, its cell the node's
/// occurrence; and one per statement that writes what no node holds: a
/// property (`store`), or what a function returns (`ret`).
const Op = enum(u7) {
    /// A value fixed by the node's kind: `a` is `fixed_top` or
    /// `fixed_object` (an arrow, an array, a `new`).
    constant,
    /// A literal node (`Spec.literalValue`), interned at the merge.
    literal,
    /// A whole-program name `a` (`Spec.globalValue`): fixed for one solve,
    /// since `decl`, `escaped` and `assigned` are.
    global,
    /// A local's read after its one declaration: the value of cell `a`,
    /// the declaration's initialiser (`none`: ⊤), narrowed past a guard
    /// when flagged (`Spec.guardNames`).
    local,
    /// A read of parameter `a` of the statement's own top-level function,
    /// narrowed when flagged. The merge finds the parameter's cell.
    param,
    /// The operand's cell `a`.
    unary,
    /// `pool[a..]`: the left and the right operand's cells.
    binary,
    /// `pool[a..]`: the test's, the consequent's and the alternate's cells,
    /// then fact 5's second case (`Spec.nullTestTaken`): the tested read's
    /// cell, the taken branch's cell and node, or `none` three times.
    cond,
    /// `pool[a..]`: the callee's whole-program name (`none`: not a name),
    /// the argument count, the arguments' cells.
    call,
    /// `pool[a..]`: the part count, then each part's cell.
    template,
    /// `a`: the object's cell.
    member,
    /// `pool[a..]`: the count of keys, then each key's name and value's
    /// cell; flagged when the literal holds a spread.
    object,
    /// `o.p = v`: its node is the target `o.p`, `a` the value's cell.
    store,
    /// A `return` of the function that is its node, `a` the value's cell
    /// (`none` for what may run off its end: `undefined`).
    ret,
    /// A store's value, or a sequence's (`JsIr.Node.Tag.assign`,
    /// `sequence`): the value of cell `a`, never as a literal
    /// (`Spec.demote`), since making it writes a record and no fold may
    /// take it for its value.
    effect,
};

/// A constraint's kind and its one flag (`Op`).
const Code = packed struct(u8) {
    op: Op,
    flag: bool = false,

    /// Whether the constraint is a node's: its `node` is the node's cell.
    fn ofNode(c: Code) bool {
        return c.op != .store and c.op != .ret;
    }
};

const fixed_top: u32 = 0;
const fixed_object: u32 = 1;

/// One module's constraints (`backend.md` §9, *The combined solver —
/// Extraction*): made from the module's `JsIr` and its names' whole-program
/// ids alone (`Extractor`), so on a worker, and each statement's kept while
/// its nodes stand (`Mod.keptNodes`). A cell is the module's own: a node's
/// index for its first occurrence in the walk, `nodes + k` for its k-th
/// repeat (`over` names the node), as `Mod.memo` keeps the last; the merge
/// adds the module's base. In an arena of its own, which only the task
/// extracting the module touches: 9 bytes a constraint, and the pool.
const Extract = struct {
    arena: Arena = .init(std.heap.page_allocator),
    /// What it was made from: the module's `epoch`, and how many names the
    /// walks count (`Mod.stamp.len`).
    epoch: u64 = std.math.maxInt(u64),
    names: usize = 0,
    nodes: u32 = 0,
    code: []Code = &.{},
    /// A node's constraint's cell; a statement's constraint's node.
    node: []u32 = &.{},
    a: []u32 = &.{},
    pool: []u32 = &.{},
    over: []u32 = &.{},
    stmts: []ExStmt = &.{},
    reads: []GRead = &.{},
    assigns: []u32 = &.{},
    /// Of the last extraction: the statements walked, and those whose
    /// constraints it took from the one before.
    walked: u32 = 0,
    reused: u32 = 0,
    /// The readers index of the module's cells: per cell, the constraints
    /// that read it, `rd[rd_off[c]..rd_off[c + 1]]`, by counting sort.
    rd_off: []u32 = &.{},
    rd: []u32 = &.{},
    /// Executability (*The combined solver — Executability*): per
    /// constraint, the exec cell that gates it; the module's exec cells,
    /// the first its top level; and per exec cell the constraints it gates
    /// (`ec`) and the arms below it (`ek`), and per node cell the arms its
    /// value decides (`et`), each `x[x_off[i]..x_off[i + 1]]`.
    exec: []u32 = &.{},
    execs: []ExecCell = &.{},
    ec_off: []u32 = &.{},
    ec: []u32 = &.{},
    ek_off: []u32 = &.{},
    ek: []u32 = &.{},
    et_off: []u32 = &.{},
    et: []u32 = &.{},

    /// A safety build's check that what an extraction kept of the last one
    /// is what a walk of every statement makes (`Extractor.reuse`).
    fn expectSame(x: *const Extract, y: *const Extract, mi: u32) void {
        const same = x.nodes == y.nodes and x.code.len == y.code.len and
            std.mem.eql(u8, @ptrCast(x.code), @ptrCast(y.code)) and std.mem.eql(u32, x.node, y.node) and
            std.mem.eql(u32, x.a, y.a) and std.mem.eql(u32, x.pool, y.pool) and
            std.mem.eql(u32, x.over, y.over) and std.mem.eql(u32, x.assigns, y.assigns) and
            std.mem.eql(u32, x.rd_off, y.rd_off) and std.mem.eql(u32, x.rd, y.rd) and
            std.mem.eql(u32, x.exec, y.exec) and x.execs.len == y.execs.len and std.mem.eql(u32, x.et, y.et) and
            x.reads.len == y.reads.len and x.stmts.len == y.stmts.len;
        if (!same) std.debug.panic("specialisation: module {d}'s constraints kept from its last extraction are not what a walk makes", .{mi});
        for (x.reads, y.reads) |r, q| if (r.g != q.g or r.callee != q.callee) std.debug.panic("specialisation: module {d}'s kept reads differ", .{mi});
        for (x.execs, y.execs) |e, f| if (e.kind != f.kind or e.parent != f.parent or e.a != f.a) std.debug.panic("specialisation: module {d}'s kept exec cells differ", .{mi});
        for (x.stmts, y.stmts) |p, q| if (p.node != q.node or p.cons != q.cons or p.pool != q.pool or p.reads != q.reads or p.assigns != q.assigns or p.execs != q.execs or p.param_reads != q.param_reads)
            std.debug.panic("specialisation: module {d}'s kept statement {d} differs", .{ mi, p.node.int() });
    }

    fn cells(x: *const Extract) u32 {
        return x.nodes + @as(u32, @intCast(x.over.len));
    }

    /// The node cell `c` is an occurrence of.
    fn nodeOf(x: *const Extract, c: u32) u32 {
        return if (c < x.nodes) c else x.over[c - x.nodes];
    }

    /// The node constraint `j` is of.
    fn nodeAt(x: *const Extract, j: usize) Index {
        return @fromBackingInt(@intCast(if (x.code[j].ofNode()) x.nodeOf(x.node[j]) else x.node[j]));
    }

    /// The place in `stmts` of the statement constraint `j` is in.
    fn stmtOf(x: *const Extract, j: usize) u32 {
        var lo: usize = 0;
        var hi: usize = x.stmts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (x.stmts[mid].cons <= j) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo);
    }

    fn deinit(x: *Extract) void {
        x.arena.deinit();
        x.* = .{};
    }
};

/// One top-level statement of an `Extract`: its node, where its constraints
/// and its names' counts end, and whether it reads a parameter of its own
/// function (a read that `Spec.readsName` registers on the function's name).
const ExStmt = struct {
    node: Index,
    cons: u32,
    pool: u32,
    over: u32,
    reads: u32,
    assigns: u32,
    /// Where its exec cells end in `execs`.
    execs: u32 = 0,
    /// The module's `epoch` when the statement was extracted: its
    /// constraints hold while its nodes are what they were then
    /// (`Mod.keptNodes`).
    epoch: u64,
    param_reads: bool,
};

/// An exec cell of a module: a bit, false until something makes it true.
/// The top level is true; a function's body (`a` its node) when a call
/// that runs may call it, or its site escapes; an arm when its parent is
/// true and the value of cell `a` (the test's, or the left operand's)
/// allows it.
const ExecCell = struct {
    kind: ExecKind,
    parent: u32 = none,
    a: u32 = none,

    const ExecKind = enum(u8) { top, body, then_arm, else_arm, and_right, or_right };
};

/// A read of a whole-program name a count makes (`Spec.read`): every one
/// counts for `Spec.reads`, and one that is not a call's callee escapes.
const GRead = struct { g: u32, callee: bool };

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
    /// `Copy.property`'s index of `names` (#608): each name's FIRST index,
    /// as the scan it replaces found it, for `names[0..name_index_len]`.
    /// A name is only ever appended and never rewritten, so the index is
    /// extended, not rebuilt, by `findName` when a lookup finds names past
    /// `name_index_len` — whichever path appended them. In `Spec.arena`.
    name_index: std.AutoHashMapUnmanaged(JsIr.Name, u32) = .empty,
    name_index_len: u32 = 0,
    /// The IR's keys (`JsIr.node_keys`, `JsIr.name_key`), as lists `Copy`
    /// may extend. A node with no row and a name past the end are wild, so
    /// a node `addNode` appends and a name `addName` appends have no key
    /// unless `Copy` gives one its source's (`backend.md` §9,
    /// *Declared-type filtering of fact 3*).
    node_keys: std.ArrayList(JsIr.KeyedNode),
    name_key: std.ArrayList(JsIr.RepKey),
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
    /// Bumped by every change to what a walk of the module meets: a node
    /// rewritten, a list or the body replaced, a name made global.
    version: u32 = 0,
    /// The count `version` is, never wrapping, and which top-level statement
    /// each change was made in (#492). A pass that writes inside one
    /// top-level statement says so (`Spec.within`), and its changes are
    /// that statement's; any other change is the whole module's (`wide`).
    /// A walk of one top-level statement, kept at the `epoch` it was made
    /// at, still holds while neither moved past it (`kept`): the passes
    /// that write one function into another one at a time no longer throw
    /// away every walk of a module of many statements per function.
    epoch: u64 = 0,
    wide: u64 = 0,
    /// The last change made in no named statement but the one that only
    /// replaced the module's list of statements (`bodyChanged`): every
    /// statement's nodes are what they were since then (`keptNodes`).
    wide_nodes: u64 = 0,
    /// The statement `Spec.within` names, and its last change while named.
    scope: ?Index = null,
    scope_last: u64 = 0,
    /// Per node, for a top-level statement: the `epoch` of its last change.
    top_changed: std.ArrayList(u64) = .empty,
    /// Per node: its place as the index last walked it (`Spec.placeIndexed`),
    /// and the walk that wrote it.
    place_at: std.ArrayList(Spec.PlaceEntry) = .empty,
    place_walk: std.ArrayList(u64) = .empty,
    /// Per top-level statement: the module's `version` when the index last
    /// walked it, or `none`.
    place_top: std.ArrayList(u32) = .empty,
    /// Per top-level statement: the `epoch` and the walk of the index's
    /// last walk of it for `Spec.placeKept`.
    /// Per node, for a top-level statement; a walk of 0 is none.
    place_kept: std.ArrayList(struct { epoch: u64 = 0, walk: u64 = 0 }) = .empty,
    /// `Spec.namedIn`'s answers for every whole-program id at once — the
    /// first name of it a walk of the module meets, or `none` — as of
    /// `occ_version` (`none`: never built, or thrown away).
    occ: []u32 = &.{},
    occ_version: u32 = none,
    /// The `Spec.rewrite_epoch` of the rewrite `occ` was built in, or 0.
    occ_rewrite: u32 = 0,
    /// Per whole-program id: the module's one name of it, `none`, or
    /// `none - 1` for several (`Spec.onlyName`), as of `global.len`.
    uniq: []u32 = &.{},
    uniq_len: usize = std.math.maxInt(usize),
    /// Something fact 3 reads may have changed since its last solve: set by
    /// every change (`changed`, `namesChanged`) but one: the literal
    /// `Spec.fact3Neutral` licenses (#575). Cleared when fact 3 solves the
    /// program again (`Spec.keepFact3`).
    fact3: bool = false,
    /// The module's constraints for the combined solver, kept while its
    /// `epoch` stands (`Extract`).
    ex: Extract = .{},
    /// Fact 3's constraints and the steps of its first walk, kept while
    /// its `epoch` stands (`PtsExtract`).
    pex: PtsExtract = .{},

    /// The whole-program id of `n`, or null for a local.
    inline fn globalOf(m: *const Mod, n: NameIndex) ?u32 {
        const i = n.unwrap() orelse return null;
        if (i >= m.global.len) return null;
        const g = m.global[i];
        return if (g == none) null else g;
    }

    /// Something a walk of the module meets changed.
    fn changed(m: *Mod) void {
        m.version +%= 1;
        if (m.version == none) m.version = 0;
        m.epoch += 1;
        if (m.scope != null) m.scope_last = m.epoch else {
            m.wide = m.epoch;
            m.wide_nodes = m.epoch;
        }
        m.fact3 = true;
    }

    /// `changed` for a new list of the module's top-level statements,
    /// each of which is the node it was: a walk of the module is another
    /// walk (`kept`), and a walk of one statement is the same one
    /// (`keptNodes`).
    fn bodyChanged(m: *Mod) void {
        std.debug.assert(m.scope == null);
        m.version +%= 1;
        if (m.version == none) m.version = 0;
        m.epoch += 1;
        m.wide = m.epoch;
        m.fact3 = true;
    }

    /// `changed` for a name added to the module and made global, which no
    /// node names yet: what a walk of a statement meets is as it was.
    fn namesChanged(m: *Mod) void {
        m.version +%= 1;
        if (m.version == none) m.version = 0;
        m.epoch += 1;
        m.fact3 = true;
    }

    /// Whether what a walk of top-level statement `top` met at `at` (an
    /// `epoch`) is what it meets now: no change since was the module's
    /// own or that statement's.
    fn kept(m: *const Mod, top: Index, at: u64) bool {
        if (at < m.wide) return false;
        return m.keptNodes(top, at);
    }

    /// Whether the nodes of top-level statement `top` are what they were at
    /// `at`: `kept`, but past a new list of statements (`bodyChanged`).
    fn keptNodes(m: *const Mod, top: Index, at: u64) bool {
        if (at == m.epoch) return true;
        if (at < m.wide_nodes) return false;
        if (m.scope) |t| if (t == top and at < m.scope_last) return false;
        if (top.int() < m.top_changed.items.len and at < m.top_changed.items[top.int()]) return false;
        return true;
    }

    /// Make `node` something else. Its key goes with what it was: a node
    /// rewritten in place is no longer the allocation lowering keyed
    /// (`backend.md` §9, *Declared-type filtering of fact 3*), and so
    /// neither is a `copyNode` or a `foldTo`, which come through here.
    fn setNode(m: *Mod, node: Index, tag: Node.Tag, lhs: u32, rhs: u32) void {
        m.changed();
        m.ir.nodes.items(.tag)[node.int()] = tag;
        m.ir.nodes.items(.data)[node.int()] = .{ .lhs = lhs, .rhs = rhs };
        if (JsIr.keyRow(m.node_keys.items, node)) |at| m.node_keys.items[at].key = .wild;
    }

    /// `node`, appended by a `Copy` that keeps its source's keys, takes
    /// `key`.
    fn setNodeKey(m: *Mod, gpa: Allocator, node: Index, key: JsIr.RepKey) Allocator.Error!void {
        // An appended node is past every row, so the rows stay ascending.
        const rows = m.node_keys.items;
        std.debug.assert(rows.len == 0 or rows[rows.len - 1].node.int() < node.int());
        try m.node_keys.append(gpa, .{ .node = node, .key = key });
        m.ir.node_keys = m.node_keys.items;
    }

    /// `n`, a name a `Copy` that keeps its source's keys made afresh, takes
    /// `key`.
    fn setNameKey(m: *Mod, gpa: Allocator, n: NameIndex, key: JsIr.RepKey) Allocator.Error!void {
        const i = n.unwrap() orelse return;
        if (i >= m.name_key.items.len) try m.name_key.appendNTimes(gpa, .wild, i + 1 - m.name_key.items.len);
        m.name_key.items[i] = key;
        m.ir.name_key = m.name_key.items;
    }

    fn setData(m: *Mod, node: Index, lhs: u32, rhs: u32) void {
        m.changed();
        m.ir.nodes.items(.data)[node.int()] = .{ .lhs = lhs, .rhs = rhs };
    }

    /// Make `node` what `from` is: same tag and operands. Every operand is
    /// an index, so the two nodes now share their children; `from` itself
    /// is no longer reached from anywhere but `node`. An allocation's key
    /// goes with it: `node` is now the allocation `from` was, of the type
    /// lowering keyed it by (*Declared-type filtering of fact 3*, amended
    /// for #722).
    fn copyNode(m: *Mod, gpa: Allocator, node: Index, from: Index) Allocator.Error!void {
        const d = m.ir.data(from);
        const tag = m.ir.tag(from);
        const key: JsIr.RepKey = switch (tag) {
            .object, .array, .arrow => if (JsIr.keyRow(m.node_keys.items, from)) |at| m.node_keys.items[at].key else .wild,
            else => .wild,
        };
        m.setNode(node, tag, d.lhs, d.rhs);
        if (key == .wild) return;
        if (JsIr.keyRow(m.node_keys.items, node)) |at| {
            m.node_keys.items[at].key = key;
            return;
        }
        var at: usize = m.node_keys.items.len;
        while (at > 0 and m.node_keys.items[at - 1].node.int() > node.int()) at -= 1;
        try m.node_keys.insert(gpa, at, .{ .node = node, .key = key });
        m.ir.node_keys = m.node_keys.items;
    }

    /// `copyNode` for a fold: `node`, a decided `cond`, `&&` or `||`, is
    /// the operand `from` it keeps, position included. The kept code is
    /// what runs, so a map names where it was written and not the test
    /// that decided it; a call kept this way is also the site a copy into
    /// it takes (`Copy.site`; `backend.md` §11.2, item 6).
    fn foldTo(m: *Mod, gpa: Allocator, node: Index, from: Index) Allocator.Error!void {
        try m.copyNode(gpa, node, from);
        m.ir.nodes.items(.pos)[node.int()] = m.ir.pos(from);
    }

    /// Append `words` to `extra`, keeping the IR's view of it current.
    /// `words` may be words of `extra` itself, read again by offset once
    /// there is room (as `addBytes`).
    fn append(m: *Mod, gpa: Allocator, words: []const u32) Allocator.Error!u32 {
        const at: u32 = @intCast(m.extra.items.len);
        const buf = m.extra.items;
        const inside = words.len != 0 and @intFromPtr(words.ptr) >= @intFromPtr(buf.ptr) and @intFromPtr(words.ptr) < @intFromPtr(buf.ptr) + buf.len * @sizeOf(u32);
        if (inside) {
            const off = (@intFromPtr(words.ptr) - @intFromPtr(buf.ptr)) / @sizeOf(u32);
            try m.extra.ensureUnusedCapacity(gpa, words.len);
            m.extra.appendSliceAssumeCapacity(m.extra.items[off..][0..words.len]);
        } else try m.extra.appendSlice(gpa, words);
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
        return @fromBackingInt(@intCast(@as(u32, @intCast(list.len - 1))));
    }

    /// Append a name, keeping the IR's view of the column current. The name
    /// is wild: it is past the end of `name_key`.
    fn addName(m: *Mod, gpa: Allocator, n: JsIr.Name) Allocator.Error!NameIndex {
        const at: u32 = @intCast(m.names.items.len);
        try m.names.append(gpa, n);
        m.ir.names = m.names.items;
        return @fromBackingInt(@intCast(at));
    }

    /// The first index of name `n`, or null: what a walk of `names` from
    /// the start finds, read from `name_index` after it takes in every name
    /// appended since the last lookup.
    fn findName(m: *Mod, arena: Allocator, n: JsIr.Name) Allocator.Error!?NameIndex {
        const len: u32 = @intCast(m.names.items.len);
        if (m.name_index_len < len) {
            try m.name_index.ensureUnusedCapacity(arena, len - m.name_index_len);
            for (m.names.items[m.name_index_len..len], m.name_index_len..) |x, i| {
                const gop = m.name_index.getOrPutAssumeCapacity(x);
                if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
            }
            m.name_index_len = len;
        }
        const i = m.name_index.get(n) orelse return null;
        return @fromBackingInt(i);
    }

    /// Append string bytes, keeping the IR's view current. `text` may be
    /// bytes of this module's own buffer — a literal copied within the
    /// module (`declaredTag`) — which growing the buffer would free before
    /// they are read: such bytes are read again, by offset, once there is
    /// room.
    fn addBytes(m: *Mod, gpa: Allocator, text: []const u8) Allocator.Error!u32 {
        const at: u32 = @intCast(m.string_bytes.items.len);
        const buf = m.string_bytes.items;
        const inside = text.len != 0 and @intFromPtr(text.ptr) >= @intFromPtr(buf.ptr) and @intFromPtr(text.ptr) < @intFromPtr(buf.ptr) + buf.len;
        if (inside) {
            const off = @intFromPtr(text.ptr) - @intFromPtr(buf.ptr);
            try m.string_bytes.ensureUnusedCapacity(gpa, text.len);
            m.string_bytes.appendSliceAssumeCapacity(m.string_bytes.items[off..][0..text.len]);
        } else try m.string_bytes.appendSlice(gpa, text);
        m.ir.string_bytes = m.string_bytes.items;
        return at;
    }
};

/// `std.sort.binarySearch`'s order for node indices.
fn orderIndex(a: Index, b: Index) std.math.Order {
    return std.math.order(a.int(), b.int());
}

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
    /// `Stats.copied` and `Stats.copied_modules` (`noteCopy`).
    copied: []bool,
    copied_modules: []bool,
    /// How many whole-program names there are: `Input.globals`, and one
    /// more for each top-level binding a body written in another place
    /// declares (`addGlobal`).
    globals: u32,
    params: std.ArrayList(Lat) = .empty,
    /// Per parameter, as `params`: some call passes it an argument whose
    /// evaluation may do something (`effectFree`), so a parameter no body
    /// reads keeps its place and the argument.
    arg_effect: std.ArrayList(bool) = .empty,
    lits: std.ArrayList(Lit) = .empty,
    /// Per literal: whether it is truthy (`truthOf`), found once.
    lit_truth: std.ArrayList(Lat.Truth) = .empty,
    lit_ids: std.HashMapUnmanaged([]const u8, u32, LitContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Per `Kind`: the id of its literal without bytes, once interned.
    plain_ids: [@typeInfo(Kind).@"enum".field_names.len]u32 = @splat(none),
    /// Per whole-program name: the id of its `name` literal (`nameLat`),
    /// once interned. Every read of a declaration that makes an object or
    /// a function asks for it, and the table's probe, hashing the key a
    /// byte at a time, is generic code Zig's own backend compiles poorly.
    name_lits: []u32 = &.{},
    /// Per whole-program name: what the last solve found its initialiser
    /// to be (`Solver`'s name cells), as a `Lat`'s bits, `none` for a name
    /// whose value is not its initialiser's (`globalValue`).
    name_solved: []u32 = &.{},
    /// `countExpr`'s stack, shared by the walks it nests: each owns the
    /// entries above the length it found.
    names: std.ArrayList(Index) = .empty,
    /// Walks' stacks, kept for reuse (`takeStack`), and how many are out.
    stacks: std.ArrayList(std.ArrayList(Index)) = .empty,
    stacks_out: u32 = 0,
    /// `eval`'s stack of nodes, shared by the walks it nests (`post_bit`).
    children: std.ArrayList(Index) = .empty,
    /// The declaration the walk is in, and the counter its stamps use.
    current: u32 = 0,
    top_func: ?Decl = null,
    /// The top-level statement being walked, which keys `Pts`'s locals.
    cur_top: Index = undefined,
    pts: Pts = undefined,
    /// `pts` holds the solve of the program as it stood after its last
    /// solve, and per module how many nodes and names it had then: the next
    /// analysis keeps that state while no module changed anything fact 3
    /// reads since (`fact3Kept`, `Mod.fact3`; #575).
    pts_kept: bool = false,
    pts_kept_nodes: []usize = &.{},
    pts_kept_names: []usize = &.{},
    pts_kept_globals: u32 = 0,
    /// Parameter drops `rewrite` made that the kept state takes when the
    /// next analysis keeps it (`keepDrop`, `keepArgs`, `applyKeptDrops`;
    /// #582): the function sites and their parameters, and the arguments
    /// that went.
    kept_drops: std.ArrayList(KeptDrop) = .empty,
    kept_args: std.ArrayList(NodeRef) = .empty,
    changed: bool = false,
    /// The reads of keys are the program's as the rewrite left it
    /// (`liveKeys`): `Pts.Prop.live_read`, and per property id a read on
    /// an object fact 3 has no value for.
    live_keys: bool = false,
    /// The patch refused a local read its literal for the count it read
    /// (`substitutes`): a count the patch lowers may allow it.
    refused_local: bool = false,
    id_read: []bool = &.{},
    /// Slice 4, facts 4 and 5: the object sites whose literal has a spread,
    /// and the function the walk is in. What is written to a property of a
    /// site, and what a function returns, are fact 3's own cells
    /// (`Pts.Prop.lat`, `Pts.Site.ret_lat`).
    spread_sites: []bool = &.{},
    cur_fn: ?NodeRef = null,
    /// `nameIn`'s answers, keyed by module and whole-program id; cleared
    /// each rewrite.
    name_in: KeyMap(SiteProp, u32) = .empty,
    /// `rewrite` is running: the program only loses mentions of names
    /// (`namedIn`).
    only_fewer: bool = false,
    /// Counts the rewrites, from 1 (`Mod.occ_rewrite`).
    rewrite_epoch: u32 = 0,
    /// The place index's walk counter (`indexWalk`).
    place_walks: u64 = 0,
    /// What `rewrite` saw that the next round's facts would spend, which
    /// the round's own facts could not (`again`): the reads of a
    /// whole-program name `substitutes` refused, by the count `reads` took
    /// before the rewrite; and per whole-program name, how many of its
    /// reads a fold of an expression around them took out of the program.
    declined: std.ArrayList(Declined) = .empty,
    folded_reads: []u32 = &.{},
    /// `globalReads`' answer, above the length the caller found.
    fold_reads: std.ArrayList(u32) = .empty,
    /// The locals a guard the walk has passed proves are neither `null` nor
    /// `undefined` (`guardNames`), for the rest of the statement list that
    /// holds the guard.
    narrow: std.ArrayList(NameIndex) = .empty,
    /// What `srList` does to each statement list it reaches.
    list_mode: enum { scalars, constructors, tidy, switches } = .scalars,
    /// Slice 8: `soleCalls`, for the pass in progress, made when a call
    /// first asks for it; null until then.
    sole: ?[]const bool = null,
    /// Slice 8: per fact-3 site, whether a body written in during the pass
    /// in progress may use the function the site makes. The copy's nodes
    /// are newer than the facts, so `soleCalls` cannot see that use.
    copied_sites: []bool = &.{},
    stats: Stats = .{},
    /// Slice 9: `smallTable`, for the pass in progress.
    cf_smalls: []?Small = &.{},
    /// `inlineBatch`'s counts, per module and for the whole program
    /// (`inlineScan`).
    io_scans: []InlineScan = &.{},
    io_refs: []u32 = &.{},
    io_assigned: []u32 = &.{},
    /// Per whole-program name, while one `inlineOnce` lasts: the last call
    /// of it `inlineAt` declined, and the versions of the two modules then
    /// (`inlineScanWrite`). Asked again only once either module changed.
    io_refused: []Refusal = &.{},
    /// Whole-program names whose mentions a write since the last
    /// `inlineScan` may have dropped (an argument nothing read): for them
    /// `io_refs` may say read where nothing reads any more (`nameRead`).
    io_dropped: std.ArrayList(u32) = .empty,
    /// Since the last `inlineScan`, a write changed the program.
    io_written: bool = false,
    /// `isRootCached`'s table.
    io_root: []const bool = &.{},
    /// The memory of `io_refs` and `io_assigned`, and the per-name scratch
    /// of `inlineOne` and `fuseOne`, kept across their calls and grown with
    /// the program's names (`scratchOf`, #574): each of those calls used to
    /// take arrays as long as the whole program's names anew.
    io_refs_keep: []u32 = &.{},
    io_assigned_keep: []u32 = &.{},
    /// `checkCallGraph`'s unreached function nodes, over every solve.
    missed: std.ArrayList(Pts.NodeKey) = .empty,
    /// `inlineScan`'s place of each name in the module it counts, plus
    /// one: zero between modules.
    io_slot: []u32 = &.{},
    io_sites: []?CallSite = &.{},
    io_flags: []bool = &.{},
    io_fit: []bool = &.{},
    io_wanted: []bool = &.{},
    /// `preorder`'s answers, per top-level statement, with the `Mod.epoch`
    /// each is of.
    preorders: KeyMap(NodeRef, KeptNodes) = .empty,
    /// `nameScan`'s answers, per top-level statement, and its scratch.
    name_scans: KeyMap(NodeRef, *NameScan) = .empty,
    ns_slot: []u32 = &.{},
    /// `sameFirstNames`' columns, by whole-program name.
    first_stamp: []u32 = &.{},
    first_name: []u32 = &.{},
    first_epoch: u32 = 0,
    /// `scanOf`'s answers, per function, with the `Mod.version` each is of.
    body_scans: KeyMap(NodeRef, KeptScan) = .empty,
    /// `returnsMade` of a function, kept while its module stands (`fuseOne`).
    fuse_made: KeyMap(NodeRef, struct { version: u32, made: bool }) = .empty,
    /// The rewrite's own walks' dependencies (`rewrite`, `stale`), which the
    /// combined solver leaves (`solve`): every top-level statement in order;
    /// those a change woke; the one a solve's constraint is of (`none`
    /// outside one) and its number; and per whole-program name and per
    /// site, the statements that read it.
    w_stmts: std.ArrayList(WorkStmt) = .empty,
    w_dirty: std.DynamicBitSetUnmanaged = .{},
    w_cur: u32 = none,
    w_walk: u32 = 0,
    w_deps: std.ArrayList(WorkDep) = .empty,
    g_deps: []u32 = &.{},
    g_seen: []u32 = &.{},
    site_deps: []u32 = &.{},
    site_seen: []u32 = &.{},
    /// The combined solver while it solves (`solve`): what `fieldGet` and
    /// `retGet` register their reads with.
    solver: ?*Solver = null,
    /// The solve's columns and pools and the rewrite's dependency lists,
    /// of one solve: emptied with `.keep_all` when the next starts, so a
    /// solve lands on the pages the last one touched, whether or not fact
    /// 3 solved in between (`Pts.tmp` is emptied only when it does).
    solve_tmp: Arena = .init(std.heap.page_allocator),

    const KeptScan = struct { epoch: u64, scan: ?*const BodyScan };
    const KeptNodes = struct { epoch: u64, nodes: []const Index };
    const WorkStmt = struct { module: u32, stmt: Index };
    const WorkDep = struct { stmt: u32, next: u32 };
    const Declined = struct { g: u32, lit: Lit, v: Lat, module: u32, top: Index, node: Index, object_position: bool };
    const SiteProp = struct { site: u32, prop: u32 };
    const NodeRef = struct { module: u32, node: u32 };
    const KeptDrop = struct { site: u32, module: u32, top: Index, gone: []const bool, names: []const NameIndex };

    /// The join of the lattice: a literal and nonnull, or two different
    /// literals, meet at nonnull when no side is `null` or `undefined`.
    inline fn join(s: *Spec, a: Lat, b: Lat) Lat {
        if (a.state == .bot) return b;
        if (b.state == .bot) return a;
        if (a.state == .lit and b.state == .lit and a.lit == b.lit) return a;
        const truth = s.truthOf(a).join(s.truthOf(b));
        if (a.state == .top or b.state == .top) return .{ .state = .top, .truth = truth };
        if (s.maybeNullish(a) or s.maybeNullish(b)) return .{ .state = .top, .truth = truth };
        return .{ .state = .nonnull, .truth = truth };
    }

    /// Whether `v` is always truthy, always falsy, or either (`Lat`).
    inline fn truthOf(s: *Spec, v: Lat) Lat.Truth {
        return if (v.state == .lit) s.lit_truth.items[v.lit] else v.truth;
    }

    inline fn maybeNullish(s: *Spec, v: Lat) bool {
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
    /// when it is neither `null` nor `undefined`, and its truthiness.
    fn demote(s: *Spec, v: Lat) Lat {
        return switch (v.state) {
            .lit => .{ .state = if (s.maybeNullish(v)) .top else .nonnull, .truth = s.truthOf(v) },
            else => v,
        };
    }

    /// A walk's stack, from `stacks`: each walk of the IR keeps one, and
    /// what one grew to is kept for the next instead of grown again.
    fn takeStack(s: *Spec) Allocator.Error!std.ArrayList(Index) {
        s.stacks_out += 1;
        // `ArrayList`'s own calls, written out: Zig's backend inlines none
        // of them, and this runs once per walk.
        const left = s.stacks.items.len;
        if (s.stacks.capacity < left + s.stacks_out) try s.stacks.ensureTotalCapacity(s.arena, left + s.stacks_out);
        if (left == 0) return .empty;
        s.stacks.items.len = left - 1;
        var stack = s.stacks.items.ptr[left - 1];
        stack.items.len = 0;
        return stack;
    }

    fn giveStack(s: *Spec, stack: *std.ArrayList(Index)) void {
        s.stacks_out -= 1;
        const at = s.stacks.items.len;
        s.stacks.items.len = at + 1;
        s.stacks.items[at] = stack.*;
    }

    /// Join `v` into `slot`; true when that changed it.
    fn joinInto(s: *Spec, slot: *Lat, v: Lat) bool {
        const joined = s.join(slot.*, v);
        if (!joined.eql(slot.*)) {
            slot.* = joined;
            s.changed = true;
            return true;
        }
        return false;
    }

    /// `v` joins property `prop` of site `site` (facts 4 and 5), in fact 3's
    /// own cell of it. A property fact 3 has no `Prop` for is one no read
    /// of facts 4 and 5 asks of (`propValue` and `tagValue` find the `Prop`
    /// first), so the write has nowhere to go.
    fn joinProp(s: *Spec, site: u32, prop: u32, v: Lat) Allocator.Error!void {
        if (prop == none) return;
        const pr = s.pts.propMut(site, prop) orelse return;
        var moved = !pr.lat_made;
        if (!pr.lat_made and v.state != .bot) s.changed = true;
        pr.lat_made = true;
        if (s.joinInto(&pr.lat, v)) moved = true;
        if (moved) s.siteChanged(site);
    }

    /// What is known of property `prop` of site `site` (facts 4 and 5):
    /// null when no write has reached it. Inside the combined solver it is
    /// the field's cell, and the constraint reading it is woken when it
    /// changes (`Solver.reads`).
    inline fn fieldGet(s: *Spec, site: u32, prop: u32) Allocator.Error!?Lat {
        const pr = s.pts.propMut(site, prop) orelse return null;
        if (s.solver) |sv| try sv.reads(&pr.lat_readers);
        return if (pr.lat_made) pr.lat else null;
    }

    /// What function `ref` may return (fact 5), as `fieldGet`.
    inline fn retGet(s: *Spec, ref: NodeRef) Allocator.Error!?Lat {
        const site = s.pts.siteAt(ref.module, @fromBackingInt(@intCast(ref.node))) orelse return null;
        const st = &s.pts.sites.items[site];
        if (s.solver) |sv| try sv.reads(&st.ret_readers);
        return if (st.ret_made) st.ret_lat else null;
    }

    /// `v` joins what the function the walk is in returns, in its site's
    /// cell (`Pts.Site.ret_lat`). A function fact 3 made no site for is
    /// one no call reads the return of (`callValue` reads a site's).
    fn joinRet(s: *Spec, v: Lat) Allocator.Error!void {
        const f = s.cur_fn orelse return;
        const site = s.pts.siteAt(f.module, @fromBackingInt(@intCast(f.node))) orelse return;
        const st = &s.pts.sites.items[site];
        var moved = !st.ret_made;
        if (!st.ret_made and v.state != .bot) s.changed = true;
        st.ret_made = true;
        if (s.joinInto(&st.ret_lat, v)) moved = true;
        if (moved) {
            s.siteChanged(site);
        }
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
                .extra = .{ .items = @constCast(ir.extra), .capacity = ir.extra.len, .pointer_stability = .{} },
                .string_bytes = .{ .items = @constCast(ir.string_bytes), .capacity = ir.string_bytes.len, .pointer_stability = .{} },
                .names = .{ .items = @constCast(ir.names), .capacity = ir.names.len, .pointer_stability = .{} },
                .node_keys = .{ .items = @constCast(ir.node_keys), .capacity = ir.node_keys.len, .pointer_stability = .{} },
                .name_key = .{ .items = @constCast(ir.name_key), .capacity = ir.name_key.len, .pointer_stability = .{} },
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
            // A node no walk reached is anything, never what the memory
            // held (as `grow` fills a copied node's).
            @memset(m.memo, .top);
            @memset(m.lit_of, none);
        }
        var s: Spec = .{
            .gpa = gpa,
            .arena = arena,
            .in = in,
            .mods = mods,
            .decl = try arena.alloc(?Decl, in.globals),
            .escaped = try arena.alloc(bool, in.globals),
            .assigned = try arena.alloc(bool, in.globals),
            .reads = try arena.alloc(u32, in.globals),
            .globals = in.globals,
            .copied = try arena.alloc(bool, in.globals),
            .copied_modules = try arena.alloc(bool, in.modules.len),
        };
        @memset(s.copied, false);
        @memset(s.copied_modules, false);
        // Room for every literal the program spells: the table is filled
        // once, and growing it rehashed every key it held.
        var spelled: u32 = 0;
        for (mods) |*m| for (m.ir.nodes.items(.tag)) |t| switch (t) {
            .number, .string => spelled += 1,
            else => {},
        };
        try s.lit_ids.ensureTotalCapacity(arena, spelled + 8);
        return s;
    }

    /// One solve, read once by one rewrite (`backend.md` §9, *The combined
    /// solver*); then what no longer has a reference goes (slice 2).
    fn rounds(s: *Spec) Allocator.Error!void {
        if (!try s.analyse()) return;
        _ = try s.rewrite();
        _ = try s.prune();
        // A key nothing left reads goes from its literal (fact 3), and
        // what its value named may go with it.
        if (try s.dropUnreadKeys()) _ = try s.prune();
    }

    /// Every key of an object literal that no read the rewrite and the
    /// prune left reaches, whose value does nothing (`dropKeys`), gone. Only
    /// a key fact 3 saw read can be one: the others the patch dropped
    /// already.
    fn dropUnreadKeys(s: *Spec) Allocator.Error!bool {
        if (!s.pts.ok) return false;
        // The keys that may have lost every read, by property id, and the
        // sites holding one.
        const asked = try s.arena.alloc(bool, s.in.props);
        @memset(asked, false);
        var sites: std.ArrayList(u32) = .empty;
        for (s.pts.sites.items, 0..) |*st, i| {
            if (st.kind != .object or st.escaped or st.all_read) continue;
            var any = false;
            for (st.props.items) |*pr| {
                pr.live_read = false;
                if (!pr.read or pr.id >= asked.len or s.pts.hostImplicit(pr.id)) continue;
                asked[pr.id] = true;
                any = true;
            }
            if (any) try sites.append(s.arena, @intCast(i));
        }
        if (sites.items.len == 0) return false;
        try s.liveKeys(asked);
        s.live_keys = true;
        defer s.live_keys = false;
        var any = false;
        const saved_top = s.cur_top;
        defer s.cur_top = saved_top;
        s.cur_top = none_index;
        for (sites.items) |site| {
            const st = &s.pts.sites.items[site];
            const lost = for (st.props.items) |pr| {
                if (pr.read and !pr.live_read and pr.id < asked.len and asked[pr.id] and !s.id_read[pr.id]) break true;
            } else false;
            if (!lost) continue;
            const m = &s.mods[st.module];
            if (st.node.int() >= m.ir.nodes.len or m.ir.tag(st.node) != .object) continue;
            if (try s.dropKeys(m, st.node)) any = true;
        }
        return any;
    }

    /// Which of the keys `asked` names a read of the program, as it now
    /// stands, reaches: each member read, by fact 3's value of its object
    /// (`Pts.Prop.live_read`); a read whose object fact 3 never saw reaches
    /// its key on every object (`id_read`). An assignment's target is no
    /// read.
    fn liveKeys(s: *Spec, asked: []const bool) Allocator.Error!void {
        s.id_read = try growSlice(s.arena, bool, &.{}, s.in.props, false);
        for (s.mods, 0..) |*m, mi| {
            const ir = m.ir;
            const vals = s.pts.vals[mi];
            for (ir.extraSlice(ir.body, Index)) |top| {
                const nodes = try s.preorder(m, top);
                for (nodes) |node| if (ir.tag(node) == .assign_stmt or ir.tag(node) == .assign) {
                    const t: Index = @fromBackingInt(@intCast(ir.data(node).lhs));
                    if (ir.tag(t) == .member and t.int() < m.objects.bit_length) m.objects.set(t.int());
                };
                for (nodes) |node| {
                    if (ir.tag(node) != .member) continue;
                    if (node.int() < m.objects.bit_length and m.objects.isSet(node.int())) {
                        m.objects.unset(node.int());
                        continue;
                    }
                    const d = ir.data(node);
                    const id = s.pts.propId(m.index, @fromBackingInt(@intCast(d.rhs)));
                    if (id == none or id >= asked.len or !asked[id]) continue;
                    if (d.lhs >= vals.len) {
                        s.id_read[id] = true;
                        continue;
                    }
                    for (vals[d.lhs].sites) |site| if (s.pts.propMut(site, id)) |pr| {
                        pr.live_read = true;
                    };
                }
            }
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
            // A development build's columns are empty and own nothing.
            if (m.node_keys.capacity != 0) m.ir.node_keys = try m.node_keys.toOwnedSlice(s.gpa);
            if (m.name_key.capacity != 0) m.ir.name_key = try m.name_key.toOwnedSlice(s.gpa);
        }
    }

    // ---- Literals -----------------------------------------------------------

    fn intern(s: *Spec, lit: Lit) Allocator.Error!u32 {
        // A literal without bytes (`true`, `null`, …) is one per kind, and
        // asked for at every `return` and every test: its id is kept apart.
        const plain = lit.bytes.len == 0;
        if (plain) if (s.plain_ids[@backingInt(lit.kind)] != none) return s.plain_ids[@backingInt(lit.kind)];
        // One probe, by the literal itself: found, or the slot the new
        // literal takes, whose key is then made.
        const gop = try s.lit_ids.getOrPutAdapted(s.arena, lit, LitAdapter{});
        if (!gop.found_existing) {
            const key = try s.arena.alloc(u8, 1 + lit.bytes.len);
            key[0] = @backingInt(lit.kind);
            @memcpy(key[1..], lit.bytes);
            gop.key_ptr.* = key;
            gop.value_ptr.* = @intCast(s.lits.items.len);
            try s.lits.append(s.arena, .{ .kind = lit.kind, .bytes = key[1..] });
            try s.lit_truth.append(s.arena, switch (s.truthy(lit)) {
                .yes => .yes,
                .no => .no,
                .unknown => .unknown,
            });
        }
        if (plain) s.plain_ids[@backingInt(lit.kind)] = gop.value_ptr.*;
        return gop.value_ptr.*;
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

    /// `backend.md` §9, *Where it runs*, amended 2026-10-22 (#781): the
    /// structural passes once before the first solve, on a program no fact
    /// has read yet — small functions (calls of a name only: no fact 3
    /// resolves a callee), functions called once, constructor folding,
    /// scalar replacement and the `tidy` list modes. Every fact they ask
    /// answers as for a value nothing is known of: `Mod.memo` is ⊤ and fact
    /// 3 has not solved (`pts.ok` is false). A whole-program name is
    /// assigned when any `assign_stmt` of the program, live or not, names
    /// it, which is what the solve would conclude or more. What they write
    /// in, the first solve sees in its own context, so a program the passes
    /// after it find nothing more in is solved once.
    fn structureFirst(s: *Spec) Allocator.Error!void {
        if (s.in.fresh == .none) return;
        try s.declTable();
        for (s.mods) |*m| {
            const ir = m.ir;
            for (0..ir.nodes.len) |i| {
                const node: Index = @fromBackingInt(@intCast(i));
                if (ir.tag(node) != .assign_stmt) continue;
                const target: Index = @fromBackingInt(@intCast(ir.data(node).lhs));
                if (ir.tag(target) != .ident) continue;
                if (m.globalOf(@fromBackingInt(@intCast(ir.data(target).lhs)))) |g| s.assigned[g] = true;
            }
        }
        var changed = try s.inlineSmall();
        if (try s.inlineOnce()) changed = true;
        if (try s.constructors()) changed = true;
        if (try s.scalarReplace()) changed = true;
        s.list_mode = .tidy;
        if (try s.eachFunctionList()) changed = true;
        if (changed) {
            _ = try s.prune();
            try s.grow();
        }
    }

    /// `Input.check_call_graph` (#685): the function sites fact 3's call
    /// graph does not reach, kept by node for `poisonMissed`. The roots are
    /// what `backend.md` §9 *Executability* names: a site that escaped, one
    /// something other than a call runs (`odd_caller`), and one held under a
    /// key the pass does not know (`any`) or one the host reads unasked
    /// (`hostImplicit`). A call reaches the function sites its callee may
    /// be (`Pts.vals`) when it stands at a module's top level or in the body
    /// of a function reached. Arms are not asked: this is the graph alone.
    fn checkCallGraph(s: *Spec) Allocator.Error!void {
        const p = &s.pts;
        if (!p.ok) return;
        const reached = try s.arena.alloc(bool, p.sites.items.len);
        @memset(reached, false);
        for (p.sites.items, 0..) |st, i| {
            if (st.kind == .func and (st.escaped or st.odd_caller)) reached[i] = true;
            if (st.any != none) for ((try p.view(st.any)).sites) |h| {
                reached[h] = true;
            };
            for (st.props.items) |pr| if (p.hostImplicit(pr.id)) {
                if (pr.vals != none) for ((try p.view(pr.vals)).sites) |h| {
                    reached[h] = true;
                };
                if (pr.from != none) for ((try p.view(pr.from)).sites) |h| {
                    reached[h] = true;
                };
            };
        }
        // Every call, with the function site whose body holds it (`none`:
        // a module's top level).
        const Call = struct { module: u32, node: Index, within: u32 };
        var calls: std.ArrayList(Call) = .empty;
        const Item = struct { node: Index, within: u32 };
        var stack: std.ArrayList(Item) = .empty;
        var kids: std.ArrayList(Index) = .empty;
        for (s.mods, 0..) |*m, mi| {
            const ir = m.ir;
            for (ir.extraSlice(ir.body, Index)) |top| try stack.append(s.arena, .{ .node = top, .within = none });
            while (stack.pop()) |it| {
                var within_fn = it.within;
                const t = ir.tag(it.node);
                if (t == .arrow or t == .func_decl or t == .gen_decl) {
                    if (p.siteAt(@intCast(mi), it.node)) |site| within_fn = site;
                }
                if (t == .call or t == .new_call) try calls.append(s.arena, .{ .module = @intCast(mi), .node = it.node, .within = within_fn });
                kids.clearRetainingCapacity();
                if (t.isStatement() or t == .arrow) try pushChildren(s.arena, ir, it.node, &kids) else try ir.pushOperands(s.arena, &kids, it.node);
                for (kids.items) |k| if (k.int() < ir.nodes.len) try stack.append(s.arena, .{ .node = k, .within = within_fn });
            }
        }
        var grew = true;
        while (grew) {
            grew = false;
            for (calls.items) |c| {
                if (c.within != none and !reached[c.within]) continue;
                const callee = s.mods[c.module].ir.data(c.node).lhs;
                const vals = p.vals[c.module];
                if (callee >= vals.len) continue;
                for (vals[callee].sites) |site| if (p.sites.items[site].kind == .func and !reached[site]) {
                    reached[site] = true;
                    grew = true;
                };
            }
        }
        for (p.sites.items, 0..) |st, i| if (st.kind == .func and !reached[i]) {
            try s.missed.append(s.arena, .{ .module = st.module, .node = st.node.int() });
        };
    }

    /// `Input.check_call_graph`: every body `checkCallGraph` found
    /// unreached in any solve is `throw "…"`, so a run that calls one fails
    /// loudly instead of printing something else.
    fn poisonMissed(s: *Spec) Allocator.Error!void {
        const text = "beni: --check-call-graph: the release specialiser's call graph missed a function this program calls (#685)";
        for (s.missed.items) |k| {
            const m = &s.mods[k.module];
            const node: Index = @fromBackingInt(k.node);
            if (node.int() >= m.ir.nodes.len) continue;
            const rec: u32 = switch (m.ir.tag(node)) {
                .arrow => m.ir.data(node).lhs,
                .func_decl, .gen_decl => m.ir.data(node).rhs,
                else => continue,
            };
            const pos = m.ir.pos(node);
            const at = try m.addBytes(s.gpa, text);
            const message = try m.addNode(s.gpa, .string, pos, at, text.len);
            const thrown = try m.addNode(s.gpa, .throw_stmt, pos, message.int(), 0);
            const start = try m.append(s.gpa, &.{thrown.int()});
            m.extra.items[rec + 2] = start;
            m.extra.items[rec + 3] = start + 1;
            m.ir.extra = m.extra.items;
        }
    }

    /// Facts 1 and 2 to their fixpoint. False when the fixpoint was not
    /// reached, and the round must rewrite nothing.
    fn analyse(s: *Spec) Allocator.Error!bool {
        try s.declTable();
        // Fact 3 first: a read it proves `undefined` folds like a literal.
        s.stats.solves += 1;
        if (s.fact3Kept()) {
            s.stats.points_to_reused += 1;
            try s.applyKeptDrops();
            if (std.debug.runtime_safety) {
                var nodes: usize = 0;
                for (s.mods) |*m| nodes += m.ir.nodes.len;
                if (nodes <= Pts.max_checked_nodes) try s.pts.checkKept();
            }
        } else {
            try s.pts.analyse();
            try s.keepFact3();
        }
        if (s.in.check_call_graph) try s.checkCallGraph();
        // What follows is of this analysis alone, so it lives where the
        // fixpoint does, emptied by the next solve (`Pts.tmp`).
        s.spread_sites = try s.pts.run().alloc(bool, s.pts.sites.items.len);
        @memset(s.spread_sites, false);
        // Facts 1, 2, 4 and 5 by the combined solver (`backend.md` §9, *The
        // combined solver*, slice 4), which has no sweep to run out of.
        try s.solve();
        return true;
    }

    /// Every top-level declaration by its whole-program name, every
    /// top-level statement in order (which the sweeps walk), and the names
    /// the roots and a second declaration make escaped and assigned.
    fn declTable(s: *Spec) Allocator.Error!void {
        @memset(s.decl, null);
        @memset(s.escaped, false);
        @memset(s.assigned, false);
        @memset(s.reads, 0);
        s.params.clearRetainingCapacity();
        s.arg_effect.clearRetainingCapacity();
        var ri: usize = 0;
        while (eachRoot(s.in, ri)) |g| : (ri += 1) if (g < s.escaped.len) {
            s.escaped[g] = true;
        };
        // Every top-level declaration, by its whole-program name; and every
        // top-level statement, in order, which the sweeps walk.
        s.w_stmts.clearRetainingCapacity();
        for (s.mods, 0..) |*m, mi| {
            const ir = m.ir;
            for (ir.extraSlice(ir.body, Index)) |stmt| {
                const index: u32 = @intCast(s.w_stmts.items.len);
                try s.w_stmts.append(s.arena, .{ .module = @intCast(mi), .stmt = stmt });
                const d = ir.data(stmt);
                const n: NameIndex = switch (ir.tag(stmt)) {
                    .const_decl, .let_decl, .func_decl, .gen_decl => @fromBackingInt(@intCast(d.lhs)),
                    else => continue,
                };
                const g = m.globalOf(n) orelse continue;
                // Two declarations of one name: nothing is concluded about it.
                if (s.decl[g] != null) {
                    s.escaped[g] = true;
                    s.assigned[g] = true;
                    continue;
                }
                var decl: Decl = .{ .module = @intCast(mi), .stmt = stmt, .index = index };
                const record: ?ExtraIndex = switch (ir.tag(stmt)) {
                    .const_decl => if (ir.tag(@fromBackingInt(@intCast(d.rhs))) == .arrow and ir.data(@fromBackingInt(@intCast(d.rhs))).rhs == Node.arrow_plain)
                        @fromBackingInt(@intCast(ir.data(@fromBackingInt(@intCast(d.rhs))).lhs))
                    else
                        null,
                    .func_decl => @fromBackingInt(@intCast(d.rhs)),
                    else => null,
                };
                if (record) |r| {
                    const f = ir.extraData(r, JsIr.Func);
                    decl.func = r;
                    decl.params = @intCast(s.params.items.len);
                    decl.arity = f.params().len();
                    try s.params.appendNTimes(s.arena, .bot, decl.arity);
                    try s.arg_effect.appendNTimes(s.arena, false, decl.arity);
                }
                s.decl[g] = decl;
            }
        }
    }

    /// Whether `pts` is still the solve of the program as it stands (#575):
    /// it reached its fixpoint, definite initialisation was not capped, and
    /// since that solve no module made a change fact 3 reads (`Mod.fact3`)
    /// nor grew a node, a name or the whole-program names. Every change
    /// moves `Mod.fact3` but the one `fact3Neutral` licenses, so what is
    /// kept is what a solve would make, sites numbered alike: the walk
    /// meets the same nodes in the same order.
    fn fact3Kept(s: *Spec) bool {
        if (!s.pts_kept or s.globals != s.pts_kept_globals) return false;
        for (s.mods, s.pts_kept_nodes, s.pts_kept_names) |*m, nodes, names| {
            if (m.fact3 or m.ir.nodes.len != nodes or m.names.items.len != names) return false;
        }
        return true;
    }

    /// Fact 3 has just solved the program: what `fact3Kept` compares.
    fn keepFact3(s: *Spec) Allocator.Error!void {
        s.pts_kept = s.pts.ok and !s.pts.init_capped;
        if (s.pts_kept_nodes.len != s.mods.len) {
            s.pts_kept_nodes = try s.arena.alloc(usize, s.mods.len);
            s.pts_kept_names = try s.arena.alloc(usize, s.mods.len);
        }
        for (s.mods, s.pts_kept_nodes, s.pts_kept_names) |*m, *nodes, *names| {
            m.fact3 = false;
            nodes.* = m.ir.nodes.len;
            names.* = m.names.items.len;
        }
        s.pts_kept_globals = s.globals;
        s.kept_drops.clearRetainingCapacity();
        s.kept_args.clearRetainingCapacity();
    }

    /// Whether writing identifier `node` as literal `lit` (`patchLiteral`)
    /// leaves fact 3's least fixpoint as it is, so that the write need not
    /// move `Mod.fact3` (#575). Exactly when fact 3 makes of the literal
    /// what it made of the read, and reads nothing of the identifier but
    /// its value:
    ///
    /// - the read was the primitive alone — no object, no host value, not
    ///   `null` or `undefined` — which is what a number, a string, `true`
    ///   or `false` is (`Pts.literal_vals`). A guard narrows a read by
    ///   taking `null` and `undefined` off it, so one on this name narrowed
    ///   nothing, and the reads it guarded are what they were;
    /// - it is not the object of a read: fact 3 reads a name's property
    ///   through the name's load cell and field summary, and a guard's
    ///   chain starts at a name;
    /// - it is not the string `__proto__`, which as the key of a computed
    ///   write escapes the object (`Pts.indexMayAssignPrototype`).
    ///
    /// A type key on the node is no reason to refuse: fact 3 reads a node's
    /// key only where it makes a site (`siteOf`, `funcSite`), and a safety
    /// build asserts a keyed node is an object, an array or an arrow
    /// (`JsIr.nodeKey`), so an identifier's row, if any, is `wild`.
    ///
    /// Anything else a read of a name gives fact 3 — a copy edge from its
    /// var where a join of its value would do, a dependency — is cost, not
    /// a fact: the edge carries what the var holds, the primitive alone.
    /// A safety build checks the rule on every small program whose
    /// analysis keeps the state (`Pts.checkKept`).
    fn fact3Neutral(s: *Spec, m: *Mod, node: Index, lit: Lit, object_position: bool) bool {
        if (!s.pts.ok or object_position or m.ir.tag(node) != .ident) return false;
        switch (lit.kind) {
            .number, .true_lit, .false_lit => {},
            .string => if (std.mem.eql(u8, lit.bytes, prototype_assign)) return false,
            .null_lit, .undefined_lit, .name => return false,
        }
        const vals = s.pts.vals[m.index];
        if (node.int() >= vals.len) return false;
        const v = vals[node.int()];
        return !v.top and v.prim and !v.nul and !v.undef and v.sites.len == 0;
    }

    /// Whether fact 3's state can take the drop of `decl`'s parameters
    /// `gone` (`rewrite`) without a solve, and if so a record of it that
    /// `applyKeptDrops` spends when the next analysis keeps the state
    /// (#582). Asked before the parameter list is rewritten, of the state
    /// the rewrite reads. A solve of the program without them makes no var
    /// for them and joins nothing into one; what it keeps of the rest is
    /// the kept state's exactly when nothing else read them:
    ///
    /// - each one's var holds no object of the program and is not `top`:
    ///   no site escaped or was linked through it, so it fed no fact. A var
    ///   that holds only the primitive, `null` or `undefined` and that no
    ///   read reads is a dead end;
    /// - the var is the parameter's local of the declaration's statement,
    ///   and no identifier of that statement names the parameter any more
    ///   (each read was written as its literal, `fact3Neutral`, or there was
    ///   none). `rewrite` drops only a parameter declared once in the
    ///   statement, so no other function of it shares the local.
    ///
    /// The calls lose the arguments with the parameters (`keepArgs`).
    fn keepDrop(s: *Spec, m: *Mod, decl: Decl, gone: []const bool) Allocator.Error!bool {
        if (!s.pts_kept or !s.pts.ok) return false;
        const ir = m.ir;
        const node: Index = switch (ir.tag(decl.stmt)) {
            .const_decl => @fromBackingInt(@intCast(ir.data(decl.stmt).rhs)),
            .func_decl => decl.stmt,
            else => return false,
        };
        const site = s.pts.siteAt(m.index, node) orelse return false;
        const st = &s.pts.sites.items[site];
        if (st.kind != .func or st.params.len != gone.len) return false;
        const names = ir.extraSlice(ir.extraData(decl.func.?, JsIr.Func).params(), NameIndex);
        for (gone, names, st.params) |g, n, v| {
            if (!g) continue;
            const val = try s.pts.view(v);
            if (val.top or val.sites.len != 0) return false;
            if ((s.pts.findLocal(m.index, decl.stmt, n) orelse return false) != v) return false;
        }
        for (try s.preorder(m, decl.stmt)) |x| if (ir.tag(x) == .ident) {
            for (gone, names) |g, n| if (g and ir.data(x).lhs == n.int()) return false;
        };
        try s.kept_drops.append(s.arena, .{
            .site = site,
            .module = m.index,
            .top = decl.stmt,
            .gone = try s.arena.dupe(bool, gone),
            .names = try s.arena.dupe(NameIndex, names),
        });
        return true;
    }

    /// Whether fact 3's state can take a call's loss of the arguments
    /// `gone` of a function `keepDrop` admitted, and if so a record of each
    /// (#582): each is a literal or a name, a leaf whose value only joined
    /// the parameter that goes — no site, nothing marked read, no node
    /// below it. A solve walks it no more, so its node has the value of a
    /// node no walk reaches.
    fn keepArgs(s: *Spec, m: *Mod, args: []const u32, gone: []const bool) Allocator.Error!bool {
        for (args, gone) |a, g| {
            if (!g) continue;
            const tag = m.ir.tag(@fromBackingInt(@intCast(a)));
            if (!isLiteralTag(tag) and tag != .ident) return false;
        }
        for (args, gone) |a, g| if (g) try s.kept_args.append(s.arena, .{ .module = m.index, .node = a });
        return true;
    }

    /// The parameter drops the kept state takes (`keepDrop`, `keepArgs`):
    /// each function site's parameter list without them, their locals
    /// gone, and each dropped argument's node unreached (`Val.top_val`, as
    /// `Pts.reset` leaves a node no walk reaches). Their vars stay, fed by
    /// nothing a fact reads.
    fn applyKeptDrops(s: *Spec) Allocator.Error!void {
        const p = &s.pts;
        for (s.kept_drops.items) |k| {
            const st = &p.sites.items[k.site];
            var kept: std.ArrayList(Pts.VarId) = .empty;
            for (st.params, k.gone) |v, g| if (!g) try kept.append(s.arena, v);
            st.params = kept.items;
            for (k.names, k.gone) |n, g| if (g) {
                p.locals.remove(.{ .module = k.module, .top = k.top.int(), .name = n.int() });
                const row = p.name_top[k.module];
                if (n.int() < row.len and row[n.int()] == k.top.int()) row[n.int()] = none;
            };
        }
        for (s.kept_args.items) |a| p.vals[a.module][a.node] = Pts.Val.top_val;
        s.kept_drops.clearRetainingCapacity();
        s.kept_args.clearRetainingCapacity();
    }

    // ---- The combined solver (backend.md §9, slice 4) -------------------------

    /// Facts 1, 2, 4 and 5 by the combined solver (`Solver`): extract the
    /// modules that changed, merge, solve, and leave the facts where the
    /// rewrite reads them — `memo`, `params`, fact 3's sites' cells of
    /// fields and returns, the `escaped`, `assigned`, `reads`, `spread_sites`
    /// and `arg_effect` columns — with the statements' dependency lists
    /// (`g_deps`, `site_deps`) for the rewrite's own walks.
    fn solve(s: *Spec) Allocator.Error!void {
        try s.extractAll();
        s.solve_tmp.reset(.keep_all);
        // Fact 3's state may be the last analysis's (`fact3Kept`): its cells
        // of fields and returns start again from ⊥.
        for (s.pts.sites.items) |*st| {
            st.ret_lat = .bot;
            st.ret_made = false;
            st.ret_readers = none;
            for (st.props.items) |*pr| {
                pr.lat = .bot;
                pr.lat_made = false;
                pr.lat_readers = none;
            }
        }
        const a = s.solve_tmp.allocator();
        const mods = s.mods;
        // ---- The merge: cells and constraints by prefix sums, in module order.
        const cell_base = try a.alloc(u32, mods.len);
        const con_base = try a.alloc(u32, mods.len);
        const stmt_base = try a.alloc(u32, mods.len);
        const exec_base = try a.alloc(u32, mods.len);
        var cells: u32 = 0;
        var cons: u32 = 0;
        var stmts: u32 = 0;
        var execs: u32 = 0;
        for (mods, cell_base, con_base, stmt_base, exec_base) |*m, *cb, *kb, *sb, *eb| {
            eb.* = execs;
            execs += @intCast(m.ex.execs.len);
            cb.* = cells;
            kb.* = cons;
            sb.* = stmts;
            cells += m.ex.cells();
            cons += @intCast(m.ex.code.len);
            stmts += @intCast(m.ex.stmts.len);
        }
        std.debug.assert(stmts == s.w_stmts.items.len);
        const param_base = cells;
        const params: u32 = @intCast(s.params.items.len);
        cells += params;
        var sv: Solver = .{
            .s = s,
            .cell_base = cell_base,
            .con_base = con_base,
            .stmt_base = stmt_base,
            .param_base = param_base,
            .lat = try a.alloc(Lat, cells),
            .aux = try a.alloc(u32, cons),
            .prd_off = try a.alloc(u32, params + 1),
            .prd = &.{},
            .queued = try .initEmpty(a, cons),
            .exec_base = exec_base,
            .on = try .initEmpty(a, execs),
            .site_exec = try a.alloc(u32, s.pts.sites.items.len),
        };
        @memset(sv.site_exec, none);
        @memset(sv.lat, .bot);
        @memset(sv.aux, none);
        // The rewrite's dependency lists, as `sweeps` sets them up.
        s.w_dirty = try .initEmpty(a, s.w_stmts.items.len);
        s.w_deps.clearRetainingCapacity();
        s.g_deps = try growSlice(a, u32, &.{}, s.globals, none);
        s.g_seen = try growSlice(a, u32, &.{}, s.globals, 0);
        s.site_deps = try growSlice(a, u32, &.{}, s.pts.sites.items.len, none);
        s.site_seen = try growSlice(a, u32, &.{}, s.pts.sites.items.len, 0);
        // ---- What the counts say, for the whole program at once: every read
        // of a name counts, one that is not a callee escapes it, an
        // assignment assigns it.
        // Of the statements that run: a declaration nothing live refers to
        // goes (`liveStatements`), and what it reads and assigns with it.
        const live = try s.liveStatements(a);
        for (mods, stmt_base) |*m, sb| {
            var reads_from: u32 = 0;
            var assigns_from: u32 = 0;
            for (m.ex.stmts, 0..) |st, k| {
                defer reads_from = st.reads;
                defer assigns_from = st.assigns;
                if (!live[sb + k]) continue;
                for (m.ex.reads[reads_from..st.reads]) |r| {
                    s.reads[r.g] +|= 1;
                    if (!r.callee) s.escaped[r.g] = true;
                }
                for (m.ex.assigns[assigns_from..st.assigns]) |g| s.assigned[g] = true;
            }
        }
        // A call of a function `Spec` tracks with another arity escapes it.
        for (mods) |*m| {
            const x = &m.ex;
            for (x.code, x.a) |code, at| if (code.op == .call) {
                const g = x.pool[at];
                if (g == none or g >= s.decl.len) continue;
                const decl = s.decl[g] orelse continue;
                if (decl.func != null and x.pool[at + 1] != decl.arity) s.escaped[g] = true;
            };
        }
        // ---- Per constraint, what the merge decides of it, in module order:
        // the values fixed for the solve (literals, interned in this order,
        // and names), parameters' cells, calls' parameters and their
        // arguments' effects, spreads.
        const gval = try a.alloc(u32, s.globals);
        @memset(gval, none);
        // The names' cells: each name whose value is its initialiser's
        // reads that node's cell (`nameInit`).
        s.name_solved = try growSlice(s.arena, u32, &.{}, s.globals, none);
        const name_src = try a.alloc(u32, s.globals);
        @memset(name_src, none);
        var name_of: std.ArrayList(Solver.NameSrc) = .empty;
        for (0..s.globals) |g| if (s.nameInit(@intCast(g))) |ini| {
            if (ini.node.int() >= mods[ini.module].ex.nodes) continue;
            name_src[g] = cell_base[ini.module] + ini.node.int();
            try name_of.append(a, .{ .cell = name_src[g], .g = @intCast(g) });
        };
        std.mem.sortUnstable(Solver.NameSrc, name_of.items, {}, struct {
            fn less(_: void, x: Solver.NameSrc, y: Solver.NameSrc) bool {
                return x.cell < y.cell;
            }
        }.less);
        sv.name_of = name_of.items;
        sv.name_src = try .initEmpty(a, cells);
        for (name_of.items) |n| sv.name_src.set(n.cell);
        sv.nrd_off = try a.alloc(u32, s.globals + 1);
        @memset(sv.nrd_off, 0);
        @memset(sv.prd_off, 0);
        for (mods, 0..) |*m, mi_usize| {
            const mi: u32 = @intCast(mi_usize);
            const x = &m.ex;
            const ir = m.ir;
            for (x.stmts, 0..) |st, k| {
                const w = stmt_base[mi] + @as(u32, @intCast(k));
                const first: u32 = if (k == 0) 0 else x.stmts[k - 1].cons;
                // The statement's own function, when it is the one `Spec`
                // tracks (`prepareTop`): its parameters' cells.
                const tracked: ?Decl = tracked: {
                    switch (ir.tag(st.node)) {
                        .const_decl, .func_decl => {},
                        else => break :tracked null,
                    }
                    const g = m.globalOf(@fromBackingInt(@intCast(ir.data(st.node).lhs))) orelse break :tracked null;
                    const d = s.decl[g] orelse break :tracked null;
                    if (d.func == null or d.module != mi or d.stmt != st.node) break :tracked null;
                    break :tracked d;
                };
                // `readsName`: the names the statement reads, and the
                // function whose parameters it reads.
                const reads_from: u32 = if (k == 0) 0 else x.stmts[k - 1].reads;
                for (x.reads[reads_from..st.reads]) |r| try s.depOnName(r.g, w);
                if (tracked) |d| if (st.param_reads) try s.depOnName(s.globalOfDecl(d), w);
                s.cur_top = st.node;
                for (first..st.cons) |j| {
                    const con = con_base[mi] + @as(u32, @intCast(j));
                    switch (x.code[j].op) {
                        .constant => sv.lat[cell_base[mi] + x.node[j]] = if (x.a[j] == fixed_object) .object else .top,
                        // A literal node's id is looked up once (`Mod.lit_of`).
                        .literal => sv.lat[cell_base[mi] + x.node[j]] = try s.literalValue(m, x.nodeAt(j)),
                        .global => {
                            const g = x.a[j];
                            // A name whose value is its initialiser's reads
                            // that cell (`nameInit`), and is woken with it.
                            if (g < name_src.len and name_src[g] != none) {
                                sv.aux[con] = name_src[g];
                                sv.nrd_off[g + 1] += 1;
                                continue;
                            }
                            if (gval[g] == none) gval[g] = @bitCast(s.globalValue(g));
                            sv.lat[cell_base[mi] + x.node[j]] = @bitCast(gval[g]);
                        },
                        .param => if (tracked) |d| {
                            if (!s.escaped[s.globalOfDecl(d)]) {
                                const p = d.params + x.a[j];
                                sv.aux[con] = param_base + p;
                                sv.prd_off[p + 1] += 1;
                            }
                        },
                        .call => {
                            const at = x.a[j];
                            const g = x.pool[at];
                            if (g == none or g >= s.decl.len) continue;
                            const decl = s.decl[g] orelse continue;
                            if (decl.func == null or x.pool[at + 1] != decl.arity) continue;
                            sv.aux[con] = decl.params;
                            for (x.pool[at + 2 ..][0..decl.arity], 0..) |c, i| {
                                const effect = &s.arg_effect.items[decl.params + i];
                                if (!effect.* and !try s.effectFree(m, @fromBackingInt(@intCast(x.nodeOf(c))))) effect.* = true;
                            }
                        },
                        .object => if (x.code[j].flag) if (s.pts.siteAt(mi, x.nodeAt(j))) |site| {
                            if (site < s.spread_sites.len) s.spread_sites[site] = true;
                        },
                        else => {},
                    }
                }
            }
        }
        // ---- The names' readers, by counting sort.
        for (1..sv.nrd_off.len) |i| sv.nrd_off[i] += sv.nrd_off[i - 1];
        sv.nrd = try a.alloc(u32, sv.nrd_off[s.globals]);
        {
            const nfill = try a.dupe(u32, sv.nrd_off[0..s.globals]);
            for (mods, con_base) |*m, base| for (m.ex.code, m.ex.a, 0..) |code, g, j| if (code.op == .global) {
                if (g >= name_src.len or name_src[g] == none) continue;
                sv.nrd[nfill[g]] = base + @as(u32, @intCast(j));
                nfill[g] += 1;
            };
        }
        // ---- The parameters' readers, by counting sort.
        for (1..sv.prd_off.len) |i| sv.prd_off[i] += sv.prd_off[i - 1];
        sv.prd = try a.alloc(u32, sv.prd_off[params]);
        const fill = try a.dupe(u32, sv.prd_off[0..params]);
        for (mods, con_base) |*m, base| for (m.ex.code, 0..) |code, j| if (code.op == .param) {
            const con = base + @as(u32, @intCast(j));
            if (sv.aux[con] == none) continue;
            const p = sv.aux[con] - param_base;
            sv.prd[fill[p]] = con;
            fill[p] += 1;
        };
        // ---- Executability's roots (*Executability*, amended for #685, the
        // completeness argument): every module's top level; a function body
        // fact 3 made no site for, whose site escaped, that something other
        // than a call runs (`new`, the entry file: `odd_caller`), or that is
        // held under a key the host reads unasked or one the pass does not
        // know. Any other body runs when an executable call reaches its site
        // (`calls`).
        // A top-level statement runs, with every body in it, unless it is a
        // declaration nothing live refers to, which `prune` drops after the
        // rewrite: what refers to it can only shrink (*Reading off*).
        for (mods, exec_base, stmt_base) |*m, eb, sb| {
            sv.on.set(eb);
            var from: u32 = 1;
            for (m.ex.stmts, 0..) |st, k| {
                defer from = st.execs;
                if (!live[sb + k]) continue;
                for (m.ex.execs[from..st.execs], from..) |e, i| switch (e.kind) {
                    .top => sv.on.set(eb + @as(u32, @intCast(i))),
                    .body => {
                        const site = if (s.pts.ok) s.pts.siteAt(m.index, @fromBackingInt(@intCast(e.a))) else null;
                        const fs = site orelse {
                            sv.on.set(eb + @as(u32, @intCast(i)));
                            continue;
                        };
                        sv.site_exec[fs] = @intCast(i);
                        const st_fn = &s.pts.sites.items[fs];
                        if (st_fn.escaped or st_fn.odd_caller) sv.on.set(eb + @as(u32, @intCast(i)));
                    },
                    else => {},
                };
            }
        }
        if (s.pts.ok) {
            var si: usize = 0;
            while (si < s.pts.sites.items.len) : (si += 1) {
                const st = &s.pts.sites.items[si];
                if (st.any != none) try sv.held(try s.pts.view(st.any));
                for (st.props.items) |pr| if (s.pts.hostImplicit(pr.id)) {
                    if (pr.vals != none) try sv.held(try s.pts.view(pr.vals));
                    if (pr.from != none) try sv.held(try s.pts.view(pr.from));
                };
            }
        }
        // ---- The solve.
        s.solver = &sv;
        defer s.solver = null;
        try sv.solve();
        s.w_cur = none;
        s.stats.solve_constraints += cons;
        s.stats.solve_evaluations += sv.evaluations;
        // ---- The facts, where the rewrite reads them. A node's value is its
        // last occurrence's, as a walk leaves `memo`; a conditional fact 5
        // decides is read off it (`decidedBranch`). The fields and returns
        // are fact 3's sites' own cells already.
        for (mods, 0..) |*m, mi| {
            const x = &m.ex;
            for (x.code, x.node) |code, cell| {
                if (!code.ofNode()) continue;
                m.memo[x.nodeOf(cell)] = sv.lat[cell_base[mi] + cell];
            }
        }
        @memcpy(s.params.items, sv.lat[param_base..]);
        for (name_src, s.name_solved) |src, *out| if (src != none) {
            out.* = @bitCast(sv.lat[src]);
        };
    }

    /// Per top-level statement, in `w_stmts`' order: whether it is live as
    /// `prune` sees it — not a declaration it may drop, or one a live
    /// statement or a root refers to.
    fn liveStatements(s: *Spec, a: Allocator) Allocator.Error![]bool {
        const referenced = try a.alloc(bool, s.globals);
        @memset(referenced, false);
        const live = try a.alloc(bool, s.globals);
        @memset(live, false);
        var work: std.ArrayList(u32) = .empty;
        var ri: usize = 0;
        while (eachRoot(s.in, ri)) |g| : (ri += 1) if (g < referenced.len) {
            referenced[g] = true;
            try work.append(a, g);
        };
        // Per statement, the names it reads and assigns, as its extraction
        // recorded them (`Extract.reads`, `Extract.assigns`): the names
        // `references` finds by walking it.
        const where_m = try a.alloc(u32, s.globals);
        @memset(where_m, none);
        const where_k = try a.alloc(u32, s.globals);
        for (s.mods, 0..) |*m, mi| for (m.ex.stmts, 0..) |st, k| {
            if (s.candidate(m, st.node)) |g| {
                where_m[g] = @intCast(mi);
                where_k[g] = @intCast(k);
                continue;
            }
            try s.extractedRefs(m, k, referenced, &work, a);
        };
        while (work.pop()) |g| {
            if (g >= where_m.len or live[g]) continue;
            live[g] = true;
            if (where_m[g] == none) continue;
            try s.extractedRefs(&s.mods[where_m[g]], where_k[g], referenced, &work, a);
        }
        var out: std.ArrayList(bool) = .empty;
        for (s.mods) |*m| for (m.ex.stmts) |st| {
            const g = s.candidate(m, st.node);
            try out.append(a, if (g) |x| live[x] else true);
        };
        std.debug.assert(out.items.len == s.w_stmts.items.len);
        return out.items;
    }

    fn extractedRefs(s: *Spec, m: *Mod, k: usize, referenced: []bool, work: *std.ArrayList(u32), a: Allocator) Allocator.Error!void {
        _ = s;
        const x = &m.ex;
        const reads_from: u32 = if (k == 0) 0 else x.stmts[k - 1].reads;
        const assigns_from: u32 = if (k == 0) 0 else x.stmts[k - 1].assigns;
        for (x.reads[reads_from..x.stmts[k].reads]) |r| if (r.g < referenced.len and !referenced[r.g]) {
            referenced[r.g] = true;
            try work.append(a, r.g);
        };
        for (x.assigns[assigns_from..x.stmts[k].assigns]) |g| if (g < referenced.len and !referenced[g]) {
            referenced[g] = true;
            try work.append(a, g);
        };
    }

    /// Statement `w` reads whole-program name `g` (`readsName`).
    fn depOnName(s: *Spec, g: u32, w: u32) Allocator.Error!void {
        if (g >= s.g_deps.len or s.g_seen[g] == w + 1) return;
        s.g_seen[g] = w + 1;
        const at = s.w_deps.items.len;
        try s.w_deps.append(s.arena, .{ .stmt = w, .next = s.g_deps[g] });
        s.g_deps[g] = @intCast(at);
    }

    /// Every module whose constraints its last extraction no longer holds
    /// extracted again (`Extractor`), on the workers when there are several.
    fn extractAll(s: *Spec) Allocator.Error!void {
        var stale: std.ArrayList(u32) = .empty;
        for (s.mods, 0..) |*m, mi| {
            if (m.ex.epoch == m.epoch and m.ex.names == m.stamp.len and m.ex.nodes == m.ir.nodes.len) {
                s.stats.solve_kept += 1;
                continue;
            }
            try stale.append(s.arena, @intCast(mi));
        }
        s.stats.solve_extracted += stale.items.len;
        if (stale.items.len == 0) return;
        const Task = struct {
            s: *Spec,
            fn run(t: *const @This(), scratch: Allocator, mi: u32) Allocator.Error!void {
                const m = &t.s.mods[mi];
                try Extractor.run(scratch, m, false, &m.ex);
            }
        };
        const task: Task = .{ .s = s };
        var scratch: Arena = .init(s.gpa);
        defer scratch.deinit();
        if (s.in.parallel != null and stale.items.len > 1) {
            const par = s.in.parallel.?;
            var work: usize = 0;
            for (stale.items) |mi| work += s.mods[mi].ir.nodes.len;
            try par.run(par.context, stale.items, work, &task, struct {
                fn call(cx: *const anyopaque, into: Allocator, item: u32) Allocator.Error!void {
                    const t: *const Task = @ptrCast(@alignCast(cx));
                    return t.run(into, item);
                }
            }.call);
        } else for (stale.items) |mi| {
            scratch.reset(.retain_capacity);
            try task.run(scratch.allocator(), mi);
        }
        var program_nodes: usize = 0;
        for (s.mods) |*m| program_nodes += m.ir.nodes.len;
        for (stale.items) |mi| {
            const m = &s.mods[mi];
            s.stats.solve_stmts_walked += m.ex.walked;
            s.stats.solve_stmts_kept += m.ex.reused;
            // A safety build checks what a module kept against a walk of
            // all of it, in a program of at most `max_solve_checked_nodes`.
            if (std.debug.runtime_safety and m.ex.reused != 0 and program_nodes <= max_solve_checked_nodes) {
                scratch.reset(.retain_capacity);
                var fresh: Extract = .{};
                defer fresh.deinit();
                try Extractor.run(scratch.allocator(), m, true, &fresh);
                m.ex.expectSame(&fresh, mi);
            }
        }
    }

    /// Every module's constraints given back (`run`'s end).
    fn freeExtracts(s: *Spec) void {
        for (s.mods) |*m| {
            m.ex.deinit();
            m.pex.deinit();
        }
        s.solve_tmp.deinit();
    }

    /// The statement being walked reads whole-program name `g`'s flags,
    /// `escaped` and `assigned`.
    inline fn readsName(s: *Spec, g: u32) Allocator.Error!void {
        if (s.w_cur == none or g >= s.g_deps.len or s.g_seen[g] == s.w_walk) return;
        s.g_seen[g] = s.w_walk;
        s.g_deps[g] = try s.addWorkDep(s.g_deps[g]);
    }

    /// The statement being walked reads what is known of site `site`: its
    /// properties' values (`Pts.Prop.lat`), what it returns, and
    /// whether a spread copies from it.
    inline fn readsSite(s: *Spec, site: u32) Allocator.Error!void {
        if (s.w_cur == none or site >= s.site_deps.len or s.site_seen[site] == s.w_walk) return;
        s.site_seen[site] = s.w_walk;
        s.site_deps[site] = try s.addWorkDep(s.site_deps[site]);
    }

    fn addWorkDep(s: *Spec, head: u32) Allocator.Error!u32 {
        const at = s.w_deps.items.len;
        // `append`, written out: Zig's own backend inlines none of its calls.
        if (s.w_deps.capacity == at) try s.w_deps.ensureUnusedCapacity(s.arena, 1);
        s.w_deps.items.len = at + 1;
        s.w_deps.items.ptr[at] = .{ .stmt = s.w_cur, .next = head };
        return @intCast(at);
    }

    /// Every statement on list `head` is walked again.
    fn wakeList(s: *Spec, head: u32) void {
        var d = head;
        while (d != none) {
            const dep = s.w_deps.items[d];
            if (dep.stmt < s.w_dirty.bit_length) s.w_dirty.set(dep.stmt);
            d = dep.next;
        }
    }

    /// `g`'s `escaped` or `assigned` became true. Neither counts as a
    /// change: a sweep that changed nothing else is the last, as it was.
    fn nameChanged(s: *Spec, g: u32) void {
        if (g >= s.g_deps.len) return;
        s.wakeList(s.g_deps[g]);
        s.g_deps[g] = none;
        s.g_seen[g] = 0;
    }

    fn siteChanged(s: *Spec, site: u32) void {
        if (site >= s.site_deps.len) return;
        s.wakeList(s.site_deps[site]);
        s.site_deps[site] = none;
        s.site_seen[site] = 0;
    }

    fn setEscaped(s: *Spec, g: u32) void {
        if (s.escaped[g]) return;
        s.escaped[g] = true;
        s.nameChanged(g);
    }

    fn setAssigned(s: *Spec, g: u32) void {
        if (s.assigned[g]) return;
        s.assigned[g] = true;
        s.nameChanged(g);
    }

    /// One top-level statement: its names counted, then its values.
    fn walkTop(s: *Spec, m: *Mod, mi: u32, stmt: Index) Allocator.Error!void {
        try s.prepareTop(m, mi, stmt);
        try s.evalStmt(m, mi, stmt);
    }

    /// `walkTop` short of evaluating: the statement's names counted, which
    /// is all `rewrite` needs of a statement whose values in `memo` are
    /// still what a walk would make.
    fn prepareTop(s: *Spec, m: *Mod, mi: u32, stmt: Index) Allocator.Error!void {
        const ir = m.ir;
        s.current += 1;
        s.top_func = null;
        s.cur_top = stmt;
        // The declaration's own function, whose parameters are tracked.
        switch (ir.tag(stmt)) {
            .const_decl, .func_decl => if (m.globalOf(@fromBackingInt(@intCast(ir.data(stmt).lhs)))) |g| {
                if (s.decl[g]) |d| if (d.func != null and d.module == mi and d.stmt == stmt) {
                    s.top_func = d;
                };
            },
            else => {},
        }
        try s.countTop(m, stmt);
        if (s.top_func) |d| {
            const f = ir.extraData(d.func.?, JsIr.Func);
            for (ir.extraSlice(f.params(), NameIndex), 0..) |n, i| {
                const at = n.unwrap() orelse continue;
                if (m.decls[at] == 1) m.param[at] = @intCast(i);
            }
        }
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
                s.declare(m, @fromBackingInt(@intCast(d.lhs)));
                try s.countExpr(m, @fromBackingInt(@intCast(d.rhs)));
            },
            .let_decl => {
                s.declare(m, @fromBackingInt(@intCast(d.lhs)));
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| try s.countExpr(m, v);
            },
            .func_decl, .gen_decl => {
                s.declare(m, @fromBackingInt(@intCast(d.lhs)));
                try s.countFunc(m, @fromBackingInt(@intCast(d.rhs)));
            },
            .assign_stmt => {
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                if (ir.tag(target) == .ident) {
                    const n: NameIndex = @fromBackingInt(@intCast(ir.data(target).lhs));
                    if (m.globalOf(n)) |g| {
                        s.setAssigned(g);
                    } else if (n.unwrap()) |i| if (i < m.stamp.len) {
                        s.touch(m, i);
                        m.assigned[i] = true;
                    };
                } else try s.countExpr(m, target);
                try s.countExpr(m, @fromBackingInt(@intCast(d.rhs)));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try s.countExpr(m, v),
            .if_stmt => {
                try s.countExpr(m, @fromBackingInt(@intCast(d.lhs)));
                const branches = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                try s.countList(m, branches.thenBody());
                try s.countList(m, branches.elseBody());
            },
            .while_true, .block_stmt => {
                s.declare(m, @fromBackingInt(@intCast(d.lhs)));
                try s.countList(m, ir.subRange(@fromBackingInt(@intCast(d.rhs))));
            },
            .for_of => {
                const f = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                s.declare(m, @fromBackingInt(@intCast(d.lhs)));
                try s.countExpr(m, f.iterable);
                try s.countList(m, f.body());
            },
            .break_stmt, .continue_stmt => {},
            .switch_stmt => {
                try s.countExpr(m, @fromBackingInt(@intCast(d.lhs)));
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |c| try s.count(m, c);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| try s.countExpr(m, t);
                try s.countList(m, ir.subRange(@fromBackingInt(@intCast(d.rhs))));
            },
            .expr_stmt, .throw_stmt => try s.countExpr(m, @fromBackingInt(@intCast(d.lhs))),
            .try_stmt => {
                const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                s.declare(m, t.catch_name);
                try s.countList(m, t.body());
                try s.countList(m, t.finalBody());
                try s.countList(m, t.catchBody());
            },
            else => {},
        }
    }

    /// `count` of top-level statement `stmt`, on a fresh `current`: the
    /// rewrite's count of a statement it walks or patches. The analysis's
    /// counts are the extraction's (`Extractor`).
    fn countTop(s: *Spec, m: *Mod, stmt: Index) Allocator.Error!void {
        try s.count(m, stmt);
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
        // A leaf, the most common expression, without the stack. Tested
        // with `==` and a table rather than a `switch` with an `else`
        // prong (`TagSet`).
        const root_tag = ir.tag(root);
        if (root_tag == .ident) return s.read(m, @fromBackingInt(@intCast(ir.data(root).lhs)), false);
        if (count_leaves[@backingInt(root_tag)]) return;
        const stack = &s.names;
        const base = stack.items.len;
        defer stack.items.len = base;
        try JsIr.pushOperand(s.arena, stack, root);
        while (stack.items.len > base) {
            const node = JsIr.popOperand(stack).?;
            const t = ir.tag(node);
            if (t == .ident) {
                try s.read(m, @fromBackingInt(@intCast(ir.data(node).lhs)), false);
            } else if (t == .arrow) {
                try s.countFunc(m, @fromBackingInt(@intCast(ir.data(node).lhs)));
            } else if (t == .call) {
                const d = ir.data(node);
                const callee: Index = @fromBackingInt(@intCast(d.lhs));
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |a| try JsIr.pushOperand(s.arena, stack, a);
                if (ir.tag(callee) == .ident) {
                    try s.read(m, @fromBackingInt(@intCast(ir.data(callee).lhs)), true);
                } else try JsIr.pushOperand(s.arena, stack, callee);
            } else if (!count_leaves[@backingInt(t)]) try ir.pushOperands(s.arena, stack, node);
        }
    }

    fn read(s: *Spec, m: *Mod, n: NameIndex, callee: bool) Allocator.Error!void {
        if (m.globalOf(n)) |g| {
            if (!callee) s.setEscaped(g);
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
                const n: NameIndex = @fromBackingInt(@intCast(d.lhs));
                const rhs: Node.OptionalIndex = if (ir.tag(stmt) == .const_decl) @fromBackingInt(@intCast(d.rhs)) else @fromBackingInt(@intCast(d.rhs));
                const v: Lat = if (rhs.unwrap()) |r| try s.eval(m, mi, r) else .top;
                if (m.globalOf(n) == null) if (n.unwrap()) |i| if (i < m.stamp.len) {
                    s.touch(m, i);
                    if (m.decls[i] == 1 and !m.assigned[i]) m.value[i] = v;
                };
            },
            // A declaration is hoisted: its body may run before any guard
            // the list has passed, so it sees none.
            .func_decl, .gen_decl => {
                const saved = s.narrow;
                s.narrow = .empty;
                defer s.narrow = saved;
                try s.evalFunc(m, mi, @fromBackingInt(@intCast(d.rhs)), stmt);
            },
            .assign_stmt => {
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                if (ir.tag(target) != .ident) _ = try s.eval(m, mi, target);
                const value = try s.eval(m, mi, @fromBackingInt(@intCast(d.rhs)));
                // Facts 4 and 5: what `o.p = v` writes, on every object `o`
                // may be.
                if (ir.tag(target) == .member and s.pts.ok) {
                    const td = ir.data(target);
                    const obj = s.pts.vals[mi][td.lhs];
                    const id = s.pts.propId(mi, @fromBackingInt(@intCast(td.rhs)));
                    for (obj.sites) |site| try s.joinProp(site, id, value);
                }
            },
            .return_stmt => {
                const v: Lat = if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try s.eval(m, mi, v) else .of(try s.intern(.{ .kind = .undefined_lit }));
                try s.joinRet(v);
            },
            .if_stmt => {
                _ = try s.eval(m, mi, @fromBackingInt(@intCast(d.lhs)));
                const branches = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                try s.evalList(m, mi, branches.thenBody());
                try s.evalList(m, mi, branches.elseBody());
            },
            .while_true, .block_stmt => try s.evalList(m, mi, ir.subRange(@fromBackingInt(@intCast(d.rhs)))),
            .for_of => {
                const f = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                _ = try s.eval(m, mi, f.iterable);
                try s.evalList(m, mi, f.body());
            },
            .switch_stmt => {
                _ = try s.eval(m, mi, @fromBackingInt(@intCast(d.lhs)));
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |c| try s.evalStmt(m, mi, c);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| _ = try s.eval(m, mi, t);
                try s.evalList(m, mi, ir.subRange(@fromBackingInt(@intCast(d.rhs))));
            },
            .expr_stmt, .throw_stmt => _ = try s.eval(m, mi, @fromBackingInt(@intCast(d.lhs))),
            // Both blocks are walked; facts 1 and 2 are flow-insensitive, so
            // a cleanup that runs after a throw part-way through the body
            // sees nothing they could have assumed.
            .try_stmt => {
                const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                try s.evalList(m, mi, t.body());
                try s.evalList(m, mi, t.finalBody());
                try s.evalList(m, mi, t.catchBody());
            },
            else => {},
        }
    }

    fn evalList(s: *Spec, m: *Mod, mi: u32, range: JsIr.SubRange) Allocator.Error!void {
        const base = s.narrow.items.len;
        defer s.narrow.shrinkRetainingCapacity(base);
        for (m.ir.extraSlice(range, Index)) |stmt| {
            try s.evalStmt(m, mi, stmt);
            if (m.ir.tag(stmt) == .if_stmt) try s.guardNames(m, stmt);
        }
    }

    /// Fact 5 past a guard: `if (T) …` whose first arm cannot complete
    /// normally (it ends in a `throw`, `return`, `break` or `continue`) is
    /// followed by the rest of its list only when `T` was false — so every
    /// disjunct of `T`'s top-level `||` chain was evaluated, and was false,
    /// without throwing. A local `X` is then neither `null` nor `undefined`
    /// for the rest of the list when some disjunct is `X == null`, or when
    /// some disjunct reads a property of `X` wherever it is evaluated (not
    /// in the right side of `&&`, `||` or a conditional's arms, nor in a
    /// function): that read would have thrown. `nameValue` reads what this
    /// pushes, and only for a name declared once that nothing assigns, so
    /// the value it saw is the value every later read sees.
    fn guardNames(s: *Spec, m: *Mod, stmt: Index) Allocator.Error!void {
        const ir = m.ir;
        const branches = ir.extraData(@fromBackingInt(@intCast(ir.data(stmt).rhs)), JsIr.If);
        const then = ir.extraSlice(branches.thenBody(), Index);
        if (then.len == 0) return;
        switch (ir.tag(then[then.len - 1])) {
            .throw_stmt, .return_stmt, .break_stmt, .continue_stmt => {},
            else => return,
        }
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        var disjuncts = try s.takeStack();
        defer s.giveStack(&disjuncts);
        try disjuncts.append(s.arena, @fromBackingInt(@intCast(ir.data(stmt).lhs)));
        while (disjuncts.pop()) |dj| {
            if (ir.tag(dj) == .binary and @as(JsIr.BinaryOp, @fromBackingInt(@intCast(ir.data(dj).rhs))) == .logical_or) {
                const b = ir.extraData(@fromBackingInt(@intCast(ir.data(dj).lhs)), JsIr.Binary);
                try disjuncts.appendSlice(s.arena, &.{ b.right, b.left });
                continue;
            }
            if (nullTest(ir, dj)) |t| if (t.loose and t.null_in_then and ir.tag(t.chain) == .ident) {
                try s.narrowName(m, @fromBackingInt(@intCast(ir.data(t.chain).lhs)));
            };
            // What this disjunct evaluated, whatever its value.
            stack.clearRetainingCapacity();
            try JsIr.pushOperand(s.arena, &stack, dj);
            while (JsIr.popOperand(&stack)) |node| {
                const d = ir.data(node);
                switch (ir.tag(node)) {
                    .member, .index_get => {
                        const object: Index = @fromBackingInt(@intCast(d.lhs));
                        if (ir.tag(object) == .ident) try s.narrowName(m, @fromBackingInt(@intCast(ir.data(object).lhs)));
                    },
                    .binary => switch (@as(JsIr.BinaryOp, @fromBackingInt(@intCast(d.rhs)))) {
                        .logical_and, .logical_or => {
                            try JsIr.pushOperand(s.arena, &stack, ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary).left);
                            continue;
                        },
                        else => {},
                    },
                    .cond => {
                        try JsIr.pushOperand(s.arena, &stack, @fromBackingInt(@intCast(d.lhs)));
                        continue;
                    },
                    else => {},
                }
                try ir.pushOperands(s.arena, &stack, node);
            }
        }
    }

    fn narrowName(s: *Spec, m: *Mod, n: NameIndex) Allocator.Error!void {
        if (m.globalOf(n) != null or n.unwrap() == null) return;
        try s.narrow.append(s.arena, n);
    }

    /// A function's body, `node` the arrow or the declaration: what its
    /// `return`s give, and `undefined` when it may run off its end, join
    /// its site's return cell (fact 5).
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
        // A leaf, the most common expression, without the stack.
        if (isValueLeaf(ir.tag(root))) {
            m.memo[root.int()] = try s.combine(m, root);
            return m.memo[root.int()];
        }
        // As `Pts.expr`'s: `post_bit` marks a node whose operands are done.
        const stack = &s.children;
        const base = stack.items.len;
        defer stack.items.len = base;
        try JsIr.pushOperand(s.arena, stack, root);
        while (stack.items.len > base) {
            const raw = stack.items[stack.items.len - 1].int();
            stack.items.len -= 1;
            if (raw & post_bit == 0) {
                const node: Index = @fromBackingInt(@intCast(raw));
                const t = ir.tag(node);
                if (t == .arrow) {
                    m.memo[raw] = .object;
                    try s.evalFunc(m, mi, @fromBackingInt(@intCast(ir.data(node).lhs)), node);
                    continue;
                }
                // A leaf has no operands to wait for.
                if (isValueLeaf(t)) {
                    m.memo[raw] = try s.combine(m, node);
                    continue;
                }
                try JsIr.pushOperand(s.arena, stack, @fromBackingInt(@intCast(raw | post_bit)));
                try ir.pushOperands(s.arena, stack, node);
                continue;
            }
            const node: Index = @fromBackingInt(@intCast(raw & ~post_bit));
            m.memo[node.int()] = try s.combine(m, node);
        }
        return m.memo[root.int()];
    }

    fn combine(s: *Spec, m: *Mod, node: Index) Allocator.Error!Lat {
        const ir = m.ir;
        const d = ir.data(node);
        return switch (ir.tag(node)) {
            .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => s.literalValue(m, node),
            .ident => try s.nameValue(m, @fromBackingInt(@intCast(d.lhs))),
            // Every operator but `yield`, `&&` and `||` gives a primitive
            // that is neither `null` nor `undefined`.
            .unary => blk: {
                const op: JsIr.UnaryOp = @fromBackingInt(@intCast(d.rhs));
                const v = try s.unary(op, m.memo[d.lhs]);
                break :blk if (op != .yield and v.state == .top) .{ .state = .nonnull, .truth = v.truth } else v;
            },
            .binary => blk: {
                const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                const op: JsIr.BinaryOp = @fromBackingInt(@intCast(d.rhs));
                const l = m.memo[b.left.int()];
                const r = m.memo[b.right.int()];
                // Facts 5 and 6: an identity test decided by what the two
                // sides may be, when neither side's evaluation can do
                // anything the fold would lose.
                if ((op == .strict_eq or op == .strict_ne) and l.state != .bot and r.state != .bot) if (try s.identity(m, b.left, b.right, l, r)) |same| {
                    break :blk try s.boolean(if (op == .strict_eq) same else !same);
                };
                const v = try s.binary(op, l, r);
                break :blk if (op != .logical_and and op != .logical_or and v.state == .top) .{ .state = .nonnull, .truth = v.truth } else v;
            },
            .cond => blk: {
                const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                const t = m.memo[d.lhs];
                // Fact 5's second case, decided by the values as they are;
                // the rewrite reads the decision off them (`decidedBranch`).
                if (t.state == .top or t.state == .nonnull) {
                    if (try s.nullTestTaken(m, @fromBackingInt(@intCast(d.lhs)), c)) |taken| break :blk m.memo[taken.int()];
                }
                break :blk s.condValue(t, m.memo[c.consequent.int()], m.memo[c.alternate.int()]);
            },
            .call => blk: {
                try s.callSite(m, node);
                break :blk try s.callValue(m, node);
            },
            .template => try s.templateValue(m, node, MemoValues{ .memo = m.memo }),
            .new_call, .object, .array => blk: {
                if (ir.tag(node) == .object) try s.objectWrites(m, node);
                break :blk .object;
            },
            .member => try s.memberValue(m, node),
            // A store of a record update written in place: what `evalStmt`
            // joins for `o.p = v` (facts 4 and 5), and its value is `v`.
            .assign => blk: {
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                const value = m.memo[d.rhs];
                if (s.pts.ok) {
                    const td = ir.data(target);
                    const obj = s.pts.vals[m.index][td.lhs];
                    const id = s.pts.propId(m.index, @fromBackingInt(@intCast(td.rhs)));
                    for (obj.sites) |site| try s.joinProp(site, id, value);
                }
                break :blk s.demote(value);
            },
            .sequence => blk: {
                const parts = ir.extraSlice(JsIr.inlineRange(d), Index);
                break :blk s.demote(m.memo[parts[parts.len - 1].int()]);
            },
            else => .top,
        };
    }

    /// `t ? a : e` that fact 5's second case does not decide: the branch a
    /// literal test takes, the branch a test always truthy or always falsy
    /// takes — never as its literal, since the test is still made — or the
    /// join of both.
    fn condValue(s: *Spec, t: Lat, a: Lat, e: Lat) Lat {
        return switch (t.state) {
            .bot => .bot,
            .top, .nonnull => undecided: {
                switch (t.truth) {
                    .yes => break :undecided s.demote(a),
                    .no => break :undecided s.demote(e),
                    .bot, .unknown => {},
                }
                if (a.state == .bot and e.state == .bot) break :undecided .bot;
                break :undecided s.demote(s.join(a, e));
            },
            .lit => switch (s.truthy(s.litOf(t))) {
                .yes => a,
                .no => e,
                .unknown => .top,
            },
        };
    }

    /// A template's parts' values as the walk left them (`templateValue`).
    const MemoValues = struct {
        memo: []const Lat,
        fn get(v: MemoValues, i: usize, part: Index) Lat {
            _ = i;
            return v.memo[part.int()];
        }
    };

    /// A template whose every substitution is a literal is the string it
    /// makes (fact 4's reads end in one: `${m.n}` is `"null"`), when that
    /// string prints no longer than the template did. A number converts
    /// only when its spelling is how JavaScript writes it back.
    fn templateValue(s: *Spec, m: *Mod, node: Index, parts: anytype) Allocator.Error!Lat {
        const ir = m.ir;
        var text: std.ArrayList(u8) = .empty;
        var template_len: usize = 2;
        for (ir.extraSlice(JsIr.inlineRange(ir.data(node)), Index), 0..) |part, i| {
            if (ir.tag(part) == .template_chunk) {
                const chunk = ir.bytes(part);
                try text.appendSlice(s.arena, chunk);
                template_len += chunk.len;
                for (chunk) |c| template_len += @intFromBool(c == '`' or c == '\\' or c == '$');
                continue;
            }
            const v = parts.get(i, part);
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
        // The fold only shortens the node (below), and a literal this long is
        // written again elsewhere only where it is read once
        // (`substitutes`): the bound is on memory, not on bytes. It was 256,
        // which kept a page's markup of several modules' strings a template.
        if (text.items.len > 1 << 20) return .nonnull;
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
        return s.memberOf(m, node, null);
    }

    /// `memberValue`, its object `named` when facts 1 and 2 say it is the
    /// object a whole-program name declares (a `name` literal): fact 3's
    /// value of that name, which is that one object, in place of the
    /// object node's, which joins what every call passes, executable or
    /// not.
    fn memberOf(s: *Spec, m: *Mod, node: Index, named: ?Pts.Val) Allocator.Error!Lat {
        const ir = m.ir;
        const d = ir.data(node);
        const id = s.pts.propId(m.index, @fromBackingInt(@intCast(d.rhs)));
        // An object literal that does nothing when made is read like a
        // chain: `{ a: 1 }.a` is `1`, as a body written in leaves it.
        const literal: ?Pts.Val = if (ir.tag(@as(Index, @fromBackingInt(@intCast(d.lhs)))) == .object and s.pts.ok and d.lhs < s.pts.vals[m.index].len and inert(ir, @fromBackingInt(@intCast(d.lhs)))) s.pts.vals[m.index][d.lhs] else null;
        const chain = if (try s.pts.chain(m.index, s.cur_top, @fromBackingInt(@intCast(d.lhs)))) |c| named orelse c else literal;
        if (chain) |obj| if (s.pts.neverWritten(obj, id)) {
            return .of(try s.intern(.{ .kind = .undefined_lit }));
        };
        if (!s.pts.ok) return .top;
        const obj = chain orelse s.pts.vals[m.index][d.lhs];
        const v = try s.propValue(obj, id);
        if (v.state == .lit and chain != null and s.pts.known(obj)) return v;
        if (id != none and id == s.in.tag_prop) if (try s.tagValue(m, @fromBackingInt(@intCast(d.lhs)), id, named)) |t| return t;
        return s.demote(v);
    }

    /// Slice 9: a constructor's tag `$`, read through a chain that may only
    /// be object literals of the program each of which has the key — escaped
    /// or not: a beni value is immutable, and no file the pass cannot see
    /// writes one (`boundary.md` §4) — and that no code of the program
    /// writes `$` on, or on anything it cannot see, is the literals' one
    /// value. A literal has no getter; the chain is safe to evaluate.
    fn tagValue(s: *Spec, m: *Mod, object: Index, id: u32, named: ?Pts.Val) Allocator.Error!?Lat {
        const p = &s.pts;
        if (p.unknown_any or std.mem.indexOfScalar(u32, p.unknown_props.items, id) != null) return null;
        const safe = try p.safeChain(m.index, s.cur_top, object) orelse return null;
        const obj = named orelse safe;
        if (obj.top or obj.prim or obj.nullish() or obj.sites.len == 0) return null;
        var out: Lat = .bot;
        for (obj.sites) |site| {
            try s.readsSite(site);
            const st = &p.sites.items[site];
            if (st.kind != .object or st.prog_any) return null;
            if (std.mem.indexOfScalar(u32, st.prog_props.items, id) != null) return null;
            if (site >= s.spread_sites.len or s.spread_sites[site]) return null;
            const pr = p.findProp(site, id) orelse return null;
            if (!pr.init) return null;
            // No write: its literal never runs (*Executability*).
            out = s.join(out, try s.fieldGet(site, id) orelse .bot);
        }
        return if (out.state == .lit) out else null;
    }

    /// The join of what is written to property `id` of every object `obj`
    /// may be: ⊤ unless each is a program object literal that nothing
    /// unseen holds, none written under an unknown key or copied from by a
    /// spread, each with the key in its literal. Reading a property of a
    /// primitive gives `undefined` or a builtin, so a primitive `obj` is ⊤;
    /// a nullish one throws and gives nothing.
    fn propValue(s: *Spec, obj: Pts.Val, id: u32) Allocator.Error!Lat {
        if (id == none or obj.top or obj.prim or obj.sites.len == 0) return .top;
        var out: Lat = .bot;
        for (obj.sites) |site| {
            try s.readsSite(site);
            const st = &s.pts.sites.items[site];
            if (st.kind != .object or st.escaped or st.any_written) return .top;
            if (site >= s.spread_sites.len or s.spread_sites[site]) return .top;
            const pr = s.pts.findProp(site, id) orelse return .top;
            if (!pr.init) return .top;
            out = s.join(out, try s.fieldGet(site, id) orelse .bot);
        }
        return out;
    }

    /// An object literal's keys, joined into what its site's properties
    /// may hold (facts 4 and 5); a spread makes every one ⊤.
    fn objectWrites(s: *Spec, m: *Mod, node: Index) Allocator.Error!void {
        const ir = m.ir;
        const site = s.pts.siteAt(m.index, node) orelse return;
        for (ir.extraSlice(JsIr.inlineRange(ir.data(node)), Index)) |child| {
            const cd = ir.data(child);
            switch (ir.tag(child)) {
                .property => try s.joinProp(site, s.pts.propId(m.index, @fromBackingInt(@intCast(cd.lhs))), m.memo[cd.rhs]),
                else => {
                    if (site < s.spread_sites.len and !s.spread_sites[site]) {
                        s.spread_sites[site] = true;
                        s.siteChanged(site);
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
        const callee: Index = @fromBackingInt(@intCast(ir.data(node).lhs));
        const vc = s.pts.vals[m.index][callee.int()];
        if (ir.tag(callee) == .member) {
            const id = s.pts.propId(m.index, @fromBackingInt(@intCast(ir.data(callee).rhs)));
            const host = id != none and std.mem.indexOfScalar(u32, s.in.node_makers, id) != null;
            const receiver = s.pts.vals[m.index][ir.data(callee).lhs];
            // No object of the program: a host object, whose method makes a
            // node or throws, or a primitive, `null` or `undefined`, which
            // has no such method and throws — never `null`, whatever else
            // fact 3 says the receiver may be (`Pts.Val.top_val`).
            if (host and receiver.sites.len == 0) return .object;
        }
        if (vc.top or vc.prim or vc.sites.len == 0) return .top;
        var out: Lat = .bot;
        for (vc.sites) |site| {
            try s.readsSite(site);
            const st = &s.pts.sites.items[site];
            if (st.kind != .func) return .top;
            const ref: NodeRef = .{ .module = st.module, .node = st.node.int() };
            if (s.mods[st.module].ir.tag(st.node) == .gen_decl) {
                out = s.join(out, .object);
                continue;
            }
            out = s.join(out, try s.retGet(ref) orelse .bot);
        }
        return s.demote(out);
    }

    /// A call: its arguments join the parameters of the function it names.
    fn callSite(s: *Spec, m: *Mod, node: Index) Allocator.Error!void {
        const ir = m.ir;
        const d = ir.data(node);
        const callee: Index = @fromBackingInt(@intCast(d.lhs));
        if (ir.tag(callee) != .ident) return;
        const g = m.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs))) orelse return;
        const decl = s.decl[g] orelse return;
        if (decl.func == null) return;
        const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index);
        if (args.len != decl.arity) {
            s.setEscaped(g);
            return;
        }
        for (args, 0..) |a, i| {
            // A parameter is read by its own declaration alone.
            if (s.joinInto(&s.params.items[decl.params + i], m.memo[a.int()]) and decl.index < s.w_dirty.bit_length)
                s.w_dirty.set(decl.index);
        }
    }

    /// Whether evaluating argument `a` can do nothing but make its value, so
    /// that it may go with the parameter it is passed to: `inert`, a name
    /// or a chain of reads through objects the program made, none of which
    /// may run a getter or throw (`Pts.safeChain`), or a call of functions
    /// that only make a value (`pureCall`).
    fn effectFree(s: *Spec, m: *Mod, a: Index) Allocator.Error!bool {
        return s.effectFreeAt(m, a, 0);
    }

    fn effectFreeAt(s: *Spec, m: *Mod, a: Index, depth: u32) Allocator.Error!bool {
        if (inert(m.ir, a)) return true;
        if (!s.pts.ok) return false;
        if (m.ir.tag(a) == .call) return s.pureCall(m, a, depth);
        return try s.pts.safeChain(m.index, s.cur_top, a) != null;
    }

    /// `backend.md` §9, *A call of a function that only makes a value*: a
    /// call does nothing but make its value when its callee is a chain that
    /// can neither throw nor run a getter (`Pts.safeChain`), that fact 3
    /// says may be only functions of the program — never `null`,
    /// `undefined`, a primitive or a host value — each of which only makes
    /// its value (`makesOnly`), and when every argument does nothing in
    /// turn. Such a call cannot throw, loop, log or write: its one
    /// observable is the value, so a call whose value nothing reads may go.
    fn pureCall(s: *Spec, m: *Mod, call: Index, depth: u32) Allocator.Error!bool {
        if (depth >= max_pure_depth) return false;
        const ir = m.ir;
        const d = ir.data(call);
        const v = try s.pts.safeChain(m.index, s.cur_top, @fromBackingInt(@intCast(d.lhs))) orelse return false;
        if (v.top or v.prim or v.nullish() or v.sites.len == 0) return false;
        for (v.sites) |site| {
            const st = &s.pts.sites.items[site];
            if (st.kind != .func or !makesOnly(s.mods[st.module].ir, st.node)) return false;
        }
        for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |arg| {
            if (!try s.effectFreeAt(m, arg, depth + 1)) return false;
        }
        return true;
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
    fn decidedBranch(s: *Spec, m: *Mod, node: Index) Allocator.Error!?Index {
        const d = m.ir.data(node);
        const t = m.memo[d.lhs];
        if (t.state != .top and t.state != .nonnull) return null;
        return s.nullTestTaken(m, @fromBackingInt(@intCast(d.lhs)), m.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond));
    }

    fn nullTestTaken(s: *Spec, m: *Mod, test_node: Index, c: JsIr.Cond) Allocator.Error!?Index {
        _ = s;
        const ir = m.ir;
        if (ir.tag(test_node) != .binary) return null;
        const op: JsIr.BinaryOp = @fromBackingInt(@intCast(ir.data(test_node).rhs));
        if (op != .strict_eq and op != .strict_ne) return null;
        const b = ir.extraData(@fromBackingInt(@intCast(ir.data(test_node).lhs)), JsIr.Binary);
        const tested, const other = if (ir.tag(b.right) == .null_lit) .{ b.left, b.right } else .{ b.right, b.left };
        if (ir.tag(other) != .null_lit or ir.tag(tested) != .member) return null;
        if (m.memo[tested.int()].state != .nonnull) return null;
        const taken = if (op == .strict_eq) c.alternate else c.consequent;
        if (!sameChain(ir, tested, taken)) return null;
        return taken;
    }

    /// What reading `n` gives, from the facts.
    fn nameValue(s: *Spec, m: *Mod, n: NameIndex) Allocator.Error!Lat {
        if (m.globalOf(n)) |g| {
            try s.readsName(g);
            return s.globalValue(g);
        }
        const i = n.unwrap() orelse return .top;
        if (i >= m.stamp.len or m.stamp[i] != s.current) return .top;
        if (m.decls[i] != 1 or m.assigned[i]) return .top;
        const v = if (m.param[i] != none) param: {
            const f = s.top_func orelse break :param Lat.top;
            try s.readsName(s.globalOfDecl(f));
            if (s.escaped[s.globalOfDecl(f)]) break :param Lat.top;
            break :param s.params.items[f.params + m.param[i]];
        } else m.value[i];
        // Past a guard that proves it (`guardNames`).
        if (v.state == .top and std.mem.indexOfScalar(NameIndex, s.narrow.items, n) != null) return .{ .state = .nonnull, .truth = v.truth };
        return v;
    }

    /// What reading whole-program name `g` gives: a function of the IR and
    /// of `decl`, `escaped` and `assigned`, which every walk of one analysis
    /// sees alike (the combined solver's `global` constraint).
    fn globalValue(s: *Spec, g: u32) Lat {
        // Slice 6: a declaration that makes an object or a function, and
        // that nothing assigns, is that one object wherever it is read.
        if (s.decl[g]) |decl| if (!s.assigned[g]) {
            const dm = &s.mods[decl.module];
            const fresh = switch (dm.ir.tag(decl.stmt)) {
                .func_decl => true,
                .const_decl => switch (dm.ir.tag(@fromBackingInt(@intCast(dm.ir.data(decl.stmt).rhs)))) {
                    .arrow, .object, .array => true,
                    else => false,
                },
                else => false,
            };
            if (fresh) return s.nameLat(g) catch .nonnull;
        };
        // Its initialiser's cell, as the last solve left it.
        if (g < s.name_solved.len and s.name_solved[g] != none) return @bitCast(s.name_solved[g]);
        if (s.escaped[g] and s.decl[g] != null and s.decl[g].?.func != null) return .top;
        if (s.assigned[g]) return .top;
        const decl = s.decl[g] orelse return .top;
        const dm = &s.mods[decl.module];
        const d = dm.ir.data(decl.stmt);
        const value: Index = switch (dm.ir.tag(decl.stmt)) {
            .const_decl => @fromBackingInt(@intCast(d.rhs)),
            .let_decl => (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap() orelse return .top),
            else => return .top,
        };
        const v = s.literalValue(dm, value) catch Lat.top;
        // Fact 5: an object, an array, a function, a template or a
        // `new` is never `null` (a read before the declaration throws).
        if (v.state == .top) switch (dm.ir.tag(value)) {
            .object, .array, .arrow, .new_call => return .object,
            .template => return .nonnull,
            else => {},
        };
        return v;
    }

    /// The initialiser of whole-program name `g`, when every read of it is
    /// that value (*Cells*, the name cells): its one declaration, a `const`
    /// or a `let` nothing assigns, of a value `globalValue` does not answer
    /// for by itself. A read before the declaration throws, so it has no
    /// value at all.
    fn nameInit(s: *Spec, g: u32) ?struct { module: u32, node: Index } {
        const decl = s.decl[g] orelse return null;
        if (s.assigned[g]) return null;
        const dm = &s.mods[decl.module];
        const d = dm.ir.data(decl.stmt);
        const value: Index = switch (dm.ir.tag(decl.stmt)) {
            .const_decl => @fromBackingInt(@intCast(d.rhs)),
            .let_decl => (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap() orelse return null),
            else => return null,
        };
        switch (dm.ir.tag(value)) {
            .arrow => return null,
            .object, .array => if (dm.ir.tag(decl.stmt) == .const_decl) return null,
            else => {},
        }
        return .{ .module = decl.module, .node = value };
    }

    fn globalOfDecl(s: *Spec, d: Decl) u32 {
        const m = &s.mods[d.module];
        return m.globalOf(@fromBackingInt(@intCast(m.ir.data(d.stmt).lhs))).?;
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
            .number => numberTruth(lit.bytes),
        };
    }

    /// Whether a numeric literal is truthy: not zero (no literal is
    /// `NaN`), which its digits say without converting it — every literal
    /// the program spells is asked once (`intern`), and a conversion costs
    /// a thousand instructions. A negative exponent may round a nonzero
    /// mantissa to zero, and is converted.
    fn numberTruth(text: []const u8) Truth {
        if (text.len == 0) return .unknown;
        if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
            for (text[2..]) |c| switch (c) {
                '0' => {},
                '1'...'9', 'a'...'f', 'A'...'F' => return .yes,
                else => return .unknown,
            };
            return .no;
        }
        var nonzero = false;
        for (text, 0..) |c, i| switch (c) {
            '0', '.', '-', '+' => {},
            '1'...'9' => nonzero = true,
            'e', 'E' => {
                if (std.mem.indexOfScalar(u8, text[i..], '-') != null) {
                    const x = parseNumber(text) orelse return .unknown;
                    return if (x != 0) .yes else .no;
                }
                break;
            },
            else => return .unknown,
        };
        return if (nonzero) .yes else .no;
    }

    fn unary(s: *Spec, op: JsIr.UnaryOp, a: Lat) Allocator.Error!Lat {
        if (a.state == .bot) return .bot;
        if (a.state != .lit) return switch (op) {
            // A boolean, `true` exactly when its operand is falsy.
            .not => .{ .state = .nonnull, .truth = s.truthOf(a).not() },
            // The name of a type: a string that is never empty.
            .type_of => .{ .state = .nonnull, .truth = .yes },
            .neg => .nonnull,
            // What the generator is resumed with, not what it yields.
            .yield => .top,
        };
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
                    .name => return .{ .state = .nonnull, .truth = .yes },
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
                const t = s.truthOf(a);
                // `a || b` is `a` when `a` is truthy, else `b`; `a && b` is
                // `a` when `a` is falsy, else `b`.
                const a_ends: Lat.Truth = if (op == .logical_or) .yes else .no;
                if (t == a_ends) return a;
                if (t == a_ends.not()) {
                    // A literal `a` is evaluated with nothing to lose; any
                    // other is still evaluated, so the value is not the
                    // literal `b` may be.
                    return if (a.state == .lit) b else if (b.state == .bot) .bot else s.demote(b);
                }
                if (a.state == .lit) return .top;
                // Either side may be the value; nonnull only when both are,
                // and truthy when `a` is wherever it ends the operator and
                // `b` is wherever it goes on (`x || true`).
                var v = s.demote(s.join(a, b));
                v.truth = a_ends.join(s.truthOf(b));
                return v;
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
            .pow, .logical_and, .logical_or, .strict_eq, .strict_ne, .loose_eq, .instance_of => .top,
        };
    }

    // ---- The rewrite ----------------------------------------------------------

    /// Spend the facts. True when anything changed, so another round may
    /// find more.
    fn rewrite(s: *Spec) Allocator.Error!bool {
        var any = false;
        s.name_in.clearRetainingCapacity();
        s.only_fewer = true;
        s.rewrite_epoch += 1;
        defer s.only_fewer = false;
        s.declined.clearRetainingCapacity();
        if (s.folded_reads.len < s.globals) s.folded_reads = try s.arena.alloc(u32, s.globals);
        @memset(s.folded_reads, 0);
        // Which parameters go: a constant the substitution rule allows,
        // by the counts before the patch, which writes its reads as the
        // literal by the same counts.
        const drop = try s.arena.alloc(bool, s.params.items.len);
        @memset(drop, false);
        for (s.decl, 0..) |maybe, g| {
            const decl = maybe orelse continue;
            if (decl.func == null or s.escaped[g]) continue;
            const m = &s.mods[decl.module];
            const f = m.ir.extraData(decl.func.?, JsIr.Func);
            s.current += 1;
            try s.countTop(m, decl.stmt);
            for (m.ir.extraSlice(f.params(), NameIndex), 0..) |n, i| {
                const v = s.params.items[decl.params + i];
                const at = n.unwrap() orelse continue;
                if (m.decls[at] != 1 or m.assigned[at]) continue;
                if (v.state == .lit and substitutes(s.litOf(v), m.uses[at]) and
                    (s.litOf(v).kind != .name or try s.nameIn(m, nameId(s.litOf(v))) != null))
                {
                    drop[decl.params + i] = true;
                }
            }
        }
        // What lowering keeps for an effect, past what does nothing after
        // all (`releaseKeeps`): per module, by node.
        const kept_bits = try s.arena.alloc(std.DynamicBitSetUnmanaged, s.mods.len);
        for (s.mods, kept_bits) |*m, *bits| {
            try s.releaseKept(m);
            bits.* = try .initEmpty(s.arena, m.ir.nodes.len);
            if (m.tables) |t| for (t.keep.items) |k| if (k.int() < bits.bit_length) bits.set(k.int());
        }

        // Each statement patched once, from the solve's facts, which no
        // patch changes (*The rewrite*): its names counted, then its
        // nodes written. Then the liveness of its bindings, on what the
        // patch left (*Reading off*), and the parameters of its function
        // that nothing live reads.
        // Per parameter: nothing live reads it, by the counts the patch
        // left.
        const unread = try s.arena.alloc(bool, s.params.items.len);
        @memset(unread, false);
        for (s.mods, 0..) |*m, mi| {
            const body = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.body, Index));
            for (body) |stmt| {
                // Patched until the counts it leaves allow nothing more:
                // a read refused by the substitution rule for the count
                // before is written when folds took the others. The facts
                // stay the solve's throughout.
                var turn: u32 = 0;
                while (true) : (turn += 1) {
                    const before = m.epoch;
                    s.refused_local = false;
                    try s.prepareTop(m, @intCast(mi), stmt);
                    // Its changes are its own (`Mod.kept`): the combined
                    // solver's constraints of another statement (`Extract`)
                    // hold across them.
                    within(m, stmt);
                    if (try s.patchStmt(m, stmt)) any = true;
                    // The `if`s whose test is now a literal, while the
                    // declaration's counts are the ones `spliceable` reads.
                    if (try s.foldBelow(m, stmt, 0)) any = true;
                    // Counted again only when the patch changed it.
                    if (m.epoch != before) try s.prepareTop(m, @intCast(mi), stmt);
                    if (try s.liveness(m, stmt, kept_bits[mi])) {
                        any = true;
                        _ = try s.foldBelow(m, stmt, 0);
                    }
                    try s.leave(m);
                    if (m.epoch == before or !s.refused_local or turn == max_patch_turns) break;
                }
                _ = try s.unreadParams(m, unread);
            }
        }
        // A parameter nothing live reads goes whatever it is passed, when
        // every call is seen and no argument for it does anything, as the
        // patch left the arguments.
        // The keys nothing the patch left reads go first: an argument that
        // was an object of them may do nothing now.
        if (try s.dropUnreadKeys()) any = true;
        if (std.mem.indexOfScalar(bool, unread, true) != null) {
            const effect = try s.argEffects();
            for (unread, effect, drop) |u, e, *d| if (u and !e) {
                d.* = true;
            };
        }
        const drop_epoch = try s.arena.alloc(u64, s.mods.len);
        for (s.mods, drop_epoch) |*m, *e| e.* = m.epoch;
        if (try s.applyDrops(drop, true)) any = true;
        // A parameter that went took its arguments, and what they read may
        // be read by nothing now: the liveness again, and the parameters it
        // leaves unread, until none goes.
        var turn: u32 = 0;
        while (turn < max_patch_turns) : (turn += 1) {
            const more = try s.arena.alloc(bool, s.params.items.len);
            @memset(more, false);
            var asks = false;
            for (s.mods, 0..) |*m, mi| {
                const body = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.body, Index));
                for (body) |stmt| {
                    // Only a statement the drops changed reads less now.
                    if (m.kept(stmt, drop_epoch[mi])) continue;
                    try s.prepareTop(m, @intCast(mi), stmt);
                    within(m, stmt);
                    if (try s.liveness(m, stmt, kept_bits[mi])) _ = try s.foldBelow(m, stmt, 0);
                    try s.leave(m);
                    if (try s.unreadParams(m, more)) asks = true;
                }
            }
            if (!asks) break;
            const effect = try s.argEffects();
            var went = false;
            for (more, effect) |*u, e| {
                if (e) u.* = false;
                if (u.*) went = true;
            }
            if (!went) break;
            for (s.mods, drop_epoch) |*m, *e| e.* = m.epoch;
            if (try s.applyDrops(more, false)) any = true;
        }
        // A read of a module constant `substitutes` refused for the count
        // the solve began with, when the patch folded enough of the others
        // away (`folded_reads`) for it to be allowed: written as its
        // literal now, by the count the whole patch left, so whether it is
        // does not depend on which module came first.
        const declined = s.declined.items.len;
        for (s.declined.items[0..declined]) |d| {
            if (d.g >= s.folded_reads.len or s.folded_reads[d.g] == 0) continue;
            const left = s.reads[d.g] -| s.folded_reads[d.g];
            if (!substitutes(d.lit, left)) continue;
            const m = &s.mods[d.module];
            if (m.ir.tag(d.node) != .ident or m.globalOf(@fromBackingInt(@intCast(m.ir.data(d.node).lhs))) != d.g) continue;
            const read_by = s.reads[d.g];
            s.reads[d.g] = left;
            defer s.reads[d.g] = read_by;
            within(m, d.top);
            if (try s.patchLiteral(m, d.node, d.v, d.object_position)) any = true;
            try s.leave(m);
        }
        return any;
    }

    /// Marks in `unread` the parameters of the function the statement just
    /// counted declares (`top_func`), when `Spec` tracks it, that nothing
    /// live reads. True when one is.
    fn unreadParams(s: *Spec, m: *Mod, unread: []bool) Allocator.Error!bool {
        const d = s.top_func orelse return false;
        if (s.escaped[s.globalOfDecl(d)]) return false;
        const f = m.ir.extraData(d.func.?, JsIr.Func);
        var any = false;
        for (m.ir.extraSlice(f.params(), NameIndex), 0..) |n, i| {
            if (i >= d.arity) break;
            const at = n.unwrap() orelse continue;
            if (m.decls[at] != 1 or m.assigned[at] or m.uses[at] != 0) continue;
            if (s.params.items[d.params + i].state == .bot) continue;
            unread[d.params + i] = true;
            any = true;
        }
        return any;
    }

    /// The parameters `drop` marks gone from their functions, and their
    /// arguments from every call the program makes. A function that lost
    /// one has its parameters numbered anew at the end of `params`, so that
    /// another drop in the same rewrite reads them as they now are.
    /// `keep_fact3`: fact 3's state may take the drop without a solve
    /// (`keepDrop`, #582); a later drop asks the solve again. True when any
    /// went.
    fn applyDrops(s: *Spec, drop: []const bool, keep_fact3: bool) Allocator.Error!bool {
        var any = false;
        // Per whole-program name: fact 3's state takes the drop of its
        // parameters without a solve (`keepDrop`, #582).
        const kept_drop = try s.arena.alloc(bool, s.globals);
        @memset(kept_drop, false);
        for (s.decl, 0..) |maybe, g| {
            const decl = maybe orelse continue;
            if (decl.func == null) continue;
            const flags = drop[decl.params..][0..decl.arity];
            if (std.mem.indexOfScalar(bool, flags, true) == null) continue;
            const m = &s.mods[decl.module];
            if (keep_fact3) kept_drop[g] = try s.keepDrop(m, decl, flags);
            const f = m.ir.extraData(decl.func.?, JsIr.Func);
            var kept: std.ArrayList(u32) = .empty;
            for (m.ir.extraSlice(f.params(), u32), flags) |n, gone| if (!gone) try kept.append(s.arena, n);
            const start = try m.append(s.gpa, kept.items);
            const at = @backingInt(decl.func.?);
            const fact3 = m.fact3;
            within(m, decl.stmt);
            m.changed();
            try s.leave(m);
            if (kept_drop[g]) m.fact3 = fact3;
            m.extra.items[at] = start;
            m.extra.items[at + 1] = start + @as(u32, @intCast(kept.items.len));
            any = true;
        }
        if (!any) return false;
        // Every call of such a function the patched program still makes. Found
        // by walking it again rather than from the analysis's list: a folded
        // conditional may have become a copy of a call, and the copy is the
        // one that is reached. None in a module that names none of the
        // functions that lost one: a call of one names it.
        const lost = try s.arena.alloc(bool, s.globals);
        @memset(lost, false);
        for (s.decl, 0..) |maybe, g| {
            const decl = maybe orelse continue;
            if (decl.func == null) continue;
            if (std.mem.indexOfScalar(bool, drop[decl.params..][0..decl.arity], true) != null) lost[g] = true;
        }
        for (s.mods) |*m| {
            const names = for (m.global) |g| {
                if (g != none and g < lost.len and lost[g]) break true;
            } else false;
            if (names) try s.rewriteCalls(m, drop, kept_drop);
        }
        // The parameters left, numbered anew.
        for (s.decl, lost) |*maybe, l| {
            if (!l) continue;
            const decl = &(maybe.* orelse continue);
            const flags = drop[decl.params..][0..decl.arity];
            const first: u32 = @intCast(s.params.items.len);
            var left: u32 = 0;
            for (flags, 0..) |gone, i| if (!gone) {
                try s.params.append(s.arena, s.params.items[decl.params + i]);
                try s.arg_effect.append(s.arena, s.arg_effect.items[decl.params + i]);
                left += 1;
            };
            decl.params = first;
            decl.arity = left;
        }
        return true;
    }

    /// Unused trailing arguments: a call whose callee fact 3 says may be
    /// only functions of the program passes nothing any of them reads past
    /// the last parameter one of them reads, so a trailing run of arguments
    /// that do nothing (`effectFree`) goes. The functions keep their
    /// parameters: a call this cannot see may still pass them. Run once,
    /// after every round, on the facts of the last.
    fn trimArguments(s: *Spec) Allocator.Error!void {
        if (!s.pts.ok) return;
        // Per site: how many leading parameters its function may read, or
        // `none` before it is asked.
        const needs = try s.arena.alloc(u32, s.pts.sites.items.len);
        @memset(needs, none);
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        const saved_top = s.cur_top;
        defer s.cur_top = saved_top;
        for (s.mods) |*m| {
            const ir = m.ir;
            const vals = s.pts.vals[m.index];
            // A copy: a trimmed call appends to `extra`, which moves.
            const body = try s.arena.dupe(Index, ir.extraSlice(ir.body, Index));
            for (body) |top| {
                s.cur_top = top;
                stack.clearRetainingCapacity();
                try JsIr.pushOperand(s.arena, &stack, top);
                while (JsIr.popOperand(&stack)) |node| {
                    if (ir.tag(node) == .call) try s.trimCall(m, vals, node, needs);
                    try pushChildren(s.arena, ir, node, &stack);
                }
            }
        }
    }

    fn trimCall(s: *Spec, m: *Mod, vals: []const Pts.Val, node: Index, needs: []u32) Allocator.Error!void {
        const ir = m.ir;
        const d = ir.data(node);
        const callee: Index = @fromBackingInt(@intCast(d.lhs));
        // Invariant: JsIr has no rest and no default parameters, so a missing
        // argument and a passed `undefined` bind alike; this must change if
        // either is ever added.
        // A trailing `undefined` passed to a callee that is only arrows of
        // the program is what a missing argument is: an arrow has no
        // `arguments` to count them by (`backend.md` §9, *Trimmed arguments*,
        // amended 2026-10-17).
        if (callee.int() < vals.len) trailing: {
            const vt = vals[callee.int()];
            if (vt.top or vt.prim or vt.nullish() or vt.sites.len == 0) break :trailing;
            for (vt.sites) |site| {
                const st = &s.pts.sites.items[site];
                if (st.kind != .func or s.mods[st.module].ir.tag(st.node) != .arrow) break :trailing;
            }
            const all = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), u32);
            var keep = all.len;
            while (keep > 0 and ir.tag(@fromBackingInt(@intCast(all[keep - 1]))) == .undefined_lit) keep -= 1;
            if (keep != all.len) {
                const kept = try s.arena.dupe(u32, all[0..keep]);
                const start = try m.append(s.gpa, kept);
                const rec = try m.append(s.gpa, &.{ start, start + @as(u32, @intCast(keep)) });
                m.setData(node, d.lhs, rec);
                return;
            }
        }
        // A function fact 1 tracks is called with its arity, or every
        // parameter of it is ⊤; its unread parameters go by `rewrite`.
        if (ir.tag(callee) == .ident) if (m.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs)))) |g| if (s.decl[g]) |decl| if (decl.func != null) return;
        if (callee.int() >= vals.len) return;
        const vc = vals[callee.int()];
        if (vc.top or vc.prim or vc.sites.len == 0) return;
        const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), u32);
        var need: u32 = 0;
        for (vc.sites) |site| {
            const st = &s.pts.sites.items[site];
            if (st.kind != .func) return;
            if (needs[site] == none) needs[site] = try s.paramsRead(st.module, st.node);
            need = @max(need, needs[site]);
        }
        if (args.len <= need) return;
        var keep = args.len;
        while (keep > need and try s.effectFree(m, @fromBackingInt(@intCast(args[keep - 1])))) keep -= 1;
        if (keep == args.len) return;
        const kept = try s.arena.dupe(u32, args[0..keep]);
        const start = try m.append(s.gpa, kept);
        const record = try m.append(s.gpa, &.{ start, start + @as(u32, @intCast(keep)) });
        m.setData(node, d.lhs, record);
    }

    /// One more than the position of the last parameter function `node`
    /// (an arrow or a declaration) mentions anywhere in its body, or 0:
    /// an over-count — a shadowing name read as the parameter — only keeps
    /// an argument.
    fn paramsRead(s: *Spec, module: u32, node: Index) Allocator.Error!u32 {
        const ir = s.mods[module].ir;
        const record: ExtraIndex = switch (ir.tag(node)) {
            .arrow => @fromBackingInt(@intCast(ir.data(node).lhs)),
            .func_decl, .gen_decl => @fromBackingInt(@intCast(ir.data(node).rhs)),
            else => return std.math.maxInt(u32),
        };
        const f = ir.extraData(record, JsIr.Func);
        const params = ir.extraSlice(f.params(), NameIndex);
        var need: u32 = 0;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperandSlice(s.arena, &stack, ir.extraSlice(f.body(), Index));
        while (JsIr.popOperand(&stack)) |n| {
            if (ir.tag(n) == .ident) if (std.mem.indexOfScalar(NameIndex, params, @fromBackingInt(@intCast(ir.data(n).lhs)))) |p| {
                need = @max(need, @as(u32, @intCast(p)) + 1);
            };
            try pushChildren(s.arena, ir, n, &stack);
        }
        return need;
    }

    /// Per parameter of a function `Spec` tracks: some call of it, in the
    /// program as it now stands, passes an argument whose evaluation may do
    /// something (`effectFree`).
    fn argEffects(s: *Spec) Allocator.Error![]bool {
        const effect = try s.arena.alloc(bool, s.params.items.len);
        @memset(effect, false);
        const saved_top = s.cur_top;
        defer s.cur_top = saved_top;
        for (s.mods) |*m| {
            const ir = m.ir;
            for (ir.extraSlice(ir.body, Index)) |top| {
                s.cur_top = top;
                for (try s.preorder(m, top)) |node| {
                    if (ir.tag(node) != .call) continue;
                    const callee: Index = @fromBackingInt(@intCast(ir.data(node).lhs));
                    if (ir.tag(callee) != .ident) continue;
                    const g = m.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs))) orelse continue;
                    const decl = s.decl[g] orelse continue;
                    if (decl.func == null) continue;
                    const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(node).rhs))), Index);
                    if (args.len != decl.arity) continue;
                    for (args, 0..) |a, i| {
                        const e = &effect[decl.params + i];
                        if (!e.* and !try s.effectFree(m, a)) e.* = true;
                    }
                }
            }
        }
        return effect;
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
        const referenced = try s.arena.alloc(bool, s.globals);
        @memset(referenced, false);
        const live = try s.arena.alloc(bool, s.globals);
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
                        const imp = m.ir.extraData(@fromBackingInt(@intCast(at)), JsIr.Import);
                        const specs = m.ir.extraSlice(imp.specs(), JsIr.Specifier);
                        var out: std.ArrayList(u32) = .empty;
                        for (specs) |spec| {
                            if (m.globalOf(spec.local)) |g| if (!referenced[g]) continue;
                            try out.appendSlice(s.arena, &.{ @backingInt(spec.imported), @backingInt(spec.local) });
                        }
                        if (out.items.len != specs.len * JsIr.Specifier.words) {
                            const start = try m.append(s.gpa, out.items);
                            within(m, stmt);
                            m.changed();
                            try s.leave(m);
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
                            try out.append(s.arena, @backingInt(n));
                        }
                        if (out.items.len != names.len) {
                            const start = try m.append(s.gpa, out.items);
                            within(m, stmt);
                            m.setData(stmt, start, start + @as(u32, @intCast(out.items.len)));
                            try s.leave(m);
                            any = true;
                        }
                    },
                    else => {},
                }
                try kept.append(s.arena, @backingInt(stmt));
            }
            if (!dropped) continue;
            const start = try m.append(s.gpa, kept.items);
            m.bodyChanged();
            m.ir.body = .{ .start = @fromBackingInt(@intCast(start)), .end = @fromBackingInt(@intCast(start + @as(u32, @intCast(kept.items.len)))) };
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
            .const_decl => @fromBackingInt(@intCast(d.rhs)),
            .let_decl => @as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap(),
            .func_decl, .gen_decl => null,
            else => return null,
        };
        const g = m.globalOf(@fromBackingInt(@intCast(d.lhs))) orelse return null;
        const decl = s.decl[g] orelse return null;
        if (decl.stmt != stmt or &s.mods[decl.module] != m) return null;
        if (value) |v| if (!inert(ir, v)) return null;
        return g;
    }

    /// Every whole-program name `stmt` mentions — read, called or assigned —
    /// marked referenced and queued.
    fn references(s: *Spec, m: *Mod, stmt: Index, referenced: []bool, work: *std.ArrayList(u32)) Allocator.Error!void {
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, stmt);
        while (JsIr.popOperand(&stack)) |node| {
            const ir = m.ir;
            const d = ir.data(node);
            // Tested with `==`, not a `switch` with an `else` prong
            // (`TagSet`).
            const t = ir.tag(node);
            if (t == .ident) {
                if (m.globalOf(@fromBackingInt(@intCast(d.lhs)))) |g| if (!referenced[g]) {
                    referenced[g] = true;
                    try work.append(s.arena, g);
                };
            } else if (t == .arrow) {
                const f = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Func);
                for (ir.extraSlice(f.body(), Index)) |b| try JsIr.pushOperand(s.arena, &stack, b);
            } else if (t == .assign_stmt) {
                try JsIr.pushOperand(s.arena, &stack, @fromBackingInt(@intCast(d.lhs)));
                try JsIr.pushOperand(s.arena, &stack, @fromBackingInt(@intCast(d.rhs)));
            } else if (t == .import_stmt or t == .export_stmt) {} else if (t.isStatement())
                try s.pushStmtExprs(m, node, &stack)
            else
                try ir.pushOperands(s.arena, &stack, node);
        }
    }

    fn rewriteCalls(s: *Spec, m: *Mod, drop: []const bool, kept_drop: []const bool) Allocator.Error!void {
        var seen: std.DynamicBitSetUnmanaged = try .initEmpty(s.arena, m.ir.nodes.len);
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        // A statement at a time, each change its own (`Mod.kept`).
        const body = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.body, Index));
        for (body) |top| {
            within(m, top);
            try JsIr.pushOperand(s.arena, &stack, top);
            try s.callsBelow(m, drop, kept_drop, &seen, &stack);
            try s.leave(m);
        }
    }

    fn callsBelow(s: *Spec, m: *Mod, drop: []const bool, kept_drop: []const bool, seen: *std.DynamicBitSetUnmanaged, stack: *std.ArrayList(Index)) Allocator.Error!void {
        while (JsIr.popOperand(stack)) |node| {
            const ir = m.ir;
            const tag = ir.tag(node);
            if (tag.isStatement()) {
                try s.pushStmtExprs(m, node, stack);
                continue;
            }
            if (seen.isSet(node.int())) continue;
            seen.set(node.int());
            switch (tag) {
                .arrow => {
                    const f = ir.extraData(@fromBackingInt(@intCast(ir.data(node).lhs)), JsIr.Func);
                    for (ir.extraSlice(f.body(), Index)) |b| try JsIr.pushOperand(s.arena, stack, b);
                    continue;
                },
                .call => {
                    const d = ir.data(node);
                    const callee: Index = @fromBackingInt(@intCast(d.lhs));
                    if (ir.tag(callee) == .ident) if (m.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs)))) |g| if (s.decl[g]) |decl| if (decl.func != null) {
                        const flags = drop[decl.params..][0..decl.arity];
                        const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), u32);
                        if (args.len == decl.arity and std.mem.indexOfScalar(bool, flags, true) != null) {
                            // Asked before `append`, which may move `args`.
                            const keep_args = kept_drop[g] and try s.keepArgs(m, args, flags);
                            var kept: std.ArrayList(u32) = .empty;
                            for (args, flags) |a, gone| if (gone) try s.noteGone(m, @fromBackingInt(a));
                            for (args, flags) |a, gone| if (!gone) try kept.append(s.arena, a);
                            const start = try m.append(s.gpa, kept.items);
                            const record = try m.append(s.gpa, &.{ start, start + @as(u32, @intCast(kept.items.len)) });
                            const fact3 = m.fact3;
                            m.setData(node, d.lhs, record);
                            if (keep_args) m.fact3 = fact3;
                        }
                    };
                },
                else => {},
            }
            try m.ir.pushOperands(s.arena, stack, node);
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
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
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
            // Tested with a table and `==`, not a `switch` with an `else`
            // prong (`TagSet`).
            if (patch_leaves[@backingInt(tag)]) continue;
            // A store's target is no read: its object and its value are
            // patched, never the property it writes (`pushStmtExprs`'s
            // rule for an `assign_stmt`).
            if (tag == .assign) {
                const d = ir.data(node);
                try JsIr.pushOperand(s.arena, &stack, @fromBackingInt(@intCast(d.rhs)));
                try ir.pushOperands(s.arena, &stack, @fromBackingInt(@intCast(d.lhs)));
                continue;
            }
            if (tag == .arrow) {
                const f = ir.extraData(@fromBackingInt(@intCast(ir.data(node).lhs)), JsIr.Func);
                for (ir.extraSlice(f.body(), Index)) |b| try JsIr.pushOperand(s.arena, &stack, b);
                continue;
            }
            // Fact 3: a key no reachable read reaches goes from its
            // literal, when its value does nothing.
            if (tag == .object) _ = try s.dropKeys(m, node) else if (tag == .call) try s.appendChild(m, node);
            // What this reports is whether the program SHRANK in a way the
            // next round's facts can see: a branch or a read gone. A name or
            // an operator written as its value takes no call site, no
            // assignment and no read with it (`prune` sees the name's
            // reference go) — but for the reads of whole-program names
            // below it, which `rewrite` weighs on its own (`folded_reads`).
            const was = ir.tag(node);
            const shrinks = was == .member or was == .cond or (was == .binary and switch (@as(JsIr.BinaryOp, @fromBackingInt(@intCast(ir.data(node).rhs)))) {
                .logical_and, .logical_or => true,
                else => false,
            });
            const v = m.memo[node.int()];
            if (v.state == .lit) {
                // The whole-program names read below `node`, which a fold
                // takes out of the program with it (`again`).
                const reads_at = s.fold_reads.items.len;
                if (tag != .ident) try s.globalReads(m, node);
                if (try s.patchLiteral(m, node, v, m.objects.isSet(node.int()))) {
                    for (s.fold_reads.items[reads_at..]) |g| if (g < s.folded_reads.len) {
                        s.folded_reads[g] += 1;
                    };
                    s.fold_reads.shrinkRetainingCapacity(reads_at);
                    if (shrinks) any = true;
                    continue;
                }
                s.fold_reads.shrinkRetainingCapacity(reads_at);
            }
            // A conditional or a logical operator whose left side decides.
            const d = ir.data(node);
            if (tag == .member or tag == .index_get) {
                if (!m.objects.isSet(d.lhs)) {
                    m.objects.set(d.lhs);
                    try marked.append(s.arena, d.lhs);
                }
            } else if (tag == .cond) {
                // Fact 5's second case: the branch the test takes is the
                // read it tested.
                if (try s.decidedBranch(m, node)) |b| {
                    try m.foldTo(s.gpa, node, b);
                    m.memo[node.int()] = m.memo[b.int()];
                    try JsIr.pushOperand(s.arena, &stack, node);
                    any = true;
                    continue;
                }
                const t = m.memo[d.lhs];
                // A literal test, or one always truthy or always falsy
                // whose evaluation does nothing.
                if (t.state == .lit or (s.truthOf(t) != .unknown and try s.effectFreeTest(m, @fromBackingInt(@intCast(d.lhs)), 0))) {
                    const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                    const taken: ?Index = switch (s.truthOf(t)) {
                        .yes => c.consequent,
                        .no => c.alternate,
                        .bot, .unknown => null,
                    };
                    if (taken) |b| {
                        try m.foldTo(s.gpa, node, b);
                        m.memo[node.int()] = m.memo[b.int()];
                        try JsIr.pushOperand(s.arena, &stack, node);
                        any = true;
                        continue;
                    }
                }
                // A test that may do something, always truthy or always
                // falsy: the arm it never takes is never evaluated
                // (*Executability*, *Reading off*), and is written as `0`.
                const decided_truth = s.truthOf(t);
                if (t.state != .bot and (decided_truth == .yes or decided_truth == .no)) {
                    const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                    const dead = if (decided_truth == .yes) c.alternate else c.consequent;
                    if (try s.writeDead(m, dead)) any = true;
                }
            } else if (tag == .binary) {
                const op: JsIr.BinaryOp = @fromBackingInt(@intCast(d.rhs));
                if (op == .logical_and or op == .logical_or) {
                    // `a || b` is `a` when `a` is always truthy, and `b`
                    // when `a` is always falsy and evaluating it does
                    // nothing; `a && b` the other way round.
                    const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                    const l = m.memo[b.left.int()];
                    const t = s.truthOf(l);
                    const a_ends: Lat.Truth = if (op == .logical_or) .yes else .no;
                    const kept: ?Index = if (t == a_ends and l.state != .lit)
                        b.left
                    else if (t == a_ends.not() and (l.state == .lit or try s.effectFreeTest(m, b.left, 0)))
                        b.right
                    else
                        null;
                    if (kept) |k| {
                        try m.foldTo(s.gpa, node, k);
                        m.memo[node.int()] = m.memo[k.int()];
                        try JsIr.pushOperand(s.arena, &stack, node);
                        any = true;
                        continue;
                    }
                }
            }
            try ir.pushOperands(s.arena, &stack, node);
        }
        return any;
    }

    /// An expression no execution evaluates written as `0`, the shortest
    /// literal, with the whole-program names it read (`folded_reads`). A
    /// literal already is left as it is.
    fn writeDead(s: *Spec, m: *Mod, node: Index) Allocator.Error!bool {
        switch (m.ir.tag(node)) {
            .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => return false,
            else => {},
        }
        const reads_at = s.fold_reads.items.len;
        defer s.fold_reads.shrinkRetainingCapacity(reads_at);
        try s.globalReads(m, node);
        const zero: Lat = .of(try s.intern(.{ .kind = .number, .bytes = "0" }));
        if (!try s.patchLiteral(m, node, zero, false)) return false;
        m.memo[node.int()] = zero;
        for (s.fold_reads.items[reads_at..]) |g| if (g < s.folded_reads.len) {
            s.folded_reads[g] += 1;
        };
        return true;
    }

    /// Whether every value `node` may have, by fact 3, is a primitive the
    /// program made — no object of its own, no host value — so that an
    /// operator applied to it runs no code.
    fn primitive(s: *Spec, m: *Mod, node: Index) bool {
        if (!s.pts.ok) return false;
        const vals = s.pts.vals[m.index];
        if (node.int() >= vals.len) return false;
        const v = vals[node.int()];
        return !v.top and v.sites.len == 0;
    }

    /// Whether evaluating `node` does nothing but make its value, so that a
    /// fold may skip it: `effectFree`'s literal, name, function or read
    /// through the program's own objects; `===`, `!==`, `!` and `typeof` of
    /// such; and `&&`, `||` and `?:` whose parts that are evaluated are such
    /// — a part the facts say is never reached (`y` in `x || true || y`) is
    /// not asked about.
    fn effectFreeTest(s: *Spec, m: *Mod, node: Index, depth: u32) Allocator.Error!bool {
        if (depth > 64) return false;
        const ir = m.ir;
        const d = ir.data(node);
        switch (ir.tag(node)) {
            .unary => return switch (@as(JsIr.UnaryOp, @fromBackingInt(@intCast(d.rhs)))) {
                .not, .type_of => s.effectFreeTest(m, @fromBackingInt(@intCast(d.lhs)), depth + 1),
                .neg => s.primitive(m, @fromBackingInt(@intCast(d.lhs))) and try s.effectFreeTest(m, @fromBackingInt(@intCast(d.lhs)), depth + 1),
                .yield => false,
            },
            .binary => {
                const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                const op: JsIr.BinaryOp = @fromBackingInt(@intCast(d.rhs));
                switch (op) {
                    .strict_eq, .strict_ne => return try s.effectFreeTest(m, b.left, depth + 1) and try s.effectFreeTest(m, b.right, depth + 1),
                    .logical_and, .logical_or => {
                        if (!try s.effectFreeTest(m, b.left, depth + 1)) return false;
                        const a_ends: Lat.Truth = if (op == .logical_or) .yes else .no;
                        if (s.truthOf(m.memo[b.left.int()]) == a_ends) return true;
                        return s.effectFreeTest(m, b.right, depth + 1);
                    },
                    // On primitives the program made, an operator converts
                    // nothing that could run code (no `valueOf`), and none
                    // of these throws.
                    .lt, .le, .gt, .ge, .loose_eq, .add, .sub, .mul, .div, .rem, .pow, .bit_and, .bit_or, .bit_xor, .shl, .sar, .shr => return s.primitive(m, b.left) and s.primitive(m, b.right) and
                        try s.effectFreeTest(m, b.left, depth + 1) and try s.effectFreeTest(m, b.right, depth + 1),
                    .instance_of => return false,
                }
            },
            .cond => {
                const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                const test_node: Index = @fromBackingInt(@intCast(d.lhs));
                if (!try s.effectFreeTest(m, test_node, depth + 1)) return false;
                const t = s.truthOf(m.memo[test_node.int()]);
                if (t != .no and !try s.effectFreeTest(m, c.consequent, depth + 1)) return false;
                if (t != .yes and !try s.effectFreeTest(m, c.alternate, depth + 1)) return false;
                return true;
            },
            else => return s.effectFree(m, node),
        }
    }

    /// Append to `fold_reads` the whole-program id of every name read in
    /// the expression `root`, short of a function's body (which no fold
    /// reaches: a function is not a literal).
    /// The whole-program names read below `root`, which a rewrite takes out
    /// of the program with it: counted off what `substitutes` weighs
    /// (`folded_reads`).
    fn noteGone(s: *Spec, m: *Mod, root: Index) Allocator.Error!void {
        if (s.folded_reads.len == 0) return;
        const at = s.fold_reads.items.len;
        defer s.fold_reads.shrinkRetainingCapacity(at);
        try s.globalReads(m, root);
        for (s.fold_reads.items[at..]) |g| if (g < s.folded_reads.len) {
            s.folded_reads[g] += 1;
        };
    }

    fn globalReads(s: *Spec, m: *Mod, root: Index) Allocator.Error!void {
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, root);
        while (JsIr.popOperand(&stack)) |node| {
            if (m.ir.tag(node) == .ident) {
                if (m.globalOf(@fromBackingInt(@intCast(m.ir.data(node).lhs)))) |g| try s.fold_reads.append(s.arena, g);
                continue;
            }
            try m.ir.pushOperands(s.arena, &stack, node);
        }
    }

    /// The expressions a statement evaluates, and its nested statements,
    /// onto `stack` — but never an assignment's target name.
    fn pushStmtExprs(s: *Spec, m: *Mod, stmt: Index, stack: *std.ArrayList(Index)) Allocator.Error!void {
        const ir = m.ir;
        const d = ir.data(stmt);
        switch (ir.tag(stmt)) {
            .const_decl => try JsIr.pushOperand(s.arena, stack, @fromBackingInt(@intCast(d.rhs))),
            .let_decl => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| try JsIr.pushOperand(s.arena, stack, v),
            .func_decl, .gen_decl => {
                const f = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Func);
                for (ir.extraSlice(f.body(), Index)) |b| try JsIr.pushOperand(s.arena, stack, b);
            },
            .assign_stmt => {
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                if (ir.tag(target) != .ident) try ir.pushOperands(s.arena, stack, target);
                try JsIr.pushOperand(s.arena, stack, @fromBackingInt(@intCast(d.rhs)));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try JsIr.pushOperand(s.arena, stack, v),
            .if_stmt => {
                try JsIr.pushOperand(s.arena, stack, @fromBackingInt(@intCast(d.lhs)));
                const branches = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                for (ir.extraSlice(branches.thenBody(), Index)) |b| try JsIr.pushOperand(s.arena, stack, b);
                for (ir.extraSlice(branches.elseBody(), Index)) |b| try JsIr.pushOperand(s.arena, stack, b);
            },
            .while_true, .block_stmt, .switch_case => {
                if (ir.tag(stmt) == .switch_case) if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| try JsIr.pushOperand(s.arena, stack, t);
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |b| try JsIr.pushOperand(s.arena, stack, b);
            },
            .for_of => {
                const f = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                try JsIr.pushOperand(s.arena, stack, f.iterable);
                for (ir.extraSlice(f.body(), Index)) |b| try JsIr.pushOperand(s.arena, stack, b);
            },
            .switch_stmt => {
                try JsIr.pushOperand(s.arena, stack, @fromBackingInt(@intCast(d.lhs)));
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |c| try JsIr.pushOperand(s.arena, stack, c);
            },
            .expr_stmt, .throw_stmt => try JsIr.pushOperand(s.arena, stack, @fromBackingInt(@intCast(d.lhs))),
            .try_stmt => {
                const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                for (ir.extraSlice(t.body(), Index)) |b| try JsIr.pushOperand(s.arena, stack, b);
                for (ir.extraSlice(t.finalBody(), Index)) |b| try JsIr.pushOperand(s.arena, stack, b);
                for (ir.extraSlice(t.catchBody(), Index)) |b| try JsIr.pushOperand(s.arena, stack, b);
            },
            else => {},
        }
    }

    /// Whether member read `node` reads a property of a parameter of the
    /// declaration being rewritten that nothing else in it reads or assigns.
    fn lastParamRead(s: *Spec, m: *Mod, node: Index) bool {
        const object: Index = @fromBackingInt(@intCast(m.ir.data(node).lhs));
        if (m.ir.tag(object) != .ident) return false;
        const n: NameIndex = @fromBackingInt(@intCast(m.ir.data(object).lhs));
        if (m.globalOf(n) != null) return false;
        const i = n.unwrap() orelse return false;
        if (i >= m.stamp.len or m.stamp[i] != s.current) return false;
        return m.param[i] != none and m.uses[i] == 1 and !m.assigned[i];
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
            // Longer, when the read is a parameter's only one: the
            // parameter then goes, and its argument at every call.
            if (printedLen(lit) > 5 and !s.lastParamRead(m, node)) return false;
            if (object_position and (lit.kind == .null_lit)) return false;
        }
        if (ir.tag(node) == .ident) {
            const n: NameIndex = @fromBackingInt(@intCast(ir.data(node).lhs));
            const global = m.globalOf(n);
            const uses: u32 = if (global) |g| s.reads[g] else if (n.unwrap()) |i| (if (i < m.stamp.len and m.stamp[i] == s.current) m.uses[i] else 2) else 2;
            if (!substitutes(lit, uses)) {
                if (global == null) s.refused_local = true;
                if (global) |g| if (m.scope) |top| try s.declined.append(s.arena, .{ .g = g, .lit = lit, .v = v, .module = m.index, .top = top, .node = node, .object_position = object_position });
                return false;
            }
        }
        // A write fact 3 cannot see does not ask it to solve again (#575).
        const neutral = s.fact3Neutral(m, node, lit, object_position);
        const fact3 = m.fact3;
        defer if (neutral) {
            m.fact3 = fact3;
        };
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
                const g = nameId(lit);
                // An identifier of `g` written as `g`: the module mentions
                // `g` right here, so when this is its one name of `g`, it is
                // the name `namedIn` would find.
                if (ir.tag(node) == .ident) {
                    const here: NameIndex = @fromBackingInt(@intCast(ir.data(node).lhs));
                    if (m.globalOf(here) == g) if (try s.onlyName(m, g)) |only| if (only == here) {
                        const gop = try s.name_in.getOrPut(s.arena, .{ .site = m.index, .prop = g });
                        if (!gop.found_existing) gop.value_ptr.* = here.int();
                    };
                }
                const n = try s.nameIn(m, g) orelse return false;
                if (ir.tag(node) == .ident and ir.data(node).lhs == n.int()) return false;
                m.setNode(node, .ident, n.int(), 0);
            },
        }
        return true;
    }

    /// A top-level binding of module `m` that a body written there declares
    /// (`Copy.fresh`): a whole-program name of its own, as every declaration
    /// the pass was handed has. Without one, each top-level statement read it
    /// as a different local, so what it holds reached no read of it, and the
    /// facts dropped keys that are read.
    fn addGlobal(s: *Spec, m: *Mod, at: NameIndex) Allocator.Error!void {
        const g = s.globals;
        s.globals += 1;
        s.decl = try growSlice(s.arena, ?Decl, s.decl, s.globals, null);
        s.escaped = try growSlice(s.arena, bool, s.escaped, s.globals, false);
        s.assigned = try growSlice(s.arena, bool, s.assigned, s.globals, false);
        s.reads = try growSlice(s.arena, u32, s.reads, s.globals, 0);
        s.copied = try growSlice(s.arena, bool, s.copied, s.globals, false);
        if (m.global_list.items.len == 0) try m.global_list.appendSlice(s.arena, m.global);
        while (m.global_list.items.len < at.int()) try m.global_list.append(s.arena, none);
        try m.global_list.append(s.arena, g);
        m.global = m.global_list.items;
        m.namesChanged();
    }

    /// Slice 6: the value of a declaration's name, `name` and its id.
    fn nameLat(s: *Spec, g: u32) Allocator.Error!Lat {
        if (g >= s.name_lits.len) s.name_lits = try growSlice(s.arena, u32, s.name_lits, @max(s.globals, g + 1), none);
        const cached = &s.name_lits[g];
        if (cached.* == none) {
            const bytes = std.mem.toBytes(g);
            cached.* = try s.intern(.{ .kind = .name, .bytes = &bytes });
        }
        return .of(cached.*);
    }

    fn nameId(lit: Lit) u32 {
        return std.mem.bytesToValue(u32, lit.bytes[0..4]);
    }

    /// Module `m`'s name for whole-program name `g`, when a live statement
    /// of it already mentions `g` (`namedIn`), so writing it needs no import
    /// the module lacks; cached for the round's rewrite.
    /// Whether `nameIn` would answer for `g` in `m`, without adding a name.
    fn canName(s: *Spec, m: *Mod, g: u32) Allocator.Error!bool {
        if (s.name_in.get(.{ .site = m.index, .prop = g })) |v| return v != none;
        if (try s.namedIn(m, g) != null) return true;
        if (!s.in.one_scope) return false;
        if (s.decl[g] != null) return true;
        for (s.mods) |*other| for (other.global) |og| if (og == g) return true;
        return false;
    }

    fn nameIn(s: *Spec, m: *Mod, g: u32) Allocator.Error!?NameIndex {
        const gop = try s.name_in.getOrPut(s.arena, .{ .site = m.index, .prop = g });
        if (!gop.found_existing) {
            gop.value_ptr.* = if (try s.namedIn(m, g)) |n| n.int() else none;
            // In one scope-hoisted file every top-level name is one binding
            // of the one scope, spelled from its `Name` alone: the
            // declaring module's, copied in.
            // A hand-written file's binding no module declares: the name a
            // module imports it by, the same `Name` wherever it is copied
            // (the import stays while any module names it: `prune`).
            const known: ?JsIr.Name = if (s.decl[g]) |decl| blk: {
                const dm = &s.mods[decl.module];
                break :blk dm.ir.name(@fromBackingInt(@intCast(dm.ir.data(decl.stmt).lhs)));
            } else found: for (s.mods) |*other| {
                for (other.global, 0..) |og, oi| if (og == g) break :found other.names.items[oi];
            } else null;
            if (gop.value_ptr.* == none and s.in.one_scope) if (known) |name| {
                const at = try m.addName(s.gpa, name);
                if (m.global_list.items.len == 0) try m.global_list.appendSlice(s.arena, m.global);
                while (m.global_list.items.len < at.int()) try m.global_list.append(s.arena, none);
                try m.global_list.append(s.arena, g);
                m.global = m.global_list.items;
                m.namesChanged();
                gop.value_ptr.* = at.int();
            };
        }
        return if (gop.value_ptr.* == none) null else @fromBackingInt(@intCast(gop.value_ptr.*));
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
            if (try s.foldBelow(m, @fromBackingInt(@intCast(raw)), depth)) any = true;
        }
        // Then this one.
        var changed = false;
        for (items) |raw| {
            if (try s.decided(m, @fromBackingInt(@intCast(raw))) != null or try s.deadWrite(m, @fromBackingInt(@intCast(raw))) or literalStmt(m.ir, @fromBackingInt(@intCast(raw)))) changed = true;
        }
        if (!changed) {
            // What follows a statement that cannot complete, when it may go.
            const keep = try s.deadTail(m, owner, items);
            if (keep == items.len) return any;
            try s.setList(m, owner, items[0..keep]);
            return true;
        }
        var out: std.ArrayList(u32) = .empty;
        defer out.deinit(s.arena);
        for (items) |raw| {
            const stmt: Index = @fromBackingInt(@intCast(raw));
            // A literal standing as a statement does nothing: what is left
            // of a value folded where nothing reads it (a function written
            // in whose last `return` folded to `null`).
            if (literalStmt(m.ir, stmt)) continue;
            // Fact 3: a write of a property no reachable read reaches is not
            // written, nor one of a variable nothing reads; its value is
            // still evaluated when it may do something.
            if (try s.deadWrite(m, stmt)) {
                const value: Index = @fromBackingInt(@intCast(m.ir.data(stmt).rhs));
                // A read of a program object's property does nothing
                // either: no getter, no throw (`Pts.safeChain`); nor does a
                // call of functions that only make a value (`pureCall`).
                if (try s.effectFree(m, value)) continue;
                m.setNode(stmt, .expr_stmt, value.int(), 0);
                try out.append(s.arena, raw);
                continue;
            }
            const decision = try s.decided(m, stmt) orelse {
                try out.append(s.arena, raw);
                continue;
            };
            const arm = decision.arm;
            if (decision.test_kept) |t| {
                // `T; …arm`, the `if` node reused for `T`.
                m.setNode(stmt, .expr_stmt, t.int(), 0);
                try out.append(s.arena, raw);
                try out.appendSlice(s.arena, m.ir.extraSlice(arm, u32));
                continue;
            }
            if (arm.len() == 0) continue;
            if (s.spliceable(m, arm)) {
                try out.appendSlice(s.arena, m.ir.extraSlice(arm, u32));
                continue;
            }
            // A block of its own: the arm declares a name the declaration
            // declares elsewhere too.
            const at = try m.append(s.gpa, &.{ @backingInt(arm.start), @backingInt(arm.end) });
            m.setNode(stmt, .block_stmt, @backingInt(NameIndex.none), at);
            try out.append(s.arena, raw);
        }
        // An arm kept in place of its `if` may end in a jump (`if (x ||
        // true) return false;`), and what followed the `if` goes with it.
        try s.setList(m, owner, out.items[0..try s.deadTail(m, owner, out.items)]);
        return true;
    }

    /// Write `items` as the statement list whose range lives at `owner`
    /// (two words of `extra`), or as the module's body when null.
    fn setList(s: *Spec, m: *Mod, owner: ?u32, items: []const u32) Allocator.Error!void {
        const start = try m.append(s.gpa, items);
        const end: u32 = start + @as(u32, @intCast(items.len));
        m.changed();
        if (owner) |o| {
            m.extra.items[o] = start;
            m.extra.items[o + 1] = end;
        } else {
            m.ir.body = .{ .start = @fromBackingInt(@intCast(start)), .end = @fromBackingInt(@intCast(end)) };
        }
    }

    /// How many statements of `list` may run: all of them, or those up to
    /// the first that cannot complete normally (`completes`) when what
    /// follows it may go — nothing outside it in the declaration being
    /// rewritten names or declares what it declares, so no earlier
    /// statement, no closure and no hoisted `function` can reach it. A
    /// module's body is kept whole: its names are the program's.
    fn deadTail(s: *Spec, m: *Mod, owner: ?u32, list: []const u32) Allocator.Error!usize {
        if (owner == null or list.len < 2) return list.len;
        for (list[0 .. list.len - 1], 0..) |raw, i| {
            if (completes(m.ir, @fromBackingInt(@intCast(raw)), 0)) continue;
            return if (try s.tailUnnamed(m, list[i + 1 ..])) i + 1 else list.len;
        }
        return list.len;
    }

    /// Whether nothing outside the statements `tail`, in the top-level
    /// statement being rewritten (`cur_top`), declares or mentions a name
    /// `tail` declares.
    fn tailUnnamed(s: *Spec, m: *Mod, tail: []const u32) Allocator.Error!bool {
        const names = m.names.items.len;
        // Per name: its declarations, then its mentions.
        const in_tail = try s.arena.alloc(u32, 2 * names);
        @memset(in_tail, 0);
        var decls_in_tail: std.ArrayList(u32) = .empty;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        for (tail) |raw| try JsIr.pushOperand(s.arena, &stack, @fromBackingInt(@intCast(raw)));
        while (JsIr.popOperand(&stack)) |node| {
            try nameUses(s.arena, m.ir, node, in_tail, &decls_in_tail);
            try pushChildren(s.arena, m.ir, node, &stack);
        }
        if (decls_in_tail.items.len == 0) return true;
        const whole = try s.arena.alloc(u32, 2 * names);
        @memset(whole, 0);
        var all: std.ArrayList(u32) = .empty;
        for (try s.preorder(m, s.cur_top)) |node| try nameUses(s.arena, m.ir, node, whole, &all);
        for (decls_in_tail.items) |x| {
            if (m.globalOf(@fromBackingInt(@intCast(x))) != null) return false;
            if (whole[2 * x] != in_tail[2 * x] or whole[2 * x + 1] != in_tail[2 * x + 1]) return false;
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
        const callee: Index = @fromBackingInt(@intCast(d.lhs));
        if (ir.tag(callee) != .member) return;
        if (s.pts.propId(m.index, @fromBackingInt(@intCast(ir.data(callee).rhs))) != ids.insert_before) return;
        const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index);
        if (args.len != 2) return;
        const r = args[1];
        switch (ir.tag(r)) {
            .null_lit, .ident => {},
            else => return,
        }
        const v = m.memo[r.int()];
        if (v.state != .lit or s.litOf(v).kind != .null_lit) return;
        // No object of the program. A primitive, `null` or `undefined` has
        // neither method, and both calls throw a `TypeError` there, as they
        // already did for `null`: fact 3 says what a host value may be
        // beside a node (`Pts.Val.top_val`), not that it is one.
        const receiver = s.pts.vals[m.index][ir.data(callee).lhs];
        if (receiver.sites.len != 0) return;
        // The module's name for `appendChild` (every plain name is in the
        // session's pool by now), made when it has none; the callee is
        // rewritten in place, so no node is added while the facts' tables
        // are sized.
        const want: JsIr.Name = .{ .module = .none, .base = ids.append_child, .tag = JsIr.Name.no_tag };
        const name: NameIndex = for (m.names.items, 0..) |x, i| {
            if (x.eql(want)) break @fromBackingInt(@intCast(@as(u32, @intCast(i))));
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
                const id = s.pts.propId(m.index, @fromBackingInt(@intCast(d.lhs)));
                if (s.pts.keyUnread(m.index, node, id) and try s.effectFree(m, @fromBackingInt(@intCast(d.rhs)))) {
                    try s.noteGone(m, @fromBackingInt(@intCast(d.rhs)));
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
        const ir = m.ir;
        if (ir.tag(stmt) != .assign_stmt) return false;
        const target: Index = @fromBackingInt(@intCast(ir.data(stmt).lhs));
        if (ir.tag(target) == .ident) return s.unreadName(m, @fromBackingInt(@intCast(ir.data(target).lhs)));
        if (!s.pts.ok) return false;
        if (ir.tag(target) != .member) return false;
        const td = ir.data(target);
        const obj = try s.pts.chain(m.index, s.cur_top, @fromBackingInt(@intCast(td.lhs))) orelse return false;
        if (s.pts.neverRead(obj, s.pts.propId(m.index, @fromBackingInt(@intCast(td.rhs))))) return true;
        // Slice 8: `x.p = x.p` on program objects — no getter, no setter,
        // no throw — changes nothing (an identity written in place).
        return sameChain(ir, target, @fromBackingInt(@intCast(ir.data(stmt).rhs))) and try s.pts.safeChain(m.index, s.cur_top, target) != null;
    }

    /// Whether nothing reads the variable `n` an assignment writes, so that
    /// the write may go (`backend.md` §9, *A variable nothing reads*): a
    /// module-level `let` of the program that no statement reads and no
    /// file the pass cannot see reaches (`escaped`), by the reads the
    /// round's first sweep counted; or a local of the declaration being
    /// rewritten that nothing in it reads. A rewrite only takes reads away,
    /// so a count of none before it is none after.
    fn unreadName(s: *Spec, m: *Mod, n: NameIndex) bool {
        if (m.globalOf(n)) |g| {
            if (g >= s.reads.len or s.reads[g] != 0 or s.escaped[g]) return false;
            const decl = s.decl[g] orelse return false;
            return s.mods[decl.module].ir.tag(decl.stmt) == .let_decl;
        }
        const i = n.unwrap() orelse return false;
        return i < m.stamp.len and m.stamp[i] == s.current and m.uses[i] == 0;
    }

    /// The arm an `if` with a literal test takes, or null.
    const Decided = struct {
        arm: JsIr.SubRange,
        /// The test, still evaluated, as a statement before the arm: it is
        /// always truthy or always falsy, but evaluating it may do
        /// something. Null when evaluating it does nothing.
        test_kept: ?Index = null,
    };

    /// The arm an `if` takes when its test is a literal, or is always
    /// truthy or always falsy whatever its value (`x || true`, `Lat`'s
    /// truthiness), or null.
    fn decided(s: *Spec, m: *Mod, stmt: Index) Allocator.Error!?Decided {
        const ir = m.ir;
        if (ir.tag(stmt) == .switch_stmt) return chosenCase(ir, stmt);
        if (ir.tag(stmt) != .if_stmt) return null;
        const d = ir.data(stmt);
        const test_node: Index = @fromBackingInt(@intCast(d.lhs));
        const lit: ?Lit = switch (ir.tag(test_node)) {
            .true_lit => .{ .kind = .true_lit },
            .false_lit => .{ .kind = .false_lit },
            .null_lit => .{ .kind = .null_lit },
            .undefined_lit => .{ .kind = .undefined_lit },
            .number => .{ .kind = .number, .bytes = ir.bytes(test_node) },
            .string => .{ .kind = .string, .bytes = ir.bytes(test_node) },
            else => null,
        };
        const branches = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
        if (lit) |l| return switch (s.truthy(l)) {
            .yes => .{ .arm = branches.thenBody() },
            .no => .{ .arm = branches.elseBody() },
            .unknown => null,
        };
        // The facts of the statement just patched (`rewrite`).
        if (test_node.int() >= m.memo.len) return null;
        const arm = switch (s.truthOf(m.memo[test_node.int()])) {
            .yes => branches.thenBody(),
            .no => branches.elseBody(),
            .bot, .unknown => return null,
        };
        if (try s.effectFreeTest(m, test_node, 0)) return .{ .arm = arm };
        // `T; …arm`, the `if` node reused for `T`: only when the arm may
        // join the list, since a block would need a node of its own.
        if (arm.len() != 0 and !s.spliceable(m, arm)) return null;
        return .{ .arm = arm, .test_kept = test_node };
    }

    /// Whether an arm's statements may join the list around it: no name it
    /// declares at its own level is declared anywhere else in the
    /// declaration, so nothing in the list can come to mean it.
    fn spliceable(s: *Spec, m: *Mod, arm: JsIr.SubRange) bool {
        const ir = m.ir;
        for (ir.extraSlice(arm, Index)) |stmt| {
            const n: NameIndex = switch (ir.tag(stmt)) {
                .const_decl, .let_decl, .func_decl, .gen_decl => @fromBackingInt(@intCast(ir.data(stmt).lhs)),
                .while_true, .block_stmt => @fromBackingInt(@intCast(ir.data(stmt).lhs)),
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
            .const_decl => any = try s.foldExprLists(m, @fromBackingInt(@intCast(d.rhs)), depth),
            .let_decl => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| {
                any = try s.foldExprLists(m, v, depth);
            },
            .func_decl, .gen_decl => any = try s.foldFunc(m, @fromBackingInt(@intCast(d.rhs)), depth),
            .assign_stmt => {
                if (try s.foldExprLists(m, @fromBackingInt(@intCast(d.lhs)), depth)) any = true;
                if (try s.foldExprLists(m, @fromBackingInt(@intCast(d.rhs)), depth)) any = true;
            },
            .return_stmt, .expr_stmt, .throw_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| {
                any = try s.foldExprLists(m, v, depth);
            },
            .if_stmt => {
                if (try s.foldExprLists(m, @fromBackingInt(@intCast(d.lhs)), depth)) any = true;
                const at = d.rhs;
                const branches = ir.extraData(@fromBackingInt(@intCast(at)), JsIr.If);
                if (try s.foldList(m, at, branches.thenBody(), depth + 1)) any = true;
                const again = m.ir.extraData(@fromBackingInt(@intCast(at)), JsIr.If);
                if (try s.foldList(m, at + 2, again.elseBody(), depth + 1)) any = true;
            },
            .while_true, .block_stmt, .switch_case => {
                if (ir.tag(stmt) == .switch_case) if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| {
                    if (try s.foldExprLists(m, t, depth)) any = true;
                };
                if (try s.foldList(m, d.rhs, ir.subRange(@fromBackingInt(@intCast(d.rhs))), depth + 1)) any = true;
            },
            .for_of => {
                const f = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                if (try s.foldExprLists(m, f.iterable, depth)) any = true;
                // The body's range is the record's second and third words.
                if (try s.foldList(m, d.rhs + 1, m.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf).body(), depth + 1)) any = true;
            },
            .switch_stmt => {
                if (try s.foldExprLists(m, @fromBackingInt(@intCast(d.lhs)), depth)) any = true;
                const cases = try s.arena.dupe(Index, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index));
                for (cases) |c| {
                    if (try s.foldBelow(m, c, depth + 1)) any = true;
                }
            },
            // The three ranges are the record's words 0–1, 2–3 and 4–5,
            // the first two as an `if`'s are.
            .try_stmt => {
                const at = d.rhs;
                if (try s.foldList(m, at, ir.extraData(@fromBackingInt(@intCast(at)), JsIr.Try).body(), depth + 1)) any = true;
                if (try s.foldList(m, at + 2, m.ir.extraData(@fromBackingInt(@intCast(at)), JsIr.Try).finalBody(), depth + 1)) any = true;
                if (try s.foldList(m, at + 4, m.ir.extraData(@fromBackingInt(@intCast(at)), JsIr.Try).catchBody(), depth + 1)) any = true;
            },
            else => {},
        }
        return any;
    }

    fn foldFunc(s: *Spec, m: *Mod, record: ExtraIndex, depth: u32) Allocator.Error!bool {
        const at = @backingInt(record);
        return s.foldList(m, at + 2, m.ir.extraData(record, JsIr.Func).body(), depth + 1);
    }

    /// The function bodies inside an expression.
    fn foldExprLists(s: *Spec, m: *Mod, root: Index, depth: u32) Allocator.Error!bool {
        var any = false;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, root);
        while (JsIr.popOperand(&stack)) |node| {
            if (m.ir.tag(node) == .arrow) {
                if (try s.foldFunc(m, @fromBackingInt(@intCast(m.ir.data(node).lhs)), depth)) any = true;
                continue;
            }
            try m.ir.pushOperands(s.arena, &stack, node);
        }
        return any;
    }

    /// The bindings of `m` lowering kept for what their initialisers might
    /// do, whose initialisers do nothing by the facts (a literal, a name, a
    /// call of a function that only makes its value, a read through the
    /// program's own objects): kept no more, so that the liveness read-off
    /// (`liveness`), and the optimiser after it, drop one nothing reads.
    fn releaseKept(s: *Spec, m: *Mod) Allocator.Error!void {
        {
            const t = m.tables orelse return;
            // Slice 8: a read through program objects does nothing either
            // (`Pts.safeChain`, asked in the declaration that holds it):
            // per kept binding, that declaration.
            const nodes = m.ir.nodes.len;
            var kept_set: std.DynamicBitSetUnmanaged = .{};
            var top_of: []Index = &.{};
            var found: std.DynamicBitSetUnmanaged = .{};
            if (s.pts.ok and t.keep.items.len != 0) {
                kept_set = try .initEmpty(s.arena, nodes);
                for (t.keep.items) |node| if (node.int() < nodes) kept_set.set(node.int());
                top_of = try s.arena.alloc(Index, nodes);
                found = try .initEmpty(s.arena, nodes);
                for (m.ir.extraSlice(m.ir.body, Index)) |top| {
                    for (try s.preorder(m, top)) |node| {
                        if (node.int() < nodes and kept_set.isSet(node.int())) {
                            top_of[node.int()] = top;
                            found.set(node.int());
                        }
                    }
                }
            }
            var kept: usize = 0;
            for (t.keep.items) |node| {
                const value: ?Index = switch (m.ir.tag(node)) {
                    .const_decl => @fromBackingInt(@intCast(m.ir.data(node).rhs)),
                    .let_decl => @as(Node.OptionalIndex, @fromBackingInt(@intCast(m.ir.data(node).rhs))).unwrap(),
                    else => null,
                };
                if (value) |v| {
                    if (inert(m.ir, v)) continue;
                    // A call of a function that only makes its value, of
                    // arguments that do nothing (`pureCall`): a field of a
                    // kept context its scalar replacement left behind.
                    if (top_of.len != 0 and m.ir.tag(v) == .call and node.int() < nodes and v.int() < s.pts.vals[m.index].len and found.isSet(node.int())) {
                        const saved = s.cur_top;
                        s.cur_top = top_of[node.int()];
                        defer s.cur_top = saved;
                        if (try s.pureCall(m, v, 0)) continue;
                    }
                    if (top_of.len != 0 and m.ir.tag(v) == .member and node.int() < nodes and v.int() < s.pts.vals[m.index].len) {
                        // A binding no walk reached is in no top: kept.
                        const top = top_of[node.int()];
                        if (found.isSet(node.int()) and try s.pts.safeChain(m.index, top, v) != null) continue;
                    }
                }
                t.keep.items[kept] = node;
                kept += 1;
            }
            t.keep.shrinkRetainingCapacity(kept);
        }
    }

    /// The liveness of the local bindings of top-level statement `top`, as
    /// patched (`backend.md` §9, *Reading off*, G8): a `const` or `let`
    /// declared once and assigned nowhere, that lowering does not keep for
    /// an effect (`kept`), is dead when every read of it stands in the
    /// initialiser of a dead binding. `Opt` drops it whole, so its
    /// initialiser is written `undefined` here, and the names it read are
    /// read by that much less: `m.uses` is left as the live reads. The
    /// counts are `prepareTop`'s, just made. True when one was written.
    fn liveness(s: *Spec, m: *Mod, top: Index, kept: std.DynamicBitSetUnmanaged) Allocator.Error!bool {
        const ir = m.ir;
        const saved_top = s.cur_top;
        defer s.cur_top = saved_top;
        s.cur_top = top;
        var binds: std.ArrayList(Index) = .empty;
        for (try s.preorder(m, top)) |node| switch (ir.tag(node)) {
            .const_decl, .let_decl => {
                if (node == top) continue;
                const n: NameIndex = @fromBackingInt(@intCast(ir.data(node).lhs));
                if (m.globalOf(n) != null) continue;
                // A qualified name crosses a file, and `Opt` concludes nothing
                // about it: nor does this.
                if (ir.name(n).module != .none) continue;
                const i = n.unwrap() orelse continue;
                if (i >= m.stamp.len or m.stamp[i] != s.current or m.decls[i] != 1 or m.assigned[i]) continue;
                if (node.int() < kept.bit_length and kept.isSet(node.int())) continue;
                try binds.append(s.arena, node);
            },
            else => {},
        };
        if (binds.items.len == 0) return false;
        var any = false;
        var reads = try s.takeStack();
        defer s.giveStack(&reads);
        const dead = try s.arena.alloc(bool, binds.items.len);
        @memset(dead, false);
        // The nodes of the initialisers gone (`Mod.objects`, cleared on the
        // way out): a binding among them went with them, and its reads were
        // counted off there.
        var marked: std.ArrayList(u32) = .empty;
        defer for (marked.items) |i| m.objects.unset(i);
        var grew = true;
        while (grew) {
            grew = false;
            for (binds.items, dead) |node, *gone| {
                if (gone.*) continue;
                if (node.int() < m.objects.bit_length and m.objects.isSet(node.int())) {
                    gone.* = true;
                    continue;
                }
                const i = (@as(NameIndex, @fromBackingInt(@intCast(ir.data(node).lhs)))).unwrap().?;
                if (m.uses[i] != 0) continue;
                gone.* = true;
                const value = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(node).rhs)))).unwrap() orelse continue;
                // An initialiser that may do something stays, for `Opt` to
                // weigh by what lowering kept: lowering keeps only what it
                // knew might go unread, and a read the patch took was not.
                if (!try s.effectFree(m, value)) continue;
                grew = true;
                // What it read, it reads no more.
                reads.clearRetainingCapacity();
                try reads.append(s.arena, value);
                while (reads.pop()) |r| {
                    if (r.int() < m.objects.bit_length and !m.objects.isSet(r.int())) {
                        m.objects.set(r.int());
                        try marked.append(s.arena, r.int());
                    }
                    // An assignment's target is no read (`count`).
                    if (ir.tag(r) == .assign_stmt) {
                        const target: Index = @fromBackingInt(@intCast(ir.data(r).lhs));
                        if (ir.tag(target) != .ident) try reads.append(s.arena, target);
                        try reads.append(s.arena, @fromBackingInt(@intCast(ir.data(r).rhs)));
                        continue;
                    }
                    if (ir.tag(r) == .ident) {
                        const rn: NameIndex = @fromBackingInt(@intCast(ir.data(r).lhs));
                        if (m.globalOf(rn) == null) if (rn.unwrap()) |ri| if (ri < m.stamp.len and m.stamp[ri] == s.current) {
                            m.uses[ri] -|= 1;
                        };
                    }
                    try pushChildren(s.arena, ir, r, &reads);
                }
                try s.noteGone(m, value);
                // The binding goes, as `Opt` would drop it: a statement of
                // its literal, which its list's fold takes out
                // (`literalStmt`).
                m.setNode(value, .undefined_lit, 0, 0);
                if (value.int() < m.lit_of.len) m.lit_of[value.int()] = none;
                m.setNode(node, .expr_stmt, value.int(), 0);
                any = true;
            }
        }
        return any;
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
        s.list_mode = .scalars;
        return s.eachFunctionList();
    }

    /// Slice 9: constructor folding, over every statement list.
    fn constructors(s: *Spec) Allocator.Error!bool {
        if (s.in.fresh == .none) return false;
        s.list_mode = .constructors;
        s.cf_smalls = try s.smallTable();
        return s.eachFunctionList();
    }

    /// `backend.md` §9, *Slice 9*: a value a small function makes — an
    /// object literal, or a choice between such and declared objects — that
    /// a small function or the rest of its function only inspects, is made
    /// where it is inspected, so that each object's fields are read where
    /// they are written (scalar replacement) and a tag test folds. The list
    /// `items`, rewritten onto `out`; true when anything was.
    fn foldConstructors(s: *Spec, m: *Mod, top: Index, items: []const u32, out: *std.ArrayList(u32)) Allocator.Error!bool {
        var work: std.ArrayList(u32) = .empty;
        try work.appendSlice(s.arena, items);
        var changed = false;
        var budget: u32 = 32;
        var i: usize = 0;
        while (i < work.items.len) {
            if (budget > 0 and try s.foldAt(m, top, &work, i)) {
                changed = true;
                budget -= 1;
                if (budget == 0) s.stats.inline_capped += 1;
                // The statements written in its place may fold again, and
                // so may the one before them: the rules that read the
                // statement after their own (`const x = e; return R`,
                // `const x = c ? A : B; R`) now see a new one. Without the
                // step back, a run of field bindings before a `return` was
                // taken one binding per structural pass (#589).
                if (i > 0) i -= 1;
                continue;
            }
            i += 1;
        }
        try out.appendSlice(s.arena, work.items);
        return changed;
    }

    /// One statement of a list being folded, rewritten in `work` when a
    /// rule applies.
    fn foldAt(s: *Spec, m: *Mod, top: Index, work: *std.ArrayList(u32), i: usize) Allocator.Error!bool {
        const stmt: Index = @fromBackingInt(@intCast(work.items[i]));
        const ir = m.ir;
        const d = ir.data(stmt);
        switch (ir.tag(stmt)) {
            // `return f(…, g(…), …)`: `f` inspects what `g` makes.
            .return_stmt => {
                const v = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs)))).unwrap() orelse return false;
                const small = s.calleeSmall(m, v) orelse return false;
                const args = try s.arena.dupe(Index, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(v).rhs))), Index));
                if (args.len != small.params.len) return false;
                const exposes = for (args, small.inspects) |a, insp| {
                    if (insp and s.producer(m, a, 0)) break true;
                } else false;
                if (!exposes) return false;
                var stmts: std.ArrayList(u32) = .empty;
                const e = try s.bodyAt(m, top, small, args, &stmts, ir.pos(v)) orelse return false;
                const ret = try m.addNode(s.gpa, .return_stmt, ir.pos(stmt), e.int(), 0);
                try stmts.append(s.arena, ret.int());
                try work.replaceRange(s.arena, i, 1, stmts.items);
                return true;
            },
            .const_decl, .let_decl => {
                const x: NameIndex = @fromBackingInt(@intCast(d.lhs));
                if (x == .none or m.globalOf(x) != null) return false;
                const v = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs)))).unwrap() orelse return false;
                // `const x = e; return R`, `R` reading `x` once and first,
                // and nothing else reading it: `return R` with `e` in its
                // place — what a field's binding is once its object went.
                // Not where `x` is only inspected: the rules below fold it.
                if (i + 1 < work.items.len and ir.tag(@as(Index, @fromBackingInt(@intCast(work.items[i + 1])))) == .return_stmt) intoReturn: {
                    const r: Index = @fromBackingInt(@intCast(work.items[i + 1]));
                    const re = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(r).lhs)))).unwrap() orelse break :intoReturn;
                    if (try s.onlyInspected(m, top, x)) break :intoReturn;
                    if (try declCount(s, m, top, x) != 1) break :intoReturn;
                    if (firstUse(ir, re, x, 0) != .found) break :intoReturn;
                    if ((try s.usesOf(m, top, x)).?.idents != 1) break :intoReturn;
                    var c: Copy = .{
                        .s = s,
                        .src = m,
                        .dst = m,
                        .cross = false,
                        .renamed = try s.arena.alloc(u32, m.names.items.len),
                        .subst = try s.arena.alloc(Node.OptionalIndex, m.names.items.len),
                    };
                    @memset(c.renamed, none);
                    @memset(c.subst, .none);
                    c.subst[x.int()] = v.toOptional();
                    const e = try c.expr(re, 0);
                    const ret = try m.addNode(s.gpa, .return_stmt, ir.pos(r), e.int(), 0);
                    try work.replaceRange(s.arena, i, 2, &.{ret.int()});
                    return true;
                }
                switch (ir.tag(v)) {
                    // `const x = g(…)`, `g` a producer, `x` only inspected.
                    .call => {
                        const small = s.calleeSmall(m, v) orelse return false;
                        if (!s.producer(&s.mods[small.module], small.ret, 0)) return false;
                        if (!try s.onlyInspected(m, top, x)) return false;
                        const args = try s.arena.dupe(Index, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(v).rhs))), Index));
                        if (args.len != small.params.len) return false;
                        var stmts: std.ArrayList(u32) = .empty;
                        const e = try s.bodyAt(m, top, small, args, &stmts, ir.pos(v)) orelse return false;
                        m.setData(stmt, d.lhs, e.int());
                        try stmts.append(s.arena, stmt.int());
                        try work.replaceRange(s.arena, i, 1, stmts.items);
                        return true;
                    },
                    // `const x = c ? A : B; R`, `R` the list's last statement
                    // and `x` only inspected: `if (c) { const x = A; R } else
                    // { const x2 = B; R' }` — each branch makes its object,
                    // and `R` runs once either way, as it did.
                    .cond => {
                        if (i + 2 != work.items.len) return false;
                        const r: Index = @fromBackingInt(@intCast(work.items[i + 1]));
                        const c = ir.extraData(@fromBackingInt(@intCast(ir.data(v).rhs)), JsIr.Cond);
                        if (!s.producer(m, c.consequent, 0) or !s.producer(m, c.alternate, 0)) return false;
                        if (!try s.onlyInspected(m, top, x)) return false;
                        // `R` is copied: small, holding no function, its
                        // own declarations given names of their own.
                        var owned: std.ArrayList(u32) = .empty;
                        var size: u32 = 0;
                        var stack = try s.takeStack();
                        defer s.giveStack(&stack);
                        try JsIr.pushOperand(s.arena, &stack, r);
                        while (JsIr.popOperand(&stack)) |node| {
                            size += 1;
                            if (size > 96) return false;
                            switch (ir.tag(node)) {
                                .arrow, .func_decl, .gen_decl, .import_stmt, .export_stmt => return false,
                                .const_decl, .let_decl, .for_of, .while_true, .block_stmt => {
                                    const n: NameIndex = @fromBackingInt(@intCast(ir.data(node).lhs));
                                    if (n != .none) try owned.append(s.arena, n.int());
                                },
                                else => {},
                            }
                            try pushChildren(s.arena, ir, node, &stack);
                        }
                        const x2 = try s.freshLocal(m);
                        var copy: Copy = .{
                            .s = s,
                            .src = m,
                            .dst = m,
                            .cross = false,
                            .renamed = try s.arena.alloc(u32, m.names.items.len),
                            .subst = try s.arena.alloc(Node.OptionalIndex, m.names.items.len),
                        };
                        @memset(copy.renamed, none);
                        @memset(copy.subst, .none);
                        for (owned.items) |n| try copy.fresh(n, false);
                        copy.subst[x.int()] = (try m.addNode(s.gpa, .ident, Node.no_pos, x2.int(), 0)).toOptional();
                        const r2 = try copy.stmt(r, 0);
                        const then_decl = try m.addNode(s.gpa, ir.tag(stmt), ir.pos(stmt), x.int(), c.consequent.int());
                        const else_decl = try m.addNode(s.gpa, ir.tag(stmt), ir.pos(stmt), x2.int(), c.alternate.int());
                        const then_start = try m.append(s.gpa, &.{ then_decl.int(), r.int() });
                        const else_start = try m.append(s.gpa, &.{ else_decl.int(), r2.int() });
                        const branches = try m.append(s.gpa, &.{ then_start, then_start + 2, else_start, else_start + 2 });
                        const if_node = try m.addNode(s.gpa, .if_stmt, ir.pos(stmt), ir.data(v).lhs, branches);
                        try work.replaceRange(s.arena, i, 2, &.{if_node.int()});
                        return true;
                    },
                    else => return false,
                }
            },
            else => return false,
        }
    }

    /// The small function call `v` calls by its whole-program name, or null.
    fn calleeSmall(s: *Spec, m: *Mod, v: Index) ?Small {
        if (m.ir.tag(v) != .call) return null;
        const callee: Index = @fromBackingInt(@intCast(m.ir.data(v).lhs));
        if (m.ir.tag(callee) != .ident) return null;
        const g = m.globalOf(@fromBackingInt(@intCast(m.ir.data(callee).lhs))) orelse return null;
        if (g >= s.cf_smalls.len) return null;
        return s.cf_smalls[g];
    }

    /// Whether `e`, of module `m`, makes an object a fold can see into: an
    /// object literal; a declared object (a top-level `const` of an object
    /// literal, made once); a choice of two such; or a call of a small
    /// function whose body is one.
    fn producer(s: *Spec, m: *Mod, e: Index, depth: u32) bool {
        if (depth > 4) return false;
        const ir = m.ir;
        switch (ir.tag(e)) {
            .object => return true,
            .cond => {
                const c = ir.extraData(@fromBackingInt(@intCast(ir.data(e).rhs)), JsIr.Cond);
                return s.producer(m, c.consequent, depth + 1) and s.producer(m, c.alternate, depth + 1);
            },
            .ident => {
                const g = m.globalOf(@fromBackingInt(@intCast(ir.data(e).lhs))) orelse return false;
                const decl = s.decl[g] orelse return false;
                if (s.assigned[g]) return false;
                const dm = &s.mods[decl.module];
                if (dm.ir.tag(decl.stmt) != .const_decl) return false;
                return dm.ir.tag(@fromBackingInt(@intCast(dm.ir.data(decl.stmt).rhs))) == .object;
            },
            .call => {
                const small = s.calleeSmall(m, e) orelse return false;
                return s.producer(&s.mods[small.module], small.ret, depth + 1);
            },
            else => return false,
        }
    }

    /// Whether every mention of local `x` in `top` is the object of a
    /// property read, and `top` declares it once and assigns it nowhere.
    fn onlyInspected(s: *Spec, m: *Mod, top: Index, x: NameIndex) Allocator.Error!bool {
        const u = try s.usesOf(m, top, x) orelse return false;
        return u.decls == 1 and u.bare() == 0 and u.written.items.len == 0;
    }

    /// `small`'s body for a call in module `m` with `args`: each argument
    /// that is not an atom bound first, in order, by a `const` appended to
    /// `stmts` (and kept by the optimiser when it may do something), then
    /// the body with each parameter its argument or binding. Null when a
    /// name the body needs is not one `m` can write.
    /// A body of module `module` is being copied out of the top-level
    /// declaration `owner` (`none`: one the pass cannot name) into another
    /// statement (`Stats.copied`).
    fn noteCopy(s: *Spec, module: u32, owner: u32) void {
        if (owner != none and owner < s.copied.len) {
            s.copied[owner] = true;
        } else s.copied_modules[module] = true;
    }

    /// `site` is the call's position (`Copy.site`).
    fn bodyAt(s: *Spec, m: *Mod, top: Index, small: Small, args: []const Index, stmts: *std.ArrayList(u32), site: u32) Allocator.Error!?Index {
        s.noteCopy(small.module, small.owner);
        const fm = &s.mods[small.module];
        const cross = small.module != m.index;
        var c: Copy = .{
            .s = s,
            .src = fm,
            .dst = m,
            .cross = cross,
            .site = site,
            .renamed = try s.arena.alloc(u32, fm.ir.names.len),
            .subst = try s.arena.alloc(Node.OptionalIndex, fm.ir.names.len),
        };
        @memset(c.renamed, none);
        @memset(c.subst, .none);
        if (cross) {
            var stack = try s.takeStack();
            defer s.giveStack(&stack);
            try JsIr.pushOperand(s.arena, &stack, small.ret);
            while (JsIr.popOperand(&stack)) |node| {
                if (fm.ir.tag(node) == .ident) {
                    const x: NameIndex = @fromBackingInt(@intCast(fm.ir.data(node).lhs));
                    if (std.mem.indexOfScalar(NameIndex, small.params, x) == null) {
                        const h = fm.globalOf(x).?;
                        const to = try s.nameIn(m, h) orelse return null;
                        c.renamed[x.int()] = to.int();
                    }
                }
                try fm.ir.pushOperands(s.arena, &stack, node);
            }
        }
        for (small.params, args, 0..) |p, a, i| {
            const pi = p.unwrap() orelse continue;
            const atom = switch (m.ir.tag(a)) {
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => literalLen(m.ir, a) <= 5 or small.reads[i] <= 1,
                .ident => try s.atomArgument(m, a, top, s.assigned),
                else => false,
            };
            if (atom) {
                c.subst[pi] = a.toOptional();
                continue;
            }
            const t = try s.freshLocal(m);
            const decl = try m.addNode(s.gpa, .const_decl, m.ir.pos(a), t.int(), a.int());
            try stmts.append(s.arena, decl.int());
            if (!inert(m.ir, a)) if (m.tables) |tb| try tb.keep.append(s.arena, decl);
            c.subst[pi] = (try m.addNode(s.gpa, .ident, Node.no_pos, t.int(), 0)).toOptional();
        }
        return try c.expr(small.ret, 0);
    }

    fn eachFunctionList(s: *Spec) Allocator.Error!bool {
        if (s.in.fresh == .none) return false;
        var any = false;
        for (s.mods) |*m| {
            const body = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.body, Index));
            for (body) |top| {
                // Every list a mode rewrites is one of `top`'s.
                within(m, top);
                const did = s.eachListIn(m, top) catch |err| {
                    m.scope = null;
                    return err;
                };
                try s.leave(m);
                if (did) any = true;
            }
        }
        return any;
    }

    fn eachListIn(s: *Spec, m: *Mod, top: Index) Allocator.Error!bool {
        var any = false;
        switch (m.ir.tag(top)) {
            // An arrow called where it is made in a top-level binding's own
            // value, outside any function: written in its place as
            // `inlineIifesIn` writes one inside a function, the binding the
            // declaration that scopes its names.
            .const_decl, .let_decl => {
                if (s.list_mode == .tidy and try s.inlineIifesIn(m, top, top)) any = true;
                if (try s.srBelow(m, top, top, 0)) any = true;
            },
            .func_decl => if (try s.srBelow(m, top, top, 0)) {
                any = true;
            },
            else => {},
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
                var stack = try s.takeStack();
                defer s.giveStack(&stack);
                try operandsOf(s.arena, ir, stmt, &stack);
                while (JsIr.popOperand(&stack)) |node| {
                    if (m.ir.tag(node) == .arrow) {
                        const at = m.ir.data(node).lhs;
                        if (try s.srList(m, at + 2, m.ir.extraData(@fromBackingInt(@intCast(at)), JsIr.Func).body(), top, depth + 1)) any = true;
                        continue;
                    }
                    try m.ir.pushOperands(s.arena, &stack, node);
                }
            },
            .func_decl, .gen_decl => any = try s.srList(m, d.rhs + 2, ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Func).body(), top, depth + 1),
            .if_stmt => {
                if (try s.srBelowExpr(m, @fromBackingInt(@intCast(d.lhs)), top, depth)) any = true;
                if (try s.srList(m, d.rhs, m.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If).thenBody(), top, depth + 1)) any = true;
                if (try s.srList(m, d.rhs + 2, m.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If).elseBody(), top, depth + 1)) any = true;
            },
            .while_true, .block_stmt, .switch_case => any = try s.srList(m, d.rhs, ir.subRange(@fromBackingInt(@intCast(d.rhs))), top, depth + 1),
            .for_of => any = try s.srList(m, d.rhs + 1, ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf).body(), top, depth + 1),
            // By position, as `srList` walks its items.
            .switch_stmt => {
                const cases = ir.subRange(@fromBackingInt(@intCast(d.rhs)));
                var k: u32 = @backingInt(cases.start);
                while (k < @backingInt(cases.end)) : (k += 1) {
                    if (try s.srBelow(m, @fromBackingInt(@intCast(m.extra.items[k])), top, depth + 1)) any = true;
                }
            },
            .try_stmt => {
                if (try s.srList(m, d.rhs, m.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try).body(), top, depth + 1)) any = true;
                if (try s.srList(m, d.rhs + 2, m.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try).finalBody(), top, depth + 1)) any = true;
                if (try s.srList(m, d.rhs + 4, m.ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try).catchBody(), top, depth + 1)) any = true;
            },
            else => {},
        }
        return any;
    }

    fn srBelowExpr(s: *Spec, m: *Mod, root: Index, top: Index, depth: u32) Allocator.Error!bool {
        var any = false;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, root);
        while (JsIr.popOperand(&stack)) |node| {
            if (m.ir.tag(node) == .arrow) {
                const at = m.ir.data(node).lhs;
                if (try s.srList(m, at + 2, m.ir.extraData(@fromBackingInt(@intCast(at)), JsIr.Func).body(), top, depth + 1)) any = true;
                continue;
            }
            try m.ir.pushOperands(s.arena, &stack, node);
        }
        return any;
    }

    /// One list: the lists below first, then each declaration of it that
    /// can be replaced, written as its bindings.
    ///
    /// A list holding no statement the mode could act on is left as it is,
    /// uncopied (`listActs`): every sweep walks the whole program, and most
    /// of its lists hold nothing for it.
    fn srList(s: *Spec, m: *Mod, owner: u32, range: JsIr.SubRange, top: Index, depth: u32) Allocator.Error!bool {
        if (depth > max_depth) return false;
        var any = false;
        // By position: a list below appends to `extra`, which may move, and
        // writes only its own owner's words, never this list's items.
        var k: u32 = @backingInt(range.start);
        while (k < @backingInt(range.end)) : (k += 1) {
            if (try s.srBelow(m, @fromBackingInt(@intCast(m.extra.items[k])), top, depth + 1)) any = true;
        }
        if (!try s.listActs(m, range)) return any;
        s.stats.lists_examined += 1;
        const items = try s.arena.dupe(u32, m.ir.extraSlice(range, u32));
        var out: std.ArrayList(u32) = .empty;
        var changed = false;
        switch (s.list_mode) {
            .scalars => for (items) |raw| {
                if (try s.replaceScalars(m, @fromBackingInt(@intCast(raw)), top, &out)) {
                    changed = true;
                    continue;
                }
                try out.append(s.arena, raw);
            },
            .constructors => changed = try s.foldConstructors(m, top, items, &out),
            // In the pass loop, in one sweep: `x = x` does nothing, a name
            // read and written back (an identity written in place, slice
            // 8); and a function called where it is made is written there
            // (`betaReduce`).
            .tidy => for (items) |raw| {
                const st: Index = @fromBackingInt(@intCast(raw));
                // A binding of a record written in place, `const x = (s, …, v)`:
                // its stores as statements before it, then `const x = v`
                // (`Lower.settleStores`), which a copy of a name folds.
                if (storesBound(m.ir, st)) |parts| {
                    const kept = try s.arena.dupe(u32, parts);
                    for (kept[0 .. kept.len - 1]) |e| try out.append(s.arena, (try m.addNode(s.gpa, .expr_stmt, m.ir.pos(st), e, 0)).int());
                    m.setData(st, m.ir.data(st).lhs, kept[kept.len - 1]);
                    try out.append(s.arena, raw);
                    changed = true;
                    continue;
                }
                if (m.ir.tag(st) == .assign_stmt) {
                    const target: Index = @fromBackingInt(@intCast(m.ir.data(st).lhs));
                    if (m.ir.tag(target) == .ident and sameChain(m.ir, target, @fromBackingInt(@intCast(m.ir.data(st).rhs)))) {
                        changed = true;
                        continue;
                    }
                }
                if (try s.betaReduce(m, st, top, &out)) {
                    changed = true;
                    continue;
                }
                if (try s.inlineIifesIn(m, top, st)) any = true;
                try out.append(s.arena, raw);
            },
            .switches => for (items, 0..) |raw, at| {
                if (try s.etaIn(m, top, items, at)) any = true;
                if (try s.switchAsIfs(m, @fromBackingInt(@intCast(raw)), items, &out)) {
                    changed = true;
                    continue;
                }
                try out.append(s.arena, raw);
            },
        }
        if (!changed) return any;
        // Scalar replacement changes a list by the statements it drops and
        // the bindings it writes in their place, and nothing else: what is
        // kept of `top` follows those (`retract`, `extend`).
        var delta: ?Retracted = null;
        var added: []const u32 = &.{};
        if (s.list_mode == .scalars) {
            const removed = try s.multisetMinus(items, out.items);
            added = try s.multisetMinus(out.items, items);
            delta = try s.retract(m, top, removed);
        }
        const start = try m.append(s.gpa, out.items);
        m.changed();
        m.extra.items[owner] = start;
        m.extra.items[owner + 1] = start + @as(u32, @intCast(out.items.len));
        if (delta) |r| try s.extend(m, top, r, added);
        return true;
    }

    /// Whether no statement of `siblings` but `except` mentions a name
    /// `body`'s own statements declare.
    fn declaresAlone(s: *Spec, m: *Mod, body: JsIr.SubRange, siblings: []const u32, except: Index) Allocator.Error!bool {
        const ir = m.ir;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        for (ir.extraSlice(body, Index)) |st| {
            const n: NameIndex = switch (ir.tag(st)) {
                .const_decl, .let_decl, .func_decl, .gen_decl, .while_true, .block_stmt => @fromBackingInt(@intCast(ir.data(st).lhs)),
                else => continue,
            };
            if (n == .none) continue;
            for (siblings) |raw| {
                if (raw == except.int()) continue;
                stack.clearRetainingCapacity();
                try JsIr.pushOperand(s.arena, &stack, @fromBackingInt(@intCast(raw)));
                while (JsIr.popOperand(&stack)) |node| {
                    switch (ir.tag(node)) {
                        .ident, .const_decl, .let_decl, .func_decl, .gen_decl, .while_true, .block_stmt, .break_stmt, .continue_stmt, .for_of => if (ir.data(node).lhs == n.int()) return false,
                        else => {},
                    }
                    try pushChildren(s.arena, ir, node, &stack);
                }
            }
        }
        return true;
    }

    /// `backend.md` §9, *The entry's call is a call*, amended 2026-10-17: an
    /// entry callee `const f = (p₁, …, pₙ) => g(p₁, …, pₙ)` that only forwards
    /// its parameters, in order, to a function `g` declared before it in the
    /// same module, is `const f = g`, when nothing names `f` but the entry,
    /// whose call passes at most `n` arguments. Calling either then runs
    /// `g` with the same arguments; the entry never compares `f`.
    fn forwardEntry(s: *Spec) Allocator.Error!void {
        const entry = s.in.entry orelse return;
        if (entry.args.len == 0) return;
        const g = entry.callee;
        if (g >= s.globals) return;
        for (s.in.escaping) |e| if (e == g) return;
        const decl = s.decl[g] orelse return;
        if (s.assigned[g]) return;
        const m = &s.mods[decl.module];
        const ir = m.ir;
        if (ir.tag(decl.stmt) != .const_decl) return;
        const value: Index = @fromBackingInt(@intCast(ir.data(decl.stmt).rhs));
        if (ir.tag(value) != .arrow or ir.data(value).rhs != Node.arrow_plain) return;
        const f = ir.extraData(@fromBackingInt(@intCast(ir.data(value).lhs)), JsIr.Func);
        const params = ir.extraSlice(f.params(), NameIndex);
        if (entry.args.len > params.len) return;
        const body = ir.extraSlice(f.body(), Index);
        if (body.len != 1 or ir.tag(body[0]) != .return_stmt) return;
        const call = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(body[0]).lhs)))).unwrap() orelse return;
        if (ir.tag(call) != .call) return;
        const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(call).rhs))), Index);
        if (args.len != params.len) return;
        for (args, params) |a, p| if (ir.tag(a) != .ident or ir.data(a).lhs != p.int()) return;
        const callee: Index = @fromBackingInt(@intCast(ir.data(call).lhs));
        if (ir.tag(callee) != .ident) return;
        const h = m.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs))) orelse return;
        const hd = s.decl[h] orelse return;
        if (hd.module != decl.module or s.assigned[h] or s.mods[hd.module].ir.tag(hd.stmt) != .const_decl) return;
        const hv: Index = @fromBackingInt(@intCast(ir.data(hd.stmt).rhs));
        if (ir.tag(hv) != .arrow) return;
        // Declared before `f`, so `const f = g` reads a bound name.
        const top = ir.extraSlice(ir.body, Index);
        const at_h = std.mem.indexOfScalar(Index, top, hd.stmt) orelse return;
        const at_f = std.mem.indexOfScalar(Index, top, decl.stmt) orelse return;
        if (at_h >= at_f) return;
        // Nothing of the program names `f`.
        for (s.mods) |*mm| for (mm.ir.extraSlice(mm.ir.body, Index)) |t| {
            for (try s.preorder(mm, t)) |node| {
                if (mm.ir.tag(node) == .ident) if (mm.globalOf(@fromBackingInt(@intCast(mm.ir.data(node).lhs)))) |x| if (x == g) return;
            }
        };
        try m.copyNode(s.gpa, value, callee);
    }
    /// `backend.md` §9, *A function that only calls a function is that
    /// function*: in statement `items[at]`'s own expressions, `() => g()`
    /// is `g` when `g` is a name an earlier statement of the list declares,
    /// once, as a function of no parameters, and nothing assigns it. Neither
    /// takes an argument nor reads `this`, a call of either runs `g`'s body
    /// and answers what it answers, and `g` exists by then (it was declared
    /// before). True when any was rewritten.
    fn etaIn(s: *Spec, m: *Mod, top: Index, items: []const u32, at: usize) Allocator.Error!bool {
        const ir = m.ir;
        var any = false;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try operandsOf(s.arena, ir, @fromBackingInt(@intCast(items[at])), &stack);
        while (JsIr.popOperand(&stack)) |node| {
            if (ir.tag(node) == .arrow) {
                if (try s.etaTarget(m, top, items[0..at], node)) |g| {
                    m.setNode(node, .ident, g.int(), 0);
                    any = true;
                }
                continue;
            }
            try ir.pushOperands(s.arena, &stack, node);
        }
        return any;
    }

    /// Whether statement `stmt`'s own expressions make a function.
    fn holdsArrow(s: *Spec, m: *Mod, stmt: Index) Allocator.Error!bool {
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try operandsOf(s.arena, m.ir, stmt, &stack);
        while (JsIr.popOperand(&stack)) |node| {
            if (m.ir.tag(node) == .arrow) return true;
            try m.ir.pushOperands(s.arena, &stack, node);
        }
        return false;
    }
    fn etaTarget(s: *Spec, m: *Mod, top: Index, before: []const u32, arrow: Index) Allocator.Error!?NameIndex {
        const ir = m.ir;
        if (ir.data(arrow).rhs != Node.arrow_plain) return null;
        const f = ir.extraData(@fromBackingInt(@intCast(ir.data(arrow).lhs)), JsIr.Func);
        if (ir.extraSlice(f.params(), NameIndex).len != 0) return null;
        const body = ir.extraSlice(f.body(), Index);
        if (body.len != 1 or ir.tag(body[0]) != .return_stmt) return null;
        const call = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(body[0]).lhs)))).unwrap() orelse return null;
        if (ir.tag(call) != .call) return null;
        // Arguments `g` takes no parameter for and whose evaluation does
        // nothing (`null` for a `⊤`) are not passed by anything.
        for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(call).rhs))), Index)) |a| if (!primitiveLit(ir, a)) return null;
        const callee: Index = @fromBackingInt(@intCast(ir.data(call).lhs));
        if (ir.tag(callee) != .ident) return null;
        const g: NameIndex = @fromBackingInt(@intCast(ir.data(callee).lhs));
        if (g == .none or m.globalOf(g) != null) return null;
        const made = for (before) |raw| {
            const st: Index = @fromBackingInt(@intCast(raw));
            if (ir.tag(st) != .const_decl or ir.data(st).lhs != g.int()) continue;
            break @as(Index, @fromBackingInt(@intCast(ir.data(st).rhs)));
        } else return null;
        if (ir.tag(made) != .arrow or ir.data(made).rhs != Node.arrow_plain) return null;
        const gf = ir.extraData(@fromBackingInt(@intCast(ir.data(made).lhs)), JsIr.Func);
        if (ir.extraSlice(gf.params(), NameIndex).len != 0) return null;
        if (try declCount(s, m, top, g) != 1) return null;
        if (try s.assignedInTop(m, top, g)) return null;
        return g;
    }
    /// `backend.md` §9, *A short `switch` is its `if`s*: `switch (k)` on a
    /// name, with at most `max_switch_ifs` cases besides the `default`, each
    /// test a literal and each body unable to run off its end and holding no
    /// `break`, is `if (k === t) { body }` per case in order, then the
    /// `default`'s statements. A literal test does nothing and a body that
    /// cannot complete never falls into the next case, so the cases are
    /// tried, and one run, exactly as the `switch` does. True when `stmt` was
    /// one, its statements appended to `out`.
    fn switchAsIfs(s: *Spec, m: *Mod, stmt: Index, siblings: []const u32, out: *std.ArrayList(u32)) Allocator.Error!bool {
        const ir = m.ir;
        if (ir.tag(stmt) != .switch_stmt) return false;
        const d = ir.data(stmt);
        const disc: Index = @fromBackingInt(@intCast(d.lhs));
        if (ir.tag(disc) != .ident) return false;
        const cases = try s.arena.dupe(Index, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index));
        var tested: u32 = 0;
        var default: ?Index = null;
        // The `default` must be the last case: one before a case is tried
        // only after every test, and would be written there.
        for (cases, 0..) |case, ci| {
            if ((@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(case).lhs)))) == .none and ci + 1 != cases.len) return false;
        }
        for (cases) |case| {
            const body = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(case).rhs))), Index);
            if (holdsBreak(ir, body, 0)) return false;
            const t = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(case).lhs)))).unwrap() orelse {
                default = case;
                continue;
            };
            if (!primitiveLit(ir, t) or !allReturn(ir, body, 0)) return false;
            tested += 1;
        }
        if (tested == 0 or tested > max_switch_ifs) return false;
        for (cases) |case| {
            const cd = ir.data(case);
            const t = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(cd.lhs)))).unwrap() orelse continue;
            const name = try m.addNode(s.gpa, .ident, ir.pos(disc), ir.data(disc).lhs, 0);
            const pair = try m.append(s.gpa, &.{ name.int(), t.int() });
            const test_node = try m.addNode(s.gpa, .binary, ir.pos(case), pair, @backingInt(JsIr.BinaryOp.strict_eq));
            // An `if`'s body is a scope of its own, as the block was.
            const body = unblocked(ir, ir.subRange(@fromBackingInt(@intCast(cd.rhs))));
            const empty = try m.append(s.gpa, &.{});
            const branches = try m.append(s.gpa, &.{ @backingInt(body.start), @backingInt(body.end), empty, empty });
            try out.append(s.arena, (try m.addNode(s.gpa, .if_stmt, ir.pos(case), test_node.int(), branches)).int());
        }
        if (default) |case| {
            const body = unblocked(ir, ir.subRange(@fromBackingInt(@intCast(ir.data(case).rhs))));
            // Its statements join the list when nothing else of the list names
            // what they declare: a `let` there would shadow, from the list's
            // start, a name an earlier statement reads.
            if (declaresNothing(ir, body) or try s.declaresAlone(m, body, siblings, stmt)) {
                try out.appendSlice(s.arena, ir.extraSlice(body, u32));
            } else {
                const at = try m.append(s.gpa, &.{ @backingInt(body.start), @backingInt(body.end) });
                try out.append(s.arena, (try m.addNode(s.gpa, .block_stmt, ir.pos(case), @backingInt(NameIndex.none), at)).int());
            }
        }
        return true;
    }
    /// Whether the list holds a statement `srList`'s mode could act on — a
    /// superset of where it does, so a list without one is one the mode
    /// leaves as it was: `replaceScalars` acts only on a `const` or `let`
    /// of an object literal, `foldAt` only on a `const` or `let`, or on a
    /// `return` of a call (a fold writes statements in only where one of
    /// these was, so a list without one gains none), and the self-assign
    /// mode only on an assignment.
    fn listActs(s: *Spec, m: *Mod, range: JsIr.SubRange) Allocator.Error!bool {
        const ir = m.ir;
        for (ir.extraSlice(range, Index)) |st| {
            const d = ir.data(st);
            switch (s.list_mode) {
                .scalars => switch (ir.tag(st)) {
                    .const_decl, .let_decl => if ((@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs)))).unwrap()) |v| {
                        if (ir.tag(v) == .object) return true;
                    },
                    else => {},
                },
                .constructors => switch (ir.tag(st)) {
                    .const_decl, .let_decl => return true,
                    .return_stmt => if ((@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs)))).unwrap()) |v| {
                        if (ir.tag(v) == .call) return true;
                    },
                    else => {},
                },
                .tidy => if (ir.tag(st) == .assign_stmt or storesBound(ir, st) != null or iifeOf(ir, st) != null or try s.inlineIifesIn(m, null, st)) return true,
                // A `switch`, or an arrow an eta step may take.
                .switches => if (ir.tag(st) == .switch_stmt or try s.holdsArrow(m, st)) return true,
            }
        }
        return false;
    }

    /// Every call in statement `stmt`'s own expressions — short of the
    /// functions in them, whose lists `srList` reaches on its own — that
    /// makes the function it calls, written as that function's body where
    /// it is small (`smallOf`), its arguments atoms or one read first
    /// (`inlineSmallAt`): `((a) => f(a, a + 1))(b)` is `f(b, b + 1)`. A
    /// body may name what the function around it names, since it is
    /// written where it was made. True when any was; with no `top`, only
    /// whether there is such a call to look at.
    fn inlineIifesIn(s: *Spec, m: *Mod, top: ?Index, stmt: Index) Allocator.Error!bool {
        var any = false;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try operandsOf(s.arena, m.ir, stmt, &stack);
        var budget: u32 = 1 << 16;
        while (JsIr.popOperand(&stack)) |node| {
            if (budget == 0) break;
            budget -= 1;
            const ir = m.ir;
            const t = ir.tag(node);
            if (t == .arrow) continue;
            if (t == .call) {
                const callee: Index = @fromBackingInt(@intCast(ir.data(node).lhs));
                if (ir.tag(callee) == .arrow and ir.data(callee).rhs == Node.arrow_plain) {
                    const at = top orelse return true;
                    if (try s.smallOf(m.index, callee, null, true)) |small| {
                        if (try s.inlineSmallAt(m, m.index, at, node, small, true)) {
                            any = true;
                            // What it became may make another.
                            try JsIr.pushOperand(s.arena, &stack, node);
                            continue;
                        }
                    }
                }
            }
            try ir.pushOperands(s.arena, &stack, node);
        }
        return any;
    }

    /// `backend.md` §9, *A function called where it is made*: a statement
    /// whose value is `((p…) => { S; return e })(a…)` — a `const` or `let`
    /// initialised by it, a `return` of it, or the call alone — is the
    /// arrow's body written in the list: `const p = a;` for each
    /// parameter, in order, then `S`, then the statement with `e` for its
    /// value. Each argument is evaluated once and before the body, as the
    /// call evaluated it, and an arrow binds no `this` and no `arguments`,
    /// so the body means what it meant. Taken only when nothing can come to
    /// mean something else: every parameter and every name `S` declares at
    /// its own level is declared once in the declaration (`declCount`), no
    /// `return` but the last leaves the body, and the body holds no label,
    /// which its new place could already hold. Onto `out`; false, with
    /// nothing changed, otherwise.
    fn betaReduce(s: *Spec, m: *Mod, stmt: Index, top: Index, out: *std.ArrayList(u32)) Allocator.Error!bool {
        const call = iifeOf(m.ir, stmt) orelse return false;
        const ir = m.ir;
        const arrow: Index = @fromBackingInt(@intCast(ir.data(call).lhs));
        const f = ir.extraData(@fromBackingInt(@intCast(ir.data(arrow).lhs)), JsIr.Func);
        const params = try s.arena.dupe(NameIndex, ir.extraSlice(f.params(), NameIndex));
        const args = try s.arena.dupe(Index, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(call).rhs))), Index));
        if (params.len != args.len) return false;
        const body = try s.arena.dupe(Index, ir.extraSlice(f.body(), Index));
        // A body that is one `return e` is `inlineIifesIn`'s, written as `e`
        // where its arguments allow; as statements it is bindings and a
        // block, larger than the call it replaces.
        if (body.len < 2 or ir.tag(body[body.len - 1]) != .return_stmt) return false;
        const value = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(body[body.len - 1]).lhs)))).unwrap() orelse return false;
        for (params) |p| {
            if (p == .none or m.globalOf(p) != null) return false;
            if (try declCount(s, m, top, p) != 1) return false;
        }
        // What `S` may not hold, outside the functions in it: a `return`
        // (it would now leave the caller), a label.
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        for (body[0 .. body.len - 1]) |st| {
            switch (ir.tag(st)) {
                .const_decl, .let_decl, .func_decl, .gen_decl => {
                    const n: NameIndex = @fromBackingInt(@intCast(ir.data(st).lhs));
                    if (n == .none or m.globalOf(n) != null) return false;
                    if (try declCount(s, m, top, n) != 1) return false;
                },
                else => {},
            }
            try JsIr.pushOperand(s.arena, &stack, st);
        }
        while (JsIr.popOperand(&stack)) |node| {
            const d = ir.data(node);
            switch (ir.tag(node)) {
                .return_stmt => return false,
                .while_true, .block_stmt => if (@as(NameIndex, @fromBackingInt(@intCast(d.lhs))) != .none) return false,
                .arrow, .func_decl, .gen_decl => continue,
                else => {},
            }
            try pushChildren(s.arena, ir, node, &stack);
        }
        // Which parameters the body assigns: those are `let`s. And no
        // `catch` binds a name the list would now declare.
        const assigned = try s.arena.alloc(bool, params.len);
        @memset(assigned, false);
        for (try s.preorder(m, top)) |node| {
            if (ir.tag(node) == .try_stmt) {
                const n = ir.extraData(@fromBackingInt(@intCast(ir.data(node).rhs)), JsIr.Try).catch_name;
                if (n != .none) {
                    if (std.mem.indexOfScalar(NameIndex, params, n) != null) return false;
                    for (body[0 .. body.len - 1]) |st| switch (ir.tag(st)) {
                        .const_decl, .let_decl, .func_decl, .gen_decl => if (ir.data(st).lhs == n.int()) return false,
                        else => {},
                    };
                }
            }
            if (ir.tag(node) != .assign_stmt) continue;
            const target: Index = @fromBackingInt(@intCast(ir.data(node).lhs));
            if (ir.tag(target) != .ident) continue;
            if (std.mem.indexOfScalar(NameIndex, params, @fromBackingInt(@intCast(ir.data(target).lhs)))) |i| assigned[i] = true;
        }
        for (params, args, assigned) |p, a, re| {
            const decl = try m.addNode(s.gpa, if (re) .let_decl else .const_decl, ir.pos(a), p.int(), a.int());
            try out.append(s.arena, decl.int());
            if (!inert(m.ir, a)) if (m.tables) |tb| try tb.keep.append(s.arena, decl);
        }
        for (body[0 .. body.len - 1]) |st| try out.append(s.arena, st.int());
        switch (m.ir.tag(stmt)) {
            .const_decl, .let_decl => m.setData(stmt, m.ir.data(stmt).lhs, value.int()),
            .return_stmt, .expr_stmt => m.setData(stmt, value.int(), 0),
            else => unreachable,
        }
        try out.append(s.arena, stmt.int());
        return true;
    }

    /// When `stmt` declares an object that can be replaced by its keys, its
    /// bindings onto `out` and every `x.k` of `top` rewritten; false, with
    /// nothing changed, otherwise.
    fn replaceScalars(s: *Spec, m: *Mod, stmt: Index, top: Index, out: *std.ArrayList(u32)) Allocator.Error!bool {
        const ir = m.ir;
        const tag = ir.tag(stmt);
        if (tag != .const_decl and tag != .let_decl) return false;
        const x: NameIndex = @fromBackingInt(@intCast(ir.data(stmt).lhs));
        if (x == .none or m.globalOf(x) != null) return false;
        const value = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(stmt).rhs)))).unwrap() orelse return false;
        if (ir.tag(value) != .object) return false;
        const props = try s.arena.dupe(Index, ir.extraSlice(JsIr.inlineRange(ir.data(value)), Index));
        if (props.len == 0 or props.len > 32) return false;
        const ids = try s.arena.alloc(u32, props.len);
        for (props, ids, 0..) |p, *id, i| {
            if (ir.tag(p) != .property) return false;
            id.* = s.pts.propId(m.index, @fromBackingInt(@intCast(ir.data(p).lhs)));
            if (id.* == none) return false;
            if (std.mem.indexOfScalar(u32, ids[0..i], id.*) != null) return false;
        }
        // A key holding a `Js.method` function is read through `this` by
        // whatever calls it: the object must stay one object.
        for (props) |p| if (s.methodValue(m, @fromBackingInt(@intCast(ir.data(p).rhs)))) return false;
        // Every mention of `x` in its declaration.
        var members: std.ArrayList(Index) = .empty;
        const written = try s.arena.alloc(bool, props.len);
        @memset(written, false);
        // Keys whose read is a call's callee, `x.k(…)`: a method call, which
        // hands the function `x` as `this` — kept unless the key's value is
        // an arrow, which cannot read it.
        const called = try s.arena.alloc(bool, props.len);
        @memset(called, false);
        const seen = try s.arena.alloc(bool, props.len);
        @memset(seen, false);
        // What a walk of `top` meets of `x` (`nameScan`): a walk that does
        // not go below a read `x.k`, of at most 2¹⁶ nodes, meeting `x`
        // nowhere else, every key it reads or writes one of the literal's.
        const scan = try s.nameScan(m, top);
        const use = findUse(scan, x.int()) orelse return false;
        if (scan.nodes - use.members.items.len > 1 << 16) return false;
        if (use.bare() != 0) return false;
        // A record written in place stays one object: its store's target is
        // a property, never a name (`JsIr.Node.Tag.assign`).
        if (use.in_place != 0) return false;
        for (use.members.items) |node| {
            const id = s.pts.propId(m.index, @fromBackingInt(@intCast(ir.data(node).rhs)));
            const k = std.mem.indexOfScalar(u32, ids, id) orelse return false;
            try members.append(s.arena, node);
            seen[k] = true;
        }
        for (use.written.items) |target| {
            const id = s.pts.propId(m.index, @fromBackingInt(@intCast(ir.data(target).rhs)));
            const k = std.mem.indexOfScalar(u32, ids, id) orelse return false;
            written[k] = true;
        }
        for (use.called.items) |callee| {
            const id = s.pts.propId(m.index, @fromBackingInt(@intCast(ir.data(callee).rhs)));
            if (std.mem.indexOfScalar(u32, ids, id)) |k| called[k] = true;
        }
        if (use.decls != 1) return false;
        for (props, called) |p, c| {
            if (c and ir.tag(@fromBackingInt(@intCast(ir.data(p).rhs))) != .arrow) return false;
        }

        const kept = if (m.tables) |t| std.mem.indexOfScalar(Index, t.keep.items, stmt) != null else false;
        // How many reads each key has: a key never written whose value is
        // an atom — a short literal, any literal read once, or a name
        // nothing assigns — is that atom where it is read.
        const uses = try s.arena.alloc(u32, props.len);
        @memset(uses, 0);
        for (members.items, 0..) |node, i| {
            if (std.mem.indexOfScalar(Index, members.items[0..i], node) != null) continue;
            uses[std.mem.indexOfScalar(u32, ids, s.pts.propId(m.index, @fromBackingInt(@intCast(m.ir.data(node).rhs)))).?] += 1;
        }
        const names = try s.arena.alloc(NameIndex, props.len);
        const atoms = try s.arena.alloc(?Index, props.len);
        for (props, names, atoms, 0..) |p, *n, *a, k| {
            const v: Index = @fromBackingInt(@intCast(m.ir.data(p).rhs));
            a.* = null;
            n.* = .none;
            if (!seen[k] and !written[k] and inert(m.ir, v)) continue;
            if (!written[k]) {
                const atom = switch (m.ir.tag(v)) {
                    .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => literalLen(m.ir, v) <= 5 or uses[k] <= 1,
                    // A name declared twice in the declaration may mean
                    // another binding where the key is read.
                    .ident => try s.atomArgument(m, v, top, s.assigned) and
                        (m.globalOf(@fromBackingInt(@intCast(m.ir.data(v).lhs))) != null or try declCount(s, m, top, @fromBackingInt(@intCast(m.ir.data(v).lhs))) <= 1),
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
        // Each read becomes, where it stands, its key's name or atom: what
        // is kept of `top` is brought up to date by those reads alone —
        // unless what holds a read counts it (`x.k = v`, `x.k(…)`, `x.k.j`),
        // when it is counted again.
        const roots = try s.arena.alloc(u32, members.items.len);
        for (roots, members.items) |*r, node| r.* = node.int();
        const alone = use.written.items.len == 0 and use.called.items.len == 0 and use.deep.items.len == 0;
        const delta = if (alone) try s.retract(m, top, roots) else null;
        for (members.items) |node| {
            // A node two parents share is met twice.
            if (m.ir.tag(node) != .member) continue;
            const id = s.pts.propId(m.index, @fromBackingInt(@intCast(m.ir.data(node).rhs)));
            const k = std.mem.indexOfScalar(u32, ids, id).?;
            if (atoms[k]) |a| try m.copyNode(s.gpa, node, a) else m.setNode(node, .ident, names[k].int(), 0);
        }
        if (delta) |r| try s.extend(m, top, r, roots);
        return true;
    }

    /// Whether `v` is a `Js.method` function (`arrow_method`), written in
    /// place or the value of a top-level `const` it names.
    fn methodValue(s: *Spec, m: *Mod, v: Index) bool {
        const ir = m.ir;
        switch (ir.tag(v)) {
            .arrow => return ir.data(v).rhs == Node.arrow_method,
            .ident => {
                const g = m.globalOf(@fromBackingInt(@intCast(ir.data(v).lhs))) orelse return false;
                if (g >= s.decl.len) return false;
                const d = s.decl[g] orelse return false;
                const dir = s.mods[d.module].ir;
                if (dir.tag(d.stmt) != .const_decl) return false;
                const value: Index = @fromBackingInt(@intCast(dir.data(d.stmt).rhs));
                return dir.tag(value) == .arrow and dir.data(value).rhs == Node.arrow_method;
            },
            else => return false,
        }
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
        /// The whole-program id of the top-level declaration the function
        /// is, or `none` for one a call reaches through a property.
        owner: u32 = none,
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
        /// Per parameter: read, and only ever as the object of a property
        /// read — `e` inspects it (slice 9).
        inspects: []bool,
        /// The fact-3 site of a function reached through a property, or
        /// `none`: when the program's one use of it is one call
        /// (`soleCalls`), the size model is not asked.
        site: u32 = none,
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
            const expressions = try s.inlineSmallPass(pass == 0 and s.pts.ok);
            const statements = try s.inlineStatementsPass();
            if (!expressions and !statements) break;
            any = true;
            if (pass == 3) s.stats.inline_capped += 1;
        }
        return any;
    }

    /// `backend.md` §9, *Slice 8*, amended (*a statement*): a top-level
    /// function whose body is one assignment, `x = e` or `o.p = e`, called
    /// as a statement — its value read by nothing — is that assignment,
    /// its parameters the arguments, where that is no larger than the call.
    /// Every argument is an atom, so each is evaluated once, and before the
    /// assignment runs, as in the call. True when any was.
    fn inlineStatementsPass(s: *Spec) Allocator.Error!bool {
        const smalls = try s.arena.alloc(?Small, s.globals);
        @memset(smalls, null);
        var found = false;
        for (s.decl, 0..) |maybe, gi| {
            const decl = maybe orelse continue;
            const g: u32 = @intCast(gi);
            if (s.assigned[g]) continue;
            const fm = &s.mods[decl.module];
            if (fm.ir.tag(decl.stmt) != .const_decl) continue;
            if (std.mem.indexOfScalar(Index, fm.ir.extraSlice(fm.ir.body, Index), decl.stmt) == null) continue;
            smalls[g] = try s.statementOf(decl.module, @fromBackingInt(@intCast(fm.ir.data(decl.stmt).rhs)), g);
            found = found or smalls[g] != null;
        }
        if (!found) return false;
        // Every mention of each candidate, and every call of one made as a
        // statement. It is written in at every call or at none: only when
        // the calls are all its mentions does its declaration go, and only
        // then is the whole smaller — `stop` called in eight places is
        // eight assignments where it was eight calls and one function.
        const Site = struct { module: u32, top: Index, stmt: Index, g: u32 };
        var sites: std.ArrayList(Site) = .empty;
        const mentions = try s.arena.alloc(u32, s.globals);
        @memset(mentions, 0);
        for (s.mods, 0..) |*m, mi| {
            const ir = m.ir;
            for (ir.extraSlice(ir.body, Index)) |top| {
                for (try s.preorder(m, top)) |node| {
                    const t = ir.tag(node);
                    if (t == .ident) {
                        if (m.globalOf(@fromBackingInt(@intCast(ir.data(node).lhs)))) |g| if (smalls[g] != null) {
                            mentions[g] += 1;
                        };
                    } else if (t == .expr_stmt) {
                        const call: Index = @fromBackingInt(@intCast(ir.data(node).lhs));
                        if (ir.tag(call) == .call) {
                            const callee: Index = @fromBackingInt(@intCast(ir.data(call).lhs));
                            if (ir.tag(callee) == .ident) if (m.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs)))) |g| if (smalls[g] != null) {
                                try sites.append(s.arena, .{ .module = @intCast(mi), .top = top, .stmt = node, .g = g });
                            };
                        }
                    }
                }
            }
        }
        // Per candidate: its calls, whether each may be written in, and
        // the bytes that would save.
        const calls = try s.arena.alloc(u32, s.globals);
        @memset(calls, 0);
        const ok = try s.arena.alloc(bool, s.globals);
        @memset(ok, true);
        const saved = try s.arena.alloc(i64, s.globals);
        @memset(saved, 0);
        for (sites.items) |site| {
            calls[site.g] += 1;
            const delta = try s.statementSite(&s.mods[site.module], site.module, site.top, site.stmt, smalls[site.g].?);
            if (delta) |d| saved[site.g] += d else ok[site.g] = false;
        }
        var any = false;
        for (sites.items) |site| {
            const g = site.g;
            const small = smalls[g].?;
            if (!ok[g] or calls[g] != mentions[g] or s.escaped[g]) continue;
            // The declaration that goes: `g=(…)=>{…},`.
            const declaration: i64 = @as(i64, small.cost) + 2 * @as(i64, @intCast(small.params.len)) + 8;
            if (saved[g] + declaration <= 0) continue;
            try s.inlineStatementAt(&s.mods[site.module], site.module, site.stmt, small);
            any = true;
        }
        return any;
    }

    /// Arrow `value` of module `module` as a statement `inlineStatementsPass`
    /// may write in, or null: one assignment to a name or a property,
    /// holding no function and no `yield`, naming nothing but its
    /// parameters and whole-program names, and not `self`. `ret` is the
    /// assignment.
    fn statementOf(s: *Spec, module: u32, value: Index, self: u32) Allocator.Error!?Small {
        const fm = &s.mods[module];
        if (fm.ir.tag(value) != .arrow or fm.ir.data(value).rhs != Node.arrow_plain) return null;
        const f = fm.ir.extraData(@fromBackingInt(@intCast(fm.ir.data(value).lhs)), JsIr.Func);
        const body = fm.ir.extraSlice(f.body(), Index);
        if (body.len == 0 or body.len > 2 or fm.ir.tag(body[0]) != .assign_stmt) return null;
        // A unit function's `return null` after it: its value is read by
        // nothing where this is written.
        if (body.len == 2) {
            if (fm.ir.tag(body[1]) != .return_stmt) return null;
            if ((@as(Node.OptionalIndex, @fromBackingInt(@intCast(fm.ir.data(body[1]).lhs)))).unwrap()) |v| switch (fm.ir.tag(v)) {
                .null_lit, .undefined_lit => {},
                else => return null,
            };
        }
        const assign = body[0];
        const params = try s.arena.dupe(NameIndex, fm.ir.extraSlice(f.params(), NameIndex));
        for (params, 0..) |p, i| if (std.mem.indexOfScalar(NameIndex, params[0..i], p) != null) return null;
        const reads = try s.arena.alloc(u32, params.len);
        @memset(reads, 0);
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        const d = fm.ir.data(assign);
        const target: Index = @fromBackingInt(@intCast(d.lhs));
        switch (fm.ir.tag(target)) {
            .ident, .member => {},
            else => return null,
        }
        try JsIr.pushOperandSlice(s.arena, &stack, &.{ target, @fromBackingInt(@intCast(d.rhs)) });
        var nodes: u32 = 0;
        // `nodeCount` prices `true`, `false` and `null` short; written
        // in, each is its text.
        var literals: u32 = 0;
        while (JsIr.popOperand(&stack)) |node| {
            nodes += 1;
            if (nodes > 24) return null;
            switch (fm.ir.tag(node)) {
                .true_lit, .null_lit, .false_lit => literals += 3,
                .arrow => return null,
                .ident => {
                    const x: NameIndex = @fromBackingInt(@intCast(fm.ir.data(node).lhs));
                    if (std.mem.indexOfScalar(NameIndex, params, x)) |i| {
                        reads[i] += 1;
                    } else if (fm.globalOf(x)) |h| {
                        if (h == self) return null;
                    } else return null;
                },
                .unary => if (@as(JsIr.UnaryOp, @fromBackingInt(@intCast(fm.ir.data(node).rhs))) == .yield) return null,
                else => {},
            }
            try fm.ir.pushOperands(s.arena, &stack, node);
        }
        // An assignment to a parameter would assign the argument's binding.
        if (fm.ir.tag(target) == .ident and std.mem.indexOfScalar(NameIndex, params, @fromBackingInt(@intCast(fm.ir.data(target).lhs))) != null) return null;
        return .{
            .module = module,
            .params = params,
            .ret = assign,
            .cost = nodeCount(fm.ir, target, &s.pts, module) + nodeCount(fm.ir, @fromBackingInt(@intCast(d.rhs)), &s.pts, module) + 1 + literals,
            .reads = reads,
            .first = &.{},
            .inspects = &.{},
            .owner = self,
        };
    }

    /// Whether call statement `stmt` of module `mi` may be `small`'s
    /// assignment, and if so the bytes that saves (negative: costs): every
    /// argument an atom, and not a statement a release build drops when it
    /// is pure.
    fn statementSite(s: *Spec, m: *Mod, mi: u32, top: Index, stmt: Index, small: Small) Allocator.Error!?i64 {
        if (m.tables) |t| if (std.mem.indexOfScalar(Index, t.discards.items, stmt) != null) return null;
        // An assignment to another module's binding is one only a single
        // scope can write.
        if (small.module != mi and !s.in.one_scope) return null;
        const call: Index = @fromBackingInt(@intCast(m.ir.data(stmt).lhs));
        const args = m.ir.extraSlice(m.ir.subRange(@fromBackingInt(@intCast(m.ir.data(call).rhs))), Index);
        if (args.len != small.params.len) return null;
        var call_cost: i64 = 3 + @as(i64, @intCast(if (args.len > 0) args.len - 1 else 0));
        var inlined: i64 = small.cost;
        for (args, 0..) |a, i| {
            const c = nodeCount(m.ir, a, &s.pts, mi);
            call_cost += c;
            inlined += @as(i64, small.reads[i]) * (@as(i64, c) - 1);
            const atom = switch (m.ir.tag(a)) {
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => literalLen(m.ir, a) <= 5 or small.reads[i] <= 1,
                .ident => try s.atomArgument(m, a, top, s.assigned),
                else => false,
            };
            if (!atom) return null;
        }
        return call_cost - inlined;
    }

    /// Call statement `stmt` of module `mi` written as `small`'s assignment,
    /// once `statementSite` has allowed it.
    fn inlineStatementAt(s: *Spec, m: *Mod, mi: u32, stmt: Index, small: Small) Allocator.Error!void {
        const call: Index = @fromBackingInt(@intCast(m.ir.data(stmt).lhs));
        const args = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.subRange(@fromBackingInt(@intCast(m.ir.data(call).rhs))), Index));
        s.noteCopy(small.module, small.owner);
        const fm = &s.mods[small.module];
        const cross = small.module != mi;
        var c: Copy = .{
            .s = s,
            .src = fm,
            .dst = m,
            .cross = cross,
            .site = m.ir.pos(call),
            .renamed = try s.arena.alloc(u32, fm.ir.names.len),
            .subst = try s.arena.alloc(Node.OptionalIndex, fm.ir.names.len),
        };
        @memset(c.renamed, none);
        @memset(c.subst, .none);
        if (cross) {
            var stack = try s.takeStack();
            defer s.giveStack(&stack);
            const d = fm.ir.data(small.ret);
            try JsIr.pushOperandSlice(s.arena, &stack, &.{ @fromBackingInt(@intCast(d.lhs)), @fromBackingInt(@intCast(d.rhs)) });
            while (JsIr.popOperand(&stack)) |node| {
                if (fm.ir.tag(node) == .ident) {
                    const x: NameIndex = @fromBackingInt(@intCast(fm.ir.data(node).lhs));
                    if (std.mem.indexOfScalar(NameIndex, small.params, x) == null) {
                        const h = fm.globalOf(x).?;
                        const to = try s.nameIn(m, h) orelse return;
                        c.renamed[x.int()] = to.int();
                    }
                }
                try fm.ir.pushOperands(s.arena, &stack, node);
            }
        }
        for (small.params, args) |p, a| if (p.unwrap()) |pi| {
            c.subst[pi] = a.toOptional();
        };
        const copied = try c.stmt(small.ret, 0);
        try m.copyNode(s.gpa, stmt, copied);
    }

    /// Arrow `value` of module `module` as slice 8 sees it, or null: one
    /// `return e`, `e` small, holding no function and no `yield`, naming
    /// nothing but its parameters and whole-program names — and not `self`,
    /// the name it is declared by, when it has one.
    /// `iife`: `value` is the callee of a call that makes it
    /// (`inlineIifes`), so the body is written where it was made, and a
    /// name of a function around it means there what it meant here.
    fn smallOf(s: *Spec, module: u32, value: Index, self: ?u32, iife: bool) Allocator.Error!?Small {
        const fm = &s.mods[module];
        if (fm.ir.tag(value) != .arrow or fm.ir.data(value).rhs != Node.arrow_plain) return null;
        const f = fm.ir.extraData(@fromBackingInt(@intCast(fm.ir.data(value).lhs)), JsIr.Func);
        const body = fm.ir.extraSlice(f.body(), Index);
        const ret = try s.returnExpr(module, body, 0) orelse return null;
        // Copied: writing a body in appends to `extra`, which may move it.
        const params = try s.arena.dupe(NameIndex, fm.ir.extraSlice(f.params(), NameIndex));
        for (params, 0..) |p, i| if (std.mem.indexOfScalar(NameIndex, params[0..i], p) != null) return null;
        const reads = try s.arena.alloc(u32, params.len);
        @memset(reads, 0);
        const member_reads = try s.arena.alloc(u32, params.len);
        @memset(member_reads, 0);
        var cost: u32 = 0;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, ret);
        while (JsIr.popOperand(&stack)) |node| {
            cost += 1;
            if (cost > 24) return null;
            switch (fm.ir.tag(node)) {
                .member => {
                    const obj: Index = @fromBackingInt(@intCast(fm.ir.data(node).lhs));
                    if (fm.ir.tag(obj) == .ident) if (std.mem.indexOfScalar(NameIndex, params, @fromBackingInt(@intCast(fm.ir.data(obj).lhs)))) |i| {
                        member_reads[i] += 1;
                    };
                },
                // A function in it is made on each call: kept out, with its
                // declarations and captures.
                .arrow => return null,
                .ident => {
                    const x: NameIndex = @fromBackingInt(@intCast(fm.ir.data(node).lhs));
                    if (std.mem.indexOfScalar(NameIndex, params, x)) |i| {
                        reads[i] += 1;
                    } else if (fm.globalOf(x)) |h| {
                        // Itself: a recursion is no expression.
                        if (self != null and h == self.?) return null;
                    } else if (!iife) return null;
                },
                .unary => if (@as(JsIr.UnaryOp, @fromBackingInt(@intCast(fm.ir.data(node).rhs))) == .yield) return null,
                else => {},
            }
            try fm.ir.pushOperands(s.arena, &stack, node);
        }
        const first = try s.arena.alloc(bool, params.len);
        for (params, first, reads) |p, *fi, r| fi.* = r == 1 and firstUse(fm.ir, ret, p, 0) == .found;
        const inspects = try s.arena.alloc(bool, params.len);
        for (inspects, reads, member_reads) |*x, r, mr| x.* = r > 0 and r == mr;
        return .{
            .module = module,
            .params = params,
            .ret = ret,
            .cost = nodeCount(fm.ir, ret, &s.pts, module),
            .reads = reads,
            .first = first,
            .inspects = inspects,
            .owner = self orelse none,
        };
    }

    /// The one expression a function body of returns is: `return e`, or
    /// `if (t) return a; return b` (either arm a block of its own, or the
    /// `else`) as `t ? a : b`, nested — the `case` lowering's shape, which
    /// the printer writes as the conditional. A conditional made for it is
    /// a node of its own, reached from nowhere but the copies made of it.
    /// Null for any other body.
    fn returnExpr(s: *Spec, module: u32, body_in: []const Index, depth: u32) Allocator.Error!?Index {
        if (depth > 8 or body_in.len == 0) return null;
        // A copy below appends to `extra`, which may move: the body is read
        // from a copy of its own (#770).
        const body = try s.arena.dupe(Index, body_in);
        const fm = &s.mods[module];
        const ir = fm.ir;
        const first = body[0];
        if (ir.tag(first) == .return_stmt) {
            if (body.len != 1) return null;
            return (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(first).lhs)))).unwrap();
        }
        // `const v = e; …return R` with `R` reading `v` once, first: `R`
        // with `e` in its place, evaluated where it was.
        if (ir.tag(first) == .const_decl) {
            const v: NameIndex = @fromBackingInt(@intCast(ir.data(first).lhs));
            if (fm.globalOf(v) != null) return null;
            const r = try s.returnExpr(module, body[1..], depth + 1) orelse return null;
            if (firstUse(ir, r, v, 0) != .found) return null;
            var reads: u32 = 0;
            var stack = try s.takeStack();
            defer s.giveStack(&stack);
            try JsIr.pushOperand(s.arena, &stack, r);
            while (JsIr.popOperand(&stack)) |node| {
                if (ir.tag(node) == .ident and ir.data(node).lhs == v.int()) reads += 1;
                if (ir.tag(node) == .arrow) return null;
                try ir.pushOperands(s.arena, &stack, node);
            }
            if (reads != 1) return null;
            var c: Copy = .{
                .s = s,
                .src = fm,
                .dst = fm,
                .cross = false,
                .renamed = try s.arena.alloc(u32, fm.names.items.len),
                .subst = try s.arena.alloc(Node.OptionalIndex, fm.names.items.len),
            };
            @memset(c.renamed, none);
            @memset(c.subst, .none);
            c.subst[v.int()] = (@as(Index, @fromBackingInt(@intCast(ir.data(first).rhs)))).toOptional();
            return try c.expr(r, 0);
        }
        // `o.f = v; …return R`, a store of a record written in place as a
        // statement (`Lower.settleStores`): `(o.f = v, R)`, evaluated in the
        // same order.
        if (ir.tag(first) == .expr_stmt) {
            const e: Index = @fromBackingInt(@intCast(ir.data(first).lhs));
            if (ir.tag(e) != .assign) return null;
            const r = try s.returnExpr(module, body[1..], depth + 1) orelse return null;
            var parts: std.ArrayList(u32) = .empty;
            try parts.append(s.arena, e.int());
            if (ir.tag(r) == .sequence) {
                try parts.appendSlice(s.arena, ir.extraSlice(JsIr.inlineRange(ir.data(r)), u32));
            } else try parts.append(s.arena, r.int());
            const start = try fm.append(s.gpa, parts.items);
            return try fm.addNode(s.gpa, .sequence, ir.pos(first), start, start + @as(u32, @intCast(parts.items.len)));
        }
        if (ir.tag(first) != .if_stmt) return null;
        const b = ir.extraData(@fromBackingInt(@intCast(ir.data(first).rhs)), JsIr.If);
        const then = try s.arena.dupe(Index, ir.extraSlice(b.thenBody(), Index));
        const els = try s.arena.dupe(Index, ir.extraSlice(b.elseBody(), Index));
        const a = try s.returnExpr(module, then, depth + 1) orelse return null;
        const rest: []const Index = if (els.len != 0) blk: {
            if (body.len != 1) return null;
            break :blk els;
        } else body[1..];
        const c = try s.returnExpr(module, rest, depth + 1) orelse return null;
        const record = try fm.append(s.gpa, &.{ a.int(), c.int() });
        const cond = try fm.addNode(s.gpa, .cond, ir.pos(first), ir.data(first).lhs, record);
        return cond;
    }

    /// Every top-level function slice 8 may write in, by whole-program id.
    fn smallTable(s: *Spec) Allocator.Error![]?Small {
        const smalls = try s.arena.alloc(?Small, s.globals);
        @memset(smalls, null);
        for (s.decl, 0..) |maybe, gi| {
            const decl = maybe orelse continue;
            const g: u32 = @intCast(gi);
            if (s.assigned[g]) continue;
            const fm = &s.mods[decl.module];
            if (fm.ir.tag(decl.stmt) != .const_decl) continue;
            if (std.mem.indexOfScalar(Index, fm.ir.extraSlice(fm.ir.body, Index), decl.stmt) == null) continue;
            smalls[g] = try s.smallOf(decl.module, @fromBackingInt(@intCast(fm.ir.data(decl.stmt).rhs)), g, false);
        }
        return smalls;
    }

    fn inlineSmallPass(s: *Spec, resolve: bool) Allocator.Error!bool {
        const smalls = try s.smallTable();
        // A function a call reaches through a property — `kind.m(…)` — when
        // fact 3 says the callee is that one function, reading it does
        // nothing, and the facts are of the program as it stands.
        // Per site: unasked, not small, or its `Small`.
        const by_site = try s.arena.alloc(?Small, if (resolve) s.pts.sites.items.len else 0);
        const asked = try s.arena.alloc(bool, by_site.len);
        @memset(asked, false);
        s.sole = null;
        s.copied_sites = &.{};
        if (resolve) {
            s.copied_sites = try s.arena.alloc(bool, s.pts.sites.items.len);
            @memset(s.copied_sites, false);
        }
        // Every call of one, in module order.
        var any = false;
        for (s.mods, 0..) |*m, mi| {
            const ir = m.ir;
            var calls: std.ArrayList(struct { top: Index, call: Index, small: Small }) = .empty;
            for (ir.extraSlice(ir.body, Index)) |top| {
                for (try s.preorder(m, top)) |node| {
                    if (ir.tag(node) == .call) {
                        const callee: Index = @fromBackingInt(@intCast(ir.data(node).lhs));
                        if (ir.tag(callee) == .ident) {
                            if (m.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs)))) |g| if (smalls[g]) |small| {
                                try calls.append(s.arena, .{ .top = top, .call = node, .small = small });
                            };
                        } else if (resolve and ir.tag(callee) == .member and callee.int() < s.pts.vals[mi].len) {
                            const v = s.pts.vals[mi][callee.int()];
                            if (!v.top and !v.prim and !v.nullish() and v.sites.len == 1) {
                                const site = v.sites[0];
                                const st = s.pts.sites.items[site];
                                if (st.kind == .func and !st.escaped and try s.pts.safeChain(@intCast(mi), top, callee) != null) {
                                    if (!asked[site]) {
                                        by_site[site] = try s.smallOf(st.module, st.node, null, false);
                                        if (by_site[site]) |*small| small.site = site;
                                    }
                                    asked[site] = true;
                                    if (by_site[site]) |small| try calls.append(s.arena, .{ .top = top, .call = node, .small = small });
                                }
                            }
                        }
                    }
                }
            }
            for (calls.items) |c| {
                if (m.ir.tag(c.call) != .call) continue;
                // Every change is to the call's statement.
                within(m, c.top);
                const did = s.inlineSmallAt(m, @intCast(mi), c.top, c.call, c.small, false) catch |err| {
                    m.scope = null;
                    return err;
                };
                try s.leave(m);
                if (did) any = true;
            }
        }
        return any;
    }

    /// `backend.md` §9, *Slice 8*, amended (*a function used once*): per
    /// fact-3 site, whether the function it makes is used by exactly one
    /// call of the program and nothing else — the callee of one call node
    /// may be it, it does not escape, and every other node that may be it
    /// only holds it: the function itself, an inert key's value in an
    /// object literal whose site neither escapes nor has every key read,
    /// or a binding's inert initialiser. Once that call holds the body,
    /// nothing reads the key or the binding, and the function goes with
    /// them, so the size model, which prices the call against the body
    /// alone, is not asked. A spread (`{ r | … }`) reads every key of `r`,
    /// a key or a top-level binding of a field read (`ops.fn`) is not
    /// dropped, and a local one may be copied into a key: there the
    /// function stays, and the body would be in the output two times.
    fn soleCalls(s: *Spec) Allocator.Error![]const bool {
        // Asked only for a `Small` that the resolving pass gave a site, and
        // that pass runs only when fact 3 holds (`pts.ok`).
        if (std.debug.runtime_safety and !s.pts.ok) unreachable;
        const n = s.pts.sites.items.len;
        const calls = try s.arena.alloc(u32, n);
        @memset(calls, 0);
        const other = try s.arena.alloc(bool, n);
        @memset(other, false);
        for (s.mods, 0..) |*m, mi| {
            const ir = m.ir;
            const vals = s.pts.vals[mi];
            // Per node: the callee of a call, or a place that only holds
            // the value it is — set by the node's parent, which a preorder
            // meets first.
            var callee: std.DynamicBitSetUnmanaged = try .initEmpty(s.arena, ir.nodes.len);
            var holds: std.DynamicBitSetUnmanaged = try .initEmpty(s.arena, ir.nodes.len);
            var key: std.DynamicBitSetUnmanaged = try .initEmpty(s.arena, ir.nodes.len);
            for (ir.extraSlice(ir.body, Index)) |top| {
                for (try s.preorder(m, top)) |node| {
                    // A node past `vals` is a copy this pass made; its uses
                    // are guarded by `copied_sites` (`noteCopiedSites`).
                    const i = node.int();
                    const tag = ir.tag(node);
                    // A key's node is what its value is, and only holds it.
                    if (i < vals.len and !vals[i].top and tag != .property) for (vals[i].sites) |site| {
                        if (s.pts.sites.items[site].kind != .func) continue;
                        if (callee.isSet(i)) {
                            calls[site] += 1;
                        } else if (!holds.isSet(i)) other[site] = true;
                    };
                    const d = ir.data(node);
                    switch (tag) {
                        .call => callee.set(d.lhs),
                        // A key holds its value only while fact 3 can drop
                        // it: of an object literal whose site neither
                        // escapes nor has every key read (`Pts.keyUnread`).
                        .object => if (s.pts.siteAt(@intCast(mi), node)) |site| {
                            const st = s.pts.sites.items[site];
                            if (!st.escaped and !st.all_read) for (ir.extraSlice(JsIr.inlineRange(d), Index)) |prop| {
                                if (ir.tag(prop) == .property) key.set(prop.int());
                            };
                        },
                        // Only an inert value holds: `dropKeys` drops only
                        // such a key, and the pass only such a top-level
                        // binding. Slice 9 may write a local `const`'s
                        // initialiser in its one read (`const x = e;
                        // return R`), so a key of it may become a field
                        // read (`ops.fn`), which stays and keeps the
                        // function.
                        .property => if (key.isSet(i) and inertOf(ir, @fromBackingInt(@intCast(d.rhs)), false)) holds.set(d.rhs),
                        .const_decl => if (inertOf(ir, @fromBackingInt(@intCast(d.rhs)), false)) holds.set(d.rhs),
                        .let_decl => if ((@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs)))).unwrap()) |v| if (inertOf(ir, v, false)) holds.set(v.int()),
                        else => {},
                    }
                }
            }
        }
        const sole = try s.arena.alloc(bool, n);
        for (sole, calls, other, s.pts.sites.items) |*x, c, o, st| x.* = c == 1 and !o and !st.escaped;
        return sole;
    }

    /// Mark in `copied_sites` every function site fact 3 gives a node of
    /// `small`'s body: once the body is copied, each of them may have a use
    /// `soleCalls` does not count. A guard, not an exact count: a node of
    /// the body newer than the facts (an earlier copy into it, what
    /// `returnExpr` made) has no value, so a function that only it may be
    /// is not marked — which costs bytes at most.
    fn noteCopiedSites(s: *Spec, small: Small) Allocator.Error!void {
        const ir = s.mods[small.module].ir;
        const vals = s.pts.vals[small.module];
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, small.ret);
        while (JsIr.popOperand(&stack)) |node| {
            const i = node.int();
            if (i < vals.len and !vals[i].top) for (vals[i].sites) |site| {
                if (s.pts.sites.items[site].kind == .func) s.copied_sites[site] = true;
            };
            try pushChildren(s.arena, ir, node, &stack);
        }
    }

    /// `iife`: the callee is the function the call makes, written in the
    /// same statement, so no size model applies — the function's own text
    /// goes with the call — and nothing is copied out of another statement.
    fn inlineSmallAt(s: *Spec, m: *Mod, mi: u32, top: Index, call: Index, small: Small, iife: bool) Allocator.Error!bool {
        const fm = &s.mods[small.module];
        const passed = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.subRange(@fromBackingInt(@intCast(m.ir.data(call).rhs))), Index));
        // An argument past the parameters is evaluated by the call and read
        // by nothing: one that does nothing (`inert`) goes with the call —
        // `app.init(null)` of a function lowered with no parameter for `⊤`.
        // A top-level function may be passed more too: a function of another
        // module lowered with no parameter for `⊤` is called with `null` for
        // it (`Inline.busy(null)`). Only one called where it is made keeps
        // the exact match: its own text goes with the call.
        if (passed.len < small.params.len or (iife and passed.len != small.params.len)) return false;
        for (passed[small.params.len..]) |a| if (!inert(m.ir, a)) return false;
        const args = passed[0..small.params.len];
        // Arguments: atoms, or one non-atom read once and first.
        // The callee, the brackets and the commas.
        var call_cost: u32 = 3 + @as(u32, @intCast(if (passed.len > 0) passed.len - 1 else 0));
        for (passed[small.params.len..]) |a| call_cost += nodeCount(m.ir, a, &s.pts, mi);
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
        if (!iife) {
            if (inlined > call_cost) {
                if (small.site == none) return false;
                if (s.sole == null) s.sole = try s.soleCalls();
                if (!s.sole.?[small.site] or s.copied_sites[small.site]) return false;
            }
            s.noteCopy(small.module, small.owner);
            if (s.copied_sites.len != 0) try s.noteCopiedSites(small);
        }

        // Names the body mentions of the whole program, as the caller
        // module spells them.
        const cross = small.module != mi;
        var c: Copy = .{
            .s = s,
            .src = fm,
            .dst = m,
            .cross = cross,
            .site = m.ir.pos(call),
            .renamed = try s.arena.alloc(u32, fm.ir.names.len),
            .subst = try s.arena.alloc(Node.OptionalIndex, fm.ir.names.len),
        };
        @memset(c.renamed, none);
        @memset(c.subst, .none);
        if (cross) {
            var stack = try s.takeStack();
            defer s.giveStack(&stack);
            try JsIr.pushOperand(s.arena, &stack, small.ret);
            while (JsIr.popOperand(&stack)) |node| {
                if (fm.ir.tag(node) == .ident) {
                    const x: NameIndex = @fromBackingInt(@intCast(fm.ir.data(node).lhs));
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
        // As `inlineAt` writes a call as an expression.
        const delta = try s.retractCall(m, top, call, e);
        try m.copyNode(s.gpa, call, e);
        if (delta) |r| try s.extend(m, top, r, &.{call.int()});
        return true;
    }

    // ---- Slice 10: a value read once at start-up ---------------------------

    /// Where a module's start-up reads a whole-program name: the node, and
    /// the top-level statement (by its place in the body) it stands in.
    const StartRead = struct { module: u32, top: u32, node: Index };

    /// `backend.md` §9, *Slice 10 — a value read once at start-up*: a
    /// top-level `const` whose initialiser only makes a value (`inert`),
    /// whose name the whole program mentions once, in a later top-level
    /// statement of its own module, where the module's start-up evaluates
    /// that mention exactly once — under no function and no loop — is
    /// written there, and not written at all. The value is still made
    /// once, by the same expression, before anything can see it: the one
    /// mention is the only way to it. Run last, after every fact is spent
    /// (a copy's nodes are in no fact). True when any was written.
    fn inlineReads(s: *Spec) Allocator.Error!bool {
        if (s.in.fresh == .none) return false;
        try s.inlineScan();
        const n = s.globals;
        const refs = s.io_refs[0..n];
        const assigned = try s.arena.alloc(bool, n);
        for (assigned, s.io_assigned[0..n]) |*a, k| a.* = k != 0;
        // Every name mentioned once whose one mention a module's start-up
        // evaluates once: that mention.
        const sites = try s.arena.alloc(?StartRead, n);
        @memset(sites, null);
        for (s.mods, 0..) |*m, mi| try s.startReads(m, @intCast(mi), refs, sites);
        var any = false;
        for (s.mods, 0..) |*m, mi| {
            const body = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.body, Index));
            // One module's scratch for every copy made in it, so that a copy
            // costs what the value holds and not what the module names.
            var scratch: ReadCopy = .{};
            for (body, 0..) |stmt, ti| {
                if (m.ir.tag(stmt) != .const_decl) continue;
                const g = m.globalOf(@fromBackingInt(@intCast(m.ir.data(stmt).lhs))) orelse continue;
                if (g >= n or refs[g] != 1 or assigned[g] or isRoot(s.in, g)) continue;
                const decl = s.decl[g] orelse continue;
                if (decl.module != mi or decl.stmt != stmt) continue;
                const at = sites[g] orelse continue;
                if (at.module != mi or at.top <= ti) continue;
                // Made later, so a field read would cross what runs between:
                // only a value that reads nothing moves (§9 item 1, amended
                // 2026-10-18, *the ordering rule*).
                const value: Index = @fromBackingInt(@intCast(m.ir.data(stmt).rhs));
                if (!inertOf(m.ir, value, false)) continue;
                // A name the value reads as it is made holds the same value
                // when it is made later: nothing assigns it.
                if (!try s.immutableNames(m, value, stmt, assigned)) continue;
                if (try s.writeRead(m, @intCast(mi), g, value, at.node, &scratch)) any = true;
            }
        }
        return any;
    }

    /// The names module `m` mentions once in the whole program (`refs`),
    /// each with that mention, when the module's start-up evaluates it
    /// exactly once: in a top-level statement, under no function (an
    /// arrow, a `function`) and no loop, and neither an assignment's target
    /// nor a statement of its own.
    fn startReads(s: *Spec, m: *Mod, mi: u32, refs: []const u32, out: []?StartRead) Allocator.Error!void {
        var stack: std.ArrayList(Index) = .empty;
        var once: std.ArrayList(bool) = .empty;
        var children = try s.takeStack();
        defer s.giveStack(&children);
        const ir = m.ir;
        for (ir.extraSlice(ir.body, Index), 0..) |top, ti| {
            stack.clearRetainingCapacity();
            once.clearRetainingCapacity();
            try stack.append(s.arena, top);
            try once.append(s.arena, true);
            while (stack.pop()) |node| {
                const here = once.pop().?;
                const t = ir.tag(node);
                if (t == .ident) {
                    if (!here) continue;
                    const g = m.globalOf(@fromBackingInt(@intCast(ir.data(node).lhs))) orelse continue;
                    if (g < refs.len and refs[g] == 1) out[g] = .{ .module = mi, .top = @intCast(ti), .node = node };
                    continue;
                }
                children.clearRetainingCapacity();
                try pushChildren(s.arena, ir, node, &children);
                // Every function `JsIr` has is one of these three tags — an
                // arrow of any kind (`arrow_plain`, `arrow_depth`, and
                // `arrow_method`, the `function` a `Js.method` is), or a
                // declared `function` or generator — and every loop is one
                // of the two after them: what runs a mention again, or
                // later, is under one of these five.
                const repeats = switch (t) {
                    .arrow, .func_decl, .gen_decl, .while_true, .for_of => true,
                    else => false,
                };
                const d = ir.data(node);
                for (children.items) |c| {
                    var below = here and !repeats;
                    if ((t == .assign_stmt or t == .assign) and c.int() == d.lhs) below = false;
                    if (t == .expr_stmt and ir.tag(c) == .ident) below = false;
                    if ((t == .call or t == .new_call) and c.int() == d.lhs) below = false;
                    try stack.append(s.arena, c);
                    try once.append(s.arena, below);
                }
            }
        }
    }

    /// `writeRead`'s scratch, kept across one module's copies: `renamed` is
    /// `Copy.renamed`, all `none` between copies (each copy puts back the
    /// entries it set), and `seen` marks a local met by the current copy's
    /// walk with that copy's number.
    const ReadCopy = struct {
        renamed: std.ArrayList(u32) = .empty,
        seen: std.ArrayList(u32) = .empty,
        copy: u32 = 0,
        locals: std.ArrayList(u32) = .empty,

        /// Both columns as long as the module's names, which a copy grows.
        fn fit(r: *ReadCopy, arena: Allocator, names: usize) Allocator.Error!void {
            while (r.renamed.items.len < names) try r.renamed.append(arena, none);
            while (r.seen.items.len < names) try r.seen.append(arena, 0);
        }
    };

    /// Note `n`, met by `writeRead`'s walk, among the locals the copy renames.
    fn readCopyLocal(s: *Spec, m: *Mod, scratch: *ReadCopy, n: NameIndex) Allocator.Error!void {
        const i = n.unwrap() orelse return;
        if (i >= scratch.seen.items.len or m.globalOf(n) != null) return;
        if (scratch.seen.items[i] == scratch.copy) return;
        scratch.seen.items[i] = scratch.copy;
        try scratch.locals.append(s.arena, i);
    }

    /// Write top-level value `value` of module `m`, declared as whole-program
    /// name `g`, at its one read `site`: a copy whose every local is new,
    /// so that none meets a name of the statement it now stands in. False
    /// when the value is too big or too deep to copy.
    fn writeRead(s: *Spec, m: *Mod, mi: u32, g: u32, value: Index, site: Index, scratch: *ReadCopy) Allocator.Error!bool {
        const ir = m.ir;
        try scratch.fit(s.arena, ir.names.len);
        scratch.copy += 1;
        scratch.locals.clearRetainingCapacity();
        // Every local the value names — each is bound inside it, since a
        // top-level value stands in no function — and how big it is.
        var stack: std.ArrayList(Index) = .empty;
        var depths: std.ArrayList(u32) = .empty;
        var children = try s.takeStack();
        defer s.giveStack(&children);
        try stack.append(s.arena, value);
        try depths.append(s.arena, 0);
        var nodes: u32 = 0;
        while (stack.pop()) |node| {
            const depth = depths.pop().?;
            nodes += 1;
            if (nodes > max_inline_nodes or depth > max_inline_depth) return false;
            const d = ir.data(node);
            const named: []const u32 = switch (ir.tag(node)) {
                .ident, .const_decl, .let_decl, .func_decl, .gen_decl, .for_of, .while_true, .block_stmt, .break_stmt, .continue_stmt => &.{d.lhs},
                .try_stmt => &.{@backingInt(ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try).catch_name)},
                else => &.{},
            };
            for (named) |x| try s.readCopyLocal(m, scratch, @fromBackingInt(@intCast(x)));
            const func: ?ExtraIndex = switch (ir.tag(node)) {
                .arrow => @fromBackingInt(@intCast(d.lhs)),
                .func_decl, .gen_decl => @fromBackingInt(@intCast(d.rhs)),
                else => null,
            };
            if (func) |record| for (ir.extraSlice(ir.extraData(record, JsIr.Func).params(), NameIndex)) |p| try s.readCopyLocal(m, scratch, p);
            children.clearRetainingCapacity();
            try pushChildren(s.arena, ir, node, &children);
            for (children.items) |c| {
                try stack.append(s.arena, c);
                try depths.append(s.arena, depth + 1);
            }
        }
        // No parameter is substituted; `fresh` grows the module's names, so
        // the column `Copy` reads is the one sized before it.
        var c: Copy = .{
            .s = s,
            .src = m,
            .dst = m,
            .cross = false,
            .renamed = scratch.renamed.items,
            .subst = &.{},
        };
        // In the order of the names, as one walk of every local would meet them.
        std.mem.sortUnstable(u32, scratch.locals.items, {}, std.sort.asc(u32));
        for (scratch.locals.items) |i| try c.fresh(i, false);
        s.noteCopy(mi, g);
        const e = try c.expr(value, 0);
        for (scratch.locals.items) |i| scratch.renamed.items[i] = none;
        try m.foldTo(s.gpa, site, e);
        // The table lowering handed the printer names the copy's root; the
        // root is now `site`.
        if (m.tables) |t| if (std.mem.indexOfScalar(Index, t.unobserved.items, e) != null) try t.unobserved.append(s.arena, site);
        return true;
    }

    // ---- Slice 5: a function called once, once the whole program is seen ----

    /// `backend.md` §9, *A function called once is written where it is
    /// called*, *Once the whole program is in view*: every top-level
    /// function the program calls from exactly one place, written there.
    /// One count of the program (`inlineBatch`) writes every candidate it
    /// finds that no write before it in the same count touched; the
    /// program is counted again while a count wrote any. After the facts,
    /// whose per-node tables it does not grow. Bounded by the nodes it
    /// copies (`copyLimit`), not by a number of functions. True when any
    /// was written.
    fn inlineOnce(s: *Spec) Allocator.Error!bool {
        if (s.in.fresh == .none) return false;
        // The index holds within this pass only: other passes move nodes.
        for (s.mods) |*m| {
            for (m.place_at.items) |*e| e.top = none_index;
            @memset(m.place_top.items, none);
        }
        // So do the refusals: the facts and `prune` between two passes
        // change what a refusal read.
        if (s.io_refused.len != s.globals) s.io_refused = try s.arena.alloc(Refusal, s.globals);
        @memset(s.io_refused, .{});
        const limit = s.copyLimit();
        var any = false;
        while (true) {
            const b = try s.inlineBatch(limit);
            if (b.wrote) any = true;
            if (b.capped) {
                s.stats.inline_capped += 1;
                break;
            }
            if (!b.wrote) break;
        }
        return any;
    }

    /// The nodes of every module.
    fn programNodes(s: *const Spec) u64 {
        var n: u64 = 0;
        for (s.mods) |*m| n += m.ir.nodes.len;
        return n;
    }

    /// The most nodes the program may hold before one pass of `inlineOnce`
    /// or `fuseCalls` stops writing: a bound on the work and the output's
    /// growth, not on what is written. Writing a function called once moves
    /// its body; it copies it only into a body that is itself written in
    /// later, so a pass copies each node a few times at most, and the bound
    /// is `copy_budget` times the program it began with.
    fn copyLimit(s: *const Spec) u64 {
        const n = s.programNodes();
        return n + @max(n * copy_budget, min_copy_budget);
    }

    /// `inlineOnce`'s memory of a call `inlineAt` declined: the call, and
    /// the `Mod.version` of the callee's module and the caller's then.
    /// Nothing else it asks changes within a pass in a way that could let
    /// it write the call after all (`inlineBatch`).
    const Refusal = struct {
        module: u32 = none,
        top: Index = none_index,
        call: Index = none_index,
        callee_version: u32 = 0,
        caller_version: u32 = 0,
    };

    /// What one count of `inlineOnce` did: wrote a function, and stopped
    /// at `copyLimit` with candidates left.
    const Batch = struct { wrote: bool = false, capped: bool = false };

    const CallSite = struct { module: u32, top: Index, call: Index };

    /// One module's part of `inlineBatch`'s count, as of the module's
    /// `version`: one entry per whole-program name the module mentions or
    /// assigns, with its mentions, its last call and whether it is
    /// assigned. Sparse, so that counting a module again costs what it
    /// names and not what the whole program names (#742).
    const InlineScan = struct {
        version: u32 = none,
        entries: std.ArrayList(Mention) = .empty,

        const Mention = struct { g: u32, refs: u32, assigned: bool, site: ?CallSite };
    };

    /// The first `n` entries of a scratch column kept across calls in
    /// `keep`, which grows by half again past `n` when the program has more
    /// names than it holds, so that names added one at a time do not take
    /// a new column each. What the entries hold is the caller's to fill.
    fn scratchOf(s: *Spec, comptime T: type, keep: *[]T, n: usize) Allocator.Error![]T {
        if (keep.len < n) keep.* = try s.arena.alloc(T, n + n / 2);
        return keep.*[0..n];
    }

    /// Bring `io_refs` and `io_assigned`, the whole program's counts, up to
    /// date: a module that changed since it was last counted is counted
    /// again, and only that module, at the cost of the names it holds.
    fn inlineScan(s: *Spec) Allocator.Error!void {
        const n = s.globals;
        if (s.io_scans.len != s.mods.len) {
            s.io_scans = try s.arena.alloc(InlineScan, s.mods.len);
            @memset(s.io_scans, .{});
        }
        if (s.io_refs.len != n) {
            // A name was added: every module is counted afresh.
            s.io_refs = try s.scratchOf(u32, &s.io_refs_keep, n);
            @memset(s.io_refs, 0);
            s.io_assigned = try s.scratchOf(u32, &s.io_assigned_keep, n);
            @memset(s.io_assigned, 0);
            for (s.io_scans) |*sc| {
                sc.version = none;
                sc.entries.clearRetainingCapacity();
            }
        }
        // Per name, its entry's place in the module being counted, plus
        // one; zero between modules.
        if (s.io_slot.len < n) {
            s.io_slot = try s.arena.alloc(u32, n + n / 2);
            @memset(s.io_slot, 0);
        }
        const slot = s.io_slot[0..n];
        for (s.mods, s.io_scans, 0..) |*m, *sc, mi| {
            if (sc.version == m.version) continue;
            for (sc.entries.items) |e| {
                s.io_refs[e.g] -= e.refs;
                s.io_assigned[e.g] -= @intFromBool(e.assigned);
            }
            sc.entries.clearRetainingCapacity();
            const ir = m.ir;
            for (ir.extraSlice(ir.body, Index)) |top| {
                for ((try s.nameScan(m, top)).uses.items) |*u| {
                    const g = m.globalOf(@fromBackingInt(@intCast(u.name))) orelse continue;
                    if (slot[g] == 0) {
                        try sc.entries.append(s.arena, .{ .g = g, .refs = 0, .assigned = false, .site = null });
                        slot[g] = @intCast(sc.entries.items.len);
                    }
                    const e = &sc.entries.items[slot[g] - 1];
                    e.refs += u.idents;
                    for (u.calls.items) |call| e.site = .{ .module = @intCast(mi), .top = top, .call = call };
                    if (u.assigns != 0) e.assigned = true;
                }
            }
            for (sc.entries.items) |e| {
                slot[e.g] = 0;
                s.io_refs[e.g] += e.refs;
                s.io_assigned[e.g] += @intFromBool(e.assigned);
            }
            sc.version = m.version;
        }
        // The counts are the program's as it stands.
        s.io_written = false;
        s.io_dropped.clearRetainingCapacity();
    }

    // ---- What a statement says of each name it names (#492) ---------------
    //
    // `inlineScan`, `occurrences`, `declCount`, `onlyInspected`,
    // `replaceScalars`, `foldAt` and `atomArgument` each asked one name, or
    // every whole-program name, of a top-level statement by walking all of
    // it. A page's `update`, every widget's update written in, is tens of
    // thousands of nodes, asked once per binding in it and again after each
    // function written into it. One walk answers every name, kept while the
    // statement stands (`Mod.kept`); and a change that replaces subtrees of
    // the statement, which `retract` and `extend` are told of, keeps it up
    // to date by those subtrees alone.

    /// Per name a top-level statement names, what a walk of it meets.
    const NameScan = struct {
        epoch: u64,
        /// How many nodes the walk meets (`preorder`'s length).
        nodes: u32 = 0,
        /// Per name (`.none` too): in the order the walk first meets each
        /// name, then those an update added.
        uses: std.ArrayList(NameUse) = .empty,
        /// The first `sorted.len` of `uses`, by name: places in `uses`.
        sorted: []const u32 = &.{},
        /// The places in `uses` of the whole-program names `ident`s name,
        /// in the order the walk meets each first (`occurrences`) — while
        /// `ordered`: an update that touched a whole-program name the module
        /// names more than one way clears it, since which name the walk
        /// meets first is then not known.
        globals: std.ArrayList(u32) = .empty,
        ordered: bool = true,
        /// Each object of a member read, target of an assignment or callee
        /// that is neither a name nor a member read: a child its parent
        /// counts once it is one (`retractCall`).
        sensitive: std.ArrayList(Index) = .empty,
        /// The sum of each met node's `contribution`, which a safety build
        /// compares with a walk's (`nameScan`).
        fp: u64 = 0,
    };

    /// One name's part of a `NameScan`. Each list holds a node once for
    /// each time the walk meets it, in no order that matters.
    const NameUse = struct {
        name: u32,
        /// How many times the statement declares it, as `declCount` counts.
        decls: u32 = 0,
        /// `ident`s of it.
        idents: u32 = 0,
        /// Assignments to it.
        assigns: u32 = 0,
        /// Stores of a record written in place into a property of it
        /// (`JsIr.Node.Tag.assign`), whose target must stay a property.
        in_place: u32 = 0,
        /// In `NameScan.globals`.
        listed: bool = false,
        /// `x.k`, `x` an `ident` of it: the member node.
        members: std.ArrayList(Index) = .empty,
        /// `x.k = …`: the target.
        written: std.ArrayList(Index) = .empty,
        /// `x.k(…)`: the callee.
        called: std.ArrayList(Index) = .empty,
        /// `x.k.j`: the outer member, which a change of `x.k` changes too.
        deep: std.ArrayList(Index) = .empty,
        /// Calls whose callee is an `ident` of it.
        calls: std.ArrayList(Index) = .empty,

        /// Its `ident`s that are not the object of a property read: what a
        /// walk that does not go below such a read meets. (`.member` pushes
        /// its object alone, and an `ident` is a leaf.)
        fn bare(u: *const NameUse) u32 {
            return u.idents - @as(u32, @intCast(u.members.items.len));
        }
    };

    /// `nameScan`'s check of a kept or updated scan: what a walk of the
    /// statement meets, summed, and the first name of each whole-program
    /// name; name by name for a small statement.
    fn checkScan(s: *Spec, m: *Mod, top: Index, kept: *NameScan) Allocator.Error!void {
        const nodes = try s.preorderWalk(m, top);
        if (nodes.len > max_checked_walk) return;
        var fp: u64 = 0;
        for (nodes) |node| fp +%= contribution(m.ir, node);
        std.debug.assert(fp == kept.fp and nodes.len == kept.nodes);
        if (kept.ordered) std.debug.assert(try s.sameFirstNames(m, kept, nodes));
        if (nodes.len <= max_compared_scan) std.debug.assert(try s.sameNames(m, kept, try s.scanNames(m, nodes)));
    }

    fn nameScan(s: *Spec, m: *Mod, top: Index) Allocator.Error!*NameScan {
        const key: NodeRef = .{ .module = m.index, .node = top.int() };
        if (s.name_scans.get(key)) |kept| if (m.kept(top, kept.epoch)) {
            // Kept across a change elsewhere in the module, or brought up
            // to date: in a safety build, a test-sized statement is walked
            // again and must say the same. Either way it holds as of now.
            if (std.debug.runtime_safety and kept.epoch != m.epoch and m.ir.nodes.len <= max_checked_module) try s.checkScan(m, top, kept);
            kept.epoch = m.epoch;
            return kept;
        };
        const scan = try s.scanNames(m, try s.preorder(m, top));
        try s.name_scans.put(s.arena, key, scan);
        return scan;
    }

    /// `nameScan`, its `globals` in the walk's order.
    fn nameScanOrdered(s: *Spec, m: *Mod, top: Index) Allocator.Error!*NameScan {
        const scan = try s.nameScan(m, top);
        if (scan.ordered) return scan;
        const fresh = try s.scanNames(m, try s.preorder(m, top));
        try s.name_scans.put(s.arena, .{ .module = m.index, .node = top.int() }, fresh);
        return fresh;
    }

    /// `n`'s uses in `top` (`.none` too, as `declCount` counted it), or
    /// null for none.
    fn usesOf(s: *Spec, m: *Mod, top: Index, n: NameIndex) Allocator.Error!?*const NameUse {
        return findUse(try s.nameScan(m, top), n.int());
    }

    /// Whether an assignment in top-level statement `top` assigns `n`.
    fn assignedInTop(s: *Spec, m: *Mod, top: Index, n: NameIndex) Allocator.Error!bool {
        const u = try s.usesOf(m, top, n) orelse return false;
        return u.assigns != 0;
    }

    /// The scan of the nodes a walk of a statement meets.
    fn scanNames(s: *Spec, m: *Mod, nodes: []const Index) Allocator.Error!*NameScan {
        const scan = try s.arena.create(NameScan);
        scan.* = .{ .epoch = m.epoch };
        // Per name: its place in `uses` plus one, 0 for none, while the walk
        // is counted; cleared again below.
        if (s.ns_slot.len < m.names.items.len) s.ns_slot = try growSlice(s.arena, u32, s.ns_slot, m.names.items.len, 0);
        try s.countNames(m, scan, nodes, .fresh);
        for (scan.uses.items) |u| if (u.name < s.ns_slot.len) {
            s.ns_slot[u.name] = 0;
        };
        const sorted = try s.arena.alloc(u32, scan.uses.items.len);
        for (sorted, 0..) |*x, i| x.* = @intCast(i);
        std.mem.sortUnstable(u32, sorted, scan.uses.items, struct {
            fn less(uses: []const NameUse, a: u32, b: u32) bool {
                return uses[a].name < uses[b].name;
            }
        }.less);
        scan.sorted = sorted;
        return scan;
    }

    fn findUse(scan: *NameScan, n: u32) ?*NameUse {
        const uses = scan.uses.items;
        var lo: usize = 0;
        var hi: usize = scan.sorted.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (uses[scan.sorted[mid]].name < n) lo = mid + 1 else hi = mid;
        }
        if (lo < scan.sorted.len and uses[scan.sorted[lo]].name == n) return &uses[scan.sorted[lo]];
        for (uses[scan.sorted.len..]) |*u| if (u.name == n) return u;
        return null;
    }

    /// `n`'s entry in `scan`, made when it has none (a pointer that the
    /// next entry made may move).
    fn useOf(s: *Spec, scan: *NameScan, n: u32, how: Count) Allocator.Error!*NameUse {
        return &scan.uses.items[try s.useAt(scan, n, how)];
    }

    /// `useOf`'s place in `scan.uses`.
    fn useAt(s: *Spec, scan: *NameScan, n: u32, how: Count) Allocator.Error!u32 {
        if (how == .fresh and n < s.ns_slot.len) {
            const slot = &s.ns_slot[n];
            if (slot.* == 0) {
                try scan.uses.append(s.arena, .{ .name = n });
                slot.* = @intCast(scan.uses.items.len);
            }
            return slot.* - 1;
        }
        if (findUse(scan, n)) |u| return @intCast((@intFromPtr(u) - @intFromPtr(scan.uses.items.ptr)) / @sizeOf(NameUse));
        try scan.uses.append(s.arena, .{ .name = n });
        return @intCast(scan.uses.items.len - 1);
    }

    /// A fresh scan's walk, or an update's: a subtree's part taken away
    /// before a change (`retract`), or a new subtree's added after it
    /// (`extend`).
    const Count = enum { fresh, take, add };

    fn countNames(s: *Spec, m: *Mod, scan: *NameScan, nodes: []const Index, how: Count) Allocator.Error!void {
        const ir = m.ir;
        const take = how == .take;
        if (take) scan.nodes -= @intCast(nodes.len) else scan.nodes += @intCast(nodes.len);
        // The whole-program ids the module has one name of, which no walk
        // can name two ways (`namedTwice`).
        const uniq: []const u32 = if (how != .fresh and scan.ordered) try s.uniqOf(m) else &.{};
        for (nodes) |node| {
            if (take) scan.fp -%= contribution(ir, node) else scan.fp +%= contribution(ir, node);
            const d = ir.data(node);
            switch (ir.tag(node)) {
                .const_decl, .let_decl, .for_of => try s.countDecl(scan, d.lhs, how),
                .func_decl, .gen_decl, .arrow => {
                    const t = ir.tag(node);
                    if (t != .arrow) try s.countDecl(scan, d.lhs, how);
                    const record: ExtraIndex = @fromBackingInt(@intCast(if (t == .arrow) d.lhs else d.rhs));
                    for (ir.extraSlice(ir.extraData(record, JsIr.Func).params(), NameIndex)) |p| try s.countDecl(scan, p.int(), how);
                },
                .ident => {
                    const at = try s.useAt(scan, d.lhs, how);
                    const u = &scan.uses.items[at];
                    if (take) u.idents -= 1 else u.idents += 1;
                    if (m.globalOf(@fromBackingInt(@intCast(d.lhs)))) |g| {
                        if (!u.listed and u.idents != 0) {
                            u.listed = true;
                            try scan.globals.append(s.arena, at);
                        }
                        // A whole-program name the module names more than
                        // one way: which the walk meets first may have
                        // changed.
                        if (how != .fresh and scan.ordered and namedTwice(m, scan, g, uniq)) scan.ordered = false;
                    }
                },
                .member => {
                    const obj: Index = @fromBackingInt(@intCast(d.lhs));
                    if (opaqueChild(ir, obj)) try s.countNode(&scan.sensitive, obj, take);
                    if (objectName(ir, obj)) |x| {
                        try s.countNode(&(try s.useOf(scan, x, how)).members, node, take);
                    } else if (ir.tag(obj) == .member) if (objectName(ir, @fromBackingInt(@intCast(ir.data(obj).lhs)))) |x| {
                        try s.countNode(&(try s.useOf(scan, x, how)).deep, node, take);
                    };
                },
                .assign_stmt, .assign => {
                    const target: Index = @fromBackingInt(@intCast(d.lhs));
                    if (opaqueChild(ir, target)) try s.countNode(&scan.sensitive, target, take);
                    switch (ir.tag(target)) {
                        .member => if (objectName(ir, @fromBackingInt(@intCast(ir.data(target).lhs)))) |x| {
                            try s.countNode(&(try s.useOf(scan, x, how)).written, target, take);
                            if (ir.tag(node) == .assign) {
                                const u = try s.useOf(scan, x, how);
                                if (take) u.in_place -= 1 else u.in_place += 1;
                            }
                        },
                        .ident => {
                            const u = try s.useOf(scan, ir.data(target).lhs, how);
                            if (take) u.assigns -= 1 else u.assigns += 1;
                        },
                        else => {},
                    }
                },
                .call => {
                    const callee: Index = @fromBackingInt(@intCast(d.lhs));
                    if (opaqueChild(ir, callee)) try s.countNode(&scan.sensitive, callee, take);
                    switch (ir.tag(callee)) {
                        .member => if (objectName(ir, @fromBackingInt(@intCast(ir.data(callee).lhs)))) |x| {
                            try s.countNode(&(try s.useOf(scan, x, how)).called, callee, take);
                        },
                        .ident => try s.countNode(&(try s.useOf(scan, ir.data(callee).lhs, how)).calls, node, take),
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    /// The largest statement a safety build compares name by name, beyond
    /// the fingerprint every checked statement is compared by.
    const max_compared_scan = 32;

    /// Whether the first name of each whole-program name in `kept`'s
    /// `globals` is the one a walk meeting `nodes` meets first: by two
    /// columns indexed by whole-program name, stamped, never cleared.
    fn sameFirstNames(s: *Spec, m: *Mod, kept: *const NameScan, nodes: []const Index) Allocator.Error!bool {
        if (s.first_stamp.len < s.globals) {
            s.first_stamp = try growSlice(s.arena, u32, s.first_stamp, s.globals, 0);
            s.first_name = try growSlice(s.arena, u32, s.first_name, s.globals, 0);
        }
        s.first_epoch += 1;
        var expected: u32 = 0;
        for (kept.globals.items) |at| {
            const u = &kept.uses.items[at];
            if (u.idents == 0) continue;
            const g = m.globalOf(@fromBackingInt(@intCast(u.name))).?;
            if (s.first_stamp[g] == s.first_epoch) continue;
            s.first_stamp[g] = s.first_epoch;
            s.first_name[g] = u.name;
            expected += 1;
        }
        s.first_epoch += 1;
        var met: u32 = 0;
        for (nodes) |node| {
            if (m.ir.tag(node) != .ident) continue;
            const n = m.ir.data(node).lhs;
            const g = m.globalOf(@fromBackingInt(@intCast(n))) orelse continue;
            if (s.first_stamp[g] == s.first_epoch) continue;
            if (s.first_stamp[g] != s.first_epoch - 1 or s.first_name[g] != n) return false;
            s.first_stamp[g] = s.first_epoch;
            met += 1;
        }
        return met == expected;
    }

    /// What `countNames` reads of `node` — its own operands, and what it
    /// reads of a child (`reachOf`) — hashed: summed over a
    /// statement's walk, a fingerprint of everything a scan of it counts,
    /// which a change misses the moment it leaves out a node whose part
    /// changed.
    fn contribution(ir: *const JsIr, node: Index) u64 {
        var h: u64 = node.int();
        h = mixNode(ir, h, node);
        const d = ir.data(node);
        switch (ir.tag(node)) {
            .member, .assign_stmt, .assign, .call => h = h *% 0x100000001B3 +% reachOf(ir, @fromBackingInt(@intCast(d.lhs))),
            .func_decl, .gen_decl, .arrow => {
                const record: ExtraIndex = @fromBackingInt(@intCast(if (ir.tag(node) == .arrow) d.lhs else d.rhs));
                for (ir.extraSlice(ir.extraData(record, JsIr.Func).params(), NameIndex)) |p| h = h *% 0x100000001B3 +% p.int();
            },
            else => {},
        }
        // One avalanche per node: the sum of these is the fingerprint.
        h *%= 0xFF51AFD7ED558CCD;
        h ^= h >> 33;
        h *%= 0xC4CEB9FE1A85EC53;
        return h ^ (h >> 33);
    }

    /// What `countNames` reads of a member's object, an assignment's target
    /// or a call's callee: the name an `ident` is, or the name `x` of a read
    /// `x.k`, each marked; 0 for anything else.
    fn reachOf(ir: *const JsIr, child: Index) u64 {
        switch (ir.tag(child)) {
            .ident => return 1 << 32 | @as(u64, ir.data(child).lhs),
            .member => if (objectName(ir, @fromBackingInt(@intCast(ir.data(child).lhs)))) |x| return 2 << 32 | @as(u64, x),
            else => {},
        }
        return 0;
    }

    /// `h` and `node`'s tag and operands, multiplied in (`contribution`).
    fn mixNode(ir: *const JsIr, h: u64, node: Index) u64 {
        const d = ir.data(node);
        return ((h *% 0x100000001B3 +% @backingInt(ir.tag(node))) *% 0x100000001B3 +% d.lhs) *% 0x100000001B3 +% d.rhs;
    }

    /// Whether `scan` names whole-program name `g` by more than one name
    /// with an `ident` left: which the walk meets first is then not known.
    /// `uniq` is `Mod.uniq`, or empty: an id the module has one name of is
    /// named one way, whatever the walk meets, and costs no search (#746).
    fn namedTwice(m: *Mod, scan: *const NameScan, g: u32, uniq: []const u32) bool {
        if (g < uniq.len and uniq[g] != uniq_many) return false;
        var seen: ?u32 = null;
        for (scan.globals.items) |at| {
            const u = &scan.uses.items[at];
            if (u.idents == 0 or m.globalOf(@fromBackingInt(@intCast(u.name))) != g) continue;
            if (seen) |n| {
                if (n != u.name) return true;
            } else seen = u.name;
        }
        return false;
    }

    /// Whether `child`, the object of a member read, an assignment's target
    /// or a callee, is neither a name nor a member read: what holds it
    /// counts nothing of it, until it becomes one.
    fn opaqueChild(ir: *const JsIr, child: Index) bool {
        return ir.tag(child) != .ident and ir.tag(child) != .member;
    }

    /// `retract` for a call `copyNode` is about to make `e`, a node outside
    /// the statement: null — counted again — when `e` is a name or a member
    /// read and what holds the call reads it (`h(x).k`, `h(x)(y)`).
    fn retractCall(s: *Spec, m: *Mod, top: Index, call: Index, e: Index) Allocator.Error!?Retracted {
        const scan = s.name_scans.get(.{ .module = m.index, .node = top.int() }) orelse return null;
        if (!m.kept(top, scan.epoch)) return null;
        // A call the statement no longer reaches — `inlineSmallPass` lists
        // a statement's calls before it writes any, and a body written in
        // may have dropped one — changes nothing a walk of it meets.
        if (!countedCall(m.ir, scan, call)) return null;
        if (!opaqueChild(m.ir, e) and std.mem.indexOfScalar(Index, scan.sensitive.items, call) != null) return null;
        return s.retract(m, top, &.{call.int()});
    }

    /// Whether `scan` counts `call`, by its callee's name listing it. A call
    /// of anything else is not known to be counted: a copy of a call's root
    /// (`Copy.atom`) shares the call's callee, so the callee alone cannot
    /// say the call itself is still met.
    fn countedCall(ir: *const JsIr, scan: *NameScan, call: Index) bool {
        const callee: Index = @fromBackingInt(@intCast(ir.data(call).lhs));
        if (ir.tag(callee) != .ident) return false;
        const u = findUse(scan, ir.data(callee).lhs) orelse return false;
        return std.mem.indexOfScalar(Index, u.calls.items, call) != null;
    }

    /// The name `obj` is, when it is an `ident`.
    fn objectName(ir: *const JsIr, obj: Index) ?u32 {
        return if (ir.tag(obj) == .ident) ir.data(obj).lhs else null;
    }

    fn countDecl(s: *Spec, scan: *NameScan, n: u32, how: Count) Allocator.Error!void {
        const u = try s.useOf(scan, n, how);
        if (how == .take) u.decls -= 1 else u.decls += 1;
    }

    fn countNode(s: *Spec, list: *std.ArrayList(Index), node: Index, take: bool) Allocator.Error!void {
        if (!take) return list.append(s.arena, node);
        _ = list.swapRemove(std.mem.lastIndexOfScalar(Index, list.items, node).?);
    }

    /// Whether `kept`, possibly brought up to date, says what `fresh`, a
    /// walk's, does of every name: the same counts and nodes, each as many
    /// times, and — while `kept` is ordered — the same first name of each
    /// whole-program name (`nameScan`'s check).
    fn sameNames(s: *Spec, m: *Mod, kept: *NameScan, fresh: *NameScan) Allocator.Error!bool {
        if (kept.nodes != fresh.nodes or kept.sensitive.items.len != fresh.sensitive.items.len) return false;
        {
            const p = try s.arena.dupe(Index, kept.sensitive.items);
            const q = try s.arena.dupe(Index, fresh.sensitive.items);
            std.mem.sort(Index, p, {}, lessIndex);
            std.mem.sort(Index, q, {}, lessIndex);
            if (!std.mem.eql(Index, p, q)) return false;
        }
        const empty: NameUse = .{ .name = none };
        for ([_][2]*NameScan{ .{ kept, fresh }, .{ fresh, kept } }) |pair| {
            for (pair[0].uses.items) |*x| {
                const y: *const NameUse = findUse(pair[1], x.name) orelse &empty;
                if (x.decls != y.decls or x.idents != y.idents or x.assigns != y.assigns or x.in_place != y.in_place) return false;
                for ([_][2][]const Index{ .{ x.members.items, y.members.items }, .{ x.written.items, y.written.items }, .{ x.called.items, y.called.items }, .{ x.calls.items, y.calls.items }, .{ x.deep.items, y.deep.items } }) |lists_| {
                    if (lists_[0].len != lists_[1].len) return false;
                    const p = try s.arena.dupe(Index, lists_[0]);
                    const q = try s.arena.dupe(Index, lists_[1]);
                    std.mem.sort(Index, p, {}, lessIndex);
                    std.mem.sort(Index, q, {}, lessIndex);
                    if (!std.mem.eql(Index, p, q)) return false;
                }
            }
        }
        if (!kept.ordered) return true;
        // Each whole-program name's first name, as `occurrences` reads it.
        const a = try s.firstNames(m, kept);
        const b = try s.firstNames(m, fresh);
        return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
    }

    /// Per whole-program name a scan's `globals` meets with an `ident` left,
    /// the first name of it: (whole-program name, name), by the former.
    fn firstNames(s: *Spec, m: *Mod, scan: *NameScan) Allocator.Error![]const [2]u32 {
        var out: std.ArrayList([2]u32) = .empty;
        for (scan.globals.items) |at| {
            const u = &scan.uses.items[at];
            if (u.idents == 0) continue;
            const g = m.globalOf(@fromBackingInt(@intCast(u.name))).?;
            for (out.items) |o| {
                if (o[0] == g) break;
            } else try out.append(s.arena, .{ g, u.name });
        }
        std.mem.sort([2]u32, out.items, {}, struct {
            fn less(_: void, a: [2]u32, b: [2]u32) bool {
                return a[0] < b[0];
            }
        }.less);
        return out.items;
    }

    fn lessIndex(_: void, a: Index, b: Index) bool {
        return a.int() < b.int();
    }

    /// What `retract` kept of a statement before a change replaces subtrees
    /// of it: its scan, the subtrees' part taken out.
    const Retracted = struct { scan: *NameScan };

    /// Before a change inside top-level statement `top` that replaces the
    /// subtrees at `roots` (each a node the walk of `top` meets, once for
    /// each time it is listed): what is kept of `top`, less what the
    /// subtrees contribute to it. Null when nothing is kept. Nothing but
    /// that change may come between this and `extend`.
    fn retract(s: *Spec, m: *Mod, top: Index, roots: []const u32) Allocator.Error!?Retracted {
        const scan = s.name_scans.get(.{ .module = m.index, .node = top.int() }) orelse return null;
        if (!m.kept(top, scan.epoch)) return null;
        try s.countNames(m, scan, try s.walkFrom(m, roots), .take);
        return .{ .scan = scan };
    }

    /// After that change, which wrote the subtrees at `roots` where those
    /// `retract` was given stood: what was kept of `top`, with the new
    /// subtrees' part, kept again as of now.
    fn extend(s: *Spec, m: *Mod, top: Index, r: Retracted, roots: []const u32) Allocator.Error!void {
        try s.countNames(m, r.scan, try s.walkFrom(m, roots), .add);
        r.scan.epoch = m.epoch;
        // A safety build checks the update at once: the statement may change
        // again before anything asks for it.
        if (std.debug.runtime_safety and m.ir.nodes.len <= max_checked_module) try s.checkScan(m, top, r.scan);
    }

    /// `a` less `b`, as multisets.
    fn multisetMinus(s: *Spec, a: []const u32, b: []const u32) Allocator.Error![]const u32 {
        const x = try s.arena.dupe(u32, a);
        const y = try s.arena.dupe(u32, b);
        std.mem.sort(u32, x, {}, std.sort.asc(u32));
        std.mem.sort(u32, y, {}, std.sort.asc(u32));
        var out: std.ArrayList(u32) = .empty;
        var j: usize = 0;
        for (x) |v| {
            while (j < y.len and y[j] < v) j += 1;
            if (j < y.len and y[j] == v) {
                j += 1;
                continue;
            }
            try out.append(s.arena, v);
        }
        return out.items;
    }

    /// Every node a walk from each of `roots` meets, as `preorder` does.
    fn walkFrom(s: *Spec, m: *Mod, roots: []const u32) Allocator.Error![]const Index {
        var nodes: std.ArrayList(Index) = .empty;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        for (roots) |root| {
            try JsIr.pushOperand(s.arena, &stack, @fromBackingInt(root));
            while (JsIr.popOperand(&stack)) |node| {
                try JsIr.pushOperand(s.arena, &nodes, node);
                try pushChildren(s.arena, m.ir, node, &stack);
            }
        }
        return nodes.items;
    }

    /// Count every whole-program name's mentions, and write in every
    /// function mentioned once as a callee and fit to be written there, in
    /// the order they were once taken one at a time: by whole-program id,
    /// those called from inside another candidate first. A candidate a
    /// write before it in this count touched waits for the next count: one
    /// whose call stood in a body just copied (it is now called twice, its
    /// original and its copy), or in a top-level statement the write
    /// replaced. Nothing else a write changes is what made a candidate one
    /// — it takes mentions away or copies ones already counted, and
    /// `inlineAt` asks the program as it stands everything else.
    fn inlineBatch(s: *Spec, limit: u64) Allocator.Error!Batch {
        s.stats.inline_scans += 1;
        const n = s.globals;
        try s.inlineScan();
        const refs = s.io_refs[0..n];
        // The last call of each name mentioned once: that one mention.
        const sites = try s.scratchOf(?CallSite, &s.io_sites, n);
        @memset(sites, null);
        const assigned = try s.scratchOf(bool, &s.io_flags, n);
        for (assigned, s.io_assigned[0..n]) |*a, k| a.* = k != 0;
        // A name mentioned once is mentioned by one module only.
        for (s.io_scans) |*sc| for (sc.entries.items) |e| {
            if (e.refs != 0 and refs[e.g] == 1) sites[e.g] = e.site;
        };
        // Which are candidates at all.
        const fit = try s.scratchOf(bool, &s.io_fit, n);
        @memset(fit, false);
        for (0..n) |gi| {
            const g: u32 = @intCast(gi);
            if (refs[g] != 1) continue;
            const site = sites[g] orelse continue;
            const decl = s.decl[g] orelse continue;
            if (try s.isRootCached(g)) continue;
            const fm = &s.mods[decl.module];
            if (fm.ir.tag(decl.stmt) != .const_decl) continue;
            // Still written: reachability may have dropped it.
            if (std.mem.indexOfScalar(Index, fm.ir.extraSlice(fm.ir.body, Index), decl.stmt) == null) continue;
            const value: Index = @fromBackingInt(@intCast(fm.ir.data(decl.stmt).rhs));
            if (fm.ir.tag(value) != .arrow or fm.ir.data(value).rhs != Node.arrow_plain) continue;
            if (site.module == decl.module and site.top == decl.stmt) continue;
            fit[g] = true;
        }
        // The top-level statements this count's writes touched as above.
        var touched: std.AutoHashMapUnmanaged(NodeRef, void) = .empty;
        var out: Batch = .{};
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
                    const h = cm.globalOf(@fromBackingInt(@intCast(cm.ir.data(site.top).lhs))) orelse break :blk false;
                    break :blk h < fit.len and fit[h];
                };
                if (in_candidate != inner) continue;
                if (touched.contains(.{ .module = site.module, .node = site.top.int() })) {
                    s.stats.inline_waits += 1;
                    continue;
                }
                const decl = s.decl[g].?;
                const fm = &s.mods[decl.module];
                const cm = &s.mods[site.module];
                // Declined before, and neither module changed since.
                if (g < s.io_refused.len) {
                    const r = s.io_refused[g];
                    if (r.module == site.module and r.top == site.top and r.call == site.call and
                        r.callee_version == fm.version and r.caller_version == cm.version)
                    {
                        s.stats.inline_refusals_kept += 1;
                        continue;
                    }
                }
                if (s.programNodes() >= limit) {
                    out.capped = true;
                    return out;
                }
                const value: Index = @fromBackingInt(@intCast(fm.ir.data(decl.stmt).rhs));
                // Every change `inlineAt` makes is to the call's statement:
                // the call, a list in it, or — the call a top-level
                // binding's — the module's body around it; and to the
                // module's names.
                within(cm, site.top);
                const wrote = s.inlineAt(decl, value, site, assigned) catch |err| {
                    cm.scope = null;
                    return err;
                };
                try s.leave(cm);
                if (!wrote) {
                    if (g < s.io_refused.len) s.io_refused[g] = .{
                        .module = site.module,
                        .top = site.top,
                        .call = site.call,
                        .callee_version = fm.version,
                        .caller_version = cm.version,
                    };
                    continue;
                }
                out.wrote = true;
                s.io_written = true;
                s.stats.inlined += 1;
                try touched.put(s.arena, .{ .module = decl.module, .node = decl.stmt.int() }, {});
                if (std.mem.indexOfScalar(Index, cm.ir.extraSlice(cm.ir.body, Index), site.top) == null) {
                    try touched.put(s.arena, .{ .module = site.module, .node = site.top.int() }, {});
                }
            }
        }
        return out;
    }

    /// `isRoot`, from a table made once: `inlineBatch` asks it of every
    /// name mentioned once, every count. A name made after the table is
    /// one a copy declared, which no file outside names.
    fn isRootCached(s: *Spec, g: u32) Allocator.Error!bool {
        if (s.io_root.len == 0 and s.globals != 0) {
            const root = try s.arena.alloc(bool, s.globals);
            @memset(root, false);
            var i: usize = 0;
            while (eachRoot(s.in, i)) |r| : (i += 1) if (r < root.len) {
                root[r] = true;
            };
            s.io_root = root;
        }
        if (g >= s.io_root.len) return isRoot(s.in, g);
        return s.io_root[g];
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

    /// `scanBody` of function `value` of module `fm`, declared by top-level
    /// statement `top`, kept while nothing changed that statement
    /// (`Mod.kept`): `inlineBatch` asks every candidate again in each count
    /// of the program, and most callees are where they were. Null when
    /// the body is too big or too deep.
    fn scanOf(s: *Spec, fm: *Mod, top: Index, value: Index, f: JsIr.Func) Allocator.Error!?*const BodyScan {
        const gop = try s.body_scans.getOrPut(s.arena, .{ .module = fm.index, .node = value.int() });
        if (gop.found_existing and fm.kept(top, gop.value_ptr.epoch)) {
            // As `preorder` checks what it keeps.
            if (std.debug.runtime_safety and gop.value_ptr.epoch != fm.epoch and fm.ir.nodes.len <= max_checked_module) {
                const kept = gop.value_ptr.scan;
                const fresh = try s.arena.create(BodyScan);
                fresh.* = .{};
                const ok = try s.scanBody(fm, f, fresh);
                std.debug.assert(ok == (kept != null));
                if (kept) |k| std.debug.assert(k.nodes == fresh.nodes and k.returns == fresh.returns and k.valued == fresh.valued and
                    k.final_return == fresh.final_return and std.mem.eql(u32, k.reads, fresh.reads) and
                    std.mem.eql(bool, k.assigns, fresh.assigns) and std.mem.eql(bool, k.repeated, fresh.repeated) and
                    std.mem.eql(u32, k.declared.items, fresh.declared.items) and std.mem.eql(u32, k.mentioned.items, fresh.mentioned.items));
            }
            gop.value_ptr.epoch = fm.epoch;
            return gop.value_ptr.scan;
        }
        const scan = try s.arena.create(BodyScan);
        scan.* = .{};
        const ok = try s.scanBody(fm, f, scan);
        // `scanBody` does not touch the table `gop` points into.
        gop.value_ptr.* = .{ .epoch = fm.epoch, .scan = if (ok) scan else null };
        return gop.value_ptr.scan;
    }

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
                const n: NameIndex = @fromBackingInt(@intCast(d.lhs));
                try out.mentioned.append(s.arena, d.lhs);
                if (std.mem.indexOfScalar(NameIndex, params, n)) |i| {
                    out.reads[i] += 1;
                    if (out.repeat != 0) out.repeated[i] = true;
                }
            },
            .const_decl => {
                try s.declared(out, @fromBackingInt(@intCast(d.lhs)));
                try s.scanNode(fm, @fromBackingInt(@intCast(d.rhs)), params, out, depth + 1, own);
            },
            .let_decl => {
                try s.declared(out, @fromBackingInt(@intCast(d.lhs)));
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| try s.scanNode(fm, v, params, out, depth + 1, own);
            },
            .func_decl, .gen_decl => {
                try s.declared(out, @fromBackingInt(@intCast(d.lhs)));
                try s.scanFunc(fm, @fromBackingInt(@intCast(d.rhs)), params, out, depth);
            },
            .arrow => try s.scanFunc(fm, @fromBackingInt(@intCast(d.lhs)), params, out, depth),
            .assign_stmt => {
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                if (ir.tag(target) == .ident) {
                    const n: NameIndex = @fromBackingInt(@intCast(ir.data(target).lhs));
                    if (std.mem.indexOfScalar(NameIndex, params, n)) |i| out.assigns[i] = true;
                }
                try s.scanNode(fm, target, params, out, depth + 1, own);
                try s.scanNode(fm, @fromBackingInt(@intCast(d.rhs)), params, out, depth + 1, own);
            },
            .return_stmt => {
                if (own) {
                    out.returns += 1;
                    if (d.lhs != @backingInt(Node.OptionalIndex.none)) out.valued = true;
                }
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try s.scanNode(fm, v, params, out, depth + 1, own);
            },
            .if_stmt => {
                try s.scanNode(fm, @fromBackingInt(@intCast(d.lhs)), params, out, depth + 1, own);
                const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                try s.scanList(fm, b.thenBody(), params, out, depth, own);
                try s.scanList(fm, b.elseBody(), params, out, depth, own);
            },
            .while_true, .block_stmt => {
                const loops = ir.tag(node) == .while_true;
                if (loops) out.repeat += 1;
                defer if (loops) {
                    out.repeat -= 1;
                };
                try s.declared(out, @fromBackingInt(@intCast(d.lhs)));
                try s.scanList(fm, ir.subRange(@fromBackingInt(@intCast(d.rhs))), params, out, depth, own);
            },
            .for_of => {
                try s.declared(out, @fromBackingInt(@intCast(d.lhs)));
                const loop = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                try s.scanNode(fm, loop.iterable, params, out, depth + 1, own);
                out.repeat += 1;
                defer out.repeat -= 1;
                try s.scanList(fm, loop.body(), params, out, depth, own);
            },
            .switch_stmt => {
                try s.scanNode(fm, @fromBackingInt(@intCast(d.lhs)), params, out, depth + 1, own);
                try s.scanList(fm, ir.subRange(@fromBackingInt(@intCast(d.rhs))), params, out, depth, own);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| try s.scanNode(fm, t, params, out, depth + 1, own);
                try s.scanList(fm, ir.subRange(@fromBackingInt(@intCast(d.rhs))), params, out, depth, own);
            },
            .break_stmt, .continue_stmt, .number, .string, .template_chunk, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit => {},
            .expr_stmt, .throw_stmt => try s.scanNode(fm, @fromBackingInt(@intCast(d.lhs)), params, out, depth + 1, own),
            // A `return` in either block is the callee's own: written where
            // the call stood, it leaves the caller from inside the same
            // `try`, and the cleanup still runs first. The body's last
            // statement is the `try`, never a `return`, so a call whose value
            // is wanted is written there only in `return` position.
            .try_stmt => {
                const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                try s.declared(out, t.catch_name);
                try s.scanList(fm, t.body(), params, out, depth, own);
                try s.scanList(fm, t.finalBody(), params, out, depth, own);
                try s.scanList(fm, t.catchBody(), params, out, depth, own);
            },
            .import_stmt, .export_stmt => out.ok = false,
            else => {
                var children = try s.takeStack();
                defer s.giveStack(&children);
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
        const n: NameIndex = @fromBackingInt(@intCast(ir.data(a).lhs));
        // A name made after `assigned` was counted is one a copy declared at
        // a module's top (`inlineBatch`): not known to be unassigned.
        if (m.globalOf(n)) |g| return g < assigned.len and !assigned[g];
        return !try s.assignedInTop(m, top, n);
    }

    /// Name top-level statement `top` of `m` as the one every change to `m`
    /// is made in until `leave` (`Mod.kept`). The caller answers for it: a
    /// change elsewhere in the module while it is named would keep walks
    /// of other statements that no longer hold, which a safety build's
    /// check in `preorder` catches.
    fn within(m: *Mod, top: Index) void {
        std.debug.assert(m.scope == null);
        m.scope = top;
        m.scope_last = 0;
    }

    fn leave(s: *Spec, m: *Mod) Allocator.Error!void {
        const top = m.scope.?;
        m.scope = null;
        if (m.scope_last == 0) return;
        if (m.top_changed.items.len <= top.int()) try m.top_changed.appendNTimes(s.arena, 0, top.int() + 1 - m.top_changed.items.len);
        m.top_changed.items[top.int()] = m.scope_last;
    }

    /// Every node of top-level statement `top` of module `m`, in the order a
    /// walk from it meets them (`pushChildren`), kept while nothing changed
    /// the statement (`Mod.kept`): most walks of a statement visit every
    /// node of it, and the passes walk the same unchanged statements over
    /// and over.
    fn preorder(s: *Spec, m: *Mod, top: Index) Allocator.Error![]const Index {
        const gop = try s.preorders.getOrPut(s.arena, .{ .module = m.index, .node = top.int() });
        if (gop.found_existing and m.kept(top, gop.value_ptr.epoch)) {
            // Kept across a change the module made elsewhere: in a safety
            // build, a test-sized statement is walked again, and must meet
            // what it met. Either way it holds as of now.
            const kept = gop.value_ptr;
            if (std.debug.runtime_safety and kept.epoch != m.epoch and kept.nodes.len <= max_checked_walk and m.ir.nodes.len <= max_checked_module) {
                std.debug.assert(std.mem.eql(Index, try s.preorderWalk(m, top), kept.nodes));
            }
            kept.epoch = m.epoch;
            return kept.nodes;
        }
        // `preorderWalk` does not touch the table `gop` points into.
        const nodes = try s.preorderWalk(m, top);
        gop.value_ptr.* = .{ .epoch = m.epoch, .nodes = nodes };
        return nodes;
    }

    /// The largest walk of a statement that a safety build checks when it
    /// is kept across a change elsewhere in its module, and the largest
    /// module whose statements it checks (a test-sized one: as the
    /// worklist's check takes programs of at most 1 500 nodes).
    const max_checked_walk = 2000;
    const max_checked_module = 3000;

    /// `preorder`'s walk.
    fn preorderWalk(s: *Spec, m: *Mod, top: Index) Allocator.Error![]const Index {
        var nodes: std.ArrayList(Index) = .empty;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, top);
        while (JsIr.popOperand(&stack)) |node| {
            try JsIr.pushOperand(s.arena, &nodes, node);
            try pushChildren(s.arena, m.ir, node, &stack);
        }
        return nodes.items;
    }

    /// Whether every name inert expression `root` reads outside the
    /// functions in it is an atom (`atomArgument`): nothing can have changed
    /// it by the time the expression is made later.
    fn immutableNames(s: *Spec, m: *Mod, root: Index, top: Index, assigned: []const bool) Allocator.Error!bool {
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, root);
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
    ///
    /// The answer for every `g` at once is one walk of the module (`occ`),
    /// kept while nothing a walk meets changes. During `rewrite`, which only
    /// ever takes mentions away, a `g` the last walk did not meet is still
    /// not met.
    fn namedIn(s: *Spec, m: *Mod, g: u32) Allocator.Error!?NameIndex {
        if (m.occ_version == m.version and g < m.occ.len) {
            const n = m.occ[g];
            return if (n == none) null else @fromBackingInt(@intCast(n));
        }
        // Walked earlier in this rewrite: a name not met then is not met
        // now; one met then may have gone since.
        if (s.only_fewer and m.occ_rewrite == s.rewrite_epoch and g < m.occ.len) {
            if (m.occ[g] == none) return null;
            return s.namedInWalk(m, g);
        }
        try s.occurrences(m);
        const n = if (g < m.occ.len) m.occ[g] else none;
        return if (n == none) null else @fromBackingInt(@intCast(n));
    }

    /// `namedIn`'s walk, every whole-program id's first name at once.
    fn occurrences(s: *Spec, m: *Mod) Allocator.Error!void {
        const ir = m.ir;
        if (m.occ.len < s.globals) m.occ = try s.arena.alloc(u32, s.globals);
        @memset(m.occ, none);
        for (ir.extraSlice(ir.body, Index)) |top| {
            switch (ir.tag(top)) {
                .import_stmt, .export_stmt => continue,
                .const_decl, .let_decl, .func_decl, .gen_decl => {
                    const n: NameIndex = @fromBackingInt(@intCast(ir.data(top).lhs));
                    if (m.globalOf(n)) |g| if (g < m.occ.len and m.occ[g] == none) {
                        m.occ[g] = n.int();
                    };
                },
                else => {},
            }
            const scan = try s.nameScanOrdered(m, top);
            for (scan.globals.items) |at| {
                const u = &scan.uses.items[at];
                if (u.idents == 0) continue;
                const g = m.globalOf(@fromBackingInt(@intCast(u.name))).?;
                if (g < m.occ.len and m.occ[g] == none) m.occ[g] = u.name;
            }
        }
        m.occ_version = m.version;
        m.occ_rewrite = if (s.only_fewer) s.rewrite_epoch else 0;
    }

    /// Module `m`'s one name of whole-program id `g`, when it has exactly
    /// one.
    fn onlyName(s: *Spec, m: *Mod, g: u32) Allocator.Error!?NameIndex {
        const uniq = try s.uniqOf(m);
        if (g >= uniq.len) return null;
        const n = uniq[g];
        return if (n == none or n == uniq_many) null else @fromBackingInt(@intCast(n));
    }

    /// `Mod.uniq`, brought up to date with the module's names.
    fn uniqOf(s: *Spec, m: *Mod) Allocator.Error![]const u32 {
        if (m.uniq_len != m.global.len or m.uniq.len < s.globals) {
            if (m.uniq.len < s.globals) m.uniq = try s.arena.alloc(u32, s.globals);
            @memset(m.uniq, none);
            for (m.global, 0..) |x, i| if (x != none and x < m.uniq.len) {
                m.uniq[x] = if (m.uniq[x] == none) @intCast(i) else uniq_many;
            };
            m.uniq_len = m.global.len;
        }
        return m.uniq;
    }

    /// `Mod.uniq`'s mark of a whole-program id the module has several
    /// names of.
    const uniq_many = none - 1;

    /// `namedIn` by walking the module until `g` is met.
    fn namedInWalk(s: *Spec, m: *Mod, g: u32) Allocator.Error!?NameIndex {
        const ir = m.ir;
        for (ir.extraSlice(ir.body, Index)) |top| {
            switch (ir.tag(top)) {
                .import_stmt, .export_stmt => continue,
                .const_decl, .let_decl, .func_decl, .gen_decl => {
                    const n: NameIndex = @fromBackingInt(@intCast(ir.data(top).lhs));
                    if (m.globalOf(n) == g) return n;
                },
                else => {},
            }
            for (try s.preorder(m, top)) |node| {
                if (ir.tag(node) == .ident) {
                    const n: NameIndex = @fromBackingInt(@intCast(ir.data(node).lhs));
                    if (m.globalOf(n) == g) return n;
                }
            }
        }
        return null;
    }

    /// Whether anything reads name `n`, declared in top-level statement
    /// `top` of module `m`: a whole-program name anywhere, a local there.
    fn nameRead(s: *Spec, m: *Mod, top: Index, n: NameIndex) Allocator.Error!bool {
        const g = m.globalOf(n);
        // A whole-program name: `inlineScan` counted its mentions. A write
        // since (`io_written`) copies only mentions already counted, so a
        // name counted unread is unread still; one counted read is read
        // still unless a write dropped an argument naming it (`io_dropped`),
        // which the walk below answers.
        if (g) |want| if (s.io_refs.len == s.globals) {
            if (s.io_refs[want] == 0) return false;
            if (!s.io_written or std.mem.indexOfScalar(u32, s.io_dropped.items, want) == null) return true;
        };
        for (s.mods) |*other| {
            if (g == null and other != m) continue;
            const ir = other.ir;
            // A walk of every statement, from the last to the first (a
            // stack holding the whole body), or of `top` alone: which
            // statement it meets first changes nothing but how soon it ends.
            const tops = if (g == null) &[_]Index{top} else ir.extraSlice(ir.body, Index);
            var i = tops.len;
            while (i > 0) {
                i -= 1;
                for (try s.preorder(other, tops[i])) |node| {
                    if (ir.tag(node) == .ident) {
                        const x: NameIndex = @fromBackingInt(@intCast(ir.data(node).lhs));
                        if (g) |want| {
                            if (other.globalOf(x) == want) return true;
                        } else if (x == n) return true;
                    }
                }
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

    // ---- The place index (#352) ---------------------------------------------
    //
    // `placeOf` walks a call's whole top-level statement from its start, and
    // slice 5 asks it once per function it writes in place: a module whose
    // one top-level statement holds every call — a page's mount — is walked
    // once per call it holds, quadratic in the program. The index walks a
    // top-level statement once, as `placeAmong` does, and keeps each node's
    // place. A lookup takes it only while it still holds — the statement
    // still in its list with the call its whole expression, or an
    // expression's node no copy has moved (`unindex`) — and otherwise walks.

    /// One node's place as of the walk that indexed its top-level statement.
    const PlaceEntry = struct {
        top: Index,
        place: Place,
        /// The statement's list is a function's body: `tail` is read off the
        /// list as it is at the lookup.
        fn_body: bool,
    };

    fn samePlace(a: ?Place, b: ?Place) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        if (x.kind != y.kind) return false;
        // An expression's place carries its kind alone: `placeExpr` answers
        // `.{ .kind = .expr }`, and nothing reads more of it (`inlineAt`
        // writes the call in place by its node).
        if (x.kind == .expr) return true;
        return x.stmt == y.stmt and x.owner == y.owner and x.tail == y.tail and x.top_level == y.top_level;
    }

    /// `placeOf` through the index: the place the walk finds.
    fn placeIndexed(s: *Spec, m: *Mod, site: CallSite) Allocator.Error!?Place {
        const found = blk: {
            if (s.placeHint(m, site)) |p| break :blk p;
            // Walked already, and unchanged since: the walk the search makes
            // met the call nowhere (past `max_depth`), so neither does it.
            const top = site.top.int();
            if (top < m.place_top.items.len and m.place_top.items[top] == m.version) break :blk null;
            try s.indexWalk(m, site.top, false);
            if (s.placeHint(m, site)) |p| break :blk p;
            break :blk null;
        };
        if (std.debug.runtime_safety) std.debug.assert(samePlace(try s.placeOf(m, site), found));
        return found;
    }

    /// The index's place of `site.call`, when it still holds.
    ///
    /// The invariant: within one `inlineOnce`, a node keeps the place the
    /// walk recorded unless `inlineAt` moves it, and the only nodes it
    /// moves are the arguments it substitutes into the body it writes,
    /// which `unindex` forgets first. Every other edit is to a statement
    /// list — a statement replaced by the copy, the list stored again at
    /// its owner — so a statement place is checked against its list here,
    /// and an expression place, whose node did not move, holds as it is.
    /// New nodes, the copy's own, have no place until a walk gives one.
    fn placeHint(s: *Spec, m: *Mod, site: CallSite) ?Place {
        _ = s;
        const at = site.call.int();
        if (at >= m.place_at.items.len or m.place_at.items[at].top == none_index) return null;
        const e = m.place_at.items[at];
        if (e.top != site.top) return null;
        var p = e.place;
        if (p.kind == .expr) return p;
        const ir = m.ir;
        const d = ir.data(p.stmt);
        const root: ?Index = switch (ir.tag(p.stmt)) {
            .expr_stmt, .const_decl => @fromBackingInt(@intCast(if (ir.tag(p.stmt) == .expr_stmt) d.lhs else d.rhs)),
            .return_stmt => @as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap(),
            .let_decl => @as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap(),
            else => null,
        };
        if (root != site.call) return null;
        if (std.debug.runtime_safety) std.debug.assert(switch (ir.tag(p.stmt)) {
            .expr_stmt => p.kind == .stmt,
            .return_stmt => p.kind == .ret,
            .const_decl, .let_decl => p.kind == .decl,
            else => false,
        });
        const o = p.owner orelse return if (p.stmt == site.top) p else null;
        const list = listAt(m, o);
        if (std.mem.indexOfScalar(Index, list, p.stmt) == null) return null;
        p.tail = e.fn_body and list[list.len - 1] == p.stmt;
        return p;
    }

    /// Walk top-level statement `top` as `placeAmong` does: record each
    /// node's place, the first the walk meets, or (`clear`) forget the
    /// places of every node of `top` — any node in place of `top`.
    fn indexWalk(s: *Spec, m: *Mod, top: Index, clear: bool) Allocator.Error!void {
        if (m.place_at.items.len < m.ir.nodes.len) {
            const old = m.place_at.items.len;
            try m.place_at.resize(s.arena, m.ir.nodes.len);
            for (m.place_at.items[old..]) |*e| e.top = none_index;
            try m.place_walk.resize(s.arena, m.ir.nodes.len);
            @memset(m.place_walk.items[old..], 0);
        }
        // 64 bits: no build makes 2⁶⁴ walks, so a mark never meets a stale one.
        s.place_walks += 1;
        while (m.place_top.items.len <= top.int()) try m.place_top.append(s.arena, none);
        if (!clear) m.place_top.items[top.int()] = m.version;
        var w: IndexWalk = .{ .s = s, .m = m, .top = top, .clear = clear };
        try w.among(null, &.{top}, false, true, 0);
    }

    /// Forget the places of the nodes below `root`, an argument a copy moves
    /// whole into the body it writes in place.
    fn unindex(s: *Spec, m: *Mod, root: Index) Allocator.Error!void {
        if (m.place_at.items.len == 0) return;
        var w: IndexWalk = .{ .s = s, .m = m, .top = none_index, .clear = true };
        try w.expr(root, 0);
    }

    const none_index: Index = @fromBackingInt(std.math.maxInt(u32));

    const IndexWalk = struct {
        s: *Spec,
        m: *Mod,
        top: Index,
        clear: bool,

        fn note(w: *IndexWalk, node: Index, place: Place, fn_body: bool) void {
            const at = node.int();
            if (at >= w.m.place_at.items.len) return;
            if (w.clear) {
                w.m.place_at.items[at].top = none_index;
                return;
            }
            if (w.m.place_walk.items[at] == w.s.place_walks) return;
            w.m.place_walk.items[at] = w.s.place_walks;
            w.m.place_at.items[at] = .{ .top = w.top, .place = place, .fn_body = fn_body };
        }

        fn among(w: *IndexWalk, owner: ?u32, list: []const Index, fn_body: bool, top_level: bool, depth: u32) Allocator.Error!void {
            if (depth > max_depth) return;
            const ir = w.m.ir;
            for (list, 0..) |stmt, i| {
                const d = ir.data(stmt);
                const root: ?Index = switch (ir.tag(stmt)) {
                    .expr_stmt, .const_decl => @fromBackingInt(@intCast(if (ir.tag(stmt) == .expr_stmt) d.lhs else d.rhs)),
                    .return_stmt => @as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap(),
                    .let_decl => @as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap(),
                    else => null,
                };
                if (root) |r| w.note(r, .{
                    .kind = switch (ir.tag(stmt)) {
                        .expr_stmt => .stmt,
                        .return_stmt => .ret,
                        else => .decl,
                    },
                    .stmt = stmt,
                    .owner = owner,
                    .tail = fn_body and i + 1 == list.len,
                    .top_level = top_level,
                }, fn_body);
                try w.in(stmt, depth + 1);
            }
        }

        fn in(w: *IndexWalk, stmt: Index, depth: u32) Allocator.Error!void {
            const ir = w.m.ir;
            const d = ir.data(stmt);
            switch (ir.tag(stmt)) {
                .func_decl, .gen_decl => {
                    const at = d.rhs;
                    try w.among(at + 2, ir.extraSlice(ir.extraData(@fromBackingInt(@intCast(at)), JsIr.Func).body(), Index), true, false, depth);
                },
                .if_stmt => {
                    try w.expr(@fromBackingInt(@intCast(d.lhs)), depth);
                    const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                    try w.among(d.rhs, ir.extraSlice(b.thenBody(), Index), false, false, depth);
                    try w.among(d.rhs + 2, ir.extraSlice(b.elseBody(), Index), false, false, depth);
                },
                .while_true, .block_stmt => try w.among(d.rhs, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index), false, false, depth),
                .for_of => {
                    const loop = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                    try w.expr(loop.iterable, depth);
                    try w.among(d.rhs + 1, ir.extraSlice(loop.body(), Index), false, false, depth);
                },
                .switch_stmt => {
                    try w.expr(@fromBackingInt(@intCast(d.lhs)), depth);
                    for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |c| {
                        const cd = ir.data(c);
                        if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(cd.lhs))).unwrap()) |t| try w.expr(t, depth);
                        try w.among(cd.rhs, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(cd.rhs))), Index), false, false, depth);
                    }
                },
                .const_decl => try w.expr(@fromBackingInt(@intCast(d.rhs)), depth),
                .let_decl, .return_stmt => {
                    const v = @as(Node.OptionalIndex, @fromBackingInt(@intCast(if (ir.tag(stmt) == .let_decl) d.rhs else d.lhs))).unwrap() orelse return;
                    try w.expr(v, depth);
                },
                .assign_stmt => {
                    try w.expr(@fromBackingInt(@intCast(d.lhs)), depth);
                    try w.expr(@fromBackingInt(@intCast(d.rhs)), depth);
                },
                .expr_stmt, .throw_stmt => try w.expr(@fromBackingInt(@intCast(d.lhs)), depth),
                .try_stmt => {
                    const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                    try w.among(d.rhs, ir.extraSlice(t.body(), Index), false, false, depth);
                    try w.among(d.rhs + 2, ir.extraSlice(t.finalBody(), Index), false, false, depth);
                    try w.among(d.rhs + 4, ir.extraSlice(t.catchBody(), Index), false, false, depth);
                },
                else => {},
            }
        }

        fn expr(w: *IndexWalk, root: Index, depth: u32) Allocator.Error!void {
            var stack = try w.s.takeStack();
            defer w.s.giveStack(&stack);
            try JsIr.pushOperand(w.s.arena, &stack, root);
            while (JsIr.popOperand(&stack)) |node| {
                w.note(node, .{ .kind = .expr }, false);
                if (w.m.ir.tag(node) == .arrow) {
                    const at = w.m.ir.data(node).lhs;
                    try w.among(at + 2, w.m.ir.extraSlice(w.m.ir.extraData(@fromBackingInt(@intCast(at)), JsIr.Func).body(), Index), true, false, depth + 1);
                    continue;
                }
                try w.m.ir.pushOperands(w.s.arena, &stack, node);
            }
        }
    };

    /// `placeOf` through a walk of the call's statement kept while the
    /// statement stands (`Mod.kept`): `fuseOne` asks every site of every
    /// candidate again after each function it writes, and most statements
    /// are as they were. (`placeIndexed`'s index holds within `inlineOnce`
    /// by what `inlineAt` moves; this one by what changed at all.)
    fn placeKept(s: *Spec, m: *Mod, site: CallSite) Allocator.Error!?Place {
        const at = site.call.int();
        const found = found: {
            if (site.top.int() < m.place_kept.items.len) {
                const k = m.place_kept.items[site.top.int()];
                if (k.walk != 0 and m.kept(site.top, k.epoch) and at < m.place_walk.items.len and m.place_walk.items[at] == k.walk and m.place_at.items[at].top == site.top) break :found m.place_at.items[at].place;
            }
            try s.indexWalk(m, site.top, false);
            if (m.place_kept.items.len <= site.top.int()) try m.place_kept.appendNTimes(s.arena, .{}, site.top.int() + 1 - m.place_kept.items.len);
            m.place_kept.items[site.top.int()] = .{ .epoch = m.epoch, .walk = s.place_walks };
            if (at < m.place_walk.items.len and m.place_walk.items[at] == s.place_walks and m.place_at.items[at].top == site.top) break :found m.place_at.items[at].place;
            break :found null;
        };
        if (std.debug.runtime_safety) std.debug.assert(samePlace(try s.placeOf(m, site), found));
        return found;
    }

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
                .expr_stmt, .const_decl => @fromBackingInt(@intCast(if (ir.tag(stmt) == .expr_stmt) d.lhs else d.rhs)),
                .return_stmt => @as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap(),
                .let_decl => @as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap(),
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
                return s.placeAmong(m, at + 2, ir.extraSlice(ir.extraData(@fromBackingInt(@intCast(at)), JsIr.Func).body(), Index), true, false, call, depth);
            },
            .if_stmt => {
                if (try s.placeExpr(m, @fromBackingInt(@intCast(d.lhs)), call, depth)) |p| return p;
                const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                if (try s.placeAmong(m, d.rhs, ir.extraSlice(b.thenBody(), Index), false, false, call, depth)) |p| return p;
                return s.placeAmong(m, d.rhs + 2, ir.extraSlice(b.elseBody(), Index), false, false, call, depth);
            },
            .while_true, .block_stmt => return s.placeAmong(m, d.rhs, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index), false, false, call, depth),
            .for_of => {
                const loop = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                if (try s.placeExpr(m, loop.iterable, call, depth)) |p| return p;
                return s.placeAmong(m, d.rhs + 1, ir.extraSlice(loop.body(), Index), false, false, call, depth);
            },
            .switch_stmt => {
                if (try s.placeExpr(m, @fromBackingInt(@intCast(d.lhs)), call, depth)) |p| return p;
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |c| {
                    const cd = ir.data(c);
                    if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(cd.lhs))).unwrap()) |t| if (try s.placeExpr(m, t, call, depth)) |p| return p;
                    if (try s.placeAmong(m, cd.rhs, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(cd.rhs))), Index), false, false, call, depth)) |p| return p;
                }
                return null;
            },
            .const_decl => return s.placeExpr(m, @fromBackingInt(@intCast(d.rhs)), call, depth),
            .let_decl, .return_stmt => {
                const v = @as(Node.OptionalIndex, @fromBackingInt(@intCast(if (ir.tag(stmt) == .let_decl) d.rhs else d.lhs))).unwrap() orelse return null;
                return s.placeExpr(m, v, call, depth);
            },
            .assign_stmt => {
                if (try s.placeExpr(m, @fromBackingInt(@intCast(d.lhs)), call, depth)) |p| return p;
                return s.placeExpr(m, @fromBackingInt(@intCast(d.rhs)), call, depth);
            },
            .expr_stmt, .throw_stmt => return s.placeExpr(m, @fromBackingInt(@intCast(d.lhs)), call, depth),
            // A call in any block is written into that block, which is
            // where its statements then run: inside the guard, or as part
            // of the cleanup. Neither block is a function's body, so a call
            // that ends one is never taken for a tail.
            .try_stmt => {
                const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                if (try s.placeAmong(m, d.rhs, ir.extraSlice(t.body(), Index), false, false, call, depth)) |p| return p;
                if (try s.placeAmong(m, d.rhs + 2, ir.extraSlice(t.finalBody(), Index), false, false, call, depth)) |p| return p;
                return s.placeAmong(m, d.rhs + 4, ir.extraSlice(t.catchBody(), Index), false, false, call, depth);
            },
            else => return null,
        }
    }

    fn placeExpr(s: *Spec, m: *Mod, root: Index, call: Index, depth: u32) Allocator.Error!?Place {
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, root);
        while (JsIr.popOperand(&stack)) |node| {
            if (node == call) return .{ .kind = .expr };
            if (m.ir.tag(node) == .arrow) {
                const at = m.ir.data(node).lhs;
                if (try s.placeAmong(m, at + 2, m.ir.extraSlice(m.ir.extraData(@fromBackingInt(@intCast(at)), JsIr.Func).body(), Index), true, false, call, depth + 1)) |p| return p;
                continue;
            }
            try m.ir.pushOperands(s.arena, &stack, node);
        }
        return null;
    }

    /// Each whole-program name `root`, an argument a write drops, names
    /// (`io_dropped`).
    fn noteDropped(s: *Spec, m: *Mod, root: Index) Allocator.Error!void {
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, root);
        while (JsIr.popOperand(&stack)) |node| {
            if (m.ir.tag(node) == .ident) if (m.globalOf(@fromBackingInt(@intCast(m.ir.data(node).lhs)))) |g| try s.io_dropped.append(s.arena, g);
            try pushChildren(s.arena, m.ir, node, &stack);
        }
    }

    /// Write function `value` (declared by `decl`) at its one call `site`,
    /// when every rule allows; false, with nothing changed, otherwise.
    fn inlineAt(s: *Spec, decl: Decl, value: Index, site: CallSite, assigned: []const bool) Allocator.Error!bool {
        const fm = &s.mods[decl.module];
        const cm = &s.mods[site.module];
        const cross = decl.module != site.module;
        const f = fm.ir.extraData(@fromBackingInt(@intCast(fm.ir.data(value).lhs)), JsIr.Func);
        const params = try s.arena.dupe(NameIndex, fm.ir.extraSlice(f.params(), NameIndex));
        const body = try s.arena.dupe(Index, fm.ir.extraSlice(f.body(), Index));
        const args = try s.arena.dupe(Index, cm.ir.extraSlice(cm.ir.subRange(@fromBackingInt(@intCast(cm.ir.data(site.call).rhs))), Index));
        if (args.len != params.len) return false;

        const scan = try s.scanOf(fm, decl.stmt, value, f) orelse return false;
        // A parameter declared again inside is not one name to substitute.
        for (params) |p| if (p.unwrap()) |i| if (scan.counts[i] > 1) return false;
        // Another module's function names nothing but its own locals and
        // whole-program names the caller's module already names — so the
        // caller needs no import it lacks, in either layout.
        // Asked without adding a name (`canName`): the names go in once the
        // copy is decided, so a call that declines leaves the module as it
        // was and its walks still kept.
        var outer: std.ArrayList(struct { from: u32, to: u32 }) = .empty;
        var pending: std.ArrayList(struct { from: u32, g: u32 }) = .empty;
        if (cross) for (scan.mentioned.items) |n| {
            if (n < scan.counts.len and scan.counts[n] != 0) continue;
            const g = fm.globalOf(@fromBackingInt(@intCast(n))) orelse return false;
            if (!try s.canName(cm, g)) return false;
            try pending.append(s.arena, .{ .from = n, .g = g });
        };
        // Arguments: atoms — or an argument that makes a value and nothing
        // else, of immutable names, whose parameter is read once and not
        // again by a loop or a later call: it is made where it is read,
        // once, as it was made once before the body.
        for (args, 0..) |a, i| {
            if (try s.atomArgument(cm, a, site.top, assigned)) continue;
            if (!inertOf(cm.ir, a, false) or scan.reads[i] > 1 or scan.repeated[i] or scan.assigns[i]) return false;
            if (!try s.immutableNames(cm, a, site.top, assigned)) return false;
        }

        const place = try s.placeIndexed(cm, site) orelse return false;
        const single = body.len == 1 and scan.final_return and scan.valued and scan.returns == 1;
        const Form = enum { expr, ret, stmt, decl, tail_stmt };
        const form: Form = if (single) .expr else switch (place.kind) {
            .expr => return false,
            .ret => .ret,
            .stmt => blk: {
                if (scan.returns == 0 or (scan.returns == 1 and scan.final_return)) break :blk .stmt;
                if (place.tail and !scan.valued) break :blk .ret;
                // A body whose `return`s all end it, at a call statement:
                // each is its value as a statement, or nothing (`copyTail`).
                if (tailReturnsOnly(fm.ir, body, 0)) break :blk .tail_stmt;
                return false;
            },
            .decl => if (scan.returns == 1 and scan.final_return and scan.valued) .decl else return false,
        };
        const top = form == .decl and place.top_level;
        if (top and cm.self == .none) return false;
        // A call the optimiser drops — a discarded pure call, or a binding
        // nothing reads whose initialiser may not do anything — would come
        // back as the body's statements: written as the call it is.
        if (form == .stmt or form == .tail_stmt or form == .ret or form == .decl) if (cm.tables) |t| {
            if ((form == .stmt or form == .tail_stmt) and std.mem.indexOfScalar(Index, t.discards.items, place.stmt) != null) return false;
            if (form == .decl and std.mem.indexOfScalar(Index, t.keep.items, place.stmt) == null and
                !try s.nameRead(cm, site.top, @fromBackingInt(@intCast(cm.ir.data(place.stmt).lhs)))) return false;
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
        for (pending.items) |p| {
            const to = (try s.nameIn(cm, p.g)).?;
            try outer.append(s.arena, .{ .from = p.from, .to = to.int() });
        }
        // The callee's name goes with the call, and so does an argument
        // whose parameter nothing reads: `nameRead` asks the program again
        // of the names they held.
        try s.io_dropped.append(s.arena, s.globalOfDecl(decl));
        for (args, bind, scan.reads) |a, b, r| if (!b and r == 0) try s.noteDropped(cm, a);
        s.noteCopy(decl.module, s.globalOfDecl(decl));
        // Each argument moves, whole, into the copy: its nodes' places are
        // no longer the index's.
        for (args) |a| try s.unindex(cm, a);

        var c: Copy = .{
            .s = s,
            .src = fm,
            .dst = cm,
            .cross = cross,
            .site = cm.ir.pos(site.call),
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
            if (std.mem.indexOfScalar(NameIndex, params, @fromBackingInt(@intCast(n))) != null) continue;
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

        // What is kept of the call's statement is brought up to date by the
        // subtree the copy replaces and the ones it writes (`retract`,
        // `extend`), not walked again: a module's every call may stand in
        // one statement (a page's `update`, its `view`). Not when the
        // module's body itself is spliced (`retractCall` for the rest).
        var delta: ?Retracted = if (form == .expr or place.top_level) null else try s.retract(cm, site.top, &.{place.stmt.int()});
        var new_roots: []const u32 = &.{};
        switch (form) {
            .expr => {
                const ret: Index = @fromBackingInt(@intCast(fm.ir.data(body[0]).lhs));
                const e = try c.expr(ret, 0);
                delta = try s.retractCall(cm, site.top, site.call, e);
                try cm.copyNode(s.gpa, site.call, e);
                new_roots = try s.arena.dupe(u32, &.{site.call.int()});
            },
            .ret => {
                var out: std.ArrayList(u32) = .empty;
                try out.appendSlice(s.arena, bindings.items);
                for (body) |stmt| try out.append(s.arena, (try c.stmt(stmt, 0)).int());
                try s.splice(cm, place, out.items, false);
                new_roots = out.items;
            },
            .tail_stmt => {
                var out: std.ArrayList(u32) = .empty;
                try out.appendSlice(s.arena, bindings.items);
                try out.appendSlice(s.arena, try copyTail(&c, cm, body, 0));
                try s.splice(cm, place, out.items, false);
                new_roots = out.items;
            },
            .stmt => {
                var out: std.ArrayList(u32) = .empty;
                try out.appendSlice(s.arena, bindings.items);
                for (body, 0..) |stmt, i| {
                    if (i + 1 == body.len and fm.ir.tag(stmt) == .return_stmt) {
                        // The last `return`'s value, kept as a statement when
                        // evaluating it may do something.
                        const v = @as(Node.OptionalIndex, @fromBackingInt(@intCast(fm.ir.data(stmt).lhs))).unwrap() orelse continue;
                        if (inert(fm.ir, v)) continue;
                        const e = try c.expr(v, 0);
                        try out.append(s.arena, (try cm.addNode(s.gpa, .expr_stmt, Node.no_pos, e.int(), 0)).int());
                        continue;
                    }
                    try out.append(s.arena, (try c.stmt(stmt, 0)).int());
                }
                try s.splice(cm, place, out.items, false);
                new_roots = out.items;
            },
            .decl => {
                var out: std.ArrayList(u32) = .empty;
                try out.appendSlice(s.arena, bindings.items);
                for (body[0 .. body.len - 1]) |stmt| try out.append(s.arena, (try c.stmt(stmt, 0)).int());
                const ret: Index = @fromBackingInt(@intCast(fm.ir.data(body[body.len - 1]).lhs));
                const e = try c.expr(ret, 0);
                const d = cm.ir.data(place.stmt);
                cm.setData(place.stmt, d.lhs, e.int());
                try out.append(s.arena, place.stmt.int());
                try s.splice(cm, place, out.items, true);
                new_roots = out.items;
            },
        }
        if (delta) |r| try s.extend(cm, site.top, r, new_roots);
        return true;
    }

    // ---- Identical functions are one --------------------------------------

    /// `backend.md` §9, *Identical functions are one* (added 2026-10-24,
    /// #934): two top-level `const f = (…) => …` that nothing assigns,
    /// whose code is the same (`sameCode`) — `Maybe.withDefault` and
    /// `Result.withDefault` once `Just` and `Ok` are both tag 0 — are one
    /// function. Every mention of one, the merged one, names the kept one where
    /// its module can name it, and reachability drops the merged one — when
    /// every mention of the merged one is the callee of a call, so that
    /// nothing can tell the two apart by identity, and the kept one is bound
    /// whenever the merged one is called (declared before it, in a module its
    /// module imports from, or the merged one reached by no top-level
    /// initialiser). One that a file the pass cannot see names keeps its own.
    /// True when a mention moved.
    fn mergeSame(s: *Spec) Allocator.Error!bool {
        const Cand = struct { g: u32, module: u32, at: u32, value: Index, hash: u64 };
        var cands: std.ArrayList(Cand) = .empty;
        for (s.mods, 0..) |*m, mi| {
            // A node lowering listed for the optimiser — a binding kept for
            // its effect, a discarded value, a function whose result nothing
            // reads (printed with no `return`) — prints differently from
            // the same node unlisted: a function holding one is never merged.
            const t = m.tables orelse continue;
            var listed: std.DynamicBitSetUnmanaged = try .initEmpty(s.arena, m.ir.nodes.len);
            for ([_][]const Index{ t.keep.items, t.discards.items, t.unobserved.items }) |list| {
                for (list) |node| if (node.int() < listed.bit_length) listed.set(node.int());
            }
            for (m.ir.extraSlice(m.ir.body, Index), 0..) |stmt, at| {
                if (m.ir.tag(stmt) != .const_decl) continue;
                const g = m.globalOf(@fromBackingInt(@intCast(m.ir.data(stmt).lhs))) orelse continue;
                if (g >= s.assigned.len or s.assigned[g]) continue;
                const value: Index = @fromBackingInt(@intCast(m.ir.data(stmt).rhs));
                if (m.ir.tag(value) != .arrow) continue;
                const hash = try s.codeHash(m, value, &listed) orelse continue;
                try cands.append(s.arena, .{ .g = g, .module = @intCast(mi), .at = @intCast(at), .value = value, .hash = hash });
            }
        }
        // Which modules each module reads names of: what is evaluated
        // before it.
        const deps = try s.moduleDeps();
        const startup = try s.startupReach();
        std.mem.sort(Cand, cands.items, {}, struct {
            fn less(_: void, a: Cand, b: Cand) bool {
                return a.hash < b.hash or (a.hash == b.hash and a.g < b.g);
            }
        }.less);
        // Whether each name is only ever called: one whose value is taken —
        // passed, stored, compared — may be told from another by its
        // identity (a listener added twice, a property set on it), so its
        // mentions are not moved.
        const mentions = try s.arena.alloc(u32, s.globals);
        @memset(mentions, 0);
        const calls = try s.arena.alloc(u32, s.globals);
        @memset(calls, 0);
        for (s.mods) |*m| for (m.ir.extraSlice(m.ir.body, Index)) |top| {
            for (try s.preorder(m, top)) |node| switch (m.ir.tag(node)) {
                .ident => if (m.globalOf(@fromBackingInt(@intCast(m.ir.data(node).lhs)))) |g| {
                    if (g < mentions.len) mentions[g] += 1;
                },
                .call => {
                    const callee: Index = @fromBackingInt(@intCast(m.ir.data(node).lhs));
                    if (m.ir.tag(callee) == .ident) if (m.globalOf(@fromBackingInt(@intCast(m.ir.data(callee).lhs)))) |g| {
                        if (g < calls.len) calls[g] += 1;
                    };
                },
                else => {},
            };
        };
        const to = try s.arena.alloc(u32, s.globals);
        @memset(to, none);
        var any = false;
        var i: usize = 0;
        while (i < cands.items.len) {
            var j = i;
            while (j < cands.items.len and cands.items[j].hash == cands.items[i].hash) j += 1;
            const group = cands.items[i..j];
            i = j;
            for (group, 0..) |a, ai| {
                if (to[a.g] != none) continue;
                for (group[ai + 1 ..]) |b| {
                    if (to[b.g] != none) continue;
                    // The kept one must be bound whenever the merged one is:
                    // declared before it in its module, or in a module
                    // evaluated before its module. Otherwise a call made at
                    // start-up could meet the kept `const` before it is
                    // initialised. The merged one is only ever called, and
                    // named by no file the pass cannot see.
                    const a_first = if (b.module == a.module) a.at < b.at else try s.dependsOn(deps, b.module, a.module);
                    const b_first = if (b.module == a.module) b.at < a.at else try s.dependsOn(deps, a.module, b.module);
                    // Or the merged one runs only once every module is
                    // evaluated: no top-level initialiser reaches it.
                    const drop_b = (a_first or !startup[b.g]) and !isRoot(s.in, b.g) and mentions[b.g] == calls[b.g];
                    const drop_a = !drop_b and (b_first or !startup[a.g]) and !isRoot(s.in, a.g) and mentions[a.g] == calls[a.g];
                    if (!drop_a and !drop_b) continue;
                    if (!try s.sameCode(&s.mods[a.module], a.value, &s.mods[b.module], b.value)) continue;
                    any = true;
                    if (drop_b) {
                        to[b.g] = a.g;
                    } else {
                        to[a.g] = b.g;
                        break;
                    }
                }
            }
        }
        if (!any) return false;
        var moved = false;
        for (s.mods) |*m| {
            const body = try s.arena.dupe(Index, m.ir.extraSlice(m.ir.body, Index));
            for (body) |top| {
                var hits: std.ArrayList(struct { node: Index, name: NameIndex }) = .empty;
                for (try s.preorder(m, top)) |node| {
                    if (m.ir.tag(node) != .ident) continue;
                    const g = m.globalOf(@fromBackingInt(@intCast(m.ir.data(node).lhs))) orelse continue;
                    if (g >= to.len or to[g] == none) continue;
                    // A kept one may itself be merged into one before it:
                    // each step goes to one evaluated earlier, so the chain
                    // ends.
                    var kept = to[g];
                    while (to[kept] != none) kept = to[kept];
                    const name = try s.nameIn(m, kept) orelse continue;
                    try hits.append(s.arena, .{ .node = node, .name = name });
                }
                if (hits.items.len == 0) continue;
                within(m, top);
                for (hits.items) |h| m.setNode(h.node, .ident, h.name.int(), 0);
                try s.leave(m);
                moved = true;
            }
        }
        return moved;
    }

    /// A hash of arrow `value`'s code that `sameCode` agrees with: its nodes'
    /// tags in walk order, each literal's bytes, each property's name, each
    /// whole-program name's id and each operator; its locals not at all.
    /// Null for a function holding a node `sameCode` does not compare.
    fn codeHash(s: *Spec, m: *Mod, value: Index, listed: *const std.DynamicBitSetUnmanaged) Allocator.Error!?u64 {
        const ir = m.ir;
        var h: std.hash.Wyhash = .init(0);
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, value);
        while (JsIr.popOperand(&stack)) |node| {
            if (node.int() < listed.bit_length and listed.isSet(node.int())) return null;
            const tag = ir.tag(node);
            const d = ir.data(node);
            h.update(std.mem.asBytes(&tag));
            switch (tag) {
                .ident => if (m.globalOf(@fromBackingInt(@intCast(d.lhs)))) |g| h.update(std.mem.asBytes(&g)),
                .number, .string, .template_chunk => h.update(ir.bytes(node)),
                .member, .property => h.update(std.mem.asBytes(&ir.name(@fromBackingInt(@intCast(if (tag == .member) d.rhs else d.lhs))).base)),
                .binary, .unary, .arrow => h.update(std.mem.asBytes(&d.rhs)),
                .true_lit, .false_lit, .null_lit, .undefined_lit, .cond, .call, .new_call, .return_stmt, .expr_stmt, .throw_stmt, .if_stmt, .object, .array, .template, .const_decl, .let_decl, .index_get, .assign, .assign_stmt, .sequence => {},
                else => return null,
            }
            try pushChildren(s.arena, ir, node, &stack);
        }
        return h.final();
    }

    /// Per module, the modules it imports a name from: ES module evaluation
    /// order evaluates each before it. A mention with no import — a body
    /// copied from another module into one scope — orders nothing.
    fn moduleDeps(s: *Spec) Allocator.Error![]const []const u32 {
        const out = try s.arena.alloc([]const u32, s.mods.len);
        for (s.mods, out, 0..) |*m, *o, mi| {
            const seen = try s.arena.alloc(bool, s.mods.len);
            @memset(seen, false);
            var list: std.ArrayList(u32) = .empty;
            const note = struct {
                fn add(sp: *Spec, mm: *Mod, n: NameIndex, me: usize, sn: []bool, l: *std.ArrayList(u32)) Allocator.Error!void {
                    const g = mm.globalOf(n) orelse return;
                    const decl = sp.decl[g] orelse return;
                    if (decl.module == me or sn[decl.module]) return;
                    sn[decl.module] = true;
                    try l.append(sp.arena, decl.module);
                }
            };
            for (m.ir.extraSlice(m.ir.body, Index)) |top| {
                if (m.ir.tag(top) == .import_stmt) {
                    const imp = m.ir.extraData(@fromBackingInt(@intCast(m.ir.data(top).lhs)), JsIr.Import);
                    for (m.ir.extraSlice(imp.specs(), JsIr.Specifier)) |spec| try note.add(s, m, spec.local, mi, seen, &list);
                }
            }
            o.* = list.items;
        }
        return out;
    }

    /// Per whole-program name: whether evaluating the modules may run or
    /// read it — mentioned by a top-level statement that is not a function's
    /// declaration, or by the declaration of a name that is, every node of
    /// it, a function made there included. A function no such statement
    /// reaches runs only once every module is evaluated, called from what
    /// the entry file starts.
    fn startupReach(s: *Spec) Allocator.Error![]const bool {
        const reach = try s.arena.alloc(bool, s.globals);
        @memset(reach, false);
        var work: std.ArrayList(u32) = .empty;
        const visit = struct {
            fn stmt(sp: *Spec, m: *Mod, top: Index, r: []bool, w: *std.ArrayList(u32)) Allocator.Error!void {
                for (try sp.preorder(m, top)) |node| if (m.ir.tag(node) == .ident) {
                    const g = m.globalOf(@fromBackingInt(@intCast(m.ir.data(node).lhs))) orelse continue;
                    if (g >= r.len or r[g]) continue;
                    r[g] = true;
                    try w.append(sp.arena, g);
                };
            }
        };
        for (s.mods) |*m| for (m.ir.extraSlice(m.ir.body, Index)) |top| {
            switch (m.ir.tag(top)) {
                .import_stmt, .export_stmt, .func_decl, .gen_decl => continue,
                .const_decl => if (m.ir.tag(@as(Index, @fromBackingInt(@intCast(m.ir.data(top).rhs)))) == .arrow) continue,
                else => {},
            }
            try visit.stmt(s, m, top, reach, &work);
        };
        while (work.pop()) |g| {
            const decl = s.decl[g] orelse continue;
            try visit.stmt(s, &s.mods[decl.module], decl.stmt, reach, &work);
        }
        return reach;
    }

    /// Whether module `from` imports from module `to`, directly or through
    /// the modules it imports from (`moduleDeps`): `to` is then evaluated
    /// before it.
    fn dependsOn(s: *Spec, deps: []const []const u32, from: u32, to: u32) Allocator.Error!bool {
        const seen = try s.arena.alloc(bool, deps.len);
        @memset(seen, false);
        var work: std.ArrayList(u32) = .empty;
        try work.append(s.arena, from);
        seen[from] = true;
        while (work.pop()) |m| for (deps[m]) |d| {
            if (d == to) return true;
            if (seen[d]) continue;
            seen[d] = true;
            try work.append(s.arena, d);
        };
        return false;
    }

    /// Whether arrows `a` of `ma` and `b` of `mb` are the same code: the same
    /// node tags in the same places, the same literals, operators and
    /// property names, the same whole-program names, and each local of one
    /// in exactly the places of one local of the other — declared by the
    /// same parameter or declaration. Two such functions do the same thing
    /// with the same arguments, wherever they are called from.
    fn sameCode(s: *Spec, ma: *Mod, a: Index, mb: *Mod, b: Index) Allocator.Error!bool {
        const ia = ma.ir;
        const ib = mb.ir;
        const fwd = try s.arena.alloc(u32, ia.names.len);
        @memset(fwd, none);
        const back = try s.arena.alloc(u32, ib.names.len);
        @memset(back, none);
        const pair = struct {
            fn names(f: []u32, k: []u32, x: u32, y: u32) bool {
                if (x >= f.len or y >= k.len) return x == y and x == @backingInt(NameIndex.none);
                if (f[x] == none and k[y] == none) {
                    f[x] = y;
                    k[y] = x;
                    return true;
                }
                return f[x] == y and k[y] == x;
            }
        };
        var sa = try s.takeStack();
        defer s.giveStack(&sa);
        var sb = try s.takeStack();
        defer s.giveStack(&sb);
        try JsIr.pushOperand(s.arena, &sa, a);
        try JsIr.pushOperand(s.arena, &sb, b);
        while (true) {
            const x = JsIr.popOperand(&sa);
            const y = JsIr.popOperand(&sb);
            if (x == null or y == null) return x == null and y == null;
            const nx = x.?;
            const ny = y.?;
            const tag = ia.tag(nx);
            if (ib.tag(ny) != tag) return false;
            const dx = ia.data(nx);
            const dy = ib.data(ny);
            switch (tag) {
                .ident => {
                    const gx = ma.globalOf(@fromBackingInt(@intCast(dx.lhs)));
                    const gy = mb.globalOf(@fromBackingInt(@intCast(dy.lhs)));
                    if (gx != null or gy != null) {
                        if (gx == null or gy == null or gx.? != gy.?) return false;
                    } else if (!pair.names(fwd, back, dx.lhs, dy.lhs)) return false;
                },
                .number, .string, .template_chunk => if (!std.mem.eql(u8, ia.bytes(nx), ib.bytes(ny))) return false,
                .member => if (!ia.name(@fromBackingInt(@intCast(dx.rhs))).eql(ib.name(@fromBackingInt(@intCast(dy.rhs))))) return false,
                .property => if (!ia.name(@fromBackingInt(@intCast(dx.lhs))).eql(ib.name(@fromBackingInt(@intCast(dy.lhs))))) return false,
                .binary, .unary => if (dx.rhs != dy.rhs) return false,
                .arrow => {
                    if (dx.rhs != dy.rhs) return false;
                    const fx = ia.extraData(@fromBackingInt(@intCast(dx.lhs)), JsIr.Func);
                    const fy = ib.extraData(@fromBackingInt(@intCast(dy.lhs)), JsIr.Func);
                    const px = ia.extraSlice(fx.params(), NameIndex);
                    const py = ib.extraSlice(fy.params(), NameIndex);
                    if (px.len != py.len) return false;
                    for (px, py) |p, q| if (!pair.names(fwd, back, @backingInt(p), @backingInt(q))) return false;
                    if (ia.extraSlice(fx.body(), Index).len != ib.extraSlice(fy.body(), Index).len) return false;
                },
                .const_decl => if (!pair.names(fwd, back, dx.lhs, dy.lhs)) return false,
                .let_decl => {
                    if (!pair.names(fwd, back, dx.lhs, dy.lhs)) return false;
                    if ((dx.rhs == @backingInt(Node.OptionalIndex.none)) != (dy.rhs == @backingInt(Node.OptionalIndex.none))) return false;
                },
                .if_stmt => {
                    const bx = ia.extraData(@fromBackingInt(@intCast(dx.rhs)), JsIr.If);
                    const by = ib.extraData(@fromBackingInt(@intCast(dy.rhs)), JsIr.If);
                    if (ia.extraSlice(bx.thenBody(), Index).len != ib.extraSlice(by.thenBody(), Index).len) return false;
                    if (ia.extraSlice(bx.elseBody(), Index).len != ib.extraSlice(by.elseBody(), Index).len) return false;
                },
                .call, .new_call => if (ia.extraSlice(ia.subRange(@fromBackingInt(@intCast(dx.rhs))), Index).len != ib.extraSlice(ib.subRange(@fromBackingInt(@intCast(dy.rhs))), Index).len) return false,
                .object, .array, .template, .sequence => if (dx.rhs - dx.lhs != dy.rhs - dy.lhs) return false,
                .return_stmt => if ((dx.lhs == @backingInt(Node.OptionalIndex.none)) != (dy.lhs == @backingInt(Node.OptionalIndex.none))) return false,
                .true_lit, .false_lit, .null_lit, .undefined_lit, .cond, .expr_stmt, .throw_stmt, .index_get, .assign, .assign_stmt => {},
                else => return false,
            }
            try pushChildren(s.arena, ia, nx, &sa);
            try pushChildren(s.arena, ib, ny, &sb);
        }
    }

    // ---- Slice 9 across a call: a `case` on what a function returns ------

    /// `backend.md` §9, *Slice 9 across a call*: a function of statements
    /// whose every site is `const x = f(…)` and then the rest of a list that
    /// only cases on `x`, written into every site with each of its `return
    /// P` the rest of that list knowing `x` is `P` — when the copies are
    /// smaller than the function and its calls by `stmtSize`, a node count
    /// standing in for bytes (not bytes). One function at a time, the
    /// program counted again after each, until none is left or the program
    /// has grown to the pass's `copyLimit`.
    fn fuseCalls(s: *Spec) Allocator.Error!bool {
        if (s.in.fresh == .none) return false;
        var any = false;
        const limit = s.copyLimit();
        while (try s.fuseOne()) {
            any = true;
            if (s.programNodes() >= limit) {
                s.stats.inline_capped += 1;
                break;
            }
        }
        return any;
    }

    fn fuseOne(s: *Spec) Allocator.Error!bool {
        try s.inlineScan();
        const n = s.globals;
        const refs = s.io_refs[0..n];
        const assigned = try s.scratchOf(bool, &s.io_flags, n);
        for (assigned, s.io_assigned[0..n]) |*a, k| a.* = k != 0;
        // The functions that may gain: a top-level arrow some `return` of
        // which makes a value a case can see into.
        const wanted = try s.scratchOf(bool, &s.io_wanted, n);
        @memset(wanted, false);
        var any_wanted = false;
        for (0..n) |gi| {
            if (refs[gi] == 0) continue;
            const decl = s.decl[gi] orelse continue;
            const fm = &s.mods[decl.module];
            if (fm.ir.tag(decl.stmt) != .const_decl) continue;
            const value: Index = @fromBackingInt(@intCast(fm.ir.data(decl.stmt).rhs));
            if (fm.ir.tag(value) != .arrow or fm.ir.data(value).rhs != Node.arrow_plain) continue;
            const f = fm.ir.extraData(@fromBackingInt(@intCast(fm.ir.data(value).lhs)), JsIr.Func);
            const gop = try s.fuse_made.getOrPut(s.arena, .{ .module = fm.index, .node = value.int() });
            if (!gop.found_existing or gop.value_ptr.version != fm.version) {
                gop.value_ptr.* = .{ .version = fm.version, .made = try s.returnsMade(fm, fm.ir.extraSlice(f.body(), Index)) };
            }
            if (!gop.value_ptr.made) continue;
            wanted[gi] = true;
            any_wanted = true;
        }
        if (!any_wanted) return false;
        // Every call of one, in module and statement order, then grouped by
        // callee (a stable sort keeps that order within each).
        const Found = struct { g: u32, at: u32, site: CallSite };
        var found: std.ArrayList(Found) = .empty;
        for (s.mods, 0..) |*m, mi| {
            const ir = m.ir;
            for (ir.extraSlice(ir.body, Index)) |top| {
                for (try s.preorder(m, top)) |node| {
                    if (ir.tag(node) != .call) continue;
                    const callee: Index = @fromBackingInt(@intCast(ir.data(node).lhs));
                    if (ir.tag(callee) != .ident) continue;
                    const g = m.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs))) orelse continue;
                    if (g >= wanted.len or !wanted[g]) continue;
                    const decl = s.decl[g] orelse continue;
                    if (s.mods[decl.module].ir.tag(decl.stmt) != .const_decl) continue;
                    try found.append(s.arena, .{ .g = g, .at = @intCast(found.items.len), .site = .{ .module = @intCast(mi), .top = top, .call = node } });
                }
            }
        }
        std.mem.sort(Found, found.items, {}, struct {
            fn less(_: void, a: Found, b: Found) bool {
                return a.g < b.g or (a.g == b.g and a.at < b.at);
            }
        }.less);
        var i: usize = 0;
        while (i < found.items.len) {
            const g = found.items[i].g;
            var j = i;
            while (j < found.items.len and found.items[j].g == g) j += 1;
            const sites = try s.arena.alloc(CallSite, j - i);
            for (found.items[i..j], sites) |f, *site| site.* = f.site;
            i = j;
            if (g >= refs.len or refs[g] != sites.len) continue;
            if (try s.fuseAt(g, sites, assigned)) return true;
        }
        return false;
    }

    /// Whether some `return` of `stmts` — outside the functions in them —
    /// gives an object literal, a declared object, or a choice of one.
    fn returnsMade(s: *Spec, m: *Mod, stmts: []const Index) Allocator.Error!bool {
        const ir = m.ir;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        for (stmts) |st| try JsIr.pushOperand(s.arena, &stack, st);
        while (JsIr.popOperand(&stack)) |node| {
            switch (ir.tag(node)) {
                .arrow, .func_decl, .gen_decl => continue,
                .return_stmt => {
                    const v = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(node).lhs)))).unwrap() orelse continue;
                    if (s.producer(m, v, 0)) return true;
                    continue;
                },
                .if_stmt, .switch_stmt, .switch_case, .block_stmt, .while_true, .for_of, .try_stmt => {},
                else => continue,
            }
            try pushChildren(s.arena, ir, node, &stack);
        }
        return false;
    }

    /// One site that fits: the binding `x` of `stmt`, the list `stmt` is in
    /// (`place`) and where in it.
    const FuseSite = struct {
        site: CallSite,
        place: Place,
        x: NameIndex,
        at: usize,
        rest: []const Index,
    };

    /// What a copy of `f`'s body hands each of its `return`s to: the site's
    /// binding and the statements after it (`Copy.cont`).
    const Cont = struct {
        x: NameIndex,
        rest: []const Index,
        top: Index,
        call: Index,
        /// Per parameter of `f`: whether its body only reads properties of it
        /// (`stableChain`).
        inspected: []const bool,
        args: []const Index,
        /// Per whole-program name: whether the program assigns it.
        assigned: []const bool,
    };

    fn fuseAt(s: *Spec, g: u32, sites: []const CallSite, assigned: []const bool) Allocator.Error!bool {
        const decl = s.decl[g] orelse return false;
        if (isRoot(s.in, g) or assigned[g]) return false;
        const fm = &s.mods[decl.module];
        if (std.mem.indexOfScalar(Index, fm.ir.extraSlice(fm.ir.body, Index), decl.stmt) == null) return false;
        const value: Index = @fromBackingInt(@intCast(fm.ir.data(decl.stmt).rhs));
        if (fm.ir.tag(value) != .arrow or fm.ir.data(value).rhs != Node.arrow_plain) return false;
        const f = fm.ir.extraData(@fromBackingInt(@intCast(fm.ir.data(value).lhs)), JsIr.Func);
        const params = try s.arena.dupe(NameIndex, fm.ir.extraSlice(f.params(), NameIndex));
        const body = try s.arena.dupe(Index, fm.ir.extraSlice(f.body(), Index));
        const scan = try s.scanOf(fm, decl.stmt, value, f) orelse return false;
        for (params) |p| if (p.unwrap()) |i| if (scan.counts[i] > 1) return false;
        for (scan.assigns) |a| if (a) return false;
        if (!try s.plainStmts(fm, body, true) or !allReturn(fm.ir, body, 0)) return false;
        const inspected = try s.arena.alloc(bool, params.len);
        for (params, inspected) |p, *insp| insp.* = try s.onlyInspectedIn(fm, body, p);

        var fits: std.ArrayList(FuseSite) = .empty;
        for (sites) |site| {
            if (site.module == decl.module and site.top == decl.stmt) return false;
            const cm = &s.mods[site.module];
            const place = try s.placeKept(cm, site) orelse return false;
            if (place.kind != .decl or place.top_level or place.owner == null) return false;
            if (cm.ir.tag(place.stmt) != .const_decl and cm.ir.tag(place.stmt) != .let_decl) return false;
            const x: NameIndex = @fromBackingInt(@intCast(cm.ir.data(place.stmt).lhs));
            if (x == .none or cm.globalOf(x) != null) return false;
            const list = listAt(cm, place.owner.?);
            const at = std.mem.indexOfScalar(Index, list, place.stmt) orelse return false;
            const rest = try s.arena.dupe(Index, list[at + 1 ..]);
            if (rest.len == 0) return false;
            if (!try s.plainStmts(cm, rest, false) or !allReturn(cm.ir, rest, 0)) return false;
            // An unlabelled `break` of the rest that leaves it would, copied in
            // place of a `return` inside a `switch` of `f`, leave that
            // `switch` instead.
            if (leavingBreak(cm.ir, rest, 0)) return false;
            var size: u32 = 0;
            for (rest) |r| size += try s.stmtSize(cm, @intCast(site.module), r);
            if (size > 96) return false;
            if (try declCount(s, cm, site.top, x) != 1) return false;
            if (!try s.onlyCased(cm, site.top, x, rest)) return false;
            if (try s.mentionsGlobal(cm, rest, g)) return false;
            const args = cm.ir.extraSlice(cm.ir.subRange(@fromBackingInt(@intCast(cm.ir.data(site.call).rhs))), Index);
            if (args.len != params.len) return false;
            for (args) |a| if (!try s.atomArgument(cm, a, site.top, assigned)) return false;
            if (decl.module != site.module) for (scan.mentioned.items) |nm| {
                if (nm < scan.counts.len and scan.counts[nm] != 0) continue;
                const h = fm.globalOf(@fromBackingInt(@intCast(nm))) orelse return false;
                if (!try s.canName(cm, h)) return false;
            };
            try fits.append(s.arena, .{ .site = site, .place = place, .x = x, .at = at, .rest = rest });
        }
        if (fits.items.len == 0) return false;

        // Every copy, made before any is written: the decision is the sum.
        // The declaration: `const f=(…)=>{…}`, its body as statements (a
        // function counts as big to `nodeCount`).
        var old_size: u32 = 8 + @as(u32, @intCast(params.len));
        for (body) |st| old_size += try s.stmtSize(fm, decl.module, st);
        var new_size: u32 = 0;
        const copies = try s.arena.alloc([]const u32, fits.items.len);
        for (fits.items, copies) |fit, *copy| {
            const cm = &s.mods[fit.site.module];
            const mi: u32 = fit.site.module;
            const list = listAt(cm, fit.place.owner.?);
            for (list[fit.at..]) |r| old_size += try s.stmtSize(cm, mi, r);
            const args = try s.arena.dupe(Index, cm.ir.extraSlice(cm.ir.subRange(@fromBackingInt(@intCast(cm.ir.data(fit.site.call).rhs))), Index));
            const cont: Cont = .{ .x = fit.x, .rest = fit.rest, .top = fit.site.top, .call = fit.site.call, .inspected = inspected, .args = args, .assigned = assigned };
            var c: Copy = .{
                .s = s,
                .src = fm,
                .dst = cm,
                .cross = decl.module != fit.site.module,
                .site = cm.ir.pos(fit.site.call),
                .renamed = try s.arena.alloc(u32, fm.ir.names.len),
                .subst = try s.arena.alloc(Node.OptionalIndex, fm.ir.names.len),
                .cont = &cont,
            };
            @memset(c.renamed, none);
            @memset(c.subst, .none);
            if (c.cross) for (scan.mentioned.items) |nm| {
                if (nm < scan.counts.len and scan.counts[nm] != 0) continue;
                const h = fm.globalOf(@fromBackingInt(@intCast(nm))).?;
                c.renamed[nm] = (try s.nameIn(cm, h)).?.int();
            };
            for (scan.declared.items) |nm| {
                if (std.mem.indexOfScalar(NameIndex, params, @fromBackingInt(@intCast(nm))) != null) continue;
                try c.fresh(nm, false);
            }
            for (params, args) |p, a| if (p.unwrap()) |pi| {
                c.subst[pi] = a.toOptional();
            };
            var out: std.ArrayList(u32) = .empty;
            for (body) |stmt| try c.stmtsInto(stmt, &out, 0);
            for (out.items) |o| new_size += try s.stmtSize(cm, mi, @fromBackingInt(@intCast(o)));
            copy.* = out.items;
        }
        if (new_size >= old_size) return false;
        s.noteCopy(decl.module, g);
        for (fits.items, copies) |fit, copy| {
            const cm = &s.mods[fit.site.module];
            // Where the list is now: an earlier site of this module may have
            // been written into another list, never into this one, whose
            // range is stored where it was.
            const place = try s.placeKept(cm, fit.site) orelse unreachable;
            const list = listAt(cm, place.owner.?);
            const at = std.mem.indexOfScalar(Index, list, place.stmt).?;
            var items: std.ArrayList(u32) = .empty;
            for (list[0..at]) |item| try items.append(s.arena, item.int());
            try items.appendSlice(s.arena, copy);
            // The list is the site's statement's: the rest of it goes, the
            // copy comes in its place (`retract`, `extend`).
            const gone = try s.arena.alloc(u32, list.len - at);
            for (gone, list[at..]) |*g_, item| g_.* = item.int();
            within(cm, fit.site.top);
            const delta = s.retract(cm, fit.site.top, gone) catch |err| {
                cm.scope = null;
                return err;
            };
            const start = try cm.append(s.gpa, items.items);
            cm.changed();
            cm.extra.items[place.owner.?] = start;
            cm.extra.items[place.owner.? + 1] = start + @as(u32, @intCast(items.items.len));
            if (delta) |r| s.extend(cm, fit.site.top, r, copy) catch |err| {
                cm.scope = null;
                return err;
            };
            try s.leave(cm);
        }
        return true;
    }

    /// The statements of the list whose range is stored at `owner`.
    fn listAt(m: *Mod, owner: u32) []const Index {
        return m.ir.extraSlice(.{ .start = @fromBackingInt(@intCast(m.extra.items[owner])), .end = @fromBackingInt(@intCast(m.extra.items[owner + 1])) }, Index);
    }

    /// Statements a copy may be made of: no function, no `continue`, no
    /// `try`, no loop; every `return` with a value when
    /// `returns_valued`.
    fn plainStmts(s: *Spec, m: *Mod, stmts: []const Index, returns_valued: bool) Allocator.Error!bool {
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        for (stmts) |st| try JsIr.pushOperand(s.arena, &stack, st);
        var budget: u32 = max_inline_nodes;
        while (JsIr.popOperand(&stack)) |node| {
            if (budget == 0) return false;
            budget -= 1;
            switch (m.ir.tag(node)) {
                .arrow, .func_decl, .gen_decl, .continue_stmt, .try_stmt, .while_true, .for_of, .import_stmt, .export_stmt => return false,
                .return_stmt => if (returns_valued and @as(Node.OptionalIndex, @fromBackingInt(@intCast(m.ir.data(node).lhs))) == .none) return false,
                else => {},
            }
            try pushChildren(s.arena, m.ir, node, &stack);
        }
        return true;
    }

    /// Whether every mention of `p` in `stmts` is the object of a property
    /// read, never a write of one.
    fn onlyInspectedIn(s: *Spec, m: *Mod, stmts: []const Index, p: NameIndex) Allocator.Error!bool {
        var seen: std.ArrayList(Inspecting) = .empty;
        return s.inspectedIn(m, stmts, p, &seen);
    }

    /// A parameter `inspectedIn` is asking of: assumed only inspected while
    /// it is asked, since a call back to it reads nothing more.
    const Inspecting = struct { module: u32, value: Index, param: usize };

    /// `onlyInspectedIn`, where `p` handed to a top-level function is a
    /// property read too when that function only reads properties of the
    /// parameter it takes it as (`inspectedParam`).
    fn inspectedIn(s: *Spec, m: *Mod, stmts: []const Index, p: NameIndex, seen: *std.ArrayList(Inspecting)) Allocator.Error!bool {
        if (p == .none) return false;
        const ir = m.ir;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        for (stmts) |st| try JsIr.pushOperand(s.arena, &stack, st);
        while (JsIr.popOperand(&stack)) |node| {
            const d = ir.data(node);
            switch (ir.tag(node)) {
                .ident => if (d.lhs == p.int()) return false,
                .call => {
                    const callee: Index = @fromBackingInt(@intCast(d.lhs));
                    const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index);
                    var handed = false;
                    for (args) |a| handed = handed or (ir.tag(a) == .ident and ir.data(a).lhs == p.int());
                    if (handed) {
                        try JsIr.pushOperand(s.arena, &stack, callee);
                        for (args, 0..) |a, i| {
                            if (ir.tag(a) == .ident and ir.data(a).lhs == p.int()) {
                                if (!try s.inspectedParam(m, callee, args.len, i, seen)) return false;
                                continue;
                            }
                            try JsIr.pushOperand(s.arena, &stack, a);
                        }
                        continue;
                    }
                },
                .member => {
                    const obj: Index = @fromBackingInt(@intCast(d.lhs));
                    if (ir.tag(obj) == .ident and ir.data(obj).lhs == p.int()) continue;
                },
                .assign_stmt, .assign => {
                    const target: Index = @fromBackingInt(@intCast(d.lhs));
                    if (ir.tag(target) == .member) {
                        const obj: Index = @fromBackingInt(@intCast(ir.data(target).lhs));
                        if (ir.tag(obj) == .ident and ir.data(obj).lhs == p.int()) return false;
                    }
                },
                else => {},
            }
            try pushChildren(s.arena, ir, node, &stack);
        }
        return true;
    }

    /// Whether `callee`, called with `count` arguments, is a top-level
    /// `const f = (…) => {…}` of the program that nothing assigns and nothing
    /// the pass cannot see names, whose parameter `i` its body only reads
    /// properties of (`inspectedIn`).
    fn inspectedParam(s: *Spec, m: *Mod, callee: Index, arity: usize, i: usize, seen: *std.ArrayList(Inspecting)) Allocator.Error!bool {
        const ir = m.ir;
        if (ir.tag(callee) != .ident) return false;
        const g = m.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs))) orelse return false;
        if (g >= s.assigned.len or s.assigned[g] or isRoot(s.in, g)) return false;
        const decl = s.decl[g] orelse return false;
        const fm = &s.mods[decl.module];
        if (fm.ir.tag(decl.stmt) != .const_decl) return false;
        const value: Index = @fromBackingInt(@intCast(fm.ir.data(decl.stmt).rhs));
        if (fm.ir.tag(value) != .arrow or fm.ir.data(value).rhs != Node.arrow_plain) return false;
        const f = fm.ir.extraData(@fromBackingInt(@intCast(fm.ir.data(value).lhs)), JsIr.Func);
        const params = fm.ir.extraSlice(f.params(), NameIndex);
        if (params.len != arity) return false;
        for (seen.items) |x| if (x.module == decl.module and x.value == value and x.param == i) return true;
        try seen.append(s.arena, .{ .module = decl.module, .value = value, .param = i });
        return s.inspectedIn(fm, fm.ir.extraSlice(f.body(), Index), params[i], seen);
    }

    /// Whether every mention of local `x` in `top` is the object of a
    /// property read, an operand of `===` or `!==` — what a `case` on it
    /// does — or, whole, the value a `return` of `rest` gives, directly or
    /// as a branch of a conditional it gives (`returnedWhole`); and nothing
    /// writes a property of it. A whole read is the last thing done with
    /// `x`, so nothing holds it before a comparison reads it.
    fn onlyCased(s: *Spec, m: *Mod, top: Index, x: NameIndex, rest: []const Index) Allocator.Error!bool {
        const Sole = struct {
            s: *Spec,
            m: *Mod,
            top: Index,
            pub fn once(c: @This(), z: NameIndex) Allocator.Error!bool {
                return try declCount(c.s, c.m, c.top, z) == 1 and !try c.s.assignedInTop(c.m, c.top, z);
            }
        };
        return casedOnly(s.arena, m.ir, top, x, rest, Sole{ .s = s, .m = m, .top = top });
    }

    fn mentionsGlobal(s: *Spec, m: *Mod, stmts: []const Index, g: u32) Allocator.Error!bool {
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        for (stmts) |st| try JsIr.pushOperand(s.arena, &stack, st);
        while (JsIr.popOperand(&stack)) |node| {
            if (m.ir.tag(node) == .ident) if (m.globalOf(@fromBackingInt(@intCast(m.ir.data(node).lhs)))) |h| if (h == g) return true;
            try pushChildren(s.arena, m.ir, node, &stack);
        }
        return false;
    }

    /// A statement's size in slice 8's model: each expression's
    /// `nodeCount`, and 4 for each statement around them.
    fn stmtSize(s: *Spec, m: *Mod, mi: u32, stmt: Index) Allocator.Error!u32 {
        const ir = m.ir;
        var size: u32 = 0;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        try JsIr.pushOperand(s.arena, &stack, stmt);
        while (JsIr.popOperand(&stack)) |node| {
            if (!ir.tag(node).isStatement() and ir.tag(node) != .switch_case) {
                size += nodeCount(ir, node, &s.pts, mi);
                continue;
            }
            size += 4;
            try pushChildren(s.arena, ir, node, &stack);
        }
        return size;
    }

    /// The statements `return P` of a copied body becomes at a fused site:
    /// the rest of the site's list, knowing its binding is `p`, a node of
    /// the site's module (`Copy.cont`).
    fn continuation(s: *Spec, m: *Mod, cont: *const Cont, p: Index, out: *std.ArrayList(u32), depth: u32) Allocator.Error!void {
        const ir = m.ir;
        if (ir.tag(p) == .cond and depth < 4) {
            // `return t ? A : B`: the test, then each branch's own copy.
            const c = ir.extraData(@fromBackingInt(@intCast(ir.data(p).rhs)), JsIr.Cond);
            var then: std.ArrayList(u32) = .empty;
            try s.continuation(m, cont, c.consequent, &then, depth + 1);
            var els: std.ArrayList(u32) = .empty;
            try s.continuation(m, cont, c.alternate, &els, depth + 1);
            const then_start = try m.append(s.gpa, then.items);
            const else_start = try m.append(s.gpa, els.items);
            const branches = try m.append(s.gpa, &.{ then_start, then_start + @as(u32, @intCast(then.items.len)), else_start, else_start + @as(u32, @intCast(els.items.len)) });
            try out.append(s.arena, (try m.addNode(s.gpa, .if_stmt, ir.pos(p), ir.data(p).lhs, branches)).int());
            return;
        }
        // An object literal's names are read where `R` reads its fields,
        // later than the `return`: none may be assigned in between.
        const known = (ir.tag(p) == .object and inertOf(ir, p, false) and try s.immutableNames(m, p, cont.top, cont.assigned)) or
            (ir.tag(p) == .ident and ir.name(@fromBackingInt(@intCast(ir.data(p).lhs))).module != .none) or
            switch (ir.tag(p)) {
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => true,
                else => false,
            } or
            try s.stableChain(m, cont, p);
        var k: Copy = .{
            .s = s,
            .src = m,
            .dst = m,
            .cross = false,
            .renamed = try s.arena.alloc(u32, m.names.items.len),
            .subst = try s.arena.alloc(Node.OptionalIndex, m.names.items.len),
        };
        @memset(k.renamed, none);
        @memset(k.subst, .none);
        // The rest's own declarations are named afresh in each copy.
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        for (cont.rest) |r| try JsIr.pushOperand(s.arena, &stack, r);
        while (JsIr.popOperand(&stack)) |node| {
            switch (ir.tag(node)) {
                .const_decl, .let_decl, .block_stmt => {
                    const nm: NameIndex = @fromBackingInt(@intCast(ir.data(node).lhs));
                    if (nm.unwrap()) |i| if (ir.name(nm).module == .none) try k.fresh(i, false);
                },
                else => {},
            }
            try pushChildren(s.arena, ir, node, &stack);
        }
        if (known and try s.projectsToAtoms(m, cont, p)) {
            k.known = .{ .x = cont.x, .p = p, .cont = cont };
        } else {
            // Bound once, and the rest reads the binding.
            const x2 = try s.freshLocal(m);
            try out.append(s.arena, (try m.addNode(s.gpa, .const_decl, ir.pos(p), x2.int(), p.int())).int());
            k.subst[cont.x.int()] = (try m.addNode(s.gpa, .ident, Node.no_pos, x2.int(), 0)).toOptional();
        }
        for (cont.rest) |r| try k.stmtsInto(r, out, 0);
    }

    /// Whether every read of `cont.x` the rest makes, `x` known to be `p`,
    /// ends at a name, a literal, or a chain on a value that is not an
    /// object literal — so that no object is made twice where it was made
    /// once.
    fn projectsToAtoms(s: *Spec, m: *Mod, cont: *const Cont, p: Index) Allocator.Error!bool {
        const ir = m.ir;
        var made: u32 = 0;
        var stack = try s.takeStack();
        defer s.giveStack(&stack);
        for (cont.rest) |r| try JsIr.pushOperand(s.arena, &stack, r);
        while (JsIr.popOperand(&stack)) |node| {
            if (ir.tag(node) == .member) {
                if (memberBase(ir, node)) |base| if (ir.data(base).lhs == cont.x.int()) {
                    // The outermost read of the chain: only it is asked.
                    const v = project(ir, node, cont.x, p) orelse return false;
                    switch (ir.tag(v)) {
                        // A value made where it is read: once per copy at most.
                        .object, .array, .arrow, .template => {
                            made += 1;
                            if (made > 1) return false;
                        },
                        else => {},
                    }
                    continue;
                };
            }
            // Compared: an object literal is decided; any other `p` is read
            // where `x` was.
            if (ir.tag(node) == .binary) {
                const op: JsIr.BinaryOp = @fromBackingInt(@intCast(ir.data(node).rhs));
                if (op == .strict_eq or op == .strict_ne) {
                    const b = ir.extraData(@fromBackingInt(@intCast(ir.data(node).lhs)), JsIr.Binary);
                    for ([_]Index{ b.left, b.right }) |side| {
                        if (ir.tag(side) == .ident and ir.data(side).lhs == cont.x.int()) {
                            if (ir.tag(p) != .object) switch (ir.tag(p)) {
                                .array, .arrow, .template => return false,
                                else => {},
                            };
                            continue;
                        }
                        try JsIr.pushOperand(s.arena, &stack, side);
                    }
                    continue;
                }
            }
            // Read whole (`onlyCased`): `p` is written there, so an object
            // literal is made there, once per copy at most.
            if (ir.tag(node) == .ident and ir.data(node).lhs == cont.x.int()) switch (ir.tag(p)) {
                .object => {
                    made += 1;
                    if (made > 1) return false;
                },
                .array, .arrow, .template => return false,
                else => {},
            };
            try pushChildren(s.arena, ir, node, &stack);
        }
        return true;
    }

    /// `p` is `y.k` read twice with one answer: `y` a local of the site's
    /// function made by an object literal holding `k`, which nothing
    /// assigns, whose every mention is the object of a property read or an
    /// argument of the site's call to a parameter the function only reads
    /// properties of; and the value at `k` an object or array literal, or a
    /// `const` of one — so never `NaN`, and `p === p` is true.
    fn stableChain(s: *Spec, m: *Mod, cont: *const Cont, p: Index) Allocator.Error!bool {
        const ir = m.ir;
        if (ir.tag(p) != .member) return false;
        const base: Index = @fromBackingInt(@intCast(ir.data(p).lhs));
        if (ir.tag(base) != .ident) return false;
        const y: NameIndex = @fromBackingInt(@intCast(ir.data(base).lhs));
        if (y == .none or ir.name(y).module != .none) return false;
        const key: NameIndex = @fromBackingInt(@intCast(ir.data(p).rhs));
        const made = try s.soleInit(m, cont.top, y) orelse return false;
        if (ir.tag(made) == .call) {
            // Made by a call of a function that makes a fresh object each
            // time, with its own value at `k` (`freshHeld`).
            if (!try s.freshHeld(m, made, key)) return false;
        } else {
            if (ir.tag(made) != .object) return false;
            const v = propertyOf(ir, made, key) orelse return false;
            const held = switch (ir.tag(v)) {
                .object, .array => true,
                .ident => blk: {
                    const z: NameIndex = @fromBackingInt(@intCast(ir.data(v).lhs));
                    if (ir.name(z).module != .none) break :blk false;
                    const zi = try s.soleInit(m, cont.top, z) orelse break :blk false;
                    break :blk ir.tag(zi) == .object or ir.tag(zi) == .array;
                },
                else => false,
            };
            if (!held) return false;
        }
        // Every mention of `y`.
        for (try s.preorder(m, cont.top)) |node| {
            const d = ir.data(node);
            switch (ir.tag(node)) {
                .member => {},
                .call => if (node == cont.call) {
                    for (cont.args, cont.inspected) |a, insp| {
                        if (ir.tag(a) == .ident and ir.data(a).lhs == y.int() and !insp) return false;
                    }
                },
                .assign_stmt, .assign => {
                    const target: Index = @fromBackingInt(@intCast(d.lhs));
                    if (ir.tag(target) == .ident and ir.data(target).lhs == y.int()) return false;
                    if (ir.tag(target) == .member) if (memberBase(ir, target)) |b| if (ir.data(b).lhs == y.int()) return false;
                },
                else => {},
            }
            // A mention that is neither a property's object nor a site's
            // argument.
            if (ir.tag(node) == .ident and d.lhs == y.int()) {
                if (!try s.mentionAllowed(m, cont, node)) return false;
            }
        }
        return true;
    }

    /// Whether call `call` of module `m` makes a fresh object whose value at
    /// `key` is made with it: its callee a top-level `const f = (…) => {…}`
    /// that nothing assigns and nothing the pass cannot see names, with no
    /// arguments, whose body is `const`s of object and array literals and
    /// then `return` of an object literal, the value at `key` an object or
    /// array literal or one of those `const`s. Each call then makes its own
    /// object, which nothing but the caller holds, and its own value at
    /// `key`, never `NaN` (`stableChain`).
    fn freshHeld(s: *Spec, m: *Mod, call: Index, key: NameIndex) Allocator.Error!bool {
        const ir = m.ir;
        if (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(call).rhs))), Index).len != 0) return false;
        const callee: Index = @fromBackingInt(@intCast(ir.data(call).lhs));
        if (ir.tag(callee) != .ident) return false;
        const g = m.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs))) orelse return false;
        if (g >= s.assigned.len or s.assigned[g] or isRoot(s.in, g)) return false;
        const decl = s.decl[g] orelse return false;
        const fm = &s.mods[decl.module];
        const fir = fm.ir;
        if (fir.tag(decl.stmt) != .const_decl) return false;
        const value: Index = @fromBackingInt(@intCast(fir.data(decl.stmt).rhs));
        return makesFreshAt(fir, value, ir.name(key));
    }

    /// Whether the mention `ident` of a `stableChain` base is the object of
    /// a property read or an argument of the site's call.
    fn mentionAllowed(s: *Spec, m: *Mod, cont: *const Cont, ident: Index) Allocator.Error!bool {
        const ir = m.ir;
        for (cont.args) |a| if (a == ident) return true;
        for (try s.preorder(m, cont.top)) |node| {
            if (ir.tag(node) == .member and ir.data(node).lhs == ident.int()) return true;
        }
        return false;
    }

    /// The tag a declared object — a top-level `const` of an object
    /// literal nothing assigns — has, as a literal of module `m`, when no
    /// code writes a `$` (slice 9's rule for a constructor's tag: no write
    /// of `$` in the program, and none by code the pass cannot see).
    fn declaredTag(s: *Spec, m: *Mod, ident: Index) Allocator.Error!?Index {
        const ir = m.ir;
        if (ir.tag(ident) != .ident) return null;
        const g = m.globalOf(@fromBackingInt(@intCast(ir.data(ident).lhs))) orelse return null;
        const decl = s.decl[g] orelse return null;
        if (s.assigned[g]) return null;
        const dm = &s.mods[decl.module];
        if (dm.ir.tag(decl.stmt) != .const_decl) return null;
        const obj: Index = @fromBackingInt(@intCast(dm.ir.data(decl.stmt).rhs));
        if (dm.ir.tag(obj) != .object) return null;
        // Slice 9's test for a tag (`tagValue`): no program code writes
        // `$` on the object or under a key it cannot name, and nothing the
        // pass cannot see writes one.
        if (s.in.tag_prop == none or !s.pts.ok or s.pts.unknown_any) return null;
        if (std.mem.indexOfScalar(u32, s.pts.unknown_props.items, s.in.tag_prop) != null) return null;
        const site = s.pts.siteAt(decl.module, obj) orelse return null;
        try s.readsSite(site);
        const st = &s.pts.sites.items[site];
        if (st.kind != .object or st.prog_any) return null;
        if (std.mem.indexOfScalar(u32, st.prog_props.items, s.in.tag_prop) != null) return null;
        if (site >= s.spread_sites.len or s.spread_sites[site]) return null;
        for (dm.ir.extraSlice(JsIr.inlineRange(dm.ir.data(obj)), Index)) |prop| {
            if (dm.ir.tag(prop) != .property) return null;
            if (s.pts.propId(decl.module, @fromBackingInt(@intCast(dm.ir.data(prop).lhs))) != s.in.tag_prop) continue;
            const v: Index = @fromBackingInt(@intCast(dm.ir.data(prop).rhs));
            return switch (dm.ir.tag(v)) {
                .string, .number => try m.addNode(s.gpa, dm.ir.tag(v), ir.pos(ident), try m.addBytes(s.gpa, dm.ir.bytes(v)), @intCast(dm.ir.bytes(v).len)),
                else => null,
            };
        }
        return null;
    }
    /// The initialiser of local `n`, declared once in `top` by a `const`
    /// (or a `let` nothing assigns); null otherwise.
    fn soleInit(s: *Spec, m: *Mod, top: Index, n: NameIndex) Allocator.Error!?Index {
        if (try declCount(s, m, top, n) != 1) return null;
        if (try s.assignedInTop(m, top, n)) return null;
        for (try s.preorder(m, top)) |node| {
            const t = m.ir.tag(node);
            if ((t == .const_decl or t == .let_decl) and m.ir.data(node).lhs == n.int()) {
                return (@as(Node.OptionalIndex, @fromBackingInt(@intCast(m.ir.data(node).rhs)))).unwrap();
            }
        }
        return null;
    }
    /// Put `stmts` where `place.stmt` stands in its list (they include it
    /// when `kept`).
    fn splice(s: *Spec, m: *Mod, place: Place, stmts: []const u32, kept: bool) Allocator.Error!void {
        _ = kept;
        const list = if (place.owner) |o| m.ir.extraSlice(.{ .start = @fromBackingInt(@intCast(m.extra.items[o])), .end = @fromBackingInt(@intCast(m.extra.items[o + 1])) }, u32) else m.ir.extraSlice(m.ir.body, u32);
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
        m.changed();
        if (place.owner) |o| {
            m.extra.items[o] = start;
            m.extra.items[o + 1] = end;
        } else m.ir.body = .{ .start = @fromBackingInt(@intCast(start)), .end = @fromBackingInt(@intCast(end)) };
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
        /// Across modules, the position of the call the copy replaces, in
        /// the destination's source: a position is an offset into ONE
        /// module's source, so the copy's nodes cannot keep theirs, and
        /// a release map sends them to the call (`backend.md` §11.2, item
        /// 2). Only a map reads a position.
        site: u32 = Node.no_pos,
        /// A declared name of the source, and its new name.
        renamed: []u32,
        /// A parameter of the source, and the argument (a node of the
        /// destination) each read of it is.
        subst: []Node.OptionalIndex,
        /// Slice 9 across a call: while a fused function's body is copied,
        /// what each of its `return`s becomes (`Spec.continuation`).
        cont: ?*const Cont = null,
        /// While the rest of a fused site's list is copied for one `return
        /// P`: its binding `x` is known to be `p`, a node of the module.
        known: ?Known = null,

        fn gpa(c: *Copy) Allocator {
            return c.s.gpa;
        }

        const Known = struct { x: NameIndex, p: Index, cont: *const Cont };

        /// A copy of a node of the destination, as it is.
        fn dupDst(c: *Copy, at: Index) Allocator.Error!Index {
            var d: Copy = .{ .s = c.s, .src = c.dst, .dst = c.dst, .cross = false, .renamed = &.{}, .subst = &.{} };
            return d.expr(at, 0);
        }

        /// The statements `from` is copied as, appended to `out`: one, but
        /// for a `return` of a fused body (the continuation) and, with `x`
        /// known, an `if` or a `switch` the knowledge decides (its chosen
        /// statements).
        fn stmtsInto(c: *Copy, from: Index, out: *std.ArrayList(u32), depth: u32) Allocator.Error!void {
            const ir = c.src.ir;
            const d = ir.data(from);
            if (c.cont) |cont| if (ir.tag(from) == .return_stmt) {
                const v = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs)))).unwrap().?;
                const p = try c.expr(v, depth + 1);
                return c.s.continuation(c.dst, cont, p, out, 0);
            };
            if (c.known != null) switch (ir.tag(from)) {
                // A block of the rest: its declarations are named afresh in
                // each copy, so its statements may stand in the list around it.
                .block_stmt => if (@as(NameIndex, @fromBackingInt(@intCast(d.lhs))) == .none) {
                    const inner = try c.s.arena.dupe(Index, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index));
                    for (inner) |st| try c.stmtsInto(st, out, depth + 1);
                    return;
                },
                .if_stmt => {
                    const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                    const t = try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1);
                    if (decidedTest(c.dst.ir, t)) |yes| {
                        const chosen = try c.s.arena.dupe(Index, ir.extraSlice(if (yes) b.thenBody() else b.elseBody(), Index));
                        for (chosen) |st| try c.stmtsInto(st, out, depth + 1);
                        return;
                    }
                    const then = try c.list(b.thenBody(), depth);
                    const els = try c.list(b.elseBody(), depth);
                    const rec = try c.dst.append(c.gpa(), &.{ @backingInt(then.start), @backingInt(then.end), @backingInt(els.start), @backingInt(els.end) });
                    try out.append(c.s.arena, (try c.node(from, .if_stmt, t.int(), rec)).int());
                    return;
                },
                .switch_stmt => {
                    const disc = try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1);
                    const cases = try c.s.arena.dupe(Index, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index));
                    var chosen: ?Index = null;
                    var undecided = false;
                    for (cases) |case| {
                        const t = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(case).lhs)))).unwrap() orelse continue;
                        // Case tests are literals of the destination module
                        // (a known copy reads its own module).
                        const eq = literalEq(c.dst.ir, disc, t) orelse {
                            undecided = true;
                            break;
                        };
                        if (eq) {
                            chosen = case;
                            break;
                        }
                    }
                    if (!undecided) {
                        if (chosen == null) for (cases) |case| {
                            if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(case).lhs))) == .none) chosen = case;
                        };
                        // A body a `break` may leave stays in its `switch`.
                        if (chosen) |case| {
                            const body = try c.s.arena.dupe(Index, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(case).rhs))), Index));
                            if (!holdsBreak(ir, body, 0)) {
                                for (body) |st| try c.stmtsInto(st, out, depth + 1);
                                return;
                            }
                        }
                    }
                    const copied = try c.list(ir.subRange(@fromBackingInt(@intCast(d.rhs))), depth);
                    try out.append(c.s.arena, (try c.node(from, .switch_stmt, disc.int(), try c.record(copied))).int());
                    return;
                },
                else => {},
            };
            try out.append(c.s.arena, (try c.stmt(from, depth)).int());
        }

        /// An expression copied with `x` known to be `kn.p`: a property read
        /// of it is what the value holds there, a comparison of it is
        /// decided when the value says, and a conditional, `&&` or `||` the
        /// copy decides is its chosen operand. Null: copied as it is.
        fn knownExpr(c: *Copy, from: Index, kn: Known, depth: u32) Allocator.Error!?Index {
            const ir = c.src.ir;
            const d = ir.data(from);
            switch (ir.tag(from)) {
                .ident => if (d.lhs == kn.x.int()) return try c.dupDst(kn.p),
                .member => {
                    const base = memberBase(ir, from) orelse return null;
                    if (ir.data(base).lhs != kn.x.int()) return null;
                    var keys: [64]NameIndex = undefined;
                    var len: usize = 0;
                    var n = from;
                    while (ir.tag(n) == .member) : (n = @fromBackingInt(@intCast(ir.data(n).lhs))) {
                        if (len == keys.len) return null;
                        keys[len] = @fromBackingInt(@intCast(ir.data(n).rhs));
                        len += 1;
                    }
                    // A declared object's tag is its literal's.
                    if (len == 1 and c.s.pts.propId(c.dst.index, keys[0]) == c.s.in.tag_prop) {
                        if (try c.s.declaredTag(c.dst, kn.p)) |lit| return lit;
                    }
                    var v = kn.p;
                    while (len > 0 and c.dst.ir.tag(v) == .object) {
                        v = propertyOf(c.dst.ir, v, keys[len - 1]) orelse return null;
                        len -= 1;
                    }
                    var e = try c.dupDst(v);
                    while (len > 0) {
                        len -= 1;
                        e = try c.dst.addNode(c.gpa(), .member, ir.pos(from), e.int(), keys[len].int());
                    }
                    return e;
                },
                .binary => {
                    const op: JsIr.BinaryOp = @fromBackingInt(@intCast(d.rhs));
                    const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                    switch (op) {
                        .strict_eq, .strict_ne => {
                            const left_x = ir.tag(b.left) == .ident and ir.data(b.left).lhs == kn.x.int();
                            const right_x = ir.tag(b.right) == .ident and ir.data(b.right).lhs == kn.x.int();
                            if (left_x == right_x) return null;
                            const other = if (left_x) b.right else b.left;
                            const p_ir = c.dst.ir;
                            const same: ?bool = if (p_ir.tag(kn.p) == .object and pureRead(ir, other))
                                false
                            else if ((primitiveLit(p_ir, kn.p) or try c.s.declaredTag(c.dst, kn.p) != null) and try c.s.stableChain(c.dst, kn.cont, other))
                                false
                            else if (sameChain(ir, other, kn.p) and try c.s.stableChain(c.dst, kn.cont, kn.p))
                                true
                            else
                                null;
                            const eq = same orelse return null;
                            return try c.dst.addNode(c.gpa(), if (eq == (op == .strict_eq)) .true_lit else .false_lit, ir.pos(from), 0, 0);
                        },
                        .logical_and, .logical_or => {
                            const l = try c.expr(b.left, depth + 1);
                            if (decidedTest(c.dst.ir, l)) |yes| {
                                // `false && r` and `true || r` are their left;
                                // otherwise the answer is `r`.
                                if (yes == (op == .logical_or)) return l;
                                return try c.expr(b.right, depth + 1);
                            }
                            const r = try c.expr(b.right, depth + 1);
                            return try c.node(from, .binary, try c.dst.append(c.gpa(), &.{ l.int(), r.int() }), d.rhs);
                        },
                        else => return null,
                    }
                },
                .cond => {
                    const cd = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                    const t = try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1);
                    if (decidedTest(c.dst.ir, t)) |yes| return try c.expr(if (yes) cd.consequent else cd.alternate, depth + 1);
                    const a = try c.expr(cd.consequent, depth + 1);
                    const e = try c.expr(cd.alternate, depth + 1);
                    return try c.node(from, .cond, t.int(), try c.dst.append(c.gpa(), &.{ a.int(), e.int() }));
                },
                else => return null,
            }
            return null;
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
            if (global) try c.s.addGlobal(c.dst, at);
            c.renamed[n] = at.int();
            // A local named afresh keeps its source name's key: a key is a
            // closed type, the same at every instantiation of the body it is
            // in (`backend.md` §9, *Declared-type filtering of fact 3*,
            // amended for #722).
            if (!global) {
                const k = c.src.ir.nameKey(@fromBackingInt(@intCast(n)));
                if (k != .wild) try c.dst.setNameKey(c.gpa(), at, k);
            }
            if (c.src.tables) |t| if (std.mem.indexOfScalar(NameIndex, t.mutable.items, @fromBackingInt(@intCast(n))) != null) {
                if (c.dst.tables) |dt| try dt.mutable.append(c.s.arena, at);
            };
        }

        /// A binding's name: the new one of a declared name, else itself.
        fn binding(c: *Copy, n: NameIndex) Allocator.Error!NameIndex {
            const i = n.unwrap() orelse return .none;
            if (i < c.renamed.len and c.renamed[i] != none) return @fromBackingInt(@intCast(c.renamed[i]));
            return c.property(n);
        }

        /// A property name: itself in its own module; in another, the
        /// destination's name of the same text (the session pools every
        /// plain name before the pass), added when it has none.
        fn property(c: *Copy, n: NameIndex) Allocator.Error!NameIndex {
            if (!c.cross or n == .none) return n;
            const name = c.src.ir.name(n);
            if (try c.dst.findName(c.s.arena, name)) |i| return i;
            return c.dst.addName(c.gpa(), name);
        }

        fn node(c: *Copy, from: Index, tag: Node.Tag, lhs: u32, rhs: u32) Allocator.Error!Index {
            const pos: u32 = if (c.cross) c.site else c.src.ir.pos(from);
            const to = try c.dst.addNode(c.gpa(), tag, pos, lhs, rhs);
            // An allocation copied as itself is still one of its type.
            if (tag == c.src.ir.tag(from)) switch (tag) {
                .object, .array, .arrow => {
                    const k = c.src.ir.nodeKey(from);
                    if (k != .wild) try c.dst.setNodeKey(c.gpa(), to, k);
                },
                else => {},
            };
            return to;
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
            for (try c.s.arena.dupe(Index, c.src.ir.extraSlice(range, Index))) |n| try c.stmtsInto(n, &out, depth + 1);
            const start = try c.dst.append(c.gpa(), out.items);
            return .{ .start = @fromBackingInt(@intCast(start)), .end = @fromBackingInt(@intCast(start + @as(u32, @intCast(out.items.len)))) };
        }

        /// A `SubRange` record of `extra`: its two words, appended.
        fn record(c: *Copy, r: JsIr.SubRange) Allocator.Error!u32 {
            return c.dst.append(c.gpa(), &.{ @backingInt(r.start), @backingInt(r.end) });
        }

        fn exprs(c: *Copy, items: []const Index, depth: u32) Allocator.Error!JsIr.SubRange {
            var out: std.ArrayList(u32) = .empty;
            for (try c.s.arena.dupe(Index, items)) |n| try out.append(c.s.arena, (try c.expr(n, depth + 1)).int());
            const start = try c.dst.append(c.gpa(), out.items);
            return .{ .start = @fromBackingInt(@intCast(start)), .end = @fromBackingInt(@intCast(start + @as(u32, @intCast(out.items.len)))) };
        }

        fn func(c: *Copy, record_at: ExtraIndex, depth: u32) Allocator.Error!u32 {
            const f = c.src.ir.extraData(record_at, JsIr.Func);
            var params: std.ArrayList(u32) = .empty;
            for (try c.s.arena.dupe(NameIndex, c.src.ir.extraSlice(f.params(), NameIndex))) |p| try params.append(c.s.arena, (try c.binding(p)).int());
            const pstart = try c.dst.append(c.gpa(), params.items);
            const pend = pstart + @as(u32, @intCast(params.items.len));
            const body = try c.list(f.body(), depth);
            return c.dst.append(c.gpa(), &.{ pstart, pend, @backingInt(body.start), @backingInt(body.end) });
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
            if (c.known) |kn| if (try c.knownExpr(from, kn, depth)) |e| return e;
            const ir = c.src.ir;
            const d = ir.data(from);
            const tag = ir.tag(from);
            switch (tag) {
                .ident => {
                    if (d.lhs < c.subst.len) if (c.subst[d.lhs].unwrap()) |a| return c.atom(a);
                    return c.node(from, .ident, (try c.binding(@fromBackingInt(@intCast(d.lhs)))).int(), 0);
                },
                .field_name => return c.node(from, tag, (try c.property(@fromBackingInt(@intCast(d.lhs)))).int(), 0),
                .number, .string, .template_chunk, .regex => return c.node(from, tag, try c.bytesOf(from), d.rhs),
                .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit => return c.node(from, tag, 0, 0),
                .template, .object, .array => {
                    const r = try c.exprs(ir.extraSlice(JsIr.inlineRange(d), Index), depth);
                    return c.node(from, tag, @backingInt(r.start), @backingInt(r.end));
                },
                .property => return c.node(from, .property, (try c.property(@fromBackingInt(@intCast(d.lhs)))).int(), (try c.expr(@fromBackingInt(@intCast(d.rhs)), depth + 1)).int()),
                .spread_property => return c.node(from, .spread_property, (try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1)).int(), 0),
                .call, .new_call => {
                    const callee = try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1);
                    const args = try c.exprs(ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index), depth);
                    return c.node(from, tag, callee.int(), try c.record(args));
                },
                .member => {
                    const key = try c.property(@fromBackingInt(@intCast(d.rhs)));
                    if (try c.projected(@fromBackingInt(@intCast(d.lhs)), key)) |v| return c.atom(v);
                    return c.node(from, .member, (try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1)).int(), key.int());
                },
                .index_get => {
                    const obj = try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1);
                    const key = try c.expr(@fromBackingInt(@intCast(d.rhs)), depth + 1);
                    return c.node(from, .index_get, obj.int(), key.int());
                },
                .arrow => {
                    const to = try c.node(from, .arrow, try c.func(@fromBackingInt(@intCast(d.lhs)), depth), d.rhs);
                    try c.listed(from, to, .unobserved);
                    return to;
                },
                .cond => {
                    const cd = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                    const t = try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1);
                    const a = try c.expr(cd.consequent, depth + 1);
                    const b = try c.expr(cd.alternate, depth + 1);
                    return c.node(from, .cond, t.int(), try c.dst.append(c.gpa(), &.{ a.int(), b.int() }));
                },
                .binary => {
                    const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                    const l = try c.expr(b.left, depth + 1);
                    const r = try c.expr(b.right, depth + 1);
                    return c.node(from, .binary, try c.dst.append(c.gpa(), &.{ l.int(), r.int() }), d.rhs);
                },
                .unary => return c.node(from, .unary, (try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1)).int(), d.rhs),
                // A store: its target copied as the read it names, never as a
                // value a fact gives the read (`projected`, `knownExpr`).
                .assign => {
                    const target: Index = @fromBackingInt(@intCast(d.lhs));
                    const key = try c.property(@fromBackingInt(@intCast(ir.data(target).rhs)));
                    const obj = try c.expr(@fromBackingInt(@intCast(ir.data(target).lhs)), depth + 1);
                    const t = try c.node(target, .member, obj.int(), key.int());
                    const v = try c.expr(@fromBackingInt(@intCast(d.rhs)), depth + 1);
                    return c.node(from, .assign, t.int(), v.int());
                },
                .sequence => {
                    const r = try c.exprs(ir.extraSlice(JsIr.inlineRange(d), Index), depth);
                    return c.node(from, tag, @backingInt(r.start), @backingInt(r.end));
                },
                else => return c.stmt(from, depth),
            }
        }

        /// `p.k`, `p` a parameter whose argument is an object literal that
        /// does nothing when made and holds `k` once among plain keys (by
        /// property id, as fact 3 numbers them): the value of `k`, written
        /// in place of the read. The literal goes with its other values,
        /// which do nothing. Nothing can see the object between its making
        /// and the read, so the read is that value; a key it lacks is left
        /// alone, since it reads the prototype (`backend.md` §9, *Slice 8*,
        /// amended 2026-10-22).
        fn projected(c: *Copy, object: Index, key: NameIndex) Allocator.Error!?Index {
            const ir = c.src.ir;
            if (ir.tag(object) != .ident) return null;
            const n = ir.data(object).lhs;
            if (n >= c.subst.len) return null;
            const arg = c.subst[n].unwrap() orelse return null;
            const dir = c.dst.ir;
            if (dir.tag(arg) != .object or !inert(dir, arg)) return null;
            const want = c.s.pts.propId(c.dst.index, key);
            if (want == none) return null;
            var found: ?Index = null;
            for (dir.extraSlice(JsIr.inlineRange(dir.data(arg)), Index)) |prop| {
                if (dir.tag(prop) != .property) return null;
                if (c.s.pts.propId(c.dst.index, @fromBackingInt(@intCast(dir.data(prop).lhs))) != want) continue;
                if (found != null) return null;
                found = @fromBackingInt(@intCast(dir.data(prop).rhs));
            }
            return found;
        }

        fn optional(c: *Copy, v: u32, depth: u32) Allocator.Error!u32 {
            const o: Node.OptionalIndex = @fromBackingInt(@intCast(v));
            const n = o.unwrap() orelse return v;
            return (try c.expr(n, depth + 1)).int();
        }

        fn stmt(c: *Copy, from: Index, depth: u32) Allocator.Error!Index {
            const ir = c.src.ir;
            const d = ir.data(from);
            const tag = ir.tag(from);
            switch (tag) {
                .const_decl => {
                    const to = try c.node(from, .const_decl, (try c.binding(@fromBackingInt(@intCast(d.lhs)))).int(), (try c.expr(@fromBackingInt(@intCast(d.rhs)), depth + 1)).int());
                    try c.listed(from, to, .keep);
                    return to;
                },
                .let_decl => {
                    const to = try c.node(from, .let_decl, (try c.binding(@fromBackingInt(@intCast(d.lhs)))).int(), try c.optional(d.rhs, depth));
                    try c.listed(from, to, .keep);
                    return to;
                },
                .func_decl, .gen_decl => {
                    const to = try c.node(from, tag, (try c.binding(@fromBackingInt(@intCast(d.lhs)))).int(), try c.func(@fromBackingInt(@intCast(d.rhs)), depth));
                    try c.listed(from, to, .unobserved);
                    return to;
                },
                .assign_stmt => {
                    const target = try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1);
                    return c.node(from, .assign_stmt, target.int(), (try c.expr(@fromBackingInt(@intCast(d.rhs)), depth + 1)).int());
                },
                .return_stmt => return c.node(from, .return_stmt, try c.optional(d.lhs, depth), 0),
                .if_stmt => {
                    const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                    const t = try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1);
                    const then = try c.list(b.thenBody(), depth);
                    const els = try c.list(b.elseBody(), depth);
                    const rec = try c.dst.append(c.gpa(), &.{ @backingInt(then.start), @backingInt(then.end), @backingInt(els.start), @backingInt(els.end) });
                    return c.node(from, .if_stmt, t.int(), rec);
                },
                .while_true, .block_stmt => {
                    const body = try c.list(ir.subRange(@fromBackingInt(@intCast(d.rhs))), depth);
                    return c.node(from, tag, (try c.binding(@fromBackingInt(@intCast(d.lhs)))).int(), try c.record(body));
                },
                .for_of => {
                    const loop = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                    const iterable = try c.expr(loop.iterable, depth + 1);
                    const body = try c.list(loop.body(), depth);
                    const rec = try c.dst.append(c.gpa(), &.{ iterable.int(), @backingInt(body.start), @backingInt(body.end) });
                    return c.node(from, .for_of, (try c.binding(@fromBackingInt(@intCast(d.lhs)))).int(), rec);
                },
                .break_stmt, .continue_stmt => return c.node(from, tag, (try c.binding(@fromBackingInt(@intCast(d.lhs)))).int(), 0),
                .switch_stmt => {
                    const disc = try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1);
                    const cases = try c.list(ir.subRange(@fromBackingInt(@intCast(d.rhs))), depth);
                    return c.node(from, .switch_stmt, disc.int(), try c.record(cases));
                },
                .switch_case => {
                    const t = try c.optional(d.lhs, depth);
                    const body = try c.list(ir.subRange(@fromBackingInt(@intCast(d.rhs))), depth);
                    return c.node(from, .switch_case, t, try c.record(body));
                },
                .expr_stmt => {
                    const to = try c.node(from, .expr_stmt, (try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1)).int(), 0);
                    try c.listed(from, to, .discards);
                    return to;
                },
                .throw_stmt => return c.node(from, .throw_stmt, (try c.expr(@fromBackingInt(@intCast(d.lhs)), depth + 1)).int(), 0),
                .try_stmt => {
                    const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                    const body = try c.list(t.body(), depth);
                    const final = try c.list(t.finalBody(), depth);
                    const name = try c.binding(t.catch_name);
                    const caught = try c.list(t.catchBody(), depth);
                    const rec = try c.dst.append(c.gpa(), &.{ @backingInt(body.start), @backingInt(body.end), @backingInt(final.start), @backingInt(final.end), @backingInt(caught.start), @backingInt(caught.end), @backingInt(name) });
                    return c.node(from, .try_stmt, 0, rec);
                },
                // `scanBody` refused a body holding one.
                .import_stmt, .export_stmt => unreachable,
                else => return c.expr(from, depth),
            }
        }
    };
};

/// The most cases besides `default` a `switch` written as `if`s has
/// (`switchAsIfs`).
const max_switch_ifs = 3;

/// What one pass of slice 5 (`inlineOnce`) or of slice 9 across a call
/// (`fuseCalls`) may grow the program by, in nodes: `copy_budget` times the
/// program the pass began with, or `min_copy_budget` for a small one
/// (`Spec.copyLimit`). A bound on work, never reached by the corpus or the
/// dashboard: reaching it is counted (`Stats.inline_capped`).
const copy_budget = 4;
const min_copy_budget = 1 << 16;
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
        .number, .string, .regex, .true_lit, .false_lit, .null_lit, .undefined_lit, .template_chunk, .global_this, .this_lit => return .clean,
        .member => return seq(&.{firstUse(ir, @fromBackingInt(@intCast(d.lhs)), p, depth + 1)}, true),
        .index_get => return seq(&.{ firstUse(ir, @fromBackingInt(@intCast(d.lhs)), p, depth + 1), firstUse(ir, @fromBackingInt(@intCast(d.rhs)), p, depth + 1) }, true),
        .unary => {
            const op: JsIr.UnaryOp = @fromBackingInt(@intCast(d.rhs));
            return seq(&.{firstUse(ir, @fromBackingInt(@intCast(d.lhs)), p, depth + 1)}, op != .not and op != .type_of);
        },
        .binary => {
            const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
            const op: JsIr.BinaryOp = @fromBackingInt(@intCast(d.rhs));
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
            const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
            const t = firstUse(ir, @fromBackingInt(@intCast(d.lhs)), p, depth + 1);
            const a = firstUse(ir, c.consequent, p, depth + 1);
            const e = firstUse(ir, c.alternate, p, depth + 1);
            if (a == .found or a == .fail or e == .found or e == .fail) return if (t == .found) .found else .fail;
            return seq(&.{ t, a, e }, false);
        },
        .call, .new_call => {
            var parts: [17]Use = undefined;
            const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index);
            if (args.len > 16) return .fail;
            parts[0] = firstUse(ir, @fromBackingInt(@intCast(d.lhs)), p, depth + 1);
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
        .property => return firstUse(ir, @fromBackingInt(@intCast(d.rhs)), p, depth + 1),
        .spread_property => return seq(&.{firstUse(ir, @fromBackingInt(@intCast(d.lhs)), p, depth + 1)}, true),
        // The target's object, the value, then the store, which acts.
        .assign => {
            const target: Index = @fromBackingInt(@intCast(d.lhs));
            return seq(&.{ firstUse(ir, @fromBackingInt(@intCast(ir.data(target).lhs)), p, depth + 1), firstUse(ir, @fromBackingInt(@intCast(d.rhs)), p, depth + 1) }, true);
        },
        .sequence => {
            var parts: [16]Use = undefined;
            const items = ir.extraSlice(JsIr.inlineRange(d), Index);
            if (items.len > 16) return .fail;
            for (items, 0..) |item, i| parts[i] = firstUse(ir, item, p, depth + 1);
            return seq(parts[0..items.len], false);
        },
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
                const id = pts.propId(mi, @fromBackingInt(@intCast(d.rhs)));
                break :blk 1 + if (id < pts.s.in.prop_len.len) @as(u32, pts.s.in.prop_len[id]) else 5;
            },
            .index_get, .call, .new_call, .object, .array, .template, .sequence => blk: {
                const items: usize = switch (ir.tag(node)) {
                    .call, .new_call => ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index).len,
                    .index_get => 1,
                    else => ir.extraSlice(JsIr.inlineRange(d), Index).len,
                };
                break :blk 2 + @as(u32, @intCast(if (items > 0) items - 1 else 0));
            },
            .binary => @intCast(JsIr.BinaryOp.text(@fromBackingInt(@intCast(d.rhs))).len),
            .unary => 1,
            .cond => 2,
            .property => 6,
            .assign => 1,
            else => 4,
        };
        if (count > 4096) return count;
        var children: [16]Index = undefined;
        var n: usize = 0;
        switch (ir.tag(node)) {
            .member, .unary, .spread_property => {
                children[0] = @fromBackingInt(@intCast(d.lhs));
                n = 1;
            },
            .property => {
                children[0] = @fromBackingInt(@intCast(d.rhs));
                n = 1;
            },
            .index_get => {
                children[0] = @fromBackingInt(@intCast(d.lhs));
                children[1] = @fromBackingInt(@intCast(d.rhs));
                n = 2;
            },
            .binary => {
                const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                children[0] = b.left;
                children[1] = b.right;
                n = 2;
            },
            .cond => {
                const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                children[0] = @fromBackingInt(@intCast(d.lhs));
                children[1] = c.consequent;
                children[2] = c.alternate;
                n = 3;
            },
            .call, .new_call => {
                const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index);
                if (args.len > 15) return 4096;
                children[0] = @fromBackingInt(@intCast(d.lhs));
                for (args, 1..) |a, i| children[i] = a;
                n = args.len + 1;
            },
            .assign => {
                children[0] = @fromBackingInt(@intCast(d.lhs));
                children[1] = @fromBackingInt(@intCast(d.rhs));
                n = 2;
            },
            .object, .array, .template, .sequence => {
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

/// A set of tags as a table indexed by tag: a test of one is a load, where a
/// `switch` with an `else` prong first checks, tag by tag, that its operand
/// is one in Zig's own backend — the hottest walks here make that test a
/// million times over a page.
fn TagSet(comptime tags: []const Node.Tag) [@typeInfo(Node.Tag).@"enum".field_names.len]bool {
    var set: [@typeInfo(Node.Tag).@"enum".field_names.len]bool = @splat(false);
    for (tags) |t| set[@backingInt(t)] = true;
    return set;
}

/// The markers of an arm on the extraction's expression stack (`Extractor.expr`):
/// it begins (the node whose arm it is, and whether it is the alternate),
/// or it ends.
const mark_exit: u32 = 1 << 28;
const mark_enter: u32 = 1 << 30;
const mark_alt: u32 = 1 << 29;
const mark_node: u32 = mark_exit - 1;

/// The leaves the evaluating walks (`Spec.eval`, `Pts.expr`) take without
/// their stack.
const value_leaves = TagSet(&.{ .field_name, .ident, .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit, .template_chunk });

inline fn isValueLeaf(t: Node.Tag) bool {
    return value_leaves[@backingInt(t)];
}

/// The leaves `Spec.patchStmt` has nothing to patch in.
const patch_leaves = TagSet(&.{ .field_name, .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit, .template_chunk, .global_this, .this_lit });

/// The leaves `Spec.countExpr` has nothing to count in: none is a name.
const count_leaves = TagSet(&.{ .field_name, .number, .string, .template_chunk, .regex, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit });

/// Whether a node of `tag` is a literal, as `Spec.literalValue` reads one.
fn isLiteralTag(tag: Node.Tag) bool {
    return switch (tag) {
        .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => true,
        else => false,
    };
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

/// Names the host reads with no member expression in the program
/// (`backend.md` §9, fact 3). `valueOf` and `toString` are what
/// `ToPrimitive` reads. `toJSON` is what `JSON.stringify` reads. A
/// well-known symbol is not a string name, so it is not here.
/// `keyUnread` keeps a key it cannot name. Both drop predicates refuse
/// an id in `Input.implicit_props`.
pub const implicit_host_keys = [_][]const u8{
    "toJSON", "toString", "valueOf",
};

/// The name whose assignment sets `[[Prototype]]` rather than storing an
/// own data property (`backend.md` §9, fact 3). A host read is a different
/// fact, so this name is not in `implicit_host_keys`.
pub const prototype_assign = "__proto__";

test "implicit_host_keys names toJSON, toString and valueOf" {
    try testing.expectEqual(@as(usize, 3), implicit_host_keys.len);
    try testing.expectEqualStrings("toJSON", implicit_host_keys[0]);
    try testing.expectEqualStrings("toString", implicit_host_keys[1]);
    try testing.expectEqualStrings("valueOf", implicit_host_keys[2]);
}

test "prototype_assign is __proto__ and not a host read" {
    try testing.expectEqualStrings("__proto__", prototype_assign);
    var on_prototype = false;
    for (prototype_names) |n| on_prototype = on_prototype or std.mem.eql(u8, n, prototype_assign);
    try testing.expect(on_prototype);
    for (implicit_host_keys) |n| try testing.expect(!std.mem.eql(u8, n, prototype_assign));
}

/// The names `Object.prototype` has: an object literal that holds none of
/// these still has one to read (`Input.builtin_props`).
pub const prototype_names = [_][]const u8{
    "constructor",      "hasOwnProperty",   "isPrototypeOf",    "propertyIsEnumerable",
    "toLocaleString",   "toString",         "valueOf",          "__proto__",
    "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__",
};

/// The memory of one fact-3 run (`Pts.tmp`, `backend.md` §9, *The combined
/// solver — Memory*): one arena for everything of the run but its hot
/// columns, and one arena for each of those, the lists that grow with the
/// program as the run makes vars, sites, edges, dependencies, summaries
/// and shared fields' consumers (#606). A column is its arena's only
/// allocation, so it grows in place (`Arena.initColumn`) and leaves no old
/// copy behind for the pages it faulted in. It is reset, swapped and
/// freed as one.
const RunArena = struct {
    main: Arena,
    columns: [column_count]Arena,

    const Column = enum { vars, links_of, cold, sites, edges, deps, summaries, field_outs };
    const column_count = std.enums.values(Column).len;

    fn init(backing: Allocator) RunArena {
        var r: RunArena = .{ .main = .init(backing), .columns = undefined };
        for (&r.columns) |*c| c.* = .initColumn(backing);
        return r;
    }

    fn deinit(r: *RunArena) void {
        r.main.deinit();
        for (&r.columns) |*c| c.deinit();
    }

    fn reset(r: *RunArena, mode: Arena.ResetMode) void {
        r.main.reset(mode);
        for (&r.columns) |*c| c.reset(mode);
    }

    /// Everything of the run but a column.
    fn allocator(r: *RunArena) Allocator {
        return r.main.allocator();
    }

    /// Column `c`'s arena: for that list and nothing else.
    fn column(r: *RunArena, c: Column) Allocator {
        return r.columns[@backingInt(c)].allocator();
    }
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
///
/// **Values flow along copy edges by their difference** (`backend.md` §9,
/// *The combined solver*, its `copy`, `spread` and `load`; *As built
/// 2026-10-19*). A binding, an argument or a `return` whose value is a name
/// no guard narrows is a copy edge between the two vars (`copy`): what joins
/// the source later joins the target as it arrives, one batch of new sites
/// at a time (`joinNow`), on a worklist and never by recursion. A spread of
/// a name copies through the var's **field summary** (`Summary`): one var
/// per property, the join of that property over every site the var holds,
/// fed by copy edges from the sites' own property vars and, for a var that
/// is a copy of another, by the other's summary — a summary is a
/// homomorphism of the union, Σ(A ∪ B) = Σ(A) ∪ Σ(B) — so every record
/// update of one record shares one summary, and a value reaching a field
/// flows to every spread along the edges without the spread being evaluated
/// again. A member read is a **load cell** (`Load`): its own var, fed by one
/// copy edge from the property's var of each site, shared by every read of
/// one property of one var; a change of a site's property flows to the read
/// along the edge, and a site's escape reaches the cells that read it
/// through the site's list of them. The facts are the same least fixpoint
/// the per-site joins reached: every edge only carries what the join
/// carried, sooner.
/// One extraction (`backend.md` §9, *The combined solver — Extraction*):
/// one walk of a module's `JsIr` that does what a sweep's walk of it does
/// (`Spec.walkTop`: `count`, then `evalStmt`) and, in place of each
/// evaluation, emits the constraint it would evaluate. It reads the module's
/// IR and its `global` column and nothing else, and writes only its own
/// columns, so modules extract on workers at once. `scratch` holds what one
/// extraction needs; the result is in the `Extract`'s own arena.
const Extractor = struct {
    scratch: Allocator,
    ir: *const JsIr,
    global: []const u32,
    /// How many names a walk counts (`Mod.stamp.len`): a name past it is
    /// one no walk counts, read as ⊤.
    names: usize,
    nodes: u32,
    /// `Spec.touch`'s columns, per name, valid when `stamp` is `cur`.
    stamp: []u32,
    cur: u32 = 0,
    decls: []u32,
    uses: []u32,
    assigned: []bool,
    /// The parameter position of the statement's own function (`Spec.param`).
    pos: []u32,
    /// The cell of the value a local was declared with, as `Spec.value`
    /// holds the value: `none` while it is ⊤.
    src: []u32,
    /// Per node: met already, and the cell of its last occurrence — what
    /// `Mod.memo` holds of it at that point of the walk.
    seen: std.DynamicBitSetUnmanaged,
    cell: []u32,
    narrow: std.ArrayList(NameIndex) = .empty,
    /// Per name, how many entries of `narrow` it has: whether a read of it
    /// is past a guard, without a search.
    guards: []u32,
    stack: std.ArrayList(Index) = .empty,
    work: std.ArrayList(Index) = .empty,
    disjuncts: std.ArrayList(Index) = .empty,
    cur_fn: u32 = none,
    ordinal: u32 = 0,
    param_reads: bool = false,
    code: std.ArrayList(Code) = .empty,
    node: std.ArrayList(u32) = .empty,
    a: std.ArrayList(u32) = .empty,
    pool: std.ArrayList(u32) = .empty,
    over: std.ArrayList(u32) = .empty,
    stmts: std.ArrayList(ExStmt) = .empty,
    reads: std.ArrayList(GRead) = .empty,
    assigns: std.ArrayList(u32) = .empty,
    /// The exec cell the walk is in, the cells, each constraint's, and the
    /// cells an arm the expression walk is in was entered from.
    cur_exec: u32 = 0,
    execs: std.ArrayList(ExecCell) = .empty,
    exec: std.ArrayList(u32) = .empty,
    exec_saved: std.ArrayList(u32) = .empty,

    /// Extract module `m` into `into`, which it replaces. A statement whose
    /// nodes are what they were when `into` took its constraints
    /// (`Mod.keptNodes`) keeps them, unless `fresh`; so does no statement
    /// when the names a walk counts changed.
    fn run(scratch: Allocator, m: *const Mod, fresh: bool, into: *Extract) Allocator.Error!void {
        const ir = m.ir;
        const global = m.global;
        const names = m.stamp.len;
        const epoch = m.epoch;
        const nodes: u32 = @intCast(ir.nodes.len);
        var x: Extractor = .{
            .scratch = scratch,
            .ir = ir,
            .global = global,
            .names = names,
            .nodes = nodes,
            .stamp = try scratch.alloc(u32, names),
            .decls = try scratch.alloc(u32, names),
            .uses = try scratch.alloc(u32, names),
            .assigned = try scratch.alloc(bool, names),
            .pos = try scratch.alloc(u32, names),
            .src = try scratch.alloc(u32, names),
            .guards = try scratch.alloc(u32, names),
            .seen = try .initEmpty(scratch, nodes),
            .cell = try scratch.alloc(u32, nodes),
        };
        @memset(x.stamp, 0);
        @memset(x.guards, 0);
        const body = ir.extraSlice(ir.body, Index);
        // The last extraction's statements, by node.
        var old: KeyMap(struct { node: u32 }, u32) = .empty;
        if (!fresh and into.names == names) for (into.stmts, 0..) |st, k| try old.put(scratch, .{ .node = st.node.int() }, @intCast(k));
        var walked: u32 = 0;
        var reused: u32 = 0;
        // Exec cell 0: the module, which no constraint names; then each
        // statement's own, which runs while the statement is live.
        try x.execs.append(scratch, .{ .kind = .top });
        for (body, 0..) |top, i| {
            x.ordinal = @intCast(i);
            x.cur_exec = 0;
            const before = old.get(.{ .node = top.int() });
            if (before) |k| if (m.keptNodes(top, into.stmts[k].epoch)) if (try x.reuse(into, k)) {
                reused += 1;
                continue;
            };
            walked += 1;
            try x.execs.append(scratch, .{ .kind = .top });
            x.cur_exec = @intCast(x.execs.items.len - 1);
            try x.prepare(top);
            try x.stmtOf(top);
            try x.stmts.append(scratch, .{
                .node = top,
                .cons = @intCast(x.code.items.len),
                .pool = @intCast(x.pool.items.len),
                .over = @intCast(x.over.items.len),
                .reads = @intCast(x.reads.items.len),
                .assigns = @intCast(x.assigns.items.len),
                .execs = @intCast(x.execs.items.len),
                .epoch = epoch,
                .param_reads = x.param_reads,
            });
        }
        into.walked = walked;
        into.reused = reused;
        // What the last extraction made is no longer read: its arena holds
        // this one's columns, each written into its field, so that the
        // arena itself is never copied.
        into.arena.reset(.retain_capacity);
        const keep = into.arena.allocator();
        into.epoch = epoch;
        into.names = names;
        into.nodes = nodes;
        into.code = try keep.dupe(Code, x.code.items);
        into.node = try keep.dupe(u32, x.node.items);
        into.a = try keep.dupe(u32, x.a.items);
        into.pool = try keep.dupe(u32, x.pool.items);
        into.over = try keep.dupe(u32, x.over.items);
        into.stmts = try keep.dupe(ExStmt, x.stmts.items);
        into.reads = try keep.dupe(GRead, x.reads.items);
        into.assigns = try keep.dupe(u32, x.assigns.items);
        into.exec = try keep.dupe(u32, x.exec.items);
        into.execs = try keep.dupe(ExecCell, x.execs.items);
        // Per exec cell the constraints it gates and the arms below it, and
        // per node cell the arms its value decides, by counting sort.
        const n_exec = into.execs.len;
        into.ec_off, into.ec = try csr(keep, scratch, n_exec, into.exec, null);
        const parents = try scratch.alloc(u32, n_exec);
        const tests = try scratch.alloc(u32, n_exec);
        for (into.execs, parents, tests) |e, *p, *t| {
            p.* = if (e.kind == .top or e.kind == .body) none else e.parent;
            t.* = if (e.kind == .top or e.kind == .body) none else e.a;
        }
        into.ek_off, into.ek = try csr(keep, scratch, n_exec, parents, null);
        into.et_off, into.et = try csr(keep, scratch, into.cells(), tests, null);
        // The readers index, by counting sort over the cells.
        const cells = into.cells();
        const off = try keep.alloc(u32, cells + 1);
        @memset(off, 0);
        for (0..into.code.len) |j| eachRead(into, j, Count{ .off = off });
        for (1..off.len) |i| off[i] += off[i - 1];
        const rd = try keep.alloc(u32, off[cells]);
        const fill = try scratch.dupe(u32, off[0..cells]);
        for (0..into.code.len) |j| eachRead(into, j, Fill{ .fill = fill, .rd = rd, .con = @intCast(j) });
        into.rd_off = off;
        into.rd = rd;
    }

    /// The index of `keys` (`none` skipped): per key in `0..n`, the places
    /// that have it, `x[off[k]..off[k + 1]]`, in order.
    fn csr(keep: Allocator, scratch: Allocator, n: usize, keys: []const u32, _: ?void) Allocator.Error!struct { []u32, []u32 } {
        const off = try keep.alloc(u32, n + 1);
        @memset(off, 0);
        for (keys) |k| if (k != none) {
            off[k + 1] += 1;
        };
        for (1..off.len) |i| off[i] += off[i - 1];
        const out = try keep.alloc(u32, off[n]);
        const fill = try scratch.dupe(u32, off[0..n]);
        for (keys, 0..) |k, i| if (k != none) {
            out[fill[k]] = @intCast(i);
            fill[k] += 1;
        };
        return .{ off, out };
    }

    const Count = struct {
        off: []u32,
        fn see(c: Count, cell: u32) void {
            c.off[cell + 1] += 1;
        }
    };

    const Fill = struct {
        fill: []u32,
        rd: []u32,
        con: u32,
        fn see(f: Fill, cell: u32) void {
            f.rd[f.fill[cell]] = f.con;
            f.fill[cell] += 1;
        }
    };

    /// Calls `f.see(cell)` for every cell of the module constraint `j`
    /// reads; a parameter's is the merge's (`Solver.prd`), and a field's
    /// and a return's are registered as they are read (`Solver.reads`).
    fn eachRead(x: *const Extract, j: usize, f: anytype) void {
        const a = x.a[j];
        switch (x.code[j].op) {
            .constant, .literal, .global, .param => {},
            .member => if (a != none) f.see(a),
            .local, .ret => if (a != none) f.see(a),
            .effect => f.see(a),
            .unary, .store => f.see(a),
            .binary => {
                f.see(x.pool[a]);
                f.see(x.pool[a + 1]);
            },
            .cond => for (x.pool[a..][0..5]) |c| if (c != none) f.see(c),
            .call => for (x.pool[a + 2 ..][0..x.pool[a + 1]]) |c| f.see(c),
            .template => for (x.pool[a + 1 ..][0..x.pool[a]]) |c| f.see(c),
            .object => for (0..x.pool[a]) |k| f.see(x.pool[a + 2 + 2 * k]),
        }
    }

    /// Statement `k` of `from`, the last extraction, taken as it was: its
    /// constraints, renumbered into this one. Not taken when it has a
    /// repeated node, whose cell is numbered across the module, or one
    /// that another statement of this extraction met first.
    fn reuse(x: *Extractor, from: *const Extract, k: u32) Allocator.Error!bool {
        const st = from.stmts[k];
        const prev: ExStmt = if (k == 0) .{ .node = st.node, .cons = 0, .pool = 0, .over = 0, .reads = 0, .assigns = 0, .execs = 1, .epoch = 0, .param_reads = false } else from.stmts[k - 1];
        if (st.over != prev.over) return false;
        for (from.code[prev.cons..st.cons], from.node[prev.cons..st.cons]) |code, node| {
            if (code.ofNode() and x.seen.isSet(node)) return false;
        }
        for (from.code[prev.cons..st.cons], from.node[prev.cons..st.cons]) |code, node| {
            if (code.ofNode()) {
                x.seen.set(node);
                x.cell[node] = node;
            }
        }
        const s = x.scratch;
        const pool_delta: u32 = @intCast(x.pool.items.len);
        // Its exec cells, renumbered as they are copied; the top level's is
        // every module's first.
        const exec_from = if (k == 0) 1 else prev.execs;
        const exec_at: u32 = @intCast(x.execs.items.len);
        const shift = struct {
            fn id(e: u32, lo: u32, at: u32) u32 {
                return if (e == 0 or e == none) e else e - lo + at;
            }
        }.id;
        for (from.execs[exec_from..st.execs]) |e| try x.execs.append(s, .{ .kind = e.kind, .parent = shift(e.parent, exec_from, exec_at), .a = e.a });
        for (prev.cons..st.cons) |j| try x.exec.append(s, shift(from.exec[j], exec_from, exec_at));
        for (prev.cons..st.cons) |j| {
            const code = from.code[j];
            const a = switch (code.op) {
                .binary, .cond, .call, .template, .object => from.a[j] - prev.pool + pool_delta,
                else => from.a[j],
            };
            try x.code.append(s, code);
            try x.node.append(s, from.node[j]);
            try x.a.append(s, a);
        }
        try x.pool.appendSlice(s, from.pool[prev.pool..st.pool]);
        try x.reads.appendSlice(s, from.reads[prev.reads..st.reads]);
        try x.assigns.appendSlice(s, from.assigns[prev.assigns..st.assigns]);
        try x.stmts.append(s, .{
            .node = st.node,
            .cons = @intCast(x.code.items.len),
            .pool = @intCast(x.pool.items.len),
            .over = @intCast(x.over.items.len),
            .reads = @intCast(x.reads.items.len),
            .assigns = @intCast(x.assigns.items.len),
            .execs = @intCast(x.execs.items.len),
            .epoch = st.epoch,
            .param_reads = st.param_reads,
        });
        return true;
    }

    inline fn globalOf(x: *const Extractor, n: NameIndex) ?u32 {
        const i = n.unwrap() orelse return null;
        if (i >= x.global.len) return null;
        const g = x.global[i];
        return if (g == none) null else g;
    }

    /// A constraint: `node` a node's cell, or the statement's node for
    /// `store` and `ret`.
    fn emit(x: *Extractor, op: Op, node: u32, a: u32, flag: bool) Allocator.Error!void {
        const s = x.scratch;
        try x.code.append(s, .{ .op = op, .flag = flag });
        try x.node.append(s, node);
        try x.a.append(s, a);
        try x.exec.append(s, x.cur_exec);
    }

    /// A new exec cell below the one the walk is in, which the walk then is
    /// in; the cell it was in is given back.
    fn enter(x: *Extractor, kind: ExecCell.ExecKind, a: u32) Allocator.Error!u32 {
        const saved = x.cur_exec;
        try x.execs.append(x.scratch, .{ .kind = kind, .parent = if (kind == .body) none else saved, .a = a });
        x.cur_exec = @intCast(x.execs.items.len - 1);
        return saved;
    }

    /// The cell of a new occurrence of `node`.
    fn occur(x: *Extractor, node: Index) Allocator.Error!u32 {
        const n = node.int();
        const c: u32 = if (!x.seen.isSet(n)) first: {
            x.seen.set(n);
            break :first n;
        } else again: {
            const c = x.nodes + @as(u32, @intCast(x.over.items.len));
            try x.over.append(x.scratch, n);
            break :again c;
        };
        x.cell[n] = c;
        return c;
    }

    // ---- `Spec.prepareTop`'s count -------------------------------------------

    fn prepare(x: *Extractor, top: Index) Allocator.Error!void {
        const ir = x.ir;
        x.cur += 1;
        x.param_reads = false;
        try x.count(top);
        // The statement's own function, whose parameters `Spec` tracks
        // when the declaration is the one its name has (the merge says).
        const record: ?ExtraIndex = switch (ir.tag(top)) {
            .const_decl => rec: {
                if (x.globalOf(@fromBackingInt(@intCast(ir.data(top).lhs))) == null) break :rec null;
                const rhs: Index = @fromBackingInt(@intCast(ir.data(top).rhs));
                if (ir.tag(rhs) != .arrow or ir.data(rhs).rhs != Node.arrow_plain) break :rec null;
                break :rec @fromBackingInt(@intCast(ir.data(rhs).lhs));
            },
            .func_decl => if (x.globalOf(@fromBackingInt(@intCast(ir.data(top).lhs))) != null) @fromBackingInt(@intCast(ir.data(top).rhs)) else null,
            else => null,
        };
        if (record) |r| {
            const f = ir.extraData(r, JsIr.Func);
            for (ir.extraSlice(f.params(), NameIndex), 0..) |n, i| {
                const at = n.unwrap() orelse continue;
                if (at < x.names and x.stamp[at] == x.cur and x.decls[at] == 1) x.pos[at] = @intCast(i);
            }
        }
    }

    fn touch(x: *Extractor, i: u32) void {
        if (x.stamp[i] == x.cur) return;
        x.stamp[i] = x.cur;
        x.decls[i] = 0;
        x.uses[i] = 0;
        x.assigned[i] = false;
        x.pos[i] = none;
        x.src[i] = none;
    }

    fn declare(x: *Extractor, n: NameIndex) void {
        const i = n.unwrap() orelse return;
        if (i >= x.names) return;
        x.touch(i);
        x.decls[i] += 1;
    }

    fn read(x: *Extractor, n: NameIndex, callee: bool) Allocator.Error!void {
        if (x.globalOf(n)) |g| {
            try x.reads.append(x.scratch, .{ .g = g, .callee = callee });
            return;
        }
        const i = n.unwrap() orelse return;
        if (i >= x.names) return;
        x.touch(i);
        x.uses[i] += 1;
    }

    /// `Spec.count`, statement for statement.
    fn count(x: *Extractor, stmt: Index) Allocator.Error!void {
        const ir = x.ir;
        const d = ir.data(stmt);
        switch (ir.tag(stmt)) {
            .import_stmt, .export_stmt => {},
            .const_decl => {
                x.declare(@fromBackingInt(@intCast(d.lhs)));
                try x.countExpr(@fromBackingInt(@intCast(d.rhs)));
            },
            .let_decl => {
                x.declare(@fromBackingInt(@intCast(d.lhs)));
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| try x.countExpr(v);
            },
            .func_decl, .gen_decl => {
                x.declare(@fromBackingInt(@intCast(d.lhs)));
                try x.countFunc(@fromBackingInt(@intCast(d.rhs)));
            },
            .assign_stmt => {
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                if (ir.tag(target) == .ident) {
                    const n: NameIndex = @fromBackingInt(@intCast(ir.data(target).lhs));
                    if (x.globalOf(n)) |g| {
                        try x.assigns.append(x.scratch, g);
                    } else if (n.unwrap()) |i| if (i < x.names) {
                        x.touch(i);
                        x.assigned[i] = true;
                    };
                } else try x.countExpr(target);
                try x.countExpr(@fromBackingInt(@intCast(d.rhs)));
            },
            .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try x.countExpr(v),
            .if_stmt => {
                try x.countExpr(@fromBackingInt(@intCast(d.lhs)));
                const branches = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                try x.countList(branches.thenBody());
                try x.countList(branches.elseBody());
            },
            .while_true, .block_stmt => {
                x.declare(@fromBackingInt(@intCast(d.lhs)));
                try x.countList(ir.subRange(@fromBackingInt(@intCast(d.rhs))));
            },
            .for_of => {
                const f = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                x.declare(@fromBackingInt(@intCast(d.lhs)));
                try x.countExpr(f.iterable);
                try x.countList(f.body());
            },
            .break_stmt, .continue_stmt => {},
            .switch_stmt => {
                try x.countExpr(@fromBackingInt(@intCast(d.lhs)));
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |c| try x.count(c);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| try x.countExpr(t);
                try x.countList(ir.subRange(@fromBackingInt(@intCast(d.rhs))));
            },
            .expr_stmt, .throw_stmt => try x.countExpr(@fromBackingInt(@intCast(d.lhs))),
            .try_stmt => {
                const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                x.declare(t.catch_name);
                try x.countList(t.body());
                try x.countList(t.finalBody());
                try x.countList(t.catchBody());
            },
            else => {},
        }
    }

    fn countList(x: *Extractor, range: JsIr.SubRange) Allocator.Error!void {
        for (x.ir.extraSlice(range, Index)) |stmt| try x.count(stmt);
    }

    fn countFunc(x: *Extractor, record: ExtraIndex) Allocator.Error!void {
        const f = x.ir.extraData(record, JsIr.Func);
        for (x.ir.extraSlice(f.params(), NameIndex)) |n| x.declare(n);
        try x.countList(f.body());
    }

    fn countExpr(x: *Extractor, root: Index) Allocator.Error!void {
        const ir = x.ir;
        const root_tag = ir.tag(root);
        if (root_tag == .ident) return x.read(@fromBackingInt(@intCast(ir.data(root).lhs)), false);
        if (count_leaves[@backingInt(root_tag)]) return;
        const stack = &x.work;
        const base = stack.items.len;
        defer stack.items.len = base;
        try JsIr.pushOperand(x.scratch, stack, root);
        while (stack.items.len > base) {
            const node = JsIr.popOperand(stack).?;
            const t = ir.tag(node);
            if (t == .ident) {
                try x.read(@fromBackingInt(@intCast(ir.data(node).lhs)), false);
            } else if (t == .arrow) {
                try x.countFunc(@fromBackingInt(@intCast(ir.data(node).lhs)));
            } else if (t == .call) {
                const d = ir.data(node);
                const callee: Index = @fromBackingInt(@intCast(d.lhs));
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |a| try JsIr.pushOperand(x.scratch, stack, a);
                if (ir.tag(callee) == .ident) {
                    try x.read(@fromBackingInt(@intCast(ir.data(callee).lhs)), true);
                } else try JsIr.pushOperand(x.scratch, stack, callee);
            } else if (!count_leaves[@backingInt(t)]) try ir.pushOperands(x.scratch, stack, node);
        }
    }

    // ---- `Spec.evalStmt`'s walk, emitting what it evaluates -------------------

    fn stmtOf(x: *Extractor, stmt: Index) Allocator.Error!void {
        const ir = x.ir;
        const d = ir.data(stmt);
        switch (ir.tag(stmt)) {
            .import_stmt, .export_stmt => {},
            .const_decl, .let_decl => {
                const n: NameIndex = @fromBackingInt(@intCast(d.lhs));
                const rhs: Node.OptionalIndex = @fromBackingInt(@intCast(d.rhs));
                const c: u32 = if (rhs.unwrap()) |r| try x.expr(r) else none;
                if (x.globalOf(n) == null) if (n.unwrap()) |i| if (i < x.names) {
                    x.touch(i);
                    if (x.decls[i] == 1 and !x.assigned[i]) x.src[i] = c;
                };
            },
            .func_decl, .gen_decl => {
                const saved = x.narrow;
                x.narrow = .empty;
                for (saved.items) |n| x.guards[n.int()] -= 1;
                defer {
                    x.narrow = saved;
                    for (saved.items) |n| x.guards[n.int()] += 1;
                }
                try x.func(@fromBackingInt(@intCast(d.rhs)), stmt);
            },
            .assign_stmt => {
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                if (ir.tag(target) != .ident) _ = try x.expr(target);
                const value = try x.expr(@fromBackingInt(@intCast(d.rhs)));
                if (ir.tag(target) == .member) try x.emit(.store, target.int(), value, false);
            },
            .return_stmt => {
                const v: u32 = if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try x.expr(v) else none;
                if (x.cur_fn != none) try x.emit(.ret, x.cur_fn, v, false);
            },
            .if_stmt => {
                const t = try x.expr(@fromBackingInt(@intCast(d.lhs)));
                const branches = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                var saved = try x.enter(.then_arm, t);
                try x.list(branches.thenBody());
                x.cur_exec = saved;
                saved = try x.enter(.else_arm, t);
                try x.list(branches.elseBody());
                x.cur_exec = saved;
            },
            .while_true, .block_stmt => try x.list(ir.subRange(@fromBackingInt(@intCast(d.rhs)))),
            .for_of => {
                const f = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                _ = try x.expr(f.iterable);
                try x.list(f.body());
            },
            .switch_stmt => {
                _ = try x.expr(@fromBackingInt(@intCast(d.lhs)));
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |c| try x.stmtOf(c);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| _ = try x.expr(t);
                try x.list(ir.subRange(@fromBackingInt(@intCast(d.rhs))));
            },
            .expr_stmt, .throw_stmt => _ = try x.expr(@fromBackingInt(@intCast(d.lhs))),
            .try_stmt => {
                const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                try x.list(t.body());
                try x.list(t.finalBody());
                try x.list(t.catchBody());
            },
            else => {},
        }
    }

    fn list(x: *Extractor, range: JsIr.SubRange) Allocator.Error!void {
        const base = x.narrow.items.len;
        defer {
            for (x.narrow.items[base..]) |n| x.guards[n.int()] -= 1;
            x.narrow.shrinkRetainingCapacity(base);
        }
        for (x.ir.extraSlice(range, Index)) |stmt| {
            try x.stmtOf(stmt);
            if (x.ir.tag(stmt) == .if_stmt) try x.guardNames(stmt);
        }
    }

    /// `Spec.guardNames`, into `narrow`.
    fn guardNames(x: *Extractor, stmt: Index) Allocator.Error!void {
        const ir = x.ir;
        const branches = ir.extraData(@fromBackingInt(@intCast(ir.data(stmt).rhs)), JsIr.If);
        const then = ir.extraSlice(branches.thenBody(), Index);
        if (then.len == 0) return;
        switch (ir.tag(then[then.len - 1])) {
            .throw_stmt, .return_stmt, .break_stmt, .continue_stmt => {},
            else => return,
        }
        const stack = &x.work;
        const disjuncts = &x.disjuncts;
        disjuncts.clearRetainingCapacity();
        try disjuncts.append(x.scratch, @fromBackingInt(@intCast(ir.data(stmt).lhs)));
        while (disjuncts.pop()) |dj| {
            if (ir.tag(dj) == .binary and @as(JsIr.BinaryOp, @fromBackingInt(@intCast(ir.data(dj).rhs))) == .logical_or) {
                const b = ir.extraData(@fromBackingInt(@intCast(ir.data(dj).lhs)), JsIr.Binary);
                try disjuncts.appendSlice(x.scratch, &.{ b.right, b.left });
                continue;
            }
            if (nullTest(ir, dj)) |t| if (t.loose and t.null_in_then and ir.tag(t.chain) == .ident) {
                try x.narrowName(@fromBackingInt(@intCast(ir.data(t.chain).lhs)));
            };
            stack.clearRetainingCapacity();
            try JsIr.pushOperand(x.scratch, stack, dj);
            while (JsIr.popOperand(stack)) |node| {
                const d = ir.data(node);
                switch (ir.tag(node)) {
                    .member, .index_get => {
                        const object: Index = @fromBackingInt(@intCast(d.lhs));
                        if (ir.tag(object) == .ident) try x.narrowName(@fromBackingInt(@intCast(ir.data(object).lhs)));
                    },
                    .binary => switch (@as(JsIr.BinaryOp, @fromBackingInt(@intCast(d.rhs)))) {
                        .logical_and, .logical_or => {
                            try JsIr.pushOperand(x.scratch, stack, ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary).left);
                            continue;
                        },
                        else => {},
                    },
                    .cond => {
                        try JsIr.pushOperand(x.scratch, stack, @fromBackingInt(@intCast(d.lhs)));
                        continue;
                    },
                    else => {},
                }
                try ir.pushOperands(x.scratch, stack, node);
            }
        }
    }

    fn narrowName(x: *Extractor, n: NameIndex) Allocator.Error!void {
        if (x.globalOf(n) != null or n.unwrap() == null) return;
        if (n.int() >= x.guards.len) return;
        try x.narrow.append(x.scratch, n);
        x.guards[n.int()] += 1;
    }

    /// `Spec.evalFunc`: the body, then `undefined` returned when it may run
    /// off its end.
    fn func(x: *Extractor, record: ExtraIndex, node: Index) Allocator.Error!void {
        const saved = x.cur_fn;
        defer x.cur_fn = saved;
        x.cur_fn = node.int();
        // The body runs when something that runs may call it.
        const saved_exec = try x.enter(.body, node.int());
        defer x.cur_exec = saved_exec;
        const f = x.ir.extraData(record, JsIr.Func);
        try x.list(f.body());
        if (fallsThrough(x.ir, f.body())) try x.emit(.ret, node.int(), none, false);
    }

    /// `Spec.eval`: the expression's nodes in the order it evaluates them,
    /// each a constraint; the cell of `root`.
    fn expr(x: *Extractor, root: Index) Allocator.Error!u32 {
        const ir = x.ir;
        if (isValueLeaf(ir.tag(root))) {
            try x.combine(root);
            return x.cell[root.int()];
        }
        const stack = &x.stack;
        const base = stack.items.len;
        defer stack.items.len = base;
        try JsIr.pushOperand(x.scratch, stack, root);
        while (stack.items.len > base) {
            const raw = stack.items[stack.items.len - 1].int();
            stack.items.len -= 1;
            if (raw & post_bit == 0) {
                // An arm of `?:`, `&&` or `||` ends, or begins: its exec cell.
                if (raw & mark_exit != 0) {
                    x.cur_exec = x.exec_saved.pop().?;
                    continue;
                }
                if (raw & mark_enter != 0) {
                    const at: Index = @fromBackingInt(@intCast(raw & mark_node));
                    const kind: ExecCell.ExecKind, const from: Index = switch (ir.tag(at)) {
                        .cond => .{ if (raw & mark_alt != 0) .else_arm else .then_arm, @fromBackingInt(@intCast(ir.data(at).lhs)) },
                        else => blk: {
                            const op: JsIr.BinaryOp = @fromBackingInt(@intCast(ir.data(at).rhs));
                            break :blk .{ if (op == .logical_and) .and_right else .or_right, ir.extraData(@fromBackingInt(@intCast(ir.data(at).lhs)), JsIr.Binary).left };
                        },
                    };
                    try x.exec_saved.append(x.scratch, try x.enter(kind, x.cell[from.int()]));
                    continue;
                }
                const node: Index = @fromBackingInt(@intCast(raw));
                const t = ir.tag(node);
                if (t == .arrow) {
                    const c = try x.occur(node);
                    try x.emit(.constant, c, fixed_object, false);
                    try x.func(@fromBackingInt(@intCast(ir.data(node).lhs)), node);
                    continue;
                }
                if (isValueLeaf(t)) {
                    try x.combine(node);
                    continue;
                }
                std.debug.assert(raw < mark_exit);
                try JsIr.pushOperand(x.scratch, stack, @fromBackingInt(@intCast(raw | post_bit)));
                // The order `pushOperands` gives, each arm bracketed.
                const d = ir.data(node);
                if (t == .cond) {
                    const k = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                    try JsIr.pushOperandSlice(x.scratch, stack, &.{
                        @fromBackingInt(mark_exit),       k.alternate,  @fromBackingInt(@intCast(raw | mark_enter | mark_alt)),
                        @fromBackingInt(mark_exit),       k.consequent, @fromBackingInt(@intCast(raw | mark_enter)),
                        @fromBackingInt(@intCast(d.lhs)),
                    });
                    continue;
                }
                if (t == .binary) switch (@as(JsIr.BinaryOp, @fromBackingInt(@intCast(d.rhs)))) {
                    .logical_and, .logical_or => {
                        const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                        try JsIr.pushOperandSlice(x.scratch, stack, &.{ @fromBackingInt(mark_exit), b.right, @fromBackingInt(@intCast(raw | mark_enter)), b.left });
                        continue;
                    },
                    else => {},
                };
                try ir.pushOperands(x.scratch, stack, node);
                continue;
            }
            try x.combine(@fromBackingInt(@intCast(raw & ~post_bit)));
        }
        return x.cell[root.int()];
    }

    /// `Spec.combine`'s constraint for `node`, whose operands' constraints
    /// came before it.
    fn combine(x: *Extractor, node: Index) Allocator.Error!void {
        const ir = x.ir;
        const d = ir.data(node);
        const c = try x.occur(node);
        switch (ir.tag(node)) {
            .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => try x.emit(.literal, c, 0, false),
            .ident => try x.ident(node, c),
            .unary => try x.emit(.unary, c, x.cell[d.lhs], false),
            .binary => {
                const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                const at: u32 = @intCast(x.pool.items.len);
                try x.pool.appendSlice(x.scratch, &.{ x.cell[b.left.int()], x.cell[b.right.int()] });
                try x.emit(.binary, c, at, false);
            },
            .cond => {
                const k = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                const test_node: Index = @fromBackingInt(@intCast(d.lhs));
                const at: u32 = @intCast(x.pool.items.len);
                try x.pool.appendSlice(x.scratch, &.{ x.cell[test_node.int()], x.cell[k.consequent.int()], x.cell[k.alternate.int()] });
                // Fact 5's second case, as `Spec.nullTestTaken` finds it.
                const taken: ?struct { tested: Index, taken: Index } = taken: {
                    if (ir.tag(test_node) != .binary) break :taken null;
                    const op: JsIr.BinaryOp = @fromBackingInt(@intCast(ir.data(test_node).rhs));
                    if (op != .strict_eq and op != .strict_ne) break :taken null;
                    const b = ir.extraData(@fromBackingInt(@intCast(ir.data(test_node).lhs)), JsIr.Binary);
                    const tested, const other = if (ir.tag(b.right) == .null_lit) .{ b.left, b.right } else .{ b.right, b.left };
                    if (ir.tag(other) != .null_lit or ir.tag(tested) != .member) break :taken null;
                    const branch = if (op == .strict_eq) k.alternate else k.consequent;
                    if (!sameChain(ir, tested, branch)) break :taken null;
                    break :taken .{ .tested = tested, .taken = branch };
                };
                if (taken) |t| {
                    try x.pool.appendSlice(x.scratch, &.{ x.cell[t.tested.int()], x.cell[t.taken.int()], t.taken.int() });
                } else try x.pool.appendSlice(x.scratch, &.{ none, none, none });
                try x.emit(.cond, c, at, false);
            },
            .call => {
                const callee: Index = @fromBackingInt(@intCast(d.lhs));
                const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index);
                const g: u32 = if (ir.tag(callee) == .ident) x.globalOf(@fromBackingInt(@intCast(ir.data(callee).lhs))) orelse none else none;
                const at: u32 = @intCast(x.pool.items.len);
                try x.pool.appendSlice(x.scratch, &.{ g, @intCast(args.len) });
                for (args) |arg| try x.pool.append(x.scratch, x.cell[arg.int()]);
                try x.emit(.call, c, at, false);
            },
            .template => {
                const parts = ir.extraSlice(JsIr.inlineRange(d), Index);
                const at: u32 = @intCast(x.pool.items.len);
                try x.pool.append(x.scratch, @intCast(parts.len));
                for (parts) |part| try x.pool.append(x.scratch, x.cell[part.int()]);
                try x.emit(.template, c, at, false);
            },
            .new_call, .array => try x.emit(.constant, c, fixed_object, false),
            .object => {
                const children = ir.extraSlice(JsIr.inlineRange(d), Index);
                const at: u32 = @intCast(x.pool.items.len);
                try x.pool.append(x.scratch, 0);
                var keys: u32 = 0;
                var spread: u32 = 0;
                for (children) |child| switch (ir.tag(child)) {
                    .property => {
                        const cd = ir.data(child);
                        try x.pool.appendSlice(x.scratch, &.{ cd.lhs, x.cell[cd.rhs] });
                        keys += 1;
                    },
                    else => spread = 1,
                };
                x.pool.items[at] = keys;
                try x.emit(.object, c, at, spread == 1);
            },
            .member => try x.emit(.member, c, x.cell[d.lhs], false),
            // `Spec.combine`: the store `stmtOf` emits for `o.p = v`, and
            // the value `v`, never as a literal (`Op.effect`).
            .assign => {
                try x.emit(.store, d.lhs, x.cell[d.rhs], false);
                try x.emit(.effect, c, x.cell[d.rhs], false);
            },
            .sequence => {
                const parts = ir.extraSlice(JsIr.inlineRange(d), Index);
                try x.emit(.effect, c, x.cell[parts[parts.len - 1].int()], false);
            },
            else => try x.emit(.constant, c, fixed_top, false),
        }
    }

    /// `Spec.nameValue` of identifier `node`, as far as the IR decides it.
    fn ident(x: *Extractor, node: Index, c: u32) Allocator.Error!void {
        const n: NameIndex = @fromBackingInt(@intCast(x.ir.data(node).lhs));
        if (x.globalOf(n)) |g| return x.emit(.global, c, g, false);
        const i = n.unwrap() orelse return x.emit(.constant, c, fixed_top, false);
        if (i >= x.names or x.stamp[i] != x.cur) return x.emit(.constant, c, fixed_top, false);
        if (x.decls[i] != 1 or x.assigned[i]) return x.emit(.constant, c, fixed_top, false);
        const narrowed: u32 = @intFromBool(x.guards[i] != 0);
        if (x.pos[i] != none) {
            x.param_reads = true;
            return x.emit(.param, c, x.pos[i], narrowed == 1);
        }
        return x.emit(.local, c, x.src[i], narrowed == 1);
    }
};

/// The combined solver for facts 1, 2, 4, 5 and 6 and truthiness
/// (`backend.md` §9, *The combined solver*, slice 4), fact 3 read as input
/// and every exec cell true. A solve's columns live in its own arena
/// (`Spec.solve_tmp`), emptied by the next solve.
///
/// **Cells.** Per module, its node cells (`Extract`), numbered by prefix
/// sums in module order; then one per tracked parameter (`Spec.params`).
/// A field (a site and a property) and a return (a function's site) are
/// fact 3's own cells of them (`Pts.Prop.lat`, `Pts.Site.ret_lat`): a
/// field exists from its first write, and one fact 3 has no `Prop` for is
/// one no read asks of.
///
/// **The worklist.** The constraints are evaluated once in module order
/// and walk order; a cell that changes queues the constraints that read it
/// and that this first pass has passed — its static readers from the
/// module's readers index (`Extract.rd`) or the parameters' (`prd`), and
/// for a field or a return those that read it so far, registered as they
/// read it. The queue is first in, first out. A constraint whose value is
/// fixed for the solve (a literal, a name, a node's kind) is written at the
/// merge and never evaluated.
const Solver = struct {
    s: *Spec,
    /// Per module: its first node cell, its first constraint, its first
    /// top-level statement in `Spec.w_stmts`.
    cell_base: []u32,
    con_base: []u32,
    stmt_base: []u32,
    /// The first parameter cell; every cell's value.
    param_base: u32,
    lat: []Lat,
    /// Per constraint: a parameter read's cell (`none`: ⊤), a call's first
    /// parameter (`none`: not a call `Spec` tracks).
    aux: []u32,
    /// The parameters' readers: per parameter, `prd[prd_off[p]..prd_off[p + 1]]`.
    prd_off: []u32,
    prd: []u32,
    /// Who read each field and return so far (`reads`): the lists the
    /// cells' `readers` start.
    readers: std.ArrayList(Reader) = .empty,
    /// The constraint being evaluated.
    cur: u32 = none,
    /// While the first pass runs, the constraint it is at: one past it is
    /// still to come, and is not queued.
    first_pass: bool = true,
    /// The queue, first in, first out: `queue.items[q_head..]`.
    queue: std.ArrayList(u32) = .empty,
    q_head: usize = 0,
    queued: std.DynamicBitSetUnmanaged,
    evaluations: u64 = 0,
    /// Past the work budget: every cell is ⊤ and stays ⊤.
    pessimised: bool = false,
    /// Executability (*Executability*): per module its first exec cell,
    /// and which exec cells are true.
    exec_base: []u32,
    on: std.DynamicBitSetUnmanaged,
    /// Per fact 3 site of a function: its body's exec cell in its module
    /// (`none`: no body extracted).
    site_exec: []u32,
    /// The names' cells (`Spec.nameInit`): which name each source cell is
    /// the initialiser of, and per name the `global` reads of it,
    /// `nrd[nrd_off[g]..nrd_off[g + 1]]`.
    name_src: std.DynamicBitSetUnmanaged = .{},
    name_of: []NameSrc = &.{},
    nrd_off: []u32 = &.{},
    nrd: []u32 = &.{},

    const Reader = struct { con: u32, next: u32 };
    /// A name's initialiser cell and the name, sorted by cell.
    const NameSrc = struct { cell: u32, g: u32 };

    /// The work budget (*The worklist*, *Termination*): evaluations per
    /// constraint and cell.
    const budget_per = 64;

    fn arena(sv: *Solver) Allocator {
        return sv.s.solve_tmp.allocator();
    }

    fn moduleOf(sv: *const Solver, con: u32) u32 {
        // The last module whose first constraint is at most `con`.
        var lo: usize = 0;
        var hi: usize = sv.con_base.len - 1;
        while (lo < hi) {
            const mid = (lo + hi + 1) / 2;
            if (sv.con_base[mid] <= con) lo = mid else hi = mid - 1;
        }
        return @intCast(lo);
    }

    inline fn cellOf(sv: *const Solver, mi: u32, local: u32) u32 {
        return sv.cell_base[mi] + local;
    }

    inline fn enqueue(sv: *Solver, con: u32) Allocator.Error!void {
        if (sv.first_pass and (sv.cur == none or con > sv.cur)) return;
        if (sv.queued.isSet(con)) return;
        sv.queued.set(con);
        try sv.queue.append(sv.arena(), con);
    }

    /// Every constraint on the readers list at `head` queued.
    fn wakeList(sv: *Solver, head: u32) Allocator.Error!void {
        var r = head;
        while (r != none) : (r = sv.readers.items[r].next) try sv.enqueue(sv.readers.items[r].con);
    }

    /// Node cell `local` of module `mi` is `v` now.
    fn set(sv: *Solver, mi: u32, local: u32, v: Lat) Allocator.Error!void {
        const cell = sv.cellOf(mi, local);
        const old = sv.lat[cell];
        const new = if (sv.pessimised) sv.s.join(old, v) else v;
        if (new.eql(old)) return;
        sv.lat[cell] = new;
        const x = &sv.s.mods[mi].ex;
        const base = sv.con_base[mi];
        for (x.rd[x.rd_off[local]..x.rd_off[local + 1]]) |j| try sv.enqueue(base + j);
        // The reads of the name it is the initialiser of.
        if (sv.name_src.bit_length != 0 and sv.name_src.isSet(cell)) {
            const at = std.sort.binarySearch(NameSrc, sv.name_of, cell, struct {
                fn order(c: u32, n: NameSrc) std.math.Order {
                    return std.math.order(c, n.cell);
                }
            }.order).?;
            const g = sv.name_of[at].g;
            for (sv.nrd[sv.nrd_off[g]..sv.nrd_off[g + 1]]) |con| try sv.enqueue(con);
        }
        // The arms it is the test of.
        for (x.et[x.et_off[local]..x.et_off[local + 1]]) |e| try sv.armCheck(mi, e);
    }

    /// Whether an arm of `kind` runs when its test is `v`: an arm `then`
    /// (`&&`'s right) when `v` may be truthy, `else` (`||`'s right) when it
    /// may be falsy, neither while the test has no value.
    fn allows(sv: *const Solver, kind: ExecCell.ExecKind, v: Lat) bool {
        if (v.state == .bot) return false;
        const t = sv.s.truthOf(v);
        return switch (kind) {
            .then_arm, .and_right => t != .no,
            .else_arm, .or_right => t != .yes,
            .top, .body => true,
        };
    }

    /// Arm `e` of module `mi` is true when its parent is and its test
    /// allows it.
    fn armCheck(sv: *Solver, mi: u32, e: u32) Allocator.Error!void {
        const eb = sv.exec_base[mi];
        if (sv.on.isSet(eb + e)) return;
        const c = sv.s.mods[mi].ex.execs[e];
        if (!sv.on.isSet(eb + c.parent)) return;
        if (!sv.allows(c.kind, sv.lat[sv.cellOf(mi, c.a)])) return;
        try sv.turnOn(mi, e);
    }

    /// Exec cell `e` of module `mi` is true: what it gates is queued, and
    /// the arms below it are checked.
    fn turnOn(sv: *Solver, mi: u32, e: u32) Allocator.Error!void {
        const eb = sv.exec_base[mi];
        if (sv.on.isSet(eb + e)) return;
        sv.on.set(eb + e);
        try sv.opened(mi, e);
    }

    fn opened(sv: *Solver, mi: u32, e: u32) Allocator.Error!void {
        const x = &sv.s.mods[mi].ex;
        const base = sv.con_base[mi];
        for (x.ec[x.ec_off[e]..x.ec_off[e + 1]]) |j| try sv.enqueue(base + j);
        for (x.ek[x.ek_off[e]..x.ek_off[e + 1]]) |child| try sv.armCheck(mi, child);
    }

    /// The bodies of the functions in `v` are roots: the host may call them.
    fn held(sv: *Solver, v: Pts.Val) Allocator.Error!void {
        for (v.sites) |site| {
            if (site >= sv.site_exec.len or sv.site_exec[site] == none) continue;
            sv.on.set(sv.exec_base[sv.s.pts.sites.items[site].module] + sv.site_exec[site]);
        }
    }

    /// The bodies of the functions in `v` run: something that runs calls them.
    fn calls(sv: *Solver, v: Pts.Val) Allocator.Error!void {
        for (v.sites) |site| {
            if (site >= sv.site_exec.len or sv.site_exec[site] == none) continue;
            try sv.turnOn(sv.s.pts.sites.items[site].module, sv.site_exec[site]);
        }
    }

    inline fn runs(sv: *const Solver, mi: usize, j: usize) bool {
        return sv.on.isSet(sv.exec_base[mi] + sv.s.mods[mi].ex.exec[j]);
    }

    /// `v` joins parameter `p`'s cell.
    fn joinParam(sv: *Solver, p: u32, v: Lat) Allocator.Error!void {
        const cell = sv.param_base + p;
        const joined = sv.s.join(sv.lat[cell], v);
        if (joined.eql(sv.lat[cell])) return;
        sv.lat[cell] = joined;
        for (sv.prd[sv.prd_off[p]..sv.prd_off[p + 1]]) |con| try sv.enqueue(con);
    }

    /// The constraint being evaluated reads a field or a return whose
    /// readers list starts at `head` (`Spec.fieldGet`, `Spec.retGet`): it is
    /// woken when that changes. A constraint read again is listed again
    /// only when another read came between: listed twice, it is woken
    /// twice, which queues it once.
    fn reads(sv: *Solver, head: *u32) Allocator.Error!void {
        if (sv.cur == none) return;
        if (head.* != none and sv.readers.items[head.*].con == sv.cur) return;
        try sv.readers.append(sv.arena(), .{ .con = sv.cur, .next = head.* });
        head.* = @intCast(sv.readers.items.len - 1);
    }

    /// `v` joins a field or a return, fact 3's cell of it (`Spec.joinProp`,
    /// `Spec.joinRet`): it exists from the first write, whatever the write's
    /// value.
    fn joinCell(sv: *Solver, lat: *Lat, made: *bool, readers: u32, v: Lat) Allocator.Error!void {
        var moved = !made.*;
        made.* = true;
        const joined = sv.s.join(lat.*, v);
        if (!joined.eql(lat.*)) {
            lat.* = joined;
            moved = true;
        }
        if (moved) try sv.wakeList(readers);
    }

    fn joinField(sv: *Solver, site: u32, prop: u32, v: Lat) Allocator.Error!void {
        const pr = sv.s.pts.propMut(site, prop) orelse return;
        try sv.joinCell(&pr.lat, &pr.lat_made, pr.lat_readers, v);
    }

    /// A template's parts' values, read from their cells.
    const CellValues = struct {
        sv: *const Solver,
        mi: u32,
        cells: []const u32,
        fn get(v: CellValues, i: usize, part: Index) Lat {
            _ = part;
            return v.sv.lat[v.sv.cellOf(v.mi, v.cells[i])];
        }
    };

    /// Constraint `j` of module `mi` (`con` in all)'s transfer function, on
    /// its operands' cells as they are: what `Spec.combine` and
    /// `Spec.evalStmt` compute of the node, the operands' values being the
    /// cells'.
    fn eval(sv: *Solver, con: u32, mi: u32, j: usize, st: u32) Allocator.Error!void {
        const s = sv.s;
        const m = &s.mods[mi];
        const x = &m.ex;
        const ir = m.ir;
        sv.cur = con;
        s.cur_top = x.stmts[st].node;
        s.w_cur = sv.stmt_base[mi] + st;
        // `readsSite`'s record of one statement's reads, once per site.
        s.w_walk = s.w_cur + 1;
        const code = x.code[j];
        const node = x.nodeAt(j);
        const a = x.a[j];
        const v: Lat = switch (code.op) {
            // Written at the merge, but a name's read of its cell.
            .constant, .literal => return,
            .global => if (sv.aux[con] == none) return else sv.lat[sv.aux[con]],
            .local, .param => read: {
                const from: u32 = if (code.op == .local) (if (a == none) none else sv.cellOf(mi, a)) else sv.aux[con];
                const got = if (from == none) Lat.top else sv.lat[from];
                // Past a guard that proves it (`guardNames`).
                if (got.state == .top and code.flag) break :read .{ .state = .nonnull, .truth = got.truth };
                break :read got;
            },
            .effect => s.demote(sv.lat[sv.cellOf(mi, a)]),
            .unary => un: {
                const op: JsIr.UnaryOp = @fromBackingInt(@intCast(ir.data(node).rhs));
                const u = try s.unary(op, sv.lat[sv.cellOf(mi, a)]);
                break :un if (op != .yield and u.state == .top) .{ .state = .nonnull, .truth = u.truth } else u;
            },
            .binary => bin: {
                const op: JsIr.BinaryOp = @fromBackingInt(@intCast(ir.data(node).rhs));
                const l = sv.lat[sv.cellOf(mi, x.pool[a])];
                const r = sv.lat[sv.cellOf(mi, x.pool[a + 1])];
                if ((op == .strict_eq or op == .strict_ne) and l.state != .bot and r.state != .bot) {
                    const b = ir.extraData(@fromBackingInt(@intCast(ir.data(node).lhs)), JsIr.Binary);
                    if (try s.identity(m, b.left, b.right, l, r)) |same| break :bin try s.boolean(if (op == .strict_eq) same else !same);
                }
                const w = try s.binary(op, l, r);
                break :bin if (op != .logical_and and op != .logical_or and w.state == .top) .{ .state = .nonnull, .truth = w.truth } else w;
            },
            .cond => cond: {
                const p = x.pool[a..][0..6];
                const t = sv.lat[sv.cellOf(mi, p[0])];
                // Fact 5's second case, decided by this evaluation alone.
                if ((t.state == .top or t.state == .nonnull) and p[3] != none and sv.lat[sv.cellOf(mi, p[3])].state == .nonnull) {
                    break :cond sv.lat[sv.cellOf(mi, p[4])];
                }
                break :cond s.condValue(t, sv.lat[sv.cellOf(mi, p[1])], sv.lat[sv.cellOf(mi, p[2])]);
            },
            .call => call: {
                // Its arguments join the parameters of the function it names.
                if (sv.aux[con] != none) {
                    const n = x.pool[a + 1];
                    for (x.pool[a + 2 ..][0..n], 0..) |c, i| try sv.joinParam(sv.aux[con] + @as(u32, @intCast(i)), sv.lat[sv.cellOf(mi, c)]);
                }
                // The functions it may call run.
                if (s.pts.ok) try sv.calls(s.pts.vals[mi][ir.data(node).lhs]);
                break :call try s.callValue(m, node);
            },
            .template => try s.templateValue(m, node, CellValues{ .sv = sv, .mi = mi, .cells = x.pool[a + 1 ..][0..x.pool[a]] }),
            .member => member: {
                // An object facts 1 and 2 name (`memberOf`).
                const o = if (a == none) Lat.top else sv.lat[sv.cellOf(mi, a)];
                if (o.state == .lit and s.pts.ok) if (s.litOf(o).kind == .name) {
                    const g = Spec.nameId(s.litOf(o));
                    if (g < s.pts.globals.len) break :member try s.memberOf(m, node, try s.pts.view(s.pts.globals[g]));
                };
                break :member try s.memberValue(m, node);
            },
            .object => obj: {
                if (s.pts.siteAt(mi, node)) |site| {
                    const n = x.pool[a];
                    for (0..n) |k| {
                        const name: NameIndex = @fromBackingInt(@intCast(x.pool[a + 1 + 2 * k]));
                        const prop = s.pts.propId(mi, name);
                        if (prop == none) continue;
                        try sv.joinField(site, prop, sv.lat[sv.cellOf(mi, x.pool[a + 2 + 2 * k])]);
                    }
                }
                break :obj Lat.object;
            },
            .store => {
                if (s.pts.ok) {
                    const td = ir.data(node);
                    const obj = s.pts.vals[mi][td.lhs];
                    const prop = s.pts.propId(mi, @fromBackingInt(@intCast(td.rhs)));
                    if (prop != none) for (obj.sites) |site| try sv.joinField(site, prop, sv.lat[sv.cellOf(mi, a)]);
                }
                return;
            },
            .ret => {
                const w: Lat = if (a == none) .of(try s.intern(.{ .kind = .undefined_lit })) else sv.lat[sv.cellOf(mi, a)];
                // Its function's site, which holds the return's cell.
                const site = s.pts.siteAt(mi, @fromBackingInt(@intCast(x.node[j]))) orelse return;
                const fs = &s.pts.sites.items[site];
                try sv.joinCell(&fs.ret_lat, &fs.ret_made, fs.ret_readers, w);
                return;
            },
        };
        try sv.set(mi, x.node[j], v);
    }

    /// What is still changing, past the budget, is ⊤ (*The worklist*): a
    /// fixpoint above any other, so the facts stay sound.
    fn pessimise(sv: *Solver) Allocator.Error!void {
        sv.pessimised = true;
        sv.first_pass = false;
        sv.s.stats.solve_budget_hit += 1;
        for (sv.lat[sv.param_base..]) |*v| v.* = .top;
        sv.on.setRangeValue(.{ .start = 0, .end = sv.on.bit_length }, true);
        for (sv.s.pts.sites.items) |*st| {
            st.ret_lat = .top;
            for (st.props.items) |*pr| pr.lat = .top;
        }
        var con: u32 = 0;
        while (con < sv.queued.bit_length) : (con += 1) try sv.enqueue(con);
    }

    fn budget(sv: *Solver, con: u32, limit: u64) Allocator.Error!void {
        sv.evaluations += 1;
        if (sv.evaluations <= limit or sv.pessimised) return;
        if (std.debug.runtime_safety) {
            const mi = sv.moduleOf(con);
            const n = sv.s.mods[mi].ex.nodeAt(con - sv.con_base[mi]);
            std.debug.panic("specialisation: the combined solver passed its work budget of {d} evaluations, node {d} ({t}) of module {d} still changing", .{ limit, n.int(), sv.s.mods[mi].ir.tag(n), mi });
        }
        try sv.pessimise();
    }

    /// The first pass, every constraint in order, then the queue to empty.
    fn solve(sv: *Solver) Allocator.Error!void {
        const limit: u64 = budget_per * (@as(u64, sv.queued.bit_length) + sv.lat.len);
        // The arms below the roots, whose tests may be fixed already.
        for (sv.s.mods, 0..) |*m, mi| for (0..m.ex.execs.len) |e| {
            if (sv.on.isSet(sv.exec_base[mi] + e)) try sv.opened(@intCast(mi), @intCast(e));
        };
        for (sv.s.mods, 0..) |*m, mi| {
            const base = sv.con_base[mi];
            var first: u32 = 0;
            for (m.ex.stmts, 0..) |st, k| {
                defer first = st.cons;
                for (first..st.cons) |j| switch (m.ex.code[j].op) {
                    .constant, .literal => {},
                    .global => if (sv.aux[base + j] != none and sv.runs(mi, j)) {
                        const con = base + @as(u32, @intCast(j));
                        try sv.budget(con, limit);
                        try sv.eval(con, @intCast(mi), j, @intCast(k));
                    },
                    else => if (sv.runs(mi, j)) {
                        const con = base + @as(u32, @intCast(j));
                        try sv.budget(con, limit);
                        try sv.eval(con, @intCast(mi), j, @intCast(k));
                    },
                };
            }
        }
        sv.first_pass = false;
        while (sv.q_head < sv.queue.items.len) {
            const con = sv.queue.items[sv.q_head];
            sv.q_head += 1;
            // Emptied, it starts again at its front.
            if (sv.q_head == sv.queue.items.len) {
                sv.q_head = 0;
                sv.queue.clearRetainingCapacity();
            }
            sv.queued.unset(con);
            const mi = sv.moduleOf(con);
            const j = con - sv.con_base[mi];
            // Woken where nothing runs: it is queued again when its exec
            // cell becomes true.
            if (!sv.runs(mi, j)) continue;
            try sv.budget(con, limit);
            try sv.eval(con, mi, j, sv.s.mods[mi].ex.stmtOf(j));
        }
        sv.cur = none;
    }
};

/// Fact 3's constraints of one module (`backend.md` §9, *The combined
/// solver*, slice 5): what `Pts`' first walk by constraints recorded of it
/// (`Pts.begin`, `Pts.input`, `Pts.narrowed`, `Pts.killRead`), made from the
/// module's `JsIr` alone, and the script of what else that walk did in
/// between, in its order — the sites and bodies of functions, the drains,
/// the context a site is made in — which `Pts.replay` follows. A constraint
/// is numbered in the walk's order within its module; the replay adds the
/// module's base. Kept while the module's `epoch` stands.
const PtsExtract = struct {
    arena: Arena = .init(std.heap.page_allocator),
    epoch: u64 = std.math.maxInt(u64),
    nodes: u32 = 0,
    /// Per constraint: its node, its top-level statement, where its inputs
    /// and its candidate guards end in `inputs` and `narrows`.
    node: []u32 = &.{},
    top: []u32 = &.{},
    inputs_end: []u32 = &.{},
    narrows_end: []u32 = &.{},
    /// A node whose value a constraint reads, and the constraint (of this
    /// module) that made the value.
    inputs: []PtsRead = &.{},
    /// The guards in view where a read was walked that name its chain and
    /// no unconditional kill had killed: what each says, and the reads
    /// between its push and this read (`kills[start..end]`, constraints of
    /// this module) each of which kills it once its object is `top`. The
    /// replay keeps them unless the read's object is `top` when it is first
    /// evaluated, as the walk recorded them only then (`Pts.narrowed`).
    narrows: []PtsNarrow = &.{},
    kills: []u32 = &.{},
    script: []PtsStep = &.{},
    /// The nodes whose value is their tag's, made by no constraint: every
    /// leaf but a name, and `constantValue`'s.
    constants: []u32 = &.{},
    /// Every `const x = f(…)` or `let x = f(…)` (`Pts.decl_call`).
    decl_calls: []PtsDeclCall = &.{},
    /// Per top-level statement: its node, where each of its columns ends,
    /// and the module's `epoch` when it was extracted. A statement's
    /// constraints read only constraints of the statement, so one whose
    /// nodes stand is copied into the next extraction, renumbered
    /// (`PtsExtractor.reuse`).
    stmts: []PtsStmt = &.{},
    /// Of the last extraction: the statements walked and those copied.
    walked: u32 = 0,
    reused: u32 = 0,

    /// A safety build's check that what an extraction kept of the last one
    /// is what a walk of every statement makes.
    fn expectSame(x: *const PtsExtract, y: *const PtsExtract, mi: u32) void {
        const same = std.mem.eql(u32, x.node, y.node) and std.mem.eql(u32, x.top, y.top) and
            std.mem.eql(u32, x.inputs_end, y.inputs_end) and std.mem.eql(u32, x.narrows_end, y.narrows_end) and
            std.mem.eql(u8, std.mem.sliceAsBytes(x.inputs), std.mem.sliceAsBytes(y.inputs)) and
            std.mem.eql(u32, x.kills, y.kills) and std.mem.eql(u32, x.constants, y.constants) and
            x.narrows.len == y.narrows.len and x.script.len == y.script.len and x.decl_calls.len == y.decl_calls.len;
        if (!same) std.debug.panic("specialisation: module {d}'s fact-3 constraints kept from its last extraction are not what a walk makes", .{mi});
        for (x.narrows, y.narrows) |a, b| if (a.nul != b.nul or a.undef != b.undef or a.start != b.start or a.end != b.end) std.debug.panic("specialisation: module {d}'s kept guards differ", .{mi});
        for (x.script, y.script) |a, b| if (a.op != b.op or a.a != b.a) std.debug.panic("specialisation: module {d}'s kept steps differ", .{mi});
        for (x.decl_calls, y.decl_calls) |a, b| if (a.call != b.call or a.start != b.start or a.end != b.end or a.index != b.index) std.debug.panic("specialisation: module {d}'s kept calls differ", .{mi});
    }

    fn deinit(x: *PtsExtract) void {
        x.arena.deinit();
        x.* = .{};
    }
};

const PtsRead = struct { node: u32, cons: u32 };
const PtsStmt = struct { node: u32, cons: u32, inputs: u32, narrows: u32, kills: u32, script: u32, constants: u32, decl_calls: u32, epoch: u64 };
const PtsNarrow = struct { nul: bool, undef: bool, start: u32, end: u32 };
const PtsDeclCall = struct { call: u32, start: u32, end: u32, index: u32 };

/// One step of `Pts.replay`, as the first walk took it.
const PtsStep = struct {
    op: Act,
    a: u32 = 0,

    const Act = enum(u8) {
        /// A top-level statement `a` begins: no constraint is current, the
        /// statement's locals are keyed by it, and what is made is made once.
        stmt_begin,
        /// The statement ends: what waits joins (`Pts.drain`).
        stmt_end,
        /// Constraint `a` evaluated.
        eval,
        /// Arrow `a`: its site, then its body begins.
        arrow,
        /// Function declaration `a`: its site, held by its name, then its
        /// body begins.
        func_decl,
        /// The body of function `a` ends: `undefined` returned when it may
        /// run off its end, what waits joins, and the context is the one it
        /// began in; an arrow's value is its site.
        body_end,
        /// A loop's statements begin, which may run many times, and end.
        loop_begin,
        loop_end,
        /// The object literal `a` that a `return` gives, the function's one
        /// way out (`Site.fresh_fn`).
        fresh,
    };
};

/// `Pts`' first walk by constraints, without evaluating anything: the
/// constraints it would make and the steps it would take (`PtsExtract`).
/// Reads the module's `JsIr` and its `global` column alone.
const PtsExtractor = struct {
    scratch: Allocator,
    ir: *const JsIr,
    nodes: u32,
    /// Per node, the last constraint that evaluated it (`Pts.last`).
    last: []u32,
    guards: std.ArrayList(Guard) = .empty,
    guard_base: usize = 0,
    reads: std.ArrayList(u32) = .empty,
    stack: std.ArrayList(Index) = .empty,
    stmts: std.ArrayList(PtsStmt) = .empty,
    node: std.ArrayList(u32) = .empty,
    top: std.ArrayList(u32) = .empty,
    inputs_end: std.ArrayList(u32) = .empty,
    narrows_end: std.ArrayList(u32) = .empty,
    inputs: std.ArrayList(PtsRead) = .empty,
    narrows: std.ArrayList(PtsNarrow) = .empty,
    kills: std.ArrayList(u32) = .empty,
    script: std.ArrayList(PtsStep) = .empty,
    constants: std.ArrayList(u32) = .empty,
    decl_calls: std.ArrayList(PtsDeclCall) = .empty,
    cur_top: Index = undefined,

    const Guard = struct { chain: Index, nul: bool, undef: bool, dead: bool = false, reads: u32 };

    /// Extract module `m` into `into`, which it replaces: a statement whose
    /// nodes are what they were when `into` took it (`Mod.keptNodes`) is
    /// copied, unless `fresh`.
    fn run(scratch: Allocator, m: *const Mod, fresh: bool, into: *PtsExtract) Allocator.Error!void {
        const ir = m.ir;
        const epoch = m.epoch;
        const nodes: u32 = @intCast(ir.nodes.len);
        var x: PtsExtractor = .{ .scratch = scratch, .ir = ir, .nodes = nodes, .last = try scratch.alloc(u32, nodes) };
        @memset(x.last, none);
        var old: KeyMap(struct { node: u32 }, u32) = .empty;
        if (!fresh) for (into.stmts, 0..) |st, k| try old.put(scratch, .{ .node = st.node }, @intCast(k));
        var walked: u32 = 0;
        var reused: u32 = 0;
        for (ir.extraSlice(ir.body, Index)) |top| {
            if (old.get(.{ .node = top.int() })) |k| if (m.keptNodes(top, into.stmts[k].epoch)) if (try x.reuse(into, k)) {
                reused += 1;
                continue;
            };
            walked += 1;
            x.cur_top = top;
            x.reads.clearRetainingCapacity();
            try x.step(.stmt_begin, top.int());
            try x.stmt(top);
            try x.step(.stmt_end, 0);
            try x.endStmt(top, epoch);
        }
        into.walked = walked;
        into.reused = reused;
        into.arena.reset(.retain_capacity);
        const keep = into.arena.allocator();
        into.epoch = epoch;
        into.nodes = nodes;
        into.node = try keep.dupe(u32, x.node.items);
        into.top = try keep.dupe(u32, x.top.items);
        into.inputs_end = try keep.dupe(u32, x.inputs_end.items);
        into.narrows_end = try keep.dupe(u32, x.narrows_end.items);
        into.inputs = try keep.dupe(PtsRead, x.inputs.items);
        into.narrows = try keep.dupe(PtsNarrow, x.narrows.items);
        into.kills = try keep.dupe(u32, x.kills.items);
        into.script = try keep.dupe(PtsStep, x.script.items);
        into.constants = try keep.dupe(u32, x.constants.items);
        into.decl_calls = try keep.dupe(PtsDeclCall, x.decl_calls.items);
        into.stmts = try keep.dupe(PtsStmt, x.stmts.items);
    }

    fn endStmt(x: *PtsExtractor, top: Index, epoch: u64) Allocator.Error!void {
        try x.stmts.append(x.scratch, .{
            .node = top.int(),
            .cons = @intCast(x.node.items.len),
            .inputs = @intCast(x.inputs.items.len),
            .narrows = @intCast(x.narrows.items.len),
            .kills = @intCast(x.kills.items.len),
            .script = @intCast(x.script.items.len),
            .constants = @intCast(x.constants.items.len),
            .decl_calls = @intCast(x.decl_calls.items.len),
            .epoch = epoch,
        });
    }

    /// Statement `k` of `from`, the last extraction, taken as it was, its
    /// constraints renumbered into this one. Not taken when one of its
    /// nodes was evaluated before it in this extraction, or one of its
    /// constraints reads a constraint outside it: a node two statements
    /// share, whose last evaluation is another statement's.
    fn reuse(x: *PtsExtractor, from: *const PtsExtract, k: u32) Allocator.Error!bool {
        const st = from.stmts[k];
        const prev: PtsStmt = if (k == 0) std.mem.zeroes(PtsStmt) else from.stmts[k - 1];
        for (from.node[prev.cons..st.cons]) |node| if (x.last[node] != none) return false;
        for (from.inputs[prev.inputs..st.inputs]) |in| if (in.cons < prev.cons or in.cons >= st.cons) return false;
        for (from.kills[prev.kills..st.kills]) |c| if (c < prev.cons or c >= st.cons) return false;
        const s = x.scratch;
        const cons_at: u32 = @intCast(x.node.items.len);
        const inputs_at: u32 = @intCast(x.inputs.items.len);
        const narrows_at: u32 = @intCast(x.narrows.items.len);
        const kills_at: u32 = @intCast(x.kills.items.len);
        for (from.node[prev.cons..st.cons], from.top[prev.cons..st.cons], from.inputs_end[prev.cons..st.cons], from.narrows_end[prev.cons..st.cons], cons_at..) |node, top, in_end, nar_end, c| {
            try x.node.append(s, node);
            try x.top.append(s, top);
            try x.inputs_end.append(s, in_end - prev.inputs + inputs_at);
            try x.narrows_end.append(s, nar_end - prev.narrows + narrows_at);
            // The node's last evaluation, for a statement after it that
            // reads it.
            if (!x.ir.tag(@fromBackingInt(@intCast(node))).isStatement()) x.last[node] = @intCast(c);
        }
        for (from.inputs[prev.inputs..st.inputs]) |in| try x.inputs.append(s, .{ .node = in.node, .cons = in.cons - prev.cons + cons_at });
        for (from.narrows[prev.narrows..st.narrows]) |n| try x.narrows.append(s, .{ .nul = n.nul, .undef = n.undef, .start = n.start - prev.kills + kills_at, .end = n.end - prev.kills + kills_at });
        for (from.kills[prev.kills..st.kills]) |c| try x.kills.append(s, c - prev.cons + cons_at);
        for (from.script[prev.script..st.script]) |step_| try x.script.append(s, if (step_.op == .eval) .{ .op = .eval, .a = step_.a - prev.cons + cons_at } else step_);
        try x.constants.appendSlice(s, from.constants[prev.constants..st.constants]);
        try x.decl_calls.appendSlice(s, from.decl_calls[prev.decl_calls..st.decl_calls]);
        try x.stmts.append(s, .{
            .node = st.node,
            .cons = @intCast(x.node.items.len),
            .inputs = @intCast(x.inputs.items.len),
            .narrows = @intCast(x.narrows.items.len),
            .kills = @intCast(x.kills.items.len),
            .script = @intCast(x.script.items.len),
            .constants = @intCast(x.constants.items.len),
            .decl_calls = @intCast(x.decl_calls.items.len),
            .epoch = st.epoch,
        });
        return true;
    }

    fn step(x: *PtsExtractor, op: PtsStep.Act, a: u32) Allocator.Error!void {
        try x.script.append(x.scratch, .{ .op = op, .a = a });
    }

    /// `Pts.begin`: a new constraint of `node`, reading the last evaluation
    /// of each node whose value it reads; evaluated where it stands.
    fn begin(x: *PtsExtractor, node: Index) Allocator.Error!u32 {
        const ir = x.ir;
        const c: u32 = @intCast(x.node.items.len);
        var buf: [3]Index = undefined;
        for (inputsOf(ir, node, &buf)) |in| try x.input(in, c);
        switch (ir.tag(node)) {
            .object => for (ir.extraSlice(JsIr.inlineRange(ir.data(node)), Index)) |child| {
                const cd = ir.data(child);
                try x.input(@fromBackingInt(@intCast(if (ir.tag(child) == .property) cd.rhs else cd.lhs)), c);
            },
            .array => for (ir.extraSlice(JsIr.inlineRange(ir.data(node)), Index)) |child| try x.input(child, c),
            .call, .new_call => for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(node).rhs))), Index)) |arg| try x.input(arg, c),
            else => {},
        }
        try x.node.append(x.scratch, node.int());
        try x.top.append(x.scratch, x.cur_top.int());
        try x.inputs_end.append(x.scratch, @intCast(x.inputs.items.len));
        try x.narrows_end.append(x.scratch, @intCast(x.narrows.items.len));
        try x.step(.eval, c);
        return c;
    }

    fn input(x: *PtsExtractor, node: Index, c: u32) Allocator.Error!void {
        _ = c;
        const from = x.last[node.int()];
        if (from == none) return;
        try x.inputs.append(x.scratch, .{ .node = node.int(), .cons = from });
    }

    /// The guards in view that name `node`'s chain and no kill killed
    /// (`Pts.narrowed`'s recording), noted for constraint `c`.
    fn narrowed(x: *PtsExtractor, c: u32, node: Index) Allocator.Error!void {
        for (x.guards.items[x.guard_base..]) |g| {
            if (!sameChain(x.ir, g.chain, node) or g.dead) continue;
            const start: u32 = @intCast(x.kills.items.len);
            try x.kills.appendSlice(x.scratch, x.reads.items[g.reads..]);
            try x.narrows.append(x.scratch, .{ .nul = g.nul, .undef = g.undef, .start = start, .end = @intCast(x.kills.items.len) });
        }
        x.narrows_end.items[c] = @intCast(x.narrows.items.len);
    }

    /// `Pts.kill`: every guard in view dies.
    fn kill(x: *PtsExtractor) void {
        for (x.guards.items[x.guard_base..]) |*g| g.dead = true;
    }

    /// `Pts.killRead`: a read through object node `obj`, which kills the
    /// guards in view once the object is `top`; one no constraint makes has
    /// its one value, and if that is `top` they die now.
    fn killRead(x: *PtsExtractor, obj: Index) Allocator.Error!void {
        if (x.guards.items.len == x.guard_base) return;
        const from = x.last[obj.int()];
        if (from != none) return x.reads.append(x.scratch, from);
        if (constantTop(x.ir, obj)) x.kill();
    }

    fn end(x: *PtsExtractor, c: u32, node: Index) void {
        x.last[node.int()] = c;
    }

    /// `Pts.effectOf`: statement `node`'s own transfer.
    fn effectOf(x: *PtsExtractor, node: Index) Allocator.Error!void {
        _ = try x.begin(node);
    }

    fn stmt(x: *PtsExtractor, node: Index) Allocator.Error!void {
        const ir = x.ir;
        const d = ir.data(node);
        switch (ir.tag(node)) {
            .import_stmt, .export_stmt, .break_stmt, .continue_stmt => {},
            .const_decl, .let_decl => {
                const v: Node.OptionalIndex = @fromBackingInt(@intCast(d.rhs));
                if (v.unwrap()) |value| try x.expr(value);
                try x.effectOf(node);
                x.kill();
            },
            .func_decl, .gen_decl => {
                try x.step(.func_decl, node.int());
                try x.body(@fromBackingInt(@intCast(d.rhs)), node);
                x.kill();
            },
            .assign_stmt => {
                try x.expr(@fromBackingInt(@intCast(d.rhs)));
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                const td = ir.data(target);
                switch (ir.tag(target)) {
                    .ident => {},
                    .member => try x.expr(@fromBackingInt(@intCast(td.lhs))),
                    .index_get => {
                        try x.expr(@fromBackingInt(@intCast(td.rhs)));
                        try x.expr(@fromBackingInt(@intCast(td.lhs)));
                    },
                    else => try x.expr(target),
                }
                try x.effectOf(node);
                x.kill();
            },
            .return_stmt => {
                const value: ?Index = @as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap();
                if (value) |v| try x.expr(v);
                try x.effectOf(node);
                if (value) |v| if (ir.tag(v) == .object) try x.step(.fresh, v.int());
            },
            .if_stmt => {
                try x.expr(@fromBackingInt(@intCast(d.lhs)));
                const branches = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                const t = nullTest(ir, @fromBackingInt(@intCast(d.lhs)));
                try x.branch(branches.thenBody(), if (t) |g| (if (g.null_in_then) null else g) else null);
                try x.branch(branches.elseBody(), if (t) |g| (if (g.null_in_then) g else null) else null);
            },
            .block_stmt => try x.list(ir.subRange(@fromBackingInt(@intCast(d.rhs)))),
            .while_true => {
                x.kill();
                try x.step(.loop_begin, 0);
                try x.list(ir.subRange(@fromBackingInt(@intCast(d.rhs))));
                try x.step(.loop_end, 0);
            },
            .for_of => {
                const f = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                try x.expr(f.iterable);
                try x.effectOf(node);
                x.kill();
                try x.step(.loop_begin, 0);
                try x.list(f.body());
                try x.step(.loop_end, 0);
            },
            .switch_stmt => {
                try x.expr(@fromBackingInt(@intCast(d.lhs)));
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |c| try x.stmt(c);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| try x.expr(t);
                try x.list(ir.subRange(@fromBackingInt(@intCast(d.rhs))));
            },
            .expr_stmt => try x.expr(@fromBackingInt(@intCast(d.lhs))),
            .throw_stmt => {
                try x.expr(@fromBackingInt(@intCast(d.lhs)));
                try x.effectOf(node);
            },
            .try_stmt => {
                const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
                try x.list(t.body());
                x.kill();
                try x.list(t.catchBody());
                x.kill();
                try x.list(t.finalBody());
                x.kill();
            },
            else => try x.expr(node),
        }
    }

    fn list(x: *PtsExtractor, range: JsIr.SubRange) Allocator.Error!void {
        const ir = x.ir;
        for (ir.extraSlice(range, Index), 0..) |node, k| {
            switch (ir.tag(node)) {
                .const_decl, .let_decl => {
                    const v: Node.OptionalIndex = @fromBackingInt(@intCast(ir.data(node).rhs));
                    if (v.unwrap()) |value| if (ir.tag(value) == .call) {
                        try x.decl_calls.append(x.scratch, .{ .call = value.int(), .start = @backingInt(range.start), .end = @backingInt(range.end), .index = @intCast(k) });
                    };
                },
                else => {},
            }
            try x.stmt(node);
        }
    }

    fn branch(x: *PtsExtractor, range: JsIr.SubRange, guard: ?NullTest) Allocator.Error!void {
        const base = x.guards.items.len;
        defer x.guards.shrinkRetainingCapacity(base);
        if (guard) |g| try x.guards.append(x.scratch, .{ .chain = g.chain, .nul = true, .undef = g.loose, .reads = @intCast(x.reads.items.len) });
        try x.list(range);
    }

    /// `Pts.body`: the steps around a function's statements, which see no
    /// guard outside them and whose reads kill none.
    fn body(x: *PtsExtractor, record: ExtraIndex, node: Index) Allocator.Error!void {
        const saved_base = x.guard_base;
        defer x.guard_base = saved_base;
        x.guard_base = x.guards.items.len;
        const saved_reads = x.reads.items.len;
        defer x.reads.shrinkRetainingCapacity(saved_reads);
        try x.list(x.ir.extraData(record, JsIr.Func).body());
        try x.step(.body_end, node.int());
    }

    /// `Pts.expr`.
    fn expr(x: *PtsExtractor, root: Index) Allocator.Error!void {
        const ir = x.ir;
        if (isValueLeaf(ir.tag(root))) {
            if (ir.tag(root) == .ident) {
                const c = try x.begin(root);
                try x.combine(c, root);
                x.end(c, root);
            } else try x.constants.append(x.scratch, root.int());
            return;
        }
        const stack = &x.stack;
        const base = stack.items.len;
        defer stack.items.len = base;
        try JsIr.pushOperand(x.scratch, stack, root);
        while (stack.items.len > base) {
            const raw = stack.items[stack.items.len - 1].int();
            stack.items.len -= 1;
            if (raw & post_bit == 0) {
                const node: Index = @fromBackingInt(@intCast(raw));
                const t = ir.tag(node);
                if (t == .arrow) {
                    try x.step(.arrow, raw);
                    try x.body(@fromBackingInt(@intCast(ir.data(node).lhs)), node);
                    continue;
                }
                if (isValueLeaf(t)) {
                    if (t != .ident) {
                        try x.constants.append(x.scratch, raw);
                    } else {
                        const c = try x.begin(node);
                        try x.combine(c, node);
                        x.end(c, node);
                    }
                    continue;
                }
                try JsIr.pushOperand(x.scratch, stack, @fromBackingInt(@intCast(raw | post_bit)));
                try ir.pushOperands(x.scratch, stack, node);
                continue;
            }
            const node: Index = @fromBackingInt(@intCast(raw & ~post_bit));
            if (!constantValue(ir, node)) {
                const c = try x.begin(node);
                try x.combine(c, node);
                x.end(c, node);
            } else {
                try x.constants.append(x.scratch, node.int());
                // `combineNow` of a `yield`: what the generator is resumed
                // with, and anything may have run.
                if (ir.tag(node) == .unary and @as(JsIr.UnaryOp, @fromBackingInt(@intCast(ir.data(node).rhs))) == .yield) x.kill();
            }
        }
    }

    /// What `Pts.combineNow` of constraint `c`'s node does to the guards:
    /// a name's and a member read's guards noted; a read through an object
    /// kills them once it is `top`; a call or a `new` kills them.
    fn combine(x: *PtsExtractor, c: u32, node: Index) Allocator.Error!void {
        const ir = x.ir;
        const d = ir.data(node);
        switch (ir.tag(node)) {
            .ident => try x.narrowed(c, node),
            .member => {
                try x.narrowed(c, node);
                try x.killRead(@fromBackingInt(@intCast(d.lhs)));
            },
            .index_get => try x.killRead(@fromBackingInt(@intCast(d.lhs))),
            .call, .new_call, .assign => x.kill(),
            else => {},
        }
    }
};

/// The value of a node no constraint of fact 3 makes (`constantValue`, and
/// every leaf but a name), as `Pts.combineNow` makes it.
fn constantVal(ir: *const JsIr, node: Index) Pts.Val {
    const t = ir.tag(node);
    if (isValueLeaf(t)) return Pts.literal_vals[@backingInt(t)];
    return if (constantTop(ir, node)) Pts.Val.top_val else Pts.Val.prim_val;
}

/// Whether a node no constraint of fact 3 makes is `top` for good
/// (`Pts.literal_vals`, `Pts.combineNow` of a `constantValue` node).
fn constantTop(ir: *const JsIr, node: Index) bool {
    return switch (ir.tag(node)) {
        .global_this, .this_lit => true,
        .unary => @as(JsIr.UnaryOp, @fromBackingInt(@intCast(ir.data(node).rhs))) == .yield,
        else => false,
    };
}

const Pts = struct {
    s: *Spec,
    vars: std.ArrayList(VSet) = .empty,
    /// Per var, beside `vars`: what a join's walk over successors reads of
    /// it, and what only making an edge, a summary or a shared field reads
    /// (`VLink`, `VCold`; #577).
    links_of: std.ArrayList(VLink) = .empty,
    cold: std.ArrayList(VCold) = .empty,
    sites: std.ArrayList(Site) = .empty,
    /// Per module, per node: the site an object, array or function node
    /// makes (`none` until it does); per name, the var it had in the top-level
    /// statement it was last looked up in, and that statement
    /// (`cachedLocal`). Sized afresh each fixpoint, as `vals` is.
    site_of: [][]u32 = &.{},
    name_var: [][]VarId = &.{},
    name_top: [][]u32 = &.{},
    /// Per module, per node: the var `nodeVar` found for it, and the
    /// top-level statement it was found under (`none`: not yet).
    node_var: [][]VarId = &.{},
    node_top: [][]u32 = &.{},
    /// Per module and name: the identifier a `const` of the name copies,
    /// when that `const` is the name's one declaration (`aliasSources`), or
    /// `none`. Such a name's var is its source's (`localVar`).
    alias_src: [][]u32 = &.{},
    alias_depth: u32 = 0,
    locals: KeyMap(LocalKey, VarId) = .empty,
    globals: []VarId = &.{},
    /// Each module's per-node value of the sweep in progress.
    vals: [][]Val = &.{},
    /// Where everything of one fixpoint lives — the per-node and per-name
    /// columns above, `globals`, the vars, sites, locals, constraints,
    /// edges, summaries, load cells and the set table — and the facts
    /// `Spec` keeps of one analysis (`Spec.spread_sites`, the sweeps'
    /// dependency lists): `backend.md` §9, *The combined solver — Memory*'s
    /// solve arena and set table. `reset` empties it with `.keep_all`, so
    /// each run fills the memory the run before touched, already mapped,
    /// and the compilation's arena (`arena`) takes nothing per run (#574).
    /// What outlives a run stays there: `extra_init`, the walk's stacks,
    /// the modules' property columns.
    /// The hot lists among them — `vars`, `links_of`, `cold`, `sites`,
    /// `edges`, `deps`, `summaries`, `field_outs` — are columns of their
    /// own (`RunArena`), each grown in place (#606).
    tmp: RunArena,
    changed: bool = false,
    /// The fixpoint was reached this round: the facts may be read.
    ok: bool = false,
    /// Definite initialisation was still finding keys at `max_init_runs`
    /// (`analyse`), so the state is not kept for the next analysis.
    init_capped: bool = false,
    /// `expr`'s stack of nodes, shared by the walks it nests (`post_bit`).
    nodes: std.ArrayList(Index) = .empty,
    /// The top-level statement the constraint evaluated is in: locals are
    /// keyed by it.
    top: Index = undefined,
    /// Whether what the replay is in runs at most once: a module's top
    /// level, outside any function and any loop. A site made there is
    /// `once`.
    once_ctx: bool = false,
    /// Definite initialisation (*Amended 2026-10-03*): per object literal
    /// node, the keys it lacks that every call of the one function
    /// returning it writes before anything can read them. Kept across the
    /// runs of one `analyse`, which grow it.
    extra_init: KeyMap(NodeKey, std.ArrayList(u32)) = .empty,
    /// Keys the program writes on objects the pass cannot see, and whether
    /// it writes one it does not know there (slice 9's tag).
    unknown_props: std.ArrayList(u32) = .empty,
    unknown_any: bool = false,
    /// Per call node the initialiser of a `const` or `let`: the list it
    /// stands in and where (`writesAfter`).
    decl_call: KeyMap(NodeKey, DeclAt) = .empty,
    /// The top-level statements, in module order. The constraint being
    /// evaluated (`none` outside one, when a read registers nothing) and
    /// that evaluation's number; the dependency lists of vars and sites,
    /// in one pool, of constraints (`byConstraints`).
    stmts: std.ArrayList(StmtRef) = .empty,
    cur: u32 = none,
    walk: u32 = 0,
    next_walk: u32 = 0,
    deps: std.ArrayList(Dep) = .empty,
    /// Copy edges between vars and the field summaries of vars (`backend.md`
    /// §9, *The combined solver*, `copy` and `spread`): `edges` is the pool
    /// of every var's `succ` list, `edge_set` keeps each edge once, and
    /// `summaries` is indexed by `VSet.summary`. All of one fixpoint, in
    /// `tmp`.
    edges: std.ArrayList(Edge) = .empty,
    edge_set: KeyMap(EdgeKey, void) = .empty,
    /// The summary links that wait (`linkSummaries`), and whether one is
    /// being made; a stack the walks over summaries and vars share, each
    /// above where it found it (`summaryOf`, `summaryProp`, `setUnknown`,
    /// `setAnyWritten`).
    link_queue: std.ArrayList(SumLink) = .empty,
    linking: bool = false,
    work: std.ArrayList(u32) = .empty,
    summaries: std.ArrayList(Summary) = .empty,
    /// The vars whose field summary is another var's (`VSet.alias`, #568):
    /// per such var, the var it copies and what was asked of the summary
    /// through it, which its own summary takes when it splits (`split`);
    /// the lists of those, of the vars aliasing each var, and of the load
    /// cells each mark of a summary feeds (`Mark.load`). `split_epoch`
    /// counts the splits, which are what changes a var's summary
    /// (`resolve`). Of one fixpoint, in `tmp`.
    aliases: std.ArrayList(Alias) = .empty,
    alias_reqs: std.ArrayList(AliasReq) = .empty,
    alias_kids: std.ArrayList(AliasKid) = .empty,
    mark_loads: std.ArrayList(MarkLoad) = .empty,
    split_epoch: u32 = 0,
    /// The consumers shared fields fed (`Prop.outs`), and an object
    /// literal's own keys, sorted, while a spread in it is evaluated
    /// (`spreadSummary`). Of one fixpoint, in `tmp`.
    field_outs: std.ArrayList(FieldOut) = .empty,
    sharers: std.ArrayList(Sharer) = .empty,
    lit_keys: std.ArrayList(u32) = .empty,
    /// The site-set table (`backend.md` §9, *The combined solver — Cells*):
    /// every set a var holds, and every union and difference `Pts` makes, is
    /// one entry of it, content-addressed, so vars that hold the same sites
    /// hold one copy, and a batch that grows several of them alike makes one
    /// new set. Of one fixpoint, in `tmp` (`Sets`).
    sets: Sets = .{},
    /// The vars whose batch waits (`enqueue`), first in, first out from
    /// `pending_head`, each once (`VSet.queued`); and whether `drain` is
    /// running.
    pending: std.ArrayList(VarId) = .empty,
    pending_head: usize = 0,
    draining: bool = false,
    /// The sites a var took by no linking edge, each waiting to be folded
    /// into the var's field summary at the end of the sweep (`joinNow`,
    /// `foldWaiting`); of one fixpoint, in `tmp`.
    folds: std.ArrayList(Fold) = .empty,
    /// The load cells: those of a var's property by var and property, and
    /// those of any other object expression's read by its node.
    loads: std.ArrayList(Load) = .empty,
    load_cells: KeyMap(LoadKey, u32) = .empty,
    load_nodes: KeyMap(NodeKey, u32) = .empty,
    /// Per var, where it came from (`VarOrigin`): kept only under
    /// `Input.trace_largest`, and reset with `vars`.
    origins: std.ArrayList(VarOrigin) = .empty,
    /// How many sweeps the fixpoint took.
    sweeps: u32 = 0,
    /// Every site number, so that a value of one site is a slice of it.
    ones: []u32 = &.{},
    /// The order the first sweep replays the top-level statements in, by
    /// their place among every module's; empty for program order. Only a
    /// safety build's check sets one (`fixpoint`).
    order: []const u32 = &.{},
    /// The fixpoint by constraints (backend.md §9, *Amended 2026-10-12 —
    /// fact 3 by its constraints*). A constraint is one evaluation of the
    /// extraction (`PtsExtract`) — of an expression node, or of a
    /// statement's own transfer (`effect`) — numbered in its order; a node
    /// lowering shares between two expressions (`a.b` in `a.b.c` and
    /// `a.b.d`) is two. A change wakes the constraints that read what
    /// changed, each evaluated again alone (`evaluating`).
    evaluating: bool = false,
    /// Per constraint: its node and context, its value, the constraints
    /// whose values it reads (`inputs[span]`), the head of those that read
    /// its value (`links`) and of the guards a read is narrowed by
    /// (`narrows`).
    cons: std.ArrayList(Cons) = .empty,
    inputs: std.ArrayList(Read) = .empty,
    links: std.ArrayList(Link) = .empty,
    narrows: std.ArrayList(Narrow) = .empty,
    kills: std.ArrayList(u32) = .empty,
    /// Per module, the first of its nodes in `last`; per node, the last
    /// constraint that evaluated it in the first walk (`none`: none did),
    /// whose value the node keeps once the fixpoint is reached.
    base: []u32 = &.{},
    last: []u32 = &.{},
    /// The constraints waiting to be evaluated again, a bit each in 64-bit
    /// words, and how many. The words are 64 bits on every target, not a
    /// `usize`: `evaluateWaiting` takes them a word at a time, so the word
    /// is part of the order of evaluation, and on wasm32 a `usize` word
    /// gave another order than on x86-64 (`fast-compiler.md` §10, *A build
    /// with no threads*).
    waiting: []u64 = &.{},
    waiting_count: u32 = 0,

    const StmtRef = struct { module: u32, top: Index };
    const Dep = struct { stmt: u32, next: u32 };

    const DeclAt = struct { range: JsIr.SubRange, index: u32 };

    /// One guard a read may be narrowed by, as the first walk found it
    /// (`narrowed`): what it says, and the reads after its push, before the
    /// read, each of which kills it once its object is `top` — their object
    /// nodes, `kills[start..end]`. The next of the read's guards is `next`.
    const Narrow = struct { nul: bool, undef: bool, start: u32, end: u32, next: u32 };

    /// A constraint: the node it evaluates, in module `module`; the
    /// top-level statement the walk was in (locals are keyed by it); for a
    /// statement, the function site its `return` goes to; its value; its
    /// inputs, `inputs[start..end]`; the heads of its readers in `links`
    /// and of its guards in `narrows`.
    const Cons = struct {
        module: u32,
        node: Index,
        top: Index,
        func: u32,
        val: Val = .{},
        start: u32,
        end: u32,
        readers: u32 = none,
        narrow: u32 = none,
        /// A member read's load cell (`load`), in `loads`.
        load: u32 = none,
        /// Its guards came from the extraction (`replayWalk`) and are not yet
        /// confirmed: the walk noted them only when the read's object was
        /// not `top` at its first evaluation (`narrowed`).
        narrow_open: bool = false,
    };

    /// A load cell: the var a member read gives. Every read of one property
    /// of one var shares one cell (`load_cells`), as every spread of a var
    /// shares its summary, and it reads the var's field summary
    /// (`summaryLoad`): one copy edge from the summary's var of the
    /// property and one from its `any`, two per cell whatever the var
    /// holds, and the summary's marks say the rest — the read marks the
    /// property read on every site the var holds (`markRead`), is
    /// `undefined` when one of them lacks the key (`Mark.lacks`) and
    /// anything when one escaped or is no object (`Summary.escaped`,
    /// `unknown`). A read of any other object expression has the cell of
    /// its node (`load_nodes`), fed by a copy edge from the property's var,
    /// and from `any`, of every site the object holds, with `done` the union
    /// of the object's sites every evaluation saw, so the next links only
    /// what is new to all of them. Whether the read may be anything the var
    /// holds as one flag beside its sites (`VSet.uncapped`), since a var
    /// that is `top` escapes its sites and a read that may be anything
    /// does not. A read through an escaped object is `top` and links
    /// nothing, as `read` gives nothing more; a cell that linked a site
    /// before it escaped keeps its property values, which `propagate`
    /// escapes, so no consumer tells the two apart. The reference sweep of
    /// a safety build reads through the same cells.
    const Load = struct { out: VarId, done: SetId = 0, summary: bool = false };
    const LoadKey = struct { v: VarId, id: u32 };

    /// A node whose value a constraint reads, and the constraint that made
    /// that value.
    const Read = struct { node: Index, cons: u32 };

    /// A constraint that reads another's value.
    const Link = struct { cons: u32, next: u32 };

    /// What `combine` makes of each leaf but `ident`: its tag alone says.
    const literal_vals: [@typeInfo(Node.Tag).@"enum".field_names.len]Val = blk: {
        var table: [@typeInfo(Node.Tag).@"enum".field_names.len]Val = @splat(Val.top_val);
        for ([_]Node.Tag{ .number, .string, .template_chunk, .true_lit, .false_lit }) |t| table[@backingInt(t)] = Val.prim_val;
        table[@backingInt(Node.Tag.null_lit)] = Val.nul_val;
        table[@backingInt(Node.Tag.undefined_lit)] = Val.undef_val;
        break :blk table;
    };

    const VarId = u32;
    const LocalKey = struct { module: u32, top: u32, name: u32 };
    const NodeKey = struct { module: u32, node: u32 };
    const elem_prop: u32 = std.math.maxInt(u32) - 1;
    /// A var holding more sites than this is `top`, its sites escaped: the
    /// sets stay small and the analysis linear in the program. An interim
    /// value (#442 tracks removing the cap): past it the analysis loses
    /// precision silently, and the release optimiser keeps every field.
    const max_sites = 1000;

    /// `prim` is a primitive that is neither `null` nor `undefined`; `nul`
    /// and `undef` are those two (slice 4). Reading a property of either
    /// throws, so it contributes nothing to what the read may be.
    ///
    /// `sites` is a sorted set that is never changed in place: a join that
    /// adds a site takes the table's entry of the grown set (`Sets`) and
    /// leaves the old one as it was, so a `Val` that `view` handed out — a
    /// node's value in `vals`, an operand a walk holds while it evaluates
    /// the next — keeps the set it was read as. Growing the set in place shifted, moved or freed the
    /// memory such a value still pointed into: a call in a later operand
    /// joins a site into the very parameter an earlier operand read.
    /// `set` is the entry's id (*Cells*' `set: []SetId`), so an operation
    /// on what a var holds starts from the id and never looks it up.
    const VSet = struct {
        top: bool = false,
        prim: bool = false,
        nul: bool = false,
        undef: bool = false,
        sites: []const u32 = &.{},
        set: SetId = 0,
        /// What waits to join it (`enqueue`, `drain`): the flags and the
        /// sites joined since it was last taken from `pending`, as one
        /// batch, and the part of those sites that came by no linking edge,
        /// which its field summary folds (`joinNow`). `queued`: it is in
        /// `pending`.
        queued: bool = false,
        q_top: bool = false,
        q_prim: bool = false,
        q_nul: bool = false,
        q_undef: bool = false,
        q_set: SetId = 0,
        q_fold: SetId = 0,
        /// The constraints that read the var (`view`), and the walk that last
        /// added one.
        deps: u32 = none,
        seen: u32 = 0,
        /// The vars this one flows into (`copy`): the head of its list in
        /// `edges`. What joins this var joins each of them, as it arrives.
        succ: u32 = none,
        /// Its field summary (`summaryOf`), once a spread asked for one.
        summary: u32 = none,
        /// A read's var (`load`). `top` is one flag beside its sites, as it
        /// is in the value a read gives. The flag never escapes them or
        /// clears them, and `max_sites` does not apply. A local bound to a
        /// member read is uncapped too, so the read's `top` does not escape
        /// the objects. That local is `limited`, so `max_sites` still caps it.
        uncapped: bool = false,
        /// `max_sites` applies even when `uncapped` is set. A member binding
        /// keeps the read's objects beside `top`, and a points-to set past
        /// the cap still escapes (`makeTop`).
        limited: bool = false,
        /// Its field summary is that of the one var that copies into it
        /// (`Alias`, in `aliases`; #568): it holds what that var holds and
        /// nothing of its own, so the summary it would have is the other's,
        /// a homomorphism of a union of one. `summary` is `none` meanwhile.
        alias: u32 = none,
    };

    /// What `linksAcross` and `joinNow`'s filter read of a var, in a column
    /// of its own (`Pts.links_of`): a join reads it of every successor, and
    /// 8 bytes of each is all it needs (#577).
    const VLink = struct {
        /// Its declared-type filter (`backend.md` §9, *Declared-type
        /// filtering of fact 3*): a local's or a parameter's name's key, a
        /// function's return's its arrow's result key, `wild` for every
        /// other var and for a key in the wild set (`Pts.closedKey`). A var
        /// with a closed filter holds only the sites of that key and the
        /// wild ones (`joinNow`).
        allow: JsIr.RepKey = .wild,
        /// A site's own var: one of its properties, or its `any`. A copy
        /// edge from or to one links no summary (`linksAcross`): the
        /// summary that takes such a var's sites folds them (#562).
        site_var: bool = false,
        /// How many summaries deep the var is: 0 for a name's var, a load
        /// cell and a site's, one more than its summary's var for a
        /// summary's (`newSummary`, `addSumProp`), saturating. Only vars of
        /// depth 0 and 1 link summaries (`linksAcross`, #562).
        depth: u8 = 0,
    };

    /// What only making an edge, a summary or a shared field reads of a
    /// var, in a column of its own (`Pts.cold`), so that a join's walk over
    /// `VSet`s reads none of it (#577).
    const VCold = struct {
        /// The vars that flow into this one: the head of its list in
        /// `edges`, by `next_in`.
        pred: u32 = none,
        /// How many edges `succ` and `pred` list (`indexEdge`).
        succs: u32 = 0,
        preds: u32 = 0,
        /// A summary var's: the var the untouched fields of spread targets
        /// take where this one is the root of the copies their summary's
        /// var is (`shareField`); and those fields, listed while this var
        /// is a copy of one other var (`Sharer`, `unshare`).
        shared: VarId = none,
        sharers: u32 = none,
        /// The vars whose summary is this one's (`AliasKid`, in
        /// `alias_kids`): one that has split since is listed still, with
        /// `alias` `none`.
        kids: u32 = none,
        /// Found by `summaryOf`'s walk, and not yet given a summary or an
        /// alias.
        sum_pending: bool = false,
        /// The other end of the last edge `copy` made or found from this
        /// var, and into it: an edge is never taken away, so either is an
        /// edge that exists, found with no walk (#577).
        last_to: VarId = none,
        last_from: VarId = none,
    };

    /// A var whose summary is that of var `of` (`VSet.alias`): what was
    /// asked of the summary through it — load cells and summary links
    /// (`reqs`), and the constraints that spread it (`deps`, `seen`) — and
    /// the summary `resolve` found while `split_epoch` was `epoch`.
    const Alias = struct {
        of: VarId,
        reqs: u32 = none,
        deps: u32 = none,
        seen: u32 = 0,
        cache: u32 = none,
        epoch: u32 = 0,
    };
    /// What an aliased var's summary was asked: a load cell reading
    /// property `id` (`summaryLoad`), or to feed summary `a` (`linkFrom`).
    const AliasReq = struct { kind: enum(u8) { cell, link }, a: u32, id: u32 = none, next: u32 };
    const AliasKid = struct { v: VarId, next: u32 };
    const MarkLoad = struct { cell: u32, next: u32 };

    /// What a var's batch holds when `drain` takes it (`VSet.q_top` …).
    const Delta = struct {
        top: bool = false,
        prim: bool = false,
        nul: bool = false,
        undef: bool = false,
        set: SetId = 0,
        fold: SetId = 0,
    };

    /// A set's id in `Sets`: 0 is the empty set.
    const SetId = u32;
    /// The id of a `Val` built from a slice, not read from the table: its
    /// sites are looked up by content when an id is asked of it (`setOf`).
    const no_set: SetId = none;

    /// The site-set table. An entry is a sorted set of sites, stored once
    /// whichever var or operation made it first; it is never changed or
    /// freed while the fixpoint runs, so a value read before a join keeps
    /// the set it was read as. Ids number in solve order, and no fact
    /// depends on one: every consumer reads the sites, and an id only finds
    /// an entry or a result the table already made. The maps are only ever
    /// looked up, never walked, so where an entry lives in memory is no
    /// answer either.
    const Sets = struct {
        /// Per id, its sites (`items[0]`, the empty set, is a placeholder),
        /// and the next id whose sites hash alike (`by_hash`'s chains).
        items: std.ArrayList([]const u32) = .empty,
        chain: std.ArrayList(SetId) = .empty,
        /// Per content hash, the last id made with it.
        by_hash: KeyMap(SetHash, SetId) = .empty,
        /// Per site, the id of the set of it alone (0: not made yet): what
        /// a node that makes a site gives, found without a hash.
        single: std.ArrayList(SetId) = .empty,
        /// Per operation and operand ids, the result: a second var that
        /// holds what the first held and takes the same batch takes the
        /// same set, with no work. A filter (*Declared-type filtering of
        /// fact 3*) is one more operation, of a set and a key.
        ops: KeyMap(SetOpKey, SetId) = .empty,
        /// Where an operation's result is built before it is looked up.
        scratch: std.ArrayList(u32) = .empty,
    };
    const SetHash = struct { lo: u32, hi: u32, len: u32 };
    const SetOp = enum(u32) { join, difference, filter };
    const SetOpKey = struct { op: u32, a: SetId, b: SetId };

    /// A copy edge: `to ⊒ from`, kept while the fixpoint runs. A site or a
    /// flag that joins `from` after the edge was made is joined into `to`
    /// then — the difference, never the whole set again (`backend.md` §9,
    /// *The combined solver — The worklist*). `next` is the next edge out of
    /// `from`.
    const Edge = struct { from: VarId, to: VarId, next_out: u32, next_in: u32 };
    const EdgeKey = struct { from: VarId, to: VarId };

    /// The join of each property over every site a var holds, kept as one
    /// var per property and fed by copy edges from the sites' own property
    /// vars: what a spread of the var copies, and what a member read of the
    /// var reads (`summaryLoad`). Made the first time a spread or a read
    /// asks for it (`summaryOf`), and kept current as the var gains
    /// sites (`addSite`), as a site it holds gains a property (`prop`) or
    /// is written under an unknown key (`markAnyWritten`). So a spread
    /// records one dependency, on the summary's list of properties, in
    /// place of one per site and property, and a value that reaches one
    /// site's property flows to every spread and read of the var along the
    /// edges, without either being evaluated again.
    ///
    /// The sites a summary holds are those it folded (`sites`) and those of
    /// the summaries that feed it (`preds`), transitively: the sites its
    /// var holds. What a spread or a read does to every one of them is a
    /// mark on the summary (`whole`, `marks`), which the summary applies to
    /// the sites it folded, now and as it folds more, and passes to the
    /// summaries that feed it, whose sites are a subset of its own. A mark
    /// is per property, so a read of `x.p` marks `p` read and no other
    /// field: the release build drops a field no read reaches.
    const Summary = struct {
        /// Per property, sorted by id: the var joining that property of
        /// every site.
        props: std.ArrayList(SumProp) = .empty,
        /// The join of every site's `any`, and whether any site has been
        /// written under an unknown key.
        any: VarId,
        any_written: bool = false,
        /// Some site is no object: the spread's result may hold anything
        /// under any key (`writeAnyOne` with `top`), and a read is anything.
        unknown: bool = false,
        /// Some site escaped (`escapeSite`): a read is anything.
        escaped: bool = false,
        /// Read whole, by a spread (`markWhole`): every site's `all_read`.
        whole: bool = false,
        /// Per property read through the summary, sorted by id
        /// (`markRead`): every site has it, marked read.
        marks: std.ArrayList(Mark) = .empty,
        /// The sites folded into it one by one (`foldSite`).
        sites: std.ArrayList(u32) = .empty,
        /// The constraints that read the summary (`seeSummary`): woken when
        /// a property, `any_written` or `unknown` appears.
        deps: u32 = none,
        seen: u32 = 0,
        /// The summaries of the vars this one's var copies into
        /// (`linkSummaries`): each holds what this one holds; and those
        /// of the vars that copy into it, each of which feeds it.
        succs: std.ArrayList(u32) = .empty,
        preds: std.ArrayList(u32) = .empty,
        /// The var is `top` and capped: every site it held escaped, and
        /// every site that joins it escapes (`makeTop`). A spread of it
        /// writes `top` under every key, and a read of its result is `top`
        /// through `any`, so what its properties hold no consumer can see:
        /// nothing more is folded into it. An uncapped `top` var still
        /// holds its sites, and its summary folds them.
        dead: bool = false,
        /// The var it summarises.
        of: VarId = none,
    };

    const SumProp = struct { id: u32, vals: VarId };
    /// Site `site`, waiting to be folded into summary `sum` (`foldWaiting`).
    const Fold = struct { sum: u32, site: u32 };
    /// A consumer a property without a var of its own fed on behalf of one
    /// site (`copyField`): the var it copied into, and the next of the site
    /// property's list.
    const FieldOut = struct { to: VarId, next: u32 };
    /// A shared field (`Prop.from`) whose summary var is a copy of another,
    /// listed on each var of the chain of copies between the two
    /// (`VCold.sharers`).
    const Sharer = struct { site: u32, id: u32, next: u32 };
    /// A property read through a summary: some site it holds lacks the
    /// key, or has it with no initialiser, so the read may be `undefined`
    /// (`lacks`); and the load cells that read this property through the
    /// summary (`load`, the head of a list in `mark_loads`): the cell of the
    /// summary's var, and those of the vars whose summary this is
    /// (`VSet.alias`).
    const Mark = struct { id: u32, lacks: bool = false, load: u32 = none };
    const SumLink = struct { src: u32, dst: u32 };

    const Val = struct {
        top: bool = false,
        prim: bool = false,
        nul: bool = false,
        undef: bool = false,
        sites: []const u32 = &.{},
        /// `sites`' id when they are a table entry's own slice (`view`,
        /// `unionOf`); `no_set` for a value built from any other slice.
        set: SetId = no_set,

        /// What the program did not make, or cannot follow, may be anything:
        /// a host object, a primitive, `null` or `undefined` (research 52
        /// §3.3, TAJS's product). `top` is one component beside the other
        /// three and implies them, so that a read through a value that went
        /// `top` gives at least what the same read gave before it did — a
        /// read, and every other transfer function, is monotone, and the
        /// fixpoint is the same whatever order the units are walked in.
        const top_val: Val = .{ .top = true, .prim = true, .nul = true, .undef = true };
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
    ///
    /// A spread target's field that only the spread writes is a copy of the
    /// source summary's var of the property and nothing else (#564), so it
    /// has no var of its own: `vals` is the summary property's `shared` var,
    /// which every such field of every spread of that summary holds, and
    /// `from` is the summary's var it is fed from. What the field fed on the
    /// site's behalf — a summary that folded the site, a load cell that read
    /// it — is listed from `outs` (`copyField`), so that when something else
    /// writes the field it gets its own var, fed by `from` and feeding each of
    /// those (`ownField`). `from` is `none` for a field with a var of its own.
    const Prop = struct {
        id: u32,
        vals: VarId,
        read: bool = false,
        written: bool = false,
        init: bool = false,
        from: VarId = none,
        outs: u32 = none,
        /// Facts 4 and 5's cell of the property (`Spec.joinProp`): the join
        /// of every value written to it, whether a write has, and the
        /// combined solver's readers of it (`Solver.reads`).
        lat: Lat = .bot,
        lat_made: bool = false,
        lat_readers: u32 = none,
        /// A read of it stands in the program as the rewrite left it
        /// (`Spec.liveKeys`): what `keyUnread` asks after a rewrite.
        live_read: bool = false,
    };

    const Site = struct {
        kind: SiteKind,
        module: u32,
        node: Index,
        /// Its node's representation key, `wild` for none or one in the
        /// wild set (`Pts.closedKey`): a var's filter passes it when the
        /// two are equal or this is wild.
        key: JsIr.RepKey = .wild,
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
        /// Fact 5's cell of what a function returns (`Spec.joinRet`), as
        /// `Prop.lat`.
        ret_lat: Lat = .bot,
        ret_made: bool = false,
        ret_readers: u32 = none,
        /// An object literal that is the value of a `return` of this
        /// function site: its only way out (definite initialisation).
        fresh_fn: u32 = none,
        /// A function's: every call node that may call it, and whether
        /// something else does (the entry file, `new`).
        callers: std.ArrayList(NodeKey) = .empty,
        odd_caller: bool = false,
        /// What the program's own code writes on it, escaped or not: the
        /// keys, and whether under a key it does not know (slice 9's tag).
        prog_props: std.ArrayList(u32) = .empty,
        prog_any: bool = false,
        /// The constraints that read whether the site escaped or is written under
        /// an unknown key (`seeSite`), and the walk that last added one.
        deps: u32 = none,
        seen: u32 = 0,
        /// The constraints that read which properties it has (`seeProps`).
        prop_deps: u32 = none,
        prop_seen: u32 = 0,
        /// The summaries of the vars that hold it (`foldSite`): a property
        /// or an unknown-key write it gains later is folded into each.
        summaries: std.ArrayList(u32) = .empty,
        /// The load cells that read it (`load`): a read through it is
        /// anything once it escapes.
        loads: std.ArrayList(u32) = .empty,
    };

    fn init(s: *Spec) Pts {
        return .{ .s = s, .tmp = .init(s.gpa) };
    }

    fn deinit(p: *Pts) void {
        p.tmp.deinit();
        // The combined solver's constraints, which `Spec` keeps across
        // its analyses in the build's `gpa`.
        p.s.freeExtracts();
    }

    /// The compilation's arena: only for what outlives one fixpoint.
    inline fn arena(p: *Pts) Allocator {
        return p.s.arena;
    }

    /// The fixpoint's own arena (`tmp`).
    inline fn run(p: *Pts) Allocator {
        return p.tmp.allocator();
    }

    // ---- Sets ----------------------------------------------------------------

    fn newVar(p: *Pts) Allocator.Error!VarId {
        const id: VarId = @intCast(p.vars.items.len);
        try p.vars.append(p.tmp.column(.vars), .{});
        try p.links_of.append(p.tmp.column(.links_of), .{});
        try p.cold.append(p.tmp.column(.cold), .{});
        if (p.s.in.trace_largest) try p.origins.append(p.run(), .{ .kind = .global, .of = .global });
        return id;
    }

    /// Var `v` came from `o` (`Input.trace_largest`; nothing else).
    fn originAt(p: *Pts, v: VarId, o: VarOrigin) void {
        if (!p.s.in.trace_largest) return;
        var full = o;
        if (full.module != none and full.node != none) full.pos = p.s.mods[full.module].ir.pos(@fromBackingInt(full.node));
        p.origins.items[v] = full;
    }

    /// The origin of a var made of var `of`: a summary's, a load cell's.
    fn originOf(p: *const Pts, of: VarId, kind: VarOrigin.Role, id: u32) VarOrigin {
        var o = p.origins.items[of];
        o.of = o.kind;
        o.of_prop = o.prop;
        o.kind = kind;
        o.prop = id;
        return o;
    }

    /// Var `v` took a new set of `len` sites (`Stats.pts_max_set`); under
    /// `Input.trace_largest`, a set larger than any before is noted with
    /// where its var and each of its sites came from.
    fn countSet(p: *Pts, v: VarId, len: usize) Allocator.Error!void {
        const stats = &p.s.stats;
        if (len <= stats.pts_max_set) return;
        stats.pts_max_set = len;
        if (p.s.in.trace_largest) {
            var o = p.origins.items[v];
            o.sites = @intCast(len);
            stats.pts_largest = o;
            const held = p.vars.items[v].sites;
            const sites = try p.arena().alloc(SiteOrigin, held.len);
            for (sites, held) |*so, site| {
                const st = p.sites.items[site];
                so.* = .{ .module = st.module, .node = st.node.int(), .pos = p.s.mods[st.module].ir.pos(st.node) };
            }
            stats.pts_largest_sites = sites;
        }
    }

    /// What var `v` holds now; a read the constraint being evaluated depends on.
    inline fn view(p: *Pts, v: VarId) Allocator.Error!Val {
        const set = &p.vars.items[v];
        if (p.cur != none and set.seen != p.walk) {
            set.seen = p.walk;
            set.deps = try p.addDep(set.deps);
        }
        return .{ .top = set.top, .prim = set.prim, .nul = set.nul, .undef = set.undef, .sites = set.sites, .set = set.set };
    }

    /// The constraint being evaluated depends on whether site `site` escaped and
    /// whether it is written under an unknown key.
    inline fn seeSite(p: *Pts, site: u32) Allocator.Error!void {
        const st = &p.sites.items[site];
        if (p.cur == none or st.seen == p.walk) return;
        st.seen = p.walk;
        st.deps = try p.addDep(st.deps);
    }

    /// The constraint being evaluated depends on which properties site `site` has.
    inline fn seeProps(p: *Pts, site: u32) Allocator.Error!void {
        const st = &p.sites.items[site];
        if (p.cur == none or st.prop_seen == p.walk) return;
        st.prop_seen = p.walk;
        st.prop_deps = try p.addDep(st.prop_deps);
    }

    /// A dependency of the constraint being evaluated, pushed on list `head`.
    fn addDep(p: *Pts, head: u32) Allocator.Error!u32 {
        const at = p.deps.items.len;
        // `append`, written out: Zig's own backend inlines none of its calls.
        // Dependency chains are read only by this fixpoint. Reclaim the
        // pool with its constraints when the next fixpoint starts (#464).
        if (p.deps.capacity == at) try p.deps.ensureUnusedCapacity(p.tmp.column(.deps), 1);
        p.deps.items.len = at + 1;
        p.deps.items.ptr[at] = .{ .stmt = p.cur, .next = head };
        return @intCast(at);
    }

    /// Every constraint on dependency list `head` is evaluated again.
    fn wake(p: *Pts, head: u32) void {
        var d = head;
        while (d != none) {
            const dep = p.deps.items[d];
            // The first walk evaluates it again once it is done.
            p.reevaluate(dep.stmt);
            d = dep.next;
        }
    }

    /// Constraint `c` is evaluated again.
    inline fn reevaluate(p: *Pts, c: u32) void {
        const word = &p.waiting[c / 64];
        const bit = @as(u64, 1) << @intCast(c % 64);
        if (word.* & bit != 0) return;
        word.* |= bit;
        p.waiting_count += 1;
    }

    /// The last constraint that evaluated node `node` of module `mi`, or
    /// `none`: the one whose value a read of the node's value gets.
    inline fn lastOf(p: *const Pts, mi: u32, node: Index) u32 {
        return p.last[p.base[mi] + node.int()];
    }

    /// Var `v` changed: what read it is walked again, and re-reads it.
    fn varChanged(p: *Pts, v: VarId) void {
        const set = &p.vars.items[v];
        p.changed = true;
        p.wake(set.deps);
        set.deps = none;
        set.seen = 0;
    }

    /// Site `site` changed in a way `seeSite` covers.
    fn siteChanged(p: *Pts, site: u32) void {
        const st = &p.sites.items[site];
        p.changed = true;
        p.wake(st.deps);
        st.deps = none;
        st.seen = 0;
    }

    /// Site `site` joins var `v`.
    fn addSite(p: *Pts, v: VarId, site: u32) Allocator.Error!void {
        try p.enqueue(v, .{}, try p.single(site), false);
    }

    fn makeTop(p: *Pts, v: VarId) Allocator.Error!void {
        // A later `top` join into a var that already holds nothing escapes
        // its own sites at the call and does not walk the successors again.
        // A member binding is already `top` while it still holds sites, so
        // the same path has to escape those sites. `escapeSite` joins
        // `top` into every load cell linked from the site.
        if (p.vars.items[v].top and p.vars.items[v].sites.len == 0) return;
        // Its summary dies below, so it is its own first; and the summary
        // of a var aliasing it, which a var that is not `top` keeps, is
        // that var's own (#568).
        if (p.vars.items[v].alias != none) try p.split(v);
        if (p.cold.items[v].kids != none) try p.splitKids(v);
        const set = &p.vars.items[v];
        const became = !set.top;
        if (became) set.top = true;
        // `top` implies the other three (`Val.top_val`). The uncapped
        // join sets `top` first and may not have set them yet.
        if (!set.prim) set.prim = true;
        if (!set.nul) set.nul = true;
        if (!set.undef) set.undef = true;
        if (became or p.vars.items[v].sites.len != 0) p.varChanged(v);
        const held = p.vars.items[v].sites;
        p.vars.items[v].sites = &.{};
        p.vars.items[v].set = 0;
        for (held) |site| try p.escapeSite(site);
        if (p.vars.items[v].summary != none) p.summaries.items[p.vars.items[v].summary].dead = true;
        var e = p.vars.items[v].succ;
        while (e != none) : (e = p.edges.items[e].next_out) try p.enqueue(p.edges.items[e].to, Val.top_val, 0, true);
        try p.drain();
    }

    /// `val` joins var `v`. The join waits (`enqueue`): it is merged into
    /// the batch `v` already waits with, and `drain` carries it on — at the
    /// end of the constraint being evaluated (`combine`, `effect`), of a
    /// copy edge's making (`copy`), of `makeTop` and of each of the
    /// fixpoint's other steps, never inside a join (`backend.md` §9, *The
    /// combined solver — The worklist*). So a var that takes many sites in
    /// one evaluation passes them on as one batch.
    fn join(p: *Pts, v: VarId, val: Val) Allocator.Error!void {
        try p.enqueue(v, val, try p.setOf(val), false);
    }

    /// Flags `flags` and the sites of set `set` join var `v`'s batch, and
    /// `v` waits in `pending` unless it does already. `folded` says the
    /// sites arrive along a copy edge whose source's summary already feeds
    /// `v`'s (`summaryOf`), so they are not folded into it again. What `v`
    /// holds already is no batch: a flag it has, sites it holds, which it
    /// keeps (a var that goes `top` escapes what it held, as it escapes
    /// what joins it after).
    fn enqueue(p: *Pts, v: VarId, flags: Val, set: SetId, folded: bool) Allocator.Error!void {
        const x = &p.vars.items[v];
        var sites = set;
        if (sites != 0) {
            if (sites == x.set) {
                sites = 0;
            } else if (x.sites.len != 0) {
                const batch = p.setSites(sites);
                const held = if (batch.len == 1)
                    holdsSite(x.sites, batch[0])
                else
                    batch.len <= x.sites.len and containsSites(x.sites, batch);
                if (held) sites = 0;
            }
        }
        const new_flags = (flags.top and !x.top) or (flags.prim and !x.prim) or (flags.nul and !x.nul) or (flags.undef and !x.undef);
        if (!new_flags and sites == 0) return;
        if (flags.top) x.q_top = true;
        if (flags.prim) x.q_prim = true;
        if (flags.nul) x.q_nul = true;
        if (flags.undef) x.q_undef = true;
        if (sites != 0) {
            const all = try p.unionSets(x.q_set, sites);
            const fold = if (folded) x.q_fold else try p.unionSets(x.q_fold, sites);
            const y = &p.vars.items[v];
            y.q_set = all;
            y.q_fold = fold;
        }
        if (!p.vars.items[v].queued) {
            p.vars.items[v].queued = true;
            try p.pending.append(p.tmp.allocator(), v);
        }
    }

    /// Every batch that waits, first in, first out, and every batch that
    /// processing them makes: a var takes all that reached it since it was
    /// last taken in one `joinNow`.
    fn drain(p: *Pts) Allocator.Error!void {
        if (p.draining) return;
        p.draining = true;
        defer p.draining = false;
        while (p.pending_head < p.pending.items.len) {
            const v = p.pending.items[p.pending_head];
            p.pending_head += 1;
            const x = &p.vars.items[v];
            const d: Delta = .{ .top = x.q_top, .prim = x.q_prim, .nul = x.q_nul, .undef = x.q_undef, .set = x.q_set, .fold = x.q_fold };
            x.queued = false;
            x.q_top = false;
            x.q_prim = false;
            x.q_nul = false;
            x.q_undef = false;
            x.q_set = 0;
            x.q_fold = 0;
            try p.joinNow(v, d);
            // What was taken is not kept: the queue's memory follows what
            // waits, not what has been processed.
            if (p.pending_head >= 4096 and 2 * p.pending_head >= p.pending.items.len) {
                const rest = p.pending.items.len - p.pending_head;
                std.mem.copyForwards(VarId, p.pending.items[0..rest], p.pending.items[p.pending_head..]);
                p.pending.items.len = rest;
                p.pending_head = 0;
            }
        }
        p.pending.clearRetainingCapacity();
        p.pending_head = 0;
    }

    /// The transfer: batch `d` into `v`, and the difference on.
    fn joinNow(p: *Pts, v: VarId, d: Delta) Allocator.Error!void {
        p.s.stats.pts_joins += 1;
        const was_top = p.vars.items[v].top;
        var flags: Val = .{};
        if (d.top) {
            if (p.vars.items[v].uncapped) {
                if (!p.vars.items[v].top) {
                    p.vars.items[v].top = true;
                    flags.top = true;
                    p.varChanged(v);
                }
            } else try p.makeTop(v);
        }
        {
            const set = &p.vars.items[v];
            if (d.prim and !set.prim) {
                set.prim = true;
                flags.prim = true;
            }
            if (d.nul and !set.nul) {
                set.nul = true;
                flags.nul = true;
            }
            if (d.undef and !set.undef) {
                set.undef = true;
                flags.undef = true;
            }
        }
        const new_flags = flags.top or flags.prim or flags.nul or flags.undef;
        if (new_flags) p.varChanged(v);
        // Only the sites `v`'s declared type allows join it (*Declared-type
        // filtering of fact 3*); the flags pass whatever the filter.
        const sites = try p.filterSites(d.set, p.links_of.items[v].allow);
        if (p.vars.items[v].top and !p.vars.items[v].uncapped) {
            // A var that is `top` holds no list: what joins it escapes, and
            // what it copies into is `top` already.
            for (p.setSites(sites)) |site| try p.escapeSite(site);
            if (!new_flags and was_top) p.s.stats.pts_joins_empty += 1;
            return;
        }
        const old = p.vars.items[v].set;
        var added: SetId = 0;
        if (sites != 0 and sites != old) {
            const batch = p.setSites(sites);
            // One site, the common batch: a search of what `v` holds, and
            // the batch is its own difference.
            if (batch.len == 1) {
                if (!holdsSite(p.vars.items[v].sites, batch[0])) added = sites;
            } else added = try p.difference(sites, old);
        }
        if (added != 0) {
            // A new set, never the old one grown (`VSet`): the table's entry
            // of the union, which every var that held `old` and takes the
            // same batch shares (`Sets.ops`).
            const grown = try p.unionSets(old, added);
            p.vars.items[v].sites = p.setSites(grown);
            p.vars.items[v].set = grown;
            try p.countSet(v, p.vars.items[v].sites.len);
            p.varChanged(v);
            if (p.vars.items[v].sites.len > max_sites and (!p.vars.items[v].uncapped or p.vars.items[v].limited)) try p.makeTop(v);
        } else if (!new_flags) {
            p.s.stats.pts_joins_empty += 1;
            return;
        }
        var e = p.vars.items[v].succ;
        while (e != none) : (e = p.edges.items[e].next_out) {
            const to = p.edges.items[e].to;
            try p.enqueue(to, flags, added, p.linksAcross(v, to));
        }
        // What no linking edge brought is folded into `v`'s summary, at the
        // end of the sweep (`foldWaiting`).
        if (added == 0 or d.fold == 0) return;
        const fresh = p.setSites(added);
        const all = d.fold == d.set;
        const fold = p.setSites(d.fold);
        if (!all) {
            for (fresh) |site| {
                if (holdsSite(fold, site)) break;
            } else return;
        }
        // A site of its own: a var whose summary is another's has its own
        // from now on (#568), which folds what the other lacks.
        if (p.vars.items[v].alias != none) try p.split(v);
        if (p.vars.items[v].summary == none) return;
        const sum = p.vars.items[v].summary;
        for (fresh) |site| {
            if (all or holdsSite(fold, site)) try p.folds.append(p.tmp.allocator(), .{ .sum = sum, .site = site });
        }
    }

    /// Every site `joinNow` left to fold, folded (`foldSite`), with what
    /// each fold joins drained, and every fold those make: at the end of a
    /// sweep, after the constraints that wait were evaluated and after
    /// `propagate`, never while a join is applied (#565). So a var that a
    /// later evaluation, an escape or the cap makes `top` before the sweep
    /// ends has a dead summary by then, which `foldSite` folds nothing into:
    /// in the dashboard N=64, most of the edges into dead summaries were made
    /// one drain or more before the `top` that killed them arrived, not in
    /// the same batch (`joinNow` takes a batch's `top` before its sites).
    /// A fold waiting is one more step of a fair order: what it would have
    /// joined reaches the summary's vars, and wakes what read them, before
    /// the sweep asks whether the fixpoint is reached, so the least fixpoint
    /// is the same.
    fn foldWaiting(p: *Pts) Allocator.Error!void {
        while (p.folds.items.len != 0) {
            // As a fold at the join was, inside a drain: what the folds'
            // copy edges join waits in one queue, a var taking one batch
            // for all of them, and no join queues another fold meanwhile.
            {
                std.debug.assert(!p.draining);
                p.draining = true;
                defer p.draining = false;
                var i: usize = 0;
                while (i < p.folds.items.len) : (i += 1) try p.foldSite(p.folds.items[i].sum, p.folds.items[i].site);
            }
            p.folds.clearRetainingCapacity();
            try p.drain();
        }
    }

    /// The sites of set `a` a var whose filter is `allow` holds: those
    /// whose key is `allow` or wild (*Declared-type filtering of fact 3*).
    /// One more operation of the set table, made once per set and key
    /// (`Sets.ops`); `a` itself when every one passes.
    fn filterSites(p: *Pts, a: SetId, allow: JsIr.RepKey) Allocator.Error!SetId {
        if (allow == .wild or a == 0) return a;
        const key: SetOpKey = .{ .op = @backingInt(SetOp.filter), .a = a, .b = allow.int() };
        if (p.sets.ops.get(key)) |id| return id;
        const sites = p.setSites(a);
        const out = &p.sets.scratch;
        out.clearRetainingCapacity();
        try out.ensureTotalCapacity(p.tmp.allocator(), sites.len);
        for (sites) |site| {
            const k = p.sites.items[site].key;
            if (k == .wild or k == allow) out.appendAssumeCapacity(site);
        }
        const id = if (out.items.len == sites.len) a else if (out.items.len == 0) 0 else try p.intern(out.items);
        try p.sets.ops.put(p.tmp.allocator(), key, id);
        return id;
    }

    /// Whether a copy edge `from → to` links `to`'s field summary to
    /// `from`'s (*Declared-type filtering of fact 3*, *Summaries across a
    /// filter*): Σ(A ∪ B) = Σ(A) ∪ Σ(B) needs `to` to hold every site
    /// `from` holds, which it does when its filter is wild or the same.
    /// Otherwise `to`'s summary folds the sites it holds one by one.
    ///
    /// Two more kinds of edge link nothing (#562). Since a load cell can
    /// have a summary — a name is a copy of it (`copySource`) — a summary
    /// can be made of the summary's var of a property that a field read's
    /// cell copies, and of the vars that feed that one: the same
    /// property's vars of the summaries along the summary links, then the
    /// property's var of each site those summaries folded.
    ///
    /// - An edge from or to a site's own var (`VLink.site_var`): linking it
    ///   would make a summary of each such var, and of every var feeding
    ///   it — in an `inline` program, of every record the model was spread
    ///   into, for every field. The summary at the summaries' vars folds the
    ///   sites the field holds instead, once, and every cell and name that
    ///   copies the field shares it.
    /// - An edge from or to a var two or more summaries deep
    ///   (`VLink.depth`). A summary's vars are new vars, and a summary of one
    ///   has new vars of its own: where a function passes a field of its
    ///   parameter back to itself (`f(x.next)`), the parameter's summary
    ///   links the cell's, the cell's links that of the parameter's summary
    ///   var of `next`, which is fed by the cell's summary var of `next`,
    ///   whose summary would link that of the summary var of `next` of the
    ///   first, and so on without end. Folding at depth 2 ends it: every
    ///   summary is of a name's var, a cell, or one of their summaries'
    ///   vars, so there are as many as the program has names, reads and
    ///   properties.
    inline fn linksAcross(p: *const Pts, from: VarId, to: VarId) bool {
        const f = p.links_of.items[from];
        const t = p.links_of.items[to];
        if (f.site_var or t.site_var or f.depth > 1 or t.depth > 1) return false;
        return t.allow == .wild or t.allow == f.allow;
    }

    /// `k` as a filter or a site's key: itself when it is closed, `wild`
    /// when it is wild or in the build's wild set (`RepKeys.isWild`), and
    /// always `wild` without the build's keys.
    /// The filter of site `site`'s own var of property `id`: the field's
    /// key when the site's key is a closed record that has the field, wild
    /// otherwise. A value of a closed record type holds in each field a
    /// value of that field's type, and a site is keyed only where its type
    /// is closed and does not cross into JavaScript (`closedKey`).
    fn fieldFilter(p: *const Pts, site: u32, id: u32) JsIr.RepKey {
        const k = p.sites.items[site].key;
        if (k == .wild or id == none) return .wild;
        const fields = p.s.in.field_keys;
        var lo: usize = 0;
        var hi: usize = fields.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const f = fields[mid];
            if (f.record < k.int() or (f.record == k.int() and f.prop < id)) lo = mid + 1 else hi = mid;
        }
        if (lo == fields.len or fields[lo].record != k.int() or fields[lo].prop != id) return .wild;
        return p.closedKey(fields[lo].key);
    }

    fn closedKey(p: *const Pts, k: JsIr.RepKey) JsIr.RepKey {
        const keys = p.s.in.rep_keys orelse return .wild;
        return if (keys.isWild(k)) .wild else k;
    }

    /// The sites of set `a` that are not in set `b`: `a` itself when `b`
    /// is empty, nothing when `b` holds all of `a`, else the table's entry
    /// of the difference.
    fn difference(p: *Pts, a: SetId, b: SetId) Allocator.Error!SetId {
        if (a == 0 or b == 0) return a;
        if (a == b or containsSites(p.setSites(b), p.setSites(a))) return 0;
        return p.differenceSets(a, b);
    }

    // ---- The set table -------------------------------------------------------

    /// The id of the set `val` holds: its own, when it was read from the
    /// table (`Val.set`), else the entry of its sites.
    fn setOf(p: *Pts, val: Val) Allocator.Error!SetId {
        if (val.sites.len == 0) return 0;
        if (val.set != no_set) {
            if (std.debug.runtime_safety) {
                const own = p.setSites(val.set);
                std.debug.assert(own.ptr == val.sites.ptr and own.len == val.sites.len);
            }
            return val.set;
        }
        return p.idOf(val.sites);
    }

    /// The id of the set `sites` holds, made when the table has none.
    fn idOf(p: *Pts, sites: []const u32) Allocator.Error!SetId {
        if (sites.len == 0) return 0;
        if (sites.len == 1) return p.single(sites[0]);
        return p.intern(sites);
    }

    /// The id of the set of site `site` alone.
    fn single(p: *Pts, site: u32) Allocator.Error!SetId {
        const t = &p.sets.single;
        if (site >= t.items.len) {
            const old = t.items.len;
            try t.resize(p.tmp.allocator(), site + 1);
            @memset(t.items[old..], 0);
        }
        if (t.items[site] != 0) return t.items[site];
        const id = try p.intern(&.{site});
        p.sets.single.items[site] = id;
        return id;
    }

    /// A value of the sites of set `id`, which knows its id.
    fn valOf(p: *const Pts, id: SetId) Val {
        return .{ .sites = p.setSites(id), .set = id };
    }

    /// Whether `a` and `b` hold the same sites: by their ids when both
    /// know theirs, the table being content-addressed.
    fn sameSites(a: Val, b: Val) bool {
        if (a.set != no_set and b.set != no_set) return a.set == b.set;
        return std.mem.eql(u32, a.sites, b.sites);
    }

    fn setSites(p: *const Pts, id: SetId) []const u32 {
        if (id == 0) return &.{};
        return p.sets.items.items[id];
    }

    /// The entry of the sites `content` holds, made when the table has
    /// none: a copy, since `content` may be `scratch` or a caller's own
    /// memory. An id is found by content alone, so two entries never hold
    /// the same sites, and ids compare as their sets do (`sameSites`).
    fn intern(p: *Pts, content: []const u32) Allocator.Error!SetId {
        const a = p.tmp.allocator();
        const t = &p.sets;
        if (t.items.items.len == 0) {
            try t.items.append(a, &.{});
            try t.chain.append(a, none);
        }
        const gop = try t.by_hash.getOrPut(a, hashSites(content));
        var head: SetId = none;
        if (gop.found_existing) {
            head = gop.value_ptr.*;
            var at = head;
            while (at != none) : (at = t.chain.items[at]) {
                if (std.mem.eql(u32, t.items.items[at], content)) return at;
            }
        }
        const id: SetId = @intCast(t.items.items.len);
        gop.value_ptr.* = id;
        const stored = try a.dupe(u32, content);
        p.s.stats.pts_set_words += stored.len;
        try t.items.append(a, stored);
        try t.chain.append(a, head);
        return id;
    }

    fn hashSites(sites: []const u32) SetHash {
        var h: u64 = 0x9E3779B97F4A7C15;
        for (sites) |site| {
            h = (h ^ site) *% 0xFF51AFD7ED558CCD;
            h ^= h >> 29;
        }
        return .{ .lo = @truncate(h), .hi = @truncate(h >> 32), .len = @intCast(sites.len) };
    }

    /// The union of sets `a` and `b`, made once per pair (`Sets.ops`).
    fn unionSets(p: *Pts, a: SetId, b: SetId) Allocator.Error!SetId {
        if (a == b or b == 0) return a;
        if (a == 0) return b;
        const key: SetOpKey = .{ .op = @backingInt(SetOp.join), .a = @min(a, b), .b = @max(a, b) };
        if (p.sets.ops.get(key)) |id| return id;
        const x = p.setSites(a);
        const y = p.setSites(b);
        const out = &p.sets.scratch;
        out.clearRetainingCapacity();
        try out.ensureTotalCapacity(p.tmp.allocator(), x.len + y.len);
        var i: usize = 0;
        var j: usize = 0;
        while (i < x.len or j < y.len) {
            if (j == y.len or (i < x.len and x[i] < y[j])) {
                out.appendAssumeCapacity(x[i]);
                i += 1;
            } else if (i == x.len or y[j] < x[i]) {
                out.appendAssumeCapacity(y[j]);
                j += 1;
            } else {
                out.appendAssumeCapacity(x[i]);
                i += 1;
                j += 1;
            }
        }
        const id = try p.intern(out.items);
        try p.sets.ops.put(p.tmp.allocator(), key, id);
        return id;
    }

    /// The sites of set `a` that set `b` lacks, made once per pair
    /// (`Sets.ops`). Gaps in `b` are galloped over, as `containsSites`
    /// does.
    fn differenceSets(p: *Pts, a: SetId, b: SetId) Allocator.Error!SetId {
        if (a == 0 or b == 0) return a;
        if (a == b) return 0;
        const key: SetOpKey = .{ .op = @backingInt(SetOp.difference), .a = a, .b = b };
        if (p.sets.ops.get(key)) |id| return id;
        const x = p.setSites(a);
        const y = p.setSites(b);
        const out = &p.sets.scratch;
        out.clearRetainingCapacity();
        try out.ensureTotalCapacity(p.tmp.allocator(), x.len);
        var at: usize = 0;
        for (x) |wanted| {
            if (at < y.len and y[at] < wanted) {
                var lo = at + 1;
                var hi = lo;
                var step: usize = 1;
                while (hi < y.len and y[hi] < wanted) {
                    lo = hi + 1;
                    hi += @min(step, y.len - hi);
                    step = step +| step;
                }
                const limit = if (hi < y.len) hi + 1 else y.len;
                at = lo + lowerU32(y[lo..limit], wanted);
            }
            if (at < y.len and y[at] == wanted) {
                at += 1;
                continue;
            }
            out.appendAssumeCapacity(wanted);
        }
        const id = if (out.items.len == 0) 0 else try p.intern(out.items);
        try p.sets.ops.put(p.tmp.allocator(), key, id);
        return id;
    }

    // ---- Copy edges and field summaries ---------------------------------------

    /// `to ⊒ from`, from now on (the combined solver's `copy`): what `from`
    /// holds joins `to` now, and what joins `from` later joins `to` as it
    /// arrives (`joinNow`, `makeTop`). An edge is made once. When `to` has
    /// a field summary, `from`'s feeds it (`linkSummaries`), so the sites
    /// the edge carries are never folded one by one.
    fn copy(p: *Pts, from: VarId, to: VarId) Allocator.Error!void {
        if (from == to) return;
        // The edge each end made or found last (`VCold.last_to`): a fold
        // copies one var into the same summary's var site after site.
        if (p.cold.items[from].last_to == to or p.cold.items[to].last_from == from) return;
        if (p.hasEdge(from, to)) {
            p.cold.items[from].last_to = to;
            p.cold.items[to].last_from = from;
            return;
        }
        const at: u32 = @intCast(p.edges.items.len);
        try p.edges.append(p.tmp.column(.edges), .{ .from = from, .to = to, .next_out = p.vars.items[from].succ, .next_in = p.cold.items[to].pred });
        p.vars.items[from].succ = at;
        p.cold.items[to].pred = at;
        p.cold.items[from].last_to = to;
        p.cold.items[to].last_from = from;
        p.cold.items[from].succs += 1;
        p.cold.items[to].preds += 1;
        p.s.stats.pts_edges += 1;
        try p.indexEdge(from, to);
        // Across a stricter filter `to`'s summary folds what joins it, as
        // it does a site no edge brought (`linksAcross`).
        const links = p.linksAcross(from, to);
        // A second source: a var whose summary was its one source's has its
        // own now (#568), which `split` links to this source's too.
        if (p.vars.items[to].alias != none) {
            try p.split(to);
        } else if (links and p.vars.items[to].summary != none) try p.linkFrom(from, p.vars.items[to].summary);
        const set = p.vars.items[from];
        try p.enqueue(to, .{ .top = set.top, .prim = set.prim, .nul = set.nul, .undef = set.undef }, set.set, links);
        try p.drain();
        // A chain of copies a shared field ran through is one no longer.
        if (p.cold.items[to].preds == 2 and p.cold.items[to].sharers != none) try p.unshare(to);
    }

    /// How many edges of a var's list `hasEdge` walks before it asks
    /// `edge_set`.
    const short_edges = 8;

    /// `edge_set`, kept for what `hasEdge` asks it: every edge whose source
    /// has more than `short_edges` edges out and whose target more than
    /// `short_edges` in. The edge `from → to` was just made: it goes in when
    /// both lists are long, and when one of them has just become long, so do
    /// the edges of that list whose other end's list is long already. Most
    /// vars have one or two edges, and no edge of theirs is ever kept.
    fn indexEdge(p: *Pts, from: VarId, to: VarId) Allocator.Error!void {
        const a = p.tmp.allocator();
        const out = p.cold.items[from].succs;
        const in = p.cold.items[to].preds;
        if (out > short_edges and in > short_edges) try p.edge_set.put(a, .{ .from = from, .to = to }, {});
        if (out == short_edges + 1) {
            var e = p.vars.items[from].succ;
            while (e != none) : (e = p.edges.items[e].next_out) {
                const t = p.edges.items[e].to;
                if (p.cold.items[t].preds > short_edges) try p.edge_set.put(a, .{ .from = from, .to = t }, {});
            }
        }
        if (in == short_edges + 1) {
            var e = p.cold.items[to].pred;
            while (e != none) : (e = p.edges.items[e].next_in) {
                const f = p.edges.items[e].from;
                if (p.cold.items[f].succs > short_edges) try p.edge_set.put(a, .{ .from = f, .to = to }, {});
            }
        }
    }

    /// Whether the edge `from → to` exists: by the shorter of the two
    /// lists when one is short — a property's var has one or two sources —
    /// else by the set of the edges between long lists (`indexEdge`). The
    /// counts say which list is shorter before either is walked, so a
    /// summary's var, fed by every site it folded, is never walked for an
    /// edge from a site's var, which has one or two (#577).
    fn hasEdge(p: *Pts, from: VarId, to: VarId) bool {
        const in = p.cold.items[to].preds;
        const out = p.cold.items[from].succs;
        if (in <= out and in <= short_edges) {
            var e = p.cold.items[to].pred;
            while (e != none) : (e = p.edges.items[e].next_in) if (p.edges.items[e].from == from) return true;
            return false;
        }
        if (out <= short_edges) {
            var e = p.vars.items[from].succ;
            while (e != none) : (e = p.edges.items[e].next_out) if (p.edges.items[e].to == to) return true;
            return false;
        }
        if (in <= short_edges) {
            var e = p.cold.items[to].pred;
            while (e != none) : (e = p.edges.items[e].next_in) if (p.edges.items[e].from == from) return true;
            return false;
        }
        return p.edge_set.get(.{ .from = from, .to = to }) != null;
    }

    /// The field summary of var `v`, made when it has none yet: the summary
    /// of every var that copies into it feeds it, and the sites no copy
    /// edge brought are folded one by one. A summary is a homomorphism of
    /// the union — Σ(A ∪ B) = Σ(A) ∪ Σ(B) — so a var that is a copy of
    /// another costs one edge per property, not one per site and property.
    ///
    /// Every var that copies into `v`, transitively, and has no summary is
    /// given one first, by a walk over `work` and never by recursion: a chain
    /// of copies is as long as the program makes it. Then each is fed and
    /// folded, the farthest from `v` first, so that a summary has what its
    /// sources hold before it feeds the next. The order changes no fact.
    ///
    /// A var with one source, a copy edge that links summaries, and no site
    /// that source lacks gets no summary of its own: its summary is the
    /// source's (`aliasSummary`, #568), so a chain of such copies — every
    /// `browser-inline` handler's `const $before = $model` — costs nothing
    /// per property. Such a var is decided after its source, and is given a
    /// summary only when it cannot share one; the vars whose summary is
    /// made at once are those that never can, so a cycle of copies is fed
    /// as before, from summaries that all exist.
    fn summaryOf(p: *Pts, v: VarId) Allocator.Error!u32 {
        if (p.vars.items[v].summary != none) return p.vars.items[v].summary;
        if (p.vars.items[v].alias != none) return p.resolve(v);
        const a = p.tmp.allocator();
        const base = p.work.items.len;
        defer p.work.shrinkRetainingCapacity(base);
        try p.pendSummary(v);
        try p.work.append(a, v);
        var i = base;
        while (i < p.work.items.len) : (i += 1) {
            const x = p.work.items[i];
            // A dead summary is fed nothing (`Summary.dead`). An uncapped
            // `top` var still holds its sites, so its sources are fed too.
            if (p.vars.items[x].top and !p.vars.items[x].uncapped) continue;
            var e = p.cold.items[x].pred;
            while (e != none) : (e = p.edges.items[e].next_in) {
                const from = p.edges.items[e].from;
                const f = p.vars.items[from];
                if (f.summary != none or f.alias != none or p.cold.items[from].sum_pending or !p.linksAcross(from, x)) continue;
                try p.pendSummary(from);
                try p.work.append(a, from);
            }
        }
        var j = p.work.items.len;
        while (j > base) {
            j -= 1;
            const x = p.work.items[j];
            // Decided already, by a `summaryOf` a feed below called.
            if (!p.cold.items[x].sum_pending) continue;
            p.cold.items[x].sum_pending = false;
            if (p.vars.items[x].summary == none) {
                if (try p.aliasSummary(x)) continue;
                try p.newSummary(x);
            }
            // A source still to be decided is given its summary now, so
            // that feeding `x` never starts another walk.
            var e = p.cold.items[x].pred;
            while (e != none) : (e = p.edges.items[e].next_in) {
                const from = p.edges.items[e].from;
                const f = p.vars.items[from];
                if (p.cold.items[from].sum_pending and f.summary == none and p.linksAcross(from, x)) try p.newSummary(from);
            }
            try p.feedSummary(x);
        }
        return p.resolve(v);
    }

    /// Var `x`, found by `summaryOf`'s walk: given its summary now unless it
    /// may share its one source's (`aliasSummary`), which is decided once
    /// the source is.
    fn pendSummary(p: *Pts, x: VarId) Allocator.Error!void {
        p.cold.items[x].sum_pending = true;
        const vx = p.vars.items[x];
        if (p.cold.items[x].preds != 1 or (vx.top and !vx.uncapped)) try p.newSummary(x);
    }

    /// The summary var `v` has: its own, or that of the var it copies
    /// (`VSet.alias`), transitively, found again only after a split.
    fn resolve(p: *Pts, v: VarId) u32 {
        if (p.vars.items[v].summary != none) return p.vars.items[v].summary;
        const al = p.vars.items[v].alias;
        if (p.aliases.items[al].epoch == p.split_epoch and p.aliases.items[al].cache != none) return p.aliases.items[al].cache;
        var x = v;
        while (p.vars.items[x].summary == none) x = p.aliases.items[p.vars.items[x].alias].of;
        p.aliases.items[al].cache = p.vars.items[x].summary;
        p.aliases.items[al].epoch = p.split_epoch;
        return p.vars.items[x].summary;
    }

    /// Whether var `x`, which has no summary, takes that of its one source
    /// `u` (#568): `x` holds what `u` holds and nothing more — one edge in,
    /// which links summaries (`linksAcross`: a wild or equal filter, so `x`
    /// holds every site `u` does), and every site of `x` is one `u` holds —
    /// so the summary `x` would have, fed by `u`'s through one edge per
    /// property and folding nothing, holds what `u`'s holds. `u` is decided
    /// already, with a summary that is not dead, at `x`'s depth, so that
    /// the summary's vars link as `x`'s own would. Otherwise `false`, and
    /// `x` is given its own.
    fn aliasSummary(p: *Pts, x: VarId) Allocator.Error!bool {
        const vx = p.vars.items[x];
        if (p.cold.items[x].preds != 1 or (vx.top and !vx.uncapped)) return false;
        const u = p.edges.items[p.cold.items[x].pred].from;
        const vu = p.vars.items[u];
        if (p.cold.items[u].sum_pending or (vu.summary == none and vu.alias == none) or p.links_of.items[u].depth != p.links_of.items[x].depth or !p.linksAcross(u, x)) return false;
        const r = p.resolve(u);
        if (p.summaries.items[r].dead or !containsSites(vu.sites, vx.sites)) return false;
        const al: u32 = @intCast(p.aliases.items.len);
        try p.aliases.append(p.tmp.allocator(), .{ .of = u, .cache = r, .epoch = p.split_epoch });
        p.vars.items[x].alias = al;
        const kid: u32 = @intCast(p.alias_kids.items.len);
        try p.alias_kids.append(p.tmp.allocator(), .{ .v = x, .next = p.cold.items[u].kids });
        p.cold.items[u].kids = kid;
        return true;
    }

    /// Summary `dst` holds what var `u`'s summary holds (`linkSummaries`).
    /// When `u`'s is another var's (`VSet.alias`), the link is listed on
    /// `u`, before it is made, so that `u`'s own summary feeds `dst` too if
    /// `u` splits — while it is made, or later.
    fn linkFrom(p: *Pts, u: VarId, dst: u32) Allocator.Error!void {
        const src = try p.summaryOf(u);
        if (p.vars.items[u].alias != none) try p.addReq(p.vars.items[u].alias, .{ .kind = .link, .a = dst, .next = none });
        try p.linkSummaries(src, dst);
    }

    fn addReq(p: *Pts, al: u32, req: AliasReq) Allocator.Error!void {
        const at: u32 = @intCast(p.alias_reqs.items.len);
        var r = req;
        r.next = p.aliases.items[al].reqs;
        try p.alias_reqs.append(p.tmp.allocator(), r);
        p.aliases.items[al].reqs = at;
    }

    /// The constraint being evaluated spreads var `v`, whose summary may be
    /// another var's: it is evaluated again when `v`'s summary is its own
    /// (`split`).
    fn seeAlias(p: *Pts, v: VarId) Allocator.Error!void {
        const al = p.vars.items[v].alias;
        if (al == none or p.cur == none or p.aliases.items[al].seen == p.walk) return;
        p.aliases.items[al].seen = p.walk;
        const head = p.aliases.items[al].deps;
        p.aliases.items[al].deps = try p.addDep(head);
    }

    /// Var `x`, whose summary was another's, has its own from now on: a
    /// second source joined it, a site of its own, or it is about to be
    /// `top`. It is made as `summaryOf` makes one — linked to each source's
    /// summary, the sites none of them holds folded — and takes what was
    /// asked through `x`, and through every var whose summary is `x`'s,
    /// transitively, since theirs is now this one: the load cells that read
    /// it and the summaries it feeds are attached to it, and the constraints
    /// that spread it are evaluated again, reading it. They keep what they
    /// took from the old summary, which held a subset of what the new one
    /// holds — `x` held every site its source did, and so does every summary
    /// `x`'s is linked to — so no consumer holds more than it would have.
    fn split(p: *Pts, x: VarId) Allocator.Error!void {
        const al = p.vars.items[x].alias;
        p.vars.items[x].alias = none;
        p.split_epoch +%= 1;
        p.changed = true;
        try p.newSummary(x);
        try p.feedSummary(x);
        const sum = p.vars.items[x].summary;
        const a = p.tmp.allocator();
        const base = p.work.items.len;
        defer p.work.shrinkRetainingCapacity(base);
        try p.replay(al, sum);
        try p.work.append(a, x);
        while (p.work.items.len > base) {
            const y = p.work.pop().?;
            var k = p.cold.items[y].kids;
            while (k != none) : (k = p.alias_kids.items[k].next) {
                const kid = p.alias_kids.items[k].v;
                // Split since: its own summary has what it asked.
                if (p.vars.items[kid].alias == none) continue;
                try p.replay(p.vars.items[kid].alias, sum);
                try p.work.append(a, kid);
            }
        }
    }

    /// What was asked through alias `al`, asked of summary `sum`.
    fn replay(p: *Pts, al: u32, sum: u32) Allocator.Error!void {
        var r = p.aliases.items[al].reqs;
        while (r != none) : (r = p.alias_reqs.items[r].next) {
            const q = p.alias_reqs.items[r];
            switch (q.kind) {
                .cell => try p.summaryLoad(sum, q.id, q.a),
                .link => try p.linkSummaries(sum, q.a),
            }
        }
        const deps = p.aliases.items[al].deps;
        p.aliases.items[al].deps = none;
        p.aliases.items[al].seen = 0;
        p.wake(deps);
    }

    /// Var `v`'s summary is about to die (`makeTop`): each var whose
    /// summary is `v`'s has its own.
    fn splitKids(p: *Pts, v: VarId) Allocator.Error!void {
        var k = p.cold.items[v].kids;
        p.cold.items[v].kids = none;
        while (k != none) : (k = p.alias_kids.items[k].next) {
            const kid = p.alias_kids.items[k].v;
            if (p.vars.items[kid].alias != none) try p.split(kid);
        }
    }

    /// A summary for var `v`, empty: dead when `v` is `top` and capped.
    /// An uncapped `top` var still holds its sites. Its vars are
    /// `uncapped`, as a load cell's: a summary is a join a read or a spread
    /// passes on, not a place a value is held, and a cap there would escape
    /// sites no consumer's own var escapes — a read's cell holds what it
    /// reads beside `top`, and a spread's target holds the summary's sites
    /// and is capped itself.
    fn newSummary(p: *Pts, v: VarId) Allocator.Error!void {
        const id: u32 = @intCast(p.summaries.items.len);
        const any = try p.newVar();
        p.vars.items[any].uncapped = true;
        p.links_of.items[any].depth = p.links_of.items[v].depth +| 1;
        if (p.s.in.trace_largest) p.originAt(any, p.originOf(v, .summary_any, none));
        const escaped_top = p.vars.items[v].top and !p.vars.items[v].uncapped;
        try p.summaries.append(p.tmp.column(.summaries), .{ .any = any, .dead = escaped_top, .of = v });
        p.vars.items[v].summary = id;
    }

    /// Var `v`'s new summary, fed by the summaries of the vars that copy
    /// into `v`, and the sites none of them brought folded into it.
    fn feedSummary(p: *Pts, v: VarId) Allocator.Error!void {
        const id = p.vars.items[v].summary;
        if (p.summaries.items[id].dead) return;
        var e = p.cold.items[v].pred;
        while (e != none) : (e = p.edges.items[e].next_in) {
            const from = p.edges.items[e].from;
            if (p.linksAcross(from, v)) try p.linkFrom(from, id);
        }
        for (p.vars.items[v].sites) |site| {
            var covered = false;
            var f = p.cold.items[v].pred;
            while (f != none and !covered) : (f = p.edges.items[f].next_in) {
                if (!p.linksAcross(p.edges.items[f].from, v)) continue;
                const from = p.vars.items[p.edges.items[f].from].sites;
                covered = holdsSite(from, site);
            }
            if (!covered) try p.foldSite(id, site);
        }
    }

    /// Summary `dst` holds what summary `src` holds, now and later. A link
    /// waits in `link_queue`, as a join waits in `pending`, while another
    /// is being made: making one copies into summaries, and a copy may link
    /// two more, so that links nested by recursion as deep as a chain of
    /// summaries is long.
    fn linkSummaries(p: *Pts, src: u32, dst: u32) Allocator.Error!void {
        try p.link_queue.append(p.tmp.allocator(), .{ .src = src, .dst = dst });
        if (p.linking) return;
        p.linking = true;
        defer p.linking = false;
        while (p.link_queue.pop()) |l| try p.linkNow(l.src, l.dst);
    }

    fn linkNow(p: *Pts, src: u32, dst: u32) Allocator.Error!void {
        if (src == dst or p.summaries.items[dst].dead) return;
        for (p.summaries.items[src].succs.items) |s| if (s == dst) return;
        try p.summaries.items[src].succs.append(p.tmp.allocator(), dst);
        try p.summaries.items[dst].preds.append(p.tmp.allocator(), src);
        // Both lists are sorted by id, so each walk's next index in the
        // other is where its last ended (`indexAt`).
        var mark_at: usize = 0;
        var prop_at: usize = 0;
        var k: usize = 0;
        while (k < p.summaries.items[src].props.items.len) : (k += 1) {
            const sp = p.summaries.items[src].props.items[k];
            if (p.demandsAt(dst, sp.id, &mark_at)) try p.copy(sp.vals, try p.summaryPropAt(dst, sp.id, &prop_at));
        }
        try p.copy(p.summaries.items[src].any, p.summaries.items[dst].any);
        if (p.summaries.items[src].unknown) try p.setUnknown(dst);
        if (p.summaries.items[src].escaped) try p.setEscaped(dst);
        if (p.summaries.items[src].any_written) try p.setAnyWritten(dst);
        // What reads `dst` reads `src`'s sites, which are now `dst`'s.
        if (p.summaries.items[dst].whole) try p.markWhole(src);
        mark_at = 0;
        k = 0;
        while (k < p.summaries.items[dst].marks.items.len) : (k += 1) {
            const id = p.summaries.items[dst].marks.items[k].id;
            try p.markRead(src, id);
            if (p.findMarkAt(src, id, &mark_at).?.lacks) try p.setLacks(dst, id);
        }
    }

    /// Site `site`, now held by the var of summary `sum`: its properties
    /// and `any` copying into the summary's, and the summary's marks
    /// applied to it.
    fn foldSite(p: *Pts, sum: u32, site: u32) Allocator.Error!void {
        if (p.summaries.items[sum].dead) return;
        const a = p.tmp.allocator();
        const st = &p.sites.items[site];
        for (st.summaries.items) |s| if (s == sum) return;
        try st.summaries.append(a, sum);
        try p.summaries.items[sum].sites.append(a, site);
        if (p.summaries.items[sum].whole) p.markAllRead(site);
        if (p.sites.items[site].escaped) try p.setEscaped(sum);
        if (p.sites.items[site].kind != .object) {
            try p.setUnknown(sum);
            return;
        }
        // The site's properties, the summary's and its marks are each
        // sorted by id: a walk over one finds the next in another where it
        // found the last (`indexAt`), so a fold of a wide record searches
        // none of them (#577).
        var at: MarkHint = .{};
        var k: usize = 0;
        while (k < p.sites.items[site].props.items.len) : (k += 1) {
            const pr = p.sites.items[site].props.items[k];
            if (p.demandsAt(sum, pr.id, &at.mark)) try p.copyField(site, k, pr.id, try p.summaryPropAt(sum, pr.id, &at.sum));
        }
        try p.copy(p.sites.items[site].any, p.summaries.items[sum].any);
        if (p.sites.items[site].any_written) try p.setAnyWritten(sum);
        // A mark made before the site arrived; one made later reaches it
        // through `sites`.
        at = .{};
        k = 0;
        while (k < p.summaries.items[sum].marks.items.len) : (k += 1) {
            at.mark = k;
            try p.markSiteAt(sum, site, p.summaries.items[sum].marks.items[k].id, &at);
        }
    }

    /// Where `markSiteAt` expects the property it marks: in the site's
    /// properties, the summary's, and the summary's marks (`indexAt`).
    const MarkHint = struct { prop: usize = 0, sum: usize = 0, mark: usize = 0 };

    /// Site `site` read whole, as `readAll` marks: a function has no
    /// properties to read, and an escaped site is marked by `propagate`.
    fn markAllRead(p: *Pts, site: u32) void {
        const st = &p.sites.items[site];
        if (st.all_read or st.kind == .func or st.escaped) return;
        st.all_read = true;
        p.changed = true;
    }

    /// Summary `sum` read whole by a spread: every site it holds, now and
    /// later, is `all_read`, and the summary holds every property of each
    /// (`demands`). Passed to the summaries that feed it, by a walk over
    /// `work`.
    fn markWhole(p: *Pts, sum: u32) Allocator.Error!void {
        if (p.summaries.items[sum].whole) return;
        const a = p.tmp.allocator();
        const base = p.work.items.len;
        defer p.work.shrinkRetainingCapacity(base);
        try p.work.append(a, sum);
        while (p.work.items.len > base) {
            const s = p.work.pop().?;
            if (p.summaries.items[s].whole) continue;
            p.summaries.items[s].whole = true;
            // A dead summary is fed nothing (`Summary.dead`).
            const fed = !p.summaries.items[s].dead;
            var k: usize = 0;
            while (k < p.summaries.items[s].sites.items.len) : (k += 1) {
                const site = p.summaries.items[s].sites.items[k];
                p.markAllRead(site);
                if (!fed or p.sites.items[site].kind != .object) continue;
                var at: usize = 0;
                var j: usize = 0;
                while (j < p.sites.items[site].props.items.len) : (j += 1) {
                    const pr = p.sites.items[site].props.items[j];
                    try p.copyField(site, j, pr.id, try p.summaryPropAt(s, pr.id, &at));
                }
            }
            k = 0;
            while (k < p.summaries.items[s].preds.items.len) : (k += 1) {
                const pred = p.summaries.items[s].preds.items[k];
                var at: usize = 0;
                var j: usize = 0;
                while (fed and j < p.summaries.items[pred].props.items.len) : (j += 1) {
                    const sp = p.summaries.items[pred].props.items[j];
                    try p.copy(sp.vals, try p.summaryPropAt(s, sp.id, &at));
                }
                if (!p.summaries.items[pred].whole) try p.work.append(a, pred);
            }
        }
    }

    fn findMark(p: *const Pts, sum: u32, id: u32) ?*Mark {
        var at: usize = 0;
        return p.findMarkAt(sum, id, &at);
    }

    /// `findMark`, expecting `id` at `at.*` or just after it, which is left
    /// where `id` is or would go (`indexAt`).
    fn findMarkAt(p: *const Pts, sum: u32, id: u32, at: *usize) ?*Mark {
        const marks = p.summaries.items[sum].marks.items;
        at.* = indexAt(Mark, marks, id, at.*);
        return if (at.* < marks.len and marks[at.*].id == id) &marks[at.*] else null;
    }

    /// Where `id` is, or would go, in `items`, sorted by their `id`: `hint`
    /// or the index after it when one of them is that place — a walk in
    /// ascending order over another sorted list asks for the next id after
    /// the last it found, and a walk over sites asks for one id again — and
    /// else the binary search's answer, which is the same (#577).
    inline fn indexAt(comptime T: type, items: []const T, id: u32, hint: usize) usize {
        const at = @min(hint, items.len);
        if (at == items.len or items[at].id >= id) {
            if (at == 0 or items[at - 1].id < id) return at;
        } else if (at + 1 == items.len or items[at + 1].id >= id) return at + 1;
        return std.sort.lowerBound(T, items, id, struct {
            fn order(want: u32, item: T) std.math.Order {
                return std.math.order(want, item.id);
            }
        }.order);
    }

    fn orderMark(id: u32, m: Mark) std.math.Order {
        return std.math.order(id, m.id);
    }

    /// Property `id` read through summary `sum`: marked read on every site
    /// the summary holds, as `load` marks each site of the object it reads
    /// — the sites it folded, now and later (`foldSite`), and those of the
    /// summaries that feed it, which are marked in turn, by a walk over
    /// `work` — and joined from each into the summary's var of it
    /// (`demands`). A summary that has the mark has it in every summary
    /// that feeds it, so the walk stops at one marked already. Whether a
    /// site lacks the key (`Mark.lacks`) runs the other way, along `succs`
    /// (`setLacks`), and a summary marked here takes it from a feeder that
    /// had the mark before.
    fn markRead(p: *Pts, sum: u32, id: u32) Allocator.Error!void {
        if (p.findMark(sum, id) != null) return;
        const a = p.tmp.allocator();
        const base = p.work.items.len;
        defer p.work.shrinkRetainingCapacity(base);
        try p.work.append(a, sum);
        while (p.work.items.len > base) {
            const s = p.work.pop().?;
            if (p.findMark(s, id) != null) continue;
            const marks = &p.summaries.items[s].marks;
            try marks.insert(a, std.sort.lowerBound(Mark, marks.items, id, orderMark), .{ .id = id });
            var k: usize = 0;
            while (k < p.summaries.items[s].preds.items.len) : (k += 1) {
                const pred = p.summaries.items[s].preds.items[k];
                if (p.findMark(pred, id)) |m| {
                    if (m.lacks) try p.setLacks(s, id);
                } else try p.work.append(a, pred);
                // What the feeder holds of it already; what it gains
                // later reaches `s` along the link (`summaryProp`).
                if (!p.summaries.items[s].dead) if (p.findSumProp(pred, id)) |v| try p.copy(v, try p.summaryProp(s, id));
            }
            var at: MarkHint = .{};
            k = 0;
            while (k < p.summaries.items[s].sites.items.len) : (k += 1) try p.markSiteAt(s, p.summaries.items[s].sites.items[k], id, &at);
        }
    }

    /// Property `id` of site `site`, which summary `sum` folded, read: made
    /// when it is new, as `load` makes it, and joined into the summary's
    /// var of it. A site that escaped, or is no object, makes the read
    /// anything through the summary's flags, and is not marked, as `load`
    /// marks no such site.
    ///
    /// `at` is where a walk over the summary's marks, or over its sites,
    /// expects the property in each list it searches (`MarkHint`).
    fn markSiteAt(p: *Pts, sum: u32, site: u32, id: u32, at: *MarkHint) Allocator.Error!void {
        const st = &p.sites.items[site];
        if (st.kind != .object) return;
        const fed = !p.summaries.items[sum].dead;
        if (st.escaped) {
            // What it held is joined as a whole read joins it; the read is
            // anything all the same.
            if (fed) if (p.findProp(site, id) != null) try p.copyField(site, none, id, try p.summaryPropAt(sum, id, &at.sum));
            return;
        }
        const k = try p.propAtHint(site, id, &at.prop);
        const pr = &p.sites.items[site].props.items[k];
        if (!pr.read) {
            pr.read = true;
            p.changed = true;
        }
        const has_init = pr.init;
        if (fed) try p.copyField(site, k, id, try p.summaryPropAt(sum, id, &at.sum));
        if (!has_init) try p.setLacksAt(sum, id, &at.mark);
    }

    /// A site summary `sum` holds lacks property `id`, which it is read
    /// for: so does every summary it feeds that is read for it, and a read
    /// of it may be `undefined`. A walk over `work`.
    fn setLacks(p: *Pts, sum: u32, id: u32) Allocator.Error!void {
        var at: usize = 0;
        return p.setLacksAt(sum, id, &at);
    }

    /// `setLacks`, `sum`'s mark expected at `at.*` (`indexAt`). A mark that
    /// lacks the key already has passed it on: the common case of a fold
    /// of a site of another record, found with no search.
    fn setLacksAt(p: *Pts, sum: u32, id: u32, at: *usize) Allocator.Error!void {
        const first = p.findMarkAt(sum, id, at) orelse return;
        if (first.lacks) return;
        const a = p.tmp.allocator();
        const base = p.work.items.len;
        defer p.work.shrinkRetainingCapacity(base);
        try p.work.append(a, sum);
        while (p.work.items.len > base) {
            const s = p.work.pop().?;
            const m = p.findMark(s, id) orelse continue;
            if (m.lacks) continue;
            m.lacks = true;
            try p.joinCells(m.load, Val.undef_val);
            for (p.summaries.items[s].succs.items) |succ| try p.work.append(a, succ);
        }
    }

    /// Summary `sum`, and every summary it feeds, holds a site that
    /// escaped: a read through it is anything. As `setUnknown` walks.
    fn setEscaped(p: *Pts, sum: u32) Allocator.Error!void {
        if (p.summaries.items[sum].escaped) return;
        const a = p.tmp.allocator();
        const base = p.work.items.len;
        defer p.work.shrinkRetainingCapacity(base);
        try p.work.append(a, sum);
        while (p.work.items.len > base) {
            const s = p.work.pop().?;
            if (p.summaries.items[s].escaped) continue;
            p.summaries.items[s].escaped = true;
            try p.topLoads(s);
            for (p.summaries.items[s].succs.items) |succ| if (!p.summaries.items[succ].escaped) try p.work.append(a, succ);
        }
    }

    /// Every read of summary `sum` is anything.
    fn topLoads(p: *Pts, sum: u32) Allocator.Error!void {
        var k: usize = 0;
        while (k < p.summaries.items[sum].marks.items.len) : (k += 1) {
            try p.joinCells(p.summaries.items[sum].marks.items[k].load, Val.top_val);
        }
    }

    /// `val` joins every load cell of a mark's list, from `head`.
    fn joinCells(p: *Pts, head: u32, val: Val) Allocator.Error!void {
        var c = head;
        while (c != none) : (c = p.mark_loads.items[c].next) try p.join(p.loads.items[p.mark_loads.items[c].cell].out, val);
    }

    /// Load cell `li` reads property `id` of the var of summary `sum`:
    /// one copy edge from the summary's var of the property, made when a
    /// site gains it (`addSumProp`), and one from its `any`; the property
    /// marked read on every site (`markRead`); `undefined` when one lacks
    /// it; anything when one escaped or is no object, or when the var is
    /// `top`.
    fn summaryLoad(p: *Pts, sum: u32, id: u32, li: u32) Allocator.Error!void {
        p.loads.items[li].summary = true;
        const out = p.loads.items[li].out;
        try p.markRead(sum, id);
        const m = p.findMark(sum, id).?;
        const at: u32 = @intCast(p.mark_loads.items.len);
        try p.mark_loads.append(p.tmp.allocator(), .{ .cell = li, .next = m.load });
        m.load = at;
        const lacks = m.lacks;
        if (p.findSumProp(sum, id)) |v| try p.copy(v, out);
        try p.copy(p.summaries.items[sum].any, out);
        const sm = p.summaries.items[sum];
        if (sm.dead or sm.escaped or sm.unknown) try p.join(out, Val.top_val);
        if (lacks) try p.join(out, Val.undef_val);
    }

    /// Load cell `li` reads property `id` of var `v` through `v`'s summary
    /// (`summaryLoad`). When that is another var's (`VSet.alias`), the cell
    /// is listed on `v` before it reads: `v` may split while it does, and
    /// `split` then has the cell read `v`'s own.
    fn nameLoad(p: *Pts, v: VarId, id: u32, li: u32) Allocator.Error!void {
        const sum = try p.summaryOf(v);
        if (p.vars.items[v].alias != none) try p.addReq(p.vars.items[v].alias, .{ .kind = .cell, .a = li, .id = id, .next = none });
        try p.summaryLoad(sum, id, li);
    }

    /// Whether summary `sum` holds property `id` of its sites: every
    /// property when a spread reads it whole, else only those a read marked.
    /// What no spread and no read of the summary asks for is never joined,
    /// so a var read for one field of a wide record costs one edge per
    /// site, not one per site and field. A summary that holds a property
    /// has it in every summary that feeds it, since the marks pass to them.
    fn demands(p: *const Pts, sum: u32, id: u32) bool {
        return p.summaries.items[sum].whole or p.findMark(sum, id) != null;
    }

    /// `demands`, the mark expected at `at.*` (`findMarkAt`).
    inline fn demandsAt(p: *const Pts, sum: u32, id: u32, at: *usize) bool {
        return p.summaries.items[sum].whole or p.findMarkAt(sum, id, at) != null;
    }

    /// The summary's var for property `id`, made when it is new: what read
    /// the summary reads the new property too, and the summaries this one
    /// feeds that hold it (`demands`) get the property as well — each made
    /// there in its turn, by a walk over `work` and never by recursion
    /// along the summaries' links.
    fn summaryProp(p: *Pts, sum: u32, id: u32) Allocator.Error!VarId {
        var at: usize = 0;
        return p.summaryPropAt(sum, id, &at);
    }

    /// `summaryProp`, the property expected at `at.*` or just after it in
    /// the summary's, which is left where it is (`indexAt`).
    fn summaryPropAt(p: *Pts, sum: u32, id: u32, at: *usize) Allocator.Error!VarId {
        const props = p.summaries.items[sum].props.items;
        at.* = indexAt(SumProp, props, id, at.*);
        if (at.* < props.len and props[at.*].id == id) return props[at.*].vals;
        const v = try p.addSumPropAt(sum, id, at.*);
        if (p.summaries.items[sum].succs.items.len == 0) return v;
        const a = p.tmp.allocator();
        const base = p.work.items.len;
        defer p.work.shrinkRetainingCapacity(base);
        try p.work.append(a, sum);
        while (p.work.items.len > base) {
            const s = p.work.pop().?;
            const from = p.findSumProp(s, id).?;
            var k: usize = 0;
            while (k < p.summaries.items[s].succs.items.len) : (k += 1) {
                const succ = p.summaries.items[s].succs.items[k];
                // A summary that does not hold the property feeds none
                // that does (`demands`).
                if (!p.demands(succ, id)) continue;
                const theirs = p.summaries.items[succ].props.items;
                const j = std.sort.lowerBound(SumProp, theirs, id, orderSumProp);
                const to = if (j < theirs.len and theirs[j].id == id) theirs[j].vals else made: {
                    const made = try p.addSumPropAt(succ, id, j);
                    try p.work.append(a, succ);
                    break :made made;
                };
                try p.copy(from, to);
            }
        }
        return v;
    }

    fn findSumProp(p: *const Pts, sum: u32, id: u32) ?VarId {
        const props = p.summaries.items[sum].props.items;
        const at = std.sort.lowerBound(SumProp, props, id, orderSumProp);
        return if (at < props.len and props[at].id == id) props[at].vals else null;
    }

    /// A new var for property `id` of summary `sum`, `uncapped` as its
    /// `any` is (`newSummary`): what read the summary reads it too, and the
    /// load cell of the property, if one reads it, takes its edge from it.
    fn addSumProp(p: *Pts, sum: u32, id: u32) Allocator.Error!VarId {
        return p.addSumPropAt(sum, id, std.sort.lowerBound(SumProp, p.summaries.items[sum].props.items, id, orderSumProp));
    }

    /// `addSumProp`, `at` the place of `id` in the summary's properties.
    fn addSumPropAt(p: *Pts, sum: u32, id: u32, at: usize) Allocator.Error!VarId {
        const v = try p.newVar();
        p.vars.items[v].uncapped = true;
        p.links_of.items[v].depth = p.links_of.items[p.summaries.items[sum].of].depth +| 1;
        if (p.s.in.trace_largest) p.originAt(v, p.originOf(p.summaries.items[sum].of, .summary_prop, id));
        try p.summaries.items[sum].props.insert(p.tmp.allocator(), at, .{ .id = id, .vals = v });
        p.summaryChanged(sum);
        if (p.findMark(sum, id)) |m| {
            var c = m.load;
            while (c != none) : (c = p.mark_loads.items[c].next) try p.copy(v, p.loads.items[p.mark_loads.items[c].cell].out);
        }
        return v;
    }

    fn orderSumProp(id: u32, pr: SumProp) std.math.Order {
        return std.math.order(id, pr.id);
    }

    /// Summary `sum`, and every summary it feeds, may hold anything under
    /// any key: a walk over `work`, not a recursion along the links.
    fn setUnknown(p: *Pts, sum: u32) Allocator.Error!void {
        if (p.summaries.items[sum].unknown) return;
        const a = p.tmp.allocator();
        const base = p.work.items.len;
        defer p.work.shrinkRetainingCapacity(base);
        try p.work.append(a, sum);
        while (p.work.items.len > base) {
            const s = p.work.pop().?;
            if (p.summaries.items[s].unknown) continue;
            p.summaries.items[s].unknown = true;
            p.summaryChanged(s);
            try p.topLoads(s);
            for (p.summaries.items[s].succs.items) |succ| if (!p.summaries.items[succ].unknown) try p.work.append(a, succ);
        }
    }

    /// Summary `sum`, and every summary it feeds, has a site written under
    /// an unknown key: as `setUnknown` walks.
    fn setAnyWritten(p: *Pts, sum: u32) Allocator.Error!void {
        if (p.summaries.items[sum].any_written) return;
        const a = p.tmp.allocator();
        const base = p.work.items.len;
        defer p.work.shrinkRetainingCapacity(base);
        try p.work.append(a, sum);
        while (p.work.items.len > base) {
            const s = p.work.pop().?;
            if (p.summaries.items[s].any_written) continue;
            p.summaries.items[s].any_written = true;
            p.summaryChanged(s);
            for (p.summaries.items[s].succs.items) |succ| if (!p.summaries.items[succ].any_written) try p.work.append(a, succ);
        }
    }

    /// The constraint being evaluated depends on summary `sum`'s properties,
    /// `any_written` and `unknown`.
    fn seeSummary(p: *Pts, sum: u32) Allocator.Error!void {
        const sm = &p.summaries.items[sum];
        if (p.cur == none or sm.seen == p.walk) return;
        sm.seen = p.walk;
        sm.deps = try p.addDep(sm.deps);
    }

    fn summaryChanged(p: *Pts, sum: u32) void {
        const sm = &p.summaries.items[sum];
        p.changed = true;
        p.wake(sm.deps);
        sm.deps = none;
        sm.seen = 0;
    }

    /// Site `site` has been written under a key the pass does not know.
    fn markAnyWritten(p: *Pts, site: u32) Allocator.Error!void {
        const st = &p.sites.items[site];
        if (st.any_written) return;
        st.any_written = true;
        p.siteChanged(site);
        for (p.sites.items[site].summaries.items) |sum| try p.setAnyWritten(sum);
    }

    /// Whether a guard may narrow what ident node `node` reads (`narrowed`):
    /// a copy of it is not a copy of its var then.
    fn maybeNarrowed(p: *Pts, mi: u32, node: Index) bool {
        const c = p.lastOf(mi, node);
        return c == none or p.cons.items[c].narrow != none;
    }

    /// The var whose value node `node` is, when a binding, a call argument
    /// or a `return` of it can be a copy edge from that var (`copy`) and not
    /// a join of what it is now (#562): a name's var, and a member read's
    /// load cell (`load`), whose view is what the read gives — so every
    /// name bound to, or passed, one read of one property of one var shares
    /// the cell's field summary. Null when a guard may narrow the read — a
    /// copy carries every flag the source has — and for any other
    /// expression, whose value is joined.
    ///
    /// A cell's var is `uncapped`: `top` is a flag beside its sites. A copy
    /// carries the flag as a join of the read's value does, so a capped
    /// target is made `top` (`makeTop`) and escapes the sites, now or when
    /// the cell turns `top`, and an uncapped one holds both.
    fn copySource(p: *Pts, mi: u32, node: Index) Allocator.Error!?VarId {
        const ir = p.s.mods[mi].ir;
        const d = ir.data(node);
        switch (ir.tag(node)) {
            .ident => {
                if (p.maybeNarrowed(mi, node)) return null;
                return try p.nodeVar(mi, node, @fromBackingInt(@intCast(d.lhs)));
            },
            .member => {
                if (p.maybeNarrowed(mi, node)) return null;
                // The read was walked: its cell exists, found as `load`
                // found it — by the object's var and the property for a
                // name, by the node for any other object expression.
                const object: Index = @fromBackingInt(@intCast(d.lhs));
                const li = if (ir.tag(object) == .ident)
                    p.load_cells.get(.{ .v = try p.nodeVar(mi, object, @fromBackingInt(@intCast(ir.data(object).lhs))), .id = p.propId(mi, @fromBackingInt(@intCast(d.rhs))) })
                else
                    p.load_nodes.get(.{ .module = mi, .node = node.int() });
                return if (li) |l| p.loads.items[l].out else null;
            },
            else => return null,
        }
    }

    fn escapeSite(p: *Pts, site: u32) Allocator.Error!void {
        const st = &p.sites.items[site];
        if (st.escaped) return;
        st.escaped = true;
        p.siteChanged(site);
        var k: usize = 0;
        while (k < p.sites.items[site].loads.items.len) : (k += 1) try p.join(p.loads.items[p.sites.items[site].loads.items[k]].out, Val.top_val);
        // A read through a summary that holds it is anything too.
        k = 0;
        while (k < p.sites.items[site].summaries.items.len) : (k += 1) try p.setEscaped(p.sites.items[site].summaries.items[k]);
    }

    fn escape(p: *Pts, val: Val) Allocator.Error!void {
        for (val.sites) |site| try p.escapeSite(site);
    }

    fn unionOf(p: *Pts, a: Val, b: Val) Allocator.Error!Val {
        const flags: Val = .{ .top = a.top or b.top, .prim = a.prim or b.prim, .nul = a.nul or b.nul, .undef = a.undef or b.undef };
        if (a.sites.len == 0) return .{ .top = flags.top, .prim = flags.prim, .nul = flags.nul, .undef = flags.undef, .sites = b.sites, .set = b.set };
        if (b.sites.len == 0) return .{ .top = flags.top, .prim = flags.prim, .nul = flags.nul, .undef = flags.undef, .sites = a.sites, .set = a.set };
        // Site slices are immutable snapshots. A settled union can share
        // the containing operand instead of retaining another identical
        // snapshot on every fixpoint reevaluation (#464).
        const large = if (a.sites.len >= b.sites.len) a else b;
        const small = if (a.sites.len >= b.sites.len) b else a;
        if ((large.set != no_set and large.set == small.set) or containsSites(large.sites, small.sites))
            return .{ .top = flags.top, .prim = flags.prim, .nul = flags.nul, .undef = flags.undef, .sites = large.sites, .set = large.set };
        const id = try p.unionSets(try p.setOf(a), try p.setOf(b));
        return .{ .top = flags.top, .prim = flags.prim, .nul = flags.nul, .undef = flags.undef, .sites = p.setSites(id), .set = id };
    }

    /// Both operands are sorted sets. Adjacent matches walk once; gaps
    /// get an exponential bracket and binary search, so sparse properties
    /// do not rescan the broad result of a computed read on every union.
    fn containsSites(large: []const u32, small: []const u32) bool {
        var at: usize = 0;
        for (small) |wanted| {
            if (at == large.len) return false;
            if (large[at] < wanted) {
                var lo = at + 1;
                var hi = lo;
                var step: usize = 1;
                while (hi < large.len and large[hi] < wanted) {
                    lo = hi + 1;
                    hi += @min(step, large.len - hi);
                    step = step +| step;
                }
                const limit = if (hi < large.len) hi + 1 else large.len;
                at = lo + lowerU32(large[lo..limit], wanted);
            }
            if (at == large.len or large[at] != wanted) return false;
            at += 1;
        }
        return true;
    }

    /// Whether `sites`, sorted, holds `site`: no search for a site past the
    /// last, which a site made after all of them is (#577).
    inline fn holdsSite(sites: []const u32, site: u32) bool {
        if (sites.len == 0 or site > sites[sites.len - 1]) return false;
        const at = lowerU32(sites, site);
        return sites[at] == site;
    }

    /// `std.sort.lowerBound` over `u32`s, without its call of an order
    /// function per step, which a release build does not inline: the
    /// first index whose item is not less than `x`.
    inline fn lowerU32(items: []const u32, x: u32) usize {
        if (items.len == 0) return 0;
        var base: usize = 0;
        var n = items.len;
        while (n > 1) {
            const half = n / 2;
            if (items[base + half - 1] < x) base += half;
            n -= half;
        }
        return base + @intFromBool(items[base] < x);
    }

    fn orderU32(a: u32, b: u32) std.math.Order {
        return std.math.order(a, b);
    }

    // ---- Names and sites -----------------------------------------------------

    /// The var of local `n` of the top-level statement the walk is in,
    /// made the first time it is asked for.
    /// Per name of a module: the identifier node that a `const` of the name
    /// is bound to, when that `const` is the name's only declaration of any
    /// kind in the module (a binding, a parameter, a loop's, a catch's), or
    /// `none` (#796, the copy-only locals of fact 3's input). Every node
    /// counts, live or not, so a name declared anywhere else is never one.
    fn aliasSources(a: Allocator, ir: *const JsIr, names: usize) Allocator.Error![]u32 {
        const src = try a.alloc(u32, names);
        @memset(src, none);
        const decls = try a.alloc(u8, names);
        defer a.free(decls);
        @memset(decls, 0);
        const bump = struct {
            fn f(d: []u8, n: u32) void {
                if (n < d.len and d[n] < 2) d[n] += 1;
            }
        }.f;
        for (0..ir.nodes.len) |i| {
            const node: Index = @fromBackingInt(@intCast(i));
            const d = ir.data(node);
            switch (ir.tag(node)) {
                .const_decl => {
                    bump(decls, d.lhs);
                    const rhs: Index = @fromBackingInt(@intCast(d.rhs));
                    if (d.lhs < names and ir.tag(rhs) == .ident and ir.data(rhs).lhs != d.lhs) src[d.lhs] = d.rhs;
                },
                .let_decl, .func_decl, .gen_decl, .for_of, .while_true, .block_stmt => bump(decls, d.lhs),
                .arrow => {
                    const f = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Func);
                    for (ir.extraSlice(f.params(), NameIndex)) |n| if (n.unwrap()) |x| bump(decls, x);
                },
                .try_stmt => if (ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try).catch_name.unwrap()) |x| bump(decls, x),
                else => {},
            }
            switch (ir.tag(node)) {
                .func_decl, .gen_decl => {
                    const f = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Func);
                    for (ir.extraSlice(f.params(), NameIndex)) |n| if (n.unwrap()) |x| bump(decls, x);
                },
                else => {},
            }
        }
        for (src, decls) |*s, c| if (c != 1) {
            s.* = none;
        };
        return src;
    }

    /// `localVar`'s alias: the var of the identifier the one `const` of `n`
    /// copies (`alias_src`), when its read is walked and no guard narrows
    /// it, and `n`'s filter (`allow`) is wild or the source's own.
    fn aliasOf(p: *Pts, mi: u32, n: NameIndex, allow: JsIr.RepKey) Allocator.Error!?VarId {
        if (mi >= p.alias_src.len) return null;
        const row = p.alias_src[mi];
        const i = n.unwrap() orelse return null;
        if (i >= row.len or row[i] == none) return null;
        const rhs: Index = @fromBackingInt(@intCast(row[i]));
        if (p.alias_depth > 64 or p.maybeNarrowed(mi, rhs)) return null;
        p.alias_depth += 1;
        defer p.alias_depth -= 1;
        const src = try p.nodeVar(mi, rhs, @fromBackingInt(@intCast(p.s.mods[mi].ir.data(rhs).lhs)));
        if (allow != .wild and allow != p.links_of.items[src].allow) return null;
        return src;
    }

    fn localVar(p: *Pts, mi: u32, n: NameIndex) Allocator.Error!VarId {
        if (p.cachedLocal(mi, p.top, n)) |v| return v;
        const gop = try p.locals.getOrPut(p.run(), .{ .module = mi, .top = p.top.int(), .name = n.int() });
        if (!gop.found_existing) {
            const allow = p.closedKey(p.s.mods[mi].ir.nameKey(n));
            // A `const` copy of a name, declared nowhere else, is its source
            // when no guard narrows the read and its filter passes what the
            // source's does: the copy edge would make the two sets one.
            if (try p.aliasOf(mi, n, allow)) |src| {
                gop.value_ptr.* = src;
            } else {
                gop.value_ptr.* = try p.newVar();
                // Filtered by its name's declared type (*Declared-type filtering
                // of fact 3*); a name the compiler made is wild.
                p.links_of.items[gop.value_ptr.*].allow = allow;
                if (p.s.in.trace_largest) p.originAt(gop.value_ptr.*, .{ .kind = .local, .of = .local, .module = mi, .node = p.top.int(), .name = p.s.mods[mi].names.items[n.int()] });
            }
        }
        p.cacheLocal(mi, p.top, n, gop.value_ptr.*);
        return gop.value_ptr.*;
    }

    /// The var of name `n`, which node `node` of the walk names (an
    /// identifier, or a binding): a local's is looked up once per node, and
    /// top-level statement it is walked in, and fixpoint — the IR does not
    /// change under one.
    inline fn nodeVar(p: *Pts, mi: u32, node: Index, n: NameIndex) Allocator.Error!VarId {
        if (p.s.mods[mi].globalOf(n)) |g| return p.globals[g];
        const i = node.int();
        if (p.node_top[mi][i] == p.top.int()) return p.node_var[mi][i];
        const v = try p.localVar(mi, n);
        p.node_var[mi][i] = v;
        p.node_top[mi][i] = p.top.int();
        return v;
    }

    /// The var of local `n` of top-level statement `top`, if it has one.
    fn findLocal(p: *Pts, mi: u32, top: Index, n: NameIndex) ?VarId {
        if (p.cachedLocal(mi, top, n)) |v| return v;
        const v = p.locals.get(.{ .module = mi, .top = top.int(), .name = n.int() }) orelse return null;
        p.cacheLocal(mi, top, n, v);
        return v;
    }

    /// `locals`, in front of which each name keeps the var it had in the
    /// last top-level statement it was looked up in: a walk stays in one
    /// statement, and most names are in one.
    inline fn cachedLocal(p: *const Pts, mi: u32, top: Index, n: NameIndex) ?VarId {
        const i = n.int();
        if (mi >= p.name_top.len or i >= p.name_top[mi].len) return null;
        return if (p.name_top[mi][i] == top.int()) p.name_var[mi][i] else null;
    }

    fn cacheLocal(p: *Pts, mi: u32, top: Index, n: NameIndex, v: VarId) void {
        const i = n.int();
        if (mi >= p.name_top.len or i >= p.name_top[mi].len) return;
        p.name_top[mi][i] = top.int();
        p.name_var[mi][i] = v;
    }

    /// The site node `node` of module `mi` made, if any.
    inline fn siteAt(p: *const Pts, mi: u32, node: Index) ?u32 {
        if (mi >= p.site_of.len) return null;
        const row = p.site_of[mi];
        if (node.int() >= row.len) return null;
        const site = row[node.int()];
        return if (site == none) null else site;
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
        if (p.siteAt(mi, node)) |site| return site;
        // The site's key (`backend.md` §9, *Declared-type filtering of fact
        // 3*): a safety build checks that a keyed node is still an object,
        // an array or an arrow (`JsIr.nodeKey`).
        const key = p.closedKey(p.s.mods[mi].ir.nodeKey(node));
        const id: u32 = @intCast(p.sites.items.len);
        p.site_of[mi][node.int()] = id;
        try p.sites.append(p.tmp.column(.sites), .{ .kind = kind, .module = mi, .node = node, .key = key, .once = p.once_ctx, .any = try p.newVar() });
        p.links_of.items[p.sites.items[id].any].site_var = true;
        if (p.s.in.trace_largest) p.originAt(p.sites.items[id].any, .{ .kind = .site_any, .of = .site_any, .module = mi, .node = node.int() });
        // Keys written before anything can read them exist from the moment
        // the object does, as a literal's own do.
        if (kind == .object) if (p.extra_init.get(.{ .module = mi, .node = node.int() })) |ids| {
            for (ids.items) |pid| (try p.prop(id, pid)).init = true;
        };
        return id;
    }

    /// A function's site, its parameters' vars and its return's.
    fn funcSite(p: *Pts, mi: u32, node: Index, record: ExtraIndex) Allocator.Error!u32 {
        const seen = p.siteAt(mi, node) != null;
        const site = try p.siteOf(mi, node, .func);
        if (seen) return site;
        const ir = p.s.mods[mi].ir;
        const f = ir.extraData(record, JsIr.Func);
        const names = ir.extraSlice(f.params(), NameIndex);
        const params = try p.run().alloc(VarId, names.len);
        for (params, names) |*v, n| v.* = try p.localVar(mi, n);
        p.sites.items[site].params = params;
        p.sites.items[site].ret = try p.newVar();
        // An arrow is keyed by what it returns (`JsIr.node_keys`): that key
        // filters its return var.
        if (p.s.in.rep_keys != null) p.links_of.items[p.sites.items[site].ret].allow = p.closedKey(ir.nodeKey(node));
        if (p.s.in.trace_largest) p.originAt(p.sites.items[site].ret, .{ .kind = .ret, .of = .ret, .module = mi, .node = node.int() });
        return site;
    }

    /// Property `id` of site `site`, made when it is new, with no var: a
    /// property nothing has written holds nothing, and gets a var when
    /// something does (`ownField`, `spreadSummary`). The properties are
    /// sorted by id: a wide record is found by binary search, not a scan.
    fn prop(p: *Pts, site: u32, id: u32) Allocator.Error!*Prop {
        const at = try p.propAt(site, id);
        return &p.sites.items[site].props.items[at];
    }

    /// `prop`, by index in the site's `props`.
    fn propAt(p: *Pts, site: u32, id: u32) Allocator.Error!usize {
        var hint: usize = 0;
        return p.propAtHint(site, id, &hint);
    }

    /// `propAt`, the property expected at `hint.*` or just after it, which
    /// is left where it is (`indexAt`): a walk over another list sorted by
    /// id finds each in turn with no search.
    fn propAtHint(p: *Pts, site: u32, id: u32, hint: *usize) Allocator.Error!usize {
        const at = indexAt(Prop, p.sites.items[site].props.items, id, hint.*);
        hint.* = at;
        if (at < p.sites.items[site].props.items.len and p.sites.items[site].props.items[at].id == id) return at;
        const st = &p.sites.items[site];
        try st.props.insert(p.run(), at, .{ .id = id, .vals = none });
        // A new property: what read the site whole reads it too.
        p.wake(st.prop_deps);
        st.prop_deps = none;
        st.prop_seen = 0;
        // Into the summary of every var that holds the site and is read
        // for it (`demands`).
        for (p.sites.items[site].summaries.items) |sum| if (!p.summaries.items[sum].dead and p.demands(sum, id)) {
            try p.copyField(site, at, id, try p.summaryProp(sum, id));
        };
        hint.* = p.propIndex(site, at, id);
        return hint.*;
    }

    fn propMut(p: *Pts, site: u32, id: u32) ?*Prop {
        if (site >= p.sites.items.len) return null;
        const props = p.sites.items[site].props.items;
        const at = std.sort.lowerBound(Prop, props, id, orderProp);
        return if (at < props.len and props[at].id == id) &props[at] else null;
    }

    fn findProp(p: *const Pts, site: u32, id: u32) ?*const Prop {
        const props = p.sites.items[site].props.items;
        const at = std.sort.lowerBound(Prop, props, id, orderProp);
        return if (at < props.len and props[at].id == id) &props[at] else null;
    }

    fn orderProp(id: u32, pr: Prop) std.math.Order {
        return std.math.order(id, pr.id);
    }

    /// The index of property `id`, which site `site` has, in its `props`:
    /// `hint` when it is still there, which a walk over the properties
    /// knows, unless something it called since gave the site another.
    inline fn propIndex(p: *const Pts, site: u32, hint: usize, id: u32) usize {
        const props = p.sites.items[site].props.items;
        if (hint < props.len and props[hint].id == id) return hint;
        const at = std.sort.lowerBound(Prop, props, id, orderProp);
        if (std.debug.runtime_safety) std.debug.assert(props[at].id == id);
        return at;
    }

    /// What a property's var holds now, read by the constraint being
    /// evaluated: nothing for one no var holds yet (`Prop`), whose readers
    /// are woken through the site when it gets one (`wakeReaders`).
    inline fn fieldView(p: *Pts, v: VarId) Allocator.Error!Val {
        return if (v == none) .{} else p.view(v);
    }

    /// The constraints that read a property of site `site` (`seeSite`,
    /// `seeProps`) read it again: its var changed (`Prop`). No value
    /// changed, so nothing else is.
    fn wakeReaders(p: *Pts, site: u32) void {
        const st = &p.sites.items[site];
        p.wake(st.deps);
        st.deps = none;
        st.seen = 0;
        p.wake(st.prop_deps);
        st.prop_deps = none;
        st.prop_seen = 0;
    }

    /// Property `id` of site `site`, which exists, copied into var `to`: a
    /// summary that folds the site, a load cell that reads it. A property
    /// without a var of its own (`Prop`) lists `to`, which the var it gets
    /// feeds then (`ownField`, `spreadSummary`); one with none yet copies
    /// nothing now.
    fn copyField(p: *Pts, site: u32, hint: usize, id: u32, to: VarId) Allocator.Error!void {
        const pr = &p.sites.items[site].props.items[p.propIndex(site, hint, id)];
        const from = pr.vals;
        if (from == none or pr.from != none) {
            const out: u32 = @intCast(p.field_outs.items.len);
            try p.field_outs.append(p.tmp.column(.field_outs), .{ .to = to, .next = pr.outs });
            pr.outs = out;
        }
        if (from != none) try p.copy(from, to);
    }

    /// The var of property `id` of site `site`, which exists, for a write
    /// other than a spread's that shares it (`Prop`): its own, made now when
    /// the property has none. It is fed by the summary's var the property
    /// shared, if it shared one, and feeds what the property fed on the
    /// site's behalf (`Prop.outs`), so it holds what the property held, and
    /// the constraints that read the property through the site read it
    /// again, from the new var (#564).
    fn ownField(p: *Pts, site: u32, hint: usize, id: u32) Allocator.Error!VarId {
        const at = p.propIndex(site, hint, id);
        const pr = &p.sites.items[site].props.items[at];
        if (pr.vals != none and pr.from == none) return pr.vals;
        const from = pr.from;
        const outs = pr.outs;
        const v = try p.newVar();
        p.links_of.items[v].site_var = true;
        p.links_of.items[v].allow = p.fieldFilter(site, id);
        if (p.s.in.trace_largest) p.originAt(v, .{ .kind = .site_prop, .of = .site_prop, .module = p.sites.items[site].module, .node = p.sites.items[site].node.int(), .prop = id });
        const own = &p.sites.items[site].props.items[at];
        own.vals = v;
        own.from = none;
        own.outs = none;
        p.wakeReaders(site);
        if (from != none) try p.copy(from, v);
        var o = outs;
        while (o != none) : (o = p.field_outs.items[o].next) try p.copy(v, p.field_outs.items[o].to);
        return v;
    }

    /// `{...x}` of a name: what spreading summary `sum` into object site
    /// `site` writes, property by property, `keys` the literal's own keys
    /// (sorted). A property the literal does not write, and that nothing
    /// else has written, is shared (`Prop.from`, `shareField`) in place of
    /// a var of its own fed by an edge per site (#564, copy equivalence: a
    /// var whose one source is a copy edge holds what the source holds).
    fn spreadSummary(p: *Pts, site: u32, sum: u32, keys: []const u32) Allocator.Error!void {
        // The summary's properties, the site's and `keys` are each sorted
        // by id: each is walked once, in step (`indexAt`, #577).
        var hint: usize = 0;
        var key: usize = 0;
        var k: usize = 0;
        while (!p.summaries.items[sum].dead and k < p.summaries.items[sum].props.items.len) : (k += 1) {
            const sp = p.summaries.items[sum].props.items[k];
            if (key > 0 and keys[key - 1] >= sp.id) key = std.sort.lowerBound(u32, keys, sp.id, orderU32);
            while (key < keys.len and keys[key] < sp.id) key += 1;
            const at = try p.propAtHint(site, sp.id, &hint);
            const pr = &p.sites.items[site].props.items[at];
            if (!pr.written) {
                pr.written = true;
                p.changed = true;
            }
            // Shared already, from this very var: nothing more to copy.
            if (pr.from == sp.vals) continue;
            if (pr.vals == none and !(key < keys.len and keys[key] == sp.id)) {
                try p.shareField(site, at, sp.id, sp.vals);
                continue;
            }
            try p.copy(sp.vals, try p.ownField(site, at, sp.id));
        }
    }

    /// How many copies `shareField` follows back from a summary's var.
    const max_share_chain = 16;

    /// Property `id` of site `site`, which exists and has no var, written by
    /// a spread from summary var `x` alone, takes the var every such field
    /// shares (`VCold.shared`). `x` is one of the summary's vars, which a copy
    /// edge feeds from another summary's var of the property when the
    /// summary is linked to that one's (`linkSummaries`); while that edge is
    /// its one source, it holds what that var holds. So the field shares
    /// the var of the root of that chain of copies — every record update
    /// whose spread operand is a copy of one record (`browser-inline`'s
    /// `const $before = $model` in each handler) shares one var per field,
    /// fed by one edge, and a summary that folds any number of them takes
    /// one edge from it. The field is listed on each var of the chain, and
    /// gets its own var when one of them gains a second source (`unshare`)
    /// or something else writes it (`ownField`).
    fn shareField(p: *Pts, site: u32, hint: usize, id: u32, x: VarId) Allocator.Error!void {
        var root = x;
        var steps: u32 = 0;
        while (steps < max_share_chain) : (steps += 1) {
            const vr = p.cold.items[root];
            if (vr.preds != 1) break;
            const from = p.edges.items[vr.pred].from;
            if (p.links_of.items[from].depth == 0 or from == x) break;
            root = from;
        }
        var z = x;
        while (z != root) : (z = p.edges.items[p.cold.items[z].pred].from) {
            const at: u32 = @intCast(p.sharers.items.len);
            try p.sharers.append(p.tmp.allocator(), .{ .site = site, .id = id, .next = p.cold.items[z].sharers });
            p.cold.items[z].sharers = at;
        }
        const fresh = p.cold.items[root].shared == none;
        if (fresh) {
            const v = try p.newVar();
            p.links_of.items[v].site_var = true;
            if (p.s.in.trace_largest) p.originAt(v, .{ .kind = .site_prop, .of = .site_prop, .module = p.sites.items[site].module, .node = p.sites.items[site].node.int(), .prop = id });
            p.cold.items[root].shared = v;
        }
        const shared = p.cold.items[root].shared;
        const pr = &p.sites.items[site].props.items[p.propIndex(site, hint, id)];
        pr.vals = shared;
        pr.from = x;
        const outs = pr.outs;
        p.wakeReaders(site);
        if (fresh) try p.copy(root, shared);
        var o = outs;
        while (o != none) : (o = p.field_outs.items[o].next) try p.copy(shared, p.field_outs.items[o].to);
    }

    /// Var `z`, a summary's var a chain of copies ran through, has a second
    /// source: each field shared through it (`shareField`) that is still
    /// shared gets its own var, fed by the summary var it was spread from.
    fn unshare(p: *Pts, z: VarId) Allocator.Error!void {
        var s = p.cold.items[z].sharers;
        p.cold.items[z].sharers = none;
        while (s != none) : (s = p.sharers.items[s].next) {
            const sh = p.sharers.items[s];
            if (p.findProp(sh.site, sh.id).?.from != none) _ = try p.ownField(sh.site, none, sh.id);
        }
    }

    // ---- Reads and writes ----------------------------------------------------

    /// What reading property `id` of `obj` may give. A `null` or
    /// `undefined` object throws, and gives nothing; a property the
    /// object's literal lacks may be `undefined` (slice 4).
    fn read(p: *Pts, obj: Val, id: u32, mark: bool) Allocator.Error!Val {
        // A property of a value the program did not make, of a primitive,
        // of an object something unseen holds, or under a key the pass does
        // not know, is anything (`Val.top_val`).
        var out: Val = if (obj.top or obj.prim) Val.top_val else .{};
        for (obj.sites) |site| {
            try p.seeSite(site);
            const st = &p.sites.items[site];
            if (st.kind != .object or st.escaped or id == none) {
                out = try p.unionOf(out, Val.top_val);
                continue;
            }
            if (mark) {
                const pr = try p.prop(site, id);
                if (!pr.read) {
                    pr.read = true;
                    p.changed = true;
                }
                if (!pr.init) out.undef = true;
                out = try p.unionOf(out, try p.fieldView(pr.vals));
            } else if (p.findProp(site, id)) |pr| {
                if (!pr.init) out.undef = true;
                out = try p.unionOf(out, try p.fieldView(pr.vals));
            } else out.undef = true;
            out = try p.unionOf(out, try p.view(p.sites.items[site].any));
        }
        return out;
    }

    /// `read`, for the constraint being evaluated (the combined solver's
    /// `load`): what it gives is the constraint's own var, the load cell
    /// (`Load`), so that a value reaching one site's property flows to the
    /// read along an edge, and the read is evaluated again only when its
    /// own var or the object changes, never for each of the sites'
    /// properties. A read of a name's property reads the name's field
    /// summary (`summaryLoad`), which holds every site the name may be and
    /// follows it as it gains more; a read of any other object expression
    /// is fed by a copy edge from property `id`'s var, and from `any`, of
    /// every object site `obj` holds — each linked once, as the sites
    /// arrive (`Load.done`). A site that may make the read anything (no
    /// object, escaped, an unknown key) is noted in the var as a flag
    /// beside its sites (`VSet.uncapped`).
    fn load(p: *Pts, mi: u32, node: Index, object: Index, obj: Val, id: u32) Allocator.Error!Val {
        const ir = p.s.mods[mi].ir;
        var li: u32 = if (p.cur != none) p.cons.items[p.cur].load else none;
        if (li == none) {
            if (ir.tag(object) == .ident) {
                const v = try p.nodeVar(mi, object, @fromBackingInt(@intCast(ir.data(object).lhs)));
                const gop = try p.load_cells.getOrPut(p.tmp.allocator(), .{ .v = v, .id = id });
                if (!gop.found_existing) {
                    const made = try p.newLoad();
                    gop.value_ptr.* = made;
                    if (p.s.in.trace_largest) p.originAt(p.loads.items[made].out, p.originOf(v, .load, id));
                    // An unknown key is anything whatever the sites are.
                    if (id != none) try p.nameLoad(v, id, made);
                    li = made;
                } else li = gop.value_ptr.*;
            } else {
                const gop = try p.load_nodes.getOrPut(p.tmp.allocator(), .{ .module = mi, .node = node.int() });
                if (!gop.found_existing) {
                    gop.value_ptr.* = try p.newLoad();
                    if (p.s.in.trace_largest) p.originAt(p.loads.items[gop.value_ptr.*].out, .{ .kind = .load, .of = .load, .module = mi, .node = node.int(), .prop = id });
                }
                li = gop.value_ptr.*;
            }
            if (p.cur != none) p.cons.items[p.cur].load = li;
        }
        const out = p.loads.items[li].out;
        if (obj.top or obj.prim or id == none) try p.join(out, Val.top_val);
        // The summary follows the name's sites itself: `obj` is what the
        // name held when the constraint was evaluated, never more.
        if (p.loads.items[li].summary) {
            // What the read joined is in the cell before its value is read.
            try p.drain();
            return p.view(out);
        }
        const fresh = try p.difference(try p.setOf(obj), p.loads.items[li].done);
        // What was linked, and what is now: two reads share a cell, and one
        // may be evaluated with an older, smaller object than the other.
        if (fresh != 0) p.loads.items[li].done = try p.unionSets(p.loads.items[li].done, fresh);
        for (p.setSites(fresh)) |site| {
            const st = &p.sites.items[site];
            // No object, an unknown key or an escaped site: the read is
            // anything, and nothing is linked. A site that escaped is read
            // whole by `propagate`, which escapes its properties' values.
            if (st.kind != .object or id == none or st.escaped) {
                try p.join(out, Val.top_val);
                continue;
            }
            try p.sites.items[site].loads.append(p.tmp.allocator(), li);
            const at = try p.propAt(site, id);
            const pr = &p.sites.items[site].props.items[at];
            if (!pr.read) {
                pr.read = true;
                p.changed = true;
            }
            if (!pr.init) try p.join(out, Val.undef_val);
            try p.copyField(site, at, id, out);
            try p.copy(p.sites.items[site].any, out);
        }
        try p.drain();
        return p.view(out);
    }

    fn newLoad(p: *Pts) Allocator.Error!u32 {
        const id: u32 = @intCast(p.loads.items.len);
        const out = try p.newVar();
        p.vars.items[out].uncapped = true;
        p.s.stats.pts_load_cells += 1;
        try p.loads.append(p.tmp.allocator(), .{ .out = out });
        return id;
    }

    /// Every property of every object `obj` may be, read.
    fn readAll(p: *Pts, obj: Val) Allocator.Error!Val {
        var out: Val = if (obj.top or obj.prim) Val.top_val else .{};
        for (obj.sites) |site| {
            try p.seeSite(site);
            try p.seeProps(site);
            const st = &p.sites.items[site];
            if (st.kind == .func or st.escaped) {
                out = try p.unionOf(out, Val.top_val);
                continue;
            }
            if (!st.all_read) {
                st.all_read = true;
                p.changed = true;
            }
            for (p.sites.items[site].props.items) |pr| out = try p.unionOf(out, try p.fieldView(pr.vals));
            out = try p.unionOf(out, try p.view(p.sites.items[site].any));
        }
        return out;
    }

    /// A write the program's own code makes, of key `id` (`none`: a key it
    /// does not know), on every object `obj` may be — or on one the pass
    /// cannot see, which it records for every object (slice 9's tag).
    fn progWrite(p: *Pts, obj: Val, id: u32) Allocator.Error!void {
        if (obj.top or obj.prim) {
            if (id == none) p.unknown_any = true else if (std.mem.indexOfScalar(u32, p.unknown_props.items, id) == null) try p.unknown_props.append(p.run(), id);
        }
        for (obj.sites) |site| {
            const st = &p.sites.items[site];
            if (id == none) {
                st.prog_any = true;
            } else if (std.mem.indexOfScalar(u32, st.prog_props.items, id) == null) try st.prog_props.append(p.run(), id);
        }
    }

    /// Whether `v` may be a `Js.method` function (`arrow_method`): one
    /// that reads `this`, which is whatever object it is called on — an
    /// object holding one may have any of its keys read and written by a
    /// receiver the pass cannot name (`backend.md` §4, *`Js.method` is a
    /// `function`*). Such an object, and the method, escape.
    fn holdsMethod(p: *Pts, v: Val) bool {
        for (v.sites) |site| {
            const st = p.sites.items[site];
            if (st.kind != .func) continue;
            const ir = p.s.mods[st.module].ir;
            if (ir.tag(st.node) == .arrow and ir.data(st.node).rhs == Node.arrow_method) return true;
        }
        return false;
    }

    fn write(p: *Pts, obj: Val, id: u32, value: Val) Allocator.Error!void {
        // `__proto__` assigns `[[Prototype]]`. Later reads and writes are
        // not own data properties of a plain literal.
        if (id != none and id == p.s.in.proto_prop) try p.escape(obj);
        if (p.holdsMethod(value)) {
            try p.escape(obj);
            try p.escape(value);
        }
        try p.progWrite(obj, id);
        if (obj.top or obj.prim) try p.escape(value);
        for (obj.sites) |site| {
            try p.seeSite(site);
            const st = &p.sites.items[site];
            if (st.kind != .object or st.escaped or id == none) {
                try p.escape(value);
                if (id == none) try p.writeAnyOne(site, value);
                continue;
            }
            const at = try p.propAt(site, id);
            const pr = &p.sites.items[site].props.items[at];
            if (!pr.written) {
                pr.written = true;
                p.changed = true;
            }
            try p.join(try p.ownField(site, at, id), value);
        }
    }

    fn writeAnyOne(p: *Pts, site: u32, value: Val) Allocator.Error!void {
        try p.seeSite(site);
        try p.markAnyWritten(site);
        try p.join(p.sites.items[site].any, value);
        if (p.sites.items[site].escaped) try p.escape(value);
    }

    fn writeAny(p: *Pts, obj: Val, value: Val) Allocator.Error!void {
        try p.progWrite(obj, none);
        if (obj.top or obj.prim) try p.escape(value);
        for (obj.sites) |site| try p.writeAnyOne(site, value);
    }

    /// Escapes unless the key is a non-`"__proto__"` string literal or a
    /// numeric literal (`backend.md` §9 fact 3, #519).
    fn indexMayAssignPrototype(p: *const Pts, mi: u32, key: Index) bool {
        const ir = p.s.mods[mi].ir;
        return switch (ir.tag(key)) {
            .string => std.mem.eql(u8, ir.bytes(key), prototype_assign),
            .number => false,
            else => true,
        };
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
        p.init_capped = false;
        const stats = &p.s.stats;
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            try p.fixpoint();
            stats.points_to_runs += 1;
            stats.points_to_sweeps += p.sweeps;
            // At the cap, asked once more only to count it: what it finds
            // is no run's, since the next `analyse` starts afresh.
            if (attempt == max_init_runs) {
                if (try p.definiteInit()) {
                    stats.init_capped += 1;
                    p.init_capped = true;
                }
                return;
            }
            if (!try p.definiteInit()) return;
        }
    }

    /// How many nodes a program may have for a safety build to check its
    /// fixpoint against another order's (`fixpoint`).
    const max_checked_nodes = 1500;

    /// Fact 3 to its fixpoint. In a safety build a small program's fixpoint
    /// is computed twice (`backend.md` §9, *The combined solver —
    /// Determinism*): first with the first sweep's top-level statements
    /// replayed in a shuffled order, then in program order. Every transfer
    /// function is monotone (`Val.top_val`), so both reach the one least
    /// fixpoint (research 52 §2.3), and the two must agree on every fact,
    /// up to the numbering of sites, which follows the replay. That checks
    /// the order does not matter, and that a constraint is evaluated again
    /// whenever anything it read changed.
    fn fixpoint(p: *Pts) Allocator.Error!void {
        if (std.debug.runtime_safety) {
            var nodes: usize = 0;
            var statements: u32 = 0;
            for (p.s.mods) |*m| {
                nodes += m.ir.nodes.len;
                statements += m.ir.body.len();
            }
            if (nodes <= max_checked_nodes) {
                // The reference fills an arena of its own, which `expectSame`
                // reads after the build's run has emptied and refilled
                // `tmp`.
                var ref_tmp: RunArena = .init(p.s.gpa);
                defer ref_tmp.deinit();
                std.mem.swap(RunArena, &p.tmp, &ref_tmp);
                const order = try p.arena().alloc(u32, statements);
                for (order, 0..) |*o, i| o.* = @intCast(i);
                // A fixed seed: the check, like the build, is a function of
                // the program.
                var prng: std.Random.DefaultPrng = .init(0x5EC5_0B1A ^ @as(u64, statements));
                prng.random().shuffle(u32, order);
                p.order = order;
                // The reference is a check, not the build's work: what its
                // sets cost is no counter's (`Stats.pts_*`).
                const counted = p.s.stats;
                try p.byConstraints();
                p.order = &.{};
                p.s.stats.pts_max_set = counted.pts_max_set;
                p.s.stats.pts_set_words = counted.pts_set_words;
                p.s.stats.pts_edges = counted.pts_edges;
                p.s.stats.pts_load_cells = counted.pts_load_cells;
                p.s.stats.pts_joins = counted.pts_joins;
                p.s.stats.pts_joins_empty = counted.pts_joins_empty;
                p.s.stats.pts_largest = counted.pts_largest;
                p.s.stats.pts_largest_sites = counted.pts_largest_sites;
                const ref = p.*;
                std.mem.swap(RunArena, &p.tmp, &ref_tmp);
                try p.byConstraints();
                try p.expectSame(&ref, false);
                return;
            }
        }
        try p.byConstraints();
    }

    /// A safety build's check of a kept state (`Spec.fact3Kept`, #575): fact
    /// 3 solves the program again, as `analyse` would have, and every fact
    /// of the solve must be the kept state's, each site the one of the same
    /// number. The kept state is what the build then reads, so that the
    /// corpus's outputs are those of the skip. The solve is a check, not
    /// the build's work: no counter counts it.
    fn checkKept(p: *Pts) Allocator.Error!void {
        // The kept state's own arena stays alive in `held` while the solve
        // fills a fresh one.
        var held: RunArena = .init(p.s.gpa);
        std.mem.swap(RunArena, &p.tmp, &held);
        const kept = p.*;
        const counted = p.s.stats;
        p.analyse() catch |err| {
            p.tmp.deinit();
            p.* = kept;
            p.tmp = held;
            p.s.stats = counted;
            return err;
        };
        p.s.stats = counted;
        defer {
            var solved = p.tmp;
            p.* = kept;
            p.tmp = held;
            solved.deinit();
        }
        if (!p.ok or p.init_capped) std.debug.panic("specialisation: fact 3 kept a state its solve does not reach", .{});
        try p.expectSame(&kept, true);
    }

    const FactCheck = struct {
        x: *const Pts,
        y: *const Pts,
        /// Per site of `x`, the site of `y` its node made.
        map: []const u32,

        fn fail(what: []const u8, at: usize) noreturn {
            std.debug.panic("specialisation: fact 3 walked in another order reaches another fixpoint: {s} {d}", .{ what, at });
        }
        fn failKept(what: []const u8, at: usize) noreturn {
            std.debug.panic("specialisation: fact 3 kept a state its solve does not reach: {s} {d}", .{ what, at });
        }
        fn sameSites(c: @This(), a: []const u32, b: []const u32) bool {
            if (a.len != b.len) return false;
            for (a) |site| if (std.sort.binarySearch(u32, b, c.map[site], orderU32) == null) return false;
            return true;
        }
        /// A value that is `top` is compared on its live sites alone: a
        /// read's cell keeps the sites it linked through an object that
        /// later escaped or went `top`, where a walk from scratch never
        /// sees them, and every such site is escaped — what it holds is
        /// no fact (*an escaped site is ⊤*). That the extra sites are
        /// indeed escaped is what the comparison then checks.
        fn sameVal(c: @This(), a: Val, b: Val) bool {
            if (a.top != b.top or a.prim != b.prim or a.nul != b.nul or a.undef != b.undef) return false;
            if (!a.top) return c.sameSites(a.sites, b.sites);
            // The node-based map need not preserve numeric site order.
            // Count live sites and compare membership, as `sameSites`
            // does for a value without `top`.
            var live_a: usize = 0;
            var live_b: usize = 0;
            for (a.sites) |site| {
                if (c.x.sites.items[site].escaped) continue;
                live_a += 1;
                if (std.sort.binarySearch(u32, b.sites, c.map[site], orderU32) == null) return false;
            }
            for (b.sites) |site| if (!c.y.sites.items[site].escaped) {
                live_b += 1;
            };
            return live_a == live_b;
        }
        fn sameVar(c: @This(), a: VarId, b: VarId) bool {
            const va = c.x.vars.items[a];
            const vb = c.y.vars.items[b];
            if (va.top != vb.top or va.prim != vb.prim or va.nul != vb.nul or va.undef != vb.undef) return false;
            // A `top` var may be uncapped (a load cell, or a local bound
            // to a member read) and then keeps the sites it linked
            // through an object that later escaped. Those sites are ⊤.
            // The live ones are the fact, as for a node's value.
            if (va.top) return c.sameVal(
                .{ .top = true, .prim = va.prim, .nul = va.nul, .undef = va.undef, .sites = va.sites },
                .{ .top = true, .prim = vb.prim, .nul = vb.nul, .undef = vb.undef, .sites = vb.sites },
            );
            return c.sameSites(va.sites, vb.sites);
        }
        /// A property no var holds yet (`Prop`) holds nothing.
        fn sameField(c: @This(), a: VarId, b: VarId) bool {
            if (a != none and b != none) return c.sameVar(a, b);
            const v = if (a != none) c.x.vars.items[a] else if (b != none) c.y.vars.items[b] else return true;
            return !v.top and !v.prim and !v.nul and !v.undef and v.sites.len == 0;
        }
        /// An absent sparse entry is an empty property. A spread may
        /// copy an empty key marked before its source escaped in only
        /// one order; `any_written` already covers its written bit.
        fn sameProp(c: @This(), a: ?Prop, b: ?Prop, any_written: bool, any_top: bool) bool {
            const pa = a orelse Prop{ .id = none, .vals = none };
            const pb = b orelse Prop{ .id = none, .vals = none };
            if (pa.read != pb.read or pa.init != pb.init or (!any_written and pa.written != pb.written)) return false;
            if (!any_top) return c.sameField(pa.vals, pb.vals);
            // Every field read includes `any`. Its top subsumes the
            // component flags and escaped sites a spread retained in
            // just one order; live sites must still agree.
            var va = Val.top_val;
            var vb = Val.top_val;
            if (pa.vals != none) va.sites = c.x.vars.items[pa.vals].sites;
            if (pb.vals != none) vb.sites = c.y.vars.items[pb.vals].sites;
            return c.sameVal(va, vb);
        }
        fn sameSet(a: []const u32, b: []const u32) bool {
            if (a.len != b.len) return false;
            for (a) |v| if (std.mem.indexOfScalar(u32, b, v) == null) return false;
            return true;
        }
    };

    /// Panic unless the facts in `p` are the facts in `ref`, each site of
    /// `p` taken for the site of `ref` its node made (and, when `numbered`,
    /// numbered as it). Nothing is compared when either did not reach its
    /// fixpoint: short of one no fact is read.
    fn expectSame(p: *const Pts, ref: *const Pts, numbered: bool) Allocator.Error!void {
        if (!p.ok or !ref.ok) return;
        const Check = FactCheck;
        const fail = if (numbered) &Check.failKept else &Check.fail;
        if (p.sites.items.len != ref.sites.items.len) fail("sites", 0);
        const map = try p.s.arena.alloc(u32, p.sites.items.len);
        for (p.sites.items, map, 0..) |a, *to, i| {
            to.* = ref.siteAt(a.module, a.node) orelse fail("site", i);
            if (numbered and to.* != i) fail("site number", i);
        }
        const c: Check = .{ .x = p, .y = ref, .map = map };
        if (p.unknown_any != ref.unknown_any) fail("unknown_any", 0);
        if (!Check.sameSet(p.unknown_props.items, ref.unknown_props.items)) fail("unknown_props", 0);
        for (p.globals, ref.globals, 0..) |a, b, g| if (!c.sameVar(a, b)) fail("global", g);
        if (p.locals.count() != ref.locals.count()) fail("locals", 0);
        var it = ref.locals.iterator();
        while (it.next()) |kv| {
            const mine = p.locals.get(kv.key_ptr.*) orelse fail("local", kv.key_ptr.name);
            if (!c.sameVar(mine, kv.value_ptr.*)) fail("local", kv.key_ptr.name);
        }
        for (p.sites.items, map, 0..) |a, j, i| {
            const b = ref.sites.items[j];
            const fresh = if (a.fresh_fn == none) none else map[a.fresh_fn];
            if (a.kind != b.kind or a.once != b.once or a.escaped != b.escaped or fresh != b.fresh_fn) fail("site", i);
            if (a.kind == .func) {
                if (!c.sameVar(a.ret, b.ret)) fail("site ret", i);
                for (a.params, b.params) |x, y| if (!c.sameVar(x, y)) fail("site param", i);
            }
            // An escaped site is ⊤: every property read and written with
            // anything, and no fact read of it but its tag's, which a
            // write through an unknown value refuses (`unknown_props`)
            // whichever way it was recorded. What else it gathered depends
            // on how much was walked before it escaped — a read marks a
            // property, a call records itself, only while the site is still
            // in view — and is no fact.
            if (a.escaped) continue;
            if (a.all_read != b.all_read or a.any_written != b.any_written or a.odd_caller != b.odd_caller or
                a.prog_any != b.prog_any)
                fail("site", i);
            if (!Check.sameSet(a.prog_props.items, b.prog_props.items)) fail("site prog_props", i);
            if (a.callers.items.len != b.callers.items.len) fail("site callers", i);
            for (a.callers.items) |k| {
                for (b.callers.items) |l| {
                    if (k.module == l.module and k.node == l.node) break;
                } else fail("site caller", i);
            }
            if (!c.sameVar(a.any, b.any)) fail("site any", i);
            // Compare facts over the union of keys, not sparse storage:
            // missing and empty entries mean the same thing. No read,
            // initialisation or value is ignored; `any_written` subsumes
            // the per-key written bit as in `neverWritten`.
            for (a.props.items) |pa| {
                const pb = ref.findProp(j, pa.id);
                if (!c.sameProp(pa, if (pb) |pr| pr.* else null, a.any_written, p.vars.items[a.any].top)) fail("site prop", i);
            }
            for (b.props.items) |pb| {
                if (p.findProp(@intCast(i), pb.id) != null) continue;
                if (!c.sameProp(null, pb, a.any_written, p.vars.items[a.any].top)) fail("site prop", i);
            }
        }
        for (p.vals, ref.vals, 0..) |a, b, mi| {
            for (a, b, 0..) |x, y, node| if (!c.sameVal(x, y)) fail("node value", mi * 1_000_000 + node);
        }
    }

    /// Everything a fixpoint computes, back to ⊥. The run arena is emptied
    /// first and keeps its chunks (`Arena.ResetMode.keep_all`), so the
    /// columns below land where the last run's did, on pages already
    /// mapped — grown in place when a pass added nodes — and each is filled
    /// here, since what the memory holds is the last run's (#574).
    fn reset(p: *Pts) Allocator.Error!void {
        const s = p.s;
        p.tmp.reset(.keep_all);
        const a = p.run();
        p.ok = false;
        p.vars = .empty;
        p.links_of = .empty;
        p.cold = .empty;
        p.sites = .empty;
        p.origins = .empty;
        p.locals = .empty;
        p.decl_call = .empty;
        p.unknown_props = .empty;
        p.unknown_any = false;
        p.stmts = .empty;
        p.deps = .empty;
        p.edges = .empty;
        p.edge_set = .empty;
        p.link_queue = .empty;
        p.linking = false;
        p.work = .empty;
        p.summaries = .empty;
        p.aliases = .empty;
        p.alias_reqs = .empty;
        p.alias_kids = .empty;
        p.mark_loads = .empty;
        p.split_epoch = 0;
        p.field_outs = .empty;
        p.sharers = .empty;
        p.lit_keys = .empty;
        p.pending = .empty;
        p.pending_head = 0;
        p.draining = false;
        p.folds = .empty;
        // A fresh table, not the old one cleared: a safety build's
        // reference (`fixpoint`) keeps its own, which `expectSame` reads.
        p.sets = .{};
        p.loads = .empty;
        p.load_cells = .empty;
        p.load_nodes = .empty;
        p.walk = 0;
        p.next_walk = 0;
        p.globals = try a.alloc(VarId, s.globals);
        for (p.globals, 0..) |*g, i| {
            g.* = try p.newVar();
            if (s.in.trace_largest) p.originAt(g.*, .{ .kind = .global, .of = .global, .global = @intCast(i) });
        }
        // What no module declares — an import of a hand-written file's
        // export — is anything at all.
        for (s.decl, p.globals) |d, g| if (d == null) try p.makeTop(g);
        p.vals = try a.alloc([]Val, s.mods.len);
        p.site_of = try a.alloc([]u32, s.mods.len);
        p.name_var = try a.alloc([]VarId, s.mods.len);
        p.name_top = try a.alloc([]u32, s.mods.len);
        p.node_var = try a.alloc([]VarId, s.mods.len);
        p.node_top = try a.alloc([]u32, s.mods.len);
        // A node no sweep reached (in code nothing runs) is anything.
        for (p.vals, p.site_of, p.name_var, p.name_top, s.mods) |*v, *so, *nv, *nt, *m| {
            const nodes = m.ir.nodes.len;
            v.* = try a.alloc(Val, nodes);
            @memset(v.*, Val.top_val);
            so.* = try a.alloc(u32, nodes);
            @memset(so.*, none);
            nv.* = try a.alloc(VarId, m.names.items.len);
            nt.* = try a.alloc(u32, m.names.items.len);
            @memset(nt.*, none);
            const ns = try a.alloc(VarId, 2 * nodes);
            @memset(ns[nodes..], none);
            p.node_var[m.index] = ns[0..nodes];
            p.node_top[m.index] = ns[nodes..];
        }
        for (s.mods, 0..) |*m, mi| {
            for (m.ir.extraSlice(m.ir.body, Index)) |top| try p.stmts.append(a, .{ .module = @intCast(mi), .top = top });
        }
        p.alias_src = try a.alloc([]u32, s.mods.len);
        for (p.alias_src, s.mods) |*al, *m| al.* = try aliasSources(a, m.ir, m.names.items.len);
        var nodes: usize = 0;
        for (s.mods) |*m| nodes += m.ir.nodes.len;
        p.ones = try a.alloc(u32, nodes);
        for (p.ones, 0..) |*o, i| o.* = @intCast(i);
    }

    /// The fixpoint by constraints (backend.md §9, *Amended 2026-10-12 —
    /// fact 3 by its constraints*, and *The combined solver*, slice 5),
    /// from ⊥. The first sweep replays the extractions (`replayWalk`): each
    /// constraint evaluated in turn — of an expression node, or of a
    /// statement's own transfer (`effect`) — and the steps between done as
    /// the walk did them. Every read of a var, a site or a property
    /// registers the constraint making it. After that a change wakes the
    /// constraints that read what changed, each evaluated again alone, and
    /// one whose value changed wakes those that read it. Every transfer
    /// function is monotone, so the fixpoint is the one least fixpoint. A
    /// sweep after the first is the constraints that wait, in the order the
    /// extraction made them; each is followed by what files the pass cannot
    /// see read, the entry's call, `propagate` and the folds that wait
    /// (`foldWaiting`), until nothing changes. Termination is the lattice's
    /// (*The worklist*): there is no cap.
    fn byConstraints(p: *Pts) Allocator.Error!void {
        try p.reset();
        const s = p.s;
        const a = p.tmp.allocator();
        p.base = try a.alloc(u32, s.mods.len);
        var count: u32 = 0;
        for (s.mods, p.base) |*m, *b| {
            b.* = count;
            count += @intCast(m.ir.nodes.len);
        }
        p.last = try a.alloc(u32, count);
        @memset(p.last, none);
        // Most nodes are evaluated once, and read by one other.
        p.cons = .empty;
        try p.cons.ensureTotalCapacity(a, count);
        p.inputs = .empty;
        try p.inputs.ensureTotalCapacity(a, count);
        p.links = .empty;
        try p.links.ensureTotalCapacity(a, count);
        p.narrows = .empty;
        p.kills = .empty;
        p.waiting_count = 0;
        defer {
            p.evaluating = false;
            // A node's value is its last evaluation's, as a walk leaves it.
            for (s.mods, p.base, p.vals) |*m, b, vals| {
                for (p.last[b..][0..m.ir.nodes.len], 0..) |c, node| {
                    if (c != none) vals[node] = p.cons.items[c].val;
                }
            }
        }
        var sweep: u32 = 0;
        while (true) : (sweep += 1) {
            p.sweeps = sweep + 1;
            if (sweep == 0) try p.replayWalk() else try p.evaluateWaiting();
            // A change the constraints made woke what reads it, so it is in
            // `waiting_count`; `changed` is what the rest of the sweep does.
            p.changed = false;
            // What files the pass cannot see read.
            for (s.in.escaping) |g| if (g < p.globals.len) try p.escape(try p.view(p.globals[g]));
            try p.drain();
            if (s.in.entry) |e| try p.entryCall(e);
            try p.propagate();
            try p.foldWaiting();
            if (std.debug.runtime_safety) std.debug.assert(p.pending.items.len == 0);
            if (!p.changed and p.waiting_count == 0) {
                p.ok = true;
                return;
            }
        }
    }

    /// The first walk by constraints, from the modules' extractions
    /// (`PtsExtract`, `backend.md` §9, *The combined solver*, slice 5): every
    /// constraint and every step in the order the recording walk took them,
    /// each constraint evaluated as `evaluate` evaluates one — its context,
    /// its inputs where it reads them, its guards — and the steps between
    /// done as the walk did them. The walk made the sites and vars in this
    /// order, so the replay makes the same ones, numbered alike, and reaches
    /// the state the recording walk did.
    fn replayWalk(p: *Pts) Allocator.Error!void {
        const s = p.s;
        const a = p.tmp.allocator();
        var scratch: Arena = .init(s.gpa);
        defer scratch.deinit();
        var program_nodes: usize = 0;
        for (s.mods) |*m| program_nodes += m.ir.nodes.len;
        for (s.mods, 0..) |*m, mi| {
            if (m.pex.epoch == m.epoch and m.pex.nodes == m.ir.nodes.len) continue;
            scratch.reset(.retain_capacity);
            try PtsExtractor.run(scratch.allocator(), m, false, &m.pex);
            // A safety build checks what a module kept against a walk of all
            // of it, in a small program.
            if (std.debug.runtime_safety and m.pex.reused != 0 and program_nodes <= max_checked_nodes) {
                scratch.reset(.retain_capacity);
                var walked: PtsExtract = .{};
                defer walked.deinit();
                try PtsExtractor.run(scratch.allocator(), m, true, &walked);
                m.pex.expectSame(&walked, @intCast(mi));
            }
        }
        // The constraints, numbered across modules in module order.
        const base = try a.alloc(u32, s.mods.len);
        var count: u32 = 0;
        for (s.mods, base) |*m, *b| {
            b.* = count;
            count += @intCast(m.pex.node.len);
        }
        try p.cons.ensureTotalCapacity(a, count);
        for (s.mods, base, 0..) |*m, b, mi| {
            const x = &m.pex;
            var in_from: u32 = 0;
            var nar_from: u32 = 0;
            for (x.node, x.top, x.inputs_end, x.narrows_end) |node, top, in_end, nar_end| {
                const start: u32 = @intCast(p.inputs.items.len);
                for (x.inputs[in_from..in_end]) |in| try lists.push(Read, &p.inputs, a, .{ .node = @fromBackingInt(@intCast(in.node)), .cons = b + in.cons });
                var narrow: u32 = none;
                for (x.narrows[nar_from..nar_end]) |n| {
                    const k_start: u32 = @intCast(p.kills.items.len);
                    for (x.kills[n.start..n.end]) |killer| try p.kills.append(a, b + killer);
                    try p.narrows.append(a, .{ .nul = n.nul, .undef = n.undef, .start = k_start, .end = @intCast(p.kills.items.len), .next = narrow });
                    narrow = @intCast(p.narrows.items.len - 1);
                }
                p.cons.appendAssumeCapacity(.{
                    .module = @intCast(mi),
                    .node = @fromBackingInt(@intCast(node)),
                    .top = @fromBackingInt(@intCast(top)),
                    .func = none,
                    .start = start,
                    .end = @intCast(p.inputs.items.len),
                    .narrow = narrow,
                    .narrow_open = narrow != none,
                });
                in_from = in_end;
                nar_from = nar_end;
            }
            // A node no constraint makes has its tag's value, read by the
            // constraints after it.
            const vals = p.vals[mi];
            for (x.constants) |c| vals[c] = constantVal(m.ir, @fromBackingInt(@intCast(c)));
            for (x.decl_calls) |dc| try p.decl_call.put(p.run(), .{ .module = @intCast(mi), .node = dc.call }, .{
                .range = .{ .start = @fromBackingInt(dc.start), .end = @fromBackingInt(dc.end) },
                .index = dc.index,
            });
        }
        p.waiting = try a.alloc(u64, std.math.divCeil(usize, p.cons.items.len, 64) catch unreachable);
        @memset(p.waiting, 0);
        p.evaluating = true;
        // The context a function's body is walked in, and a loop's.
        const Ctx = struct { cur: u32, walk: u32, once: bool, func: u32 };
        var ctxs: std.ArrayList(Ctx) = .empty;
        var loops: std.ArrayList(bool) = .empty;
        var func: u32 = none;
        defer p.cur = none;
        // The top-level statements in program order, or for a safety build's
        // check in `order` (`fixpoint`): each one's steps.
        const Unit = struct { module: u32, from: u32, to: u32 };
        var units: std.ArrayList(Unit) = .empty;
        for (s.mods, 0..) |*m, mi| {
            var from: u32 = 0;
            for (m.pex.stmts) |st| {
                try units.append(a, .{ .module = @intCast(mi), .from = from, .to = st.script });
                from = st.script;
            }
        }
        for (0..units.items.len) |u| {
            const unit = units.items[if (p.order.len == units.items.len) p.order[u] else u];
            const mi = unit.module;
            const m = &s.mods[mi];
            const b = base[mi];
            const ir = m.ir;
            const vals = p.vals[mi];
            for (m.pex.script[unit.from..unit.to]) |st| switch (st.op) {
                .stmt_begin => {
                    p.cur = none;
                    p.top = @fromBackingInt(@intCast(st.a));
                    p.once_ctx = true;
                    func = none;
                },
                .stmt_end => try p.drain(),
                .eval => {
                    const c = b + st.a;
                    const k = &p.cons.items[c];
                    for (p.inputs.items[k.start..k.end]) |in| try p.link(in.cons, c);
                    p.top = p.cons.items[c].top;
                    p.cur = c;
                    p.next_walk += 1;
                    p.walk = p.next_walk;
                    const node = p.cons.items[c].node;
                    if (ir.tag(node).isStatement()) {
                        p.cons.items[c].func = func;
                        try p.effect(mi, node, if (func == none) null else func);
                    } else {
                        vals[node.int()] = try p.combine(mi, node);
                        p.cons.items[c].val = vals[node.int()];
                        p.last[p.base[mi] + node.int()] = c;
                    }
                },
                .arrow, .func_decl => {
                    const node: Index = @fromBackingInt(@intCast(st.a));
                    const d = ir.data(node);
                    const record: ExtraIndex = @fromBackingInt(@intCast(if (st.op == .arrow) d.lhs else d.rhs));
                    const site = try p.funcSite(mi, node, record);
                    if (st.op == .func_decl) {
                        if (ir.tag(node) == .gen_decl) try p.escapeSite(site);
                        try p.enqueue(try p.nodeVar(mi, node, @fromBackingInt(@intCast(d.lhs))), .{}, try p.single(site), false);
                        // Its name holds it before the body, which may call it, is walked.
                        try p.drain();
                    }
                    try ctxs.append(a, .{ .cur = p.cur, .walk = p.walk, .once = p.once_ctx, .func = func });
                    p.cur = none;
                    p.once_ctx = false;
                    func = site;
                },
                .body_end => {
                    const node: Index = @fromBackingInt(@intCast(st.a));
                    const site = p.siteAt(mi, node).?;
                    const d = ir.data(node);
                    const record: ExtraIndex = @fromBackingInt(@intCast(if (ir.tag(node) == .arrow) d.lhs else d.rhs));
                    if (fallsThrough(ir, ir.extraData(record, JsIr.Func).body())) try p.join(p.sites.items[site].ret, Val.undef_val);
                    try p.drain();
                    const ctx = ctxs.pop().?;
                    p.cur = ctx.cur;
                    p.walk = ctx.walk;
                    p.once_ctx = ctx.once;
                    func = ctx.func;
                    if (ir.tag(node) == .arrow) vals[node.int()] = .{ .sites = p.ones[site..][0..1] };
                },
                .loop_begin => {
                    try loops.append(a, p.once_ctx);
                    p.once_ctx = false;
                },
                .loop_end => p.once_ctx = loops.pop().?,
                .fresh => if (func != none) if (p.siteAt(mi, @fromBackingInt(@intCast(st.a)))) |o| {
                    p.sites.items[o].fresh_fn = func;
                },
            };
        }
    }

    /// Every constraint that waits, a 64-bit word of the set at a time from
    /// the first: one woken in a word already passed waits for the next
    /// sweep. The order changes no fact, every transfer function being
    /// monotone, but it changes how many sweeps the fixpoint takes and
    /// which vars a sweep makes; so the word is 64 bits on every target,
    /// and wasm32 sweeps as x86-64 does.
    fn evaluateWaiting(p: *Pts) Allocator.Error!void {
        defer p.cur = none;
        const masks = p.waiting;
        var w: usize = 0;
        while (w < masks.len) : (w += 1) {
            while (masks[w] != 0) {
                const bit = @ctz(masks[w]);
                masks[w] &= masks[w] - 1;
                p.waiting_count -= 1;
                try p.evaluate(@intCast(w * 64 + bit));
            }
        }
    }

    /// Constraint `c` evaluated again, alone, in the context the walk made
    /// it in, its inputs' values where it reads them: a statement does what
    /// it does with them; a node's value is made again, and when it
    /// changed, what reads it waits.
    fn evaluate(p: *Pts, c: u32) Allocator.Error!void {
        const k = p.cons.items[c];
        const vals = p.vals[k.module];
        p.top = k.top;
        p.cur = c;
        p.next_walk += 1;
        p.walk = p.next_walk;
        for (p.inputs.items[k.start..k.end]) |in| vals[in.node.int()] = p.cons.items[in.cons].val;
        if (p.s.mods[k.module].ir.tag(k.node).isStatement()) return p.effect(k.module, k.node, if (k.func == none) null else k.func);
        const v = try p.combine(k.module, k.node);
        const old = &p.cons.items[c].val;
        if (old.top == v.top and old.prim == v.prim and old.nul == v.nul and old.undef == v.undef and
            sameSites(old.*, v)) return;
        old.* = v;
        var l = p.cons.items[c].readers;
        while (l != none) : (l = p.links.items[l].next) p.reevaluate(p.links.items[l].cons);
    }

    /// Constraint `to` reads constraint `from`'s value.
    fn link(p: *Pts, from: u32, to: u32) Allocator.Error!void {
        try lists.push(Link, &p.links, p.tmp.allocator(), .{ .cons = to, .next = p.cons.items[from].readers });
        p.cons.items[from].readers = @intCast(p.links.items.len - 1);
    }

    /// Statement `node`'s transfer, and what it joined carried on: the end
    /// of a constraint's evaluation, where the worklist drains (`join`).
    fn effect(p: *Pts, mi: u32, node: Index, func: ?u32) Allocator.Error!void {
        try p.effectNow(mi, node, func);
        try p.drain();
    }

    fn effectNow(p: *Pts, mi: u32, node: Index, func: ?u32) Allocator.Error!void {
        const ir = p.s.mods[mi].ir;
        const d = ir.data(node);
        const vals = p.vals[mi];
        switch (ir.tag(node)) {
            .const_decl, .let_decl => {
                const target = try p.nodeVar(mi, node, @fromBackingInt(@intCast(d.lhs)));
                const v: Node.OptionalIndex = @fromBackingInt(@intCast(d.rhs));
                const value = v.unwrap() orelse return p.join(target, Val.undef_val);
                // The cell holds `top` beside the objects (`load`). This
                // local is that read, so `top` does not escape the objects,
                // and an unread field can drop. `limited` keeps `max_sites`.
                // The flag is the statement's, so the two walks agree. The
                // slot of a variant payload is one such read. `Result`'s
                // `a` holds the payload and the `Err` list, so the read is
                // `top`.
                if (ir.tag(value) == .member) {
                    p.vars.items[target].uncapped = true;
                    p.vars.items[target].limited = true;
                }
                // A binding to a name or a member read, when no guard
                // narrows it, is a copy (`copySource`): the binding's set is
                // the source's as it grows, and a spread or a read of the
                // binding shares the source's field summary.
                if (try p.copySource(mi, value)) |from| return p.copy(from, target);
                try p.join(target, vals[value.int()]);
            },
            .assign_stmt => {
                const value = vals[d.rhs];
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                const td = ir.data(target);
                switch (ir.tag(target)) {
                    // A later value of a name is joined, not copied (#562):
                    // the `inline` lowering assigns its model from a read of
                    // each handler's own result (`$model = $result.a`), a
                    // cell no other read shares. As a copy, every field
                    // summary of the model would be fed by one of each such
                    // cell, each folding the field's records again: the
                    // dashboard N=64 took 99.7M edges against 1.36M.
                    .ident => try p.join(try p.nodeVar(mi, target, @fromBackingInt(@intCast(td.lhs))), value),
                    .member => try p.write(vals[td.lhs], p.propId(mi, @fromBackingInt(@intCast(td.rhs))), value),
                    .index_get => {
                        const obj = vals[td.lhs];
                        if (p.indexMayAssignPrototype(mi, @fromBackingInt(@intCast(td.rhs)))) try p.escape(obj);
                        try p.writeAny(obj, value);
                    },
                    else => try p.escape(value),
                }
            },
            .return_stmt => {
                const value: ?Index = @as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap();
                const val = if (value) |v| vals[v.int()] else Val.undef_val;
                const site = func orelse return p.escape(val);
                if (value) |v| if (try p.copySource(mi, v)) |from| return p.copy(from, p.sites.items[site].ret);
                try p.join(p.sites.items[site].ret, val);
            },
            .for_of => {
                const f = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
                const items = try p.readAll(vals[f.iterable.int()]);
                try p.join(try p.nodeVar(mi, node, @fromBackingInt(@intCast(d.lhs))), items);
            },
            .throw_stmt => try p.escape(vals[d.lhs]),
            else => {},
        }
    }

    /// What an escaped site holds escapes, and an escaped function is
    /// called with anything and returns to anyone.
    fn propagate(p: *Pts) Allocator.Error!void {
        var i: usize = 0;
        while (i < p.sites.items.len) : (i += 1) {
            if (!p.sites.items[i].escaped) continue;
            const st = &p.sites.items[i];
            if (!st.all_read) {
                st.all_read = true;
                p.changed = true;
            }
            // A walk reads `any_written` (a spread copies it), so the
            // constraints that saw it unset are evaluated again, as `writeAnyOne`
            // wakes them: setting it here alone left a constraint evaluated earlier
            // in the sweep the site escaped in never to see it.
            try p.markAnyWritten(@intCast(i));
            for (p.sites.items[i].props.items) |pr| try p.escape(try p.fieldView(pr.vals));
            try p.escape(try p.view(p.sites.items[i].any));
            if (p.sites.items[i].kind == .func) {
                for (p.sites.items[i].params) |v| try p.makeTop(v);
                try p.escape(try p.view(p.sites.items[i].ret));
            }
        }
        try p.drain();
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
                    try found.appendSlice(p.run(), here.items);
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
        const x: NameIndex = @fromBackingInt(@intCast(ir.data(decl).lhs));
        for (items[at.index + 1 ..]) |stmt| {
            // A store of a record written in place stands as a statement of
            // its own (`Lower.settleStores`): read like `x.k = v`.
            const next: Index = if (ir.tag(stmt) == .expr_stmt and ir.tag(@fromBackingInt(@intCast(ir.data(stmt).lhs))) == .assign) @fromBackingInt(@intCast(ir.data(stmt).lhs)) else stmt;
            if (ir.tag(next) != .assign_stmt and ir.tag(next) != .assign) return;
            const target: Index = @fromBackingInt(@intCast(ir.data(next).lhs));
            if (ir.tag(target) != .member) return;
            const obj: Index = @fromBackingInt(@intCast(ir.data(target).lhs));
            if (ir.tag(obj) != .ident or ir.data(obj).lhs != x.int()) return;
            const id = p.propId(mi, @fromBackingInt(@intCast(ir.data(target).rhs)));
            if (id == none) return;
            if (!p.harmless(mi, @fromBackingInt(@intCast(ir.data(next).rhs)), x)) return;
            if (std.mem.indexOfScalar(u32, out.items, id) == null) try out.append(p.run(), id);
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
                    const obj: Index = @fromBackingInt(@intCast(ir.data(node).lhs));
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

    /// `v`, what chain `node` read, less what a live guard in view says
    /// it cannot be. A member read through a host value may run a getter,
    /// which a guard cannot vouch for.
    ///
    /// Evaluated alone (`evaluating`), the guards are the ones the first
    /// walk noted for the read: each live while none of the reads between
    /// its push and this one is through a `top` object (`Narrow`). A guard a
    /// call, an assignment or a declaration killed was never noted.
    fn narrowed(p: *Pts, mi: u32, node: Index, v: Val) Allocator.Error!Val {
        var out = v;
        const ir = p.s.mods[mi].ir;
        if (ir.tag(node) == .member and p.vals[mi][ir.data(node).lhs].top) {
            // The first walk returned here before it noted any guard.
            if (p.evaluating and p.cur != none and p.cons.items[p.cur].narrow_open) {
                p.cons.items[p.cur].narrow = none;
                p.cons.items[p.cur].narrow_open = false;
            }
            return out;
        }
        if (p.evaluating) {
            // Guards the extraction found, noted as the walk noted them: the
            // reads that kill each wake this one.
            if (p.cur != none and p.cons.items[p.cur].narrow_open) {
                const c = p.cur;
                p.cons.items[c].narrow_open = false;
                var n = p.cons.items[c].narrow;
                while (n != none) : (n = p.narrows.items[n].next) {
                    for (p.kills.items[p.narrows.items[n].start..p.narrows.items[n].end]) |killer| try p.link(killer, c);
                }
            }
            var k = p.cons.items[p.cur].narrow;
            each: while (k != none) : (k = p.narrows.items[k].next) {
                const n = p.narrows.items[k];
                for (p.kills.items[n.start..n.end]) |killer| if (p.cons.items[killer].val.top) continue :each;
                if (n.nul) out.nul = false;
                if (n.undef) out.undef = false;
            }
            return out;
        }
        return out;
    }

    /// Node `node`'s value, and what making it joined carried on: the end
    /// of a constraint's evaluation, where the worklist drains (`join`).
    fn combine(p: *Pts, mi: u32, node: Index) Allocator.Error!Val {
        const v = try p.combineNow(mi, node);
        try p.drain();
        return v;
    }

    fn combineNow(p: *Pts, mi: u32, node: Index) Allocator.Error!Val {
        const ir = p.s.mods[mi].ir;
        const vals = p.vals[mi];
        const d = ir.data(node);
        return switch (ir.tag(node)) {
            .number, .string, .template, .template_chunk, .true_lit, .false_lit => Val.prim_val,
            .null_lit => Val.nul_val,
            .undefined_lit => Val.undef_val,
            .global_this, .this_lit => Val.top_val,
            .ident => try p.narrowed(mi, node, try p.view(try p.nodeVar(mi, node, @fromBackingInt(@intCast(d.lhs))))),
            .member => blk: {
                const obj = vals[d.lhs];
                const id = p.propId(mi, @fromBackingInt(@intCast(d.rhs)));
                const raw = try p.load(mi, node, @fromBackingInt(@intCast(d.lhs)), obj, id);
                break :blk try p.narrowed(mi, node, raw);
            },
            // An index past the end is `undefined`.
            .index_get => blk: {
                var v = try p.readAll(vals[d.lhs]);
                if (vals[d.lhs].sites.len != 0) v.undef = true;
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
                            const at = try p.propAt(site, p.propId(mi, @fromBackingInt(@intCast(cd.lhs))));
                            const pr = &p.sites.items[site].props.items[at];
                            if (!pr.written) {
                                pr.written = true;
                                p.changed = true;
                            }
                            // The literal has the key: the property exists
                            // from the moment the object does. Set before
                            // the site reaches any var, so no read of it
                            // ever saw it missing.
                            pr.init = true;
                            try p.join(try p.ownField(site, at, pr.id), vals[cd.rhs]);
                            // A method in the literal reads and writes the
                            // object through `this` (`holdsMethod`).
                            if (p.holdsMethod(vals[cd.rhs])) {
                                try p.escapeSite(site);
                                try p.escape(vals[cd.rhs]);
                            }
                        },
                        // `{...x}` copies what `x` holds, reading all of it.
                        else => {
                            const from = vals[cd.lhs];
                            if (from.top or from.prim) try p.writeAnyOne(site, Val.top_val);
                            const operand: Index = @fromBackingInt(@intCast(cd.lhs));
                            if (ir.tag(operand) == .ident) {
                                // A spread of a name copies through the
                                // var's field summary: one copy edge per
                                // property of any site the var holds, and
                                // one dependency, on the summary. A record
                                // update spreads the record it updates, so
                                // every update of one record type shares
                                // one summary, and a value that reaches a
                                // field of one of them flows along the
                                // edges to every other (#464).
                                const v = try p.nodeVar(mi, operand, @fromBackingInt(@intCast(ir.data(operand).lhs)));
                                const sum = try p.summaryOf(v);
                                // Evaluated again when `v`'s summary, another
                                // var's, becomes its own (#568).
                                try p.seeAlias(v);
                                // Read whole: every site the name holds.
                                try p.markWhole(sum);
                                try p.seeSummary(sum);
                                if (p.summaries.items[sum].unknown) try p.writeAnyOne(site, Val.top_val);
                                // The literal's own keys, which a field
                                // the spread writes does not share.
                                p.lit_keys.clearRetainingCapacity();
                                for (ir.extraSlice(JsIr.inlineRange(d), Index)) |key| if (ir.tag(key) == .property) {
                                    try p.lit_keys.append(p.tmp.allocator(), p.propId(mi, @fromBackingInt(@intCast(ir.data(key).lhs))));
                                };
                                std.mem.sortUnstable(u32, p.lit_keys.items, {}, std.sort.asc(u32));
                                try p.spreadSummary(site, sum, p.lit_keys.items);
                                if (p.summaries.items[sum].any_written) {
                                    try p.seeSite(site);
                                    try p.markAnyWritten(site);
                                    try p.copy(p.summaries.items[sum].any, p.sites.items[site].any);
                                }
                            } else {
                                // Any other operand: copied site by site,
                                // and evaluated again when one changes.
                                for (from.sites) |other| {
                                    try p.seeSite(other);
                                    try p.seeProps(other);
                                    const st = &p.sites.items[other];
                                    if (!st.all_read and st.kind != .func and !st.escaped) {
                                        st.all_read = true;
                                        p.changed = true;
                                    }
                                    if (st.kind != .object) {
                                        try p.writeAnyOne(site, Val.top_val);
                                        continue;
                                    }
                                    var hint: usize = 0;
                                    var k: usize = 0;
                                    while (k < p.sites.items[other].props.items.len) : (k += 1) {
                                        const src = p.sites.items[other].props.items[k];
                                        const at = try p.propAtHint(site, src.id, &hint);
                                        const pr = &p.sites.items[site].props.items[at];
                                        if (!pr.written) {
                                            pr.written = true;
                                            p.changed = true;
                                        }
                                        const own = try p.ownField(site, at, src.id);
                                        try p.join(own, try p.fieldView(src.vals));
                                    }
                                    if (p.sites.items[other].any_written) try p.writeAnyOne(site, try p.view(p.sites.items[other].any));
                                }
                            }
                        },
                    }
                }
                break :blk .{ .sites = p.ones[site..][0..1] };
            },
            .array => blk: {
                const site = try p.siteOf(mi, node, .array);
                const pv = try p.ownField(site, try p.propAt(site, elem_prop), elem_prop);
                for (ir.extraSlice(JsIr.inlineRange(d), Index)) |child| try p.join(pv, vals[child.int()]);
                break :blk .{ .sites = p.ones[site..][0..1] };
            },
            .arrow => vals[node.int()],
            .cond => blk: {
                const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
                break :blk p.unionOf(vals[c.consequent.int()], vals[c.alternate.int()]);
            },
            .binary => blk: {
                const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                break :blk switch (@as(JsIr.BinaryOp, @fromBackingInt(@intCast(d.rhs)))) {
                    .logical_and, .logical_or => p.unionOf(vals[b.left.int()], vals[b.right.int()]),
                    else => Val.prim_val,
                };
            },
            .unary => if (@as(JsIr.UnaryOp, @fromBackingInt(@intCast(d.rhs))) == .yield) Val.top_val else Val.prim_val,
            .call => p.call(mi, node),
            .new_call => blk: {
                for (vals[d.lhs].sites) |site| p.sites.items[site].odd_caller = true;
                for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |a| try p.escape(vals[a.int()]);
                break :blk Val.top_val;
            },
            // A store of a record update written in place: what `effectNow`
            // does for `o.p = v`, and its value is `v`.
            .assign => blk: {
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                const td = ir.data(target);
                try p.write(vals[td.lhs], p.propId(mi, @fromBackingInt(@intCast(td.rhs))), vals[d.rhs]);
                break :blk vals[d.rhs];
            },
            .sequence => blk: {
                const parts = ir.extraSlice(JsIr.inlineRange(d), Index);
                break :blk vals[parts[parts.len - 1].int()];
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
        const vc = try p.view(p.globals[e.callee]);
        var unknown = vc.top or vc.prim;
        for (vc.sites) |site| {
            if (p.sites.items[site].kind != .func) {
                unknown = true;
                continue;
            }
            p.sites.items[site].odd_caller = true;
            const params = p.sites.items[site].params;
            for (params, 0..) |v, i| try p.join(v, if (i < e.args.len) try p.view(p.globals[e.args[i]]) else Val.undef_val);
        }
        if (unknown) for (e.args) |a| try p.escape(try p.view(p.globals[a]));
        try p.drain();
    }

    fn call(p: *Pts, mi: u32, node: Index) Allocator.Error!Val {
        const ir = p.s.mods[mi].ir;
        const vals = p.vals[mi];
        const d = ir.data(node);
        const callee: Index = @fromBackingInt(@intCast(d.lhs));
        const vc = vals[callee.int()];
        const args = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index);
        var out: Val = .{};
        var unknown = vc.top or vc.prim;
        for (vc.sites) |site| {
            if (p.sites.items[site].kind != .func) {
                unknown = true;
                continue;
            }
            const params = p.sites.items[site].params;
            for (params, 0..) |v, i| {
                if (i >= args.len) {
                    try p.join(v, Val.undef_val);
                } else if (try p.copySource(mi, args[i])) |from| {
                    // An argument that is a name or a member read is a
                    // copy (`effect`'s binding rule).
                    try p.copy(from, v);
                } else try p.join(v, vals[args[i].int()]);
            }
            out = try p.unionOf(out, try p.view(p.sites.items[site].ret));
            const key: NodeKey = .{ .module = mi, .node = node.int() };
            const callers = &p.sites.items[site].callers;
            const known_caller = for (callers.items) |k| {
                if (k.module == key.module and k.node == key.node) break true;
            } else false;
            if (!known_caller) try callers.append(p.run(), key);
        }
        if (unknown) {
            for (args) |a| try p.escape(vals[a.int()]);
            // A method the pass does not know may do anything with its
            // receiver, however its name is written (#685).
            if (ir.tag(callee) == .member or ir.tag(callee) == .index_get) try p.escape(vals[ir.data(callee).lhs]);
            out = try p.unionOf(out, Val.top_val);
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
                const n: NameIndex = @fromBackingInt(@intCast(d.lhs));
                if (p.s.mods[mi].globalOf(n)) |g| break :blk try p.view(p.globals[g]);
                const v = p.findLocal(mi, top, n) orelse break :blk null;
                break :blk try p.view(v);
            },
            .member => blk: {
                const obj = try p.chain(mi, top, @fromBackingInt(@intCast(d.lhs))) orelse break :blk null;
                break :blk try p.read(obj, p.propId(mi, @fromBackingInt(@intCast(d.rhs))), false);
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
                const obj = try p.safeChain(mi, top, @fromBackingInt(@intCast(d.lhs))) orelse break :blk null;
                if (!p.known(obj)) break :blk null;
                break :blk try p.read(obj, p.propId(mi, @fromBackingInt(@intCast(d.rhs))), false);
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
        if (id == none or !p.known(obj) or p.hostImplicit(id)) return false;
        for (obj.sites) |site| {
            if (p.sites.items[site].all_read) return false;
            if (p.findProp(site, id)) |pr| if (pr.read) return false;
        }
        return true;
    }

    /// Of object literal `node`, a site: whether key `id` is never read.
    /// A key this pass cannot name stays. A well-known symbol is not a
    /// string name, so a `.property` does not hold one.
    fn keyUnread(p: *const Pts, mi: u32, node: Index, id: u32) bool {
        if (!p.ok or id == none or p.hostImplicit(id)) return false;
        const site = p.siteAt(mi, node) orelse return false;
        const st = &p.sites.items[site];
        if (st.escaped or st.all_read) return false;
        if (p.findProp(site, id)) |pr| if (if (p.s.live_keys) pr.live_read else pr.read) return false;
        if (p.s.live_keys and id < p.s.id_read.len and p.s.id_read[id]) return false;
        return true;
    }

    /// Whether `id` is a name in `implicit_host_keys`.
    fn hostImplicit(p: *const Pts, id: u32) bool {
        for (p.s.in.implicit_props) |k| if (k == id) return true;
        return false;
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
/// In the same positions `x && true` and `x || false` are `x` (amended
/// 2026-10-15): what specialisation leaves of a schema reader's
/// `f === c.fail && !c.all` once it knows `c.all`.
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
    try JsIr.pushOperandSlice(gpa, &stack, ir.extraSlice(ir.body, Index));
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
        const node: Index = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
        const d = ir.data(node);
        // `!(a === b)` is `a !== b`, and the other way round, anywhere.
        if (ir.tag(node) == .unary and @as(JsIr.UnaryOp, @fromBackingInt(@intCast(d.rhs))) == .not) {
            const inner: Index = @fromBackingInt(@intCast(d.lhs));
            if (ir.tag(inner) == .binary and refs[inner.int()] == 1) {
                const flipped: ?JsIr.BinaryOp = switch (@as(JsIr.BinaryOp, @fromBackingInt(@intCast(ir.data(inner).rhs)))) {
                    .strict_eq => .strict_ne,
                    .strict_ne => .strict_eq,
                    else => null,
                };
                if (flipped) |op| {
                    ir.nodes.items(.tag)[node.int()] = .binary;
                    ir.nodes.items(.data)[node.int()] = .{ .lhs = ir.data(inner).lhs, .rhs = @backingInt(op) };
                    ir.clearNodeKey(node);
                    continue;
                }
            }
        }
        switch (ir.tag(node)) {
            .if_stmt, .cond => try tests.append(gpa, @fromBackingInt(@intCast(d.lhs))),
            .unary => if (@as(JsIr.UnaryOp, @fromBackingInt(@intCast(d.rhs))) == .not) try tests.append(gpa, @fromBackingInt(@intCast(d.lhs))),
            else => {},
        }
        while (tests.pop()) |t| {
            if (ir.tag(t) != .binary) continue;
            const td = ir.data(t);
            const op: JsIr.BinaryOp = @fromBackingInt(@intCast(td.rhs));
            const b = ir.extraData(@fromBackingInt(@intCast(td.lhs)), JsIr.Binary);
            switch (op) {
                .logical_and, .logical_or => {
                    // A logical operator referred to from anywhere else may
                    // be a value there, and then so are its operands: only
                    // an unshared one is a test all the way down.
                    if (refs[t.int()] > 1) continue;
                    // `x && true` and `x || false` are `x` in a test: the
                    // literal decides nothing and evaluates nothing, so the
                    // operator's value is truthy exactly when `x` is.
                    const neutral: JsIr.Node.Tag = if (op == .logical_and) .true_lit else .false_lit;
                    if (ir.tag(b.right) == neutral and refs[t.int()] <= 1 and refs[b.left.int()] <= 1) {
                        ir.nodes.items(.tag)[t.int()] = ir.tag(b.left);
                        ir.nodes.items(.data)[t.int()] = ir.data(b.left);
                        ir.nodes.items(.pos)[t.int()] = ir.pos(b.left);
                        ir.clearNodeKey(t);
                        try tests.append(gpa, t);
                        continue;
                    }
                    try tests.appendSlice(gpa, &.{ b.left, b.right });
                },
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
                        datas[t.int()] = .{ .lhs = bits.int(), .rhs = @backingInt(JsIr.UnaryOp.not) };
                    }
                },
                else => {},
            }
        }
    }
}

/// Every child of `node` onto `stack`: a statement's expressions and
/// statements, an expression's operands, and a function's body.
pub fn pushChildren(gpa: Allocator, ir: *const JsIr, node: Index, stack: *std.ArrayList(Index)) Allocator.Error!void {
    const d = ir.data(node);
    switch (ir.tag(node)) {
        .import_stmt, .export_stmt, .break_stmt, .continue_stmt => {},
        .const_decl => try JsIr.pushOperand(gpa, stack, @fromBackingInt(@intCast(d.rhs))),
        .let_decl => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| try JsIr.pushOperand(gpa, stack, v),
        .func_decl, .gen_decl => try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Func).body(), Index)),
        .arrow => try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Func).body(), Index)),
        .assign_stmt => try JsIr.pushOperandSlice(gpa, stack, &.{ @fromBackingInt(@intCast(d.lhs)), @fromBackingInt(@intCast(d.rhs)) }),
        .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try JsIr.pushOperand(gpa, stack, v),
        .if_stmt => {
            try JsIr.pushOperand(gpa, stack, @fromBackingInt(@intCast(d.lhs)));
            const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
            try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(b.thenBody(), Index));
            try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(b.elseBody(), Index));
        },
        .while_true, .block_stmt => try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)),
        .for_of => {
            const loop = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf);
            try JsIr.pushOperand(gpa, stack, loop.iterable);
            try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(loop.body(), Index));
        },
        .switch_stmt => {
            try JsIr.pushOperand(gpa, stack, @fromBackingInt(@intCast(d.lhs)));
            try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index));
        },
        .switch_case => {
            if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |t| try JsIr.pushOperand(gpa, stack, t);
            try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index));
        },
        .expr_stmt, .throw_stmt => try JsIr.pushOperand(gpa, stack, @fromBackingInt(@intCast(d.lhs))),
        .try_stmt => {
            const t = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try);
            try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(t.body(), Index));
            try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(t.finalBody(), Index));
            try JsIr.pushOperandSlice(gpa, stack, ir.extraSlice(t.catchBody(), Index));
        },
        // An expression's operands, as `JsIr.pushOperands` pushes them,
        // written out: the walks that ask for every node's children ask a
        // million times over a page, and one exhaustive `switch` is one
        // jump where an `else` prong first checks the tag in Zig's own
        // backend, and a second call checks it again.
        .ident, .field_name, .number, .string, .template_chunk, .regex, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit => {},
        .member, .unary, .spread_property => try JsIr.pushOperand(gpa, stack, @fromBackingInt(@intCast(d.lhs))),
        .index_get => try JsIr.pushOperandSlice(gpa, stack, &.{ @fromBackingInt(@intCast(d.rhs)), @fromBackingInt(@intCast(d.lhs)) }),
        .property => try JsIr.pushOperand(gpa, stack, @fromBackingInt(@intCast(d.rhs))),
        .call, .new_call => {
            try JsIr.pushReversed(gpa, stack, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index));
            try JsIr.pushOperand(gpa, stack, @fromBackingInt(@intCast(d.lhs)));
        },
        .object, .array, .template => try JsIr.pushReversed(gpa, stack, ir.extraSlice(JsIr.inlineRange(d), Index)),
        .cond => {
            const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
            try JsIr.pushOperandSlice(gpa, stack, &.{ c.alternate, c.consequent, @fromBackingInt(@intCast(d.lhs)) });
        },
        .binary => {
            const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
            try JsIr.pushOperandSlice(gpa, stack, &.{ b.right, b.left });
        },
        .assign => try JsIr.pushOperandSlice(gpa, stack, &.{ @fromBackingInt(@intCast(d.rhs)), @fromBackingInt(@intCast(d.lhs)) }),
        .sequence => try JsIr.pushReversed(gpa, stack, ir.extraSlice(JsIr.inlineRange(d), Index)),
    }
}

/// How many times `top` declares name `n`: a `const`, `let`, `function` or
/// `for…of` binding, or a parameter of a function in it (`Spec.nameScan`).
fn declCount(s: *Spec, m: *Mod, top: Index, n: NameIndex) Allocator.Error!u32 {
    const u = try s.usesOf(m, top, n) orelse return 0;
    return u.decls;
}

/// Whether `Pts.combine` makes `node`'s value from its tag alone, reading
/// nothing and joining nothing: a unary operator, an operator but `&&` and
/// `||`, a template. The first walk's value is its value for good, and no
/// constraint is made of it (`Pts.byConstraints`).
fn constantValue(ir: *const JsIr, node: Index) bool {
    return switch (ir.tag(node)) {
        .unary, .template => true,
        .binary => switch (@as(JsIr.BinaryOp, @fromBackingInt(@intCast(ir.data(node).rhs)))) {
            .logical_and, .logical_or => false,
            else => true,
        },
        else => false,
    };
}

/// The nodes whose values `Pts.combine` (or, for a statement, `Pts.effect`)
/// reads when it evaluates `node`, but a call's arguments and an array's or
/// an object's elements, which `Pts.begin` adds: at most three, in `buf`.
fn inputsOf(ir: *const JsIr, node: Index, buf: *[3]Index) []const Index {
    const d = ir.data(node);
    const at = struct {
        fn idx(x: u32) Index {
            return @fromBackingInt(@intCast(x));
        }
    }.idx;
    switch (ir.tag(node)) {
        .const_decl, .let_decl => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| {
            buf[0] = v;
            return buf[0..1];
        },
        .assign_stmt => {
            buf[0] = at(d.rhs);
            const target = at(d.lhs);
            switch (ir.tag(target)) {
                .member, .index_get => {
                    buf[1] = at(ir.data(target).lhs);
                    return buf[0..2];
                },
                else => return buf[0..1],
            }
        },
        .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| {
            buf[0] = v;
            return buf[0..1];
        },
        .for_of => {
            buf[0] = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf).iterable;
            return buf[0..1];
        },
        .throw_stmt, .member, .index_get, .spread_property => {
            buf[0] = at(d.lhs);
            return buf[0..1];
        },
        .property => {
            buf[0] = at(d.rhs);
            return buf[0..1];
        },
        .cond => {
            const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
            buf[0] = c.consequent;
            buf[1] = c.alternate;
            return buf[0..2];
        },
        .binary => {
            const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
            buf[0] = b.left;
            buf[1] = b.right;
            return buf[0..2];
        },
        // The callee, and the object whose method it is: it escapes with
        // the arguments when the callee may be code the pass cannot see.
        .call => {
            buf[0] = at(d.lhs);
            if (ir.tag(buf[0]) != .member) return buf[0..1];
            buf[1] = at(ir.data(buf[0]).lhs);
            return buf[0..2];
        },
        // A store's value, and the object it writes (`Pts.combineNow`).
        .assign => {
            buf[0] = at(d.rhs);
            buf[1] = at(ir.data(at(d.lhs)).lhs);
            return buf[0..2];
        },
        .sequence => {
            const parts = ir.extraSlice(JsIr.inlineRange(d), Index);
            buf[0] = parts[parts.len - 1];
            return buf[0..1];
        },
        .new_call => {
            buf[0] = at(d.lhs);
            return buf[0..1];
        },
        else => {},
    }
    return buf[0..0];
}

/// The expression operands of any node, statements' included.
fn operandsOf(gpa: Allocator, ir: *const JsIr, node: Index, out: *std.ArrayList(Index)) Allocator.Error!void {
    const d = ir.data(node);
    switch (ir.tag(node)) {
        .const_decl, .let_decl => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs))).unwrap()) |v| try out.append(gpa, v),
        .assign_stmt => try out.appendSlice(gpa, &.{ @fromBackingInt(@intCast(d.lhs)), @fromBackingInt(@intCast(d.rhs)) }),
        .return_stmt, .switch_case => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| try out.append(gpa, v),
        .if_stmt, .switch_stmt, .expr_stmt, .throw_stmt => try out.append(gpa, @fromBackingInt(@intCast(d.lhs))),
        .for_of => try out.append(gpa, ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.ForOf).iterable),
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
    return switch (@as(JsIr.BinaryOp, @fromBackingInt(@intCast(ir.data(node).rhs)))) {
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
    const op: JsIr.BinaryOp = @fromBackingInt(@intCast(ir.data(node).rhs));
    const b = ir.extraData(@fromBackingInt(@intCast(ir.data(node).lhs)), JsIr.Binary);
    const chain, const other = if (ir.tag(b.right) == .null_lit) .{ b.left, b.right } else .{ b.right, b.left };
    if (ir.tag(other) != .null_lit) return null;
    switch (ir.tag(chain)) {
        .ident, .member => {},
        else => return null,
    }
    var x = chain;
    while (ir.tag(x) == .member) x = @fromBackingInt(@intCast(ir.data(x).lhs));
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
                x = @fromBackingInt(@intCast(dx.lhs));
                y = @fromBackingInt(@intCast(dy.lhs));
            },
            else => return false,
        }
    }
    return false;
}

/// Whether statement `stmt` may complete normally, so that the statement
/// after it in its list may run: not a `return`, `throw`, `break` or
/// `continue`, nor an `if` neither of whose arms may, nor an unlabelled block
/// that may not. Any other statement may, as far as this says.
fn completes(ir: *const JsIr, stmt: Index, depth: u32) bool {
    if (depth > 64) return true;
    switch (ir.tag(stmt)) {
        .return_stmt, .throw_stmt, .break_stmt, .continue_stmt => return false,
        .if_stmt => {
            const b = ir.extraData(@fromBackingInt(@intCast(ir.data(stmt).rhs)), JsIr.If);
            return completesList(ir, b.thenBody(), depth + 1) or completesList(ir, b.elseBody(), depth + 1);
        },
        .block_stmt => {
            // A labelled block may be left by its `break`.
            if (@as(NameIndex, @fromBackingInt(@intCast(ir.data(stmt).lhs))) != .none) return true;
            return completesList(ir, ir.subRange(@fromBackingInt(@intCast(ir.data(stmt).rhs))), depth + 1);
        },
        else => return true,
    }
}

/// Whether a statement list may complete normally, by its last statement
/// alone: a jump before it makes the list not complete either, so this may
/// say "may" where it does not, never the other way — and `foldList` cuts
/// what follows a jump in each list before it asks of the list around it.
fn completesList(ir: *const JsIr, range: JsIr.SubRange, depth: u32) bool {
    const items = ir.extraSlice(range, Index);
    if (items.len == 0) return true;
    return completes(ir, items[items.len - 1], depth);
}

/// Count what node `node` declares (`counts[2 * name]`, each also appended to
/// `declared`) and the names it mentions (`counts[2 * name + 1]`): an
/// identifier, and the label of a `break` or `continue`.
fn nameUses(gpa: Allocator, ir: *const JsIr, node: Index, counts: []u32, declared: *std.ArrayList(u32)) Allocator.Error!void {
    const d = ir.data(node);
    const Count = struct {
        fn decl(c: []u32, out: *std.ArrayList(u32), a: Allocator, n: NameIndex) Allocator.Error!void {
            const i = n.unwrap() orelse return;
            if (2 * i >= c.len) return;
            c[2 * i] += 1;
            try out.append(a, i);
        }
        fn params(c: []u32, out: *std.ArrayList(u32), a: Allocator, f: *const JsIr, record: ExtraIndex) Allocator.Error!void {
            for (f.extraSlice(f.extraData(record, JsIr.Func).params(), NameIndex)) |p| try decl(c, out, a, p);
        }
    };
    switch (ir.tag(node)) {
        .ident, .break_stmt, .continue_stmt => if (@as(NameIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |i| {
            if (2 * i + 1 < counts.len) counts[2 * i + 1] += 1;
        },
        .const_decl, .let_decl, .for_of, .while_true, .block_stmt => try Count.decl(counts, declared, gpa, @fromBackingInt(@intCast(d.lhs))),
        .func_decl, .gen_decl => {
            try Count.decl(counts, declared, gpa, @fromBackingInt(@intCast(d.lhs)));
            try Count.params(counts, declared, gpa, ir, @fromBackingInt(@intCast(d.rhs)));
        },
        .arrow => try Count.params(counts, declared, gpa, ir, @fromBackingInt(@intCast(d.lhs))),
        .try_stmt => try Count.decl(counts, declared, gpa, ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Try).catch_name),
        else => {},
    }
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
                const branches = ir.extraData(@fromBackingInt(@intCast(ir.data(last).rhs)), JsIr.If);
                if (fallsThrough(ir, branches.thenBody())) return true;
                list = ir.extraSlice(branches.elseBody(), Index);
            },
            .block_stmt => {
                // A labelled block may be left by its `break`.
                if (@as(NameIndex, @fromBackingInt(@intCast(ir.data(last).lhs))) != .none) return true;
                list = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(last).rhs))), Index);
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
/// Whether `stmt` is an expression statement of a literal alone.
/// The call `((p…) => …)(a…)` that is statement `stmt`'s value — a `const`
/// or `let`'s initialiser, a `return`'s value, or the statement itself — of
/// an ordinary arrow (`arrow_plain`: no default, not a method); or null.
fn iifeOf(ir: *const JsIr, stmt: Index) ?Index {
    const d = ir.data(stmt);
    const value: Index = switch (ir.tag(stmt)) {
        .const_decl, .let_decl => (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.rhs)))).unwrap() orelse return null,
        .return_stmt => (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs)))).unwrap() orelse return null,
        .expr_stmt => @fromBackingInt(@intCast(d.lhs)),
        else => return null,
    };
    if (ir.tag(value) != .call) return null;
    const callee: Index = @fromBackingInt(@intCast(ir.data(value).lhs));
    if (ir.tag(callee) != .arrow or ir.data(callee).rhs != Node.arrow_plain) return null;
    return value;
}

fn literalStmt(ir: *const JsIr, stmt: Index) bool {
    if (ir.tag(stmt) != .expr_stmt) return false;
    return switch (ir.tag(@fromBackingInt(@intCast(ir.data(stmt).lhs)))) {
        .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => true,
        else => false,
    };
}

/// How deep `pureCall` follows a call that is an argument of a call.
const max_pure_depth = 8;

/// Whether calling function `node` — an arrow of any kind, or a `function`
/// declaration — does nothing but make its value: its body is empty, or
/// one `return` whose value, when it has one, is `inert`. A `JsIr`
/// function's parameters are plain names, with no pattern and no default
/// but `arrow_depth`'s literal `0`, so binding them does nothing either.
/// A generator's call makes an object without running its body, and is
/// not asked about here.
fn makesOnly(ir: *const JsIr, node: Index) bool {
    const record: ExtraIndex = switch (ir.tag(node)) {
        .arrow => @fromBackingInt(@intCast(ir.data(node).lhs)),
        .func_decl => @fromBackingInt(@intCast(ir.data(node).rhs)),
        else => return false,
    };
    const body = ir.extraSlice(ir.extraData(record, JsIr.Func).body(), Index);
    if (body.len == 0) return true;
    if (body.len != 1 or ir.tag(body[0]) != .return_stmt) return false;
    const value: Node.OptionalIndex = @fromBackingInt(@intCast(ir.data(body[0]).lhs));
    return if (value.unwrap()) |e| inert(ir, e) or plainValue(ir, e, 0) else true;
}

/// An expression whose evaluation cannot throw, run code or read a property:
/// names, literals, and `===`, `!==`, `!`, `typeof`, `&&`, `||` and a
/// conditional of such — `endpointOf`'s `a === 0 ? 0 : 1`.
fn plainValue(ir: *const JsIr, node: Index, depth: u32) bool {
    if (depth > 32) return false;
    const d = ir.data(node);
    return switch (ir.tag(node)) {
        .ident, .field_name, .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => true,
        .unary => switch (@as(JsIr.UnaryOp, @fromBackingInt(@intCast(d.rhs)))) {
            .not, .type_of => plainValue(ir, @fromBackingInt(@intCast(d.lhs)), depth + 1),
            else => false,
        },
        .binary => switch (@as(JsIr.BinaryOp, @fromBackingInt(@intCast(d.rhs)))) {
            .strict_eq, .strict_ne, .logical_and, .logical_or => blk: {
                const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                break :blk plainValue(ir, b.left, depth + 1) and plainValue(ir, b.right, depth + 1);
            },
            else => false,
        },
        .cond => blk: {
            const c = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.Cond);
            break :blk plainValue(ir, @fromBackingInt(@intCast(d.lhs)), depth + 1) and plainValue(ir, c.consequent, depth + 1) and plainValue(ir, c.alternate, depth + 1);
        },
        else => false,
    };
}

/// `inert`, for the emitter's reachability after the optimiser.
pub fn isInert(ir: *const JsIr, root: Index) bool {
    return inert(ir, root);
}

fn inert(ir: *const JsIr, root: Index) bool {
    return inertOf(ir, root, true);
}

/// `inert`, with `field_reads` whether a beni field read counts as one. A
/// field read is effect-free, so whatever only drops or keeps a value asks
/// with it. Whatever MOVES a value later asks without (`backend.md` §9
/// item 1, amended 2026-10-18, *the ordering rule*): a top-level value made
/// at its read (`writeReads`), an argument made where the body reads it
/// (`inlineAt`), an object literal's names read where `R` reads them —
/// each would cross code that may write the record. `soleCalls` asks
/// without too: a place holding a field read is not a place that only
/// holds the value it is.
fn inertOf(ir: *const JsIr, root: Index, comptime field_reads: bool) bool {
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
            .arrow, .ident, .field_name, .number, .string, .template_chunk, .true_lit, .false_lit, .null_lit, .undefined_lit, .global_this, .this_lit => {},
            .property => {
                if (len == stack.len) return false;
                stack[len] = @fromBackingInt(@intCast(d.rhs));
                len += 1;
            },
            // A beni record's field: no getter, no throw, and nothing
            // changes it (`backend.md` §9, *A field read of a beni value
            // is pure*).
            .member => {
                if (!field_reads or !ir.isFieldRead(node)) return false;
                if (len == stack.len) return false;
                stack[len] = @fromBackingInt(@intCast(d.lhs));
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// What a whole-program pass over no modules sets up, for a test of `Pts`
/// alone.
fn emptySpec(gpa: Allocator, arena: Allocator) Allocator.Error!Spec {
    return Spec.init(gpa, arena, .{ .modules = &.{}, .globals = 0, .escaping = &.{} });
}

// Research 52's E5: with the inlining passes' cap raised, four `browser/tea`
// pages read `0xAAAAAAAA` as a site in `Pts.escapeSite`. A walk holds the
// values of an expression's earlier operands while it evaluates the later
// ones, and a call among those joined a site into the very var an earlier
// operand had read — whose set the earlier value still pointed into, and
// which the join shifted, or moved and freed. No corpus program reaches it
// under the passes' cap, so the smallest input is the var itself: a value
// read from it must stay what it was read as when a join grows it, both
// where the new site goes in front of the others (a shift) and past the
// set's first allocation (a move).
test "a value read from a var keeps its sites when a later join adds one" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = try emptySpec(testing.allocator, arena);
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const v = try p.newVar();
    var want: std.ArrayList(u32) = .empty;
    for (0..Pts.max_sites - 1) |i| {
        const read = try p.view(v);
        const before = try arena.dupe(u32, read.sites);
        // In front: every site already there moves up one.
        const site: u32 = @intCast(2 * (Pts.max_sites - i));
        try p.addSite(v, site);
        try p.drain();
        try testing.expectEqualSlices(u32, before, read.sites);
        try want.insert(arena, 0, site);
    }
    try testing.expectEqualSlices(u32, want.items, (try p.view(v)).sites);
}

// #464: the points-to fixpoint repeatedly joins the same site facts.
// Allocating another immutable snapshot when the union adds no sites made
// N16 of unique-components retain hundreds of MB within one fixpoint. Four
// sites suffice: repeated equal and contained unions must keep bounded
// space, preserve every flag, and leave the earlier values unchanged.
test "repeated points-to unions of settled site facts keep bounded space" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    var storage: [8192]u8 = undefined;
    var bounded: std.heap.FixedBufferAllocator = .init(&storage);
    s.pts.tmp.main.deinit();
    // One chunk of all the storage there is: the run arena never opens a
    // second, so the unions must fit in it.
    s.pts.tmp.main = .{ .backing = bounded.allocator(), .next_chunk_size = storage.len - 16 };
    const sites = [_]u32{ 1, 3, 5, 7 };
    const equal = [_]u32{ 1, 3, 5, 7 };
    const subset = [_]u32{ 3, 7 };
    const all: Pts.Val = .{ .sites = &sites, .prim = true };
    const contained: Pts.Val = .{ .sites = &subset, .nul = true };
    for (0..512) |_| {
        const forward = try s.pts.unionOf(all, contained);
        const backward = try s.pts.unionOf(contained, all);
        const same = try s.pts.unionOf(all, .{ .sites = &equal, .undef = true });
        for ([_]Pts.Val{ forward, backward, same }) |v| try testing.expectEqualSlices(u32, &sites, v.sites);
        try testing.expect(forward.prim and forward.nul and !forward.undef and !forward.top);
        try testing.expect(backward.prim and backward.nul and !backward.undef and !backward.top);
        try testing.expect(same.prim and same.undef and !same.nul and !same.top);
    }
    // A common prefix is insufficient for containment, in either order.
    const mixed = try s.pts.unionOf(all, .{ .sites = &.{ 3, 8 }, .nul = true });
    const reverse = try s.pts.unionOf(.{ .sites = &.{ 3, 8 }, .undef = true }, all);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 5, 7, 8 }, mixed.sites);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 5, 7, 8 }, reverse.sites);
    try testing.expect(mixed.prim and mixed.nul and !mixed.undef);
    try testing.expect(reverse.prim and reverse.undef and !reverse.nul);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 5, 7 }, all.sites);
    try testing.expectEqualSlices(u32, &.{ 3, 7 }, contained.sites);
}

// A computed read repeatedly unions separately stored sparse property values
// into a broad settled result. Its work must follow the small operand rather
// than scanning the broad set again for each unchanged read.
test "points-to sparse subset unions have bounded work" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    var large: [1024]u32 = undefined;
    for (&large, 0..) |*site, i| site.* = @intCast(i);
    const sparse = [_]u32{ 100, 200, 400, 600, 800, 1023 };
    const a: Pts.Val = .{ .sites = &large, .prim = true, .nul = true };
    const b: Pts.Val = .{ .sites = &sparse, .top = true, .undef = true };
    var flags: usize = 0;
    var result: Pts.Val = .{};
    for (0..131072) |i| {
        result = if (i % 2 == 0) try s.pts.unionOf(a, b) else try s.pts.unionOf(b, a);
        flags += @intFromBool(result.top and result.prim and result.nul and result.undef);
    }
    try testing.expectEqual(131072, flags);
    try testing.expectEqualSlices(u32, &large, result.sites);
}

test "points-to membership search preserves dense sparse and absent sites" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    var equal = [_]u32{ 0, 2, 4, 6 };
    const cases = [_]struct { a: []const u32, b: []const u32, expected: []const u32 }{
        .{ .a = &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, .b = &.{ 2, 3, 4 }, .expected = &.{ 0, 1, 2, 3, 4, 5, 6, 7 } },
        .{ .a = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, .b = &.{ 1, 8, 15 }, .expected = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } },
        .{ .a = &.{ 0, 2, 4, 6, 8, 10, 12 }, .b = &.{ 2, 6, 10 }, .expected = &.{ 0, 2, 4, 6, 8, 10, 12 } },
        .{ .a = &.{ 0, 2, 4, 6 }, .b = &equal, .expected = &.{ 0, 2, 4, 6 } },
        .{ .a = &.{ 2, 4, 6 }, .b = &.{ 1, 4 }, .expected = &.{ 1, 2, 4, 6 } },
        .{ .a = &.{ 0, 2, 4, 6 }, .b = &.{ 2, 3, 4 }, .expected = &.{ 0, 2, 3, 4, 6 } },
        .{ .a = &.{ 0, 2, 4, 6 }, .b = &.{ 2, 4, 7 }, .expected = &.{ 0, 2, 4, 6, 7 } },
        .{ .a = &.{ 0, 2, 4, 6 }, .b = &.{ 8, 9, 10 }, .expected = &.{ 0, 2, 4, 6, 8, 9, 10 } },
        .{ .a = &.{}, .b = &.{ 2, 4 }, .expected = &.{ 2, 4 } },
    };
    for (cases) |case| {
        const a: Pts.Val = .{ .sites = case.a, .prim = true, .nul = true };
        const b: Pts.Val = .{ .sites = case.b, .top = true, .undef = true };
        const forward = try s.pts.unionOf(a, b);
        const reverse = try s.pts.unionOf(b, a);
        try testing.expectEqualSlices(u32, case.expected, forward.sites);
        try testing.expectEqualSlices(u32, case.expected, reverse.sites);
        try testing.expect(forward.top and forward.prim and forward.nul and forward.undef);
        try testing.expect(reverse.top and reverse.prim and reverse.nul and reverse.undef);
    }
}

// #464: dependency records are abandoned at the next fixpoint, but their
// backing arrays used to remain in the whole-compilation arena. Repeat a
// tiny fixpoint's dependency pool in bounded outer storage: earlier pools
// must be reclaimable, while each live dependency chain remains intact.
test "points-to dependency storage is reclaimed between fixpoints" {
    var storage: [8192]u8 = undefined;
    var bounded: std.heap.FixedBufferAllocator = .init(&storage);
    var s = try emptySpec(testing.allocator, bounded.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    for (0..64) |_| {
        try p.reset();
        p.cur = 7;
        var head = none;
        for (0..64) |_| head = try p.addDep(head);
        var count: u32 = 0;
        while (head != none) : (count += 1) {
            try testing.expectEqual(7, p.deps.items[head].stmt);
            head = p.deps.items[head].next;
        }
        try testing.expectEqual(64, count);
    }
}

// #574: every fixpoint took its per-node and per-name columns anew from the
// compilation's arena, six times a release build, and its own arena gave
// its chunks back and mapped them again, so each run faulted its memory in
// afresh. A fixpoint takes nothing from the compilation's arena, a second
// one no new chunk, and its columns are the first's memory, filled again.
test "a second fixpoint takes no new column and no new chunk" {
    const gpa = testing.allocator;
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    _ = try b.intern(.local(@fromBackingInt(@intCast(0))));
    _ = try b.intern(.local(@fromBackingInt(@intCast(1))));
    var stmts: [64]Index = undefined;
    for (&stmts) |*st| {
        const t = try b.addNode(.{ .tag = .true_lit, .pos = Node.no_pos, .data = .{ .lhs = 0, .rhs = 0 } });
        st.* = try b.addNode(.{ .tag = .expr_stmt, .pos = Node.no_pos, .data = .{ .lhs = t.int(), .rhs = 0 } });
    }
    var ir = try b.toOwned(try b.addRange(&stmts));
    defer ir.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    // The compilation's arena, and what the run arena's chunks come from.
    var compilation: std.testing.FailingAllocator = .init(arena_state.allocator(), .{});
    var chunks: std.testing.FailingAllocator = .init(gpa, .{});
    const modules = [_]Module{.{ .ir = &ir, .global = &.{ none, none } }};
    var s = try Spec.init(chunks.allocator(), compilation.allocator(), .{ .modules = &modules, .globals = 2, .escaping = &.{} });
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const taken = compilation.allocations;
    try p.reset();
    const opened = chunks.allocations;
    const vals = p.vals[0].ptr;
    const node_var = p.node_var[0].ptr;
    for (0..3) |_| {
        // What a run leaves behind, which the next must not read.
        @memset(p.vals[0], Pts.Val.prim_val);
        @memset(p.site_of[0], 0);
        @memset(p.name_top[0], 0);
        @memset(p.node_top[0], 0);
        try p.reset();
        try testing.expectEqual(taken, compilation.allocations);
        try testing.expectEqual(opened, chunks.allocations);
        try testing.expectEqual(@as(usize, 0), chunks.deallocations);
        try testing.expectEqual(vals, p.vals[0].ptr);
        try testing.expectEqual(node_var, p.node_var[0].ptr);
        try testing.expectEqual(ir.nodes.len, p.vals[0].len);
        for (p.vals[0]) |v| try testing.expect(v.top and v.prim and v.nul and v.undef and v.sites.len == 0);
        for (p.site_of[0]) |x| try testing.expectEqual(none, x);
        for (p.name_top[0]) |x| try testing.expectEqual(none, x);
        for (p.node_top[0]) |x| try testing.expectEqual(none, x);
        try testing.expectEqual(@as(usize, 2), p.globals.len);
        try testing.expectEqual(@as(usize, 2), p.vars.items.len);
        try testing.expectEqual(stmts.len, p.stmts.items.len);
    }
}

test "a key map's removal keeps every other key reachable" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Enough keys in a small table that probe runs wrap and cross: each
    // removal must move back exactly the entries whose home allows it.
    var map: KeyMap(Spec.NodeRef, u32) = .empty;
    const n = 200;
    for (0..n) |i| try map.put(arena, .{ .module = @intCast(i % 3), .node = @intCast(i) }, @intCast(i));
    for (0..n) |i| if (i % 3 != 1) map.remove(.{ .module = @intCast(i % 3), .node = @intCast(i) });
    // Removing what is not there changes nothing.
    map.remove(.{ .module = 7, .node = 7 });
    var left: u32 = 0;
    for (0..n) |i| {
        const got = map.get(.{ .module = @intCast(i % 3), .node = @intCast(i) });
        if (i % 3 == 1) {
            try testing.expectEqual(@as(?u32, @intCast(i)), got);
            left += 1;
        } else try testing.expectEqual(@as(?u32, null), got);
    }
    try testing.expectEqual(left, map.count());
}

/// The `ident` a member chain `a.b.c` reads first, or null when its base is
/// not a name.
fn memberBase(ir: *const JsIr, node: Index) ?Index {
    var n = node;
    var budget: u32 = 64;
    while (budget > 0) : (budget -= 1) {
        switch (ir.tag(n)) {
            .member => n = @fromBackingInt(@intCast(ir.data(n).lhs)),
            .ident => return n,
            else => return null,
        }
    }
    return null;
}

/// What the member chain `node`, on `x`, reads when `x` is `p`: through
/// the object literals it meets, the value it ends at — or the first value
/// that is not an object literal, which the rest of the chain reads
/// properties of. Null when a literal does not hold the key it reads.
fn project(ir: *const JsIr, node: Index, x: NameIndex, p: Index) ?Index {
    var keys: [64]NameIndex = undefined;
    var len: usize = 0;
    var n = node;
    while (ir.tag(n) == .member) {
        if (len == keys.len) return null;
        keys[len] = @fromBackingInt(@intCast(ir.data(n).rhs));
        len += 1;
        n = @fromBackingInt(@intCast(ir.data(n).lhs));
    }
    if (ir.tag(n) != .ident or ir.data(n).lhs != x.int()) return null;
    var v = p;
    while (len > 0) {
        len -= 1;
        if (ir.tag(v) != .object) return v;
        v = propertyOf(ir, v, keys[len]) orelse return null;
    }
    return v;
}

/// `Spec.onlyCased` over statement `top` (the site's function), the rest
/// `rest` after the site and its binding `x`: whether every mention of `x`
/// and of its aliases is a property read, a comparison with something else,
/// or a return's whole value (`returnedWhole`), and no property of one is
/// written. `sole.once(z)` says whether alias `z` is declared once and never
/// assigned.
fn casedOnly(arena: Allocator, ir: *const JsIr, top: Index, x: NameIndex, rest: []const Index, sole: anytype) Allocator.Error!bool {
    // `x` and its aliases: a `const z = x` of the rest, `z` declared
    // once and never assigned — a `case`'s pattern binding the value
    // its constructor fold left (`const new = x`). Each is held to
    // what `x` is.
    var names: std.ArrayList(u32) = .empty;
    try names.append(arena, x.int());
    var aliases: std.ArrayList(Index) = .empty;
    var decls: std.ArrayList(Index) = .empty;
    {
        var walk: std.ArrayList(Index) = .empty;
        for (rest) |r| try JsIr.pushOperand(arena, &walk, r);
        while (JsIr.popOperand(&walk)) |node| {
            if (ir.tag(node) == .const_decl) try decls.append(arena, node);
            try pushChildren(arena, ir, node, &walk);
        }
    }
    var grew = true;
    while (grew) {
        grew = false;
        for (decls.items) |node| {
            if (ir.tag(node) != .const_decl) continue;
            const from = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(node).rhs)))).unwrap() orelse continue;
            if (ir.tag(from) != .ident or std.mem.indexOfScalar(u32, names.items, ir.data(from).lhs) == null) continue;
            if (std.mem.indexOfScalar(Index, aliases.items, from) != null) continue;
            const z: NameIndex = @fromBackingInt(@intCast(ir.data(node).lhs));
            if (z == .none or ir.name(z).module != .none) return false;
            if (!try sole.once(z)) return false;
            try aliases.append(arena, from);
            if (std.mem.indexOfScalar(u32, names.items, z.int()) == null) try names.append(arena, z.int());
            grew = true;
        }
    }
    var whole: std.ArrayList(Index) = .empty;
    for (names.items) |n| try returnedWhole(arena, ir, rest, @fromBackingInt(@intCast(n)), &whole);
    try whole.appendSlice(arena, aliases.items);
    const held = struct {
        fn is(r: *const JsIr, list: []const u32, node: Index) bool {
            return r.tag(node) == .ident and std.mem.indexOfScalar(u32, list, r.data(node).lhs) != null;
        }
    };
    var stack: std.ArrayList(Index) = .empty;
    try JsIr.pushOperand(arena, &stack, top);
    while (JsIr.popOperand(&stack)) |node| {
        const d = ir.data(node);
        switch (ir.tag(node)) {
            .ident => if (held.is(ir, names.items, node) and std.mem.indexOfScalar(Index, whole.items, node) == null) return false,
            .member => {
                const obj: Index = @fromBackingInt(@intCast(d.lhs));
                if (held.is(ir, names.items, obj)) continue;
            },
            .binary => {
                const op: JsIr.BinaryOp = @fromBackingInt(@intCast(d.rhs));
                if (op == .strict_eq or op == .strict_ne) {
                    const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
                    // `x === z` of an alias would be decided `false`
                    // of an object literal: refused.
                    if (held.is(ir, names.items, b.left) and held.is(ir, names.items, b.right)) return false;
                    for ([_]Index{ b.left, b.right }) |side| {
                        if (held.is(ir, names.items, side)) continue;
                        try JsIr.pushOperand(arena, &stack, side);
                    }
                    continue;
                }
            },
            .assign_stmt, .assign => {
                const target: Index = @fromBackingInt(@intCast(d.lhs));
                if (ir.tag(target) == .member) {
                    const obj: Index = @fromBackingInt(@intCast(ir.data(target).lhs));
                    if (held.is(ir, names.items, obj)) return false;
                }
            },
            else => {},
        }
        try pushChildren(arena, ir, node, &stack);
    }
    return true;
}

const CasedCase = enum { property, alias_of_alias, compared_with_alias, handed, not_sole };

/// `const z = x` and a use of it, as `casedOnly` is asked of them.
fn casedCase(gpa: Allocator, case: CasedCase) !bool {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    const x = try b.intern(.local(@fromBackingInt(@intCast(0))));
    const z = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const w = try b.intern(.local(@fromBackingInt(@intCast(2))));
    const k = try b.intern(.local(@fromBackingInt(@intCast(3))));
    const g = try b.intern(.local(@fromBackingInt(@intCast(4))));
    var rest: std.ArrayList(Index) = .empty;
    defer rest.deinit(gpa);
    try rest.append(gpa, try specTestNode(&b, .const_decl, z.int(), (try specTestNode(&b, .ident, x.int(), 0)).int()));
    const value: Index = switch (case) {
        .property, .not_sole => try specTestNode(&b, .member, (try specTestNode(&b, .ident, z.int(), 0)).int(), k.int()),
        .alias_of_alias => blk: {
            try rest.append(gpa, try specTestNode(&b, .const_decl, w.int(), (try specTestNode(&b, .ident, z.int(), 0)).int()));
            break :blk try specTestNode(&b, .ident, w.int(), 0);
        },
        .compared_with_alias => blk: {
            const pair = try b.addRecord(JsIr.Binary{ .left = try specTestNode(&b, .ident, x.int(), 0), .right = try specTestNode(&b, .ident, z.int(), 0) });
            break :blk try specTestNode(&b, .binary, @backingInt(pair), @backingInt(JsIr.BinaryOp.strict_eq));
        },
        .handed => blk: {
            const args = try b.addRange(&.{try specTestNode(&b, .ident, z.int(), 0)});
            break :blk try specTestNode(&b, .call, (try specTestNode(&b, .ident, g.int(), 0)).int(), @backingInt(try b.addRecord(args)));
        },
    };
    try rest.append(gpa, try specTestNode(&b, .return_stmt, value.int(), 0));
    const body = try b.addRange(rest.items);
    const top = try specTestNode(&b, .block_stmt, @backingInt(NameIndex.none), @backingInt(try b.addRecord(body)));
    var ir = try b.toOwned(try b.addRange(&.{}));
    defer ir.deinit(gpa);
    const Stub = struct {
        yes: bool,
        pub fn once(c: @This(), _: NameIndex) Allocator.Error!bool {
            return c.yes;
        }
    };
    return casedOnly(arena_state.allocator(), &ir, top, x, rest.items, Stub{ .yes = case != .not_sole });
}

test "an alias of a fused site's binding is held to the binding's rules" {
    // `backend.md` §9, *Slice 9 across a call*, amended 2026-10-24 (#934).
    try testing.expect(try casedCase(testing.allocator, .property));
    try testing.expect(try casedCase(testing.allocator, .alias_of_alias));
    // `x === z` would be decided `false` of an object literal `P`.
    try testing.expect(!try casedCase(testing.allocator, .compared_with_alias));
    // Handed to a call, the alias could be held before a comparison.
    try testing.expect(!try casedCase(testing.allocator, .handed));
    // An alias declared twice or assigned is not the binding.
    try testing.expect(!try casedCase(testing.allocator, .not_sole));
}

/// Every mention of `x` in `stmts` that a `return` gives whole: its value,
/// or a branch of a conditional that is (`Spec.onlyCased`).
fn returnedWhole(arena: Allocator, ir: *const JsIr, stmts: []const Index, x: NameIndex, out: *std.ArrayList(Index)) Allocator.Error!void {
    var stack: std.ArrayList(Index) = .empty;
    for (stmts) |st| try JsIr.pushOperand(arena, &stack, st);
    while (JsIr.popOperand(&stack)) |node| {
        if (ir.tag(node) == .return_stmt) {
            var v = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(node).lhs)))).unwrap() orelse continue;
            var values: std.ArrayList(Index) = .empty;
            try values.append(arena, v);
            while (values.pop()) |e| {
                v = e;
                switch (ir.tag(v)) {
                    .ident => if (ir.data(v).lhs == x.int()) try out.append(arena, v),
                    .cond => {
                        const c = ir.extraData(@fromBackingInt(@intCast(ir.data(v).rhs)), JsIr.Cond);
                        try values.append(arena, c.consequent);
                        try values.append(arena, c.alternate);
                    },
                    else => {},
                }
            }
        }
        try pushChildren(arena, ir, node, &stack);
    }
}

/// The value object literal `obj` holds at `key`; null when it holds none
/// or a spread may hold it.
fn propertyOf(ir: *const JsIr, obj: Index, key: NameIndex) ?Index {
    const want = ir.name(key);
    var found: ?Index = null;
    for (ir.extraSlice(JsIr.inlineRange(ir.data(obj)), Index)) |prop| {
        switch (ir.tag(prop)) {
            .property => if (ir.name(@fromBackingInt(@intCast(ir.data(prop).lhs))).eql(want)) {
                found = @fromBackingInt(@intCast(ir.data(prop).rhs));
            },
            else => return null,
        }
    }
    return found;
}

/// Whether control cannot run off the end of `stmts`: its last statement
/// jumps — a `return`, a `throw`, a `break` — or is an `if` neither of whose
/// branches may complete, an unlabelled block whose list may not, or a
/// `switch` with a `default`, holding no `break`, none of whose case bodies
/// may complete. A labelled block may be left by its `break` and so may
/// complete. A `break` that leaves the list is the same jump wherever the
/// list is copied.
fn allReturn(ir: *const JsIr, stmts: []const Index, depth: u32) bool {
    if (stmts.len == 0 or depth > 32) return false;
    const last = stmts[stmts.len - 1];
    const d = ir.data(last);
    switch (ir.tag(last)) {
        .return_stmt, .throw_stmt, .break_stmt => return true,
        .if_stmt => {
            const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
            return allReturn(ir, ir.extraSlice(b.thenBody(), Index), depth + 1) and allReturn(ir, ir.extraSlice(b.elseBody(), Index), depth + 1);
        },
        .block_stmt => {
            if (@as(NameIndex, @fromBackingInt(@intCast(d.lhs))) != .none) return false;
            return allReturn(ir, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index), depth + 1);
        },
        .switch_stmt => {
            var default = false;
            for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |case| {
                const cd = ir.data(case);
                if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(cd.lhs))) == .none) default = true;
                const body = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(cd.rhs))), Index);
                if (holdsBreak(ir, body, 0) or !allReturn(ir, body, depth + 1)) return false;
            }
            return default;
        },
        else => return false,
    }
}

/// Whether `stmts` hold a `break`, at any depth: one that may leave the
/// `switch` around them.
fn holdsBreak(ir: *const JsIr, stmts: []const Index, depth: u32) bool {
    if (depth > 32) return true;
    for (stmts) |st| {
        const d = ir.data(st);
        switch (ir.tag(st)) {
            .break_stmt => return true,
            .if_stmt => {
                const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                if (holdsBreak(ir, ir.extraSlice(b.thenBody(), Index), depth + 1) or holdsBreak(ir, ir.extraSlice(b.elseBody(), Index), depth + 1)) return true;
            },
            .block_stmt => if (holdsBreak(ir, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index), depth + 1)) return true,
            .switch_stmt => for (ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index)) |case| {
                if (holdsBreak(ir, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(case).rhs))), Index), depth + 1)) return true;
            },
            else => {},
        }
    }
    return false;
}

/// Whether two nodes are literals `===` decides: `true` or `false`, or
/// null when either is not a literal.
fn literalEq(ir: *const JsIr, a: Index, b: Index) ?bool {
    const ta = ir.tag(a);
    const tb = ir.tag(b);
    const lit = struct {
        fn is(t: Node.Tag) bool {
            return switch (t) {
                .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => true,
                else => false,
            };
        }
    };
    if (!lit.is(ta) or !lit.is(tb)) return null;
    if (ta != tb) return false;
    return switch (ta) {
        .string => std.mem.eql(u8, ir.bytes(a), ir.bytes(b)),
        .number => {
            const x = std.fmt.parseFloat(f64, ir.bytes(a)) catch return null;
            const y = std.fmt.parseFloat(f64, ir.bytes(b)) catch return null;
            return x == y;
        },
        else => true,
    };
}

/// The answer a test is known to give: a boolean literal, `!` of one, or
/// `===`/`!==` of two literals.
fn decidedTest(ir: *const JsIr, node: Index) ?bool {
    const d = ir.data(node);
    switch (ir.tag(node)) {
        .true_lit => return true,
        .false_lit => return false,
        .unary => {
            if (@as(JsIr.UnaryOp, @fromBackingInt(@intCast(d.rhs))) != .not) return null;
            return !(decidedTest(ir, @fromBackingInt(@intCast(d.lhs))) orelse return null);
        },
        .binary => {
            const op: JsIr.BinaryOp = @fromBackingInt(@intCast(d.rhs));
            const b = ir.extraData(@fromBackingInt(@intCast(d.lhs)), JsIr.Binary);
            return switch (op) {
                .strict_eq => literalEq(ir, b.left, b.right),
                .strict_ne => !(literalEq(ir, b.left, b.right) orelse return null),
                else => null,
            };
        },
        else => return null,
    }
}

/// The parts of `const x = (s, …, v)` (or a `let`) whose `s` are stores of a
/// record written in place (`JsIr.Node.Tag.sequence`), or null.
fn storesBound(ir: *const JsIr, stmt: Index) ?[]const u32 {
    switch (ir.tag(stmt)) {
        .const_decl, .let_decl => {},
        else => return null,
    }
    const v = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(stmt).rhs)))).unwrap() orelse return null;
    if (ir.tag(v) != .sequence) return null;
    const parts = ir.extraSlice(JsIr.inlineRange(ir.data(v)), u32);
    for (parts[0 .. parts.len - 1]) |e| if (ir.tag(@fromBackingInt(@intCast(e))) != .assign) return null;
    return parts;
}

/// A name, a literal, or a member chain on a name: reading it does
/// nothing, so a decided comparison may drop it.
fn pureRead(ir: *const JsIr, node: Index) bool {
    return switch (ir.tag(node)) {
        .ident, .field_name, .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => true,
        .member => memberBase(ir, node) != null,
        else => false,
    };
}

/// A literal that is not an object: `===` with an object is false.
fn primitiveLit(ir: *const JsIr, node: Index) bool {
    return switch (ir.tag(node)) {
        .number, .string, .true_lit, .false_lit, .null_lit, .undefined_lit => true,
        else => false,
    };
}

/// A `switch` on a literal whose case tests are literals (`backend.md` §9,
/// *Slice 9 across a call*): the body of the case it takes — the first
/// whose test `===` the literal, else the `default` — when that body holds
/// no `break` and cannot run off its end into the next case. Evaluating a
/// literal does nothing, so nothing else of the `switch` runs.
fn chosenCase(ir: *const JsIr, stmt: Index) ?Spec.Decided {
    const disc: Index = @fromBackingInt(@intCast(ir.data(stmt).lhs));
    const cases = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(ir.data(stmt).rhs))), Index);
    var chosen: ?Index = null;
    for (cases) |case| {
        const t = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(case).lhs)))).unwrap() orelse continue;
        if (literalEq(ir, disc, t) orelse return null) {
            chosen = case;
            break;
        }
    }
    if (chosen == null) for (cases) |case| {
        if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(case).lhs))) == .none) chosen = case;
    };
    const case = chosen orelse return null;
    const body = ir.subRange(@fromBackingInt(@intCast(ir.data(case).rhs)));
    const items = ir.extraSlice(body, Index);
    if (holdsBreak(ir, items, 0) or !allReturn(ir, items, 0)) return null;
    return .{ .arm = body };
}

/// Whether `stmts` hold an unlabelled `break` that is not inside a `switch`
/// of their own: one that leaves the statements for whatever encloses them.
fn leavingBreak(ir: *const JsIr, stmts: []const Index, depth: u32) bool {
    if (depth > 32) return true;
    for (stmts) |st| {
        const d = ir.data(st);
        switch (ir.tag(st)) {
            .break_stmt => if (@as(NameIndex, @fromBackingInt(@intCast(d.lhs))) == .none) return true,
            .if_stmt => {
                const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                if (leavingBreak(ir, ir.extraSlice(b.thenBody(), Index), depth + 1) or leavingBreak(ir, ir.extraSlice(b.elseBody(), Index), depth + 1)) return true;
            },
            .block_stmt => if (leavingBreak(ir, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index), depth + 1)) return true,
            // A `switch` of their own is what its unlabelled breaks leave.
            else => {},
        }
    }
    return false;
}

/// Whether arrow `value` of `ir` makes a fresh object each time it is
/// called, whose property `want` is made with it (`Spec.freshHeld`): no
/// parameter; a body of `const`s of object and array literals of atoms and
/// then `return` of an object literal; that literal's value at `want` an
/// object or array literal, or one of those `const`s. So two reads of the
/// property of one result give one object, never `NaN`.
fn makesFreshAt(ir: *const JsIr, value: Index, want: JsIr.Name) bool {
    if (ir.tag(value) != .arrow or ir.data(value).rhs != Node.arrow_plain) return false;
    const f = ir.extraData(@fromBackingInt(@intCast(ir.data(value).lhs)), JsIr.Func);
    if (ir.extraSlice(f.params(), NameIndex).len != 0) return false;
    const body = ir.extraSlice(f.body(), Index);
    if (body.len == 0) return false;
    for (body[0 .. body.len - 1]) |st| {
        if (ir.tag(st) != .const_decl) return false;
        const made = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(st).rhs)))).unwrap() orelse return false;
        if ((ir.tag(made) != .object and ir.tag(made) != .array) or !inertOf(ir, made, false)) return false;
    }
    const last = body[body.len - 1];
    if (ir.tag(last) != .return_stmt) return false;
    const obj = (@as(Node.OptionalIndex, @fromBackingInt(@intCast(ir.data(last).lhs)))).unwrap() orelse return false;
    if (ir.tag(obj) != .object) return false;
    var v: ?Index = null;
    for (ir.extraSlice(JsIr.inlineRange(ir.data(obj)), Index)) |prop| {
        if (ir.tag(prop) != .property) return false;
        if (ir.name(@fromBackingInt(@intCast(ir.data(prop).lhs))).eql(want)) v = @fromBackingInt(@intCast(ir.data(prop).rhs));
    }
    const at = v orelse return false;
    return switch (ir.tag(at)) {
        .object, .array => true,
        .ident => for (body[0 .. body.len - 1]) |st| {
            if (ir.data(st).lhs == ir.data(at).lhs) break true;
        } else false,
        else => false,
    };
}

const FreshCase = enum { array, number, param, const_array, const_call, missing };

/// `() => ({ k: [] })` and the variations `makesFreshAt` refuses.
fn freshCase(gpa: Allocator, case: FreshCase) !bool {
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    const k = try b.intern(.local(@fromBackingInt(@intCast(0))));
    const j = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const n = try b.intern(.local(@fromBackingInt(@intCast(2))));
    const p = try b.intern(.local(@fromBackingInt(@intCast(3))));
    const g = try b.intern(.local(@fromBackingInt(@intCast(4))));
    const empty = try b.addRange(&.{});
    var stmts: std.ArrayList(Index) = .empty;
    defer stmts.deinit(gpa);
    const held: Index = switch (case) {
        .number => blk: {
            const text = try b.addString("0");
            break :blk try specTestNode(&b, .number, text[0], text[1]);
        },
        .const_array, .const_call => blk: {
            const init = if (case == .const_array)
                try specTestNode(&b, .array, @backingInt(empty.start), @backingInt(empty.end))
            else
                try specTestNode(&b, .call, (try specTestNode(&b, .ident, g.int(), 0)).int(), @backingInt(try b.addRecord(empty)));
            try stmts.append(gpa, try specTestNode(&b, .const_decl, n.int(), init.int()));
            break :blk try specTestNode(&b, .ident, n.int(), 0);
        },
        else => try specTestNode(&b, .array, @backingInt(empty.start), @backingInt(empty.end)),
    };
    const prop = try specTestNode(&b, .property, (if (case == .missing) j else k).int(), held.int());
    const props = try b.addRange(&.{prop});
    const obj = try specTestNode(&b, .object, @backingInt(props.start), @backingInt(props.end));
    try stmts.append(gpa, try specTestNode(&b, .return_stmt, obj.int(), 0));
    const params = try b.addNames(if (case == .param) &.{p} else &.{});
    const body = try b.addRange(stmts.items);
    const func = try b.addRecord(JsIr.Func{ .params_start = params.start, .params_end = params.end, .body_start = body.start, .body_end = body.end });
    const arrow = try specTestNode(&b, .arrow, @backingInt(func), Node.arrow_plain);
    var ir = try b.toOwned(try b.addRange(&.{}));
    defer ir.deinit(gpa);
    return makesFreshAt(&ir, arrow, ir.name(k));
}

fn specTestNode(b: *JsIr.Builder, tag: Node.Tag, lhs: u32, rhs: u32) !Index {
    return b.addNode(.{ .tag = tag, .pos = Node.no_pos, .data = .{ .lhs = lhs, .rhs = rhs } });
}

test "a call's object is fresh, with its own value at a key, only for a function of literals" {
    // `backend.md` §9, *Slice 9 across a call*, amended 2026-10-24 (#934):
    // `x === c.k` is decided across the call only when each read of `c.k`
    // gives one object, made with `c`.
    try testing.expect(try freshCase(testing.allocator, .array));
    try testing.expect(try freshCase(testing.allocator, .const_array));
    // A number may be `NaN`, which is not `===` itself.
    try testing.expect(!try freshCase(testing.allocator, .number));
    // A parameter could hand the object something it holds.
    try testing.expect(!try freshCase(testing.allocator, .param));
    // A value a call made may be anything, shared with anyone.
    try testing.expect(!try freshCase(testing.allocator, .const_call));
    // No value at the key: the read is `undefined`, not an object.
    try testing.expect(!try freshCase(testing.allocator, .missing));
}

test "a fused site's binding may be read whole only as what a return gives" {
    // `return x === y ? b : x` gives `x` whole in its alternate; `return
    // g(x)` hands it to a call, which could keep it before a comparison.
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    const x = try b.intern(.local(@fromBackingInt(@intCast(0))));
    const y = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const bn = try b.intern(.local(@fromBackingInt(@intCast(2))));
    const g = try b.intern(.local(@fromBackingInt(@intCast(3))));
    const tested = try specTestNode(&b, .ident, x.int(), 0);
    const pair = try b.addRecord(JsIr.Binary{ .left = tested, .right = try specTestNode(&b, .ident, y.int(), 0) });
    const test_node = try specTestNode(&b, .binary, @backingInt(pair), @backingInt(JsIr.BinaryOp.strict_eq));
    const alternate = try specTestNode(&b, .ident, x.int(), 0);
    const branches = try b.addRecord(JsIr.Cond{ .consequent = try specTestNode(&b, .ident, bn.int(), 0), .alternate = alternate });
    const cond = try specTestNode(&b, .cond, test_node.int(), @backingInt(branches));
    const ret_cond = try specTestNode(&b, .return_stmt, cond.int(), 0);
    const handed = try specTestNode(&b, .ident, x.int(), 0);
    const args = try b.addRange(&.{handed});
    const call = try specTestNode(&b, .call, (try specTestNode(&b, .ident, g.int(), 0)).int(), @backingInt(try b.addRecord(args)));
    const ret_call = try specTestNode(&b, .return_stmt, call.int(), 0);
    var ir = try b.toOwned(try b.addRange(&.{}));
    defer ir.deinit(gpa);
    var whole: std.ArrayList(Index) = .empty;
    try returnedWhole(arena, &ir, &.{ret_cond}, x, &whole);
    try testing.expectEqualSlices(Index, &.{alternate}, whole.items);
    whole.clearRetainingCapacity();
    try returnedWhole(arena, &ir, &.{ret_call}, x, &whole);
    try testing.expectEqual(@as(usize, 0), whole.items.len);
}

test "an unlabelled break that leaves a fused rest refuses the fusion" {
    const gpa = testing.allocator;
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    const label = try b.intern(.local(@fromBackingInt(@intCast(0))));
    const leaving = try b.addNode(.{ .tag = .break_stmt, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(NameIndex.none), .rhs = 0 } });
    const labelled = try b.addNode(.{ .tag = .break_stmt, .pos = Node.no_pos, .data = .{ .lhs = label.int(), .rhs = 0 } });
    const inner = try b.addRange(&.{leaving});
    const block = try b.addNode(.{ .tag = .block_stmt, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(NameIndex.none), .rhs = @backingInt(try b.addRecord(inner)) } });
    const case_body = try b.addRange(&.{leaving});
    const case = try b.addNode(.{ .tag = .switch_case, .pos = Node.no_pos, .data = .{ .lhs = @backingInt(Node.OptionalIndex.none), .rhs = @backingInt(try b.addRecord(case_body)) } });
    const cases = try b.addRange(&.{case});
    const disc = try b.addNode(.{ .tag = .true_lit, .pos = Node.no_pos, .data = .{ .lhs = 0, .rhs = 0 } });
    const own_switch = try b.addNode(.{ .tag = .switch_stmt, .pos = Node.no_pos, .data = .{ .lhs = disc.int(), .rhs = @backingInt(try b.addRecord(cases)) } });
    var ir = try b.toOwned(try b.addRange(&.{}));
    defer ir.deinit(gpa);
    // In a block of the rest: it leaves the rest.
    try testing.expect(leavingBreak(&ir, &.{block}, 0));
    // A labelled one names its target, which copying does not move.
    try testing.expect(!leavingBreak(&ir, &.{labelled}, 0));
    // Inside a `switch` of the rest: it leaves that `switch` only.
    try testing.expect(!leavingBreak(&ir, &.{own_switch}, 0));
}

/// Whether `range`'s own statements declare no name: they may stand in the
/// list around them, scoping nothing differently.
fn declaresNothing(ir: *const JsIr, range: JsIr.SubRange) bool {
    for (ir.extraSlice(range, Index)) |stmt| switch (ir.tag(stmt)) {
        .const_decl, .let_decl, .func_decl, .gen_decl => return false,
        .while_true, .block_stmt => if (@as(NameIndex, @fromBackingInt(@intCast(ir.data(stmt).lhs))) != .none) return false,
        else => {},
    };
    return true;
}

/// A case body that is one unlabelled block, as the block's statements.
fn unblocked(ir: *const JsIr, body: JsIr.SubRange) JsIr.SubRange {
    var range = body;
    var depth: u32 = 0;
    while (depth < 32) : (depth += 1) {
        const items = ir.extraSlice(range, Index);
        if (items.len != 1 or ir.tag(items[0]) != .block_stmt) return range;
        if (@as(NameIndex, @fromBackingInt(@intCast(ir.data(items[0]).lhs))) != .none) return range;
        range = ir.subRange(@fromBackingInt(@intCast(ir.data(items[0]).rhs)));
    }
    return range;
}
/// Whether `stmts`' only `return`s end the list: the last statement, or the
/// last of each branch of an `if` or of an unlabelled block that is the
/// last — no early `return` an inlined copy would have to keep.
/// A branch with no `return` at all is accepted: control falls off its end,
/// as it falls out of the call, to the statement after it. A function that
/// may suspend never meets this: its call is never a statement of the
/// suspendable form, which hands the call's value on to `Task$andThen`
/// (`emit/release/SuspendTailStatement`).
fn tailReturnsOnly(ir: *const JsIr, stmts: []const Index, depth: u32) bool {
    if (depth > 32) return false;
    for (stmts, 0..) |st, i| {
        const last = i + 1 == stmts.len;
        const d = ir.data(st);
        switch (ir.tag(st)) {
            .return_stmt => if (!last) return false,
            .if_stmt => {
                const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                const t = ir.extraSlice(b.thenBody(), Index);
                const e = ir.extraSlice(b.elseBody(), Index);
                if (last) {
                    if (!tailReturnsOnly(ir, t, depth + 1) or !tailReturnsOnly(ir, e, depth + 1)) return false;
                } else if (holdsReturn(ir, t, depth + 1) or holdsReturn(ir, e, depth + 1)) return false;
            },
            .block_stmt => {
                const inner = ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index);
                const labelled = @as(NameIndex, @fromBackingInt(@intCast(d.lhs))) != .none;
                if (last and !labelled) {
                    if (!tailReturnsOnly(ir, inner, depth + 1)) return false;
                } else if (holdsReturn(ir, inner, depth + 1)) return false;
            },
            else => if (holdsReturn(ir, &.{st}, depth + 1)) return false,
        }
    }
    return true;
}

/// Whether a `return` of the function is among `stmts`, a nested
/// function's aside.
fn holdsReturn(ir: *const JsIr, stmts: []const Index, depth: u32) bool {
    if (depth > 32) return true;
    for (stmts) |st| {
        const d = ir.data(st);
        switch (ir.tag(st)) {
            .return_stmt => return true,
            .if_stmt => {
                const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                if (holdsReturn(ir, ir.extraSlice(b.thenBody(), Index), depth + 1) or holdsReturn(ir, ir.extraSlice(b.elseBody(), Index), depth + 1)) return true;
            },
            .block_stmt => if (holdsReturn(ir, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index), depth + 1)) return true,
            .expr_stmt, .const_decl, .let_decl, .assign_stmt, .throw_stmt => {},
            // A loop, a `switch`, a `try`: not looked into.
            else => return true,
        }
    }
    return false;
}

/// `stmts` copied by `c` into `m` as a call statement that ends its
/// function: each `return v` at the list's end is `v` as a statement, or
/// nothing when `v` is inert (`tailReturnsOnly` holds of `stmts`). The
/// value was never read, and the function ends there either way.
fn copyTail(c: anytype, m: *Mod, stmts: []const Index, depth: u32) Allocator.Error![]const u32 {
    const s = c.s;
    const ir = c.src.ir;
    var out: std.ArrayList(u32) = .empty;
    for (stmts, 0..) |st, i| {
        const d = ir.data(st);
        if (i + 1 != stmts.len) {
            try out.append(s.arena, (try c.stmt(st, depth)).int());
            continue;
        }
        switch (ir.tag(st)) {
            .return_stmt => if (@as(Node.OptionalIndex, @fromBackingInt(@intCast(d.lhs))).unwrap()) |v| if (!inert(ir, v)) {
                const e = try c.expr(v, depth);
                try out.append(s.arena, (try m.addNode(s.gpa, .expr_stmt, Node.no_pos, e.int(), 0)).int());
            },
            .if_stmt => {
                const b = ir.extraData(@fromBackingInt(@intCast(d.rhs)), JsIr.If);
                const cond = try c.expr(@fromBackingInt(@intCast(d.lhs)), depth);
                const t = try copyTail(c, m, ir.extraSlice(b.thenBody(), Index), depth + 1);
                const e = try copyTail(c, m, ir.extraSlice(b.elseBody(), Index), depth + 1);
                if (t.len == 0 and e.len == 0) {
                    if (!inert(m.ir, cond)) try out.append(s.arena, (try m.addNode(s.gpa, .expr_stmt, Node.no_pos, cond.int(), 0)).int());
                    continue;
                }
                const ts = try m.append(s.gpa, t);
                const te = ts + @as(u32, @intCast(t.len));
                const es = try m.append(s.gpa, e);
                const ee = es + @as(u32, @intCast(e.len));
                const branches = try m.append(s.gpa, &.{ ts, te, es, ee });
                try out.append(s.arena, (try m.addNode(s.gpa, .if_stmt, ir.pos(st), cond.int(), branches)).int());
            },
            .block_stmt => if (@as(NameIndex, @fromBackingInt(@intCast(d.lhs))) == .none) {
                const inner = try copyTail(c, m, ir.extraSlice(ir.subRange(@fromBackingInt(@intCast(d.rhs))), Index), depth + 1);
                const at = try m.append(s.gpa, inner);
                try out.append(s.arena, (try m.addNode(s.gpa, .block_stmt, ir.pos(st), @backingInt(NameIndex.none), try m.append(s.gpa, &.{ at, at + @as(u32, @intCast(inner.len)) }))).int());
            } else try out.append(s.arena, (try c.stmt(st, depth)).int()),
            else => try out.append(s.arena, (try c.stmt(st, depth)).int()),
        }
    }
    return out.items;
}

// Record copies keep joining independently stored snapshots after their
// destination has settled. Rechecking every site by binary search made
// this repeated source-to-field propagation cost most of the analysis.
test "settled points-to joins have bounded work" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const v = try p.newVar();
    var held: [64]u32 = undefined;
    for (&held, 0..) |*site, i| site.* = @intCast(i);
    var incoming: [64]u32 = undefined;
    @memcpy(&incoming, &held);
    try holdSites(p, v, &held);
    for (0..131072) |_| try p.join(v, .{ .sites = &incoming });
    try p.drain();
    try testing.expectEqualSlices(u32, &held, (try p.view(v)).sites);
}

// Different snapshots may already be contained, or add interleaved sites.
// Primitive/null/undefined facts must still wake readers before returning.
test "points-to joins preserve flags and finite snapshot growth" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const v = try p.newVar();
    const held = [_]u32{ 0, 2, 4, 6 };
    const equal = [_]u32{ 0, 2, 4, 6 };
    try holdSites(p, v, &held);
    p.waiting = try arena_state.allocator().alloc(u64, 1);
    p.waiting[0] = 0;
    p.walk = 1;
    p.cur = 7;
    _ = try p.view(v);
    try p.join(v, .{ .sites = &equal });
    try p.drain();
    try p.join(v, .{ .sites = &.{ 2, 6 } });
    try p.drain();
    try testing.expectEqual(@as(u32, 0), p.waiting_count);
    try p.join(v, .{ .sites = &.{ 2, 6 }, .prim = true, .nul = true, .undef = true });
    try p.drain();
    try testing.expectEqual(@as(u64, 1) << 7, p.waiting[0]);
    try testing.expectEqual(@as(u32, 1), p.waiting_count);
    try p.join(v, .{ .sites = &.{ 1, 3, 5 } });
    try p.drain();
    const result = try p.view(v);
    try testing.expect(result.prim and result.nul and result.undef and !result.top);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6 }, result.sites);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 4, 6 }, &held);
}

// Crossing the existing limit must escape every old and subsequent site;
// top inputs must also escape sites, even when the destination is top.
test "points-to joins preserve top escape and threshold wake order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = try emptySpec(testing.allocator, arena);
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const v = try p.newVar();
    for (0..Pts.max_sites + 3) |_| {
        const any = try p.newVar();
        try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(0), .any = any });
    }
    const held = try arena.alloc(u32, Pts.max_sites - 1);
    for (held, 0..) |*site, i| site.* = @intCast(i);
    try holdSites(p, v, held);
    p.waiting = try arena.alloc(u64, 1);
    p.waiting[0] = 0;
    p.walk = 1;
    p.cur = 1;
    _ = try p.view(v);
    for ([_]u32{ 0, Pts.max_sites, Pts.max_sites + 1, Pts.max_sites + 2 }, 2..) |site, reader| {
        p.cur = @intCast(reader);
        try p.seeSite(site);
    }
    try p.join(v, .{ .sites = &.{ 0, Pts.max_sites - 1, Pts.max_sites, Pts.max_sites + 1 } });
    try p.drain();
    const result = try p.view(v);
    try testing.expect(result.top and result.prim and result.nul and result.undef);
    try testing.expectEqual(@as(usize, 0), result.sites.len);
    try testing.expectEqual(@as(u64, 0b11110), p.waiting[0]);
    try testing.expectEqual(@as(u32, 4), p.waiting_count);
    for (0..Pts.max_sites + 2) |site| try testing.expect(p.sites.items[site].escaped);
    try testing.expect(!p.sites.items[Pts.max_sites + 2].escaped);
    for (held, 0..) |site, i| try testing.expectEqual(@as(u32, @intCast(i)), site);
    // An already-top destination still has to escape incoming sites.
    try p.join(v, .{ .sites = &.{Pts.max_sites + 2} });
    try p.drain();
    try testing.expect(p.sites.items[Pts.max_sites + 2].escaped);
    try testing.expectEqual(@as(u32, 5), p.waiting_count);
    // Incoming top escapes a finite destination's borrowed snapshot.
    const other = try p.newVar();
    const fresh: u32 = @intCast(p.sites.items.len);
    const any = try p.newVar();
    try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(0), .any = any });
    const snapshot = [_]u32{fresh};
    try holdSites(p, other, &snapshot);
    try p.join(other, .{ .top = true, .sites = &snapshot });
    try p.drain();
    try testing.expect((try p.view(other)).top);
    try testing.expect(p.sites.items[fresh].escaped);
    try testing.expectEqualSlices(u32, &.{fresh}, &snapshot);
}

// A local bound to a member read is uncapped and limited. The read's
// value is `top` beside its objects. Past `max_sites` that local's
// sites escape. The same joins without `limited` keep every site.
test "a limited member binding escapes its sites past the cap" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = try emptySpec(testing.allocator, arena);
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const count = Pts.max_sites + 1;
    const ids = try arena.alloc(u32, count);
    for (ids, 0..) |*id, i| {
        id.* = @intCast(i);
        const any = try p.newVar();
        try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(id.*), .any = any });
    }
    const open = try p.newVar();
    p.vars.items[open].uncapped = true;
    try p.join(open, .{ .top = true, .sites = ids });
    try p.drain();
    const kept = try p.view(open);
    try testing.expect(kept.top);
    try testing.expectEqualSlices(u32, ids, kept.sites);
    for (ids) |site| try testing.expect(!p.sites.items[site].escaped);

    const under = try p.newVar();
    p.vars.items[under].uncapped = true;
    p.vars.items[under].limited = true;
    try p.join(under, .{ .top = true, .sites = ids[0..1] });
    try p.drain();
    const few = try p.view(under);
    try testing.expect(few.top);
    try testing.expectEqualSlices(u32, ids[0..1], few.sites);
    try testing.expect(!p.sites.items[0].escaped);

    const capped = try p.newVar();
    p.vars.items[capped].uncapped = true;
    p.vars.items[capped].limited = true;
    const through = try p.newVar();
    try p.copy(capped, through);
    const li = try p.newLoad();
    try p.sites.items[0].loads.append(arena, li);
    try p.join(capped, .{ .top = true, .sites = ids });
    try p.drain();
    const result = try p.view(capped);
    try testing.expect(result.top and result.prim and result.nul and result.undef);
    try testing.expectEqual(@as(usize, 0), result.sites.len);
    for (ids) |site| try testing.expect(p.sites.items[site].escaped);
    const reader = try p.view(p.loads.items[li].out);
    try testing.expect(reader.top);
    const copied = try p.view(through);
    try testing.expect(copied.top and copied.prim and copied.nul and copied.undef);
    try testing.expectEqual(@as(usize, 0), copied.sites.len);
}

// #464: a copy edge carries what joins its source to its target as it
// arrives — the difference, in one batch — and a value read before the join
// keeps the set it was read as (`VSet`). Flags and `top` follow the edge too,
// and an edge is made once.
test "a copy edge carries the difference, and a value read before keeps its sites" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    // Ten sites, so that `makeTop` has sites to escape.
    var i: u32 = 0;
    while (i < 10) : (i += 1) try p.sites.append(arena_state.allocator(), .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
    const a = try p.newVar();
    const b = try p.newVar();
    const c = try p.newVar();
    try p.addSite(a, 5);
    try p.drain();
    try p.copy(a, b);
    try p.copy(b, c);
    try p.copy(a, b);
    try testing.expectEqual(@as(usize, 2), p.edges.items.len);
    try testing.expectEqualSlices(u32, &.{5}, (try p.view(c)).sites);
    const before = try p.view(c);
    try p.join(a, .{ .prim = true, .sites = &.{ 2, 9 } });
    try p.drain();
    try testing.expectEqualSlices(u32, &.{5}, before.sites);
    try testing.expectEqualSlices(u32, &.{ 2, 5, 9 }, (try p.view(b)).sites);
    try testing.expectEqualSlices(u32, &.{ 2, 5, 9 }, (try p.view(c)).sites);
    try testing.expect((try p.view(c)).prim and !(try p.view(c)).nul);
    // A site already there costs no new set.
    const settled = (try p.view(c)).sites;
    try p.addSite(a, 9);
    try p.drain();
    try testing.expectEqual(settled.ptr, (try p.view(c)).sites.ptr);
    try p.makeTop(a);
    try testing.expect((try p.view(c)).top);
    try testing.expect(p.sites.items[5].escaped and !p.sites.items[0].escaped);
}

// #496: vars that hold the same sites hold one copy (`Pts.Sets`). Two vars
// a source copies into grow by the same batches and take each grown set
// the source took, a value read before a growth keeps the set it was read
// as, and a var given the same sites another way holds the same entry.
test "points-to vars grown by the same batches share their sets" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const src = try p.newVar();
    const a = try p.newVar();
    const b = try p.newVar();
    try p.copy(src, a);
    try p.copy(src, b);
    var before: Pts.Val = .{};
    var site: u32 = 0;
    while (site < 64) : (site += 1) {
        if (site == 32) before = try p.view(a);
        try p.addSite(src, site);
        try p.drain();
        const held = (try p.view(src)).sites;
        try testing.expectEqual(@as(usize, site + 1), held.len);
        try testing.expectEqual(held.ptr, (try p.view(a)).sites.ptr);
        try testing.expectEqual(held.ptr, (try p.view(b)).sites.ptr);
    }
    try testing.expectEqual(@as(usize, 32), before.sites.len);
    for (before.sites, 0..) |x, i| try testing.expectEqual(@as(u32, @intCast(i)), x);
    // Each of the 64 sets is stored once, not once per var, and so is
    // each batch of one site but the first, which is the first set.
    const words: u64 = 64 * 65 / 2 + 63;
    try testing.expectEqual(words, s.stats.pts_set_words);
    var all: [64]u32 = undefined;
    for (&all, 0..) |*x, i| x.* = @intCast(i);
    const c = try p.newVar();
    try p.join(c, .{ .sites = &all });
    try p.drain();
    try testing.expectEqual((try p.view(a)).sites.ptr, (try p.view(c)).sites.ptr);
    try testing.expectEqual(words, s.stats.pts_set_words);
}

// #464: a spread of a var copies through its field summary, and a var that
// is a copy of another shares the other's summary through one edge per
// property, not one per site and property. A site joining the source later,
// and a property a site gains later, reach the copy's summary through the
// edges.
test "a field summary composes along a copy edge" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const arena = arena_state.allocator();
    // Three object sites with properties 1 and 2, holding sites 100 + i.
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
        try p.addSite(try fieldVar(p, i, 1), 100 + i);
        try settle(p);
        try p.addSite(try fieldVar(p, i, 2), 200 + i);
        try settle(p);
    }
    const u = try p.newVar();
    const v = try p.newVar();
    try p.join(u, .{ .sites = &.{ 0, 1 } });
    try settle(p);
    try p.copy(u, v);
    // A second source, empty, so that `v` has a summary of its own: a var
    // that copies one var alone shares its summary (#568).
    const w = try p.newVar();
    try p.copy(w, v);
    const sum_v = try p.summaryOf(v);
    // Read whole, as a spread reads it.
    try p.markWhole(sum_v);
    try settle(p);
    const sum_u = p.vars.items[u].summary;
    try testing.expect(sum_u != none and sum_u != sum_v);
    // `u`'s summary folds two sites of two properties (plus `any`), each
    // once; `v`'s takes `u`'s through one edge per property (plus `any`),
    // and `w`'s, which holds nothing, through its `any`.
    try testing.expectEqual(@as(usize, 2 + 2 * 3 + 3 + 1), p.edges.items.len);
    const prop1 = p.summaries.items[sum_v].props.items[0];
    try testing.expectEqual(@as(u32, 1), prop1.id);
    try testing.expectEqualSlices(u32, &.{ 100, 101 }, (try p.view(prop1.vals)).sites);
    // A site joining `u` later reaches `v`'s summary; so does a property a
    // held site gains later.
    try p.addSite(u, 2);
    try settle(p);
    try testing.expectEqualSlices(u32, &.{ 100, 101, 102 }, (try p.view(prop1.vals)).sites);
    try p.addSite(try fieldVar(p, 1, 3), 300);
    try settle(p);
    const prop3 = p.summaries.items[sum_v].props.items[2];
    try testing.expectEqual(@as(u32, 3), prop3.id);
    try testing.expectEqualSlices(u32, &.{300}, (try p.view(prop3.vals)).sites);
    // A var that goes `top` has a dead summary: nothing more is folded.
    try p.makeTop(v);
    try testing.expect(p.summaries.items[sum_v].dead);
}

// #562: a binding to a member read is a copy of the read's load cell. The
// cell is `uncapped`, `top` a flag beside its sites, and so is the binding
// (`limited`): when the cell turns `top`, the binding holds the read's
// objects beside `top` and escapes none of them, as the join of the read's
// value it replaces did.
test "a binding copied from a load cell holds the read's objects beside top" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    var i: u32 = 0;
    while (i < 3) : (i += 1) try p.sites.append(arena_state.allocator(), .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
    const cell = p.loads.items[try p.newLoad()].out;
    try p.join(cell, .{ .sites = &.{ 0, 1 } });
    try p.drain();
    const binding = try p.newVar();
    p.vars.items[binding].uncapped = true;
    p.vars.items[binding].limited = true;
    try p.copy(cell, binding);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try p.view(binding)).sites);
    try testing.expect(!(try p.view(binding)).top);
    try p.join(cell, Pts.Val.top_val);
    try p.drain();
    try p.addSite(cell, 2);
    try p.drain();
    const held = try p.view(binding);
    try testing.expect(held.top);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, held.sites);
    i = 0;
    while (i < 3) : (i += 1) try testing.expect(!p.sites.items[i].escaped);
}

// #562: an argument (or a `return`) that is a member read is a copy of the
// read's load cell into a capped var. The cell's `top` reaches the var
// along the edge and makes it `top` (`makeTop`), escaping every site it
// held and every site that joins the cell later — whether the edge was made
// before the cell turned `top` or after.
test "a parameter copied from a load cell is made top as the cell is" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    var i: u32 = 0;
    while (i < 4) : (i += 1) try p.sites.append(arena_state.allocator(), .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
    const cell = p.loads.items[try p.newLoad()].out;
    try p.join(cell, .{ .sites = &.{0} });
    try p.drain();
    const before = try p.newVar();
    try p.copy(cell, before);
    try testing.expectEqualSlices(u32, &.{0}, (try p.view(before)).sites);
    try testing.expect(!p.sites.items[0].escaped);
    try p.join(cell, .{ .top = true, .sites = &.{1} });
    try p.drain();
    const after = try p.newVar();
    try p.copy(cell, after);
    try p.addSite(cell, 2);
    try p.drain();
    for ([_]Pts.VarId{ before, after }) |v| {
        const got = try p.view(v);
        try testing.expect(got.top and got.prim and got.nul and got.undef);
        try testing.expectEqual(@as(usize, 0), got.sites.len);
    }
    // The cell keeps its sites; each of them escaped through the copies.
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, (try p.view(cell)).sites);
    for ([_]u32{ 0, 1, 2 }) |site| try testing.expect(p.sites.items[site].escaped);
    try testing.expect(!p.sites.items[3].escaped);
}

// #562: names that copy one load cell share a field summary, made once. A
// cell of a field read copies the field's var in a summary, which its
// summary links in turn; that var is fed by the field's var of each site
// the summary folded, a site's own var (`VLink.site_var`), and no summary
// is made of one of those (`linksAcross`): the summary at the field's var
// folds the sites they hold. The cell and every name copy it alone, so
// theirs is that summary (#568), and nothing else is made. A read through a name's summary marks and reads the sites the
// field holds, and a site that joins the field later reaches it.
test "names that copy a load cell share one summary, which folds the field's sites" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const arena = arena_state.allocator();
    // Four object sites, each with property 1 (holding site 100 + i).
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
        (try p.prop(i, 1)).init = true;
        try p.addSite(try fieldVar(p, i, 1), 100 + i);
        try settle(p);
    }
    // `site_field` is a record's field, holding sites 0 to 2, and `field`
    // the summary's var of it; the cell copies `field`.
    const site_field = try p.newVar();
    p.links_of.items[site_field].site_var = true;
    try p.join(site_field, .{ .sites = &.{ 0, 1, 2 } });
    try settle(p);
    const field = try p.newVar();
    try p.copy(site_field, field);
    const cell = p.loads.items[try p.newLoad()].out;
    try p.copy(field, cell);
    const a = try p.newVar();
    const b = try p.newVar();
    try p.copy(cell, a);
    try p.copy(cell, b);
    const sum_a = try p.summaryOf(a);
    const sum_b = try p.summaryOf(b);
    const sum_field = p.vars.items[field].summary;
    try testing.expect(sum_field != none and sum_a == sum_field and sum_b == sum_field);
    try testing.expectEqual(sum_field, try p.summaryOf(cell));
    try testing.expect(p.vars.items[cell].summary == none and p.vars.items[cell].alias != none);
    try testing.expectEqual(none, p.vars.items[site_field].summary);
    try testing.expectEqual(@as(usize, 1), p.summaries.items.len);
    try testing.expectEqual(@as(usize, 3), p.summaries.items[sum_field].sites.items.len);
    const li = try p.newLoad();
    try p.summaryLoad(sum_a, 1, li);
    try settle(p);
    const out = p.loads.items[li].out;
    try testing.expectEqualSlices(u32, &.{ 100, 101, 102 }, (try p.view(out)).sites);
    for ([_]u32{ 0, 1, 2 }) |site| try testing.expect(p.findProp(site, 1).?.read);
    try testing.expect(!p.findProp(3, 1).?.read);
    try p.addSite(site_field, 3);
    try settle(p);
    try testing.expectEqualSlices(u32, &.{ 100, 101, 102, 103 }, (try p.view(out)).sites);
    try testing.expect(p.findProp(3, 1).?.read);
    try testing.expectEqual(@as(usize, 4), p.summaries.items[sum_field].sites.items.len);
    try testing.expectEqual(@as(usize, 1), p.summaries.items.len);
}

// #562: a function that passes a field of its parameter back to itself,
// `f(x.next)`, makes the parameter a copy of its own field's cell. The
// parameter's summary links the cell's, which links that of the
// parameter's summary var of `next`, fed by the cell's summary var of
// `next`, whose summary would link the next one down, without end: a
// first build ran `run/UrlParser` out of memory. A summary var two
// summaries deep links nothing (`VLink.depth`), so the summaries are few,
// and the read still gives what the list holds.
test "a field passed back to its own parameter makes finitely many summaries" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const arena = arena_state.allocator();
    // Two list cells, each with property 1 (`next`) holding the other, and
    // the parameter holding the first.
    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
        (try p.prop(i, 1)).init = true;
    }
    try p.addSite(try fieldVar(p, 0, 1), 1);
    try settle(p);
    try p.addSite(try fieldVar(p, 1, 1), 0);
    try settle(p);
    const param = try p.newVar();
    try p.addSite(param, 0);
    try settle(p);
    const li = try p.newLoad();
    try p.summaryLoad(try p.summaryOf(param), 1, li);
    try settle(p);
    const cell = p.loads.items[li].out;
    // The call `f(x.next)`, and a read of `x.next.next` through the cell.
    try p.copy(cell, param);
    const again = try p.newLoad();
    try p.summaryLoad(try p.summaryOf(cell), 1, again);
    try settle(p);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try p.view(param)).sites);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try p.view(cell)).sites);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try p.view(p.loads.items[again].out)).sites);
    try testing.expect(p.summaries.items.len <= 8);
    for (p.summaries.items) |sm| try testing.expect(p.links_of.items[sm.of].depth <= 1);
}

// #487: a field summary is made for every var that copies into the spread
// one, transitively, and a summary feeds every summary its var copies into.
// Making them, and carrying a property, an unknown-key write or a site that
// is no object along them, recursed once per copy, so a chain of copies as
// long as a program makes it overflowed the stack. On `small_stack`'s
// stack, a chain of 10 000 copies and a spread of its last var: the summary
// is made, and what the chain's head gains later reaches it.
test "a field summary of a long chain of copies is made and fed without recursion" {
    try @import("../small_stack.zig").run(summaryOfLongChain, .{});
}

fn summaryOfLongChain() !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = try emptySpec(testing.allocator, arena);
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    // Site 0, an object whose property 1 holds itself; site 1, a function.
    try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(0), .any = try p.newVar() });
    try p.sites.append(arena, .{ .kind = .func, .module = 0, .node = @fromBackingInt(1), .any = try p.newVar() });
    try p.addSite(try fieldVar(p, 0, 1), 0);
    try settle(p);
    const head = try p.newVar();
    try p.addSite(head, 0);
    try settle(p);
    var last = head;
    for (0..10_000) |_| {
        const next = try p.newVar();
        try p.copy(last, next);
        last = next;
    }
    const sum = try p.summaryOf(last);
    try p.markWhole(sum);
    try settle(p);
    try testing.expectEqual(@as(usize, 1), p.summaries.items[sum].props.items.len);
    try testing.expectEqualSlices(u32, &.{0}, (try p.view(p.summaries.items[sum].props.items[0].vals)).sites);
    // A property the head's site gains later, along every summary.
    try p.addSite(try fieldVar(p, 0, 2), 0);
    try settle(p);
    const later = p.summaries.items[sum].props.items[1];
    try testing.expectEqual(@as(u32, 2), later.id);
    try testing.expectEqualSlices(u32, &.{0}, (try p.view(later.vals)).sites);
    // A write under an unknown key, and a site that is no object.
    try p.markAnyWritten(0);
    try testing.expect(p.summaries.items[sum].any_written);
    try p.addSite(head, 1);
    try settle(p);
    try testing.expect(p.summaries.items[sum].unknown);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try p.view(last)).sites);
}

// #498: a member read of a name reads the name's field summary, two edges
// per cell, and marks the property it reads on exactly the sites the name
// holds: those the summary folded, those of the summaries feeding it, and
// those either gains later, through a copy made before the read or after.
// It marks no other property, and reads no site whole: the release build
// drops a field no read reaches.
test "a read through a field summary marks the property on the sites it holds and no other" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const arena = arena_state.allocator();
    // Six object sites, each with properties 1 (holding site 100 + i) and 2.
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
        (try p.prop(i, 1)).init = true;
        (try p.prop(i, 2)).init = true;
        try p.addSite(try fieldVar(p, i, 1), 100 + i);
        try settle(p);
    }
    // `u` holds sites 0 and 1 and copies into `v`, which holds site 2 too.
    const u = try p.newVar();
    const v = try p.newVar();
    try p.join(u, .{ .sites = &.{ 0, 1 } });
    try settle(p);
    try p.copy(u, v);
    try p.addSite(v, 2);
    try settle(p);
    const li = try p.newLoad();
    const edges = p.edges.items.len;
    const sum = try p.summaryOf(v);
    try p.summaryLoad(sum, 1, li);
    try settle(p);
    const out = p.loads.items[li].out;
    try testing.expectEqualSlices(u32, &.{ 100, 101, 102 }, (try p.view(out)).sites);
    try testing.expect(!(try p.view(out)).undef and !(try p.view(out)).top);
    // Of the edges the summaries made, two are the cell's.
    var into: usize = 0;
    for (p.edges.items[edges..]) |e| if (e.to == out) {
        into += 1;
    };
    try testing.expectEqual(@as(usize, 2), into);
    // A site joining the feeding var later, and one a var linked after the
    // read brings, are marked and read too; site 3 is in no var.
    try p.addSite(u, 4);
    try settle(p);
    const t = try p.newVar();
    try p.addSite(t, 5);
    try settle(p);
    try p.copy(t, v);
    try testing.expectEqualSlices(u32, &.{ 100, 101, 102, 104, 105 }, (try p.view(out)).sites);
    for ([_]u32{ 0, 1, 2, 4, 5 }) |site| try testing.expect(p.findProp(site, 1).?.read);
    try testing.expect(!p.findProp(3, 1).?.read);
    // Property 2, which nothing reads, stays unread, and no site is read whole.
    i = 0;
    while (i < 6) : (i += 1) {
        try testing.expect(!p.findProp(i, 2).?.read);
        try testing.expect(!p.sites.items[i].all_read);
    }
    // The mark is in the summaries that feed `v`'s.
    try testing.expect(p.findMark(p.vars.items[u].summary, 1) != null);
    try testing.expect(p.findMark(p.vars.items[t].summary, 1) != null);
}

// #498: what makes a read through a summary `undefined` or anything reaches
// its cell from wherever it arises: a site lacking the key, folded into a
// summary that feeds the read's after the read was made; a site that
// escapes; a site that is no object.
test "a read through a field summary is undefined or anything as its sites are" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const arena = arena_state.allocator();
    // Sites 0, 1 and 3 have property 1 from their literal, site 2 lacks it,
    // and site 4 is a function.
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try p.sites.append(arena, .{ .kind = if (i == 4) .func else .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
        if (i != 2 and i != 4) (try p.prop(i, 1)).init = true;
    }
    const u = try p.newVar();
    const v = try p.newVar();
    try p.addSite(u, 0);
    try settle(p);
    try p.copy(u, v);
    const a = try p.newLoad();
    try p.summaryLoad(try p.summaryOf(v), 1, a);
    try settle(p);
    try testing.expect(!(try p.view(p.loads.items[a].out)).undef);
    try p.addSite(u, 2);
    try settle(p);
    try testing.expect((try p.view(p.loads.items[a].out)).undef);
    try testing.expect(p.findProp(2, 1).?.read and !p.findProp(2, 1).?.init);
    try testing.expect(!(try p.view(p.loads.items[a].out)).top);

    const w = try p.newVar();
    try p.addSite(w, 1);
    try settle(p);
    const b = try p.newLoad();
    try p.summaryLoad(try p.summaryOf(w), 1, b);
    try settle(p);
    try testing.expect(!(try p.view(p.loads.items[b].out)).top);
    try p.escapeSite(1);
    try settle(p);
    try testing.expect((try p.view(p.loads.items[b].out)).top);

    const x = try p.newVar();
    try p.addSite(x, 3);
    try settle(p);
    const c = try p.newLoad();
    try p.summaryLoad(try p.summaryOf(x), 1, c);
    try settle(p);
    try testing.expect(!(try p.view(p.loads.items[c].out)).top);
    try p.addSite(x, 4);
    try settle(p);
    try testing.expect((try p.view(p.loads.items[c].out)).top);
}

// #564: a record update `{...x, k: v}` makes a site whose fields the spread
// alone writes. Each such field is a copy of the summary's var of it and
// nothing else, so every spread of one summary shares one var per field
// (`Pts.spreadSummary`), fed by one edge, and a summary folding many such
// sites takes one edge from it, made when it folded them before the spread
// or after. A field the literal writes has its own var. A write of
// something more gives a shared field its own var, which holds what the
// shared one held and feeds what it fed for the site; the facts read of the
// site's properties are the same before and after.
test "a spread's untouched field shares the summary's var until something else writes it" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const arena = arena_state.allocator();
    // Sites 0, 1 and 4 are records with properties 1 and 2 (holding sites
    // 100 + i and 200 + i); sites 2 and 3 are the updates of them, and site 5
    // is a value written later.
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
        if (i == 2 or i == 3 or i == 5) continue;
        (try p.prop(i, 1)).init = true;
        (try p.prop(i, 2)).init = true;
        try p.addSite(try fieldVar(p, i, 1), 100 + i);
        try settle(p);
        try p.addSite(try fieldVar(p, i, 2), 200 + i);
        try settle(p);
    }
    const u = try p.newVar();
    try p.join(u, .{ .sites = &.{ 0, 1 } });
    try settle(p);
    const sum = try p.summaryOf(u);
    try p.markWhole(sum);
    try settle(p);
    const x1 = p.findSumProp(sum, 1).?;
    // A var holding both updates, read for property 1 before either
    // spread is evaluated: the read marks the property on both, which no
    // var holds yet.
    const w = try p.newVar();
    try p.join(w, .{ .sites = &.{ 2, 3 } });
    try settle(p);
    const li = try p.newLoad();
    try p.summaryLoad(try p.summaryOf(w), 1, li);
    try settle(p);
    const out = p.loads.items[li].out;
    try testing.expect(p.findProp(3, 1).?.vals == none and p.findProp(3, 1).?.read);
    try testing.expectEqual(@as(usize, 0), (try p.view(out)).sites.len);
    // Site 2's literal writes key 2 itself; site 3's writes nothing.
    try p.spreadSummary(2, sum, &.{2});
    try p.spreadSummary(3, sum, &.{});
    const shared = p.findProp(2, 1).?.vals;
    try testing.expectEqual(x1, p.findProp(2, 1).?.from);
    try testing.expectEqual(shared, p.findProp(3, 1).?.vals);
    try testing.expect(p.findProp(2, 2).?.from == none and p.findProp(2, 2).?.vals != p.findProp(3, 2).?.vals);
    try testing.expectEqual(p.findProp(3, 2).?.vals, p.cold.items[p.findSumProp(sum, 2).?].shared);
    try testing.expectEqual(@as(u32, 1), p.cold.items[shared].preds);
    try testing.expectEqualSlices(u32, &.{ 100, 101 }, (try p.view(shared)).sites);
    try testing.expect(p.findProp(2, 1).?.written and p.findProp(3, 1).?.written and !p.findProp(3, 1).?.init);
    // The read's summary takes one edge from the shared var for the two
    // sites, and the read what they hold.
    const w1 = p.findSumProp(p.vars.items[w].summary, 1).?;
    try testing.expectEqual(@as(u32, 1), p.cold.items[w1].preds);
    try testing.expectEqualSlices(u32, &.{ 100, 101 }, (try p.view(out)).sites);
    // The read's undefined, as `Prop.init` says: an update's spread key has
    // no initialiser of the literal's.
    try testing.expect((try p.view(out)).undef);

    p.ok = true;
    p.site_of = try arena.alloc([]u32, 1);
    p.site_of[0] = try arena.alloc(u32, 6);
    for (p.site_of[0], 0..) |*so, n| so.* = @intCast(n);
    const both: Pts.Val = .{ .sites = &.{ 2, 3 } };
    const Facts = struct { written: [3]bool, read: [3]bool, unread: [3]bool };
    const facts = struct {
        fn of(q: *const Pts, obj: Pts.Val) Facts {
            var f: Facts = undefined;
            for (0..3) |id| {
                f.written[id] = !q.neverWritten(obj, @intCast(id));
                f.read[id] = !q.neverRead(obj, @intCast(id));
                f.unread[id] = q.keyUnread(0, @fromBackingInt(3), @intCast(id));
            }
            return f;
        }
    }.of;
    const before = facts(p, both);
    try testing.expectEqual(Facts{ .written = .{ false, true, true }, .read = .{ false, true, false }, .unread = .{ true, false, true } }, before);

    // A write of more into site 3's field: its own var, fed by the
    // summary's and feeding the read's summary; site 2's stays shared.
    try p.write(.{ .sites = &.{3} }, 1, .{ .sites = &.{5} });
    try settle(p);
    const own = p.findProp(3, 1).?;
    try testing.expect(own.from == none and own.vals != shared);
    try testing.expectEqual(shared, p.findProp(2, 1).?.vals);
    try testing.expectEqualSlices(u32, &.{ 5, 100, 101 }, (try p.view(own.vals)).sites);
    try testing.expectEqualSlices(u32, &.{ 100, 101 }, (try p.view(shared)).sites);
    try testing.expectEqualSlices(u32, &.{ 5, 100, 101 }, (try p.view(out)).sites);
    // What reaches the source later reaches both, and the read.
    try p.addSite(u, 4);
    try settle(p);
    try testing.expectEqualSlices(u32, &.{ 100, 101, 104 }, (try p.view(shared)).sites);
    try testing.expectEqualSlices(u32, &.{ 5, 100, 101, 104 }, (try p.view(p.findProp(3, 1).?.vals)).sites);
    try testing.expectEqualSlices(u32, &.{ 5, 100, 101, 104 }, (try p.view(out)).sites);
    try testing.expectEqual(before, facts(p, both));
    // A second spread of another summary into site 2 gives its field its
    // own var too, holding both.
    const t = try p.newVar();
    try p.addSite(t, 4);
    try settle(p);
    const sum_t = try p.summaryOf(t);
    try p.markWhole(sum_t);
    try settle(p);
    try p.spreadSummary(2, sum_t, &.{});
    try testing.expect(p.findProp(2, 1).?.from == none);
    try testing.expectEqualSlices(u32, &.{ 100, 101, 104 }, (try p.view(p.findProp(2, 1).?.vals)).sites);
    try testing.expectEqual(before, facts(p, both));
}

// #564: `browser-inline` copies the model into each handler
// (`const $before = $model`) and spreads the copy, so every update's
// summary is the model's (#568). The fields of all those updates share
// the var of the model summary's property, and a summary folding them
// takes one edge. A copy that gains a second source is a copy no longer:
// its summary is its own, and its spread, evaluated again, gives the
// fields it writes their own vars, which hold what it holds; the others
// stay shared.
test "fields spread from copies of one record share one var until a copy gains a source" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const arena = arena_state.allocator();
    // Sites 0, 1 and 4 are records with property 1 holding site 100 + i;
    // sites 2 and 3 are updates.
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
        if (i == 2 or i == 3) continue;
        (try p.prop(i, 1)).init = true;
        try p.addSite(try fieldVar(p, i, 1), 100 + i);
        try p.drain();
    }
    const model = try p.newVar();
    try p.join(model, .{ .sites = &.{ 0, 1 } });
    try p.drain();
    const a = try p.newVar();
    const b = try p.newVar();
    try p.copy(model, a);
    try p.copy(model, b);
    const sum_a = try p.summaryOf(a);
    const sum_b = try p.summaryOf(b);
    try testing.expect(sum_a == p.vars.items[model].summary and sum_b == sum_a);
    try p.markWhole(sum_a);
    try p.drain();
    try p.markWhole(sum_b);
    try p.drain();
    try p.spreadSummary(2, sum_a, &.{});
    try p.spreadSummary(3, sum_b, &.{});
    const shared = p.findProp(2, 1).?.vals;
    try testing.expectEqual(shared, p.findProp(3, 1).?.vals);
    try testing.expectEqual(p.findSumProp(sum_a, 1).?, p.findProp(2, 1).?.from);
    try testing.expectEqual(p.findSumProp(sum_b, 1).?, p.findProp(3, 1).?.from);
    try testing.expectEqual(shared, p.cold.items[p.findSumProp(p.vars.items[model].summary, 1).?].shared);
    try testing.expectEqualSlices(u32, &.{ 100, 101 }, (try p.view(shared)).sites);
    const w = try p.newVar();
    try p.join(w, .{ .sites = &.{ 2, 3 } });
    try p.drain();
    const li = try p.newLoad();
    try p.summaryLoad(try p.summaryOf(w), 1, li);
    try p.drain();
    const out = p.loads.items[li].out;
    try testing.expectEqual(@as(u32, 1), p.cold.items[p.findSumProp(p.vars.items[w].summary, 1).?].preds);
    try testing.expectEqualSlices(u32, &.{ 100, 101 }, (try p.view(out)).sites);
    p.ok = true;
    const both: Pts.Val = .{ .sites = &.{ 2, 3 } };
    try testing.expect(!p.neverWritten(both, 1) and !p.neverRead(both, 1));
    // `b` takes a second source: site 3's field gets its own var, which
    // holds what `b`'s summary holds; site 2's stays shared.
    const q = try p.newVar();
    try p.addSite(q, 4);
    try p.drain();
    try p.copy(q, b);
    // What the spread's constraint does when `split` wakes it.
    const own_b = try p.summaryOf(b);
    try testing.expect(own_b != sum_b);
    try p.markWhole(own_b);
    try p.drain();
    try p.spreadSummary(3, own_b, &.{});
    try testing.expect(p.findProp(3, 1).?.from == none);
    try testing.expectEqualSlices(u32, &.{ 100, 101, 104 }, (try p.view(p.findProp(3, 1).?.vals)).sites);
    try testing.expectEqual(shared, p.findProp(2, 1).?.vals);
    try testing.expectEqualSlices(u32, &.{ 100, 101 }, (try p.view(shared)).sites);
    try testing.expectEqualSlices(u32, &.{ 100, 101, 104 }, (try p.view(out)).sites);
    try testing.expect(!p.neverWritten(both, 1) and !p.neverRead(both, 1));
}

/// A `Pts` of `n` object sites, each with properties 1 and 2 from its
/// literal, holding sites 100 + i and 200 + i.
fn aliasSites(p: *Pts, arena: Allocator, n: u32) !void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
        (try p.prop(i, 1)).init = true;
        (try p.prop(i, 2)).init = true;
        try p.addSite(try fieldVar(p, i, 1), 100 + i);
        try p.drain();
        try p.addSite(try fieldVar(p, i, 2), 200 + i);
        try p.drain();
    }
}

// #568: a var that copies one var and holds nothing of its own has that
// var's field summary, and so does a chain of such copies: no summary, and
// no edge, per copy. A read through the last copy reads the source's
// summary, and what the source gains later reaches it.
test "a var that copies one var alone shares its field summary" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    try aliasSites(p, arena_state.allocator(), 3);
    const u = try p.newVar();
    try p.join(u, .{ .sites = &.{ 0, 1 } });
    try settle(p);
    const v = try p.newVar();
    try p.copy(u, v);
    const w = try p.newVar();
    try p.copy(v, w);
    const edges = p.edges.items.len;
    const sum = try p.summaryOf(w);
    try testing.expectEqual(sum, try p.summaryOf(u));
    try testing.expectEqual(sum, try p.summaryOf(v));
    try testing.expect(p.vars.items[v].summary == none and p.vars.items[w].summary == none);
    try testing.expectEqual(@as(usize, 1), p.summaries.items.len);
    const li = try p.newLoad();
    try p.nameLoad(w, 1, li);
    const out = p.loads.items[li].out;
    try testing.expectEqualSlices(u32, &.{ 100, 101 }, (try p.view(out)).sites);
    // Two sites' `any` and property 1 into `u`'s summary, and the cell's
    // two: nothing for either copy.
    try testing.expectEqual(edges + 2 + 2 + 2, p.edges.items.len);
    try p.addSite(u, 2);
    try settle(p);
    try testing.expectEqualSlices(u32, &.{ 100, 101, 102 }, (try p.view(out)).sites);
    for ([_]u32{ 0, 1, 2 }) |site| try testing.expect(p.findProp(site, 1).?.read and !p.findProp(site, 2).?.read);
}

/// The facts of `secondSource`: what two reads give, and which properties
/// of the four sites are read.
const SplitFacts = struct { v1: [3]u32, t2: [4]u32, read: [4][2]bool };

/// `u` holds sites 0 and 1 and copies into `v`; `t` copies `v` and holds
/// site 3, so its summary is its own and fed by `v`'s; `q` holds site 2.
/// A read of `v.1` and one of `t.2`, and `q` copied into `v`: before the
/// reads (`split` false), so that `v` never shares `u`'s summary, or after.
fn secondSource(split: bool) !SplitFacts {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    try aliasSites(p, arena_state.allocator(), 4);
    const u = try p.newVar();
    try p.join(u, .{ .sites = &.{ 0, 1 } });
    try p.drain();
    const v = try p.newVar();
    try p.copy(u, v);
    const t = try p.newVar();
    try p.copy(v, t);
    try p.addSite(t, 3);
    try p.drain();
    const q = try p.newVar();
    try p.addSite(q, 2);
    try p.drain();
    if (!split) try p.copy(q, v);
    const lv = try p.newLoad();
    try p.nameLoad(v, 1, lv);
    const lt = try p.newLoad();
    try p.nameLoad(t, 2, lt);
    if (split) {
        try testing.expectEqual(try p.summaryOf(u), try p.summaryOf(v));
        try testing.expectEqualSlices(u32, &.{ 100, 101 }, (try p.view(p.loads.items[lv].out)).sites);
        try p.copy(q, v);
    }
    try testing.expect(try p.summaryOf(v) != try p.summaryOf(u));
    try testing.expect(p.vars.items[v].summary != none and p.vars.items[v].alias == none);
    var f: SplitFacts = undefined;
    const v1 = (try p.view(p.loads.items[lv].out)).sites;
    const t2 = (try p.view(p.loads.items[lt].out)).sites;
    try testing.expectEqual(@as(usize, 3), v1.len);
    try testing.expectEqual(@as(usize, 4), t2.len);
    @memcpy(&f.v1, v1);
    @memcpy(&f.t2, t2);
    for (0..4) |site| for (0..2) |k| {
        f.read[site][k] = p.findProp(@intCast(site), @intCast(k + 1)).?.read;
    };
    return f;
}

// #568: a var that shares its source's summary has its own once a second
// source copies into it. What read the shared summary through the var — a
// load cell, and the summary of a var it copies into — reads the new one,
// so the facts are those of a run where the var never shared one.
test "a second source gives a var its own summary, read by what read the shared one" {
    const early = try secondSource(false);
    const late = try secondSource(true);
    try testing.expectEqual(early, late);
    try testing.expectEqual([3]u32{ 100, 101, 102 }, late.v1);
    try testing.expectEqual([4]u32{ 200, 201, 202, 203 }, late.t2);
    try testing.expectEqual([4][2]bool{ .{ true, true }, .{ true, true }, .{ true, true }, .{ false, true } }, late.read);
}

// #568: a site joining a var that shares its source's summary is one the
// source lacks: the var's summary is its own from then on, and folds it.
// A read through the source does not see it.
test "a site of its own gives a var its own summary" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    try aliasSites(p, arena_state.allocator(), 2);
    const u = try p.newVar();
    try p.addSite(u, 0);
    try p.drain();
    const v = try p.newVar();
    try p.copy(u, v);
    const lv = try p.newLoad();
    try p.nameLoad(v, 1, lv);
    const lu = try p.newLoad();
    try p.nameLoad(u, 1, lu);
    try testing.expectEqual(try p.summaryOf(u), try p.summaryOf(v));
    try p.addSite(v, 1);
    try p.drain();
    const sum_v = try p.summaryOf(v);
    try testing.expect(sum_v != try p.summaryOf(u));
    try testing.expectEqualSlices(u32, &.{1}, p.summaries.items[sum_v].sites.items);
    try testing.expectEqualSlices(u32, &.{ 100, 101 }, (try p.view(p.loads.items[lv].out)).sites);
    try testing.expectEqualSlices(u32, &.{100}, (try p.view(p.loads.items[lu].out)).sites);
    try testing.expect(p.findProp(1, 1).?.read and !p.findProp(1, 2).?.read);
}

// #568, *Summaries across a filter*: a var shares its source's summary
// only where the copy edge links summaries — its filter wild or the
// source's. A stricter filter folds the sites one by one, as before.
test "a var whose filter differs from its source's never shares its summary" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    try aliasSites(p, arena_state.allocator(), 2);
    const k1: JsIr.RepKey = @fromBackingInt(7);
    const k2: JsIr.RepKey = @fromBackingInt(8);
    const u = try p.newVar();
    p.links_of.items[u].allow = k1;
    try p.join(u, .{ .sites = &.{ 0, 1 } });
    try p.drain();
    const other = try p.newVar();
    p.links_of.items[other].allow = k2;
    const same = try p.newVar();
    p.links_of.items[same].allow = k1;
    const wild = try p.newVar();
    for ([_]Pts.VarId{ other, same, wild }) |x| try p.copy(u, x);
    const sum_u = try p.summaryOf(u);
    const sum_other = try p.summaryOf(other);
    try testing.expect(sum_other != sum_u and p.vars.items[other].alias == none);
    try testing.expectEqual(@as(usize, 2), p.summaries.items[sum_other].sites.items.len);
    try testing.expectEqual(sum_u, try p.summaryOf(same));
    try testing.expectEqual(sum_u, try p.summaryOf(wild));
}

// #568: a var whose source's summary dies (`makeTop`) has its own first, so
// an uncapped var, which keeps its sites beside `top`, keeps a live summary
// as it would have had one of its own all along.
test "a var whose source goes top keeps a summary of its own" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    try aliasSites(p, arena_state.allocator(), 2);
    const u = try p.newVar();
    try p.join(u, .{ .sites = &.{ 0, 1 } });
    try p.drain();
    const v = try p.newVar();
    p.vars.items[v].uncapped = true;
    try p.copy(u, v);
    const lv = try p.newLoad();
    try p.nameLoad(v, 1, lv);
    try testing.expectEqual(try p.summaryOf(u), try p.summaryOf(v));
    try p.makeTop(u);
    try testing.expect(p.summaries.items[try p.summaryOf(u)].dead);
    try testing.expect(!p.summaries.items[try p.summaryOf(v)].dead);
    try testing.expect(try p.summaryOf(v) != try p.summaryOf(u));
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, (try p.view(v)).sites);
    try testing.expect((try p.view(v)).top and (try p.view(p.loads.items[lv].out)).top);
}

/// Var `v` holds `sites`, as a join would leave it: the table's entry,
/// with its id (`Pts.VSet.set`).
fn holdSites(p: *Pts, v: Pts.VarId, sites: []const u32) Allocator.Error!void {
    const id = try p.idOf(sites);
    p.vars.items[v].set = id;
    p.vars.items[v].sites = p.setSites(id);
}

// #563: joins wait in a var's batch until the worklist drains. 300 sites
// joined one by one, in one evaluation, into a var with a successor: each
// var takes one batch, and the successor's batch is the 300 sites at once.
test "a var fed 300 single-site joins in one evaluation forwards one batch" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const v = try p.newVar();
    const w = try p.newVar();
    try p.copy(v, w);
    const joins = s.stats.pts_joins;
    var site: u32 = 0;
    while (site < 300) : (site += 1) try p.addSite(v, 299 - site);
    try testing.expectEqual(joins, s.stats.pts_joins);
    try testing.expectEqual(@as(usize, 1), p.pending.items.len);
    try p.drain();
    try testing.expectEqual(joins + 2, s.stats.pts_joins);
    try testing.expectEqual(s.stats.pts_joins_empty, 0);
    const held = try p.view(w);
    try testing.expectEqual(@as(usize, 300), held.sites.len);
    for (held.sites, 0..) |x, i| try testing.expectEqual(@as(u32, @intCast(i)), x);
    // Both vars hold the one entry.
    try testing.expectEqual(held.set, (try p.view(v)).set);
}

// #563: a value carries its set's id beside its sites. One read before a
// later join keeps the slice and the id it was read with, and the id still
// names that slice; an id compares as the sites do.
test "a value read before a later join keeps its slice and its id" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const v = try p.newVar();
    try p.join(v, .{ .sites = &.{ 1, 4 } });
    try p.drain();
    const before = try p.view(v);
    try p.join(v, .{ .sites = &.{ 2, 3 } });
    try p.drain();
    const after = try p.view(v);
    try testing.expectEqualSlices(u32, &.{ 1, 4 }, before.sites);
    try testing.expectEqual(before.sites.ptr, p.setSites(before.set).ptr);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, after.sites);
    try testing.expect(before.set != after.set);
    // A slice built by hand finds the entry of its sites.
    try testing.expectEqual(after.set, try p.setOf(.{ .sites = &.{ 1, 2, 3, 4 } }));
    try testing.expect(Pts.sameSites(after, .{ .sites = &.{ 1, 2, 3, 4 } }));
    try testing.expectEqual(try p.single(7), try p.setOf(.{ .sites = &.{7} }));
}

// #563: the worklist is first in, first out, and a batch waits until the
// end of the evaluation; any fair order reaches the same least fixpoint.
// A cycle of three copies with a tail, joined in two orders — every join
// drained at once, and all of them in one batch the other way round —
// holds the same sites and flags in every var.
test "the order of the worklist changes no fact on a small cycle" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var facts: [2][4]Pts.Val = undefined;
    for (0..2) |order| {
        var s = try emptySpec(testing.allocator, arena_state.allocator());
        s.pts = .init(&s);
        defer s.pts.deinit();
        const p = &s.pts;
        var vs: [4]Pts.VarId = undefined;
        for (&vs) |*x| x.* = try p.newVar();
        try p.copy(vs[0], vs[1]);
        try p.copy(vs[1], vs[2]);
        try p.copy(vs[2], vs[0]);
        try p.copy(vs[2], vs[3]);
        const joins = [_]struct { v: usize, val: Pts.Val }{
            .{ .v = 0, .val = .{ .sites = &.{1} } },
            .{ .v = 2, .val = .{ .sites = &.{ 2, 5 }, .nul = true } },
            .{ .v = 1, .val = .{ .sites = &.{3}, .prim = true } },
            .{ .v = 3, .val = .{ .sites = &.{4} } },
        };
        for (0..joins.len) |k| {
            const j = joins[if (order == 0) k else joins.len - 1 - k];
            try p.join(vs[j.v], j.val);
            if (order == 0) try p.drain();
        }
        try p.drain();
        for (vs, 0..) |x, i| {
            const val = try p.view(x);
            facts[order][i] = .{ .prim = val.prim, .nul = val.nul, .sites = try arena_state.allocator().dupe(u32, val.sites) };
        }
    }
    for (facts[0], facts[1], 0..) |a, b, i| {
        try testing.expectEqualSlices(u32, a.sites, b.sites);
        try testing.expect(a.prim == b.prim and a.nul == b.nul);
        try testing.expectEqualSlices(u32, if (i == 3) &.{ 1, 2, 3, 4, 5 } else &.{ 1, 2, 3, 5 }, a.sites);
    }
}

/// What waits, carried on as the end of a sweep carries it: the joins, then
/// the folds into field summaries they left (`Pts.foldWaiting`, #565).
fn settle(p: *Pts) Allocator.Error!void {
    try p.drain();
    try p.foldWaiting();
}

/// Two object sites, 0 and 1, each with properties 1 and 2 holding sites
/// 100 + i and 200 + i, and an empty var with a field summary read whole,
/// as a spread reads it: what #565's tests fold into.
fn wholeSummaryVar(p: *Pts, arena: Allocator) Allocator.Error!Pts.VarId {
    var i: u32 = 0;
    while (i < 2) : (i += 1) {
        try p.sites.append(arena, .{ .kind = .object, .module = 0, .node = @fromBackingInt(i), .any = try p.newVar() });
        try p.addSite(try fieldVar(p, i, 1), 100 + i);
        try p.addSite(try fieldVar(p, i, 2), 200 + i);
        try p.drain();
    }
    const v = try p.newVar();
    try p.markWhole(try p.summaryOf(v));
    return v;
}

/// How many copy edges end at one of summary `sum`'s vars.
fn edgesInto(p: *const Pts, sum: u32) usize {
    const sm = p.summaries.items[sum];
    var n: usize = 0;
    for (p.edges.items) |e| {
        if (e.to == sm.any) n += 1;
        for (sm.props.items) |sp| {
            if (e.to == sp.vals) n += 1;
        }
    }
    return n;
}

// #565: a batch that makes a var `top` is applied before the batch's sites,
// whichever was joined first, and a site that joins a var already `top`
// escapes: no site is folded into the summary that dies with it.
test "a batch that makes a var top folds none of its sites" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for (0..2) |order| {
        var s = try emptySpec(testing.allocator, arena_state.allocator());
        s.pts = .init(&s);
        defer s.pts.deinit();
        const p = &s.pts;
        const v = try wholeSummaryVar(p, arena_state.allocator());
        const sum = try p.summaryOf(v);
        const edges = p.edges.items.len;
        // The sites first and `top` after, or `top` first: one batch.
        if (order == 0) {
            try p.join(v, .{ .sites = &.{ 0, 1 } });
            try p.join(v, Pts.Val.top_val);
        } else {
            try p.join(v, Pts.Val.top_val);
            try p.join(v, .{ .sites = &.{ 0, 1 } });
        }
        try testing.expectEqual(@as(usize, 1), p.pending.items.len);
        try p.drain();
        try p.foldWaiting();
        try testing.expect(p.summaries.items[sum].dead);
        try testing.expectEqual(@as(usize, 0), p.summaries.items[sum].sites.items.len);
        try testing.expectEqual(edges, p.edges.items.len);
        try testing.expect(p.sites.items[0].escaped and p.sites.items[1].escaped);
    }
}

// #565: a site a var takes by no linking edge waits to be folded until the
// end of the sweep (`foldWaiting`). A var made `top` in between — by a later
// evaluation, an escape or the cap — has a dead summary by then, and the
// fold makes no edge; a var still live has the site folded then, every
// property of it linked, as the fold at the join did.
test "a fold waits for the end of the sweep, and a summary dead by then takes none" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for ([_]bool{ false, true }) |dies| {
        var s = try emptySpec(testing.allocator, arena_state.allocator());
        s.pts = .init(&s);
        defer s.pts.deinit();
        const p = &s.pts;
        const v = try wholeSummaryVar(p, arena_state.allocator());
        const sum = try p.summaryOf(v);
        try p.addSite(v, 0);
        try p.drain();
        try testing.expectEqualSlices(u32, &.{0}, (try p.view(v)).sites);
        try testing.expectEqual(@as(usize, 1), p.folds.items.len);
        try testing.expectEqual(@as(usize, 0), p.summaries.items[sum].sites.items.len);
        try testing.expectEqual(@as(usize, 0), edgesInto(p, sum));
        if (dies) try p.makeTop(v);
        try p.foldWaiting();
        try testing.expectEqual(@as(usize, 0), p.folds.items.len);
        if (dies) {
            try testing.expect(p.summaries.items[sum].dead);
            try testing.expectEqual(@as(usize, 0), p.summaries.items[sum].sites.items.len);
            try testing.expectEqual(@as(usize, 0), edgesInto(p, sum));
            try testing.expect(p.sites.items[0].escaped);
        } else {
            try testing.expectEqualSlices(u32, &.{0}, p.summaries.items[sum].sites.items);
            // Two properties and `any`.
            try testing.expectEqual(@as(usize, 3), edgesInto(p, sum));
            try testing.expectEqualSlices(u32, &.{100}, (try p.view(p.findSumProp(sum, 1).?)).sites);
            try testing.expectEqualSlices(u32, &.{200}, (try p.view(p.findSumProp(sum, 2).?)).sites);
            try testing.expect(p.sites.items[0].all_read);
        }
    }
}

// #575: an analysis keeps fact 3's state when the rewrite before it only
// wrote literals for reads fact 3 made the primitive alone. In `const b =
// "abc"; const c = b;` the read of `b` is written `"abc"`, which moves no
// fact 3 reads, and the analysis after it solves nothing; a safety build
// solves anyway and compares (`Pts.checkKept`).
test "a read written as its literal leaves fact 3 to be kept" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    const name_b = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const name_c = try b.intern(.local(@fromBackingInt(@intCast(2))));
    const text = try b.addString("abc");
    const abc = try b.addParts(.string, Node.no_pos, text[0], text[1]);
    const decl_b = try b.addParts(.const_decl, Node.no_pos, name_b.int(), abc.int());
    const read = try b.addParts(.ident, Node.no_pos, name_b.int(), 0);
    const decl_c = try b.addParts(.const_decl, Node.no_pos, name_c.int(), read.int());
    var ir = try b.toOwned(try b.addRange(&.{ decl_b, decl_c }));
    defer ir.deinit(gpa);
    const global = [_]u32{ 0, 1 };
    const modules = [_]Module{.{ .ir = &ir, .global = &global }};
    var s: Spec = try .init(gpa, arena_state.allocator(), .{ .modules = &modules, .globals = 2, .escaping = &.{1} });
    // `c` is read by a file the pass cannot see: a root, so its statement
    // runs (since slice 6 a declaration nothing live refers to is in no
    // solve, `liveStatements`).
    s.pts = .init(&s);
    defer s.pts.deinit();
    // Hands the module its columns back, owned and exactly sized.
    defer s.finish() catch @panic("out of memory");
    try testing.expect(try s.analyse());
    const runs = s.stats.points_to_runs;
    try testing.expect(s.fact3Kept());
    _ = try s.rewrite();
    // The read is the literal, and no change fact 3 reads was made.
    try testing.expectEqual(Node.Tag.string, ir.tag(read));
    try testing.expect(!s.mods[0].fact3);
    try testing.expect(s.fact3Kept());
    try testing.expect(try s.analyse());
    try testing.expectEqual(runs, s.stats.points_to_runs);
    try testing.expectEqual(@as(u64, 1), s.stats.points_to_reused);
}

// #796: which names are a `const` copy of a name declared nowhere else.
// `const a = 1; const b = a; const c = b; const c = 1;` and `(d) => { const
// d = a; }`: `b` copies `a`; `c` is declared twice and `d` is a parameter
// too, so neither is; `a` is bound to a literal.
test "a const copy is an alias only when it is its name's one declaration" {
    const gpa = testing.allocator;
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    const name_a = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const name_b = try b.intern(.local(@fromBackingInt(@intCast(2))));
    const name_c = try b.intern(.local(@fromBackingInt(@intCast(3))));
    const name_d = try b.intern(.local(@fromBackingInt(@intCast(4))));
    const one = try b.addString("1");
    const lit = try b.addParts(.number, Node.no_pos, one[0], one[1]);
    const decl_a = try b.addParts(.const_decl, Node.no_pos, name_a.int(), lit.int());
    const read_a = try b.addParts(.ident, Node.no_pos, name_a.int(), 0);
    const decl_b = try b.addParts(.const_decl, Node.no_pos, name_b.int(), read_a.int());
    const read_b = try b.addParts(.ident, Node.no_pos, name_b.int(), 0);
    const decl_c = try b.addParts(.const_decl, Node.no_pos, name_c.int(), read_b.int());
    const lit2 = try b.addParts(.number, Node.no_pos, one[0], one[1]);
    const decl_c2 = try b.addParts(.const_decl, Node.no_pos, name_c.int(), lit2.int());
    const read_a2 = try b.addParts(.ident, Node.no_pos, name_a.int(), 0);
    const decl_d = try b.addParts(.const_decl, Node.no_pos, name_d.int(), read_a2.int());
    const params = try b.addNames(&.{name_d});
    const fbody = try b.addRange(&.{decl_d});
    const func = try b.addRecord(JsIr.Func{ .params_start = params.start, .params_end = params.end, .body_start = fbody.start, .body_end = fbody.end });
    const arrow = try b.addParts(.arrow, Node.no_pos, @backingInt(func), Node.arrow_plain);
    const stmt = try b.addParts(.expr_stmt, Node.no_pos, arrow.int(), 0);
    var ir = try b.toOwned(try b.addRange(&.{ decl_a, decl_b, decl_c, decl_c2, stmt }));
    defer ir.deinit(gpa);
    const src = try Pts.aliasSources(gpa, &ir, ir.names.len);
    defer gpa.free(src);
    try testing.expectEqual(read_a.int(), src[name_b.int()]);
    try testing.expectEqual(none, src[name_a.int()]);
    try testing.expectEqual(none, src[name_c.int()]);
    try testing.expectEqual(none, src[name_d.int()]);
}

/// An allocator that never grows or shrinks a block in place, so that every
/// append past the capacity moves the list and frees the block it left —
/// which the testing allocator then poisons.
const MovingAllocator = struct {
    child: std.mem.Allocator,

    fn allocator(m: *MovingAllocator) std.mem.Allocator {
        return .{ .ptr = m, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const m: *MovingAllocator = @ptrCast(@alignCast(ctx));
        return m.child.rawAlloc(len, alignment, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const m: *MovingAllocator = @ptrCast(@alignCast(ctx));
        m.child.rawFree(memory, alignment, ret_addr);
    }
};

// #770: `returnExpr` of `(a) => { if (a) { if (a) return 1; return 2; }
// return 3; }` on a module no pass has appended to yet. The inner `if`
// appends its conditional to `extra`, which has no room and moves; the outer
// `if` then reads the rest of its body, which was a slice of the old block.
test "returnExpr reads its body after a nested conditional moved extra" {
    var moving: MovingAllocator = .{ .child = testing.allocator };
    const gpa = moving.allocator();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    const name_f = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const name_a = try b.intern(.local(@fromBackingInt(@intCast(2))));
    var rets: [3]Index = undefined;
    for (&rets, [_][]const u8{ "1", "2", "3" }) |*r, digits| {
        const text = try b.addString(digits);
        const number = try b.addParts(.number, Node.no_pos, text[0], text[1]);
        r.* = try b.addParts(.return_stmt, Node.no_pos, number.int(), 0);
    }
    const none_else = try b.addRange(&.{});
    const inner_then = try b.addRange(&.{rets[0]});
    const inner_rec = try b.addRecord(JsIr.If{ .then_start = inner_then.start, .then_end = inner_then.end, .else_start = none_else.start, .else_end = none_else.end });
    const inner_test = try b.addParts(.ident, Node.no_pos, name_a.int(), 0);
    const inner_if = try b.addParts(.if_stmt, Node.no_pos, inner_test.int(), @backingInt(inner_rec));
    const outer_then = try b.addRange(&.{ inner_if, rets[1] });
    const outer_rec = try b.addRecord(JsIr.If{ .then_start = outer_then.start, .then_end = outer_then.end, .else_start = none_else.start, .else_end = none_else.end });
    const outer_test = try b.addParts(.ident, Node.no_pos, name_a.int(), 0);
    const outer_if = try b.addParts(.if_stmt, Node.no_pos, outer_test.int(), @backingInt(outer_rec));
    const params = try b.addNames(&.{name_a});
    const body = try b.addRange(&.{ outer_if, rets[2] });
    const func = try b.addRecord(JsIr.Func{ .params_start = params.start, .params_end = params.end, .body_start = body.start, .body_end = body.end });
    const arrow = try b.addParts(.arrow, Node.no_pos, @backingInt(func), Node.arrow_plain);
    const decl_f = try b.addParts(.const_decl, Node.no_pos, name_f.int(), arrow.int());
    var ir = try b.toOwned(try b.addRange(&.{decl_f}));
    defer ir.deinit(gpa);
    const global = [_]u32{ 0, none };
    const modules = [_]Module{.{ .ir = &ir, .global = &global }};
    var s: Spec = try .init(gpa, arena_state.allocator(), .{ .modules = &modules, .globals = 1, .escaping = &.{} });
    s.pts = .init(&s);
    defer s.pts.deinit();
    defer s.finish() catch @panic("out of memory");
    const f = ir.extraData(func, JsIr.Func);
    const ret = (try s.returnExpr(0, ir.extraSlice(f.body(), Index), 0)).?;
    // `a ? (a ? 1 : 2) : 3`.
    try testing.expectEqual(Node.Tag.cond, ir.tag(ret));
    const outer = ir.extraData(@fromBackingInt(@intCast(ir.data(ret).rhs)), JsIr.Cond);
    try testing.expectEqual(Node.Tag.cond, ir.tag(outer.consequent));
    try testing.expectEqual(Node.Tag.number, ir.tag(outer.alternate));
}

/// `const f = (a) => <body>; const r = f(<arg>);` as one module, `f` and
/// `r` whole-program names 0 and 1: analysed once, then rewritten, which
/// drops `a` with its argument (#582's tests).
const DropProgram = struct {
    ir: JsIr,
    func: ExtraIndex,
    read: ?Index,
};

fn dropProgram(b: *JsIr.Builder, read_param: bool, object_arg: bool) !DropProgram {
    const name_f = try b.intern(.local(@fromBackingInt(@intCast(1))));
    const name_r = try b.intern(.local(@fromBackingInt(@intCast(2))));
    const name_a = try b.intern(.local(@fromBackingInt(@intCast(3))));
    const read = if (read_param) try b.addParts(.ident, Node.no_pos, name_a.int(), 0) else null;
    const one = try b.addString("1");
    const value = read orelse try b.addParts(.number, Node.no_pos, one[0], one[1]);
    const ret = try b.addParts(.return_stmt, Node.no_pos, value.int(), 0);
    const params = try b.addNames(&.{name_a});
    const body = try b.addRange(&.{ret});
    const func = try b.addRecord(JsIr.Func{ .params_start = params.start, .params_end = params.end, .body_start = body.start, .body_end = body.end });
    const arrow = try b.addParts(.arrow, Node.no_pos, @backingInt(func), Node.arrow_plain);
    const decl_f = try b.addParts(.const_decl, Node.no_pos, name_f.int(), arrow.int());
    const callee = try b.addParts(.ident, Node.no_pos, name_f.int(), 0);
    const arg = if (object_arg) try b.addParts(.object, Node.no_pos, 0, 0) else blk: {
        const text = try b.addString("x");
        break :blk try b.addParts(.string, Node.no_pos, text[0], text[1]);
    };
    const args = try b.addRecord(try b.addRange(&.{arg}));
    const call = try b.addParts(.call, Node.no_pos, callee.int(), @backingInt(args));
    const decl_r = try b.addParts(.const_decl, Node.no_pos, name_r.int(), call.int());
    return .{ .ir = try b.toOwned(try b.addRange(&.{ decl_f, decl_r })), .func = func, .read = read };
}

// #582: a parameter every call passes the same literal goes with its
// arguments, and fact 3's state takes the drop: in `const f = (a) => a;
// const r = f("x");` the read of `a` is written `"x"`, `a` holds the
// primitive alone, and the argument is a literal, so the analysis after
// the rewrite keeps the state with `a` gone from `f`'s site and its local.
// A safety build solves anyway and compares (`Pts.checkKept`).
test "a dropped parameter that held a primitive leaves fact 3 to be kept" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    var program = try dropProgram(&b, true, false);
    defer program.ir.deinit(gpa);
    const global = [_]u32{ 0, 1, none };
    const modules = [_]Module{.{ .ir = &program.ir, .global = &global }};
    var s: Spec = try .init(gpa, arena_state.allocator(), .{ .modules = &modules, .globals = 2, .escaping = &.{} });
    s.pts = .init(&s);
    defer s.pts.deinit();
    // Hands the module its columns back, owned and exactly sized.
    defer s.finish() catch @panic("out of memory");
    try testing.expect(try s.analyse());
    const runs = s.stats.points_to_runs;
    _ = try s.rewrite();
    try testing.expectEqual(Node.Tag.string, program.ir.tag(program.read.?));
    try testing.expectEqual(@as(u32, 0), program.ir.extraData(program.func, JsIr.Func).params().len());
    try testing.expect(!s.mods[0].fact3);
    try testing.expect(s.fact3Kept());
    try testing.expect(try s.analyse());
    try testing.expectEqual(runs, s.stats.points_to_runs);
    try testing.expectEqual(@as(u64, 1), s.stats.points_to_reused);
    try testing.expectEqual(@as(usize, 0), s.pts.locals.count());
}

// #582: a parameter nothing reads goes whatever it is passed, and when a
// call passed it an object, fact 3 made a site and joined it into the
// parameter, which a solve without the argument would not: `const f = (a)
// => 1; const r = f({});` solves again.
test "a dropped parameter that held an object makes fact 3 solve again" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var b: JsIr.Builder = .init(gpa);
    defer b.deinit();
    var program = try dropProgram(&b, false, true);
    defer program.ir.deinit(gpa);
    const global = [_]u32{ 0, 1, none };
    const modules = [_]Module{.{ .ir = &program.ir, .global = &global }};
    var s: Spec = try .init(gpa, arena_state.allocator(), .{ .modules = &modules, .globals = 2, .escaping = &.{} });
    s.pts = .init(&s);
    defer s.pts.deinit();
    // Hands the module its columns back, owned and exactly sized.
    defer s.finish() catch @panic("out of memory");
    try testing.expect(try s.analyse());
    const runs = s.stats.points_to_runs;
    _ = try s.rewrite();
    try testing.expectEqual(@as(u32, 0), program.ir.extraData(program.func, JsIr.Func).params().len());
    try testing.expect(s.mods[0].fact3);
    try testing.expect(!s.fact3Kept());
    try testing.expect(try s.analyse());
    try testing.expect(s.stats.points_to_runs > runs);
    try testing.expectEqual(@as(u64, 0), s.stats.points_to_reused);
}

/// The var of property `id` of site `site`, its own, the property made
/// when it is new: what a literal's key joins (`Pts.ownField`).
fn fieldVar(p: *Pts, site: u32, id: u32) Allocator.Error!Pts.VarId {
    return p.ownField(site, try p.propAt(site, id), id);
}

// #577: a lookup that starts from where a walk expects the id answers as
// the binary search does, from every hint, in lists with gaps, and for an
// id that is absent, below the first or past the last; and so do the
// searches without an order function.
test "a lookup from a hint finds what the binary search finds" {
    var prng: std.Random.DefaultPrng = .init(577);
    const random = prng.random();
    var items: [48]Pts.SumProp = undefined;
    var words: [48]u32 = undefined;
    const order = struct {
        fn byId(id: u32, sp: Pts.SumProp) std.math.Order {
            return std.math.order(id, sp.id);
        }
    };
    var round: u32 = 0;
    while (round < 200) : (round += 1) {
        const len = random.uintLessThan(usize, items.len + 1);
        var id: u32 = random.uintLessThan(u32, 3);
        for (items[0..len], words[0..len]) |*it, *w| {
            it.* = .{ .id = id, .vals = id };
            w.* = id;
            id += 1 + random.uintLessThan(u32, 4);
        }
        const list = items[0..len];
        var want: u32 = 0;
        while (want < id + 2) : (want += 1) {
            const expected = std.sort.lowerBound(Pts.SumProp, list, want, order.byId);
            try testing.expectEqual(expected, Pts.lowerU32(words[0..len], want));
            const held = expected < len and list[expected].id == want;
            try testing.expectEqual(held, Pts.holdsSite(words[0..len], want));
            var hint: usize = 0;
            while (hint < len + 3) : (hint += 1) try testing.expectEqual(expected, Pts.indexAt(Pts.SumProp, list, want, hint));
        }
    }
}

// #577: `hasEdge` walks whichever of the two lists is shorter, or asks the
// set of the edges between long lists, and `copy` remembers the last edge
// of each end: none of them may miss an edge or find one that was never
// made. Vars with many edges in and out exercise every path.
test "the edge check finds every edge made and no other" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var s = try emptySpec(testing.allocator, arena_state.allocator());
    s.pts = .init(&s);
    defer s.pts.deinit();
    const p = &s.pts;
    const n = 40;
    var made: [n][n]bool = @splat(@splat(false));
    var v: u32 = 0;
    while (v < n) : (v += 1) _ = try p.newVar();
    var prng: std.Random.DefaultPrng = .init(0x577);
    const random = prng.random();
    var step: u32 = 0;
    while (step < 2000) : (step += 1) {
        // Vars 0-3 copy into many and 4-7 are copied into by many, so
        // their lists grow long; the others have a few edges each.
        const from: u32 = if (step % 3 == 0) random.uintLessThan(u32, 4) else random.uintLessThan(u32, n);
        const to: u32 = if (step % 3 == 1) 4 + random.uintLessThan(u32, 4) else random.uintLessThan(u32, n);
        const edges = p.edges.items.len;
        try p.copy(from, to);
        const fresh = from != to and !made[from][to];
        try testing.expectEqual(edges + @intFromBool(fresh), p.edges.items.len);
        if (from != to) made[from][to] = true;
        if (step % 100 != 99) continue;
        var a: u32 = 0;
        while (a < n) : (a += 1) {
            var b: u32 = 0;
            while (b < n) : (b += 1) if (a != b) try testing.expectEqual(made[a][b], p.hasEdge(a, b));
        }
    }
    try testing.expect(p.cold.items[0].succs > Pts.short_edges and p.cold.items[4].preds > Pts.short_edges);
}

// The check is itself a safety property: equal representations must pass,
// but a live site, value bit or property flag must not disappear unnoticed.
test "fact-3 comparison maps sets and compares effective sparse properties" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var s = try emptySpec(testing.allocator, arena);
    var ref = try emptySpec(testing.allocator, arena);
    s.pts = .init(&s);
    ref.pts = .init(&ref);
    defer s.pts.deinit();
    defer ref.pts.deinit();
    const p = &s.pts;
    const r = &ref.pts;
    for (0..3) |i| {
        try p.sites.append(p.tmp.allocator(), .{ .kind = .object, .module = 0, .node = @fromBackingInt(@intCast(i)), .any = none, .escaped = i == 2 });
        try r.sites.append(r.tmp.allocator(), .{ .kind = .object, .module = 0, .node = @fromBackingInt(@intCast(i)), .any = none, .escaped = i == 2 });
    }
    const c: Pts.FactCheck = .{ .x = p, .y = r, .map = &.{ 1, 0, 2 } };
    var a = Pts.Val.top_val;
    var b = Pts.Val.top_val;
    a.sites = &.{ 0, 1, 2 };
    b.sites = &.{ 0, 1 };
    try testing.expect(c.sameVal(a, b));
    b.sites = &.{0};
    try testing.expect(!c.sameVal(a, b));
    b.sites = &.{ 0, 1 };
    b.nul = false;
    try testing.expect(!c.sameVal(a, b));

    const empty: Pts.Prop = .{ .id = 0, .vals = none, .written = true };
    try testing.expect(c.sameProp(empty, null, true, false));
    try testing.expect(c.sameProp(null, empty, true, false));
    try testing.expect(!c.sameProp(empty, null, false, false));
    var marked = empty;
    marked.read = true;
    try testing.expect(!c.sameProp(marked, null, true, true));
    marked = empty;
    marked.init = true;
    try testing.expect(!c.sameProp(marked, null, true, true));

    const v = try p.newVar();
    try holdSites(p, v, &.{2});
    const escaped: Pts.Prop = .{ .id = 0, .vals = v };
    try testing.expect(c.sameProp(escaped, null, true, true));
    try testing.expect(!c.sameProp(escaped, null, true, false));
    try holdSites(p, v, &.{0});
    try testing.expect(!c.sameProp(escaped, null, true, true));
    try holdSites(p, v, &.{});
    p.vars.items[v].prim = true;
    try testing.expect(!c.sameProp(escaped, null, true, false));
}
