//! The read-only write-set pass (`docs/design/write-sets.md`, normative).
//!
//! For a program's `update`, per message key (§4.4), the write set: the
//! paths into the model at which the returned model may not be the same
//! JavaScript value as the old one (§1.3); for its `view`, per hole, the
//! model paths it reads (§3.6) and its class (§8.1). Nothing reads the
//! result yet: `beni dump --stage=writes` prints it (§8.1), and R3 and R4
//! will consume it (§9).
//!
//! **The domain** (§2–§3): paths, index symbols, tag facts, abstract values
//! (terms) and write sets are interned into flat word tables, so equal
//! things are one id — the hash-consing §3.1 asks for (*Terms are shared*),
//! which is what keeps a chain of `if`s a DAG and makes a fixpoint's
//! stability one integer compare.
//!
//! **The interpreter** (§3.3) walks a declaration's `Bir` with an
//! environment of terms. A top-level function is SUMMARISED once — its body
//! with each parameter a root `πᵢ` of its own — and a call instantiates the
//! summary by substitution (§4.1–§4.2); a recursive component is iterated
//! to a fixpoint (§4.3). A key is one walk of `update`'s body under the
//! key's message facts; a key is split where the walk meets a `case` on an
//! undecided path of the message (§4.4). `view` is walked with every call of
//! the program's own functions inlined, so each hole is seen with the
//! anchors of its call site (§3.6).
//!
//! **Determinism** (§7): ids are assigned in the order the walk meets
//! things, and the walk is a function of the program's text — it starts at
//! `update`, `view` and `init` and follows calls, so neither the order of
//! declarations nor `--jobs` moves it. Everything printed is sorted by text
//! or by a structural order of paths, never by an id.
//!
//! Every cap of §6.1 yields the top of its lattice — `Fresh`, `value` where
//! it lands — and never a diagnostic; the pass produces none (§0 rules).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Dispatch = @import("../check/Dispatch.zig");
const SourceStore = @import("../SourceStore.zig");
pub const Core = @import("Core.zig");

const Inst = Bir.Inst;
const Symbol = InternPool.Symbol;

const Writes = @This();

// ---------------------------------------------------------------------------
// The caps (§6.1, owner's decision O2: the recommended values)
// ---------------------------------------------------------------------------

/// k: path and value depth (§2.2, O1).
pub const k_limit: u32 = 8;
/// A: alternatives in one plain `Alt`.
pub const cap_alt: usize = 16;
/// D: nested instantiation depth.
pub const cap_inst_depth: u32 = 8;
/// I: rounds of a recursive component.
pub const cap_rounds: u32 = 4;
/// S: DAG nodes in any term.
pub const cap_size: u32 = 4096;
/// W: node visits per summary or per key; `--writes-work` lowers it.
pub const default_work: u64 = 1 << 20;
/// L: leaves of a program's key tree.
pub const cap_leaves: u32 = 256;

pub const none: u32 = std.math.maxInt(u32);

pub const Error = Allocator.Error || error{WorkCap};

pub const Input = struct {
    gpa: Allocator,
    graph: *const Graph,
    /// Per module index.
    birs: []const *const Bir,
    provenance: []const Interface.Provenance,
    /// Per module index; shorter when a module was not checked.
    dispatch: []const Dispatch,
    interner: *const InternPool.Global,
    /// Per module index.
    module_names: []const []const u8,
    packages: []const SourceStore.Package,
    /// Per module index: whether its `main` is a program the dump prints.
    targets: []const bool,
    work_cap: u64 = default_work,
};

// ---------------------------------------------------------------------------
// Interned word tables
// ---------------------------------------------------------------------------

const Table = struct {
    words: std.ArrayList(u32) = .empty,
    starts: std.ArrayList(u32) = .empty,
    map: std.HashMapUnmanaged(Interned, void, SlotCtx, std.hash_map.default_max_load_percentage) = .empty,

    const Interned = struct { id: u32 };

    const SlotCtx = struct {
        t: *const Table,
        pub fn hash(c: SlotCtx, k: Interned) u64 {
            return hashWords(c.t.get(k.id));
        }
        pub fn eql(_: SlotCtx, a: Interned, b: Interned) bool {
            return a.id == b.id;
        }
    };

    const Adapter = struct {
        t: *const Table,
        pub fn hash(_: Adapter, s: []const u32) u64 {
            return hashWords(s);
        }
        pub fn eql(c: Adapter, s: []const u32, k: Interned) bool {
            return std.mem.eql(u32, s, c.t.get(k.id));
        }
    };

    fn hashWords(s: []const u32) u64 {
        return std.hash.Wyhash.hash(0x5157, std.mem.sliceAsBytes(s));
    }

    fn deinit(t: *Table, gpa: Allocator) void {
        t.words.deinit(gpa);
        t.starts.deinit(gpa);
        t.map.deinit(gpa);
    }

    fn get(t: *const Table, id: u32) []const u32 {
        return t.words.items[t.starts.items[id]..t.starts.items[id + 1]];
    }

    fn word(t: *const Table, id: u32, k: usize) u32 {
        return t.words.items[t.starts.items[id] + k];
    }

    fn len(t: *const Table, id: u32) u32 {
        return t.starts.items[id + 1] - t.starts.items[id];
    }

    fn count(t: *const Table) u32 {
        return if (t.starts.items.len == 0) 0 else @intCast(t.starts.items.len - 1);
    }

    /// The id of `s`, interning it. `s` must not alias `t.words`.
    fn intern(t: *Table, gpa: Allocator, s: []const u32) Allocator.Error!u32 {
        if (t.starts.items.len == 0) try t.starts.append(gpa, 0);
        const gop = try t.map.getOrPutContextAdapted(gpa, s, Adapter{ .t = t }, SlotCtx{ .t = t });
        if (gop.found_existing) return gop.key_ptr.id;
        const id: u32 = @intCast(t.starts.items.len - 1);
        try t.words.appendSlice(gpa, s);
        try t.starts.append(gpa, @intCast(t.words.items.len));
        gop.key_ptr.* = .{ .id = id };
        return id;
    }
};

// ---------------------------------------------------------------------------
// Paths (§2.1)
// ---------------------------------------------------------------------------

/// Path words: `[parent, kind, a, b]`.
pub const PathKind = enum(u32) {
    /// ρ, the old model.
    rho,
    /// μ, the message.
    mu,
    /// πᵢ of a function: `a` the function id, `b` the parameter.
    pi,
    /// εⱼ: `a` the root's id.
    eps,
    /// ιⱼ, an index parameter, as a value: `a` the root's id.
    iota,
    /// `.f`: `a` the field's symbol.
    field,
    /// `.i`: `a` the index.
    tuple,
    /// `C#i`: `a` the constructor id, `b` the argument.
    ctor,
    /// `[κ]`: `a` the index symbol.
    index,
    /// `[*]`.
    star,
    /// A **tag read** (write-sets.md, amended 2026-10-09: tag reads): not a
    /// step into the value but the read of which constructor the parent path
    /// holds. Only reads carry it — a `case`'s scrutiny, a tag fact's path —
    /// and it is exempt from the k-limit, since it goes no deeper.
    tag,
};

pub const rho_path: u32 = 0;
pub const mu_path: u32 = 1;

// Index symbols (§2.3): words `[kind, a, b, c]`.
pub const SymKind = enum(u32) {
    /// `[*]`'s symbol: some position.
    star,
    /// `[?]`: unknown.
    unknown,
    /// An integer literal: `a`, `b` its two halves.
    lit,
    /// A handler-evaluable expression: `a` module, `b` instruction, `c` its
    /// term — the same instruction under the same substitution (A4, N5).
    expr,
};

pub const sym_star: u32 = 0;
pub const sym_unknown: u32 = 1;

// Tag and index facts (§3.2, §3.3 *guards*): gamma words are triples
// `[kind, key, value]`, sorted.
const FactKind = enum(u32) { pos, neg, ieq, ineq };

// ---------------------------------------------------------------------------
// Terms (§3.1)
// ---------------------------------------------------------------------------

pub const Tag = enum(u32) {
    /// `[tag, path]`.
    same,
    /// `[tag, kind, x, y]`: 0 int (x, y the value's halves), 1 float (x a
    /// bytes id), 2 char (x), 3 string (x a bytes id), 4 unit.
    lit,
    /// `[tag, base, rest, (field, term)*]`, fields sorted by symbol. `base`
    /// a path or `none`; `rest`: 0 every field named (a literal), 1 the
    /// base's, 2 + deps id: every field not named is `Fresh(deps)` (B2).
    rec,
    /// `[tag, ctor, parts*]`; a nullary constructor is a literal (§3.3).
    con,
    /// `[tag, parts*]`.
    tup,
    /// `[tag, base, edit, s1, s2, (index, eps, term)*]`.
    lst,
    /// `[tag, elements*]`: a list literal, its elements kept for `init`.
    lst_lit,
    /// `[tag, deps]`.
    fresh,
    /// `[tag, kind, module, x, inst, env*]` (`FunKind`).
    fun,
    /// `[tag, scrutinee, keyed, reads, (gamma, term)*]`: `reads` is what
    /// deciding the choice read (a deps id: a `case`'s pattern reads), or
    /// `none` for the scrutinee's dependencies.
    alt,
    /// `[tag, fn, args*]`: a call through a function-valued parameter.
    app,
    /// `[tag, iota, sym, deps]`: `ι == e`, a guard on an index (§3.3).
    ixeq,
};

const FunKind = enum(u32) { top, ctor, lambda, letdef };

pub const Edit = enum(u32) { none, kept, append, prepend, clear, remove_some, insert, remove_at, swap, set, permute, replaced };

const lit_int: u32 = 0;
const lit_float: u32 = 1;
const lit_char: u32 = 2;
const lit_string: u32 = 3;
const lit_unit: u32 = 4;

// ---------------------------------------------------------------------------
// Write sets (§2.4): words `[path, kind, edit, s1, s2]*` sorted by path.
// ---------------------------------------------------------------------------

pub const WKind = enum(u32) { node, value };

pub const Write = struct {
    path: u32,
    kind: WKind,
    edit: Edit = .none,
    s1: u32 = none,
    s2: u32 = none,
};

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

pub const Caps = packed struct(u8) {
    k: bool = false,
    a: bool = false,
    d: bool = false,
    i: bool = false,
    s: bool = false,
    w: bool = false,
    l: bool = false,
    _pad: u1 = 0,

    pub fn any(c: Caps) bool {
        return @as(u8, @bitCast(c)) & 0x7f != 0;
    }

    fn join(a: Caps, b: Caps) Caps {
        return @bitCast(@as(u8, @bitCast(a)) | @as(u8, @bitCast(b)));
    }
};

pub const ProgramKind = enum { sandbox, program, element, document, application };

pub const KeyStep = struct {
    /// The message path split.
    path: u32,
    /// The constructor, or `none` for the default child.
    ctor: u32,
    /// How many constructors of the split type the step stands for: 1 for
    /// a named one, the unnamed siblings for the default child.
    covers: u32 = 1,
    /// A constructor of the split type, for its module (browser-direct.md,
    /// amended 2026-10-09 for S0: `constructors`).
    type_ctor: u32 = none,
};

pub const Key = struct {
    steps: []const KeyStep,
    writes: []const Write,
    caps: Caps,
};

pub const HoleKind = enum { child, attribute, each };

/// What a hole of kind `each` is the list, or the value, of.
pub const Form = enum { none, for_keyed, for_positional, show };

/// A markup root's class (browser-direct.md §5.2, and its S0 amendment).
pub const SiteClass = enum { unique, shared, instanced, value };

/// Why a site is on the value path.
pub const ValueWhy = enum { none, list, recursive };

pub const Site = struct {
    module: u32,
    token: u32,
    class: SiteClass,
    /// Visits of the view walk: its call sites, with helpers inlined.
    calls: u32,
    why: ValueWhy,
};

/// An `Html.map` whose function is not a constructor's shape (§9.1); the
/// module is `none` where the call is not in the program's own modules.
pub const MapSite = struct { module: u32, token: u32 };

/// Why a program's messages are run-time values (browser-direct.md §11).
pub const Carriers = struct {
    commands: bool = false,
    maps: []const MapSite = &.{},
    msg_whole: bool = false,
};

pub const Hole = struct {
    module: u32,
    token: u32,
    kind: HoleKind,
    /// Anchored model reads, sorted, deduplicated.
    reads: []const u32,
    /// Bake-eligible (§9.1, as amended: O8 widened): every visit's
    /// expression is exactly the model path `literal_path`, whose `init`
    /// value is a string or an exact `Int` (`bake_text`), or a string
    /// literal; and the hole is an attribute, or stands alone under an
    /// allowlisted parent.
    bake: bool,
    /// The model path every visit read, or `none` (a string literal), when
    /// `bake`.
    literal_path: u32,
    /// The hole sits in a keyed `For`'s row whose key path is this.
    key_paths: []const u32,
    /// The index of the site holding it, into `Program.sites`.
    site: u32 = none,
    /// For an `each` hole: the form it is the list or the value of.
    form: Form = .none,
    /// For an `each` hole: the model path the value is exactly, on every
    /// visit, or `none` (a derived list).
    each_path: u32 = none,
    /// When `bake`: the text the template holds in the hole's place — the
    /// plain string `init` gives `literal_path`, or the literal itself
    /// (`browser-direct.md` §5.1, write-sets.md §9.1).
    bake_text: []const u8 = "",
};

pub const Program = struct {
    module: u32,
    /// The declaration holding the program call.
    decl: u32,
    /// Position in `Browser.programs [ … ]`, or null.
    index: ?u32,
    kind: ProgramKind,
    recognised: bool,
    /// The model type's annotation instruction (update's second parameter),
    /// in `type_module`, or `none`.
    type_module: u32,
    type_inst: u32,
    init_literals: []const u32,
    keys: []const Key,
    summaries: []const Capped,
    holes: []Hole,
    /// The view's walk reached W: every hole reads ρ, and the dump says so.
    view_capped: bool = false,
    /// The markup roots the view walk reached, in the order it met them
    /// (`Hole.site` indexes this; the dump sorts by position).
    sites: []const Site = &.{},
    carriers: Carriers = .{},
    /// The message type's constructor count, or 0 when unknown.
    msg_ctors: u32 = 0,
    /// The top-level declaration `update` names, or `none` for an `update`
    /// that is not one: where the checker's scheme of it is, which the
    /// fuzzer's message type is read from (`dump --stage=writes
    /// --msg-types`, browser-direct.md §8.3, amended 2026-10-09).
    update_module: u32 = none,
    update_decl: u32 = none,
    /// For an `update` written as a lambda (`λmsg model → …`) whose first
    /// parameter is a name: that local, module-wide, in `update_module`.
    update_param_local: u32 = none,
};

pub const Capped = struct { module: u32, decl: u32, caps: Caps };

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const Mode = enum { summary, key, view, init, closed };

const SummaryState = union(enum) {
    absent,
    active: struct { depth: u32, approx: u32 },
    done: u32,
};

const SummaryFrame = struct {
    fn_id: u32,
    low: u32,
    hit: bool = false,
    members: std.ArrayList(u32) = .empty,
};

const Ctx = struct {
    mode: Mode,
    work: u64 = 0,
    caps: Caps = .{},
    /// Key mode: the message path the next split is at, `none` while none.
    split_path: u32 = none,
    /// View mode: the key path of the keyed `For` row being walked.
    row_key: u32 = none,
    /// View mode: how many `For` rows, and list elements, the walk is in.
    in_row: u32 = 0,
    in_list: u32 = 0,
};

const SiteAcc = struct {
    module: u32,
    token: u32,
    visits: u32 = 0,
    row: bool = false,
    list: bool = false,
    /// The functions holding the root on each visit, as `active` keys: the
    /// top-level declaration's and the innermost function's.
    holders: std.ArrayList(u64) = .empty,
};

const HoleAcc = struct {
    module: u32,
    token: u32,
    kind: HoleKind,
    reads: std.ArrayList(u32) = .empty,
    alone: bool,
    /// `none` until visited; `none - 1` once two visits disagree.
    literal_path: u32 = unvisited,
    literal_ok: bool = true,
    in_row: bool = true,
    key_paths: std.ArrayList(u32) = .empty,
    site: u32 = none,
    form: Form = .none,
    /// `unvisited`, the one model path every visit's value is, or `none`.
    each_path: u32 = unvisited,
    /// The string literal's term, when the hole's expression is one.
    lit_term: u32 = none,

    const unvisited: u32 = none - 2;
    const string_literal: u32 = none;
};

gpa: Allocator,
arena_state: std.heap.ArenaAllocator,
in: Input,

paths: Table = .{},
path_len: std.ArrayList(u8) = .empty,
syms: Table = .{},
gammas: Table = .{},
deps_t: Table = .{},
terms: Table = .{},
term_depth: std.ArrayList(u8) = .empty,
term_deps: std.ArrayList(u32) = .empty,
wsets: Table = .{},
bytes: std.ArrayList(u8) = .empty,
bytes_t: Table = .{},
scratch: std.ArrayList(u32) = .empty,

/// Dense function and constructor ids: per module, the first id.
fn_base: []u32 = &.{},
ctor_base: []u32 = &.{},
/// Per constructor id: its module and `Bir.ctors` index.
ctor_module: []u32 = &.{},
summaries: []SummaryState = &.{},
summary_caps: []Caps = &.{},
summary_stack: std.ArrayList(SummaryFrame) = .empty,
top_values: []u32 = &.{},

/// Per ε/ι root id: the model path (or deps) it anchors to (§3.6).
root_base: std.ArrayList(u32) = .empty,
root_base_is_deps: std.ArrayList(bool) = .empty,
next_root: u32 = 0,

ctx: Ctx = .{ .mode = .closed },
inst_depth: u32 = 0,
active: std.ArrayList(u64) = .empty,
split_ctors: std.ArrayList(u32) = .empty,
diff_memo: std.HashMapUnmanaged(DiffKey, u32, std.hash_map.AutoContext(DiffKey), std.hash_map.default_max_load_percentage) = .empty,
subst_memo: std.HashMapUnmanaged(SubstKey, u32, std.hash_map.AutoContext(SubstKey), std.hash_map.default_max_load_percentage) = .empty,
cut_memo: std.HashMapUnmanaged(SubstKey, u32, std.hash_map.AutoContext(SubstKey), std.hash_map.default_max_load_percentage) = .empty,
next_inst_id: u32 = 0,
holes: std.ArrayList(HoleAcc) = .empty,
hole_index: std.HashMapUnmanaged(HoleKey, u32, std.hash_map.AutoContext(HoleKey), std.hash_map.default_max_load_percentage) = .empty,
/// The S0 stats (browser-direct.md §11): the markup roots the view walk
/// visits and the one it is in, the functions it is in (`active` keys) and
/// those that re-entered themselves.
sites: std.ArrayList(SiteAcc) = .empty,
site_index: std.HashMapUnmanaged(HoleKey, u32, std.hash_map.AutoContext(HoleKey), std.hash_map.default_max_load_percentage) = .empty,
cur_site: u32 = none,
holders: std.ArrayList(u64) = .empty,
recursive: std.ArrayList(u64) = .empty,
/// Message paths a key's walk let out whole (§11's `msg whole`), and the
/// `Html.map`s whose function is not a constructor's shape.
mu_escapes: std.ArrayList(u32) = .empty,
map_sites: std.ArrayList(MapSite) = .empty,
/// Per term id: the number of the last `noteMu` walk that visited it.
mu_seen: std.ArrayList(u32) = .empty,
mu_walk: u32 = 0,

/// `Maybe` and `Basics` constructors the rows build.
ctor_just: u32 = none,
ctor_nothing: u32 = none,
ctor_true: u32 = none,
ctor_false: u32 = none,

/// The program being analysed: its model type, for §3.4's full-record row.
model_type: ?TyRef = null,

const DiffKey = struct { term: u32, path: u32, gamma: u32 };
const SubstKey = struct { inst: u32, term: u32 };
const HoleKey = struct { module: u32, token: u32 };

fn arena(a: *Writes) Allocator {
    return a.arena_state.allocator();
}

pub fn init(in: Input) Allocator.Error!*Writes {
    const a = try in.gpa.create(Writes);
    a.* = .{ .gpa = in.gpa, .arena_state = .init(in.gpa), .in = in };
    const n = in.graph.count();
    a.fn_base = try a.arena().alloc(u32, n + 1);
    a.ctor_base = try a.arena().alloc(u32, n + 1);
    var fns: u32 = 0;
    var ctors: u32 = 0;
    for (0..n) |m| {
        a.fn_base[m] = fns;
        a.ctor_base[m] = ctors;
        fns += @intCast(in.birs[m].decls.len);
        ctors += @intCast(in.birs[m].ctors.len);
    }
    a.fn_base[n] = fns;
    a.ctor_base[n] = ctors;
    a.ctor_module = try a.arena().alloc(u32, ctors);
    for (0..n) |m| {
        for (a.ctor_base[m]..a.ctor_base[m + 1]) |c| a.ctor_module[c] = @intCast(m);
    }
    a.summaries = try a.arena().alloc(SummaryState, fns);
    @memset(a.summaries, .absent);
    a.summary_caps = try a.arena().alloc(Caps, fns);
    @memset(a.summary_caps, .{});
    a.top_values = try a.arena().alloc(u32, fns);
    @memset(a.top_values, none);
    // The fixed ids: ρ and μ, `[*]` and `[?]`, the empty set and Γ.
    _ = try a.mkPath(none, .rho, 0, 0);
    _ = try a.mkPath(none, .mu, 0, 0);
    _ = try a.syms.intern(a.gpa, &.{ @backingInt(SymKind.star), 0, 0, 0 });
    _ = try a.syms.intern(a.gpa, &.{ @backingInt(SymKind.unknown), 0, 0, 0 });
    _ = try a.gammas.intern(a.gpa, &.{});
    _ = try a.deps_t.intern(a.gpa, &.{});
    _ = try a.wsets.intern(a.gpa, &.{});
    a.ctor_just = a.findCtor("Maybe", "Just");
    a.ctor_nothing = a.findCtor("Maybe", "Nothing");
    a.ctor_true = a.findCtor("Basics", "True");
    a.ctor_false = a.findCtor("Basics", "False");
    return a;
}

pub fn deinit(a: *Writes) void {
    const gpa = a.gpa;
    a.paths.deinit(gpa);
    a.path_len.deinit(gpa);
    a.syms.deinit(gpa);
    a.gammas.deinit(gpa);
    a.deps_t.deinit(gpa);
    a.terms.deinit(gpa);
    a.term_depth.deinit(gpa);
    a.term_deps.deinit(gpa);
    a.wsets.deinit(gpa);
    a.bytes.deinit(gpa);
    a.bytes_t.deinit(gpa);
    a.scratch.deinit(gpa);
    for (a.summary_stack.items) |*f| f.members.deinit(gpa);
    a.summary_stack.deinit(gpa);
    a.root_base.deinit(gpa);
    a.root_base_is_deps.deinit(gpa);
    a.active.deinit(gpa);
    a.split_ctors.deinit(gpa);
    a.diff_memo.deinit(gpa);
    a.subst_memo.deinit(gpa);
    a.cut_memo.deinit(gpa);
    for (a.holes.items) |*h| {
        h.reads.deinit(gpa);
        h.key_paths.deinit(gpa);
    }
    a.holes.deinit(gpa);
    a.hole_index.deinit(gpa);
    for (a.sites.items) |*st| st.holders.deinit(gpa);
    a.sites.deinit(gpa);
    a.site_index.deinit(gpa);
    a.holders.deinit(gpa);
    a.recursive.deinit(gpa);
    a.mu_escapes.deinit(gpa);
    a.map_sites.deinit(gpa);
    a.mu_seen.deinit(gpa);
    a.arena_state.deinit();
    gpa.destroy(a);
}

// ---------------------------------------------------------------------------
// Modules, declarations, constructors
// ---------------------------------------------------------------------------

fn bir(a: *const Writes, m: u32) *const Bir {
    return a.in.birs[m];
}

fn moduleNamed(a: *const Writes, package: SourceStore.Package, name: []const u8) ?u32 {
    for (a.in.module_names, 0..) |n, m| {
        if (a.in.packages[m] == package and std.mem.eql(u8, n, name)) return @intCast(m);
    }
    return null;
}

fn findCtor(a: *const Writes, module: []const u8, name: []const u8) u32 {
    const m = a.moduleNamed(.core, module) orelse return none;
    const b = a.bir(m);
    for (b.ctors, 0..) |c, i| {
        if (std.mem.eql(u8, a.in.interner.slice(b.symbol(c.name)), name)) return a.ctor_base[m] + @as(u32, @intCast(i));
    }
    return none;
}

fn ctorId(a: *const Writes, m: u32, index: u32) u32 {
    return a.ctor_base[m] + index;
}

fn ctorOf(a: *const Writes, c: u32) Bir.Ctor {
    const m = a.ctor_module[c];
    return a.bir(m).ctors[c - a.ctor_base[m]];
}

pub fn ctorName(a: *const Writes, c: u32) []const u8 {
    const m = a.ctor_module[c];
    return a.in.interner.slice(a.bir(m).symbol(a.ctorOf(c).name));
}

