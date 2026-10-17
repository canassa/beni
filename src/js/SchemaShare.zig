//! Which validators a build shares across its schemas (`docs/design/
//! schema.md` §6, *Validators shared across schemas*): a failure branch
//! every compiled worker would write in place — the depth bound, a missing
//! key, a required field of a JSON object that is absent, too deep or not
//! the primitive it should be — written once in `core/Schema` and called,
//! but only where that makes the program smaller.
//!
//! Every shared helper is the cold half of a branch. The worker keeps its
//! tests in place, so the success path runs the code it ran before, and
//! calls the helper only to make the issue of a test that failed — which
//! issue it is, `prim`'s order decides, as the branch it replaces decided.
//!
//! A helper costs its own definition once and saves a little at every
//! call, and a call `--release` cannot take back: the helper is another
//! module's value, which its inliner does not reach into. So a helper is
//! shared only when the build's live workers would call it at least
//! `threshold` times. The count is taken after reachability, over the
//! worker sets that survived, so it is the count of what the build writes;
//! the helpers chosen are then roots of the walk (`Emit`), and
//! `SchemaLower` calls a helper exactly where `Share.on` says so.
//!
//! Every answer is a function of the plans and the walk, both input-derived
//! (CLAUDE.md rule 5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const SchemaPlan = @import("../check/SchemaPlan.zig");
const SchemaGraph = @import("SchemaGraph.zig");
const Reach = @import("Reach.zig");

const Op = SchemaGraph.Op;
const PNode = SchemaPlan.NodeIndex;

pub const Helper = enum(u8) {
    /// `compiledDeep`: the depth bound, reached before a descent.
    deep,
    /// `compiledMissing`: a required key that is not there.
    missing,
    /// `badString` … `badFinite`: a required field of a JSON object, absent,
    /// past the depth bound, or not the primitive it should be.
    string,
    int,
    bool,
    float,
    finite,

    pub const count = std.enums.EnumIndexer(Helper).count;

    /// The `core/Schema` value the helper is.
    pub fn coreName(h: Helper) []const u8 {
        return switch (h) {
            .deep => "compiledDeep",
            .missing => "compiledMissing",
            .string => "badString",
            .int => "badInt",
            .bool => "badBool",
            .float => "badFloat",
            .finite => "badFinite",
        };
    }

    /// The fewest calls at which the helper is shared: measured in release
    /// brotli on Conduit and the schema corpus, where a field helper wins
    /// from 4 calls and loses at 3, and the depth bound and the missing key
    /// win from 16 and lose at 12, so 24 leaves them a margin (`schema.md`
    /// §16, *As built — slice B*).
    pub fn threshold(h: Helper) u32 {
        return switch (h) {
            .deep, .missing => 24,
            .string, .int, .bool, .float, .finite => 4,
        };
    }
};

pub const Set = std.EnumSet(Helper);

/// The helpers a build shares.
pub const Share = struct {
    set: Set = .empty,

    pub fn on(s: Share, h: Helper) bool {
        return s.set.contains(h);
    }
};

/// The helper a worker of `op` could call for record field `f`, whose
/// external key is `key`: a required field of what `JSON.parse` made, read
/// by value (`SchemaLower`'s `readsByValue`), whose value is a primitive
/// with a helper.
pub fn fieldHelper(plan: *const SchemaPlan, op: Op, f: SchemaPlan.Field, key: []const u8) ?Helper {
    if (op != .parse or f.optional or isPrototypeKey(key)) return null;
    if (SchemaGraph.tag(plan, f.child) != .primitive) return null;
    return switch (std.enums.fromInt(SchemaPlan.Primitive, SchemaGraph.lhs(plan, f.child)) orelse return null) {
        .string => .string,
        .int => .int,
        .bool => .bool,
        .float => .float,
        .finite_float => .finite,
        .null, .value, .char, .int32, .never => null,
    };
}

/// The helper record field `f` calls in a build that shares `share`.
pub fn fieldCall(share: Share, plan: *const SchemaPlan, op: Op, f: SchemaPlan.Field, key: []const u8) ?Helper {
    const h = fieldHelper(plan, op, f, key) orelse return null;
    return if (share.on(h)) h else null;
}

/// What the build shares: every helper its live workers would call at
/// least `threshold` times. The field helpers are decided first, then the
/// depth bound and the missing key over the branches no field helper took.
/// A field helper calls `compiledDeep` and `compiledMissing` itself, so
/// once one is shared those two are paid for and every other branch calls
/// them too.
pub fn decide(scratch: Allocator, sg: *const SchemaGraph, live: *const Reach.Result) Allocator.Error!Share {
    var share: Share = .{};
    var fields: [Helper.count]u32 = @splat(0);
    try count(scratch, sg, live, true, share, &fields);
    for ([_]Helper{ .string, .int, .bool, .float, .finite }) |h| {
        if (fields[@backingInt(h)] >= h.threshold()) share.set.insert(h);
    }
    var branches: [Helper.count]u32 = @splat(0);
    try count(scratch, sg, live, false, share, &branches);
    const any_field = share.set.count() != 0;
    for ([_]Helper{ .deep, .missing }) |h| {
        if (any_field or branches[@backingInt(h)] >= h.threshold()) share.set.insert(h);
    }
    return share;
}

/// The walk's roots the shared helpers are: `core/Schema`'s declarations.
pub fn roots(scratch: Allocator, sg: *const SchemaGraph, share: Share) Allocator.Error![]const Reach.Node {
    var out: std.ArrayList(Reach.Node) = .empty;
    const core = sg.graph.lookup(.core, InternPool.WellKnown.Schema.symbol()) orelse return out.items;
    const bir = sg.birOf(core);
    var it = share.set.iterator();
    while (it.next()) |h| {
        const symbol = sg.interner.find(h.coreName()) orelse continue;
        for (bir.decls, 0..) |d, i| {
            if (!d.kind.isValue() or bir.symbol(d.name) != symbol) continue;
            try out.append(scratch, .{ .module = core, .kind = .decl, .index = @intCast(i) });
            break;
        }
    }
    return out.items;
}

