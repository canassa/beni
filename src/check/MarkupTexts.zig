//! The texts of markup's checker diagnostics (checker-v2.md §25.9,
//! `language.md` §11.17), each through the one emit path (§15.1). An
//! element or attribute name has no instruction of its own, so each message
//! is attributed to its markup root's instruction and underlines the token
//! it is about.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const diagnostic = @import("diagnostic");
const Render = @import("Render.zig");
const Report = @import("Report.zig");
const TypeStore = @import("TypeStore.zig");
const Diagnostics = @import("Diagnostics.zig");
const CategoryFile = @import("Category.zig");

const Category = CategoryFile.Category;
const FormAttribute = CategoryFile.FormAttribute;
const Var = TypeStore.Var;
const Symbol = InternPool.Symbol;
const Error = Report.Error;

/// The sentences of a `type_mismatch` met in markup (§25.3–§25.4): the
/// attribute, event or form it was looking at is named.
pub fn categoryLines(scratch: std.mem.Allocator, interner: *const InternPool.Global, category: Category) Diagnostics.Reporter.Lines {
    const name: []const u8 = switch (category.tag) {
        .markup_attribute, .markup_list_attribute, .markup_handler => interner.slice(@enumFromInt(category.index)),
        .markup_form => switch (std.enums.fromInt(FormAttribute, category.index) orelse .each) {
            .each => "each",
            .when => "when",
            .fallback => "fallback",
            .keyed => "keyed",
        },
        else => "",
    };
    return switch (category.tag) {
        .markup_attribute => .{
            .intro = std.fmt.allocPrint(scratch, "The `{s}` attribute is given a value of the wrong type:", .{name}) catch "This attribute is given a value of the wrong type:",
            .found = "The value is:",
            .wanted = std.fmt.allocPrint(scratch, "But `{s}` is declared to take:", .{name}) catch "But the attribute takes:",
        },
        .markup_list_attribute => .{
            .intro = std.fmt.allocPrint(scratch, "The `{s}` attribute takes a `String` or a list, and this value is neither:", .{name}) catch "This attribute takes a `String` or a list:",
            .found = "The value is:",
            .wanted = "But I need:",
        },
        .markup_handler => .{
            .intro = std.fmt.allocPrint(scratch, "The handler given to `{s}` does not fit the event:", .{name}) catch "This handler does not fit its event:",
            .found = "The handler is:",
            .wanted = "But the event needs a message, or a function from its payload to one:",
        },
        .markup_form => .{
            .intro = std.fmt.allocPrint(scratch, "The `{s}` of this markup form is not what it takes:", .{name}) catch "This form's attribute is not what it takes:",
            .found = "It is:",
            .wanted = "But I need:",
        },
        .markup_row => .{
            .intro = if (category.index == 0)
                "The row function of this `<For>` does not take an item, or an item and its position:"
            else
                "The body of this `<Show>` does not take the value it shows:",
            .found = "It is:",
            .wanted = "But I need:",
        },
        else => .{
            .intro = "This markup does not produce the same messages as the markup around it:",
            .found = "It is:",
            .wanted = "But the markup around it is:",
        },
    };
}

fn emit(r: *Report, code: diagnostic.Code, severity: diagnostic.Severity, region: Bir.Inst.Index, token: ?u32, out: *std.Io.Writer.Allocating) Error!void {
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = code, .module = r.module, .region = region, .severity = severity, .token = token, .message = message });
}

fn text(r: *const Report, s: Symbol) []const u8 {
    return r.env.interner.slice(s);
}

fn writeType(r: *Report, w: *std.Io.Writer, v: Var) Error!void {
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    Render.writeVar(w, r.texts.cx(), &namer, v, .top) catch return error.OutOfMemory;
}

fn writeSuggestions(w: *std.Io.Writer, names: []const []const u8) Error!void {
    if (names.len == 0) return;
    w.writeAll("\n\nHint: did you mean ") catch return error.OutOfMemory;
    for (names, 0..) |n, i| {
        if (i != 0) w.writeAll(if (i + 1 == names.len) " or " else ", ") catch return error.OutOfMemory;
        w.print("`{s}`", .{n}) catch return error.OutOfMemory;
    }
    w.writeByte('?') catch return error.OutOfMemory;
}

pub fn unknownElement(r: *Report, region: Bir.Inst.Index, token: u32, name: Symbol, near: []const []const u8) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    const w = &out.writer;
    w.print(
        \\`<{s}>` is not an element of this build's markup vocabulary.
        \\
        \\The elements markup may write are the ones its platform declares with
        \\`pub element`; a custom element is one the platform declares by a pattern.
    , .{text(r, name)}) catch return error.OutOfMemory;
    try writeSuggestions(w, near);
    try emit(r, .unknown_element, .@"error", region, token, &out);
}

pub fn unknownAttribute(r: *Report, region: Bir.Inst.Index, token: u32, name: Symbol, tag: Symbol, near: []const []const u8) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    const w = &out.writer;
    w.print(
        \\`{s}` is not an attribute or event of `<{s}>` in this build's markup vocabulary.
        \\
        \\An attribute the vocabulary does not declare is written with its name quoted,
        \\`"{s}"={{value}}`, and is then an untyped `String` that is never checked.
    , .{ text(r, name), text(r, tag), text(r, name) }) catch return error.OutOfMemory;
    try writeSuggestions(w, near);
    try emit(r, .unknown_attribute, .@"error", region, token, &out);
}

