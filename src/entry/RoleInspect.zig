//! Pre-rendered owned producer evidence. No answer-equation/native certificate.
const std = @import("std");
const Graph = @import("CompactGraph.zig");
const Evidence = @import("CompactEvidence.zig");
const Allocator = std.mem.Allocator;
const Session = @import("../Session.zig");
pub const Error = Allocator.Error || Evidence.Error;
pub const header = "entry-role-transfers schema=1 evidence=owned-source answerValidation=structural entryComplete=false invocationComplete=false\n";

pub fn prepare(a: Allocator, g: *const Graph, session: *const Session) Error!std.Io.Writer.Allocating {
    try g.validateTransfers();
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    write(&out.writer, g, session) catch return error.OutOfMemory;
    return out;
}
fn write(w: *std.Io.Writer, g: *const Graph, session: *const Session) std.Io.Writer.Error!void {
    const e = &g.evidence;
    const ir = &e.source;
    try w.writeAll(header);
    try w.print("  role-counts transfers={d} captures={d} ports={d} calls={d} inputs={d} fields={d} allocations={d} queries={d} facts={d} edges={d} derivations={d} transports={d} sourceRows={d} sourceWords={d} solverRows={d}\n", .{ g.role_transfers.len, g.captures.len, ir.ports.len, ir.calls.len, ir.inputs.len, ir.fields.len, ir.allocations.len, e.queries.len, e.facts.len, e.edges.len, e.derivations.len, e.transports.len, e.counts.source_rows, e.counts.source_words, e.counts.solver_rows });
    try w.print("  role-directory-counts modules={d} declarations={d} templates={d} sites={d} origins={d} selectors={d} anchors={d} seals={d} observations={d} answers={d} seeds={d} bindings={d} obligations={d} constructors={d} layouts={d} execution={d} exports={d}\n", .{ ir.modules.len, ir.declarations.len, ir.templates.len, ir.sites.len, ir.origins.len, ir.selectors.len, ir.anchors.len, ir.seals.len, g.observations.len, g.answers.len, e.seeds.len, e.bindings.len, e.obligations.len, ir.constructors.len, ir.roles.len, ir.execution.len, ir.exports.len });
    for (0..ir.modules.len) |module| {
        const row = ir.modules.get(module);
        const mid: @import("../resolve/Graph.zig").Index = @fromBackingInt(@as(u32, @intCast(module)));
        const file = session.graph.moduleFile(mid);
        const bir = session.artifacts.bir(file);
        try w.print("  role-module {d} declarations={d}:{d} name={s}\n", .{ module, row.declarations.start, row.declarations.len, session.store.moduleName(file) });
        for (0..row.declarations.len) |di| {
            const decl = ir.declarations.get(row.declarations.start + di);
            try w.print("  role-declaration {d}:{d} template={d} exported={d} anchor={d} name={s}.{s}\n", .{ module, di, @backingInt(decl.template), @backingInt(decl.exported), @backingInt(decl.anchor), session.store.moduleName(file), session.interner.slice(bir.symbol(bir.decls[di].name)) });
        }
    }
    for (0..ir.templates.len) |i| {
        const r = ir.templates.get(i);
        try w.print("  role-template {d} site={d} body={d} inputs={d}:{d} lexical={d}\n", .{ i, @backingInt(r.site), @backingInt(r.body), r.inputs.start, r.inputs.len, @backingInt(r.lexical) });
    }
    for (0..ir.sites.len) |i| {
        const r = ir.sites.get(i);
        try w.print("  role-site {d} source={d}:{d}:{d}\n", .{ i, @backingInt(r.module), @backingInt(r.declaration), @backingInt(r.instruction) });
    }
    for (0..ir.origins.len) |i| {
        const r = ir.origins.get(i);
        try w.print("  role-origin {d} kind={t} site={d} target={d}\n", .{ i, r.tag, @backingInt(r.site), r.target });
    }
    for (0..ir.selectors.len) |i| {
        const r = ir.selectors.get(i);
        try w.print("  role-selector {d} kind={t} key=", .{ i, r.tag });
        if (r.tag == .field) try w.writeAll(session.interner.slice(@fromBackingInt(r.value))) else try w.print("{d}", .{r.value});
        try w.writeByte('\n');
    }
    for (0..ir.constructors.len) |i| {
        const r = ir.constructors.get(i);
        try w.print("  role-constructor {d} kind={d} origin={d} callbacks={d} roles={d}:{d} arguments={d}:{d}\n", .{ i, @backingInt(r.kind), @backingInt(r.origin), @backingInt(r.callbacks), r.roles.start, r.roles.len, r.arguments.start, r.arguments.len });
    }
    for (0..ir.roles.len) |i| {
        const r = ir.roles.get(i);
        try w.print("  role-layout {d} selector={d} position={d}\n", .{ i, @backingInt(r.selector), r.position });
    }
    for (0..ir.execution.len) |i| {
        const r = ir.execution.get(i);
        try w.print("  role-execution {d} owner={d} site={d} kind={t} target={d} argument={d}\n", .{ i, @backingInt(r.owner), @backingInt(r.site), r.tag, r.target, @backingInt(r.argument) });
    }
    for (0..ir.exports.len) |i| {
        const r = ir.exports.get(i);
        try w.print("  role-export {d} owner={d} launch={d} port={d}\n", .{ i, @backingInt(r.owner), r.launch, @backingInt(r.port) });
    }
    for (0..ir.anchors.len) |i| {
        const r = ir.anchors.get(i);
        try w.print("  role-anchor {d} module={d} declaration={d} kind={d} site={d}\n", .{ i, @backingInt(r.module), @backingInt(r.declaration), @backingInt(r.kind), @backingInt(r.site) });
    }
    for (0..ir.seals.len) |i| {
        const r = ir.seals.get(i);
        try w.print("  role-seal {d} anchor={d} kind={d} initializer={d}\n", .{ i, @backingInt(r.anchor), @backingInt(r.kind), @backingInt(r.initializer) });
    }
    for (0..g.observations.len) |i| {
        const r = g.observations.get(i);
        try w.print("  role-observation {d} mode={t} control={} prefix={t} selector={d} kind={d} role={d} constructor={d} anchor={d} capture={d}\n", .{ i, r.mode, r.control, r.prefix, @backingInt(r.selector), @backingInt(r.kind), r.role, @backingInt(r.constructor), @backingInt(r.anchor), @backingInt(r.capture) });
    }
    for (0..g.answers.len) |i| {
        const r = g.answers.get(i);
        try w.print("  role-answer {d} kind={t} input={d} observation={d} origin={d} anchor={d} site={d} reason={t}\n", .{ i, r.tag, @backingInt(r.input), @backingInt(r.observation), @backingInt(r.origin), @backingInt(r.anchor), @backingInt(r.site), r.reason });
    }
    for (0..e.seeds.len) |i| {
        const r = e.seeds.get(i);
        try w.print("  role-seed {d} template={d} anchor={d} role={d}\n", .{ i, @backingInt(r.template), @backingInt(r.entry), r.role });
    }
    for (0..e.bindings.len) |i| {
        const r = e.bindings.get(i);
        try w.print("  role-binding {d} seed={d} input={d} W={d} S={d} runtime={}\n", .{ i, @backingInt(r.seed), @backingInt(r.input), @backingInt(r.W), @backingInt(r.S), r.runtime });
    }
    for (0..e.obligations.len) |i| {
        const r = e.obligations.get(i);
        try w.print("  role-obligation {d} query={d} needs={d} next={d}\n", .{ i, @backingInt(r.query), @backingInt(r.needs), r.next });
    }
    for (0..g.role_transfers.len) |i| {
        const r = g.role_transfers.get(i);
        try w.print("  role-transfer {d} entry={s} anchor={d} constructor={d} role={d} origin={d} template={d} seed={d} source={d} W={d} S={d} captures={d}:{d} kind={t} sourceStatus={t}\n", .{ i, g.text(g.entries.get(@backingInt(r.entry)).canonical), @backingInt(r.anchor), @backingInt(r.constructor), r.role, @backingInt(r.origin), @backingInt(r.template), @backingInt(r.seed), @backingInt(r.source), @backingInt(r.W), @backingInt(r.S), r.captures.start, r.captures.len, r.kind, r.status });
    }
    for (0..g.captures.len) |i| {
        const r = g.captures.get(i);
        try w.print("  role-capture {d} transfer={d} binding={d} input={d} W={d} S={d} sourceStatus={t}\n", .{ i, @backingInt(r.transfer), @backingInt(r.binding), @backingInt(r.input), @backingInt(r.W), @backingInt(r.S), r.status });
    }
    for (0..ir.ports.len) |i| {
        const r = ir.ports.get(i);
        const s = ir.sites.get(@backingInt(r.site));
        try w.print("  role-port {d} owner={d} tag={t} lhs={d} rhs={d} values={d}:{d} source={d}:{d}:{d}\n", .{ i, @backingInt(r.owner), r.tag, r.lhs, r.rhs, r.values.start, r.values.len, @backingInt(s.module), @backingInt(s.declaration), @backingInt(s.instruction) });
    }
    for (0..ir.calls.len) |i| {
        const r = ir.calls.get(i);
        try w.print("  role-call {d} owner={d} site={d} target={d} callee={d} arguments={d}:{d} captures={d}:{d}\n", .{ i, @backingInt(r.owner), @backingInt(r.site), @backingInt(r.target), @backingInt(r.callee), r.arguments.start, r.arguments.len, r.captures.start, r.captures.len });
    }
    for (0..ir.inputs.len) |i| {
        const r = ir.inputs.get(i);
        try w.print("  role-input {d} owner={d} position={d} port={d} capture={} defining={d} local={d}\n", .{ i, @backingInt(r.owner), r.position, @backingInt(r.port), r.capture, @backingInt(r.defining), @backingInt(r.source_local) });
    }
    for (0..ir.fields.len) |i| {
        const r = ir.fields.get(i);
        try w.print("  role-field {d} allocation={d} selector={d} value={d}\n", .{ i, @backingInt(r.allocation), @backingInt(r.selector), @backingInt(r.value) });
    }
    for (0..ir.allocations.len) |i| {
        const r = ir.allocations.get(i);
        try w.print("  role-allocation {d} kind={t} origin={d} fields={d}:{d} base={d} shape={d}:{d} complete={}\n", .{ i, r.tag, @backingInt(r.origin), r.fields.start, r.fields.len, @backingInt(r.base), r.shape.start, r.shape.len, r.shape_complete });
    }
    for (0..e.queries.len) |i| {
        const r = e.queries.get(i);
        try w.print("  role-query {d} port={d} observation={d} seed={d} sourceStatus={t}\n", .{ i, @backingInt(r.port), @backingInt(r.observation), @backingInt(r.seed), e.statuses.items[i] });
    }
    for (0..e.facts.len) |i| {
        const r = e.facts.get(i);
        try w.print("  role-fact {d} query={d} answer={d}\n", .{ i, @backingInt(r.query), @backingInt(r.answer) });
    }
    for (0..e.edges.len) |i| {
        const r = e.edges.get(i);
        try w.print("  role-edge {d} source={d} target={d} kind={t} call={d} seal={d}\n", .{ i, @backingInt(r.source), @backingInt(r.target), r.tag, @backingInt(r.call), @backingInt(r.seal) });
    }
    for (0..e.derivations.len) |i| {
        const r = e.derivations.get(i);
        try w.print("  role-derivation {d} target={d} source={d} via={d}\n", .{ i, @backingInt(r.target), @backingInt(r.source), @backingInt(r.via) });
    }
    for (0..e.transports.len) |i| {
        const r = e.transports.get(i);
        try w.print("  role-transport {d} kind={t} edge={d} via={d} call={d} input={d} formal={d} actual={d} binding={d}\n", .{ i, r.kind, @backingInt(r.edge), @backingInt(r.via), @backingInt(r.call), @backingInt(r.input), @backingInt(r.formal), @backingInt(r.actual), r.binding });
    }
    try w.print("  role-extra words={d}", .{ir.extra.items.len});
    for (ir.extra.items) |word| try w.print(" {d}", .{word});
    try w.writeByte('\n');
}
