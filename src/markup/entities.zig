//! HTML character references (docs/design/language.md §11.4 step 2,
//! frontend.md §9.7): the one piece of HTML the language knows, because it is
//! JSX's text syntax the way `\u{…}` is a string's.
//!
//! `decode` reads text as HTML reads text outside an attribute (WHATWG's
//! *character reference state*), which is what `htmlize` 1.1.0's `unescape`
//! implements for Solid 2's compiler:
//!
//!   - a named reference is the longest name of the table that the text
//!     spells after its `&`: the whole run of ASCII letters and digits with a
//!     `;` after it, else the longest prefix of that run that is a name HTML
//!     accepts without its `;` — so `&copy;` and `&copy` are both ©, and
//!     `&notit;` is `¬it;`;
//!   - `&#169;` and `&#xA9;` are numeric, with or without their `;`: `&#0;`,
//!     a surrogate and anything past U+10FFFF become U+FFFD, and U+0080 to
//!     U+009F map through HTML's windows-1252 table (`&#x80;` is €);
//!   - anything else — `AT&T`, `&nosuch;`, `&#;` — stays as written.
//!
//! The table is `markup_entity_table`, which `build.zig` generates from the
//! pinned `src/markup/entities.json` sorted by name bytes, so a name is found
//! by binary search. Decoding allocates only the output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const generated = @import("markup_entity_table");

pub const Entity = generated.Entity;
pub const table = generated.table;

const replacement = "\u{FFFD}";

/// Append `text` to `out` with every character reference decoded.
pub fn decode(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    var i: usize = 0;
    var copied: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '&')) |amp| {
        var buf: [4]u8 = undefined;
        if (match(text[amp..], &buf)) |m| {
            try out.appendSlice(gpa, text[copied..amp]);
            try out.appendSlice(gpa, m.expansion);
            i = amp + m.consumed;
            copied = i;
        } else {
            i = amp + 1;
        }
    }
    try out.appendSlice(gpa, text[copied..]);
}

/// Whether `text` holds no `&`, so `decode` would copy it unchanged.
pub fn isPlain(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '&') == null;
}

const Match = struct {
    /// Bytes of the reference, its `&` included.
    consumed: usize,
    expansion: []const u8,
};

/// The reference that begins at `text[0] == '&'`, if any. A numeric
/// expansion is encoded into `buf`.
fn match(text: []const u8, buf: *[4]u8) ?Match {
    std.debug.assert(text[0] == '&');
    if (text.len > 1 and text[1] == '#') return numeric(text, buf);
    var run: usize = 1;
    while (run < text.len and run <= generated.longest_name and std.ascii.isAlphanumeric(text[run])) run += 1;
    const name = text[1..run];
    if (name.len == 0) return null;
    if (run < text.len and text[run] == ';') {
        if (find(text[1 .. run + 1])) |value| return .{ .consumed = run + 1, .expansion = value };
    }
    // Without its `;`, the longest prefix that is a name HTML accepts bare.
    var k = name.len;
    while (k > 0) : (k -= 1) {
        if (find(name[0..k])) |value| return .{ .consumed = 1 + k, .expansion = value };
    }
    return null;
}

/// `&#` then decimal digits, or `&#x`/`&#X` then hexadecimal digits, then an
/// optional `;`. No digit at all is no reference.
fn numeric(text: []const u8, buf: *[4]u8) ?Match {
    var at: usize = 2;
    const hex = at < text.len and (text[at] == 'x' or text[at] == 'X');
    if (hex) at += 1;
    const digits_start = at;
    var value: u32 = 0;
    var too_big = false;
    while (at < text.len) : (at += 1) {
        const c = text[at];
        const digit: u32 = if (hex) switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => break,
        } else switch (c) {
            '0'...'9' => c - '0',
            else => break,
        };
        if (!too_big) {
            value = value * (if (hex) @as(u32, 16) else 10) + digit;
            if (value > 0x10FFFF) too_big = true;
        }
    }
    if (at == digits_start) return null;
    if (at < text.len and text[at] == ';') at += 1;
    return .{ .consumed = at, .expansion = if (too_big) replacement else scalar(value, buf) };
}

/// HTML's *numeric character reference end state*: the code point, with
/// its replacements.
fn scalar(value: u32, buf: *[4]u8) []const u8 {
    const code: u21 = switch (value) {
        0, 0xD800...0xDFFF => return replacement,
        0x80 => 0x20AC,
        0x82 => 0x201A,
        0x83 => 0x0192,
        0x84 => 0x201E,
        0x85 => 0x2026,
        0x86 => 0x2020,
        0x87 => 0x2021,
        0x88 => 0x02C6,
        0x89 => 0x2030,
        0x8A => 0x0160,
        0x8B => 0x2039,
        0x8C => 0x0152,
        0x8E => 0x017D,
        0x91 => 0x2018,
        0x92 => 0x2019,
        0x93 => 0x201C,
        0x94 => 0x201D,
        0x95 => 0x2022,
        0x96 => 0x2013,
        0x97 => 0x2014,
        0x98 => 0x02DC,
        0x99 => 0x2122,
        0x9A => 0x0161,
        0x9B => 0x203A,
        0x9C => 0x0153,
        0x9E => 0x017E,
        0x9F => 0x0178,
        0x110000...std.math.maxInt(u32) => return replacement,
        else => @intCast(value),
    };
    const len = std.unicode.utf8Encode(code, buf) catch unreachable;
    return buf[0..len];
}

