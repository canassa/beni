//! Ast → Bir (docs/design/language.md §5–§8, frontend.md §3.6): one pass
//! over the tree that resolves every name, desugars what §8.2 lists,
//! computes the interface skeleton and the per-declaration reference sets,
//! and reports the diagnostics of §5.3, §6.2, §6.6 and §7.
//!
//! Order of work, per file:
//!   1. Imports: the import table, `duplicate_import`,
//!      `duplicate_import_alias`, `self_import`; every `exposing` name goes
//!      into the namespace tables as an "exposed" entry.
//!   2. Declarations, headers only: one `Decl` per top-level item, the
//!      value/type/constructor namespace tables (`duplicate_declaration`,
//!      `duplicate_type`, `duplicate_constructor`, `shadows_import`,
//!      `foreign_outside_platform`), the interface. Top-level names are in scope
//!      in every body regardless of order (§7), so this must finish before
//!      any body is lowered — it is a walk over the root items, not over
//!      bodies, and is the only thing that looks at a declaration twice.
//!   3. Declarations, bodies: types, parameters, expressions, in source
//!      order, each into its own contiguous instruction range.
//!
//! Scopes are a flat array of `(symbol, local index, token)` with per-scope
//! marks; a lookup scans backwards. Scopes are small, and this beats a hash
//! map on every measurement Zig and Roc made (frontend.md §3.6). The three
//! top-level namespaces are `AutoHashMapUnmanaged(Symbol, …)`: a symbol is
//! a SPARSE key here (a file mentions a few hundred of a worker's tens of
//! thousands of symbols), so a hash map is the right structure here, and it
//! is on the dense-id lint's list (`src/rules_test.zig`) with why. A column
//! per worker indexed by symbol and stamped per file, which costs no memset,
//! was built and measured: fewer instructions, but more page faults than it
//! saved time, since it touches a slot for every symbol the worker ever
//! declared a name with. Prelude membership is not a lookup at
//! all: `InternPool.Local.init` fixes the prelude names at their
//! `WellKnown` indices (`prelude.zig`).
//!
//! Every reference to a top-level or imported name is recorded in the
//! declaration's `refs` as it is resolved — the dead-code-elimination
//! graph of fast-compiler.md §9.1 is a byproduct, never a second pass.
//! Deduplication uses a stamp per declaration index (a dense id, so a
//! parallel array) for this module's names and a scan of the current
//! declaration's few import refs for the rest.
//!
//! `?`: each `e?` becomes a `try` instruction whose target is the nearest
//! enclosing definition with parameters (§6.6). A stack of "frames" —
//! declaration, `let` definition or lambda, each knowing whether it has
//! parameters — is walked outwards: a lambda before such a definition is
//! `question_in_lambda`; reaching the bottom is
//! `question_outside_function`.
//!
//! Memory: the Bir columns go to `gpa` (session-owned, see `Artifacts.zig`),
//! pre-sized from the tree; every scratch structure comes from the worker's
//! arena and is dropped by its reset.

const std = @import("std");
const lists = @import("../lists.zig");
const soa = @import("../soa.zig");
const U32Set = @import("../u32_set.zig").U32Set;
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const InternPool = @import("../InternPool.zig");
const Token = @import("../lex/Token.zig");
const Tokenizer = @import("../lex/Tokenizer.zig");
const Ast = @import("../parse/Ast.zig");
const Bir = @import("Bir.zig");
const Diagnostics = @import("Diagnostics.zig");
const prelude = @import("prelude.zig");
const markup_entities = @import("../markup/entities.zig");
const markup_text = @import("../markup/text.zig");

const Symbol = InternPool.Symbol;
const WellKnown = InternPool.WellKnown;
const Node = Ast.Node;
const NodeIndex = Node.Index;
const TokenIndex = Ast.TokenIndex;
const Inst = Bir.Inst;
const Index = Inst.Index;
const SubRange = Bir.SubRange;
const SymbolIndex = Bir.SymbolIndex;
const none_u32 = std.math.maxInt(u32);

const Lower = @This();

gpa: Allocator,
scratch_allocator: Allocator,
source: [:0]const u8,
tags: []const Token.Tag,
starts: []const u32,
payloads: []const u32,
tree: *const Ast,
interner: *InternPool.Local,
options: Options,

// ---- Output columns (gpa) ----
insts: Bir.InstList = .empty,
/// Appends to `insts` without recomputing its columns per instruction.
inst_appender: soa.Appender(Inst) = .{},
extra: std.ArrayList(u32) = .empty,
string_bytes: std.ArrayList(u8) = .empty,
symbols: std.ArrayList(Symbol) = .empty,
decls: std.ArrayList(Bir.Decl) = .empty,
ctors: std.ArrayList(Bir.Ctor) = .empty,
locals: std.ArrayList(Bir.Local) = .empty,
refs: std.ArrayList(Bir.Ref) = .empty,
imports: std.ArrayList(Bir.Import) = .empty,
exposed: std.ArrayList(Bir.Exposed) = .empty,
interface: std.ArrayList(Bir.DeclIndex) = .empty,
diagnostics: std.ArrayList(Diagnostics.Item) = .empty,

// ---- Scratch (arena) ----
/// Value namespace: top-level values and exposed lower names.
values: Symbol.Map(NameEntry) = .empty,
/// Constructor namespace: this file's constructors and exposed upper names.
ctor_names: Symbol.Map(NameEntry) = .empty,
/// Type namespace: this file's types and aliases and exposed upper names.
types: Symbol.Map(NameEntry) = .empty,
/// Schema namespace skeleton; resolution resolves members and imports.
schemas: Symbol.Map(NameEntry) = .empty,
/// The explicit imports by ALIAS, the first import to take an alias
/// keeping it (a duplicate alias is reported and resolves to the first),
/// and by MODULE, for `duplicate_import`. Every qualified reference asks
/// which import its prefix names; a scan of the import table per reference
/// would be O(imports × references).
import_by_alias: Symbol.Map(u32) = .empty,
import_by_module: Symbol.Map(u32) = .empty,
/// The current declaration's import edges by key, once it has more than
/// `indexed_refs` edges (`addRef`); `import_refs_start` is the
/// `cur_refs_start` of the declaration it indexes.
import_refs: std.AutoHashMapUnmanaged(ImportRefKey, void) = .empty,
import_refs_start: u32 = none_u32,
/// The lexical scope stack (frontend.md §3.6). Pushed by `bindLocal` and
/// popped by `popScope` only, which keep `scope_index` in step.
scope: std.ArrayList(ScopeEntry) = .empty,
/// The innermost scope entry of each name, while `scope_indexed`: set when
/// the scope grows past `indexed_scope` and dropped when it shrinks to half
/// of it.
scope_index: Symbol.Map(u32) = .empty,
scope_indexed: bool = false,
/// Enclosing definitions and lambdas, for `?` (§6.6).
frames: std.ArrayList(Frame) = .empty,
/// Where lists of children are gathered before they are copied to `extra`.
list_scratch: std.ArrayList(u32) = .empty,
/// The top-level items that became declarations, in order.
decl_sources: std.ArrayList(DeclSource) = .empty,
/// `decl_stamp[i] == cur_decl + 1` once declaration `i` is in the current
/// declaration's refs; likewise `ctor_stamp` per constructor.
decl_stamp: []u32 = &.{},
ctor_stamp: []u32 = &.{},
/// The type parameters of the declaration being lowered (tokens), or
/// null inside an annotation, where type variables are free (§7).
type_params: ?[]const TokenIndex = null,
/// `type_params` by name, first occurrence, when there are more than
/// `indexed_params` of them: a scan per type variable would be O(n²) in the
/// parameter count.
type_param_index: Symbol.Map(u32) = .empty,
/// The type variables already seen in the type expression being lowered,
/// for the "first occurrence" half of the `equatable` rule (checker.md
/// Appendix A). Cleared by `lowerRootType` per type expression, not per
/// declaration: two `let` annotations in one body are two annotations, and
/// each may mark its own `a`.
type_vars_seen: std.ArrayList(Symbol) = .empty,
/// The type variables of the declaration's own annotation, kept for the
/// whole of its body. `type_vars_seen` cannot serve: a `let` annotation or
/// a `where` constraint's type resets it. Read by `typeDispatchVar` for
/// trigger (2) of static-dispatch-spike.md §4.1 — `v.m` where `v` IS an
/// annotation variable and the declaration has no `where` clause at all,
/// which the checker then reports as `type_dispatch_needs_annotation`
/// (§10.8, A.5). Without it that trigger has no reachable path and the
/// diagnostic could never fire.
annotation_vars: std.ArrayList(Symbol) = .empty,

/// The names bound AFTER the `<-` whose right-hand side is being lowered
/// (§7): a reference to one of them is `bind_rhs_forward_reference`. Empty
/// everywhere else, and restored by the caller, so a nested `let` inside the
/// right-hand side sees its own bindings as locals first.
forward: []const Symbol = &.{},

/// The token every instruction appended right now is stamped with.
cur_token: TokenIndex = 0,
/// True while `lowerType` is inside a parameter of the arrow it started
/// from (an odd number of parameter positions deep): a function type there
/// is one the declaration RECEIVES, the only kind `sync` may mark
/// (transparent-effects-proposal.md §15.2).
receives: bool = false,
cur_decl: u32 = 0,
/// While lowering a `via` Atom, lexical locals resolve normally and every
/// nonlocal name stays as an unresolved schema-expression leaf for resolution.
in_schema_expr: bool = false,
/// An import of this file wrote Elm's `T(..)`. Its constructors
/// are unknown here — only the imported module's interface lists them —
/// so an unknown constructor is left quiet, as an error instruction, and
/// resolution's one `expected_token` names what to write instead.
exposes_all_ctors: bool = false,
cur_locals_start: u32 = 0,
cur_refs_start: u32 = 0,
cur_inst_start: u32 = 0,
/// Set by the first `markup` instruction (frontend.md §9.7).
uses_markup: bool = false,
/// Every `For` row and `Show` body lowered, for the captures and inputs
/// that `finishRows` computes once every declaration is lowered.
rows: std.ArrayList(PendingRow) = .empty,

pub const Options = struct {
    /// `--core`: the file is core, so `equatable` is legal (checker.md
    /// Appendix A). Core is also a platform package, so this implies
    /// `platform`.
    core: bool,
    /// The file is in a package that may write `foreign` (boundary.md §2):
    /// core, or a package whose manifest says `"platform": true`. Split
    /// from `core` because the two permissions are not the same one:
    /// anyone may publish a platform, and nobody but core may hand out
    /// `equatable`.
    platform: bool = false,
    /// The module's own name (`SourceStore.moduleName`), for `self_import`.
    module_name: []const u8,
};

const NameEntry = struct {
    kind: enum(u8) { top, exposed },
    /// `top`: the `DeclIndex` (values, types) or `CtorIndex`. `exposed`:
    /// the index of the import.
    index: u32,
    /// The declaring token, for the "first declared on line N" of a
    /// duplicate report.
    token: TokenIndex,
};

const ScopeEntry = struct {
    symbol: Symbol,
    local: u32,
    token: TokenIndex,
    /// The entry of the same name this one shadows, an index into `scope`,
    /// or `none_u32`. Kept while the scope is indexed (`scope_index`).
    prev: u32 = none_u32,
};

/// Past this many entries the scope is looked up by name (`scope_index`)
/// instead of scanned: a `let` binds all its names before any body is
/// lowered, so a block of n bindings would make every lookup and every
/// shadowing check a scan of n. Below it a scan is the cheaper of the two,
/// and it is what almost every scope is.
const indexed_scope = 64;

/// Past this many edges a declaration's import edges are deduplicated
/// through `import_refs` instead of a scan, for the reason
/// `indexed_scope` gives.
const indexed_refs = 64;

const ImportRefKey = struct {
    kind: Bir.Ref.Kind,
    module: Symbol,
    name: Symbol,
};

/// One binding of one `let` block, gathered by `lowerBindings` for §7's
/// initialisation rule and read by `checkLetOrder`. Annotations and `<-`
/// binds contribute none: an annotation binds nothing, and the block ends
/// at the first `<-` (§6.7).
const LetBinding = struct {
    /// The locals it binds, as declaration-relative indices. A `let_def`
    /// binds one; a `let_pattern` binds every variable of its pattern, and
    /// `let _ = e` binds none.
    local_start: u32,
    local_end: u32,
    /// Its right-hand side's instructions, which is where its references
    /// are. Contiguous, and a nested `let`'s lie inside it.
    inst_start: u32 = 0,
    inst_end: u32 = 0,
    /// A `let` FUNCTION: the backend emits it as a `function` declaration,
    /// which JavaScript hoists, so naming it above its own line is legal
    /// and mutual recursion between `let` functions works (§7).
    hoisted: bool,
    /// Evaluating its right-hand side runs nothing: a function, or a value
    /// whose right-hand side is a lambda (`g = \_ -> later`, `g = f a _`).
    /// Its body runs when something CALLS it instead.
    defers: bool = false,
};

/// A reference from one binding of a `let` block to a local that block
/// binds: `from` and `to` are indices into the block's `LetBinding` list.
const LetEdge = struct {
    from: u32,
    to: u32,
    /// The local referenced, for the name and line of the binding reported.
    local: u32,
    /// The token of the reference itself, which is the region.
    token: TokenIndex,
};

const Frame = struct {
    kind: Kind,
    /// The `let_def` instruction, or none for the declaration itself.
    inst: Inst.OptionalIndex,

    const Kind = enum(u8) { function, constant, lambda };

    fn definition(has_params: bool, inst: Inst.OptionalIndex) Frame {
        return .{ .kind = if (has_params) .function else .constant, .inst = inst };
    }
};

/// A row whose captures and inputs are still to be computed: they read the
/// summaries of functions declared anywhere in the file (frontend.md §9.7).
const PendingRow = struct {
    /// The `MarkupRow` record.
    row: Bir.ExtraIndex,
    decl: u32,
    /// The row function's instructions, `[first, function]`.
    first: u32,
    function: u32,
};

const DeclSource = struct {
    node: NodeIndex,
    /// For a definition with an annotation: the annotation node.
    annotation: Node.OptionalIndex,
};

/// Instructions, extra words and symbol slots per node. The three lists are
/// reserved at exactly these counts, so each is the most a real file needs
/// rather than the mean: measured over the generated 100k-line corpus,
/// bench/corpus and core, a file makes 0.91 instructions a node at the
/// median and 1.09 at most, 1.05 extra words at the median and 1.42 at
/// most, and 0.70 symbols at the median and 0.78 at the 99th percentile.
/// A file past an estimate grows that list once.
fn estimatedInstCount(nodes: usize) usize {
    return nodes * 9 / 8 + 16;
}

fn estimatedExtraCount(nodes: usize) usize {
    return nodes * 3 / 2 + 16;
}

fn estimatedSymbolCount(nodes: usize) usize {
    return nodes * 4 / 5 + 16;
}

/// Lower one file's tree. `gpa` owns the returned Bir; `scratch` (the
/// worker's arena) takes every temporary structure and is not referenced
/// by the result. `interner` must have been made by `InternPool.Local.init`
/// (the well-known prefix is how prelude names are recognised); it gains
/// the name parts of qualified references.
pub fn lower(
    gpa: Allocator,
    scratch: Allocator,
    source: [:0]const u8,
    tokens: Token.TokenList.Slice,
    tree: *const Ast,
    interner: *InternPool.Local,
    options: Options,
) Allocator.Error!Bir {
    std.debug.assert(interner.hasWellKnown());
    var l: Lower = .{
        .gpa = gpa,
        .scratch_allocator = scratch,
        .source = source,
        .tags = tokens.items(.tag),
        .starts = tokens.items(.start),
        .payloads = tokens.items(.payload),
        .tree = tree,
        .interner = interner,
        .options = options,
    };
    errdefer {
        l.insts.deinit(gpa);
        l.extra.deinit(gpa);
        l.string_bytes.deinit(gpa);
        l.symbols.deinit(gpa);
        l.decls.deinit(gpa);
        l.ctors.deinit(gpa);
        l.locals.deinit(gpa);
        l.refs.deinit(gpa);
        l.imports.deinit(gpa);
        l.exposed.deinit(gpa);
        l.interface.deinit(gpa);
        l.diagnostics.deinit(gpa);
    }
    // Free on an arena is a no-op; on a testing allocator it is the leak check.
    defer {
        l.values.deinit(scratch);
        l.ctor_names.deinit(scratch);
        l.types.deinit(scratch);
        l.schemas.deinit(scratch);
        l.import_by_alias.deinit(scratch);
        l.import_by_module.deinit(scratch);
        l.import_refs.deinit(scratch);
        l.scope.deinit(scratch);
        l.frames.deinit(scratch);
        l.list_scratch.deinit(scratch);
        l.decl_sources.deinit(scratch);
        l.type_vars_seen.deinit(scratch);
        l.type_param_index.deinit(scratch);
        l.annotation_vars.deinit(scratch);
        l.rows.deinit(scratch);
        scratch.free(l.decl_stamp);
        scratch.free(l.ctor_stamp);
    }

    const node_count = tree.nodes.len;
    try l.insts.setCapacity(gpa, estimatedInstCount(node_count));
    try l.extra.ensureTotalCapacityPrecise(gpa, estimatedExtraCount(node_count));
    try l.symbols.ensureTotalCapacityPrecise(gpa, estimatedSymbolCount(node_count));

    if (node_count > 0) {
        try l.lowerImports();
        try l.collectDeclarations();
        try l.lowerDeclarations();
        if (l.rows.items.len != 0) try l.finishRows();
    }

    var bir: Bir = .{
        .insts = l.insts.toOwnedSlice(),
        .extra = &.{},
        .string_bytes = &.{},
        .symbols = &.{},
        .decls = &.{},
        .ctors = &.{},
        .locals = &.{},
        .refs = &.{},
        .imports = &.{},
        .exposed = &.{},
        .interface = &.{},
        .diagnostics = &.{},
        .module_doc_start = tree.module_doc.start,
        .module_doc_end = tree.module_doc.end,
        .uses_markup = l.uses_markup,
    };
    errdefer bir.deinit(gpa);
    bir.extra = try l.extra.toOwnedSlice(gpa);
    bir.string_bytes = try l.string_bytes.toOwnedSlice(gpa);
    bir.symbols = try l.symbols.toOwnedSlice(gpa);
    bir.decls = try l.decls.toOwnedSlice(gpa);
    bir.ctors = try l.ctors.toOwnedSlice(gpa);
    bir.locals = try l.locals.toOwnedSlice(gpa);
    bir.refs = try l.refs.toOwnedSlice(gpa);
    bir.imports = try l.imports.toOwnedSlice(gpa);
    bir.exposed = try l.exposed.toOwnedSlice(gpa);
    bir.interface = try l.interface.toOwnedSlice(gpa);
    bir.diagnostics = try l.diagnostics.toOwnedSlice(gpa);
    return bir;
}

// ---------------------------------------------------------------------------
// Tokens and text
// ---------------------------------------------------------------------------

fn tokenText(l: *const Lower, token: TokenIndex) []const u8 {
    return Tokenizer.slice(l.source, l.tags[token], l.starts[token]);
}

fn tokenEnd(l: *const Lower, token: TokenIndex) u32 {
    return Tokenizer.tokenEnd(l.source, l.tags[token], l.starts[token]);
}

fn tokenSymbol(l: *const Lower, token: TokenIndex) Symbol {
    std.debug.assert(l.tags[token].isInterned());
    return @enumFromInt(l.payloads[token]);
}

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

/// Append an instruction, stamped with `cur_token` — the token the walker
/// currently stands on. Every `lower*` entry point sets it from the node it
/// was handed, so no call site has to thread a token through and no
/// instruction is left without a source position (see `Bir.Inst`).
fn addInst(l: *Lower, tag: Inst.Tag, lhs: u32, rhs: u32) Allocator.Error!Index {
    const i: u32 = @intCast(l.insts.len);
    try l.inst_appender.append(&l.insts, l.gpa, .{ .tag = tag, .main_token = l.cur_token, .data = .{ .lhs = lhs, .rhs = rhs } });
    return @enumFromInt(i);
}

/// Append an instruction stamped with `token` rather than with whatever
/// the last child left in `cur_token`. Every walker sets `cur_token` on
/// entry, so a LEAF is stamped right for free; a composite node has to say
/// so, because by the time it appends its own instruction its children
/// have moved `cur_token` on.
///
/// Why not save and restore around each node instead: the walkers recurse
/// once per level of nesting and the parser allows 4,096 (language.md
/// §10), so a `defer` and one extra local in `lowerExpr` is 4,096 of them
/// on the stack — enough, measured, to turn `r????…` from a diagnostic
/// into a segfault. `tests/blackbox/abuse_test.zig` holds that case.
fn addInstAt(l: *Lower, token: TokenIndex, tag: Inst.Tag, lhs: u32, rhs: u32) Allocator.Error!Index {
    l.cur_token = token;
    return l.addInst(tag, lhs, rhs);
}

/// An instruction whose data is filled in later (`let_def` needs its index
/// before its body is lowered, for `try` targets).
fn reserveInst(l: *Lower, tag: Inst.Tag) Allocator.Error!Index {
    return l.addInst(tag, 0, 0);
}

fn setInstData(l: *Lower, inst: Index, lhs: u32, rhs: u32) void {
    l.insts.items(.data)[inst.int()] = .{ .lhs = lhs, .rhs = rhs };
}

fn errorInst(l: *Lower, code: diagnostic.Code) Allocator.Error!Index {
    return l.addInst(.@"error", @intFromEnum(code), Inst.Data.unused);
}

fn addSymbol(l: *Lower, symbol: Symbol) Allocator.Error!SymbolIndex {
    const i: u32 = @intCast(l.symbols.items.len);
    try lists.push(Symbol, &l.symbols, l.gpa, symbol);
    return @enumFromInt(i);
}

fn addExtraWords(l: *Lower, words: []const u32) Allocator.Error!Bir.ExtraIndex {
    const i: u32 = @intCast(l.extra.items.len);
    try l.extra.appendSlice(l.gpa, words);
    return @enumFromInt(i);
}

/// Copy `items` into `extra` and return their range.
fn addRange(l: *Lower, items: []const u32) Allocator.Error!SubRange {
    const start = try l.addExtraWords(items);
    return .{ .start = start, .end = @enumFromInt(@intFromEnum(start) + items.len) };
}

/// Store a `SubRange` record itself in `extra`, for tags whose data holds
/// an `ExtraIndex` to a range.
fn addRangeRecord(l: *Lower, range: SubRange) Allocator.Error!Bir.ExtraIndex {
    return l.addExtraWords(&.{ @intFromEnum(range.start), @intFromEnum(range.end) });
}

fn addExtra(l: *Lower, record: anytype) Allocator.Error!Bir.ExtraIndex {
    const fields = std.meta.fields(@TypeOf(record));
    var words: [fields.len]u32 = undefined;
    inline for (fields, 0..) |field, i| {
        const v = @field(record, field.name);
        words[i] = switch (@typeInfo(field.type)) {
            .@"enum" => @intFromEnum(v),
            .int => v,
            else => @compileError("unexpected extra field type: " ++ @typeName(field.type)),
        };
    }
    return l.addExtraWords(&words);
}

fn addBytes(l: *Lower, bytes: []const u8) Allocator.Error!struct { u32, u32 } {
    const offset: u32 = @intCast(l.string_bytes.items.len);
    try l.string_bytes.appendSlice(l.gpa, bytes);
    return .{ offset, @intCast(bytes.len) };
}

fn scratchMark(l: *const Lower) usize {
    return l.list_scratch.items.len;
}

fn pushScratch(l: *Lower, value: anytype) Allocator.Error!void {
    const word: u32 = switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => @intFromEnum(value),
        .int => value,
        else => @compileError("unexpected scratch value type: " ++ @typeName(@TypeOf(value))),
    };
    try lists.push(u32, &l.list_scratch, l.scratch_allocator, word);
}

fn scratchSince(l: *const Lower, mark: usize) []const u32 {
    return l.list_scratch.items[mark..];
}

fn shrinkScratch(l: *Lower, mark: usize) void {
    l.list_scratch.shrinkRetainingCapacity(mark);
}

fn report(l: *Lower, code: diagnostic.Code, start: u32, end: u32) Allocator.Error!void {
    try l.diagnostics.append(l.gpa, .{ .code = code, .start = start, .end = end });
}

fn reportToken(l: *Lower, code: diagnostic.Code, token: TokenIndex) Allocator.Error!void {
    try l.report(code, l.starts[token], l.tokenEnd(token));
}

/// Report `code` at `token`, pointing at `other` as the earlier occurrence.
fn reportPair(l: *Lower, code: diagnostic.Code, token: TokenIndex, other: TokenIndex) Allocator.Error!void {
    try l.diagnostics.append(l.gpa, .{
        .code = code,
        .start = l.starts[token],
        .end = l.tokenEnd(token),
        .other_start = l.starts[other],
        .other_end = l.tokenEnd(other),
    });
}

/// Report `let_forward_reference` at `token` — the reference that runs too
/// soon — naming at `other` the binding of the same `let` it reaches (§7).
fn reportForward(
    l: *Lower,
    token: TokenIndex,
    other: TokenIndex,
    forward: Diagnostics.Item.Forward,
) Allocator.Error!void {
    try l.diagnostics.append(l.gpa, .{
        .code = .let_forward_reference,
        .start = l.starts[token],
        .end = l.tokenEnd(token),
        .other_start = l.starts[other],
        .other_end = l.tokenEnd(other),
        .forward = forward,
    });
}

fn addRef(l: *Lower, kind: Bir.Ref.Kind, a: u32, b: u32) Allocator.Error!void {
    const stamp = l.cur_decl + 1;
    switch (kind) {
        .top_value, .top_type, .top_schema => {
            if (l.decl_stamp[a] == stamp) return;
            l.decl_stamp[a] = stamp;
        },
        .top_ctor => {
            if (l.ctor_stamp[a] == stamp) return;
            l.ctor_stamp[a] = stamp;
        },
        .import_value, .import_ctor, .import_type, .import_schema => {
            // The module and name are compared as symbols, not as symbol
            // indices: each occurrence has its own slot in `symbols`.
            const ma = l.symbols.items[a];
            const na = l.symbols.items[b];
            const since = l.refs.items[l.cur_refs_start..];
            if (since.len <= indexed_refs) {
                for (since) |r| {
                    if (r.kind == kind and l.symbols.items[r.a] == ma and l.symbols.items[r.b] == na) return;
                }
            } else {
                // Past `indexed_refs` a declaration's import edges are
                // looked up by key rather than scanned: one declaration
                // naming n imported things would be n² here. The index
                // is built once per declaration that needs it, from the
                // edges it already has.
                if (l.import_refs_start != l.cur_refs_start) {
                    l.import_refs.clearAndFree(l.scratch_allocator);
                    for (since) |r| switch (r.kind) {
                        .import_value, .import_ctor, .import_type, .import_schema => try l.import_refs.put(l.scratch_allocator, .{
                            .kind = r.kind,
                            .module = l.symbols.items[r.a],
                            .name = l.symbols.items[r.b],
                        }, {}),
                        .top_value, .top_ctor, .top_type, .top_schema => {},
                    };
                    l.import_refs_start = l.cur_refs_start;
                }
                const gop = try l.import_refs.getOrPut(l.scratch_allocator, .{ .kind = kind, .module = ma, .name = na });
                if (gop.found_existing) return;
            }
        },
    }
    try l.refs.append(l.gpa, .{ .kind = kind, .a = a, .b = b });
}

/// A `(module, name)` reference instruction, with its dependency edge.
fn importRef(l: *Lower, tag: Inst.Tag, ref_kind: Bir.Ref.Kind, module: Symbol, name: Symbol) Allocator.Error!Index {
    const m = try l.addSymbol(module);
    const n = try l.addSymbol(name);
    try l.addRef(ref_kind, @intFromEnum(m), @intFromEnum(n));
    return l.addInst(tag, @intFromEnum(m), @intFromEnum(n));
}

/// `import_value(Basics, name)` for a core function reached by desugaring
/// rather than by an operator — negation, `?`. Fixed to `Basics` whatever
/// the file declares: these are syntax (§6.5), not names subject to
/// shadowing.
fn basicsRef(l: *Lower, name: WellKnown) Allocator.Error!Index {
    return l.importRef(.import_value, .import_value, WellKnown.Basics.symbol(), name.symbol());
}

/// `import_value(home, function)` for the core function an operator
/// desugars to, with the home module the operator's own (see
/// `operatorFunction`) rather than `Basics` for all of them.
fn operatorRef(l: *Lower, op: Token.Tag) Allocator.Error!Index {
    const f = operatorFunction(op);
    return l.importRef(.import_value, .import_value, f.module.symbol(), f.function.symbol());
}

// ---------------------------------------------------------------------------
// Imports
// ---------------------------------------------------------------------------

fn lowerImports(l: *Lower) Allocator.Error!void {
    for (l.tree.rootItems()) |item| {
        if (l.tree.nodeTag(item) != .import) continue;
        try l.lowerImport(item);
    }
    // The prelude modules as rows of their own (Appendix A), so the table
    // names every module this file resolves against. Their exposed lists
    // are the constant table in `prelude.zig`, not repeated here.
    for (prelude.modules) |w| {
        const s = try l.addSymbol(w.symbol());
        try l.imports.append(l.gpa, .{
            .module = s,
            .name_token = 0,
            .alias = s,
            .exposed_start = @intCast(l.exposed.items.len),
            .exposed_end = @intCast(l.exposed.items.len),
            .prelude = true,
        });
    }
}

fn lowerImport(l: *Lower, node: NodeIndex) Allocator.Error!void {
    const imp = l.tree.fullImport(node);
    const name_token = imp.name orelse return; // already a syntax error
    const module = l.tokenSymbol(name_token);
    const alias_token = imp.alias orelse name_token;
    const alias = l.tokenSymbol(alias_token);

    if (std.mem.eql(u8, l.tokenText(name_token), l.options.module_name)) {
        try l.reportToken(.self_import, name_token);
    }
    const import_index: u32 = @intCast(l.imports.items.len);
    const by_module = try l.import_by_module.getOrPut(l.scratch_allocator, module);
    if (by_module.found_existing) {
        try l.reportPair(.duplicate_import, name_token, l.importToken(by_module.value_ptr.*, .module));
        return;
    }
    by_module.value_ptr.* = import_index;
    const by_alias = try l.import_by_alias.getOrPut(l.scratch_allocator, alias);
    if (by_alias.found_existing) {
        try l.reportPair(.duplicate_import_alias, alias_token, l.importToken(by_alias.value_ptr.*, .alias));
    } else {
        by_alias.value_ptr.* = import_index;
    }

    const module_index = try l.addSymbol(module);
    const alias_index = if (imp.alias != null) try l.addSymbol(alias) else module_index;
    const exposed_start: u32 = @intCast(l.exposed.items.len);
    for (imp.exposed) |e| {
        if (l.tree.nodeTag(e) != .exposed) continue;
        const token = l.tree.nodeMainToken(e);
        const symbol = l.tokenSymbol(token);
        const all_ctors_token = l.tree.nodeData(e).lhs;
        if (all_ctors_token != 0) l.exposes_all_ctors = true;
        try l.exposed.append(l.gpa, .{ .name = try l.addSymbol(symbol), .token = token, .all_ctors_token = all_ctors_token });
        const entry: NameEntry = .{ .kind = .exposed, .index = import_index, .token = token };
        switch (l.tags[token]) {
            .lower_ident => try l.expose(&l.values, symbol, entry),
            .upper_ident => {
                // A type or a constructor — the file cannot tell (§5.2),
                // so the name is visible in both namespaces. Both tables
                // see the same duplicates, so only one reports.
                try l.expose(&l.ctor_names, symbol, entry);
                if (!l.types.contains(symbol)) try l.types.put(l.scratch_allocator, symbol, entry);
                if (!l.schemas.contains(symbol)) try l.schemas.put(l.scratch_allocator, symbol, entry);
            },
            else => {},
        }
    }
    try l.imports.append(l.gpa, .{
        .module = module_index,
        .name_token = name_token,
        .alias = alias_index,
        .exposed_start = exposed_start,
        .exposed_end = @intCast(l.exposed.items.len),
        .prelude = false,
    });
    try l.pushScratch(node);
}

