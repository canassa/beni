//! The resolved schema plan cache sidecar (`schema.md` A.6). The plan is
//! unhashed: public endpoint/member schemes live in the interface, while this
//! file carries private executable shape and source provenance for emission.

const std = @import("std");
const Allocator = std.mem.Allocator;
const InternPool = @import("../InternPool.zig");
const SourceStore = @import("../SourceStore.zig");
const Interface = @import("../resolve/Interface.zig");
const SchemaPlan = @import("../check/SchemaPlan.zig");

pub const magic = "BENISPL\x00";
/// 2: a `type_refs` row carries an alias's body and an `alias` term its
/// arguments only, as in the interface (`checker-v2.md` §14.2).
pub const format_version: u32 = 2;

pub const Column = enum(u32) {
    definitions,
    node_tags,
    node_lhs,
    node_rhs,
    node_tokens,
    fields,
    variants,
    conversions,
    checks,
    annotations,
    extra,
    term_tags,
    term_lhs,
    term_rhs,
    type_extra,
    type_refs,
    literals,
    literal_bytes,
    symbols,
    schema_targets,
    ctor_targets,
    strings,

    pub const count: u32 = @typeInfo(Column).@"enum".field_names.len;

    pub fn width(c: Column) u32 {
        return switch (c) {
            .definitions => 44,
            .node_tags, .term_tags, .literal_bytes, .strings => 1,
            .node_lhs, .node_rhs, .node_tokens, .extra, .term_lhs, .term_rhs, .type_extra, .symbols => 4,
            .fields, .checks, .annotations => 20,
            .variants => 24,
            .conversions => 16,
            .type_refs => 16,
            .schema_targets, .ctor_targets => 12,
            .literals => 8,
        };
    }
};

const header_bytes: u32 = 16;
const table_bytes: u32 = Column.count * 8;
const body_start: u32 = header_bytes + table_bytes;

pub const ReadError = error{ BadPlan, UnknownSymbol } || Allocator.Error;

