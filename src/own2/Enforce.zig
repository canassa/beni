//! L14: the ownership checker v2 in a session (`docs/design/ownership-v2.md`
//! §3.7, §8 S3a): the per-module inputs built from the session, the
//! `dump --stage=ownership --ownership=v2` report, and the Driver's hook,
//! all behind the hidden `--ownership=v2`.
//!
//! Obligations kept here: none (plumbing).

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Session = @import("../Session.zig");
const Graph = @import("../resolve/Graph.zig");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Types = @import("../check/Types.zig");
const Module = @import("../check/Check.zig").Module;
const Dispatch = @import("../check/Dispatch.zig");
const Driver = @import("../check/Driver.zig");
const CheckDiagnostics = @import("../check/Diagnostics.zig");
const Facts = @import("Facts.zig");
const Groups = @import("Groups.zig");
const Ownership = @import("Ownership.zig");
const Message = @import("Message.zig");
const Report = @import("Report.zig");

/// What every module's check reads from the session, built once before
/// the DAG starts and read-only after.
pub const Inputs = struct {
    birs: []*const Bir,
    names: [][]const u8,
    /// Per global symbol its rank in text order, and per rank its symbol.
    ranks: []u32,
    rank_names: []InternPool.Symbol,

    pub fn deinit(i: *Inputs, gpa: Allocator) void {
        gpa.free(i.birs);
        gpa.free(i.names);
        gpa.free(i.ranks);
        gpa.free(i.rank_names);
    }
};

pub fn inputs(gpa: Allocator, session: *const Session) Allocator.Error!Inputs {
    const n = session.graph.count();
    var out: Inputs = .{
        .birs = try gpa.alloc(*const Bir, n),
        .names = try gpa.alloc([]const u8, n),
        .ranks = &.{},
        .rank_names = &.{},
    };
    for (0..n) |i| {
        const f = session.graph.moduleFile(@fromBackingInt(@intCast(i)));
        out.birs[i] = session.artifacts.bir(f);
        out.names[i] = session.store.moduleName(f);
    }
    // Every symbol by its text, once (§3.8: steps order by text, never by
    // a session id).
    const interner = &session.interner;
    const count = interner.count();
    out.rank_names = try gpa.alloc(InternPool.Symbol, count);
    for (out.rank_names, 0..) |*s, i| s.* = @fromBackingInt(@intCast(i));
    std.mem.sort(InternPool.Symbol, out.rank_names, interner, struct {
        fn lessThan(in: *const InternPool.Global, a: InternPool.Symbol, b: InternPool.Symbol) bool {
            if (in.textRank(a)) |ra| if (in.textRank(b)) |rb| return ra < rb;
            return std.mem.lessThan(u8, in.slice(a), in.slice(b));
        }
    }.lessThan);
    out.ranks = try gpa.alloc(u32, count);
    for (out.rank_names, 0..) |s, r| out.ranks[@backingInt(s)] = @intCast(r);
    return out;
}

/// The names a message prints, over a session.
const NameCtx = struct {
    session: *const Session,
    ins: *const Inputs,
    types: *const Types,
    arena: Allocator,

    fn typeQualified(ctx: *anyopaque, head: u32) []const u8 {
        const c: *NameCtx = @ptrCast(@alignCast(ctx));
        const e = c.entry(head) orelse return "?";
        return std.fmt.allocPrint(c.arena, "{t}·{s}·{s}", .{ e.package, c.session.interner.slice(e.module_name), c.session.interner.slice(e.name) }) catch "?";
    }

    fn field(ctx: *anyopaque, rank: u32) []const u8 {
        const c: *NameCtx = @ptrCast(@alignCast(ctx));
        if (rank >= c.ins.rank_names.len) return "?";
        return c.session.interner.slice(c.ins.rank_names[rank]);
    }

    fn entry(c: *NameCtx, head: u32) ?Types.Entry {
        const types = c.types;
        return if (head < types.entries.len) types.entries[head] else null;
    }

    fn ctor(ctx: *anyopaque, head: u32, ordinal: u32) []const u8 {
        const c: *NameCtx = @ptrCast(@alignCast(ctx));
        const e = c.entry(head) orelse return "?";
        const bir = c.ins.birs[e.module.int()];
        const ctors = bir.declCtors(bir.decl(e.decl));
        if (ordinal >= ctors.len) return "?";
        return c.session.interner.slice(bir.symbol(ctors[ordinal].name));
    }

    fn typeName(ctx: *anyopaque, head: u32) []const u8 {
        const c: *NameCtx = @ptrCast(@alignCast(ctx));
        const e = c.entry(head) orelse return "?";
        return c.session.interner.slice(e.name);
    }

    fn position(ctx: *anyopaque, module: u32, tok: u32) Message.Position {
        const c: *NameCtx = @ptrCast(@alignCast(ctx));
        const s = c.session;
        const f = s.graph.moduleFile(@fromBackingInt(@intCast(module)));
        const line_starts = s.store.lineStarts(f);
        const sp = s.artifacts.spans(f);
        if (line_starts.len == 0 or tok >= sp.len()) return .{ .line = 0, .col = 0 };
        const pos = diagnostic.position(line_starts, s.store.bytes(f), sp.starts[tok]);
        return .{ .line = pos.line, .col = pos.col };
    }

    fn names(c: *NameCtx) Message.Names {
        return .{
            .ctx = c,
            .interner = &c.session.interner,
            .module_names = c.ins.names,
            .birs = c.ins.birs,
            .field = field,
            .ctor = ctor,
            .type_name = typeName,
            .type_qualified = typeQualified,
            .position = position,
        };
    }
};

