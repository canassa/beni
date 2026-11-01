//! Actual checked generated-body consumer. No runtime or storage certification.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("../Session.zig");
const Graph = @import("../resolve/Graph.zig");
const Bir = @import("../bir/Bir.zig");
const Build = @import("../check/ControlBuild.zig");
const Generated = @import("../check/GeneratedUnit.zig");
const Proof = @import("../check/ControlProof.zig");
pub const Prepared = struct {
    bytes: []u8,
    /// Owned in the command arena, including generated paths and excerpts.
    foreign: Session.Foreign = .{},
    pub fn deinit(p: *Prepared, gpa: Allocator) void {
        gpa.free(p.bytes);
        p.* = undefined;
    }
};
pub const Error = Build.Error || Generated.Error || Proof.Error;
pub fn prepare(gpa: Allocator, diagnostic_owner: Allocator, io: std.Io, source: *Session, tamper: Build.Tamper, diagnostics: *std.Io.Writer, failure_reported: *bool) Error!Prepared {
    failure_reported.* = false;
    var inputs: std.ArrayList(Build.Input) = .empty;
    defer inputs.deinit(gpa);
    for (0..source.graph.count()) |mi| {
        const module: Graph.Index = @fromBackingInt(@intCast(mi));
        if (source.graph.modulePackage(module) != .app) continue;
        const table = &source.checked.dispatch[mi];
        if (!table.control_sources.present or !try table.control_sources.verifyAgainstBir(gpa, source.artifacts.bir(source.graph.moduleFile(module)), table, &source.interner)) return error.MissingEvidence;
        try inputs.append(gpa, .{ .module = module, .bir = source.artifacts.bir(source.graph.moduleFile(module)), .plan = &table.control_sources, .dispatch = table });
    }
    var batch = try Build.produce(gpa, inputs.items, &source.interner, tamper);
    defer batch.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    if (batch.members.len == 0) {
        try Proof.verifyInventory(gpa, &batch, inputs.items, &source.interner);
        w.print("checked-controls schema=1 supported=0 unsupported={d} sourceRegionMapped=false generatedBodyTypechecked=false taskMigrated=false\n", .{batch.unsupported}) catch return error.OutOfMemory;
        try writeOwnershipReports(gpa, w, "source", source);
        try writeSourceEvidence(w, inputs.items, source);
        return .{ .bytes = try out.toOwnedSlice() };
    }
    var origin_arena: std.heap.ArenaAllocator = .init(gpa);
    defer origin_arena.deinit();
    const failure_origins = try source.exportLate(origin_arena.allocator(), try originItems(origin_arena.allocator(), source, &batch, inputs.items, "GeneratedCheckFailed"));
    const generated_profile = if (source.options.self_profile) |path|
        try std.fmt.allocPrint(gpa, "{s}.checked-controls.json", .{path})
    else
        null;
    // Declared before unit's defer: its borrowed option stays alive until the
    // independent Session is deinitialized, on success and every error path.
    defer if (generated_profile) |path| gpa.free(path);
    var unit = Generated.checkRuntime(gpa, io, .{ .batch = &batch, .inputs = inputs.items, .interner = &source.interner, .tamper = tamper }, .{ .failure_origins = failure_origins, .self_profile = generated_profile, .jobs = source.options.jobs, .diagnostics = source.options.diagnostics, .ownership_v2 = source.options.ownership_v2, .ownership_everywhere = source.enforce_ownership or source.options.ownership_everywhere }, diagnostics) catch |err| {
        // GeneratedCheckFailed is returned only after ordinary rendering succeeds.
        if (err == error.GeneratedCheckFailed) failure_reported.* = true;
        return err;
    };
    defer unit.deinit(gpa);
    const gm = unit.root;
    const generated_bir = unit.bir();
    var receipts = Proof.verify(gpa, &batch, inputs.items, .{ .bir = generated_bir, .graph = &unit.session.graph, .interfaces = unit.session.resolution.interfaces, .iface = unit.iface(), .provenance = &unit.session.resolution.provenance[gm.int()], .dispatch = unit.dispatch(), .interner = &unit.session.interner }, &source.interner) catch |err| {
        const previous = source.foreign;
        source.foreign = try unit.session.exportLate(origin_arena.allocator(), &.{});
        defer source.foreign = previous;
        try reportOrigins(gpa, source, &batch, inputs.items, @errorName(err), diagnostics);
        failure_reported.* = true;
        return err;
    };
    defer receipts.deinit(gpa);
    w.print("checked-controls schema=1 supported={d} unsupported={d} sourceRegionMapped=true generatedBodyTypechecked=true producerModelChecked=true actualTaskProducerProved=false runtimeRepresentationProved=false taskMigrated=false C=false launch=false sourceOwnershipEnforced={} generatedOwnershipEnforced={} ownershipV2={} owningStorageProved=false batches=1\n", .{ receipts.len, batch.unsupported, source.enforce_ownership, unit.session.enforce_ownership, source.options.ownership_v2 }) catch return error.OutOfMemory;
    try writeOwnershipReports(gpa, w, "source", source);
    try writeOwnershipReports(gpa, w, "generated", unit.session);
    for (0..receipts.len) |i| {
        const receipt = receipts.get(i);
        const generated_effects = @import("../resolve/Interface.zig").effectBlock(unit.iface(), unit.iface().schemes[@backingInt(receipt.job_scheme)]).?;
        const result_class = generated_effects.class(receipt.job_class);
        w.print("  job-class {d} factory={d} packer={d} scheme={d} resultClass={d} sync=true rawDeps={d} unresolvedDeps=0\n", .{ i, receipt.job.int(), receipt.pack.int(), @backingInt(receipt.job_scheme), receipt.job_class, result_class.deps.len }) catch return error.OutOfMemory;
        const member = batch.members.get(receipt.member);
        const in = inputs.items[member.input];
        const region = in.plan.regions.get(@backingInt(member.region));
        w.print("  body {d} source={s} decl={d} site={d} region={d} operations={d} captures={d} checkedRemainder={d} checkedControl={d}\n", .{ i, source.interner.slice(source.graph.moduleName(member.module)), region.decl.int(), region.suspension.int(), @backingInt(member.region), receipt.source_operations, receipt.captures, receipt.remainder.int(), receipt.control.int() }) catch return error.OutOfMemory;
        if (region.input_kind == .bound_int) w.print("    resumed-input local={d} definition={d} scope={d} type={d} output={d} binding=bound_int\n", .{ region.input_local, region.input_definition, @backingInt(region.scheme), region.input.int(), region.output.int() }) catch return error.OutOfMemory;
        for (0..region.captures.len) |ci| {
            const capture = in.plan.captures.get(region.captures.start + ci);
            w.print("    capture {d} local={d} definition={d} scope={d} parameter={d} type={d}\n", .{ ci, capture.local, capture.definition.int(), @backingInt(region.scheme), capture.parameter, capture.type.int() }) catch return error.OutOfMemory;
        }
        for (result_class.deps) |dependency| {
            var paths = generated_effects.sites();
            while (paths.next()) |path| {
                const Interface = @import("../resolve/Interface.zig");
                if (path.class != dependency or path.root != 0 or path.steps.len != 1 or Interface.EffectBlock.stepKind(path.steps[0]) != 0) continue;
                const parameter = Interface.EffectBlock.stepIndex(path.steps[0]);
                if (parameter < 2 or parameter - 2 >= region.captures.len) continue;
                const ci = parameter - 2;
                const capture = in.plan.captures.get(region.captures.start + ci);
                const source_class = Build.sourceCaptureClass(in, region, ci) orelse continue;
                w.print("    dependency sourceScope={d} BODY.param={d} sourceClass={d} -> factory.param={d} class={d} checkedSync=true\n", .{ @backingInt(region.scheme), capture.parameter, source_class, parameter, dependency }) catch return error.OutOfMemory;
            }
        }
        const decl = generated_bir.decl(receipt.remainder);
        for (decl.inst_start.int()..decl.inst_end.int()) |ii| {
            const inst: Bir.Inst.Index = @fromBackingInt(@intCast(ii));
            const data = generated_bir.instData(inst);
            w.print("    checked-inst {d} {t} lhs={d} rhs={d}\n", .{ ii, generated_bir.instTag(inst), data.lhs, data.rhs }) catch return error.OutOfMemory;
        }
    }
    try writeSourceEvidence(w, inputs.items, source);
    @import("interface.zig").writeRaw(w, "GeneratedControls", &unit.session.resolution.interfaces[gm.int()], &unit.session.interner) catch return error.OutOfMemory;
    w.writeAll("generated-ordinary-source\n") catch return error.OutOfMemory;
    w.writeAll(unit.source) catch return error.OutOfMemory;
    const foreign = try ownForeign(diagnostic_owner, try unit.session.exportLate(diagnostic_owner, &.{}));
    return .{ .bytes = try out.toOwnedSlice(), .foreign = foreign };
}

