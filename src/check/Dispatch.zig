//! The checker → backend dispatch table (docs/design/static-dispatch-spike.md
//! §7): one per module, flat, index-based, immutable once built.
//!
//! The backend sees no types (`backend.md` §3), so everything the checker
//! decided about a method call has to cross as DATA. This is that data, in
//! the shape of `Bir.refs`: four parallel tables of plain records, every
//! index resolved before anything reads them.
//!
//! **Sorted before anything indexes it.** `derived` is sorted by emitted
//! name text at the end of the module's check, and `Target.derived` /
//! `Derived.parts` index the SORTED arrays — so the table a dump prints and
//! the table the emitter walks are one table in one order, and `--jobs`
//! cannot move a byte of either (§7.1, A.29, CLAUDE.md rule 5). `sites` is
//! grouped by `inst` and then put into the PRE-ORDER of §7.2's evidence
//! tree, which is not the order its indices run in; `Site.parent` says why.
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
    /// Which slot of the same instruction this one hangs under, or
    /// `no_parent` for a slot the instruction owns outright.
    ///
    /// **The list is flat and the tree is real** (§7.2, §8.2). Resolving a
    /// slot can instantiate the scheme that ANSWERS it, and that scheme's
    /// own `where` clause is a further slot of the SAME instruction; the
    /// emitter reads the flat list as a pre-order walk of that tree, a
    /// target consuming the slots that follow it. The cursor that numbers
    /// them runs in ALLOCATION order, which is breadth-first — an
    /// instantiation numbers all of its own slots at once, before any of
    /// them is discharged — so `pair [ [ 1 ] ] [ [ 2 ] ]` under
    /// `pair : a, b -> Bool where a.eq : …, b.eq : …` numbered `a`'s child
    /// AFTER `b` and the pre-order walk then read it as `a`'s grandchild
    /// (A.68). The parent is what `Builder.finish` orders the list by, so
    /// the ORDER is the tree and `evidence_index` is only the identity the
    /// checker's two deduplicating tables key on.
    parent: u16 = no_parent,
    target: Target,

    /// A slot no other slot of its instruction asked for: a root of the
    /// forest `finish` walks.
    pub const no_parent: u16 = std.math.maxInt(u16);
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

/// Which shape every `?` of this module turned out to have (§6.5), sorted
/// by instruction.
///
/// **It is a decision and not a lookup, so it has to cross as data.** The
/// backend sees no types (`backend.md` §3), and `Maybe` and `Result` are
/// the one construct where the emitted JavaScript differs by a type the
/// program never wrote: the failure test is the `Nothing` tag or the `Err`
/// tag and there is no pattern at the `?` to read either off. `checker.md`
/// §6.5 settles it by speculation, and what the speculation chose is this.
pub const Try = struct {
    inst: Bir.Inst.Index,
    shape: Kind,

    /// Named `Kind` and not `Shape` because `Shape` above is what a DERIVED
    /// function is derived for, and one file may not spell two things one
    /// way.
    pub const Kind = enum(u8) { maybe, result };
};

sites: []const Site = &.{},
/// One per `try` instruction that solved, ascending by instruction.
tries: []const Try = &.{},
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
    gpa.free(d.tries);
    gpa.free(d.decl_evidence);
    gpa.free(d.evidence);
    gpa.free(d.derived);
    gpa.free(d.parts);
    gpa.free(d.symbols);
    d.* = .empty;
}

