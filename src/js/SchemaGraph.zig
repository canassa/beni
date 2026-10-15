//! The resolved schema plans of a whole build, read by the backend
//! (`docs/design/schema.md` §6, *The specialised path, as specified for
//! S4*): which declaration a plan reference names, what a definition's
//! nodes are, which of its parameters its value reaches, and which schemas
//! of a module refer to each other in a cycle. `Reach` reads it to build the
//! three member nodes' edges and `SchemaLower` to write what they emit, so
//! the two cannot disagree about what a member names.
//!
//! Every answer is a function of the plans, the module graph and the
//! interfaces, all input-derived (CLAUDE.md rule 5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const SchemaPlan = @import("../check/SchemaPlan.zig");
const SchemaShare = @import("SchemaShare.zig");
const Dispatch = @import("../check/Dispatch.zig");

const SchemaGraph = @This();

graph: *const Graph,
/// One per module, by `Graph.Index`.
plans: []const SchemaPlan,
birs: []const *const Bir,
interfaces: []const Interface,
provenance: []const Interface.Provenance,
interner: *const InternPool.Global,
/// The validators this build shares across its schemas (`SchemaShare`),
/// decided once reachability has run and read by every module's lowering.
share: SchemaShare.Share = .{},

/// The nodes one declaration emits besides its `via`s, and their order in
/// a module's member table (`Reach`'s `schema` kind is
/// `decl * members + member`):
/// - `description`, `$$description`;
/// - one worker set per operation a compiled schema runs (`schema.md` §6,
///   *Every runner of a statically known schema is compiled*): `read` and
///   `write`, the `parse` and `print` workers (`$$read`, `$$write`, named
///   before the other four existed), and `decode`, `encode`, `read_value`
///   and `write_value`, the workers of `Schema.decode`, `encode`, `read`
///   and `write`;
/// - `root`, `S.schema`'s value, a compiled schema. It reaches the
///   description and each worker set only through guards: the description
///   on `core/Schema`'s `nodeOf`, a worker set on a `core/Schema` value that
///   runs a compiled schema's worker of that operation (`root_guards`);
/// - `parse` and `print`, the root wrappers `S.parse`/`S.parseWith` and
///   `S.print`/`S.printWith`, which only those members reach, so a build
///   that runs `S.schema` alone ships none of them.
pub const Member = enum(u4) {
    description = 0,
    read = 1,
    write = 2,
    root = 3,
    parse = 4,
    print = 5,
    decode = 6,
    encode = 7,
    read_value = 8,
    write_value = 9,
    /// `read`'s validator workers (`schema.md` §6, *A run whose failure is
    /// never read is a validator*).
    read_valid = 10,
    /// The definition's shape, which a shape run hands the shared
    /// validator (`schema.md` §6, *A validator run is a shape that one
    /// shared validator reads*): only shape runs and other shapes reach it.
    shape = 11,

    pub const count = 12;

    /// The members a `pub schema` exports from a `--library` build: what
    /// another program can name. The other four worker sets are reached
    /// only through a root's guards.
    pub const exported = [_]Member{ .description, .read, .write, .root, .parse, .print };

    /// The worker set of operation `op`.
    pub fn worker(o: Op) Member {
        return switch (o) {
            .parse => .read,
            .print => .write,
            .decode => .decode,
            .encode => .encode,
            .read => .read_value,
            .write => .write_value,
            .valid => .read_valid,
        };
    }

    /// The operation whose worker set this member is, if it is one.
    pub fn op(m: Member) ?Op {
        return switch (m) {
            .read => .parse,
            .write => .print,
            .decode => .decode,
            .encode => .encode,
            .read_value => .read,
            .write_value => .write,
            .read_valid => .valid,
            .description, .root, .parse, .print, .shape => null,
        };
    }
};

/// An operation a compiled schema runs (`core/Schema`'s `parseMode` …
/// `writeMode`; `declared` takes the last four in this order). Its ends:
/// whether it decodes (Encoded to Type), whether its input and its output
/// are host values, and whether the host value is JSON's (`parse` reads
/// what `JSON.parse` made, `print` writes what `JSON.stringify` takes).
pub const Op = enum(u3) {
    parse = 0,
    print = 1,
    decode = 2,
    encode = 3,
    read = 4,
    write = 5,
    /// `read` as a validator: `read`'s ends, no issue made.
    valid = 6,

    pub fn decoding(o: Op) bool {
        return switch (o) {
            .parse, .decode, .read, .valid => true,
            .print, .encode, .write => false,
        };
    }

    pub fn hostIn(o: Op) bool {
        return o == .parse or o == .read or o == .valid;
    }

    pub fn hostOut(o: Op) bool {
        return o == .print or o == .write;
    }

    pub fn json(o: Op) bool {
        return o == .parse or o == .print;
    }

    /// The core-private value that makes a schema argument this
    /// operation's slot.
    pub fn slot(o: Op) []const u8 {
        return switch (o) {
            .parse => "readSlot",
            .print => "writeSlot",
            .decode => "decodeSlot",
            .encode => "encodeSlot",
            .read => "readValueSlot",
            .write => "writeValueSlot",
            .valid => "readValidSlot",
        };
    }

    /// The suffix of its workers' names: `$$read`, `$$read$7`.
    pub fn workerSuffix(o: Op) []const u8 {
        return switch (o) {
            .parse => "read",
            .print => "write",
            .decode => "decode",
            .encode => "encode",
            .read => "readValue",
            .write => "writeValue",
            .valid => "readValid",
        };
    }
};

