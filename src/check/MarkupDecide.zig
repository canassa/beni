//! Deciding markup's obligations and reporting its faults
//! (checker-v2.md §25.3–§25.4): the part of the solver that answers what a
//! hole renders as, which form a handler has, which form a `class` or
//! `style` value takes, a row function's arity, whether a key may be one,
//! and whether a `For`'s item is a primitive-`eq` type.
//!
//! Every obligation is decided when its owner is bound, or at its owner's
//! boundary (`default`), exactly as `interpolatable` is (§4.5), so whether
//! and how a root checks is a function of its declaration and never of
//! declaration order (I9). What was decided is recorded (§25.7), so the
//! backend is told which conversion, list form and arity to write and never
//! guesses one from a value.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const Obligations = @import("Obligations.zig");
const Solve = @import("Solve.zig");
const Decide = @import("Decide.zig");
const Walk = @import("Walk.zig");
const Tree = @import("constrain/Tree.zig");
const MarkupTexts = @import("MarkupTexts.zig");
const Producers = @import("Producers.zig");

const Var = TypeStore.Var;
const Error = Solve.Error;
const Id = Obligations.Id;
const Row = Obligations.Row;
const Category = Tree.Category;

/// What one markup obligation was decided as, by the record it is about:
/// a hole's `HoleKind`, an event item's `Form`, a list attribute's `Class`,
/// a row's arity, a form's item primitiveness (1 or 0).
pub const Decision = struct { at: u32, value: u8 };

pub fn decide(s: *Solve, id: Id, row: Row, default: bool) Error!void {
    switch (row.kind) {
        .renderable => try renderable(s, id, row, default),
        .handler => try handler(s, id, row, default),
        .attr_form => try attrForm(s, id, row, default),
        .row => try rowFunction(s, id, row, default),
        .key => try key(s, id, row, default),
        .item => try item(s, id, row, default),
        else => unreachable,
    }
}

/// Whether the declaration holding `region` already has an error: a type
/// still unknown at its boundary is then that error's consequence (a
/// lambda of the wrong arity leaves its parameters unbound), and saying
/// "cannot tell" about it would be a second message for one mistake.
fn failedAt(s: *Solve, region: Bir.Inst.Index) bool {
    const d = Producers.declOf(s.cx.bir, region) orelse return false;
    return d < s.report.failed.bit_length and s.report.failed.isSet(d);
}

fn record(s: *Solve, row: Row, value: u8) Error!void {
    try s.markup_decisions.append(s.cx.gpa, .{ .at = row.index & ~Obligations.markup_flag, .value = value });
}

fn html(s: *Solve, m: Var) Error!Var {
    const vocab = s.cx.markup orelse return s.fresh(.err);
    if (vocab.markup_type == .none) return s.fresh(.err);
    const args = try s.store().addVars(&.{m});
    return s.fresh(.{ .structure = .{ .app = .{ .type = vocab.markup_type, .args = args } } });
}

/// The type application `v` resolves to, or null.
fn appOf(s: *Solve, v: Var) ?TypeStore.Structure.App {
    return switch (s.store().resolvedContent(v)) {
        .structure => |st| switch (st) {
            .app => |a| a,
            else => null,
        },
        else => null,
    };
}

fn isMarkupType(s: *Solve, a: TypeStore.Structure.App) bool {
    const vocab = s.cx.markup orelse return false;
    return a.type != .none and a.type == vocab.markup_type and a.args.len == 1;
}

/// §25.4's `renderable(part, m)`: text of one of the five primitive types,
/// markup, `Maybe` markup or a `List` of it, whose messages are the root's.
fn renderable(s: *Solve, id: Id, row: Row, default: bool) Error!void {
    const st = s.store();
    const wk = s.cx.types.well_known;
    const part = row.vars[0];
    const m = row.vars[1];
    const Hole = Dispatch.Markup.Hole;
    switch (st.resolvedContent(part)) {
        .err, .alias => {},
        .flex => |flags| if (flags.kind == .number) {
            if (default) try record(s, row, @intFromEnum(Hole.text_number)) else try Decide.reopen(s, id);
        } else if (default) {
            if (!failedAt(s, row.region)) try MarkupTexts.childUnknown(s.report, row.region);
        } else try Decide.reopen(s, id),
        .rigid => |flags| if (flags.kind == .number) {
            try record(s, row, @intFromEnum(Hole.text_number));
        } else try MarkupTexts.childNotRenderable(s.report, row.region, part),
        .structure => {
            const a = appOf(s, part) orelse return MarkupTexts.childNotRenderable(s.report, row.region, part);
            if (a.args.len == 0) {
                const kind: ?Hole = if (a.type == wk.string)
                    .text_string
                else if (a.type == wk.int or a.type == wk.float)
                    .text_number
                else if (a.type == wk.char)
                    .text_char
                else if (a.type == wk.bool)
                    .text_bool
                else
                    null;
                if (kind) |k| return record(s, row, @intFromEnum(k));
                return MarkupTexts.childNotRenderable(s.report, row.region, part);
            }
            if (isMarkupType(s, a)) {
                _ = try s.unify(m, Walk.positions(st, part)[0], row.region, .{ .tag = .markup_child });
                return record(s, row, @intFromEnum(Hole.html));
            }
            const wrapper: ?Hole = if (a.type == wk.maybe and a.args.len == 1)
                .maybe_html
            else if (a.type == wk.list and a.args.len == 1)
                .list_html
            else
                null;
            const w = wrapper orelse return MarkupTexts.childNotRenderable(s.report, row.region, part);
            // A `Maybe` or a `List` holds markup or nothing renderable, so
            // an element type still unknown is markup of this root.
            const inner = Walk.positions(st, part)[0];
            switch (st.resolvedContent(inner)) {
                .err, .alias => return,
                .flex => |flags| if (flags.kind != .any) return MarkupTexts.childNotRenderable(s.report, row.region, part),
                else => if (appOf(s, inner)) |ia| {
                    if (!isMarkupType(s, ia)) return MarkupTexts.childNotRenderable(s.report, row.region, part);
                } else return MarkupTexts.childNotRenderable(s.report, row.region, part),
            }
            _ = try s.unify(try html(s, m), inner, row.region, .{ .tag = .markup_child });
            try record(s, row, @intFromEnum(w));
        },
    }
}

