//! Resolve the reviewed adapters against the catalogue, then generate ordinary
//! typed modules and their exact-error siblings. Unsupported members stay private.
const std = @import("std");
const Operations = @import("Operations.zig");
const CheckedData = @import("CheckedData.zig");
const Allocator = std.mem.Allocator;

pub fn validate(c: anytype) bool {
    for (Operations.rows) |row| {
        if (row.recipe == .byte_length or row.source != .webidl) continue; // Versioned ECMAScript intrinsic.
        var owner: ?u32 = null;
        for (c.declarations, 0..) |d, i| {
            if (!d.partial and d.kind != .includes and std.mem.eql(u8, d.name, row.owner)) owner = @intCast(i);
        }
        const declaration = owner orelse {
            std.debug.print("native owner missing: {s}\n", .{row.owner});
            return false;
        };
        if (row.recipe == .identity or row.recipe == .renderer_from_node) {
            var found = false;
            for (c.upcasts) |edge| {
                if (row.recipe == .renderer_from_node) {
                    if (c.native_types[edge.from].declaration == declaration and std.mem.eql(u8, c.native_types[edge.to].idl_name, "EventTarget")) found = true;
                } else if (c.native_types[edge.from].declaration == declaration and std.mem.eql(u8, c.native_types[edge.to].idl_name, "Node")) found = true;
            }
            if (!found) return false;
            continue;
        }
        var found = false;
        for (c.members) |m| {
            if (!std.mem.eql(u8, c.declarations[m.owner].name, row.owner)) continue;
            const text = m.source_span.text(c.files[m.file].source);
            if (hasMember(text, row.member)) found = true;
        }
        if (!found) {
            std.debug.print("native member missing: {s}.{s}\n", .{ row.owner, row.member });
            return false;
        }
        // Mixin exposure belongs to the implementing native receiver.
        const receiver = if ((row.recipe == .global_event_target or row.recipe == .global_is_page)) "Window" else if (row.recipe == .worker_event_target) "Worker" else if (std.mem.eql(u8, row.owner, "AnimationFrameProvider")) "Window" else if (row.recipe == .as_anchor or std.mem.eql(u8, row.owner, "HTMLHyperlinkElementUtils") or std.mem.eql(u8, row.owner, "HyperlinkElementUtils")) "HTMLAnchorElement" else if (row.recipe == .listen_window or row.recipe == .listen_document) "Window" else if (row.recipe == .storage_local or row.recipe == .storage_session) "Window" else if (row.recipe == .response_text or row.recipe == .response_reader) "Response" else if (std.mem.eql(u8, row.owner, "HTMLOrSVGOrMathMLElement")) "HTMLElement" else if (std.mem.eql(u8, row.owner, "DocumentOrShadowRoot") or std.mem.eql(u8, row.owner, "NonElementParentNode")) "Document" else if (std.mem.eql(u8, row.owner, "ParentNode")) "Document" else if (std.mem.eql(u8, row.owner, "WindowOrWorkerGlobalScope")) "Window" else if (std.mem.eql(u8, row.owner, "MessageEventTarget")) "MessagePort" else row.owner;
        var exposure: u8 = 0;
        for (c.native_types) |t| {
            if (!std.mem.eql(u8, t.idl_name, receiver) and !((row.recipe == .global_event_target or row.recipe == .global_is_page) and std.mem.eql(u8, t.idl_name, "WorkerGlobalScope"))) continue;
            for (t.exposed) |name| {
                if (std.mem.eql(u8, name, "Window")) exposure |= Operations.window;
                if (std.mem.eql(u8, name, "Worker")) exposure |= Operations.workers;
                if (std.mem.eql(u8, name, "DedicatedWorker")) exposure |= 2;
                if (std.mem.eql(u8, name, "SharedWorker")) exposure |= 4;
                if (std.mem.eql(u8, name, "ServiceWorker")) exposure |= 8;
                if (std.mem.eql(u8, name, "*")) exposure |= Operations.all;
            }
        }
        if (std.mem.eql(u8, row.owner, "WindowOrWorkerGlobalScope")) exposure |= Operations.workers;
        if (row.node_extension) exposure |= 16;
        if (exposure != row.allowed) {
            std.debug.print("exposure mismatch {s}.{s}: {d} != {d}\n", .{ row.owner, row.member, exposure, row.allowed });
            return false;
        }
    }
    return true;
}

