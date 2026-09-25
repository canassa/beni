//! Which later slice a module needs, if any (checker-v2.md §5, *As built by
//! R4b*, as widened by R5; `plans/checker-rewrite.md` R4b, R5).
//!
//! v2 checks the modules whose own code needs **no dispatch**: from R5 the
//! obligation forms (`e.i`, `${…}`, `e?`, an `equatable` annotation
//! variable, explicit `Basics.eq`/`neq`) are checked too. One scan of the
//! module's Bir, before anything is checked, finds what else it would need
//! and names the slice that brings it:
//!
//!   - **R6a** — dispatch: a `method_call` or `type_dispatch`, a `where`
//!     clause, or an imported value, schema member or schema constructor
//!     whose scheme carries a method constraint.
//!
//! A module that declares a `type` is checked (the manager's decision on
//! R4b's review, S8): only a `--library` build needs the eager derived rows
//! v2 does not write (P5, R8a), and `js/Emit.zig` refuses that build.
//!
//! The answer is reported at the first construct (in declaration, then
//! instruction, order) that needs it: a function of the source (rule 5). A
//! module outside the subset reports that one `not_implemented` and nothing
//! else, so v2 never answers for code it does not yet check.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const reads = @import("../check/reads.zig");

pub const Slice = enum(u8) {
    r6a,

    pub fn name(s: Slice) []const u8 {
        return switch (s) {
            .r6a => "R6a",
        };
    }

    /// What the module does that the slice brings, for the message.
    pub fn reason(s: Slice) []const u8 {
        return switch (s) {
            .r6a => "it calls a method (`x.m`, `==`, `<`, an operator section) or needs a `where`\nclause, which v2 does not resolve yet",
        };
    }
};

pub const Missing = struct {
    slice: Slice,
    /// The construct, when it is an instruction.
    region: Bir.Inst.Index,
    /// The token to underline instead, for a declaration with no
    /// instruction of its own (a `type`'s name).
    token: ?u32,
};

/// The latest slice `bir` needs, and where it first needs it; null when the
/// module is in v2's subset.
pub fn scan(bir: *const Bir, interfaces: []const Interface) ?Missing {
    var found: ?Missing = null;
    const note = struct {
        fn f(out: *?Missing, slice: Slice, region: Bir.Inst.Index, token: ?u32) void {
            if (out.*) |m| {
                if (@intFromEnum(m.slice) >= @intFromEnum(slice)) return;
            }
            out.* = .{ .slice = slice, .region = region, .token = token };
        }
    }.f;
    for (bir.decls) |d| {
        if (d.where_start != d.where_end) note(&found, .r6a, d.annotation.unwrap() orelse d.inst_start, null);
        var i = d.inst_start.int();
        while (i < d.inst_end.int() and i < bir.insts.len) : (i += 1) {
            const inst: Bir.Inst.Index = @enumFromInt(i);
            const data = bir.instData(inst);
            switch (bir.instTag(inst)) {
                .method_call, .type_dispatch => note(&found, .r6a, inst, null),
                .ext_value, .ext_schema_member, .ext_schema_ctor => {
                    if (importedNeeds(interfaces, bir.instTag(inst), data)) |slice| note(&found, slice, inst, null);
                },
                else => {},
            }
        }
    }
    return found;
}

/// What an imported scheme's quantifiers need: a method constraint is
/// R6a's. An `equatable` quantifier (`Basics.eq`/`neq`) is R5's, and v2 has
/// it.
fn importedNeeds(interfaces: []const Interface, tag: Bir.Inst.Tag, data: Bir.Inst.Data) ?Slice {
    const module: Graph.Index = @enumFromInt(data.lhs);
    if (module.int() >= interfaces.len) return null;
    // A read of another module's record decides this module's output, so
    // the covered-read self-check hears of it (`reads.zig`).
    reads.note(.iface, module);
    const iface = &interfaces[module.int()];
    const index = data.rhs;
    const scheme_index = switch (tag) {
        .ext_value => if (index < iface.values.len) iface.values[index].scheme else return null,
        .ext_schema_member => if (index < iface.schema_members.len) iface.schema_members[index].scheme else return null,
        .ext_schema_ctor => if (index < iface.schema_ctors.len) iface.schema_ctors[index].scheme else return null,
        else => return null,
    };
    if (scheme_index == .none) return null;
    const s = iface.schemes[@intFromEnum(scheme_index)];
    for (0..s.quantified_count) |q| {
        if (iface.quantified(s, @intCast(q)).constraints_len != 0) return .r6a;
    }
    return null;
}
