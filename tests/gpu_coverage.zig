//! The WebGPU coverage gate (`docs/design/webgpu.md` §10, §10.1): every
//! declaration, member, overload and applied mixin member of the pinned
//! `webgpu.idl` has a row in `docs/design/research/webgpu/coverage.md`, and
//! every row is bound — to public beni declarations that exist and a
//! behavioural fixture that exists and names one of them — or waits for a
//! later slice the file lists. It reads the committed files and runs in
//! `zig build test-blackbox`, a gate; `tests/gpu_bindings.zig` imports it.
const std = @import("std");
const Native = @import("native_bindings");
const Gpu = Native.Gpu;

pub const coverage_path = "docs/design/research/webgpu/coverage.md";
/// The modules a user can import: what `browser-tea` re-exports.
pub const public_manifest = "platforms/browser-tea/beni.json";
/// Where a fixture's test-platform imports live.
pub const test_platform_dir = "tests/platforms/gpu";
const max_file = 4 * 1024 * 1024;

const Row = struct {
    section: []const u8,
    key: []const u8,
    declarations: []const u8,
    fixtures: []const u8,
    line: usize,
    used: bool = false,
};

const Coverage = struct {
    rows: []Row,
    /// Every section heading, as `<kind words> <name>`.
    sections: []const []const u8,
    /// The issue numbers of the later-slice table.
    later: []const u32,
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn unquote(s: []const u8) []const u8 {
    const t = trim(s);
    if (t.len >= 2 and t[0] == '`' and t[t.len - 1] == '`') return t[1 .. t.len - 1];
    return t;
}

/// The cells of a table line `| a | b | c |`.
fn cells(a: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const inner = trim(line);
    if (inner.len < 2 or inner[0] != '|' or inner[inner.len - 1] != '|') return out.toOwnedSlice(a);
    var it = std.mem.splitScalar(u8, inner[1 .. inner.len - 1], '|');
    while (it.next()) |cell| try out.append(a, trim(cell));
    return out.toOwnedSlice(a);
}

fn parse(a: std.mem.Allocator, text: []const u8) !Coverage {
    var rows: std.ArrayList(Row) = .empty;
    var sections: std.ArrayList([]const u8) = .empty;
    var later: std.ArrayList(u32) = .empty;
    var section: ?[]const u8 = null;
    var in_later = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (std.mem.startsWith(u8, line, "## ")) {
            in_later = std.mem.eql(u8, trim(line), "## Later slices");
            section = null;
            if (in_later) continue;
            // `## <kind words> `<name>`[ `: Parent`]`
            const open = std.mem.findScalar(u8, line, '`') orelse continue;
            const close = std.mem.findScalarPos(u8, line, open + 1, '`') orelse continue;
            const heading = try std.fmt.allocPrint(a, "{s} {s}", .{ trim(line[3..open]), line[open + 1 .. close] });
            try sections.append(a, heading);
            section = heading;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "|")) continue;
        const cs = try cells(a, line);
        if (cs.len < 3 or std.mem.startsWith(u8, cs[0], "---") or std.mem.eql(u8, cs[0], "IDL") or std.mem.eql(u8, cs[0], "Slice")) continue;
        if (in_later) {
            const issue = cs[1];
            if (issue.len > 1 and issue[0] == '#') try later.append(a, try std.fmt.parseInt(u32, issue[1..], 10));
            continue;
        }
        try rows.append(a, .{ .section = section orelse "(no section)", .key = unquote(cs[0]), .declarations = cs[1], .fixtures = cs[2], .line = number });
    }
    return .{ .rows = try rows.toOwnedSlice(a), .sections = try sections.toOwnedSlice(a), .later = try later.toOwnedSlice(a) };
}

