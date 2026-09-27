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
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Schemes = @import("Schemes.zig");
const Context = @import("Context.zig");
const Report = @import("Report.zig");
const Walk = @import("Walk.zig");
const Contexts = @import("Contexts.zig");
const Marker = @import("Marker.zig");
const type_body = @import("../cache/type_body.zig");
const Publish = @This();

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
    /// The derived contexts, settled in P5 (§11.2): the rows publish them.
    contexts: *Contexts,
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
    try typeFacts(cx, prov, iface, &writer, in.contexts, in.report);
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

/// Interface v3's per-type facts (§14.2 *as amended by R8a*): each type's
/// `payload_params` and its two derived rows, read off THE derived contexts
/// (`Contexts`, settled in P5) — on the exported types' rows, and on a hidden
/// row for every other nominal type of this module a published term names
/// (CK-89), found by closing over the writer's type references, which the
/// context entries' own schemes can extend.
fn typeFacts(cx: *const Context, prov: *const Interface.Provenance, iface: *Interface, writer: *Schemes.Writer, contexts: *Contexts, report: *Report) Error!void {
    const gpa = cx.gpa;
    var facts: Facts = .{ .cx = cx, .writer = writer, .contexts = contexts, .report = report };
    defer facts.deinit();
    if (iface.types.len != 0) {
        const out = try gpa.dupe(Interface.Type, iface.types);
        errdefer gpa.free(out);
        for (out, 0..) |*t, i| {
            const decl = prov.typeDecl(i) orelse continue;
            const id = cx.types.ofDecl(cx.module, decl);
            if (id == .none) continue;
            if (t.kind == .alias) {
                t.eq = .{ .status = .alias };
                t.compare = .{ .status = .alias };
                continue;
            }
            t.payload_params = try facts.payloadParams(decl, t.kind, t.arity);
            // §11.4's gate, which an importer cannot compute (CK-120).
            if (t.kind == .adt) t.no_function = ((try Marker.functionFree(cx, contexts, null, id)) orelse true);
            t.eq = try facts.derived(id, .eq);
            t.compare = try facts.derived(id, .compare);
        }
        gpa.free(@constCast(iface.types));
        iface.types = out;
    }

    var hidden: std.ArrayList(Interface.HiddenType) = .empty;
    errdefer hidden.deinit(gpa);
    var names: std.ArrayList(InternPool.Symbol) = .empty;
    defer names.deinit(cx.scratch);
    var seen: std.AutoHashMapUnmanaged(Types.TypeId, void) = .empty;
    defer seen.deinit(cx.scratch);
    // Own alias bodies are in no record, so a private type an importer
    // reaches only through a `pub type alias` body is named by no
    // `type_refs` row: the set is closed over them, as `cache/Digest.zig`
    // closes its type set (R8a's review, S2). Seeded with the exported
    // aliases; an alias the writer names adds its body too.
    var through: std.ArrayList(Types.TypeId) = .empty;
    defer through.deinit(cx.scratch);
    for (iface.types, 0..) |t, i| {
        if (t.kind != .alias) continue;
        const decl = prov.typeDecl(i) orelse continue;
        try through.append(cx.scratch, cx.types.ofDecl(cx.module, decl));
    }
    var local: std.ArrayList(Types.TypeId) = .empty;
    defer local.deinit(cx.scratch);
    var at: usize = 0;
    var at_through: usize = 0;
    while (true) {
        // The writer's references first: a hidden row's templates extend them.
        const id = if (at < writer.ref_ids.items.len) blk: {
            at += 1;
            break :blk writer.ref_ids.items[at - 1];
        } else if (at_through < through.items.len) blk: {
            at_through += 1;
            break :blk through.items[at_through - 1];
        } else break;
        if (id == .none) continue;
        const entry = cx.types.entry(id);
        if (entry.module != cx.module) continue;
        if ((try seen.getOrPut(cx.scratch, id)).found_existing) continue;
        if (entry.kind == .alias) {
            const d = cx.bir.decls[entry.decl.int()];
            const body = d.annotation.unwrap() orelse continue;
            local.clearRetainingCapacity();
            try type_body.collectLocal(cx.scratch, &local, .{
                .graph = cx.graph,
                .types = cx.types,
                .interner = cx.interner,
                .module = cx.module,
                .bir = cx.bir,
                .params = cx.bir.declTypeParams(d),
            }, body);
            try through.appendSlice(cx.scratch, local.items);
            continue;
        }
        if (iface.findType(cx.interner, entry.name) != null) continue;
        try hidden.append(gpa, .{
            .name = @enumFromInt(try writer.symbolIndex(entry.name)),
            .arity = entry.arity,
            .kind = entry.kind,
            .is_equatable = entry.equatable and entry.kind == .foreign,
            // §11.4's gate, which an importer cannot compute (CK-120; a
            // tagged schema endpoint's among them, §11.5).
            .no_function = entry.kind == .adt and ((try Marker.functionFree(cx, contexts, null, id)) orelse true),
            .payload_params = try facts.payloadParams(entry.decl, entry.kind, entry.arity),
            .eq = try facts.derived(id, .eq),
            .compare = try facts.derived(id, .compare),
        });
        try names.append(cx.scratch, entry.name);
    }
    // Sorted by name text, as `Interface.typeFacts` searches them.
    const order = try cx.scratch.alloc(u32, hidden.items.len);
    defer cx.scratch.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Sorter = struct {
        names: []const InternPool.Symbol,
        interner: *const InternPool.Global,
        fn lessThan(self: @This(), a: u32, b: u32) bool {
            return std.mem.lessThan(u8, self.interner.slice(self.names[a]), self.interner.slice(self.names[b]));
        }
    };
    std.mem.sort(u32, order, Sorter{ .names = names.items, .interner = cx.interner }, Sorter.lessThan);
    const sorted = try gpa.alloc(Interface.HiddenType, hidden.items.len);
    for (order, sorted) |o, *h| h.* = hidden.items[o];
    hidden.deinit(gpa);
    gpa.free(iface.hidden_types);
    iface.hidden_types = sorted;
}

