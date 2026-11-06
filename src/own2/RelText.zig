//! L3: a relative slot's text (`docs/design/ownership-v2.md` §2.10), split from
//! `ContractText`. Obligations kept here: none (text).
const std = @import("std");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");

/// How a contract's text names a field.
pub const Names = struct {
    ctx: *anyopaque,
    field: *const fn (ctx: *anyopaque, rank: u32) []const u8,
};

/// `rel`'s text: `.f`, `.0`, `#c.i`, `[*]`, `⟲`, `◆`, `◇`, `⟨n⟩`; `ε` for none.
pub fn relText(slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, r: Slots.Rel) std.Io.Writer.Error!void {
    return wordsText(places, names, w, slots.relWords(r));
}

pub fn wordsText(places: *const Place.Table, names: Names, w: *std.Io.Writer, words: []const u32) std.Io.Writer.Error!void {
    if (words.len == 0) return w.writeAll("ε");
    for (words) |word| {
        const s = Place.Step.fromWord(word);
        switch (s.kind) {
            .field => try w.print(".{s}", .{names.field(names.ctx, s.payload)}),
            .index => try w.print(".{d}", .{s.payload}),
            .ctor_arg => try w.print("#{d}.{d}", .{ places.ctorArgOf(s)[0], places.ctorArgOf(s)[1] }),
            .elem => try w.writeAll("[*]"),
            .contents => try w.writeAll("◆"),
            .env => try w.writeAll("◇"),
            .slot => try w.print("⟨{d}⟩", .{s.payload}),
            .level => try w.writeAll("⟲"),
        }
    }
}
