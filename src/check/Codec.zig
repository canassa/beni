//! Schemas derived from a type (`docs/design/schema.md` §12, §12.10): the
//! third well-known method, `codec`, which `Json.decode` dispatches on its
//! result type.
//!
//! **A `codec` wanted whose receiver is a type waits** (`wait`) for its
//! top-level declaration's boundary (`boundary`), which runs after the last
//! default of §8.1 step 3, so a field read the declaration makes of a
//! decoded value has made its record by then. The boundary first applies
//! Roc's closing rule (§12.5): each record row of a waiting receiver that is
//! still open, young, and reached by no member's type is closed to the
//! fields it has. Then it derives.
//!
//! **A derivation is a definition.** The receiver's type, with each type
//! variable a numbered slot, is the definition's KEY (`keyOf`); a
//! definition is that type's shape in schema-plan terms (`Node`): records,
//! tuples, lists and primitives written in place, a nominal type a
//! definition of its own (so a recursive type's worker calls itself), a
//! slot a parameter. Two uses with one key share one definition. The use's
//! answer is `codec { definition, one sub-wanted per slot }`, the slot's own
//! `codec` evidence, which a `where` gives, promotion forwards, or §9.4's
//! default refuses as `derived_codec_needs_type`.
//!
//! **What reaches the backend.** P9 writes every definition into the
//! module's schema plan in key order (`writePlan`), which the dispatch
//! table's `codec` terms index (`order`). A definition is checked here and
//! nowhere else: the plan holds no variable.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Evidence = @import("Evidence.zig");
const Solve = @import("Solve.zig");
const Resolve = @import("Resolve.zig");
const Instances = @import("Instances.zig");
const Walk = @import("Walk.zig");
const Render = @import("Render.zig");
const SchemaPlan = @import("SchemaPlan.zig");

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const WantedId = Evidence.WantedId;
const Error = Allocator.Error;

pub const none = std.math.maxInt(u32);

/// How deep one derivation walks a type before it gives up: a type nested
/// deeper is refused rather than walked on the native stack.
const max_depth = 200;
/// How many definitions one derivation may make: past it a type is used at
/// ever larger arguments inside itself (polymorphic recursion).
const max_definitions = 512;

pub const State = struct {
    /// Wanteds waiting for their declaration's boundary, in creation order.
    pending: std.ArrayList(WantedId) = .empty,
    defs: std.ArrayList(Def) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    words: std.ArrayList(u32) = .empty,
    by_key: std.StringHashMapUnmanaged(u32) = .empty,
    /// A slot's sub-wanted and the field its type was read at, for
    /// `derived_codec_needs_type`: an error path's list, scanned.
    fields: std.ArrayList(struct { WantedId, Symbol }) = .empty,
    /// The uses `derived_codec_needs_type` was said at, once each: scanned.
    unknown: std.ArrayList(Bir.Inst.Index) = .empty,
    /// After P4, per definition its place in key order: the plan's index.
    order: []u32 = &.{},
    /// `core`'s `Int32`, found once.
    int32: ?Types.TypeId = null,

    pub fn deinit(c: *State, gpa: Allocator) void {
        c.pending.deinit(gpa);
        for (c.defs.items) |d| gpa.free(d.key);
        c.defs.deinit(gpa);
        c.nodes.deinit(gpa);
        c.words.deinit(gpa);
        c.by_key.deinit(gpa);
        c.fields.deinit(gpa);
        c.unknown.deinit(gpa);
        gpa.free(c.order);
    }
};

/// One definition: a key's shape.
pub const Def = struct {
    /// Owned.
    key: []const u8,
    root: u32 = none,
    /// How many slots, which are its parameters.
    slots: u32,
    /// The source token of the first use, where the code it compiles to is.
    token: u32,
    /// Its shape could not be derived; the first use said why.
    failed: bool = false,
};

/// One node of a definition's shape.
pub const Node = struct {
    tag: Tag,
    a: u32 = 0,
    b: u32 = 0,

    pub const Tag = enum(u8) {
        /// `a`: a `SchemaPlan.Primitive`.
        prim,
        /// `a`: the element.
        list,
        /// `a`: the inner node, `b`: `SchemaPlan.Maybe` bits.
        maybe,
        /// `a`: the inner node.
        nullable,
        /// `words[a..][0..b]`: the elements.
        tuple,
        /// `words[a..][0..3 * b]`: per field its name, its node and its
        /// form (`FieldForm`), in name-text order.
        record,
        /// `a`: the `TypeId`, `words[b]` the constructor count, then per
        /// constructor its name, its place, its argument count and its
        /// argument nodes.
        ctors,
        /// `a`: the slot.
        param,
        /// `a`: the definition, `words[b]` the argument count, then a
        /// slot of this definition per parameter of that one.
        def_ref,
        /// The type's module's `codec`: `a` the module, `b` the `TypeId`.
        value,
        /// A tagged schema's `Type` endpoint: `a` its `TypeId`.
        schema_ref,
    };
};

pub const FieldForm = enum(u32) { required, presence };

// ---------------------------------------------------------------------------
// Waiting
// ---------------------------------------------------------------------------

pub fn isCodec(name: Symbol) bool {
    return name == InternPool.WellKnown.codec.symbol();
}

