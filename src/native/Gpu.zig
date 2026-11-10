//! The WebGPU emitter of the native-bindings tool (`docs/design/webgpu.md`
//! §2.2, §2.3). From `webgpu.idl` in the pinned @webref/idl archive it writes
//! the `Browser.Host.GPU*` type modules into core and the generated
//! `Gpu.Types`, `Gpu.Flags`, `Gpu.Limits` and `Gpu.Native` modules into the
//! browser platform. Every IDL dictionary, enum, union typedef and flag
//! constant is either emitted or named in `excluded_dictionaries` with its
//! reason; nothing is skipped silently. Names follow the versioned maps below,
//! and a collision is a generator error, never a silent rename.
const std = @import("std");
const Generate = @import("Generate.zig");
const Idl = @import("Idl.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// The version of the name maps below. A change to any row is a new version.
pub const format_version: u32 = 1;
pub const idl_file = "webgpu.idl";

/// Where `zig build gpu-bindings` writes, relative to the repository root.
pub const core_dir = "core/Browser/Host";
pub const platform_dir = "platforms/browser-base/Gpu";

pub const Output = struct { path: []const u8, bytes: []const u8 };
pub const Code = enum { missing_input, exposure_mismatch, unsupported_type, name_collision, unmapped_name, invalid_member };
pub const Diagnostic = struct { code: Code, detail: []const u8, offset: u32 = 0 };
pub const Result = union(enum) { success: []const Output, failure: Diagnostic };

pub const Rename = struct { idl: []const u8, beni: []const u8 };

/// The 22 handle interfaces of §2.1, each aliased in `Gpu.Handle` by its name
/// without `GPU`, with §3's four exceptions.
pub const handle_interfaces = [_][]const u8{
    "GPUAdapter",            "GPUDevice",            "GPUQueue",               "GPUBuffer",
    "GPUTexture",            "GPUTextureView",       "GPUSampler",             "GPUExternalTexture",
    "GPUBindGroupLayout",    "GPUPipelineLayout",    "GPUBindGroup",           "GPUShaderModule",
    "GPUComputePipeline",    "GPURenderPipeline",    "GPUCommandEncoder",      "GPUCommandBuffer",
    "GPUComputePassEncoder", "GPURenderPassEncoder", "GPURenderBundleEncoder", "GPURenderBundle",
    "GPUQuerySet",           "GPUCanvasContext",
};
pub const handle_names = [_]Rename{
    .{ .idl = "GPUShaderModule", .beni = "Shader" },
    .{ .idl = "GPUComputePassEncoder", .beni = "ComputePass" },
    .{ .idl = "GPURenderPassEncoder", .beni = "RenderPass" },
    .{ .idl = "GPUCanvasContext", .beni = "Surface" },
};

/// Types whose generated name is not the IDL name without `GPU`.
pub const type_names = [_]Rename{
    .{ .idl = "GPURequestAdapterOptions", .beni = "AdapterOptions" },
};

/// Record fields whose IDL member name is a beni keyword.
pub const field_names = [_]Rename{
    .{ .idl = "type", .beni = "type_" },
};

/// Dictionaries not emitted as descriptors, each with its reason.
pub const Excluded = struct { idl: []const u8, reason: []const u8 };
pub const excluded_dictionaries = [_]Excluded{
    .{ .idl = "GPUPipelineErrorInit", .reason = "the constructor init of GPUPipelineError: beni makes the error as a pure value of Gpu.Error (webgpu.md §3; ledger §7)" },
    .{ .idl = "GPUUncapturedErrorEventInit", .reason = "the constructor init of GPUUncapturedErrorEvent: beni makes the event as a pure value (webgpu.md §3; ledger §7)" },
};

/// Every union a dictionary member names: the typedef's name, or an inline
/// union's text with single spaces. `arms` are the constructors, in the
/// union's own order. An arm whose type is an enum of one value carries no
/// payload: it is that value.
pub const Union = struct { key: []const u8, name: []const u8, arms: []const []const u8 };
pub const unions = [_]Union{
    .{ .key = "GPUBindingResource", .name = "BindingResource", .arms = &.{ "SamplerBinding", "TextureBinding", "TextureViewBinding", "WholeBufferBinding", "BufferRangeBinding", "ExternalTextureBinding" } },
    .{ .key = "GPUColor", .name = "Color", .arms = &.{ "ColorSequence", "ColorFields" } },
    .{ .key = "GPUOrigin2D", .name = "Origin2D", .arms = &.{ "Origin2DSequence", "Origin2DFields" } },
    .{ .key = "GPUOrigin3D", .name = "Origin3D", .arms = &.{ "Origin3DSequence", "Origin3DFields" } },
    .{ .key = "GPUExtent3D", .name = "Extent3D", .arms = &.{ "Extent3DSequence", "Extent3DFields" } },
    .{ .key = "GPUCopyExternalImageSource", .name = "CopyExternalImageSource", .arms = &.{ "Bitmap", "ImageData", "ImageElement", "VideoElement", "VideoFrame", "CanvasElement", "OffscreenCanvas" } },
    .{ .key = "(GPUPipelineLayout or GPUAutoLayoutMode)", .name = "PipelineLayoutMode", .arms = &.{ "Explicit", "Auto" } },
    .{ .key = "(HTMLVideoElement or VideoFrame)", .name = "ExternalTextureSource", .arms = &.{ "ExternalVideoElement", "ExternalVideoFrame" } },
    .{ .key = "(GPUTexture or GPUTextureView)", .name = "AttachmentView", .arms = &.{ "AttachmentTexture", "AttachmentTextureView" } },
};

/// Enum values whose constructor is not their spelling in PascalCase: a
/// spelling that starts with a digit, or one another enum of the module
/// spells too.
pub const EnumValue = struct { idl: []const u8, value: []const u8, beni: []const u8 };
pub const enum_values = [_]EnumValue{
    .{ .idl = "GPUAutoLayoutMode", .value = "auto", .beni = "AutoLayout" },
    .{ .idl = "GPUTextureDimension", .value = "1d", .beni = "Dimension1D" },
    .{ .idl = "GPUTextureDimension", .value = "2d", .beni = "Dimension2D" },
    .{ .idl = "GPUTextureDimension", .value = "3d", .beni = "Dimension3D" },
    .{ .idl = "GPUTextureViewDimension", .value = "1d", .beni = "View1D" },
    .{ .idl = "GPUTextureViewDimension", .value = "2d", .beni = "View2D" },
    .{ .idl = "GPUTextureViewDimension", .value = "2d-array", .beni = "View2DArray" },
    .{ .idl = "GPUTextureViewDimension", .value = "3d", .beni = "View3D" },
};
/// Enums whose every constructor carries a prefix, so that no two enums of
/// the module spell one constructor.
pub const enum_prefixes = [_]Rename{
    .{ .idl = "GPUTextureViewDimension", .beni = "View" },
    .{ .idl = "GPUFeatureName", .beni = "Feature" },
    .{ .idl = "GPUErrorFilter", .beni = "Filter" },
    .{ .idl = "GPUPipelineErrorReason", .beni = "Reason" },
    .{ .idl = "GPUMipmapFilterMode", .beni = "Mipmap" },
    .{ .idl = "GPUIndexFormat", .beni = "Index" },
    .{ .idl = "GPUStencilOperation", .beni = "Stencil" },
};

/// The five flag domains of §3 item 4.
pub const FlagDomain = struct { namespace: []const u8, typedef: []const u8, member: []const u8, set: []const u8, make: []const u8 };
pub const flag_domains = [_]FlagDomain{
    .{ .namespace = "GPUBufferUsage", .typedef = "GPUBufferUsageFlags", .member = "BufferUsage", .set = "BufferUsages", .make = "buffer" },
    .{ .namespace = "GPUTextureUsage", .typedef = "GPUTextureUsageFlags", .member = "TextureUsage", .set = "TextureUsages", .make = "texture" },
    .{ .namespace = "GPUShaderStage", .typedef = "GPUShaderStageFlags", .member = "ShaderStage", .set = "ShaderStages", .make = "shaderStages" },
    .{ .namespace = "GPUColorWrite", .typedef = "GPUColorWriteFlags", .member = "ColorWrite", .set = "ColorWrites", .make = "colorWrites" },
    .{ .namespace = "GPUMapMode", .typedef = "GPUMapModeFlags", .member = "MapMode", .set = "MapModes", .make = "mapModes" },
};
/// Flag constants whose constructor is not their name in PascalCase.
pub const FlagName = struct { namespace: []const u8, constant: []const u8, beni: []const u8 };
pub const flag_names = [_]FlagName{
    .{ .namespace = "GPUTextureUsage", .constant = "COPY_SRC", .beni = "TextureCopySrc" },
    .{ .namespace = "GPUTextureUsage", .constant = "COPY_DST", .beni = "TextureCopyDst" },
    .{ .namespace = "GPUShaderStage", .constant = "VERTEX", .beni = "VertexStage" },
    .{ .namespace = "GPUShaderStage", .constant = "FRAGMENT", .beni = "FragmentStage" },
    .{ .namespace = "GPUShaderStage", .constant = "COMPUTE", .beni = "ComputeStage" },
};

/// Numeric typedefs and the `Gpu.Scalar` type each one is (§3.1).
pub const Scalar = enum { u32, i32, size64, f32, f64 };
pub const scalar_typedefs = [_]struct { idl: []const u8, scalar: Scalar }{
    .{ .idl = "GPUSize64", .scalar = .size64 },
    .{ .idl = "GPUSize32", .scalar = .u32 },
    .{ .idl = "GPUIntegerCoordinate", .scalar = .u32 },
    .{ .idl = "GPUIndex32", .scalar = .u32 },
    .{ .idl = "GPUStencilValue", .scalar = .u32 },
    .{ .idl = "GPUSampleMask", .scalar = .u32 },
    .{ .idl = "GPUBufferDynamicOffset", .scalar = .u32 },
    .{ .idl = "GPUSignedOffset32", .scalar = .i32 },
    .{ .idl = "GPUDepthBias", .scalar = .i32 },
    .{ .idl = "GPUPipelineConstantValue", .scalar = .f64 },
};

/// Snapshot members a host may lack: each is newer than the rest of its
/// interface or belongs to an optional feature, so a host without it is not
/// a broken host. They are `Maybe Int`; every other member a snapshot reads
/// must be there with its IDL type, or the read is a defect naming it.
pub const OptionalMember = struct { owner: []const u8, member: []const u8, reason: []const u8 };
pub const optional_members = [_]OptionalMember{
    .{ .owner = "GPUSupportedLimits", .member = "maxImmediateSize", .reason = "immediate data, added to the standard in 2025" },
    .{ .owner = "GPUSupportedLimits", .member = "maxStorageBuffersInVertexStage", .reason = "per-stage storage limits, added in 2025 with compatibility mode" },
    .{ .owner = "GPUSupportedLimits", .member = "maxStorageBuffersInFragmentStage", .reason = "per-stage storage limits, added in 2025 with compatibility mode" },
    .{ .owner = "GPUSupportedLimits", .member = "maxStorageTexturesInVertexStage", .reason = "per-stage storage limits, added in 2025 with compatibility mode" },
    .{ .owner = "GPUSupportedLimits", .member = "maxStorageTexturesInFragmentStage", .reason = "per-stage storage limits, added in 2025 with compatibility mode" },
    .{ .owner = "GPUAdapterInfo", .member = "subgroupMinSize", .reason = "the subgroups feature" },
    .{ .owner = "GPUAdapterInfo", .member = "subgroupMaxSize", .reason = "the subgroups feature" },
};

/// The limits of the *alignment* class (WebGPU, *Limits*): a better value is
/// lower, and it is a power of two. Every other limit is a maximum; a `min…`
/// limit this table does not name stops generation, since its class is
/// unknown.
pub const alignment_limits = [_][]const u8{ "minUniformBufferOffsetAlignment", "minStorageBufferOffsetAlignment" };

/// The sequence arm of a union whose native conversion checks its length
/// (WebGPU, *validate GPUColor shape*, *GPUOrigin2D*, *GPUOrigin3D*,
/// *GPUExtent3D shape*): the arm carries an opaque list made only by a
/// constructor that checks the length, so a value of the arm never throws.
pub const SequenceShape = struct { union_key: []const u8, list: []const u8, min: u32, max: u32 };
pub const sequence_shapes = [_]SequenceShape{
    .{ .union_key = "GPUColor", .list = "ColorList", .min = 4, .max = 4 },
    .{ .union_key = "GPUOrigin2D", .list = "Origin2DList", .min = 0, .max = 2 },
    .{ .union_key = "GPUOrigin3D", .list = "Origin3DList", .min = 0, .max = 3 },
    .{ .union_key = "GPUExtent3D", .list = "Extent3DList", .min = 1, .max = 3 },
};

fn sequenceShape(key: []const u8) ?SequenceShape {
    for (sequence_shapes) |s| if (std.mem.eql(u8, s.union_key, key)) return s;
    return null;
}

/// The snapshot interfaces whose readonly attributes become a record.
pub const snapshots = [_]Rename{
    .{ .idl = "GPUAdapterInfo", .beni = "AdapterInfo" },
};

// ---------------------------------------------------------------------
// IDL types of dictionary members.

const Ty = union(enum) {
    named: []const u8,
    clamp_u16,
    sequence: *const Ty,
    record: *const Ty,
    union_: struct { key: []const u8, arms: []const Ty },
    nullable: *const Ty,
    undefined_,
};

const Field = struct { name: []const u8, idl_name: []const u8, ty: Ty, required: bool };
const Dictionary = struct { idl: []const u8, name: []const u8, parent: ?[]const u8, own: []const Field, decl: u32 };
const Enum = struct { idl: []const u8, name: []const u8, values: []const []const u8, ctors: []const []const u8 };
const Constant = struct { name: []const u8, value: u32 };
const Flags = struct { domain: FlagDomain, constants: []const Constant, ctors: []const []const u8 };
const Attribute = struct { name: []const u8, ty: []const u8, reader: []const u8 };

const Model = struct {
    arena: Allocator,
    c: Generate.Catalogue,
    file: u32,
    dictionaries: std.ArrayList(Dictionary) = .empty,
    enums: std.ArrayList(Enum) = .empty,
    flags: std.ArrayList(Flags) = .empty,
    used_unions: std.ArrayList(Union) = .empty,
    union_arms: std.ArrayList([]const Ty) = .empty,
    hosts: std.ArrayList([]const u8) = .empty,
    limits: []const Attribute = &.{},
    failure: ?Diagnostic = null,

    fn fail(m: *Model, code: Code, detail: []const u8, offset: u32) error{Failed} {
        m.failure = .{ .code = code, .detail = detail, .offset = offset };
        return error.Failed;
    }
};

const Error = Allocator.Error || error{Failed};

pub fn generate(arena: Allocator, c: Generate.Catalogue) Allocator.Error!Result {
    var m: Model = .{ .arena = arena, .c = c, .file = undefined };
    run(&m) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => return .{ .failure = m.failure.? },
    };
    var out: std.ArrayList(Output) = .empty;
    emitAll(&m, &out) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.OutOfMemory,
        error.Failed => return .{ .failure = m.failure.? },
    };
    return .{ .success = try out.toOwnedSlice(arena) };
}

