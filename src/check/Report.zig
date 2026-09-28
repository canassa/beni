//! The one emit path, `quiet` once, failure as state (checker-v2.md §15.1,
//! §15.2).
//!
//! **`emit` is the only way anything reaches the module's diagnostics.** It
//! drops the message when the module is quiet, and sets the failure bit of
//! the declaration being checked when the message is an error. Nothing in
//! `src/check/` appends to the list any other way, and nothing tests a
//! diagnostic's region against an instruction range.
//!
//! **The texts are `Diagnostics.zig`'s** (§19). They are
//! `Diagnostics.Reporter` methods, which append to a list and read an
//! `Env` (what the texts read). `Report` owns one such reporter, never
//! quiet, appending to a STAGING list only `Report` reads; each method here
//! calls the text, then `flush` moves what it staged through `emit`
//! (§15.1). `at` sets the declaration a message is about — and with it the
//! locals the texts name a callee from — which is the one generation-time
//! fact the texts read, and they read it here: the solver reads no
//! generation-time context.
//!
//! **The checker's own texts** (§15.3, `checker.md` §8.5, §8.6) — the annotation
//! escape, the infinite type written as its structure and the legs of a
//! failed `?` — are `Messages.zig`'s, which emits through `emit` too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Diagnostics = @import("Diagnostics.zig");
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const EnvFile = @import("Env.zig");
const Context = @import("Context.zig");

const Report = @This();

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;
pub const Item = Diagnostics.Item;
pub const Callee = Diagnostics.Callee;
pub const Rigid = Diagnostics.Reporter.Rigid;
const Category = @import("Category.zig").Category;

gpa: Allocator,
module: Graph.Index,
/// The module's list: `emit` is its only writer.
items: *std.ArrayList(Item),
/// An earlier phase reported on the module, or the graph poisoned it
/// (checker.md §4.3): every message is dropped, once, here.
quiet: bool,
/// One bit per declaration, set iff an ERROR was attributed to it or
/// (at its group's boundary) to a member of its group.
failed: std.DynamicBitSetUnmanaged = .{},
/// The same, less the declarations whose only errors are `infinite_type`:
/// what P7 skips (§15.2). Exhaustiveness
/// reads no solved type, and an infinite type says nothing about a
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
/// The messages `renderLate` redraws (`noMethodsOnShapeLate`).
late: std.ArrayList(Late) = .empty,

pub const Late = struct { index: u32, length: u32, region: Bir.Inst.Index, method: Symbol, v: Var, shape: Diagnostics.Reporter.ShapeKind };

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
    r.env = .{
        .scratch = cx.scratch,
        .store = cx.store,
        .types = cx.types,
        .graph = cx.graph,
        .interner = cx.interner,
        .interfaces = cx.interfaces,
        .module = cx.module,
        .bir = cx.bir,
        .decl_scheme = decl_scheme,
        .local_var = &.{},
        .monomorphic = &r.monomorphic,
    };
    r.texts = .{ .gpa = cx.gpa, .env = &r.env, .items = &r.staged };
}

pub fn deinit(r: *Report) void {
    for (r.staged.items) |item| r.gpa.free(item.message);
    r.staged.deinit(r.gpa);
    r.failed.deinit(r.gpa);
    r.failed_patterns.deinit(r.gpa);
    r.monomorphic.deinit(r.env.scratch);
    r.late.deinit(r.gpa);
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
    // quiet module.
    if (quiet and item.code != .internal) {
        gpa.free(item.message);
        return;
    }
    errdefer gpa.free(item.message);
    try items.append(gpa, item);
}

/// §15.2: the members of a group share variables, so one failure fails
/// them all (the failure bits' one owner is `Report`).
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

/// Append `text` to the message of the module's diagnostic at `index`, one
/// already emitted: a recursive group's hint, written once its class is
/// final (§10.8).
pub fn appendToItem(r: *Report, index: u32, text: []const u8) Error!void {
    const item = &r.items.items[index];
    const joined = try std.mem.concat(r.gpa, u8, &.{ item.message, text });
    r.gpa.free(item.message);
    item.message = joined;
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
    r.env.locals_base = decl_row.locals_start;
    r.env.local_var = r.local_type[decl_row.locals_start..decl_row.locals_end];
}

