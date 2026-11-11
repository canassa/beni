//! L12: the facade of the ownership checker v2 (`docs/design/ownership-v2.md`
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
const ContractText = @import("ContractText.zig");
const Groups = @import("Groups.zig");
const Message = @import("Message.zig");
const Report = @import("Report.zig");
const Block = @import("Block.zig");
const SummaryText = @import("SummaryText.zig");
const Hoists = @import("Hoists.zig");
const Subtree = @import("Subtree.zig");

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
    below: bool = false, // with the summaries, each one's `belowLine`
    records_lost: bool = false, // `--ownership-records-lost`: each record line is refused, and no list line reads that (§7, point 8; R-8.6)
};

const FieldNames = struct {
    names: Names,
    fn field(ctx: *anyopaque, rank: u32) []const u8 {
        const s: *FieldNames = @ptrCast(@alignCast(ctx));
        return s.names.field(s.names.ctx, rank);
    }
};

/// Check every module of `in` and report each, in `in.modules`' order;
/// everything the reports hold lives in `arena`.
pub fn run(gpa: Allocator, arena: Allocator, in: Input) Allocator.Error![]Report.Module {
    const out = try arena.alloc(Report.Module, in.modules.len);
    for (in.modules, out, 0..) |*mi, *r, at| {
        var lines: std.ArrayList(@import("Facts.zig").Line) = .empty;
        var others: std.ArrayList([]const u8) = .empty;
        // The hoisted reads of the record pass (§2.8), printed before every other line that is no verdict, as v1 prints them.
        var hoist_lines: std.ArrayList([]const u8) = .empty;
        var hoist_rows: std.ArrayList(Hoists.Row) = .empty;
        var limits: u32 = 0;
        var blocks: [2]?[]const u8 = .{ null, null };
        var word_errors: [][3]u32 = &.{};
        // The list pass's summary lines, and how often it refused each `L:C op base`: the record pass says only what it changes.
        var said: std.StringHashMapUnmanaged(u32) = .empty;
        var needed = false;
        // A worded declaration's body is its pins' to check, not this run's.
        var channel: Hoists.Builder = .{ .unchecked = for (mi.bir.decls) |d| {
            if (d.kind == .value and d.body != .none and mi.bir.ownSlotsV2(d).len != 0) break true;
        } else false };
        // Two passes (§2.11.5, R-8.6). The list pass reads an update as a new record: every list line
        // is its line, and no record fact is in it. The record pass reads an update as a write of its
        // base's object: only its record lines are taken, and its limit refuses them, no more.
        for ([_]bool{ false, true }) |records| {
            // No update, no record pattern, and no import whose passes differ: the record pass is the list pass.
            if (records and (!needed or @import("Mutate.zig").on(.record_pass_off))) {
                blocks[1] = blocks[0];
                break;
            }
            var pass = mi.*;
            pass.records = records;
            const mod = try gpa.create(Groups.Module);
            defer gpa.destroy(mod);
            if (!records) Counters.reset();
            try Groups.checkModule(&pass, mod);
            defer mod.deinit();
            const first = !records;
            var belows: std.ArrayList(struct { []const u8, u32 }) = .empty;
            const frame_base: Message.Frame = .{
                .names = in.names,
                .module = mi.module,
                .decl = undefined,
                .places = &mod.places,
                .ctx = mod,
                .decl_of = Groups.Module.declOfCtx,
                .callee_of = Groups.Module.calleeOfCtx,
                .ctor_of = Groups.Module.ctorIndexCtx,
                .is_append = Groups.Module.isListAppend,
            };
            // A worded declaration's class is its words (an asserted row):
            // its body is not checked here (§2.13.6's pins check it).
            if (in.format_summaries and first) for (mi.bir.decls, 0..) |d, di| {
                if (d.kind != .value or d.body == .none or mi.bir.ownSlotsV2(d).len == 0) continue;
                const span = declLines(in.names, mi, d);
                try others.append(arena, try std.fmt.allocPrint(arena, "unchecked {s}: lines {d}-{d} (row)", .{ in.names.declName(mi.module, @intCast(di)), span[0], span[1] }));
            };
            var rlimits: u32 = 0;
            for (mod.results.items) |*dr| {
                const d = mi.bir.decls[dr.decl];
                const name = in.names.declName(mi.module, dr.decl);
                // A declaration v2 does not check (a construct not built yet, a
                // limit) names its lines, so a verdict diff can tell a demand it
                // did not check from one it missed (`bench/ownership-everywhere.mjs`).
                if (in.format_summaries and dr.failure != null) {
                    const span = declLines(in.names, mi, d);
                    try others.append(arena, try std.fmt.allocPrint(arena, "unchecked {s}: lines {d}-{d} ({s}limit)", .{ name, span[0], span[1], if (records) "record-pass " else "" }));
                }
                if (dr.failure) |f| {
                    // The record pass past its limit: no line accepts an update of it, and its limit is a limit as a list's is (§2.8).
                    const which = if (records) " (record pass)" else "";
                    if (records) {
                        rlimits += 1;
                        // Its record writes have no verdict: the module's records keep the spread (§2.8).
                        if (!@import("Mutate.zig").on(.record_limit_clean)) channel.record_refused = true;
                        if (@import("Mutate.zig").on(.record_limit_quiet)) continue;
                    } else limits += 1;
                    try others.append(arena, switch (f) {
                        .exhausted => try std.fmt.allocPrint(arena, "limit {s}: ownership_summary_size{s}", .{ name, which }),
                        .limit => |l| try std.fmt.allocPrint(arena, "limit {s}: {t}{s}", .{ name, l, which }),
                        // The lane past its ceiling (§4.1): a defect, named for its fix.
                        .invariant => |l| try std.fmt.allocPrint(arena, "limit {s}: ownership_accounting_invariant ({t} lane of atom {d}, {t}){s}", .{ name, l.role, l.atom, l.phase, which }),
                    });
                    continue;
                }
                var frame = frame_base;
                frame.decl = d;
                // Its frames' field captures: a row each, unless an earlier write's row has the read (§2.8, the capture rows).
                for (dr.captures) |h| try hoist_rows.append(arena, .{ .key = .{ dr.decl, h.capture, h.outer, h.read }, .text = try Message.hoistLine(frame, arena, h, "capture"), .read = .{ h.read, h.binding, h.capture }, .hoist = h, .written = false });
                for (dr.lines) |l| {
                    const op = if (l.demand.callee_inst != Ids.none_int) try Message.opName(frame, arena, l.demand.callee_inst) else "";
                    var ln = try Message.line(frame, arena, l, op);
                    ln.hoisted = l.hoisted;
                    if (in.records_lost and !first and l.demand.record and !@import("Mutate.zig").on(.records_lost_keeps)) ln = .{ .position = ln.position, .token = ln.token, .op = ln.op, .base = ln.base, .refused = true, .approx = true, .detail = Message.records_lost };
                    const key = try std.fmt.allocPrint(arena, "{d}:{d} {s} {s}", .{ ln.position.line, ln.position.col, ln.op, ln.base });
                    if (first) {
                        if (ln.refused) (try said.getOrPutValue(arena, key, 0)).value_ptr.* += 1;
                        // The list channel is the list pass's: a record line is no list write, and its refusal no list refusal.
                        try channel.add(arena, l.demand.point, l.demand.kind, ln.refused, Hoists.reliesOnCallers(l.outcome.accepted));
                    } else if (!l.demand.record) {
                        // A refusal that only the record pass has is a record's, whatever its demand: it is not lost, and it is no
                        // list line. Each refusal of the list pass stands for one of the same text here, and no more.
                        if (!ln.refused or @import("Mutate.zig").on(.record_refusal_lost)) continue;
                        if (said.getPtr(key)) |n| if (n.* != 0) {
                            n.* -= 1;
                            continue;
                        };
                        if (!@import("Mutate.zig").on(.record_pass_lists)) ln.op = "update";
                    }
                    try lines.append(arena, ln);
                    // An accepted record write's hoisted reads, by the write's instruction (§2.8, the hoist rows).
                    if (!ln.refused) for (l.hoists) |h| try hoist_rows.append(arena, .{ .key = .{ dr.decl, l.demand.point, h.outer, h.read }, .text = try Message.hoistLine(frame, arena, h, "hoist"), .read = .{ h.read, h.binding, h.capture }, .hoist = h, .written = true });
                    // The channel's record half (§2.8): a line of the record pass refuses, or is an accepted record write.
                    if (!first) try channel.record(arena, dr.decl, l.demand.point, ln.refused, l.demand.record);
                }
                if (in.format_summaries) {
                    const a = &dr.account;
                    var line: std.Io.Writer.Allocating = .init(arena);
                    line.writer.print("{s} {s}: source {d}, baseline {d}, growth {d} of {d}, total {d}, continuation {d} of {d}", .{ if (first) "account" else "record-pass account", name, a.source, a.baseline, a.growth, a.allowance, a.total(), a.continuation, a.continuationCap() }) catch return error.OutOfMemory;
                    // Demands' resolve apart: a call's share is the rest (§2.11).
                    line.writer.print(", demands {d}", .{a.demands}) catch return error.OutOfMemory;
                    if (a.hold_listings != 0) line.writer.print(", hold listings {d}", .{a.hold_listings}) catch return error.OutOfMemory;
                    // Its codes' walks and its group's rounds (§2.12).
                    line.writer.print(", walks {d}, rounds {d}", .{ dr.walks, dr.rounds }) catch return error.OutOfMemory;
                    if (dr.defects != 0) line.writer.print(", inference defects {d}", .{dr.defects}) catch return error.OutOfMemory;
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
                    if (first or a.demands != 0) try others.append(arena, line.written());
                }
                if (in.format_summaries and dr.contract != Ids.none_int) {
                    var fn_names: FieldNames = .{ .names = in.names };
                    const from = others.items.len;
                    try SummaryText.lines(&mod.contracts, gpa, arena, dr.contract, name, &mod.slots, &mod.places, .{ .ctx = &fn_names, .field = FieldNames.field }, &others);
                    // The record pass says a contract only where it is not the list pass's: `record-pass summary …`.
                    var keep = from;
                    for (others.items[from..]) |text| {
                        if (first) try said.put(arena, text, 0) else if (!said.contains(text)) {
                            others.items[keep] = try std.fmt.allocPrint(arena, "record-pass {s}", .{text});
                            keep += 1;
                        }
                    }
                    if (records) others.shrinkRetainingCapacity(keep);
                    if (first and in.below and dr.decl < mod.body_code.len and mod.body_code[dr.decl] != Ids.none_int) try belows.append(arena, .{ name, mod.body_code[dr.decl] });
                }
            }
            // An import read as unknown is said, never silent (§3.6): its codes
            // had the pessimistic contract here.
            std.mem.sort(u32, mod.imports_unknown.items, {}, std.sort.asc(u32));
            for (mod.imports_unknown.items) |m| try others.append(arena, try std.fmt.allocPrint(arena, "{s}unknown block {s}: its declarations read the pessimistic contract", .{ if (first) "" else "record-pass ", in.names.module_names[m] }));
            var unpublished: ?[]const u8 = null;
            blocks[@intFromBool(records)] = if ((in.publish or in.format_summaries) and limits == 0 and rlimits == 0) try publish(gpa, arena, in.names, mod, &unpublished) else null;
            if (records) {
                // Its block not written is said too (#1450): an importer's record pass reads the module as unknown.
                if (unpublished) |why| if (in.format_summaries) try others.append(arena, try std.fmt.allocPrint(arena, "record-pass block not published: {s}", .{why}));
                continue;
            }
            needed = mod.record_facts or for (mi.bir.insts.items(.tag)) |t| {
                if (t == .record_update or t == .pat_record) break true;
            } else false;
            // A block not written for a limit is that limit, said (never a silent
            // missing block, #1450): its importers read none of its classes.
            if (unpublished) |why| {
                limits += 1;
                try others.append(arena, try std.fmt.allocPrint(arena, "limit block: {s} (the module's summaries are not published)", .{why}));
            }
            var fn_names: FieldNames = .{ .names = in.names };
            for (belows.items) |b| {
                var bl: std.Io.Writer.Allocating = .init(arena);
                belowLine(mod, gpa, &bl.writer, .{ .ctx = &fn_names, .field = FieldNames.field }, b[0], b[1]) catch |err| switch (err) {
                    error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
                    else => bl.writer.writeAll(" ?") catch return error.OutOfMemory,
                };
                try others.append(arena, bl.written());
            }
            var errs: std.ArrayList(Groups.WordError) = .empty;
            defer errs.deinit(gpa);
            Groups.wordKindErrors(mod, &errs) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            };
            word_errors = try arena.alloc([3]u32, errs.items.len);
            for (errs.items, word_errors) |e, *w| w.* = .{ e.decl, e.slot, @backingInt(e.word) };
            // `-Downership-v2-counters`: the module's container counts and census.
            if (Counters.enabled and in.format_summaries) {
                var text: std.Io.Writer.Allocating = .init(arena);
                Counters.write(&text.writer, mod) catch return error.OutOfMemory;
                try others.append(arena, std.mem.trimEnd(u8, text.written(), "\n"));
            }
        }
        // One block for both passes (`Block.both`): an importer's pass reads its own part.
        const block = try Block.both(arena, blocks[0], blocks[1]);
        // The dump names the block by its size and a hash of its bytes: what
        // the determinism tests compare across job counts (rule 5).
        if (in.format_summaries) if (block) |b| try others.append(arena, try std.fmt.allocPrint(arena, "block: {d} bytes, hash {x:0>16}", .{ b.len, std.hash.Wyhash.hash(0, b) }));
        // The rows' lines, and the rows into the channel before it is finished.
        try Hoists.Row.lines(arena, hoist_rows.items, &hoist_lines, &channel);
        if (in.channels) |c| c[at] = try channel.finish(arena, gpa, limits != 0);
        try hoist_lines.appendSlice(arena, others.items);
        r.* = .{ .module = mi.module, .lines = lines.items, .others = hoist_lines.items, .limits = limits, .block = block, .word_errors = word_errors };
    }
    return out;
}

