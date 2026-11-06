//! Kept-code raw global checks and EntryHost proof over inferred typed summaries,
//! followed by a breadth-first
//! explanation in the entry's existing execution projection. No second native
//! shape graph and no source sidecar is involved.
const std = @import("std");
const Graph = @import("../resolve/Graph.zig");
const Reach = @import("Reach.zig");
const Operations = @import("../native/Operations.zig");
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("../check/Dispatch.zig");
const JsIntrinsic = @import("JsIntrinsic.zig");
const none = std.math.maxInt(u32);

/// Globals unavailable to browser workers, except the dedicated-worker frame
/// provider handled by pageName. Restricted receivers are checked syntactically
/// below, without adding a native-object shape analysis.
const page_only = std.StaticStringMap(void).initComptime(.{
    .{"document"},             .{"window"},
    .{"history"},              .{"localStorage"},
    .{"sessionStorage"},       .{"innerWidth"},
    .{"innerHeight"},          .{"scrollX"},
    .{"scrollY"},              .{"requestAnimationFrame"},
    .{"cancelAnimationFrame"}, .{"HTMLAnchorElement"},
    .{"Text"},
});

/// A kept body's first unproved access. Unknown names and escaping receiver
/// handles are refused rather than followed through an alias or value graph.
fn globalName(e: anytype, b: *const Bir, inst: Bir.Inst.Index) ?[]const u8 {
    if (b.instTag(inst) != .call) return null;
    const d = b.instData(inst);
    if (JsIntrinsic.of(e.graph(), e.session.resolution.interfaces, b, @fromBackingInt(@intCast(d.lhs)), &e.session.interner) != .global) return null;
    const args = b.extraSlice(b.subRange(@fromBackingInt(@intCast(d.rhs))), Bir.Inst.Index);
    return if (args.len == 1 and b.instTag(args[0]) == .string) b.bytes(args[0]) else null;
}

const Receiver = enum { globalThis, self, location, navigator };

/// Only literal root/member chains; aliases are deliberately not followed.
fn receiver(e: anytype, b: *const Bir, at: Bir.Inst.Index) ?Receiver {
    var current = at;
    var result: ?Receiver = null;
    while (current.int() < b.insts.len and b.instTag(current) == .call) {
        if (globalName(e, b, current)) |name| {
            const root = std.meta.stringToEnum(Receiver, name) orelse return null;
            return if (result) |r| if (root == .globalThis or root == .self) r else null else root;
        }
        const d = b.instData(current);
        if (JsIntrinsic.of(e.graph(), e.session.resolution.interfaces, b, @fromBackingInt(@intCast(d.lhs)), &e.session.interner) != .get) return null;
        const args = b.extraSlice(b.subRange(@fromBackingInt(@intCast(d.rhs))), Bir.Inst.Index);
        if (args.len != 2 or b.instTag(args[1]) != .string) return null;
        const member = std.meta.stringToEnum(Receiver, b.bytes(args[1])) orelse return null;
        if (result == null) result = member else if (member != .globalThis and member != .self) return null;
        current = args[0];
    }
    return null;
}

fn pageName(name: []const u8, realm: @import("../entry/Plan.zig").Realm) bool {
    if (realm == .dedicatedWorker and (std.mem.eql(u8, name, "requestAnimationFrame") or std.mem.eql(u8, name, "cancelAnimationFrame"))) return false;
    return page_only.has(name);
}

// WorkerLocation and WorkerNavigator/mixin members from the pinned Webref IDL.
const location_reads = std.StaticStringMap(void).initComptime(.{
    .{"href"}, .{"origin"},   .{"protocol"}, .{"host"}, .{"hostname"},
    .{"port"}, .{"pathname"}, .{"search"},   .{"hash"}, .{"toString"},
});
const navigator_reads = std.StaticStringMap(void).initComptime(.{
    .{"appCodeName"},        .{"appName"},              .{"appVersion"},    .{"platform"},
    .{"product"},            .{"userAgent"},            .{"language"},      .{"languages"},
    .{"onLine"},             .{"hardwareConcurrency"},  .{"connection"},    .{"mediaCapabilities"},
    .{"permissions"},        .{"serviceWorker"},        .{"storage"},       .{"storageBuckets"},
    .{"crossOriginStorage"}, .{"globalPrivacyControl"}, .{"userAgentData"}, .{"usb"},
    .{"locks"},              .{"gpu"},                  .{"ml"},
});