/// The name symbol of the item record a handler or list row is about.
fn itemName(s: *Solve, row: Row) u32 {
    const it = s.cx.bir.extraData(@enumFromInt(row.index & ~Obligations.markup_flag), Bir.MarkupItem);
    return @intFromEnum(s.cx.bir.symbol(it.name));
}

/// §25.4's `handler(h, p, m)`: a function is the payload form, `p -> m`;
/// anything else, and a variable at the boundary, the message form.
fn handler(s: *Solve, id: Id, row: Row, default: bool) Error!void {
    const st = s.store();
    const h = row.vars[0];
    const payload = row.vars[1];
    const m = row.vars[2];
    const category: Category = .{ .tag = .markup_handler, .index = itemName(s, row) };
    const Form = Dispatch.Markup.Form;
    switch (st.resolvedContent(h)) {
        .err, .alias => {},
        .flex => if (default) {
            _ = try s.unify(m, h, row.region, category);
            try record(s, row, @intFromEnum(Form.message));
        } else try Decide.reopen(s, id),
        .structure => |flat| if (flat == .func) {
            const params = try s.store().addVars(&.{payload});
            const wanted = try s.fresh(.{ .structure = .{ .func = .{ .params = params, .result = m } } });
            _ = try s.unify(wanted, h, row.region, category);
            try record(s, row, @intFromEnum(Form.payload));
        } else {
            _ = try s.unify(m, h, row.region, category);
            try record(s, row, @intFromEnum(Form.message));
        },
        .rigid => {
            _ = try s.unify(m, h, row.region, category);
            try record(s, row, @intFromEnum(Form.message));
        },
    }
}

/// §25.4's `attr_form(v, row)`: a `List` is the class or style list,
/// anything else, and a variable at the boundary, the `String` form.
fn attrForm(s: *Solve, id: Id, row: Row, default: bool) Error!void {
    const st = s.store();
    const wk = s.cx.types.well_known;
    const v = row.vars[0];
    const styles = row.index & Obligations.markup_flag != 0;
    const category: Category = .{ .tag = .markup_list_attribute, .index = itemName(s, row) };
    const Class = Dispatch.Markup.Class;
    const is_list = switch (st.resolvedContent(v)) {
        .err, .alias => return,
        .flex => if (default) false else return Decide.reopen(s, id),
        else => if (appOf(s, v)) |a| a.type != .none and a.type == wk.list else false,
    };
    if (!is_list) {
        _ = try s.unify(try s.fresh(.{ .structure = .{ .app = .{ .type = wk.string, .args = .empty } } }), v, row.region, category);
        return record(s, row, @intFromEnum(Class.string));
    }
    const name = try s.fresh(.{ .structure = .{ .app = .{ .type = wk.string, .args = .empty } } });
    const second = try s.fresh(.{ .structure = .{ .app = .{ .type = if (styles) wk.string else wk.bool, .args = .empty } } });
    const pair = try s.fresh(.{ .structure = .{ .tuple = try st.addVars(&.{ name, second }) } });
    const list = try s.fresh(.{ .structure = .{ .app = .{ .type = wk.list, .args = try st.addVars(&.{pair}) } } });
    _ = try s.unify(list, v, row.region, category);
    try record(s, row, @intFromEnum(if (styles) Class.style_list else Class.class_list));
}

