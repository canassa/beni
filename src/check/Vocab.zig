//! The vocabulary declarations of a module, checked (checker-v2.md §25.2):
//! `pub element`, `pub attribute`, `pub event` and `pub markup`
//! (`language.md` §11.14).
//!
//! Each is checked once, as a declaration, after P2 has read every
//! annotated value's scheme — a `via` extractor is a `foreign` value, whose
//! annotation is all it needs, and a markup primitive's scheme is P2's — and
//! before any value group, so nothing here waits on inference. An
//! attribute's value type and an event's payload type are read here, into
//! the declaration's `decl_scheme` slot, which is what publication writes
//! (§25.8).
//!
//! A failure is reported against the declaration and sets its failure bit
//! (`Report.at`), and publication then leaves the row out, so an importer
//! never reads a half-checked row. The language gives these faults no codes
//! of their own: a type that is not one the form admits is `type_mismatch`,
//! a fact written twice or two declarations that answer the same names are
//! `duplicate_declaration`, and a `via` that names no `foreign` value of the
//! module is `unbound_variable`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const TypeStore = @import("TypeStore.zig");
const Walk = @import("Walk.zig");
const Context = @import("Context.zig");
const Report = @import("Report.zig");

const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

/// The build's markup type (`boundary.md` §9.2), by its declaring module's
/// name and its own.
pub const MarkupType = struct { module: Symbol, name: Symbol };

pub fn check(cx: *const Context, report: *Report, decl_scheme: []Var.Optional, markup_type: ?MarkupType) Error!void {
    const bir = cx.bir;
    var any = false;
    for (bir.decls, 0..) |d, i| {
        if (!d.kind.isVocab()) continue;
        any = true;
        report.at(@intCast(i));
        try checkOne(cx, report, decl_scheme, markup_type, @intCast(i));
    }
    if (!any) return;
    try duplicates(cx, report);
    report.at(null);
}

fn facts(bir: *const Bir, d: Bir.Decl) []const Bir.VocabFact {
    return bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Bir.VocabFact);
}

fn text(cx: *const Context, s: Symbol) []const u8 {
    return cx.interner.slice(s);
}

fn fail(cx: *const Context, report: *Report, i: u32, code: @import("diagnostic").Code, comptime format: []const u8, args: anytype) Error!void {
    const d = cx.bir.decls[i];
    const message = try std.fmt.allocPrint(cx.scratch, format, args);
    try report.emitText(code, d.inst_start, d.name_token, message);
}