fn writeSourceEvidence(w: *std.Io.Writer, inputs: []const Build.Input, source: *const Session) Allocator.Error!void {
    const Interface = @import("../resolve/Interface.zig");
    for (inputs) |in| {
        const name = source.interner.slice(source.graph.moduleName(in.module));
        const original = &in.dispatch.continuations;
        const types = &original.types;
        for (0..original.scopes.len) |si| {
            const scope = original.scopes.get(si);
            const scheme = types.schemes[@backingInt(scope.scheme)];
            const roots = types.range(types.term(scheme.body).lhs);
            w.print("  source-scope module={s} decl={d} scheme={d} owner={d} BODY={d}\n", .{ name, scope.decl.int(), @backingInt(scope.scheme), roots[0], roots[1] }) catch return error.OutOfMemory;
            for (roots[0..2], 0..) |root, projection| {
                const term = types.term(@fromBackingInt(root));
                if (term.tag != .func) continue;
                for (types.range(term.lhs), 0..) |parameter, ordinal| {
                    w.print("    source-parameter module={s} decl={d} scheme={d} {s}.param={d} type={d} directFunction={} effectAuthority=published-paths\n", .{ name, scope.decl.int(), @backingInt(scope.scheme), if (projection == 0) "OWNER" else "BODY", ordinal, parameter, types.term(@fromBackingInt(parameter)).tag == .func }) catch return error.OutOfMemory;
                }
            }
            if (Interface.effectBlock(types, scheme)) |block| {
                var paths = block.sites();
                while (paths.next()) |path| {
                    if (path.root != 0 or path.steps.len != 2 or Interface.EffectBlock.stepKind(path.steps[0]) != 3 or Interface.EffectBlock.stepIndex(path.steps[0]) != 1 or Interface.EffectBlock.stepKind(path.steps[1]) != 0) continue;
                    const class = block.class(path.class);
                    w.print("    source-callback module={s} decl={d} scheme={d} BODY.param={d} class={d} sync={} rung={d} sensitive={} rawDeps={d}\n", .{ name, scope.decl.int(), @backingInt(scope.scheme), Interface.EffectBlock.stepIndex(path.steps[1]), path.class, class.sync, class.rung, class.sensitive, class.deps.len }) catch return error.OutOfMemory;
                }
            }
            for (0..scope.len) |j| {
                const index = scope.start + j;
                const site = original.sites.get(index);
                const selected = in.plan.sites.get(index);
                const reason: Build.Support = if (selected.region == .none) .source_shape else Build.supportReason(in, in.plan.regions.get(@backingInt(selected.region)), &source.interner);
                w.print("  source-site module={s} decl={d} scheme={d} inst={d} type={d} own={t} body={t} state={s} reason={t}\n", .{ name, scope.decl.int(), @backingInt(scope.scheme), site.inst.int(), site.type.int(), site.own, site.body, if (reason == .supported) "body-checked" else "uncertified", reason }) catch return error.OutOfMemory;
            }
        }
        @import("interface.zig").writeRaw(w, name, types, &source.interner) catch return error.OutOfMemory;
    }
}

