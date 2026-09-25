//! The one emit path, `quiet` once, failure as state (checker-v2.md §15.1,
//! §15.2, I12; CK-11, CK-14).
//!
//! **`emit` is the only way anything reaches the module's diagnostics.** It
//! drops the message when the module is quiet, and sets the failure bit of
//! the declaration being checked when the message is an error. Nothing in
//! `src/check2/` appends to the list any other way, and nothing tests a
//! diagnostic's region against an instruction range.
//!
//! **The texts are v1's** (§19: `Diagnostics.zig` texts kept verbatim). They
//! are `Diagnostics.Reporter` methods, which append to a list and read a
//! `Constrain.Env`. `Report` owns one such reporter, never quiet, appending
//! to a STAGING list only `Report` reads; each method here calls the text,
//! then `flush` moves what it staged through `emit` (§15.1, *As built by
//! R4b*). `at` sets the declaration a message is about — and with it the
//! locals the texts name a callee from — which is the one generation-time
//! fact the texts read, and they read it here, never in the solver (I11).
//!
//! **Two texts are v2's own** (§15.3, `checker.md` §8.5): the annotation
//! escape of §8.3 (CK-01) and the infinite type written as its structure
//! (§8.2, CK-57). v1 keeps its own until the cut-over.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Diagnostics = @import("../check/Diagnostics.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Render = @import("../check/Render.zig");
const TypeStore = @import("../check/TypeStore.zig");
const EnvFile = @import("../check/Env.zig");
const Context = @import("Context.zig");

const Report = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;
pub const Item = Diagnostics.Item;
pub const Callee = Diagnostics.Callee;
pub const Rigid = Diagnostics.Reporter.Rigid;
const Category = @import("../check/Category.zig").Category;

gpa: Allocator,
module: Graph.Index,
/// The module's list: `emit` is its only writer.
items: *std.ArrayList(Item),
/// An earlier phase reported on the module, or the graph poisoned it
/// (checker.md §4.3): every message is dropped, once, here.
quiet: bool,
/// I12: one bit per declaration, set iff an ERROR was attributed to it or
/// (at its group's boundary) to a member of its group.
failed: std.DynamicBitSetUnmanaged = .{},
/// The same, less the declarations whose only errors are `infinite_type`:
/// what P7 skips (§15.2 *As built by R4b's review*, F9). Exhaustiveness
/// reads no solved type (CK-61), and an infinite type says nothing about a
/// pattern, so a `case` beside one is still checked.
failed_patterns: std.DynamicBitSetUnmanaged = .{},
/// The declaration a message is attributed to, or none outside a group.
current: ?u32 = null,
/// Errors emitted, dropped ones included: what the plan gate reads.
errors: u32 = 0,
/// Per local of the module, what the generator bound it to: the texts name
/// a callee from it (`Reporter.describe`).
local_type: []Var.Optional = &.{},

staged: std.ArrayList(Item) = .empty,
env: EnvFile.Env = undefined,
texts: Diagnostics.Reporter = undefined,
monomorphic: std.ArrayList(EnvFile.Monomorphic) = .empty,
dispatch_unused: Dispatch.Builder = undefined,
/// The v1 `Env`'s note list, which the texts never write: v2's notes are
/// `Context.too_deep`.
unused_too_deep: std.ArrayList(Bir.Inst.Index) = .empty,

/// In place: the staging reporter points into `r` itself.
pub fn init(
    r: *Report,
    cx: *const Context,
    items: *std.ArrayList(Item),
    quiet: bool,
    decl_scheme: []Var.Optional,
    local_type: []Var.Optional,
) Error!void {
    r.* = .{ .gpa = cx.gpa, .module = cx.module, .items = items, .quiet = quiet, .local_type = local_type };
    r.failed = try .initEmpty(cx.gpa, cx.bir.decls.len);
    r.failed_patterns = try .initEmpty(cx.gpa, cx.bir.decls.len);
    r.dispatch_unused = .{ .gpa = cx.gpa };
    r.env = .{
        .scratch = cx.scratch,
        .store = cx.store,
        .types = cx.types,
        .graph = cx.graph,
        .artifacts = cx.artifacts,
        .interner = cx.interner,
        .interfaces = cx.interfaces,
        .module = cx.module,
        .bir = cx.bir,
        .schemas = cx.schemas,
        .decl_scheme = decl_scheme,
        .local_var = &.{},
        .inst_result = &.{},
        .inst_base = 0,
        .monomorphic = &r.monomorphic,
        .dispatch = &r.dispatch_unused,
        .too_deep = &r.unused_too_deep,
    };
    r.texts = .{ .gpa = cx.gpa, .env = &r.env, .items = &r.staged };
}

pub fn deinit(r: *Report) void {
    for (r.staged.items) |item| r.gpa.free(item.message);
    r.staged.deinit(r.gpa);
    r.failed.deinit(r.gpa);
    r.failed_patterns.deinit(r.gpa);
    r.monomorphic.deinit(r.env.scratch);
    r.dispatch_unused.deinit();
}