/// A member's row key: an attribute by its name; an operation by its name
/// and parameter names, so each overload has its own; `constructor(…)`;
/// `setlike`.
pub fn memberKey(a: std.mem.Allocator, source: []const u8) ![]const u8 {
    var t = trim(std.mem.trim(u8, source, " \t\r\n;"));
    // Extended attributes.
    while (t.len > 0 and t[0] == '[') {
        var depth: usize = 0;
        var i: usize = 0;
        while (i < t.len) : (i += 1) {
            if (t[i] == '[') depth += 1;
            if (t[i] == ']') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        t = std.mem.trimStart(u8, t[@min(i + 1, t.len)..], " \t\r\n");
    }
    if (std.mem.find(u8, t, "setlike<") != null) return "setlike";
    const is_attribute = std.mem.startsWith(u8, t, "attribute ") or std.mem.startsWith(u8, t, "readonly attribute ");
    const open = std.mem.findScalar(u8, t, '(');
    if (open != null and !is_attribute) {
        const head = std.mem.trimEnd(u8, t[0..open.?], " \t\r\n");
        // A constructor has no return type before its name.
        const name = if (std.mem.findLastAny(u8, head, " \t\r\n")) |space| head[space + 1 ..] else head;
        const close = std.mem.findScalarLast(u8, t, ')') orelse return error.MemberWithoutName;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, name);
        try out.append(a, '(');
        var depth: usize = 0;
        var start: usize = open.? + 1;
        var first = true;
        var i: usize = start;
        while (i <= close) : (i += 1) {
            const c = if (i == close) ',' else t[i];
            switch (c) {
                '<', '(', '[', '{' => depth += 1,
                '>', ')', ']', '}' => depth -= 1,
                ',' => if (depth == 0) {
                    var param = t[start..i];
                    if (std.mem.findScalar(u8, param, '=')) |eq| param = param[0..eq];
                    param = std.mem.trim(u8, param, " \t\r\n");
                    if (param.len > 0) {
                        const word = param[(std.mem.findLastAny(u8, param, " \t\r\n") orelse return error.MemberWithoutName) + 1 ..];
                        if (!first) try out.appendSlice(a, ", ");
                        try out.appendSlice(a, word);
                        first = false;
                    }
                    start = i + 1;
                },
                else => {},
            }
        }
        try out.append(a, ')');
        return out.toOwnedSlice(a);
    }
    // A constant: `const T NAME = value;`.
    const end = if (std.mem.startsWith(u8, t, "const "))
        std.mem.findScalar(u8, t, '=') orelse return error.MemberWithoutName
    else
        std.mem.findScalar(u8, t, ';') orelse t.len;
    const head = std.mem.trimEnd(u8, t[0..end], " \t\r\n");
    return head[(std.mem.findLastAny(u8, head, " \t\r\n") orelse return error.MemberWithoutName) + 1 ..];
}

/// The heading words of a declaration's section.
fn kindWords(d: Native.Declaration) []const u8 {
    return switch (d.kind) {
        .interface => if (d.partial) "partial interface" else "interface",
        .mixin => if (d.partial) "partial interface mixin" else "interface mixin",
        .namespace => if (d.partial) "partial namespace" else "namespace",
        .dictionary => if (d.partial) "partial dictionary" else "dictionary",
        .enumeration => "enum",
        .typedef => "typedef",
        .includes => "includes",
        .callback => "callback",
        .callback_interface => "callback interface",
    };
}

const Required = struct { section: []const u8, key: []const u8 };

/// Every row the IDL requires, in IDL order.
fn required(a: std.mem.Allocator, c: Native.Catalogue) ![]const Required {
    var out: std.ArrayList(Required) = .empty;
    for (c.declarations) |d| {
        if (!std.mem.eql(u8, c.files[d.file].path, Gpu.idl_file)) continue;
        const words = kindWords(d);
        switch (d.kind) {
            .includes => {
                const mixin = d.parent.?;
                const section = try std.fmt.allocPrint(a, "includes {s} includes {s};", .{ d.name, mixin });
                for (c.declarations) |m| {
                    if (m.kind != .mixin or !std.mem.eql(u8, m.name, mixin) or !std.mem.eql(u8, c.files[m.file].path, Gpu.idl_file)) continue;
                    for (c.members[m.members_start..m.members_end]) |member|
                        try out.append(a, .{ .section = section, .key = try memberKey(a, member.source_span.text(c.files[member.file].source)) });
                }
            },
            // A mixin is bound where it is included.
            .mixin => {},
            .interface, .callback_interface => {
                const section = try std.fmt.allocPrint(a, "{s} {s}", .{ words, d.name });
                if (!d.partial) try out.append(a, .{ .section = section, .key = d.name });
                for (c.members[d.members_start..d.members_end]) |member|
                    try out.append(a, .{ .section = section, .key = try memberKey(a, member.source_span.text(c.files[member.file].source)) });
            },
            else => if (!d.partial) try out.append(a, .{ .section = try std.fmt.allocPrint(a, "{s} {s}", .{ words, d.name }), .key = d.name }),
        }
    }
    return out.toOwnedSlice(a);
}

/// The repository's files, read once each.
const Files = struct {
    a: std.mem.Allocator,
    io: std.Io,
    cache: std.StringHashMapUnmanaged(?[]const u8) = .empty,

    fn read(self: *Files, path: []const u8) !?[]const u8 {
        if (self.cache.get(path)) |hit| return hit;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(max_file)) catch |err| switch (err) {
            error.FileNotFound, error.NotDir, error.IsDir => null,
            else => return err,
        };
        try self.cache.put(self.a, try self.a.dupe(u8, path), bytes);
        return bytes;
    }
};