fn checkOne(cx: *const Context, report: *Report, decl_scheme: []Var.Optional, markup_type: ?MarkupType, i: u32) Error!void {
    const bir = cx.bir;
    const d = bir.decls[i];
    const name = text(cx, bir.symbol(d.name));
    const fs = facts(bir, d);

    // The facts are a set: a word written twice says nothing new and is
    // almost always a mistake. `on` takes several names, each once.
    var seen: u32 = 0;
    for (fs, 0..) |f, k| {
        const bit = @as(u32, 1) << @intCast(@intFromEnum(f.word));
        if (f.word == .on) {
            for (fs[0..k]) |g| {
                if (g.word == .on and f.arg != .none and g.arg != .none and bir.symbol(g.arg) == bir.symbol(f.arg)) return fail(cx, report, i, .duplicate_declaration,
                    \\`{s}` names the element `{s}` twice after `on`.
                    \\
                    \\Each element is named once (`docs/design/checker-v2.md` §25.2).
                , .{ name, text(cx, bir.symbol(f.arg)) });
            }
            continue;
        }
        if (seen & bit != 0) return fail(cx, report, i, .duplicate_declaration,
            \\`{s}` declares the fact `{s}` twice.
            \\
            \\A declaration's facts are a set (`docs/design/checker-v2.md` §25.2): write each once.
        , .{ name, f.word.spelling() });
        seen |= bit;
    }
    const has = struct {
        fn f(bits: u32, word: Bir.FactWord) bool {
            return bits & (@as(u32, 1) << @intCast(@intFromEnum(word))) != 0;
        }
    }.f;

    switch (d.kind) {
        .vocab_element => {
            if (has(seen, .svg) and has(seen, .mathml)) return fail(cx, report, i, .duplicate_declaration,
                \\The element `{s}` is declared both `svg` and `mathml`.
                \\
                \\An element has one namespace (`docs/design/language.md` §11.14): write one of
                \\the two, or neither for HTML.
            , .{name});
        },
        .vocab_attribute => {
            const v = try readType(cx, decl_scheme, d, i) orelse return;
            if (has(seen, .classes) and has(seen, .styles)) return fail(cx, report, i, .duplicate_declaration,
                \\The attribute `{s}` is declared both `classes` and `styles`.
                \\
                \\An attribute takes at most one of the two list forms
                \\(`docs/design/language.md` §11.19).
            , .{name});
            const class = valueClass(cx, v);
            if ((has(seen, .classes) or has(seen, .styles)) and class != .string) return fail(cx, report, i, .type_mismatch,
                \\The attribute `{s}` takes a {s} list, so its value type must be `String`.
                \\
                \\A `classes` or `styles` attribute is written as a string or as a list
                \\(`docs/design/language.md` §11.19).
            , .{ name, if (has(seen, .classes)) "class" else "style" });
            if (class == .other) return fail(cx, report, i, .type_mismatch,
                \\The attribute `{s}` must have one of the value types a lowering can write.
                \\
                \\An attribute's value type is `String`, `Int`, `Float`, `Bool` or
                \\`Maybe String` (`docs/design/language.md` §11.14).
            , .{name});
        },
        .vocab_event => {
            const payload = try readType(cx, decl_scheme, d, i) orelse return;
            const via = for (fs) |f| {
                if (f.word == .via and f.arg != .none) break bir.symbol(f.arg);
            } else null;
            if (via) |extractor| {
                const scheme = extractorScheme(cx, decl_scheme, extractor) orelse return fail(cx, report, i, .unbound_variable,
                    \\The event `{s}` takes its payload `via {s}`, which is not a `foreign` value of
                    \\this module.
                    \\
                    \\A payload extractor is a `foreign` value declared beside the event
                    \\(`docs/design/boundary.md` §9.3).
                , .{ name, text(cx, extractor) });
                if (!extractorFits(cx, scheme, payload)) return fail(cx, report, i, .type_mismatch,
                    \\The event `{s}` takes its payload `via {s}`, whose type does not fit.
                    \\
                    \\The extractor takes the event object, a `foreign type`, and returns the
                    \\event's payload type (`docs/design/checker-v2.md` §25.2).
                , .{ name, text(cx, extractor) });
            } else if (!isForeignType(cx, payload)) return fail(cx, report, i, .type_mismatch,
                \\The event `{s}` has no `via`, so its payload is the event object itself, and
                \\its type must be a `foreign type`.
                \\
                \\Name an extractor with `via` to hand a handler anything else
                \\(`docs/design/language.md` §11.14).
            , .{name});
        },
        .vocab_markup => {
            const v = decl_scheme[i].unwrap() orelse return;
            if (isErr(cx, v)) return;
            const is_function = switch (cx.store.resolvedContent(v)) {
                .structure => |s| s == .func,
                else => false,
            };
            const mentions = if (markup_type) |t| try mentionsType(cx, v, t) else true;
            if (!is_function or !mentions) return fail(cx, report, i, .type_mismatch,
                \\The markup primitive `{s}` must be a function whose type mentions the markup
                \\type.
                \\
                \\A primitive builds or transforms markup at run time, and each lowering's runtime
                \\implements it (`docs/design/boundary.md` §9.3).
            , .{name});
        },
        else => unreachable,
    }
}

/// Read the declaration's annotation into its `decl_scheme` slot; null when
/// it has none or reads as an error, which is already reported.
fn readType(cx: *const Context, decl_scheme: []Var.Optional, d: Bir.Decl, i: u32) Error!?Var {
    const annotation = d.annotation.unwrap() orelse return null;
    var b = cx.builder(.flex, TypeStore.generalized);
    defer b.deinit();
    const v = try cx.readAnnotation(&b, annotation, i);
    decl_scheme[i] = v.toOptional();
    if (isErr(cx, v)) return null;
    return v;
}

fn isErr(cx: *const Context, v: Var) bool {
    return cx.store.resolvedContent(v) == .err;
}