fn run(m: *Model) Error!void {
    const c = m.c;
    m.file = for (c.files, 0..) |f, i| {
        if (std.mem.eql(u8, f.path, idl_file)) break @intCast(i);
    } else return m.fail(.missing_input, idl_file, 0);
    try checkExposure(m);
    for (c.declarations, 0..) |d, i| {
        if (d.file != m.file or d.partial) continue;
        switch (d.kind) {
            .enumeration => try addEnum(m, @intCast(i)),
            .namespace => try addFlags(m, @intCast(i)),
            else => {},
        }
    }
    // PredefinedColorSpace is HTML's enum, named by GPU dictionaries.
    try addEnum(m, primary(c, "PredefinedColorSpace") orelse return m.fail(.missing_input, "PredefinedColorSpace", 0));
    for (c.declarations, 0..) |d, i| {
        if (d.file != m.file or d.kind != .dictionary) continue;
        if (d.partial) return m.fail(.unsupported_type, d.name, d.source_span.start);
        if (excluded(d.name)) continue;
        try addDictionary(m, @intCast(i));
    }
    // Resolve every field type now, so an unsupported one fails before output.
    for (m.dictionaries.items) |dict| for (dict.own) |f| try collectUnions(m, f.ty);
    try nameEnums(m);
    try checkCollisions(m);
    const limits = primary(c, "GPUSupportedLimits") orelse return m.fail(.missing_input, "GPUSupportedLimits", 0);
    m.limits = try attributes(m, limits);
}

fn primary(c: Generate.Catalogue, name: []const u8) ?u32 {
    for (c.declarations, 0..) |d, i| {
        if (!d.partial and d.kind != .includes and std.mem.eql(u8, d.name, name)) return @intCast(i);
    }
    return null;
}

fn excluded(name: []const u8) bool {
    for (excluded_dictionaries) |e| if (std.mem.eql(u8, e.idl, name)) return true;
    return false;
}

