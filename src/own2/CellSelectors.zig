//! Literal Cell selectors are structural row input, never invoked callbacks.
//! Obligations kept here: none (syntax and resolved module identity).

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const InternPool = @import("../InternPool.zig");
const Ids = @import("Ids.zig");

pub const Reader = *const fn (ctx: *anyopaque, inst: u32) Ids.ChargeError!?u32;

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

/// Only the existing worded read row consumes a selector without invoking it.
pub fn reader(bir: *const Bir, owner: *const Bir, decl: Bir.Decl, interner: *const InternPool.Global, args: []const u32) ?u32 {
    if (owner.ownSlotsV2(decl).len == 0) return null;
    const selected = select(bir, owner, decl, interner, args) orelse return null;
    return if (selected.write) null else selected.operand;
}

/// Absorb exactly a proven selector, its field access and its own parameter
/// read. It still has an empty capture-free closure value as the call's operand.
pub fn consume(bir: *const Bir, start: u32, absorbed: []bool, ctx: *anyopaque, lookup: ?Reader, inst: u32) Ids.ChargeError!void {
    const tag = bir.instTag(@fromBackingInt(inst));
    if (tag != .call and tag != .method_call) return;
    const find = lookup orelse return;
    const selector = try find(ctx, inst) orelse return;
    const body = bir.instData(@fromBackingInt(selector)).rhs;
    absorbed[selector - start] = true;
    absorbed[body - start] = true;
    absorbed[bir.instData(@fromBackingInt(body)).lhs - start] = true;
}
