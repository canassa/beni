//! The ownership checker in `check` and `build` (`docs/design/
//! ownership-checker.md` §28): on a platform that edits lists in place, the
//! module's worker computes its summaries immediately after its type check,
//! before publishing the interface and releasing its dependents. Each
//! worker owns its path and constructor tables and its local recursion.
//! Rejected or pending application demands are errors when the platform
//! enforces; every platform publishes the same summary facts.
//!
//! It also builds the pass's `Input` from a session, for the dump as well.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Session = @import("../Session.zig");
const SourceStore = @import("../SourceStore.zig");
const Bir = @import("../bir/Bir.zig");
const Token = @import("../lex/Token.zig");
const Tokenizer = @import("../lex/Tokenizer.zig");
const Graph = @import("../resolve/Graph.zig");
const CacheEntry = @import("../cache/Entry.zig");
const CheckDiagnostics = @import("../check/Diagnostics.zig");
const Ownership = @import("Ownership.zig");
const Message = @import("Message.zig");

const none = Ownership.none;

/// What `Ownership.Input` borrows, per module, built from a session.
pub const Inputs = struct {
    birs: []*const Bir,
    names: [][]const u8,
    packages: []SourceStore.Package,
    spans: []Token.Spans,
    sources: [][]const u8,
    platform_names: [][]const u8,
    blocks: []?[]const u8,

    pub fn deinit(i: *Inputs, gpa: Allocator) void {
        gpa.free(i.birs);
        gpa.free(i.names);
        gpa.free(i.packages);
        gpa.free(i.spans);
        gpa.free(i.sources);
        gpa.free(i.platform_names);
        gpa.free(i.blocks);
    }

    pub fn input(i: *const Inputs, gpa: Allocator, session: *Session) Ownership.Input {
        return .{
            .gpa = gpa,
            .graph = &session.graph,
            .birs = i.birs,
            .provenance = session.resolution.provenance,
            .interfaces = session.resolution.interfaces,
            .dispatch = session.checked.dispatch,
            .modules = session.checked.modules,
            .types = &session.checked.types,
            .interner = &session.interner,
            .module_names = i.names,
            .packages = i.packages,
            .spans = i.spans,
            .sources = i.sources,
            .positions = .{ .ctx = session, .get = position },
            .platform_names = i.platform_names,
            .blocks = i.blocks,
            .records_lost = session.options.ownership_records_lost,
            .profile = &session.profile,
        };
    }
};

/// The per-module tables, and each installed module's block from `cached`
/// (empty for a run that loaded none).
pub fn inputs(gpa: Allocator, session: *const Session, cached: []const ?CacheEntry.Loaded) Allocator.Error!Inputs {
    const n = session.graph.count();
    var out: Inputs = .{
        .birs = try gpa.alloc(*const Bir, n),
        .names = try gpa.alloc([]const u8, n),
        .packages = try gpa.alloc(SourceStore.Package, n),
        .spans = try gpa.alloc(Token.Spans, n),
        .sources = try gpa.alloc([]const u8, n),
        .platform_names = try gpa.alloc([]const u8, n),
        .blocks = try gpa.alloc(?[]const u8, n),
    };
    for (0..n) |i| {
        const m: Graph.Index = @fromBackingInt(@intCast(i));
        const f = session.graph.moduleFile(m);
        out.birs[i] = session.artifacts.bir(f);
        out.names[i] = session.store.moduleName(f);
        out.packages[i] = session.graph.modulePackage(m);
        out.spans[i] = session.artifacts.spans(f);
        out.sources[i] = session.store.bytes(f);
        out.platform_names[i] = "";
        out.blocks[i] = null;
        if (i < cached.len) if (cached[i]) |l| if (l.ownership.len != 0) {
            out.blocks[i] = l.ownership;
        };
        if (out.packages[i] != .platform) continue;
        const chain = session.options.chain orelse continue;
        // Every platform file has a layer once the store is numbered; a
        // missing one would lose a platform-qualified report name.
        if (std.debug.runtime_safety) std.debug.assert(f.int() < session.file_layers.len and session.file_layers[f.int()] < chain.layers.len);
        if (f.int() >= session.file_layers.len) continue;
        const layer = session.file_layers[f.int()];
        if (layer >= chain.layers.len) continue;
        out.platform_names[i] = chain.layers[layer].name;
    }
    return out;
}

