//! Ownership's module-local channel to lowering (§31.10). Rows contain only
//! BIR identities; neither ownership paths nor session interner ids escape.
const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Allocator = std.mem.Allocator;
pub const none = std.math.maxInt(u32);
pub const format_version: u32 = 1;
const magic = "BENIHOI\x00";

pub const Demand = struct {
    decl: u32,
    inst: u32,
    fields_start: u32,
    fields_len: u32,
};

pub const Step = struct {
    /// 0: a field (offset into `names`); 1: a tuple slot.
    kind: u32,
    arg: u32,
};

pub const Read = struct {
    decl: u32,
    /// The accepted write, or `none` for an eager capture alone.
    demand: u32,
    /// The field-access instruction, or the scrutinee for a pattern read.
    inst: u32,
    /// Declaration-local holder and, for a record pattern, its binding.
    holder: u32,
    binding: u32 = none,
    path_start: u32,
    path_len: u32,
    /// Prefix through the written field; full path for an eager capture.
    prefix_len: u32,
    placement: u32,
    /// 0: before the instruction; 1: after its operands, before its stores.
    phase: u32,
    /// Closure creation, or `none` for a direct read.
    capture: u32 = none,
};

pub const Table = struct {
    /// Report facts alone never authorise mutation. The module must have
    /// been checked under enforcement and all record demands accepted.
    clean: bool = false,
    demands: []const Demand = &.{},
    reads: []const Read = &.{},
    fields: []const u32 = &.{},
    paths: []const Step = &.{},
    names: []const u8 = &.{},

    pub const empty: Table = .{};

    pub fn deinit(t: *Table, gpa: Allocator) void {
        gpa.free(t.demands);
        gpa.free(t.reads);
        gpa.free(t.fields);
        gpa.free(t.paths);
        gpa.free(t.names);
        t.* = .empty;
    }

    pub fn clone(t: Table, gpa: Allocator) Allocator.Error!Table {
        var out: Table = .{ .clean = t.clean };
        errdefer out.deinit(gpa);
        out.demands = try gpa.dupe(Demand, t.demands);
        out.reads = try gpa.dupe(Read, t.reads);
        out.fields = try gpa.dupe(u32, t.fields);
        out.paths = try gpa.dupe(Step, t.paths);
        out.names = try gpa.dupe(u8, t.names);
        return out;
    }

    fn accepted(t: Table, inst: u32) ?Demand {
        var lo: usize = 0;
        var hi = t.demands.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const d = t.demands[mid];
            if (d.inst < inst) lo = mid + 1 else hi = mid;
        }
        return if (lo < t.demands.len and t.demands[lo].inst == inst) t.demands[lo] else null;
    }

    pub fn name(t: Table, offset: u32) []const u8 {
        return std.mem.sliceTo(t.names[offset..], 0);
    }

    fn hasName(t: Table, offset: u32) bool {
        return offset < t.names.len and (offset == 0 or t.names[offset - 1] == 0) and
            t.names[offset] != 0 and std.mem.indexOfScalar(u8, t.names[offset..], 0) != null;
    }

    pub fn verifyAgainstBir(t: Table, bir: *const Bir, pool: *const InternPool.Global, dispatch: *const Dispatch) bool {
        for (t.fields) |f| if (!t.hasName(f)) return false;
        for (t.paths) |p| if (p.kind == 0 and !t.hasName(p.arg)) return false;
        for (t.demands) |d| {
            if (!inDecl(bir, d.decl, d.inst)) return false;
            switch (bir.instTag(@fromBackingInt(d.inst))) {
                .record_update, .call, .method_call, .type_dispatch => {},
                // Validation precedes Nullary.cached's replay: a source dot
                // is a call only when the cached dispatch says it is.
                .field_access => {
                    const site = dispatch.siteOf(@fromBackingInt(d.inst)) orelse return false;
                    if (site.callee == .none) return false;
                },
                else => return false,
            }
        }
        for (t.reads) |r| {
            if (!inDecl(bir, r.decl, r.inst) or !inDecl(bir, r.decl, r.placement)) return false;
            const d = bir.decls[r.decl];
            if (r.holder >= d.locals_end - d.locals_start) return false;
            if (r.binding != none and r.binding >= d.locals_end - d.locals_start) return false;
            if (r.capture != none and !inDecl(bir, r.decl, r.capture)) return false;
            const path = t.paths[r.path_start..][0..r.path_len];
            var index: Bir.Inst.Index = @fromBackingInt(r.inst);
            var end = path.len;
            if (r.binding != none) {
                if (end == 0) return false;
                const n = bir.locals[d.locals_start + r.binding].name.unwrap() orelse return false;
                if (path[end - 1].kind != 0 or !std.mem.eql(u8, t.name(path[end - 1].arg), pool.slice(bir.symbol(@fromBackingInt(n))))) return false;
                end -= 1;
            }
            while (end > 0) {
                end -= 1;
                const data = bir.instData(index);
                const tag = bir.instTag(index);
                if (tag == .field_access) {
                    if (path[end].kind != 0 or !std.mem.eql(u8, t.name(path[end].arg), pool.slice(bir.symbol(@fromBackingInt(data.rhs))))) return false;
                } else if (tag == .tuple_index) {
                    if (path[end].kind != 1 or path[end].arg != data.rhs) return false;
                } else return false;
                if (!inDecl(bir, r.decl, data.lhs)) return false;
                index = @fromBackingInt(data.lhs);
            }
            if (bir.instTag(index) != .local or bir.instData(index).lhs != r.holder) return false;
            if (r.phase == 1 and (r.placement != r.demand or bir.instTag(@fromBackingInt(r.demand)) != .record_update)) return false;
        }
        return true;
    }

    fn inDecl(bir: *const Bir, decl: u32, inst: u32) bool {
        if (decl >= bir.decls.len) return false;
        const d = bir.decls[decl];
        return inst >= d.inst_start.int() and inst < d.inst_end.int();
    }

    /// The single guard an in-place record lowering must call. A missing
    /// table, an unchecked module or a nonaccepted write is a compiler bug.
    pub fn assertAccepted(t: Table, inst: Bir.Inst.Index) void {
        if (!std.debug.runtime_safety) return;
        std.debug.assert(t.clean and t.accepted(inst.int()) != null);
    }
};

