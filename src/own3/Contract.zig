//! own3, layer 2: contracts (`ownership-v3-kernel.md` §4; research report
//! 110 §6.4, §6.5; report 111 §2).
//!
//! A contract is a table over the locations of a signature:
//!
//! - for each parameter location, whether the body **reads** it, **writes**
//!   it (the caller must hand it `own`) and lets it **escape**;
//! - for each result location, its **sources**: the cells it can hold, each
//!   a named, positive fact (`Src`);
//! - for each function parameter, what the body hands it (`Fn`).
//!
//! A location with no source holds no cell: the body's frame had no atom
//! there (a recursion that never ends, `Nil`'s lists). That is a positive
//! fact of the body's walk, never a default. A walk that gives up publishes
//! no contract at all (`Check.walkDecl`), and a caller reads a callee with
//! no contract as unknown code: each argument escapes and the answer holds
//! every argument.
//!
//! Layout numbers are those of the module that owns the contract
//! (`Loc.Table`). `Published` holds the layouts as label paths, so another
//! module reads a contract into its own table (`import`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Loc = @import("Loc.zig");

pub const none = Loc.none;

/// One source of a result location, or of what a body hands a function
/// parameter. Every kind names cells (`ownership-v3-kernel.md` §4.2):
///
/// - `outside`: a cell that is outside every frame of the program's walk —
///   a top-level value's, a cell's contents, JavaScript's. No frame may
///   write it, and it holds no cell of any frame: what went into a cell or
///   to JavaScript escaped in the frame that put it there.
/// - `fresh`: a cell the body made, named by its allocation site `a` in the
///   body's frame. Two sources with one `a` may be one cell. `e` is 1 when
///   the body let that cell escape (a cell, a task, unknown code holds it).
/// - `param`: the cells of parameter `a` at entry `e` of its layout.
/// - `answer`: the cells that the function at parameter `a` answers at
///   entry `e` of its result layout.
/// - `twice`: the location is a summary location, and one of its cells can
///   be at two of its places. It keeps its claim; its parts are not apart,
///   so a part of it is all of it, and a callee that writes it is refused.
pub const Src = struct {
    kind: Kind,
    a: u16 = 0,
    e: u16 = 0,
    /// A `param` source whose cells are at positions of the list that
    /// parameter `a` is (kernel §6 rule 10, *A position*): 0 for none, else
    /// `1 + 2·q + k`, where parameter `q` names one position of that list
    /// and `k` is 0 for the element at it, 1 for every other element. A
    /// caller reads the cells of its argument there at those positions of
    /// its own match for the argument and the index (`Frame.posKey`). A
    /// reader that does not read it reads the cells with no position: the
    /// pessimistic side.
    p: u8 = 0,

    pub const Kind = enum(u8) { outside, fresh, param, answer, twice };
    pub const outside: Src = .{ .kind = .outside };
    pub const twice: Src = .{ .kind = .twice };

    pub fn fresh(k: u32, escaped: bool) Src {
        return .{ .kind = .fresh, .a = @intCast(@min(k, std.math.maxInt(u16))), .e = @intFromBool(escaped) };
    }

    /// `p` for parameter `q` and position `k` (0 or 1), or 0 when `q` cannot be named.
    pub fn posOf(q: usize, k: u32) u8 {
        if (q >= 127) return 0;
        return @intCast(1 + 2 * q + k);
    }

    pub fn key(s: Src) u64 {
        return (@as(u64, s.p) << 40) | (@as(u64, @backingInt(s.kind)) << 32) | (@as(u64, s.a) << 16) | s.e;
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
/// The body answers the location: its cells are in the result. Another
/// operand of a call that writes is every location the callee reads or
/// answers (kernel §5, test 2): an answered cell that the callee writes
/// through another parameter is the written cell under the answer's name.
/// Alone it is no read at the call: the caller holds the answer and reads
/// its cells where it reads them (`reads`). That holds of a record's field
/// slot (kernel §11); every other location the body answers is read as well
/// (`flag_r`), as v3 has judged lists from the start.
pub const flag_a: u8 = 16;
/// On a cell's handle (kernel §13 item 12): the body holds a value taken out
/// of the cell's contents across a call where another fiber can run (a read
/// of it after such a call, an escape of it, or an answer of it that a later
/// switch point precedes), or hands the contents to a function that can run
/// other fibers while it holds them. No read at the call: the caller marks
/// its own holder of the handle, and a function that writes the contents in
/// another fiber is refused where a holder of the cell has the mark.
pub const flag_m: u8 = 32;
/// On a cell's handle (kernel §13 item 12, *What the body stored is in the
/// cell while another fiber runs*): the body writes in place, at or after a
/// call where another fiber can run, a value it stored in the cell before
/// that call. No read at the call: a holder of the handle that another
/// fiber can hold too refuses the call, and a holder that is itself a
/// parameter or a capture says so in its own contract.
pub const flag_p: u8 = 64;

/// Whether the flags `x` of a location say the body reads it at the call:
/// any flag but the answer's and the marks.
pub fn reads(x: u8) bool {
    return x & ~(flag_a | flag_m | flag_p) != 0;
}

/// What a body does with a function parameter: the use of that location
/// (research report 112 §2.1).
pub const Fn = struct {
    arity: u32,
    /// The function type's parameter layouts as the owner sees them, then its result layout.
    layouts: []const u32,
    /// Per parameter `k`, where its entries start in `supply`; one more for the end.
    off: []const u32,
    /// Per `(k, entry)`: what the owner hands there. A worded row that does
    /// not say what it hands a function hands it every cell of every
    /// parameter, not `free` (`Check.wordedFn`): a missing fact is the
    /// pessimistic one.
    supply: []const []const Src,
    /// Per `(k, entry)`: the owner does not read what it handed after the
    /// call, and nothing else that it handed can reach it. So the function
    /// can write there when each source is `own`.
    free: []const bool,
    /// The owner calls it, or hands it to a function that does.
    called: bool = false,
    /// The value goes where no contract describes its holder (the default):
    /// nothing above holds, and a function that writes its parameter cannot go here.
    lost: bool = false,
    /// The owner lets the function's answer escape, or a cell keeps it. So
    /// each cell that the answer can hold escapes at the call that gives the
    /// function.
    ans_escapes: bool = false,
    /// The owner writes a cell after it handed that cell to the function. So
    /// a function that keeps what it is handed cannot go here.
    rewrites: bool = false,
    /// The owner runs the function at most once in each call (a cell's
    /// callback, `cellupdate` and `cellmodify`): two runs of it in one call
    /// never answer one captured cell (kernel §13 item 2).
    once: bool = false,
    /// A defect can run the function (kernel §13 item 12, *A defect*): the
    /// owner keeps it where a throw at any point of any fiber runs it, not
    /// only a switch point (`Task.onDefect`, `Task.scheduler`'s hook, and
    /// a function that hands its parameter to one).
    defect: bool = false,
    /// The owner can run the function while the fiber that runs it is
    /// masked or lent to a scheduler of its own (kernel §13 item 12, *A
    /// defect*, (d)): `Task.uninterruptible`'s and `uninterruptibleMask`'s
    /// work, `Task.withScheduler`'s, and a function that hands its
    /// parameter to one. A throw in another fiber does not stop it there.
    runs_on: bool = false,
    /// The owner only starts the function in a new fiber of the scheduler
    /// it runs under, unmasked, and hands it to nothing else (`Task.spawn`,
    /// `spawnIn`, `spawnDetached`; a function that loses its parameter to
    /// one only): a writer can go here (kernel §13 item 12, *A defect*, (d)).
    forks: bool = false,
    /// The owner starts the function in a new root fiber, unmasked, of the
    /// program's scheduler, and hands it to nothing else (`Task.start`'s
    /// work; named). Not `forks`: the fiber is not of the scheduler the
    /// frame runs under, whose stop would stop it, so no writer goes here;
    /// but nothing masks it or lends it, so a hosting function can (kernel
    /// §13 item 12, *A defect*, (d), *Up*; #2622).
    starts: bool = false,
    /// The owner can hold the function past the call and run it where no
    /// call runs it within, at a holder that does not start it in a fiber of
    /// its own (`Frame.startedAt`): a list, a cell, unknown code, a wrapper
    /// it answers. A hosting function is refused there (kernel §13 item 12,
    /// *A defect*, (d), *Up*; #2622).
    kept_out: bool = false,
    /// The owner runs the function after a call of another of its own
    /// function parameters or captures that the owner's walk could not
    /// judge (its holder does): where that one can park the fiber masked or
    /// lend it, this one runs in the window (`Frame.siblingRunsOn`; kernel
    /// §13 item 12, *A defect*, (d), *After such a call*; #2622).
    after_call: bool = false,
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
    /// Per parameter: its function contract. Each parameter of a function
    /// type has one, also when the body does nothing with the function.
    /// Null for a parameter of a function type says that the checker does
    /// not follow it: a caller hands it a function as to the default
    /// (research report 112 §2.2).
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
    /// The result has the word `copyof` and is a record (`Record.copy`,
    /// kernel §11): a new object whose fields hold parameter 0's values. A
    /// direct call is applied as that (`Frame.recordCopy`); `res` says it
    /// for every other use, on the pessimistic side.
    record_copy: bool = false,
    /// The body reads a value at a type variable of its result that is not
    /// the value's own type (a cast, `Js.to (Js.from x)` at `b`; or the
    /// answer of a callee that does): a caller that fills the variable in
    /// with a type that has a part of no location reads, there, cells that
    /// no reader can name, so they escape at its call (kernel §3.4,
    /// `Frame.escapeHidden`; research report 150).
    casts: bool = false,
    /// Every answer of the walked body is parameter 0 itself, whole (through
    /// identities only): a call answers its argument as it is, whatever type
    /// the body read it at (`Frame.identityCall`; research report 151).
    exact: bool = false,
    /// A row of a cell's words (`Check.cellRow`: `Ref`, `Deferred`,
    /// `Task`): what it answers, stores and hands at a type variable is the
    /// value there as it is, so each part of it is at its own place below
    /// the variable (kernel §3.4, `Frame.paired_exact`).
    cell_row: bool = false,
    /// The body makes a call where another fiber can run (kernel §13 item
    /// 12): one whose callee may be impure or may suspend. A worded row's is
    /// true: its words say nothing of it.
    switches: bool = false,
    /// A run of the body can park its own fiber while it is masked or lent
    /// to a scheduler of its own (kernel §13 item 12, *A defect*, (d)): a
    /// throw in another fiber does not stop it. A worded row's is false:
    /// only `core/Task.beni` masks a fiber or lends it, and it is walked.
    runs_on: bool = false,
    /// A writer of a cell the body made runs at its switch points, or a
    /// callee or a function the body runs within a call has the bit
    /// (kernel §13 item 12, *A defect*, (d)): the body may not run masked.
    hosts: bool = false,
    /// A fiber the body started (a fork, a race's branch, `Task.start`)
    /// in which a writer or a reader of a cell runs can still run where
    /// the body returns: a mask or a lend of an ancestor of it while it is
    /// parked keeps it running after a throw, so no call after this one may
    /// park the fiber masked or lent (kernel §13 item 12, *A defect*, (d),
    /// *Descendants of a masked fiber*; #2638). Also where the body calls,
    /// or runs within a call, code with `hosts`: the writers and readers
    /// that code started outlive the call (#2653). Implies `hosts`.
    hosts_forked: bool = false,
    /// What a call leaves in a parameter's cells (kernel §13, *Renewal*):
    /// per parameter location, as `flags` is, null where the call leaves
    /// the location as it was, or the sources it holds from the call on. A
    /// location below a cell's contents step (`◆`) is renewed where the call
    /// stores into the cell (`Ref.set`, `update`, `modify`, a body that calls
    /// them): every location of the contents is, and each then holds its
    /// sources and nothing else. Empty where no location is renewed. A
    /// source `param` names the argument's cells as they were at the call.
    renew: []const ?[]const Src = &.{},
    /// A run of the call can leave one cell at two locations of a renewed
    /// parameter's cells (kernel §13 item 5, *One value of the renewal at a
    /// time*). When false, each run leaves each cell of a parameter at one
    /// location of it, though the arms of the body leave it at different ones
    /// and `renew` is their union: two locations of the version a caller makes
    /// are apart. A worded row's is true: its words state no count.
    renew_shared: bool = false,
    /// The body's paths (kernel §13 item 13): one per arm of the `case`
    /// that answers it, each with what a run through that arm writes and
    /// renews. Empty where the body has fewer than two, or where no path
    /// says less than the union. Every other fact is the union's.
    paths: []const Path = &.{},

    /// The renewal of location `i` of `flags`, or null.
    pub fn renewAt(c: *const Contract, i: usize) ?[]const Src {
        if (c.renew.len == 0) return null;
        return c.renew[i];
    }

    pub fn renews(c: *const Contract) bool {
        for (c.renew) |r| if (r != null) return true;
        return false;
    }

    pub fn writes(c: *const Contract) bool {
        for (c.flags) |f| if (f & flag_w != 0) return true;
        return false;
    }

    pub fn escapes(c: *const Contract) bool {
        for (c.flags) |f| if (f & flag_e != 0) return true;
        return false;
    }
};

/// One path of a body (kernel §13 item 13): a run through one arm of the
/// `case` that answers it.
pub const Path = struct {
    /// Per location of `flags`: a run through the path writes it.
    writes: []const bool,
    /// As `Contract.renew`, for a run through the path: empty where it
    /// renews nothing.
    renew: []const ?[]const Src = &.{},

    pub fn renewAt(p: *const Path, i: usize) ?[]const Src {
        if (p.renew.len == 0) return null;
        return p.renew[i];
    }
};

fn pathEql(a: Path, b: Path) bool {
    if (!std.mem.eql(bool, a.writes, b.writes)) return false;
    for (0..a.writes.len) |i| {
        const x = a.renewAt(i);
        const y = b.renewAt(i);
        if ((x == null) != (y == null)) return false;
        if (x) |xs| if (!srcsEql(xs, y.?)) return false;
    }
    return true;
}

/// Path `k` of `c` as a path: its own, or the union where `c` has none.
fn pathOf(c: *const Contract, k: usize) Path {
    if (c.paths.len != 0) return c.paths[k];
    return .{ .writes = &.{}, .renew = c.renew };
}

/// Whether path `p` of `c` writes location `i` (a contract with no paths: the union's flag).
fn pathWrites(c: *const Contract, p: Path, i: usize) bool {
    if (p.writes.len == 0) return c.flags[i] & flag_w != 0;
    return p.writes[i];
}

/// The renewal of two contracts at one location of parameter `j`: null
/// where neither renews it, else either's sources, or the location's own
/// cells where one leaves it as it was (kernel §13).
fn joinRenew(arena: Allocator, a: *const Contract, x: ?[]const Src, y: ?[]const Src, j: usize, i: usize) Allocator.Error!?[]const Src {
    if (x == null and y == null) return null;
    const self = [1]Src{.{ .kind = .param, .a = @intCast(j), .e = @intCast(i - a.off[j]) }};
    return try normal(arena, try std.mem.concat(arena, Src, &.{ x orelse &self, y orelse &self }));
}

/// The paths of the join of `a` and `b` (kernel §13 item 13): path by path,
/// a contract with none read as each path being its union; none where both
/// have none, or where they have other numbers of them.
fn joinPaths(arena: Allocator, a: *const Contract, b: *const Contract) Allocator.Error![]const Path {
    if (a.paths.len == 0 and b.paths.len == 0) return &.{};
    if (a.paths.len != 0 and b.paths.len != 0 and a.paths.len != b.paths.len) return &.{};
    const n = @max(a.paths.len, b.paths.len);
    const out = try arena.alloc(Path, n);
    for (out, 0..) |*o, k| {
        const p = pathOf(a, k);
        const q = pathOf(b, k);
        const writes = try arena.alloc(bool, a.flags.len);
        for (writes, 0..) |*w, i| w.* = pathWrites(a, p, i) or pathWrites(b, q, i);
        var renew: []const ?[]const Src = &.{};
        if (p.renew.len != 0 or q.renew.len != 0) {
            const rn = try arena.alloc(?[]const Src, a.flags.len);
            for (0..a.arity) |j| for (a.off[j]..a.off[j + 1]) |i| {
                rn[i] = try joinRenew(arena, a, p.renewAt(i), q.renewAt(i), j, i);
            };
            renew = rn;
        }
        o.* = .{ .writes = writes, .renew = renew };
    }
    return out;
}

fn dupPaths(a: Allocator, ps: []const Path) Allocator.Error![]const Path {
    const out = try a.alloc(Path, ps.len);
    for (out, ps) |*o, p| {
        const renew = try a.alloc(?[]const Src, p.renew.len);
        for (renew, p.renew) |*r, x| r.* = if (x) |xs| try a.dupe(Src, xs) else null;
        o.* = .{ .writes = try a.dupe(bool, p.writes), .renew = renew };
    }
    return out;
}

fn srcLess(_: void, x: Src, y: Src) bool {
    return x.key() < y.key();
}

/// `xs` sorted, each source once.
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
    if (x.arity != y.arity or x.called != y.called or x.lost != y.lost or x.ans_escapes != y.ans_escapes or x.rewrites != y.rewrites or x.once != y.once or x.defect != y.defect or x.runs_on != y.runs_on or x.forks != y.forks or x.starts != y.starts or x.kept_out != y.kept_out or x.after_call != y.after_call) return false;
    if (!std.mem.eql(u32, x.layouts, y.layouts) or !std.mem.eql(bool, x.free, y.free)) return false;
    for (x.supply, y.supply) |s, t| if (!srcsEql(s, t)) return false;
    return true;
}

pub fn eql(a: *const Contract, b: *const Contract) bool {
    if (a.arity != b.arity or a.entry != b.entry or a.taken != b.taken or a.nonlinear != b.nonlinear or a.old_result != b.old_result or a.record_copy != b.record_copy or a.casts != b.casts or a.exact != b.exact or a.switches != b.switches or a.runs_on != b.runs_on or a.hosts != b.hosts or a.hosts_forked != b.hosts_forked or a.cell_row != b.cell_row or a.renew_shared != b.renew_shared) return false;
    if (!std.mem.eql(u32, a.layouts, b.layouts) or !std.mem.eql(u8, a.flags, b.flags)) return false;
    if (a.res.len != b.res.len) return false;
    for (a.res, b.res) |s, t| if (!srcsEql(s, t)) return false;
    for (a.fns, b.fns) |f, g| if (!fnEql(f, g)) return false;
    for (0..a.flags.len) |i| {
        const x = a.renewAt(i);
        const y = b.renewAt(i);
        if ((x == null) != (y == null)) return false;
        if (x) |xs| if (!srcsEql(xs, y.?)) return false;
    }
    if (a.paths.len != b.paths.len) return false;
    for (a.paths, b.paths) |p, q| if (!pathEql(p, q)) return false;
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
        out.runs_on = x.runs_on or y.runs_on;
        out.forks = false;
        out.starts = false;
        out.kept_out = x.kept_out or y.kept_out;
        out.after_call = x.after_call or y.after_call;
        return out;
    }
    const supply = try arena.alloc([]const Src, x.supply.len);
    const free = try arena.alloc(bool, x.free.len);
    for (supply, x.supply, y.supply) |*s, p, q| s.* = try union2(arena, p, q);
    for (free, x.free, y.free) |*f, p, q| f.* = p and q;
    const out = try arena.create(Fn);
    out.* = .{ .arity = x.arity, .layouts = x.layouts, .off = x.off, .supply = supply, .free = free, .called = x.called or y.called, .lost = x.lost or y.lost, .ans_escapes = x.ans_escapes or y.ans_escapes, .rewrites = x.rewrites or y.rewrites, .once = x.once and y.once, .defect = x.defect or y.defect, .runs_on = x.runs_on or y.runs_on, .forks = x.forks and y.forks, .starts = x.starts and y.starts, .kept_out = x.kept_out or y.kept_out, .after_call = x.after_call or y.after_call };
    return out;
}

