//! The pass between synthesis and printing:
//!
//! - drops `let` bindings nothing uses, to a fixed point, and turns pattern
//!   bindings nothing uses into `_` (§2.4: every bound variable is used or
//!   is `_`), recording each local's use count for the printers;
//! - marks the members of recursive SCCs (TypeScript writes their return
//!   types in every mode, §6.3);
//! - computes each module's imports from what it references;
//! - counts the comparable size of each module (§5.3).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tree = @import("Tree.zig");
const TypeStore = @import("Type.zig");
const Type = TypeStore.Type;

pub const Size = struct {
    nodes: u64 = 0,
    decls: u64 = 0,
    annotated: u64 = 0,
    leaves: u64 = 0,

    pub fn add(a: *Size, b: Size) void {
        a.nodes += b.nodes;
        a.decls += b.decls;
        a.annotated += b.annotated;
        a.leaves += b.leaves;
    }
};

pub const Result = struct {
    /// Use count of each local.
    uses: []u32,
    /// Per module.
    sizes: []Size,
};

pub fn analyse(t: *Tree) !Result {
    const a = t.arena;
    const uses = try a.alloc(u32, t.locals.items.len);
    // Drop unused `let` bindings until nothing changes: dropping one can
    // leave another unused.
    while (true) {
        @memset(uses, 0);
        for (t.fns.items) |f| countUses(t, f.body, uses);
        var changed = false;
        for (t.fns.items) |f| changed = (try dropUnused(t, f.body, uses)) or changed;
        if (!changed) break;
    }
    // A `let` that lost every binding became its body, which can leave a
    // literal operand of `&&` or `||`: `false && e` hides `e` from
    // TypeScript and is a condition Roc decides (§19 V2, V8). Drop it.
    for (0..t.exprs.len) |i| simplifyBool(t, @intCast(i));
    // Unused pattern bindings print as `_`.
    for (0..t.pats.len) |i| {
        const p = t.pat(@intCast(i));
        if (p.tag == .bind and uses[p.a] == 0) t.pats.set(i, .{ .tag = .wild, .ty = p.ty });
    }
    markRecursive(t);
    try computeImports(t);
    const sizes = try a.alloc(Size, t.modules.items.len);
    @memset(sizes, .{});
    for (t.modules.items, 0..) |m, mi| {
        for (m.types.items) |d| {
            sizes[mi].nodes += 1;
            sizes[mi].decls += 1;
            for (t.types.items[d].ctors.items) |c| {
                sizes[mi].nodes += 1;
                for (t.ctors.items[c].fields) |fty| sizes[mi].nodes += t.store.size(fty);
            }
        }
        for (m.fns.items) |fi| {
            const f = t.fns.items[fi];
            sizes[mi].decls += 1;
            if (f.annotated or f.entry or f.library) sizes[mi].annotated += 1;
            sizes[mi].nodes += 1 + t.store.size(f.ret);
            for (f.params) |p| sizes[mi].nodes += t.store.size(t.locals.items[p].ty);
            countNodes(t, f.body, &sizes[mi]);
        }
    }
    return .{ .uses = uses, .sizes = sizes };
}

/// Visit every expression reachable from `root`, children after parents.
pub fn walk(t: *const Tree, root: u32, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u32) void) void {
    var stack: [4096]u32 = undefined;
    var sp: usize = 1;
    stack[0] = root;
    var buf: [256]u32 = undefined;
    while (sp > 0) {
        sp -= 1;
        const i = stack[sp];
        visit(ctx, i);
        var kids: std.ArrayList(u32) = .initBuffer(&buf);
        childrenInto(t, i, &kids);
        for (kids.items) |k| {
            stack[sp] = k;
            sp += 1;
        }
    }
}

fn childrenInto(t: *const Tree, i: u32, out: *std.ArrayList(u32)) void {
    const e = t.expr(i);
    switch (e.tag) {
        .lit_int, .lit_float, .lit_string, .lit_bool, .local, .global => {},
        .call => {
            out.appendAssumeCapacity(e.a);
            out.appendSliceAssumeCapacity(t.extraList(e.b));
        },
        .lambda => out.appendAssumeCapacity(e.b),
        .let => {
            const xs = t.extraPairs(e.a);
            var k: usize = 1;
            while (k < xs.len) : (k += 2) out.appendAssumeCapacity(xs[k]);
            out.appendAssumeCapacity(e.b);
        },
        .@"if" => {
            out.appendAssumeCapacity(e.a);
            out.appendSliceAssumeCapacity(t.extra.items[e.b..][0..2]);
        },
        .case => {
            out.appendAssumeCapacity(e.a);
            const xs = t.extraPairs(e.b);
            var k: usize = 1;
            while (k < xs.len) : (k += 2) out.appendAssumeCapacity(xs[k]);
        },
        .ctor => out.appendSliceAssumeCapacity(t.extraList(e.b)),
        .list => out.appendSliceAssumeCapacity(t.extraList(e.a)),
        .pair, .binop, .list_map, .list_filter => out.appendSliceAssumeCapacity(&.{ e.a, e.b }),
        .not, .int_to_string => out.appendAssumeCapacity(e.a),
        .list_foldl => out.appendSliceAssumeCapacity(&.{ e.a, t.extra.items[e.b], t.extra.items[e.b + 1] }),
        .pipe => {
            out.appendAssumeCapacity(e.a);
            out.appendSliceAssumeCapacity(t.extraList(e.b));
        },
    }
}

