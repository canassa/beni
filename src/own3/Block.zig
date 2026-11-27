//! own3, layer 5: a module's block (`ownership-v3-kernel.md` §7.1), what
//! the module cache keeps of a module's walk under `--ownership=v3`:
//!
//! - its contracts as its importers read them (`Contract.Published`);
//! - its lowering channel (`own2/Hoists.Table`) and the reads that the
//!   lowering reads first (`Reads.Read`).
//!
//! A block holds no id of a session. A field is written as its name, not its
//! text rank, and a type as its package, its module and its name, not its
//! `TypeId` (`Names`); the reader gives each name the id of its own session
//! (`Remap`). Every other number is local to the module: a layout number, a
//! parameter, an entry of a layout, an allocation site, an instruction of
//! the module's BIR.
//!
//! ```
//! header    magic "OWN3BLK\x00" (8)   version: u32
//! strings   count: u32, then per string: len: u32, bytes
//! walked    u8                        0: the module was not walked
//! layouts   count: u32, then per layout: present: u8, and if present
//!             entries: u32, then per entry: kind: u8, labels: u32, then
//!             per label: kind | cyc << 7: u8, payload, head (`putLabel`)
//! contracts count: u32, then per declaration: present: u8, the contract
//! derived   count: u32, then per fact: the type, kind: u8, the effect
//! js        count: u32, then one byte each
//! channel   clean: u8, writes: u32, then per write: inst: u32, kind: u8,
//!           callers: u8
//! reads     count: u32, then seven u32 each
//! ```
//!
//! Every integer is little-endian. A contract, a function contract, a
//! source, a path and an effect are written field by field in declaration
//! order (`putStruct`): a bool and a `u8` as one byte, a `u16` as two, a
//! `u32` as four, a slice as its length and its elements, an optional as
//! one byte and its value. **A new field is written with no change here**,
//! unless it is wide enough to hold an id of a session (more than 16 bits):
//! then `local` must name it, or this file does not compile. A field that a
//! block dropped would read as its default at the importer, and the default
//! of a fact such as `switches`, `hosts` or `casts` is the optimistic side.
//!
//! The reader trusts no byte. Each length is checked against the bytes
//! left, each enum against its tags, and the decoded contracts against the
//! layouts they name (`valid`), so a damaged block is `error.BadBlock`: a
//! miss, and the module is walked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Contract = @import("Contract.zig");
const Loc = @import("Loc.zig");
const Reads = @import("Reads.zig");
const Hoists = @import("../own2/Hoists.zig");

pub const magic = "OWN3BLK\x00";
/// Bumped when the meaning of a byte changes. The compiler's build id is in
/// every key, so a block is only ever read by the compiler that wrote it;
/// the version is for a reader of the bytes.
pub const version: u32 = 1;

pub const Error = error{BadBlock} || Allocator.Error;

/// A type by its name: the declaring module's package and name, and the type's name.
pub const TypeName = struct { package: u8, module: []const u8, name: []const u8 };

/// How the writer names what a session numbers. A null answer says that the
/// session cannot name the id: the module has no block, and is not stored.
pub const Names = struct {
    ctx: *anyopaque,
    /// The text of the field with text rank `rank`.
    field: *const fn (ctx: *anyopaque, rank: u32) ?[]const u8,
    /// The name of the type with `TypeId` `id`.
    type: *const fn (ctx: *anyopaque, id: u32) ?TypeName,
};

/// The reader's inverse of `Names`. A null answer is a miss.
pub const Remap = struct {
    ctx: *anyopaque,
    /// The text rank of the field named `name`.
    field: *const fn (ctx: *anyopaque, name: []const u8) ?u32,
    /// The `TypeId` of the type named `name`.
    type: *const fn (ctx: *anyopaque, name: TypeName) ?u32,
};

/// What a block holds of one module.
pub const Module = struct {
    /// Null: the module was not walked (it has no kept types). It publishes
    /// no contract.
    published: ?*const Contract.Published = null,
    channel: Hoists.Table = .empty,
    reads: []const Reads.Read = &.{},
};

/// A block read back. `published` is its own (`Contract.Published.deinit`);
/// the channel's writes and the reads are `gpa`'s.
pub const Loaded = struct {
    published: ?*Contract.Published = null,
    channel: Hoists.Table = .empty,
    reads: []const Reads.Read = &.{},

    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        if (l.published) |p| p.deinit(gpa);
        l.channel.deinit(gpa);
        gpa.free(l.reads);
        l.* = .{};
    }
};

// ---- which fields a block may write as they are ------------------------------