/// Register an `exposing` name in `table`. The same name exposed twice in
/// one file — by two imports, or twice in one list — is
/// `duplicate_exposed_name` at the second occurrence (§5.2); the first
/// keeps the name, so uses resolve to one module.
fn expose(l: *Lower, table: *Symbol.Map(NameEntry), symbol: Symbol, entry: NameEntry) Allocator.Error!void {
    const gop = try table.getOrPut(l.scratch_allocator, symbol);
    if (gop.found_existing) {
        try l.reportPair(.duplicate_exposed_name, entry.token, gop.value_ptr.token);
        return;
    }
    gop.value_ptr.* = entry;
}

/// The module or alias token of the `i`th explicit import, found again
/// from its node (imports are few; nothing is stored per import for this).
fn importToken(l: *const Lower, i: usize, which: enum { module, alias }) TokenIndex {
    // `list_scratch` holds the import nodes in order while imports are
    // being lowered (nothing else uses it yet).
    const node: NodeIndex = @enumFromInt(l.list_scratch.items[i]);
    const imp = l.tree.fullImport(node);
    return switch (which) {
        .module => imp.name.?,
        .alias => imp.alias orelse imp.name.?,
    };
}

// ---------------------------------------------------------------------------
// Declarations: headers
// ---------------------------------------------------------------------------

fn collectDeclarations(l: *Lower) Allocator.Error!void {
    l.shrinkScratch(0);
    const items = l.tree.rootItems();
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const node = items[i];
        switch (l.tree.nodeTag(node)) {
            .import, .error_decl => {},
            .annotation => {
                // An annotation directly followed by the definition of the
                // same name is one declaration; the parser has already
                // reported the other case.
                const ann = l.tree.fullAnnotation(node);
                if (i + 1 < items.len and l.tree.nodeTag(items[i + 1]) == .definition and
                    l.tokenSymbol(l.tree.nodeMainToken(items[i + 1])) == l.tokenSymbol(ann.name))
                {
                    try l.declareValue(items[i + 1], node.toOptional());
                    i += 1;
                } else {
                    try l.declareValue(node, .none);
                }
            },
            .definition => try l.declareValue(node, .none),
            .foreign_value => try l.declareValue(node, .none),
            .type_alias, .type_decl, .foreign_type => try l.declareType(node),
            .schema_decl => try l.declareSchema(node),
            .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => try l.declareVocab(node),
            else => {}, // the parser puts only the kinds above at the root
        }
    }
    l.decl_stamp = try l.scratch_allocator.alloc(u32, l.decls.items.len);
    @memset(l.decl_stamp, 0);
    l.ctor_stamp = try l.scratch_allocator.alloc(u32, l.ctors.items.len);
    @memset(l.ctor_stamp, 0);
}

fn newDecl(l: *Lower, kind: Bir.Decl.Kind, name_token: TokenIndex, header: Ast.DeclHeader) Allocator.Error!u32 {
    return l.newDeclNamed(kind, l.tokenSymbol(name_token), name_token, header);
}

/// `newDecl` for a declaration whose name is not its token's symbol: a
/// vocabulary declaration's is the text of a string.
fn newDeclNamed(l: *Lower, kind: Bir.Decl.Kind, name: Symbol, name_token: TokenIndex, header: Ast.DeclHeader) Allocator.Error!u32 {
    const index: u32 = @intCast(l.decls.items.len);
    try l.decls.append(l.gpa, .{
        .kind = kind,
        .name = try l.addSymbol(name),
        .name_token = name_token,
        .is_pub = header.pub_token != .none,
        .is_opaque = header.opaque_token != .none,
        .is_equatable = header.equatable_token != .none,
        .doc_start = header.doc_start,
        .doc_end = header.doc_end,
        .params = 0,
        .params_start = @enumFromInt(0),
        .params_end = @enumFromInt(0),
        .type_params_start = 0,
        .type_params_end = 0,
        .annotation = .none,
        .where_start = @enumFromInt(0),
        .where_end = @enumFromInt(0),
        .body = .none,
        .schema_body = .none,
        .inst_start = @enumFromInt(0),
        .inst_end = @enumFromInt(0),
        .ctors_start = 0,
        .ctors_end = 0,
        .locals_start = 0,
        .locals_end = 0,
        .refs_start = 0,
        .refs_end = 0,
    });
    if (header.pub_token != .none) try l.interface.append(l.gpa, @enumFromInt(index));
    return index;
}

fn declareSchema(l: *Lower, node: NodeIndex) Allocator.Error!void {
    const d = l.tree.fullSchemaDecl(node);
    // The schema's generated interface names must already be in this file's Local
    // pool so the serial merge places them in Global before checker workers
    // and in-session interface round trips use the non-mutating `find` path.
    // `getOrPut` below may grow the interner's byte buffer, so retain an
    // owned copy rather than a slice which that growth can invalidate.
    const schema_name = try l.scratch_allocator.dupe(u8, l.interner.slice(l.tokenSymbol(d.name)));
    defer l.scratch_allocator.free(schema_name);
    for ([_][]const u8{ "Type", "Encoded", "schema", "parse", "print", "parseWith", "printWith" }) |member| {
        _ = try l.addSymbol(try l.interner.getOrPut(l.gpa, member));
    }
    for ([_][]const u8{ "Type", "Encoded" }) |endpoint| {
        const full = try std.fmt.allocPrint(l.scratch_allocator, "{s}.{s}", .{ schema_name, endpoint });
        defer l.scratch_allocator.free(full);
        _ = try l.addSymbol(try l.interner.getOrPut(l.gpa, full));
    }
    if (l.schemaTaggedNode(d.body)) |tagged_node| {
        for (l.tree.fullSchemaTagged(tagged_node).variants) |variant_node| {
            if (l.tree.nodeTag(variant_node) != .schema_variant) continue;
            const variant = l.tokenText(l.tree.fullSchemaVariant(variant_node).name);
            const program = try std.fmt.allocPrint(l.scratch_allocator, "{s}.{s}", .{ schema_name, variant });
            defer l.scratch_allocator.free(program);
            _ = try l.addSymbol(try l.interner.getOrPut(l.gpa, program));
            const encoded = try std.fmt.allocPrint(l.scratch_allocator, "{s}.Encoded.{s}", .{ schema_name, variant });
            defer l.scratch_allocator.free(encoded);
            _ = try l.addSymbol(try l.interner.getOrPut(l.gpa, encoded));
        }
    }
    for (d.params, 0..) |_, i| {
        var buf: [32]u8 = undefined;
        const encoded_name = if (i == 0) "e" else std.fmt.bufPrint(&buf, "e{d}", .{i + 1}) catch unreachable;
        _ = try l.addSymbol(try l.interner.getOrPut(l.gpa, encoded_name));
    }
    const index = try l.newDecl(.schema, d.name, d.header);
    try l.decl_sources.append(l.scratch_allocator, .{ .node = node, .annotation = .none });
    // A schema is deliberately absent from `values` and `types`: resolution
    // adds the separate namespace and resolves its members (schema.md §3).
    try l.declareName(&l.schemas, l.tokenSymbol(d.name), d.name, index, .duplicate_declaration, false);
}

/// A vocabulary declaration (language.md §11.14): legal only where
/// `foreign` is (`vocabulary_outside_platform`), named by its string's text
/// or, for a markup primitive, by its name, which is a value name and meets
/// the module's `duplicate_declaration`.
fn declareVocab(l: *Lower, node: NodeIndex) Allocator.Error!void {
    const v = l.tree.fullVocab(node);
    const kind: Bir.Decl.Kind = switch (l.tree.nodeTag(node)) {
        .vocab_element => .vocab_element,
        .vocab_attribute => .vocab_attribute,
        .vocab_event => .vocab_event,
        else => .vocab_markup,
    };
    const name: Symbol = if (v.name_string) |s| blk: {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(l.scratch_allocator);
        try l.stringText(s, &text);
        break :blk try l.interner.getOrPut(l.gpa, text.items);
    } else l.tokenSymbol(v.name);
    const index = try l.newDeclNamed(kind, name, v.name, v.header);
    try l.decl_sources.append(l.scratch_allocator, .{ .node = node, .annotation = .none });
    if (kind == .vocab_markup) try l.declareName(&l.values, name, v.name, index, .duplicate_declaration, true);
    if (!l.options.core and !l.options.platform) {
        const first = v.header.pub_token.unwrap() orelse v.word;
        const last = if (v.name_string) |s| l.stringEnd(l.tree.nodeMainToken(s)) else v.name;
        try l.report(.vocabulary_outside_platform, l.starts[first], l.tokenEnd(last));
    }
}

/// The `str_end` (or the token that cut the string off) of the one-line
/// string whose `str_start` is `start`.
fn stringEnd(l: *const Lower, start: TokenIndex) TokenIndex {
    var t = start;
    while (l.tags[t] != .str_end and l.tags[t] != .eof and !(l.tags[t] == .invalid and t != start and l.tokenEnd(t) == l.starts[t])) t += 1;
    return t;
}

/// The literal text of a string with its escapes decoded; an
/// interpolation's part is left out (the parser has reported one where a
/// name is written).
fn stringText(l: *Lower, node: NodeIndex, out: *std.ArrayList(u8)) Allocator.Error!void {
    for (l.tree.fullString(node).parts) |p| {
        if (l.tree.nodeTag(p) == .chunk) try decodeChunk(l.tokenText(l.tree.nodeMainToken(p)), l.scratch_allocator, out);
    }
}

/// A vocabulary declaration's facts as `VocabFact` records, one per word,
/// or per string of a word that takes several (`on "input" "select"`).
fn lowerFacts(l: *Lower, v: Ast.full.VocabDecl) Allocator.Error!SubRange {
    const start: u32 = @intCast(l.extra.items.len);
    var word: ?Bir.FactWord = null;
    var t = v.facts_start;
    while (t < v.facts_end) {
        switch (l.tags[t]) {
            .lower_ident => {
                // An unknown word is null; the parser has reported it.
                word = factWord(l.tokenText(t));
                t += 1;
                const fw = word orelse continue;
                if (fw == .via and t < v.facts_end and l.tags[t] == .lower_ident) {
                    _ = try l.addExtra(Bir.VocabFact{ .word = .via, .arg = try l.addSymbol(l.tokenSymbol(t)) });
                    t += 1;
                } else if (t >= v.facts_end or l.tags[t] != .str_start) {
                    _ = try l.addExtra(Bir.VocabFact{ .word = fw, .arg = .none });
                }
            },
            .str_start => {
                const end = l.stringEnd(t);
                var text: std.ArrayList(u8) = .empty;
                defer text.deinit(l.scratch_allocator);
                var c = t + 1;
                while (c < end) : (c += 1) {
                    if (l.tags[c] == .str_chunk) try decodeChunk(l.tokenText(c), l.scratch_allocator, &text);
                }
                if (word) |fw| _ = try l.addExtra(Bir.VocabFact{ .word = fw, .arg = try l.addSymbol(try l.interner.getOrPut(l.gpa, text.items)) });
                t = end + 1;
            },
            else => t += 1,
        }
    }
    return .{ .start = @enumFromInt(start), .end = @enumFromInt(l.extra.items.len) };
}

/// The fact a word spells, or null for a word the parser reported.
fn factWord(text: []const u8) ?Bir.FactWord {
    inline for (@typeInfo(Bir.FactWord).@"enum".fields) |f| {
        const w: Bir.FactWord = @enumFromInt(f.value);
        if (std.mem.eql(u8, w.spelling(), text)) return w;
    }
    return null;
}

fn schemaTaggedNode(l: *const Lower, root: NodeIndex) ?NodeIndex {
    var at = root;
    var budget = l.tree.nodes.len + 1;
    while (budget > 0) : (budget -= 1) switch (l.tree.nodeTag(at)) {
        .schema_tagged => return at,
        .schema_value => at = l.tree.fullSchemaField(at).operand,
        .schema_paren => at = l.tree.operand(at),
        else => return null,
    };
    return null;
}

/// Register `symbol` declared at `token` in `table`, reporting a duplicate
/// or a collision with an `exposing` name. The declaration always wins the
/// slot: resolving to it is the more useful outcome after the report.
fn declareName(l: *Lower, table: *Symbol.Map(NameEntry), symbol: Symbol, token: TokenIndex, index: u32, duplicate: diagnostic.Code, check_exposed: bool) Allocator.Error!void {
    const gop = try table.getOrPut(l.scratch_allocator, symbol);
    if (gop.found_existing) {
        switch (gop.value_ptr.kind) {
            .top => {
                try l.reportPair(duplicate, token, gop.value_ptr.token);
                return; // the first declaration keeps the name
            },
            .exposed => if (check_exposed) try l.reportPair(.shadows_import, token, gop.value_ptr.token),
        }
    }
    gop.value_ptr.* = .{ .kind = .top, .index = index, .token = token };
}

fn declareValue(l: *Lower, node: NodeIndex, annotation: Node.OptionalIndex) Allocator.Error!void {
    const tag = l.tree.nodeTag(node);
    const name_token = l.tree.nodeMainToken(node);
    var header = l.tree.declHeader(node);
    if (annotation.unwrap()) |ann| {
        // `pub` sits on the annotation (§3); take the doc block from it too.
        const ah = l.tree.declHeader(ann);
        if (ah.pub_token != .none) header.pub_token = ah.pub_token;
        if (ah.doc_end > ah.doc_start) {
            header.doc_start = ah.doc_start;
            header.doc_end = ah.doc_end;
        }
    }
    const kind: Bir.Decl.Kind = switch (tag) {
        .definition => .value,
        .annotation => .annotation_only,
        .foreign_value => .foreign_value,
        else => unreachable,
    };
    const index = try l.newDecl(kind, name_token, header);
    try l.decl_sources.append(l.scratch_allocator, .{ .node = node, .annotation = annotation });
    try l.declareName(&l.values, l.tokenSymbol(name_token), name_token, index, .duplicate_declaration, true);
    if (tag == .foreign_value) {
        // The rung is the lower identifier before the name, when the
        // parser found one there (transparent-effects-proposal.md §14.1);
        // `foreign` is then the token before it. A missing or unknown rung
        // was reported by the parser, and the declaration stays `pure`.
        const has_rung = l.tags[name_token - 1] == .lower_ident;
        if (has_rung) l.decls.items[index].rung = Bir.Rung.fromText(l.tokenText(name_token - 1)) orelse .pure;
        try l.checkForeign(header, name_token, if (has_rung) name_token - 2 else name_token - 1);
    }
}

fn declareType(l: *Lower, node: NodeIndex) Allocator.Error!void {
    const tag = l.tree.nodeTag(node);
    const name_token = l.tree.nodeMainToken(node);
    const header = l.tree.declHeader(node);
    const kind: Bir.Decl.Kind = switch (tag) {
        .type_alias => .type_alias,
        .type_decl => .type,
        .foreign_type => .foreign_type,
        else => unreachable,
    };
    const index = try l.newDecl(kind, name_token, header);
    try l.decl_sources.append(l.scratch_allocator, .{ .node = node, .annotation = .none });
    try l.declareName(&l.types, l.tokenSymbol(name_token), name_token, index, .duplicate_type, true);
    if (tag == .type_decl) {
        const d = l.tree.fullTypeDecl(node);
        l.decls.items[index].ctors_start = @intCast(l.ctors.items.len);
        for (d.ctors) |c| {
            if (l.tree.nodeTag(c) != .constructor) continue;
            const ctor_token = l.tree.nodeMainToken(c);
            const ctor_index: u32 = @intCast(l.ctors.items.len);
            try l.ctors.append(l.gpa, .{
                .name = try l.addSymbol(l.tokenSymbol(ctor_token)),
                .name_token = ctor_token,
                .decl = @enumFromInt(index),
                .args_start = @enumFromInt(0),
                .args_end = @enumFromInt(0),
            });
            // A constructor named like an exposed upper name hides it, as
            // a top-level name hides a prelude name: the exposed name is
            // most likely the type of the same name, already reported
            // once on the type if it collides.
            try l.declareName(&l.ctor_names, l.tokenSymbol(ctor_token), ctor_token, ctor_index, .duplicate_constructor, false);
        }
        l.decls.items[index].ctors_end = @intCast(l.ctors.items.len);
    }
    if (tag == .type_alias) {
        // A record alias declares a constructor of its own name, as in Elm
        // (§0: everything not listed is Elm's): `type alias User = { … }`
        // makes `User` a function of the fields in order. Its argument
        // types are filled in when the body is lowered.
        const ta = l.tree.fullTypeAlias(node);
        if (l.isRecordType(ta.body)) {
            l.decls.items[index].ctors_start = @intCast(l.ctors.items.len);
            const ctor_index: u32 = @intCast(l.ctors.items.len);
            try l.ctors.append(l.gpa, .{
                .name = try l.addSymbol(l.tokenSymbol(name_token)),
                .name_token = name_token,
                .decl = @enumFromInt(index),
                .args_start = @enumFromInt(0),
                .args_end = @enumFromInt(0),
            });
            try l.declareName(&l.ctor_names, l.tokenSymbol(name_token), name_token, ctor_index, .duplicate_constructor, false);
            l.decls.items[index].ctors_end = @intCast(l.ctors.items.len);
        }
    }
    if (tag == .foreign_type) {
        try l.checkForeign(header, name_token, name_token - 2);
        try l.checkEquatableMarker(header.equatable_token);
    }
}

/// True for `{ … }` (grouping parentheses looked through): the alias body
/// that makes a record constructor.
fn isRecordType(l: *const Lower, node: NodeIndex) bool {
    var n = node;
    while (l.tree.nodeTag(n) == .type_paren) n = l.tree.operand(n);
    return l.tree.nodeTag(n) == .type_record;
}

/// `equatable_outside_core` (checker.md Appendix A/B): the marker is the
/// one spelling in the language user code may not write, so outside the
/// core package it is reported wherever it appears — on a `foreign type`
/// here, on a type variable in `lowerTypeVar`.
fn checkEquatableMarker(l: *Lower, marker: Ast.OptionalTokenIndex) Allocator.Error!void {
    if (l.options.core) return;
    const token = marker.unwrap() orelse return;
    try l.reportToken(.equatable_outside_core, token);
}

/// `foreign_outside_platform` (§5.4), spanning from `pub` (or the `foreign`
/// keyword) to the name.
fn checkForeign(l: *Lower, header: Ast.DeclHeader, name_token: TokenIndex, keyword_token: TokenIndex) Allocator.Error!void {
    if (l.options.core or l.options.platform) return;
    const first = header.pub_token.unwrap() orelse keyword_token;
    try l.report(.foreign_outside_platform, l.starts[first], l.tokenEnd(name_token));
}

// ---------------------------------------------------------------------------
// Declarations: bodies
// ---------------------------------------------------------------------------

fn lowerDeclarations(l: *Lower) Allocator.Error!void {
    for (l.decl_sources.items, 0..) |src, i| {
        l.cur_decl = @intCast(i);
        l.cur_inst_start = @intCast(l.insts.len);
        l.cur_locals_start = @intCast(l.locals.items.len);
        l.cur_refs_start = @intCast(l.refs.items.len);
        std.debug.assert(l.scope.items.len == 0 and l.frames.items.len == 0);
        l.type_params = null;
        const d = &l.decls.items[i];
        d.inst_start = @enumFromInt(l.cur_inst_start);
        switch (l.tree.nodeTag(src.node)) {
            .definition => try l.lowerDefinition(src.node, src.annotation),
            .annotation => {
                const ann = l.tree.fullAnnotation(src.node);
                l.decls.items[i].annotation = (try l.lowerRootType(ann.type_expr)).toOptional();
                try l.lowerWhere(ann.header, ann.name);
            },
            .foreign_value => {
                const fv = l.tree.fullForeignValue(src.node);
                const annotation = try l.lowerRootType(fv.type_expr);
                l.decls.items[i].annotation = annotation.toOptional();
                // §3.6: a `foreign` has no definition to count parameters
                // from, so its `params` is what its ANNOTATION declares —
                // the same number `boundary.md` §4's check 4 measures the
                // sibling export against. Without it every reader of
                // `params` sees a nullary value, and `js/Lower.termArity`
                // eta-expanded `List.eq` used from inside `core/List.beni`
                // to `() => List$eq(m0)`.
                l.decls.items[i].params = l.typeFnArity(annotation);
                try l.lowerWhere(fv.header, fv.name);
            },
            .type_alias => {
                const ta = l.tree.fullTypeAlias(src.node);
                try l.lowerTypeParams(ta.params);
                const body = try l.lowerRootType(ta.body);
                l.decls.items[i].annotation = body.toOptional();
                if (d.ctors_end > d.ctors_start and l.insts.items(.tag)[body.int()] == .type_record) {
                    // The record constructor's arguments are the field
                    // types, in field order.
                    const mark = l.scratchMark();
                    defer l.shrinkScratch(mark);
                    const fields = Bir.inlineRange(l.insts.items(.data)[body.int()]);
                    var f = @intFromEnum(fields.start);
                    while (f < @intFromEnum(fields.end)) : (f += Bir.extraLen(Bir.Field)) {
                        try l.pushScratch(l.extra.items[f + 1]);
                    }
                    const range = try l.addRange(l.scratchSince(mark));
                    l.ctors.items[d.ctors_start].args_start = range.start;
                    l.ctors.items[d.ctors_start].args_end = range.end;
                }
            },
            .type_decl => {
                const td = l.tree.fullTypeDecl(src.node);
                try l.lowerTypeParams(td.params);
                var ctor_index = l.decls.items[i].ctors_start;
                for (td.ctors) |c| {
                    if (l.tree.nodeTag(c) != .constructor) continue;
                    const ctor = l.tree.fullConstructor(c);
                    const mark = l.scratchMark();
                    defer l.shrinkScratch(mark);
                    for (ctor.args) |arg| try l.pushScratch(try l.lowerRootType(arg));
                    const range = try l.addRange(l.scratchSince(mark));
                    l.ctors.items[ctor_index].args_start = range.start;
                    l.ctors.items[ctor_index].args_end = range.end;
                    ctor_index += 1;
                }
            },
            .foreign_type => {
                const ft = l.tree.fullForeignType(src.node);
                try l.lowerTypeParams(ft.params);
            },
            .schema_decl => {
                const schema = l.tree.fullSchemaDecl(src.node);
                try l.lowerTypeParams(schema.params);
                l.decls.items[i].schema_body = (try l.lowerSchema(schema.body)).toOptional();
            },
            .vocab_element, .vocab_attribute, .vocab_event, .vocab_markup => {
                const v = l.tree.fullVocab(src.node);
                const facts = try l.lowerFacts(v);
                l.decls.items[i].params_start = facts.start;
                l.decls.items[i].params_end = facts.end;
                if (v.type_expr) |te| l.decls.items[i].annotation = (try l.lowerRootType(te)).toOptional();
            },
            else => unreachable,
        }
        const done = &l.decls.items[i];
        done.inst_end = @enumFromInt(@as(u32, @intCast(l.insts.len)));
        done.locals_start = l.cur_locals_start;
        done.locals_end = @intCast(l.locals.items.len);
        done.refs_start = l.cur_refs_start;
        done.refs_end = @intCast(l.refs.items.len);
    }
}

/// The key `duplicate_where_constraint` is decided on: one constraint per
/// `(variable, method)` pair (§2.4).
const ConstraintKey = struct { variable: Symbol, method: Symbol };

/// The annotation's `where` clause (static-dispatch-spike.md §2.1, §2.4),
/// lowered right after the annotated type and stored on the declaration as
/// `(variable, method, type)` triples. `name_token` is the declared name,
/// whose `name_token + 2` is the first token of the annotated type.
///
/// Every well-formedness rule of §2.4 is checked here, where the clause is
/// stored, so all of them are pure functions of the file (§8):
///
///   - the constrained variable occurs in the annotated type, else
///     `where_variable_unbound` (§10.6 trigger (a));
///   - every variable inside a constraint's TYPE occurs in the annotated
///     type — the closure rule — else `where_variable_unbound` (trigger
///     (b)). It is load-bearing and not tidiness: a scheme's quantifiers
///     are discovered by walking its body, so a variable that occurs only
///     in a constraint has no index in the canonical evidence order and
///     caller and callee would disagree about the evidence list in silence
///     (Appendix A.21);
///   - no two constraints share a `(variable, method)` pair, else
///     `duplicate_where_constraint` (§10.7).
///
/// The annotated type's variables are exactly `type_vars_seen`: it was
/// cleared by `lowerRootType` and only that type has been lowered since.
fn lowerWhere(l: *Lower, header: Ast.DeclHeader, name_token: TokenIndex) Allocator.Error!void {
    const constraints = l.tree.whereConstraints(header);
    if (constraints.len == 0) return;
    // The annotated type's variables, kept as a set of their own: the
    // constraint types lowered below get a SCOPE of their own for the
    // `equatable` marker, so `type_vars_seen` cannot double as this.
    const annotation_set = try l.scratch_allocator.dupe(Symbol, l.type_vars_seen.items);
    defer l.scratch_allocator.free(annotation_set);
    // The annotated type as source bytes, for the two messages of §10.6:
    // from the token after the `:` to the token before the `where`, which
    // is the one before the FIRST WELL-FORMED constraint's variable. A
    // clause whose every constraint is an error placeholder is already
    // reported and has nothing to store.
    var first_constraint: ?Ast.full.WhereConstraint = null;
    for (constraints) |node| {
        if (l.tree.nodeTag(node) != .where_constraint) continue;
        first_constraint = l.tree.fullWhereConstraint(node);
        break;
    }
    const first = (first_constraint orelse return).variable;
    const annotated: struct { u32, u32 } = .{ l.starts[name_token + 2], l.tokenEnd(first - 2) };

    // `(variable, method)` pairs already seen, for `duplicate_where_constraint`:
    // a map and not a scan, because a generated file may carry thousands of
    // constraints and the scan made that quadratic.
    var seen: std.AutoHashMapUnmanaged(ConstraintKey, TokenIndex) = .empty;
    defer seen.deinit(l.scratch_allocator);
    var reported: std.ArrayList(Symbol) = .empty;
    defer reported.deinit(l.scratch_allocator);
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (constraints) |node| {
        // A constraint the parser could not build is already reported.
        if (l.tree.nodeTag(node) != .where_constraint) continue;
        const c = l.tree.fullWhereConstraint(node);
        const variable = l.tokenSymbol(c.variable);
        const method = l.tokenSymbol(c.method);
        if (std.mem.indexOfScalar(Symbol, annotation_set, variable) == null) {
            try l.diagnostics.append(l.gpa, .{
                .code = .where_variable_unbound,
                .start = l.starts[c.variable],
                .end = l.tokenEnd(c.variable),
                .other_start = annotated[0],
                .other_end = annotated[1],
            });
            // One mistake, one message: the same variable inside the
            // constraint's own type is the SAME mistake, not the closure
            // rule, so trigger (b) stays quiet about it.
            if (std.mem.indexOfScalar(Symbol, reported.items, variable) == null) {
                try reported.append(l.scratch_allocator, variable);
            }
        }
        const duplicate = try seen.getOrPut(l.scratch_allocator, .{ .variable = variable, .method = method });
        if (duplicate.found_existing) {
            const earlier = duplicate.value_ptr.*;
            try l.diagnostics.append(l.gpa, .{
                .code = .duplicate_where_constraint,
                .start = l.starts[c.variable],
                .end = l.tokenEnd(c.method),
                .other_start = l.starts[earlier],
                .other_end = l.tokenEnd(earlier + 1),
            });
        } else {
            duplicate.value_ptr.* = c.variable;
        }
        const type_start: u32 = @intCast(l.insts.len);
        // A constraint's type is its own scope for the `equatable` marker
        // (checker.md Appendix A), which is legal at a variable's FIRST
        // occurrence: the annotation's occurrences are not the clause's,
        // and one constraint's are not the next one's. Without the reset,
        // `where a.compare : equatable a, a -> Order` — core's own
        // spelling — is `equatable_not_first_occurrence`.
        l.type_vars_seen.clearRetainingCapacity();
        const type_inst = try l.lowerType(c.type_expr);
        // The closure rule, read off the instructions the type just made:
        // its `type_var`s are contiguous in that range and each carries the
        // token of the occurrence, which is where the message points.
        var j = type_start;
        while (j < l.insts.len) : (j += 1) {
            if (l.insts.items(.tag)[j] != .type_var) continue;
            const symbol = l.symbols.items[l.insts.items(.data)[j].lhs];
            if (std.mem.indexOfScalar(Symbol, annotation_set, symbol) != null) continue;
            if (std.mem.indexOfScalar(Symbol, reported.items, symbol) != null) continue;
            try reported.append(l.scratch_allocator, symbol);
            const token = l.insts.items(.main_token)[j];
            try l.diagnostics.append(l.gpa, .{
                .code = .where_variable_unbound,
                .start = l.starts[token],
                .end = l.tokenEnd(token),
                .other_start = annotated[0],
                .other_end = annotated[1],
                .inside_constraint = true,
            });
        }
        try l.pushScratch(@intFromEnum(try l.addSymbol(variable)));
        try l.pushScratch(@intFromEnum(try l.addSymbol(method)));
        try l.pushScratch(type_inst.int());
    }
    // Leave the annotation's variables where the caller found them.
    l.type_vars_seen.clearRetainingCapacity();
    try l.type_vars_seen.appendSlice(l.scratch_allocator, annotation_set);
    const range = try l.addRange(l.scratchSince(mark));
    const d = &l.decls.items[l.cur_decl];
    d.where_start = range.start;
    d.where_end = range.end;
}

// ---------------------------------------------------------------------------
// Unresolved schema plans (schema.md §4)
// ---------------------------------------------------------------------------

fn lowerSchema(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const tag = l.tree.nodeTag(node);
    const main = l.tree.nodeMainToken(node);
    l.cur_token = main;
    switch (tag) {
        .schema_operand => {
            const name = try l.addSymbol(l.tokenSymbol(main));
            const head = try l.addInst(.schema_ref, @intFromEnum(name), 0);
            const args = l.tree.children(node);
            if (args.len == 0) return head;
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (args) |arg| try l.pushScratch(try l.lowerSchema(arg));
            const range = try l.addRangeRecord(try l.addRange(l.scratchSince(mark)));
            return l.addInstAt(main, .schema_app, head.int(), @intFromEnum(range));
        },
        .schema_paren => {
            const child = try l.lowerSchema(l.tree.operand(node));
            return l.addInstAt(main, .schema_paren, child.int(), 0);
        },
        .schema_record => {
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (l.tree.children(node)) |field| {
                if (l.tree.nodeTag(field) != .schema_field) continue;
                try l.pushScratch(try l.lowerSchema(field));
            }
            const range = try l.addRange(l.scratchSince(mark));
            return l.addInstAt(main, .schema_record, @intFromEnum(range.start), @intFromEnum(range.end));
        },
        .schema_field, .schema_value => {
            const field = l.tree.fullSchemaField(node);
            const operand = try l.lowerSchema(field.operand);
            const modifiers = try l.lowerSchemaModifiers(field.modifiers);
            if (tag == .schema_value) {
                const range = try l.addRangeRecord(modifiers);
                return l.addInstAt(main, .schema_value, operand.int(), @intFromEnum(range));
            }
            const name = try l.addSymbol(l.tokenSymbol(field.name));
            const extra = try l.addExtra(Bir.SchemaField{
                .operand = operand,
                .modifiers_start = modifiers.start,
                .modifiers_end = modifiers.end,
                .doc_start = field.header.doc_start,
                .doc_end = field.header.doc_end,
            });
            return l.addInstAt(main, .schema_field, @intFromEnum(name), @intFromEnum(extra));
        },
        .schema_tagged => {
            const tagged = l.tree.fullSchemaTagged(node);
            const discriminator = try l.lowerSchemaString(tagged.discriminator);
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (tagged.variants) |variant| try l.pushScratch(try l.lowerSchema(variant));
            const range = try l.addRangeRecord(try l.addRange(l.scratchSince(mark)));
            return l.addInstAt(main, .schema_tagged, discriminator.int(), @intFromEnum(range));
        },
        .schema_variant => {
            const variant = l.tree.fullSchemaVariant(node);
            const payload = if (variant.payload) |p| (try l.lowerSchema(p)).toOptional() else Inst.OptionalIndex.none;
            const rename = if (variant.rename) |r| (try l.lowerSchemaString(r)).toOptional() else Inst.OptionalIndex.none;
            const name = try l.addSymbol(l.tokenSymbol(variant.name));
            const extra = try l.addExtra(Bir.SchemaVariant{ .payload = payload, .rename = rename });
            return l.addInstAt(main, .schema_variant, @intFromEnum(name), @intFromEnum(extra));
        },
        .schema_as => {
            const value = try l.lowerSchemaString(l.tree.operand(node));
            return l.addInstAt(main, .schema_as, value.int(), 0);
        },
        .schema_via => {
            const saved = l.in_schema_expr;
            l.in_schema_expr = true;
            defer l.in_schema_expr = saved;
            const value = try l.lowerExpr(l.tree.operand(node));
            return l.addInstAt(main, .schema_via, value.int(), 0);
        },
        .schema_optional => return l.addInst(.schema_optional, 0, 0),
        .schema_nullable => return l.addInst(.schema_nullable, 0, 0),
        else => {
            std.debug.assert(tag.isError());
            return l.errorInst(l.tree.fullError(node).code);
        },
    }
}

