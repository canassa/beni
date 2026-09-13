//! Types as text (docs/design/checker.md §8.2).
//!
//! One renderer serves the diagnostics AND both dumps, which is the point:
//! every type string a message can print is corpus-tested through
//! `dump --stage=types` and `--stage=interface`, so the goldens double as
//! the test for the prose.
//!
//! **Names are allocated per diagnostic, on the error path only.** A
//! variable has no name in the store — naming one costs an allocation and
//! the happy path must not pay it (`fast-compiler.md` §7, research/02 §6).
//! A `Namer` is created when a message is being written, hands out `a`, `b`,
//! … in order of FIRST APPEARANCE, and is shared by the two types of one
//! message so "expected `a -> a`, got `a -> b`" means what it looks like.
//! A variable that carries a name — a rigid from an annotation, or the flex
//! copy instantiation made of one — keeps it, because the whole value of
//! `rigid_mismatch`'s prose is being able to say *your annotation called it
//! `msg`*.
//!
//! **Kinds print as themselves.** A `number` variable prints `number`, an
//! `appendable` one `appendable`: they are not `a`, and a message that
//! called them `a` would be lying about why the unification failed.
//!
//! **Aliases print by name.** The store never expands one (checker.md §5),
//! so `Model` prints as `Model` and not as the record behind it — which is
//! the entire reason aliases are interned rather than substituted away.
//!
//! Parentheses are minimal: `a -> b -> c` right-associates so only a
//! function in ARGUMENT position needs them, and an application needs them
//! only when it is itself an argument and takes arguments of its own.
//!
//! **Patterns are rendered here too** (`writePattern`), for
//! `missing_patterns`' counterexamples (checker.md §6.6). They live next to
//! the type renderer for the same reason the type renderer exists once: a
//! message and a dump must spell the same value the same way, and the only
//! way to keep two printers agreeing is not to have two. The output is
//! SOURCE SYNTAX — `Just _`, `[]`, `( Nothing, _ )`, `x :: xs` — so an
//! example can be pasted into the `case` as a branch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Exhaustive = @import("Exhaustive.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");

const Render = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;

/// How tightly the surrounding context binds, so parentheses are added only
/// where they change the reading.
pub const Prec = enum {
    /// Nothing around it: `a -> b` needs no parentheses.
    top,
    /// Left of an arrow, or an argument of an application.
    arg,
    /// An argument of an application: even a bare application needs
    /// parentheses (`Maybe (List a)`).
    app_arg,
};

/// Fresh variable names for ONE message. Lives on the error path and
/// nowhere else.
pub const Namer = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// How many generated (`a`, `b`, …) names have been handed out.
    generated: u32 = 0,

    const Entry = struct { v: Var, text: []const u8 };

    pub fn init(gpa: Allocator) Namer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(n: *Namer) void {
        for (n.entries.items) |e| n.gpa.free(e.text);
        n.entries.deinit(n.gpa);
    }

    /// The name `v` prints as, allocating one the first time. `preferred`
    /// is the variable's own name or its kind, or null for a plain flex
    /// variable.
    pub fn name(n: *Namer, v: Var, preferred: ?[]const u8) Allocator.Error![]const u8 {
        for (n.entries.items) |e| {
            if (e.v == v) return e.text;
        }
        const text = try n.allocate(preferred);
        try n.entries.append(n.gpa, .{ .v = v, .text = text });
        return text;
    }

    fn allocate(n: *Namer, preferred: ?[]const u8) Allocator.Error![]const u8 {
        if (preferred) |p| {
            if (!n.taken(p)) return n.gpa.dupe(u8, p);
            var suffix: u32 = 2;
            while (suffix < 1000) : (suffix += 1) {
                const candidate = try std.fmt.allocPrint(n.gpa, "{s}{d}", .{ p, suffix });
                if (!n.taken(candidate)) return candidate;
                n.gpa.free(candidate);
            }
        }
        while (true) {
            const candidate = try generatedName(n.gpa, n.generated);
            n.generated += 1;
            if (!n.taken(candidate)) return candidate;
            n.gpa.free(candidate);
        }
    }

    fn taken(n: *const Namer, candidate: []const u8) bool {
        for (n.entries.items) |e| {
            if (std.mem.eql(u8, e.text, candidate)) return true;
        }
        return false;
    }
};

