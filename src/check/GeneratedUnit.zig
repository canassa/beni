//! One ordinary independent checking batch. Never mutates the source Driver graph.
//! Success is ordinary checking, not a source-region/body provenance certificate.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("../Session.zig");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Dispatch = @import("Dispatch.zig");
const ControlBuild = @import("ControlBuild.zig");

pub const Options = struct {
    ownership_v2: bool = false,
    diagnostics: Session.DiagnosticsFormat = .text,
    /// Structured source origins, borrowed only through this check.
    failure_origins: Session.Foreign = .{},
    /// Request ordinary ownership enforcement in this chainless app unit.
    ownership_everywhere: bool = false,
    jobs: u32 = 1,
    /// Optional ordinary profile path, borrowed through CheckedUnit.deinit.
    self_profile: ?[]const u8 = null,
};

pub const CheckedUnit = struct {
    session: *Session,
    /// SourceStore borrows these bytes; destroy the Session before freeing them.
    source: [:0]u8,
    /// The actual checked body module, never the bridge or a source-graph id.
    root: Graph.Index,

    pub fn bir(unit: *const CheckedUnit) *const Bir {
        return unit.session.artifacts.bir(unit.session.graph.moduleFile(unit.root));
    }

    pub fn dispatch(unit: *const CheckedUnit) *const Dispatch {
        return &unit.session.checked.dispatch[unit.root.int()];
    }

    pub fn iface(unit: *const CheckedUnit) *const Interface {
        return &unit.session.resolution.interfaces[unit.root.int()];
    }

    pub fn deinit(unit: *CheckedUnit, gpa: Allocator) void {
        unit.session.deinit();
        gpa.destroy(unit.session);
        gpa.free(unit.source);
        unit.* = undefined;
    }
};

pub const Error = Session.RunError || ControlBuild.Error || error{ GeneratedCheckFailed, MissingGeneratedRoot, InvalidJobCount, InvalidRuntimeSource };

/// Arbitrary caller source always receives ordinary APP rules.
pub fn check(gpa: Allocator, io: std.Io, source: []const u8, options: Options, diagnostics: *std.Io.Writer) Error!CheckedUnit {
    return checkSource(gpa, io, source, options, diagnostics, .app);
}

/// Only the validated checked-BIR producer can enter the owned runtime role.
/// This validation establishes origin; the independent Session still checks
/// every generated declaration through its ordinary frontend/type/own route.
pub fn checkRuntime(gpa: Allocator, io: std.Io, runtime: ControlBuild.RuntimeSource, options: Options, diagnostics: *std.Io.Writer) Error!CheckedUnit {
    if (options.jobs == 0) return error.InvalidJobCount;
    try ControlBuild.validateRuntimeSource(gpa, runtime);
    return checkSource(gpa, io, runtime.batch.source, options, diagnostics, .runtime_core);
}

const Role = enum { app, runtime_core };
const bridge = "import GeneratedControls\n\npub witness : ⊤\nwitness = ⊤\n";

fn checkSource(gpa: Allocator, io: std.Io, source: []const u8, options: Options, diagnostics: *std.Io.Writer, role: Role) Error!CheckedUnit {
    if (options.jobs == 0) return error.InvalidJobCount;
    const owned = try gpa.dupeSentinel(u8, source, 0);
    errdefer gpa.free(owned);
    const session = try gpa.create(Session);
    errdefer gpa.destroy(session);
    // Rebuild, never copy source graph options/selection/cache/Driver arrays.
    // A false query gives the ordinary checker an EMPTY required-module mask.
    session.* = try Session.init(gpa, io, .{
        .jobs = options.jobs,
        .self_profile = options.self_profile,
        .core_package = true,
        .core = role == .runtime_core,
        .ownership_v2_dump = if (role == .runtime_core and options.ownership_v2) .{ .summaries = true } else null,
        .diagnostics = options.diagnostics,
        .defer_render = true,
        .ownership = options.ownership_everywhere,
        .ownership_v2 = options.ownership_v2,
        .ownership_everywhere = options.ownership_everywhere,
        .checked_controls = false,
        .entry_root_requests = &.{},
    });
    errdefer session.deinit();
    const package: Graph.Package = .app;
    try session.store.addEmbedded(gpa, "GeneratedControls.beni", 0, package, owned);
    if (role == .runtime_core) try session.store.addEmbedded(gpa, "ControlBridge.beni", 0, .app, bridge);
    const summary = try session.run(&.{}, Session.check_phases, diagnostics);
    // Includes ordinary ownership diagnostics: a type-clean module alone
    // cannot authorize returning a checked generated body.
    if (summary.errors != 0) {
        session.foreign = options.failure_origins;
        _ = try session.renderLate(&.{}, diagnostics);
        return error.GeneratedCheckFailed;
    }
    if (role == .app) _ = try session.renderLate(&.{}, diagnostics);
    const name = try session.interner.getOrPut(gpa, "GeneratedControls");
    const root = session.graph.find(package, name) orelse return error.MissingGeneratedRoot;
    return .{ .session = session, .source = owned, .root = root };
}

