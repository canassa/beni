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
//! thousands of symbols), so a hash map is the right structure and the
//! house rule against maps keyed by dense ids does not apply; a per-file
//! array indexed by symbol would cost a memset proportional to the
//! worker's whole interner per file. Prelude membership is not a lookup at
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
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const InternPool = @import("../InternPool.zig");
const Token = @import("../lex/Token.zig");
const Tokenizer = @import("../lex/Tokenizer.zig");
const Ast = @import("../parse/Ast.zig");
const Bir = @import("Bir.zig");
const Diagnostics = @import("Diagnostics.zig");
const prelude = @import("prelude.zig");

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
values: std.AutoHashMapUnmanaged(Symbol, NameEntry) = .empty,
/// Constructor namespace: this file's constructors and exposed upper names.
ctor_names: std.AutoHashMapUnmanaged(Symbol, NameEntry) = .empty,
/// Type namespace: this file's types and aliases and exposed upper names.
types: std.AutoHashMapUnmanaged(Symbol, NameEntry) = .empty,
/// The lexical scope stack (frontend.md §3.6).
scope: std.ArrayList(ScopeEntry) = .empty,
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
/// The type variables already seen in the type expression being lowered,
/// for the "first occurrence" half of the `equatable` rule (checker.md
/// Appendix A). Cleared by `lowerRootType` per type expression, not per
/// declaration: two `let` annotations in one body are two annotations, and
/// each may mark its own `a`.
type_vars_seen: std.ArrayList(Symbol) = .empty,

/// The token every instruction appended right now is stamped with.
cur_token: TokenIndex = 0,
cur_decl: u32 = 0,
cur_locals_start: u32 = 0,
cur_refs_start: u32 = 0,
cur_inst_start: u32 = 0,

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

const DeclSource = struct {
    node: NodeIndex,
    /// For a definition with an annotation: the annotation node.
    annotation: Node.OptionalIndex,
};

/// Instructions per node and extra words per node, measured on the corpus
/// and the generated project (both lie under 1.0 and 1.1); rounded up so a
/// typical file never regrows.
fn estimatedInstCount(nodes: usize) usize {
    return nodes + 16;
}