/// The fields wide enough to hold an id of a session (more than 16 bits)
/// that hold none: each is a number of the module alone, the same in every
/// session that reads the module's source.
fn local(comptime T: type, comptime name: []const u8) bool {
    const rows = .{
        // A count of parameters; layout numbers of `Published.layouts`;
        // offsets into `flags`.
        .{ Contract.Contract, "arity" },
        .{ Contract.Contract, "layouts" },
        .{ Contract.Contract, "off" },
        .{ Contract.Fn, "arity" },
        .{ Contract.Fn, "layouts" },
        .{ Contract.Fn, "off" },
        // Instructions, declarations and locals of the module's BIR.
        .{ Hoists.Write, "inst" },
        .{ Reads.Read, "decl" },
        .{ Reads.Read, "demand" },
        .{ Reads.Read, "inst" },
        .{ Reads.Read, "holder" },
        .{ Reads.Read, "path_len" },
        .{ Reads.Read, "placement" },
        .{ Reads.Read, "phase" },
    };
    inline for (rows) |row| {
        if (row[0] == T and std.mem.eql(u8, row[1], name)) return true;
    }
    return false;
}

/// The type below the slices, optionals and pointers of `T`.
fn Base(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| Base(o.child),
        .pointer => |p| Base(p.child),
        else => T,
    };
}

/// The structs that `putStruct` writes field by field.
fn fieldwise(comptime T: type) bool {
    return T == Contract.Contract or T == Contract.Fn or T == Contract.Src or T == Contract.Path or T == Contract.Effect or T == Hoists.Write or T == Reads.Read;
}

fn checkField(comptime T: type, comptime name: []const u8, comptime F: type) void {
    const B = Base(F);
    switch (@typeInfo(B)) {
        .bool, .@"enum" => {},
        .int => |i| if (i.bits > 16 and !local(T, name)) @compileError("own3/Block.zig: field `" ++ name ++ "` of " ++ @typeName(T) ++ " is wide enough to hold an id of a session. If it holds a number of the module alone, name it in `local`; if it holds an id of a session (a `TypeId`, a text rank, a symbol), write it by name (kernel §7.1)."),
        .@"struct" => if (!fieldwise(B)) @compileError("own3/Block.zig: field `" ++ name ++ "` of " ++ @typeName(T) ++ " has a type that no block writes: " ++ @typeName(B)),
        else => @compileError("own3/Block.zig: field `" ++ name ++ "` of " ++ @typeName(T) ++ " has a type that no block writes: " ++ @typeName(B)),
    }
}

comptime {
    // The parts that this file writes by hand: a change of their fields is
    // a change of `putPublished`, `getPublished`, `same` and `valid`.
    exactFields(Contract.Published, &.{ "arena", "layouts", "contracts", "derived", "js" });
    exactFields(Contract.ExEntry, &.{ "labels", "kind" });
    exactFields(Contract.DerivedFact, &.{ "type", "kind", "effect" });
    exactFields(Loc.Label, &.{ "payload", "cyc", "kind", "head" });
    exactFields(Hoists.Table, &.{ "clean", "writes" });
}

fn exactFields(comptime T: type, comptime names: []const []const u8) void {
    const got = @typeInfo(T).@"struct".field_names;
    const text = "own3/Block.zig: the fields of " ++ @typeName(T) ++ " changed. The block writes this type by hand: write the new field, read it, compare it (`same`), check it (`valid`), then correct this list (kernel §7.1).";
    if (got.len != names.len) @compileError(text);
    for (got, names) |g, n| if (!std.mem.eql(u8, g, n)) @compileError(text);
}

/// Whether the head of label `l` is a `TypeId`: the label leaves the place of
/// a nominal type (a constructor's argument, an opaque type's slot), or is
/// a member that is one (a list, an opaque value, a cell's handle). The
/// head of each other label is 0 (`Loc.Table.stepLabel`, `memberLabel`;
/// `own2/Groups.zig`, `Adapter.describeOr`).
fn typeHead(l: Loc.Label) bool {
    return switch (l.kind) {
        .ctor_arg, .slot => true,
        .member => l.payload == @backingInt(Loc.Kind.list) or l.payload == @backingInt(Loc.Kind.@"opaque") or l.payload == @backingInt(Loc.Kind.cell),
        .field, .index, .elem, .contents, .row, .env, .fslot => false,
    };
}

/// Whether the payload of label `l` is a field's text rank.
fn fieldPayload(k: Loc.LabelKind) bool {
    return k == .field or k == .fslot;
}

// ---- writing -----------------------------------------------------------------

