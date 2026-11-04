//! Where a development build's `_core/Schema.mjs` reads schema
//! descriptions (`schema.md` §16 and A.14, issue #1818).
//!
//! A description node is `Node (Js.Ref NodeBody)`, and a read of one is a
//! call of `Schema$nodeBody` or a test of a `NodeBody` tag (`x.$ === "NList"`,
//! `case "NPrim":`). The tags are the ones the module builds description
//! nodes with (`Schema$nodeRef({ $: "N…"`), so the vocabulary comes from the
//! output, not from a list here. The markers must match the module, or the
//! check would see nothing (`Report.missing`): a module that declares the
//! builder or the accessor but builds no node in the form above has a
//! printing this check no longer knows, and one that references
//! `Schema$nodeBody` without declaring it has an accessor this check cannot locate.
//! An unused accessor may be eliminated while builders remain; direct tag tests
//! still count as reads even without the accessor.
//! A module that declares neither builds and reads no description node:
//! reachability dropped both, as it does when every schema of a program is
//! a declaration. That `nodeBody` and `nodeRef` are the one function of
//! `core/Schema.beni` that takes a `Node` apart and the one that builds it
//! is pinned against the source by a separate build test.
//!
//! Two kinds of code may read a description. Inspection: `describe`, and
//! every declaration it reaches, which walk the graph and run no
//! conversion. Construction: the makers `variant` and `tagged`, which check
//! a schema once when it is made, themselves or through the named helpers
//! `construction_helpers`. A run — parse, print, read, write and the
//! workers they call, `taggedRead` and the rest — never does: it calls
//! compiled workers.
//!
//! The check is a reference graph over the module's top-level declarations,
//! each from its line at column 0 to the next. A declaration *reads
//! descriptions* when its text has a read, or names a declaration that
//! reads descriptions. Every declaration that reads descriptions must be
//! inspection or construction as above; and those named from outside that
//! set — by the module's `export` list, so another module may call them —
//! must be `describe` or a maker. A runner that walks a description, calls
//! `describe`, or calls a helper that reads one is named with its chain, and
//! so is a worker that reads one, though only a maker reaches it. A closure
//! written inside a maker's own declaration is the maker's text, and the
//! graph cannot tell its run from the maker's check; the makers' run-time
//! workers are their own declarations, so that is only code written into
//! `variant` or `tagged` themselves. Development names are stable
//! (`Schema$<name>`); release short names are never read.

const std = @import("std");

/// The declarations whose reads are inspection: these, and every
/// declaration they reach.
pub const inspection = [_][]const u8{"Schema$describe"};

/// The makers, whose reads check a schema when it is made.
pub const makers = [_][]const u8{ "Schema$variant", "Schema$tagged" };

/// The helpers a maker's check calls, which may read for it.
pub const construction_helpers = [_][]const u8{ "Schema$taggedNode", "Schema$variantClashes" };

const Decl = struct {
    name: []const u8,
    text: []const u8,
};

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// The top-level declarations of `text`: a line at column 0 that begins
/// `const`, `let`, `var`, `function`, `async function` or `class` starts
/// one, and it runs to the next. Other lines at column 0 — imports, the
/// `export` list, comments — end it and belong to no declaration.
fn declarations(arena: std.mem.Allocator, text: []const u8, outside: *std.ArrayList(u8)) ![]Decl {
    var decls: std.ArrayList(Decl) = .empty;
    var current: ?usize = null;
    var start: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var at: usize = 0;
    while (lines.next()) |line| : (at += line.len + 1) {
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '}' or line[0] == ')' or line[0] == ']') continue;
        if (current) |i| decls.items[i].text = text[start..at];
        current = null;
        const keywords = [_][]const u8{ "const ", "let ", "var ", "function ", "async function ", "class " };
        for (keywords) |kw| {
            if (!std.mem.startsWith(u8, line, kw)) continue;
            var e: usize = kw.len;
            while (e < line.len and isIdent(line[e])) e += 1;
            if (e == kw.len) break;
            try decls.append(arena, .{ .name = line[kw.len..e], .text = "" });
            current = decls.items.len - 1;
            start = at;
            break;
        } else {
            try outside.appendSlice(arena, line);
            try outside.append(arena, '\n');
        }
    }
    if (current) |i| decls.items[i].text = text[start..];
    return decls.items;
}