pub fn write(gpa: Allocator, plan: *const SchemaPlan, interner: *const InternPool.Global) Allocator.Error![]u8 {
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(gpa);
    const symbol_offsets = try gpa.alloc(u32, plan.symbols.len);
    defer gpa.free(symbol_offsets);
    var seen: std.StringHashMapUnmanaged(u32) = .empty;
    defer seen.deinit(gpa);
    for (plan.symbols, symbol_offsets) |symbol, *slot| {
        const spelling = interner.slice(symbol);
        const got = try seen.getOrPut(gpa, spelling);
        if (got.found_existing) {
            slot.* = got.value_ptr.*;
            continue;
        }
        const at: u32 = @intCast(blob.items.len);
        got.value_ptr.* = at;
        slot.* = at;
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(spelling.len), .little);
        try blob.appendSlice(gpa, &len);
        try blob.appendSlice(gpa, spelling);
        try blob.appendNTimes(gpa, 0, pad4(spelling.len));
    }

    var lengths: [Column.count]u32 = @splat(0);
    lengths[@backingInt(Column.definitions)] = @intCast(plan.definitions.len);
    lengths[@backingInt(Column.node_tags)] = @intCast(plan.nodes.len);
    lengths[@backingInt(Column.node_lhs)] = @intCast(plan.nodes.len);
    lengths[@backingInt(Column.node_rhs)] = @intCast(plan.nodes.len);
    lengths[@backingInt(Column.node_tokens)] = @intCast(plan.nodes.len);
    lengths[@backingInt(Column.fields)] = @intCast(plan.fields.len);
    lengths[@backingInt(Column.variants)] = @intCast(plan.variants.len);
    lengths[@backingInt(Column.conversions)] = @intCast(plan.conversions.len);
    lengths[@backingInt(Column.checks)] = @intCast(plan.checks.len);
    lengths[@backingInt(Column.annotations)] = @intCast(plan.annotations.len);
    lengths[@backingInt(Column.extra)] = @intCast(plan.extra.len);
    lengths[@backingInt(Column.term_tags)] = @intCast(plan.terms.len);
    lengths[@backingInt(Column.term_lhs)] = @intCast(plan.terms.len);
    lengths[@backingInt(Column.term_rhs)] = @intCast(plan.terms.len);
    lengths[@backingInt(Column.type_extra)] = @intCast(plan.type_extra.len);
    lengths[@backingInt(Column.type_refs)] = @intCast(plan.type_refs.len);
    lengths[@backingInt(Column.literals)] = @intCast(plan.literals.len);
    lengths[@backingInt(Column.literal_bytes)] = @intCast(plan.literal_bytes.len);
    lengths[@backingInt(Column.symbols)] = @intCast(plan.symbols.len);
    lengths[@backingInt(Column.schema_targets)] = @intCast(plan.schema_targets.len);
    lengths[@backingInt(Column.ctor_targets)] = @intCast(plan.ctor_targets.len);
    lengths[@backingInt(Column.strings)] = @intCast(blob.items.len);

    var offsets: [Column.count]u32 = undefined;
    var at: u32 = body_start;
    for (0..Column.count) |i| {
        const c: Column = @fromBackingInt(@intCast(i));
        offsets[i] = at;
        at += lengths[i] * c.width();
        at += @intCast(pad4(at));
    }
    const out = try gpa.alloc(u8, at);
    errdefer gpa.free(out);
    @memset(out, 0);
    @memcpy(out[0..8], magic);
    std.mem.writeInt(u32, out[8..12], format_version, .little);
    std.mem.writeInt(u32, out[12..16], Column.count, .little);
    for (0..Column.count) |i| {
        const row = out[header_bytes + i * 8 ..][0..8];
        std.mem.writeInt(u32, row[0..4], offsets[i], .little);
        std.mem.writeInt(u32, row[4..8], lengths[i], .little);
    }

    for (plan.definitions, 0..) |d, i| {
        const row = col(out, offsets, .definitions)[i * 44 ..][0..44];
        words(row[0..40], &.{ @backingInt(d.name), @backingInt(d.decl), d.params_start, d.params_end, @backingInt(d.root), @backingInt(d.type_ref), @backingInt(d.encoded_ref), @backingInt(d.program_term), @backingInt(d.encoded_term), d.token });
        row[40] = d.program_properties;
        row[41] = d.encoded_properties;
    }
    if (plan.nodes.len != 0) {
        const tags = plan.nodes.items(.tag);
        const lhs = plan.nodes.items(.lhs);
        const rhs = plan.nodes.items(.rhs);
        const tokens = plan.nodes.items(.token);
        const tag_out = col(out, offsets, .node_tags);
        for (tags, 0..) |tag, i| tag_out[i] = @backingInt(tag);
        writeWords(col(out, offsets, .node_lhs), lhs);
        writeWords(col(out, offsets, .node_rhs), rhs);
        writeWords(col(out, offsets, .node_tokens), tokens);
    }
    for (plan.fields, 0..) |f, i| {
        const row = col(out, offsets, .fields)[i * 20 ..][0..20];
        words(row[0..12], &.{ @backingInt(f.name), @backingInt(f.external), @backingInt(f.child) });
        row[12] = @intFromBool(f.optional);
        std.mem.writeInt(u32, row[16..20], f.token, .little);
    }
    for (plan.variants, 0..) |v, i| {
        const row = col(out, offsets, .variants)[i * 24 ..][0..24];
        words(row, &.{ @backingInt(v.name), @backingInt(v.external), @backingInt(v.payload), @backingInt(v.program_ctor), @backingInt(v.encoded_ctor), v.token });
    }
    for (plan.conversions, 0..) |c, i| {
        const row = col(out, offsets, .conversions)[i * 16 ..][0..16];
        words(row[0..12], &.{ @backingInt(c.expr), @backingInt(c.target_term), c.token });
        row[12] = @intFromBool(c.opaque_target) | (@as(u8, @intFromBool(c.opaque_checks)) << 1);
    }
    for (plan.checks, 0..) |c, i| {
        const row = col(out, offsets, .checks)[i * 20 ..][0..20];
        row[0] = @backingInt(c.endpoint);
        row[1] = @backingInt(c.kind);
        std.mem.writeInt(u32, row[4..8], c.order, .little);
        std.mem.writeInt(u32, row[8..12], @backingInt(c.call), .little);
        std.mem.writeInt(u32, row[12..16], @backingInt(c.metadata), .little);
        std.mem.writeInt(u32, row[16..20], c.token, .little);
    }
    for (plan.annotations, 0..) |a, i| {
        const row = col(out, offsets, .annotations)[i * 20 ..][0..20];
        row[0] = @backingInt(a.side);
        row[1] = @backingInt(a.target_kind);
        words(row[4..20], &.{ a.target, @backingInt(a.key), @backingInt(a.value), a.token });
    }
    writeWords(col(out, offsets, .extra), plan.extra);
    if (plan.terms.len != 0) {
        const tags = plan.terms.items(.tag);
        const tag_out = col(out, offsets, .term_tags);
        for (tags, 0..) |tag, i| tag_out[i] = @backingInt(tag);
        writeWords(col(out, offsets, .term_lhs), plan.terms.items(.lhs));
        writeWords(col(out, offsets, .term_rhs), plan.terms.items(.rhs));
    }
    writeWords(col(out, offsets, .type_extra), plan.type_extra);
    for (plan.type_refs, 0..) |r, i| {
        const row = col(out, offsets, .type_refs)[i * 16 ..][0..16];
        std.mem.writeInt(u32, row[0..4], @backingInt(r.module), .little);
        std.mem.writeInt(u32, row[4..8], @backingInt(r.name), .little);
        std.mem.writeInt(u32, row[8..12], @backingInt(r.body), .little);
        row[12] = @backingInt(r.package);
    }
    for (plan.literals, 0..) |l, i| words(col(out, offsets, .literals)[i * 8 ..][0..8], &.{ l.start, l.len });
    @memcpy(col(out, offsets, .literal_bytes)[0..plan.literal_bytes.len], plan.literal_bytes);
    writeWords(col(out, offsets, .symbols), symbol_offsets);
    for (plan.schema_targets, 0..) |t, i| {
        const row = col(out, offsets, .schema_targets)[i * 12 ..][0..12];
        row[0] = @backingInt(t.package);
        std.mem.writeInt(u32, row[4..8], @backingInt(t.module), .little);
        std.mem.writeInt(u32, row[8..12], @backingInt(t.schema), .little);
    }
    for (plan.ctor_targets, 0..) |t, i| {
        const row = col(out, offsets, .ctor_targets)[i * 12 ..][0..12];
        std.mem.writeInt(u32, row[0..4], @backingInt(t.schema), .little);
        std.mem.writeInt(u32, row[4..8], @backingInt(t.variant), .little);
        row[8] = @backingInt(t.endpoint);
    }
    @memcpy(col(out, offsets, .strings)[0..blob.items.len], blob.items);
    return out;
}