const Writer = struct {
    gpa: Allocator,
    names: Names,
    out: std.ArrayList(u8) = .empty,
    strings: std.ArrayList(u8) = .empty,
    string_count: u32 = 0,
    ids: std.StringHashMapUnmanaged(u32) = .empty,
    /// The session could not name an id, or a label has a head that no
    /// rule of `typeHead` reads: the module has no block.
    bad: bool = false,

    fn deinit(w: *Writer) void {
        w.out.deinit(w.gpa);
        w.strings.deinit(w.gpa);
        w.ids.deinit(w.gpa);
    }

    fn byte(w: *Writer, x: u8) Allocator.Error!void {
        try w.out.append(w.gpa, x);
    }

    fn int(w: *Writer, comptime T: type, x: T) Allocator.Error!void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, x, .little);
        try w.out.appendSlice(w.gpa, &buf);
    }

    /// The number of `text` in the block's table.
    fn string(w: *Writer, text: []const u8) Allocator.Error!void {
        const got = try w.ids.getOrPut(w.gpa, text);
        if (!got.found_existing) {
            got.value_ptr.* = w.string_count;
            w.string_count += 1;
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, @intCast(text.len), .little);
            try w.strings.appendSlice(w.gpa, &buf);
            try w.strings.appendSlice(w.gpa, text);
        }
        try w.int(u32, got.value_ptr.*);
    }

    fn typeName(w: *Writer, id: u32) Allocator.Error!void {
        const n = w.names.type(w.names.ctx, id) orelse {
            w.bad = true;
            return;
        };
        try w.byte(n.package);
        try w.string(n.module);
        try w.string(n.name);
    }

    fn put(w: *Writer, comptime T: type, v: T) Allocator.Error!void {
        switch (@typeInfo(T)) {
            .bool => try w.byte(@intFromBool(v)),
            .int => try w.int(T, v),
            .@"enum" => try w.int(std.meta.BackingInt(T), @backingInt(v)),
            .optional => |o| {
                try w.byte(@intFromBool(v != null));
                if (v) |x| try w.put(o.child, x);
            },
            .pointer => |p| switch (p.size) {
                .slice => {
                    try w.int(u32, @intCast(v.len));
                    for (v) |x| try w.put(p.child, x);
                },
                .one => try w.put(p.child, v.*),
                .many, .c => @compileError("own3/Block.zig: no block writes " ++ @typeName(T)),
            },
            .@"struct" => try w.putStruct(T, v),
            else => @compileError("own3/Block.zig: no block writes " ++ @typeName(T)),
        }
    }

    fn putStruct(w: *Writer, comptime T: type, v: T) Allocator.Error!void {
        if (comptime !fieldwise(T)) @compileError("own3/Block.zig: no block writes " ++ @typeName(T) ++ " field by field");
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |name, F| {
            comptime checkField(T, name, F);
            try w.put(F, @field(v, name));
        }
    }

    fn putLabel(w: *Writer, word: u64) Allocator.Error!void {
        const l: Loc.Label = @bitCast(word);
        try w.byte(@as(u8, @backingInt(l.kind)) | (@as(u8, @intFromBool(l.cyc)) << 7));
        if (fieldPayload(l.kind)) {
            if (w.names.field(w.names.ctx, l.payload)) |text| try w.string(text) else w.bad = true;
        } else try w.int(u32, l.payload);
        if (typeHead(l)) {
            try w.typeName(l.head);
        } else if (l.head != 0) {
            // No rule says what this head is: it is not written as a number
            // that another session could read as its own.
            w.bad = true;
        }
    }

    fn putPublished(w: *Writer, p: *const Contract.Published) Allocator.Error!void {
        try w.int(u32, @intCast(p.layouts.len));
        for (p.layouts) |lo| {
            try w.byte(@intFromBool(lo != null));
            const es = lo orelse continue;
            try w.int(u32, @intCast(es.len));
            for (es) |e| {
                try w.put(Loc.Kind, e.kind);
                try w.int(u32, @intCast(e.labels.len));
                for (e.labels) |l| try w.putLabel(l);
            }
        }
        try w.int(u32, @intCast(p.contracts.len));
        for (p.contracts) |co| {
            try w.byte(@intFromBool(co != null));
            if (co) |c| try w.put(Contract.Contract, c.*);
        }
        try w.int(u32, @intCast(p.derived.len));
        for (p.derived) |f| {
            try w.typeName(f.type);
            try w.byte(f.kind);
            try w.put(Contract.Effect, f.effect);
        }
        try w.put([]const bool, p.js);
    }
};

/// The block of `m`, in `gpa`, or null when the session cannot name an id
/// that the module's contracts hold: the module is then not stored.
pub fn write(gpa: Allocator, m: Module, names: Names) Allocator.Error!?[]u8 {
    var w: Writer = .{ .gpa = gpa, .names = names };
    defer w.deinit();
    try w.byte(@intFromBool(m.published != null));
    if (m.published) |p| try w.putPublished(p);
    try w.put(bool, m.channel.clean);
    try w.put([]const Hoists.Write, m.channel.writes);
    try w.put([]const Reads.Read, m.reads);
    if (w.bad) return null;

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try bytes.ensureTotalCapacityPrecise(gpa, magic.len + 8 + w.strings.items.len + w.out.items.len);
    bytes.appendSliceAssumeCapacity(magic);
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, version, .little);
    bytes.appendSliceAssumeCapacity(&buf);
    std.mem.writeInt(u32, &buf, w.string_count, .little);
    bytes.appendSliceAssumeCapacity(&buf);
    bytes.appendSliceAssumeCapacity(w.strings.items);
    bytes.appendSliceAssumeCapacity(w.out.items);
    return try bytes.toOwnedSlice(gpa);
}