pub fn voidChildren(r: *Report, region: Bir.Inst.Index, token: u32, tag: Symbol) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    out.writer.print(
        \\`<{s}>` is given children, but its platform declares it `void`: it takes none,
        \\and they would be dropped.
        \\
        \\Write it self-closing, `<{s} />`, and put the children beside it.
    , .{ text(r, tag), text(r, tag) }) catch return error.OutOfMemory;
    try emit(r, .void_element_with_children, .@"error", region, token, &out);
}

pub fn rawAttribute(r: *Report, region: Bir.Inst.Index, token: u32, name: Symbol) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    out.writer.print(
        \\`{s}` writes its value into the page as markup, unescaped.
        \\
        \\Whatever the value holds becomes part of the page, script included, so only
        \\markup this program built itself is safe to give it.
    , .{text(r, name)}) catch return error.OutOfMemory;
    try emit(r, .raw_markup_attribute, .warning, region, token, &out);
}

pub fn eventEscape(r: *Report, region: Bir.Inst.Index, token: u32, name: Symbol, events: []const []const u8) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    const w = &out.writer;
    w.print(
        \\`"{s}"` writes an event handler as an untyped attribute.
        \\
        \\A page runs the text of an attribute whose name begins with `on` as script, so
        \\a value there could inject one. Handle the event with the typed event
        \\attribute the vocabulary declares, which takes a message:
        \\
        \\    onClick={{Clicked}}
    , .{text(r, name)}) catch return error.OutOfMemory;
    if (events.len != 0) {
        w.writeAll("\n\nHint: this element takes ") catch return error.OutOfMemory;
        for (events, 0..) |e, i| {
            if (i != 0) w.writeAll(", ") catch return error.OutOfMemory;
            w.print("`{s}`", .{e}) catch return error.OutOfMemory;
        }
        w.writeByte('.') catch return error.OutOfMemory;
    }
    try emit(r, .untyped_event_attribute, .@"error", region, token, &out);
}

/// A quoted or bare attribute value the declared type does not admit
/// (§25.3): decided from the syntax, so the message names both.
pub fn valueForm(r: *Report, region: Bir.Inst.Index, token: u32, name: Symbol, quoted: bool, declared: Var) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    const w = &out.writer;
    if (quoted) {
        w.print("The `{s}` attribute is given a quoted value, which is a `String`, but it is declared to take:\n\n    ", .{text(r, name)}) catch return error.OutOfMemory;
    } else {
        w.print("The `{s}` attribute is written bare, which means `{{True}}`, but it is declared to take:\n\n    ", .{text(r, name)}) catch return error.OutOfMemory;
    }
    try writeType(r, w, declared);
    w.print("\n\nHint: give it a value of that type in braces, `{s}={{…}}`.", .{text(r, name)}) catch return error.OutOfMemory;
    try emit(r, .type_mismatch, .@"error", region, token, &out);
}

const shapes =
    \\A hole takes a `String`, `Int`, `Float`, `Bool` or `Char`, which it shows as
    \\text; markup, `Html msg`; a `Maybe (Html msg)`; or a `List (Html msg)`.
;

pub fn childNotRenderable(r: *Report, region: Bir.Inst.Index, v: Var) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    const w = &out.writer;
    w.writeAll("I cannot show this value in markup:\n\n    ") catch return error.OutOfMemory;
    try writeType(r, w, v);
    w.writeAll("\n\n" ++ shapes ++ "\n\nHint: convert it first, `{String.fromX x}`, or build markup from it.") catch return error.OutOfMemory;
    try emit(r, .child_not_renderable, .@"error", region, null, &out);
}

pub fn childUnknown(r: *Report, region: Bir.Inst.Index) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    out.writer.writeAll("I cannot tell what type this hole's value has.\n\n" ++ shapes ++ "\n" ++
        \\How a hole updates is chosen from its type, so the type must be known here.
        \\
        \\Hint: add a type annotation that pins it down.
    ) catch return error.OutOfMemory;
    try emit(r, .child_not_renderable, .@"error", region, null, &out);
}

const primitives = "`String`, `Int`, `Float`, `Char`, `Bool` or `Order`";

pub fn keyNotPrimitive(r: *Report, region: Bir.Inst.Index, v: ?Var) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    const w = &out.writer;
    if (v) |key| {
        w.writeAll("This key is not a type whose `==` is identity:\n\n    ") catch return error.OutOfMemory;
        try writeType(r, w, key);
        w.writeAll("\n\n") catch return error.OutOfMemory;
    } else {
        w.writeAll("I cannot tell what type this key has, and a key's type must be known.\n\n") catch return error.OutOfMemory;
    }
    w.writeAll("Keys are compared by identity, and two equal keys must be one row, so a key is a\n" ++ primitives ++ ". A record compared by identity would make two\nequal keys two rows.\n\nHint: key by a field, `keyed={.id}`.") catch return error.OutOfMemory;
    try emit(r, .key_not_primitive, .@"error", region, null, &out);
}

pub fn unkeyedFor(r: *Report, region: Bir.Inst.Index, token: u32, item: Var) Error!void {
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    const w = &out.writer;
    w.writeAll("This `<For>` says nothing about how its rows are keyed, and its items are:\n\n    ") catch return error.OutOfMemory;
    try writeType(r, w, item);
    w.writeAll(
        \\
        \\
        \\so each row is kept by the item's identity. An item that is edited is a new
        \\value, so its row is rebuilt, and focus and input inside it are lost.
        \\
        \\Hint: key the rows, `keyed={.id}`, or say that identity is meant, `keyed={True}`.
    ) catch return error.OutOfMemory;
    try emit(r, .unkeyed_for, .warning, region, token, &out);
}
