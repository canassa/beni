//! L16: the ownership checker v2 in a session (`docs/design/ownership-v2.md`
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
const BlockRead = @import("BlockRead.zig");
const Interface = @import("../resolve/Interface.zig");

/// What every module's check reads from the session, built once before
/// the DAG starts and read-only after.
pub const Inputs = struct {
    birs: []*const Bir,
    names: [][]const u8,
    /// Per module, whether it is in the core package (`Session.fileIsCore`):
    /// its comparisons compose their evidence (§2.13.13).
    core: []bool = &.{},
    /// Per global symbol its rank in text order, and per rank its symbol.
    ranks: []u32,
    rank_names: []InternPool.Symbol,

    pub fn deinit(i: *Inputs, gpa: Allocator) void {
        gpa.free(i.birs);
        gpa.free(i.names);
        gpa.free(i.core);
        gpa.free(i.ranks);
        gpa.free(i.rank_names);
    }
};

pub fn inputs(gpa: Allocator, session: *const Session) Allocator.Error!Inputs {
    const n = session.graph.count();
    var out: Inputs = .{
        .birs = try gpa.alloc(*const Bir, n),
        .names = try gpa.alloc([]const u8, n),
        .core = try gpa.alloc(bool, n),
        .ranks = &.{},
        .rank_names = &.{},
    };
    for (0..n) |i| {
        const f = session.graph.moduleFile(@fromBackingInt(@intCast(i)));
        out.birs[i] = session.artifacts.bir(f);
        out.names[i] = session.store.moduleName(f);
        out.core[i] = session.fileIsCore(f);
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
        .core = ins.core,
        .interner = &session.interner,
    };
}

