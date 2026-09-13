//! Per-file front-end artifacts (docs/design/frontend.md §3, §4): what each
//! per-file phase produced, in one `MultiArrayList` column set keyed by file
//! index. M1a fills the lexical columns, M1b the AST, M1c the BIR.
//!
//! Ownership: a file's artifacts are the FILE's, not the worker's. They are
//! allocated from the session allocator, pre-sized from the byte count
//! (`Tokenizer.estimatedTokenCount` and friends), and installed here by
//! pointer — never copied — when the phase ends. The worker's arena is for
//! phase scratch (the parser's stacks, M1b), reset between files. This is
//! the choice frontend.md §3.4 leaves open ("moved to session-owned
//! storage"), taken this way because the alternative — an arena chunk per
//! file detached from the worker — either wastes a 256 KiB chunk on every
//! small module or forces a chunk-size policy, while a handful of
//! session-allocator calls per file is nowhere near the per-token budget.
//! It is also what the daemon (M4) needs: an edited file's columns are
//! freed and rebuilt on their own, and every other file's survive untouched.
//!
//! Threads: `set` writes only the columns of its own index, so workers on
//! disjoint files never race, the same discipline as `SourceStore.read`.
//! `applyRemap` runs serially after the interner merge.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("InternPool.zig");
const Token = @import("lex/Token.zig");
const LexDiagnostics = @import("lex/Diagnostics.zig");
const Ast = @import("parse/Ast.zig");
const Bir = @import("bir/Bir.zig");
const SourceStore = @import("SourceStore.zig");

const Artifacts = @This();

files: std.MultiArrayList(File) = .empty,

pub const File = struct {
    /// Owned. `payload` holds the producing worker's LOCAL symbols until
    /// `applyRemap`, then global ones.
    tokens: Token.TokenList,
    /// Owned.
    comments: []const Token.Comment,
    /// Owned. Offsets only; the session renders messages at report time.
    lex_diagnostics: []const LexDiagnostics.Item,
    /// Owned (M1b). `Ast.empty` until the parse phase has run.
    ast: Ast,
    /// Owned (M1c). `Bir.empty` until the lower phase has run. Its
    /// `symbols` hold the producing worker's LOCAL symbols until
    /// `applyRemap`, like the token payloads.
    bir: Bir,
    /// Owned (M1d). The file's canonical text, produced by the `format`
    /// phase on a worker. `null` means "not formatted": either the phase
    /// did not run, or the file has a diagnostic and therefore no canonical
    /// form. An EMPTY file formats to zero bytes, which is why this is an
    /// optional and not a length test.
    formatted: ?[]const u8,
    /// Which worker's interner the token payloads and Bir symbols refer to.
    worker: u32,

    pub const empty: File = .{ .tokens = .empty, .comments = &.{}, .lex_diagnostics = &.{}, .ast = .empty, .bir = .empty, .formatted = null, .worker = 0 };

    fn deinit(file: *File, gpa: Allocator) void {
        file.tokens.deinit(gpa);
        gpa.free(file.comments);
        gpa.free(file.lex_diagnostics);
        file.ast.deinit(gpa);
        file.bir.deinit(gpa);
        if (file.formatted) |text| gpa.free(text);
        file.* = undefined;
    }
};

pub fn deinit(a: *Artifacts, gpa: Allocator) void {
    a.freeAll(gpa);
    a.files.deinit(gpa);
    a.* = undefined;
}

fn freeAll(a: *Artifacts, gpa: Allocator) void {
    for (0..a.files.len) |i| {
        var file = a.files.get(i);
        file.deinit(gpa);
    }
}

/// Make room for `count` files, all empty. Frees whatever a previous run
/// left. Called serially before workers start.
pub fn resize(a: *Artifacts, gpa: Allocator, count: u32) Allocator.Error!void {
    a.freeAll(gpa);
    a.files.shrinkRetainingCapacity(0);
    try a.files.ensureTotalCapacity(gpa, count);
    for (0..count) |_| a.files.appendAssumeCapacity(File.empty);
}

/// Install `file`'s artifacts, taking ownership; whatever was there is
/// freed. Safe from a worker for its own index.
pub fn set(a: *Artifacts, gpa: Allocator, index: SourceStore.Index, file: File) void {
    var old = a.files.get(index.int());
    old.deinit(gpa);
    a.files.set(index.int(), file);
}

pub fn tokens(a: *const Artifacts, index: SourceStore.Index) *const Token.TokenList {
    return &a.files.items(.tokens)[index.int()];
}