// ---- reading -----------------------------------------------------------------

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,
    /// Where the value being read is made.
    a: Allocator,
    strings: []const []const u8 = &.{},
    remap: Remap,

    fn left(r: *const Reader) usize {
        return r.bytes.len - r.at;
    }

    fn byte(r: *Reader) Error!u8 {
        if (r.left() < 1) return error.BadBlock;
        defer r.at += 1;
        return r.bytes[r.at];
    }

    fn int(r: *Reader, comptime T: type) Error!T {
        const n = @sizeOf(T);
        if (r.left() < n) return error.BadBlock;
        defer r.at += n;
        return std.mem.readInt(T, r.bytes[r.at..][0..n], .little);
    }

    /// A count of things that each take one byte or more: never more than the bytes left.
    fn count(r: *Reader) Error!usize {
        const n = try r.int(u32);
        if (n > r.left()) return error.BadBlock;
        return n;
    }

    fn string(r: *Reader) Error![]const u8 {
        const id = try r.int(u32);
        if (id >= r.strings.len) return error.BadBlock;
        return r.strings[id];
    }

    fn typeId(r: *Reader) Error!u32 {
        const package = try r.byte();
        const module = try r.string();
        const name = try r.string();
        return r.remap.type(r.remap.ctx, .{ .package = package, .module = module, .name = name }) orelse error.BadBlock;
    }

    fn get(r: *Reader, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .bool => {
                const b = try r.byte();
                if (b > 1) return error.BadBlock;
                return b == 1;
            },
            .int => return r.int(T),
            .@"enum" => return std.enums.fromInt(T, try r.int(std.meta.BackingInt(T))) orelse error.BadBlock,
            .optional => |o| {
                if (!try r.get(bool)) return null;
                return try r.get(o.child);
            },
            .pointer => |p| switch (p.size) {
                .slice => {
                    const out = try r.a.alloc(p.child, try r.count());
                    // For the reads of the channel, which are `gpa`'s: an
                    // arena frees the rest.
                    errdefer r.a.free(out);
                    for (out) |*x| x.* = try r.get(p.child);
                    return out;
                },
                .one => {
                    const x = try r.a.create(p.child);
                    errdefer r.a.destroy(x);
                    x.* = try r.get(p.child);
                    return x;
                },
                .many, .c => @compileError("own3/Block.zig: no block reads " ++ @typeName(T)),
            },
            .@"struct" => return r.getStruct(T),
            else => @compileError("own3/Block.zig: no block reads " ++ @typeName(T)),
        }
    }

    fn getStruct(r: *Reader, comptime T: type) Error!T {
        if (comptime !fieldwise(T)) @compileError("own3/Block.zig: no block reads " ++ @typeName(T) ++ " field by field");
        var out: T = undefined;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types) |name, F| @field(out, name) = try r.get(F);
        return out;
    }

    fn getLabel(r: *Reader) Error!u64 {
        const b = try r.byte();
        if (b & 0x70 != 0) return error.BadBlock;
        const kind = std.enums.fromInt(Loc.LabelKind, @as(u4, @truncate(b))) orelse return error.BadBlock;
        const payload: u32 = if (fieldPayload(kind))
            r.remap.field(r.remap.ctx, try r.string()) orelse return error.BadBlock
        else
            try r.int(u32);
        if (payload > std.math.maxInt(u27)) return error.BadBlock;
        var l: Loc.Label = .{ .kind = kind, .cyc = b & 0x80 != 0, .payload = @intCast(payload), .head = 0 };
        if (typeHead(l)) l.head = try r.typeId();
        return l.word();
    }

    fn getPublished(r: *Reader, p: *Contract.Published) Error!void {
        const layouts = try r.a.alloc(?[]const Contract.ExEntry, try r.count());
        p.layouts = layouts;
        for (layouts) |*lo| {
            lo.* = null;
            if (!try r.get(bool)) continue;
            const es = try r.a.alloc(Contract.ExEntry, try r.count());
            for (es) |*e| {
                const kind = try r.get(Loc.Kind);
                const labels = try r.a.alloc(u64, try r.count());
                for (labels) |*l| l.* = try r.getLabel();
                e.* = .{ .labels = labels, .kind = kind };
            }
            lo.* = es;
        }
        const contracts = try r.a.alloc(?*const Contract.Contract, try r.count());
        p.contracts = contracts;
        for (contracts) |*co| {
            co.* = null;
            if (!try r.get(bool)) continue;
            co.* = try r.get(*const Contract.Contract);
        }
        const derived = try r.a.alloc(Contract.DerivedFact, try r.count());
        p.derived = derived;
        for (derived) |*f| {
            const ty = try r.typeId();
            const kind = try r.byte();
            f.* = .{ .type = ty, .kind = kind, .effect = try r.get(Contract.Effect) };
        }
        p.js = try r.get([]const bool);
    }
};