/// A `codec` wanted met a type: it waits for its declaration's boundary.
pub fn wait(s: *Solve, id: WantedId) Error!void {
    s.evidence.ptr(id).state = .open;
    try s.codecs.pending.append(s.cx.gpa, id);
}

/// The waiting wanteds of `members`, closed and derived (§12.5). True when
/// any was, so the caller settles again.
pub fn boundary(s: *Solve, members: []const u32) Error!bool {
    var any = false;
    var round: std.ArrayList(WantedId) = .empty;
    defer round.deinit(s.cx.scratch);
    while (true) {
        round.clearRetainingCapacity();
        var keep: usize = 0;
        for (s.codecs.pending.items) |id| {
            const w = s.evidence.get(id);
            if (std.mem.indexOfScalar(u32, members, w.decl) != null) {
                try round.append(s.cx.scratch, id);
            } else {
                s.codecs.pending.items[keep] = id;
                keep += 1;
            }
        }
        s.codecs.pending.shrinkRetainingCapacity(keep);
        if (round.items.len == 0) return any;
        any = true;
        for (round.items) |id| try close(s, id, members);
        for (round.items) |id| try derive(s, id);
    }
}

/// What waited past every boundary — a wanted whose declaration was merged
/// away, or that a later unification readied — derived once P4 is done,
/// with no row to close.
pub fn finish(s: *Solve) Error!void {
    while (s.codecs.pending.items.len != 0) {
        const round = try s.cx.scratch.dupe(WantedId, s.codecs.pending.items);
        defer s.cx.scratch.free(round);
        s.codecs.pending.clearRetainingCapacity();
        for (round) |id| try derive(s, id);
    }
}

/// Roc's closing rule (§12.5): every record row of `id`'s receiver that is
/// still an open variable of this frame, and that no member's type
/// reaches, is closed to the fields it has.
fn close(s: *Solve, id: WantedId, members: []const u32) Error!void {
    const st = s.store();
    const gpa = s.cx.gpa;
    const rank = s.frame().rank;
    var rows: std.ArrayList(Var) = .empty;
    defer rows.deinit(s.cx.scratch);
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(s.cx.scratch);
    // Each node once, by the store's marks: a type is a graph, and a shared
    // part is walked once. The row's extension chain is followed here, with
    // no other walk taking a mark meanwhile.
    const seen = st.nextMark();
    try stack.append(s.cx.scratch, s.evidence.get(id).receiver);
    while (stack.pop()) |v| {
        const root, const content = st.resolved(v);
        if (st.mark(root) == seen) continue;
        st.setMark(root, seen);
        switch (content) {
            .structure => |flat| switch (flat) {
                .record => |r| {
                    for (Walk.recordFields(st, r)) |f| try stack.append(s.cx.scratch, f.value);
                    // The row's end: another record's fields, `{}`, or a
                    // variable, which is the row to close.
                    const end, const tail = st.resolved(r.ext);
                    switch (tail) {
                        .structure => |t| switch (t) {
                            .record => try stack.append(s.cx.scratch, end),
                            else => {},
                        },
                        .flex => try rows.append(s.cx.scratch, end),
                        else => {},
                    }
                },
                .tuple, .app => for (Walk.positions(st, root)) |p| try stack.append(s.cx.scratch, p),
                else => {},
            },
            else => {},
        }
    }
    for (rows.items) |row| {
        const end = st.find(row);
        switch (st.content(end)) {
            .flex => {},
            else => continue,
        }
        if (st.rank(end) < rank) continue;
        var reached = false;
        for (members) |m| {
            if (m >= s.decl_scheme.len) continue;
            const header = s.decl_scheme[m].unwrap() orelse continue;
            if (try Walk.reaches(st, &s.stacks, gpa, header, end)) {
                reached = true;
                break;
            }
        }
        if (reached) continue;
        const empty = try s.fresh(.{ .structure = .empty_record });
        _ = try s.unifyQuiet(end, empty, s.evidence.get(id).origin);
    }
}

// ---------------------------------------------------------------------------
// Deriving
// ---------------------------------------------------------------------------

/// `⊤ → Schema Value t`, the method's type at `t`.
fn methodType(s: *Solve, t: Var) Error!Var {
    const wk = s.cx.types.well_known;
    const unit = try s.fresh(.{ .structure = .unit });
    const value = try s.fresh(.{ .structure = .{ .app = .{ .type = wk.value, .args = .empty } } });
    const schema_args = try s.store().addVars(&.{ value, t });
    const schema = try s.fresh(.{ .structure = .{ .app = .{ .type = wk.schema, .args = schema_args } } });
    const params = try s.store().addVars(&.{unit});
    return s.fresh(.{ .structure = .{ .func = .{ .params = params, .result = schema } } });
}

/// Whether `w` came from core's `Schema.structural`: the outermost type then
/// skips its module's `codec` (§12.2).
fn fromStructural(s: *Solve, w: Evidence.Wanted) bool {
    const bir = s.cx.bir;
    if (w.origin.int() >= bir.insts.len or bir.instTag(w.origin) != .ext_value) return false;
    const d = bir.instData(w.origin);
    const module: Graph.Index = @fromBackingInt(@intCast(d.lhs));
    if (s.cx.graph.modulePackage(module) != .core or s.cx.graph.moduleName(module) != InternPool.WellKnown.Schema.symbol()) return false;
    if (module.int() >= s.cx.interfaces.len) return false;
    const iface = s.cx.iface(module);
    if (d.rhs >= iface.values.len) return false;
    return std.mem.eql(u8, s.cx.interner.slice(iface.symbol(iface.values[d.rhs].name)), "structural");
}