/// The `core/Schema` declarations whose survival lets a root reach each of
/// the other members, any one of them enough: `nodeOf`, the one reader of
/// a compiled schema's description; for each operation, its runner
/// (`parseWith` …) and its slot maker (`readSlot` …), which run a compiled
/// schema's worker of that operation. Every other value that touches a
/// worker — `list`, `nullable`, `converted` — only passes it on to one of
/// these.
pub const root_guards = [_]struct { Member, []const u8 }{
    .{ .description, "nodeOf" },
    .{ .read, "parseWith" },
    .{ .read, "readSlot" },
    .{ .write, "printWith" },
    .{ .write, "writeSlot" },
    .{ .decode, "decodeWith" },
    .{ .decode, "decodeSlot" },
    .{ .encode, "encodeWith" },
    .{ .encode, "encodeSlot" },
    .{ .read_value, "readWith" },
    .{ .read_value, "readValueSlot" },
    .{ .write_value, "writeWith" },
    .{ .write_value, "writeValueSlot" },
    .{ .read_valid, "readValid" },
    .{ .read_valid, "readValidSlot" },
};

/// A schema declaration of some module.
pub const Ref = struct { module: Graph.Index, decl: u32 };

/// `core/Schema`'s core-private values the specialised path calls: in no
/// interface, exported by `core/Schema` when they survive.
pub const compiled_values = [_][]const u8{
    "compiledParse",   "compiledPrint",       "compiledFail",    "compiledForward",   "compiledBackward",
    "belowBackward",   "readSlot",            "writeSlot",       "pathAt",            "printableWithin",
    "declared",        "decodeSlot",          "encodeSlot",      "readValueSlot",     "writeValueSlot",
    "box",             "describedOf",         "describedList",   "describedNullable", "describedConverted",
    "describedRecord", "describedField",      "describedTagged", "describedVariant",  "describedRecursive",
    "compiledDeep",    "compiledMissing",     "badString",       "badInt",            "badBool",
    "badFloat",        "badFinite",
    // A derived codec's (schema.md §12.10).
              "describedHost",   "describedTuple",    "describedConstructors",
    "describedMaybe",  "describedMaybeField", "derivedChar",     "derivedInt32",      "derivedNever",
    "hostWorker",
    // `read` as a validator (schema.md §6).
         "readValid",           "readValidSlot",   "validContext",      "validJson",
    // A shape run's validator and the readers a shape names (schema.md §6,
    // *A validator run is a shape that one shared validator reads*).
    "validShape",      "shapeParse",          "shapeString",     "shapeBool",         "shapeInt",
    "shapeFloat",      "shapeFinite",         "shapeNull",       "shapeValue",        "shapeChar",
    "oneScalar",       "shapeInt32",          "shapeNever",      "shapeRecord",       "shapeList",
    "shapeNullable",   "shapeMaybe",          "shapeJust",       "shapeLater",        "shapeTuple",
    "shapeTagged",     "shapeCtors",          "shapeRecordOwn",  "shapeTaggedOwn",
};

pub fn isCompiledValue(text: []const u8) bool {
    for (compiled_values) |v| if (std.mem.eql(u8, v, text)) return true;
    return false;
}

