//! Structural HostFree facts, computed only under the internal rollout option.
//! Nominal representations use monotone summaries of held parameters and two
//! flags. Recursive types never expand into an unbounded family of applications.
const std = @import("std");
const Context = @import("Context.zig");
const Types = @import("Types.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Operations = @import("../native/Operations.zig");
const Allocator = std.mem.Allocator;
const Var = TypeStore.Var;
const TypeId = Types.TypeId;
const native: u8 = 1;
const callable: u8 = 2;
pub const Offense = struct { path: []const u8, kind: enum { callable, native } };
const Range = struct { start: u32 = 0, len: u32 = 0 };
const Info = struct { flags: u8 = 0, native_type: TypeId = .none, parameters: Range = .{}, body: Range = .{} };
const Frame = struct { v: Var, path: []const u8 };

const Environment = struct {
    scratch: Allocator,
    store: *TypeStore,
    types: *const Types,
    graph: *const @import("../resolve/Graph.zig"),
    artifacts: *const @import("../Artifacts.zig"),
    interner: *const @import("../InternPool.zig").Global,
    interfaces: []const @import("../resolve/Interface.zig"),
};
pub const Facts = struct {
    info: []const Info = &.{},
    held: []const bool = &.{},
    pub fn deinit(f: *Facts, gpa: Allocator) void {
        gpa.free(f.info);
        gpa.free(f.held);
        f.* = .{};
    }
    pub fn key(f: Facts, a: Allocator, id: TypeId) Allocator.Error![]const u8 {
        if (id == .none or id.int() >= f.info.len) return &.{};
        const info = f.info[id.int()];
        const bytes = try a.alloc(u8, info.parameters.len + 1);
        bytes[0] = info.flags;
        for (f.held[info.parameters.start..][0..info.parameters.len], bytes[1..]) |held, *byte| byte.* = @intFromBool(held);
        return bytes;
    }
};
/// Prepared before the checker DAG, like TypeFacts: every module subsequently
/// reads immutable facts, never another module's source or a mutable type store.
pub fn build(gpa: Allocator, scratch: Allocator, types: *const Types, graph: *const @import("../resolve/Graph.zig"), artifacts: *const @import("../Artifacts.zig"), interfaces: []const @import("../resolve/Interface.zig"), interner: *const @import("../InternPool.zig").Global) Allocator.Error!Facts {
    var store: TypeStore = .init(scratch);
    defer store.deinit();
    const state = try State.init(.{ .scratch = scratch, .store = &store, .types = types, .graph = graph, .artifacts = artifacts, .interfaces = interfaces, .interner = interner });
    const info = try gpa.dupe(Info, state.info);
    errdefer gpa.free(info);
    for (info) |*row| row.body = .{};
    return .{ .info = info, .held = try gpa.dupe(bool, state.held) };
}
pub const State = struct {
    cx: Environment,

    info: []Info,
    held: []bool,
    parameters: []Var,
    bodies: []Var,

    fn init(cx: Environment) Allocator.Error!State {
        const a = cx.scratch;
        const store = cx.store;
        const info = try a.alloc(Info, cx.types.count());
        @memset(info, .{});
        var parameters: std.ArrayList(Var) = .empty;
        var bodies: std.ArrayList(Var) = .empty;
        for (cx.types.entries, info, 0..) |entry, *out, i| {
            const bir = cx.artifacts.bir(cx.graph.moduleFile(entry.module));
            const declaration = bir.decl(entry.decl);
            out.parameters = .{ .start = @intCast(parameters.items.len), .len = entry.arity };
            var builder = Types.Builder.init(store, cx.types, cx.graph, cx.artifacts, entry.module, bir, .flex, TypeStore.generalized, a, cx.interner);
            defer builder.deinit();
            builder.interfaces = cx.interfaces;
            for (bir.declTypeParams(declaration)) |name| {
                const v = try store.fresh(.{ .flex = .{} }, TypeStore.generalized);
                try parameters.append(a, v);
                try builder.bind(name, v);
            }
            // Schema endpoint representations contain the schema's data and
            // parameters, never an untyped host object or callback.
            if (entry.schema_endpoint) continue;
            if (entry.kind == .foreign) {
                if (!plainForeign(cx, entry)) {
                    out.flags = native;
                    out.native_type = @fromBackingInt(@intCast(i));
                }
                continue;
            }
            const start: u32 = @intCast(bodies.items.len);
            if (entry.kind == .alias) {
                if (declaration.annotation.unwrap()) |body| try bodies.append(a, try builder.read(body));
            } else for (bir.declCtors(declaration)) |ctor| {
                for (bir.extraSlice(.{ .start = ctor.args_start, .end = ctor.args_end }, @import("../bir/Bir.zig").Inst.Index)) |body| try bodies.append(a, try builder.read(body));
            }
            out.body = .{ .start = start, .len = @intCast(bodies.items.len - start) };
        }
        var state: State = .{ .cx = cx, .info = info, .held = try a.alloc(bool, parameters.items.len), .parameters = parameters.items, .bodies = bodies.items };
        @memset(state.held, false);
        // Trusted foreign data storage keeps its type parameters. Unknown
        // foreign representations are quarantined, rather than assumed plain.
        for (cx.types.entries, info) |entry, row| if (entry.kind == .foreign or entry.schema_endpoint) {
            @memset(state.held[row.parameters.start..][0..row.parameters.len], true);
        };
        var edges: std.ArrayList([2]u32) = .empty;
        var stack: std.ArrayList(Var) = .empty;
        for (info, 0..) |row, i| {
            stack.clearRetainingCapacity();
            try stack.appendSlice(a, state.bodies[row.body.start..][0..row.body.len]);
            const mark = store.nextMark();
            while (stack.pop()) |v| {
                const root, const content = store.resolved(v);
                if (store.mark(root) == mark) continue;
                store.setMark(root, mark);
                if (content == .structure and content.structure == .app and content.structure.app.type != .none) try edges.append(a, .{ content.structure.app.type.int(), @intCast(i) });
                var k: u32 = 0;
                while (Walk.child(store, root, k, .payload)) |child| : (k += 1) try stack.append(a, child);
            }
        }
        const starts = try a.alloc(u32, info.len + 1);
        @memset(starts, 0);
        for (edges.items) |edge| starts[edge[0] + 1] += 1;
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const positions = try a.dupe(u32, starts[0..info.len]);
        const dependents = try a.alloc(u32, edges.items.len);
        for (edges.items) |edge| {
            dependents[positions[edge[0]]] = edge[1];
            positions[edge[0]] += 1;
        }
        var work: std.ArrayList(u32) = .empty;
        const queued = try a.alloc(bool, info.len);
        @memset(queued, true);
        for (0..info.len) |i| try work.append(a, @intCast(i));
        while (work.pop()) |i| {
            queued[i] = false;
            const row = &info[i];
            const used = try a.alloc(bool, row.parameters.len);
            @memset(used, false);
            const value = try state.evaluate(state.bodies[row.body.start..][0..row.body.len], state.parameters[row.parameters.start..][0..row.parameters.len], used);
            var changed = value.flags & ~row.flags != 0;
            row.flags |= value.flags;
            if (value.native_type != .none and (row.native_type == .none or value.native_type.int() < row.native_type.int())) row.native_type = value.native_type;
            for (state.held[row.parameters.start..][0..row.parameters.len], used) |*held, yes| if (yes and !held.*) {
                held.* = true;
                changed = true;
            };
            if (changed) for (dependents[starts[i]..starts[i + 1]]) |dependent| {
                if (queued[dependent]) continue;
                queued[dependent] = true;
                try work.append(a, dependent);
            };
        }
        return state;
    }

    pub fn forContext(cx: *const Context) State {
        return .{
            .cx = .{ .scratch = cx.scratch, .store = cx.store, .types = cx.types, .graph = cx.graph, .artifacts = cx.artifacts, .interner = cx.interner, .interfaces = cx.interfaces },
            .info = @constCast(cx.types.host_free.info),
            .held = @constCast(cx.types.host_free.held),
            .parameters = &.{},
            .bodies = &.{},
        };
    }
    fn evaluate(s: *const State, roots: []const Var, parameters: []const Var, used: []bool) Allocator.Error!Info {
        const store = s.cx.store;
        const a = s.cx.scratch;
        var todo: std.ArrayList(Var) = .empty;
        try todo.appendSlice(a, roots);
        var result: Info = .{};
        const mark = store.nextMark();
        while (todo.pop()) |v| {
            const root, const content = store.resolved(v);
            if (store.mark(root) == mark) continue;
            store.setMark(root, mark);
            switch (content) {
                .flex, .rigid => {
                    for (parameters, 0..) |p, i| if (store.find(p) == root) {
                        used[i] = true;
                    };
                },
                .err => {},
                .alias => unreachable,
                .structure => |st| switch (st) {
                    .func => result.flags |= callable,
                    .app => |app| {
                        if (app.type == .none) continue;
                        const info = s.info[app.type.int()];
                        result.flags |= info.flags;
                        if (info.native_type != .none and (result.native_type == .none or info.native_type.int() < result.native_type.int())) result.native_type = info.native_type;
                        for (Walk.positions(store, root), 0..) |arg, i| if (i < info.parameters.len and s.held[info.parameters.start + i]) try todo.append(a, arg);
                    },
                    else => {
                        var i: u32 = 0;
                        while (Walk.child(store, root, i, .payload)) |child| : (i += 1) try todo.append(a, child);
                    },
                },
            }
        }
        return result;
    }

    pub fn inspect(s: *const State, value: Var) Allocator.Error!?Offense {
        const a = s.cx.scratch;
        const store = s.cx.store;
        var todo: std.ArrayList(Frame) = .empty;
        try todo.append(a, .{ .v = value, .path = "value" });
        const mark = store.nextMark();
        while (todo.pop()) |frame| {
            const root, const content = store.resolved(frame.v);
            if (store.mark(root) == mark) continue;
            store.setMark(root, mark);
            switch (content) {
                .flex, .rigid, .err => {}, // Retained quantified obligations.
                .alias => unreachable,
                .structure => |st| switch (st) {
                    .func => return .{ .kind = .callable, .path = frame.path },
                    .app => |app| {
                        if (app.type == .none) continue;
                        const entry = s.cx.types.entry(app.type);
                        const row = s.info[app.type.int()];
                        var path = try std.fmt.allocPrint(a, "{s} → {s}.{s}", .{ frame.path, s.cx.interner.slice(entry.module_name), s.cx.interner.slice(entry.name) });
                        if (row.flags != 0) {
                            if (row.native_type != .none and row.native_type != app.type) {
                                const leaf = s.cx.types.entry(row.native_type);
                                path = try std.fmt.allocPrint(a, "{s} → {s}.{s}", .{ path, s.cx.interner.slice(leaf.module_name), s.cx.interner.slice(leaf.name) });
                            }
                            return .{ .kind = if (row.flags & native != 0) .native else .callable, .path = path };
                        }
                        for (Walk.positions(store, root), 0..) |arg, i| if (i < row.parameters.len and s.held[row.parameters.start + i]) try todo.append(a, .{ .v = arg, .path = path });
                    },
                    .record => |record| {
                        const fields = try a.dupe(TypeStore.Field, Walk.recordFields(store, record));
                        try TypeStore.sortByText(TypeStore.Field, a, s.cx.interner, fields);
                        for (fields) |field| try todo.append(a, .{ .v = field.value, .path = try std.fmt.allocPrint(a, "{s}.{s}", .{ frame.path, s.cx.interner.slice(field.name) }) });
                        try todo.append(a, .{ .v = Walk.recordExtension(record), .path = frame.path });
                    },
                    else => {
                        var i: u32 = 0;
                        while (Walk.child(store, root, i, .payload)) |child| : (i += 1) try todo.append(a, .{ .v = child, .path = frame.path });
                    },
                },
            }
        }
        return null;
    }
};

fn plainForeign(cx: Environment, entry: Types.Entry) bool {
    if (entry.package != .core) return false;
    const module = cx.interner.slice(entry.module_name);
    const name = cx.interner.slice(entry.name);
    if (Operations.nativeModule(module)) return false;
    if (std.mem.eql(u8, module, "Basics")) return std.mem.eql(u8, name, "Int") or std.mem.eql(u8, name, "Float");
    if (std.mem.eql(u8, module, "String")) return std.mem.eql(u8, name, "String");
    if (std.mem.eql(u8, module, "Char")) return std.mem.eql(u8, name, "Char");
    if (std.mem.eql(u8, module, "Int32")) return std.mem.eql(u8, name, "Int32");
    if (std.mem.eql(u8, module, "List")) return std.mem.eql(u8, name, "List");
    if (std.mem.eql(u8, module, "Js")) return std.mem.eql(u8, name, "Value") or std.mem.eql(u8, name, "Ref");
    return false;
}
test "HostFree internal rollout retains imported generic obligations and rejects opaque native and callback payloads" {
    const TestProject = @import("../resolve/TestProject.zig");
    const Session = @import("../Session.zig");
    const testing = std.testing;
    for ([_]struct { body: []const u8, refused: bool }{
        .{ .body = "pub bad : Element.Element → Js.Value\nbad element = Library.erase element\n", .refused = true },
        .{ .body = "pub bad : (⊤ → ⊤) → Js.Value\nbad callback = Library.erase { callback = callback }\n", .refused = true },
        .{ .body = "type Secret = Secret Element.Element\npub bad : Secret → Js.Value\nbad secret = Library.erase secret\n", .refused = true },
        .{ .body = "pub bad : Js.Value → Element.Element\nbad value = Library.read value\n", .refused = true },
        .{ .body = "pub safe : Library.Outer Element.Element → Js.Value\nsafe value = Library.eraseOuter value\n", .refused = false },
        .{ .body = "pub safe : Library.Nest Int → Js.Value\nsafe value = Library.erase value\n", .refused = false },
    }) |scenario| {
        var modules: std.ArrayList(TestProject.Module) = .empty;
        defer modules.deinit(testing.allocator);
        try modules.appendSlice(testing.allocator, &@import("checker_test.zig").test_core);
        try modules.appendSlice(testing.allocator, &.{
            .{ .path = "Browser/Host/Element.beni", .package = .core, .source = "pub foreign type Element\n" },
            .{ .path = "Js.beni", .package = .core, .source = "pub foreign type Value\npub foreign pure from : a → Value\npub foreign pure to : Value → a\n" },
            .{ .path = "Library.beni", .package = .core, .source = "import Js\npub erase value = Js.from value\npub read value = Js.to value\npub type Phantom a = Phantom\npub type Outer a = Outer (Phantom a)\npub eraseOuter : Outer a → Js.Value\neraseOuter value = erase value\npub type Nest a = Leaf a | Branch (Nest (List a))\n" },
        });
        const text = try std.fmt.allocPrintSentinel(testing.allocator, "import Browser.Host.Element as Element\nimport Js\nimport Library\n{s}", .{scenario.body}, 0);
        defer testing.allocator.free(text);
        try modules.append(testing.allocator, .{ .path = "M.beni", .package = .core, .source = text });
        var p = try TestProject.initWith(testing.allocator, modules.items, .{ .phases = Session.check_phases, .host_free = true });
        defer p.deinit();
        var found = false;
        for (p.session.diagnostics.items) |item| if (item.code == .host_value_erasure) {
            found = true;
        };
        if (found != scenario.refused) std.debug.print("{s}\n{s}\n", .{ scenario.body, p.stderr.written() });
        try testing.expectEqual(scenario.refused, found);
        if (!scenario.refused) try testing.expectEqual(@as(usize, 0), p.session.diagnostics.items.len);
    }
}
