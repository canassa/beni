//! Erased types (transparent-effects-proposal.md §14.3 rule 6, amended
//! 2026-11-08). A type variable that occurs once in a `foreign`'s signature
//! is an erasure: `Js.from : a → Value` hands the host a value whose type
//! it does not track, and `Js.to : Value → a` hands beni one the host made.
//! Rule 6 reads the function types WRITTEN in a signature; a function type
//! that reaches the signature through such a variable is known only at the
//! use. So the variable's class carries `erased`, the two bits below, and at
//! each use `walk` reads the instantiated type: each function type in a
//! position the host makes — a parameter of a function the host receives, or
//! the value itself when the host makes it — is `impure`, and so is each
//! nominal application that holds a function in such a position (§14.5).
//! When the erased value is itself a type variable, it is marked in turn, so
//! a beni declaration that erases its own parameter publishes the same bits
//! (`Schema.toHost : a → Js.Value`). An `entry` record parameter, which the
//! runtime calls with no beni call between, is walked the same way
//! (`entries`).
//!
//! Nothing here touches the store or `unify`. Like `Realms.zig`, it rides
//! the classes `Effects.zig` already has.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Effects = @import("Effects.zig");
const Walk = @import("Walk.zig");
const Realms = @import("Realms.zig");
const Bir = @import("../bir/Bir.zig");
const Ast = @import("../parse/Ast.zig");

const Var = Effects.Var;
const Error = Effects.Error;

/// The host receives the value (a parameter of the `foreign`).
pub const receives: u2 = 1;
/// The host makes the value (the `foreign`'s result).
pub const makes: u2 = 2;

/// A use's copy of an erased class, read at an imported use and walked in
/// `apply`, once every class is final.
pub const Item = struct { v: Var, bits: u2 };

/// One type variable of a `foreign`'s signature: its node and the bits of
/// the positions it occurs in.
pub const Erased = struct { node: u32, bits: u2 };
const Seen = struct { node: u32, bits: u2, count: u32 };

/// The erasures of `foreign` scheme `scheme`, one per node: each type
/// variable that occurs once, outside its `where` types, with the side of
/// the boundary it is on. The caller frees the list.
pub fn foreignBits(e: *Effects, scheme: Var, scratch: Allocator) Error![]Erased {
    const store = e.store;
    var seen: std.ArrayList(Seen) = .empty;
    defer seen.deinit(scratch);
    const Frame = struct { v: Var, positive: bool };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(scratch);
    try stack.append(scratch, .{ .v = scheme, .positive = true });
    while (stack.pop()) |f| {
        const r = store.find(f.v);
        if (Realms.unknown(store, r)) {
            const nd = try e.nodeFor(r);
            const bit = if (f.positive) makes else receives;
            for (seen.items) |*s| {
                if (s.node != nd) continue;
                s.count += 1;
                s.bits |= bit;
                break;
            } else try seen.append(scratch, .{ .node = nd, .bits = bit, .count = 1 });
            continue;
        }
        var k: u32 = 0;
        while (Walk.stepped(store, r, k)) |c| : (k += 1)
            try stack.append(scratch, .{ .v = c.v, .positive = if (c.kind == .param) !f.positive else f.positive });
    }
    var out: std.ArrayList(Erased) = .empty;
    for (seen.items) |s| {
        if (s.count == 1) try out.append(scratch, .{ .node = s.node, .bits = s.bits });
    }
    return out.toOwnedSlice(scratch);
}

/// The bits `foreignBits` gave node `nd`, or 0.
pub fn bitsOf(items: []const Erased, nd: u32) u2 {
    for (items) |it| if (it.node == nd) return it.bits;
    return 0;
}

/// The bits a walk marked on node `nd`, a type variable of a declaration.
pub fn of(e: *const Effects, nd: u32) u2 {
    return if (nd < e.solved.erased.items.len) e.solved.erased.items[nd] else 0;
}

fn mark(e: *Effects, nd: u32, bits: u2) Error!void {
    const s = &e.solved;
    const old = s.erased.items.len;
    if (old < s.nodes()) {
        try s.erased.resize(e.gpa, s.nodes());
        @memset(s.erased.items[old..], 0);
    }
    s.erased.items[nd] |= bits;
}

