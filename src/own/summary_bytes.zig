//! A module's ownership summaries as bytes: the *summary block*
//! (`docs/design/ownership-checker.md` §28.4).
//!
//! A build on an in-place platform reads the summaries of every module it
//! did not walk — core and the platforms from the checked core, a project's
//! module from its cache entry — from this block, so the block names nothing
//! by a session's id:
//!
//! - a **module** by its package and dotted name, through the table at the
//!   block's head;
//! - a **declaration** by its index in its module's BIR, a **constructor** by
//!   its module and its index in that module's constructor table (the
//!   BIR's constructors, then its tagged schemas', `Ownership.schemaCtorIndex`) — both
//!   functions of the module's source, which the module's key covers;
//! - a **path** step by step, a field by its name;
//! - every other number (a parameter, a fresh number, a lambda's local) as
//!   the summary holds it: none is a session's id.
//!
//! ```
//! "BENIOWN\x00"      8       magic
//! version: u32               `version`
//! modules: u32, then per module: package u8, name (u32 length, bytes)
//! strings: u32, then per string: u32 length, bytes        field names
//! cast types: u32, then per type: u32 length and portable structural node key
//!        children reference earlier entries in this table
//! paths: u32, then per path: steps u32, then per step: kind u8 and
//!        field: string index u32 · tuple: index u32 · ctor: module u32,
//!        constructor u32, argument u32 · level: module u32, declaration
//!        u32, where it stands u8 · cast, cast_level: type-table index u32;
//!        any: scope u32 (0 all, 1 runtime); elem, env: nothing
//! decls: u32, then per declaration: index u32, flags u8 (1: a summary
//!        follows; 2: a value whose type may hold a list), length and summary
//! ```
//!
//! A summary is its scalars, then each component's entries. Sets — `uses`,
//! `res`, `supply`, `funs`, `xreq` and a condition's atoms — are written in
//! a canonical order that compares paths and modules by their table index,
//! and both tables are sorted by content, so **the bytes are a function of
//! the summaries alone**, whatever ids the session that computed them
//! assigned. Lists whose order means something — the function slots and the
//! carried lambdas, which a provenance names by index, and a carried
//! lambda's bindings — keep theirs.
//!
//! Little-endian, read with bounds checks: a block that does not read is
//! `error.Bad`, which the pass treats as no block — the module is then
//! walked if it can be, and is otherwise a callee with no summary, never a
//! wrong one (§16.4's last paragraph).
//! The interface's public variant has magic `BENIOWP\x00`. Its rows name
//! public values and schema namespaces by name, shared provenances name the
//! module and value, constructors name their type and index within it, and
//! carried classes number their captures locally. An opaque path uses wire
//! step 255: module, type name, slot number. The final table lists every
//! exported opaque type's slots in definition order, with its container bits.
//! The cache-only variant also carries an ownership-clean certificate byte
//! after the version; it is not part of the public interface hash.
//!
const std = @import("std");
const Allocator = std.mem.Allocator;
const Ownership = @import("Ownership.zig");
const SourceStore = @import("../SourceStore.zig");

const Summary = Ownership.Summary;
const Prov = Ownership.Prov;
const XAtom = Ownership.XAtom;
const XSum = Ownership.XSum;
const ResEntry = Ownership.ResEntry;
const SupplyEntry = Ownership.SupplyEntry;
const UseEntry = Ownership.UseEntry;
const FunFacts = Ownership.FunFacts;
const Carried = Ownership.Carried;
const StepKind = Ownership.StepKind;

pub const magic = "BENIOWN\x00";

/// Bumped with the rule set (thesis §8.5): a block of another version is
/// absent, never misread. In this PR: 5 transferred private initializers,
/// 6 excluded evidence-driven values, 7 retained entry environments, and
/// 8 preserves unknown/root entry paths while excluding only known init fields.
/// 9 reads `need` through taken elements (§16.4 item 5, amended 2026-10-15).
/// 10 names a tagged schema's constructors after the BIR's own.
/// 11 gives a schema value its two analysis slots, `⟨decoded⟩` and
/// `⟨encoded⟩` (§30.10).
/// 12 drops the coarsened flag and carries a limit's measure (§16.7).
/// 13 names a carried lambda by where it is made, so a fixpoint over the
/// walk's cells settles, and a fixpoint that does not is the `fixpoint` limit
/// (§20.4, amended 2026-10-16).
/// 14 records whether a function parameter's `need` comes only from a send
/// (§23.5, amended 2026-10-17).
/// 15 writes a constructor step's field as a u32, so a field past 63 is
/// named exactly (issue #289; it was a byte, and a field past 63 refused).
/// 16 adds the level marker `⟨T⟩`, a step naming its type (§16.7, #379).
/// 17 carries a record's facts (§31.7, #315): two bytes of bits — `W{F}`
/// with its fields by name, a field read and an object's escape — a
/// provenance's object flag (`◦`), and the records a result holds
/// (`objs`), after `res`; what callbacks are handed of records (`rsupply`),
/// after `supply`; and a function parameter's record `need`, bit 3 of its byte.
/// 18 carries records' exclusive contents (§31.4 item 6): a record
/// condition `rxc` after each `res`, `objs` and supply entry's list ones, and
/// the summary's `rxreq` after its `xreq`.
/// 19 distinguishes value-scoped construction conditions from allocations.
/// 20 carries each write's storage/deep extent (§32 amendment, #670).
/// 21 writes a pairwise-apart atom as its groups (§16.7, amended 2026-10-22, #693).
/// 22 retains recursive function slots and returned classes, including unknown alternatives.
/// 23 carries projection-aware container conditions and their sep_root atom (#720).
/// 24 invalidates rows before declaration-selected hosted entry protocols (#750).
/// 25 preserves conditional container facts for folded Dict tree positions.
/// 26 preserves each callback owned-result requirement's possible writers.
/// 27 writes summary lengths for lazy summary and path reads (§28.4, #814).
/// 28 records full structural type keys and cast signatures (§16.7, #712).
/// 29 makes unknown keys conservative and schema callback endpoints exact.
/// 30 preserves callable environments and fixed cast type contexts.
/// 31 integrates those keys with the lazy summary directory.
/// 32 separates single uncertain views from spatial repeated reads.
/// 33 preserves occurrence conditions before cast read normalization.
/// 34 adds the clean-report certificate and public rows, opaque slots and aliases.
/// 35 marks a schema's `Encoded` endpoint in a level marker (§16.7, #820).
/// 36 invalidates template-row reports: every entry word uses the direct protocol.
/// 37 removes the path cut (§16.7 (c), #286): a path's length is a u32.
/// 38 escapes only what a callback keeps of its supply, in the caller's cells (#749).
pub const version: u32 = 38;

/// A cache hit may skip enforcement only if its previous report was clean.
/// Other platforms also compute reports, but can cache a rejected module.
pub fn clean(bytes: []const u8) bool {
    return bytes.len > 12 and std.mem.eql(u8, bytes[0..8], magic) and
        std.mem.readInt(u32, bytes[8..12], .little) == version and bytes[12] == 1;
}

pub fn certify(bytes: []u8, report: Ownership.ModuleReport) void {
    if (report.limits.len != 0) return;
    for (report.demands) |d| if (!d.record and d.verdict != .accepted) return;
    bytes[12] = 1;
}

pub const Error = error{Bad} || Allocator.Error;

/// One declaration's row of a block, as `write` takes it.
pub const Row = struct {
    decl: u32,
    sum: ?*const Summary,
    /// A value with no parameters whose type may hold a list (§23.6).
    holds_list: bool = false,
};

/// What `read` gives: per declaration of the module, its summary, and
/// whether it is a value that may hold a list.
pub const AliasRow = struct { decl: u32, target: Ownership.Alias, sum: *const Summary };

pub const AliasValue = struct { target: Ownership.Alias, sum: *const Summary };

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

const Writer = struct {
    o: *Ownership,
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    public_module: ?u32 = null,
    env: []const Carried.Bind = &.{},
    fresh_index: std.ArrayList(u32) = .empty,
    fresh_next: [2]u32 = .{ 1, 500 },
    class_index: []const u32 = &.{},
    neutral_fresh: bool = false,
    /// Path id → index in the sorted table.
    path_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Module index → index in the sorted table.
    module_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Field symbol → index in the sorted table.
    string_index: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    cast_index: []u32 = &.{},

    fn freshName(w: *const Writer, raw: u32) u32 {
        if (raw < w.fresh_index.items.len and w.fresh_index.items[raw] != Ownership.none) return w.fresh_index.items[raw];
        return raw;
    }

    fn setFresh(w: *Writer, arena: Allocator, raw: u32, name: u32) Allocator.Error!void {
        if (raw >= w.fresh_index.items.len) try w.fresh_index.appendNTimes(arena, Ownership.none, raw + 1 - w.fresh_index.items.len);
        w.fresh_index.items[raw] = name;
    }

    fn int(w: *Writer, v: u32) Allocator.Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try w.out.appendSlice(w.gpa, &b);
    }

    fn byte(w: *Writer, v: u8) Allocator.Error!void {
        try w.out.append(w.gpa, v);
    }

    fn text(w: *Writer, s: []const u8) Allocator.Error!void {
        try w.int(@intCast(s.len));
        try w.out.appendSlice(w.gpa, s);
    }
};

