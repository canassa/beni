//! L3: the condition algebra of `Cond.Table` (`docs/design/ownership-v2.md`
//! §2.9, §3.4): the three constants, the atoms, `and`, the flat form and
//! the lattice (`flat`, `ofSet`, `join`, `leq`), the lazy `inst` atoms and
//! their resolution (`resolved`, §2.11 *κ across a call*), `instantiate`,
//! `rely` and the text. `Of(Table)` is this part's methods over the table
//! `Cond.zig` declares; `Cond.zig` binds them by name (§5).
//!
//! Obligations kept here: none (`Cond.zig` and `KappaRead.zig` keep the
//! condition table's).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Facts = @import("Facts.zig");
const Cell = @import("Cell.zig");
const full_cross_check = @import("ownership_options").full_cross_check;
const CondId = Ids.CondId;
const CellId = Ids.CellId;
const SetId = Ids.SetId;
const LabelId = Ids.LabelId;
const Charge = Ids.Charge;
const Error = Ids.ChargeError;
const Exactness = Facts.Exactness;

pub const Kind = enum(u8) { yes, @"and", atom, shared, lost };

pub const AtomKind = enum(u8) { excl, sep, within, apart, keep, writes, inst };

/// One condition (§3.4). `a`, `b` by kind: `and`: two conditions; `atom`:
/// `excl`: a cell; `sep`: two cells (the smaller id first); `within`: a
/// label; `apart`: a persistent set of cells; `keep`/`writes`: a function
/// parameter index.
pub const Cond = struct {
    kind: Kind,
    atom: AtomKind,
    a: u32,
    b: u32,
};

/// The three constants, in every table at these ids (`init`).
pub const yes: CondId = .from(0);
pub const shared: CondId = .from(1);
pub const lost: CondId = .from(2);

/// How a cell and a label print, the layer above's (`Summary`).
pub const Printer = struct {
    ctx: *anyopaque,
    cell: *const fn (ctx: *anyopaque, w: *std.Io.Writer, c: CellId) std.Io.Writer.Error!void,
    label: *const fn (ctx: *anyopaque, w: *std.Io.Writer, l: LabelId) std.Io.Writer.Error!void,
};

/// `rely`'s answer (§2.9): nothing, the atoms (the class's `xreq`), a refusal.
pub const Rely = union(enum) { ok, xreq: SetId, refused: Exactness };

pub fn sortText(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
}

