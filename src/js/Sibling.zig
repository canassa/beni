//! The sibling JavaScript file of a module that declares `foreign` values,
//! and the two checks `boundary.md` §4 makes of it that Elm does not make of
//! its kernel code:
//!
//!  2. **It exports exactly the declared names** — no more, no fewer.
//!  3. **Its references are covered by its own imports** (§7.1).
//!
//! Check 1 — the two-shape type rule — is about the beni annotation and
//! lives in `js/Emit.zig`, next to the `Bir` that holds it.
//!
//! **Why check 3 exists**, because it is the least obvious of the three:
//! Elm's compiler *can* see through its own kernel code — a kernel file is a
//! template parsed into chunks and every variable reference becomes an edge
//! in the same whole-program graph — but every kernel FILE is one graph
//! node, so reaching one function pulls in the whole file and module-granular
//! tree shaking reappears exactly where §9.1 exists to beat it (roughly 45%
//! of Elm's TodoMVC bundle is hand-written runtime). One export per foreign
//! value is one graph node per foreign value; what recovers the dependency
//! half is that we emit ES modules and can simply read the file's own
//! `import` statements. A file that reaches a name from nowhere has an edge
//! the compiler cannot see, and that is the error.
//!
//! **What this scanner is and is not.** It is a lexical pass: it skips
//! comments, string and template literals and regular expressions, then
//! classifies each identifier as a binding, a property, a key or a
//! reference. It is NOT a scope analysis — an identifier bound anywhere in
//! the file counts as bound everywhere, and a reference inside a template
//! substitution is not seen at all. Both approximations are in the
//! permissive direction, deliberately: the failure this check exists to
//! catch is a sibling file reaching a HOST global it never imported
//! (`process`, `require`, `window`), and no amount of local scoping hides
//! one of those. A precise answer needs a JavaScript parser, which is a
//! dependency the wall exists to avoid.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What the scan found. All slices point into the scanned bytes.
pub const Scan = struct {
    /// Names the file exports, in source order, deduplicated.
    exports: []const []const u8,
    /// Identifiers referenced that are neither bound in the file, nor
    /// imported by it, nor a standard global.
    unbound: []const []const u8,
};

/// Scan `source`. Everything returned is owned by `arena`.
pub fn scan(arena: Allocator, source: []const u8) Allocator.Error!Scan {
    var tokens: std.ArrayList(Token) = .empty;
    try tokenize(arena, source, &tokens);

    var exports: std.ArrayList([]const u8) = .empty;
    var bound: std.StringHashMapUnmanaged(void) = .empty;
    var referenced: std.ArrayList([]const u8) = .empty;

    const items = tokens.items;
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const token = items[i];
        if (token.kind != .ident) continue;

        if (eql(token.text, "import")) {
            i = try collectImport(arena, items, i, &bound);
            continue;
        }
        if (eql(token.text, "export")) {
            i = try collectExport(arena, items, i, &exports, &bound);
            continue;
        }
        if (isDeclarator(token.text)) {
            i = try collectDeclaration(arena, items, i, &bound);
            continue;
        }
        if (eql(token.text, "catch")) {
            i = try collectParenNames(arena, items, i + 1, &bound);
            continue;
        }
        // A parameter list: `(a, b) =>` or `function f(a, b)`.
        if (isArrowParams(items, i)) {
            i = try collectParenNames(arena, items, i, &bound);
            continue;
        }
        if (isReference(items, i)) try referenced.append(arena, token.text);
    }
    // Arrow parameter lists that do not start at an identifier — `(a) =>`
    // after a `=`, a `(`, or a comma — are found by a second sweep over
    // every `(` in the file, because the first pass only looks at
    // identifiers.
    for (items, 0..) |token, at| {
        if (token.kind != .punct or !eql(token.text, "(")) continue;
        const close = matching(items, at) orelse continue;
        if (close + 1 >= items.len or !eql(items[close + 1].text, "=>")) continue;
        for (items[at + 1 .. close]) |inner| {
            if (inner.kind == .ident and !isKeyword(inner.text)) try bound.put(arena, inner.text, {});
        }
    }
    // A single-identifier arrow parameter, `x => …`.
    for (items, 0..) |token, at| {
        if (token.kind != .ident or at + 1 >= items.len) continue;
        if (!eql(items[at + 1].text, "=>")) continue;
        try bound.put(arena, token.text, {});
    }

    var unbound: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (referenced.items) |reference| {
        if (bound.contains(reference)) continue;
        if (isStandardGlobal(reference)) continue;
        if (seen.contains(reference)) continue;
        try seen.put(arena, reference, {});
        try unbound.append(arena, reference);
    }
    return .{ .exports = exports.items, .unbound = unbound.items };
}

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isDeclarator(text: []const u8) bool {
    return eql(text, "const") or eql(text, "let") or eql(text, "var") or
        eql(text, "function") or eql(text, "class");
}