const good_body =
    \\import Ref
    \\
    \\
    \\type alias Slot a = Ref.Ref (Maybe a)
    \\
    \\
    \\pub body : Slot Int, Int, (Int → Int) → ⊤
    \\body output value next =
    \\    answer = next value
    \\    Ref.set output (Just answer)
    \\
;

fn expectCheckedBody(jobs: u32) !void {
    const caller = try std.testing.allocator.dupe(u8, good_body);
    defer std.testing.allocator.free(caller);
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    var unit = check(std.testing.allocator, std.testing.io, caller, .{ .jobs = jobs }, &diagnostics.writer) catch |err| {
        std.debug.print("ordinary generated good body failed:\n{s}\n", .{diagnostics.written()});
        return err;
    };
    defer unit.deinit(std.testing.allocator);
    @memset(caller, ' ');
    try std.testing.expectEqualStrings(good_body, unit.source);
    const file = unit.session.graph.moduleFile(unit.root);
    try std.testing.expectEqualStrings("GeneratedControls", unit.session.store.moduleName(file));
    try std.testing.expect(unit.session.store.isEmbedded(file));
    try std.testing.expectEqual(@intFromPtr(unit.source.ptr), @intFromPtr(unit.session.store.bytes(file).ptr));
    try std.testing.expect(unit.session.options.core_package);
    try std.testing.expect(!unit.session.options.core);
    try std.testing.expectEqual(Graph.Package.app, unit.session.graph.modulePackage(unit.root));
    try std.testing.expect(!unit.session.options.checked_controls);
    try std.testing.expectEqual(@as(usize, 0), unit.session.options.entry_root_requests.len);
    try std.testing.expect(!unit.dispatch().control_sources.present);
    try std.testing.expectEqualStrings("", diagnostics.written());
    var found_body = false;
    for (unit.bir().decls) |decl| {
        if (std.mem.eql(u8, unit.session.interner.slice(unit.bir().symbol(decl.name)), "body")) found_body = true;
    }
    try std.testing.expect(found_body);
    var actual_calls: usize = 0;
    for (unit.bir().insts.items(.tag)) |tag| if (tag == .call) {
        actual_calls += 1;
    };
    try std.testing.expect(actual_calls >= 2); // next(value) and actual Ref.set body.
    try std.testing.expectEqual(@as(usize, 1), unit.iface().values.len);
}

test "generated unit owns ordinary source and exposes its checked body with one worker" {
    try expectCheckedBody(1);
}

test "generated unit owns ordinary source and exposes its checked body with eight workers" {
    try expectCheckedBody(8);
}

fn expectWrongSlot(format: Session.DiagnosticsFormat) !void {
    const wrong_body =
        \\import Ref
        \\
        \\
        \\type alias Slot a = Ref.Ref (Maybe a)
        \\
        \\
        \\pub body : Slot Int, Int, (Int → Int) → ⊤
        \\body output value next =
        \\    answer = next value
        \\    Ref.set output (Just "wrong")
        \\
    ;
    {
        var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer diagnostics.deinit();
        try std.testing.expectError(error.GeneratedCheckFailed, check(std.testing.allocator, std.testing.io, wrong_body, .{ .diagnostics = format }, &diagnostics.writer));
        if (format == .json) {
            try expectJsonDiagnostic(diagnostics.written(), "type_mismatch");
        } else {
            try std.testing.expect(std.mem.indexOf(u8, diagnostics.written(), "TYPE MISMATCH") != null);
            try std.testing.expect(std.mem.indexOf(u8, diagnostics.written(), "GeneratedControls.beni") != null);
            try std.testing.expect(std.mem.indexOf(u8, diagnostics.written(), "wrong") != null);
        }
    }
}

