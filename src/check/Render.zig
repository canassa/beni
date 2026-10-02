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
//! SOURCE SYNTAX — `Just _`, `[]`, `( Nothing, _ )`, `[ x, ..._ ]` — so an
//! example can be pasted into the `case` as a branch.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const Exhaustive = @import("Exhaustive.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");
const Effects = @import("Effects.zig");

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
    /// An operand of a product (language.md §12.8): a function and another
    /// product need parentheses, an application does not
    /// (`Maybe a × (b × c)`).
    operand,
};

/// Fresh variable names for ONE message. Lives on the error path and
/// nowhere else.
pub const Namer = struct {
    gpa: Allocator,
    /// What each variable that has been named prints as. Borrows the text
    /// from `names`, which owns it.
    by_var: std.AutoHashMapUnmanaged(Var, []const u8) = .empty,
    /// Every name handed out, so a candidate is rejected in O(1) instead of
    /// by a walk of the whole message. Owns the text.
    names: std.StringHashMapUnmanaged(void) = .empty,
    /// The next suffix worth trying for a stem whose bare form is already
    /// taken. A suffix, once handed out, is taken for the rest of the
    /// message, so a stem never has to re-walk the run it already spent:
    /// `number65` costs one probe rather than sixty-four. Keys borrow the
    /// `names` key that spells the stem, which is why the stem itself is
    /// never allocated twice.
    next_suffix: std.StringHashMapUnmanaged(u32) = .empty,
    /// How many generated (`a`, `b`, …) names have been handed out.
    generated: u32 = 0,
    /// How many type nodes this message may still print (`checker.md` §8.2's
    /// third bound). Past it a node prints `…`. A diagnostic's type is
    /// printed as a TREE, so a shared or cyclic graph — `x = ( x, x )`, a
    /// doubling `let` — would print 2^24 leaves under `max_depth` alone,
    /// hundreds of megabytes for a two-line program. The dumps, whose output is a
    /// type's whole text, set it to `unlimited`.
    budget: u32 = message_budget,
    /// The roots being printed, outermost first: a node met again
    /// inside itself is a CYCLE, printed `…` there rather than unrolled
    /// until `budget` runs out, which would print `x = ( x, x )` as 4 096
    /// nodes of tuple. Never deeper than `max_depth`, so it is inline.
    path: [max_depth + 2]Var = undefined,
    path_len: u32 = 0,
    /// The types this message prints with their module's name
    /// (`qualifyClashes`): two distinct types, or aliases, of one name.
    qualified: std.AutoHashMapUnmanaged(TypeStore.TypeId, void) = .empty,

    pub const message_budget: u32 = 4096;
    pub const unlimited: u32 = std.math.maxInt(u32);

    pub fn init(gpa: Allocator) Namer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(n: *Namer) void {
        n.qualified.deinit(n.gpa);
        // Before the texts: a stem key points into one of them.
        n.next_suffix.deinit(n.gpa);
        n.by_var.deinit(n.gpa);
        var it = n.names.keyIterator();
        while (it.next()) |text| n.gpa.free(text.*);
        n.names.deinit(n.gpa);
    }

    /// The name `v` prints as, allocating one the first time. `preferred`
    /// is the variable's own name or its kind, or null for a plain flex
    /// variable.
    pub fn name(n: *Namer, v: Var, preferred: ?[]const u8) Allocator.Error![]const u8 {
        if (n.by_var.get(v)) |text| return text;
        try n.by_var.ensureUnusedCapacity(n.gpa, 1);
        const text = try n.allocate(preferred);
        errdefer n.gpa.free(text);
        try n.names.put(n.gpa, text, {});
        n.by_var.putAssumeCapacity(v, text);
        return text;
    }

    fn allocate(n: *Namer, preferred: ?[]const u8) Allocator.Error![]const u8 {
        if (preferred) |p| {
            if (!n.taken(p)) return n.gpa.dupe(u8, p);
            // `p` is taken, so `names` holds a copy of it whose bytes
            // outlive every suffix search; key the counter by that.
            const stem = n.names.getKey(p).?;
            const slot = try n.next_suffix.getOrPut(n.gpa, stem);
            if (!slot.found_existing) slot.value_ptr.* = 2;
            while (slot.value_ptr.* < 1000) {
                const suffix = slot.value_ptr.*;
                slot.value_ptr.* += 1;
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
        return n.names.contains(candidate);
    }
};

/// `a`, `b`, … `z`, then `a2`, `b2`, … — the names an unnamed variable gets.
/// `pub` because `dump/interface.zig` spells a type's parameters with it:
/// there is ONE generated-name scheme in the compiler, so the two dumps
/// cannot drift apart the way a second copy of this would.
pub fn generatedName(gpa: Allocator, i: u32) Allocator.Error![]const u8 {
    const letters = "abcdefghijklmnopqrstuvwxyz";
    const letter = letters[i % letters.len];
    const round = i / letters.len;
    if (round == 0) return gpa.dupe(u8, &.{letter});
    return std.fmt.allocPrint(gpa, "{c}{d}", .{ letter, round + 1 });
}

/// What a flex or rigid variable prefers to print as (checker.md §8.7,
/// its own name when it has one that agrees with its kind, else its
/// kind, else nothing (a generated `a`, `b`, …). A name that does not start
/// with the kind's text was inherited through unification — `cons`'s `a`
/// merged with a literal's `number` — and printing it would hide the kind
/// the message is about. `Schemes.Writer` publishes a name by the same rule
/// (`nameAgreesWithKind`).
pub fn preferredName(interner: *const InternPool.Global, flags: TypeStore.Flags) ?[]const u8 {
    if (flags.name.unwrap()) |s| {
        const text = interner.slice(s);
        if (nameAgreesWithKind(text, flags.kind)) return text;
    }
    return if (flags.kind != .any) flags.kind.text() else null;
}

/// Whether a variable named `text` may keep that name at `kind`.
pub fn nameAgreesWithKind(text: []const u8, kind: TypeStore.Kind) bool {
    return kind == .any or std.mem.startsWith(u8, text, kind.text());
}

/// Everything the renderer needs that is not the variable itself.
pub const Context = struct {
    store: *TypeStore,
    types: *const Types,
    interner: *const InternPool.Global,
    /// The dumps' effect classes (transparent-effects-proposal.md §14.7):
    /// each function type and function-holding application prints its
    /// class after it. Null in every diagnostic, whose text never shows one.
    effects: ?*Effects.View = null,
};

/// The class `v` prints after it (§14.7), owned by the caller, or null for
/// none.
fn effectSuffix(cx: Context, v: Var) Allocator.Error!?[]u8 {
    const view = cx.effects orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(view.gpa);
    try view.suffix(cx.store, v, &out);
    if (out.items.len == 0) {
        out.deinit(view.gpa);
        return null;
    }
    return try out.toOwnedSlice(view.gpa);
}

/// Mark for qualification (`Namer.qualified`) every named type in `roots`
/// that shares its name with a different one there: `T` against `T` from two
/// modules prints `Main.T` against `Shapes.T`. Only what a message prints is
/// walked — an alias's arguments, never its expansion — each node once, and
/// no more of them than a message prints.
pub fn qualifyClashes(namer: *Namer, cx: Context, roots: []const Var) Allocator.Error!void {
    const gpa = namer.gpa;
    var seen: std.AutoHashMapUnmanaged(Var, void) = .empty;
    defer seen.deinit(gpa);
    var by_name: std.AutoHashMapUnmanaged(Symbol, TypeStore.TypeId) = .empty;
    defer by_name.deinit(gpa);
    var stack: std.ArrayList(Var) = .empty;
    defer stack.deinit(gpa);
    try stack.appendSlice(gpa, roots);
    var budget: u32 = Namer.message_budget;
    while (stack.pop()) |next| {
        if (budget == 0) break;
        budget -= 1;
        const root = cx.store.find(next);
        if ((try seen.getOrPut(gpa, root)).found_existing) continue;
        const named: ?struct { TypeStore.TypeId, []const Var } = switch (cx.store.content(root)) {
            .alias => |a| .{ a.type, cx.store.vars(a.args) },
            .structure => |s| switch (s) {
                .app => |a| .{ a.type, cx.store.vars(a.args) },
                .func => |f| blk: {
                    try stack.appendSlice(gpa, cx.store.vars(f.params));
                    try stack.append(gpa, f.result);
                    break :blk null;
                },
                .tuple => |range| blk: {
                    try stack.appendSlice(gpa, cx.store.vars(range));
                    break :blk null;
                },
                .record => |r| blk: {
                    for (cx.store.fields(r.fields)) |f| try stack.append(gpa, f.value);
                    try stack.append(gpa, r.ext);
                    break :blk null;
                },
                .unit, .empty_record => null,
            },
            .flex, .rigid, .err => null,
        };
        const id, const args = named orelse continue;
        try stack.appendSlice(gpa, args);
        if (id == .none) continue;
        const slot = try by_name.getOrPut(gpa, cx.types.name(id));
        if (!slot.found_existing) {
            slot.value_ptr.* = id;
        } else if (slot.value_ptr.* != id) {
            try namer.qualified.put(gpa, slot.value_ptr.*, {});
            try namer.qualified.put(gpa, id, {});
        }
    }
}

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

/// A whole scheme: its body, then the `where` clause its quantified
/// variables carry (static-dispatch-spike.md §6.6).
///
/// `writeVar` and `allocType` — which every diagnostic uses, because a
/// message builds prose out of type fragments rather than printing a scheme
/// — are deliberately NOT this and print no suffix. A constraint belongs to
/// a scheme, not to a type, and a two-type mismatch message is already the
/// busiest prose in the compiler.
///
/// The order is by variable name AS RENDERED, then by method name text: a
/// total order that is a function of the scheme and not of the store, which
/// is what `--jobs` determinism needs. The whole suffix is one line; the
/// FORMATTER breaks a `where` clause over continuation lines (§2.5) and the
/// two differ on purpose.
pub fn writeScheme(w: *std.Io.Writer, cx: Context, namer: *Namer, v: Var) (std.Io.Writer.Error || Allocator.Error)!void {
    try write(w, cx, namer, v, .top, 0);
    try writeWhere(w, cx, namer, v);
}

/// One rendered constraint, for the sort.
const Rendered = struct { variable: []const u8, method: []const u8, fn_var: Var };

/// The `where` suffix of `v`'s scheme, or nothing when no variable in it
/// carries a constraint.
pub fn writeWhere(w: *std.Io.Writer, cx: Context, namer: *Namer, v: Var) (std.Io.Writer.Error || Allocator.Error)!void {
    var roots: std.ArrayList(Var) = .empty;
    defer roots.deinit(namer.gpa);
    const mark = cx.store.nextMark();
    try collectVars(cx, v, &roots, namer.gpa, mark, 0);
    var items: std.ArrayList(Rendered) = .empty;
    defer items.deinit(namer.gpa);
    // By INDEX, and re-reading the length: a constraint's own type can
    // mention a variable the body never reaches, and naming it means
    // walking it — which appends. The same reason `Schemes.quantifierOrder`
    // drains its list rather than iterating a slice.
    var r: usize = 0;
    while (r < roots.items.len) : (r += 1) {
        const root = roots.items[r];
        const flags = cx.store.flagsOf(root);
        const n = cx.store.constraintCount(flags.constraints);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const c = cx.store.constraintAt(flags.constraints, i);
            try collectVars(cx, c.fn_var, &roots, namer.gpa, mark, 0);
            // The renderer's own name for the variable, so the suffix and
            // the body agree about which `a` this is.
            const preferred = preferredName(cx.interner, flags);
            const name = try namer.name(root, preferred);
            try items.append(namer.gpa, .{
                .variable = name,
                .method = cx.interner.slice(c.name),
                .fn_var = c.fn_var,
            });
        }
    }
    if (items.items.len == 0) return;
    std.mem.sort(Rendered, items.items, {}, renderedLessThan);
    try w.writeAll(" where ");
    for (items.items, 0..) |item, i| {
        if (i != 0) try w.writeAll(", ");
        try w.print("{s}.{s} : ", .{ item.variable, item.method });
        try write(w, cx, namer, item.fn_var, .top, 0);
    }
}

fn renderedLessThan(_: void, a: Rendered, b: Rendered) bool {
    return switch (std.mem.order(u8, a.variable, b.variable)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.method, b.method),
    };
}