/// The join of two contracts of one signature: every flag and every source of both.
pub fn join(arena: Allocator, a: *const Contract, b: *const Contract) Allocator.Error!*const Contract {
    // Two contracts of one code have one set of layouts for one arity. A
    // local function's arity is its parameters and its captures, and a walk
    // can find a capture an earlier one did not (its bottom contract has
    // none; a function called before its binding): a contract of another
    // arity is of no use to the rounds, which walk again to a fixed point at
    // the new one. A join of two contracts of one arity and other layouts
    // would drop facts the rounds need (research report 148, kernel §9).
    if (a.arity != b.arity) return b;
    if (!std.mem.eql(u32, a.layouts, b.layouts)) {
        if (std.debug.runtime_safety) {
            for (a.flags) |x| if (x != 0) std.debug.panic("own3: a join of two contracts of one arity and other layouts drops a flag", .{});
            for (a.res) |r| if (r.len != 0) std.debug.panic("own3: a join of two contracts of one arity and other layouts drops a source", .{});
        }
        return b;
    }
    const flags = try arena.alloc(u8, a.flags.len);
    for (flags, a.flags, b.flags) |*f, x, y| f.* = x | y;
    const res = try arena.alloc([]const Src, a.res.len);
    for (res, a.res, b.res) |*r, x, y| r.* = try union2(arena, x, y);
    const fns = try arena.alloc(?*const Fn, a.fns.len);
    for (fns, a.fns, b.fns) |*f, x, y| f.* = try joinFn(arena, x, y);
    // A location that one contract renews and the other leaves as it was
    // holds the renewal's sources or its own cells as they were (kernel §13).
    var renew: []const ?[]const Src = &.{};
    if (a.renews() or b.renews()) {
        const rn = try arena.alloc(?[]const Src, a.flags.len);
        for (0..a.arity) |j| for (a.off[j]..a.off[j + 1]) |i| {
            const x = a.renewAt(i);
            const y = b.renewAt(i);
            const self = [1]Src{.{ .kind = .param, .a = @intCast(j), .e = @intCast(i - a.off[j]) }};
            rn[i] = if (x == null and y == null) null else try normal(arena, try std.mem.concat(arena, Src, &.{ x orelse &self, y orelse &self }));
        };
        renew = rn;
    }
    const out = try arena.create(Contract);
    out.* = .{ .arity = a.arity, .layouts = a.layouts, .off = a.off, .flags = flags, .res = res, .fns = fns, .entry = a.entry or b.entry, .taken = a.taken or b.taken, .nonlinear = a.nonlinear or b.nonlinear, .old_result = a.old_result or b.old_result, .record_copy = a.record_copy and b.record_copy, .casts = a.casts or b.casts, .exact = a.exact and b.exact, .switches = a.switches or b.switches, .runs_on = a.runs_on or b.runs_on, .hosts = a.hosts or b.hosts, .hosts_forked = a.hosts_forked or b.hosts_forked, .cell_row = a.cell_row and b.cell_row, .renew = renew, .renew_shared = a.renew_shared or b.renew_shared, .paths = try joinPaths(arena, a, b) };
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
    /// Each derived `eq` or `compare` of a nominal type that the module emits,
    /// and what the methods it calls, at any depth, can do (kernel §6.11). A
    /// row that is not here has no fact: an importer reads it as code that
    /// writes and keeps what it is handed.
    derived: []const DerivedFact = &.{},
    /// By declaration: its body reaches JavaScript (`Check.reachesJs`,
    /// kernel §6 rule 10, *A worded body is checked against its walk*). A
    /// declaration past the end is read as one that does.
    js: []const bool = &.{},

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
    out.* = .{ .arity = f.arity, .layouts = try a.dupe(u32, f.layouts), .off = try a.dupe(u32, f.off), .supply = supply, .free = try a.dupe(bool, f.free), .called = f.called, .lost = f.lost, .ans_escapes = f.ans_escapes, .rewrites = f.rewrites, .once = f.once, .defect = f.defect, .runs_on = f.runs_on, .forks = f.forks, .starts = f.starts, .kept_out = f.kept_out, .after_call = f.after_call };
    return out;
}