/// Whether `source` declares `name` public: a value, a type, or a
/// constructor of a public, non-opaque type.
fn declares(source: []const u8, name: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var in_type = false;
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] != ' ') in_type = false;
        if (std.mem.startsWith(u8, line, "pub ")) {
            var rest = line[4..];
            for ([_][]const u8{ "foreign pure ", "foreign impure ", "foreign suspends ", "foreign " }) |p| {
                if (std.mem.startsWith(u8, rest, p)) rest = rest[p.len..];
            }
            const is_type = std.mem.startsWith(u8, rest, "type ") or std.mem.startsWith(u8, rest, "opaque type ");
            if (std.mem.startsWith(u8, rest, "type ") and !std.mem.startsWith(u8, rest, "type alias ")) in_type = true;
            for ([_][]const u8{ "type alias ", "opaque type ", "type " }) |p| {
                if (std.mem.startsWith(u8, rest, p)) {
                    rest = rest[p.len..];
                    break;
                }
            }
            if (std.mem.startsWith(u8, rest, name) and (rest.len == name.len or rest[name.len] == ' ')) {
                if (is_type or std.mem.startsWith(u8, rest[name.len..], " :")) return true;
            }
            continue;
        }
        if (in_type) {
            const t = std.mem.trimStart(u8, line, " ");
            if (t.len > 2 and (t[0] == '=' or t[0] == '|') and t[1] == ' ') {
                const ctor = t[2..];
                if (std.mem.startsWith(u8, ctor, name) and (ctor.len == name.len or ctor[name.len] == ' ')) return true;
            }
        }
    }
    return false;
}

/// The constructors of the public type `name` declared in `source`.
fn constructors(a: std.mem.Allocator, source: []const u8, name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var in_type = false;
    while (lines.next()) |line| {
        if (line.len > 0 and line[0] != ' ') {
            in_type = false;
            if (std.mem.startsWith(u8, line, "pub type ")) {
                const rest = line["pub type ".len..];
                in_type = std.mem.startsWith(u8, rest, name) and (rest.len == name.len or rest[name.len] == ' ');
            }
            continue;
        }
        if (!in_type) continue;
        const t = std.mem.trimStart(u8, line, " ");
        if (t.len > 2 and (t[0] == '=' or t[0] == '|') and t[1] == ' ') {
            const ctor = t[2..];
            const end = std.mem.findAny(u8, ctor, " \r") orelse ctor.len;
            try out.append(a, ctor[0..end]);
        }
    }
    return out.toOwnedSlice(a);
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether `source` names `reference.word` as a whole word.
fn names(source: []const u8, reference: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.findPos(u8, source, from, reference)) |at| {
        from = at + 1;
        if (at > 0 and (isIdent(source[at - 1]) or source[at - 1] == '.')) continue;
        const dot = at + reference.len;
        if (dot >= source.len or source[dot] != '.') continue;
        const rest = source[dot + 1 ..];
        if (!std.mem.startsWith(u8, rest, word)) continue;
        if (rest.len > word.len and isIdent(rest[word.len])) continue;
        return true;
    }
    return false;
}

/// A beni source as the mention check reads it: its code with every
/// comment (`--` and nested `{- -}`), string literal and character literal
/// blanked, and its import lines kept apart, so neither a comment, a
/// string nor an import is a use.
pub const Source = struct { code: []const u8, imports: []const []const u8 };

pub fn readSource(a: std.mem.Allocator, bytes: []const u8) !Source {
    var code: std.ArrayList(u8) = try .initCapacity(a, bytes.len);
    var i: usize = 0;
    var depth: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        if (depth > 0) {
            if (std.mem.startsWith(u8, bytes[i..], "{-")) {
                depth += 1;
                i += 2;
            } else if (std.mem.startsWith(u8, bytes[i..], "-}")) {
                depth -= 1;
                i += 2;
            } else {
                if (c == '\n') try code.append(a, '\n');
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, bytes[i..], "{-")) {
            depth = 1;
            i += 2;
        } else if (std.mem.startsWith(u8, bytes[i..], "--")) {
            while (i < bytes.len and bytes[i] != '\n') i += 1;
        } else if (std.mem.startsWith(u8, bytes[i..], "\"\"\"")) {
            i += 3;
            while (i < bytes.len and !std.mem.startsWith(u8, bytes[i..], "\"\"\"")) : (i += 1) {
                if (bytes[i] == '\n') try code.append(a, '\n');
            }
            i = @min(i + 3, bytes.len);
            try code.appendSlice(a, "\"\"");
        } else if (c == '"' or c == '\'') {
            i += 1;
            while (i < bytes.len and bytes[i] != c and bytes[i] != '\n') : (i += 1) {
                if (bytes[i] == '\\') i += 1;
            }
            i += 1;
            try code.appendSlice(a, "\"\"");
        } else {
            try code.append(a, c);
            i += 1;
        }
    }
    // Import lines apart from the code.
    var kept: std.ArrayList(u8) = .empty;
    var imports: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, code.items, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "import ")) {
            try imports.append(a, line);
            try kept.append(a, '\n');
        } else {
            try kept.appendSlice(a, line);
            try kept.append(a, '\n');
        }
    }
    return .{ .code = try kept.toOwnedSlice(a), .imports = try imports.toOwnedSlice(a) };
}

/// Whether `code` holds `word` as a whole, unqualified word.
fn bare(code: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.findPos(u8, code, from, word)) |at| {
        from = at + 1;
        if (at > 0 and (isIdent(code[at - 1]) or code[at - 1] == '.')) continue;
        const end = at + word.len;
        if (end < code.len and isIdent(code[end])) continue;
        return true;
    }
    return false;
}

