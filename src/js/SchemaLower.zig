//! What one `schema` declaration emits (`docs/design/schema.md` §6, *The
//! specialised path, as specified for S4*): its `via`s, its description,
//! and its two directions — the decoding worker behind `parse` and the
//! encoding worker behind `print` — each a separate reachability node
//! (`SchemaGraph.Member`), so a program ships only the directions it calls.
//!
//! **The workers are the engine's `run`, specialised.** A worker takes the
//! engine's own context and answers exactly what `run` answers for the same
//! node: the result, or `c.fail` after pushing the issues `run` would have
//! pushed, in the order it would have pushed them. Every branch below cites
//! the engine function it mirrors in `core/Schema.beni`; the differential
//! corpus (`--schema-library`, `schema.md` §10) is what holds the two to
//! one answer.
//!
//! The generator writes `JsIr` through `Lower`'s own builders, so a record
//! field is a field name `--release` renames like any other, a constructor
//! is §4's representation, and an imported worker is an import like any
//! other cross-module name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Lower = @import("Lower.zig");
const Lowerer = Lower.Lowerer;
const JsIr = @import("JsIr.zig");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const SchemaPlan = @import("../check/SchemaPlan.zig");
const SchemaGraph = @import("SchemaGraph.zig");
const SchemaShare = @import("SchemaShare.zig");

const Node = JsIr.Node;
const NameIndex = JsIr.NameIndex;
const Symbol = InternPool.Symbol;
const PNode = SchemaPlan.NodeIndex;
const Member = SchemaGraph.Member;
const Stmts = std.ArrayList(Node.Index);

const no_pos = Node.no_pos;

/// `IssueCode`'s constructors, by their position in `core/Schema.beni`'s
/// declaration: what `compiledFail` takes.
const Code = enum(u8) {
    wrong_shape = 0,
    missing_key = 1,
    unknown_key = 2,
    unknown_tag = 3,
    invalid_value = 4,
    depth_exceeded = 5,
    print_failed = 10,
};

// ---- Members ----------------------------------------------------------------

/// The member a reference names: which declaration, and which binding.
pub const MemberUse = struct { ref: SchemaGraph.Ref, kind: Interface.SchemaMember.Kind };

pub fn memberUse(l: *const Lowerer, inst: Bir.Inst.Index) ?MemberUse {
    const d = l.bir.instData(inst);
    switch (l.bir.instTag(inst)) {
        .schema_member_top => return .{ .ref = .{ .module = l.in.module, .decl = d.lhs }, .kind = std.enums.fromInt(Interface.SchemaMember.Kind, d.rhs) orelse return null },
        .ext_schema_member => {
            const module: Graph.Index = @fromBackingInt(@intCast(d.lhs));
            const sg = l.in.schemas orelse return null;
            if (module.int() >= sg.interfaces.len or module.int() >= sg.provenance.len) return null;
            const iface = &sg.interfaces[module.int()];
            if (d.rhs >= iface.schema_members.len) return null;
            const member = iface.schema_members[d.rhs];
            const decl = sg.provenance[module.int()].schemaDecl(@backingInt(member.schema)) orelse return null;
            return .{ .ref = .{ .module = module, .decl = decl.int() }, .kind = member.kind };
        },
        else => return null,
    }
}

/// Which node a member binding belongs to.
pub fn memberOf(kind: Interface.SchemaMember.Kind) ?Member {
    return switch (kind) {
        .schema => .root,
        .parse, .parse_with => .parse,
        .print, .print_with => .print,
        .type, .encoded => null,
    };
}

/// Every operation, in the order a declaration emits their workers.
const all_ops = [_]Op{ .parse, .print, .decode, .encode, .read, .write, .valid };

fn suffixOf(kind: Interface.SchemaMember.Kind) []const u8 {
    return switch (kind) {
        .schema => "schema",
        .parse => "parse",
        .print => "print",
        .parse_with => "parseWith",
        .print_with => "printWith",
        .type => "Type",
        .encoded => "Encoded",
    };
}

/// A schema member in value position: its binding, imported when another
/// module declares it.
pub fn memberReference(l: *Lowerer, inst: Bir.Inst.Index) !Node.Index {
    const p = l.pos(inst);
    const use = memberUse(l, inst) orelse return l.add(.undefined_lit, p, Node.Data.unused, Node.Data.unused);
    if (memberOf(use.kind)) |member| try l.requireLive(l.liveSchema(use.ref, member), suffixOf(use.kind));
    return l.ident(try schemaName(l, use.ref, suffixOf(use.kind)), p);
}

/// Derived codec `k`'s `schema` binding (`schema.md` §12.10), the value its
/// evidence is, required to have survived.
pub fn codecSchemaName(l: *Lowerer, k: u32) !NameIndex {
    const sg = l.in.schemas.?;
    const ref = sg.codecTarget(l.in.module, k);
    try l.requireLive(l.liveSchema(ref, .root), "a derived codec");
    return schemaName(l, ref, "schema");
}

/// Derived codec `k`'s root wrapper binding `suffix` of `member` — its
/// `parse`, `print`, `parseWith` or `printWith`, which a `Json` call is
/// written as (`SchemaGraph.jsonCall`) — required to have survived.
pub fn codecMemberName(l: *Lowerer, k: u32, member: SchemaGraph.Member, suffix: []const u8) !NameIndex {
    const sg = l.in.schemas.?;
    const ref = sg.codecTarget(l.in.module, k);
    try l.requireLive(l.liveSchema(ref, member), "a derived codec's parse or print");
    return schemaName(l, ref, suffix);
}

/// `<Module>$<Schema>$$<suffix>`: a schema's binding, by the reserved double
/// separator no module member can spell (§6). Imported when `ref` is
/// another module's.
fn schemaName(l: *Lowerer, ref: SchemaGraph.Ref, suffix: []const u8) !NameIndex {
    const sg = l.in.schemas.?;
    const bir = sg.birOf(ref.module);
    // A derived codec is `<Module>$$codec<k>$$<member>` (schema.md
    // §12.10): no `schema` declaration's name begins with `$`.
    const text = if (sg.codecIndex(ref.module, ref.decl)) |k|
        try std.fmt.allocPrint(l.scratch, "$codec{d}$${s}", .{ k, suffix })
    else
        try std.fmt.allocPrint(l.scratch, "{s}$${s}", .{ l.text(bir.symbol(bir.decls[ref.decl].name)), suffix });
    const base = try l.interner.getOrPut(l.gpa, text);
    if (ref.module != l.in.module) {
        const entry: Lowerer.Needed = .{ .module = ref.module, .base = base.toOptional() };
        try l.needName(entry);
        return l.neededName(entry);
    }
    return l.name(.{ .module = l.module_name.toOptional(), .base = base, .tag = JsIr.Name.no_tag });
}

/// The bindings a declaration exports, by what survived.
pub fn exports(l: *Lowerer, decl: u32, names: *std.ArrayList(NameIndex)) !void {
    const ref: SchemaGraph.Ref = .{ .module = l.in.module, .decl = decl };
    if (l.liveSchema(ref, .root)) {
        try names.append(l.scratch, try schemaName(l, ref, "schema"));
    }
    // The description, which another module's description names.
    if (l.liveSchema(ref, .description)) {
        try names.append(l.scratch, try schemaName(l, ref, "description"));
    }
    // The workers too, which another module's workers call; the forced
    // library path writes none. Then the root wrappers.
    const workers = !l.in.schema_library;
    const sg = l.in.schemas.?;
    for (all_ops) |op| {
        // A derived codec's `decode` and `encode` are its `read` and
        // `write` workers (`SchemaGraph.hostAliased`): none of their own.
        const own = sg.hostAliased(ref, Member.worker(op)) == null;
        if (workers and own and l.liveSchema(ref, Member.worker(op))) try names.append(l.scratch, try schemaName(l, ref, op.workerSuffix()));
        const wrapper: Member, const suffixes: [2][]const u8 = switch (op) {
            .parse => .{ .parse, .{ "parse", "parseWith" } },
            .print => .{ .print, .{ "print", "printWith" } },
            else => continue,
        };
        if (l.liveSchema(ref, wrapper)) for (suffixes) |s| try names.append(l.scratch, try schemaName(l, ref, s));
    }
}

// ---- One declaration --------------------------------------------------------

/// Everything declaration `decl` emits that survived elimination, in the
/// order its own bindings read each other: the `via`s, the description,
/// then each direction.
pub fn declaration(l: *Lowerer, out: *Stmts, decl: u32) !void {
    const sg = l.in.schemas orelse return;
    const def = sg.definition(l.in.module, decl) orelse return;
    const ref: SchemaGraph.Ref = .{ .module = l.in.module, .decl = decl };
    const codec = sg.codecIndex(l.in.module, decl) != null;
    var g: Gen = .{
        .l = l,
        .sg = sg,
        .plan = sg.planOf(l.in.module),
        .ref = ref,
        .def = def,
        .schema = if (codec) InternPool.WellKnown.codec.symbol() else l.bir.symbol(l.bir.decls[decl].name),
        .params = def.params_end - def.params_start,
        .p = if (def.token < l.in.token_starts.len) l.in.token_starts[def.token] else no_pos,
        .codec = codec,
    };
    // Each part is a top-level declaration of its own, and its
    // compiler-made names count from 1 (`backend.md` §4, *A compiler-made
    // name is numbered within its top-level declaration*). A derived codec
    // has no `via`.
    if (!codec and l.liveDecl(decl)) {
        l.restartNames();
        try g.vias(out);
    }
    if (l.liveSchema(ref, .description)) {
        l.restartNames();
        try g.description(out);
    }
    // Each operation's worker set, and for `parse` and `print` the root
    // wrappers after it, in one naming scope.
    for (all_ops) |op| {
        const own_set = sg.hostAliased(ref, Member.worker(op)) == null;
        const worker = !l.in.schema_library and own_set and l.liveSchema(ref, Member.worker(op));
        const wrapper = switch (op) {
            .parse => l.liveSchema(ref, .parse),
            .print => l.liveSchema(ref, .print),
            else => false,
        };
        if (!worker and !wrapper) continue;
        l.restartNames();
        if (worker) try g.workers(out, op);
        if (wrapper) try g.wrappers(out, op);
    }
    if (l.liveSchema(ref, .root)) {
        l.restartNames();
        try g.root(out);
    }
}

const Op = SchemaGraph.Op;

