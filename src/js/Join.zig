//! The join (`backend.md` §9, *The embedded modules' printed text, in the
//! pack*): a module assembled from printed pieces — the head, the units,
//! the tail, the footer — by concatenating their text and rebasing each
//! piece's marks by where the piece landed.
//!
//! One module is still one `SourceMap.write`, from the bytes and the marks
//! the pieces together hold, exactly as when the whole module was printed
//! in one walk. The pieces were printed with the module's shared printer
//! state (`Print.Context`), so joining them is the whole print.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SourceMap = @import("SourceMap.zig");

/// One printed piece of a module: its bytes and the marks the printer
/// recorded while printing it, generated offsets relative to the piece's
/// first byte. Both live in the scratch arena the piece was printed in.
pub const Piece = struct {
    text: []const u8,
    mappings: []const SourceMap.Mapping = &.{},
};

/// A module joined: the text (`gpa`-owned, one allocation) and its marks
/// (`scratch`-owned, one allocation), ready for `SourceMap.write`.
pub const Joined = struct {
    text: []u8,
    mappings: []SourceMap.Mapping,
};

/// Concatenate `pieces` — the module's byte order — and `footer`, rebasing
/// every mark by its piece's start. The marks stay in generated order
/// across pieces, because the piece starts ascend.
pub fn join(gpa: Allocator, scratch: Allocator, pieces: []const Piece, footer: []const u8) Allocator.Error!Joined {
    var total: usize = footer.len;
    var count: usize = 0;
    for (pieces) |piece| {
        total += piece.text.len;
        count += piece.mappings.len;
    }
    const text = try gpa.alloc(u8, total);
    errdefer gpa.free(text);
    const mappings = try scratch.alloc(SourceMap.Mapping, count);
    var at: usize = 0;
    var m: usize = 0;
    for (pieces) |piece| {
        @memcpy(text[at..][0..piece.text.len], piece.text);
        for (piece.mappings) |mark| {
            // `generated` is an offset into one module: the piece's start
            // and the module's length are both u32, so the sum is.
            mappings[m] = .{
                .generated = mark.generated + @as(u32, @intCast(at)),
                .source = mark.source,
                .name = mark.name,
            };
            m += 1;
        }
        at += piece.text.len;
    }
    @memcpy(text[at..][0..footer.len], footer);
    return .{ .text = text, .mappings = mappings };
}
