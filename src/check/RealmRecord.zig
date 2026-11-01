//! Ordinary checker observer. Raw Vars are anchors only and die before Module.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const TypeStore = @import("TypeStore.zig");
const Source = @import("RealmSource.zig");
const Dispatch = @import("Dispatch.zig");
const Allocator = std.mem.Allocator;
const Record = @This();
const none = std.math.maxInt(u32);
pub const Error = Source.Error;
const Observation = struct { declaration: u32 = none, ambient: u32 = none, type: TypeStore.Var.Optional = .none, literal: Source.Role = .expression };

gpa: Allocator,
bir: *const Bir,
expressions: []Observation,
functions: []TypeStore.Var.Optional,
declarations: []TypeStore.Var.Optional,
call_sites: []Observation,
copy_observations: u64 = 0,
invalid: bool = false,
failure: ?Failure = null,
pub const Failure = struct {
    kind: enum { scope, expression, call },
    scope: u32,
    declaration: u32,
    instruction: u32,
    tag: Bir.Inst.Tag,
    role: Source.Role,
    expected_ambient: u32,
    observed_declaration: u32,
    observed_ambient: u32,
    observed_type: bool,
};

pub fn init(gpa: Allocator, bir: *const Bir) Allocator.Error!Record {
    const expressions = try gpa.alloc(Observation, bir.insts.len);
    errdefer gpa.free(expressions);
    @memset(expressions, .{});
    const functions = try gpa.alloc(TypeStore.Var.Optional, bir.insts.len);
    errdefer gpa.free(functions);
    @memset(functions, .none);
    const declarations = try gpa.alloc(TypeStore.Var.Optional, bir.decls.len);
    errdefer gpa.free(declarations);
    @memset(declarations, .none);
    const call_sites = try gpa.alloc(Observation, bir.insts.len);
    @memset(call_sites, .{});
    return .{ .gpa = gpa, .bir = bir, .expressions = expressions, .functions = functions, .declarations = declarations, .call_sites = call_sites };
}
pub fn deinit(r: *Record) void {
    r.gpa.free(r.expressions);
    r.gpa.free(r.functions);
    r.gpa.free(r.declarations);
    r.gpa.free(r.call_sites);
    r.* = undefined;
}
pub fn declaration(r: *Record, decl: u32, root: TypeStore.Var) void {
    if (decl >= r.declarations.len) {
        r.invalid = true;
        return;
    }
    r.declarations[decl] = root.toOptional();
}
pub fn function(r: *Record, decl: u32, inst: u32, arrow: TypeStore.Var) void {
    if (!r.inDecl(decl, inst)) {
        r.invalid = true;
        return;
    }
    r.functions[inst] = arrow.toOptional();
}
pub fn expression(r: *Record, decl: u32, inst: u32, ambient: u32, expected: TypeStore.Var) void {
    if (!r.inDecl(decl, inst)) {
        r.invalid = true;
        return;
    }
    const previous = r.expressions[inst];
    if (previous.declaration != none and (previous.declaration != decl or previous.ambient != ambient)) {
        r.invalid = true;
        return;
    }
    r.expressions[inst] = .{ .declaration = decl, .ambient = ambient, .type = expected.toOptional() };
}
pub fn specialLiteral(r: *Record, decl: u32, inst: u32, ambient: u32, role: Source.Role) void {
    if (!r.inDecl(decl, inst) or r.expressions[inst].declaration != none) {
        r.invalid = true;
        return;
    }
    r.expressions[inst] = .{ .declaration = decl, .ambient = ambient, .literal = role };
}
pub fn call(r: *Record, decl: u32, inst: u32, ambient: u32) void {
    if (!r.inDecl(decl, inst)) {
        r.invalid = true;
        return;
    }
    const previous = r.call_sites[inst];
    if (previous.declaration != none and (previous.declaration != decl or previous.ambient != ambient)) {
        r.invalid = true;
        return;
    }
    r.call_sites[inst] = .{ .declaration = decl, .ambient = ambient };
}
pub fn activatedCall(r: *Record, inst: u32, ambient: u32) void {
    if (inst >= r.expressions.len or r.expressions[inst].declaration == none) {
        r.invalid = true;
        return;
    }
    r.call(r.expressions[inst].declaration, inst, ambient);
}
/// The original site is retained by expression(); pairs are observed while the
/// ordinary copy memo is live. They do not establish realm/value equality.
pub fn copy(r: *Record, owner: u32, inst: u32, _: TypeStore.Var, copied: []const TypeStore.Var) void {
    if (!r.inDecl(owner, inst)) return; // Synthetic evidence has no source port.
    r.copy_observations += copied.len;
}
fn inDecl(r: *const Record, decl: u32, inst: u32) bool {
    if (decl >= r.bir.decls.len or inst >= r.bir.insts.len) return false;
    const d = r.bir.decls[decl];
    return inst >= d.inst_start.int() and inst < d.inst_end.int();
}
fn functionType(store: *TypeStore, root: TypeStore.Var) bool {
    const resolved, _ = store.resolved(root);
    return switch (store.content(resolved)) {
        .structure => |s| s == .func,
        else => false,
    };
}