pub fn comments(a: *const Artifacts, index: SourceStore.Index) []const Token.Comment {
    return a.files.items(.comments)[index.int()];
}

pub fn lexDiagnostics(a: *const Artifacts, index: SourceStore.Index) []const LexDiagnostics.Item {
    return a.files.items(.lex_diagnostics)[index.int()];
}

pub fn ast(a: *const Artifacts, index: SourceStore.Index) *const Ast {
    return &a.files.items(.ast)[index.int()];
}

pub fn bir(a: *const Artifacts, index: SourceStore.Index) *const Bir {
    return &a.files.items(.bir)[index.int()];
}

/// The file's canonical text, or null when it was not formatted (see
/// `File.formatted`).
pub fn formatted(a: *const Artifacts, index: SourceStore.Index) ?[]const u8 {
    return a.files.items(.formatted)[index.int()];
}

/// Install `index`'s canonical text, taking ownership. Safe from a worker
/// for its own index, like `set`.
pub fn setFormatted(a: *Artifacts, gpa: Allocator, index: SourceStore.Index, text: []const u8) void {
    const slot = &a.files.items(.formatted)[index.int()];
    if (slot.*) |old| gpa.free(old);
    slot.* = text;
}

pub fn worker(a: *const Artifacts, index: SourceStore.Index) u32 {
    return a.files.items(.worker)[index.int()];
}

/// Rewrite the interned payloads of `index`'s tokens and the symbol column
/// of its Bir from local to global symbols (frontend.md §3.3). `remap` is
/// the table `Global.merge` returned for the worker that lexed and lowered
/// this file.
pub fn applyRemap(a: *Artifacts, index: SourceStore.Index, remap: []const InternPool.Symbol) void {
    const list = &a.files.items(.tokens)[index.int()];
    const tags = list.items(.tag);
    const payloads = list.items(.payload);
    for (tags, payloads) |tag, *payload| {
        if (tag.isInterned()) payload.* = @intFromEnum(remap[payload.*]);
    }
    a.files.items(.bir)[index.int()].applyRemap(remap);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "resize, set, applyRemap, and the old entry is freed" {
    const gpa = testing.allocator;
    var a: Artifacts = .{};
    defer a.deinit(gpa);
    try a.resize(gpa, 2);
    try testing.expectEqual(@as(usize, 0), a.tokens(@enumFromInt(1)).len);

    var list: Token.TokenList = .empty;
    try list.append(gpa, .{ .tag = .lower_ident, .start = 0, .line = 0, .payload = 1 });
    try list.append(gpa, .{ .tag = .dot_index, .start = 2, .line = 0, .payload = 1 });
    try list.append(gpa, .{ .tag = .eof, .start = 4, .line = 0, .payload = 0 });
    const cs = try gpa.dupe(Token.Comment, &.{.{ .kind = .plain, .start = 5, .before_token = 2 }});
    var lowered: Bir = .empty;
    lowered.symbols = try gpa.dupe(InternPool.Symbol, &.{ @enumFromInt(1), @enumFromInt(0) });
    a.set(gpa, @enumFromInt(1), .{ .tokens = list, .comments = cs, .lex_diagnostics = &.{}, .ast = .empty, .bir = lowered, .formatted = null, .worker = 3 });
    try testing.expectEqual(@as(u32, 3), a.worker(@enumFromInt(1)));
    try testing.expectEqual(@as(usize, 1), a.comments(@enumFromInt(1)).len);

    // Only interned tags are remapped; the tuple index keeps its value.
    a.applyRemap(@enumFromInt(1), &.{ @enumFromInt(10), @enumFromInt(11) });
    try testing.expectEqualSlices(u32, &.{ 11, 1, 0 }, a.tokens(@enumFromInt(1)).items(.payload));
    try testing.expectEqualSlices(InternPool.Symbol, &.{ @enumFromInt(11), @enumFromInt(10) }, a.bir(@enumFromInt(1)).symbols);

    // Setting again frees the previous columns (the testing allocator
    // would report a leak otherwise), and resize frees everything.
    var again: Token.TokenList = .empty;
    try again.append(gpa, .{ .tag = .eof, .start = 0, .line = 0, .payload = 0 });
    a.set(gpa, @enumFromInt(1), .{ .tokens = again, .comments = &.{}, .lex_diagnostics = &.{}, .ast = .empty, .bir = .empty, .formatted = null, .worker = 0 });
    try a.resize(gpa, 1);
    try testing.expectEqual(@as(usize, 1), a.files.len);
}