/// An importer's read of another module's block (§3.6, §8 S3b slice 3):
/// the envelope `Ownership.publish` writes, its names resolved in this
/// session (no session id is in the bytes), its classes built in the
/// importer's tables by `BlockRead.read`. Only an import is read, whose
/// interface the Driver published before this module's check began.
const ImportReader = struct {
    session: *const Session,
    ins: *const Inputs,
    types: *const Types,
    interfaces: []const Interface,
    /// Blocks this run computed itself, by module, read in place of the
    /// interface's: under `--ownership-both` the interface carries v1's
    /// block (#1398).
    blocks: ?[]const ?[]const u8 = null,

    fn imports(r: *ImportReader) Groups.Imports {
        return .{ .ctx = r, .read = read };
    }

    fn read(ctx: *anyopaque, mod: *Groups.Module, m: u32) Groups.Error!?[]Groups.ClassId {
        const r: *ImportReader = @ptrCast(@alignCast(ctx));
        if (m >= r.interfaces.len) return null;
        const bytes = if (r.blocks) |b| (b[m] orelse &.{}) else r.interfaces[m].ownership;
        if (bytes.len == 0 or bytes.len % 4 != 0) return null;
        const gpa = mod.gpa;
        const words = try gpa.alloc(u32, bytes.len / 4);
        defer gpa.free(words);
        @memcpy(std.mem.sliceAsBytes(words), bytes);
        var e: Envelope = .{ .r = r, .mod = mod, .m = m };
        defer e.texts.deinit(gpa);
        const body = (try e.parse(gpa, words)) orelse return null;
        var classes: std.ArrayList(Groups.ClassId) = .empty;
        defer classes.deinit(gpa);
        const remap: BlockRead.Remap = .{ .place = .{ .ctx = &e, .head = Envelope.head, .field = Envelope.field }, .ctx = &e, .decl = Envelope.decl, .inst = Envelope.inst, .own = Envelope.own };
        // A split that meets one of the importer's with another condition is
        // no block it can read: an unknown summary (R-5.7.4), never a guess.
        const got = BlockRead.read(mod.env(), &mod.sums, body, remap, &classes) catch |err| switch (err) {
            error.BlockConflict => null,
            else => |x| return x,
        };
        if (e.oom) return error.OutOfMemory;
        if (got == null or e.failed or classes.items.len * 2 != e.dir.len) return null;
        const bir = r.ins.birs[m];
        const out = try gpa.alloc(Groups.ClassId, bir.decls.len);
        @memset(out, .none);
        for (classes.items, 0..) |c, k| {
            if (e.dir[2 * k + 1] != 1) continue;
            const di = e.declOf(m, e.dir[2 * k]) orelse {
                gpa.free(out);
                return null;
            };
            out[di] = c;
        }
        return out;
    }

    /// The envelope's string table and directory, and the remap over them:
    /// a name this session cannot resolve makes the block unknown.
    const Envelope = struct {
        r: *ImportReader,
        mod: *Groups.Module,
        m: u32,
        texts: std.ArrayList([]const u8) = .empty,
        dir: []const u32 = &.{},
        failed: bool = false,
        oom: bool = false,

        /// The block's words after the string table and the directory, or
        /// null when the envelope is malformed.
        fn parse(e: *Envelope, gpa: Allocator, words: []const u32) Allocator.Error!?[]const u32 {
            var at: usize = 1;
            if (words.len < 1) return null;
            for (0..words[0]) |_| {
                if (at >= words.len) return null;
                const len = words[at];
                const n = (@as(usize, len) + 3) / 4;
                if (words.len - at - 1 < n) return null;
                try e.texts.append(gpa, std.mem.sliceAsBytes(words[at + 1 ..][0..n])[0..len]);
                at += 1 + n;
            }
            if (at >= words.len or (words.len - at - 1) / 2 < words[at]) return null;
            e.dir = words[at + 1 ..][0 .. 2 * @as(usize, words[at])];
            return words[at + 1 + e.dir.len ..];
        }

        fn text(e: *Envelope, s: u32) ?[]const u8 {
            if (s < e.texts.items.len) return e.texts.items[s];
            e.failed = true;
            return null;
        }

        fn symbol(e: *Envelope, t: []const u8) ?InternPool.Symbol {
            return e.r.session.interner.find(t) orelse {
                e.failed = true;
                return null;
            };
        }

        /// `package·module·type` → the type's head (`Types.find`'s search,
        /// with no read noted: the block, not this module's check, names it).
        fn head(ctx: *anyopaque, s: u32) u32 {
            const e: *Envelope = @ptrCast(@alignCast(ctx));
            const t = e.text(s) orelse return 0;
            if (t.len == 0) return @import("Ids.zig").none_int;
            var it = std.mem.splitSequence(u8, t, "·");
            const package = std.meta.stringToEnum(Graph.Package, it.next().?);
            const module = e.symbol(it.next() orelse "");
            const name = e.symbol(it.next() orelse "");
            const types = e.r.types;
            if (package != null and module != null and name != null) if (e.r.session.graph.find(package.?, module.?)) |g| if (g.int() + 1 < types.entry_offsets.len) {
                for (types.by_name[types.entry_offsets[g.int()]..types.entry_offsets[g.int() + 1]]) |id| if (types.entries[id.int()].name == name.?) return id.int();
            };
            e.failed = true;
            return 0;
        }

        fn field(ctx: *anyopaque, s: u32) u32 {
            const e: *Envelope = @ptrCast(@alignCast(ctx));
            const sym = e.symbol(e.text(s) orelse return 0) orelse return 0;
            if (@backingInt(sym) < e.r.ins.ranks.len) return e.r.ins.ranks[@backingInt(sym)];
            e.failed = true;
            return 0;
        }

        /// `Module.name` (the writer's `Strings.decl`) → the importer's
        /// `shared` index; a module name two modules share is unknown.
        fn decl(ctx: *anyopaque, s: u32, ordinal: u32) ?u32 {
            const e: *Envelope = @ptrCast(@alignCast(ctx));
            const t = e.text(s) orelse return null;
            const dot = std.mem.lastIndexOfScalar(u8, t, '.') orelse return null;
            var module: ?u32 = null;
            for (e.r.ins.names, 0..) |n, i| if (std.mem.eql(u8, n, t[0..dot])) {
                if (module != null) return null;
                module = @intCast(i);
            };
            const di = e.declOf(module orelse return null, (e.symbol(t[dot + 1 ..]) orelse return null)) orelse return null;
            if (ordinal != 0) return null;
            return e.mod.sharedOf(.{ module.?, di }) catch {
                e.oom = true;
                return null;
            };
        }

        fn own(ctx: *anyopaque, p: Groups.PlaceId) Groups.Error!?Groups.PlaceId {
            const e: *Envelope = @ptrCast(@alignCast(ctx));
            return e.mod.adapter.ownPlace(p);
        }
        fn inst(ctx: *anyopaque, i: u32) u32 {
            const e: *Envelope = @ptrCast(@alignCast(ctx));
            return e.mod.importInst(e.m, i) catch {
                e.oom = true;
                return 0;
            };
        }

        /// The value declaration of module `m` a directory or `shared` name
        /// names (a string, or a symbol), or null.
        fn declOf(e: *Envelope, m: u32, name: anytype) ?u32 {
            const sym: InternPool.Symbol = if (@TypeOf(name) == u32) e.symbol(e.text(name) orelse return null) orelse return null else name;
            const bir = e.r.ins.birs[m];
            for (bir.decls, 0..) |d, di| if (d.kind.isValue() and bir.symbol(d.name) == sym) return @intCast(di);
            return null;
        }
    };
};

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
    // No check of this session ran v2 (`--ownership-both`): the interfaces
    // hold v1's blocks, so each module is checked after the modules it
    // imports and the blocks it publishes are what an importer reads, as
    // `checkModule` publishes them in the module DAG (#1398).
    const own_blocks = try gpa.alloc(?[]const u8, session.graph.count());
    defer gpa.free(own_blocks);
    @memset(own_blocks, null);
    const done = try gpa.alloc(Done, session.graph.count());
    defer gpa.free(done);
    @memset(done, .{});
    var reader: ImportReader = .{ .session = session, .ins = &ins, .types = &session.checked.types, .interfaces = session.resolution.interfaces, .blocks = own_blocks };
    var run: DumpRun = .{ .gpa = gpa, .arena = arena, .session = session, .ins = &ins, .nc = &nc, .reader = &reader, .mods = &mods, .blocks = own_blocks, .done = done, .totals_only = options.totals_only };
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
        if (try run.module(m)) |one| try reports.appendSlice(gpa, one) else try reports.append(gpa, .{ .module = m, .checked = false });
    }
    try Report.write(w, reports.items, ins.names, .{ .totals_only = options.totals_only });
}

