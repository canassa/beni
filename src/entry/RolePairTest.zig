//! Actual ordinary source supplements for exact producer query/binding pairing.
const std = @import("std");
const Session = @import("../Session.zig");
const Entries = @import("../dump/entries.zig");
const Emit = @import("../js/Emit.zig");
const Manifest = @import("../js/Manifest.zig");
const a = std.testing.allocator;
const Fixture = struct {
    session: Session = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    fn init(f: *Fixture) !void {
        f.arena = .init(a);
        errdefer f.arena.deinit();
        f.session = try Session.init(a, std.testing.io, .{ .jobs = 1, .diagnostics = .json, .entry_root_requests = &.{.{ .program = "Start.Program" }} });
        errdefer f.session.deinit();
        try f.session.store.addEmbedded(a, "Main.beni", 0, .app,
            \\import Start
            \\
            \\
            \\first : ⊤, ⊤ → ⊤
            \\first _ value = value
            \\
            \\
            \\second : ⊤, ⊤ → ⊤
            \\second _ value = value
            \\
            \\
            \\callbacks init =
            \\    { init = init
            \\    , start = first
            \\    , handle = λ_ _ value → value
            \\    , stream = λ_ _ _ value → value
            \\    }
            \\
            \\
            \\make init = Start.make (callbacks init)
            \\
            \\
            \\wrap f =
            \\    captured = { payload = f }
            \\    λ_ value →
            \\        _ = captured
            \\        value
            \\
            \\
            \\foo = make (wrap first)
            \\
            \\
            \\bar = make (wrap second)
            \\
            \\
            \\begin context value =
            \\    Start.open foo ⊤
            \\    Start.open bar ⊤
            \\    value
            \\
            \\
            \\main : Start.Program
            \\main = Start.make (callbacks begin)
            \\
        );
        try f.session.store.addEmbedded(a, "platform/Start.beni", 9, .platform,
            \\pub type Program
            \\    = Program
            \\        { init : (⊤, ⊤ → ⊤)
            \\        , start : (⊤, ⊤ → ⊤)
            \\        , handle : (⊤, ⊤, ⊤ → ⊤)
            \\        , stream : (⊤, ⊤, ⊤, ⊤ → ⊤)
            \\        }
            \\
            \\
            \\pub make callbacks = Program callbacks
            \\
            \\
            \\pub open : Program, ⊤ → ⊤
            \\open _ _ = ⊤
            \\
        );
        try f.session.store.addEmbedded(a, "platform/Rt.beni", 9, .platform, "import Start exposing (Program)\n\n\npub run : Program → ⊤\nrun _ = ⊤\n");
        var diagnostics: std.Io.Writer.Allocating = .init(a);
        defer diagnostics.deinit();
        const summary = try f.session.run(&.{}, Session.check_phases, &diagnostics.writer);
        if (summary.errors != 0) std.debug.print("{s}\n", .{diagnostics.written()});
        try std.testing.expectEqual(@as(u32, 0), summary.errors);
        const arena = f.arena.allocator();
        const manifest = try Manifest.parse(arena,
            \\{"platform":true,"program":"Start.Program","entryKinds":[{"programType":"Start.Program","realm":"window","runtime":"Rt","constructors":[{"name":"Start.make","parameter":0,"callbackProtocol":"handlers"}],"launches":[{"name":"Start.open","parameter":0}],"parameters":[]}]}
        );
        const kinds = [_]Emit.EntryKind{.{ .definition = manifest.entryKinds[0], .root = "platform", .layer = 0 }};
        const items = try Entries.inspect(a, arena, &f.session, .{ .out_dir = &.{}, .embedded = &.{}, .platform = .{ .root = "platform", .program = manifest.program, .entry_kinds = &kinds } });
        defer {
            for (items) |item| a.free(item.message);
            a.free(items);
        }
        if (items.len != 0) for (items) |item| std.debug.print("{t}: {s}\n", .{ item.code, item.message });
        try std.testing.expectEqual(@as(usize, 0), items.len);
        try std.testing.expect(f.session.entry_graph.captures.len >= 2);
        try f.session.entry_graph.validateTransfers();
    }
    fn deinit(f: *Fixture) void {
        f.session.deinit();
        f.arena.deinit();
    }
};

test "role producer actual source refuses capture S replaced by W" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const g = &f.session.entry_graph;
    g.captures.items(.S)[0] = g.captures.items(.W)[0];
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
}

test "role producer actual source refuses mismatched observation seed sibling binding and status" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const g = &f.session.entry_graph;
    const capture = g.captures.get(0);
    const transfer = g.role_transfers.get(@backingInt(capture.transfer));
    const S = g.evidence.queries.get(@backingInt(capture.S));
    const observation = g.observations.get(@backingInt(S.observation));
    g.observations.items(.control)[@backingInt(S.observation)] = !observation.control;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.observations.set(@backingInt(S.observation), observation);
    try std.testing.expect(g.evidence.source.selectors.len > 0);
    g.observations.items(.selector)[@backingInt(S.observation)] = @fromBackingInt(0);
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.observations.set(@backingInt(S.observation), observation);
    g.evidence.queries.items(.seed)[@backingInt(capture.S)] = @fromBackingInt(0);
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.evidence.queries.set(@backingInt(capture.S), S);
    const other = g.captures.get(1);
    try std.testing.expect(capture.binding != other.binding);
    g.captures.items(.binding)[0] = other.binding;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.captures.set(0, capture);
    g.captures.items(.status)[0] = if (capture.status == .closed) .unproved else .closed;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.captures.set(0, capture);
    const ti = @backingInt(capture.transfer);
    g.role_transfers.items(.S)[ti] = transfer.W;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.role_transfers.set(ti, transfer);
    const overall_S = g.evidence.queries.get(@backingInt(transfer.S));
    const overall_observation = g.observations.get(@backingInt(overall_S.observation));
    g.observations.items(.control)[@backingInt(overall_S.observation)] = !overall_observation.control;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.observations.set(@backingInt(overall_S.observation), overall_observation);
    g.evidence.queries.items(.seed)[@backingInt(transfer.S)] = @fromBackingInt(0);
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.evidence.queries.set(@backingInt(transfer.S), overall_S);
    g.role_transfers.items(.status)[ti] = if (transfer.status == .closed) .unproved else .closed;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.role_transfers.set(ti, transfer);
    const oi = @backingInt(transfer.origin);
    const origin = g.evidence.source.origins.get(oi);
    inline for (.{ @import("Compact.zig").Origin.Tag.runtime, @import("Compact.zig").Origin.Tag.@"opaque", @import("Compact.zig").Origin.Tag.literal }) |tag| {
        g.evidence.source.origins.items(.tag)[oi] = tag;
        try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
        g.evidence.source.origins.set(oi, origin);
    }
    const ci = @backingInt(transfer.constructor);
    const constructor = g.evidence.source.origins.get(ci);
    g.evidence.source.origins.items(.tag)[ci] = .function;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.evidence.source.origins.set(ci, constructor);
    try std.testing.expect(g.evidence.source.constructors.len >= 2);
    g.evidence.source.origins.items(.target)[ci] = if (constructor.target == 0) 1 else 0;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.evidence.source.origins.set(ci, constructor);
    const ctor = g.evidence.source.constructors.get(constructor.target);
    g.evidence.source.constructors.items(.kind)[constructor.target] = .none;
    try std.testing.expectError(error.InvalidEvidence, g.validateTransfers());
    g.evidence.source.constructors.set(constructor.target, ctor);
    try g.validateTransfers();
}