pub const ValueClass = enum { string, int, float, bool, maybe_string, other };

/// Which of §11.14's five value types `v` is, after aliases.
pub fn valueClass(cx: *const Context, v: Var) ValueClass {
    const wk = cx.types.well_known;
    const app = appOf(cx, v) orelse return .other;
    if (app.type == wk.string and app.args.len == 0) return .string;
    if (app.type == wk.int and app.args.len == 0) return .int;
    if (app.type == wk.float and app.args.len == 0) return .float;
    if (app.type == wk.bool and app.args.len == 0) return .bool;
    if (app.type == wk.maybe and app.args.len == 1) {
        const inner = appOf(cx, Walk.positions(cx.store, v)[0]) orelse return .other;
        if (inner.type == wk.string and inner.args.len == 0) return .maybe_string;
    }
    return .other;
}

fn appOf(cx: *const Context, v: Var) ?TypeStore.Structure.App {
    return switch (cx.store.resolvedContent(v)) {
        .structure => |s| switch (s) {
            .app => |a| a,
            else => null,
        },
        else => null,
    };
}

fn isForeignType(cx: *const Context, v: Var) bool {
    const app = appOf(cx, v) orelse return false;
    if (app.type == .none or app.type.int() >= cx.types.entries.len) return false;
    return cx.types.entries[app.type.int()].kind == .foreign;
}

/// The P2 scheme of this module's `foreign` value `name`, or null.
fn extractorScheme(cx: *const Context, decl_scheme: []const Var.Optional, name: Symbol) ?Var {
    for (cx.bir.decls, 0..) |d, j| {
        if (d.kind != .foreign_value or cx.bir.symbol(d.name) != name) continue;
        return decl_scheme[j].unwrap();
    }
    return null;
}

/// `E -> P`, `E` a `foreign type` and `P` the declared payload.
fn extractorFits(cx: *const Context, scheme: Var, payload: Var) bool {
    if (isErr(cx, scheme)) return true;
    const func = Walk.function(cx.store, scheme) orelse return false;
    if (func.params.len != 1) return false;
    if (!isForeignType(cx, func.params[0])) return false;
    return sameType(cx, func.result, payload, 0);
}

/// Whether two written types are one type, aliases looked through. The
/// payload types a vocabulary declares hold no type variables, so this is
/// structural equality over applications, tuples, functions and `()`.
fn sameType(cx: *const Context, a: Var, b: Var, depth: u32) bool {
    if (depth > 64) return false;
    const ca = cx.store.resolvedContent(a);
    const cb = cx.store.resolvedContent(b);
    if (ca == .err or cb == .err) return true;
    const sa = switch (ca) {
        .structure => |s| s,
        else => return false,
    };
    const sb = switch (cb) {
        .structure => |s| s,
        else => return false,
    };
    return switch (sa) {
        .unit => sb == .unit,
        .app => |x| switch (sb) {
            .app => |y| x.type == y.type and allSame(cx, Walk.positions(cx.store, a), Walk.positions(cx.store, b), depth),
            else => false,
        },
        .tuple => switch (sb) {
            .tuple => allSame(cx, Walk.positions(cx.store, a), Walk.positions(cx.store, b), depth),
            else => false,
        },
        .func => switch (sb) {
            .func => {
                const x = Walk.function(cx.store, a).?;
                const y = Walk.function(cx.store, b).?;
                return allSame(cx, x.params, y.params, depth) and sameType(cx, x.result, y.result, depth + 1);
            },
            else => false,
        },
        else => false,
    };
}

fn allSame(cx: *const Context, xs: []const Var, ys: []const Var, depth: u32) bool {
    if (xs.len != ys.len) return false;
    for (xs, ys) |x, y| {
        if (!sameType(cx, x, y, depth + 1)) return false;
    }
    return true;
}

