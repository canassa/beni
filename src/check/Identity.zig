//! Type identities (`static-dispatch-spike.md` §8.6, checker-v2.md §33):
//! which declarations take the identity of a quantifier's type as a hidden
//! parameter, and the identity every call passes them.
//!
//! A key matched across types (`boundary.md` §9.8.3) needs to know which
//! type it is of, and evidence says only how to compare two values of it.
//! So the compiler supplies the type's identity — a string naming the whole
//! type — at every site that needs one: a call of core's `Js.fingerprint`,
//! the seed, or of a declaration that needs one. A declaration generic over
//! the type passes on its own identity parameter, which its callers supply
//! in turn. Nothing of it is written in the source.
//!
//! **After P6, per module.** `Elaborate` records every root of every site
//! whose evidence is a value's (`Elaborate.Slot`), with the type its
//! requirement was instantiated at. Here:
//!
//!   1. a root is an identity SLOT when its callee takes an identity there:
//!      an import whose quantifier carries the interface's identity bit,
//!      core `Js.fingerprint` (in `Js` itself, its own declaration), or a
//!      binder of this module found to need one;
//!   2. a slot's type is walked: each type variable that is the root of a
//!      requirement of a binder around the site — the promoting `let`s
//!      innermost first, then the declaration — makes that binder take the
//!      identity of that quantifier, placed at its first requirement, which
//!      turns every root of every call of that binder there into a slot;
//!   3. at the fixpoint each slot's identity becomes an `identity` term —
//!      text, and `param` terms for the variables — appended to its site's
//!      roots, and each binder's identities are set.
//!
//! **What is refused** (`type_identity_unknown`): a slot whose type names
//! an annotation's variable, or a variable its binders' types reach, that no
//! requirement of theirs roots (there is no parameter to read it from); and a
//! declaration that takes identities named anywhere but as a site's callee —
//! as evidence, which is called with the values it compares and has no room
//! for one. Either would otherwise be two types under one key.
//!
//! A module none of whose slots reaches the seed returns at step 1 with
//! nothing changed, so its table is byte for byte what it was.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Context = @import("Context.zig");
const Dispatch = @import("Dispatch.zig");
const Elaborate = @import("Elaborate.zig");
const Report = @import("Report.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Walk = @import("Walk.zig");

const Var = TypeStore.Var;
const TermIndex = Dispatch.TermIndex;
pub const Error = Allocator.Error;

const none = std.math.maxInt(u32);

/// The parts one identity's text may hold before the type is refused as too
/// large to name: a type is a DAG in the store and a text here, and
/// `( x, x )` nested n deep is 2ⁿ parts. A key's type is a handful.
pub const max_parts: u32 = 1 << 16;

pub const Input = struct {
    cx: *const Context,
    report: *Report,
    /// The table's declarations and promoting `let`s: their `identities`
    /// are set here.
    decls: []Dispatch.DeclInfo,
    lets: []Dispatch.LetInfo,
    requirements: []const Dispatch.Requirement,
    /// Per requirement row, its quantifier's root.
    roots: []const Var,
    decl_scheme: []const Var.Optional,
    let_schemes: []const Var,
    /// P6's trees, rewritten in place when a site gains identities.
    out: *Elaborate.Output,
};

/// What the pass adds to the table: owned by `cx.gpa`.
pub const Result = struct {
    identities: []const u32 = &.{},
    text: []const u8 = &.{},
};

/// Where a site's evidence goes: a binder of this module, an import, or
/// something that takes none.
const Callee = union(enum) {
    none,
    binder: u32,
    ext: struct { module: Graph.Index, value: u32 },
};

/// One part of an identity being written: literal text (a run of `bytes`),
/// a binder's requirement whose quantifier it names, or a variable no
/// requirement roots.
const Part = union(enum) {
    text: Dispatch.Range,
    hole: struct { binder: u32, row: u32 },
    unknown: Var,
};

const Item = union(enum) {
    type: Var,
    lit: []const u8,
};

const Pass = struct {
    in: Input,
    gpa: Allocator,
    scratch: Allocator,
    store: *TypeStore,
    /// Per slot, its callee.
    callee: []Callee,
    /// Per slot, whether it is an identity slot.
    keyed: []bool,
    /// Per requirement row: the binder takes its quantifier's identity
    /// (only ever the quantifier's first row).
    marked: []bool,
    /// Slot indices sorted by (binder, root), and per binder its run.
    by_binder: []u32,
    binder_start: []u32,
    work: std.ArrayList(u32) = .empty,
    /// Per keyed slot, its parts: a run of `parts`.
    slot_parts: []Dispatch.Range,
    parts: std.ArrayList(Part) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    items: std.ArrayList(Item) = .empty,
    fields: std.ArrayList(TypeStore.Field) = .empty,
    stacks: Walk.Stacks = .{},
    any: bool = false,
    /// Where the slot being written starts in `parts`: a text part before
    /// it is another slot's, and is never extended.
    slot_start: usize = 0,

    fn binderCount(p: *const Pass) u32 {
        return @intCast(p.in.decls.len + p.in.lets.len);
    }

    fn reqRange(p: *const Pass, b: u32) Dispatch.Range {
        if (b < p.in.decls.len) return p.in.decls[b].requirements;
        return p.in.lets[b - p.in.decls.len].requirements;
    }

    /// Mark binder `b`'s requirement `j` (an index into its list) as an
    /// identity, and make every root `j` of a call of `b` a slot.
    fn mark(p: *Pass, b: u32, j: u32) Error!void {
        const r = p.reqRange(b);
        if (j >= r.len) return;
        const row = r.start + j;
        if (p.marked[row]) return;
        p.marked[row] = true;
        p.any = true;
        for (p.by_binder[p.binder_start[b]..p.binder_start[b + 1]]) |s| {
            if (p.in.out.slots[s].root == j) try p.work.append(p.scratch, s);
        }
    }

    /// The binder and requirement whose quantifier is `v` (a root), among
    /// the binders around slot `s`: promoting `let`s innermost first, then
    /// the declaration. The first row of the quantifier, since rows are in
    /// canonical order and every row of one quantifier has its root.
    fn holeOf(p: *Pass, s: Elaborate.Slot, v: Var) ?struct { binder: u32, row: u32 } {
        const lets_base: u32 = @intCast(p.in.decls.len);
        var l = s.let;
        while (l != Elaborate.no_let and l < p.in.lets.len) : (l = if (l < p.in.out.let_parent.len) p.in.out.let_parent[l] else Elaborate.no_let) {
            if (p.rowOf(lets_base + l, v)) |j| return .{ .binder = lets_base + l, .row = j };
        }
        if (s.decl < p.in.decls.len) if (p.rowOf(s.decl, v)) |j| return .{ .binder = s.decl, .row = j };
        return null;
    }

    fn rowOf(p: *Pass, b: u32, v: Var) ?u32 {
        const r = p.reqRange(b);
        for (p.in.roots[r.start..][0..r.len], 0..) |q, k| {
            if (p.store.find(q) == v) return @intCast(k);
        }
        return null;
    }

    fn lit(p: *Pass, text: []const u8) Error!void {
        if (p.parts.items.len > p.slot_start) switch (p.parts.items[p.parts.items.len - 1]) {
            .text => |*r| if (r.start + r.len == p.bytes.items.len) {
                try p.bytes.appendSlice(p.scratch, text);
                r.len += @intCast(text.len);
                return;
            },
            else => {},
        };
        const start: u32 = @intCast(p.bytes.items.len);
        try p.bytes.appendSlice(p.scratch, text);
        try p.parts.append(p.scratch, .{ .text = .{ .start = start, .len = @intCast(text.len) } });
    }

    /// Slot `s`'s type, as parts appended to `parts`. False when it is too
    /// large to name.
    fn write(p: *Pass, s: Elaborate.Slot) Error!bool {
        const cx = p.in.cx;
        p.items.clearRetainingCapacity();
        try p.items.append(p.scratch, .{ .type = s.type });
        var n: u32 = 0;
        while (p.items.pop()) |item| {
            n += 1;
            if (n > max_parts) return false;
            const v = switch (item) {
                .lit => |t| {
                    try p.lit(t);
                    continue;
                },
                .type => |v| v,
            };
            const root, const c = p.store.resolved(v);
            switch (c) {
                .flex, .rigid => try p.variable(s, root),
                .err, .alias => try p.lit("_"),
                .structure => |flat| switch (flat) {
                    .unit => try p.lit("()"),
                    .empty_record => try p.lit("{}"),
                    .func => |f| {
                        try p.lit("(");
                        try p.items.append(p.scratch, .{ .lit = ")" });
                        try p.items.append(p.scratch, .{ .type = f.result });
                        try p.items.append(p.scratch, .{ .lit = "->" });
                        const params = if (Walk.function(p.store, root)) |fun| fun.params else &.{};
                        try p.pushList(params);
                    },
                    .tuple => {
                        try p.lit("(");
                        try p.items.append(p.scratch, .{ .lit = ")" });
                        try p.pushList(Walk.positions(p.store, root));
                    },
                    .app => |a| {
                        const entry = cx.types.entry(a.type);
                        try p.lit(switch (entry.package) {
                            .app => "",
                            .core => "core:",
                            .platform => "platform:",
                        });
                        try p.lit(cx.interner.slice(entry.module_name));
                        try p.lit(".");
                        try p.lit(cx.interner.slice(entry.name));
                        const args = Walk.positions(p.store, root);
                        if (args.len != 0) {
                            try p.lit("(");
                            try p.items.append(p.scratch, .{ .lit = ")" });
                            try p.pushList(args);
                        }
                    },
                    .record => |r| {
                        p.fields.clearRetainingCapacity();
                        var concatenated = false;
                        const end = try Walk.recordRow(p.store, r, &p.fields, p.gpa, &concatenated);
                        // By TEXT: a `Symbol` id depends on `--jobs` (§17).
                        std.mem.sort(TypeStore.Field, p.fields.items, cx.interner, struct {
                            fn lessThan(pool: *const InternPool.Global, a: TypeStore.Field, b: TypeStore.Field) bool {
                                return std.mem.lessThan(u8, pool.slice(a.name), pool.slice(b.name));
                            }
                        }.lessThan);
                        try p.lit("{");
                        try p.items.append(p.scratch, .{ .lit = "}" });
                        switch (end) {
                            .closed => {},
                            .open => |tail| {
                                try p.items.append(p.scratch, .{ .type = tail });
                                try p.items.append(p.scratch, .{ .lit = "|" });
                            },
                        }
                        var k = p.fields.items.len;
                        while (k > 0) {
                            k -= 1;
                            const f = p.fields.items[k];
                            try p.items.append(p.scratch, .{ .type = f.value });
                            try p.items.append(p.scratch, .{ .lit = "=" });
                            try p.items.append(p.scratch, .{ .lit = cx.interner.slice(f.name) });
                            if (k != 0) try p.items.append(p.scratch, .{ .lit = "," });
                        }
                    },
                },
            }
        }
        return true;
    }

    /// `vs` pushed so that they pop in order, a comma between two.
    fn pushList(p: *Pass, vs: []const Var) Error!void {
        var k = vs.len;
        while (k > 0) {
            k -= 1;
            try p.items.append(p.scratch, .{ .type = vs[k] });
            if (k != 0) try p.items.append(p.scratch, .{ .lit = "," });
        }
    }

    fn variable(p: *Pass, s: Elaborate.Slot, v: Var) Error!void {
        if (p.holeOf(s, v)) |h| {
            try p.parts.append(p.scratch, .{ .hole = .{ .binder = h.binder, .row = h.row } });
            return;
        }
        try p.parts.append(p.scratch, .{ .unknown = v });
    }

    /// The slot's parts, written once; holes mark their binder's
    /// requirement (step 2).
    fn visit(p: *Pass, s_index: u32) Error!void {
        if (p.keyed[s_index]) return;
        p.keyed[s_index] = true;
        const s = p.in.out.slots[s_index];
        const start: u32 = @intCast(p.parts.items.len);
        p.slot_start = start;
        if (!try p.write(s)) {
            p.parts.shrinkRetainingCapacity(start);
            try p.parts.append(p.scratch, .{ .unknown = s.type });
            try p.refuse(s.inst, "This key's type is too large for me to name.\n");
        }
        p.slot_parts[s_index] = .{ .start = start, .len = @as(u32, @intCast(p.parts.items.len)) - start };
        for (p.parts.items[start..]) |part| switch (part) {
            .hole => |h| try p.mark(h.binder, h.row),
            else => {},
        };
    }

    fn refuse(p: *Pass, inst: Bir.Inst.Index, text: []const u8) Error!void {
        try p.in.report.emitText(.type_identity_unknown, inst, null, text);
    }
};

/// Where slot `s`'s evidence goes.
fn calleeOf(cx: *const Context, out: *const Elaborate.Output, lets: []const Dispatch.LetInfo, decls_len: u32, s: Elaborate.Slot) Callee {
    const bir = cx.bir;
    const d: Dispatch = .{ .sites = out.sites, .terms = out.terms, .lets = lets };
    if (d.siteOf(s.inst)) |site| if (site.callee.unwrap()) |c| {
        return switch (out.terms[c.int()]) {
            .top => |u| .{ .binder = u.decl.int() },
            .ext => |u| .{ .ext = .{ .module = u.module, .value = @backingInt(u.value) } },
            else => .none,
        };
    };
    if (s.inst.int() >= bir.insts.len) return .none;
    var ref = s.inst;
    if (bir.instTag(ref) == .call) ref = @fromBackingInt(@intCast(bir.instData(ref).lhs));
    if (ref.int() >= bir.insts.len) return .none;
    const data = bir.instData(ref);
    return switch (bir.instTag(ref)) {
        .top => .{ .binder = data.lhs },
        .ext_value => .{ .ext = .{ .module = @fromBackingInt(@intCast(data.lhs)), .value = data.rhs } },
        .local => if (s.decl < bir.decls.len) (if (d.localLet(bir, s.decl, data.lhs)) |i| Callee{ .binder = decls_len + i } else .none) else .none,
        else => .none,
    };
}

/// Whether this module is core's `Js`, whose `fingerprint` is the seed.
fn isCoreJs(cx: *const Context) bool {
    return cx.graph.modulePackage(cx.module) == .core and std.mem.eql(u8, cx.interner.slice(cx.graph.moduleName(cx.module)), "Js");
}

pub fn run(in: Input) Error!Result {
    const cx = in.cx;
    const gpa = cx.gpa;
    const scratch = cx.scratch;
    const bir = cx.bir;
    const slots = in.out.slots;
    const decls_len: u32 = @intCast(in.decls.len);

    var p: Pass = .{
        .in = in,
        .gpa = gpa,
        .scratch = scratch,
        .store = cx.store,
        .callee = try scratch.alloc(Callee, slots.len),
        .keyed = try scratch.alloc(bool, slots.len),
        .marked = try scratch.alloc(bool, in.requirements.len),
        .by_binder = &.{},
        .binder_start = &.{},
        .slot_parts = try scratch.alloc(Dispatch.Range, slots.len),
    };
    defer p.stacks.deinit(gpa);
    defer p.fields.deinit(gpa);
    @memset(p.keyed, false);
    @memset(p.marked, false);
    @memset(p.slot_parts, .empty);

    // Step 1: each slot's callee, the seeds among them, and the slots of
    // each binder of this module.
    var seeds: std.ArrayList(u32) = .empty;
    var buf: [64]u32 = undefined;
    const binders = p.binderCount();
    const counts = try scratch.alloc(u32, binders + 1);
    @memset(counts, 0);
    for (slots, p.callee, 0..) |s, *c, i| {
        c.* = calleeOf(cx, in.out, in.lets, decls_len, s);
        switch (c.*) {
            .binder => |b| if (b < binders) {
                counts[b + 1] += 1;
            } else {
                c.* = .none;
            },
            .ext => |x| {
                const n = Dispatch.extIdentities(cx.interfaces, x.module, x.value, &buf);
                for (buf[0..@min(n, buf.len)]) |j| if (j == s.root) try seeds.append(scratch, @intCast(i));
            },
            .none => {},
        }
    }
    // Core `Js`'s `fingerprint`, in its own module: identity 0.
    var seeded_decl: ?u32 = null;
    if (isCoreJs(cx)) for (bir.decls, 0..) |d, i| {
        if (d.kind != .foreign_value or i >= in.decls.len) continue;
        if (!std.mem.eql(u8, cx.interner.slice(bir.symbol(d.name)), "fingerprint")) continue;
        if (in.decls[i].requirements.len != 0) seeded_decl = @intCast(i);
    };
    if (seeds.items.len == 0 and seeded_decl == null) return .{};

    for (1..counts.len) |b| counts[b] += counts[b - 1];
    p.binder_start = counts;
    p.by_binder = try scratch.alloc(u32, slots.len);
    {
        const fill = try scratch.dupe(u32, counts);
        for (p.callee, 0..) |c, i| switch (c) {
            .binder => |b| {
                p.by_binder[fill[b]] = @intCast(i);
                fill[b] += 1;
            },
            else => {},
        };
    }

    // Step 2: to the fixpoint.
    if (seeded_decl) |d| try p.mark(d, 0);
    try p.work.appendSlice(scratch, seeds.items);
    while (p.work.pop()) |s| try p.visit(s);
    if (!p.any and seeds.items.len == 0) return .{};

    // Each binder's identities: its marked rows, in order.
    var identities: std.ArrayList(u32) = .empty;
    errdefer identities.deinit(gpa);
    // Per requirement row that is marked, its position among its binder's
    // identities.
    const position = try scratch.alloc(u32, in.requirements.len);
    @memset(position, none);
    for (0..binders) |b| {
        const r = p.reqRange(@intCast(b));
        const start: u32 = @intCast(identities.items.len);
        for (0..r.len) |k| {
            if (!p.marked[r.start + k]) continue;
            position[r.start + k] = @as(u32, @intCast(identities.items.len)) - start;
            try identities.append(gpa, @intCast(k));
        }
        const range: Dispatch.Range = .{ .start = start, .len = @as(u32, @intCast(identities.items.len)) - start };
        if (range.len == 0) continue;
        if (b < in.decls.len) in.decls[b].identities = range else in.lets[b - in.decls.len].identities = range;
    }

    // Step 3: the identity terms, and each site's roots with them.
    var terms: std.ArrayList(Dispatch.Term) = .empty;
    errdefer terms.deinit(gpa);
    try terms.appendSlice(gpa, in.out.terms);
    var args: std.ArrayList(TermIndex) = .empty;
    errdefer args.deinit(gpa);
    try args.appendSlice(gpa, in.out.args);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    const sites = try gpa.dupe(Dispatch.Site, in.out.sites);
    errdefer gpa.free(sites);
    // The keyed slots in site order: slots are recorded site by site,
    // ascending by instruction, roots in order.
    var at: usize = 0;
    var part_terms: std.ArrayList(TermIndex) = .empty;
    var ids: std.ArrayList(TermIndex) = .empty;
    for (sites) |*site| {
        while (at < slots.len and slots[at].inst.int() < site.inst.int()) at += 1;
        var end = at;
        while (end < slots.len and slots[end].inst == site.inst) end += 1;
        defer at = end;
        const wanted: []const u32 = switch (if (at < end) p.callee[at] else Callee.none) {
            .binder => |b| identitiesOf(&p, identities.items, b),
            .ext => |x| blk: {
                const n = Dispatch.extIdentities(cx.interfaces, x.module, x.value, &buf);
                break :blk buf[0..@min(n, buf.len)];
            },
            .none => &.{},
        };
        if (wanted.len == 0) continue;
        ids.clearRetainingCapacity();
        for (wanted) |j| {
            const s = for (at..end) |k| {
                if (slots[k].root == j and p.keyed[k]) break k;
            } else {
                // A callee's identity with no slot to supply it: the
                // evidence-count assert names it after the module's last
                // error (checker-v2.md §13.1).
                continue;
            };
            part_terms.clearRetainingCapacity();
            const id_index: u32 = @intCast(terms.items.len);
            try terms.append(gpa, .{ .identity = .empty });
            const r = p.slot_parts[s];
            for (p.parts.items[r.start..][0..r.len]) |part| {
                const t: Dispatch.Term = switch (part) {
                    .text => |x| blk: {
                        const start: u32 = @intCast(text.items.len);
                        try text.appendSlice(gpa, p.bytes.items[x.start..][0..x.len]);
                        break :blk .{ .text = .{ .start = start, .len = x.len } };
                    },
                    .hole => |h| holeTerm(&p, h.binder, h.row, position),
                    .unknown => |v| blk: {
                        if (try unknownRefused(&p, slots[s], v)) {
                            try p.refuse(site.inst, try unknownText(&p, v));
                        }
                        const start: u32 = @intCast(text.items.len);
                        const word = undeterminedText(&p, v);
                        try text.appendSlice(gpa, word);
                        break :blk .{ .text = .{ .start = start, .len = @intCast(word.len) } };
                    },
                };
                // Two texts in a row are one.
                if (t == .text and part_terms.items.len != 0) {
                    const last = &terms.items[part_terms.items[part_terms.items.len - 1].int()];
                    if (last.* == .text and last.text.start + last.text.len == t.text.start) {
                        last.text.len += t.text.len;
                        continue;
                    }
                }
                try part_terms.append(scratch, @fromBackingInt(@intCast(@as(u32, @intCast(terms.items.len)))));
                try terms.append(gpa, t);
            }
            const parts_start: u32 = @intCast(args.items.len);
            try args.appendSlice(gpa, part_terms.items);
            terms.items[id_index] = .{ .identity = .{ .start = parts_start, .len = @intCast(part_terms.items.len) } };
            try ids.append(scratch, @fromBackingInt(@intCast(id_index)));
        }
        // The roots, then the identities: one run at the end of `args`.
        const roots = in.out.args[site.evidence.start..][0..site.evidence.len];
        const roots_start: u32 = @intCast(args.items.len);
        try args.appendSlice(gpa, roots);
        try args.appendSlice(gpa, ids.items);
        site.evidence = .{ .start = roots_start, .len = @intCast(roots.len + ids.items.len) };
    }

    // Step 4: a declaration that takes identities, named as evidence.
    try refuseAsEvidence(&p, terms.items, args.items, sites, identities.items);

    gpa.free(in.out.terms);
    gpa.free(in.out.args);
    gpa.free(in.out.sites);
    in.out.terms = try terms.toOwnedSlice(gpa);
    in.out.args = try args.toOwnedSlice(gpa);
    in.out.sites = sites;
    return .{ .identities = try identities.toOwnedSlice(gpa), .text = try text.toOwnedSlice(gpa) };
}

fn identitiesOf(p: *const Pass, all: []const u32, b: u32) []const u32 {
    const r = if (b < p.in.decls.len) p.in.decls[b].identities else p.in.lets[b - p.in.decls.len].identities;
    if (r.len == 0) return &.{};
    return all[r.start..][0..r.len];
}

/// The `param` a hole reads: its binder's identity parameter, numbered on
/// from its evidence.
fn holeTerm(p: *const Pass, b: u32, row: u32, position: []const u32) Dispatch.Term {
    const r = p.reqRange(b);
    const k = r.len + position[r.start + row];
    if (b < p.in.decls.len) return .{ .param = .{ .binder = .decl, .k = k } };
    return .{ .param = .{ .binder = .{ .let = p.in.lets[b - p.in.decls.len].inst }, .k = k } };
}

/// Whether a variable no requirement roots is one a value can hold at the
/// site: an annotation's, or one the binders' types reach. Then there is
/// no parameter to read its identity from.
fn unknownRefused(p: *Pass, s: Elaborate.Slot, v: Var) Error!bool {
    const root, const c = p.store.resolved(v);
    switch (c) {
        .rigid => return true,
        .flex => {},
        else => return false,
    }
    var l = s.let;
    while (l != Elaborate.no_let and l < p.in.lets.len) : (l = if (l < p.in.out.let_parent.len) p.in.out.let_parent[l] else Elaborate.no_let) {
        if (l < p.in.let_schemes.len and try Walk.reachesThroughRequirements(p.store, &p.stacks, p.gpa, p.in.let_schemes[l], root)) return true;
    }
    if (s.decl < p.in.decl_scheme.len) if (p.in.decl_scheme[s.decl].unwrap()) |scheme| {
        if (try Walk.reachesThroughRequirements(p.store, &p.stacks, p.gpa, scheme, root)) return true;
    };
    return false;
}

/// A variable no value of which can reach the site: an `Int` when it is a
/// `number` nothing settled (what its literals are), else `_`.
fn undeterminedText(p: *Pass, v: Var) []const u8 {
    _, const c = p.store.resolved(v);
    switch (c) {
        .flex => |f| if (f.kind == .number) return "core:Basics.Int",
        else => {},
    }
    return "_";
}

fn unknownText(p: *Pass, v: Var) Error![]const u8 {
    _, const c = p.store.resolved(v);
    const name: []const u8 = switch (c) {
        .flex, .rigid => |f| if (f.name.unwrap()) |n| p.in.cx.interner.slice(n) else "a",
        else => "a",
    };
    return std.fmt.allocPrint(p.scratch,
        \\This key's type mentions `{s}`, a type variable no `where` clause here
        \\constrains, so I cannot tell which type the key is of.
        \\
        \\A key carries its type's identity (`docs/design/boundary.md` §9.8.3), and a
        \\function generic over the type passes on its own: it has one for each type
        \\variable it has a requirement on.
        \\
        \\Hint: add `where {s}.compare : {s}, {s} → Order` to the annotation.
        \\
    , .{ name, name, name, name });
}

/// Step 4: a `top` or `ext` term that takes identities anywhere but as a
/// site's callee — evidence, called with the values it compares, has no
/// room for one.
fn refuseAsEvidence(p: *Pass, terms: []const Dispatch.Term, args: []const TermIndex, sites: []const Dispatch.Site, identities: []const u32) Error!void {
    const cx = p.in.cx;
    const takes = try p.scratch.alloc(bool, terms.len);
    var buf: [1]u32 = undefined;
    var any = false;
    for (terms, takes) |t, *x| {
        x.* = switch (t) {
            .top => |u| u.decl.int() < p.in.decls.len and p.in.decls[u.decl.int()].identities.len != 0,
            .ext => |u| Dispatch.extIdentities(cx.interfaces, u.module, @backingInt(u.value), &buf) != 0,
            else => false,
        };
        any = any or x.*;
    }
    _ = identities;
    if (!any) return;
    const seen = try p.scratch.alloc(u32, terms.len);
    @memset(seen, none);
    var stack: std.ArrayList(TermIndex) = .empty;
    for (sites, 0..) |site, si| {
        stack.clearRetainingCapacity();
        // Every root is evidence too: only the callee is called directly.
        try stack.appendSlice(p.scratch, args[site.evidence.start..][0..site.evidence.len]);
        if (site.callee.unwrap()) |c| for (argsOfTerm(terms, args, c)) |a| try stack.append(p.scratch, a);
        while (stack.pop()) |t| {
            if (seen[t.int()] == si) continue;
            seen[t.int()] = @intCast(si);
            if (takes[t.int()]) {
                try p.refuse(site.inst,
                    \\This passes on a method that needs a type's identity, as the way to compare
                    \\or handle the values something else holds. A method passed on is called with
                    \\those values alone, so there is no room for the identity.
                    \\
                    \\Hint: call the method directly on the values, not through a type that
                    \\holds them.
                    \\
                );
                break;
            }
            for (argsOfTerm(terms, args, t)) |a| try stack.append(p.scratch, a);
        }
    }
    // A derived function's body: every position is evidence.
    for (p.in.out.derived, 0..) |row, ri| {
        const stamp: u32 = @intCast(sites.len + ri);
        stack.clearRetainingCapacity();
        if (row.body.len != 0) try stack.appendSlice(p.scratch, args[row.body.start..][0..row.body.len]);
        while (stack.pop()) |t| {
            if (seen[t.int()] == stamp) continue;
            seen[t.int()] = stamp;
            if (takes[t.int()]) {
                var region: Bir.Inst.Index = @fromBackingInt(@intCast(0));
                if (row.shape == .nominal) {
                    const entry = cx.types.entry(row.shape.nominal);
                    if (entry.decl.int() < cx.bir.decls.len) region = cx.bir.decls[entry.decl.int()].inst_start;
                }
                try p.refuse(region,
                    \\This type's derived comparison compares a value whose method needs a type's
                    \\identity, and a method is passed as a function of the values it compares,
                    \\with no room for one.
                    \\
                );
                break;
            }
            for (argsOfTerm(terms, args, t)) |a| try stack.append(p.scratch, a);
        }
    }
}

fn argsOfTerm(terms: []const Dispatch.Term, args: []const TermIndex, t: TermIndex) []const TermIndex {
    const r = terms[t.int()].argsOf();
    if (r.len == 0) return &.{};
    return args[r.start..][0..r.len];
}
