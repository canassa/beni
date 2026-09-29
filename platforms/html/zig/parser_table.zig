//! What the HTML parser does with a string of markup, as a fixed table
//! (docs/design/backend.md §15.3; boundary.md §9.3): which elements are
//! void, which read their content as text, and which nestings the parser
//! rebuilds into a different tree than the one written. A lowering that
//! writes markup as a string — a template, a server render — asks it before
//! it writes an element, and reports `markup_restructured` where the page
//! would not be the tree the program described.
//!
//! These are facts about the parser, not about a vocabulary: a vocabulary
//! says which elements a view may name, this says what the parser makes of
//! them. The rules are the HTML standard's tree-construction rules for the
//! cases a view can write statically: void elements, raw and escapable raw
//! text, a `<p>` closed by a block element, an `<a>` or a `<form>` inside
//! another, and the table and list items whose parents the parser supplies
//! or closes.

const std = @import("std");

/// Elements with no end tag: the parser closes them at once, so anything
/// written inside one would become its sibling.
pub fn isVoid(name: []const u8) bool {
    return among(name, &.{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" });
}

pub const Content = enum {
    /// Ordinary content: text decodes character references and `<` opens
    /// a tag.
    normal,
    /// Raw text: nothing is decoded, and only `</name` ends the element.
    raw_text,
    /// Escapable raw text: references decode, but no tag opens.
    escapable_raw_text,
};

pub fn content(name: []const u8) Content {
    if (among(name, &.{ "script", "style", "xmp", "iframe", "noembed", "noframes" })) return .raw_text;
    if (among(name, &.{ "textarea", "title" })) return .escapable_raw_text;
    return .normal;
}

/// Whether raw text written into the element `name` would end it early:
/// `</` followed by the name, in any case.
pub fn endsRawText(name: []const u8, text: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "</")) |at| : (i = at + 1) {
        const rest = text[at + 2 ..];
        if (rest.len >= name.len and std.ascii.eqlIgnoreCase(rest[0..name.len], name)) return true;
    }
    return false;
}

/// The open elements a child is written inside, as far as the rules below
/// need them.
pub const Scope = struct {
    /// The nearest enclosing element, or null at a root.
    parent: ?[]const u8 = null,
    /// An open `<p>`, which a block element would close.
    in_p: bool = false,
    in_a: bool = false,
    in_form: bool = false,

    /// The scope of the children of `name`, written in `outer`.
    pub fn enter(outer: Scope, name: []const u8) Scope {
        var s = outer;
        s.parent = name;
        if (std.mem.eql(u8, name, "p")) s.in_p = true;
        // A table or a button starts a new scope for `<p>`'s closing.
        if (among(name, &.{ "table", "button", "td", "th", "caption", "marquee", "object", "template" })) s.in_p = false;
        if (std.mem.eql(u8, name, "a")) s.in_a = true;
        if (std.mem.eql(u8, name, "form")) s.in_form = true;
        return s;
    }
};

/// Why the parser would rebuild an element `child` written in `scope`, or
/// null when it keeps it where it is written.
pub fn misnested(scope: Scope, child: []const u8) ?[]const u8 {
    if (scope.parent) |parent| {
        if (isVoid(parent)) return "a void element has no end tag, so the parser makes its children its siblings";
        if (content(parent) != .normal) return "the parser reads this element's content as text, so a child element would be text";
        if (among(parent, &.{"table"}) and !among(child, &.{ "caption", "colgroup", "thead", "tbody", "tfoot", "template" }))
            return "the parser moves everything but a caption, a column group and the row groups out of a table, and puts a row inside a `tbody` it makes itself";
        if (among(parent, &.{ "thead", "tbody", "tfoot" }) and !among(child, &.{ "tr", "template" }))
            return "a row group holds only rows; the parser supplies a row or moves the element out of the table";
        if (std.mem.eql(u8, parent, "tr") and !among(child, &.{ "td", "th", "template" }))
            return "a row holds only cells; the parser moves anything else out of the table";
        if (std.mem.eql(u8, parent, "colgroup") and !among(child, &.{ "col", "template" }))
            return "a column group holds only columns";
        if (among(child, &.{ "li", "dt", "dd", "option", "optgroup" }) and std.mem.eql(u8, parent, child))
            return "the parser closes the open element of the same name before it opens this one";
    }
    if (among(child, &.{ "tr", "td", "th", "tbody", "thead", "tfoot", "caption", "col", "colgroup" }) and !tableContext(scope.parent))
        return "the parser drops a table part written outside the table structure it belongs in";
    if (scope.in_p and closesP(child)) return "the parser closes an open `<p>` before a block element, so the element would follow the paragraph instead of being inside it";
    if (scope.in_a and std.mem.eql(u8, child, "a")) return "the parser closes an open `<a>` before it opens another";
    if (scope.in_form and std.mem.eql(u8, child, "form")) return "the parser ignores a `<form>` inside another";
    return null;
}

/// Whether text written directly inside `parent` would be moved out of it
/// (foster-parented out of a table).
pub fn movesText(parent: ?[]const u8) bool {
    const p = parent orelse return false;
    return among(p, &.{ "table", "thead", "tbody", "tfoot", "tr", "colgroup" });
}

fn tableContext(parent: ?[]const u8) bool {
    const p = parent orelse return true;
    return among(p, &.{ "table", "thead", "tbody", "tfoot", "tr", "colgroup", "template" });
}

/// Block elements whose start tag closes an open `<p>`.
fn closesP(name: []const u8) bool {
    return among(name, &.{
        "address",  "article",    "aside",  "blockquote", "details", "dialog",  "div",   "dl",
        "fieldset", "figcaption", "figure", "footer",     "form",    "h1",      "h2",    "h3",
        "h4",       "h5",         "h6",     "header",     "hgroup",  "hr",      "main",  "menu",
        "nav",      "ol",         "p",      "pre",        "search",  "section", "table", "ul",
    });
}

fn among(name: []const u8, comptime set: []const []const u8) bool {
    inline for (set) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

test "void and text-content elements" {
    const t = std.testing;
    try t.expect(isVoid("br"));
    try t.expect(!isVoid("div"));
    try t.expectEqual(Content.raw_text, content("style"));
    try t.expectEqual(Content.escapable_raw_text, content("textarea"));
    try t.expect(endsRawText("style", "a { } </STYLE >"));
    try t.expect(!endsRawText("style", "a < b </sty"));
}

test "a block element closes an open paragraph, and table parts need their table" {
    const t = std.testing;
    const in_p = Scope.enter(.{}, "p");
    try t.expect(misnested(in_p, "div") != null);
    try t.expect(misnested(Scope.enter(in_p, "span"), "div") != null);
    try t.expect(misnested(in_p, "span") == null);
    try t.expect(misnested(Scope.enter(.{}, "table"), "tr") != null);
    try t.expect(misnested(Scope.enter(Scope.enter(.{}, "table"), "tbody"), "tr") == null);
    try t.expect(misnested(Scope.enter(.{}, "div"), "td") != null);
    try t.expect(misnested(Scope.enter(.{}, "a"), "a") != null);
}
