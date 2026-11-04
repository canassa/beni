//! Checked existential storage retains the complete callback shape. A profile
//! is a regular graph, so callbacks in arguments/results keep separate roles
//! and recursive Any values do not require a depth limit or a flattened rung.
const std = @import("std");
const Effects = @import("Effects.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Var = Effects.Var;
const Allocator = std.mem.Allocator;
const none = std.math.maxInt(u32);

pub const Edge = struct { name: []const u8, child: u32 };
pub const Node = struct {
    parent: u32,
    variable: Var,
    effect: bool = false,
    edges: std.ArrayList(Edge) = .empty,
};
const Value = struct { variable: Var, node: u32, built: bool = false };
const Variable = struct { variable: Var, node: u32 };
const Image = struct { record: u32, source: u32, target: u32 };
pub const State = struct {
    nodes: std.ArrayList(Node) = .empty,
    values: std.ArrayList(Value) = .empty,
    variables: std.ArrayList(Variable) = .empty,
    images: std.ArrayList(Image) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    changed: bool = false,

    pub fn deinit(s: *State, gpa: Allocator) void {
        for (s.nodes.items) |*node| node.edges.deinit(gpa);
        for (s.names.items) |name| gpa.free(name);
        s.nodes.deinit(gpa);
        s.values.deinit(gpa);
        s.variables.deinit(gpa);
        s.images.deinit(gpa);
        s.names.deinit(gpa);
    }
};

fn root(e: *const Effects, id: u32) u32 {
    var at = id;
    while (e.stored.nodes.items[at].parent != at) at = e.stored.nodes.items[at].parent;
    return at;
}

fn meta(e: *const Effects, variable: Var) ?u32 {
    const list = e.stored.variables.items;
    var lo: usize = 0;
    var hi = list.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (list[mid].variable.int() < variable.int()) lo = mid + 1 else hi = mid;
    }
    return if (lo < list.len and list[lo].variable == variable) root(e, list[lo].node) else null;
}

pub fn canonical(e: *const Effects, variable: Var) Var {
    if (e.stored.variables.items.len == 0 or variable.int() < e.stored.variables.items[0].variable.int()) return variable;
    const id = meta(e, variable) orelse return variable;
    return e.stored.nodes.items[id].variable;
}

fn make(e: *Effects, effect: bool) Effects.Error!u32 {
    const id: u32 = @intCast(e.stored.nodes.items.len);
    const v = try e.store.fresh(.{ .flex = .{} }, TypeStore.generalized);
    try e.stored.nodes.append(e.gpa, .{ .parent = id, .variable = v, .effect = effect });
    try e.stored.variables.append(e.gpa, .{ .variable = v, .node = id });
    e.stored.changed = true;
    return id;
}

fn sameValue(e: *Effects, a: Var, b: Var) bool {
    const x, _ = e.store.resolved(a);
    const y, _ = e.store.resolved(b);
    if (a == b) return true;
    if (x == y) return e.realmCarrier(x) or switch (e.store.content(x)) {
        .structure => |shape| shape == .record or shape == .tuple,
        else => false,
    };
    if (e.solved.slot.len == 0) return false;
    if (!@import("Realms.zig").stored(e, x) and !@import("Realms.zig").unknown(e.store, x)) return false;
    if (!@import("Realms.zig").stored(e, y) and !@import("Realms.zig").unknown(e.store, y)) return false;
    const xn = e.nodeOf(x) orelse return false;
    const yn = e.nodeOf(y) orelse return false;
    return xn == yn;
}

fn valueIndex(e: *Effects, variable: Var) ?usize {
    for (e.stored.values.items, 0..) |entry, i| if (sameValue(e, entry.variable, variable)) return i;
    return null;
}

fn value(e: *Effects, variable: Var) Effects.Error!u32 {
    if (meta(e, variable)) |id| return id;
    if (valueIndex(e, variable)) |i| return root(e, e.stored.values.items[i].node);
    const id = try make(e, false);
    try e.stored.values.append(e.gpa, .{ .variable = variable, .node = id });
    return id;
}

fn child(e: *Effects, owner: u32, name: []const u8, effect: bool) Effects.Error!u32 {
    const id = root(e, owner);
    for (e.stored.nodes.items[id].edges.items) |item| {
        if (std.mem.eql(u8, item.name, name)) return root(e, item.child);
    }
    const fresh = try make(e, effect);
    const owned = try e.gpa.dupe(u8, name);
    try e.stored.names.append(e.gpa, owned);
    try e.stored.nodes.items[id].edges.append(e.gpa, .{ .name = owned, .child = fresh });
    return fresh;
}

