//! The ownership checker in `check` and `build` (`docs/design/
//! ownership-checker.md` §27): on a platform that edits lists in place, the
//! pass runs after the module check, and every rejected or pending line of a
//! module the run reports on is an error; in every run that summarises, each
//! module the run checked gets its summary block, which its cache entry —
//! and the checked core — carries.
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
    in_place: []bool,
    blocks: []?[]const u8,

    pub fn deinit(i: *Inputs, gpa: Allocator) void {
        gpa.free(i.birs);
        gpa.free(i.names);
        gpa.free(i.packages);
        gpa.free(i.spans);
        gpa.free(i.sources);
        gpa.free(i.platform_names);
        gpa.free(i.in_place);
        gpa.free(i.blocks);
    }

    pub fn input(i: *const Inputs, gpa: Allocator, session: *Session) Ownership.Input {
        return .{
            .gpa = gpa,
            .graph = &session.graph,
            .birs = i.birs,
            .provenance = session.resolution.provenance,
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
            .in_place = i.in_place,
            .blocks = i.blocks,
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
        .in_place = try gpa.alloc(bool, n),
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
        out.in_place[i] = false;
        out.blocks[i] = null;
        if (i < cached.len) if (cached[i]) |l| if (l.ownership.len != 0) {
            out.blocks[i] = l.ownership;
        };
        if (out.packages[i] != .platform) continue;
        const chain = session.options.chain orelse continue;
        if (f.int() >= session.file_layers.len) continue;
        const layer = session.file_layers[f.int()];
        if (layer >= chain.layers.len) continue;
        out.platform_names[i] = chain.layers[layer].name;
        out.in_place[i] = chain.layers[layer].manifest.lists == .@"in-place";
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

/// The pass, after the module check (§27.3). `cached` holds every module
/// the run installed; the others it checked, keeping their type stores.
pub fn run(session: *Session, cached: []const ?CacheEntry.Loaded) Allocator.Error!void {
    const gpa = session.gpa;
    const n = session.graph.count();
    var ins = try inputs(gpa, session, cached);
    defer ins.deinit(gpa);
    var o = Ownership.init(ins.input(gpa, session));
    defer o.deinit();

    const chain_in_place = if (session.options.chain) |c| c.inPlace() else false;
    const making_pack = session.options.pack_out != null;
    var targets: std.ArrayList(u32) = .empty;
    defer targets.deinit(gpa);
    for (0..n) |i| {
        if (i < cached.len and cached[i] != null) continue;
        const report = switch (ins.packages[i]) {
            .app => session.enforce_ownership,
            // §27.7: core must have no rejected or pending line, and an
            // in-place chain's platforms neither.
            .core => making_pack,
            .platform => making_pack and chain_in_place,
        };
        if (report) try targets.append(gpa, @intCast(i));
    }
    const reports = try onBigStack(&o, targets.items);

    // The blocks the run's entries carry (§27.4).
    if (session.options.cache != null or making_pack) {
        session.freeOwnershipBlocks();
        session.ownership_blocks = try gpa.alloc(?[]u8, n);
        @memset(session.ownership_blocks, null);
        for (0..n) |i| {
            if (i < cached.len and cached[i] != null) continue;
            if (i >= session.checked.modules.len) continue;
            session.ownership_blocks[i] = try o.writeBlock(@intCast(i));
        }
    }

    // The errors (§27.5), one per root cause.
    var items: std.ArrayList(CheckDiagnostics.Item) = .empty;
    defer items.deinit(gpa);
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var src_ctx: SrcCtx = .{ .session = session, .arena = scratch.allocator() };
    const src: Message.Src = .{ .ctx = &src_ctx, .vtable = &src_vtable };
    for (reports) |r| {
        if (!r.checked) continue;
        var i: usize = 0;
        while (i < r.demands.len) {
            const d = r.demands[i];
            var j = i + 1;
            while (j < r.demands.len and sameCause(d, r.demands[j])) j += 1;
            defer i = j;
            if (d.verdict == .accepted) continue;
            var group: std.ArrayList(Ownership.Demand) = .empty;
            for (r.demands[i..j]) |x| {
                var line = x;
                line.span = editSpan(session, r.module, x);
                try group.append(scratch.allocator(), line);
            }
            const text = try Message.build(scratch.allocator(), src, r.module, group.items);
            const message = try gpa.dupe(u8, text);
            errdefer gpa.free(message);
            const span = group.items[0].span;
            try items.append(gpa, .{
                .code = Message.code(d),
                .module = @fromBackingInt(r.module),
                .region = @fromBackingInt(0),
                .token = if (span[0] != none) span[0] else d.token,
                .last_token = if (span[1] != none) span[1] else null,
                .message = message,
            });
        }
    }
    if (items.items.len == 0) return;
    const old = session.checked.diagnostics;
    const all = try gpa.alloc(CheckDiagnostics.Item, old.len + items.items.len);
    @memcpy(all[0..old.len], old);
    @memcpy(all[old.len..], items.items);
    items.clearRetainingCapacity();
    gpa.free(old);
    session.checked.diagnostics = all;
}

/// Two lines of one root cause (§27.5): the same place, verdict, cause and
/// reason.
fn sameCause(a: Ownership.Demand, b: Ownership.Demand) bool {
    return a.position.line == b.position.line and a.position.col == b.position.col and
        std.mem.eql(u8, a.op, b.op) and std.meta.eql(a.verdict, b.verdict) and a.approx == b.approx and
        std.mem.eql(u8, a.detail, b.detail);
}

fn onBigStack(o: *Ownership, targets: []const u32) Allocator.Error![]const Ownership.ModuleReport {
    const Runner = struct {
        o: *Ownership,
        targets: []const u32,
        result: Allocator.Error![]const Ownership.ModuleReport = undefined,

        fn go(r: *@This()) void {
            r.result = r.o.run(r.targets);
        }
    };
    var runner: Runner = .{ .o = o, .targets = targets };
    // The pass walks expression trees by recursion, as the checker does.
    const thread = std.Thread.spawn(.{ .stack_size = Session.check_stack_size }, Runner.go, .{&runner}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            Runner.go(&runner);
            return runner.result;
        },
    };
    thread.join();
    return runner.result;
}

/// The tokens a message underlines for an edit (§27.6): the walk's span,
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
