//! The parser (docs/design/language.md §3–§4, §6.5–§6.6, §10; frontend.md
//! §3.5, §8). Tokens in, an `Ast` out; never fails on user input.
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
//! `assertProgress` calls check that in a safety build — and every function returns
//! at `eof`, so the parse terminates on any token sequence; the fuzz and
//! stress tests at the bottom are the evidence.
//!
//! Memory: nodes, extra and errors go to `gpa` (session-owned, see
//! `Artifacts.zig`), pre-sized from the token count so a typical file never
//! grows them; the scratch stacks come from the worker's arena.

const std = @import("std");
const lists = @import("../lists.zig");
const soa = @import("../soa.zig");
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
/// Expression nesting, for the depth guard. Two kinds of charge share it.
/// `enter`/`leave` bracket a RECURSIVE descent and release on the way out,
/// so they measure the current path. `enterSpine` charges a node that a
/// LOOP is about to hang the node it built last iteration under, and does
/// NOT release: `parseBinop`'s operator loop, `parseAccessChain` and
/// `parsePostfix`'s `?` loop each build a left-deep chain one node per
/// iteration without recursing, so the parser frames they save are frames
/// every CONSUMER — `Lower.lowerExpr`, `dump/ast.zig` — still has to spend
/// walking the result. (`Format.zig` flattens them on purpose and says so.)
///
/// Releasing a spine charge when its loop ends is not enough: the subtree
/// it built is still an ancestor of whatever comes next, so
/// `((a.b….c…).d…)` would stack any number of maximum-length spines under
/// one another with the counter back at zero between them. Holding the
/// charge until the declaration ends (`resetDepth`) makes `max_depth`
/// bound the depth of the whole declaration, which is the bound every
/// consumer's recursion needs. The cost is that chain links ADD UP along
/// a declaration even when no one path is that long — except across
/// SIBLINGS (`Siblings`): a `let`'s bindings and body and a `case`'s
/// scrutinee and branches are charged as the deepest of them, not their
/// sum, because none of them is below another. What still adds
/// up — say 4096 operators spread over the arguments of one call — is
/// nothing a person writes, and what does is a generated file that would
/// otherwise crash us.
depth: u32 = 0,
/// Next unprocessed comment, for doc attachment.
comment_i: u32 = 0,
/// Next lexical diagnostic to match against an `invalid` token.
lex_i: usize = 0,

nodes: Ast.NodeList = .empty,
/// Appends to `nodes` without recomputing its columns per node.
node_appender: soa.Appender(Node) = .{},
extra: std.ArrayList(u32) = .empty,
errors: std.ArrayList(Diagnostics.Item) = .empty,
module_doc: Ast.CommentRange = .empty,
/// Scratch: node/token indices being collected into a range.
scratch: std.ArrayList(u32) = .empty,
/// Scratch: the closers of every open bracket, innermost last.
brackets: std.ArrayList(Tag) = .empty,
/// Scratch: the name symbol of every element whose children are being
/// parsed, innermost last (`fragment_symbol` for a fragment), so a closing
/// tag can tell a mismatch from an outer element's closer (frontend.md §9.5).
markup_open: std.ArrayList(u32) = .empty,
/// How many elements were closed at an outer element's closing tag: the
/// lexer, which does not match names, still counts each as open, and lexes
/// what follows the outermost element as its children (`skipDrift`).
markup_drift: u32 = 0,
/// True while the `Type` of a TOP-LEVEL annotation or `foreign` value is
/// being parsed: the only two positions a `where` clause may follow
/// (static-dispatch-spike.md §2.1). It is what makes `where` a CONTEXTUAL
/// word (§2.2) — everywhere else, a `lower_ident` spelled `where` is an
/// ordinary name. A `let` annotation leaves it false, so a `where` after
/// one is an ordinary token the enclosing block reports (Appendix A.1).
in_top_annotation: bool = false,
/// True while parsing a layout field's type or schema operand. In that one
/// context a later-line `lower_ident ':'` is a field head, never another
/// type/schema application argument (language.md §3–§4).
in_layout_field: bool = false,
/// True while a `where` constraint's type is being parsed: the comma rule
/// of §2.3 takes one more token of lookahead there.
in_where: bool = false,

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
    defer p.markup_open.deinit(scratch);
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

inline fn col(p: *const Parse, i: TokenIndex) u32 {
    return p.starts[i] - p.line_starts[p.lines[i]] + 1;
}

inline fn inBlock(p: *const Parse, i: TokenIndex) bool {
    return i == p.head or p.col(i) > p.indent;
}

