//! The checker → backend dispatch table (docs/design/static-dispatch-spike.md
//! §7): one per module, flat, index-based, immutable once built.
//!
//! The backend sees no types (`backend.md` §3), so everything the checker
//! decided about a method call has to cross as DATA. This is that data, in
//! the shape of `Bir.refs`: four parallel tables of plain records, every
//! index resolved before anything reads them.
//!
//! **Sorted before anything indexes it.** `derived` is sorted by emitted
//! name text and `sites` by `(inst, evidence_index)` at the end of the
//! module's check, and `Target.derived` / `Derived.parts` index the SORTED
//! arrays — so the table a dump prints and the table the emitter walks are
//! one table in one order, and `--jobs` cannot move a byte of either
//! (§7.1, A.29, CLAUDE.md rule 5).
//!
//! **One level of evidence, no depth.** `Target.evidence` is a single `u16`
//! because §6.4 rule (a) keeps a `let` binding from being generalised over
//! a constrained variable, so only a top-level declaration ever has
//! evidence parameters and a lambda inside its body captures `$m$k`
//! lexically (A.31). Roc's `EvidenceChainIndex { depth, index }` has no
//! counterpart here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");

const Dispatch = @This();

pub const Symbol = InternPool.Symbol;
pub const TypeId = TypeStore.TypeId;

/// A half-open run of a sidecar table.
pub const Range = struct {
    start: u32 = 0,
    len: u32 = 0,

    pub const empty: Range = .{};
};

/// What a derived function is derived FOR. There is no `prim` shape: a
/// primitive is a `Target`.
pub const Shape = union(enum(u8)) {
    /// A `type`, `opaque type` or `foreign type`.
    nominal: TypeId,
    /// The field names, sorted by name text: a range of `symbols`.
    record: Range,
    /// The arity.
    tuple: u8,
    unit,
};

/// Which function a site calls, or which value it passes.
pub const Target = union(enum(u8)) {
    /// A value of this module, and the evidence this use passes it.
    top: TopUse,
    ext: Ext,
    /// The `k`th evidence parameter of the ENCLOSING declaration. One
    /// level, no depth — §6.4 proves why.
    evidence: u16,
    primitive: Primitive,
    /// A derived function THIS module emits, and the evidence this use
    /// passes it (§9.2, A.11, A.46).
    derived: DerivedUse,
    /// A derived function of another module's nominal type, named by
    /// `<Module>$<Type>$<kind>` (§8.5). It is not in this module's
    /// `derived` table: that table is exactly what this module EMITS
    /// (A.47).
    ext_derived: ExtDerivedUse,
    /// A record receiver: a plain field call.
    field,
    err,

    /// **A `top` or `ext` in a PART position carries its own evidence**
    /// (§7.1 amendment, A.64). At a call site the evidence of a
    /// constrained value rides on the sites that follow it (§8.2), because
    /// §7.2 numbers them into one flat list; inside a `parts` tree there
    /// is no site to number, so the tree has to carry it. Without the
    /// range, `{ p : { x : Int }, q : List Int } == …` wrote
    /// `part 1 ext List eq` with nothing under it and the emitted call to
    /// `List$eq` — which takes `(m0, xs, ys)` once §5.2 lands — was one
    /// argument short.
    ///
    /// EMPTY at a call site, where the site list carries the same
    /// evidence: a target is never handed both, and the emitter reads
    /// `partsOf()` first for exactly that reason.
    pub const TopUse = struct {
        decl: Bir.DeclIndex,
        parts: Range = .empty,
    };

    pub const Ext = struct {
        module: Graph.Index,
        value: Interface.ValueIndex,
        parts: Range = .empty,
    };

    /// **The evidence is per USE, never per function** (A.11, A.46). A
    /// structural derived function is keyed on its shape alone — the field
    /// names or the arity — and is parameterised by one evidence argument
    /// per element, so `{ x : Int, y : Int }` and `{ x : String, y : String }`
    /// share one `r$x$y` and differ only in what they are handed. Baking
    /// the first requester's element targets into the function is what made
    /// `( String, String ) < …` order strings with JavaScript `<`.
    pub const DerivedUse = struct {
        /// Index into `derived`.
        index: u32,
        /// One `Target` per evidence parameter, in shape order: a range of
        /// `parts`. Recursive — a nested record or tuple position is itself
        /// a `derived` target with its own range.
        parts: Range = .empty,
    };

    pub const ExtDerivedUse = struct {
        module: Graph.Index,
        type: TypeId,
        kind: Derived.Kind,
        parts: Range = .empty,
    };

    pub const Primitive = enum(u8) { strict_eq, num_compare, char_compare, string_compare };

    /// The evidence arguments this target passes, or an empty range.
    pub fn partsOf(t: Target) Range {
        return switch (t) {
            .derived => |d| d.parts,
            .ext_derived => |d| d.parts,
            .top => |d| d.parts,
            .ext => |e| e.parts,
            else => .empty,
        };
    }
};

