//! own3, layer 5: the prototype in a session (research report 111 §2), behind
//! the hidden `--ownership=v3`: the Driver's hook, the lowering channel for
//! `--sanitize-lists`, and `dump --stage=ownership --ownership=v3`.
//!
//! A module's contracts go to its importers through `State.shared`, one slot
//! for each module, written by the worker that checked it before any importer
//! runs. Nothing is in the interface, the cache or the checked core: a run
//! under `--ownership=v3` checks `core/` from its sources.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Session = @import("../Session.zig");
const Graph = @import("../resolve/Graph.zig");
const Bir = @import("../bir/Bir.zig");
const Types = @import("../check/Types.zig");
const CheckModule = @import("../check/Check.zig").Module;
const Dispatch = @import("../check/Dispatch.zig");
const Driver = @import("../check/Driver.zig");
const CheckDiagnostics = @import("../check/Diagnostics.zig");
const Enforce2 = @import("../own2/Enforce.zig");
const Groups = @import("../own2/Groups.zig");
const Facts = @import("../own2/Facts.zig");
const Message = @import("../own2/Message.zig");
const Report = @import("../own2/Report.zig");
const Hoists = @import("../own2/Hoists.zig");
const InternPool = @import("../InternPool.zig");
const MarkupTree = @import("../js/MarkupTree.zig");
const Check = @import("Check.zig");
const Contract = @import("Contract.zig");

pub const Inputs = Enforce2.Inputs;
pub const inputs = Enforce2.inputs;

/// What one run keeps: each module's contracts, and its report when a dump asked for it.
pub const State = struct {
    shared: Check.Shared,
    reports: []?*Report.Kept,

    pub fn init(gpa: Allocator, modules: usize) Allocator.Error!*State {
        const s = try gpa.create(State);
        errdefer gpa.destroy(s);
        const published = try gpa.alloc(?*Contract.Published, modules);
        errdefer gpa.free(published);
        @memset(published, null);
        const reports = try gpa.alloc(?*Report.Kept, modules);
        @memset(reports, null);
        s.* = .{ .shared = .{ .published = published }, .reports = reports };
        return s;
    }

    pub fn deinit(s: *State, gpa: Allocator) void {
        for (s.shared.published) |p| if (p) |x| x.deinit(gpa);
        gpa.free(s.shared.published);
        for (s.reports) |r| if (r) |k| k.deinit(gpa);
        gpa.free(s.reports);
        gpa.destroy(s);
    }
};

pub const Context = struct {
    session: *Session,
    ins: *Inputs,
    state: *State,
};