/// §25.4's `row(f, a, m)`: a function of one parameter is `a -> H m`; of
/// two, in a `For`, `a, Int -> H m`; anything else meets `a -> H m`, whose
/// mismatch names the forms. The arity is recorded.
fn rowFunction(s: *Solve, id: Id, row: Row, default: bool) Error!void {
    const st = s.store();
    const f = row.vars[0];
    const a = row.vars[1];
    const m = row.vars[2];
    const in_for = row.index & Obligations.markup_flag != 0;
    const category: Category = .{ .tag = .markup_row, .index = if (in_for) 0 else 1 };
    const arity: u8 = switch (st.resolvedContent(f)) {
        .err, .alias => return,
        .flex => if (default) 1 else return Decide.reopen(s, id),
        .structure => |flat| if (flat == .func and in_for and Walk.function(st, f).?.params.len == 2) 2 else 1,
        else => 1,
    };
    const params: []const Var = if (arity == 2)
        &.{ a, try s.fresh(.{ .structure = .{ .app = .{ .type = s.cx.types.well_known.int, .args = .empty } } }) }
    else
        &.{a};
    const wanted = try s.fresh(.{ .structure = .{ .func = .{ .params = try st.addVars(params), .result = try html(s, m) } } });
    _ = try s.unify(wanted, f, row.region, category);
    try record(s, row, arity);
}

/// Whether `v`'s `eq` is `strict_eq` (static-dispatch-spike.md §3.2): a
/// `String`, `Int`, `Float`, `Char`, `Bool` or `Order`, or a `number`.
/// Null while it is still a variable that could be one.
fn primitiveEq(s: *Solve, v: Var) ?bool {
    const wk = s.cx.types.well_known;
    return switch (s.store().resolvedContent(v)) {
        .flex => |flags| if (flags.kind == .number) true else null,
        .rigid => |flags| flags.kind == .number,
        .structure => if (appOf(s, v)) |a|
            a.args.len == 0 and a.type != .none and
                (a.type == wk.string or a.type == wk.int or a.type == wk.float or a.type == wk.char or a.type == wk.bool or a.type == wk.order)
        else
            false,
        .err, .alias => true,
    };
}

/// §25.4's `key(k)`: accepted at a primitive-`eq` type, refused at any
/// other, and at the boundary refused when still unknown.
fn key(s: *Solve, id: Id, row: Row, default: bool) Error!void {
    const k = row.vars[0];
    const content = s.store().resolvedContent(k);
    if (content == .err or content == .alias) return;
    if (primitiveEq(s, k)) |yes| {
        if (yes) return;
        return MarkupTexts.keyNotPrimitive(s.report, row.region, if (content == .rigid) null else k);
    }
    if (!default) return Decide.reopen(s, id);
    if (!failedAt(s, row.region)) try MarkupTexts.keyNotPrimitive(s.report, row.region, null);
}

/// Whether a `For`'s item or a `Show`'s value is primitive-`eq`, recorded;
/// no is the `unkeyed_for` warning for a `For` that says nothing about its
/// keying.
fn item(s: *Solve, id: Id, row: Row, default: bool) Error!void {
    const a = row.vars[0];
    const yes = primitiveEq(s, a) orelse if (default) false else return Decide.reopen(s, id);
    try record(s, row, @intFromBool(yes));
    if (yes or row.index & Obligations.markup_flag == 0 or !s.informational) return;
    const form = s.cx.bir.extraData(@enumFromInt(row.index & ~Obligations.markup_flag), Bir.MarkupForm);
    try MarkupTexts.unkeyedFor(s.report, row.region, form.token, a, keyField(s, a));
}

/// The field of a record item that `unkeyed_for`'s hint suggests keying
/// by: `id` when it is a primitive-`eq` field, else the first such field
/// by name text. Null for an item that is not a record, or has none.
fn keyField(s: *Solve, a: Var) ?[]const u8 {
    const rec = switch (s.store().resolvedContent(a)) {
        .structure => |st| switch (st) {
            .record => |r| r,
            else => return null,
        },
        else => return null,
    };
    var best: ?[]const u8 = null;
    for (Walk.recordFields(s.store(), rec)) |f| {
        if (primitiveEq(s, f.value) != true) continue;
        const text = s.cx.interner.slice(f.name);
        if (std.mem.eql(u8, text, "id")) return text;
        if (best == null or std.mem.lessThan(u8, text, best.?)) best = text;
    }
    return best;
}

// ---------------------------------------------------------------------------
// Faults (§25.3)
// ---------------------------------------------------------------------------

pub fn fault(s: *Solve, region: Bir.Inst.Index, f: Tree.MarkupFault) Error!void {
    const vocab = s.cx.markup orelse return;
    switch (f.kind) {
        .unknown_element => try MarkupTexts.unknownElement(s.report, region, f.token, f.name, try vocab.suggestions(s.cx.scratch, f.name, null)),
        .unknown_attribute => try MarkupTexts.unknownAttribute(s.report, region, f.token, f.name, f.tag, try vocab.suggestions(s.cx.scratch, f.name, f.tag)),
        .void_children => try MarkupTexts.voidChildren(s.report, region, f.token, f.name),
        .raw_attribute => if (s.informational) try MarkupTexts.rawAttribute(s.report, region, f.token, f.name),
        .event_escape => try MarkupTexts.eventEscape(s.report, region, f.token, f.name, try vocab.eventsLike(s.cx.scratch, s.cx.interner.slice(f.name), f.tag)),
        .srcdoc_escape => try MarkupTexts.srcdocEscape(s.report, region, f.token, f.name),
        .quoted_value, .bare_value => try MarkupTexts.valueForm(s.report, region, f.token, f.name, f.kind == .quoted_value, @enumFromInt(f.type)),
    }
}
