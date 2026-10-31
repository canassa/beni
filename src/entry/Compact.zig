//! Source-finite symbolic entry IR (workers-entry-compact.md).
//! Rows are SoA, references are typed IDs, variable data uses one u32 sidecar.
//! A source template is shared by all calls; no row is a caller environment.
const std = @import("std");
const Allocator = std.mem.Allocator;
const sentinel = std.math.maxInt(u32);
const Compact = @This();

pub const Reason = enum(u8) { higher_order, projection, shape, native_flow, missing_body, missing_binding, unproductive, dispatch, metadata, materialization_control };

pub const BuilderCounters = struct {
    shape_port_work: u64 = 0,
    shape_edge_work: u64 = 0,
    shape_selector_work: u64 = 0,
    metadata_rows: u64 = 0,
    metadata_index_work: u64 = 0,
    metadata_lookup_work: u64 = 0,
    metadata_match_work: u64 = 0,
};

pub const ModuleId = enum(u32) { none = sentinel, _ };
pub const DeclarationId = enum(u32) { none = sentinel, _ };
pub const InstructionId = enum(u32) { none = sentinel, _ };
pub const LocalId = enum(u32) { none = sentinel, _ };
pub const TemplateId = enum(u32) { none = sentinel, _ };
pub const PortId = enum(u32) { none = sentinel, _ };
pub const InputId = enum(u32) { none = sentinel, _ };
pub const OriginId = enum(u32) { none = sentinel, _ };
pub const AllocationId = enum(u32) { none = sentinel, _ };
pub const CallId = enum(u32) { none = sentinel, _ };
pub const ConstructorId = enum(u32) { none = sentinel, _ };
pub const SealId = enum(u32) { none = sentinel, _ };
pub const SiteId = enum(u32) { none = sentinel, _ };
pub const SelectorId = enum(u32) { none = sentinel, _ };
pub const AnchorId = enum(u32) { none = sentinel, _ };
pub const KindId = enum(u32) { none = sentinel, _ };
pub const Range = struct { start: u32 = 0, len: u32 = 0 };

pub const Module = struct { declarations: Range };
pub const Declaration = struct { template: TemplateId = .none, exported: PortId = .none, anchor: AnchorId = .none };
pub const Site = struct { module: ModuleId, declaration: DeclarationId, instruction: InstructionId };
pub const Template = struct {
    site: SiteId,
    body: PortId = .none,
    inputs: Range = .{},
    /// Source lexical parent, not an invocation/caller ID.
    lexical: TemplateId = .none,
};
pub const Port = struct {
    owner: TemplateId,
    site: SiteId,
    tag: Tag,
    /// A typed table's backing ID, selected only by tag; analogous to BIR data.
    lhs: u32 = sentinel,
    rhs: u32 = sentinel,
    values: Range = .{},

    pub const Tag = enum(u8) {
        input,
        alias,
        alternatives,
        function,
        literal,
        @"opaque",
        runtime,
        allocation,
        closure,
        project,
        call,
        constructor,
        seal,
        residual,
    };
};
pub const Input = struct {
    owner: TemplateId,
    /// Index in the ordinary argument range OR capture range, selected by
    /// capture. Captures do not include ordinary argument count in this index.
    position: u32,
    port: PortId,
    capture: bool,
    defining: PortId = .none,
    source_local: LocalId = .none,
};
pub const Origin = struct {
    tag: Tag,
    site: SiteId,
    target: u32 = sentinel,
    pub const Tag = enum(u8) { function, literal, @"opaque", runtime, allocation, closure, constructor };
};
pub const Selector = struct {
    tag: enum(u8) { field, tuple },
    /// An interned field symbol or tuple element number, never a string.
    value: u32,
};
pub const Field = struct { allocation: AllocationId, selector: SelectorId, value: PortId };
pub const Allocation = struct {
    tag: enum(u8) { record, tuple, list, tagged },
    origin: OriginId,
    fields: Range,
    base: PortId = .none,
    /// All effective names known from checked/source shape. Unknown shapes
    /// remain residual; they are not inferred closed from an allocation origin.
    shape: Range = .{},
    shape_complete: bool = true,
};
pub const Call = struct {
    residual_reason: Reason = .higher_order,
    owner: TemplateId,
    site: SiteId,
    target: TemplateId,
    callee: PortId,
    arguments: Range,
    captures: Range = .{},
};
pub const Constructor = struct {
    kind: KindId,
    origin: OriginId,
    callbacks: PortId,
    roles: Range,
    arguments: Range = .{},
};
pub const Role = struct { selector: SelectorId, position: u32 };
pub const Seal = struct { anchor: AnchorId, kind: KindId, initializer: PortId };
pub const Anchor = struct { module: ModuleId, declaration: DeclarationId, kind: KindId, site: SiteId };
pub const Export = struct { owner: TemplateId, launch: u32, port: PortId };
pub const Execution = struct {
    owner: TemplateId,
    site: SiteId,
    tag: enum(u8) { known_call, launch, evaluate, descriptor, residual },
    target: u32,
    argument: PortId = .none,
};

