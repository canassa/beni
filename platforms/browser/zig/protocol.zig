// ownership pin begin: protocol
// ownership pin begin: unit
// ownership pin begin: patch
// ownership pin begin: again
// ownership pin begin: live
// ownership pin begin: eventPayload
// ownership pin begin: nodeContext
// ownership pin begin: contextPresent
// ownership pin begin: contextParent
// ownership pin begin: contextApply
// ownership pin begin: sendRoot
// ownership pin begin: controls
// ownership pin begin: setControls
// ownership pin begin: hasRoot
// ownership pin begin: hasHandler
// ownership pin begin: handlerFlags
// ownership pin begin: first
// ownership pin begin: last
// ownership pin begin: put
// ownership pin begin: drop
// ownership pin begin: swap
// ownership pin begin: parentOf
// ownership pin begin: childMaybe
// ownership pin begin: restate
// ownership pin begin: turn
// ownership pin begin: dead
// ownership pin begin: stop
// ownership pin begin: makeSite
// ownership pin begin: siteScope
// ownership pin begin: setSiteScope
// ownership pin begin: siteData
// ownership pin begin: siteHead
// ownership pin begin: siteTail
// ownership pin begin: siteRestate
// ownership pin begin: siteDispose
//! The private existential half of the DOM producer ABI (interface 1.30,
//! boundary.md §9.4.6). Source owns ranges, slots, rows and scheduling.
//! These ordinary helpers open only a block's paired kind/payload or its
//! paired map context. The lowering supplies them as values of the runtime
//! module `Rt`, once per build, in Rt's own emit unit: the record
//! `protocol` and the two markup primitives `text` and `map`, each its own
//! value so that a build that never maps ships no map kind.
const std = @import("std");
const m = @import("beni_markup");

/// The values of `Rt` this lowering supplies (`Lowering.runtime_protocol`).
pub const values = [_][]const u8{ "protocol", "text", "map", "rootConnection" };

/// The names of `runtime`, which a supplied value reaches.
pub const uses = blk: {
    var names: [runtime.len][]const u8 = undefined;
    for (runtime, &names) |r, *n| n.* = r.name;
    const out = names;
    break :blk out;
};

/// The runtime exports the supplied values' expressions name.
pub const runtime = [_]m.RuntimeExport{
    .{ .name = "protocol", .arity = 0 },
    .{ .name = "empty", .arity = 0 },
    .{ .name = "protocolTextNode", .arity = 1 },
    .{ .name = "protocolSlot", .arity = 3 },
    .{ .name = "protocolFirst", .arity = 1 },
    .{ .name = "protocolLast", .arity = 1 },
    .{ .name = "protocolPut", .arity = 3 },
    .{ .name = "protocolDrop", .arity = 1 },
    .{ .name = "protocolSwap", .arity = 2 },
    .{ .name = "protocolParentOf", .arity = 1 },
    .{ .name = "protocolChildMaybe", .arity = 2 },
    .{ .name = "protocolRestate", .arity = 1 },
    .{ .name = "protocolTurn", .arity = 2 },
    .{ .name = "protocolDead", .arity = 0 },
    .{ .name = "protocolStop", .arity = 0 },
};

// ownership pin begin: domProtocol
/// The expression of supplied value `name`, written into Rt's unit. Every
/// helper is hoisted once in that unit; no factory runs per view or row.
pub fn supply(cx: *m.Context, name: []const u8) m.Error!m.Expr {
    const b: Builder = .{ .cx = cx };
    if (std.mem.eql(u8, name, "text")) return b.text();
    if (std.mem.eql(u8, name, "map")) return b.map();
    if (std.mem.eql(u8, name, "protocol")) return b.record();
    if (std.mem.eql(u8, name, "rootConnection")) return b.rootConnection();
    unreachable;
}