fn dupContract(a: Allocator, c: *const Contract) Allocator.Error!*Contract {
    const res = try a.alloc([]const Src, c.res.len);
    for (res, c.res) |*r, x| r.* = try a.dupe(Src, x);
    const fns = try a.alloc(?*const Fn, c.fns.len);
    for (fns, c.fns) |*f, x| f.* = if (x) |g| try dupFn(a, g) else null;
    const renew = try a.alloc(?[]const Src, c.renew.len);
    for (renew, c.renew) |*r, x| r.* = if (x) |xs| try a.dupe(Src, xs) else null;
    const out = try a.create(Contract);
    out.* = .{ .arity = c.arity, .layouts = try a.dupe(u32, c.layouts), .off = try a.dupe(u32, c.off), .flags = try a.dupe(u8, c.flags), .res = res, .fns = fns, .entry = c.entry, .taken = c.taken, .nonlinear = c.nonlinear, .old_result = c.old_result, .record_copy = c.record_copy, .casts = c.casts, .exact = c.exact, .switches = c.switches, .runs_on = c.runs_on, .hosts = c.hosts, .hosts_forked = c.hosts_forked, .cell_row = c.cell_row, .renew = renew, .renew_shared = c.renew_shared, .paths = try dupPaths(a, c.paths) };
    return out;
}