fn memberAllowed(kind: Receiver, member: []const u8, call: bool, realm: @import("../entry/Plan.zig").Realm) bool {
    return switch (kind) {
        .globalThis, .self => !pageName(member, realm) and (!call or std.meta.stringToEnum(Receiver, member) == null),
        .location => if (call) std.mem.eql(u8, member, "toString") else location_reads.has(member),
        .navigator => blk: {
            if (std.mem.eql(u8, member, "setAppBadge") or std.mem.eql(u8, member, "clearAppBadge")) break :blk true;
            if (call) break :blk false;
            if (std.mem.eql(u8, member, "serial")) break :blk realm == .dedicatedWorker;
            if (std.mem.eql(u8, member, "hid")) break :blk realm != .sharedWorker;
            break :blk navigator_reads.has(member);
        },
    };
}

fn pageGlobal(e: anytype, m: Graph.Index, index: u32, seen: *std.DynamicBitSetUnmanaged) std.mem.Allocator.Error!?[]const u8 {
    const b = e.bir(m);
    const root = b.decls[index].body.unwrap() orelse return null;
    const interner = &e.session.interner;
    const interfaces = e.session.resolution.interfaces;
    var todo: std.ArrayList(Bir.Inst.Index) = .empty;
    try todo.append(e.scratch, root);
    while (todo.pop()) |inst| {
        if (inst.int() >= b.insts.len) continue;
        if (seen.isSet(inst.int())) continue;
        seen.set(inst.int());
        const data = b.instData(inst);
        if (b.instTag(inst) == .case) {
            if (JsIntrinsic.droppedArm(e.graph(), interfaces, b, inst, interner, e.options.release, e.options.test_hooks, JsIntrinsic.entryWindow(e.options.platform.entry_host, e.options.library))) |dropped| {
                for (b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index)) |branch| {
                    if (branch != dropped) try todo.append(e.scratch, @fromBackingInt(@intCast(b.instData(branch).rhs)));
                }
                continue;
            }
        }
        if (e.options.platform.entry_host == .unknown) {
            if (JsIntrinsic.of(e.graph(), interfaces, b, inst, interner) == .entryWindow) return "entryWindow";
            try b.operands(e.scratch, inst, &todo);
            continue;
        }
        if (b.instTag(inst) == .ext_value and JsIntrinsic.of(e.graph(), interfaces, b, inst, interner) == .global) return "(computed)";
        if (b.instTag(inst) == .call) {
            const which = JsIntrinsic.of(e.graph(), interfaces, b, @fromBackingInt(@intCast(data.lhs)), interner);
            const args = b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Inst.Index);
            if (which == .global) {
                const name = globalName(e, b, inst) orelse return "(computed)";
                if (std.meta.stringToEnum(Receiver, name) != null) return try std.fmt.allocPrint(e.scratch, "{s} (escaping receiver)", .{name});
                if (pageName(name, e.options.platform.entry_host)) return name;
                continue;
            }
            // Existing direct probes of absent globals remain runtime probes;
            // the four restricted receivers cannot be passed even to a probe.
            if (which == .isUndefined and args.len == 1) if (globalName(e, b, args[0])) |name| {
                if (std.meta.stringToEnum(Receiver, name) == null) continue;
            };
            if ((which == .get or which == .call or which == .set) and args.len >= 2) {
                if (receiver(e, b, args[0])) |kind| {
                    if (which == .set) return try std.fmt.allocPrint(e.scratch, "{s} (receiver write)", .{@tagName(kind)});
                    if (b.instTag(args[1]) != .string) return "(computed member)";
                    const member = b.bytes(args[1]);
                    if (!memberAllowed(kind, member, which == .call, e.options.platform.entry_host)) return try std.fmt.allocPrint(e.scratch, "{s}.{s}", .{ @tagName(kind), member });
                    if (receiver(e, b, inst)) |escaping| return try std.fmt.allocPrint(e.scratch, "{s} (escaping receiver)", .{@tagName(escaping)});
                    // The checked receiver chain consists only of literal reads.
                    // Do not revisit its global as an escaping standalone value.
                    for (args[2..]) |arg| try todo.append(e.scratch, arg);
                    continue;
                }
            }
        }
        try b.operands(e.scratch, inst, &todo);
    }
    return null;
}