pub const Site = struct {
    inst: Bir.Inst.Index,
    evidence_index: u16,
    target: Target,
};

/// One evidence parameter of one declaration: which quantifier of its
/// scheme it came from, and which method. Recorded so the dump can name it
/// and so a caller/callee disagreement is a caught bug rather than a silent
/// miscompile (§7.2).
pub const Evidence = struct {
    quantified: u16,
    var_name: Symbol.Optional,
    method: Symbol,
};

/// One evidence parameter of an ANNOTATED declaration, keyed by the rigid
/// variable it sits on. Built by `Check` from the annotation's `where`
/// clause in the canonical order of §7.2, so a constraint discharged
/// against a rigid knows which hidden parameter answers it without
/// re-deriving the order.
pub const RigidEvidence = struct { v: TypeStore.Var, method: Symbol, index: u16 };

/// One function this module emits (§9). Keyed on `(kind, shape)` and
/// NOTHING else: what varies between two uses is the evidence, which rides
/// on the `Target` (A.46).
pub const Derived = struct {
    kind: Kind,
    shape: Shape,
    /// How many evidence parameters it takes: one per field, element or
    /// type parameter, in shape order — for a parametric nominal type,
    /// one per parameter whether the parameter is used or not (A.20).
    evidence_count: u16 = 0,
    /// The BODY's per-structural-position targets, a range of `parts`:
    /// every constructor argument of a nominal shape, constructors in
    /// declaration order and arguments left to right (§9's parts
    /// contract). A position whose type is the type's own parameter `i`
    /// is `evidence i`.
    ///
    /// EMPTY for a record, a tuple or `()`: such a body is
    /// `$m$0 … $m$n-1` applied position by position by construction
    /// (§9.2, §9.3), so there is nothing a table could say that the shape
    /// does not already.
    parts: Range = .empty,

    pub const Kind = enum(u8) { eq, compare };
};

sites: []const Site = &.{},
/// Per declaration, into `evidence`.
decl_evidence: []const Range = &.{},
/// Canonical order within each declaration (§7.2).
evidence: []const Evidence = &.{},
/// Sorted by emitted name text (§8.5). Exactly the functions this module
/// emits: a derived method of another module's type is an `ext_derived`
/// target and has no row here (A.47).
derived: []const Derived = &.{},
/// The evidence arguments of every `derived`/`ext_derived` target, and the
/// body positions of every nominal `Derived`. Ranges into it nest.
parts: []const Target = &.{},
/// The names `Shape.record` ranges over.
symbols: []const Symbol = &.{},

pub const empty: Dispatch = .{};

pub fn deinit(d: *Dispatch, gpa: Allocator) void {
    gpa.free(d.sites);
    gpa.free(d.decl_evidence);
    gpa.free(d.evidence);
    gpa.free(d.derived);
    gpa.free(d.parts);
    gpa.free(d.symbols);
    d.* = .empty;
}

/// The evidence parameters of `decl`, in canonical order.
pub fn declEvidence(d: *const Dispatch, decl: u32) []const Evidence {
    if (decl >= d.decl_evidence.len) return &.{};
    const r = d.decl_evidence[decl];
    return d.evidence[r.start..][0..r.len];
}

/// The field names of a record shape.
pub fn shapeNames(d: *const Dispatch, r: Range) []const Symbol {
    return d.symbols[r.start..][0..r.len];
}