fn bidirectional(e: *Effects, a: Var, b: Var) Effects.Error!void {
    const x = try e.nodeFor(a);
    const y = try e.nodeFor(b);
    if (x == y) return;
    try edge(e, x, y);
    try edge(e, y, x);
}

fn edge(e: *Effects, a: u32, b: u32) Effects.Error!void {
    var at = e.solved.head.items[a];
    while (at != none) : (at = e.solved.next.items[at]) {
        if (e.solved.to.items[at] == b and e.solved.origin.items[at] == none) return;
    }
    try e.edgeNodes(a, b, none);
}

fn merge(e: *Effects, left: u32, right: u32) Effects.Error!void {
    var pending: std.ArrayList([2]u32) = .empty;
    defer pending.deinit(e.gpa);
    try pending.append(e.gpa, .{ left, right });
    while (pending.pop()) |pair| {
        const x = root(e, pair[0]);
        const y = root(e, pair[1]);
        if (x == y) continue;
        const a = @min(x, y);
        const b = @max(x, y);
        // Keep old graph seats connected when a later signature copy joins
        // two profile nodes whose rungs have already entered the graph.
        if (e.solved.slot.len != 0) try bidirectional(e, e.stored.nodes.items[a].variable, e.stored.nodes.items[b].variable);
        e.stored.nodes.items[b].parent = a;
        e.stored.nodes.items[a].effect = e.stored.nodes.items[a].effect or e.stored.nodes.items[b].effect;
        e.stored.changed = true;
        const count = e.stored.nodes.items[b].edges.items.len;
        for (0..count) |i| {
            const incoming = e.stored.nodes.items[b].edges.items[i];
            const existing = for (e.stored.nodes.items[a].edges.items) |old| {
                if (std.mem.eql(u8, old.name, incoming.name)) break old.child;
            } else null;
            if (existing) |old| {
                try pending.append(e.gpa, .{ old, incoming.child });
            } else try e.stored.nodes.items[a].edges.append(e.gpa, incoming);
        }
    }
}

fn attach(e: *Effects, profile: u32, variable: Var) Effects.Error!void {
    const id = root(e, profile);
    if (e.realmCarrier(e.store.find(variable))) try bidirectional(e, e.stored.nodes.items[id].variable, variable);
}

fn build(e: *Effects, index: usize) Effects.Error!void {
    if (e.stored.values.items[index].built) return;
    e.stored.values.items[index].built = true;
    const variable = e.stored.values.items[index].variable;
    const holder = root(e, e.stored.values.items[index].node);
    const r, _ = e.store.resolved(variable);
    const content = e.store.content(r);
    if (@import("Realms.zig").stored(e, r) or @import("Realms.zig").unknown(e.store, r)) return;
    if (content != .structure) return;
    var buffer: [64]u8 = undefined;
    const parent = switch (content.structure) {
        .func => blk: {
            const function = Walk.function(e.store, r).?;
            const name = std.fmt.bufPrint(&buffer, "f{d}", .{function.params.len}) catch unreachable;
            const node = try child(e, holder, name, true);
            try attach(e, node, r);
            break :blk node;
        },
        .app => |a| blk: {
            if (a.type == .none) return;
            const identity = e.types.entry(a.type);
            const name = try std.fmt.allocPrint(e.gpa, "n{s}:{s}.{s}", .{ @tagName(identity.package), e.interner.slice(identity.module_name), e.interner.slice(identity.name) });
            defer e.gpa.free(name);
            const node = try child(e, holder, name, e.carries(r));
            try attach(e, node, r);
            break :blk node;
        },
        .record => try child(e, holder, "o", false),
        .tuple => blk: {
            const name = std.fmt.bufPrint(&buffer, "t{d}", .{Walk.positions(e.store, r).len}) catch unreachable;
            break :blk try child(e, holder, name, false);
        },
        .unit, .empty_record => return,
    };
    var ordinal: u32 = 0;
    while (Walk.stepped(e.store, r, ordinal)) |step| : (ordinal += 1) {
        const name = switch (step.kind) {
            .param => std.fmt.bufPrint(&buffer, "p{d}", .{step.index}) catch unreachable,
            .result => "r",
            .argument => std.fmt.bufPrint(&buffer, "a{d}", .{step.index}) catch unreachable,
            .element => std.fmt.bufPrint(&buffer, "e{d}", .{step.index}) catch unreachable,
            .field => try std.fmt.allocPrint(e.gpa, "k{s}", .{e.interner.slice(@fromBackingInt(step.index))}),
            .extension => "x",
            .expansion => unreachable, // resolved() read through aliases above.
        };
        defer if (step.kind == .field) e.gpa.free(name);
        try merge(e, try child(e, parent, name, false), try value(e, step.v));
    }
}