/// Whether `source` uses the declaration `module.name` in its code: through
/// the module's full name or an alias it is imported as, or unqualified
/// when an import exposes it; a type also through its record constructor
/// (`lowerFirst`), its spelling conversions and its constructors.
pub fn mentions(a: std.mem.Allocator, source: Source, module: []const u8, name: []const u8, ctors: []const []const u8) !bool {
    var refs: std.ArrayList([]const u8) = .empty;
    try refs.append(a, module);
    var exposed = false;
    const prefix = try std.fmt.allocPrint(a, "import {s}", .{module});
    for (source.imports) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        if (rest.len > 0 and rest[0] != ' ') continue;
        if (std.mem.find(u8, rest, " as ")) |at| {
            const alias_start = at + 4;
            const alias_end = std.mem.findAnyPos(u8, rest, alias_start, " \r") orelse rest.len;
            try refs.append(a, rest[alias_start..alias_end]);
        }
        if (std.mem.find(u8, rest, "exposing (")) |at| {
            const list = rest[at + "exposing (".len .. std.mem.findScalarPos(u8, rest, at, ')') orelse rest.len];
            var items = std.mem.splitScalar(u8, list, ',');
            while (items.next()) |item| exposed = exposed or std.mem.eql(u8, trim(item), name);
        }
    }
    // An exposed name counts only where the code uses it.
    if (exposed and bare(source.code, name)) return true;
    var words: std.ArrayList([]const u8) = .empty;
    try words.append(a, name);
    if (std.ascii.isUpper(name[0])) {
        const lower = try a.dupe(u8, name);
        lower[0] = std.ascii.toLower(lower[0]);
        try words.append(a, lower);
        try words.append(a, try std.fmt.allocPrint(a, "{s}ToString", .{lower}));
        try words.append(a, try std.fmt.allocPrint(a, "{s}FromString", .{lower}));
        try words.appendSlice(a, ctors);
    }
    for (refs.items) |r| for (words.items) |w| if (names(source.code, r, w)) return true;
    return false;
}

/// A fixture: its own sources, those of the test-platform modules it
/// imports, and the text of its goldens.
pub const Fixture = struct { own: []const Source, platform: []const Source, golden: []const u8 };

/// Whether the fixture uses `module.name`: its own code does, or — for a
/// type or constructor — a test-platform module it imports names it AND
/// its golden shows the name or one of its constructors, so the page
/// really produced the value.
pub fn uses(a: std.mem.Allocator, f: Fixture, module: []const u8, name: []const u8, ctors: []const []const u8) !bool {
    for (f.own) |s| if (try mentions(a, s, module, name, ctors)) return true;
    if (!std.ascii.isUpper(name[0])) return false;
    var shown = bare(f.golden, name);
    for (ctors) |ctor| shown = shown or bare(f.golden, ctor);
    if (!shown) return false;
    for (f.platform) |s| if (try mentions(a, s, module, name, ctors)) return true;
    return false;
}

/// A fixture's sources, the test-platform modules it imports and its
/// goldens; null when it is not a fixture.
fn fixture(a: std.mem.Allocator, files: *Files, path: []const u8) !?Fixture {
    const dir_path = try std.fmt.allocPrint(a, "tests/corpus/{s}", .{path});
    const expected = try std.fmt.allocPrint(a, "{s}/_expected.expected", .{dir_path});
    if (try files.read(expected) == null) return null;
    var dir = std.Io.Dir.cwd().openDir(files.io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(files.io);
    var own: std.ArrayList(Source) = .empty;
    var platform: std.ArrayList(Source) = .empty;
    var golden: std.ArrayList(u8) = .empty;
    var it = dir.iterate();
    var names_found: std.ArrayList([]const u8) = .empty;
    while (try it.next(files.io)) |entry| try names_found.append(a, try a.dupe(u8, entry.name));
    std.mem.sort([]const u8, names_found.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (names_found.items) |entry| {
        const file_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, entry });
        if (std.mem.startsWith(u8, entry, "_expected.") and !std.mem.endsWith(u8, entry, ".steps")) {
            try golden.appendSlice(a, (try files.read(file_path)) orelse "");
            continue;
        }
        if (!std.mem.endsWith(u8, entry, ".beni")) continue;
        const source = try readSource(a, (try files.read(file_path)).?);
        try own.append(a, source);
        for (source.imports) |line| {
            const rest = line["import ".len..];
            const end = std.mem.findAny(u8, rest, " \r") orelse rest.len;
            const module = rest[0..end];
            if (std.mem.findScalar(u8, module, '.') != null) continue;
            const lib = try std.fmt.allocPrint(a, "{s}/{s}.beni", .{ test_platform_dir, module });
            if (try files.read(lib)) |lib_bytes| try platform.append(a, try readSource(a, lib_bytes));
        }
    }
    if (own.items.len == 0) return null;
    return .{ .own = try own.toOwnedSlice(a), .platform = try platform.toOwnedSlice(a), .golden = try golden.toOwnedSlice(a) };
}