const Gen = struct {
    l: *Lowerer,
    sg: *const SchemaGraph,
    plan: *const SchemaPlan,
    ref: SchemaGraph.Ref,
    def: *const SchemaPlan.Definition,
    schema: Symbol,
    params: u32,
    p: u32,
    /// A derived codec's definition (schema.md §12.10), not a declaration.
    codec: bool = false,

    // ---- Small builders -------------------------------------------------

    fn sym(g: *Gen, text: []const u8) !Symbol {
        return g.l.interner.getOrPut(g.l.gpa, text);
    }

    fn id(g: *Gen, n: NameIndex) !Node.Index {
        return g.l.ident(n, g.p);
    }

    fn str(g: *Gen, text: []const u8) !Node.Index {
        return g.l.stringNode(text, g.p);
    }

    fn num(g: *Gen, n: u32) !Node.Index {
        var buf: [16]u8 = undefined;
        return g.l.numberNode(std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable, g.p);
    }

    fn lit(g: *Gen, tag: Node.Tag) !Node.Index {
        return g.l.add(tag, g.p, Node.Data.unused, Node.Data.unused);
    }

    fn bin(g: *Gen, op: JsIr.BinaryOp, a: Node.Index, b: Node.Index) !Node.Index {
        return g.l.binary(op, a, b, g.p);
    }

    fn not(g: *Gen, a: Node.Index) !Node.Index {
        return g.l.unary(.not, a, g.p);
    }

    fn call(g: *Gen, callee: Node.Index, args: []const Node.Index) !Node.Index {
        return g.l.call(callee, args, g.p);
    }

    /// `target.name`, a plain property.
    fn prop(g: *Gen, target: Node.Index, name: []const u8) !Node.Index {
        return g.l.member(target, try g.sym(name), g.p);
    }

    /// `target.name`, a beni record's field.
    fn field(g: *Gen, target: Node.Index, name: Symbol) !Node.Index {
        return g.l.fieldMember(target, name, g.p);
    }

    /// The context's field `name`.
    fn ctxField(g: *Gen, c: NameIndex, name: []const u8) !Node.Index {
        return g.field(try g.id(c), try g.sym(name));
    }

    /// A host global: `globalThis.name`, which a release build writes bare.
    fn global(g: *Gen, name: []const u8) !Node.Index {
        const this = try g.lit(.global_this);
        return g.prop(this, name);
    }

    fn globalCall(g: *Gen, object: []const u8, method: []const u8, args: []const Node.Index) !Node.Index {
        return g.call(try g.prop(try g.global(object), method), args);
    }

    fn indexOf(g: *Gen, target: Node.Index, key: Node.Index) !Node.Index {
        return g.l.add(.index_get, g.p, target.int(), key.int());
    }

    fn fresh(g: *Gen, base: []const u8) !NameIndex {
        return g.l.fresh(try g.sym(base));
    }

    fn constDecl(g: *Gen, out: *Stmts, n: NameIndex, value: Node.Index) !void {
        try g.l.constDecl(out, n, value, g.p);
    }

    fn letDecl(g: *Gen, out: *Stmts, n: NameIndex) !void {
        try out.append(g.l.scratch, try g.l.add(.let_decl, g.p, @backingInt(n), @backingInt(Node.OptionalIndex.none)));
    }

    fn assign(g: *Gen, out: *Stmts, n: NameIndex, value: Node.Index) !void {
        try out.append(g.l.scratch, try g.l.add(.assign_stmt, g.p, (try g.id(n)).int(), value.int()));
    }

    fn ret(g: *Gen, out: *Stmts, value: Node.Index) !void {
        try out.append(g.l.scratch, try g.l.returnStmt(value, g.p));
    }

    fn exprStmt(g: *Gen, out: *Stmts, value: Node.Index) !void {
        try out.append(g.l.scratch, try g.l.add(.expr_stmt, g.p, value.int(), Node.Data.unused));
    }

    fn ifElse(g: *Gen, out: *Stmts, cond: Node.Index, then: []const Node.Index, otherwise: []const Node.Index) !void {
        const then_range = try g.l.b.addRange(then);
        const else_range = try g.l.b.addRange(otherwise);
        const record = try g.l.b.addRecord(JsIr.If{
            .then_start = then_range.start,
            .then_end = then_range.end,
            .else_start = else_range.start,
            .else_end = else_range.end,
        });
        try out.append(g.l.scratch, try g.l.add(.if_stmt, g.p, cond.int(), @backingInt(record)));
    }

    fn whileTrue(g: *Gen, out: *Stmts, body: []const Node.Index) !void {
        const range = try g.l.b.addRange(body);
        const record = try g.l.b.addRecord(range);
        try out.append(g.l.scratch, try g.l.add(.while_true, g.p, @backingInt(NameIndex.none), @backingInt(record)));
    }

    fn breakStmt(g: *Gen, out: *Stmts) !void {
        try out.append(g.l.scratch, try g.l.add(.break_stmt, g.p, @backingInt(NameIndex.none), Node.Data.unused));
    }

    fn forOf(g: *Gen, out: *Stmts, item: NameIndex, iterable: Node.Index, body: []const Node.Index) !void {
        const range = try g.l.b.addRange(body);
        const record = try g.l.b.addRecord(JsIr.ForOf{ .iterable = iterable, .body_start = range.start, .body_end = range.end });
        try out.append(g.l.scratch, try g.l.add(.for_of, g.p, @backingInt(item), @backingInt(record)));
    }

    fn arrow(g: *Gen, params: []const NameIndex, body: []const Node.Index) !Node.Index {
        return g.l.arrowOf(params, body, g.p);
    }

    /// `(params) => value`.
    fn arrowOf(g: *Gen, params: []const NameIndex, value: Node.Index) !Node.Index {
        var body: Stmts = .empty;
        try g.ret(&body, value);
        return g.arrow(params, body.items);
    }

    /// A string concatenation of `parts`, adjacent literals joined.
    fn concat(g: *Gen, parts: []const Part) !Node.Index {
        var acc: ?Node.Index = null;
        var text: std.ArrayList(u8) = .empty;
        for (parts) |part| switch (part) {
            .text => |t| try text.appendSlice(g.l.scratch, t),
            .value => |v| {
                if (text.items.len != 0) {
                    const s = try g.str(text.items);
                    acc = if (acc) |a| try g.bin(.add, a, s) else s;
                    text = .empty;
                }
                acc = if (acc) |a| try g.bin(.add, a, v) else v;
            },
        };
        if (text.items.len != 0 or acc == null) {
            const s = try g.str(text.items);
            acc = if (acc) |a| try g.bin(.add, a, s) else s;
        }
        return acc.?;
    }

    const Part = union(enum) { text: []const u8, value: Node.Index };

    /// One of `core/Schema`'s values, by name: a builder, a runner, or a
    /// core-private value of the specialised path.
    fn core(g: *Gen, name: []const u8) !Node.Index {
        return g.l.coreSchemaValue(name, g.p);
    }

    /// A constructor of a core type, applied: `Present x`, `Null`, `Just x`.
    fn coreCtor(g: *Gen, module: []const u8, ctor: []const u8, args: []const Node.Index) !Node.Index {
        return g.l.coreCtorApplied(module, ctor, args, g.p);
    }

    /// A test that `x` is the core constructor `ctor`: `x.$ === tag`, or
    /// `x === tag` for an all-nullary type.
    fn coreCtorTest(g: *Gen, module: []const u8, ctor: []const u8, x: Node.Index) !Node.Index {
        return g.l.coreCtorTest(module, ctor, x, g.p);
    }

    // ---- Naming ---------------------------------------------------------

    fn own(g: *Gen, suffix: []const u8) !NameIndex {
        return schemaName(g.l, g.ref, suffix);
    }

    fn nodeWorkerName(g: *Gen, op: Op, n: PNode) !NameIndex {
        var buf: [32]u8 = undefined;
        const suffix = std.fmt.bufPrint(&buf, "{s}${d}", .{ op.workerSuffix(), @backingInt(n) }) catch unreachable;
        return g.own(try g.l.scratch.dupe(u8, suffix));
    }

    fn viaName(g: *Gen, conversion: u32) !NameIndex {
        var buf: [24]u8 = undefined;
        const suffix = std.fmt.bufPrint(&buf, "via${d}", .{conversion}) catch unreachable;
        return g.own(try g.l.scratch.dupe(u8, suffix));
    }

    fn paramName(g: *Gen, i: u32) !NameIndex {
        var buf: [16]u8 = undefined;
        const base = std.fmt.bufPrint(&buf, "$s{d}", .{i}) catch unreachable;
        return g.l.name(.{ .module = .none, .base = try g.sym(base), .tag = JsIr.Name.no_tag });
    }

    fn local(g: *Gen, base: []const u8) !NameIndex {
        return g.l.name(.{ .module = .none, .base = try g.sym(base), .tag = JsIr.Name.no_tag });
    }

    // ---- The `via`s -----------------------------------------------------

    /// One module constant per `via` of the declaration, evaluated once at
    /// initialisation, in source order, and read by both paths.
    fn vias(g: *Gen, out: *Stmts) !void {
        var nodes: std.ArrayList(PNode) = .empty;
        try SchemaGraph.subtree(g.plan, g.l.scratch, g.def.root, &nodes);
        for (nodes.items) |n| {
            if (SchemaGraph.tag(g.plan, n) != .conversion) continue;
            const index = SchemaGraph.rhs(g.plan, n);
            if (index >= g.plan.conversions.len) continue;
            const value = try g.l.schemaViaExpr(g.ref.decl, g.plan.conversions[index].expr);
            try g.constDecl(out, try g.viaName(index), value);
        }
    }

    // ---- The description --------------------------------------------------

    /// `$$description`: the node §5's builders would make, made by
    /// `core/Schema`'s `described…` values as the plan says — no builder
    /// and no box (§6, *What `describe` ships*). A constant for a
    /// nongeneric declaration and a function of the schema arguments for a
    /// generic one.
    fn description(g: *Gen, out: *Stmts) !void {
        const recursive = try g.sg.recursive(g.l.scratch, g.ref.module, g.ref.decl);
        const params = try g.l.scratch.alloc(NameIndex, g.params);
        for (params, 0..) |*slot, i| slot.* = try g.paramName(@intCast(i));
        const self = try g.local("$self");
        var body = try g.descNode(g.def.root, params, if (recursive) self else null);
        if (recursive) {
            body = try g.call(try g.core("describedRecursive"), &.{ try g.str(g.l.text(g.schema)), try g.arrowOf(&.{self}, body) });
        }
        // A derived codec's Encoded end is a host value (`NHost`): `decode`
        // reads it as `read` does (schema.md §12.10).
        if (g.codec) body = try g.call(try g.core("describedHost"), &.{body});
        if (g.params == 0) {
            try g.constDecl(out, try g.own("description"), body);
        } else {
            try g.constDecl(out, try g.own("description"), try g.arrowOf(params, body));
        }
    }

    /// `$$schema`, `S.schema`'s value (`schema.md` §6, *A statically known
    /// schema runs compiled*): `core/Schema`'s `declared` of the description
    /// as a function of no argument, the `parse` and `print` workers, the
    /// arguments its value reaches, then the `decode`, `encode`, `read` and
    /// `write` workers — a generic declaration's closed over its arguments'
    /// slots of that operation (`readSlot` …), made once per value; `null`
    /// for each member the build left out, which nothing then reads, and
    /// trailing ones left out. A nongeneric declaration's is one constant,
    /// `$$declared`. Under
    /// `--schema-library` it is the description itself, boxed — an
    /// `Interpreted` schema, one constant for a nongeneric declaration — so
    /// every composition over it runs through the library (§6, *The forced
    /// library path*).
    fn root(g: *Gen, out: *Stmts) !void {
        const params = try g.l.scratch.alloc(NameIndex, g.params);
        for (params, 0..) |*slot, i| slot.* = try g.paramName(@intCast(i));
        if (g.l.in.schema_library) {
            const boxed = try g.call(try g.core("box"), &.{try g.described(params)});
            if (params.len == 0) {
                const constant = try g.own("declared");
                try g.constDecl(out, constant, boxed);
                try g.constDecl(out, try g.own("schema"), try g.arrowOf(&.{try g.fresh("$u")}, try g.id(constant)));
            } else {
                try g.constDecl(out, try g.own("schema"), try g.arrowOf(params, boxed));
            }
            return;
        }
        // `declared`'s arguments: the description, the `parse` and `print`
        // workers, the arguments, then an array of the other four
        // operations' workers, its trailing `null`s left out, or no array
        // when it would hold none.
        var slots: [9]Node.Index = undefined;
        slots[0] = if (g.l.liveSchema(g.ref, .description)) try g.arrowOf(&.{}, try g.described(params)) else try g.lit(.null_lit);
        const positions = [_]struct { Op, usize }{ .{ .parse, 1 }, .{ .print, 2 }, .{ .decode, 4 }, .{ .encode, 5 }, .{ .read, 6 }, .{ .write, 7 }, .{ .valid, 8 } };
        var used: usize = 4;
        for (positions) |pick| {
            const op, const at = pick;
            const slot = &slots[at];
            if (!g.l.liveSchema(g.ref, Member.worker(op))) {
                slot.* = try g.lit(.null_lit);
                continue;
            }
            used = @max(used, at + 1);
            // A derived codec's `decode` and `encode` are its `read` and
            // `write` workers on a context whose Encoded end is a host
            // value (`hostWorker`, schema.md §12.10).
            const aliased = g.sg.hostAliased(g.ref, Member.worker(op));
            const runs: Op = if (aliased) |m| m.op().? else op;
            const worker = try g.id(try g.own(runs.workerSuffix()));
            if (params.len == 0) {
                slot.* = if (aliased != null) try g.call(try g.core("hostWorker"), &.{worker}) else worker;
                continue;
            }
            // `((r0, …) => (c, d, p, k, n, v) => worker(c, d, p, k, n, v, r0, …))(readSlot(s0), …)`:
            // each argument's slot made once, when the value is.
            const bound = try g.l.scratch.alloc(NameIndex, params.len);
            var made: std.ArrayList(Node.Index) = .empty;
            for (bound, params) |*b, param| {
                b.* = try g.fresh("$w");
                try made.append(g.l.scratch, try g.call(try g.core(runs.slot()), &.{try g.id(param)}));
            }
            const ps = try g.freshParams();
            var call_args: std.ArrayList(Node.Index) = .empty;
            for (ps.list()) |p| try call_args.append(g.l.scratch, try g.id(p));
            for (bound) |b| try call_args.append(g.l.scratch, try g.id(b));
            var inner = try g.arrowOf(&ps.list(), try g.call(worker, call_args.items));
            if (aliased != null) inner = try g.call(try g.core("hostWorker"), &.{inner});
            slot.* = try g.call(try g.arrowOf(bound, inner), made.items);
        }
        // The arguments the value reaches, in the order it meets them
        // (`compiledProblem`).
        const reached = try g.sg.reachedParams(g.l.scratch, g.ref);
        var checked: std.ArrayList(Node.Index) = .empty;
        for (reached) |i| try checked.append(g.l.scratch, try g.id(params[i]));
        slots[3] = if (params.len == 0) try g.lit(.null_lit) else try g.l.arrayNode(checked.items, g.p);
        // Every argument is written, `null` included: the release optimiser
        // drops a parameter only when every call passes the same constant.
        var call_args: [5]Node.Index = undefined;
        @memcpy(call_args[0..4], slots[0..4]);
        call_args[4] = if (used > 4) try g.l.arrayNode(slots[4..used], g.p) else try g.lit(.null_lit);
        const value = try g.call(try g.core("declared"), &call_args);
        if (params.len == 0) {
            const constant = try g.own("declared");
            try g.constDecl(out, constant, value);
            try g.constDecl(out, try g.own("schema"), try g.arrowOf(&.{try g.fresh("$u")}, try g.id(constant)));
        } else {
            try g.constDecl(out, try g.own("schema"), try g.arrowOf(params, value));
        }
    }

    /// The value's description, `$$description`, or for a generic
    /// declaration `$$description` of each schema argument's node.
    fn described(g: *Gen, params: []const NameIndex) !Node.Index {
        const desc = try g.id(try g.own("description"));
        if (params.len == 0) return desc;
        var args: std.ArrayList(Node.Index) = .empty;
        for (params) |param| try args.append(g.l.scratch, try g.call(try g.core("describedOf"), &.{try g.id(param)}));
        return g.call(desc, args.items);
    }

    /// A node's description: an expression that makes its node. `self` is
    /// the definition's own reference inside its `describedRecursive`, and
    /// a generic declaration's parameters are nodes — its root turns each
    /// schema argument into its node (`describedOf`).
    fn descNode(g: *Gen, n: PNode, params: []const NameIndex, self: ?NameIndex) Allocator.Error!Node.Index {
        const plan = g.plan;
        switch (SchemaGraph.tag(plan, n)) {
            .primitive => return g.call(try g.core("describedOf"), &.{try g.core(primitiveBuilder(SchemaGraph.lhs(plan, n)))}),
            .parameter => {
                const i = SchemaGraph.lhs(plan, n);
                if (i >= params.len) return g.lit(.undefined_lit);
                return g.id(params[i]);
            },
            .reference => {
                const t = g.sg.target(g.ref.module, @fromBackingInt(@intCast(SchemaGraph.lhs(plan, n)))) orelse return g.lit(.undefined_lit);
                const words = SchemaGraph.args(plan, n);
                if (self) |s| if (t.module == g.ref.module and t.decl == g.ref.decl and isIdentity(plan, words, params.len)) return g.id(s);
                var args: std.ArrayList(Node.Index) = .empty;
                for (words) |a| try args.append(g.l.scratch, try g.descNode(@fromBackingInt(@intCast(a)), params, self));
                const named = try g.id(try schemaName(g.l, t, "description"));
                if (g.sg.paramCount(t) == 0) return named;
                return g.call(named, args.items);
            },
            .list => return g.call(try g.core("describedList"), &.{try g.descNode(@fromBackingInt(@intCast(SchemaGraph.lhs(plan, n))), params, self)}),
            .nullable => return g.call(try g.core("describedNullable"), &.{try g.descNode(@fromBackingInt(@intCast(SchemaGraph.lhs(plan, n))), params, self)}),
            .conversion => {
                const source = try g.descNode(@fromBackingInt(@intCast(SchemaGraph.lhs(plan, n))), params, self);
                return g.call(try g.core("describedConverted"), &.{ source, try g.id(try g.viaName(SchemaGraph.rhs(plan, n))) });
            },
            .check, .annotation => return g.descNode(@fromBackingInt(@intCast(SchemaGraph.lhs(plan, n))), params, self),
            .record => return g.descRecord(n, params, self),
            .tagged => return g.descTagged(n, params, self),
            // A derived codec's (schema.md §12.10).
            .codec_ref => {
                const t = g.sg.codecTarget(g.ref.module, SchemaGraph.lhs(plan, n));
                const words = SchemaGraph.args(plan, n);
                if (self) |s| if (t.module == g.ref.module and t.decl == g.ref.decl and isIdentity(plan, words, params.len)) return g.id(s);
                var args: std.ArrayList(Node.Index) = .empty;
                for (words) |a| try args.append(g.l.scratch, try g.descNode(@fromBackingInt(@intCast(a)), params, self));
                const named = try g.id(try schemaName(g.l, t, "description"));
                if (g.sg.paramCount(t) == 0) return named;
                return g.call(named, args.items);
            },
            .codec_value => return g.call(try g.core("describedOf"), &.{try g.codecValue(n)}),
            .maybe => return g.call(try g.core("describedMaybe"), &.{
                try g.descNode(@fromBackingInt(@intCast(SchemaGraph.lhs(plan, n))), params, self),
                try g.num(SchemaGraph.rhs(plan, n)),
            }),
            .tuple => {
                const elems = SchemaGraph.elements(plan, n);
                var items: std.ArrayList(Node.Index) = .empty;
                for (elems) |e| try items.append(g.l.scratch, try g.descNode(@fromBackingInt(@intCast(e)), params, self));
                const xs = try g.fresh("$xs");
                var values: std.ArrayList(Node.Index) = .empty;
                for (0..elems.len) |i| try values.append(g.l.scratch, try g.indexOf(try g.id(xs), try g.num(@intCast(i))));
                const there = try g.arrowOf(&.{xs}, try g.tupleValue(values.items));
                const t = try g.fresh("$t");
                var parts: std.ArrayList(Node.Index) = .empty;
                for (0..elems.len) |i| try parts.append(g.l.scratch, try g.l.member(try g.id(t), try g.l.slotName(@intCast(i)), g.p));
                const back = try g.arrowOf(&.{t}, try g.l.arrayNode(parts.items, g.p));
                return g.call(try g.core("describedTuple"), &.{ try g.l.arrayNode(items.items, g.p), there, back });
            },
            .constructors => return g.descCtors(n, params, self),
        }
    }

    /// A tuple of `values`: `⊤`'s `null` for none, else §4's object of
    /// positional slots.
    fn tupleValue(g: *Gen, values: []const Node.Index) !Node.Index {
        if (values.len == 0) return g.lit(.null_lit);
        var properties: std.ArrayList(Node.Index) = .empty;
        for (values, 0..) |v, i| try properties.append(g.l.scratch, try g.l.property(try g.l.slotName(@intCast(i)), v, g.p));
        return g.l.object(properties.items, g.p);
    }

    /// A `codec_value` node: its type's module's `codec`, applied to `⊤`.
    fn codecValue(g: *Gen, n: PNode) !Node.Index {
        const target = g.plan.value_targets[SchemaGraph.lhs(g.plan, n)];
        const callee = try g.l.valueNamed(target.package, SchemaGraph.symbol(g.plan, target.module), SchemaGraph.symbol(g.plan, target.name), g.p);
        return g.call(callee, &.{try g.lit(.null_lit)});
    }

    /// A derived custom type's constructor: its representation (§4) and
    /// how it is named and built.
    fn codecCtor(g: *Gen, n: PNode, c: u32) !?Lowerer.CodecCtor {
        const target = g.plan.type_targets[SchemaGraph.lhs(g.plan, n)];
        return g.l.codecCtor(target.package, SchemaGraph.symbol(g.plan, target.module), SchemaGraph.symbol(g.plan, target.name), g.plan.codec_ctors[c].order);
    }

    /// `describedConstructors([[name, [nodes], inject, project], …])`.
    fn descCtors(g: *Gen, n: PNode, params: []const NameIndex, self: ?NameIndex) Allocator.Error!Node.Index {
        const plan = g.plan;
        var rows: std.ArrayList(Node.Index) = .empty;
        for (SchemaGraph.ctors(plan, n)) |c| {
            const cc = (try g.codecCtor(n, c)) orelse continue;
            const arg_nodes = SchemaGraph.ctorArgs(plan, c);
            var descs: std.ArrayList(Node.Index) = .empty;
            for (arg_nodes) |a| try descs.append(g.l.scratch, try g.descNode(@fromBackingInt(@intCast(a)), params, self));
            const xs = try g.fresh("$xs");
            var built: std.ArrayList(Node.Index) = .empty;
            for (0..arg_nodes.len) |i| try built.append(g.l.scratch, try g.indexOf(try g.id(xs), try g.num(@intCast(i))));
            const inject = try g.arrowOf(&.{xs}, try g.l.codecCtorValue(cc, built.items, g.p));
            const v = try g.fresh("$v");
            var read: std.ArrayList(Node.Index) = .empty;
            for (0..arg_nodes.len) |i| try read.append(g.l.scratch, try g.l.codecCtorArg(cc, try g.id(v), @intCast(i), g.p));
            const taken = try g.l.arrayNode(read.items, g.p);
            const project = try g.arrowOf(&.{v}, if (try g.l.codecCtorTest(cc, try g.id(v), g.p)) |t|
                try g.l.condOf(t, taken, try g.lit(.null_lit), g.p)
            else
                taken);
            try rows.append(g.l.scratch, try g.l.arrayNode(&.{
                try g.str(g.l.text(SchemaGraph.symbol(plan, plan.codec_ctors[c].name))),
                try g.l.arrayNode(descs.items, g.p),
                inject,
                project,
            }, g.p));
        }
        return g.call(try g.core("describedConstructors"), &.{try g.l.arrayNode(rows.items, g.p)});
    }

    /// `describedRecord([describedField(name, key, optional, node), …], to,
    /// from)`: the mapping between the left-nested product and the record
    /// written out once, for both endpoints.
    fn descRecord(g: *Gen, n: PNode, params: []const NameIndex, self: ?NameIndex) Allocator.Error!Node.Index {
        const fields = SchemaGraph.fields(g.plan, n);
        var fs: std.ArrayList(Node.Index) = .empty;
        for (fields) |f| {
            const name = SchemaGraph.symbol(g.plan, f.name);
            // A derived record's `Maybe` field (schema.md §12.4): its key
            // absent is `Nothing`, and its node the `maybe`'s inner one.
            if (SchemaGraph.isMaybeField(g.plan, f)) {
                const inner = try g.descNode(@fromBackingInt(@intCast(SchemaGraph.lhs(g.plan, f.child))), params, self);
                try fs.append(g.l.scratch, try g.call(try g.core("describedMaybeField"), &.{ try g.str(g.l.text(name)), inner, try g.num(SchemaGraph.rhs(g.plan, f.child)) }));
                continue;
            }
            const child = try g.descNode(f.child, params, self);
            try fs.append(g.l.scratch, try g.call(try g.core("describedField"), &.{
                try g.str(g.l.text(name)),
                try g.str(SchemaGraph.literal(g.plan, f.external)),
                try g.lit(if (f.optional) .true_lit else .false_lit),
                child,
            }));
        }
        const to, const from = try g.mapping(fields);
        return g.call(try g.core("describedRecord"), &.{ try g.l.arrayNode(fs.items, g.p), to, from });
    }

    /// The two functions of a record's mapping, for a record whose fields
    /// are `fields`: `( ( ( (), a ), b ), c )` — `{a: {a: {a: null, b: a},
    /// b: b}, b: c}` — to `{a, b, c}`, and back.
    fn mapping(g: *Gen, fields: []const SchemaPlan.Field) !struct { Node.Index, Node.Index } {
        const product = try g.fresh("$p");
        const names = try g.l.scratch.alloc(Symbol, fields.len);
        for (fields, names) |f, *slot| slot.* = SchemaGraph.symbol(g.plan, f.name);
        // to: field i is `p` read `.a` (n − 1 − i) times, then `.b`.
        const values = try g.l.scratch.alloc(Node.Index, fields.len);
        for (values, 0..) |*slot, i| {
            var at = try g.id(product);
            var k = fields.len - 1 - i;
            while (k > 0) : (k -= 1) at = try g.l.member(at, try g.l.slotName(0), g.p);
            slot.* = try g.l.member(at, try g.l.slotName(1), g.p);
        }
        const to = try g.arrowOf(&.{product}, try g.recordValue(names, values));
        // from: the product rebuilt from the record's fields.
        const r = try g.fresh("$r");
        var acc = try g.lit(.null_lit);
        for (names) |name| {
            acc = try g.l.object(&.{
                try g.l.property(try g.l.slotName(0), acc, g.p),
                try g.l.property(try g.l.slotName(1), try g.field(try g.id(r), name), g.p),
            }, g.p);
        }
        const from = try g.arrowOf(&.{r}, acc);
        return .{ to, from };
    }

    /// A beni record of `names` and `values`, keys in the canonical order.
    fn recordValue(g: *Gen, names: []const Symbol, values: []const Node.Index) !Node.Index {
        const order = try g.l.fieldOrder(names);
        var properties: std.ArrayList(Node.Index) = .empty;
        for (order) |i| try properties.append(g.l.scratch, try g.l.fieldProperty(names[i], values[i], g.p));
        return g.l.object(properties.items, g.p);
    }

    /// `describedTagged("key", [describedVariant(name, tag, payload,
    /// inject, project), …])`, a nullary variant's payload `null`.
    fn descTagged(g: *Gen, n: PNode, params: []const NameIndex, self: ?NameIndex) Allocator.Error!Node.Index {
        const plan = g.plan;
        const discriminator = SchemaGraph.literal(plan, @fromBackingInt(@intCast(SchemaGraph.lhs(plan, n))));
        var variants: std.ArrayList(Node.Index) = .empty;
        const info = g.variantsOf(n);
        for (SchemaGraph.variants(plan, n), 0..) |vi, order| {
            if (vi >= plan.variants.len) continue;
            const v = plan.variants[vi];
            const name = SchemaGraph.symbol(plan, v.name);
            const tag_text = SchemaGraph.literal(plan, v.external);
            const payload = if (v.payload.unwrap()) |p| try g.descNode(p, params, self) else try g.lit(.null_lit);
            const inject, const project = try g.injection(info, @intCast(order), name, v.payload != .none);
            try variants.append(g.l.scratch, try g.call(try g.core("describedVariant"), &.{
                try g.str(g.l.text(name)),
                try g.str(tag_text),
                payload,
                inject,
                project,
            }));
        }
        return g.call(try g.core("describedTagged"), &.{ try g.str(discriminator), try g.l.arrayNode(variants.items, g.p) });
    }

    /// Whether any variant of the union has a payload: §4's padded object
    /// then, the bare tag when none does.
    fn variantsOf(g: *Gen, n: PNode) Variants {
        var padded = false;
        for (SchemaGraph.variants(g.plan, n)) |vi| {
            if (vi < g.plan.variants.len and g.plan.variants[vi].payload != .none) padded = true;
        }
        return .{ .padded = padded };
    }

    const Variants = struct { padded: bool };

    /// The constructor of variant `name` applied to `payload` (null for a
    /// nullary one): one value for both families.
    fn variantValue(g: *Gen, info: Variants, order: u32, name: Symbol, payload: ?Node.Index) !Node.Index {
        const rep = Lowerer.schemaCtorRep(.{
            .order = order,
            .count = 0,
            .arity = @intFromBool(payload != null),
            .padded = info.padded,
            .name = name,
            .schema = g.schema,
            .module = g.ref.module,
            .ext = false,
            .owner = g.ref.decl,
        });
        if (payload) |value| return g.l.ctorValue(rep, name, &.{value}, g.p);
        if (!info.padded) return g.l.ctorValue(rep, name, &.{}, g.p);
        return g.id(try g.l.schemaNullary(.{
            .order = order,
            .count = 0,
            .arity = 0,
            .padded = true,
            .name = name,
            .schema = g.schema,
            .module = g.ref.module,
            .ext = false,
            .owner = g.ref.decl,
        }, rep));
    }

    /// Whether `x` is variant `name`.
    fn variantTest(g: *Gen, info: Variants, name: Symbol, x: Node.Index) !Node.Index {
        const subject = if (info.padded) try g.l.member(x, g.l.well.tag, g.p) else x;
        return g.bin(.strict_eq, subject, try g.str(g.l.text(name)));
    }

    /// A variant's injection, `inject` and `project`, which both endpoints
    /// share.
    fn injection(g: *Gen, info: Variants, order: u32, name: Symbol, payload: bool) !struct { Node.Index, Node.Index } {
        const x = try g.fresh("$x");
        const inject = if (payload)
            try g.arrowOf(&.{x}, try g.variantValue(info, order, name, try g.id(x)))
        else
            try g.arrowOf(&.{x}, try g.variantValue(info, order, name, null));
        const v = try g.fresh("$v");
        const found = if (payload)
            try g.coreCtor("Maybe", "Just", &.{try g.l.member(try g.id(v), try g.l.slotName(0), g.p)})
        else
            try g.coreCtor("Maybe", "Just", &.{try g.lit(.null_lit)});
        const project = try g.arrowOf(&.{v}, try g.l.condOf(
            try g.variantTest(info, name, try g.id(v)),
            found,
            try g.coreCtor("Maybe", "Nothing", &.{}),
            g.p,
        ));
        return .{ inject, project };
    }

    // ---- The directions ---------------------------------------------------

    /// The two root wrappers of `parse` (`S.parse`, `S.parseWith`) or of
    /// `print`, over the operation's worker; or, under `--schema-library`,
    /// over the description.
    fn wrappers(g: *Gen, out: *Stmts, op: Op) !void {
        const root_suffix, const with_suffix = switch (op) {
            .parse => .{ "parse", "parseWith" },
            .print => .{ "print", "printWith" },
            else => unreachable,
        };
        const params = try g.l.scratch.alloc(NameIndex, g.params);
        for (params, 0..) |*slot, i| slot.* = try g.paramName(@intCast(i));
        const options = try g.local("$o");
        const input = try g.local("$t");

        // `…With`.
        var with_params: std.ArrayList(NameIndex) = .empty;
        try with_params.appendSlice(g.l.scratch, params);
        try with_params.append(g.l.scratch, options);
        try with_params.append(g.l.scratch, input);
        const with_body = if (g.l.in.schema_library) blk: {
            // The whole root through the interpreter (`schema.md` §10's
            // forced library path): `S.schema`, which is the boxed
            // description there.
            var args: std.ArrayList(Node.Index) = .empty;
            for (params) |param| try args.append(g.l.scratch, try g.id(param));
            if (params.len == 0) try args.append(g.l.scratch, try g.lit(.null_lit));
            const s = try g.call(try g.id(try g.own("schema")), args.items);
            break :blk try g.call(try g.core(with_suffix), &.{ s, try g.id(options), try g.id(input) });
        } else blk: {
            const worker_name = try g.own(op.workerSuffix());
            // The arguments the value reaches, in the order it meets them
            // (`compiledProblem`).
            const reached = try g.sg.reachedParams(g.l.scratch, g.ref);
            var checked: std.ArrayList(Node.Index) = .empty;
            for (reached) |i| try checked.append(g.l.scratch, try g.id(params[i]));
            const worker = if (params.len == 0) try g.id(worker_name) else wrapped: {
                const ps = try g.freshParams();
                var args: std.ArrayList(Node.Index) = .empty;
                for (ps.list()) |n| try args.append(g.l.scratch, try g.id(n));
                for (params) |param| try args.append(g.l.scratch, try g.call(try g.core(op.slot()), &.{try g.id(param)}));
                break :wrapped try g.arrowOf(&ps.list(), try g.call(try g.id(worker_name), args.items));
            };
            break :blk try g.call(try g.core(if (op == .parse) "compiledParse" else "compiledPrint"), &.{
                try g.id(options),
                if (params.len == 0) try g.lit(.null_lit) else try g.l.arrayNode(checked.items, g.p),
                worker,
                try g.id(input),
            });
        };
        try g.constDecl(out, try g.own(with_suffix), try g.arrowOf(with_params.items, with_body));

        // The root wrapper without options.
        var root_params: std.ArrayList(NameIndex) = .empty;
        try root_params.appendSlice(g.l.scratch, params);
        try root_params.append(g.l.scratch, input);
        var root_args: std.ArrayList(Node.Index) = .empty;
        for (params) |param| try root_args.append(g.l.scratch, try g.id(param));
        try root_args.append(g.l.scratch, try g.core("defaultOptions"));
        try root_args.append(g.l.scratch, try g.id(input));
        try g.constDecl(out, try g.own(root_suffix), try g.arrowOf(root_params.items, try g.call(try g.id(try g.own(with_suffix)), root_args.items)));
    }

    /// A worker's parameters: the context, the depth, the parent's path and
    /// the two segments, the value, then one slot per schema parameter.
    const Params = struct {
        c: NameIndex,
        d: NameIndex,
        pp: NameIndex,
        pk: NameIndex,
        pn: NameIndex,
        v: NameIndex,

        fn list(ps: Params) [6]NameIndex {
            return .{ ps.c, ps.d, ps.pp, ps.pk, ps.pn, ps.v };
        }
    };

    fn workerParams(g: *Gen) !Params {
        return .{
            .c = try g.local("c"),
            .d = try g.local("d"),
            .pp = try g.local("p"),
            .pk = try g.local("k"),
            .pn = try g.local("n"),
            .v = try g.local("v"),
        };
    }

    /// A worker's parameters for an arrow written inside another function,
    /// which must not take its enclosing worker's names.
    fn freshParams(g: *Gen) !Params {
        return .{
            .c = try g.fresh("$c"),
            .d = try g.fresh("$d"),
            .pp = try g.fresh("$p"),
            .pk = try g.fresh("$k"),
            .pn = try g.fresh("$n"),
            .v = try g.fresh("$v"),
        };
    }

    fn slotNames(g: *Gen) ![]const NameIndex {
        const slots = try g.l.scratch.alloc(NameIndex, g.params);
        for (slots, 0..) |*slot, i| slot.* = try g.paramName(@intCast(i));
        return slots;
    }

    /// Every worker of one operation: the definition's own and one per
    /// record, list and tagged node of its value and per argument of a
    /// generic reference.
    fn workers(g: *Gen, out: *Stmts, op: Op) !void {
        var nodes: std.ArrayList(PNode) = .empty;
        try SchemaGraph.subtree(g.plan, g.l.scratch, g.def.root, &nodes);
        // A tagged node's payload records are written into its own worker.
        var payloads: std.ArrayList(PNode) = .empty;
        for (nodes.items) |n| {
            if (SchemaGraph.tag(g.plan, n) != .tagged) continue;
            for (SchemaGraph.variants(g.plan, n)) |vi| {
                if (vi >= g.plan.variants.len) continue;
                if (g.plan.variants[vi].payload.unwrap()) |payload| try payloads.append(g.l.scratch, payload);
            }
        }
        try g.emitWorker(out, op, g.def.root, try g.own(op.workerSuffix()));
        for (nodes.items) |n| {
            if (n == g.def.root) continue;
            if (!g.needsWorker(n, payloads.items)) continue;
            try g.emitWorker(out, op, n, try g.nodeWorkerName(op, n));
        }
    }

    /// Whether node `n` is called as a worker of its own: a record, list or
    /// tagged node (not a payload), or an argument of a generic reference
    /// that is not a bare parameter or a bare reference.
    fn needsWorker(g: *Gen, n: PNode, payloads: []const PNode) bool {
        for (payloads) |payload| if (payload == n) return false;
        if (isComposite(g.plan, n)) return true;
        return g.isPassedArgument(n);
    }

    fn isPassedArgument(g: *Gen, n: PNode) bool {
        const plan = g.plan;
        for (0..plan.nodes.len) |i| {
            const r: PNode = @fromBackingInt(@intCast(@as(u32, @intCast(i))));
            if (SchemaGraph.tag(plan, r) != .reference) continue;
            for (SchemaGraph.args(plan, r)) |a| {
                if (a != @backingInt(n)) continue;
                return switch (SchemaGraph.tag(plan, n)) {
                    .parameter => false,
                    .reference => SchemaGraph.args(plan, n).len != 0,
                    else => true,
                };
            }
        }
        return false;
    }

    /// The worker `name` for node `n`.
    fn emitWorker(g: *Gen, out: *Stmts, op: Op, n: PNode, name: NameIndex) !void {
        const ps = try g.workerParams();
        const slots = try g.slotNames();
        var params: std.ArrayList(NameIndex) = .empty;
        try params.appendSlice(g.l.scratch, &ps.list());
        try params.appendSlice(g.l.scratch, slots);
        var w: Fn = .{ .g = g, .op = op, .ps = ps, .slots = slots, .c = ps.c };
        var body: Stmts = .empty;
        switch (SchemaGraph.tag(g.plan, n)) {
            .record => try w.recordWorker(&body, n),
            .list => try w.listWorker(&body, n),
            .tagged => try w.taggedWorker(&body, n),
            .tuple => try w.tupleWorker(&body, n),
            .constructors => try w.ctorsWorker(&body, n),
            else => {
                const r = try g.fresh("$r");
                try g.letDecl(&body, r);
                try w.into(&body, n, ps.v, 0, w.ownAt(), r);
                try g.ret(&body, try g.id(r));
            },
        }
        try g.constDecl(out, name, try g.arrow(params.items, body.items));
    }
};

