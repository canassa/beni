//! Resolve the reviewed adapters against the catalogue, then generate ordinary
//! typed modules and their exact-error siblings. Unsupported members stay private.
const std = @import("std");
const Operations = @import("Operations.zig");
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
        if (row.recipe == .identity) {
            var found = false;
            for (c.upcasts) |edge| {
                if (c.native_types[edge.from].declaration == declaration and std.mem.eql(u8, c.native_types[edge.to].idl_name, "Node")) found = true;
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
        const receiver = if (std.mem.eql(u8, row.owner, "AnimationFrameProvider")) "Window" else if (row.recipe == .as_anchor or std.mem.eql(u8, row.owner, "HTMLHyperlinkElementUtils") or std.mem.eql(u8, row.owner, "HyperlinkElementUtils")) "HTMLAnchorElement" else if (row.recipe == .listen_window or row.recipe == .listen_document) "Window" else if (std.mem.eql(u8, row.owner, "ParentNode")) "Document" else if (std.mem.eql(u8, row.owner, "WindowOrWorkerGlobalScope")) "Window" else if (std.mem.eql(u8, row.owner, "MessageEventTarget")) "MessagePort" else row.owner;
        var exposure: u8 = 0;
        for (c.native_types) |t| {
            if (!std.mem.eql(u8, t.idl_name, receiver)) continue;
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
    try w.writeAll("-- Generated from @webref/idl 3.86.0; reviewed adapters in native/Operations.zig.\n");
    if (std.mem.eql(u8, module, "Browser.Host.Events")) try w.writeAll("import Browser.Host.Event as Event\nimport Browser.Host.EventTarget as EventTarget\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.EventTarget")) try w.writeAll("import Browser.Host.HTMLAnchorElement as HTMLAnchorElement\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Event")) try w.writeAll("import Browser.Host.EventTarget as EventTarget\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Event")) try w.writeAll("import Browser.Host.DOMRect as DOMRect\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Window") or std.mem.eql(u8, module, "Browser.Host.Document")) try w.writeAll("import Browser.Host.Event as Event\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Window")) try w.writeAll("import Browser.Host.Document as Document\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Document")) try w.writeAll("import Browser.Host.Element as Element\n\n\npub type QueryError\n    = SyntaxError\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Element")) try w.writeAll("import Browser.Host.Node as Node\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.TextEncoder")) try w.writeAll("import Browser.Host.Uint8Array as Uint8Array\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.MessageChannel")) try w.writeAll("import Browser.Host.MessagePort as MessagePort\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Timers")) try w.writeAll("-- A browser numeric timer id or a Node Timeout handle; never plain data.\npub foreign type Timer\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Window")) try w.writeAll("pub foreign type Frame\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Promise")) try w.writeAll("import Browser.Host.Rejection as Rejection\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.AbortController")) try w.writeAll("import Browser.Host.AbortSignal as AbortSignal\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.NodeFs")) try w.writeAll("import Browser.Host.AbortSignal as AbortSignal\nimport Browser.Host.Promise as Promise\nimport Browser.Host.NodeDirent as NodeDirent\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Data") or std.mem.eql(u8, module, "Browser.Host.Json")) try w.writeAll("import Js\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Json")) try w.writeAll("pub type ParseError\n    = SyntaxError\n\n\n");
    if (type_name) |name| try w.print("pub foreign type {s}\n", .{name});
    for (Operations.rows) |row| {
        if (!std.mem.eql(u8, row.module, module)) continue;
        try w.print("{s}pub foreign {s} {s} : {s}\n", .{ if (type_name == null) "\n" else "\n\n", @tagName(row.effect), row.name, row.signature });
    }
    return out.toOwnedSlice();
}

pub fn sibling(arena: Allocator, module: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    for (Operations.rows) |row| {
        if (!std.mem.eql(u8, row.module, module)) continue;
        const body = switch (row.recipe) {
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
            if (row.recipe == .identity) {
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