/// The `core/Schema` values member `member` of `r` calls, by name: the
/// builders its description uses, the helpers its worker calls, or —
/// under `--schema-library` — the library runner and the options.
/// `SchemaLower` writes calls of exactly these, and `Reach` keeps them.
pub fn coreNeeds(g: SchemaGraph, scratch: Allocator, r: Ref, member: Member, library: bool, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    const d = g.definition(r.module, r.decl) orelse return;
    const plan = g.planOf(r.module);
    var nodes: std.ArrayList(SchemaPlan.NodeIndex) = .empty;
    try subtree(plan, scratch, d.root, &nodes);
    const params = d.params_end - d.params_start;
    switch (member) {
        // Under `--schema-library` the root is its description, boxed.
        .root => try out.append(scratch, if (library) "box" else "declared"),
        .description => {
            // `describedOf` makes a primitive's node, and a generic root's
            // description of each argument's node.
            try out.append(scratch, "describedOf");
            if (try g.recursive(scratch, r.module, r.decl)) try out.append(scratch, "describedRecursive");
            // A derived codec's Encoded end is a host value (schema.md
            // §12.10).
            if (g.codecIndex(r.module, r.decl) != null) try out.append(scratch, "describedHost");
            for (nodes.items) |n| switch (tag(plan, n)) {
                .primitive => try out.append(scratch, primitiveBuilder(lhs(plan, n))),
                .list => try out.append(scratch, "describedList"),
                .nullable => try out.append(scratch, "describedNullable"),
                .conversion => try out.append(scratch, "describedConverted"),
                .record => {
                    try out.append(scratch, "describedRecord");
                    for (fields(plan, n)) |f| try out.append(scratch, if (isMaybeField(plan, f)) "describedMaybeField" else "describedField");
                },
                .tagged => try out.appendSlice(scratch, &.{ "describedTagged", "describedVariant" }),
                // A derived codec's (schema.md §12.10).
                .tuple => try out.append(scratch, "describedTuple"),
                .constructors => try out.append(scratch, "describedConstructors"),
                .maybe => if (rhs(plan, n) & SchemaPlan.Maybe.field == 0) try out.append(scratch, "describedMaybe"),
                .parameter, .reference, .check, .annotation, .codec_ref, .codec_value => {},
            };
        },
        // The readers the shape names, one per kind of node it holds.
        .shape => {
            if (library) return;
            for (nodes.items) |n| if (shapeReader(plan, n)) |name| try out.append(scratch, name);
            var refs: std.ArrayList(SchemaPlan.NodeIndex) = .empty;
            for (nodes.items) |n| switch (tag(plan, n)) {
                .reference, .codec_ref => try refs.append(scratch, n),
                else => {},
            };
            for (refs.items) |n| {
                const t = switch (tag(plan, n)) {
                    .reference => g.target(r.module, @fromBackingInt(@intCast(lhs(plan, n)))) orelse continue,
                    else => g.codecTarget(r.module, lhs(plan, n)),
                };
                if (try g.inCycle(scratch, r, t)) {
                    try out.append(scratch, "shapeLater");
                    break;
                }
            }
        },
        // The root wrappers: `S.parse`/`S.parseWith`, `S.print`/`S.printWith`.
        .parse, .print => {
            try out.append(scratch, "defaultOptions");
            if (library) {
                try out.append(scratch, if (member == .parse) "parseWith" else "printWith");
                return;
            }
            try out.append(scratch, if (member == .parse) "compiledParse" else "compiledPrint");
            if (params != 0) try out.append(scratch, if (member == .parse) "readSlot" else "writeSlot");
        },
        .read, .write, .decode, .encode, .read_value, .write_value, .read_valid => {
            // Under `--schema-library` no worker is written.
            if (library) return;
            // A derived codec's `decode` and `encode` are its `read` and
            // `write` workers on a context whose Encoded end is a host value
            // (`hostWorker`, schema.md §12.10): no worker set of their own.
            if (g.hostAliased(r, member)) |_| {
                try out.append(scratch, "hostWorker");
                return;
            }
            const op = member.op().?;
            try out.append(scratch, "pathAt");
            // `compiledFail`, for any failure branch: the depth bound and a
            // missing key call it too where the build does not share their
            // helpers (`SchemaShare`), which are roots of their own when it
            // does.
            const failures = failureHelpers(plan, nodes.items, op);
            // A validator's failure branches make no issue.
            if (op != .valid and (failures.deep or failures.missing or failures.generic)) try out.append(scratch, "compiledFail");
            // A generic declaration's root closes this operation's worker
            // over its arguments' slots, once this worker set survives.
            if (params != 0) try out.append(scratch, op.slot());
            for (nodes.items) |n| switch (tag(plan, n)) {
                .conversion => if (op.decoding()) {
                    try out.append(scratch, "compiledForward");
                } else {
                    try out.appendSlice(scratch, &.{ "compiledBackward", "belowBackward" });
                },
                .primitive => {
                    if (op == .print and lhs(plan, n) == @backingInt(SchemaPlan.Primitive.value)) try out.append(scratch, "printableWithin");
                    // Generated readers call `oneScalar`. That call is not in
                    // this module, so reachability keeps the value only when
                    // it is named here.
                    if (op.hostIn() and lhs(plan, n) == @backingInt(SchemaPlan.Primitive.char)) try out.append(scratch, "oneScalar");
                },
                // A module's `codec` runs through its own workers.
                .codec_value => try out.append(scratch, op.slot()),
                else => {},
            };
        },
    }
}

/// A derived codec's `decode` or `encode` member: the `read` or `write`
/// worker set it runs instead, since a derived codec's Encoded end is a
/// host value (schema.md §12.10, `NHost`). Null for any other member.
pub fn hostAliased(g: SchemaGraph, r: Ref, member: Member) ?Member {
    if (g.codecIndex(r.module, r.decl) == null) return null;
    return switch (member) {
        .decode => .read_value,
        .encode => .write_value,
        else => null,
    };
}

/// The failure helpers a worker of operation `op` over `nodes` calls
/// (`SchemaLower`'s `failText`): `compiledDeep` for the depth bound before
/// every descent, `compiledMissing` for a missing key, and `compiledFail`
/// for the rest — a shape or number test, an unknown key or tag, and what
/// `print` refuses to write.
pub const FailureHelpers = struct { deep: bool = false, missing: bool = false, generic: bool = false };