/// The one path to the module's list (§15.1). Takes ownership of
/// `item.message`.
pub fn emit(r: *Report, item: Item) Error!void {
    if (item.severity == .@"error") {
        r.errors += 1;
        if (r.current) |d| {
            r.failed.set(d);
            if (item.code != .infinite_type) r.failed_patterns.set(d);
        }
    }
    return appendTo(r.gpa, r.items, r.quiet, item);
}

/// The list half of `emit`, for the one caller that has no `Report` yet — P0's
/// refusal, which runs before P1 builds one. Takes ownership of the message.
pub fn appendTo(gpa: Allocator, items: *std.ArrayList(Item), quiet: bool, item: Item) Error!void {
    // An `internal` is the compiler's own failure and is said even in a
    // quiet module (v1's `internalAlways`).
    if (quiet and item.code != .internal) {
        gpa.free(item.message);
        return;
    }
    errdefer gpa.free(item.message);
    try items.append(gpa, item);
}

/// §15.2: the members of a group share variables, so one failure fails
/// them all (I12's one owner is `Report`).
pub fn failGroup(r: *Report, members: []const u32) void {
    for ([_]*std.DynamicBitSetUnmanaged{ &r.failed, &r.failed_patterns }) |bits| {
        for (members) |m| {
            if (!bits.isSet(m)) continue;
            for (members) |other| bits.set(other);
            break;
        }
    }
}

/// Move everything the staging reporter wrote through `emit`.
pub fn flush(r: *Report) Error!void {
    for (r.staged.items, 0..) |item, i| {
        r.emit(item) catch |err| {
            for (r.staged.items[i + 1 ..]) |rest| r.gpa.free(rest.message);
            r.staged.clearRetainingCapacity();
            return err;
        };
    }
    r.staged.clearRetainingCapacity();
}

/// Attribute what follows to declaration `decl` (or to nothing).
pub fn at(r: *Report, decl: ?u32) void {
    r.current = decl;
    const d = decl orelse {
        r.env.local_var = &.{};
        r.env.locals_base = 0;
        return;
    };
    const bir = r.env.bir;
    const decl_row = bir.decls[d];
    r.env.decl = d;
    r.env.locals_base = decl_row.locals_start;
    r.env.local_var = r.local_type[decl_row.locals_start..decl_row.locals_end];
}

/// The shared reporter, for the kept passes that take one (`Exhaustive`,
/// `Cycles`). The caller `flush`es after.
pub fn staging(r: *Report) *Diagnostics.Reporter {
    return &r.texts;
}

/// A message with no text of v1's to reuse, built here.
pub fn emitText(r: *Report, code: diagnostic.Code, region: Bir.Inst.Index, token: ?u32, text: []const u8) Error!void {
    const message = try r.gpa.dupe(u8, text);
    try r.emit(.{ .code = code, .module = r.module, .region = region, .token = token, .message = message });
}

// ---------------------------------------------------------------------------
// v1's texts, staged and flushed
// ---------------------------------------------------------------------------

pub fn calleeOf(r: *const Report, region: Bir.Inst.Index) Callee {
    return r.texts.calleeOf(region);
}

pub fn mismatch(r: *Report, region: Bir.Inst.Index, category: Category, expected: Var, actual: Var, rigid: ?Rigid) Error!void {
    try r.texts.mismatch(region, category, expected, actual, rigid);
    try r.flush();
}

pub fn kindMismatch(r: *Report, region: Bir.Inst.Index, left: TypeStore.Kind, right: TypeStore.Kind) Error!void {
    try r.texts.kindMismatch(region, left, right);
    try r.flush();
}

pub fn kindNotSatisfied(r: *Report, region: Bir.Inst.Index, category: Category, kind: TypeStore.Kind, expected: Var, actual: Var) Error!void {
    try r.texts.kindNotSatisfied(region, category, kind, expected, actual);
    try r.flush();
}

pub fn notEquatableRigid(r: *Report, region: Bir.Inst.Index, v: Var) Error!void {
    try r.texts.notEquatable(region, v, .rigid_variable);
    try r.flush();
}

pub fn missingField(r: *Report, region: Bir.Inst.Index, names: []Symbol, actual: Var, expected: Var) Error!void {
    try r.texts.missingField(region, names, actual, expected);
    try r.flush();
}

pub fn unknownField(r: *Report, region: Bir.Inst.Index, names: []Symbol, actual: Var, expected: Var) Error!void {
    try r.texts.unknownField(region, names, actual, expected);
    try r.flush();
}

pub fn recordNotClosed(r: *Report, region: Bir.Inst.Index, actual: Var, expected: Var) Error!void {
    try r.texts.recordNotClosed(region, actual, expected);
    try r.flush();
}

pub fn tooFewArgs(r: *Report, region: Bir.Inst.Index, callee: Callee, arity: u32, given: u32, missing: []const Var) Error!void {
    try r.texts.tooFewArgs(region, callee, arity, given, missing);
    try r.flush();
}

