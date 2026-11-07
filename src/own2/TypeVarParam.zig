//! L12: whether a parameter's annotated type is a type variable, through
//! aliases (`docs/design/ownership-v2.md` §2.13.9), split from `Groups`.
//!
//! Obligations kept here: none of §2.14's directly (a question of the BIR).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Ids = @import("Ids.zig");

const none: u32 = Ids.none_int;

/// Whether parameter `k` of declaration `d` of module `owner` is declared
/// as a bare type variable (`borrowed a`), aliases expanded (`Id a` with
/// `type alias Id a = a`): its value may hold any structure, and the callee
/// may read any of it, so its words apply at every depth (§2.13.6, #1105).
pub fn paramIsTypeVariable(in: anytype, owner: u32, d: Bir.Decl, k: usize) Allocator.Error!bool {
    const bir = in.birs[owner];
    const ann = d.annotation.unwrap() orelse return false;
    if (bir.instTag(ann) != .type_fn) return false;
    const ps = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(ann).lhs)), Bir.Inst.Index);
    return k < ps.len and try expandsToVariable(in, owner, ps[k]);
}

/// A type written in module `module` whose type variables are bound by
/// `env` (an alias's arguments; null in an annotation, where every variable
/// is free).
const AliasEnv = struct { module: u32, args: []const Bir.Inst.Index, outer: u32 };

/// Whether the type `t` of `module` expands to a free type variable.
/// Alias cycles are refused by the checker (`recursive_alias`), so the
/// expansion ends.
fn expandsToVariable(in: anytype, start_module: u32, start: Bir.Inst.Index) Allocator.Error!bool {
    // A loop, the environments a list (#1143: aliases chain as long as the
    // source has them). `outer` indexes `envs`; `none` is no environment.
    var envs: std.ArrayList(AliasEnv) = .empty;
    defer envs.deinit(in.gpa);
    var module = start_module;
    var t = start;
    var env: u32 = none;
    while (true) {
        const bir = in.birs[module];
        switch (bir.instTag(t)) {
            .type_var => {
                if (env == none) return true;
                const e = envs.items[env];
                const p = Bir.TypeVarInfo.unpack(bir.instData(t).rhs).param;
                if (p >= e.args.len) return false;
                module = e.module;
                t = e.args[p];
                env = e.outer;
            },
            .type_app => {
                const args = bir.extraSlice(bir.subRange(@fromBackingInt(bir.instData(t).rhs)), Bir.Inst.Index);
                const alias = aliasOf(in, module, @fromBackingInt(bir.instData(t).lhs)) orelse return false;
                try envs.append(in.gpa, .{ .module = module, .args = args, .outer = env });
                env = @intCast(envs.items.len - 1);
                module = alias[0];
                t = alias[1];
            },
            .type_top, .ext_type => {
                const alias = aliasOf(in, module, t) orelse return false;
                try envs.append(in.gpa, .{ .module = module, .args = &.{}, .outer = env });
                env = @intCast(envs.items.len - 1);
                module = alias[0];
                t = alias[1];
            },
            else => return false,
        }
    }
}

/// The aliased type of the alias a type reference names, with the module it is written in; null for anything else.
fn aliasOf(in: anytype, module: u32, ref: Bir.Inst.Index) ?struct { u32, Bir.Inst.Index } {
    const bir = in.birs[module];
    const data = bir.instData(ref);
    const at: [2]u32 = switch (bir.instTag(ref)) {
        .type_top => .{ module, data.lhs },
        .ext_type => blk: {
            if (data.lhs >= in.provenance.len) return null;
            const d = in.provenance[data.lhs].typeDecl(data.rhs) orelse return null;
            break :blk .{ data.lhs, d.int() };
        },
        else => return null,
    };
    if (at[0] >= in.birs.len) return null;
    const decls = in.birs[at[0]].decls;
    if (at[1] >= decls.len or decls[at[1]].kind != .type_alias) return null;
    return .{ at[0], decls[at[1]].annotation.unwrap() orelse return null };
}
