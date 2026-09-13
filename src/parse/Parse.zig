//! The parser (docs/design/language.md §3–§4, §6.5–§6.6, §10; frontend.md
//! §3.5, §8 M1b). Tokens in, an `Ast` out; never fails on user input.
//!
//! Shape, after `std.zig.Parse`: predictive recursive descent for
//! declarations, types and patterns; Pratt for expressions with the fixed
//! table of §6.5; application by juxtaposition; postfix `?`. Committed
//! choice with CONSTANT LOOKAHEAD: the deepest look-ahead is three tokens
//! (`(` operator `)` for an operator-as-function, `{` name `|` for a record
//! update); nothing backtracks, so the parse is linear in the token count.
//!
//! Layout (§4) is one integer, `indent`, plus the index of the current
//! block's head token. `peek` answers "the next token's tag, or `eof` if the
//! token is not inside the current block" — a token is inside iff its
//! column is greater than `indent`, or it is the head itself. Every grammar
//! function reads tokens only through `peek`, so a token left of the block
//! is simply invisible to it and the enclosing construct decides what it
//! means. That is the whole mechanism: `let` bindings and `case` branches
//! add the "sibling at exactly this column" check on top, and top-level
//! declarations are parsed with `indent = 1`, which is why a column-1 token
//! ends everything (§4 rule 1, rule 6).
//!
//! Errors (§10) never stop the file. Two kinds:
//!   - SOFT: the construct is fine to build, only a rule was broken
//!     (`non_associative_chain`, `pub_on_definition`, …). Report, build,
//!     continue.
//!   - HARD: a required construct or token is missing. The parser reports,
//!     emits a structurally valid `error_*` placeholder node, and either
//!     continues as if the missing token were present (`expectToken`: an
//!     `expected_token` where exactly one token can come next — this is what
//!     lets `if x 1 else 2` still produce an `if` with three children) or
//!     resynchronises (`recover`: skip to the closing delimiter of the
//!     innermost open bracket, or to the first token left of the current
//!     block, whichever comes first — a column-1 token always qualifies, so
//!     a broken declaration never swallows the next one).
//! Two dampers keep one mistake from becoming five diagnostics: never two
//! errors at the same source offset, and nothing is reported while
//! resynchronising until a token has been consumed again. `invalid` tokens
//! from the lexer are consumed as placeholders with no second diagnostic.
//!
//! Every loop consumes at least one token per iteration or breaks — the
//! `assertProgress` calls check that in Debug — and every function returns
//! at `eof`, so the parse terminates on any token sequence; the fuzz and
//! stress tests at the bottom are the evidence.
//!
//! Memory: nodes, extra and errors go to `gpa` (session-owned, see
//! `Artifacts.zig`), pre-sized from the token count so a typical file never
//! grows them; the scratch stacks come from the worker's arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Token = @import("../lex/Token.zig");
const Tokenizer = @import("../lex/Tokenizer.zig");
const LexDiagnostics = @import("../lex/Diagnostics.zig");
const Ast = @import("Ast.zig");
const Diagnostics = @import("Diagnostics.zig");

const Tag = Token.Tag;
const Node = Ast.Node;
const Index = Node.Index;
const TokenIndex = Ast.TokenIndex;
const SubRange = Ast.SubRange;
const Context = Diagnostics.Context;
const Construct = Diagnostics.Construct;

const Parse = @This();

gpa: Allocator,
scratch_allocator: Allocator,
source: [:0]const u8,
tags: []const Tag,
starts: []const u32,
lines: []const u32,
payloads: []const u32,
comments: []const Token.Comment,
line_starts: []const u32,
lex_diagnostics: []const LexDiagnostics.Item,

/// Next unconsumed token. Never past the final `eof`.
tok_i: TokenIndex = 0,
/// The current block's indent: a token belongs to the block iff its column
/// is greater (§4). 0 at the top level, so every column qualifies there.
indent: u32 = 0,
/// The current block's head token, exempt from the column check (it sits
/// exactly on the indent column).
head: TokenIndex = std.math.maxInt(u32),
/// What the parser is in the middle of, for messages.
context: Context = .module,
/// Set by `recover`, cleared by the next consumed token; errors are not
/// reported while it is set.
recovering: bool = false,
/// Offset of the last reported error; a second error there is dropped.
last_error_start: u32 = std.math.maxInt(u32),
/// Expression nesting, for the depth guard.
depth: u32 = 0,
/// Next unprocessed comment, for doc attachment.
comment_i: u32 = 0,
/// Next lexical diagnostic to match against an `invalid` token.
lex_i: usize = 0,

nodes: Ast.NodeList = .empty,
extra: std.ArrayList(u32) = .empty,
errors: std.ArrayList(Diagnostics.Item) = .empty,
module_doc: Ast.CommentRange = .empty,
/// Scratch: node/token indices being collected into a range.
scratch: std.ArrayList(u32) = .empty,
/// Scratch: the closers of every open bracket, innermost last.
brackets: std.ArrayList(Tag) = .empty,

/// Deeper nesting than this reports `nesting_too_deep` instead of
/// recursing: one level per bracket, block form, right-associative operator
/// or negation, each costing a few stack frames, and a hostile file must not
/// overflow the thread's stack (16 MiB by default; the hermetic test parses
/// `max_depth` nested parentheses clean in Debug, where frames are largest).
pub const max_depth: u32 = 4096;

/// Nodes per token, measured on the generated 100k-line corpus (0.74) and
/// bench/corpus (0.80); rounded up to 7/8 so a typical file never regrows.
pub fn estimatedNodeCount(tokens: usize) usize {
    return tokens * 7 / 8 + 16;
}

/// Extra words per token, measured the same way (0.76 and 0.77).
pub fn estimatedExtraCount(tokens: usize) usize {
    return tokens * 7 / 8 + 16;
}

/// Parse one file's token stream. `gpa` owns the returned tree; `scratch`
/// (the worker's arena) takes the parser's stacks and is not referenced by
/// the result. `comments` and `lex_diagnostics` are the tokenizer's, read
/// only.
pub fn parse(
    gpa: Allocator,
    scratch: Allocator,
    source: [:0]const u8,
    tokens: Token.TokenList.Slice,
    comments: []const Token.Comment,
    line_starts: []const u32,
    lex_diagnostics: []const LexDiagnostics.Item,
) Allocator.Error!Ast {
    std.debug.assert(tokens.len > 0 and tokens.items(.tag)[tokens.len - 1] == .eof);
    var p: Parse = .{
        .gpa = gpa,
        .scratch_allocator = scratch,
        .source = source,
        .tags = tokens.items(.tag),
        .starts = tokens.items(.start),
        .lines = tokens.items(.line),
        .payloads = tokens.items(.payload),
        .comments = comments,
        .line_starts = line_starts,
        .lex_diagnostics = lex_diagnostics,
    };
    errdefer {
        p.nodes.deinit(gpa);
        p.extra.deinit(gpa);
        p.errors.deinit(gpa);
    }
    // Free on an arena is a no-op; on a testing allocator it is the leak check.
    defer p.scratch.deinit(scratch);
    defer p.brackets.deinit(scratch);
    try p.nodes.ensureTotalCapacity(gpa, estimatedNodeCount(tokens.len));
    try p.extra.ensureTotalCapacity(gpa, estimatedExtraCount(tokens.len));

    try p.parseModule();

    // Source order for the report: an `unclosed_delimiter` is detected after
    // the errors inside its brackets, doc-comment errors when the next
    // declaration starts.
    std.mem.sort(Diagnostics.Item, p.errors.items, {}, struct {
        fn lessThan(_: void, a: Diagnostics.Item, b: Diagnostics.Item) bool {
            return a.start < b.start;
        }
    }.lessThan);

    const extra = try p.extra.toOwnedSlice(gpa);
    errdefer gpa.free(extra);
    const errors = try p.errors.toOwnedSlice(gpa);
    return .{
        .nodes = p.nodes.toOwnedSlice(),
        .extra = extra,
        .errors = errors,
        .module_doc = p.module_doc,
    };
}

// ---------------------------------------------------------------------------
// Tokens and layout
// ---------------------------------------------------------------------------

fn col(p: *const Parse, i: TokenIndex) u32 {
    return p.starts[i] - p.line_starts[p.lines[i]] + 1;
}

fn inBlock(p: *const Parse, i: TokenIndex) bool {
    return i == p.head or p.col(i) > p.indent;
}

/// The next token's tag if it belongs to the current block, else `eof`.
/// The lexer's zero-length marker for a string cut off by its line end
/// (language.md §2.6) also reads as `eof`: nothing can follow it on the
/// line, and only the string parser needs to see it (`atCutMarker`).
fn peek(p: *const Parse) Tag {
    if (!p.inBlock(p.tok_i) or p.atCutMarker()) return .eof;
    return p.tags[p.tok_i];
}

/// True when the next token is the zero-length `invalid` the lexer leaves
/// where an unterminated string was cut off.
fn atCutMarker(p: *const Parse) bool {
    return p.tags[p.tok_i] == .invalid and p.tokenEnd(p.tok_i) == p.starts[p.tok_i];
}

/// Lookahead `n` tokens past the next one, with the same block rule; `eof`
/// at or past the end.
fn peekAt(p: *const Parse, n: u32) Tag {
    const i = p.tok_i + n;
    if (i >= p.tags.len) return .eof;
    return if (p.inBlock(i)) p.tags[i] else .eof;
}

/// The raw tag of the next token, block or not.
fn rawTag(p: *const Parse) Tag {
    return p.tags[p.tok_i];
}

/// Consume the next token. Never consumes `eof`.
fn next(p: *Parse) TokenIndex {
    std.debug.assert(p.tags[p.tok_i] != .eof);
    const i = p.tok_i;
    p.tok_i += 1;
    p.recovering = false;
    return i;
}

fn eat(p: *Parse, tag: Tag) ?TokenIndex {
    return if (p.peek() == tag) p.next() else null;
}

fn tokenEnd(p: *const Parse, i: TokenIndex) u32 {
    return Tokenizer.tokenEnd(p.source, p.tags[i], p.starts[i]);
}

fn tokenText(p: *const Parse, i: TokenIndex) []const u8 {
    return p.source[p.starts[i]..p.tokenEnd(i)];
}

/// True when token `i` starts on the byte right after token `i - 1` ends.
fn adjacent(p: *const Parse, i: TokenIndex) bool {
    return i > 0 and p.starts[i] == p.tokenEnd(i - 1);
}

const Saved = struct { indent: u32, head: TokenIndex, context: Context };

/// Enter a block whose head is the next token (§4): everything after the
/// head must sit right of the head's column.
fn startBlock(p: *Parse, context: Context) Saved {
    const saved: Saved = .{ .indent = p.indent, .head = p.head, .context = p.context };
    p.indent = p.col(p.tok_i);
    p.head = p.tok_i;
    p.context = context;
    return saved;
}

fn endBlock(p: *Parse, saved: Saved) void {
    p.indent = saved.indent;
    p.head = saved.head;
    p.context = saved.context;
}

fn setContext(p: *Parse, context: Context) Context {
    const previous = p.context;
    p.context = context;
    return previous;
}

/// Debug-only: a loop iteration that is about to loop again consumed at
/// least one token, so every loop terminates at `eof`.
fn assertProgress(p: *const Parse, before: TokenIndex) void {
    std.debug.assert(p.tok_i > before);
}

// ---------------------------------------------------------------------------
// Nodes and extra data
// ---------------------------------------------------------------------------

fn addNode(p: *Parse, node: Node) Allocator.Error!Index {
    const i: Index = @enumFromInt(p.nodes.len);
    try p.nodes.append(p.gpa, node);
    return i;
}

fn leaf(p: *Parse, tag: Node.Tag, main_token: TokenIndex) Allocator.Error!Index {
    return p.addNode(.{ .tag = tag, .main_token = main_token, .data = .{ .lhs = 0, .rhs = 0 } });
}

fn unary(p: *Parse, tag: Node.Tag, main_token: TokenIndex, operand: Index) Allocator.Error!Index {
    return p.addNode(.{ .tag = tag, .main_token = main_token, .data = .{ .lhs = operand.int(), .rhs = 0 } });
}

fn binary(p: *Parse, tag: Node.Tag, main_token: TokenIndex, lhs: Index, rhs: Index) Allocator.Error!Index {
    return p.addNode(.{ .tag = tag, .main_token = main_token, .data = .{ .lhs = lhs.int(), .rhs = rhs.int() } });
}

fn rangeNode(p: *Parse, tag: Node.Tag, main_token: TokenIndex, range: SubRange) Allocator.Error!Index {
    return p.addNode(.{ .tag = tag, .main_token = main_token, .data = .{ .lhs = @intFromEnum(range.start), .rhs = @intFromEnum(range.end) } });
}

/// Copy `items` (node or token indices) into `extra` as a range.
fn listToRange(p: *Parse, items: []const u32) Allocator.Error!SubRange {
    const start: u32 = @intCast(p.extra.items.len);
    try p.extra.appendSlice(p.gpa, items);
    return .{ .start = @enumFromInt(start), .end = @enumFromInt(p.extra.items.len) };
}

/// Append a record to `extra`, nested structs flattened in order.
fn addExtra(p: *Parse, record: anytype) Allocator.Error!Ast.ExtraIndex {
    const T = @TypeOf(record);
    try p.extra.ensureUnusedCapacity(p.gpa, Ast.extraLen(T));
    const start: Ast.ExtraIndex = @enumFromInt(p.extra.items.len);
    p.appendExtraFields(record);
    return start;
}

fn appendExtraFields(p: *Parse, record: anytype) void {
    inline for (std.meta.fields(@TypeOf(record))) |field| {
        const value = @field(record, field.name);
        switch (@typeInfo(field.type)) {
            .@"struct" => p.appendExtraFields(value),
            .@"enum" => p.extra.appendAssumeCapacity(@intFromEnum(value)),
            .int => p.extra.appendAssumeCapacity(value),
            else => @compileError("unexpected extra field type: " ++ @typeName(field.type)),
        }
    }
}

/// The scratch stack's current height, to be restored by `shrinkScratch`.
fn scratchMark(p: *const Parse) usize {
    return p.scratch.items.len;
}

fn pushScratch(p: *Parse, value: anytype) Allocator.Error!void {
    const v: u32 = switch (@TypeOf(value)) {
        Index => value.int(),
        u32 => value,
        comptime_int => value,
        else => @compileError("scratch takes node or token indices"),
    };
    try p.scratch.append(p.scratch_allocator, v);
}

fn scratchSince(p: *const Parse, mark: usize) []const u32 {
    return p.scratch.items[mark..];
}