/// Every imported use's erasure, walked.
pub fn apply(e: *Effects, work: *std.ArrayList(u32), scratch: Allocator) Error!void {
    for (e.erasures.items) |it| try walk(e, it.v, it.bits, false, work, scratch);
}

/// Each `entry` record parameter of this module's declarations
/// (`boundary.md` §5.2, `ownership-checker.md` §30.3): the runtime receives
/// the record and calls its functions with no beni call between, so the
/// record is erased as a `foreign`'s parameter is. A nominal value those
/// functions return is raised too: the runtime runs what it holds — a
/// command's body — with arguments it makes, and its one class (§14.5)
/// holds them.
pub fn entries(e: *Effects, bir: *const Bir, schemes: []const Var.Optional, work: *std.ArrayList(u32), scratch: Allocator) Error!void {
    const store = e.store;
    const entry_bit = @as(u32, 1) << @backingInt(Ast.OwnWord.entry);
    for (bir.decls, schemes) |d, scheme| {
        if (d.kind == .foreign_value) continue;
        for (bir.ownSlotsV2(d)) |slot| {
            if (slot[1] & entry_bit == 0) continue;
            const r, _ = store.resolved(scheme.unwrap() orelse continue);
            if (!isFunc(store, r) or slot[0] >= Bir.own_type) continue;
            const param = Walk.stepped(store, r, slot[0]) orelse continue;
            if (param.kind == .param) try walk(e, param.v, receives, true, work, scratch);
        }
    }
}

/// An own declaration's erased class `ci`, at the use `r` copied it for.
pub fn applyRecord(e: *Effects, r: Effects.Record, target: u32, ci: usize, bits: u2, work: *std.ArrayList(u32), scratch: Allocator) Error!void {
    for (e.pairs.items[r.start..][0..r.len]) |p| {
        if (e.solved.classIndex(target, try e.nodeFor(p.a)) != @as(u32, @intCast(ci))) continue;
        try walk(e, p.b, bits, false, work, scratch);
    }
}

/// Raise each class `v` holds in a position the host makes to `impure` —
/// and, when `nominals`, each nominal application the host receives — and
/// mark `v` with the side it is on when it is a type variable.
fn walk(e: *Effects, v: Var, bits: u2, nominals: bool, work: *std.ArrayList(u32), scratch: Allocator) Error!void {
    const store = e.store;
    const Frame = struct { v: Var, made: bool, held: bool = false };
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(scratch);
    var done: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer done.deinit(scratch);
    if (bits & receives != 0) try stack.append(scratch, .{ .v = v, .made = false });
    if (bits & makes != 0) try stack.append(scratch, .{ .v = v, .made = true });
    while (stack.pop()) |f| {
        const r = store.find(f.v);
        const key = (@as(u64, r.int()) << 2) | (@as(u64, @intFromBool(f.held)) << 1) | @intFromBool(f.made);
        if ((try done.getOrPut(scratch, key)).found_existing) continue;
        if (Realms.unknown(store, r)) {
            // Only the erased value itself is marked. One it holds is not:
            // core's `List` erases a `List a` and a callback `a → b` to run
            // them in the host's loops, which call the callback with the
            // list's own elements, never with a value the host made.
            if (!f.held) try mark(e, try e.nodeFor(r), if (f.made) makes else receives);
            continue;
        }
        // A function the host receives is beni's own, and its parameters
        // are the host's. A nominal value the host receives is not raised:
        // its one class holds its own arrows too, and core's `List` erases
        // every element it stores.
        if (e.carries(r) and (f.made or (nominals and !isFunc(store, r)))) try e.raise(try e.nodeFor(r), .impure, work, scratch);
        var k: u32 = 0;
        while (Walk.stepped(store, r, k)) |c| : (k += 1)
            try stack.append(scratch, .{ .v = c.v, .made = if (c.kind == .param) !f.made else f.made, .held = true });
    }
}

fn isFunc(store: anytype, r: Var) bool {
    return switch (store.content(r)) {
        .structure => |st| st == .func,
        else => false,
    };
}
