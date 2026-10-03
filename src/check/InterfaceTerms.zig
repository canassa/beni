//! Reading interface terms into a store: the one reader behind every
//! instantiation of an imported scheme, constructor, schema member or plan
//! endpoint (checker.md §7, checker-v2.md §14.2).
//!
//! **An alias is expanded from its row.** An `alias` term holds a use's
//! arguments; its body is on the `type_refs` row it names, written once per
//! record, with `var(i)` meaning the alias's parameter `i`. The reader reads
//! the arguments, then the body with `var(i)` bound to argument `i`, and
//! makes the same `alias{type, args, actual}` variable the declaring
//! module's store held. Each `(row, argument roots)` is expanded once per
//! read and shared by every term that names it, as `Types.Builder.aliases`
//! shares an annotation's, so a read costs its distinct applications and
//! never its tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Var = TypeStore.Var;

pub const Error = Allocator.Error;

/// How deep a read may go before it poisons. The writer counts every term a
/// reader walks, alias bodies included, against the same number and
/// reports what does not fit (`Schemes.Writer.max_depth`), so a record the
/// writer wrote never reaches it; only a record mapped from disk that does
/// not describe itself does, and it has no position in the reading module
/// to point a message at.
pub const max_depth = 512;

/// Read `root` with `args` as its quantifiers: a schema member's scheme
/// body, or a plan's endpoint term, instantiated by the caller's choice of
/// variables.
pub fn instantiateRoot(iface: *const Interface, type_ids: []const TypeStore.TypeId, store: *TypeStore, root: Interface.TermIndex, args: []const Var, rank: u32, scratch: Allocator) Error!Var {
    var memo: TermMemo = .{};
    defer memo.deinit(scratch);
    try memo.begin(scratch, iface.terms.len);
    var r: Reader = .{ .iface = iface, .type_ids = type_ids, .store = store, .rank = rank, .scratch = scratch, .fresh = args, .memo = &memo };
    defer r.deinit();
    return r.read(root);
}

/// The `alias` term `root` applied to its arguments (read with `args` as
/// quantifiers), with its body read ONCE and every alias inside that body
/// left unexpanded: an `alias` variable whose expansion is a placeholder.
/// What the interface writer needs to write another module's body without
/// walking the aliases it names (`Types.Builder.canonical`). Null when
/// `root` is not an alias or its row has no body.
pub fn applicationOf(iface: *const Interface, type_ids: []const TypeStore.TypeId, store: *TypeStore, root: Interface.TermIndex, args: []const Var, rank: u32, scratch: Allocator) Error!?Var {
    const t = iface.term(root);
    if (t.tag != .alias) return null;
    const body = iface.aliasBody(t.lhs);
    if (body == .none) return null;
    var memo: TermMemo = .{};
    defer memo.deinit(scratch);
    try memo.begin(scratch, iface.terms.len);
    var r: Reader = .{ .iface = iface, .type_ids = type_ids, .store = store, .rank = rank, .scratch = scratch, .fresh = args, .memo = &memo, .shallow = true };
    defer r.deinit();
    const actual_args = try r.readRange(t.rhs);
    defer scratch.free(actual_args);
    const actual = try r.readBody(body, actual_args);
    return try store.fresh(.{ .alias = .{ .type = r.typeId(t.lhs), .args = try store.addVars(actual_args), .actual = actual } }, rank);
}

/// A reader's memo of an interface's terms, by term index: one variable per
/// term, so a term referenced twice becomes one variable. Kept by a
/// module's check and reused by every instantiation it makes: a slot holds
/// a variable only while its stamp is the current one, so starting a read
/// is one increment, not a clear of a table as long as the whole
/// interface. An alias body read inside a read takes a stamp of its own
/// and gives the outer one back, because the same body terms mean other
/// variables under other arguments; stamps are never reissued, so the
/// outer read's slots stay valid across it.
pub const TermMemo = struct {
    slots: std.ArrayList(Slot) = .empty,
    current: u64 = 0,
    issued: u64 = 0,

    const Slot = struct { stamp: u64 = 0, v: Var = undefined };

    pub fn deinit(m: *TermMemo, gpa: Allocator) void {
        m.slots.deinit(gpa);
    }

    /// A new read over `len` terms: every slot empty.
    pub fn begin(m: *TermMemo, gpa: Allocator, len: usize) Error!void {
        if (m.slots.items.len < len) try m.slots.appendNTimes(gpa, .{}, len - m.slots.items.len);
        _ = m.push();
    }

    /// A fresh stamp; returns the one to give back with `pop`.
    fn push(m: *TermMemo) u64 {
        const saved = m.current;
        m.issued += 1;
        m.current = m.issued;
        return saved;
    }

    fn pop(m: *TermMemo, saved: u64) void {
        m.current = saved;
    }

    fn get(m: *const TermMemo, index: u32) ?Var {
        const slot = m.slots.items[index];
        return if (slot.stamp == m.current) slot.v else null;
    }

    fn put(m: *TermMemo, index: u32, v: Var) void {
        m.slots.items[index] = .{ .stamp = m.current, .v = v };
    }
};