pub fn read(gpa: Allocator, bytes: []const u8, interner: *const InternPool.Global) ReadError!SchemaPlan {
    var in: Interning = .{ .find = interner };
    return decode(gpa, bytes, &in);
}

pub fn readGrowing(gpa: Allocator, bytes: []const u8, interner: *InternPool.Global) ReadError!SchemaPlan {
    var in: Interning = .{ .grow = .{ .pool = interner, .gpa = gpa } };
    return decode(gpa, bytes, &in);
}

const Interning = union(enum) {
    find: *const InternPool.Global,
    grow: struct { pool: *InternPool.Global, gpa: Allocator },

    fn symbol(in: *Interning, text: []const u8) ReadError!InternPool.Symbol {
        return switch (in.*) {
            .find => |pool| pool.find(text) orelse error.UnknownSymbol,
            .grow => |g| g.pool.getOrPut(g.gpa, text),
        };
    }
};

fn decode(gpa: Allocator, bytes: []const u8, interning: *Interning) ReadError!SchemaPlan {
    if (bytes.len < body_start or !std.mem.eql(u8, bytes[0..8], magic)) return error.BadPlan;
    if (std.mem.readInt(u32, bytes[8..12], .little) != format_version) return error.BadPlan;
    if (std.mem.readInt(u32, bytes[12..16], .little) != Column.count) return error.BadPlan;
    var offsets: [Column.count]u32 = undefined;
    var lengths: [Column.count]u32 = undefined;
    for (0..Column.count) |i| {
        const c: Column = @fromBackingInt(@intCast(i));
        const row = bytes[header_bytes + i * 8 ..][0..8];
        const offset = std.mem.readInt(u32, row[0..4], .little);
        const len = std.mem.readInt(u32, row[4..8], .little);
        if (offset < body_start or offset % 4 != 0) return error.BadPlan;
        if (@as(u64, offset) + @as(u64, len) * c.width() > bytes.len) return error.BadPlan;
        offsets[i] = offset;
        lengths[i] = len;
    }
    const nodes_len = lengths[@backingInt(Column.node_tags)];
    if (lengths[@backingInt(Column.node_lhs)] != nodes_len or lengths[@backingInt(Column.node_rhs)] != nodes_len or lengths[@backingInt(Column.node_tokens)] != nodes_len) return error.BadPlan;
    const terms_len = lengths[@backingInt(Column.term_tags)];
    if (lengths[@backingInt(Column.term_lhs)] != terms_len or lengths[@backingInt(Column.term_rhs)] != terms_len) return error.BadPlan;

    var plan: SchemaPlan = .empty;
    errdefer plan.deinit(gpa);
    const blob = section(bytes, offsets, lengths, .strings);
    const symbol_words = section(bytes, offsets, lengths, .symbols);
    const symbols = try gpa.alloc(InternPool.Symbol, lengths[@backingInt(Column.symbols)]);
    plan.symbols = symbols;
    for (symbols, 0..) |*symbol, i| {
        const at = std.mem.readInt(u32, symbol_words[i * 4 ..][0..4], .little);
        if (@as(u64, at) + 4 > blob.len) return error.BadPlan;
        const len = std.mem.readInt(u32, blob[at..][0..4], .little);
        if (@as(u64, at) + 4 + len > blob.len) return error.BadPlan;
        symbol.* = try interning.symbol(blob[at + 4 ..][0..len]);
    }

    const defs = try gpa.alloc(SchemaPlan.Definition, lengths[@backingInt(Column.definitions)]);
    plan.definitions = defs;
    for (defs, 0..) |*d, i| {
        const row = section(bytes, offsets, lengths, .definitions)[i * 44 ..][0..44];
        if (row[40] & ~@as(u8, 7) != 0 or row[41] & ~@as(u8, 7) != 0 or row[42] != 0 or row[43] != 0) return error.BadPlan;
        d.* = .{ .name = @fromBackingInt(@intCast(word(row, 0))), .decl = @fromBackingInt(@intCast(word(row, 1))), .params_start = word(row, 2), .params_end = word(row, 3), .root = @fromBackingInt(@intCast(word(row, 4))), .type_ref = @fromBackingInt(@intCast(word(row, 5))), .encoded_ref = @fromBackingInt(@intCast(word(row, 6))), .program_term = @fromBackingInt(@intCast(word(row, 7))), .encoded_term = @fromBackingInt(@intCast(word(row, 8))), .token = word(row, 9), .program_properties = row[40], .encoded_properties = row[41] };
    }
    var nodes: std.MultiArrayList(SchemaPlan.Node) = .empty;
    errdefer nodes.deinit(gpa);
    try nodes.resize(gpa, nodes_len);
    const node_tags = section(bytes, offsets, lengths, .node_tags);
    const node_lhs = section(bytes, offsets, lengths, .node_lhs);
    const node_rhs = section(bytes, offsets, lengths, .node_rhs);
    const node_tokens = section(bytes, offsets, lengths, .node_tokens);
    for (0..nodes_len) |i| nodes.set(i, .{ .tag = std.enums.fromInt(SchemaPlan.Node.Tag, node_tags[i]) orelse return error.BadPlan, .lhs = word(node_lhs, i), .rhs = word(node_rhs, i), .token = word(node_tokens, i) });
    plan.nodes = nodes.toOwnedSlice();

    plan.fields = try readFields(gpa, section(bytes, offsets, lengths, .fields));
    plan.variants = try readVariants(gpa, section(bytes, offsets, lengths, .variants));
    plan.conversions = try readConversions(gpa, section(bytes, offsets, lengths, .conversions));
    plan.checks = try readChecks(gpa, section(bytes, offsets, lengths, .checks));
    plan.annotations = try readAnnotations(gpa, section(bytes, offsets, lengths, .annotations));
    plan.extra = try readWords(gpa, section(bytes, offsets, lengths, .extra));

    var terms: std.MultiArrayList(Interface.Term) = .empty;
    errdefer terms.deinit(gpa);
    try terms.resize(gpa, terms_len);
    const term_tags = section(bytes, offsets, lengths, .term_tags);
    const term_lhs = section(bytes, offsets, lengths, .term_lhs);
    const term_rhs = section(bytes, offsets, lengths, .term_rhs);
    for (0..terms_len) |i| terms.set(i, .{ .tag = std.enums.fromInt(Interface.Term.Tag, term_tags[i]) orelse return error.BadPlan, .lhs = word(term_lhs, i), .rhs = word(term_rhs, i) });
    plan.terms = terms.toOwnedSlice();
    plan.type_extra = try readWords(gpa, section(bytes, offsets, lengths, .type_extra));
    plan.type_refs = try readTypeRefs(gpa, section(bytes, offsets, lengths, .type_refs));
    plan.literals = try readLiterals(gpa, section(bytes, offsets, lengths, .literals));
    plan.literal_bytes = try gpa.dupe(u8, section(bytes, offsets, lengths, .literal_bytes));
    plan.schema_targets = try readSchemaTargets(gpa, section(bytes, offsets, lengths, .schema_targets));
    plan.ctor_targets = try readCtorTargets(gpa, section(bytes, offsets, lengths, .ctor_targets));
    if (!verify(&plan)) return error.BadPlan;
    if (!try verifyOwnership(gpa, &plan)) return error.BadPlan;
    return plan;
}

