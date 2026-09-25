//! v2's check of one module (checker-v2.md §5): the per-module pipeline
//! P1–P9, run by `Driver.checkInner` for every module `Options.usesV2`
//! selects.
//!
//! **R4a: a stub.** Nothing here type-checks yet (`plans/checker-rewrite.md`
//! R4a). Every module v2 is given reports one `not_implemented`, "checker
//! v2: R4b", so a `--checker=v2` run exits 1 exactly as any failed check
//! does, and `zig build test-v2` can run the whole corpus against v2 before
//! v2 checks anything. R4b replaces the body with §5's phases.
//!
//! What the stub still owes the rest of the pipeline is what a failed v1
//! check leaves: `Types.ref_ids` for the module's record (every term reader
//! indexes it), and — under `dump --stage=types` — a `Check.Module` whose
//! tables are sized to the Bir, every entry `none`. It publishes no scheme;
//! the record keeps the shell resolution built, which the dumps print as
//! `<error>`. A module an earlier phase already reported on, or one the
//! graph poisoned, is checked silently, as v1's is (checker.md §4.3).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Artifacts = @import("../Artifacts.zig");
const Profile = @import("../Profile.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const Diagnostics = @import("../check/Diagnostics.zig");
const TypeStore = @import("../check/TypeStore.zig");
const Types = @import("../check/Types.zig");
const Check = @import("Check.zig");

pub const Error = Allocator.Error;

/// The message every module v2 checks reports until R4b.
pub const stub_message = "checker v2: R4b\n";

/// What `Driver.checkInner` hands v2 for one module.
pub const Input = struct {
    gpa: Allocator,
    graph: *const Graph,
    artifacts: *const Artifacts,
    interfaces: []Interface,
    types: *Types,
    module: Graph.Index,
    diagnostics: *std.ArrayList(Diagnostics.Item),
    quiet: bool,
    profile: ?*Profile,
    tid: u32 = 0,
    /// This module's slot of `Check.modules`, under `keep_stores`.
    keep: ?*Check.Module = null,
};

pub fn check(in: Input) Error!void {
    const gpa = in.gpa;
    const file = in.graph.moduleFile(in.module);
    const bir = in.artifacts.bir(file);
    // One `check` event per module, as v1 emits (checker.md §9).
    const token = if (in.profile) |p| p.begin() else null;
    defer if (in.profile) |p| p.end(in.tid, token.?, .check, file.int(), 0);

    const ref_ids = &in.types.ref_ids[in.module.int()];
    gpa.free(ref_ids.*);
    ref_ids.* = &.{};
    ref_ids.* = try in.types.resolveRefs(gpa, &in.interfaces[in.module.int()], in.graph);

    if (in.keep) |k| {
        k.decl_scheme = try noneTable(gpa, bir.decls.len);
        k.decl_display = try noneTable(gpa, bir.decls.len);
        k.local_type = try noneTable(gpa, bir.locals.len);
    }

    if (in.quiet or in.graph.isPoisoned(in.module)) return;
    const message = try gpa.dupe(u8, stub_message);
    errdefer gpa.free(message);
    // At the module's first token: the stub is about the whole module.
    try in.diagnostics.append(gpa, .{
        .code = .not_implemented,
        .module = in.module,
        .region = @enumFromInt(0),
        .token = 0,
        .message = message,
    });
}

fn noneTable(gpa: Allocator, len: usize) Error![]TypeStore.Var.Optional {
    const table = try gpa.alloc(TypeStore.Var.Optional, len);
    @memset(table, .none);
    return table;
}