/// The writes one module's type facts share: the bitset buffer, and one
/// symbol slot per method name.
const Facts = struct {
    cx: *const Context,
    report: *Report,
    writer: *Schemes.Writer,
    contexts: *Contexts,
    words: std.ArrayList(u32) = .empty,
    slots: std.AutoHashMapUnmanaged(InternPool.Symbol, u32) = .empty,

    fn deinit(f: *Facts) void {
        f.words.deinit(f.cx.gpa);
        f.slots.deinit(f.cx.scratch);
    }

    fn payloadParams(f: *Facts, decl: Bir.DeclIndex, kind: Interface.TypeKind, arity: u16) Error!u32 {
        try Publish.payloadParams(f.cx, decl, kind, arity, &f.words);
        return f.writer.addRange(f.words.items);
    }

    fn slot(f: *Facts, method: InternPool.Symbol) Error!u32 {
        const got = try f.slots.getOrPut(f.cx.scratch, method);
        if (!got.found_existing) got.value_ptr.* = try f.writer.symbolIndex(method);
        return got.value_ptr.*;
    }

    /// Type `id`'s derived `kind`, as §14.2 publishes it: `primitive` for
    /// §3.2's table, `own_method`, `foreign`, else the context's answer —
    /// `present` with its entries, each of another method than `eq` or
    /// `compare` with its method type as a scheme over the type's
    /// parameters, or `function` / `unanswerable` — or `private_method`
    /// (D1, §14.2 *as amended by R8b*) with its culprit: this type itself
    /// when the module's own value of the name is private, or the type a
    /// payload's context reached.
    fn derived(f: *Facts, id: Types.TypeId, kind: Contexts.Kind) Error!Interface.Derived {
        const types = f.cx.types;
        if (Contexts.tableRow(types, id, kind) == .primitive) return .{ .status = .primitive };
        if (f.contexts.moduleRuleAnswers(id, kind)) {
            if (f.contexts.module_pub[@intFromEnum(kind)]) return .{ .status = .own_method };
            return f.private(id, Contexts.methodName(kind));
        }
        if (types.entry(id).kind == .foreign) return .{ .status = .foreign };
        const t = f.contexts.local(id) orelse return .{ .status = .unanswerable };
        const answer = f.contexts.final(t, kind);
        switch (answer.status) {
            .present => {},
            .own_method => return .{ .status = .own_method },
            .foreign => return .{ .status = .foreign },
            .absent_function => return .{ .status = .function },
            .absent_private => return f.private(@enumFromInt(answer.culprit), answer.method),
            // The record has no status for a needed annotation, so an
            // importer says "does not support" where the module itself gives
            // the annotation hint (R8a's review, nit): the texts are R13's.
            .absent_other, .needs_annotation => return .{ .status = .unanswerable },
            // P5 ran it with a budget of its own: one that still ran out is
            // the compiler's failure, not a fact about the type (R8b's
            // round-2 review, S1).
            .absent_budget => {
                try f.report.internal(f.cx.bir.decls[f.cx.types.entry(id).decl.int()].inst_start, "a derived context ran out of the step budget in P5 (checker-v2.md §11.2)");
                return .{ .status = .unanswerable };
            },
        }
        const entries = f.contexts.entriesOf(answer);
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(f.cx.scratch);
        try words.ensureTotalCapacity(f.cx.scratch, 1 + entries.len * Interface.context_words);
        // The row's one scheme first: its method types, or `none`.
        words.appendAssumeCapacity(if (answer.template.unwrap()) |template|
            @intFromEnum(try f.templateScheme(t, template))
        else
            std.math.maxInt(u32));
        for (entries) |e| {
            words.appendAssumeCapacity(e.param);
            words.appendAssumeCapacity(try f.slot(e.method));
            words.appendAssumeCapacity(e.slot);
        }
        return .{ .status = .present, .context = try f.writer.addRange(words.items) };
    }

    /// A `private_method` row: `(type_ref, method)`, the type whose module
    /// declares the private method named through this record's own
    /// `type_refs` (a first mention appends a row, as any term's does).
    fn private(f: *Facts, culprit: Types.TypeId, method: InternPool.Symbol) Error!Interface.Derived {
        const ref = try f.writer.typeRefOf(culprit);
        if (ref == .none) return .{ .status = .unanswerable };
        const words = [_]u32{ @intFromEnum(ref), try f.slot(method) };
        return .{ .status = .private_method, .context = try f.writer.addRange(&words) };
    }

    /// A row's method types as ONE scheme whose body is `( p₀, …, pₙ₋₁,
    /// ( τ₀, …, τₖ ) )` (§14.2 *as amended by R8a*): the parameters first, so
    /// `Schemes.Writer` numbers them `0 … n − 1`, then the answer's template
    /// tuple, whose element `slot` an entry names.
    fn templateScheme(f: *Facts, t: u32, template: Var) Error!Interface.SchemeIndex {
        const store = f.cx.store;
        const params = try f.contexts.paramsOf(t);
        const elements = try f.cx.scratch.alloc(Var, params.len + 1);
        defer f.cx.scratch.free(elements);
        @memcpy(elements[0..params.len], params);
        elements[params.len] = template;
        const range = try store.addVars(elements);
        const tuple = try store.fresh(.{ .structure = .{ .tuple = range } }, TypeStore.generalized);
        const index = try f.writer.add(tuple);
        if (f.writer.too_deep) return f.writer.addError();
        return index;
    }
};

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
    const owner = cx.bir.decl(decl);
    // A schema endpoint's payloads are its plan's, not constructors: every
    // parameter counts (§11.4's safe side; R8b).
    if (kind == .foreign or arity == 0 or owner.kind == .schema) return all(words.items, arity);
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