pub fn verify(plan: *const SchemaPlan) bool {
    const symbol_len = plan.symbols.len;
    const node_len = plan.nodes.len;
    for (plan.definitions) |d| {
        if (@backingInt(d.name) >= symbol_len or d.params_start > d.params_end or d.params_end > plan.extra.len) return false;
        if (@backingInt(d.root) >= node_len or @backingInt(d.type_ref) >= plan.type_refs.len or @backingInt(d.encoded_ref) >= plan.type_refs.len) return false;
        if (@backingInt(d.program_term) >= plan.terms.len or @backingInt(d.encoded_term) >= plan.terms.len) return false;
        const program = plan.terms.get(d.program_term.int());
        const encoded = plan.terms.get(d.encoded_term.int());
        if ((program.tag != .app and program.tag != .alias) or program.lhs != @backingInt(d.type_ref)) return false;
        if ((encoded.tag != .app and encoded.tag != .alias) or encoded.lhs != @backingInt(d.encoded_ref)) return false;
        for (plan.extra[d.params_start..d.params_end]) |name| if (name >= symbol_len) return false;
    }
    if (node_len != 0) {
        const tags = plan.nodes.items(.tag);
        const lhs = plan.nodes.items(.lhs);
        const rhs = plan.nodes.items(.rhs);
        for (tags, lhs, rhs, 0..) |tag, l, r, node_i| switch (tag) {
            .parameter => if (r != 0) return false,
            .primitive => if (std.enums.fromInt(SchemaPlan.Primitive, l) == null or r != 0) return false,
            .reference => {
                if (l >= plan.schema_targets.len or !indicesInRange(plan.extra, r, node_i)) return false;
            },
            .record => {
                if (l > r or r > plan.fields.len) return false;
                for (plan.fields[l..r]) |field| if (@backingInt(field.child) >= node_i) return false;
            },
            .list, .nullable => if (l >= node_i or r != 0) return false,
            .tagged => {
                if (l >= plan.literals.len or !indicesInRange(plan.extra, r, plan.variants.len)) return false;
                const variants = rangeAt(plan.extra, r) orelse return false;
                for (variants) |variant| {
                    const payload = plan.variants[variant].payload;
                    if (payload != .none and @backingInt(payload) >= node_i) return false;
                }
            },
            .conversion => if (l >= node_i or r >= plan.conversions.len) return false,
            .check => if (l >= node_i or r >= plan.checks.len) return false,
            .annotation => if (l >= node_i or r >= plan.annotations.len) return false,
        };
    }
    for (plan.fields) |f| if (@backingInt(f.name) >= symbol_len or @backingInt(f.external) >= plan.literals.len or @backingInt(f.child) >= node_len) return false;
    for (plan.variants) |v| {
        if (@backingInt(v.name) >= symbol_len or @backingInt(v.external) >= plan.literals.len) return false;
        if (v.payload != .none and @backingInt(v.payload) >= node_len) return false;
        if (@backingInt(v.program_ctor) >= plan.ctor_targets.len or @backingInt(v.encoded_ctor) >= plan.ctor_targets.len) return false;
    }
    for (plan.conversions) |c| if (@backingInt(c.target_term) >= plan.terms.len) return false;
    for (plan.checks) |c| if (c.metadata != .none and @backingInt(c.metadata) >= plan.literals.len) return false;
    for (plan.annotations) |a| {
        if (a.target_kind == .node and a.target >= node_len) return false;
        if (a.target_kind == .field and a.target >= plan.fields.len) return false;
        if (a.key != .none and @backingInt(a.key) >= plan.literals.len) return false;
        if (a.value != .none and @backingInt(a.value) >= plan.literals.len) return false;
    }
    for (plan.literals) |l| if (@as(u64, l.start) + l.len > plan.literal_bytes.len) return false;
    for (plan.type_refs) |r| if (@backingInt(r.module) >= symbol_len or @backingInt(r.name) >= symbol_len or (r.body != .none and r.body.int() >= plan.terms.len)) return false;
    for (plan.schema_targets) |t| if (@backingInt(t.module) >= symbol_len or @backingInt(t.schema) >= symbol_len) return false;
    for (plan.ctor_targets) |t| if (@backingInt(t.schema) >= plan.schema_targets.len or @backingInt(t.variant) >= symbol_len) return false;
    return verifyTerms(plan);
}