/// `(row, argument roots) →` the alias variable, per read.
const Expansions = std.HashMapUnmanaged([]const u32, Var, KeyContext, std.hash_map.default_max_load_percentage);
const KeyContext = struct {
    pub fn hash(_: KeyContext, key: []const u32) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(key));
    }
    pub fn eql(_: KeyContext, a: []const u32, b: []const u32) bool {
        return std.mem.eql(u32, a, b);
    }
};

pub const Reader = struct {
    iface: *const Interface,
    /// `iface.type_refs` translated into this session (`Types.refIds`).
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    rank: u32,
    scratch: Allocator,
    /// What `var(i)` means where the read is: the scheme's quantifiers, or
    /// inside an alias body the use's arguments.
    fresh: []const Var,
    /// Grown by the caller (`TermMemo.begin`) to the record's term count.
    memo: *TermMemo,
    /// Leave every alias unexpanded (`applicationOf`).
    shallow: bool = false,
    depth: u32 = 0,
    expansions: Expansions = .empty,

    pub fn deinit(r: *Reader) void {
        var keys = r.expansions.keyIterator();
        while (keys.next()) |k| r.scratch.free(k.*);
        r.expansions.deinit(r.scratch);
    }

    pub fn read(r: *Reader, index: Interface.TermIndex) Error!Var {
        if (index == .none or index.int() >= r.iface.terms.len) return r.store.freshErr(r.rank);
        r.depth += 1;
        defer r.depth -= 1;
        if (r.depth > max_depth) return r.store.freshErr(r.rank);
        if (r.memo.get(index.int())) |v| return v;

        const t = r.iface.term(index);
        const v = switch (t.tag) {
            .err => try r.store.freshErr(r.rank),
            .@"var" => if (t.lhs < r.fresh.len) r.fresh[t.lhs] else try r.store.freshErr(r.rank),
            .unit => try r.store.fresh(.{ .structure = .unit }, r.rank),
            .empty_record => try r.store.fresh(.{ .structure = .empty_record }, r.rank),
            .func => blk: {
                const params = try r.readRange(t.lhs);
                defer r.scratch.free(params);
                const range = try r.store.addVars(params);
                const result = try r.read(@fromBackingInt(@intCast(t.rhs)));
                break :blk try r.store.fresh(.{ .structure = .{ .func = .{ .params = range, .result = result } } }, r.rank);
            },
            .app => blk: {
                const args = try r.readRange(t.rhs);
                defer r.scratch.free(args);
                const range = try r.store.addVars(args);
                break :blk try r.store.fresh(.{ .structure = .{ .app = .{ .type = r.typeId(t.lhs), .args = range } } }, r.rank);
            },
            .tuple => blk: {
                const elements = try r.readRange(t.lhs);
                defer r.scratch.free(elements);
                const range = try r.store.addVars(elements);
                break :blk try r.store.fresh(.{ .structure = .{ .tuple = range } }, r.rank);
            },
            .record => blk: {
                const words = r.iface.range(t.lhs);
                const count = words.len / 2;
                const fields = try r.scratch.alloc(TypeStore.Field, count);
                defer r.scratch.free(fields);
                for (0..count) |i| {
                    fields[i] = .{
                        .name = r.iface.symbol(@fromBackingInt(@intCast(words[i * 2]))),
                        .value = try r.read(@fromBackingInt(@intCast(words[i * 2 + 1]))),
                    };
                }
                const range = try r.store.addFields(fields);
                const ext = try r.read(@fromBackingInt(@intCast(t.rhs)));
                break :blk try r.store.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = ext } } }, r.rank);
            },
            .alias => blk: {
                const args = try r.readRange(t.rhs);
                defer r.scratch.free(args);
                break :blk try r.expand(t.lhs, args);
            },
        };
        r.memo.put(index.int(), v);
        return v;
    }

    /// The alias of row `ref` applied to `args`: shared per read by its
    /// row and its arguments' roots.
    fn expand(r: *Reader, ref: u32, args: []const Var) Error!Var {
        const key = try r.scratch.alloc(u32, args.len + 1);
        key[0] = ref;
        for (args, key[1..]) |arg, *k| k.* = r.store.find(arg).int();
        if (r.expansions.get(key)) |v| {
            r.scratch.free(key);
            return v;
        }
        errdefer r.scratch.free(key);
        const body = r.iface.aliasBody(ref);
        const actual = if (r.shallow or body == .none)
            try r.store.freshErr(r.rank)
        else
            try r.readBody(body, args);
        const v = try r.store.fresh(.{ .alias = .{ .type = r.typeId(ref), .args = try r.store.addVars(args), .actual = actual } }, r.rank);
        try r.expansions.put(r.scratch, key, v);
        return v;
    }

    /// Read an alias body with `var(i)` bound to `args[i]`, under a memo
    /// stamp of its own. The depth runs on: the writer counted the body's
    /// terms from the `alias` term that names it.
    fn readBody(r: *Reader, body: Interface.TermIndex, args: []const Var) Error!Var {
        const outer = r.fresh;
        const saved = r.memo.push();
        defer {
            r.memo.pop(saved);
            r.fresh = outer;
        }
        r.fresh = args;
        return r.read(body);
    }

    /// The session `TypeId` an `app` or `alias` operand names. One array
    /// index — the whole point of `Types.ref_ids`. A reference the session
    /// could not resolve, and an operand a record mapped from disk does not
    /// describe, both give `.none`, the poisoned id.
    fn typeId(r: *const Reader, operand: u32) TypeStore.TypeId {
        return if (operand < r.type_ids.len) r.type_ids[operand] else .none;
    }

    fn readRange(r: *Reader, start: u32) Error![]Var {
        const words = r.iface.range(start);
        const out = try r.scratch.alloc(Var, words.len);
        errdefer r.scratch.free(out);
        for (words, out) |word, *v| v.* = try r.read(@fromBackingInt(@intCast(word)));
        return out;
    }
};

