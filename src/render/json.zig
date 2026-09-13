//! `--diagnostics=json` renderer (docs/design/frontend.md §1.1).
//!
//! One JSON array on stderr, one object per diagnostic, field names exactly
//! those of `diagnostic.Diagnostic`, `code` and `severity` as strings. The
//! array is written through `std.json.Stringify` so string escaping is the
//! library's, not ours. The input must already be in emission order
//! (`diagnostic.sort`); this renderer never reorders.

const std = @import("std");
const diagnostic = @import("diagnostic");

/// Write `diagnostics` as one array followed by a newline. An empty slice is
/// not written at all: the caller decides whether there is anything to render
/// (frontend.md §1.1, "the renderer runs only when there is something to
/// render"), and the black-box harness treats empty stderr as no diagnostics.
pub fn render(writer: *std.Io.Writer, diagnostics: []const diagnostic.Diagnostic) std.Io.Writer.Error!void {
    if (diagnostics.len == 0) return;
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stringify.write(diagnostics);
    try writer.writeByte('\n');
}

test "render escapes and round-trips through the schema" {
    const diags = [_]diagnostic.Diagnostic{
        .{
            .code = .tab_in_source,
            .severity = .@"error",
            .span = .{ .file = "src/Main.beni", .start = .{ .line = 3, .col = 5 }, .end = .{ .line = 3, .col = 6 } },
            .title = diagnostic.title(.tab_in_source),
            .message = "I found a tab character.\nSay \"no\" to \\t.",
        },
        .{
            .code = .invalid_module_path,
            .severity = .warning,
            .span = .{ .file = "x y.beni", .start = .{ .line = 1, .col = 1 }, .end = .{ .line = 1, .col = 1 } },
            .title = diagnostic.title(.invalid_module_path),
            .message = "",
        },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, &diags);
    const text = out.written();
    try std.testing.expect(text[text.len - 1] == '\n');

    const parsed = try std.json.parseFromSlice([]diagnostic.Diagnostic, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(@as([]const diagnostic.Diagnostic, &diags), parsed.value);
}

test "render writes nothing for no diagnostics" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, &.{});
    try std.testing.expectEqualStrings("", out.written());
}