/// What a module's check left, while its worker has it (the Driver's
/// tables) or after the run (the session's).
const Tables = struct { modules: []Module, types: *const Types, dispatch: []const Dispatch };

/// Module `m`'s `Groups.Input`, or null when the run did not check it.
fn moduleInput(gpa: Allocator, session: *Session, ins: *const Inputs, t: Tables, m: u32) ?Groups.Input {
    if (m >= t.modules.len) return null;
    const km = &t.modules[m];
    const bir = ins.birs[m];
    if (km.inst_type.len != bir.insts.len or km.local_type.len != bir.locals.len) return null;
    return .{
        .gpa = gpa,
        .module = m,
        .bir = bir,
        .store = &km.store,
        .inst_type = km.inst_type,
        .local_type = km.local_type,
        .decl_scheme = km.decl_scheme,
        .types = t.types,
        .birs = ins.birs,
        .provenance = session.resolution.provenance,
        .dispatch = if (m < t.dispatch.len) &t.dispatch[m] else null,
        .ranks = ins.ranks,
    };
}

pub const DumpOptions = struct { totals_only: bool = false };

/// `dump --stage=ownership --ownership=v2` over `targets` (module indices,
/// in path order).
pub fn dump(gpa: Allocator, session: *Session, targets: []const u32, w: *std.Io.Writer, options: DumpOptions) (Allocator.Error || std.Io.Writer.Error)!void {
    var ins = try inputs(gpa, session);
    defer ins.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var mods: std.ArrayList(Groups.Input) = .empty;
    defer mods.deinit(gpa);
    var reports: std.ArrayList(Report.Module) = .empty;
    defer reports.deinit(gpa);
    var nc: NameCtx = .{ .session = session, .ins = &ins, .types = &session.checked.types, .arena = arena };
    for (targets) |m| {
        // The session's check ran v2 on the module and kept its report
        // (#1193): print it, never run v2 again.
        if (m < session.ownership2_reports.len) {
            if (session.ownership2_reports[m]) |k| {
                try reports.append(gpa, k.report);
                continue;
            }
            try reports.append(gpa, .{ .module = m, .checked = false });
            continue;
        }
        const mi = moduleInput(gpa, session, &ins, .{ .modules = session.checked.modules, .types = &session.checked.types, .dispatch = session.checked.dispatch }, m) orelse {
            try reports.append(gpa, .{ .module = m, .checked = false });
            continue;
        };
        try mods.append(gpa, mi);
        const token = session.profile.begin();
        defer session.profile.end(0, token, .ownership2_module, @backingInt(session.graph.moduleFile(@fromBackingInt(m))), 0);
        const one = try Ownership.run(gpa, arena, .{ .names = nc.names(), .modules = mods.items[mods.items.len - 1 ..], .format_summaries = !options.totals_only });
        try reports.appendSlice(gpa, one);
    }
    try Report.write(w, reports.items, ins.names, .{ .totals_only = options.totals_only });
}

/// Read-only session metadata prepared before the DAG starts.
pub const Context = struct {
    session: *Session,
    ins: *Inputs,
};

