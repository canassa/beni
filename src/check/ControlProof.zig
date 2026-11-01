//! Source rewrite provenance, deliberately independent of ordinary type checking.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const InternPool = @import("../InternPool.zig");
const Build = @import("ControlBuild.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
pub const Context = struct { bir: *const Bir, graph: *const Graph, interfaces: []const Interface, iface: *const Interface, provenance: *const Interface.Provenance, dispatch: *const @import("Dispatch.zig"), interner: *const InternPool.Global };
const absent: Bir.DeclIndex = @fromBackingInt(std.math.maxInt(u32));
pub const Receipt = struct { member: u32, remainder: Bir.DeclIndex, control: Bir.DeclIndex, job: Bir.DeclIndex, pack: Bir.DeclIndex, job_class: u32, job_scheme: Interface.SchemeIndex, source_operations: u32, captures: u32 };
pub const Error = Allocator.Error || error{InvalidControlProvenance};
pub fn verify(gpa: Allocator, batch: *const Build.Batch, inputs: []const Build.Input, generated_context: Context, source_interner: *const InternPool.Global) Error!std.MultiArrayList(Receipt) {
    const generated = generated_context.bir;
    const interner = generated_context.interner;
    try verifyInventory(gpa, batch, inputs, source_interner);
    var out: std.MultiArrayList(Receipt) = .empty;
    errdefer out.deinit(gpa);
    const remainders = try gpa.alloc(Bir.DeclIndex, batch.members.len);
    defer gpa.free(remainders);
    @memset(remainders, absent);
    const controls = try gpa.alloc(Bir.DeclIndex, batch.members.len);
    defer gpa.free(controls);
    @memset(controls, absent);
    const jobs = try gpa.alloc(Bir.DeclIndex, batch.members.len);
    defer gpa.free(jobs);
    @memset(jobs, absent);
    const packs = try gpa.alloc(Bir.DeclIndex, batch.members.len);
    defer gpa.free(packs);
    @memset(packs, absent);
    var sealer: Bir.DeclIndex = absent;
    const schemes = try gpa.alloc(Interface.SchemeIndex, generated.decls.len);
    defer gpa.free(schemes);
    @memset(schemes, .none);
    if (generated_context.provenance.value_decl.len != generated_context.iface.values.len) return error.InvalidControlProvenance;
    for (generated_context.iface.values, generated_context.provenance.value_decl) |value, decl_index| {
        if (decl_index.int() >= generated.decls.len) return error.InvalidControlProvenance;
        const decl = generated.decl(decl_index);
        if (!decl.kind.isValue() or generated_context.iface.symbol(value.name) != generated.symbol(decl.name)) return error.InvalidControlProvenance;
        if (schemes[decl_index.int()] != .none) return error.InvalidControlProvenance;
        schemes[decl_index.int()] = value.scheme;
    }
    for (generated.decls, 0..) |decl, di| {
        const name = interner.slice(generated.symbol(decl.name));
        if (number(name, "rest")) |i| {
            if (i >= remainders.len or remainders[i] != absent) return error.InvalidControlProvenance;
            remainders[i] = @fromBackingInt(@intCast(di));
        } else if (number(name, "job")) |i| {
            if (i >= jobs.len or jobs[i] != absent) return error.InvalidControlProvenance;
            jobs[i] = @fromBackingInt(@intCast(di));
        } else if (number(name, "pack")) |i| {
            if (i >= packs.len or packs[i] != absent) return error.InvalidControlProvenance;
            packs[i] = @fromBackingInt(@intCast(di));
        } else if (std.mem.eql(u8, name, "sealJob")) {
            if (sealer != absent) return error.InvalidControlProvenance;
            sealer = @fromBackingInt(@intCast(di));
        } else if (number(name, "control")) |i| {
            if (i >= controls.len or controls[i] != absent) return error.InvalidControlProvenance;
            controls[i] = @fromBackingInt(@intCast(di));
        }
    }
    if (sealer == absent) return error.InvalidControlProvenance;
    try verifySealer(generated_context, sealer, schemes[sealer.int()]);
    try verifyJobConstruction(gpa, generated_context, packs);
    const offsets = try gpa.alloc(usize, inputs.len + 1);
    defer gpa.free(offsets);
    offsets[0] = 0;
    for (inputs, 0..) |in, i| offsets[i + 1] = offsets[i] + in.bir.locals.len;
    const positions = try gpa.alloc(u32, offsets[inputs.len]);
    defer gpa.free(positions);
    @memset(positions, std.math.maxInt(u32));
    for (0..batch.members.len) |mi| {
        if (remainders[mi] == absent or controls[mi] == absent or jobs[mi] == absent or packs[mi] == absent) return error.InvalidControlProvenance;
        const member = batch.members.get(mi);
        if (member.input >= inputs.len) return error.InvalidControlProvenance;
        const in = inputs[member.input];
        if (member.module != in.module or @backingInt(member.region) >= in.plan.regions.len) return error.InvalidControlProvenance;
        const r = in.plan.regions.get(@backingInt(member.region));
        const remainder = generated.decl(remainders[mi]);
        const control = generated.decl(controls[mi]);
        if (remainder.annotation == .none or control.annotation == .none) return error.InvalidControlProvenance;
        const params = generated.extraSlice(.{ .start = remainder.params_start, .end = remainder.params_end }, Bir.Inst.Index);
        const control_params = generated.extraSlice(.{ .start = control.params_start, .end = control.params_end }, Bir.Inst.Index);
        const input_count: usize = if (r.input_kind == .bound_int) 1 else 0;
        if (params.len != r.captures.len + input_count or control_params.len != r.captures.len + 1) return error.InvalidControlProvenance;
        const source_decl = in.bir.decl(r.decl);
        const map = positions[offsets[member.input] + source_decl.locals_start .. offsets[member.input] + source_decl.locals_end];
        if (input_count != 0) {
            if (r.input_local >= map.len or generated.instTag(params[0]) != .pat_var or in.bir.locals[source_decl.locals_start + r.input_local].inst.int() != r.input_definition) return error.InvalidControlProvenance;
            map[r.input_local] = generated.instData(params[0]).lhs;
        }
        for (params[input_count..], 0..) |param, pi| {
            if (generated.instTag(param) != .pat_var or generated.instTag(control_params[pi + 1]) != .pat_var) return error.InvalidControlProvenance;
            const capture = in.plan.captures.get(r.captures.start + pi);
            if (capture.local >= map.len or capture.local >= source_decl.locals_end - source_decl.locals_start or in.bir.locals[source_decl.locals_start + capture.local].inst != capture.definition) return error.InvalidControlProvenance;
            map[capture.local] = generated.instData(param).lhs;
        }
        // Validate the REAL checked remainder body, not producer-supplied text/map.
        const body = remainder.body.unwrap() orelse return error.InvalidControlProvenance;
        if (generated.instTag(body) != .call or in.bir.instTag(r.body) != .call) return error.InvalidControlProvenance;
        const actual = generated.instData(body);
        const source = in.bir.instData(r.body);
        try sameLocal(generated, @fromBackingInt(actual.lhs), in.bir, @fromBackingInt(source.lhs), map);
        const source_args = in.bir.extraSlice(in.bir.subRange(@fromBackingInt(source.rhs)), Bir.Inst.Index);
        const actual_args = generated.extraSlice(generated.subRange(@fromBackingInt(actual.rhs)), Bir.Inst.Index);
        if (source_args.len != actual_args.len or r.operations.len != source_args.len + 2) return error.InvalidControlProvenance;
        for (source_args, actual_args) |old, new| try sameLocal(generated, new, in.bir, old, map);
        // Only one call/local remainder region is supported; every source
        // operation is covered in order and suspension is explicitly consumed.
        if (in.plan.operations.get(r.operations.start).inst != r.body) return error.InvalidControlProvenance;
        if (in.plan.operations.get(r.operations.start + 1).inst.int() != source.lhs) return error.InvalidControlProvenance;
        for (source_args, 0..) |arg, ai| if (in.plan.operations.get(r.operations.start + 2 + ai).inst != arg) return error.InvalidControlProvenance;
        const job_class = try verifyFactory(gpa, generated_context, jobs[mi], schemes[jobs[mi].int()], remainders[mi], sealer, in, r);
        try verifyPacker(generated_context, packs[mi], schemes[packs[mi].int()], mi);
        try verifyScaffold(generated_context, control, remainders[mi], jobs[mi], packs[mi], control_params, r.input_kind == .bound_int);
        try out.append(gpa, .{ .member = @intCast(mi), .remainder = remainders[mi], .control = controls[mi], .job = jobs[mi], .pack = packs[mi], .job_class = job_class, .job_scheme = schemes[jobs[mi].int()], .source_operations = r.operations.len, .captures = r.captures.len });
    }
    return out;
}
fn sameLocal(generated: *const Bir, actual: Bir.Inst.Index, source: *const Bir, expected: Bir.Inst.Index, map: []const u32) Error!void {
    if (generated.instTag(actual) != .local or source.instTag(expected) != .local) return error.InvalidControlProvenance;
    const local = source.instData(expected).lhs;
    if (local >= map.len or map[local] == std.math.maxInt(u32) or generated.instData(actual).lhs != map[local]) return error.InvalidControlProvenance;
}
fn number(name: []const u8, prefix: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return null;
    return std.fmt.parseInt(u32, name[prefix.len..], 10) catch null;
}

pub fn verifyInventory(gpa: Allocator, batch: *const Build.Batch, inputs: []const Build.Input, interner: *const InternPool.Global) Error!void {
    const offsets = try gpa.alloc(usize, inputs.len + 1);
    defer gpa.free(offsets);
    offsets[0] = 0;
    for (inputs, 0..) |in, i| offsets[i + 1] = offsets[i] + in.plan.regions.len;
    const seen = try gpa.alloc(bool, offsets[inputs.len]);
    defer gpa.free(seen);
    @memset(seen, false);
    for (0..batch.members.len) |mi| {
        const member = batch.members.get(mi);
        if (member.input >= inputs.len) return error.InvalidControlProvenance;
        const in = inputs[member.input];
        if (member.module != in.module or @backingInt(member.region) >= in.plan.regions.len) return error.InvalidControlProvenance;
        const index = offsets[member.input] + @backingInt(member.region);
        if (seen[index]) return error.InvalidControlProvenance;
        seen[index] = true;
        if (Build.supportReason(in, in.plan.regions.get(@backingInt(member.region)), interner) != .supported) return error.InvalidControlProvenance;
    }
    var unsupported: u64 = 0;
    var supported: u64 = 0;
    for (inputs, 0..) |in, ii| {
        if (!in.plan.present) return error.InvalidControlProvenance;
        for (0..in.plan.sites.len) |si| {
            const site = in.plan.sites.get(si);
            if (site.region == .none) {
                unsupported += 1;
                continue;
            }
            if (Build.supportReason(in, in.plan.regions.get(@backingInt(site.region)), interner) == .supported) {
                if (!seen[offsets[ii] + @backingInt(site.region)]) return error.InvalidControlProvenance;
                supported += 1;
            } else unsupported += 1;
        }
    }
    if (unsupported != batch.unsupported or supported != batch.members.len) return error.InvalidControlProvenance;
}

fn verifyScaffold(c: Context, control: Bir.Decl, remainder: Bir.DeclIndex, factory: Bir.DeclIndex, packer: Bir.DeclIndex, params: []const Bir.Inst.Index, bound_input: bool) Error!void {
    const b = c.bir;
    if (params.len == 0 or b.instTag(params[0]) != .pat_var) return error.InvalidControlProvenance;
    const body = control.body.unwrap() orelse return error.InvalidControlProvenance;
    if (b.instTag(body) != .case) return error.InvalidControlProvenance;
    const data = b.instData(body);
    try localIs(b, @fromBackingInt(data.lhs), b.instData(params[0]).lhs);
    const branches = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Bir.Inst.Index);
    if (branches.len != 2) return error.InvalidControlProvenance;
    const direct = try branch(c, branches[0], "Direct", "Control", 1);
    if (b.instTag(direct.patterns[0]) != (if (bound_input) Bir.Inst.Tag.pat_var else .pat_unit)) return error.InvalidControlProvenance;
    const direct_values = try tuple(b, direct.body, 2);
    const direct_payload = try constructor(c, direct_values[0], "Direct", "Control", 1);
    try restCall(b, direct_payload[0], remainder, params[1..], if (bound_input) b.instData(direct.patterns[0]).lhs else null);
    try constructorRef(c, direct_values[1], "Nothing", "Maybe");
    const parked = try branch(c, branches[1], "Parked", "Control", 1);
    if (b.instTag(parked.patterns[0]) != .pat_var or b.instTag(parked.body) != .let) return error.InvalidControlProvenance;
    const input = b.instData(parked.patterns[0]).lhs;
    const parked_data = b.instData(parked.body);
    const definitions = b.extraSlice(b.subRange(@fromBackingInt(parked_data.lhs)), Bir.Inst.Index);
    if (definitions.len != 2) return error.InvalidControlProvenance;
    const output = try definition(b, definitions[0]);
    const job = try definition(b, definitions[1]);
    const made = try nativeCall(c, output.body, "Ref", "make", 1);
    try constructorRef(c, made[0], "Nothing", "Maybe");
    const created = try topCall(b, job.body, factory, params.len + 1);
    try localIs(b, created[0], input);
    try localIs(b, created[1], output.local);
    for (params[1..], 0..) |param, ci| try localIs(b, created[ci + 2], b.instData(param).lhs);
    const final = try tuple(b, @fromBackingInt(parked_data.rhs), 2);
    const parked_payload = try constructor(c, final[0], "Parked", "Control", 1);
    try localIs(b, parked_payload[0], output.local);
    const job_value = try constructor(c, final[1], "Just", "Maybe", 1);
    const stored = try topCall(b, job_value[0], packer, 1);
    try localIs(b, stored[0], job.local);
}
fn verifyFactory(gpa: Allocator, c: Context, index: Bir.DeclIndex, scheme: Interface.SchemeIndex, remainder: Bir.DeclIndex, sealer: Bir.DeclIndex, source: Build.Input, region: @import("ControlSourcePlan.zig").Region) Error!u32 {
    const b = c.bir;
    const decl = b.decl(index);
    const params = b.extraSlice(.{ .start = decl.params_start, .end = decl.params_end }, Bir.Inst.Index);
    if (params.len != region.captures.len + 2) return error.InvalidControlProvenance;
    for (params) |param| if (b.instTag(param) != .pat_var) return error.InvalidControlProvenance;
    const body = decl.body.unwrap() orelse return error.InvalidControlProvenance;
    const sealed = try topCall(b, body, sealer, 1);
    if (b.instTag(sealed[0]) != .lambda) return error.InvalidControlProvenance;
    const lambda = b.instData(sealed[0]);
    const unit_params = b.extraSlice(b.subRange(@fromBackingInt(lambda.lhs)), Bir.Inst.Index);
    if (unit_params.len != 1 or b.instTag(unit_params[0]) != .pat_unit) return error.InvalidControlProvenance;
    const input_case: Bir.Inst.Index = @fromBackingInt(lambda.rhs);
    if (b.instTag(input_case) != .case) return error.InvalidControlProvenance;
    const input = b.instData(input_case);
    const got = try nativeCall(c, @fromBackingInt(input.lhs), "Ref", "get", 1);
    try localIs(b, got[0], b.instData(params[0]).lhs);
    const branches = b.extraSlice(b.subRange(@fromBackingInt(input.rhs)), Bir.Inst.Index);
    if (branches.len != 2) return error.InvalidControlProvenance;
    const missing = try branch(c, branches[0], "Nothing", "Maybe", 0);
    const defect = try nativeCall(c, missing.body, "Debug", "todo", 1);
    if (b.instTag(defect[0]) != .string or !std.mem.eql(u8, b.bytes(defect[0]), "missing generated input slot")) return error.InvalidControlProvenance;
    const available = try branch(c, branches[1], "Just", "Maybe", 1);
    const bound_input = region.input_kind == .bound_int;
    if (b.instTag(available.patterns[0]) != (if (bound_input) Bir.Inst.Tag.pat_var else .pat_unit)) return error.InvalidControlProvenance;
    const set = try nativeCall(c, available.body, "Ref", "set", 2);
    try localIs(b, set[0], b.instData(params[1]).lhs);
    const publication = try constructor(c, set[1], "Just", "Maybe", 1);
    try restCall(b, publication[0], remainder, params[2..], if (bound_input) b.instData(available.patterns[0]).lhs else null);
    // Exact inferred RESULT function class, not an annotation, another
    // same-shaped endpoint, or EffectPlan's missing/no row default.
    return proveFactoryClass(gpa, c.iface, scheme, source, region);
}
fn verifyPacker(c: Context, index: Bir.DeclIndex, scheme: Interface.SchemeIndex, member: usize) Error!void {
    const b = c.bir;
    const decl = b.decl(index);
    const params = b.extraSlice(.{ .start = decl.params_start, .end = decl.params_end }, Bir.Inst.Index);
    if (params.len != 1 or b.instTag(params[0]) != .pat_var) return error.InvalidControlProvenance;
    var buffer: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&buffer, "Site{d}", .{member}) catch return error.InvalidControlProvenance;
    const args = try constructor(c, decl.body.unwrap() orelse return error.InvalidControlProvenance, name, "Job", 1);
    try localIs(b, args[0], b.instData(params[0]).lhs);
    _ = try effectClass(c.iface, scheme, 0, 0);
}
fn verifySealer(c: Context, index: Bir.DeclIndex, scheme: Interface.SchemeIndex) Error!void {
    const b = c.bir;
    const decl = b.decl(index);
    const params = b.extraSlice(.{ .start = decl.params_start, .end = decl.params_end }, Bir.Inst.Index);
    if (params.len != 1 or b.instTag(params[0]) != .pat_var) return error.InvalidControlProvenance;
    try localIs(b, decl.body.unwrap() orelse return error.InvalidControlProvenance, b.instData(params[0]).lhs);
    const received = try effectClass(c.iface, scheme, 0, 0);
    const returned = try effectClass(c.iface, scheme, 1, 0);
    if (received != returned) return error.InvalidControlProvenance;
}
fn effectClass(iface: *const Interface, scheme: Interface.SchemeIndex, kind: u32, index: u32) Error!u32 {
    if (scheme == .none or @backingInt(scheme) >= iface.schemes.len) return error.InvalidControlProvenance;
    const block = Interface.effectBlock(iface, iface.schemes[@backingInt(scheme)]) orelse return error.InvalidControlProvenance;
    var sites = block.sites();
    while (sites.next()) |site| {
        if (site.root != 0 or site.steps.len != 1 or Interface.EffectBlock.stepKind(site.steps[0]) != kind or Interface.EffectBlock.stepIndex(site.steps[0]) != index) continue;
        const class = block.class(site.class);
        if (!class.sync or class.rung >= 2 or class.sensitive or class.deps.len != 0) return error.InvalidControlProvenance;
        return site.class;
    }
    return error.InvalidControlProvenance;
}
fn verifyJobConstruction(gpa: Allocator, c: Context, packs: []const Bir.DeclIndex) Error!void {
    const counts = try gpa.alloc(u32, packs.len);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (c.bir.decls, 0..) |decl, di| for (decl.inst_start.int()..decl.inst_end.int()) |ii| {
        const inst: Bir.Inst.Index = @fromBackingInt(@intCast(ii));
        if (c.bir.instTag(inst) != .ctor) continue;
        const ctor = c.bir.ctors[c.bir.instData(inst).lhs];
        if (!std.mem.eql(u8, c.interner.slice(c.bir.symbol(c.bir.decl(ctor.decl).name)), "Job")) continue;
        const member = number(c.interner.slice(c.bir.symbol(ctor.name)), "Site") orelse return error.InvalidControlProvenance;
        if (member >= packs.len or packs[member] == absent or packs[member].int() != di) return error.InvalidControlProvenance;
        counts[member] += 1;
        if (counts[member] != 1) return error.InvalidControlProvenance;
    };
    for (counts) |count| if (count != 1) return error.InvalidControlProvenance;
}
fn topCall(b: *const Bir, inst: Bir.Inst.Index, expected: Bir.DeclIndex, arity: usize) Error![]const Bir.Inst.Index {
    const got = try call(b, inst, arity);
    if (b.instTag(got.callee) != .top or b.instData(got.callee).lhs != expected.int()) return error.InvalidControlProvenance;
    return got.args;
}

