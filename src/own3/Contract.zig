//! own3, layer 2: contracts (research report 110 §6.4, §6.5; report 111 §2).
//!
//! A contract is a table over the locations of a signature:
//!
//! - for each parameter location, whether the body **reads** it, **writes**
//!   it (the caller must hand it `own`) and lets it **escape**;
//! - for each result location, what it is made of: `fresh`, `shared`, a
//!   parameter location, or the answer of a function parameter;
//! - for each function parameter, what the body hands it (`Fn`).
//!
//! A location with no source holds no cell (a recursion that never ends, an
//! empty list). `shared` is the answer for everything a rule does not name.
//!
//! Layout numbers are those of the module that owns the contract
//! (`Loc.Table`). `Published` holds the layouts as label paths, so another
//! module reads a contract into its own table (`import`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Loc = @import("Loc.zig");

pub const none = Loc.none;

pub const Src = struct {
    kind: Kind,
    /// `param`: the parameter. `answer`: the function parameter.
    a: u16 = 0,
    /// The entry of that parameter's layout, or of the function's result layout.
    e: u16 = 0,

    pub const Kind = enum(u8) { fresh, shared, param, answer };
    pub const fresh: Src = .{ .kind = .fresh };
    pub const shared: Src = .{ .kind = .shared };

    pub fn key(s: Src) u64 {
        return (@as(u64, @backingInt(s.kind)) << 32) | (@as(u64, s.a) << 16) | s.e;
    }
    pub fn eql(x: Src, y: Src) bool {
        return x.key() == y.key();
    }
};

/// The body writes the location: the caller must hand it `own`.
pub const flag_w: u8 = 1;
/// The body lets the location escape.
pub const flag_e: u8 = 2;
/// The body reads the location, answers it or hands it on. A location with
/// no flag is one that the body does not look at.
pub const flag_r: u8 = 4;
/// The body hands the location to a function parameter that can write it.
pub const flag_s: u8 = 8;

/// What a body does with a function parameter.
pub const Fn = struct {
    arity: u32,
    /// The function type's parameter layouts as the owner sees them, then its result layout.
    layouts: []const u32,
    /// Per parameter `k`, where its entries start in `supply`; one more for the end.
    off: []const u32,
    /// Per `(k, entry)`: what the owner hands there.
    supply: []const []const Src,
    /// Per `(k, entry)`: the owner does not read what it handed after the
    /// call, and nothing else that it handed can reach it. So the function
    /// can write there when each source is `own`.
    free: []const bool,
    /// The owner calls it, or hands it to a function that does.
    called: bool = false,
    /// The value goes where the checker does not follow it: nothing above holds.
    lost: bool = false,
    /// The owner lets the function's answer escape, or a cell keeps it. So
    /// each cell that the answer can hold escapes at the call that gives the
    /// function.
    ans_escapes: bool = false,
    /// The owner writes a cell after it handed that cell to the function. So
    /// a function that keeps what it is handed cannot go here.
    rewrites: bool = false,
};

pub const Contract = struct {
    arity: u32,
    /// The parameter layouts, then the result layout.
    layouts: []const u32,
    /// Per parameter, where its entries start in `flags`; one more for the end.
    off: []const u32,
    flags: []const u8,
    /// Per result entry.
    res: []const []const Src,
    /// Per parameter: its function contract, or null.
    fns: []const ?*const Fn,
    /// Parameter 0 has the word `entry`: the argument is a program's record.
    entry: bool = false,
    /// The result has the word `taken`: an element taken out of parameter 0,
    /// which the body's own frame reads as apart from the list (a trusted row
    /// of a loop of `core/` that hands each element once).
    taken: bool = false,
    /// A cell of a parameter can be at two locations of the result, or twice
    /// at one. When false, the result only rearranges what it takes: two
    /// parts of it are apart.
    nonlinear: bool = false,
    /// The result can be an object that was there before the call. When
    /// false, each answer is a record, a tuple or a list that the body made
    /// where it answers it, so it is no element of an array that exists.
    old_result: bool = true,

    pub fn writes(c: *const Contract) bool {
        for (c.flags) |f| if (f & flag_w != 0) return true;
        return false;
    }
};

fn srcLess(_: void, x: Src, y: Src) bool {
    return x.key() < y.key();
}

/// `xs` sorted, each source once. `shared` among them says that the location
/// has no claim; the other sources still say what it can hold.
pub fn normal(arena: Allocator, xs: []const Src) Allocator.Error![]const Src {
    if (xs.len == 0) return &.{};
    const out = try arena.dupe(Src, xs);
    std.mem.sort(Src, out, {}, srcLess);
    var n: usize = 1;
    for (out[1..]) |x| {
        if (x.eql(out[n - 1])) continue;
        out[n] = x;
        n += 1;
    }
    return out[0..n];
}

pub const shared_only: []const Src = &.{Src.shared};
pub const fresh_only: []const Src = &.{Src.fresh};

