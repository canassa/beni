//! The per-module context the shared diagnostic texts read
//! (`Diagnostics.Reporter.env`). Moved out of v1's `Constrain.zig` by R4b's
//! review (S2), so the texts would not depend on it; R12 deleted v1 and with
//! it every field only v1's generator and solver read; R13 the two no text
//! read (`artifacts`, `schemas`: checker-v2.md §15.1). It is built only
//! inside `Report.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const reads = @import("reads.zig");
const TypeStore = @import("TypeStore.zig");
const Types = @import("Types.zig");

pub const Var = TypeStore.Var;
pub const Symbol = InternPool.Symbol;
pub const Error = Allocator.Error;

/// One `let` binding rule (a) refused to generalise; see `Env.monomorphic`.
pub const Monomorphic = struct { v: Var, method: Symbol };

/// What the texts read of one module's check: its own Bir, the interfaces
/// of its imports and the store it owns (checker.md §4.4).
pub const Env = struct {
    scratch: Allocator,
    store: *TypeStore,
    types: *const Types,
    graph: *const Graph,
    interner: *const InternPool.Global,
    interfaces: []const Interface,
    module: Graph.Index,
    bir: *const Bir,
    /// Scheme variable per top-level declaration; `.none` for a type or for
    /// a value whose scheme is not built yet.
    decl_scheme: []Var.Optional,
    /// Per local of the declaration being checked. Indices in the Bir are
    /// relative to the declaration, so this is a SLICE of the module's
    /// table and `locals_base` is where it starts — anything that reaches
    /// past this slice into `bir.locals` has to add it.
    local_var: []Var.Optional,
    /// The declaration's `locals_start`.
    locals_base: u32 = 0,
    /// Every variable §6.4 rule (a) held back from a `let` generalisation,
    /// with the constraint that held it.
    ///
    /// It exists for ONE message. The boundary A.30 buys surfaces as an
    /// ordinary `type_mismatch` at the second use, by which time the
    /// constraint has been discharged against the first use's type and
    /// nothing in the store says why the binding was monomorphic. Without
    /// this the hint on that message told the author to check their
    /// arithmetic (M7).
    monomorphic: *std.ArrayList(Monomorphic),
    /// Another module's interface record, noted for the covered-read
    /// self-check (`reads.zig`, `plans/m4-3.md` §3.2 rows 17–22 and 25–27).
    ///
    /// **Every cross-module read of `interfaces` on the checking path goes
    /// through this**, which is what makes the `&interfaces[N]` handoff one of
    /// the three channels the enumeration is finite over. Callers keep their
    /// own bounds tests: this is a note, not a guard.
    pub fn iface(env: *const Env, m: Graph.Index) *const Interface {
        reads.note(.iface, m);
        return &env.interfaces[m.int()];
    }

    pub fn localVar(env: *const Env, index: u32) ?Var {
        if (index >= env.local_var.len) return null;
        return env.local_var[index].unwrap();
    }
};