pub fn source(arena: Allocator, module: []const u8, type_name: ?[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(if (std.mem.eql(u8, module, "Browser.Host.Map")) "-- Generated from ECMA-262, 16th edition (2025), §24.1; reviewed adapters in native/Map.zig.\n" else if (std.mem.eql(u8, module, "Browser.Host.Cloudflare")) "-- Generated from @cloudflare/workers-types 5.20261102.1; reviewed native supplement.\n" else "-- Generated from @webref/idl 3.86.0; reviewed adapters in native/Operations.zig.\n");
    if (std.mem.eql(u8, module, "Browser.Host.Events")) try w.writeAll("import Browser.Host.Event as Event\nimport Browser.Host.EventTarget as EventTarget\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.EventTarget")) try w.writeAll("import Browser.Host.HTMLAnchorElement as HTMLAnchorElement\nimport Browser.Host.Node as Node\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Event")) try w.writeAll("import Browser.Host.EventTarget as EventTarget\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Event")) try w.writeAll("import Browser.Host.DOMRect as DOMRect\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Window") or std.mem.eql(u8, module, "Browser.Host.Document")) try w.writeAll("import Browser.Host.Event as Event\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Window")) try w.writeAll("import Browser.Host.Document as Document\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Document")) try w.writeAll("import Browser.Host.Element as Element\nimport Browser.Host.Node as Node\nimport Browser.Host.Promise as Promise\n\n\npub type QueryError\n    = SyntaxError\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Element")) try w.writeAll("import Browser.Host.Node as Node\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.TextEncoder")) try w.writeAll("import Browser.Host.Uint8Array as Uint8Array\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.MessageChannel")) try w.writeAll("import Browser.Host.MessagePort as MessagePort\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Timers")) try w.writeAll("-- A browser numeric timer id or a Node Timeout handle; never plain data.\npub foreign type Timer\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Window")) try w.writeAll("pub foreign type Frame\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Promise")) try w.writeAll("import Browser.Host.Rejection as Rejection\nimport Js\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.AbortController")) try w.writeAll("import Browser.Host.AbortSignal as AbortSignal\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.NodeFs")) try w.writeAll("import Browser.Host.AbortSignal as AbortSignal\nimport Browser.Host.Promise as Promise\nimport Browser.Host.NodeDirent as NodeDirent\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Data") or std.mem.eql(u8, module, "Browser.Host.Json")) try w.writeAll("import Js\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Json")) try w.writeAll("pub type ParseError\n    = SyntaxError\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.AbortController")) try w.writeAll("import Browser.Host.DOMException as DOMException\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.AbortSignal")) try w.writeAll("import Browser.Host.DOMException as DOMException\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Fetch")) try w.writeAll("import Browser.Host.Headers as Headers\nimport Browser.Host.AbortSignal as AbortSignal\nimport Browser.Host.Response as Response\nimport Browser.Host.Promise as Promise\nimport Browser.Host.FormData as FormData\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.ReadResult")) try w.writeAll("import Browser.Host.Uint8Array as Uint8Array\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.ReadableStreamDefaultReader")) try w.writeAll("import Browser.Host.Promise as Promise\nimport Browser.Host.ReadResult as ReadResult\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Response")) try w.writeAll("import Browser.Host.Headers as Headers\nimport Browser.Host.Promise as Promise\nimport Browser.Host.ReadableStreamDefaultReader as ReadableStreamDefaultReader\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.TextDecoder")) try w.writeAll("import Browser.Host.Uint8Array as Uint8Array\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Fetch")) try w.writeAll("pub foreign type Body\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.RegExp")) try w.writeAll("pub type CreateError\n    = SyntaxError\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Storage")) try w.writeAll("pub type SetError\n    = QuotaExceeded\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Element")) try w.writeAll("import Browser.Host.DOMRect as DOMRect\nimport Browser.Host.Promise as Promise\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Worker")) try w.writeAll("import Js\nimport Browser.Host.EventTarget as EventTarget\n\n\npub foreign type Endpoint\n\n\npub type CreateError\n    = SyntaxError\n    | SecurityError\n    | TypeError\n\n\npub type PostError\n    = DataCloneError\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Event")) try w.writeAll("import Js\nimport Browser.Host.Rejection as Rejection\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Console") or std.mem.eql(u8, module, "Browser.Host.Rejection")) try w.writeAll("import Js\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Cloudflare")) try w.writeAll(@import("Cloudflare.zig").declarations);
    if (std.mem.eql(u8, module, "Browser.Host.Promise")) try w.writeAll("pub foreign type Resolvers a\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Node")) try w.writeAll("import Js\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Node")) try w.writeAll("pub type MoveError\n    = HierarchyRequestError\n\n\n");
    if (type_name) |name| try w.print("pub foreign type {s}\n", .{name});
    for (Operations.rows) |row| {
        if (!std.mem.eql(u8, row.module, module)) continue;
        try w.print("{s}pub foreign {s} {s} :{s}{s}\n", .{ if (type_name == null and !std.mem.eql(u8, module, "Browser.Host.Cloudflare")) "\n" else "\n\n", @tagName(row.effect), row.name, if (std.mem.startsWith(u8, row.signature, "\n")) "" else " ", row.signature });
    }
    return out.toOwnedSlice();
}