fn srcsEql(a: []const Src, b: []const Src) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!x.eql(y)) return false;
    return true;
}

fn union2(arena: Allocator, a: []const Src, b: []const Src) Allocator.Error![]const Src {
    if (a.len == 0) return b;
    if (b.len == 0 or srcsEql(a, b)) return a;
    const both = try arena.alloc(Src, a.len + b.len);
    @memcpy(both[0..a.len], a);
    @memcpy(both[a.len..], b);
    return normal(arena, both);
}

fn fnEql(a: ?*const Fn, b: ?*const Fn) bool {
    const x = a orelse return b == null;
    const y = b orelse return false;
    if (x.arity != y.arity or x.called != y.called or x.lost != y.lost or x.ans_escapes != y.ans_escapes or x.rewrites != y.rewrites) return false;
    if (!std.mem.eql(u32, x.layouts, y.layouts) or !std.mem.eql(bool, x.free, y.free)) return false;
    for (x.supply, y.supply) |s, t| if (!srcsEql(s, t)) return false;
    return true;
}

pub fn eql(a: *const Contract, b: *const Contract) bool {
    if (a.arity != b.arity or a.entry != b.entry or a.taken != b.taken or a.nonlinear != b.nonlinear or a.old_result != b.old_result) return false;
    if (!std.mem.eql(u32, a.layouts, b.layouts) or !std.mem.eql(u8, a.flags, b.flags)) return false;
    if (a.res.len != b.res.len) return false;
    for (a.res, b.res) |s, t| if (!srcsEql(s, t)) return false;
    for (a.fns, b.fns) |f, g| if (!fnEql(f, g)) return false;
    return true;
}

fn joinFn(arena: Allocator, a: ?*const Fn, b: ?*const Fn) Allocator.Error!?*const Fn {
    const x = a orelse return b;
    const y = b orelse return a;
    if (x.arity != y.arity or !std.mem.eql(u32, x.layouts, y.layouts)) {
        // Two readings of one type do not agree: nothing is known.
        const out = try arena.create(Fn);
        out.* = x.*;
        out.lost = true;
        return out;
    }
    const supply = try arena.alloc([]const Src, x.supply.len);
    const free = try arena.alloc(bool, x.free.len);
    for (supply, x.supply, y.supply) |*s, p, q| s.* = try union2(arena, p, q);
    for (free, x.free, y.free) |*f, p, q| f.* = p and q;
    const out = try arena.create(Fn);
    out.* = .{ .arity = x.arity, .layouts = x.layouts, .off = x.off, .supply = supply, .free = free, .called = x.called or y.called, .lost = x.lost or y.lost, .ans_escapes = x.ans_escapes or y.ans_escapes, .rewrites = x.rewrites or y.rewrites };
    return out;
}

/// The join of two contracts of one signature: every flag and every source of both.
pub fn join(arena: Allocator, a: *const Contract, b: *const Contract) Allocator.Error!*const Contract {
    if (a.arity != b.arity or !std.mem.eql(u32, a.layouts, b.layouts)) return b;
    const flags = try arena.alloc(u8, a.flags.len);
    for (flags, a.flags, b.flags) |*f, x, y| f.* = x | y;
    const res = try arena.alloc([]const Src, a.res.len);
    for (res, a.res, b.res) |*r, x, y| r.* = try union2(arena, x, y);
    const fns = try arena.alloc(?*const Fn, a.fns.len);
    for (fns, a.fns, b.fns) |*f, x, y| f.* = try joinFn(arena, x, y);
    const out = try arena.create(Contract);
    out.* = .{ .arity = a.arity, .layouts = a.layouts, .off = a.off, .flags = flags, .res = res, .fns = fns, .entry = a.entry or b.entry, .taken = a.taken or b.taken, .nonlinear = a.nonlinear or b.nonlinear, .old_result = a.old_result or b.old_result };
    return out;
}

// ---- across modules ----------------------------------------------------------

pub const ExEntry = struct { labels: []const u64, kind: Loc.Kind };

/// What a module hands its importers: read-only once it is published.
pub const Published = struct {
    arena: std.heap.ArenaAllocator,
    /// By the module's layout number; a layout that no contract names is not filled.
    layouts: []?[]const ExEntry = &.{},
    /// By declaration.
    contracts: []?*const Contract = &.{},

    pub fn deinit(p: *Published, gpa: Allocator) void {
        p.arena.deinit();
        gpa.destroy(p);
    }
};

fn exportLayout(p: *Published, loc: *const Loc.Table, gpa: Allocator, id: u32) Allocator.Error!void {
    if (p.layouts[id] != null) return;
    const a = p.arena.allocator();
    const es = loc.layoutEntries(id);
    const out = try a.alloc(ExEntry, es.len);
    var labels: std.ArrayList(u64) = .empty;
    defer labels.deinit(gpa);
    for (out, es) |*o, e| {
        labels.clearRetainingCapacity();
        try loc.labels(e.loc, &labels, gpa);
        o.* = .{ .labels = try a.dupe(u64, labels.items), .kind = e.kind };
    }
    p.layouts[id] = out;
}