/// The Driver's hook (§3.7): in the worker that checked module `m`, after
/// its type check and before its interface is published, the checker v2
/// checks it; an application module on a chain that enforces gets its
/// refusals as errors (R-1.1, R-8.1).
pub fn checkModule(ctx: *const Context, d: *Driver, m: Graph.Index, tid: u32) Allocator.Error!void {
    const session = ctx.session;
    const gpa = d.gpa;
    const mi = moduleInput(gpa, session, ctx.ins, .{ .modules = d.kept, .types = d.types, .dispatch = d.dispatch }, m.int()) orelse return;
    const token = session.profile.begin();
    defer session.profile.end(tid, token, .ownership2_module, @backingInt(session.graph.moduleFile(m)), 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var nc: NameCtx = .{ .session = session, .ins = ctx.ins, .types = d.types, .arena = arena };
    const one = [_]Groups.Input{mi};
    const kept = session.options.ownership_v2_dump;
    const reports = try Ownership.run(gpa, arena, .{ .names = nc.names(), .modules = &one, .publish = true, .format_summaries = if (kept) |k| k.summaries else false });
    // The dump's report, from this run (#1193): one slot per module, written
    // by the worker that checked it.
    if (kept != null and m.int() < session.ownership2_reports.len) session.ownership2_reports[m.int()] = try Report.Kept.of(gpa, reports[0]);
    // §3.7: the block in the interface, hashed with it, for importers.
    if (reports[0].block) |b| {
        const iface = &d.interfaces[m.int()];
        gpa.free(iface.ownership);
        iface.ownership = try gpa.dupe(u8, b);
    }
    // A v2 word on a place without its kind (#1056 item 4): an error in
    // the core or platform module that wrote it, enforcing or not.
    for (reports[0].word_errors) |e| {
        const d_ = mi.bir.decls[e[0]];
        const word: @import("../parse/Ast.zig").OwnWord = @fromBackingInt(@intCast(e[2]));
        const what = if (e[1] == Bir.own_result) "the result" else try std.fmt.allocPrint(arena, "parameter {d}", .{e[1] + 1});
        const message = try std.fmt.allocPrint(gpa, "`{t}` reads a list, a cell or a dictionary that {s} of `{s}` is not.\n\nA word that names a storage kind belongs on a value of that kind: `sequence` and\n`cell` types say which (ownership-v2.md §2.13.6).", .{ word, what, session.interner.slice(mi.bir.symbol(d_.name)) });
        try d.per_module[m.int()].append(gpa, .{ .code = .misplaced_ownership_word, .module = m, .region = @fromBackingInt(0), .token = d_.name_token, .message = message });
    }
    const package = session.graph.modulePackage(m);
    if (package != .app or !session.enforce_ownership) return;
    try diagnostics(gpa, arena, reports, &d.per_module[m.int()]);
}

/// One error per refused or limited line (R-1.1, §6): the code by cause
/// and kind (R-6.1), the verdict line as the message.
fn diagnostics(gpa: Allocator, arena: Allocator, reports: []const Report.Module, dest: *std.ArrayList(CheckDiagnostics.Item)) Allocator.Error!void {
    for (reports) |r| {
        for (r.lines) |l| {
            if (!l.refused) continue;
            const code: @import("diagnostic").Code = switch (l.cause) {
                .top_level => .top_level_list_changed,
                .read_only => .view_changes_model,
                .limit => .ownership_limit,
                else => if (l.approx) .list_may_be_shared else .list_still_used,
            };
            const message = try std.fmt.allocPrint(gpa, "{s} {s} is refused: {s}{s}\n\n{s}", .{
                l.op,
                l.base,
                Facts.causeText(l.cause),
                if (l.detail.len != 0) try std.fmt.allocPrint(arena, ": {s}", .{l.detail}) else "",
                if (l.approx) "This is a limit of the checker, not proof of sharing." else "This is sharing the checker can see.",
            });
            try dest.append(gpa, .{ .ownership = true, .code = code, .module = @fromBackingInt(r.module), .region = @fromBackingInt(0), .token = l.token, .message = message });
        }
        for (r.others) |o| if (std.mem.startsWith(u8, o, "limit ")) {
            try dest.append(gpa, .{ .ownership = true, .code = .ownership_limit, .module = @fromBackingInt(r.module), .region = @fromBackingInt(0), .message = try gpa.dupe(u8, o) });
        };
    }
}