pub fn sibling(arena: Allocator, module: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    for (Operations.rows) |row| {
        if (!std.mem.eql(u8, row.module, module)) continue;
        if (Operations.renderer(row.recipe)) continue; // Both call forms are compiler-emitted.
        const body = switch (row.recipe) {
            .renderer_first_child, .renderer_next_sibling, .renderer_parent, .renderer_insert, .renderer_append, .renderer_remove, .renderer_clone, .renderer_fragment, .renderer_import, .renderer_template, .renderer_body, .renderer_text, .renderer_from_node => unreachable,
            .worker_close_self => "(ignored) => { globalThis.close(); return null; }",
            .global_is_page => "(ignored) => { return typeof globalThis.window !== \"undefined\"; }",
            .event_error_message => "(event) => { return typeof globalThis.ErrorEvent === \"function\" && event instanceof globalThis.ErrorEvent ? { $: \"Just\", a: event.message } : { $: \"Nothing\", a: null }; }",
            .rejection_create => "(message) => { return new globalThis.Error(message); }",
            .rejection_assign => "(reason, fields) => { Object.assign(reason, fields); return null; }",
            // RegExp handles are constructed once from fixed platform source literals.
            .regexp_group => "(pattern, text, index) => { const match = pattern.exec(text); const group = match === null ? undefined : match[index]; return group !== null && group !== undefined ? { $: \"Just\", a: group } : { $: \"Nothing\", a: null }; }",
            .map_make => "(ignored) => { return new globalThis.Map(); }",
            .map_get => "(map, key) => { return map.has(key) ? { $: \"Just\", a: map.get(key) } : { $: \"Nothing\", a: null }; }",
            .map_set => "(map, key, value) => { map.set(key, value); return null; }",
            .map_delete => "(map, key) => { map.delete(key); return null; }",
            .map_entries => "(map) => { return Array.from(map, pair => ({ a: pair[0], b: pair[1] })); }",
            .cf_socketInitialize => "(socket, id, protocol, tags) => { socket.serializeAttachment({ data: null, id, protocol, tags: Array.isArray(tags) ? tags : tags.$plain ? tags.$plain() : tags.b.slice(tags.o) }); return null; }",
            .cf_unitResolvers => "(ignored) => { return globalThis.Promise.withResolvers(); }",
            .cf_stringResolvers => "(ignored) => { return globalThis.Promise.withResolvers(); }",
            .cf_dataResolvers => "(ignored) => { return globalThis.Promise.withResolvers(); }",
            .cf_responseResolvers => "(ignored) => { return globalThis.Promise.withResolvers(); }",
            .cf_program => "(fetch, definitions) => { return { fetch, objects: (Array.isArray(definitions) ? definitions : definitions.$plain ? definitions.$plain() : definitions.b.slice(definitions.o)).slice() }; }",
            .cf_definition => "(name, start) => { return { name, start }; }",
            .cf_instance => "(fetch, alarm, rpc, message, closed, failed) => { return { fetch, alarm, rpc: (chain, kind, id, text) => rpc(chain == null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: chain }, kind, id == null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: id }, text), webSocketMessage: (socket, value) => message(socket, typeof value === \"string\" ? { $: \"Just\", a: value } : { $: \"Nothing\", a: null }), webSocketClose: closed, webSocketError: failed }; }",
            .cf_namespace => "(env, name) => { const binding = env[name]; return binding == null || typeof binding.idFromName !== \"function\" || typeof binding.fetch === \"function\" ? { $: \"Nothing\", a: null } : { $: \"Just\", a: binding }; }",
            .cf_service => "(env, name) => { const binding = env[name]; return binding == null || typeof binding.fetch !== \"function\" ? { $: \"Nothing\", a: null } : { $: \"Just\", a: binding }; }",
            .cf_variable => "(env, name) => { const binding = env[name]; return typeof binding === \"string\" ? { $: \"Just\", a: binding } : { $: \"Nothing\", a: null }; }",
            .cf_byName => "(ns, name) => { return ns.getByName(name); }",
            .cf_uniqueId => "(ns) => { return ns.newUniqueId(); }",
            .cf_idFromString => "(ns, text) => { try { return { $: \"Just\", a: ns.idFromString(text) }; } catch (error) { if (!(error instanceof globalThis.TypeError)) throw error; return { $: \"Nothing\", a: null }; } }",
            .cf_getStub => "(ns, id) => { return ns.get(id); }",
            .cf_stubId => "(stub) => { return stub.id; }",
            .cf_idText => "(id) => { return id.toString(); }",
            .cf_idName => "(id) => { return id.name == null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: id.name }; }",
            .cf_requestMethod => "(request) => { return request.method; }",
            .cf_requestUrl => "(request) => { return request.url; }",
            .cf_requestPath => "(request) => { return new globalThis.URL(request.url).pathname; }",
            .cf_requestHeaders => "(request) => { return request.headers; }",
            .cf_requestText => "(request) => { return request.text(); }",
            .cf_requestCopy => "(request, headers) => { return new globalThis.Request(request, { headers }); }",
            .cf_requestSignal => "(request) => { return request.signal == null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: request.signal }; }",
            .cf_onAbort => "(signal, callback) => { signal.addEventListener(\"abort\", () => callback(null)); return null; }",
            .cf_responseCreate => "(status, body, headers) => { const pairs = Array.isArray(headers) ? headers : headers.$plain ? headers.$plain() : headers.b.slice(headers.o); return new globalThis.Response(body.$ === \"Just\" ? body.a : null, { status, headers: pairs.map(pair => [pair.a, pair.b]) }); }",
            .cf_responseCopy => "(response) => { return new globalThis.Response(response.body, response); }",
            .cf_stubFetch => "(stub, request) => { return stub.fetch(request); }",
            .cf_serviceFetch => "(service, request) => { return service.fetch(request); }",
            .cf_stubRpc => "(stub, chain, kind, id, text) => { return stub.$beni(chain, kind, id.$ === \"Just\" ? id.a : null, text); }",
            .cf_overloaded => "(reason) => { return reason != null && reason.overloaded === true; }",
            .cf_reset => "(reason) => { return reason != null && reason.durableObjectReset === true; }",
            .cf_retryable => "(reason) => { return reason != null && reason.retryable === true; }",
            .cf_errorText => "(reason) => { return String(reason); }",
            .cf_randomUUID => "(ignored) => { return globalThis.crypto.randomUUID(); }",
            .cf_waitUntil => "(context, promise) => { context.waitUntil(promise); return null; }",
            .cf_objectWaitUntil => "(state, promise) => { state.waitUntil(promise); return null; }",
            .cf_objectId => "(state) => { return state.id; }",
            .cf_objectAbort => "(state, reason) => { state.abort(reason); return null; }",
            .cf_alarmSet => "(state, when) => { state.storage.setAlarm(when); return null; }",
            .cf_alarmDelete => "(state) => { state.storage.deleteAlarm(); return null; }",
            .cf_sockets => "(state) => { return state.getWebSockets(); }",
            .cf_socketsTagged => "(state, tag) => { return state.getWebSockets(tag); }",
            .cf_acceptSocket => "(state, socket, tags) => { state.acceptWebSocket(socket, Array.isArray(tags) ? tags : tags.$plain ? tags.$plain() : tags.b.slice(tags.o)); return null; }",
            .cf_autoResponse => "(state, request, response) => { state.setWebSocketAutoResponse(new globalThis.WebSocketRequestResponsePair(request, response)); return null; }",
            .cf_socketPair => "(ignored) => { return new globalThis.WebSocketPair(); }",
            .cf_socketClient => "(pair) => { return pair[0]; }",
            .cf_socketServer => "(pair) => { return pair[1]; }",
            .cf_socketResponse => "(client, protocol) => { return new globalThis.Response(null, { status: 101, webSocket: client, headers: protocol === \"\" ? [] : [[\"sec-websocket-protocol\", protocol]] }); }",
            .cf_socketCloseEmpty => "(socket) => { socket.close(); return null; }",
            .cf_consoleError => "(text) => { globalThis.console.error(text); return null; }",
            .cf_consoleLog => "(text) => { globalThis.console.log(text); return null; }",
            .cf_consoleReason => "(text, reason) => { globalThis.console.error(text, reason); return null; }",
            .promise_of => "(resolvers) => { return resolvers.promise; }",
            .promise_resolve => "(resolvers, value) => { resolvers.resolve(value); return null; }",
            .promise_reject => "(resolvers, reason) => { resolvers.reject(reason); return null; }",
            .promise_after => "(promise, done) => { return promise.then(done); }",
            .cf_socketEq => "(a, b) => { return a === b; }",
            .cf_socketState => "(socket) => { return socket.readyState; }",
            .cf_socketSend => "(socket, text) => { socket.send(text); return null; }",
            .cf_socketClose => "(socket, code, reason) => { socket.close(code, reason); return null; }",
            .cf_socketAttachment => "(socket) => { return socket.deserializeAttachment(); }",
            .cf_socketAttach => "(socket, data) => { socket.serializeAttachment(data); return null; }",
            .cf_kv => "(state) => { const kv = state.storage.kv; return kv == null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: kv }; }",
            .cf_kvGet => "(store, key) => { const value = store.get(key); return value == null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: value }; }",
            .cf_kvPut => "(store, key, text) => { try { store.put(key, text); return true; } catch (error) { if (!(error instanceof globalThis.Error) || !String(error.message).includes(\"SQLITE_FULL\")) throw error; return false; } }",
            .cf_kvDelete => "(store, key) => { return store.delete(key); }",
            .cf_kvKeys => "(store, prefix) => { return Array.from(store.list({ prefix }), pair => pair[0]); }",
            .worker_supported => "(ignored) => { return typeof globalThis.Worker === \"function\"; }",
            .worker_create => "(url, name, credentials) => { try { return { $: \"Ok\", a: new globalThis.Worker(url, { type: \"module\", name, credentials }) }; } catch (error) { if (error instanceof globalThis.DOMException && (error.name === \"SyntaxError\" || error.name === \"SecurityError\")) return { $: \"Err\", a: error.name }; if (error instanceof globalThis.TypeError) return { $: \"Err\", a: \"TypeError\" }; throw error; } }",
            .worker_endpoint => "(worker) => { return worker; }",
            .worker_self_endpoint => "(ignored) => { return globalThis.self; }",
            .worker_post => "(endpoint, payload) => { try { endpoint.postMessage(payload); return { $: \"Ok\", a: null }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== \"DataCloneError\") throw error; return { $: \"Err\", a: \"DataCloneError\" }; } }",
            .worker_terminate => "(worker) => { worker.terminate(); return null; }",
            .worker_event_target => "(endpoint) => { return endpoint; }",
            .global_event_target => "(ignored) => { return globalThis; }",
            .event_data_only => "(event) => { const value = event.data;\n" ++ CheckedData.body ++ "}",
            .key_map_values => "(map) => { return globalThis.Array.from(map.values()); }",
            .key_map_make => "(unit) => { return new globalThis.Map(); }",
            .key_map_get_or => "(map, key, fallback) => { const value = map.get(key); return value !== undefined || map.has(key) ? value : fallback; }",
            .key_map_get => "(map, key) => { return map.has(key) ? { $: \"Just\", a: map.get(key) } : { $: \"Nothing\", a: null }; }",
            .key_map_set => "(map, key, value) => { map.set(key, value); return null; }",
            .key_map_has => "(map, key) => { return map.has(key); }",
            .key_map_remove => "(map, key) => { return map.delete(key); }",
            .key_map_clear => "(map) => { map.clear(); return null; }",
            .key_map_size => "(map) => { return map.size; }",
            .key_map_each => "(map, visit) => { map.forEach((value, key) => visit(key, value)); return null; }",
            .document_body => "(unit) => { const body = globalThis.document.body; return body === null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: body }; }",
            .document_create_element => "(unit) => { return globalThis.document.createElement(\"div\"); }",
            .node_append => "(parent, child) => { try { parent.appendChild(child); return { $: \"Ok\", a: null }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== \"HierarchyRequestError\") throw error; return { $: \"Err\", a: { $: \"HierarchyRequestError\", a: null } }; } }",
            .element_attribute => "(element, value) => { element.setAttribute(\"style\", value); return null; }",
            .event_message => "(event) => { return globalThis.String(event.message); }",
            .rejection_display => "(reason) => { return globalThis.String(reason); }",
            .event_error => "(event) => { const error = event.error; return error == null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: error }; }",
            .console_error_data => "(label, data) => { globalThis.console.error(label, data); return null; }",
            .rejection_abandoned => "(error, reports) => { error.abandonedWorkers = reports; return null; }",
            .data_same => "(a, b) => { return Object.is(a, b); }",
            .document_by_id => "(documentId) => { const element = globalThis.document.getElementById(documentId); return element === null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: element }; }",
            .element_focus => "(element) => { element.focus(); return null; }",
            .element_blur => "(element) => { element.blur(); return null; }",
            .element_box => "(element) => { return element.getBoundingClientRect(); }",
            .element_scroll => "(element, x, y) => { element.scrollTo(x, y); return null; }",
            .element_into_view => "(element) => { element.scrollIntoView(); return null; }",
            .rect_x => "(rect) => { return rect.x; }",
            .rect_y => "(rect) => { return rect.y; }",
            .rect_width => "(rect) => { return rect.width; }",
            .rect_height => "(rect) => { return rect.height; }",
            .window_scroll_x => "(_) => { return globalThis.scrollX; }",
            .window_scroll_y => "(_) => { return globalThis.scrollY; }",
            .element_fullscreen_supported => "(element) => { return typeof element.requestFullscreen === \"function\"; }",
            .element_fullscreen => "(element) => { return element.requestFullscreen(); }",
            .document_fullscreen_enabled => "(_) => { return globalThis.document.fullscreenEnabled === true; }",
            .document_fullscreen_id => "(_) => { const element = globalThis.document.fullscreenElement; return element == null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: element.id }; }",
            .document_fullscreen_exit => "(_) => { return globalThis.document.exitFullscreen(); }",
            .navigator_activated => "(_) => { const state = globalThis.navigator.userActivation; return state == null || state.isActive === true; }",
            .rejection_type_error_message => "(error) => { return error instanceof globalThis.TypeError ? { $: \"Just\", a: error.message } : { $: \"Nothing\", a: null }; }",
            .url_protocol => "(url) => { return url.protocol; }",
            .url_set_protocol => "(url, protocol) => { url.protocol = protocol; return null; }",
            .ws_create => "(url, protocols) => { try { return { $: \"Just\", a: new globalThis.WebSocket(url, Array.isArray(protocols) ? protocols : (protocols.$plain ? protocols.$plain() : protocols.b.slice(protocols.o))) }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== \"SecurityError\") throw error; return { $: \"Nothing\", a: null }; } }",
            .ws_binary => "(socket) => { socket.binaryType = \"arraybuffer\"; return null; }",
            .ws_state => "(socket) => { return socket.readyState; }",
            .ws_buffered => "(socket) => { return socket.bufferedAmount; }",
            .ws_protocol => "(socket) => { return socket.protocol; }",
            .ws_send => "(socket, text) => { socket.send(text); return null; }",
            .ws_close => "(socket, code, reason) => { socket.close(code, reason); return null; }",
            .ws_close_empty => "(socket) => { socket.close(); return null; }",
            .ws_open => "(socket, callback) => { socket.addEventListener(\"open\", () => callback(null)); return null; }",
            .ws_error => "(socket, callback) => { socket.addEventListener(\"error\", () => callback(null)); return null; }",
            .ws_message => "(socket, callback) => { socket.addEventListener(\"message\", event => callback(typeof event.data === \"string\" ? { $: \"Just\", a: event.data } : { $: \"Nothing\", a: null })); return null; }",
            .ws_closed => "(socket, callback) => { socket.addEventListener(\"close\", event => callback(event.code, event.reason)); return null; }",
            .console_warn => "(text) => { globalThis.console.warn(text); return null; }",
            .storage_local => "(_) => { try { const area = globalThis.localStorage; return area == null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: area }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== \"SecurityError\") throw error; return { $: \"Nothing\", a: null }; } }",
            .storage_session => "(_) => { try { const area = globalThis.sessionStorage; return area == null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: area }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== \"SecurityError\") throw error; return { $: \"Nothing\", a: null }; } }",
            .storage_get => "(area, key) => { const value = area.getItem(key); return value === null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: value }; }",
            .storage_set => "(area, key, value) => { try { area.setItem(key, value); return { $: \"Ok\", a: null }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== \"QuotaExceededError\") throw error; return { $: \"Err\", a: \"QuotaExceeded\" }; } }",
            .storage_remove => "(area, key) => { area.removeItem(key); return null; }",
            .storage_length => "(area) => { return area.length; }",
            .storage_key => "(area, index) => { const key = area.key(index); return key === null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: key }; }",
            .url_try_create => "(text, base) => { let value; if (globalThis.URL.parse === undefined) { try { value = new globalThis.URL(text, base); } catch (error) { if (!(error instanceof globalThis.TypeError)) throw error; return { $: \"Nothing\", a: null }; } } else { value = globalThis.URL.parse(text, base); } return value === null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: value }; }",
            .url_href => "(url) => { return url.href; }",
            .url_username => "(url) => { return url.username; }",
            .url_password => "(url) => { return url.password; }",
            .document_base_uri => "(_) => { return globalThis.document.baseURI; }",
            .headers_create => "(_) => { return new globalThis.Headers(); }",
            .headers_append => "(headers, name, value) => { headers.append(name, value); return null; }",
            .headers_has => "(headers, name) => { return headers.has(name); }",
            .headers_set => "(headers, name, value) => { headers.set(name, value); return null; }",
            .headers_get => "(headers, name) => { const value = headers.get(name); return value === null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: value }; }",
            .headers_entries => "(headers) => { return Array.from(headers, entry => ({ a: entry[0], b: entry[1] })); }",
            .form_create => "(_) => { return new globalThis.FormData(); }",
            .form_append => "(form, name, value) => { form.append(name, value); return null; }",
            .fetch_text_body => "(text) => { return text; }",
            .fetch_form_body => "(form) => { return form; }",
            .fetch_init => "(method, headers, body, signal, credentials) => { return { body: body.$ === \"Just\" ? body.a : undefined, credentials, headers, method, mode: \"cors\", redirect: \"follow\", signal }; }",
            .fetch_call => "(url, init) => { return globalThis.fetch(url, init); }",
            .response_url => "(response) => { return response.url; }",
            .response_status => "(response) => { return response.status; }",
            .response_status_text => "(response) => { return response.statusText; }",
            .response_ok => "(response) => { return response.ok; }",
            .response_headers => "(response) => { return response.headers; }",
            .response_text => "(response) => { return response.text(); }",
            .response_reader => "(response) => { const stream = response.body; return stream === null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: stream.getReader() }; }",
            .reader_bytes => "(reader) => { return reader.read(); }",
            .read_result_done => "(result) => { return result.done; }",
            .read_result_value => "(result) => { return result.value === undefined ? { $: \"Nothing\", a: null } : { $: \"Just\", a: result.value }; }",
            .decoder_create => "(_) => { return new globalThis.TextDecoder(); }",
            .decoder_more => "(decoder, bytes) => { return decoder.decode(bytes, { stream: true }); }",
            .decoder_finish => "(decoder) => { return decoder.decode(); }",
            .dom_exception_create => "(message, name) => { return new globalThis.DOMException(message, name); }",
            .abort_with_reason => "(controller, reason) => { controller.abort(reason); return null; }",
            .abort_reason_is => "(signal, reason) => { return signal.reason === reason; }",
            .rejection_is_type_error => "(reason) => { return reason instanceof globalThis.TypeError; }",
            .regexp_create => "(pattern, flags) => { try { return { $: \"Ok\", a: new globalThis.RegExp(pattern, flags) }; } catch (error) { if (!(error instanceof globalThis.SyntaxError)) throw error; return { $: \"Err\", a: \"SyntaxError\" }; } }",
            .regexp_test => "(pattern, text) => { return pattern.test(text); }",
            .regexp_replace => "(pattern, text, replacement) => { return text.replace(pattern, replacement); }",
            .data_is_array => "(value) => { return globalThis.Array.isArray(value); }",
            .data_is_finite => "(value) => { return globalThis.Number.isFinite(value); }",
            .data_is_integer => "(value) => { return globalThis.Number.isInteger(value); }",
            .data_is_safe_integer => "(value) => { return globalThis.Number.isSafeInteger(value); }",
            .data_keys => "(value) => { return globalThis.Object.keys(value); }",
            .data_empty_object => "(_) => { return globalThis.Object.create(null); }",
            .data_has_own => "(value, key) => { return globalThis.Object.hasOwn(value, key); }",
            .json_parse => "(text) => { try { return { $: \"Ok\", a: globalThis.JSON.parse(text) }; } catch (error) { if (!(error instanceof globalThis.SyntaxError)) throw error; return { $: \"Err\", a: \"SyntaxError\" }; } }",
            .json_stringify => "(value) => { return globalThis.JSON.stringify(value); }",
            .promise_observe => "(promise, done, failed) => { promise.then(done, failed); return null; }",
            .rejection_is_error => "(reason) => { return reason instanceof globalThis.Error; }",
            .rejection_name => "(reason) => { return reason instanceof globalThis.Error ? reason.name : \"\"; }",
            .rejection_code => "(reason) => { return reason instanceof globalThis.Error && typeof reason.code === \"string\" ? { $: \"Just\", a: reason.code } : { $: \"Nothing\", a: null }; }",
            .rejection_raise => "(reason) => { throw reason; }",
            .abort_create => "(_) => { return new globalThis.AbortController(); }",
            .abort_signal => "(controller) => { return controller.signal; }",
            .abort_call => "(controller) => { controller.abort(); return null; }",
            .abort_aborted => "(signal) => { return signal.aborted; }",
            .node_read_utf8 => "(path, signal) => { return globalThis.process.getBuiltinModule(\"node:fs/promises\").readFile(path, { encoding: \"utf8\", signal }); }",
            .node_read_dir => "(path) => { return globalThis.process.getBuiltinModule(\"node:fs/promises\").readdir(path, { withFileTypes: true }); }",
            .dirent_name => "(entry) => { return entry.name; }",
            .dirent_file => "(entry) => { return entry.isFile(); }",
            .dirent_directory => "(entry) => { return entry.isDirectory(); }",
            .dirent_link => "(entry) => { return entry.isSymbolicLink(); }",
            .process_stdout => "(text) => { globalThis.process.stdout.write(text); return null; }",
            .process_stderr => "(text) => { globalThis.process.stderr.write(text); return null; }",
            .process_exit_code => "(code) => { globalThis.process.exitCode = code; return null; }",
            .process_before_exit => "(work) => { globalThis.process.on(\"beforeExit\", () => work(null)); return null; }",
            .event_listen => "(target, name, handler) => { target.addEventListener(name, handler); return (_) => { target.removeEventListener(name, handler); return null; }; }",
            .document_title_read => "(_) => { return globalThis.document.title; }",
            .frame_request => "(work) => { return globalThis.requestAnimationFrame(() => work(null)); }",
            .frame_cancel => "(frame) => { globalThis.cancelAnimationFrame(frame); return null; }",
            .inner_width => "(_) => { return globalThis.innerWidth; }",
            .inner_height => "(_) => { return globalThis.innerHeight; }",
            .visibility_state => "(_) => { return globalThis.document.visibilityState; }",
            .document_title => "(title) => { globalThis.document.title = title; return null; }",
            .event_prevented => "(event) => { return event.defaultPrevented; }",
            .event_button => "(event) => { return event.button; }",
            .event_path => "(event) => { return event.composedPath(); }",
            .as_anchor => "(target) => { return target instanceof globalThis.HTMLAnchorElement ? { $: \"Just\", a: target } : { $: \"Nothing\", a: null }; }",
            .anchor_has => "(anchor, name) => { return anchor.hasAttribute(name); }",
            .anchor_href => "(anchor) => { return anchor.href; }",
            .anchor_protocol => "(anchor) => { return anchor.protocol; }",
            .anchor_host => "(anchor) => { return anchor.host; }",
            .anchor_target => "(anchor) => { return anchor.target; }",
            .event_box => "(event) => { return event.currentTarget.getBoundingClientRect(); }",
            .rect_left => "(rect) => { return rect.left; }",
            .rect_top => "(rect) => { return rect.top; }",
            .event_target_value => "(event) => { return event.target.value; }",
            .event_target_checked => "(event) => { return event.target.checked; }",
            .listen_window => "(name, handler) => { globalThis.addEventListener(name, handler); return (_) => { globalThis.removeEventListener(name, handler); return null; }; }",
            .listen_document => "(name, handler) => { const target = globalThis.document; target.addEventListener(name, handler); return (_) => { target.removeEventListener(name, handler); return null; }; }",
            .event_prevent => "(event) => { event.preventDefault(); return null; }",
            .event_key => "(event) => { return event.key ?? \"\"; }",
            .event_code => "(event) => { return event.code ?? \"\"; }",
            .event_ctrlKey => "(event) => { return event.ctrlKey === true; }",
            .event_shiftKey => "(event) => { return event.shiftKey === true; }",
            .event_altKey => "(event) => { return event.altKey === true; }",
            .event_metaKey => "(event) => { return event.metaKey === true; }",
            .event_pointerId => "(event) => { return event.pointerId; }",
            .event_pointerType => "(event) => { return event.pointerType ?? \"\"; }",
            .event_isPrimary => "(event) => { return event.isPrimary === true; }",
            .event_clientX => "(event) => { return event.clientX; }",
            .event_clientY => "(event) => { return event.clientY; }",
            .queue_microtask => "(work) => { globalThis.queueMicrotask(() => work(null)); return null; }",
            .timer_start => "(work, delay) => { return globalThis.setTimeout(() => work(null), delay); }",
            .timer_clear => "(timer) => { globalThis.clearTimeout(timer); return null; }",
            .message_channel => "(_) => { return new globalThis.MessageChannel(); }",
            .message_port1 => "(channel) => { return channel.port1; }",
            .message_port2 => "(channel) => { return channel.port2; }",
            .post_unit => "(port) => { port.postMessage(null); return null; }",
            .on_message => "(port, work) => { port.onmessage = () => work(null); return null; }",
            .try_immediate => "(work) => { if (typeof globalThis.setImmediate !== \"function\") return false; globalThis.setImmediate(() => work(null)); return true; }",
            .date_now => "(_) => { return globalThis.Date.now(); }",
            .math_random => "(_) => { return globalThis.Math.random(); }",

            .document => "(_) => { return globalThis.document; }",
            .query_selector => "(node, selector) => {\n  try {\n    const element = node.querySelector(selector);\n    return { $: \"Ok\", a: element === null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: element } };\n  } catch (error) {\n    if (!(error instanceof globalThis.DOMException) || error.name !== \"SyntaxError\") throw error;\n    return { $: \"Err\", a: { $: \"SyntaxError\", a: null } };\n  }\n}",
            .text_content => "(node) => { const text = node.textContent; return text === null ? { $: \"Nothing\", a: null } : { $: \"Just\", a: text }; }",
            .set_text_content => "(node, text) => { node.textContent = text; return null; }",
            .identity => "(element) => { return element; }",
            .text_encoder => "(_) => { return new globalThis.TextEncoder(); }",
            .encode => "(encoder, text) => { return encoder.encode(text); }",
            .byte_length => "(bytes) => { return bytes.byteLength; }",
            .timeout => "(callback, delay) => { return globalThis.setTimeout(() => callback(null), delay); }",
            .worker_self => "(_) => { return globalThis.self; }",
        };
        try w.print("export const {s} = {s};\n", .{ row.name, body });
    }
    return out.toOwnedSlice();
}