pub fn ctorArity(a: *const Writes, c: u32) u32 {
    const ct = a.ctorOf(c);
    return @backingInt(ct.args_end) - @backingInt(ct.args_start);
}

/// The constructors of `c`'s type, as ids, in declaration order.
fn siblings(a: *const Writes, c: u32) struct { first: u32, count: u32 } {
    const m = a.ctor_module[c];
    const b = a.bir(m);
    const d = b.decls[a.ctorOf(c).decl.int()];
    return .{ .first = a.ctor_base[m] + d.ctors_start, .count = d.ctors_end - d.ctors_start };
}

fn isRecordAliasCtor(a: *const Writes, c: u32) bool {
    const m = a.ctor_module[c];
    return a.bir(m).decls[a.ctorOf(c).decl.int()].kind == .type_alias;
}

fn fnId(a: *const Writes, m: u32, d: u32) u32 {
    return a.fn_base[m] + d;
}

fn fnModule(a: *const Writes, id: u32) u32 {
    var lo: usize = 0;
    var hi: usize = a.in.graph.count();
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (a.fn_base[mid] <= id) lo = mid else hi = mid;
    }
    return @intCast(lo);
}

fn declName(a: *const Writes, m: u32, d: u32) []const u8 {
    const b = a.bir(m);
    return a.in.interner.slice(b.symbol(b.decls[d].name));
}

fn dispatchOf(a: *const Writes, m: u32) ?*const Dispatch {
    return if (m < a.in.dispatch.len) &a.in.dispatch[m] else null;
}

/// The declaration a resolved value reference names: `(module, decl)`.
fn valueTarget(a: *const Writes, m: u32, inst: Inst.Index) ?struct { m: u32, d: u32 } {
    const b = a.bir(m);
    const data = b.instData(inst);
    switch (b.instTag(inst)) {
        .top => return .{ .m = m, .d = data.lhs },
        .ext_value => {
            const m2 = data.lhs;
            if (m2 >= a.in.provenance.len) return null;
            const d = a.in.provenance[m2].valueDecl(data.rhs) orelse return null;
            return .{ .m = m2, .d = d.int() };
        },
        else => return null,
    }
}

fn ctorTarget(a: *const Writes, m: u32, inst: Inst.Index) ?u32 {
    const b = a.bir(m);
    const data = b.instData(inst);
    switch (b.instTag(inst)) {
        .ctor => return a.ctorId(m, data.lhs),
        .ext_ctor => {
            const m2 = data.lhs;
            if (m2 >= a.in.provenance.len) return null;
            const i = a.in.provenance[m2].ctorIndex(data.rhs) orelse return null;
            return a.ctorId(m2, i);
        },
        else => return null,
    }
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

fn mkPath(a: *Writes, parent: u32, kind: PathKind, x: u32, y: u32) Allocator.Error!u32 {
    const before = a.paths.count();
    const id = try a.paths.intern(a.gpa, &.{ parent, @backingInt(kind), x, y });
    if (id == before) {
        const l: u8 = if (parent == none) 0 else a.path_len.items[parent] + 1;
        try a.path_len.append(a.gpa, l);
    }
    return id;
}

pub fn pathParent(a: *const Writes, p: u32) u32 {
    return a.paths.word(p, 0);
}

pub fn pathKind(a: *const Writes, p: u32) PathKind {
    return @fromBackingInt(a.paths.word(p, 1));
}

pub fn pathA(a: *const Writes, p: u32) u32 {
    return a.paths.word(p, 2);
}

pub fn pathB(a: *const Writes, p: u32) u32 {
    return a.paths.word(p, 3);
}

pub fn pathLen(a: *const Writes, p: u32) u32 {
    return a.path_len.items[p];
}

pub fn rootOf(a: *const Writes, p: u32) u32 {
    var q = p;
    while (a.pathParent(q) != none) q = a.pathParent(q);
    return q;
}

/// `p` extended by one step, or null past k (§2.2).
fn extend(a: *Writes, p: u32, kind: PathKind, x: u32, y: u32) Allocator.Error!?u32 {
    if (kind != .tag and a.pathLen(p) >= k_limit) {
        if (a.ctx.mode == .key) a.ctx.caps.k = true;
        return null;
    }
    return try a.mkPath(p, kind, x, y);
}

/// The tag read at `p` (write-sets.md, amended 2026-10-09: tag reads).
fn tagRead(a: *Writes, p: u32) Allocator.Error!u32 {
    if (a.isTagRead(p)) return p;
    return a.mkPath(p, .tag, 0, 0);
}

/// Whether `p` is a tag read: the read of which constructor its parent holds.
pub fn isTagRead(a: *const Writes, p: u32) bool {
    return a.pathParent(p) != none and a.pathKind(p) == .tag;
}

fn hasStarOrUnknown(a: *const Writes, p: u32) bool {
    var q = p;
    while (a.pathParent(q) != none) : (q = a.pathParent(q)) {
        switch (a.pathKind(q)) {
            .star => return true,
            .index => if (a.pathA(q) == sym_unknown) return true,
            else => {},
        }
    }
    return false;
}

fn mintRoot(a: *Writes, kind: PathKind, base: u32, base_is_deps: bool) Allocator.Error!u32 {
    const id = a.next_root;
    a.next_root += 1;
    try a.root_base.append(a.gpa, base);
    try a.root_base_is_deps.append(a.gpa, base_is_deps);
    return a.mkPath(none, kind, id, 0);
}

/// The steps of `p` from its root, outermost first, into `out`.
fn steps(a: *const Writes, p: u32, out: *[k_limit + 1]u32) []u32 {
    var n: usize = 0;
    var q = p;
    while (a.pathParent(q) != none) : (q = a.pathParent(q)) {
        out[n] = q;
        n += 1;
    }
    std.mem.reverse(u32, out[0..n]);
    return out[0..n];
}

/// `base` followed by the steps of `p` below its root, cut at k.
fn rebase(a: *Writes, p: u32, base: u32) Allocator.Error!u32 {
    var buf: [k_limit + 1]u32 = undefined;
    var q = base;
    for (a.steps(p, &buf)) |s| {
        q = (try a.extend(q, a.pathKind(s), a.pathA(s), a.pathB(s))) orelse return q;
    }
    return q;
}

// ---------------------------------------------------------------------------
// Index symbols
// ---------------------------------------------------------------------------

pub fn symKind(a: *const Writes, s: u32) SymKind {
    return @fromBackingInt(a.syms.word(s, 0));
}

fn symWord(a: *const Writes, s: u32, k: usize) u32 {
    return a.syms.word(s, k);
}

fn mkLitSym(a: *Writes, v: i64) Allocator.Error!u32 {
    const u: u64 = @bitCast(v);
    return a.syms.intern(a.gpa, &.{ @backingInt(SymKind.lit), @truncate(u), @truncate(u >> 32), 0 });
}

pub fn symLit(a: *const Writes, s: u32) i64 {
    const u: u64 = @as(u64, a.symWord(s, 1)) | (@as(u64, a.symWord(s, 2)) << 32);
    return @bitCast(u);
}

/// The index symbol of an argument (§2.3): an integer literal, or a read of
/// the message, the old model or a summary's parameter — a `Same` of a
/// path rooted at μ, ρ or π with no `[*]` or `[?]` in it, which an R4
/// handler can evaluate before it patches. Anything computed (`i + 1`, a
/// `foreign`'s result) is `?`: coarser than §2.3, never wider (research 63).
fn mkSym(a: *Writes, m: u32, inst: Inst.Index, t: u32) Error!u32 {
    if (a.termTag(t) == .lit and a.termWord(t, 1) == lit_int) {
        const u: u64 = @as(u64, a.termWord(t, 2)) | (@as(u64, a.termWord(t, 3)) << 32);
        return a.mkLitSym(@bitCast(u));
    }
    if (a.termTag(t) != .same) return sym_unknown;
    const p = a.termWord(t, 1);
    switch (a.pathKind(a.rootOf(p))) {
        .rho, .mu, .pi => {},
        else => return sym_unknown,
    }
    if (!a.factPath(p)) return sym_unknown;
    return a.syms.intern(a.gpa, &.{ @backingInt(SymKind.expr), m, inst.int(), t });
}

/// Whether two index symbols may stand for one position (§2.1's
/// may-coincide): unless both are literals and differ.
fn symMayCoincide(a: *const Writes, s1: u32, s2: u32) bool {
    if (s1 == s2) return true;
    if (a.symKind(s1) == .lit and a.symKind(s2) == .lit) return a.symLit(s1) == a.symLit(s2);
    return true;
}

// ---------------------------------------------------------------------------
// Dependency sets
// ---------------------------------------------------------------------------

fn mkDeps(a: *Writes, items: []u32) Allocator.Error!u32 {
    std.mem.sort(u32, items, {}, std.sort.asc(u32));
    var n: usize = 0;
    for (items) |p| {
        if (n == 0 or items[n - 1] != p) {
            items[n] = p;
            n += 1;
        }
    }
    return a.deps_t.intern(a.gpa, items[0..n]);
}

fn depsUnion(a: *Writes, x: u32, y: u32) Allocator.Error!u32 {
    if (x == y or a.deps_t.len(y) == 0) return x;
    if (a.deps_t.len(x) == 0) return y;
    const mark = a.scratch.items.len;
    defer a.scratch.shrinkRetainingCapacity(mark);
    try a.scratch.appendSlice(a.gpa, a.deps_t.get(x));
    try a.scratch.appendSlice(a.gpa, a.deps_t.get(y));
    return a.mkDeps(a.scratch.items[mark..]);
}

fn depsOfPath(a: *Writes, p: u32) Allocator.Error!u32 {
    var one = [_]u32{p};
    return a.mkDeps(&one);
}

// ---------------------------------------------------------------------------
// Γ: tag facts and index facts
// ---------------------------------------------------------------------------

const Fact = struct { kind: FactKind, key: u32, val: u32 };

fn factLess(_: void, x: Fact, y: Fact) bool {
    const gx: u32 = if (x.kind == .pos or x.kind == .neg) 0 else 1;
    const gy: u32 = if (y.kind == .pos or y.kind == .neg) 0 else 1;
    if (gx != gy) return gx < gy;
    if (x.key != y.key) return x.key < y.key;
    if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
    return x.val < y.val;
}

fn gammaFacts(a: *const Writes, g: u32) []const u32 {
    return a.gammas.get(g);
}

fn factAt(words: []const u32, i: usize) Fact {
    return .{ .kind = @fromBackingInt(words[3 * i]), .key = words[3 * i + 1], .val = words[3 * i + 2] };
}

fn gammaLen(a: *const Writes, g: u32) usize {
    return a.gammas.len(g) / 3;
}

fn gammaFact(a: *const Writes, g: u32, i: usize) Fact {
    const s = a.gammas.starts.items[g] + 3 * i;
    const w = a.gammas.words.items;
    return .{ .kind = @fromBackingInt(w[s]), .key = w[s + 1], .val = w[s + 2] };
}

/// `g ∪ facts`, or null on a contradiction.
fn gammaAdd(a: *Writes, g: u32, facts: []const Fact) Allocator.Error!?u32 {
    if (facts.len == 0) return g;
    var list: std.ArrayList(Fact) = .empty;
    defer list.deinit(a.gpa);
    for (0..a.gammaLen(g)) |i| try list.append(a.gpa, a.gammaFact(g, i));
    for (facts) |f| {
        if (!try a.addFact(&list, f)) return null;
    }
    std.mem.sort(Fact, list.items, {}, factLess);
    const mark = a.scratch.items.len;
    defer a.scratch.shrinkRetainingCapacity(mark);
    for (list.items) |f| try a.scratch.appendSlice(a.gpa, &.{ @backingInt(f.kind), f.key, f.val });
    return try a.gammas.intern(a.gpa, a.scratch.items[mark..]);
}

fn gammaJoin(a: *Writes, g: u32, h: u32) Allocator.Error!?u32 {
    if (h == 0) return g;
    if (g == 0) return h;
    var facts: std.ArrayList(Fact) = .empty;
    defer facts.deinit(a.gpa);
    for (0..a.gammaLen(h)) |i| try facts.append(a.gpa, a.gammaFact(h, i));
    return a.gammaAdd(g, facts.items);
}

/// Add `f` to `list`; false on a contradiction.
fn addFact(a: *Writes, list: *std.ArrayList(Fact), f: Fact) Allocator.Error!bool {
    switch (f.kind) {
        .pos => {
            var i: usize = 0;
            while (i < list.items.len) {
                const e = list.items[i];
                if (e.key == f.key and (e.kind == .pos or e.kind == .neg)) {
                    if (e.kind == .pos) {
                        if (e.val != f.val) return false;
                        return true;
                    }
                    if (e.val == f.val) return false;
                    _ = list.swapRemove(i);
                    continue;
                }
                i += 1;
            }
            try list.append(a.gpa, f);
        },
        .neg => {
            var negs: u32 = 0;
            for (list.items) |e| {
                if (e.key != f.key) continue;
                if (e.kind == .pos) return e.val != f.val;
                if (e.kind == .neg) {
                    if (e.val == f.val) return true;
                    negs += 1;
                }
            }
            try list.append(a.gpa, f);
            if (negs + 1 >= a.siblings(f.val).count) return false;
        },
        .ieq => {
            for (list.items) |e| {
                if (e.key != f.key) continue;
                if (e.kind == .ineq and e.val == f.val) return false;
                if (e.kind == .ieq) {
                    if (e.val == f.val) return true;
                    if (a.symKind(e.val) == .lit and a.symKind(f.val) == .lit) return false;
                }
            }
            try list.append(a.gpa, f);
        },
        .ineq => {
            for (list.items) |e| {
                if (e.key != f.key) continue;
                if (e.kind == .ieq and e.val == f.val) return false;
                if (e.kind == .ineq and e.val == f.val) return true;
            }
            try list.append(a.gpa, f);
        },
    }
    return true;
}

/// What Γ says of the tag at `p`: the constructor it must be, if decided
/// (a positive fact, or negation leaving one, §3.2), and whether `c` is
/// excluded.
fn tagKnown(a: *const Writes, g: u32, p: u32) ?u32 {
    var neg_any: u32 = none;
    var negs: u32 = 0;
    for (0..a.gammaLen(g)) |i| {
        const f = a.gammaFact(g, i);
        if (f.key != p) continue;
        if (f.kind == .pos) return f.val;
        if (f.kind == .neg) {
            neg_any = f.val;
            negs += 1;
        }
    }
    if (neg_any == none) return null;
    const sib = a.siblings(neg_any);
    if (negs + 1 != sib.count) return null;
    var c = sib.first;
    while (c < sib.first + sib.count) : (c += 1) {
        if (!a.gammaExcludes(g, p, c)) return c;
    }
    return null;
}

fn gammaExcludes(a: *const Writes, g: u32, p: u32, c: u32) bool {
    for (0..a.gammaLen(g)) |i| {
        const f = a.gammaFact(g, i);
        if (f.key != p) continue;
        if (f.kind == .neg and f.val == c) return true;
        if (f.kind == .pos and f.val != c) return true;
    }
    return false;
}

/// `Γ ⊢ tag(p) = c` (§3.4): a fact, the single-constructor rule, or
/// negation leaving `c`.
fn knowsTag(a: *const Writes, g: u32, p: u32, c: u32) bool {
    if (a.siblings(c).count == 1) return true;
    if (!a.factPath(p)) return false;
    if (a.tagKnown(g, p)) |k| return k == c;
    return false;
}

/// Whether a tag fact may be kept at `p`: not when `p` holds a `[*]` or
/// `[?]` step, which stands for SOME element and is equal to nothing,
/// itself included (§2.3) — a fact about one such element is no fact about
/// another that interns to the same path.
fn factPath(a: *const Writes, p: u32) bool {
    return !a.hasStarOrUnknown(p);
}

fn contradicts(a: *const Writes, g: u32, p: u32, c: u32) bool {
    if (!a.factPath(p)) return false;
    if (a.gammaExcludes(g, p, c)) return true;
    if (a.tagKnown(g, p)) |k| return k != c;
    return false;
}

// ---------------------------------------------------------------------------
// Terms
// ---------------------------------------------------------------------------

pub fn termTag(a: *const Writes, t: u32) Tag {
    return @fromBackingInt(a.terms.word(t, 0));
}

pub fn termWord(a: *const Writes, t: u32, k: usize) u32 {
    return a.terms.word(t, k);
}

pub fn termLen(a: *const Writes, t: u32) u32 {
    return a.terms.len(t);
}

fn termDepth(a: *const Writes, t: u32) u8 {
    return a.term_depth.items[t];
}

/// Intern a term built in `scratch[mark..]`, with its height. Nothing is cut
/// here: `capSize` cuts a finished term top-down below level k (§3.1, *Depth*,
/// as amended), and the height only tells it whether to look.
fn finish(a: *Writes, mark: usize, depth: u32) Error!u32 {
    defer a.scratch.shrinkRetainingCapacity(mark);
    const before = a.terms.count();
    const id = try a.terms.intern(a.gpa, a.scratch.items[mark..]);
    if (id == before) {
        try a.term_depth.append(a.gpa, @intCast(@min(depth, 255)));
        try a.term_deps.append(a.gpa, none);
    }
    return id;
}

fn mkSame(a: *Writes, p: u32) Error!u32 {
    const mark = a.scratch.items.len;
    try a.scratch.appendSlice(a.gpa, &.{ @backingInt(Tag.same), p });
    return a.finish(mark, 0);
}

/// `Same(p.step)`, or `Fresh({p})` past k (B4).
fn mkSameStep(a: *Writes, p: u32, kind: PathKind, x: u32, y: u32) Error!u32 {
    if (try a.extend(p, kind, x, y)) |q| return a.mkSame(q);
    return a.mkFresh(try a.depsOfPath(p));
}

fn mkFresh(a: *Writes, d: u32) Error!u32 {
    const mark = a.scratch.items.len;
    try a.scratch.appendSlice(a.gpa, &.{ @backingInt(Tag.fresh), d });
    return a.finish(mark, 0);
}

fn freshEmpty(a: *Writes) Error!u32 {
    return a.mkFresh(0);
}

fn mkLit(a: *Writes, kind: u32, x: u32, y: u32) Error!u32 {
    const mark = a.scratch.items.len;
    try a.scratch.appendSlice(a.gpa, &.{ @backingInt(Tag.lit), kind, x, y });
    return a.finish(mark, 0);
}

fn internBytes(a: *Writes, s: []const u8) Allocator.Error!u32 {
    // Bytes as words: length, then the bytes four to a word.
    const mark = a.scratch.items.len;
    defer a.scratch.shrinkRetainingCapacity(mark);
    try a.scratch.append(a.gpa, @intCast(s.len));
    var i: usize = 0;
    while (i < s.len) : (i += 4) {
        var w: u32 = 0;
        for (0..4) |j| {
            if (i + j < s.len) w |= @as(u32, s[i + j]) << @intCast(8 * j);
        }
        try a.scratch.append(a.gpa, w);
    }
    return a.bytes_t.intern(a.gpa, a.scratch.items[mark..]);
}

pub fn bytesOf(a: *const Writes, id: u32, buf: []u8) []const u8 {
    const words = a.bytes_t.get(id);
    const n = @min(words[0], buf.len);
    for (0..n) |i| buf[i] = @truncate(words[1 + i / 4] >> @intCast(8 * (i % 4)));
    return buf[0..n];
}

fn mkCon(a: *Writes, c: u32, parts: []const u32) Error!u32 {
    if (a.isRecordAliasCtor(c)) return a.recordAliasValue(c, parts);
    const mark = a.scratch.items.len;
    try a.scratch.appendSlice(a.gpa, &.{ @backingInt(Tag.con), c });
    var depth: u32 = 0;
    for (parts) |p| depth = @max(depth, a.termDepth(p));
    try a.scratch.appendSlice(a.gpa, parts);
    return a.finish(mark, if (parts.len == 0) 0 else depth + 1);
}

/// A record alias's constructor applied: the record, its fields in
/// declaration order.
fn recordAliasValue(a: *Writes, c: u32, parts: []const u32) Error!u32 {
    const m = a.ctor_module[c];
    const b = a.bir(m);
    const d = b.decls[a.ctorOf(c).decl.int()];
    const body = d.annotation.unwrap() orelse return a.freshOfAll(parts);
    if (b.instTag(body) != .type_record) return a.freshOfAll(parts);
    const fields = b.extraSlice(Bir.inlineRange(b.instData(body)), Bir.Field);
    if (fields.len != parts.len) return a.freshOfAll(parts);
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(a.gpa);
    for (fields, parts) |f, p| try pairs.append(a.gpa, .{ @backingInt(b.symbol(f.name)), p });
    return a.mkRec(none, 0, pairs.items);
}

fn freshOfAll(a: *Writes, parts: []const u32) Error!u32 {
    var d: u32 = 0;
    for (parts) |p| d = try a.depsUnion(d, try a.deps(p));
    return a.mkFresh(d);
}

fn mkTup(a: *Writes, parts: []const u32) Error!u32 {
    const mark = a.scratch.items.len;
    try a.scratch.append(a.gpa, @backingInt(Tag.tup));
    var depth: u32 = 0;
    for (parts) |p| depth = @max(depth, a.termDepth(p));
    try a.scratch.appendSlice(a.gpa, parts);
    return a.finish(mark, depth + 1);
}

/// `Rec(base, fields)` with `rest` as `Tag.rec` documents; `pairs` are
/// `(symbol, term)` and are sorted here.
fn mkRec(a: *Writes, base: u32, rest: u32, pairs: [][2]u32) Error!u32 {
    std.mem.sort([2]u32, pairs, {}, struct {
        fn less(_: void, x: [2]u32, y: [2]u32) bool {
            return x[0] < y[0];
        }
    }.less);
    const mark = a.scratch.items.len;
    try a.scratch.appendSlice(a.gpa, &.{ @backingInt(Tag.rec), base, rest });
    var depth: u32 = 0;
    for (pairs) |p| {
        try a.scratch.appendSlice(a.gpa, &p);
        depth = @max(depth, a.termDepth(p[1]));
    }
    return a.finish(mark, depth + 1);
}

const Elem = struct { index: u32, eps: u32, term: u32 };

fn mkLst(a: *Writes, base: u32, edit: Edit, s1: u32, s2: u32, elems: []const Elem) Error!u32 {
    const mark = a.scratch.items.len;
    try a.scratch.appendSlice(a.gpa, &.{ @backingInt(Tag.lst), base, @backingInt(edit), s1, s2 });
    var depth: u32 = 0;
    for (elems) |e| {
        try a.scratch.appendSlice(a.gpa, &.{ e.index, e.eps, e.term });
        depth = @max(depth, a.termDepth(e.term));
    }
    return a.finish(mark, depth + 1);
}

fn lstElems(a: *const Writes, t: u32) u32 {
    return (a.termLen(t) - 5) / 3;
}

fn lstElem(a: *const Writes, t: u32, i: u32) Elem {
    return .{ .index = a.termWord(t, 5 + 3 * i), .eps = a.termWord(t, 6 + 3 * i), .term = a.termWord(t, 7 + 3 * i) };
}

fn mkLstLit(a: *Writes, elems: []const u32) Error!u32 {
    const mark = a.scratch.items.len;
    try a.scratch.append(a.gpa, @backingInt(Tag.lst_lit));
    var depth: u32 = 0;
    for (elems) |p| depth = @max(depth, a.termDepth(p));
    try a.scratch.appendSlice(a.gpa, elems);
    return a.finish(mark, depth + 1);
}

fn mkFun(a: *Writes, kind: FunKind, m: u32, x: u32, inst: u32, env: []const u32) Error!u32 {
    const mark = a.scratch.items.len;
    try a.scratch.appendSlice(a.gpa, &.{ @backingInt(Tag.fun), @backingInt(kind), m, x, inst });
    try a.scratch.appendSlice(a.gpa, env);
    return a.finish(mark, 0);
}

fn mkApp(a: *Writes, f: u32, args: []const u32) Error!u32 {
    const mark = a.scratch.items.len;
    try a.scratch.appendSlice(a.gpa, &.{ @backingInt(Tag.app), f });
    try a.scratch.appendSlice(a.gpa, args);
    return a.finish(mark, 0);
}

fn mkIxeq(a: *Writes, iota: u32, sym: u32, d: u32) Error!u32 {
    const mark = a.scratch.items.len;
    try a.scratch.appendSlice(a.gpa, &.{ @backingInt(Tag.ixeq), iota, sym, d });
    return a.finish(mark, 0);
}

const AltItem = struct { gamma: u32, term: u32 };

/// An `Alt`. A plain one wider than A is `Fresh` of everything it reads
/// (§3.1); a keyed one is bounded by its type. Keyed `Alt`s do not count
/// toward the depth (write-sets.md, amended 2026-10-08 by research 63).
fn mkAlt(a: *Writes, scrut: u32, keyed: bool, reads_in: u32, items_in: []const AltItem) Error!u32 {
    var reads = reads_in;
    // Normal form: a plain alternative that is itself a plain `Alt` on the
    // same choice (or on none) is its alternatives, under both sets of
    // facts; ⊥ (`Alt([])`) joins as nothing; equal alternatives are one.
    // This is the join a fixpoint's rounds climb (§4.3), so a recursion
    // that adds nothing new is seen to be stable.
    var flat: std.ArrayList(AltItem) = .empty;
    defer flat.deinit(a.gpa);
    for (items_in) |it| {
        const t = it.term;
        if (keyed) {
            try flat.append(a.gpa, it);
            continue;
        }
        if (a.termTag(t) == .alt and a.termWord(t, 2) == 0 and (a.termWord(t, 1) == none or a.termWord(t, 1) == scrut)) {
            const inner_reads = a.termWord(t, 3);
            if (inner_reads != reads) reads = try a.depsUnion(try a.altReadsOf(scrut, reads), try a.altReadsOf(a.termWord(t, 1), inner_reads));
            for (0..a.altLen(t)) |i| {
                const inner = a.altItem(t, @intCast(i));
                const g = (try a.gammaJoin(it.gamma, inner.gamma)) orelse continue;
                try appendAlt(a, &flat, .{ .gamma = g, .term = inner.term });
            }
            continue;
        }
        try appendAlt(a, &flat, it);
    }
    const items = flat.items;
    if (scrut == none and (reads == none or reads == 0) and items.len == 1 and items[0].gamma == 0) return items[0].term;
    if (!keyed and items.len > cap_alt) {
        a.ctx.caps.a = true;
        var d: u32 = try a.altReadsOf(scrut, reads);
        for (items) |it| {
            d = try a.depsUnion(d, try a.deps(it.term));
            d = try a.depsUnion(d, try a.gammaDeps(it.gamma));
        }
        return a.mkFresh(d);
    }
    const mark = a.scratch.items.len;
    try a.scratch.appendSlice(a.gpa, &.{ @backingInt(Tag.alt), scrut, @intFromBool(keyed), reads });
    var depth: u32 = 0;
    for (items) |it| {
        try a.scratch.appendSlice(a.gpa, &.{ it.gamma, it.term });
        depth = @max(depth, a.termDepth(it.term));
    }
    return a.finish(mark, if (keyed) depth else depth + 1);
}

fn appendAlt(a: *Writes, list: *std.ArrayList(AltItem), it: AltItem) Allocator.Error!void {
    for (list.items) |e| if (e.gamma == it.gamma and e.term == it.term) return;
    try list.append(a.gpa, it);
}

fn altLen(a: *const Writes, t: u32) u32 {
    return (a.termLen(t) - 4) / 2;
}

fn altItem(a: *const Writes, t: u32, i: u32) AltItem {
    return .{ .gamma = a.termWord(t, 4 + 2 * i), .term = a.termWord(t, 5 + 2 * i) };
}

/// What deciding an `Alt`'s choice read: its own `reads`, or, when it has
/// none, its scrutinee's dependencies (§3.6, A6).
fn altReadsOf(a: *Writes, scrut: u32, reads: u32) Allocator.Error!u32 {
    if (reads != none) return reads;
    return if (scrut == none) 0 else a.deps(scrut);
}

fn bottom(a: *Writes) Error!u32 {
    return a.mkAlt(none, false, none, &.{});
}

// ---- deps (§3.6, *Dependencies*) -------------------------------------------

fn gammaDeps(a: *Writes, g: u32) Allocator.Error!u32 {
    const mark = a.scratch.items.len;
    defer a.scratch.shrinkRetainingCapacity(mark);
    for (0..a.gammaLen(g)) |i| {
        const f = a.gammaFact(g, i);
        // A tag fact's path is read for its tag only (amended 2026-10-09).
        if (f.kind == .pos or f.kind == .neg) try a.scratch.append(a.gpa, try a.tagRead(f.key));
    }
    return a.mkDeps(a.scratch.items[mark..]);
}

fn deps(a: *Writes, t: u32) Allocator.Error!u32 {
    if (a.term_deps.items[t] != none) return a.term_deps.items[t];
    var d: u32 = 0;
    switch (a.termTag(t)) {
        .same => d = try a.depsOfPath(a.termWord(t, 1)),
        .lit => {},
        .fresh => d = a.termWord(t, 1),
        .ixeq => d = a.termWord(t, 3),
        .rec => {
            const base = a.termWord(t, 1);
            const rest = a.termWord(t, 2);
            if (base != none) d = try a.depsOfPath(base);
            if (rest >= 2) d = try a.depsUnion(d, rest - 2);
            var i: u32 = 3;
            while (i < a.termLen(t)) : (i += 2) d = try a.depsUnion(d, try a.deps(a.termWord(t, i + 1)));
        },
        .con, .app => {
            var i: u32 = if (a.termTag(t) == .con) 2 else 1;
            while (i < a.termLen(t)) : (i += 1) d = try a.depsUnion(d, try a.deps(a.termWord(t, i)));
        },
        .tup, .lst_lit => {
            var i: u32 = 1;
            while (i < a.termLen(t)) : (i += 1) d = try a.depsUnion(d, try a.deps(a.termWord(t, i)));
        },
        .lst => {
            const base = a.termWord(t, 1);
            if (base != none) d = try a.depsOfPath(base);
            for (0..a.lstElems(t)) |i| d = try a.depsUnion(d, try a.deps(a.lstElem(t, @intCast(i)).term));
        },
        .fun => {
            var i: u32 = 5;
            while (i < a.termLen(t)) : (i += 1) {
                const e = a.termWord(t, i);
                if (e != none) d = try a.depsUnion(d, try a.deps(e));
            }
        },
        .alt => {
            d = try a.altReadsOf(a.termWord(t, 1), a.termWord(t, 3));
            for (0..a.altLen(t)) |i| {
                const it = a.altItem(t, @intCast(i));
                d = try a.depsUnion(d, try a.gammaDeps(it.gamma));
                d = try a.depsUnion(d, try a.deps(it.term));
            }
        },
    }
    a.term_deps.items[t] = d;
    return d;
}

/// The DAG node count of `t`, stopping past `limit`.
fn termSize(a: *Writes, t: u32, limit: u32) Allocator.Error!u32 {
    var seen: std.AutoHashMapUnmanaged(SubstKey, void) = .empty;
    defer seen.deinit(a.gpa);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(a.gpa);
    try stack.append(a.gpa, t);
    var n: u32 = 0;
    while (stack.pop()) |x| {
        const gop = try seen.getOrPut(a.gpa, .{ .inst = 0, .term = x });
        if (gop.found_existing) continue;
        n += 1;
        if (n > limit) return n;
        switch (a.termTag(x)) {
            .rec => {
                var i: u32 = 3;
                while (i < a.termLen(x)) : (i += 2) try stack.append(a.gpa, a.termWord(x, i + 1));
            },
            .con, .app => {
                var i: u32 = if (a.termTag(x) == .con) 2 else 1;
                while (i < a.termLen(x)) : (i += 1) try stack.append(a.gpa, a.termWord(x, i));
            },
            .tup, .lst_lit => {
                var i: u32 = 1;
                while (i < a.termLen(x)) : (i += 1) try stack.append(a.gpa, a.termWord(x, i));
            },
            .lst => for (0..a.lstElems(x)) |i| try stack.append(a.gpa, a.lstElem(x, @intCast(i)).term),
            .fun => {
                var i: u32 = 5;
                while (i < a.termLen(x)) : (i += 1) if (a.termWord(x, i) != none) try stack.append(a.gpa, a.termWord(x, i));
            },
            .alt => {
                if (a.termWord(x, 1) != none) try stack.append(a.gpa, a.termWord(x, 1));
                for (0..a.altLen(x)) |i| try stack.append(a.gpa, a.altItem(x, @intCast(i)).term);
            },
            else => {},
        }
    }
    return n;
}

/// The S cap and the depth cut (§3.1, *Depth*; §6.1): the part of a term
/// nested more than k structures deep (a plain `Alt` a level, a keyed one
/// not) is `Fresh` of what it reads, and a term of more than S nodes is
/// `Fresh`. Applied to every finished term — a summary, a key's result, a
/// call's value — top-down, so the cut is below the k-th level and never at
/// the root.
fn capSize(a: *Writes, t0: u32) Error!u32 {
    const t = if (a.termDepth(t0) > k_limit) try a.cut(t0, 0) else t0;
    if (try a.termSize(t, cap_size) > cap_size) {
        a.ctx.caps.s = true;
        return a.mkFresh(try a.deps(t));
    }
    return t;
}

fn cut(a: *Writes, t: u32, level: u32) Error!u32 {
    if (level + a.termDepth(t) <= k_limit) return t;
    if (a.cut_memo.get(.{ .inst = level, .term = t })) |r| return r;
    const r = try a.cutNode(t, level);
    try a.cut_memo.put(a.gpa, .{ .inst = level, .term = t }, r);
    return r;
}

fn cutNode(a: *Writes, t: u32, level: u32) Error!u32 {
    const tag = a.termTag(t);
    const keyed = tag == .alt and a.termWord(t, 2) == 1;
    if (level >= k_limit and !keyed) {
        if (a.ctx.mode == .key) a.ctx.caps.k = true;
        return a.mkFresh(try a.deps(t));
    }
    const next = if (keyed) level else level + 1;
    switch (tag) {
        .con => {
            const n = a.termLen(t) - 2;
            const parts = try a.arena().alloc(u32, n);
            for (parts, 0..) |*p, i| p.* = try a.cut(a.termWord(t, 2 + i), next);
            return a.mkCon(a.termWord(t, 1), parts);
        },
        .tup, .lst_lit => {
            const n = a.termLen(t) - 1;
            const parts = try a.arena().alloc(u32, n);
            for (parts, 0..) |*p, i| p.* = try a.cut(a.termWord(t, 1 + i), next);
            return if (tag == .tup) a.mkTup(parts) else a.mkLstLit(parts);
        },
        .rec => {
            const n = (a.termLen(t) - 3) / 2;
            const pairs = try a.arena().alloc([2]u32, n);
            for (pairs, 0..) |*p, i| p.* = .{ a.termWord(t, 3 + 2 * i), try a.cut(a.termWord(t, 4 + 2 * i), next) };
            return a.mkRec(a.termWord(t, 1), a.termWord(t, 2), pairs);
        },
        .lst => {
            const n = a.lstElems(t);
            const elems = try a.arena().alloc(Elem, n);
            for (elems, 0..) |*e, i| {
                e.* = a.lstElem(t, @intCast(i));
                e.term = try a.cut(e.term, next);
            }
            return a.mkLst(a.termWord(t, 1), @fromBackingInt(a.termWord(t, 2)), a.termWord(t, 3), a.termWord(t, 4), elems);
        },
        .alt => {
            const n = a.altLen(t);
            const items = try a.arena().alloc(AltItem, n);
            for (items, 0..) |*it, i| {
                it.* = a.altItem(t, @intCast(i));
                it.term = try a.cut(it.term, next);
            }
            return a.mkAlt(a.termWord(t, 1), keyed, a.termWord(t, 3), items);
        },
        else => return t,
    }
}

// ---------------------------------------------------------------------------
// Work (W)
// ---------------------------------------------------------------------------

fn tick(a: *Writes) error{WorkCap}!void {
    a.ctx.work += 1;
    if (a.ctx.work > a.in.work_cap) return error.WorkCap;
}

// ---------------------------------------------------------------------------
// proj (§3.3, *Field access*)
// ---------------------------------------------------------------------------

fn proj(a: *Writes, t: u32, kind: PathKind, x: u32, y: u32) Error!u32 {
    switch (a.termTag(t)) {
        .same => return a.mkSameStep(a.termWord(t, 1), kind, x, y),
        .rec => if (kind == .field) {
            var i: u32 = 3;
            while (i < a.termLen(t)) : (i += 2) {
                if (a.termWord(t, i) == x) return a.termWord(t, i + 1);
            }
            const base = a.termWord(t, 1);
            if (base != none) return a.mkSameStep(base, .field, x, 0);
            const rest = a.termWord(t, 2);
            if (rest >= 2) return a.mkFresh(rest - 2);
        },
        .tup => if (kind == .tuple and x + 1 < a.termLen(t)) return a.termWord(t, 1 + x),
        .con => if (kind == .ctor and a.termWord(t, 1) == x and y + 2 < a.termLen(t)) return a.termWord(t, 2 + y),
        .lst_lit => if (kind == .index and a.symKind(x) == .lit) {
            const i = a.symLit(x);
            if (i >= 0 and i + 1 < a.termLen(t)) return a.termWord(t, @intCast(1 + i));
        },
        .fresh => return t,
        .alt => {
            var items: std.ArrayList(AltItem) = .empty;
            defer items.deinit(a.gpa);
            const n = a.altLen(t);
            for (0..n) |i| {
                const it = a.altItem(t, @intCast(i));
                try items.append(a.gpa, .{ .gamma = it.gamma, .term = try a.proj(it.term, kind, x, y) });
            }
            return a.mkAlt(a.termWord(t, 1), a.termWord(t, 2) == 1, a.termWord(t, 3), items.items);
        },
        else => {},
    }
    return a.mkFresh(try a.deps(t));
}

fn projField(a: *Writes, t: u32, field: Symbol) Error!u32 {
    return a.proj(t, .field, @backingInt(field), 0);
}

// ---------------------------------------------------------------------------
// Frames
// ---------------------------------------------------------------------------

const Frame = struct {
    m: u32,
    decl: u32,
    env: []u32,
    /// What a local the walk has not bound reads: the function's roots, or ρ.
    unknown: u32,
    /// `?` in this body: what an early return may carry.
    try_deps: u32 = 0,
};

fn newFrame(a: *Writes, m: u32, d: u32, unknown: u32) Allocator.Error!Frame {
    const decl = a.bir(m).decls[d];
    const env = try a.arena().alloc(u32, decl.locals_end - decl.locals_start);
    @memset(env, none);
    return .{ .m = m, .decl = d, .env = env, .unknown = unknown };
}

fn unknownLocal(a: *Writes, f: *Frame) Error!u32 {
    return a.mkFresh(f.unknown);
}

// ---------------------------------------------------------------------------
// Patterns (§3.2)
// ---------------------------------------------------------------------------

/// Bind the variables `pat` holds to the parts of `v`, by projection.
fn bind(a: *Writes, f: *Frame, pat: Inst.Index, v: u32) Error!void {
    const b = a.bir(f.m);
    const data = b.instData(pat);
    switch (b.instTag(pat)) {
        .pat_var => f.env[data.lhs] = v,
        .pat_as => {
            f.env[data.rhs] = v;
            try a.bind(f, @fromBackingInt(data.lhs), v);
        },
        .pat_ctor => {
            const c = a.ctorTarget(f.m, @fromBackingInt(data.lhs));
            const args = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index);
            for (args, 0..) |arg, j| {
                const part = if (c) |cc| try a.proj(v, .ctor, cc, @intCast(j)) else try a.mkFresh(try a.deps(v));
                try a.bind(f, arg, part);
            }
        },
        .pat_tuple => {
            const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
            for (items, 0..) |item, j| try a.bind(f, item, try a.proj(v, .tuple, @intCast(j), 0));
        },
        .pat_record => {
            const locals = b.extraSlice(Bir.inlineRange(data), u32);
            const decl = b.decls[f.decl];
            for (locals) |l| {
                const name = b.locals[decl.locals_start + l].name;
                const part = if (name.unwrap()) |s| try a.projField(v, b.symbols[s]) else try a.mkFresh(try a.deps(v));
                f.env[l] = part;
            }
        },
        .pat_list => {
            const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
            const base: ?u32 = if (a.termTag(v) == .same) a.termWord(v, 1) else null;
            var after_spread = false;
            for (items, 0..) |item, j| {
                if (b.instTag(item) == .pat_spread) {
                    after_spread = true;
                    const part = if (base) |p| try a.mkLst(p, .remove_some, none, none, &.{}) else try a.mkFresh(try a.deps(v));
                    try a.bind(f, @fromBackingInt(b.instData(item).lhs), part);
                    continue;
                }
                const part = if (base) |p| blk: {
                    const s = if (after_spread) sym_unknown else try a.mkLitSym(@intCast(j));
                    break :blk try a.mkSameStep(p, .index, s, 0);
                } else try a.mkFresh(try a.deps(v));
                try a.bind(f, item, part);
            }
        },
        else => {},
    }
}