/// Whether `text` names `name` as a whole identifier.
fn names(text: []const u8, name: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, name)) |i| {
        from = i + 1;
        if (i > 0 and isIdent(text[i - 1])) continue;
        const end = i + name.len;
        if (end < text.len and isIdent(text[end])) continue;
        return true;
    }
    return false;
}

/// The `NodeBody` tags the module builds description nodes with.
fn vocabulary(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var tags: std.ArrayList([]const u8) = .empty;
    const opener = "Schema$nodeRef({ $: \"";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, opener)) |i| {
        const s = i + opener.len;
        const e = std.mem.indexOfScalarPos(u8, text, s, '"') orelse break;
        from = e;
        const tag = text[s..e];
        for (tags.items) |t| {
            if (std.mem.eql(u8, t, tag)) break;
        } else try tags.append(arena, tag);
    }
    return tags.items;
}

/// Whether `text` reads a description directly: calls `Schema$nodeBody`,
/// or tests one of `tags` (`=== "T"`, `!== "T"`, `case "T":`).
fn readsDirectly(arena: std.mem.Allocator, text: []const u8, tags: []const []const u8) !bool {
    return names(text, "Schema$nodeBody") or try testsTag(arena, text, tags);
}

/// Whether `text` tests one of `tags`.
fn testsTag(arena: std.mem.Allocator, text: []const u8, tags: []const []const u8) !bool {
    for (tags) |t| {
        const forms = [_][]const u8{ "=== \"{s}\"", "!== \"{s}\"", "case \"{s}\":", "\"{s}\" ===", "\"{s}\" !==" };
        inline for (forms) |f| {
            if (std.mem.indexOf(u8, text, try std.fmt.allocPrint(arena, f, .{t})) != null) return true;
        }
    }
    return false;
}

pub const Entry = struct {
    /// The declaration that may not read descriptions.
    name: []const u8,
    /// A chain of declarations from it to one that reads directly.
    path: []const []const u8,
};

pub const Report = struct {
    /// A dangling accessor reference, or a surviving builder/accessor with
    /// no recognized description tags. Null when the markers agree.
    missing: ?[]const u8,
    /// Each declaration that reads descriptions and may not.
    forbidden: []const Entry,
};