/// The block `bytes`, read into the reader's session. `error.BadBlock`: the
/// bytes are no block of this compiler, a name has no id in this session,
/// or a contract does not agree with the layouts it names.
pub fn read(gpa: Allocator, bytes: []const u8, remap: Remap) Error!Loaded {
    if (bytes.len < magic.len + 8) return error.BadBlock;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadBlock;
    if (std.mem.readInt(u32, bytes[magic.len..][0..4], .little) != version) return error.BadBlock;
    var r: Reader = .{ .bytes = bytes, .at = magic.len + 4, .a = gpa, .remap = remap };

    // The table of strings: slices of `bytes`, which outlive the read.
    var table: std.ArrayList([]const u8) = .empty;
    defer table.deinit(gpa);
    const strings = try r.count();
    try table.ensureTotalCapacityPrecise(gpa, strings);
    for (0..strings) |_| {
        const len = try r.count();
        table.appendAssumeCapacity(r.bytes[r.at..][0..len]);
        r.at += len;
    }
    r.strings = table.items;

    var out: Loaded = .{};
    errdefer out.deinit(gpa);
    if (try r.get(bool)) {
        const p = try gpa.create(Contract.Published);
        p.* = .{ .arena = .init(gpa) };
        out.published = p;
        r.a = p.arena.allocator();
        try r.getPublished(p);
        if (!valid(p)) return error.BadBlock;
    }
    r.a = gpa;
    out.channel.clean = try r.get(bool);
    out.channel.writes = try r.get([]const Hoists.Write);
    out.reads = try r.get([]const Reads.Read);
    if (r.left() != 0) return error.BadBlock;
    // The writes by instruction, ascending, each once (`Hoists.Table.find`).
    for (out.channel.writes, 0..) |w, i| {
        if (i != 0 and out.channel.writes[i - 1].inst >= w.inst) return error.BadBlock;
    }
    return out;
}

// ---- what a reader may index ---------------------------------------------------

fn entriesOf(p: *const Contract.Published, layout: u32) ?usize {
    if (layout >= p.layouts.len) return null;
    return (p.layouts[layout] orelse return null).len;
}

/// Whether the offsets `off` are those of the layouts `layouts[0..arity]`, and their end.
fn offsets(p: *const Contract.Published, arity: u32, layouts: []const u32, off: []const u32) ?usize {
    if (layouts.len != @as(usize, arity) + 1 or off.len != @as(usize, arity) + 1) return null;
    var at: usize = 0;
    for (0..arity) |j| {
        if (off[j] != at) return null;
        at += entriesOf(p, layouts[j]) orelse return null;
    }
    if (off[arity] != at) return null;
    _ = entriesOf(p, layouts[arity]) orelse return null;
    return at;
}

/// Whether each source of `srcs` names a parameter and an entry that
/// contract `c` has: a reader indexes the contract's layouts with them.
fn srcsValid(p: *const Contract.Published, c: *const Contract.Contract, srcs: []const Contract.Src) bool {
    for (srcs) |s| {
        if (s.p != 0 and (s.p - 1) / 2 >= c.arity) return false;
        switch (s.kind) {
            .outside, .twice, .fresh => {},
            .param => {
                if (s.a >= c.arity) return false;
                if (s.e >= entriesOf(p, c.layouts[s.a]).?) return false;
            },
            .answer => {
                if (s.a >= c.arity) return false;
                if (c.fns[s.a]) |g| if (s.e >= entriesOf(p, g.layouts[g.arity]).?) return false;
            },
        }
    }
    return true;
}

fn renewValid(p: *const Contract.Published, c: *const Contract.Contract, renew: []const ?[]const Contract.Src) bool {
    if (renew.len != 0 and renew.len != c.flags.len) return false;
    for (renew) |r| if (r) |srcs| if (!srcsValid(p, c, srcs)) return false;
    return true;
}