/// A path segment, as the code that names it: none (the value is its
/// parent's own position, the root), a literal key, or a name holding a
/// key or an index.
const Seg = union(enum) { none, text: []const u8, name: NameIndex, index: u32 };

/// Where a value is: its parent's path — a name holding a path, or the
/// worker's own value's path made from its three parameters — and the
/// segment it was read at as the input and as the output name it.
const At = struct {
    parent: Parent,
    k: Seg,
    n: Seg,

    const Parent = union(enum) { path: NameIndex, own };
};

/// One worker being written.
const Fn = struct {
    g: *Gen,
    op: Op,
    ps: Gen.Params,
    slots: []const NameIndex,
    /// The context the code reads: the parameter, or below an encoding
    /// conversion the one `belowBackward` made.
    c: NameIndex,
    /// The worker's own value's path, once made (`hereFor`).
    here: ?NameIndex = null,

    fn ownAt(w: *const Fn) At {
        return .{ .parent = .{ .path = w.ps.pp }, .k = .{ .name = w.ps.pk }, .n = .{ .name = w.ps.pn } };
    }

    /// A child of the worker's own value, read at `k` and written at `n`.
    fn childAt(w: *const Fn, k: Seg, n: Seg) At {
        return .{ .parent = if (w.here) |h| .{ .path = h } else .own, .k = k, .n = n };
    }

    fn segExpr(w: *Fn, s: Seg) !Node.Index {
        return switch (s) {
            .none => w.g.lit(.null_lit),
            .text => |t| w.g.str(t),
            .name => |n| w.g.id(n),
            .index => |i| w.g.num(i),
        };
    }

    /// The three path arguments of a helper or a child worker.
    fn pathArgs(w: *Fn, at: At) ![3]Node.Index {
        const parent = switch (at.parent) {
            .path => |n| try w.g.id(n),
            .own => try w.g.call(try w.g.core("pathAt"), &.{ try w.g.id(w.ps.pp), try w.g.id(w.ps.pk), try w.g.id(w.ps.pn) }),
        };
        return .{ parent, try w.segExpr(at.k), try w.segExpr(at.n) };
    }

    /// `const here = pathAt(p, k, n)`, when a child is read through a worker
    /// or a conversion on the success path: once, rather than per child.
    fn hereFor(w: *Fn, out: *Stmts) !void {
        const g = w.g;
        const here = try g.local("$here");
        try g.constDecl(out, here, try g.call(try g.core("pathAt"), &.{ try g.id(w.ps.pp), try g.id(w.ps.pk), try g.id(w.ps.pn) }));
        w.here = here;
    }

    /// `compiledFail(c, …at, code, message, input, written)`.
    fn fail(w: *Fn, at: At, code: Code, message: Node.Index, input: Node.Index, written: bool) !Node.Index {
        const g = w.g;
        // A validator makes no issue: its failure is `c.fail` alone.
        if (w.op == .valid) return w.failMark();
        const path = try w.pathArgs(at);
        return g.call(try g.core("compiledFail"), &.{
            try g.id(w.c),
            path[0],
            path[1],
            path[2],
            try g.num(@backingInt(code)),
            message,
            input,
            try g.lit(if (written) .true_lit else .false_lit),
        });
    }

    /// A failure with a literal message: the depth bound and a missing key
    /// named as the input names it call their shared helper where the build
    /// shares it (`SchemaShare`), and the rest `compiledFail` (`schema.md`
    /// §6, *Validators shared across schemas*).
    fn failText(w: *Fn, at: At, code: Code, message: []const u8, input: Node.Index, written: bool) !Node.Index {
        const g = w.g;
        if (w.op == .valid) return w.failMark();
        if (!written) {
            const shared: ?SchemaShare.Helper = if (code == .depth_exceeded and std.mem.eql(u8, message, depth_message))
                .deep
            else if (code == .missing_key and at.k == .text and missingMessage(at.k.text, message))
                .missing
            else
                null;
            if (shared) |h| if (g.sg.share.on(h)) {
                const path = try w.pathArgs(at);
                return g.call(try g.core(h.coreName()), &.{ try g.id(w.c), path[0], path[1], path[2], input });
            };
        }
        return w.fail(at, code, try g.str(message), input, written);
    }

    /// `c.fail`.
    fn failMark(w: *Fn) !Node.Index {
        return w.g.ctxField(w.c, "fail");
    }

    /// The depth `d + offset`.
    fn depth(w: *Fn, offset: u32) !Node.Index {
        const d = try w.g.id(w.ps.d);
        if (offset == 0) return d;
        return w.g.bin(.add, d, try w.g.num(offset));
    }

    /// `d + offset >= c.max`.
    fn deepTest(w: *Fn, offset: u32) !Node.Index {
        return w.g.bin(.ge, try w.depth(offset), try w.g.ctxField(w.c, "max"));
    }

    /// `c.issues.length`.
    fn issueCount(w: *Fn) !Node.Index {
        // A validator's context gains no issue.
        if (w.op == .valid) return w.g.num(0);
        return w.g.prop(try w.g.ctxField(w.c, "issues"), "length");
    }

    /// `if (x === c.fail && !c.all) return c.fail;`: a sibling's failure
    /// stops the record under `FirstError` (`fieldsFrom`).
    fn stopOnFailure(w: *Fn, out: *Stmts, x: NameIndex) !void {
        const g = w.g;
        const failed = try g.bin(.strict_eq, try g.id(x), try w.failMark());
        const cond = try g.bin(.logical_and, failed, try g.not(try g.ctxField(w.c, "all")));
        var then: Stmts = .empty;
        try g.ret(&then, try w.failMark());
        try g.ifElse(out, cond, then.items, &.{});
    }

    /// `if (c.issues.length > before) return c.fail;` (`recordOf`,
    /// `listOf`).
    fn failIfGrew(w: *Fn, out: *Stmts, before: NameIndex) !void {
        const g = w.g;
        var then: Stmts = .empty;
        try g.ret(&then, try w.failMark());
        try g.ifElse(out, try g.bin(.gt, try w.issueCount(), try g.id(before)), then.items, &.{});
    }

    fn isObjectTest(w: *Fn, v: Node.Index, v2: Node.Index, v3: Node.Index) !Node.Index {
        const g = w.g;
        // `typeof v === "object" && v !== null && !Array.isArray(v)`, negated.
        const not_object = try g.bin(.strict_ne, try g.l.unary(.type_of, v, g.p), try g.str("object"));
        const is_null = try g.bin(.strict_eq, v2, try g.lit(.null_lit));
        const is_array = try g.globalCall("Array", "isArray", &.{v3});
        return g.bin(.logical_or, try g.bin(.logical_or, not_object, is_null), is_array);
    }

    // ---- One value, written into its parent ------------------------------

    /// The statements that set `target` to node `n`'s answer for the value
    /// `x` at depth `d + offset` and place `at`: written in place for a
    /// primitive, a `nullable` and a `via`, a call for anything else.
    /// `run` for one node on the operation's ends (`prim`, `NNullable`,
    /// `NConverted`; the rest are calls).
    fn into(w: *Fn, out: *Stmts, n: PNode, x: NameIndex, offset: u32, at: At, target: NameIndex) Allocator.Error!void {
        const g = w.g;
        const plan = g.plan;
        const child: PNode = @fromBackingInt(@intCast(SchemaGraph.lhs(plan, n)));
        switch (SchemaGraph.tag(plan, n)) {
            .primitive => if (w.op.hostIn())
                try w.readPrimitive(out, SchemaGraph.lhs(plan, n), x, at, target)
            else
                try w.typedPrimitive(out, SchemaGraph.lhs(plan, n), x, offset, at, target),
            .nullable => try w.nullable(out, child, x, offset, at, target),
            .conversion => if (w.op.decoding()) {
                // `NConverted`, decoding: the source, then `forward`.
                const b = try g.fresh("$b");
                try g.letDecl(out, b);
                try w.into(out, child, x, offset, at, b);
                const path = try w.pathArgs(at);
                const forward = try g.call(try g.core("compiledForward"), &.{
                    try g.id(w.c),
                    path[0],
                    path[1],
                    path[2],
                    try g.id(try g.viaName(SchemaGraph.rhs(plan, n))),
                    try g.id(b),
                });
                const failed = try g.bin(.strict_eq, try g.id(b), try w.failMark());
                try g.assign(out, target, try g.l.condOf(failed, try w.failMark(), forward, g.p));
            } else {
                // `NConverted`, encoding: `backward`, then the source below
                // it, where a failure is in what is written.
                const b = try g.fresh("$b");
                const path = try w.pathArgs(at);
                try g.constDecl(out, b, try g.call(try g.core("compiledBackward"), &.{
                    try g.id(w.c),
                    path[0],
                    path[1],
                    path[2],
                    try g.id(try g.viaName(SchemaGraph.rhs(plan, n))),
                    try g.id(x),
                }));
                var then: Stmts = .empty;
                try g.assign(&then, target, try w.failMark());
                var otherwise: Stmts = .empty;
                const below = try g.fresh("$cv");
                try g.constDecl(&otherwise, below, try g.call(try g.core("belowBackward"), &.{try g.id(w.c)}));
                const outer = w.c;
                w.c = below;
                defer w.c = outer;
                try w.into(&otherwise, child, b, offset, at, target);
                try g.ifElse(out, try g.bin(.strict_eq, try g.id(b), try g.ctxField(outer, "fail")), then.items, otherwise.items);
            },
            .check, .annotation => try w.into(out, child, x, offset, at, target),
            .maybe => try w.maybe(out, n, x, offset, at, target),
            else => {
                const callee, const extra = try w.calleeOf(n);
                try w.callInto(out, callee, extra, x, offset, at, target);
            },
        }
    }

    /// A derived `Maybe` (`NMaybe`, schema.md §12.4, §12.10), whose Encoded
    /// end is a host value. Decoding: `null` is `Nothing` unless the inner
    /// node reads it, anything else the inner node's answer in `Just`.
    /// Encoding: `Nothing` writes `null`, `Just` its value — refused when
    /// the inner node's is a `null` that would read back as `Nothing`.
    fn maybe(w: *Fn, out: *Stmts, n: PNode, x: NameIndex, offset: u32, at: At, target: NameIndex) Allocator.Error!void {
        const g = w.g;
        const plan = g.plan;
        const mode = SchemaGraph.rhs(plan, n);
        const inner: PNode = @fromBackingInt(@intCast(SchemaGraph.lhs(plan, n)));
        if (w.op.decoding()) {
            var nothing: Stmts = .empty;
            try g.assign(&nothing, target, try g.coreCtor("Maybe", "Nothing", &.{}));
            var just: Stmts = .empty;
            const y = try g.fresh("$y");
            try g.letDecl(&just, y);
            try w.into(&just, inner, x, offset, at, y);
            const failed = try g.bin(.strict_eq, try g.id(y), try w.failMark());
            try g.assign(&just, target, try g.l.condOf(failed, try w.failMark(), try g.coreCtor("Maybe", "Just", &.{try g.id(y)}), g.p));
            if (mode & SchemaPlan.Maybe.reads_null != 0) {
                try out.appendSlice(g.l.scratch, just.items);
            } else {
                try g.ifElse(out, try g.bin(.strict_eq, try g.id(x), try g.lit(.null_lit)), nothing.items, just.items);
            }
            return;
        }
        var then: Stmts = .empty;
        try g.assign(&then, target, try g.lit(.null_lit));
        var otherwise: Stmts = .empty;
        const a = try g.fresh("$a");
        try g.constDecl(&otherwise, a, try g.l.member(try g.id(x), try g.l.slotName(0), g.p));
        try w.into(&otherwise, inner, a, offset, at, target);
        if (mode & SchemaPlan.Maybe.refuse_null != 0) {
            var refuse: Stmts = .empty;
            try g.assign(&refuse, target, try w.failText(at, .invalid_value, "the value inside Just writes null, which reads back as Nothing", try g.id(a), true));
            try g.ifElse(&otherwise, try g.bin(.strict_eq, try g.id(target), try g.lit(.null_lit)), refuse.items, &.{});
        }
        try g.ifElse(out, try g.coreCtorTest("Maybe", "Nothing", try g.id(x)), then.items, otherwise.items);
    }

    /// `NNullable`: `null` on a host input, `Null` on a typed one, is the
    /// output's `null` or `Null`; anything else is the child's answer, in
    /// `NonNull` when the output is typed.
    fn nullable(w: *Fn, out: *Stmts, child: PNode, x: NameIndex, offset: u32, at: At, target: NameIndex) Allocator.Error!void {
        const g = w.g;
        const is_null = if (w.op.hostIn())
            try g.bin(.strict_eq, try g.id(x), try g.lit(.null_lit))
        else
            try g.coreCtorTest("Schema", "Null", try g.id(x));
        var then: Stmts = .empty;
        try g.assign(&then, target, if (w.op.hostOut()) try g.lit(.null_lit) else try g.coreCtor("Schema", "Null", &.{}));
        var otherwise: Stmts = .empty;
        const inner = if (w.op.hostIn()) x else inner: {
            const a = try g.fresh("$a");
            try g.constDecl(&otherwise, a, try g.l.member(try g.id(x), try g.l.slotName(0), g.p));
            break :inner a;
        };
        if (w.op.hostOut()) {
            try w.into(&otherwise, child, inner, offset, at, target);
        } else {
            const y = try g.fresh("$y");
            try g.letDecl(&otherwise, y);
            try w.into(&otherwise, child, inner, offset, at, y);
            const failed = try g.bin(.strict_eq, try g.id(y), try w.failMark());
            try g.assign(&otherwise, target, try g.l.condOf(failed, try w.failMark(), try g.coreCtor("Schema", "NonNull", &.{try g.id(y)}), g.p));
        }
        try g.ifElse(out, is_null, then.items, otherwise.items);
    }

    /// A call of another worker: a record, list or tagged node of this
    /// definition, an argument, a referenced definition or a slot.
    fn callInto(w: *Fn, out: *Stmts, callee: Node.Index, extra: []const Node.Index, x: NameIndex, offset: u32, at: At, target: NameIndex) !void {
        const g = w.g;
        const path = try w.pathArgs(at);
        var args: std.ArrayList(Node.Index) = .empty;
        try args.appendSlice(g.l.scratch, &.{ try g.id(w.c), try w.depth(offset), path[0], path[1], path[2], try g.id(x) });
        try args.appendSlice(g.l.scratch, extra);
        try g.assign(out, target, try g.call(callee, args.items));
    }

    /// The node's worker, or the referenced definition's, or the slot, with
    /// the arguments it takes after the value.
    fn calleeOf(w: *Fn, n: PNode) !struct { Node.Index, []const Node.Index } {
        const g = w.g;
        const plan = g.plan;
        switch (SchemaGraph.tag(plan, n)) {
            .parameter => {
                const i = SchemaGraph.lhs(plan, n);
                if (i >= w.slots.len) return .{ try g.lit(.undefined_lit), &.{} };
                return .{ try g.id(w.slots[i]), &.{} };
            },
            .reference => {
                const t = g.sg.target(g.ref.module, @fromBackingInt(@intCast(SchemaGraph.lhs(plan, n)))) orelse return .{ try g.lit(.undefined_lit), &.{} };
                const callee = try g.id(try schemaName(g.l, t, w.op.workerSuffix()));
                var args: std.ArrayList(Node.Index) = .empty;
                for (SchemaGraph.args(plan, n)) |a| try args.append(g.l.scratch, try w.slotFor(@fromBackingInt(@intCast(a))));
                return .{ callee, args.items };
            },
            // A derived codec's (schema.md §12.10): another definition's
            // worker, as a declaration's reference calls one.
            .codec_ref => {
                const t = g.sg.codecTarget(g.ref.module, SchemaGraph.lhs(plan, n));
                const callee = try g.id(try schemaName(g.l, t, w.op.workerSuffix()));
                var args: std.ArrayList(Node.Index) = .empty;
                for (SchemaGraph.args(plan, n)) |a| try args.append(g.l.scratch, try w.slotFor(@fromBackingInt(@intCast(a))));
                return .{ callee, args.items };
            },
            // A module's `codec`, through its own workers, as a schema
            // argument runs (`readSlot` …).
            .codec_value => {
                const slot = try g.call(try g.core(w.op.slot()), &.{try g.codecValue(n)});
                return .{ slot, &.{} };
            },
            else => {
                var args: std.ArrayList(Node.Index) = .empty;
                for (w.slots) |s| try args.append(g.l.scratch, try g.id(s));
                return .{ try g.id(try g.nodeWorkerName(w.op, n)), args.items };
            },
        }
    }

    /// The worker a generic reference passes for argument node `n`: this
    /// definition's slot, a referenced definition's worker, or the node's
    /// own, closed over this definition's slots when it has any.
    fn slotFor(w: *Fn, n: PNode) !Node.Index {
        const g = w.g;
        const plan = g.plan;
        switch (SchemaGraph.tag(plan, n)) {
            .parameter => {
                const i = SchemaGraph.lhs(plan, n);
                return if (i < w.slots.len) g.id(w.slots[i]) else g.lit(.undefined_lit);
            },
            .reference => if (SchemaGraph.args(plan, n).len == 0) {
                const t = g.sg.target(g.ref.module, @fromBackingInt(@intCast(SchemaGraph.lhs(plan, n)))) orelse return g.lit(.undefined_lit);
                return g.id(try schemaName(g.l, t, w.op.workerSuffix()));
            },
            .codec_ref => if (SchemaGraph.args(plan, n).len == 0) {
                return g.id(try schemaName(g.l, g.sg.codecTarget(g.ref.module, SchemaGraph.lhs(plan, n)), w.op.workerSuffix()));
            },
            .codec_value => return g.call(try g.core(w.op.slot()), &.{try g.codecValue(n)}),
            else => {},
        }
        const worker = try g.id(try g.nodeWorkerName(w.op, n));
        if (w.slots.len == 0) return worker;
        const ps = try g.freshParams();
        var args: std.ArrayList(Node.Index) = .empty;
        for (ps.list()) |p| try args.append(g.l.scratch, try g.id(p));
        for (w.slots) |s| try args.append(g.l.scratch, try g.id(s));
        return g.arrowOf(&ps.list(), try g.call(worker, args.items));
    }

    // ---- A host input (`parse`, `read`) -----------------------------------------

    /// `prim` on a host input, whose output is typed.
    fn readPrimitive(w: *Fn, out: *Stmts, kind: u32, x: NameIndex, at: At, target: NameIndex) !void {
        const g = w.g;
        const typeof_x = try g.l.unary(.type_of, try g.id(x), g.p);
        switch (std.enums.fromInt(SchemaPlan.Primitive, kind) orelse .value) {
            .string => try w.checks(out, &.{.{ .cond = try g.bin(.strict_ne, typeof_x, try g.str("string")), .code = .wrong_shape, .message = "expected a string" }}, x, at, target, try g.id(x)),
            .bool => try w.checks(out, &.{.{ .cond = try g.bin(.strict_ne, typeof_x, try g.str("boolean")), .code = .wrong_shape, .message = "expected a boolean" }}, x, at, target, try g.id(x)),
            .int => try w.checks(out, &.{
                .{ .cond = try g.bin(.strict_ne, typeof_x, try g.str("number")), .code = .wrong_shape, .message = "expected a number" },
                .{ .cond = try g.not(try g.globalCall("Number", "isSafeInteger", &.{try g.id(x)})), .code = .invalid_value, .message = "expected a safe integer" },
            }, x, at, target, try g.id(x)),
            .float => try w.checks(out, &.{.{ .cond = try g.bin(.strict_ne, typeof_x, try g.str("number")), .code = .wrong_shape, .message = "expected a number" }}, x, at, target, try g.id(x)),
            .finite_float => try w.checks(out, &.{
                .{ .cond = try g.bin(.strict_ne, typeof_x, try g.str("number")), .code = .wrong_shape, .message = "expected a number" },
                .{ .cond = try g.not(try g.globalCall("Number", "isFinite", &.{try g.id(x)})), .code = .invalid_value, .message = "expected a finite number" },
            }, x, at, target, try g.id(x)),
            .null => try w.checks(out, &.{.{ .cond = try g.bin(.strict_ne, try g.id(x), try g.lit(.null_lit)), .code = .wrong_shape, .message = "expected null" }}, x, at, target, try g.coreCtor("Schema", "Null", &.{})),
            .value => try g.assign(out, target, try g.id(x)),
            // A derived codec's (schema.md §12.10), as `prim` reads them.
            .char => try w.checks(out, &.{
                .{ .cond = try g.bin(.strict_ne, typeof_x, try g.str("string")), .code = .wrong_shape, .message = "expected a string" },
                .{ .cond = try g.bin(.strict_ne, try g.prop(try g.globalCall("Array", "from", &.{try g.id(x)}), "length"), try g.num(1)), .code = .invalid_value, .message = "expected one character" },
            }, x, at, target, try g.id(x)),
            .int32 => try w.checks(out, &.{
                .{ .cond = try g.bin(.strict_ne, typeof_x, try g.str("number")), .code = .wrong_shape, .message = "expected a number" },
                .{ .cond = try g.bin(.strict_ne, try g.bin(.bit_or, try g.id(x), try g.num(0)), try g.id(x)), .code = .invalid_value, .message = "expected a 32-bit integer" },
            }, x, at, target, try g.id(x)),
            .never => try g.assign(out, target, try w.failText(at, .wrong_shape, "expected nothing: ⊥ has no value", try g.id(x), false)),
        }
    }

    const Check = struct { cond: Node.Index, code: Code, message: []const u8, written: bool = false };

    /// `if (c1) target = fail1; else if (c2) target = fail2; else target =
    /// ok;`: a primitive's tests in `prim`'s order.
    fn checks(w: *Fn, out: *Stmts, list: []const Check, x: NameIndex, at: At, target: NameIndex, ok: Node.Index) !void {
        const g = w.g;
        var tail: Stmts = .empty;
        try g.assign(&tail, target, ok);
        var i = list.len;
        while (i > 0) {
            i -= 1;
            var then: Stmts = .empty;
            try g.assign(&then, target, try w.failText(at, list[i].code, list[i].message, try g.id(x), list[i].written));
            var chained: Stmts = .empty;
            try g.ifElse(&chained, list[i].cond, then.items, tail.items);
            tail = chained;
        }
        try out.appendSlice(g.l.scratch, tail.items);
    }

    /// Whether node `n`, as a child, is read through a call or a conversion,
    /// which takes its parent's path on the success path.
    fn takesPath(plan: *const SchemaPlan, n: PNode) bool {
        return switch (SchemaGraph.tag(plan, n)) {
            .primitive => false,
            .nullable, .check, .annotation, .maybe => takesPath(plan, @fromBackingInt(@intCast(SchemaGraph.lhs(plan, n)))),
            else => true,
        };
    }

    /// `run` on a record node, standalone (`NRecord` on a host value).
    fn recordWorker(w: *Fn, out: *Stmts, n: PNode) !void {
        const g = w.g;
        if (w.op.hostIn()) {
            var then: Stmts = .empty;
            try g.ret(&then, try w.failText(w.ownAt(), .wrong_shape, "expected an object", try g.id(w.ps.v), false));
            try g.ifElse(out, try w.isObjectTest(try g.id(w.ps.v), try g.id(w.ps.v), try g.id(w.ps.v)), then.items, &.{});
        }
        var fields_take = false;
        for (SchemaGraph.fields(g.plan, n)) |f| fields_take = fields_take or takesPath(g.plan, f.child);
        if (fields_take) try w.hereFor(out);
        try w.recordBody(out, n, w.ps.v, 0, null);
    }

    /// The owner of a variant's payload: its discriminator, and the
    /// variant.
    const Owner = struct { discriminator: []const u8, variant: SchemaPlan.Variant, order: u32, info: Gen.Variants };

    fn recordBody(w: *Fn, out: *Stmts, n: PNode, v: NameIndex, offset: u32, owner: ?Owner) !void {
        if (w.op.hostIn()) {
            try w.decodeRecord(out, n, v, offset, owner);
        } else {
            try w.encodeRecord(out, n, v, offset, owner);
        }
    }

    /// Whether host object `v`'s key `key` is present by what a read of it
    /// answers: anything but `undefined`, wherever along its prototype
    /// chain it is (§5, *Host values*, amended 2026-10-17). Every runner
    /// that reads a host value — `parse`, `read` and its validator — tests a
    /// key so, but a name `Object.prototype` has, which is tested with
    /// `Object.hasOwn` so that the prototype never shadows a field; the one
    /// list of those names is `isPrototypeKey`'s.
    fn readsByValue(w: *const Fn, key: []const u8) bool {
        return w.op.hostIn() and !isPrototypeKey(key);
    }

    /// `recordOf` on a host object at depth `d + offset`: the unknown keys
    /// under `Reject`, then each field in declaration order, then the typed
    /// record — in its variant's constructor, for a payload.
    fn decodeRecord(w: *Fn, out: *Stmts, n: PNode, v: NameIndex, offset: u32, owner: ?Owner) !void {
        const g = w.g;
        const fields = SchemaGraph.fields(g.plan, n);
        const before = try g.fresh("$before");
        try g.constDecl(out, before, try w.issueCount());

        // `unknownKeys`: every own key no field claims, in the object's
        // own-key order; under `FirstError` the first ends the record.
        var claimed: std.ArrayList([]const u8) = .empty;
        if (owner) |o| try claimed.append(g.l.scratch, o.discriminator);
        for (fields) |f| try claimed.append(g.l.scratch, SchemaGraph.literal(g.plan, f.external));
        try w.unknownKeys(out, v, claimed.items, false);

        const deep = try g.fresh("$deep");
        if (fields.len != 0) try g.constDecl(out, deep, try w.deepTest(offset));
        const values = try g.l.scratch.alloc(NameIndex, fields.len);
        for (fields, values) |f, *slot| {
            const name = g.l.text(SchemaGraph.symbol(g.plan, f.name));
            const key = SchemaGraph.literal(g.plan, f.external);
            const at = w.childAt(.{ .text = key }, .{ .text = name });
            const value = try g.fresh("$f");
            slot.* = value;
            // A required primitive field of a JSON object, where the build
            // shares its failure branch (`SchemaShare`): the key read and
            // every test written here, as one condition, and one call that
            // makes the issue of the test that failed — absent, past the
            // depth bound, or not the primitive — made only when one did.
            if (SchemaShare.fieldCall(g.sg.share, g.plan, w.op, f, key)) |h| {
                const parent: [3]Node.Index = switch (at.parent) {
                    .own => .{ try g.id(w.ps.pp), try g.id(w.ps.pk), try g.id(w.ps.pn) },
                    .path => |here| .{ try g.id(here), try g.lit(.null_lit), try g.lit(.null_lit) },
                };
                const x = try g.fresh("$x");
                try g.letDecl(out, value);
                try g.constDecl(out, x, try g.indexOf(try g.id(v), try g.str(key)));
                const typeof_x = try g.l.unary(.type_of, try g.id(x), g.p);
                const wrong = switch (h) {
                    .string => try g.bin(.strict_ne, typeof_x, try g.str("string")),
                    .bool => try g.bin(.strict_ne, typeof_x, try g.str("boolean")),
                    .float => try g.bin(.strict_ne, typeof_x, try g.str("number")),
                    // `Number.isSafeInteger` and `Number.isFinite` answer
                    // false for anything that is not a number.
                    .int => try g.not(try g.globalCall("Number", "isSafeInteger", &.{try g.id(x)})),
                    .finite => try g.not(try g.globalCall("Number", "isFinite", &.{try g.id(x)})),
                    .deep, .missing => unreachable,
                };
                const absent_or_deep = try g.bin(.logical_or, try g.bin(.strict_eq, try g.id(x), try g.lit(.undefined_lit)), try g.id(deep));
                var bad: Stmts = .empty;
                try g.assign(&bad, value, try g.call(try g.core(h.coreName()), &.{
                    try g.id(w.c), parent[0],   parent[1],      parent[2],
                    try g.id(v),   try g.id(x), try g.str(key), try g.id(deep),
                }));
                var good: Stmts = .empty;
                try g.assign(&good, value, try g.id(x));
                try g.ifElse(out, try g.bin(.logical_or, absent_or_deep, wrong), bad.items, good.items);
                try w.stopOnFailure(out, value);
                continue;
            }
            try g.letDecl(out, value);
            // Present: read it one level down (`descend`). The own-key test
            // is `readsByValue`'s.
            const inherited = !w.readsByValue(key);
            var present: Stmts = .empty;
            const x = try g.fresh("$x");
            if (inherited) try g.constDecl(&present, x, try g.indexOf(try g.id(v), try g.str(key)));
            var too_deep: Stmts = .empty;
            try g.assign(&too_deep, value, try w.failText(at, .depth_exceeded, "the depth limit is reached", try g.id(x), false));
            var descend: Stmts = .empty;
            // A derived record's `Maybe` field (schema.md §12.4): its
            // `maybe` node's answer, and absent `Nothing`.
            const lenient = SchemaGraph.isMaybeField(g.plan, f);
            if (f.optional and !lenient) {
                const y = try g.fresh("$y");
                try g.letDecl(&descend, y);
                try w.into(&descend, f.child, x, offset + 1, at, y);
                const failed = try g.bin(.strict_eq, try g.id(y), try w.failMark());
                try g.assign(&descend, value, try g.l.condOf(failed, try w.failMark(), try g.coreCtor("Schema", "Present", &.{try g.id(y)}), g.p));
            } else {
                try w.into(&descend, f.child, x, offset + 1, at, value);
            }
            try g.ifElse(&present, try g.id(deep), too_deep.items, descend.items);
            // Absent: `Missing`, or the missing key.
            var absent: Stmts = .empty;
            if (lenient) {
                try g.assign(&absent, value, try g.coreCtor("Maybe", "Nothing", &.{}));
            } else if (f.optional) {
                try g.assign(&absent, value, try g.coreCtor("Schema", "Missing", &.{}));
            } else {
                const message = try std.fmt.allocPrint(g.l.scratch, "missing key \"{s}\"", .{key});
                try g.assign(&absent, value, try w.failText(at, .missing_key, message, try g.id(v), false));
            }
            if (inherited) {
                try g.ifElse(out, try g.globalCall("Object", "hasOwn", &.{ try g.id(v), try g.str(key) }), present.items, absent.items);
            } else {
                try g.constDecl(out, x, try g.indexOf(try g.id(v), try g.str(key)));
                try g.ifElse(out, try g.bin(.strict_ne, try g.id(x), try g.lit(.undefined_lit)), present.items, absent.items);
            }
            try w.stopOnFailure(out, value);
        }
        try w.failIfGrew(out, before);
        const names = try g.l.scratch.alloc(Symbol, fields.len);
        const exprs = try g.l.scratch.alloc(Node.Index, fields.len);
        for (fields, names, exprs, values) |f, *name, *expr, value| {
            name.* = SchemaGraph.symbol(g.plan, f.name);
            expr.* = try g.id(value);
        }
        const built = try g.recordValue(names, exprs);
        try g.ret(out, if (owner) |o| try g.variantValue(o.info, o.order, SchemaGraph.symbol(g.plan, o.variant.name), built) else built);
    }

    /// `unknownKeys` under `Reject`: each own key of `v` not in `claimed`
    /// is an issue at its own path. `wholeFails`: a nullary variant fails on
    /// any (`nullaryOf`), where a record goes on to its fields under
    /// `AllErrors`.
    fn unknownKeys(w: *Fn, out: *Stmts, v: NameIndex, claimed: []const []const u8, whole_fails: bool) !void {
        const g = w.g;
        const key = try g.fresh("$key");
        var test_expr: ?Node.Index = null;
        for (claimed) |c| {
            const differs = try g.bin(.strict_ne, try g.id(key), try g.str(c));
            test_expr = if (test_expr) |t| try g.bin(.logical_and, t, differs) else differs;
        }
        const found = try g.fresh("$found");
        var report: Stmts = .empty;
        const message = try g.concat(&.{ .{ .text = "unexpected key \"" }, .{ .value = try g.id(key) }, .{ .text = "\"" } });
        try g.exprStmt(&report, try w.fail(w.childAt(.{ .name = key }, .{ .name = key }), .unknown_key, message, try g.indexOf(try g.id(v), try g.id(key)), false));
        if (whole_fails) {
            try g.assign(&report, found, try g.lit(.true_lit));
            var stop: Stmts = .empty;
            try g.breakStmt(&stop);
            try g.ifElse(&report, try g.not(try g.ctxField(w.c, "all")), stop.items, &.{});
        } else {
            var stop: Stmts = .empty;
            try g.ret(&stop, try w.failMark());
            try g.ifElse(&report, try g.not(try g.ctxField(w.c, "all")), stop.items, &.{});
        }
        var loop_body: Stmts = .empty;
        if (test_expr) |t| try g.ifElse(&loop_body, t, report.items, &.{}) else try loop_body.appendSlice(g.l.scratch, report.items);
        var reject: Stmts = .empty;
        if (whole_fails) {
            const decl = try g.l.add(.let_decl, g.p, @backingInt(found), @backingInt((try g.lit(.false_lit)).toOptional()));
            try reject.append(g.l.scratch, decl);
        }
        try g.forOf(&reject, key, try g.globalCall("Object", "keys", &.{try g.id(v)}), loop_body.items);
        if (whole_fails) {
            var stop: Stmts = .empty;
            try g.ret(&stop, try w.failMark());
            try g.ifElse(&reject, try g.id(found), stop.items, &.{});
        }
        try g.ifElse(out, try g.ctxField(w.c, "reject"), reject.items, &.{});
    }

    /// `listOf`: each element one level down, the output a fresh array —
    /// or, under `parse`, for a list of a primitive with no conversion, the
    /// array `JSON.parse` made itself (§6, *Lists are arrays*). An array
    /// `read` was handed is never adopted: the host may still write it.
    fn listWorker(w: *Fn, out: *Stmts, n: PNode) !void {
        if (w.op.hostIn()) {
            try w.decodeList(out, n);
        } else {
            try w.encodeList(out, n);
        }
    }

    fn decodeList(w: *Fn, out: *Stmts, n: PNode) !void {
        const g = w.g;
        const child: PNode = @fromBackingInt(@intCast(SchemaGraph.lhs(g.plan, n)));
        const v = w.ps.v;
        var then: Stmts = .empty;
        try g.ret(&then, try w.failText(w.ownAt(), .wrong_shape, "expected an array", try g.id(v), false));
        try g.ifElse(out, try g.not(try g.globalCall("Array", "isArray", &.{try g.id(v)})), then.items, &.{});
        if (takesPath(g.plan, child)) try w.hereFor(out);
        const adopt = w.op.json() and adoptable(g.plan, child);
        const before = try g.fresh("$before");
        try g.constDecl(out, before, try w.issueCount());
        const len = try g.fresh("$len");
        try g.constDecl(out, len, try g.prop(try g.id(v), "length"));
        const deep = try g.fresh("$deep");
        try g.constDecl(out, deep, try w.deepTest(0));
        const result = try g.fresh("$out");
        if (!adopt) try g.constDecl(out, result, try g.l.arrayNode(&.{}, g.p));
        const i = try g.fresh("$i");
        try out.append(g.l.scratch, try g.l.add(.let_decl, g.p, @backingInt(i), @backingInt((try g.num(0)).toOptional())));

        var body: Stmts = .empty;
        var stop: Stmts = .empty;
        try g.breakStmt(&stop);
        try g.ifElse(&body, try g.bin(.ge, try g.id(i), try g.id(len)), stop.items, &.{});
        const x = try g.fresh("$x");
        try g.constDecl(&body, x, try g.indexOf(try g.id(v), try g.id(i)));
        const y = try g.fresh("$y");
        try g.letDecl(&body, y);
        const at = w.childAt(.{ .name = i }, .{ .name = i });
        var too_deep: Stmts = .empty;
        try g.assign(&too_deep, y, try w.failText(at, .depth_exceeded, "the depth limit is reached", try g.id(x), false));
        var descend: Stmts = .empty;
        try w.into(&descend, child, x, 1, at, y);
        try g.ifElse(&body, try g.id(deep), too_deep.items, descend.items);
        // `listItems`: a failure stops the list under `FirstError`.
        var failed: Stmts = .empty;
        var give_up: Stmts = .empty;
        try g.ret(&give_up, try w.failMark());
        try g.ifElse(&failed, try g.not(try g.ctxField(w.c, "all")), give_up.items, &.{});
        var ok: Stmts = .empty;
        if (!adopt) try g.exprStmt(&ok, try g.call(try g.prop(try g.id(result), "push"), &.{try g.id(y)}));
        try g.ifElse(&body, try g.bin(.strict_eq, try g.id(y), try w.failMark()), failed.items, ok.items);
        try g.assign(&body, i, try g.bin(.add, try g.id(i), try g.num(1)));
        try g.whileTrue(out, body.items);
        try w.failIfGrew(out, before);
        try g.ret(out, try g.id(if (adopt) v else result));
    }

    /// `run` on a tagged node: the discriminator, then the selected
    /// variant's payload (`variantOf`, `nullaryOf`).
    fn taggedWorker(w: *Fn, out: *Stmts, n: PNode) !void {
        if (w.op.hostIn()) {
            try w.decodeTagged(out, n);
        } else {
            try w.encodeTagged(out, n);
        }
    }

    fn decodeTagged(w: *Fn, out: *Stmts, n: PNode) !void {
        const g = w.g;
        const plan = g.plan;
        const v = w.ps.v;
        const discriminator = SchemaGraph.literal(plan, @fromBackingInt(@intCast(SchemaGraph.lhs(plan, n))));
        const info = g.variantsOf(n);
        var then: Stmts = .empty;
        try g.ret(&then, try w.failText(w.ownAt(), .wrong_shape, "expected an object", try g.id(v), false));
        try g.ifElse(out, try w.isObjectTest(try g.id(v), try g.id(v), try g.id(v)), then.items, &.{});
        // The payloads' fields read through a call or a conversion take the
        // union's own path as their parent.
        var takes = false;
        for (SchemaGraph.variants(plan, n)) |vi| {
            if (vi >= plan.variants.len) continue;
            const payload = plan.variants[vi].payload.unwrap() orelse continue;
            for (SchemaGraph.fields(plan, payload)) |f| takes = takes or takesPath(plan, f.child);
        }
        if (takes) try w.hereFor(out);
        const at_disc = w.childAt(.{ .text = discriminator }, .{ .text = discriminator });
        var missing: Stmts = .empty;
        const missing_message = try std.fmt.allocPrint(g.l.scratch, "missing key \"{s}\"", .{discriminator});
        try g.ret(&missing, try w.failText(at_disc, .missing_key, missing_message, try g.id(v), false));
        // The own-key test as `decodeRecord` makes it.
        const tag = try g.fresh("$tag");
        if (!w.readsByValue(discriminator)) {
            try g.ifElse(out, try g.not(try g.globalCall("Object", "hasOwn", &.{ try g.id(v), try g.str(discriminator) })), missing.items, &.{});
            try g.constDecl(out, tag, try g.indexOf(try g.id(v), try g.str(discriminator)));
        } else {
            try g.constDecl(out, tag, try g.indexOf(try g.id(v), try g.str(discriminator)));
            try g.ifElse(out, try g.bin(.strict_eq, try g.id(tag), try g.lit(.undefined_lit)), missing.items, &.{});
        }

        var cases: std.ArrayList(Node.Index) = .empty;
        var expected: std.ArrayList(u8) = .empty;
        try expected.appendSlice(g.l.scratch, "unknown tag; expected ");
        for (SchemaGraph.variants(plan, n), 0..) |vi, order| {
            if (vi >= plan.variants.len) continue;
            const variant = plan.variants[vi];
            const tag_text = SchemaGraph.literal(plan, variant.external);
            try expected.print(g.l.scratch, "{s}\"{s}\"", .{ if (order == 0) "" else ", ", tag_text });
            var arm: Stmts = .empty;
            const owner: Owner = .{ .discriminator = discriminator, .variant = variant, .order = @intCast(order), .info = info };
            if (variant.payload.unwrap()) |payload| {
                var stop: Stmts = .empty;
                try g.ret(&stop, try w.failText(w.ownAt(), .depth_exceeded, "the depth limit is reached", try g.id(v), false));
                try g.ifElse(&arm, try w.deepTest(0), stop.items, &.{});
                try w.decodeRecord(&arm, payload, v, 1, owner);
            } else {
                try w.unknownKeys(&arm, v, &.{discriminator}, true);
                try g.ret(&arm, try g.variantValue(info, @intCast(order), SchemaGraph.symbol(plan, variant.name), null));
            }
            try cases.append(g.l.scratch, try w.switchCase(try g.str(tag_text), arm.items));
        }
        var fallback: Stmts = .empty;
        try g.ret(&fallback, try w.failText(at_disc, .unknown_tag, expected.items, try g.id(tag), false));
        try cases.append(g.l.scratch, try w.switchCase(null, fallback.items));
        try w.switchOn(out, try g.id(tag), cases.items);
    }

    fn switchCase(w: *Fn, test_expr: ?Node.Index, body: []const Node.Index) !Node.Index {
        const g = w.g;
        // A case's body is a block of its own: two arms may declare one name.
        const block_range = try g.l.b.addRange(body);
        const block_record = try g.l.b.addRecord(block_range);
        const block = try g.l.add(.block_stmt, g.p, @backingInt(NameIndex.none), @backingInt(block_record));
        const range = try g.l.b.addRange(&.{block});
        const record = try g.l.b.addRecord(range);
        const t: Node.OptionalIndex = if (test_expr) |e| e.toOptional() else .none;
        return g.l.add(.switch_case, g.p, @backingInt(t), @backingInt(record));
    }

    fn switchOn(w: *Fn, out: *Stmts, discriminant: Node.Index, cases: []const Node.Index) !void {
        const g = w.g;
        const range = try g.l.b.addRange(cases);
        const record = try g.l.b.addRecord(range);
        try out.append(g.l.scratch, try g.l.add(.switch_stmt, g.p, discriminant.int(), @backingInt(record)));
    }

    // ---- A typed input (`print`, `write`, `decode`, `encode`) ---------------

    /// `prim` on a typed input: the type has already proved the shape, so
    /// only the refinements are tested — a safe integer, a finite number,
    /// and for `print` a number JSON can hold and a `Value` within the
    /// bound (`prim`'s `c.json && c.dh`). `Null` is written `null` to a
    /// host output and stays `Null` in a typed one.
    fn typedPrimitive(w: *Fn, out: *Stmts, kind: u32, x: NameIndex, offset: u32, at: At, target: NameIndex) !void {
        const g = w.g;
        const json_out = w.op.json() and w.op.hostOut();
        switch (std.enums.fromInt(SchemaPlan.Primitive, kind) orelse .value) {
            .string, .bool => try g.assign(out, target, try g.id(x)),
            .int => try w.checks(out, &.{.{ .cond = try g.not(try g.globalCall("Number", "isSafeInteger", &.{try g.id(x)})), .code = .invalid_value, .message = "expected a safe integer" }}, x, at, target, try g.id(x)),
            .float => if (json_out)
                try w.checks(out, &.{.{ .cond = try g.not(try g.globalCall("Number", "isFinite", &.{try g.id(x)})), .code = .print_failed, .message = "JSON has no number for NaN or an infinity", .written = true }}, x, at, target, try g.id(x))
            else
                try g.assign(out, target, try g.id(x)),
            .finite_float => try w.checks(out, &.{.{ .cond = try g.not(try g.globalCall("Number", "isFinite", &.{try g.id(x)})), .code = .invalid_value, .message = "expected a finite number" }}, x, at, target, try g.id(x)),
            .null => try g.assign(out, target, if (w.op.hostOut()) try g.lit(.null_lit) else try g.coreCtor("Schema", "Null", &.{})),
            .value => if (json_out) {
                const r = try g.fresh("$printable");
                try g.constDecl(out, r, try g.call(try g.core("printableWithin"), &.{ try g.id(w.c), try w.depth(offset), try g.id(x) }));
                try w.checks(out, &.{
                    .{ .cond = try g.bin(.strict_eq, try g.id(r), try g.num(1)), .code = .depth_exceeded, .message = "the value nests deeper than the depth limit", .written = true },
                    .{ .cond = try g.bin(.strict_eq, try g.id(r), try g.num(2)), .code = .print_failed, .message = "the value holds NaN or an infinity, which JSON has no number for", .written = true },
                }, x, at, target, try g.id(x));
            } else try g.assign(out, target, try g.id(x)),
            // A well-typed `Char` is one character and an `Int32` a 32-bit
            // integer, so `prim`'s tests always hold.
            .char, .int32 => try g.assign(out, target, try g.id(x)),
            .never => try g.assign(out, target, try w.failText(at, .wrong_shape, "expected nothing: ⊥ has no value", try g.id(x), false)),
        }
    }

    /// `recordOf` on a typed record at depth `d + offset`: each field in
    /// declaration order, then the output — a host object, keys in field
    /// order, a variant's discriminator first (`newObject`), a `Missing`
    /// field left out; or a typed record, in its variant's constructor for
    /// a payload.
    fn encodeRecord(w: *Fn, out: *Stmts, n: PNode, v: NameIndex, offset: u32, owner: ?Owner) !void {
        const g = w.g;
        const fields = SchemaGraph.fields(g.plan, n);
        const before = try g.fresh("$before");
        try g.constDecl(out, before, try w.issueCount());
        const deep = try g.fresh("$deep");
        if (fields.len != 0) try g.constDecl(out, deep, try w.deepTest(offset));
        const values = try g.l.scratch.alloc(NameIndex, fields.len);
        for (fields, values) |f, *slot| {
            const name_sym = SchemaGraph.symbol(g.plan, f.name);
            const name = g.l.text(name_sym);
            const key = SchemaGraph.literal(g.plan, f.external);
            // The input names a field by its name when it is the Type
            // endpoint and by its key when it is the Encoded (`fieldsFrom`).
            const at = if (w.op.decoding()) w.childAt(.{ .text = key }, .{ .text = name }) else w.childAt(.{ .text = name }, .{ .text = key });
            const s = try g.fresh("$s");
            slot.* = s;
            try g.letDecl(out, s);
            const x = try g.fresh("$x");
            try g.constDecl(out, x, try g.field(try g.id(v), name_sym));
            if (SchemaGraph.isMaybeField(g.plan, f)) {
                // A derived `Maybe` field, whose Encoded end is a host
                // value: `Nothing` writes nothing, `Just` what its `maybe`
                // node writes (schema.md §12.4).
                var nothing: Stmts = .empty;
                try g.assign(&nothing, s, try g.lit(.undefined_lit));
                var just: Stmts = .empty;
                try w.encodeField(&just, f.child, x, offset, at, s, deep);
                try g.ifElse(out, try g.coreCtorTest("Maybe", "Nothing", try g.id(x)), nothing.items, just.items);
            } else if (f.optional) {
                // `Missing` writes nothing to a host output and stays
                // `Missing` in a typed one; `Present a` writes `a`, or
                // `Present` of it.
                var missing: Stmts = .empty;
                try g.assign(&missing, s, if (w.op.hostOut()) try g.lit(.undefined_lit) else try g.id(x));
                var present: Stmts = .empty;
                const a = try g.fresh("$a");
                try g.constDecl(&present, a, try g.l.member(try g.id(x), try g.l.slotName(0), g.p));
                if (w.op.hostOut()) {
                    try w.encodeField(&present, f.child, a, offset, at, s, deep);
                } else {
                    const y = try g.fresh("$y");
                    try g.letDecl(&present, y);
                    try w.encodeField(&present, f.child, a, offset, at, y, deep);
                    const failed = try g.bin(.strict_eq, try g.id(y), try w.failMark());
                    try g.assign(&present, s, try g.l.condOf(failed, try w.failMark(), try g.coreCtor("Schema", "Present", &.{try g.id(y)}), g.p));
                }
                try g.ifElse(out, try g.coreCtorTest("Schema", "Missing", try g.id(x)), missing.items, present.items);
            } else {
                try w.encodeField(out, f.child, x, offset, at, s, deep);
            }
            try w.stopOnFailure(out, s);
        }
        try w.failIfGrew(out, before);
        if (!w.op.hostOut()) {
            // The typed record, in canonical key order (`made`).
            const names = try g.l.scratch.alloc(Symbol, fields.len);
            const exprs = try g.l.scratch.alloc(Node.Index, fields.len);
            for (fields, names, exprs, values) |f, *name, *expr, value| {
                name.* = SchemaGraph.symbol(g.plan, f.name);
                expr.* = try g.id(value);
            }
            const built = try g.recordValue(names, exprs);
            try g.ret(out, if (owner) |o| try g.variantValue(o.info, o.order, SchemaGraph.symbol(g.plan, o.variant.name), built) else built);
            return;
        }
        const object = try w.newObject(out);
        if (owner) |o| try w.setKey(out, object, o.discriminator, try g.str(SchemaGraph.literal(g.plan, o.variant.external)), null);
        for (fields, values) |f, s| try w.setKey(out, object, SchemaGraph.literal(g.plan, f.external), try g.id(s), if (f.optional) s else null);
        try g.ret(out, try g.id(object));
    }

    /// `const o = …`, the host object a host output writes a record into:
    /// `{}` for `print`, whose object only `JSON.stringify` reads, and
    /// `Object.create(null)` for `write`, whose object the program gets —
    /// §5's *Host values*, built with no prototype (`newObject`).
    fn newObject(w: *Fn, out: *Stmts) !NameIndex {
        const g = w.g;
        const object = try g.fresh("$o");
        const value = if (w.op.json())
            try g.l.object(&.{}, g.p)
        else
            try g.globalCall("Object", "create", &.{try g.lit(.null_lit)});
        try g.constDecl(out, object, value);
        return object;
    }

    /// `o[key] = value`, a key the object then owns; under `present`, only
    /// when that name does not hold `undefined` (a `Missing` field).
    /// On `print`'s `{}`, `__proto__` is defined rather than assigned:
    /// assigning it would set the prototype (§5, *Host values*). `write`'s
    /// object has no prototype, so there it is an ordinary key.
    fn setKey(w: *Fn, out: *Stmts, object: NameIndex, key: []const u8, value: Node.Index, present: ?NameIndex) !void {
        const g = w.g;
        var write: Stmts = .empty;
        if (w.op.json() and std.mem.eql(u8, key, "__proto__")) {
            const descriptor = try g.l.object(&.{
                try g.l.property(try g.sym("value"), value, g.p),
                try g.l.property(try g.sym("enumerable"), try g.lit(.true_lit), g.p),
                try g.l.property(try g.sym("writable"), try g.lit(.true_lit), g.p),
                try g.l.property(try g.sym("configurable"), try g.lit(.true_lit), g.p),
            }, g.p);
            try g.exprStmt(&write, try g.globalCall("Object", "defineProperty", &.{ try g.id(object), try g.str(key), descriptor }));
        } else {
            const target = try g.indexOf(try g.id(object), try g.str(key));
            try write.append(g.l.scratch, try g.l.add(.assign_stmt, g.p, target.int(), value.int()));
        }
        if (present) |s| {
            try g.ifElse(out, try g.bin(.strict_ne, try g.id(s), try g.lit(.undefined_lit)), write.items, &.{});
        } else {
            try out.appendSlice(g.l.scratch, write.items);
        }
    }

    /// `descend`: the depth bound, then the child one level down.
    fn encodeField(w: *Fn, out: *Stmts, child: PNode, x: NameIndex, offset: u32, at: At, target: NameIndex, deep: NameIndex) !void {
        const g = w.g;
        var too_deep: Stmts = .empty;
        try g.assign(&too_deep, target, try w.failText(at, .depth_exceeded, "the depth limit is reached", try g.id(x), false));
        var descend: Stmts = .empty;
        try w.into(&descend, child, x, offset + 1, at, target);
        try g.ifElse(out, try g.id(deep), too_deep.items, descend.items);
    }

    /// `listOf` on a `List`: its elements read through the protocol every
    /// reader outside `core/List` uses, each one level down, into a fresh
    /// array.
    fn encodeList(w: *Fn, out: *Stmts, n: PNode) !void {
        const g = w.g;
        const child: PNode = @fromBackingInt(@intCast(SchemaGraph.lhs(g.plan, n)));
        const v = w.ps.v;
        if (takesPath(g.plan, child)) try w.hereFor(out);
        // `plain`: a list's elements as a plain array.
        const xs = try g.fresh("$xs");
        try g.constDecl(out, xs, try g.l.condOf(
            try g.globalCall("Array", "isArray", &.{try g.id(v)}),
            try g.id(v),
            try g.call(try g.prop(try g.id(v), "$plain"), &.{}),
            g.p,
        ));
        const before = try g.fresh("$before");
        try g.constDecl(out, before, try w.issueCount());
        const len = try g.fresh("$len");
        try g.constDecl(out, len, try g.prop(try g.id(xs), "length"));
        const deep = try g.fresh("$deep");
        try g.constDecl(out, deep, try w.deepTest(0));
        const result = try g.fresh("$out");
        try g.constDecl(out, result, try g.l.arrayNode(&.{}, g.p));
        const i = try g.fresh("$i");
        try out.append(g.l.scratch, try g.l.add(.let_decl, g.p, @backingInt(i), @backingInt((try g.num(0)).toOptional())));

        var body: Stmts = .empty;
        var stop: Stmts = .empty;
        try g.breakStmt(&stop);
        try g.ifElse(&body, try g.bin(.ge, try g.id(i), try g.id(len)), stop.items, &.{});
        const x = try g.fresh("$x");
        try g.constDecl(&body, x, try g.indexOf(try g.id(xs), try g.id(i)));
        const y = try g.fresh("$y");
        try g.letDecl(&body, y);
        const at = w.childAt(.{ .name = i }, .{ .name = i });
        var too_deep: Stmts = .empty;
        try g.assign(&too_deep, y, try w.failText(at, .depth_exceeded, "the depth limit is reached", try g.id(x), false));
        var descend: Stmts = .empty;
        try w.into(&descend, child, x, 1, at, y);
        try g.ifElse(&body, try g.id(deep), too_deep.items, descend.items);
        var failed: Stmts = .empty;
        var give_up: Stmts = .empty;
        try g.ret(&give_up, try w.failMark());
        try g.ifElse(&failed, try g.not(try g.ctxField(w.c, "all")), give_up.items, &.{});
        var ok: Stmts = .empty;
        try g.exprStmt(&ok, try g.call(try g.prop(try g.id(result), "push"), &.{try g.id(y)}));
        try g.ifElse(&body, try g.bin(.strict_eq, try g.id(y), try w.failMark()), failed.items, ok.items);
        try g.assign(&body, i, try g.bin(.add, try g.id(i), try g.num(1)));
        try g.whileTrue(out, body.items);
        try w.failIfGrew(out, before);
        try g.ret(out, try g.id(result));
    }

    /// `run` on a tagged Type value: a `switch` over its constructor, the
    /// selected payload one level down (`variantOf`, `nullaryOf`).
    fn encodeTagged(w: *Fn, out: *Stmts, n: PNode) !void {
        const g = w.g;
        const plan = g.plan;
        const v = w.ps.v;
        const discriminator = SchemaGraph.literal(plan, @fromBackingInt(@intCast(SchemaGraph.lhs(plan, n))));
        const info = g.variantsOf(n);
        var takes = false;
        for (SchemaGraph.variants(plan, n)) |vi| {
            if (vi >= plan.variants.len) continue;
            const payload = plan.variants[vi].payload.unwrap() orelse continue;
            for (SchemaGraph.fields(plan, payload)) |f| takes = takes or takesPath(plan, f.child);
        }
        if (takes) try w.hereFor(out);
        var cases: std.ArrayList(Node.Index) = .empty;
        const all = SchemaGraph.variants(plan, n);
        for (all, 0..) |vi, order| {
            if (vi >= plan.variants.len) continue;
            const variant = plan.variants[vi];
            const name = SchemaGraph.symbol(plan, variant.name);
            var arm: Stmts = .empty;
            const owner: Owner = .{ .discriminator = discriminator, .variant = variant, .order = @intCast(order), .info = info };
            if (variant.payload.unwrap()) |payload| {
                const a = try g.fresh("$a");
                try g.constDecl(&arm, a, try g.l.member(try g.id(v), try g.l.slotName(0), g.p));
                var stop: Stmts = .empty;
                try g.ret(&stop, try w.failText(w.ownAt(), .depth_exceeded, "the depth limit is reached", try g.id(a), false));
                try g.ifElse(&arm, try w.deepTest(0), stop.items, &.{});
                try w.encodeRecord(&arm, payload, a, 1, owner);
            } else if (w.op.hostOut()) {
                const object = try w.newObject(&arm);
                try w.setKey(&arm, object, discriminator, try g.str(SchemaGraph.literal(plan, variant.external)), null);
                try g.ret(&arm, try g.id(object));
            } else {
                // `nullaryOf` to a typed output: the variant's constructor.
                try g.ret(&arm, try g.variantValue(info, @intCast(order), name, null));
            }
            // The last variant is the `default`: a well-typed value is one
            // of them.
            const label: ?Node.Index = if (order + 1 == all.len) null else try g.str(g.l.text(name));
            try cases.append(g.l.scratch, try w.switchCase(label, arm.items));
        }
        const discriminant = if (info.padded) try g.l.member(try g.id(v), g.l.well.tag, g.p) else try g.id(v);
        try w.switchOn(out, discriminant, cases.items);
    }

    // ---- A derived codec's (schema.md §12.10) ---------------------------
    // Only a derived codec's definitions hold these nodes, and a derived
    // codec runs `parse`, `print`, `read` and `write` only (its `decode` and
    // `encode` are `read` and `write`, `SchemaGraph.hostAliased`): decoding
    // reads a host value, and encoding writes one.

    /// `NTuple` (`tupleOf`): an array of exactly its elements outside, each
    /// one level down at its index, and the tuple inside.
    fn tupleWorker(w: *Fn, out: *Stmts, n: PNode) !void {
        const g = w.g;
        const elems = SchemaGraph.elements(g.plan, n);
        const v = w.ps.v;
        const decoding = w.op.decoding();
        if (decoding) {
            var then: Stmts = .empty;
            try g.ret(&then, try w.failText(w.ownAt(), .wrong_shape, try elementsMessage(g, elems.len), try g.id(v), false));
            const not_array = try g.not(try g.globalCall("Array", "isArray", &.{try g.id(v)}));
            const wrong_length = try g.bin(.strict_ne, try g.prop(try g.id(v), "length"), try g.num(@intCast(elems.len)));
            try g.ifElse(out, try g.bin(.logical_or, not_array, wrong_length), then.items, &.{});
        }
        var takes = false;
        for (elems) |e| takes = takes or takesPath(g.plan, @fromBackingInt(@intCast(e)));
        if (takes) try w.hereFor(out);
        const items = try g.l.scratch.alloc(Node.Index, elems.len);
        for (0..elems.len) |i| items[i] = if (decoding)
            try g.indexOf(try g.id(v), try g.num(@intCast(i)))
        else
            try g.l.member(try g.id(v), try g.l.slotName(@intCast(i)), g.p);
        const values = try w.elementsInto(out, elems, items, w.childParent(), 0);
        try w.failIfGrew(out, values.before);
        var ids: std.ArrayList(Node.Index) = .empty;
        for (values.names) |name| try ids.append(g.l.scratch, try g.id(name));
        try g.ret(out, if (decoding) try g.tupleValue(ids.items) else try g.l.arrayNode(ids.items, g.p));
    }

    /// The parent a child of this worker's own value is read under: the
    /// worker's own path once made (`hereFor`).
    fn childParent(w: *const Fn) At.Parent {
        return if (w.here) |h| .{ .path = h } else .own;
    }

    const Elements = struct { names: []const NameIndex, before: NameIndex };

    /// `elementsFrom`: element `i` of `items` by node `nodes[i]`, at
    /// `Index i` below `parent`, one level down from `d + offset`; under
    /// `FirstError` the first failure ends the worker.
    fn elementsInto(w: *Fn, out: *Stmts, nodes: []const u32, items: []const Node.Index, parent: At.Parent, offset: u32) !Elements {
        const g = w.g;
        const before = try g.fresh("$before");
        try g.constDecl(out, before, try w.issueCount());
        const deep = try g.fresh("$deep");
        if (nodes.len != 0) try g.constDecl(out, deep, try w.deepTest(offset));
        const names = try g.l.scratch.alloc(NameIndex, nodes.len);
        for (nodes, items, names, 0..) |node, item, *name, i| {
            const at: At = .{ .parent = parent, .k = .{ .index = @intCast(i) }, .n = .{ .index = @intCast(i) } };
            const x = try g.fresh("$x");
            try g.constDecl(out, x, item);
            const y = try g.fresh("$e");
            name.* = y;
            try g.letDecl(out, y);
            var too_deep: Stmts = .empty;
            try g.assign(&too_deep, y, try w.failText(at, .depth_exceeded, depth_message, try g.id(x), false));
            var descend: Stmts = .empty;
            try w.into(&descend, @fromBackingInt(@intCast(node)), x, offset + 1, at, y);
            try g.ifElse(out, try g.id(deep), too_deep.items, descend.items);
            try w.stopOnFailure(out, y);
        }
        return .{ .names = names, .before = before };
    }

    /// `NCtors`: a custom type's constructors in Roc's form (§12.3) — a
    /// nullary one's name, or an object whose one key names one that takes
    /// arguments, its argument or an array of its arguments below.
    fn ctorsWorker(w: *Fn, out: *Stmts, n: PNode) !void {
        if (w.op.decoding()) {
            try w.decodeCtors(out, n);
        } else {
            try w.encodeCtors(out, n);
        }
    }

    fn decodeCtors(w: *Fn, out: *Stmts, n: PNode) !void {
        const g = w.g;
        const plan = g.plan;
        const v = w.ps.v;
        const all = SchemaGraph.ctors(plan, n);
        // The names, quoted, for `UnknownTag` (`unknownCtor`).
        var expected: std.ArrayList(u8) = .empty;
        for (all, 0..) |c, i| try expected.print(g.l.scratch, "{s}\"{s}\"", .{ if (i == 0) "" else ", ", g.l.text(SchemaGraph.symbol(plan, plan.codec_ctors[c].name)) });
        var takes = false;
        for (all) |c| for (SchemaGraph.ctorArgs(plan, c)) |a| {
            takes = takes or takesPath(plan, @fromBackingInt(@intCast(a)));
        };
        if (takes) try w.hereFor(out);

        // A string: a nullary constructor's name.
        {
            var cases: std.ArrayList(Node.Index) = .empty;
            for (all) |c| {
                const name = g.l.text(SchemaGraph.symbol(plan, plan.codec_ctors[c].name));
                var arm: Stmts = .empty;
                if (SchemaGraph.ctorArgs(plan, c).len == 0) {
                    const cc = (try g.codecCtor(n, c)) orelse continue;
                    try g.ret(&arm, try g.l.codecCtorValue(cc, &.{}, g.p));
                } else {
                    const message = try std.fmt.allocPrint(g.l.scratch, "the constructor {s} takes arguments, so it is an object with the key \"{s}\"", .{ name, name });
                    try g.ret(&arm, try w.failText(w.ownAt(), .wrong_shape, message, try g.id(v), false));
                }
                try cases.append(g.l.scratch, try w.switchCase(try g.str(name), arm.items));
            }
            var fallback: Stmts = .empty;
            try g.ret(&fallback, try w.fail(w.ownAt(), .unknown_tag, try g.concat(&.{ .{ .text = "unknown constructor \"" }, .{ .value = try g.id(v) }, .{ .text = try std.fmt.allocPrint(g.l.scratch, "\"; expected {s}", .{expected.items}) } }), try g.id(v), false));
            try cases.append(g.l.scratch, try w.switchCase(null, fallback.items));
            var string_arm: Stmts = .empty;
            try w.switchOn(&string_arm, try g.id(v), cases.items);
            const is_string = try g.bin(.strict_eq, try g.l.unary(.type_of, try g.id(v), g.p), try g.str("string"));
            try g.ifElse(out, is_string, string_arm.items, &.{});
        }
        // An object of one key.
        var not_object: Stmts = .empty;
        try g.ret(&not_object, try w.failText(w.ownAt(), .wrong_shape, "expected a constructor: a string, or an object with one key", try g.id(v), false));
        try g.ifElse(out, try w.isObjectTest(try g.id(v), try g.id(v), try g.id(v)), not_object.items, &.{});
        const keys = try g.fresh("$keys");
        try g.constDecl(out, keys, try g.globalCall("Object", "keys", &.{try g.id(v)}));
        var not_one: Stmts = .empty;
        try g.ret(&not_one, try w.failText(w.ownAt(), .wrong_shape, "expected a constructor: a string, or an object with one key", try g.id(v), false));
        try g.ifElse(out, try g.bin(.strict_ne, try g.prop(try g.id(keys), "length"), try g.num(1)), not_one.items, &.{});
        const key = try g.fresh("$key");
        try g.constDecl(out, key, try g.indexOf(try g.id(keys), try g.num(0)));
        var cases: std.ArrayList(Node.Index) = .empty;
        for (all) |c| {
            const name = g.l.text(SchemaGraph.symbol(plan, plan.codec_ctors[c].name));
            const args = SchemaGraph.ctorArgs(plan, c);
            var arm: Stmts = .empty;
            if (args.len == 0) {
                const message = try std.fmt.allocPrint(g.l.scratch, "the constructor {s} takes no arguments, so it is the string \"{s}\"", .{ name, name });
                try g.ret(&arm, try w.failText(w.ownAt(), .wrong_shape, message, try g.id(v), false));
            } else {
                const cc = (try g.codecCtor(n, c)) orelse continue;
                const payload = try g.fresh("$x");
                try g.constDecl(&arm, payload, try g.indexOf(try g.id(v), try g.str(name)));
                try w.ctorArgsInto(&arm, cc, name, args, payload, &.{});
            }
            try cases.append(g.l.scratch, try w.switchCase(try g.str(name), arm.items));
        }
        var fallback: Stmts = .empty;
        try g.ret(&fallback, try w.fail(w.ownAt(), .unknown_tag, try g.concat(&.{ .{ .text = "unknown constructor \"" }, .{ .value = try g.id(key) }, .{ .text = try std.fmt.allocPrint(g.l.scratch, "\"; expected {s}", .{expected.items}) } }), try g.id(v), false));
        try cases.append(g.l.scratch, try w.switchCase(null, fallback.items));
        try w.switchOn(out, try g.id(key), cases.items);
    }

    /// `ctorArgs`: constructor `cc`'s arguments, read at its name one level
    /// down — the argument itself, or an array of exactly as many — then the
    /// constructor (decoding) or its wire object (encoding). `payload` is the
    /// host value at the name when decoding; `typed` the arguments read off
    /// the value when encoding.
    fn ctorArgsInto(w: *Fn, out: *Stmts, cc: Lowerer.CodecCtor, name: []const u8, args: []const u32, payload: NameIndex, typed: []const Node.Index) !void {
        const g = w.g;
        const decoding = w.op.decoding();
        const at = w.childAt(.{ .text = name }, .{ .text = name });
        // The depth bound, before the descent; its input is the payload
        // read, or the constructor written.
        var stop: Stmts = .empty;
        try g.ret(&stop, try w.failText(at, .depth_exceeded, depth_message, try g.id(if (decoding) payload else w.ps.v), false));
        try g.ifElse(out, try w.deepTest(0), stop.items, &.{});
        if (args.len == 1) {
            const y = try g.fresh("$y");
            try g.letDecl(out, y);
            const x = if (decoding) payload else blk: {
                const a = try g.fresh("$a");
                try g.constDecl(out, a, typed[0]);
                break :blk a;
            };
            try w.into(out, @fromBackingInt(@intCast(args[0])), x, 1, at, y);
            var failed: Stmts = .empty;
            try g.ret(&failed, try w.failMark());
            try g.ifElse(out, try g.bin(.strict_eq, try g.id(y), try w.failMark()), failed.items, &.{});
            try g.ret(out, try w.ctorOut(out, cc, name, &.{try g.id(y)}, false));
            return;
        }
        if (decoding) {
            var wrong: Stmts = .empty;
            try g.ret(&wrong, try w.failText(at, .wrong_shape, try elementsMessage(g, args.len), try g.id(payload), false));
            const not_array = try g.not(try g.globalCall("Array", "isArray", &.{try g.id(payload)}));
            const wrong_length = try g.bin(.strict_ne, try g.prop(try g.id(payload), "length"), try g.num(@intCast(args.len)));
            try g.ifElse(out, try g.bin(.logical_or, not_array, wrong_length), wrong.items, &.{});
        }
        // The arguments' own path, below the constructor's name.
        const here = try g.fresh("$at");
        const path = try w.pathArgs(at);
        try g.constDecl(out, here, try g.call(try g.core("pathAt"), &path));
        const items = try g.l.scratch.alloc(Node.Index, args.len);
        for (items, 0..) |*item, i| item.* = if (decoding) try g.indexOf(try g.id(payload), try g.num(@intCast(i))) else typed[i];
        const values = try w.elementsInto(out, args, items, .{ .path = here }, 1);
        try w.failIfGrew(out, values.before);
        var ids: std.ArrayList(Node.Index) = .empty;
        for (values.names) |v| try ids.append(g.l.scratch, try g.id(v));
        try g.ret(out, try w.ctorOut(out, cc, name, ids.items, true));
    }

    /// The constructor of `args` (decoding), or its wire object (encoding):
    /// `{"Name": arg}`, or `{"Name": [args]}` when it takes several — for
    /// `write`, an object with no prototype (`newObject`).
    fn ctorOut(w: *Fn, out: *Stmts, cc: Lowerer.CodecCtor, name: []const u8, args: []const Node.Index, several: bool) !Node.Index {
        const g = w.g;
        if (w.op.decoding()) return g.l.codecCtorValue(cc, args, g.p);
        const value = if (several) try g.l.arrayNode(args, g.p) else args[0];
        if (w.op.json()) return g.l.object(&.{try g.l.property(try g.sym(name), value, g.p)}, g.p);
        const object = try w.newObject(out);
        try w.setKey(out, object, name, value, null);
        return g.id(object);
    }

    fn encodeCtors(w: *Fn, out: *Stmts, n: PNode) !void {
        const g = w.g;
        const plan = g.plan;
        const v = w.ps.v;
        const all = SchemaGraph.ctors(plan, n);
        var takes = false;
        for (all) |c| for (SchemaGraph.ctorArgs(plan, c)) |a| {
            takes = takes or takesPath(plan, @fromBackingInt(@intCast(a)));
        };
        if (takes) try w.hereFor(out);
        // An `if` chain over the constructors, the last one the `else`: a
        // well-typed value is one of them.
        var tail: Stmts = .empty;
        var i = all.len;
        while (i > 0) {
            i -= 1;
            const c = all[i];
            const cc = (try g.codecCtor(n, c)) orelse continue;
            const name = g.l.text(SchemaGraph.symbol(plan, plan.codec_ctors[c].name));
            const args = SchemaGraph.ctorArgs(plan, c);
            var arm: Stmts = .empty;
            if (args.len == 0) {
                try g.ret(&arm, try g.str(name));
            } else {
                const typed = try g.l.scratch.alloc(Node.Index, args.len);
                for (typed, 0..) |*t, k| t.* = try g.l.codecCtorArg(cc, try g.id(v), @intCast(k), g.p);
                try w.ctorArgsInto(&arm, cc, name, args, v, typed);
            }
            if (i + 1 == all.len) {
                tail = arm;
                continue;
            }
            const test_expr = (try g.l.codecCtorTest(cc, try g.id(v), g.p)) orelse {
                tail = arm;
                continue;
            };
            var chained: Stmts = .empty;
            try g.ifElse(&chained, test_expr, arm.items, tail.items);
            tail = chained;
        }
        try out.appendSlice(g.l.scratch, tail.items);
    }
};