/// `a`, `b`, … `z`, then `a2`, `b2`, … — the same scheme
/// `dump/interface.zig` uses for a type's parameters, so the two dumps read
/// alike.
fn generatedName(gpa: Allocator, i: u32) Allocator.Error![]const u8 {
    const letters = "abcdefghijklmnopqrstuvwxyz";
    const letter = letters[i % letters.len];
    const round = i / letters.len;
    if (round == 0) return gpa.dupe(u8, &.{letter});
    return std.fmt.allocPrint(gpa, "{c}{d}", .{ letter, round + 1 });
}

/// Everything the renderer needs that is not the variable itself.
pub const Context = struct {
    store: *TypeStore,
    types: *const Types,
    interner: *const InternPool.Global,
};

/// Write the type of `v`.
pub fn writeVar(
    w: *std.Io.Writer,
    cx: Context,
    namer: *Namer,
    v: Var,
    prec: Prec,
) (std.Io.Writer.Error || Allocator.Error)!void {
    return write(w, cx, namer, v, prec, 0);
}

/// A whole scheme, which at this point is just its body: the quantifiers
/// are implicit in beni's surface syntax and printing `∀` would be noise.
pub fn writeScheme(w: *std.Io.Writer, cx: Context, namer: *Namer, v: Var) (std.Io.Writer.Error || Allocator.Error)!void {
    return write(w, cx, namer, v, .top, 0);
}

/// A type rendered into a freshly allocated string. For the diagnostics,
/// which build prose out of pieces.
pub fn allocType(gpa: Allocator, cx: Context, namer: *Namer, v: Var) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    write(&out.writer, cx, namer, v, .top, 0) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return out.toOwnedSlice();
}

/// The depth at which a type stops being readable anyway. An `infinite_type`
/// is reported separately; this is what keeps a poisoned cycle from filling
/// stderr.
const max_depth = 24;

fn write(
    w: *std.Io.Writer,
    cx: Context,
    namer: *Namer,
    v: Var,
    prec: Prec,
    depth: u32,
) (std.Io.Writer.Error || Allocator.Error)!void {
    if (depth > max_depth) return w.writeAll("…");
    const root = cx.store.find(v);
    switch (cx.store.content(root)) {
        .err => try w.writeAll("?"),
        .flex, .rigid => |flags| {
            const preferred: ?[]const u8 = if (flags.name.unwrap()) |s|
                cx.interner.slice(s)
            else if (flags.kind != .any)
                flags.kind.text()
            else
                null;
            try w.writeAll(try namer.name(root, preferred));
        },
        .alias => |a| try writeNamed(w, cx, namer, a.type, cx.store.vars(a.args), prec, depth),
        .structure => |s| switch (s) {
            .unit => try w.writeAll("()"),
            // A bare extension variable that closed: only reachable as a
            // record's tail, where `writeRecord` handles it.
            .empty_record => try w.writeAll("{}"),
            .func => |f| {
                const wrap = prec != .top;
                if (wrap) try w.writeByte('(');
                try write(w, cx, namer, f.param, .arg, depth + 1);
                try w.writeAll(" -> ");
                // The result stays at `top`, which is what makes
                // `a -> b -> c` right-associate with no parentheses.
                try write(w, cx, namer, f.result, .top, depth + 1);
                if (wrap) try w.writeByte(')');
            },
            .app => |a| try writeNamed(w, cx, namer, a.type, cx.store.vars(a.args), prec, depth),
            .tuple => |range| {
                try w.writeAll("( ");
                for (cx.store.vars(range), 0..) |el, i| {
                    if (i != 0) try w.writeAll(", ");
                    try write(w, cx, namer, el, .top, depth + 1);
                }
                try w.writeAll(" )");
            },
            .record => |r| try writeRecord(w, cx, namer, r, depth),
        },
    }
}