const Match = struct {
    ok: bool = true,
    facts: std.ArrayList(Fact) = .empty,
};

/// The positive tag facts of `pat` against `v` under `g`, nested ones
/// included, or `ok = false` when the pattern contradicts a known shape or
/// a fact that holds (§3.2's one rule for skipping an arm).
fn matchFacts(a: *Writes, f: *Frame, pat: Inst.Index, v: u32, g: u32, out: *Match) Error!void {
    if (!out.ok) return;
    const b = a.bir(f.m);
    const data = b.instData(pat);
    switch (b.instTag(pat)) {
        .pat_as => try a.matchFacts(f, @fromBackingInt(data.lhs), v, g, out),
        .pat_ctor => {
            const c = a.ctorTarget(f.m, @fromBackingInt(data.lhs)) orelse return;
            const args = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index);
            switch (a.termTag(v)) {
                .same => {
                    const p = a.termWord(v, 1);
                    if (a.contradicts(g, p, c)) {
                        out.ok = false;
                        return;
                    }
                    if (a.siblings(c).count > 1 and a.factPath(p)) try out.facts.append(a.gpa, .{ .kind = .pos, .key = p, .val = c });
                },
                .con => if (a.termWord(v, 1) != c) {
                    out.ok = false;
                    return;
                },
                else => return,
            }
            for (args, 0..) |arg, j| try a.matchFacts(f, arg, try a.proj(v, .ctor, c, @intCast(j)), g, out);
        },
        .pat_tuple => {
            const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
            if (a.termTag(v) != .same and a.termTag(v) != .tup) return;
            for (items, 0..) |item, j| try a.matchFacts(f, item, try a.proj(v, .tuple, @intCast(j), 0), g, out);
        },
        .pat_int => if (a.termTag(v) == .lit and a.termWord(v, 1) == lit_int) {
            if (parseInt(b.bytes(pat))) |n| {
                const u: u64 = @bitCast(n);
                if (a.termWord(v, 2) != @as(u32, @truncate(u)) or a.termWord(v, 3) != @as(u32, @truncate(u >> 32))) out.ok = false;
            }
        },
        .pat_string => if (a.termTag(v) == .lit and a.termWord(v, 1) == lit_string) {
            if (a.termWord(v, 2) != try a.internBytes(b.bytes(pat))) out.ok = false;
        },
        else => {},
    }
}

fn irrefutable(a: *Writes, m: u32, pat: Inst.Index) bool {
    const b = a.bir(m);
    const data = b.instData(pat);
    return switch (b.instTag(pat)) {
        .pat_wild, .pat_var, .pat_unit, .pat_record => true,
        .pat_as => a.irrefutable(m, @fromBackingInt(data.lhs)),
        .pat_tuple => {
            for (b.extraSlice(Bir.inlineRange(data), Inst.Index)) |i| if (!a.irrefutable(m, i)) return false;
            return true;
        },
        .pat_ctor => {
            const c = a.ctorTarget(m, @fromBackingInt(data.lhs)) orelse return false;
            if (a.siblings(c).count != 1) return false;
            for (b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index)) |i| if (!a.irrefutable(m, i)) return false;
            return true;
        },
        else => false,
    };
}

/// The negation an arm gives the arms after it (A1–A2): only for a
/// single-path, irrefutable-below constructor test on a path.
fn negationOf(a: *Writes, m: u32, pat: Inst.Index, v: u32) Error!?Fact {
    const b = a.bir(m);
    const data = b.instData(pat);
    switch (b.instTag(pat)) {
        .pat_as => return a.negationOf(m, @fromBackingInt(data.lhs), v),
        .pat_ctor => {
            if (a.termTag(v) != .same or !a.factPath(a.termWord(v, 1))) return null;
            const c = a.ctorTarget(m, @fromBackingInt(data.lhs)) orelse return null;
            if (a.siblings(c).count == 1) return null;
            for (b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index)) |i| if (!a.irrefutable(m, i)) return null;
            return .{ .kind = .neg, .key = a.termWord(v, 1), .val = c };
        },
        .pat_tuple => {
            const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
            var found: ?Fact = null;
            for (items, 0..) |item, j| {
                if (a.irrefutable(m, item)) continue;
                if (found != null) return null;
                found = (try a.negationOf(m, item, try a.proj(v, .tuple, @intCast(j), 0))) orelse return null;
            }
            return found;
        },
        else => return null,
    }
}

/// What matching `pat` against `v` reads (write-sets.md, amended 2026-10-09:
/// tag reads): a constructor pattern on a path reads the tag there and
/// nothing more, its sub-patterns read below it; a literal or list pattern
/// reads the value it tests; a value that is not a path (`Fresh`, an `Alt`,
/// one the k-limit cut) is read whole. A known constructor reads nothing.
fn patReads(a: *Writes, f: *Frame, pat: Inst.Index, v: u32, out: *u32) Error!void {
    const b = a.bir(f.m);
    const data = b.instData(pat);
    switch (b.instTag(pat)) {
        .pat_wild, .pat_var, .pat_unit, .pat_record => {},
        .pat_as => try a.patReads(f, @fromBackingInt(data.lhs), v, out),
        .pat_ctor => {
            const c = a.ctorTarget(f.m, @fromBackingInt(data.lhs)) orelse {
                out.* = try a.depsUnion(out.*, try a.deps(v));
                return;
            };
            switch (a.termTag(v)) {
                .same => if (a.siblings(c).count > 1) {
                    out.* = try a.depsUnion(out.*, try a.depsOfPath(try a.tagRead(a.termWord(v, 1))));
                },
                .con => if (a.termWord(v, 1) != c) return,
                else => {
                    out.* = try a.depsUnion(out.*, try a.deps(v));
                    return;
                },
            }
            const args = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index);
            for (args, 0..) |arg, j| try a.patReads(f, arg, try a.proj(v, .ctor, c, @intCast(j)), out);
        },
        .pat_tuple => {
            if (a.termTag(v) != .same and a.termTag(v) != .tup) {
                out.* = try a.depsUnion(out.*, try a.deps(v));
                return;
            }
            const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
            for (items, 0..) |item, j| try a.patReads(f, item, try a.proj(v, .tuple, @intCast(j), 0), out);
        },
        else => out.* = try a.depsUnion(out.*, try a.deps(v)),
    }
}

fn parseInt(text: []const u8) ?i64 {
    var t = text;
    var neg = false;
    if (t.len > 0 and t[0] == '-') {
        neg = true;
        t = t[1..];
    }
    const v = if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X"))
        std.fmt.parseInt(i64, t[2..], 16) catch return null
    else
        std.fmt.parseInt(i64, t, 10) catch return null;
    return if (neg) -v else v;
}

// ---------------------------------------------------------------------------
// Evaluation (§3.3)
// ---------------------------------------------------------------------------