/// The block of module `m`: `rows` in declaration order. The caller owns
/// the bytes.
pub fn write(o: *Ownership, gpa: Allocator, rows: []const Row) Allocator.Error![]u8 {
    return writeRows(o, gpa, rows, null, &.{});
}

/// The public rows are in interface name order, never BIR declaration order.
pub fn writePublic(o: *Ownership, gpa: Allocator, m: u32, rows: []const Row, aliases: []const AliasRow) Allocator.Error![]u8 {
    return writeRows(o, gpa, rows, m, aliases);
}

fn writeRows(o: *Ownership, gpa: Allocator, rows: []const Row, public_module: ?u32, aliases: []const AliasRow) Allocator.Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var w: Writer = .{ .o = o, .gpa = gpa, .public_module = public_module };
    errdefer w.out.deinit(gpa);

    // Everything the summaries name, first: paths, and through them and the
    // provenances, modules and field names.
    var paths: std.ArrayList(u32) = .empty;
    var modules: std.ArrayList(u32) = .empty;
    var strings: std.ArrayList(u32) = .empty;
    var casts: std.ArrayList(u32) = .empty;
    w.cast_index = try arena.alloc(u32, o.cast_types.items.len);
    @memset(w.cast_index, Ownership.none);
    var seen_path: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var seen_module: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var seen_string: std.AutoHashMapUnmanaged(u32, void) = .empty;
    const Collect = struct {
        o: *Ownership,
        arena: Allocator,
        paths: *std.ArrayList(u32),
        modules: *std.ArrayList(u32),
        strings: *std.ArrayList(u32),
        casts: *std.ArrayList(u32),
        cast_index: []u32,
        seen_path: *std.AutoHashMapUnmanaged(u32, void),
        seen_module: *std.AutoHashMapUnmanaged(u32, void),
        seen_string: *std.AutoHashMapUnmanaged(u32, void),
        public: bool,

        fn path(c: *@This(), p: u32) Allocator.Error!void {
            if ((try c.seen_path.getOrPut(c.arena, p)).found_existing) return;
            try c.paths.append(c.arena, p);
            const ss = c.o.steps(p);
            var si: usize = 0;
            while (si < ss.len) {
                if (c.public) if (try c.o.opaquePrefix(ss[si..])) |slot| {
                    try c.module(slot.module);
                    si += slot.len;
                    continue;
                };
                const s = ss[si];
                si += 1;
                switch (s.kind) {
                    .field => if (!(try c.seen_string.getOrPut(c.arena, s.arg)).found_existing) try c.strings.append(c.arena, s.arg),
                    .ctor => try c.module(c.o.ctorKey(c.o.stepCtor(s.arg)).module),
                    .level => if (c.o.markerType(s.arg) != Ownership.fn_type) try c.module(@intCast(c.o.markerType(s.arg) >> 32)),
                    .cast, .cast_level => try c.cast(s.arg),
                    else => {},
                }
            }
        }

        fn cast(c: *@This(), id: u32) Allocator.Error!void {
            if (c.cast_index[id] != Ownership.none) return;
            c.cast_index[id] = 0;
            for (try c.o.castParts(id)) |part| try c.cast(part.key);
            try c.casts.append(c.arena, id);
        }

        fn module(c: *@This(), m: u32) Allocator.Error!void {
            if ((try c.seen_module.getOrPut(c.arena, m)).found_existing) return;
            try c.modules.append(c.arena, m);
        }

        fn prov(c: *@This(), p: Prov) Allocator.Error!void {
            try c.path(p.path);
            if (p.kind == .shared) try c.module(p.a);
        }

        fn xsum(c: *@This(), x: XSum) Allocator.Error!void {
            for (x.atoms) |a| try c.atom(a);
        }

        fn atom(c: *@This(), a: XAtom) Allocator.Error!void {
            if (a.isApart()) {
                for (a.groups) |g| for (g) |p| try c.prov(p);
                return;
            }
            try c.prov(a.a);
            try c.prov(a.b);
        }

        fn res(c: *@This(), r: ResEntry) Allocator.Error!void {
            try c.path(r.path);
            try c.prov(r.prov);
            try c.xsum(r.xc);
            try c.xsum(r.sc);
            try c.xsum(r.rxc);
        }

        fn summary(c: *@This(), s: *const Summary) Allocator.Error!void {
            if (s.cast_signature != Ownership.none) try c.cast(s.cast_signature);
            for (s.uses) |u| {
                try c.path(u.path);
                if (!(c.public and (try c.o.hiddenFields(u.path, u.fields)) != null))
                    for (u.fields) |f| if (!(try c.seen_string.getOrPut(c.arena, f)).found_existing) try c.strings.append(c.arena, f);
            }
            for (s.res) |r| try c.res(r);
            for (s.objs) |r| try c.res(r);
            for ([_][]const SupplyEntry{ s.supply, s.rsupply }) |entries| for (entries) |e| {
                try c.path(e.path);
                try c.prov(e.prov);
                try c.xsum(e.xc);
                try c.xsum(e.sc);
                try c.xsum(e.rxc);
            };
            for ([_][]const XAtom{ s.xreq, s.rxreq }) |atoms| for (atoms) |a| try c.atom(a);
            for (s.slots) |sl| try c.path(sl[1]);
            for (s.klasses) |k| {
                try c.summary(k.sum);
                for (k.binds) |b| {
                    try c.path(b.path);
                    for (b.provs) |r| try c.res(r);
                }
            }
        }
    };
    var collect: Collect = .{
        .o = o,
        .arena = arena,
        .paths = &paths,
        .modules = &modules,
        .strings = &strings,
        .casts = &casts,
        .cast_index = w.cast_index,
        .seen_path = &seen_path,
        .seen_module = &seen_module,
        .seen_string = &seen_string,
        .public = public_module != null,
    };
    try collect.path(Ownership.eps);
    for (rows) |r| if (r.sum) |s| try collect.summary(s);
    for (aliases) |alias| {
        try collect.module(alias.target.module);
        try collect.summary(alias.sum);
    }

    // The tables, sorted by content.
    const SortModules = struct {
        o: *const Ownership,
        fn less(cx: @This(), x: u32, y: u32) bool {
            const px = cx.o.in.packages[x];
            const py = cx.o.in.packages[y];
            if (px != py) return @backingInt(px) < @backingInt(py);
            return std.mem.lessThan(u8, cx.o.in.module_names[x], cx.o.in.module_names[y]);
        }
    };
    std.mem.sort(u32, modules.items, SortModules{ .o = o }, SortModules.less);
    for (modules.items, 0..) |m, i| try w.module_index.put(arena, m, @intCast(i));
    const SortStrings = struct {
        o: *const Ownership,
        fn less(cx: @This(), x: u32, y: u32) bool {
            return std.mem.lessThan(u8, cx.o.in.interner.slice(@fromBackingInt(x)), cx.o.in.interner.slice(@fromBackingInt(y)));
        }
    };
    std.mem.sort(u32, strings.items, SortStrings{ .o = o }, SortStrings.less);
    for (strings.items, 0..) |s, i| try w.string_index.put(arena, s, @intCast(i));
    // A deterministic DAG table: all children have smaller depth, and at
    // one depth the key contains only already assigned block-local ids.
    std.mem.sort(u32, casts.items, o, struct {
        fn less(ow: *Ownership, x: u32, y: u32) bool {
            return ow.cast_depth.items[x] < ow.cast_depth.items[y];
        }
    }.less);
    const cast_keys = try arena.alloc([]const u8, o.cast_types.items.len);
    var first: usize = 0;
    while (first < casts.items.len) {
        var end = first + 1;
        const depth = o.cast_depth.items[casts.items[first]];
        while (end < casts.items.len and o.cast_depth.items[casts.items[end]] == depth) : (end += 1) {}
        for (casts.items[first..end]) |id| cast_keys[id] = try o.castWireKey(arena, id, w.cast_index);
        std.mem.sort(u32, casts.items[first..end], cast_keys, struct {
            fn less(keys: []const []const u8, x: u32, y: u32) bool {
                return std.mem.lessThan(u8, keys[x], keys[y]);
            }
        }.less);
        for (casts.items[first..end], first..) |id, i| w.cast_index[id] = @intCast(i);
        first = end;
    }

    // A path's key is its steps' keys, so ε (no steps) sorts first.
    const keys = try arena.alloc([]const u8, paths.items.len);
    var key_of: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    for (paths.items, keys) |p, *k| {
        k.* = try pathKey(o, arena, &w, p);
        try key_of.put(arena, p, k.*);
    }
    const SortPaths = struct {
        key_of: *const std.AutoHashMapUnmanaged(u32, []const u8),
        fn less(cx: @This(), x: u32, y: u32) bool {
            return std.mem.lessThan(u8, cx.key_of.get(x).?, cx.key_of.get(y).?);
        }
    };
    std.mem.sort(u32, paths.items, SortPaths{ .key_of = &key_of }, SortPaths.less);
    for (paths.items, 0..) |p, i| try w.path_index.put(arena, p, @intCast(i));

    try w.out.appendSlice(gpa, if (public_module != null) "BENIOWP\x00" else magic);
    try w.int(version);
    if (public_module == null) try w.byte(0);
    try w.int(@intCast(modules.items.len));
    for (modules.items) |m| {
        try w.byte(@backingInt(o.in.packages[m]));
        try w.text(o.in.module_names[m]);
    }
    try w.int(@intCast(strings.items.len));
    for (strings.items) |s| try w.text(o.in.interner.slice(@fromBackingInt(s)));
    try w.int(@intCast(casts.items.len));
    for (casts.items) |id| try w.text(cast_keys[id]);
    try w.int(@intCast(paths.items.len));
    for (paths.items) |p| try w.out.appendSlice(gpa, key_of.get(p).?);

    var count: u32 = 0;
    for (rows) |r| {
        if (r.sum != null or r.holds_list) count += 1;
    }
    try w.int(count);
    for (rows) |r| {
        if (r.sum == null and !r.holds_list) continue;
        if (public_module) |m| try w.text(o.in.interner.slice(o.in.birs[m].symbol(o.in.birs[m].decls[r.decl].name))) else try w.int(r.decl);
        try w.byte(@as(u8, if (r.sum != null) 1 else 0) | @as(u8, if (r.holds_list) 2 else 0));
        if (r.sum) |sum| try writeSizedSummary(&w, arena, sum);
    }
    if (public_module) |m| {
        const iface = &o.in.interfaces[m];
        var n: u32 = 0;
        for (iface.types) |t| if (t.is_opaque) {
            n += 1;
        };
        try w.int(n);
        for (iface.types, 0..) |t, ti| {
            if (!t.is_opaque) continue;
            try w.text(o.in.interner.slice(iface.symbol(t.name)));
            const d = o.in.provenance[m].typeDecl(ti).?;
            const slots = try o.opaqueSlots(m, d.int());
            try w.int(@intCast(slots.len));
            for (slots) |slot| try w.byte(@intFromBool(slot.container));
        }
    }
    if (public_module) |m| {
        try w.int(@intCast(aliases.len));
        for (aliases) |alias| {
            const bir = o.in.birs[m];
            try w.text(o.in.interner.slice(bir.symbol(bir.decls[alias.decl].name)));
            try w.int(w.module_index.get(alias.target.module).?);
            const target_bir = o.in.birs[alias.target.module];
            try w.text(o.in.interner.slice(target_bir.symbol(target_bir.decls[alias.target.decl].name)));
            try w.int(alias.target.hops);
            try w.byte(@intFromBool(alias.target.callable != null));
            try writeSizedSummary(&w, arena, alias.sum);
        }
    }
    return w.out.toOwnedSlice(gpa);
}