fn shrinkScratch(p: *Parse, mark: usize) void {
    p.scratch.shrinkRetainingCapacity(mark);
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Record `item` unless a damper applies. Returns its index in `errors`.
fn report(p: *Parse, item: Diagnostics.Item) Allocator.Error!?u32 {
    @branchHint(.cold);
    if (p.recovering) return null;
    if (item.start == p.last_error_start) return null;
    // The lexer already reported this token (language.md §2: every lexical
    // error produces an `invalid` token); it needs no second diagnostic.
    if (p.tags[p.tok_i] == .invalid and item.start == p.starts[p.tok_i]) return null;
    p.last_error_start = item.start;
    try p.errors.append(p.gpa, item);
    return @intCast(p.errors.items.len - 1);
}

/// An item at the next token, with the layout fields filled in when the
/// token is outside the current block.
fn itemAt(p: *const Parse, code: diagnostic.Code) Diagnostics.Item {
    var item: Diagnostics.Item = .{
        .code = code,
        .start = p.starts[p.tok_i],
        .end = p.tokenEnd(p.tok_i),
        .context = p.context,
    };
    if (p.rawTag() != .eof and !p.inBlock(p.tok_i)) {
        item.layout = true;
        item.required_col = p.indent;
        item.head_start = p.starts[p.head];
        item.head_end = p.tokenEnd(p.head);
    }
    return item;
}

fn itemAtToken(p: *const Parse, code: diagnostic.Code, token: TokenIndex) Diagnostics.Item {
    return .{ .code = code, .start = p.starts[token], .end = p.tokenEnd(token), .context = p.context };
}

/// Report a hard error and build its placeholder node at the next token.
fn errorNode(p: *Parse, tag: Node.Tag, item: Diagnostics.Item) Allocator.Error!Index {
    @branchHint(.cold);
    const index = try p.report(item);
    return p.addNode(.{
        .tag = tag,
        .main_token = p.tok_i,
        .data = .{ .lhs = @intFromEnum(item.code), .rhs = index orelse std.math.maxInt(u32) },
    });
}

/// `unexpected_token`: the start of `construct` was needed and the next
/// token cannot begin one.
fn unexpected(p: *Parse, tag: Node.Tag, construct: Construct) Allocator.Error!Index {
    @branchHint(.cold);
    var item = p.itemAt(.unexpected_token);
    item.construct = construct;
    return p.errorNode(tag, item);
}

/// Consume an `invalid` token from the lexer as a silent placeholder carrying
/// the lexical code it was reported with.
fn invalidNode(p: *Parse, tag: Node.Tag) Allocator.Error!Index {
    std.debug.assert(p.rawTag() == .invalid);
    const start = p.starts[p.tok_i];
    // Both streams are in source order; the diagnostic's range contains
    // the token (an unterminated string's marker sits at the range end).
    while (p.lex_i < p.lex_diagnostics.len and p.lex_diagnostics[p.lex_i].end < start) p.lex_i += 1;
    const code: diagnostic.Code = if (p.lex_i < p.lex_diagnostics.len and p.lex_diagnostics[p.lex_i].start <= start)
        p.lex_diagnostics[p.lex_i].code
    else
        .invalid_character;
    const token = p.next();
    return p.addNode(.{ .tag = tag, .main_token = token, .data = .{ .lhs = @intFromEnum(code), .rhs = std.math.maxInt(u32) } });
}

/// Skip `invalid` tokens the lexer already reported (`peek` hides the
/// cut-off marker, so this never consumes it).
fn skipInvalid(p: *Parse) void {
    while (p.peek() == .invalid) _ = p.next();
}

/// Expect exactly `tag` next. When it is missing, report `expected_token`
/// and continue as if it had been there (returns null). `invalid` tokens in
/// the way are skipped silently; a string cut off by its line end has
/// already been reported by the lexer and gets no second diagnostic.
fn expectToken(p: *Parse, tag: Tag) Allocator.Error!?TokenIndex {
    p.skipInvalid();
    if (p.peek() == tag) return p.next();
    if (p.atCutMarker()) return null;
    var item = p.itemAt(.expected_token);
    item.expected = tag;
    _ = try p.report(item);
    return null;
}

/// Expect the closer of the bracket opened at `open`. A closer that is
/// missing because the block ended (or the file did) is
/// `unclosed_delimiter` at the opener; any other token is `expected_token`.
fn expectCloser(p: *Parse, tag: Tag, open: TokenIndex) Allocator.Error!void {
    p.skipInvalid();
    if (p.peek() == tag) {
        _ = p.next();
        return;
    }
    if (p.atCutMarker()) return; // the lexer reported the cut string
    if (p.peek() == .eof) {
        var item = p.itemAtToken(.unclosed_delimiter, open);
        item.expected = tag;
        item.required_col = p.indent;
        if (p.rawTag() != .eof) {
            item.head_start = p.starts[p.tok_i];
            item.head_end = p.tokenEnd(p.tok_i);
        }
        _ = try p.report(item);
    } else {
        var item = p.itemAt(.expected_token);
        item.expected = tag;
        _ = try p.report(item);
    }
}

fn pushBracket(p: *Parse, closer: Tag) Allocator.Error!void {
    try p.brackets.append(p.scratch_allocator, closer);
}

fn popBracket(p: *Parse) void {
    _ = p.brackets.pop();
}

fn isOpenCloser(p: *const Parse, tag: Tag) bool {
    for (p.brackets.items) |closer| if (closer == tag) return true;
    return false;
}

/// Tokens an enclosing construct may be waiting for. A hard error at one
/// of these does not skip it: the construct that owns it gets to see it,
/// which is what turns `[ 1, , 2 ]` into a three-element list with one
/// placeholder instead of a truncated one.
fn isStructural(tag: Tag) bool {
    return switch (tag) {
        .r_paren, .r_bracket, .r_brace, .interp_end, .str_end, .comma, .pipe, .equal, .colon, .arrow, .keyword_then, .keyword_else, .keyword_of, .keyword_in, .eof => true,
        else => false,
    };
}

/// Resynchronise after a hard error: skip tokens until the closing
/// delimiter of an open bracket (at nesting depth zero), or the first token
/// left of the current block, or `eof`. Sets `recovering`.
fn recover(p: *Parse) void {
    @branchHint(.cold);
    var depth: u32 = 0;
    while (true) {
        const tag = p.tags[p.tok_i];
        if (tag == .eof or !p.inBlock(p.tok_i)) break;
        switch (tag) {
            .l_paren, .l_bracket, .l_brace, .interp_start => depth += 1,
            .r_paren, .r_bracket, .r_brace, .interp_end => {
                if (depth > 0) {
                    depth -= 1;
                } else if (p.isOpenCloser(tag)) {
                    break;
                }
            },
            else => {},
        }
        p.tok_i += 1;
    }
    p.recovering = true;
}

/// `recover` unless the next token is one an enclosing construct wants.
fn recoverUnlessStructural(p: *Parse) void {
    if (!isStructural(p.rawTag())) p.recover();
}

// ---------------------------------------------------------------------------
// Module
// ---------------------------------------------------------------------------

const PendingAnnotation = struct { name: TokenIndex, symbol: u32 };

/// Module := ModuleDoc? Import* Decl*
fn parseModule(p: *Parse) Allocator.Error!void {
    const root = try p.addNode(.{ .tag = .root, .main_token = 0, .data = .{ .lhs = 0, .rhs = 0 } });
    std.debug.assert(root == .root);
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);

    var seen_decl = false;
    var pending: ?PendingAnnotation = null;
    while (true) {
        const before = p.tok_i;
        const tag = p.rawTag();
        if (tag == .eof) break;
        if (p.col(p.tok_i) != 1) {
            // Leftover from the previous item that nothing consumed: only a
            // column-1 token can start the next one (§4 rule 1).
            var item = p.itemAt(.unexpected_token);
            item.context = .module;
            item.construct = .declaration;
            _ = try p.report(item);
            p.skipToColumnOne();
            p.assertProgress(before);
            continue;
        }
        switch (tag) {
            .keyword_import => {
                try p.reportPendingAnnotation(&pending);
                p.drainComments(p.tok_i + 1);
                if (seen_decl) _ = try p.report(p.itemAtToken(.import_after_declaration, p.tok_i));
                try p.pushScratch(try p.parseImport());
            },
            .keyword_pub, .keyword_type, .keyword_foreign, .lower_ident => {
                const docs = p.attachDocs(p.tok_i);
                seen_decl = true;
                try p.pushScratch(try p.parseDecl(docs, &pending));
            },
            else => {
                try p.reportPendingAnnotation(&pending);
                var item = p.itemAt(.expected_declaration);
                item.context = .module;
                item.construct = .declaration;
                _ = try p.report(item);
                p.skipToColumnOne();
            },
        }
        p.assertProgress(before);
    }
    try p.reportPendingAnnotation(&pending);
    p.drainComments(@intCast(p.tags.len));
    const range = try p.listToRange(p.scratchSince(mark));
    p.nodes.items(.data)[0] = .{ .lhs = @intFromEnum(range.start), .rhs = @intFromEnum(range.end) };
}

/// Top-level resynchronisation: the next column-1 token, or `eof`.
fn skipToColumnOne(p: *Parse) void {
    @branchHint(.cold);
    if (p.rawTag() != .eof) p.tok_i += 1;
    while (p.rawTag() != .eof and p.col(p.tok_i) != 1) p.tok_i += 1;
}

fn reportPendingAnnotation(p: *Parse, pending: *?PendingAnnotation) Allocator.Error!void {
    const a = pending.* orelse return;
    pending.* = null;
    var item = p.itemAtToken(.annotation_without_definition, a.name);
    item.context = .annotation;
    _ = try p.report(item);
}

/// Import := 'import' (upper | qualified_upper) ('as' upper)? Exposing?
fn parseImport(p: *Parse) Allocator.Error!Index {
    const saved = p.startBlock(.import);
    defer p.endBlock(saved);
    const import_token = p.next();

    var record: Ast.Import = .{ .name = .none, .alias = .none, .exposed_start = @enumFromInt(0), .exposed_end = @enumFromInt(0), .exposing_token = .none };
    switch (p.peek()) {
        .upper_ident, .qualified_upper => record.name = .fromToken(p.next()),
        else => {
            var item = p.itemAt(.unexpected_token);
            item.construct = .module_name;
            _ = try p.report(item);
            p.recoverUnlessStructural();
        },
    }
    if (p.eat(.keyword_as)) |_| {
        if (try p.expectToken(.upper_ident)) |alias| record.alias = .fromToken(alias);
    }
    if (p.eat(.keyword_exposing)) |exposing| {
        record.exposing_token = .fromToken(exposing);
        p.context = .exposing;
        const mark = p.scratchMark();
        defer p.shrinkScratch(mark);
        if (try p.expectToken(.l_paren)) |open| {
            try p.pushBracket(.r_paren);
            defer p.popBracket();
            // Progress: every iteration that loops again consumed a comma.
            while (true) {
                switch (p.peek()) {
                    .lower_ident, .upper_ident => try p.pushScratch(try p.leaf(.exposed, p.next())),
                    .invalid => try p.pushScratch(try p.invalidNode(.error_exposed)),
                    else => {
                        try p.pushScratch(try p.unexpected(.error_exposed, .exposed_name));
                        p.recoverUnlessStructural();
                    },
                }
                if (p.eat(.comma) == null) break;
            }
            try p.expectCloser(.r_paren, open);
        }
        const range = try p.listToRange(p.scratchSince(mark));
        record.exposed_start = range.start;
        record.exposed_end = range.end;
    }
    const extra = try p.addExtra(record);
    return p.addNode(.{ .tag = .import, .main_token = import_token, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

/// Decl := DocComment? Visibility? (TypeAlias | TypeDecl | Annotation | Definition | Foreign)
fn parseDecl(p: *Parse, docs: Ast.CommentRange, pending: *?PendingAnnotation) Allocator.Error!Index {
    const saved = p.startBlock(.declaration);
    defer p.endBlock(saved);

    var header: Ast.DeclHeader = .{ .pub_token = .none, .opaque_token = .none, .doc_start = docs.start, .doc_end = docs.end };
    if (p.eat(.keyword_pub)) |pub_token| {
        header.pub_token = .fromToken(pub_token);
        if (p.eat(.keyword_opaque)) |opaque_token| header.opaque_token = .fromToken(opaque_token);
    }
    const opaque_token = header.opaque_token.unwrap();

    const node = switch (p.peek()) {
        .keyword_type => blk: {
            if (p.peekAt(1) == .keyword_alias) {
                if (opaque_token) |t| _ = try p.report(p.itemAtToken(.opaque_not_on_type, t));
                try p.reportPendingAnnotation(pending);
                break :blk try p.parseTypeAlias(header);
            }
            try p.reportPendingAnnotation(pending);
            break :blk try p.parseTypeDecl(header);
        },
        .keyword_foreign => blk: {
            if (opaque_token) |_| {
                // `opaque` before `foreign` is unexpected_token (§5.4): after
                // `pub opaque` only `type` may follow.
                var item = p.itemAt(.unexpected_token);
                item.construct = .declaration;
                _ = try p.report(item);
            }
            try p.reportPendingAnnotation(pending);
            break :blk if (p.peekAt(1) == .keyword_type) try p.parseForeignType(header) else try p.parseForeignValue(header);
        },
        .lower_ident => blk: {
            if (opaque_token) |t| _ = try p.report(p.itemAtToken(.opaque_not_on_type, t));
            if (p.peekAt(1) == .colon) {
                try p.reportPendingAnnotation(pending);
                pending.* = .{ .name = p.tok_i, .symbol = p.payloads[p.tok_i] };
                break :blk try p.parseAnnotation(header);
            }
            // An annotated definition: `pub` belongs on the annotation.
            if (pending.*) |a| {
                if (a.symbol == p.payloads[p.tok_i]) {
                    pending.* = null;
                    if (header.pub_token.unwrap()) |t| {
                        var item = p.itemAtToken(.pub_on_definition, t);
                        item.head_start = p.starts[a.name];
                        item.head_end = p.tokenEnd(a.name);
                        _ = try p.report(item);
                    }
                } else try p.reportPendingAnnotation(pending);
            }
            break :blk try p.parseDefinition(header);
        },
        else => blk: {
            try p.reportPendingAnnotation(pending);
            const node = try p.unexpected(.error_decl, .declaration);
            p.recover();
            break :blk node;
        },
    };

    // Whatever the declaration could not consume but is still inside its
    // block is an error here, where the context is known.
    if (p.peek() != .eof) {
        var item = p.itemAt(.unexpected_token);
        item.context = .declaration;
        item.head_start = p.starts[p.head];
        item.head_end = p.tokenEnd(p.head);
        if (p.tags[p.head] == .keyword_pub and p.head + 1 < p.tags.len) {
            item.head_start = p.starts[p.head + 1];
            item.head_end = p.tokenEnd(p.head + 1);
        }
        _ = try p.report(item);
        p.recover();
    }
    return node;
}

/// Annotation := lower_ident ':' Type
fn parseAnnotation(p: *Parse, header: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .annotation;
    const name = p.next();
    _ = p.next(); // ':' by lookahead
    const type_expr = try p.parseType();
    const extra = try p.addExtra(header);
    return p.addNode(.{ .tag = .annotation, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = type_expr.int() } });
}

/// Definition := lower_ident PatAtom* '=' Expr
fn parseDefinition(p: *Parse, header: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .definition;
    const name = p.next();
    const params = try p.parsePatAtoms();
    _ = try p.expectToken(.equal);
    const body = try p.parseExpr();
    const extra = try p.addExtra(Ast.Definition{ .header = header, .params_start = params.start, .params_end = params.end });
    return p.addNode(.{ .tag = .definition, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = body.int() } });
}

/// `PatAtom*` into a range.
fn parsePatAtoms(p: *Parse) Allocator.Error!SubRange {
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    while (canStartPatAtom(p.peek())) {
        const before = p.tok_i;
        defer p.assertProgress(before);
        try p.pushScratch(try p.parsePatAtom());
    }
    return p.listToRange(p.scratchSince(mark));
}

/// `lower_ident*` type parameters into a range of tokens.
fn parseTypeParams(p: *Parse) Allocator.Error!SubRange {
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    while (p.peek() == .lower_ident) try p.pushScratch(p.next());
    return p.listToRange(p.scratchSince(mark));
}

/// A declared name of tag `tag`, or a placeholder declaration when it is
/// missing.
fn expectDeclName(p: *Parse, tag: Tag) Allocator.Error!union(enum) { name: TokenIndex, placeholder: Index } {
    if (p.peek() == tag) return .{ .name = p.next() };
    const construct: Construct = if (tag == .upper_ident) .constructor else .declaration;
    const node = try p.unexpected(.error_decl, construct);
    p.recover();
    return .{ .placeholder = node };
}

/// TypeAlias := 'type' 'alias' upper_ident lower_ident* '=' Type
fn parseTypeAlias(p: *Parse, header: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .type_alias;
    _ = p.next(); // type
    _ = p.next(); // alias
    const name = switch (try p.expectDeclName(.upper_ident)) {
        .name => |n| n,
        .placeholder => |node| return node,
    };
    const params = try p.parseTypeParams();
    _ = try p.expectToken(.equal);
    const body = try p.parseType();
    const extra = try p.addExtra(Ast.TypeAlias{ .header = header, .params_start = params.start, .params_end = params.end });
    return p.addNode(.{ .tag = .type_alias, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = body.int() } });
}

