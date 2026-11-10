//! The record rows of checker v2's lowering channel, as the table that the
//! emitter reads (`docs/design/ownership-v2.md` §2.8, *the emitter reads the
//! rows*; `ownership-checker.md` §31.10). `Lower` reads v1's `Hoists.Table`:
//! a demand row for each accepted record write, and a read row for each read
//! that it binds before a write or at a closure's creation. Checker v2 keeps
//! the same facts as BIR identities (`own2/Hoists.zig`) and may not import
//! `src/own/`, so the conversion is here, outside both.
//!
//! A demand row is for an update or a call: the emitter asserts on an update's
//! row before it stores. An accepted record line at another instruction, the
//! creation of a closure that writes its capture at most once (R-4.8.2), has
//! no row: the creation writes nothing.
//!
//! A read's path is the BIR's own access chain, from the holder to the last
//! access of the source read, with a record pattern's field after it. The
//! prefix is the part through the written field. So the result is a table
//! that `Hoists.Table.verifyAgainstBir` accepts.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Hoists = @import("../own/Hoists.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Channel = @import("../own2/Hoists.zig");

const Allocator = std.mem.Allocator;
const Inst = Bir.Inst;

/// The offset of `text` in the name blob, added when it is new.
fn nameOf(gpa: Allocator, names: *std.ArrayList(u8), seen: *std.StringHashMapUnmanaged(u32), text: []const u8) Allocator.Error!u32 {
    const got = try seen.getOrPut(gpa, text);
    if (!got.found_existing) {
        got.value_ptr.* = @intCast(names.items.len);
        try names.appendSlice(gpa, text);
        try names.append(gpa, 0);
    }
    return got.value_ptr.*;
}

/// v1's table for module `bir`, from v2's channel `ch`, in `gpa`. The records are written in place
/// (`clean`) where the module is an application's (`app`) and both halves of the channel are clean; any
/// other module has the empty table, which is not clean.
pub fn table(gpa: Allocator, ch: *const Channel.Table, bir: *const Bir, pool: *const InternPool.Global, dispatch: *const Dispatch, app: bool) Allocator.Error!Hoists.Table {
    if (!app or !ch.clean or !ch.records) return .empty;
    var out: Hoists.Table = .{ .clean = true };
    errdefer out.deinit(gpa);
    // The writes are in instruction order, each once, as the table's search needs.
    var demands: std.ArrayList(Hoists.Demand) = .empty;
    errdefer demands.deinit(gpa);
    for (ch.record_writes) |w| {
        const at: Inst.Index = @fromBackingInt(w.inst);
        const row = switch (bir.instTag(at)) {
            .record_update, .call, .method_call, .type_dispatch => true,
            // A source dot is a call only where the dispatch says so.
            .field_access => if (dispatch.siteOf(at)) |site| site.callee != .none else false,
            else => false,
        };
        if (row) try demands.append(gpa, .{ .decl = w.decl, .inst = w.inst, .fields_start = 0, .fields_len = 0 });
    }
    out.demands = try demands.toOwnedSlice(gpa);
    var reads: std.ArrayList(Hoists.Read) = .empty;
    errdefer reads.deinit(gpa);
    var paths: std.ArrayList(Hoists.Step) = .empty;
    errdefer paths.deinit(gpa);
    var names: std.ArrayList(u8) = .empty;
    errdefer names.deinit(gpa);
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer seen.deinit(gpa);
    var chain: std.ArrayList(Inst.Index) = .empty;
    defer chain.deinit(gpa);
    for (ch.reads) |r| {
        const h = r.row;
        // The source read's chain, last access first, down to its holder.
        chain.clearRetainingCapacity();
        var at: Inst.Index = @fromBackingInt(h.outer);
        while (bir.instTag(at) == .field_access or bir.instTag(at) == .tuple_index) : (at = @fromBackingInt(@intCast(bir.instData(at).lhs))) try chain.append(gpa, at);
        const start: u32 = @intCast(paths.items.len);
        var prefix: u32 = 0;
        var k = chain.items.len;
        while (k > 0) {
            k -= 1;
            const i = chain.items[k];
            const d = bir.instData(i);
            try paths.append(gpa, if (bir.instTag(i) == .field_access)
                .{ .kind = 0, .arg = try nameOf(gpa, &names, &seen, pool.slice(bir.symbol(@fromBackingInt(d.rhs)))) }
            else
                .{ .kind = 1, .arg = d.rhs });
            // The prefix ends at the access of the written field.
            if (i.int() == h.read) prefix = @intCast(paths.items.len - start);
        }
        // A record pattern's field is the last step, and the written one.
        if (h.binding != Hoists.none) {
            const decl = bir.decls[r.decl];
            const name = bir.locals[decl.locals_start + h.binding].name.unwrap().?;
            try paths.append(gpa, .{ .kind = 0, .arg = try nameOf(gpa, &names, &seen, pool.slice(bir.symbol(@fromBackingInt(name)))) });
        }
        const len: u32 = @intCast(paths.items.len - start);
        try reads.append(gpa, .{
            .decl = r.decl,
            .demand = r.write,
            .inst = h.outer,
            .holder = h.holder,
            .binding = h.binding,
            .path_start = start,
            .path_len = len,
            .prefix_len = if (h.binding != Hoists.none or prefix == 0) len else prefix,
            .placement = h.placement,
            .phase = h.phase,
            .capture = h.capture,
        });
    }
    out.reads = try reads.toOwnedSlice(gpa);
    out.paths = try paths.toOwnedSlice(gpa);
    out.names = try names.toOwnedSlice(gpa);
    return out;
}