/// The names a line prints, over a session.
const NameCtx = struct {
    session: *const Session,
    ins: *const Inputs,
    types: *const Types,
    arena: Allocator,

    fn typeQualified(ctx: *anyopaque, head: u32) []const u8 {
        return typeName(ctx, head);
    }

    fn field(ctx: *anyopaque, rank: u32) []const u8 {
        const c: *NameCtx = @ptrCast(@alignCast(ctx));
        if (rank >= c.ins.rank_names.len) return "?";
        return c.session.interner.slice(c.ins.rank_names[rank]);
    }

    fn entry(c: *NameCtx, head: u32) ?Types.Entry {
        return if (head < c.types.entries.len) c.types.entries[head] else null;
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

/// The Driver's hook: in the worker that checked module `m`, after its type
/// check and before its interface is published.
pub fn checkModule(ctx: *const Context, d: *Driver, m: Graph.Index, tid: u32) Allocator.Error!void {
    const session = ctx.session;
    const gpa = d.gpa;
    const mi_u = m.int();
    // A module with no kept types is not walked (v2's hook has the same
    // test). It has no line, so the lowering channel has no accepted write
    // of it: a build edits none of its lists in place. It publishes no
    // contract, and an importer reads a callee with no contract as unknown
    // code: each argument escapes, the answer holds each argument, a function
    // handed as evidence is refused. Each of these refuses; none accepts.
    if (mi_u >= d.kept.len) return;
    const km = &d.kept[mi_u];
    const bir = ctx.ins.birs[mi_u];
    if (km.inst_type.len != bir.insts.len or km.local_type.len != bir.locals.len) return;
    const mi: Groups.Input = .{
        .gpa = gpa,
        .module = mi_u,
        .bir = bir,
        .store = &km.store,
        .inst_type = km.inst_type,
        .local_type = km.local_type,
        .decl_scheme = km.decl_scheme,
        .types = d.types,
        .birs = ctx.ins.birs,
        .provenance = session.resolution.provenance,
        .dispatch = if (mi_u < d.dispatch.len) &d.dispatch[mi_u] else null,
        .ranks = ctx.ins.ranks,
        .core = ctx.ins.core,
        .interner = &session.interner,
    };
    const token = session.profile.begin();
    defer session.profile.end(tid, token, .ownership3_module, @backingInt(session.graph.moduleFile(m)), 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var nc: NameCtx = .{ .session = session, .ins = ctx.ins, .types = d.types, .arena = arena };
    const kept = session.options.ownership_v3_dump;
    const mk = session.graph.markup;
    const markup_type: ?Check.MarkupType = if (mk.type_module.unwrap()) |mm| if (mk.type_name.unwrap()) |mn| .{ .module = mm, .name = mn } else null else null;
    const r = try Check.checkModule(gpa, arena, &mi, &ctx.state.shared, nc.names(), .{
        .summaries = if (kept) |k| k.summaries else false,
        .markup_type = markup_type,
        .kept_lets = try keptLets(arena, session, d, m, bir),
        .library = session.options.library and session.graph.modulePackage(m) == .app,
        .tokens = session.artifacts.spans(session.graph.moduleFile(m)).len(),
    });
    ctx.state.shared.published[mi_u] = r.published;

    const lines = try arena.alloc(Facts.Line, r.lines.len);
    var channel: Hoists.Builder = .{};
    for (r.lines, lines) |l, *to| {
        to.* = .{
            .position = NameCtx.position(&nc, mi_u, l.token),
            .token = l.token,
            .op = l.op,
            .base = l.base,
            .refused = l.refused,
            .accepted = l.accepted,
            .cause = l.cause,
            .detail = l.detail,
        };
        try channel.add(arena, l.inst, l.kind, l.refused, Hoists.reliesOnCallers(l.accepted));
    }
    var table = try channel.finish(arena, gpa, r.limits.len != 0);
    // Core and the platforms authorise no write of their own.
    if (session.graph.modulePackage(m) != .app) {
        gpa.free(table.writes);
        table.writes = &.{};
    }
    if (mi_u < d.channels.len) d.channels[mi_u] = table else table.deinit(gpa);

    if (kept != null and mi_u < ctx.state.reports.len) {
        var others: std.ArrayList([]const u8) = .empty;
        try others.appendSlice(arena, r.summaries);
        try others.appendSlice(arena, r.limits);
        ctx.state.reports[mi_u] = try Report.Kept.of(gpa, .{ .module = mi_u, .lines = lines, .others = others.items, .limits = @intCast(r.limits.len) });
    }
    if (session.graph.modulePackage(m) != .app or !session.enforce_ownership) return;
    const dest = &d.per_module[mi_u];
    for (lines) |l| {
        if (!l.refused) continue;
        const message = try std.fmt.allocPrint(gpa, "{s} {s} is refused: {s}{s}{s}\n\nThe step 0 prototype of the ownership checker (`--ownership=v3`) refuses a write that it cannot show to be safe. Change a copy (`List.copy`).", .{
            l.op,
            l.base,
            Facts.causeText(l.cause),
            if (l.detail.len != 0) ": " else "",
            l.detail,
        });
        try dest.append(gpa, .{ .ownership = true, .code = .list_still_used, .module = m, .region = @fromBackingInt(0), .token = l.token, .message = message });
    }
    for (r.limits) |o| try dest.append(gpa, .{ .ownership = true, .code = .ownership_limit, .module = m, .region = @fromBackingInt(0), .message = try gpa.dupe(u8, o) });
}

/// The `let`s of module `m` whose values the build's markup lowering keeps
/// beyond the call of the function that made them (kernel §6.14,
/// `boundary.md` §9.4.8, *What a lowering keeps*). The lowering says which it
/// keeps (`Lowering.keeps_let`), of the `let`s that the compiler moves into
/// a root (`MarkupTree.keptLets`): the tree is built here as the emitter
/// builds it, so the checker and the lowering read one answer. A build with
/// no lowering, or a module with no markup, keeps none.
fn keptLets(arena: Allocator, session: *const Session, d: *const Driver, m: Graph.Index, bir: *const Bir) Allocator.Error![]const u32 {
    const mk = session.graph.markup;
    const name = mk.lowering.unwrap() orelse return &.{};
    const lowering = for (markup_lowerings) |*l| {
        if (std.mem.eql(u8, l.name, session.interner.slice(name))) break l;
    } else return &.{};
    if (!lowering.groups) return &.{};
    const mi = m.int();
    // No shortcut by the dispatch table: a component's call has no row in
    // it, and a root made of one is a root all the same. The tree finds
    // the roots as the emitter does, from the `markup` instructions.
    if (mi >= d.dispatch.len) return &.{};
    const vocabulary = mk.vocabulary orelse return &.{};
    if (vocabulary.int() >= d.interfaces.len) return &.{};
    const live = try arena.alloc(u32, bir.decls.len);
    for (live, 0..) |*x, i| x.* = @intCast(i);
    const built = try MarkupTree.build(arena, .{
        .bir = bir,
        .module = mi,
        .dispatch = &d.dispatch[mi],
        .vocabulary = &d.interfaces[vocabulary.int()],
        .interner = &session.interner,
        .live = live,
        .interfaces = d.interfaces,
        .debug_module = if (session.graph.lookup(.core, InternPool.WellKnown.Debug.symbol())) |x| x.int() else null,
        .parameterised_templates = lowering.parameterised_templates,
    }) orelse return &.{};
    return MarkupTree.keptLets(arena, &built, bir, lowering);
}

const markup_lowerings = @import("markup_lowerings").all;

pub const DumpOptions = struct { totals_only: bool = false };

/// `dump --stage=ownership --ownership=v3` over `targets`: the reports that the session's check kept.
pub fn dump(gpa: Allocator, session: *Session, targets: []const u32, w: *std.Io.Writer, options: DumpOptions) (Allocator.Error || std.Io.Writer.Error)!void {
    var ins = try inputs(gpa, session);
    defer ins.deinit(gpa);
    var reports: std.ArrayList(Report.Module) = .empty;
    defer reports.deinit(gpa);
    const state = session.ownership3;
    for (targets) |m| {
        const kept: ?*Report.Kept = if (state) |s| (if (m < s.reports.len) s.reports[m] else null) else null;
        try reports.append(gpa, if (kept) |k| k.report else .{ .module = m, .checked = false });
    }
    try Report.write(w, reports.items, ins.names, .{ .totals_only = options.totals_only });
}