/// TypeDecl := 'type' upper_ident lower_ident* '=' '|'? Ctor ('|' Ctor)*
fn parseTypeDecl(p: *Parse, header: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .type_decl;
    _ = p.next(); // type
    const name = switch (try p.expectDeclName(.upper_ident)) {
        .name => |n| n,
        .placeholder => |node| return node,
    };
    const params = try p.parseTypeParams();
    _ = try p.expectToken(.equal);
    _ = p.eat(.pipe);
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    // Progress: every iteration that loops again consumed a comma (or, in
    // a string, a token of the string).
    while (true) {
        switch (p.peek()) {
            .upper_ident => try p.pushScratch(try p.parseConstructor()),
            .invalid => try p.pushScratch(try p.invalidNode(.error_constructor)),
            else => {
                try p.pushScratch(try p.unexpected(.error_constructor, .constructor));
                p.recoverUnlessStructural();
            },
        }
        if (p.eat(.pipe) == null) break;
    }
    const ctors = try p.listToRange(p.scratchSince(mark));
    const extra = try p.addExtra(Ast.TypeDecl{
        .header = header,
        .params_start = params.start,
        .params_end = params.end,
        .ctors_start = ctors.start,
        .ctors_end = ctors.end,
    });
    return p.addNode(.{ .tag = .type_decl, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

/// Ctor := upper_ident TypeAtom*
fn parseConstructor(p: *Parse) Allocator.Error!Index {
    const name = p.next();
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    while (canStartTypeAtom(p.peek())) {
        const before = p.tok_i;
        defer p.assertProgress(before);
        try p.pushScratch(try p.parseTypeAtom());
    }
    return p.rangeNode(.constructor, name, try p.listToRange(p.scratchSince(mark)));
}

/// Foreign := 'foreign' lower_ident ':' Type
fn parseForeignValue(p: *Parse, header: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .foreign;
    _ = p.next(); // foreign
    const name = switch (try p.expectDeclName(.lower_ident)) {
        .name => |n| n,
        .placeholder => |node| return node,
    };
    _ = try p.expectToken(.colon);
    const type_expr = try p.parseType();
    const extra = try p.addExtra(header);
    return p.addNode(.{ .tag = .foreign_value, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = type_expr.int() } });
}

/// Foreign := 'foreign' 'type' upper_ident lower_ident*
fn parseForeignType(p: *Parse, header: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .foreign;
    _ = p.next(); // foreign
    _ = p.next(); // type
    const name = switch (try p.expectDeclName(.upper_ident)) {
        .name => |n| n,
        .placeholder => |node| return node,
    };
    const params = try p.parseTypeParams();
    const extra = try p.addExtra(Ast.ForeignType{ .header = header, .params_start = params.start, .params_end = params.end });
    return p.addNode(.{ .tag = .foreign_type, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

// ---------------------------------------------------------------------------
// Doc comments (§2.3)
// ---------------------------------------------------------------------------

/// Report every doc block and misplaced module doc among the comments that
/// precede token `before` and have not been looked at yet. Module docs
/// before the first token are collected instead.
fn drainComments(p: *Parse, before: TokenIndex) void {
    while (p.comment_i < p.comments.len and p.comments[p.comment_i].before_token < before) {
        const i = p.comment_i;
        const c = p.comments[i];
        var j = i + 1;
        while (j < p.comments.len and p.comments[j].kind == c.kind and p.comments[j].before_token == c.before_token) j += 1;
        p.handleCommentBlock(i, j);
        p.comment_i = j;
    }
}

/// Process the comments before declaration head `head`, returning the
/// attached `--|` block: the trailing run of doc comments not split from
/// the head by an ordinary comment or a module doc.
fn attachDocs(p: *Parse, head: TokenIndex) Ast.CommentRange {
    p.drainComments(head);
    var attached: Ast.CommentRange = .empty;
    var block_start: ?u32 = null;
    var block_kind: Token.Comment.Kind = .plain;
    var i = p.comment_i;
    while (i < p.comments.len and p.comments[i].before_token == head) : (i += 1) {
        const kind = p.comments[i].kind;
        if (block_start) |s| {
            if (kind != block_kind) {
                if (block_kind == .doc or block_kind == .module_doc) p.handleCommentBlock(s, i);
                block_start = null;
            }
        }
        if (block_start == null) {
            block_start = i;
            block_kind = kind;
        }
    }
    if (block_start) |s| {
        if (block_kind == .doc) {
            attached = .{ .start = s, .end = i };
        } else if (block_kind == .module_doc) {
            p.handleCommentBlock(s, i);
        }
    }
    p.comment_i = i;
    return attached;
}

/// A run of same-kind comments `[start, end)` that is not attached to a
/// declaration: doc → unattached; module doc → merged into the module doc
/// if before the first token, misplaced otherwise; plain → trivia.
fn handleCommentBlock(p: *Parse, start: u32, end: u32) void {
    const c = p.comments[start];
    switch (c.kind) {
        .plain => {},
        .doc => p.reportComment(.doc_comment_unattached, c.start),
        .module_doc => {
            if (c.before_token == 0) {
                if (p.module_doc.end == 0) p.module_doc.start = start;
                p.module_doc.end = end;
            } else {
                p.reportComment(.module_doc_not_at_top, c.start);
            }
        },
    }
}

fn reportComment(p: *Parse, code: diagnostic.Code, start: u32) void {
    // Reported like any other error; the only failure is OOM, which the
    // comment pass cannot propagate through the layout code cheaply, so a
    // dropped diagnostic under OOM is the accepted outcome here.
    const end = Tokenizer.tokenEnd(p.source, .multiline_line, start);
    _ = p.report(.{ .code = code, .start = start, .end = end, .context = .module }) catch {};
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

fn canStartTypeAtom(tag: Tag) bool {
    return switch (tag) {
        .lower_ident, .upper_ident, .qualified_upper, .l_paren, .l_brace, .invalid => true,
        else => false,
    };
}

/// Type := TypeApp ('->' Type)?    (right associative)
fn parseType(p: *Parse) Allocator.Error!Index {
    if (try p.enter()) |placeholder| return placeholder;
    defer p.leave();
    const lhs = try p.parseTypeApp();
    if (p.eat(.arrow)) |arrow| {
        const rhs = try p.parseType();
        return p.binary(.type_fn, arrow, lhs, rhs);
    }
    return lhs;
}

/// TypeApp := (upper_ident | qualified_upper) TypeAtom+ | TypeAtom
fn parseTypeApp(p: *Parse) Allocator.Error!Index {
    switch (p.peek()) {
        .upper_ident, .qualified_upper => {
            const name = p.next();
            const mark = p.scratchMark();
            defer p.shrinkScratch(mark);
            while (canStartTypeAtom(p.peek())) {
                const before = p.tok_i;
                defer p.assertProgress(before);
                try p.pushScratch(try p.parseTypeAtom());
            }
            return p.rangeNode(.type_con, name, try p.listToRange(p.scratchSince(mark)));
        },
        else => return p.parseTypeAtom(),
    }
}

/// TypeAtom := lower | upper | qualified_upper | '(' ')' | '(' Type ')'
///           | '(' Type (',' Type)+ ')' | '{' '}' | '{' fields '}' | '{' lower '|' fields '}'
fn parseTypeAtom(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.type_expr);
    defer p.context = saved_context;
    switch (p.peek()) {
        .lower_ident => return p.leaf(.type_var, p.next()),
        .upper_ident, .qualified_upper => return p.rangeNode(.type_con, p.next(), try p.listToRange(&.{})),
        .l_paren => {
            if (p.peekAt(1) == .r_paren) {
                const open = p.next();
                _ = p.next();
                return p.leaf(.type_unit, open);
            }
            const open = p.next();
            try p.pushBracket(.r_paren);
            defer p.popBracket();
            const first = try p.parseType();
            if (p.peek() != .comma) {
                try p.expectCloser(.r_paren, open);
                return p.unary(.type_paren, open, first);
            }
            const mark = p.scratchMark();
            defer p.shrinkScratch(mark);
            try p.pushScratch(first);
            while (p.eat(.comma)) |_| try p.pushScratch(try p.parseType());
            try p.expectCloser(.r_paren, open);
            return p.rangeNode(.type_tuple, open, try p.listToRange(p.scratchSince(mark)));
        },
        .l_brace => {
            const open = p.next();
            try p.pushBracket(.r_brace);
            defer p.popBracket();
            if (p.peek() == .r_brace) {
                _ = p.next();
                return p.rangeNode(.type_record, open, try p.listToRange(&.{}));
            }
            if (p.peek() == .lower_ident and p.peekAt(1) == .pipe) {
                const base = p.next();
                _ = p.next();
                const fields = try p.parseRecordTypeFields();
                try p.expectCloser(.r_brace, open);
                const extra = try p.addExtra(fields);
                return p.addNode(.{ .tag = .type_record_ext, .main_token = open, .data = .{ .lhs = base, .rhs = @intFromEnum(extra) } });
            }
            const fields = try p.parseRecordTypeFields();
            try p.expectCloser(.r_brace, open);
            return p.rangeNode(.type_record, open, fields);
        },
        .invalid => return p.invalidNode(.error_type),
        else => {
            const node = try p.unexpected(.error_type, .type_expr);
            p.recoverUnlessStructural();
            return node;
        },
    }
}

/// RecordTypeFields := lower_ident ':' Type (',' lower_ident ':' Type)*
fn parseRecordTypeFields(p: *Parse) Allocator.Error!SubRange {
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    // Progress: every iteration that loops again consumed a comma (or, in
    // a string, a token of the string).
    while (true) {
        switch (p.peek()) {
            .lower_ident => {
                const name = p.next();
                _ = try p.expectToken(.colon);
                const type_expr = try p.parseType();
                try p.pushScratch(try p.unary(.record_type_field, name, type_expr));
            },
            .invalid => try p.pushScratch(try p.invalidNode(.error_field)),
            else => {
                try p.pushScratch(try p.unexpected(.error_field, .field_name));
                p.recoverUnlessStructural();
            },
        }
        if (p.eat(.comma) == null) break;
    }
    return p.listToRange(p.scratchSince(mark));
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

/// The depth guard: returns a placeholder instead of descending when the
/// nesting is hostile. Every recursive expression/type/pattern entry point
/// calls it.
fn enter(p: *Parse) Allocator.Error!?Index {
    if (p.depth < max_depth) {
        p.depth += 1;
        return null;
    }
    const node = try p.errorNode(.error_expr, p.itemAt(.nesting_too_deep));
    p.recover();
    return node;
}

fn leave(p: *Parse) void {
    p.depth -= 1;
}

fn isBlockStart(tag: Tag) bool {
    return switch (tag) {
        .keyword_let, .keyword_if, .keyword_case, .backslash => true,
        else => false,
    };
}

/// An atom that may start an argument (negation excluded: after an operand
/// `-` is the binary minus, §6.5).
fn canStartAtom(tag: Tag) bool {
    return switch (tag) {
        .lower_ident, .qualified_lower, .upper_ident, .qualified_upper, .dot_lower, .int, .float, .char, .str_start, .multiline_line, .l_paren, .l_bracket, .l_brace, .invalid => true,
        else => false,
    };
}

/// Expr := 'let' … | 'if' … | 'case' … | '\' … | BinOp
fn parseExpr(p: *Parse) Allocator.Error!Index {
    if (try p.enter()) |placeholder| return placeholder;
    defer p.leave();
    return switch (p.peek()) {
        .keyword_let => p.parseLet(),
        .keyword_if => p.parseIf(),
        .keyword_case => p.parseCase(),
        .backslash => p.parseLambda(),
        else => p.parseBinop(0, .invalid),
    };
}

const Assoc = enum { left, right, none };

const OpInfo = struct {
    /// Precedence from the §6.5 table; binding power is `2 * prec + 2`.
    prec: u8,
    assoc: Assoc,
    tag: Node.Tag,

    fn lbp(info: OpInfo) u8 {
        return 2 * info.prec + 2;
    }
};

fn opInfo(tag: Tag) ?OpInfo {
    return switch (tag) {
        .op_pipe_left => .{ .prec = 0, .assoc = .right, .tag = .pipe_left },
        .op_pipe_right => .{ .prec = 0, .assoc = .left, .tag = .pipe_right },
        .op_or_or => .{ .prec = 2, .assoc = .right, .tag = .bool_or },
        .op_and_and => .{ .prec = 3, .assoc = .right, .tag = .bool_and },
        .op_eq_eq => .{ .prec = 4, .assoc = .none, .tag = .eq },
        .op_slash_eq => .{ .prec = 4, .assoc = .none, .tag = .neq },
        .op_lt => .{ .prec = 4, .assoc = .none, .tag = .lt },
        .op_gt => .{ .prec = 4, .assoc = .none, .tag = .gt },
        .op_lte => .{ .prec = 4, .assoc = .none, .tag = .lte },
        .op_gte => .{ .prec = 4, .assoc = .none, .tag = .gte },
        .op_plus_plus => .{ .prec = 5, .assoc = .right, .tag = .append },
        .op_colon_colon => .{ .prec = 5, .assoc = .right, .tag = .cons },
        .op_plus => .{ .prec = 6, .assoc = .left, .tag = .add },
        .op_minus => .{ .prec = 6, .assoc = .left, .tag = .sub },
        .op_star => .{ .prec = 7, .assoc = .left, .tag = .mul },
        .op_slash => .{ .prec = 7, .assoc = .left, .tag = .div },
        .op_slash_slash => .{ .prec = 7, .assoc = .left, .tag = .int_div },
        .op_caret => .{ .prec = 8, .assoc = .right, .tag = .pow },
        .op_compose_left => .{ .prec = 9, .assoc = .right, .tag = .compose_left },
        .op_compose_right => .{ .prec = 9, .assoc = .left, .tag = .compose_right },
        else => null,
    };
}

/// The operator that may not share a chain with `tag` at the same
/// precedence: `<|` with `|>`, `<<` with `>>` (opposite associativities at
/// one level, §6.5: mixing is `non_associative_chain`).
fn conflicting(tag: Tag) Tag {
    return switch (tag) {
        .op_pipe_left => .op_pipe_right,
        .op_pipe_right => .op_pipe_left,
        .op_compose_left => .op_compose_right,
        .op_compose_right => .op_compose_left,
        else => .invalid,
    };
}

/// BinOp := Postfix (operator Postfix)* (operator Block)?    — Pratt.
/// `min_bp` is the lowest binding power this call may consume; `banned` is
/// an operator that a right-associative caller at the same level forbids.
fn parseBinop(p: *Parse, min_bp: u8, banned: Tag) Allocator.Error!Index {
    var lhs = try p.parsePostfix();
    var banned_prec: i16 = -1;
    var last_op: Tag = .invalid;
    while (true) {
        const tok = p.peek();
        const info = opInfo(tok) orelse break;
        if (info.lbp() < min_bp) break;
        if (info.prec == banned_prec or tok == banned or tok == conflicting(last_op)) {
            @branchHint(.cold);
            _ = try p.report(p.itemAt(.non_associative_chain));
            // Continue as if left-associative so the tree stays complete.
        }
        const op_token = p.next();
        const rhs = if (isBlockStart(p.peek()))
            try p.parseExpr() // the last operand; extends as far as layout allows
        else if (p.peek() == .eof)
            try p.unexpected(.error_expr, .expression)
        else blk: {
            // Right-associative chains recurse once per operator.
            if (try p.enter()) |placeholder| break :blk placeholder;
            defer p.leave();
            break :blk switch (info.assoc) {
                .left => try p.parseBinop(info.lbp() + 1, .invalid),
                .right => try p.parseBinop(info.lbp(), conflicting(tok)),
                .none => try p.parseBinop(info.lbp() + 1, .invalid),
            };
        };
        lhs = try p.binary(info.tag, op_token, lhs, rhs);
        banned_prec = if (info.assoc == .none) info.prec else -1;
        last_op = tok;
    }
    return lhs;
}

/// Postfix := App ('?' …)*  — after `?`, an adjacent `.field`/`.0` chain is
/// allowed (`x?.field` is `(x?).field`); a further argument is
/// `args_after_question` and is applied anyway so the tree stays complete.
fn parsePostfix(p: *Parse) Allocator.Error!Index {
    var node = try p.parseApp();
    while (p.peek() == .question) {
        const q = p.next();
        node = try p.unary(.question, q, node);
        node = try p.parseAccessChain(node);
        if (canStartAtom(p.peek())) {
            @branchHint(.cold);
            _ = try p.report(p.itemAt(.args_after_question));
            node = try p.parseArgs(node);
        }
    }
    return node;
}

/// App := Atom Atom*
fn parseApp(p: *Parse) Allocator.Error!Index {
    const function = try p.parseAtomAccess(true);
    return p.parseArgs(function);
}

/// Arguments after `function`, if any. A block form (`let`, `if`, `case`,
/// lambda) as a bare argument is an error (§3 notes) but is parsed as the
/// last argument so the expression still has a shape.
fn parseArgs(p: *Parse, function: Index) Allocator.Error!Index {
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    try p.pushScratch(function);
    while (true) {
        const before = p.tok_i;
        const tag = p.peek();
        if (canStartAtom(tag)) {
            try p.pushScratch(try p.parseAtomAccess(false));
            p.assertProgress(before);
        } else if (isBlockStart(tag)) {
            @branchHint(.cold);
            var item = p.itemAt(.unexpected_token);
            item.construct = .expression;
            _ = try p.report(item);
            try p.pushScratch(try p.parseExpr());
            break;
        } else break;
    }
    const items = p.scratchSince(mark);
    if (items.len == 1) return function;
    return p.rangeNode(.apply, p.nodes.items(.main_token)[function.int()], try p.listToRange(items));
}

/// Atom followed by its adjacent `.field` / `.0` chain (§3 notes: the dot
/// must start right after the atom's last byte).
fn parseAtomAccess(p: *Parse, operand_start: bool) Allocator.Error!Index {
    const atom = try p.parseAtom(operand_start);
    return p.parseAccessChain(atom);
}

fn parseAccessChain(p: *Parse, base: Index) Allocator.Error!Index {
    var node = base;
    while (true) {
        switch (p.peek()) {
            .dot_lower => {
                if (!p.adjacent(p.tok_i)) break;
                node = try p.unary(.field_access, p.next(), node);
            },
            .dot_index => {
                if (!p.adjacent(p.tok_i)) break;
                const dot = p.next();
                const digits = p.tokenText(dot)[1..];
                if (digits.len > 1 and digits[0] == '0') {
                    @branchHint(.cold);
                    _ = try p.report(p.itemAtToken(.invalid_tuple_index, dot));
                }
                node = try p.unary(.tuple_index, dot, node);
            },
            else => break,
        }
    }
    return node;
}

/// Atom := literal | name | constructor | accessor | '-' Atom | '(' … ')'
///       | '[' … ']' | '{' … '}'
fn parseAtom(p: *Parse, operand_start: bool) Allocator.Error!Index {
    switch (p.peek()) {
        .int => return p.leaf(.int, p.next()),
        .float => return p.leaf(.float, p.next()),
        .char => return p.leaf(.char, p.next()),
        .lower_ident, .qualified_lower => return p.leaf(.ident, p.next()),
        .upper_ident, .qualified_upper => return p.leaf(.ctor, p.next()),
        .dot_lower => return p.leaf(.accessor, p.next()),
        .str_start => return p.parseString(),
        .multiline_line => {
            const first = p.next();
            var last = first;
            // Consecutive lines only (§2.7): a blank line ends the literal.
            while (p.peek() == .multiline_line and p.lines[p.tok_i] == p.lines[last] + 1) last = p.next();
            return p.addNode(.{ .tag = .multiline_string, .main_token = first, .data = .{ .lhs = last, .rhs = 0 } });
        },
        .op_minus => {
            if (!operand_start) return p.unexpectedExpr();
            const minus = p.next();
            if (!p.adjacent(p.tok_i) or p.peek() == .eof) {
                @branchHint(.cold);
                _ = try p.report(p.itemAtToken(.negation_with_space, minus));
            }
            if (try p.enter()) |placeholder| return placeholder;
            defer p.leave();
            const operand = try p.parseAtomAccess(true);
            return p.unary(.negate, minus, operand);
        },
        .l_paren => return p.parseParens(),
        .l_bracket => return p.parseList(),
        .l_brace => return p.parseRecord(),
        .invalid => return p.invalidNode(.error_expr),
        else => return p.unexpectedExpr(),
    }
}

fn unexpectedExpr(p: *Parse) Allocator.Error!Index {
    @branchHint(.cold);
    const node = try p.unexpected(.error_expr, .expression);
    p.recoverUnlessStructural();
    return node;
}

/// '(' ')' | '(' operator ')' | '(' Expr ')' | '(' Expr (',' Expr)+ ')'
fn parseParens(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.parens);
    defer p.context = saved_context;
    const open = p.next();
    if (p.peek() == .r_paren) {
        _ = p.next();
        return p.leaf(.unit, open);
    }
    if (p.peek().isOperator() and p.peekAt(1) == .r_paren) {
        const op = p.next();
        _ = p.next();
        return p.leaf(.op_fn, op);
    }
    try p.pushBracket(.r_paren);
    defer p.popBracket();
    const first = try p.parseExpr();
    if (p.peek() != .comma) {
        try p.expectCloser(.r_paren, open);
        return p.unary(.paren, open, first);
    }
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    try p.pushScratch(first);
    while (p.eat(.comma)) |_| try p.pushScratch(try p.parseExpr());
    try p.expectCloser(.r_paren, open);
    return p.rangeNode(.tuple, open, try p.listToRange(p.scratchSince(mark)));
}

/// '[' ']' | '[' Expr (',' Expr)* ']'
fn parseList(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.list);
    defer p.context = saved_context;
    const open = p.next();
    try p.pushBracket(.r_bracket);
    defer p.popBracket();
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    if (p.peek() != .r_bracket) {
        try p.pushScratch(try p.parseExpr());
        while (p.eat(.comma)) |_| try p.pushScratch(try p.parseExpr());
    }
    try p.expectCloser(.r_bracket, open);
    return p.rangeNode(.list, open, try p.listToRange(p.scratchSince(mark)));
}

/// '{' '}' | '{' Field (',' Field)* '}' | '{' lower_ident '|' Field (',' Field)* '}'
fn parseRecord(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.record);
    defer p.context = saved_context;
    const open = p.next();
    try p.pushBracket(.r_brace);
    defer p.popBracket();
    if (p.peek() == .r_brace) {
        _ = p.next();
        return p.rangeNode(.record, open, try p.listToRange(&.{}));
    }
    if (p.peek() == .lower_ident and p.peekAt(1) == .pipe) {
        p.context = .record_update;
        const base = p.next();
        _ = p.next();
        const fields = try p.parseFields();
        try p.expectCloser(.r_brace, open);
        const extra = try p.addExtra(fields);
        return p.addNode(.{ .tag = .record_update, .main_token = open, .data = .{ .lhs = base, .rhs = @intFromEnum(extra) } });
    }
    const fields = try p.parseFields();
    try p.expectCloser(.r_brace, open);
    return p.rangeNode(.record, open, fields);
}

/// Field := lower_ident '=' Expr, comma separated, at least one.
fn parseFields(p: *Parse) Allocator.Error!SubRange {
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    // Progress: every iteration that loops again consumed a comma (or, in
    // a string, a token of the string).
    while (true) {
        switch (p.peek()) {
            .lower_ident => {
                const name = p.next();
                _ = try p.expectToken(.equal);
                const value = try p.parseExpr();
                try p.pushScratch(try p.unary(.field, name, value));
            },
            .invalid => try p.pushScratch(try p.invalidNode(.error_field)),
            else => {
                try p.pushScratch(try p.unexpected(.error_field, .field_name));
                p.recoverUnlessStructural();
            },
        }
        if (p.eat(.comma) == null) break;
    }
    return p.listToRange(p.scratchSince(mark));
}

/// str_start (str_chunk | interp_start Expr interp_end)* str_end
fn parseString(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.string);
    defer p.context = saved_context;
    const start = p.next();
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    // Progress: every iteration that loops again consumed a comma (or, in
    // a string, a token of the string).
    while (true) {
        if (p.atCutMarker()) {
            // The string ended with its line; the lexer reported it.
            _ = p.next();
            break;
        }
        switch (p.peek()) {
            .str_chunk => try p.pushScratch(try p.leaf(.chunk, p.next())),
            .interp_start => {
                const open = p.next();
                p.context = .interpolation;
                try p.pushBracket(.interp_end);
                const expr = try p.parseExpr();
                try p.expectCloser(.interp_end, open);
                p.popBracket();
                p.context = .string;
                try p.pushScratch(try p.unary(.interp, open, expr));
            },
            .str_end => {
                _ = p.next();
                break;
            },
            // A bad escape, tab or byte inside the string, already reported
            // by the lexer: part of the text, no node.
            .invalid => _ = p.next(),
            .eof => break,
            else => {
                // Leftovers of a broken interpolation; the string is one
                // line, so this is bounded by the line.
                while (true) {
                    switch (p.peek()) {
                        .str_end, .eof, .str_chunk, .interp_start => break,
                        .interp_end => {
                            _ = p.next();
                            break;
                        },
                        else => _ = p.next(),
                    }
                }
            },
        }
    }
    return p.rangeNode(.string, start, try p.listToRange(p.scratchSince(mark)));
}

/// '\' PatAtom+ '->' Expr
fn parseLambda(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.lambda);
    defer p.context = saved_context;
    const backslash = p.next();
    const params = try p.parsePatAtoms();
    if (params.len() == 0) {
        @branchHint(.cold);
        var item = p.itemAt(.unexpected_token);
        item.construct = .pattern;
        _ = try p.report(item);
    }
    _ = try p.expectToken(.arrow);
    const body = try p.parseExpr();
    const extra = try p.addExtra(params);
    return p.addNode(.{ .tag = .lambda, .main_token = backslash, .data = .{ .lhs = @intFromEnum(extra), .rhs = body.int() } });
}

/// 'if' Expr 'then' Expr 'else' Expr
fn parseIf(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.if_expr);
    defer p.context = saved_context;
    const if_token = p.next();
    const cond = try p.parseExpr();
    _ = try p.expectToken(.keyword_then);
    const then_expr = try p.parseExpr();
    _ = try p.expectToken(.keyword_else);
    const else_expr = try p.parseExpr();
    const extra = try p.addExtra(Ast.If{ .then_expr = then_expr, .else_expr = else_expr });
    return p.addNode(.{ .tag = .@"if", .main_token = if_token, .data = .{ .lhs = cond.int(), .rhs = @intFromEnum(extra) } });
}

