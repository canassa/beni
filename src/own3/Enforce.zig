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
const Reads = @import("Reads.zig");
const InternPool = @import("../InternPool.zig");
const MarkupTree = @import("../js/MarkupTree.zig");
const Check = @import("Check.zig");
const Contract = @import("Contract.zig");
const Prepass = @import("../own2/Prepass.zig");

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

/// The value of core that `callee` names, as `(module, spelling)`: an
/// `ext_value`, through a chain of locals that a `let` binds to it
/// (`upd = Dict.update`, `q = upd`), as `Lower.listWriterOf` follows it,
/// and through top-level aliases of other modules (a platform's `pub ins =
/// Dict.insert`), as `Mod.calleeOf` and `Lower.coreWriterAt` follow them.
fn coreValueOf(session: *const Session, birs: []const *const Bir, bir: *const Bir, callee: Bir.Inst.Index) ?struct { Graph.Index, []const u8 } {
    var at = callee;
    var depth: u32 = 0;
    while (bir.instTag(at) == .local and depth < 8) : (depth += 1) at = letValueOf(bir, at) orelse return null;
    if (bir.instTag(at) != .ext_value) return null;
    const d = bir.instData(at);
    const module: Graph.Index = @fromBackingInt(@intCast(d.lhs));
    if (module.int() >= session.resolution.interfaces.len) return null;
    if (session.graph.modulePackage(module) == .core) {
        _, const spelling = coreNames(session, module, d.rhs) orelse return null;
        return .{ module, spelling };
    }
    const provenance = session.resolution.provenance;
    if (module.int() >= provenance.len) return null;
    const decl = provenance[module.int()].valueDecl(d.rhs) orelse return null;
    var t: [2]u32 = .{ module.int(), decl.int() };
    var budget: u32 = 16;
    while (budget > 0) : (budget -= 1) t = Prepass.aliasStep(birs, provenance, t) orelse break;
    if (t[0] == module.int() or t[0] >= birs.len) return null;
    const target: Graph.Index = @fromBackingInt(t[0]);
    if (session.graph.modulePackage(target) != .core or t[1] >= birs[t[0]].decls.len) return null;
    return .{ target, session.interner.slice(birs[t[0]].symbol(birs[t[0]].decls[t[1]].name)) };
}

/// The definition a `let` binds local `inst` to, as `Lower.letValueOf`
/// reads it.
fn letValueOf(bir: *const Bir, inst: Bir.Inst.Index) ?Bir.Inst.Index {
    const local = bir.instData(inst).lhs;
    for (bir.decls) |d| {
        if (inst.int() < d.inst_start.int() or inst.int() >= d.inst_end.int()) continue;
        const locals = bir.declLocals(d);
        if (local >= locals.len or locals[local].kind != .let) return null;
        const def = locals[local].inst;
        if (bir.instTag(def) != .let_def) return null;
        return @fromBackingInt(@intCast(bir.instData(def).rhs));
    }
    return null;
}

/// The name of core module `module`, and the spelling of its value `value`.
fn coreNames(session: *const Session, module: Graph.Index, value: u32) ?struct { []const u8, []const u8 } {
    const iface = &session.resolution.interfaces[module.int()];
    if (value >= iface.values.len) return null;
    return .{ session.interner.slice(session.graph.moduleName(module)), session.interner.slice(iface.symbols[@backingInt(iface.values[value].name)]) };
}

/// Whether instruction `inst` is the body of a top-level alias
/// (`Prepass.isAliasShape`: a value of no parameter whose body is a name).
fn isAliasBody(bir: *const Bir, inst: u32) bool {
    for (bir.decls) |d| {
        const body = d.body.unwrap() orelse continue;
        if (body.int() == inst and Prepass.isAliasShape(bir, d)) return true;
    }
    return false;
}