fn rename(table: []const Rename, idl: []const u8) ?[]const u8 {
    for (table) |r| if (std.mem.eql(u8, r.idl, idl)) return r.beni;
    return null;
}

fn dropGpu(name: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, "GPU")) name[3..] else name;
}

pub fn typeName(idl: []const u8) []const u8 {
    return rename(&type_names, idl) orelse dropGpu(idl);
}

pub fn handleName(idl: []const u8) []const u8 {
    return rename(&handle_names, idl) orelse dropGpu(idl);
}

fn isHandle(idl: []const u8) bool {
    for (handle_interfaces) |h| if (std.mem.eql(u8, h, idl)) return true;
    return false;
}

// ---------------------------------------------------------------------
// §2.3: every WebGPU declaration is exposed in exactly (Window, Worker).

fn exposedExactly(names: []const []const u8) bool {
    var window = false;
    var worker = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "Window")) {
            if (window) return false;
            window = true;
        } else if (std.mem.eql(u8, n, "Worker")) {
            if (worker) return false;
            worker = true;
        } else return false;
    }
    return window and worker;
}

fn checkExposure(m: *Model) Error!void {
    const c = m.c;
    for (c.declarations) |d| {
        if (d.file != m.file) continue;
        const source = c.files[d.file].source;
        const attrs = d.attributes_span.text(source);
        const exposed = Idl.attributeNames(m.arena, attrs, "Exposed") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidIdl => return m.fail(.exposure_mismatch, d.name, d.source_span.start),
        };
        switch (d.kind) {
            .interface, .namespace => if (!d.partial and !exposedExactly(exposed)) {
                return m.fail(.exposure_mismatch, d.name, d.source_span.start);
            } else if (d.partial and exposed.len != 0 and !exposedExactly(exposed)) {
                return m.fail(.exposure_mismatch, d.name, d.source_span.start);
            },
            .mixin => if (exposed.len != 0) return m.fail(.exposure_mismatch, d.name, d.source_span.start),
            .includes => {},
            else => if (exposed.len != 0 and !exposedExactly(exposed)) return m.fail(.exposure_mismatch, d.name, d.source_span.start),
        }
        // A member with an [Exposed] of its own.
        for (c.members[d.members_start..d.members_end]) |member| {
            const text = member.source_span.text(c.files[member.file].source);
            if (text.len == 0 or text[0] != '[') continue;
            const close = std.mem.findScalar(u8, text, ']') orelse continue;
            const names = Idl.attributeNames(m.arena, text[0 .. close + 1], "Exposed") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidIdl => return m.fail(.exposure_mismatch, text, member.source_span.start),
            };
            if (names.len != 0 and !exposedExactly(names)) return m.fail(.exposure_mismatch, text, member.source_span.start);
        }
    }
    // A mixin of the file reaches exactly Window and Worker through the
    // interfaces that include it: each is within (Window, Worker), and
    // together they are both.
    for (c.declarations, 0..) |mixin, mi| {
        if (mixin.file != m.file or mixin.kind != .mixin or mixin.partial) continue;
        var window = false;
        var worker = false;
        for (c.declarations) |inc| {
            if (inc.kind != .includes or !std.mem.eql(u8, inc.parent.?, mixin.name)) continue;
            const target = primary(c, inc.name) orelse return m.fail(.exposure_mismatch, inc.name, inc.source_span.start);
            const t = c.declarations[target];
            const names = Idl.attributeNames(m.arena, t.attributes_span.text(c.files[t.file].source), "Exposed") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidIdl => return m.fail(.exposure_mismatch, inc.name, inc.source_span.start),
            };
            for (names) |n| {
                if (std.mem.eql(u8, n, "Window")) {
                    window = true;
                } else if (std.mem.eql(u8, n, "Worker")) {
                    worker = true;
                } else return m.fail(.exposure_mismatch, inc.name, inc.source_span.start);
            }
        }
        _ = mi;
        if (!window or !worker) return m.fail(.exposure_mismatch, mixin.name, mixin.source_span.start);
    }
}

// ---------------------------------------------------------------------
// Member tokens: identifiers, numbers, strings and single punctuation.

const Tokens = struct {
    items: []const []const u8,
    at: usize = 0,

    fn peek(t: *Tokens) []const u8 {
        return if (t.at < t.items.len) t.items[t.at] else "";
    }
    fn eat(t: *Tokens, text: []const u8) bool {
        if (!std.mem.eql(u8, t.peek(), text)) return false;
        t.at += 1;
        return true;
    }
    fn next(t: *Tokens) []const u8 {
        const s = t.peek();
        if (t.at < t.items.len) t.at += 1;
        return s;
    }
};