/// Answer waiting wanted `id`.
fn derive(s: *Solve, id: WantedId) Error!void {
    const w = s.evidence.get(id);
    if (w.state != .open and w.state != .ready) return;
    const st = s.store();
    const saved = s.report.current;
    defer s.report.at(saved);
    s.report.at(if (w.decl == Evidence.Wanted.no_decl) saved else w.decl);
    const root, const content = st.resolved(w.receiver);
    switch (content) {
        .err => return Resolve.poisoned(s, id),
        // Unified with a variable since it waited: it rides on it.
        .flex, .rigid => return Resolve.step(s, id, false),
        else => {},
    }
    if (!try s.unifyQuiet(try methodType(s, root), w.method_type, w.origin)) {
        try s.report.emitText(.type_mismatch, w.origin, null, "This `codec` requirement does not have the type `⊤ → Codec a` (schema.md §12.2), so no derived codec can answer it.\n");
        return Resolve.reject(s, id, true);
    }
    const structural = fromStructural(s, w);
    // §12.2 step 2: the module rule, at the receiver itself.
    if (!structural) {
        if (content == .structure and content.structure == .app) {
            const a = content.structure.app;
            if (try moduleCodec(s, a.type) != null) return Instances.moduleRule(s, id, root, a);
        }
    }
    if (structural) {
        const own = switch (content) {
            .structure => |flat| switch (flat) {
                .app => |a| s.cx.types.entry(a.type).module == s.cx.module,
                else => false,
            },
            else => false,
        };
        if (!own) {
            try refuse(s, w.origin, root, root, &.{}, "is read by `Schema.structural` only in the module that declares it, whose constructors are its own: anywhere else it would build values that skip the checks its module makes");
            return Resolve.reject(s, id, true);
        }
    }
    var d: Derivation = .{ .s = s, .origin = w.origin, .decoded = w.receiver, .structural = structural };
    defer d.deinit();
    const def = (try d.defFor(root)) orelse return Resolve.reject(s, id, d.reported);
    if (s.codecs.defs.items[def].failed) return Resolve.poisoned(s, id);
    // One sub-wanted per slot, in the key's order.
    const key = try d.keyOf(root);
    const subs = try s.cx.scratch.alloc(WantedId, key.slots.len);
    defer s.cx.scratch.free(subs);
    for (key.slots, subs, 0..) |slot, *sub, i| {
        const sub_id = try Resolve.create(s, w.method, slot, try methodType(s, slot), w.origin, w.kind, id.toOptional());
        s.evidence.ptr(sub_id).decl = w.decl;
        if (key.fields[i].unwrap()) |f| try s.codecs.fields.append(s.cx.gpa, .{ sub_id, f });
        sub.* = sub_id;
    }
    const args = try s.evidence.addArgs(s.cx.gpa, subs);
    Resolve.answer(s, id, .{ .codec = .{ .index = def, .args = args } });
    for (subs) |sub| try Resolve.step(s, sub, false);
}

/// The value module rule step 2 finds for `type_id`'s `codec`, when its
/// module declares one: this module's declaration, or another's interface
/// value.
const ModuleCodec = union(enum) {
    own: u32,
    imported: struct { module: Graph.Index, value: Interface.ValueIndex },
};

fn moduleCodec(s: *Solve, type_id: Types.TypeId) Error!?ModuleCodec {
    const entry = s.cx.types.entry(type_id);
    const name = InternPool.WellKnown.codec.symbol();
    if (entry.module == s.cx.module) {
        if (s.ownValue(name)) |decl| return .{ .own = decl };
        return null;
    }
    if (entry.module.int() >= s.cx.interfaces.len) return null;
    const iface = s.cx.iface(entry.module);
    if (iface.findValue(s.cx.interner, name)) |v| return .{ .imported = .{ .module = entry.module, .value = v } };
    return null;
}

/// `no_derived_codec` at `region` (schema.md §12.7): the decoded type
/// cannot be read from JSON, because the type `at` it holds at `path`
/// (field and constructor names, outermost first; none for the decoded type
/// itself) `reason` — a predicate, "is a function, which JSON has no form
/// for".
fn refuse(s: *Solve, region: Bir.Inst.Index, decoded: Var, at: Var, path: []const []const u8, reason: []const u8) Error!void {
    var namer: Render.Namer = .init(s.cx.scratch);
    defer namer.deinit();
    const cx: Render.Context = .{ .store = s.store(), .types = s.cx.types, .interner = s.cx.interner };
    const whole = try Render.allocType(s.cx.scratch, cx, &namer, decoded);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(s.cx.scratch);
    try text.print(s.cx.scratch, "`{s}` cannot be read from JSON or written to it: ", .{whole});
    if (path.len == 0) {
        try text.appendSlice(s.cx.scratch, "it");
    } else {
        try text.appendSlice(s.cx.scratch, "at `");
        for (path, 0..) |p, i| {
            if (i != 0 and !std.mem.eql(u8, p, "[]")) try text.appendSlice(s.cx.scratch, ".");
            try text.appendSlice(s.cx.scratch, p);
        }
        try text.print(s.cx.scratch, "`, `{s}`", .{try Render.allocType(s.cx.scratch, cx, &namer, at)});
    }
    try text.print(s.cx.scratch, " {s}.\n", .{reason});
    try s.report.emitText(.no_derived_codec, region, null, text.items);
}