fn ownForeign(a: Allocator, foreign: Session.Foreign) Allocator.Error!Session.Foreign {
    const items = try a.dupe(@import("diagnostic").Diagnostic, foreign.diagnostics);
    for (items) |*item| {
        item.span.file = try a.dupe(u8, item.span.file);
        item.message = try a.dupe(u8, item.message);
        item.title = try a.dupe(u8, item.title);
    }
    const sources = try a.dupe(Session.LateSource, foreign.sources);
    // exportLate(empty) exports ordinary held diagnostics in sorted file
    // order. Each file uses its actual SourceStore buffer, so repeated
    // excerpts are contiguous and need only one owned source copy.
    var previous: ?[]const u8 = null;
    var owned: []const u8 = &.{};
    for (sources) |*item| {
        item.span.file = try a.dupe(u8, item.span.file);
        if (item.source) |bytes| {
            if (previous == null or previous.?.ptr != bytes.ptr or previous.?.len != bytes.len) {
                owned = try a.dupe(u8, bytes);
                previous = bytes;
            }
            item.source = owned;
        }
    }
    return .{ .diagnostics = items, .sources = sources };
}

fn originItems(gpa: Allocator, source: *Session, batch: *const Build.Batch, inputs: []const Build.Input, reason: []const u8) Allocator.Error![]const Session.LateItem {
    var items: std.ArrayList(Session.LateItem) = .empty;
    for (0..batch.members.len) |i| {
        const member = batch.members.get(i);
        if (member.input >= inputs.len) continue;
        const in = inputs[member.input];
        if (@backingInt(member.region) >= in.plan.regions.len) continue;
        const region = in.plan.regions.get(@backingInt(member.region));
        const message = try std.fmt.allocPrint(gpa, "Generated ordinary body rest{d}/control{d} is mapped from this source suspension and body {d}; the batch failed checking or provenance ({s}). No checked-control receipt was printed. This is compiler evidence, not a new source type rule.", .{ i, i, region.body.int(), reason });
        try items.append(gpa, .{ .code = .internal, .file = source.graph.moduleFile(member.module), .token = in.bir.insts.items(.main_token)[region.suspension.int()], .message = message });
    }
    return try items.toOwnedSlice(gpa);
}