pub fn failureHelpers(plan: *const SchemaPlan, nodes: []const SchemaPlan.NodeIndex, op: Op) FailureHelpers {
    var f: FailureHelpers = .{};
    for (nodes) |n| switch (tag(plan, n)) {
        .record, .tagged => {
            f.deep = true;
            if (op.hostIn()) {
                f.missing = true;
                f.generic = true;
            }
        },
        .list => {
            f.deep = true;
            f.generic = f.generic or op.hostIn();
        },
        .primitive => switch (std.enums.fromInt(SchemaPlan.Primitive, lhs(plan, n)) orelse .value) {
            .int, .finite_float, .never => f.generic = true,
            .string, .bool, .null, .float, .char, .int32 => f.generic = f.generic or op.hostIn() or (op == .print and lhs(plan, n) == @backingInt(SchemaPlan.Primitive.float)),
            .value => f.generic = f.generic or op == .print,
        },
        // A derived codec's (schema.md §12.10): an array or a constructor
        // read from a host value is tested for its shape, and a `Maybe`
        // whose inner value writes `null` is refused.
        .tuple, .constructors => {
            f.deep = true;
            f.generic = f.generic or op.hostIn();
        },
        .maybe => f.generic = f.generic or (!op.decoding() and rhs(plan, n) & SchemaPlan.Maybe.refuse_null != 0),
        else => {},
    };
    return f;
}

/// A call of core's `Json.decode`, `encode`, `decodeWith` or `encodeWith`
/// whose one evidence argument is a derived codec of this module
/// (`schema.md` §12.10): written as the codec's own `parse`, `print`,
/// `parseWith` or `printWith`, so a derived schema ships what a
/// declaration's `S.parse` ships. `Lower` writes it and `Reach` keeps what
/// it names; both ask here.
pub const JsonCall = struct {
    /// The codec's index in its module's plan, and the evidence term.
    codec: u32,
    term: Dispatch.TermIndex,
    /// The root wrapper: `parse` or `print`.
    member: Member,
    /// The binding: `parse`, `print`, `parseWith` or `printWith`.
    suffix: []const u8,
};

pub fn jsonCall(graph: *const Graph, interfaces: []const Interface, bir: *const Bir, dispatch: *const Dispatch, interner: *const InternPool.Global, call: Bir.Inst.Index) ?JsonCall {
    if (call.int() >= bir.insts.len or bir.instTag(call) != .call) return null;
    const callee: Bir.Inst.Index = @fromBackingInt(@intCast(bir.instData(call).lhs));
    if (callee.int() >= bir.insts.len or bir.instTag(callee) != .ext_value) return null;
    const d = bir.instData(callee);
    const module: Graph.Index = @fromBackingInt(@intCast(d.lhs));
    if (module.int() >= interfaces.len) return null;
    if (graph.modulePackage(module) != .core or graph.moduleName(module) != InternPool.WellKnown.Json.symbol()) return null;
    const iface = &interfaces[module.int()];
    if (d.rhs >= iface.values.len) return null;
    const name = interner.slice(iface.symbol(iface.values[d.rhs].name));
    const member: Member, const suffix: []const u8 = if (std.mem.eql(u8, name, "decode"))
        .{ .parse, "parse" }
    else if (std.mem.eql(u8, name, "decodeWith"))
        .{ .parse, "parseWith" }
    else if (std.mem.eql(u8, name, "encode"))
        .{ .print, "print" }
    else if (std.mem.eql(u8, name, "encodeWith"))
        .{ .print, "printWith" }
    else
        return null;
    const site = dispatch.siteOf(call) orelse return null;
    const roots = dispatch.argsAt(site.evidence);
    if (roots.len != 1) return null;
    return switch (dispatch.term(roots[0])) {
        .codec => |use| .{ .codec = use.index, .term = roots[0], .member = member, .suffix = suffix },
        else => null,
    };
}

/// The `core/Schema` value a primitive node's description is.
pub fn primitiveBuilder(kind: u32) []const u8 {
    return switch (std.enums.fromInt(SchemaPlan.Primitive, kind) orelse .value) {
        .string => "string",
        .bool => "bool",
        .int => "int",
        .float => "float",
        .finite_float => "finiteFloat",
        .null => "null",
        .value => "value",
        .char => "derivedChar",
        .int32 => "derivedInt32",
        .never => "derivedNever",
    };
}

/// Whether record field `f` is a derived record's `Maybe` field
/// (schema.md §12.4): optional, its child a `maybe` node in field form.
pub fn isMaybeField(plan: *const SchemaPlan, f: SchemaPlan.Field) bool {
    if (!f.optional or @backingInt(f.child) >= plan.nodes.len) return false;
    return tag(plan, f.child) == .maybe and rhs(plan, f.child) & SchemaPlan.Maybe.field != 0;
}