pub const Binding = struct {
    operation: Operations.Row,
    member: ?u32 = null,
    file: ?u32,
    start: u32,
    end: u32,
};

/// Source-linked callable rows are generated only from the verified archive.
/// Intrinsic rows use their explicit versioned primary-source recipe instead.
pub fn bindings(arena: Allocator, c: anytype) Allocator.Error![]const Binding {
    const out = try arena.alloc(Binding, Operations.rows.len);
    for (Operations.rows, out) |row, *binding| {
        binding.* = .{ .operation = row, .file = null, .start = 0, .end = 0 };
        if (row.recipe == .byte_length or row.source != .webidl) continue;
        for (c.declarations) |d| {
            if (d.partial or d.kind == .includes or !std.mem.eql(u8, d.name, row.owner)) continue;
            if (row.recipe == .identity or row.recipe == .renderer_from_node) {
                binding.file = d.file;
                binding.start = d.source_span.start;
                binding.end = d.source_span.end;
                break;
            }
            for (c.members, 0..) |member, mi| {
                if (!std.mem.eql(u8, c.declarations[member.owner].name, row.owner)) continue;
                const text = member.source_span.text(c.files[member.file].source);
                if (!hasMember(text, row.member)) continue;
                binding.member = @intCast(mi);
                binding.file = member.file;
                binding.start = member.source_span.start;
                binding.end = member.source_span.end;
                break;
            }
        }
        std.debug.assert(binding.file != null);
    }
    return out;
}

fn hasMember(text: []const u8, member: []const u8) bool {
    if (member.len == 0) return false; // Identity upcasts link the declaration, not a member.
    var at: usize = 0;
    while (std.mem.findPos(u8, text, at, member)) |pos| {
        const end = pos + member.len;
        if ((pos == 0 or !identifierByte(text[pos - 1])) and (end == text.len or !identifierByte(text[end]))) return true;
        at = end;
    }
    return false;
}

fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}