/// A path's bytes in the table: its steps, each named by table indices.
fn pathKey(o: *Ownership, arena: Allocator, w: *Writer, p: u32) Allocator.Error![]const u8 {
    const s = o.steps(p);
    var out: std.ArrayList(u8) = .empty;
    // §16.7 (c): a path has no length limit, and its length is a u32.
    try appendInt(arena, &out, 0);
    var si: usize = 0;
    var count: u32 = 0;
    while (si < s.len) {
        count += 1;
        if (w.public_module != null) if (try o.opaquePrefix(s[si..])) |slot| {
            try out.append(arena, 255);
            try appendInt(arena, &out, w.module_index.get(slot.module).?);
            const bir = o.in.birs[slot.module];
            try appendText(arena, &out, o.in.interner.slice(bir.symbol(bir.decls[slot.decl].name)));
            try appendInt(arena, &out, slot.slot);
            si += slot.len;
            continue;
        };
        const st = s[si];
        si += 1;
        try out.append(arena, @backingInt(st.kind));
        switch (st.kind) {
            .field => try appendInt(arena, &out, w.string_index.get(st.arg).?),
            .cast, .cast_level => try appendInt(arena, &out, w.cast_index[st.arg]),
            .tuple => try appendInt(arena, &out, st.arg),
            .any => try appendInt(arena, &out, st.arg),
            .ctor => {
                const key = o.ctorKey(o.stepCtor(st.arg));
                try appendInt(arena, &out, w.module_index.get(key.module).?);
                if (w.public_module != null and key.index < o.in.birs[key.module].ctors.len) {
                    const bir = o.in.birs[key.module];
                    const c = bir.ctors[key.index];
                    const d = bir.decl(c.decl);
                    try appendText(arena, &out, o.in.interner.slice(bir.symbol(d.name)));
                    try appendInt(arena, &out, key.index - d.ctors_start);
                } else if (w.public_module != null) {
                    const key_name = try o.publicSchemaCtor(key.module, key.index);
                    try appendText(arena, &out, key_name.name);
                    try appendInt(arena, &out, key_name.index);
                } else try appendInt(arena, &out, key.index);
                try appendInt(arena, &out, o.stepField(st.arg));
            },
            .level => {
                const t = o.markerType(st.arg);
                // F1's marker of every function type names no module.
                try appendInt(arena, &out, if (t == Ownership.fn_type) std.math.maxInt(u32) else w.module_index.get(@intCast(t >> 32)).?);
                if (w.public_module != null and t != Ownership.fn_type) {
                    const bir = o.in.birs[@intCast(t >> 32)];
                    try appendText(arena, &out, o.in.interner.slice(bir.symbol(bir.decls[@as(u32, @truncate(t)) & ~Ownership.encoded_bit].name)));
                } else try appendInt(arena, &out, if (t == Ownership.fn_type) @truncate(t) else @as(u32, @truncate(t)) & ~Ownership.encoded_bit);
                // §16.7 (#820): a schema's `Encoded` endpoint is the high bit of
                // where the marker stands.
                const enc: u8 = if (t != Ownership.fn_type and @as(u32, @truncate(t)) & Ownership.encoded_bit != 0) 0x80 else 0;
                try out.append(arena, @backingInt(o.markerKind(st.arg)) | enc);
            },
            .elem, .env, .markup_render, .markup_event, .schema_decoded, .schema_encoded => {},
        }
    }
    std.mem.writeInt(u32, out.items[0..4], count, .little);
    return out.items;
}

fn appendText(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try appendInt(a, out, @intCast(text.len));
    try out.appendSlice(a, text);
}

fn appendInt(a: Allocator, out: *std.ArrayList(u8), v: u32) Allocator.Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(a, &b);
}

/// A provenance as five numbers in the block's vocabulary, for ordering.
const ProvKey = struct {
    kind: u8,
    a: u32,
    b: u32,
    path: u32,
    taken: bool,
    obj: bool,
    condition_only: bool,

    fn less(x: ProvKey, y: ProvKey) bool {
        if (x.kind != y.kind) return x.kind < y.kind;
        if (x.a != y.a) return x.a < y.a;
        if (x.b != y.b) return x.b < y.b;
        if (x.path != y.path) return x.path < y.path;
        if (x.taken != y.taken) return @intFromBool(x.taken) < @intFromBool(y.taken);
        if (x.condition_only != y.condition_only) return @intFromBool(x.condition_only) < @intFromBool(y.condition_only);
        return @intFromBool(x.obj) < @intFromBool(y.obj);
    }
};

fn provKey(w: *const Writer, p: Prov) ProvKey {
    return .{
        .kind = @backingInt(p.kind),
        .a = if (p.kind == .klass and p.a < w.class_index.len) w.class_index[p.a] else if (p.kind == .shared) w.module_index.get(p.a).? else if (w.public_module != null and (p.kind == .fresh or p.kind == .esc)) if (w.neutral_fresh) @as(u32, if (p.a >= 500 and p.a < 1000) 500 else 0) else w.freshName(p.a) else p.a,
        .b = p.b,
        .path = w.path_index.get(p.path).?,
        .taken = p.taken,
        .obj = p.obj,
        .condition_only = p.condition_only,
    };
}