/// Whether every index that a reader of `p` takes from it is inside what it
/// names (`Contract.Reader`, `Frame.applyAt`): a contract's layouts are
/// layouts of the block, its offsets are those of its layouts, each table
/// by entry has an entry for each, and each source names a parameter and an
/// entry of the contract.
pub fn valid(p: *const Contract.Published) bool {
    for (p.contracts) |co| {
        const c = co orelse continue;
        const n = offsets(p, c.arity, c.layouts, c.off) orelse return false;
        if (c.flags.len != n) return false;
        if (c.res.len != entriesOf(p, c.layouts[c.arity]).?) return false;
        if (c.fns.len != c.arity) return false;
        // The function contracts first: a source of the kind `answer` reads one.
        for (c.fns) |fo| {
            const g = fo orelse continue;
            const gn = offsets(p, g.arity, g.layouts, g.off) orelse return false;
            if (g.supply.len != gn or g.free.len != gn) return false;
        }
        for (c.res) |srcs| if (!srcsValid(p, c, srcs)) return false;
        for (c.fns) |fo| {
            const g = fo orelse continue;
            for (g.supply) |srcs| if (!srcsValid(p, c, srcs)) return false;
        }
        if (!renewValid(p, c, c.renew)) return false;
        for (c.paths) |path| {
            if (path.writes.len != 0 and path.writes.len != c.flags.len) return false;
            if (!renewValid(p, c, path.renew)) return false;
        }
    }
    // Sorted by type and method, each once: `Contract.derivedFact` searches it.
    for (p.derived, 0..) |f, i| {
        if (i == 0) continue;
        const b = p.derived[i - 1];
        if (b.type > f.type or (b.type == f.type and b.kind >= f.kind)) return false;
    }
    return true;
}

// ---- equality ------------------------------------------------------------------