pub const Builder = struct {
    demands: std.ArrayList(Demand) = .empty,
    reads: std.ArrayList(Read) = .empty,
    fields: std.ArrayList(u32) = .empty,
    paths: std.ArrayList(Step) = .empty,
    names: std.ArrayList(u8) = .empty,

    pub fn table(b: *const Builder) Table {
        std.mem.sort(Demand, b.demands.items, {}, struct {
            fn less(_: void, x: Demand, y: Demand) bool {
                if (x.inst != y.inst) return x.inst < y.inst;
                return x.fields_start < y.fields_start;
            }
        }.less);
        return .{ .demands = b.demands.items, .reads = b.reads.items, .fields = b.fields.items, .paths = b.paths.items, .names = b.names.items };
    }

    pub fn append(b: *Builder, a: Allocator, t: Table) Allocator.Error!void {
        const f: u32 = @intCast(b.fields.items.len);
        const p: u32 = @intCast(b.paths.items.len);
        const n: u32 = @intCast(b.names.items.len);
        for (t.demands) |d| {
            var row = d;
            row.fields_start += f;
            try b.demands.append(a, row);
        }
        for (t.reads) |r| {
            var row = r;
            row.path_start += p;
            try b.reads.append(a, row);
        }
        for (t.fields) |field| try b.fields.append(a, field + n);
        for (t.paths) |step| try b.paths.append(a, .{ .kind = step.kind, .arg = if (step.kind == 0) step.arg + n else step.arg });
        try b.names.appendSlice(a, t.names);
    }
};

/// Header: magic(8), version, clean, and five u32 counts (demands, reads,
/// fields, paths, name bytes). Then 4-word demands, 11-word reads, fields,
/// 2-word path steps, and the NUL-terminated name blob, in that order.
/// A little-endian section with four counted fixed-width columns. Read
/// checks every range before allocating. Module/BIR checks happen at install.
pub fn write(gpa: Allocator, t: Table) Allocator.Error![]u8 {
    const words = 9 + t.demands.len * 4 + t.reads.len * 11 + t.fields.len + t.paths.len * 2;
    const out = try gpa.alloc(u8, words * 4 + t.names.len);
    @memcpy(out[0..8], magic);
    put(out, 2, format_version);
    put(out, 3, @intFromBool(t.clean));
    put(out, 4, @intCast(t.demands.len));
    put(out, 5, @intCast(t.reads.len));
    put(out, 6, @intCast(t.fields.len));
    put(out, 7, @intCast(t.paths.len));
    put(out, 8, @intCast(t.names.len));
    var at: usize = 9;
    inline for (.{ t.demands, t.reads }) |rows| for (rows) |row| {
        inline for (@typeInfo(@TypeOf(row)).@"struct".field_names) |f| {
            put(out, at, @field(row, f));
            at += 1;
        }
    };
    for (t.fields) |f| {
        put(out, at, f);
        at += 1;
    }
    for (t.paths) |p| {
        put(out, at, p.kind);
        put(out, at + 1, p.arg);
        at += 2;
    }
    @memcpy(out[at * 4 ..], t.names);
    return out;
}

