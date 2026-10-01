//! The sibling JavaScript file of a module that declares `foreign` values,
//! and the three checks `boundary.md` §4 makes of it that Elm does not make
//! of its kernel code — the second, the third, and half of the fourth:
//!
//!  2. **It exports exactly the declared names** — no more, no fewer.
//!  3. **Its references are covered by its own imports** (§7.1).
//!  4. **Each export takes evidence count + declared arity parameters.**
//!
//! Check 1 — the two-shape type rule — is about the beni annotation and
//! lives in `js/Emit.zig`, next to the `Bir` that holds it. So does check
//! 4's comparison: what this file supplies is the left-hand side of it, the
//! parameter count each export is WRITTEN with, because only the `Bir` and
//! the dispatch table know what the count should be.
//!
//! **Why check 4 exists.** Since static dispatch a `pub foreign` may carry
//! a `where` clause, and its sibling then takes the evidence parameters of
//! `static-dispatch-spike.md` §8.1 in front of its declared ones —
//! `core/List.js` writes `eq` as `(m0, xs, ys)` for a declaration that is
//! 2-ary in beni. Nothing used to check that count, so a sibling that
//! forgot the leading parameter built cleanly and produced a program that
//! silently compared the wrong things. Every call the backend emits is
//! saturated (`backend.md` §6), so an arity mistake is never a partial
//! application: it is an argument that arrives nowhere.
//!
//! **Why check 3 exists**, because it is the least obvious of the four:
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

/// How many parameters an export is written with — check 4's left-hand
/// side, and the whole of what this scanner claims about a function.
///
/// The three cases are a deliberate closed set. A sibling is privileged,
/// first-party code, so `boundary.md` §4 may restrict how it spells an
/// export, and the restriction is the one that keeps the answer readable
/// BY EYE: the parameter list must be at the export. Anything else is
/// `.opaque_value` or `.uncountable` and is refused there, rather than
/// waved through as "unknown" — waving it through is what the check exists
/// to stop.
pub const Arity = union(enum) {
    /// A function literal: an arrow or a `function`, with this many
    /// parameter POSITIONS. A destructuring or defaulted parameter is one
    /// position like any other, because the emitted call fills positions.
    function: u32,
    /// Not written as a function here: a constant (`export const pi =
    /// Math.PI`), or a name whose definition this scanner cannot see —
    /// `export const f = g` and a re-export both land here.
    opaque_value,
    /// A function literal whose parameter list has no fixed length: a rest
    /// parameter. Nothing in `core/` or `platforms/` uses one.
    uncountable,
};

/// One export, with the parameter count it is written with.
pub const Export = struct {
    name: []const u8,
    arity: Arity,
    /// Byte offset of the name AS WRITTEN in the file. `boundary.md` §4's
    /// rule is that a diagnostic points at the file whose text is wrong, so
    /// an export nothing declares is underlined HERE and not on some
    /// innocent `foreign` in the module. For `export { g as f }` it is `f`,
    /// the name check 2 compares; for `export default …`, the `default`.
    offset: u32,
};

/// A name the file uses, or a specifier it imports, and where it is
/// written. Both feed a diagnostic that points into the `.js`.
pub const Located = struct {
    text: []const u8,
    offset: u32,
};

/// What the scan found. All slices point into the scanned bytes.
pub const Scan = struct {
    /// Names the file exports, in source order, with their arities.
    exports: []const Export,
    /// Identifiers referenced that are neither bound in the file, nor
    /// imported by it, nor a standard global — first occurrence of each.
    unbound: []const Located,
    /// Module specifiers that name a FILE rather than a package — `./x.js`,
    /// `../y.mjs` — with their quotes, in source order.
    ///
    /// They are collected because the build RENAMES a sibling as it copies
    /// it out (`js/Emit.zig`: `<Module>.foreign.mjs`, so that every emitted
    /// file is `.mjs` per backend.md §2), and a relative specifier written
    /// against the source names would then point at nothing. They are
    /// refused rather than rewritten, because the alternative is a build
    /// that succeeds and a program that cannot load.
    relative_imports: []const Located,
};