fn position(ctx: *const anyopaque, module: u32, tok: u32) Ownership.Position {
    const s: *const Session = @ptrCast(@alignCast(ctx));
    const f = s.graph.moduleFile(@fromBackingInt(@intCast(module)));
    const line_starts = s.store.lineStarts(f);
    const sp = s.artifacts.spans(f);
    // `0:0`, never a plausible position: a golden must show it.
    if (line_starts.len == 0 or tok >= sp.len()) return .{ .line = 0, .col = 0 };
    const pos = diagnostic.position(line_starts, s.store.bytes(f), sp.starts[tok]);
    return .{ .line = pos.line, .col = pos.col };
}

/// Read-only session metadata prepared before the DAG starts. Every mutable
/// result is written only by its module's checking worker.
pub const Context = struct {
    session: *Session,
    ins: *Inputs,
};

pub fn checkModule(ctx: *const Context, d: *@import("../check/Driver.zig"), m: Graph.Index, tid: u32) Allocator.Error!void {
    const session = ctx.session;
    const gpa = d.gpa;
    const token = session.profile.begin();
    defer session.profile.end(tid, token, .ownership, @backingInt(d.graph.moduleFile(m)), 0);
    var in = ctx.ins.input(gpa, session);
    in.single_module = m.int();
    in.tid = tid;
    in.interfaces = d.interfaces;
    in.dispatch = d.dispatch;
    in.modules = d.kept;
    in.types = d.types;
    in.blocks = ctx.ins.blocks;
    const chain_in_place = if (session.options.chain) |c| session.options.ownership_everywhere or c.inPlace() else false;
    const making_pack = session.options.pack_out != null;
    const report = switch (ctx.ins.packages[m.int()]) {
        .app => session.enforce_ownership,
        .core => making_pack,
        .platform => making_pack and chain_in_place,
    };
    var o = Ownership.init(in);
    defer o.deinit();
    // With no public value there is no callable summary to compute. On a
    // platform that does not enforce, private bodies cannot affect an
    // importer. Keep this cache report uncertified so enforcement rechecks it.
    const private_only = !report and session.ownership_sites.len == 0 and d.interfaces[m.int()].values.len == 0;
    const private_token = if (private_only) session.profile.begin() else null;
    defer if (private_token) |t| session.profile.end(tid, t, .ownership_module, @backingInt(d.graph.moduleFile(m)), 0);
    const reports = try o.run(if (private_only) &.{} else &.{m.int()});
    if (m.int() < session.ownership_sites.len) session.ownership_sites[m.int()] = try Ownership.observations(gpa, reports[0]);
    const block_wire = @import("summary_bytes.zig");
    const block = if (private_only) try block_wire.write(&o, gpa, &.{}) else try o.writeBlock(m.int());
    if (!private_only) {
        d.hoists[m.int()] = try reports[0].hoist_table.clone(gpa);
        block_wire.certify(block, reports[0]);
    }
    session.ownership_blocks[m.int()] = block;
    try o.publish(m.int(), &d.interfaces[m.int()]);
    if (d.options.roundtrip_interfaces) {
        const iface = &d.interfaces[m.int()];
        const wire = @import("../resolve/iface_bytes.zig");
        const bytes = try wire.write(gpa, iface, d.interner);
        defer gpa.free(bytes);
        const back = wire.read(gpa, bytes, d.interner) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => @panic("ownership: published interface does not roundtrip"),
        };
        iface.deinit(gpa);
        iface.* = back;
    }
    ctx.ins.blocks[m.int()] = d.interfaces[m.int()].ownership;

    if (report) try diagnostics(session, reports, &d.per_module[m.int()]);
}

