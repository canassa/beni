//! L12: a declaration's nested codes' captures (`docs/design/ownership-v2.md`
//! §2.11.4), split from `Groups`.
//!
//! Obligations kept here: none of §2.14's directly (a table).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Ids = @import("Ids.zig");

const none: u32 = Ids.none_int;

/// Per code of `nested` (their instructions), the locals it captures.
pub fn of(gpa: Allocator, bir: *const Bir, d: Bir.Decl, fr: []const u32, nested: []const u32, caps: *std.ArrayList(std.ArrayList(u32))) Allocator.Error!void {
    const start = d.inst_start.int();
    var i = start;
    // Captures: each read of a local inside a code, bound outside it.
    for (nested) |_| try caps.append(gpa, .empty);
    const which = struct {
        fn of(list: []const u32, inst: u32) ?usize {
            return std.mem.indexOfScalar(u32, list, inst);
        }
    };
    // Whether instruction `x` lies inside code `c` (its frame chain meets c).
    const inside = struct {
        fn f(frames: []const u32, x0: u32, c: u32) bool {
            var x = x0;
            var hops: u32 = 0;
            while (x != none and hops < 100_000) : (hops += 1) {
                if (x == c) return true;
                x = frames[x];
            }
            return false;
        }
    };
    i = start;
    while (i < d.inst_end.int()) : (i += 1) {
        if (bir.instTag(@fromBackingInt(i)) != .local) continue;
        const l = bir.instData(@fromBackingInt(i)).lhs;
        if (l >= d.locals_end - d.locals_start) continue;
        const binding = bir.locals[d.locals_start + l].inst.int();
        var f = fr[i];
        while (f != none) : (f = fr[f]) {
            const k = which.of(nested, f) orelse break;
            // Bound inside the code (its parameter, a pattern of its body,
            // its own name for a local function): no capture.
            if (binding == f or inside.f(fr, binding, f)) continue;
            if (std.mem.indexOfScalar(u32, caps.items[k].items, l) == null) try caps.items[k].append(gpa, l);
        }
    }
    // A local function a code calls by name: its captures are the caller's too.
    var changed = true;
    while (changed) {
        changed = false;
        for (nested, 0..) |c, k| {
            i = start;
            while (i < d.inst_end.int()) : (i += 1) {
                if (bir.instTag(@fromBackingInt(i)) != .local or !inside.f(fr, fr[i], c) and fr[i] != c) continue;
                const l = bir.instData(@fromBackingInt(i)).lhs;
                if (l >= d.locals_end - d.locals_start) continue;
                const binding = bir.locals[d.locals_start + l].inst.int();
                const g = which.of(nested, binding) orelse continue;
                if (g == k) continue;
                for (caps.items[g].items) |x| {
                    const xb = bir.locals[d.locals_start + x].inst.int();
                    if (xb == c or inside.f(fr, xb, c)) continue;
                    if (std.mem.indexOfScalar(u32, caps.items[k].items, x) == null) {
                        try caps.items[k].append(gpa, x);
                        changed = true;
                    }
                }
            }
        }
    }
}