/// The shared reporter, for the kept passes that take one (`Exhaustive`,
/// `Cycles`). The caller `flush`es after.
pub fn staging(r: *Report) *Diagnostics.Reporter {
    return &r.texts;
}

/// A message with no shared text to reuse, built here.
pub fn emitText(r: *Report, code: diagnostic.Code, region: Bir.Inst.Index, token: ?u32, text: []const u8) Error!void {
    const message = try r.gpa.dupe(u8, text);
    try r.emit(.{ .code = code, .module = r.module, .region = region, .token = token, .message = message });
}

// ---------------------------------------------------------------------------
// The shared texts, staged and flushed
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

pub const EquatableReason = Diagnostics.Reporter.EquatableReason;

/// The `equatable` marker walk's refusal (§11.4), the shared text.
pub fn notEquatable(r: *Report, region: Bir.Inst.Index, v: Var, reason: EquatableReason) Error!void {
    try r.texts.notEquatable(region, v, reason);
    try r.flush();
}

pub fn ambiguousTuple(r: *Report, region: Bir.Inst.Index, index: u32) Error!void {
    try r.texts.ambiguousTuple(region, index);
    try r.flush();
}

pub fn tupleIndexOutOfRange(r: *Report, region: Bir.Inst.Index, index: u32, arity: u32, v: Var) Error!void {
    try r.texts.tupleIndexOutOfRange(region, index, arity, v);
    try r.flush();
}

pub fn notATuple(r: *Report, region: Bir.Inst.Index, index: u32, v: Var) Error!void {
    try r.texts.notATuple(region, index, v);
    try r.flush();
}

pub fn ambiguousInterpolation(r: *Report, region: Bir.Inst.Index) Error!void {
    try r.texts.ambiguousInterpolation(region);
    try r.flush();
}

