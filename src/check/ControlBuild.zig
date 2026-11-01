//! Produce actual straight-line source remainders as ordinary declarations.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("../resolve/Graph.zig");
const Bir = @import("../bir/Bir.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const Source = @import("ControlSourcePlan.zig");
const Dispatch = @import("Dispatch.zig");
pub const Tamper = enum { none, wrong_input_slot, direct_input, parked_input, wrong_slot, same_type_operand, scaffold_return_slot, drop_region, duplicate_region, suspending_job, ownership_conflict };
pub const Support = enum { supported, source_shape, binder_contract, callback_contract, type_shape };
pub const Input = struct { module: Graph.Index, bir: *const Bir, plan: *const Source.Artifact, dispatch: *const Dispatch };
pub const Member = struct { module: Graph.Index, input: u32, region: Source.RegionIndex };
pub const Batch = struct {
    source: []u8 = &.{},
    members: std.MultiArrayList(Member) = .empty,
    unsupported: u32 = 0,
    pub fn deinit(b: *Batch, gpa: Allocator) void {
        gpa.free(b.source);
        b.members.deinit(gpa);
        b.* = .{};
    }
};
pub const Error = Allocator.Error || error{ MissingEvidence, UnsupportedTamper };
pub fn produce(gpa: Allocator, inputs: []const Input, interner: *const InternPool.Global, tamper: Tamper) Error!Batch {
    var batch: Batch = .{};
    errdefer batch.deinit(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    if (tamper == .suspending_job) w.writeAll("import Task\n") catch return error.OutOfMemory;
    w.writeAll("import Ref\nimport Debug\n\ntype alias Slot a = Ref.Ref (Maybe a)\n\ntype Control a = Direct a | Parked (Slot a)\n\n") catch return error.OutOfMemory;
    for (inputs, 0..) |in, ii| {
        if (!in.plan.present) return error.MissingEvidence;
        for (0..in.plan.sites.len) |si| {
            const site = in.plan.sites.get(si);
            if (site.region == .none) {
                batch.unsupported += 1;
                continue;
            }
            const region = in.plan.regions.get(@backingInt(site.region));
            if (supportReason(in, region, interner) != .supported) {
                batch.unsupported += 1;
                continue;
            }
            try batch.members.append(gpa, .{ .module = in.module, .input = @intCast(ii), .region = site.region });
        }
    }
    if (batch.members.len != 0) {
        w.writeAll("type Job\n") catch return error.OutOfMemory;
        for (0..batch.members.len) |i| w.print("    {s} Site{d} (⊤ → ⊤)\n", .{ if (i == 0) "=" else "|", i }) catch return error.OutOfMemory;
        w.writeAll("\npub sealJob : sync (⊤ → ⊤) → (⊤ → ⊤)\nsealJob run = run\n\n") catch return error.OutOfMemory;
    }
    const offsets = try gpa.alloc(usize, inputs.len + 1);
    defer gpa.free(offsets);
    offsets[0] = 0;
    for (inputs, 0..) |in, i| offsets[i + 1] = offsets[i] + in.bir.locals.len;
    const capture_slots = try gpa.alloc(u32, offsets[inputs.len]);
    defer gpa.free(capture_slots);
    @memset(capture_slots, std.math.maxInt(u32));
    var tampered = false;
    for (0..batch.members.len) |mi| {
        const member = batch.members.get(mi);
        const in = inputs[member.input];
        const r = in.plan.regions.get(@backingInt(member.region));
        const source_decl = in.bir.decl(r.decl);
        const positions = capture_slots[offsets[member.input] + source_decl.locals_start .. offsets[member.input] + source_decl.locals_end];
        for (0..r.captures.len) |ci| positions[in.plan.captures.get(r.captures.start + ci).local] = @intCast(ci);
        const types = &in.dispatch.continuations.types;
        // Source-rigid helper annotations prevent tampered outputs from merely
        // specializing a mutually inferred generated variable.
        const bound_input = r.input_kind == .bound_int;
        w.print("pub rest{d} : ", .{mi}) catch return error.OutOfMemory;
        if (bound_input) {
            try writeType(w, types, r.input, interner, false);
            w.writeAll(", ") catch return error.OutOfMemory;
        }
        for (0..r.captures.len) |ci| {
            if (ci != 0) w.writeAll(", ") catch return error.OutOfMemory;
            try writeType(w, types, in.plan.captures.get(r.captures.start + ci).type, interner, ci == 0);
        }
        w.writeAll(" → ") catch return error.OutOfMemory;
        try writeType(w, types, r.output, interner, false);
        w.print("\nrest{d}", .{mi}) catch return error.OutOfMemory;
        if (bound_input) w.writeAll(" resumed") catch return error.OutOfMemory;
        for (0..r.captures.len) |ci| w.print(" c{d}", .{ci}) catch return error.OutOfMemory;
        w.writeAll(" = ") catch return error.OutOfMemory;
        const call = in.bir.instData(r.body);
        const source_callee = in.bir.instData(@fromBackingInt(call.lhs)).lhs;
        w.print("c{d}", .{try capturePosition(positions, source_callee)}) catch return error.OutOfMemory;
        const args = in.bir.extraSlice(in.bir.subRange(@fromBackingInt(call.rhs)), Bir.Inst.Index);
        const swap = tamper == .same_type_operand and !tampered and args.len >= 2 and
            sameFixtureType(types, try operandType(in, r, positions, args[0]), try operandType(in, r, positions, args[1]));
        for (args, 0..) |arg, ai| {
            var actual = arg;
            if (swap) {
                actual = args[if (ai == 0) 1 else if (ai == 1) 0 else ai];
            }
            const local = in.bir.instData(actual).lhs;
            if (bound_input and local == r.input_local) w.writeAll(" resumed") catch return error.OutOfMemory else w.print(" c{d}", .{try capturePosition(positions, local)}) catch return error.OutOfMemory;
        }
        if (swap) tampered = true;
        w.print("\n\npub job{d} : Slot ", .{mi}) catch return error.OutOfMemory;
        if (tamper == .wrong_input_slot and bound_input and !tampered) {
            w.writeAll("String") catch return error.OutOfMemory;
            tampered = true;
        } else try writeType(w, types, r.input, interner, false);
        w.writeAll(", Slot ") catch return error.OutOfMemory;
        try writeType(w, types, r.output, interner, false);
        for (0..r.captures.len) |ci| {
            w.writeAll(", ") catch return error.OutOfMemory;
            try writeType(w, types, in.plan.captures.get(r.captures.start + ci).type, interner, ci == 0);
        }
        w.writeAll(" → (⊤ → ⊤)\n") catch return error.OutOfMemory;
        w.print("job{d} input output", .{mi}) catch return error.OutOfMemory;
        for (0..r.captures.len) |ci| w.print(" c{d}", .{ci}) catch return error.OutOfMemory;
        w.writeAll(" =\n    sealJob λ⊤ →\n") catch return error.OutOfMemory;
        if (tamper == .suspending_job and !tampered) {
            w.writeAll("        Task.yieldNow ⊤\n") catch return error.OutOfMemory;
            tampered = true;
        }
        w.writeAll("        case Ref.get input of\n            Nothing →\n                Debug.todo \"missing generated input slot\"\n\n            Just ") catch return error.OutOfMemory;
        w.writeAll(if (bound_input) "resumed" else "⊤") catch return error.OutOfMemory;
        w.writeAll(" →\n                Ref.set output (Just (") catch return error.OutOfMemory;
        const corrupt_parked = tamper == .parked_input and bound_input and !tampered and r.captures.len > 1 and isInt(types, in.plan.captures.get(r.captures.start + 1).type, interner);
        try writeRestCall(w, mi, r.captures.len, if (corrupt_parked) "c1" else if (bound_input) "resumed" else null);
        if (corrupt_parked) tampered = true;
        w.writeAll("))\n\n") catch return error.OutOfMemory;
        w.print("pub pack{d} : sync (⊤ → ⊤) → Job\npack{d} run = Site{d} run\n\n", .{ mi, mi, mi }) catch return error.OutOfMemory;
        w.print("pub control{d} : Control ", .{mi}) catch return error.OutOfMemory;
        try writeType(w, types, r.input, interner, false);
        for (0..r.captures.len) |ci| {
            w.writeAll(", ") catch return error.OutOfMemory;
            try writeType(w, types, in.plan.captures.get(r.captures.start + ci).type, interner, ci == 0);
        }
        w.writeAll(" → Control ") catch return error.OutOfMemory;
        try writeType(w, types, r.output, interner, false);
        w.writeAll(" × Maybe Job\n") catch return error.OutOfMemory;
        w.print("control{d} state", .{mi}) catch return error.OutOfMemory;
        for (0..r.captures.len) |ci| w.print(" c{d}", .{ci}) catch return error.OutOfMemory;
        w.writeAll(" =\n    case state of\n        Direct ") catch return error.OutOfMemory;
        w.writeAll(if (bound_input) "resumed" else "⊤") catch return error.OutOfMemory;
        w.writeAll(" →\n            ( Direct (") catch return error.OutOfMemory;
        const corrupt_direct = tamper == .direct_input and bound_input and !tampered and r.captures.len > 1 and isInt(types, in.plan.captures.get(r.captures.start + 1).type, interner);
        try writeRestCall(w, mi, r.captures.len, if (corrupt_direct) "c1" else if (bound_input) "resumed" else null);
        if (corrupt_direct) tampered = true;
        w.writeAll("), Nothing )\n\n        Parked input →\n            output = Ref.make ") catch return error.OutOfMemory;
        if (tamper == .wrong_slot and !tampered and isInt(types, r.output, interner)) {
            w.writeAll("(Just \"wrong slot\")\n") catch return error.OutOfMemory;
            tampered = true;
        } else w.writeAll("Nothing\n") catch return error.OutOfMemory;
        w.print("            job = job{d} input output", .{mi}) catch return error.OutOfMemory;
        for (0..r.captures.len) |ci| w.print(" c{d}", .{ci}) catch return error.OutOfMemory;
        w.writeAll("\n            ( Parked ") catch return error.OutOfMemory;
        if (tamper == .scaffold_return_slot and !tampered) {
            w.writeAll("(Ref.make Nothing)") catch return error.OutOfMemory;
            tampered = true;
        } else w.writeAll("output") catch return error.OutOfMemory;
        w.print(", Just (pack{d} job) )\n\n", .{mi}) catch return error.OutOfMemory;
    }
    if (tamper == .drop_region and batch.members.len != 0) {
        batch.members.len -= 1;
        tampered = true;
    }
    if (tamper == .duplicate_region and batch.members.len >= 2) {
        batch.members.set(1, batch.members.get(0));
        tampered = true;
    }
    if (tamper == .ownership_conflict and batch.members.len != 0) {
        w.writeAll("pub ownershipConflict : List Int → List Int × List Int\nownershipConflict xs = ( xs, List.push xs 1 )\n") catch return error.OutOfMemory;
        tampered = true;
    }
    if (tamper != .none and !tampered) return error.UnsupportedTamper;
    batch.source = try out.toOwnedSlice();
    return batch;
}
fn writeRestCall(w: *std.Io.Writer, member: usize, captures: u32, input_name: ?[]const u8) Error!void {
    w.print("rest{d}", .{member}) catch return error.OutOfMemory;
    if (input_name) |name| w.print(" {s}", .{name}) catch return error.OutOfMemory;
    for (0..captures) |ci| w.print(" c{d}", .{ci}) catch return error.OutOfMemory;
}
fn operandType(in: Input, region: Source.Region, positions: []const u32, arg: Bir.Inst.Index) Error!Interface.TermIndex {
    const local = in.bir.instData(arg).lhs;
    if (region.input_kind == .bound_int and local == region.input_local) return region.input;
    return in.plan.captures.get(region.captures.start + try capturePosition(positions, local)).type;
}
fn capturePosition(positions: []const u32, local: u32) Error!u32 {
    if (local >= positions.len or positions[local] == std.math.maxInt(u32)) return error.MissingEvidence;
    return positions[local];
}
fn simple(types: *const Interface, root: Interface.TermIndex, interner: *const InternPool.Global) bool {
    const t = types.term(root);
    return switch (t.tag) {
        .@"var", .unit => true,
        .func => blk: {
            for (types.range(t.lhs)) |p| if (!atomic(types, @fromBackingInt(p), interner)) break :blk false;
            break :blk atomic(types, @fromBackingInt(t.rhs), interner);
        },
        .app => blk: {
            const ref = types.type_refs[t.lhs];
            const name = interner.slice(types.symbol(ref.name));
            const module = interner.slice(types.symbol(ref.module));
            const primitive_module = if (std.mem.eql(u8, name, "String")) "String" else if (std.mem.eql(u8, name, "Char")) "Char" else "Basics";
            break :blk std.mem.eql(u8, module, primitive_module) and ref.package == .core and types.range(t.rhs).len == 0 and (std.mem.eql(u8, name, "Int") or std.mem.eql(u8, name, "String") or std.mem.eql(u8, name, "Bool") or std.mem.eql(u8, name, "Float") or std.mem.eql(u8, name, "Char"));
        },
        else => false,
    };
}
fn atomic(types: *const Interface, root: Interface.TermIndex, interner: *const InternPool.Global) bool {
    return types.term(root).tag != .func and simple(types, root, interner);
}
fn writeType(w: *std.Io.Writer, types: *const Interface, root: Interface.TermIndex, interner: *const InternPool.Global, sync_function: bool) Error!void {
    const t = types.term(root);
    switch (t.tag) {
        .@"var" => w.print("a{d}", .{t.lhs}) catch return error.OutOfMemory,
        .unit => w.writeAll("⊤") catch return error.OutOfMemory,
        .app => w.writeAll(interner.slice(types.symbol(types.type_refs[t.lhs].name))) catch return error.OutOfMemory,
        .func => {
            w.writeAll(if (sync_function) "sync (" else "(") catch return error.OutOfMemory;
            for (types.range(t.lhs), 0..) |p, pi| {
                if (pi != 0) w.writeAll(", ") catch return error.OutOfMemory;
                try writeType(w, types, @fromBackingInt(p), interner, false);
            }
            w.writeAll(" → ") catch return error.OutOfMemory;
            try writeType(w, types, @fromBackingInt(t.rhs), interner, false);
            w.writeAll(")") catch return error.OutOfMemory;
        },
        else => return error.MissingEvidence,
    }
}

// Tamper selection only; these helpers never establish source/type proof.
fn isInt(types: *const Interface, root: Interface.TermIndex, interner: *const InternPool.Global) bool {
    const t = types.term(root);
    if (t.tag != .app) return false;
    const r = types.type_refs[t.lhs];
    return r.package == .core and std.mem.eql(u8, interner.slice(types.symbol(r.module)), "Basics") and std.mem.eql(u8, interner.slice(types.symbol(r.name)), "Int");
}
fn sameFixtureType(types: *const Interface, a: Interface.TermIndex, b: Interface.TermIndex) bool {
    const x = types.term(a);
    const y = types.term(b);
    if (x.tag != y.tag) return false;
    return switch (x.tag) {
        .unit => true,
        .@"var" => x.lhs == y.lhs,
        .app => x.lhs == y.lhs and types.range(x.rhs).len == 0 and types.range(y.rhs).len == 0,
        else => false,
    };
}

/// Recomputed from installed source authority by the independent inventory gate.
pub fn supportReason(in: Input, region: Source.Region, interner: *const InternPool.Global) Support {
    const scheme = in.dispatch.continuations.types.schemes[@backingInt(region.scheme)];
    for (0..scheme.quantified_count) |qi| {
        const q = in.dispatch.continuations.types.quantified(scheme, @intCast(qi));
        if (q.kind != 0 or q.equatable or q.constraints_len != 0 or q.identity or q.crosses) return .binder_contract;
    }
    if (in.dispatch.effectAt(region.body).own != .no or sourceCaptureClass(in, region, 0) == null) return .callback_contract;
    if (!atomic(&in.dispatch.continuations.types, region.output, interner)) return .type_shape;
    for (0..region.captures.len) |ci| {
        const root = in.plan.captures.get(region.captures.start + ci).type;
        if (ci == 0) {
            if (in.dispatch.continuations.types.term(root).tag != .func or !simple(&in.dispatch.continuations.types, root, interner)) return .type_shape;
        } else if (!atomic(&in.dispatch.continuations.types, root, interner)) return .type_shape;
    }
    return .supported;
}
pub fn sourceCaptureClass(in: Input, region: Source.Region, capture: u32) ?u32 {
    if (capture >= region.captures.len) return null;
    const types = &in.dispatch.continuations.types;
    const scheme = types.schemes[@backingInt(region.scheme)];
    const block = Interface.effectBlock(types, scheme) orelse return null;
    const parameter = in.plan.captures.get(region.captures.start + capture).parameter;
    var sites = block.sites();
    while (sites.next()) |site| {
        // Exact lexical BODY parameter path; matching function shape/term ID
        // never borrows another callback's sync authority.
        if (site.root != 0 or site.steps.len != 2) continue;
        if (Interface.EffectBlock.stepKind(site.steps[0]) != 3 or Interface.EffectBlock.stepIndex(site.steps[0]) != 1 or
            Interface.EffectBlock.stepKind(site.steps[1]) != 0 or Interface.EffectBlock.stepIndex(site.steps[1]) != parameter) continue;
        const class = block.class(site.class);
        if (class.sync and class.rung < 2 and !class.sensitive and class.deps.len == 0) return site.class;
    }
    return null;
}

/// Only a deterministic checked-source producer descriptor may enter the
/// compiler-owned core route; arbitrary ordinary source strings stay APP.
pub const RuntimeSource = struct {
    batch: *const Batch,
    inputs: []const Input,
    interner: *const InternPool.Global,
    tamper: Tamper = .none,
};
pub fn validateRuntimeSource(gpa: Allocator, source: RuntimeSource) (Error || error{InvalidRuntimeSource})!void {
    for (source.inputs) |in| {
        if (!in.plan.present or !try in.plan.verifyAgainstBir(gpa, in.bir, in.dispatch, source.interner)) return error.InvalidRuntimeSource;
    }
    var expected = try produce(gpa, source.inputs, source.interner, source.tamper);
    defer expected.deinit(gpa);
    if (!std.mem.eql(u8, expected.source, source.batch.source) or expected.unsupported != source.batch.unsupported or expected.members.len != source.batch.members.len) return error.InvalidRuntimeSource;
    for (0..expected.members.len) |i| if (!std.meta.eql(expected.members.get(i), source.batch.members.get(i))) return error.InvalidRuntimeSource;
}