/// IDL text with its comments and every space and `;` removed.
fn squeezed(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const end = std.mem.find(u8, line, "//") orelse line.len;
        for (line[0..end]) |c| if (!std.ascii.isWhitespace(c) and c != ';') try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

/// The quoted values of an enum, in order.
fn enumValues(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |whole| {
        var line = whole[0 .. std.mem.find(u8, whole, "//") orelse whole.len];
        while (std.mem.findScalar(u8, line, '"')) |open| {
            const close = std.mem.findScalarPos(u8, line, open + 1, '"') orelse break;
            try out.appendSlice(a, line[open .. close + 1]);
            try out.append(a, ' ');
            line = line[close + 1 ..];
        }
    }
    return out.toOwnedSlice(a);
}

const IdlSection = struct { heading: []const u8, parent: []const u8, block: ?[]const u8, values: ?[]const u8, line: usize };

/// The IDL text of coverage.md, which research/webgpu/inventory.py once
/// generated and this check now holds to the pin: each section in IDL
/// order with its heading and parent, every member's text, every enum's
/// values, and the counts line.
fn checkIdl(a: std.mem.Allocator, c: Native.Catalogue, text: []const u8, quiet: bool) !usize {
    var count: usize = 0;
    var sections: std.ArrayList(IdlSection) = .empty;
    var counts_line: ?[]const u8 = null;
    var in_block = false;
    var block: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (std.mem.startsWith(u8, line, "Counts: ")) counts_line = line;
        if (in_block) {
            if (std.mem.startsWith(u8, line, "```")) {
                in_block = false;
                sections.items[sections.items.len - 1].block = try a.dupe(u8, block.items);
            } else {
                try block.appendSlice(a, line);
                try block.append(a, '\n');
            }
            continue;
        }
        if (std.mem.startsWith(u8, line, "## ") and std.mem.findScalar(u8, line, '`') != null) {
            const open = std.mem.findScalar(u8, line, '`').?;
            const close = std.mem.findScalarPos(u8, line, open + 1, '`') orelse continue;
            var parent: []const u8 = "";
            if (std.mem.find(u8, line[close..], "`: ")) |at| {
                const from = close + at + 3;
                parent = line[from .. std.mem.findScalarPos(u8, line, from, '`') orelse line.len];
            }
            try sections.append(a, .{ .heading = try std.fmt.allocPrint(a, "{s} {s}", .{ trim(line[3..open]), line[open + 1 .. close] }), .parent = parent, .block = null, .values = null, .line = number });
            continue;
        }
        if (sections.items.len == 0) continue;
        if (std.mem.startsWith(u8, line, "```webidl")) {
            in_block = true;
            block.clearRetainingCapacity();
        } else if (std.mem.startsWith(u8, line, "`\"")) {
            sections.items[sections.items.len - 1].values = try enumValues(a, line);
        }
    }
    var kinds = [_]struct { word: []const u8, n: usize }{
        .{ .word = "dictionary", .n = 0 },        .{ .word = "enum", .n = 0 },            .{ .word = "includes", .n = 0 },
        .{ .word = "interface", .n = 0 },         .{ .word = "interface mixin", .n = 0 }, .{ .word = "namespace", .n = 0 },
        .{ .word = "partial interface", .n = 0 }, .{ .word = "typedef", .n = 0 },
    };
    var at: usize = 0;
    for (c.declarations) |d| {
        if (!std.mem.eql(u8, c.files[d.file].path, Gpu.idl_file)) continue;
        const words = kindWords(d);
        for (&kinds) |*k| if (std.mem.eql(u8, k.word, words)) {
            k.n += 1;
        };
        const heading = if (d.kind == .includes)
            try std.fmt.allocPrint(a, "includes {s} includes {s};", .{ d.name, d.parent.? })
        else
            try std.fmt.allocPrint(a, "{s} {s}", .{ words, d.name });
        if (at >= sections.items.len or !std.mem.eql(u8, sections.items[at].heading, heading)) {
            count += 1;
            if (!quiet) std.debug.print("coverage.md: the IDL's next declaration is `{s}`, the file's is `{s}`\n", .{ heading, if (at < sections.items.len) sections.items[at].heading else "(none)" });
            return count;
        }
        const s = sections.items[at];
        at += 1;
        const parent = if (d.kind != .includes and d.parent != null) d.parent.? else "";
        if (!std.mem.eql(u8, s.parent, parent)) {
            count += 1;
            if (!quiet) std.debug.print("coverage.md:{d}: {s}: parent `{s}`, the IDL's `{s}`\n", .{ s.line, heading, s.parent, parent });
        }
        const source = c.files[d.file].source;
        switch (d.kind) {
            .enumeration => {
                const want = try enumValues(a, d.source_span.text(source));
                if (s.values == null or !std.mem.eql(u8, s.values.?, want)) {
                    count += 1;
                    if (!quiet) std.debug.print("coverage.md:{d}: {s}: its values are not the IDL's\n", .{ s.line, heading });
                }
            },
            .includes => if (s.block != null) {
                count += 1;
                if (!quiet) std.debug.print("coverage.md:{d}: {s}: an includes has no IDL block\n", .{ s.line, heading });
            },
            else => {
                var want: std.ArrayList(u8) = .empty;
                if (d.kind == .typedef) {
                    try want.appendSlice(a, try squeezed(a, d.source_span.text(source)));
                } else for (c.members[d.members_start..d.members_end]) |m| {
                    try want.appendSlice(a, try squeezed(a, m.source_span.text(c.files[m.file].source)));
                }
                const have = if (s.block) |b| try squeezed(a, b) else "";
                if (!std.mem.eql(u8, have, want.items)) {
                    count += 1;
                    if (!quiet) std.debug.print("coverage.md:{d}: {s}: its IDL block is not the IDL's members\n", .{ s.line, heading });
                }
            },
        }
    }
    if (at != sections.items.len) {
        count += 1;
        if (!quiet) std.debug.print("coverage.md: {d} sections, the IDL has {d} declarations\n", .{ sections.items.len, at });
    }
    var want_counts: std.ArrayList(u8) = .empty;
    try want_counts.appendSlice(a, "Counts: ");
    for (kinds, 0..) |k, i| {
        if (i > 0) try want_counts.appendSlice(a, ", ");
        try want_counts.print(a, "{d} {s}", .{ k.n, k.word });
    }
    try want_counts.append(a, '.');
    if (counts_line == null or !std.mem.eql(u8, trim(counts_line.?), want_counts.items)) {
        count += 1;
        if (!quiet) std.debug.print("coverage.md: the counts line is not `{s}`\n", .{want_counts.items});
    }
    return count;
}