/// The schema members member `member` of `r` reaches directly: a root
/// wrapper its own worker set, and a worker set or the description the same
/// member of every definition its value references. Under
/// `--schema-library` a root wrapper reaches the root, the boxed description, and a
/// worker set nothing, since none is written.
pub fn memberTargets(g: SchemaGraph, scratch: Allocator, r: Ref, member: Member, library: bool, out: *std.ArrayList(struct { Ref, Member })) Allocator.Error!void {
    switch (member) {
        .root => return,
        .parse, .print => {
            try out.append(scratch, .{ r, if (library) .root else if (member == .parse) .read else .write });
            return;
        },
        .description => {},
        .read, .write, .decode, .encode, .read_value, .write_value, .read_valid, .shape => if (library) return,
    }
    if (g.hostAliased(r, member)) |aliased| {
        try out.append(scratch, .{ r, aliased });
        return;
    }
    const d = g.definition(r.module, r.decl) orelse return;
    const plan = g.planOf(r.module);
    var nodes: std.ArrayList(SchemaPlan.NodeIndex) = .empty;
    try subtree(plan, scratch, d.root, &nodes);
    for (nodes.items) |n| {
        const t = switch (tag(plan, n)) {
            .reference => g.target(r.module, @fromBackingInt(@intCast(lhs(plan, n)))) orelse continue,
            .codec_ref => g.codecTarget(r.module, lhs(plan, n)),
            else => continue,
        };
        try out.append(scratch, .{ t, member });
    }
}

/// Whether definition `r` has a shape (`schema.md` §6, *A validator run is
/// a shape that one shared validator reads*): it takes no parameter, and
/// every node it reaches, through references, is one a shape can hold —
/// no `via`, no parameter, no module `codec`, and no reference with
/// arguments or to a generic definition.
pub fn shapeable(g: SchemaGraph, scratch: Allocator, r: Ref) Allocator.Error!bool {
    var stack: std.ArrayList(Ref) = .empty;
    var seen: std.ArrayList(Ref) = .empty;
    try stack.append(scratch, r);
    while (stack.pop()) |at| {
        var done = false;
        for (seen.items) |x| done = done or (x.module == at.module and x.decl == at.decl);
        if (done) continue;
        try seen.append(scratch, at);
        const d = g.definition(at.module, at.decl) orelse return false;
        if (d.params_end != d.params_start) return false;
        const plan = g.planOf(at.module);
        var nodes: std.ArrayList(SchemaPlan.NodeIndex) = .empty;
        try subtree(plan, scratch, d.root, &nodes);
        for (nodes.items) |n| switch (tag(plan, n)) {
            .primitive, .list, .nullable, .record, .tagged, .tuple, .constructors, .maybe, .check, .annotation => {},
            .reference => {
                if (args(plan, n).len != 0) return false;
                try stack.append(scratch, g.target(at.module, @fromBackingInt(@intCast(lhs(plan, n)))) orelse return false);
            },
            .codec_ref => {
                if (args(plan, n).len != 0) return false;
                try stack.append(scratch, g.codecTarget(at.module, lhs(plan, n)));
            },
            .conversion, .parameter, .codec_value => return false,
        };
    }
    return true;
}

/// The `core/Schema` reader a node's shape names first, or null for a
/// reference, a check or an annotation, which name none. A record with a
/// key, or a union with a discriminator, that is a name `Object.prototype`
/// holds takes the reader that tests it as an own key, decided here from
/// the key's text as the workers decide it (`SchemaShare.isPrototypeKey`).
pub fn shapeReader(plan: *const SchemaPlan, n: SchemaPlan.NodeIndex) ?[]const u8 {
    return switch (tag(plan, n)) {
        .primitive => switch (std.enums.fromInt(SchemaPlan.Primitive, lhs(plan, n)) orelse .value) {
            .string => "shapeString",
            .bool => "shapeBool",
            .int => "shapeInt",
            .float => "shapeFloat",
            .finite_float => "shapeFinite",
            .null => "shapeNull",
            .value => "shapeValue",
            .char => "shapeChar",
            .int32 => "shapeInt32",
            .never => "shapeNever",
        },
        .list => "shapeList",
        .nullable => "shapeNullable",
        .maybe => if (rhs(plan, n) & SchemaPlan.Maybe.reads_null != 0) "shapeJust" else "shapeMaybe",
        .tuple => "shapeTuple",
        .tagged => if (SchemaShare.isPrototypeKey(literal(plan, @fromBackingInt(@intCast(lhs(plan, n)))))) "shapeTaggedOwn" else "shapeTagged",
        .record => for (fields(plan, n)) |f| {
            if (SchemaShare.isPrototypeKey(literal(plan, f.external))) break "shapeRecordOwn";
        } else "shapeRecord",
        .constructors => "shapeCtors",
        .reference, .codec_ref, .check, .annotation, .conversion, .parameter, .codec_value => null,
    };
}