fn fieldOf(s: *const Solve, id: WantedId) ?Symbol {
    for (s.codecs.fields.items) |pair| if (pair[0] == id) return pair[1];
    return null;
}

/// §9.4's default for a slot no type reached: `derived_codec_needs_type`.
pub fn needsType(s: *Solve, id: WantedId) Error!void {
    const w = s.evidence.get(id);
    // One message per use: the first slot nothing reached says it.
    if (std.mem.indexOfScalar(Bir.Inst.Index, s.codecs.unknown.items, w.origin) != null) return;
    try s.codecs.unknown.append(s.cx.gpa, w.origin);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(s.cx.scratch);
    const number = switch (s.store().resolvedContent(w.receiver)) {
        .flex => |flags| flags.kind == .number,
        else => false,
    };
    if (number) {
        try text.appendSlice(s.cx.scratch, "This is a number, but nothing in this declaration says whether it is an `Int` or a `Float`, and JSON reads the two differently: a `1.5` is not an `Int`.\n\nAnnotate it, or use it where its type shows.\n");
    } else if (fieldOf(s, id)) |field| {
        try text.print(s.cx.scratch, "I can see this decoded record has a field `{s}`, but nothing says what type it is, so I cannot tell how to read it from JSON.\n\nUse the field where its type shows, or annotate the declaration with the record's type.\n", .{s.cx.interner.slice(field)});
    } else {
        try text.appendSlice(s.cx.scratch, "Nothing in this declaration says what type this decodes to, so I cannot tell how to read it from JSON.\n\nAnnotate the declaration, or use the decoded value where its type shows.\n");
    }
    try s.report.emitText(.derived_codec_needs_type, w.origin, null, text.items);
}

const Key = struct {
    text: []const u8,
    /// The slots, each a variable root, in pre-order.
    slots: []const Var,
    /// Per slot, the field whose type it is, or none.
    fields: []const Symbol.Optional,
};