fn eq(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .bool, .int, .@"enum" => return a == b,
        .optional => |o| {
            const x = a orelse return b == null;
            const y = b orelse return false;
            return eq(o.child, x, y);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (a.len != b.len) return false;
                for (a, b) |x, y| if (!eq(p.child, x, y)) return false;
                return true;
            },
            .one => return eq(p.child, a.*, b.*),
            .many, .c => @compileError("own3/Block.zig: no block compares " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            inline for (info.field_names, info.field_types) |name, F| {
                if (!eq(F, @field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        else => @compileError("own3/Block.zig: no block compares " ++ @typeName(T)),
    }
}

/// Whether two modules' published contracts are the same, field for field:
/// each layout number, each null, each label, each flag and each source.
pub fn samePublished(a: ?*const Contract.Published, b: ?*const Contract.Published) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    return eq([]const ?[]const Contract.ExEntry, x.layouts, y.layouts) and
        eq([]const ?*const Contract.Contract, x.contracts, y.contracts) and
        eq([]const Contract.DerivedFact, x.derived, y.derived) and
        eq([]const bool, x.js, y.js);
}

/// Whether a block read back is what was written (kernel §7.1): the check
/// that a safe build makes of each block.
pub fn same(m: Module, l: *const Loaded) bool {
    return samePublished(m.published, l.published) and
        m.channel.clean == l.channel.clean and
        eq([]const Hoists.Write, m.channel.writes, l.channel.writes) and
        eq([]const Reads.Read, m.reads, l.reads);
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

/// A session of the tests: field `rank` is named `f<rank + shift>`, type
/// `id` is `T<id + shift>` of module `M`.
const TestSession = struct {
    shift: u32 = 0,
    missing_type: ?u32 = null,
    buf: [8][24]u8 = undefined,
    next: usize = 0,

    fn text(s: *TestSession, comptime prefix: []const u8, x: u32) []const u8 {
        const slot = &s.buf[s.next % s.buf.len];
        s.next += 1;
        return std.fmt.bufPrint(slot, prefix ++ "{d}", .{x}) catch unreachable;
    }

    fn field(ctx: *anyopaque, rank: u32) ?[]const u8 {
        const s: *TestSession = @ptrCast(@alignCast(ctx));
        return s.text("f", rank);
    }
    fn typeOf(ctx: *anyopaque, id: u32) ?TypeName {
        const s: *TestSession = @ptrCast(@alignCast(ctx));
        if (s.missing_type == id) return null;
        return .{ .package = 1, .module = "M", .name = s.text("T", id) };
    }
    fn rankOf(ctx: *anyopaque, name: []const u8) ?u32 {
        const s: *TestSession = @ptrCast(@alignCast(ctx));
        if (name.len < 2 or name[0] != 'f') return null;
        return (std.fmt.parseInt(u32, name[1..], 10) catch return null) + s.shift;
    }
    fn typeId(ctx: *anyopaque, n: TypeName) ?u32 {
        const s: *TestSession = @ptrCast(@alignCast(ctx));
        if (n.package != 1 or !std.mem.eql(u8, n.module, "M") or n.name.len < 2 or n.name[0] != 'T') return null;
        const id = std.fmt.parseInt(u32, n.name[1..], 10) catch return null;
        if (s.missing_type == id) return null;
        return id + s.shift;
    }
    fn names(s: *TestSession) Names {
        return .{ .ctx = s, .field = field, .type = typeOf };
    }
    fn remap(s: *TestSession) Remap {
        return .{ .ctx = s, .field = rankOf, .type = typeId };
    }
};

/// A module with one contract over two layouts: `{ f7 : List a }` and a
/// constructor's argument of type 5.
fn testModule(arena: Allocator) Allocator.Error!Module {
    const Label = Loc.Label;
    const l_field: Label = .{ .kind = .field, .payload = 7, .cyc = false, .head = 0 };
    const l_elem: Label = .{ .kind = .elem, .payload = 0, .cyc = false, .head = 0 };
    const l_ctor: Label = .{ .kind = .ctor_arg, .payload = (1 << 12) | 2, .cyc = true, .head = 5 };
    const l_member: Label = .{ .kind = .member, .payload = @backingInt(Loc.Kind.list), .cyc = true, .head = 9 };
    const l_var: Label = .{ .kind = .member, .payload = @backingInt(Loc.Kind.@"var"), .cyc = true, .head = 0 };
    const layouts = try arena.alloc(?[]const Contract.ExEntry, 3);
    layouts[0] = try arena.dupe(Contract.ExEntry, &.{
        .{ .labels = try arena.dupe(u64, &.{l_field.word()}), .kind = .list },
        .{ .labels = try arena.dupe(u64, &.{ l_field.word(), l_elem.word() }), .kind = .@"var" },
    });
    layouts[1] = null;
    layouts[2] = try arena.dupe(Contract.ExEntry, &.{
        .{ .labels = try arena.dupe(u64, &.{ l_ctor.word(), l_member.word(), l_var.word() }), .kind = .list },
    });
    const g = try arena.create(Contract.Fn);
    g.* = .{
        .arity = 1,
        .layouts = try arena.dupe(u32, &.{ 2, 2 }),
        .off = try arena.dupe(u32, &.{ 0, 1 }),
        .supply = try arena.dupe([]const Contract.Src, &.{try arena.dupe(Contract.Src, &.{.{ .kind = .param, .a = 0, .e = 1 }})}),
        .free = try arena.dupe(bool, &.{true}),
        .called = true,
        .kept_out = true,
    };
    const c = try arena.create(Contract.Contract);
    c.* = .{
        .arity = 2,
        .layouts = try arena.dupe(u32, &.{ 0, 2, 2 }),
        .off = try arena.dupe(u32, &.{ 0, 2, 3 }),
        .flags = try arena.dupe(u8, &.{ Contract.flag_w | Contract.flag_r, 0, Contract.flag_e }),
        .res = try arena.dupe([]const Contract.Src, &.{try arena.dupe(Contract.Src, &.{ .outside, Contract.Src.fresh(3, true), .{ .kind = .answer, .a = 1, .e = 0 }, .{ .kind = .param, .a = 0, .e = 1, .p = Contract.Src.posOf(1, 1) } })}),
        .fns = try arena.dupe(?*const Contract.Fn, &.{ null, g }),
        .nonlinear = true,
        .old_result = false,
        .hosts = true,
        .renew = try arena.dupe(?[]const Contract.Src, &.{ null, try arena.dupe(Contract.Src, &.{.twice}), null }),
        .paths = try arena.dupe(Contract.Path, &.{
            .{ .writes = try arena.dupe(bool, &.{ true, false, false }) },
            .{ .writes = try arena.dupe(bool, &.{ false, false, false }), .renew = try arena.dupe(?[]const Contract.Src, &.{ null, null, &.{} }) },
        }),
    };
    const p = try arena.create(Contract.Published);
    p.* = .{
        .arena = undefined,
        .layouts = layouts,
        .contracts = try arena.dupe(?*const Contract.Contract, &.{ null, c }),
        .derived = try arena.dupe(Contract.DerivedFact, &.{ .{ .type = 5, .kind = 0, .effect = .{ .writes = true } }, .{ .type = 5, .kind = 1, .effect = .{ .hosts = true } } }),
        .js = try arena.dupe(bool, &.{ true, false }),
    };
    return .{
        .published = p,
        .channel = .{ .clean = true, .writes = try arena.dupe(Hoists.Write, &.{ .{ .inst = 3, .kind = .writer }, .{ .inst = 9, .kind = .update, .callers = true } }) },
        .reads = try arena.dupe(Reads.Read, &.{.{ .decl = 1, .demand = 2, .inst = 3, .holder = 4, .path_len = 5, .placement = 6, .phase = 1 }}),
    };
}

test "a block read back in the session that wrote it is what was written" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const m = try testModule(arena_state.allocator());
    var s: TestSession = .{};
    const bytes = (try write(testing.allocator, m, s.names())).?;
    defer testing.allocator.free(bytes);
    var back = try read(testing.allocator, bytes, s.remap());
    defer back.deinit(testing.allocator);
    try testing.expect(same(m, &back));
    // A field that differs is seen.
    @constCast(back.published.?.contracts[1].?).hosts = false;
    try testing.expect(!same(m, &back));
}

test "a block read in another session has that session's ranks and type ids, and nothing else changes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const m = try testModule(arena_state.allocator());
    var s: TestSession = .{};
    const bytes = (try write(testing.allocator, m, s.names())).?;
    defer testing.allocator.free(bytes);
    var other: TestSession = .{ .shift = 100 };
    var back = try read(testing.allocator, bytes, other.remap());
    defer back.deinit(testing.allocator);
    const p = back.published.?;
    const field: Loc.Label = @bitCast(p.layouts[0].?[0].labels[0]);
    try testing.expectEqual(@as(u27, 107), field.payload);
    const ctor: Loc.Label = @bitCast(p.layouts[2].?[0].labels[0]);
    try testing.expectEqual(@as(u32, 105), ctor.head);
    try testing.expectEqual(@as(u27, (1 << 12) | 2), ctor.payload);
    const member: Loc.Label = @bitCast(p.layouts[2].?[0].labels[1]);
    try testing.expectEqual(@as(u32, 109), member.head);
    const variable: Loc.Label = @bitCast(p.layouts[2].?[0].labels[2]);
    try testing.expectEqual(@as(u32, 0), variable.head);
    try testing.expectEqual(@as(u32, 105), p.derived[0].type);
    // The contracts hold no id of a session.
    try testing.expect(eq([]const ?*const Contract.Contract, m.published.?.contracts, p.contracts));
    try testing.expect(!same(m, &back));
}

test "a module that was not walked has a block that says so" {
    var s: TestSession = .{};
    const bytes = (try write(testing.allocator, .{}, s.names())).?;
    defer testing.allocator.free(bytes);
    var back = try read(testing.allocator, bytes, s.remap());
    defer back.deinit(testing.allocator);
    try testing.expect(back.published == null and back.channel.writes.len == 0 and back.reads.len == 0);
}

test "an id that the session cannot name: no block; a name that the reader does not have: a miss" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const m = try testModule(arena_state.allocator());
    var s: TestSession = .{ .missing_type = 9 };
    try testing.expect(try write(testing.allocator, m, s.names()) == null);
    var full: TestSession = .{};
    const bytes = (try write(testing.allocator, m, full.names())).?;
    defer testing.allocator.free(bytes);
    try testing.expectError(error.BadBlock, read(testing.allocator, bytes, s.remap()));
}

