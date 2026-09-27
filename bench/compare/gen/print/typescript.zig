//! The TypeScript printer (docs/design/compare-bench.md §2.6, §6.3).
//!
//! Function bodies are statements. A `case`, `let` or `if` in tail
//! position prints as statements (a `switch` tree, `const`s, `if`/`else`);
//! elsewhere a `case` or `let` prints as an immediately invoked arrow and an
//! `if` as a conditional expression. A `case` is compiled from the tree's
//! patterns back into the split tree they came from (§3.6): a `switch` on
//! the tag of each occurrence it splits, `if`/`else` on a `Bool`, a literal
//! `switch` with a `default` for the variable leaf, and `default: return
//! Base.absurd(x)` after every constructor switch, which is TypeScript's
//! exhaustiveness check.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Tree = @import("../Tree.zig");
const TypeStore = @import("../Type.zig");
const Type = TypeStore.Type;
const common = @import("common.zig");
const analyse = @import("../analyse.zig");
const E = error{ OutOfMemory, WriteFailed };

pub const P = struct {
    t: *const Tree,
    uses: []const u32,
    module: u32,
    w: *Writer,
    a: Allocator,
    refs: []bool,
    annotations: u64 = 0,
    explicit_type_args: u64 = 0,
    invoked_arrows: u64 = 0,
    /// Counter for the occurrence constants `m<n>` and wildcards `_<n>`.
    fresh: u32 = 0,
    wild: u32 = 0,
    /// Whether a `return` here has a contextual type: the function or
    /// lambda it returns from declares or receives its result type.
    ret_ctx: bool = true,
    unread: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// The switch subjects narrowed where the printer is: a generic call
    /// passed one writes its type arguments, or TypeScript would infer the
    /// narrowed variant (§19 V8).
    narrowed: std.ArrayList([]const u8) = .empty,

    fn out(p: *P, s: []const u8) !void {
        try p.w.writeAll(s);
    }

    fn print(p: *P, comptime fmt: []const u8, args: anytype) !void {
        try p.w.print(fmt, args);
    }

    fn nl(p: *P, ind: usize) !void {
        try p.w.writeByte('\n');
        try p.w.splatByteAll(' ', ind);
    }

    fn store(p: *P) *const TypeStore {
        return &p.t.store;
    }

    fn qual(p: *P, m: u32) !void {
        p.refs[m] = true;
        try p.print("{s}.", .{p.t.modules.items[m].name});
    }

    fn fnRef(p: *P, f: u32) !void {
        const fd = p.t.fns.items[f];
        if (fd.module != p.module) try p.qual(fd.module);
        try p.out(fd.name);
    }

    fn typeRef(p: *P, d: u32) !void {
        const td = p.t.types.items[d];
        if (td.module != p.module) try p.qual(td.module);
        try p.out(td.name);
    }

    fn baseRef(p: *P, name: []const u8) !void {
        // Base's TypeScript-only helpers (`absurd`, `pair`).
        const base: u32 = 0;
        if (p.module != base) try p.qual(base);
        try p.out(name);
    }

    fn local(p: *P, l: u32) !void {
        try p.print("v{d}", .{p.t.locals.items[l].name});
    }

    /// How often TypeScript's text reads `l`: the tree's count, less the
    /// pair scrutinees whose column no row tests or binds (a `case (x, y)`
    /// that ignores `x` never mentions it in a `switch` tree).
    fn tsUses(p: *P, l: u32) u32 {
        return p.uses[l] - (p.unread.get(l) orelse 0);
    }

    fn noteUnread(p: *P, body: u32) !void {
        const Ctx = struct { p: *P };
        analyse.walk(p.t, body, Ctx{ .p = p }, struct {
            fn visit(c: Ctx, i: u32) void {
                const t = c.p.t;
                const x = t.expr(i);
                if (x.tag != .case) return;
                const sc = t.expr(x.a);
                const xs = t.extraPairs(x.b);
                if (sc.tag == .local) {
                    // A single-constructor type is destructured, not switched
                    // on: when no row reads a field, the subject is unread.
                    var r: usize = 0;
                    while (r < xs.len) : (r += 2) if (c.p.patReads(xs[r])) return;
                    const gop = c.p.unread.getOrPut(c.p.a, sc.a) catch @panic("oom");
                    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
                    return;
                }
                for ([_]u32{ sc.a, sc.b }, 0..) |comp, k| {
                    var read = false;
                    var r: usize = 0;
                    while (r < xs.len) : (r += 2) {
                        const pt = t.pat(xs[r]);
                        if (pt.tag != .pair) {
                            read = true;
                            break;
                        }
                        if (c.p.patReads(if (k == 0) pt.a else pt.b)) read = true;
                    }
                    if (!read) {
                        const gop = c.p.unread.getOrPut(c.p.a, t.expr(comp).a) catch @panic("oom");
                        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
                    }
                }
            }
        }.visit);
    }

    /// Whether the printed match of `i` mentions its subject: it binds,
    /// tests a literal or `Bool`, or tells constructors apart.
    fn patReads(p: *P, i: u32) bool {
        const t = p.t;
        const pt = t.pat(i);
        return switch (pt.tag) {
            .wild => false,
            .bind, .lit_int, .lit_string, .lit_bool => true,
            .pair => p.patReads(pt.a) or p.patReads(pt.b),
            .ctor => blk: {
                if (t.types.items[t.ctors.items[pt.a].decl].ctors.items.len > 1) break :blk true;
                for (t.extraList(pt.b)) |s| if (p.patReads(s)) break :blk true;
                break :blk false;
            },
        };
    }

    fn binder(p: *P, l: u32) !void {
        if (p.tsUses(l) == 0) {
            p.wild += 1;
            return p.print("_{d}", .{p.wild});
        }
        try p.local(l);
    }

    // ---- types ----

    pub fn ty(p: *P, t: Type) E!void {
        const s = p.store();
        switch (s.tag(t)) {
            .int, .float => try p.out("number"),
            .string => try p.out("string"),
            .bool => try p.out("boolean"),
            .@"var" => try p.print("{c}", .{"abcdefgh"[s.varIndex(t)]}),
            .pair => {
                const parts = s.pairParts(t);
                try p.out("readonly [");
                try p.ty(parts[0]);
                try p.out(", ");
                try p.ty(parts[1]);
                try p.out("]");
            },
            .list => {
                try p.out("ReadonlyArray<");
                try p.ty(s.listElem(t));
                try p.out(">");
            },
            .func => {
                var ps: [16]Type = undefined;
                const n = s.funcParams(t).len;
                @memcpy(ps[0..n], s.funcParams(t));
                const ret = s.funcRet(t);
                try p.out("((");
                for (ps[0..n], 0..) |x, i| {
                    if (i > 0) try p.out(", ");
                    try p.print("p{d}: ", .{i});
                    try p.ty(x);
                }
                try p.out(") => ");
                try p.ty(ret);
                try p.out(")");
            },
            .named => {
                var args: [8]Type = undefined;
                const n = s.namedArgs(t).len;
                @memcpy(args[0..n], s.namedArgs(t));
                try p.typeRef(s.namedDecl(t));
                if (n > 0) {
                    try p.out("<");
                    for (args[0..n], 0..) |x, i| {
                        if (i > 0) try p.out(", ");
                        try p.ty(x);
                    }
                    try p.out(">");
                }
            },
        }
    }

    fn typeParams(p: *P, n: u32) !void {
        if (n == 0) return;
        try p.out("<");
        for (0..n) |i| {
            if (i > 0) try p.out(", ");
            try p.print("{c}", .{"abcdefgh"[i]});
        }
        try p.out(">");
    }

    fn typeArgs(p: *P, args: []const Type) !void {
        p.explicit_type_args += 1;
        try p.out("<");
        for (args, 0..) |x, i| {
            if (i > 0) try p.out(", ");
            try p.ty(x);
        }
        try p.out(">");
    }

    // ---- declarations ----

    pub fn typeDecl(p: *P, d: u32) !void {
        const t = p.t;
        const td = t.types.items[d];
        try p.print("export type {s}", .{td.name});
        try p.typeParams(td.nparams);
        try p.out(" =");
        for (td.ctors.items) |c| {
            const cd = t.ctors.items[c];
            try p.nl(2);
            try p.print("| {{ readonly tag: \"{s}\"", .{cd.name});
            for (cd.fields, 0..) |f, i| {
                try p.print("; readonly f{d}: ", .{i});
                try p.ty(f);
            }
            try p.out(" }");
        }
        try p.out(";\n\n");
        // One generic constructor function per constructor (§2.6).
        for (td.ctors.items) |c| {
            const cd = t.ctors.items[c];
            try p.print("export function {s}", .{cd.name});
            try p.typeParams(td.nparams);
            try p.out("(");
            for (cd.fields, 0..) |f, i| {
                if (i > 0) try p.out(", ");
                try p.print("f{d}: ", .{i});
                try p.ty(f);
            }
            try p.out("): ");
            try p.typeRef(d);
            try p.typeParams(td.nparams);
            try p.print(" {{\n  return {{ tag: \"{s}\"", .{cd.name});
            for (0..cd.fields.len) |i| try p.print(", f{d}", .{i});
            try p.out(" };\n}\n\n");
        }
    }

    pub fn fnDecl(p: *P, fi: u32) !void {
        const t = p.t;
        const f = t.fns.items[fi];
        p.fresh = 0;
        p.wild = 0;
        try p.noteUnread(f.body);
        try p.print("export function {s}", .{f.name});
        try p.typeParams(f.nvars);
        try p.out("(");
        for (f.params, 0..) |l, i| {
            if (i > 0) try p.out(", ");
            try p.binder(l);
            try p.out(": ");
            try p.ty(t.locals.items[l].ty);
            p.annotations += 1;
        }
        try p.out(")");
        // §6.3: the return type is written when annotated, and always for a
        // member of a recursive SCC (TS7023).
        if (f.annotated or f.entry or f.library or f.recursive) {
            try p.out(": ");
            try p.ty(f.ret);
            p.annotations += 1;
        }
        p.ret_ctx = f.annotated or f.entry or f.library or f.recursive;
        try p.out(" {");
        try p.tail(f.body, 2);
        try p.out("\n}\n\n");
    }

    // ---- statements ----

    /// Statements that return `e`'s value, each on its own line at `ind`.
    fn tail(p: *P, e: u32, ind: usize) E!void {
        const t = p.t;
        const x = t.expr(e);
        switch (x.tag) {
            .let => {
                const xs = t.extraPairs(x.a);
                var k: usize = 0;
                while (k < xs.len) : (k += 2) {
                    try p.nl(ind);
                    try p.binding(xs[k], xs[k + 1], ind);
                }
                try p.tail(x.b, ind);
            },
            .@"if" => {
                try p.nl(ind);
                try p.out("if (");
                try p.expr(x.a, ind);
                try p.out(") {");
                const nmark = p.narrowed.items.len;
                defer p.narrowed.shrinkRetainingCapacity(nmark);
                try p.condNarrows(x.a);
                try p.tail(t.extra.items[x.b], ind + 2);
                try p.nl(ind);
                try p.out("} else {");
                try p.tail(t.extra.items[x.b + 1], ind + 2);
                try p.nl(ind);
                try p.out("}");
            },
            .case => try p.caseStmts(e, ind),
            else => {
                try p.nl(ind);
                try p.out("return ");
                try p.exprCtx(e, ind, p.ret_ctx);
                try p.out(";");
            },
        }
    }

    /// `const v = e;` A binding of a base type is a `let`, whose type
    /// TypeScript widens: a `const` of a literal would have the literal's
    /// type, and comparing two literal types is an error. A lambda bound
    /// here has no contextual type, so its parameters are written (§6.3).
    fn binding(p: *P, l: u32, v: u32, ind: usize) !void {
        const lty = p.t.locals.items[l].ty;
        const base = lty == .int or lty == .float or lty == .string or lty == .bool;
        try p.out(if (base) "let " else "const ");
        try p.local(l);
        // A value read from a narrowed local has the narrowed type (a
        // literal, a variant), and so would the binding: write the type.
        if (p.readsNarrowed(v)) {
            try p.out(": ");
            try p.ty(lty);
            p.annotations += 1;
        }
        try p.out(" = ");
        try p.exprCtx(v, ind, false);
        try p.out(";");
    }

    // ---- case: patterns back into the split tree ----

    const wild_pat: u32 = std.math.maxInt(u32);

    const Row = struct {
        pats: []u32,
        body: u32,
        /// (local, occurrence text) pairs bound on the way down.
        binds: []const Bind,
    };
    /// `annotate`: the occurrence is narrowed here (a `switch` subject in
    /// one of its cases, a `Bool` in its branch), so the binding writes the
    /// declared type; it would otherwise take the narrowed literal or variant
    /// type, which later comparisons and inference trip on (§19 V8).
    const Bind = struct { local: u32, occ: []const u8, annotate: bool = false };
    const Occ = struct { text: []const u8, ty: Type };

    fn caseStmts(p: *P, e: u32, ind: usize) !void {
        const t = p.t;
        const x = t.expr(e);
        const sc = t.expr(x.a);
        const xs = t.extraPairs(x.b);
        var rows: std.ArrayList(Row) = .empty;
        var occs: std.ArrayList(Occ) = .empty;
        var k: usize = 0;
        if (sc.tag == .pair) {
            // `case (x, y)`: the two locals are the occurrences.
            try occs.append(p.a, .{ .text = try p.localText(t.expr(sc.a).a), .ty = t.expr(sc.a).ty });
            try occs.append(p.a, .{ .text = try p.localText(t.expr(sc.b).a), .ty = t.expr(sc.b).ty });
            while (k < xs.len) : (k += 2) {
                const pt = t.pat(xs[k]);
                const pats = try p.a.alloc(u32, 2);
                var binds: std.ArrayList(Bind) = .empty;
                if (pt.tag == .pair) {
                    pats[0] = pt.a;
                    pats[1] = pt.b;
                } else {
                    pats[0] = wild_pat;
                    pats[1] = wild_pat;
                    if (pt.tag == .bind) try binds.append(p.a, .{ .local = pt.a, .occ = try p.pairOcc(occs.items[0].text, occs.items[1].text) });
                }
                try rows.append(p.a, .{ .pats = pats, .body = xs[k + 1], .binds = binds.items });
            }
        } else {
            try occs.append(p.a, .{ .text = try p.exprText(x.a), .ty = sc.ty });
            while (k < xs.len) : (k += 2) {
                const pats = try p.a.alloc(u32, 1);
                pats[0] = xs[k];
                try rows.append(p.a, .{ .pats = pats, .body = xs[k + 1], .binds = &.{} });
            }
        }
        try p.compile(rows.items, occs.items, ind);
    }

    fn pairOcc(p: *P, a: []const u8, b: []const u8) ![]const u8 {
        return std.fmt.allocPrint(p.a, "{s}pair({s}, {s})", .{ if (p.module != 0) "Base." else "", a, b });
    }

    fn localText(p: *P, l: u32) ![]const u8 {
        return std.fmt.allocPrint(p.a, "v{d}", .{p.t.locals.items[l].name});
    }

    fn exprText(p: *P, e: u32) ![]const u8 {
        var buf: Writer.Allocating = .init(p.a);
        const saved = p.w;
        p.w = &buf.writer;
        defer p.w = saved;
        try p.expr(e, 0);
        return buf.written();
    }

    fn isWild(p: *P, i: u32) bool {
        if (i == wild_pat) return true;
        const tag = p.t.pat(i).tag;
        return tag == .wild or tag == .bind;
    }

    fn withBindAnn(p: *P, row: Row, pat: u32, occ: []const u8) ![]const Bind {
        const bs = try p.withBind(row, pat, occ);
        if (bs.len > row.binds.len) {
            const m = @constCast(bs);
            m[bs.len - 1].annotate = true;
        }
        return bs;
    }

    fn withBind(p: *P, row: Row, pat: u32, occ: []const u8) ![]const Bind {
        if (pat == wild_pat or p.t.pat(pat).tag != .bind) return row.binds;
        const res = try p.a.alloc(Bind, row.binds.len + 1);
        @memcpy(res[0..row.binds.len], row.binds);
        res[row.binds.len] = .{ .local = p.t.pat(pat).a, .occ = occ };
        return res;
    }

    fn compile(p: *P, rows: []const Row, occs: []const Occ, ind: usize) E!void {
        const t = p.t;
        const s = p.store();
        std.debug.assert(rows.len > 0);
        const r0 = rows[0];
        var col: ?usize = null;
        for (r0.pats, 0..) |pt, j| if (!p.isWild(pt)) {
            col = j;
            break;
        };
        if (col == null) {
            // The first row matches: bind and return.
            for (r0.binds) |b| try p.bindConst(b, ind);
            for (r0.pats, 0..) |pt, j| {
                if (pt != wild_pat and t.pat(pt).tag == .bind) try p.bindConst(.{ .local = t.pat(pt).a, .occ = occs[j].text }, ind);
            }
            return p.tail(r0.body, ind);
        }
        const j = col.?;
        const occ = occs[j];
        const oty = occ.ty;
        switch (s.tag(oty)) {
            .pair => {
                // Destructure: the two components become occurrences.
                const parts = s.pairParts(oty);
                const a_txt = try std.fmt.allocPrint(p.a, "{s}[0]", .{occ.text});
                const b_txt = try std.fmt.allocPrint(p.a, "{s}[1]", .{occ.text});
                const nocc = try p.expandOccs(occs, j, &.{ .{ .text = a_txt, .ty = parts[0] }, .{ .text = b_txt, .ty = parts[1] } });
                var nrows: std.ArrayList(Row) = .empty;
                for (rows) |r| {
                    const pt = r.pats[j];
                    const subs: [2]u32 = if (p.isWild(pt)) .{ wild_pat, wild_pat } else .{ t.pat(pt).a, t.pat(pt).b };
                    try nrows.append(p.a, .{ .pats = try p.expandPats(r.pats, j, &subs), .body = r.body, .binds = try p.withBind(r, pt, occ.text) });
                }
                return p.compile(nrows.items, nocc, ind);
            },
            .bool => {
                const nmark = p.narrowed.items.len;
                defer p.narrowed.shrinkRetainingCapacity(nmark);
                try p.narrowed.append(p.a, occ.text);
                try p.nl(ind);
                try p.print("if ({s}) {{", .{occ.text});
                try p.boolBranch(rows, occs, j, 1, ind + 2);
                try p.nl(ind);
                try p.out("} else {");
                try p.boolBranch(rows, occs, j, 0, ind + 2);
                try p.nl(ind);
                try p.out("}");
            },
            .int, .string => {
                const subj = try p.subject(occ.text, ind);
                try p.nl(ind);
                const nmark = p.narrowed.items.len;
                defer p.narrowed.shrinkRetainingCapacity(nmark);
                try p.narrowed.append(p.a, subj);
                try p.print("switch ({s}) {{", .{subj});
                var seen: std.ArrayList(u32) = .empty;
                for (rows) |r| {
                    const pt = r.pats[j];
                    if (p.isWild(pt)) continue;
                    const v = t.pat(pt).a;
                    if (std.mem.indexOfScalar(u32, seen.items, v) != null) continue;
                    try seen.append(p.a, v);
                    var sub: std.ArrayList(Row) = .empty;
                    for (rows) |r2| {
                        const q = r2.pats[j];
                        if (p.isWild(q) or t.pat(q).a == v) try sub.append(p.a, .{ .pats = try p.expandPats(r2.pats, j, &.{}), .body = r2.body, .binds = try p.withBindAnn(r2, q, subj) });
                    }
                    try p.nl(ind + 2);
                    if (oty == .int) try p.print("case {d}: {{", .{v}) else try p.print("case \"s{d}\": {{", .{v});
                    try p.compile(sub.items, try p.expandOccs(occs, j, &.{}), ind + 4);
                    try p.nl(ind + 2);
                    try p.out("}");
                }
                var def: std.ArrayList(Row) = .empty;
                for (rows) |r| if (p.isWild(r.pats[j])) try def.append(p.a, .{ .pats = try p.expandPats(r.pats, j, &.{}), .body = r.body, .binds = try p.withBind(r, r.pats[j], subj) });
                try p.nl(ind + 2);
                try p.out("default: {");
                try p.compile(def.items, try p.expandOccs(occs, j, &.{}), ind + 4);
                try p.nl(ind + 2);
                try p.out("}");
                try p.nl(ind);
                try p.out("}");
            },
            .named => {
                const d = t.types.items[s.namedDecl(oty)];
                if (d.ctors.items.len == 1) {
                    const subj = occ.text;
                    // One constructor: TypeScript does not narrow a type that
                    // is not a union, so there is nothing to switch on and
                    // `absurd` would not type. Destructure directly.
                    const c = d.ctors.items[0];
                    const sub = try p.specialise(rows, j, c, subj);
                    var ftys: [16]Type = undefined;
                    const fs = try @constCast(t).ctorFields(c, oty, &ftys);
                    var focc: [16]Occ = undefined;
                    for (fs, 0..) |f, i| focc[i] = .{ .text = try std.fmt.allocPrint(p.a, "{s}.f{d}", .{ subj, i }), .ty = f };
                    return p.compile(sub, try p.expandOccs(occs, j, focc[0..fs.len]), ind);
                }
                const subj = try p.subject(occ.text, ind);
                try p.narrowed.append(p.a, subj);
                defer _ = p.narrowed.pop();
                try p.nl(ind);
                try p.print("switch ({s}.tag) {{", .{subj});
                for (d.ctors.items) |c| {
                    var sub: std.ArrayList(Row) = .empty;
                    const arity = t.ctors.items[c].fields.len;
                    for (rows) |r| {
                        const q = r.pats[j];
                        if (p.isWild(q)) {
                            const ws = try p.a.alloc(u32, arity);
                            @memset(ws, wild_pat);
                            try sub.append(p.a, .{ .pats = try p.expandPats(r.pats, j, ws), .body = r.body, .binds = try p.withBindAnn(r, q, subj) });
                        } else if (t.pat(q).a == c) {
                            try sub.append(p.a, .{ .pats = try p.expandPats(r.pats, j, t.extraList(t.pat(q).b)), .body = r.body, .binds = r.binds });
                        }
                    }
                    if (sub.items.len == 0) continue;
                    var ftys: [16]Type = undefined;
                    const fs = try @constCast(t).ctorFields(c, oty, &ftys);
                    var focc: [16]Occ = undefined;
                    for (fs, 0..) |f, i| focc[i] = .{ .text = try std.fmt.allocPrint(p.a, "{s}.f{d}", .{ subj, i }), .ty = f };
                    try p.nl(ind + 2);
                    try p.print("case \"{s}\": {{", .{t.ctors.items[c].name});
                    try p.compile(sub.items, try p.expandOccs(occs, j, focc[0..fs.len]), ind + 4);
                    try p.nl(ind + 2);
                    try p.out("}");
                }
                try p.nl(ind + 2);
                try p.out("default:");
                try p.nl(ind + 4);
                try p.out("return ");
                try p.baseRef("absurd");
                try p.print("({s});", .{subj});
                try p.nl(ind);
                try p.out("}");
            },
            else => unreachable,
        }
    }

    /// An identifier to switch on: the occurrence itself when it already
    /// is one, else a fresh `const m<n>`, so narrowing applies to a name.
    fn subject(p: *P, occ: []const u8, ind: usize) ![]const u8 {
        for (occ) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) {
            p.fresh += 1;
            try p.nl(ind);
            try p.print("const m{d} = {s};", .{ p.fresh, occ });
            return std.fmt.allocPrint(p.a, "m{d}", .{p.fresh});
        };
        return occ;
    }

    /// The rows that match constructor `c` at column `j`, its fields
    /// expanded in place.
    fn specialise(p: *P, rows: []const Row, j: usize, c: u32, subj: []const u8) ![]const Row {
        const t = p.t;
        var sub: std.ArrayList(Row) = .empty;
        const arity = t.ctors.items[c].fields.len;
        for (rows) |r| {
            const q = r.pats[j];
            if (p.isWild(q)) {
                const ws = try p.a.alloc(u32, arity);
                @memset(ws, wild_pat);
                try sub.append(p.a, .{ .pats = try p.expandPats(r.pats, j, ws), .body = r.body, .binds = try p.withBindAnn(r, q, subj) });
            } else if (t.pat(q).a == c) {
                try sub.append(p.a, .{ .pats = try p.expandPats(r.pats, j, t.extraList(t.pat(q).b)), .body = r.body, .binds = r.binds });
            }
        }
        return sub.items;
    }

    fn boolBranch(p: *P, rows: []const Row, occs: []const Occ, j: usize, v: u32, ind: usize) !void {
        const t = p.t;
        var sub: std.ArrayList(Row) = .empty;
        for (rows) |r| {
            const q = r.pats[j];
            if (p.isWild(q) or t.pat(q).a == v) try sub.append(p.a, .{ .pats = try p.expandPats(r.pats, j, &.{}), .body = r.body, .binds = try p.withBindAnn(r, q, occs[j].text) });
        }
        try p.compile(sub.items, try p.expandOccs(occs, j, &.{}), ind);
    }

    fn expandPats(p: *P, pats: []const u32, j: usize, with: []const u32) ![]u32 {
        const res = try p.a.alloc(u32, pats.len - 1 + with.len);
        @memcpy(res[0..j], pats[0..j]);
        @memcpy(res[j..][0..with.len], with);
        @memcpy(res[j + with.len ..], pats[j + 1 ..]);
        return res;
    }

    fn expandOccs(p: *P, occs: []const Occ, j: usize, with: []const Occ) ![]Occ {
        const res = try p.a.alloc(Occ, occs.len - 1 + with.len);
        @memcpy(res[0..j], occs[0..j]);
        @memcpy(res[j..][0..with.len], with);
        @memcpy(res[j + with.len ..], occs[j + 1 ..]);
        return res;
    }

    fn bindConst(p: *P, b: Bind, ind: usize) !void {
        if (p.tsUses(b.local) == 0) return;
        try p.nl(ind);
        const lty = p.t.locals.items[b.local].ty;
        const base = lty == .int or lty == .float or lty == .string or lty == .bool;
        try p.out(if (base) "let " else "const ");
        try p.local(b.local);
        if (b.annotate) {
            try p.out(": ");
            try p.ty(lty);
            p.annotations += 1;
        }
        try p.print(" = {s};", .{b.occ});
    }

    // ---- expressions ----

    /// Whether `e` would print as statements in tail position.
    fn isBlock(p: *P, e: u32) bool {
        const tag = p.t.expr(e).tag;
        return tag == .let or tag == .case or tag == .@"if";
    }

    fn expr(p: *P, e: u32, ind: usize) E!void {
        return p.exprCtx(e, ind, true);
    }

    /// `ctx`: whether TypeScript gives `e` a contextual type here. A lambda
    /// without one writes its parameter types (§6.3).
    fn exprCtx(p: *P, e: u32, ind: usize, ctx: bool) E!void {
        const t = p.t;
        const s = p.store();
        const x = t.expr(e);
        switch (x.tag) {
            .lit_int => try p.print("{d}", .{x.a}),
            .lit_float => try p.print("{d}.{d}", .{ x.a, x.b }),
            .lit_string => try p.print("\"s{d}\"", .{x.a}),
            .lit_bool => try p.out(if (x.a == 1) "true" else "false"),
            .local => try p.local(x.a),
            .global => try p.fnRef(x.a),
            .call => {
                const callee = t.expr(x.a);
                const args = t.extraList(x.b);
                if (callee.tag == .global) {
                    try p.fnRef(callee.a);
                    const targs: []const Type = @ptrCast(t.extraList(callee.b));
                    if (targs.len > 0 and (p.needsTypeArgs(callee.a, args, false) or p.anyList(targs))) try p.typeArgs(targs);
                } else try p.group(x.a, ind);
                try p.argList(args, ind);
            },
            .ctor => {
                const c = x.a;
                const d = t.ctors.items[c].decl;
                const td = t.types.items[d];
                if (td.module != p.module) try p.qual(td.module);
                try p.out(t.ctors.items[c].name);
                const args = t.extraList(x.b);
                if (td.nparams > 0 and (p.needsTypeArgs(c, args, true) or p.anyList(s.namedArgs(x.ty)))) try p.typeArgs(s.namedArgs(x.ty));
                try p.argList(args, ind);
            },
            .lambda => try p.lambda(e, ind, ctx),
            .let, .case => {
                p.invoked_arrows += 1;
                try p.out("(() => {");
                const saved = p.ret_ctx;
                p.ret_ctx = false;
                try p.tail(e, ind + 2);
                p.ret_ctx = saved;
                try p.nl(ind);
                try p.out("})()");
            },
            .@"if" => {
                try p.out("(");
                try p.group(x.a, ind);
                try p.out(" ? ");
                const nmark = p.narrowed.items.len;
                defer p.narrowed.shrinkRetainingCapacity(nmark);
                try p.condNarrows(x.a);
                try p.exprCtx(t.extra.items[x.b], ind, ctx);
                try p.out(" : ");
                try p.exprCtx(t.extra.items[x.b + 1], ind, ctx);
                try p.out(")");
            },
            .pair => {
                // A generic helper, not an array literal: without a
                // contextual type `[a, b]` is an array, and `as const` gives
                // literal types that reach comparisons (§19 V8).
                try p.baseRef("pair");
                const na = t.expr(x.a).tag == .local and p.isNarrowed(t.expr(x.a).a);
                const nb = t.expr(x.b).tag == .local and p.isNarrowed(t.expr(x.b).a);
                if (na or nb or p.hasList(x.ty)) try p.typeArgs(&s.pairParts(x.ty));
                try p.argList(&.{ x.a, x.b }, ind);
            },
            .list => {
                const items = t.extraList(x.a);
                if (items.len == 0) {
                    p.explicit_type_args += 1;
                    try p.out("([] as ReadonlyArray<");
                    try p.ty(s.listElem(x.ty));
                    try p.out(">)");
                    return;
                }
                try p.out("[");
                for (items, 0..) |it, i| {
                    if (i > 0) try p.out(", ");
                    try p.exprCtx(it, ind, false);
                }
                try p.out("]");
            },
            .binop => {
                const op: []const u8 = switch (x.op) {
                    .int_add, .float_add, .str_append => "+",
                    .int_sub, .float_sub => "-",
                    .int_mul, .float_mul => "*",
                    .bool_and => "&&",
                    .bool_or => "||",
                    .int_eq, .str_eq, .bool_eq => "===",
                    .int_lt, .float_lt => "<",
                };
                // Flatten the same operator's left spine.
                var spine: [512]u32 = undefined;
                var n: usize = 0;
                var cur = e;
                while (true) {
                    const c = t.expr(cur);
                    if (c.tag != .binop or c.op != x.op or n == spine.len - 1) break;
                    if (c.op == .int_eq or c.op == .str_eq or c.op == .bool_eq or c.op == .int_lt or c.op == .float_lt) {
                        if (n > 0) break;
                    }
                    spine[n] = c.b;
                    n += 1;
                    cur = c.a;
                }
                const logical = x.op == .bool_and or x.op == .bool_or;
                const nmark = p.narrowed.items.len;
                defer p.narrowed.shrinkRetainingCapacity(nmark);
                try p.group(cur, ind);
                if (logical) try p.condNarrows(cur);
                var i = n;
                while (i > 0) {
                    i -= 1;
                    try p.print(" {s} ", .{op});
                    try p.group(spine[i], ind);
                    if (logical) try p.condNarrows(spine[i]);
                }
            },
            .not => {
                try p.out("!");
                try p.group(x.a, ind);
            },
            .int_to_string => {
                try p.out("String(");
                try p.expr(x.a, ind);
                try p.out(")");
            },
            .list_map, .list_filter => {
                try p.receiver(x.a, ind);
                try p.out(if (x.tag == .list_map) ".map(" else ".filter(");
                try p.expr(x.b, ind);
                try p.out(")");
            },
            .list_foldl => {
                const z = t.extra.items[x.b];
                const f = t.extra.items[x.b + 1];
                try p.receiver(x.a, ind);
                try p.out(".reduce");
                try p.typeArgs(&.{x.ty});
                try p.out("(");
                try p.lambdaSwapped(f, ind);
                try p.out(", ");
                try p.expr(z, ind);
                try p.out(")");
            },
            .pipe => {
                // No pipe operator: nested calls (§2.6).
                const stages = t.extraList(x.b);
                var i: usize = stages.len;
                while (i > 0) {
                    i -= 1;
                    try p.expr(stages[i], ind);
                    try p.out("(");
                }
                try p.expr(x.a, ind);
                for (stages) |_| try p.out(")");
            },
        }
    }

    /// Whether a call of `f` (a function, or a constructor when `is_ctor`)
    /// must write its type arguments: when a type variable can come from no
    /// argument that is not a lambda, or only from literals, whose literal
    /// types TypeScript would infer and then fix (§2.6, §19 V8).
    fn needsTypeArgs(p: *P, f: u32, args: []const u32, is_ctor: bool) bool {
        const t = p.t;
        const s = p.store();
        const nvars = if (is_ctor) t.types.items[t.ctors.items[f].decl].nparams else t.fns.items[f].nvars;
        for (args) |a| if (t.expr(a).tag == .local and p.isNarrowed(t.expr(a).a)) return true;
        var any_lambda = false;
        for (args) |a| any_lambda = any_lambda or t.expr(a).tag == .lambda;
        for (0..nvars) |vi| {
            var found = false;
            for (args, 0..) |a, k| {
                const pty = if (is_ctor) t.ctors.items[f].fields[k] else t.locals.items[t.fns.items[f].params[k]].ty;
                if (!s.mentionsVar(pty, @intCast(vi))) continue;
                const tag = t.expr(a).tag;
                if (tag == .lambda) continue;
                // A `Bool` may be narrowed to `true` or `false` (through `if`,
                // `&&`, `||` and aliases), and inference would fix the variable
                // at the literal.
                if (t.expr(a).ty == .bool) return true;
                if (any_lambda and (tag == .lit_int or tag == .lit_float or tag == .lit_string or tag == .lit_bool or tag == .@"if")) continue;
                found = true;
            }
            if (!found) return true;
        }
        return false;
    }

    /// An array literal infers as a mutable `T[]`, so a type argument that
    /// is a `ReadonlyArray` would be inferred as one and then conflict
    /// (TS4104): such type arguments are written (§19 V8).
    fn anyList(p: *P, targs: []const Type) bool {
        for (targs) |x| if (p.hasList(x)) return true;
        return false;
    }

    fn hasList(p: *P, t: Type) bool {
        const s = p.store();
        return switch (s.tag(t)) {
            .list => true,
            .pair => p.hasList(s.pairParts(t)[0]) or p.hasList(s.pairParts(t)[1]),
            .named => blk: {
                for (s.namedArgs(t)) |a| if (p.hasList(a)) break :blk true;
                break :blk false;
            },
            .func => blk: {
                for (s.funcParams(t)) |a| if (p.hasList(a)) break :blk true;
                break :blk p.hasList(s.funcRet(t));
            },
            else => false,
        };
    }

    /// The locals a condition narrows in the branches it guards: those it
    /// compares with `===`, and `Bool` locals it tests, through `&&`,
    /// `||` and `!` (the TypeScript side of `Gen.markCond`).
    fn condNarrows(p: *P, c: u32) !void {
        const t = p.t;
        const x = t.expr(c);
        switch (x.tag) {
            .binop => switch (x.op) {
                .int_eq, .str_eq, .bool_eq => if (t.expr(x.a).tag == .local) try p.narrowed.append(p.a, try p.localText(t.expr(x.a).a)),
                .bool_and, .bool_or => {
                    try p.condNarrows(x.a);
                    try p.condNarrows(x.b);
                },
                else => {},
            },
            .not => try p.condNarrows(x.a),
            .local => try p.narrowed.append(p.a, try p.localText(x.a)),
            else => {},
        }
    }

    fn readsNarrowed(p: *P, e: u32) bool {
        if (p.narrowed.items.len == 0) return false;
        const Ctx = struct { p: *P, found: *bool };
        var found = false;
        analyse.walk(p.t, e, Ctx{ .p = p, .found = &found }, struct {
            fn visit(c: Ctx, i: u32) void {
                const x = c.p.t.expr(i);
                if (x.tag == .local and c.p.isNarrowed(x.a)) c.found.* = true;
            }
        }.visit);
        return found;
    }

    fn isNarrowed(p: *P, l: u32) bool {
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "v{d}", .{p.t.locals.items[l].name}) catch return false;
        for (p.narrowed.items) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    fn receiver(p: *P, e: u32, ind: usize) !void {
        const tag = p.t.expr(e).tag;
        if (tag == .local or tag == .call or tag == .list_map or tag == .list_filter) return p.expr(e, ind);
        try p.out("(");
        try p.expr(e, ind);
        try p.out(")");
    }

    fn group(p: *P, e: u32, ind: usize) !void {
        const tag = p.t.expr(e).tag;
        switch (tag) {
            .lit_int, .lit_float, .lit_string, .lit_bool, .local, .global, .call, .ctor, .pair, .list, .int_to_string, .list_map, .list_filter, .list_foldl, .pipe, .let, .case, .@"if" => try p.expr(e, ind),
            else => {
                try p.out("(");
                try p.expr(e, ind);
                try p.out(")");
            },
        }
    }

    fn argList(p: *P, args: []const u32, ind: usize) !void {
        try p.out("(");
        for (args, 0..) |a, i| {
            if (i > 0) try p.out(", ");
            try p.exprCtx(a, ind, true);
        }
        try p.out(")");
    }

    fn lambda(p: *P, e: u32, ind: usize, ctx: bool) !void {
        const t = p.t;
        const x = t.expr(e);
        const ps = t.extraList(x.a);
        try p.out("(");
        for (ps, 0..) |l, i| {
            if (i > 0) try p.out(", ");
            try p.binder(l);
            if (!ctx) {
                try p.out(": ");
                try p.ty(t.locals.items[l].ty);
                p.annotations += 1;
            }
        }
        try p.out(") => ");
        const saved = p.ret_ctx;
        p.ret_ctx = ctx;
        try p.lambdaBody(x.b, ind);
        p.ret_ctx = saved;
    }

    /// `foldl`'s lambda is (elem, acc) in the tree and (acc, elem) in
    /// `reduce` (§2.3).
    fn lambdaSwapped(p: *P, e: u32, ind: usize) !void {
        const t = p.t;
        const x = t.expr(e);
        const ps = t.extraList(x.a);
        try p.out("(");
        try p.binder(ps[1]);
        try p.out(", ");
        try p.binder(ps[0]);
        try p.out(") => ");
        try p.lambdaBody(x.b, ind);
    }

    fn lambdaBody(p: *P, body: u32, ind: usize) !void {
        if (p.isBlock(body)) {
            try p.out("{");
            try p.tail(body, ind + 2);
            try p.nl(ind);
            try p.out("}");
        } else {
            try p.expr(body, ind);
        }
    }
};
