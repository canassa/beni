//! Validate the compiler's trusted callable row against ordinary solved types.
//! Provenance is nominal: an app module with these spellings is never native.
const std = @import("std");
const Context = @import("Context.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Operations = @import("../native/Operations.zig");
const Var = TypeStore.Var;
fn named(cx: *const Context, v: Var, module: []const u8, name: []const u8) bool {
    const content = cx.store.resolvedContent(v);
    const app = switch (content) {
        .structure => |s| switch (s) {
            .app => |a| a,
            else => return false,
        },
        else => return false,
    };
    const identity = cx.types.named(app.type) orelse return false;
    return identity.package == .core and std.mem.eql(u8, cx.interner.slice(identity.module), module) and std.mem.eql(u8, cx.interner.slice(identity.name), name);
}
fn native(cx: *const Context, v: Var, name: []const u8) bool {
    var buffer: [128]u8 = undefined;
    const module = std.fmt.bufPrint(&buffer, "Browser.Host.{s}", .{name}) catch return false;
    return named(cx, v, module, name);
}
fn unit(cx: *const Context, v: Var) bool {
    return switch (cx.store.resolvedContent(v)) {
        .structure => |s| s == .unit,
        else => false,
    };
}
fn argument(cx: *const Context, v: Var, module: []const u8, name: []const u8, index: usize) ?Var {
    if (!named(cx, v, module, name)) return null;
    const args = Walk.positions(cx.store, v);
    return if (index < args.len) args[index] else null;
}
pub fn valid(cx: *const Context, row: Operations.Row, v: Var) bool {
    const f = Walk.function(cx.store, v) orelse return false;
    const a = f.params;
    const r = f.result;
    return switch (row.recipe) {
        .cf_socketInitialize => a.len == 4 and named(cx, a[0], "Browser.Host.Cloudflare", "Socket") and named(cx, a[1], "String", "String") and named(cx, a[2], "String", "String") and (if (argument(cx, a[3], "List", "List", 0)) |item| named(cx, item, "String", "String") else false) and unit(cx, r),
        .cf_unitResolvers => a.len == 1 and unit(cx, a[0]) and (if (argument(cx, r, "Browser.Host.Promise", "Resolvers", 0)) |item| unit(cx, item) else false),
        .cf_stringResolvers => a.len == 1 and unit(cx, a[0]) and (if (argument(cx, r, "Browser.Host.Promise", "Resolvers", 0)) |item| named(cx, item, "String", "String") else false),
        .cf_dataResolvers => a.len == 1 and unit(cx, a[0]) and (if (argument(cx, r, "Browser.Host.Promise", "Resolvers", 0)) |item| named(cx, item, "Js", "Value") else false),
        .cf_responseResolvers => a.len == 1 and unit(cx, a[0]) and (if (argument(cx, r, "Browser.Host.Promise", "Resolvers", 0)) |item| native(cx, item, "Response") else false),
        .cf_program => a.len == 2 and (if (Walk.function(cx.store, a[0])) |callback| callback.params.len == 3 and named(cx, callback.params[0], "Browser.Host.Request", "Request") and named(cx, callback.params[1], "Browser.Host.Cloudflare", "Env") and named(cx, callback.params[2], "Browser.Host.Cloudflare", "ExecutionContext") and (if (argument(cx, callback.result, "Browser.Host.Promise", "Promise", 0)) |item| named(cx, item, "Browser.Host.Response", "Response") else false) else false) and (if (argument(cx, a[1], "List", "List", 0)) |item| named(cx, item, "Browser.Host.Cloudflare", "Definition") else false) and named(cx, r, "Browser.Host.Cloudflare", "Program"),
        .cf_definition => a.len == 2 and named(cx, a[0], "String", "String") and (if (Walk.function(cx.store, a[1])) |callback| callback.params.len == 2 and named(cx, callback.params[0], "Browser.Host.Cloudflare", "ObjectState") and named(cx, callback.params[1], "Browser.Host.Cloudflare", "Env") and named(cx, callback.result, "Browser.Host.Cloudflare", "Instance") else false) and named(cx, r, "Browser.Host.Cloudflare", "Definition"),
        .cf_instance => a.len == 6 and (if (Walk.function(cx.store, a[0])) |callback| callback.params.len == 1 and named(cx, callback.params[0], "Browser.Host.Request", "Request") and (if (argument(cx, callback.result, "Browser.Host.Promise", "Promise", 0)) |item| named(cx, item, "Browser.Host.Response", "Response") else false) else false) and (if (Walk.function(cx.store, a[1])) |callback| callback.params.len == 1 and unit(cx, callback.params[0]) and (if (argument(cx, callback.result, "Browser.Host.Promise", "Promise", 0)) |item| unit(cx, item) else false) else false) and (if (Walk.function(cx.store, a[2])) |callback| callback.params.len == 4 and (if (argument(cx, callback.params[0], "Maybe", "Maybe", 0)) |item| named(cx, item, "String", "String") else false) and named(cx, callback.params[1], "String", "String") and (if (argument(cx, callback.params[2], "Maybe", "Maybe", 0)) |item| named(cx, item, "String", "String") else false) and named(cx, callback.params[3], "String", "String") and (if (argument(cx, callback.result, "Browser.Host.Promise", "Promise", 0)) |item| named(cx, item, "Js", "Value") else false) else false) and (if (Walk.function(cx.store, a[3])) |callback| callback.params.len == 2 and named(cx, callback.params[0], "Browser.Host.Cloudflare", "Socket") and (if (argument(cx, callback.params[1], "Maybe", "Maybe", 0)) |item| named(cx, item, "String", "String") else false) and (if (argument(cx, callback.result, "Browser.Host.Promise", "Promise", 0)) |item| unit(cx, item) else false) else false) and (if (Walk.function(cx.store, a[4])) |callback| callback.params.len == 4 and named(cx, callback.params[0], "Browser.Host.Cloudflare", "Socket") and named(cx, callback.params[1], "Basics", "Int") and named(cx, callback.params[2], "String", "String") and named(cx, callback.params[3], "Basics", "Bool") and (if (argument(cx, callback.result, "Browser.Host.Promise", "Promise", 0)) |item| unit(cx, item) else false) else false) and (if (Walk.function(cx.store, a[5])) |callback| callback.params.len == 2 and named(cx, callback.params[0], "Browser.Host.Cloudflare", "Socket") and named(cx, callback.params[1], "Browser.Host.Rejection", "Rejection") and (if (argument(cx, callback.result, "Browser.Host.Promise", "Promise", 0)) |item| unit(cx, item) else false) else false) and named(cx, r, "Browser.Host.Cloudflare", "Instance"),
        .cf_namespace => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Env") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |item| named(cx, item, "Browser.Host.Cloudflare", "Namespace") else false),
        .cf_service => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Env") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |item| named(cx, item, "Browser.Host.Cloudflare", "Service") else false),
        .cf_variable => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Env") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |item| named(cx, item, "String", "String") else false),
        .cf_byName => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Namespace") and named(cx, a[1], "String", "String") and named(cx, r, "Browser.Host.Cloudflare", "Stub"),
        .cf_uniqueId => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "Namespace") and named(cx, r, "Browser.Host.Cloudflare", "Id"),
        .cf_idFromString => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Namespace") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |item| named(cx, item, "Browser.Host.Cloudflare", "Id") else false),
        .cf_getStub => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Namespace") and named(cx, a[1], "Browser.Host.Cloudflare", "Id") and named(cx, r, "Browser.Host.Cloudflare", "Stub"),
        .cf_stubId => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "Stub") and named(cx, r, "Browser.Host.Cloudflare", "Id"),
        .cf_idText => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "Id") and named(cx, r, "String", "String"),
        .cf_idName => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "Id") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |item| named(cx, item, "String", "String") else false),
        .cf_requestMethod => a.len == 1 and named(cx, a[0], "Browser.Host.Request", "Request") and named(cx, r, "String", "String"),
        .cf_requestUrl => a.len == 1 and named(cx, a[0], "Browser.Host.Request", "Request") and named(cx, r, "String", "String"),
        .cf_requestPath => a.len == 1 and named(cx, a[0], "Browser.Host.Request", "Request") and named(cx, r, "String", "String"),
        .cf_requestHeaders => a.len == 1 and named(cx, a[0], "Browser.Host.Request", "Request") and named(cx, r, "Browser.Host.Headers", "Headers"),
        .cf_requestText => a.len == 1 and named(cx, a[0], "Browser.Host.Request", "Request") and (if (argument(cx, r, "Browser.Host.Promise", "Promise", 0)) |item| named(cx, item, "String", "String") else false),
        .cf_requestCopy => a.len == 2 and named(cx, a[0], "Browser.Host.Request", "Request") and named(cx, a[1], "Browser.Host.Headers", "Headers") and named(cx, r, "Browser.Host.Request", "Request"),
        .cf_requestSignal => a.len == 1 and named(cx, a[0], "Browser.Host.Request", "Request") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |item| named(cx, item, "Browser.Host.AbortSignal", "AbortSignal") else false),
        .cf_onAbort => a.len == 2 and named(cx, a[0], "Browser.Host.AbortSignal", "AbortSignal") and (if (Walk.function(cx.store, a[1])) |callback| callback.params.len == 1 and unit(cx, callback.params[0]) and unit(cx, callback.result) else false) and unit(cx, r),
        .cf_responseCreate => a.len == 3 and named(cx, a[0], "Basics", "Int") and (if (argument(cx, a[1], "Maybe", "Maybe", 0)) |item| named(cx, item, "String", "String") else false) and (if (argument(cx, a[2], "List", "List", 0)) |pair| switch (cx.store.resolvedContent(pair)) {
            .structure => |shape| shape == .tuple and Walk.positions(cx.store, pair).len == 2 and named(cx, Walk.positions(cx.store, pair)[0], "String", "String") and named(cx, Walk.positions(cx.store, pair)[1], "String", "String"),
            else => false,
        } else false) and named(cx, r, "Browser.Host.Response", "Response"),
        .cf_responseCopy => a.len == 1 and named(cx, a[0], "Browser.Host.Response", "Response") and named(cx, r, "Browser.Host.Response", "Response"),
        .cf_stubFetch => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Stub") and named(cx, a[1], "Browser.Host.Request", "Request") and (if (argument(cx, r, "Browser.Host.Promise", "Promise", 0)) |item| named(cx, item, "Browser.Host.Response", "Response") else false),
        .cf_serviceFetch => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Service") and named(cx, a[1], "Browser.Host.Request", "Request") and (if (argument(cx, r, "Browser.Host.Promise", "Promise", 0)) |item| named(cx, item, "Browser.Host.Response", "Response") else false),
        .cf_stubRpc => a.len == 5 and named(cx, a[0], "Browser.Host.Cloudflare", "Stub") and named(cx, a[1], "String", "String") and named(cx, a[2], "String", "String") and (if (argument(cx, a[3], "Maybe", "Maybe", 0)) |item| named(cx, item, "String", "String") else false) and named(cx, a[4], "String", "String") and (if (argument(cx, r, "Browser.Host.Promise", "Promise", 0)) |item| named(cx, item, "Js", "Value") else false),
        .cf_overloaded => a.len == 1 and named(cx, a[0], "Browser.Host.Rejection", "Rejection") and named(cx, r, "Basics", "Bool"),
        .cf_reset => a.len == 1 and named(cx, a[0], "Browser.Host.Rejection", "Rejection") and named(cx, r, "Basics", "Bool"),
        .cf_retryable => a.len == 1 and named(cx, a[0], "Browser.Host.Rejection", "Rejection") and named(cx, r, "Basics", "Bool"),
        .cf_errorText => a.len == 1 and named(cx, a[0], "Browser.Host.Rejection", "Rejection") and named(cx, r, "String", "String"),
        .cf_randomUUID => a.len == 1 and unit(cx, a[0]) and named(cx, r, "String", "String"),
        .cf_waitUntil => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "ExecutionContext") and named(cx, a[1], "Browser.Host.Promise", "Promise") and unit(cx, r),
        .cf_objectWaitUntil => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "ObjectState") and named(cx, a[1], "Browser.Host.Promise", "Promise") and unit(cx, r),
        .cf_objectId => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "ObjectState") and named(cx, r, "Browser.Host.Cloudflare", "Id"),
        .cf_objectAbort => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "ObjectState") and named(cx, a[1], "String", "String") and unit(cx, r),
        .cf_alarmSet => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "ObjectState") and named(cx, a[1], "Basics", "Int") and unit(cx, r),
        .cf_alarmDelete => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "ObjectState") and unit(cx, r),
        .cf_sockets => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "ObjectState") and (if (argument(cx, r, "List", "List", 0)) |item| named(cx, item, "Browser.Host.Cloudflare", "Socket") else false),
        .cf_socketsTagged => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "ObjectState") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "List", "List", 0)) |item| named(cx, item, "Browser.Host.Cloudflare", "Socket") else false),
        .cf_acceptSocket => a.len == 3 and named(cx, a[0], "Browser.Host.Cloudflare", "ObjectState") and named(cx, a[1], "Browser.Host.Cloudflare", "Socket") and (if (argument(cx, a[2], "List", "List", 0)) |item| named(cx, item, "String", "String") else false) and unit(cx, r),
        .cf_autoResponse => a.len == 3 and named(cx, a[0], "Browser.Host.Cloudflare", "ObjectState") and named(cx, a[1], "String", "String") and named(cx, a[2], "String", "String") and unit(cx, r),
        .cf_socketPair => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Browser.Host.Cloudflare", "SocketPair"),
        .cf_socketClient => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "SocketPair") and named(cx, r, "Browser.Host.Cloudflare", "Socket"),
        .cf_socketServer => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "SocketPair") and named(cx, r, "Browser.Host.Cloudflare", "Socket"),
        .cf_socketResponse => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Socket") and named(cx, a[1], "String", "String") and named(cx, r, "Browser.Host.Response", "Response"),
        .cf_socketCloseEmpty => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "Socket") and unit(cx, r),
        .cf_consoleError => a.len == 1 and named(cx, a[0], "String", "String") and unit(cx, r),
        .cf_consoleLog => a.len == 1 and named(cx, a[0], "String", "String") and unit(cx, r),
        .cf_consoleReason => a.len == 2 and named(cx, a[0], "String", "String") and named(cx, a[1], "Browser.Host.Rejection", "Rejection") and unit(cx, r),
        .promise_of => blk: {
            if (a.len != 1) break :blk false;
            const input = argument(cx, a[0], "Browser.Host.Promise", "Resolvers", 0) orelse break :blk false;
            const output = argument(cx, r, "Browser.Host.Promise", "Promise", 0) orelse break :blk false;
            break :blk cx.store.find(input) == cx.store.find(output);
        },
        .promise_resolve => blk: {
            if (a.len != 2 or !unit(cx, r)) break :blk false;
            const item = argument(cx, a[0], "Browser.Host.Promise", "Resolvers", 0) orelse break :blk false;
            break :blk cx.store.find(item) == cx.store.find(a[1]);
        },
        .promise_reject => a.len == 2 and named(cx, a[0], "Browser.Host.Promise", "Resolvers") and native(cx, a[1], "Rejection") and unit(cx, r),
        .promise_after => blk: {
            if (a.len != 2) break :blk false;
            const input = argument(cx, a[0], "Browser.Host.Promise", "Promise", 0) orelse break :blk false;
            const output = argument(cx, r, "Browser.Host.Promise", "Promise", 0) orelse break :blk false;
            const done = Walk.function(cx.store, a[1]) orelse break :blk false;
            break :blk done.params.len == 1 and cx.store.find(done.params[0]) == cx.store.find(input) and unit(cx, done.result) and unit(cx, output);
        },
        .cf_socketEq => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Socket") and named(cx, a[1], "Browser.Host.Cloudflare", "Socket") and named(cx, r, "Basics", "Bool"),
        .cf_socketState => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "Socket") and named(cx, r, "Basics", "Int"),
        .cf_socketSend => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Socket") and named(cx, a[1], "String", "String") and unit(cx, r),
        .cf_socketClose => a.len == 3 and named(cx, a[0], "Browser.Host.Cloudflare", "Socket") and named(cx, a[1], "Basics", "Int") and named(cx, a[2], "String", "String") and unit(cx, r),
        .cf_socketAttachment => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "Socket") and named(cx, r, "Js", "Value"),
        .cf_socketAttach => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "Socket") and named(cx, a[1], "Js", "Value") and unit(cx, r),
        .cf_kv => a.len == 1 and named(cx, a[0], "Browser.Host.Cloudflare", "ObjectState") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |item| named(cx, item, "Browser.Host.Cloudflare", "KV") else false),
        .cf_kvGet => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "KV") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |item| named(cx, item, "String", "String") else false),
        .cf_kvPut => a.len == 3 and named(cx, a[0], "Browser.Host.Cloudflare", "KV") and named(cx, a[1], "String", "String") and named(cx, a[2], "String", "String") and named(cx, r, "Basics", "Bool"),
        .cf_kvDelete => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "KV") and named(cx, a[1], "String", "String") and named(cx, r, "Basics", "Bool"),
        .cf_kvKeys => a.len == 2 and named(cx, a[0], "Browser.Host.Cloudflare", "KV") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "List", "List", 0)) |item| named(cx, item, "String", "String") else false),
        .worker_supported => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Basics", "Bool"),
        .worker_create => a.len == 3 and named(cx, a[0], "String", "String") and named(cx, a[1], "String", "String") and named(cx, a[2], "String", "String") and (if (argument(cx, r, "Result", "Result", 0)) |failure| named(cx, failure, "Browser.Host.Worker", "CreateError") else false) and (if (argument(cx, r, "Result", "Result", 1)) |worker| native(cx, worker, "Worker") else false),
        .worker_endpoint => a.len == 1 and native(cx, a[0], "Worker") and named(cx, r, "Browser.Host.Worker", "Endpoint"),
        .worker_self_endpoint => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Browser.Host.Worker", "Endpoint"),
        .worker_post => a.len == 2 and named(cx, a[0], "Browser.Host.Worker", "Endpoint") and named(cx, a[1], "Js", "Value") and (if (argument(cx, r, "Result", "Result", 0)) |failure| named(cx, failure, "Browser.Host.Worker", "PostError") else false) and (if (argument(cx, r, "Result", "Result", 1)) |success| unit(cx, success) else false),
        .worker_terminate => a.len == 1 and native(cx, a[0], "Worker") and unit(cx, r),
        .worker_event_target => a.len == 1 and named(cx, a[0], "Browser.Host.Worker", "Endpoint") and native(cx, r, "EventTarget"),
        .global_event_target => a.len == 1 and unit(cx, a[0]) and native(cx, r, "EventTarget"),
        .event_data_only => a.len == 1 and native(cx, a[0], "Event") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |data| named(cx, data, "Js", "Value") else false),
        .event_error => a.len == 1 and native(cx, a[0], "Event") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |reason| native(cx, reason, "Rejection") else false),
        .console_error_data => a.len == 2 and named(cx, a[0], "String", "String") and named(cx, a[1], "Js", "Value") and unit(cx, r),
        .rejection_abandoned => a.len == 2 and native(cx, a[0], "Rejection") and named(cx, a[1], "Js", "Value") and unit(cx, r),
        .data_same => a.len == 2 and named(cx, a[0], "Js", "Value") and named(cx, a[1], "Js", "Value") and named(cx, r, "Basics", "Bool"),
        .document_by_id => a.len == 1 and named(cx, a[0], "String", "String") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |nested0| native(cx, nested0, "Element") else false),
        .element_focus => a.len == 1 and native(cx, a[0], "Element") and unit(cx, r),
        .element_blur => a.len == 1 and native(cx, a[0], "Element") and unit(cx, r),
        .element_box => a.len == 1 and native(cx, a[0], "Element") and native(cx, r, "DOMRect"),
        .element_scroll => a.len == 3 and native(cx, a[0], "Element") and named(cx, a[1], "Basics", "Float") and named(cx, a[2], "Basics", "Float") and unit(cx, r),
        .element_into_view => a.len == 1 and native(cx, a[0], "Element") and unit(cx, r),
        .rect_x => a.len == 1 and native(cx, a[0], "DOMRect") and named(cx, r, "Basics", "Float"),
        .rect_y => a.len == 1 and native(cx, a[0], "DOMRect") and named(cx, r, "Basics", "Float"),
        .rect_width => a.len == 1 and native(cx, a[0], "DOMRect") and named(cx, r, "Basics", "Float"),
        .rect_height => a.len == 1 and native(cx, a[0], "DOMRect") and named(cx, r, "Basics", "Float"),
        .window_scroll_x => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Basics", "Float"),
        .window_scroll_y => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Basics", "Float"),
        .element_fullscreen_supported => a.len == 1 and native(cx, a[0], "Element") and named(cx, r, "Basics", "Bool"),
        .element_fullscreen => a.len == 1 and native(cx, a[0], "Element") and (if (argument(cx, r, "Browser.Host.Promise", "Promise", 0)) |nested0| unit(cx, nested0) else false),
        .document_fullscreen_enabled => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Basics", "Bool"),
        .document_fullscreen_id => a.len == 1 and unit(cx, a[0]) and (if (argument(cx, r, "Maybe", "Maybe", 0)) |nested0| named(cx, nested0, "String", "String") else false),
        .document_fullscreen_exit => a.len == 1 and unit(cx, a[0]) and (if (argument(cx, r, "Browser.Host.Promise", "Promise", 0)) |nested0| unit(cx, nested0) else false),
        .navigator_activated => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Basics", "Bool"),
        .rejection_type_error_message => a.len == 1 and native(cx, a[0], "Rejection") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |nested0| named(cx, nested0, "String", "String") else false),
        .url_protocol => a.len == 1 and native(cx, a[0], "URL") and named(cx, r, "String", "String"),
        .url_set_protocol => a.len == 2 and native(cx, a[0], "URL") and named(cx, a[1], "String", "String") and unit(cx, r),
        .ws_create => a.len == 2 and named(cx, a[0], "String", "String") and (if (argument(cx, a[1], "List", "List", 0)) |item| named(cx, item, "String", "String") else false) and (if (argument(cx, r, "Maybe", "Maybe", 0)) |socket| native(cx, socket, "WebSocket") else false),
        .ws_binary, .ws_close_empty => a.len == 1 and native(cx, a[0], "WebSocket") and unit(cx, r),
        .ws_state, .ws_buffered => a.len == 1 and native(cx, a[0], "WebSocket") and named(cx, r, "Basics", "Int"),
        .ws_protocol => a.len == 1 and native(cx, a[0], "WebSocket") and named(cx, r, "String", "String"),
        .ws_send => a.len == 2 and native(cx, a[0], "WebSocket") and named(cx, a[1], "String", "String") and unit(cx, r),
        .ws_close => a.len == 3 and native(cx, a[0], "WebSocket") and named(cx, a[1], "Basics", "Int") and named(cx, a[2], "String", "String") and unit(cx, r),
        .ws_open, .ws_error => a.len == 2 and native(cx, a[0], "WebSocket") and unitCallback(cx, a[1]) and unit(cx, r),
        .ws_message => a.len == 2 and native(cx, a[0], "WebSocket") and (if (Walk.function(cx.store, a[1])) |callback| callback.params.len == 1 and unit(cx, callback.result) and (if (argument(cx, callback.params[0], "Maybe", "Maybe", 0)) |text| named(cx, text, "String", "String") else false) else false) and unit(cx, r),
        .ws_closed => a.len == 2 and native(cx, a[0], "WebSocket") and (if (Walk.function(cx.store, a[1])) |callback| callback.params.len == 2 and named(cx, callback.params[0], "Basics", "Int") and named(cx, callback.params[1], "String", "String") and unit(cx, callback.result) else false) and unit(cx, r),
        .console_warn => a.len == 1 and named(cx, a[0], "String", "String") and unit(cx, r),
        .storage_local, .storage_session => a.len == 1 and unit(cx, a[0]) and (if (argument(cx, r, "Maybe", "Maybe", 0)) |area| native(cx, area, "Storage") else false),
        .storage_get => a.len == 2 and native(cx, a[0], "Storage") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |value| named(cx, value, "String", "String") else false),
        .storage_set => blk: {
            if (a.len != 3 or !native(cx, a[0], "Storage") or !named(cx, a[1], "String", "String") or !named(cx, a[2], "String", "String")) break :blk false;
            const failure = argument(cx, r, "Result", "Result", 0) orelse break :blk false;
            const success = argument(cx, r, "Result", "Result", 1) orelse break :blk false;
            break :blk named(cx, failure, "Browser.Host.Storage", "SetError") and unit(cx, success);
        },
        .storage_remove => a.len == 2 and native(cx, a[0], "Storage") and named(cx, a[1], "String", "String") and unit(cx, r),
        .storage_length => a.len == 1 and native(cx, a[0], "Storage") and named(cx, r, "Basics", "Int"),
        .storage_key => a.len == 2 and native(cx, a[0], "Storage") and named(cx, a[1], "Basics", "Int") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |key| named(cx, key, "String", "String") else false),
        .url_try_create => a.len == 2 and named(cx, a[0], "String", "String") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |nested0| native(cx, nested0, "URL") else false),
        .url_href => a.len == 1 and native(cx, a[0], "URL") and named(cx, r, "String", "String"),
        .url_username => a.len == 1 and native(cx, a[0], "URL") and named(cx, r, "String", "String"),
        .url_password => a.len == 1 and native(cx, a[0], "URL") and named(cx, r, "String", "String"),
        .document_base_uri => a.len == 1 and unit(cx, a[0]) and named(cx, r, "String", "String"),
        .headers_create => a.len == 1 and unit(cx, a[0]) and native(cx, r, "Headers"),
        .headers_append => a.len == 3 and native(cx, a[0], "Headers") and named(cx, a[1], "String", "String") and named(cx, a[2], "String", "String") and unit(cx, r),
        .headers_has => a.len == 2 and native(cx, a[0], "Headers") and named(cx, a[1], "String", "String") and named(cx, r, "Basics", "Bool"),
        .headers_set => a.len == 3 and native(cx, a[0], "Headers") and named(cx, a[1], "String", "String") and named(cx, a[2], "String", "String") and unit(cx, r),
        .headers_get => a.len == 2 and native(cx, a[0], "Headers") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |nested0| named(cx, nested0, "String", "String") else false),
        .headers_entries => a.len == 1 and native(cx, a[0], "Headers") and stringPairs(cx, r),
        .form_create => a.len == 1 and unit(cx, a[0]) and native(cx, r, "FormData"),
        .form_append => a.len == 3 and native(cx, a[0], "FormData") and named(cx, a[1], "String", "String") and named(cx, a[2], "String", "String") and unit(cx, r),
        .fetch_text_body => a.len == 1 and named(cx, a[0], "String", "String") and named(cx, r, "Browser.Host.Fetch", "Body"),
        .fetch_form_body => a.len == 1 and native(cx, a[0], "FormData") and named(cx, r, "Browser.Host.Fetch", "Body"),
        .fetch_init => a.len == 5 and named(cx, a[0], "String", "String") and native(cx, a[1], "Headers") and (if (argument(cx, a[2], "Maybe", "Maybe", 0)) |nested0| named(cx, nested0, "Browser.Host.Fetch", "Body") else false) and native(cx, a[3], "AbortSignal") and named(cx, a[4], "String", "String") and named(cx, r, "Browser.Host.Fetch", "Init"),
        .fetch_call => a.len == 2 and named(cx, a[0], "String", "String") and named(cx, a[1], "Browser.Host.Fetch", "Init") and (if (argument(cx, r, "Browser.Host.Promise", "Promise", 0)) |nested0| native(cx, nested0, "Response") else false),
        .response_url => a.len == 1 and native(cx, a[0], "Response") and named(cx, r, "String", "String"),
        .response_status => a.len == 1 and native(cx, a[0], "Response") and named(cx, r, "Basics", "Int"),
        .response_status_text => a.len == 1 and native(cx, a[0], "Response") and named(cx, r, "String", "String"),
        .response_ok => a.len == 1 and native(cx, a[0], "Response") and named(cx, r, "Basics", "Bool"),
        .response_headers => a.len == 1 and native(cx, a[0], "Response") and native(cx, r, "Headers"),
        .response_text => a.len == 1 and native(cx, a[0], "Response") and (if (argument(cx, r, "Browser.Host.Promise", "Promise", 0)) |nested0| named(cx, nested0, "String", "String") else false),
        .response_reader => a.len == 1 and native(cx, a[0], "Response") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |nested0| native(cx, nested0, "ReadableStreamDefaultReader") else false),
        .reader_bytes => a.len == 1 and native(cx, a[0], "ReadableStreamDefaultReader") and (if (argument(cx, r, "Browser.Host.Promise", "Promise", 0)) |nested0| native(cx, nested0, "ReadResult") else false),
        .read_result_done => a.len == 1 and native(cx, a[0], "ReadResult") and named(cx, r, "Basics", "Bool"),
        .read_result_value => a.len == 1 and native(cx, a[0], "ReadResult") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |nested0| native(cx, nested0, "Uint8Array") else false),
        .decoder_create => a.len == 1 and unit(cx, a[0]) and native(cx, r, "TextDecoder"),
        .decoder_more => a.len == 2 and native(cx, a[0], "TextDecoder") and native(cx, a[1], "Uint8Array") and named(cx, r, "String", "String"),
        .decoder_finish => a.len == 1 and native(cx, a[0], "TextDecoder") and named(cx, r, "String", "String"),
        .dom_exception_create => a.len == 2 and named(cx, a[0], "String", "String") and named(cx, a[1], "String", "String") and native(cx, r, "DOMException"),
        .abort_with_reason => a.len == 2 and native(cx, a[0], "AbortController") and native(cx, a[1], "DOMException") and unit(cx, r),
        .abort_reason_is => a.len == 2 and native(cx, a[0], "AbortSignal") and native(cx, a[1], "DOMException") and named(cx, r, "Basics", "Bool"),
        .rejection_is_type_error => a.len == 1 and native(cx, a[0], "Rejection") and named(cx, r, "Basics", "Bool"),
        .regexp_create => a.len == 2 and named(cx, a[0], "String", "String") and named(cx, a[1], "String", "String") and (if (argument(cx, r, "Result", "Result", 0)) |failure| named(cx, failure, "Browser.Host.RegExp", "CreateError") else false) and (if (argument(cx, r, "Result", "Result", 1)) |success| native(cx, success, "RegExp") else false),
        .regexp_test => a.len == 2 and native(cx, a[0], "RegExp") and named(cx, a[1], "String", "String") and named(cx, r, "Basics", "Bool"),
        .regexp_replace => a.len == 3 and native(cx, a[0], "RegExp") and named(cx, a[1], "String", "String") and named(cx, a[2], "String", "String") and named(cx, r, "String", "String"),
        .data_is_array, .data_is_finite, .data_is_integer, .data_is_safe_integer => a.len == 1 and named(cx, a[0], "Js", "Value") and named(cx, r, "Basics", "Bool"),
        .data_keys => a.len == 1 and named(cx, a[0], "Js", "Value") and (if (argument(cx, r, "List", "List", 0)) |element| named(cx, element, "String", "String") else false),
        .data_empty_object => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Js", "Value"),
        .data_has_own => a.len == 2 and named(cx, a[0], "Js", "Value") and named(cx, a[1], "String", "String") and named(cx, r, "Basics", "Bool"),
        .json_parse => blk: {
            if (a.len != 1 or !named(cx, a[0], "String", "String")) break :blk false;
            const failure = argument(cx, r, "Result", "Result", 0) orelse break :blk false;
            const success = argument(cx, r, "Result", "Result", 1) orelse break :blk false;
            break :blk named(cx, failure, "Browser.Host.Json", "ParseError") and named(cx, success, "Js", "Value");
        },
        .json_stringify => a.len == 1 and named(cx, a[0], "Js", "Value") and named(cx, r, "Js", "Value"),
        .promise_observe => blk: {
            if (a.len != 3 or !unit(cx, r)) break :blk false;
            const item = argument(cx, a[0], "Browser.Host.Promise", "Promise", 0) orelse break :blk false;
            const done = Walk.function(cx.store, a[1]) orelse break :blk false;
            const failed = Walk.function(cx.store, a[2]) orelse break :blk false;
            break :blk done.params.len == 1 and cx.store.find(done.params[0]) == cx.store.find(item) and unit(cx, done.result) and failed.params.len == 1 and native(cx, failed.params[0], "Rejection") and unit(cx, failed.result);
        },
        .rejection_is_error => a.len == 1 and native(cx, a[0], "Rejection") and named(cx, r, "Basics", "Bool"),
        .rejection_name => a.len == 1 and native(cx, a[0], "Rejection") and named(cx, r, "String", "String"),
        .rejection_code => a.len == 1 and native(cx, a[0], "Rejection") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |text| named(cx, text, "String", "String") else false),
        .rejection_raise => a.len == 1 and native(cx, a[0], "Rejection") and switch (cx.store.resolvedContent(r)) {
            .flex, .rigid => true,
            else => false,
        },
        .abort_create => a.len == 1 and unit(cx, a[0]) and native(cx, r, "AbortController"),
        .abort_signal => a.len == 1 and native(cx, a[0], "AbortController") and native(cx, r, "AbortSignal"),
        .abort_call => a.len == 1 and native(cx, a[0], "AbortController") and unit(cx, r),
        .abort_aborted => a.len == 1 and native(cx, a[0], "AbortSignal") and named(cx, r, "Basics", "Bool"),
        .node_read_utf8 => a.len == 2 and named(cx, a[0], "String", "String") and native(cx, a[1], "AbortSignal") and (if (argument(cx, r, "Browser.Host.Promise", "Promise", 0)) |item| named(cx, item, "String", "String") else false),
        .node_read_dir => blk: {
            if (a.len != 1 or !named(cx, a[0], "String", "String")) break :blk false;
            const list = argument(cx, r, "Browser.Host.Promise", "Promise", 0) orelse break :blk false;
            const item = argument(cx, list, "List", "List", 0) orelse break :blk false;
            break :blk native(cx, item, "NodeDirent");
        },
        .dirent_name => a.len == 1 and native(cx, a[0], "NodeDirent") and named(cx, r, "String", "String"),
        .dirent_file, .dirent_directory, .dirent_link => a.len == 1 and native(cx, a[0], "NodeDirent") and named(cx, r, "Basics", "Bool"),
        .process_stdout, .process_stderr => a.len == 1 and named(cx, a[0], "String", "String") and unit(cx, r),
        .process_exit_code => a.len == 1 and named(cx, a[0], "Basics", "Int") and unit(cx, r),
        .process_before_exit => a.len == 1 and unitCallback(cx, a[0]) and unit(cx, r),
        .event_listen => a.len == 3 and native(cx, a[0], "EventTarget") and named(cx, a[1], "String", "String") and eventCallback(cx, a[2]) and unitCallback(cx, r),
        .frame_request => a.len == 1 and unitCallback(cx, a[0]) and named(cx, r, "Browser.Host.Window", "Frame"),
        .frame_cancel => a.len == 1 and named(cx, a[0], "Browser.Host.Window", "Frame") and unit(cx, r),
        .inner_width, .inner_height => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Basics", "Int"),
        .visibility_state, .document_title_read => a.len == 1 and unit(cx, a[0]) and named(cx, r, "String", "String"),
        .document_title => a.len == 1 and named(cx, a[0], "String", "String") and unit(cx, r),
        .event_prevented => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Bool"),
        .event_button => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Int"),
        .event_path => a.len == 1 and native(cx, a[0], "Event") and (if (argument(cx, r, "List", "List", 0)) |element| native(cx, element, "EventTarget") else false),
        .as_anchor => a.len == 1 and native(cx, a[0], "EventTarget") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |element| native(cx, element, "HTMLAnchorElement") else false),
        .anchor_has => a.len == 2 and native(cx, a[0], "HTMLAnchorElement") and named(cx, a[1], "String", "String") and named(cx, r, "Basics", "Bool"),
        .anchor_href, .anchor_protocol, .anchor_host, .anchor_target => a.len == 1 and native(cx, a[0], "HTMLAnchorElement") and named(cx, r, "String", "String"),
        .event_box => a.len == 1 and native(cx, a[0], "Event") and native(cx, r, "DOMRect"),
        .rect_left, .rect_top => a.len == 1 and native(cx, a[0], "DOMRect") and named(cx, r, "Basics", "Float"),
        .event_target_value => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "String", "String"),
        .event_target_checked => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Bool"),
        .listen_window, .listen_document => a.len == 2 and named(cx, a[0], "String", "String") and eventCallback(cx, a[1]) and unitCallback(cx, r),
        .event_prevent => a.len == 1 and native(cx, a[0], "Event") and unit(cx, r),
        .event_key => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "String", "String"),
        .event_code => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "String", "String"),
        .event_ctrlKey => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Bool"),
        .event_shiftKey => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Bool"),
        .event_altKey => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Bool"),
        .event_metaKey => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Bool"),
        .event_pointerId => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Int"),
        .event_pointerType => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "String", "String"),
        .event_isPrimary => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Bool"),
        .event_clientX => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Float"),
        .event_clientY => a.len == 1 and native(cx, a[0], "Event") and named(cx, r, "Basics", "Float"),
        .queue_microtask => a.len == 1 and unitCallback(cx, a[0]) and unit(cx, r),
        .timer_start => a.len == 2 and unitCallback(cx, a[0]) and named(cx, a[1], "Basics", "Int") and named(cx, r, "Browser.Host.Timers", "Timer"),
        .timer_clear => a.len == 1 and named(cx, a[0], "Browser.Host.Timers", "Timer") and unit(cx, r),
        .message_channel => a.len == 1 and unit(cx, a[0]) and native(cx, r, "MessageChannel"),
        .message_port1, .message_port2 => a.len == 1 and native(cx, a[0], "MessageChannel") and native(cx, r, "MessagePort"),
        .post_unit => a.len == 1 and native(cx, a[0], "MessagePort") and unit(cx, r),
        .on_message => a.len == 2 and native(cx, a[0], "MessagePort") and unitCallback(cx, a[1]) and unit(cx, r),
        .try_immediate => a.len == 1 and unitCallback(cx, a[0]) and named(cx, r, "Basics", "Bool"),
        .date_now => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Basics", "Int"),
        .math_random => a.len == 1 and unit(cx, a[0]) and named(cx, r, "Basics", "Float"),

        .document => a.len == 1 and unit(cx, a[0]) and native(cx, r, "Document"),
        .query_selector => blk: {
            if (a.len != 2 or !native(cx, a[0], "Document") or !named(cx, a[1], "String", "String")) break :blk false;
            const error_type = argument(cx, r, "Result", "Result", 0) orelse break :blk false;
            const result = argument(cx, r, "Result", "Result", 1) orelse break :blk false;
            const element = argument(cx, result, "Maybe", "Maybe", 0) orelse break :blk false;
            break :blk named(cx, error_type, "Browser.Host.Document", "QueryError") and native(cx, element, "Element");
        },
        .text_content => a.len == 1 and native(cx, a[0], "Node") and (if (argument(cx, r, "Maybe", "Maybe", 0)) |text| named(cx, text, "String", "String") else false),
        .set_text_content => a.len == 2 and native(cx, a[0], "Node") and named(cx, a[1], "String", "String") and unit(cx, r),
        .identity => a.len == 1 and native(cx, a[0], "Element") and native(cx, r, "Node"),
        .text_encoder => a.len == 1 and unit(cx, a[0]) and native(cx, r, "TextEncoder"),
        .encode => a.len == 2 and native(cx, a[0], "TextEncoder") and named(cx, a[1], "String", "String") and native(cx, r, "Uint8Array"),
        .byte_length => a.len == 1 and native(cx, a[0], "Uint8Array") and named(cx, r, "Basics", "Int"),
        .timeout => a.len == 2 and named(cx, a[1], "Basics", "Int") and named(cx, r, "Basics", "Int") and (if (Walk.function(cx.store, a[0])) |callback| callback.params.len == 1 and unit(cx, callback.params[0]) and unit(cx, callback.result) else false),
        .worker_self => a.len == 1 and unit(cx, a[0]) and native(cx, r, "WorkerGlobalScope"),
    };
}
fn unitCallback(cx: *const Context, v: Var) bool {
    const callback = Walk.function(cx.store, v) orelse return false;
    return callback.params.len == 1 and unit(cx, callback.params[0]) and unit(cx, callback.result);
}

fn eventCallback(cx: *const Context, v: Var) bool {
    const callback = Walk.function(cx.store, v) orelse return false;
    return callback.params.len == 1 and native(cx, callback.params[0], "Event") and unit(cx, callback.result);
}

fn stringPairs(cx: *const Context, v: Var) bool {
    const pair = argument(cx, v, "List", "List", 0) orelse return false;
    switch (cx.store.resolvedContent(pair)) {
        .structure => |shape| if (shape != .tuple) return false,
        else => return false,
    }
    const fields = Walk.positions(cx.store, pair);
    return fields.len == 2 and named(cx, fields[0], "String", "String") and named(cx, fields[1], "String", "String");
}