const Done = struct { started: bool = false, reports: ?[]const Report.Module = null };

/// The dump's own run of v2 over a module and, first, the modules it imports.
const DumpRun = struct {
    gpa: Allocator,
    arena: Allocator,
    session: *Session,
    ins: *Inputs,
    nc: *NameCtx,
    reader: *ImportReader,
    mods: *std.ArrayList(Groups.Input),
    blocks: []?[]const u8,
    done: []Done,
    totals_only: bool,

    fn module(r: *DumpRun, m: u32) (Allocator.Error || std.Io.Writer.Error)!?[]const Report.Module {
        if (m >= r.done.len) return null;
        if (r.done[m].started) return r.done[m].reports;
        r.done[m].started = true;
        for (r.session.graph.dependencies(@fromBackingInt(m))) |dep| _ = try r.module(dep.int());
        var mi = moduleInput(r.gpa, r.session, r.ins, .{ .modules = r.session.checked.modules, .types = &r.session.checked.types, .dispatch = r.session.checked.dispatch }, m) orelse return null;
        mi.imports = r.reader.imports();
        try r.mods.append(r.gpa, mi);
        const token = r.session.profile.begin();
        defer r.session.profile.end(0, token, .ownership2_module, @backingInt(r.session.graph.moduleFile(@fromBackingInt(m))), 0);
        const one = try Ownership.run(r.gpa, r.arena, .{ .names = r.nc.names(), .modules = r.mods.items[r.mods.items.len - 1 ..], .publish = true, .format_summaries = !r.totals_only });
        if (one[0].block) |b| r.blocks[m] = b;
        r.done[m].reports = one;
        return one;
    }
};

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
    var mi = moduleInput(gpa, session, ctx.ins, .{ .modules = d.kept, .types = d.types, .dispatch = d.dispatch }, m.int()) orelse return;
    var reader: ImportReader = .{ .session = session, .ins = ctx.ins, .types = d.types, .interfaces = d.interfaces };
    mi.imports = reader.imports();
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
                .comparison => .comparison_changes_value,
                .limit => .ownership_limit,
                else => if (l.approx) .list_may_be_shared else .list_still_used,
            };
            const message = try std.fmt.allocPrint(gpa, "{s} {s} is refused: {s}{s}\n\n{s}", .{
                l.op,
                l.base,
                Facts.causeText(l.cause),
                if (l.detail.len != 0) try std.fmt.allocPrint(arena, ": {s}", .{l.detail}) else "",
                if (l.approx) "This is a limit of the checker, not proof of sharing." else if (l.cause == .comparison) "This is a rule of the language: `==` and `<` call a type's `eq` and `compare`, which only read. Change a copy (`List.copy`)." else "This is sharing the checker can see.",
            });
            try dest.append(gpa, .{ .ownership = true, .code = code, .module = @fromBackingInt(r.module), .region = @fromBackingInt(0), .token = l.token, .message = message });
        }
        for (r.others) |o| if (std.mem.startsWith(u8, o, "limit ")) {
            try dest.append(gpa, .{ .ownership = true, .code = .ownership_limit, .module = @fromBackingInt(r.module), .region = @fromBackingInt(0), .message = try gpa.dupe(u8, o) });
        };
    }
}