/// The expansion of the name spelled `name` (no `&`; its `;` if it has one).
fn find(name: []const u8) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, table[mid].name, name)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return table[mid].value,
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests: htmlize 1.1.0's vectors for text outside an attribute
// (`src/unescape/internal.rs`), which is the reading both text and quoted
// attribute values use (language.md §11.4, §11.5).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectDecode(input: []const u8, expected: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try decode(testing.allocator, &out, input);
    try testing.expectEqualStrings(expected, out.items);
}

test "the table is sorted, has every WHATWG name, and each name decodes to its value alone" {
    try testing.expectEqual(@as(usize, 2231), table.len);
    for (table[1..], table[0 .. table.len - 1]) |b, a| try testing.expect(std.mem.order(u8, a.name, b.name) == .lt);
    var buf: [64]u8 = undefined;
    for (table) |e| {
        buf[0] = '&';
        @memcpy(buf[1..][0..e.name.len], e.name);
        try expectDecode(buf[0 .. 1 + e.name.len], e.value);
    }
}

test "named references: bare, with `;`, and the longest name wins" {
    try expectDecode("&time", "&time");
    try expectDecode("&times;", "×");
    try expectDecode("&timesb;", "⊠");
    try expectDecode("&times", "×");
    try expectDecode("&times!", "×!");
    try expectDecode("&timesa", "×a");
    try expectDecode("&timesbar;", "⨱");
    try expectDecode("&timesbar", "×bar");
    try expectDecode("&timesbarrrrrr", "×barrrrrr");
    try expectDecode("&times=", "×=");
    try expectDecode("&timesa;", "×a;");
    try expectDecode("&times=;", "×=;");
    try expectDecode("&times&lt;", "×<");
    try expectDecode("&timesb", "×b");
    try expectDecode("&timesb&lt;", "×b<");
    try expectDecode("&notit;", "¬it;");
    try expectDecode("&copy;", "©");
    try expectDecode("&copy", "©");
}

test "text that holds no reference is left as written" {
    try expectDecode("", "");
    try expectDecode("none", "none");
    try expectDecode("&", "&");
    try expectDecode("&;", "&;");
    try expectDecode("&time;", "&time;");
    try expectDecode(" &time; ", " &time; ");
    try expectDecode("&time; &amp; &time; &amp; &time;", "&time; & &time; & &time;");
    try expectDecode(" &amp; ", " & ");
    try expectDecode("&&amp;&", "&&&");
    try expectDecode("AND &amp;&AMP; and", "AND && and");
    try expectDecode("AT&T", "AT&T");
    try expectDecode("&nosuch;", "&nosuch;");
    try expectDecode("&CounterClockwiseContourIntegral;", "∳");
    try expectDecode("&CounterClockwiseContourIntegralX;", "&CounterClockwiseContourIntegralX;");
    try expectDecode("&aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;", "&aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;");
    try expectDecode("\xa1", "\xa1");
}

test "numeric references, decimal and hexadecimal, with or without `;`" {
    try expectDecode("&#x7a;", "z");
    try expectDecode("&#x7A;", "z");
    try expectDecode("&#X7a;", "z");
    try expectDecode("&#X7A;", "z");
    try expectDecode("&#x07a;", "z");
    try expectDecode("&#x007a;", "z");
    try expectDecode("&#122;", "z");
    try expectDecode("&#0122;", "z");
    try expectDecode("&#00122;", "z");
    try expectDecode("&#x21D2;", "⇒");
    try expectDecode("&#x7Az", "zz");
    try expectDecode("&#x7A&lt;", "z<");
    try expectDecode("&#x7A", "z");
    try expectDecode("&#122z", "zz");
    try expectDecode("&#122&lt;", "z<");
    try expectDecode("&#122", "z");
    try expectDecode("&#z", "&#z");
    try expectDecode("&#&lt;", "&#<");
    try expectDecode("&#", "&#");
    try expectDecode("&#a0;", "&#a0;");
    try expectDecode("&#xZ;", "&#xZ;");
    try expectDecode("&#XZ;", "&#XZ;");
    try expectDecode("&#169;", "©");
    try expectDecode("&#xA9;", "©");
}

test "numeric references HTML replaces: controls, NUL, surrogates, out of range, windows-1252" {
    try expectDecode("&#x1;", "\u{1}");
    try expectDecode("&#1;", "\u{1}");
    try expectDecode("&#13;", "\r");
    try expectDecode("&#xd;", "\r");
    try expectDecode("&#9;", "\t");
    try expectDecode("&#x10ffff;", "\u{10ffff}");
    try expectDecode("&#x110001;", "\u{fffd}");
    try expectDecode("&#x1100000000;", "\u{fffd}");
    try expectDecode("&#x1100000000", "\u{fffd}");
    try expectDecode("&#x110000000000000000000000000000000000000;", "\u{fffd}");
    try expectDecode("&#x110000000000000000000000000000000000000", "\u{fffd}");
    try expectDecode("&#0;", "\u{fffd}");
    try expectDecode("&#xD800;", "\u{fffd}");
    try expectDecode("&#x95;", "•");
    try expectDecode("&#x95;&#149;&#x2022;•", "••••");
    try expectDecode("&#x20", " ");
    try expectDecode("&#x80;", "€");
    try expectDecode("&#x81;", "\u{81}");
}