/// Associate every node with exactly one definition and check parameter
/// ordinals against that definition's declaration-order parameter range.
/// Direct edges point backward (verified above), so this walk is finite and
/// cannot be trapped by a corrupt child cycle.
fn verifyOwnership(gpa: Allocator, plan: *const SchemaPlan) Allocator.Error!bool {
    const none = std.math.maxInt(u32);
    const owners = try gpa.alloc(u32, plan.nodes.len);
    defer gpa.free(owners);
    @memset(owners, none);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(gpa);
    try work.ensureTotalCapacity(gpa, plan.nodes.len);

    for (plan.definitions, 0..) |definition, definition_i| {
        const owner: u32 = @intCast(definition_i);
        const root = @backingInt(definition.root);
        if (owners[root] != none) return false;
        owners[root] = owner;
        work.clearRetainingCapacity();
        work.appendAssumeCapacity(root);
        while (work.pop()) |node_i| {
            const node = plan.nodes.get(node_i);
            if (node.tag == .parameter and node.lhs >= definition.params_end - definition.params_start) return false;
            if (!claimChildren(plan, node, owner, owners, none, &work)) return false;
        }
    }
    for (owners) |owner| if (owner == none) return false;
    return true;
}

fn claim(owner: u32, child: u32, owners: []u32, none: u32, work: *std.ArrayList(u32)) bool {
    if (owners[child] == owner) return true;
    if (owners[child] != none) return false;
    owners[child] = owner;
    work.appendAssumeCapacity(child);
    return true;
}

fn claimChildren(plan: *const SchemaPlan, node: SchemaPlan.Node, owner: u32, owners: []u32, none: u32, work: *std.ArrayList(u32)) bool {
    switch (node.tag) {
        .parameter, .primitive => {},
        .reference => for (rangeAt(plan.extra, node.rhs).?) |child| {
            if (!claim(owner, child, owners, none, work)) return false;
        },
        .record => for (plan.fields[node.lhs..node.rhs]) |field| {
            if (!claim(owner, @backingInt(field.child), owners, none, work)) return false;
        },
        .tagged => for (rangeAt(plan.extra, node.rhs).?) |variant| {
            if (plan.variants[variant].payload.unwrap()) |payload| {
                if (!claim(owner, @backingInt(payload), owners, none, work)) return false;
            }
        },
        .list, .nullable, .conversion, .check, .annotation => {
            if (!claim(owner, node.lhs, owners, none, work)) return false;
        },
    }
    return true;
}

