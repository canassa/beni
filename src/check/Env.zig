//! The per-module context the shared diagnostic texts read
//! (`Diagnostics.Reporter.env`): only what the texts read (checker-v2.md
//! §15.1). It is built only inside `Report.zig`.

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

/// One variable a `let` held at the enclosing rank rather than generalise
/// (checker-v2.md §8.4); see `Env.monomorphic`.
pub const Monomorphic = struct {
    v: Var,
    method: Symbol,
    why: Why,

    pub const Why = enum(u8) {
        /// Only dot-calls' own requirements ride on it (checker-v2.md
        /// §21.1, 2026-09-26): the call may still be a record's field.
        dot_call,
        /// A `let` value or pattern binding reaches it (the value
        /// restriction).
        value,
        /// No function binding of the `let` reaches it: it is decided, or
        /// defaulted, where it escapes to.
        unreached,
        /// A function binding over `max_inferred_constraints` (spike §10.11)
        /// is held whole, not generalised.
        cap,
    };
};

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
    /// this the hint on that message would tell the author to check their
    /// arithmetic.
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