fn lowerSchemaString(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    if (l.tree.nodeTag(node) == .string) {
        const string = l.tree.fullString(node);
        for (string.parts) |part| {
            // parseSchemaString already reported interpolation. Do not lower
            // its expressions as ordinary values and cascade name errors.
            if (l.tree.nodeTag(part) == .interp) return l.errorInst(.unexpected_token);
        }
        return l.lowerString(node);
    }
    if (l.tree.nodeTag(node).isError()) return l.errorInst(l.tree.fullError(node).code);
    return l.errorInst(.expected_token);
}

fn lowerSchemaModifiers(l: *Lower, modifiers: []const NodeIndex) Allocator.Error!SubRange {
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    var first: [4]?TokenIndex = @splat(null);
    for (modifiers) |modifier| {
        const tag = l.tree.nodeTag(modifier);
        const slot: usize = switch (tag) {
            .schema_as => 0,
            .schema_via => 1,
            .schema_optional => 2,
            .schema_nullable => 3,
            else => continue,
        };
        const token = l.tree.nodeMainToken(modifier);
        if (first[slot]) |earlier| try l.reportPair(.duplicate_schema_modifier, token, earlier) else first[slot] = token;
        try l.pushScratch(try l.lowerSchema(modifier));
    }
    return l.addRange(l.scratchSince(mark));
}

/// Type parameters of a `type`, `type alias`, `foreign type` or `schema`: recorded
/// on the declaration, checked for duplicates (§7), and made the scope of
/// the body's type variables.
///
/// **More than `Interface.max_type_params` is refused** at the first one
/// past it (`too_many_type_parameters`, `checker-v2.md` §14.2): an arity is
/// a `u16` in the interface record. The declaration keeps its first 65 535,
/// so nothing downstream sees a width it cannot record; a body naming a
/// dropped one is then an `unbound_type_variable` too, after the error that
/// explains it.
///
/// Duplicates are found by sorting a copy, not by comparing every pair: the
/// pairwise scan was O(n²) in the parameter count, 35 s of a Debug build for
/// 65 536 of them. Each duplicate is still reported against the FIRST
/// earlier occurrence of its name, in parameter order.
fn lowerTypeParams(l: *Lower, all_params: []const TokenIndex) Allocator.Error!void {
    const limit = Bir.max_type_params;
    if (all_params.len > limit) try l.reportToken(.too_many_type_parameters, all_params[limit]);
    const params = all_params[0..@min(all_params.len, limit)];
    const d = &l.decls.items[l.cur_decl];
    d.type_params_start = @intCast(l.symbols.items.len);
    for (params) |p| _ = try l.addSymbol(l.tokenSymbol(p));
    d.type_params_end = @intCast(l.symbols.items.len);
    d.params = @intCast(params.len);
    l.type_params = params;
    l.type_param_index.clearRetainingCapacity();
    if (params.len > indexed_params) {
        try l.type_param_index.ensureTotalCapacity(l.scratch_allocator, @intCast(params.len));
        for (params, 0..) |p, i| {
            const gop = l.type_param_index.getOrPutAssumeCapacity(l.tokenSymbol(p));
            if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
        }
    }
    if (params.len < 2) return;

    // `order` sorted by (symbol, position): each run of one name starts at
    // its first occurrence.
    const order = try l.scratch_allocator.alloc(u32, params.len);
    defer l.scratch_allocator.free(order);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    const Cx = struct {
        l: *const Lower,
        params: []const TokenIndex,
        fn lessThan(cx: @This(), a: u32, b: u32) bool {
            const sa = @intFromEnum(cx.l.tokenSymbol(cx.params[a]));
            const sb = @intFromEnum(cx.l.tokenSymbol(cx.params[b]));
            return sa < sb or (sa == sb and a < b);
        }
    };
    std.mem.sort(u32, order, Cx{ .l = l, .params = params }, Cx.lessThan);
    // `first[i]` is the first occurrence of parameter `i`'s name.
    const first = try l.scratch_allocator.alloc(u32, params.len);
    defer l.scratch_allocator.free(first);
    var run_start: usize = 0;
    for (order, 0..) |at, k| {
        if (k != 0 and l.tokenSymbol(params[at]) != l.tokenSymbol(params[order[run_start]])) run_start = k;
        first[at] = order[run_start];
    }
    for (params, first, 0..) |p, earlier, i| {
        if (earlier != i) try l.reportPair(.duplicate_type_parameter, p, params[earlier]);
    }
}

fn lowerDefinition(l: *Lower, node: NodeIndex, annotation: Node.OptionalIndex) Allocator.Error!void {
    const def = l.tree.fullDefinition(node);
    l.annotation_vars.clearRetainingCapacity();
    if (annotation.unwrap()) |ann| {
        const a = l.tree.fullAnnotation(ann);
        l.decls.items[l.cur_decl].annotation = (try l.lowerRootType(a.type_expr)).toOptional();
        try l.annotation_vars.appendSlice(l.scratch_allocator, l.type_vars_seen.items);
        try l.lowerWhere(a.header, a.name);
    }
    const params = try l.lowerParams(def.params);
    try l.frames.append(l.scratch_allocator, Frame.definition(def.params.len > 0, .none));
    const body = try l.lowerExpr(def.body);
    _ = l.frames.pop();
    l.popScope(0);
    const d = &l.decls.items[l.cur_decl];
    d.params = @intCast(def.params.len);
    d.params_start = params.start;
    d.params_end = params.end;
    d.body = body.toOptional();
}

/// Lower the parameter patterns of a definition, `let` function or lambda
/// as one pattern set (duplicates across parameters are
/// `duplicate_pattern_variable`, as in `g a a`), binding their variables
/// into the current scope. Returns the range of pattern instructions.
fn lowerParams(l: *Lower, params: []const NodeIndex) Allocator.Error!SubRange {
    const set_start = l.scope.items.len;
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (params) |p| try l.pushScratch(try l.lowerPattern(p, set_start, .param));
    return l.addRange(l.scratchSince(mark));
}

// ---------------------------------------------------------------------------
// Scopes and resolution
// ---------------------------------------------------------------------------

/// Bind `token`'s name as a new local of `kind`, checking the rules of §7:
/// twice in one pattern set (`scope[set_start..]`) is
/// `duplicate_pattern_variable`; any enclosing local, top-level value,
/// `exposing` name or prelude value is `shadowing`. The binding is made
/// either way, so later uses resolve and one mistake yields one report.
fn bindVar(l: *Lower, token: TokenIndex, set_start: usize, kind: Bir.Local.Kind, inst: Index) Allocator.Error!u32 {
    const symbol = l.tokenSymbol(token);
    check: {
        if (l.scope_indexed) {
            // The same answers as the scans below, off the name's chain:
            // the EARLIEST entry of this pattern set, else the innermost
            // entry outside it.
            if (l.scope_index.get(symbol)) |latest| {
                var at = latest;
                if (at >= set_start) {
                    while (l.scope.items[at].prev != none_u32 and l.scope.items[at].prev >= set_start) at = l.scope.items[at].prev;
                    try l.reportPair(.duplicate_pattern_variable, token, l.scope.items[at].token);
                } else {
                    try l.reportPair(.shadowing, token, l.scope.items[at].token);
                }
                break :check;
            }
        } else for (l.scope.items[set_start..]) |entry| {
            if (entry.symbol == symbol) {
                try l.reportPair(.duplicate_pattern_variable, token, entry.token);
                break :check;
            }
        }
        if (!l.scope_indexed) {
            var i = set_start;
            while (i > 0) {
                i -= 1;
                const entry = l.scope.items[i];
                if (entry.symbol == symbol) {
                    try l.reportPair(.shadowing, token, entry.token);
                    break :check;
                }
            }
        }
        if (l.values.get(symbol)) |entry| {
            try l.reportPair(.shadowing, token, entry.token);
            break :check;
        }
        if (prelude.wellKnown(symbol)) |w| {
            if (prelude.valueModule(w) != null) try l.reportToken(.shadowing, token);
        }
    }
    return l.bindLocal(symbol.toOptional(), token, kind, inst);
}

/// Push a local without checks (`bindVar` does them; fresh locals need
/// none). Returns its index within the declaration.
fn bindLocal(l: *Lower, symbol: Symbol.Optional, token: TokenIndex, kind: Bir.Local.Kind, inst: Index) Allocator.Error!u32 {
    const index: u32 = @intCast(l.locals.items.len - l.cur_locals_start);
    try l.locals.append(l.gpa, .{
        .name = if (symbol.unwrap()) |s| try l.addSymbol(s) else .none,
        .kind = kind,
        .inst = inst,
    });
    if (symbol.unwrap()) |s| try l.pushScope(.{ .symbol = s, .local = index, .token = token });
    return index;
}

fn pushScope(l: *Lower, entry: ScopeEntry) Allocator.Error!void {
    const at: u32 = @intCast(l.scope.items.len);
    try l.scope.append(l.scratch_allocator, entry);
    if (l.scope_indexed) return l.indexScopeEntry(at);
    if (l.scope.items.len > indexed_scope) {
        l.scope_index.clearRetainingCapacity();
        for (0..l.scope.items.len) |i| try l.indexScopeEntry(@intCast(i));
        l.scope_indexed = true;
    }
}

fn indexScopeEntry(l: *Lower, at: u32) Allocator.Error!void {
    const gop = try l.scope_index.getOrPut(l.scratch_allocator, l.scope.items[at].symbol);
    l.scope.items[at].prev = if (gop.found_existing) gop.value_ptr.* else none_u32;
    gop.value_ptr.* = at;
}

/// Leave every scope entry above `mark`, restoring each name's innermost
/// entry in the index.
fn popScope(l: *Lower, mark: usize) void {
    if (l.scope_indexed) {
        var i = l.scope.items.len;
        while (i > mark) {
            i -= 1;
            const e = l.scope.items[i];
            if (e.prev == none_u32) {
                _ = l.scope_index.remove(e.symbol);
            } else {
                l.scope_index.getPtr(e.symbol).?.* = e.prev;
            }
        }
        if (mark <= indexed_scope / 2) {
            l.scope_index.clearRetainingCapacity();
            l.scope_indexed = false;
        }
    }
    l.scope.shrinkRetainingCapacity(mark);
}

/// The index the next local of this declaration will get.
fn nextLocal(l: *const Lower) u32 {
    return @intCast(l.locals.items.len - l.cur_locals_start);
}

/// A compiler-made local for a desugared lambda: no name, no scope entry.
fn freshLocal(l: *Lower, inst: Index) Allocator.Error!u32 {
    return l.bindLocal(.none, 0, .fresh, inst);
}

fn lookupLocal(l: *const Lower, symbol: Symbol) ?u32 {
    if (l.scope_indexed) {
        const at = l.scope_index.get(symbol) orelse return null;
        return l.scope.items[at].local;
    }
    var i = l.scope.items.len;
    while (i > 0) {
        i -= 1;
        if (l.scope.items[i].symbol == symbol) return l.scope.items[i].local;
    }
    return null;
}

/// An unqualified lower name in expression position (§6.2): local, then
/// top-level, then `exposing`, then prelude.
fn resolveValue(l: *Lower, token: TokenIndex) Allocator.Error!Index {
    l.cur_token = token;
    const symbol = l.tokenSymbol(token);
    if (l.lookupLocal(symbol)) |local| return l.addInst(.local, local, Inst.Data.unused);
    for (l.forward) |name| {
        if (name == symbol) {
            @branchHint(.cold);
            try l.reportToken(.bind_rhs_forward_reference, token);
            return l.errorInst(.bind_rhs_forward_reference);
        }
    }
    if (l.values.get(symbol)) |entry| switch (entry.kind) {
        .top => {
            try l.addRef(.top_value, entry.index, 0);
            return l.addInst(.top, entry.index, Inst.Data.unused);
        },
        .exposed => return l.importRef(.import_value, .import_value, l.importModule(entry.index), symbol),
    };
    if (prelude.wellKnown(symbol)) |w| {
        if (prelude.valueModule(w)) |m| return l.importRef(.import_value, .import_value, m.symbol(), symbol);
    }
    if (l.in_schema_expr) {
        const name = try l.addSymbol(symbol);
        return l.addInst(.schema_expr_ref, @intFromEnum(name), 0);
    }
    try l.reportToken(.unbound_variable, token);
    return l.errorInst(.unbound_variable);
}

/// An unqualified upper name in expression or pattern position (§6.2).
fn resolveCtor(l: *Lower, token: TokenIndex) Allocator.Error!Index {
    l.cur_token = token;
    const symbol = l.tokenSymbol(token);
    if (l.ctor_names.get(symbol)) |entry| switch (entry.kind) {
        .top => {
            try l.addRef(.top_ctor, entry.index, 0);
            return l.addInst(.ctor, entry.index, Inst.Data.unused);
        },
        .exposed => return l.importRef(.import_ctor, .import_ctor, l.importModule(entry.index), symbol),
    };
    if (prelude.wellKnown(symbol)) |w| {
        if (prelude.ctorModule(w)) |m| return l.importRef(.import_ctor, .import_ctor, m.symbol(), symbol);
    }
    if (l.schemas.contains(symbol)) return l.schemaNamespaceRef(token, .schema_value_ref);
    if (l.in_schema_expr) {
        const name = try l.addSymbol(symbol);
        return l.addInst(.schema_expr_ref, @intFromEnum(name), 0);
    }
    if (!l.exposes_all_ctors) try l.reportToken(.unbound_constructor, token);
    return l.errorInst(.unbound_constructor);
}

fn schemaExprRef(l: *Lower, token: TokenIndex) Allocator.Error!Index {
    l.cur_token = token;
    const name = try l.addSymbol(l.tokenSymbol(token));
    return l.addInst(.schema_expr_ref, @intFromEnum(name), 0);
}

/// Keep a possibly schema-qualified spelling whole until imported interfaces
/// exist. Record the dependency edge now, while import aliases and local
/// declaration indices are still available.
fn schemaNamespaceRef(l: *Lower, token: TokenIndex, tag: Inst.Tag) Allocator.Error!Index {
    l.cur_token = token;
    const text = l.tokenText(token);
    const first_dot = std.mem.indexOfScalar(u8, text, '.') orelse text.len;
    const root = try l.interner.getOrPut(l.gpa, text[0..first_dot]);
    _ = try l.addSymbol(root);
    if (std.mem.lastIndexOfScalar(u8, text, '.')) |last_dot| {
        _ = try l.addSymbol(try l.interner.getOrPut(l.gpa, text[0..last_dot]));
        _ = try l.addSymbol(try l.interner.getOrPut(l.gpa, text[last_dot + 1 ..]));
    }
    if (l.schemas.get(root)) |entry| switch (entry.kind) {
        .top => try l.addRef(.top_schema, entry.index, 0),
        .exposed => {
            const module = l.importModule(entry.index);
            const m = try l.addSymbol(module);
            const n = try l.addSymbol(root);
            try l.addRef(.import_schema, @intFromEnum(m), @intFromEnum(n));
        },
    };
    if (first_dot < text.len) {
        // The LONGEST explicit alias that is a prefix of `text` ending at a
        // dot with a further dot after it: `text` cut at each such dot,
        // longest first (a probe per dot, not a scan per import).
        var best_len: usize = 0;
        var best_module: ?Symbol = null;
        const last_dot = std.mem.lastIndexOfScalar(u8, text, '.').?;
        var cut = last_dot;
        while (std.mem.lastIndexOfScalar(u8, text[0..cut], '.')) |at| : (cut = at) {
            if (l.importWithAlias(text[0..at])) |i| {
                best_len = at;
                best_module = l.importModule(i);
                break;
            }
        }
        if (best_module) |module| {
            const tail = text[best_len + 1 ..];
            const dot = std.mem.indexOfScalar(u8, tail, '.').?;
            const schema = try l.interner.getOrPut(l.gpa, tail[0..dot]);
            const m = try l.addSymbol(module);
            const n = try l.addSymbol(schema);
            try l.addRef(.import_schema, @intFromEnum(m), @intFromEnum(n));
        }
    }
    const whole = try l.addSymbol(l.tokenSymbol(token));
    return l.addInst(tag, @intFromEnum(whole), 0);
}

/// Whether a qualified spelling needs the schema namespace resolver.  An
/// exact `Alias.member` keeps the ordinary fast path unless the alias also
/// collides with a schema root.  A longer `Alias.Schema.member` cannot be an
/// ordinary module access and is deferred once its imported prefix is known.
fn couldBeSchemaQualified(l: *const Lower, token: TokenIndex) bool {
    const text = l.tokenText(token);
    const first_dot = std.mem.indexOfScalar(u8, text, '.') orelse return false;
    const last_dot = std.mem.lastIndexOfScalar(u8, text, '.').?;
    // Each question is a probe per DOT of the token, never a scan of the
    // schema table or the import table: an alias that is a prefix
    // of `text` ending at a dot is `text` cut at that dot.
    if (l.isAnyAlias(text[0..last_dot])) return false;
    const root_schema = if (l.interner.find(text[0..first_dot])) |root| l.schemas.contains(root) else false;
    if (root_schema) return true;
    // An alias followed by at least two more segments: cut at every dot
    // but the last.
    var at: usize = first_dot;
    while (at < last_dot) : (at = at + 1 + std.mem.indexOfScalar(u8, text[at + 1 ..], '.').?) {
        if (l.isAnyAlias(text[0..at])) return true;
    }
    return false;
}

/// An unqualified upper name in type position (§6.2).
fn resolveType(l: *Lower, token: TokenIndex) Allocator.Error!Index {
    l.cur_token = token;
    const symbol = l.tokenSymbol(token);
    if (l.types.get(symbol)) |entry| switch (entry.kind) {
        .top => {
            try l.addRef(.top_type, entry.index, 0);
            return l.addInst(.type_top, entry.index, Inst.Data.unused);
        },
        .exposed => return l.importRef(.type_import, .import_type, l.importModule(entry.index), symbol),
    };
    if (prelude.wellKnown(symbol)) |w| {
        if (prelude.typeModule(w)) |m| return l.importRef(.type_import, .import_type, m.symbol(), symbol);
    }
    if (l.schemas.contains(symbol)) return l.schemaNamespaceRef(token, .schema_type_ref);
    try l.reportToken(.unbound_type, token);
    return l.errorInst(.unbound_type);
}

fn importModule(l: *const Lower, import_index: u32) Symbol {
    return l.symbols.items[@intFromEnum(l.imports.items[import_index].module)];
}

/// The explicit import whose alias is spelled `text` — the first to take
/// it — or null. One hash probe, not a scan of the import table.
fn importWithAlias(l: *const Lower, text: []const u8) ?u32 {
    const symbol = l.interner.find(text) orelse return null;
    return l.import_by_alias.get(symbol);
}

/// Whether `text` is the alias of any import row, the prelude's included:
/// an explicit import's, or a prelude module's name, which is its own
/// alias (`lowerImports`).
fn isAnyAlias(l: *const Lower, text: []const u8) bool {
    if (l.importWithAlias(text) != null) return true;
    for (prelude.modules) |w| {
        if (std.mem.eql(u8, @tagName(w), text)) return true;
    }
    return false;
}