/// The copy that a refused write's message names: of a record, of a
/// dictionary or a set where the writer is theirs, else of a list.
fn copyFix(record: bool, op: []const u8, base: []const u8) []const u8 {
    if (record) return "Record.copy";
    const writer = if (std.mem.eql(u8, op, "value")) base else if (std.mem.startsWith(u8, op, "call ")) op["call ".len..] else op;
    if (std.mem.startsWith(u8, writer, "Dict.")) return "Dict.copy";
    if (std.mem.startsWith(u8, writer, "Set.")) return "Set.copy";
    return "List.copy";
}

fn isOneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |w| if (std.mem.eql(u8, w, name)) return true;
    return false;
}

/// The core value that instruction `inst` calls: a `call` of an
/// `ext_value` or of a local bound to one, or a `method_call` whose
/// dispatch term is a value of a core module (`d.update k f`).
fn coreCallee(session: *const Session, birs: []const *const Bir, bir: *const Bir, dispatch: ?*const Dispatch, inst: u32) ?struct { Graph.Index, []const u8 } {
    if (inst >= bir.insts.len) return null;
    const call: Bir.Inst.Index = @fromBackingInt(inst);
    if (bir.instTag(call) == .call) return coreValueOf(session, birs, bir, @fromBackingInt(@intCast(bir.instData(call).lhs)));
    if (bir.instTag(call) != .method_call) return null;
    const dt = dispatch orelse return null;
    const site = dt.siteOf(call) orelse return null;
    const ti = site.callee.unwrap() orelse return null;
    return switch (dt.term(ti)) {
        .ext => |u| if (u.module.int() < session.resolution.interfaces.len and session.graph.modulePackage(u.module) == .core) (if (coreNames(session, u.module, @backingInt(u.value))) |n| .{ u.module, n[1] } else null) else null,
        // No other term names a value of another module.
        .top, .param, .derived, .ext_derived, .primitive, .undetermined, .field, .identity, .text, .codec => null,
    };
}

/// Whether instruction `inst` calls a walked writer of core by its name:
/// `List.update`, or one of `Dict`'s and `Set`'s (kernel §12), however the
/// call names it: directly, method-style (`d.update k f`), or through a
/// local alias (`upd = Dict.update`).
fn callsCoreWriter(session: *const Session, birs: []const *const Bir, bir: *const Bir, dispatch: ?*const Dispatch, inst: u32) bool {
    const module, const name = coreCallee(session, birs, bir, dispatch, inst) orelse return false;
    const module_name = session.interner.slice(session.graph.moduleName(module));
    if (session.graph.moduleName(module) == InternPool.WellKnown.List.symbol()) return std.mem.eql(u8, name, "update");
    // The walked writers of `Dict` and `Set` (kernel §12): the write is a
    // row's inside core, and the lowering edits the call as the writer.
    if (std.mem.eql(u8, module_name, "Dict")) return isOneOf(name, &.{ "update", "sortBy" });
    if (std.mem.eql(u8, module_name, "Set")) return isOneOf(name, &.{ "insert", "remove", "swap", "insertAt", "sortBy" });
    return false;
}