/// Whether definition `t`, which `r` references, references `r` back,
/// directly or through others: the two are then in one reference cycle,
/// which cannot cross a module.
pub fn inCycle(g: SchemaGraph, scratch: Allocator, r: Ref, t: Ref) Allocator.Error!bool {
    if (t.module != r.module) return false;
    const m = r.module;
    const plan = g.planOf(m);
    var stack: std.ArrayList(u32) = .empty;
    var visited: std.ArrayList(u32) = .empty;
    try stack.append(scratch, t.decl);
    while (stack.pop()) |at| {
        if (at == r.decl) return true;
        var done = false;
        for (visited.items) |v| done = done or v == at;
        if (done) continue;
        try visited.append(scratch, at);
        const d = g.definition(m, at) orelse continue;
        var nodes: std.ArrayList(SchemaPlan.NodeIndex) = .empty;
        try subtree(plan, scratch, d.root, &nodes);
        for (nodes.items) |n| {
            const next = switch (tag(plan, n)) {
                .reference => g.target(m, @fromBackingInt(@intCast(lhs(plan, n)))) orelse continue,
                .codec_ref => g.codecTarget(m, lhs(plan, n)),
                else => continue,
            };
            if (next.module == m) try stack.append(scratch, next.decl);
        }
    }
    return false;
}

/// Whether the definition holds a `via`: its members then reach the
/// declaration's own node, which emits the `via`s.
pub fn hasVia(g: SchemaGraph, scratch: Allocator, r: Ref) Allocator.Error!bool {
    const d = g.definition(r.module, r.decl) orelse return false;
    const plan = g.planOf(r.module);
    var nodes: std.ArrayList(SchemaPlan.NodeIndex) = .empty;
    try subtree(plan, scratch, d.root, &nodes);
    for (nodes.items) |n| if (tag(plan, n) == .conversion) return true;
    return false;
}

pub fn planOf(g: SchemaGraph, m: Graph.Index) *const SchemaPlan {
    if (m.int() >= g.plans.len) return &SchemaPlan.empty;
    return &g.plans[m.int()];
}

pub fn birOf(g: SchemaGraph, m: Graph.Index) *const Bir {
    if (m.int() >= g.birs.len) return &Bir.empty;
    return g.birs[m.int()];
}

/// The plan's definition of declaration `decl` of module `m`: a `schema`
/// declaration's, or a derived codec's, whose `decl` is a virtual index
/// after the module's last declaration (`SchemaPlan.codecs`).
pub fn definition(g: SchemaGraph, m: Graph.Index, decl: u32) ?*const SchemaPlan.Definition {
    const plan = g.planOf(m);
    const decls = g.birOf(m).decls.len;
    if (decl >= decls) {
        const k = decl - decls;
        if (k < plan.codecs.len and @backingInt(plan.codecs[k].decl) == decl) return &plan.codecs[k];
        return null;
    }
    for (plan.definitions) |*d| {
        if (@backingInt(d.decl) == decl) return d;
    }
    return null;
}

/// Whether `decl` of `m` is a derived codec's virtual declaration
/// (schema.md §12.10): its index among the module's codecs.
pub fn codecIndex(g: SchemaGraph, m: Graph.Index, decl: u32) ?u32 {
    const decls = g.birOf(m).decls.len;
    if (decl < decls) return null;
    return decl - @as(u32, @intCast(decls));
}

/// The derived codec a `codec_ref` node of `m`'s plan names.
pub fn codecTarget(g: SchemaGraph, m: Graph.Index, k: u32) Ref {
    return .{ .module = m, .decl = @intCast(g.birOf(m).decls.len + k) };
}

/// How many schema parameters declaration `decl` of `m` takes.
pub fn paramCount(g: SchemaGraph, r: Ref) u32 {
    const d = g.definition(r.module, r.decl) orelse return 0;
    return d.params_end - d.params_start;
}

pub fn symbol(plan: *const SchemaPlan, index: SchemaPlan.SymbolIndex) InternPool.Symbol {
    return plan.symbols[@backingInt(index)];
}

/// The declaration a reference node of `m`'s plan names.
pub fn target(g: SchemaGraph, m: Graph.Index, index: SchemaPlan.SchemaTargetIndex) ?Ref {
    const plan = g.planOf(m);
    const i = @backingInt(index);
    if (i >= plan.schema_targets.len) return null;
    const t = plan.schema_targets[i];
    const module_name = symbol(plan, t.module);
    const schema_name = symbol(plan, t.schema);
    const owner = if (g.graph.moduleName(m) == module_name and g.graph.modulePackage(m) == t.package)
        m
    else
        g.graph.lookup(t.package, module_name) orelse return null;
    if (owner == m) {
        const bir = g.birOf(m);
        for (bir.decls, 0..) |d, di| {
            if (d.kind == .schema and bir.symbol(d.name) == schema_name) return .{ .module = m, .decl = @intCast(di) };
        }
        return null;
    }
    if (owner.int() >= g.interfaces.len or owner.int() >= g.provenance.len) return null;
    const schema = g.interfaces[owner.int()].findSchema(g.interner, schema_name) orelse return null;
    const decl = g.provenance[owner.int()].schemaDecl(@backingInt(schema)) orelse return null;
    return .{ .module = owner, .decl = decl.int() };
}

pub fn tag(plan: *const SchemaPlan, n: SchemaPlan.NodeIndex) SchemaPlan.Node.Tag {
    return plan.nodes.items(.tag)[@backingInt(n)];
}

pub fn lhs(plan: *const SchemaPlan, n: SchemaPlan.NodeIndex) u32 {
    return plan.nodes.items(.lhs)[@backingInt(n)];
}