pub fn partsAt(d: *const Dispatch, r: Range) []const Target {
    if (r.len == 0) return &.{};
    return d.parts[r.start..][0..r.len];
}

// ---------------------------------------------------------------------------
// The builder
// ---------------------------------------------------------------------------

/// Accumulates the five tables while a module is checked; `finish` sorts
/// and remaps them once, at the end of `ModuleCheck.run`.
///
/// Every list here is APPEND-ONLY and rolled back by truncating its length,
/// which is what lets `dischargeMethod` run under a `?` probe (§6.1
/// invariant 2, A.35). `Lengths`/`shrink` are that rollback.
pub const Builder = struct {
    gpa: Allocator,
    sites: std.ArrayList(Site) = .empty,
    evidence: std.ArrayList(Evidence) = .empty,
    derived: std.ArrayList(Derived) = .empty,
    parts: std.ArrayList(Target) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    /// `decl_evidence`, filled per declaration as its rank generalises.
    decl_evidence: std.ArrayList(Range) = .empty,

    pub const Lengths = struct { sites: usize, evidence: usize, derived: usize, parts: usize, symbols: usize };

    pub fn deinit(b: *Builder) void {
        b.sites.deinit(b.gpa);
        b.evidence.deinit(b.gpa);
        b.derived.deinit(b.gpa);
        b.parts.deinit(b.gpa);
        b.symbols.deinit(b.gpa);
        b.decl_evidence.deinit(b.gpa);
    }

    pub fn lengths(b: *const Builder) Lengths {
        return .{
            .sites = b.sites.items.len,
            .evidence = b.evidence.items.len,
            .derived = b.derived.items.len,
            .parts = b.parts.items.len,
            .symbols = b.symbols.items.len,
        };
    }

    pub fn shrink(b: *Builder, to: Lengths) void {
        b.sites.shrinkRetainingCapacity(to.sites);
        b.evidence.shrinkRetainingCapacity(to.evidence);
        b.derived.shrinkRetainingCapacity(to.derived);
        b.parts.shrinkRetainingCapacity(to.parts);
        b.symbols.shrinkRetainingCapacity(to.symbols);
    }

    pub fn addSite(b: *Builder, site: Site) Allocator.Error!void {
        try b.sites.append(b.gpa, site);
    }

    pub fn addSymbols(b: *Builder, names: []const Symbol) Allocator.Error!Range {
        const start: u32 = @intCast(b.symbols.items.len);
        try b.symbols.appendSlice(b.gpa, names);
        return .{ .start = start, .len = @intCast(names.len) };
    }

    pub fn addParts(b: *Builder, targets: []const Target) Allocator.Error!Range {
        const start: u32 = @intCast(b.parts.items.len);
        try b.parts.appendSlice(b.gpa, targets);
        return .{ .start = start, .len = @intCast(targets.len) };
    }

    /// The index of the derived function for `(kind, shape)`, creating it
    /// when it is new.
    ///
    /// **Deduplicated on the shape alone** — never on what a use hands it —
    /// which is what makes one `r$x$y` serve every record with those field
    /// names whatever their field types (§9.2, A.11, A.46).
    pub fn derive(b: *Builder, kind: Derived.Kind, shape: Shape, evidence_count: u16) Allocator.Error!u32 {
        if (b.findDerived(kind, shape)) |existing| return existing;
        const index: u32 = @intCast(b.derived.items.len);
        try b.derived.append(b.gpa, .{ .kind = kind, .shape = shape, .evidence_count = evidence_count });
        return index;
    }

    pub fn findDerived(b: *const Builder, kind: Derived.Kind, shape: Shape) ?u32 {
        for (b.derived.items, 0..) |d, i| {
            if (d.kind == kind and shapeEql(b, d.shape, shape)) return @intCast(i);
        }
        return null;
    }

    /// Give a nominal `Derived` the body positions of §9's parts contract.
    /// Set once, by the eager pass of A.23, after the entry exists — a
    /// recursive type's own derived function is a part of itself.
    pub fn setDerivedParts(b: *Builder, index: u32, parts: Range) void {
        b.derived.items[index].parts = parts;
    }

    /// Reserve `n` part slots and return their range, so a recursive
    /// resolution can fill them after the entry that names them exists.
    pub fn reserveParts(b: *Builder, n: usize) Allocator.Error!Range {
        const start: u32 = @intCast(b.parts.items.len);
        try b.parts.appendNTimes(b.gpa, .err, n);
        return .{ .start = start, .len = @intCast(n) };
    }

    pub fn setPart(b: *Builder, range: Range, i: usize, target: Target) void {
        b.parts.items[range.start + i] = target;
    }

    fn shapeEql(b: *const Builder, a: Shape, c: Shape) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(c)) return false;
        return switch (a) {
            .nominal => |t| t == c.nominal,
            .record => |r| blk: {
                const o = c.record;
                if (r.len != o.len) break :blk false;
                break :blk std.mem.eql(
                    Symbol,
                    b.symbols.items[r.start..][0..r.len],
                    b.symbols.items[o.start..][0..o.len],
                );
            },
            .tuple => |n| n == c.tuple,
            .unit => true,
        };
    }

    /// Record one declaration's evidence list and return its range.
    pub fn addEvidence(b: *Builder, items: []const Evidence) Allocator.Error!Range {
        const start: u32 = @intCast(b.evidence.items.len);
        try b.evidence.appendSlice(b.gpa, items);
        return .{ .start = start, .len = @intCast(items.len) };
    }

    pub fn setDeclEvidence(b: *Builder, decl_count: usize, decl: u32, r: Range) Allocator.Error!void {
        while (b.decl_evidence.items.len < decl_count) try b.decl_evidence.append(b.gpa, .{});
        if (decl < b.decl_evidence.items.len) b.decl_evidence.items[decl] = r;
    }

    /// Patch the target of an already-appended site. Used once, by
    /// generalisation, for a constraint that was promoted rather than
    /// discharged (§6.4): the site is known when the constraint is created,
    /// the evidence index only when the scheme's canonical order is
    /// (§7.2).
    pub fn setSiteTarget(b: *Builder, index: u32, target: Target) void {
        b.sites.items[index].target = target;
    }

    /// Move the tables out, sorted (§7.1, §7.3). `name_of` spells a derived
    /// function so the sort is by EMITTED NAME TEXT and not by request
    /// order.
    pub fn finish(
        b: *Builder,
        gpa: Allocator,
        decl_count: usize,
        scratch: Allocator,
        name_of: *const fn (ctx: *anyopaque, d: Derived, out: *std.ArrayList(u8), a: Allocator) Allocator.Error!void,
        ctx: *anyopaque,
    ) Allocator.Error!Dispatch {
        // `derived` is sorted first, because everything else indexes it.
        const n = b.derived.items.len;
        const order = try scratch.alloc(u32, n);
        defer scratch.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        var names = try scratch.alloc([]const u8, n);
        defer {
            for (names) |name| scratch.free(name);
            scratch.free(names);
        }
        for (b.derived.items, 0..) |d, i| {
            var buf: std.ArrayList(u8) = .empty;
            try name_of(ctx, d, &buf, scratch);
            names[i] = try buf.toOwnedSlice(scratch);
        }
        const Sorter = struct {
            names: [][]const u8,
            fn lessThan(self: @This(), x: u32, y: u32) bool {
                return switch (std.mem.order(u8, self.names[x], self.names[y])) {
                    .lt => true,
                    .gt => false,
                    .eq => x < y,
                };
            }
        };
        std.mem.sort(u32, order, Sorter{ .names = names }, Sorter.lessThan);
        const remap = try scratch.alloc(u32, n);
        defer scratch.free(remap);
        for (order, 0..) |old, new| remap[old] = @intCast(new);

        const derived = try gpa.alloc(Derived, n);
        errdefer gpa.free(derived);
        for (order, 0..) |old, new| derived[new] = b.derived.items[old];

        const parts = try gpa.dupe(Target, b.parts.items);
        errdefer gpa.free(parts);
        for (parts) |*t| remapTarget(t, remap);

        const sites = try gpa.dupe(Site, b.sites.items);
        errdefer gpa.free(sites);
        for (sites) |*s| remapTarget(&s.target, remap);
        std.mem.sort(Site, sites, {}, siteLessThan);

        while (b.decl_evidence.items.len < decl_count) try b.decl_evidence.append(b.gpa, .{});
        return .{
            .sites = sites,
            .decl_evidence = try gpa.dupe(Range, b.decl_evidence.items),
            .evidence = try gpa.dupe(Evidence, b.evidence.items),
            .derived = derived,
            .parts = parts,
            .symbols = try gpa.dupe(Symbol, b.symbols.items),
        };
    }

    fn remapTarget(t: *Target, remap: []const u32) void {
        switch (t.*) {
            .derived => |d| t.* = .{ .derived = .{ .index = remap[d.index], .parts = d.parts } },
            else => {},
        }
    }

    fn siteLessThan(_: void, a: Site, c: Site) bool {
        if (a.inst != c.inst) return a.inst.int() < c.inst.int();
        return a.evidence_index < c.evidence_index;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the builder's lengths and shrink are an exact rollback" {
    // static-dispatch-spike.md §6.1 invariant 2 and A.35: §6.2 registers
    // obligations from inside `unify`, so `dischargeMethod` — and every
    // site it appends — can run under the `?` probe of `checker.md` §6.5
    // and be retracted. A site a retracted probe left behind is an argument
    // the emitter would pass to a call the checker decided against.
    //
    // `Solve.tryShape` calls exactly this pair; what it has to be able to
    // rely on is that every one of the five tables goes back.
    var b: Builder = .{ .gpa = testing.allocator };
    defer b.deinit();

    const before = b.lengths();
    try testing.expectEqual(@as(usize, 0), before.sites);

    const shape_names = try b.addSymbols(&.{ @enumFromInt(3), @enumFromInt(4) });
    const index = try b.derive(.eq, .{ .record = shape_names }, 2);
    const parts = try b.reserveParts(2);
    b.setPart(parts, 0, .{ .primitive = .strict_eq });
    b.setPart(parts, 1, .{ .primitive = .strict_eq });
    try b.addSite(.{ .inst = @enumFromInt(7), .evidence_index = 0, .target = .{ .derived = .{ .index = index, .parts = parts } } });
    _ = try b.addEvidence(&.{.{ .quantified = 0, .var_name = .none, .method = @enumFromInt(9) }});

    const after = b.lengths();
    try testing.expect(after.sites > before.sites);
    try testing.expect(after.derived > before.derived);
    try testing.expect(after.parts > before.parts);
    try testing.expect(after.symbols > before.symbols);
    try testing.expect(b.evidence.items.len > 0);

    b.shrink(before);
    const rolled = b.lengths();
    try testing.expectEqual(before.sites, rolled.sites);
    try testing.expectEqual(before.derived, rolled.derived);
    try testing.expectEqual(before.parts, rolled.parts);
    try testing.expectEqual(before.symbols, rolled.symbols);
    try testing.expectEqual(before.evidence, rolled.evidence);
    // And the builder is usable afterwards: a probe that fails is followed
    // by one that does not.
    _ = try b.derive(.compare, .unit, 0);
    try testing.expectEqual(@as(usize, 1), b.derived.items.len);
}

test "a derived function is deduplicated on its shape alone" {
    // A.11 and A.46: `{ x : Int, y : Int }` and `{ x : String, y : String }`
    // are ONE function with two evidence parameters, and what tells the two
    // uses apart is the `Target`'s own parts — never the `Derived`'s.
    var b: Builder = .{ .gpa = testing.allocator };
    defer b.deinit();
    const names = try b.addSymbols(&.{ @enumFromInt(1), @enumFromInt(2) });
    const again = try b.addSymbols(&.{ @enumFromInt(1), @enumFromInt(2) });
    const first = try b.derive(.eq, .{ .record = names }, 2);
    const second = try b.derive(.eq, .{ .record = again }, 2);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 1), b.derived.items.len);
    // A different KIND is a different function.
    try testing.expect(try b.derive(.compare, .{ .record = names }, 2) != first);
}