/// The `browser/gpu/` fixtures that use `module.name`, printed to help
/// rebind a row.
fn suggest(a: std.mem.Allocator, files: *Files, module: []const u8, name: []const u8, ctors: []const []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(files.io, "tests/corpus/browser/gpu", .{ .iterate = true });
    defer dir.close(files.io);
    var it = dir.iterate();
    var found: std.ArrayList(u8) = .empty;
    while (try it.next(files.io)) |entry| {
        const path = try std.fmt.allocPrint(a, "browser/gpu/{s}", .{entry.name});
        const f = (try fixture(a, files, path)) orelse continue;
        if (try uses(a, f, module, name, ctors)) try found.print(a, " {s}", .{entry.name});
    }
    std.debug.print("    fixtures that use it:{s}\n", .{if (found.items.len == 0) " none" else found.items});
}

fn problem(quiet: bool, count: *usize, row: anytype, comptime what: []const u8, args: anytype) void {
    count.* += 1;
    if (quiet) return;
    if (row.line == 0)
        std.debug.print("coverage.md: {s} `{s}`: " ++ what ++ "\n", .{ row.section, row.key } ++ args)
    else
        std.debug.print("coverage.md:{d}: {s} `{s}`: " ++ what ++ "\n", .{ row.line, row.section, row.key } ++ args);
}

