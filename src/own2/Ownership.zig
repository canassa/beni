//! L16: the facade of the ownership checker v2 (`docs/design/ownership-v2.md`
//! §5): check the modules it is handed (`Groups`), and say what each found
//! as report lines (`Message`, `Report`). The caller — `Enforce`'s hook, the
//! dump — prepares each module's inputs.
//!
//! Obligations kept here: O11 (an owner the account stopped publishes no
//! class and is reported as a limit).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Counters = @import("Counters.zig");
const Summary = @import("Summary.zig");
const Groups = @import("Groups.zig");
const Walk = @import("Walk.zig");
const Message = @import("Message.zig");
const Report = @import("Report.zig");
const Block = @import("Block.zig");
const Hoists = @import("Hoists.zig");

pub const Names = Message.Names;
pub const ModuleReport = Report.Module;

pub const Input = struct {
    names: Names,
    modules: []const Groups.Input,
    /// Each declaration's `summary` line, which only the dump prints.
    format_summaries: bool = false,
    /// Write each module's block (`publish`) into its report.
    publish: bool = false,
    /// Per module, its lowering channel (`Hoists`, §3.7), in `gpa`.
    channels: ?[]Hoists.Table = null,
};

const SummaryNames = struct {
    names: Names,
    module: u32,
    /// A `shared` cell's index → `(module, declaration)`.
    shared: []const [2]u32,

    fn field(ctx: *anyopaque, rank: u32) []const u8 {
        const s: *SummaryNames = @ptrCast(@alignCast(ctx));
        return s.names.field(s.names.ctx, rank);
    }
    fn ctor(ctx: *anyopaque, head: u32, ordinal: u32) []const u8 {
        const s: *SummaryNames = @ptrCast(@alignCast(ctx));
        return s.names.ctor(s.names.ctx, head, ordinal);
    }
    fn decl(ctx: *anyopaque, index: u32, j: u32) []const u8 {
        _ = j;
        const s: *SummaryNames = @ptrCast(@alignCast(ctx));
        if (index >= s.shared.len) return "?";
        const md = s.shared[index];
        return s.names.declName(md[0], md[1]);
    }
};

