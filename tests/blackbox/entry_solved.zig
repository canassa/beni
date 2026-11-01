//! Strict public schema1 text reader; no compiler internals or proof inference.
const std = @import("std");
const a = std.testing.allocator;
pub const header = "solved-representations schema=1 hostfree=false wire=false phase=P9-before-ownership\n";
pub const end = "end-solved-representations\n";
const Node = struct { seen: bool = false, seed: bool = false, formal: bool = false, reached: bool = false, variable: bool = false, start: usize = 0, len: usize = 0 };
fn member(word: []const u8, set: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, set, ' ');
    while (it.next()) |s| if (std.mem.eql(u8, s, word)) return true;
    return false;
}
const Tokens = std.mem.TokenIterator(u8, .scalar);
fn token(it: *Tokens) ![]const u8 {
    return it.next() orelse error.TruncatedSolvedRow;
}
fn key(it: *Tokens, expected: []const u8) ![]const u8 {
    const t = try token(it);
    const eq = std.mem.indexOfScalar(u8, t, '=') orelse return error.InvalidSolvedKey;
    if (!std.mem.eql(u8, t[0..eq], expected)) return error.UnknownSolvedKey;
    return t[eq + 1 ..];
}
fn n(word: []const u8) !u32 {
    return std.fmt.parseInt(u32, word, 10);
}
fn number(it: *Tokens, expected: []const u8) !u32 {
    return n(try key(it, expected));
}
fn done(it: *Tokens) !void {
    if (it.next() != null) return error.TrailingSolvedField;
}
fn qualified(value: []const u8, nominal: bool) !void {
    const sep = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidSolvedName;
    if (!member(value[0..sep], "app core platform") or sep + 1 == value.len or std.mem.indexOfScalarPos(u8, value, sep + 1, ':') != null) return error.InvalidSolvedName;
    if (nominal) {
        const dot = std.mem.lastIndexOfScalar(u8, value, '.') orelse return error.InvalidSolvedName;
        if (dot <= sep + 1 or dot + 1 == value.len) return error.InvalidSolvedName;
    }
}
const Module = struct {
    active: bool = false,
    D: u32 = 0,
    T: u32 = 0,
    E: u32 = 0,
    F: u32 = 0,
    R: u32 = 0,
    Q: u32 = 0,
    N: u32 = 0,
    RE: u32 = 0,
    roots: usize = 0,
    formals: usize = 0,
    observed: usize = 0,
    fields: usize = 0,
    nodes: []Node = &.{},
    edges: std.ArrayList(u32) = .empty,
    previous_id: ?u32 = null,
    previous_source: ?u32 = null,
    fn deinit(m: *Module) void {
        a.free(m.nodes);
        m.edges.deinit(a);
        m.* = .{};
    }
    fn reference(m: *Module, index: u32, seed: bool, formal: bool) !void {
        if (index >= m.T) return error.InvalidSolvedNodeId;
        m.nodes[index].seed = m.nodes[index].seed or seed;
        m.nodes[index].formal = m.nodes[index].formal or formal;
    }
    fn finish(m: *Module) !void {
        if (!m.active) return;
        if (m.roots != m.R or m.formals != m.Q or m.observed != m.N or m.edges.items.len != m.RE or m.fields > m.F) return error.SolvedCountMismatch;
        if (m.N == m.T and (m.RE != m.E or m.fields != m.F)) return error.SolvedCountMismatch;
        var queue: std.ArrayList(u32) = .empty;
        defer queue.deinit(a);
        for (m.nodes, 0..) |*node, i| {
            if (node.formal and (!node.seen or !node.variable)) return error.InvalidSolvedFormal;
            if (node.seed) {
                if (!node.seen) return error.MissingSolvedNode;
                node.reached = true;
                try queue.append(a, @intCast(i));
            }
        }
        var cursor: usize = 0;
        while (cursor < queue.items.len) : (cursor += 1) {
            const node = m.nodes[queue.items[cursor]];
            for (m.edges.items[node.start..][0..node.len]) |target| {
                if (!m.nodes[target].seen) return error.MissingSolvedNode;
                if (!m.nodes[target].reached) {
                    m.nodes[target].reached = true;
                    try queue.append(a, target);
                }
            }
        }
        if (queue.items.len != m.N) return error.InvalidSolvedReachability;
    }
    fn begin(m: *Module, it: *Tokens) !void {
        try m.finish();
        m.deinit();
        try qualified(try token(it), false);
        m.D = try number(it, "D");
        m.T = try number(it, "T_store");
        m.E = try number(it, "E_store");
        m.F = try number(it, "F_store");
        const parents = try number(it, "parentEdges");
        m.R = try number(it, "roots");
        m.Q = try number(it, "formals");
        m.N = try number(it, "reachedNodes");
        m.RE = try number(it, "reachedEdges");
        try done(it);
        if (m.D < m.T or parents != m.D - m.T or m.F > m.E or m.N > m.T or m.RE > m.E) return error.SolvedCountMismatch;
        m.nodes = try a.alloc(Node, m.T);
        @memset(m.nodes, .{});
        m.active = true;
    }
    fn root(m: *Module, it: *Tokens) !void {
        if (!m.active or m.previous_id != null or m.roots >= m.R or try n(try token(it)) != m.roots) return error.InvalidSolvedRoot;
        const kind = try token(it);
        if (!member(kind, "entry nominal_template alias_template")) return error.InvalidSolvedRootKind;
        _ = try number(it, "declaration");
        if (try number(it, "anchor") == std.math.maxInt(u32)) return error.InvalidSolvedAnchor;
        const origin = try key(it, "origin");
        if (!member(origin, "entry nominal") or (std.mem.eql(u8, kind, "entry") and !std.mem.eql(u8, origin, "entry")) or (std.mem.eql(u8, kind, "nominal_template") and !std.mem.eql(u8, origin, "nominal"))) return error.InvalidSolvedOrigin;
        try m.reference(try number(it, "node"), true, false);
        const owner = try key(it, "owner");
        if (std.mem.eql(u8, kind, "entry")) {
            if (!std.mem.eql(u8, owner, "<entry>")) return error.InvalidSolvedOwner;
        } else try qualified(owner, true);
        const formals = try key(it, "formals");
        try done(it);
        if (formals.len != 0) {
            var fs = std.mem.splitScalar(u8, formals, ',');
            var ordinal: u32 = 0;
            while (fs.next()) |f| {
                var pair = std.mem.splitScalar(u8, f, ':');
                if (try n(pair.next().?) != ordinal) return error.InvalidSolvedFormal;
                const target = try n(pair.next() orelse return error.InvalidSolvedFormal);
                if (pair.next() != null) return error.InvalidSolvedFormal;
                try m.reference(target, true, true);
                ordinal += 1;
                m.formals += 1;
                if (m.formals > m.Q) return error.SolvedCountMismatch;
            }
        }
        m.roots += 1;
    }
    fn readNode(m: *Module, it: *Tokens) !void {
        if (!m.active or m.roots != m.R) return error.InvalidSolvedNode;
        const id = try n(try token(it));
        if (id >= m.T or m.nodes[id].seen) return error.InvalidSolvedNodeId;
        if (m.previous_id) |p| if (id <= p) return error.InvalidSolvedNodeId;
        const source = try number(it, "source");
        if (source >= m.D) return error.InvalidSolvedSourceId;
        if (m.previous_source) |p| if (source <= p) return error.InvalidSolvedSourceId;
        const tag = try token(it);
        if (!member(tag, "err flex rigid unit empty_record function app tuple record alias")) return error.InvalidSolvedTag;
        const variable = member(tag, "flex rigid");
        _ = try number(it, "rank");
        const kind = try key(it, "kind");
        const eq = try key(it, "equatable");
        if (!member(kind, "any number appendable dict_key int_key string_key") or !member(eq, "true false") or (!variable and (!std.mem.eql(u8, kind, "any") or !std.mem.eql(u8, eq, "false")))) return error.InvalidSolvedKind;
        const edges = try key(it, "edges");
        const start = m.edges.items.len;
        var edge_count: u32 = 0;
        if (edges.len != 0) {
            var es = std.mem.splitScalar(u8, edges, ',');
            while (es.next()) |edge| {
                const colon = std.mem.indexOfScalar(u8, edge, ':') orelse return error.InvalidSolvedEdge;
                const arrow = std.mem.indexOfPos(u8, edge, colon + 1, "->") orelse return error.InvalidSolvedEdge;
                const ek = edge[0..colon];
                const selector = edge[colon + 1 .. arrow];
                const target = try n(edge[arrow + 2 ..]);
                if (!member(ek, "argument result tuple_field record_field extension actual") or selector.len == 0) return error.InvalidSolvedEdge;
                const expected: []const u8 = if (std.mem.eql(u8, tag, "function")) (if (es.peek() == null) "result" else "argument") else if (std.mem.eql(u8, tag, "app")) "argument" else if (std.mem.eql(u8, tag, "tuple")) "tuple_field" else if (std.mem.eql(u8, tag, "record")) (if (es.peek() == null) "extension" else "record_field") else if (std.mem.eql(u8, tag, "alias")) (if (edge_count == 0) "actual" else "argument") else return error.InvalidSolvedEdge;
                if (!std.mem.eql(u8, ek, expected)) return error.InvalidSolvedEdge;
                if (std.mem.eql(u8, ek, "record_field")) m.fields += 1 else {
                    const expected_selector: u32 = if (member(ek, "argument tuple_field")) edge_count - @as(u32, if (std.mem.eql(u8, tag, "alias")) 1 else 0) else 0;
                    if (try n(selector) != expected_selector) return error.InvalidSolvedSelector;
                }
                try m.reference(target, false, false);
                try m.edges.append(a, target);
                edge_count += 1;
                if (m.edges.items.len > m.RE) return error.SolvedCountMismatch;
            }
        }
        if (member(tag, "function record alias") and edge_count == 0) return error.InvalidSolvedEdge;
        if (member(tag, "app alias")) try qualified(try key(it, "nominal"), true);
        try done(it);
        m.nodes[id].seen = true;
        m.nodes[id].variable = variable;
        m.nodes[id].start = start;
        m.nodes[id].len = edge_count;
        m.previous_id = id;
        m.previous_source = source;
        m.observed += 1;
        if (m.observed > m.N) return error.SolvedCountMismatch;
    }
};
/// Validate the complete final section; return its unchanged preceding bytes.
pub fn before(full: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, full, header) orelse return error.MissingSolvedSection;
    if ((at != 0 and full[at - 1] != '\n') or std.mem.indexOfPos(u8, full, at + header.len, "solved-representations ") != null) return error.DuplicateSolvedSection;
    const finish = std.mem.indexOfPos(u8, full, at + header.len, end) orelse return error.MissingSolvedEnd;
    if (finish + end.len != full.len) return error.TrailingSolvedSection;
    var state: Module = .{};
    defer state.deinit();
    var lines = std.mem.splitScalar(u8, full[at + header.len .. finish], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = try token(&it);
        if (std.mem.eql(u8, tag, "solved-module") and !std.mem.startsWith(u8, line, " ")) try state.begin(&it) else if (std.mem.eql(u8, tag, "solved-root") and std.mem.startsWith(u8, line, "  solved-root ")) try state.root(&it) else if (std.mem.eql(u8, tag, "solved-node") and std.mem.startsWith(u8, line, "  solved-node ")) try state.readNode(&it) else return error.UnknownSolvedRow;
    }
    try state.finish();
    return full[0..at];
}