fn listed(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Where `text` reads descriptions, against the module's doc comment.
pub fn check(arena: std.mem.Allocator, text: []const u8) !Report {
    var outside: std.ArrayList(u8) = .empty;
    const decls = try declarations(arena, text, &outside);
    const tags = try vocabulary(arena, text);
    var accessor = false;
    var builder = false;
    for (decls) |d| {
        accessor = accessor or std.mem.eql(u8, d.name, "Schema$nodeBody");
        builder = builder or std.mem.eql(u8, d.name, "Schema$nodeRef");
    }
    const missing: ?[]const u8 = if ((builder or accessor) and tags.len == 0)
        "Schema$nodeRef or Schema$nodeBody but no node built as Schema$nodeRef({ $: \"…\""
    else if (!accessor and names(text, "Schema$nodeBody"))
        "a reference to Schema$nodeBody without its declaration"
    else
        null;
    // `reads[i]`: the declaration through which `i` reads, or itself.
    const reads = try arena.alloc(?usize, decls.len);
    for (decls, reads, 0..) |d, *r, i| {
        // nodeBody's own declaration is the accessor, not a read.
        r.* = if (!std.mem.eql(u8, d.name, "Schema$nodeBody") and try readsDirectly(arena, d.text, tags)) i else null;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (decls, reads) |d, *r| {
            if (r.* != null) continue;
            for (decls, 0..) |callee, j| {
                if (reads[j] == null or std.mem.eql(u8, callee.name, d.name)) continue;
                if (!names(d.text, callee.name)) continue;
                r.* = j;
                changed = true;
                break;
            }
        }
    }
    // Inspection: what `inspection` reaches.
    const inspecting = try arena.alloc(bool, decls.len);
    for (decls, inspecting) |d, *x| x.* = listed(&inspection, d.name);
    changed = true;
    while (changed) {
        changed = false;
        for (decls, inspecting) |d, x| {
            if (!x) continue;
            for (decls, inspecting) |callee, *y| {
                if (y.* or !names(d.text, callee.name)) continue;
                y.* = true;
                changed = true;
            }
        }
    }
    var out: std.ArrayList(Entry) = .empty;
    for (decls, reads, inspecting, 0..) |d, r, insp, i| {
        if (r == null) continue;
        const construction = listed(&makers, d.name) or listed(&construction_helpers, d.name);
        const reader_ok = insp or construction;
        // Named from outside the module: only `describe` and the makers.
        const exported = names(outside.items, d.name);
        const entry_ok = !exported or listed(&inspection, d.name) or listed(&makers, d.name);
        if (reader_ok and entry_ok) continue;
        var path: std.ArrayList([]const u8) = .empty;
        var k = i;
        while (true) {
            try path.append(arena, decls[k].name);
            const next = reads[k].?;
            if (next == k or path.items.len > decls.len) break;
            k = next;
        }
        try out.append(arena, .{ .name = d.name, .path = path.items });
    }
    return .{ .missing = missing, .forbidden = out.items };
}

const sample =
    \\import { Maybe$map } from "../_core/Maybe.mjs";
    \\const Schema$nodeRef = (body$1) => ({ v: body$1 });
    \\const Schema$nodeBody = ($p$1) => {
    \\  return $p$1.v;
    \\};
    \\const Schema$nList = (child$1) => Schema$nodeRef({ $: "NList", a: child$1, b: null });
    \\const Schema$nRecord = (fs$1) => Schema$nodeRef({ $: "NRecord", a: fs$1, b: null });
    \\const Schema$variantClashes = (selected$1) => {
    \\  const $t$1 = Maybe$map(selected$1.payload, Schema$nodeBody);
    \\  return $t$1.$ === "Just";
    \\};
    \\const Schema$taggedNode = (variants$1) => variants$1.some(Schema$variantClashes);
    \\const Schema$taggedRead = (variants$1) => (c$2, v$3) => {
    \\  return variants$1[0].worker(c$2, v$3);
    \\};
    \\const Schema$taggedWorkers = (variants$1) => ({ read: Schema$taggedRead(variants$1) });
    \\const Schema$tagged = (variants$1) => {
    \\  const ok$1 = Schema$taggedNode(variants$1);
    \\  return Schema$compiledBox(ok$1, Schema$taggedWorkers(variants$1));
    \\};
    \\const Schema$shapeOf = (node$1) => {
    \\  const $t$1 = Schema$nodeBody(node$1);
    \\  switch ($t$1.$) {
    \\    case "NList":
    \\      return Schema$shapeOf($t$1.a);
    \\  }
    \\};
    \\const Schema$describe = (schema$1) => ({ root: Schema$shapeOf(schema$1.node) });
    \\const Schema$compiledBox = (x$1, w$2) => w$2;
    \\const Schema$parseWith = (schema$1, opts$2, text$3) => {
    \\  return schema$1.workers.parse(opts$2, text$3);
    \\};
    \\const Schema$parse = (schema$1, text$2) => Schema$parseWith(schema$1, null, text$2);
    \\export { Schema$nList, Schema$nRecord, Schema$tagged, Schema$describe, Schema$parse };
    \\
;

const parse_body = "  return schema$1.workers.parse(opts$2, text$3);";

fn mutant(a: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
    std.debug.assert(std.mem.indexOf(u8, sample, from) != null);
    return std.mem.replaceOwned(u8, a, sample, from, to);
}

test "inspection and construction may read descriptions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try check(arena.allocator(), sample);
    try std.testing.expectEqual(@as(?[]const u8, null), r.missing);
    try std.testing.expectEqual(@as(usize, 0), r.forbidden.len);
}