/// What code that a walk does not follow can do with what it is handed: a
/// derived method through the methods of its parts, or a function handed
/// as evidence (kernel §6.11). `no_contract`: some of it is unknown code.
pub const Effect = struct {
    writes: bool = false,
    keeps: bool = false,
    no_contract: bool = false,
    /// The function writes a cell after it handed the cell to one of its
    /// function parameters (`Fn.rewrites`). The code that runs it hands
    /// that parameter a function in the default state, which keeps what it
    /// is handed (`ownership-v3-kernel.md` §6.8).
    rewrites: bool = false,
    /// The code can park its fiber masked or lent to a scheduler of its own,
    /// or hosts a writer (`Contract.runs_on`, `hosts`; kernel §13 item 12,
    /// *A defect*, (d)). Code the compiler derives is a well-known method,
    /// which cannot suspend: neither.
    runs_on: bool = false,
    hosts: bool = false,
    hosts_forked: bool = false,

    pub fn join(x: Effect, y: Effect) Effect {
        return .{ .writes = x.writes or y.writes, .keeps = x.keeps or y.keeps, .no_contract = x.no_contract or y.no_contract, .rewrites = x.rewrites or y.rewrites, .runs_on = x.runs_on or y.runs_on, .hosts = x.hosts or y.hosts, .hosts_forked = x.hosts_forked or y.hosts_forked };
    }
    pub fn any(x: Effect) bool {
        return x.writes or x.keeps or x.no_contract or x.rewrites;
    }
};

