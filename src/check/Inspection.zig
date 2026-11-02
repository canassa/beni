//! Debug's Raw views are borrowed inspection capabilities, never stored data.
//! The name fence confines their source creation to Debug. Only that module
//! needs this pass; generic storage helpers outside it cannot receive a Raw.
const std = @import("std");
const Context = @import("Context.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const HostFree = @import("HostFree.zig");
const Bir = @import("../bir/Bir.zig");
const Report = @import("Report.zig");
const Var = TypeStore.Var;
const Inst = Bir.Inst.Index;

pub fn run(cx: *const Context, inst_type: []const Var.Optional, local_type: []const Var.Optional, decl_scheme: []const Var.Optional, report: *Report) std.mem.Allocator.Error!void {
    if (!cx.store.has_inspection) return;
    if (cx.types.host_free.info.len == 0) return;
    var p: Pass = .{
        .cx = cx,
        .inst_type = inst_type,
        .local_type = local_type,
        .decl_scheme = decl_scheme,
        .report = report,
        .facts = HostFree.State.forContext(cx),
        .memo = &.{},
    };
    var has_value = false;
    var first_value: Inst = @fromBackingInt(0);
    for (inst_type, 0..) |v, i| {
        if (v.unwrap()) |value| {
            switch (cx.bir.instTag(@fromBackingInt(@as(u32, @intCast(i))))) {
                .local, .top, .ext_value, .call, .method_call, .type_dispatch, .field_access, .tuple_index => if (p.rootRaw(value)) {
                    has_value = true;
                    first_value = @fromBackingInt(@as(u32, @intCast(i)));
                    break;
                },
                else => {},
            }
        }
    }
    if (has_value and !std.mem.eql(u8, cx.interner.slice(cx.graph.moduleName(cx.module)), "Debug")) {
        try p.fail(first_value, "Only core Debug may use a borrowed inspection view, including a view obtained through inferred types.");
        return;
    }
    p.memo = try cx.scratch.alloc(u8, cx.store.count());
    @memset(p.memo, 0);
    for (cx.bir.decls, 0..) |decl, i| {
        if (decl.kind != .value or i >= decl_scheme.len) continue;
        const scheme = decl_scheme[i].unwrap() orelse continue;
        if (Walk.function(cx.store, scheme)) |f| {
            if (try p.raw(f.result) or (decl.is_pub and try p.signatureRaw(scheme))) {
                try p.fail(decl.inst_start, "A borrowed inspection view cannot leave Debug through a returned value or public signature.");
                return;
            }
        } else if (try p.raw(scheme)) {
            try p.fail(decl.inst_start, "A borrowed inspection view cannot be kept in a top-level binding.");
            return;
        }
    }
    if (!has_value) return;
    for (0..cx.bir.insts.len) |i| {
        const inst: Inst = @fromBackingInt(@as(u32, @intCast(i)));
        const tag = cx.bir.instTag(inst);
        switch (tag) {
            .record, .record_update, .tuple, .list, .call, .method_call, .type_dispatch => {
                if (i < inst_type.len) if (inst_type[i].unwrap()) |v| {
                    if (!p.rootRaw(v) and try p.raw(v)) {
                        try p.fail(inst, "A borrowed inspection view cannot be stored in a record, union, List or cell.");
                        return;
                    }
                };
            },
            .lambda, .let_def => if (try p.capturesRaw(inst)) {
                try p.fail(inst, "A borrowed inspection view cannot be captured by a closure.");
                return;
            },
            else => {},
        }
        switch (tag) {
            .record, .record_update, .tuple, .list => {
                var children: std.ArrayList(Inst) = .empty;
                defer children.deinit(cx.scratch);
                try cx.bir.operands(cx.scratch, inst, &children);
                for (children.items) |child| if (child.int() < inst_type.len) {
                    if (inst_type[child.int()].unwrap()) |value| if (try p.raw(value)) {
                        try p.fail(child, "A borrowed inspection view cannot be retained in a record, union, List or raw JavaScript aggregate.");
                        return;
                    };
                };
            },
            .lambda, .let_def => {
                const value = if (tag == .let_def) blk: {
                    const def = cx.bir.extraData(@fromBackingInt(@as(u32, @intCast(cx.bir.instData(inst).lhs))), Bir.LetDef);
                    break :blk if (def.local < local_type.len) local_type[def.local].unwrap() else null;
                } else if (i < inst_type.len) inst_type[i].unwrap() else null;
                if (value) |v| if (Walk.function(cx.store, v)) |f| if (try p.raw(f.result)) {
                    try p.fail(inst, "A borrowed inspection view cannot be returned from a closure or local helper.");
                    return;
                };
            },
            else => {},
        }
        if (tag != .call) continue;
        const data = cx.bir.instData(inst);
        const callee: Inst = @fromBackingInt(@intCast(data.lhs));
        const args = cx.bir.extraSlice(cx.bir.subRange(@fromBackingInt(@intCast(data.rhs))), Inst);
        for (args, 0..) |arg, j| {
            if (arg.int() >= inst_type.len) continue;
            const v = inst_type[arg.int()].unwrap() orelse continue;
            if (!try p.raw(v)) continue;
            if (!p.borrower(callee, j)) {
                try p.fail(arg, "A borrowed inspection view may only be read by inspection operations or passed to a Debug helper whose parameter is a Raw view. It cannot enter generic storage or Js.Value.");
                return;
            }
        }
    }
}

const Pass = struct {
    cx: *const Context,
    inst_type: []const Var.Optional,
    local_type: []const Var.Optional,
    decl_scheme: []const Var.Optional,
    report: *Report,
    facts: HostFree.State,
    memo: []u8,

    fn raw(p: *Pass, v: Var) !bool {
        const root = p.cx.store.find(v);
        if (p.memo[root.int()] == 0) p.memo[root.int()] = if (try p.facts.containsInspection(root)) 2 else 1;
        return p.memo[root.int()] == 2;
    }
    fn rootRaw(p: *const Pass, v: Var) bool {
        const content = p.cx.store.resolvedContent(v);
        if (content != .structure or content.structure != .app) return false;
        const id = content.structure.app.type;
        if (id == .none) return false;
        const entry = p.cx.types.entry(id);
        return entry.package == .core and std.mem.eql(u8, p.cx.interner.slice(entry.module_name), "Js.Inspect") and std.mem.eql(u8, p.cx.interner.slice(entry.name), "Raw");
    }
    fn signatureRaw(p: *Pass, value: Var) std.mem.Allocator.Error!bool {
        var stack: std.ArrayList(Var) = .empty;
        defer stack.deinit(p.cx.scratch);
        const seen = try p.cx.scratch.alloc(bool, p.cx.store.count());
        defer p.cx.scratch.free(seen);
        @memset(seen, false);
        try stack.append(p.cx.scratch, value);
        while (stack.pop()) |v| {
            const root = p.cx.store.find(v);
            if (seen[root.int()]) continue;
            seen[root.int()] = true;
            if (try p.raw(root)) return true;
            var i: u32 = 0;
            while (Walk.stepped(p.cx.store, root, i)) |child| : (i += 1) try stack.append(p.cx.scratch, child.v);
        }
        return false;
    }
    fn borrower(p: *const Pass, callee: Inst, index: usize) bool {
        const bir = p.cx.bir;
        const data = bir.instData(callee);
        var base: ?Var = null;
        switch (bir.instTag(callee)) {
            .ext_value => {
                const module: @import("../resolve/Graph.zig").Index = @fromBackingInt(@intCast(data.lhs));
                if (p.cx.graph.modulePackage(module) != .core) return false;
                const name = p.cx.interner.slice(p.cx.graph.moduleName(module));
                if (std.mem.eql(u8, name, "Js.Inspect")) return true;
                if (!std.mem.eql(u8, name, "Js")) return false;
                const iface = &p.cx.interfaces[module.int()];
                const value = iface.values[@intCast(data.rhs)];
                return std.mem.eql(u8, p.cx.interner.slice(iface.symbols[@backingInt(value.name)]), "same");
            },
            .top => if (data.lhs < p.decl_scheme.len) {
                base = p.decl_scheme[@intCast(data.lhs)].unwrap();
            },
            .local => if (data.lhs < p.local_type.len) {
                base = p.local_type[@intCast(data.lhs)].unwrap();
            },
            else => return false,
        }
        const f = Walk.function(p.cx.store, base orelse return false) orelse return false;
        return index < f.params.len and p.rootRaw(f.params[index]);
    }
    fn capturesRaw(p: *Pass, inst: Inst) !bool {
        const a = p.cx.scratch;
        var nodes: std.ArrayList(Inst) = .empty;
        defer nodes.deinit(a);
        try nodes.append(a, inst);
        var at: usize = 0;
        while (at < nodes.items.len) : (at += 1) try p.cx.bir.operands(a, nodes.items[at], &nodes);
        const bound = try a.alloc(bool, p.local_type.len);
        defer a.free(bound);
        @memset(bound, false);
        for (nodes.items) |node| if (p.cx.bir.instTag(node) == .pat_var) {
            const local = p.cx.bir.instData(node).lhs;
            if (local < bound.len) bound[@intCast(local)] = true;
        };
        for (nodes.items) |node| if (p.cx.bir.instTag(node) == .local) {
            const local = p.cx.bir.instData(node).lhs;
            if (local >= bound.len or bound[@intCast(local)]) continue;
            if (p.local_type[@intCast(local)].unwrap()) |v| if (try p.raw(v)) return true;
        };
        return false;
    }
    fn fail(p: *Pass, inst: Inst, message: []const u8) !void {
        for (p.cx.bir.decls, 0..) |decl, i| if (inst.int() >= decl.inst_start.int() and inst.int() < decl.inst_end.int()) {
            p.report.at(@intCast(i));
            break;
        };
        try p.report.emitText(.inspection_escape, inst, null, message);
        p.report.at(null);
    }
};