fn verifyTerms(plan: *const SchemaPlan) bool {
    if (plan.terms.len == 0) return true;
    const tags = plan.terms.items(.tag);
    const lhs = plan.terms.items(.lhs);
    const rhs = plan.terms.items(.rhs);
    for (tags, lhs, rhs) |tag, l, r| switch (tag) {
        .@"var", .unit, .empty_record, .err => {},
        .func => if (!termRange(plan, l, false) or r >= plan.terms.len) return false,
        .app => if (l >= plan.type_refs.len or !termRange(plan, r, false)) return false,
        .tuple => if (!termRange(plan, l, false)) return false,
        .record => if (!termRange(plan, l, true) or r >= plan.terms.len) return false,
        .alias => if (l >= plan.type_refs.len or plan.type_refs[l].body == .none or !termRange(plan, r, false)) return false,
    };
    return true;
}

fn termRange(plan: *const SchemaPlan, at: u32, fields: bool) bool {
    const range = rangeAt(plan.type_extra, at) orelse return false;
    if (fields and range.len % 2 != 0) return false;
    for (range, 0..) |item, i| {
        if (fields and i % 2 == 0) {
            if (item >= plan.symbols.len) return false;
        } else if (item >= plan.terms.len) return false;
    }
    return true;
}

fn indicesInRange(extra: []const u32, at: u32, bound: usize) bool {
    const range = rangeAt(extra, at) orelse return false;
    for (range) |i| if (i >= bound) return false;
    return true;
}

fn rangeAt(extra: []const u32, at: u32) ?[]const u32 {
    if (at >= extra.len) return null;
    const len = extra[at];
    if (@as(u64, at) + 1 + len > extra.len) return null;
    return extra[at + 1 ..][0..len];
}

fn readFields(gpa: Allocator, bytes: []const u8) ![]SchemaPlan.Field {
    const out = try gpa.alloc(SchemaPlan.Field, bytes.len / 20);
    errdefer gpa.free(out);
    for (out, 0..) |*f, i| {
        const row = bytes[i * 20 ..][0..20];
        if (row[12] & ~@as(u8, 1) != 0 or !allZero(row[13..16])) return error.BadPlan;
        f.* = .{ .name = @fromBackingInt(@intCast(word(row, 0))), .external = @fromBackingInt(@intCast(word(row, 1))), .child = @fromBackingInt(@intCast(word(row, 2))), .optional = row[12] == 1, .token = word(row, 4) };
    }
    return out;
}

fn readVariants(gpa: Allocator, bytes: []const u8) ![]SchemaPlan.Variant {
    const out = try gpa.alloc(SchemaPlan.Variant, bytes.len / 24);
    for (out, 0..) |*v, i| {
        const row = bytes[i * 24 ..][0..24];
        v.* = .{ .name = @fromBackingInt(@intCast(word(row, 0))), .external = @fromBackingInt(@intCast(word(row, 1))), .payload = @fromBackingInt(@intCast(word(row, 2))), .program_ctor = @fromBackingInt(@intCast(word(row, 3))), .encoded_ctor = @fromBackingInt(@intCast(word(row, 4))), .token = word(row, 5) };
    }
    return out;
}

fn readConversions(gpa: Allocator, bytes: []const u8) ![]SchemaPlan.Conversion {
    const out = try gpa.alloc(SchemaPlan.Conversion, bytes.len / 16);
    errdefer gpa.free(out);
    for (out, 0..) |*c, i| {
        const row = bytes[i * 16 ..][0..16];
        if (row[12] & ~@as(u8, 3) != 0 or !allZero(row[13..16])) return error.BadPlan;
        c.* = .{ .expr = @fromBackingInt(@intCast(word(row, 0))), .target_term = @fromBackingInt(@intCast(word(row, 1))), .token = word(row, 2), .opaque_target = row[12] & 1 != 0, .opaque_checks = row[12] & 2 != 0 };
    }
    return out;
}

fn readChecks(gpa: Allocator, bytes: []const u8) ![]SchemaPlan.Check {
    const out = try gpa.alloc(SchemaPlan.Check, bytes.len / 20);
    errdefer gpa.free(out);
    for (out, 0..) |*c, i| {
        const row = bytes[i * 20 ..][0..20];
        if (row[2] != 0 or row[3] != 0) return error.BadPlan;
        c.* = .{ .endpoint = std.enums.fromInt(SchemaPlan.Endpoint, row[0]) orelse return error.BadPlan, .kind = std.enums.fromInt(SchemaPlan.Check.Kind, row[1]) orelse return error.BadPlan, .order = word(row, 1), .call = @fromBackingInt(@intCast(word(row, 2))), .metadata = @fromBackingInt(@intCast(word(row, 3))), .token = word(row, 4) };
    }
    return out;
}