fn reportOrigins(gpa: Allocator, source: *Session, batch: *const Build.Batch, inputs: []const Build.Input, reason: []const u8, diagnostics: *std.Io.Writer) Session.RunError!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    _ = try source.renderLate(try originItems(arena.allocator(), source, batch, inputs, reason), diagnostics);
}

/// Print retained ordinary own2 evidence; never invoke a second checker or turn
/// zero demands / an absent report into a complete ownership certificate.
fn writeOwnershipReports(gpa: Allocator, w: *std.Io.Writer, label: []const u8, session: *Session) Allocator.Error!void {
    if (!session.options.ownership_v2) return;
    const Report = @import("../own2/Report.zig");
    const names = try gpa.alloc([]const u8, session.graph.count());
    defer gpa.free(names);
    for (names, 0..) |*name, mi| name.* = session.interner.slice(session.graph.moduleName(@fromBackingInt(@intCast(mi))));
    w.print("ownership-v2-report {s} owningStorageProved=false\n", .{label}) catch return error.OutOfMemory;
    for (0..session.graph.count()) |mi| {
        if (session.graph.modulePackage(@fromBackingInt(@intCast(mi))) != .app) continue;
        if (mi < session.ownership2_reports.len) if (session.ownership2_reports[mi]) |kept| {
            var reports = [_]Report.Module{kept.report};
            Report.write(w, &reports, names, .{}) catch return error.OutOfMemory;
            continue;
        };
        w.print("module {s} ownership-report=unavailable\n", .{names[mi]}) catch return error.OutOfMemory;
    }
}