/// Copy an interface scheme into `store` at `rank`: one fresh variable per
/// quantifier, then the body rebuilt on top of them.
///
/// `type_ids` is this session's translation of `iface.type_refs`, which is
/// `Types.refIds` of the module the record belongs to. It is passed in
/// rather than resolved here because it is built ONCE per module, when that
/// module is checked, and read on every import use: resolving a reference
/// has to stay one array index however many times a scheme is instantiated
/// (`Interface.TypeRef`, `Types.ref_ids`).
pub fn instantiate(
    iface: *const Interface,
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    scheme_index: u32,
    rank: u32,
    scratch: Allocator,
) Error!Var {
    var memo: TermMemo = .{};
    defer memo.deinit(scratch);
    return instantiateWith(iface, type_ids, store, scheme_index, rank, scratch, &memo, scratch, null);
}

/// `instantiate` with the caller's memo, allocated with `gpa`. When
/// `quantified` is given, it receives the variable made for each
/// quantifier, in the scheme's order: what an effect block's `where` roots
/// are read against (transparent-effects-proposal.md §14.6).
pub fn instantiateWith(
    iface: *const Interface,
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    scheme_index: u32,
    rank: u32,
    scratch: Allocator,
    memo: *TermMemo,
    gpa: Allocator,
    quantified: ?*std.ArrayList(Var),
) Error!Var {
    const s = iface.schemes[scheme_index];
    const fresh = try scratch.alloc(Var, s.quantified_count);
    defer scratch.free(fresh);
    for (fresh, 0..) |*v, i| {
        const q = iface.quantified(s, @intCast(i));
        v.* = try store.fresh(.{ .flex = .{
            .name = iface.quantifiedSymbol(q),
            .kind = @fromBackingInt(@intCast(q.kind)),
            .equatable = q.equatable,
        } }, rank);
    }
    // One store variable per TERM, so a term referenced twice becomes one
    // variable and the sharing the writer preserved survives the crossing.
    try memo.begin(gpa, iface.terms.len);
    var reader: Reader = .{ .iface = iface, .type_ids = type_ids, .store = store, .rank = rank, .scratch = scratch, .fresh = fresh, .memo = memo };
    defer reader.deinit();
    const body = try reader.read(s.body);
    // The constraint blocks LAST, so every quantifier already has its
    // variable and a `var(i)` inside a constraint's type lands on the same
    // one the body uses (static-dispatch-spike.md §6.5 rule 3). Each
    // quantifier gets a FRESH set; the evidence index runs across
    // quantifiers in canonical order (§7.2).
    for (fresh, 0..) |v, i| {
        const q = iface.quantified(s, @intCast(i));
        if (q.constraints_len == 0) continue;
        const built = try scratch.alloc(TypeStore.MethodConstraint, q.constraints_len);
        defer scratch.free(built);
        for (built, 0..) |*c, j| {
            const qc = iface.quantifiedConstraint(q, @intCast(j));
            c.* = .{
                .name = iface.symbol(qc.name),
                .fn_var = try reader.read(qc.type),
                .region = @fromBackingInt(@intCast(0)),
                .origin = .where_clause,
            };
        }
        const set = try store.addConstraints(built);
        const flags = store.flagsOf(store.find(v));
        store.setContent(store.find(v), .{ .flex = .{
            .name = flags.name,
            .kind = flags.kind,
            .equatable = flags.equatable,
            .constraints = set.toOptional(),
        } });
    }
    if (quantified) |out| {
        out.clearRetainingCapacity();
        try out.appendSlice(gpa, fresh);
    }
    return body;
}

