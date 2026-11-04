//! The private existential half of the DOM producer ABI (interface 1.28).
//! Source owns ranges, slots, rows and scheduling. These ordinary helpers
//! open only a block's paired kind/payload or its paired map context.
const std = @import("std");
const m = @import("beni_markup");

pub const Core = struct {
    unit: m.Name,
    patch: m.Name,
    again: m.Name,
    live: m.Name,
    text: m.Name,
    map: m.Name,
    event_payload: m.Name,
    node_context: m.Name,
    context_present: m.Name,
    context_parent: m.Name,
    context_apply: m.Name,
    send_root: m.Name,
    controls: m.Name,
    set_controls: m.Name,
    has_root: m.Name,
    has_handler: m.Name,
    handler_flags: m.Name,
    make_site: m.Name,
    site_scope: m.Name,
    set_site_scope: m.Name,
    site_data: m.Name,
    site_head: m.Name,
    site_tail: m.Name,
    site_restate: m.Name,
    site_dispose: m.Name,
};

// ownership pin begin: domProtocol
/// One set per independent emit/cache unit; no per-view helper factory.
/// Runtime exports used below are typed Source algorithms, never Js.Value
/// adapters. Native DOM work remains in the reviewed catalogue.
pub fn emit(cx: *m.Context, protocol: m.Name, into: m.Block) m.Error!Core {
    const b: Builder = .{ .cx = cx, .protocol = protocol, .into = into };
    const unit = try b.unit();
    const patch = try b.patch(unit);
    const live = try b.project("domLive", "l", true);
    return .{
        .unit = unit,
        .patch = patch,
        .again = try b.again(),
        .live = live,
        .text = try b.text(),
        .map = try b.map(unit, patch, live),
        .event_payload = try b.eventPayload(),
        .node_context = try b.nodeContext(),
        .context_present = try b.contextPresent(),
        .context_parent = try b.project("domContextParent", "up", false),
        .context_apply = try b.contextApply(),
        .send_root = try b.sendRoot(),
        .controls = try b.controls(),
        .set_controls = try b.setControls(),
        .has_root = try b.hasRoot(),
        .has_handler = try b.hasHandler(),
        .handler_flags = try b.handlerFlags(),
        .make_site = try b.makeSite(),
        .site_scope = try b.project("domSiteScope", "scope", false),
        .set_site_scope = try b.setSiteScope(),
        .site_data = try b.project("domSiteData", "data", false),
        .site_head = try b.siteCall("domSiteHead", "head", false),
        .site_tail = try b.siteCall("domSiteTail", "tail", false),
        .site_restate = try b.siteCall("domSiteRestate", "restate", true),
        .site_dispose = try b.siteCall("domSiteDispose", "dispose", false),
    };
}