fn eval(a: *Writes, f: *Frame, inst: Inst.Index, g: u32) Error!u32 {
    try a.tick();
    const b = a.bir(f.m);
    const data = b.instData(inst);
    switch (b.instTag(inst)) {
        .local => {
            const v = f.env[data.lhs];
            return if (v == none) a.unknownLocal(f) else v;
        },
        .top, .ext_value => {
            const t = a.valueTarget(f.m, inst) orelse return a.freshEmpty();
            return a.topRef(t.m, t.d, g);
        },
        .ctor, .ext_ctor => {
            const c = a.ctorTarget(f.m, inst) orelse return a.freshEmpty();
            if (a.ctorArity(c) == 0) return a.mkCon(c, &.{});
            return a.mkFun(.ctor, a.ctor_module[c], c, none, &.{});
        },
        .int => {
            const n = parseInt(b.bytes(inst)) orelse return a.mkLit(lit_float, try a.internBytes(b.bytes(inst)), 0);
            const u: u64 = @bitCast(n);
            return a.mkLit(lit_int, @truncate(u), @truncate(u >> 32));
        },
        .float => return a.mkLit(lit_float, try a.internBytes(b.bytes(inst)), 0),
        .char => return a.mkLit(lit_char, data.lhs, 0),
        .string => return a.mkLit(lit_string, try a.internBytes(b.bytes(inst)), 0),
        .unit => return a.mkLit(lit_unit, 0, 0),
        .interp => {
            var d: u32 = 0;
            for (b.extraSlice(Bir.inlineRange(data), Inst.Index)) |part| {
                if (b.instTag(part) == .chunk) continue;
                d = try a.depsUnion(d, try a.deps(try a.eval(f, part, g)));
            }
            return a.mkFresh(d);
        },
        .tuple => {
            const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
            const vals = try a.arena().alloc(u32, items.len);
            for (items, vals) |item, *v| v.* = try a.eval(f, item, g);
            return a.mkTup(vals);
        },
        .list => {
            const items = b.extraSlice(Bir.inlineRange(data), Inst.Index);
            if (items.len == 0) return a.mkLst(none, .clear, none, none, &.{});
            const vals = try a.arena().alloc(u32, items.len);
            // Markup written as a list's element is a `List Html` value.
            a.ctx.in_list += 1;
            defer a.ctx.in_list -= 1;
            for (items, vals) |item, *v| v.* = try a.eval(f, item, g);
            return a.mkLstLit(vals);
        },
        .record => {
            const fields = b.extraSlice(Bir.inlineRange(data), Bir.Field);
            const pairs = try a.arena().alloc([2]u32, fields.len);
            for (fields, pairs) |fld, *p| p.* = .{ @backingInt(b.symbol(fld.name)), try a.eval(f, fld.value, g) };
            return a.mkRec(none, 0, pairs);
        },
        .record_update => {
            const base = try a.eval(f, @fromBackingInt(data.lhs), g);
            const fields = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Bir.Field);
            const pairs = try a.arena().alloc([2]u32, fields.len);
            for (fields, pairs) |fld, *p| p.* = .{ @backingInt(b.symbol(fld.name)), try a.eval(f, fld.value, g) };
            return a.recordUpdate(base, pairs);
        },
        .field_access => return a.projField(try a.eval(f, @fromBackingInt(data.lhs), g), b.symbol(@fromBackingInt(data.rhs))),
        .tuple_index => return a.proj(try a.eval(f, @fromBackingInt(data.lhs), g), .tuple, data.rhs, 0),
        .call => return a.evalCall(f, inst, g),
        .method_call => return a.evalMethod(f, inst, g),
        .type_dispatch => {
            const md = b.extraData(@fromBackingInt(data.rhs), Bir.TypeDispatch);
            const args = b.extraSlice(.{ .start = md.args_start, .end = md.args_end }, Inst.Index);
            var d: u32 = 0;
            for (args) |arg| d = try a.depsUnion(d, try a.deps(try a.eval(f, arg, g)));
            return a.mkFresh(d);
        },
        .lambda => return a.mkFun(.lambda, f.m, f.decl, inst.int(), f.env),
        .let => {
            const items = b.extraSlice(b.subRange(@fromBackingInt(data.lhs)), Inst.Index);
            for (items) |item| {
                const idata = b.instData(item);
                switch (b.instTag(item)) {
                    .let_def => {
                        const ld = b.extraData(@fromBackingInt(idata.lhs), Bir.LetDef);
                        if (ld.params_start == ld.params_end) {
                            f.env[ld.local] = try a.eval(f, @fromBackingInt(idata.rhs), g);
                        } else {
                            f.env[ld.local] = try a.mkFun(.letdef, f.m, f.decl, item.int(), f.env);
                        }
                    },
                    .let_pattern => {
                        const v = try a.eval(f, @fromBackingInt(idata.rhs), g);
                        try a.bind(f, @fromBackingInt(idata.lhs), v);
                    },
                    .let_stmt => _ = try a.eval(f, @fromBackingInt(idata.rhs), g),
                    else => {},
                }
            }
            return a.eval(f, @fromBackingInt(data.rhs), g);
        },
        .case => {
            const s = try a.eval(f, @fromBackingInt(data.lhs), g);
            const branches = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index);
            return a.caseOn(f, s, branches, g);
        },
        .@"try" => {
            const s = try a.eval(f, @fromBackingInt(data.lhs), g);
            f.try_deps = try a.depsUnion(f.try_deps, try a.deps(s));
            return a.mkFresh(try a.deps(s));
        },
        .markup => return a.evalMarkup(f, inst, g),
        else => return a.freshEmpty(),
    }
}

fn recordUpdate(a: *Writes, base: u32, pairs: [][2]u32) Error!u32 {
    switch (a.termTag(base)) {
        .same => return a.mkRec(a.termWord(base, 1), 1, pairs),
        .rec => {
            var all: std.ArrayList([2]u32) = .empty;
            defer all.deinit(a.gpa);
            try all.appendSlice(a.gpa, pairs);
            var i: u32 = 3;
            while (i < a.termLen(base)) : (i += 2) {
                const name = a.termWord(base, i);
                var named = false;
                for (pairs) |p| if (p[0] == name) {
                    named = true;
                };
                if (!named) try all.append(a.gpa, .{ name, a.termWord(base, i + 1) });
            }
            return a.mkRec(a.termWord(base, 1), a.termWord(base, 2), all.items);
        },
        // An update of a value chosen by control flow is the update of each
        // choice, as `proj` of one is (research 63: an amendment to §3.3).
        .alt => {
            var items: std.ArrayList(AltItem) = .empty;
            defer items.deinit(a.gpa);
            for (0..a.altLen(base)) |i| {
                const it = a.altItem(base, @intCast(i));
                const copy = try a.arena().dupe([2]u32, pairs);
                try items.append(a.gpa, .{ .gamma = it.gamma, .term = try a.recordUpdate(it.term, copy) });
            }
            return a.mkAlt(a.termWord(base, 1), a.termWord(base, 2) == 1, a.termWord(base, 3), items.items);
        },
        else => return a.mkRec(none, 2 + try a.deps(base), pairs),
    }
}

// ---- case ----------------------------------------------------------------

fn caseOn(a: *Writes, f: *Frame, s: u32, branches: []const Inst.Index, g: u32) Error!u32 {
    const b = a.bir(f.m);
    if (a.termTag(s) == .alt) {
        // Each alternative of the scrutinee is matched under its own facts
        // and the results joined (§3.2).
        var items: std.ArrayList(AltItem) = .empty;
        defer items.deinit(a.gpa);
        const n = a.altLen(s);
        for (0..n) |i| {
            const it = a.altItem(s, @intCast(i));
            const g2 = (try a.gammaJoin(g, it.gamma)) orelse continue;
            try items.append(a.gpa, .{ .gamma = it.gamma, .term = try a.caseOn(f, it.term, branches, g2) });
        }
        // Plain: a keyed `Alt` is a `case` on a path (§3.1); this one is a join
        // over another `Alt`'s alternatives, which counts against A and depth.
        return a.mkAlt(s, false, none, items.items);
    }
    var items: std.ArrayList(AltItem) = .empty;
    defer items.deinit(a.gpa);
    var negs: std.ArrayList(Fact) = .empty;
    defer negs.deinit(a.gpa);
    var keyed = false;
    const ixeq = a.termTag(s) == .ixeq;
    for (branches) |br| {
        const pat: Inst.Index = @fromBackingInt(b.instData(br).lhs);
        const body: Inst.Index = @fromBackingInt(b.instData(br).rhs);
        const g_negs = (try a.gammaAdd(g, negs.items)) orelse break;
        var m: Match = .{};
        defer m.facts.deinit(a.gpa);
        try a.matchFacts(f, pat, s, g_negs, &m);
        if (!m.ok) continue;
        if (ixeq) if (a.boolPattern(f.m, pat)) |truth| {
            try m.facts.append(a.gpa, .{ .kind = if (truth) .ieq else .ineq, .key = a.termWord(s, 1), .val = a.termWord(s, 2) });
        };
        if (b.instTag(pat) == .pat_ctor or b.instTag(pat) == .pat_as) keyed = keyed or a.termTag(s) == .same;
        const gi = (try a.gammaAdd(g_negs, m.facts.items)) orelse continue;
        if (a.ctx.mode == .key) try a.noteSplit(m.facts.items, g);
        try a.bind(f, pat, s);
        const r = try a.eval(f, body, gi);
        // The alternative's own facts: the negations so far and the arm's.
        var own: std.ArrayList(Fact) = .empty;
        defer own.deinit(a.gpa);
        try own.appendSlice(a.gpa, negs.items);
        try own.appendSlice(a.gpa, m.facts.items);
        const og = (try a.gammaAdd(0, own.items)) orelse continue;
        try items.append(a.gpa, .{ .gamma = og, .term = r });
        if (try a.negationOf(f.m, pat, s)) |neg| try negs.append(a.gpa, neg);
    }
    if (a.termTag(s) != .same) keyed = false;
    // What choosing the arm read: the tag at each path a constructor
    // pattern tests, the whole value where a pattern tests more (amended
    // 2026-10-09: tag reads).
    var reads: u32 = 0;
    for (branches) |br| try a.patReads(f, @fromBackingInt(b.instData(br).lhs), s, &reads);
    return a.mkAlt(s, keyed, reads, items.items);
}

fn boolPattern(a: *Writes, m: u32, pat: Inst.Index) ?bool {
    const b = a.bir(m);
    if (b.instTag(pat) != .pat_ctor) return null;
    const c = a.ctorTarget(m, @fromBackingInt(b.instData(pat).lhs)) orelse return null;
    if (c == a.ctor_true) return true;
    if (c == a.ctor_false) return false;
    return null;
}

/// Key mode: a positive fact on a path of the message that the key has not
/// decided is where the key splits (§4.4). The first such path met is the
/// split; every constructor named at it, here or later in the walk, is a
/// child.
fn noteSplit(a: *Writes, facts: []const Fact, g: u32) Allocator.Error!void {
    // The shortest undecided message path among these facts.
    var best: u32 = none;
    for (facts) |fact| {
        if (fact.kind != .pos) continue;
        if (a.pathKind(a.rootOf(fact.key)) != .mu) continue;
        if (a.tagKnown(g, fact.key) != null) continue;
        if (best == none or a.pathLen(fact.key) < a.pathLen(best)) best = fact.key;
    }
    if (a.ctx.split_path == none) {
        if (best == none) return;
        a.ctx.split_path = best;
    }
    for (facts) |fact| {
        if (fact.kind != .pos or fact.key != a.ctx.split_path) continue;
        if (a.tagKnown(g, fact.key) != null) continue;
        if (std.mem.indexOfScalar(u32, a.split_ctors.items, fact.val) == null) try a.split_ctors.append(a.gpa, fact.val);
    }
}

// ---- references and calls ---------------------------------------------------

fn topRef(a: *Writes, m: u32, d: u32, g: u32) Error!u32 {
    const decl = a.bir(m).decls[d];
    if (decl.kind == .foreign_value) {
        if (decl.params == 0) return a.freshEmpty();
        return a.mkFun(.top, m, d, none, &.{});
    }
    if (!decl.kind.isValue()) return a.freshEmpty();
    if (decl.params > 0) return a.mkFun(.top, m, d, none, &.{});
    return a.topValue(m, d, g);
}

/// A top-level value: its body, closed, analysed once (B3). In `view` it is
/// walked again, so the holes of a markup constant are seen.
fn topValue(a: *Writes, m: u32, d: u32, g: u32) Error!u32 {
    _ = g;
    const id = a.fnId(m, d);
    if (a.ctx.mode != .view) {
        if (a.top_values[id] != none) return a.top_values[id];
    } else if (a.in.packages[m] != .app) {
        if (a.top_values[id] != none) return a.top_values[id];
    }
    const body = a.bir(m).decls[d].body.unwrap() orelse return a.freshEmpty();
    const key: u64 = (@as(u64, 1) << 63) | (@as(u64, m) << 32) | d;
    if (std.mem.indexOfScalar(u64, a.active.items, key) != null) return a.freshEmpty();
    try a.active.append(a.gpa, key);
    defer _ = a.active.pop();
    if (a.ctx.mode == .view and a.in.packages[m] == .app) {
        var f = try a.newFrame(m, d, 0);
        return a.eval(&f, body, 0);
    }
    const saved = a.ctx;
    a.ctx = .{ .mode = .closed, .work = 0 };
    defer a.ctx = saved;
    var f = try a.newFrame(m, d, 0);
    const v = a.eval(&f, body, 0) catch |err| switch (err) {
        error.WorkCap => try a.freshEmpty(),
        else => |e| return e,
    };
    a.top_values[id] = v;
    return v;
}

fn evalArgs(a: *Writes, f: *Frame, args: []const Inst.Index, g: u32) Error![]u32 {
    const vals = try a.arena().alloc(u32, args.len);
    for (args, vals) |arg, *v| v.* = try a.eval(f, arg, g);
    return vals;
}

fn evalCall(a: *Writes, f: *Frame, inst: Inst.Index, g: u32) Error!u32 {
    const b = a.bir(f.m);
    const data = b.instData(inst);
    const callee: Inst.Index = @fromBackingInt(data.lhs);
    const args = try a.evalArgs(f, b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index), g);
    if (a.valueTarget(f.m, callee)) |t| {
        // `++` on lists is `List.append` by the dispatch table.
        if (a.dispatchOf(f.m)) |dt| if (dt.isListAppend(inst) or dt.isListAppend(callee)) {
            if (args.len == 2) return a.applyRow(.append, f.m, inst, args, g);
        };
        // `-42` is `Basics.negate 42`: a negative integer literal, kept a
        // literal so `init` can give it (§3.5, §9.1 as amended).
        if (args.len == 1 and a.in.packages[t.m] == .core and a.termTag(args[0]) == .lit and a.termWord(args[0], 1) == lit_int and
            std.mem.eql(u8, a.in.module_names[t.m], "Basics") and std.mem.eql(u8, a.declName(t.m, t.d), "negate"))
        {
            const u = @as(u64, a.termWord(args[0], 2)) | (@as(u64, a.termWord(args[0], 3)) << 32);
            const n: i64 = @bitCast(u);
            if (n != std.math.minInt(i64)) {
                const neg: u64 = @bitCast(-n);
                return a.mkLit(lit_int, @truncate(neg), @truncate(neg >> 32));
            }
        }
        return a.callTop(t.m, t.d, args, f.m, inst, g);
    }
    if (a.ctorTarget(f.m, callee)) |c| return a.mkCon(c, args);
    const fun = try a.eval(f, callee, g);
    return a.apply(fun, args, g);
}

fn evalMethod(a: *Writes, f: *Frame, inst: Inst.Index, g: u32) Error!u32 {
    const b = a.bir(f.m);
    const data = b.instData(inst);
    const mc = b.extraData(@fromBackingInt(data.rhs), Bir.MethodCall);
    const recv = try a.eval(f, @fromBackingInt(data.lhs), g);
    const arg_insts = b.extraSlice(.{ .start = mc.args_start, .end = mc.args_end }, Inst.Index);
    const rest = try a.evalArgs(f, arg_insts, g);
    // A guard on an index: `ι == e` with `e` handler-evaluable (§3.3).
    if (mc.origin == .eq and rest.len == 1) {
        if (try a.indexGuard(f, recv, rest[0], arg_insts[0])) |t| return t;
        if (try a.indexGuard(f, rest[0], recv, @fromBackingInt(data.lhs))) |t| return t;
    }
    var all = try a.arena().alloc(u32, rest.len + 1);
    all[0] = recv;
    @memcpy(all[1..], rest);
    const dt = a.dispatchOf(f.m) orelse return a.freshCall(all);
    const site = dt.siteOf(inst) orelse return a.freshCall(all);
    const ci = site.callee.unwrap() orelse return a.freshCall(all);
    switch (dt.term(ci)) {
        .top => |t| return a.callTop(f.m, t.decl.int(), all, f.m, inst, g),
        .ext => |t| {
            const m2 = t.module.int();
            if (m2 >= a.in.provenance.len) return a.freshCall(all);
            const d = a.in.provenance[m2].valueDecl(@backingInt(t.value)) orelse return a.freshCall(all);
            return a.callTop(m2, d.int(), all, f.m, inst, g);
        },
        .field => {
            const fun = try a.projField(recv, b.symbol(mc.name));
            return a.apply(fun, rest, g);
        },
        // A derived or primitive `eq`/`compare` returns a `Bool` or an
        // `Order`, and reads its operands; evidence passed as a parameter
        // is not resolved through a summary in this slice (research 63).
        else => return a.freshCall(all),
    }
}

fn indexGuard(a: *Writes, f: *Frame, iota: u32, other: u32, other_inst: Inst.Index) Error!?u32 {
    if (a.termTag(iota) != .same) return null;
    const p = a.termWord(iota, 1);
    if (a.pathParent(p) != none or a.pathKind(p) != .iota) return null;
    const s = try a.mkSym(f.m, other_inst, other);
    if (s == sym_unknown) return null;
    return try a.mkIxeq(p, s, try a.depsUnion(try a.deps(iota), try a.deps(other)));
}

/// `Fresh` of the arguments; in `view`, each function argument is applied
/// to `Fresh` arguments first so that the holes it holds are seen.
fn freshCall(a: *Writes, args: []const u32) Error!u32 {
    var d: u32 = 0;
    for (args) |x| d = try a.depsUnion(d, try a.deps(x));
    if (a.ctx.mode == .key) for (args) |x| try a.noteMu(x);
    if (a.ctx.mode == .view) {
        const fr = try a.mkFresh(d);
        for (args) |x| {
            if (a.termTag(x) != .fun) continue;
            const n = a.funArity(x);
            if (n == 0) continue;
            const xs = try a.arena().alloc(u32, n);
            @memset(xs, fr);
            _ = try a.apply(x, xs, 0);
        }
    }
    return a.mkFresh(d);
}

fn funArity(a: *Writes, t: u32) u32 {
    const kind: FunKind = @fromBackingInt(a.termWord(t, 1));
    const m = a.termWord(t, 2);
    const b = a.bir(m);
    return switch (kind) {
        .top => b.decls[a.termWord(t, 3)].params,
        .ctor => a.ctorArity(a.termWord(t, 3)),
        .lambda => b.subRange(@fromBackingInt(b.instData(@fromBackingInt(a.termWord(t, 4))).lhs)).len(),
        .letdef => blk: {
            const ld = b.extraData(@fromBackingInt(b.instData(@fromBackingInt(a.termWord(t, 4))).lhs), Bir.LetDef);
            break :blk @backingInt(ld.params_end) - @backingInt(ld.params_start);
        },
    };
}

/// A call of the top-level `(m, d)`: a core row, `Fresh` for a `foreign` or
/// a platform function without one, the body inlined in `view` for the
/// program's own functions, and otherwise its summary instantiated.
fn callTop(a: *Writes, m: u32, d: u32, args: []const u32, site_m: u32, site: Inst.Index, g: u32) Error!u32 {
    const decl = a.bir(m).decls[d];
    if (a.in.packages[m] != .app) {
        // The rows are core's: a platform module of the same name is not `List`.
        if (a.in.packages[m] == .core) if (Core.row(a.in.module_names[m], a.declName(m, d))) |r| {
            // Markup a `List` function's callback builds is a list's element.
            const in_list = a.ctx.mode == .view and std.mem.eql(u8, a.in.module_names[m], "List");
            if (in_list) a.ctx.in_list += 1;
            defer if (in_list) {
                a.ctx.in_list -= 1;
            };
            return a.applyRow(r, site_m, site, args, g);
        };
        if (a.in.packages[m] == .platform) {
            if (a.ctx.mode == .view and args.len == 2 and std.mem.eql(u8, a.in.module_names[m], "Html") and
                std.mem.eql(u8, a.declName(m, d), "map") and !a.ctorShape(args[1]))
            {
                const at: MapSite = if (a.in.packages[site_m] == .app and site.int() < a.bir(site_m).insts.len)
                    .{ .module = site_m, .token = a.bir(site_m).insts.items(.main_token)[site.int()] }
                else
                    .{ .module = none, .token = 0 };
                try a.map_sites.append(a.gpa, at);
            }
            return a.freshCall(args);
        }
    }
    if (decl.kind == .foreign_value or !decl.kind.isValue()) return a.freshCall(args);
    if (decl.params == 0) return a.apply(try a.topValue(m, d, g), args, g);
    if (args.len != decl.params) return a.freshCall(args);
    if (a.ctx.mode == .view and a.in.packages[m] == .app) return a.direct(m, d, args, g);
    const s = try a.summary(m, d);
    return a.instantiate(s, a.fnId(m, d), args, g);
}

/// Apply a function value (§4.2's reductions).
fn apply(a: *Writes, fun: u32, args: []const u32, g: u32) Error!u32 {
    switch (a.termTag(fun)) {
        .fun => {
            const kind: FunKind = @fromBackingInt(a.termWord(fun, 1));
            const m = a.termWord(fun, 2);
            const x = a.termWord(fun, 3);
            switch (kind) {
                .top => return a.callTop(m, x, args, m, @fromBackingInt(0), g),
                .ctor => {
                    if (args.len != a.ctorArity(x)) return a.freshCall(args);
                    return a.mkCon(x, args);
                },
                .lambda, .letdef => return a.applyClosure(fun, args, g),
            }
        },
        .alt => {
            var items: std.ArrayList(AltItem) = .empty;
            defer items.deinit(a.gpa);
            for (0..a.altLen(fun)) |i| {
                const it = a.altItem(fun, @intCast(i));
                const g2 = (try a.gammaJoin(g, it.gamma)) orelse continue;
                try items.append(a.gpa, .{ .gamma = it.gamma, .term = try a.apply(it.term, args, g2) });
            }
            return a.mkAlt(a.termWord(fun, 1), a.termWord(fun, 2) == 1, a.termWord(fun, 3), items.items);
        },
        .same => {
            const r = a.rootOf(a.termWord(fun, 1));
            if (a.pathKind(r) == .pi) return a.mkApp(fun, args);
        },
        else => {},
    }
    var all = try a.arena().alloc(u32, args.len + 1);
    all[0] = fun;
    @memcpy(all[1..], args);
    return a.freshCall(all);
}

fn applyClosure(a: *Writes, fun: u32, args: []const u32, g: u32) Error!u32 {
    const kind: FunKind = @fromBackingInt(a.termWord(fun, 1));
    const m = a.termWord(fun, 2);
    const d = a.termWord(fun, 3);
    const inst: Inst.Index = @fromBackingInt(a.termWord(fun, 4));
    const b = a.bir(m);
    const key: u64 = (@as(u64, m) << 32) | inst.int();
    if (std.mem.indexOfScalar(u64, a.active.items, key) != null or a.inst_depth >= cap_inst_depth) {
        if (a.inst_depth >= cap_inst_depth) a.ctx.caps.d = true else try a.noteRecursive(key);
        return a.freshCall(args);
    }
    try a.active.append(a.gpa, key);
    defer _ = a.active.pop();
    try a.holders.append(a.gpa, key);
    defer _ = a.holders.pop();
    a.inst_depth += 1;
    defer a.inst_depth -= 1;
    var f = try a.newFrame(m, d, 0);
    const n_env = a.termLen(fun) - 5;
    for (0..@min(n_env, f.env.len)) |i| f.env[i] = a.termWord(fun, 5 + i);
    f.unknown = try a.deps(fun);
    const data = b.instData(inst);
    var params: []const Inst.Index = undefined;
    var body: Inst.Index = undefined;
    if (kind == .lambda) {
        params = b.extraSlice(b.subRange(@fromBackingInt(data.lhs)), Inst.Index);
        body = @fromBackingInt(data.rhs);
    } else {
        const ld = b.extraData(@fromBackingInt(data.lhs), Bir.LetDef);
        params = b.extraSlice(.{ .start = ld.params_start, .end = ld.params_end }, Inst.Index);
        body = @fromBackingInt(data.rhs);
        f.env[ld.local] = fun;
    }
    if (params.len != args.len) return a.freshCall(args);
    for (params, args) |p, v| try a.bind(&f, p, v);
    var r = try a.eval(&f, body, g);
    r = try a.joinTry(&f, r);
    return a.capSize(r);
}

fn joinTry(a: *Writes, f: *Frame, r: u32) Error!u32 {
    if (f.try_deps == 0) return r;
    return a.mkAlt(none, false, none, &.{ .{ .gamma = 0, .term = r }, .{ .gamma = 0, .term = try a.mkFresh(f.try_deps) } });
}

fn directKey(m: u32, d: u32) u64 {
    return (@as(u64, m) << 32) | (@as(u64, 1) << 62) | d;
}

/// A function the view walk re-entered: the markup it holds is on the
/// value path (browser-direct.md §5.2: a recursive helper).
fn noteRecursive(a: *Writes, key: u64) Allocator.Error!void {
    if (a.ctx.mode != .view) return;
    if (std.mem.indexOfScalar(u64, a.recursive.items, key) == null) try a.recursive.append(a.gpa, key);
}

/// Walk `(m, d)`'s body with `args` bound: the key's walk of `update`, the
/// view's inlining, `init`.
fn direct(a: *Writes, m: u32, d: u32, args: []const u32, g: u32) Error!u32 {
    const key = directKey(m, d);
    if (std.mem.indexOfScalar(u64, a.active.items, key) != null or a.inst_depth >= cap_inst_depth) {
        if (a.inst_depth >= cap_inst_depth) a.ctx.caps.d = true else try a.noteRecursive(key);
        return a.freshCall(args);
    }
    try a.active.append(a.gpa, key);
    defer _ = a.active.pop();
    try a.holders.append(a.gpa, key);
    defer _ = a.holders.pop();
    a.inst_depth += 1;
    defer a.inst_depth -= 1;
    const b = a.bir(m);
    const decl = b.decls[d];
    var f = try a.newFrame(m, d, if (a.ctx.mode == .summary) 0 else try a.depsOfPath(rho_path));
    const params = b.extraSlice(.{ .start = decl.params_start, .end = decl.params_end }, Inst.Index);
    if (params.len != args.len) return a.freshCall(args);
    for (params, args) |p, v| try a.bind(&f, p, v);
    const body = decl.body.unwrap() orelse return a.freshCall(args);
    var r = try a.eval(&f, body, g);
    r = try a.joinTry(&f, r);
    return a.capSize(r);
}

// ---------------------------------------------------------------------------
// Summaries and the fixpoint (§4.1, §4.3)
// ---------------------------------------------------------------------------

fn paramDeps(a: *Writes, m: u32, d: u32) Allocator.Error!u32 {
    const n = a.bir(m).decls[d].params;
    const mark = a.scratch.items.len;
    defer a.scratch.shrinkRetainingCapacity(mark);
    const id = a.fnId(m, d);
    for (0..n) |i| try a.scratch.append(a.gpa, try a.mkPath(none, .pi, id, @intCast(i)));
    return a.mkDeps(a.scratch.items[mark..]);
}