/// Copy an imported constructor's type into `store` at `rank`:
/// `arg1 -> … -> argN -> T p0 … pk`, with one fresh variable per parameter
/// of the owning type.
///
/// The mirror of `instantiate`, and the point of `Interface.Ctor.arg_terms`:
/// a dependent builds an imported constructor's type out of the interface
/// alone, never out of the declaring module's `Bir`. `type_id` is what
/// `Types.ofInterface` says the owning type is in THIS session — the
/// interface stores its own `TypeIndex`, which is meaningless anywhere
/// else.
///
/// Null when the constructor has no terms: the declaring module was never
/// checked, or its declaration was too deep to read. The caller poisons.
pub fn instantiateCtor(
    iface: *const Interface,
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    ctor_index: u32,
    type_id: TypeStore.TypeId,
    rank: u32,
    scratch: Allocator,
) Error!?Var {
    var memo: TermMemo = .{};
    defer memo.deinit(scratch);
    return instantiateCtorWith(iface, type_ids, store, ctor_index, type_id, rank, scratch, &memo, scratch);
}

/// `instantiateCtor` with the caller's memo, allocated with `gpa`.
pub fn instantiateCtorWith(
    iface: *const Interface,
    type_ids: []const TypeStore.TypeId,
    store: *TypeStore,
    ctor_index: u32,
    type_id: TypeStore.TypeId,
    rank: u32,
    scratch: Allocator,
    memo: *TermMemo,
    gpa: Allocator,
) Error!?Var {
    if (ctor_index >= iface.ctors.len) return null;
    const c = iface.ctors[ctor_index];
    if (c.arg_terms == Interface.no_terms) return null;
    if (@backingInt(c.type) >= iface.types.len) return null;
    const arity = iface.types[@backingInt(c.type)].arity;

    const fresh = try scratch.alloc(Var, arity);
    defer scratch.free(fresh);
    for (fresh, 0..) |*v, i| {
        const q = iface.ctorQuantified(c, @intCast(i));
        v.* = try store.fresh(.{ .flex = .{
            .name = iface.quantifiedSymbol(q),
            .kind = @fromBackingInt(@intCast(q.kind)),
            .equatable = q.equatable,
        } }, rank);
    }
    try memo.begin(gpa, iface.terms.len);
    var reader: Reader = .{ .iface = iface, .type_ids = type_ids, .store = store, .rank = rank, .scratch = scratch, .fresh = fresh, .memo = memo };
    defer reader.deinit();

    const words = iface.range(c.arg_terms);
    const args = try scratch.alloc(Var, words.len);
    defer scratch.free(args);
    for (words, args) |word, *v| v.* = try reader.read(@fromBackingInt(@intCast(word)));

    // The result: the owning type applied to its own parameters — or, for
    // a record alias's constructor (interface v3), the alias of the
    // RECORD its fields make, argument `i` being field `i` of the row's
    // declaration-order names. That is exactly what the declaring module's
    // own check builds for it (`Types.Builder.apply` on the alias), so a
    // field access or an update on `P 1 "a"` types the same on both sides
    // of the import.
    const params = try store.addVars(fresh);
    const result = switch (c.result) {
        .nominal => try store.fresh(.{ .structure = .{ .app = .{ .type = type_id, .args = params } } }, rank),
        .record_alias => blk: {
            const names = iface.range(c.fields);
            // A row whose names do not match its arguments is a record the
            // writer never produces; poison rather than guess.
            if (names.len != args.len) return null;
            const fields = try scratch.alloc(TypeStore.Field, args.len);
            defer scratch.free(fields);
            for (fields, names, args) |*f, name, arg| {
                if (name >= iface.symbols.len) return null;
                f.* = .{ .name = iface.symbol(@fromBackingInt(@intCast(name))), .value = arg };
            }
            const field_range = try store.addFields(fields);
            const closed = try store.fresh(.{ .structure = .empty_record }, rank);
            const record = try store.fresh(.{ .structure = .{ .record = .{ .fields = field_range, .ext = closed } } }, rank);
            break :blk try store.fresh(.{ .alias = .{ .type = type_id, .args = params, .actual = record } }, rank);
        },
    };
    // A constructor of n fields is an n-ARY function, not a chain of n
    // one-argument ones (language.md §6.7), and a nullary one is the type
    // itself.
    if (args.len == 0) return result;
    const arg_range = try store.addVars(args);
    return try store.fresh(.{ .structure = .{ .func = .{ .params = arg_range, .result = result } } }, rank);
}