/// 'case' Expr 'of' Branch+   — branches aligned on the first one (§4).
fn parseCase(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.case_head);
    defer p.context = saved_context;
    const case_token = p.next();
    const scrutinee = try p.parseExpr();
    _ = try p.expectToken(.keyword_of);
    p.context = .case_branches;

    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    if (p.peek() == .eof or !canStartPattern(p.peek())) {
        @branchHint(.cold);
        // Reported at the `case` itself: the token that ended the search
        // is quoted in the message, with the columns.
        var item = p.itemAtToken(.case_without_branches, case_token);
        item.required_col = p.indent;
        if (p.rawTag() != .eof) {
            item.head_start = p.starts[p.tok_i];
            item.head_end = p.tokenEnd(p.tok_i);
        }
        try p.pushScratch(try p.errorNode(.error_branch, item));
    } else {
        const column = p.col(p.tok_i);
        while (true) {
            const before = p.tok_i;
            try p.pushScratch(try p.parseBranch());
            p.assertProgress(before);
            if (p.peek() == .eof or !canStartPattern(p.peek())) break;
            if (p.col(p.tok_i) != column) {
                @branchHint(.cold);
                var item = p.itemAt(.unexpected_token);
                item.construct = .branch;
                item.required_col = column;
                item.head_start = p.starts[before];
                item.head_end = p.tokenEnd(before);
                _ = try p.report(item);
                // Parsed as a branch anyway: it can start one, and the
                // alternative is to lose everything after it.
            }
        }
    }
    const branches = try p.listToRange(p.scratchSince(mark));
    const extra = try p.addExtra(branches);
    return p.addNode(.{ .tag = .case, .main_token = case_token, .data = .{ .lhs = scrutinee.int(), .rhs = @intFromEnum(extra) } });
}

/// Branch := Pattern '->' Expr, its own block headed by the pattern.
fn parseBranch(p: *Parse) Allocator.Error!Index {
    const saved = p.startBlock(.case_branches);
    defer p.endBlock(saved);
    const head = p.tok_i;
    const pattern = try p.parsePattern();
    _ = try p.expectToken(.arrow);
    p.context = .branch_body;
    const body = try p.parseExpr();
    return p.binary(.branch, head, pattern, body);
}

/// 'let' LetBinding+ 'in' Expr   — bindings aligned on the first one (§4).
fn parseLet(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.let_bindings);
    defer p.context = saved_context;
    const let_token = p.next();
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    if (!canStartBinding(p.peek())) {
        @branchHint(.cold);
        try p.pushScratch(try p.unexpected(.error_binding, .binding));
        p.recoverUnlessStructural();
    } else {
        const column = p.col(p.tok_i);
        while (true) {
            const before = p.tok_i;
            try p.pushScratch(try p.parseLetBinding());
            p.assertProgress(before);
            if (!canStartBinding(p.peek())) break;
            if (p.col(p.tok_i) != column) {
                @branchHint(.cold);
                var item = p.itemAt(.unexpected_token);
                item.construct = .binding;
                item.required_col = column;
                item.head_start = p.starts[before];
                item.head_end = p.tokenEnd(before);
                _ = try p.report(item);
            }
        }
    }
    const bindings = try p.listToRange(p.scratchSince(mark));
    _ = try p.expectToken(.keyword_in);
    p.context = .let_body;
    const body = try p.parseExpr();
    const extra = try p.addExtra(bindings);
    return p.addNode(.{ .tag = .let, .main_token = let_token, .data = .{ .lhs = @intFromEnum(extra), .rhs = body.int() } });
}

/// Anything that can start a pattern: a refutable one is still parsed as a
/// binding so it gets the specific `refutable_let_pattern` (§7) instead of
/// ending the binding list.
fn canStartBinding(tag: Tag) bool {
    return canStartPattern(tag);
}

/// LetBinding := Annotation | Definition | LetPattern '=' Expr
fn parseLetBinding(p: *Parse) Allocator.Error!Index {
    const saved = p.startBlock(.let_bindings);
    defer p.endBlock(saved);
    const head = p.tok_i;
    switch (p.peek()) {
        .lower_ident => {
            if (p.peekAt(1) == .colon) {
                const name = p.next();
                _ = p.next();
                const type_expr = try p.parseType();
                return p.unary(.let_annotation, name, type_expr);
            }
            if (p.peekAt(1) != .keyword_as) {
                const name = p.next();
                const params = try p.parsePatAtoms();
                _ = try p.expectToken(.equal);
                const body = try p.parseExpr();
                const extra = try p.addExtra(params);
                return p.addNode(.{ .tag = .let_def, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = body.int() } });
            }
        },
        .invalid => return p.invalidNode(.error_binding),
        else => {},
    }
    const pattern = try p.parsePattern();
    try p.checkIrrefutable(pattern);
    _ = try p.expectToken(.equal);
    const value = try p.parseExpr();
    return p.binary(.let_pattern, head, pattern, value);
}