const UseCtx = struct { t: *const Tree, uses: []u32 };

fn countUses(t: *const Tree, root: u32, uses: []u32) void {
    walk(t, root, UseCtx{ .t = t, .uses = uses }, struct {
        fn f(c: UseCtx, i: u32) void {
            const e = c.t.expr(i);
            if (e.tag == .local) c.uses[e.a] += 1;
        }
    }.f);
}

/// Remove unused bindings from every `let` under `root`; a `let` left with
/// none becomes its body. Returns whether anything changed.
fn dropUnused(t: *Tree, root: u32, uses: []const u32) !bool {
    const Ctx = struct { t: *Tree, uses: []const u32, changed: *bool };
    var changed = false;
    walk(t, root, Ctx{ .t = t, .uses = uses, .changed = &changed }, struct {
        fn f(c: Ctx, i: u32) void {
            const e = c.t.expr(i);
            if (e.tag != .let) return;
            const at = e.a;
            const n = c.t.extra.items[at];
            var kept: u32 = 0;
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const l = c.t.extra.items[at + 1 + 2 * k];
                const v = c.t.extra.items[at + 2 + 2 * k];
                if (c.uses[l] == 0) continue;
                c.t.extra.items[at + 1 + 2 * kept] = l;
                c.t.extra.items[at + 2 + 2 * kept] = v;
                kept += 1;
            }
            if (kept == n) return;
            c.changed.* = true;
            c.t.extra.items[at] = kept;
            if (kept == 0) {
                // The let becomes its body, in place, keeping the node id.
                c.t.exprs.set(i, c.t.expr(e.b));
            }
        }
    }.f);
    return changed;
}

fn simplifyBool(t: *Tree, i: u32) void {
    while (true) {
        const e = t.expr(i);
        if (e.tag != .binop or (e.op != .bool_and and e.op != .bool_or)) return;
        if (t.expr(e.a).tag == .lit_bool) {
            t.exprs.set(i, t.expr(e.b));
        } else if (t.expr(e.b).tag == .lit_bool) {
            t.exprs.set(i, t.expr(e.a));
        } else return;
    }
}

fn countNodes(t: *const Tree, root: u32, size: *Size) void {
    const Ctx = struct { t: *const Tree, size: *Size };
    walk(t, root, Ctx{ .t = t, .size = size }, struct {
        fn f(c: Ctx, i: u32) void {
            c.size.nodes += 1;
            const e = c.t.expr(i);
            if (e.tag == .case) {
                const xs = c.t.extraPairs(e.b);
                var k: usize = 0;
                while (k < xs.len) : (k += 2) {
                    c.size.leaves += 1;
                    c.size.nodes += patNodes(c.t, xs[k]);
                }
            }
            if (e.tag == .lambda or e.tag == .let) {
                const xs = if (e.tag == .lambda) c.t.extraList(e.a) else c.t.extraPairs(e.a);
                c.size.nodes += if (e.tag == .lambda) xs.len else xs.len / 2;
            }
        }
    }.f);
}

pub fn patNodes(t: *const Tree, p: u32) u64 {
    const pt = t.pat(p);
    return switch (pt.tag) {
        .ctor => blk: {
            var n: u64 = 1;
            for (t.extraList(pt.b)) |c| n += patNodes(t, c);
            break :blk n;
        },
        .pair => 1 + patNodes(t, pt.a) + patNodes(t, pt.b),
        else => 1,
    };
}

/// The functions each function calls or references, within its module.
fn edges(t: *const Tree, f: u32, out: *std.ArrayList(u32), a: Allocator) !void {
    const Ctx = struct { t: *const Tree, out: *std.ArrayList(u32), a: Allocator, m: u32 };
    const m = t.fns.items[f].module;
    walk(t, t.fns.items[f].body, Ctx{ .t = t, .out = out, .a = a, .m = m }, struct {
        fn v(c: Ctx, i: u32) void {
            const e = c.t.expr(i);
            if (e.tag == .global and c.t.fns.items[e.a].module == c.m) c.out.append(c.a, e.a) catch @panic("oom");
        }
    }.v);
}