/// `Alias.name` (§6.2): the module part against the import aliases, then
/// the prelude's module aliases; the name part is interned on its own.
fn resolveQualified(l: *Lower, token: TokenIndex, tag: Inst.Tag, ref_kind: Bir.Ref.Kind, unbound: diagnostic.Code) Allocator.Error!Index {
    l.cur_token = token;
    const text = l.tokenText(token);
    const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse {
        // A `qualified_*` token always has a dot; a placeholder does not.
        try l.reportToken(.unknown_module_alias, token);
        return l.errorInst(unbound);
    };
    const module_text = text[0..dot];
    const name_text = text[dot + 1 ..];
    const module: Symbol = found: {
        if (l.importWithAlias(module_text)) |i| break :found l.importModule(i);
        for (prelude.modules) |w| {
            if (std.mem.eql(u8, @tagName(w), module_text)) break :found w.symbol();
        }
        try l.reportToken(.unknown_module_alias, token);
        return l.errorInst(unbound);
    };
    const name = try l.interner.getOrPut(l.gpa, name_text);
    return l.importRef(tag, ref_kind, module, name);
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// A type expression the source wrote on its own: an annotation, a
/// `foreign` value's type, an alias body, one constructor's argument.
/// Each is a fresh scope for the "first occurrence" half of the
/// `equatable` rule (checker.md Appendix A) — `lowerType` itself recurses
/// and must not reset it.
fn lowerRootType(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    l.type_vars_seen.clearRetainingCapacity();
    return l.lowerType(node);
}

/// The parameter count a lowered type declares: `n` for `T1, …, Tn -> R`,
/// and 0 for everything else — a `foreign` whose annotation is not a
/// function type binds to a VALUE and has no parameters at all
/// (`boundary.md` §4). Reads the `SubRange` record `type_fn`'s `lhs` points
/// at, which is the shape `Bir.subRange` reads once the arrays are frozen.
fn typeFnArity(l: *const Lower, inst: Index) u32 {
    if (l.insts.items(.tag)[inst.int()] != .type_fn) return 0;
    const at = l.insts.items(.data)[inst.int()].lhs;
    return l.extra.items[at + 1] - l.extra.items[at];
}

fn lowerType(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const main_token = l.tree.nodeMainToken(node);
    l.cur_token = main_token;
    const data = l.tree.nodeData(node);
    switch (l.tree.nodeTag(node)) {
        .type_var => return l.lowerTypeVarMarked(l.tree.nodeMainToken(node), @enumFromInt(data.lhs)),
        .type_con => {
            const con = l.tree.fullTypeCon(node);
            const ref = switch (l.tags[con.name]) {
                .qualified_upper => if (l.couldBeSchemaQualified(con.name))
                    try l.schemaNamespaceRef(con.name, .schema_type_ref)
                else
                    try l.resolveQualified(con.name, .type_qualified, .import_type, .unbound_type),
                else => try l.resolveType(con.name),
            };
            if (con.args.len == 0) return ref;
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (con.args) |arg| try l.pushScratch(try l.lowerType(arg));
            const range = try l.addRangeRecord(try l.addRange(l.scratchSince(mark)));
            return l.addInstAt(main_token, .type_app, ref.int(), @intFromEnum(range));
        },
        .type_fn => {
            const fn_type = l.tree.fullTypeFn(node);
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            // A parameter is a position the declaration receives, and a
            // parameter of a parameter one it hands back.
            const outer = l.receives;
            l.receives = !outer;
            for (fn_type.params) |param| try l.pushScratch(try l.lowerType(param));
            l.receives = outer;
            const range = try l.addRangeRecord(try l.addRange(l.scratchSince(mark)));
            const result = try l.lowerType(fn_type.result);
            return l.addInstAt(main_token, .type_fn, @intFromEnum(range), result.int());
        },
        .type_unit => return l.addInst(.type_unit, 0, 0),
        .type_paren => return l.lowerType(l.tree.operand(node)),
        // `sync (…)`: the function type inside, whose `main_token` becomes
        // the word `sync` — the mark, in the BIR, costs no column
        // (transparent-effects-proposal.md §15.2, §15.5). A mark on anything
        // but a function type written out, or on one the declaration hands
        // back, is `misplaced_sync` and is dropped.
        .type_sync => {
            const inner = try l.lowerType(l.tree.operand(node));
            const reading: Diagnostics.Item.Markup = if (l.insts.items(.tag)[inner.int()] != .type_fn)
                .sync_not_function
            else if (!l.receives)
                .sync_handed_back
            else {
                l.insts.items(.main_token)[inner.int()] = main_token;
                return inner;
            };
            try l.diagnostics.append(l.gpa, .{ .code = .misplaced_sync, .start = l.starts[main_token], .end = l.tokenEnd(main_token), .markup = reading });
            return inner;
        },
        .type_tuple => {
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (l.tree.children(node)) |elem| try l.pushScratch(try l.lowerType(elem));
            const range = try l.addRange(l.scratchSince(mark));
            return l.addInstAt(main_token, .type_tuple, @intFromEnum(range.start), @intFromEnum(range.end));
        },
        .type_record => {
            const range = try l.lowerTypeFields(l.tree.children(node));
            return l.addInstAt(main_token, .type_record, @intFromEnum(range.start), @intFromEnum(range.end));
        },
        .type_record_ext => {
            const ext = l.tree.fullTypeRecordExt(node);
            const base = try l.lowerTypeVar(ext.base);
            const range = try l.addRangeRecord(try l.lowerTypeFields(ext.fields));
            return l.addInstAt(main_token, .type_record_ext, base.int(), @intFromEnum(range));
        },
        else => |tag| {
            std.debug.assert(tag.isError());
            return l.errorInst(l.tree.fullError(node).code);
        },
    }
}

/// `record_type_field` nodes to a range of `Field` pairs.
/// `duplicate_field` (language.md §4) over the field names of one record,
/// a literal's or a TYPE's: the second and every later `a` is reported at
/// its own name. Linear for the short records every program writes, and a
/// hash set past `linear_limit`, so a generated 100 000-field record costs
/// n and not n²/2.
const FieldNames = struct {
    const linear_limit = 16;

    /// The first `linear_limit` names, with no allocation: every record a
    /// person writes stays here.
    few: [linear_limit]Symbol = undefined,
    len: usize = 0,
    /// Every name, once there are more than `linear_limit`.
    set: U32Set = .{},

    fn deinit(f: *FieldNames, gpa: Allocator) void {
        f.set.deinit(gpa);
    }

    /// Records `symbol`; true when the record already named it.
    fn seen(f: *FieldNames, gpa: Allocator, symbol: Symbol) Allocator.Error!bool {
        if (f.len < linear_limit) {
            if (std.mem.indexOfScalar(Symbol, f.few[0..f.len], symbol) != null) return true;
            f.few[f.len] = symbol;
            f.len += 1;
            return false;
        }
        if (f.set.count == 0) {
            for (f.few) |n| _ = try f.set.insert(gpa, @intFromEnum(n));
        }
        return f.set.insert(gpa, @intFromEnum(symbol));
    }
};

fn lowerTypeFields(l: *Lower, fields: []const NodeIndex) Allocator.Error!SubRange {
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    var names: FieldNames = .{};
    defer names.deinit(l.gpa);
    for (fields) |f| {
        if (l.tree.nodeTag(f) != .record_type_field) continue;
        const name_token = l.tree.nodeMainToken(f);
        const symbol = l.tokenSymbol(name_token);
        // A duplicate field name in a record TYPE is the error a duplicate
        // in a record literal has always been. The field is still
        // lowered, so its type is resolved and reported like any other,
        // but it is not kept: `TypeStore`'s records have one field per
        // name (`Solve.gatherFields`), and the first `a` is the one read.
        if (try names.seen(l.gpa, symbol)) {
            try l.reportToken(.duplicate_field, name_token);
            _ = try l.lowerType(l.tree.operand(f));
            continue;
        }
        const name = try l.addSymbol(symbol);
        const value = try l.lowerType(l.tree.operand(f));
        try l.pushScratch(name);
        try l.pushScratch(value);
    }
    return l.addRange(l.scratchSince(mark));
}

/// A type variable: bound to a parameter of the enclosing `type` /
/// `type alias` (`unbound_type_variable` otherwise, §7), or free in an
/// annotation.
fn lowerTypeVar(l: *Lower, token: TokenIndex) Allocator.Error!Index {
    return l.lowerTypeVarMarked(token, .none);
}

/// A type variable, with the `equatable` marker written in front of it if
/// any (checker.md Appendix A). The marker is legal only in the core
/// package (`equatable_outside_core`) and only on the variable's FIRST
/// occurrence in this type expression (`equatable_not_first_occurrence`) —
/// `eq : equatable a -> a -> Bool` marks the variable once and is a
/// function of two arguments, so a second marker, or one on a later
/// occurrence, is a mistake about what the prefix means rather than a
/// harmless repetition.
/// Above this many type parameters a declaration's are looked up by name
/// (`type_param_index`), not scanned.
const indexed_params = 8;

fn lowerTypeVarMarked(l: *Lower, token: TokenIndex, marker: Ast.OptionalTokenIndex) Allocator.Error!Index {
    l.cur_token = token;
    const symbol = l.tokenSymbol(token);
    const name = try l.addSymbol(symbol);
    var info: Bir.TypeVarInfo = .{ .param = Bir.TypeVarInfo.param_none, .equatable = false };
    if (l.type_params) |params| {
        if (params.len > indexed_params) {
            if (l.type_param_index.get(symbol)) |i| info.param = @intCast(i);
        } else for (params, 0..) |p, i| {
            if (l.tokenSymbol(p) == symbol) {
                info.param = @intCast(i);
                break;
            }
        }
        if (info.param == Bir.TypeVarInfo.param_none) try l.reportToken(.unbound_type_variable, token);
    }
    const first_occurrence = std.mem.indexOfScalar(Symbol, l.type_vars_seen.items, symbol) == null;
    if (first_occurrence) try l.type_vars_seen.append(l.scratch_allocator, symbol);
    if (marker.unwrap()) |marker_token| {
        if (!l.options.core) {
            try l.reportToken(.equatable_outside_core, marker_token);
        } else if (!first_occurrence) {
            try l.reportToken(.equatable_not_first_occurrence, marker_token);
        } else {
            info.equatable = true;
        }
    }
    return l.addInst(.type_var, @intFromEnum(name), info.pack());
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

fn lowerExpr(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const tag = l.tree.nodeTag(node);
    const main_token = l.tree.nodeMainToken(node);
    l.cur_token = main_token;
    switch (tag) {
        .int, .float => {
            const text = try l.addBytes(l.tokenText(main_token));
            return l.addInst(if (tag == .int) .int else .float, text[0], text[1]);
        },
        .char => return l.addInst(.char, decodeChar(l.tokenText(main_token)), Inst.Data.unused),
        .string => return l.lowerString(node),
        .multiline_string => {
            const ml = l.tree.fullMultilineString(node);
            const offset: u32 = @intCast(l.string_bytes.items.len);
            var t = ml.first_line;
            while (t <= ml.last_line) : (t += 1) {
                if (l.tags[t] != .multiline_line) continue;
                if (t != ml.first_line) try l.string_bytes.append(l.gpa, '\n');
                try l.string_bytes.appendSlice(l.gpa, l.tokenText(t)[2..]);
            }
            return l.addInst(.string, offset, @as(u32, @intCast(l.string_bytes.items.len)) - offset);
        },
        .ident => return switch (l.tags[main_token]) {
            .qualified_lower => if (l.couldBeSchemaQualified(main_token))
                l.schemaNamespaceRef(main_token, .schema_value_ref)
            else
                l.resolveQualified(main_token, .qualified, .import_value, .unbound_variable),
            else => l.resolveValue(main_token),
        },
        .ctor => return switch (l.tags[main_token]) {
            .qualified_upper => if (l.couldBeSchemaQualified(main_token))
                l.schemaNamespaceRef(main_token, .schema_ctor_ref)
            else
                l.resolveQualified(main_token, .qualified_ctor, .import_ctor, .unbound_constructor),
            else => l.resolveCtor(main_token),
        },
        .accessor => {
            // `.field` → `\r -> r.field` (§8.2).
            const param = try l.reserveInst(.pat_var);
            const local = try l.freshLocal(param);
            l.setInstData(param, local, Inst.Data.unused);
            const target = try l.addInst(.local, local, Inst.Data.unused);
            const field = try l.addSymbol(l.tokenSymbol(main_token));
            const access = try l.addInst(.field_access, target.int(), @intFromEnum(field));
            const params = try l.addRangeRecord(try l.addRange(&.{param.int()}));
            return l.addInst(.lambda, @intFromEnum(params), access.int());
        },
        .op_fn => {
            // `(==)` and its five relatives are a LAMBDA over a method call
            // (static-dispatch-spike.md §3.1, Appendix A.22): a reference to
            // `Basics.eq` would be structural equality, which is not what
            // the operator means any more. Every other operator is still the
            // reference to its core function.
            if (Bir.WellKnown.fromOperator(l.tags[main_token])) |origin| return l.operatorLambda(origin);
            // `(::)`: `cons_removed`, reported by the parser (§6.8).
            if (l.tags[main_token] == .op_colon_colon) return l.errorInst(.cons_removed);
            return l.operatorRef(l.tags[main_token]);
        },
        .unit => return l.addInst(.unit, 0, 0),
        .negate => {
            const operand = try l.lowerExpr(l.tree.operand(node));
            const negate = try l.basicsRef(.negate);
            return l.call(negate, &.{operand.int()});
        },
        .paren => return l.lowerExpr(l.tree.operand(node)),
        .tuple, .list => {
            if (tag == .list) {
                for (l.tree.children(node)) |elem| {
                    if (l.tree.nodeTag(elem) == .spread) return l.lowerSpreadList(node);
                }
            }
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (l.tree.children(node)) |elem| try l.pushScratch(try l.lowerExpr(elem));
            const range = try l.addRange(l.scratchSince(mark));
            return l.addInstAt(main_token, if (tag == .tuple) .tuple else .list, @intFromEnum(range.start), @intFromEnum(range.end));
        },
        // Only ever an item of a `list`, which `lowerSpreadList` reads; the
        // operand alone is the defensive reading of one met anywhere else.
        .spread => return l.lowerExpr(l.tree.operand(node)),
        .record => {
            const range = try l.lowerFields(l.tree.children(node));
            return l.addInstAt(main_token, .record, @intFromEnum(range.start), @intFromEnum(range.end));
        },
        .record_update => {
            const upd = l.tree.fullRecordUpdate(node);
            const base = try l.resolveValue(upd.base);
            const range = try l.addRangeRecord(try l.lowerFields(upd.fields));
            return l.addInstAt(main_token, .record_update, base.int(), @intFromEnum(range));
        },
        .field_access => {
            const target = try l.lowerExpr(l.tree.operand(node));
            const field = try l.addSymbol(l.tokenSymbol(main_token));
            return l.addInstAt(main_token, .field_access, target.int(), @intFromEnum(field));
        },
        .tuple_index => {
            const target = try l.lowerExpr(l.tree.operand(node));
            return l.addInstAt(main_token, .tuple_index, target.int(), l.payloads[main_token]);
        },
        .apply => {
            const app = l.tree.fullApply(node);
            return l.lowerApplication(main_token, app.function, app.args, null, .last);
        },
        .question => return l.lowerQuestion(node),
        .pipe_right => {
            // `x |> f a` → `f x a` (§8.2): the operand is the callee's FIRST
            // argument, which is what makes the subject-first library read
            // as a pipeline (§6.7).
            const b = l.tree.fullBinop(node);
            return l.saturate(b.rhs, b.lhs, .first);
        },
        .pipe_left => {
            // `f a <| x` → `f a x`.
            const b = l.tree.fullBinop(node);
            return l.saturate(b.lhs, b.rhs, .last);
        },
        .lambda => {
            const lam = l.tree.fullLambda(node);
            const mark = l.scope.items.len;
            const params = try l.lowerParams(lam.params);
            try l.frames.append(l.scratch_allocator, .{ .kind = .lambda, .inst = .none });
            const body = try l.lowerExpr(lam.body);
            _ = l.frames.pop();
            l.popScope(mark);
            const params_record = try l.addRangeRecord(params);
            return l.addInstAt(main_token, .lambda, @intFromEnum(params_record), body.int());
        },
        .@"if" => return l.lowerIf(node),
        .let => return l.lowerLet(node),
        .case => {
            const c = l.tree.fullCase(node);
            const scrutinee = try l.lowerExpr(c.scrutinee);
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (c.branches) |br| {
                if (l.tree.nodeTag(br) != .branch) continue;
                const b = l.tree.fullBranch(br);
                try l.pushScratch(try l.lowerBranch(b.pattern, b.body));
            }
            const branches = try l.addRangeRecord(try l.addRange(l.scratchSince(mark)));
            return l.addInstAt(main_token, .case, scrutinee.int(), @intFromEnum(branches));
        },
        // Every other binary operator: a call of its core function — except
        // the six comparisons, which are method calls on the type of their
        // left operand and carry the operator they were written as
        // (static-dispatch-spike.md §3.1).
        // `::` left the language (language.md §6.8): the parser reported
        // the chain as `cons_removed`, and it lowers to the poison that
        // report stands for.
        .cons => return l.errorInst(.cons_removed),
        .add, .sub, .mul, .div, .int_div, .pow, .append, .eq, .neq, .lt, .gt, .lte, .gte, .bool_and, .bool_or => {
            const b = l.tree.fullBinop(node);
            const lhs = try l.lowerExpr(b.lhs);
            const rhs = try l.lowerExpr(b.rhs);
            if (Bir.WellKnown.fromOperator(l.tags[b.op_token])) |origin| {
                l.cur_token = b.op_token;
                return l.methodCall(lhs, origin.method().?.symbol(), origin, &.{rhs.int()});
            }
            const function = try l.operatorRef(l.tags[b.op_token]);
            l.cur_token = b.op_token;
            return l.call(function, &.{ lhs.int(), rhs.int() });
        },
        // Only a `<-` right-hand side can hold one (§6.7); the parser has
        // reported it as `placeholder_outside_argument` already.
        .placeholder => return l.errorInst(.placeholder_outside_argument),
        .markup_element, .markup_fragment, .markup_for, .markup_show => return l.lowerMarkup(node),
        else => {
            std.debug.assert(tag.isError());
            return l.errorInst(l.tree.fullError(node).code);
        },
    }
}

/// A list literal with a spread (language.md §6.8, §8): the `List.cons` and
/// `List.append` calls it means, built from the right. The plain items
/// after the last spread are one `list` (none when the spread is last);
/// going left, a spread `...s` is `List.append s <built>` — `s` alone when
/// nothing is built yet — and an element `e` is `List.cons e <built>`. So
/// `[ x, ...xs ]` is exactly the call `x :: xs` was, which is what keeps a
/// cons step a cons step (`backend.md` §8) and the emitted JavaScript the
/// same. Every item is lowered first, in source order, so the instructions
/// read as the source does; a call evaluates its arguments left to right,
/// so the items still run in written order. Each call and its callee are
/// stamped with the `...` of the spread they belong to.
fn lowerSpreadList(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const items = l.tree.children(node);
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (items) |item| {
        try l.pushScratch(try l.lowerExpr(if (l.tree.nodeTag(item) == .spread) l.tree.operand(item) else item));
    }
    // Nothing below pushes to the scratch list, so the slice stays valid.
    const lowered: []const Index = @ptrCast(l.scratchSince(mark));
    // The trailing run of plain items, as one literal.
    var end = items.len;
    while (end > 0 and l.tree.nodeTag(items[end - 1]) != .spread) end -= 1;
    var built: ?Index = null;
    if (end < items.len) {
        const range = try l.addRange(@ptrCast(lowered[end..]));
        built = try l.addInstAt(l.tree.nodeMainToken(node), .list, @intFromEnum(range.start), @intFromEnum(range.end));
    }
    var i = end;
    // The `...` of the nearest spread at or right of `i`.
    var spread_token = l.tree.nodeMainToken(items[end - 1]);
    while (i > 0) {
        i -= 1;
        const item = items[i];
        if (l.tree.nodeTag(item) == .spread) {
            spread_token = l.tree.nodeMainToken(item);
            if (built) |rest| {
                l.cur_token = spread_token;
                const callee = try l.importRef(.import_value, .import_value, WellKnown.List.symbol(), WellKnown.append.symbol());
                built = try l.call(callee, &.{ lowered[i].int(), rest.int() });
            } else built = lowered[i];
        } else {
            l.cur_token = spread_token;
            const callee = try l.importRef(.import_value, .import_value, WellKnown.List.symbol(), WellKnown.cons.symbol());
            built = try l.call(callee, &.{ lowered[i].int(), built.?.int() });
        }
    }
    return built.?;
}

fn call(l: *Lower, callee: Index, args: []const u32) Allocator.Error!Index {
    const range = try l.addRangeRecord(try l.addRange(args));
    return l.addInst(.call, callee.int(), @intFromEnum(range));
}

/// `x.m a b` (static-dispatch-spike.md §1.4). `args` excludes the receiver,
/// which is the instruction's `lhs`. No `refs` edge is recorded: which
/// function this calls is the checker's to decide (§1.4).
fn methodCall(l: *Lower, receiver: Index, name: Symbol, origin: Bir.WellKnown, args: []const u32) Allocator.Error!Index {
    const range = try l.addRange(args);
    const extra = try l.addExtra(Bir.MethodCall{
        .name = try l.addSymbol(name),
        .origin = origin,
        .args_start = range.start,
        .args_end = range.end,
    });
    return l.addInst(.method_call, receiver.int(), @intFromEnum(extra));
}

/// `a.m args` with no receiver value (§4.1): `var_symbol` is the type
/// variable the enclosing declaration's `where` clause constrains.
fn typeDispatch(l: *Lower, var_symbol: Symbol, name: Symbol, args: []const u32) Allocator.Error!Index {
    const range = try l.addRange(args);
    const extra = try l.addExtra(Bir.TypeDispatch{
        .name = try l.addSymbol(name),
        .args_start = range.start,
        .args_end = range.end,
    });
    return l.addInst(.type_dispatch, @intFromEnum(try l.addSymbol(var_symbol)), @intFromEnum(extra));
}

/// `(==)` → `\a b -> a == b` (§3.1, Appendix A.22): a closure of arity two
/// whose BODY carries the method constraint, so the operator as a function
/// dispatches exactly as the operator does.
fn operatorLambda(l: *Lower, origin: Bir.WellKnown) Allocator.Error!Index {
    const left = try l.reserveInst(.pat_var);
    const left_local = try l.freshLocal(left);
    l.setInstData(left, left_local, Inst.Data.unused);
    const right = try l.reserveInst(.pat_var);
    const right_local = try l.freshLocal(right);
    l.setInstData(right, right_local, Inst.Data.unused);
    const receiver = try l.addInst(.local, left_local, Inst.Data.unused);
    const argument = try l.addInst(.local, right_local, Inst.Data.unused);
    const body = try l.methodCall(receiver, origin.method().?.symbol(), origin, &.{argument.int()});
    const params = try l.addRangeRecord(try l.addRange(&.{ left.int(), right.int() }));
    return l.addInst(.lambda, @intFromEnum(params), body.int());
}

/// The core function of language.md §6.5's table for an operator token,
/// **with the module that defines it**. Every operator is a `Basics`
/// function since `::`, whose home was `List`, left (language.md §6.8),
/// but the module stays per operator rather than assumed — checker.md
/// §4.3. Getting this wrong is invisible until name resolution looks the function up in the wrong
/// interface, which is why the corpus goldens print the module.
const OperatorFunction = struct { module: WellKnown, function: WellKnown };

fn operatorFunction(op: Token.Tag) OperatorFunction {
    return switch (op) {
        .op_plus => .{ .module = .Basics, .function = .add },
        .op_minus => .{ .module = .Basics, .function = .sub },
        .op_star => .{ .module = .Basics, .function = .mul },
        .op_slash => .{ .module = .Basics, .function = .fdiv },
        .op_slash_slash => .{ .module = .Basics, .function = .idiv },
        .op_caret => .{ .module = .Basics, .function = .pow },
        .op_plus_plus => .{ .module = .Basics, .function = .append },
        .op_eq_eq => .{ .module = .Basics, .function = .eq },
        .op_slash_eq => .{ .module = .Basics, .function = .neq },
        .op_lt => .{ .module = .Basics, .function = .lt },
        .op_gt => .{ .module = .Basics, .function = .gt },
        .op_lte => .{ .module = .Basics, .function = .le },
        .op_gte => .{ .module = .Basics, .function = .ge },
        .op_and_and => .{ .module = .Basics, .function = .@"and" },
        .op_or_or => .{ .module = .Basics, .function = .@"or" },
        // `|>` and `<|` are syntax, not calls (§6.5): they have no core
        // function, no `(|>)` form, and never reach this table.
        else => unreachable, // `op_fn` and binop nodes hold operator tokens only
    };
}

/// Which end of the argument list a pipe's operand lands on: `|>` inserts at
/// the FIRST argument and `<|` appends at the last (§6.7).
const Position = enum { first, last };

/// Apply `function_node` to one more argument, flattening the call spine it
/// is written against: `f a` with `x` becomes `f x a` (`|>`) or `f a x`
/// (`<|`) — the one place the front end changes call arity, §8.2. The walk
/// is `bindSpine`, shared with `<-`, so one set of rules decides what a
/// pipe's right operand means in both positions: grouping parentheses are
/// looked through (`x |> (f a)` is `f x a`, not a call of the value), a bare
/// name contributes no arguments, and a nested pipe underneath contributes
/// its own operand rather than being called as a value — `x |> (y |> f)` is
/// `f x y`, because `y |> f` is `f y` first and §8 runs the rewrite before
/// anything else (§6.7).
fn saturate(l: *Lower, function_node: NodeIndex, extra_node: NodeIndex, position: Position) Allocator.Error!Index {
    var arg_nodes: std.ArrayList(NodeIndex) = .empty;
    defer arg_nodes.deinit(l.scratch_allocator);
    const callee_node = try l.bindSpine(function_node, &arg_nodes);
    return l.lowerApplication(l.spineToken(function_node), callee_node, arg_nodes.items, extra_node, position);
}

/// The token the call a pipe rewrote is stamped with: the head of the spine
/// `bindSpine` walks, so `x |> (y |> f a)` reports against `f a` rather than
/// against either `|>`.
fn spineToken(l: *const Lower, node: NodeIndex) TokenIndex {
    var n = node;
    while (true) switch (l.tree.nodeTag(n)) {
        .paren => n = l.tree.operand(n),
        .pipe_right => n = l.tree.fullBinop(n).rhs,
        .pipe_left => n = l.tree.fullBinop(n).lhs,
        else => return l.tree.nodeMainToken(n),
    };
}

/// One application, with `extra` appended when a pipe supplied an argument.
/// A `_` among the arguments (§6.7) makes the WHOLE call the body of a
/// one-parameter lambda — the innermost enclosing application is this one —
/// so `f a _ c` is `\x -> f a x c`. Everything else inside the call is
/// lowered inside that lambda, which is where the desugared form puts it.
/// §8 fixes the order as pipes first, then placeholders, so the operand a
/// pipe supplied is one of this call's arguments and is lowered inside the
/// lambda too: `a? |> f _` is the same program as `f (a?) _`, down to the
/// `question_in_lambda` both report. Without a `_` there is no lambda and
/// the operand keeps its written position, ahead of the callee.
///
/// `position` says which end the pipe's operand lands on, and it is lowered
/// where it is WRITTEN, which is not the same end: `|>` writes its operand
/// ahead of the callee, so it is lowered first and then rotated to the front
/// of the argument list; `<|` writes it after the callee and after every
/// argument, so it is lowered last, like the hole case. Either way the
/// instructions come out in source order and only the operand's slot in the
/// call moves. That matters because `?` returns from the enclosing function
/// where it is lowered: in `Just (two (String.toInt a?) <| String.toInt b?)`
/// the `try` on `a` has to precede the `try` on `b`.
fn lowerApplication(
    l: *Lower,
    main_token: TokenIndex,
    function: NodeIndex,
    args: []const NodeIndex,
    extra: ?NodeIndex,
    position: Position,
) Allocator.Error!Index {
    var param: Index = @enumFromInt(0);
    var local: u32 = 0;
    const has_hole = l.placeholderIn(args);
    var extra_arg: ?Index = null;
    if (has_hole) {
        param = try l.reserveInst(.pat_var);
        local = try l.freshLocal(param);
        l.setInstData(param, local, Inst.Data.unused);
        try l.frames.append(l.scratch_allocator, .{ .kind = .lambda, .inst = .none });
    } else if (position == .first) {
        // `|>` writes its operand before the callee, so that is where it is
        // lowered. `<|` writes it last and is lowered below, after the args.
        if (extra) |e| extra_arg = try l.lowerExpr(e);
    }
    // An application whose head is a field access is a METHOD CALL
    // (static-dispatch-spike.md §1.1): `x.m a` is `method_call`, and so is
    // `x.a.m b`, `x.0.m a`, `M.v.m a` and `e |> x.m a`, because the head of
    // each is a field access. Parentheses opt out — the head of `(x.m) a`
    // is a `paren`, which is not looked through here — and `x.m` with no
    // argument is not an application at all, so it stays a field access.
    const Method = struct { target: NodeIndex, name: TokenIndex };
    const method: ?Method = if (l.tree.nodeTag(function) == .field_access)
        .{ .target = l.tree.operand(function), .name = l.tree.nodeMainToken(function) }
    else
        null;
    // `a.decode s`: a receiver that is a lower name binding no value, but
    // naming a type variable of this declaration's `where` clause, is a
    // dispatch on the TYPE and never a field access (§4.1).
    const dispatch: ?Symbol = if (method) |m| l.typeDispatchVar(m.target) else null;
    var receiver: Index = @enumFromInt(0);
    var callee: Index = @enumFromInt(0);
    if (method) |m| {
        if (dispatch == null) receiver = try l.lowerExpr(m.target);
    } else {
        callee = try l.lowerExpr(function);
    }
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (args) |arg| {
        // A second `_` is `multiple_placeholders`, already reported; it
        // shares the one parameter so the tree stays well formed.
        if (l.tree.nodeTag(arg) == .placeholder) {
            try l.pushScratch(try l.addInst(.local, local, Inst.Data.unused));
        } else {
            try l.pushScratch(try l.lowerExpr(arg));
        }
    }
    // The operand of a `<|`, and of a `|>` whose call has a hole, is written
    // after the arguments (a hole's lambda wraps the whole call, so `a? |> f _`
    // is the same program as `f (a?) _`, down to the `question_in_lambda`).
    if (extra_arg == null) {
        if (extra) |e| extra_arg = try l.lowerExpr(e);
    }
    if (extra_arg) |e| {
        try l.pushScratch(e);
        // `|>` inserts at the first argument, so its operand is rotated to
        // the front of the slots, which moves one word and leaves every
        // instruction where it is.
        if (position == .first) {
            const slots = l.list_scratch.items[mark..];
            std.mem.rotate(u32, slots, slots.len - 1);
        }
    }
    const called = blk: {
        if (method) |m| {
            // The method name is the region: every diagnostic about a method
            // call is about `m`, not about the receiver's first token.
            l.cur_token = m.name;
            const name = l.tokenSymbol(m.name);
            if (dispatch) |variable| break :blk try l.typeDispatch(variable, name, l.scratchSince(mark));
            break :blk try l.methodCall(receiver, name, .none, l.scratchSince(mark));
        }
        l.cur_token = main_token;
        break :blk try l.call(callee, l.scratchSince(mark));
    };
    if (!has_hole) return called;
    _ = l.frames.pop();
    const params = try l.addRangeRecord(try l.addRange(&.{param.int()}));
    return l.addInstAt(main_token, .lambda, @intFromEnum(params), called.int());
}

fn placeholderIn(l: *const Lower, args: []const NodeIndex) bool {
    for (args) |a| if (l.tree.nodeTag(a) == .placeholder) return true;
    return false;
}

/// The type variable a `v.m args` head dispatches on (§4.1), or null: `v`
/// must be an unqualified lower name that resolves to NO value binding —
/// not a local, not a top-level value, not an `exposing` name, not a
/// prelude value — and must be constrained by the enclosing declaration's
/// own `where` clause. Shadowing is an error in beni (§7), so the two
/// readings never overlap.
fn typeDispatchVar(l: *const Lower, receiver: NodeIndex) ?Symbol {
    if (l.tree.nodeTag(receiver) != .ident) return null;
    const token = l.tree.nodeMainToken(receiver);
    if (l.tags[token] != .lower_ident) return null;
    const symbol = l.tokenSymbol(token);
    if (l.lookupLocal(symbol) != null) return null;
    if (l.values.get(symbol) != null) return null;
    if (prelude.wellKnown(symbol)) |w| {
        if (prelude.valueModule(w) != null) return null;
    }
    const d = l.decls.items[l.cur_decl];
    var i = @intFromEnum(d.where_start);
    while (i < @intFromEnum(d.where_end)) : (i += Bir.extraLen(Bir.WhereConstraint)) {
        if (l.symbols.items[l.extra.items[i]] == symbol) return symbol;
    }
    // Trigger (2) of §4.1: the declaration has an annotation naming `v` as
    // a type variable but no `where` clause for it. The node is emitted so
    // that the CHECKER can say `type_dispatch_needs_annotation` (§10.8)
    // naming the constraint to add; reporting `unbound_variable` here would
    // leave A.5's second trigger with no path at all.
    if (std.mem.indexOfScalar(Symbol, l.annotation_vars.items, symbol) != null) return symbol;
    return null;
}

/// `if c then a else b` → `case c of True -> a; False -> b` on the prelude
/// constructors (§8.2), whatever the file declares: `if` is syntax on
/// `Bool`.
fn lowerIf(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const i = l.tree.fullIf(node);
    const if_token = l.tree.nodeMainToken(node);
    const cond = try l.lowerExpr(i.cond);
    const true_ref = try l.importRef(.import_ctor, .import_ctor, WellKnown.Basics.symbol(), WellKnown.True.symbol());
    const true_pat = try l.addInst(.pat_ctor, true_ref.int(), @intFromEnum(try l.addRangeRecord(SubRange.empty)));
    const then_expr = try l.lowerExpr(i.then_expr);
    const then_branch = try l.addInst(.branch, true_pat.int(), then_expr.int());
    const false_ref = try l.importRef(.import_ctor, .import_ctor, WellKnown.Basics.symbol(), WellKnown.False.symbol());
    const false_pat = try l.addInst(.pat_ctor, false_ref.int(), @intFromEnum(try l.addRangeRecord(SubRange.empty)));
    const else_expr = try l.lowerExpr(i.else_expr);
    const else_branch = try l.addInst(.branch, false_pat.int(), else_expr.int());
    const branches = try l.addRangeRecord(try l.addRange(&.{ then_branch.int(), else_branch.int() }));
    return l.addInstAt(if_token, .case, cond.int(), @intFromEnum(branches));
}

/// A `case` branch: its pattern's variables are in scope in its body only.
fn lowerBranch(l: *Lower, pattern: NodeIndex, body: NodeIndex) Allocator.Error!Index {
    const mark = l.scope.items.len;
    const pat = try l.lowerPattern(pattern, mark, .pattern);
    const value = try l.lowerExpr(body);
    l.popScope(mark);
    return l.addInst(.branch, pat.int(), value.int());
}

/// `e?` (§6.6): a `try` whose target is the nearest enclosing definition
/// with parameters.
fn lowerQuestion(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const operand = try l.lowerExpr(l.tree.operand(node));
    const q_token = l.tree.nodeMainToken(node);
    l.cur_token = q_token;
    // Reported or not, the instruction stands for the case it desugars to.
    var target: Inst.OptionalIndex = .none;
    var i = l.frames.items.len;
    while (i > 0) {
        i -= 1;
        const frame = l.frames.items[i];
        switch (frame.kind) {
            .lambda => {
                try l.reportToken(.question_in_lambda, q_token);
                break;
            },
            .function => {
                target = frame.inst;
                break;
            },
            .constant => {},
        }
    } else {
        try l.reportToken(.question_outside_function, q_token);
    }
    return l.addInst(.@"try", operand.int(), @intFromEnum(target));
}

/// `let` (§7): every binding's name is bound before any body is lowered,
/// so mutual recursion resolves and a binding may use a later constant.
fn lowerLet(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const let_node = l.tree.fullLet(node);
    return l.lowerBindings(let_node.bindings, let_node.body);
}

/// The bindings of one `let` up to the first `<-`, then the rest of the
/// block as that bind's callback (§6.7). `let x <- f a in rest` is
/// `f a (\x -> rest)`, so the bindings in front of the bind stay an ordinary
/// `let` whose body is the call, and `rest` — every later binding and the
/// `in` body — is lowered inside the lambda. A `let` whose ONLY binding is a
/// bind produces no `let` instruction at all: there is nothing left to bind.
fn lowerBindings(
    l: *Lower,
    all_bindings: []const NodeIndex,
    body_node: NodeIndex,
) Allocator.Error!Index {
    var head_len = all_bindings.len;
    for (all_bindings, 0..) |b, i| {
        if (l.tree.nodeTag(b) == .let_bind) {
            head_len = i;
            break;
        }
    }
    const head = all_bindings[0..head_len];
    const rest = all_bindings[head_len..];
    const scope_mark = l.scope.items.len;
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);

    // §7's initialisation rule wants one row per binding, in written order
    // and in step with the scratch slots below. `checkLetOrder` reads them
    // once, after phase 2 has filled in what each right-hand side is.
    var order: std.ArrayList(LetBinding) = .empty;
    defer order.deinit(l.scratch_allocator);
    const first_local = l.nextLocal();

    // Phase 1: bind. `let_def` gets its instruction now (its index is the
    // `try` target of its body); a `let_pattern` lowers its pattern now
    // (irrefutable, so it resolves nothing) and its value later.
    for (head) |b| {
        const local_start = l.nextLocal();
        switch (l.tree.nodeTag(b)) {
            .let_def => {
                const inst = try l.reserveInst(.let_def);
                _ = try l.bindVar(l.tree.nodeMainToken(b), l.scope.items.len, .let, inst);
                try l.pushScratch(inst);
                try order.append(l.scratch_allocator, .{
                    .local_start = local_start,
                    .local_end = l.nextLocal(),
                    .hoisted = l.tree.fullLetDef(b).params.len != 0,
                });
            },
            .let_pattern => {
                const lp = l.tree.fullLetPattern(b);
                const pat = try l.lowerPattern(lp.pattern, l.scope.items.len, .pattern);
                try l.pushScratch(pat);
                try order.append(l.scratch_allocator, .{
                    .local_start = local_start,
                    .local_end = l.nextLocal(),
                    .hoisted = false,
                });
            },
            else => {}, // annotations are read in phase 2; error bindings are skipped
        }
    }
    // Every local this block binds, with the token that binds it, so a
    // report can name the binding and its line. The scope entries phase 1
    // appended are exactly those locals, in index order.
    const local_tokens = try l.scratch_allocator.alloc(TokenIndex, l.nextLocal() - first_local);
    defer l.scratch_allocator.free(local_tokens);
    for (l.scope.items[scope_mark..]) |entry| local_tokens[entry.local - first_local] = entry.token;

    // Phase 2: bodies, in source order, each patched into its binding.
    var pending_annotation: Inst.OptionalIndex = .none;
    var pending_annotation_name: ?Symbol = null;
    var slot: usize = mark;
    for (head) |b| {
        switch (l.tree.nodeTag(b)) {
            .let_annotation => {
                pending_annotation = (try l.lowerRootType(l.tree.operand(b))).toOptional();
                pending_annotation_name = l.tokenSymbol(l.tree.nodeMainToken(b));
            },
            .let_def => {
                const inst: Index = @enumFromInt(l.list_scratch.items[slot]);
                const row = &order.items[slot - mark];
                row.inst_start = @intCast(l.insts.len);
                const def = l.tree.fullLetDef(b);
                var annotation: Inst.OptionalIndex = .none;
                if (pending_annotation_name != null and pending_annotation_name.? == l.tokenSymbol(def.name)) {
                    annotation = pending_annotation;
                }
                pending_annotation = .none;
                pending_annotation_name = null;
                const inner_mark = l.scope.items.len;
                const params = try l.lowerParams(def.params);
                try l.frames.append(l.scratch_allocator, Frame.definition(def.params.len > 0, inst.toOptional()));
                const body = try l.lowerExpr(def.body);
                _ = l.frames.pop();
                l.popScope(inner_mark);
                const record = try l.addExtra(Bir.LetDef{
                    // Phase 1 bound it: a `let_def` binds exactly one
                    // local, `local_start` (a search of the declaration's
                    // locals per binding would be quadratic).
                    .local = row.local_start,
                    .annotation = annotation,
                    .params_start = params.start,
                    .params_end = params.end,
                });
                l.setInstData(inst, @intFromEnum(record), body.int());
                row.inst_end = @intCast(l.insts.len);
                // A value whose right-hand side IS a lambda evaluates
                // nothing when it is bound (§6, *Evaluation order*), so
                // what the lambda's body names is read only when it is
                // called. `f a _` is one of these: the placeholder's
                // lambda wraps the whole application (§6.7).
                row.defers = row.hoisted or l.insts.items(.tag)[body.int()] == .lambda;
                slot += 1;
            },
            .let_pattern => {
                const pat: Index = @enumFromInt(l.list_scratch.items[slot]);
                const row = &order.items[slot - mark];
                row.inst_start = @intCast(l.insts.len);
                const lp = l.tree.fullLetPattern(b);
                const value = try l.lowerExpr(lp.value);
                l.list_scratch.items[slot] = (try l.addInst(.let_pattern, pat.int(), value.int())).int();
                row.inst_end = @intCast(l.insts.len);
                slot += 1;
            },
            else => {},
        }
    }
    try l.checkLetOrder(order.items, first_local, local_tokens);
    // `let x : T` may only precede a Definition (§6.7), and a bind is not
    // one, so an annotation left pending when the head runs out is
    // unattached exactly as a top-level one would be.
    if (rest.len != 0) {
        if (pending_annotation_name != null) {
            @branchHint(.cold);
            try l.reportToken(.annotation_without_definition, l.annotationToken(head));
        }
    }
    const body = if (rest.len == 0)
        try l.lowerExpr(body_node)
    else
        try l.lowerBind(rest[0], rest[1..], body_node);
    l.popScope(scope_mark);
    const items = l.scratchSince(mark);
    // Nothing left to bind: the `let` node would be empty. That happens for
    // the block a `<-` rewrote (its callback body is `rest`, which can be
    // the `in` body alone) but never for a `let` the author wrote, which
    // has at least one binding even when every one of them is an error.
    if (items.len == 0 and (rest.len != 0 or all_bindings.len == 0)) return body;
    const bindings = try l.addRangeRecord(try l.addRange(items));
    return l.addInst(.let, @intFromEnum(bindings), body.int());
}

/// §7's initialisation rule, for one `let` block: a VALUE binding is
/// initialised where it is written (§6, *Evaluation order*), so its
/// right-hand side may not read a binding of this block that has no value
/// there — one written below it, or itself. A `let` FUNCTION is emitted as
/// a hoisted `function` declaration (`backend.md` §4), so naming one early
/// is legal, and that is what makes §7's promise of mutual recursion
/// between `let` functions real; but naming one may CALL it — passing it
/// to `List.map` calls it — so whatever its body reads is read here too.
/// Without this, `a = later` above `later = 5` type-checks, emits
/// `const a = later$2;` above `const later$2 = …` and throws a JavaScript
/// `ReferenceError` at run time.
///
/// The references are read back out of the instructions the two phases
/// just emitted rather than recorded as they were resolved. Every use of a
/// local is a `local` instruction carrying its own token; each binding's
/// right-hand side occupies one contiguous instruction range; and a nested
/// `let`, lambda or `case` lies inside the range of the binding that
/// contains it, so a reference from one of those to a binding of THIS
/// block is attributed to the binding it runs inside, for free. Resolution
/// is hot and pays nothing; this walk is once per `let`, and linear in it:
/// each binding's edges are a contiguous run, since they are read
/// binding by binding, and the visited set is reset where it was set.
fn checkLetOrder(
    l: *Lower,
    bindings: []const LetBinding,
    first_local: u32,
    local_tokens: []const TokenIndex,
) Allocator.Error!void {
    if (local_tokens.len == 0) return;
    const end_local = first_local + @as(u32, @intCast(local_tokens.len));
    const tags = l.insts.items(.tag);
    const data = l.insts.items(.data);
    const tokens = l.insts.items(.main_token);
    // The binding each local of the block belongs to, by local.
    const binding_of = try l.scratch_allocator.alloc(u32, end_local - first_local);
    defer l.scratch_allocator.free(binding_of);
    for (bindings, 0..) |b, i| {
        for (b.local_start..b.local_end) |local| binding_of[local - first_local] = @intCast(i);
    }
    var edges: std.ArrayList(LetEdge) = .empty;
    defer edges.deinit(l.scratch_allocator);
    // `edges[starts[k]..starts[k + 1]]` are binding `k`'s.
    const starts = try l.scratch_allocator.alloc(u32, bindings.len + 1);
    defer l.scratch_allocator.free(starts);
    for (bindings, 0..) |b, from| {
        starts[from] = @intCast(edges.items.len);
        var i = b.inst_start;
        while (i < b.inst_end) : (i += 1) {
            if (tags[i] != .local) continue;
            const local = data[i].lhs;
            if (local < first_local or local >= end_local) continue;
            try edges.append(l.scratch_allocator, .{
                .from = @intCast(from),
                .to = binding_of[local - first_local],
                .local = local,
                .token = tokens[i],
            });
        }
    }
    starts[bindings.len] = @intCast(edges.items.len);
    if (edges.items.len == 0) return;
    const seen = try l.scratch_allocator.alloc(bool, bindings.len);
    defer l.scratch_allocator.free(seen);
    @memset(seen, false);
    var touched: std.ArrayList(u32) = .empty;
    defer touched.deinit(l.scratch_allocator);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(l.scratch_allocator);
    for (bindings, 0..) |b, index| {
        // A binding that defers runs nothing where it is written, so it
        // cannot read anything too soon. It is what its callers reach
        // THROUGH, which is the walk below.
        if (b.defers) continue;
        const k: u32 = @intCast(index);
        for (touched.items) |t| seen[t] = false;
        touched.clearRetainingCapacity();
        for (edges.items[starts[k]..starts[k + 1]]) |e| {
            if (tooSoon(bindings, e.to, k)) {
                const forward: Diagnostics.Item.Forward = if (e.to == k) .self else .direct;
                try l.reportForward(e.token, local_tokens[e.local - first_local], forward);
                break;
            }
            if (!bindings[e.to].defers or seen[e.to]) continue;
            seen[e.to] = true;
            try touched.append(l.scratch_allocator, e.to);
            if (try l.reachesTooSoon(edges.items, starts, bindings, seen, &touched, &work, e.to, k)) |hit| {
                // The binding reached may be `k` itself — `n = get ()`
                // where `get` reads `n` — and then it is not "further down".
                const forward: Diagnostics.Item.Forward = if (hit.to == k) .self_through else .through;
                try l.reportForward(e.token, local_tokens[hit.local - first_local], forward);
                break;
            }
        }
    }
}

/// The first binding that `start`'s body reads and `k` cannot have yet, or
/// null. `seen` carries across the calls made for one `k`, so no binding's
/// body is walked twice for the same `k`.
fn reachesTooSoon(
    l: *Lower,
    edges: []const LetEdge,
    starts: []const u32,
    bindings: []const LetBinding,
    seen: []bool,
    touched: *std.ArrayList(u32),
    work: *std.ArrayList(u32),
    start: u32,
    k: u32,
) Allocator.Error!?LetEdge {
    work.clearRetainingCapacity();
    try work.append(l.scratch_allocator, start);
    while (work.pop()) |p| {
        for (edges[starts[p]..starts[p + 1]]) |e| {
            if (tooSoon(bindings, e.to, k)) return e;
            if (bindings[e.to].defers and !seen[e.to]) {
                seen[e.to] = true;
                try touched.append(l.scratch_allocator, e.to);
                try work.append(l.scratch_allocator, e.to);
            }
        }
    }
    return null;
}

/// Whether reading binding `to` while binding `k` is being initialised
/// reads something that is not there: everything from `k` down is still
/// uninitialised, itself included, unless it is hoisted.
fn tooSoon(bindings: []const LetBinding, to: u32, k: u32) bool {
    return to >= k and !bindings[to].hoisted;
}

/// `p <- f a` with `rest` after it: `f a (\p -> rest)` (§6.7). The call is
/// lowered where it is written — outside the lambda, so a `?` in it belongs
/// to the enclosing definition — and `rest` is the lambda's body, which is
/// the only place `p` is in scope.
fn lowerBind(
    l: *Lower,
    bind: NodeIndex,
    rest: []const NodeIndex,
    body_node: NodeIndex,
) Allocator.Error!Index {
    const b = l.tree.fullLetPattern(bind);
    const bind_token = l.tree.nodeMainToken(bind);
    // Pipes rewrite before the bind does (§6.7, §8), so the callee and the
    // arguments in front of the callback are the ones the REWRITTEN chain
    // has: `x <- File.read path |> Task.mapError f` is
    // `Task.mapError (File.read path) f (\x -> rest)`.
    var arg_nodes: std.ArrayList(NodeIndex) = .empty;
    defer arg_nodes.deinit(l.scratch_allocator);
    const callee_node = try l.bindSpine(b.value, &arg_nodes);

    // The call is made where it is written: outside the callback, and with
    // the bindings below the `<-` not yet in scope (§7). They exist, so a
    // reference to one is `bind_rhs_forward_reference` rather than an
    // `unbound_variable` or, worse, a silent hit on a top-level name.
    var forward: std.ArrayList(Symbol) = .empty;
    defer forward.deinit(l.scratch_allocator);
    // An enclosing bind's forward set still applies: a bind nested in an
    // outer bind's right-hand side is lowered before the outer block's
    // later names come into scope, so they stay forward references here
    // too. Extend the list, never replace it.
    try forward.appendSlice(l.scratch_allocator, l.forward);
    try l.forwardNames(rest, &forward);
    const saved_forward = l.forward;
    l.forward = forward.items;
    const callee = try l.lowerExpr(callee_node);
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (arg_nodes.items) |arg| try l.pushScratch(try l.lowerExpr(arg));
    l.forward = saved_forward;

    const callback = try l.lowerCallback(bind_token, b.pattern, rest, body_node);
    try l.pushScratch(callback);
    l.cur_token = bind_token;
    return l.call(callee, l.scratchSince(mark));
}

/// The callee of a `<-` right-hand side, with its argument NODES appended to
/// `args` in the order the rewritten call has them (§6.7). Grouping
/// parentheses are looked through, an application contributes its own
/// arguments, `|>` contributes its operand at the FRONT of what its right
/// operand contributed, and `<|` contributes its operand at the back. A bare
/// name contributes nothing, which is `scope <- Task.scope`.
fn bindSpine(l: *Lower, node: NodeIndex, args: *std.ArrayList(NodeIndex)) Allocator.Error!NodeIndex {
    var n = node;
    while (l.tree.nodeTag(n) == .paren) n = l.tree.operand(n);
    switch (l.tree.nodeTag(n)) {
        .apply => {
            const app = l.tree.fullApply(n);
            try args.appendSlice(l.scratch_allocator, app.args);
            return app.function;
        },
        .pipe_right => {
            const b = l.tree.fullBinop(n);
            const start = args.items.len;
            const callee = try l.bindSpine(b.rhs, args);
            try args.insert(l.scratch_allocator, start, b.lhs);
            return callee;
        },
        .pipe_left => {
            const b = l.tree.fullBinop(n);
            const callee = try l.bindSpine(b.lhs, args);
            try args.append(l.scratch_allocator, b.rhs);
            return callee;
        },
        else => return n,
    }
}

/// The names the bindings after a `<-` introduce, in source order. They are
/// what the right-hand side may not mention (§7); the list is short and is
/// scanned linearly, like the scope stack next to it.
fn forwardNames(l: *Lower, rest: []const NodeIndex, names: *std.ArrayList(Symbol)) Allocator.Error!void {
    for (rest) |b| switch (l.tree.nodeTag(b)) {
        .let_def => try names.append(l.scratch_allocator, l.tokenSymbol(l.tree.nodeMainToken(b))),
        .let_pattern, .let_bind => try l.patternNames(l.tree.fullLetPattern(b).pattern, names),
        else => {},
    };
}

/// Every variable a pattern binds, appended to `names`.
fn patternNames(l: *Lower, pattern: NodeIndex, names: *std.ArrayList(Symbol)) Allocator.Error!void {
    switch (l.tree.nodeTag(pattern)) {
        .pat_var => try names.append(l.scratch_allocator, l.tokenSymbol(l.tree.nodeMainToken(pattern))),
        .pat_paren => try l.patternNames(l.tree.operand(pattern), names),
        .pat_as => {
            const a = l.tree.fullPatAs(pattern);
            try l.patternNames(a.pattern, names);
            if (l.tags[a.name] == .lower_ident) try names.append(l.scratch_allocator, l.tokenSymbol(a.name));
        },
        .pat_tuple, .pat_list => for (l.tree.children(pattern)) |child| try l.patternNames(child, names),
        .pat_spread => try l.patternNames(l.tree.operand(pattern), names),
        .pat_ctor => for (l.tree.children(pattern)) |child| try l.patternNames(child, names),
        .pat_cons => {
            const d = l.tree.nodeData(pattern);
            try l.patternNames(@enumFromInt(d.lhs), names);
            try l.patternNames(@enumFromInt(d.rhs), names);
        },
        .pat_record => for (l.tree.fullPatRecord(pattern).fields) |f| try names.append(l.scratch_allocator, l.tokenSymbol(f)),
        else => {},
    }
}

/// `\p -> rest`: the lambda a bind passes as the last argument. The pattern
/// is in scope in `rest` and nowhere else (§6.7), and `rest` is inside a
/// lambda, so a `?` in it is `question_in_lambda` exactly as the desugared
/// form says it is.
fn lowerCallback(
    l: *Lower,
    bind_token: TokenIndex,
    pattern: NodeIndex,
    rest: []const NodeIndex,
    body_node: NodeIndex,
) Allocator.Error!Index {
    const scope_mark = l.scope.items.len;
    const pat = try l.lowerPattern(pattern, scope_mark, .pattern);
    try l.frames.append(l.scratch_allocator, .{ .kind = .lambda, .inst = .none });
    const rest_expr = try l.lowerBindings(rest, body_node);
    _ = l.frames.pop();
    l.popScope(scope_mark);
    const params = try l.addRangeRecord(try l.addRange(&.{pat.int()}));
    return l.addInstAt(bind_token, .lambda, @intFromEnum(params), rest_expr.int());
}

/// The name token of the last `let_annotation` in `bindings`.
fn annotationToken(l: *const Lower, bindings: []const NodeIndex) TokenIndex {
    var i = bindings.len;
    while (i > 0) {
        i -= 1;
        if (l.tree.nodeTag(bindings[i]) == .let_annotation) return l.tree.nodeMainToken(bindings[i]);
    }
    unreachable; // only called when phase 2 left an annotation pending
}

/// Record fields to a range of `Field` pairs, with `duplicate_field` (§6.3).
fn lowerFields(l: *Lower, fields: []const NodeIndex) Allocator.Error!SubRange {
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    var names: FieldNames = .{};
    defer names.deinit(l.gpa);
    for (fields) |f| {
        if (l.tree.nodeTag(f) != .field) continue;
        const name_token = l.tree.nodeMainToken(f);
        const symbol = l.tokenSymbol(name_token);
        if (try names.seen(l.gpa, symbol)) try l.reportToken(.duplicate_field, name_token);
        const name = try l.addSymbol(symbol);
        const value = try l.lowerExpr(l.tree.operand(f));
        try l.pushScratch(name);
        try l.pushScratch(value);
    }
    return l.addRange(l.scratchSince(mark));
}

/// A string literal (§2.6): a `string` when it has no interpolation, else
/// an `interp` of `chunk`s and expressions. Escapes are decoded here. Both
/// are stamped with the literal's opening quote, so a diagnostic about the
/// literal starts there rather than at whatever its last part left.
fn lowerString(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const s = l.tree.fullString(node);
    var has_interp = false;
    for (s.parts) |p| {
        if (l.tree.nodeTag(p) == .interp) has_interp = true;
    }
    if (!has_interp) {
        const offset: u32 = @intCast(l.string_bytes.items.len);
        for (s.parts) |p| {
            if (l.tree.nodeTag(p) == .chunk) try decodeChunk(l.tokenText(l.tree.nodeMainToken(p)), l.gpa, &l.string_bytes);
        }
        return l.addInstAt(s.start_token, .string, offset, @as(u32, @intCast(l.string_bytes.items.len)) - offset);
    }
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (s.parts) |p| {
        switch (l.tree.nodeTag(p)) {
            .chunk => {
                const offset: u32 = @intCast(l.string_bytes.items.len);
                try decodeChunk(l.tokenText(l.tree.nodeMainToken(p)), l.gpa, &l.string_bytes);
                try l.pushScratch(try l.addInstAt(l.tree.nodeMainToken(p), .chunk, offset, @as(u32, @intCast(l.string_bytes.items.len)) - offset));
            },
            .interp => try l.pushScratch(try l.lowerExpr(l.tree.operand(p))),
            else => {},
        }
    }
    const range = try l.addRange(l.scratchSince(mark));
    return l.addInstAt(s.start_token, .interp, @intFromEnum(range.start), @intFromEnum(range.end));
}

// ---------------------------------------------------------------------------
// Markup (language.md §11, frontend.md §9.7)
// ---------------------------------------------------------------------------

/// A markup root: its tree, whose value instructions are lowered in source
/// order — items, then children, element by element, depth first — and
/// then the `markup` instruction that points at it.
fn lowerMarkup(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const open = l.tree.nodeMainToken(node);
    const root = try l.markupNode(node);
    l.uses_markup = true;
    return l.addInstAt(open, .markup, @intFromEnum(root), 0);
}

/// An element, fragment, component or form, as a node record.
fn markupNode(l: *Lower, node: NodeIndex) Allocator.Error!Bir.ExtraIndex {
    const mk = l.tree.fullMarkup(node);
    switch (l.tree.nodeTag(node)) {
        .markup_fragment => {
            const children = try l.markupChildren(mk.children);
            return l.addExtra(Bir.MarkupFragment{ .kind = .fragment, .token = mk.open, .children_start = children.start, .children_end = children.end });
        },
        .markup_for, .markup_show => return l.markupForm(node, mk),
        else => {
            const name = mk.name.?;
            if (std.ascii.isUpper(l.tokenText(name)[0])) return l.markupComponent(mk, name);
            const items = try l.markupItems(mk.attrs, name, false);
            const children = try l.markupChildren(mk.children);
            return l.addExtra(Bir.MarkupElement{
                .kind = .element,
                .token = name,
                .name = try l.addSymbol(l.tokenSymbol(name)),
                .items_start = items.items.start,
                .items_end = items.items.end,
                .children_start = children.start,
                .children_end = children.end,
            });
        },
    }
}

const Items = struct { items: SubRange, spread: Inst.OptionalIndex, children_token: ?TokenIndex };

/// The attribute names of one tag, each with the token that first wrote
/// it, for `duplicate_attribute`: a scan of the few a person writes, and a
/// map past `linear_limit`, so a generated tag of thousands costs n and
/// not n²/2. An element's names are compared as HTML reads them, ASCII
/// case folded (`fold`): `title` and `"TITLE"` are one attribute. A
/// component's are record fields, compared exactly.
const AttrNames = struct {
    const linear_limit = 16;

    fold: bool,
    few: [linear_limit]struct { []const u8, TokenIndex } = undefined,
    len: usize = 0,
    /// Every name, once there are more than `linear_limit`.
    map: std.HashMapUnmanaged([]const u8, TokenIndex, NameContext, std.hash_map.default_max_load_percentage) = .empty,

    const NameContext = struct {
        fold: bool,

        pub fn hash(c: NameContext, s: []const u8) u64 {
            if (!c.fold) return std.hash.Wyhash.hash(0, s);
            var h: std.hash.Wyhash = .init(0);
            for (s) |ch| h.update(&.{std.ascii.toLower(ch)});
            return h.final();
        }

        pub fn eql(c: NameContext, x: []const u8, y: []const u8) bool {
            return if (c.fold) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
        }
    };

    fn deinit(a: *AttrNames, gpa: Allocator) void {
        a.map.deinit(gpa);
    }

    /// Records `name`, written at `token`; the token that wrote it first
    /// when the tag already has it.
    fn first(a: *AttrNames, gpa: Allocator, name: []const u8, token: TokenIndex) Allocator.Error!?TokenIndex {
        const context: NameContext = .{ .fold = a.fold };
        if (a.len < linear_limit) {
            for (a.few[0..a.len]) |e| if (context.eql(e[0], name)) return e[1];
            a.few[a.len] = .{ name, token };
            a.len += 1;
            return null;
        }
        if (a.map.count() == 0) {
            for (a.few) |e| try a.map.putContext(gpa, e[0], e[1], context);
        }
        const entry = try a.map.getOrPutContext(gpa, name, context);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = token;
        return null;
    }
};

/// The attributes of an element (`component` false) or of a component, as
/// `MarkupItem` records in source order. `duplicate_attribute` for a name
/// written twice; a spread is a component's first attribute and nothing
/// else (`spread_on_element`, `spread_not_first`).
fn markupItems(l: *Lower, attrs: []const NodeIndex, tag_name: TokenIndex, component: bool) Allocator.Error!Items {
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    var seen: AttrNames = .{ .fold = !component };
    defer seen.deinit(l.scratch_allocator);
    var spread: Inst.OptionalIndex = .none;
    var children_token: ?TokenIndex = null;
    for (attrs, 0..) |attr, k| {
        switch (l.tree.nodeTag(attr)) {
            .markup_spread => {
                const open = l.tree.nodeMainToken(attr);
                const value = try l.lowerExpr(l.tree.operand(attr));
                if (!component) {
                    try l.reportMarkup(.spread_on_element, open, open + 1, tag_name, .none);
                } else if (k != 0 or spread != .none) {
                    try l.reportMarkup(.spread_not_first, open, open + 1, tag_name, .none);
                } else spread = value.toOptional();
            },
            .markup_attr, .markup_attr_escape => {
                const item = try l.markupItem(attr);
                const token = l.tree.nodeMainToken(attr);
                const name = l.symbols.items[@intFromEnum(item.name)];
                if (try seen.first(l.scratch_allocator, l.interner.slice(name), token)) |first| {
                    // A quoted name is reported whole, quotes included.
                    const last = if (l.tags[token] == .str_start) l.stringEnd(token) else token;
                    const first_last = if (l.tags[first] == .str_start) l.stringEnd(first) else first;
                    try l.diagnostics.append(l.gpa, .{
                        .code = .duplicate_attribute,
                        .start = l.starts[token],
                        .end = l.tokenEnd(last),
                        .other_start = l.starts[first],
                        .other_end = l.tokenEnd(first_last),
                    });
                }
                if (component and std.mem.eql(u8, l.interner.slice(name), "children")) children_token = token;
                try l.pushScratch(try l.addExtra(item));
            },
            else => {},
        }
    }
    return .{ .items = try l.addRange(l.scratchSince(mark)), .spread = spread, .children_token = children_token };
}

/// One `name`, `name="…"`, `name={e}` or `"name"=…` (language.md §11.5).
fn markupItem(l: *Lower, attr: NodeIndex) Allocator.Error!Bir.MarkupItem {
    var item: Bir.MarkupItem = .{
        .kind = .attr,
        .token = l.tree.nodeMainToken(attr),
        .name = .none,
        .form = .bare,
        .value = .none,
        .constant = .none,
        .constant_offset = 0,
        .constant_len = 0,
        .entries_start = @enumFromInt(0),
        .entries_end = @enumFromInt(0),
    };
    const a = l.tree.fullMarkupAttr(attr);
    if (a.name_string) |name_node| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(l.scratch_allocator);
        try l.stringText(name_node, &text);
        item.kind = .escape;
        item.name = try l.addSymbol(try l.interner.getOrPut(l.gpa, text.items));
        if (attributeNameFault(text.items)) |fault| {
            const token = l.tree.nodeMainToken(attr);
            try l.diagnostics.append(l.gpa, .{
                .code = .invalid_attribute_name,
                .start = l.starts[token],
                .end = l.tokenEnd(l.stringEnd(token)),
                .markup = fault,
            });
        }
    } else {
        item.name = try l.addSymbol(l.tokenSymbol(a.name));
    }
    try l.itemValue(&item, a.value, a.brace != null);
    return item;
}

