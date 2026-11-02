//! Resolve the reviewed adapters against the catalogue, then generate ordinary
//! typed modules and their exact-error siblings. Unsupported members stay private.
const std = @import("std");
const Operations = @import("Operations.zig");
const Allocator = std.mem.Allocator;

pub fn validate(c: anytype) bool {
    for (Operations.rows) |row| {
        if (row.recipe == .byte_length) continue; // Versioned ECMAScript intrinsic.
        var owner: ?u32 = null;
        for (c.declarations, 0..) |d, i| {
            if (!d.partial and d.kind != .includes and std.mem.eql(u8, d.name, row.owner)) owner = @intCast(i);
        }
        const declaration = owner orelse return false;
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
            if (m.owner != declaration) continue;
            const text = m.source_span.text(c.files[m.file].source);
            if (hasMember(text, row.member)) found = true;
        }
        if (!found) return false;
        // Mixin exposure belongs to the implementing native receiver.
        const receiver = if (std.mem.eql(u8, row.owner, "ParentNode")) "Document" else if (std.mem.eql(u8, row.owner, "WindowOrWorkerGlobalScope")) "Window" else row.owner;
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
        if (row.recipe == .timeout) exposure |= Operations.workers;
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
    if (std.mem.eql(u8, module, "Browser.Host.Window")) try w.writeAll("import Browser.Host.Document as Document\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Document")) try w.writeAll("import Browser.Host.Element as Element\n\n\npub type QueryError\n    = SyntaxError\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.Element")) try w.writeAll("import Browser.Host.Node as Node\n\n\n");
    if (std.mem.eql(u8, module, "Browser.Host.TextEncoder")) try w.writeAll("import Browser.Host.Uint8Array as Uint8Array\n\n\n");
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
        if (row.recipe == .byte_length) continue;
        for (c.declarations, 0..) |d, di| {
            if (d.partial or d.kind == .includes or !std.mem.eql(u8, d.name, row.owner)) continue;
            if (row.recipe == .identity) {
                binding.file = d.file;
                binding.start = d.source_span.start;
                binding.end = d.source_span.end;
                break;
            }
            for (c.members, 0..) |member, mi| {
                if (member.owner != di) continue;
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