pub fn seed(e: *Effects, schemes: []const Var.Optional) Effects.Error!void {
    if (e.storage_pack) |decl| if (schemes[decl].unwrap()) |scheme| {
        const f = Walk.function(e.store, scheme) orelse return;
        try merge(e, try value(e, f.params[0]), try value(e, f.result));
    };
    for ([_]?u32{ e.storage_unpack, e.storage_unpack_opt }) |operation| if (operation) |decl| if (schemes[decl].unwrap()) |scheme| {
        const f = Walk.function(e.store, scheme) orelse return;
        const args = Walk.positions(e.store, f.result);
        if (args.len == 1) try merge(e, try value(e, f.params[0]), try value(e, args[0]));
    };
}

fn remember(e: *Effects, record: u32, source: u32, target: u32) Effects.Error!void {
    for (e.stored.images.items) |image| if (image.record == record and root(e, image.source) == root(e, source)) {
        try merge(e, image.target, target);
        return;
    };
    try e.stored.images.append(e.gpa, .{ .record = record, .source = source, .target = target });
}

fn clone(e: *Effects, record: u32, source: u32, target: u32) Effects.Error!void {
    var pending: std.ArrayList([2]u32) = .empty;
    defer pending.deinit(e.gpa);
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(e.gpa);
    try pending.append(e.gpa, .{ source, target });
    while (pending.pop()) |pair| {
        const from = root(e, pair[0]);
        const to = root(e, pair[1]);
        try remember(e, record, from, to);
        if (std.mem.indexOfScalar(u32, seen.items, from) != null) continue;
        try seen.append(e.gpa, from);
        const count = e.stored.nodes.items[from].edges.items.len;
        for (0..count) |i| {
            const item = e.stored.nodes.items[from].edges.items[i];
            const original = root(e, item.child);
            const copied = try child(e, to, item.name, e.stored.nodes.items[original].effect);
            try pending.append(e.gpa, .{ original, copied });
        }
    }
}

/// All shapes are prepared before summary solving, including aliases made
/// by imported signature sites and each own scheme instantiation.
pub fn prepare(e: *Effects) Effects.Error!void {
    if (e.stored.nodes.items.len == 0) return;
    while (true) {
        e.stored.changed = false;
        const values_count = e.stored.values.items.len;
        for (0..values_count) |i| for (i + 1..values_count) |j| {
            if (sameValue(e, e.stored.values.items[i].variable, e.stored.values.items[j].variable)) try merge(e, e.stored.values.items[i].node, e.stored.values.items[j].node);
        };
        var vi: usize = 0;
        while (vi < e.stored.values.items.len) : (vi += 1) try build(e, vi);
        const count = e.stored.variables.items.len;
        for (0..count) |i| {
            const a = e.solved.nodeIfAny(e.store.find(e.stored.variables.items[i].variable)) orelse continue;
            for (i + 1..count) |j| {
                const b = e.solved.nodeIfAny(e.store.find(e.stored.variables.items[j].variable)) orelse continue;
                if (e.solved.find(a) == e.solved.find(b)) try merge(e, e.stored.variables.items[i].node, e.stored.variables.items[j].node);
            }
        }
        for (e.records.items) |record| {
            for (e.pairs.items[record.start..][0..record.len]) |pair| {
                const index = valueIndex(e, pair.a) orelse continue;
                const from = e.stored.values.items[index].node;
                const to = try value(e, pair.b);
                try clone(e, record.start, from, to);
            }
        }
        if (!e.stored.changed) break;
    }
    for (e.stored.nodes.items, 0..) |node, i| {
        if (root(e, @intCast(i)) == i) _ = try e.nodeFor(node.variable);
    }
}

pub fn appendNodes(e: *Effects, variable: Var, out: *std.ArrayList(u32), allocator: Allocator) Effects.Error!void {
    const index = valueIndex(e, variable) orelse return;
    var pending: std.ArrayList(u32) = .empty;
    defer pending.deinit(allocator);
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(allocator);
    try pending.append(allocator, e.stored.values.items[index].node);
    while (pending.pop()) |id| {
        const at = root(e, id);
        if (std.mem.indexOfScalar(u32, seen.items, at) != null) continue;
        try seen.append(allocator, at);
        const node = try e.nodeFor(e.stored.nodes.items[at].variable);
        if (std.mem.indexOfScalar(u32, out.items, node) == null) try out.append(allocator, node);
        for (e.stored.nodes.items[at].edges.items) |item| try pending.append(allocator, item.child);
    }
}