/// Why the decoded text of a quoted attribute name cannot be one, or null
/// (language.md §11.5): a page ends a name at whitespace, a quote, `=`, `/`
/// or `>`, and what follows begins another attribute; a control character
/// has no place in one; and an empty name names nothing.
fn attributeNameFault(name: []const u8) ?Diagnostics.Item.Markup {
    if (name.len == 0) return .name_empty;
    for (name, 0..) |c, i| switch (c) {
        ' ', '\t', '\n', '\r', 0x0C => return .name_space,
        '"', '\'' => return .name_quote,
        '=' => return .name_equals,
        '/' => return .name_slash,
        '>' => return .name_gt,
        0x00...0x08, 0x0B, 0x0E...0x1F, 0x7F => return .name_control,
        // U+0080 to U+009F, the C1 controls.
        0xC2 => if (i + 1 < name.len and name[i + 1] >= 0x80 and name[i + 1] <= 0x9F) return .name_control,
        else => {},
    };
    return null;
}

/// An item's value: a constant, the instruction computing it, or both
/// (frontend.md §9.7).
fn itemValue(l: *Lower, item: *Bir.MarkupItem, value: ?NodeIndex, braced: bool) Allocator.Error!void {
    const v = value orelse {
        item.form = .bare;
        item.constant = .true;
        return;
    };
    if (braced) {
        item.form = .braced;
        const inst = try l.lowerExpr(v);
        item.value = inst.toOptional();
        const c = l.constantOf(v, inst);
        item.constant = c.constant;
        item.constant_offset = c.offset;
        item.constant_len = c.len;
        const entries = try l.listEntries(v, inst);
        item.entries_start = entries.start;
        item.entries_end = entries.end;
        return;
    }
    item.form = .quoted;
    if (l.tree.nodeTag(v) != .string) {
        item.value = (try l.lowerExpr(v)).toOptional();
        return;
    }
    const q = try l.quotedValue(v);
    if (q.inst) |inst| {
        item.value = inst.toOptional();
    } else {
        item.constant = .string;
        item.constant_offset = q.offset;
        item.constant_len = q.len;
    }
}

const Quoted = struct { inst: ?Index, offset: u32, len: u32 };

/// A quoted attribute value (language.md §11.5): a string whose literal
/// text also decodes character references. Without interpolation it is a
/// constant and lowers to no instruction; with one it is an `interp` whose
/// chunks are decoded, each on its own, so a reference never spans an
/// interpolation.
fn quotedValue(l: *Lower, node: NodeIndex) Allocator.Error!Quoted {
    const s = l.tree.fullString(node);
    var has_interp = false;
    for (s.parts) |p| {
        if (l.tree.nodeTag(p) == .interp) has_interp = true;
    }
    if (!has_interp) {
        const offset: u32 = @intCast(l.string_bytes.items.len);
        for (s.parts) |p| {
            if (l.tree.nodeTag(p) == .chunk) try decodeMarkupChunk(l.tokenText(l.tree.nodeMainToken(p)), l.gpa, &l.string_bytes);
        }
        return .{ .inst = null, .offset = offset, .len = @as(u32, @intCast(l.string_bytes.items.len)) - offset };
    }
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (s.parts) |p| {
        switch (l.tree.nodeTag(p)) {
            .chunk => {
                const offset: u32 = @intCast(l.string_bytes.items.len);
                try decodeMarkupChunk(l.tokenText(l.tree.nodeMainToken(p)), l.gpa, &l.string_bytes);
                try l.pushScratch(try l.addInstAt(l.tree.nodeMainToken(p), .chunk, offset, @as(u32, @intCast(l.string_bytes.items.len)) - offset));
            },
            .interp => try l.pushScratch(try l.lowerExpr(l.tree.operand(p))),
            else => {},
        }
    }
    const range = try l.addRange(l.scratchSince(mark));
    return .{ .inst = try l.addInstAt(s.start_token, .interp, @intFromEnum(range.start), @intFromEnum(range.end)), .offset = 0, .len = 0 };
}

/// A quoted value as a value instruction, where one is needed: a form's
/// attribute is an ordinary value.
fn quotedInst(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const q = try l.quotedValue(node);
    return q.inst orelse l.addInstAt(l.tree.nodeMainToken(node), .string, q.offset, q.len);
}

/// A string chunk of markup: escapes decoded as in any string, and the
/// literal text between them with its character references decoded, so a
/// character an escape produces never begins a reference (§11.5).
fn decodeMarkupChunk(text: []const u8, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const j = std.mem.indexOfScalarPos(u8, text, i, '\\') orelse text.len;
        try markup_entities.decode(gpa, out, text[i..j]);
        if (j == text.len) return;
        if (j + 1 >= text.len) {
            try out.append(gpa, '\\');
            return;
        }
        const decoded = decodeEscape(text[j..]);
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(decoded.scalar, &buf) catch blk: {
            buf[0..3].* = "\xEF\xBF\xBD".*;
            break :blk 3;
        };
        try out.appendSlice(gpa, buf[0..n]);
        i = j + decoded.len;
    }
}

const ConstantOf = struct { constant: Bir.Constant, offset: u32 = 0, len: u32 = 0 };

/// A hole holding only a constant (language.md §11.5): a number literal,
/// negated or not, as spelled; a string literal without interpolation, as
/// its text, undecoded; or the prelude's `True` or `False`.
fn constantOf(l: *Lower, node: NodeIndex, inst: Index) ConstantOf {
    const tags = l.insts.items(.tag);
    const datas = l.insts.items(.data);
    switch (l.tree.nodeTag(node)) {
        .int, .float => {
            const d = datas[inst.int()];
            return .{ .constant = .number, .offset = d.lhs, .len = d.rhs };
        },
        .negate => {
            const operand = l.tree.operand(node);
            switch (l.tree.nodeTag(operand)) {
                .int, .float => {},
                else => return .{ .constant = .none },
            }
            const offset: u32 = @intCast(l.string_bytes.items.len);
            l.string_bytes.append(l.gpa, '-') catch return .{ .constant = .none };
            l.string_bytes.appendSlice(l.gpa, l.tokenText(l.tree.nodeMainToken(operand))) catch return .{ .constant = .none };
            return .{ .constant = .number, .offset = offset, .len = @as(u32, @intCast(l.string_bytes.items.len)) - offset };
        },
        .string => {
            if (tags[inst.int()] != .string) return .{ .constant = .none };
            const d = datas[inst.int()];
            return .{ .constant = .string, .offset = d.lhs, .len = d.rhs };
        },
        .ctor => return .{ .constant = l.boolConstant(inst) },
        else => return .{ .constant = .none },
    }
}

/// `true` or `false` for a reference to the prelude's `True` or `False`.
fn boolConstant(l: *const Lower, inst: Index) Bir.Constant {
    if (l.insts.items(.tag)[inst.int()] != .import_ctor) return .none;
    const d = l.insts.items(.data)[inst.int()];
    if (l.symbols.items[d.lhs] != WellKnown.Basics.symbol()) return .none;
    const name = l.symbols.items[d.rhs];
    if (name == WellKnown.True.symbol()) return .true;
    if (name == WellKnown.False.symbol()) return .false;
    return .none;
}

/// The entries of a class or style list written in place: a list literal of
/// pair literals whose names are string literals without interpolation
/// (frontend.md §9.7). Empty for any other value.
fn listEntries(l: *Lower, node: NodeIndex, inst: Index) Allocator.Error!SubRange {
    const empty: SubRange = .{ .start = @enumFromInt(0), .end = @enumFromInt(0) };
    if (l.tree.nodeTag(node) != .list) return empty;
    const elems = l.tree.children(node);
    if (elems.len == 0) return empty;
    for (elems) |e| {
        if (l.tree.nodeTag(e) != .tuple or l.tree.children(e).len != 2) return empty;
        const first = l.tree.children(e)[0];
        if (l.tree.nodeTag(first) != .string) return empty;
        for (l.tree.fullString(first).parts) |p| if (l.tree.nodeTag(p) == .interp) return empty;
    }
    const datas = l.insts.items(.data);
    const list = Bir.inlineRange(datas[inst.int()]);
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (elems, @intFromEnum(list.start)..) |e, at| {
        const pair = Bir.inlineRange(datas[l.extra.items[at]]);
        const name_inst = l.extra.items[@intFromEnum(pair.start)];
        const value_inst: Index = @enumFromInt(l.extra.items[@intFromEnum(pair.start) + 1]);
        const second = l.tree.children(e)[1];
        const c: ConstantOf = switch (l.tree.nodeTag(second)) {
            .string, .ctor => l.constantOf(second, value_inst),
            else => .{ .constant = .none },
        };
        try l.pushScratch(try l.addExtra(Bir.MarkupEntry{
            .name_offset = datas[name_inst].lhs,
            .name_len = datas[name_inst].rhs,
            .constant = c.constant,
            .constant_offset = c.offset,
            .constant_len = c.len,
            .value = value_inst,
        }));
    }
    // The entries are records of their own; the range lists them.
    return l.addRange(l.scratchSince(mark));
}

/// The children of an element, fragment or component, as node records: a
/// text run that trims to nothing and an empty hole are no node.
fn markupChildren(l: *Lower, children: []const NodeIndex) Allocator.Error!SubRange {
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (children) |c| {
        switch (l.tree.nodeTag(c)) {
            .markup_text => if (try l.markupText(l.tree.nodeMainToken(c))) |e| try l.pushScratch(e),
            .markup_hole => {
                const open = l.tree.nodeMainToken(c);
                const value = try l.lowerExpr(l.tree.operand(c));
                try l.pushScratch(try l.addExtra(Bir.MarkupHole{ .kind = .hole, .token = open, .value = value }));
            },
            // One level of recursion per element, which the parser bounds
            // (frontend.md §9.4).
            .markup_element, .markup_fragment, .markup_for, .markup_show => try l.pushScratch(try l.markupNode(c)),
            else => {},
        }
    }
    return l.addRange(l.scratchSince(mark));
}