/// The calls of each helper the live workers would make, as `SchemaLower`
/// writes them given what `share` already shares: with `fields`, each field
/// helper's; without, per record field no field helper takes, per list and
/// per tagged payload the depth bound before the descent, and per required
/// field and per discriminator of a host input the missing key.
fn count(scratch: Allocator, sg: *const SchemaGraph, live: *const Reach.Result, fields: bool, share: Share, out: *[Helper.count]u32) Allocator.Error!void {
    for (0..sg.graph.count()) |mi| {
        const m: Graph.Index = @fromBackingInt(@intCast(@as(u32, @intCast(mi))));
        const plan = sg.planOf(m);
        // The declarations' definitions, then the derived codecs' (schema.md
        // §12.10), whose `decode` and `encode` write no worker of their own.
        for ([_][]const SchemaPlan.Definition{ plan.definitions, plan.codecs }) |defs| for (defs) |*d| {
            const decl = @backingInt(d.decl);
            var nodes: std.ArrayList(PNode) = .empty;
            var walked = false;
            for ([_]Op{ .parse, .print, .decode, .encode, .read, .write }) |op| {
                if (!live.schema(m, decl, SchemaGraph.Member.worker(op))) continue;
                if (sg.hostAliased(.{ .module = m, .decl = decl }, SchemaGraph.Member.worker(op)) != null) continue;
                if (!walked) {
                    try SchemaGraph.subtree(plan, scratch, d.root, &nodes);
                    walked = true;
                }
                for (nodes.items) |n| switch (SchemaGraph.tag(plan, n)) {
                    .record => for (SchemaGraph.fields(plan, n)) |f| {
                        const key = SchemaGraph.literal(plan, f.external);
                        if (fields) {
                            if (fieldHelper(plan, op, f, key)) |h| out[@backingInt(h)] += 1;
                        } else if (fieldCall(share, plan, op, f, key) == null) {
                            out[@backingInt(Helper.deep)] += 1;
                            if (op.hostIn() and !f.optional) out[@backingInt(Helper.missing)] += 1;
                        }
                    },
                    .list => if (!fields) {
                        out[@backingInt(Helper.deep)] += 1;
                    },
                    .tagged => if (!fields) {
                        for (SchemaGraph.variants(plan, n)) |vi| {
                            if (vi >= plan.variants.len or plan.variants[vi].payload == .none) continue;
                            out[@backingInt(Helper.deep)] += 1;
                        }
                        if (op.hostIn()) out[@backingInt(Helper.missing)] += 1;
                    },
                    // A derived codec's: the depth bound before each
                    // element, and before a constructor's arguments.
                    .tuple => if (!fields) {
                        out[@backingInt(Helper.deep)] += @intCast(SchemaGraph.elements(plan, n).len);
                    },
                    .constructors => if (!fields) {
                        for (SchemaGraph.ctors(plan, n)) |c| {
                            const arity = SchemaGraph.ctorArgs(plan, c).len;
                            if (arity == 0) continue;
                            out[@backingInt(Helper.deep)] += 1;
                            if (arity > 1) out[@backingInt(Helper.deep)] += @intCast(arity);
                        }
                    },
                    else => {},
                };
            }
        };
    }
}

/// The names a standard `Object.prototype` holds: a read of one finds it on
/// any object, so every reading runner tests it as an own key. The one list:
/// core's `Schema.prototypeKey` spells the same names, which a test below
/// keeps equal.
pub const prototype_keys = [_][]const u8{
    "__proto__",            "__defineGetter__", "__defineSetter__", "__lookupGetter__",
    "__lookupSetter__",     "constructor",      "hasOwnProperty",   "isPrototypeOf",
    "propertyIsEnumerable", "toLocaleString",   "toString",         "valueOf",
};

/// Whether `key` is one of `prototype_keys`.
pub fn isPrototypeKey(key: []const u8) bool {
    for (prototype_keys) |name| if (std.mem.eql(u8, name, key)) return true;
    return false;
}

test "a key Object.prototype holds is read as an own key, and no other" {
    try std.testing.expect(isPrototypeKey("toString"));
    try std.testing.expect(isPrototypeKey("__proto__"));
    try std.testing.expect(!isPrototypeKey("user-id"));
    try std.testing.expect(!isPrototypeKey("toJSON"));
}

test "core's Schema.prototypeKey lists exactly prototype_keys" {
    const core = @import("core_package");
    const source = for (core.files) |f| {
        if (std.mem.eql(u8, f.rel, "Schema.beni")) break f.source;
    } else return error.NoSchemaModule;
    const head = "\nprototypeKey k =\n";
    const at = std.mem.indexOf(u8, source, head) orelse return error.NoPrototypeKey;
    const body_start = at + head.len;
    // The body ends at the first blank line.
    const body_end = std.mem.indexOfPos(u8, source, body_start, "\n\n") orelse source.len;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.testing.allocator);
    var rest = source[body_start..body_end];
    while (std.mem.indexOfScalar(u8, rest, '"')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open + 1, '"') orelse return error.Unclosed;
        try names.append(std.testing.allocator, rest[open + 1 .. close]);
        rest = rest[close + 1 ..];
    }
    try std.testing.expectEqual(prototype_keys.len, names.items.len);
    for (prototype_keys, names.items) |want, got| try std.testing.expectEqualStrings(want, got);
}