pub fn notInterpolatable(r: *Report, region: Bir.Inst.Index, v: Var) Error!void {
    try r.texts.notInterpolatable(region, v);
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

// ---- Dispatch (static-dispatch-spike.md §10): shared texts, staged -------

pub fn unknownMethod(r: *Report, origin: Bir.Inst.Index, from_annotation: bool, module: Graph.Index, type_name: Symbol, method: Symbol) Error!void {
    try r.texts.unknownMethod(origin, from_annotation, module, type_name, method);
    try r.flush();
}

pub fn undeterminedMethodReceiver(r: *Report, region: Bir.Inst.Index, method: Symbol, kind: TypeStore.Kind) Error!void {
    try r.texts.undeterminedMethodReceiver(region, method, kind);
    try r.flush();
}

pub fn methodSignatureMismatch(r: *Report, region: Bir.Inst.Index, module: Graph.Index, type_name: Symbol, method: Symbol, found: Var, wanted: Var) Error!void {
    try r.texts.methodSignatureMismatch(region, module, type_name, method, found, wanted, null);
    try r.flush();
}

/// `methodSignatureMismatch` said once, at the method's declaration
/// (`region`, its name `token` underlined): an own well-known method no use
/// of `type_name` can call. `wanted` is the use-independent
/// `T a…, T a… -> Bool|Order`.
pub fn methodSignatureAtDeclaration(r: *Report, region: Bir.Inst.Index, token: u32, module: Graph.Index, type_name: Symbol, method: Symbol, found: Var, wanted: Var) Error!void {
    try r.texts.methodSignatureMismatch(region, module, type_name, method, found, wanted, token);
    try r.flush();
}

pub fn privateMethod(r: *Report, region: Bir.Inst.Index, module: Graph.Index, method: Symbol) Error!void {
    try r.texts.privateMethod(region, module, method);
    try r.flush();
}

pub const ShapeKind = Diagnostics.Reporter.ShapeKind;

pub fn noMethodsOnShape(r: *Report, region: Bir.Inst.Index, method: Symbol, v: Var, shape: ShapeKind) Error!void {
    try r.texts.noMethodsOnShape(region, method, v, shape);
    try r.flush();
}

/// A message about a record a DEFERRED wanted met (a requirement readied
/// when an argument reached its receiver): said now, and its record printed
/// again once P4 is done (`renderLate`), as the declaration left it rather
/// than as it met the receiver — `{ combine : number -> number }`, not
/// `{ combine : a -> b }` (checker.md §8.7). The region, code and failure
/// bits are decided now; only the text is redrawn.
pub fn noMethodsOnShapeLate(r: *Report, region: Bir.Inst.Index, method: Symbol, v: Var, shape: ShapeKind) Error!void {
    const before = r.items.items.len;
    try r.noMethodsOnShape(region, method, v, shape);
    if (r.items.items.len != before + 1) return;
    try r.late.append(r.gpa, .{ .index = @intCast(before), .length = @intCast(r.items.items[before].message.len), .region = region, .method = method, .v = v, .shape = shape });
}

/// Redraw every `noMethodsOnShapeLate` message with the store as P4 left it.
/// A hint appended since (a recursive group's, `appendToItem`) is kept
/// after the text.
pub fn renderLate(r: *Report) Error!void {
    defer r.late.clearRetainingCapacity();
    for (r.late.items) |l| {
        try r.texts.noMethodsOnShape(l.region, l.method, l.v, l.shape);
        if (r.staged.items.len != 1) {
            for (r.staged.items) |item| r.gpa.free(item.message);
            r.staged.clearRetainingCapacity();
            continue;
        }
        const fresh = r.staged.items[0].message;
        r.staged.clearRetainingCapacity();
        defer r.gpa.free(fresh);
        const item = &r.items.items[l.index];
        const joined = try std.mem.concat(r.gpa, u8, &.{ fresh, item.message[l.length..] });
        r.gpa.free(item.message);
        item.message = joined;
    }
}

pub fn missingWhereConstraint(r: *Report, origin: Bir.Inst.Index, from_annotation: bool, var_name: Symbol.Optional, method: Symbol, fn_var: Var, let_binding: Symbol.Optional) Error!void {
    try r.texts.missingWhereConstraint(origin, from_annotation, var_name, method, fn_var, let_binding);
    try r.flush();
}

pub fn methodConstraintMismatch(r: *Report, region: Bir.Inst.Index, other: Bir.Inst.Index, method: Symbol, younger: Var, older: Var) Error!void {
    try r.texts.methodConstraintMismatch(region, other, method, younger, older);
    try r.flush();
}

pub fn typeDispatchNeedsAnnotation(r: *Report, region: Bir.Inst.Index, var_name: Symbol.Optional, method: Symbol, fn_var: Var) Error!void {
    try r.texts.typeDispatchNeedsAnnotation(region, var_name, method, fn_var);
    try r.flush();
}

pub fn tooManyInferredConstraints(r: *Report, region: Bir.Inst.Index, token: u32, decl: Symbol, count: u32, limit: u32, names: []const Symbol, receivers: []const Var) Error!void {
    try r.texts.tooManyInferredConstraints(region, token, decl, count, limit, names, receivers);
    try r.flush();
}

pub fn ambiguousMethodReceiver(r: *Report, region: Bir.Inst.Index, token: u32, decl: Symbol, count: u32, scheme: Var) Error!void {
    try r.texts.ambiguousMethodReceiver(region, token, decl, count, scheme);
    try r.flush();
}

pub fn constrainedConstant(r: *Report, region: Bir.Inst.Index, token: u32, decl: Symbol, var_name: Symbol.Optional, method: Symbol) Error!void {
    try r.texts.constrainedConstant(region, token, decl, var_name, method);
    try r.flush();
}

/// Whether this module already has an error at `region`: an error path's
/// question (a scan), so one use is not refused twice for one receiver
/// (`Instances.noMethodsAs`).
pub fn hasErrorAt(r: *const Report, region: Bir.Inst.Index) bool {
    for (r.items.items) |item| {
        if (item.module == r.module and item.region == region and item.severity == .@"error") return true;
    }
    return false;
}