fn summary(a: *Writes, m: u32, d: u32) Error!u32 {
    const id = a.fnId(m, d);
    switch (a.summaries[id]) {
        .done => |t| return t,
        .active => |s| {
            // A recursion: the current approximation, and the lowest frame
            // it reaches back to (Tarjan's low link).
            const top = &a.summary_stack.items[a.summary_stack.items.len - 1];
            top.low = @min(top.low, s.depth);
            a.summary_stack.items[s.depth].hit = true;
            return s.approx;
        },
        .absent => {},
    }
    const depth: u32 = @intCast(a.summary_stack.items.len);
    try a.summary_stack.append(a.gpa, .{ .fn_id = id, .low = depth });
    var approx = try a.bottom();
    a.summaries[id] = .{ .active = .{ .depth = depth, .approx = approx } };
    var round: u32 = 0;
    var result: u32 = undefined;
    var caps: Caps = .{};
    while (true) {
        round += 1;
        a.summary_stack.items[depth].hit = false;
        const saved = a.ctx;
        const saved_depth = a.inst_depth;
        a.ctx = .{ .mode = .summary };
        a.inst_depth = 0;
        result = a.summaryBody(m, d) catch |err| switch (err) {
            error.WorkCap => blk: {
                a.ctx.caps.w = true;
                break :blk try a.mkFresh(try a.paramDeps(m, d));
            },
            else => |e| return e,
        };
        result = try a.capSize(result);
        caps = a.ctx.caps;
        a.ctx = saved;
        a.inst_depth = saved_depth;
        if (!a.summary_stack.items[depth].hit or result == approx) break;
        if (round >= cap_rounds) {
            caps.i = true;
            result = try a.mkFresh(try a.paramDeps(m, d));
            break;
        }
        approx = result;
        a.summaries[id] = .{ .active = .{ .depth = depth, .approx = approx } };
    }
    var frame = a.summary_stack.pop().?;
    defer frame.members.deinit(a.gpa);
    a.summary_caps[id] = a.summary_caps[id].join(caps);
    if (frame.low < depth) {
        // A member of a cycle whose head is below: provisional.
        a.summaries[id] = .absent;
        const parent = &a.summary_stack.items[a.summary_stack.items.len - 1];
        parent.low = @min(parent.low, frame.low);
        try a.summary_stack.items[frame.low].members.append(a.gpa, id);
        return result;
    }
    a.summaries[id] = .{ .done = result };
    if (caps.i) {
        // Every summary of a component that did not settle is `Fresh`.
        for (frame.members.items) |member| {
            const mm = a.fnModule(member);
            a.summaries[member] = .{ .done = try a.mkFresh(try a.paramDeps(mm, member - a.fn_base[mm])) };
            a.summary_caps[member].i = true;
        }
    }
    return result;
}

fn summaryBody(a: *Writes, m: u32, d: u32) Error!u32 {
    const b = a.bir(m);
    const decl = b.decls[d];
    const id = a.fnId(m, d);
    var f = try a.newFrame(m, d, try a.paramDeps(m, d));
    const params = b.extraSlice(.{ .start = decl.params_start, .end = decl.params_end }, Inst.Index);
    for (params, 0..) |p, i| try a.bind(&f, p, try a.mkSame(try a.mkPath(none, .pi, id, @intCast(i))));
    const body = decl.body.unwrap() orelse return a.mkFresh(try a.paramDeps(m, d));
    const r = try a.eval(&f, body, 0);
    return a.joinTry(&f, r);
}

// ---------------------------------------------------------------------------
// Instantiation (§4.2)
// ---------------------------------------------------------------------------

const Subst = struct {
    id: u32,
    fn_id: u32,
    args: []const u32,
    g: u32,
};

fn instantiate(a: *Writes, s: u32, fn_id: u32, args: []const u32, g: u32) Error!u32 {
    if (a.inst_depth >= cap_inst_depth) {
        a.ctx.caps.d = true;
        return a.freshCall(args);
    }
    a.inst_depth += 1;
    defer a.inst_depth -= 1;
    const sub: Subst = .{ .id = a.next_inst_id, .fn_id = fn_id, .args = args, .g = g };
    a.next_inst_id += 1;
    return a.capSize(try a.subst(&sub, s));
}

fn substRoot(a: *Writes, sub: *const Subst, root: u32) ?u32 {
    if (a.pathKind(root) != .pi or a.pathA(root) != sub.fn_id) return null;
    const i = a.pathB(root);
    return if (i < sub.args.len) sub.args[i] else null;
}

/// A path under the substitution: `proj` of the argument through the
/// suffix when its root is the callee's, else the path with its index
/// symbols rewritten.
fn substPath(a: *Writes, sub: *const Subst, p: u32) Error!u32 {
    var buf: [k_limit + 1]u32 = undefined;
    const st = a.steps(p, &buf);
    const root = a.rootOf(p);
    if (a.substRoot(sub, root)) |arg| {
        var v = arg;
        for (st) |s| {
            var x = a.pathA(s);
            if (a.pathKind(s) == .index) x = try a.substSym(sub, x);
            v = try a.proj(v, a.pathKind(s), x, a.pathB(s));
        }
        return v;
    }
    var q = root;
    for (st) |s| {
        var x = a.pathA(s);
        if (a.pathKind(s) == .index) x = try a.substSym(sub, x);
        q = try a.mkPath(q, a.pathKind(s), x, a.pathB(s));
    }
    return a.mkSame(q);
}

fn substPathId(a: *Writes, sub: *const Subst, p: u32) Error!?u32 {
    const v = try a.substPath(sub, p);
    return if (a.termTag(v) == .same) a.termWord(v, 1) else null;
}

fn substSym(a: *Writes, sub: *const Subst, s: u32) Error!u32 {
    if (a.symKind(s) != .expr) return s;
    const t = a.symWord(s, 3);
    const t2 = try a.subst(sub, t);
    if (t2 == t) return s;
    return a.mkSym(a.symWord(s, 1), @fromBackingInt(a.symWord(s, 2)), t2);
}

fn substDeps(a: *Writes, sub: *const Subst, d: u32) Error!u32 {
    var out: u32 = 0;
    const n = a.deps_t.len(d);
    for (0..n) |i| {
        const p = a.deps_t.word(d, i);
        if (a.substRoot(sub, a.rootOf(p)) != null) {
            if (a.isTagRead(p)) {
                out = try a.depsUnion(out, try a.tagDeps(try a.substPath(sub, a.pathParent(p))));
                continue;
            }
            out = try a.depsUnion(out, try a.deps(try a.substPath(sub, p)));
        } else {
            out = try a.depsUnion(out, try a.depsOfPath(p));
        }
    }
    return out;
}

/// Γ under the substitution: facts on the callee's roots move to the
/// argument's path, are decided by a known shape (an alternative whose fact
/// is false is dropped: null), or are dropped (§4.2).
/// What reading the tag of a value reads: the tag at its path, nothing for
/// a value whose constructor is known, everything it depends on otherwise.
fn tagDeps(a: *Writes, v: u32) Allocator.Error!u32 {
    return switch (a.termTag(v)) {
        .same => a.depsOfPath(try a.tagRead(a.termWord(v, 1))),
        .con, .lit => 0,
        else => a.deps(v),
    };
}

fn substGamma(a: *Writes, sub: *const Subst, g: u32) Error!?u32 {
    if (g == 0) return 0;
    var facts: std.ArrayList(Fact) = .empty;
    defer facts.deinit(a.gpa);
    for (0..a.gammaLen(g)) |i| {
        const f = a.gammaFact(g, i);
        switch (f.kind) {
            .pos, .neg => {
                const v = try a.substPath(sub, f.key);
                switch (a.termTag(v)) {
                    .same => if (a.factPath(a.termWord(v, 1))) try facts.append(a.gpa, .{ .kind = f.kind, .key = a.termWord(v, 1), .val = f.val }),
                    .con => {
                        const is = a.termWord(v, 1) == f.val;
                        if ((f.kind == .pos) != is) return null;
                    },
                    else => {},
                }
            },
            .ieq, .ineq => try facts.append(a.gpa, .{ .kind = f.kind, .key = f.key, .val = try a.substSym(sub, f.val) }),
        }
    }
    return a.gammaAdd(0, facts.items);
}

fn subst(a: *Writes, sub: *const Subst, t: u32) Error!u32 {
    try a.tick();
    if (a.subst_memo.get(.{ .inst = sub.id, .term = t })) |r| return r;
    const r = try a.substNode(sub, t);
    try a.subst_memo.put(a.gpa, .{ .inst = sub.id, .term = t }, r);
    return r;
}

fn substNode(a: *Writes, sub: *const Subst, t: u32) Error!u32 {
    switch (a.termTag(t)) {
        .same => return a.substPath(sub, a.termWord(t, 1)),
        .lit => return t,
        .fresh => return a.mkFresh(try a.substDeps(sub, a.termWord(t, 1))),
        .con => {
            const n = a.termLen(t) - 2;
            const parts = try a.arena().alloc(u32, n);
            for (parts, 0..) |*p, i| p.* = try a.subst(sub, a.termWord(t, 2 + i));
            return a.mkCon(a.termWord(t, 1), parts);
        },
        .tup, .lst_lit => {
            const n = a.termLen(t) - 1;
            const parts = try a.arena().alloc(u32, n);
            for (parts, 0..) |*p, i| p.* = try a.subst(sub, a.termWord(t, 1 + i));
            return if (a.termTag(t) == .tup) a.mkTup(parts) else a.mkLstLit(parts);
        },
        .app => {
            const fun = try a.subst(sub, a.termWord(t, 1));
            const n = a.termLen(t) - 2;
            const args = try a.arena().alloc(u32, n);
            for (args, 0..) |*p, i| p.* = try a.subst(sub, a.termWord(t, 2 + i));
            return a.apply(fun, args, sub.g);
        },
        .fun => {
            const n = a.termLen(t) - 5;
            const env = try a.arena().alloc(u32, n);
            for (env, 0..) |*e, i| {
                const x = a.termWord(t, 5 + i);
                e.* = if (x == none) none else try a.subst(sub, x);
            }
            return a.mkFun(@fromBackingInt(a.termWord(t, 1)), a.termWord(t, 2), a.termWord(t, 3), a.termWord(t, 4), env);
        },
        .ixeq => {
            const s = try a.substSym(sub, a.termWord(t, 2));
            return a.mkIxeq(a.termWord(t, 1), s, try a.substDeps(sub, a.termWord(t, 3)));
        },
        .rec => {
            const n = (a.termLen(t) - 3) / 2;
            const pairs = try a.arena().alloc([2]u32, n);
            for (pairs, 0..) |*p, i| p.* = .{ a.termWord(t, 3 + 2 * i), try a.subst(sub, a.termWord(t, 4 + 2 * i)) };
            const base = a.termWord(t, 1);
            var rest = a.termWord(t, 2);
            if (base == none) {
                if (rest >= 2) rest = 2 + try a.substDeps(sub, rest - 2);
                return a.mkRec(none, rest, pairs);
            }
            // B2: a base that is not a path.
            const bv = try a.substPath(sub, base);
            return a.recordUpdate(bv, pairs);
        },
        .lst => {
            const base = a.termWord(t, 1);
            const edit: Edit = @fromBackingInt(a.termWord(t, 2));
            const s1 = try a.substSymOpt(sub, a.termWord(t, 3));
            const s2 = try a.substSymOpt(sub, a.termWord(t, 4));
            const n = a.lstElems(t);
            const elems = try a.arena().alloc(Elem, n);
            for (elems, 0..) |*e, i| {
                const el = a.lstElem(t, @intCast(i));
                e.* = .{ .index = try a.substSymOpt(sub, el.index), .eps = el.eps, .term = try a.subst(sub, el.term) };
            }
            if (base == none) return a.mkLst(none, edit, s1, s2, elems);
            const bv = try a.substPath(sub, base);
            switch (a.termTag(bv)) {
                .same => return a.mkLst(a.termWord(bv, 1), edit, s1, s2, elems),
                .lst => if (edit == .kept and @as(Edit, @fromBackingInt(a.termWord(bv, 2))) == .kept) {
                    var all: std.ArrayList(Elem) = .empty;
                    defer all.deinit(a.gpa);
                    for (0..a.lstElems(bv)) |i| try all.append(a.gpa, a.lstElem(bv, @intCast(i)));
                    try all.appendSlice(a.gpa, elems);
                    return a.mkLst(a.termWord(bv, 1), .kept, none, none, all.items);
                },
                else => {},
            }
            return a.mkLst(none, .replaced, none, none, &.{});
        },
        .alt => {
            const scrut = a.termWord(t, 1);
            const s2 = if (scrut == none) none else try a.subst(sub, scrut);
            const reads = a.termWord(t, 3);
            const reads2 = if (reads == none) none else try a.substDeps(sub, reads);
            var items: std.ArrayList(AltItem) = .empty;
            defer items.deinit(a.gpa);
            const n = a.altLen(t);
            for (0..n) |i| {
                const it = a.altItem(t, @intCast(i));
                // Selection (§3.1, N1): an alternative whose facts a known
                // shape or the context contradicts is dropped.
                const g2 = (try a.substGamma(sub, it.gamma)) orelse continue;
                const joined = (try a.gammaJoin(sub.g, g2)) orelse continue;
                if (a.ctx.mode == .key) try a.noteSplitGamma(g2, sub.g);
                const sub2: Subst = .{ .id = sub.id, .fn_id = sub.fn_id, .args = sub.args, .g = joined };
                try items.append(a.gpa, .{ .gamma = g2, .term = try a.subst(&sub2, it.term) });
            }
            return a.mkAlt(s2, a.termWord(t, 2) == 1, reads2, items.items);
        },
    }
}

fn substSymOpt(a: *Writes, sub: *const Subst, s: u32) Error!u32 {
    return if (s == none) none else a.substSym(sub, s);
}

fn noteSplitGamma(a: *Writes, g: u32, ctx_g: u32) Allocator.Error!void {
    var facts: std.ArrayList(Fact) = .empty;
    defer facts.deinit(a.gpa);
    for (0..a.gammaLen(g)) |i| try facts.append(a.gpa, a.gammaFact(g, i));
    try a.noteSplit(facts.items, ctx_g);
}

// ---------------------------------------------------------------------------
// Core rows (§3.7)
// ---------------------------------------------------------------------------

fn listBase(a: *Writes, xs: u32) ?u32 {
    return if (a.termTag(xs) == .same) a.termWord(xs, 1) else null;
}

/// A callback's element root, anchored to the list it walks.
fn mintEps(a: *Writes, xs: u32) Error!u32 {
    if (a.listBase(xs)) |p| {
        const star = (try a.extend(p, .star, 0, 0)) orelse p;
        return a.mintRoot(.eps, star, false);
    }
    return a.mintRoot(.eps, try a.deps(xs), true);
}

fn mintIota(a: *Writes, xs: u32) Error!u32 {
    if (a.listBase(xs)) |p| return a.mintRoot(.iota, p, false);
    return a.mintRoot(.iota, try a.deps(xs), true);
}

/// Whether every alternative of `r` is the element itself.
fn isIdentity(a: *Writes, r: u32, eps: u32) bool {
    switch (a.termTag(r)) {
        .same => return a.termWord(r, 1) == eps,
        .alt => {
            if (a.altLen(r) == 0) return false;
            for (0..a.altLen(r)) |i| if (!a.isIdentity(a.altItem(r, @intCast(i)).term, eps)) return false;
            return true;
        },
        else => return false,
    }
}

fn argSym(a: *Writes, m: u32, site: Inst.Index, which: usize, t: u32) Error!u32 {
    const b = a.bir(m);
    if (site.int() < b.insts.len and b.instTag(site) == .call) {
        const args = b.extraSlice(b.subRange(@fromBackingInt(b.instData(site).rhs)), Inst.Index);
        if (which < args.len) return a.mkSym(m, args[which], t);
    }
    if (a.termTag(t) == .lit and a.termWord(t, 1) == lit_int) return a.mkSym(m, site, t);
    return sym_unknown;
}

fn applyRow(a: *Writes, row: Core.Row, m: u32, site: Inst.Index, args: []const u32, g: u32) Error!u32 {
    const xs = if (args.len > 0) args[0] else none;
    switch (row) {
        .fresh => return a.freshCall(args),
        .debug_todo => return a.freshEmpty(),
        .debug_log => {
            if (args.len != 2) return a.freshCall(args);
            // Logged whole, a message is a value (browser-direct.md §11).
            if (a.ctx.mode == .key) try a.noteMu(args[1]);
            return args[1];
        },
        .map, .update => {
            if (row == .map and args.len != 2) return a.freshCall(args);
            if (row == .update and args.len != 3) return a.freshCall(args);
            const fun = args[args.len - 1];
            const eps = try a.mintEps(xs);
            const r = try a.apply(fun, &.{try a.mkSame(eps)}, g);
            const p = a.listBase(xs) orelse return a.freshCall(args);
            if (a.isIdentity(r, eps)) return xs;
            const index = if (row == .map) sym_star else try a.argSym(m, site, 1, args[1]);
            return a.mkLst(p, .kept, none, none, &.{.{ .index = index, .eps = eps, .term = r }});
        },
        .indexed_map => {
            if (args.len != 2) return a.freshCall(args);
            const eps = try a.mintEps(xs);
            const iota = try a.mintIota(xs);
            const r = try a.apply(args[1], &.{ try a.mkSame(iota), try a.mkSame(eps) }, g);
            const p = a.listBase(xs) orelse return a.freshCall(args);
            return a.indexedResult(p, xs, eps, iota, r);
        },
        .filter, .remove_some, .permute => {
            // Which elements are kept, and in what order, is what the
            // callback answers and what the counts say: the result reads
            // those too (write-sets.md §3.6, amended 2026-10-09 for S0).
            var read: u32 = 0;
            var eps: u32 = none;
            for (args[1..]) |x| {
                if (row != .remove_some and a.termTag(x) == .fun) {
                    eps = try a.mintEps(xs);
                    const e = try a.mkSame(eps);
                    const xs2 = [_]u32{ e, e };
                    read = try a.depsUnion(read, try a.deps(try a.apply(x, xs2[0..@min(2, a.funArity(x))], g)));
                } else read = try a.depsUnion(read, try a.deps(x));
            }
            const p = a.listBase(xs) orelse return a.freshCall(args);
            return a.mkLst(p, if (row == .permute) .permute else .remove_some, none, none, try a.readsElem(xs, eps, read));
        },
        .filter_map => {
            if (args.len != 2) return a.freshCall(args);
            const eps = try a.mintEps(xs);
            const r = try a.apply(args[1], &.{try a.mkSame(eps)}, g);
            const p = a.listBase(xs) orelse return a.freshCall(args);
            if (a.keepsOrDrops(r, eps)) return a.mkLst(p, .remove_some, none, none, try a.readsElem(xs, eps, try a.deps(r)));
            return a.freshCall(args);
        },
        .set => {
            if (args.len != 3) return a.freshCall(args);
            const p = a.listBase(xs) orelse return a.freshCall(args);
            const eps = try a.mintEps(xs);
            const index = try a.argSym(m, site, 1, args[1]);
            return a.mkLst(p, .kept, none, none, &.{.{ .index = index, .eps = eps, .term = args[2] }});
        },
        .swap => {
            if (args.len != 3) return a.freshCall(args);
            const p = a.listBase(xs) orelse return a.freshCall(args);
            return a.mkLst(p, .swap, try a.argSym(m, site, 1, args[1]), try a.argSym(m, site, 2, args[2]), &.{});
        },
        .push => {
            const p = a.listBase(xs) orelse return a.freshCall(args);
            return a.mkLst(p, .append, none, none, &.{});
        },
        .append => {
            if (args.len != 2) return a.freshCall(args);
            if (a.listBase(args[0])) |p| return a.mkLst(p, .append, none, none, &.{});
            if (a.listBase(args[1])) |q| return a.mkLst(q, .prepend, none, none, &.{});
            return a.freshCall(args);
        },
        .cons => {
            if (args.len != 2) return a.freshCall(args);
            const q = a.listBase(args[1]) orelse return a.freshCall(args);
            return a.mkLst(q, .prepend, none, none, &.{});
        },
        .tail => {
            const p = a.listBase(xs) orelse return a.freshCall(args);
            return a.maybeOf(try a.mkLst(p, .remove_some, none, none, &.{}));
        },
        .insert_at, .remove_at => {
            const p = a.listBase(xs) orelse return a.freshCall(args);
            if (args.len < 2) return a.freshCall(args);
            const s = try a.argSym(m, site, 1, args[1]);
            return a.mkLst(p, if (row == .insert_at) .insert else .remove_at, s, none, &.{});
        },
        .get, .head, .last => {
            const p = a.listBase(xs) orelse return a.freshCall(args);
            const s = switch (row) {
                .get => if (args.len == 2) try a.argSym(m, site, 1, args[1]) else return a.freshCall(args),
                .head => try a.mkLitSym(0),
                else => sym_unknown,
            };
            const at = try a.mkSameStep(p, .index, s, 0);
            // An index the program computes is `[?]`, and the element read
            // reads what the index read (§3.6, amended 2026-10-09 for S0);
            // a model path's own index is anchored by `anchorPath`.
            if (row == .get and s == sym_unknown) return a.maybeOf(try a.mkFresh(try a.depsUnion(try a.deps(at), try a.deps(args[1]))));
            return a.maybeOf(at);
        },
    }
}

/// The one element a non-`kept` list carries for its reads: a `Fresh` of
/// what deciding its shape read, which `diff` never reads (an edit other
/// than `kept` is a `value` write of the list) and `deps` does.
fn readsElem(a: *Writes, xs: u32, eps0: u32, read: u32) Error![]const Elem {
    if (a.deps_t.len(read) == 0) return &.{};
    const eps = if (eps0 == none) try a.mintEps(xs) else eps0;
    const out = try a.arena().alloc(Elem, 1);
    out[0] = .{ .index = sym_star, .eps = eps, .term = try a.mkFresh(read) };
    return out;
}

/// `Alt([ Just v, Nothing ])`.
fn maybeOf(a: *Writes, v: u32) Error!u32 {
    if (a.ctor_just == none or a.ctor_nothing == none) return a.mkFresh(try a.deps(v));
    const just = try a.mkCon(a.ctor_just, &.{v});
    const nothing = try a.mkCon(a.ctor_nothing, &.{});
    return a.mkAlt(none, false, none, &.{ .{ .gamma = 0, .term = just }, .{ .gamma = 0, .term = nothing } });
}

fn keepsOrDrops(a: *Writes, r: u32, eps: u32) bool {
    switch (a.termTag(r)) {
        .con => {
            const c = a.termWord(r, 1);
            if (c == a.ctor_nothing) return true;
            if (c == a.ctor_just and a.termLen(r) == 3) {
                const x = a.termWord(r, 2);
                return a.termTag(x) == .same and a.termWord(x, 1) == eps;
            }
            return false;
        },
        .alt => {
            if (a.altLen(r) == 0) return false;
            for (0..a.altLen(r)) |i| if (!a.keepsOrDrops(a.altItem(r, @intCast(i)).term, eps)) return false;
            return true;
        },
        else => return false,
    }
}

/// `indexedMap`'s result with the index facts of §3.3: when the callback is
/// the element wherever its facts do not fix ι, and something else only
/// where they fix ι to e₁ … eₘ, the writes are at `[e₁] … [eₘ]`.
fn indexedResult(a: *Writes, p: u32, xs: u32, eps: u32, iota: u32, r: u32) Error!u32 {
    if (a.isIdentity(r, eps)) return xs;
    var leaves: std.ArrayList(AltItem) = .empty;
    defer leaves.deinit(a.gpa);
    const exact = try a.collectLeaves(r, 0, &leaves);
    if (exact) {
        var elems: std.ArrayList(Elem) = .empty;
        defer elems.deinit(a.gpa);
        var ok = true;
        for (leaves.items) |leaf| {
            var fixed: u32 = none;
            for (0..a.gammaLen(leaf.gamma)) |i| {
                const fct = a.gammaFact(leaf.gamma, i);
                if (fct.kind == .ieq and fct.key == iota) fixed = fct.val;
            }
            if (fixed == none) {
                if (!(a.termTag(leaf.term) == .same and a.termWord(leaf.term, 1) == eps)) ok = false;
                continue;
            }
            try elems.append(a.gpa, .{ .index = fixed, .eps = eps, .term = leaf.term });
        }
        if (ok and elems.items.len > 0) return a.mkLst(p, .kept, none, none, elems.items);
    }
    return a.mkLst(p, .kept, none, none, &.{.{ .index = sym_star, .eps = eps, .term = r }});
}