fn writeNamed(
    w: *std.Io.Writer,
    cx: Context,
    namer: *Namer,
    id: TypeStore.TypeId,
    args: []const Var,
    prec: Prec,
    depth: u32,
) (std.Io.Writer.Error || Allocator.Error)!void {
    if (id == .none) return w.writeAll("?");
    const text = cx.interner.slice(cx.types.name(id));
    if (args.len == 0) return w.writeAll(text);
    const wrap = prec == .app_arg;
    if (wrap) try w.writeByte('(');
    try w.writeAll(text);
    for (args) |arg| {
        try w.writeByte(' ');
        try write(w, cx, namer, arg, .app_arg, depth + 1);
    }
    if (wrap) try w.writeByte(')');
}

fn writeRecord(
    w: *std.Io.Writer,
    cx: Context,
    namer: *Namer,
    record: TypeStore.Structure.Record,
    depth: u32,
) (std.Io.Writer.Error || Allocator.Error)!void {
    // Flatten the extension chain: a record whose tail is another record is
    // one record, exactly as unification sees it (`gatherFields`).
    var collected: std.ArrayList(TypeStore.Field) = .empty;
    defer collected.deinit(namer.gpa);
    var tail = record.ext;
    try collected.appendSlice(namer.gpa, cx.store.fields(record.fields));
    var guard: u32 = 0;
    const open: ?Var = while (guard < 64) : (guard += 1) {
        const root, const c = cx.store.resolved(tail);
        switch (c) {
            .structure => |s| switch (s) {
                .empty_record => break null,
                .record => |r| {
                    try collected.appendSlice(namer.gpa, cx.store.fields(r.fields));
                    tail = r.ext;
                },
                else => break root,
            },
            else => break root,
        }
    } else null;

    // Sorted by the field's TEXT, never by its symbol id: an id depends on
    // which worker interned which file (`InternPool`'s header), and a
    // diagnostic may not depend on `--jobs`.
    const Sorter = struct {
        interner: *const InternPool.Global,
        fn lessThan(s: @This(), a: TypeStore.Field, b: TypeStore.Field) bool {
            return std.mem.lessThan(u8, s.interner.slice(a.name), s.interner.slice(b.name));
        }
    };
    std.mem.sort(TypeStore.Field, collected.items, Sorter{ .interner = cx.interner }, Sorter.lessThan);

    if (collected.items.len == 0 and open == null) return w.writeAll("{}");
    try w.writeAll("{ ");
    if (open) |ext| {
        // An open record prints its extension variable, so two `{ r | … }`
        // in one message are visibly the same `r` or visibly not.
        switch (cx.store.content(cx.store.find(ext))) {
            .flex, .rigid => |flags| {
                const preferred: ?[]const u8 = if (flags.name.unwrap()) |s| cx.interner.slice(s) else "r";
                try w.writeAll(try namer.name(cx.store.find(ext), preferred));
            },
            else => try w.writeAll("?"),
        }
        try w.writeAll(" | ");
    }
    for (collected.items, 0..) |f, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{s} : ", .{cx.interner.slice(f.name)});
        try write(w, cx, namer, f.value, .top, depth + 1);
    }
    try w.writeAll(" }");
}

// ---------------------------------------------------------------------------
// Patterns (checker.md §6.6)
// ---------------------------------------------------------------------------

/// Where a pattern sits, so parentheses appear only where they change the
/// reading — Elm's three `Reporting/Error/Pattern.hs` contexts.
pub const PatPrec = enum {
    /// A whole branch pattern: nothing needs wrapping.
    top,
    /// An argument of a constructor: `Just (Node a b)`, `Just (x :: xs)`.
    arg,
    /// Left of a `::`: `(a :: b) :: c`.
    head,
};