/// Check retained access in worker entries, or a retained selector in an
/// unknown entry. Window/node entries and libraries have no raw-global check.
fn refusePageGlobals(e: anytype, module: Graph.Index, decl: u32) std.mem.Allocator.Error!bool {
    for (0..e.graph().count()) |mi| {
        const m: Graph.Index = @fromBackingInt(@intCast(mi));
        // One entry context: shared instruction subtrees need checking only once.
        var seen = try std.DynamicBitSetUnmanaged.initEmpty(e.scratch, e.bir(m).insts.len);
        for (0..e.bir(m).decls.len) |di| {
            if (!e.live.decl(m, di) and !e.live.twin(m, di)) continue;
            const global = try pageGlobal(e, m, @intCast(di), &seen) orelse continue;
            const b = e.bir(m);
            const realm = @tagName(e.options.platform.entry_host);
            if (e.options.platform.entry_host == .unknown) {
                try e.report(.worker_realm_violation, e.graph().moduleFile(module), e.bir(module).decls[decl].name_token, "`Js.entryWindow` needs a known entry realm. Declare `entryHost` for this platform; an entry cannot use the library fallback.", .{});
                return true;
            }
            try e.report(.worker_realm_violation, e.graph().moduleFile(module), e.bir(module).decls[decl].name_token, "`{s}.{s}` uses JavaScript access `{s}`, which is not proved available in entry realm `{s}`.", .{ e.session.interner.slice(e.graph().moduleName(m)), e.session.interner.slice(b.symbol(b.decls[di].name)), global, realm });
            return true;
        }
    }
    return false;
}