/// The leaves of nested `Alt`s with their accumulated facts; false past 64.
fn collectLeaves(a: *Writes, t: u32, g: u32, out: *std.ArrayList(AltItem)) Allocator.Error!bool {
    if (out.items.len > 64) return false;
    if (a.termTag(t) != .alt) {
        try out.append(a.gpa, .{ .gamma = g, .term = t });
        return true;
    }
    for (0..a.altLen(t)) |i| {
        const it = a.altItem(t, @intCast(i));
        const g2 = (try a.gammaJoin(g, it.gamma)) orelse continue;
        if (!try a.collectLeaves(it.term, g2, out)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// diff (§3.4)
// ---------------------------------------------------------------------------

const WsBuilder = std.ArrayList(Write);

fn wsGet(a: *const Writes, id: u32, out: *WsBuilder, gpa: Allocator) Allocator.Error!void {
    const words = a.wsets.get(id);
    var i: usize = 0;
    while (i < words.len) : (i += 5) {
        try out.append(gpa, .{ .path = words[i], .kind = @fromBackingInt(words[i + 1]), .edit = @fromBackingInt(words[i + 2]), .s1 = words[i + 3], .s2 = words[i + 4] });
    }
}

fn joinEdit(x: Edit, y: Edit) Edit {
    if (x == y) return x;
    if (x == .none or y == .none) return .replaced;
    if (x == .kept) return y;
    if (y == .kept) return x;
    return .replaced;
}

/// Add `w` to `ws`, joining a write already at its path (§2.4).
fn wsAdd(a: *Writes, ws: *WsBuilder, w: Write) Allocator.Error!void {
    for (ws.items) |*e| {
        if (e.path != w.path) continue;
        if (w.kind == .value) e.kind = .value;
        if (e.edit != w.edit) {
            const j = joinEdit(e.edit, w.edit);
            if (j != e.edit) {
                e.s1 = if (j == w.edit) w.s1 else none;
                e.s2 = if (j == w.edit) w.s2 else none;
            }
            e.edit = j;
        } else if (e.s1 != w.s1 or e.s2 != w.s2) {
            e.edit = .replaced;
            e.s1 = none;
            e.s2 = none;
        }
        return;
    }
    try ws.append(a.gpa, w);
}

fn wsIntern(a: *Writes, ws: []Write) Allocator.Error!u32 {
    std.mem.sort(Write, ws, {}, struct {
        fn less(_: void, x: Write, y: Write) bool {
            return x.path < y.path;
        }
    }.less);
    const mark = a.scratch.items.len;
    defer a.scratch.shrinkRetainingCapacity(mark);
    for (ws) |w| try a.scratch.appendSlice(a.gpa, &.{ w.path, @backingInt(w.kind), @backingInt(w.edit), w.s1, w.s2 });
    return a.wsets.intern(a.gpa, a.scratch.items[mark..]);
}

fn value(p: u32) Write {
    return .{ .path = p, .kind = .value };
}

/// The write set of placing `t` at `p` under `g`, memoised on `(t, p, Γ)`
/// (C1). Prefix closure and nothing past k: a step past k is `value` at the
/// k-prefix.
fn diff(a: *Writes, t: u32, p: u32, g: u32) Error!u32 {
    try a.tick();
    if (a.diff_memo.get(.{ .term = t, .path = p, .gamma = g })) |r| return r;
    var ws: WsBuilder = .empty;
    defer ws.deinit(a.gpa);
    try a.diffInto(t, p, g, &ws);
    const id = try a.wsIntern(ws.items);
    try a.diff_memo.put(a.gpa, .{ .term = t, .path = p, .gamma = g }, id);
    return id;
}

fn diffChild(a: *Writes, t: u32, p: u32, kind: PathKind, x: u32, y: u32, g: u32, ws: *WsBuilder) Error!void {
    // The invariant tag reads rest on (write-sets.md, amended 2026-10-09:
    // tag reads, item 3): a write descends through a constructor step only
    // from the `Con` row, which has written `node p` under `Γ ⊢ tag(p) = C`.
    if (std.debug.runtime_safety and kind == .ctor) {
        if (!a.knowsTag(g, p, x)) std.debug.panic("writes: a descent below {d} through a constructor whose tag is not known", .{p});
        for (ws.items) |w| {
            if (w.path == p and w.kind == .node) break;
        } else std.debug.panic("writes: a descent below {d} through a constructor with no `node` written there", .{p});
    }
    const q = (try a.extend(p, kind, x, y)) orelse return a.wsAdd(ws, value(p));
    var sub: WsBuilder = .empty;
    defer sub.deinit(a.gpa);
    try a.wsGet(try a.diff(t, q, g), &sub, a.gpa);
    for (sub.items) |w| try a.wsAdd(ws, w);
}

fn diffInto(a: *Writes, t: u32, p: u32, g: u32, ws: *WsBuilder) Error!void {
    switch (a.termTag(t)) {
        .same => {
            const q = a.termWord(t, 1);
            if (q == p and !a.hasStarOrUnknown(q)) return;
            try a.wsAdd(ws, value(p));
        },
        .rec => {
            const base = a.termWord(t, 1);
            const rest = a.termWord(t, 2);
            const n = (a.termLen(t) - 3) / 2;
            var extra_fields: ?[]const u32 = null;
            if (base != p) {
                if (base != none) return a.wsAdd(ws, value(p));
                if (rest >= 2) {
                    // B2/N7: every other field of the type at `p` is Fresh.
                    extra_fields = (try a.fieldsAt(p)) orelse return a.wsAdd(ws, value(p));
                }
            }
            try a.wsAdd(ws, .{ .path = p, .kind = .node });
            for (0..n) |i| try a.diffChild(a.termWord(t, @intCast(4 + 2 * i)), p, .field, a.termWord(t, @intCast(3 + 2 * i)), 0, g, ws);
            if (extra_fields) |fields| {
                for (fields) |fld| {
                    var named = false;
                    for (0..n) |i| if (a.termWord(t, @intCast(3 + 2 * i)) == fld) {
                        named = true;
                    };
                    if (named) continue;
                    const q = (try a.extend(p, .field, fld, 0)) orelse return a.wsAdd(ws, value(p));
                    try a.wsAdd(ws, value(q));
                }
            }
        },
        .con => {
            const c = a.termWord(t, 1);
            const n = a.termLen(t) - 2;
            if (n == 0 or !a.knowsTag(g, p, c)) return a.wsAdd(ws, value(p));
            try a.wsAdd(ws, .{ .path = p, .kind = .node });
            for (0..n) |i| try a.diffChild(a.termWord(t, @intCast(2 + i)), p, .ctor, c, @intCast(i), g, ws);
        },
        .tup => {
            try a.wsAdd(ws, .{ .path = p, .kind = .node });
            for (0..a.termLen(t) - 1) |i| try a.diffChild(a.termWord(t, @intCast(1 + i)), p, .tuple, @intCast(i), 0, g, ws);
        },
        .lst => {
            const base = a.termWord(t, 1);
            const edit: Edit = @fromBackingInt(a.termWord(t, 2));
            if (base == p) {
                if (edit != .kept) return a.wsAdd(ws, .{ .path = p, .kind = .value, .edit = edit, .s1 = a.termWord(t, 3), .s2 = a.termWord(t, 4) });
                try a.wsAdd(ws, .{ .path = p, .kind = .node, .edit = .kept });
                for (0..a.lstElems(t)) |i| {
                    const e = a.lstElem(t, @intCast(i));
                    // N2: the element's result diffed against its own root,
                    // and every write rebased to `p[κ]`.
                    const at: u32 = (if (e.index == sym_star) try a.extend(p, .star, 0, 0) else try a.extend(p, .index, e.index, 0)) orelse {
                        try a.wsAdd(ws, value(p));
                        continue;
                    };
                    var sub: WsBuilder = .empty;
                    defer sub.deinit(a.gpa);
                    try a.wsGet(try a.diff(e.term, e.eps, g), &sub, a.gpa);
                    for (sub.items) |w| {
                        var w2 = w;
                        w2.path = try a.rebase(w.path, at);
                        if (a.pathLen(w2.path) < a.pathLen(at) + a.pathLen(w.path)) w2.kind = .value;
                        try a.wsAdd(ws, w2);
                    }
                }
                return;
            }
            if (base == none and edit == .clear) return a.wsAdd(ws, .{ .path = p, .kind = .value, .edit = .clear });
            try a.wsAdd(ws, .{ .path = p, .kind = .value, .edit = .replaced });
        },
        .lst_lit => try a.wsAdd(ws, .{ .path = p, .kind = .value, .edit = .replaced }),
        .alt => {
            for (0..a.altLen(t)) |i| {
                const it = a.altItem(t, @intCast(i));
                const g2 = (try a.gammaJoin(g, it.gamma)) orelse continue;
                var sub: WsBuilder = .empty;
                defer sub.deinit(a.gpa);
                try a.wsGet(try a.diff(it.term, p, g2), &sub, a.gpa);
                for (sub.items) |w| try a.wsAdd(ws, w);
            }
        },
        else => try a.wsAdd(ws, value(p)),
    }
}

/// The prefix closure (§2.4): `node` at every proper prefix.
fn closure(a: *Writes, ws: *WsBuilder) Allocator.Error!void {
    var i: usize = 0;
    while (i < ws.items.len) : (i += 1) {
        var child = ws.items[i].path;
        var q = a.pathParent(child);
        while (q != none) : ({
            child = q;
            q = a.pathParent(q);
        }) {
            var found = false;
            for (ws.items) |w| if (w.path == q) {
                found = true;
            };
            if (found) continue;
            // A `node` the closure adds above a constructor step would claim
            // a tag kept that no `Con` row proved (write-sets.md, amended
            // 2026-10-09: tag reads, item 3).
            if (std.debug.runtime_safety and a.pathKind(child) == .ctor) std.debug.panic("writes: the prefix closure would write `node` above a constructor step at {d}", .{q});
            try ws.append(a.gpa, .{ .path = q, .kind = .node });
        }
    }
}

// ---------------------------------------------------------------------------
// The model's type, for §3.4's full-record row (B2, N7)
// ---------------------------------------------------------------------------

const TyRef = struct {
    m: u32,
    inst: u32,
    /// Type arguments, for the declaring type's parameters.
    env: []const TyRef,
};

const Ty = union(enum) {
    record: TyRef,
    tuple: TyRef,
    nominal: struct { m: u32, d: u32, args: []const TyRef },
    other,
};

fn tyResolve(a: *Writes, r0: TyRef) Allocator.Error!Ty {
    var r = r0;
    var fuel: u32 = 64;
    while (fuel > 0) : (fuel -= 1) {
        const b = a.bir(r.m);
        const inst: Inst.Index = @fromBackingInt(r.inst);
        const data = b.instData(inst);
        switch (b.instTag(inst)) {
            .type_var => {
                const info = Bir.TypeVarInfo.unpack(data.rhs);
                if (info.param == Bir.TypeVarInfo.param_none or info.param >= r.env.len) return .other;
                r = r.env[info.param];
            },
            .type_record => return .{ .record = r },
            .type_tuple => return .{ .tuple = r },
            .type_top, .ext_type => {
                const t = a.typeTarget(r.m, inst) orelse return .other;
                return a.tyDecl(t.m, t.d, &.{}) orelse .other;
            },
            .type_app => {
                const head: Inst.Index = @fromBackingInt(data.lhs);
                const t = a.typeTarget(r.m, head) orelse return .other;
                const arg_insts = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index);
                const args = try a.arena().alloc(TyRef, arg_insts.len);
                for (arg_insts, args) |ai, *x| x.* = .{ .m = r.m, .inst = ai.int(), .env = r.env };
                const decl = a.bir(t.m).decls[t.d];
                if (decl.kind == .type_alias) {
                    const body = decl.annotation.unwrap() orelse return .other;
                    r = .{ .m = t.m, .inst = body.int(), .env = args };
                    continue;
                }
                return .{ .nominal = .{ .m = t.m, .d = t.d, .args = args } };
            },
            else => return .other,
        }
        if (b.instTag(@fromBackingInt(r.inst)) == .type_top or b.instTag(@fromBackingInt(r.inst)) == .ext_type) {}
    }
    return .other;
}

fn tyDecl(a: *Writes, m: u32, d: u32, args: []const TyRef) ?Ty {
    const decl = a.bir(m).decls[d];
    if (decl.kind == .type_alias) {
        const body = decl.annotation.unwrap() orelse return null;
        return a.tyResolve(.{ .m = m, .inst = body.int(), .env = args }) catch null;
    }
    return .{ .nominal = .{ .m = m, .d = d, .args = args } };
}

fn typeTarget(a: *const Writes, m: u32, inst: Inst.Index) ?struct { m: u32, d: u32 } {
    const b = a.bir(m);
    const data = b.instData(inst);
    switch (b.instTag(inst)) {
        .type_top => return .{ .m = m, .d = data.lhs },
        .ext_type => {
            if (data.lhs >= a.in.provenance.len) return null;
            const d = a.in.provenance[data.lhs].typeDecl(data.rhs) orelse return null;
            return .{ .m = data.lhs, .d = d.int() };
        },
        else => return null,
    }
}

/// The type at model path `p`, or null.
fn tyAt(a: *Writes, p: u32) Allocator.Error!?Ty {
    const model = a.model_type orelse return null;
    if (a.rootOf(p) != rho_path) return null;
    var ty = try a.tyResolve(model);
    var buf: [k_limit + 1]u32 = undefined;
    for (a.steps(p, &buf)) |s| {
        const next: TyRef = switch (a.pathKind(s)) {
            .field => blk: {
                const rr = switch (ty) {
                    .record => |rr| rr,
                    else => return null,
                };
                const b = a.bir(rr.m);
                const fields = b.extraSlice(Bir.inlineRange(b.instData(@fromBackingInt(rr.inst))), Bir.Field);
                for (fields) |fld| {
                    if (@backingInt(b.symbol(fld.name)) == a.pathA(s)) break :blk .{ .m = rr.m, .inst = fld.value.int(), .env = rr.env };
                }
                return null;
            },
            .tuple => blk: {
                const rr = switch (ty) {
                    .tuple => |rr| rr,
                    else => return null,
                };
                const b = a.bir(rr.m);
                const items = b.extraSlice(Bir.inlineRange(b.instData(@fromBackingInt(rr.inst))), Inst.Index);
                if (a.pathA(s) >= items.len) return null;
                break :blk .{ .m = rr.m, .inst = items[a.pathA(s)].int(), .env = rr.env };
            },
            .ctor => blk: {
                const n = switch (ty) {
                    .nominal => |n| n,
                    else => return null,
                };
                const c = a.pathA(s);
                if (a.ctor_module[c] != n.m) return null;
                const ct = a.ctorOf(c);
                const b = a.bir(n.m);
                const arg_types = b.extraSlice(.{ .start = ct.args_start, .end = ct.args_end }, Inst.Index);
                if (a.pathB(s) >= arg_types.len) return null;
                break :blk .{ .m = n.m, .inst = arg_types[a.pathB(s)].int(), .env = n.args };
            },
            .index, .star => blk: {
                const n = switch (ty) {
                    .nominal => |n| n,
                    else => return null,
                };
                if (n.args.len != 1 or !std.mem.eql(u8, a.declName(n.m, n.d), "List")) return null;
                break :blk n.args[0];
            },
            else => return null,
        };
        ty = try a.tyResolve(next);
    }
    return ty;
}

/// The field symbols of the record type at `p`, or null.
fn fieldsAt(a: *Writes, p: u32) Allocator.Error!?[]const u32 {
    const ty = (try a.tyAt(p)) orelse return null;
    const rr = switch (ty) {
        .record => |rr| rr,
        else => return null,
    };
    const b = a.bir(rr.m);
    const fields = b.extraSlice(Bir.inlineRange(b.instData(@fromBackingInt(rr.inst))), Bir.Field);
    const out = try a.arena().alloc(u32, fields.len);
    for (fields, out) |fld, *o| o.* = @backingInt(b.symbol(fld.name));
    return out;
}

// ---------------------------------------------------------------------------
// Markup and holes (§3.6)
// ---------------------------------------------------------------------------

/// The parents under which a hole may be baked (§9.1, amended).
const allowlist = [_][]const u8{
    "div",        "span",   "p",      "h1",      "h2",      "h3",      "h4",      "h5",     "h6",   "li",
    "a",          "button", "label",  "td",      "th",      "caption", "summary", "strong", "em",   "b",
    "i",          "small",  "code",   "section", "article", "header",  "footer",  "nav",    "main", "aside",
    "figcaption", "legend", "option", "dt",      "dd",
};

fn evalMarkup(a: *Writes, f: *Frame, inst: Inst.Index, g: u32) Error!u32 {
    const b = a.bir(f.m);
    const root: Bir.ExtraIndex = @fromBackingInt(b.instData(inst).lhs);
    const saved = a.cur_site;
    defer a.cur_site = saved;
    if (a.ctx.mode == .view and a.in.packages[f.m] == .app) try a.visitSite(f, b.insts.items(.main_token)[inst.int()]);
    var d: u32 = 0;
    try a.walkMarkup(f, root, g, &d, null);
    return a.mkFresh(d);
}

/// One visit of the view walk to a markup root (browser-direct.md §5.2).
fn visitSite(a: *Writes, f: *Frame, token: u32) Allocator.Error!void {
    const gop = try a.site_index.getOrPut(a.gpa, .{ .module = f.m, .token = token });
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(a.sites.items.len);
        try a.sites.append(a.gpa, .{ .module = f.m, .token = token });
    }
    const s = &a.sites.items[gop.value_ptr.*];
    s.visits += 1;
    if (a.ctx.in_row > 0) s.row = true;
    if (a.ctx.in_list > 0) s.list = true;
    const top = directKey(f.m, f.decl);
    if (std.mem.indexOfScalar(u64, s.holders.items, top) == null) try s.holders.append(a.gpa, top);
    if (a.holders.items.len > 0) {
        const inner = a.holders.items[a.holders.items.len - 1];
        if (std.mem.indexOfScalar(u64, s.holders.items, inner) == null) try s.holders.append(a.gpa, inner);
    }
    a.cur_site = gop.value_ptr.*;
}

fn isEvent(a: *Writes, m: u32, node: u32) bool {
    const dt = a.dispatchOf(m) orelse return false;
    for (dt.markup) |row| {
        if (row.node == node) return row.kind == .event;
    }
    return false;
}

const Parent = struct { name: []const u8, children: []const Bir.ExtraIndex, index: usize };

fn walkMarkup(a: *Writes, f: *Frame, node: Bir.ExtraIndex, g: u32, d: *u32, parent: ?Parent) Error!void {
    const b = a.bir(f.m);
    switch (b.markupKind(node)) {
        .element => {
            const e = b.extraData(node, Bir.MarkupElement);
            for (b.extraSlice(.{ .start = e.items_start, .end = e.items_end }, Bir.ExtraIndex)) |at| {
                const item = b.extraData(at, Bir.MarkupItem);
                const v = item.value.unwrap() orelse continue;
                const t = try a.eval(f, v, g);
                if (a.isEvent(f.m, @backingInt(at))) continue;
                d.* = try a.depsUnion(d.*, try a.deps(t));
                try a.recordHole(f, item.token, .attribute, v, t, false);
            }
            const children = b.extraSlice(.{ .start = e.children_start, .end = e.children_end }, Bir.ExtraIndex);
            const name = a.in.interner.slice(b.symbol(e.name));
            for (children, 0..) |c, i| try a.walkMarkup(f, c, g, d, .{ .name = name, .children = children, .index = i });
        },
        .fragment => {
            const fr = b.extraData(node, Bir.MarkupFragment);
            for (b.extraSlice(.{ .start = fr.children_start, .end = fr.children_end }, Bir.ExtraIndex)) |c| try a.walkMarkup(f, c, g, d, null);
        },
        .text => {},
        .hole => {
            const h = b.extraData(node, Bir.MarkupHole);
            const t = try a.eval(f, h.value, g);
            d.* = try a.depsUnion(d.*, try a.deps(t));
            var alone = false;
            if (parent) |par| {
                alone = for (allowlist) |n| {
                    if (std.mem.eql(u8, n, par.name)) break true;
                } else false;
                for (par.children, 0..) |sib, i| {
                    if (i == par.index) continue;
                    if (i + 1 != par.index and i != par.index + 1) continue;
                    if (b.markupKind(sib) != .element) alone = false;
                }
            }
            try a.recordHole(f, h.token, .child, h.value, t, alone);
        },
        .component => {
            const c = b.extraData(node, Bir.MarkupComponent);
            const callee = try a.eval(f, c.callee, g);
            var pairs: std.ArrayList([2]u32) = .empty;
            defer pairs.deinit(a.gpa);
            for (b.extraSlice(.{ .start = c.props_start, .end = c.props_end }, Bir.ExtraIndex)) |at| {
                const item = b.extraData(at, Bir.MarkupItem);
                const v = if (item.value.unwrap()) |vi| try a.eval(f, vi, g) else try a.freshEmpty();
                if (item.name.unwrap() != null) try pairs.append(a.gpa, .{ @backingInt(b.symbol(item.name)), v });
            }
            var cd: u32 = 0;
            for (b.extraSlice(.{ .start = c.children_start, .end = c.children_end }, Bir.ExtraIndex)) |ch| try a.walkMarkup(f, ch, g, &cd, null);
            const props = if (c.spread.unwrap()) |s| try a.recordUpdate(try a.eval(f, s, g), pairs.items) else try a.mkRec(none, 2 + cd, pairs.items);
            const r = try a.apply(callee, &.{props}, g);
            d.* = try a.depsUnion(d.*, try a.deps(r));
        },
        .@"for", .show => {
            const fm = b.extraData(node, Bir.MarkupForm);
            var list: u32 = try a.freshEmpty();
            if (fm.list.unwrap()) |l| {
                list = try a.eval(f, l, g);
                d.* = try a.depsUnion(d.*, try a.deps(list));
                try a.recordHole(f, fm.token, .each, l, list, false);
                const form: Form = if (b.markupKind(node) == .show) .show else if (fm.mode == .literal_false) .for_positional else .for_keyed;
                try a.noteEach(f, fm.token, form, list);
            }
            if (fm.fallback.unwrap()) |fb| d.* = try a.depsUnion(d.*, try a.deps(try a.eval(f, fb, g)));
            if (fm.row == Bir.none_extra) return;
            const row = b.extraData(@fromBackingInt(fm.row), Bir.MarkupRow);
            const fun = try a.eval(f, row.function, g);
            const is_for = b.markupKind(node) == .@"for";
            const item = if (is_for) blk: {
                if (a.listBase(list)) |p| break :blk try a.mkSameStep(p, .star, 0, 0);
                break :blk try a.mkFresh(try a.deps(list));
            } else try a.proj(list, .ctor, a.ctor_just, 0);
            // A keyed row's key path (§8.1's static-key).
            var key_path: u32 = none;
            if (is_for) if (fm.keyed.unwrap()) |k| if (fm.mode == .key_function) {
                const kf = try a.eval(f, k, g);
                const kv = try a.apply(kf, &.{item}, g);
                if (a.termTag(kv) == .same) key_path = a.termWord(kv, 1);
            };
            const saved = a.ctx.row_key;
            a.ctx.row_key = key_path;
            defer a.ctx.row_key = saved;
            const arity = if (a.termTag(fun) == .fun) a.funArity(fun) else 1;
            const index = try a.mkFresh(try a.deps(list));
            const args = [_]u32{ item, index };
            if (is_for) a.ctx.in_row += 1;
            defer if (is_for) {
                a.ctx.in_row -= 1;
            };
            const r = try a.apply(fun, args[0..@min(arity, 2)], g);
            d.* = try a.depsUnion(d.*, try a.deps(r));
        },
    }
}

/// The model paths a value reads (§3.6): its dependencies, with each
/// callback root replaced by the list position it stands for.
fn anchors(a: *Writes, t: u32, out: *std.ArrayList(u32)) Error!void {
    const d = try a.deps(t);
    for (0..a.deps_t.len(d)) |i| try a.anchorPath(a.deps_t.word(d, i), out, 0);
}

fn anchorPath(a: *Writes, p: u32, out: *std.ArrayList(u32), depth: u32) Error!void {
    const root = a.rootOf(p);
    switch (a.pathKind(root)) {
        .rho => {
            if (std.mem.indexOfScalar(u32, out.items, p) == null) try out.append(a.gpa, p);
            // `ρ.rows[model.sel]` also reads `ρ.sel`: which element is shown
            // is what the index says (write-sets.md §3.6, amended
            // 2026-10-09 for S0).
            if (depth > 16) return;
            var buf: [k_limit + 1]u32 = undefined;
            for (a.steps(p, &buf)) |s| {
                if (a.pathKind(s) != .index or a.symKind(a.pathA(s)) != .expr) continue;
                const d = try a.deps(a.symWord(a.pathA(s), 3));
                for (0..a.deps_t.len(d)) |i| try a.anchorPath(a.deps_t.word(d, i), out, depth + 1);
            }
        },
        .eps, .iota => {
            if (depth > 16) return a.anchorPath(rho_path, out, depth);
            const id = a.pathA(root);
            const base = a.root_base.items[id];
            if (a.root_base_is_deps.items[id]) {
                for (0..a.deps_t.len(base)) |i| try a.anchorPath(a.deps_t.word(base, i), out, depth + 1);
                return;
            }
            if (a.pathKind(root) == .iota) return a.anchorPath(base, out, depth + 1);
            try a.anchorPath(try a.rebase(p, base), out, depth + 1);
        },
        else => {},
    }
}

/// Whether the hole's expression is exactly a model path (§9.1:
/// `tree.pathOf`, a local read through field and tuple accesses).
fn isPathExpr(a: *Writes, m: u32, inst: Inst.Index) bool {
    const b = a.bir(m);
    return switch (b.instTag(inst)) {
        .local => true,
        .field_access, .tuple_index => a.isPathExpr(m, @fromBackingInt(b.instData(inst).lhs)),
        else => false,
    };
}

fn recordHole(a: *Writes, f: *Frame, token: u32, kind: HoleKind, inst: Inst.Index, t: u32, alone: bool) Error!void {
    if (a.ctx.mode != .view) return;
    if (a.in.packages[f.m] != .app) return;
    const gop = try a.hole_index.getOrPut(a.gpa, .{ .module = f.m, .token = token });
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(a.holes.items.len);
        try a.holes.append(a.gpa, .{ .module = f.m, .token = token, .kind = kind, .alone = alone, .site = a.cur_site });
    }
    const h = &a.holes.items[gop.value_ptr.*];
    var reads: std.ArrayList(u32) = .empty;
    defer reads.deinit(a.gpa);
    try a.anchors(t, &reads);
    for (reads.items) |r| if (std.mem.indexOfScalar(u32, h.reads.items, r) == null) try h.reads.append(a.gpa, r);
    // Bake eligibility, per visit.
    const b = a.bir(f.m);
    var lp: u32 = none - 1;
    if ((kind == .child or kind == .attribute) and a.isPathExpr(f.m, inst) and a.termTag(t) == .same and a.rootOf(a.termWord(t, 1)) == rho_path) {
        lp = a.termWord(t, 1);
    } else if (kind == .child and b.instTag(inst) == .string) {
        lp = HoleAcc.string_literal;
        h.lit_term = t;
    }
    if (lp == none - 1) h.literal_ok = false;
    if (h.literal_path == HoleAcc.unvisited) h.literal_path = lp else if (h.literal_path != lp) h.literal_ok = false;
    if (a.ctx.row_key == none) h.in_row = false else if (std.mem.indexOfScalar(u32, h.key_paths.items, a.ctx.row_key) == null) try h.key_paths.append(a.gpa, a.ctx.row_key);
}