const Derivation = struct {
    s: *Solve,
    origin: Bir.Inst.Index,
    /// The use's receiver, which a message names.
    decoded: Var,
    structural: bool,
    /// A message was said (not a silent `err`).
    reported: bool = false,
    made: u32 = 0,
    depth: u32 = 0,
    /// Field and constructor names from the root to the position being
    /// derived, for the message.
    path: std.ArrayList([]const u8) = .empty,

    fn deinit(d: *Derivation) void {
        d.path.deinit(d.s.cx.scratch);
    }

    fn st(d: *Derivation) *TypeStore {
        return d.s.store();
    }

    fn fail(d: *Derivation, at: Var, reason: []const u8) Error!?u32 {
        try refuse(d.s, d.origin, d.decoded, at, d.path.items, reason);
        d.reported = true;
        return null;
    }

    fn failText(d: *Derivation, at: Var, comptime fmt: []const u8, args: anytype) Error!?u32 {
        const reason = try std.fmt.allocPrint(d.s.cx.scratch, fmt, args);
        return d.fail(at, reason);
    }

    // ---- Keys ---------------------------------------------------------

    /// `t`'s key: its text with every variable a slot `#k`, nominal
    /// types by their module and name, record fields in name-text order.
    fn keyOf(d: *Derivation, t: Var) Error!Key {
        var text: std.ArrayList(u8) = .empty;
        var slots: std.ArrayList(Var) = .empty;
        var fields: std.ArrayList(Symbol.Optional) = .empty;
        try d.keyInto(t, &text, &slots, &fields, .none, 0);
        return .{ .text = text.items, .slots = slots.items, .fields = fields.items };
    }

    fn keyInto(d: *Derivation, t: Var, text: *std.ArrayList(u8), slots: *std.ArrayList(Var), fields: *std.ArrayList(Symbol.Optional), field: Symbol.Optional, depth: u32) Error!void {
        const scratch = d.s.cx.scratch;
        const interner = d.s.cx.interner;
        if (depth > max_depth) return text.appendSlice(scratch, "…");
        const root, const content = d.st().resolved(t);
        switch (content) {
            .flex, .rigid => {
                const k = for (slots.items, 0..) |v, i| {
                    if (v == root) break i;
                } else blk: {
                    try slots.append(scratch, root);
                    try fields.append(scratch, field);
                    break :blk slots.items.len - 1;
                };
                try text.print(scratch, "#{d}", .{k});
            },
            .err, .alias => try text.appendSlice(scratch, "?"),
            .structure => |flat| switch (flat) {
                .unit => try text.appendSlice(scratch, "()"),
                .empty_record => try text.appendSlice(scratch, "{}"),
                .func => try text.appendSlice(scratch, "->"),
                .tuple => |r| {
                    const items = try scratch.dupe(Var, d.st().vars(r));
                    try text.append(scratch, '(');
                    for (items, 0..) |item, i| {
                        if (i != 0) try text.append(scratch, ',');
                        try d.keyInto(item, text, slots, fields, field, depth + 1);
                    }
                    try text.append(scratch, ')');
                },
                .record => |r| {
                    var row: std.ArrayList(TypeStore.Field) = .empty;
                    var concatenated = false;
                    const end = try Walk.recordRow(d.st(), r, &row, scratch, &concatenated);
                    try TypeStore.sortByText(TypeStore.Field, scratch, interner, row.items);
                    try text.append(scratch, '{');
                    for (row.items, 0..) |f, i| {
                        if (i != 0) try text.append(scratch, ',');
                        try text.print(scratch, "{s}:", .{interner.slice(f.name)});
                        try d.keyInto(f.value, text, slots, fields, f.name.toOptional(), depth + 1);
                    }
                    switch (end) {
                        .open => try text.appendSlice(scratch, "|…"),
                        .closed => {},
                    }
                    try text.append(scratch, '}');
                },
                .app => |a| {
                    const entry = d.s.cx.types.entry(a.type);
                    try text.print(scratch, "{s}.{s}", .{ interner.slice(entry.module_name), interner.slice(entry.name) });
                    const args = try scratch.dupe(Var, d.st().vars(a.args));
                    if (args.len != 0) {
                        try text.append(scratch, '(');
                        for (args, 0..) |arg, i| {
                            if (i != 0) try text.append(scratch, ',');
                            try d.keyInto(arg, text, slots, fields, field, depth + 1);
                        }
                        try text.append(scratch, ')');
                    }
                },
            },
        }
    }

    // ---- Definitions --------------------------------------------------

    /// The definition of `t`'s key, made when it is new: a nominal type's
    /// constructors, anything else its shape.
    fn defFor(d: *Derivation, t: Var) Error!?u32 {
        const c = &d.s.codecs;
        const gpa = d.s.cx.gpa;
        const key = try d.keyOf(t);
        if (c.by_key.get(key.text)) |index| return index;
        d.made += 1;
        if (d.made > max_definitions) return d.fail(t, "is used at ever larger types inside itself, so no finite schema reads it");
        const owned = try gpa.dupe(u8, key.text);
        const index: u32 = @intCast(c.defs.items.len);
        try c.defs.append(gpa, .{ .key = owned, .slots = @intCast(key.slots.len), .token = d.s.cx.bir.insts.items(.main_token)[d.origin.int()] });
        try c.by_key.put(gpa, owned, index);
        const slots = try d.s.cx.scratch.dupe(Var, key.slots);
        const root, const content = d.st().resolved(t);
        const node = switch (content) {
            .structure => |flat| switch (flat) {
                .app => |a| if (d.nominal(a.type))
                    try d.ctorsNode(root, a.type, slots)
                else
                    try d.nodeFor(root, slots, false),
                else => try d.nodeFor(root, slots, false),
            },
            else => try d.nodeFor(root, slots, false),
        };
        if (node) |n| {
            c.defs.items[index].root = n;
        } else {
            c.defs.items[index].failed = true;
            return null;
        }
        return index;
    }

    /// Whether `type_id` is a `type` read by its constructors: not one the
    /// table answers, not a foreign type, not a schema endpoint.
    fn nominal(d: *Derivation, type_id: Types.TypeId) bool {
        if (d.tableType(type_id)) return false;
        const entry = d.s.cx.types.entry(type_id);
        return entry.kind == .adt and !entry.schema_endpoint;
    }

    fn tableType(d: *Derivation, type_id: Types.TypeId) bool {
        const wk = d.s.cx.types.well_known;
        return type_id == wk.int or type_id == wk.float or type_id == wk.bool or type_id == wk.string or
            type_id == wk.char or type_id == wk.value or type_id == wk.never or type_id == wk.list or
            type_id == wk.maybe or type_id == wk.nullable or type_id == wk.presence or
            type_id == d.int32();
    }

    fn int32(d: *Derivation) Types.TypeId {
        const c = &d.s.codecs;
        if (c.int32) |id| return id;
        const cx = d.s.cx;
        const name = cx.interner.find("Int32");
        const id = if (name) |n| cx.types.find(cx.graph, .core, n, n) else .none;
        c.int32 = id;
        return id;
    }

    fn add(d: *Derivation, n: Node) Error!u32 {
        const c = &d.s.codecs;
        try c.nodes.append(d.s.cx.gpa, n);
        return @intCast(c.nodes.items.len - 1);
    }

    fn slotOf(d: *Derivation, root: Var, slots: []const Var) ?u32 {
        const f = d.st().find(root);
        for (slots, 0..) |v, i| if (d.st().find(v) == f) return @intCast(i);
        return null;
    }

    /// The node of `t` inside a definition whose slots are `slots`.
    fn nodeFor(d: *Derivation, t: Var, slots: []const Var, in_field: bool) Error!?u32 {
        _ = in_field;
        d.depth += 1;
        defer d.depth -= 1;
        if (d.depth > max_depth) return d.fail(t, "nests too deep to be read");
        const root, const content = d.st().resolved(t);
        switch (content) {
            .err, .alias => {
                // Its message is where the `err` was made.
                return null;
            },
            .flex => |flags| {
                _ = flags;
                if (d.st().rank(root) == TypeStore.generalized) return d.fail(root, "was generalised by a `let` inside the declaration: annotate that `let`");
                const k = d.slotOf(root, slots) orelse return d.fail(root, "has a variable that is not one of its parameters");
                return try d.add(.{ .tag = .param, .a = k });
            },
            .rigid => {
                const k = d.slotOf(root, slots) orelse return d.fail(root, "has a variable that is not one of its parameters");
                return try d.add(.{ .tag = .param, .a = k });
            },
            .structure => |flat| switch (flat) {
                .unit => return try d.tuple(&.{}, slots),
                .tuple => |r| {
                    const items = try d.s.cx.scratch.dupe(Var, d.st().vars(r));
                    return d.tuple(items, slots);
                },
                .func => return d.fail(root, "is a function, which JSON has no form for"),
                .empty_record => return try d.record(&.{}, slots),
                .record => |r| {
                    var row: std.ArrayList(TypeStore.Field) = .empty;
                    var concatenated = false;
                    switch (try Walk.recordRow(d.st(), r, &row, d.s.cx.scratch, &concatenated)) {
                        .open => return d.fail(root, "is an extensible record, whose other fields are not known"),
                        .closed => {},
                    }
                    try TypeStore.sortByText(TypeStore.Field, d.s.cx.scratch, d.s.cx.interner, row.items);
                    return d.record(row.items, slots);
                },
                .app => |a| return d.app(root, a, slots, false),
            },
        }
    }

    fn tuple(d: *Derivation, items: []const Var, slots: []const Var) Error!?u32 {
        const scratch = d.s.cx.scratch;
        const children = try scratch.alloc(u32, items.len);
        for (items, children, 0..) |item, *child, i| {
            try d.path.append(scratch, try std.fmt.allocPrint(scratch, "{d}", .{i}));
            defer _ = d.path.pop();
            child.* = (try d.nodeFor(item, slots, false)) orelse return null;
        }
        const c = &d.s.codecs;
        const start: u32 = @intCast(c.words.items.len);
        try c.words.appendSlice(d.s.cx.gpa, children);
        return try d.add(.{ .tag = .tuple, .a = start, .b = @intCast(items.len) });
    }

    fn record(d: *Derivation, row: []const TypeStore.Field, slots: []const Var) Error!?u32 {
        const scratch = d.s.cx.scratch;
        const out = try scratch.alloc(u32, row.len * 3);
        for (row, 0..) |f, i| {
            try d.path.append(scratch, d.s.cx.interner.slice(f.name));
            defer _ = d.path.pop();
            out[i * 3] = @backingInt(f.name);
            out[i * 3 + 2] = @backingInt(FieldForm.required);
            const froot, const fcontent = d.st().resolved(f.value);
            // A field's `Maybe` may be absent (§12.4), and its `Presence`
            // is the exact field form.
            if (fcontent == .structure and fcontent.structure == .app) {
                const a = fcontent.structure.app;
                const wk = d.s.cx.types.well_known;
                if (a.type == wk.presence and a.args.len == 1) {
                    const inner = d.st().vars(a.args)[0];
                    out[i * 3 + 1] = (try d.nodeFor(inner, slots, false)) orelse return null;
                    out[i * 3 + 2] = @backingInt(FieldForm.presence);
                    continue;
                }
                if (a.type == wk.maybe and a.args.len == 1) {
                    out[i * 3 + 1] = (try d.app(froot, a, slots, true)) orelse return null;
                    continue;
                }
            }
            out[i * 3 + 1] = (try d.nodeFor(f.value, slots, true)) orelse return null;
        }
        const c = &d.s.codecs;
        const start: u32 = @intCast(c.words.items.len);
        try c.words.appendSlice(d.s.cx.gpa, out);
        return try d.add(.{ .tag = .record, .a = start, .b = @intCast(row.len) });
    }

    /// Whether node `n` reads `null` as a value of its own (§12.4).
    fn readsNull(d: *Derivation, n: u32) enum { yes, no, unknown } {
        const node = d.s.codecs.nodes.items[n];
        return switch (node.tag) {
            .maybe, .nullable => .yes,
            .prim => if (node.a == @backingInt(SchemaPlan.Primitive.value) or node.a == @backingInt(SchemaPlan.Primitive.null)) .yes else .no,
            .param, .value, .schema_ref => .unknown,
            else => .no,
        };
    }

    /// A type's application: the table, a schema endpoint, the type's
    /// module's `codec`, or its constructors.
    fn app(d: *Derivation, root: Var, a: TypeStore.Structure.App, slots: []const Var, field: bool) Error!?u32 {
        const wk = d.s.cx.types.well_known;
        const args = try d.s.cx.scratch.dupe(Var, d.st().vars(a.args));
        const prim: ?SchemaPlan.Primitive = if (a.type == wk.int)
            .int
        else if (a.type == wk.float)
            .float
        else if (a.type == wk.bool)
            .bool
        else if (a.type == wk.string)
            .string
        else if (a.type == wk.char)
            .char
        else if (a.type == wk.value)
            .value
        else if (a.type == wk.never)
            .never
        else if (a.type == d.int32())
            .int32
        else
            null;
        if (prim) |p| return try d.add(.{ .tag = .prim, .a = @backingInt(p) });
        if (a.type == wk.list and args.len == 1) {
            try d.path.append(d.s.cx.scratch, "[]");
            const child = (try d.nodeFor(args[0], slots, false)) orelse return null;
            _ = d.path.pop();
            return try d.add(.{ .tag = .list, .a = child });
        }
        if (a.type == wk.nullable and args.len == 1) {
            const child = (try d.nodeFor(args[0], slots, false)) orelse return null;
            return try d.add(.{ .tag = .nullable, .a = child });
        }
        if (a.type == wk.maybe and args.len == 1) {
            const child = (try d.nodeFor(args[0], slots, false)) orelse return null;
            var mode: u32 = if (field) SchemaPlan.Maybe.field else 0;
            switch (d.readsNull(child)) {
                .yes => {
                    if (!field) return d.fail(root, "is a `Maybe` of a type that reads `null` itself, so `Nothing` and `Just` of that `null` would be one JSON value: outside a record field use `Schema.Nullable`, or make it a field");
                    mode |= SchemaPlan.Maybe.reads_null;
                },
                .unknown => mode |= SchemaPlan.Maybe.refuse_null,
                .no => {},
            }
            return try d.add(.{ .tag = .maybe, .a = child, .b = mode });
        }
        if (a.type == wk.presence) return d.fail(root, "says whether a record field's key is there, so it is read only as a field's type");
        const entry = d.s.cx.types.entry(a.type);
        if (d.dictOrSet(entry)) return d.failDictOrSet(root, entry);
        if (entry.schema_endpoint) {
            const tagged = d.s.cx.types.ofSchemaDecl(entry.module, entry.decl, .type) == a.type and entry.kind == .adt;
            if (tagged) return try d.add(.{ .tag = .schema_ref, .a = @backingInt(a.type) });
            return d.fail(root, "is a schema's `Encoded` endpoint, which its schema reads: use the schema's `parse`, or decode its `Type`");
        }
        if (try moduleCodec(d.s, a.type)) |found| {
            if (!try d.evidenceFree(found, root)) return null;
            return try d.add(.{ .tag = .value, .a = entry.module.int(), .b = @backingInt(a.type) });
        }
        switch (entry.kind) {
            .foreign => return d.failText(root, "is a foreign type, `{s}`, whose values JSON has no form for, and its module declares no `codec`", .{d.s.cx.interner.slice(entry.name)}),
            .alias => return d.fail(root, "is an alias the compiler could not read through"),
            .adt => {},
        }
        const def = (try d.defFor(root)) orelse return null;
        const target_key = try d.keyOf(root);
        const c = &d.s.codecs;
        const start: u32 = @intCast(c.words.items.len);
        try c.words.append(d.s.cx.gpa, @intCast(target_key.slots.len));
        for (target_key.slots) |v| {
            const k = d.slotOf(v, slots) orelse return d.fail(root, "has a variable that is not one of its parameters");
            try c.words.append(d.s.cx.gpa, k);
        }
        return try d.add(.{ .tag = .def_ref, .a = def, .b = start });
    }

    /// §12.2's `Dict` and `Set` rows need their key's `compare` beside the
    /// codec slots; they are not built yet (#205).
    fn dictOrSet(d: *Derivation, entry: Types.Entry) bool {
        if (d.s.cx.graph.modulePackage(entry.module) != .core) return false;
        const name = d.s.cx.interner.slice(entry.name);
        return std.mem.eql(u8, name, "Dict") or std.mem.eql(u8, name, "Set");
    }

    fn failDictOrSet(d: *Derivation, root: Var, entry: Types.Entry) Error!?u32 {
        return d.failText(root, "is a `{s}`, which a derived codec does not read yet (issue #205): use a `List` of pairs, or a declared schema", .{d.s.cx.interner.slice(entry.name)});
    }

    /// Whether a type's constructors are this module's to read: its own
    /// type, or another module's that exports them.
    fn visible(d: *Derivation, entry: Types.Entry) bool {
        if (entry.module == d.s.cx.module) return true;
        const iface = d.s.cx.iface(entry.module);
        const ti = iface.findType(d.s.cx.interner, entry.name) orelse return false;
        const t = iface.types[@backingInt(ti)];
        return !t.is_opaque and t.ctors_end > t.ctors_start;
    }

    /// A module's `codec` met below the receiver must take no evidence and
    /// have the method's type (§12.10).
    fn evidenceFree(d: *Derivation, found: ModuleCodec, at: Var) Error!bool {
        const s = d.s;
        const requirements: u32 = switch (found) {
            .imported => |v| @import("Dispatch.zig").extRequirementCount(s.cx.interfaces, v.module, @backingInt(v.value)),
            .own => |decl| blk: {
                const header = s.decl_scheme[decl].unwrap() orelse break :blk 0;
                var reqs: std.ArrayList(Evidence.Requirement) = .empty;
                defer reqs.deinit(s.cx.scratch);
                try Evidence.requirements(s.store(), s.cx.interner, header, s.cx.scratch, &reqs);
                break :blk @intCast(reqs.items.len);
            },
        };
        if (requirements != 0) {
            _ = try d.fail(at, "has a module `codec` that needs evidence, so it is used only where it is the decoded type itself");
            return false;
        }
        // Its type: the module rule makes a module's one `codec` the
        // method of every type the module declares, so it must be this
        // type's (`Instances.match` says the same at the receiver).
        const copy: ?Var = switch (found) {
            .imported => |v| try s.instantiate.importedValue(v.module, @backingInt(v.value)),
            .own => |decl| blk: {
                if (s.cx.bir.decls[decl].annotation == .none) {
                    _ = try d.fail(at, "has a module `codec` with no annotation, whose type a derived codec cannot read while its module is checked: annotate it `⊤ → Codec …`");
                    return false;
                }
                const scheme = s.decl_scheme[decl].unwrap() orelse break :blk null;
                break :blk try s.instantiate.copy(scheme);
            },
        };
        const got = copy orelse return false;
        const wanted = try methodType(s, at);
        if (!try s.unifyQuiet(got, wanted, d.origin)) {
            var namer: Render.Namer = .init(s.cx.scratch);
            defer namer.deinit();
            const shown = try Render.allocType(s.cx.scratch, .{ .store = s.store(), .types = s.cx.types, .interner = s.cx.interner }, &namer, at);
            _ = try d.failText(at, "has its module's `codec`, which is not `⊤ → Codec {s}`: a module's one `codec` is the method of every type the module declares", .{shown});
            return false;
        }
        return true;
    }

    /// A nominal type's constructors (§12.3), each argument read with the
    /// type's parameters bound to `root`'s arguments.
    fn ctorsNode(d: *Derivation, root: Var, type_id: Types.TypeId, slots: []const Var) Error!?u32 {
        const s = d.s;
        const cx = s.cx;
        const entry = cx.types.entry(type_id);
        // An opaque type is derived only inside its own module (§12.2): from
        // anywhere else its constructors would build values that skip the
        // invariant the type exists for.
        if (d.dictOrSet(entry)) return d.failDictOrSet(root, entry);
        if (!d.visible(entry)) {
            return d.failText(root, "is an opaque type of `{s}`, whose constructors this module cannot see: declare `pub codec : ⊤ → Codec {s}` in `{s}`, where `pub codec u = Schema.structural u` reads its shape", .{
                cx.interner.slice(entry.module_name),
                cx.interner.slice(entry.name),
                cx.interner.slice(entry.module_name),
            });
        }
        var ctor_ids: std.ArrayList(u32) = .empty;
        var names: std.ArrayList(Symbol) = .empty;
        if (entry.module == cx.module) {
            const decl = cx.bir.decls[entry.decl.int()];
            var i = decl.ctors_start;
            while (i < decl.ctors_end) : (i += 1) {
                try ctor_ids.append(cx.scratch, i);
                try names.append(cx.scratch, cx.bir.symbol(cx.bir.ctors[i].name));
            }
        } else {
            const iface = cx.iface(entry.module);
            const ti = iface.findType(cx.interner, entry.name) orelse return d.fail(root, "has no constructors in its module's interface");
            const t = iface.types[@backingInt(ti)];
            var i = t.ctors_start;
            while (i < t.ctors_end) : (i += 1) {
                try ctor_ids.append(cx.scratch, i);
                try names.append(cx.scratch, iface.symbol(iface.ctors[i].name));
            }
        }
        var body: std.ArrayList(u32) = .empty;
        try body.append(cx.scratch, @intCast(ctor_ids.items.len));
        for (ctor_ids.items, names.items, 0..) |ctor, name, order| {
            const fty = (try s.instantiate.ctorType(entry.module, ctor, d.origin)) orelse return null;
            const args: []const Var = blk: {
                if (Walk.function(s.store(), fty)) |f| {
                    const params = try cx.scratch.dupe(Var, f.params);
                    if (!try s.unifyQuiet(f.result, root, d.origin)) return d.fail(root, "is not what its constructors build");
                    break :blk params;
                }
                if (!try s.unifyQuiet(fty, root, d.origin)) return d.fail(root, "is not what its constructors build");
                break :blk &.{};
            };
            try body.append(cx.scratch, @backingInt(name));
            try body.append(cx.scratch, @intCast(order));
            try body.append(cx.scratch, @intCast(args.len));
            try d.path.append(cx.scratch, cx.interner.slice(name));
            defer _ = d.path.pop();
            for (args) |arg| {
                const n = (try d.nodeFor(arg, slots, false)) orelse return null;
                try body.append(cx.scratch, n);
            }
        }
        const c = &s.codecs;
        const start: u32 = @intCast(c.words.items.len);
        try c.words.appendSlice(cx.gpa, body.items);
        return try d.add(.{ .tag = .ctors, .a = @backingInt(type_id), .b = start });
    }
};

// ---------------------------------------------------------------------------
// After P4
// ---------------------------------------------------------------------------

/// Every definition's place in key order, which the dispatch table's terms
/// and the plan use (CLAUDE.md rule 5: the order is the keys', never the
/// order the uses were met in).
pub fn sortKeys(c: *State, gpa: Allocator, scratch: Allocator) Error!void {
    const n = c.defs.items.len;
    const by_key = try scratch.alloc(u32, n);
    defer scratch.free(by_key);
    for (by_key, 0..) |*slot, i| slot.* = @intCast(i);
    const Sorter = struct {
        defs: []const Def,
        fn lessThan(ctx: @This(), a: u32, b: u32) bool {
            return std.mem.lessThan(u8, ctx.defs[a].key, ctx.defs[b].key);
        }
    };
    std.mem.sort(u32, by_key, Sorter{ .defs = c.defs.items }, Sorter.lessThan);
    gpa.free(c.order);
    c.order = try gpa.alloc(u32, n);
    for (by_key, 0..) |def, place| c.order[def] = @intCast(place);
}