/// A text run as the page shows it (language.md §11.4), interned; null
/// when it trims to nothing.
fn markupText(l: *Lower, token: TokenIndex) Allocator.Error!?Bir.ExtraIndex {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(l.scratch_allocator);
    try markup_text.read(l.scratch_allocator, l.scratch_allocator, &out, l.tokenText(token));
    if (out.items.len == 0) return null;
    const text = try l.addSymbol(try l.interner.getOrPut(l.gpa, out.items));
    return try l.addExtra(Bir.MarkupText{ .kind = .text, .token = token, .text = text });
}

/// `<M.c a={x}>k</M.c>` (language.md §11.8): the callee, then the props,
/// then the children in the form `children` takes.
fn markupComponent(l: *Lower, mk: Ast.full.Markup, name: TokenIndex) Allocator.Error!Bir.ExtraIndex {
    const text = l.tokenText(name);
    const dot = std.mem.lastIndexOfScalar(u8, text, '.');
    // `Card.header` names that value; `Card` and `Ui.Card` a module's `view`.
    const member = if (dot) |d| std.ascii.isLower(text[d + 1]) else false;
    const module_text = if (member) text[0..dot.?] else text;
    const value_text = if (member) text[dot.? + 1 ..] else "view";
    const callee = try l.resolveModuleValue(name, module_text, value_text);
    const items = try l.markupItems(mk.attrs, name, true);
    const children = try l.markupChildren(mk.children);
    const form: Bir.ChildrenForm = if (children.len() == 0)
        .absent
    else if (children.len() == 1 and l.recordKind(l.extra.items[@intFromEnum(children.start)]) == .hole)
        .hole
    else
        .fragment;
    if (form != .absent) {
        if (items.children_token) |t| try l.reportMarkup(.duplicate_attribute, t, t, name, .children_twice);
    }
    return l.addExtra(Bir.MarkupComponent{
        .kind = .component,
        .token = name,
        .callee = callee,
        .props_start = items.items.start,
        .props_end = items.items.end,
        .spread = items.spread,
        .children_form = form,
        .children_start = children.start,
        .children_end = children.end,
    });
}

fn recordKind(l: *const Lower, index: u32) Bir.MarkupKind {
    return @enumFromInt(l.extra.items[index]);
}

/// `Module.value` spelled as two texts, resolved as a qualified name is
/// (§6.2): the component's callee.
fn resolveModuleValue(l: *Lower, token: TokenIndex, module_text: []const u8, name_text: []const u8) Allocator.Error!Index {
    l.cur_token = token;
    const module: Symbol = found: {
        if (l.importWithAlias(module_text)) |i| break :found l.importModule(i);
        for (prelude.modules) |w| {
            if (std.mem.eql(u8, @tagName(w), module_text)) break :found w.symbol();
        }
        try l.diagnostics.append(l.gpa, .{ .code = .unknown_module_alias, .start = l.starts[token], .end = l.tokenEnd(token), .markup = .component });
        return l.errorInst(.unbound_variable);
    };
    const name = try l.interner.getOrPut(l.gpa, name_text);
    return l.importRef(.qualified, .import_value, module, name);
}

/// `For` and `Show` (language.md §11.9, §11.18): their own attributes,
/// checked here, then the row.
fn markupForm(l: *Lower, node: NodeIndex, mk: Ast.full.Markup) Allocator.Error!Bir.ExtraIndex {
    const is_for = l.tree.nodeTag(node) == .markup_for;
    const form_name = mk.name.?;
    var record: Bir.MarkupForm = .{
        .kind = if (is_for) .@"for" else .show,
        .token = form_name,
        .list = .none,
        .keyed = .none,
        .fallback = .none,
        .mode = .absent,
        .row = Bir.none_extra,
    };
    var list_token: ?TokenIndex = null;
    var keyed_token: ?TokenIndex = null;
    var fallback_token: ?TokenIndex = null;
    // What a `Show` that says nothing about remounting would be as a
    // `case`, which its message writes out: the braces of `when` and
    // `fallback`, and the span of `keyed={False}`.
    var when_brace: ?TokenIndex = null;
    var fallback_brace: ?TokenIndex = null;
    var keyed_false: ?[2]TokenIndex = null;
    for (mk.attrs) |attr| {
        switch (l.tree.nodeTag(attr)) {
            .markup_spread => {
                const open = l.tree.nodeMainToken(attr);
                _ = try l.lowerExpr(l.tree.operand(attr));
                try l.reportMarkup(.spread_on_element, open, open + 1, form_name, .none);
            },
            .markup_attr_escape => {
                const t = l.tree.nodeMainToken(attr);
                try l.reportMarkup(.unknown_form_attribute, t, l.stringEnd(t), form_name, .none);
            },
            .markup_attr => {
                const a = l.tree.fullMarkupAttr(attr);
                const text = l.tokenText(a.name);
                const list_word = if (is_for) "each" else "when";
                const slot: *?TokenIndex = if (std.mem.eql(u8, text, list_word))
                    &list_token
                else if (std.mem.eql(u8, text, "keyed"))
                    &keyed_token
                else if (std.mem.eql(u8, text, "fallback"))
                    &fallback_token
                else {
                    try l.reportMarkup(.unknown_form_attribute, a.name, a.name, form_name, .none);
                    continue;
                };
                if (slot.*) |first| {
                    try l.reportPair(.duplicate_attribute, a.name, first);
                    continue;
                }
                slot.* = a.name;
                if (slot == &keyed_token) {
                    keyed_false = try l.formKeyed(&record, a, is_for, form_name);
                    continue;
                }
                if (slot == &list_token) when_brace = a.brace else fallback_brace = a.brace;
                const inst = try l.formValue(a);
                if (slot == &list_token) record.list = inst.toOptional() else record.fallback = inst.toOptional();
            },
            else => {},
        }
    }
    if (list_token == null) try l.reportMarkup(.missing_form_attribute, form_name, form_name, form_name, if (is_for) .missing_each else .missing_when);

    // Its only child is one hole holding the row function. Whitespace around
    // it is layout, not a child: a form renders nothing but its row.
    var hole: ?NodeIndex = null;
    var offending: ?TokenIndex = null;
    for (mk.children) |c| {
        switch (l.tree.nodeTag(c)) {
            .markup_empty_hole => {},
            .markup_text => {
                const text = l.tokenText(l.tree.nodeMainToken(c));
                var i: usize = 0;
                while (i < text.len) {
                    const n = markup_text.whitespaceAt(text, i);
                    if (n == 0) break;
                    i += n;
                }
                if (i < text.len and offending == null) offending = l.tree.nodeMainToken(c);
            },
            .markup_hole => {
                if (hole != null) {
                    if (offending == null) offending = l.tree.nodeMainToken(c);
                } else hole = c;
            },
            else => if (offending == null) {
                offending = l.tree.nodeMainToken(c);
            },
        }
    }
    if (offending) |t| {
        try l.reportMarkup(.invalid_form_children, t, t, form_name, .none);
    } else if (hole) |h| {
        record.row = @intFromEnum(try l.lowerRow(l.tree.operand(h)));
    } else {
        try l.reportMarkup(.invalid_form_children, form_name, form_name, form_name, .none);
    }
    // A `Show` that does not say when it remounts: the message writes the
    // `case` it would be, from the program's own `when`, body and
    // `fallback`, so both are reported once all three are known.
    if (!is_for) {
        const body_brace: ?TokenIndex = if (offending == null) if (hole) |h| l.tree.nodeMainToken(h) else null else null;
        if (keyed_false) |span| {
            try l.reportShowCase(.invalid_keyed, span[0], span[1], form_name, .keyed_false_on_show, when_brace, body_brace, fallback_brace);
        } else if (keyed_token == null) {
            try l.reportShowCase(.missing_form_attribute, form_name, form_name, form_name, .missing_keyed, when_brace, body_brace, fallback_brace);
        }
    }
    return l.addExtra(record);
}

/// `reportMarkup` with the text inside the braces of a `Show`'s `when`,
/// body and `fallback`, each empty when it is not written in braces.
fn reportShowCase(l: *Lower, code: diagnostic.Code, first: TokenIndex, last: TokenIndex, tag_name: TokenIndex, detail: Diagnostics.Item.Markup, when: ?TokenIndex, body: ?TokenIndex, fallback: ?TokenIndex) Allocator.Error!void {
    const w = if (when) |t| l.braceInner(t) else [2]u32{ 0, 0 };
    const b = if (body) |t| l.braceInner(t) else [2]u32{ 0, 0 };
    const f = if (fallback) |t| l.braceInner(t) else [2]u32{ 0, 0 };
    try l.diagnostics.append(l.gpa, .{
        .code = code,
        .start = l.starts[first],
        .end = l.tokenEnd(last),
        .other_start = l.starts[tag_name],
        .other_end = l.tokenEnd(tag_name),
        .markup = detail,
        .when_start = w[0],
        .when_end = w[1],
        .body_start = b[0],
        .body_end = b[1],
        .fallback_start = f[0],
        .fallback_end = f[1],
    });
}

/// The source bytes between the brace `open` and the `}` that closes it,
/// from the first token inside to the last; empty when there is none.
fn braceInner(l: *const Lower, open: TokenIndex) [2]u32 {
    var depth: u32 = 0;
    var t = open + 1;
    while (t < l.tags.len) : (t += 1) switch (l.tags[t]) {
        .l_brace => depth += 1,
        .r_brace => if (depth == 0) break else {
            depth -= 1;
        },
        .eof => return .{ 0, 0 },
        else => {},
    };
    if (t == open + 1 or t >= l.tags.len) return .{ 0, 0 };
    return .{ l.starts[open + 1], l.tokenEnd(t - 1) };
}

/// `keyed`: bare or `{True}` is by reference (by identity for `Show`),
/// `{False}` by position, any other expression a key function; a quoted
/// value, another constant, or `{False}` on `Show` is `invalid_keyed`. The
/// last is returned, as the tokens it spans, for `markupForm` to report.
fn formKeyed(l: *Lower, record: *Bir.MarkupForm, a: Ast.full.MarkupAttr, is_for: bool, form_name: TokenIndex) Allocator.Error!?[2]TokenIndex {
    const value = a.value orelse {
        record.mode = .literal_true;
        return null;
    };
    if (a.brace == null) {
        try l.reportMarkup(.invalid_keyed, a.name, l.lastToken(value), form_name, .none);
        return null;
    }
    const inst = try l.lowerExpr(value);
    record.keyed = inst.toOptional();
    switch (l.constantOf(value, inst).constant) {
        .true => record.mode = .literal_true,
        .false => {
            record.mode = .literal_false;
            if (!is_for) return .{ a.name, l.lastToken(value) + 1 };
        },
        .string, .number => try l.reportMarkup(.invalid_keyed, a.name, l.lastToken(value) + 1, form_name, .none),
        .none => record.mode = .key_function,
    }
    return null;
}

/// A form's `each`, `when` or `fallback`: an ordinary value, whatever its
/// spelling.
fn formValue(l: *Lower, a: Ast.full.MarkupAttr) Allocator.Error!Index {
    const value = a.value orelse {
        l.cur_token = a.name;
        return l.importRef(.import_ctor, .import_ctor, WellKnown.Basics.symbol(), WellKnown.True.symbol());
    };
    if (a.brace == null and l.tree.nodeTag(value) == .string) return l.quotedInst(value);
    return l.lowerExpr(value);
}

/// The last token of a constant's node — a string, a number negated or
/// not, a constructor — for a span.
fn lastToken(l: *const Lower, node: NodeIndex) TokenIndex {
    return switch (l.tree.nodeTag(node)) {
        .string => l.stringEnd(l.tree.nodeMainToken(node)),
        .negate => l.tree.nodeMainToken(l.tree.operand(node)),
        else => l.tree.nodeMainToken(node),
    };
}

/// Report a markup lowering diagnostic spanning tokens `first..last`, with
/// the tag's name as the second range.
fn reportMarkup(l: *Lower, code: diagnostic.Code, first: TokenIndex, last: TokenIndex, tag_name: TokenIndex, detail: Diagnostics.Item.Markup) Allocator.Error!void {
    try l.diagnostics.append(l.gpa, .{
        .code = code,
        .start = l.starts[first],
        .end = l.tokenEnd(last),
        .other_start = l.starts[tag_name],
        .other_end = l.tokenEnd(tag_name),
        .markup = detail,
    });
}

/// A `For` row or a `Show` body (frontend.md §9.7): the function's
/// instructions, then its shape. The captures and inputs of a lambda are
/// computed by `finishRows`, once every declaration is lowered.
fn lowerRow(l: *Lower, node: NodeIndex) Allocator.Error!Bir.ExtraIndex {
    const first: u32 = @intCast(l.insts.len);
    const function = try l.lowerExpr(node);
    const tags = l.insts.items(.tag);
    const datas = l.insts.items(.data);
    var shape: Bir.RowShape = .function;
    var body: Inst.OptionalIndex = .none;
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    if (tags[function.int()] == .lambda) {
        shape = .lambda;
        var at = datas[function.int()].rhs;
        while (tags[at] == .let) {
            try l.pushScratch(at);
            at = datas[at].rhs;
        }
        if (tags[at] == .markup) {
            shape = .markup;
            body = @enumFromInt(at);
        } else l.shrinkScratch(mark);
    }
    const lets = try l.addRange(l.scratchSince(mark));
    const row = try l.addExtra(Bir.MarkupRow{
        .function = function,
        .shape = shape,
        .body = body,
        .lets_start = lets.start,
        .lets_end = lets.end,
        .captures_start = @enumFromInt(0),
        .captures_end = @enumFromInt(0),
        .inputs_start = @enumFromInt(0),
        .inputs_end = @enumFromInt(0),
    });
    if (shape != .function) try l.rows.append(l.scratch_allocator, .{ .row = row, .decl = l.cur_decl, .first = first, .function = function.int() });
    return row;
}

// ---- A row's captures and inputs (language.md §11.9, frontend.md §9.7) ----
//
// The captures of a row lambda are the locals of its declaration that it
// uses and does not bind, in first-use order. Its inputs are, per capture,
// the field paths through which it reads the local — a chain of field
// accesses and tuple indices, cut to four links — or the local itself when
// some use is anything else. A use as argument `i` of a call of a top-level
// function of this file contributes that function's summary for parameter
// `i`: the paths its body reads the parameter through, by the same rule, a
// record pattern `{ a }` being the path `a`. Summaries are computed only
// for the functions rows reach, iterated from the empty set to a fixpoint,
// which ends because the sets only grow and are finite.

/// A field path: `len` links, each a field's symbol or a tuple index with
/// `Bir.tuple_link` set; none is the local itself.
const Path = struct {
    len: u8 = 0,
    links: [Bir.max_input_links]u32 = @splat(0),

    fn prefixOf(a: Path, b: Path) bool {
        return a.len <= b.len and std.mem.eql(u32, a.links[0..a.len], b.links[0..a.len]);
    }

    fn eql(a: Path, b: Path) bool {
        return a.len == b.len and std.mem.eql(u32, a.links[0..a.len], b.links[0..a.len]);
    }

    fn append(p: Path, link: u32) Path {
        var r = p;
        if (r.len < Bir.max_input_links) {
            r.links[r.len] = link;
            r.len += 1;
        }
        return r;
    }

    fn concat(p: Path, q: Path) Path {
        var r = p;
        for (q.links[0..q.len]) |k| r = r.append(k);
        return r;
    }
};

/// Paths kept minimal and in first-use order: one with a prefix in the set
/// adds nothing, and one that is a prefix of others replaces them.
const Paths = struct {
    list: std.ArrayList(Path) = .empty,

    fn add(s: *Paths, gpa: Allocator, p: Path) Allocator.Error!void {
        for (s.list.items) |q| if (q.prefixOf(p)) return;
        var i: usize = 0;
        var placed = false;
        while (i < s.list.items.len) {
            if (p.prefixOf(s.list.items[i])) {
                if (!placed) {
                    s.list.items[i] = p;
                    placed = true;
                    i += 1;
                } else _ = s.list.orderedRemove(i);
            } else i += 1;
        }
        if (!placed) try s.list.append(gpa, p);
    }

    fn sameAs(a: Paths, b: Paths) bool {
        if (a.list.items.len != b.list.items.len) return false;
        for (a.list.items) |p| {
            for (b.list.items) |q| {
                if (p.eql(q)) break;
            } else return false;
        }
        return true;
    }
};

/// Where an instruction is an operand: its parent and the operand's
/// position, `callee` then arguments for a `call`, the target for an access.
const Parent = struct { inst: u32 = none_u32, pos: u32 = 0 };

const Summary = struct { params: []Paths };

const RowAnalysis = struct {
    l: *Lower,
    /// Per declaration, the parent of each of its instructions.
    parents: std.AutoHashMapUnmanaged(u32, []Parent) = .empty,
    /// Per function reached, its parameters' summaries, in the order they
    /// were reached.
    summaries: std.AutoArrayHashMapUnmanaged(u32, Summary) = .empty,

    fn gpa(a: *RowAnalysis) Allocator {
        return a.l.scratch_allocator;
    }

    fn deinit(a: *RowAnalysis) void {
        var it = a.parents.valueIterator();
        while (it.next()) |p| a.gpa().free(p.*);
        a.parents.deinit(a.gpa());
        for (a.summaries.values()) |s| freeParams(a.gpa(), s.params);
        a.summaries.deinit(a.gpa());
    }

    fn freeParams(gpa_: Allocator, params: []Paths) void {
        for (params) |*p| p.list.deinit(gpa_);
        gpa_.free(params);
    }

    fn parentsOf(a: *RowAnalysis, decl: u32) Allocator.Error![]Parent {
        if (a.parents.get(decl)) |p| return p;
        const d = a.l.decls.items[decl];
        const base = d.inst_start.int();
        const map = try a.gpa().alloc(Parent, d.inst_end.int() - base);
        @memset(map, .{});
        var operands: std.ArrayList(u32) = .empty;
        defer operands.deinit(a.gpa());
        var i = base;
        while (i < d.inst_end.int()) : (i += 1) {
            operands.clearRetainingCapacity();
            try a.l.operandsOf(i, &operands, a.gpa());
            for (operands.items, 0..) |o, pos| {
                if (o >= base and o < d.inst_end.int()) map[o - base] = .{ .inst = i, .pos = @intCast(pos) };
            }
        }
        try a.parents.put(a.gpa(), decl, map);
        return map;
    }

    /// The summary of function `decl`, registered (empty) the first time it
    /// is asked for; the fixpoint fills it.
    fn summaryOf(a: *RowAnalysis, decl: u32) Allocator.Error!Summary {
        const gop = try a.summaries.getOrPut(a.gpa(), decl);
        if (!gop.found_existing) {
            const params = try a.gpa().alloc(Paths, a.l.decls.items[decl].params);
            for (params) |*p| p.* = .{};
            gop.value_ptr.* = .{ .params = params };
        }
        return gop.value_ptr.*;
    }

    /// Add to `out` the paths use `u` (a `local` instruction of `decl`)
    /// reads its local through.
    fn pathsOfUse(a: *RowAnalysis, decl: u32, u: u32, out: *Paths) Allocator.Error!void {
        const l = a.l;
        const tags = l.insts.items(.tag);
        const datas = l.insts.items(.data);
        const parents = try a.parentsOf(decl);
        const base = l.decls.items[decl].inst_start.int();
        var path: Path = .{};
        var cur = u;
        while (true) {
            const p = parents[cur - base];
            if (p.inst == none_u32 or p.pos != 0) break;
            switch (tags[p.inst]) {
                .field_access => path = path.append(@intFromEnum(l.symbols.items[datas[p.inst].rhs])),
                .tuple_index => path = path.append(@min(datas[p.inst].rhs, Bir.tuple_link - 1) | Bir.tuple_link),
                else => break,
            }
            cur = p.inst;
        }
        const p = parents[cur - base];
        if (p.inst != none_u32 and tags[p.inst] == .call and p.pos >= 1) {
            const callee = datas[p.inst].lhs;
            if (tags[callee] == .top) {
                const f = datas[callee].lhs;
                const fd = l.decls.items[f];
                if (fd.kind == .value and p.pos - 1 < fd.params) {
                    const summary = try a.summaryOf(f);
                    for (summary.params[p.pos - 1].list.items) |q| try out.add(a.gpa(), path.concat(q));
                    return;
                }
            }
        }
        try out.add(a.gpa(), path);
    }

    /// Function `decl`'s parameter summaries from its body and the current
    /// summaries of what it calls.
    fn computeSummary(a: *RowAnalysis, decl: u32) Allocator.Error![]Paths {
        const l = a.l;
        const d = l.decls.items[decl];
        const tags = l.insts.items(.tag);
        const datas = l.insts.items(.data);
        const params = l.extra.items[@intFromEnum(d.params_start)..@intFromEnum(d.params_end)];
        const out = try a.gpa().alloc(Paths, params.len);
        for (out, params) |*paths, param| {
            paths.* = .{};
            switch (tags[param]) {
                .pat_record => {
                    const locals = Bir.inlineRange(datas[param]);
                    for (l.extra.items[@intFromEnum(locals.start)..@intFromEnum(locals.end)]) |local| {
                        const name = l.locals.items[d.locals_start + local].name;
                        try paths.add(a.gpa(), (Path{}).append(@intFromEnum(l.symbols.items[@intFromEnum(name)])));
                    }
                },
                .pat_var => {
                    const local = datas[param].lhs;
                    var i = d.inst_start.int();
                    while (i < d.inst_end.int()) : (i += 1) {
                        if (tags[i] == .local and datas[i].lhs == local) try a.pathsOfUse(decl, i, paths);
                    }
                },
                else => try paths.add(a.gpa(), .{}),
            }
        }
        return out;
    }

    /// Recompute every summary reached until none changes.
    fn fixpoint(a: *RowAnalysis) Allocator.Error!bool {
        var changed = false;
        var k: usize = 0;
        while (k < a.summaries.count()) : (k += 1) {
            const decl = a.summaries.keys()[k];
            const next = try a.computeSummary(decl);
            const current = a.summaries.values()[k];
            for (next, current.params) |n, c| {
                if (!n.sameAs(c)) changed = true;
            }
            a.summaries.values()[k] = .{ .params = next };
            freeParams(a.gpa(), current.params);
        }
        return changed;
    }
};

/// Fill every row's captures and inputs (see above).
fn finishRows(l: *Lower) Allocator.Error!void {
    var a: RowAnalysis = .{ .l = l };
    defer a.deinit();
    // Reach every function the rows' uses call, then iterate.
    for (l.rows.items) |row| {
        var sink: Paths = .{};
        defer sink.list.deinit(l.scratch_allocator);
        var i = row.first;
        while (i <= row.function) : (i += 1) {
            if (l.insts.items(.tag)[i] == .local) try a.pathsOfUse(row.decl, i, &sink);
        }
    }
    while (try a.fixpoint()) {}

    const tags = l.insts.items(.tag);
    const datas = l.insts.items(.data);
    for (l.rows.items) |row| {
        const d = l.decls.items[row.decl];
        var captures: std.ArrayList(u32) = .empty;
        defer captures.deinit(l.scratch_allocator);
        var i = row.first;
        while (i <= row.function) : (i += 1) {
            if (tags[i] != .local) continue;
            const local = datas[i].lhs;
            const binder = l.locals.items[d.locals_start + local].inst.int();
            if (binder >= row.first and binder <= row.function) continue;
            if (std.mem.indexOfScalar(u32, captures.items, local) == null) try captures.append(l.scratch_allocator, local);
        }
        const capture_range = try l.addRange(captures.items);
        const inputs_start: u32 = @intCast(l.extra.items.len);
        for (captures.items) |local| {
            var paths: Paths = .{};
            defer paths.list.deinit(l.scratch_allocator);
            i = row.first;
            while (i <= row.function) : (i += 1) {
                if (tags[i] == .local and datas[i].lhs == local) try a.pathsOfUse(row.decl, i, &paths);
            }
            for (paths.list.items) |p| {
                var links: [Bir.max_input_links]u32 = @splat(0);
                for (p.links[0..p.len], 0..) |k, n| {
                    links[n] = if (k & Bir.tuple_link != 0) k else @intFromEnum(try l.addSymbol(@enumFromInt(k)));
                }
                _ = try l.addExtra(Bir.MarkupInput{ .local = local, .len = p.len, .link0 = links[0], .link1 = links[1], .link2 = links[2], .link3 = links[3] });
            }
        }
        const at = @intFromEnum(row.row);
        l.extra.items[at + 5] = @intFromEnum(capture_range.start);
        l.extra.items[at + 6] = @intFromEnum(capture_range.end);
        l.extra.items[at + 7] = inputs_start;
        l.extra.items[at + 8] = @intCast(l.extra.items.len);
    }
}

/// The instructions `inst` has as operands, in position order: a `call`'s
/// callee then its arguments, an access's target, a markup tree's values.
/// Types are left out: no local is ever in one.
fn operandsOf(l: *const Lower, inst: u32, out: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!void {
    const tags = l.insts.items(.tag);
    const d = l.insts.items(.data)[inst];
    const extra = l.extra.items;
    switch (tags[inst]) {
        .tuple, .list, .interp, .pat_tuple, .pat_list => try out.appendSlice(gpa, extra[d.lhs..d.rhs]),
        .record => {
            var f = d.lhs;
            while (f < d.rhs) : (f += 2) try out.append(gpa, extra[f + 1]);
        },
        .record_update => {
            try out.append(gpa, d.lhs);
            var f = extra[d.rhs];
            while (f < extra[d.rhs + 1]) : (f += 2) try out.append(gpa, extra[f + 1]);
        },
        .field_access, .tuple_index, .@"try", .pat_as, .pat_spread => try out.append(gpa, d.lhs),
        .call, .pat_ctor => {
            try out.append(gpa, d.lhs);
            try out.appendSlice(gpa, extra[extra[d.rhs]..extra[d.rhs + 1]]);
        },
        .method_call => {
            try out.append(gpa, d.lhs);
            const m = extraAt(extra, d.rhs, Bir.MethodCall);
            try out.appendSlice(gpa, extra[@intFromEnum(m.args_start)..@intFromEnum(m.args_end)]);
        },
        .type_dispatch => {
            const t = extraAt(extra, d.rhs, Bir.TypeDispatch);
            try out.appendSlice(gpa, extra[@intFromEnum(t.args_start)..@intFromEnum(t.args_end)]);
        },
        .lambda, .let => {
            try out.appendSlice(gpa, extra[extra[d.lhs]..extra[d.lhs + 1]]);
            try out.append(gpa, d.rhs);
        },
        .let_def => {
            const def = extraAt(extra, d.lhs, Bir.LetDef);
            try out.appendSlice(gpa, extra[@intFromEnum(def.params_start)..@intFromEnum(def.params_end)]);
            try out.append(gpa, d.rhs);
        },
        .case => {
            try out.append(gpa, d.lhs);
            try out.appendSlice(gpa, extra[extra[d.rhs]..extra[d.rhs + 1]]);
        },
        .let_pattern, .branch => {
            try out.append(gpa, d.lhs);
            try out.append(gpa, d.rhs);
        },
        .markup => try l.markupOperands(d.lhs, out, gpa),
        else => {},
    }
}

/// The value instructions of the markup tree rooted at record `at`, in
/// source order.
fn markupOperands(l: *const Lower, at: u32, out: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!void {
    const extra = l.extra.items;
    switch (@as(Bir.MarkupKind, @enumFromInt(extra[at]))) {
        .element => {
            const e = extraAt(extra, at, Bir.MarkupElement);
            try l.itemOperands(e.items_start, e.items_end, out, gpa);
            for (extra[@intFromEnum(e.children_start)..@intFromEnum(e.children_end)]) |c| try l.markupOperands(c, out, gpa);
        },
        .fragment => {
            const f = extraAt(extra, at, Bir.MarkupFragment);
            for (extra[@intFromEnum(f.children_start)..@intFromEnum(f.children_end)]) |c| try l.markupOperands(c, out, gpa);
        },
        .text => {},
        .hole => try out.append(gpa, extraAt(extra, at, Bir.MarkupHole).value.int()),
        .component => {
            const c = extraAt(extra, at, Bir.MarkupComponent);
            try out.append(gpa, c.callee.int());
            if (c.spread.unwrap()) |s| try out.append(gpa, s.int());
            try l.itemOperands(c.props_start, c.props_end, out, gpa);
            for (extra[@intFromEnum(c.children_start)..@intFromEnum(c.children_end)]) |ch| try l.markupOperands(ch, out, gpa);
        },
        .@"for", .show => {
            const f = extraAt(extra, at, Bir.MarkupForm);
            for ([_]Inst.OptionalIndex{ f.list, f.keyed, f.fallback }) |v| {
                if (v.unwrap()) |i| try out.append(gpa, i.int());
            }
            if (f.row != Bir.none_extra) try out.append(gpa, extraAt(extra, f.row, Bir.MarkupRow).function.int());
        },
    }
}

fn itemOperands(l: *const Lower, start: Bir.ExtraIndex, end: Bir.ExtraIndex, out: *std.ArrayList(u32), gpa: Allocator) Allocator.Error!void {
    const extra = l.extra.items;
    for (extra[@intFromEnum(start)..@intFromEnum(end)]) |at| {
        const item = extraAt(extra, at, Bir.MarkupItem);
        if (item.value.unwrap()) |v| try out.append(gpa, v.int());
    }
}

/// Read a record out of `extra` at `index`, field by field, as
/// `Bir.extraData` does once the arrays are frozen.
fn extraAt(extra: []const u32, index: u32, comptime T: type) T {
    var result: T = undefined;
    inline for (std.meta.fields(T), 0..) |field, k| {
        @field(result, field.name) = switch (@typeInfo(field.type)) {
            .@"enum" => @enumFromInt(extra[index + k]),
            .int => extra[index + k],
            else => @compileError("unexpected extra field type: " ++ @typeName(field.type)),
        };
    }
    return result;
}

// ---------------------------------------------------------------------------
// Patterns
// ---------------------------------------------------------------------------

/// Lower a pattern, binding its variables into the current scope as
/// locals of `kind` (`param` for a bare parameter name; variables nested
/// in a destructuring pattern are `pattern` locals). `set_start` marks the
/// start of the pattern set duplicates are checked against.
fn lowerPattern(l: *Lower, node: NodeIndex, set_start: usize, kind: Bir.Local.Kind) Allocator.Error!Index {
    l.cur_token = l.tree.nodeMainToken(node);
    const tag = l.tree.nodeTag(node);
    const main_token = l.tree.nodeMainToken(node);
    const data = l.tree.nodeData(node);
    switch (tag) {
        .pat_wild => return l.addInst(.pat_wild, 0, 0),
        .pat_var => {
            const inst = try l.reserveInst(.pat_var);
            const local = try l.bindVar(main_token, set_start, kind, inst);
            l.setInstData(inst, local, Inst.Data.unused);
            return inst;
        },
        .pat_ctor => {
            const pc = l.tree.fullPatCtor(node);
            const ref = switch (l.tags[pc.name]) {
                .qualified_upper => if (l.couldBeSchemaQualified(pc.name))
                    try l.schemaNamespaceRef(pc.name, .schema_ctor_ref)
                else
                    try l.resolveQualified(pc.name, .qualified_ctor, .import_ctor, .unbound_constructor),
                else => try l.resolveCtor(pc.name),
            };
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (pc.args) |arg| try l.pushScratch(try l.lowerPattern(arg, set_start, .pattern));
            const args = try l.addRangeRecord(try l.addRange(l.scratchSince(mark)));
            // Stamped with the CONSTRUCTOR's token, not with whatever the
            // last argument left in `cur_token`: every diagnostic about a
            // constructor pattern — its arity (checker.md §8.3), its type,
            // its redundancy (§6.6) — is about the pattern as a whole, and
            // its name is where a reader looks for it.
            return l.addInstAt(pc.name, .pat_ctor, ref.int(), @intFromEnum(args));
        },
        .pat_int => {
            const text = try l.addBytes(l.tokenText(main_token));
            return l.addInst(.pat_int, text[0], text[1]);
        },
        .pat_neg_int => {
            const offset: u32 = @intCast(l.string_bytes.items.len);
            try l.string_bytes.append(l.gpa, '-');
            if (main_token + 1 < l.tags.len and l.tags[main_token + 1] == .int) {
                try l.string_bytes.appendSlice(l.gpa, l.tokenText(main_token + 1));
            }
            return l.addInst(.pat_int, offset, @as(u32, @intCast(l.string_bytes.items.len)) - offset);
        },
        .pat_char => return l.addInst(.pat_char, decodeChar(l.tokenText(main_token)), Inst.Data.unused),
        .pat_string => {
            const offset: u32 = @intCast(l.string_bytes.items.len);
            var t = main_token + 1;
            while (t < l.tags.len and l.tags[t] != .str_end and l.tags[t] != .eof) : (t += 1) {
                if (l.tags[t] == .str_chunk) try decodeChunk(l.tokenText(t), l.gpa, &l.string_bytes);
            }
            return l.addInst(.pat_string, offset, @as(u32, @intCast(l.string_bytes.items.len)) - offset);
        },
        .pat_unit => return l.addInst(.pat_unit, 0, 0),
        .pat_paren => return l.lowerPattern(l.tree.operand(node), set_start, kind),
        .pat_tuple, .pat_list => {
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (l.tree.children(node)) |elem| try l.pushScratch(try l.lowerPattern(elem, set_start, .pattern));
            const range = try l.addRange(l.scratchSince(mark));
            return l.addInst(if (tag == .pat_tuple) .pat_tuple else .pat_list, @intFromEnum(range.start), @intFromEnum(range.end));
        },
        .pat_record => {
            const pr = l.tree.fullPatRecord(node);
            const inst = try l.reserveInst(.pat_record);
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (pr.fields) |field_token| try l.pushScratch(try l.bindVar(field_token, set_start, .pattern, inst));
            const range = try l.addRange(l.scratchSince(mark));
            l.setInstData(inst, @intFromEnum(range.start), @intFromEnum(range.end));
            return inst;
        },
        // A `::` pattern: `cons_removed`, reported by the parser. Its
        // names are still bound — to nothing, so a body that reads them is
        // poisoned rather than full of `unbound_variable`s.
        .pat_cons => {
            _ = try l.lowerPattern(@enumFromInt(data.lhs), set_start, .pattern);
            _ = try l.lowerPattern(@enumFromInt(data.rhs), set_start, .pattern);
            return l.errorInst(.cons_removed);
        },
        .pat_spread => {
            const operand = try l.lowerPattern(l.tree.operand(node), set_start, .pattern);
            return l.addInstAt(main_token, .pat_spread, operand.int(), Inst.Data.unused);
        },
        .pat_as => {
            const pa = l.tree.fullPatAs(node);
            const inner = try l.lowerPattern(pa.pattern, set_start, .pattern);
            const inst = try l.reserveInst(.pat_as);
            const local = try l.bindVar(pa.name, set_start, .pattern, inst);
            l.setInstData(inst, inner.int(), local);
            return inst;
        },
        // Only a `<-` right-hand side can hold one (§6.7); the parser has
        // reported it as `placeholder_outside_argument` already.
        .placeholder => return l.errorInst(.placeholder_outside_argument),
        else => {
            std.debug.assert(tag.isError());
            return l.errorInst(l.tree.fullError(node).code);
        },
    }
}

// ---------------------------------------------------------------------------
// Literal decoding (§2.6, §2.8). The lexer has validated every escape; the
// decoders still accept anything, copying what they do not understand, so
// no input reaches a panic.
// ---------------------------------------------------------------------------

/// Decode the escapes of one `str_chunk` onto `out`.
fn decodeChunk(text: []const u8, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            try out.append(gpa, text[i]);
            i += 1;
            continue;
        }
        const decoded = decodeEscape(text[i..]);
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(decoded.scalar, &buf) catch blk: {
            buf[0..3].* = "\xEF\xBF\xBD".*; // U+FFFD for a surrogate the lexer let through
            break :blk 3;
        };
        try out.appendSlice(gpa, buf[0..n]);
        i += decoded.len;
    }
}