/// A counterexample pattern rendered into a freshly allocated string, for
/// `missing_patterns`' list.
pub fn allocPattern(
    gpa: Allocator,
    pats: *const Exhaustive.Patterns,
    interner: *const InternPool.Global,
    p: Exhaustive.PatIndex,
) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    writePattern(&out.writer, pats, interner, p, .top) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return out.toOwnedSlice();
}

/// Write one simplified pattern as source syntax.
pub fn writePattern(
    w: *std.Io.Writer,
    pats: *const Exhaustive.Patterns,
    interner: *const InternPool.Global,
    p: Exhaustive.PatIndex,
    prec: PatPrec,
) (std.Io.Writer.Error || Allocator.Error)!void {
    return writePat(w, pats, interner, p, prec, 0);
}

fn writePat(
    w: *std.Io.Writer,
    pats: *const Exhaustive.Patterns,
    interner: *const InternPool.Global,
    p: Exhaustive.PatIndex,
    prec: PatPrec,
    depth: u32,
) (std.Io.Writer.Error || Allocator.Error)!void {
    if (depth > max_depth) return w.writeAll("…");
    switch (pats.tag(p)) {
        .anything => return w.writeAll("_"),
        .literal => return writeLiteral(w, pats, pats.literal(p)),
        .ctor => {},
    }
    const c = pats.ctor(p);
    const args = pats.args(c);
    const un = pats.unionAt(c.un);
    switch (un.shape) {
        .unit => return w.writeAll("()"),
        .tuple => {
            try w.writeAll("( ");
            for (args, 0..) |arg, i| {
                if (i != 0) try w.writeAll(", ");
                try writePat(w, pats, interner, arg, .top, depth + 1);
            }
            return w.writeAll(" )");
        },
        // A list is `[]`/`::` in the algorithm and two different things on
        // the page: a spine that ends in `[]` is a literal list, one that
        // ends in anything else is a `::` chain (Elm's `delist`).
        .list => return writeList(w, pats, interner, p, prec, depth),
        .adt => {
            const name = if (c.alt < pats.alts.items.len) pats.alt(c.alt).name.unwrap() else null;
            const text = if (name) |sym| interner.slice(sym) else "?";
            if (args.len == 0) return w.writeAll(text);
            // An argument-taking constructor needs parentheses anywhere but
            // at the top: `Just (Node a b)`.
            const wrap = prec != .top;
            if (wrap) try w.writeByte('(');
            try w.writeAll(text);
            for (args) |arg| {
                try w.writeByte(' ');
                try writePat(w, pats, interner, arg, .arg, depth + 1);
            }
            if (wrap) try w.writeByte(')');
        },
    }
}

/// `[]`, `[ a, b ]` or `a :: rest`, walking the cons spine iteratively —
/// the spine of a missing-pattern example is as long as the source's
/// longest list pattern and does not belong on the stack.
fn writeList(
    w: *std.Io.Writer,
    pats: *const Exhaustive.Patterns,
    interner: *const InternPool.Global,
    p: Exhaustive.PatIndex,
    prec: PatPrec,
    depth: u32,
) (std.Io.Writer.Error || Allocator.Error)!void {
    // Collect the heads; `tail` ends on `[]` (a finite list) or on anything
    // else (a `::` chain).
    var heads: [max_depth]Exhaustive.PatIndex = undefined;
    var count: usize = 0;
    var tail = p;
    while (count < heads.len) {
        if (pats.tag(tail) != .ctor) break;
        const c = pats.ctor(tail);
        if (pats.unionAt(c.un).shape != .list) break;
        if (c.args_len != 2) break; // `[]`
        const cons = pats.args(c);
        heads[count] = cons[0];
        count += 1;
        tail = cons[1];
    }
    const finite = pats.tag(tail) == .ctor and
        pats.unionAt(pats.ctor(tail).un).shape == .list and
        pats.ctor(tail).args_len == 0;

    if (finite) {
        if (count == 0) return w.writeAll("[]");
        try w.writeAll("[ ");
        for (heads[0..count], 0..) |h, i| {
            if (i != 0) try w.writeAll(", ");
            try writePat(w, pats, interner, h, .top, depth + 1);
        }
        return w.writeAll(" ]");
    }
    const wrap = prec != .top;
    if (wrap) try w.writeByte('(');
    for (heads[0..count]) |h| {
        try writePat(w, pats, interner, h, .head, depth + 1);
        try w.writeAll(" :: ");
    }
    try writePat(w, pats, interner, tail, .top, depth + 1);
    if (wrap) try w.writeByte(')');
}