/// Which shape the `?` at `inst` has, or `null` when the checker recorded
/// none — a `try` that never solved, which cannot reach the emitter from a
/// build that checked clean. One binary search over a table with one row
/// per `?` in the module.
pub fn tryShape(d: *const Dispatch, inst: Bir.Inst.Index) ?Try.Kind {
    var lo: usize = 0;
    var hi: usize = d.tries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const at = d.tries[mid].inst;
        if (at == inst) return d.tries[mid].shape;
        if (at.int() < inst.int()) lo = mid + 1 else hi = mid;
    }
    return null;
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
    tries: std.ArrayList(Try) = .empty,
    evidence: std.ArrayList(Evidence) = .empty,
    derived: std.ArrayList(Derived) = .empty,
    parts: std.ArrayList(Target) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    /// `decl_evidence`, filled per declaration as its rank generalises.
    decl_evidence: std.ArrayList(Range) = .empty,

    pub const Lengths = struct {
        sites: usize,
        /// A `?`'s own shape probe rolls the builder back between its two
        /// guesses (§6.5), and a `?` may sit inside another one's probe, so
        /// the shapes are rolled back with everything else — or a retracted
        /// guess would decide the emitted test.
        tries: usize,
        evidence: usize,
        derived: usize,
        parts: usize,
        symbols: usize,
    };

    pub fn deinit(b: *Builder) void {
        b.sites.deinit(b.gpa);
        b.tries.deinit(b.gpa);
        b.evidence.deinit(b.gpa);
        b.derived.deinit(b.gpa);
        b.parts.deinit(b.gpa);
        b.symbols.deinit(b.gpa);
        b.decl_evidence.deinit(b.gpa);
    }

    pub fn lengths(b: *const Builder) Lengths {
        return .{
            .sites = b.sites.items.len,
            .tries = b.tries.items.len,
            .evidence = b.evidence.items.len,
            .derived = b.derived.items.len,
            .parts = b.parts.items.len,
            .symbols = b.symbols.items.len,
        };
    }

    pub fn shrink(b: *Builder, to: Lengths) void {
        b.sites.shrinkRetainingCapacity(to.sites);
        b.tries.shrinkRetainingCapacity(to.tries);
        b.evidence.shrinkRetainingCapacity(to.evidence);
        b.derived.shrinkRetainingCapacity(to.derived);
        b.parts.shrinkRetainingCapacity(to.parts);
        b.symbols.shrinkRetainingCapacity(to.symbols);
    }

    pub fn addSite(b: *Builder, site: Site) Allocator.Error!void {
        try b.sites.append(b.gpa, site);
    }

    /// Record the shape a `?` solved as. Appended in the order the solver
    /// reaches them and sorted by `finish`, like `sites`.
    pub fn addTry(b: *Builder, entry: Try) Allocator.Error!void {
        try b.tries.append(b.gpa, entry);
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
        try preorderSites(sites, scratch);

        // One row per `?`, ascending, so the emitter can search it. A
        // duplicate is possible only if one instruction solved twice, and
        // the two rows then agree — the shape is a function of the types —
        // so the sort is by instruction alone and the first row wins.
        const tries = try gpa.dupe(Try, b.tries.items);
        errdefer gpa.free(tries);
        std.mem.sort(Try, tries, {}, tryLessThan);

        while (b.decl_evidence.items.len < decl_count) try b.decl_evidence.append(b.gpa, .{});
        return .{
            .sites = sites,
            .tries = tries,
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

    fn tryLessThan(_: void, a: Try, c: Try) bool {
        return a.inst.int() < c.inst.int();
    }

    fn siteLessThan(_: void, a: Site, c: Site) bool {
        if (a.inst != c.inst) return a.inst.int() < c.inst.int();
        return a.evidence_index < c.evidence_index;
    }

    /// Put each instruction's slots into the PRE-ORDER of §7.2's evidence
    /// tree, which is the order `Lower.evidenceArguments` reads the flat
    /// list in.
    ///
    /// Called on a list already sorted by `(inst, evidence_index)`, so the
    /// instructions are contiguous — which `Lower.siteRangeOf`'s binary
    /// search needs and this must not disturb — and within one instruction
    /// a slot's parent, numbered before it was, always sits EARLIER in the
    /// group. That one fact is what makes the whole walk a forward pass:
    /// each slot's path from its root is its parent's path with its own
    /// index appended, and sorting the group by that path lexicographically
    /// is the pre-order. A parent's path is a strict prefix of its child's,
    /// so a parent always precedes every descendant; two siblings differ
    /// first at their own indices, so they keep the cursor's order.
    ///
    /// Deterministic without qualification: the paths are a function of the
    /// (already deterministic) site list alone, the comparison is total —
    /// ties, which unique indices make unreachable, fall back on the
    /// position — and nothing here reads a clock, a pointer or a thread id
    /// (CLAUDE.md rule 5).
    fn preorderSites(sites: []Site, scratch: Allocator) Allocator.Error!void {
        var start: usize = 0;
        while (start < sites.len) {
            var end = start + 1;
            while (end < sites.len and sites[end].inst == sites[start].inst) end += 1;
            try preorderGroup(sites[start..end], scratch);
            start = end;
        }
    }

    fn preorderGroup(group: []Site, scratch: Allocator) Allocator.Error!void {
        if (group.len < 2) return;

        // `paths[i]` is the chain of evidence indices from `group[i]`'s root
        // down to `group[i]`, as a run of `flat`.
        var flat: std.ArrayList(u16) = .empty;
        defer flat.deinit(scratch);
        const paths = try scratch.alloc(Range, group.len);
        defer scratch.free(paths);
        for (group, 0..) |s, i| {
            const parent: ?usize = if (s.parent == Site.no_parent) null else slotAt(group[0..i], s.parent);
            const inherited: Range = if (parent) |j| paths[j] else .empty;
            try flat.ensureUnusedCapacity(scratch, inherited.len + 1);
            flat.appendSliceAssumeCapacity(flat.items[inherited.start..][0..inherited.len]);
            flat.appendAssumeCapacity(s.evidence_index);
            paths[i] = .{ .start = @intCast(flat.items.len - inherited.len - 1), .len = inherited.len + 1 };
        }

        const order = try scratch.alloc(u32, group.len);
        defer scratch.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        const Sorter = struct {
            flat: []const u16,
            paths: []const Range,
            fn lessThan(self: @This(), x: u32, y: u32) bool {
                const a = self.flat[self.paths[x].start..][0..self.paths[x].len];
                const c = self.flat[self.paths[y].start..][0..self.paths[y].len];
                for (a[0..@min(a.len, c.len)], c[0..@min(a.len, c.len)]) |p, q| {
                    if (p != q) return p < q;
                }
                if (a.len != c.len) return a.len < c.len;
                return x < y;
            }
        };
        std.mem.sort(u32, order, Sorter{ .flat = flat.items, .paths = paths }, Sorter.lessThan);

        const sorted = try scratch.alloc(Site, group.len);
        defer scratch.free(sorted);
        for (order, 0..) |old, new| sorted[new] = group[old];
        @memcpy(group, sorted);
    }

    /// Where in `group` the slot numbered `index` sits. Linear, over a list
    /// that is the evidence of ONE instruction; a slot's parent is usually
    /// the slot just before it, so the scan runs backwards.
    fn slotAt(group: []const Site, index: u16) ?usize {
        var i = group.len;
        while (i > 0) {
            i -= 1;
            if (group[i].evidence_index == index) return i;
        }
        return null;
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

test "one instruction's sites come out in pre-order, not in index order" {
    // static-dispatch-spike.md §7.2 and A.68: the cursor numbers slots in
    // ALLOCATION order, which is breadth-first — `pair [ [ 1 ] ] [ [ 2 ] ]`
    // under `pair : a, b -> Bool where a.eq : …, b.eq : …` numbers `a` and
    // `b` together, then their children, then their grandchildren — while
    // `Lower.evidenceArguments` reads the flat list as a pre-order tree.
    // The parent links are what reconcile the two.
    var b: Builder = .{ .gpa = testing.allocator };
    defer b.deinit();

    // 0:a 1:b 2:a's child 3:b's child 4:a's grandchild 5:b's grandchild,
    // appended in that (breadth-first) order, plus one site of a LATER
    // instruction to prove the grouping survives.
    const parents = [_]u16{ Site.no_parent, Site.no_parent, 0, 1, 2, 3 };
    for (parents, 0..) |parent, i| {
        try b.addSite(.{
            .inst = @enumFromInt(9),
            .evidence_index = @intCast(i),
            .parent = parent,
            .target = .{ .evidence = @intCast(i) },
        });
    }
    try b.addSite(.{ .inst = @enumFromInt(4), .evidence_index = 0, .target = .{ .evidence = 99 } });

    const Name = struct {
        fn write(_: *anyopaque, _: Derived, _: *std.ArrayList(u8), _: Allocator) Allocator.Error!void {}
    };
    var ctx: u8 = 0;
    var d = try b.finish(testing.allocator, 0, testing.allocator, Name.write, &ctx);
    defer d.deinit(testing.allocator);

    // Instructions stay contiguous and in order — `Lower.siteRangeOf`
    // binary-searches them — and within the one that nests, the rows are
    // the depth-first walk: a, a's child, a's grandchild, then b's.
    var got: [7]u32 = undefined;
    for (d.sites, 0..) |s, i| got[i] = (@as(u32, s.inst.int()) << 8) | s.evidence_index;
    try testing.expectEqualSlices(u32, &.{
        (4 << 8) | 0,
        (9 << 8) | 0,
        (9 << 8) | 2,
        (9 << 8) | 4,
        (9 << 8) | 1,
        (9 << 8) | 3,
        (9 << 8) | 5,
    }, &got);
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