fn tokenize(arena: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (std.ascii.isWhitespace(ch)) {
            i += 1;
        } else if (std.mem.startsWith(u8, text[i..], "//")) {
            while (i < text.len and text[i] != '\n') i += 1;
        } else if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            const start = i;
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '-' or text[i] == '.')) i += 1;
            try out.append(arena, text[start..i]);
        } else if (ch == '"') {
            const start = i;
            i += 1;
            while (i < text.len and text[i] != '"') i += 1;
            i += 1;
            try out.append(arena, text[start..@min(i, text.len)]);
        } else {
            try out.append(arena, text[i .. i + 1]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

fn parseType(m: *Model, t: *Tokens, offset: u32) Error!Ty {
    var clamp = false;
    if (t.eat("[")) {
        while (!t.eat("]")) {
            const a = t.next();
            if (a.len == 0) return m.fail(.invalid_member, "unterminated extended attribute", offset);
            if (std.mem.eql(u8, a, "Clamp")) clamp = true;
        }
    }
    var ty: Ty = undefined;
    if (t.eat("(")) {
        var arms: std.ArrayList(Ty) = .empty;
        var key: std.ArrayList(u8) = .empty;
        try key.appendSlice(m.arena, "(");
        while (true) {
            const before = t.at;
            const arm = try parseType(m, t, offset);
            for (t.items[before..t.at], 0..) |tok, k| {
                if (k > 0 and !std.mem.eql(u8, tok, "<") and !std.mem.eql(u8, tok, ">") and !std.mem.eql(u8, t.items[before + k - 1], "<")) try key.appendSlice(m.arena, " ");
                try key.appendSlice(m.arena, tok);
            }
            try arms.append(m.arena, arm);
            if (t.eat(")")) break;
            if (!t.eat("or")) return m.fail(.invalid_member, "union", offset);
            try key.appendSlice(m.arena, " or ");
        }
        try key.appendSlice(m.arena, ")");
        ty = .{ .union_ = .{ .key = try key.toOwnedSlice(m.arena), .arms = try arms.toOwnedSlice(m.arena) } };
    } else {
        const word = t.next();
        if (std.mem.eql(u8, word, "sequence")) {
            if (!t.eat("<")) return m.fail(.invalid_member, "sequence", offset);
            const inner = try m.arena.create(Ty);
            inner.* = try parseType(m, t, offset);
            if (!t.eat(">")) return m.fail(.invalid_member, "sequence", offset);
            ty = .{ .sequence = inner };
        } else if (std.mem.eql(u8, word, "record")) {
            if (!t.eat("<")) return m.fail(.invalid_member, "record", offset);
            const key = try parseType(m, t, offset);
            if (key != .named or !(std.mem.eql(u8, key.named, "DOMString") or std.mem.eql(u8, key.named, "USVString"))) return m.fail(.unsupported_type, "record key", offset);
            if (!t.eat(",")) return m.fail(.invalid_member, "record", offset);
            const inner = try m.arena.create(Ty);
            inner.* = try parseType(m, t, offset);
            if (!t.eat(">")) return m.fail(.invalid_member, "record", offset);
            ty = .{ .record = inner };
        } else if (std.mem.eql(u8, word, "unsigned")) {
            const size = t.next();
            if (std.mem.eql(u8, size, "short")) {
                if (!clamp) return m.fail(.unsupported_type, "unsigned short without [Clamp]", offset);
                ty = .clamp_u16;
            } else return m.fail(.unsupported_type, "unsigned integer outside a GPU typedef", offset);
        } else if (std.mem.eql(u8, word, "undefined")) {
            ty = .undefined_;
        } else if (word.len == 0) {
            return m.fail(.invalid_member, "type", offset);
        } else {
            ty = .{ .named = word };
        }
    }
    if (t.eat("?")) {
        const inner = try m.arena.create(Ty);
        inner.* = ty;
        ty = .{ .nullable = inner };
    }
    return ty;
}

fn addDictionary(m: *Model, decl: u32) Error!void {
    const c = m.c;
    const d = c.declarations[decl];
    var own: std.ArrayList(Field) = .empty;
    for (c.members[d.members_start..d.members_end]) |member| {
        const text = member.source_span.text(c.files[member.file].source);
        var t: Tokens = .{ .items = try tokenize(m.arena, text) };
        const required = t.eat("required");
        const ty = try parseType(m, &t, member.source_span.start);
        const name = t.next();
        if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return m.fail(.invalid_member, text, member.source_span.start);
        try own.append(m.arena, .{ .name = rename(&field_names, name) orelse name, .idl_name = name, .ty = ty, .required = required });
    }
    try m.dictionaries.append(m.arena, .{ .idl = d.name, .name = typeName(d.name), .parent = d.parent, .own = try own.toOwnedSlice(m.arena), .decl = decl });
}

fn findDictionary(m: *Model, idl: []const u8) ?Dictionary {
    for (m.dictionaries.items) |d| if (std.mem.eql(u8, d.idl, idl)) return d;
    return null;
}

/// Every field of a dictionary, inherited ones first.
fn allFields(m: *Model, d: Dictionary) Error![]const Field {
    var out: std.ArrayList(Field) = .empty;
    if (d.parent) |p| {
        const parent = findDictionary(m, p) orelse return m.fail(.unsupported_type, p, 0);
        try out.appendSlice(m.arena, try allFields(m, parent));
    }
    try out.appendSlice(m.arena, d.own);
    return out.toOwnedSlice(m.arena);
}

fn addEnum(m: *Model, decl: u32) Error!void {
    const d = m.c.declarations[decl];
    const text = d.source_span.text(m.c.files[d.file].source);
    var values: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    // Strings inside the body; comments hold no quotes in the pin, but skip
    // them anyway.
    const body = std.mem.findScalar(u8, text, '{') orelse return m.fail(.invalid_member, d.name, d.source_span.start);
    i = body;
    while (i < text.len) : (i += 1) {
        if (std.mem.startsWith(u8, text[i..], "//")) {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (text[i] != '"') continue;
        const end = std.mem.findScalarPos(u8, text, i + 1, '"') orelse return m.fail(.invalid_member, d.name, d.source_span.start);
        try values.append(m.arena, text[i + 1 .. end]);
        i = end;
    }
    try m.enums.append(m.arena, .{ .idl = d.name, .name = typeName(d.name), .values = try values.toOwnedSlice(m.arena), .ctors = &.{} });
}

fn pascal(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    if (text.len == 0 or !std.ascii.isAlphabetic(text[0])) return null;
    var out: std.ArrayList(u8) = .empty;
    var upper = true;
    for (text) |ch| {
        if (ch == '-' or ch == '_') {
            upper = true;
            continue;
        }
        if (!std.ascii.isAlphanumeric(ch)) return null;
        try out.append(arena, if (upper) std.ascii.toUpper(ch) else ch);
        upper = false;
    }
    return try out.toOwnedSlice(arena);
}

/// SCREAMING_CASE to PascalCase: `MAP_READ` is `MapRead`.
fn constantName(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var upper = true;
    for (text) |ch| {
        if (ch == '_') {
            upper = true;
            continue;
        }
        try out.append(arena, if (upper) std.ascii.toUpper(ch) else std.ascii.toLower(ch));
        upper = false;
    }
    return out.toOwnedSlice(arena);
}

fn nameEnums(m: *Model) Error!void {
    for (m.enums.items) |*e| {
        const ctors = try m.arena.alloc([]const u8, e.values.len);
        for (e.values, ctors) |value, *ctor| {
            ctor.* = for (enum_values) |row| {
                if (std.mem.eql(u8, row.idl, e.idl) and std.mem.eql(u8, row.value, value)) break row.beni;
            } else blk: {
                const base = try pascal(m.arena, value) orelse return m.fail(.unmapped_name, try std.fmt.allocPrint(m.arena, "{s} \"{s}\"", .{ e.idl, value }), 0);
                const prefix = rename(&enum_prefixes, e.idl) orelse "";
                break :blk try std.mem.concat(m.arena, u8, &.{ prefix, base });
            };
        }
        e.ctors = ctors;
    }
}

fn addFlags(m: *Model, decl: u32) Error!void {
    const c = m.c;
    const d = c.declarations[decl];
    const domain = for (flag_domains) |f| {
        if (std.mem.eql(u8, f.namespace, d.name)) break f;
    } else return m.fail(.unmapped_name, d.name, d.source_span.start);
    var constants: std.ArrayList(Constant) = .empty;
    var ctors: std.ArrayList([]const u8) = .empty;
    for (c.members[d.members_start..d.members_end]) |member| {
        const text = member.source_span.text(c.files[member.file].source);
        var t: Tokens = .{ .items = try tokenize(m.arena, text) };
        if (!t.eat("const") or !t.eat("GPUFlagsConstant")) return m.fail(.invalid_member, text, member.source_span.start);
        const name = t.next();
        if (!t.eat("=")) return m.fail(.invalid_member, text, member.source_span.start);
        const value = std.fmt.parseInt(u32, t.next(), 0) catch return m.fail(.invalid_member, text, member.source_span.start);
        try constants.append(m.arena, .{ .name = name, .value = value });
        try ctors.append(m.arena, for (flag_names) |row| {
            if (std.mem.eql(u8, row.namespace, d.name) and std.mem.eql(u8, row.constant, name)) break row.beni;
        } else try constantName(m.arena, name));
    }
    try m.flags.append(m.arena, .{ .domain = domain, .constants = try constants.toOwnedSlice(m.arena), .ctors = try ctors.toOwnedSlice(m.arena) });
}

fn attributes(m: *Model, decl: u32) Error![]const Attribute {
    const c = m.c;
    const d = c.declarations[decl];
    var out: std.ArrayList(Attribute) = .empty;
    for (c.members[d.members_start..d.members_end]) |member| {
        const text = member.source_span.text(c.files[member.file].source);
        var t: Tokens = .{ .items = try tokenize(m.arena, text) };
        if (!t.eat("readonly") or !t.eat("attribute")) return m.fail(.invalid_member, text, member.source_span.start);
        var ty: []const u8 = undefined;
        const word = t.next();
        if (std.mem.eql(u8, word, "unsigned")) {
            _ = t.eat("long");
            _ = t.eat("long");
            ty = "Int";
        } else if (std.mem.eql(u8, word, "DOMString")) {
            ty = "String";
        } else if (std.mem.eql(u8, word, "boolean")) {
            ty = "Bool";
        } else return m.fail(.unsupported_type, text, member.source_span.start);
        const name = t.next();
        if (!t.eat(";")) return m.fail(.invalid_member, text, member.source_span.start);
        const optional = for (optional_members) |row| {
            if (std.mem.eql(u8, row.owner, d.name) and std.mem.eql(u8, row.member, name)) break true;
        } else false;
        if (optional and !std.mem.eql(u8, ty, "Int")) return m.fail(.unsupported_type, text, member.source_span.start);
        try out.append(m.arena, .{
            .name = name,
            .ty = if (optional) "Maybe Int" else ty,
            .reader = if (optional) "readOptionalInt" else if (std.mem.eql(u8, ty, "Int")) "readInt" else if (std.mem.eql(u8, ty, "String")) "readString" else "readBool",
        });
    }
    // A row of the table that names no member is stale.
    for (optional_members) |row| {
        if (!std.mem.eql(u8, row.owner, d.name)) continue;
        for (out.items) |a| {
            if (std.mem.eql(u8, a.name, row.member)) break;
        } else return m.fail(.unmapped_name, row.member, d.source_span.start);
    }
    return out.toOwnedSlice(m.arena);
}

// ---------------------------------------------------------------------
// Type resolution.

const Kind = union(enum) {
    bool_,
    string,
    clamp_u16,
    scalar: Scalar,
    flags: FlagDomain,
    enumeration: Enum,
    dictionary: Dictionary,
    handle: []const u8,
    host: []const u8,
    union_: usize,
    limits_record,
};

fn findEnum(m: *Model, idl: []const u8) ?Enum {
    for (m.enums.items) |e| if (std.mem.eql(u8, e.idl, idl)) return e;
    return null;
}

fn typedefText(m: *Model, idl: []const u8) ?[]const u8 {
    const c = m.c;
    for (c.declarations) |d| {
        if (d.kind != .typedef or !std.mem.eql(u8, d.name, idl)) continue;
        const text = d.source_span.text(c.files[d.file].source);
        // `typedef <type> <name>;`
        const body = text["typedef".len..];
        const end = std.mem.findLast(u8, body, idl) orelse return null;
        return std.mem.trim(u8, body[0..end], " \t\r\n");
    }
    return null;
}

fn unionIndex(m: *Model, key: []const u8, arms: []const Ty) Error!usize {
    for (m.used_unions.items, 0..) |u, i| if (std.mem.eql(u8, u.key, key)) return i;
    const row = for (unions) |u| {
        if (std.mem.eql(u8, u.key, key)) break u;
    } else return m.fail(.unmapped_name, key, 0);
    if (row.arms.len != arms.len) return m.fail(.unmapped_name, key, 0);
    try m.used_unions.append(m.arena, row);
    try m.union_arms.append(m.arena, arms);
    for (arms) |arm| try collectUnions(m, arm);
    return m.used_unions.items.len - 1;
}

fn kindOf(m: *Model, idl: []const u8) Error!Kind {
    if (std.mem.eql(u8, idl, "boolean")) return .bool_;
    if (std.mem.eql(u8, idl, "DOMString") or std.mem.eql(u8, idl, "USVString")) return .string;
    if (std.mem.eql(u8, idl, "double")) return .{ .scalar = .f64 };
    if (std.mem.eql(u8, idl, "float")) return .{ .scalar = .f32 };
    for (scalar_typedefs) |s| if (std.mem.eql(u8, s.idl, idl)) return .{ .scalar = s.scalar };
    for (flag_domains) |f| if (std.mem.eql(u8, f.typedef, idl)) return .{ .flags = f };
    if (findEnum(m, idl)) |e| return .{ .enumeration = e };
    if (findDictionary(m, idl)) |d| return .{ .dictionary = d };
    if (isHandle(idl)) return .{ .handle = idl };
    for (unions) |u| if (std.mem.eql(u8, u.key, idl)) {
        const text = typedefText(m, idl) orelse return m.fail(.missing_input, idl, 0);
        var t: Tokens = .{ .items = try tokenize(m.arena, text) };
        const ty = try parseType(m, &t, 0);
        if (ty != .union_) return m.fail(.unsupported_type, idl, 0);
        return .{ .union_ = try unionIndex(m, idl, ty.union_.arms) };
    };
    // Any other interface of the catalogue is a native host type.
    if (primary(m.c, idl)) |decl| if (m.c.declarations[decl].kind == .interface) {
        for (m.hosts.items) |h| if (std.mem.eql(u8, h, idl)) return .{ .host = idl };
        if (m.c.declarations[decl].file != m.file) try m.hosts.append(m.arena, idl);
        return .{ .host = idl };
    };
    return m.fail(.unsupported_type, idl, 0);
}

fn collectUnions(m: *Model, ty: Ty) Error!void {
    switch (ty) {
        .named => |n| _ = try kindOf(m, n),
        .clamp_u16, .undefined_ => {},
        .sequence, .nullable, .record => |inner| try collectUnions(m, inner.*),
        .union_ => |u| {
            // `(GPUSize64 or undefined)` is the value of requiredLimits only.
            if (u.arms.len == 2 and u.arms[1] == .undefined_) return;
            _ = try unionIndex(m, u.key, u.arms);
        },
    }
}

/// `requiredLimits`'s `record<DOMString, (GPUSize64 or undefined)>`.
fn isLimitsRecord(ty: Ty) bool {
    if (ty != .record) return false;
    const v = ty.record.*;
    return v == .union_ and v.union_.arms.len == 2 and v.union_.arms[1] == .undefined_;
}

fn checkCollisions(m: *Model) Error!void {
    var ctors: std.StringHashMapUnmanaged(void) = .empty;
    var types: std.StringHashMapUnmanaged(void) = .empty;
    const reserved = [_][]const u8{ "Option", "Default", "Value" };
    for (reserved) |r| {
        if (std.ascii.isUpper(r[0])) try ctors.put(m.arena, r, {});
    }
    try types.put(m.arena, "Option", {});
    for (m.enums.items) |e| {
        if ((try types.getOrPut(m.arena, e.name)).found_existing) return m.fail(.name_collision, e.name, 0);
        for (e.ctors) |ctor| if ((try ctors.getOrPut(m.arena, ctor)).found_existing) return m.fail(.name_collision, ctor, 0);
    }
    for (m.dictionaries.items) |d| if ((try types.getOrPut(m.arena, d.name)).found_existing) return m.fail(.name_collision, d.name, 0);
    for (m.used_unions.items) |u| {
        if ((try types.getOrPut(m.arena, u.name)).found_existing) return m.fail(.name_collision, u.name, 0);
        for (u.arms) |arm| if ((try ctors.getOrPut(m.arena, arm)).found_existing) return m.fail(.name_collision, arm, 0);
    }
    for (snapshots) |s| if ((try types.getOrPut(m.arena, s.beni)).found_existing) return m.fail(.name_collision, s.beni, 0);
    for (sequence_shapes) |s| if ((try types.getOrPut(m.arena, s.list)).found_existing) return m.fail(.name_collision, s.list, 0);
    var flag_ctors: std.StringHashMapUnmanaged(void) = .empty;
    for (m.flags.items) |f| for (f.ctors) |ctor| {
        if ((try flag_ctors.getOrPut(m.arena, ctor)).found_existing) return m.fail(.name_collision, ctor, 0);
    };
}

// ---------------------------------------------------------------------
// Emission.

const header = "-- Generated by `zig build gpu-bindings` from webgpu.idl in @webref/idl 3.86.0\n-- (docs/design/webgpu.md §2.2, name maps v1 in src/native/Gpu.zig). Do not edit.\n";

fn lowerFirst(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const out = try arena.dupe(u8, name);
    // `AdapterInfo` is `adapterInfo`; a leading run of capitals is lowered
    // as one word only where it is the whole name.
    out[0] = std.ascii.toLower(out[0]);
    return out;
}

fn emitAll(m: *Model, out: *std.ArrayList(Output)) (Error || Writer.Error)!void {
    // The native types: every GPU interface. The host types GPU dictionaries
    // name from other IDL files (`m.hosts`) are the native catalogue's
    // modules (`tests/native_bindings.zig`), which `Gpu.Types` imports.
    var natives: std.ArrayList([]const u8) = .empty;
    for (m.c.declarations) |d| {
        if (d.file == m.file and d.kind == .interface and !d.partial) try natives.append(m.arena, d.name);
    }
    std.mem.sort([]const u8, natives.items, {}, lessString);
    for (natives.items) |name| {
        try out.append(m.arena, .{
            .path = try std.fmt.allocPrint(m.arena, "{s}/{s}.beni", .{ core_dir, name }),
            .bytes = try hostModule(m.arena, name),
        });
    }
    try out.append(m.arena, .{ .path = platform_dir ++ "/Flags.beni", .bytes = try flagsModule(m) });
    try out.append(m.arena, .{ .path = platform_dir ++ "/Limits.beni", .bytes = try limitsModule(m) });
    try out.append(m.arena, .{ .path = platform_dir ++ "/Types.beni", .bytes = try typesModule(m) });
    try out.append(m.arena, .{ .path = platform_dir ++ "/Native.beni", .bytes = try nativeModule(m) });
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn hostModule(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{s}
        \\--| The native `{s}` object, opaque: a value is the host's object
        \\--| itself (`docs/design/workers-native-bindings.md`).
        \\pub foreign type {s}
        \\
    , .{ header, name, name });
}

fn flagsModule(m: *Model) (Error || Writer.Error)![]const u8 {
    var buffer: Writer.Allocating = .init(m.arena);
    const w = &buffer.writer;
    try w.writeAll(header);
    try w.writeAll(
        \\--! The five flag domains of WebGPU (`docs/design/webgpu.md` §3 item 4):
        \\--! each a closed type of its constants and an opaque set of them, so a
        \\--! buffer usage is never a texture usage. Every constant has the exact
        \\--! value of its IDL namespace, and every combination is expressible:
        \\--! the device validates the ones an operation refuses.
        \\
        \\
        \\import Js
        \\
        \\
    );
    for (m.flags.items, 0..) |f, fi| {
        const d = f.domain;
        const lower = try lowerFirst(m.arena, d.member);
        const lower_set = try lowerFirst(m.arena, d.set);
        if (fi > 0) try w.writeAll("\n\n");
        try w.print("--| One constant of `{s}`.\npub type {s}\n", .{ d.namespace, d.member });
        for (f.ctors, 0..) |ctor, i| try w.print("    {s} {s}\n", .{ if (i == 0) "=" else "|", ctor });
        try w.print("\n\n--| A set of `{s}` constants, as `{s}` holds it.\npub opaque type {s}\n    = {s} Int\n", .{ d.namespace, d.typedef, d.set, d.set });
        try w.print("\n\n--| The value of the constant: `{s}.{s}` is {d}.\npub {s}Bits : {s} → Int\n{s}Bits flag =\n    case flag of\n", .{ d.namespace, f.constants[0].name, f.constants[0].value, lower, d.member, lower });
        for (f.ctors, f.constants, 0..) |ctor, constant, i| {
            if (i > 0) try w.writeAll("\n");
            try w.print("        {s} →\n            {d}\n", .{ ctor, constant.value });
        }
        try w.print("\n\n--| The set of the constants listed: their bitwise or.\npub {s} : List {s} → {s}\n{s} flags =\n    {s} (List.foldl flags 0 λflag bits → Js.bitOr bits ({s}Bits flag))\n", .{ d.make, d.member, d.set, d.make, d.set, lower });
        try w.print("\n\n--| The set's value, as the native API takes it.\npub {s}Bits : {s} → Int\n{s}Bits set =\n    case set of\n        {s} bits →\n            bits\n", .{ lower_set, d.set, lower_set, d.set });
        try w.print("\n\n--| Whether the set holds every bit of the constant.\npub {s}Has : {s}, {s} → Bool\n{s}Has set flag =\n    Js.bitAnd ({s}Bits set) ({s}Bits flag) == {s}Bits flag\n", .{ lower_set, d.set, d.member, lower_set, lower_set, lower, lower });
        try w.print("\n\n--| Every constant of `{s}`, in the order of its namespace.\npub all{s} : List {s}\nall{s} =\n    [ ", .{ d.namespace, d.set, d.member, d.set });
        for (f.ctors, 0..) |ctor, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", ctor });
        try w.writeAll(" ]\n");
    }
    return buffer.toOwnedSlice();
}

fn limitsModule(m: *Model) (Error || Writer.Error)![]const u8 {
    var buffer: Writer.Allocating = .init(m.arena);
    const w = &buffer.writer;
    try w.writeAll(header);
    try w.writeAll(
        \\--! The supported limits of an adapter or a device (`GPUSupportedLimits`,
        \\--! `docs/design/webgpu.md` §4): a snapshot with every limit of the pin,
        \\--! and the names `requiredLimits` asks for.
        \\
        \\
        \\
        \\--| The name of one limit.
        \\pub type LimitName
        \\
    );
    for (m.limits, 0..) |a, i| try w.print("    {s} {s}\n", .{ if (i == 0) "=" else "|", try pascal(m.arena, a.name) orelse a.name });
    try w.writeAll("\n\n--| Every limit of the pin, read once.\npub type alias Limits =\n");
    for (m.limits) |a| try w.print("    {s} : {s}\n", .{ a.name, a.ty });
    try w.writeAll("\n\n--| Whether a better value is higher (a maximum) or lower (an alignment, a\n--| power of two) (the WebGPU *limit class*).\npub type LimitClass\n    = Maximum\n    | Alignment\n");
    try w.writeAll("\n\n--| The limit's name in the native API.\npub limitNameToString : LimitName → String\nlimitNameToString name =\n    case name of\n");
    for (m.limits, 0..) |a, i| {
        if (i > 0) try w.writeAll("\n");
        try w.print("        {s} →\n            \"{s}\"\n", .{ try pascal(m.arena, a.name) orelse a.name, a.name });
    }
    try w.writeAll("\n\n--| The limit a native name spells, if the pin has it.\npub limitNameFromString : String → Maybe LimitName\nlimitNameFromString text =\n    case text of\n");
    for (m.limits) |a| try w.print("        \"{s}\" →\n            Just {s}\n\n", .{ a.name, try pascal(m.arena, a.name) orelse a.name });
    try w.writeAll("        _ →\n            Nothing\n");
    try w.writeAll("\n\n--| The class of a limit: the two `min…Alignment` limits are alignments.\npub limitClass : LimitName → LimitClass\nlimitClass name =\n    case name of\n");
    var first = true;
    for (m.limits) |a| {
        const alignment = for (alignment_limits) |name| {
            if (std.mem.eql(u8, name, a.name)) break true;
        } else false;
        if (!alignment and std.mem.startsWith(u8, a.name, "min")) return m.fail(.unmapped_name, a.name, 0);
        if (!alignment) continue;
        if (!first) try w.writeAll("\n");
        first = false;
        try w.print("        {s} →\n            Alignment\n", .{try pascal(m.arena, a.name) orelse a.name});
    }
    try w.writeAll("\n        _ →\n            Maximum\n");
    try w.writeAll("\n\n--| One limit of a snapshot, by name: `Nothing` for one the host does not\n--| report.\npub limit : Limits, LimitName → Maybe Int\nlimit limits name =\n    case name of\n");
    for (m.limits, 0..) |a, i| {
        if (i > 0) try w.writeAll("\n");
        try w.print("        {s} →\n            {s}limits.{s}\n", .{ try pascal(m.arena, a.name) orelse a.name, if (std.mem.startsWith(u8, a.ty, "Maybe")) "" else "Just ", a.name });
    }
    try w.writeAll("\n\n--| Every limit name of the pin, in its order.\npub allLimitNames : List LimitName\nallLimitNames =\n    [ ");
    for (m.limits, 0..) |a, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", try pascal(m.arena, a.name) orelse a.name });
    try w.writeAll(" ]\n");
    return buffer.toOwnedSlice();
}

const scalar_type = std.enums.EnumArray(Scalar, []const u8).init(.{ .u32 = "Scalar.U32", .i32 = "Scalar.I32", .size64 = "Scalar.Size64", .f32 = "Scalar.FiniteF32", .f64 = "Scalar.FiniteF64" });
const scalar_to = std.enums.EnumArray(Scalar, []const u8).init(.{ .u32 = "Scalar.u32ToInt", .i32 = "Scalar.i32ToInt", .size64 = "Scalar.size64ToInt", .f32 = "Scalar.finiteF32ToFloat", .f64 = "Scalar.finiteF64ToFloat" });

/// The beni type of an IDL type, written in `Gpu.Types` (`qualify` empty) or
/// in another module (`qualify` "Types.").
fn beniType(m: *Model, ty: Ty, qualify: []const u8) Error![]const u8 {
    return switch (ty) {
        .named => |n| switch (try kindOf(m, n)) {
            .bool_ => "Bool",
            .string => "String",
            .clamp_u16 => "Int",
            .scalar => |s| scalar_type.get(s),
            .flags => |f| try std.fmt.allocPrint(m.arena, "Flags.{s}", .{f.set}),
            .enumeration => |e| try std.fmt.allocPrint(m.arena, "{s}{s}", .{ qualify, e.name }),
            .dictionary => |d| try std.fmt.allocPrint(m.arena, "{s}{s}", .{ qualify, d.name }),
            .handle => |h| try std.fmt.allocPrint(m.arena, "Handle.{s}", .{handleName(h)}),
            .host => |h| try std.fmt.allocPrint(m.arena, "{s}.{s}", .{ h, h }),
            .union_ => |i| try std.fmt.allocPrint(m.arena, "{s}{s}", .{ qualify, m.used_unions.items[i].name }),
            .limits_record => unreachable,
        },
        .clamp_u16 => "Int",
        .sequence => |inner| try std.fmt.allocPrint(m.arena, "List {s}", .{try atom(m, inner.*, qualify)}),
        .nullable => |inner| try std.fmt.allocPrint(m.arena, "Maybe {s}", .{try atom(m, inner.*, qualify)}),
        .record => |inner| if (isLimitsRecord(ty))
            "List (Limits.LimitName × Scalar.Size64)"
        else
            try std.fmt.allocPrint(m.arena, "Dict String {s}", .{try atom(m, inner.*, qualify)}),
        .union_ => |u| try std.fmt.allocPrint(m.arena, "{s}{s}", .{ qualify, m.used_unions.items[try unionIndex(m, u.key, u.arms)].name }),
        .undefined_ => m.fail(.unsupported_type, "undefined", 0),
    };
}

fn atom(m: *Model, ty: Ty, qualify: []const u8) Error![]const u8 {
    const text = try beniType(m, ty, qualify);
    return if (std.mem.findScalar(u8, text, ' ') != null) try std.fmt.allocPrint(m.arena, "({s})", .{text}) else text;
}

fn fieldType(m: *Model, f: Field, qualify: []const u8) Error![]const u8 {
    const text = try beniType(m, f.ty, qualify);
    if (f.required) return text;
    return try std.fmt.allocPrint(m.arena, "{s}Option {s}", .{ qualify, if (std.mem.findScalar(u8, text, ' ') != null) try std.fmt.allocPrint(m.arena, "({s})", .{text}) else text });
}

fn typesModule(m: *Model) (Error || Writer.Error)![]const u8 {
    var buffer: Writer.Allocating = .init(m.arena);
    const w = &buffer.writer;
    try w.writeAll(header);
    try w.writeAll(
        \\--! Every descriptor, enum and union of WebGPU (`docs/design/webgpu.md`
        \\--! §2.2, §3): a record per IDL dictionary with every inherited member, a
        \\--! closed type per enum with its spelling both ways, and a sum per union.
        \\--! A required member is required; an optional one is an `Option`, whose
        \\--! `Default` leaves the member out so that the native default applies,
        \\--! and a nullable one a `Maybe`. Each descriptor has a constructor that
        \\--! takes its required members and sets every optional one to `Default`.
        \\
        \\
    );
    const hosts = try m.arena.dupe([]const u8, m.hosts.items);
    std.mem.sort([]const u8, hosts, {}, lessString);
    for (hosts) |h| try w.print("import Browser.Host.{s} as {s}\n", .{ h, h });
    try w.writeAll("import Dict exposing (Dict)\nimport Gpu.Flags as Flags\nimport Gpu.Handle as Handle\nimport Gpu.Limits as Limits\nimport Gpu.Scalar as Scalar\n");
    try w.writeAll(
        \\
        \\
        \\--| An optional descriptor member: `Default` leaves it out, and the
        \\--| native algorithm's default applies; `Value x` sets it, even to the
        \\--| value the default would have been.
        \\pub type Option a
        \\    = Default
        \\    | Value a
        \\
    );
    // Enums.
    for (m.enums.items) |e| {
        const lower = try lowerFirst(m.arena, e.name);
        try w.print("\n\n--| `{s}`.\npub type {s}\n", .{ e.idl, e.name });
        for (e.ctors, 0..) |ctor, i| try w.print("    {s} {s}\n", .{ if (i == 0) "=" else "|", ctor });
        try w.print("\n\n--| The native spelling of a `{s}`.\npub {s}ToString : {s} → String\n{s}ToString value =\n    case value of\n", .{ e.name, lower, e.name, lower });
        for (e.ctors, e.values, 0..) |ctor, value, i| {
            if (i > 0) try w.writeAll("\n");
            try w.print("        {s} →\n            \"{s}\"\n", .{ ctor, value });
        }
        try w.print("\n\n--| The `{s}` a native spelling names, if the pin has it.\npub {s}FromString : String → Maybe {s}\n{s}FromString text =\n    case text of\n", .{ e.name, lower, e.name, lower });
        for (e.ctors, e.values) |ctor, value| try w.print("        \"{s}\" →\n            Just {s}\n\n", .{ value, ctor });
        try w.writeAll("        _ →\n            Nothing\n");
    }
    // Unions, each sequence arm whose length the host checks behind an
    // opaque list a constructor checks first.
    for (m.used_unions.items, m.union_arms.items) |u, arms| {
        for (arms) |arm| if (arm == .sequence and sequenceShape(u.key) == null) return m.fail(.unmapped_name, u.key, 0);
        for (arms) |arm| if (arm == .sequence) if (sequenceShape(u.key)) |shape| {
            const element = try atom(m, arm.sequence.*, "");
            const lower = try lowerFirst(m.arena, shape.list);
            const length = if (shape.min == shape.max) try std.fmt.allocPrint(m.arena, "exactly {d}", .{shape.min}) else if (shape.min == 0) try std.fmt.allocPrint(m.arena, "at most {d}", .{shape.max}) else try std.fmt.allocPrint(m.arena, "{d} to {d}", .{ shape.min, shape.max });
            try w.print("\n\n--| The sequence form of a `{s}`: {s} values, the length the host\n--| accepts. Made only by `{s}`.\npub opaque type {s}\n    = {s} (List {s})\n", .{ u.key, length, lower, shape.list, shape.list, element });
            const fits = if (shape.min == shape.max) try std.fmt.allocPrint(m.arena, "List.length values == {d}", .{shape.max}) else if (shape.min == 0) try std.fmt.allocPrint(m.arena, "List.length values ≤ {d}", .{shape.max}) else try std.fmt.allocPrint(m.arena, "List.length values ≥ {d} && List.length values ≤ {d}", .{ shape.min, shape.max });
            try w.print("\n\n--| A `{s}` of these values, or `Nothing` when there are not {s}.\npub {s} : List {s} → Maybe {s}\n{s} values =\n    if {s} then Just ({s} values) else Nothing\n", .{ shape.list, length, lower, element, shape.list, lower, fits, shape.list });
            try w.print("\n\n--| The values of a `{s}`.\npub {s}Values : {s} → List {s}\n{s}Values list =\n    case list of\n        {s} values →\n            values\n", .{ shape.list, lower, shape.list, element, lower, shape.list });
        };
        try w.print("\n\n--| `{s}`: one arm per alternative of the union.\npub type {s}\n", .{ u.key, u.name });
        for (u.arms, arms, 0..) |ctor, arm, i| {
            if (try nullaryArm(m, arm)) {
                try w.print("    {s} {s}\n", .{ if (i == 0) "=" else "|", ctor });
            } else if (arm == .sequence and sequenceShape(u.key) != null) {
                try w.print("    {s} {s} {s}\n", .{ if (i == 0) "=" else "|", ctor, sequenceShape(u.key).?.list });
            } else try w.print("    {s} {s} {s}\n", .{ if (i == 0) "=" else "|", ctor, try atom(m, arm, "") });
        }
    }
    // Dictionaries.
    for (m.dictionaries.items) |d| {
        const fields = try allFields(m, d);
        try w.print("\n\n--| `{s}`.\npub type alias {s} =\n", .{ d.idl, d.name });
        if (fields.len == 0) {
            try w.writeAll("    {}\n");
        } else {
            for (fields) |f| try w.print("    {s} : {s}\n", .{ f.name, try fieldType(m, f, "") });
        }
        // The convenience constructor.
        const lower = try lowerFirst(m.arena, d.name);
        var required: std.ArrayList(Field) = .empty;
        for (fields) |f| if (f.required) try required.append(m.arena, f);
        try w.print("\n\n--| A `{s}` with the required members given and every optional\n--| member `Default`.\npub {s} : ", .{ d.name, lower });
        for (required.items, 0..) |f, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", try fieldType(m, f, "") });
        if (required.items.len > 0) try w.writeAll(" → ");
        try w.print("{s}\n{s}", .{ d.name, lower });
        for (required.items) |f| try w.print(" {s}", .{f.name});
        try w.writeAll(" =\n");
        if (fields.len == 0) {
            try w.writeAll("    {}\n");
        } else {
            for (fields, 0..) |f, i| {
                try w.print("    {s} {s} = {s}\n", .{ if (i == 0) "{" else ",", f.name, if (f.required) f.name else "Default" });
            }
            try w.writeAll("    }\n");
        }
    }
    // Snapshots.
    for (snapshots) |s| {
        const decl = primary(m.c, s.idl) orelse return m.fail(.missing_input, s.idl, 0);
        const attrs = try attributes(m, decl);
        try w.print("\n\n--| A snapshot of `{s}`, read once.\npub type alias {s} =\n", .{ s.idl, s.beni });
        for (attrs) |a| try w.print("    {s} : {s}\n", .{ a.name, a.ty });
    }
    return buffer.toOwnedSlice();
}

fn nullaryArm(m: *Model, arm: Ty) Error!bool {
    if (arm != .named) return false;
    const e = findEnum(m, arm.named) orelse return false;
    return e.values.len == 1;
}

// ---------------------------------------------------------------------
// Gpu.Native: the conversions to native values.

fn convert(m: *Model, ty: Ty, expr: []const u8, depth: u32) Error![]const u8 {
    const v = try std.fmt.allocPrint(m.arena, "x{d}", .{depth + 1});
    return switch (ty) {
        .named => |n| switch (try kindOf(m, n)) {
            .bool_, .string, .clamp_u16, .handle, .host => try std.fmt.allocPrint(m.arena, "Js.from {s}", .{expr}),
            .scalar => |s| try std.fmt.allocPrint(m.arena, "Js.from ({s} {s})", .{ scalar_to.get(s), expr }),
            .flags => |f| try std.fmt.allocPrint(m.arena, "Js.from (Flags.{s}Bits {s})", .{ try lowerFirst(m.arena, f.set), expr }),
            .enumeration => |e| try std.fmt.allocPrint(m.arena, "Js.from (Types.{s}ToString {s})", .{ try lowerFirst(m.arena, e.name), expr }),
            .dictionary => |d| try std.fmt.allocPrint(m.arena, "{s} {s}", .{ try lowerFirst(m.arena, d.name), expr }),
            .union_ => |i| try std.fmt.allocPrint(m.arena, "{s} {s}", .{ try lowerFirst(m.arena, m.used_unions.items[i].name), expr }),
            .limits_record => unreachable,
        },
        .clamp_u16 => try std.fmt.allocPrint(m.arena, "Js.from {s}", .{expr}),
        .sequence => |inner| try std.fmt.allocPrint(m.arena, "array {s} (λ{s} → {s})", .{ expr, v, try convert(m, inner.*, v, depth + 1) }),
        .nullable => |inner| try std.fmt.allocPrint(m.arena, "nullable {s} (λ{s} → {s})", .{ expr, v, try convert(m, inner.*, v, depth + 1) }),
        .record => |inner| if (isLimitsRecord(ty))
            try std.fmt.allocPrint(m.arena, "requiredLimits {s}", .{expr})
        else
            try std.fmt.allocPrint(m.arena, "dict {s} (λ{s} → {s})", .{ expr, v, try convert(m, inner.*, v, depth + 1) }),
        .union_ => |u| try std.fmt.allocPrint(m.arena, "{s} {s}", .{ try lowerFirst(m.arena, m.used_unions.items[try unionIndex(m, u.key, u.arms)].name), expr }),
        .undefined_ => m.fail(.unsupported_type, "undefined", 0),
    };
}

fn nativeModule(m: *Model) (Error || Writer.Error)![]const u8 {
    var buffer: Writer.Allocating = .init(m.arena);
    const w = &buffer.writer;
    try w.writeAll(header);
    try w.writeAll(
        \\--! The conversions between `Gpu.Types` values and native WebGPU values,
        \\--! for the engine alone (`docs/design/webgpu.md` §2.2): a descriptor
        \\--! becomes a fresh native dictionary with every `Default` member left
        \\--! out, a `Maybe` member `null` for `Nothing`, and a snapshot is read
        \\--! once into a record. Its signatures name `Js.Value`, so it is not part
        \\--! of the public API; an application never needs it.
        \\
        \\
        \\import Dict exposing (Dict)
        \\import Gpu.Flags as Flags
        \\import Gpu.Limits as Limits
        \\import Gpu.Scalar as Scalar
        \\import Gpu.Types as Types
        \\import Js
        \\
        \\
        \\--| A fresh native array of the converted elements.
        \\pub array : List a, (a → Js.Value) → Js.Value
        \\array xs f =
        \\    out = Js.array []
        \\    List.foldl xs ⊤ λx _ → Js.to (Js.call out "push" [ f x ])
        \\    out
        \\
        \\
        \\--| `null` for `Nothing`, else the converted value.
        \\pub nullable : Maybe a, (a → Js.Value) → Js.Value
        \\nullable value f =
        \\    case value of
        \\        Nothing →
        \\            Js.null
        \\
        \\        Just x →
        \\            f x
        \\
        \\
        \\--| A fresh native object with one property per entry.
        \\pub dict : Dict String a, (a → Js.Value) → Js.Value
        \\dict entries f =
        \\    out = Js.object []
        \\    Dict.foldl entries ⊤ λkey x _ → Js.set out key (f x)
        \\    out
        \\
        \\
        \\--| The native `requiredLimits` record: one property per limit, by name.
        \\pub requiredLimits : List (Limits.LimitName × Scalar.Size64) → Js.Value
        \\requiredLimits entries =
        \\    out = Js.object []
        \\    List.foldl entries ⊤ λ( name, value ) _ →
        \\        Js.set out (Limits.limitNameToString name) (Js.from (Scalar.size64ToInt value))
        \\    out
        \\
        \\
        \\--| Set the member `name` of `out` unless the option is `Default`.
        \\pub member : Js.Value, String, Types.Option a, (a → Js.Value) → ⊤
        \\member out name option f =
        \\    case option of
        \\        Types.Default →
        \\            ⊤
        \\
        \\        Types.Value x →
        \\            Js.set out name (f x)
        \\
        \\
        \\
        \\-- A member a native snapshot must have, of its IDL type; a defect naming
        \\-- it when it is missing or of another type.
        \\readInt : Js.Value, String → Int
        \\readInt native name =
        \\    value = Js.get native name
        \\    if count value then Js.to value else missing name "non-negative integer"
        \\
        \\
        \\readString : Js.Value, String → String
        \\readString native name =
        \\    value = Js.get native name
        \\    if Js.typeIs value "string" then Js.to value else missing name "string"
        \\
        \\
        \\readBool : Js.Value, String → Bool
        \\readBool native name =
        \\    value = Js.get native name
        \\    if Js.typeIs value "boolean" then Js.to value else missing name "boolean"
        \\
        \\
        \\-- A member a host may lack (`optional_members` in src/native/Gpu.zig):
        \\-- `Nothing` when it is absent, a defect when it is of another type.
        \\readOptionalInt : Js.Value, String → Maybe Int
        \\readOptionalInt native name =
        \\    value = Js.get native name
        \\    if Js.isUndefined value then
        \\        Nothing
        \\    else if count value then
        \\        Just (Js.to value)
        \\    else
        \\        missing name "non-negative integer"
        \\
        \\
        \\-- A count or a limit: an integer, not negative; NaN, an infinity and a
        \\-- fraction are none.
        \\count : Js.Value → Bool
        \\count value =
        \\    Js.typeIs value "number"
        \\        && Js.to (Js.call (Js.global "Number") "isInteger" [ value ])
        \\        && Js.to (Js.ge value (Js.from 0))
        \\
        \\
        \\missing : String, String → a
        \\missing name kind =
        \\    Js.throw (Js.construct (Js.global "TypeError") [ Js.from ("webgpu: the host's snapshot has no " ++ kind ++ " `" ++ name ++ "`") ])
        \\
    );
    for (m.used_unions.items, m.union_arms.items) |u, arms| {
        const lower = try lowerFirst(m.arena, u.name);
        try w.print("\n\n--| The native value of a `{s}`.\npub {s} : Types.{s} → Js.Value\n{s} value =\n    case value of\n", .{ u.name, lower, u.name, lower });
        for (u.arms, arms, 0..) |ctor, arm, i| {
            if (i > 0) try w.writeAll("\n");
            if (try nullaryArm(m, arm)) {
                const e = findEnum(m, arm.named).?;
                try w.print("        Types.{s} →\n            Js.from \"{s}\"\n", .{ ctor, e.values[0] });
            } else if (arm == .sequence and sequenceShape(u.key) != null) {
                const values = try std.fmt.allocPrint(m.arena, "(Types.{s}Values x0)", .{try lowerFirst(m.arena, sequenceShape(u.key).?.list)});
                try w.print("        Types.{s} x0 →\n            {s}\n", .{ ctor, try convert(m, arm, values, 0) });
            } else try w.print("        Types.{s} x0 →\n            {s}\n", .{ ctor, try convert(m, arm, "x0", 0) });
        }
    }
    for (m.dictionaries.items) |d| {
        const fields = try allFields(m, d);
        const lower = try lowerFirst(m.arena, d.name);
        try w.print("\n\n--| The native `{s}`.\npub {s} : Types.{s} → Js.Value\n{s} value =\n    out = Js.object []\n", .{ d.idl, lower, d.name, lower });
        for (fields) |f| {
            const field = try std.fmt.allocPrint(m.arena, "value.{s}", .{f.name});
            if (f.required) {
                try w.print("    Js.set out \"{s}\" ({s})\n", .{ f.idl_name, try convert(m, f.ty, field, 0) });
            } else {
                try w.print("    member out \"{s}\" {s} (λx0 → {s})\n", .{ f.idl_name, field, try convert(m, f.ty, "x0", 0) });
            }
        }
        try w.writeAll("    out\n");
    }
    // Snapshot readers.
    for (snapshots) |s| {
        const decl = primary(m.c, s.idl) orelse return m.fail(.missing_input, s.idl, 0);
        const attrs = try attributes(m, decl);
        const lower = try lowerFirst(m.arena, s.beni);
        try w.print("\n\n--| Read a native `{s}` once.\npub read{s} : Js.Value → Types.{s}\nread{s} native =\n", .{ s.idl, s.beni, s.beni, s.beni });
        _ = lower;
        for (attrs, 0..) |a, i| try w.print("    {s} {s} = {s} native \"{s}\"\n", .{ if (i == 0) "{" else ",", a.name, a.reader, a.name });
        try w.writeAll("    }\n");
    }
    try w.writeAll("\n\n--| Read a native `GPUSupportedLimits` once.\npub readLimits : Js.Value → Limits.Limits\nreadLimits native =\n");
    for (m.limits, 0..) |a, i| try w.print("    {s} {s} = {s} native \"{s}\"\n", .{ if (i == 0) "{" else ",", a.name, a.reader, a.name });
    try w.writeAll("    }\n");
    return buffer.toOwnedSlice();
}