/// Check `text`, a coverage table, against the IDL and the repository;
/// the number of problems, each printed unless `quiet`.
pub fn check(a: std.mem.Allocator, io: std.Io, c: Native.Catalogue, text: []const u8, quiet: bool) !usize {
    var count: usize = try checkIdl(a, c, text, quiet);
    const coverage = try parse(a, text);
    var files: Files = .{ .a = a, .io = io };
    const manifest = (try files.read(public_manifest)) orelse return error.NoManifest;

    // Every required row, once; no row the IDL does not require.
    const needed = try required(a, c);
    for (needed) |r| {
        var found: usize = 0;
        for (coverage.rows) |*row| {
            if (std.mem.eql(u8, row.section, r.section) and std.mem.eql(u8, row.key, r.key)) {
                found += 1;
                row.used = true;
            }
        }
        if (found == 0) problem(quiet, &count, .{ .line = @as(usize, 0), .section = r.section, .key = r.key }, "the IDL has it and no row binds it", .{});
        if (found > 1) problem(quiet, &count, .{ .line = @as(usize, 0), .section = r.section, .key = r.key }, "it has {d} rows", .{found});
    }
    for (coverage.rows) |row| {
        if (!row.used) problem(quiet, &count, row, "no such member of the IDL", .{});
    }

    for (coverage.rows) |row| {
        if (std.mem.startsWith(u8, row.declarations, "later")) {
            const hash = std.mem.findScalar(u8, row.declarations, '#') orelse {
                problem(quiet, &count, row, "a later slice names no issue", .{});
                continue;
            };
            const end = std.mem.findNonePos(u8, row.declarations, hash + 1, "0123456789") orelse row.declarations.len;
            const issue = std.fmt.parseInt(u32, row.declarations[hash + 1 .. end], 10) catch 0;
            if (std.mem.findScalar(u32, coverage.later, issue) == null) problem(quiet, &count, row, "#{d} is not a later slice of the table", .{issue});
            if (!std.mem.eql(u8, row.fixtures, "—")) problem(quiet, &count, row, "a later row has fixtures", .{});
            continue;
        }
        // The declarations.
        var declarations: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitSequence(u8, row.declarations, ", ");
        while (it.next()) |cell| {
            const name = unquote(cell);
            if (name.len > 0) try declarations.append(a, name);
        }
        if (declarations.items.len == 0) {
            problem(quiet, &count, row, "no declaration and no later slice", .{});
            continue;
        }
        // The fixtures.
        var fixtures: std.ArrayList(Fixture) = .empty;
        var fx = std.mem.splitSequence(u8, row.fixtures, ", ");
        var named: usize = 0;
        while (fx.next()) |cell| {
            const path = unquote(cell);
            if (path.len == 0 or std.mem.eql(u8, path, "—")) continue;
            named += 1;
            if (try fixture(a, &files, path)) |f| try fixtures.append(a, f) else problem(quiet, &count, row, "no fixture tests/corpus/{s} (with `_expected.expected`)", .{path});
        }
        if (named == 0) problem(quiet, &count, row, "no fixture", .{});
        for (declarations.items) |declaration| {
            const dot = std.mem.findScalarLast(u8, declaration, '.') orelse {
                problem(quiet, &count, row, "`{s}` is not Module.name", .{declaration});
                continue;
            };
            const module = declaration[0..dot];
            const name = declaration[dot + 1 ..];
            const quoted = try std.fmt.allocPrint(a, "\"{s}\"", .{module});
            if (!std.mem.startsWith(u8, module, "Gpu") or std.mem.find(u8, manifest, quoted) == null) {
                problem(quiet, &count, row, "`{s}` is not a public module (browser-tea re-exports it not)", .{module});
                continue;
            }
            const relative = try a.dupe(u8, module);
            std.mem.replaceScalar(u8, relative, '.', '/');
            const file_path = try std.fmt.allocPrint(a, "platforms/browser-base/{s}.beni", .{relative});
            const source = (try files.read(file_path)) orelse {
                problem(quiet, &count, row, "no file {s}", .{file_path});
                continue;
            };
            if (!declares(source, name)) {
                problem(quiet, &count, row, "{s} declares no public `{s}`", .{ module, name });
                continue;
            }
            const ctors = if (std.ascii.isUpper(name[0])) try constructors(a, source, name) else &.{};
            var seen = false;
            for (fixtures.items) |f| seen = seen or try uses(a, f, module, name, ctors);
            if (!seen and fixtures.items.len > 0) {
                problem(quiet, &count, row, "no fixture of the row uses `{s}`", .{declaration});
                if (!quiet) try suggest(a, &files, module, name, ctors);
            }
        }
    }
    return count;
}

fn catalogue(a: std.mem.Allocator) !Native.Catalogue {
    return (try Native.generate(a, @embedFile("webref_idl"))).success;
}

test "every row of the WebGPU coverage table is bound, or waits for a later slice" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, coverage_path, a, .limited(max_file));
    try std.testing.expectEqual(@as(usize, 0), try check(a, std.testing.io, try catalogue(a), text, false));
}

fn replaced(a: std.mem.Allocator, text: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    const at = std.mem.find(u8, text, old) orelse return error.MutationNotFound;
    return std.mem.concat(a, u8, &.{ text[0..at], new, text[at + old.len ..] });
}

test "the coverage gate fails on a broken row" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try catalogue(a);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, coverage_path, a, .limited(max_file));
    const row = "| `usage` | `Gpu.Buffer.usage` | `browser/gpu/CoverageAttributes` |\n";
    const cases = [_][]const u8{
        // The row is gone: the IDL member is unbound.
        "",
        // A row with neither declarations nor a later slice.
        "| `usage` |  | `browser/gpu/CoverageAttributes` |\n",
        // A declaration that does not exist.
        "| `usage` | `Gpu.Buffer.usages` | `browser/gpu/CoverageAttributes` |\n",
        // A module that is not public.
        "| `usage` | `Gpu.Memory.usageOf` | `browser/gpu/CoverageAttributes` |\n",
        // A fixture that does not exist.
        "| `usage` | `Gpu.Buffer.usage` | `browser/gpu/NoSuchFixture` |\n",
        // A fixture that never names the declaration.
        "| `usage` | `Gpu.Buffer.usage` | `browser/gpu/Availability` |\n",
        // No fixture.
        "| `usage` | `Gpu.Buffer.usage` |  |\n",
        // A later slice the table does not list.
        "| `usage` | later #9999 | — |\n",
        // A member the IDL does not have.
        row ++ "| `usages` | `Gpu.Buffer.usage` | `browser/gpu/CoverageAttributes` |\n",
        // Two rows of one member.
        row ++ row,
    };
    for (cases) |new| {
        const broken = try replaced(a, text, row, new);
        try std.testing.expect(try check(a, std.testing.io, c, broken, true) > 0);
    }
    // A later slice the table lists is a binding.
    const later = try replaced(a, text, row, "| `usage` | later #1299 | — |\n");
    try std.testing.expectEqual(@as(usize, 0), try check(a, std.testing.io, c, later, true));
    // And the committed table passes.
    try std.testing.expectEqual(@as(usize, 0), try check(a, std.testing.io, c, text, true));
}

