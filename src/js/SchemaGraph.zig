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

const SchemaGraph = @This();

graph: *const Graph,
/// One per module, by `Graph.Index`.
plans: []const SchemaPlan,
birs: []const *const Bir,
interfaces: []const Interface,
provenance: []const Interface.Provenance,
interner: *const InternPool.Global,

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

    pub const count = 10;

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
            .description, .root, .parse, .print => null,
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

    pub fn decoding(o: Op) bool {
        return switch (o) {
            .parse, .decode, .read => true,
            .print, .encode, .write => false,
        };
    }

    pub fn hostIn(o: Op) bool {
        return o == .parse or o == .read;
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
};

/// A schema declaration of some module.
pub const Ref = struct { module: Graph.Index, decl: u32 };

/// `core/Schema`'s core-private values the specialised path calls: in no
/// interface, exported by `core/Schema` when they survive.
pub const compiled_values = [_][]const u8{
    "compiledParse",   "compiledPrint",  "compiledFail",    "compiledForward",   "compiledBackward",
    "belowBackward",   "readSlot",       "writeSlot",       "pathAt",            "printableWithin",
    "declared",        "decodeSlot",     "encodeSlot",      "readValueSlot",     "writeValueSlot",
    "box",             "describedOf",    "describedList",   "describedNullable", "describedConverted",
    "describedRecord", "describedField", "describedTagged", "describedVariant",  "describedRecursive",
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
            for (nodes.items) |n| switch (tag(plan, n)) {
                .primitive => try out.append(scratch, switch (std.enums.fromInt(SchemaPlan.Primitive, lhs(plan, n)) orelse .value) {
                    .string => "string",
                    .bool => "bool",
                    .int => "int",
                    .float => "float",
                    .finite_float => "finiteFloat",
                    .null => "null",
                    .value => "value",
                }),
                .list => try out.append(scratch, "describedList"),
                .nullable => try out.append(scratch, "describedNullable"),
                .conversion => try out.append(scratch, "describedConverted"),
                .record => try out.appendSlice(scratch, &.{ "describedRecord", "describedField" }),
                .tagged => try out.appendSlice(scratch, &.{ "describedTagged", "describedVariant" }),
                .parameter, .reference, .check, .annotation => {},
            };
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
        .read, .write, .decode, .encode, .read_value, .write_value => {
            // Under `--schema-library` no worker is written.
            if (library) return;
            const op = member.op().?;
            try out.appendSlice(scratch, &.{ "compiledFail", "pathAt" });
            // A generic declaration's root closes this operation's worker
            // over its arguments' slots, once this worker set survives.
            if (params != 0) try out.append(scratch, op.slot());
            for (nodes.items) |n| switch (tag(plan, n)) {
                .conversion => if (op.decoding()) {
                    try out.append(scratch, "compiledForward");
                } else {
                    try out.appendSlice(scratch, &.{ "compiledBackward", "belowBackward" });
                },
                .primitive => if (op == .print and lhs(plan, n) == @backingInt(SchemaPlan.Primitive.value)) try out.append(scratch, "printableWithin"),
                else => {},
            };
        },
    }
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
        .read, .write, .decode, .encode, .read_value, .write_value => if (library) return,
    }
    const d = g.definition(r.module, r.decl) orelse return;
    const plan = g.planOf(r.module);
    var nodes: std.ArrayList(SchemaPlan.NodeIndex) = .empty;
    try subtree(plan, scratch, d.root, &nodes);
    for (nodes.items) |n| {
        if (tag(plan, n) != .reference) continue;
        const t = g.target(r.module, @fromBackingInt(@intCast(lhs(plan, n)))) orelse continue;
        try out.append(scratch, .{ t, member });
    }
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

/// The plan's definition of declaration `decl` of module `m`.
pub fn definition(g: SchemaGraph, m: Graph.Index, decl: u32) ?*const SchemaPlan.Definition {
    const plan = g.planOf(m);
    for (plan.definitions) |*d| {
        if (@backingInt(d.decl) == decl) return d;
    }
    return null;
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
            .list, .conversion, .check, .annotation, .nullable => try stack.append(scratch, @fromBackingInt(@intCast(lhs(plan, n)))),
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
        .record => for (fields(plan, n)) |f| try g.paramsAt(scratch, m, f.child, binding, out, active),
        .tagged => for (variants(plan, n)) |vi| {
            if (vi >= plan.variants.len) continue;
            if (plan.variants[vi].payload.unwrap()) |p| try g.paramsAt(scratch, m, p, binding, out, active);
        },
        .list, .conversion, .check, .annotation, .nullable => try g.paramsAt(scratch, m, @fromBackingInt(@intCast(lhs(plan, n))), binding, out, active),
    }
}

/// Whether declaration `decl` of `m` is in a reference cycle of its module:
/// its description is then built under `Schema.recursive`. A cycle cannot
/// cross a module, since modules import in a DAG.
pub fn recursive(g: SchemaGraph, scratch: Allocator, m: Graph.Index, decl: u32) Allocator.Error!bool {
    // A depth-first search from `decl` over its module's references: is
    // `decl` reachable from itself?
    var stack: std.ArrayList(u32) = .empty;
    var visited: std.ArrayList(u32) = .empty;
    const plan = g.planOf(m);
    try stack.append(scratch, decl);
    var first = true;
    while (stack.pop()) |at| {
        if (!first) {
            if (at == decl) return true;
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
            if (tag(plan, n) != .reference) continue;
            const t = g.target(m, @fromBackingInt(@intCast(lhs(plan, n)))) orelse continue;
            if (t.module != m) continue;
            try stack.append(scratch, t.decl);
        }
    }
    return false;
}
