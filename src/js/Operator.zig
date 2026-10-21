//! Compatibility import for the shared native-operation contract. The
//! checker and backend read the same identities, saturation and totality.
const Shared = @import("../Operator.zig");
pub const Which = Shared.Which;
pub const of = Shared.of;
pub const atCall = Shared.atCall;
pub const isBasicsAppend = Shared.isBasicsAppend;
pub const same = Shared.same;