pub fn images(e: *Effects, record: Effects.Record, node: u32, out: *std.ArrayList(Var), allocator: Allocator) Effects.Error!void {
    for (e.pairs.items[record.start..][0..record.len]) |pair| {
        if (e.nodeOf(pair.a) == node) try out.append(allocator, pair.b);
    }
    for (e.stored.images.items) |image| {
        if (image.record != record.start) continue;
        const source = root(e, image.source);
        if (e.nodeOf(e.stored.nodes.items[source].variable) != node) continue;
        const target = root(e, image.target);
        const variable = e.stored.nodes.items[target].variable;
        if (std.mem.indexOfScalar(Var, out.items, variable) == null) try out.append(allocator, variable);
    }
}

pub const Site = struct { variable: Var, key: []const u8 };
pub fn sites(e: *Effects, variable: Var, out: *std.ArrayList(Site), allocator: Allocator) Effects.Error!void {
    const index = valueIndex(e, variable) orelse return;
    const Item = struct { node: u32, key: []const u8 };
    var pending: std.ArrayList(Item) = .empty;
    defer pending.deinit(allocator);
    var seen: std.ArrayList(u32) = .empty;
    defer seen.deinit(allocator);
    try pending.append(allocator, .{ .node = e.stored.values.items[index].node, .key = "" });
    while (pending.pop()) |item| {
        const id = root(e, item.node);
        try out.append(allocator, .{ .variable = e.stored.nodes.items[id].variable, .key = item.key });
        if (std.mem.indexOfScalar(u32, seen.items, id) != null) continue;
        try seen.append(allocator, id);
        const edges = try allocator.dupe(Edge, e.stored.nodes.items[id].edges.items);
        defer allocator.free(edges);
        std.mem.sort(Edge, edges, {}, struct {
            fn less(_: void, a: Edge, b: Edge) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        var i = edges.len;
        while (i > 0) {
            i -= 1;
            const key = try std.mem.concat(allocator, u8, &.{ item.key, edges[i].name, "\x00" });
            try pending.append(allocator, .{ .node = edges[i].child, .key = key });
        }
    }
}

pub fn follow(e: *Effects, owner: Var, key: []const u8) Effects.Error!Var {
    var at = try value(e, owner);
    var names = std.mem.splitScalar(u8, key, 0);
    while (names.next()) |name| {
        if (name.len == 0) continue;
        at = try child(e, at, name, name[0] == 'f' or name[0] == 'n');
    }
    return e.stored.nodes.items[root(e, at)].variable;
}

pub fn appendSchemeNodes(e: *Effects, scheme: Var, out: *std.ArrayList(u32), allocator: Allocator) Effects.Error!void {
    if (e.stored.values.items.len == 0) return;
    var pending: std.ArrayList(Var) = .empty;
    defer pending.deinit(allocator);
    try pending.append(allocator, scheme);
    const mark = e.store.nextMark();
    while (pending.pop()) |v| {
        const r = e.store.find(v);
        if (e.store.mark(r) == mark) continue;
        e.store.setMark(r, mark);
        try appendNodes(e, r, out, allocator);
        var k: u32 = 0;
        while (Walk.stepped(e.store, r, k)) |item| : (k += 1) try pending.append(allocator, item.v);
        switch (e.store.content(r)) {
            .flex, .rigid => |flags| {
                const constraints = Walk.constraints(flags);
                for (0..constraints.count(e.store)) |i| try pending.append(allocator, constraints.at(e.store, @intCast(i)).fn_var);
            },
            else => {},
        }
    }
}

pub fn followSite(e: *Effects, owner: Var, words: []const u32) Effects.Error!Var {
    const len = words[0] & 0x0fffffff;
    const bytes = try e.gpa.alloc(u8, len);
    defer e.gpa.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(words[1 + i / 4] >> @as(u5, @intCast((i % 4) * 8)));
    return follow(e, owner, bytes);
}

pub fn foreignSeats(e: *Effects, scheme: Var, nodes: *std.ArrayList(u32), positive: *std.ArrayList(bool), evidence: *std.ArrayList(bool), sync: *std.ArrayList(bool), allocator: Allocator) Effects.Error!void {
    if (e.stored.nodes.items.len == 0) return;
    var profiles: std.ArrayList(u32) = .empty;
    defer profiles.deinit(allocator);
    try appendSchemeNodes(e, scheme, &profiles, allocator);
    for (profiles.items) |node| {
        if (std.mem.indexOfScalar(u32, nodes.items, node) != null) continue;
        try nodes.append(allocator, node);
        try positive.append(allocator, false);
        try evidence.append(allocator, false);
        try sync.append(allocator, false);
    }
}