/// An `each` hole's form, and the one model path its value is on every
/// visit (browser-direct.md §6.2: the scripts apply to a `For` whose `each`
/// is exactly a model path).
fn noteEach(a: *Writes, f: *Frame, token: u32, form: Form, t: u32) Error!void {
    if (a.ctx.mode != .view) return;
    if (a.in.packages[f.m] != .app) return;
    const i = a.hole_index.get(.{ .module = f.m, .token = token }) orelse return;
    const h = &a.holes.items[i];
    h.form = form;
    var p: u32 = none;
    if (a.termTag(t) == .same) {
        var reads: std.ArrayList(u32) = .empty;
        defer reads.deinit(a.gpa);
        try a.anchors(t, &reads);
        if (reads.items.len == 1) p = reads.items[0];
    }
    if (h.each_path == HoleAcc.unvisited) h.each_path = p else if (h.each_path != p) h.each_path = none;
}

/// Whether `t` is a function §9.1 composes at compile time: a constructor,
/// a constructor under a placeholder (`λx → C a x`), or a choice of those.
fn ctorShape(a: *Writes, t: u32) bool {
    switch (a.termTag(t)) {
        .fun => {
            const kind: FunKind = @fromBackingInt(a.termWord(t, 1));
            switch (kind) {
                .ctor => return true,
                .lambda => {
                    const m = a.termWord(t, 2);
                    const b = a.bir(m);
                    const body: Inst.Index = @fromBackingInt(b.instData(@fromBackingInt(a.termWord(t, 4))).rhs);
                    if (b.instTag(body) != .call) return false;
                    return a.ctorTarget(m, @fromBackingInt(b.instData(body).lhs)) != null;
                },
                else => return false,
            }
        },
        .alt => {
            if (a.altLen(t) == 0) return false;
            for (0..a.altLen(t)) |i| if (!a.ctorShape(a.altItem(t, @intCast(i)).term)) return false;
            return true;
        },
        else => return false,
    }
}

/// Record the message paths `t` holds whole — a `Same` of one, inside the
/// structures `t` builds — where the key's walk lets the value out
/// (browser-direct.md §11's `msg whole`). A `Fresh` is not looked into: a
/// closure's environment is its whole frame, `msg` included, so its deps
/// name the message whether or not the closure reads it.
fn noteMu(a: *Writes, t: u32) Allocator.Error!void {
    // A walk's visited terms: a column stamped with this walk's number.
    a.mu_walk +%= 1;
    if (a.mu_walk == 0) {
        @memset(a.mu_seen.items, 0);
        a.mu_walk = 1;
    }
    try a.noteMuIn(t);
}

fn noteMuIn(a: *Writes, t: u32) Allocator.Error!void {
    if (t >= a.mu_seen.items.len) try a.mu_seen.appendNTimes(a.gpa, 0, t + 1 - a.mu_seen.items.len);
    if (a.mu_seen.items[t] == a.mu_walk) return;
    a.mu_seen.items[t] = a.mu_walk;
    switch (a.termTag(t)) {
        .same => try a.noteMuPath(a.termWord(t, 1)),
        .rec => {
            var i: u32 = 3;
            while (i < a.termLen(t)) : (i += 2) try a.noteMuIn(a.termWord(t, i + 1));
        },
        .con, .app => {
            var i: u32 = if (a.termTag(t) == .con) 2 else 1;
            while (i < a.termLen(t)) : (i += 1) try a.noteMuIn(a.termWord(t, i));
        },
        .tup, .lst_lit => for (1..a.termLen(t)) |i| try a.noteMuIn(a.termWord(t, i)),
        .lst => for (0..a.lstElems(t)) |i| try a.noteMuIn(a.lstElem(t, @intCast(i)).term),
        .alt => for (0..a.altLen(t)) |i| try a.noteMuIn(a.altItem(t, @intCast(i)).term),
        else => {},
    }
}

fn noteMuPath(a: *Writes, p: u32) Allocator.Error!void {
    if (a.pathKind(a.rootOf(p)) != .mu) return;
    if (std.mem.indexOfScalar(u32, a.mu_escapes.items, p) == null) try a.mu_escapes.append(a.gpa, p);
}

// ---------------------------------------------------------------------------
// Conflict (§2.5)
// ---------------------------------------------------------------------------

fn stepMayCoincide(a: *const Writes, x: u32, y: u32) bool {
    if (x == y) return true;
    const kx = a.pathKind(x);
    const ky = a.pathKind(y);
    const lx = kx == .index or kx == .star;
    const ly = ky == .index or ky == .star;
    if (lx and ly) {
        if (kx == .star or ky == .star) return true;
        return a.symMayCoincide(a.pathA(x), a.pathA(y));
    }
    return kx == ky and a.pathA(x) == a.pathA(y) and a.pathB(x) == a.pathB(y);
}

/// `p ⊑̃ q`: `p` may be a prefix of `q`.
fn mayPrefix(a: *const Writes, p: u32, q: u32) bool {
    const lp = a.pathLen(p);
    const lq = a.pathLen(q);
    if (lp > lq) return false;
    if (a.rootOf(p) != a.rootOf(q)) return false;
    var bp: [k_limit + 1]u32 = undefined;
    var bq: [k_limit + 1]u32 = undefined;
    const sp = a.steps(p, &bp);
    const sq = a.steps(q, &bq);
    for (sp, 0..) |s, i| if (!a.stepMayCoincide(s, sq[i])) return false;
    return true;
}

