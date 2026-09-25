//! P8: the interface record (checker-v2.md §14.1, CK-13).
//!
//! **`scheme` is the only way a solved type enters an interface.** In order:
//! the error scan (`Walk.hasError`, v1's three-valued `hasError` over
//! `owned` successors), `Schemes.Writer.add`, the writer's depth check, a
//! `nesting_too_deep` on failure, and `<error>` instead of a truncated or
//! poisoned scheme. Values, schema members and schema constructors all go
//! through it — v1 wrote schema members and constructors with a bare
//! `writer.add`, so a 600-deep member was published truncated and a
//! dependent's mistake against it compiled clean (CK-13). Constructor terms
//! keep v1's own guard (`addCtor` has no scheme to scan).
//!
//! The rest is v1's `fillInterface`, `fillCtorTerms` and `fillTypeFacts`,
//! moved here (§19: "the rest into `Publish.zig`"), and the
//! `--roundtrip-interfaces` hook, which runs right after the record is
//! complete and before anything reads it (§5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Interface = @import("../resolve/Interface.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const Schemes = @import("../check/Schemes.zig");
const Context = @import("Context.zig");
const Report = @import("Report.zig");
const Walk = @import("Walk.zig");

pub const Var = TypeStore.Var;
pub const Error = Allocator.Error;

pub const Input = struct {
    cx: *const Context,
    report: *Report,
    stacks: *Walk.Stacks,
    iface: *Interface,
    provenance: *const Interface.Provenance,
    decl_scheme: []const Var.Optional,
    roundtrip: bool,
    types: *Types,
};

/// Fill the module's record, round-trip it under the flag, and translate its
/// type references for dependents.
pub fn fill(in: Input) Error!void {
    const cx = in.cx;
    const gpa = cx.gpa;
    const iface = in.iface;
    const prov = in.provenance;
    var writer: Schemes.Writer = .init(gpa, cx.store, cx.interner, cx.types, @intCast(iface.symbols.len));
    defer writer.deinit();
    try writer.seedExtra(iface.extra);
    var p: Publisher = .{ .cx = cx, .stacks = in.stacks, .writer = &writer };

    const values = try gpa.dupe(Interface.Value, iface.values);
    errdefer gpa.free(values);
    for (values, 0..) |*v, i| {
        const decl = prov.valueDecl(i);
        const root = if (decl) |d| (if (d.int() < in.decl_scheme.len) in.decl_scheme[d.int()].unwrap() else null) else null;
        v.scheme = try p.scheme(root, decl);
    }
    gpa.free(@constCast(iface.values));
    iface.values = values;

    const members = try gpa.dupe(Interface.SchemaMember, iface.schema_members);
    errdefer gpa.free(members);
    for (members) |*member| {
        const decl = prov.schemaDecl(@intFromEnum(member.schema));
        const root = if (decl) |d| cx.schemas.member(d.int(), member.kind) else null;
        member.scheme = try p.scheme(root, decl);
    }
    gpa.free(@constCast(iface.schema_members));
    iface.schema_members = members;

    const ctors = try gpa.dupe(Interface.SchemaCtor, iface.schema_ctors);
    errdefer gpa.free(ctors);
    for (ctors, 0..) |*ctor, ci| {
        const si = @intFromEnum(ctor.schema);
        const decl = prov.schemaDecl(si);
        const root = if (decl) |d| blk: {
            const schema = iface.schemas[si];
            const start = if (ctor.endpoint == .type) schema.program_ctors_start else schema.encoded_ctors_start;
            break :blk try cx.schemas.constructor(d, ctor.endpoint, @intCast(ci - start));
        } else null;
        ctor.scheme = try p.scheme(root, decl);
    }
    gpa.free(@constCast(iface.schema_ctors));
    iface.schema_ctors = ctors;

    try ctorTerms(cx, prov, iface, &writer);
    try typeFacts(cx, prov, iface, &writer);
    try writer.attach(iface);

    // `--roundtrip-interfaces` goes HERE (§5): the record is complete and no
    // importer has read it, and the `ref_ids` below must be the loaded
    // record's.
    if (in.roundtrip) try roundtrip(cx, iface, in.report);
    const ref_ids = &in.types.ref_ids[cx.module.int()];
    gpa.free(ref_ids.*);
    ref_ids.* = &.{};
    ref_ids.* = try in.types.resolveRefs(gpa, iface, cx.graph);
}