/// A clean typed module must have actually constrained every original source
/// expression. The independent lexical scan decides scopes/support; the observer
/// checks those against real pre-unification source anchors before discarding Vars.
pub fn freeze(r: *Record, store: *TypeStore, table: *const Dispatch, intrinsics: Source.IntrinsicContext) Error!Source.Artifact {
    if (r.invalid) return error.InvalidSource;
    var artifact = try Source.scanWithIntrinsics(r.gpa, r.bir, table, intrinsics);
    errdefer artifact.deinit(r.gpa);
    for (0..artifact.scopes.len) |i| {
        const scope = artifact.scopes.get(i);
        if (scope.kind == .foreign) continue;
        const root = if (scope.instruction == none) r.declarations[scope.declaration] else r.functions[scope.instruction];
        const v = root.unwrap() orelse return r.missing(artifact, @intCast(i), scope.body, .expression, .{}, .scope);
        if (scope.kind == .function and !functionType(store, v)) return error.InvalidFunctionAnchor;
    }
    for (0..artifact.nodes.len) |i| {
        const node = artifact.nodes.get(i);
        if (node.scope == .none or node.role == .pattern or node.role == .annotation or !Source.expression(node.tag)) continue;
        const actual = r.expressions[i];
        const scope = artifact.scopes.get(@backingInt(node.scope));
        if (actual.declaration != node.declaration or actual.ambient != scope.instruction or actual.literal != node.role or (node.role == .expression and actual.type == .none)) return r.missing(artifact, @backingInt(node.scope), @intCast(i), node.role, actual, .expression);
        if (Source.isCall(node, artifact.refs) and (r.call_sites[i].declaration != node.declaration or r.call_sites[i].ambient != scope.instruction)) return r.missing(artifact, @backingInt(node.scope), @intCast(i), node.role, r.call_sites[i], .call);
    }
    if (!try artifact.verifyAgainstBirWithIntrinsics(r.gpa, r.bir, table, intrinsics)) return error.InvalidSource;
    return artifact;
}

fn missing(r: *Record, artifact: Source.Artifact, scope_index: u32, instruction: u32, role: Source.Role, actual: Observation, kind: @FieldType(Failure, "kind")) Error {
    const scope = artifact.scopes.get(scope_index);
    r.failure = .{ .kind = kind, .scope = scope_index, .declaration = scope.declaration, .instruction = instruction, .tag = r.bir.instTag(@fromBackingInt(instruction)), .role = role, .expected_ambient = scope.instruction, .observed_declaration = actual.declaration, .observed_ambient = actual.ambient, .observed_type = actual.type != .none };
    return error.MissingObservation;
}