/// The next token's tag if it belongs to the current block, else `eof`.
/// The lexer's zero-length marker for a string cut off by its line end
/// (language.md §2.6) also reads as `eof`: nothing can follow it on the
/// line, and only the string parser needs to see it (`atCutMarker`).
inline fn peek(p: *const Parse) Tag {
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
inline fn rawTag(p: *const Parse) Tag {
    return p.tags[p.tok_i];
}

/// Consume the next token. Never consumes `eof`.
inline fn next(p: *Parse) TokenIndex {
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

fn atLayoutFieldHeadAfter(p: *const Parse, after: TokenIndex) bool {
    return p.atLayoutFieldHeadAfterColumn(after, p.indent);
}

fn atLayoutFieldHeadAfterColumn(p: *const Parse, after: TokenIndex, min_col: u32) bool {
    return p.peek() == .lower_ident and p.peekAt(1) == .colon and
        p.lines[p.tok_i] > p.lines[after] and p.col(p.tok_i) > min_col;
}

fn atLaterLayoutFieldHead(p: *const Parse) bool {
    return p.in_layout_field and p.peek() == .lower_ident and p.peekAt(1) == .colon and
        p.lines[p.tok_i] > p.lines[p.head];
}

fn reportLayoutAlignment(p: *Parse, required_col: u32, construct: Construct) Allocator.Error!void {
    if (p.col(p.tok_i) == required_col) return;
    var item = p.itemAt(.unexpected_token);
    item.context = .record;
    item.construct = construct;
    item.required_col = required_col;
    _ = try p.report(item);
}

fn setContext(p: *Parse, context: Context) Context {
    const previous = p.context;
    p.context = context;
    return previous;
}

/// Safety builds only: a loop iteration that is about to loop again consumed at
/// least one token, so every loop terminates at `eof`.
fn assertProgress(p: *const Parse, before: TokenIndex) void {
    std.debug.assert(p.tok_i > before);
}

// ---------------------------------------------------------------------------
// Nodes and extra data
// ---------------------------------------------------------------------------

fn addNode(p: *Parse, node: Node) Allocator.Error!Index {
    const i: Index = @enumFromInt(p.nodes.len);
    try p.node_appender.append(&p.nodes, p.gpa, node);
    return i;
}

fn leaf(p: *Parse, tag: Node.Tag, main_token: TokenIndex) Allocator.Error!Index {
    return p.addNode(.{ .tag = tag, .main_token = main_token, .data = .{ .lhs = 0, .rhs = 0 } });
}

/// A `type_var` node. `marker` is the `equatable` token in front of it, or
/// `.none` — which is NOT zero, so it cannot be spelled with `leaf`.
fn typeVar(p: *Parse, name: TokenIndex, marker: Ast.OptionalTokenIndex) Allocator.Error!Index {
    return p.addNode(.{ .tag = .type_var, .main_token = name, .data = .{ .lhs = @intFromEnum(marker), .rhs = 0 } });
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
    try lists.push(u32, &p.scratch, p.scratch_allocator, v);
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
    if ((p.tags[p.tok_i] == .invalid or p.tags[p.tok_i] == .markup_stray) and item.start == p.starts[p.tok_i]) return null;
    // Markup nested past the lexer's bound is past the parser's too, at the
    // same `<`: one message for one mistake.
    if (item.code == .nesting_too_deep and p.lexReportedAt(item.start, .nesting_too_deep)) return null;
    p.last_error_start = item.start;
    try p.errors.append(p.gpa, item);
    return @intCast(p.errors.items.len - 1);
}

/// Whether the lexer reported `code` at `start` (its items are in source
/// order).
fn lexReportedAt(p: *const Parse, start: u32, code: diagnostic.Code) bool {
    var lo: usize = 0;
    var hi: usize = p.lex_diagnostics.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (p.lex_diagnostics[mid].start < start) lo = mid + 1 else hi = mid;
    }
    while (lo < p.lex_diagnostics.len and p.lex_diagnostics[lo].start == start) : (lo += 1) {
        if (p.lex_diagnostics[lo].code == code) return true;
    }
    return false;
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

/// Skip `invalid` tokens and markup strays the lexer already reported (`peek` hides the
/// cut-off marker, so this never consumes it).
fn skipInvalid(p: *Parse) void {
    while (true) {
        const tag = p.peek();
        if (tag != .invalid and tag != .markup_stray) return;
        _ = p.next();
    }
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
        // Every `enter` this item took has been matched by its `leave`;
        // what is left is the spine charge, which belongs to the item.
        p.resetDepth();
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
                    .upper_ident => try p.pushScratch(try p.exposedUpper()),
                    .lower_ident => try p.pushScratch(try p.leaf(.exposed, p.next())),
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

/// An upper name in an `exposing` list, and Elm's `T(..)` after it (the
/// owner's decision that it gets a message of its own). beni exposes constructors by name beside the type
/// (language.md §5.2), so `(..)` is `expected_token` at its `(` — ONE
/// diagnostic, where the lexer and the parser used to report the `(` and
/// each dot. The node keeps the `(` as its `lhs` (0 when there is none):
/// lowering records it, and resolution, which has the imported module's
/// interface, names the constructors in its message (`Session`
/// `.reportResolveDiagnostics` rewrites this one diagnostic's text, so
/// there is still one), and the uses of them stay quiet. `fmt` and the
/// dumps, which never resolve, print the message as the parser wrote it.
fn exposedUpper(p: *Parse) Allocator.Error!Index {
    const name = p.next();
    if (p.peek() == .l_paren and p.peekAt(1) == .dot_dot and p.peekAt(2) == .r_paren) {
        const open = p.tok_i;
        var item = p.itemAtToken(.expected_token, open);
        item.expected = .r_paren;
        item.construct = .expose_all;
        item.head_start = p.starts[name];
        item.head_end = p.tokenEnd(name);
        _ = try p.report(item);
        _ = p.next();
        _ = p.next();
        _ = p.next();
        return p.addNode(.{ .tag = .exposed, .main_token = name, .data = .{ .lhs = open, .rhs = 0 } });
    }
    return p.leaf(.exposed, name);
}

/// Decl := DocComment? Visibility? (TypeAlias | TypeDecl | Annotation | Definition | Foreign)
fn parseDecl(p: *Parse, docs: Ast.CommentRange, pending: *?PendingAnnotation) Allocator.Error!Index {
    const saved = p.startBlock(.declaration);
    defer p.endBlock(saved);

    var header: Ast.DeclHeader = .{
        .pub_token = .none,
        .opaque_token = .none,
        .equatable_token = .none,
        .doc_start = docs.start,
        .doc_end = docs.end,
        .where_start = @enumFromInt(0),
        .where_end = @enumFromInt(0),
    };
    if (p.eat(.keyword_pub)) |pub_token| {
        header.pub_token = .fromToken(pub_token);
        if (p.eat(.keyword_opaque)) |opaque_token| header.opaque_token = .fromToken(opaque_token);
    }
    // `equatable` is contextual, not a keyword: it is a legal identifier
    // everywhere else, and making it a keyword would break every program
    // that already uses the name. Here it is the marker only when the very
    // next token is `foreign` — two tokens of lookahead, no backtracking.
    if (p.peek() == .lower_ident and p.peekAt(1) == .keyword_foreign and p.isEquatableToken(p.tok_i)) {
        header.equatable_token = .fromToken(p.next());
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
            if (p.peekAt(1) == .keyword_type) break :blk try p.parseForeignType(header);
            // `equatable foreign name : T` — the marker says a TYPE is
            // equatable (checker.md Appendix B), so exactly one token can
            // come next after it and it is `type`.
            if (header.equatable_token.unwrap()) |_| {
                var item = p.itemAt(.expected_token);
                item.expected = .keyword_type;
                _ = try p.report(item);
            }
            break :blk try p.parseForeignValue(header);
        },
        .lower_ident => blk: {
            if (opaque_token) |t| _ = try p.report(p.itemAtToken(.opaque_not_on_type, t));
            if (header.pub_token != .none) {
                if (p.vocabForm()) |form| {
                    try p.reportPendingAnnotation(pending);
                    break :blk try p.parseVocab(header, form);
                }
            }
            if (p.isWord(p.tok_i, "schema") and p.peekAt(1) == .upper_ident) {
                try p.reportPendingAnnotation(pending);
                break :blk try p.parseSchemaDecl(header);
            }
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

fn isWord(p: *const Parse, token: TokenIndex, word: []const u8) bool {
    return p.tags[token] == .lower_ident and std.mem.eql(u8, p.tokenText(token), word);
}

/// SchemaDecl := 'schema' upper_ident lower_ident* SchemaBody (schema.md §2).
fn parseSchemaDecl(p: *Parse, header: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .declaration;
    _ = p.next(); // contextual `schema`
    const name = switch (try p.expectDeclName(.upper_ident)) {
        .name => |n| n,
        .placeholder => |node| return node,
    };
    const params_mark = p.scratchMark();
    defer p.shrinkScratch(params_mark);
    while (p.peek() == .lower_ident and
        !(p.isWord(p.tok_i, "tagged") and p.peekAt(1) == .str_start))
    {
        try p.pushScratch(p.next());
    }
    const params = try p.listToRange(p.scratchSince(params_mark));
    const body = if (p.eat(.equal)) |equal|
        if (p.peek() == .l_brace)
            try p.parseSchemaValue()
        else if (p.atLayoutFieldHeadAfter(equal))
            try p.parseLayoutSchemaRecord()
        else
            try p.parseSchemaValue()
    else if (p.peek() == .lower_ident and p.isWord(p.tok_i, "tagged"))
        try p.parseSchemaTagged()
    else blk: {
        _ = try p.expectToken(.equal);
        break :blk try p.unexpected(.error_type, .type_expr);
    };
    const extra = try p.addExtra(Ast.SchemaDecl{
        .header = header,
        .params_start = params.start,
        .params_end = params.end,
        .body = body,
    });
    return p.addNode(.{ .tag = .schema_decl, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

fn parseSchemaValue(p: *Parse) Allocator.Error!Index {
    const operand = try p.parseSchemaOperand();
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    while (p.atSchemaValueModifier()) try p.pushScratch(try p.parseSchemaModifier(false));
    if (p.scratchSince(mark).len == 0) return operand;
    const modifiers = try p.listToRange(p.scratchSince(mark));
    const extra = try p.addExtra(Ast.SchemaField{
        .header = .none,
        .operand = operand,
        .modifiers_start = modifiers.start,
        .modifiers_end = modifiers.end,
    });
    return p.addNode(.{ .tag = .schema_value, .main_token = p.treeMainToken(operand), .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

fn treeMainToken(p: *const Parse, node: Index) TokenIndex {
    return p.nodes.items(.main_token)[node.int()];
}

fn parseSchemaRecord(p: *Parse) Allocator.Error!Index {
    const saved_layout = p.in_layout_field;
    p.in_layout_field = false;
    defer p.in_layout_field = saved_layout;
    const open = p.next();
    try p.pushBracket(.r_brace);
    defer p.popBracket();
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    _ = p.eat(.comma);
    while (p.peek() != .r_brace and p.peek() != .eof) {
        const before = p.tok_i;
        const docs = p.attachDocs(p.tok_i);
        try p.pushScratch(try p.parseSchemaField(docs));
        if (p.eat(.comma) != null) {
            p.assertProgress(before);
            continue;
        }
        if (p.peek() == .r_brace or p.peek() == .eof) break;
        // Only a field whose NAME did not parse leaves a tail here
        // (`parseSchemaField` consumes a parsed field's own).
        var item = p.itemAt(.unexpected_token);
        item.context = .record;
        item.construct = .field_name;
        _ = try p.report(item);
        while (p.peek() != .comma and p.peek() != .r_brace and p.peek() != .eof) _ = p.next();
        if (p.eat(.comma) == null) break;
        p.assertProgress(before);
    }
    try p.expectCloser(.r_brace, open);
    return p.rangeNode(.schema_record, open, try p.listToRange(p.scratchSince(mark)));
}

/// SchemaFieldBlock := LayoutSchemaField+ (schema.md §2). The returned node
/// is deliberately the brace form's `schema_record`: layout is only sugar.
fn parseLayoutSchemaRecord(p: *Parse) Allocator.Error!Index {
    if (try p.enter()) |placeholder| return placeholder;
    defer p.leave();
    const first = p.tok_i;
    return p.rangeNode(.schema_record, first, try p.parseLayoutFields(.schema));
}

fn parseSchemaField(p: *Parse, docs: Ast.CommentRange) Allocator.Error!Index {
    const name = if (p.peek() == .lower_ident) p.next() else {
        const bad = try p.unexpected(.error_type, .field_name);
        p.recoverUnlessStructural();
        return bad;
    };
    _ = try p.expectToken(.colon);
    var operand = try p.parseSchemaOperand();
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    while (p.atSchemaFieldModifier()) try p.pushScratch(try p.parseSchemaModifier(true));
    if (p.peek() != .comma and p.peek() != .r_brace and p.peek() != .eof) {
        // The field's value did not end where a field ends: what was
        // written is not a schema field, so its value is the placeholder
        // never the prefix that happened to parse. Schema records
        // promise sibling recovery at comma/brace (§2), which generic
        // delimiter recovery cannot provide because it skips to the closing
        // brace: consume the broken field's tail only.
        var item = p.itemAt(.unexpected_token);
        item.context = .record;
        item.construct = .field_name;
        operand = try p.errorNode(.error_type, item);
        while (p.peek() != .comma and p.peek() != .r_brace and p.peek() != .eof) _ = p.next();
        p.shrinkScratch(mark);
    }
    const modifiers = try p.listToRange(p.scratchSince(mark));
    const extra = try p.addExtra(Ast.SchemaField{
        .header = .{ .doc_start = docs.start, .doc_end = docs.end, .pub_token = .none, .opaque_token = .none, .equatable_token = .none, .where_start = @enumFromInt(0), .where_end = @enumFromInt(0) },
        .operand = operand,
        .modifiers_start = modifiers.start,
        .modifiers_end = modifiers.end,
    });
    return p.addNode(.{ .tag = .schema_field, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

fn parseLayoutSchemaField(p: *Parse, docs: Ast.CommentRange) Allocator.Error!Index {
    const saved = p.startBlock(.record);
    defer p.endBlock(saved);
    const saved_layout = p.in_layout_field;
    p.in_layout_field = true;
    defer p.in_layout_field = saved_layout;

    if (p.peek() != .lower_ident) {
        const bad = try p.unexpected(.error_type, .field_name);
        p.recover();
        return bad;
    }
    const name = p.next();
    const colon = try p.expectToken(.colon);
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    var operand = if (colon != null and p.atLayoutFieldHeadAfter(colon.?))
        try p.parseLayoutSchemaRecord()
    else blk: {
        const value = try p.parseSchemaOperand();
        while (p.atSchemaFieldModifier()) try p.pushScratch(try p.parseSchemaModifier(true));
        break :blk value;
    };
    // A tail means the value is not what was written: the placeholder,
    // as in the brace form (`parseSchemaField`).
    if (try p.finishLayoutField(.error_type)) |bad| {
        operand = bad;
        p.shrinkScratch(mark);
    }
    const modifiers = try p.listToRange(p.scratchSince(mark));
    const extra = try p.addExtra(Ast.SchemaField{
        .header = .{ .doc_start = docs.start, .doc_end = docs.end, .pub_token = .none, .opaque_token = .none, .equatable_token = .none, .where_start = @enumFromInt(0), .where_end = @enumFromInt(0) },
        .operand = operand,
        .modifiers_start = modifiers.start,
        .modifiers_end = modifiers.end,
    });
    return p.addNode(.{ .tag = .schema_field, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

fn parseSchemaOperand(p: *Parse) Allocator.Error!Index {
    if (try p.enter()) |err| return err;
    defer p.leave();
    if (p.peek() == .l_brace) return p.parseSchemaRecord();
    if (p.peek() == .l_paren) {
        const open = p.next();
        try p.pushBracket(.r_paren);
        defer p.popBracket();
        const inner = try p.parseSchemaOperand();
        try p.expectCloser(.r_paren, open);
        return p.addNode(.{ .tag = .schema_paren, .main_token = open, .data = .{ .lhs = inner.int(), .rhs = 0 } });
    }
    if (!isSchemaName(p.peek())) return p.unexpected(.error_type, .type_expr);
    const head = p.next();
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    while (p.canStartSchemaAtom() and !p.atSchemaFieldModifier() and !p.atLaterLayoutFieldHead()) {
        if (p.peek() == .l_brace) {
            try p.pushScratch(try p.parseSchemaRecord());
        } else if (p.peek() == .l_paren) {
            const open = p.next();
            try p.pushBracket(.r_paren);
            const inner = try p.parseSchemaOperand();
            try p.expectCloser(.r_paren, open);
            p.popBracket();
            try p.pushScratch(try p.addNode(.{ .tag = .schema_paren, .main_token = open, .data = .{ .lhs = inner.int(), .rhs = 0 } }));
        } else {
            const atom = p.next();
            try p.pushScratch(try p.rangeNode(.schema_operand, atom, try p.listToRange(&.{})));
        }
    }
    return p.rangeNode(.schema_operand, head, try p.listToRange(p.scratchSince(mark)));
}

fn isSchemaName(tag: Tag) bool {
    return tag == .upper_ident or tag == .qualified_upper or tag == .lower_ident;
}

fn canStartSchemaAtom(p: *const Parse) bool {
    return isSchemaName(p.peek()) or p.peek() == .l_paren or p.peek() == .l_brace;
}

fn atSchemaFieldModifier(p: *const Parse) bool {
    if (p.peek() == .keyword_as) return true;
    return p.peek() == .lower_ident and
        (p.isWord(p.tok_i, "via") or p.isWord(p.tok_i, "optional") or p.isWord(p.tok_i, "nullable"));
}

fn atSchemaValueModifier(p: *const Parse) bool {
    return p.peek() == .lower_ident and (p.isWord(p.tok_i, "via") or p.isWord(p.tok_i, "nullable"));
}

fn parseSchemaModifier(p: *Parse, field: bool) Allocator.Error!Index {
    if (p.peek() == .keyword_as and field) {
        const token = p.next();
        const value = try p.parseSchemaString();
        return p.addNode(.{ .tag = .schema_as, .main_token = token, .data = .{ .lhs = value.int(), .rhs = 0 } });
    }
    const token = p.next();
    if (p.isWord(token, "via")) {
        const value = try p.parseAtomAccess(true);
        return p.addNode(.{ .tag = .schema_via, .main_token = token, .data = .{ .lhs = value.int(), .rhs = 0 } });
    }
    return p.leaf(if (p.isWord(token, "optional")) .schema_optional else .schema_nullable, token);
}

fn parseSchemaString(p: *Parse) Allocator.Error!Index {
    if (p.peek() != .str_start) return p.unexpected(.error_expr, .expression);
    const string = try p.parseString();
    const data = p.nodes.items(.data)[string.int()];
    for (p.extra.items[data.lhs..data.rhs]) |raw_part| {
        const part: Index = @enumFromInt(raw_part);
        if (p.nodes.items(.tag)[part.int()] == .interp) {
            var item = p.itemAtToken(.unexpected_token, p.nodes.items(.main_token)[part.int()]);
            item.context = .declaration;
            item.construct = .expression;
            _ = try p.report(item);
        }
    }
    return string;
}

fn parseSchemaTagged(p: *Parse) Allocator.Error!Index {
    const tagged = p.next();
    const discriminator = try p.parseSchemaString();
    const of_token = (try p.expectToken(.keyword_of)) orelse tagged;
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    const leading_pipe = p.eat(.pipe) != null;
    if (p.peek() != .upper_ident) {
        try p.pushScratch(try p.unexpected(.error_constructor, .constructor));
        p.recoverUnlessStructural();
    } else {
        const column = p.col(p.tok_i);
        const layout = !leading_pipe and p.lines[p.tok_i] > p.lines[of_token];
        try p.pushScratch(try p.parseSchemaVariant(layout));
        if (p.eat(.pipe) != null) {
            while (true) {
                if (p.peek() != .upper_ident) {
                    try p.pushScratch(try p.unexpected(.error_constructor, .constructor));
                    p.recoverUnlessStructural();
                } else try p.pushScratch(try p.parseSchemaVariant(false));
                if (p.eat(.pipe) == null) break;
            }
        } else if (layout) while (p.peek() == .upper_ident) {
            if (p.col(p.tok_i) < column) break;
            try p.reportLayoutAlignment(column, .constructor);
            try p.pushScratch(try p.parseSchemaVariant(true));
        };
    }
    const variants = try p.listToRange(p.scratchSince(mark));
    const extra = try p.addExtra(Ast.SchemaTagged{ .discriminator = discriminator, .variants_start = variants.start, .variants_end = variants.end });
    return p.addNode(.{ .tag = .schema_tagged, .main_token = tagged, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

fn parseSchemaVariant(p: *Parse, layout: bool) Allocator.Error!Index {
    const name = p.next();
    var payload = Node.OptionalIndex.none;
    var rename = Node.OptionalIndex.none;
    if (p.peek() == .l_brace) {
        // The brace spelling keeps its historical payload-before-rename
        // order and remains accepted as input.
        payload = (try p.parseSchemaRecord()).toOptional();
        if (p.eat(.keyword_as)) |_| rename = (try p.parseSchemaString()).toOptional();
    } else {
        if (p.eat(.keyword_as)) |_| rename = (try p.parseSchemaString()).toOptional();
        if (layout and p.atLayoutFieldHeadAfterColumn(name, p.col(name))) {
            payload = (try p.parseLayoutSchemaRecord()).toOptional();
        } else if (layout and p.peek() == .l_brace and p.peekAt(1) == .r_brace) {
            // An explicit empty payload has no layout spelling. Canonical
            // layout therefore keeps exactly `{}` after the optional rename.
            payload = (try p.parseSchemaRecord()).toOptional();
        }
    }
    const extra = try p.addExtra(Ast.SchemaVariant{ .payload = payload, .rename = rename });
    return p.addNode(.{ .tag = .schema_variant, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

/// TopAnnotation := lower_ident ':' Type WhereClause?
/// (language.md §3; the clause is static-dispatch-spike.md §2.1.)
fn parseAnnotation(p: *Parse, header_in: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .annotation;
    var header = header_in;
    const name = p.next();
    _ = p.next(); // ':' by lookahead
    const type_expr = try p.parseTopType();
    const clause = try p.parseWhere();
    header.where_start = clause.start;
    header.where_end = clause.end;
    const extra = try p.addExtra(header);
    return p.addNode(.{ .tag = .annotation, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = type_expr.int() } });
}

/// The `Type` of a top-level annotation or `foreign` value: the one
/// position where a following `where` ends it (§2.2).
fn parseTopType(p: *Parse) Allocator.Error!Index {
    const saved = p.in_top_annotation;
    p.in_top_annotation = true;
    defer p.in_top_annotation = saved;
    return p.parseType();
}

/// True at the `where` that begins a clause: the contextual-word rule of
/// §2.2, three tokens and no backtracking. `where` followed by anything
/// but an abutting `lower_ident dot_lower` is an ordinary type variable.
/// Callers inside a type also require `in_top_annotation`; after the type
/// that is the only position left, so `parseWhere` asks this alone.
fn atWhereClause(p: *const Parse) bool {
    if (p.peek() != .lower_ident or !p.isWhereToken(p.tok_i)) return false;
    return p.peekAt(1) == .lower_ident and p.peekAt(2) == .dot_lower and p.adjacent(p.tok_i + 2);
}

/// True when token `t` is the contextual word `where`, compared by TEXT
/// like `equatable` (§2.2).
fn isWhereToken(p: *const Parse, t: TokenIndex) bool {
    return std.mem.eql(u8, Tokenizer.slice(p.source, p.tags[t], p.starts[t]), "where");
}

/// WhereClause := 'where' Constraint (',' Constraint)*  (§2.1). Empty when
/// no clause follows.
fn parseWhere(p: *Parse) Allocator.Error!SubRange {
    if (!p.atWhereClause()) return p.listToRange(&.{});
    _ = p.next(); // `where`
    const saved_context = p.setContext(.where_clause);
    defer p.context = saved_context;
    const saved_where = p.in_where;
    p.in_where = true;
    defer p.in_where = saved_where;
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    while (true) {
        const before = p.tok_i;
        try p.pushScratch(try p.parseWhereConstraint());
        if (p.eat(.comma) == null) break;
        p.assertProgress(before); // the comma, at the very least
    }
    return p.listToRange(p.scratchSince(mark));
}

/// Constraint := lower_ident dot_lower ':' Type (§2.1). The method name is
/// the `dot_lower`, which the lexer only produces where it abuts its atom,
/// so `k . compare` and `k.Compare` are `unexpected_token`.
fn parseWhereConstraint(p: *Parse) Allocator.Error!Index {
    if (p.peek() != .lower_ident) {
        const node = try p.unexpected(.error_type, .constraint);
        p.recoverUnlessStructural();
        return node;
    }
    const variable = p.next();
    if (p.peek() != .dot_lower or !p.adjacent(p.tok_i)) {
        var item = p.itemAt(.expected_token);
        item.expected = .dot_lower;
        const node = try p.errorNode(.error_type, item);
        p.recoverUnlessStructural();
        return node;
    }
    _ = p.next(); // the method name
    _ = try p.expectToken(.colon);
    const type_expr = try p.parseType();
    return p.addNode(.{ .tag = .where_constraint, .main_token = variable, .data = .{ .lhs = type_expr.int(), .rhs = 0 } });
}

/// Definition := lower_ident PatAtom* '=' Expr
fn parseDefinition(p: *Parse, header: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .definition;
    const name = p.next();
    const params = try p.parseParams();
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

/// TypeAlias := 'type' 'alias' upper_ident lower_ident* '=' (Type | FieldBlock)
fn parseTypeAlias(p: *Parse, header: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .type_alias;
    _ = p.next(); // type
    _ = p.next(); // alias
    const name = switch (try p.expectDeclName(.upper_ident)) {
        .name => |n| n,
        .placeholder => |node| return node,
    };
    const params = try p.parseTypeParams();
    const equal = (try p.expectToken(.equal)) orelse name;
    const body = if (p.atLayoutFieldHeadAfter(equal))
        try p.parseLayoutTypeRecord()
    else
        try p.parseType();
    const extra = try p.addExtra(Ast.TypeAlias{ .header = header, .params_start = params.start, .params_end = params.end });
    return p.addNode(.{ .tag = .type_alias, .main_token = name, .data = .{ .lhs = @intFromEnum(extra), .rhs = body.int() } });
}

fn parseLayoutTypeRecord(p: *Parse) Allocator.Error!Index {
    if (try p.enter()) |placeholder| return placeholder;
    defer p.leave();
    const first = p.tok_i;
    return p.rangeNode(.type_record, first, try p.parseLayoutFields(.type));
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

/// Foreign := 'foreign' lower_ident ':' Type WhereClause?
/// (language.md §5.4; the clause is static-dispatch-spike.md §2.1, §5.2.)
fn parseForeignValue(p: *Parse, header_in: Ast.DeclHeader) Allocator.Error!Index {
    p.context = .foreign;
    var header = header_in;
    _ = p.next(); // foreign
    const name = switch (try p.expectDeclName(.lower_ident)) {
        .name => |n| n,
        .placeholder => |node| return node,
    };
    _ = try p.expectToken(.colon);
    const type_expr = try p.parseTopType();
    const clause = try p.parseWhere();
    header.where_start = clause.start;
    header.where_end = clause.end;
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

/// `Type := TypeParams '->' Type | TypeApp` and
/// `TypeParams := TypeApp (',' TypeApp)*` (language.md §3).
///
/// Used everywhere a single, complete type is wanted — an annotation, an
/// alias body, a record field, the result of an arrow. The COMMA is the
/// parameter separator and binds looser than everything except `->`, so the
/// items are collected first and the token after them decides: `->` makes
/// them a parameter list, anything else means there had better be exactly
/// one of them. A parenthesised type is the other reading of the same
/// items and `parseTypeAtom` gathers them itself (`(a, b)` is a tuple).
fn parseType(p: *Parse) Allocator.Error!Index {
    if (try p.enter()) |placeholder| return placeholder;
    defer p.leave();
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    try p.parseTypeItems();
    return p.finishType(mark, .params);
}

/// How the RESULT of an arrow is parsed (`finishType`'s `mode`).
///
/// `.params` is the ordinary reading: the result is a whole `Type`, so
/// `a -> b, c -> d` right-associates into `a -> (b, c -> d)` exactly as
/// language.md §3's `Type := TypeParams '->' Type` says.
///
/// `.single` is what a PARENTHESISED type needs. Inside parentheses the
/// token after the items has already decided that they were a parameter
/// list, so the result runs to the `)` and a top-level comma in it belongs
/// to nobody: it is the tuple-element trap of §3, where the author wrote a
/// tuple whose first element has a bare `->`. Reading the result greedily
/// there would swallow the comma and silently produce a nested function
/// type instead, so in this mode each link of the result's arrow chain is a
/// single `TypeApp` and the comma is left for the caller to report on.
const ResultMode = enum { params, single };

/// `TypeApp (',' TypeApp)*` onto the scratch stack above `mark`.
///
/// **The record-field comma rule** (language.md §3, Types): a comma whose
/// next two tokens are `lower_ident ':'` ends the item list, because a `:`
/// can never follow a type item — that one token of lookahead is what lets
/// `{ a : Int, b : Int }` have two fields with no backtracking and no
/// parentheses around a field of function type. It costs nothing to apply
/// it everywhere rather than only inside a record body, and the reason it
/// is safe is the same reason.
fn parseTypeItems(p: *Parse) Allocator.Error!void {
    try p.pushScratch(try p.parseTypeApp());
    while (p.peek() == .comma and !p.commaEndsFieldType()) {
        const before = p.tok_i;
        defer p.assertProgress(before);
        _ = p.next();
        try p.pushScratch(try p.parseTypeApp());
    }
}

/// Whether the comma at the cursor ends the type it follows rather than
/// separating a parameter list: the record-field rule above, plus — inside
/// a `where` clause — the three-token rule of static-dispatch-spike.md
/// §2.3, `lower_ident dot_lower ':'`, which is the next CONSTRAINT.
fn commaEndsFieldType(p: *const Parse) bool {
    if (p.peekAt(1) == .lower_ident and p.peekAt(2) == .colon) return true;
    return p.in_where and p.peekAt(1) == .lower_ident and p.peekAt(2) == .dot_lower and
        p.adjacent(p.tok_i + 2) and p.peekAt(3) == .colon;
}

/// Turn the items above `mark` into one type: an n-ary `type_fn` when `->`
/// follows, the single item when it does not.
///
/// Two or more items with no arrow INSIDE PARENTHESES is the trap
/// language.md §3 names: the author wrote a tuple one of whose elements has
/// a bare `->`, and the arrow was read as the parameter list's.
/// `arrow_in_tuple_element` says so, and carries the example. Outside
/// parentheses the same shape is an ordinary missing `->` — a parameter
/// list with nothing to be the parameters of — and says that instead, so
/// the message about tuples only appears where a tuple was plausible.
///
/// Either way the items are folded into a `type_tuple` so the rest of the
/// declaration still parses.
fn finishType(p: *Parse, mark: usize, mode: ResultMode) Allocator.Error!Index {
    if (p.eat(.arrow)) |arrow| {
        const params = try p.listToRange(p.scratchSince(mark));
        const result = switch (mode) {
            .params => try p.parseType(),
            .single => try p.parseTypeResult(),
        };
        const extra = try p.addExtra(params);
        return p.addNode(.{
            .tag = .type_fn,
            .main_token = arrow,
            .data = .{ .lhs = @intFromEnum(extra), .rhs = result.int() },
        });
    }
    const items = p.scratchSince(mark);
    if (items.len == 1) return @enumFromInt(items[0]);
    if (p.insideParens()) {
        _ = try p.report(p.itemAt(.arrow_in_tuple_element));
    } else {
        var item = p.itemAt(.expected_token);
        item.expected = .arrow;
        _ = try p.report(item);
    }
    return p.rangeNode(.type_tuple, p.tok_i, try p.listToRange(items));
}

/// The result of an arrow inside parentheses: `TypeApp ('->' <result>)*`,
/// never a comma list (see `ResultMode.single`). `a, b -> c -> d` still
/// right-associates; `(a -> b, c)` stops at the comma so the `.l_paren`
/// branch can report `arrow_in_tuple_element` on it.
fn parseTypeResult(p: *Parse) Allocator.Error!Index {
    if (try p.enter()) |placeholder| return placeholder;
    defer p.leave();
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    try p.pushScratch(try p.parseTypeApp());
    return p.finishType(mark, .single);
}

/// Whether the innermost open bracket is a `(`. The parameter-list reading
/// of a comma list is only a TUPLE's rival inside parentheses.
fn insideParens(p: *const Parse) bool {
    const open = p.brackets.items;
    return open.len != 0 and open[open.len - 1] == .r_paren;
}

/// True when token `t` is the contextual word `equatable` (checker.md
/// Appendix A). Compared by TEXT, not by symbol: the parser has no
/// interner of its own and the tokenizer already knows the extent.
fn isEquatableToken(p: *const Parse, t: TokenIndex) bool {
    return std.mem.eql(u8, Tokenizer.slice(p.source, p.tags[t], p.starts[t]), "equatable");
}

/// TypeApp := 'equatable'? TypeAtom | (upper_ident | qualified_upper) TypeAtom+ | TypeAtom
///
/// The `equatable` marker (checker.md Appendix A) is recognised only where
/// a whole `Type` starts — so `eq : equatable a, a -> Bool` marks
/// the variable `a`, and an ARGUMENT position keeps its old reading:
/// `List equatable` is a list of a variable named `equatable`, not a marked
/// nothing. Whether the file may write the marker at all is a package fact
/// lowering decides (`equatable_outside_core`).
fn parseTypeApp(p: *Parse) Allocator.Error!Index {
    if (p.peek() == .lower_ident and p.peekAt(1) == .lower_ident and p.isEquatableToken(p.tok_i)) {
        const marker = p.next();
        return p.typeVar(p.next(), .fromToken(marker));
    }
    switch (p.peek()) {
        .upper_ident, .qualified_upper => {
            const name = p.next();
            const mark = p.scratchMark();
            defer p.shrinkScratch(mark);
            // `TypeApp` is greedy, so without the `where` guard
            // `Dict k v where k.compare : …` would read `where` as a third
            // type argument (static-dispatch-spike.md §2.2).
            while (canStartTypeAtom(p.peek()) and !(p.in_top_annotation and p.atWhereClause()) and
                !p.atLaterLayoutFieldHead())
            {
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
///           | '(' TypeApp (',' TypeApp)+ ')' | '{' '}' | '{' fields '}'
///           | '{' lower '|' fields '}'
fn parseTypeAtom(p: *Parse) Allocator.Error!Index {
    const saved_context = p.setContext(.type_expr);
    defer p.context = saved_context;
    switch (p.peek()) {
        .lower_ident => return p.typeVar(p.next(), .none),
        .upper_ident, .qualified_upper => return p.rangeNode(.type_con, p.next(), try p.listToRange(&.{})),
        .l_paren => {
            // Inside brackets the `where` comma rule of §2.3 does not
            // apply: a record type's own fields are `lower_ident ':'`, and
            // `{ x : Int, b : Int }` inside a constraint would otherwise
            // have its second field read as the next CONSTRAINT the moment
            // a field name abutted a `.` — the rule is about the clause's
            // top level and nowhere else.
            const saved_where = p.in_where;
            p.in_where = false;
            defer p.in_where = saved_where;
            // The depth charge for a parenthesised type. `parseTypeItems`
            // is called directly below rather than through `parseType`, so
            // `parseTypeItems → parseTypeApp → parseTypeAtom` is a cycle
            // with no other `enter()` in it: without this one a file of
            // 30 000 nested `(` is accepted in silence and a deeper one
            // overflows the stack instead of reporting.
            if (try p.enter()) |placeholder| return placeholder;
            defer p.leave();
            if (p.peekAt(1) == .r_paren) {
                const open = p.next();
                _ = p.next();
                return p.leaf(.type_unit, open);
            }
            const open = p.next();
            try p.pushBracket(.r_paren);
            defer p.popBracket();
            // Inside parentheses the token AFTER the comma-separated items
            // decides what they were (language.md §3, Types): `->` makes
            // them a parameter list, `)` a tuple at two or more and a
            // grouping at one.
            const mark = p.scratchMark();
            defer p.shrinkScratch(mark);
            try p.parseTypeItems();
            if (p.peek() == .arrow) {
                // `.single`: the arrow settled the items, so the result may
                // not go on to eat a comma of its own. One that follows it
                // is the §3 trap — `(Int -> Int, Bool -> Bool)` is not a
                // pair of functions — and says so rather than turning into
                // a nested function type nobody wrote.
                const inner = try p.finishType(mark, .single);
                if (p.peek() == .comma and !p.commaEndsFieldType()) {
                    _ = try p.report(p.itemAt(.arrow_in_tuple_element));
                    // Recover as the tuple that was meant, so the rest of
                    // the declaration still parses. Each further element is
                    // read the same way, arrow and all.
                    p.shrinkScratch(mark);
                    try p.pushScratch(inner);
                    while (p.peek() == .comma and !p.commaEndsFieldType()) {
                        const before = p.tok_i;
                        defer p.assertProgress(before);
                        _ = p.next();
                        try p.pushScratch(try p.parseTypeResult());
                    }
                    const tuple = try p.listToRange(p.scratchSince(mark));
                    try p.expectCloser(.r_paren, open);
                    return p.rangeNode(.type_tuple, open, tuple);
                }
                try p.expectCloser(.r_paren, open);
                return p.unary(.type_paren, open, inner);
            }
            const items = p.scratchSince(mark);
            if (items.len == 1) {
                const only: Index = @enumFromInt(items[0]);
                try p.expectCloser(.r_paren, open);
                return p.unary(.type_paren, open, only);
            }
            const elements = try p.listToRange(items);
            try p.expectCloser(.r_paren, open);
            return p.rangeNode(.type_tuple, open, elements);
        },
        .l_brace => {
            const saved_where = p.in_where;
            p.in_where = false;
            defer p.in_where = saved_where;
            const saved_layout = p.in_layout_field;
            p.in_layout_field = false;
            defer p.in_layout_field = saved_layout;
            const open = p.next();
            try p.pushBracket(.r_brace);
            defer p.popBracket();
            // No `enter()` in this branch: every way into a record type
            // body runs through `parseRecordTypeFields → parseType`, which
            // charges a level, so a `{` cannot nest without paying.
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

const LayoutFieldKind = enum { type, schema };

fn parseLayoutFields(p: *Parse, kind: LayoutFieldKind) Allocator.Error!SubRange {
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    const column = p.col(p.tok_i);
    while (true) {
        const before = p.tok_i;
        const docs = p.attachDocs(p.tok_i);
        switch (kind) {
            .type => try p.pushScratch(try p.parseLayoutTypeField()),
            .schema => try p.pushScratch(try p.parseLayoutSchemaField(docs)),
        }
        p.assertProgress(before);

        if (p.peek() == .eof or p.lines[p.tok_i] <= p.lines[before]) break;
        const next_col = p.col(p.tok_i);
        if (next_col == column) continue;
        if (p.peek() != .lower_ident or p.peekAt(1) != .colon) break;
        if (next_col < column) break;
        try p.reportLayoutAlignment(column, .field_name);
    }
    return p.listToRange(p.scratchSince(mark));
}

fn parseLayoutTypeField(p: *Parse) Allocator.Error!Index {
    const saved = p.startBlock(.record);
    defer p.endBlock(saved);
    const saved_layout = p.in_layout_field;
    p.in_layout_field = true;
    defer p.in_layout_field = saved_layout;

    if (p.peek() != .lower_ident) {
        const bad = try p.unexpected(.error_field, .field_name);
        p.recover();
        return bad;
    }
    const name = p.next();
    const colon = try p.expectToken(.colon);
    const type_expr = if (colon != null and p.atLayoutFieldHeadAfter(colon.?))
        try p.parseLayoutTypeRecord()
    else
        try p.parseType();
    _ = try p.finishLayoutField(null);
    return p.unary(.record_type_field, name, type_expr);
}

/// Anything left to the right of a field after its body is malformed field
/// tail. Preserve a later-line field head for the block loop so it can issue
/// the alignment diagnostic; otherwise recover at the aligned sibling.
fn finishLayoutField(p: *Parse, placeholder: ?Node.Tag) Allocator.Error!?Index {
    if (p.peek() == .eof or p.atLaterLayoutFieldHead()) return null;
    var item = p.itemAt(.unexpected_token);
    item.context = .record;
    item.construct = .field_name;
    const bad: ?Index = if (placeholder) |tag| try p.errorNode(tag, item) else blk: {
        _ = try p.report(item);
        break :blk null;
    };
    p.recover();
    return bad;
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
                _ = p.attachDocs(p.tok_i);
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

/// Charge one level for a node a loop is about to build on its own spine
/// (see `depth`). False when there is no room: `nesting_too_deep` has been
/// reported and the parser has recovered, and the loop must stop and
/// return the chain it has, which is a structurally valid node.
fn enterSpine(p: *Parse) Allocator.Error!bool {
    if (p.depth < max_depth) {
        p.depth += 1;
        return true;
    } else {
        @branchHint(.cold);
        _ = try p.report(p.itemAt(.nesting_too_deep));
        p.recover();
        return false;
    }
}

/// Siblings: children of one node that are not each other's ancestors — a
/// `let`'s bindings and its body, a `case`'s branches. The tree below the
/// node is as deep as its DEEPEST child, not as the sum of them, so the
/// spine charges one child leaves behind are not the next child's to pay
/// (otherwise a flat `let` of 5 000 `x{i} = x{i-1} + 1` would spend the
/// budget on its 4 097th binding and be refused 907 times, "nested more than
/// 4096 levels deep" about a block nested two deep). Each child starts from the
/// depth at `beginSiblings`; `endSiblings` leaves the counter at the
/// deepest child's, which is the height of what was built, so the node
/// stays charged for it if a loop later hangs a chain above it.
const Siblings = struct { start: u32, high: u32 };

fn beginSiblings(p: *const Parse) Siblings {
    return .{ .start = p.depth, .high = p.depth };
}

/// Between two children: remember how deep the last one went and start
/// the next from the parent's depth.
fn nextSibling(p: *Parse, s: *Siblings) void {
    s.high = @max(s.high, p.depth);
    p.depth = s.start;
}

fn endSiblings(p: *Parse, s: Siblings) void {
    p.depth = @max(s.high, p.depth);
}

/// Release every spine charge. Called between top-level items, which is
/// the scope `enterSpine`'s charges live in.
fn resetDepth(p: *Parse) void {
    std.debug.assert(p.depth <= max_depth);
    p.depth = 0;
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
        else => null,
    };
}

/// The operator that may not share a chain with `tag` at the same
/// precedence: `<|` with `|>` (opposite associativities at one level, §6.5:
/// mixing is `non_associative_chain`).
fn conflicting(tag: Tag) Tag {
    return switch (tag) {
        .op_pipe_left => .op_pipe_right,
        .op_pipe_right => .op_pipe_left,
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
        // The node this iteration builds becomes the parent of the one it
        // built last time: one more level of tree, even though the parser
        // does not recurse for it.
        if (!try p.enterSpine()) break;
        const op_token = p.next();
        if (tok == .op_lt) {
            if (try @call(.never_inline, markupArgument, .{ p, op_token })) |placeholder| {
                lhs = try p.binary(info.tag, op_token, lhs, placeholder);
                break;
            }
        }
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
        if (info.tag == .pipe_right) try p.checkPipeRhs(rhs);
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
        if (!try p.enterSpine()) break;
        const q = p.next();
        node = try p.unary(.question, q, node);
        node = try p.parseAccessChain(node);
        if (canStartAtom(p.peek()) or p.peek() == .underscore) {
            @branchHint(.cold);
            _ = try p.report(p.itemAt(.args_after_question));
            // The `apply` wraps the chain: another level.
            if (!try p.enterSpine()) break;
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

/// Arguments after `function`, if any. `Arg := Atom | '_'` (§3): the
/// placeholder is an argument and only an argument, and at most one per
/// application (§6.7), so both of its diagnostics are decided here, where
/// the application is. A block form (`let`, `if`, `case`, lambda) as a bare
/// argument is an error (§3 notes) but is parsed as the last argument so the
/// expression still has a shape.
fn parseArgs(p: *Parse, function: Index) Allocator.Error!Index {
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    try p.pushScratch(function);
    var placeholders: u32 = 0;
    while (true) {
        const before = p.tok_i;
        const tag = p.peek();
        if (tag == .underscore) {
            placeholders += 1;
            if (placeholders == 2) {
                @branchHint(.cold);
                _ = try p.report(p.itemAt(.multiple_placeholders));
            }
            try p.pushScratch(try p.leaf(.placeholder, p.next()));
        } else if (canStartAtom(tag)) {
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
                if (!try p.enterSpine()) break;
                node = try p.unary(.field_access, p.next(), node);
            },
            .dot_index => {
                if (!p.adjacent(p.tok_i)) break;
                if (!try p.enterSpine()) break;
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
            // `-<b />`: markup is not a number (frontend.md §9.4).
            if (p.peek() == .markup_open) {
                @branchHint(.cold);
                var item = p.itemAt(.unexpected_token);
                item.construct = .negated_markup;
                const node = try p.errorNode(.error_expr, item);
                p.recover();
                return node;
            }
            const operand = try p.parseAtomAccess(true);
            return p.unary(.negate, minus, operand);
        },
        .l_paren => return p.parseParens(),
        .l_bracket => return p.parseList(),
        .l_brace => return p.parseRecord(),
        .underscore => {
            // Every `_` that reaches an expression head is outside argument
            // position (§6.7): `parseArgs` takes the legal ones before the
            // atom parser ever sees them.
            @branchHint(.cold);
            const node = try p.errorNode(.error_expr, p.itemAt(.placeholder_outside_argument));
            _ = p.next();
            return node;
        },
        .invalid => return p.invalidNode(.error_expr),
        // The lexer never produces `markup_open` after an operand
        // (frontend.md §9.3), so only an operand start reaches this.
        .markup_open => return @call(.never_inline, parseMarkup, .{p}),
        else => return p.unexpectedExpr(),
    }
}

fn unexpectedExpr(p: *Parse) Allocator.Error!Index {
    @branchHint(.cold);
    var item = p.itemAt(.unexpected_token);
    item.construct = .expression;
    // `<-div>`: `<-` is one token (language.md §2.2), so this is no tag.
    if (p.rawTag() == .arrow_left and p.tok_i + 1 < p.tags.len and p.adjacent(p.tok_i + 1) and
        isMarkupNameStart(p.tags[p.tok_i + 1])) item.construct = .dash_tag;
    const node = try p.errorNode(.error_expr, item);
    p.recoverUnlessStructural();
    return node;
}

// ---------------------------------------------------------------------------
// Markup (language.md §11.3, frontend.md §9.4–§9.5)
// ---------------------------------------------------------------------------

fn isMarkupNameStart(tag: Tag) bool {
    return switch (tag) {
        .lower_ident, .upper_ident, .qualified_lower, .qualified_upper, .int, .float => true,
        else => false,
    };
}

/// Which built-in form, if any, a tag name spells (language.md §11.3).
fn markupKind(p: *const Parse, name: ?TokenIndex) Node.Tag {
    const t = name orelse return .markup_fragment;
    const text = p.tokenText(t);
    if (std.mem.eql(u8, text, "For")) return .markup_for;
    if (std.mem.eql(u8, text, "Show")) return .markup_show;
    return .markup_element;
}

/// A capitalised tag, or a module path then a lower name: a component,
/// whose attributes are the fields of its one record (§11.8).
fn isComponentName(p: *const Parse, name: TokenIndex) bool {
    const text = p.tokenText(name);
    return text.len > 0 and std.ascii.isUpper(text[0]);
}

/// Markup := Element | Fragment. One nesting level per element (§9.4).
fn parseMarkup(p: *Parse) Allocator.Error!Index {
    if (try p.enter()) |placeholder| return placeholder;
    defer p.leave();
    const saved_context = p.setContext(.markup_tag);
    defer p.context = saved_context;
    const open = p.next();
    // The lexer opens markup only before a letter or `>`, and a letter
    // right after the `<` is always the tag's name.
    const name: ?TokenIndex = if (p.peek() == .markup_name) p.next() else null;
    const kind = p.markupKind(name);
    const component = if (name) |n| kind == .markup_element and p.isComponentName(n) else false;

    var record: Ast.Markup = .{
        .name = if (name) |n| .fromToken(n) else .none,
        .attrs_start = @enumFromInt(0),
        .attrs_end = @enumFromInt(0),
        .children_start = @enumFromInt(0),
        .children_end = @enumFromInt(0),
        .open_end = .none,
        .close = .none,
    };
    const attrs = try p.parseMarkupAttrs(name, component);
    record.attrs_start = attrs.start;
    record.attrs_end = attrs.end;

    p.skipInvalid();
    switch (p.peek()) {
        .markup_self_close => record.open_end = .fromToken(p.next()),
        .markup_gt => {
            record.open_end = .fromToken(p.next());
            try p.markup_open.append(p.scratch_allocator, if (name) |n| p.payloads[n] else fragment_symbol);
            defer _ = p.markup_open.pop();
            p.context = .markup_children;
            const children = try p.parseMarkupChildren(open, name, &record);
            record.children_start = children.start;
            record.children_end = children.end;
        },
        else => {
            // The tag ends at the first token that cannot continue it.
            var item = p.itemAt(.expected_token);
            item.expected = .markup_gt;
            _ = try p.report(item);
        },
    }
    const extra = try p.addExtra(record);
    const node = try p.addNode(.{ .tag = kind, .main_token = open, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
    if (p.markup_drift > 0 and p.markup_open.items.len == 0) p.skipDrift();
    return node;
}

/// After the outermost element, the tokens the lexer made of what it took
/// for the children of elements the parser closed at an outer closer, up to
/// as many closing tags: they follow a reported error, and are skipped
/// rather than reported again.
fn skipDrift(p: *Parse) void {
    @branchHint(.cold);
    var nested: u32 = 0;
    while (p.markup_drift > 0) {
        switch (p.peek()) {
            .eof => break,
            .markup_open => {
                nested += 1;
                _ = p.next();
            },
            .markup_self_close => {
                nested -|= 1;
                _ = p.next();
            },
            .markup_close_open => {
                _ = p.next();
                if (p.peek() == .markup_name) _ = p.next();
                if (p.peek() == .markup_gt) _ = p.next();
                if (nested > 0) nested -= 1 else p.markup_drift -= 1;
            },
            else => _ = p.next(),
        }
    }
    p.markup_drift = 0;
}

/// What `markup_open` holds for an open fragment: no symbol of a name,
/// since a name is always interned before its payload is read.
const fragment_symbol = std.math.maxInt(u32);

/// Attr* up to the `>` or `/>` that ends the opening tag.
fn parseMarkupAttrs(p: *Parse, name: ?TokenIndex, component: bool) Allocator.Error!SubRange {
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    while (true) {
        const before = p.tok_i;
        switch (p.peek()) {
            .markup_attr => {
                const attr = p.next();
                if (component and !isFieldName(p.tokenText(attr))) try p.reportComponentProp(attr, name.?);
                try p.pushScratch(try p.parseMarkupAttr(attr));
            },
            .str_start => {
                const quoted = p.tok_i;
                const name_node = try p.parseString();
                if (component) try p.reportComponentProp(quoted, name.?);
                if (p.tree_string_interpolates(name_node)) {
                    @branchHint(.cold);
                    var item = p.itemAtToken(.unexpected_token, quoted);
                    item.construct = .attribute_name;
                    _ = try p.report(item);
                }
                try p.pushScratch(try p.parseEscapeValue(quoted, name_node));
            },
            .l_brace => try p.pushScratch(try p.parseSpread()),
            .invalid, .markup_stray => _ = p.next(), // a stray byte the lexer reported
            else => break,
        }
        p.assertProgress(before);
    }
    return p.listToRange(p.scratchSince(mark));
}

/// A component's attribute is a field of its record (language.md §11.8),
/// so its name must be a lower identifier.
fn isFieldName(text: []const u8) bool {
    if (text.len == 0 or !std.ascii.isLower(text[0])) return false;
    for (text[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn reportComponentProp(p: *Parse, attr: TokenIndex, component: TokenIndex) Allocator.Error!void {
    @branchHint(.cold);
    var item = p.itemAtToken(.unexpected_token, attr);
    // A quoted name spans its whole string.
    if (p.tags[attr] == .str_start) {
        var t = attr;
        while (p.tags[t] != .str_end and p.tags[t] != .eof and p.tags[t] != .invalid) t += 1;
        item.end = p.tokenEnd(t);
    }
    item.construct = .component_prop;
    item.head_start = p.starts[component];
    item.head_end = p.tokenEnd(component);
    _ = try p.report(item);
}

/// Whether a `string` node has a `${…}` part.
fn tree_string_interpolates(p: *const Parse, node: Index) bool {
    if (p.nodes.items(.tag)[node.int()] != .string) return false;
    const data = p.nodes.items(.data)[node.int()];
    for (p.extra.items[data.lhs..data.rhs]) |part| {
        if (p.nodes.items(.tag)[part] == .interp) return true;
    }
    return false;
}

/// `name`, or `name=value`.
fn parseMarkupAttr(p: *Parse, name: TokenIndex) Allocator.Error!Index {
    if (p.peek() != .equal) {
        return p.addNode(.{ .tag = .markup_attr, .main_token = name, .data = .{ .lhs = @intFromEnum(Node.OptionalIndex.none), .rhs = 0 } });
    }
    _ = p.next();
    const brace: u32 = if (p.peek() == .l_brace) p.tok_i else 0;
    const value = try p.parseMarkupValue();
    return p.addNode(.{ .tag = .markup_attr, .main_token = name, .data = .{ .lhs = value.int(), .rhs = brace } });
}

/// `"name"` then `=` and its value. Without the `=`, a braced value right
/// after the name is still read as its value, so the one mistake is one
/// message; anything else leaves the escape with no value.
fn parseEscapeValue(p: *Parse, quoted: TokenIndex, name_node: Index) Allocator.Error!Index {
    var record: Ast.MarkupAttrEscape = .{ .name = name_node, .value = .none, .brace = .none };
    // A name cut off by the end of its line or file is the lexer's one
    // message, and nothing after it is an `=`.
    const cut = p.tags[p.tok_i - 1] != .str_end;
    const has_value = if (cut) false else try p.expectToken(.equal) != null or
        (p.peek() == .l_brace and p.peekAt(1) != .ellipsis);
    if (has_value) {
        if (p.peek() == .l_brace) record.brace = .fromToken(p.tok_i);
        record.value = (try p.parseMarkupValue()).toOptional();
    }
    const extra = try p.addExtra(record);
    return p.addNode(.{ .tag = .markup_attr_escape, .main_token = quoted, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

/// AttrValue := string | '{' Expr '}'.
fn parseMarkupValue(p: *Parse) Allocator.Error!Index {
    switch (p.peek()) {
        .str_start => return p.parseString(),
        .l_brace => {
            const open = p.next();
            const saved_context = p.setContext(.markup_hole);
            defer p.context = saved_context;
            try p.pushBracket(.r_brace);
            defer p.popBracket();
            const value = try p.parseExpr();
            try p.expectCloser(.r_brace, open);
            return value;
        },
        else => {
            @branchHint(.cold);
            // Left in place: it is most likely the next attribute.
            return p.unexpected(.error_expr, .attribute_value);
        },
    }
}

/// `{...e}` (language.md §11.3). A `{` in a tag whose first token is not
/// `...` is `expected_token`, and its expression is kept as the spread's so
/// the tree stays complete.
fn parseSpread(p: *Parse) Allocator.Error!Index {
    const open = p.next();
    const saved_context = p.setContext(.markup_hole);
    defer p.context = saved_context;
    try p.pushBracket(.r_brace);
    defer p.popBracket();
    if (p.eat(.ellipsis) == null) {
        @branchHint(.cold);
        var item = p.itemAt(.expected_token);
        item.expected = .ellipsis;
        _ = try p.report(item);
    }
    const value = try p.parseExpr();
    try p.expectCloser(.r_brace, open);
    return p.unary(.markup_spread, open, value);
}

/// Child* then the closing tag. The children end at `</`, at a token
/// outside the block (a column-1 declaration, the end of the file), or at
/// the closing tag of an element further out (§9.5).
fn parseMarkupChildren(p: *Parse, open: TokenIndex, name: ?TokenIndex, record: *Ast.Markup) Allocator.Error!SubRange {
    const mark = p.scratchMark();
    defer p.shrinkScratch(mark);
    while (true) {
        const before = p.tok_i;
        switch (p.peek()) {
            .markup_text => try p.pushScratch(try p.leaf(.markup_text, p.next())),
            .l_brace => try p.pushScratch(try p.parseHole()),
            .markup_open => try p.pushScratch(try p.parseMarkup()),
            .invalid => _ = p.next(), // a stray byte in text, reported by the lexer
            .markup_close_open => {
                const close_name: ?TokenIndex = if (p.peekAt(1) == .markup_name) p.tok_i + 1 else null;
                if (!p.closerMatches(name, close_name) and p.closesOuter(close_name)) {
                    // `</outer>`: this element was never closed, and the
                    // closer is the outer one's.
                    try p.reportUnclosed(open, name, p.tok_i);
                    p.markup_drift += 1;
                    break;
                }
                record.close = .fromToken(p.next());
                if (close_name != null) _ = p.next();
                if (!p.closerMatches(name, close_name)) try p.reportMismatch(open, name, record.close.unwrap().?, close_name);
                p.skipInvalid();
                if (p.peek() == .markup_gt) {
                    _ = p.next();
                } else {
                    var item = p.itemAt(.expected_token);
                    item.expected = .markup_gt;
                    _ = try p.report(item);
                }
                break;
            },
            else => {
                // `eof`, or a token outside the block.
                try p.reportUnclosed(open, name, p.tok_i);
                break;
            },
        }
        p.assertProgress(before);
    }
    return p.listToRange(p.scratchSince(mark));
}

/// Whether the closing tag named `close_name` (null for `</>`) closes the
/// element named `name` (null for a fragment). Names compare by symbol.
fn closerMatches(p: *const Parse, name: ?TokenIndex, close_name: ?TokenIndex) bool {
    const a = name orelse return close_name == null;
    const b = close_name orelse return false;
    return p.payloads[a] == p.payloads[b];
}

/// Whether the closing tag names an element (or fragment) opened further
/// out than the one being parsed.
fn closesOuter(p: *const Parse, close_name: ?TokenIndex) bool {
    const want = if (close_name) |c| p.payloads[c] else fragment_symbol;
    const outer = p.markup_open.items[0 .. p.markup_open.items.len - 1];
    for (outer) |s| if (s == want) return true;
    return false;
}

/// `unclosed_element` at the opening `<` and its name, naming the token the
/// element ended at, as `unclosed_delimiter` does.
fn reportUnclosed(p: *Parse, open: TokenIndex, name: ?TokenIndex, at: TokenIndex) Allocator.Error!void {
    var item = p.itemAtToken(.unclosed_element, open);
    item.end = if (name) |n| p.tokenEnd(n) else p.tokenEnd(open + 1);
    item.required_col = p.indent;
    if (p.tags[at] != .eof) {
        item.head_start = p.starts[at];
        item.head_end = p.tokenEnd(at);
        if (p.tags[at] == .markup_close_open) {
            // The whole closing tag, `</name>`, is what the message quotes.
            item.construct = .outer_closer;
            var t = at + 1;
            if (p.tags[t] == .markup_name) t += 1;
            item.head_end = if (p.tags[t] == .markup_gt) p.tokenEnd(t) else p.tokenEnd(t - 1);
        }
    }
    _ = try p.report(item);
}

/// `mismatched_closing_tag` at the closing tag, naming both.
fn reportMismatch(p: *Parse, open: TokenIndex, name: ?TokenIndex, close: TokenIndex, close_name: ?TokenIndex) Allocator.Error!void {
    var item = p.itemAtToken(.mismatched_closing_tag, close);
    item.end = if (close_name) |c| p.tokenEnd(c) else p.tokenEnd(close);
    item.head_start = p.starts[open];
    item.head_end = if (name) |n| p.tokenEnd(n) else p.tokenEnd(open + 1);
    _ = try p.report(item);
}

/// '{' Expr? '}' between tags. An empty hole, or one holding only
/// comments, is a `markup_empty_hole`.
fn parseHole(p: *Parse) Allocator.Error!Index {
    const open = p.next();
    const saved_context = p.setContext(.markup_hole);
    defer p.context = saved_context;
    if (p.peek() == .r_brace) {
        _ = p.next();
        return p.leaf(.markup_empty_hole, open);
    }
    if (p.commentSwallowsBrace(open)) {
        @branchHint(.cold);
        // `{-- note}`: the comment ran to the end of the line with the `}`
        // in it, and nothing later closes the hole (§9.5).
        var item = p.itemAtToken(.unclosed_delimiter, open);
        item.expected = .r_brace;
        item.construct = .comment_swallowed_brace;
        const c = p.comments[p.firstCommentAfter(open)];
        item.head_start = c.start;
        item.head_end = Tokenizer.tokenEnd(p.source, .multiline_line, c.start);
        _ = try p.report(item);
        const node = try p.leaf(.markup_empty_hole, open);
        try p.pushBracket(.r_brace);
        defer p.popBracket();
        p.recover();
        return node;
    }
    try p.pushBracket(.r_brace);
    defer p.popBracket();
    const value = try p.parseExpr();
    try p.expectCloser(.r_brace, open);
    return p.unary(.markup_hole, open, value);
}

/// Index of the first comment after token `t`.
fn firstCommentAfter(p: *const Parse, t: TokenIndex) usize {
    var lo: usize = 0;
    var hi: usize = p.comments.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (p.comments[mid].before_token <= t) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// A hole whose `{` is followed on its own line by a comment holding a
/// `}`, and which nothing later in the block closes: the comment took the
/// hole's `}` (language.md §11.3).
fn commentSwallowsBrace(p: *const Parse, open: TokenIndex) bool {
    const i = p.firstCommentAfter(open);
    if (i >= p.comments.len or p.comments[i].before_token != open + 1) return false;
    const c = p.comments[i];
    const line_end = Tokenizer.tokenEnd(p.source, .multiline_line, c.start);
    if (c.start < p.starts[open] or line_end < c.start) return false;
    // The comment must start on the `{`'s line.
    if (std.mem.indexOfScalar(u8, p.source[p.starts[open]..c.start], '\n') != null) return false;
    if (std.mem.indexOfScalar(u8, p.source[c.start..line_end], '}') == null) return false;
    // Anything that does close the hole later makes it an ordinary one.
    var depth: u32 = 0;
    var t = open + 1;
    while (t < p.tags.len and p.tags[t] != .eof and p.inBlock(t)) : (t += 1) switch (p.tags[t]) {
        .l_brace => depth += 1,
        .r_brace => {
            if (depth == 0) return false;
            depth -= 1;
        },
        else => {},
    };
    return true;
}

/// `f <div />`: markup where an operand has already ended (language.md
/// §11.2). One message, then the comparison's placeholder, returned, and the
/// rest of the construct skipped; null for a comparison. Kept out of
/// `parseBinop`'s loop, which it would otherwise slow for every operator.
fn markupArgument(p: *Parse, op_token: TokenIndex) Allocator.Error!?Index {
    if (!p.looksLikeMarkupArgument(op_token)) return null;
    var item = p.itemAtToken(.element_as_argument, op_token);
    item.end = p.tokenEnd(op_token + 1);
    item.head_start = p.starts[op_token - 1];
    item.head_end = p.tokenEnd(op_token - 1);
    const placeholder = try p.errorNode(.error_expr, item);
    p.recover();
    return placeholder;
}

/// `f <div />` (language.md §11.2): after an operand the `<` is a
/// comparison, and what follows its abutting name can only be markup — a
/// `/>`, a `>`, or an `=` after the name and any attribute names. True when
/// the comparison's right operand has that shape; `op` is the `<`.
fn looksLikeMarkupArgument(p: *const Parse, op: TokenIndex) bool {
    const name = op + 1;
    if (name >= p.tags.len or !p.adjacent(name)) return false;
    switch (p.tags[name]) {
        .lower_ident, .upper_ident, .qualified_lower, .qualified_upper => {},
        else => return false,
    }
    var n: u32 = 1;
    while (true) : (n += 1) switch (p.peekAt(n)) {
        .lower_ident => {},
        .op_gt, .equal => return true,
        .op_slash => {
            const slash = p.tok_i + n;
            return p.peekAt(n + 1) == .op_gt and p.adjacent(slash + 1);
        },
        else => return false,
    };
}

// ---------------------------------------------------------------------------
// Vocabulary declarations (language.md §11.14, frontend.md §9.4)
// ---------------------------------------------------------------------------

const VocabForm = enum { element, attribute, event, markup };

/// After `pub`: which vocabulary declaration begins here, if any. The
/// words are contextual, so this is two tokens of lookahead past the word.
fn vocabForm(p: *const Parse) ?VocabForm {
    // The token after the word decides before its text is read: a `pub`
    // annotation, `pub name : T`, costs two tag tests.
    if (p.peek() != .lower_ident) return null;
    switch (p.peekAt(1)) {
        .str_start => {
            const text = p.tokenText(p.tok_i);
            if (std.mem.eql(u8, text, "element")) return .element;
            if (std.mem.eql(u8, text, "attribute")) return .attribute;
            if (std.mem.eql(u8, text, "event")) return .event;
            return null;
        },
        .lower_ident => {
            if (p.peekAt(2) != .colon) return null;
            return if (std.mem.eql(u8, p.tokenText(p.tok_i), "markup")) .markup else null;
        },
        else => return null,
    }
}

/// VocabDecl := 'pub' ('element' | 'attribute' | 'event') string Fact* (':' Type)?
///            | 'pub' 'markup' lower_ident ':' Type
fn parseVocab(p: *Parse, header: Ast.DeclHeader, form: VocabForm) Allocator.Error!Index {
    p.context = .vocabulary;
    _ = p.next(); // the contextual word
    var record: Ast.VocabDecl = .{
        .header = header,
        .name = .none,
        .facts_start = 0,
        .facts_end = 0,
        .type_expr = .none,
    };
    const name_token = p.tok_i;
    if (form == .markup) {
        _ = p.next();
    } else {
        const name = try p.parseString();
        record.name = name.toOptional();
        if (p.tree_string_interpolates(name)) {
            @branchHint(.cold);
            var item = p.itemAtToken(.unexpected_token, name_token);
            item.construct = .vocabulary_name;
            _ = try p.report(item);
        }
    }
    record.facts_start = p.tok_i;
    if (form != .markup) try p.parseFacts(form);
    record.facts_end = p.tok_i;
    if (form != .element) {
        _ = try p.expectToken(.colon);
        record.type_expr = (try p.parseTopType()).toOptional();
    }
    const tag: Node.Tag = switch (form) {
        .element => .vocab_element,
        .attribute => .vocab_attribute,
        .event => .vocab_event,
        .markup => .vocab_markup,
    };
    const extra = try p.addExtra(record);
    return p.addNode(.{ .tag = tag, .main_token = name_token, .data = .{ .lhs = @intFromEnum(extra), .rhs = 0 } });
}

/// What a fact word takes after it.
const FactArgs = enum { none, strings, optional_string, string, name };

fn factArgs(form: VocabForm, word: []const u8) ?FactArgs {
    const Row = struct { []const u8, FactArgs };
    const rows: []const Row = switch (form) {
        .element => &.{ .{ "void", .none }, .{ "svg", .none }, .{ "mathml", .none } },
        .attribute => &.{
            .{ "on", .strings }, .{ "property", .optional_string }, .{ "stateful", .none }, .{ "url", .none },
            .{ "raw", .none },   .{ "classes", .none },             .{ "styles", .none },
        },
        .event => &.{
            .{ "on", .strings },          .{ "name", .string },          .{ "delegated", .none },
            .{ "preventDefault", .none }, .{ "stopPropagation", .none }, .{ "via", .name },
        },
        .markup => &.{},
    };
    for (rows) |r| if (std.mem.eql(u8, r[0], word)) return r[1];
    return null;
}

/// A fact's string argument, consumed as tokens: the facts are kept as a
/// token range (`Ast.VocabDecl`), and lowering reads the text from there.
fn skipFactString(p: *Parse) void {
    _ = p.next(); // str_start
    while (true) {
        if (p.atCutMarker()) {
            _ = p.next();
            return;
        }
        switch (p.peek()) {
            .eof => return,
            .str_end => {
                _ = p.next();
                return;
            },
            else => _ = p.next(),
        }
    }
}

/// Fact* up to `:` or the end of the declaration. A word that is no fact of
/// the form is `unexpected_token`, naming the ones that are, and skipped.
fn parseFacts(p: *Parse, form: VocabForm) Allocator.Error!void {
    while (p.peek() == .lower_ident) {
        const word = p.next();
        const args = factArgs(form, p.tokenText(word)) orelse {
            @branchHint(.cold);
            var item = p.itemAtToken(.unexpected_token, word);
            item.construct = switch (form) {
                .element => .element_fact,
                .attribute => .attribute_fact,
                .event, .markup => .event_fact,
            };
            _ = try p.report(item);
            continue;
        };
        switch (args) {
            .none => {},
            .strings => {
                if (p.peek() != .str_start) {
                    var item = p.itemAt(.expected_token);
                    item.expected = .str_start;
                    _ = try p.report(item);
                }
                while (p.peek() == .str_start) p.skipFactString();
            },
            .optional_string => if (p.peek() == .str_start) p.skipFactString(),
            .string => if (p.peek() == .str_start) {
                p.skipFactString();
            } else {
                var item = p.itemAt(.expected_token);
                item.expected = .str_start;
                _ = try p.report(item);
            },
            .name => _ = try p.expectToken(.lower_ident),
        }
    }
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
        const op_tag = p.peek();
        const op = p.next();
        _ = p.next();
        // `(+)` is the 2-ary function `+` desugars to, but `|>` and `<|`
        // desugar to nothing: they rearrange the call they are written in
        // (§6.5, §6.7), so there is no function to name.
        if (op_tag == .op_pipe_left or op_tag == .op_pipe_right) {
            @branchHint(.cold);
            return p.errorNode(.error_expr, p.itemAtToken(.operator_not_a_function, op));
        }
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
    const params = try p.parseParams();
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
    // The scrutinee and the branches are siblings (`Siblings`).
    var siblings = p.beginSiblings();
    defer p.endSiblings(siblings);
    const scrutinee = try p.parseExpr();
    p.nextSibling(&siblings);
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
            p.nextSibling(&siblings);
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
    // The bindings and the body are siblings (`Siblings`).
    var siblings = p.beginSiblings();
    defer p.endSiblings(siblings);
    if (!canStartBinding(p.peek())) {
        @branchHint(.cold);
        try p.pushScratch(try p.unexpected(.error_binding, .binding));
        p.recoverUnlessStructural();
    } else {
        const column = p.col(p.tok_i);
        while (true) {
            const before = p.tok_i;
            try p.pushScratch(try p.parseLetBinding());
            p.nextSibling(&siblings);
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
///              | LetPattern '<-' App                            (§6.7)
fn parseLetBinding(p: *Parse) Allocator.Error!Index {
    const saved = p.startBlock(.let_bindings);
    defer p.endBlock(saved);
    const head = p.tok_i;
    switch (p.peek()) {
        .lower_ident => {
            if (p.peekAt(1) == .colon) {
                const name = p.next();
                _ = p.next();
                // A `let` annotation takes no `where` clause
                // (static-dispatch-spike.md §2.1, Appendix A.1): evidence
                // parameters belong to a declaration and a `let` binding is
                // not one. The clause is still RECOGNISED here, so the
                // report names `where` instead of letting the greedy type
                // application swallow it and blame whatever follows.
                const type_expr = try p.parseTopType();
                if (p.atWhereClause()) {
                    var item = p.itemAt(.unexpected_token);
                    item.context = .let_bindings;
                    item.construct = .binding;
                    _ = try p.report(item);
                    p.recover();
                }
                return p.unary(.let_annotation, name, type_expr);
            }
            if (p.peekAt(1) != .keyword_as and p.peekAt(1) != .arrow_left) {
                const name = p.next();
                const params = try p.parseParams();
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
    // §6.7 desugars `p <- e` into a call whose last argument is a callback
    // `\p -> rest`, so the bound pattern IS a parameter and is named as
    // one; `p = e` is a `let` pattern. The rule is the same either way
    // (§7) — what differs is only which code says so, and the operator has
    // to be peeked at BEFORE the check so that the parser and the checker
    // (where the same position reappears as a `lambda` parameter) cannot
    // name one position two ways.
    const bind = p.peek() == .arrow_left;
    try p.checkIrrefutable(pattern, if (bind) .refutable_parameter_pattern else .refutable_let_pattern);
    if (bind) {
        _ = p.next();
        const value = try p.parseExpr();
        try p.checkBindRhs(value);
        return p.binary(.let_bind, head, pattern, value);
    }
    _ = try p.expectToken(.equal);
    const value = try p.parseExpr();
    return p.binary(.let_pattern, head, pattern, value);
}

/// The right operand of `|>` is an `App` (§3, §6.7): the operand becomes the
/// callee's first argument, so there has to be a callee. A `let`, `if`,
/// `case` or lambda has no head application to insert into — §3's rule
/// admitting a block as the last operand of a chain does not extend to `|>`
/// — and neither does an operator chain or a `?`. `<|` carries all of them
/// and is unaffected.
///
/// An `Atom` counts, parentheses included: `x |> (f a)` is an `App` whose
/// callee is written in parentheses, and lowering looks through them (§8).
fn checkPipeRhs(p: *Parse, node: Index) Allocator.Error!void {
    const tag = p.nodes.items(.tag)[node.int()];
    if (tag.isError()) return; // already reported as something else
    const is_app = switch (tag) {
        .let, .@"if", .case, .lambda, .question => false,
        else => !Node.Tag.isBinop(tag),
    };
    if (!is_app) {
        @branchHint(.cold);
        _ = try p.report(p.itemAtToken(.pipe_rhs_not_application, p.nodes.items(.main_token)[node.int()]));
    }
}

/// The right-hand side of `<-` is an `App` (§3): a call missing exactly its
/// final argument, or the bare function when that is the only one it takes.
/// Everything else — an operator chain, a `?`, a block form — has no reading
/// as "the call that receives the rest of the block"
/// (`bind_rhs_not_application`). The whole expression is parsed first, so the
/// message points at a complete thing and the binding list stays aligned.
fn checkBindRhs(p: *Parse, node: Index) Allocator.Error!void {
    const tags = p.nodes.items(.tag);
    const data = p.nodes.items(.data);
    // A `|>`/`<|` chain is legal here, because pipes rewrite BEFORE the bind
    // does (§6.7, §8): `x <- File.read path |> Task.mapError f` is
    // `Task.mapError (File.read path) f (\x -> rest)`. The chain's head
    // application is what receives the callback, so that is what is checked.
    var n = node;
    var through_pipe = false;
    while (true) {
        switch (tags[n.int()]) {
            .paren => n = @enumFromInt(data[n.int()].lhs),
            .pipe_right => {
                through_pipe = true;
                n = @enumFromInt(data[n.int()].rhs);
            },
            .pipe_left => {
                through_pipe = true;
                n = @enumFromInt(data[n.int()].lhs);
            },
            else => break,
        }
    }
    const tag = tags[n.int()];
    if (tag.isError()) return; // already reported as something else
    // The final argument of the call is the rest of the block, so the call
    // does not take a `_` as well (§6.7); one written here is a `_` outside
    // argument position.
    if (tag == .apply) {
        for (p.applyArgs(n)) |arg| {
            if (tags[arg] == .placeholder) {
                @branchHint(.cold);
                _ = try p.report(p.itemAtToken(.placeholder_outside_argument, p.nodes.items(.main_token)[arg]));
            }
        }
        return;
    }
    // Whatever the head of a pipe chain is, the chain is a call once it is
    // rewritten, so there is always something for the callback to be the
    // last argument of.
    if (through_pipe) return;
    switch (tag) {
        // A bare name is accepted: an `App` with no arguments written, whose
        // callee takes the rest of the block and nothing else. That is
        // `let scope <- Task.scope`, §6.7's own example and the case
        // `fast-compiler.md` §9.3 item 7 says the form exists to reach.
        // §6.7's prose also lists "a bare name" among the rejected
        // right-hand sides, which contradicts its example; delete this line
        // to take the other reading.
        .ident, .ctor, .field_access, .tuple_index, .op_fn => {},
        else => {
            @branchHint(.cold);
            var item = p.itemAtToken(.bind_rhs_not_application, p.nodes.items(.main_token)[n.int()]);
            item.context = .let_bindings;
            _ = try p.report(item);
        },
    }
}

/// The argument node indices of an `apply` (element 0 of its range is the
/// function).
fn applyArgs(p: *const Parse, node: Index) []const u32 {
    const d = p.nodes.items(.data)[node.int()];
    return p.extra.items[d.lhs + 1 .. d.rhs];
}

/// The HALF of §7's irrefutability rule that types cannot change: a
/// literal, a list and a `::` match some values of their type and not
/// others whatever that type turns out to be, so they are rejected here,
/// early and cheaply, in every irrefutable position — a `let` pattern, a
/// `<-` bound pattern, and the parameters of a definition, a `let`-bound
/// function or a lambda. `code` says which position found it.
///
/// A **constructor** pattern is not decided here. Whether `Box x` always
/// matches depends on how many constructors `Box`'s type has, which is a
/// question about types; the checker asks it with the same usefulness
/// analysis a `case` gets (`checker.md` §6.6) and raises the same two
/// codes. So this walk descends THROUGH a constructor's arguments — a `::`
/// inside one is still hopeless — without judging the constructor itself.
fn checkIrrefutable(p: *Parse, node: Index, code: diagnostic.Code) Allocator.Error!void {
    const tags = p.nodes.items(.tag);
    const data = p.nodes.items(.data);
    const tag = tags[node.int()];
    // Already reported as whatever it really was — the depth guard hands a
    // pattern position an `error_expr` — and "it is also refutable" adds
    // nothing to that.
    if (tag.isError()) return;
    switch (tag) {
        .pat_wild, .pat_var, .pat_unit, .pat_record => {},
        .pat_paren, .pat_as => try p.checkIrrefutable(@enumFromInt(data[node.int()].lhs), code),
        .pat_tuple, .pat_ctor => {
            const range: SubRange = .{ .start = @enumFromInt(data[node.int()].lhs), .end = @enumFromInt(data[node.int()].rhs) };
            for (p.extra.items[@intFromEnum(range.start)..@intFromEnum(range.end)]) |child| try p.checkIrrefutable(@enumFromInt(child), code);
        },
        else => {
            @branchHint(.cold);
            var item = p.itemAtToken(code, p.nodes.items(.main_token)[node.int()]);
            // A binding list has to name its context: `parsePattern` has
            // restored whatever enclosed the `let`, which is not it. A
            // parameter's ambient context is already the definition or the
            // lambda it belongs to.
            if (code == .refutable_let_pattern) item.context = .let_bindings;
            _ = try p.report(item);
        },
    }
}

/// The parameters of a `Definition`, of a `let`-bound function or of a
/// lambda (§3), each checked against §7: a parameter pattern is
/// irrefutable, exactly as a `let` pattern is. That is what lets the
/// backend destructure one with no test at all (`backend.md` §4). What is
/// checked HERE is only the half of the rule that needs no types.
fn parseParams(p: *Parse) Allocator.Error!SubRange {
    const params = try p.parsePatAtoms();
    var i = @intFromEnum(params.start);
    while (i < @intFromEnum(params.end)) : (i += 1) {
        try p.checkIrrefutable(@enumFromInt(p.extra.items[i]), .refutable_parameter_pattern);
    }
    return params;
}

// ---------------------------------------------------------------------------
// Patterns
// ---------------------------------------------------------------------------

fn canStartPatAtom(tag: Tag) bool {
    return switch (tag) {
        // `.float` starts no pattern (language.md §3, `PatAtom`), but it is
        // taken as the start of one so `parsePatAtom` can say so
        // rather than end the `case` in a layout error.
        .underscore, .lower_ident, .upper_ident, .qualified_upper, .int, .float, .char, .str_start, .l_paren, .l_bracket, .l_brace, .invalid => true,
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
        // No name: the pattern keeps the part it HAS rather than a
        // `pat_as` whose name token is the `as` keyword. Lowering reads
        // that token with `tokenSymbol`, which asserts the tag is an
        // interned one — a keyword is not, so the old placeholder panicked
        // in Debug and, in ReleaseFast where the assert is gone, bound a
        // variable named `main` (a keyword's payload is 0, which is
        // `WellKnown.main`). `expectToken` has already reported.
        const name = (try p.expectToken(.lower_ident)) orelse return inner;
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

/// A float literal where a pattern was needed: `unexpected_token` with a
/// message of its own (the owner's decision: only the message was
/// wrong, so there is no new code). The grammar has no float
/// pattern (language.md §3, `PatAtom`) — matching on `==` of a float is not
/// something a `case` should promise — so the literal is consumed and
/// stands as an error pattern, and the `case` goes on with its branches
/// instead of ending in a layout error at the literal.
fn floatPattern(p: *Parse) Allocator.Error!Index {
    @branchHint(.cold);
    const node = try p.unexpected(.error_pattern, .float_pattern);
    _ = p.next();
    return node;
}

fn parseNegIntPattern(p: *Parse) Allocator.Error!Index {
    const minus = p.next();
    if (p.peek() == .float) return p.floatPattern();
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
    // Charged as well as `parsePattern`, because a bracketed atom is a
    // NODE of its own: `Just (Just (…))` is `pat_ctor` over `pat_paren`
    // over `pat_ctor`, two tree levels per source level, and one charge
    // apiece would let a 4096-charge pattern build an 8192-deep tree. Every
    // consumer walks that tree by recursion — `dump --stage=ast` and the
    // formatter over the AST, lowering over it again — so the guard has to
    // bound the TREE and not the source nesting. Before this, 4000 levels
    // of `Just (` segfaulted `check`, both dumps and `fmt`.
    if (try p.enter()) |placeholder| return placeholder;
    defer p.leave();
    const saved_context = p.setContext(.pattern);
    defer p.context = saved_context;
    switch (p.peek()) {
        .underscore => return p.leaf(.pat_wild, p.next()),
        .lower_ident => return p.leaf(.pat_var, p.next()),
        .upper_ident, .qualified_upper => return p.rangeNode(.pat_ctor, p.next(), try p.listToRange(&.{})),
        .int => return p.leaf(.pat_int, p.next()),
        .float => return p.floatPattern(),
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
const fuzzing = @import("../fuzzing.zig");
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
        const pos = diagnostic.position(r.out.line_starts.items, got.start);
        if (got.code != want.code or pos.line != want.line or pos.col != want.col) mismatch = true;
    };
    if (mismatch) {
        std.debug.print("errors differ; got:\n", .{});
        for (r.tree.errors) |got| {
            const pos = diagnostic.position(r.out.line_starts.items, got.start);
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
        .exposed, .type_var, .type_unit, .int, .float, .char, .chunk, .ident, .ctor, .accessor, .op_fn, .unit, .placeholder, .pat_wild, .pat_var, .pat_int, .pat_neg_int, .pat_char, .pat_string, .pat_unit => {},
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
        .schema_decl => {
            const d = tree.fullSchemaDecl(n);
            try checkHeader(d.header, token_count, comment_count);
            try checkTokens(d.params, token_count);
            try checkIndex(tree, d.body);
        },
        .schema_field, .schema_value => {
            const f = tree.fullSchemaField(n);
            try checkHeader(f.header, token_count, comment_count);
            try checkIndex(tree, f.operand);
            try checkIndices(tree, f.modifiers);
        },
        .schema_tagged => {
            const t = tree.fullSchemaTagged(n);
            try checkIndex(tree, t.discriminator);
            try checkIndices(tree, t.variants);
        },
        .schema_variant => {
            const v = tree.fullSchemaVariant(n);
            if (v.payload) |p| try checkIndex(tree, p);
            if (v.rename) |r| try checkIndex(tree, r);
        },
        .schema_optional, .schema_nullable => {},
        .constructor, .type_con, .type_tuple, .type_record, .string, .tuple, .list, .record, .apply, .pat_ctor, .pat_tuple, .pat_list, .schema_operand, .schema_record => {
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
        .type_paren, .record_type_field, .interp, .negate, .paren, .field, .field_access, .tuple_index, .question, .let_annotation, .pat_paren, .schema_paren, .schema_as, .schema_via => try checkIndex(tree, tree.operand(n)),
        .type_fn => {
            const f = tree.fullTypeFn(n);
            try testing.expect(f.params.len >= 1);
            try checkIndices(tree, f.params);
            try checkIndex(tree, f.result);
        },
        .pat_cons => {
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
        .let_pattern, .let_bind => {
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
        .markup_element, .markup_fragment, .markup_for, .markup_show => {
            const m = tree.fullMarkup(n);
            try testing.expect(m.open < token_count);
            if (m.name) |t| try testing.expect(t < token_count);
            if (m.open_end) |t| try testing.expect(t < token_count);
            if (m.close) |t| try testing.expect(t < token_count);
            try checkIndices(tree, m.attrs);
            try checkIndices(tree, m.children);
        },
        .markup_attr, .markup_attr_escape => {
            const a = tree.fullMarkupAttr(n);
            if (a.name_string) |s| try checkIndex(tree, s);
            if (a.value) |v| try checkIndex(tree, v);
            if (a.brace) |t| try testing.expect(t < token_count);
        },
        .markup_spread, .markup_hole => try checkIndex(tree, tree.operand(n)),
        .markup_text, .markup_empty_hole => {},
        .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => {
            const v = tree.fullVocab(n);
            try checkHeader(v.header, token_count, comment_count);
            if (v.name_string) |s| try checkIndex(tree, s);
            try testing.expect(v.facts_start <= v.facts_end and v.facts_end <= token_count);
            if (v.type_expr) |t| try checkIndex(tree, t);
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
        \\f : (a -> b), List a -> List b
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
        \\      (type_con List
        \\        (type_var a))
        \\      (type_con List
        \\        (type_var b))))
        \\  (definition f
        \\    (pat_var g)
        \\    (pat_var xs)
        \\    (ident xs))
        \\  (definition pub answer
        \\    (int 42)))
        \\
    );
}

test "types: the comma is the parameter separator and the arrow right-associates in its result" {
    // language.md §3, Types: `a, b -> c -> d` is a 2-ary function returning
    // a 1-ary one, a tuple is the `)` reading of the same items, and a
    // comma inside a record body ends the FIELD when `lower_ident :`
    // follows — one token of lookahead, no backtracking.
    try expectTree(
        \\a : Int, Int -> Int -> Int
        \\b : Dict.Dict String (List ( Int, Maybe b )) -> List b
        \\c : { r | x : Int, y : Int } -> Int
        \\d : { f : Int, Int -> Int, g : Bool }, ( Int, Int ) -> Int
        \\
    ,
        \\(module
        \\  (annotation a
        \\    (type_fn
        \\      (type_con Int)
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
        \\          (type_con Int))
        \\        (record_type_field y
        \\          (type_con Int)))
        \\      (type_con Int)))
        \\  (annotation d
        \\    (type_fn
        \\      (type_record
        \\        (record_type_field f
        \\          (type_fn
        \\            (type_con Int)
        \\            (type_con Int)
        \\            (type_con Int)))
        \\        (record_type_field g
        \\          (type_con Bool)))
        \\      (type_tuple
        \\        (type_con Int)
        \\        (type_con Int))
        \\      (type_con Int))))
        \\
    , &.{
        .{ .code = .annotation_without_definition, .line = 1, .col = 1 },
        .{ .code = .annotation_without_definition, .line = 2, .col = 1 },
        .{ .code = .annotation_without_definition, .line = 3, .col = 1 },
        .{ .code = .annotation_without_definition, .line = 4, .col = 1 },
    });
}

// ---- Expressions -----------------------------------------------------------

test "every atom: literals, names, brackets, operator functions, strings, multiline" {
    try expectClean(
        \\v = ( (+), (::), (^), (), (1), (1, 2), [], [1], {}, 'c', 1.5, 0x1F, "a${b}c", "", \a b -> a, if a then b else c )
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
        \\      (op_fn ^)
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
    , &.{ .{ .code = .non_associative_chain, .line = 6, .col = 19 }, .{ .code = .non_associative_chain, .line = 7, .col = 19 } });
    // The other order of mixed pipes.
    try expectTree("f g x y = g <| x |> y\n",
        \\(module
        \\  (definition f
        \\    (pat_var g)
        \\    (pat_var x)
        \\    (pat_var y)
        \\    (pipe_left
        \\      (ident g)
        \\      (pipe_right
        \\        (ident x)
        \\        (ident y)))))
        \\
    , &.{.{ .code = .non_associative_chain, .line = 1, .col = 18 }});
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
        \\a6 = .a
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
        \\    (accessor .a))
        \\  (definition a7
        \\    (pat_var t)
        \\    (tuple_index .00
        \\      (ident t))))
        \\
    , &.{.{ .code = .invalid_tuple_index, .line = 7, .col = 9 }});
}

test "`_` is an argument and only an argument (§6.7)" {
    try expectTree(
        \\p1 f a c = f a _ c
        \\p2 f g b = f (g _) b
        \\p3 f = f _
        \\p4 f g = f (_)
        \\p5 f a b = f _ a _ b
        \\
    ,
        \\(module
        \\  (definition p1
        \\    (pat_var f)
        \\    (pat_var a)
        \\    (pat_var c)
        \\    (apply
        \\      (ident f)
        \\      (ident a)
        \\      (placeholder)
        \\      (ident c)))
        \\  (definition p2
        \\    (pat_var f)
        \\    (pat_var g)
        \\    (pat_var b)
        \\    (apply
        \\      (ident f)
        \\      (paren
        \\        (apply
        \\          (ident g)
        \\          (placeholder)))
        \\      (ident b)))
        \\  (definition p3
        \\    (pat_var f)
        \\    (apply
        \\      (ident f)
        \\      (placeholder)))
        \\  (definition p4
        \\    (pat_var f)
        \\    (pat_var g)
        \\    (apply
        \\      (ident f)
        \\      (paren
        \\        (error placeholder_outside_argument))))
        \\  (definition p5
        \\    (pat_var f)
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (apply
        \\      (ident f)
        \\      (placeholder)
        \\      (ident a)
        \\      (placeholder)
        \\      (ident b))))
        \\
    , &.{ .{ .code = .placeholder_outside_argument, .line = 4, .col = 13 }, .{ .code = .multiple_placeholders, .line = 5, .col = 18 } });
}

test "`<-` binds the rest of the block; its right-hand side must be a call (§6.7)" {
    try expectTree(
        \\b1 f rest =
        \\    let
        \\        x <- f rest
        \\    in
        \\    x
        \\
        \\
        \\b2 f g =
        \\    let
        \\        a = 1
        \\        ( x, y ) <- f a
        \\        b = 2
        \\    in
        \\    g x y b
        \\
        \\
        \\b3 f =
        \\    let
        \\        x <- f 1 + 2
        \\    in
        \\    x
        \\
    ,
        \\(module
        \\  (definition b1
        \\    (pat_var f)
        \\    (pat_var rest)
        \\    (let
        \\      (let_bind
        \\        (pat_var x)
        \\        (apply
        \\          (ident f)
        \\          (ident rest)))
        \\      (ident x)))
        \\  (definition b2
        \\    (pat_var f)
        \\    (pat_var g)
        \\    (let
        \\      (let_def a
        \\        (int 1))
        \\      (let_bind
        \\        (pat_tuple
        \\          (pat_var x)
        \\          (pat_var y))
        \\        (apply
        \\          (ident f)
        \\          (ident a)))
        \\      (let_def b
        \\        (int 2))
        \\      (apply
        \\        (ident g)
        \\        (ident x)
        \\        (ident y)
        \\        (ident b))))
        \\  (definition b3
        \\    (pat_var f)
        \\    (let
        \\      (let_bind
        \\        (pat_var x)
        \\        (add
        \\          (apply
        \\            (ident f)
        \\            (int 1))
        \\          (int 2)))
        \\      (ident x))))
        \\
    , &.{.{ .code = .bind_rhs_not_application, .line = 19, .col = 18 }});
}

test "`|>` takes only an application, and neither pipe has a parenthesised form (§6.5, §6.7)" {
    // `<|` is unaffected and still carries a block, which the chain test
    // below covers; here only `|>` and the two operator-function forms.
    try expectClean(
        \\p1 xs f = xs |> f
        \\p2 xs f = xs |> f 1
        \\p3 xs f = xs |> (f 1)
        \\p4 xs f g = xs |> f 1 |> g
        \\
    ,
        \\(module
        \\  (definition p1
        \\    (pat_var xs)
        \\    (pat_var f)
        \\    (pipe_right
        \\      (ident xs)
        \\      (ident f)))
        \\  (definition p2
        \\    (pat_var xs)
        \\    (pat_var f)
        \\    (pipe_right
        \\      (ident xs)
        \\      (apply
        \\        (ident f)
        \\        (int 1))))
        \\  (definition p3
        \\    (pat_var xs)
        \\    (pat_var f)
        \\    (pipe_right
        \\      (ident xs)
        \\      (paren
        \\        (apply
        \\          (ident f)
        \\          (int 1)))))
        \\  (definition p4
        \\    (pat_var xs)
        \\    (pat_var f)
        \\    (pat_var g)
        \\    (pipe_right
        \\      (pipe_right
        \\        (ident xs)
        \\        (apply
        \\          (ident f)
        \\          (int 1)))
        \\      (ident g))))
        \\
    );
    // The tree stays complete after each report, so one bad pipe does not
    // swallow the declarations after it.
    try expectTree(
        \\e1 xs = xs |> \x -> x
        \\e2 c a b = a |> if c then b else a
        \\e3 x f = x |> f 1 + 2
        \\e4 = (|>)
        \\e5 = (<|)
        \\
    ,
        \\(module
        \\  (definition e1
        \\    (pat_var xs)
        \\    (pipe_right
        \\      (ident xs)
        \\      (lambda
        \\        (pat_var x)
        \\        (ident x))))
        \\  (definition e2
        \\    (pat_var c)
        \\    (pat_var a)
        \\    (pat_var b)
        \\    (pipe_right
        \\      (ident a)
        \\      (if
        \\        (ident c)
        \\        (ident b)
        \\        (ident a))))
        \\  (definition e3
        \\    (pat_var x)
        \\    (pat_var f)
        \\    (pipe_right
        \\      (ident x)
        \\      (add
        \\        (apply
        \\          (ident f)
        \\          (int 1))
        \\        (int 2))))
        \\  (definition e4
        \\    (error operator_not_a_function))
        \\  (definition e5
        \\    (error operator_not_a_function)))
        \\
    , &.{
        .{ .code = .pipe_rhs_not_application, .line = 1, .col = 15 },
        .{ .code = .pipe_rhs_not_application, .line = 2, .col = 17 },
        .{ .code = .pipe_rhs_not_application, .line = 3, .col = 19 },
        .{ .code = .operator_not_a_function, .line = 4, .col = 7 },
        .{ .code = .operator_not_a_function, .line = 5, .col = 7 },
    });
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
        // `Just y` on line 9 is NOT reported here: whether a constructor
        // always matches depends on how many its type has, which the
        // parser does not know, so §7 leaves it to the checker. The
        // literal and the `::` can never match everything whatever the
        // types are, so those two stay parse errors.
    , &.{ .{ .code = .refutable_let_pattern, .line = 10, .col = 9 }, .{ .code = .refutable_let_pattern, .line = 11, .col = 12 } });
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

test "recovery: a quoted attribute name without `=` records its value and brace, or none" {
    try expectTree("v y = <a \"x\" {y} />\nw = <a \"x\" \"z\"=\"q\" />\nu = <a \"x\"",
        \\(module
        \\  (definition v
        \\    (pat_var y)
        \\    (markup_element a
        \\      (markup_attr_escape "x" braced
        \\        (ident y))))
        \\  (definition w
        \\    (markup_element a
        \\      (markup_attr_escape "x")
        \\      (markup_attr_escape "z"
        \\        (string
        \\          (chunk "q")))))
        \\  (definition u
        \\    (markup_element a
        \\      (markup_attr_escape "x"))))
        \\
    , &.{
        .{ .code = .expected_token, .line = 1, .col = 14 },
        .{ .code = .expected_token, .line = 2, .col = 12 },
        .{ .code = .expected_token, .line = 3, .col = 11 },
    });
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
        "schema X = { a : Int as\n",
        "type alias X =\n    a :\n        b : Int\n",
        "schema X =\n    a :\n        b : Int optional\n",
        "schema T tagged \"kind\" of A as \n",
        "schema T tagged \"kind\" of\n    A as \"a\"\n        x : Int\n    B\n",
        "schema Page a = { items : List a optional nullable }\n",
        "let in in let\n",
        "x = \\ -> \\x\n",
    } });
}

test "every loop that could run past the last token stops at it" {
    // One input per check that stops a loop at `eof`, each ending inside
    // that loop: resynchronising after an error inside a declaration and
    // at the top level; a schema field whose name did not parse, and one
    // whose value did not end; and the leftovers of a broken
    // interpolation. Without its check, each consumes `eof` and reads past
    // the tokens.
    for ([_][:0]const u8{
        "x = 1 )",
        ") x",
        "schema X = { : Int",
        "schema X = { a : Int 5",
        "x = \"${ b ) c",
    }) |source| try checkArbitrary(source);
}

/// Token-shaped pieces (each a well-formed token, space or newline) and
/// real grammar fragments; mixing them produces every kind of half-valid
/// program the parser must survive.
const soup_pieces = [_][]const u8{
    "x",      "foo",    "Bar",    "Json.Decode.string", "Maybe.Just", ".field",   ".0",
    "42",     "1.5",    "\"s\"",  "\"a ${x} b\"",       "'c'",        "\\\\raw",  "if",
    "then",   "else",   "case",   "of",                 "let",        "in",       "type",
    "alias",  "pub",    "opaque", "import",             "as",         "exposing", "foreign",
    "schema", "tagged", "via",    "optional",           "nullable",   "(",        ")",
    "[",      "]",      "{",      "}",                  ",",          ":",        "=",
    "->",     "\\",     "|",      "_",                  "?",          "+",        "-",
    "*",      "/",      "//",     "^",                  "++",         "::",       "==",
    "/=",     "<",      ">",      "<=",                 ">=",         "&&",       "||",
    "|>",     "<|",     "<-",     "<--",                " ",          " ",        " ",
    "\n",     "\n",     "\n    ", "\n        ",         "-- c\n",     "--| d\n",  "--! m\n",
    "@",      "\t",     "12abc",  "<div",               "</",         "/>",       "<>",
    "</>",    "{...",   " text ",
};

const fragment_pieces = [_][]const u8{
    "x = 1\n",
    "f a b = a + b\n",
    "import Json.Decode as D exposing (Decoder, string)\n",
    "type T a = A | B a (List a)\n",
    "type alias P = { x : Int, y : Int }\n",
    "type alias Layout =\n    x : Int\n    nested :\n        y : String\n",
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
    "n xs = List.map (add 1 _) xs\n",
    "schema User = { id : Int as \"user-id\", name : String optional nullable }\n",
    "schema LayoutUser =\n    id : Int as \"user-id\"\n    nested :\n        name : String optional nullable\n",
    "schema Page item = { items : List item via (convert item) }\n",
    "schema Message tagged \"kind\" of Count Int as \"count\" | Reset\n",
    "v =\n    <div class=\"a\" id={x} hidden>Hi {x}!<br /><></></div>\n",
    "w = (<For each={xs} keyed={.id}>{\\x -> <li>{x}</li>}</For>)\n",
    "c = <Card {...d} title=\"t\">{-- n\n    }</Card>\n",
    "pub element \"input\" void\n",
    "pub event \"onInput\" on \"input\" via value : String\n",
    "schema LayoutMessage tagged \"kind\" of\n    Count as \"count\"\n        value : Int\n    Reset\n",
    "o f =\n    let\n        x <- f 1\n        y = 2\n    in\n    x + y\n",
};

// PRNG-driven stand-in for the fuzzer (the toolchain's fuzz mode does not
// build on 0.16.0): token soup and grammar fragments, mixed at random.
// Opt-in (`zig build fuzz`, `fuzzing.zig`); the gates run the inputs above,
// one per check. `BENI_STRESS_ITERATIONS` raises the count for a long run.
test "stress: token soup and grammar fragments never panic and always yield a well-formed tree" {
    try fuzzing.skipUnlessFuzzing();
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