pub fn check(e: anytype, module: Graph.Index, decl: u32) std.mem.Allocator.Error!void {
    if (e.options.library) return;
    const realm = e.options.platform.entry_host;
    if ((realm == .dedicatedWorker or realm == .sharedWorker or realm == .serviceWorker or realm == .unknown) and try refusePageGlobals(e, module, decl)) return;
    if (!e.graph().has_native_bindings) return;
    const forbidden = Operations.bit(realm);
    const root_mask = e.session.checked.dispatch[module.int()].effectDecl(decl);
    var roots: std.ArrayList(Reach.Node) = .empty;
    if ((root_mask.realms | root_mask.eval_realms) & forbidden != 0) {
        if (e.live.decl(module, decl)) try roots.append(e.scratch, .{ .module = module, .index = decl, .kind = .decl });
        if (e.live.twin(module, decl)) try roots.append(e.scratch, .{ .module = module, .index = decl, .kind = .twin });
    }
    if (e.worker_runtime orelse e.session.entry_plan.runtime()) |runtime| {
        const mask = e.session.checked.dispatch[runtime.module.int()].effectDecl(runtime.decl);
        if ((mask.realms | mask.eval_realms) & forbidden != 0) try roots.append(e.scratch, .{ .module = runtime.module, .index = runtime.decl, .kind = .decl });
    }
    // Initializers that this projection actually evaluates are roots as well.
    for (e.session.checked.dispatch, 0..) |table, mi| {
        const m: Graph.Index = @fromBackingInt(@intCast(mi));
        for (table.effect_decls, 0..) |effect, di| {
            if (effect.eval_realms & forbidden == 0 or (!e.live.decl(m, di) and !e.live.twin(m, di))) continue;
            if (m == module and di == decl) continue;
            try roots.append(e.scratch, .{ .module = m, .index = @intCast(di), .kind = .decl });
        }
    }
    if (roots.items.len == 0) return;
    const native_reachable = for (0..e.graph().count()) |mi| {
        const m: Graph.Index = @fromBackingInt(@intCast(mi));
        if (e.graph().modulePackage(m) != .core) continue;
        const b = e.bir(m);
        for (b.decls, 0..) |d, di| {
            if ((!e.live.decl(m, di) and !e.live.twin(m, di))) continue;
            const op = Operations.lookup(e.session.interner.slice(e.graph().moduleName(m)), e.session.interner.slice(b.symbol(d.name))) orelse continue;
            if (op.allowed & forbidden != forbidden) break;
        } else continue;
        break true;
    } else false;
    if (!native_reachable) return;
    const Frame = struct { node: Reach.Node, parent: u32 };
    var queue: std.ArrayList(Frame) = .empty;
    // Sparse here: diagnostic-only nodes include derived rows as well as values.
    var seen: std.AutoHashMapUnmanaged(Reach.Node, void) = .empty;
    for (roots.items) |root| {
        const mark = try seen.getOrPut(e.scratch, root);
        if (mark.found_existing) continue;
        try queue.append(e.scratch, .{ .node = root, .parent = none });
    }
    var cursor: u32 = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const node = queue.items[cursor].node;
        if ((node.kind == .decl or node.kind == .twin) and e.graph().modulePackage(node.module) == .core) {
            const b = e.bir(node.module);
            const name = e.session.interner.slice(b.symbol(b.decls[node.index].name));
            if (Operations.lookup(e.session.interner.slice(e.graph().moduleName(node.module)), name)) |operation| {
                if (operation.allowed & forbidden != forbidden) {
                    var path: std.ArrayList(u32) = .empty;
                    var at = cursor;
                    while (at != none) : (at = queue.items[at].parent) try path.append(e.scratch, at);
                    var chain: std.ArrayList(u8) = .empty;
                    var i = path.items.len;
                    while (i > 0) {
                        i -= 1;
                        const step = queue.items[path.items[i]].node;
                        if (chain.items.len != 0) try chain.appendSlice(e.scratch, " → ");
                        const step_name = if (step.kind == .decl or step.kind == .twin) e.session.interner.slice(e.bir(step.module).symbol(e.bir(step.module).decls[step.index].name)) else "<evidence>";
                        try chain.print(e.scratch, "{s}.{s}", .{ e.session.interner.slice(e.graph().moduleName(step.module)), step_name });
                    }
                    var allowed: std.ArrayList(u8) = .empty;
                    inline for (@typeInfo(@import("../entry/Plan.zig").Realm).@"enum".field_names, @typeInfo(@import("../entry/Plan.zig").Realm).@"enum".field_values) |field_name, field_value| {
                        if (operation.allowed & (@as(u8, 1) << @intCast(field_value)) != 0) {
                            if (allowed.items.len != 0) try allowed.appendSlice(e.scratch, ", ");
                            try allowed.appendSlice(e.scratch, field_name);
                        }
                    }
                    if (realm == .unknown) {
                        try e.report(.worker_realm_violation, e.graph().moduleFile(module), e.bir(module).decls[decl].name_token, "Native operation `{s}.{s}` requires a known entry realm. This platform chain does not declare `entryHost`. Allowed realms: {s}.\n\nShortest inferred call or evidence chain: {s}.", .{ operation.owner, operation.member, allowed.items, chain.items });
                        return;
                    }
                    try e.report(.worker_realm_violation, e.graph().moduleFile(module), e.bir(module).decls[decl].name_token, "Native operation `{s}.{s}` is unavailable in entry realm `{s}`. Allowed realms: {s}.\n\nShortest inferred call or evidence chain: {s}.", .{ operation.owner, operation.member, @tagName(realm), allowed.items, chain.items });
                    return;
                }
            }
        }
        if (node.module.int() >= e.edges.len) continue;
        for (e.edges[node.module.int()].targets(node)) |edge| {
            const target = edge.node;
            if (target.kind == .decl and !e.live.decl(target.module, target.index)) continue;
            if (target.kind == .twin and !e.live.twin(target.module, target.index)) continue;
            const mark = try seen.getOrPut(e.scratch, target);
            if (mark.found_existing) continue;
            try queue.append(e.scratch, .{ .node = target, .parent = cursor });
        }
    }
    // A summary cannot lose its native terminal: keep this an explicit compiler
    // defect rather than silently treating an unexplainable obligation as proven.
    try e.report(.worker_realm_violation, e.graph().moduleFile(module), e.bir(module).decls[decl].name_token, "This entry's inferred native availability excludes realm `{s}` (mask {d}). The native call chain could not be reconstructed.", .{ @tagName(realm), root_mask.realms | root_mask.eval_realms });
}