/// Whether a function parameter of `c` has `rewrites`.
pub fn rewritesFn(c: *const Contract) bool {
    for (c.fns) |fo| if (fo) |g| if (g.rewrites) return true;
    return false;
}

/// What a module says of one derived method it emits (`Published.derived`):
/// the type (a `TypeId`), the method (`Dispatch.Derived.Kind`), and what
/// the methods it calls through the parts of the type can do.
pub const DerivedFact = struct { type: u32, kind: u8, effect: Effect };

/// The first fact of `p` for derived method `kind` of type `ty`, or null.
pub fn derivedFact(p: *const Published, ty: u32, kind: u8) ?Effect {
    var lo: usize = 0;
    var hi: usize = p.derived.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const f = p.derived[mid];
        if (f.type < ty or (f.type == ty and f.kind < kind)) lo = mid + 1 else hi = mid;
    }
    if (lo < p.derived.len and p.derived[lo].type == ty and p.derived[lo].kind == kind) return p.derived[lo].effect;
    return null;
}

/// The module's contracts, by declaration, as its importers read them.
pub fn publish(gpa: Allocator, loc: *const Loc.Table, contracts: []const ?*const Contract, derived: []const DerivedFact, js: []const bool) Allocator.Error!*Published {
    const p = try gpa.create(Published);
    p.* = .{ .arena = .init(gpa) };
    errdefer p.deinit(gpa);
    const a = p.arena.allocator();
    // Sorted by type and method, so that an importer finds a fact in
    // logarithmic time (`derivedFact`); the sort is stable.
    const facts = try a.dupe(DerivedFact, derived);
    std.mem.sort(DerivedFact, facts, {}, struct {
        fn lt(_: void, x: DerivedFact, y: DerivedFact) bool {
            return x.type < y.type or (x.type == y.type and x.kind < y.kind);
        }
    }.lt);
    p.derived = facts;
    p.js = try a.dupe(bool, js);
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
        // The locations of the labels of the entry before: an entry shares
        // a prefix of its labels with the one before it, and only the labels
        // after that prefix are looked up. Each comparison and each lookup is
        // work of the module that reads the contract (kernel §8).
        var prev: []const u64 = &.{};
        var path: std.ArrayList(u32) = .empty;
        defer path.deinit(gpa);
        for (es) |e| {
            var same: usize = 0;
            while (same < prev.len and same < e.labels.len and prev[same] == e.labels[same]) same += 1;
            path.shrinkRetainingCapacity(same);
            loc.units +|= Loc.scanUnits(same) + (e.labels.len - same) * Loc.lookup_units;
            var at: u32 = if (same == 0) 0 else path.items[same - 1];
            for (e.labels[same..]) |l| {
                at = try loc.extend(at, @bitCast(l));
                try path.append(gpa, at);
            }
            prev = e.labels;
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