/// Every variable reachable from `v`, in the order `write` names them, so
/// the `where` suffix uses the names the body already printed.
fn collectVars(
    cx: Context,
    v: Var,
    out: *std.ArrayList(Var),
    gpa: Allocator,
    mark: u32,
    depth: u32,
) (std.Io.Writer.Error || Allocator.Error)!void {
    if (depth > max_depth) return;
    const root = cx.store.find(v);
    if (cx.store.mark(root) == mark) return;
    cx.store.setMark(root, mark);
    switch (cx.store.content(root)) {
        .err => {},
        .flex, .rigid => try out.append(gpa, root),
        .structure => |flat| switch (flat) {
            .unit, .empty_record => {},
            .func => |f| {
                const params = try gpa.dupe(Var, cx.store.vars(f.params));
                defer gpa.free(params);
                for (params) |p| try collectVars(cx, p, out, gpa, mark, depth + 1);
                try collectVars(cx, f.result, out, gpa, mark, depth + 1);
            },
            .app => |a| {
                const args = try gpa.dupe(Var, cx.store.vars(a.args));
                defer gpa.free(args);
                for (args) |arg| try collectVars(cx, arg, out, gpa, mark, depth + 1);
            },
            .tuple => |t| {
                const items = try gpa.dupe(Var, cx.store.vars(t));
                defer gpa.free(items);
                for (items) |el| try collectVars(cx, el, out, gpa, mark, depth + 1);
            },
            .record => |r| {
                const fields = try gpa.dupe(TypeStore.Field, cx.store.fields(r.fields));
                defer gpa.free(fields);
                for (fields) |f| try collectVars(cx, f.value, out, gpa, mark, depth + 1);
                try collectVars(cx, r.ext, out, gpa, mark, depth + 1);
            },
        },
        .alias => |a| {
            const args = try gpa.dupe(Var, cx.store.vars(a.args));
            defer gpa.free(args);
            for (args) |arg| try collectVars(cx, arg, out, gpa, mark, depth + 1);
            try collectVars(cx, a.actual, out, gpa, mark, depth + 1);
        },
    }
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
///
/// Reaching it TRUNCATES the printed type to `…` and reports nothing extra,
/// which is right for a printer: the diagnostic that asked for this text
/// has already been decided, and the guard changes only how much of one
/// type the reader sees. A type 24 constructors deep is past the point
/// where more text helps, and a message that stopped short is strictly
/// better than one that scrolls a cycle off the screen.
const max_depth = 24;

fn write(
    w: *std.Io.Writer,
    cx: Context,
    namer: *Namer,
    v: Var,
    prec: Prec,
    depth: u32,
) (std.Io.Writer.Error || Allocator.Error)!void {
    // Truncation, not an error: the diagnostic stands, only this type's
    // tail is elided. See `max_depth`.
    if (depth > max_depth) return w.writeAll("…");
    if (namer.budget == 0) return w.writeAll("…");
    namer.budget -= 1;
    const root = cx.store.find(v);
    const content = cx.store.content(root);
    // A cycle is elided where it repeats (`Namer.path`). `depth` bounds the
    // path, so the push fits; the test is only a backstop.
    const pushed = (content == .alias or content == .structure) and namer.path_len < namer.path.len;
    if (pushed) {
        for (namer.path[0..namer.path_len]) |on| if (on == root) return w.writeAll("…");
        namer.path[namer.path_len] = root;
        namer.path_len += 1;
    }
    defer if (pushed) {
        namer.path_len -= 1;
    };
    switch (content) {
        .err => try w.writeAll("?"),
        .flex, .rigid => |flags| {
            const preferred = preferredName(cx.interner, flags);
            try w.writeAll(try namer.name(root, preferred));
        },
        .alias => |a| {
            const suffix = try effectSuffix(cx, root);
            defer if (suffix) |t| cx.effects.?.gpa.free(t);
            const wrap = suffix != null and prec != .top;
            if (wrap) try w.writeByte('(');
            try writeNamed(w, cx, namer, a.type, cx.store.vars(a.args), if (wrap) .top else prec, depth);
            if (suffix) |t| try w.writeAll(t);
            if (wrap) try w.writeByte(')');
        },
        .structure => |s| switch (s) {
            .unit => try w.writeAll("⊤"),
            // A bare extension variable that closed: only reachable as a
            // record's tail, where `writeRecord` handles it.
            .empty_record => try w.writeAll("{}"),
            // `A, B → C` with the minimal parentheses (checker.md §8.2):
            // a function-typed PARAMETER is always parenthesised, a
            // function-typed RESULT never is, and a 1-ary function over a
            // tuple prints `Int × Int → Int`, which reads differently from
            // the 2-ary `Int, Int → Int` because `×` is not a comma
            // (language.md §12.8).
            .func => |f| {
                const wrap = prec != .top;
                if (wrap) try w.writeByte('(');
                for (cx.store.vars(f.params), 0..) |param, i| {
                    if (i != 0) try w.writeAll(", ");
                    try write(w, cx, namer, param, .arg, depth + 1);
                }
                try w.writeAll(" → ");
                // The dumps' class of this arrow (§14.7 of
                // transparent-effects-proposal.md), printed after the result:
                // a function-typed result is then parenthesised, so its own
                // class cannot be read as this one.
                const suffix = try effectSuffix(cx, root);
                defer if (suffix) |t| cx.effects.?.gpa.free(t);
                // The result stays at `top`, which is what makes
                // `a, b -> c -> d` right-associate with no parentheses.
                const result_is_function = switch (cx.store.resolvedContent(f.result)) {
                    .structure => |r| r == .func,
                    else => false,
                };
                const result_prec: Prec = if (suffix != null and result_is_function) .arg else .top;
                try write(w, cx, namer, f.result, result_prec, depth + 1);
                if (suffix) |t| try w.writeAll(t);
                if (wrap) try w.writeByte(')');
            },
            .app => |a| {
                const suffix = try effectSuffix(cx, root);
                defer if (suffix) |t| cx.effects.?.gpa.free(t);
                const wrap = suffix != null and prec != .top;
                if (wrap) try w.writeByte('(');
                try writeNamed(w, cx, namer, a.type, cx.store.vars(a.args), if (wrap) .top else prec, depth);
                if (suffix) |t| try w.writeAll(t);
                if (wrap) try w.writeByte(')');
            },
            // `a × b` (language.md §12.8): parenthesised as a type
            // argument or an operand of another product and nowhere else —
            // not as a parameter, a result or a field. Its elements print at
            // `.operand`, which parenthesises a function and a product, so
            // the type is one the reader can paste back.
            .tuple => |range| {
                const wrap = prec == .app_arg or prec == .operand;
                if (wrap) try w.writeByte('(');
                for (cx.store.vars(range), 0..) |el, i| {
                    if (i != 0) try w.writeAll(" × ");
                    try write(w, cx, namer, el, .operand, depth + 1);
                }
                if (wrap) try w.writeByte(')');
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
    // Core's empty type is written `⊥` (language.md §12.10).
    if (id == cx.types.well_known.never) return w.writeAll("⊥");
    const text = cx.interner.slice(cx.types.name(id));
    const module: ?[]const u8 = if (namer.qualified.contains(id)) cx.interner.slice(cx.types.entry(id).module_name) else null;
    if (args.len == 0) {
        if (module) |m| try w.print("{s}.", .{m});
        return w.writeAll(text);
    }
    const wrap = prec == .app_arg;
    if (wrap) try w.writeByte('(');
    if (module) |m| try w.print("{s}.", .{m});
    try w.writeAll(text);
    for (args) |arg| {
        try w.writeByte(' ');
        try write(w, cx, namer, arg, .app_arg, depth + 1);
    }
    if (wrap) try w.writeByte(')');
}

/// How many extension links `writeRecord` follows before it stops. The
/// chain can be a cycle — an `infinite_type` is reported and then printed,
/// so the printer meets the poisoned type it is describing — and a record
/// past this width is unreadable anyway, which is `max_depth`'s argument
/// one axis over.
///
/// Stopping here TRUNCATES and says so. It does not close the record: an
/// open record printed closed is a different type, and a reader who pastes
/// it back gets a program that does not compile. See `Ext.elided`.
const max_ext_links = 64;

/// What sits at the end of a flattened extension chain.
const Ext = union(enum) {
    /// `{}`-terminated: the record is closed and the printed field list is
    /// all of it.
    closed,
    /// An extension variable: `{ r | … }`.
    open: Var,
    /// `max_ext_links` ran out before the tail was reached, so neither the
    /// remaining fields nor the tail is known. Prints `…` where the
    /// extension variable goes.
    elided,
};

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
    var links: u32 = 0;
    const ext: Ext = while (links < max_ext_links) : (links += 1) {
        const root, const c = cx.store.resolved(tail);
        switch (c) {
            .structure => |s| switch (s) {
                .empty_record => break .closed,
                .record => |r| {
                    try collected.appendSlice(namer.gpa, cx.store.fields(r.fields));
                    tail = r.ext;
                },
                else => break .{ .open = root },
            },
            else => break .{ .open = root },
        }
    } else .elided;

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

    if (collected.items.len == 0 and ext == .closed) return w.writeAll("{}");
    try w.writeAll("{ ");
    switch (ext) {
        .closed => {},
        // An open record prints its extension variable, so two `{ r | … }`
        // in one message are visibly the same `r` or visibly not.
        .open => |v| {
            switch (cx.store.content(cx.store.find(v))) {
                .flex, .rigid => |flags| {
                    const preferred: ?[]const u8 = if (flags.name.unwrap()) |s| cx.interner.slice(s) else "r";
                    try w.writeAll(try namer.name(cx.store.find(v), preferred));
                },
                else => try w.writeAll("?"),
            }
            try w.writeAll(" | ");
        },
        // `{ … | … }`: the chain ran past `max_ext_links`, so the rest of
        // the record — however many more fields, and whatever the tail
        // turns out to be — is elided. Never `{ … }`: a record whose
        // remainder was not read may not be printed closed (checker.md §8.2).
        .elided => try w.writeAll("… | "),
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
    /// An argument of a constructor: `Just (Node a b)`. A list is brackets
    /// and needs none, `Just [ x, ..._ ]`.
    arg,
};

/// A counterexample pattern rendered into a freshly allocated string, for
/// `missing_patterns`' list. See `writePattern` for what such a row can and
/// cannot contain.
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
///
/// **The rows this is called on are COUNTEREXAMPLES, never source
/// patterns.** The only caller is `allocPattern`, and the only caller of
/// that is `Exhaustive.one` on the rows `Exhaustive.isExhaustive` returned.
/// Those rows are built from `anythings()` and `makeCtor()` alone: every
/// row `isExhaustive` returns is either a fresh row of wildcards, or a
/// wildcard prepended to a row it built recursively, or a constructor made
/// here and prepended to one. A node of the input matrix — which is where a
/// `.literal` from `simplify` lives — is never carried into the result. So
/// `.literal` is a shape this printer cannot be handed, and it prints `_`
/// rather than a value it has no business decoding.
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
    // Truncation, not an error: `missing_patterns` still names the `case`
    // and still lists its examples, one of which is elided past this depth.
    // `writeList`'s `heads` buffer is sized by the same constant, so the
    // two agree on where an example stops.
    if (depth > max_depth) return w.writeAll("…");
    switch (pats.tag(p)) {
        .anything => return w.writeAll("_"),
        // Unreachable by the argument on `writePattern`. `_` rather than
        // `unreachable`, and rather than a literal printer that would have
        // to decode arbitrary bytes: a counterexample with `_` where a
        // literal would go is still a pattern that covers the missing case,
        // which is the one property the reader acts on.
        .literal => return w.writeAll("_"),
        .list => return writeList(w, pats, interner, p, depth),
        .ctor => {},
    }
    const c = pats.ctor(p);
    const args = pats.args(c);
    const un = pats.unionAt(c.un);
    switch (un.shape) {
        .unit => return w.writeAll("⊤"),
        .tuple => {
            try w.writeAll("( ");
            for (args, 0..) |arg, i| {
                if (i != 0) try w.writeAll(", ");
                try writePat(w, pats, interner, arg, .top, depth + 1);
            }
            return w.writeAll(" )");
        },
        .adt => {
            const name = if (c.alt < pats.alts.items.len) pats.alt(c.alt).name.unwrap() else null;
            const text = if (name) |sym| interner.slice(sym) else "?";
            if (args.len == 0) return w.writeAll(text);
            // An argument-taking constructor needs parentheses only as an
            // ARGUMENT: `Just (Node a b)`, never as a list item,
            // `[ Circle _, ..._ ]` (Elm's `patternToDoc`).
            const wrap = prec == .arg;
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

/// `[]`, `[ a, b ]`, `[ a, ..._ ]` or `[ ..._, z ]` (language.md §6.8): the
/// leading items, the spread when the pattern has one, the trailing items.
fn writeList(
    w: *std.Io.Writer,
    pats: *const Exhaustive.Patterns,
    interner: *const InternPool.Global,
    p: Exhaustive.PatIndex,
    depth: u32,
) (std.Io.Writer.Error || Allocator.Error)!void {
    const l = pats.list(p);
    if (!l.spread and l.prefix == 0) return w.writeAll("[]");
    try w.writeAll("[ ");
    var first = true;
    // Re-sliced per item, as `ctor`'s arguments are.
    var i: u32 = 0;
    while (i < l.prefix + l.suffix) : (i += 1) {
        if (i == l.prefix and l.spread) {
            if (!first) try w.writeAll(", ");
            try w.writeAll("…_");
            first = false;
        }
        if (!first) try w.writeAll(", ");
        try writePat(w, pats, interner, pats.items(l)[i], .top, depth + 1);
        first = false;
    }
    if (l.spread and l.suffix == 0) {
        if (!first) try w.writeAll(", ");
        try w.writeAll("…_");
    }
    try w.writeAll(" ]");
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

test "disambiguating one stem sixty-four times is linear, not quadratic" {
    // `check/good/SixtyFourConstraints` renders a scheme whose `where`
    // clause names `number` sixty-five times, and the namer used to walk
    // every suffix from 2 for each of them — O(k²) allocations and O(k³)
    // comparisons for one warning. The count is the assertion because a
    // clock is not one: on the old code this is ~2000 allocations, and no
    // timing threshold could say that without also failing on a slow
    // machine.
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = counting.allocator();
    var namer: Namer = .init(gpa);
    defer namer.deinit();
    for (0..64) |i| {
        const v: Var = @enumFromInt(@as(u32, @intCast(i)));
        const got = try namer.name(v, "number");
        if (i == 0) {
            try testing.expectEqualStrings("number", got);
        } else {
            var buf: [16]u8 = undefined;
            try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "number{d}", .{i + 1}), got);
        }
    }
    // Eight allocations per name is generous for one `allocPrint` and the
    // occasional map growth — it measures 201 in all — where the old code
    // spent ~2000 printings for the same sixty-four names. The ratio is the
    // assertion; the bound is only loose enough to survive a change in how
    // `allocPrint` buffers.
    try testing.expect(counting.alloc_index < 8 * 64);
}
