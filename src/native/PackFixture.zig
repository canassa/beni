//! Test-only actual checked native Lower/Funnel/Print -> ordinary pack encoding.
const std = @import("std");
const Session = @import("../Session.zig");
const Reach = @import("../js/Reach.zig");
const Lower = @import("../js/Lower.zig");
const Print = @import("../js/Print.zig");
const Funnel = @import("../js/Funnel.zig");
const EmitPack = @import("../js/EmitPack.zig");
const Record = @import("../js/EmitPackRecord.zig");
const Pack = @import("../cache/Pack.zig");
const Emission = @import("Emission.zig");
const Pool = @import("../InternPool.zig");
const Bir = @import("../bir/Bir.zig");
const A = std.mem.Allocator;
pub const Fault = enum { none, old_false, unknown_true };
pub const Snapshot = struct { bytes: []u8, key: @import("../cache/Key.zig").Key };
pub fn make(a: A, scratch: A, session: *Session, live: *const Reach.Result, table: *const Emission.Table, fault: Fault) !Snapshot {
    const recipe = table.recipe orelse return error.MissingRecipe;
    if (!table.ready(recipe.target)) return error.RecipeNotReady;
    const m = recipe.target.module;
    const file = session.graph.moduleFile(m);
    const bir = session.artifacts.bir(file);
    const birs = try scratch.alloc(*const Bir, session.graph.count());
    for (birs, 0..) |*item, i| item.* = session.artifacts.bir(session.graph.moduleFile(@fromBackingInt(@intCast(i))));
    var recorder: Funnel.Recorder = .{};
    var overlay: Pool.Overlay = .init(&session.interner);
    defer overlay.deinit(a);
    var lowered = try Lower.lower(a, scratch, &overlay, .{
        .bir = bir,
        .birs = birs,
        .provenance = session.resolution.provenance,
        .token_starts = session.artifacts.spans(file).starts,
        .module = m,
        .graph = &session.graph,
        .interfaces = session.resolution.interfaces,
        .dispatch = &session.checked.dispatch[m.int()],
        .dispatches = session.checked.dispatch,
        .types = &session.checked.types,
        .specifiers = &.{},
        .sibling = "",
        .live = live,
        .development = true,
        .native_emission = table,
        .record = &recorder,
    });
    defer lowered.deinit(a);
    if (lowered.diagnostics.len != 0 or lowered.uses_runtime or lowered.uses_markup_runtime) return error.UnexpectedNativeLowering;
    var context = try Print.Context.init(scratch, &lowered.ir, .fromOverlay(&overlay), lowered.unobserved, true);
    _ = try context.printRange(0, lowered.head_len);
    var builder: EmitPack.Builder = .init(a);
    defer builder.deinit();
    var encoder: Record.Encoder = .{ .scratch = scratch, .graph = &session.graph, .interner = &session.interner };
    var native_facts: usize = 0;
    for (lowered.units) |unit| {
        const record = &recorder.units.items[unit.record];
        const numbered = context.names_out.items.len;
        const piece = try context.printRange(unit.start, unit.end);
        var encoded = try encoder.rowUnit(m, &builder, &context, &overlay, &recorder, record, piece, numbered);
        const facts = try scratch.dupe(EmitPack.Fact, encoded.facts);
        for (facts) |*fact| if (fact.question == .native_recipe) {
            native_facts += 1;
            if (!fact.validNativeRecipe()) return error.InvalidRecordedRecipe;
            switch (fault) {
                .none => {},
                .old_false => {
                    fact.where = 0;
                    fact.answer = false;
                },
                .unknown_true => fact.where = 2,
            }
        };
        encoded.facts = facts;
        try builder.addUnit(encoded, piece.text);
    }
    if (native_facts != 1) return error.MissingRecordedRecipe;
    const row = try builder.encode(a);
    defer a.free(row);
    var writer: Pack.Writer = .{};
    defer writer.deinit(a);
    const module_key = session.keys.of(m);
    for (EmitPack.every_options) |options| try writer.add(a, .emit, EmitPack.key(module_key, options), row);
    return .{ .bytes = try writer.write(a), .key = module_key };
}
