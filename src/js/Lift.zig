//! Lifted pieces (`docs/design/browser-inline.md` §7): what the compiler
//! needs to know of a lambda that its module lowers as an exported function
//! for a program site in another module — its name, the instruction range
//! its code is, and the locals of its declaration it reads. Read off `Bir`
//! alone, so every module answers for its own lambdas the same way in every
//! build (CLAUDE.md rule 5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");

const Inst = Bir.Inst;

/// One lifted piece, as the build lists it: lowered by `module` after its
/// declaration `decl`, named by `ordinal`, its code the instructions `lo`
/// to `inst`, the lambda last.
pub const Piece = struct {
    module: u32,
    decl: u32,
    inst: u32,
    lo: u32,
    ordinal: u32,
    /// The base of its name, `base(declaration, ordinal)`.
    name: []const u8,
    /// A lambda of the program's own module, lowered at the program site
    /// and not as a piece: a node only for what it reaches.
    in_place: bool = false,
    /// The locals of `decl`, numbered within it, that the lambda reads and
    /// its frame held a value of when it was made, in order: its captures.
    captures: []const u32,
};

/// The base of a piece's name, `<declaration>$$lift$<ordinal>`: `$` is in
/// no beni name, so no declaration can be called that.
pub fn base(scratch: Allocator, decl_name: []const u8, n: u32) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(scratch, "{s}$$lift${d}", .{ decl_name, n });
}

/// The lambda's place among the lambdas of its declaration, in instruction
/// order: what names it, so that an edit elsewhere does not move the name.
pub fn ordinal(bir: *const Bir, decl: u32, inst: u32) u32 {
    const d = bir.decls[decl];
    var n: u32 = 0;
    var at = d.inst_start.int();
    while (at < inst) : (at += 1) {
        if (bir.instTag(@fromBackingInt(at)) == .lambda) n += 1;
    }
    return n;
}

/// The first instruction of the code `inst` is: `Bir` writes an
/// expression's operands before it, so its code is a contiguous range that
/// ends at it.
pub fn low(bir: *const Bir, scratch: Allocator, inst: u32) Allocator.Error!u32 {
    var lo = inst;
    var stack: std.ArrayList(Inst.Index) = .empty;
    try stack.append(scratch, @fromBackingInt(inst));
    while (stack.pop()) |at| {
        lo = @min(lo, at.int());
        try children(bir, scratch, at, &stack);
    }
    return lo;
}

/// Every instruction of the code `root` is, but the code `skip` is (`null`:
/// none skipped): the walk `low` takes, for a test of its claim.
pub fn reach(bir: *const Bir, scratch: Allocator, root: u32, skip: ?u32) Allocator.Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList(Inst.Index) = .empty;
    try stack.append(scratch, @fromBackingInt(root));
    while (stack.pop()) |at| {
        if (skip) |s| if (at.int() == s) continue;
        try out.append(scratch, at.int());
        try children(bir, scratch, at, &stack);
    }
    return out.items;
}

/// Whether the code `inst` is reads local `local` of its declaration.
pub fn readsLocal(bir: *const Bir, scratch: Allocator, inst: u32, local: u32) Allocator.Error!bool {
    var stack: std.ArrayList(Inst.Index) = .empty;
    try stack.append(scratch, @fromBackingInt(inst));
    while (stack.pop()) |at| {
        if (bir.instTag(at) == .local and bir.instData(at).lhs == local) return true;
        try children(bir, scratch, at, &stack);
    }
    return false;
}

/// The instructions an expression's value is made of; patterns and types
/// are not among them. The same walk as `Lower.instChildren`.
fn children(bir: *const Bir, scratch: Allocator, inst: Inst.Index, out: *std.ArrayList(Inst.Index)) Allocator.Error!void {
    const d = bir.instData(inst);
    const one = struct {
        fn of(x: u32) Inst.Index {
            return @fromBackingInt(@intCast(x));
        }
    }.of;
    switch (bir.instTag(inst)) {
        .call => {
            try out.append(scratch, one(d.lhs));
            try out.appendSlice(scratch, bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index));
        },
        .method_call => {
            try out.append(scratch, one(d.lhs));
            const mc = bir.extraData(@fromBackingInt(@intCast(d.rhs)), Bir.MethodCall);
            try out.appendSlice(scratch, bir.extraSlice(.{ .start = mc.args_start, .end = mc.args_end }, Inst.Index));
        },
        .type_dispatch => {
            const t = bir.extraData(@fromBackingInt(@intCast(d.rhs)), Bir.TypeDispatch);
            try out.appendSlice(scratch, bir.extraSlice(.{ .start = t.args_start, .end = t.args_end }, Inst.Index));
        },
        .let => {
            for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.lhs))), Inst.Index)) |def| {
                const dd = bir.instData(def);
                switch (bir.instTag(def)) {
                    .let_def, .let_pattern, .let_stmt => try out.append(scratch, one(dd.rhs)),
                    else => {},
                }
            }
            try out.append(scratch, one(d.rhs));
        },
        .case => {
            try out.append(scratch, one(d.lhs));
            for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index)) |branch| {
                if (bir.instTag(branch) == .branch) try out.append(scratch, one(bir.instData(branch).rhs));
            }
        },
        .@"try", .field_access, .tuple_index => try out.append(scratch, one(d.lhs)),
        .tuple, .list, .interp => try out.appendSlice(scratch, bir.extraSlice(Bir.inlineRange(d), Inst.Index)),
        .record => for (bir.extraSlice(Bir.inlineRange(d), Bir.Field)) |f| try out.append(scratch, f.value),
        .record_update => {
            try out.append(scratch, one(d.lhs));
            for (bir.extraSlice(bir.subRange(@fromBackingInt(@intCast(d.rhs))), Bir.Field)) |f| try out.append(scratch, f.value);
        },
        .lambda => try out.append(scratch, one(d.rhs)),
        else => {},
    }
}