test "a label whose head no rule reads: no block" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const odd: Loc.Label = .{ .kind = .index, .payload = 1, .cyc = false, .head = 4 };
    const layouts = try arena.alloc(?[]const Contract.ExEntry, 1);
    layouts[0] = try arena.dupe(Contract.ExEntry, &.{.{ .labels = try arena.dupe(u64, &.{odd.word()}), .kind = .list }});
    var p: Contract.Published = .{ .arena = undefined, .layouts = layouts };
    var s: TestSession = .{};
    try testing.expect(try write(testing.allocator, .{ .published = &p }, s.names()) == null);
}

test "each damaged block is a miss: every cut, and every byte changed" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const m = try testModule(arena_state.allocator());
    var s: TestSession = .{};
    const bytes = (try write(testing.allocator, m, s.names())).?;
    defer testing.allocator.free(bytes);
    for (0..bytes.len) |n| try testing.expectError(error.BadBlock, read(testing.allocator, bytes[0..n], s.remap()));
    // A changed byte gives a miss or a block that a reader can index; it
    // never gives a read outside the bytes or a leak (the test allocator).
    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    for (0..copy.len) |i| for ([_]u8{ 1, 0x80, 0xff }) |x| {
        copy[i] = bytes[i] ^ x;
        defer copy[i] = bytes[i];
        var back = read(testing.allocator, copy, s.remap()) catch |err| switch (err) {
            error.BadBlock => continue,
            error.OutOfMemory => return err,
        };
        defer back.deinit(testing.allocator);
        if (back.published) |p| try testing.expect(valid(p));
    };
}

test "a contract that names a layout or an entry that the block does not have is not valid" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const m = try testModule(arena_state.allocator());
    const p = @constCast(m.published.?);
    try testing.expect(valid(p));
    const c = @constCast(p.contracts[1].?);
    const layouts = @constCast(c.layouts);
    layouts[0] = 1; // a layout that the block does not fill
    try testing.expect(!valid(p));
    layouts[0] = 0;
    const res = @constCast(c.res[0]);
    res[3].e = 2; // parameter 0 has two entries
    try testing.expect(!valid(p));
    res[3].e = 1;
    res[2].e = 1; // the function at parameter 1 answers one entry
    try testing.expect(!valid(p));
    res[2].e = 0;
    try testing.expect(valid(p));
}