/// Scan `source`. Everything returned is owned by `arena`.
pub fn scan(arena: Allocator, source: []const u8) Allocator.Error!Scan {
    var tokens: std.ArrayList(Token) = .empty;
    try tokenize(arena, source, &tokens);

    var exports: std.ArrayList(Export) = .empty;
    var bound: std.StringHashMapUnmanaged(void) = .empty;
    var referenced: std.ArrayList(Located) = .empty;
    var relative: std.ArrayList(Located) = .empty;

    const items = tokens.items;
    // Check 4's table, built before the walk below so that `export { a, b
    // as c }` can look its LOCAL name up: the exported name is `c`, and the
    // parameter list belongs to `b`.
    var arities: std.StringHashMapUnmanaged(Arity) = .empty;
    try collectArities(arena, items, &arities);

    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const token = items[i];
        if (token.kind != .ident) continue;

        if (eql(token.text, "import")) {
            const end = try collectImport(arena, items, i, &bound);
            if (end < items.len and items[end].kind == .string and isRelative(items[end].text)) {
                try relative.append(arena, .{ .text = items[end].text, .offset = items[end].offset });
            }
            i = end;
            continue;
        }
        if (eql(token.text, "export")) {
            i = try collectExport(arena, items, i, &exports, &bound, &arities);
            continue;
        }
        // A function's parameter list, `function f(a, b)` or `function (a)`,
        // before the declarator branch below, which would otherwise take
        // `function f` and leave `(a, b)` to be read as references. The
        // name is a binding too.
        if (isArrowParams(items, i)) {
            if (i + 1 < items.len and items[i + 1].kind == .ident) try bound.put(arena, items[i + 1].text, {});
            i = try collectParenNames(arena, items, i, &bound);
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
        if (isReference(items, i)) try referenced.append(arena, .{ .text = token.text, .offset = token.offset });
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

    // The FIRST occurrence of each name, which is the one the diagnostic
    // underlines: a reader who fixes the import fixes every later use too,
    // and reporting them all would be one error per use of `process`.
    var unbound: std.ArrayList(Located) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (referenced.items) |reference| {
        if (bound.contains(reference.text)) continue;
        if (isStandardGlobal(reference.text)) continue;
        if (seen.contains(reference.text)) continue;
        try seen.put(arena, reference.text, {});
        try unbound.append(arena, reference);
    }
    return .{ .exports = exports.items, .unbound = unbound.items, .relative_imports = relative.items };
}

/// A specifier that names a file relative to this one. A BARE specifier —
/// `node:process`, a package name — is untouched by the copy and needs no
/// rewriting; only a path does.
fn isRelative(quoted: []const u8) bool {
    if (quoted.len < 2) return false;
    const inner = quoted[1 .. quoted.len - 1];
    return std.mem.startsWith(u8, inner, "./") or std.mem.startsWith(u8, inner, "../") or
        std.mem.startsWith(u8, inner, "/");
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
    exports: *std.ArrayList(Export),
    bound: *std.StringHashMapUnmanaged(void),
    arities: *const std.StringHashMapUnmanaged(Arity),
) Allocator.Error!usize {
    var i = start + 1;
    if (i >= items.len) return i;
    if (items[i].kind == .ident and eql(items[i].text, "default")) {
        // A `default` export can never match a `foreign` name, so check 2
        // refuses it before check 4 has anything to say.
        try exports.append(arena, .{ .name = "default", .arity = .opaque_value, .offset = items[i].offset });
        return i;
    }
    if (items[i].kind == .punct and eql(items[i].text, "{")) {
        // `export { a, b as c }`: the EXPORTED name is the one after `as`,
        // and the ARITY belongs to the local name in front of it.
        var local: ?Located = null;
        var exported: ?Located = null;
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
                    exported = .{ .text = token.text, .offset = token.offset };
                    renamed = false;
                } else {
                    try flushClause(arena, exports, arities, local, exported);
                    local = .{ .text = token.text, .offset = token.offset };
                    exported = null;
                }
                continue;
            }
            if (token.kind == .punct and eql(token.text, ",")) {
                try flushClause(arena, exports, arities, local, exported);
                local = null;
                exported = null;
            }
        }
        try flushClause(arena, exports, arities, local, exported);
        return i;
    }
    if (items[i].kind == .ident and isDeclarator(items[i].text)) {
        // `export const a = …` / `export function f(…)`. The arity came
        // from `collectArities`, which saw this same declaration.
        if (i + 1 < items.len and items[i + 1].kind == .ident) {
            const name = items[i + 1].text;
            try exports.append(arena, .{
                .name = name,
                .arity = arityOf(arities, name),
                .offset = items[i + 1].offset,
            });
        }
        return collectDeclaration(arena, items, i, bound);
    }
    return i;
}