fn writeProv(w: *Writer, p: Prov) Allocator.Error!void {
    const k = provKey(w, p);
    try w.byte(k.kind);
    var a = k.a;
    if (w.public_module != null and p.kind == .env) {
        for (w.env, 0..) |b, i| if (b.local == p.a) {
            a = @intCast(i);
            break;
        };
    }
    try w.int(a);
    if (w.public_module != null and p.kind == .shared) {
        const bir = w.o.in.birs[p.a];
        try w.text(w.o.in.interner.slice(bir.symbol(bir.decls[p.b].name)));
    } else try w.int(k.b);
    try w.int(k.path);
    // Bit 1: record object alone; bit 2: containing-value condition.
    try w.byte(@as(u8, @intFromBool(k.taken)) | @as(u8, @intFromBool(k.obj)) << 1 | @as(u8, @intFromBool(k.condition_only)) << 2);
}

fn provLess(w: *const Writer, p: Prov, q: Prov) bool {
    if (w.public_module != null and p.kind == .shared and q.kind == .shared and p.a == q.a and p.b != q.b) {
        const bir = w.o.in.birs[p.a];
        return std.mem.lessThan(u8, w.o.in.interner.slice(bir.symbol(bir.decls[p.b].name)), w.o.in.interner.slice(bir.symbol(bir.decls[q.b].name)));
    }
    return provKey(w, p).less(provKey(w, q));
}

/// Two groups of an apart, in the block's order.
fn groupLess(w: *const Writer, g: []const Prov, h: []const Prov) bool {
    for (g[0..@min(g.len, h.len)], h[0..@min(g.len, h.len)]) |p, q| {
        if (provLess(w, p, q)) return true;
        if (provLess(w, q, p)) return false;
    }
    return g.len < h.len;
}

/// An apart's groups in the block's order: each group's members, then the
/// groups, by their provenances' keys (§16.7, #693).
fn canonicalApart(w: *const Writer, arena: Allocator, x: XAtom) Allocator.Error!XAtom {
    const gs = try arena.alloc([]const Prov, x.groups.len);
    for (gs, x.groups) |*d, g| {
        const m = try arena.dupe(Prov, g);
        std.mem.sort(Prov, m, w, provLess);
        d.* = m;
    }
    std.mem.sort([]const Prov, gs, w, groupLess);
    var out = x;
    out.groups = gs;
    return out;
}

fn atomLess(w: *const Writer, x: XAtom, y: XAtom) bool {
    if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
    if (x.isApart()) {
        const n = @min(x.groups.len, y.groups.len);
        for (x.groups[0..n], y.groups[0..n]) |g, h| {
            if (groupLess(w, g, h)) return true;
            if (groupLess(w, h, g)) return false;
        }
        return x.groups.len < y.groups.len;
    }
    if (provLess(w, x.a, y.a) or provLess(w, y.a, x.a)) return provLess(w, x.a, y.a);
    return provLess(w, x.b, y.b);
}

fn canonicalPair(w: *const Writer, x: XAtom) XAtom {
    if ((x.kind == .sep or x.kind == .sep_spine) and provLess(w, x.b, x.a)) {
        var out = x;
        out.a = x.b;
        out.b = x.a;
        return out;
    }
    return x;
}

fn writeAtoms(w: *Writer, arena: Allocator, atoms: []const XAtom) Allocator.Error!void {
    const sorted = try arena.dupe(XAtom, atoms);
    for (sorted) |*a| {
        a.* = if (a.isApart()) try canonicalApart(w, arena, a.*) else canonicalPair(w, a.*);
    }
    std.mem.sort(XAtom, sorted, w, atomLess);
    try w.int(@intCast(sorted.len));
    for (sorted) |a| {
        try w.byte(@backingInt(a.kind));
        if (a.isApart()) {
            // Its groups: their count, then each one's members.
            try w.int(@intCast(a.groups.len));
            for (a.groups) |g| {
                try w.int(@intCast(g.len));
                for (g) |p| try writeProv(w, p);
            }
            continue;
        }
        try writeProv(w, a.a);
        try writeProv(w, a.b);
    }
}

fn writeXSum(w: *Writer, arena: Allocator, x: XSum) Allocator.Error!void {
    try w.byte(x.no);
    try writeAtoms(w, arena, x.atoms);
}

fn writeSupply(w: *Writer, arena: Allocator, items: []const SupplyEntry) Allocator.Error!void {
    const supply = try arena.dupe(SupplyEntry, items);
    const SupCx = struct {
        w: *const Writer,
        fn less(cx: @This(), x: SupplyEntry, y: SupplyEntry) bool {
            if (x.fun != y.fun) return x.fun < y.fun;
            if (x.k != y.k) return x.k < y.k;
            const px = cx.w.path_index.get(x.path).?;
            const py = cx.w.path_index.get(y.path).?;
            if (px != py) return px < py;
            return provLess(cx.w, x.prov, y.prov);
        }
    };
    std.mem.sort(SupplyEntry, supply, SupCx{ .w = w }, SupCx.less);
    try w.int(@intCast(supply.len));
    for (supply) |e| {
        try w.int(e.fun);
        try w.int(e.k);
        try w.int(w.path_index.get(e.path).?);
        try writeProv(w, e.prov);
        try w.byte(@as(u8, @intFromBool(e.owned)) | @as(u8, @intFromBool(e.approx)) << 1);
        try writeXSum(w, arena, e.xc);
        try writeXSum(w, arena, e.sc);
        try writeXSum(w, arena, e.rxc);
    }
}

fn writeRes(w: *Writer, arena: Allocator, items: []const ResEntry, sort: bool) Allocator.Error!void {
    const list = try arena.dupe(ResEntry, items);
    if (sort) {
        const Cx = struct {
            w: *const Writer,
            fn less(cx: @This(), x: ResEntry, y: ResEntry) bool {
                const px = cx.w.path_index.get(x.path).?;
                const py = cx.w.path_index.get(y.path).?;
                if (px != py) return px < py;
                return provLess(cx.w, x.prov, y.prov);
            }
        };
        std.mem.sort(ResEntry, list, Cx{ .w = w }, Cx.less);
    }
    try w.int(@intCast(list.len));
    for (list) |r| {
        try w.int(w.path_index.get(r.path).?);
        try writeProv(w, r.prov);
        try w.byte(@intFromBool(r.approx));
        try writeXSum(w, arena, r.xc);
        try writeXSum(w, arena, r.sc);
        try writeXSum(w, arena, r.rxc);
    }
}