const Decoded = struct { scalar: u21, len: usize };

/// The escape at `text[0] == '\\'`: its scalar value and its length in
/// bytes. An unknown escape decodes to its own second byte.
fn decodeEscape(text: []const u8) Decoded {
    std.debug.assert(text.len >= 2 and text[0] == '\\');
    switch (text[1]) {
        'n' => return .{ .scalar = '\n', .len = 2 },
        'r' => return .{ .scalar = '\r', .len = 2 },
        't' => return .{ .scalar = '\t', .len = 2 },
        'u' => {
            if (text.len < 4 or text[2] != '{') return .{ .scalar = 'u', .len = 2 };
            var value: u32 = 0;
            var j: usize = 3;
            while (j < text.len and text[j] != '}') : (j += 1) {
                const digit = std.fmt.charToDigit(text[j], 16) catch return .{ .scalar = 'u', .len = 2 };
                value = (value *% 16) +% digit;
            }
            if (j >= text.len) return .{ .scalar = 'u', .len = 2 };
            return .{ .scalar = @intCast(@min(value, 0x10FFFF)), .len = j + 1 };
        },
        else => |c| return .{ .scalar = c, .len = 2 },
    }
}

/// The scalar of a `char` token, quotes included in `text`.
fn decodeChar(text: []const u8) u32 {
    if (text.len < 3) return 0;
    const inner = text[1 .. text.len - 1];
    if (inner[0] == '\\' and inner.len >= 2) return decodeEscape(inner).scalar;
    const n = std.unicode.utf8ByteSequenceLength(inner[0]) catch return inner[0];
    if (n > inner.len) return inner[0];
    return std.unicode.utf8Decode(inner[0..n]) catch inner[0];
}

// ---------------------------------------------------------------------------
// Tests. The whole-object assertion for a lowered file is its dump
// (`dump/bir.zig`), so most tests pin the declaration blocks of the dump
// text; errors are asserted as (code, line, column) triples in source
// order. Every lowered Bir also passes `checkWellFormed`, which is the
// in-bounds checker the stress and fuzz tests rely on.
// ---------------------------------------------------------------------------

const testing = std.testing;
const Parse = @import("../parse/Parse.zig");
const dump_bir = @import("../dump/bir.zig");

const Lowered = struct {
    out: Tokenizer.Output,
    tree: Ast,
    bir: Bir,

    fn deinit(r: *Lowered) void {
        r.bir.deinit(testing.allocator);
        r.tree.deinit(testing.allocator);
        r.out.deinit(testing.allocator);
    }
};

const TestOptions = struct {
    core: bool = false,
    module_name: []const u8 = "Main",
};

fn lowerSource(interner: *InternPool.Local, source: [:0]const u8, options: TestOptions) !Lowered {
    var out: Tokenizer.Output = .empty;
    errdefer out.deinit(testing.allocator);
    try Tokenizer.tokenize(testing.allocator, source, interner, &out);
    var tree = try Parse.parse(testing.allocator, testing.allocator, source, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
    errdefer tree.deinit(testing.allocator);
    const bir = try lower(testing.allocator, testing.allocator, source, out.tokens.slice(), &tree, interner, .{
        .core = options.core,
        .module_name = options.module_name,
    });
    return .{ .out = out, .tree = tree, .bir = bir };
}

const ExpectedError = struct { code: diagnostic.Code, line: u32, col: u32 };

/// Compare the lowering errors in position order — what the session emits
/// (`diagnostic.sort`). Lowering itself reports declaration-header errors
/// before body errors, which is not source order.
fn expectErrorList(r: *const Lowered, expected: []const ExpectedError) !void {
    const sorted = try testing.allocator.dupe(Diagnostics.Item, r.bir.diagnostics);
    defer testing.allocator.free(sorted);
    std.mem.sort(Diagnostics.Item, sorted, {}, struct {
        fn lessThan(_: void, a: Diagnostics.Item, b: Diagnostics.Item) bool {
            return a.start < b.start;
        }
    }.lessThan);
    var ok = sorted.len == expected.len;
    if (ok) for (sorted, expected) |item, want| {
        const pos = diagnostic.position(r.out.line_starts.items, item.start);
        if (item.code != want.code or pos.line != want.line or pos.col != want.col) ok = false;
    };
    if (!ok) {
        std.debug.print("expected {d} lowering errors:\n", .{expected.len});
        for (expected) |want| std.debug.print("  {t} at {d}:{d}\n", .{ want.code, want.line, want.col });
        std.debug.print("found {d}:\n", .{sorted.len});
        for (sorted) |item| {
            const pos = diagnostic.position(r.out.line_starts.items, item.start);
            std.debug.print("  {t} at {d}:{d}\n", .{ item.code, pos.line, pos.col });
        }
        return error.TestExpectedEqual;
    }
}

/// Lower `source` and compare the declaration blocks of its dump (everything
/// before the final `interface` section) with `expected`; assert the
/// lowering errors as well.
fn expectDecls(source: [:0]const u8, expected: []const u8, expected_errors: []const ExpectedError) !void {
    try expectDump(source, .{}, expected, expected_errors, .decls);
}

/// Like `expectDecls` but compares the whole dump, interface and imports
/// included.
fn expectWholeDump(source: [:0]const u8, options: TestOptions, expected: []const u8, expected_errors: []const ExpectedError) !void {
    try expectDump(source, options, expected, expected_errors, .whole);
}

fn expectDump(source: [:0]const u8, options: TestOptions, expected: []const u8, expected_errors: []const ExpectedError, part: enum { decls, whole }) !void {
    var interner = try InternPool.Local.init(testing.allocator);
    defer interner.deinit(testing.allocator);
    var r = try lowerSource(&interner, source, options);
    defer r.deinit();
    try checkWellFormed(&r.bir);

    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try dump_bir.write(&text.writer, source, r.out.comments.items, &r.bir, .fromLocal(&interner));
    const whole = text.written();
    const actual = switch (part) {
        .whole => whole,
        // Up to the blank line that separates the last block from `interface`.
        .decls => blk: {
            const at = std.mem.indexOf(u8, whole, "interface\n") orelse whole.len;
            break :blk whole[0 .. at - @intFromBool(at > 0)];
        },
    };
    try testing.expectEqualStrings(expected, actual);
    try expectErrorList(&r, expected_errors);
}

/// Lower `source` and assert only its errors (and well-formedness).
fn expectErrors(source: [:0]const u8, options: TestOptions, expected: []const ExpectedError) !void {
    var interner = try InternPool.Local.init(testing.allocator);
    defer interner.deinit(testing.allocator);
    var r = try lowerSource(&interner, source, options);
    defer r.deinit();
    try checkWellFormed(&r.bir);
    try expectErrorList(&r, expected);
}

// ---- The in-bounds checker ----------------------------------------------------

fn checkWellFormed(bir: *const Bir) !void {
    const n_insts = bir.insts.len;
    const n_extra = bir.extra.len;
    try testing.expect(bir.module_doc_start <= bir.module_doc_end);
    for (bir.symbols) |_| {}
    for (bir.imports) |imp| {
        try checkSymbol(bir, imp.module);
        try checkSymbol(bir, imp.alias);
        try testing.expect(imp.exposed_start <= imp.exposed_end and imp.exposed_end <= bir.symbols.len);
    }
    for (bir.interface) |di| try testing.expect(di.int() < bir.decls.len);
    for (bir.ctors) |c| {
        try checkSymbol(bir, c.name);
        try testing.expect(c.decl.int() < bir.decls.len);
        try checkRange(.{ .start = c.args_start, .end = c.args_end }, n_extra);
    }
    var prev_end: u32 = 0;
    for (bir.decls, 0..) |d, i| {
        try checkSymbol(bir, d.name);
        try testing.expect(d.doc_start <= d.doc_end);
        try testing.expect(d.inst_start.int() == prev_end); // contiguous, in order
        try testing.expect(d.inst_start.int() <= d.inst_end.int() and d.inst_end.int() <= n_insts);
        prev_end = d.inst_end.int();
        try testing.expect(d.type_params_start <= d.type_params_end and d.type_params_end <= bir.symbols.len);
        try testing.expect(d.ctors_start <= d.ctors_end and d.ctors_end <= bir.ctors.len);
        for (bir.declCtors(d)) |c| try testing.expectEqual(@as(u32, @intCast(i)), c.decl.int());
        try testing.expect(d.locals_start <= d.locals_end and d.locals_end <= bir.locals.len);
        try testing.expect(d.refs_start <= d.refs_end and d.refs_end <= bir.refs.len);
        if (d.annotation.unwrap()) |a| try checkInDecl(d, a);
        if (d.body.unwrap()) |b| try checkInDecl(d, b);
        if (d.schema_body.unwrap()) |b| try checkInDecl(d, b);
        if (d.kind == .value) {
            try checkRange(.{ .start = d.params_start, .end = d.params_end }, n_extra);
            for (bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Index)) |p| try checkInDecl(d, p);
        }
        for (bir.declLocals(d)) |l| {
            if (l.name != .none) try checkSymbol(bir, l.name);
            try checkInDecl(d, l.inst);
        }
        for (bir.declRefs(d)) |r| switch (r.kind) {
            .top_value, .top_type, .top_schema => try testing.expect(r.a < bir.decls.len),
            .top_ctor => try testing.expect(r.a < bir.ctors.len),
            .import_value, .import_ctor, .import_type, .import_schema => {
                try testing.expect(r.a < bir.symbols.len and r.b < bir.symbols.len);
            },
        };
        var i_inst = d.inst_start.int();
        while (i_inst < d.inst_end.int()) : (i_inst += 1) try checkInst(bir, d, @enumFromInt(i_inst));
    }
    try testing.expectEqual(n_insts, prev_end); // every instruction belongs to a declaration
}

fn checkSymbol(bir: *const Bir, s: SymbolIndex) !void {
    try testing.expect(@intFromEnum(s) < bir.symbols.len);
}

fn checkRange(r: SubRange, n_extra: usize) !void {
    try testing.expect(@intFromEnum(r.start) <= @intFromEnum(r.end) and @intFromEnum(r.end) <= n_extra);
}

fn checkInDecl(d: Bir.Decl, inst: Index) !void {
    try testing.expect(inst.int() >= d.inst_start.int() and inst.int() < d.inst_end.int());
}

fn checkLocal(bir: *const Bir, d: Bir.Decl, local: u32) !void {
    try testing.expect(local < bir.declLocals(d).len);
}

fn checkInstList(bir: *const Bir, d: Bir.Decl, r: SubRange) !void {
    try checkRange(r, bir.extra.len);
    for (bir.extraSlice(r, Index)) |i| try checkInDecl(d, i);
}

fn checkFields(bir: *const Bir, d: Bir.Decl, r: SubRange) !void {
    try checkRange(r, bir.extra.len);
    try testing.expect(r.len() % 2 == 0);
    for (bir.extraSlice(r, Bir.Field)) |f| {
        try checkSymbol(bir, f.name);
        try checkInDecl(d, f.value);
    }
}

fn checkRecordAt(bir: *const Bir, index: u32) !SubRange {
    try testing.expect(index + 2 <= bir.extra.len);
    return bir.subRange(@enumFromInt(index));
}

fn checkBytes(bir: *const Bir, data: Inst.Data) !void {
    try testing.expect(data.lhs <= bir.string_bytes.len and data.rhs <= bir.string_bytes.len - data.lhs);
}

fn checkInst(bir: *const Bir, d: Bir.Decl, inst: Index) !void {
    const data = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .local, .pat_var => try checkLocal(bir, d, data.lhs),
        .top, .type_top => try testing.expect(data.lhs < bir.decls.len),
        .ctor => try testing.expect(data.lhs < bir.ctors.len),
        .import_value, .import_ctor, .qualified, .qualified_ctor, .type_import, .type_qualified => {
            try testing.expect(data.lhs < bir.symbols.len and data.rhs < bir.symbols.len);
        },
        .schema_type_ref, .schema_value_ref, .schema_ctor_ref => try checkSymbol(bir, @enumFromInt(data.lhs)),
        // Lowering never produces these; `resolve/Resolve.zig` rewrites
        // the forms above into them after the module graph exists.
        .ext_value, .ext_ctor, .ext_type, .schema_member_top, .ext_schema_member, .schema_ctor_top, .ext_schema_ctor, .schema_type_top, .ext_schema_type, .schema_parameter, .schema_primitive, .schema_target_top, .ext_schema_target => return error.TestUnexpectedResult,
        .type_var => {
            try testing.expect(data.lhs < bir.symbols.len);
            const info = Bir.TypeVarInfo.unpack(data.rhs);
            if (info.param != Bir.TypeVarInfo.param_none) try testing.expect(info.param < d.params);
        },
        .schema_ref, .schema_expr_ref => try checkSymbol(bir, @enumFromInt(data.lhs)),
        .schema_app => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try checkInstList(bir, d, try checkRecordAt(bir, data.rhs));
        },
        .schema_paren, .schema_as, .schema_via => try checkInDecl(d, @enumFromInt(data.lhs)),
        .schema_record => try checkInstList(bir, d, Bir.inlineRange(data)),
        .schema_field => {
            try checkSymbol(bir, @enumFromInt(data.lhs));
            try testing.expect(data.rhs + Bir.extraLen(Bir.SchemaField) <= bir.extra.len);
            const field = bir.extraData(@enumFromInt(data.rhs), Bir.SchemaField);
            try checkInDecl(d, field.operand);
            try checkInstList(bir, d, .{ .start = field.modifiers_start, .end = field.modifiers_end });
        },
        .schema_value => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try checkInstList(bir, d, try checkRecordAt(bir, data.rhs));
        },
        .schema_tagged => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try checkInstList(bir, d, try checkRecordAt(bir, data.rhs));
        },
        .schema_variant => {
            try checkSymbol(bir, @enumFromInt(data.lhs));
            try testing.expect(data.rhs + Bir.extraLen(Bir.SchemaVariant) <= bir.extra.len);
            const variant = bir.extraData(@enumFromInt(data.rhs), Bir.SchemaVariant);
            if (variant.payload.unwrap()) |p| try checkInDecl(d, p);
            if (variant.rename.unwrap()) |r| try checkInDecl(d, r);
        },
        .schema_optional, .schema_nullable => {},
        .type_app, .call, .pat_ctor => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try checkInstList(bir, d, try checkRecordAt(bir, data.rhs));
        },
        .type_fn => {
            const params = try checkRecordAt(bir, data.lhs);
            try testing.expect(params.len() >= 1);
            try checkInstList(bir, d, params);
            try checkInDecl(d, @enumFromInt(data.rhs));
        },
        .let_pattern, .branch => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try checkInDecl(d, @enumFromInt(data.rhs));
        },
        .type_unit, .unit, .pat_wild, .pat_unit => {},
        .type_tuple, .tuple, .list, .interp, .pat_tuple, .pat_list => try checkInstList(bir, d, Bir.inlineRange(data)),
        .type_record, .record => try checkFields(bir, d, Bir.inlineRange(data)),
        .type_record_ext, .record_update => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try checkFields(bir, d, try checkRecordAt(bir, data.rhs));
        },
        .int, .float, .string, .chunk, .pat_int, .pat_string => try checkBytes(bir, data),
        .markup => try testing.expect(bir.markupTreeValid(d, data.lhs)),
        .char, .pat_char => try testing.expect(data.lhs <= 0x10FFFF),
        .field_access => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try testing.expect(data.rhs < bir.symbols.len);
        },
        .tuple_index => try checkInDecl(d, @enumFromInt(data.lhs)),
        .method_call => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try testing.expect(data.rhs + Bir.extraLen(Bir.MethodCall) <= bir.extra.len);
            const m = bir.extraData(@enumFromInt(data.rhs), Bir.MethodCall);
            try checkSymbol(bir, m.name);
            try checkInstList(bir, d, .{ .start = m.args_start, .end = m.args_end });
            try testing.expect(m.args_end != m.args_start); // never zero arguments (§1.1)
        },
        .type_dispatch => {
            try testing.expect(data.lhs < bir.symbols.len);
            try testing.expect(data.rhs + Bir.extraLen(Bir.TypeDispatch) <= bir.extra.len);
            const t = bir.extraData(@enumFromInt(data.rhs), Bir.TypeDispatch);
            try checkSymbol(bir, t.name);
            try checkInstList(bir, d, .{ .start = t.args_start, .end = t.args_end });
        },
        .lambda, .let => {
            try checkInstList(bir, d, try checkRecordAt(bir, data.lhs));
            try checkInDecl(d, @enumFromInt(data.rhs));
        },
        .let_def => {
            try testing.expect(data.lhs + Bir.extraLen(Bir.LetDef) <= bir.extra.len);
            const def = bir.extraData(@enumFromInt(data.lhs), Bir.LetDef);
            try checkLocal(bir, d, def.local);
            if (def.annotation.unwrap()) |a| try checkInDecl(d, a);
            try checkInstList(bir, d, .{ .start = def.params_start, .end = def.params_end });
            try checkInDecl(d, @enumFromInt(data.rhs));
        },
        .case => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try checkInstList(bir, d, try checkRecordAt(bir, data.rhs));
        },
        .@"try" => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            const target: Inst.OptionalIndex = @enumFromInt(data.rhs);
            if (target.unwrap()) |t| {
                try checkInDecl(d, t);
                try testing.expectEqual(Inst.Tag.let_def, bir.instTag(t));
            }
        },
        .pat_record => {
            try checkRange(Bir.inlineRange(data), bir.extra.len);
            for (bir.extraSlice(Bir.inlineRange(data), u32)) |l| try checkLocal(bir, d, l);
        },
        .pat_as => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try checkLocal(bir, d, data.rhs);
        },
        .pat_spread => try checkInDecl(d, @enumFromInt(data.lhs)),
        .@"error" => try testing.expect(data.lhs < @typeInfo(diagnostic.Code).@"enum".fields.len),
    }
}

// ---- Desugarings (§8.2) ---------------------------------------------------------