fn readAnnotations(gpa: Allocator, bytes: []const u8) ![]SchemaPlan.Annotation {
    const out = try gpa.alloc(SchemaPlan.Annotation, bytes.len / 20);
    errdefer gpa.free(out);
    for (out, 0..) |*a, i| {
        const row = bytes[i * 20 ..][0..20];
        if (!allZero(row[2..4])) return error.BadPlan;
        a.* = .{ .side = std.enums.fromInt(SchemaPlan.Annotation.Side, row[0]) orelse return error.BadPlan, .target_kind = std.enums.fromInt(SchemaPlan.Annotation.TargetKind, row[1]) orelse return error.BadPlan, .target = word(row, 1), .key = @fromBackingInt(@intCast(word(row, 2))), .value = @fromBackingInt(@intCast(word(row, 3))), .token = word(row, 4) };
    }
    return out;
}

fn readTypeRefs(gpa: Allocator, bytes: []const u8) ![]Interface.TypeRef {
    const out = try gpa.alloc(Interface.TypeRef, bytes.len / 16);
    errdefer gpa.free(out);
    for (out, 0..) |*r, i| {
        const row = bytes[i * 16 ..][0..16];
        if (!allZero(row[13..16])) return error.BadPlan;
        r.* = .{
            .module = @fromBackingInt(@intCast(word(row, 0))),
            .name = @fromBackingInt(@intCast(word(row, 1))),
            .body = @fromBackingInt(@intCast(word(row, 2))),
            .package = std.enums.fromInt(SourceStore.Package, row[12]) orelse return error.BadPlan,
        };
    }
    return out;
}

fn readLiterals(gpa: Allocator, bytes: []const u8) ![]SchemaPlan.Literal {
    const out = try gpa.alloc(SchemaPlan.Literal, bytes.len / 8);
    for (out, 0..) |*l, i| l.* = .{ .start = word(bytes[i * 8 ..][0..8], 0), .len = word(bytes[i * 8 ..][0..8], 1) };
    return out;
}

fn readSchemaTargets(gpa: Allocator, bytes: []const u8) ![]SchemaPlan.SchemaTarget {
    const out = try gpa.alloc(SchemaPlan.SchemaTarget, bytes.len / 12);
    errdefer gpa.free(out);
    for (out, 0..) |*t, i| {
        const row = bytes[i * 12 ..][0..12];
        if (!allZero(row[1..4])) return error.BadPlan;
        t.* = .{ .package = std.enums.fromInt(SourceStore.Package, row[0]) orelse return error.BadPlan, .module = @fromBackingInt(@intCast(word(row, 1))), .schema = @fromBackingInt(@intCast(word(row, 2))) };
    }
    return out;
}

fn readCtorTargets(gpa: Allocator, bytes: []const u8) ![]SchemaPlan.CtorTarget {
    const out = try gpa.alloc(SchemaPlan.CtorTarget, bytes.len / 12);
    errdefer gpa.free(out);
    for (out, 0..) |*t, i| {
        const row = bytes[i * 12 ..][0..12];
        if (!allZero(row[9..12])) return error.BadPlan;
        t.* = .{ .schema = @fromBackingInt(@intCast(word(row, 0))), .variant = @fromBackingInt(@intCast(word(row, 1))), .endpoint = std.enums.fromInt(SchemaPlan.Endpoint, row[8]) orelse return error.BadPlan };
    }
    return out;
}

fn readWords(gpa: Allocator, bytes: []const u8) ![]u32 {
    const out = try gpa.alloc(u32, bytes.len / 4);
    for (out, 0..) |*v, i| v.* = word(bytes, i);
    return out;
}

fn col(bytes: []u8, offsets: [Column.count]u32, c: Column) []u8 {
    return bytes[offsets[@backingInt(c)]..];
}

fn section(bytes: []const u8, offsets: [Column.count]u32, lengths: [Column.count]u32, c: Column) []const u8 {
    return bytes[offsets[@backingInt(c)]..][0 .. lengths[@backingInt(c)] * c.width()];
}

fn words(out: []u8, values: []const u32) void {
    writeWords(out, values);
}

fn writeWords(out: []u8, values: []const u32) void {
    for (values, 0..) |v, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], v, .little);
}

fn word(bytes: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |b| if (b != 0) return false;
    return true;
}

fn pad4(n: usize) usize {
    return (4 - n % 4) % 4;
}

const testing = std.testing;