counts: BuilderCounters = .{},
modules: std.MultiArrayList(Module) = .empty,
declarations: std.MultiArrayList(Declaration) = .empty,
sites: std.MultiArrayList(Site) = .empty,
templates: std.MultiArrayList(Template) = .empty,
ports: std.MultiArrayList(Port) = .empty,
inputs: std.MultiArrayList(Input) = .empty,
origins: std.MultiArrayList(Origin) = .empty,
selectors: std.MultiArrayList(Selector) = .empty,
fields: std.MultiArrayList(Field) = .empty,
allocations: std.MultiArrayList(Allocation) = .empty,
calls: std.MultiArrayList(Call) = .empty,
constructors: std.MultiArrayList(Constructor) = .empty,
roles: std.MultiArrayList(Role) = .empty,
seals: std.MultiArrayList(Seal) = .empty,
anchors: std.MultiArrayList(Anchor) = .empty,
execution: std.MultiArrayList(Execution) = .empty,
exports: std.MultiArrayList(Export) = .empty,
extra: std.ArrayList(u32) = .empty,

pub fn deinit(ir: *Compact, a: Allocator) void {
    inline for (comptime std.meta.fieldNames(Compact)) |name| if (comptime !std.mem.eql(u8, name, "counts")) {
        @field(ir, name).deinit(a);
    };
    ir.* = .{};
}

pub fn declaration(ir: *const Compact, module: ModuleId, index: DeclarationId) Declaration {
    return ir.declarations.get(ir.modules.get(@backingInt(module)).declarations.start + @backingInt(index));
}

pub fn ids(ir: *const Compact, comptime T: type, range: Range) []const T {
    comptime std.debug.assert(@sizeOf(T) == @sizeOf(u32));
    const words = ir.extra.items[range.start..][0..range.len];
    return @as([*]const T, @ptrCast(words.ptr))[0..words.len];
}

pub fn appendIds(ir: *Compact, a: Allocator, values: anytype) Allocator.Error!Range {
    const start: u32 = @intCast(ir.extra.items.len);
    try ir.extra.ensureUnusedCapacity(a, values.len);
    for (values) |value| ir.extra.appendAssumeCapacity(@backingInt(value));
    return .{ .start = start, .len = @intCast(values.len) };
}

pub fn addTemplate(ir: *Compact, a: Allocator, value: Template) Allocator.Error!TemplateId {
    const index: TemplateId = @fromBackingInt(@intCast(ir.templates.len));
    try ir.templates.append(a, value);
    return index;
}
pub fn addPort(ir: *Compact, a: Allocator, value: Port) Allocator.Error!PortId {
    const index: PortId = @fromBackingInt(@intCast(ir.ports.len));
    try ir.ports.append(a, value);
    return index;
}
pub fn addOrigin(ir: *Compact, a: Allocator, value: Origin) Allocator.Error!OriginId {
    const index: OriginId = @fromBackingInt(@intCast(ir.origins.len));
    try ir.origins.append(a, value);
    return index;
}
pub fn addInput(ir: *Compact, a: Allocator, value: Input) Allocator.Error!InputId {
    const index: InputId = @fromBackingInt(@intCast(ir.inputs.len));
    try ir.inputs.append(a, value);
    return index;
}
pub fn addAllocation(ir: *Compact, a: Allocator, value: Allocation) Allocator.Error!AllocationId {
    const index: AllocationId = @fromBackingInt(@intCast(ir.allocations.len));
    try ir.allocations.append(a, value);
    return index;
}
pub fn addCall(ir: *Compact, a: Allocator, value: Call) Allocator.Error!CallId {
    const index: CallId = @fromBackingInt(@intCast(ir.calls.len));
    try ir.calls.append(a, value);
    return index;
}
pub fn addConstructor(ir: *Compact, a: Allocator, value: Constructor) Allocator.Error!ConstructorId {
    const index: ConstructorId = @fromBackingInt(@intCast(ir.constructors.len));
    try ir.constructors.append(a, value);
    return index;
}
pub fn addSeal(ir: *Compact, a: Allocator, value: Seal) Allocator.Error!SealId {
    const index: SealId = @fromBackingInt(@intCast(ir.seals.len));
    try ir.seals.append(a, value);
    return index;
}
pub fn addAnchor(ir: *Compact, a: Allocator, value: Anchor) Allocator.Error!AnchorId {
    const index: AnchorId = @fromBackingInt(@intCast(ir.anchors.len));
    try ir.anchors.append(a, value);
    return index;
}

/// Sparse composite interning belongs to the builder, not the immutable IR.
/// Dense source/port IDs index columns directly; none is a hash-map key alone.
pub const Builder = struct {
    ir: *Compact,
    a: Allocator,
    site_index: std.AutoHashMapUnmanaged(Site, SiteId) = .empty,
    selector_index: std.AutoHashMapUnmanaged(Selector, SelectorId) = .empty,

    pub fn deinit(b: *Builder) void {
        b.site_index.deinit(b.a);
        b.selector_index.deinit(b.a);
    }
    pub fn site(b: *Builder, value: Site) Allocator.Error!SiteId {
        const entry = try b.site_index.getOrPut(b.a, value);
        if (entry.found_existing) return entry.value_ptr.*;
        const index: SiteId = @fromBackingInt(@intCast(b.ir.sites.len));
        try b.ir.sites.append(b.a, value);
        entry.value_ptr.* = index;
        return index;
    }
    pub fn selector(b: *Builder, value: Selector) Allocator.Error!SelectorId {
        const entry = try b.selector_index.getOrPut(b.a, value);
        if (entry.found_existing) return entry.value_ptr.*;
        const index: SelectorId = @fromBackingInt(@intCast(b.ir.selectors.len));
        try b.ir.selectors.append(b.a, value);
        entry.value_ptr.* = index;
        return index;
    }
};