/// The one routine (§14.1).
const Publisher = struct {
    cx: *const Context,
    stacks: *Walk.Stacks,
    writer: *Schemes.Writer,

    /// `root`'s scheme, or `<error>`: for no type, a poisoned one, or one
    /// too deep to write — the last two reported as `nesting_too_deep` at
    /// `decl` when they are the scanner's or the writer's answer and not the
    /// program's (`fast-compiler.md` §5: a guard that poisons reports).
    fn scheme(p: *Publisher, root: ?Var, decl: ?Bir.DeclIndex) Error!Interface.SchemeIndex {
        const v = root orelse return p.writer.addError();
        switch (try Walk.hasError(p.cx.store, p.stacks, p.cx.gpa, v)) {
            .clean => {},
            .poisoned => return p.writer.addError(),
            .unknown => {
                try p.cx.noteDeepDecl(decl);
                return p.writer.addError();
            },
        }
        const index = try p.writer.add(v);
        if (!p.writer.too_deep) return index;
        // A truncated scheme is an `err` term inside a concrete type: it
        // unifies with anything, and a dependent's mistake compiles clean.
        try p.cx.noteDeepDecl(decl);
        return p.writer.addError();
    }
};

/// Every visible constructor's argument terms (checker.md §7's
/// `arg_terms`), quantified over the owning type's parameters. v1's
/// `fillCtorTerms`, verbatim.
fn ctorTerms(cx: *const Context, prov: *const Interface.Provenance, iface: *Interface, writer: *Schemes.Writer) Error!void {
    if (iface.ctors.len == 0) return;
    const gpa = cx.gpa;
    const scratch = cx.scratch;
    const bir = cx.bir;
    const ctors = try gpa.dupe(Interface.Ctor, iface.ctors);
    errdefer gpa.free(ctors);
    for (ctors, 0..) |*c, i| {
        const bir_index = prov.ctorIndex(i) orelse continue;
        if (bir_index >= bir.ctors.len) continue;
        const bc = bir.ctors[bir_index];
        const owner = bir.decl(bc.decl);
        const params = bir.declTypeParams(owner);
        var b: Types.Builder = .init(cx.store, cx.types, cx.graph, cx.artifacts, cx.module, bir, .flex, TypeStore.generalized, scratch, cx.interner);
        defer b.deinit();
        const param_vars = try scratch.alloc(Var, params.len);
        defer scratch.free(param_vars);
        for (params, param_vars) |param, *v| {
            v.* = try cx.store.fresh(.{ .flex = .{ .name = param.toOptional() } }, TypeStore.generalized);
            try b.bind(param, v.*);
        }
        const args = bir.extraSlice(.{ .start = bc.args_start, .end = bc.args_end }, Bir.Inst.Index);
        const arg_vars = try scratch.alloc(Var, args.len);
        defer scratch.free(arg_vars);
        for (args, arg_vars) |arg, *v| v.* = try b.read(arg);
        if (b.too_deep) {
            try cx.noteDeepDecl(bc.decl);
            continue; // `arg_terms` stays `no_terms`: a use poisons
        }
        const written = try writer.addCtor(param_vars, arg_vars);
        if (writer.too_deep) {
            try cx.noteDeepDecl(bc.decl);
            continue;
        }
        c.arg_terms = written.arg_terms;
        c.quantified_start = written.quantified_start;
    }
    gpa.free(@constCast(iface.ctors));
    iface.ctors = ctors;
}