fn samplePlan(gpa: Allocator, pool: *InternPool.Global) !SchemaPlan {
    const module = try pool.getOrPut(gpa, "Models");
    const user = try pool.getOrPut(gpa, "User");
    const user_type = try pool.getOrPut(gpa, "User.Type");
    const user_encoded = try pool.getOrPut(gpa, "User.Encoded");
    const symbols = try gpa.dupe(InternPool.Symbol, &.{ module, user, user_type, user_encoded });
    const refs = try gpa.dupe(Interface.TypeRef, &.{
        .{ .package = .app, .module = @fromBackingInt(@intCast(0)), .name = @fromBackingInt(@intCast(2)) },
        .{ .package = .app, .module = @fromBackingInt(@intCast(0)), .name = @fromBackingInt(@intCast(3)) },
    });
    const definitions = try gpa.dupe(SchemaPlan.Definition, &.{.{
        .name = @fromBackingInt(@intCast(1)),
        .decl = @fromBackingInt(@intCast(0)),
        .params_start = 0,
        .params_end = 0,
        .root = @fromBackingInt(@intCast(0)),
        .type_ref = @fromBackingInt(@intCast(0)),
        .encoded_ref = @fromBackingInt(@intCast(1)),
        .program_term = @fromBackingInt(@intCast(0)),
        .encoded_term = @fromBackingInt(@intCast(1)),
        .token = 1,
        .program_properties = 3,
        .encoded_properties = 7,
    }});
    var nodes: std.MultiArrayList(SchemaPlan.Node) = .empty;
    try nodes.append(gpa, .{ .tag = .primitive, .lhs = @backingInt(SchemaPlan.Primitive.string), .rhs = 0, .token = 2 });
    var terms: std.MultiArrayList(Interface.Term) = .empty;
    try terms.append(gpa, .{ .tag = .app, .lhs = 0, .rhs = 0 });
    try terms.append(gpa, .{ .tag = .app, .lhs = 1, .rhs = 1 });
    const type_extra = try gpa.dupe(u32, &.{ 0, 0 });
    const schema_targets = try gpa.dupe(SchemaPlan.SchemaTarget, &.{.{
        .package = .app,
        .module = @fromBackingInt(@intCast(0)),
        .schema = @fromBackingInt(@intCast(1)),
    }});
    return .{
        .definitions = definitions,
        .nodes = nodes.toOwnedSlice(),
        .fields = &.{},
        .variants = &.{},
        .conversions = &.{},
        .checks = &.{},
        .annotations = &.{},
        .extra = &.{},
        .terms = terms.toOwnedSlice(),
        .type_extra = type_extra,
        .type_refs = refs,
        .literal_bytes = &.{},
        .literals = &.{},
        .symbols = symbols,
        .schema_targets = schema_targets,
        .ctor_targets = &.{},
    };
}

test "a resolved schema plan round-trips canonically" {
    const gpa = testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    var plan = try samplePlan(gpa, &pool);
    defer plan.deinit(gpa);
    const encoded = try write(gpa, &plan, &pool);
    defer gpa.free(encoded);
    var loaded = try read(gpa, encoded, &pool);
    defer loaded.deinit(gpa);
    const again = try write(gpa, &loaded, &pool);
    defer gpa.free(again);
    try testing.expectEqualSlices(u8, encoded, again);
}

test "invalid plan enums roots and ranges are cache misses" {
    const gpa = testing.allocator;
    var pool = try InternPool.Global.init(gpa);
    defer pool.deinit(gpa);
    var plan = try samplePlan(gpa, &pool);
    defer plan.deinit(gpa);
    const encoded = try write(gpa, &plan, &pool);
    defer gpa.free(encoded);

    const node_tag_row = encoded[header_bytes + @backingInt(Column.node_tags) * 8 ..][0..8];
    const node_tag_at = std.mem.readInt(u32, node_tag_row[0..4], .little);
    const defs_row = encoded[header_bytes + @backingInt(Column.definitions) * 8 ..][0..8];
    const defs_at = std.mem.readInt(u32, defs_row[0..4], .little);
    const targets_row = encoded[header_bytes + @backingInt(Column.schema_targets) * 8 ..][0..8];
    const targets_at = std.mem.readInt(u32, targets_row[0..4], .little);
    const refs_row = encoded[header_bytes + @backingInt(Column.type_refs) * 8 ..][0..8];
    const refs_at = std.mem.readInt(u32, refs_row[0..4], .little);

    var copy = try gpa.dupe(u8, encoded);
    defer gpa.free(copy);
    copy[node_tag_at] = 0xff;
    try testing.expectError(error.BadPlan, read(gpa, copy, &pool));

    @memcpy(copy, encoded);
    std.mem.writeInt(u32, copy[defs_at + 16 ..][0..4], 99, .little);
    try testing.expectError(error.BadPlan, read(gpa, copy, &pool));

    @memcpy(copy, encoded);
    copy[defs_at + 40] = 0x80;
    try testing.expectError(error.BadPlan, read(gpa, copy, &pool));

    @memcpy(copy, encoded);
    copy[defs_at + 42] = 1;
    try testing.expectError(error.BadPlan, read(gpa, copy, &pool));

    @memcpy(copy, encoded);
    std.mem.writeInt(u32, copy[8..12], format_version + 1, .little);
    try testing.expectError(error.BadPlan, read(gpa, copy, &pool));

    @memcpy(copy, encoded);
    copy[targets_at + 1] = 1;
    try testing.expectError(error.BadPlan, read(gpa, copy, &pool));

    @memcpy(copy, encoded);
    std.mem.writeInt(u32, copy[refs_at + 8 ..][0..4], 99, .little);
    try testing.expectError(error.BadPlan, read(gpa, copy, &pool));

    @memcpy(copy, encoded);
    copy[refs_at + 12] = 0xff;
    try testing.expectError(error.BadPlan, read(gpa, copy, &pool));

    @memcpy(copy, encoded);
    copy[refs_at + 13] = 1;
    try testing.expectError(error.BadPlan, read(gpa, copy, &pool));
}