/// "expected an array of N elements" (`elementsMessage`).
fn elementsMessage(g: *Gen, n: usize) ![]const u8 {
    return std.fmt.allocPrint(g.l.scratch, "expected an array of {d} elements", .{n});
}

/// The depth bound's message, which `compiledDeep` fixes.
const depth_message = "the depth limit is reached";

/// Whether `message` is `missing key "<key>"`, as `compiledMissing` makes it.
fn missingMessage(key: []const u8, message: []const u8) bool {
    const head = "missing key \"";
    return message.len == head.len + key.len + 1 and std.mem.startsWith(u8, message, head) and
        std.mem.eql(u8, message[head.len..][0..key.len], key) and message[message.len - 1] == '"';
}

fn isComposite(plan: *const SchemaPlan, n: PNode) bool {
    return switch (SchemaGraph.tag(plan, n)) {
        .record, .list, .tagged, .tuple, .constructors => true,
        else => false,
    };
}

/// Whether a list of `child` may hand back the parsed array itself: every
/// element's answer is the element (§6, *Lists are arrays*).
fn adoptable(plan: *const SchemaPlan, child: PNode) bool {
    if (SchemaGraph.tag(plan, child) != .primitive) return false;
    return switch (std.enums.fromInt(SchemaPlan.Primitive, SchemaGraph.lhs(plan, child)) orelse return false) {
        .string, .bool, .int, .float, .finite_float, .value, .char, .int32 => true,
        .null, .never => false,
    };
}

/// Whether a reference's arguments are the referencing definition's own
/// parameters in order: the reference is then the definition itself.
fn isIdentity(plan: *const SchemaPlan, words: []const u32, params: usize) bool {
    if (words.len != params) return false;
    for (words, 0..) |a, i| {
        const n: PNode = @fromBackingInt(@intCast(a));
        if (SchemaGraph.tag(plan, n) != .parameter or SchemaGraph.lhs(plan, n) != i) return false;
    }
    return true;
}

const primitiveBuilder = SchemaGraph.primitiveBuilder;

const isPrototypeKey = SchemaShare.isPrototypeKey;

/// `<Module>$<Schema>$$readValid`, the root validator worker of `ref`, which
/// a validator run whose schema is `S.schema ⊤` calls (`SchemaValid`).
pub fn validWorker(l: *Lowerer, ref: SchemaGraph.Ref, p: u32) !Node.Index {
    try l.requireLive(l.liveSchema(ref, .read_valid), "readValid");
    return l.ident(try schemaName(l, ref, Op.valid.workerSuffix()), p);
}
