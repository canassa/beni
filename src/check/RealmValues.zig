//! Source-finite value origins. No actual-argument environments or type identity.
const std = @import("std");
const Realms = @import("Realms.zig");
const Allocator = std.mem.Allocator;
const PortId = Realms.PortId;
const none = Realms.none;
pub const Reason = enum(u8) { formal, pattern, opaque_value, value_cycle, unresolved_call, unsupported_control, foreign, missing_field, metadata };
pub const Kind = enum(u8) { scalar, callable, record, tuple, residual };
pub const Origin = struct { kind: Kind = .residual, value: u32 = none, reason: Reason = .opaque_value, witness: PortId = .none };
pub const Op = struct {
    kind: enum(u8) { scalar, callable, record, tuple, forward, call_result, field_call_result, field, tuple_index, residual } = .residual,
    a: u32 = none,
    b: u32 = none,
    reason: Reason = .opaque_value,
};
pub const Range = struct { start: u32 = 0, len: u32 = 0 };
pub const Work = struct { ports: u64 = 0, dependencies: u64 = 0, field_steps: u64 = 0, field_queries: u64 = 0, fields: u64 = 0 };
pub const Error = Allocator.Error || error{ InvalidPort, InvalidExec, InvalidField, DuplicateField };

/// One compact radix tree per original record. Branch bits strictly increase;
/// every field adds one leaf and at most one branch, and lookup takes <=32 bits.
pub const Fields = struct {
    const Node = struct { key: u32 = 0, value: PortId = .none, zero: u32 = none, one: u32 = none, bit: u8 = 32 };
    roots: []u32 = &.{},
    nodes: std.MultiArrayList(Node) = .empty,
    work: Work = .{},
    pub fn init(gpa: Allocator, count: usize) Allocator.Error!Fields {
        const roots = try gpa.alloc(u32, count);
        @memset(roots, none);
        return .{ .roots = roots };
    }
    pub fn deinit(f: *Fields, gpa: Allocator) void {
        gpa.free(f.roots);
        f.nodes.deinit(gpa);
        f.* = .{};
    }
    fn direction(key: u32, bit: u8) bool {
        return key & (@as(u32, 1) << @as(u5, @intCast(31 - bit))) != 0;
    }
    pub fn put(f: *Fields, gpa: Allocator, record: PortId, key: u32, value: PortId) Error!void {
        const root = @backingInt(record);
        if (root >= f.roots.len) return error.InvalidPort;
        const first = f.roots[root];
        if (first == none) {
            f.roots[root] = @intCast(f.nodes.len);
            try f.nodes.append(gpa, .{ .key = key, .value = value });
            f.work.fields += 1;
            return;
        }
        var at = first;
        while (f.nodes.get(at).bit != 32) {
            f.work.field_steps += 1;
            const n = f.nodes.get(at);
            at = if (direction(key, n.bit)) n.one else n.zero;
        }
        const old = f.nodes.get(at);
        if (old.key == key) return error.DuplicateField;
        const bit: u8 = @intCast(@clz(old.key ^ key));
        var parent: u32 = none;
        at = first;
        while (f.nodes.get(at).bit < bit) {
            f.work.field_steps += 1;
            parent = at;
            const n = f.nodes.get(at);
            at = if (direction(key, n.bit)) n.one else n.zero;
        }
        // Reserve both nodes before publishing a root/child link.
        try f.nodes.ensureUnusedCapacity(gpa, 2);
        const leaf: u32 = @intCast(f.nodes.len);
        f.nodes.appendAssumeCapacity(.{ .key = key, .value = value });
        const branch: u32 = @intCast(f.nodes.len);
        const right = direction(key, bit);
        f.nodes.appendAssumeCapacity(.{ .bit = bit, .zero = if (right) at else leaf, .one = if (right) leaf else at });
        if (parent == none) {
            f.roots[root] = branch;
        } else {
            var n = f.nodes.get(parent);
            if (direction(key, n.bit)) n.one = branch else n.zero = branch;
            f.nodes.set(parent, n);
        }
        f.work.fields += 1;
    }
    pub fn get(f: *Fields, record: PortId, key: u32) Error!PortId {
        const root = @backingInt(record);
        if (root >= f.roots.len) return error.InvalidPort;
        f.work.field_queries += 1;
        var at = f.roots[root];
        if (at == none) return .none;
        while (true) {
            f.work.field_steps += 1;
            const n = f.nodes.get(at);
            if (n.bit == 32) return if (n.key == key) n.value else .none;
            at = if (direction(key, n.bit)) n.one else n.zero;
        }
    }
};
pub const Input = struct {
    ops: std.MultiArrayList(Op).Slice,
    results: []const PortId,
    tuple_ranges: []const Range,
    tuple_ports: []const PortId,
    fields: *Fields,
};
pub const Result = struct {
    origins: std.MultiArrayList(Origin) = .empty,
    work: Work = .{},
    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.origins.deinit(gpa);
        r.* = .{};
    }
};
const Frame = struct { port: u32, stage: u8 = 0, dependency: u32 = none };
fn residual(port: u32, reason: Reason) Origin {
    return .{ .kind = .residual, .reason = reason, .witness = @fromBackingInt(port) };
}
pub fn solve(gpa: Allocator, in: Input) Error!Result {
    const count = in.ops.len;
    if (in.tuple_ranges.len != count) return error.InvalidPort;
    var out: Result = .{};
    errdefer out.deinit(gpa);
    try out.origins.resize(gpa, count);
    const states = try gpa.alloc(enum { unseen, visiting, finished }, count);
    defer gpa.free(states);
    @memset(states, .unseen);
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(gpa);
    for (0..count) |start| {
        if (states[start] == .finished) continue;
        try stack.append(gpa, .{ .port = @intCast(start) });
        while (stack.items.len != 0) {
            const index = stack.items.len - 1;
            var frame = stack.items[index];
            const id = frame.port;
            const op = in.ops.get(id);
            var done: ?Origin = null;
            var dependency: u32 = none;
            if (frame.stage == 0) {
                states[id] = .visiting;
                out.work.ports += 1;
                switch (op.kind) {
                    .scalar => done = .{ .kind = .scalar },
                    .callable => {
                        if (op.a >= in.results.len) return error.InvalidExec;
                        done = .{ .kind = .callable, .value = op.a };
                    },
                    .record => done = .{ .kind = .record, .value = id },
                    .tuple => done = .{ .kind = .tuple, .value = id },
                    .residual => done = residual(id, op.reason),
                    .forward, .call_result, .field_call_result, .field, .tuple_index => {
                        frame.stage = 1;
                        dependency = op.a;
                    },
                }
            } else if (frame.stage == 1) {
                const origin = out.origins.get(frame.dependency);
                switch (op.kind) {
                    .forward => done = origin,
                    .call_result => {
                        if (origin.kind == .residual) {
                            done = origin;
                        } else if (origin.kind != .callable) {
                            done = residual(id, .unresolved_call);
                        } else {
                            if (origin.value >= in.results.len) return error.InvalidExec;
                            dependency = @backingInt(in.results[origin.value]);
                            if (dependency == none) done = residual(id, .opaque_value) else frame.stage = 2;
                        }
                    },
                    .field, .field_call_result, .tuple_index => {
                        if (origin.kind == .residual) {
                            done = origin;
                        } else if ((op.kind == .field or op.kind == .field_call_result) and origin.kind == .record) {
                            dependency = @backingInt(try in.fields.get(@fromBackingInt(origin.value), op.b));
                            if (dependency == none) done = residual(id, .missing_field) else frame.stage = 2;
                        } else if (op.kind == .tuple_index and origin.kind == .tuple) {
                            if (origin.value >= in.tuple_ranges.len) return error.InvalidPort;
                            const range = in.tuple_ranges[origin.value];
                            if (range.start > in.tuple_ports.len or range.len > in.tuple_ports.len - range.start) return error.InvalidPort;
                            if (op.b >= range.len) {
                                done = residual(id, .missing_field);
                            } else {
                                dependency = @backingInt(in.tuple_ports[range.start + op.b]);
                                frame.stage = 2;
                            }
                        } else done = residual(id, .opaque_value);
                    },
                    else => unreachable,
                }
            } else if (frame.stage == 2 and op.kind == .field_call_result) {
                const origin = out.origins.get(frame.dependency);
                if (origin.kind == .residual) {
                    done = origin;
                } else if (origin.kind != .callable) {
                    done = residual(id, .unresolved_call);
                } else {
                    if (origin.value >= in.results.len) return error.InvalidExec;
                    dependency = @backingInt(in.results[origin.value]);
                    if (dependency == none) done = residual(id, .opaque_value) else frame.stage = 3;
                }
            } else {
                done = out.origins.get(frame.dependency);
            }
            if (done == null) {
                if (dependency >= count) return error.InvalidPort;
                out.work.dependencies += 1;
                frame.dependency = dependency;
                stack.items[index] = frame;
                switch (states[dependency]) {
                    .unseen => {
                        try stack.append(gpa, .{ .port = dependency });
                        continue;
                    },
                    .visiting => done = residual(dependency, .value_cycle),
                    .finished => continue,
                }
            }
            out.origins.set(id, done.?);
            states[id] = .finished;
            _ = stack.pop();
        }
    }
    return out;
}