const Builder = struct {
    cx: *m.Context,

    fn js(b: Builder) m.Js {
        return b.cx.js;
    }

    fn name(b: Builder, hint: []const u8) m.Error!m.Name {
        return b.cx.fresh(hint);
    }

    fn read(b: Builder, name_: m.Name) m.Error!m.Expr {
        return b.js().name(name_);
    }

    fn member(b: Builder, name_: m.Name, field: []const u8) m.Error!m.Expr {
        return b.js().member(try b.read(name_), field);
    }

    fn rt(b: Builder, export_name: []const u8) m.Error!m.Expr {
        return b.js().name(try b.cx.runtime(export_name));
    }

    fn function(b: Builder, hint: []const u8, params: []const m.Name, body: m.Block) m.Error!m.Name {
        if (b.cx.hoisted(hint)) |existing| return existing;
        return b.cx.hoistFunction(hint, params, body);
    }

    fn project(b: Builder, hint: []const u8, field: []const u8, truth: bool) m.Error!m.Name {
        if (b.cx.hoisted(hint)) |existing| return existing;
        const value = try b.name("value");
        const body = try b.js().block();
        const read_ = try b.member(value, field);
        try b.js().@"return"(body, if (truth)
            try b.js().binary(.strict_eq, read_, try b.js().literal(.true))
        else
            read_);
        return b.function(hint, &.{value}, body);
    }

    fn unit(b: Builder) m.Error!m.Name {
        if (b.cx.hoisted("domUnit")) |existing| return existing;
        const block = try b.name("block");
        const context = try b.name("context");
        const instance = try b.name("instance");
        const body = try b.js().block();
        const kind = try b.member(block, "t");
        try b.js().constant(body, instance, try b.js().call(try b.js().member(kind, "m"), &.{ try b.member(block, "v"), try b.read(context) }));
        try b.js().assign(body, try b.member(instance, "$t"), kind);
        try b.js().assign(body, try b.member(instance, "$b"), try b.read(block));
        try b.js().@"return"(body, try b.read(instance));
        return b.function("domUnit", &.{ block, context }, body);
    }

    fn patch(b: Builder) m.Error!m.Name {
        if (b.cx.hoisted("domPatch")) |existing| return existing;
        const unit_ = try b.unit();
        const instance = try b.name("instance");
        const block = try b.name("block");
        const context = try b.name("context");
        const replacement = try b.name("replacement");
        const body = try b.js().block();
        const same = try b.js().block();
        const kind = try b.member(block, "t");
        try b.js().expression(same, try b.js().call(try b.js().member(kind, "p"), &.{ try b.read(instance), try b.member(block, "v") }));
        try b.js().assign(same, try b.member(instance, "$b"), try b.read(block));
        try b.js().@"return"(same, try b.read(instance));
        try b.js().@"if"(body, try b.js().binary(.strict_eq, kind, try b.member(instance, "$t")), same, null);
        try b.js().constant(body, replacement, try b.js().call(try b.read(unit_), &.{ try b.read(block), try b.read(context) }));
        try b.js().expression(body, try b.js().call(try b.rt("protocolSwap"), &.{ try b.read(instance), try b.read(replacement) }));
        try b.js().@"return"(body, try b.read(replacement));
        return b.function("domPatch", &.{ instance, block, context }, body);
    }

    // Private producer operations; chooseRoot proves the single-node and same-kind preconditions.
    // ownership pin begin: rootConnection
    // ownership pin begin: createRoot
    // ownership pin begin: nodeRoot
    // ownership pin begin: patchRoot
    fn rootConnection(b: Builder) m.Error!m.Expr {
        const block = try b.name("block");
        const make_body = try b.js().block();
        try b.js().@"return"(make_body, try b.js().call(try b.read(try b.unit()), &.{ try b.read(block), try b.js().literal(.null) }));
        const make = try b.function("domRootCreate", &.{block}, make_body);
        const node = try b.project("domRootNode", "s", false);
        const instance = try b.name("instance");
        const fresh = try b.name("block");
        const patch_body = try b.js().block();
        const kind = try b.member(fresh, "t");
        try b.js().expression(patch_body, try b.js().call(try b.js().member(kind, "p"), &.{ try b.read(instance), try b.member(fresh, "v") }));
        try b.js().assign(patch_body, try b.member(instance, "$b"), try b.read(fresh));
        const patch_ = try b.function("domRootPatch", &.{ instance, fresh }, patch_body);
        return b.js().object(&.{
            .{ .key = "createRoot", .value = try b.read(make), .source = true },
            .{ .key = "nodeRoot", .value = try b.read(node), .source = true },
            .{ .key = "patchRoot", .value = try b.read(patch_), .source = true },
        });
    }

    // ownership pin end: patchRoot
    // ownership pin end: nodeRoot
    // ownership pin end: createRoot
    // ownership pin end: rootConnection

    fn live(b: Builder) m.Error!m.Name {
        return b.project("domLive", "$l", true);
    }

    fn again(b: Builder) m.Error!m.Name {
        if (b.cx.hoisted("domAgain")) |existing| return existing;
        const instance = try b.name("instance");
        const body = try b.js().block();
        const block = try b.member(instance, "$b");
        const kind = try b.member(instance, "$t");
        try b.js().expression(body, try b.js().call(try b.js().member(kind, "p"), &.{ try b.read(instance), try b.js().member(block, "v") }));
        return b.function("domAgain", &.{instance}, body);
    }

    /// `Html.text`: a block of the text kind, hoisted once per build.
    fn text(b: Builder) m.Error!m.Expr {
        const value = try b.name("value");
        const node = try b.name("node");
        const mount = try b.js().block();
        try b.js().constant(mount, node, try b.js().call(try b.rt("protocolTextNode"), &.{try b.read(value)}));
        try b.js().@"return"(mount, try b.js().object(&.{
            .{ .key = "s", .value = try b.read(node), .source = true },
            .{ .key = "q", .value = try b.rt("empty"), .source = true },
            .{ .key = "e", .value = try b.read(node), .source = true },
            .{ .key = "$d", .value = try b.read(value) },
        }));
        const make = try b.function("domTextMount", &.{value}, mount);
        const instance = try b.name("instance");
        const fresh = try b.name("value");
        const patch_body = try b.js().block();
        const changed = try b.js().block();
        try b.js().assign(changed, try b.member(instance, "$d"), try b.read(fresh));
        try b.js().assign(changed, try b.js().member(try b.js().field(try b.read(instance), "s"), "data"), try b.read(fresh));
        try b.js().@"if"(patch_body, try b.js().binary(.strict_ne, try b.read(fresh), try b.member(instance, "$d")), changed, null);
        const update = try b.function("domTextPatch", &.{ instance, fresh }, patch_body);
        const kind = try b.cx.hoist("textKind", try b.js().object(&.{
            .{ .key = "m", .value = try b.read(make) },
            .{ .key = "p", .value = try b.read(update) },
        }));
        const shown = try b.name("value");
        const body = try b.js().block();
        try b.js().@"return"(body, try b.js().object(&.{
            .{ .key = "t", .value = try b.read(kind) },
            .{ .key = "v", .value = try b.read(shown) },
        }));
        return b.js().arrow(&.{shown}, body);
    }

    /// `Html.map`: a block of the map kind, hoisted once per build. Its
    /// instance keeps a context that sends through the mapper, then up.
    fn map(b: Builder) m.Error!m.Expr {
        const unit_ = try b.unit();
        const patch_ = try b.patch();
        const live_ = try b.live();
        const value = try b.name("value");
        const context = try b.name("context");
        const own = try b.name("mapContext");
        const location = try b.name("mapSlot");
        const child = try b.name("mapped");
        const mount = try b.js().block();
        const html = try b.js().index(try b.read(value), try b.js().number("0"));
        const mapper = try b.js().index(try b.read(value), try b.js().number("1"));
        try b.js().constant(mount, own, try b.js().object(&.{
            .{ .key = "f", .value = mapper },
            .{ .key = "up", .value = try b.read(context) },
        }));
        try b.js().constant(mount, location, try b.js().call(try b.rt("protocolSlot"), &.{ try b.rt("empty"), try b.rt("empty"), try b.read(own) }));
        try b.js().constant(mount, child, try b.js().call(try b.read(unit_), &.{ html, try b.read(own) }));
        try b.js().assign(mount, try b.js().field(try b.read(location), "i"), try b.read(child));
        const alive = try b.js().call(try b.read(live_), &.{try b.read(child)});
        try b.js().assign(mount, try b.js().field(try b.read(location), "l"), alive);
        try b.js().@"return"(mount, try b.js().object(&.{
            .{ .key = "s", .value = try b.rt("empty"), .source = true },
            .{ .key = "q", .value = try b.read(location), .source = true },
            .{ .key = "e", .value = try b.rt("empty"), .source = true },
            .{ .key = "$c", .value = try b.read(own) },
            .{ .key = "$l", .value = alive },
        }));
        const make = try b.function("domMapMount", &.{ value, context }, mount);
        const instance = try b.name("instance");
        const fresh = try b.name("value");
        const html2 = try b.js().index(try b.read(fresh), try b.js().number("0"));
        const mapper2 = try b.js().index(try b.read(fresh), try b.js().number("1"));
        const place = try b.name("mapSlot");
        const replaced = try b.name("mapped");
        const update = try b.js().block();
        const current = try b.member(instance, "$c");
        try b.js().assign(update, try b.js().member(current, "f"), mapper2);
        try b.js().constant(update, place, try b.js().field(try b.read(instance), "q"));
        try b.js().constant(update, replaced, try b.js().call(try b.read(patch_), &.{ try b.js().field(try b.read(place), "i"), html2, current }));
        try b.js().assign(update, try b.js().field(try b.read(place), "i"), try b.read(replaced));
        const live2 = try b.js().call(try b.read(live_), &.{try b.read(replaced)});
        try b.js().assign(update, try b.js().field(try b.read(place), "l"), live2);
        try b.js().assign(update, try b.member(instance, "$l"), try b.js().field(try b.read(place), "l"));
        const patch_fn = try b.function("domMapPatch", &.{ instance, fresh }, update);
        const kind = try b.cx.hoist("mapKind", try b.js().object(&.{
            .{ .key = "l", .value = try b.js().literal(.true) },
            .{ .key = "m", .value = try b.read(make) },
            .{ .key = "p", .value = try b.read(patch_fn) },
        }));
        const block = try b.name("block");
        const mapper_ = try b.name("mapper");
        const body = try b.js().block();
        try b.js().@"return"(body, try b.js().object(&.{
            .{ .key = "t", .value = try b.read(kind) },
            .{ .key = "v", .value = try b.js().array(&.{ try b.read(block), try b.read(mapper_) }) },
        }));
        return b.js().arrow(&.{ block, mapper_ }, body);
    }

    fn eventPayload(b: Builder) m.Error!m.Name {
        const node = try b.name("node");
        const event = try b.name("event");
        const key = try b.name("key");
        const payload = try b.name("payload");
        const extract = try b.name("extract");
        const body = try b.js().block();
        try b.js().constant(body, extract, try b.js().index(try b.read(node), try b.read(payload)));
        const handler = try b.js().index(try b.read(node), try b.read(key));
        const no_payload = try b.js().binary(.strict_eq, try b.read(extract), try b.js().literal(.undefined));
        const message = try b.js().call(handler, &.{try b.js().call(try b.read(extract), &.{try b.read(event)})});
        try b.js().@"return"(body, try b.js().cond(no_payload, handler, message));
        return b.function("domEventPayload", &.{ node, event, key, payload }, body);
    }

    fn nodeContext(b: Builder) m.Error!m.Name {
        const node = try b.name("node");
        const value = try b.name("context");
        const body = try b.js().block();
        try b.js().constant(body, value, try b.member(node, "$$cx"));
        try b.js().@"return"(body, try b.js().cond(try b.js().binary(.strict_eq, try b.read(value), try b.js().literal(.undefined)), try b.js().literal(.null), try b.read(value)));
        return b.function("domNodeContext", &.{node}, body);
    }

    fn contextPresent(b: Builder) m.Error!m.Name {
        const context = try b.name("context");
        const body = try b.js().block();
        try b.js().@"return"(body, try b.js().binary(.strict_ne, try b.read(context), try b.js().literal(.null)));
        return b.function("domContextPresent", &.{context}, body);
    }

    fn contextApply(b: Builder) m.Error!m.Name {
        const context = try b.name("context");
        const message = try b.name("message");
        const body = try b.js().block();
        try b.js().@"return"(body, try b.js().call(try b.member(context, "f"), &.{try b.read(message)}));
        return b.function("domContextApply", &.{ context, message }, body);
    }

    fn sendRoot(b: Builder) m.Error!m.Name {
        const node = try b.name("node");
        const message = try b.name("message");
        const body = try b.js().block();
        try b.js().expression(body, try b.js().call(try b.member(node, "$$root"), &.{try b.read(message)}));
        return b.function("domSendRoot", &.{ node, message }, body);
    }

    fn controls(b: Builder) m.Error!m.Name {
        const node = try b.name("node");
        const value = try b.name("controls");
        const body = try b.js().block();
        try b.js().constant(body, value, try b.member(node, "$$s"));
        try b.js().@"return"(body, try b.js().cond(
            try b.js().binary(.strict_eq, try b.read(value), try b.js().literal(.undefined)),
            try b.rt("empty"),
            try b.read(value),
        ));
        return b.function("domControls", &.{node}, body);
    }

    fn setControls(b: Builder) m.Error!m.Name {
        const node = try b.name("node");
        const value = try b.name("controls");
        const body = try b.js().block();
        try b.js().assign(body, try b.member(node, "$$s"), try b.read(value));
        return b.function("domSetControls", &.{ node, value }, body);
    }

    fn hasRoot(b: Builder) m.Error!m.Name {
        const node = try b.name("node");
        const body = try b.js().block();
        try b.js().@"return"(body, try b.js().binary(.strict_ne, try b.member(node, "$$root"), try b.js().literal(.undefined)));
        return b.function("domHasRoot", &.{node}, body);
    }

    fn hasHandler(b: Builder) m.Error!m.Name {
        const node = try b.name("node");
        const key = try b.name("key");
        const body = try b.js().block();
        try b.js().@"return"(body, try b.js().binary(.strict_ne, try b.js().index(try b.read(node), try b.read(key)), try b.js().literal(.undefined)));
        return b.function("domHasHandler", &.{ node, key }, body);
    }

    fn handlerFlags(b: Builder) m.Error!m.Name {
        const node = try b.name("node");
        const key = try b.name("key");
        const flags = try b.name("flags");
        const body = try b.js().block();
        try b.js().constant(body, flags, try b.js().index(try b.read(node), try b.read(key)));
        try b.js().@"return"(body, try b.js().cond(try b.js().binary(.strict_eq, try b.read(flags), try b.js().literal(.undefined)), try b.js().number("0"), try b.read(flags)));
        return b.function("domHandlerFlags", &.{ node, key }, body);
    }

    fn makeSite(b: Builder) m.Error!m.Name {
        const operations = try b.name("operations");
        const scope = try b.name("scope");
        const data = try b.name("data");
        const body = try b.js().block();
        try b.js().@"return"(body, try b.js().object(&.{
            .{ .key = "ops", .value = try b.read(operations) },
            .{ .key = "scope", .value = try b.read(scope) },
            .{ .key = "data", .value = try b.read(data) },
        }));
        return b.function("domMakeSite", &.{ operations, scope, data }, body);
    }

    fn setSiteScope(b: Builder) m.Error!m.Name {
        const site = try b.name("site");
        const operations = try b.name("operations");
        const scope = try b.name("scope");
        const body = try b.js().block();
        try b.js().assign(body, try b.member(site, "ops"), try b.read(operations));
        try b.js().assign(body, try b.member(site, "scope"), try b.read(scope));
        return b.function("domSetSiteScope", &.{ site, operations, scope }, body);
    }

    fn siteCall(b: Builder, hint: []const u8, method: []const u8, stamped: bool) m.Error!m.Name {
        const site = try b.name("site");
        const slot = try b.name("slot");
        const stamp = if (stamped) try b.name("stamp") else null;
        const body = try b.js().block();
        const callback = try b.js().field(try b.member(site, "ops"), method);
        const args = [_]m.Expr{ try b.member(site, "scope"), try b.member(site, "data"), try b.read(slot), if (stamp) |n| try b.read(n) else try b.read(slot) };
        const call = try b.js().call(callback, args[0..if (stamped) @as(usize, 4) else 3]);
        try b.js().@"return"(body, call);
        const params = [_]m.Name{ site, slot, stamp orelse slot };
        return b.function(hint, params[0..if (stamped) @as(usize, 3) else 2], body);
    }

    /// The private record, one per build. Its fields are the hoisted
    /// helpers and arrows into Rt's own algorithms.
    fn record(b: Builder) m.Error!m.Expr {
        var fields: std.ArrayList(m.Property) = .empty;
        try fields.append(b.cx.arena, .{ .key = "none", .value = try b.js().literal(.null), .source = true });
        const direct = [_]struct { []const u8, m.Name }{
            .{ "unit", try b.unit() },
            .{ "patch", try b.patch() },
            .{ "again", try b.again() },
            .{ "live", try b.live() },
            .{ "eventPayload", try b.eventPayload() },
            .{ "nodeContext", try b.nodeContext() },
            .{ "contextPresent", try b.contextPresent() },
            .{ "contextParent", try b.project("domContextParent", "up", false) },
            .{ "contextApply", try b.contextApply() },
            .{ "sendRoot", try b.sendRoot() },
            .{ "controls", try b.controls() },
            .{ "setControls", try b.setControls() },
            .{ "hasRoot", try b.hasRoot() },
            .{ "hasHandler", try b.hasHandler() },
            .{ "handlerFlags", try b.handlerFlags() },
            .{ "makeSite", try b.makeSite() },
            .{ "siteScope", try b.project("domSiteScope", "scope", false) },
            .{ "setSiteScope", try b.setSiteScope() },
            .{ "siteData", try b.project("domSiteData", "data", false) },
            .{ "siteHead", try b.siteCall("domSiteHead", "head", false) },
            .{ "siteTail", try b.siteCall("domSiteTail", "tail", false) },
            .{ "siteRestate", try b.siteCall("domSiteRestate", "restate", true) },
            .{ "siteDispose", try b.siteCall("domSiteDispose", "dispose", false) },
        };
        for (direct) |field| try fields.append(b.cx.arena, .{ .key = field[0], .value = try b.read(field[1]), .source = true });
        // Rt's algorithms, reached through an arrow so the record is made
        // whatever order Rt's declarations are written in.
        const forwards = [_]struct { field: []const u8, target: []const u8, arity: u8 }{
            .{ .field = "first", .target = "protocolFirst", .arity = 1 },
            .{ .field = "last", .target = "protocolLast", .arity = 1 },
            .{ .field = "put", .target = "protocolPut", .arity = 3 },
            .{ .field = "drop", .target = "protocolDrop", .arity = 1 },
            .{ .field = "swap", .target = "protocolSwap", .arity = 2 },
            .{ .field = "parentOf", .target = "protocolParentOf", .arity = 1 },
            .{ .field = "childMaybe", .target = "protocolChildMaybe", .arity = 2 },
            .{ .field = "restate", .target = "protocolRestate", .arity = 1 },
            .{ .field = "turn", .target = "protocolTurn", .arity = 2 },
            .{ .field = "dead", .target = "protocolDead", .arity = 0 },
            .{ .field = "stop", .target = "protocolStop", .arity = 0 },
        };
        for (forwards) |forward| {
            const params = try b.cx.arena.alloc(m.Name, forward.arity);
            const args = try b.cx.arena.alloc(m.Expr, forward.arity);
            for (params, args) |*param, *arg| {
                param.* = try b.cx.fresh("argument");
                arg.* = try b.js().name(param.*);
            }
            const body = try b.js().block();
            try b.js().@"return"(body, try b.js().call(try b.rt(forward.target), args));
            try fields.append(b.cx.arena, .{ .key = forward.field, .value = try b.js().arrow(params, body), .source = true });
        }
        return b.js().object(fields.items);
    }
};
/// A checked vocabulary member, not a runtime string inspector. The type
/// class belongs to the cache key; the caller supplies only its checked raw
/// property representation. Maybe String is already null/String here.
/// This is the same module-level hoist mechanism as a DOM kind, never a
/// descriptor factory executed by a node or event.
pub fn property(cx: *m.Context, native_name: []const u8, class: m.Class, immutable: bool) m.Error!m.Name {
    var encoded: std.ArrayList(u8) = .empty;
    try encoded.appendSlice(cx.arena, "domProperty_");
    const hex = "0123456789abcdef";
    for (native_name) |byte| {
        try encoded.append(cx.arena, hex[byte >> 4]);
        try encoded.append(cx.arena, hex[byte & 15]);
    }
    const hint = try std.fmt.allocPrint(cx.arena, "{s}_{d}", .{ encoded.items, @backingInt(class) });
    if (cx.hoisted(hint)) |existing| return existing;
    const node = try cx.fresh("propertyNode");
    const value = try cx.fresh("propertyValue");
    const getter = try cx.js.block();
    try cx.js.@"return"(getter, try cx.js.member(try cx.js.name(node), native_name));
    const get = try cx.hoistFunction(try std.fmt.allocPrint(cx.arena, "{s}_get", .{hint}), &.{node}, getter);
    const setter = try cx.js.block();
    try cx.js.assign(setter, try cx.js.member(try cx.js.name(node), native_name), try cx.js.name(value));
    const set = try cx.hoistFunction(try std.fmt.allocPrint(cx.arena, "{s}_set", .{hint}), &.{ node, value }, setter);
    return cx.hoist(hint, try cx.js.object(&.{
        .{ .key = "name", .value = try cx.js.string(native_name), .source = true },
        .{ .key = "immutable", .value = try cx.js.literal(if (immutable) .true else .false), .source = true },
        .{ .key = "get", .value = try cx.js.name(get), .source = true },
        .{ .key = "set", .value = try cx.js.name(set), .source = true },
    }));
}
// ownership pin end: domProtocol

// ownership pin end: siteDispose
// ownership pin end: siteRestate
// ownership pin end: siteTail
// ownership pin end: siteHead
// ownership pin end: siteData
// ownership pin end: setSiteScope
// ownership pin end: siteScope
// ownership pin end: makeSite
// ownership pin end: stop
// ownership pin end: dead
// ownership pin end: turn
// ownership pin end: restate
// ownership pin end: childMaybe
// ownership pin end: parentOf
// ownership pin end: swap
// ownership pin end: drop
// ownership pin end: put
// ownership pin end: last
// ownership pin end: first
// ownership pin end: handlerFlags
// ownership pin end: hasHandler
// ownership pin end: hasRoot
// ownership pin end: setControls
// ownership pin end: controls
// ownership pin end: sendRoot
// ownership pin end: contextApply
// ownership pin end: contextParent
// ownership pin end: contextPresent
// ownership pin end: nodeContext
// ownership pin end: eventPayload
// ownership pin end: live
// ownership pin end: again
// ownership pin end: patch
// ownership pin end: unit
// ownership pin end: protocol