/// `f(` where `f` is `function`, or an identifier that opens a parameter
/// list — `function name(a, b)`.
fn isArrowParams(items: []const Token, i: usize) bool {
    if (!eql(items[i].text, "function")) return false;
    var at = i + 1;
    if (at < items.len and items[at].kind == .ident) at += 1;
    return at < items.len and eql(items[at].text, "(");
}

/// An identifier in reference position: not a property after `.`, not an
/// object key or a label before `:`, not a keyword, not a literal.
fn isReference(items: []const Token, i: usize) bool {
    const token = items[i];
    if (isKeyword(token.text)) return false;
    if (i != 0 and items[i - 1].kind == .punct and eql(items[i - 1].text, ".")) return false;
    if (i + 1 < items.len and items[i + 1].kind == .punct and eql(items[i + 1].text, ":")) return false;
    return true;
}

fn matching(items: []const Token, open: usize) ?usize {
    var depth: u32 = 0;
    var at = open;
    while (at < items.len) : (at += 1) {
        if (items[at].kind != .punct) continue;
        if (eql(items[at].text, "(")) depth += 1;
        if (eql(items[at].text, ")")) {
            depth -= 1;
            if (depth == 0) return at;
        }
    }
    return null;
}

/// `import a, { b as c } from "m"` / `import * as m from "m"`: every
/// identifier in the statement is a local binding except the keywords.
fn collectImport(arena: Allocator, items: []const Token, start: usize, bound: *std.StringHashMapUnmanaged(void)) Allocator.Error!usize {
    var i = start + 1;
    while (i < items.len) : (i += 1) {
        const token = items[i];
        // The specifier string ends the statement, and so does a `;` — a
        // malformed import must not swallow the rest of the file, because
        // everything it swallowed would go unchecked.
        if (token.kind == .string) return i;
        if (token.kind == .punct and eql(token.text, ";")) return i;
        if (token.kind != .ident) continue;
        if (eql(token.text, "from") or eql(token.text, "as")) continue;
        // Every other identifier in an import statement names a binding the
        // file now has — `a`, `{ b as c }` and `* as m` alike. Taking the
        // left half of a rename too is deliberate over-approximation: this
        // check is about names that come from NOWHERE.
        try bound.put(arena, token.text, {});
    }
    return items.len;
}

/// `export const x = …`, `export function f …`, `export { a, b as c }`,
/// `export default …`.
fn collectExport(
    arena: Allocator,
    items: []const Token,
    start: usize,
    exports: *std.ArrayList([]const u8),
    bound: *std.StringHashMapUnmanaged(void),
) Allocator.Error!usize {
    var i = start + 1;
    if (i >= items.len) return i;
    if (items[i].kind == .ident and eql(items[i].text, "default")) {
        try exports.append(arena, "default");
        return i;
    }
    if (items[i].kind == .punct and eql(items[i].text, "{")) {
        // `export { a, b as c }`: the EXPORTED name is the one after `as`.
        var pending: ?[]const u8 = null;
        var renamed = false;
        i += 1;
        while (i < items.len and !(items[i].kind == .punct and eql(items[i].text, "}"))) : (i += 1) {
            const token = items[i];
            if (token.kind == .ident and eql(token.text, "as")) {
                renamed = true;
                continue;
            }
            if (token.kind == .ident) {
                if (renamed) {
                    pending = token.text;
                    renamed = false;
                } else {
                    if (pending) |name| try exports.append(arena, name);
                    pending = token.text;
                }
                continue;
            }
            if (token.kind == .punct and eql(token.text, ",")) {
                if (pending) |name| try exports.append(arena, name);
                pending = null;
            }
        }
        if (pending) |name| try exports.append(arena, name);
        return i;
    }
    if (items[i].kind == .ident and isDeclarator(items[i].text)) {
        // `export const a = …` / `export function f(…)`.
        if (i + 1 < items.len and items[i + 1].kind == .ident) try exports.append(arena, items[i + 1].text);
        return collectDeclaration(arena, items, i, bound);
    }
    return i;
}

