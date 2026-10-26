//! L13: the facade of the ownership checker v2 (`docs/design/ownership-v2.md`
//! §5): check the modules it is handed (`Groups`), and say what each found
//! as report lines (`Message`, `Report`). The caller — `Enforce`'s hook, the
//! dump — prepares each module's inputs.
//!
//! Obligations kept here: O11 (an owner the account stopped publishes no
//! class and is reported as a limit).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Summary = @import("Summary.zig");
const Groups = @import("Groups.zig");
const Walk = @import("Walk.zig");
const Message = @import("Message.zig");
const Report = @import("Report.zig");
const Block = @import("Block.zig");

pub const Names = Message.Names;
pub const ModuleReport = Report.Module;

pub const Input = struct {
    names: Names,
    modules: []const Groups.Input,
    /// Each declaration's `summary` line, which only the dump prints.
    format_summaries: bool = false,
    /// Write each module's block (`publish`) into its report.
    publish: bool = false,
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
    for (in.modules, out) |*mi, *r| {
        const mod = try gpa.create(Groups.Module);
        defer gpa.destroy(mod);
        try Groups.checkModule(mi, mod);
        defer mod.deinit();
        var lines: std.ArrayList(@import("Facts.zig").Line) = .empty;
        var others: std.ArrayList([]const u8) = .empty;
        var limits: u32 = 0;
        const frame_base: Message.Frame = .{
            .names = in.names,
            .module = mi.module,
            .decl = undefined,
            .places = &mod.places,
            .cells = &mod.cells,
            .shared = mod.shared_of.items,
            .ctx = mod,
            .decl_of = Groups.Module.declOfCtx,
        };
        for (mod.results.items) |*dr| {
            const d = mi.bir.decls[dr.decl];
            const name = in.names.declName(mi.module, dr.decl);
            if (dr.failure) |f| {
                limits += 1;
                try others.append(arena, try std.fmt.allocPrint(arena, "limit {s}: {s}", .{ name, switch (f) {
                    .exhausted => "ownership_summary_size",
                    .limit => |l| @tagName(l),
                    .invariant => "ownership_accounting_invariant",
                } }));
                continue;
            }
            var frame = frame_base;
            frame.decl = d;
            for (dr.lines) |l| {
                const op = if (l.demand.callee_inst != Ids.none_int) (try Message.refName(frame, arena, l.demand.callee_inst)) orelse "call" else "";
                try lines.append(arena, try Message.line(frame, arena, l, op));
            }
            if (in.format_summaries) {
                const a = &dr.account;
                var line: std.Io.Writer.Allocating = .init(arena);
                line.writer.print("account {s}: source {d}, baseline {d}, growth {d} of {d}, total {d}", .{ name, a.source, a.baseline, a.growth, a.allowance, a.total() }) catch return error.OutOfMemory;
                // §4.4's category counts: the growth records by what they
                // were reserved for, the nonzero ones in category order.
                for (a.growth_by, 0..) |n, c| if (n != 0) line.writer.print(", {t} {d}", .{ @as(Ids.Category, @fromBackingInt(@intCast(c))), n }) catch return error.OutOfMemory;
                try others.append(arena, line.written());
            }
            if (in.format_summaries and dr.class != .none) {
                var sn: SummaryNames = .{ .names = in.names, .module = mi.module, .shared = mod.shared_of.items };
                var buf: std.Io.Writer.Allocating = .init(arena);
                mod.account = &dr.account;
                const sum_names: Summary.Names = .{ .ctx = &sn, .field = SummaryNames.field, .ctor = SummaryNames.ctor, .decl = SummaryNames.decl };
                mod.sums.print(mod.env(), arena, &buf.writer, dr.class, name, sum_names) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                };
                mod.account = &mod.base_account;
                const text = buf.written();
                if (dr.unbuilt != Ids.none_int) {
                    try others.append(arena, try std.fmt.allocPrint(arena, "summary {s}: not built: {t} (pessimistic)", .{ name, mi.bir.instTag(@fromBackingInt(dr.unbuilt)) }));
                } else if (text.len != 0) try others.append(arena, text);
            }
        }
        const block: ?[]const u8 = if ((in.publish or in.format_summaries) and limits == 0) try publish(gpa, arena, in.names, mod) else null;
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
        r.* = .{ .module = mi.module, .lines = lines.items, .others = others.items, .limits = limits, .block = block, .word_errors = word_errors };
    }
    return out;
}

comptime {
    _ = Walk;
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
        return s.intern(s.names.type_qualified(s.names.ctx, h));
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
/// bytes in words)…]` — then `Block.write`'s words. Bytes in `arena`; null
/// when a class could not be written (an owner past its limits).
pub fn publish(gpa: Allocator, arena: Allocator, names: Names, mod: *Groups.Module) Allocator.Error!?[]const u8 {
    var classes: std.ArrayList(Ids.ClassId) = .empty;
    defer classes.deinit(gpa);
    mod.account = &mod.base_account;
    for (mod.in.bir.decls, 0..) |d, di| {
        if (!d.is_pub or !d.kind.isValue()) continue;
        const c = (Groups.declaredClass(mod, @intCast(di)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        }) orelse continue;
        try classes.append(gpa, c);
    }
    var s: Strings = .{ .gpa = gpa, .arena = arena, .names = names, .shared = mod.shared_of.items };
    defer s.deinit();
    const block_names: Block.Names = .{ .place = .{ .ctx = &s, .head = Strings.head, .field = Strings.field }, .ctx = &s, .decl = Strings.decl };
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    Block.write(mod.env(), &mod.sums, classes.items, block_names, &words) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
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
    try out.appendSlice(arena, words.items);
    return std.mem.sliceAsBytes(out.items);
}
