//! L10: a value written at a supply's key by its own structure
//! (`docs/design/ownership-v2.md` §2.1, *An arrival's level*). A parameter's position is one
//! arrival at the key's level, when its slot has an object. Anything else, a built value, a
//! call's result, or a tuple or a constructor with no object at its slot, is described by its
//! place, each part at its own key below. A type variable's or an opaque place has no steps to
//! walk: the arrival stays as it is.
//!
//! Obligations kept here: none of §2.14's directly: `SplitRow` says what this is for.

const std = @import("std");
const Ids = @import("Ids.zig");
const Contract = @import("Contract.zig");
const Relation = @import("Relation.zig");
const Slots = @import("Slots.zig");
const Value = @import("Value.zig");

const Error = Relation.Error;
const PlaceId = Ids.PlaceId;

/// One write, at `key`: `a` as it is (`by_slot`), else read deep; or value `v` by `place`.
pub const Part = struct { key: []const u32, a: Contract.Arrival, by_slot: bool = false, v: u32 = Ids.none_int, place: PlaceId = .none };

pub const Plan = struct { ev: *Relation.Eval, call: Value.Call, arena: std.mem.Allocator, out: *std.ArrayList(Part) };

/// Value `v` at `key`: a parameter's own object as its slot, anything else part by part.
pub fn write(p: Plan, v: u32, key: []const u32, a: Contract.Arrival) Error!void {
    if (try direct(p, v, key)) return;
    const at = placeOf(p.ev, v);
    if (at == .none) return p.out.append(p.arena, .{ .key = key, .a = a });
    const k = p.ev.f.places.kind(at);
    if (k == .@"var" or k == .@"opaque") return p.out.append(p.arena, .{ .key = key, .a = a });
    try p.out.append(p.arena, .{ .key = key, .a = a, .v = v, .place = at });
}

/// `v` as an arrival by structure, at `key`: only a parameter's position, whose slot has an object.
pub fn direct(p: Plan, v: u32, key: []const u32) Error!bool {
    const f = p.ev.f;
    const x = f.val(v);
    if (x.kind != .ref or x.family != Slots.empty or f.roots.items[x.root].kind != .param) return false;
    const at = f.pos.items[x.pos].slot;
    const k = f.places.kind(f.places.pathPlace(at));
    if (k == .tuple or k == .ctor) return false;
    const r = f.roots.items[x.root];
    try p.out.append(p.arena, .{ .key = key, .by_slot = true, .a = .{ .kind = .param, .j = r.a, .slot = try f.slots.relOf(p.ev.gpa(), p.ev.account(), p.ev.places(), at), .deep = k == .@"var" or k == .@"opaque", .path = at.int() } });
    return true;
}

/// The place of value `v`, `.none` when it has none to walk.
pub fn placeOf(ev: *Relation.Eval, v: u32) PlaceId {
    const f = ev.f;
    const x = f.val(v);
    if (x.kind == .ref and x.family == Slots.empty) return f.places.pathPlace(f.pos.items[x.pos].slot);
    return if (x.kind == .built) x.place else .none;
}