/// The names a `const`/`let`/`var`/`function`/`class` binds: every
/// identifier from the keyword up to the `=`, `;`, `(` or `{` that ends the
/// binder, which covers `const x`, `const [a, b]` and `const { a, b }`.
fn collectDeclaration(arena: Allocator, items: []const Token, start: usize, bound: *std.StringHashMapUnmanaged(void)) Allocator.Error!usize {
    const is_function = eql(items[start].text, "function") or eql(items[start].text, "class");
    var i = start + 1;
    while (i < items.len) : (i += 1) {
        const token = items[i];
        if (token.kind == .punct) {
            if (eql(token.text, "=") or eql(token.text, ";") or eql(token.text, "(")) return i - 1;
            if (is_function and eql(token.text, "{")) return i - 1;
            continue;
        }
        if (token.kind != .ident) continue;
        if (eql(token.text, "of") or eql(token.text, "in")) return i - 1;
        try bound.put(arena, token.text, {});
        if (is_function) return i;
    }
    return items.len;
}

/// Every identifier inside the parenthesised list starting at or after `at`.
fn collectParenNames(arena: Allocator, items: []const Token, at: usize, bound: *std.StringHashMapUnmanaged(void)) Allocator.Error!usize {
    var open = at;
    while (open < items.len and !(items[open].kind == .punct and eql(items[open].text, "("))) open += 1;
    if (open >= items.len) return items.len;
    const close = matching(items, open) orelse return items.len;
    for (items[open + 1 .. close]) |token| {
        if (token.kind == .ident and !isKeyword(token.text)) try bound.put(arena, token.text, {});
    }
    return close;
}

// ---------------------------------------------------------------------------
// The lexer
// ---------------------------------------------------------------------------