const Branch = struct { patterns: []const Bir.Inst.Index, body: Bir.Inst.Index };
fn branch(c: Context, inst: Bir.Inst.Index, name: []const u8, family: []const u8, arity: usize) Error!Branch {
    const b = c.bir;
    if (b.instTag(inst) != .branch) return error.InvalidControlProvenance;
    const data = b.instData(inst);
    const pattern: Bir.Inst.Index = @fromBackingInt(data.lhs);
    if (b.instTag(pattern) != .pat_ctor) return error.InvalidControlProvenance;
    const p = b.instData(pattern);
    try constructorRef(c, @fromBackingInt(p.lhs), name, family);
    const patterns = b.extraSlice(b.subRange(@fromBackingInt(p.rhs)), Bir.Inst.Index);
    if (patterns.len != arity) return error.InvalidControlProvenance;
    return .{ .patterns = patterns, .body = @fromBackingInt(data.rhs) };
}
const Definition = struct { local: u32, body: Bir.Inst.Index };
fn definition(b: *const Bir, inst: Bir.Inst.Index) Error!Definition {
    if (b.instTag(inst) != .let_def) return error.InvalidControlProvenance;
    const data = b.instData(inst);
    const def = b.extraData(@fromBackingInt(data.lhs), Bir.LetDef);
    if (def.params_start != def.params_end) return error.InvalidControlProvenance;
    return .{ .local = def.local, .body = @fromBackingInt(data.rhs) };
}
fn localIs(b: *const Bir, inst: Bir.Inst.Index, expected: u32) Error!void {
    if (b.instTag(inst) != .local or b.instData(inst).lhs != expected) return error.InvalidControlProvenance;
}
fn tuple(b: *const Bir, inst: Bir.Inst.Index, arity: usize) Error![]const Bir.Inst.Index {
    if (b.instTag(inst) != .tuple) return error.InvalidControlProvenance;
    const data = b.instData(inst);
    const fields = b.extraSlice(.{ .start = @fromBackingInt(data.lhs), .end = @fromBackingInt(data.rhs) }, Bir.Inst.Index);
    if (fields.len != arity) return error.InvalidControlProvenance;
    return fields;
}
fn call(b: *const Bir, inst: Bir.Inst.Index, arity: usize) Error!struct { callee: Bir.Inst.Index, args: []const Bir.Inst.Index } {
    if (b.instTag(inst) != .call) return error.InvalidControlProvenance;
    const data = b.instData(inst);
    const args = b.extraSlice(b.subRange(@fromBackingInt(data.rhs)), Bir.Inst.Index);
    if (args.len != arity) return error.InvalidControlProvenance;
    return .{ .callee = @fromBackingInt(data.lhs), .args = args };
}
fn restCall(b: *const Bir, inst: Bir.Inst.Index, expected: Bir.DeclIndex, params: []const Bir.Inst.Index, resumed: ?u32) Error!void {
    const offset: usize = if (resumed != null) 1 else 0;
    const got = try call(b, inst, params.len + offset);
    if (resumed) |local| try localIs(b, got.args[0], local);
    if (b.instTag(got.callee) != .top or b.instData(got.callee).lhs != expected.int()) return error.InvalidControlProvenance;
    for (got.args[offset..], 0..) |arg, ai| try localIs(b, arg, b.instData(params[ai]).lhs);
}
fn nativeCall(c: Context, inst: Bir.Inst.Index, module: []const u8, name: []const u8, arity: usize) Error![]const Bir.Inst.Index {
    const got = try call(c.bir, inst, arity);
    if (c.bir.instTag(got.callee) != .ext_value) return error.InvalidControlProvenance;
    const data = c.bir.instData(got.callee);
    const m: Graph.Index = @fromBackingInt(data.lhs);
    if (data.lhs >= c.graph.count() or c.graph.modulePackage(m) != .core or !std.mem.eql(u8, c.interner.slice(c.graph.moduleName(m)), module)) return error.InvalidControlProvenance;
    const iface = &c.interfaces[data.lhs];
    if (data.rhs >= iface.values.len or !std.mem.eql(u8, c.interner.slice(iface.symbol(iface.values[data.rhs].name)), name)) return error.InvalidControlProvenance;
    return got.args;
}
fn constructor(c: Context, inst: Bir.Inst.Index, name: []const u8, family: []const u8, arity: usize) Error![]const Bir.Inst.Index {
    const got = try call(c.bir, inst, arity);
    try constructorRef(c, got.callee, name, family);
    return got.args;
}
fn constructorRef(c: Context, inst: Bir.Inst.Index, name: []const u8, family: []const u8) Error!void {
    const data = c.bir.instData(inst);
    if (std.mem.eql(u8, family, "Maybe")) {
        if (c.bir.instTag(inst) != .ext_ctor or data.lhs >= c.graph.count()) return error.InvalidControlProvenance;
        const module: Graph.Index = @fromBackingInt(data.lhs);
        if (c.graph.modulePackage(module) != .core or !std.mem.eql(u8, c.interner.slice(c.graph.moduleName(module)), "Maybe")) return error.InvalidControlProvenance;
        const iface = &c.interfaces[data.lhs];
        if (data.rhs >= iface.ctors.len or !std.mem.eql(u8, c.interner.slice(iface.symbol(iface.ctors[data.rhs].name)), name)) return error.InvalidControlProvenance;
    } else {
        if (c.bir.instTag(inst) != .ctor or data.lhs >= c.bir.ctors.len) return error.InvalidControlProvenance;
        const ctor = c.bir.ctors[data.lhs];
        if (!std.mem.eql(u8, c.interner.slice(c.bir.symbol(ctor.name)), name) or !std.mem.eql(u8, c.interner.slice(c.bir.symbol(c.bir.decl(ctor.decl).name)), family)) return error.InvalidControlProvenance;
    }
}