test "member keys name each overload by its parameters" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("label", try memberKey(a, "attribute USVString label;"));
    try std.testing.expectEqualStrings("features", try memberKey(a, "[SameObject] readonly attribute GPUSupportedFeatures features;"));
    try std.testing.expectEqualStrings("setlike", try memberKey(a, "readonly setlike<DOMString>;"));
    try std.testing.expectEqualStrings("textureBindingViewDimension", try memberKey(a, "readonly attribute (GPUTextureViewDimension or undefined) textureBindingViewDimension;"));
    try std.testing.expectEqualStrings("mapAsync(mode, offset, size)", try memberKey(a, "Promise<undefined> mapAsync(GPUMapModeFlags mode, optional GPUSize64 offset = 0, optional GPUSize64 size);"));
    try std.testing.expectEqualStrings("setBindGroup(index, bindGroup, dynamicOffsets)", try memberKey(a, "undefined setBindGroup(GPUIndex32 index, GPUBindGroup? bindGroup,\n optional sequence<GPUBufferDynamicOffset> dynamicOffsets = []);"));
    try std.testing.expectEqualStrings("constructor(message, options)", try memberKey(a, "constructor(optional DOMString message = \"\", GPUPipelineErrorInit options);"));
    try std.testing.expectEqualStrings("popDebugGroup()", try memberKey(a, "undefined popDebugGroup();"));
}

test "a constant is keyed by its name" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("MAP_READ", try memberKey(arena.allocator(), "const GPUFlagsConstant MAP_READ = 0x0001;"));
}

test "the coverage gate fails when the IDL text drifts from the pin" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try catalogue(a);
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, coverage_path, a, .limited(max_file));
    const cases = [_][2][]const u8{
        // An enum value.
        .{ "`\"r8snorm\"`", "`\"r8snorn\"`" },
        // A member's signature.
        .{ "Promise<undefined> mapAsync(GPUMapModeFlags mode,", "Promise<undefined> mapAsync(GPUMapModeFlags modes," },
        // A default.
        .{ "GPUTextureUsageFlags usage = 0x10;", "GPUTextureUsageFlags usage = 0x11;" },
        // The counts.
        .{ "Counts: 62 dictionary", "Counts: 61 dictionary" },
        // A parent.
        .{ "## interface `GPUDevice` `: EventTarget`", "## interface `GPUDevice`" },
    };
    for (cases) |case| {
        const broken = try replaced(a, text, case[0], case[1]);
        try std.testing.expect(try check(a, std.testing.io, c, broken, true) > 0);
    }
}

fn fixtureOf(a: std.mem.Allocator, source: []const u8, golden: []const u8) !Fixture {
    const sources = try a.alloc(Source, 1);
    sources[0] = try readSource(a, source);
    return .{ .own = sources, .platform = &.{}, .golden = golden };
}

test "an import, a comment or a string is not a use" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cheats = [_][]const u8{
        // Exposed and never called.
        "import Gpu.Buffer exposing (usage, size)\nmain = 1\n",
        // In a block comment, nested or not.
        "{- Gpu.Buffer.usage -}\nmain = 1\n",
        "{- outer {- inner -} Gpu.Buffer.usage -}\nmain = 1\n",
        // In a line comment.
        "main = 1 -- Gpu.Buffer.usage\n",
        // In a string literal, and a multi-line one.
        "main = \"Gpu.Buffer.usage\"\n",
        "main = \"\"\"\nGpu.Buffer.usage\n\"\"\"\n",
        // An import line alone.
        "import Gpu.Buffer as Gpu.Buffer.usage\nmain = 1\n",
    };
    for (cheats) |source| try std.testing.expect(!try uses(a, try fixtureOf(a, source, ""), "Gpu.Buffer", "usage", &.{}));
    const real = [_][]const u8{
        "main = Gpu.Buffer.usage b\n",
        "import Gpu.Buffer as B\nmain = B.usage b\n",
        "import Gpu.Buffer exposing (usage)\nmain = usage b\n",
        "main = \"a {- string\" ++ Gpu.Buffer.usage b\n",
    };
    for (real) |source| try std.testing.expect(try uses(a, try fixtureOf(a, source, ""), "Gpu.Buffer", "usage", &.{}));
    // A constructor a test-platform module names counts only when the
    // golden shows it.
    const platform = try a.alloc(Source, 1);
    platform[0] = try readSource(a, "show e = case e of\n    Error.OutOfMemoryError _ -> \"OutOfMemoryError\"\n");
    const page = try readSource(a, "import GpuShow\nmain = 1\n");
    const own = try a.alloc(Source, 1);
    own[0] = page;
    const ctors = [_][]const u8{};
    try std.testing.expect(!try uses(a, .{ .own = own, .platform = platform, .golden = "<li>\"Ok none\"</li>" }, "Error", "OutOfMemoryError", &ctors));
    try std.testing.expect(try uses(a, .{ .own = own, .platform = platform, .golden = "<li>\"Ok OutOfMemoryError\"</li>" }, "Error", "OutOfMemoryError", &ctors));
}