const Token = struct {
    kind: enum { ident, punct, string, number },
    text: []const u8,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$' or c >= 0x80;
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

/// Comments, strings, template literals and regular expressions become one
/// token each (or none): their contents are not code as far as this scanner
/// is concerned. Template SUBSTITUTIONS are skipped with the template,
/// which is the permissive approximation the header explains.
fn tokenize(arena: Allocator, source: []const u8, out: *std.ArrayList(Token)) Allocator.Error!void {
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            i = @min(i + 2, source.len);
            continue;
        }
        if (c == '"' or c == '\'') {
            const start = i;
            i += 1;
            while (i < source.len and source[i] != c) {
                if (source[i] == '\\') i += 1;
                i += 1;
            }
            i = @min(i + 1, source.len);
            try out.append(arena, .{ .kind = .string, .text = source[start..@min(i, source.len)] });
            continue;
        }
        if (c == '`') {
            const start = i;
            i += 1;
            var depth: u32 = 0;
            while (i < source.len) : (i += 1) {
                if (source[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (source[i] == '$' and i + 1 < source.len and source[i + 1] == '{') {
                    depth += 1;
                    i += 1;
                    continue;
                }
                if (depth != 0 and source[i] == '}') {
                    depth -= 1;
                    continue;
                }
                if (depth == 0 and source[i] == '`') break;
            }
            i = @min(i + 1, source.len);
            try out.append(arena, .{ .kind = .string, .text = source[start..@min(i, source.len)] });
            continue;
        }
        if (c == '/' and regexAllowed(out.items)) {
            const start = i;
            i += 1;
            var in_class = false;
            while (i < source.len) : (i += 1) {
                if (source[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (source[i] == '[') in_class = true;
                if (source[i] == ']') in_class = false;
                if (source[i] == '\n') break;
                if (!in_class and source[i] == '/') break;
            }
            i = @min(i + 1, source.len);
            while (i < source.len and std.ascii.isAlphabetic(source[i])) i += 1;
            try out.append(arena, .{ .kind = .string, .text = source[start..@min(i, source.len)] });
            continue;
        }
        if (std.ascii.isDigit(c)) {
            const start = i;
            while (i < source.len and (isIdentPart(source[i]) or source[i] == '.')) i += 1;
            try out.append(arena, .{ .kind = .number, .text = source[start..i] });
            continue;
        }
        if (isIdentStart(c)) {
            const start = i;
            while (i < source.len and isIdentPart(source[i])) i += 1;
            try out.append(arena, .{ .kind = .ident, .text = source[start..i] });
            continue;
        }
        // Punctuation: the multi-character forms this scanner cares about
        // are `=>` and `...`; everything else is one byte, which is enough
        // because nothing below inspects an operator's spelling.
        if (c == '=' and i + 1 < source.len and source[i + 1] == '>') {
            try out.append(arena, .{ .kind = .punct, .text = source[i .. i + 2] });
            i += 2;
            continue;
        }
        try out.append(arena, .{ .kind = .punct, .text = source[i .. i + 1] });
        i += 1;
    }
}

/// Whether a `/` here opens a regular expression rather than dividing. The
/// standard heuristic: it divides only after something that can END an
/// expression.
fn regexAllowed(items: []const Token) bool {
    if (items.len == 0) return true;
    const last = items[items.len - 1];
    return switch (last.kind) {
        .number, .string => false,
        .ident => isKeyword(last.text),
        .punct => !(eql(last.text, ")") or eql(last.text, "]") or eql(last.text, "}")),
    };
}

fn isKeyword(text: []const u8) bool {
    const words = [_][]const u8{
        "await",    "break",    "case",      "catch",   "class",      "const",
        "continue", "debugger", "default",   "delete",  "do",         "else",
        "export",   "extends",  "false",     "finally", "for",        "from",
        "function", "if",       "import",    "in",      "instanceof", "let",
        "new",      "null",     "of",        "return",  "super",      "switch",
        "this",     "throw",    "true",      "try",     "typeof",     "var",
        "void",     "while",    "with",      "yield",   "as",         "static",
        "get",      "set",      "undefined",
    };
    for (words) |word| {
        if (eql(word, text)) return true;
    }
    return false;
}

/// Globals a sibling file may reach without importing anything: the
/// ECMAScript intrinsics, plus the web-standard capabilities boundary.md
/// §5.1 says every runtime has. A HOST global — `process`, `require`,
/// `__dirname`, `window`, `Deno`, `Bun` — is deliberately NOT here: those
/// are exactly the edges check 3 exists to make visible, and importing
/// `node:process` is the fix.
fn isStandardGlobal(text: []const u8) bool {
    const globals = [_][]const u8{
        "Array",           "ArrayBuffer",        "BigInt",          "Boolean",
        "DataView",        "Date",               "Error",           "EvalError",
        "Float32Array",    "Float64Array",       "Function",        "Infinity",
        "Int8Array",       "Int16Array",         "Int32Array",      "Intl",
        "JSON",            "Map",                "Math",            "NaN",
        "Number",          "Object",             "Promise",         "Proxy",
        "RangeError",      "ReferenceError",     "Reflect",         "RegExp",
        "Set",             "String",             "Symbol",          "SyntaxError",
        "TypeError",       "URIError",           "Uint8Array",      "Uint16Array",
        "Uint32Array",     "WeakMap",            "WeakSet",         "globalThis",
        "isFinite",        "isNaN",              "parseFloat",      "parseInt",
        "decodeURI",       "decodeURIComponent", "encodeURI",       "encodeURIComponent",
        "structuredClone", "queueMicrotask",     "AbortController", "TextDecoder",
        "TextEncoder",     "URL",                "URLSearchParams", "atob",
        "btoa",            "console",            "crypto",          "fetch",
        "setTimeout",      "clearTimeout",       "setInterval",     "clearInterval",
        "performance",     "Uint8ClampedArray",  "BigInt64Array",   "BigUint64Array",
    };
    for (globals) |global| {
        if (eql(global, text)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn scanOnce(arena: Allocator, source: []const u8) !Scan {
    return scan(arena, source);
}

test "exports: every form boundary.md's recipe uses" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const result = try scanOnce(a.allocator(),
        \\const helper = (x) => x;
        \\export const add = (a, b) => a + b;
        \\export function sub(a, b) { return a - b; }
        \\const one = 1;
        \\const two = 2;
        \\export { one, two as pair };
    );
    try testing.expectEqual(@as(usize, 4), result.exports.len);
    try testing.expectEqualStrings("add", result.exports[0]);
    try testing.expectEqualStrings("sub", result.exports[1]);
    try testing.expectEqualStrings("one", result.exports[2]);
    try testing.expectEqualStrings("pair", result.exports[3]);
    try testing.expectEqual(@as(usize, 0), result.unbound.len);
}

test "check 3: a host global that was never imported is unbound" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const result = try scanOnce(a.allocator(),
        \\export const write = (s) => { process.stdout.write(s); };
    );
    try testing.expectEqual(@as(usize, 1), result.unbound.len);
    try testing.expectEqualStrings("process", result.unbound[0]);
}

test "check 3: importing it is the fix" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const result = try scanOnce(a.allocator(),
        \\import process from "node:process";
        \\export const write = (s) => { process.stdout.write(s); };
    );
    try testing.expectEqual(@as(usize, 0), result.unbound.len);
    try testing.expectEqual(@as(usize, 1), result.exports.len);
}

test "check 3: named and namespace imports bind too" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const result = try scanOnce(a.allocator(),
        \\import { cons as makeCell } from "./List.js";
        \\import * as fs from "node:fs";
        \\export const one = () => makeCell(1, fs.nothing);
    );
    try testing.expectEqual(@as(usize, 0), result.unbound.len);
}

test "standard globals need no import; strings, comments and regexes are not code" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const result = try scanOnce(a.allocator(),
        \\// process is fine in a comment
        \\const pattern = /process/g;
        \\export const f = (s) => Math.max(0, s.search(pattern)) + "process".length;
    );
    try testing.expectEqual(@as(usize, 0), result.unbound.len);
    try testing.expectEqual(@as(usize, 1), result.exports.len);
}

test "object keys and property accesses are not references" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const result = try scanOnce(a.allocator(),
        \\export const cell = (head, tail) => ({ $: 1, a: head, b: tail });
        \\export const headOf = (cell2) => cell2.a;
    );
    try testing.expectEqual(@as(usize, 0), result.unbound.len);
}