pub fn conflicts(a: *const Writes, r: u32, ws: []const Write) bool {
    // A tag read at `p` conflicts with a `value` write at `p` or at a
    // prefix of it, and with nothing else: a `node` write keeps the tag, and
    // a write below `p` is under a `node` at `p` (amended 2026-10-09).
    if (a.isTagRead(r)) {
        const p = a.pathParent(r);
        for (ws) |w| if (w.kind == .value and a.mayPrefix(w.path, p)) return true;
        return false;
    }
    for (ws) |w| {
        switch (w.kind) {
            .value => if (a.mayPrefix(w.path, r) or a.mayPrefix(r, w.path)) return true,
            .node => if (a.pathLen(w.path) == a.pathLen(r) and a.mayPrefix(w.path, r)) return true,
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Programs (§1.1)
// ---------------------------------------------------------------------------

const Fields = struct { m: u32, frame_decl: u32, init: ?Inst.Index = null, update: ?Inst.Index = null, view: ?Inst.Index = null };

fn programKind(a: *Writes, m: u32, inst: Inst.Index) ?ProgramKind {
    const t = a.valueTarget(m, inst) orelse return null;
    if (a.in.packages[t.m] != .platform) return null;
    const mod = a.in.module_names[t.m];
    const name = a.declName(t.m, t.d);
    if (std.mem.eql(u8, mod, "Tea")) {
        if (std.mem.eql(u8, name, "sandbox")) return .sandbox;
        if (std.mem.eql(u8, name, "element")) return .element;
        if (std.mem.eql(u8, name, "document")) return .document;
        if (std.mem.eql(u8, name, "application")) return .application;
    }
    if (std.mem.eql(u8, mod, "Browser") and std.mem.eql(u8, name, "program")) return .program;
    return null;
}

fn isPlatformCall(a: *Writes, m: u32, inst: Inst.Index) bool {
    const b = a.bir(m);
    if (b.instTag(inst) != .call) return false;
    const t = a.valueTarget(m, @fromBackingInt(b.instData(inst).lhs)) orelse return false;
    if (a.in.packages[t.m] != .platform) return false;
    const mod = a.in.module_names[t.m];
    return std.mem.eql(u8, mod, "Tea") or std.mem.eql(u8, mod, "Browser");
}

/// The record of a program call's argument: inline, or a top-level value
/// whose body is that literal.
fn programRecord(a: *Writes, m: u32, d: u32, arg: Inst.Index) ?Fields {
    const b = a.bir(m);
    if (b.instTag(arg) == .record) {
        var out: Fields = .{ .m = m, .frame_decl = d };
        for (b.extraSlice(Bir.inlineRange(b.instData(arg)), Bir.Field)) |fld| {
            const name = a.in.interner.slice(b.symbol(fld.name));
            if (std.mem.eql(u8, name, "init")) out.init = fld.value;
            if (std.mem.eql(u8, name, "update")) out.update = fld.value;
            if (std.mem.eql(u8, name, "view")) out.view = fld.value;
        }
        return out;
    }
    if (b.instTag(arg) == .top) {
        const d2 = b.instData(arg).lhs;
        const decl = b.decls[d2];
        if (decl.kind != .value or decl.params != 0) return null;
        const body = decl.body.unwrap() orelse return null;
        if (b.instTag(body) != .record) return null;
        return a.programRecord(m, d2, body);
    }
    return null;
}

fn isFunctionField(a: *Writes, m: u32, inst: Inst.Index) bool {
    const b = a.bir(m);
    if (b.instTag(inst) == .lambda) return true;
    const t = a.valueTarget(m, inst) orelse return false;
    const decl = a.bir(t.m).decls[t.d];
    return decl.kind == .value and decl.params > 0;
}

pub const Run = struct {
    programs: []const Program,
};

/// Analyse every program whose `main` is in a target module, in module
/// index order.
pub fn run(a: *Writes) Allocator.Error!Run {
    var programs: std.ArrayList(Program) = .empty;
    const n = a.in.graph.count();
    for (0..n) |mi| {
        const m: u32 = @intCast(mi);
        if (!a.in.targets[m] or a.in.packages[m] != .app) continue;
        const b = a.bir(m);
        for (b.decls, 0..) |decl, di| {
            if (decl.kind != .value or decl.params != 0) continue;
            if (!std.mem.eql(u8, a.declName(m, @intCast(di)), "main")) continue;
            const body = decl.body.unwrap() orelse continue;
            a.programsOf(m, @intCast(di), body, &programs) catch |err| switch (err) {
                // `programsOf` turns W into the top program; nothing else spends it.
                error.WorkCap => unreachable,
                else => |e| return e,
            };
        }
    }
    // Several programs written in one declaration are numbered in order.
    for (programs.items, 0..) |*p, i| {
        var same: u32 = 0;
        var at: u32 = 0;
        for (programs.items, 0..) |q, j| {
            if (q.module != p.module or q.decl != p.decl) continue;
            if (j < i) at += 1;
            same += 1;
        }
        p.index = if (same > 1) at else null;
    }
    return .{ .programs = programs.items };
}

fn programsOf(a: *Writes, m: u32, d: u32, body: Inst.Index, out: *std.ArrayList(Program)) Error!void {
    const b = a.bir(m);
    // A top-level value of this module that holds the program call.
    if (b.instTag(body) == .top) {
        const d2 = b.instData(body).lhs;
        const decl = b.decls[d2];
        if (decl.kind != .value or decl.params != 0) return;
        if (std.mem.indexOfScalar(u64, a.active.items, (@as(u64, 3) << 62) | d2) != null) return;
        try a.active.append(a.gpa, (@as(u64, 3) << 62) | d2);
        defer _ = a.active.pop();
        return a.programsOf(m, d2, decl.body.unwrap() orelse return, out);
    }
    if (b.instTag(body) != .call) return;
    const data = b.instData(body);
    const callee: Inst.Index = @fromBackingInt(data.lhs);
    const args = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index);
    if (a.valueTarget(m, callee)) |t| if (a.in.packages[t.m] == .platform and std.mem.eql(u8, a.in.module_names[t.m], "Browser")) {
        const name = a.declName(t.m, t.d);
        // `Browser.programs [ … ]`: each mounted program on its own.
        if (std.mem.eql(u8, name, "programs") and args.len == 1 and b.instTag(args[0]) == .list) {
            for (b.extraSlice(Bir.inlineRange(b.instData(args[0])), Inst.Index)) |item| try a.programsOf(m, d, item, out);
            return;
        }
        // `Browser.mountAt p id`: the program `p`, mounted elsewhere.
        if (std.mem.eql(u8, name, "mountAt") and args.len == 2) return a.programsOf(m, d, args[0], out);
    };
    if (!a.isPlatformCall(m, body)) return;
    try out.append(a.arena(), try a.programOfCall(m, d, body));
}

/// The program a call of a platform's program constructor makes, analysed
/// (§1.1): unrecognised when the constructor or the record is not of the
/// required shape.
fn programOfCall(a: *Writes, m: u32, d: u32, body: Inst.Index) Error!Program {
    const b = a.bir(m);
    const data = b.instData(body);
    const callee: Inst.Index = @fromBackingInt(data.lhs);
    const args = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index);
    const kind = a.programKind(m, callee);
    const fields: ?Fields = if (kind != null and args.len == 1) a.programRecord(m, d, args[0]) else null;
    var recognised = kind != null and fields != null;
    if (fields) |fs| {
        if (fs.update == null or fs.view == null or fs.init == null) recognised = false;
        if (fs.update) |u| if (!a.isFunctionField(fs.m, u)) {
            recognised = false;
        };
        if (fs.view) |v| if (!a.isFunctionField(fs.m, v)) {
            recognised = false;
        };
    }
    var prog = a.analyseProgram(m, kind orelse .sandbox, if (recognised) fields else null, fields) catch |err| switch (err) {
        // Every walk catches W itself; should one ever not, the program is
        // the top — one key writing ρ, its view cut short — never an error.
        error.WorkCap => Program{
            .module = m,
            .decl = d,
            .index = null,
            .kind = kind orelse .sandbox,
            .recognised = recognised,
            .type_module = none,
            .type_inst = none,
            .init_literals = &.{},
            .keys = try a.arena().dupe(Key, &.{.{ .steps = &.{}, .writes = try a.arena().dupe(Write, &.{value(rho_path)}), .caps = .{ .w = true } }}),
            .summaries = &.{},
            .holes = &.{},
            .view_capped = true,
        },
        else => |e| return e,
    };
    prog.decl = d;
    return prog;
}

/// One program constructor's call, found where it stands, and its program.
pub const Call = struct { module: u32, inst: u32, program: Program };

/// Every call of a program constructor in a value declaration of an
/// application module, in module index and instruction order, each
/// analysed as a program of its own: what a markup lowering that compiles
/// programs whole consumes (`browser-direct.md` §11.1). Unlike `run`, it
/// does not start from `main`, so a program a function builds is found too.
pub fn runCalls(a: *Writes) Allocator.Error![]const Call {
    var calls: std.ArrayList(Call) = .empty;
    const n = a.in.graph.count();
    for (0..n) |mi| {
        const m: u32 = @intCast(mi);
        if (a.in.packages[m] != .app) continue;
        const b = a.bir(m);
        const tags = b.insts.items(.tag);
        const data = b.insts.items(.data);
        for (b.decls, 0..) |decl, di| {
            if (!decl.kind.isValue()) continue;
            var at = decl.inst_start.int();
            while (at < decl.inst_end.int()) : (at += 1) {
                if (tags[at] != .call) continue;
                if (a.programKind(m, @fromBackingInt(data[at].lhs)) == null) continue;
                const prog = a.programOfCall(m, @intCast(di), @fromBackingInt(@intCast(at))) catch |err| switch (err) {
                    error.WorkCap => unreachable,
                    else => |e| return e,
                };
                try calls.append(a.arena(), .{ .module = m, .inst = @intCast(at), .program = prog });
            }
        }
    }
    return calls.items;
}

/// A constructor id's module and its index among that module's `Bir.ctors`.
pub fn ctorPlace(a: *const Writes, c: u32) struct { module: u32, index: u32 } {
    const m = a.ctor_module[c];
    return .{ .module = m, .index = c - a.ctor_base[m] };
}

fn analyseProgram(a: *Writes, m: u32, kind: ProgramKind, fields: ?Fields, view_fields: ?Fields) Error!Program {
    // Each program is analysed as if it were alone (§7): a write set depends
    // on the program's model type (§3.4's full-record row), and a summary's
    // caps are listed for the program that reached it.
    a.diff_memo.clearRetainingCapacity();
    @memset(a.summaries, .absent);
    @memset(a.summary_caps, .{});
    @memset(a.top_values, none);
    a.ctx = .{ .mode = .closed };
    a.inst_depth = 0;
    for (a.holes.items) |*h| {
        h.reads.deinit(a.gpa);
        h.key_paths.deinit(a.gpa);
    }
    a.holes.clearRetainingCapacity();
    a.hole_index.clearRetainingCapacity();
    for (a.sites.items) |*st| st.holders.deinit(a.gpa);
    a.sites.clearRetainingCapacity();
    a.site_index.clearRetainingCapacity();
    a.cur_site = none;
    a.recursive.clearRetainingCapacity();
    a.mu_escapes.clearRetainingCapacity();
    a.map_sites.clearRetainingCapacity();
    a.model_type = null;
    var prog: Program = .{
        .module = m,
        .decl = 0,
        .index = null,
        .kind = kind,
        .recognised = fields != null,
        .type_module = none,
        .type_inst = none,
        .init_literals = &.{},
        .keys = &.{},
        .summaries = &.{},
        .holes = &.{},
    };
    var init_model: u32 = none;
    if (fields) |fs| {
        var frame = try a.newFrame(fs.m, fs.frame_decl, 0);
        // The model type: `update`'s second parameter, as annotated.
        const upd = fs.update.?;
        const fb = a.bir(fs.m);
        if (fb.instTag(upd) == .lambda and fs.frame_decl < fb.decls.len) {
            const params = fb.extraSlice(fb.subRange(@fromBackingInt(fb.instData(upd).lhs)), Inst.Index);
            if (params.len != 0 and fb.instTag(params[0]) == .pat_var) {
                prog.update_module = fs.m;
                prog.update_param_local = fb.decls[fs.frame_decl].locals_start + fb.instData(params[0]).lhs;
            }
        }
        if (a.valueTarget(fs.m, upd)) |t| {
            prog.update_module = t.m;
            prog.update_decl = t.d;
            const decl = a.bir(t.m).decls[t.d];
            if (decl.annotation.unwrap()) |ann| {
                const ab = a.bir(t.m);
                if (ab.instTag(ann) == .type_fn) {
                    const ps = ab.extraSlice(ab.subRange(@fromBackingInt(ab.instData(ann).lhs)), Inst.Index);
                    if (ps.len == 2) {
                        prog.type_module = t.m;
                        prog.type_inst = ps[1].int();
                        a.model_type = .{ .m = t.m, .inst = ps[1].int(), .env = &.{} };
                        // The message type's constructors, for `(any)`.
                        switch (try a.tyResolve(.{ .m = t.m, .inst = ps[0].int(), .env = &.{} })) {
                            .nominal => |n| prog.msg_ctors = @intCast(a.bir(n.m).declCtors(a.bir(n.m).decls[n.d]).len),
                            else => {},
                        }
                    }
                }
            }
        }
        // init (§3.5).
        a.ctx = .{ .mode = .init };
        init_model = blk: {
            const v = a.eval(&frame, fs.init.?, 0) catch |err| switch (err) {
                error.WorkCap => break :blk try a.freshEmpty(),
                else => |e| return e,
            };
            var r = v;
            if (kind == .application) {
                const fe = try a.freshEmpty();
                r = a.apply(v, &.{ fe, fe }, 0) catch |err| switch (err) {
                    error.WorkCap => break :blk try a.freshEmpty(),
                    else => |e| return e,
                };
            }
            if (kind == .element or kind == .document or kind == .application) r = try a.proj(r, .tuple, 0, 0);
            break :blk r;
        };
        var lits: std.ArrayList(u32) = .empty;
        try a.literalPaths(init_model, rho_path, &lits);
        prog.init_literals = lits.items;
        // What `init` spent is its own: the keys start with a budget of theirs.
        a.ctx = .{ .mode = .closed };
        // Keys (§4.4).
        const update_fun = try a.eval(&frame, upd, 0);
        var keys: std.ArrayList(Key) = .empty;
        var leaves: u32 = 1;
        var path_steps: std.ArrayList(KeyStep) = .empty;
        defer path_steps.deinit(a.gpa);
        try a.keyTree(kind, update_fun, 0, &path_steps, &keys, &leaves);
        prog.keys = keys.items;
    }
    // The view (§3.6).
    if (view_fields) |fs| if (fs.view) |vi| if (a.isFunctionField(fs.m, vi)) {
        var frame = try a.newFrame(fs.m, fs.frame_decl, 0);
        a.ctx = .{ .mode = .view };
        const view_fun = try a.eval(&frame, vi, 0);
        _ = a.applyDirect(view_fun, &.{try a.mkSame(rho_path)}, 0) catch |err| switch (err) {
            error.WorkCap => prog.view_capped = true,
            else => |e| return e,
        };
    };
    a.ctx = .{ .mode = .closed };
    prog.holes = try a.finishHoles(init_model);
    // A view cut short says so, and every hole it met reads ρ: the top,
    // never a partial read set (§6.1).
    if (prog.view_capped) for (prog.holes) |*h| {
        h.reads = try a.arena().dupe(u32, &.{rho_path});
        h.bake = false;
        h.key_paths = &.{};
        h.each_path = none;
    };
    prog.sites = try a.finishSites(prog.holes);
    prog.carriers = .{
        .commands = kind == .element or kind == .document or kind == .application,
        .maps = try a.finishMaps(),
        .msg_whole = a.msgWhole(prog.keys),
    };
    var capped: std.ArrayList(Capped) = .empty;
    for (a.summary_caps, 0..) |c, id| {
        if (!c.w and !c.s and !c.i) continue;
        const mm = a.fnModule(@intCast(id));
        try capped.append(a.arena(), .{ .module = mm, .decl = @as(u32, @intCast(id)) - a.fn_base[mm], .caps = c });
    }
    prog.summaries = capped.items;
    return prog;
}

/// Apply a function value directly: walk a top-level function's body rather
/// than instantiate its summary, so the key's facts select arms and the
/// view's holes are seen.
fn applyDirect(a: *Writes, fun: u32, args: []const u32, g: u32) Error!u32 {
    if (a.termTag(fun) == .fun and @as(FunKind, @fromBackingInt(a.termWord(fun, 1))) == .top) {
        return a.direct(a.termWord(fun, 2), a.termWord(fun, 3), args, g);
    }
    return a.apply(fun, args, g);
}

fn evalKey(a: *Writes, kind: ProgramKind, update_fun: u32, g: u32) Error!struct { writes: []Write, caps: Caps, split: u32 } {
    a.ctx = .{ .mode = .key };
    a.split_ctors.clearRetainingCapacity();
    a.inst_depth = 0;
    var ws: WsBuilder = .empty;
    defer ws.deinit(a.gpa);
    const msg = try a.mkSame(mu_path);
    const model = try a.mkSame(rho_path);
    const ok = blk: {
        var r = a.applyDirect(update_fun, &.{ msg, model }, g) catch |err| switch (err) {
            error.WorkCap => break :blk false,
            else => |e| return e,
        };
        if (kind == .element or kind == .document or kind == .application) r = try a.proj(r, .tuple, 0, 0);
        r = try a.capSize(r);
        // A message placed in the model is a value (browser-direct.md §11).
        try a.noteMu(r);
        const id = a.diff(r, rho_path, g) catch |err| switch (err) {
            error.WorkCap => break :blk false,
            else => |e| return e,
        };
        try a.wsGet(id, &ws, a.gpa);
        break :blk true;
    };
    if (!ok) {
        a.ctx.caps.w = true;
        ws.clearRetainingCapacity();
        try ws.append(a.gpa, value(rho_path));
    }
    try a.closure(&ws);
    const caps = a.ctx.caps;
    const split = if (ok) a.ctx.split_path else none;
    a.ctx = .{ .mode = .closed };
    return .{ .writes = try a.arena().dupe(Write, ws.items), .caps = caps, .split = split };
}

fn keyTree(a: *Writes, kind: ProgramKind, update_fun: u32, g: u32, path_steps: *std.ArrayList(KeyStep), keys: *std.ArrayList(Key), leaves: *u32) Error!void {
    const res = try a.evalKey(kind, update_fun, g);
    if (res.split != none) {
        const ctors = try a.arena().dupe(u32, a.split_ctors.items);
        const sib = a.siblings(ctors[0]);
        const default = ctors.len < sib.count;
        const children: u32 = @as(u32, @intCast(ctors.len)) + @intFromBool(default);
        if (leaves.* - 1 + children <= cap_leaves) {
            leaves.* = leaves.* - 1 + children;
            for (ctors) |c| {
                const g2 = (try a.gammaAdd(g, &.{.{ .kind = .pos, .key = res.split, .val = c }})) orelse continue;
                try path_steps.append(a.gpa, .{ .path = res.split, .ctor = c, .type_ctor = c });
                try a.keyTree(kind, update_fun, g2, path_steps, keys, leaves);
                _ = path_steps.pop();
            }
            if (default) {
                var negs: std.ArrayList(Fact) = .empty;
                defer negs.deinit(a.gpa);
                for (ctors) |c| try negs.append(a.gpa, .{ .kind = .neg, .key = res.split, .val = c });
                if (try a.gammaAdd(g, negs.items)) |g2| {
                    try path_steps.append(a.gpa, .{ .path = res.split, .ctor = none, .covers = sib.count - @as(u32, @intCast(ctors.len)), .type_ctor = ctors[0] });
                    try a.keyTree(kind, update_fun, g2, path_steps, keys, leaves);
                    _ = path_steps.pop();
                }
            }
            return;
        }
        var caps = res.caps;
        caps.l = true;
        try keys.append(a.arena(), .{ .steps = try a.arena().dupe(KeyStep, path_steps.items), .writes = res.writes, .caps = caps });
        return;
    }
    try keys.append(a.arena(), .{ .steps = try a.arena().dupe(KeyStep, path_steps.items), .writes = res.writes, .caps = res.caps });
}

// ---------------------------------------------------------------------------
// init and literals (§3.5)
// ---------------------------------------------------------------------------

fn isLiteral(a: *Writes, t: u32) bool {
    switch (a.termTag(t)) {
        .lit => return true,
        .con => {
            for (2..a.termLen(t)) |i| if (!a.isLiteral(a.termWord(t, i))) return false;
            return true;
        },
        .tup, .lst_lit => {
            for (1..a.termLen(t)) |i| if (!a.isLiteral(a.termWord(t, i))) return false;
            return true;
        },
        .rec => {
            if (a.termWord(t, 1) != none or a.termWord(t, 2) != 0) return false;
            var i: u32 = 3;
            while (i < a.termLen(t)) : (i += 2) if (!a.isLiteral(a.termWord(t, i + 1))) return false;
            return true;
        },
        .lst => return a.termWord(t, 1) == none and @as(Edit, @fromBackingInt(a.termWord(t, 2))) == .clear,
        else => return false,
    }
}

/// The maximal paths `literal(p)` holds at.
fn literalPaths(a: *Writes, t: u32, p: u32, out: *std.ArrayList(u32)) Error!void {
    if (a.isLiteral(t)) return out.append(a.arena(), p);
    switch (a.termTag(t)) {
        .rec => {
            if (a.termWord(t, 1) != none) return;
            var i: u32 = 3;
            while (i < a.termLen(t)) : (i += 2) {
                const q = (try a.mkPathOpt(p, .field, a.termWord(t, i), 0)) orelse continue;
                try a.literalPaths(a.termWord(t, i + 1), q, out);
            }
        },
        .tup => for (1..a.termLen(t)) |i| {
            const q = (try a.mkPathOpt(p, .tuple, @intCast(i - 1), 0)) orelse continue;
            try a.literalPaths(a.termWord(t, i), q, out);
        },
        .con => for (2..a.termLen(t)) |i| {
            const q = (try a.mkPathOpt(p, .ctor, a.termWord(t, 1), @intCast(i - 2))) orelse continue;
            try a.literalPaths(a.termWord(t, i), q, out);
        },
        else => {},
    }
}

fn mkPathOpt(a: *Writes, p: u32, kind: PathKind, x: u32, y: u32) Allocator.Error!?u32 {
    if (a.pathLen(p) >= k_limit) return null;
    return try a.mkPath(p, kind, x, y);
}

/// `init`'s value at a model path, projected through what `init` built.
fn initAt(a: *Writes, t0: u32, p: u32) Error!?u32 {
    var buf: [k_limit + 1]u32 = undefined;
    var t = t0;
    for (a.steps(p, &buf)) |s| {
        switch (a.pathKind(s)) {
            .field, .tuple, .ctor => {},
            else => return null,
        }
        t = try a.proj(t, a.pathKind(s), a.pathA(s), a.pathB(s));
        if (a.termTag(t) == .fresh) return null;
    }
    return t;
}

fn finishHoles(a: *Writes, init_model: u32) Error![]Hole {
    const out = try a.arena().alloc(Hole, a.holes.items.len);
    for (a.holes.items, out) |*h, *o| {
        // A tag read under a whole read of its path or a prefix of it adds
        // nothing: the whole read conflicts with every write the tag read does.
        var n: usize = 0;
        for (h.reads.items) |r| {
            if (a.isTagRead(r) and a.wholeReadAbove(h.reads.items, a.pathParent(r))) continue;
            h.reads.items[n] = r;
            n += 1;
        }
        h.reads.shrinkRetainingCapacity(n);
        std.mem.sort(u32, h.reads.items, {}, std.sort.asc(u32));
        // Bake-eligible (§9.1 as amended — O8 widened, the owner,
        // 2026-10-09): a text hole alone under an allowlisted parent, or an
        // attribute, every visit's expression the same model path whose
        // `init` value the template can hold exactly — a string, an `Int`
        // in the exact range — or, for a text hole, a string literal.
        const shape = h.literal_ok and h.literal_path != HoleAcc.unvisited and
            ((h.kind == .child and h.alone) or (h.kind == .attribute and h.literal_path != HoleAcc.string_literal));
        var bake_text: ?[]const u8 = null;
        if (shape) {
            if (h.literal_path == HoleAcc.string_literal) {
                if (h.reads.items.len == 0) bake_text = try a.bakeText(h.lit_term, h.kind);
            } else if (init_model != none) if (try a.initAt(init_model, h.literal_path)) |v| {
                bake_text = try a.bakeText(v, h.kind);
            };
        }
        o.* = .{
            .module = h.module,
            .token = h.token,
            .kind = h.kind,
            .reads = try a.arena().dupe(u32, h.reads.items),
            .bake = bake_text != null,
            .literal_path = h.literal_path,
            .key_paths = if (h.in_row) try a.arena().dupe(u32, h.key_paths.items) else &.{},
            .site = h.site,
            .form = h.form,
            .each_path = if (h.each_path == HoleAcc.unvisited) none else h.each_path,
            .bake_text = bake_text orelse "",
        };
    }
    return out;
}

/// The text a template holds for literal term `t` shown by a hole of kind
/// `kind`, or null when it cannot hold it exactly (§9.1 as amended, O8
/// widened). A string is any string but one holding NUL, which the HTML
/// parser replaces; the lowering escapes the rest (`&`, `<`, a carriage
/// return; in an attribute `"` too). An empty string is an attribute's
/// value, but no text: a text hole's node exists empty, and a template
/// holding nothing has no node there. An `Int` is printed in decimal when
/// its magnitude is at most 2⁵³: every such integer is a double exactly,
/// and JavaScript prints such a double as exactly these digits, so the page
/// shows what the mount's `String(n)` would. A `Float` is never baked.
fn bakeText(a: *Writes, t: u32, kind: HoleKind) Allocator.Error!?[]const u8 {
    if (t == none or a.termTag(t) != .lit) return null;
    switch (a.termWord(t, 1)) {
        lit_string => {
            const id = a.termWord(t, 2);
            const buf = try a.arena().alloc(u8, a.bytes_t.word(id, 0));
            const text = a.bytesOf(id, buf);
            if (std.mem.indexOfScalar(u8, text, 0) != null) return null;
            if (text.len == 0 and kind != .attribute) return null;
            return text;
        },
        lit_int => {
            const u = @as(u64, a.termWord(t, 2)) | (@as(u64, a.termWord(t, 3)) << 32);
            const n: i64 = @bitCast(u);
            if (@abs(n) > (1 << 53)) return null;
            return try std.fmt.allocPrint(a.arena(), "{d}", .{n});
        },
        else => return null,
    }
}

fn wholeReadAbove(a: *const Writes, reads: []const u32, p: u32) bool {
    for (reads) |r| {
        if (a.isTagRead(r)) continue;
        var q = p;
        while (true) {
            if (q == r) return true;
            q = a.pathParent(q);
            if (q == none) break;
        }
    }
    return false;
}

/// Each site's class (browser-direct.md §5.2, and its S0 amendment), in the
/// order the walk met them; `Hole.site` indexes this.
fn finishSites(a: *Writes, holes: []const Hole) Error![]Site {
    const out = try a.arena().alloc(Site, a.sites.items.len);
    for (a.sites.items, out, 0..) |*s, *o, i| {
        var recursive = false;
        for (s.holders.items) |k| if (std.mem.indexOfScalar(u64, a.recursive.items, k) != null) {
            recursive = true;
        };
        var reads_model = false;
        for (holes) |h| if (h.site == i and h.reads.len > 0) {
            reads_model = true;
        };
        const why: ValueWhy = if (s.list) .list else if (recursive) .recursive else .none;
        const class: SiteClass = if (why != .none)
            .value
        else if (s.row)
            .instanced
        else if (s.visits > 1 and reads_model)
            .shared
        else
            .unique;
        o.* = .{ .module = s.module, .token = s.token, .class = class, .calls = s.visits, .why = why };
    }
    return out;
}

fn finishMaps(a: *Writes) Error![]MapSite {
    var out: std.ArrayList(MapSite) = .empty;
    for (a.map_sites.items) |m| {
        for (out.items) |x| {
            if (x.module == m.module and x.token == m.token) break;
        } else try out.append(a.arena(), m);
    }
    return out.items;
}

/// Whether some key let the message, or a sub-message the key tree splits,
/// out whole (browser-direct.md §11's `msg whole`).
fn msgWhole(a: *Writes, keys: []const Key) bool {
    for (a.mu_escapes.items) |p| {
        if (p == mu_path) return true;
        for (keys) |k| for (k.steps) |s| {
            if (s.path == p) return true;
        };
    }
    return false;
}

// ---------------------------------------------------------------------------
// The S0 stats (browser-direct.md §11, and its S0 amendment)
// ---------------------------------------------------------------------------

/// The program's message constructors, and those under a `*` key.
pub const Constructors = struct { total: u32, star: u32 };

pub fn constructorShare(a: *const Writes, gpa: Allocator, prog: *const Program) Allocator.Error!Constructors {
    if (!prog.recognised) return .{ .total = 1, .star = 1 };
    // Each message constructor as the (split path, constructor) of the last
    // step a module of the program's own package declares.
    const Entry = struct { path: u32, ctor: u32, covers: u32, star: bool };
    var list: std.ArrayList(Entry) = .empty;
    defer list.deinit(gpa);
    for (prog.keys) |k| {
        const star = a.keyClass(k.writes) == .star;
        var e: Entry = .{ .path = none, .ctor = none, .covers = @max(prog.msg_ctors, 1), .star = star };
        var i = k.steps.len;
        while (i > 0) {
            i -= 1;
            const s = k.steps[i];
            if (s.type_ctor == none or a.in.packages[a.ctor_module[s.type_ctor]] != .app) continue;
            e = .{ .path = s.path, .ctor = s.ctor, .covers = s.covers, .star = star };
            break;
        }
        for (list.items) |*x| {
            if (x.path == e.path and x.ctor == e.ctor) {
                x.star = x.star or e.star;
                break;
            }
        } else try list.append(gpa, e);
    }
    var out: Constructors = .{ .total = 0, .star = 0 };
    for (list.items) |e| {
        out.total += e.covers;
        if (e.star) out.star += e.covers;
    }
    return out;
}

/// The (key, group) pairs (§5.2): groups are a site's holes by anchored read
/// set, over holes that read something; pairs are summed over bounded keys.
pub const Pairs = struct { pairs: u32, keys: u32, groups: u32, every: u32 };

pub fn pairCount(a: *const Writes, gpa: Allocator, prog: *const Program) Allocator.Error!Pairs {
    // The groups: one representative hole each.
    var groups: std.ArrayList(usize) = .empty;
    defer groups.deinit(gpa);
    for (prog.holes, 0..) |h, i| {
        if (h.reads.len == 0) continue;
        for (groups.items) |j| {
            const g = prog.holes[j];
            if (g.site == h.site and std.mem.eql(u32, g.reads, h.reads)) break;
        } else try groups.append(gpa, i);
    }
    var out: Pairs = .{ .pairs = 0, .keys = 0, .groups = @intCast(groups.items.len), .every = 0 };
    const calls = try gpa.alloc(u32, groups.items.len);
    defer gpa.free(calls);
    @memset(calls, 0);
    if (prog.recognised) for (prog.keys) |k| {
        if (a.keyClass(k.writes) == .star) continue;
        out.keys += 1;
        for (groups.items, calls) |j, *c| {
            for (prog.holes[j].reads) |r| if (a.conflicts(r, k.writes)) {
                c.* += 1;
                out.pairs += 1;
                break;
            };
        }
    };
    if (out.keys > 0) for (calls) |c| {
        if (c == out.keys) out.every += 1;
    };
    return out;
}

/// Why a key reaches a list's reconciler (§6.3).
pub const Why = union(enum) { tag: Edit, value, prefix: u32, derived, star };

pub const Reach = struct { key: u32, why: Why };

/// The keys that reach the reconciler for `For` hole `h`: by the write at
/// the list's path, a `value` write above it, a conflict with a derived
/// list's reads, or a `*` key.
pub fn reconcilerKeys(a: *const Writes, gpa: Allocator, prog: *const Program, h: *const Hole) Allocator.Error![]Reach {
    var out: std.ArrayList(Reach) = .empty;
    for (prog.keys, 0..) |k, ki| {
        const key: u32 = @intCast(ki);
        if (a.keyClass(k.writes) == .star) {
            try out.append(gpa, .{ .key = key, .why = .star });
            continue;
        }
        if (h.each_path == none) {
            for (h.reads) |r| if (a.conflicts(r, k.writes)) {
                try out.append(gpa, .{ .key = key, .why = .derived });
                break;
            };
            continue;
        }
        const p = h.each_path;
        for (k.writes) |w| {
            if (!a.mayPrefix(w.path, p)) continue;
            if (a.pathLen(w.path) < a.pathLen(p)) {
                if (w.kind == .value) {
                    try out.append(gpa, .{ .key = key, .why = .{ .prefix = w.path } });
                    break;
                }
                continue;
            }
            if (w.kind != .value) continue;
            switch (w.edit) {
                .permute, .replaced => {
                    try out.append(gpa, .{ .key = key, .why = .{ .tag = w.edit } });
                    break;
                },
                .none => {
                    try out.append(gpa, .{ .key = key, .why = .value });
                    break;
                },
                else => {},
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Classes (§8.1)
// ---------------------------------------------------------------------------

pub const KeyClass = enum { exact, indexed, structural, star };

pub fn keyClass(a: *const Writes, ws: []const Write) KeyClass {
    var class: KeyClass = .exact;
    for (ws) |w| {
        if (w.path == rho_path and w.kind == .value) return .star;
    }
    for (ws) |w| {
        switch (w.edit) {
            .remove_some, .permute => class = .structural,
            .none, .kept => {},
            else => if (class == .exact) {
                class = .indexed;
            },
        }
        var q = w.path;
        while (a.pathParent(q) != none) : (q = a.pathParent(q)) {
            switch (a.pathKind(q)) {
                .star => class = .structural,
                .index => if (a.pathA(q) == sym_unknown) {
                    class = .structural;
                } else if (class == .exact) {
                    class = .indexed;
                },
                else => {},
            }
        }
    }
    return class;
}

pub const HoleClass = enum { static, literal, static_key, dynamic };

pub fn holeClass(a: *const Writes, prog: *const Program, h: *const Hole) HoleClass {
    if (!prog.recognised or prog.view_capped) return .dynamic;
    var static = true;
    for (prog.keys) |k| {
        for (h.reads) |r| if (a.conflicts(r, k.writes)) {
            static = false;
        };
        if (!static) break;
    }
    if (static) return if (h.bake) .literal else .static;
    if (h.key_paths.len == 1 and h.reads.len > 0) {
        for (h.reads) |r| if (r != h.key_paths[0]) return .dynamic;
        return .static_key;
    }
    return .dynamic;
}

// ---------------------------------------------------------------------------
// Printing helpers
// ---------------------------------------------------------------------------

/// A structural order of paths (§7): parents first, then steps by text.
pub fn pathLess(a: *const Writes, x: u32, y: u32) bool {
    var bx: [k_limit + 1]u32 = undefined;
    var by: [k_limit + 1]u32 = undefined;
    const sx = a.steps(x, &bx);
    const sy = a.steps(y, &by);
    const rx = a.rootOf(x);
    const ry = a.rootOf(y);
    if (rx != ry) return @backingInt(a.pathKind(rx)) < @backingInt(a.pathKind(ry));
    const n = @min(sx.len, sy.len);
    for (0..n) |i| {
        const o = a.stepOrder(sx[i], sy[i]);
        if (o != .eq) return o == .lt;
    }
    return sx.len < sy.len;
}

fn stepOrder(a: *const Writes, x: u32, y: u32) std.math.Order {
    if (x == y) return .eq;
    const kx = a.pathKind(x);
    const ky = a.pathKind(y);
    if (kx != ky) {
        // A tag read sorts right after its path.
        if (kx == .tag) return .lt;
        if (ky == .tag) return .gt;
        return std.math.order(@backingInt(kx), @backingInt(ky));
    }
    switch (kx) {
        .field => return std.mem.order(u8, a.in.interner.slice(@fromBackingInt(a.pathA(x))), a.in.interner.slice(@fromBackingInt(a.pathA(y)))),
        .tuple => return std.math.order(a.pathA(x), a.pathA(y)),
        .ctor => {
            const o = std.math.order(a.pathA(x), a.pathA(y));
            return if (o != .eq) o else std.math.order(a.pathB(x), a.pathB(y));
        },
        .index => {
            const sx = a.pathA(x);
            const sy = a.pathA(y);
            const kx2 = a.symKind(sx);
            const ky2 = a.symKind(sy);
            if (kx2 != ky2) return std.math.order(@backingInt(kx2), @backingInt(ky2));
            if (kx2 == .lit) return std.math.order(a.symLit(sx), a.symLit(sy));
            if (kx2 == .expr) {
                const o = std.math.order(a.symWord(sx, 1), a.symWord(sy, 1));
                return if (o != .eq) o else std.math.order(a.symWord(sx, 2), a.symWord(sy, 2));
            }
            return .eq;
        },
        else => return .eq,
    }
}

pub fn writePath(a: *const Writes, w: *std.Io.Writer, p: u32) std.Io.Writer.Error!void {
    if (a.isTagRead(p)) {
        try w.writeAll("tag ");
        return a.writePath(w, a.pathParent(p));
    }
    var buf: [k_limit + 1]u32 = undefined;
    const root = a.rootOf(p);
    switch (a.pathKind(root)) {
        .rho => try w.writeAll("ρ"),
        .mu => try w.writeAll("μ"),
        else => try w.writeAll("?"),
    }
    for (a.steps(p, &buf)) |s| {
        switch (a.pathKind(s)) {
            .field => try w.print(".{s}", .{a.in.interner.slice(@fromBackingInt(a.pathA(s)))}),
            .tuple => try w.print(".{d}", .{a.pathA(s)}),
            .ctor => try w.print(".{s}#{d}", .{ a.ctorName(a.pathA(s)), a.pathB(s) }),
            .index => {
                try w.writeByte('[');
                try a.writeSym(w, a.pathA(s));
                try w.writeByte(']');
            },
            .star => try w.writeAll("[*]"),
            else => {},
        }
    }
}

pub fn writeSym(a: *const Writes, w: *std.Io.Writer, s: u32) std.Io.Writer.Error!void {
    switch (a.symKind(s)) {
        .star => try w.writeByte('*'),
        .unknown => try w.writeByte('?'),
        .lit => try w.print("{d}", .{a.symLit(s)}),
        .expr => try a.writeExpr(w, a.symWord(s, 1), @fromBackingInt(a.symWord(s, 2)), 0),
    }
}

/// An index expression in its source spelling, as far as the instructions
/// show it.
fn writeExpr(a: *const Writes, w: *std.Io.Writer, m: u32, inst: Inst.Index, depth: u32) std.Io.Writer.Error!void {
    const b = a.bir(m);
    if (depth > 6) return w.writeAll("…");
    const data = b.instData(inst);
    switch (b.instTag(inst)) {
        .local => {
            const decl = for (b.decls) |d| {
                if (inst.int() >= d.inst_start.int() and inst.int() < d.inst_end.int()) break d;
            } else return w.writeAll("…");
            const l = b.locals[decl.locals_start + data.lhs];
            if (l.name.unwrap()) |s| return w.writeAll(a.in.interner.slice(b.symbols[s]));
            return w.writeAll("_");
        },
        .int => return w.writeAll(b.bytes(inst)),
        .field_access => {
            try a.writeExpr(w, m, @fromBackingInt(data.lhs), depth + 1);
            return w.print(".{s}", .{a.in.interner.slice(b.symbol(@fromBackingInt(data.rhs)))});
        },
        .tuple_index => {
            try a.writeExpr(w, m, @fromBackingInt(data.lhs), depth + 1);
            return w.print(".{d}", .{data.rhs});
        },
        .top, .ext_value => if (a.valueTarget(m, inst)) |t| return w.writeAll(a.declName(t.m, t.d)),
        .call => {
            const args = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Inst.Index);
            if (a.valueTarget(m, @fromBackingInt(data.lhs))) |t| if (args.len == 2 and a.in.packages[t.m] == .core) {
                const name = a.declName(t.m, t.d);
                const op: ?[]const u8 = if (std.mem.eql(u8, name, "add")) "+" else if (std.mem.eql(u8, name, "sub")) "-" else if (std.mem.eql(u8, name, "mul")) "*" else null;
                if (op) |o| {
                    try a.writeExpr(w, m, args[0], depth + 1);
                    try w.print(" {s} ", .{o});
                    return a.writeExpr(w, m, args[1], depth + 1);
                }
            };
        },
        else => {},
    }
    return w.writeAll("…");
}

pub fn writeEdit(a: *const Writes, w: *std.Io.Writer, wr: Write) std.Io.Writer.Error!void {
    const name: []const u8 = switch (wr.edit) {
        .none => return,
        .kept => "kept",
        .append => "append",
        .prepend => "prepend",
        .clear => "clear",
        .remove_some => "removeSome",
        .insert => "insert",
        .remove_at => "removeAt",
        .swap => "swap",
        .set => "set",
        .permute => "permute",
        .replaced => "replaced",
    };
    try w.print(" ⟨{s}", .{name});
    if (wr.s1 != none) {
        try w.writeByte(' ');
        try a.writeSym(w, wr.s1);
    }
    if (wr.s2 != none) {
        try w.writeByte(' ');
        try a.writeSym(w, wr.s2);
    }
    try w.writeAll("⟩");
}

pub fn moduleName(a: *const Writes, m: u32) []const u8 {
    return a.in.module_names[m];
}

/// The model type's name, as `update`'s annotation writes its head.
pub fn writeModelType(a: *const Writes, w: *std.Io.Writer, prog: *const Program) std.Io.Writer.Error!void {
    if (prog.type_module == none) return w.writeAll("?");
    const m = prog.type_module;
    const b = a.bir(m);
    var inst: Inst.Index = @fromBackingInt(prog.type_inst);
    if (b.instTag(inst) == .type_app) inst = @fromBackingInt(b.instData(inst).lhs);
    if (a.typeTarget(m, inst)) |t| return w.print("{s}.{s}", .{ a.in.module_names[t.m], a.declName(t.m, t.d) });
    return switch (b.instTag(inst)) {
        .type_record => w.writeAll("{ … }"),
        .type_tuple => w.writeAll("( … )"),
        else => w.writeAll("?"),
    };
}

pub fn programKindName(k: ProgramKind) []const u8 {
    return switch (k) {
        .sandbox => "Tea.sandbox",
        .program => "Browser.program",
        .element => "Tea.element",
        .document => "Tea.document",
        .application => "Tea.application",
    };
}

pub fn declNameOf(a: *const Writes, m: u32, d: u32) []const u8 {
    return a.declName(m, d);
}

test {
    _ = Core;
}