/// One entry of an `export { … }` clause, once its two halves are known.
fn flushClause(
    arena: Allocator,
    exports: *std.ArrayList(Export),
    arities: *const std.StringHashMapUnmanaged(Arity),
    local: ?Located,
    exported: ?Located,
) Allocator.Error!void {
    const name = local orelse return;
    // The EXPORTED name is what check 2 compares and therefore what the
    // caret goes under; the arity belongs to the local name in front of it.
    const written = exported orelse name;
    try exports.append(arena, .{
        .name = written.text,
        .arity = arityOf(arities, name.text),
        .offset = written.offset,
    });
}

fn arityOf(arities: *const std.StringHashMapUnmanaged(Arity), name: []const u8) Arity {
    // A name with no binder in this file is an import re-exported, and its
    // parameter list is in another file. `.opaque_value` refuses it, which
    // is the rule §4 states: the parameter list is written at the export.
    return arities.get(name) orelse .opaque_value;
}

// ---------------------------------------------------------------------------
// Check 4: what each export is written with
// ---------------------------------------------------------------------------

/// Every TOP-LEVEL binder in the file, with the arity of what it is bound
/// to. Depth is tracked so that a `const` inside a function body cannot
/// claim an export's name; the count saturates at zero so that an
/// unbalanced bracket loses one binding rather than every binding after it.
fn collectArities(
    arena: Allocator,
    items: []const Token,
    out: *std.StringHashMapUnmanaged(Arity),
) Allocator.Error!void {
    var depth: u32 = 0;
    for (items, 0..) |token, i| {
        if (token.kind == .punct) {
            if (eql(token.text, "(") or eql(token.text, "[") or eql(token.text, "{")) depth += 1;
            if (eql(token.text, ")") or eql(token.text, "]") or eql(token.text, "}")) depth -|= 1;
            continue;
        }
        if (depth != 0 or token.kind != .ident) continue;
        if (i + 1 >= items.len or items[i + 1].kind != .ident) continue;
        const name = items[i + 1].text;
        if (eql(token.text, "function")) {
            try out.put(arena, name, countParams(items, i + 2));
            continue;
        }
        if (!isDeclarator(token.text) or eql(token.text, "class")) continue;
        // `const x = <value>`; `const [a, b] = …` is not a shape an export
        // of a foreign value may take and is simply not recorded.
        if (i + 2 < items.len and items[i + 2].kind == .punct and eql(items[i + 2].text, "=")) {
            try out.put(arena, name, classifyValue(items, i + 3));
        }
    }
}

/// The arity of the expression starting at `at`, which is a function only
/// when it is written as one right here.
fn classifyValue(items: []const Token, at: usize) Arity {
    if (at >= items.len) return .opaque_value;
    // `async (a, b) => …`: the modifier does not change the parameters.
    const head = if (items[at].kind == .ident and eql(items[at].text, "async")) at + 1 else at;
    if (head >= items.len) return .opaque_value;
    if (items[head].kind == .ident and eql(items[head].text, "function")) {
        // `function (a, b) {}` and `function named(a, b) {}`.
        const open = if (head + 1 < items.len and items[head + 1].kind == .ident) head + 2 else head + 1;
        return countParams(items, open);
    }
    if (items[head].kind == .punct and eql(items[head].text, "(")) {
        const close = matching(items, head) orelse return .opaque_value;
        // A parenthesised expression is not a parameter list; only the
        // `=>` makes it one.
        if (close + 1 >= items.len or !eql(items[close + 1].text, "=>")) return .opaque_value;
        return countParams(items, head);
    }
    // `x => …`, the one arrow form that needs no parentheses.
    if (items[head].kind == .ident and !isKeyword(items[head].text) and
        head + 1 < items.len and eql(items[head + 1].text, "=>")) return .{ .function = 1 };
    return .opaque_value;
}