test "generated unit rejects a wrong fixed output Slot through ordinary text typing" {
    try expectWrongSlot(.text);
}

test "generated unit rejects a wrong fixed output Slot through ordinary JSON typing" {
    try expectWrongSlot(.json);
}

fn expectOwnership(v2: bool, enforce: bool) !void {
    const shared_list =
        \\pub bad : List Int → List Int × List Int
        \\bad values =
        \\    changed = List.push values 1
        \\    ( changed, values )
        \\
    ;
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    const result = check(std.testing.allocator, std.testing.io, shared_list, .{ .ownership_v2 = v2, .ownership_everywhere = enforce, .diagnostics = .json }, &diagnostics.writer);
    if (enforce) {
        try std.testing.expectError(error.GeneratedCheckFailed, result);
        try expectJsonDiagnostic(diagnostics.written(), "list_still_used");
    } else {
        var unit = try result;
        defer unit.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("", diagnostics.written());
    }
}

test "generated unit own1 accepts unenforced standalone ownership" {
    try expectOwnership(false, false);
}
test "generated unit own1 enforces standalone ownership" {
    try expectOwnership(false, true);
}

test "generated unit rejects zero workers without starting a session" {
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.InvalidJobCount, check(std.testing.allocator, std.testing.io, good_body, .{ .jobs = 0 }, &diagnostics.writer));
    try std.testing.expectEqualStrings("", diagnostics.written());
}

fn expectJsonDiagnostic(bytes: []const u8, code: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    var found = false;
    for (parsed.value.array.items) |item| {
        const actual_code = item.object.get("code").?.string;
        if (!std.mem.eql(u8, actual_code, code)) continue;
        try std.testing.expectEqualStrings("GeneratedControls.beni", item.object.get("span").?.object.get("file").?.string);
        found = true;
    }
    if (!found) std.debug.print("missing ordinary generated diagnostic {s}:\n{s}\n", .{ code, bytes });
    try std.testing.expect(found);
}

test "generated unit keeps ordinary app sync restrictions" {
    const privileged = "pub bad : sync (Int → Int) → Int\nbad next = next 1\n";
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.GeneratedCheckFailed, check(std.testing.allocator, std.testing.io, privileged, .{}, &diagnostics.writer));
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.written(), "MISPLACED SYNC") != null);
}

test "generated unit runtime rejects caller bytes before assigning a core role" {
    var batch: ControlBuild.Batch = .{ .source = try std.testing.allocator.dupe(u8, "pub bad : sync (Int → Int) → Int\nbad next = next 1\n") };
    defer batch.deinit(std.testing.allocator);
    var interner = try @import("../InternPool.zig").Global.init(std.testing.allocator);
    defer interner.deinit(std.testing.allocator);
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.InvalidRuntimeSource, checkRuntime(std.testing.allocator, std.testing.io, .{
        .batch = &batch,
        .inputs = &.{},
        .interner = &interner,
        .tamper = .none,
    }, .{}, &diagnostics.writer));
    try std.testing.expectEqualStrings("", diagnostics.written());
}

test "generated unit canonical runtime retains app ownership role with core syntax" {
    var interner = try @import("../InternPool.zig").Global.init(std.testing.allocator);
    defer interner.deinit(std.testing.allocator);
    var batch = try ControlBuild.produce(std.testing.allocator, &.{}, &interner, .none);
    defer batch.deinit(std.testing.allocator);
    var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    var unit = try checkRuntime(std.testing.allocator, std.testing.io, .{
        .batch = &batch,
        .inputs = &.{},
        .interner = &interner,
    }, .{ .ownership_everywhere = true }, &diagnostics.writer);
    defer unit.deinit(std.testing.allocator);
    try std.testing.expectEqual(Graph.Package.app, unit.session.graph.modulePackage(unit.root));
    try std.testing.expect(unit.session.options.core);
    try std.testing.expect(unit.session.enforce_ownership);
    const name = try unit.session.interner.getOrPut(std.testing.allocator, "ControlBridge");
    try std.testing.expect(unit.session.graph.find(.app, name) != null);
    try std.testing.expectEqualStrings("", diagnostics.written());
}