test "operators become calls of their core functions, `(+)` the function itself, `-x` a negate call" {
    try expectDecls(
        \\f a b =
        \\    ( a + b, a // b, [ a, ...[] ], (+), -a )
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (a)
        \\  %1 = pat_var local 1 (b)
        \\  %2 = local 0 (a)
        \\  %3 = local 1 (b)
        \\  %4 = import_value Basics.add
        \\  %5 = call %4 [%2, %3]
        \\  %6 = local 0 (a)
        \\  %7 = local 1 (b)
        \\  %8 = import_value Basics.idiv
        \\  %9 = call %8 [%6, %7]
        \\  %10 = local 0 (a)
        \\  %11 = list []
        \\  %12 = import_value List.cons
        \\  %13 = call %12 [%10, %11]
        \\  %14 = import_value Basics.add
        \\  %15 = local 0 (a)
        \\  %16 = import_value Basics.negate
        \\  %17 = call %16 [%15]
        \\  %18 = tuple [%5, %9, %13, %14, %17]
        \\  params [%0, %1]
        \\  body %18
        \\  locals
        \\    0 a param %0
        \\    1 b param %1
        \\  refs
        \\    import_value Basics.add
        \\    import_value Basics.idiv
        \\    import_value List.cons
        \\    import_value Basics.negate
        \\
    , &.{});
}

test "every binary operator maps to the §6.5 core function, except the six comparisons" {
    // The six comparison operators are method calls on the type of their
    // left operand and carry the operator they were written as
    // (static-dispatch-spike.md §3.1); `Basics.eq` and friends stay
    // declared and callable, they are simply no longer what `==` means.
    try expectDecls(
        \\f a b =
        \\    [ a - b, a * b, a / b, a ^ b, a ++ b, a == b, a /= b, a < b, a > b, a <= b, a >= b, a && b, a || b ]
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (a)
        \\  %1 = pat_var local 1 (b)
        \\  %2 = local 0 (a)
        \\  %3 = local 1 (b)
        \\  %4 = import_value Basics.sub
        \\  %5 = call %4 [%2, %3]
        \\  %6 = local 0 (a)
        \\  %7 = local 1 (b)
        \\  %8 = import_value Basics.mul
        \\  %9 = call %8 [%6, %7]
        \\  %10 = local 0 (a)
        \\  %11 = local 1 (b)
        \\  %12 = import_value Basics.fdiv
        \\  %13 = call %12 [%10, %11]
        \\  %14 = local 0 (a)
        \\  %15 = local 1 (b)
        \\  %16 = import_value Basics.pow
        \\  %17 = call %16 [%14, %15]
        \\  %18 = local 0 (a)
        \\  %19 = local 1 (b)
        \\  %20 = import_value Basics.append
        \\  %21 = call %20 [%18, %19]
        \\  %22 = local 0 (a)
        \\  %23 = local 1 (b)
        \\  %24 = method_call %22 .eq [%23] (==)
        \\  %25 = local 0 (a)
        \\  %26 = local 1 (b)
        \\  %27 = method_call %25 .eq [%26] (/=)
        \\  %28 = local 0 (a)
        \\  %29 = local 1 (b)
        \\  %30 = method_call %28 .compare [%29] (<)
        \\  %31 = local 0 (a)
        \\  %32 = local 1 (b)
        \\  %33 = method_call %31 .compare [%32] (>)
        \\  %34 = local 0 (a)
        \\  %35 = local 1 (b)
        \\  %36 = method_call %34 .compare [%35] (<=)
        \\  %37 = local 0 (a)
        \\  %38 = local 1 (b)
        \\  %39 = method_call %37 .compare [%38] (>=)
        \\  %40 = local 0 (a)
        \\  %41 = local 1 (b)
        \\  %42 = import_value Basics.and
        \\  %43 = call %42 [%40, %41]
        \\  %44 = local 0 (a)
        \\  %45 = local 1 (b)
        \\  %46 = import_value Basics.or
        \\  %47 = call %46 [%44, %45]
        \\  %48 = list [%5, %9, %13, %17, %21, %24, %27, %30, %33, %36, %39, %43, %47]
        \\  params [%0, %1]
        \\  body %48
        \\  locals
        \\    0 a param %0
        \\    1 b param %1
        \\  refs
        \\    import_value Basics.sub
        \\    import_value Basics.mul
        \\    import_value Basics.fdiv
        \\    import_value Basics.pow
        \\    import_value Basics.append
        \\    import_value Basics.and
        \\    import_value Basics.or
        \\
    , &.{});
}

test "a leading element and a spread desugar to List.cons, not Basics.cons" {
    // language.md §6.8: `[ x, ...xs ]` is `List.cons x xs`, the call `::`
    // made, and `++` is `Basics.append`, matching Elm, where `(::)` is
    // `List.cons`. Assuming `Basics` for every desugaring once emitted
    // `import_value Basics.cons` — a name no interface has — and nothing
    // noticed, because name resolution against interfaces came later.
    try expectDecls(
        \\f x xs =
        \\    [ x, ...xs ]
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (x)
        \\  %1 = pat_var local 1 (xs)
        \\  %2 = local 0 (x)
        \\  %3 = local 1 (xs)
        \\  %4 = import_value List.cons
        \\  %5 = call %4 [%2, %3]
        \\  params [%0, %1]
        \\  body %5
        \\  locals
        \\    0 x param %0
        \\    1 xs param %1
        \\  refs
        \\    import_value List.cons
        \\
    , &.{});
}

test "the operator table gives every operator a home module, Basics" {
    // `::`, the one operator whose home was `List`, left on 2026-10-01
    // (language.md §6.8); a list's spread names `List.cons` itself.
    const ops = [_]Token.Tag{
        .op_plus,        .op_minus,   .op_star,      .op_slash,
        .op_slash_slash, .op_caret,   .op_plus_plus, .op_eq_eq,
        .op_slash_eq,    .op_lt,      .op_gt,        .op_lte,
        .op_gte,         .op_and_and, .op_or_or,
    };
    for (ops) |op| {
        const f = operatorFunction(op);
        testing.expectEqual(InternPool.WellKnown.Basics, f.module) catch |err| {
            std.debug.print("operator {t} resolved to module {t}\n", .{ op, f.module });
            return err;
        };
    }
    try testing.expectEqualDeep(OperatorFunction{ .module = .Basics, .function = .append }, operatorFunction(.op_plus_plus));
}

test "`|>` inserts at the FIRST argument, `<|` at the last, through grouping parentheses" {
    try expectDecls(
        \\f g x =
        \\    ( x |> g 1, g <| x, x |> (g 1) |> g, g <| g <| x )
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (g)
        \\  %1 = pat_var local 1 (x)
        \\  %2 = local 1 (x)
        \\  %3 = local 0 (g)
        \\  %4 = int 1
        \\  %5 = call %3 [%2, %4]
        \\  %6 = local 0 (g)
        \\  %7 = local 1 (x)
        \\  %8 = call %6 [%7]
        \\  %9 = local 1 (x)
        \\  %10 = local 0 (g)
        \\  %11 = int 1
        \\  %12 = call %10 [%9, %11]
        \\  %13 = local 0 (g)
        \\  %14 = call %13 [%12]
        \\  %15 = local 0 (g)
        \\  %16 = local 0 (g)
        \\  %17 = local 1 (x)
        \\  %18 = call %16 [%17]
        \\  %19 = call %15 [%18]
        \\  %20 = tuple [%5, %8, %14, %19]
        \\  params [%0, %1]
        \\  body %20
        \\  locals
        \\    0 g param %0
        \\    1 x param %1
        \\
    , &.{});
}

test "`_` becomes a lambda over the innermost enclosing application (§6.7)" {
    try expectDecls(
        \\f a b =
        \\    ( max a _, clamp _ (modBy _ b) 3 )
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (a)
        \\  %1 = pat_var local 1 (b)
        \\  %2 = pat_var local 2
        \\  %3 = import_value Basics.max
        \\  %4 = local 0 (a)
        \\  %5 = local 2
        \\  %6 = call %3 [%4, %5]
        \\  %7 = lambda [%2] -> %6
        \\  %8 = pat_var local 3
        \\  %9 = import_value Basics.clamp
        \\  %10 = local 3
        \\  %11 = pat_var local 4
        \\  %12 = import_value Basics.modBy
        \\  %13 = local 4
        \\  %14 = local 1 (b)
        \\  %15 = call %12 [%13, %14]
        \\  %16 = lambda [%11] -> %15
        \\  %17 = int 3
        \\  %18 = call %9 [%10, %16, %17]
        \\  %19 = lambda [%8] -> %18
        \\  %20 = tuple [%7, %19]
        \\  params [%0, %1]
        \\  body %20
        \\  locals
        \\    0 a param %0
        \\    1 b param %1
        \\    2 _ fresh %2
        \\    3 _ fresh %8
        \\    4 _ fresh %11
        \\  refs
        \\    import_value Basics.max
        \\    import_value Basics.clamp
        \\    import_value Basics.modBy
        \\
    , &.{});
}

test "`<-` binds the rest of the block as the call's last argument (§6.7)" {
    try expectDecls(
        \\f s =
        \\    let
        \\        n = 1
        \\
        \\        h <- Result.andThen s
        \\        t = h
        \\    in
        \\    max t n
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (s)
        \\  %1 = let_def local 1 (n) [] = %2
        \\  %2 = int 1
        \\  %3 = qualified Result.andThen
        \\  %4 = local 0 (s)
        \\  %5 = pat_var local 2 (h)
        \\  %6 = let_def local 3 (t) [] = %7
        \\  %7 = local 2 (h)
        \\  %8 = import_value Basics.max
        \\  %9 = local 3 (t)
        \\  %10 = local 1 (n)
        \\  %11 = call %8 [%9, %10]
        \\  %12 = let [%6] in %11
        \\  %13 = lambda [%5] -> %12
        \\  %14 = call %3 [%4, %13]
        \\  %15 = let [%1] in %14
        \\  params [%0]
        \\  body %15
        \\  locals
        \\    0 s param %0
        \\    1 n let %1
        \\    2 h pattern %5
        \\    3 t let %6
        \\  refs
        \\    import_value Result.andThen
        \\    import_value Basics.max
        \\
    , &.{});
}

test "`?` becomes a try that returns from the innermost definition with parameters" {
    try expectDecls(
        \\f x =
        \\    let
        \\        g y =
        \\            y?
        \\
        \\        c =
        \\            x?
        \\    in
        \\    g c?
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (x)
        \\  %1 = let_def local 1 (g) [%3] = %5
        \\  %2 = let_def local 2 (c) [] = %7
        \\  %3 = pat_var local 3 (y)
        \\  %4 = local 3 (y)
        \\  %5 = try %4 (returns from let_def %1)
        \\  %6 = local 0 (x)
        \\  %7 = try %6 (returns from the declaration)
        \\  %8 = local 1 (g)
        \\  %9 = local 2 (c)
        \\  %10 = call %8 [%9]
        \\  %11 = try %10 (returns from the declaration)
        \\  %12 = let [%1, %2] in %11
        \\  params [%0]
        \\  body %12
        \\  locals
        \\    0 x param %0
        \\    1 g let %1
        \\    2 c let %2
        \\    3 y param %3
        \\
    , &.{});
}

test "`?` in a top-level constant, even under let constants, is question_outside_function" {
    try expectErrors(
        \\x =
        \\    let
        \\        y =
        \\            x?
        \\    in
        \\    y?
        \\
    , .{}, &.{
        .{ .code = .question_outside_function, .line = 4, .col = 14 },
        .{ .code = .question_outside_function, .line = 6, .col = 6 },
    });
}

test "`?` under a lambda is question_in_lambda, whatever encloses the lambda" {
    try expectErrors(
        \\f x =
        \\    (\y -> y?) x
        \\
        \\
        \\g =
        \\    \y -> y?
        \\
    , .{}, &.{
        .{ .code = .question_in_lambda, .line = 2, .col = 13 },
        .{ .code = .question_in_lambda, .line = 6, .col = 12 },
    });
}

test "string interpolation becomes interp of chunks and expressions; escapes are decoded" {
    try expectDecls(
        \\f a =
        \\    ( "x\t${a}\u{41}\n\"", "${a}${a}", "plain\\", "" )
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (a)
        \\  %1 = chunk "x\t"
        \\  %2 = local 0 (a)
        \\  %3 = chunk "A\n\""
        \\  %4 = interp [%1, %2, %3]
        \\  %5 = local 0 (a)
        \\  %6 = local 0 (a)
        \\  %7 = interp [%5, %6]
        \\  %8 = string "plain\\"
        \\  %9 = string ""
        \\  %10 = tuple [%4, %7, %8, %9]
        \\  params [%0]
        \\  body %10
        \\  locals
        \\    0 a param %0
        \\
    , &.{});
}

test "multiline strings join their lines; chars decode; numbers keep their spelling" {
    try expectDecls(
        \\x =
        \\    ( \\a
        \\      \\b
        \\    , 'q', '\n', '\u{1F600}', 0x1F, 1.5e3 )
        \\
    ,
        \\decl 0: value x
        \\  %0 = string "a\nb"
        \\  %1 = char 'q'
        \\  %2 = char U+000A
        \\  %3 = char U+1F600
        \\  %4 = int 0x1F
        \\  %5 = float 1.5e3
        \\  %6 = tuple [%0, %1, %2, %3, %4, %5]
        \\  params []
        \\  body %6
        \\
    , &.{});
}

test "`if` becomes a two-branch case on the prelude Bool constructors" {
    try expectDecls(
        \\f c =
        \\    if c then 1 else 2
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (c)
        \\  %1 = local 0 (c)
        \\  %2 = import_ctor Basics.True
        \\  %3 = pat_ctor %2 []
        \\  %4 = int 1
        \\  %5 = branch %3 -> %4
        \\  %6 = import_ctor Basics.False
        \\  %7 = pat_ctor %6 []
        \\  %8 = int 2
        \\  %9 = branch %7 -> %8
        \\  %10 = case %1 [%5, %9]
        \\  params [%0]
        \\  body %10
        \\  locals
        \\    0 c param %0
        \\  refs
        \\    import_ctor Basics.True
        \\    import_ctor Basics.False
        \\
    , &.{});
}

test "lambdas stay n-ary and an accessor becomes a one-parameter lambda around a field access" {
    try expectDecls(
        \\f =
        \\    ( \a b -> a, .name )
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (a)
        \\  %1 = pat_var local 1 (b)
        \\  %2 = local 0 (a)
        \\  %3 = lambda [%0, %1] -> %2
        \\  %4 = pat_var local 2
        \\  %5 = local 2
        \\  %6 = field_access %5 .name
        \\  %7 = lambda [%4] -> %6
        \\  %8 = tuple [%3, %7]
        \\  params []
        \\  body %8
        \\  locals
        \\    0 a param %0
        \\    1 b param %1
        \\    2 _ fresh %4
        \\
    , &.{});
}

test "records, record update, field access, tuple index, lists and unit stay nodes" {
    try expectDecls(
        \\f r t =
        \\    ( { a = 1, b = r.x.y }, { r | a = t.0 }, [ () ], {} )
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (r)
        \\  %1 = pat_var local 1 (t)
        \\  %2 = int 1
        \\  %3 = local 0 (r)
        \\  %4 = field_access %3 .x
        \\  %5 = field_access %4 .y
        \\  %6 = record { a = %2, b = %5 }
        \\  %7 = local 0 (r)
        \\  %8 = local 1 (t)
        \\  %9 = tuple_index %8 .0
        \\  %10 = record_update %7 { a = %9 }
        \\  %11 = unit
        \\  %12 = list [%11]
        \\  %13 = record {}
        \\  %14 = tuple [%6, %10, %12, %13]
        \\  params [%0, %1]
        \\  body %14
        \\  locals
        \\    0 r param %0
        \\    1 t param %1
        \\
    , &.{});
}

test "every pattern kind lowers, binding its variables as locals of the right kind" {
    try expectDecls(
        \\f p =
        \\    case p of
        \\        ( Just [ x, ...rest ] as whole, { a, b }, [ 1, -2, 'c', "s", () ], _ ) ->
        \\            x
        \\
        \\        _ ->
        \\            0
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (p)
        \\  %1 = local 0 (p)
        \\  %2 = import_ctor Maybe.Just
        \\  %3 = pat_var local 1 (x)
        \\  %4 = pat_var local 2 (rest)
        \\  %5 = pat_spread ...%4
        \\  %6 = pat_list [%3, %5]
        \\  %7 = pat_ctor %2 [%6]
        \\  %8 = pat_as %7 as local 3 (whole)
        \\  %9 = pat_record [local 4 (a), local 5 (b)]
        \\  %10 = pat_int 1
        \\  %11 = pat_int -2
        \\  %12 = pat_char 'c'
        \\  %13 = pat_string "s"
        \\  %14 = pat_unit
        \\  %15 = pat_list [%10, %11, %12, %13, %14]
        \\  %16 = pat_wild
        \\  %17 = pat_tuple [%8, %9, %15, %16]
        \\  %18 = local 1 (x)
        \\  %19 = branch %17 -> %18
        \\  %20 = pat_wild
        \\  %21 = int 0
        \\  %22 = branch %20 -> %21
        \\  %23 = case %1 [%19, %22]
        \\  params [%0]
        \\  body %23
        \\  locals
        \\    0 p param %0
        \\    1 x pattern %3
        \\    2 rest pattern %4
        \\    3 whole pattern %8
        \\    4 a pattern %9
        \\    5 b pattern %9
        \\  refs
        \\    import_ctor Maybe.Just
        \\
    , &.{});
}

test "let patterns and annotated let definitions" {
    try expectDecls(
        \\f p =
        \\    let
        \\        ( a, b ) =
        \\            p
        \\
        \\        n : Int
        \\        n =
        \\            a
        \\    in
        \\    ( b, n )
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (p)
        \\  %1 = pat_var local 1 (a)
        \\  %2 = pat_var local 2 (b)
        \\  %3 = pat_tuple [%1, %2]
        \\  %4 = let_def local 3 (n) : %7 [] = %8
        \\  %5 = local 0 (p)
        \\  %6 = let_pattern %3 = %5
        \\  %7 = type_import Basics.Int
        \\  %8 = local 1 (a)
        \\  %9 = local 2 (b)
        \\  %10 = local 3 (n)
        \\  %11 = tuple [%9, %10]
        \\  %12 = let [%6, %4] in %11
        \\  params [%0]
        \\  body %12
        \\  locals
        \\    0 p param %0
        \\    1 a pattern %1
        \\    2 b pattern %2
        \\    3 n let %4
        \\  refs
        \\    import_type Basics.Int
        \\
    , &.{});
}

test "parser placeholders lower to error instructions and report nothing more" {
    try expectDecls(
        \\x =
        \\    [ 1, , 2 ]
        \\
    ,
        \\decl 0: value x
        \\  %0 = int 1
        \\  %1 = error unexpected_token
        \\  %2 = int 2
        \\  %3 = list [%0, %1, %2]
        \\  params []
        \\  body %3
        \\
    , &.{});
}

// ---- Resolution forms (§6.2, §8.1) ------------------------------------------

test "every resolution form: local, top, ctor, import_value, import_ctor, qualified, prelude" {
    try expectWholeDump(
        \\import Dict exposing (Dict, empty, Node)
        \\import Json.Encode as E
        \\import Http
        \\
        \\
        \\type T
        \\    = C Int
        \\
        \\
        \\f x =
        \\    ( x, top, C, empty, Node, E.int, Http.Timeout, max, Just, Dict.get )
        \\
        \\
        \\top =
        \\    1
        \\
        \\
        \\t : ( T, Dict Int Int, E.Value, Maybe a, Http.Error )
        \\t =
        \\    t
        \\
    , .{},
        \\decl 0: type T
        \\  %0 = type_import Basics.Int
        \\  ctor 0 C [%0]
        \\  refs
        \\    import_type Basics.Int
        \\
        \\decl 1: value f
        \\  %0 = pat_var local 0 (x)
        \\  %1 = local 0 (x)
        \\  %2 = top 2 (top)
        \\  %3 = ctor 0 (C)
        \\  %4 = import_value Dict.empty
        \\  %5 = import_ctor Dict.Node
        \\  %6 = qualified Json.Encode.int via E
        \\  %7 = qualified_ctor Http.Timeout
        \\  %8 = import_value Basics.max
        \\  %9 = import_ctor Maybe.Just
        \\  %10 = qualified Dict.get
        \\  %11 = tuple [%1, %2, %3, %4, %5, %6, %7, %8, %9, %10]
        \\  params [%0]
        \\  body %11
        \\  locals
        \\    0 x param %0
        \\  refs
        \\    top 2 (top)
        \\    ctor 0 (C)
        \\    import_value Dict.empty
        \\    import_ctor Dict.Node
        \\    import_value Json.Encode.int
        \\    import_ctor Http.Timeout
        \\    import_value Basics.max
        \\    import_ctor Maybe.Just
        \\    import_value Dict.get
        \\
        \\decl 2: value top
        \\  %0 = int 1
        \\  params []
        \\  body %0
        \\
        \\decl 3: value t (annotated)
        \\  %0 = type_top 0 (T)
        \\  %1 = type_import Dict.Dict
        \\  %2 = type_import Basics.Int
        \\  %3 = type_import Basics.Int
        \\  %4 = type_app %1 [%2, %3]
        \\  %5 = type_qualified Json.Encode.Value via E
        \\  %6 = type_import Maybe.Maybe
        \\  %7 = type_var a
        \\  %8 = type_app %6 [%7]
        \\  %9 = type_qualified Http.Error
        \\  %10 = type_tuple [%0, %4, %5, %8, %9]
        \\  %11 = top 3 (t)
        \\  annotation %10
        \\  params []
        \\  body %11
        \\  refs
        \\    type_top 0 (T)
        \\    import_type Dict.Dict
        \\    import_type Basics.Int
        \\    import_type Json.Encode.Value
        \\    import_type Maybe.Maybe
        \\    import_type Http.Error
        \\    top 3 (t)
        \\
        \\interface
        \\
        \\imports
        \\  import Dict exposing (Dict, empty, Node)
        \\  import Json.Encode as E
        \\  import Http
        \\  prelude Basics
        \\  prelude List
        \\  prelude Maybe
        \\  prelude Result
        \\  prelude String
        \\  prelude Char
        \\  prelude Debug
        \\
    , &.{});
}

test "a top-level name or an exposing name hides the prelude name silently" {
    try expectDecls(
        \\import Util exposing (min)
        \\
        \\
        \\max a b =
        \\    ( max, min, Just )
        \\
        \\
        \\type M
        \\    = Just
        \\
    ,
        \\decl 0: value max
        \\  %0 = pat_var local 0 (a)
        \\  %1 = pat_var local 1 (b)
        \\  %2 = top 0 (max)
        \\  %3 = import_value Util.min
        \\  %4 = ctor 0 (Just)
        \\  %5 = tuple [%2, %3, %4]
        \\  params [%0, %1]
        \\  body %5
        \\  locals
        \\    0 a param %0
        \\    1 b param %1
        \\  refs
        \\    top 0 (max)
        \\    import_value Util.min
        \\    ctor 0 (Just)
        \\
        \\decl 1: type M
        \\  ctor 0 Just []
        \\
    , &.{});
}

test "unbound names in every namespace, and an unknown module alias" {
    try expectErrors(
        \\x : Foo
        \\x =
        \\    ( nowhere, Nope, D.empty, D.Ctor )
        \\
        \\
        \\f m =
        \\    case m of
        \\        Bar ->
        \\            1
        \\
    , .{}, &.{
        .{ .code = .unbound_type, .line = 1, .col = 5 },
        .{ .code = .unbound_variable, .line = 3, .col = 7 },
        .{ .code = .unbound_constructor, .line = 3, .col = 16 },
        .{ .code = .unknown_module_alias, .line = 3, .col = 22 },
        .{ .code = .unknown_module_alias, .line = 3, .col = 31 },
        .{ .code = .unbound_constructor, .line = 8, .col = 9 },
    });
}

// ---- Scopes and shadowing (§7) ---------------------------------------------

test "sibling scopes may reuse a name; nested ones may not" {
    try expectErrors(
        \\ok =
        \\    ( \k -> k, \k -> k )
        \\
        \\
        \\bad =
        \\    \k -> \k -> k
        \\
        \\
        \\branches m =
        \\    case m of
        \\        Just n ->
        \\            n
        \\
        \\        Err n ->
        \\            n
        \\
    , .{}, &.{
        .{ .code = .shadowing, .line = 6, .col = 12 },
    });
}

test "let bindings are in scope in every body, but a value that names a later value is reported" {
    try expectErrors(
        \\f x =
        \\    let
        \\        a =
        \\            b
        \\
        \\        b =
        \\            a
        \\
        \\        x =
        \\            1
        \\
        \\        a =
        \\            2
        \\    in
        \\    a
        \\
    , .{}, &.{
        // `b` RESOLVES — every binding of a `let` is in scope in every body
        // (§7), which is why this is not `unbound_variable` — but reading it
        // where `a` is initialised reads a `const` that has no value yet, so
        // it is `let_forward_reference`.
        .{ .code = .let_forward_reference, .line = 4, .col = 13 },
        // `b = a` reads the SECOND `a`, because the shadowing one is bound
        // too and is the one in scope, so it is a forward reference as well.
        // The program is broken twice over; the point here is that neither
        // report is `unbound_variable`.
        .{ .code = .let_forward_reference, .line = 7, .col = 13 },
        .{ .code = .shadowing, .line = 9, .col = 9 },
        .{ .code = .shadowing, .line = 12, .col = 9 },
    });
}

test "parameters may not reuse a top-level name, an exposing name or a prelude value" {
    try expectErrors(
        \\import Dict exposing (empty)
        \\
        \\
        \\count =
        \\    1
        \\
        \\
        \\f count empty e =
        \\    count
        \\
    , .{}, &.{
        .{ .code = .shadowing, .line = 8, .col = 3 },
        .{ .code = .shadowing, .line = 8, .col = 9 },
        .{ .code = .shadowing, .line = 8, .col = 15 },
    });
}

test "a name bound twice in one pattern set is duplicate_pattern_variable, not shadowing" {
    try expectErrors(
        \\f a a =
        \\    case a of
        \\        ( b, ( b, c ) as c ) ->
        \\            b
        \\
        \\
        \\g =
        \\    \{ x, x } -> x
        \\
    , .{}, &.{
        .{ .code = .duplicate_pattern_variable, .line = 1, .col = 5 },
        .{ .code = .duplicate_pattern_variable, .line = 3, .col = 16 },
        .{ .code = .duplicate_pattern_variable, .line = 3, .col = 26 },
        .{ .code = .duplicate_pattern_variable, .line = 8, .col = 11 },
    });
}

test "a top-level declaration colliding with an exposing name is shadows_import, in values and types" {
    try expectErrors(
        \\import Dict exposing (Dict, empty)
        \\
        \\
        \\empty =
        \\    1
        \\
        \\
        \\type alias Dict =
        \\    Int
        \\
    , .{}, &.{
        .{ .code = .shadows_import, .line = 4, .col = 1 },
        .{ .code = .shadows_import, .line = 8, .col = 12 },
    });
}

// ---- Declarations and imports (§5) ---------------------------------------------

test "duplicate declarations, types, constructors, type parameters and fields" {
    try expectErrors(
        \\x : Int
        \\x =
        \\    { a = 1, a = 2 }
        \\
        \\
        \\x =
        \\    2
        \\
        \\
        \\type T a a
        \\    = A
        \\    | A
        \\
        \\
        \\type alias T =
        \\    Int
        \\
        \\
        \\type alias R =
        \\    { r : Int }
        \\
        \\
        \\type S
        \\    = R
        \\
    , .{}, &.{
        .{ .code = .duplicate_field, .line = 3, .col = 14 },
        .{ .code = .duplicate_declaration, .line = 6, .col = 1 },
        .{ .code = .duplicate_type_parameter, .line = 10, .col = 10 },
        .{ .code = .duplicate_constructor, .line = 12, .col = 7 },
        .{ .code = .duplicate_type, .line = 15, .col = 12 },
        .{ .code = .duplicate_constructor, .line = 24, .col = 7 },
    });
}

test "every repeated type parameter is reported once, in parameter order" {
    // `lowerTypeParams` sorts a copy rather than comparing every pair:
    // the reports must still come out one per repeat, left to right, with
    // interleaved names each against their own first occurrence.
    try expectErrors(
        \\type U b a b a b
        \\    = U a b
        \\
    , .{}, &.{
        .{ .code = .duplicate_type_parameter, .line = 1, .col = 12 },
        .{ .code = .duplicate_type_parameter, .line = 1, .col = 14 },
        .{ .code = .duplicate_type_parameter, .line = 1, .col = 16 },
    });
}

test "a name exposed by two imports, or twice in one list, is duplicate_exposed_name at the second" {
    try expectDecls(
        \\import Dict exposing (Dict, empty, empty)
        \\import Set exposing (Set, empty, Dict)
        \\
        \\
        \\x =
        \\    ( empty, Dict )
        \\
    ,
        \\decl 0: value x
        \\  %0 = import_value Dict.empty
        \\  %1 = import_ctor Dict.Dict
        \\  %2 = tuple [%0, %1]
        \\  params []
        \\  body %2
        \\  refs
        \\    import_value Dict.empty
        \\    import_ctor Dict.Dict
        \\
    , &.{
        .{ .code = .duplicate_exposed_name, .line = 1, .col = 36 },
        .{ .code = .duplicate_exposed_name, .line = 2, .col = 27 },
        .{ .code = .duplicate_exposed_name, .line = 2, .col = 34 },
    });
}

test "duplicate imports, duplicate aliases and a self import" {
    try expectErrors(
        \\import Dict
        \\import Dict as X
        \\import Set as D
        \\import Json.Decode as D
        \\import Main
        \\
        \\
        \\x =
        \\    ( X.a, D.b )
        \\
    , .{}, &.{
        .{ .code = .duplicate_import, .line = 2, .col = 8 },
        .{ .code = .duplicate_import_alias, .line = 4, .col = 23 },
        .{ .code = .self_import, .line = 5, .col = 8 },
        // The duplicate import registered nothing, so its alias is unknown;
        // the duplicate alias resolves to the first import that took it.
        .{ .code = .unknown_module_alias, .line = 9, .col = 7 },
    });
}

test "type variables must be parameters in type bodies, and are free in annotations" {
    try expectErrors(
        \\type Box a
        \\    = Box a b
        \\
        \\
        \\type alias W =
        \\    { r | x : c }
        \\
        \\
        \\f : d -> d
        \\f x =
        \\    x
        \\
    , .{}, &.{
        .{ .code = .unbound_type_variable, .line = 2, .col = 13 },
        .{ .code = .unbound_type_variable, .line = 6, .col = 7 },
        .{ .code = .unbound_type_variable, .line = 6, .col = 15 },
    });
}

test "foreign declarations are rejected without --core and accepted with it" {
    const source =
        \\--| Doc.
        \\pub foreign pure add : Int, Int -> Int
        \\
        \\
        \\foreign type Handle
        \\
    ;
    try expectErrors(source, .{}, &.{
        .{ .code = .foreign_outside_platform, .line = 2, .col = 1 },
        .{ .code = .foreign_outside_platform, .line = 5, .col = 1 },
    });
    try expectWholeDump(source, .{ .core = true },
        \\decl 0: pub foreign value pure add
        \\  doc "Doc."
        \\  %0 = type_import Basics.Int
        \\  %1 = type_import Basics.Int
        \\  %2 = type_import Basics.Int
        \\  %3 = type_fn [%0, %1] -> %2
        \\  annotation %3
        \\  refs
        \\    import_type Basics.Int
        \\  interface foreign value add
        \\
        \\decl 1: foreign type Handle
        \\
        \\interface
        \\  foreign value add
        \\
        \\imports
        \\  prelude Basics
        \\  prelude List
        \\  prelude Maybe
        \\  prelude Result
        \\  prelude String
        \\  prelude Char
        \\  prelude Debug
        \\
    , &.{});
}

test "the interface skeleton lists every pub declaration and nothing private" {
    try expectWholeDump(
        \\pub type alias Id =
        \\    Int
        \\
        \\
        \\pub type alias Point =
        \\    { x : Int, y : Int }
        \\
        \\
        \\pub type Color
        \\    = Red
        \\    | Green
        \\
        \\
        \\pub opaque type Token
        \\    = Token String
        \\
        \\
        \\type Hidden
        \\    = Hidden
        \\
        \\
        \\pub annotated : Int
        \\annotated =
        \\    1
        \\
        \\
        \\pub bare =
        \\    Point 1 2
        \\
        \\
        \\secret =
        \\    Hidden
        \\
    , .{},
        \\decl 0: pub alias Id
        \\  %0 = type_import Basics.Int
        \\  body %0
        \\  refs
        \\    import_type Basics.Int
        \\  interface alias Id
        \\
        \\decl 1: pub alias Point
        \\  %0 = type_import Basics.Int
        \\  %1 = type_import Basics.Int
        \\  %2 = type_record { x : %0, y : %1 }
        \\  body %2
        \\  ctor 0 Point [%0, %1]
        \\  refs
        \\    import_type Basics.Int
        \\  interface alias Point (record constructor)
        \\
        \\decl 2: pub type Color
        \\  ctor 1 Red []
        \\  ctor 2 Green []
        \\  interface type Color = Red | Green
        \\
        \\decl 3: pub opaque type Token
        \\  %0 = type_import String.String
        \\  ctor 3 Token [%0]
        \\  refs
        \\    import_type String.String
        \\  interface opaque type Token
        \\
        \\decl 4: type Hidden
        \\  ctor 4 Hidden []
        \\
        \\decl 5: pub value annotated (annotated)
        \\  %0 = type_import Basics.Int
        \\  %1 = int 1
        \\  annotation %0
        \\  params []
        \\  body %1
        \\  refs
        \\    import_type Basics.Int
        \\  interface value annotated (annotated)
        \\
        \\decl 6: pub value bare
        \\  %0 = ctor 0 (Point)
        \\  %1 = int 1
        \\  %2 = int 2
        \\  %3 = call %0 [%1, %2]
        \\  params []
        \\  body %3
        \\  refs
        \\    ctor 0 (Point)
        \\  interface value bare
        \\
        \\decl 7: value secret
        \\  %0 = ctor 4 (Hidden)
        \\  params []
        \\  body %0
        \\  refs
        \\    ctor 4 (Hidden)
        \\
        \\interface
        \\  alias Id
        \\  alias Point (record constructor)
        \\  type Color = Red | Green
        \\  opaque type Token
        \\  value annotated (annotated)
        \\  value bare
        \\
        \\imports
        \\  prelude Basics
        \\  prelude List
        \\  prelude Maybe
        \\  prelude Result
        \\  prelude String
        \\  prelude Char
        \\  prelude Debug
        \\
    , &.{});
}

test "refs: three top-level names and an import, each once, in first-mention order" {
    try expectDecls(
        \\import Dict exposing (size)
        \\
        \\
        \\report d =
        \\    format (total d + limit + limit) + size d + total d
        \\
        \\
        \\format n =
        \\    n
        \\
        \\
        \\total d =
        \\    0
        \\
        \\
        \\limit =
        \\    10
        \\
    ,
        \\decl 0: value report
        \\  %0 = pat_var local 0 (d)
        \\  %1 = top 1 (format)
        \\  %2 = top 2 (total)
        \\  %3 = local 0 (d)
        \\  %4 = call %2 [%3]
        \\  %5 = top 3 (limit)
        \\  %6 = import_value Basics.add
        \\  %7 = call %6 [%4, %5]
        \\  %8 = top 3 (limit)
        \\  %9 = import_value Basics.add
        \\  %10 = call %9 [%7, %8]
        \\  %11 = call %1 [%10]
        \\  %12 = import_value Dict.size
        \\  %13 = local 0 (d)
        \\  %14 = call %12 [%13]
        \\  %15 = import_value Basics.add
        \\  %16 = call %15 [%11, %14]
        \\  %17 = top 2 (total)
        \\  %18 = local 0 (d)
        \\  %19 = call %17 [%18]
        \\  %20 = import_value Basics.add
        \\  %21 = call %20 [%16, %19]
        \\  params [%0]
        \\  body %21
        \\  locals
        \\    0 d param %0
        \\  refs
        \\    top 1 (format)
        \\    top 2 (total)
        \\    top 3 (limit)
        \\    import_value Basics.add
        \\    import_value Dict.size
        \\
        \\decl 1: value format
        \\  %0 = pat_var local 0 (n)
        \\  %1 = local 0 (n)
        \\  params [%0]
        \\  body %1
        \\  locals
        \\    0 n param %0
        \\
        \\decl 2: value total
        \\  %0 = pat_var local 0 (d)
        \\  %1 = int 0
        \\  params [%0]
        \\  body %1
        \\  locals
        \\    0 d param %0
        \\
        \\decl 3: value limit
        \\  %0 = int 10
        \\  params []
        \\  body %0
        \\
    , &.{});
}

test "an annotation without its definition still declares the name and resolves its type" {
    try expectErrors(
        \\x : Foo
        \\
        \\
        \\y =
        \\    x
        \\
    , .{}, &.{
        .{ .code = .unbound_type, .line = 1, .col = 5 },
    });
}

test "an empty file lowers to an empty module with the prelude rows" {
    try expectWholeDump("", .{},
        \\interface
        \\
        \\imports
        \\  prelude Basics
        \\  prelude List
        \\  prelude Maybe
        \\  prelude Result
        \\  prelude String
        \\  prelude Char
        \\  prelude Debug
        \\
    , &.{});
}

// ---- Stress and fuzz --------------------------------------------------------------

/// Lower arbitrary bytes: no panic, and every reference in bounds.
fn checkArbitrary(source: [:0]const u8) !void {
    var interner = try InternPool.Local.init(testing.allocator);
    defer interner.deinit(testing.allocator);
    var r = try lowerSource(&interner, source, .{});
    defer r.deinit();
    try checkWellFormed(&r.bir);
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try dump_bir.write(&sink.writer, source, r.out.comments.items, &r.bir, .fromLocal(&interner));
}

test "every corpus fixture lowers without a panic, in bounds, and dumps" {
    const corpora = .{ @import("corpus_parse_good"), @import("corpus_bir") };
    inline for (corpora) |corpus| {
        for (corpus.fixtures) |fixture| {
            checkArbitrary(fixture.source) catch |err| {
                std.debug.print("fixture {s}: {t}\n", .{ fixture.name, err });
                return err;
            };
        }
    }
}

test "deeply nested expressions lower without exhausting the stack" {
    const depth = Parse.max_depth;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "x =\n    ");
    for (0..depth) |_| try source.append(testing.allocator, '(');
    try source.append(testing.allocator, '1');
    for (0..depth) |_| try source.append(testing.allocator, ')');
    try source.append(testing.allocator, '\n');
    try source.append(testing.allocator, 0);
    try checkArbitrary(source.items[0 .. source.items.len - 1 :0]);
}

test "fuzz: arbitrary bytes never panic and always lower in bounds" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.sliceWithHash(buf[0 .. buf.len - 1], 0x10E3);
            buf[len] = 0;
            try checkArbitrary(buf[0..len :0]);
        }
    }.testOne, .{ .corpus = &.{
        "x = a |> b <| c\n",
        "f x = let y = x? in \\z -> z?\n",
        "import A exposing (a, B)\ntype B = B\na = B\n",
        "x = \"a ${ b } \\u{41}\" ++ \\\\raw\n",
        "type alias R = { a : b }\nr = { r | a = .a }\n",
    } });
}

// PRNG-driven stand-in for the fuzzer (the toolchain's fuzz mode does not
// build on 0.16.0): corpus fixtures with random lines dropped, duplicated
// and swapped, so half-valid programs of every shape reach lowering.
// Opt-in (`zig build fuzz`, `fuzzing.zig`); the gates lower every
// fixture as written, above. `BENI_STRESS_ITERATIONS` raises the count.
test "stress: mutated corpus fixtures never panic and always lower in bounds" {
    try @import("../fuzzing.zig").skipUnlessFuzzing();
    var iterations: usize = 500;
    if (testing.environ.getAlloc(testing.allocator, "BENI_STRESS_ITERATIONS")) |value| {
        defer testing.allocator.free(value);
        iterations = std.fmt.parseInt(usize, value, 10) catch iterations;
    } else |_| {}

    const corpus = @import("corpus_bir");
    var prng: std.Random.DefaultPrng = .init(0x10E3);
    const random = prng.random();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(testing.allocator);

    for (0..iterations) |_| {
        const fixture = corpus.fixtures[random.uintLessThan(usize, corpus.fixtures.len)];
        lines.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, fixture.source, '\n');
        while (it.next()) |line| try lines.append(testing.allocator, line);
        // A few mutations per file.
        for (0..1 + random.uintLessThan(usize, 4)) |_| {
            if (lines.items.len < 2) break;
            const i = random.uintLessThan(usize, lines.items.len);
            switch (random.uintLessThan(u8, 3)) {
                0 => _ = lines.orderedRemove(i),
                1 => try lines.insert(testing.allocator, i, lines.items[random.uintLessThan(usize, lines.items.len)]),
                else => {
                    const j = random.uintLessThan(usize, lines.items.len);
                    std.mem.swap([]const u8, &lines.items[i], &lines.items[j]);
                },
            }
        }
        source.clearRetainingCapacity();
        for (lines.items) |line| {
            try source.appendSlice(testing.allocator, line);
            try source.append(testing.allocator, '\n');
        }
        try source.append(testing.allocator, 0);
        checkArbitrary(source.items[0 .. source.items.len - 1 :0]) catch |err| {
            std.debug.print("mutated {s} failed ({t}):\n{s}\n", .{ fixture.name, err, source.items });
            return err;
        };
    }
}