test "every sibling that ships in the box passes check 3" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const core_package = @import("core_package");
    const platform_packages = @import("platform_packages");
    var scanned: u32 = 0;
    for (core_package.assets) |asset| {
        if (!std.mem.endsWith(u8, asset.path, ".js")) continue;
        const result = try scanOnce(a.allocator(), asset.bytes);
        if (result.unbound.len != 0) {
            std.debug.print("{s} reaches `{s}` without importing it\n", .{ asset.path, result.unbound[0] });
            return error.UnboundReference;
        }
        try testing.expect(result.exports.len != 0);
        scanned += 1;
    }
    for (platform_packages.platforms) |platform| {
        for (platform.assets) |asset| {
            if (!std.mem.endsWith(u8, asset.path, ".js")) continue;
            const result = try scanOnce(a.allocator(), asset.bytes);
            if (result.unbound.len != 0) {
                std.debug.print("{s} reaches `{s}` without importing it\n", .{ asset.path, result.unbound[0] });
                return error.UnboundReference;
            }
            try testing.expect(result.exports.len != 0);
            scanned += 1;
        }
    }
    // Core has five siblings and the Node platform two; a zero here would
    // mean the embedding broke and the check passed by looking at nothing.
    try testing.expect(scanned >= 7);
}

test "fuzz: the scanner never panics on arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.sliceWithHash(&buf, 0x5B10C);
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            _ = try scan(a.allocator(), buf[0..len]);
        }
    }.testOne, .{});
}