/// LetPattern (§3, §7): a name, `_`, unit, or tuples/records of those,
/// optionally with `as`. Anything else is `refutable_let_pattern`.
fn checkIrrefutable(p: *Parse, node: Index) Allocator.Error!void {
    const tags = p.nodes.items(.tag);
    const data = p.nodes.items(.data);
    switch (tags[node.int()]) {
        .pat_wild, .pat_var, .pat_unit, .pat_record, .error_pattern => {},
        .pat_paren, .pat_as => try p.checkIrrefutable(@enumFromInt(data[node.int()].lhs)),
        .pat_tuple => {
            const range: SubRange = .{ .start = @enumFromInt(data[node.int()].lhs), .end = @enumFromInt(data[node.int()].rhs) };
            for (p.extra.items[@intFromEnum(range.start)..@intFromEnum(range.end)]) |child| try p.checkIrrefutable(@enumFromInt(child));
        },
        else => {
            @branchHint(.cold);
            var item = p.itemAtToken(.refutable_let_pattern, p.nodes.items(.main_token)[node.int()]);
            item.context = .let_bindings;
            _ = try p.report(item);
        },
    }
}

// ---------------------------------------------------------------------------
// Patterns
// ---------------------------------------------------------------------------

fn canStartPatAtom(tag: Tag) bool {
    return switch (tag) {
        .underscore, .lower_ident, .upper_ident, .qualified_upper, .int, .char, .str_start, .l_paren, .l_bracket, .l_brace, .invalid => true,
        else => false,
    };
}

fn canStartPattern(tag: Tag) bool {
    return canStartPatAtom(tag) or tag == .op_minus;
}

/// Pattern := PatCons ('as' lower_ident)?
fn parsePattern(p: *Parse) Allocator.Error!Index {
    if (try p.enter()) |placeholder| return placeholder;
    defer p.leave();
    const saved_context = p.setContext(.pattern);
    defer p.context = saved_context;
    const inner = try p.parsePatCons();
    if (p.eat(.keyword_as)) |as_token| {
        const name = (try p.expectToken(.lower_ident)) orelse return p.addNode(.{ .tag = .pat_as, .main_token = as_token, .data = .{ .lhs = inner.int(), .rhs = as_token } });
        return p.addNode(.{ .tag = .pat_as, .main_token = as_token, .data = .{ .lhs = inner.int(), .rhs = name } });
    }
    return inner;
}

/// PatCons := PatCtor ('::' PatCons)?    (right associative)
fn parsePatCons(p: *Parse) Allocator.Error!Index {
    const head = try p.parsePatCtor();
    if (p.eat(.op_colon_colon)) |cons| {
        if (try p.enter()) |placeholder| return placeholder;
        defer p.leave();
        const tail = try p.parsePatCons();
        return p.binary(.pat_cons, cons, head, tail);
    }
    return head;
}

/// PatCtor := (upper_ident | qualified_upper) PatAtom* | PatAtom
fn parsePatCtor(p: *Parse) Allocator.Error!Index {
    switch (p.peek()) {
        .upper_ident, .qualified_upper => {
            const name = p.next();
            const args = try p.parsePatAtoms();
            return p.rangeNode(.pat_ctor, name, args);
        },
        .op_minus => return p.parseNegIntPattern(),
        else => return p.parsePatAtom(),
    }
}

fn parseNegIntPattern(p: *Parse) Allocator.Error!Index {
    const minus = p.next();
    if (p.peek() != .int) {
        @branchHint(.cold);
        return p.unexpected(.error_pattern, .pattern);
    }
    _ = p.next();
    return p.leaf(.pat_neg_int, minus);
}

/// PatAtom := '_' | lower | upper | qualified_upper | int | char | string
///          | '(' ')' | '(' Pattern ')' | '(' Pattern (',' Pattern)+ ')'
///          | '[' ']' | '[' Pattern (',' Pattern)* ']' | '{' lower (',' lower)* '}'
fn parsePatAtom(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.pattern);
    defer p.context = saved_context;
    switch (p.peek()) {
        .underscore => return p.leaf(.pat_wild, p.next()),
        .lower_ident => return p.leaf(.pat_var, p.next()),
        .upper_ident, .qualified_upper => return p.rangeNode(.pat_ctor, p.next(), try p.listToRange(&.{})),
        .int => return p.leaf(.pat_int, p.next()),
        .char => return p.leaf(.pat_char, p.next()),
        .str_start => {
            const start = p.next();
            var node: ?Index = null;
            while (true) {
                if (p.atCutMarker()) {
                    _ = p.next();
                    break;
                }
                switch (p.peek()) {
                    .str_chunk, .invalid => _ = p.next(),
                    .str_end => {
                        _ = p.next();
                        break;
                    },
                    .interp_start => {
                        // A string pattern has no interpolation (§3).
                        if (node == null) node = try p.unexpected(.error_pattern, .pattern);
                        _ = p.next();
                    },
                    .eof => break,
                    else => _ = p.next(),
                }
            }
            return node orelse p.leaf(.pat_string, start);
        },
        .l_paren => {
            const open = p.next();
            if (p.peek() == .r_paren) {
                _ = p.next();
                return p.leaf(.pat_unit, open);
            }
            try p.pushBracket(.r_paren);
            defer p.popBracket();
            const first = try p.parsePattern();
            if (p.peek() != .comma) {
                try p.expectCloser(.r_paren, open);
                return p.unary(.pat_paren, open, first);
            }
            const mark = p.scratchMark();
            defer p.shrinkScratch(mark);
            try p.pushScratch(first);
            while (p.eat(.comma)) |_| try p.pushScratch(try p.parsePattern());
            try p.expectCloser(.r_paren, open);
            return p.rangeNode(.pat_tuple, open, try p.listToRange(p.scratchSince(mark)));
        },
        .l_bracket => {
            const open = p.next();
            try p.pushBracket(.r_bracket);
            defer p.popBracket();
            const mark = p.scratchMark();
            defer p.shrinkScratch(mark);
            if (p.peek() != .r_bracket) {
                try p.pushScratch(try p.parsePattern());
                while (p.eat(.comma)) |_| try p.pushScratch(try p.parsePattern());
            }
            try p.expectCloser(.r_bracket, open);
            return p.rangeNode(.pat_list, open, try p.listToRange(p.scratchSince(mark)));
        },
        .l_brace => {
            const open = p.next();
            try p.pushBracket(.r_brace);
            defer p.popBracket();
            const mark = p.scratchMark();
            defer p.shrinkScratch(mark);
            // Progress: every iteration that loops again consumed a comma.
            while (true) {
                if (p.peek() == .lower_ident) {
                    try p.pushScratch(p.next());
                } else {
                    var item = p.itemAt(.unexpected_token);
                    item.construct = .field_name;
                    _ = try p.report(item);
                    p.recoverUnlessStructural();
                }
                if (p.eat(.comma) == null) break;
            }
            try p.expectCloser(.r_brace, open);
            return p.rangeNode(.pat_record, open, try p.listToRange(p.scratchSince(mark)));
        },
        .invalid => return p.invalidNode(.error_pattern),
        else => {
            const node = try p.unexpected(.error_pattern, .pattern);
            p.recoverUnlessStructural();
            return node;
        },
    }
}

// ---------------------------------------------------------------------------
// Tests. Each parses a string and asserts the whole tree as the dump text
// (`dump/ast.zig`): that is the whole-object assertion for a tree. Errors
// are asserted as (code, line, column) triples in source order; a few
// messages are pinned in full, the rest through the black-box suite.
// ---------------------------------------------------------------------------

const testing = std.testing;
const InternPool = @import("../InternPool.zig");
const dump_ast = @import("../dump/ast.zig");

const Parsed = struct {
    out: Tokenizer.Output,
    tree: Ast,

    fn deinit(r: *Parsed) void {
        r.tree.deinit(testing.allocator);
        r.out.deinit(testing.allocator);
    }
};