/// Whether the markup type occurs anywhere in `v`, after aliases: in an
/// argument, an element, a parameter or result, a record field, or inside
/// a named type — a constructor's payload, another type's body — which
/// `Types.Entry.holds_markup` answers for every type at once. Each node is
/// visited once, so a type whose expansion is exponentially wide costs its
/// size in the store, and the walk always finishes: there is no budget
/// that could answer "no" for a type it did not see.
pub fn mentionsType(cx: *const Context, v: Var, t: MarkupType) Error!bool {
    const store = cx.store;
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(cx.scratch);
    try stack.append(cx.scratch, v);
    const seen = store.nextMark();
    while (stack.pop()) |at| {
        const root = store.find(at);
        if (store.mark(root) == seen) continue;
        store.setMark(root, seen);
        switch (store.content(root)) {
            .structure => |s| if (s == .app) {
                if (cx.types.named(s.app.type)) |n| {
                    if (n.module == t.module and n.name == t.name) return true;
                }
                if (cx.types.entry(s.app.type).holds_markup) return true;
            },
            else => {},
        }
        // An alias's expansion, not the arguments it may drop.
        var n: u32 = 0;
        while (Walk.child(store, root, n, .payload)) |c| : (n += 1) try stack.append(cx.scratch, c);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Two declarations that answer the same names
// ---------------------------------------------------------------------------

/// A markup name as §11.14's precedence reads it: exact, or a pattern in
/// which each `*` matches a non-empty run of characters.
const Name = struct {
    text: []const u8,
    pattern: bool,

    fn of(t: []const u8) Name {
        return .{ .text = t, .pattern = std.mem.indexOfScalar(u8, t, '*') != null };
    }

    /// Whether the two names tie under the precedence rule: two exact names
    /// of one text, or two patterns with literal parts of one length that
    /// some name matches both of.
    fn ties(a: Name, b: Name, scratch: Allocator) Error!bool {
        if (!a.pattern or !b.pattern) return !a.pattern and !b.pattern and std.mem.eql(u8, a.text, b.text);
        if (literalLen(a.text) != literalLen(b.text)) return false;
        return patternsMeet(scratch, a.text, b.text);
    }
};

/// The length of a pattern's literal part: its characters that are not
/// `*`. Of two patterns that match a name, the longer literal part wins.
pub fn literalLen(pattern: []const u8) usize {
    return pattern.len - std.mem.count(u8, pattern, "*");
}

/// Whether the pattern matches `name`, each `*` a non-empty run of
/// characters; a `*` in `name` is an ordinary character. A `*` is one
/// character followed by a zero-or-more wildcard, and the classic greedy
/// match needs only the last such wildcard as its backtrack point: no
/// allocation, and time bounded by the lengths' product.
pub fn nameMatches(pattern: []const u8, name: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    var back: ?usize = null; // the pattern index after the last `*`
    var back_j: usize = 0; // where that `*`'s run ends so far
    while (j < name.len) {
        if (i < pattern.len and pattern[i] == '*') {
            i += 1;
            j += 1;
            back = i;
            back_j = j;
        } else if (i < pattern.len and pattern[i] == name[j]) {
            i += 1;
            j += 1;
        } else if (back) |b| {
            back_j += 1;
            j = back_j;
            i = b;
        } else return false;
    }
    // A `*` left over would need a character, and none is left.
    return i == pattern.len;
}

/// Whether some name matches both patterns: a search over pairs of
/// positions, each `*` read as one character then zero or more.
fn patternsMeet(scratch: Allocator, a: []const u8, b: []const u8) Error!bool {
    const xa = try expand(scratch, a);
    const xb = try expand(scratch, b);
    const width = xb.len + 1;
    var seen = try std.DynamicBitSetUnmanaged.initEmpty(scratch, (xa.len + 1) * width);
    var stack: std.ArrayList([2]usize) = .empty;
    try stack.append(scratch, .{ 0, 0 });
    while (stack.pop()) |at| {
        const i = at[0];
        const j = at[1];
        if (seen.isSet(i * width + j)) continue;
        seen.set(i * width + j);
        if (i == xa.len and j == xb.len) return true;
        if (i < xa.len and xa[i] == many) try stack.append(scratch, .{ i + 1, j });
        if (j < xb.len and xb[j] == many) try stack.append(scratch, .{ i, j + 1 });
        if (i == xa.len or j == xb.len) continue;
        const ca = xa[i];
        const cb = xb[j];
        if (ca == many and cb == many) continue; // a character, and no progress
        if (ca < one and cb < one and ca != cb) continue;
        try stack.append(scratch, .{ if (ca == many) i else i + 1, if (cb == many) j else j + 1 });
    }
    return false;
}

const one: u16 = 256;
const many: u16 = 257;

/// A pattern as positions: a character, or for each `*` a `one` then a
/// `many`.
fn expand(scratch: Allocator, t: []const u8) Error![]const u16 {
    var out: std.ArrayList(u16) = .empty;
    for (t) |c| {
        if (c == '*') {
            try out.appendSlice(scratch, &.{ one, many });
        } else try out.append(scratch, c);
    }
    return out.items;
}

test nameMatches {
    try std.testing.expect(nameMatches("*-*", "my-widget"));
    try std.testing.expect(nameMatches("*-*", "a-b-c"));
    try std.testing.expect(!nameMatches("*-*", "widget"));
    try std.testing.expect(!nameMatches("*-*", "-x"));
    try std.testing.expect(!nameMatches("*-*", "x-"));
    try std.testing.expect(nameMatches("data-*", "data-row-id"));
    try std.testing.expect(!nameMatches("data-*", "data-"));
    try std.testing.expect(nameMatches("a*b*c", "axbbyc"));
    try std.testing.expect(!nameMatches("a*b*c", "abxc"));
}

test patternsMeet {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try patternsMeet(a, "x-*", "*-y"));
    try std.testing.expect(try patternsMeet(a, "*-*", "x*"));
    try std.testing.expect(!try patternsMeet(a, "x-*", "y-*"));
    try std.testing.expect(!try patternsMeet(a, "a-*", "b*"));
    try std.testing.expect(!try patternsMeet(a, "a*", "a"));
}

/// Two declarations of one namespace — elements; attributes and events
/// together — whose names tie and whose `on` sets overlap are
/// `duplicate_declaration`, at the later one (§25.2).
fn duplicates(cx: *const Context, report: *Report) Error!void {
    const bir = cx.bir;
    for (bir.decls, 0..) |d, i| {
        if (!inNamespace(d.kind)) continue;
        const name = Name.of(text(cx, bir.symbol(d.name)));
        for (bir.decls[0..i]) |e| {
            if (!inNamespace(e.kind) or namespaceOf(e.kind) != namespaceOf(d.kind)) continue;
            if (!try name.ties(Name.of(text(cx, bir.symbol(e.name))), cx.scratch)) continue;
            if (!onOverlap(bir, d, e)) continue;
            report.at(@intCast(i));
            try fail(cx, report, @intCast(i), .duplicate_declaration,
                \\`{s}` is declared twice: the {s} `{s}` above answers the same names on the
                \\same elements.
                \\
                \\Of two declarations that could answer a name, the exact one wins, then the
                \\pattern with the longer literal part (`docs/design/language.md` §11.14); these
                \\two tie, so which one answered would be arbitrary.
            , .{ name.text, formName(e.kind), text(cx, bir.symbol(e.name)) });
            break;
        }
    }
}

fn inNamespace(k: Bir.Decl.Kind) bool {
    return k == .vocab_element or k == .vocab_attribute or k == .vocab_event;
}

fn namespaceOf(k: Bir.Decl.Kind) u1 {
    return if (k == .vocab_element) 0 else 1;
}

fn formName(k: Bir.Decl.Kind) []const u8 {
    return switch (k) {
        .vocab_element => "element",
        .vocab_attribute => "attribute",
        else => "event",
    };
}

/// Whether two declarations' `on` sets share an element; no `on` is every
/// element.
fn onOverlap(bir: *const Bir, a: Bir.Decl, b: Bir.Decl) bool {
    var a_any = false;
    var b_any = false;
    for (facts(bir, a)) |f| a_any = a_any or f.word == .on;
    for (facts(bir, b)) |f| b_any = b_any or f.word == .on;
    if (!a_any or !b_any) return true;
    for (facts(bir, a)) |f| {
        if (f.word != .on or f.arg == .none) continue;
        for (facts(bir, b)) |g| {
            if (g.word == .on and g.arg != .none and bir.symbol(g.arg) == bir.symbol(f.arg)) return true;
        }
    }
    return false;
}