fn diagnostics(session: *Session, reports: []const Ownership.ModuleReport, dest: *std.ArrayList(CheckDiagnostics.Item)) Allocator.Error!void {
    const gpa = session.gpa;
    // The errors (§28.5), one per root cause.
    var items: std.ArrayList(CheckDiagnostics.Item) = .empty;
    defer items.deinit(gpa);
    // The messages are `items`' until they move into the check's list.
    errdefer for (items.items) |item| gpa.free(item.message);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var src_ctx: SrcCtx = .{ .session = session, .arena = scratch.allocator() };
    const src: Message.Src = .{ .ctx = &src_ctx, .vtable = &src_vtable };
    // §16.7: a limit of the checker is one error at the declaration that
    // reached it. The rejections it causes downstream follow from it, so a
    // run that reports one does not report them too.
    var any_limit = false;
    for (reports) |r| {
        if (!r.checked) continue;
        for (r.limits) |h| {
            any_limit = true;
            const text = try Message.limit(scratch.allocator(), src, r.module, h);
            try items.ensureUnusedCapacity(gpa, 1);
            const message = try gpa.dupe(u8, text);
            items.appendAssumeCapacity(.{
                .ownership = true,
                .code = .ownership_limit,
                .module = @fromBackingInt(r.module),
                .region = @fromBackingInt(0),
                .token = blk: {
                    const t = srcDeclToken(&src_ctx, r.module, h.decl);
                    break :blk if (t == none) null else t;
                },
                .last_token = null,
                .message = message,
            });
        }
    }
    for (reports) |r| {
        if (!r.checked) continue;
        var i: usize = 0;
        while (i < r.demands.len) {
            const d = r.demands[i];
            var j = i + 1;
            while (j < r.demands.len and sameCause(d, r.demands[j])) j += 1;
            defer i = j;
            // A record demand is reported, not enforced, until §31.9's codes land.
            if (d.verdict == .accepted or d.record) continue;
            if (any_limit and d.verdict == .rejected and d.verdict.rejected == .limit) continue;
            var group: std.ArrayList(Ownership.Demand) = .empty;
            for (r.demands[i..j]) |x| {
                var line = x;
                line.span = editSpan(session, r.module, x);
                try group.append(scratch.allocator(), line);
            }
            const text = try Message.build(scratch.allocator(), src, r.module, group.items);
            try items.ensureUnusedCapacity(gpa, 1);
            const message = try gpa.dupe(u8, text);
            const span = group.items[0].span;
            items.appendAssumeCapacity(.{
                .ownership = true,
                .ownership_consequence = d.verdict == .rejected and d.verdict.rejected == .limit,
                .code = Message.code(d),
                .module = @fromBackingInt(r.module),
                // No instruction: the span is `token` to `last_token`, the
                // edit (§28.6), which `Session.reportCheckDiagnostics` reads
                // before `region`. Never cached: a module with an error is not.
                .region = @fromBackingInt(0),
                .token = if (span[0] != none) span[0] else d.token,
                .last_token = if (span[1] != none) span[1] else null,
                .message = message,
            });
        }
    }
    if (items.items.len == 0) return;
    try dest.appendSlice(gpa, items.items);
    items.clearRetainingCapacity();
}

/// Two lines of one root cause (§28.5): the same place, verdict, cause and
/// reason.
fn sameCause(a: Ownership.Demand, b: Ownership.Demand) bool {
    // `.record` too: a list writer may be named `update` as well.
    return a.record == b.record and a.position.line == b.position.line and a.position.col == b.position.col and
        std.mem.eql(u8, a.op, b.op) and std.meta.eql(a.verdict, b.verdict) and a.approx == b.approx and
        std.mem.eql(u8, a.detail, b.detail);
}

