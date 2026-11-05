//! Literal Cell selectors and immediate pure bodies, without general closures.
//! Obligations kept here: none (syntax and resolved module identity).

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Ids = @import("Ids.zig");

pub const Lambda = struct { operand: u32, immediate: bool = false };
pub const Reader = *const fn (ctx: *anyopaque, inst: u32) Ids.ChargeError!?Lambda;

/// Namespace identity must not read a Js type fact outside a caller's cache key.
pub fn moduleId(graph: *const Graph, interner: *const InternPool.Global) u32 {
    const name = interner.find("Js") orelse return Ids.none_int;
    const module = graph.lookup(.core, name) orelse return Ids.none_int;
    return module.int();
}

const Selection = struct { operand: u32, field: Bir.Symbol, write: bool };

/// The caller has resolved the declaration to core Js before entering here.
fn select(bir: *const Bir, owner: *const Bir, decl: Bir.Decl, interner: *const InternPool.Global, args: []const u32) ?Selection {
    const name = interner.slice(owner.symbol(decl.name));
    const index: usize = if (std.mem.eql(u8, name, "cellRead")) 1 else if (std.mem.eql(u8, name, "cellWrite")) 2 else return null;
    if (args.len <= index) return null;
    const selected = bir.fieldSelector(@fromBackingInt(args[index])) orelse return null;
    return .{ .operand = args[index], .field = selected, .write = index == 2 };
}

pub fn field(bir: *const Bir, owner: *const Bir, decl: Bir.Decl, interner: *const InternPool.Global, args: []const u32) ?Bir.Symbol {
    return (select(bir, owner, decl, interner, args) orelse return null).field;
}

/// Structural readers consume selectors; Js.pure executes its literal body.
pub fn reader(bir: *const Bir, owner: *const Bir, decl: Bir.Decl, interner: *const InternPool.Global, args: []const u32) ?Lambda {
    if (owner.ownSlotsV2(decl).len == 0) return null;
    if (std.mem.eql(u8, interner.slice(owner.symbol(decl.name)), "pure") and args.len == 1) {
        const operand: Bir.Inst.Index = @fromBackingInt(args[0]);
        if (bir.instTag(operand) != .lambda) return null;
        const params = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(operand).lhs)), Bir.Inst.Index);
        if (params.len != 1) return null;
        const tag = bir.instTag(params[0]);
        if (tag != .pat_unit and tag != .pat_wild) return null;
        return .{ .operand = args[0], .immediate = true };
    }
    const selected = select(bir, owner, decl, interner, args) orelse return null;
    return if (selected.write) null else .{ .operand = selected.operand };
}

/// Absorb structural selectors whole; immediate thunks lose only the wrapper.
/// Their body stays live, with its answer consumed at the primitive call.
pub fn consume(bir: *const Bir, start: u32, absorbed: []bool, consumer: []u32, ctx: *anyopaque, lookup: ?Reader, inst: u32) Ids.ChargeError!void {
    const tag = bir.instTag(@fromBackingInt(inst));
    if (tag != .call and tag != .method_call) return;
    const find = lookup orelse return;
    const selector = try find(ctx, inst) orelse return;
    const body = bir.instData(@fromBackingInt(selector.operand)).rhs;
    absorbed[selector.operand - start] = true;
    if (selector.immediate) {
        consumer[body - start] = inst;
        return;
    }
    absorbed[body - start] = true;
    absorbed[bir.instData(@fromBackingInt(body)).lhs - start] = true;
}