fn estimatedExtraCount(nodes: usize) usize {
    return nodes * 5 / 4 + 16;
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
        l.scope.deinit(scratch);
        l.frames.deinit(scratch);
        l.list_scratch.deinit(scratch);
        l.decl_sources.deinit(scratch);
        l.type_vars_seen.deinit(scratch);
        scratch.free(l.decl_stamp);
        scratch.free(l.ctor_stamp);
    }

    const node_count = tree.nodes.len;
    try l.insts.ensureTotalCapacity(gpa, estimatedInstCount(node_count));
    try l.extra.ensureTotalCapacity(gpa, estimatedExtraCount(node_count));
    try l.symbols.ensureTotalCapacity(gpa, node_count / 3 + 16);

    if (node_count > 0) {
        try l.lowerImports();
        try l.collectDeclarations();
        try l.lowerDeclarations();
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
    try l.insts.append(l.gpa, .{ .tag = tag, .main_token = l.cur_token, .data = .{ .lhs = lhs, .rhs = rhs } });
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
    try l.symbols.append(l.gpa, symbol);
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
    try l.list_scratch.append(l.scratch_allocator, word);
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

fn addRef(l: *Lower, kind: Bir.Ref.Kind, a: u32, b: u32) Allocator.Error!void {
    const stamp = l.cur_decl + 1;
    switch (kind) {
        .top_value, .top_type => {
            if (l.decl_stamp[a] == stamp) return;
            l.decl_stamp[a] = stamp;
        },
        .top_ctor => {
            if (l.ctor_stamp[a] == stamp) return;
            l.ctor_stamp[a] = stamp;
        },
        .import_value, .import_ctor, .import_type => {
            // The module and name are compared as symbols, not as symbol
            // indices: each occurrence has its own slot in `symbols`.
            const ma = l.symbols.items[a];
            const na = l.symbols.items[b];
            for (l.refs.items[l.cur_refs_start..]) |r| {
                if (r.kind == kind and l.symbols.items[r.a] == ma and l.symbols.items[r.b] == na) return;
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
    for (l.imports.items, 0..) |existing, i| {
        if (l.symbols.items[@intFromEnum(existing.module)] == module) {
            try l.reportPair(.duplicate_import, name_token, l.importToken(i, .module));
            return;
        }
    }
    for (l.imports.items, 0..) |existing, i| {
        if (l.symbols.items[@intFromEnum(existing.alias)] == alias) {
            try l.reportPair(.duplicate_import_alias, alias_token, l.importToken(i, .alias));
            break;
        }
    }

    const import_index: u32 = @intCast(l.imports.items.len);
    const module_index = try l.addSymbol(module);
    const alias_index = if (imp.alias != null) try l.addSymbol(alias) else module_index;
    const exposed_start: u32 = @intCast(l.exposed.items.len);
    for (imp.exposed) |e| {
        if (l.tree.nodeTag(e) != .exposed) continue;
        const token = l.tree.nodeMainToken(e);
        const symbol = l.tokenSymbol(token);
        try l.exposed.append(l.gpa, .{ .name = try l.addSymbol(symbol), .token = token });
        const entry: NameEntry = .{ .kind = .exposed, .index = import_index, .token = token };
        switch (l.tags[token]) {
            .lower_ident => try l.expose(&l.values, symbol, entry),
            .upper_ident => {
                // A type or a constructor — the file cannot tell (§5.2),
                // so the name is visible in both namespaces. Both tables
                // see the same duplicates, so only one reports.
                try l.expose(&l.ctor_names, symbol, entry);
                if (!l.types.contains(symbol)) try l.types.put(l.scratch_allocator, symbol, entry);
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
fn expose(l: *Lower, table: *std.AutoHashMapUnmanaged(Symbol, NameEntry), symbol: Symbol, entry: NameEntry) Allocator.Error!void {
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
            else => {}, // the parser puts only the kinds above at the root
        }
    }
    l.decl_stamp = try l.scratch_allocator.alloc(u32, l.decls.items.len);
    @memset(l.decl_stamp, 0);
    l.ctor_stamp = try l.scratch_allocator.alloc(u32, l.ctors.items.len);
    @memset(l.ctor_stamp, 0);
}

fn newDecl(l: *Lower, kind: Bir.Decl.Kind, name_token: TokenIndex, header: Ast.DeclHeader) Allocator.Error!u32 {
    const index: u32 = @intCast(l.decls.items.len);
    try l.decls.append(l.gpa, .{
        .kind = kind,
        .name = try l.addSymbol(l.tokenSymbol(name_token)),
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
        .body = .none,
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

/// Register `symbol` declared at `token` in `table`, reporting a duplicate
/// or a collision with an `exposing` name. The declaration always wins the
/// slot: resolving to it is the more useful outcome after the report.
fn declareName(l: *Lower, table: *std.AutoHashMapUnmanaged(Symbol, NameEntry), symbol: Symbol, token: TokenIndex, index: u32, duplicate: diagnostic.Code, check_exposed: bool) Allocator.Error!void {
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
    if (tag == .foreign_value) try l.checkForeign(header, name_token, name_token - 1);
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
            },
            .foreign_value => {
                const fv = l.tree.fullForeignValue(src.node);
                l.decls.items[i].annotation = (try l.lowerRootType(fv.type_expr)).toOptional();
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

/// Type parameters of a `type`, `type alias` or `foreign type`: recorded
/// on the declaration, checked for duplicates (§7), and made the scope of
/// the body's type variables.
fn lowerTypeParams(l: *Lower, params: []const TokenIndex) Allocator.Error!void {
    const d = &l.decls.items[l.cur_decl];
    d.type_params_start = @intCast(l.symbols.items.len);
    for (params, 0..) |p, i| {
        _ = try l.addSymbol(l.tokenSymbol(p));
        for (params[0..i]) |earlier| {
            if (l.tokenSymbol(earlier) == l.tokenSymbol(p)) {
                try l.reportPair(.duplicate_type_parameter, p, earlier);
                break;
            }
        }
    }
    d.type_params_end = @intCast(l.symbols.items.len);
    d.params = @intCast(params.len);
    l.type_params = params;
}

fn lowerDefinition(l: *Lower, node: NodeIndex, annotation: Node.OptionalIndex) Allocator.Error!void {
    const def = l.tree.fullDefinition(node);
    if (annotation.unwrap()) |ann| {
        const a = l.tree.fullAnnotation(ann);
        l.decls.items[l.cur_decl].annotation = (try l.lowerRootType(a.type_expr)).toOptional();
    }
    const params = try l.lowerParams(def.params);
    try l.frames.append(l.scratch_allocator, Frame.definition(def.params.len > 0, .none));
    const body = try l.lowerExpr(def.body);
    _ = l.frames.pop();
    l.scope.shrinkRetainingCapacity(0);
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
        for (l.scope.items[set_start..]) |entry| {
            if (entry.symbol == symbol) {
                try l.reportPair(.duplicate_pattern_variable, token, entry.token);
                break :check;
            }
        }
        var i = set_start;
        while (i > 0) {
            i -= 1;
            const entry = l.scope.items[i];
            if (entry.symbol == symbol) {
                try l.reportPair(.shadowing, token, entry.token);
                break :check;
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
    if (symbol.unwrap()) |s| try l.scope.append(l.scratch_allocator, .{ .symbol = s, .local = index, .token = token });
    return index;
}

/// A compiler-made local for a desugared lambda: no name, no scope entry.
fn freshLocal(l: *Lower, inst: Index) Allocator.Error!u32 {
    return l.bindLocal(.none, 0, .fresh, inst);
}

fn lookupLocal(l: *const Lower, symbol: Symbol) ?u32 {
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
    try l.reportToken(.unbound_constructor, token);
    return l.errorInst(.unbound_constructor);
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
    try l.reportToken(.unbound_type, token);
    return l.errorInst(.unbound_type);
}

fn importModule(l: *const Lower, import_index: u32) Symbol {
    return l.symbols.items[@intFromEnum(l.imports.items[import_index].module)];
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
        for (l.imports.items) |imp| {
            if (imp.prelude) break;
            if (std.mem.eql(u8, l.interner.slice(l.symbols.items[@intFromEnum(imp.alias)]), module_text)) {
                break :found l.symbols.items[@intFromEnum(imp.module)];
            }
        }
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

fn lowerType(l: *Lower, node: NodeIndex) Allocator.Error!Index {
    const main_token = l.tree.nodeMainToken(node);
    l.cur_token = main_token;
    const data = l.tree.nodeData(node);
    switch (l.tree.nodeTag(node)) {
        .type_var => return l.lowerTypeVarMarked(l.tree.nodeMainToken(node), @enumFromInt(data.lhs)),
        .type_con => {
            const con = l.tree.fullTypeCon(node);
            const ref = switch (l.tags[con.name]) {
                .qualified_upper => try l.resolveQualified(con.name, .type_qualified, .import_type, .unbound_type),
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
            const param = try l.lowerType(@enumFromInt(data.lhs));
            const result = try l.lowerType(@enumFromInt(data.rhs));
            return l.addInstAt(main_token, .type_fn, param.int(), result.int());
        },
        .type_unit => return l.addInst(.type_unit, 0, 0),
        .type_paren => return l.lowerType(l.tree.operand(node)),
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
fn lowerTypeFields(l: *Lower, fields: []const NodeIndex) Allocator.Error!SubRange {
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (fields) |f| {
        if (l.tree.nodeTag(f) != .record_type_field) continue;
        const name = try l.addSymbol(l.tokenSymbol(l.tree.nodeMainToken(f)));
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
fn lowerTypeVarMarked(l: *Lower, token: TokenIndex, marker: Ast.OptionalTokenIndex) Allocator.Error!Index {
    l.cur_token = token;
    const symbol = l.tokenSymbol(token);
    const name = try l.addSymbol(symbol);
    var info: Bir.TypeVarInfo = .{ .param = Bir.TypeVarInfo.param_none, .equatable = false };
    if (l.type_params) |params| {
        for (params, 0..) |p, i| {
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
            .qualified_lower => l.resolveQualified(main_token, .qualified, .import_value, .unbound_variable),
            else => l.resolveValue(main_token),
        },
        .ctor => return switch (l.tags[main_token]) {
            .qualified_upper => l.resolveQualified(main_token, .qualified_ctor, .import_ctor, .unbound_constructor),
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
        .op_fn => return l.operatorRef(l.tags[main_token]),
        .unit => return l.addInst(.unit, 0, 0),
        .negate => {
            const operand = try l.lowerExpr(l.tree.operand(node));
            const negate = try l.basicsRef(.negate);
            return l.call(negate, &.{operand.int()});
        },
        .paren => return l.lowerExpr(l.tree.operand(node)),
        .tuple, .list => {
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (l.tree.children(node)) |elem| try l.pushScratch(try l.lowerExpr(elem));
            const range = try l.addRange(l.scratchSince(mark));
            return l.addInstAt(main_token, if (tag == .tuple) .tuple else .list, @intFromEnum(range.start), @intFromEnum(range.end));
        },
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
            const callee = try l.lowerExpr(app.function);
            const mark = l.scratchMark();
            defer l.shrinkScratch(mark);
            for (app.args) |arg| try l.pushScratch(try l.lowerExpr(arg));
            l.cur_token = main_token;
            return l.call(callee, l.scratchSince(mark));
        },
        .question => return l.lowerQuestion(node),
        .pipe_right => {
            // `x |> f a` → `f a x` (§8.2).
            const b = l.tree.fullBinop(node);
            const arg = try l.lowerExpr(b.lhs);
            return l.saturate(b.rhs, arg);
        },
        .pipe_left => {
            // `f a <| x` → `f a x`.
            const b = l.tree.fullBinop(node);
            const arg = try l.lowerExpr(b.rhs);
            return l.saturate(b.lhs, arg);
        },
        .compose_right, .compose_left => return l.lowerCompose(node, tag),
        .lambda => {
            const lam = l.tree.fullLambda(node);
            const mark = l.scope.items.len;
            const params = try l.lowerParams(lam.params);
            try l.frames.append(l.scratch_allocator, .{ .kind = .lambda, .inst = .none });
            const body = try l.lowerExpr(lam.body);
            _ = l.frames.pop();
            l.scope.shrinkRetainingCapacity(mark);
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
        // Every other binary operator: a call of its core function.
        .add, .sub, .mul, .div, .int_div, .pow, .append, .cons, .eq, .neq, .lt, .gt, .lte, .gte, .bool_and, .bool_or => {
            const b = l.tree.fullBinop(node);
            const lhs = try l.lowerExpr(b.lhs);
            const rhs = try l.lowerExpr(b.rhs);
            const function = try l.operatorRef(l.tags[b.op_token]);
            l.cur_token = b.op_token;
            return l.call(function, &.{ lhs.int(), rhs.int() });
        },
        else => {
            std.debug.assert(tag.isError());
            return l.errorInst(l.tree.fullError(node).code);
        },
    }
}

fn call(l: *Lower, callee: Index, args: []const u32) Allocator.Error!Index {
    const range = try l.addRangeRecord(try l.addRange(args));
    return l.addInst(.call, callee.int(), @intFromEnum(range));
}

/// The core function of language.md §6.5's table for an operator token,
/// **with the module that defines it**. Almost every operator is a
/// `Basics` function, but not all of them: `::` is `List.cons` (Elm's
/// `(::)` is `List.cons`, and core puts it there), so the home module is
/// per operator rather than assumed — checker.md §4.3. Getting this wrong
/// is invisible until name resolution looks the function up in the wrong
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
        .op_colon_colon => .{ .module = .List, .function = .cons },
        .op_eq_eq => .{ .module = .Basics, .function = .eq },
        .op_slash_eq => .{ .module = .Basics, .function = .neq },
        .op_lt => .{ .module = .Basics, .function = .lt },
        .op_gt => .{ .module = .Basics, .function = .gt },
        .op_lte => .{ .module = .Basics, .function = .le },
        .op_gte => .{ .module = .Basics, .function = .ge },
        .op_and_and => .{ .module = .Basics, .function = .@"and" },
        .op_or_or => .{ .module = .Basics, .function = .@"or" },
        .op_pipe_left => .{ .module = .Basics, .function = .apL },
        .op_pipe_right => .{ .module = .Basics, .function = .apR },
        .op_compose_left => .{ .module = .Basics, .function = .composeL },
        .op_compose_right => .{ .module = .Basics, .function = .composeR },
        else => unreachable, // `op_fn` and binop nodes hold operator tokens only
    };
}

/// Apply `function_node` to one more argument, flattening an application:
/// `f a` with `x` becomes `f a x` (the one place the front end changes call
/// arity, §8.2). Grouping parentheses are looked through.
fn saturate(l: *Lower, function_node: NodeIndex, extra_arg: Index) Allocator.Error!Index {
    var fnode = function_node;
    while (l.tree.nodeTag(fnode) == .paren) fnode = l.tree.operand(fnode);
    if (l.tree.nodeTag(fnode) == .apply) {
        const app = l.tree.fullApply(fnode);
        const callee = try l.lowerExpr(app.function);
        const mark = l.scratchMark();
        defer l.shrinkScratch(mark);
        for (app.args) |arg| try l.pushScratch(try l.lowerExpr(arg));
        try l.pushScratch(extra_arg);
        return l.call(callee, l.scratchSince(mark));
    }
    const callee = try l.lowerExpr(fnode);
    return l.call(callee, &.{extra_arg.int()});
}

/// `f >> g` → `\x -> g (f x)`, `f << g` → `\x -> f (g x)` (§8.2). A chain of
/// the same operator is flattened first — `a >> b >> c` is one lambda
/// `\x -> c (b (a x))` — since the parser has already rejected mixed
/// chains (`non_associative_chain`). The functions are lowered before the
/// lambda is opened: they are evaluated when the composition is built, so
/// a `?` in them belongs to the enclosing definition, not to the lambda.
fn lowerCompose(l: *Lower, node: NodeIndex, op: Node.Tag) Allocator.Error!Index {
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    try l.collectComposeChain(node, op);
    const functions = l.scratchSince(mark);
    // Which function applies first: the leftmost for `>>`, the rightmost
    // for `<<`.
    const param = try l.reserveInst(.pat_var);
    const local = try l.freshLocal(param);
    l.setInstData(param, local, Inst.Data.unused);
    var value = try l.addInst(.local, local, Inst.Data.unused);
    var i: usize = 0;
    while (i < functions.len) : (i += 1) {
        const f: Index = @enumFromInt(if (op == .compose_right) functions[i] else functions[functions.len - 1 - i]);
        value = try l.call(f, &.{value.int()});
    }
    const params = try l.addRangeRecord(try l.addRange(&.{param.int()}));
    return l.addInst(.lambda, @intFromEnum(params), value.int());
}

/// Lower every operand of a chain of `op`, left to right, onto the scratch
/// list. Only bare chains flatten; a parenthesised sub-composition is a
/// function like any other.
fn collectComposeChain(l: *Lower, node: NodeIndex, op: Node.Tag) Allocator.Error!void {
    if (l.tree.nodeTag(node) == op) {
        const b = l.tree.fullBinop(node);
        try l.collectComposeChain(b.lhs, op);
        try l.collectComposeChain(b.rhs, op);
    } else {
        try l.pushScratch(try l.lowerExpr(node));
    }
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
    l.scope.shrinkRetainingCapacity(mark);
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
    const scope_mark = l.scope.items.len;
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);

    // Phase 1: bind. `let_def` gets its instruction now (its index is the
    // `try` target of its body); a `let_pattern` lowers its pattern now
    // (irrefutable, so it resolves nothing) and its value later.
    for (let_node.bindings) |b| {
        switch (l.tree.nodeTag(b)) {
            .let_def => {
                const inst = try l.reserveInst(.let_def);
                _ = try l.bindVar(l.tree.nodeMainToken(b), l.scope.items.len, .let, inst);
                try l.pushScratch(inst);
            },
            .let_pattern => {
                const lp = l.tree.fullLetPattern(b);
                const pat = try l.lowerPattern(lp.pattern, l.scope.items.len, .pattern);
                try l.pushScratch(pat);
            },
            else => {}, // annotations are read in phase 2; error bindings are skipped
        }
    }

    // Phase 2: bodies, in source order, each patched into its binding.
    var pending_annotation: Inst.OptionalIndex = .none;
    var pending_annotation_name: ?Symbol = null;
    var slot: usize = mark;
    for (let_node.bindings) |b| {
        switch (l.tree.nodeTag(b)) {
            .let_annotation => {
                pending_annotation = (try l.lowerRootType(l.tree.operand(b))).toOptional();
                pending_annotation_name = l.tokenSymbol(l.tree.nodeMainToken(b));
            },
            .let_def => {
                const inst: Index = @enumFromInt(l.list_scratch.items[slot]);
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
                l.scope.shrinkRetainingCapacity(inner_mark);
                const record = try l.addExtra(Bir.LetDef{
                    .local = l.localOfInst(inst),
                    .annotation = annotation,
                    .params_start = params.start,
                    .params_end = params.end,
                });
                l.setInstData(inst, @intFromEnum(record), body.int());
                slot += 1;
            },
            .let_pattern => {
                const pat: Index = @enumFromInt(l.list_scratch.items[slot]);
                const lp = l.tree.fullLetPattern(b);
                const value = try l.lowerExpr(lp.value);
                l.list_scratch.items[slot] = (try l.addInst(.let_pattern, pat.int(), value.int())).int();
                slot += 1;
            },
            else => {},
        }
    }
    const body = try l.lowerExpr(let_node.body);
    l.scope.shrinkRetainingCapacity(scope_mark);
    const bindings = try l.addRangeRecord(try l.addRange(l.scratchSince(mark)));
    return l.addInst(.let, @intFromEnum(bindings), body.int());
}

/// The local index a reserved `let_def` instruction binds (its `Local`
/// row points back at it).
fn localOfInst(l: *const Lower, inst: Index) u32 {
    const rows = l.locals.items[l.cur_locals_start..];
    var i = rows.len;
    while (i > 0) {
        i -= 1;
        if (rows[i].inst == inst) return @intCast(i);
    }
    unreachable; // every reserved let_def bound a local in phase 1
}

/// Record fields to a range of `Field` pairs, with `duplicate_field` (§6.3).
fn lowerFields(l: *Lower, fields: []const NodeIndex) Allocator.Error!SubRange {
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (fields) |f| {
        if (l.tree.nodeTag(f) != .field) continue;
        const name_token = l.tree.nodeMainToken(f);
        const symbol = l.tokenSymbol(name_token);
        // Fields written so far: every second scratch word is a name.
        const written = l.scratchSince(mark);
        var j: usize = 0;
        while (j < written.len) : (j += 2) {
            if (l.symbols.items[written[j]] == symbol) {
                try l.reportToken(.duplicate_field, name_token);
                break;
            }
        }
        const name = try l.addSymbol(symbol);
        const value = try l.lowerExpr(l.tree.operand(f));
        try l.pushScratch(name);
        try l.pushScratch(value);
    }
    return l.addRange(l.scratchSince(mark));
}

/// A string literal (§2.6): a `string` when it has no interpolation, else
/// an `interp` of `chunk`s and expressions. Escapes are decoded here.
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
        return l.addInst(.string, offset, @as(u32, @intCast(l.string_bytes.items.len)) - offset);
    }
    const mark = l.scratchMark();
    defer l.shrinkScratch(mark);
    for (s.parts) |p| {
        switch (l.tree.nodeTag(p)) {
            .chunk => {
                const offset: u32 = @intCast(l.string_bytes.items.len);
                try decodeChunk(l.tokenText(l.tree.nodeMainToken(p)), l.gpa, &l.string_bytes);
                try l.pushScratch(try l.addInst(.chunk, offset, @as(u32, @intCast(l.string_bytes.items.len)) - offset));
            },
            .interp => try l.pushScratch(try l.lowerExpr(l.tree.operand(p))),
            else => {},
        }
    }
    const range = try l.addRange(l.scratchSince(mark));
    return l.addInst(.interp, @intFromEnum(range.start), @intFromEnum(range.end));
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
                .qualified_upper => try l.resolveQualified(pc.name, .qualified_ctor, .import_ctor, .unbound_constructor),
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
        .pat_cons => {
            const head = try l.lowerPattern(@enumFromInt(data.lhs), set_start, .pattern);
            const tail = try l.lowerPattern(@enumFromInt(data.rhs), set_start, .pattern);
            return l.addInst(.pat_cons, head.int(), tail.int());
        },
        .pat_as => {
            const pa = l.tree.fullPatAs(node);
            const inner = try l.lowerPattern(pa.pattern, set_start, .pattern);
            const inst = try l.reserveInst(.pat_as);
            const local = try l.bindVar(pa.name, set_start, .pattern, inst);
            l.setInstData(inst, inner.int(), local);
            return inst;
        },
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
        if (d.kind == .value) {
            try checkRange(.{ .start = d.params_start, .end = d.params_end }, n_extra);
            for (bir.extraSlice(.{ .start = d.params_start, .end = d.params_end }, Index)) |p| try checkInDecl(d, p);
        }
        for (bir.declLocals(d)) |l| {
            if (l.name != .none) try checkSymbol(bir, l.name);
            try checkInDecl(d, l.inst);
        }
        for (bir.declRefs(d)) |r| switch (r.kind) {
            .top_value, .top_type => try testing.expect(r.a < bir.decls.len),
            .top_ctor => try testing.expect(r.a < bir.ctors.len),
            .import_value, .import_ctor, .import_type => {
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
        // Lowering never produces these; `resolve/Resolve.zig` rewrites
        // the forms above into them after the module graph exists.
        .ext_value, .ext_ctor, .ext_type => return error.TestUnexpectedResult,
        .type_var => {
            try testing.expect(data.lhs < bir.symbols.len);
            const info = Bir.TypeVarInfo.unpack(data.rhs);
            if (info.param != Bir.TypeVarInfo.param_none) try testing.expect(info.param < d.params);
        },
        .type_app, .call, .pat_ctor => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try checkInstList(bir, d, try checkRecordAt(bir, data.rhs));
        },
        .type_fn, .let_pattern, .branch, .pat_cons => {
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
        .char, .pat_char => try testing.expect(data.lhs <= 0x10FFFF),
        .field_access => {
            try checkInDecl(d, @enumFromInt(data.lhs));
            try testing.expect(data.rhs < bir.symbols.len);
        },
        .tuple_index => try checkInDecl(d, @enumFromInt(data.lhs)),
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
        .@"error" => try testing.expect(data.lhs < @typeInfo(diagnostic.Code).@"enum".fields.len),
    }
}

// ---- Desugarings (§8.2) ---------------------------------------------------------

test "operators become calls of their core functions, `(+)` the function itself, `-x` a negate call" {
    try expectDecls(
        \\f a b =
        \\    ( a + b, a // b, a :: [], (+), -a )
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

test "every binary operator maps to the §6.5 core function" {
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
        \\  %24 = import_value Basics.eq
        \\  %25 = call %24 [%22, %23]
        \\  %26 = local 0 (a)
        \\  %27 = local 1 (b)
        \\  %28 = import_value Basics.neq
        \\  %29 = call %28 [%26, %27]
        \\  %30 = local 0 (a)
        \\  %31 = local 1 (b)
        \\  %32 = import_value Basics.lt
        \\  %33 = call %32 [%30, %31]
        \\  %34 = local 0 (a)
        \\  %35 = local 1 (b)
        \\  %36 = import_value Basics.gt
        \\  %37 = call %36 [%34, %35]
        \\  %38 = local 0 (a)
        \\  %39 = local 1 (b)
        \\  %40 = import_value Basics.le
        \\  %41 = call %40 [%38, %39]
        \\  %42 = local 0 (a)
        \\  %43 = local 1 (b)
        \\  %44 = import_value Basics.ge
        \\  %45 = call %44 [%42, %43]
        \\  %46 = local 0 (a)
        \\  %47 = local 1 (b)
        \\  %48 = import_value Basics.and
        \\  %49 = call %48 [%46, %47]
        \\  %50 = local 0 (a)
        \\  %51 = local 1 (b)
        \\  %52 = import_value Basics.or
        \\  %53 = call %52 [%50, %51]
        \\  %54 = list [%5, %9, %13, %17, %21, %25, %29, %33, %37, %41, %45, %49, %53]
        \\  params [%0, %1]
        \\  body %54
        \\  locals
        \\    0 a param %0
        \\    1 b param %1
        \\  refs
        \\    import_value Basics.sub
        \\    import_value Basics.mul
        \\    import_value Basics.fdiv
        \\    import_value Basics.pow
        \\    import_value Basics.append
        \\    import_value Basics.eq
        \\    import_value Basics.neq
        \\    import_value Basics.lt
        \\    import_value Basics.gt
        \\    import_value Basics.le
        \\    import_value Basics.ge
        \\    import_value Basics.and
        \\    import_value Basics.or
        \\
    , &.{});
}

test "`::` desugars to List.cons, not Basics.cons" {
    // checker.md §4.3: `::` is `List.cons` and `++` is `Basics.append`,
    // matching Elm, where `(::)` is `List.cons`. Assuming `Basics` for
    // every operator emitted `import_value Basics.cons` — a name no
    // interface has — and nothing noticed, because name resolution against
    // interfaces is M2. The home module is per operator for this reason.
    try expectDecls(
        \\f x xs =
        \\    x :: xs
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

test "the operator table gives every operator a home module, and only `::` leaves Basics" {
    const ops = [_]Token.Tag{
        .op_plus,        .op_minus,      .op_star,         .op_slash,
        .op_slash_slash, .op_caret,      .op_plus_plus,    .op_colon_colon,
        .op_eq_eq,       .op_slash_eq,   .op_lt,           .op_gt,
        .op_lte,         .op_gte,        .op_and_and,      .op_or_or,
        .op_pipe_left,   .op_pipe_right, .op_compose_left, .op_compose_right,
    };
    for (ops) |op| {
        const f = operatorFunction(op);
        const expected: InternPool.WellKnown = if (op == .op_colon_colon) .List else .Basics;
        testing.expectEqual(expected, f.module) catch |err| {
            std.debug.print("operator {t} resolved to module {t}\n", .{ op, f.module });
            return err;
        };
    }
    try testing.expectEqualDeep(OperatorFunction{ .module = .List, .function = .cons }, operatorFunction(.op_colon_colon));
    try testing.expectEqualDeep(OperatorFunction{ .module = .Basics, .function = .append }, operatorFunction(.op_plus_plus));
}

test "`|>` and `<|` flatten into saturated calls, through grouping parentheses" {
    try expectDecls(
        \\f g x =
        \\    ( x |> g 1, g <| x, x |> (g 1) |> g, g <| g <| x, x |> \y -> y )
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (g)
        \\  %1 = pat_var local 1 (x)
        \\  %2 = local 1 (x)
        \\  %3 = local 0 (g)
        \\  %4 = int 1
        \\  %5 = call %3 [%4, %2]
        \\  %6 = local 1 (x)
        \\  %7 = local 0 (g)
        \\  %8 = call %7 [%6]
        \\  %9 = local 1 (x)
        \\  %10 = local 0 (g)
        \\  %11 = int 1
        \\  %12 = call %10 [%11, %9]
        \\  %13 = local 0 (g)
        \\  %14 = call %13 [%12]
        \\  %15 = local 1 (x)
        \\  %16 = local 0 (g)
        \\  %17 = call %16 [%15]
        \\  %18 = local 0 (g)
        \\  %19 = call %18 [%17]
        \\  %20 = local 1 (x)
        \\  %21 = pat_var local 2 (y)
        \\  %22 = local 2 (y)
        \\  %23 = lambda [%21] -> %22
        \\  %24 = call %23 [%20]
        \\  %25 = tuple [%5, %8, %14, %19, %24]
        \\  params [%0, %1]
        \\  body %25
        \\  locals
        \\    0 g param %0
        \\    1 x param %1
        \\    2 y param %21
        \\
    , &.{});
}

test "`>>` and `<<` become one lambda per chain, applied in the right order" {
    try expectDecls(
        \\f a b c =
        \\    ( a >> b >> c, a << b << c )
        \\
    ,
        \\decl 0: value f
        \\  %0 = pat_var local 0 (a)
        \\  %1 = pat_var local 1 (b)
        \\  %2 = pat_var local 2 (c)
        \\  %3 = local 0 (a)
        \\  %4 = local 1 (b)
        \\  %5 = local 2 (c)
        \\  %6 = pat_var local 3
        \\  %7 = local 3
        \\  %8 = call %3 [%7]
        \\  %9 = call %4 [%8]
        \\  %10 = call %5 [%9]
        \\  %11 = lambda [%6] -> %10
        \\  %12 = local 0 (a)
        \\  %13 = local 1 (b)
        \\  %14 = local 2 (c)
        \\  %15 = pat_var local 4
        \\  %16 = local 4
        \\  %17 = call %14 [%16]
        \\  %18 = call %13 [%17]
        \\  %19 = call %12 [%18]
        \\  %20 = lambda [%15] -> %19
        \\  %21 = tuple [%11, %20]
        \\  params [%0, %1, %2]
        \\  body %21
        \\  locals
        \\    0 a param %0
        \\    1 b param %1
        \\    2 c param %2
        \\    3 _ fresh %6
        \\    4 _ fresh %15
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
        \\        ( Just (x :: rest) as whole, { a, b }, [ 1, -2, 'c', "s", () ], _ ) ->
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
        \\  %5 = pat_cons %3 :: %4
        \\  %6 = pat_ctor %2 [%5]
        \\  %7 = pat_as %6 as local 3 (whole)
        \\  %8 = pat_record [local 4 (a), local 5 (b)]
        \\  %9 = pat_int 1
        \\  %10 = pat_int -2
        \\  %11 = pat_char 'c'
        \\  %12 = pat_string "s"
        \\  %13 = pat_unit
        \\  %14 = pat_list [%9, %10, %11, %12, %13]
        \\  %15 = pat_wild
        \\  %16 = pat_tuple [%7, %8, %14, %15]
        \\  %17 = local 1 (x)
        \\  %18 = branch %16 -> %17
        \\  %19 = pat_wild
        \\  %20 = int 0
        \\  %21 = branch %19 -> %20
        \\  %22 = case %1 [%18, %21]
        \\  params [%0]
        \\  body %22
        \\  locals
        \\    0 p param %0
        \\    1 x pattern %3
        \\    2 rest pattern %4
        \\    3 whole pattern %7
        \\    4 a pattern %8
        \\    5 b pattern %8
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

test "let bindings are in scope in every body; a let name may not reuse a parameter or a sibling" {
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
        \\pub foreign add : Int -> Int -> Int
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
        \\decl 0: pub foreign value add
        \\  doc "Doc."
        \\  %0 = type_import Basics.Int
        \\  %1 = type_import Basics.Int
        \\  %2 = type_import Basics.Int
        \\  %3 = type_fn %1 -> %2
        \\  %4 = type_fn %0 -> %3
        \\  annotation %4
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
        \\  %0 = type_import Basics.String
        \\  ctor 3 Token [%0]
        \\  refs
        \\    import_type Basics.String
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
// `BENI_STRESS_ITERATIONS` raises the count for a long run.
test "stress: mutated corpus fixtures never panic and always lower in bounds" {
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