test "a run routed through a description walk is named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The runner tests a node's tag itself.
    const by_tag = (try check(a, try mutant(a, parse_body, "  if (schema$1.node.v.$ === \"NRecord\") return null;\n" ++ parse_body))).forbidden;
    try std.testing.expectEqual(@as(usize, 2), by_tag.len);
    try std.testing.expectEqualStrings("Schema$parseWith", by_tag[0].name);
    try std.testing.expectEqualStrings("Schema$parse", by_tag[1].name);
    // The runner calls the inspection walk.
    const by_walk = (try check(a, try mutant(a, parse_body, "  Schema$describe(schema$1);\n" ++ parse_body))).forbidden;
    try std.testing.expectEqual(@as(usize, 2), by_walk.len);
    try std.testing.expectEqualStrings("Schema$parse", by_walk[1].name);
    try std.testing.expectEqualStrings("Schema$describe", by_walk[1].path[2]);
}

test "a worker that only a maker reaches may not read a description" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = (try check(a, try mutant(a, "  return variants$1[0].worker(c$2, v$3);", "  Schema$nodeBody(variants$1[0].node);\n  return variants$1[0].worker(c$2, v$3);"))).forbidden;
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("Schema$taggedRead", found[0].name);
    try std.testing.expectEqualStrings("Schema$taggedWorkers", found[1].name);
}

test "a description read under an unlisted maker is named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const renamed = try std.mem.replaceOwned(u8, a, sample, "Schema$tagged =", "Schema$taggedLoose =");
    const found = (try check(a, try std.mem.replaceOwned(u8, a, renamed, "Schema$tagged,", "Schema$taggedLoose,"))).forbidden;
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("Schema$taggedLoose", found[0].name);
}

test "a module without the markers is a failure, not a pass" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const no_accessor = try check(a, try mutant(a, "const Schema$nodeBody = ", "const Schema$bodyOf = "));
    try std.testing.expect(no_accessor.missing != null);
    // DCE may drop an unused accessor while keeping description builders.
    const unread = try std.mem.replaceOwned(u8, a, sample[0..std.mem.indexOf(u8, sample, "const Schema$variantClashes").?], "const Schema$nodeBody = ($p$1) => {\n  return $p$1.v;\n};\n", "");
    const dropped = try check(a, unread);
    try std.testing.expectEqual(@as(?[]const u8, null), dropped.missing);
    try std.testing.expectEqual(@as(usize, 0), dropped.forbidden.len);
    const no_accessor_tag_test = try check(a, try std.mem.replaceOwned(u8, a, unread, "const Schema$nRecord", "const Schema$bad = (n) => n.$ === \"NList\";\nconst Schema$nRecord"));
    try std.testing.expectEqual(@as(?[]const u8, null), no_accessor_tag_test.missing);
    try std.testing.expectEqual(@as(usize, 1), no_accessor_tag_test.forbidden.len);
    try std.testing.expectEqualStrings("Schema$bad", no_accessor_tag_test.forbidden[0].name);
    const no_tags = try check(a, try std.mem.replaceOwned(u8, a, sample, "Schema$nodeRef({ $: ", "Schema$nodeRef({ tag: "));
    try std.testing.expect(no_tags.missing != null);
    // Neither builder nor accessor: no description at all.
    const none = try check(a, "const Schema$parse = (s$1, t$2) => s$1.workers.parse(t$2);\nexport { Schema$parse };\n");
    try std.testing.expectEqual(@as(?[]const u8, null), none.missing);
}