fn parseSource(interner: *InternPool.Local, source: [:0]const u8) !Parsed {
    var out: Tokenizer.Output = .empty;
    errdefer out.deinit(testing.allocator);
    try Tokenizer.tokenize(testing.allocator, source, interner, &out);
    const tree = try parse(testing.allocator, testing.allocator, source, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
    return .{ .out = out, .tree = tree };
}

const ExpectedError = struct { code: diagnostic.Code, line: u32, col: u32 };

fn expectTree(source: [:0]const u8, expected: []const u8, expected_errors: []const ExpectedError) !void {
    var interner: InternPool.Local = .empty;
    defer interner.deinit(testing.allocator);
    var r = try parseSource(&interner, source);
    defer r.deinit();
    try checkWellFormed(&r.tree, r.out.tokens.len, r.out.comments.items.len);

    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try dump_ast.write(&text.writer, source, &r.out.tokens, r.out.comments.items, r.out.line_starts.items, &r.tree, .{});
    try testing.expectEqualStrings(expected, text.written());

    var mismatch = r.tree.errors.len != expected_errors.len;
    if (!mismatch) for (r.tree.errors, expected_errors) |got, want| {
        const pos = LexDiagnostics.position(r.out.line_starts.items, got.start);
        if (got.code != want.code or pos.line != want.line or pos.col != want.col) mismatch = true;
    };
    if (mismatch) {
        std.debug.print("errors differ; got:\n", .{});
        for (r.tree.errors) |got| {
            const pos = LexDiagnostics.position(r.out.line_starts.items, got.start);
            std.debug.print("  {t} at {d}:{d}\n", .{ got.code, pos.line, pos.col });
        }
        return error.TestExpectedEqual;
    }
}

fn expectClean(source: [:0]const u8, expected: []const u8) !void {
    try expectTree(source, expected, &.{});
}

/// The message of error `index`, rendered.
fn expectErrorMessage(source: [:0]const u8, index: usize, expected: []const u8) !void {
    var interner: InternPool.Local = .empty;
    defer interner.deinit(testing.allocator);
    var r = try parseSource(&interner, source);
    defer r.deinit();
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try Diagnostics.message(r.tree.errors[index], source, r.out.line_starts.items, &text.writer);
    try testing.expectEqualStrings(expected, text.written());
}

/// The structural contract of every tree, parsed from anything: the root
/// is node 0; every node's main token exists; every child index and every
/// extra range is in bounds (walking through the same views consumers
/// use, so a view that decoded the wrong words would fail here too); the
/// errors are inside the source and in order.
fn checkWellFormed(tree: *const Ast, token_count: usize, comment_count: usize) !void {
    try testing.expect(tree.nodes.len >= 1);
    try testing.expectEqual(Node.Tag.root, tree.nodeTag(.root));
    for (0..tree.nodes.len) |i| {
        const n: Index = @enumFromInt(i);
        try testing.expect(tree.nodeMainToken(n) < token_count);
        try checkNode(tree, n, token_count, comment_count);
    }
    try testing.expect(tree.module_doc.start <= tree.module_doc.end and tree.module_doc.end <= comment_count);
    var last: u32 = 0;
    for (tree.errors) |e| {
        try testing.expect(e.start <= e.end);
        try testing.expect(e.start >= last);
        last = e.start;
    }
}

fn checkIndex(tree: *const Ast, n: Index) !void {
    try testing.expect(n.int() < tree.nodes.len);
}

fn checkIndices(tree: *const Ast, nodes: []const Index) !void {
    for (nodes) |n| try checkIndex(tree, n);
}

fn checkTokens(tokens: []const TokenIndex, token_count: usize) !void {
    for (tokens) |t| try testing.expect(t < token_count);
}

fn checkHeader(h: Ast.DeclHeader, token_count: usize, comment_count: usize) !void {
    if (h.pub_token.unwrap()) |t| try testing.expect(t < token_count);
    if (h.opaque_token.unwrap()) |t| try testing.expect(t < token_count);
    try testing.expect(h.doc_start <= h.doc_end and h.doc_end <= comment_count);
}

fn checkNode(tree: *const Ast, n: Index, token_count: usize, comment_count: usize) !void {
    const tag = tree.nodeTag(n);
    if (tag.isError()) {
        const e = tree.fullError(n);
        if (e.error_index) |i| try testing.expect(i < tree.errors.len);
        return;
    }
    switch (tag) {
        .root => try checkIndices(tree, tree.rootItems()),
        .import => {
            const i = tree.fullImport(n);
            if (i.name) |t| try testing.expect(t < token_count);
            if (i.alias) |t| try testing.expect(t < token_count);
            try checkIndices(tree, i.exposed);
        },
        .exposed, .type_var, .type_unit, .int, .float, .char, .chunk, .ident, .ctor, .accessor, .op_fn, .unit, .pat_wild, .pat_var, .pat_int, .pat_neg_int, .pat_char, .pat_string, .pat_unit => {},
        .annotation => {
            const a = tree.fullAnnotation(n);
            try checkHeader(a.header, token_count, comment_count);
            try checkIndex(tree, a.type_expr);
        },
        .definition => {
            const d = tree.fullDefinition(n);
            try checkHeader(d.header, token_count, comment_count);
            try checkIndices(tree, d.params);
            try checkIndex(tree, d.body);
        },
        .type_alias => {
            const a = tree.fullTypeAlias(n);
            try checkHeader(a.header, token_count, comment_count);
            try checkTokens(a.params, token_count);
            try checkIndex(tree, a.body);
        },
        .type_decl => {
            const t = tree.fullTypeDecl(n);
            try checkHeader(t.header, token_count, comment_count);
            try checkTokens(t.params, token_count);
            try checkIndices(tree, t.ctors);
        },
        .foreign_value => {
            const f = tree.fullForeignValue(n);
            try checkHeader(f.header, token_count, comment_count);
            try checkIndex(tree, f.type_expr);
        },
        .foreign_type => {
            const f = tree.fullForeignType(n);
            try checkHeader(f.header, token_count, comment_count);
            try checkTokens(f.params, token_count);
        },
        .constructor, .type_con, .type_tuple, .type_record, .string, .tuple, .list, .record, .apply, .pat_ctor, .pat_tuple, .pat_list => {
            const items = tree.children(n);
            try checkIndices(tree, items);
            if (tag == .apply) try testing.expect(items.len >= 2);
        },
        .type_record_ext => {
            const r = tree.fullTypeRecordExt(n);
            try testing.expect(r.base < token_count);
            try checkIndices(tree, r.fields);
        },
        .record_update => {
            const r = tree.fullRecordUpdate(n);
            try testing.expect(r.base < token_count);
            try checkIndices(tree, r.fields);
        },
        .type_paren, .record_type_field, .interp, .negate, .paren, .field, .field_access, .tuple_index, .question, .let_annotation, .pat_paren => try checkIndex(tree, tree.operand(n)),
        .type_fn, .pat_cons => {
            const data = tree.nodeData(n);
            try checkIndex(tree, @enumFromInt(data.lhs));
            try checkIndex(tree, @enumFromInt(data.rhs));
        },
        .multiline_string => {
            const m = tree.fullMultilineString(n);
            try testing.expect(m.first_line <= m.last_line and m.last_line < token_count);
        },
        .pat_record => try checkTokens(tree.fullPatRecord(n).fields, token_count),
        .pat_as => {
            const a = tree.fullPatAs(n);
            try checkIndex(tree, a.pattern);
            try testing.expect(a.name < token_count);
        },
        .lambda => {
            const l = tree.fullLambda(n);
            try checkIndices(tree, l.params);
            try checkIndex(tree, l.body);
        },
        .@"if" => {
            const i = tree.fullIf(n);
            try checkIndex(tree, i.cond);
            try checkIndex(tree, i.then_expr);
            try checkIndex(tree, i.else_expr);
        },
        .let => {
            const l = tree.fullLet(n);
            try testing.expect(l.bindings.len >= 1);
            try checkIndices(tree, l.bindings);
            try checkIndex(tree, l.body);
        },
        .let_def => {
            const l = tree.fullLetDef(n);
            try checkIndices(tree, l.params);
            try checkIndex(tree, l.body);
        },
        .let_pattern => {
            const l = tree.fullLetPattern(n);
            try checkIndex(tree, l.pattern);
            try checkIndex(tree, l.value);
        },
        .case => {
            const c = tree.fullCase(n);
            try checkIndex(tree, c.scrutinee);
            try testing.expect(c.branches.len >= 1);
            try checkIndices(tree, c.branches);
        },
        .branch => {
            const b = tree.fullBranch(n);
            try checkIndex(tree, b.pattern);
            try checkIndex(tree, b.body);
        },
        else => {
            try testing.expect(tag.isBinop());
            const b = tree.fullBinop(n);
            try checkIndex(tree, b.lhs);
            try checkIndex(tree, b.rhs);
        },
    }
}

// ---- Module, imports, declarations ---------------------------------------

test "empty file and a file of only imports or only a module doc" {
    try expectClean("", "(module)\n");
    try expectClean("import Dict\nimport Set\n",
        \\(module
        \\  (import Dict)
        \\  (import Set))
        \\
    );
    try expectClean("--! Only docs.\n--! Two lines.\n",
        \\(module
        \\  (module_doc "Only docs.")
        \\  (module_doc "Two lines."))
        \\
    );
}

test "import forms: bare, as, exposing, both, qualified paths" {
    try expectClean(
        \\import Dict
        \\import Html as H
        \\import Html.Attributes exposing (class, href)
        \\import Json.Decode as D exposing (Decoder, string, int)
        \\
    ,
        \\(module
        \\  (import Dict)
        \\  (import Html as H)
        \\  (import Html.Attributes exposing
        \\    (exposed class)
        \\    (exposed href))
        \\  (import Json.Decode as D exposing
        \\    (exposed Decoder)
        \\    (exposed string)
        \\    (exposed int)))
        \\
    );
}

test "every declaration kind with visibility, docs and type parameters" {
    try expectClean(
        \\--! doc
        \\--| Doc.
        \\pub type alias P a b = { a | x : Int, y : ( a, b ), z : (), w : {} }
        \\pub opaque type T a = | A | B (List a) { r : a }
        \\type U = C
        \\foreign f : Int -> Int
        \\pub foreign type L a
        \\f : (a -> b) -> List a -> List b
        \\f g xs = xs
        \\pub answer = 42
        \\
    ,
        \\(module
        \\  (module_doc "doc")
        \\  (type_alias pub P a b
        \\    (doc "Doc.")
        \\    (type_record_ext a
        \\      (record_type_field x
        \\        (type_con Int))
        \\      (record_type_field y
        \\        (type_tuple
        \\          (type_var a)
        \\          (type_var b)))
        \\      (record_type_field z
        \\        (type_unit))
        \\      (record_type_field w
        \\        (type_record))))
        \\  (type_decl pub opaque T a
        \\    (constructor A)
        \\    (constructor B
        \\      (type_paren
        \\        (type_con List
        \\          (type_var a)))
        \\      (type_record
        \\        (record_type_field r
        \\          (type_var a)))))
        \\  (type_decl U
        \\    (constructor C))
        \\  (foreign_value f
        \\    (type_fn
        \\      (type_con Int)
        \\      (type_con Int)))
        \\  (foreign_type pub L a)
        \\  (annotation f
        \\    (type_fn
        \\      (type_paren
        \\        (type_fn
        \\          (type_var a)
        \\          (type_var b)))
        \\      (type_fn
        \\        (type_con List
        \\          (type_var a))
        \\        (type_con List
        \\          (type_var b)))))
        \\  (definition f
        \\    (pat_var g)
        \\    (pat_var xs)
        \\    (ident xs))
        \\  (definition pub answer
        \\    (int 42)))
        \\
    );
}

test "types: arrows are right associative, applications take atoms, qualified heads" {
    try expectTree(
        \\a : Int -> Int -> Int
        \\b : Dict.Dict String (List ( Int, Maybe b )) -> List b
        \\c : { r | x : Int } -> Int
        \\
    ,
        \\(module
        \\  (annotation a
        \\    (type_fn
        \\      (type_con Int)
        \\      (type_fn
        \\        (type_con Int)
        \\        (type_con Int))))
        \\  (annotation b
        \\    (type_fn
        \\      (type_con Dict.Dict
        \\        (type_con String)
        \\        (type_paren
        \\          (type_con List
        \\            (type_tuple
        \\              (type_con Int)
        \\              (type_con Maybe
        \\                (type_var b))))))
        \\      (type_con List
        \\        (type_var b))))
        \\  (annotation c
        \\    (type_fn
        \\      (type_record_ext r
        \\        (record_type_field x
        \\          (type_con Int)))
        \\      (type_con Int))))
        \\
    , &.{ .{ .code = .annotation_without_definition, .line = 1, .col = 1 }, .{ .code = .annotation_without_definition, .line = 2, .col = 1 }, .{ .code = .annotation_without_definition, .line = 3, .col = 1 } });
}

// ---- Expressions -----------------------------------------------------------

test "every atom: literals, names, brackets, operator functions, strings, multiline" {
    try expectClean(
        \\v = ( (+), (::), (|>), (), (1), (1, 2), [], [1], {}, 'c', 1.5, 0x1F, "a${b}c", "", \a b -> a, if a then b else c )
        \\m =
        \\    \\a
        \\    \\b
        \\r = { a = 1, b = { r | c = 2 } }
        \\
    ,
        \\(module
        \\  (definition v
        \\    (tuple
        \\      (op_fn +)
        \\      (op_fn ::)
        \\      (op_fn |>)
        \\      (unit)
        \\      (paren
        \\        (int 1))
        \\      (tuple
        \\        (int 1)
        \\        (int 2))
        \\      (list)
        \\      (list
        \\        (int 1))
        \\      (record)
        \\      (char 'c')
        \\      (float 1.5)
        \\      (int 0x1F)
        \\      (string
        \\        (chunk "a")
        \\        (interp
        \\          (ident b))
        \\        (chunk "c"))
        \\      (string)
        \\      (lambda
        \\        (pat_var a)
        \\        (pat_var b)
        \\        (ident a))
        \\      (if
        \\        (ident a)
        \\        (ident b)
        \\        (ident c))))
        \\  (definition m
        \\    (multiline_string "a" "b"))
        \\  (definition r
        \\    (record
        \\      (field a
        \\        (int 1))
        \\      (field b
        \\        (record_update r
        \\          (field c
        \\            (int 2)))))))
        \\
    );
}

test "precedence and associativity: every case of §6.5" {
    try expectTree(
        \\a1 a b c = a - b - c
        \\a2 a b c = a :: b :: c
        \\a3 a b c = a ^ b ^ c
        \\a4 f g x = f <| g <| x
        \\a5 x f g = x |> f |> g
        \\a6 f g h = f << g << h
        \\a7 f g h = f >> g >> h
        \\a8 a b c = a == b == c
        \\a9 a b c = a <| b |> c
        \\b1 a b c = a + b * c
        \\b2 a b c = a || b && c
        \\b3 a b c d = a ++ b == c ++ d
        \\b4 f x y = x + y |> f
        \\b5 a b c = a * b ^ c
        \\b6 f x y = f x + f y
        \\
    ,
        \\(module
        \\  (definition a1
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pat_var c)
        \\    (sub
        \\      (sub
        \\        (ident a)
        \\        (ident b))
        \\      (ident c)))
        \\  (definition a2
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pat_var c)
        \\    (cons
        \\      (ident a)
        \\      (cons
        \\        (ident b)
        \\        (ident c))))
        \\  (definition a3
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pat_var c)
        \\    (pow
        \\      (ident a)
        \\      (pow
        \\        (ident b)
        \\        (ident c))))
        \\  (definition a4
        \\    (pat_var f)
        \\    (pat_var g)
        \\    (pat_var x)
        \\    (pipe_left
        \\      (ident f)
        \\      (pipe_left
        \\        (ident g)
        \\        (ident x))))
        \\  (definition a5
        \\    (pat_var x)
        \\    (pat_var f)
        \\    (pat_var g)
        \\    (pipe_right
        \\      (pipe_right
        \\        (ident x)
        \\        (ident f))
        \\      (ident g)))
        \\  (definition a6
        \\    (pat_var f)
        \\    (pat_var g)
        \\    (pat_var h)
        \\    (compose_left
        \\      (ident f)
        \\      (compose_left
        \\        (ident g)
        \\        (ident h))))
        \\  (definition a7
        \\    (pat_var f)
        \\    (pat_var g)
        \\    (pat_var h)
        \\    (compose_right
        \\      (compose_right
        \\        (ident f)
        \\        (ident g))
        \\      (ident h)))
        \\  (definition a8
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pat_var c)
        \\    (eq
        \\      (eq
        \\        (ident a)
        \\        (ident b))
        \\      (ident c)))
        \\  (definition a9
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pat_var c)
        \\    (pipe_left
        \\      (ident a)
        \\      (pipe_right
        \\        (ident b)
        \\        (ident c))))
        \\  (definition b1
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pat_var c)
        \\    (add
        \\      (ident a)
        \\      (mul
        \\        (ident b)
        \\        (ident c))))
        \\  (definition b2
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pat_var c)
        \\    (bool_or
        \\      (ident a)
        \\      (bool_and
        \\        (ident b)
        \\        (ident c))))
        \\  (definition b3
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pat_var c)
        \\    (pat_var d)
        \\    (eq
        \\      (append
        \\        (ident a)
        \\        (ident b))
        \\      (append
        \\        (ident c)
        \\        (ident d))))
        \\  (definition b4
        \\    (pat_var f)
        \\    (pat_var x)
        \\    (pat_var y)
        \\    (pipe_right
        \\      (add
        \\        (ident x)
        \\        (ident y))
        \\      (ident f)))
        \\  (definition b5
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pat_var c)
        \\    (mul
        \\      (ident a)
        \\      (pow
        \\        (ident b)
        \\        (ident c))))
        \\  (definition b6
        \\    (pat_var f)
        \\    (pat_var x)
        \\    (pat_var y)
        \\    (add
        \\      (apply
        \\        (ident f)
        \\        (ident x))
        \\      (apply
        \\        (ident f)
        \\        (ident y)))))
        \\
    , &.{ .{ .code = .non_associative_chain, .line = 8, .col = 19 }, .{ .code = .non_associative_chain, .line = 9, .col = 19 } });
    // The other order of mixed pipes, and composition mixed the same way.
    try expectTree("f g x y = g <| x |> y\nh f g = f << g >> f\n",
        \\(module
        \\  (definition f
        \\    (pat_var g)
        \\    (pat_var x)
        \\    (pat_var y)
        \\    (pipe_left
        \\      (ident g)
        \\      (pipe_right
        \\        (ident x)
        \\        (ident y))))
        \\  (definition h
        \\    (pat_var f)
        \\    (pat_var g)
        \\    (compose_left
        \\      (ident f)
        \\      (compose_right
        \\        (ident g)
        \\        (ident f)))))
        \\
    , &.{ .{ .code = .non_associative_chain, .line = 1, .col = 18 }, .{ .code = .non_associative_chain, .line = 2, .col = 16 } });
}

test "negation: every case of §6.5, and `- x` is an error" {
    try expectTree(
        \\n1 x = -x
        \\n2 a b = -(a + b)
        \\n3 = [ -1 ]
        \\n4 f = f (-1)
        \\n5 f = f -1
        \\n6 a b = a - -b
        \\n7 x = - x
        \\n8 r = -r.value
        \\
    ,
        \\(module
        \\  (definition n1
        \\    (pat_var x)
        \\    (negate
        \\      (ident x)))
        \\  (definition n2
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (negate
        \\      (paren
        \\        (add
        \\          (ident a)
        \\          (ident b)))))
        \\  (definition n3
        \\    (list
        \\      (negate
        \\        (int 1))))
        \\  (definition n4
        \\    (pat_var f)
        \\    (apply
        \\      (ident f)
        \\      (paren
        \\        (negate
        \\          (int 1)))))
        \\  (definition n5
        \\    (pat_var f)
        \\    (sub
        \\      (ident f)
        \\      (int 1)))
        \\  (definition n6
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (sub
        \\      (ident a)
        \\      (negate
        \\        (ident b))))
        \\  (definition n7
        \\    (pat_var x)
        \\    (negate
        \\      (ident x)))
        \\  (definition n8
        \\    (pat_var r)
        \\    (negate
        \\      (field_access .value
        \\        (ident r)))))
        \\
    , &.{.{ .code = .negation_with_space, .line = 7, .col = 8 }});
}

test "question mark: postfix on applications, in pipelines, with access, and args after it" {
    try expectTree(
        \\q1 s = parse s?
        \\q2 x f = x? |> f
        \\q3 f a b = f (a?) b
        \\q4 f a b = f a? b
        \\q5 x = x.field?
        \\q6 x = x?.field
        \\q7 r = r??
        \\
    ,
        \\(module
        \\  (definition q1
        \\    (pat_var s)
        \\    (question
        \\      (apply
        \\        (ident parse)
        \\        (ident s))))
        \\  (definition q2
        \\    (pat_var x)
        \\    (pat_var f)
        \\    (pipe_right
        \\      (question
        \\        (ident x))
        \\      (ident f)))
        \\  (definition q3
        \\    (pat_var f)
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (apply
        \\      (ident f)
        \\      (paren
        \\        (question
        \\          (ident a)))
        \\      (ident b)))
        \\  (definition q4
        \\    (pat_var f)
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (apply
        \\      (question
        \\        (apply
        \\          (ident f)
        \\          (ident a)))
        \\      (ident b)))
        \\  (definition q5
        \\    (pat_var x)
        \\    (question
        \\      (field_access .field
        \\        (ident x))))
        \\  (definition q6
        \\    (pat_var x)
        \\    (field_access .field
        \\      (question
        \\        (ident x))))
        \\  (definition q7
        \\    (pat_var r)
        \\    (question
        \\      (question
        \\        (ident r)))))
        \\
    , &.{.{ .code = .args_after_question, .line = 4, .col = 17 }});
}

test "field access chains, tuple indices and accessor functions, with and without whitespace" {
    try expectTree(
        \\a1 r = r.a.b
        \\a2 t = t.0.1
        \\a3 f = f .name
        \\a4 f = f.name
        \\a5 f x = (f x).y
        \\a6 = .a >> .b
        \\a7 t = t.00
        \\
    ,
        \\(module
        \\  (definition a1
        \\    (pat_var r)
        \\    (field_access .b
        \\      (field_access .a
        \\        (ident r))))
        \\  (definition a2
        \\    (pat_var t)
        \\    (tuple_index .1
        \\      (tuple_index .0
        \\        (ident t))))
        \\  (definition a3
        \\    (pat_var f)
        \\    (apply
        \\      (ident f)
        \\      (accessor .name)))
        \\  (definition a4
        \\    (pat_var f)
        \\    (field_access .name
        \\      (ident f)))
        \\  (definition a5
        \\    (pat_var f)
        \\    (pat_var x)
        \\    (field_access .y
        \\      (paren
        \\        (apply
        \\          (ident f)
        \\          (ident x)))))
        \\  (definition a6
        \\    (compose_right
        \\      (accessor .a)
        \\      (accessor .b)))
        \\  (definition a7
        \\    (pat_var t)
        \\    (tuple_index .00
        \\      (ident t))))
        \\
    , &.{.{ .code = .invalid_tuple_index, .line = 7, .col = 9 }});
}

