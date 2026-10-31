//! Checked BIR -> source-finite symbolic templates. Each instruction/function
//! belongs to its lexical source template once; there is no caller context.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Bir = @import("../bir/Bir.zig");
const Modules = @import("../resolve/Graph.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Edges = @import("../check/Edges.zig");
const Reach = @import("../js/Reach.zig");
const Plan = @import("Plan.zig");
const Ir = @import("Compact.zig");
const Solve = @import("CompactSolve.zig");
const Exports = @import("CompactExports.zig");
const Shapes = @import("CompactShapes.zig");
const Inst = Bir.Inst;
const sentinel = std.math.maxInt(u32);

pub const Input = struct { metadata: *const Plan, reach: Reach.Input };
const Module = struct { instructions: u32, locals: u32 };
const Template = struct { module: Modules.Index, declaration: u32, body: Inst.OptionalIndex, parameters: Bir.SubRange };
const Local = struct { owner: Ir.TemplateId = .none, value: Ir.PortId = .none, function: Ir.TemplateId = .none };
const Job = struct { instruction: Inst.Index, owner: Ir.TemplateId };
const Pattern = struct { instruction: Inst.Index, owner: Ir.TemplateId, value: Ir.PortId };
const CaptureKey = struct { owner: Ir.TemplateId, local: u32 };
const CaptureBinding = struct { call: Ir.CallId, input: Ir.InputId, port: Ir.PortId };
const CaptureBindingKey = struct { call: Ir.CallId, input: Ir.InputId };
const MetadataGroupId = enum(u32) { none = std.math.maxInt(u32), _ };
const MetadataGroup = struct { range: Ir.Range = .{}, cursor: u32 = 0 };
const MetadataRow = struct { group: MetadataGroupId, tag: enum(u8) { constructor, launch }, kind: Ir.KindId, index: u32 };
const Caller = struct { call: Ir.CallId, next: u32 };

pub fn build(a: Allocator, in: Input, ir: *Ir) Allocator.Error!void {
    std.debug.assert(ir.templates.len == 0);
    var p: Pass = .{ .a = a, .in = in, .ir = ir, .intern = .{ .ir = ir, .a = a }, .resolver = Reach.Builder.init(in.reach, a) };
    defer p.deinit();
    try p.indexModules();
    try p.indexMetadata();
    try p.declarations();
    try p.assignOwners();
    try p.allocatePorts();
    try p.bindNames();
    try p.translate();
    try p.closeCaptures();
    try p.freezeInputs();
    try p.recordShapes();
    try Exports.build(ir, a);
}

const Pass = struct {
    a: Allocator,
    in: Input,
    ir: *Ir,
    intern: Ir.Builder,
    resolver: Reach.Builder,
    modules: std.MultiArrayList(Module) = .empty,
    kind_lookup: std.ArrayList(Ir.KindId) = .empty,
    metadata_index: std.AutoHashMapUnmanaged(Ref, MetadataGroupId) = .empty,
    metadata_groups: std.MultiArrayList(MetadataGroup) = .empty,
    metadata_rows: std.MultiArrayList(MetadataRow) = .empty,
    templates: std.MultiArrayList(Template) = .empty,
    locals: std.MultiArrayList(Local) = .empty,
    owners: std.ArrayList(Ir.TemplateId) = .empty,
    ports: std.ArrayList(Ir.PortId) = .empty,
    functions: std.ArrayList(Ir.TemplateId) = .empty,
    jobs: std.MultiArrayList(Job) = .empty,
    patterns: std.MultiArrayList(Pattern) = .empty,
    capture_index: std.AutoHashMapUnmanaged(CaptureKey, Ir.InputId) = .empty,
    capture_bindings: std.MultiArrayList(CaptureBinding) = .empty,
    capture_binding_index: std.AutoHashMapUnmanaged(CaptureBindingKey, void) = .empty,
    capture_work: std.ArrayList(Ir.InputId) = .empty,
    ordinary_counts: std.ArrayList(u32) = .empty,
    capture_counts: std.ArrayList(u32) = .empty,
    callers: std.ArrayList(u32) = .empty,
    links: std.MultiArrayList(Caller) = .empty,
    scratch_ports: std.ArrayList(Ir.PortId) = .empty,
    scratch_templates: std.ArrayList(Ir.TemplateId) = .empty,
    targets: std.ArrayList(Reach.Node) = .empty,
    arguments: std.ArrayList(Ir.PortId) = .empty,
    operands: std.ArrayList(Inst.Index) = .empty,
    shape_stack: std.ArrayList(Ir.PortId) = .empty,
    shape_selectors: std.ArrayList(Ir.SelectorId) = .empty,
    shape_seen: std.ArrayList(u32) = .empty,
    selector_seen: std.ArrayList(u32) = .empty,

    fn deinit(p: *Pass) void {
        p.intern.deinit();
        inline for (.{ "modules", "kind_lookup", "metadata_index", "metadata_groups", "metadata_rows", "templates", "locals", "owners", "ports", "functions", "jobs", "patterns", "capture_index", "capture_bindings", "capture_binding_index", "capture_work", "ordinary_counts", "capture_counts", "callers", "links", "scratch_ports", "scratch_templates", "targets", "arguments", "operands", "shape_stack", "shape_selectors", "shape_seen", "selector_seen" }) |name| @field(p, name).deinit(p.a);
    }
    fn bir(p: *const Pass, m: Modules.Index) *const Bir {
        return p.in.reach.birOf(m);
    }
    fn instSlot(p: *const Pass, m: Modules.Index, inst: Inst.Index) u32 {
        return p.modules.get(m.int()).instructions + inst.int();
    }
    fn localSlot(p: *const Pass, owner: Ir.TemplateId, local: u32) u32 {
        const t = p.templates.get(@backingInt(owner));
        return p.modules.get(t.module.int()).locals + p.bir(t.module).decls[t.declaration].locals_start + local;
    }
    fn portOf(p: *const Pass, m: Modules.Index, inst: Inst.Index) Ir.PortId {
        return p.ports.items[p.instSlot(m, inst)];
    }
    fn declaration(p: *const Pass, m: Modules.Index, index: u32) Ir.Declaration {
        return p.ir.declarations.get(p.ir.modules.get(m.int()).declarations.start + index);
    }
    fn declarationSlot(p: *const Pass, m: Modules.Index, index: u32) u32 {
        return p.ir.modules.get(m.int()).declarations.start + index;
    }
    fn site(p: *Pass, m: Modules.Index, declaration_index: u32, inst: Inst.OptionalIndex) !Ir.SiteId {
        return p.intern.site(.{ .module = @fromBackingInt(m.int()), .declaration = @fromBackingInt(declaration_index), .instruction = if (inst.unwrap()) |i| @fromBackingInt(i.int()) else .none });
    }
    fn newTemplate(p: *Pass, m: Modules.Index, index: u32, body: Inst.OptionalIndex, parameters: Bir.SubRange, lexical: Ir.TemplateId, source: Inst.OptionalIndex) !Ir.TemplateId {
        const result = try p.ir.addTemplate(p.a, .{ .site = try p.site(m, index, source), .lexical = lexical });
        std.debug.assert(@backingInt(result) == p.templates.len);
        try p.templates.append(p.a, .{ .module = m, .declaration = index, .body = body, .parameters = parameters });
        try p.ordinary_counts.append(p.a, 0);
        try p.capture_counts.append(p.a, 0);
        return result;
    }
    fn indexModules(p: *Pass) !void {
        for (0..p.in.reach.graph.count()) |mi| {
            const m: Modules.Index = @fromBackingInt(@intCast(mi));
            const b = p.bir(m);
            try p.ir.modules.append(p.a, .{ .declarations = .{ .start = @intCast(p.ir.declarations.len), .len = @intCast(b.decls.len) } });
            try p.ir.declarations.ensureUnusedCapacity(p.a, b.decls.len);
            for (b.decls) |_| p.ir.declarations.appendAssumeCapacity(.{});
            try p.modules.append(p.a, .{ .instructions = @intCast(p.ports.items.len), .locals = @intCast(p.locals.len) });
            try p.ports.appendNTimes(p.a, .none, b.insts.len);
            try p.owners.appendNTimes(p.a, .none, b.insts.len);
            try p.functions.appendNTimes(p.a, .none, b.insts.len);
            try p.locals.ensureUnusedCapacity(p.a, b.locals.len);
            for (b.locals) |_| p.locals.appendAssumeCapacity(.{});
        }
    }
    fn addMetadata(p: *Pass, key: Ref, tag: @FieldType(MetadataRow, "tag"), kind: Ir.KindId, index: u32) !void {
        const found = try p.metadata_index.getOrPut(p.a, key);
        const group = if (found.found_existing) found.value_ptr.* else blk: {
            const id: MetadataGroupId = @fromBackingInt(@intCast(p.metadata_groups.len));
            try p.metadata_groups.append(p.a, .{});
            found.value_ptr.* = id;
            break :blk id;
        };
        try p.metadata_rows.append(p.a, .{ .group = group, .tag = tag, .kind = kind, .index = index });
        p.metadata_groups.items(.range)[@backingInt(group)].len += 1;
        p.ir.counts.metadata_rows += 1;
        p.ir.counts.metadata_index_work += 1;
    }
    fn indexMetadata(p: *Pass) !void {
        try p.kind_lookup.appendNTimes(p.a, .none, p.in.reach.types.entries.len);
        for (0..p.in.metadata.kinds.len) |ki| {
            const kind = p.in.metadata.kinds.get(ki);
            const id: Ir.KindId = @fromBackingInt(@intCast(ki));
            p.kind_lookup.items[kind.program.int()] = id;
            for (kind.constructors.start..kind.constructors.start + kind.constructors.len) |ci| {
                const row = p.in.metadata.constructors.get(ci);
                try p.addMetadata(.{ .module = row.value.module, .index = row.value.decl }, .constructor, id, @intCast(ci));
            }
            for (kind.launches.start..kind.launches.start + kind.launches.len) |li| {
                const row = p.in.metadata.launches.get(li);
                try p.addMetadata(.{ .module = row.value.module, .index = row.value.decl }, .launch, id, @intCast(li));
            }
        }
        var start: u32 = 0;
        for (0..p.metadata_groups.len) |gi| {
            p.ir.counts.metadata_index_work += 1;
            p.metadata_groups.items(.range)[gi].start = start;
            start += p.metadata_groups.get(gi).range.len;
        }
        var ordered: std.MultiArrayList(MetadataRow) = .empty;
        errdefer ordered.deinit(p.a);
        try ordered.ensureTotalCapacity(p.a, p.metadata_rows.len);
        for (0..p.metadata_rows.len) |_| ordered.appendAssumeCapacity(undefined);
        for (0..p.metadata_rows.len) |ri| {
            p.ir.counts.metadata_index_work += 1;
            const row = p.metadata_rows.get(ri);
            const group = p.metadata_groups.get(@backingInt(row.group));
            ordered.set(group.range.start + group.cursor, row);
            p.metadata_groups.items(.cursor)[@backingInt(row.group)] += 1;
        }
        p.metadata_rows.deinit(p.a);
        p.metadata_rows = ordered;
    }
    fn declarations(p: *Pass) !void {
        for (0..p.modules.len) |mi| {
            const m: Modules.Index = @fromBackingInt(@intCast(mi));
            const b = p.bir(m);
            const heads = p.in.reach.dispatchOf(m).decl_heads;
            for (b.decls, 0..) |d, di| {
                if (d.kind != .value and d.kind != .foreign_value) continue;
                const t = try p.newTemplate(m, @intCast(di), d.body, .{ .start = d.params_start, .end = d.params_end }, .none, .none);
                const own_site = p.ir.templates.get(@backingInt(t)).site;
                const value = if (d.params != 0) blk: {
                    const origin = try p.ir.addOrigin(p.a, .{ .tag = .function, .site = own_site, .target = @backingInt(t) });
                    break :blk try p.ir.addPort(p.a, .{ .owner = t, .site = own_site, .tag = .function, .lhs = @backingInt(origin) });
                } else try p.ir.addPort(p.a, .{ .owner = t, .site = own_site, .tag = .alias });
                var row: Ir.Declaration = .{ .template = t, .exported = value };
                if (d.params == 0 and d.kind == .value and di < heads.len and heads[di] != .none and p.kind_lookup.items[heads[di].int()] != .none) {
                    const kind = p.kind_lookup.items[heads[di].int()];
                    row.anchor = try p.ir.addAnchor(p.a, .{ .module = @fromBackingInt(m.int()), .declaration = @fromBackingInt(@intCast(di)), .kind = @fromBackingInt(@backingInt(kind)), .site = own_site });
                    const seal = try p.ir.addSeal(p.a, .{ .anchor = row.anchor, .kind = @fromBackingInt(@backingInt(kind)), .initializer = .none });
                    p.ir.ports.items(.tag)[@backingInt(value)] = .seal;
                    p.ir.ports.items(.lhs)[@backingInt(value)] = @backingInt(seal);
                }
                p.ir.declarations.set(p.declarationSlot(m, @intCast(di)), row);
            }
        }
    }
    fn push(p: *Pass, inst: Inst.Index, owner: Ir.TemplateId) !void {
        try p.jobs.append(p.a, .{ .instruction = inst, .owner = owner });
    }
    fn assignOwners(p: *Pass) !void {
        const roots = p.templates.len;
        for (0..roots) |ti| {
            const source = p.templates.get(ti);
            if (source.body.unwrap()) |body| try p.push(body, @fromBackingInt(@intCast(ti)));
            for (p.bir(source.module).extraSlice(source.parameters, Inst.Index)) |parameter| try p.push(parameter, @fromBackingInt(@intCast(ti)));
        }
        while (p.jobs.len != 0) {
            const job = p.jobs.get(p.jobs.len - 1);
            p.jobs.len -= 1;
            const source = p.templates.get(@backingInt(job.owner));
            const b = p.bir(source.module);
            const slot = p.instSlot(source.module, job.instruction);
            if (p.owners.items[slot] != .none) continue;
            p.owners.items[slot] = job.owner;
            const data = b.instData(job.instruction);
            switch (b.instTag(job.instruction)) {
                .lambda => {
                    const params = b.subRange(@fromBackingInt(@intCast(data.lhs)));
                    const body: Inst.Index = @fromBackingInt(@intCast(data.rhs));
                    const child = try p.newTemplate(source.module, source.declaration, body.toOptional(), params, job.owner, job.instruction.toOptional());
                    p.functions.items[slot] = child;
                    try p.push(body, child);
                    for (b.extraSlice(params, Inst.Index)) |parameter| try p.push(parameter, child);
                },
                .let_def => {
                    const def = b.extraData(@fromBackingInt(@intCast(data.lhs)), Bir.LetDef);
                    const body: Inst.Index = @fromBackingInt(@intCast(data.rhs));
                    if (def.params_start != def.params_end) {
                        const params: Bir.SubRange = .{ .start = def.params_start, .end = def.params_end };
                        const child = try p.newTemplate(source.module, source.declaration, body.toOptional(), params, job.owner, job.instruction.toOptional());
                        p.functions.items[slot] = child;
                        try p.push(body, child);
                        for (b.extraSlice(params, Inst.Index)) |parameter| try p.push(parameter, child);
                    } else try p.push(body, job.owner);
                },
                else => {
                    p.operands.clearRetainingCapacity();
                    try b.operands(p.a, job.instruction, &p.operands);
                    for (p.operands.items) |operand| try p.push(operand, job.owner);
                },
            }
        }
    }
    fn allocatePorts(p: *Pass) !void {
        for (0..p.modules.len) |mi| {
            const m: Modules.Index = @fromBackingInt(@intCast(mi));
            const b = p.bir(m);
            for (0..b.insts.len) |ii| {
                const inst: Inst.Index = @fromBackingInt(@intCast(ii));
                const slot = p.instSlot(m, inst);
                const owner = p.owners.items[slot];
                if (owner == .none) continue;
                const source = p.templates.get(@backingInt(owner));
                p.ports.items[slot] = try p.ir.addPort(p.a, .{ .owner = owner, .site = try p.site(m, source.declaration, inst.toOptional()), .tag = .residual, .lhs = @backingInt(Solve.Reason.projection) });
            }
        }
        for (0..p.templates.len) |ti| {
            const t: Ir.TemplateId = @fromBackingInt(@intCast(ti));
            const source = p.templates.get(ti);
            if (source.body.unwrap()) |body| p.ir.templates.items(.body)[ti] = p.portOf(source.module, body);
            if (p.ir.templates.get(ti).lexical != .none) continue;
            const d = p.bir(source.module).decls[source.declaration];
            if (d.params != 0) continue;
            const row = p.declaration(source.module, source.declaration);
            if (row.exported == .none) continue;
            const port = p.ir.ports.get(@backingInt(row.exported));
            if (d.body.unwrap()) |body| {
                if (port.tag == .seal) p.ir.seals.items(.initializer)[port.lhs] = p.portOf(source.module, body) else p.ir.ports.items(.lhs)[@backingInt(row.exported)] = @backingInt(p.portOf(source.module, body));
            } else {
                p.ir.ports.items(.tag)[@backingInt(row.exported)] = .residual;
                p.ir.ports.items(.lhs)[@backingInt(row.exported)] = @backingInt(Solve.Reason.native_flow);
            }
            _ = t;
        }
    }

    fn setAlias(p: *Pass, port: Ir.PortId, value: Ir.PortId) void {
        p.ir.ports.items(.tag)[@backingInt(port)] = .alias;
        p.ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(value);
    }
    fn projection(p: *Pass, owner: Ir.TemplateId, site_id: Ir.SiteId, value: Ir.PortId, selector: Ir.SelectorId) !Ir.PortId {
        return p.ir.addPort(p.a, .{ .owner = owner, .site = site_id, .tag = .project, .lhs = @backingInt(value), .rhs = @backingInt(selector) });
    }
    fn setLocal(p: *Pass, owner: Ir.TemplateId, index: u32, value: Ir.PortId, function: Ir.TemplateId) void {
        p.locals.set(p.localSlot(owner, index), .{ .owner = owner, .value = value, .function = function });
    }
    fn bindPattern(p: *Pass, owner: Ir.TemplateId, pattern: Inst.Index, value: Ir.PortId) !void {
        p.patterns.clearRetainingCapacity();
        try p.patterns.append(p.a, .{ .instruction = pattern, .owner = owner, .value = value });
        const source = p.templates.get(@backingInt(owner));
        const b = p.bir(source.module);
        while (p.patterns.len != 0) {
            const row = p.patterns.get(p.patterns.len - 1);
            p.patterns.len -= 1;
            const data = b.instData(row.instruction);
            const own_site = try p.site(source.module, source.declaration, row.instruction.toOptional());
            switch (b.instTag(row.instruction)) {
                .pat_var => p.setLocal(owner, data.lhs, row.value, .none),
                .pat_wild, .pat_unit, .pat_int, .pat_string, .pat_char => {},
                .pat_as => {
                    p.setLocal(owner, data.rhs, row.value, .none);
                    try p.patterns.append(p.a, .{ .instruction = @fromBackingInt(@intCast(data.lhs)), .owner = owner, .value = row.value });
                },
                .pat_record => for (b.extraSlice(Bir.inlineRange(data), u32)) |local| {
                    const name = b.locals[b.decls[source.declaration].locals_start + local].name.unwrap() orelse continue;
                    const selector = try p.intern.selector(.{ .tag = .field, .value = @backingInt(b.symbol(@fromBackingInt(name))) });
                    p.setLocal(owner, local, try p.projection(owner, own_site, row.value, selector), .none);
                },
                .pat_tuple, .pat_list => {
                    var after_spread = false;
                    for (b.extraSlice(Bir.inlineRange(data), Inst.Index), 0..) |item, index| {
                        var selected: Ir.PortId = undefined;
                        if (b.instTag(item) == .pat_spread or after_spread) {
                            after_spread = true;
                            selected = try p.ir.addPort(p.a, .{ .owner = owner, .site = own_site, .tag = .residual, .lhs = @backingInt(Solve.Reason.projection) });
                        } else selected = try p.projection(owner, own_site, row.value, try p.intern.selector(.{ .tag = .tuple, .value = @intCast(index) }));
                        try p.patterns.append(p.a, .{ .instruction = item, .owner = owner, .value = selected });
                    }
                },
                .pat_spread => try p.patterns.append(p.a, .{ .instruction = @fromBackingInt(@intCast(data.lhs)), .owner = owner, .value = row.value }),
                .pat_ctor => {
                    // Constructor payload matching is outside this kernel's
                    // unguarded field/tuple observation grammar.
                    const selected = try p.ir.addPort(p.a, .{ .owner = owner, .site = own_site, .tag = .residual, .lhs = @backingInt(Solve.Reason.projection) });
                    for (b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index)) |item|
                        try p.patterns.append(p.a, .{ .instruction = item, .owner = owner, .value = selected });
                },
                else => {},
            }
        }
    }
    fn bindNames(p: *Pass) !void {
        for (0..p.templates.len) |ti| {
            const owner: Ir.TemplateId = @fromBackingInt(@intCast(ti));
            const source = p.templates.get(ti);
            const b = p.bir(source.module);
            for (b.extraSlice(source.parameters, Inst.Index), 0..) |pattern, position| {
                const port = p.portOf(source.module, pattern);
                const input = try p.ir.addInput(p.a, .{ .owner = owner, .position = @intCast(position), .port = port, .capture = false });
                p.ir.ports.items(.tag)[@backingInt(port)] = .input;
                p.ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(input);
                p.ordinary_counts.items[ti] += 1;
                try p.bindPattern(owner, pattern, port);
            }
        }
        for (0..p.modules.len) |mi| {
            const m: Modules.Index = @fromBackingInt(@intCast(mi));
            const b = p.bir(m);
            for (b.insts.items(.tag), b.insts.items(.data), 0..) |tag, data, ii| {
                const inst: Inst.Index = @fromBackingInt(@intCast(ii));
                const owner = p.owners.items[p.instSlot(m, inst)];
                if (owner == .none) continue;
                switch (tag) {
                    .let_def => {
                        const def = b.extraData(@fromBackingInt(@intCast(data.lhs)), Bir.LetDef);
                        p.setLocal(owner, def.local, p.portOf(m, inst), p.functions.items[p.instSlot(m, inst)]);
                    },
                    .let_pattern => try p.bindPattern(owner, @fromBackingInt(@intCast(data.lhs)), p.portOf(m, @fromBackingInt(@intCast(data.rhs)))),
                    .case => for (b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index)) |branch| {
                        const arm = b.instData(branch);
                        try p.bindPattern(owner, @fromBackingInt(@intCast(arm.lhs)), p.portOf(m, @fromBackingInt(@intCast(data.lhs))));
                    },
                    else => {},
                }
            }
        }
    }
    fn readLocal(p: *Pass, owner: Ir.TemplateId, local_index: u32) !Ir.PortId {
        const binding = p.locals.get(p.localSlot(owner, local_index));
        if (binding.owner == owner) return binding.value;
        if (p.capture_index.get(.{ .owner = owner, .local = local_index })) |input| return p.ir.inputs.get(@backingInt(input)).port;
        p.scratch_templates.clearRetainingCapacity();
        var at = owner;
        while (at != .none and at != binding.owner) {
            if (p.capture_index.contains(.{ .owner = at, .local = local_index })) break;
            try p.scratch_templates.append(p.a, at);
            at = p.ir.templates.get(@backingInt(at)).lexical;
        }
        var value = if (at == binding.owner) binding.value else if (at != .none) p.ir.inputs.get(@backingInt(p.capture_index.get(.{ .owner = at, .local = local_index }).?)).port else Ir.PortId.none;
        if (value == .none) {
            return p.ir.addPort(p.a, .{ .owner = owner, .site = p.ir.templates.get(@backingInt(owner)).site, .tag = .residual, .lhs = @backingInt(Solve.Reason.missing_binding) });
        }
        var i = p.scratch_templates.items.len;
        while (i != 0) {
            i -= 1;
            const child = p.scratch_templates.items[i];
            const site_id = p.ir.templates.get(@backingInt(child)).site;
            const port = try p.ir.addPort(p.a, .{ .owner = child, .site = site_id, .tag = .input });
            const input = try p.ir.addInput(p.a, .{
                .owner = child,
                .position = p.capture_counts.items[@backingInt(child)],
                .port = port,
                .capture = true,
                .defining = value,
                .source_local = @fromBackingInt(local_index),
            });
            p.capture_counts.items[@backingInt(child)] += 1;
            p.ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(input);
            try p.capture_index.put(p.a, .{ .owner = child, .local = local_index }, input);
            try p.capture_work.append(p.a, input);
            value = port;
        }
        return value;
    }
    fn closeCaptures(p: *Pass) !void {
        try p.callers.resize(p.a, p.ir.templates.len);
        @memset(p.callers.items, sentinel);
        for (0..p.ir.calls.len) |ci| {
            const call = p.ir.calls.get(ci);
            if (call.target == .none) continue;
            const index: u32 = @intCast(p.links.len);
            try p.links.append(p.a, .{ .call = @fromBackingInt(@intCast(ci)), .next = p.callers.items[@backingInt(call.target)] });
            p.callers.items[@backingInt(call.target)] = index;
        }
        var cursor: usize = 0;
        while (cursor < p.capture_work.items.len) : (cursor += 1) {
            const input_id = p.capture_work.items[cursor];
            const input = p.ir.inputs.get(@backingInt(input_id));
            var link = p.callers.items[@backingInt(input.owner)];
            while (link != sentinel) : (link = p.links.items(.next)[link]) {
                const call_id = p.links.get(link).call;
                const key: CaptureBindingKey = .{ .call = call_id, .input = input_id };
                const found = try p.capture_binding_index.getOrPut(p.a, key);
                if (found.found_existing) continue;
                const caller = p.ir.calls.get(@backingInt(call_id));
                const value = try p.readLocal(caller.owner, @backingInt(input.source_local));
                try p.capture_bindings.append(p.a, .{ .call = call_id, .input = input_id, .port = value });
            }
        }
        const counts = try p.a.alloc(u32, p.ir.calls.len);
        defer p.a.free(counts);
        const starts = try p.a.alloc(u32, p.ir.calls.len);
        defer p.a.free(starts);
        @memset(counts, 0);
        for (0..p.capture_bindings.len) |bi| counts[@backingInt(p.capture_bindings.get(bi).call)] += 1;
        for (counts, 0..) |count, ci| {
            starts[ci] = @intCast(p.ir.extra.items.len);
            try p.ir.extra.appendNTimes(p.a, sentinel, count);
            p.ir.calls.items(.captures)[ci] = .{ .start = starts[ci], .len = count };
        }
        for (0..p.capture_bindings.len) |bi| {
            const binding = p.capture_bindings.get(bi);
            const input = p.ir.inputs.get(@backingInt(binding.input));
            p.ir.extra.items[starts[@backingInt(binding.call)] + input.position] = @backingInt(binding.port);
        }
    }
    fn freezeInputs(p: *Pass) !void {
        const counts = try p.a.alloc(u32, p.ir.templates.len);
        defer p.a.free(counts);
        const cursors = try p.a.alloc(u32, counts.len);
        defer p.a.free(cursors);
        @memset(counts, 0);
        for (p.ir.inputs.items(.owner)) |owner| counts[@backingInt(owner)] += 1;
        for (counts, 0..) |count, ti| {
            const start: u32 = @intCast(p.ir.extra.items.len);
            try p.ir.extra.appendNTimes(p.a, sentinel, count);
            p.ir.templates.items(.inputs)[ti] = .{ .start = start, .len = count };
            cursors[ti] = start;
        }
        for (p.ir.inputs.items(.owner), 0..) |owner, ii| {
            p.ir.extra.items[cursors[@backingInt(owner)]] = @intCast(ii);
            cursors[@backingInt(owner)] += 1;
        }
    }

    const Ref = struct { module: Modules.Index, index: u32 };
    fn resolved(p: *Pass, m: Modules.Index, edge: Edges.Edge) !?Ref {
        p.targets.clearRetainingCapacity();
        try p.resolver.resolveCheckedEdge(m, edge, &p.targets);
        if (p.targets.items.len != 1 or p.targets.items[0].kind != .decl) return null;
        return .{ .module = p.targets.items[0].module, .index = p.targets.items[0].index };
    }
    fn reference(p: *Pass, owner: Ir.TemplateId, inst: Inst.Index) !?Ref {
        const source = p.templates.get(@backingInt(owner));
        const b = p.bir(source.module);
        const data = b.instData(inst);
        return switch (b.instTag(inst)) {
            .top => p.resolved(source.module, .{ .top = data.lhs }),
            .ext_value => p.resolved(source.module, .{ .ext = .{ .module = @fromBackingInt(@intCast(data.lhs)), .value = data.rhs } }),
            else => null,
        };
    }
    fn directFunction(p: *Pass, owner: Ir.TemplateId, inst: Inst.Index) !Ir.TemplateId {
        const source = p.templates.get(@backingInt(owner));
        const b = p.bir(source.module);
        const data = b.instData(inst);
        return switch (b.instTag(inst)) {
            .top, .ext_value => if (try p.reference(owner, inst)) |target| blk: {
                const d = p.bir(target.module).decls[target.index];
                break :blk if (d.kind == .value and d.params != 0) p.declaration(target.module, target.index).template else Ir.TemplateId.none;
            } else .none,
            .local => p.locals.get(p.localSlot(owner, data.lhs)).function,
            .lambda => p.functions.items[p.instSlot(source.module, inst)],
            else => .none,
        };
    }
    fn emitExecution(p: *Pass, owner: Ir.TemplateId, site_id: Ir.SiteId, tag: @FieldType(Ir.Execution, "tag"), target: u32, argument: Ir.PortId) !void {
        try p.ir.execution.append(p.a, .{ .owner = owner, .site = site_id, .tag = tag, .target = target, .argument = argument });
    }
    fn makeOrigin(p: *Pass, port: Ir.PortId, tag: Ir.Port.Tag, origin_tag: Ir.Origin.Tag, target: u32) !void {
        const old = p.ir.ports.get(@backingInt(port));
        const origin = try p.ir.addOrigin(p.a, .{ .tag = origin_tag, .site = old.site, .target = target });
        p.ir.ports.items(.tag)[@backingInt(port)] = tag;
        p.ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(origin);
    }
    fn setResidual(p: *Pass, port: Ir.PortId, reason: Solve.Reason) void {
        p.ir.ports.items(.tag)[@backingInt(port)] = .residual;
        p.ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(reason);
    }
    fn sourceRecord(p: *Pass, owner: Ir.TemplateId, inst: Inst.Index, port: Ir.PortId) !void {
        const source = p.templates.get(@backingInt(owner));
        const b = p.bir(source.module);
        const data = b.instData(inst);
        const tag = b.instTag(inst);
        const site_id = p.ir.ports.get(@backingInt(port)).site;
        const origin = try p.ir.addOrigin(p.a, .{ .tag = .allocation, .site = site_id });
        const row = try p.ir.addAllocation(p.a, .{
            .tag = switch (tag) {
                .record, .record_update => .record,
                .tuple => .tuple,
                .list => .list,
                else => .tagged,
            },
            .origin = origin,
            .fields = .{ .start = @intCast(p.ir.fields.len) },
            .base = if (tag == .record_update) p.portOf(source.module, @fromBackingInt(@intCast(data.lhs))) else .none,
        });
        p.ir.origins.items(.target)[@backingInt(origin)] = @backingInt(row);
        if (tag == .record or tag == .record_update) {
            const fields = b.extraSlice(if (tag == .record) Bir.inlineRange(data) else b.subRange(@fromBackingInt(@intCast(data.rhs))), Bir.Field);
            for (fields) |field| try p.ir.fields.append(p.a, .{ .allocation = row, .selector = try p.intern.selector(.{ .tag = .field, .value = @backingInt(b.symbol(field.name)) }), .value = p.portOf(source.module, field.value) });
        } else {
            const values = b.extraSlice(if (tag == .call) b.subRange(@fromBackingInt(@intCast(data.rhs))) else Bir.inlineRange(data), Inst.Index);
            for (values, 0..) |value, index| try p.ir.fields.append(p.a, .{ .allocation = row, .selector = try p.intern.selector(.{ .tag = .tuple, .value = @intCast(index) }), .value = p.portOf(source.module, value) });
        }
        const fields = p.ir.allocations.get(@backingInt(row)).fields;
        p.ir.allocations.items(.fields)[@backingInt(row)].len = @intCast(p.ir.fields.len - fields.start);
        p.ir.ports.items(.tag)[@backingInt(port)] = .allocation;
        p.ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(row);
    }
    fn nativeCallableResult(p: *Pass, target: Ref) bool {
        const b = p.bir(target.module);
        const annotation = b.decls[target.index].annotation.unwrap() orelse return false;
        if (b.instTag(annotation) != .type_fn) return false;
        const result: Inst.Index = @fromBackingInt(@intCast(b.instData(annotation).rhs));
        // This exact declared callable result is an opaque native production.
        // Generic/native value transfer, including polymorphic core primitives,
        // remains a residual instead of guessing a dynamic Program origin.
        return b.instTag(result) == .type_fn;
    }
    fn knownCall(p: *Pass, owner: Ir.TemplateId, site_id: Ir.SiteId, callee: Ir.PortId, target: Ir.TemplateId, args: []const Ir.PortId, reason: Ir.Reason) !Ir.CallId {
        const call = try p.ir.addCall(p.a, .{ .owner = owner, .site = site_id, .target = target, .callee = callee, .residual_reason = reason, .arguments = try p.ir.appendIds(p.a, args) });
        try p.emitExecution(owner, site_id, if (target == .none) .residual else .known_call, if (target == .none) @backingInt(reason) else @backingInt(call), .none);
        return call;
    }
    fn makeCall(p: *Pass, owner: Ir.TemplateId, inst: Inst.Index, port: Ir.PortId, callee: Ir.PortId, target: Ir.TemplateId, resolved_ref: ?Ref, args: []const Ir.PortId, residual_reason: Ir.Reason) !void {
        const site_id = p.ir.ports.get(@backingInt(port)).site;
        if (resolved_ref) |ref| {
            p.ir.counts.metadata_lookup_work += 1;
            var constructor: ?Plan.Constructor = null;
            var constructor_kind: Ir.KindId = .none;
            var ambiguous = false;
            if (p.metadata_index.get(ref)) |group_id| {
                const range = p.metadata_groups.get(@backingInt(group_id)).range;
                for (range.start..range.start + range.len) |ri| {
                    p.ir.counts.metadata_match_work += 1;
                    const row = p.metadata_rows.get(ri);
                    switch (row.tag) {
                        .constructor => {
                            const candidate = p.in.metadata.constructors.get(row.index);
                            if (constructor) |old| {
                                if (constructor_kind != row.kind or old.parameter != candidate.parameter or old.protocol != candidate.protocol) ambiguous = true;
                            } else {
                                constructor = candidate;
                                constructor_kind = row.kind;
                            }
                        },
                        .launch => {
                            const launch = p.in.metadata.launches.get(row.index);
                            if (launch.parameter < args.len) {
                                try p.emitExecution(owner, p.ir.ports.get(@backingInt(args[launch.parameter])).site, .launch, @backingInt(row.kind), args[launch.parameter]);
                            } else try p.emitExecution(owner, site_id, .residual, @backingInt(Ir.Reason.shape), .none);
                        },
                    }
                }
            }
            if (constructor) |ctor| {
                if (ambiguous or ctor.parameter >= args.len) {
                    p.setResidual(port, if (ambiguous) .metadata else .shape);
                    _ = try p.knownCall(owner, site_id, callee, target, args, .missing_body);
                    return;
                }
                const role_names: []const []const u8 = if (ctor.protocol == .handlers) &.{ "init", "start", "handle", "stream" } else &.{ "init", "update", "subscriptions", "request", "stream" };
                const roles: Ir.Range = .{ .start = @intCast(p.ir.roles.len), .len = @intCast(role_names.len) };
                for (role_names, 0..) |name, position| {
                    const symbol = p.in.reach.interner.?.find(name) orelse {
                        p.setResidual(port, .shape);
                        return;
                    };
                    try p.ir.roles.append(p.a, .{ .selector = try p.intern.selector(.{ .tag = .field, .value = @backingInt(symbol) }), .position = @intCast(position) });
                }
                const origin = try p.ir.addOrigin(p.a, .{ .tag = .constructor, .site = site_id });
                p.scratch_ports.clearRetainingCapacity();
                for (args, 0..) |argument, ai| if (ai != ctor.parameter) {
                    try p.scratch_ports.append(p.a, argument);
                };
                const row = try p.ir.addConstructor(p.a, .{ .kind = constructor_kind, .origin = origin, .callbacks = args[ctor.parameter], .roles = roles, .arguments = try p.ir.appendIds(p.a, p.scratch_ports.items) });
                p.ir.origins.items(.target)[@backingInt(origin)] = @backingInt(row);
                p.ir.ports.items(.tag)[@backingInt(port)] = .constructor;
                p.ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(row);
                _ = try p.knownCall(owner, site_id, callee, target, args, .missing_body);
                return;
            }
            if (p.bir(ref.module).decls[ref.index].kind == .foreign_value) {
                if (p.nativeCallableResult(ref)) try p.makeOrigin(port, .@"opaque", .@"opaque", sentinel) else p.setResidual(port, .native_flow);
                try p.emitExecution(owner, site_id, .residual, @backingInt(Solve.Reason.native_flow), .none);
                return;
            }
        }
        const call = try p.knownCall(owner, site_id, callee, target, args, residual_reason);
        p.ir.ports.items(.tag)[@backingInt(port)] = .call;
        p.ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(call);
        _ = inst;
    }

    fn translate(p: *Pass) !void {
        for (0..p.modules.len) |mi| {
            const m: Modules.Index = @fromBackingInt(@intCast(mi));
            const b = p.bir(m);
            for (b.insts.items(.tag), b.insts.items(.data), 0..) |tag, data, ii| {
                const inst: Inst.Index = @fromBackingInt(@intCast(ii));
                const slot = p.instSlot(m, inst);
                const owner = p.owners.items[slot];
                if (owner == .none) continue;
                const port = p.ports.items[slot];
                const site_id = p.ir.ports.get(@backingInt(port)).site;
                switch (tag) {
                    .pat_var, .pat_wild, .pat_unit, .pat_tuple, .pat_record, .pat_list, .pat_ctor, .pat_spread, .pat_as, .pat_int, .pat_char, .pat_string => {},
                    .unit, .int, .float, .string, .char, .chunk => try p.makeOrigin(port, .literal, .literal, sentinel),
                    .local => p.setAlias(port, try p.readLocal(owner, data.lhs)),
                    .top, .ext_value => {
                        if (try p.reference(owner, inst)) |ref| {
                            const target = p.declaration(ref.module, ref.index);
                            if (target.exported == .none) {
                                p.setResidual(port, .missing_body);
                                continue;
                            }
                            p.setAlias(port, target.exported);
                            const d = p.bir(ref.module).decls[ref.index];
                            if (d.params == 0) {
                                if (target.anchor != .none) try p.emitExecution(owner, site_id, .descriptor, @backingInt(target.anchor), target.exported);
                                try p.emitExecution(owner, site_id, .evaluate, @backingInt(target.template), target.exported);
                            }
                        } else p.setResidual(port, .projection);
                    },
                    .lambda => try p.makeOrigin(port, .closure, .closure, @backingInt(p.functions.items[slot])),
                    .let_def => {
                        const child = p.functions.items[slot];
                        if (child != .none) try p.makeOrigin(port, .closure, .closure, @backingInt(child)) else p.setAlias(port, p.portOf(m, @fromBackingInt(@intCast(data.rhs))));
                    },
                    .let => p.setAlias(port, p.portOf(m, @fromBackingInt(@intCast(data.rhs)))),
                    .let_pattern, .let_stmt => try p.makeOrigin(port, .literal, .literal, sentinel),
                    .branch => p.setAlias(port, p.portOf(m, @fromBackingInt(@intCast(data.rhs)))),
                    .case => {
                        p.scratch_ports.clearRetainingCapacity();
                        for (b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index)) |branch|
                            try p.scratch_ports.append(p.a, p.portOf(m, @fromBackingInt(@intCast(b.instData(branch).rhs))));
                        p.ir.ports.items(.tag)[@backingInt(port)] = .alternatives;
                        p.ir.ports.items(.rhs)[@backingInt(port)] = @backingInt(p.portOf(m, @fromBackingInt(@intCast(data.lhs))));
                        p.ir.ports.items(.values)[@backingInt(port)] = try p.ir.appendIds(p.a, p.scratch_ports.items);
                    },
                    .record, .record_update, .tuple, .list => try p.sourceRecord(owner, inst, port),
                    .field_access, .tuple_index => {
                        p.ir.ports.items(.tag)[@backingInt(port)] = .project;
                        p.ir.ports.items(.lhs)[@backingInt(port)] = @backingInt(p.portOf(m, @fromBackingInt(@intCast(data.lhs))));
                        p.ir.ports.items(.rhs)[@backingInt(port)] = @backingInt(try p.intern.selector(if (tag == .field_access) .{ .tag = .field, .value = @backingInt(b.symbol(@fromBackingInt(@intCast(data.rhs)))) } else .{ .tag = .tuple, .value = data.rhs }));
                    },
                    .call => {
                        const callee_inst: Inst.Index = @fromBackingInt(@intCast(data.lhs));
                        const callee_tag = b.instTag(callee_inst);
                        if (callee_tag == .ctor or callee_tag == .ext_ctor) {
                            try p.sourceRecord(owner, inst, port);
                            continue;
                        }
                        p.arguments.clearRetainingCapacity();
                        for (b.extraSlice(b.subRange(@fromBackingInt(@intCast(data.rhs))), Inst.Index)) |argument|
                            try p.arguments.append(p.a, p.portOf(m, argument));
                        try p.makeCall(owner, inst, port, p.portOf(m, callee_inst), try p.directFunction(owner, callee_inst), try p.reference(owner, callee_inst), p.arguments.items, .higher_order);
                    },
                    .method_call, .type_dispatch => {
                        const table = p.in.reach.dispatchOf(m);
                        const dispatch_site = table.siteOf(inst);
                        const term = if (dispatch_site) |ss| if (ss.callee.unwrap()) |target| table.term(target) else null else null;
                        var target_ref: ?Ref = null;
                        var target: Ir.TemplateId = .none;
                        var callee: Ir.PortId = .none;
                        if (term) |t| switch (t) {
                            .top => |top| target_ref = try p.resolved(m, .{ .top = top.decl.int() }),
                            .ext => |ext| target_ref = try p.resolved(m, .{ .ext = .{ .module = ext.module, .value = @backingInt(ext.value) } }),
                            .field => if (tag == .method_call) {
                                const method = b.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.MethodCall);
                                callee = try p.projection(owner, site_id, p.portOf(m, @fromBackingInt(@intCast(data.lhs))), try p.intern.selector(.{ .tag = .field, .value = @backingInt(b.symbol(method.name)) }));
                            },
                            else => {},
                        };
                        if (target_ref) |ref| {
                            const d = p.bir(ref.module).decls[ref.index];
                            const row = p.declaration(ref.module, ref.index);
                            callee = row.exported;
                            if (d.kind == .value and d.params != 0) target = row.template;
                        }
                        p.arguments.clearRetainingCapacity();
                        if (tag == .method_call) {
                            const method = b.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.MethodCall);
                            if (term == null or term.? != .field) try p.arguments.append(p.a, p.portOf(m, @fromBackingInt(@intCast(data.lhs))));
                            for (b.extraSlice(.{ .start = method.args_start, .end = method.args_end }, Inst.Index)) |argument| try p.arguments.append(p.a, p.portOf(m, argument));
                        } else {
                            const method = b.extraData(@fromBackingInt(@intCast(data.rhs)), Bir.TypeDispatch);
                            for (b.extraSlice(.{ .start = method.args_start, .end = method.args_end }, Inst.Index)) |argument| try p.arguments.append(p.a, p.portOf(m, argument));
                        }
                        try p.makeCall(owner, inst, port, callee, target, target_ref, p.arguments.items, if (term != null and term.? == .field) .higher_order else .dispatch);
                    },
                    .ctor => {
                        const ctor = b.ctors[data.lhs];
                        if (ctor.args_start == ctor.args_end) try p.makeOrigin(port, .literal, .literal, sentinel) else p.setResidual(port, .projection);
                    },
                    // A foreign/tagged constructor VALUE needs its own exact
                    // callable/type projection model. Syntactic constructor
                    // calls above are already source allocation sites.
                    .ext_ctor => {
                        const module: Modules.Index = @fromBackingInt(@intCast(data.lhs));
                        if (module.int() < p.in.reach.interfaces.len and data.rhs < p.in.reach.interfaces[module.int()].ctors.len and p.in.reach.interfaces[module.int()].ctors[data.rhs].arity == 0) {
                            try p.makeOrigin(port, .literal, .literal, sentinel);
                        } else p.setResidual(port, .projection);
                    },
                    else => p.setResidual(port, .projection),
                }
            }
        }
    }
    fn recordShapes(p: *Pass) !void {
        try Shapes.build(p.ir, p.a);
    }
};

test "compact checked-source adapter empty store publishes no source identity" {
    const a = std.testing.allocator;
    const SourceStore = @import("../SourceStore.zig");
    const Types = @import("../check/Types.zig");
    const store: SourceStore = .{};
    const metadata: Plan = .{};
    var ir: Ir = .{};
    defer ir.deinit(a);
    try build(a, .{ .metadata = &metadata, .reach = .{
        .graph = &Modules.empty,
        .store = &store,
        .birs = &.{},
        .dispatch = &.{},
        .interfaces = &.{},
        .provenance = &.{},
        .types = &Types.empty,
    } }, &ir);
    try std.testing.expectEqual(@as(usize, 0), ir.anchors.len);
    try std.testing.expectEqual(@as(usize, 0), ir.templates.len);
    try std.testing.expectEqual(@as(usize, 0), ir.exports.len);
}