/// Check every module of `in` and report each, in `in.modules`' order;
/// everything the reports hold lives in `arena`.
pub fn run(gpa: Allocator, arena: Allocator, in: Input) Allocator.Error![]Report.Module {
    const out = try arena.alloc(Report.Module, in.modules.len);
    for (in.modules, out, 0..) |*mi, *r, at| {
        const mod = try gpa.create(Groups.Module);
        defer gpa.destroy(mod);
        Counters.reset();
        try Groups.checkModule(mi, mod, in.format_summaries);
        defer mod.deinit();
        var lines: std.ArrayList(@import("Facts.zig").Line) = .empty;
        var others: std.ArrayList([]const u8) = .empty;
        var limits: u32 = 0;
        // A worded declaration's body is its pins' to check, not this run's.
        var channel: Hoists.Builder = .{ .unchecked = for (mi.bir.decls) |d| {
            if (d.kind == .value and d.body != .none and mi.bir.ownSlotsV2(d).len != 0) break true;
        } else false };
        const frame_base: Message.Frame = .{
            .names = in.names,
            .module = mi.module,
            .decl = undefined,
            .places = &mod.places,
            .cells = &mod.cells,
            .shared = mod.shared_of.items,
            .ctx = mod,
            .decl_of = Groups.Module.declOfCtx,
            .callee_of = Groups.Module.calleeOfCtx,
            .ctor_of = Groups.Module.ctorIndexCtx,
            .is_append = Groups.Module.isListAppend,
        };
        // A worded declaration's class is its words (an asserted row):
        // its body is not checked here (§2.13.6's pins check it).
        if (in.format_summaries) for (mi.bir.decls, 0..) |d, di| {
            if (d.kind != .value or d.body == .none or mi.bir.ownSlotsV2(d).len == 0) continue;
            const span = declLines(in.names, mi, d);
            try others.append(arena, try std.fmt.allocPrint(arena, "unchecked {s}: lines {d}-{d} (row)", .{ in.names.declName(mi.module, @intCast(di)), span[0], span[1] }));
        };
        for (mod.results.items) |*dr| {
            const d = mi.bir.decls[dr.decl];
            const name = in.names.declName(mi.module, dr.decl);
            // A declaration v2 does not check (a construct not built yet, a
            // limit) names its lines, so a verdict diff can tell a demand it
            // did not check from one it missed (`bench/ownership-everywhere.mjs`).
            if (in.format_summaries and (dr.failure != null or dr.unbuilt != Ids.none_int)) {
                const span = declLines(in.names, mi, d);
                const why = if (dr.failure != null) "limit" else if (dr.polymorphic) "not built: polymorphic recursion" else try std.fmt.allocPrint(arena, "not built: {t}", .{mi.bir.instTag(@fromBackingInt(dr.unbuilt))});
                try others.append(arena, try std.fmt.allocPrint(arena, "unchecked {s}: lines {d}-{d} ({s})", .{ name, span[0], span[1], why }));
            }
            if (dr.failure) |f| {
                limits += 1;
                try others.append(arena, switch (f) {
                    .exhausted => try std.fmt.allocPrint(arena, "limit {s}: ownership_summary_size", .{name}),
                    .limit => |l| try std.fmt.allocPrint(arena, "limit {s}: {t}", .{ name, l }),
                    // The lane past its ceiling (§4.1): a defect, named for its fix.
                    .invariant => |l| try std.fmt.allocPrint(arena, "limit {s}: ownership_accounting_invariant ({t} lane of atom {d}, {t})", .{ name, l.role, l.atom, l.phase }),
                });
                continue;
            }
            if (dr.unbuilt != Ids.none_int) channel.unchecked = true;
            var frame = frame_base;
            frame.decl = d;
            for (dr.lines) |l| {
                try channel.add(arena, l.demand.point, l.demand.kind, l.outcome.verdict == .refused, Hoists.reliesOnCallers(l.outcome.accepted));
                const op = if (l.demand.callee_inst != Ids.none_int) (try Message.calleeName(frame, arena, l.demand.callee_inst)) orelse "call" else "";
                try lines.append(arena, try Message.line(frame, arena, l, op));
            }
            if (in.format_summaries) {
                const a = &dr.account;
                var line: std.Io.Writer.Allocating = .init(arena);
                line.writer.print("account {s}: source {d}, baseline {d}, growth {d} of {d}, total {d}, continuation {d} of {d}", .{ name, a.source, a.baseline, a.growth, a.allowance, a.total(), a.continuation, a.continuationCap() }) catch return error.OutOfMemory;
                // Demands' resolve apart: a call's share is the rest (§2.11).
                line.writer.print(", demands {d}", .{a.demands}) catch return error.OutOfMemory;
                if (a.hold_listings != 0) line.writer.print(", hold listings {d}", .{a.hold_listings}) catch return error.OutOfMemory;
                // A recursive group member's walks (§8 S3b slice 4, *Charging*).
                if (dr.walks != 0) line.writer.print(", walks {d}, inference {d}, deliveries {d}", .{ dr.walks, dr.inference, dr.deliveries }) catch return error.OutOfMemory;
                // §4.4's category counts: the growth records by what they
                // were reserved for, the nonzero ones in category order.
                for (a.growth_by, 0..) |n, c| if (n != 0) line.writer.print(", {t} {d}", .{ @as(Ids.Category, @fromBackingInt(@intCast(c))), n }) catch return error.OutOfMemory;
                // The lanes in use by role (§4.1): how many source atoms each kernel
                // used; a path step's own lane (`Lane.step`, #1225) counts apart.
                var roles: [@typeInfo(Ids.Role).@"enum".field_names.len]u32 = @splat(0);
                var steps: u32 = 0;
                for (0..a.lanes.count()) |li| {
                    if (a.lanes.keys.items[li * 4 + 3] != 0) {
                        steps += 1;
                        continue;
                    }
                    roles[a.lanes.keys.items[li * 4 + 1]] += 1;
                }
                for (roles, 0..) |n, ri| if (n != 0) line.writer.print(", {t} lanes {d}", .{ @as(Ids.Role, @fromBackingInt(@intCast(ri))), n }) catch return error.OutOfMemory;
                if (steps != 0) line.writer.print(", step lanes {d}", .{steps}) catch return error.OutOfMemory;
                try others.append(arena, line.written());
            }
            if (in.format_summaries) if (dr.contract) |c| try others.append(arena, try std.fmt.allocPrint(arena, "contract {s}: stage {d}, rounds {d}, slots {d}, slot cells {d}, origins {d}, unknown {d}, alpha {d}, port nodes {d}, tokens {d}, token ops {d}, token rounds {d}, validation ops {d}, mults {x}, fresh dup {}, validated {}, preserved {}, v2 leq {}, v2 leq uses {}, certified {}, walk2 growth {d}, walk2 total {d}{s}{s}", .{ name, c.stage, c.rounds, c.slots, c.slot_cells, c.origins, c.unknown_origins, c.alpha_visits, c.port_records, c.tokens, c.token_ops, c.token_rounds, c.validate_ops, c.mults, c.fresh_dup, c.validated, c.preserved, c.v2_leq, c.v2_leq_uses, c.certified, c.growth_at_walk2, c.total_at_walk2, if (c.reason.len != 0) ", reason " else "", c.reason }));
            // The crossing's counts (§2.11 *κ across a call*), once per module:
            // the reads that crossed, those redone at `C` and `base_epoch`'s
            // moves (the counted tests read them).
            if (in.format_summaries and dr == &mod.results.items[0]) try others.append(arena, try std.fmt.allocPrint(arena, "crossing: reads {d}, redone {d}, base moves {d}", .{ mod.conds.crossed_reads, mod.conds.crossed_redos, mod.shapes.base_epoch }));
            if (in.format_summaries and dr.class != .none) {
                var sn: SummaryNames = .{ .names = in.names, .module = mi.module, .shared = mod.shared_of.items };
                var buf: std.Io.Writer.Allocating = .init(arena);
                mod.account = &dr.account;
                const sum_names: Summary.Names = .{ .ctx = &sn, .field = SummaryNames.field, .ctor = SummaryNames.ctor, .decl = SummaryNames.decl };
                // The print reads the class on the declaration's account, so it
                // can pass the allowance the walk stayed under: a summary that
                // is not printed says why, never goes missing (#1182).
                var not_printed: ?[]const u8 = null;
                mod.sums.print(mod.env(), arena, &buf.writer, dr.class, name, sum_names) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => not_printed = if (dr.account.failed) |f| switch (f) {
                        .exhausted => "ownership_summary_size",
                        .limit => |l| try std.fmt.allocPrint(arena, "{t}", .{l}),
                        .invariant => |l| try std.fmt.allocPrint(arena, "ownership_accounting_invariant ({t} lane of atom {d}, {t})", .{ l.role, l.atom, l.phase }),
                    } else @errorName(err),
                };
                mod.account = &mod.base_account;
                const text = buf.written();
                if (not_printed) |why| {
                    try others.append(arena, try std.fmt.allocPrint(arena, "summary {s}: not printed: {s}", .{ name, why }));
                } else if (dr.unbuilt != Ids.none_int) {
                    try others.append(arena, try std.fmt.allocPrint(arena, "summary {s}: not built: {t} (pessimistic)", .{ name, mi.bir.instTag(@fromBackingInt(dr.unbuilt)) }));
                } else if (text.len != 0) try others.append(arena, text);
            }
        }
        var unpublished: ?[]const u8 = null;
        const block: ?[]const u8 = if ((in.publish or in.format_summaries) and limits == 0) try publish(gpa, arena, in.names, mod, &unpublished) else null;
        // A block not written for a limit is that limit, said (never a silent
        // missing block, #1450): its importers read none of its classes.
        if (unpublished) |why| {
            limits += 1;
            try others.append(arena, try std.fmt.allocPrint(arena, "limit block: {s} (the module's summaries are not published)", .{why}));
        }
        // The dump names the block by its size and a hash of its bytes: what
        // the determinism tests compare across job counts (rule 5).
        if (in.format_summaries) if (block) |b| try others.append(arena, try std.fmt.allocPrint(arena, "block: {d} bytes, hash {x:0>16}", .{ b.len, std.hash.Wyhash.hash(0, b) }));
        var errs: std.ArrayList(Groups.WordError) = .empty;
        defer errs.deinit(gpa);
        Groups.wordKindErrors(mod, &errs) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {},
        };
        const word_errors = try arena.alloc([3]u32, errs.items.len);
        for (errs.items, word_errors) |e, *w| w.* = .{ e.decl, e.slot, @backingInt(e.word) };
        // `-Downership-v2-counters`: the module's container counts and census.
        if (Counters.enabled and in.format_summaries) {
            var text: std.Io.Writer.Allocating = .init(arena);
            Counters.write(&text.writer, mod) catch return error.OutOfMemory;
            try others.append(arena, std.mem.trimEnd(u8, text.written(), "\n"));
        }
        if (in.channels) |c| c[at] = try channel.finish(arena, gpa, limits != 0);
        r.* = .{ .module = mi.module, .lines = lines.items, .others = others.items, .limits = limits, .block = block, .word_errors = word_errors };
    }
    return out;
}