pub fn read(gpa: Allocator, bytes: []const u8) (Allocator.Error || error{BadHoists})!Table {
    if (bytes.len == 0) return .empty;
    if (bytes.len < 36 or !std.mem.eql(u8, bytes[0..8], magic) or get(bytes, 2) != format_version or get(bytes, 3) > 1) return error.BadHoists;
    const nd = get(bytes, 4);
    const nr = get(bytes, 5);
    const nf = get(bytes, 6);
    const np = get(bytes, 7);
    const nn = get(bytes, 8);
    const words = 9 + @as(u64, nd) * 4 + @as(u64, nr) * 11 + nf + @as(u64, np) * 2;
    if (words * 4 + nn != bytes.len) return error.BadHoists;
    var out: Table = .{ .clean = get(bytes, 3) == 1 };
    errdefer out.deinit(gpa);
    const ds = try gpa.alloc(Demand, nd);
    out.demands = ds;
    const rs = try gpa.alloc(Read, nr);
    out.reads = rs;
    const fs = try gpa.alloc(u32, nf);
    out.fields = fs;
    const ps = try gpa.alloc(Step, np);
    out.paths = ps;
    var at: usize = 9;
    inline for (.{ ds, rs }) |rows| for (rows) |*row| {
        inline for (@typeInfo(@TypeOf(row.*)).@"struct".field_names) |f| {
            @field(row, f) = get(bytes, at);
            at += 1;
        }
    };
    for (fs) |*f| {
        f.* = get(bytes, at);
        at += 1;
    }
    for (ps) |*p| {
        p.* = .{ .kind = get(bytes, at), .arg = get(bytes, at + 1) };
        at += 2;
        if (p.kind > 1) return error.BadHoists;
    }
    out.names = try gpa.dupe(u8, bytes[at * 4 ..]);
    for (fs) |f| if (!out.hasName(f)) return error.BadHoists;
    for (ps) |p| if (p.kind == 0 and !out.hasName(p.arg)) return error.BadHoists;
    for (ds, 0..) |d, i| {
        if (@as(u64, d.fields_start) + d.fields_len > nf) return error.BadHoists;
        if (i > 0 and ds[i - 1].inst > d.inst) return error.BadHoists;
    }
    for (rs) |r| {
        if (@as(u64, r.path_start) + r.path_len > np or r.prefix_len == 0 or r.prefix_len > r.path_len or r.phase > 1) return error.BadHoists;
        if (r.demand == none) {
            if (r.capture == none or r.placement != r.capture or r.phase != 0) return error.BadHoists;
        } else {
            const d = out.accepted(r.demand) orelse return error.BadHoists;
            if (d.decl != r.decl) return error.BadHoists;
        }
    }
    return out;
}

fn put(bytes: []u8, word: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[word * 4 ..][0..4], value, .little);
}
fn get(bytes: []const u8, word: usize) u32 {
    return std.mem.readInt(u32, bytes[word * 4 ..][0..4], .little);
}

test "hoist section round trips and refuses malformed ranges and versions" {
    const a = std.testing.allocator;
    const t: Table = .{
        .clean = true,
        .demands = &.{.{ .decl = 0, .inst = 2, .fields_start = 0, .fields_len = 1 }},
        .reads = &.{.{ .decl = 0, .demand = 2, .inst = 5, .holder = 0, .path_start = 0, .path_len = 1, .prefix_len = 1, .placement = 2, .phase = 1 }},
        .fields = &.{0},
        .names = "x\x00",
        .paths = &.{.{ .kind = 0, .arg = 0 }},
    };
    const bytes = try write(a, t);
    defer a.free(bytes);
    var got = try read(a, bytes);
    defer got.deinit(a);
    try std.testing.expectEqualDeep(t, got);
    got.assertAccepted(@fromBackingInt(2));
    try std.testing.expect(got.accepted(1) == null);
    try std.testing.expect(got.accepted(3) == null);

    put(bytes, 2, format_version + 1);
    try std.testing.expectError(error.BadHoists, read(a, bytes));
    put(bytes, 2, format_version);
    put(bytes, 11, 2);
    try std.testing.expectError(error.BadHoists, read(a, bytes));
}

test "fuzz: malformed hoist sections never leave their columns" {
    try @import("../fuzzing.zig").skipUnlessFuzzing();
    try std.testing.fuzz({}, struct {
        fn go(_: void, smith: *std.testing.Smith) !void {
            var buffer: [4096]u8 = undefined;
            const len = smith.sliceWithHash(&buffer, 0x315);
            const bytes = buffer[0..len];
            var t = read(std.testing.allocator, bytes) catch |err| switch (err) {
                error.BadHoists => return,
                error.OutOfMemory => return err,
            };
            defer t.deinit(std.testing.allocator);
            const encoded = try write(std.testing.allocator, t);
            defer std.testing.allocator.free(encoded);
            var back = try read(std.testing.allocator, encoded);
            defer back.deinit(std.testing.allocator);
            try std.testing.expectEqualDeep(t, back);
        }
    }.go, .{});
}