/// `--ownership-below`: each parameter's slots as `Subtree.belowAll` writes them, with each one's `below` by index
/// (`{0,2}`) or `*` where no step names one; `…` past 512, `?` where a walk stops. Its own account, after every
/// summary and the block (the walks intern slots): a script reads both spellings of a subtree as one (§2.9.1).
fn belowLine(mod: *Groups.Module, gpa: Allocator, w: *std.Io.Writer, names: ContractText.Names, name: []const u8, code: u32) !void {
    try w.print("below {s}:", .{name});
    var account: Ids.Account = .{};
    defer account.deinit(gpa);
    const c = mod.codes.items[code];
    for (mod.code_places.items[c.params.start..][0..c.params.len], 0..) |pl, j| {
        try w.print(" π{d}", .{j + 1});
        if (pl == .none) continue;
        const root = try mod.places.rootPath(gpa, pl);
        if (try @import("BelowSize.zig").moreBelow(&mod.slots, gpa, &account, &mod.places, root, 512)) {
            try w.writeAll(" …");
            continue;
        }
        const all = try gpa.dupe(u32, mod.slots.items(try Subtree.belowAll(&mod.slots, gpa, &account, &mod.places, root)));
        defer gpa.free(all);
        var index: Ids.FixedDict(1) = .{};
        defer index.deinit(gpa);
        for (all, 0..) |x, i| try index.put(gpa, .{x}, @intCast(i));
        for (all) |x| {
            try w.writeAll(" ");
            try ContractText.relText(&mod.slots, &mod.places, names, w, try mod.slots.relOf(gpa, &account, &mod.places, .from(x)));
            const k = mod.places.kind(mod.places.pathPlace(.from(x)));
            if (k == .@"var" or k == .@"opaque") {
                try w.writeAll("*");
                continue;
            }
            for (mod.slots.items(try Subtree.belowAll(&mod.slots, gpa, &account, &mod.places, .from(x))), 0..) |y, n| {
                try w.writeAll(if (n == 0) "{" else ",");
                if (index.get(.{y})) |i| try w.print("{d}", .{i}) else try w.writeAll("?");
            }
            try w.writeAll("}");
        }
    }
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
/// in the bytes): field names and values as `Module.name`, each text once,
/// numbered in the order the writer asks.
const Strings = struct {
    gpa: Allocator,
    arena: Allocator,
    names: Names,
    texts: std.ArrayList([]const u8) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
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

    fn field(ctx: *anyopaque, rank: u32) u32 {
        const s: *Strings = @ptrCast(@alignCast(ctx));
        return s.intern(s.names.field(s.names.ctx, rank));
    }

    fn decl(ctx: *anyopaque, md: [2]u32) u32 {
        const s: *Strings = @ptrCast(@alignCast(ctx));
        const text = std.fmt.allocPrint(s.arena, "{s}.{s}", .{ s.names.module_names[md[0]], s.names.declName(md[0], md[1]) }) catch {
            s.failed = true;
            return 0;
        };
        return s.intern(text);
    }

    fn deinit(s: *Strings) void {
        s.texts.deinit(s.gpa);
        s.index.deinit(s.gpa);
    }
};

/// The module's block (§3.6): the string table first — `[count, (byte
/// length, bytes in words)…]` — then the directory, `[count, (name,
/// applies)…]`, one per public value with a contract: its name and whether
/// an importer may apply it (a body checked within its limits) — then
/// `Block.write`'s words. Bytes in `arena`; null when one could not be
/// written (an owner past its limits).
pub fn publish(gpa: Allocator, arena: Allocator, names: Names, mod: *Groups.Module, why: *?[]const u8) Allocator.Error!?[]const u8 {
    var contracts: std.ArrayList(u32) = .empty;
    defer contracts.deinit(gpa);
    var decls: std.ArrayList(u32) = .empty;
    defer decls.deinit(gpa);
    Groups.charging(mod, &mod.base_account);
    for (mod.in.bir.decls, 0..) |d, di| {
        if (!d.is_pub or !d.kind.isValue()) continue;
        const c = (Groups.declaredContract(mod, @intCast(di)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (err == error.ProbeLength) _ = mod.base_account.probeFailed();
                why.* = try limitText(arena, mod);
                return null;
            },
        }) orelse continue;
        try contracts.append(gpa, c);
        try decls.append(gpa, @intCast(di));
    }
    var s: Strings = .{ .gpa = gpa, .arena = arena, .names = names };
    defer s.deinit();
    var dir: std.ArrayList(u32) = .empty;
    try dir.append(arena, @intCast(decls.items.len));
    for (decls.items) |di| try dir.appendSlice(arena, &.{ s.intern(names.declName(mod.in.module, di)), @intFromBool(mod.walkedContract(di) != null) });
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    try Block.write(gpa, &mod.contracts, &mod.slots, &mod.places, contracts.items, .{ .ctx = &s, .field = Strings.field, .decl = Strings.decl }, &words);
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