/// Tarjan's SCC over each module's call graph; members of an SCC of size
/// > 1, or with a self edge, are recursive.
fn markRecursive(t: *Tree) void {
    const a = t.arena;
    const n = t.fns.items.len;
    const index = a.alloc(i64, n) catch @panic("oom");
    const low = a.alloc(i64, n) catch @panic("oom");
    const on = a.alloc(bool, n) catch @panic("oom");
    @memset(index, -1);
    @memset(on, false);
    var stack: std.ArrayList(u32) = .empty;
    var counter: i64 = 0;
    const adj = a.alloc([]const u32, n) catch @panic("oom");
    for (0..n) |f| {
        var out: std.ArrayList(u32) = .empty;
        edges(t, @intCast(f), &out, a) catch @panic("oom");
        adj[f] = out.items;
    }
    const S = struct {
        fn strong(tt: *Tree, v: u32, ix: []i64, lo: []i64, onst: []bool, st: *std.ArrayList(u32), ctr: *i64, ad: []const []const u32) void {
            ix[v] = ctr.*;
            lo[v] = ctr.*;
            ctr.* += 1;
            st.append(tt.arena, v) catch @panic("oom");
            onst[v] = true;
            for (ad[v]) |w| {
                if (ix[w] == -1) {
                    strong(tt, w, ix, lo, onst, st, ctr, ad);
                    lo[v] = @min(lo[v], lo[w]);
                } else if (onst[w]) lo[v] = @min(lo[v], ix[w]);
            }
            if (lo[v] == ix[v]) {
                var members: std.ArrayList(u32) = .empty;
                while (true) {
                    const w = st.pop().?;
                    onst[w] = false;
                    members.append(tt.arena, w) catch @panic("oom");
                    if (w == v) break;
                }
                const self_edge = std.mem.indexOfScalar(u32, ad[v], v) != null;
                if (members.items.len > 1 or self_edge) {
                    for (members.items) |m| tt.fns.items[m].recursive = true;
                }
            }
        }
    };
    for (0..n) |v| if (index[v] == -1) S.strong(t, @intCast(v), index, low, on, &stack, &counter, adj);
}

fn noteType(t: *const Tree, ty: Type, refs: []bool) void {
    const s = &t.store;
    switch (s.tag(ty)) {
        .int, .float, .string, .bool, .@"var" => {},
        .pair => {
            noteType(t, s.pairParts(ty)[0], refs);
            noteType(t, s.pairParts(ty)[1], refs);
        },
        .list => noteType(t, s.listElem(ty), refs),
        .func => {
            for (s.funcParams(ty)) |p| noteType(t, p, refs);
            noteType(t, s.funcRet(ty), refs);
        },
        .named => {
            refs[t.types.items[s.namedDecl(ty)].module] = true;
            for (s.namedArgs(ty)) |p| noteType(t, p, refs);
        },
    }
}

fn notePat(t: *const Tree, p: u32, refs: []bool) void {
    const pt = t.pat(p);
    switch (pt.tag) {
        .ctor => {
            refs[t.types.items[t.ctors.items[pt.a].decl].module] = true;
            for (t.extraList(pt.b)) |c| notePat(t, c, refs);
        },
        .pair => {
            notePat(t, pt.a, refs);
            notePat(t, pt.b, refs);
        },
        else => {},
    }
}

/// A module's imports are every module it references: a function, a
/// constructor (in an expression or a pattern), or a type in a signature
/// or a constructor field. Printers narrow this per language and mode.
fn computeImports(t: *Tree) !void {
    const nm = t.modules.items.len;
    for (t.modules.items, 0..) |*m, mi| {
        const refs = try t.arena.alloc(bool, nm);
        @memset(refs, false);
        for (m.types.items) |d| for (t.types.items[d].ctors.items) |c| for (t.ctors.items[c].fields) |fty| noteType(t, fty, refs);
        for (m.fns.items) |fi| {
            const f = t.fns.items[fi];
            noteType(t, f.ret, refs);
            for (f.params) |p| noteType(t, t.locals.items[p].ty, refs);
            const Ctx = struct { t: *const Tree, refs: []bool };
            walk(t, f.body, Ctx{ .t = t, .refs = refs }, struct {
                fn v(c: Ctx, i: u32) void {
                    const e = c.t.expr(i);
                    switch (e.tag) {
                        .global => c.refs[c.t.fns.items[e.a].module] = true,
                        .ctor => c.refs[c.t.types.items[c.t.ctors.items[e.a].decl].module] = true,
                        .case => {
                            const xs = c.t.extraPairs(e.b);
                            var k: usize = 0;
                            while (k < xs.len) : (k += 2) notePat(c.t, xs[k], c.refs);
                        },
                        else => {},
                    }
                    noteType(c.t, e.ty, c.refs);
                }
            }.v);
        }
        m.imports.clearRetainingCapacity();
        for (refs, 0..) |r, j| if (r and j != mi) try m.imports.append(t.arena, @intCast(j));
    }
}