comptime {
    _ = Walk;
}

/// The first and last source lines of declaration `d`: its name and every
/// instruction's main token.
fn declLines(names: Message.Names, mi: *const Groups.Input, d: @import("../bir/Bir.zig").Decl) [2]u32 {
    var lo = names.position(names.ctx, mi.module, d.name_token).line;
    var hi = lo;
    const tokens = mi.bir.insts.items(.main_token);
    var i = d.inst_start.int();
    while (i < d.inst_end.int()) : (i += 1) {
        const line = names.position(names.ctx, mi.module, tokens[i]).line;
        lo = @min(lo, line);
        hi = @max(hi, line);
    }
    return .{ lo, hi };
}
/// The string table a published block's names index (§3.6: no session id
/// in the bytes): heads as `package·module·type`, field names, values as
/// `Module.name`, each text once, numbered in the order the writer asks.
const Strings = struct {
    gpa: Allocator,
    arena: Allocator,
    names: Names,
    texts: std.ArrayList([]const u8) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    shared: []const [2]u32,
    failed: bool = false,

    fn intern(s: *Strings, text: []const u8) u32 {
        const got = s.index.getOrPut(s.gpa, text) catch {
            s.failed = true;
            return 0;
        };
        if (!got.found_existing) {
            got.value_ptr.* = @intCast(s.texts.items.len);
            s.texts.append(s.gpa, text) catch {
                s.failed = true;
            };
        }
        return got.value_ptr.*;
    }

    fn head(ctx: *anyopaque, h: u32) u32 {
        const s: *Strings = @ptrCast(@alignCast(ctx));
        // No type's head (`⊤`'s) is the empty name.
        return s.intern(if (h == Ids.none_int) "" else s.names.type_qualified(s.names.ctx, h));
    }

    fn field(ctx: *anyopaque, rank: u32) u32 {
        const s: *Strings = @ptrCast(@alignCast(ctx));
        return s.intern(s.names.field(s.names.ctx, rank));
    }

    fn decl(ctx: *anyopaque, index: u32) [2]u32 {
        const s: *Strings = @ptrCast(@alignCast(ctx));
        const md = s.shared[index];
        const text = std.fmt.allocPrint(s.arena, "{s}.{s}", .{ s.names.module_names[md[0]], s.names.declName(md[0], md[1]) }) catch {
            s.failed = true;
            return .{ 0, 0 };
        };
        return .{ s.intern(text), 0 };
    }

    fn deinit(s: *Strings) void {
        s.texts.deinit(s.gpa);
        s.index.deinit(s.gpa);
    }
};