const Builder = struct {
    cx: *m.Context,
    protocol: m.Name,
    into: m.Block,

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

    fn function(b: Builder, hint: []const u8, params: []const m.Name, body: m.Block) m.Error!m.Name {
        const result = try b.cx.fresh(hint);
        try b.js().constant(b.into, result, try b.js().arrow(params, body));
        return result;
    }

    fn project(b: Builder, hint: []const u8, field: []const u8, truth: bool) m.Error!m.Name {
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
        const block = try b.name("block");
        const context = try b.name("context");
        const instance = try b.name("instance");
        const body = try b.js().block();
        const kind = try b.member(block, "t");
        try b.js().constant(body, instance, try b.js().call(try b.js().member(kind, "m"), &.{ try b.member(block, "v"), try b.read(context) }));
        try b.js().assign(body, try b.member(instance, "t"), kind);
        try b.js().assign(body, try b.member(instance, "b"), try b.read(block));
        try b.js().@"return"(body, try b.read(instance));
        return b.function("domUnit", &.{ block, context }, body);
    }

    fn patch(b: Builder, unit_: m.Name) m.Error!m.Name {
        const instance = try b.name("instance");
        const block = try b.name("block");
        const context = try b.name("context");
        const replacement = try b.name("replacement");
        const body = try b.js().block();
        const same = try b.js().block();
        const kind = try b.member(block, "t");
        try b.js().expression(same, try b.js().call(try b.js().member(kind, "p"), &.{ try b.read(instance), try b.member(block, "v") }));
        try b.js().assign(same, try b.member(instance, "b"), try b.read(block));
        try b.js().@"return"(same, try b.read(instance));
        try b.js().@"if"(body, try b.js().binary(.strict_eq, kind, try b.member(instance, "t")), same, null);
        try b.js().constant(body, replacement, try b.js().call(try b.read(unit_), &.{ try b.read(block), try b.read(context) }));
        try b.js().expression(body, try b.js().call(try b.js().name(try b.cx.runtime("protocolSwap")), &.{ try b.read(b.protocol), try b.read(instance), try b.read(replacement) }));
        try b.js().@"return"(body, try b.read(replacement));
        return b.function("domPatch", &.{ instance, block, context }, body);
    }

    fn again(b: Builder) m.Error!m.Name {
        const instance = try b.name("instance");
        const body = try b.js().block();
        const block = try b.member(instance, "b");
        const kind = try b.member(instance, "t");
        try b.js().expression(body, try b.js().call(try b.js().member(kind, "p"), &.{ try b.read(instance), try b.js().member(block, "v") }));
        return b.function("domAgain", &.{instance}, body);
    }

    fn empty(b: Builder) m.Error!m.Expr {
        return b.js().name(try b.cx.runtime("protocolEmpty"));
    }

    fn text(b: Builder) m.Error!m.Name {
        const value = try b.name("value");
        const node = try b.name("node");
        const mount = try b.js().block();
        try b.js().constant(mount, node, try b.js().call(try b.js().name(try b.cx.runtime("protocolTextNode")), &.{try b.read(value)}));
        try b.js().@"return"(mount, try b.js().object(&.{
            .{ .key = "s", .value = try b.read(node), .source = true },
            .{ .key = "q", .value = try b.empty(), .source = true },
            .{ .key = "e", .value = try b.read(node), .source = true },
            .{ .key = "d", .value = try b.read(value) },
        }));
        const make = try b.function("domTextMount", &.{value}, mount);
        const instance = try b.name("instance");
        const patch_body = try b.js().block();
        const changed = try b.js().block();
        try b.js().assign(changed, try b.member(instance, "d"), try b.read(value));
        try b.js().assign(changed, try b.js().member(try b.js().field(try b.read(instance), "s"), "data"), try b.read(value));
        try b.js().@"if"(patch_body, try b.js().binary(.strict_ne, try b.read(value), try b.member(instance, "d")), changed, null);
        const update = try b.function("domTextPatch", &.{ instance, value }, patch_body);
        const kind = try b.name("textKind");
        try b.js().constant(b.into, kind, try b.js().object(&.{
            .{ .key = "m", .value = try b.read(make) },
            .{ .key = "p", .value = try b.read(update) },
        }));
        const body = try b.js().block();
        try b.js().@"return"(body, try b.js().object(&.{
            .{ .key = "t", .value = try b.read(kind) },
            .{ .key = "v", .value = try b.read(value) },
        }));
        return b.function("domText", &.{value}, body);
    }

    fn map(b: Builder, unit_: m.Name, patch_: m.Name, live_: m.Name) m.Error!m.Name {
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
        try b.js().constant(mount, location, try b.js().call(try b.js().name(try b.cx.runtime("protocolSlot")), &.{ try b.empty(), try b.empty(), try b.read(own) }));
        try b.js().constant(mount, child, try b.js().call(try b.read(unit_), &.{ html, try b.read(own) }));
        try b.js().assign(mount, try b.js().field(try b.read(location), "i"), try b.read(child));
        const live = try b.js().call(try b.read(live_), &.{try b.read(child)});
        try b.js().assign(mount, try b.js().field(try b.read(location), "l"), live);
        try b.js().@"return"(mount, try b.js().object(&.{
            .{ .key = "s", .value = try b.empty(), .source = true },
            .{ .key = "q", .value = try b.read(location), .source = true },
            .{ .key = "e", .value = try b.empty(), .source = true },
            .{ .key = "c", .value = try b.read(own) },
            .{ .key = "l", .value = live },
        }));
        const make = try b.function("domMapMount", &.{ value, context }, mount);
        const instance = try b.name("instance");
        const update = try b.js().block();
        const current = try b.member(instance, "c");
        try b.js().assign(update, try b.js().member(current, "f"), mapper);
        try b.js().constant(update, location, try b.js().field(try b.read(instance), "q"));
        try b.js().constant(update, child, try b.js().call(try b.read(patch_), &.{ try b.js().field(try b.read(location), "i"), html, current }));
        try b.js().assign(update, try b.js().field(try b.read(location), "i"), try b.read(child));
        try b.js().assign(update, try b.js().field(try b.read(location), "l"), live);
        try b.js().assign(update, try b.member(instance, "l"), live);
        const patch_fn = try b.function("domMapPatch", &.{ instance, value }, update);
        const kind = try b.name("mapKind");
        try b.js().constant(b.into, kind, try b.js().object(&.{
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
        return b.function("domMap", &.{ block, mapper_ }, body);
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
            try b.js().name(try b.cx.runtime("protocolEmpty")),
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
/// Initialize one private record per independent emit/cache unit. The
/// initializer runs only at module evaluation. Its local functions share
/// the completed record; no factory executes during a view, row or event.
pub fn record(cx: *m.Context) m.Error!m.Name {
    if (cx.hoisted("domProtocol")) |existing| return existing;
    const into = try cx.js.block();
    const self = try cx.fresh("protocol");
    const core = try emit(cx, self, into);
    var fields: std.ArrayList(m.Property) = .empty;
    try fields.append(cx.arena, .{ .key = "none", .value = try cx.js.literal(.null), .source = true });
    const direct = .{
        .{ "unit", core.unit },                      .{ "patch", core.patch },
        .{ "again", core.again },                    .{ "live", core.live },
        .{ "text", core.text },                      .{ "map", core.map },
        .{ "eventPayload", core.event_payload },     .{ "nodeContext", core.node_context },
        .{ "contextPresent", core.context_present }, .{ "contextParent", core.context_parent },
        .{ "contextApply", core.context_apply },     .{ "sendRoot", core.send_root },
        .{ "controls", core.controls },              .{ "setControls", core.set_controls },
        .{ "hasRoot", core.has_root },               .{ "hasHandler", core.has_handler },
        .{ "handlerFlags", core.handler_flags },     .{ "makeSite", core.make_site },
        .{ "siteScope", core.site_scope },           .{ "setSiteScope", core.set_site_scope },
        .{ "siteData", core.site_data },             .{ "siteHead", core.site_head },
        .{ "siteTail", core.site_tail },             .{ "siteRestate", core.site_restate },
        .{ "siteDispose", core.site_dispose },
    };
    inline for (direct) |field| try fields.append(cx.arena, .{ .key = field[0], .value = try cx.js.name(field[1]), .source = true });
    const forwards = [_]struct { field: []const u8, target: []const u8, arity: u8, paired: bool = true }{
        .{ .field = "fire", .target = "protocolFire", .arity = 5 },
        .{ .field = "first", .target = "protocolFirst", .arity = 1 },
        .{ .field = "last", .target = "protocolLast", .arity = 1 },
        .{ .field = "put", .target = "protocolPut", .arity = 3 },
        .{ .field = "drop", .target = "protocolDrop", .arity = 1 },
        .{ .field = "swap", .target = "protocolSwap", .arity = 2 },
        .{ .field = "parentOf", .target = "protocolParentOf", .arity = 1, .paired = false },
        .{ .field = "childMaybe", .target = "protocolChildMaybe", .arity = 2 },
        .{ .field = "restate", .target = "protocolRestate", .arity = 1 },
        .{ .field = "turn", .target = "protocolTurn", .arity = 2, .paired = false },
        .{ .field = "dead", .target = "protocolDead", .arity = 0, .paired = false },
        .{ .field = "stop", .target = "protocolStop", .arity = 0, .paired = false },
    };
    for (forwards) |forward| {
        const params = try cx.arena.alloc(m.Name, forward.arity);
        const args = try cx.arena.alloc(m.Expr, params.len + @intFromBool(forward.paired));
        if (forward.paired) args[0] = try cx.js.name(self);
        for (params, 0..) |*param, i| {
            param.* = try cx.fresh("argument");
            args[i + @intFromBool(forward.paired)] = try cx.js.name(param.*);
        }
        const body = try cx.js.block();
        try cx.js.@"return"(body, try cx.js.call(try cx.js.name(try cx.runtime(forward.target)), args));
        try fields.append(cx.arena, .{ .key = forward.field, .value = try cx.js.arrow(params, body), .source = true });
    }
    try cx.js.constant(into, self, try cx.js.object(fields.items));
    try cx.js.@"return"(into, try cx.js.name(self));
    const initialize = try cx.hoistFunction("domProtocolInit", &.{}, into);
    return cx.hoist("domProtocol", try cx.js.call(try cx.js.name(initialize), &.{}));
}
// ownership pin end: domProtocol