pub fn rhs(plan: *const SchemaPlan, n: SchemaPlan.NodeIndex) u32 {
    return plan.nodes.items(.rhs)[@backingInt(n)];
}

/// The words of an `extra` range: a length, then the words.
pub fn range(plan: *const SchemaPlan, at: u32) []const u32 {
    if (at >= plan.extra.len) return &.{};
    const n = plan.extra[at];
    if (at + 1 + n > plan.extra.len) return &.{};
    return plan.extra[at + 1 ..][0..n];
}

/// A reference node's argument nodes.
pub fn args(plan: *const SchemaPlan, n: SchemaPlan.NodeIndex) []const u32 {
    return range(plan, rhs(plan, n));
}

/// A tagged node's variant indices.
pub fn variants(plan: *const SchemaPlan, n: SchemaPlan.NodeIndex) []const u32 {
    return range(plan, rhs(plan, n));
}

/// A `tuple` node's elements.
pub fn elements(plan: *const SchemaPlan, n: SchemaPlan.NodeIndex) []const u32 {
    return range(plan, lhs(plan, n));
}

/// A `constructors` node's `codec_ctors` indices, in declaration order.
pub fn ctors(plan: *const SchemaPlan, n: SchemaPlan.NodeIndex) []const u32 {
    return range(plan, rhs(plan, n));
}

/// A constructor's argument nodes.
pub fn ctorArgs(plan: *const SchemaPlan, c: u32) []const u32 {
    if (c >= plan.codec_ctors.len) return &.{};
    return range(plan, plan.codec_ctors[c].args);
}

/// A record node's fields.
pub fn fields(plan: *const SchemaPlan, n: SchemaPlan.NodeIndex) []const SchemaPlan.Field {
    const start = lhs(plan, n);
    const end = rhs(plan, n);
    if (start > end or end > plan.fields.len) return &.{};
    return plan.fields[start..end];
}

pub fn literal(plan: *const SchemaPlan, index: SchemaPlan.LiteralIndex) []const u8 {
    return plan.literal(index) orelse "";
}

/// Every node of the subtree at `root`, in pre-order: declaration order
/// of fields, variants and arguments. `out` is the caller's.
pub fn subtree(plan: *const SchemaPlan, scratch: Allocator, root: SchemaPlan.NodeIndex, out: *std.ArrayList(SchemaPlan.NodeIndex)) Allocator.Error!void {
    var stack: std.ArrayList(SchemaPlan.NodeIndex) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, root);
    while (stack.pop()) |n| {
        if (@backingInt(n) >= plan.nodes.len) continue;
        try out.append(scratch, n);
        const start = stack.items.len;
        switch (tag(plan, n)) {
            .parameter, .primitive => {},
            .reference => for (args(plan, n)) |a| try stack.append(scratch, @fromBackingInt(@intCast(a))),
            .record => for (fields(plan, n)) |f| try stack.append(scratch, f.child),
            .tagged => for (variants(plan, n)) |vi| {
                if (vi >= plan.variants.len) continue;
                if (plan.variants[vi].payload.unwrap()) |p| try stack.append(scratch, p);
            },
            .list, .conversion, .check, .annotation, .nullable, .maybe => try stack.append(scratch, @fromBackingInt(@intCast(lhs(plan, n)))),
            .tuple => for (range(plan, lhs(plan, n))) |a| try stack.append(scratch, @fromBackingInt(@intCast(a))),
            .codec_ref => for (args(plan, n)) |a| try stack.append(scratch, @fromBackingInt(@intCast(a))),
            .constructors => for (ctors(plan, n)) |c| {
                for (ctorArgs(plan, c)) |a| try stack.append(scratch, @fromBackingInt(@intCast(a)));
            },
            .codec_value => {},
        }
        // Pushed in order, popped in reverse: turn the new run around so the
        // first child is visited first.
        std.mem.reverse(SchemaPlan.NodeIndex, stack.items[start..]);
    }
}

/// The parameters of `r` its value reaches, each once, in the order a walk
/// of the value meets them (fields, elements and variants in declaration
/// order, a reference's arguments where the referenced schema first uses
/// them): the order `rootProblem` meets a schema argument's construction
/// failure in. `visiting` guards a reference cycle.
pub fn reachedParams(g: SchemaGraph, scratch: Allocator, r: Ref) Allocator.Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var active: std.ArrayList(Ref) = .empty;
    const d = g.definition(r.module, r.decl) orelse return &.{};
    const identity = try scratch.alloc(Arg, d.params_end - d.params_start);
    for (identity, 0..) |*a, i| a.* = .{ .root = @intCast(i) };
    try active.append(scratch, r);
    try g.paramsAt(scratch, r.module, d.root, identity, &out, &active);
    return out.items;
}

/// What a parameter of the definition being walked stands for: a parameter
/// of the outermost one, or an argument node of the definition that
/// referenced it, read with that definition's own binding.
const Arg = union(enum) {
    root: u32,
    node: struct { module: Graph.Index, node: SchemaPlan.NodeIndex, binding: []const Arg },
};