/// The part of `Cond.Table` this file holds, over the table `Cond.zig` declares.
pub fn Of(comptime Table: type) type {
    return struct {
        /// A caller's interpretation of one atom at a call (§2.9): `excl c` the
        /// argument's deep condition at `c`'s path, `sep`/`apart` the arrivals'
        /// cells compared AT THAT PATH, `keep`/`writes` the actual's facts,
        /// `within` and a label `sep` §2.11 item 5's instantiation.
        pub const Interp = struct { ctx: *anyopaque, atom: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, charge: Charge, atom: Cond) Error!CondId };

        pub fn count(t: *const Table) u32 {
            return @intCast(t.conds.len());
        }

        pub fn get(t: *const Table, c: CondId) Cond {
            return t.conds.get(c.int());
        }

        pub fn kind(t: *const Table, c: CondId) Kind {
            return t.conds.col.kind[c.int()];
        }

        /// Whether `c` fails (`shared` or `lost`).
        pub fn fails(c: CondId) bool {
            return c == shared or c == lost;
        }

        /// Reserved before the dictionary is touched, hit or miss (§4.1).
        pub fn make(t: *Table, gpa: Allocator, charge: Charge, c: Cond) Error!CondId {
            try charge.reserve(gpa, .cond, 1);
            const got = try t.intern.getOrPut(gpa, .{ key0(c), c.a, c.b });
            if (got.found_existing) return .from(got.value_ptr.*);
            got.value_ptr.* = @intCast(t.conds.len());
            try t.conds.append(gpa, c);
            return .from(got.value_ptr.*);
        }

        fn key0(c: Cond) u32 {
            return (@as(u32, @backingInt(c.kind)) << 8) | @backingInt(c.atom);
        }

        /// The id of `c` if it exists, without making it. One inspection.
        pub fn find(t: *Table, gpa: Allocator, charge: Charge, c: Cond) Error!?CondId {
            try charge.reserve(gpa, .inspection, 1);
            return if (t.intern.get(.{ key0(c), c.a, c.b })) |hit| .from(hit) else null;
        }

        // ---- forming -----------------------------------------------------------

        /// `a ∧ b`, O(1): a failure absorbs (`shared` over `lost`), `yes` is the
        /// unit, the pair is interned in id order so `and(a, b) = and(b, a)`.
        pub fn @"and"(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) Error!CondId {
            if (a == b) return a;
            if (a == shared or b == shared) return shared;
            if (a == lost or b == lost) return lost;
            if (a == yes) return b;
            if (b == yes) return a;
            return t.make(gpa, charge, .{ .kind = .@"and", .atom = .excl, .a = @min(a.int(), b.int()), .b = @max(a.int(), b.int()) });
        }

        pub fn excl(t: *Table, gpa: Allocator, charge: Charge, c: CellId) Error!CondId {
            return t.make(gpa, charge, .{ .kind = .atom, .atom = .excl, .a = c.int(), .b = 0 });
        }

        /// The atom `sep a b` (two arrivals apart at this path), unordered.
        pub fn sepAtom(t: *Table, gpa: Allocator, charge: Charge, a: CellId, b: CellId) Error!CondId {
            std.debug.assert(a != b);
            return t.make(gpa, charge, .{ .kind = .atom, .atom = .sep, .a = @min(a.int(), b.int()), .b = @max(a.int(), b.int()) });
        }

        pub fn within(t: *Table, gpa: Allocator, charge: Charge, l: LabelId) Error!CondId {
            return t.make(gpa, charge, .{ .kind = .atom, .atom = .within, .a = l.int(), .b = 0 });
        }

        /// `apart{S}` over a persistent set of cells (in `Cell.Table.sets`).
        pub fn apartAtom(t: *Table, gpa: Allocator, charge: Charge, group: SetId) Error!CondId {
            return t.make(gpa, charge, .{ .kind = .atom, .atom = .apart, .a = group.int(), .b = 0 });
        }

        pub fn keep(t: *Table, gpa: Allocator, charge: Charge, j: u32) Error!CondId {
            return t.make(gpa, charge, .{ .kind = .atom, .atom = .keep, .a = j, .b = 0 });
        }

        pub fn writes(t: *Table, gpa: Allocator, charge: Charge, j: u32) Error!CondId {
            return t.make(gpa, charge, .{ .kind = .atom, .atom = .writes, .a = j, .b = 0 });
        }

        // ---- flattening and the lattice ------------------------------------------

        /// The atom set of `c` (not a failure): `.none` for `yes`, else the
        /// persistent set of its atoms. An `and` tree is walked once on an
        /// explicit stack, every inner node memoised: W stores flatten in
        /// O(W log W) once, their prefixes shared.
        pub fn flat(t: *Table, gpa: Allocator, charge: Charge, c: CondId) Error!SetId {
            std.debug.assert(!fails(c));
            if (c == yes) return .none;
            // Reserved before the memo is read, a hit too (§2.3 *Memo safety*, #1124).
            try charge.reserve(gpa, .memo, 1);
            if (t.flat_memo.get(c)) |s| return s;
            var stack: std.ArrayList(CondId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, c);
            while (stack.items.len > 0) {
                const x = stack.items[stack.items.len - 1];
                if (t.flat_memo.contains(x)) {
                    _ = stack.pop();
                    continue;
                }
                try charge.reserve(gpa, .inspection, 1);
                if (x == yes) {
                    try t.flat_memo.put(gpa, x, .none);
                    _ = stack.pop();
                    continue;
                }
                const d = t.get(x);
                if (d.kind == .atom) {
                    try t.flat_memo.put(gpa, x, try t.atoms.insert(gpa, charge, .none, x.int(), 0));
                    _ = stack.pop();
                    continue;
                }
                std.debug.assert(d.kind == .@"and");
                const l: CondId = .from(d.a);
                const r: CondId = .from(d.b);
                const fl = t.flat_memo.get(l);
                const fr = t.flat_memo.get(r);
                if (fl != null and fr != null) {
                    try t.flat_memo.put(gpa, x, try t.atoms.unionWith(gpa, charge, fl.?, fr.?));
                    _ = stack.pop();
                    continue;
                }
                if (fl == null) try stack.append(gpa, l);
                if (fr == null) try stack.append(gpa, r);
            }
            return t.flat_memo.get(c).?;
        }

        /// The canonical condition of an atom set: the `and` tree of its
        /// persistent set's own trie (a branch the `and` of its two sides'),
        /// one id per set (memoised per trie node), so a fixpoint's `join` is
        /// idempotent (§2.12) and a set one insertion larger builds only its
        /// new spine (§2.9, #1121): O(log |S|), never a chain of all its atoms.
        pub fn ofSet(t: *Table, gpa: Allocator, charge: Charge, s: SetId) Error!CondId {
            if (s == .none) return yes;
            if (t.of_set.get(.{s.int()})) |hit| return .from(hit);
            var stack: std.ArrayList(SetId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, s);
            while (stack.items.len > 0) {
                const x = stack.items[stack.items.len - 1];
                if (t.of_set.get(.{x.int()}) != null) {
                    _ = stack.pop();
                    continue;
                }
                try charge.reserve(gpa, .inspection, 1);
                const acc: CondId = if (t.atoms.branches(x)) |kids| blk: {
                    const l = t.of_set.get(.{kids[0].int()});
                    const r = t.of_set.get(.{kids[1].int()});
                    if (l == null or r == null) {
                        if (l == null) try stack.append(gpa, kids[0]);
                        if (r == null) try stack.append(gpa, kids[1]);
                        continue;
                    }
                    break :blk try t.@"and"(gpa, charge, .from(l.?), .from(r.?));
                } else blk: {
                    var it = t.atoms.iterate(x);
                    break :blk .from(it.next().?.key);
                };
                (try t.of_set.getOrPut(gpa, .{x.int()})).value_ptr.* = acc.int();
                if (!t.flat_memo.contains(acc)) try t.flat_memo.put(gpa, acc, x);
                _ = stack.pop();
            }
            return .from(t.of_set.get(.{s.int()}).?);
        }

        /// The lattice join (§2.10): `shared` wins, then `lost`, else the
        /// canonical form of the union of the atom sets. `join(a, a) = a`.
        pub fn join(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) Error!CondId {
            if (a == b) return a;
            if (a == shared or b == shared) return shared;
            if (a == lost or b == lost) return lost;
            if (a == yes) return t.ofSet(gpa, charge, try t.flat(gpa, charge, b));
            if (b == yes) return t.ofSet(gpa, charge, try t.flat(gpa, charge, a));
            const fa = try t.flat(gpa, charge, a);
            const fb = try t.flat(gpa, charge, b);
            return t.ofSet(gpa, charge, try t.atoms.unionWith(gpa, charge, fa, fb));
        }

        /// `a ⊑ b` in the lattice `yes ⊑ and{A} ⊑ and{A ∪ B} ⊑ lost ⊑ shared`.
        pub fn leq(t: *Table, gpa: Allocator, charge: Charge, a0: CondId, b0: CondId) Error!bool {
            // A fixpoint compares resolved conditions: an `inst` atom made at one
            // round need not repeat at the next.
            const a = try t.resolved(gpa, charge, a0);
            const b = try t.resolved(gpa, charge, b0);
            if (a == b or a == yes or b == shared) return true;
            if (a == shared) return false;
            if (b == lost) return true;
            if (a == lost) return false;
            if (b == yes) return false;
            return t.atoms.subset(gpa, charge, try t.flat(gpa, charge, a), try t.flat(gpa, charge, b));
        }

        /// Two conditions of one kind and one atom set, or a defect.
        pub fn expectSame(t: *Table, gpa: Allocator, charge: Charge, a: CondId, b: CondId) Error!void {
            const same = blk: {
                if (fails(a) or fails(b) or a == yes or b == yes) break :blk a == b;
                break :blk try t.flat(gpa, charge, a) == try t.flat(gpa, charge, b);
            };
            if (!same) std.debug.panic("ownership v2 cross-check: a crossed read {d} differs from its read at C {d}", .{ a.int(), b.int() });
        }

        /// `k` as the condition of its atom set (*Canonical partials*): one id per
        /// kind and atom set, whatever `and` tree made it.
        pub fn canonical(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!CondId {
            if (k == yes or fails(k)) return k;
            return t.ofSet(gpa, charge, try t.flat(gpa, charge, k));
        }

        // ---- lazy conditions (§2.11 *κ across a call*, part 3) -------------------------

        /// What resolves an `inst` atom: condition `k` of a class under a call's
        /// environment `env`, instantiated there (`Calls.Views`).
        pub const Resolver = struct {
            ctx: *anyopaque,
            /// `k` a condition id, or with `set` an atom set (`instSet`).
            resolve: *const fn (ctx: *anyopaque, t: *Table, gpa: Allocator, charge: Charge, k: u32, env: u32, set: bool) Error!CondId,
        };

        /// The atom `inst(k, env)`: a class's condition `k` under a call's
        /// environment, instantiated only when a reader tests it (`resolved`).
        /// `join`, `and`, `flat` and `kind` treat it as an opaque atom: resolving
        /// distributes over `and`. A new atom is queued in creation order.
        pub fn instAtom(t: *Table, gpa: Allocator, charge: Charge, k: CondId, env: u32) Error!CondId {
            if (k == yes or fails(k)) return k;
            const before = t.conds.len();
            const a = try t.make(gpa, charge, .{ .kind = .atom, .atom = .inst, .a = k.int(), .b = env });
            if (a.int() >= before) try t.inst_queue.append(gpa, a);
            return a;
        }

        /// `inst` of an atom set (a class's `xreq`): the set itself, flagged in
        /// the environment word (`inst_set_bit`), resolved atom by atom.
        pub fn instSet(t: *Table, gpa: Allocator, charge: Charge, s: SetId, env: u32) Error!CondId {
            if (s == .none) return yes;
            std.debug.assert(env & inst_set_bit == 0);
            const before = t.conds.len();
            const a = try t.make(gpa, charge, .{ .kind = .atom, .atom = .inst, .a = s.int(), .b = env | inst_set_bit });
            if (a.int() >= before) try t.inst_queue.append(gpa, a);
            return a;
        }

        pub const inst_set_bit: u32 = 1 << 31;

        /// The atoms queued before now are not this walk's to resolve: a frame
        /// holds only atoms made in its own walk (a class is published resolved).
        pub fn instFloor(t: *Table) void {
            t.inst_next = @intCast(t.inst_queue.items.len);
        }

        /// `k` with every `inst` atom resolved (`Cond.resolved`, the one entry):
        /// memoised per condition, canonical (*Canonical partials*). Before it
        /// resolves anything it resolves, in creation order, every queued atom up
        /// to the latest environment `k` names: an atom's resolution reads only
        /// its environment's actuals, made before it, so the atoms that read
        /// meets are resolved already and no resolution waits on another on the
        /// native stack (#1130).
        pub fn resolved(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!CondId {
            if (k == yes or fails(k) or t.inst_queue.items.len == 0) return k;
            // A call's condition resolved inside Demands' resolve is the call's.
            const was = charge.account.in_demands;
            charge.account.in_demands = false;
            defer charge.account.in_demands = was;
            // Resolving is the reader's growth: never a lane's share (§4.1).
            const task = try charge.account.enter(gpa, null);
            defer charge.account.leave(task);
            const g: Charge = .growth(charge.account);
            const latest = try t.instLatest(gpa, g, k) orelse return k;
            try g.reserve(gpa, .memo, 1);
            if (t.memo_resolved_root.get(.{k.int()})) |hit| return .from(hit);
            try t.drainTo(gpa, g, latest);
            const out = try t.canonical(gpa, g, try t.resolveTree(gpa, g, k));
            (try t.memo_resolved_root.getOrPut(gpa, .{k.int()})).value_ptr.* = out.int();
            return out;
        }

        /// The latest environment an `inst` atom of `k` names, null for none:
        /// memoised per node of `k`'s `and` tree, so a condition built over
        /// earlier ones reads its new nodes. Post-order on an explicit stack.
        pub fn instLatest(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!?u32 {
            const none: u32 = 0;
            const of = struct {
                fn leaf(tt: *const Table, x: CondId) ?u32 {
                    if (x == yes or fails(x)) return none;
                    const c = tt.get(x);
                    if (c.kind != .atom) return null;
                    return if (c.atom == .inst) (c.b & ~inst_set_bit) + 1 else none;
                }
            };
            if (of.leaf(t, k)) |v| return if (v == none) null else v - 1;
            var stack: std.ArrayList(CondId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, k);
            while (stack.items.len > 0) {
                const x = stack.items[stack.items.len - 1];
                if (t.memo_inst_latest.get(.{x.int()}) != null) {
                    _ = stack.pop();
                    continue;
                }
                try charge.reserve(gpa, .memo, 1);
                const c = t.get(x);
                var vals: [2]u32 = undefined;
                var missing = false;
                for ([_]CondId{ .from(c.a), .from(c.b) }, 0..) |sd, i| {
                    if (of.leaf(t, sd)) |v| {
                        vals[i] = v;
                    } else if (t.memo_inst_latest.get(.{sd.int()})) |v| {
                        vals[i] = v;
                    } else {
                        missing = true;
                        try stack.append(gpa, sd);
                    }
                }
                if (missing) continue;
                (try t.memo_inst_latest.getOrPut(gpa, .{x.int()})).value_ptr.* = @max(vals[0], vals[1]);
                _ = stack.pop();
            }
            const v = t.memo_inst_latest.get(.{k.int()}).?;
            return if (v == none) null else v - 1;
        }

        /// `k` with each `inst` atom replaced by its resolution: memoised per node
        /// of its `and` tree, a node's the `and` of its two sides'. Post-order on
        /// an explicit stack; the caller makes the answer canonical.
        pub fn resolveTree(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!CondId {
            const leafOf = struct {
                fn get(tt: *Table, g: Allocator, ch: Charge, x: CondId) Error!?CondId {
                    if (x == yes or fails(x)) return x;
                    const c = tt.get(x);
                    if (c.kind != .atom) return null;
                    return if (c.atom == .inst) try tt.resolveAtom(g, ch, x) else x;
                }
            }.get;
            if (try leafOf(t, gpa, charge, k)) |r| return r;
            var stack: std.ArrayList(CondId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, k);
            while (stack.items.len > 0) {
                const x = stack.items[stack.items.len - 1];
                if (t.memo_resolved.get(.{x.int()}) != null) {
                    _ = stack.pop();
                    continue;
                }
                try charge.reserve(gpa, .memo, 1);
                const c = t.get(x);
                var sides: [2]CondId = undefined;
                var missing = false;
                for ([_]CondId{ .from(c.a), .from(c.b) }, 0..) |sd, i| {
                    if (try leafOf(t, gpa, charge, sd)) |r| {
                        sides[i] = r;
                    } else if (t.memo_resolved.get(.{sd.int()})) |r| {
                        sides[i] = .from(r);
                    } else {
                        missing = true;
                        try stack.append(gpa, sd);
                    }
                }
                if (missing) continue;
                const got = try t.@"and"(gpa, charge, sides[0], sides[1]);
                (try t.memo_resolved.getOrPut(gpa, .{x.int()})).value_ptr.* = got.int();
                _ = stack.pop();
            }
            return .from(t.memo_resolved.get(.{k.int()}).?);
        }

        /// The queued atoms up to environment `env`, resolved in creation order.
        pub fn drainTo(t: *Table, gpa: Allocator, charge: Charge, env: u32) Error!void {
            while (t.inst_next < t.inst_queue.items.len) {
                const a = t.inst_queue.items[t.inst_next];
                if (t.get(a).b & ~inst_set_bit > env) break;
                t.inst_next += 1;
                _ = try t.resolveAtom(gpa, charge, a);
            }
        }

        /// One `inst` atom resolved, memoised: `instantiate` of its condition
        /// under its environment, canonical. A resolved condition holds no
        /// `inst` atom.
        pub fn resolveAtom(t: *Table, gpa: Allocator, charge: Charge, a: CondId) Error!CondId {
            try charge.reserve(gpa, .memo, 1);
            if (t.memo_resolved.get(.{a.int()})) |hit| return .from(hit);
            const d = t.get(a);
            const rs = t.resolver orelse unreachable; // an `inst` atom is made only under one
            const r = try t.canonical(gpa, charge, try rs.resolve(rs.ctx, t, gpa, charge, d.a, d.b & ~inst_set_bit, d.b & inst_set_bit != 0));
            if (std.debug.runtime_safety) try t.assertResolved(gpa, charge, r);
            if (std.debug.runtime_safety and full_cross_check and !t.no_memo) {
                // Resolved again, with no memo and no crossing (*Cross-check*), on an account and caches of its own (#1545).
                var scratch: Ids.Account = .{ .allowance = std.math.maxInt(u32) };
                defer scratch.deinit(gpa);
                const ch: Charge = .growth(&scratch);
                var caches = t.checkBegin(true);
                defer t.checkEnd(gpa, &caches);
                const saved = .{ t.no_cross, t.no_memo };
                t.no_cross = true;
                t.no_memo = true;
                defer {
                    t.no_cross = saved[0];
                    t.no_memo = saved[1];
                }
                try t.expectSame(gpa, ch, r, try t.canonical(gpa, ch, try rs.resolve(rs.ctx, t, gpa, ch, d.a, d.b & ~inst_set_bit, d.b & inst_set_bit != 0)));
            }
            (try t.memo_resolved.getOrPut(gpa, .{a.int()})).value_ptr.* = r.int();
            return r;
        }

        /// A `runtime_safety` check at a resolving reader: `k` holds no `inst`.
        /// It walks `k`'s `and` tree itself, charging nothing and writing no memo:
        /// a check never changes what the reader it checks charges (#1545).
        pub fn assertResolved(t: *Table, gpa: Allocator, charge: Charge, k: CondId) Error!void {
            _ = charge;
            if (!std.debug.runtime_safety or k == yes or fails(k)) return;
            var seen: Ids.FixedDict(1) = .{};
            defer seen.deinit(gpa);
            var stack: std.ArrayList(CondId) = .empty;
            defer stack.deinit(gpa);
            try stack.append(gpa, k);
            while (stack.pop()) |x| {
                if (x == yes or (try seen.getOrPut(gpa, .{x.int()})).found_existing) continue;
                const d = t.get(x);
                if (d.kind == .atom) {
                    if (d.atom == .inst) std.debug.panic("ownership v2: an unresolved inst atom reached a reader that tests it", .{});
                    continue;
                }
                std.debug.assert(d.kind == .@"and");
                try stack.append(gpa, .from(d.a));
                try stack.append(gpa, .from(d.b));
            }
        }

        // ---- at a call, and relying ----------------------------------------------

        /// κ instantiated at a call (§2.9, *a call*): a failure stays, every
        /// atom is answered by the caller's interpreter and the answers are
        /// conjoined. One record per atom.
        pub fn instantiate(t: *Table, gpa: Allocator, charge: Charge, k0: CondId, interp: Interp) Error!CondId {
            // A reader of a condition's atoms: its `inst` atoms resolved first.
            const k = try t.resolved(gpa, charge, k0);
            if (k == yes or fails(k)) return k;
            var acc: CondId = yes;
            var it = t.atoms.iterate(try t.flat(gpa, charge, k));
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                acc = try t.@"and"(gpa, charge, acc, try interp.atom(interp.ctx, t, gpa, charge, t.get(.from(e.key))));
                if (acc == shared) return shared;
            }
            return acc;
        }

        /// Relying on κ (§2.9): `yes` records nothing, atoms become the frame's
        /// `xreq`, a failure is the refusal `exclusive`, exact for `shared`.
        pub fn rely(t: *Table, gpa: Allocator, charge: Charge, k0: CondId) Error!Rely {
            const k = try t.resolved(gpa, charge, k0);
            try t.assertResolved(gpa, charge, k);
            if (k == yes) return .ok;
            if (k == shared) return .{ .refused = .exact };
            if (k == lost) return .{ .refused = .approximate };
            return .{ .xreq = try t.flat(gpa, charge, k) };
        }

        // ---- text -------------------------------------------------------------------

        /// A condition as a summary line prints it (v1's grammar): nothing,
        /// `{lost}`, `{shared}`, or `{atom, atom}` in text order (`arena` scratch).
        pub fn print(t: *Table, gpa: Allocator, charge: Charge, arena: Allocator, w: *std.Io.Writer, k: CondId, cellt: *const Cell.Table, p: Printer) (Error || std.Io.Writer.Error)!void {
            if (k == yes) return;
            if (k == lost) return w.writeAll("{lost}");
            if (k == shared) return w.writeAll("{shared}");
            var texts: std.ArrayList([]const u8) = .empty;
            defer texts.deinit(gpa);
            var it = t.atoms.iterate(try t.flat(gpa, charge, k));
            while (it.next()) |e| {
                try charge.reserve(gpa, .inspection, 1);
                var buf: std.Io.Writer.Allocating = .init(arena);
                try t.printAtom(&buf.writer, t.get(.from(e.key)), gpa, arena, cellt, p);
                try texts.append(gpa, buf.toOwnedSlice() catch return error.OutOfMemory);
            }
            sortText(texts.items);
            try w.writeByte('{');
            for (texts.items, 0..) |s, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(s);
            }
            try w.writeByte('}');
        }

        /// `excl X`, `sep X Y`, `within L`, `apart [X] [Y] …` (members in text
        /// order, one group each as v1 prints them), `keep cbJ`, `writes cbJ`.
        pub fn printAtom(t: *Table, w: *std.Io.Writer, a: Cond, gpa: Allocator, arena: Allocator, cellt: *const Cell.Table, p: Printer) (Error || std.Io.Writer.Error)!void {
            _ = t;
            std.debug.assert(a.kind == .atom);
            switch (a.atom) {
                .excl => {
                    try w.writeAll("excl ");
                    try p.cell(p.ctx, w, .from(a.a));
                },
                .sep => {
                    // The two sides in text order.
                    var x: std.Io.Writer.Allocating = .init(arena);
                    try p.cell(p.ctx, &x.writer, .from(a.a));
                    var y: std.Io.Writer.Allocating = .init(arena);
                    try p.cell(p.ctx, &y.writer, .from(a.b));
                    const xs = x.toOwnedSlice() catch return error.OutOfMemory;
                    const ys = y.toOwnedSlice() catch return error.OutOfMemory;
                    const first = std.mem.lessThan(u8, ys, xs);
                    try w.print("sep {s} {s}", .{ if (first) ys else xs, if (first) xs else ys });
                },
                .within => {
                    try w.writeAll("within ");
                    try p.label(p.ctx, w, .from(a.a));
                },
                .apart => {
                    var texts: std.ArrayList([]const u8) = .empty;
                    defer texts.deinit(gpa);
                    var it = cellt.sets.iterate(.from(a.a));
                    while (it.next()) |e| {
                        var buf: std.Io.Writer.Allocating = .init(arena);
                        try p.cell(p.ctx, &buf.writer, .from(e.key));
                        try texts.append(gpa, buf.toOwnedSlice() catch return error.OutOfMemory);
                    }
                    sortText(texts.items);
                    try w.writeAll("apart");
                    for (texts.items) |s| try w.print(" [{s}]", .{s});
                },
                .keep => try w.print("keep cb{d}", .{a.a + 1}),
                .writes => try w.print("writes cb{d}", .{a.a + 1}),
                // Unresolved: only a frame's value, never a summary, holds one.
                .inst => try w.print("inst {d}@{d}", .{ a.a, a.b }),
            }
        }
    };
}