test "block expressions as the last operand of a chain, and as a bare argument (error)" {
    try expectTree(
        \\b1 f = f <| \x -> x + 1
        \\b2 xs = xs |> List.map (\x -> x)
        \\b3 t a b c = text <| if a then b else c
        \\b4 x = x + let y = 1 in y
        \\b5 x = x + case x of
        \\  1 -> 2
        \\  _ -> 3
        \\b6 f = f \x -> x
        \\
    ,
        \\(module
        \\  (definition b1
        \\    (pat_var f)
        \\    (pipe_left
        \\      (ident f)
        \\      (lambda
        \\        (pat_var x)
        \\        (add
        \\          (ident x)
        \\          (int 1)))))
        \\  (definition b2
        \\    (pat_var xs)
        \\    (pipe_right
        \\      (ident xs)
        \\      (apply
        \\        (ident List.map)
        \\        (paren
        \\          (lambda
        \\            (pat_var x)
        \\            (ident x))))))
        \\  (definition b3
        \\    (pat_var t)
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pat_var c)
        \\    (pipe_left
        \\      (ident text)
        \\      (if
        \\        (ident a)
        \\        (ident b)
        \\        (ident c))))
        \\  (definition b4
        \\    (pat_var x)
        \\    (add
        \\      (ident x)
        \\      (let
        \\        (let_def y
        \\          (int 1))
        \\        (ident y))))
        \\  (definition b5
        \\    (pat_var x)
        \\    (add
        \\      (ident x)
        \\      (case
        \\        (ident x)
        \\        (branch
        \\          (pat_int 1)
        \\          (int 2))
        \\        (branch
        \\          (pat_wild)
        \\          (int 3)))))
        \\  (definition b6
        \\    (pat_var f)
        \\    (apply
        \\      (ident f)
        \\      (lambda
        \\        (pat_var x)
        \\        (ident x)))))
        \\
    , &.{.{ .code = .unexpected_token, .line = 8, .col = 10 }});
}

test "strings: chunks and interpolations in every arrangement" {
    try expectClean(
        \\a n = "${a} and ${b}!"
        \\b = "${ { r | a = 2 }.a } done"
        \\c = "\t${n}\n"
        \\
    ,
        \\(module
        \\  (definition a
        \\    (pat_var n)
        \\    (string
        \\      (interp
        \\        (ident a))
        \\      (chunk " and ")
        \\      (interp
        \\        (ident b))
        \\      (chunk "!")))
        \\  (definition b
        \\    (string
        \\      (interp
        \\        (field_access .a
        \\          (record_update r
        \\            (field a
        \\              (int 2)))))
        \\      (chunk " done")))
        \\  (definition c
        \\    (string
        \\      (chunk "\t")
        \\      (interp
        \\        (ident n))
        \\      (chunk "\n"))))
        \\
    );
}

// ---- Layout ----------------------------------------------------------------

test "layout: the worked example of §4, verbatim" {
    try expectClean(
        \\view model =
        \\    case model.page of
        \\        Home ->
        \\            let
        \\                title = "Hi"
        \\                body =
        \\                    text title
        \\            in
        \\            div [] [ body ]
        \\
        \\        About ->
        \\            text "about"
        \\
    ,
        \\(module
        \\  (definition view
        \\    (pat_var model)
        \\    (case
        \\      (field_access .page
        \\        (ident model))
        \\      (branch
        \\        (pat_ctor Home)
        \\        (let
        \\          (let_def title
        \\            (string
        \\              (chunk "Hi")))
        \\          (let_def body
        \\            (apply
        \\              (ident text)
        \\              (ident title)))
        \\          (apply
        \\            (ident div)
        \\            (list)
        \\            (list
        \\              (ident body)))))
        \\      (branch
        \\        (pat_ctor About)
        \\        (apply
        \\          (ident text)
        \\          (string
        \\            (chunk "about")))))))
        \\
    );
}

test "layout: a branch list ends at a token its body cannot consume, and nested cases" {
    try expectClean(
        \\f x = (case x of A -> y)
        \\g x = [ case x of A -> y, 2 ]
        \\h a b =
        \\    case a of
        \\        Just x ->
        \\            case b of
        \\                Just y -> x
        \\                Nothing -> x
        \\        Nothing -> 0
        \\
    ,
        \\(module
        \\  (definition f
        \\    (pat_var x)
        \\    (paren
        \\      (case
        \\        (ident x)
        \\        (branch
        \\          (pat_ctor A)
        \\          (ident y)))))
        \\  (definition g
        \\    (pat_var x)
        \\    (list
        \\      (case
        \\        (ident x)
        \\        (branch
        \\          (pat_ctor A)
        \\          (ident y)))
        \\      (int 2)))
        \\  (definition h
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (case
        \\      (ident a)
        \\      (branch
        \\        (pat_ctor Just
        \\          (pat_var x))
        \\        (case
        \\          (ident b)
        \\          (branch
        \\            (pat_ctor Just
        \\              (pat_var y))
        \\            (ident x))
        \\          (branch
        \\            (pat_ctor Nothing)
        \\            (ident x))))
        \\      (branch
        \\        (pat_ctor Nothing)
        \\        (int 0)))))
        \\
    );
}

test "layout: `in` at various columns, bindings on the head line, nested lets" {
    try expectClean(
        \\a =
        \\    let
        \\        x =
        \\            1
        \\    in
        \\    x
        \\b =
        \\    let x = 1
        \\        y = 2 in x + y
        \\c = let
        \\      x = 1
        \\    in
        \\      x
        \\d =
        \\  let
        \\    x = 1
        \\            in x
        \\e =
        \\    let
        \\        outer =
        \\            let
        \\                inner =
        \\                    3
        \\            in
        \\            inner
        \\    in
        \\    outer
        \\
    ,
        \\(module
        \\  (definition a
        \\    (let
        \\      (let_def x
        \\        (int 1))
        \\      (ident x)))
        \\  (definition b
        \\    (let
        \\      (let_def x
        \\        (int 1))
        \\      (let_def y
        \\        (int 2))
        \\      (add
        \\        (ident x)
        \\        (ident y))))
        \\  (definition c
        \\    (let
        \\      (let_def x
        \\        (int 1))
        \\      (ident x)))
        \\  (definition d
        \\    (let
        \\      (let_def x
        \\        (int 1))
        \\      (ident x)))
        \\  (definition e
        \\    (let
        \\      (let_def outer
        \\        (let
        \\          (let_def inner
        \\            (int 3))
        \\          (ident inner)))
        \\      (ident outer))))
        \\
    );
}

test "layout: brackets do not suspend it, operators and keywords may lead a line" {
    try expectClean(
        \\list =
        \\ [ 1
        \\ , 2
        \\ ]
        \\call =
        \\        List.map
        \\  (\x -> x)
        \\     [ 1 ]
        \\branch m =
        \\    case
        \\        m
        \\    of
        \\        Just x
        \\            ->
        \\                x
        \\        Nothing
        \\            -> 0
        \\pick flag a b =
        \\    if flag
        \\    then a
        \\    else b
        \\
    ,
        \\(module
        \\  (definition list
        \\    (list
        \\      (int 1)
        \\      (int 2)))
        \\  (definition call
        \\    (apply
        \\      (ident List.map)
        \\      (paren
        \\        (lambda
        \\          (pat_var x)
        \\          (ident x)))
        \\      (list
        \\        (int 1))))
        \\  (definition branch
        \\    (pat_var m)
        \\    (case
        \\      (ident m)
        \\      (branch
        \\        (pat_ctor Just
        \\          (pat_var x))
        \\        (ident x))
        \\      (branch
        \\        (pat_ctor Nothing)
        \\        (int 0))))
        \\  (definition pick
        \\    (pat_var flag)
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (if
        \\      (ident flag)
        \\      (ident a)
        \\      (ident b))))
        \\
    );
}

test "layout errors: a continuation on column 1, misaligned let bindings and case branches" {
    try expectTree("x =\n    1\n+ 1\n",
        \\(module
        \\  (definition x
        \\    (int 1)))
        \\
    , &.{.{ .code = .expected_declaration, .line = 3, .col = 1 }});
    try expectTree("x =\n    let\n        a = 1\n      b = 2\n    in\n    a + b\n",
        \\(module
        \\  (definition x
        \\    (let
        \\      (let_def a
        \\        (int 1))
        \\      (let_def b
        \\        (int 2))
        \\      (add
        \\        (ident a)
        \\        (ident b)))))
        \\
    , &.{.{ .code = .unexpected_token, .line = 4, .col = 7 }});
    try expectErrorMessage("x =\n    let\n        a = 1\n      b = 2\n    in\n    a + b\n", 0,
        \\I was parsing the bindings of this `let` and ran into `b` on column 7.
        \\
        \\Every binding must start on the same column as the first one, `a` on column 9,
        \\and `in` ends the list.
    );
    try expectTree("x =\n    case y of\n        A -> 1\n      B -> 2\n",
        \\(module
        \\  (definition x
        \\    (case
        \\      (ident y)
        \\      (branch
        \\        (pat_ctor A)
        \\        (int 1))
        \\      (branch
        \\        (pat_ctor B)
        \\        (int 2)))))
        \\
    , &.{.{ .code = .unexpected_token, .line = 4, .col = 7 }});
    // A `case` whose branches would all be left of its block: no branches.
    try expectTree("x =\n    case y of\n\nz = 1\n",
        \\(module
        \\  (definition x
        \\    (case
        \\      (ident y)
        \\      (error case_without_branches)))
        \\  (definition z
        \\    (int 1)))
        \\
    , &.{.{ .code = .case_without_branches, .line = 2, .col = 5 }});
    try expectErrorMessage("x =\n    case y of\n\nz = 1\n", 0,
        \\I was parsing the branches of this `case` and ran into `z`, which is indented to
        \\column 1. Branches must be indented more than the block the `case` is in, whose
        \\column is 1.
        \\
        \\A `case` needs at least one branch:
        \\
        \\    case x of
        \\        Just n ->
        \\            n
    );
}

// ---- Patterns --------------------------------------------------------------

test "every pattern form, `as` binding loosest, cons right associative" {
    try expectClean(
        \\p1 x = case x of
        \\  _ -> 0
        \\  y -> 0
        \\  Just z -> 0
        \\  Maybe.Just z -> 0
        \\  Nothing -> 0
        \\  1 -> 0
        \\  -1 -> 0
        \\  'c' -> 0
        \\  "s" -> 0
        \\  () -> 0
        \\  (a) -> 0
        \\  (a, b) -> 0
        \\  [] -> 0
        \\  [a, b] -> 0
        \\  { a, b } -> 0
        \\  a :: b :: c -> 0
        \\  Just x as m -> 0
        \\  x :: xs as all -> 0
        \\  Node (Leaf) _ (Leaf) -> 0
        \\
    ,
        \\(module
        \\  (definition p1
        \\    (pat_var x)
        \\    (case
        \\      (ident x)
        \\      (branch
        \\        (pat_wild)
        \\        (int 0))
        \\      (branch
        \\        (pat_var y)
        \\        (int 0))
        \\      (branch
        \\        (pat_ctor Just
        \\          (pat_var z))
        \\        (int 0))
        \\      (branch
        \\        (pat_ctor Maybe.Just
        \\          (pat_var z))
        \\        (int 0))
        \\      (branch
        \\        (pat_ctor Nothing)
        \\        (int 0))
        \\      (branch
        \\        (pat_int 1)
        \\        (int 0))
        \\      (branch
        \\        (pat_neg_int -1)
        \\        (int 0))
        \\      (branch
        \\        (pat_char 'c')
        \\        (int 0))
        \\      (branch
        \\        (pat_string "s")
        \\        (int 0))
        \\      (branch
        \\        (pat_unit)
        \\        (int 0))
        \\      (branch
        \\        (pat_paren
        \\          (pat_var a))
        \\        (int 0))
        \\      (branch
        \\        (pat_tuple
        \\          (pat_var a)
        \\          (pat_var b))
        \\        (int 0))
        \\      (branch
        \\        (pat_list)
        \\        (int 0))
        \\      (branch
        \\        (pat_list
        \\          (pat_var a)
        \\          (pat_var b))
        \\        (int 0))
        \\      (branch
        \\        (pat_record a b)
        \\        (int 0))
        \\      (branch
        \\        (pat_cons
        \\          (pat_var a)
        \\          (pat_cons
        \\            (pat_var b)
        \\            (pat_var c)))
        \\        (int 0))
        \\      (branch
        \\        (pat_as m
        \\          (pat_ctor Just
        \\            (pat_var x)))
        \\        (int 0))
        \\      (branch
        \\        (pat_as all
        \\          (pat_cons
        \\            (pat_var x)
        \\            (pat_var xs)))
        \\        (int 0))
        \\      (branch
        \\        (pat_ctor Node
        \\          (pat_paren
        \\            (pat_ctor Leaf))
        \\          (pat_wild)
        \\          (pat_paren
        \\            (pat_ctor Leaf)))
        \\        (int 0)))))
        \\
    );
}

test "let bindings: definitions, annotations, irrefutable patterns, and refutable ones (error)" {
    try expectTree(
        \\x =
        \\    let
        \\        f a = a
        \\        t : Int
        \\        ( n, ( s, flag ) ) = input
        \\        { name, age } = person
        \\        (( a, b ) as pair) = t
        \\        _ = flag
        \\        Just y = m
        \\        1 = n
        \\        (h :: r) = l
        \\    in
        \\    y
        \\
    ,
        \\(module
        \\  (definition x
        \\    (let
        \\      (let_def f
        \\        (pat_var a)
        \\        (ident a))
        \\      (let_annotation t
        \\        (type_con Int))
        \\      (let_pattern
        \\        (pat_tuple
        \\          (pat_var n)
        \\          (pat_tuple
        \\            (pat_var s)
        \\            (pat_var flag)))
        \\        (ident input))
        \\      (let_pattern
        \\        (pat_record name age)
        \\        (ident person))
        \\      (let_pattern
        \\        (pat_paren
        \\          (pat_as pair
        \\            (pat_tuple
        \\              (pat_var a)
        \\              (pat_var b))))
        \\        (ident t))
        \\      (let_pattern
        \\        (pat_wild)
        \\        (ident flag))
        \\      (let_pattern
        \\        (pat_ctor Just
        \\          (pat_var y))
        \\        (ident m))
        \\      (let_pattern
        \\        (pat_int 1)
        \\        (ident n))
        \\      (let_pattern
        \\        (pat_paren
        \\          (pat_cons
        \\            (pat_var h)
        \\            (pat_var r)))
        \\        (ident l))
        \\      (ident y))))
        \\
    , &.{ .{ .code = .refutable_let_pattern, .line = 9, .col = 9 }, .{ .code = .refutable_let_pattern, .line = 10, .col = 9 }, .{ .code = .refutable_let_pattern, .line = 11, .col = 12 } });
}

// ---- Doc comments ----------------------------------------------------------

test "doc comments: attached, before an import, split by a comment, at EOF, blank line inside a block" {
    try expectTree(
        \\--| doc x
        \\x = 1
        \\--| unattached before import
        \\import Dict
        \\--| split
        \\-- plain
        \\y = 2
        \\--| a
        \\
        \\--| b
        \\pub type T = A
        \\--| at eof
        \\
    ,
        \\(module
        \\  (definition x
        \\    (doc "doc x")
        \\    (int 1))
        \\  (import Dict)
        \\  (definition y
        \\    (int 2))
        \\  (type_decl pub T
        \\    (doc "a")
        \\    (doc "b")
        \\    (constructor A)))
        \\
    , &.{
        .{ .code = .doc_comment_unattached, .line = 3, .col = 1 },
        .{ .code = .import_after_declaration, .line = 4, .col = 1 },
        .{ .code = .doc_comment_unattached, .line = 5, .col = 1 },
        .{ .code = .doc_comment_unattached, .line = 12, .col = 1 },
    });
    // A doc comment inside a `let` documents nothing.
    try expectTree("x =\n    let\n        --| no\n        y = 1\n    in\n    y\n",
        \\(module
        \\  (definition x
        \\    (let
        \\      (let_def y
        \\        (int 1))
        \\      (ident y))))
        \\
    , &.{.{ .code = .doc_comment_unattached, .line = 3, .col = 9 }});
}