fn dupFn(a: Allocator, f: *const Fn) Allocator.Error!*const Fn {
    const supply = try a.alloc([]const Src, f.supply.len);
    for (supply, f.supply) |*s, x| s.* = try a.dupe(Src, x);
    const out = try a.create(Fn);
    out.* = .{ .arity = f.arity, .layouts = try a.dupe(u32, f.layouts), .off = try a.dupe(u32, f.off), .supply = supply, .free = try a.dupe(bool, f.free), .called = f.called, .lost = f.lost, .ans_escapes = f.ans_escapes, .rewrites = f.rewrites };
    return out;
}

fn dupContract(a: Allocator, c: *const Contract) Allocator.Error!*Contract {
    const res = try a.alloc([]const Src, c.res.len);
    for (res, c.res) |*r, x| r.* = try a.dupe(Src, x);
    const fns = try a.alloc(?*const Fn, c.fns.len);
    for (fns, c.fns) |*f, x| f.* = if (x) |g| try dupFn(a, g) else null;
    const out = try a.create(Contract);
    out.* = .{ .arity = c.arity, .layouts = try a.dupe(u32, c.layouts), .off = try a.dupe(u32, c.off), .flags = try a.dupe(u8, c.flags), .res = res, .fns = fns, .entry = c.entry, .taken = c.taken, .nonlinear = c.nonlinear, .old_result = c.old_result };
    return out;
}

/// The module's contracts, by declaration, as its importers read them.
pub fn publish(gpa: Allocator, loc: *const Loc.Table, contracts: []const ?*const Contract) Allocator.Error!*Published {
    const p = try gpa.create(Published);
    p.* = .{ .arena = .init(gpa) };
    errdefer p.deinit(gpa);
    const a = p.arena.allocator();
    p.layouts = try a.alloc(?[]const ExEntry, loc.layouts.items.len);
    @memset(p.layouts, null);
    p.contracts = try a.alloc(?*const Contract, contracts.len);
    for (p.contracts, contracts) |*to, from| {
        const c = from orelse {
            to.* = null;
            continue;
        };
        for (c.layouts) |l| try exportLayout(p, loc, gpa, l);
        for (c.fns) |f| if (f) |g| for (g.layouts) |l| try exportLayout(p, loc, gpa, l);
        to.* = try dupContract(a, c);
    }
    return p;
}

/// The reader's side of one imported module: its layouts in this module's table.
pub const Reader = struct {
    from: *const Published,
    layouts: []u32,
    contracts: []?*const Contract,
    tried: []bool,

    pub fn init(arena: Allocator, from: *const Published) Allocator.Error!Reader {
        const layouts = try arena.alloc(u32, from.layouts.len);
        @memset(layouts, none);
        const contracts = try arena.alloc(?*const Contract, from.contracts.len);
        @memset(contracts, null);
        const tried = try arena.alloc(bool, from.contracts.len);
        @memset(tried, false);
        return .{ .from = from, .layouts = layouts, .contracts = contracts, .tried = tried };
    }

    fn layout(r: *Reader, gpa: Allocator, loc: *Loc.Table, id: u32) Allocator.Error!u32 {
        if (r.layouts[id] != none) return r.layouts[id];
        const es = r.from.layouts[id] orelse &.{};
        var out: std.ArrayList(Loc.Entry) = .empty;
        defer out.deinit(gpa);
        for (es) |e| {
            var at: u32 = 0;
            for (e.labels) |l| at = try loc.extend(at, @bitCast(l));
            try out.append(gpa, .{ .loc = at, .kind = e.kind, .single = !loc.loc_summary.items[at] });
        }
        const got = if (out.items.len == 0) loc.empty_layout else try loc.addLayout(out.items);
        r.layouts[id] = got;
        return got;
    }

    /// Declaration `decl`'s contract with this module's layout numbers, or null.
    pub fn contract(r: *Reader, gpa: Allocator, arena: Allocator, loc: *Loc.Table, decl: u32) Allocator.Error!?*const Contract {
        if (decl >= r.contracts.len) return null;
        if (r.tried[decl]) return r.contracts[decl];
        r.tried[decl] = true;
        const from = r.from.contracts[decl] orelse return null;
        const c = try dupContract(arena, from);
        const ls = @constCast(c.layouts);
        for (ls) |*l| l.* = try r.layout(gpa, loc, l.*);
        for (c.fns) |f| if (f) |g| {
            const gl = @constCast(g.layouts);
            for (gl) |*l| l.* = try r.layout(gpa, loc, l.*);
        };
        r.contracts[decl] = c;
        return c;
    }
};