/// The module's block (§3.6, §8 S3a): every public value's class in
/// declaration order, the string table first — `[count, (byte length,
/// bytes in words)…]` — then the directory, `[count, (name, applies)…]`,
/// one per class: its declaration's name (a string) and whether an importer
/// may apply it, which a walk past a limit or left unbuilt may not (§2.11,
/// S3b slice 3) — then `Block.write`'s words. Bytes in `arena`; null when a
/// class could not be written (an owner past its limits).
pub fn publish(gpa: Allocator, arena: Allocator, names: Names, mod: *Groups.Module, why: *?[]const u8) Allocator.Error!?[]const u8 {
    var classes: std.ArrayList(Ids.ClassId) = .empty;
    defer classes.deinit(gpa);
    var decls: std.ArrayList(u32) = .empty;
    defer decls.deinit(gpa);
    mod.account = &mod.base_account;
    for (mod.in.bir.decls, 0..) |d, di| {
        if (!d.is_pub or !d.kind.isValue()) continue;
        const c = (Groups.declaredClass(mod, @intCast(di)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                why.* = try limitText(arena, mod);
                return null;
            },
        }) orelse continue;
        try classes.append(gpa, c);
        try decls.append(gpa, @intCast(di));
    }
    var s: Strings = .{ .gpa = gpa, .arena = arena, .names = names, .shared = mod.shared_of.items };
    defer s.deinit();
    var dir: std.ArrayList(u32) = .empty;
    try dir.append(arena, @intCast(decls.items.len));
    for (decls.items) |di| try dir.appendSlice(arena, &.{ s.intern(names.declName(mod.in.module, di)), @intFromBool(mod.walkedClass(di) != null) });
    const block_names: Block.Names = .{ .place = .{ .ctx = &s, .head = Strings.head, .field = Strings.field }, .ctx = &s, .decl = Strings.decl };
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    Block.write(mod.env(), &mod.sums, classes.items, block_names, &words) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            why.* = try limitText(arena, mod);
            return null;
        },
    };
    if (s.failed) return error.OutOfMemory;
    var out: std.ArrayList(u32) = .empty;
    try out.append(arena, @intCast(s.texts.items.len));
    for (s.texts.items) |t| {
        try out.append(arena, @intCast(t.len));
        const at = out.items.len;
        try out.appendNTimes(arena, 0, (t.len + 3) / 4);
        @memcpy(std.mem.sliceAsBytes(out.items[at..])[0..t.len], t);
    }
    try out.appendSlice(arena, dir.items);
    try out.appendSlice(arena, words.items);
    return std.mem.sliceAsBytes(out.items);
}

/// Why the module's block was not written: the limit its account met.
fn limitText(arena: Allocator, mod: *Groups.Module) Allocator.Error![]const u8 {
    const f = mod.base_account.failed orelse return "ownership_summary_size";
    return switch (f) {
        .exhausted => "ownership_summary_size",
        .limit => |l| try std.fmt.allocPrint(arena, "{t}", .{l}),
        .invariant => |l| try std.fmt.allocPrint(arena, "ownership_accounting_invariant ({t} lane of atom {d}, {t})", .{ l.role, l.atom, l.phase }),
    };
}
