//! Compiler-produced descriptors. References are checked module/declaration ids;
//! paths are assigned before any projection lowers.
const Graph = @import("../resolve/Graph.zig");
const Plan = @import("../entry/Plan.zig");
pub const Descriptor = struct {
    module: Graph.Index,
    decl: u32,
    kind: Plan.KindIndex,
    identity: []const u8,
    id: []const u8,
    url: []const u8 = "",
    wire: ?*const @import("../check/Wire.zig").Artifact = null,
};