/// The tokens a message underlines for an edit (§28.6): the walk's span,
/// grown to the brackets it opens or closes — a construction from its `[`
/// to its `]`.
fn editSpan(session: *const Session, module: u32, d: Ownership.Demand) [2]u32 {
    var lo = d.span[0];
    var hi = d.span[1];
    // An entry line is about the program constructor's call: its name.
    if (std.mem.startsWith(u8, d.op, "entry ")) return .{ d.token, d.token };
    if (lo == none or hi == none or hi < lo) return .{ d.token, d.token };
    const f = session.graph.moduleFile(@fromBackingInt(@intCast(module)));
    const tags = session.artifacts.spans(f).tags;
    if (hi >= tags.len) return .{ d.token, d.token };
    // A construction's spread literal: its own `[`, before the first item.
    if (std.mem.eql(u8, d.op, "construction") and lo > 0 and tags[lo - 1] == .l_bracket) lo -= 1;
    // Closers whose opener is before `lo`: back to the opener.
    var sum: i32 = 0;
    var lowest: i32 = 0;
    var k = lo;
    while (k <= hi) : (k += 1) {
        sum += delimiter(tags[k]);
        lowest = @min(lowest, sum);
    }
    var need = -lowest;
    while (need > 0 and lo > 0) {
        lo -= 1;
        need -= delimiter(tags[lo]);
    }
    // Openers whose closer is after `hi`: on to the closer.
    var open: i32 = 0;
    k = lo;
    while (k <= hi) : (k += 1) open += delimiter(tags[k]);
    while (open > 0 and hi + 1 < tags.len) {
        hi += 1;
        open += delimiter(tags[hi]);
    }
    return .{ lo, hi };
}

fn delimiter(t: Token.Tag) i32 {
    return switch (t) {
        .l_paren, .l_bracket, .l_brace => 1,
        .r_paren, .r_bracket, .r_brace => -1,
        else => 0,
    };
}

const src_vtable: Message.Src.VTable = .{
    .start = srcStart,
    .end = srcEnd,
    .line = srcLine,
    .path = srcPath,
    .decl_token = srcDeclToken,
    .decl_name = srcDeclName,
    .module_name = srcModuleName,
};

const SrcCtx = struct { session: *const Session, arena: Allocator };

fn sessionOf(ctx: *const anyopaque) *const Session {
    const c: *const SrcCtx = @ptrCast(@alignCast(ctx));
    return c.session;
}

fn fileOf(s: *const Session, m: u32) SourceStore.Index {
    return s.graph.moduleFile(@fromBackingInt(@intCast(m)));
}

fn srcStart(ctx: *const anyopaque, m: u32, tok: u32) diagnostic.Position {
    const s = sessionOf(ctx);
    const f = fileOf(s, m);
    const sp = s.artifacts.spans(f);
    if (tok >= sp.len()) return .{ .line = 1, .col = 1 };
    return diagnostic.position(s.store.lineStarts(f), s.store.bytes(f), sp.starts[tok]);
}

fn srcEnd(ctx: *const anyopaque, m: u32, tok: u32) diagnostic.Position {
    const s = sessionOf(ctx);
    const f = fileOf(s, m);
    const sp = s.artifacts.spans(f);
    if (tok >= sp.len()) return .{ .line = 1, .col = 1 };
    const source = s.store.bytes(f);
    const end = Tokenizer.tokenEnd(source, sp.tags[tok], sp.starts[tok]);
    return diagnostic.position(s.store.lineStarts(f), source, end);
}

fn srcLine(ctx: *const anyopaque, m: u32, n: u32) []const u8 {
    const s = sessionOf(ctx);
    const f = fileOf(s, m);
    const starts = s.store.lineStarts(f);
    const source = s.store.bytes(f);
    if (n == 0 or n > starts.len) return "";
    const from = starts[n - 1];
    const to = if (n < starts.len) starts[n] else @as(u32, @intCast(source.len));
    return std.mem.trimEnd(u8, source[from..to], "\r\n");
}

fn srcPath(ctx: *const anyopaque, m: u32) []const u8 {
    const s = sessionOf(ctx);
    return s.store.path(fileOf(s, m));
}

fn srcDeclToken(ctx: *const anyopaque, m: u32, d: u32) u32 {
    const s = sessionOf(ctx);
    const bir = s.artifacts.bir(fileOf(s, m));
    if (d >= bir.decls.len) return none;
    return bir.decls[d].name_token;
}

fn srcDeclName(ctx: *const anyopaque, m: u32, d: u32) []const u8 {
    const s = sessionOf(ctx);
    const f = fileOf(s, m);
    const bir = s.artifacts.bir(f);
    if (d >= bir.decls.len) return "?";
    return s.interner.slice(bir.symbol(bir.decls[d].name));
}

fn srcModuleName(ctx: *const anyopaque, m: u32) []const u8 {
    const s = sessionOf(ctx);
    return s.store.moduleName(fileOf(s, m));
}
