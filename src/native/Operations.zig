//! Reviewed callable subset of the pinned native catalogue. The generator
//! resolves each row to actual IDL before exposing it. Core owns the generated
//! sources; an application module with the same name has no native authority.
const std = @import("std");
pub const all: u8 = 0x1f;
pub const browser: u8 = 0x0f;
pub const window: u8 = 1;
pub const workers: u8 = 0x0e;
pub fn bit(realm: anytype) u8 {
    return @as(u8, 1) << @intCast(@backingInt(realm));
}
pub const Recipe = enum { document, query_selector, text_content, set_text_content, identity, text_encoder, encode, byte_length, timeout, worker_self };
pub const Adapter = enum { total, syntax_error };
pub const Row = struct {
    owner: []const u8,
    member: []const u8,
    module: []const u8,
    name: []const u8,
    signature: []const u8,
    recipe: Recipe,
    adapter: Adapter = .total,
    effect: enum { pure, impure } = .impure,
    allowed: u8,
    algorithm: []const u8,
};
pub const rows = [_]Row{
    .{ .owner = "Window", .member = "document", .module = "Browser.Host.Window", .name = "document", .signature = "⊤ → Document.Document", .recipe = .document, .allowed = window, .algorithm = "https://html.spec.whatwg.org/multipage/window-object.html#dom-document" },
    .{ .owner = "ParentNode", .member = "querySelector", .module = "Browser.Host.Document", .name = "querySelector", .signature = "Document, String → Result QueryError (Maybe Element.Element)", .recipe = .query_selector, .adapter = .syntax_error, .allowed = window, .algorithm = "https://dom.spec.whatwg.org/#dom-parentnode-queryselector" },
    .{ .owner = "Node", .member = "textContent", .module = "Browser.Host.Node", .name = "textContent", .signature = "Node → Maybe String", .recipe = .text_content, .allowed = window, .algorithm = "https://dom.spec.whatwg.org/#dom-node-textcontent" },
    .{ .owner = "Node", .member = "textContent", .module = "Browser.Host.Node", .name = "setTextContent", .signature = "Node, String → ⊤", .recipe = .set_text_content, .allowed = window, .algorithm = "https://dom.spec.whatwg.org/#dom-node-textcontent" },
    .{ .owner = "Element", .member = "", .module = "Browser.Host.Element", .name = "toNode", .signature = "Element → Node.Node", .recipe = .identity, .effect = .pure, .allowed = window, .algorithm = "https://dom.spec.whatwg.org/#interface-element" },
    .{ .owner = "TextEncoder", .member = "constructor", .module = "Browser.Host.TextEncoder", .name = "create", .signature = "⊤ → TextEncoder", .recipe = .text_encoder, .allowed = all, .algorithm = "https://encoding.spec.whatwg.org/#dom-textencoder" },
    .{ .owner = "TextEncoder", .member = "encode", .module = "Browser.Host.TextEncoder", .name = "encode", .signature = "TextEncoder, String → Uint8Array.Uint8Array", .recipe = .encode, .allowed = all, .algorithm = "https://encoding.spec.whatwg.org/#dom-textencoder-encode" },
    .{ .owner = "Uint8Array", .member = "byteLength", .module = "Browser.Host.Uint8Array", .name = "byteLength", .signature = "Uint8Array → Int", .recipe = .byte_length, .effect = .pure, .allowed = all, .algorithm = "https://tc39.es/ecma262/#sec-get-%typedarray%.prototype.bytelength" },
    .{ .owner = "WindowOrWorkerGlobalScope", .member = "setTimeout", .module = "Browser.Host.Timers", .name = "setTimeout", .signature = "sync (⊤ → ⊤), Int → Int", .recipe = .timeout, .allowed = browser, .algorithm = "https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#dom-settimeout" },
    .{ .owner = "WorkerGlobalScope", .member = "self", .module = "Browser.Host.WorkerGlobalScope", .name = "self", .signature = "⊤ → WorkerGlobalScope", .recipe = .worker_self, .allowed = workers, .algorithm = "https://html.spec.whatwg.org/multipage/workers.html#dom-workerglobalscope-self" },
};
pub fn lookup(module: []const u8, name: []const u8) ?Row {
    for (rows) |row| if (std.mem.eql(u8, row.module, module) and std.mem.eql(u8, row.name, name)) return row;
    return null;
}
pub fn nativeModule(module: []const u8) bool {
    return std.mem.startsWith(u8, module, "Browser.Host.");
}
