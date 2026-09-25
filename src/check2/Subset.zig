//! Which modules checker v2 checks but cannot yet BUILD (checker-v2.md §5,
//! *As built by R4b*, as widened by R5 and R6a; `plans/checker-rewrite.md`
//! R6a, R6b).
//!
//! From R6a v2 checks every construct: `check` runs P0–P4 and P7–P9 on any
//! module. What it does not do before R6b is **P6, elaboration**: the
//! evidence trees `Lower` reads (§12.2, §13). So a module whose own code
//! needs evidence — a `method_call` or `type_dispatch` (every `x.m`, `==`,
//! `<`, operator section), a `where` clause, or a reference to an imported
//! value, schema member or schema constructor whose scheme carries a method
//! requirement — may be checked, and its dispatch table read by `Cycles`,
//! but not lowered. Two consumers ask this scan:
//!
//!   - `js/Emit.zig`, which refuses to build such a module under
//!     `--checker=v2` before any output exists (like a schema, or R8a's
//!     `--library` types);
//!   - `dump --stage=dispatch` (`main.zig`), whose table would be v2's
//!     partial one.
//!
//! Each refusal is ONE `not_implemented`, at the first construct in
//! declaration, then instruction, order: a function of the source (rule 5).
//! The scan reads only the module's Bir and its imports' interfaces, so it
//! answers the same on a cache hit as on a check.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const reads = @import("../check/reads.zig");

pub const Missing = struct {
    /// The construct, when it is an instruction.
    region: Bir.Inst.Index,
    /// The token to underline instead (a declaration's name).
    token: ?u32,
};

/// Why the build is refused, for the message.
pub const reason = "checker v2 does not elaborate evidence until slice R6b: this module calls a method (`x.m`, `==`, `<`, an operator section) or needs a `where` clause.";

/// The first construct of `bir` that needs evidence elaborated, or null.
pub fn needsElaboration(bir: *const Bir, interfaces: []const Interface) ?Missing {
    for (bir.decls) |d| {
        if (d.where_start != d.where_end) return .{ .region = d.annotation.unwrap() orelse d.inst_start, .token = d.name_token };
        var i = d.inst_start.int();
        while (i < d.inst_end.int() and i < bir.insts.len) : (i += 1) {
            const inst: Bir.Inst.Index = @enumFromInt(i);
            switch (bir.instTag(inst)) {
                .method_call, .type_dispatch => return .{ .region = inst, .token = null },
                .ext_value, .ext_schema_member, .ext_schema_ctor => {
                    if (importedNeeds(interfaces, bir.instTag(inst), bir.instData(inst))) return .{ .region = inst, .token = null };
                },
                else => {},
            }
        }
    }
    return null;
}

/// Whether an imported scheme's quantifiers carry a method requirement.
fn importedNeeds(interfaces: []const Interface, tag: Bir.Inst.Tag, data: Bir.Inst.Data) bool {
    const module: Graph.Index = @enumFromInt(data.lhs);
    if (module.int() >= interfaces.len) return false;
    // A read of another module's record decides this module's output, so
    // the covered-read self-check hears of it (`reads.zig`).
    reads.note(.iface, module);
    const iface = &interfaces[module.int()];
    const index = data.rhs;
    const scheme_index = switch (tag) {
        .ext_value => if (index < iface.values.len) iface.values[index].scheme else return false,
        .ext_schema_member => if (index < iface.schema_members.len) iface.schema_members[index].scheme else return false,
        .ext_schema_ctor => if (index < iface.schema_ctors.len) iface.schema_ctors[index].scheme else return false,
        else => return false,
    };
    if (scheme_index == .none) return false;
    const s = iface.schemes[@intFromEnum(scheme_index)];
    for (0..s.quantified_count) |q| {
        if (iface.quantified(s, @intCast(q)).constraints_len != 0) return true;
    }
    return false;
}
