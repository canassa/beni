//! Optional source capture referencing the authoritative ContinuationPlan bundle.
//! No second type graph, body certificate, runtime storage or source inference.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");
const ContinuationPlan = @import("ContinuationPlan.zig");
const Dispatch = @import("Dispatch.zig");
const TypeStore = @import("TypeStore.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
pub const schema_version: u32 = 2;
const none = std.math.maxInt(u32);
pub const RegionIndex = enum(u32) { none = std.math.maxInt(u32), _ };
pub const Range = struct { start: u32 = 0, len: u32 = 0 };
pub const Site = struct { inst: Bir.Inst.Index, region: RegionIndex = .none };
pub const InputKind = enum(u32) { discarded_unit, bound_int };
pub const Region = struct { input_kind: InputKind = .discarded_unit, input_local: u32 = none, input_definition: u32 = none, decl: Bir.DeclIndex, suspension: Bir.Inst.Index, body: Bir.Inst.Index, scheme: Interface.SchemeIndex, input: Interface.TermIndex, output: Interface.TermIndex, captures: Range, operations: Range };
pub const Capture = struct { local: u32, definition: Bir.Inst.Index, parameter: u32, type: Interface.TermIndex };
pub const Operation = struct { inst: Bir.Inst.Index, tag: Bir.Inst.Tag, lhs: u32, rhs: u32 };
pub const Artifact = struct {
    present: bool = false,
    sites: std.MultiArrayList(Site).Slice = .empty,
    regions: std.MultiArrayList(Region).Slice = .empty,
    captures: std.MultiArrayList(Capture).Slice = .empty,
    operations: std.MultiArrayList(Operation).Slice = .empty,
    pub const empty: Artifact = .{};
    pub fn deinit(a: *Artifact, gpa: Allocator) void {
        inline for (.{ "sites", "regions", "captures", "operations" }) |f| @field(a, f).deinit(gpa);
        a.* = .empty;
    }
    pub fn verify(a: *const Artifact, _: Allocator, _: *const InternPool.Global) Allocator.Error!bool {
        if (!a.present) return a.sites.len == 0 and a.regions.len == 0 and a.captures.len == 0 and a.operations.len == 0;
        var previous: ?u32 = null;
        var region_next: u32 = 0;
        for (0..a.sites.len) |i| {
            const s = a.sites.get(i);
            if (previous) |p| if (s.inst.int() <= p) return false;
            previous = s.inst.int();
            if (s.region != .none) {
                if (@backingInt(s.region) != region_next or region_next >= a.regions.len or a.regions.get(region_next).suspension != s.inst) return false;
                region_next += 1;
            }
        }
        if (region_next != a.regions.len) return false;
        var captures: u64 = 0;
        var operations: u64 = 0;
        for (0..a.regions.len) |i| {
            const r = a.regions.get(i);
            if (r.input_kind == .discarded_unit and (r.input_local != none or r.input_definition != none)) return false;
            if (r.input_kind == .bound_int and (r.input_local == none or r.input_definition == none)) return false;
            if (r.captures.start != captures or r.operations.start != operations) return false;
            captures += r.captures.len;
            operations += r.operations.len;
            if (captures > a.captures.len or operations > a.operations.len or r.captures.len == 0) return false;
        }
        return captures == a.captures.len and operations == a.operations.len;
    }
    /// Recompute admission and every lexical root. region=none cannot downgrade
    /// an admitted source site; all term refs belong to the SAME original scope.
    pub fn verifyAgainstBir(a: *const Artifact, gpa: Allocator, bir: *const Bir, table: *const Dispatch, interner: *const InternPool.Global) Allocator.Error!bool {
        if (!try a.verify(gpa, interner)) return false;
        if (!a.present) return true;
        const base = &table.continuations;
        if (!base.present or !try base.verify(gpa, interner) or a.sites.len != base.sites.len) return false;
        const parameters = try parameterMap(gpa, bir);
        defer gpa.free(parameters);
        if (parameters.len != bir.locals.len) return false;
        const seen = try gpa.alloc(u32, bir.locals.len);
        defer gpa.free(seen);
        @memset(seen, none);
        for (0..base.scopes.len) |scope_index| {
            const scope = base.scopes.get(scope_index);
            if (scope.decl.int() >= bir.decls.len) return false;
            const decl = bir.decl(scope.decl);
            const shape = admitted(bir, base, scope, parameters);
            for (scope.start..@as(usize, scope.start) + scope.len) |si| {
                const source = base.sites.get(si);
                const site = a.sites.get(si);
                if (site.inst != source.inst) return false;
                const expected = if (shape) |s| s.suspension == source.inst and admittedInput(&base.types, source.type, s, interner) else false;
                if ((site.region != .none) != expected) return false;
                if (!expected) continue;
                const s = shape.?;
                const r = a.regions.get(@backingInt(site.region));
                if (r.input_kind != s.input_kind or r.input_local != s.input_local or r.input_definition != s.input_definition or r.decl != scope.decl or r.scheme != scope.scheme or r.suspension != source.inst or r.input != source.type or r.body != s.body or r.output != s.output) return false;
                const call = bir.instData(s.body);
                const args = bir.extraSlice(bir.subRange(@fromBackingInt(call.rhs)), Bir.Inst.Index);
                if (r.operations.len != args.len + 2) return false;
                var next = r.captures.start;
                for (0..r.operations.len) |oi| {
                    const expected_inst = if (oi == 0) s.body else if (oi == 1) @as(Bir.Inst.Index, @fromBackingInt(call.lhs)) else args[oi - 2];
                    const op = a.operations.get(r.operations.start + oi);
                    const data = bir.instData(expected_inst);
                    if (op.inst != expected_inst or op.tag != bir.instTag(expected_inst) or op.lhs != data.lhs or op.rhs != data.rhs) return false;
                    if (oi == 0) continue;
                    const local = data.lhs;
                    if (local >= decl.locals_end - decl.locals_start) return false;
                    if (local == r.input_local) continue;
                    const absolute = decl.locals_start + local;
                    if (seen[absolute] != @backingInt(site.region)) {
                        if (next >= r.captures.start + r.captures.len) return false;
                        const capture = a.captures.get(next);
                        const parameter = parameters[absolute];
                        if (capture.local != local or capture.definition != bir.locals[absolute].inst or capture.parameter != parameter or parameter >= s.params.len or capture.type.int() != s.params[parameter]) return false;
                        seen[absolute] = @backingInt(site.region);
                        next += 1;
                    }
                }
                if (next != r.captures.start + r.captures.len) return false;
            }
        }
        return true;
    }
};
/// BIR locals are declaration-relative. This map has one MODULE-flat slot per
/// actual local and is prepared once, not once per suspension or scheme.
fn parameterMap(gpa: Allocator, bir: *const Bir) Allocator.Error![]u32 {
    const map = try gpa.alloc(u32, bir.locals.len);
    @memset(map, none);
    for (bir.decls) |decl| {
        if (!decl.kind.isValue()) continue;
        if (decl.locals_end > bir.locals.len or decl.locals_start > decl.locals_end) {
            gpa.free(map);
            return gpa.alloc(u32, 0);
        }
        const patterns = bir.extraSlice(.{ .start = decl.params_start, .end = decl.params_end }, Bir.Inst.Index);
        for (patterns, 0..) |pattern, pi| {
            if (bir.instTag(pattern) != .pat_var) continue;
            const local = bir.instData(pattern).lhs;
            if (local >= decl.locals_end - decl.locals_start) {
                gpa.free(map);
                return gpa.alloc(u32, 0);
            }
            const absolute = decl.locals_start + local;
            if (bir.locals[absolute].inst != pattern or map[absolute] != none) {
                gpa.free(map);
                return gpa.alloc(u32, 0);
            }
            map[absolute] = @intCast(pi);
        }
    }
    return map;
}
const Admission = struct { input_kind: InputKind = .discarded_unit, input_local: u32 = none, input_definition: u32 = none, suspension: Bir.Inst.Index, body: Bir.Inst.Index, output: Interface.TermIndex, params: []const u32 };
fn admitted(bir: *const Bir, base: *const ContinuationPlan.Artifact, scope: ContinuationPlan.Scope, parameters: []const u32) ?Admission {
    const decl = bir.decl(scope.decl);
    const root = decl.body.unwrap() orelse return null;
    if (bir.instTag(root) != .let) return null;
    const data = bir.instData(root);
    const defs = bir.extraSlice(bir.subRange(@fromBackingInt(data.lhs)), Bir.Inst.Index);
    if (defs.len != 1) return null;
    var input_kind: InputKind = .discarded_unit;
    var input_local: u32 = none;
    var input_definition: u32 = none;
    switch (bir.instTag(defs[0])) {
        .let_stmt => {},
        .let_def => {
            const definition = bir.extraData(@fromBackingInt(bir.instData(defs[0]).lhs), Bir.LetDef);
            if (definition.params_start != definition.params_end or definition.local >= decl.locals_end - decl.locals_start) return null;
            if (bir.locals[decl.locals_start + definition.local].inst != defs[0]) return null;
            input_kind = .bound_int;
            input_local = definition.local;
            input_definition = defs[0].int();
        },
        else => return null,
    }
    const suspension: Bir.Inst.Index = @fromBackingInt(bir.instData(defs[0]).rhs);
    if (bir.instTag(suspension) != .call and bir.instTag(suspension) != .method_call) return null;
    const body: Bir.Inst.Index = @fromBackingInt(data.rhs);
    if (bir.instTag(body) != .call) return null;
    const call = bir.instData(body);
    if (bir.instTag(@fromBackingInt(call.lhs)) != .local) return null;
    const scheme = base.types.schemes[@backingInt(scope.scheme)];
    const bundle = base.types.term(scheme.body);
    if (bundle.tag != .tuple) return null;
    const roots = base.types.range(bundle.lhs);
    if (roots.len < 2) return null;
    const body_type = base.types.term(@fromBackingInt(roots[1]));
    if (body_type.tag != .func) return null;
    const params = base.types.range(body_type.lhs);
    const patterns = bir.extraSlice(.{ .start = decl.params_start, .end = decl.params_end }, Bir.Inst.Index);
    if (params.len != patterns.len) return null;
    const callee_local = bir.instData(@fromBackingInt(call.lhs)).lhs;
    if (!parameterLocal(decl, callee_local, parameters, params.len)) return null;
    for (bir.extraSlice(bir.subRange(@fromBackingInt(call.rhs)), Bir.Inst.Index)) |arg| {
        if (bir.instTag(arg) != .local) return null;
        const local = bir.instData(arg).lhs;
        if (local != input_local and !parameterLocal(decl, local, parameters, params.len)) return null;
    }
    return .{ .input_kind = input_kind, .input_local = input_local, .input_definition = input_definition, .suspension = suspension, .body = body, .params = params, .output = @fromBackingInt(body_type.rhs) };
}
fn admittedInput(types: *const Interface, root: Interface.TermIndex, shape: Admission, interner: *const InternPool.Global) bool {
    const term = types.term(root);
    if (shape.input_kind == .discarded_unit) return term.tag == .unit;
    if (term.tag != .app or term.lhs >= types.type_refs.len or types.range(term.rhs).len != 0) return false;
    const ref = types.type_refs[term.lhs];
    return ref.package == .core and ref.body == .none and std.mem.eql(u8, interner.slice(types.symbol(ref.module)), "Basics") and std.mem.eql(u8, interner.slice(types.symbol(ref.name)), "Int");
}
fn parameterLocal(decl: Bir.Decl, local: u32, parameters: []const u32, arity: usize) bool {
    return local < decl.locals_end - decl.locals_start and parameters[decl.locals_start + local] < arity;
}
pub const Input = struct { source: ContinuationPlan.Input, local_type: []const TypeStore.Var.Optional };
pub const Error = Allocator.Error || error{ MissingEvidence, InvalidControlArtifact, InvalidControlCoverage };
pub fn build(in: Input) Error!Artifact {
    const s = in.source;
    const base = &s.dispatch.continuations;
    if (!base.present) return error.MissingEvidence;
    var out: Artifact = .{ .present = true };
    errdefer out.deinit(s.gpa);
    var sites: std.MultiArrayList(Site) = .empty;
    defer sites.deinit(s.gpa);
    var regions: std.MultiArrayList(Region) = .empty;
    defer regions.deinit(s.gpa);
    var captures: std.MultiArrayList(Capture) = .empty;
    defer captures.deinit(s.gpa);
    var operations: std.MultiArrayList(Operation) = .empty;
    defer operations.deinit(s.gpa);
    const parameters = try parameterMap(s.scratch, s.bir);
    defer s.scratch.free(parameters);
    if (parameters.len != s.bir.locals.len) return error.MissingEvidence;
    const seen = try s.scratch.alloc(u32, s.bir.locals.len);
    defer s.scratch.free(seen);
    @memset(seen, none);
    for (0..base.scopes.len) |scope_index| {
        const scope = base.scopes.get(scope_index);
        const decl = s.bir.decl(scope.decl);
        const shape = admitted(s.bir, base, scope, parameters);
        for (scope.start..@as(usize, scope.start) + scope.len) |si| {
            const source = base.sites.get(si);
            var site: Site = .{ .inst = source.inst };
            if (shape) |a| if (a.suspension == source.inst and admittedInput(&base.types, source.type, a, s.interner)) {
                const capture_start: u32 = @intCast(captures.len);
                const operation_start: u32 = @intCast(operations.len);
                const call = s.bir.instData(a.body);
                try appendOperation(&operations, s.gpa, s.bir, a.body);
                try appendOperation(&operations, s.gpa, s.bir, @fromBackingInt(call.lhs));
                for (s.bir.extraSlice(s.bir.subRange(@fromBackingInt(call.rhs)), Bir.Inst.Index)) |arg| try appendOperation(&operations, s.gpa, s.bir, arg);
                // The original checker proves the exact BIR parameter binding.
                // BODY display structures share its actual rigid variables but
                // intentionally have different function/record object Vars.
                for (operation_start + 1..operations.len) |oi| {
                    const local = operations.get(oi).lhs;
                    if (local == a.input_local) continue;
                    const absolute = decl.locals_start + local;
                    if (seen[absolute] == si) continue;
                    seen[absolute] = @intCast(si);
                    const parameter = parameters[absolute];
                    if (absolute >= in.local_type.len) return error.MissingEvidence;
                    _ = in.local_type[absolute].unwrap() orelse return error.MissingEvidence;
                    try captures.append(s.gpa, .{ .local = local, .definition = s.bir.locals[absolute].inst, .parameter = parameter, .type = @fromBackingInt(a.params[parameter]) });
                }
                site.region = @fromBackingInt(@intCast(regions.len));
                try regions.append(s.gpa, .{ .input_kind = a.input_kind, .input_local = a.input_local, .input_definition = a.input_definition, .decl = scope.decl, .suspension = source.inst, .body = a.body, .scheme = scope.scheme, .input = source.type, .output = a.output, .captures = .{ .start = capture_start, .len = @as(u32, @intCast(captures.len)) - capture_start }, .operations = .{ .start = operation_start, .len = @as(u32, @intCast(operations.len)) - operation_start } });
            };
            try sites.append(s.gpa, site);
        }
    }
    out.sites = sites.toOwnedSlice();
    out.regions = regions.toOwnedSlice();
    out.captures = captures.toOwnedSlice();
    out.operations = operations.toOwnedSlice();
    if (!try out.verify(s.gpa, s.interner)) return error.InvalidControlArtifact;
    if (!try out.verifyAgainstBir(s.gpa, s.bir, s.dispatch, s.interner)) return error.InvalidControlCoverage;
    return out;
}
fn appendOperation(rows: *std.MultiArrayList(Operation), gpa: Allocator, bir: *const Bir, inst: Bir.Inst.Index) Allocator.Error!void {
    const data = bir.instData(inst);
    try rows.append(gpa, .{ .inst = inst, .tag = bir.instTag(inst), .lhs = data.lhs, .rhs = data.rhs });
}
const magic = "BENICTL\x00";
const header_bytes = 32;
fn put(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn get(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
pub fn write(gpa: Allocator, a: *const Artifact, _: *const InternPool.Global) Allocator.Error![]u8 {
    if (!a.present) return gpa.alloc(u8, 0);
    const out = try gpa.alloc(u8, header_bytes + a.sites.len * 8 + a.regions.len * 52 + a.captures.len * 16 + a.operations.len * 16);
    @memcpy(out[0..8], magic);
    put(out, 8, schema_version);
    put(out, 12, @intCast(a.sites.len));
    put(out, 16, @intCast(a.regions.len));
    put(out, 20, @intCast(a.captures.len));
    put(out, 24, @intCast(a.operations.len));
    put(out, 28, 0);
    var at: usize = header_bytes;
    for (0..a.sites.len) |i| {
        const r = a.sites.get(i);
        put(out, at, r.inst.int());
        put(out, at + 4, @backingInt(r.region));
        at += 8;
    }
    for (0..a.regions.len) |i| {
        const r = a.regions.get(i);
        for ([_]u32{ r.decl.int(), r.suspension.int(), r.body.int(), @backingInt(r.scheme), r.input.int(), r.output.int(), r.captures.start, r.captures.len, r.operations.start, r.operations.len, @backingInt(r.input_kind), r.input_local, r.input_definition }, 0..) |v, j| put(out, at + j * 4, v);
        at += 52;
    }
    for (0..a.captures.len) |i| {
        const r = a.captures.get(i);
        put(out, at, r.local);
        put(out, at + 4, r.definition.int());
        put(out, at + 8, r.parameter);
        put(out, at + 12, r.type.int());
        at += 16;
    }
    for (0..a.operations.len) |i| {
        const r = a.operations.get(i);
        put(out, at, r.inst.int());
        put(out, at + 4, @backingInt(r.tag));
        put(out, at + 8, r.lhs);
        put(out, at + 12, r.rhs);
        at += 16;
    }
    return out;
}
pub const ReadError = iface_bytes.ReadError || error{BadPlan};
pub fn read(gpa: Allocator, bytes: []const u8, interner: *const InternPool.Global) ReadError!Artifact {
    return decode(gpa, bytes, interner);
}
pub fn readGrowing(gpa: Allocator, bytes: []const u8, interner: *InternPool.Global) ReadError!Artifact {
    return decode(gpa, bytes, interner);
}
fn decode(gpa: Allocator, bytes: []const u8, interner: *const InternPool.Global) ReadError!Artifact {
    if (bytes.len == 0) return .empty;
    if (bytes.len < header_bytes or !std.mem.eql(u8, bytes[0..8], magic) or get(bytes, 8) != schema_version or get(bytes, 28) != 0) return error.BadPlan;
    const ns = get(bytes, 12);
    const nr = get(bytes, 16);
    const nc = get(bytes, 20);
    const no = get(bytes, 24);
    if (@as(u64, header_bytes) + @as(u64, ns) * 8 + @as(u64, nr) * 52 + @as(u64, nc) * 16 + @as(u64, no) * 16 != bytes.len) return error.BadPlan;
    var a: Artifact = .{ .present = true };
    errdefer a.deinit(gpa);
    var sites: std.MultiArrayList(Site) = .empty;
    defer sites.deinit(gpa);
    var regions: std.MultiArrayList(Region) = .empty;
    defer regions.deinit(gpa);
    var captures: std.MultiArrayList(Capture) = .empty;
    defer captures.deinit(gpa);
    var operations: std.MultiArrayList(Operation) = .empty;
    defer operations.deinit(gpa);
    var at: usize = header_bytes;
    for (0..ns) |_| {
        try sites.append(gpa, .{ .inst = @fromBackingInt(get(bytes, at)), .region = @fromBackingInt(get(bytes, at + 4)) });
        at += 8;
    }
    for (0..nr) |_| {
        try regions.append(gpa, .{ .decl = @fromBackingInt(get(bytes, at)), .suspension = @fromBackingInt(get(bytes, at + 4)), .body = @fromBackingInt(get(bytes, at + 8)), .scheme = @fromBackingInt(get(bytes, at + 12)), .input = @fromBackingInt(get(bytes, at + 16)), .output = @fromBackingInt(get(bytes, at + 20)), .captures = .{ .start = get(bytes, at + 24), .len = get(bytes, at + 28) }, .operations = .{ .start = get(bytes, at + 32), .len = get(bytes, at + 36) }, .input_kind = std.enums.fromInt(InputKind, get(bytes, at + 40)) orelse return error.BadPlan, .input_local = get(bytes, at + 44), .input_definition = get(bytes, at + 48) });
        at += 52;
    }
    for (0..nc) |_| {
        try captures.append(gpa, .{ .local = get(bytes, at), .definition = @fromBackingInt(get(bytes, at + 4)), .parameter = get(bytes, at + 8), .type = @fromBackingInt(get(bytes, at + 12)) });
        at += 16;
    }
    for (0..no) |_| {
        try operations.append(gpa, .{ .inst = @fromBackingInt(get(bytes, at)), .tag = std.enums.fromInt(Bir.Inst.Tag, get(bytes, at + 4)) orelse return error.BadPlan, .lhs = get(bytes, at + 8), .rhs = get(bytes, at + 12) });
        at += 16;
    }
    a.sites = sites.toOwnedSlice();
    a.regions = regions.toOwnedSlice();
    a.captures = captures.toOwnedSlice();
    a.operations = operations.toOwnedSlice();
    if (!try a.verify(gpa, interner)) return error.BadPlan;
    return a;
}
test "control source codec distinguishes requested empty evidence and safely rejects truncation" {
    const gpa = std.testing.allocator;
    var interner = try InternPool.Global.init(gpa);
    defer interner.deinit(gpa);
    const absent_bytes = try write(gpa, &.empty, &interner);
    defer gpa.free(absent_bytes);
    try std.testing.expectEqual(@as(usize, 0), absent_bytes.len);
    var absent = try read(gpa, absent_bytes, &interner);
    defer absent.deinit(gpa);
    try std.testing.expect(!absent.present);
    const complete: Artifact = .{ .present = true };
    const bytes = try write(gpa, &complete, &interner);
    defer gpa.free(bytes);
    var restored = try read(gpa, bytes, &interner);
    defer restored.deinit(gpa);
    try std.testing.expect(restored.present);
    try std.testing.expectEqual(@as(usize, 0), restored.sites.len);
    try std.testing.expectEqual(@as(usize, 0), restored.regions.len);
    for (1..bytes.len) |n| try std.testing.expectError(error.BadPlan, read(gpa, bytes[0..n], &interner));
    const damaged = try gpa.dupe(u8, bytes);
    defer gpa.free(damaged);
    put(damaged, 8, schema_version + 1);
    try std.testing.expectError(error.BadPlan, read(gpa, damaged, &interner));
}
test "fuzz control source bytes never publish unchecked malformed evidence" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            var buffer: [4096]u8 = undefined;
            const n = smith.sliceWithHash(&buffer, 0xc01720);
            var interner = try InternPool.Global.init(std.testing.allocator);
            defer interner.deinit(std.testing.allocator);
            if (read(std.testing.allocator, buffer[0..n], &interner)) |value| {
                var artifact = value;
                defer artifact.deinit(std.testing.allocator);
                try std.testing.expect(try artifact.verify(std.testing.allocator, &interner));
            } else |_| {}
        }
    }.one, .{});
}