fn classAt(block: Interface.EffectBlock, kind: u32, index: u32) ?u32 {
    var sites = block.sites();
    while (sites.next()) |site| if (site.root == 0 and site.steps.len == 1 and Interface.EffectBlock.stepKind(site.steps[0]) == kind and Interface.EffectBlock.stepIndex(site.steps[0]) == index) return site.class;
    return null;
}
fn proveFactoryClass(gpa: Allocator, iface: *const Interface, scheme: Interface.SchemeIndex, source: Build.Input, region: @import("ControlSourcePlan.zig").Region) Error!u32 {
    if (scheme == .none or @backingInt(scheme) >= iface.schemes.len) return error.InvalidControlProvenance;
    const block = Interface.effectBlock(iface, iface.schemes[@backingInt(scheme)]) orelse return error.InvalidControlProvenance;
    const root = classAt(block, 1, 0) orelse return error.InvalidControlProvenance;
    const n = block.classCount();
    if (root >= n) return error.InvalidControlProvenance;
    const witnesses = try gpa.alloc(u32, n);
    defer gpa.free(witnesses);
    @memset(witnesses, std.math.maxInt(u32));
    for (0..region.captures.len) |ci| {
        if (Build.sourceCaptureClass(source, region, @intCast(ci)) == null) continue;
        const class = classAt(block, 0, @intCast(ci + 2)) orelse return error.InvalidControlProvenance;
        if (class >= n or witnesses[class] != std.math.maxInt(u32)) return error.InvalidControlProvenance;
        witnesses[class] = @intCast(ci);
    }
    const Class = struct { rung: u32, sync: bool, sensitive: bool, start: u32, len: u32 };
    var classes: std.MultiArrayList(Class) = .empty;
    defer classes.deinit(gpa);
    var dependencies: std.ArrayList(u32) = .empty;
    defer dependencies.deinit(gpa);
    var iterator = block.classIter();
    while (iterator.next()) |class| {
        const start: u32 = @intCast(dependencies.items.len);
        try dependencies.appendSlice(gpa, class.deps);
        try classes.append(gpa, .{ .rung = class.rung, .sync = class.sync, .sensitive = class.sensitive, .start = start, .len = @intCast(class.deps.len) });
    }
    if (classes.len != n) return error.InvalidControlProvenance;
    const states = try gpa.alloc(u8, n);
    defer gpa.free(states);
    @memset(states, 0);
    const Frame = struct { class: u32, next: u32 = 0 };
    const stack = try gpa.alloc(Frame, n);
    defer gpa.free(stack);
    var depth: usize = 1;
    stack[0] = .{ .class = root };
    states[root] = 1;
    while (depth != 0) {
        const frame = &stack[depth - 1];
        const class = classes.get(frame.class);
        if (!class.sync or class.rung >= 2 or class.sensitive) return error.InvalidControlProvenance;
        // The constructed/sealed lambda is the root witness. Every other
        // node must be an exact original sync-capture parameter, never a
        // same-shaped callback or an unknown pure-looking parameter.
        if (frame.class != root and witnesses[frame.class] == std.math.maxInt(u32)) return error.InvalidControlProvenance;
        if (frame.next < class.len) {
            const dependency = dependencies.items[class.start + frame.next];
            frame.next += 1;
            if (dependency >= n or states[dependency] == 1) return error.InvalidControlProvenance;
            if (states[dependency] == 2) continue;
            states[dependency] = 1;
            stack[depth] = .{ .class = dependency };
            depth += 1;
        } else {
            states[frame.class] = 2;
            depth -= 1;
        }
    }
    return root;
}