fn writeLiteral(
    w: *std.Io.Writer,
    pats: *const Exhaustive.Patterns,
    lit: Exhaustive.Literal,
) std.Io.Writer.Error!void {
    switch (lit.kind) {
        .int => if (lit.parsed) try w.print("{d}", .{lit.value}) else try w.writeAll(pats.bytesOf(lit)),
        .char => {
            try w.writeByte('\'');
            try writeEscaped(w, @intCast(lit.value), '\'');
            try w.writeByte('\'');
        },
        .string => {
            try w.writeByte('"');
            var it = std.unicode.Utf8View.initUnchecked(pats.bytesOf(lit)).iterator();
            while (it.nextCodepoint()) |cp| try writeEscaped(w, cp, '"');
            try w.writeByte('"');
        },
    }
}

/// One scalar, re-escaped the way the lexer would accept it back
/// (language.md §2.6). `quote` is the delimiter that has to be escaped.
fn writeEscaped(w: *std.Io.Writer, cp: u21, quote: u8) std.Io.Writer.Error!void {
    if (cp < 0x20 or cp == 0x7f) return switch (cp) {
        '\t' => w.writeAll("\\t"),
        '\n' => w.writeAll("\\n"),
        '\r' => w.writeAll("\\r"),
        else => w.print("\\u{{{x:0>4}}}", .{cp}),
    };
    if (cp == quote) return w.print("\\{c}", .{quote});
    if (cp == '\\') return w.writeAll("\\\\");
    var buffer: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buffer) catch return w.writeAll("?");
    return w.writeAll(buffer[0..len]);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "generated names run a..z then a2, b2, …" {
    const gpa = testing.allocator;
    for ([_]struct { u32, []const u8 }{
        .{ 0, "a" }, .{ 1, "b" }, .{ 25, "z" }, .{ 26, "a2" }, .{ 27, "b2" }, .{ 52, "a3" },
    }) |case| {
        const got = try generatedName(gpa, case[0]);
        defer gpa.free(got);
        try testing.expectEqualStrings(case[1], got);
    }
}

test "a namer keeps one name per variable and never repeats a name" {
    const gpa = testing.allocator;
    var namer: Namer = .init(gpa);
    defer namer.deinit();
    const a: Var = @enumFromInt(0);
    const b: Var = @enumFromInt(1);
    const c: Var = @enumFromInt(2);
    try testing.expectEqualStrings("a", try namer.name(a, null));
    try testing.expectEqualStrings("a", try namer.name(a, null));
    try testing.expectEqualStrings("b", try namer.name(b, null));
    // A preferred name wins, and a clash with it is disambiguated rather
    // than silently reused: two different variables must never print alike.
    try testing.expectEqualStrings("msg", try namer.name(c, "msg"));
    const d: Var = @enumFromInt(3);
    try testing.expectEqualStrings("msg2", try namer.name(d, "msg"));
    const e: Var = @enumFromInt(4);
    try testing.expectEqualStrings("c", try namer.name(e, null));
}