/// Allocation numbers are alpha names. Read-off orders paths by local ids;
/// a worker and the serial dump can therefore number the same conditions
/// differently. Number them by the public paths before writing any set.
fn numberFresh(w: *Writer, arena: Allocator, s: *const Summary) Allocator.Error!void {
    const Label = struct { raw: u32, occurrences: std.ArrayList([]const u8) = .empty, key: []const u8 = &.{} };
    const N = struct {
        w: *Writer,
        a: Allocator,
        labels: std.ArrayList(Label) = .empty,
        by_raw: std.ArrayList(u32) = .empty,
        saw_zero: bool = false,

        fn named(p: Prov) bool {
            return p.kind == .fresh or p.kind == .esc;
        }
        fn names(xs: []const XAtom) bool {
            for (xs) |x| {
                if (x.isApart()) {
                    for (x.groups) |group| for (group) |p| if (named(p)) return true;
                } else if (named(x.a) or named(x.b)) return true;
            }
            return false;
        }
        fn entryNames(p: Prov, xc: XSum, sc: XSum, rxc: XSum) bool {
            return named(p) or names(xc.atoms) or names(sc.atoms) or names(rxc.atoms);
        }

        fn descriptor(n: *@This(), context: []const u8, role: u32) Allocator.Error!Writer {
            var d = n.w.*;
            d.out = .empty;
            d.gpa = n.a;
            d.neutral_fresh = true;
            try d.int(role);
            try d.int(@intCast(context.len));
            try d.out.appendSlice(n.a, context);
            return d;
        }
        fn note(n: *@This(), p: Prov, context: []const u8) Allocator.Error!void {
            if (p.kind != .fresh and p.kind != .esc) return;
            if (p.a == 0) {
                n.saw_zero = true;
                return;
            }
            if (p.a >= n.by_raw.items.len) try n.by_raw.appendNTimes(n.a, Ownership.none, p.a + 1 - n.by_raw.items.len);
            if (n.by_raw.items[p.a] == Ownership.none) {
                n.by_raw.items[p.a] = @intCast(n.labels.items.len);
                try n.labels.append(n.a, .{ .raw = p.a });
            }
            try n.labels.items[n.by_raw.items[p.a]].occurrences.append(n.a, context);
        }
        fn atoms(n: *@This(), xs: []const XAtom, context: []const u8, role: u32) Allocator.Error!void {
            for (xs) |x| {
                // Parameter-only atoms contribute no allocation occurrence.
                // In particular, do not copy their containing entry's full
                // condition for every member of a large conjunction.
                if (!names(&.{x})) continue;
                var d = try n.descriptor(context, role);
                try writeAtoms(&d, n.a, &.{x});
                if (x.isApart()) {
                    for (x.groups) |group| {
                        var gd = try n.descriptor(d.out.items, 0);
                        // An apart's groups and members are sets.
                        const ps = try n.a.dupe(Prov, group);
                        std.mem.sort(Prov, ps, &gd, provLess);
                        for (ps) |p| try writeProv(&gd, p);
                        for (group) |p| try n.note(p, gd.out.items);
                    }
                } else {
                    const symmetric = x.kind == .sep or x.kind == .sep_spine;
                    var left = try n.descriptor(d.out.items, 0);
                    var right = try n.descriptor(d.out.items, if (symmetric) 0 else 1);
                    try writeProv(&left, x.a);
                    try writeProv(&right, x.b);
                    try n.note(x.a, left.out.items);
                    try n.note(x.b, right.out.items);
                }
            }
        }
        fn entry(n: *@This(), p: Prov, xc: XSum, sc: XSum, rxc: XSum, context: []const u8) Allocator.Error!void {
            if (named(p)) {
                const d = try n.descriptor(context, 0);
                try n.note(p, d.out.items);
            }
            try n.atoms(xc.atoms, context, 1);
            try n.atoms(sc.atoms, context, 2);
            try n.atoms(rxc.atoms, context, 3);
        }
        fn res(n: *@This(), items: []const ResEntry, context: []const u8, role: u32) Allocator.Error!void {
            for (items) |r| {
                if (!entryNames(r.prov, r.xc, r.sc, r.rxc)) continue;
                var d = try n.descriptor(context, role);
                try writeRes(&d, n.a, &.{r}, false);
                try n.entry(r.prov, r.xc, r.sc, r.rxc, d.out.items);
            }
        }
    };
    var n: N = .{ .w = w, .a = arena };
    try n.res(s.res, &.{}, 0);
    try n.res(s.objs, &.{}, 1);
    for ([_][]const SupplyEntry{ s.supply, s.rsupply }, 0..) |items, role| for (items) |e| {
        if (!N.entryNames(e.prov, e.xc, e.sc, e.rxc)) continue;
        var d = try n.descriptor(&.{}, @intCast(2 + role));
        try writeSupply(&d, arena, &.{e});
        try n.entry(e.prov, e.xc, e.sc, e.rxc, d.out.items);
    };
    try n.atoms(s.xreq, &.{}, 4);
    try n.atoms(s.rxreq, &.{}, 5);
    for (s.klasses, 0..) |k, ki| for (k.binds, 0..) |bind, bi| {
        var d = try n.descriptor(&.{}, 6);
        try d.int(w.class_index[ki]);
        try d.int(@intCast(bi));
        try d.int(w.path_index.get(bind.path).?);
        try n.res(bind.provs, d.out.items, 0);
    };
    const Less = struct {
        fn bytes(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
        fn label(_: void, x: Label, y: Label) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    };
    for (n.labels.items) |*label| {
        std.mem.sort([]const u8, label.occurrences.items, {}, Less.bytes);
        var d = try n.descriptor(&.{}, 0);
        for (label.occurrences.items) |occurrence| {
            try d.int(@intCast(occurrence.len));
            try d.out.appendSlice(arena, occurrence);
        }
        label.key = d.out.items;
    }
    std.mem.sort(Label, n.labels.items, {}, Less.label);
    // Instantiation maps the unnumbered fresh zero to cell one. Keep that
    // existing anchor while alpha-renaming the remaining allocation names.
    w.fresh_next[0] = if (n.saw_zero) 2 else 1;
    for (n.labels.items) |label| {
        if (n.saw_zero and label.raw == 1) {
            try w.setFresh(arena, 1, 1);
            continue;
        }
        const space: usize = @intFromBool(label.raw >= 500 and label.raw < 1000);
        try w.setFresh(arena, label.raw, w.fresh_next[space]);
        w.fresh_next[space] += 1;
        if (space == 0 and w.fresh_next[0] == 500) w.fresh_next[0] = 1000;
    }
}

fn writeSizedSummary(w: *Writer, arena: Allocator, sum: *const Summary) Allocator.Error!void {
    const at = w.out.items.len;
    try w.int(0);
    try writeSummary(w, arena, sum);
    std.mem.writeInt(u32, w.out.items[at..][0..4], @intCast(w.out.items.len - at - 4), .little);
}

fn writeSummary(w: *Writer, arena: Allocator, s: *const Summary) Allocator.Error!void {
    std.debug.assert(s.cast_grown == 0);
    const saved_index = w.fresh_index;
    const saved_next = w.fresh_next;
    const saved_classes = w.class_index;
    var class_order: []u32 = &.{};
    defer {
        w.fresh_index = saved_index;
        w.fresh_next = saved_next;
        w.class_index = saved_classes;
    }
    if (w.public_module != null) {
        const indices = try arena.alloc(u32, s.klasses.len);
        @memset(indices, Ownership.none);
        class_order = try arena.alloc(u32, s.klasses.len);
        const ordered = try arena.dupe(ResEntry, s.res);
        std.mem.sort(ResEntry, ordered, w, struct {
            fn less(writer: *const Writer, x: ResEntry, y: ResEntry) bool {
                return writer.path_index.get(x.path).? < writer.path_index.get(y.path).?;
            }
        }.less);
        var next: u32 = 0;
        for (ordered) |r| if (r.prov.kind == .klass and r.prov.a < indices.len and indices[r.prov.a] == Ownership.none) {
            indices[r.prov.a] = next;
            class_order[next] = r.prov.a;
            next += 1;
        };
        for (indices, 0..) |*index, i| if (index.* == Ownership.none) {
            index.* = next;
            class_order[next] = @intCast(i);
            next += 1;
        };
        w.class_index = indices;
        w.fresh_index = .empty;
        w.fresh_next = .{ 1, 500 };
        try numberFresh(w, arena, s);
    }
    try w.int(s.params);
    try w.int(if (s.cast_signature == Ownership.none) 0 else w.cast_index[s.cast_signature] + 1);
    try w.byte(@backingInt(s.limit));
    try w.int(s.limit_at);
    try w.byte(@as(u8, @intFromBool(s.asserted)) | @as(u8, @intFromBool(s.once)) << 2 | @as(u8, @intFromBool(s.words)) << 3);

    const uses = try arena.dupe(UseEntry, s.uses);
    const UseCx = struct {
        w: *const Writer,
        fn less(cx: @This(), x: UseEntry, y: UseEntry) bool {
            if (x.param != y.param) return x.param < y.param;
            return cx.w.path_index.get(x.path).? < cx.w.path_index.get(y.path).?;
        }
    };
    std.mem.sort(UseEntry, uses, UseCx{ .w = w }, UseCx.less);
    try w.int(@intCast(uses.len));
    for (uses) |u| {
        try w.int(u.param);
        try w.int(w.path_index.get(u.path).?);
        // §31.7: two bytes of bits, and a record write's fields, by name.
        try w.byte(@truncate(u.bits));
        try w.byte(@truncate(u.bits >> 8));
        try w.byte(@backingInt(u.extent));
        const hidden = if (w.public_module != null) try w.o.hiddenFields(u.path, u.fields) else null;
        if (w.public_module != null) try w.byte(@intFromBool(hidden != null));
        try w.int(@intCast(u.fields.len));
        const fields = try arena.alloc(u32, u.fields.len);
        for (u.fields, fields) |f, *x| x.* = if (hidden) |names| @intCast(std.mem.indexOfScalar(u32, names, f).?) else w.string_index.get(f).?;
        std.mem.sort(u32, fields, {}, std.sort.asc(u32));
        for (fields) |f| try w.int(f);
    }

    try writeRes(w, arena, s.res, true);
    // §31.7: the records the result holds, after it.
    try writeRes(w, arena, s.objs, true);

    try writeSupply(w, arena, s.supply);
    // §31.5: what the callbacks are handed of records, after it.
    try writeSupply(w, arena, s.rsupply);

    const funs = try arena.dupe(FunFacts, s.funs);
    std.mem.sort(FunFacts, funs, {}, struct {
        fn less(_: void, x: FunFacts, y: FunFacts) bool {
            return x.param < y.param;
        }
    }.less);
    try w.int(@intCast(funs.len));
    for (funs) |f| {
        try w.int(f.param);
        try w.byte(@backingInt(f.calls));
        try w.byte(@as(u8, @intFromBool(f.need)) | @as(u8, @intFromBool(f.seen)) << 1 | @as(u8, @intFromBool(f.sends)) << 2 | @as(u8, @intFromBool(f.rneed)) << 3);
        try w.int(f.send);
        try w.int(@intCast(f.need_if.len));
        for (f.need_if) |writer| try w.int(writer);
    }

    try writeAtoms(w, arena, s.xreq);
    try writeAtoms(w, arena, s.rxreq);

    try w.int(@intCast(s.slots.len));
    for (s.slots) |sl| {
        try w.int(sl[0]);
        try w.int(w.path_index.get(sl[1]).?);
    }

    try w.int(@intCast(s.klasses.len));
    for (0..s.klasses.len) |ki| {
        const k = s.klasses[if (w.public_module != null) class_order[ki] else ki];
        const env = w.env;
        w.env = k.binds;
        try writeSummary(w, arena, k.sum);
        w.env = env;
        try w.int(@intCast(k.binds.len));
        for (k.binds, 0..) |b, bi| {
            var local: u32 = b.local;
            if (w.public_module != null) for (k.binds[0 .. bi + 1], 0..) |other, oi| if (other.local == b.local) {
                local = @intCast(oi);
                break;
            };
            try w.int(local);
            try w.int(w.path_index.get(b.path).?);
            try writeRes(w, arena, b.provs, false);
        }
        try w.int(@intCast(k.cb_js.len));
        for (k.cb_js) |j| try w.int(j);
    }
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

const Reader = struct {
    o: *Ownership,
    arena: Allocator,
    bytes: []const u8,
    at: usize = 0,
    block: *Block,

    fn int(r: *Reader) Error!u32 {
        if (r.bytes.len - r.at < 4) return error.Bad;
        const v = std.mem.readInt(u32, r.bytes[r.at..][0..4], .little);
        r.at += 4;
        return v;
    }

    fn byte(r: *Reader) Error!u8 {
        if (r.at >= r.bytes.len) return error.Bad;
        r.at += 1;
        return r.bytes[r.at - 1];
    }

    fn text(r: *Reader) Error![]const u8 {
        const n = try r.int();
        if (r.bytes.len - r.at < n) return error.Bad;
        r.at += n;
        return r.bytes[r.at - n .. r.at];
    }

    fn skip(r: *Reader, n: usize) Error!void {
        if (r.bytes.len - r.at < n) return error.Bad;
        r.at += n;
    }

    /// A count of items each at least `min` bytes long: a count the rest of
    /// the block cannot hold is a bad block, not an allocation.
    fn count(r: *Reader, min: usize) Error!u32 {
        const n = try r.int();
        if (@as(u64, n) * min > r.bytes.len - r.at) return error.Bad;
        return n;
    }

    /// A path by its table index, interned the first time a summary names
    /// it (§28.4: a block is read as far as the run asks).
    fn path(r: *Reader) Error!u32 {
        const i = try r.int();
        const b = r.block;
        if (i >= b.path_at.len) return error.Bad;
        if (b.path_id[i] == unread) b.path_id[i] = try readPath(r.o, b, b.path_at[i]);
        return b.path_id[i];
    }

    fn module(r: *Reader) Error!u32 {
        const i = try r.int();
        if (i >= r.block.modules.len) return error.Bad;
        return r.block.modules[i];
    }

    fn enumOf(r: *Reader, comptime E: type) Error!E {
        const v = try r.byte();
        return std.enums.fromInt(E, v) orelse error.Bad;
    }

    fn bool_(r: *Reader) Error!bool {
        return switch (try r.byte()) {
            0 => false,
            1 => true,
            else => error.Bad,
        };
    }
};

const unread = std.math.maxInt(u32);

/// What `open` gives: a block whose tables are resolved and whose
/// summaries are read one declaration at a time, the first time the run
/// asks for one (`summary`), and kept. Per declaration, whether it is a
/// value that may hold a list is read at once.
const AliasEntry = struct {
    target: Ownership.Alias,
    callable: bool,
    at: u32,
    end: u32,
    state: u8 = 0,
    sum: ?*const Summary = null,
};

pub const Block = struct {
    public: bool = false,
    aliases: []?AliasEntry,
    bytes: []const u8,
    modules: []u32,
    strings: []u32,
    casts: []u32,
    /// Each path's offset in `bytes`, and its id in this run once a
    /// summary names it (`unread` until then).
    path_at: []u32,
    path_id: []u32,
    /// Per declaration: the span of its summary in `bytes` (`sum_at` is
    /// `unread` when it has none), and the summary once read.
    sum_at: []u32,
    sum_end: []u32,
    sums: []?Summary,
    /// Per declaration: 0 not read yet, 1 read, 2 no summary (none in the
    /// block, or one that does not read).
    state: []u8,
    holds_list: []bool,
};

/// The block `bytes` of module `m`: its head, its tables and its row
/// directory read; its paths and summaries read as `summary` asks.
/// `error.Bad` when the bytes are not a block of this version, or name a
/// module or declaration this session does not have.
pub fn open(o: *Ownership, arena: Allocator, bytes: []const u8, m: u32) Error!Block {
    const decls = o.in.birs[m].decls.len;
    var block: Block = .{
        .bytes = bytes,
        .aliases = try arena.alloc(?AliasEntry, decls),
        .modules = &.{},
        .strings = &.{},
        .casts = &.{},
        .path_at = &.{},
        .path_id = &.{},
        .sum_at = try arena.alloc(u32, decls),
        .sum_end = try arena.alloc(u32, decls),
        .sums = try arena.alloc(?Summary, decls),
        .state = try arena.alloc(u8, decls),
        .holds_list = try arena.alloc(bool, decls),
    };
    @memset(block.aliases, null);
    @memset(block.sum_at, unread);
    @memset(block.sum_end, 0);
    @memset(block.sums, null);
    @memset(block.state, 0);
    @memset(block.holds_list, false);
    var r: Reader = .{ .o = o, .arena = arena, .bytes = bytes, .block = &block };
    if (bytes.len < magic.len) return error.Bad;
    block.public = std.mem.eql(u8, bytes[0..magic.len], "BENIOWP\x00");
    if (!block.public and !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.Bad;
    r.at = magic.len;
    if (try r.int() != version) return error.Bad;
    if (!block.public and try r.byte() > 1) return error.Bad;

    const n_modules = try r.count(5);
    block.modules = try arena.alloc(u32, n_modules);
    for (block.modules) |*slot| {
        const package = std.enums.fromInt(SourceStore.Package, try r.byte()) orelse return error.Bad;
        const name = try r.text();
        slot.* = o.moduleNamed(package, name) orelse return error.Bad;
    }
    const n_strings = try r.count(4);
    block.strings = try arena.alloc(u32, n_strings);
    for (block.strings) |*slot| {
        const name = try r.text();
        // A field the session never interned is a field no value of this
        // session has: the step is still a field, of no record it can meet.
        slot.* = if (o.in.interner.find(name)) |s| @backingInt(s) else Ownership.none;
    }
    block.casts = try arena.alloc(u32, try r.count(4));
    for (block.casts, 0..) |*slot, i| slot.* = try o.readCastId(try r.text(), block.casts[0..i]);
    // The path table is only measured here: each path is read, and
    // interned, when a summary first names it.
    const n_paths = try r.count(1);
    block.path_at = try arena.alloc(u32, n_paths);
    block.path_id = try arena.alloc(u32, n_paths);
    @memset(block.path_id, unread);
    for (block.path_at) |*slot| {
        slot.* = @intCast(r.at);
        const n_steps = try r.int();
        if (n_steps > r.bytes.len - r.at) return error.Bad;
        for (0..n_steps) |_| {
            const tag = try r.byte();
            if (block.public and tag == 255) {
                try r.skip(4);
                _ = try r.text();
                try r.skip(4);
                continue;
            }
            switch (std.enums.fromInt(StepKind, tag) orelse return error.Bad) {
                .field, .tuple, .cast, .cast_level, .any => try r.skip(4),
                .ctor => {
                    try r.skip(4);
                    if (block.public) _ = try r.text();
                    try r.skip(8);
                },
                .level => {
                    const module = try r.int();
                    if (block.public and module != std.math.maxInt(u32)) _ = try r.text() else try r.skip(4);
                    try r.skip(1);
                },
                .elem, .env, .markup_render, .markup_event, .schema_decoded, .schema_encoded => {},
            }
        }
    }

    const n_rows = try r.count(5);
    for (0..n_rows) |_| {
        const d = if (block.public) o.declNamed(m, try r.text()) orelse return error.Bad else try r.int();
        if (d >= decls) return error.Bad;
        const flags = try r.byte();
        if (flags > 3) return error.Bad;
        block.holds_list[d] = flags & 2 != 0;
        if (flags & 1 != 0) {
            const len = try r.int();
            const at = r.at;
            try r.skip(len);
            block.sum_at[d] = @intCast(at);
            block.sum_end[d] = @intCast(r.at);
        } else {
            block.sum_at[d] = unread;
        }
    }
    if (block.public) {
        const n = try r.count(8);
        for (0..n) |_| {
            const d = o.declNamed(m, try r.text()) orelse return error.Bad;
            const slots = try o.opaqueSlots(m, d);
            if (try r.count(1) != slots.len) return error.Bad;
            for (slots) |slot| if (try r.bool_() != slot.container) return error.Bad;
        }
    }
    if (block.public) {
        const n = try r.count(16);
        for (0..n) |_| {
            const d = o.declNamed(m, try r.text()) orelse return error.Bad;
            const tm = try r.module();
            const td = o.declNamed(tm, try r.text()) orelse return error.Bad;
            const hops = try r.int();
            if (hops == 0 or hops >= 8) return error.Bad;
            const callable = try r.bool_();
            if (block.aliases[d] != null) return error.Bad;
            const len = try r.int();
            const at = r.at;
            try r.skip(len);
            block.aliases[d] = .{
                .target = .{ .module = tm, .decl = td, .hops = hops },
                .callable = callable,
                .at = @intCast(at),
                .end = @intCast(r.at),
            };
        }
    }
    if (r.at != bytes.len) return error.Bad;
    return block;
}

/// Declaration `d`'s summary in `b`, read now if it is not yet, in `o`'s
/// normal form; null when the block has none for it, or the one it has
/// does not read — a callee with no summary, never a wrong one (§16.4).
pub fn summary(o: *Ownership, arena: Allocator, b: *Block, d: u32) Allocator.Error!?*const Summary {
    if (d >= b.state.len) return null;
    switch (b.state[d]) {
        1 => return &b.sums[d].?,
        2 => return null,
        else => {},
    }
    b.state[d] = 2;
    if (b.sum_at[d] == unread) return null;
    var r: Reader = .{ .o = o, .arena = arena, .bytes = b.bytes[0..b.sum_end[d]], .at = b.sum_at[d], .block = b };
    const s = readSummary(&r, 0) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Bad => return null,
    };
    if (r.at != r.bytes.len) return null;
    b.sums[d] = s;
    b.state[d] = 1;
    return &b.sums[d].?;
}

pub fn aliasSummary(o: *Ownership, arena: Allocator, b: *Block, d: u32) Allocator.Error!?AliasValue {
    if (d >= b.aliases.len) return null;
    const entry = if (b.aliases[d]) |*e| e else return null;
    if (entry.state == 2) return null;
    if (entry.state == 0) {
        entry.state = 2;
        var r: Reader = .{ .o = o, .arena = arena, .bytes = b.bytes[0..entry.end], .at = entry.at, .block = b };
        const value = readSummary(&r, 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Bad => return null,
        };
        if (r.at != r.bytes.len) return null;
        const sum = try arena.create(Summary);
        sum.* = value;
        entry.sum = sum;
        if (entry.callable) entry.target.callable = sum;
        try o.installAlias(entry.target, sum);
        entry.state = 1;
    }
    return .{ .target = entry.target, .sum = entry.sum.? };
}

/// The path at offset `at` of `b`'s table, interned into `o`'s table.
fn readPath(o: *Ownership, b: *Block, at: u32) Error!u32 {
    var r: Reader = .{ .o = o, .arena = undefined, .bytes = b.bytes, .at = at, .block = b };
    const n_steps = try r.int();
    var id: u32 = Ownership.eps;
    for (0..n_steps) |_| {
        const tag = try r.byte();
        if (b.public and tag == 255) {
            const sm = try r.module();
            const sd = o.declNamed(sm, try r.text()) orelse return error.Bad;
            const slots = try o.opaqueSlots(sm, sd);
            const k = try r.int();
            if (k >= slots.len) return error.Bad;
            for (o.steps(slots[k].path)) |step| id = try o.rawChild(id, step.kind, step.arg);
            continue;
        }
        const kind = std.enums.fromInt(StepKind, tag) orelse return error.Bad;
        const arg: u32 = switch (kind) {
            .field => blk: {
                const i = try r.int();
                if (i >= b.strings.len) return error.Bad;
                break :blk b.strings[i];
            },
            .tuple => try r.int(),
            .any => blk: {
                const scope = try r.int();
                if (scope > 1) return error.Bad;
                break :blk scope;
            },
            .cast, .cast_level => blk: {
                const i = try r.int();
                if (i >= b.casts.len) return error.Bad;
                break :blk b.casts[i];
            },
            .ctor => blk: {
                const cm = try r.module();
                const ci = if (b.public) named: {
                    const name = try r.text();
                    const relative = try r.int();
                    const decl = o.declNamed(cm, name) orelse return error.Bad;
                    const bir = o.in.birs[cm];
                    const d = bir.decls[decl];
                    if (d.kind == .schema) break :named (try o.publicSchemaCtorIndex(cm, decl, relative)) orelse return error.Bad;
                    if (relative >= d.ctors_end - d.ctors_start) return error.Bad;
                    break :named d.ctors_start + relative;
                } else try r.int();
                const k = try r.int();
                const arity = (try o.ctorArity(cm, ci)) orelse return error.Bad;
                if (k >= arity) return error.Bad;
                break :blk try o.ctorStep(try o.ctorId(cm, ci), k);
            },
            .level => blk: {
                const mi = try r.int();
                const td = if (b.public and mi != std.math.maxInt(u32)) (o.declNamed(b.modules[if (mi < b.modules.len) mi else return error.Bad], try r.text()) orelse return error.Bad) else try r.int();
                const wb = try r.byte();
                const where = std.enums.fromInt(Ownership.MarkerKind, wb & 0x7f) orelse return error.Bad;
                // §16.7 (#820): the high bit is a schema's `Encoded` endpoint.
                const enc = wb & 0x80 != 0;
                if (mi == std.math.maxInt(u32)) {
                    if (enc) return error.Bad;
                    break :blk try o.markerId(Ownership.fn_type, where);
                }
                if (mi >= b.modules.len) return error.Bad;
                const tm = b.modules[mi];
                if (td >= o.in.birs[tm].decls.len) return error.Bad;
                if (enc and o.in.birs[tm].decls[td].kind != .schema) return error.Bad;
                break :blk try o.markerId((@as(u64, tm) << 32) | td | (if (enc) Ownership.encoded_bit else 0), where);
            },
            .elem, .env, .markup_render, .markup_event, .schema_decoded, .schema_encoded => 0,
        };
        id = try o.rawChild(id, kind, arg);
    }
    return id;
}

fn readProv(r: *Reader) Error!Prov {
    const kind = try r.enumOf(Ownership.ProvKind);
    const a_raw = try r.int();
    const b = if (r.block.public and kind == .shared) blk: {
        if (a_raw >= r.block.modules.len) return error.Bad;
        break :blk r.o.declNamed(r.block.modules[a_raw], try r.text()) orelse return error.Bad;
    } else try r.int();
    const path = try r.path();
    const flags = try r.byte();
    if (flags > 7) return error.Bad;
    const taken = flags & 1 != 0;
    const a = if (kind == .shared) blk: {
        if (a_raw >= r.block.modules.len) return error.Bad;
        const sm = r.block.modules[a_raw];
        if (b >= r.o.in.birs[sm].decls.len) return error.Bad;
        break :blk sm;
    } else a_raw;
    return .{ .kind = kind, .a = a, .b = b, .path = path, .taken = taken, .obj = flags & 2 != 0, .condition_only = flags & 4 != 0 };
}

fn readAtoms(r: *Reader) Error![]const XAtom {
    const n = try r.count(1 + 2 * 14);
    var atoms: std.ArrayList(XAtom) = .empty;
    for (0..n) |_| {
        const kind = try r.enumOf(@FieldType(XAtom, "kind"));
        if (kind == .apart or kind == .apart_spine) {
            // Its groups, put in this run's canonical form.
            const groups = try r.arena.alloc([]Prov, try r.count(4 + 14));
            if (groups.len < 2) return error.Bad;
            for (groups) |*g| {
                g.* = try r.arena.alloc(Prov, try r.count(14));
                if (g.len == 0) return error.Bad;
                for (g.*) |*p| p.* = try readProv(r);
            }
            try Ownership.apartAtoms(r.arena, kind, groups, &atoms);
            continue;
        }
        const x = try readProv(r);
        const y = try readProv(r);
        var atom = if (kind == .sep or kind == .sep_spine) Ownership.sepAtom(x, y) else XAtom{ .kind = kind, .a = x, .b = y };
        atom.kind = kind;
        try atoms.append(r.arena, atom);
    }
    return Ownership.sortAtoms(atoms.items);
}

fn readXSum(r: *Reader) Error!XSum {
    const no = try r.byte();
    if (no > 2) return error.Bad;
    return .{ .no = no, .atoms = try readAtoms(r) };
}

fn readSupply(r: *Reader) Error![]const SupplyEntry {
    const supply = try r.arena.alloc(SupplyEntry, try r.count(12 + 14 + 1 + 5));
    for (supply) |*e| {
        const fun = try r.int();
        const k = try r.int();
        const path = try r.path();
        const prov = try readProv(r);
        const bits = try r.byte();
        if (bits > 3) return error.Bad;
        e.* = .{ .fun = fun, .k = k, .path = path, .prov = prov, .owned = bits & 1 != 0, .approx = bits & 2 != 0, .xc = try readXSum(r), .sc = try readXSum(r), .rxc = try readXSum(r) };
    }
    return supply;
}

fn readRes(r: *Reader) Error![]const ResEntry {
    const n = try r.count(4 + 14 + 1 + 10);
    const out = try r.arena.alloc(ResEntry, n);
    for (out) |*e| {
        const path = try r.path();
        const prov = try readProv(r);
        const approx = try r.bool_();
        e.* = .{ .path = path, .prov = prov, .approx = approx, .xc = try readXSum(r), .sc = try readXSum(r), .rxc = try readXSum(r) };
    }
    return out;
}

fn readSummary(r: *Reader, depth: u32) Error!Summary {
    // A carried lambda's class holds no carried lambda of its own deeper
    // than the walk can make; a block that nests further is not one.
    if (depth > 16) return error.Bad;
    const params = try r.int();
    const signature_index = try r.int();
    if (signature_index > r.block.casts.len) return error.Bad;
    const cast_signature = if (signature_index == 0) Ownership.none else r.block.casts[signature_index - 1];
    const limit = try r.enumOf(Ownership.Limit);
    const limit_at = try r.int();
    const flags = try r.byte();
    // Bit 2 was a coarsened summary's, before §16.7 deleted coarsening.
    if (flags > 15 or flags & 2 != 0) return error.Bad;

    const uses = try r.arena.alloc(UseEntry, try r.count(15));
    for (uses) |*u| {
        const param = try r.int();
        const path = try r.path();
        const lo = try r.byte();
        const hi = try r.byte();
        const extent = try r.enumOf(Ownership.WriteExtent);
        const hidden = r.block.public and try r.bool_();
        const names = if (hidden) (try r.o.opaqueRecordFields(path)) orelse return error.Bad else r.block.strings;
        const fields = try r.arena.alloc(u32, try r.count(4));
        for (fields) |*f| {
            const i = try r.int();
            if (i >= names.len) return error.Bad;
            f.* = names[i];
        }
        // Interned in this session's order, as the summary's own are.
        std.mem.sort(u32, fields, {}, std.sort.asc(u32));
        u.* = .{ .param = param, .path = path, .bits = @as(u16, lo) | @as(u16, hi) << 8, .extent = extent, .fields = fields };
    }

    const res = try readRes(r);
    const objs = try readRes(r);

    const supply = try readSupply(r);
    const rsupply = try readSupply(r);

    const funs = try r.arena.alloc(FunFacts, try r.count(14));
    for (funs) |*f| {
        const param = try r.int();
        const calls = try r.enumOf(Ownership.Calls);
        const bits = try r.byte();
        if (bits > 15) return error.Bad;
        f.* = .{ .param = param, .calls = calls, .need = bits & 1 != 0, .seen = bits & 2 != 0, .sends = bits & 4 != 0, .rneed = bits & 8 != 0, .send = try r.int() };
        const guards = try r.arena.alloc(u32, try r.count(4));
        for (guards) |*writer| writer.* = try r.int();
        f.need_if = guards;
    }

    const xreq = try readAtoms(r);
    const rxreq = try readAtoms(r);

    const slots = try r.arena.alloc([2]u32, try r.count(8));
    for (slots) |*sl| sl.* = .{ try r.int(), try r.path() };

    const klasses = try r.arena.alloc(Carried, try r.count(4));
    for (klasses) |*k| {
        const sum = try r.arena.create(Summary);
        sum.* = try readSummary(r, depth + 1);
        const binds = try r.arena.alloc(Carried.Bind, try r.count(12));
        for (binds) |*b| b.* = .{ .local = try r.int(), .path = try r.path(), .provs = try readRes(r) };
        const cb_js = try r.arena.alloc(u32, try r.count(4));
        for (cb_js) |*j| j.* = try r.int();
        k.* = .{ .sum = sum, .binds = binds, .cb_js = cb_js };
    }

    return r.o.normalizeRead(.{
        .params = params,
        .cast_signature = cast_signature,
        .uses = uses,
        .res = res,
        .objs = objs,
        .supply = supply,
        .rsupply = rsupply,
        .funs = funs,
        .limit = limit,
        .limit_at = limit_at,
        .asserted = flags & 1 != 0,
        .once = flags & 4 != 0,
        .words = flags & 8 != 0,
        .xreq = xreq,
        .rxreq = rxreq,
        .slots = slots,
        .klasses = klasses,
    });
}

test "a block naming a constructor field past the constructor's arity is refused" {
    const gpa = std.testing.allocator;
    const Bir = @import("../bir/Bir.zig");
    // One module, `M`, whose one constructor takes two fields.
    const extra = [_]u32{ 0, 0 };
    var symbols = [_]Bir.Symbol{};
    const ctors = [_]Bir.Ctor{.{ .name = .none, .name_token = 0, .decl = @fromBackingInt(@intCast(0)), .args_start = @fromBackingInt(@intCast(0)), .args_end = @fromBackingInt(@intCast(2)) }};
    const bir: Bir = .{
        .insts = (Bir.InstList{}).slice(),
        .extra = &extra,
        .string_bytes = "",
        .symbols = &symbols,
        .decls = &.{},
        .ctors = &ctors,
        .locals = &.{},
        .refs = &.{},
        .imports = &.{},
        .exposed = &.{},
        .interface = &.{},
        .diagnostics = &.{},
        .module_doc_start = 0,
        .module_doc_end = 0,
    };
    const birs = [_]*const Bir{&bir};
    const names = [_][]const u8{"M"};
    const packages = [_]SourceStore.Package{.app};
    var o = Ownership.init(.{
        .gpa = gpa,
        .graph = undefined,
        .birs = &birs,
        .provenance = &.{},
        .dispatch = &.{},
        .modules = &.{},
        .types = undefined,
        .interner = undefined,
        .module_names = &names,
        .packages = &packages,
        .spans = &.{},
        .positions = undefined,
    });
    defer o.deinit();
    try o.seedPaths();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // A block of no rows and one path, `#C.k`.
    const bytes = struct {
        fn of(a: Allocator, k: u32) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            const int = struct {
                fn f(al: Allocator, o2: *std.ArrayList(u8), v: u32) !void {
                    var b: [4]u8 = undefined;
                    std.mem.writeInt(u32, &b, v, .little);
                    try o2.appendSlice(al, &b);
                }
            }.f;
            try out.appendSlice(a, magic);
            try int(a, &out, version);
            try out.append(a, 0); // No clean-report certificate.
            try int(a, &out, 1);
            try out.append(a, @backingInt(SourceStore.Package.app));
            try int(a, &out, 1);
            try out.append(a, 'M');
            try int(a, &out, 0);
            try int(a, &out, 0);
            try int(a, &out, 1);
            try int(a, &out, 1);
            try out.append(a, @backingInt(Ownership.StepKind.ctor));
            try int(a, &out, 0);
            try int(a, &out, 0);
            try int(a, &out, k);
            try int(a, &out, 0);
            return out.items;
        }
    };
    // A path is read when a summary first names it (§28.4), so the
    // refusal is the path's.
    for ([_]u32{ 1, 2, 64 }) |k| {
        var block = try open(&o, arena.allocator(), try bytes.of(arena.allocator(), k), 0);
        const got = readPath(&o, &block, block.path_at[0]);
        if (k < 2) _ = try got else try std.testing.expectError(error.Bad, got);
    }
}