/// The walk of `reachedParams`, as `problemIn` walks a built schema: an
/// argument is reached where the referenced schema reaches its parameter,
/// and not where it is written. `active` holds the definitions being
/// walked: a reference back into one reaches nothing new.
fn paramsAt(
    g: SchemaGraph,
    scratch: Allocator,
    m: Graph.Index,
    n: SchemaPlan.NodeIndex,
    binding: []const Arg,
    out: *std.ArrayList(u32),
    active: *std.ArrayList(Ref),
) Allocator.Error!void {
    const plan = g.planOf(m);
    if (@backingInt(n) >= plan.nodes.len) return;
    switch (tag(plan, n)) {
        .primitive => {},
        .parameter => {
            const i = lhs(plan, n);
            if (i >= binding.len) return;
            switch (binding[i]) {
                .root => |p| {
                    for (out.items) |o| if (o == p) return;
                    try out.append(scratch, p);
                },
                .node => |x| try g.paramsAt(scratch, x.module, x.node, x.binding, out, active),
            }
        },
        .reference => {
            const callee = g.target(m, @fromBackingInt(@intCast(lhs(plan, n)))) orelse return;
            for (active.items) |s| if (s.module == callee.module and s.decl == callee.decl) return;
            const d = g.definition(callee.module, callee.decl) orelse return;
            const words = args(plan, n);
            const inner = try scratch.alloc(Arg, words.len);
            for (words, inner) |a, *slot| slot.* = .{ .node = .{ .module = m, .node = @fromBackingInt(@intCast(a)), .binding = binding } };
            try active.append(scratch, callee);
            defer _ = active.pop();
            try g.paramsAt(scratch, callee.module, d.root, inner, out, active);
        },
        .codec_ref => {
            const callee = g.codecTarget(m, lhs(plan, n));
            for (active.items) |s| if (s.module == callee.module and s.decl == callee.decl) return;
            const d = g.definition(callee.module, callee.decl) orelse return;
            const words = args(plan, n);
            const inner = try scratch.alloc(Arg, words.len);
            for (words, inner) |a, *slot| slot.* = .{ .node = .{ .module = m, .node = @fromBackingInt(@intCast(a)), .binding = binding } };
            try active.append(scratch, callee);
            defer _ = active.pop();
            try g.paramsAt(scratch, callee.module, d.root, inner, out, active);
        },
        .record => for (fields(plan, n)) |f| try g.paramsAt(scratch, m, f.child, binding, out, active),
        .tagged => for (variants(plan, n)) |vi| {
            if (vi >= plan.variants.len) continue;
            if (plan.variants[vi].payload.unwrap()) |p| try g.paramsAt(scratch, m, p, binding, out, active);
        },
        .list, .conversion, .check, .annotation, .nullable, .maybe => try g.paramsAt(scratch, m, @fromBackingInt(@intCast(lhs(plan, n))), binding, out, active),
        .tuple => for (elements(plan, n)) |e| try g.paramsAt(scratch, m, @fromBackingInt(@intCast(e)), binding, out, active),
        .constructors => for (ctors(plan, n)) |c| {
            for (ctorArgs(plan, c)) |a| try g.paramsAt(scratch, m, @fromBackingInt(@intCast(a)), binding, out, active);
        },
        .codec_value => {},
    }
}

/// Whether declaration `decl` of `m` is in a reference cycle of its module:
/// its description is then built under `Schema.recursive`. A cycle cannot
/// cross a module, since modules import in a DAG.
pub fn recursive(g: SchemaGraph, scratch: Allocator, m: Graph.Index, decl: u32) Allocator.Error!bool {
    return g.reaches(scratch, m, decl, decl);
}

/// Whether declaration `to` of `m` is reachable from declaration `from`'s
/// references, one reference or more: `from` and `to` are then in one
/// reference cycle when `to` reaches `from` too.
pub fn reaches(g: SchemaGraph, scratch: Allocator, m: Graph.Index, from: u32, to: u32) Allocator.Error!bool {
    // A depth-first search from `from` over its module's references.
    var stack: std.ArrayList(u32) = .empty;
    var visited: std.ArrayList(u32) = .empty;
    const plan = g.planOf(m);
    try stack.append(scratch, from);
    var first = true;
    while (stack.pop()) |at| {
        if (!first) {
            if (at == to) return true;
            var done = false;
            for (visited.items) |v| done = done or v == at;
            if (done) continue;
            try visited.append(scratch, at);
        }
        first = false;
        const d = g.definition(m, at) orelse continue;
        var nodes: std.ArrayList(SchemaPlan.NodeIndex) = .empty;
        try subtree(plan, scratch, d.root, &nodes);
        for (nodes.items) |n| {
            const t = switch (tag(plan, n)) {
                .reference => g.target(m, @fromBackingInt(@intCast(lhs(plan, n)))) orelse continue,
                .codec_ref => g.codecTarget(m, lhs(plan, n)),
                else => continue,
            };
            if (t.module != m) continue;
            try stack.append(scratch, t.decl);
        }
    }
    return false;
}
