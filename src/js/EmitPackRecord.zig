//! Existing emitted-unit encoder, shared by the pack maker and actual reuse tests.
const std = @import("std");
const Allocator = std.mem.Allocator;
const EmitPack = @import("EmitPack.zig");
const Print = @import("Print.zig");
const InternPool = @import("../InternPool.zig");
const Funnel = @import("Funnel.zig");
const Join = @import("Join.zig");
const SourceMap = @import("SourceMap.zig");
const JsIr = @import("JsIr.zig");
const Graph = @import("../resolve/Graph.zig");
pub const Encoder = struct {
    scratch: Allocator,
    graph: *const Graph,
    interner: *const InternPool.Global,
    /// The row's unit for `record` and the piece just printed
    /// (`backend.md` §9, *What a unit carries*): the selector the funnel
    /// was opened with, the marks — with the identity behind each name the
    /// printer numbered — the identities the unit introduced, the imports
    /// it asked for, the facts it read, the runtime exports it reached and
    /// its edges.
    pub fn rowUnit(
        mk: *Encoder,
        m: Graph.Index,
        builder: *EmitPack.Builder,
        context: *const Print.Context,
        overlay: *const InternPool.Overlay,
        recorder: *const Funnel.Recorder,
        record: *const Funnel.UnitRecord,
        piece: Join.Piece,
        numbered: usize,
    ) Allocator.Error!EmitPack.Unit {
        const scratch = mk.scratch;
        // The identities the printer numbered while printing this unit:
        // `Print.Context.names_src` is `names_out`'s source column, in the
        // same order.
        const introduced = try scratch.alloc(u32, context.names_src.items.len - numbered);
        for (introduced, context.names_src.items[numbered..]) |*slot, index| {
            slot.* = try mk.ident(builder, context.ir, overlay, index);
        }
        const marks = try scratch.alloc(EmitPack.Mark, piece.mappings.len);
        for (marks, piece.mappings) |*mark, mapping| {
            mark.* = .{
                .generated = mapping.generated,
                .source = mapping.source,
                .name = if (mapping.name == SourceMap.Mapping.no_name)
                    EmitPack.no_name
                else
                    try mk.ident(builder, context.ir, overlay, context.names_src.items[mapping.name]),
            };
        }
        const needed = try scratch.alloc(EmitPack.Needed, record.asks_end - record.asks_start);
        for (needed, record.asks(recorder)) |*need, ask| {
            need.* = .{
                .module = try mk.moduleRef(builder, m, @fromBackingInt(@intCast(ask.module))),
                .value = ask.value,
                .base = if (ask.base.unwrap()) |symbol| try mk.text(builder, overlay.slice(symbol)) else EmitPack.no_string,
            };
        }
        const facts = try scratch.alloc(EmitPack.Fact, record.facts_end - record.facts_start);
        for (facts, record.facts(recorder)) |*fact, asked| {
            fact.* = asked;
            fact.module = try mk.moduleRef(builder, m, @fromBackingInt(@intCast(asked.module)));
        }
        return .{
            .selector = record.selector,
            .marks = marks,
            .introduced = introduced,
            .needed = needed,
            .facts = facts,
            .runtime = record.runtime,
            .edges = record.edges,
        };
    }

    /// The row's identity slot for the printer's name `index`
    /// (`js/JsIr.Name`): its module part, base and tag, with the texts
    /// interned in the row's string table.
    fn ident(mk: *Encoder, builder: *EmitPack.Builder, ir: *const JsIr, overlay: *const InternPool.Overlay, index: u32) Allocator.Error!u32 {
        const name = ir.name(@fromBackingInt(@intCast(index)));
        return builder.internIdent(.{
            .module = if (name.module.unwrap()) |symbol| try mk.text(builder, overlay.slice(symbol)) else EmitPack.no_string,
            .base = try mk.text(builder, overlay.slice(name.base)),
            .tag = name.tag,
        });
    }

    /// A row string: a stable copy in this module's scratch, interned in the
    /// row's table (an interned text must be stable until `encode`).
    fn text(mk: *Encoder, builder: *EmitPack.Builder, bytes: []const u8) Allocator.Error!u32 {
        return builder.internString(try mk.scratch.dupe(u8, bytes));
    }

    /// The row's module reference for graph module `other`
    /// (`EmitPack.Needed.module`): 0 is this module, `k + 1` the slot of
    /// `modules[k]`.
    fn moduleRef(mk: *Encoder, builder: *EmitPack.Builder, m: Graph.Index, other: Graph.Index) Allocator.Error!u32 {
        if (other == m) return EmitPack.self_slot;
        const name = try mk.text(builder, mk.interner.slice(mk.graph.moduleName(other)));
        return (try builder.internModule(mk.graph.modulePackage(other), name)) + 1;
    }
};