/// The parameter POSITIONS of the list that opens at `open`: one more than
/// the commas at its own depth. A rest parameter makes the list unbounded
/// and is reported as such rather than counted.
fn countParams(items: []const Token, open: usize) Arity {
    if (open >= items.len or !(items[open].kind == .punct and eql(items[open].text, "("))) return .opaque_value;
    const close = matching(items, open) orelse return .opaque_value;
    var count: u32 = 0;
    var depth: u32 = 0;
    var dots: u32 = 0;
    for (items[open + 1 .. close]) |token| {
        if (token.kind != .punct) {
            dots = 0;
            continue;
        }
        if (eql(token.text, "(") or eql(token.text, "[") or eql(token.text, "{")) depth += 1;
        if (eql(token.text, ")") or eql(token.text, "]") or eql(token.text, "}")) depth -|= 1;
        if (depth == 0 and eql(token.text, ",")) count += 1;
        // `...` is three one-byte tokens (the lexer spells only `=>` long).
        dots = if (eql(token.text, ".")) dots + 1 else 0;
        if (dots == 3) return .uncountable;
    }
    if (close == open + 1) return .{ .function = 0 };
    return .{ .function = count + 1 };
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
    /// Byte offset of `text` in the scanned file. Carried on every token
    /// because the checks report against the `.js` itself (`boundary.md`
    /// §4), and the offset is what turns a finding into a line, a column
    /// and an excerpt.
    offset: u32,
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
            try out.append(arena, .{ .kind = .string, .text = source[start..@min(i, source.len)], .offset = @intCast(start) });
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
            try out.append(arena, .{ .kind = .string, .text = source[start..@min(i, source.len)], .offset = @intCast(start) });
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
            try out.append(arena, .{ .kind = .string, .text = source[start..@min(i, source.len)], .offset = @intCast(start) });
            continue;
        }
        if (std.ascii.isDigit(c)) {
            const start = i;
            while (i < source.len and (isIdentPart(source[i]) or source[i] == '.')) i += 1;
            try out.append(arena, .{ .kind = .number, .text = source[start..i], .offset = @intCast(start) });
            continue;
        }
        if (isIdentStart(c)) {
            const start = i;
            while (i < source.len and isIdentPart(source[i])) i += 1;
            try out.append(arena, .{ .kind = .ident, .text = source[start..i], .offset = @intCast(start) });
            continue;
        }
        // Punctuation: the multi-character forms this scanner cares about
        // are `=>` and `...`; everything else is one byte, which is enough
        // because nothing below inspects an operator's spelling.
        if (c == '=' and i + 1 < source.len and source[i + 1] == '>') {
            try out.append(arena, .{ .kind = .punct, .text = source[i .. i + 2], .offset = @intCast(i) });
            i += 2;
            continue;
        }
        try out.append(arena, .{ .kind = .punct, .text = source[i .. i + 1], .offset = @intCast(i) });
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
    return keyword_set.has(text);
}

const keyword_set = setOf(&keyword_words);

/// One `StaticStringMap` from a list of words, built at compile time: a
/// scan asks it of every identifier of every sibling.
fn setOf(comptime words: []const []const u8) std.StaticStringMap(void) {
    @setEvalBranchQuota(100_000);
    var kvs: [words.len]struct { []const u8 } = undefined;
    for (words, 0..) |w, i| kvs[i] = .{w};
    return .initComptime(kvs);
}

const keyword_words = [_][]const u8{
    "await",    "break",    "case",      "catch",   "class",      "const",
    "continue", "debugger", "default",   "delete",  "do",         "else",
    "export",   "extends",  "false",     "finally", "for",        "from",
    "function", "if",       "import",    "in",      "instanceof", "let",
    "new",      "null",     "of",        "return",  "super",      "switch",
    "this",     "throw",    "true",      "try",     "typeof",     "var",
    "void",     "while",    "with",      "yield",   "as",         "static",
    "get",      "set",      "undefined",
};

/// Globals a sibling file may reach without importing anything: the
/// ECMAScript intrinsics, plus the web-standard capabilities boundary.md
/// §5.1 says every runtime has. A HOST global — `process`, `require`,
/// `__dirname`, `window`, `Deno`, `Bun` — is deliberately NOT here: those
/// are exactly the edges check 3 exists to make visible, and importing
/// `node:process` is the fix.
pub fn isStandardGlobal(text: []const u8) bool {
    return global_set.has(text);
}

const global_set = setOf(&global_words);

