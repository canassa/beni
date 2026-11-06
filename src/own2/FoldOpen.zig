//! L3: an open arrival whose slot lies past a fold
//! (`docs/design/ownership-v2.md` §2.1, *A step past a fold*). A callee's `ε… π1s*`
//! says its value lies somewhere below `s`: `s` is a `var` place, and no step of it
//! names how far below. Read at a slot of any place, it is `s`'s whole subtree, not
//! the object at `s`, whatever the caller's slot says of the value's own structure.
//!
//! Obligations kept here: none of §2.14's directly.

const Contract = @import("Contract.zig");
const Ids = @import("Ids.zig");
const LevelCycle = @import("LevelCycle.zig");
const Subtree = @import("Subtree.zig");

/// `Subtree.readAt` of arrival `a` of call `call`, read at `slot`.
pub fn read(e: anytype, call: u32, a: Contract.Arrival, slot: Ids.PathId, open: bool) Contract.Arrival {
    var x = Subtree.readAt(e.places(), a, slot, open);
    if (!open or !a.deep or x.deep or a.kind != .param) return x;
    const args = e.f.calls.items[call].args;
    if (a.j >= args.len) return x;
    const root = LevelCycle.rootOf(e.f, args[a.j]);
    const p = LevelCycle.of(e.places(), root, e.f.slots.relWords(a.slot), .none);
    x.deep = p != .none and e.places().kind(p) == .@"var";
    return x;
}