/// Interface v3's per-type facts (§14.2): `payload_params` as v1 computes
/// it, and the derived rows' status: `alias` for an alias, `own_method` or
/// `foreign` for a `foreign type` (as v1 decides it), and `unchecked` for a
/// `type` — P5, which derives its rows, is R8a's (the manager's decision on
/// R4b's review, S8; nothing reads the rows before R8a).
fn typeFacts(cx: *const Context, prov: *const Interface.Provenance, iface: *Interface, writer: *Schemes.Writer) Error!void {
    if (iface.types.len == 0) return;
    const gpa = cx.gpa;
    const bir = cx.bir;
    const out = try gpa.dupe(Interface.Type, iface.types);
    errdefer gpa.free(out);
    var declares: [2]bool = .{ false, false };
    for (bir.decls) |d| {
        if (!d.kind.isValue() or !d.is_pub) continue;
        if (bir.symbol(d.name) == InternPool.WellKnown.eq.symbol()) declares[0] = true;
        if (bir.symbol(d.name) == InternPool.WellKnown.compare.symbol()) declares[1] = true;
    }
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    for (out, 0..) |*t, i| {
        const decl = prov.typeDecl(i) orelse continue;
        if (cx.types.ofDecl(cx.module, decl) == .none) continue;
        if (t.kind == .alias) {
            t.eq = .{ .status = .alias };
            t.compare = .{ .status = .alias };
            continue;
        }
        try payloadParams(cx, decl, t.kind, t.arity, &words);
        t.payload_params = try writer.addRange(words.items);
        if (t.kind == .foreign) {
            t.eq = .{ .status = if (declares[0]) .own_method else .foreign };
            t.compare = .{ .status = if (declares[1]) .own_method else .foreign };
        }
    }
    gpa.free(@constCast(iface.types));
    iface.types = out;
}

/// v1's `payloadParams`: bit `i` set when parameter `i` occurs in some
/// constructor's payload; every bit for a `foreign type`, for a declaration
/// too deep to read, or for a payload that reads as `err` ("may hold a
/// value" is the safe side). The walk is the store's own, over the builder's
/// fresh variables. Also what the `equatable` marker walk reads for a type of
/// this module, while the module is checked (§11.4, `Instances.zig`).
pub fn payloadParams(cx: *const Context, decl: Bir.DeclIndex, kind: Interface.TypeKind, arity: u16, words: *std.ArrayList(u32)) Error!void {
    const gpa = cx.gpa;
    const scratch = cx.scratch;
    const store = cx.store;
    words.clearRetainingCapacity();
    try words.appendNTimes(gpa, 0, (@as(usize, arity) + 31) / 32);
    const all = struct {
        fn set(w: []u32, count: usize) void {
            for (0..count) |param| w[param / 32] |= @as(u32, 1) << @intCast(param % 32);
        }
    }.set;
    if (kind == .foreign or arity == 0) return all(words.items, arity);
    const owner = cx.bir.decl(decl);
    const params = cx.bir.declTypeParams(owner);
    var b = cx.builder(.flex, TypeStore.generalized);
    defer b.deinit();
    const first: u32 = store.count();
    for (params, 0..) |param, i| {
        const v = try store.fresh(.{ .flex = .{ .name = param.toOptional() } }, TypeStore.generalized);
        if (v.int() != first + i) return all(words.items, arity);
        try b.bind(param, v);
    }
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(scratch);
    for (cx.bir.declCtors(owner)) |c| {
        for (cx.bir.extraSlice(.{ .start = c.args_start, .end = c.args_end }, Bir.Inst.Index)) |arg| {
            try stack.append(scratch, try b.read(arg));
        }
    }
    if (b.too_deep) return all(words.items, arity);
    const seen = store.nextMark();
    while (stack.pop()) |raw| {
        const root = store.find(raw);
        if (store.mark(root) == seen) continue;
        store.setMark(root, seen);
        switch (store.content(root)) {
            .err => return all(words.items, arity),
            .flex, .rigid => if (root.int() >= first and root.int() - first < params.len) {
                const param = root.int() - first;
                words.items[param / 32] |= @as(u32, 1) << @intCast(param % 32);
            },
            .alias, .structure => {
                var n: u32 = 0;
                while (Walk.child(store, root, n, .payload)) |c| : (n += 1) try stack.append(scratch, c);
            },
        }
    }
}

/// `--roundtrip-interfaces` (`fast-compiler.md` §8): replace the record with
/// serialize → bytes → deserialize of itself. v1's, verbatim; a failure is
/// `internal`, never a cache miss.
fn roundtrip(cx: *const Context, iface: *Interface, report: *Report) Error!void {
    const gpa = cx.gpa;
    const bytes = try iface_bytes.write(gpa, iface, cx.interner);
    defer gpa.free(bytes);
    const loaded = iface_bytes.read(gpa, bytes, cx.interner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadRecord => return report.internal(@enumFromInt(0), "this module's interface record did not load back from its own bytes"),
        error.UnknownSymbol => return report.internal(@enumFromInt(0), "this module's interface record names a string the session's interner does not hold"),
    };
    iface.deinit(gpa);
    iface.* = loaded;
}