const global_words = [_][]const u8{
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn scanOnce(arena: Allocator, source: []const u8) !Scan {
    return scan(arena, source);
}

test "exports: every form boundary.md's recipe uses, with its arity" {
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
    try testing.expectEqualStrings("add", result.exports[0].name);
    try testing.expectEqual(@as(Arity, .{ .function = 2 }), result.exports[0].arity);
    try testing.expectEqualStrings("sub", result.exports[1].name);
    try testing.expectEqual(@as(Arity, .{ .function = 2 }), result.exports[1].arity);
    // A renamed export takes the LOCAL name's parameter list and the
    // exported name.
    try testing.expectEqualStrings("one", result.exports[2].name);
    try testing.expectEqual(@as(Arity, .opaque_value), result.exports[2].arity);
    try testing.expectEqualStrings("pair", result.exports[3].name);
    try testing.expectEqual(@as(Arity, .opaque_value), result.exports[3].arity);
    try testing.expectEqual(@as(usize, 0), result.unbound.len);
}

test "check 4: the parameter list has to be at the export" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const result = try scanOnce(a.allocator(),
        \\const impl = (a, b) => a + b;
        \\export const zero = () => 0;
        \\export const one = (x) => x;
        \\export const named = function (a, b, c) { return a; };
        \\export const bare = x => x;
        \\export const spread = (...args) => args;
        \\export const alias = impl;
        \\export const pi = Math.PI;
        \\export const grouped = (1 + 2);
        \\export const pair = ({ a, b }, fallback = 0) => a + b + fallback;
    );
    const expected = [_]Arity{
        .{ .function = 0 },
        .{ .function = 1 },
        .{ .function = 3 },
        .{ .function = 1 },
        .uncountable,
        // `impl` IS a function, and the scanner still refuses: the rule is
        // that the parameter list is written at the export, so that a
        // reader can count it against the declaration.
        .opaque_value,
        .opaque_value,
        .opaque_value,
        // A destructuring and a defaulted parameter are one POSITION each,
        // because the emitted call fills positions.
        .{ .function = 2 },
    };
    try testing.expectEqual(expected.len, result.exports.len);
    for (expected, result.exports) |want, got| try testing.expectEqual(want, got.arity);
}

test "check 4: a nested binder does not claim an export's name" {
    // The scanner is not a scope analysis (see the header), so the arity
    // table is the one place it tracks depth: a `const eq` inside a body
    // must not answer for the `eq` the module exports.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const result = try scanOnce(a.allocator(),
        \\export const eq = (m0, xs, ys) => {
        \\  const eq = (a) => a;
        \\  return eq(m0(xs, ys));
        \\};
    );
    try testing.expectEqual(@as(usize, 1), result.exports.len);
    try testing.expectEqual(@as(Arity, .{ .function = 3 }), result.exports[0].arity);
}

test "check 3: a host global that was never imported is unbound" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const result = try scanOnce(a.allocator(),
        \\export const write = (s) => { process.stdout.write(s); };
    );
    try testing.expectEqual(@as(usize, 1), result.unbound.len);
    try testing.expectEqualStrings("process", result.unbound[0].text);
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

test "a specifier naming a file is reported; a bare one is not" {
    // The build renames a sibling as it copies it out, so a specifier
    // written against the source name would point at nothing. A package
    // specifier survives the copy untouched.
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const result = try scanOnce(a.allocator(),
        \\import process from "node:process";
        \\import { cons } from "./List.js";
        \\import helper from "../shared/helper.mjs";
        \\import lodash from "lodash";
        \\export const one = () => cons(1, helper(process, lodash));
    );
    try testing.expectEqual(@as(usize, 2), result.relative_imports.len);
    try testing.expectEqualStrings("\"./List.js\"", result.relative_imports[0].text);
    try testing.expectEqualStrings("\"../shared/helper.mjs\"", result.relative_imports[1].text);
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

/// Check 4's left-hand side, for the embedded siblings: every export is
/// written so that its parameters can be counted. Whether the count is the
/// RIGHT one is `js/Emit.zig`'s question and every corpus build asks it.
fn expectCountable(path: []const u8, result: Scan) !void {
    for (result.exports) |entry| {
        if (entry.arity != .uncountable) continue;
        std.debug.print("{s} writes `{s}` with a parameter list nothing can count\n", .{ path, entry.name });
        return error.UncountableExport;
    }
}

test "every sibling that ships in the box passes checks 3 and 4" {
    var a: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a.deinit();
    const core_package = @import("core_package");
    const platform_packages = @import("platform_packages");
    var scanned: u32 = 0;
    for (core_package.assets) |asset| {
        if (!std.mem.endsWith(u8, asset.path, ".js")) continue;
        const result = try scanOnce(a.allocator(), asset.bytes);
        if (result.unbound.len != 0) {
            std.debug.print("{s} reaches `{s}` without importing it\n", .{ asset.path, result.unbound[0].text });
            return error.UnboundReference;
        }
        try testing.expect(result.exports.len != 0);
        try expectCountable(asset.path, result);
        scanned += 1;
    }
    for (platform_packages.platforms) |platform| {
        for (platform.assets) |asset| {
            if (!std.mem.endsWith(u8, asset.path, ".js")) continue;
            const result = try scanOnce(a.allocator(), asset.bytes);
            if (result.unbound.len != 0) {
                std.debug.print("{s} reaches `{s}` without importing it\n", .{ asset.path, result.unbound[0].text });
                return error.UnboundReference;
            }
            try testing.expect(result.exports.len != 0);
            try expectCountable(asset.path, result);
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