pub fn tooManyArgs(r: *Report, region: Bir.Inst.Index, callee: Callee, arity: u32, given: u32) Error!void {
    try r.texts.tooManyArgs(region, callee, arity, given);
    try r.flush();
}

pub fn notAFunction(r: *Report, region: Bir.Inst.Index, callee: Callee, given: u32, actual: Var) Error!void {
    try r.texts.notAFunction(region, callee, given, actual);
    try r.flush();
}

pub fn ctorPatternArity(r: *Report, region: Bir.Inst.Index, callee: Callee, arity: u32, given: u32) Error!void {
    try r.texts.ctorPatternArity(region, callee, arity, given);
    try r.flush();
}

pub fn nestingTooDeep(r: *Report, region: Bir.Inst.Index, limit: u32) Error!void {
    try r.texts.nestingTooDeep(region, limit);
    try r.flush();
}

pub fn internal(r: *Report, region: Bir.Inst.Index, what: []const u8) Error!void {
    try r.texts.internalAlways(region, what);
    try r.flush();
}

// ---------------------------------------------------------------------------
// v2's own texts (`checker.md` §8.5)
// ---------------------------------------------------------------------------

fn renderContext(r: *const Report) Render.Context {
    return .{ .store = r.env.store, .types = r.env.types, .interner = r.env.interner };
}

/// `infinite_type` at `region`, for binder `name` (or "here"), with the
/// cycle through `cycle` — a union-find root on the cycle — written down
/// once, every inner occurrence named (§8.2, CK-57).
///
/// The node's own content is printed through a detached copy while the node
/// itself reads as a plain variable, so the printer names it where it
/// recurs; the content is put back before returning. The caller poisons the
/// node after.
pub fn infiniteType(r: *Report, region: Bir.Inst.Index, name: Symbol.Optional, cycle: Var) Error!void {
    const store = r.env.store;
    const interner = r.env.interner;
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;

    const content = store.content(cycle);
    const shown = try store.fresh(content, store.rank(cycle));
    store.setContent(cycle, .{ .flex = .{} });
    defer store.setContent(cycle, content);
    const repeat = try namer.name(cycle, null);

    if (name.unwrap()) |s| {
        w.print("I am inferring a weird self-referential type for `{s}`:\n\n", .{interner.slice(s)}) catch return error.OutOfMemory;
    } else {
        w.writeAll("I am inferring a weird self-referential type here:\n\n") catch return error.OutOfMemory;
    }
    w.print(
        \\Here is my best effort at writing it down, with `{s}` standing for the whole
        \\type wherever it repeats inside itself:
        \\
        \\
    , .{repeat}) catch return error.OutOfMemory;
    w.print("    {s} = ", .{repeat}) catch return error.OutOfMemory;
    Render.writeVar(w, r.renderContext(), &namer, shown, .top) catch return error.OutOfMemory;
    w.writeAll(
        \\
        \\
        \\Hint: the type would go on forever, so I gave up. This usually means a
        \\definition is missing an argument, or is being used with one argument too
        \\many, somewhere inside itself.
        \\
    ) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = .infinite_type, .module = r.module, .region = region, .message = message });
}

/// `rigid_mismatch` for an annotation escape (§8.3, D7, CK-01): binding
/// `binding` declares `scheme`, and its variable `rigid` was tied to a type
/// of `enclosing`, the declaration it is written in.
pub fn escape(
    r: *Report,
    region: Bir.Inst.Index,
    binding: Symbol.Optional,
    enclosing: Symbol,
    scheme: Var,
    rigid: Var,
) Error!void {
    const store = r.env.store;
    const interner = r.env.interner;
    var out: std.Io.Writer.Allocating = .init(r.gpa);
    defer out.deinit();
    var namer: Render.Namer = .init(r.gpa);
    defer namer.deinit();
    const w = &out.writer;
    const name = if (binding.unwrap()) |s| interner.slice(s) else "this binding";
    const outer = interner.slice(enclosing);
    const variable = switch (store.content(store.find(rigid))) {
        .rigid, .flex => |flags| if (flags.name.unwrap()) |s| interner.slice(s) else "a",
        else => "a",
    };
    w.print("The type annotation of `{s}` promises more than its body keeps:\n\n    {s} : ", .{ name, name }) catch return error.OutOfMemory;
    Render.writeVar(w, r.renderContext(), &namer, scheme, .top) catch return error.OutOfMemory;
    w.print(
        \\
        \\
        \\The annotation says `{s}` can be ANY type, but the body ties `{s}` to a type that
        \\comes from `{s}`, the definition `{s}` is written inside. That type is fixed for
        \\each call of `{s}`, so `{s}` does not work for every `{s}`.
        \\
        \\Hint: write the enclosing definition's type in the annotation instead of `{s}`,
        \\or remove the annotation and let the type be inferred.
        \\
    , .{ variable, variable, outer, name, outer, name, variable, variable }) catch return error.OutOfMemory;
    const message = try out.toOwnedSlice();
    try r.emit(.{ .code = .rigid_mismatch, .module = r.module, .region = region, .message = message });
}
