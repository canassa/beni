//! L8: a value's leaves each at the slot it sits at, split from `Relation`
//! (`docs/design/ownership-v2.md` §2.9.2): what `Resolve` reads of a value
//! along a result's steps.
//!
//! Obligations kept here: none of §2.14's directly (every leaf of the value
//! is listed, at the steps that name it or at its value's).

const std = @import("std");
const Place = @import("Place.zig");
const Relation = @import("Relation.zig");

const Error = Relation.Error;
const Eval = Relation.Eval;
const Part = Relation.Part;
const Step = Place.Step;
const none = std.math.maxInt(u32);

/// A leaf of a value and the slot it sits at: `leavesOf`'s leaves, each
/// at the steps from the value's slot that name it (a part no step
/// names, a list's storage or an opaque value's, sits at its value's).
pub fn of(e: *Eval, v0: u32, at0: []const u32, out: *std.ArrayList(Part)) Error!void {
    const f = e.f;
    const g = e.gpa();
    const Item = struct { v: u32, tags: u32, at: []const u32 };
    var stack: std.ArrayList(Item) = .empty;
    defer stack.deinit(g);
    try stack.append(g, .{ .v = v0, .tags = 0, .at = at0 });
    while (stack.pop()) |it| {
        try e.charge(.inspection, 1);
        const x = f.val(it.v);
        const here = try f.slots.relOfWords(g, f.account, f.places, it.at);
        switch (x.kind) {
            .built => {
                if (x.site != none) try out.append(g, .{ .leaf = try f.leaf(.{ .kind = .site, .atom = x.site, .tags = it.tags }), .at = here });
                if (x.form == .list and x.head != 0) {
                    var ls: std.ArrayList(u32) = .empty;
                    defer ls.deinit(g);
                    try e.storageOf(x.head - 1, it.tags, &ls);
                    for (ls.items) |l| try out.append(g, .{ .leaf = l, .at = here });
                }
                for (f.kidsOf(x), 0..) |kv, n| {
                    const st: ?Step = switch (x.form) {
                        .tuple => try Step.index(f.account, @intCast(n)),
                        .ctor => try f.places.ctorStep(g, f.account, x.head, @intCast(n)),
                        .list => Step.elem,
                        .record => try Step.ofRank(f.account, f.wordsOf(x.extra)[n]),
                        .closure, .opaque_ => null,
                    };
                    const at = if (st) |stp| try std.mem.concat(e.arena, u32, &.{ it.at, &.{stp.word()} }) else it.at;
                    try stack.append(g, .{ .v = kv, .tags = it.tags, .at = at });
                }
            },
            .alt => {
                const ks = f.kidsOf(x);
                var i: usize = 0;
                while (i < ks.len) : (i += 2) {
                    const t = (try f.mergeTags(it.tags, try f.internTags(&.{.{ x.head, try f.armOf(ks[i]) }}))) orelse continue;
                    try stack.append(g, .{ .v = ks[i + 1], .tags = t, .at = it.at });
                }
            },
            else => {
                var ls: std.ArrayList(u32) = .empty;
                defer ls.deinit(g);
                try e.leavesOf(it.v, it.tags, &ls);
                for (ls.items) |l| try out.append(g, .{ .leaf = l, .at = here });
            },
        }
    }
}