test "module docs: merged across blanks and plain comments, misplaced after an import or a declaration" {
    try expectTree(
        \\--! mod
        \\-- plain
        \\
        \\--! mod2
        \\import Dict
        \\--! late
        \\x = 1
        \\--! late2
        \\--! late3
        \\
    ,
        \\(module
        \\  (module_doc "mod")
        \\  (module_doc "mod2")
        \\  (import Dict)
        \\  (definition x
        \\    (int 1)))
        \\
    , &.{ .{ .code = .module_doc_not_at_top, .line = 6, .col = 1 }, .{ .code = .module_doc_not_at_top, .line = 8, .col = 1 } });
}

// ---- Errors and recovery -------------------------------------------------

test "recovery: a broken declaration followed by a valid one yields one error and both declarations" {
    try expectTree("x = 1 )\ny = 2\n",
        \\(module
        \\  (definition x
        \\    (int 1))
        \\  (definition y
        \\    (int 2)))
        \\
    , &.{.{ .code = .unexpected_token, .line = 1, .col = 7 }});
    try expectErrorMessage("x = 1 )\ny = 2\n", 0,
        \\I was parsing the declaration of `x` and ran into `)`, which cannot continue it.
        \\
        \\Either it is part of the expression before it (then check what comes just
        \\before it), or it should start a new declaration on column 1.
    );
    try expectTree("type Foo = bar\nx = 1\n",
        \\(module
        \\  (type_decl Foo
        \\    (error unexpected_token))
        \\  (definition x
        \\    (int 1)))
        \\
    , &.{.{ .code = .unexpected_token, .line = 1, .col = 12 }});
    try expectTree("1 + 2\nx = 1\n)\ny = 2\n",
        \\(module
        \\  (definition x
        \\    (int 1))
        \\  (definition y
        \\    (int 2)))
        \\
    , &.{ .{ .code = .expected_declaration, .line = 1, .col = 1 }, .{ .code = .expected_declaration, .line = 3, .col = 1 } });
}

test "recovery: unclosed brackets are reported at the opener and the tree is complete" {
    try expectTree("x = (1 + 2\n\ng = 3\n",
        \\(module
        \\  (definition x
        \\    (paren
        \\      (add
        \\        (int 1)
        \\        (int 2))))
        \\  (definition g
        \\    (int 3)))
        \\
    , &.{.{ .code = .unclosed_delimiter, .line = 1, .col = 5 }});
    try expectTree("x = (1 + 2",
        \\(module
        \\  (definition x
        \\    (paren
        \\      (add
        \\        (int 1)
        \\        (int 2)))))
        \\
    , &.{.{ .code = .unclosed_delimiter, .line = 1, .col = 5 }});
    try expectErrorMessage("x = (1 + 2", 0,
        \\I was parsing a parenthesised expression and got to the end of the file without finding the `)` that
        \\closes this `(`.
    );
    try expectTree("x = { a = 1",
        \\(module
        \\  (definition x
        \\    (record
        \\      (field a
        \\        (int 1)))))
        \\
    , &.{.{ .code = .unclosed_delimiter, .line = 1, .col = 5 }});
}

test "recovery: garbage inside a list, a missing `then`, a missing `=`, a stray closer" {
    try expectTree("x = [ 1, , 2 ]\n",
        \\(module
        \\  (definition x
        \\    (list
        \\      (int 1)
        \\      (error unexpected_token)
        \\      (int 2))))
        \\
    , &.{.{ .code = .unexpected_token, .line = 1, .col = 10 }});
    try expectTree("x = [ 1 = 2 ) 3 ]\ny = 4\n",
        \\(module
        \\  (definition x
        \\    (list
        \\      (int 1)))
        \\  (definition y
        \\    (int 4)))
        \\
    , &.{.{ .code = .expected_token, .line = 1, .col = 9 }});
    try expectTree("f x =\n    if x 1 else 2\ny = 1\n",
        \\(module
        \\  (definition f
        \\    (pat_var x)
        \\    (if
        \\      (apply
        \\        (ident x)
        \\        (int 1))
        \\      (error unexpected_token)
        \\      (int 2)))
        \\  (definition y
        \\    (int 1)))
        \\
    , &.{.{ .code = .expected_token, .line = 2, .col = 12 }});
    try expectErrorMessage("f x =\n    if x 1 else 2\ny = 1\n", 0, "I was parsing this `if` and ran into `else`, but I was expecting `then` here.");
    try expectTree("type alias P Int\nx = 1\n",
        \\(module
        \\  (type_alias P
        \\    (type_con Int))
        \\  (definition x
        \\    (int 1)))
        \\
    , &.{.{ .code = .expected_token, .line = 1, .col = 14 }});
}

test "recovery: broken imports, records, interpolations and lambdas keep their shape" {
    try expectTree("import\nimport 1\nimport A as b\nimport A exposing (x, 1, Y)\n",
        \\(module
        \\  (import)
        \\  (import)
        \\  (import A)
        \\  (import A exposing
        \\    (exposed x)
        \\    (error unexpected_token)))
        \\
    , &.{
        .{ .code = .unexpected_token, .line = 2, .col = 1 },
        .{ .code = .unexpected_token, .line = 2, .col = 8 },
        .{ .code = .expected_token, .line = 3, .col = 13 },
        .{ .code = .unexpected_token, .line = 4, .col = 23 },
    });
    try expectTree("f = { r | }\ng = { = 1 }\n",
        \\(module
        \\  (definition f
        \\    (record_update r
        \\      (error unexpected_token)))
        \\  (definition g
        \\    (record
        \\      (error unexpected_token))))
        \\
    , &.{ .{ .code = .unexpected_token, .line = 1, .col = 11 }, .{ .code = .unexpected_token, .line = 2, .col = 7 } });
    try expectTree("f = \"a ${ } b ${ 1, 2 } c\"\n",
        \\(module
        \\  (definition f
        \\    (string
        \\      (chunk "a ")
        \\      (interp
        \\        (error unexpected_token))
        \\      (chunk " b ")
        \\      (interp
        \\        (int 1))
        \\      (chunk " c"))))
        \\
    , &.{ .{ .code = .unexpected_token, .line = 1, .col = 11 }, .{ .code = .expected_token, .line = 1, .col = 19 } });
    try expectTree("f = \\ -> 1\ng = \\x y",
        \\(module
        \\  (definition f
        \\    (lambda
        \\      (int 1)))
        \\  (definition g
        \\    (lambda
        \\      (pat_var x)
        \\      (pat_var y)
        \\      (error unexpected_token))))
        \\
    , &.{ .{ .code = .unexpected_token, .line = 1, .col = 7 }, .{ .code = .expected_token, .line = 2, .col = 9 } });
}

test "the soft declaration errors: annotation without definition, pub on definition, opaque misuse, import order" {
    try expectTree("f : Int\ng = 1\nh : Int\n",
        \\(module
        \\  (annotation f
        \\    (type_con Int))
        \\  (definition g
        \\    (int 1))
        \\  (annotation h
        \\    (type_con Int)))
        \\
    , &.{ .{ .code = .annotation_without_definition, .line = 1, .col = 1 }, .{ .code = .annotation_without_definition, .line = 3, .col = 1 } });
    try expectTree("f : Int\npub f = 1\npub g : Int\npub g = 2\n",
        \\(module
        \\  (annotation f
        \\    (type_con Int))
        \\  (definition pub f
        \\    (int 1))
        \\  (annotation pub g
        \\    (type_con Int))
        \\  (definition pub g
        \\    (int 2)))
        \\
    , &.{ .{ .code = .pub_on_definition, .line = 2, .col = 1 }, .{ .code = .pub_on_definition, .line = 4, .col = 1 } });
    try expectTree("pub opaque type alias Id = Int\npub opaque a = 1\npub opaque foreign b : Int\n",
        \\(module
        \\  (type_alias pub opaque Id
        \\    (type_con Int))
        \\  (definition pub opaque a
        \\    (int 1))
        \\  (foreign_value pub opaque b
        \\    (type_con Int)))
        \\
    , &.{ .{ .code = .opaque_not_on_type, .line = 1, .col = 5 }, .{ .code = .opaque_not_on_type, .line = 2, .col = 5 }, .{ .code = .unexpected_token, .line = 3, .col = 12 } });
    try expectTree("import Dict\nx = 1\nimport Set\n",
        \\(module
        \\  (import Dict)
        \\  (definition x
        \\    (int 1))
        \\  (import Set))
        \\
    , &.{.{ .code = .import_after_declaration, .line = 3, .col = 1 }});
}

test "lexer errors produce placeholders with the lexical code and no second diagnostic" {
    try expectTree("x = 12abc\ny = 'ab'\nz = \"open\nw = \"a\\qb\"\n",
        \\(module
        \\  (definition x
        \\    (error invalid_number))
        \\  (definition y
        \\    (error invalid_char_literal))
        \\  (definition z
        \\    (string
        \\      (chunk "open")))
        \\  (definition w
        \\    (string
        \\      (chunk "a")
        \\      (chunk "b"))))
        \\
    , &.{});
}

test "nesting deeper than the limit is cut off with a diagnostic, not a stack overflow" {
    const depth = max_depth + 100;
    const source = try testing.allocator.allocSentinel(u8, 4 + depth * 2 + 1, 0);
    defer testing.allocator.free(source);
    @memcpy(source[0..4], "x = ");
    @memset(source[4 .. 4 + depth], '(');
    source[4 + depth] = '1';
    @memset(source[5 + depth ..], ')');
    var interner: InternPool.Local = .empty;
    defer interner.deinit(testing.allocator);
    var r = try parseSource(&interner, source);
    defer r.deinit();
    try checkWellFormed(&r.tree, r.out.tokens.len, r.out.comments.items.len);
    try testing.expectEqual(@as(usize, 1), r.tree.errors.len);
    try testing.expectEqual(diagnostic.Code.nesting_too_deep, r.tree.errors[0].code);

    // The body expression is level one, so `max_depth - 1` nested parentheses
    // is the most that parses clean (and proves the stack budget in Debug).
    const clean = max_depth - 1;
    const ok = try testing.allocator.allocSentinel(u8, 4 + clean * 2 + 1, 0);
    defer testing.allocator.free(ok);
    @memcpy(ok[0..4], "x = ");
    @memset(ok[4 .. 4 + clean], '(');
    ok[4 + clean] = '1';
    @memset(ok[5 + clean ..], ')');
    var r2 = try parseSource(&interner, ok);
    defer r2.deinit();
    try testing.expectEqual(@as(usize, 0), r2.tree.errors.len);
}

// ---- Fuzz and stress ---------------------------------------------------------

/// The contract for arbitrary bytes: lex, parse, no panic, a well-formed
/// tree, every error inside the source.
fn checkArbitrary(source: [:0]const u8) !void {
    var interner: InternPool.Local = .empty;
    defer interner.deinit(testing.allocator);
    var r = try parseSource(&interner, source);
    defer r.deinit();
    try checkWellFormed(&r.tree, r.out.tokens.len, r.out.comments.items.len);
    for (r.tree.errors) |e| try testing.expect(e.end <= source.len);
}

test "fuzz: arbitrary bytes never panic and always yield a well-formed tree" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.sliceWithHash(buf[0 .. buf.len - 1], 0x9A25E);
            buf[len] = 0;
            try checkArbitrary(buf[0..len :0]);
        }
    }.testOne, .{ .corpus = &.{
        "x = (1 + 2\n\ng = 3\n",
        "f x =\n    case x of\n    Just n -> n\n",
        "x = [ 1, , 2 ]\n",
        "--| a\n--! b\nimport\n",
        "x = \"a ${ b\n",
        "type T = | | A\n",
        "let in in let\n",
        "x = \\ -> \\x\n",
    } });
}

/// Token-shaped pieces (each a well-formed token, space or newline) and
/// real grammar fragments; mixing them produces every kind of half-valid
/// program the parser must survive.
const soup_pieces = [_][]const u8{
    "x",       "foo",     "Bar",    "Json.Decode.string", "Maybe.Just", ".field",     ".0",
    "42",      "1.5",     "\"s\"",  "\"a ${x} b\"",       "'c'",        "\\\\raw",    "if",
    "then",    "else",    "case",   "of",                 "let",        "in",         "type",
    "alias",   "pub",     "opaque", "import",             "as",         "exposing",   "foreign",
    "(",       ")",       "[",      "]",                  "{",          "}",          ",",
    ":",       "=",       "->",     "\\",                 "|",          "_",          "?",
    "+",       "-",       "*",      "/",                  "//",         "^",          "++",
    "::",      "==",      "/=",     "<",                  ">",          "<=",         ">=",
    "&&",      "||",      "|>",     "<|",                 "<<",         ">>",         " ",
    " ",       " ",       "\n",     "\n",                 "\n    ",     "\n        ", "-- c\n",
    "--| d\n", "--! m\n", "@",      "\t",                 "12abc",
};

const fragment_pieces = [_][]const u8{
    "x = 1\n",
    "f a b = a + b\n",
    "import Json.Decode as D exposing (Decoder, string)\n",
    "type T a = A | B a (List a)\n",
    "type alias P = { x : Int, y : Int }\n",
    "g : Int -> Int\n",
    "pub opaque type Q = Q Int\n",
    "foreign h : Int\n",
    "--| doc\n",
    "v =\n    case m of\n        Just n ->\n            n\n\n        Nothing ->\n            0\n",
    "w =\n    let\n        a = 1\n        b = 2\n    in\n    a + b\n",
    "u x = if x then 1 else 2\n",
    "l = [ 1, 2, 3 ]\n",
    "r = { a = 1, b = \"${x}\" }\n",
    "s = \\a b -> a\n",
    "t = f <| g <| x |> h\n",
    "q s = parse s? |> f\n",
    "m =\n    \\\\a\n    \\\\b\n",
    "p (Just x) { a } ( b, c ) = -x\n",
};

// PRNG-driven stand-in for the fuzzer (the toolchain's fuzz mode does not
// build on 0.16.0): token soup and grammar fragments, mixed at random.
// `BENI_STRESS_ITERATIONS` raises the count for a long run.
test "stress: token soup and grammar fragments never panic and always yield a well-formed tree" {
    var iterations: usize = 2000;
    if (testing.environ.getAlloc(testing.allocator, "BENI_STRESS_ITERATIONS")) |value| {
        defer testing.allocator.free(value);
        iterations = std.fmt.parseInt(usize, value, 10) catch iterations;
    } else |_| {}

    var prng: std.Random.DefaultPrng = .init(0xBE11);
    const random = prng.random();
    var buf: [2049]u8 = undefined;
    for (0..iterations) |_| {
        const len = random.intRangeAtMost(usize, 0, buf.len - 1);
        var i: usize = 0;
        while (i < len) {
            const piece = switch (random.uintLessThan(u8, 5)) {
                0, 1 => fragment_pieces[random.uintLessThan(usize, fragment_pieces.len)],
                2, 3 => soup_pieces[random.uintLessThan(usize, soup_pieces.len)],
                else => {
                    buf[i] = random.int(u8);
                    i += 1;
                    continue;
                },
            };
            const n = @min(piece.len, len - i);
            @memcpy(buf[i..][0..n], piece[0..n]);
            i += n;
        }
        buf[len] = 0;
        try checkArbitrary(buf[0..len :0]);
    }
}