/// The qualified name of the writer of core's `List`, `Dict` or `Set` that
/// instruction `inst` names as a value: an `ext_value` of the writer, or
/// of a top-level alias of it (`coreValueOf`), anywhere but as the callee
/// of a `call` (`callee`). Kernel §12 item 5, *A writer value is routed
/// where it is made*: each run of it is judged where it runs, and the
/// lowering routes the value where the reference is (`Lower.reference`,
/// which reads the same instructions).
fn valueWriter(session: *const Session, birs: []const *const Bir, bir: *const Bir, callee: []const bool, inst: u32) ?[]const u8 {
    const at: Bir.Inst.Index = @fromBackingInt(inst);
    if (bir.instTag(at) != .ext_value or callee[inst]) return null;
    const module, const name = coreValueOf(session, birs, bir, at) orelse return null;
    const module_name = session.interner.slice(session.graph.moduleName(module));
    const writers: []const []const u8 = if (session.graph.moduleName(module) == InternPool.WellKnown.List.symbol())
        &.{ "List.set", "List.update", "List.push", "List.pop", "List.swap", "List.insertAt", "List.removeAt", "List.append" }
    else if (std.mem.eql(u8, module_name, "Dict"))
        &.{ "Dict.insert", "Dict.remove", "Dict.update", "Dict.swap", "Dict.insertAt", "Dict.sortBy" }
    else if (std.mem.eql(u8, module_name, "Set"))
        &.{ "Set.insert", "Set.remove", "Set.swap", "Set.insertAt", "Set.sortBy" }
    else
        &.{};
    for (writers) |w| if (std.mem.eql(u8, w[module_name.len + 1 ..], name)) return w;
    return null;
}

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
        .rows = session.graph.modulePackage(m) != .app,
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
        // `List.update` has no words: its write is `focus`'s, inside core,
        // so v3 says it at the call (`callsite`). The lowering edits the call
        // as the writer it is (`backend.md` §4), so the channel names it as one.
        const dispatch: ?*const Dispatch = if (mi_u < d.dispatch.len) &d.dispatch[mi_u] else null;
        const kind = if (l.kind == .callsite and callsCoreWriter(session, ctx.ins.birs, bir, dispatch, l.inst)) .writer else l.kind;
        try channel.add(arena, l.inst, kind, l.refused, Hoists.reliesOnCallers(l.accepted));
    }
    // A writer of core named as a value (`apply Dict.insert d`, `w = idW
    // Dict.insert`): each run of it is judged where it runs (a call of it,
    // a call that hands it on, a closure that captured it), and a holder
    // that keeps or loses it refuses it (kernel §12 item 5). So where its
    // reference has no refused line, its line is accepted, and the channel
    // names it as a write: the lowering routes the value there.
    var report_lines: std.ArrayList(Facts.Line) = .empty;
    try report_lines.appendSlice(arena, lines);
    {
        const callee = try arena.alloc(bool, bir.insts.len);
        @memset(callee, false);
        for (0..bir.insts.len) |i| {
            const at: Bir.Inst.Index = @fromBackingInt(@intCast(i));
            if (bir.instTag(at) != .call) continue;
            const c = bir.instData(at).lhs;
            if (c < callee.len) callee[c] = true;
        }
        const main_tokens = bir.insts.items(.main_token);
        for (0..bir.insts.len) |i| {
            const writer = valueWriter(session, ctx.ins.birs, bir, callee, @intCast(i)) orelse continue;
            const refused = for (r.lines) |l| {
                if (l.inst == i and l.refused) break true;
            } else false;
            if (refused) continue;
            try report_lines.append(arena, .{ .position = NameCtx.position(&nc, mi_u, main_tokens[i]), .token = main_tokens[i], .op = "value", .base = writer, .refused = false, .accepted = .call });
            try channel.add(arena, @intCast(i), .writer, false, false);
        }
    }
    var table = try channel.finish(arena, gpa, r.limits.len != 0);
    // Core and the platforms authorise no write of their own.
    if (session.graph.modulePackage(m) != .app) {
        gpa.free(table.writes);
        table.writes = &.{};
    }
    // The reads the lowering reads first (kernel §11, item 10): of a module
    // whose updates it writes, that is one whose channel lists its writes.
    if (mi_u < d.hoist_reads.len) {
        gpa.free(d.hoist_reads[mi_u]);
        d.hoist_reads[mi_u] = &.{};
    }
    if (table.writes.len != 0 and mi_u < d.hoist_reads.len) {
        var reads: std.ArrayList(Reads.Read) = .empty;
        for (r.lines) |l| if (!l.refused) try reads.appendSlice(arena, l.hoists);
        d.hoist_reads[mi_u] = try gpa.dupe(Reads.Read, reads.items);
    }
    if (mi_u < d.channels.len) d.channels[mi_u] = table else table.deinit(gpa);

    if (kept != null and mi_u < ctx.state.reports.len) {
        var others: std.ArrayList([]const u8) = .empty;
        try others.appendSlice(arena, r.summaries);
        for (r.false_words) |x| try others.append(arena, x.text);
        for (r.limits) |l| try others.append(arena, l.text);
        ctx.state.reports[mi_u] = try Report.Kept.of(gpa, .{ .module = mi_u, .lines = report_lines.items, .others = others.items, .limits = @intCast(r.limits.len) });
    }
    if (!session.enforce_ownership) return;
    // Core and the platforms authorise no write of their own, so only a
    // refusal of evidence stops their build: a function handed as evidence
    // can be kept and run later on another package's values (`Hosted.key`
    // stores a key type's `compare`, which `Hosted.compare` runs on the
    // program's keys; kernel §6 rules 10 and 11).
    const app = session.graph.modulePackage(m) == .app;
    const dest = &d.per_module[mi_u];
    for (lines, r.lines) |l, rl| {
        if (!l.refused) continue;
        // A line refused because its walk gave up is no write of a list or
        // a record: the module's limit is the error (below), and stops the
        // build of the app.
        if (rl.cause == .limit and r.limits.len != 0) continue;
        // And a function that writes its parameter that a platform puts
        // where no rule follows it (`pub push = idL List.push`, kept at
        // its top level): a program runs it through the platform's value
        // with no line judging the run (kernel §12 item 5; the review of
        // research report 163). A top-level alias (`pub ins = Dict.insert`)
        // is not kept: every reader reads it as what it names
        // (`Mod.calleeOf`, `coreValueOf`), and each run is judged there.
        const kept_writer = !app and session.graph.modulePackage(m) != .core and std.mem.eql(u8, l.op, "value") and rl.cause == .call and !isAliasBody(bir, rl.inst);
        if (!app and !rl.evidence and !kept_writer) continue;
        // A write of a record's field slot is a record's refusal (kernel §11).
        // A function that writes, as a value, where no rule follows it:
        // the fix is to call it where it writes, or to hand it straight to
        // the call that runs it (kernel §12 item 5).
        const fix: []const u8 = if (std.mem.eql(u8, l.op, "value")) "Call the function directly where it writes, or hand it straight to the call that runs it, or change a copy" else "Change a copy";
        const message = try std.fmt.allocPrint(gpa, "{s} {s} is refused: {s}{s}{s}\n\nThe step 0 prototype of the ownership checker (`--ownership=v3`) refuses a write that it cannot show to be safe. {s} (`{s}`).", .{
            l.op,
            l.base,
            Facts.causeText(l.cause),
            if (l.detail.len != 0) ": " else "",
            l.detail,
            fix,
            copyFix(rl.record, l.op, l.base),
        });
        try dest.append(gpa, .{ .ownership = true, .code = if (rl.record) .record_still_used else .list_still_used, .module = m, .region = @fromBackingInt(0), .token = l.token, .message = message });
    }
    // A worded declaration whose words claim less than its walk found
    // (kernel §6 rule 10, *A worded body is checked against its walk*): a
    // fact of the words, so every package's build stops on it.
    for (r.false_words) |x| {
        const message = try std.fmt.allocPrint(gpa, "{s}\n\nA worded declaration whose body reaches no JavaScript is checked against what the ownership checker (`--ownership=v3`) finds in its body: a word may say more than the body does, never less. Correct the words.", .{x.text});
        try dest.append(gpa, .{ .ownership = true, .code = .false_ownership_word, .module = m, .region = @fromBackingInt(0), .token = x.token orelse 0, .message = message });
    }
    if (!app) return;
    for (r.limits) |o| try dest.append(gpa, .{ .ownership = true, .code = .ownership_limit, .module = m, .region = @fromBackingInt(0), .token = o.token orelse 0, .message = try gpa.dupe(u8, o.text) });
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
