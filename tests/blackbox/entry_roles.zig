//! Public text protocol reader; no compiler internals or proof inference.
const std = @import("std");
pub const header = "entry-role-transfers schema=1 evidence=owned-source answerValidation=structural entryComplete=false invocationComplete=false\n";
const Rule = struct { row: []const u8, count: []const u8, keys: []const u8 };
const rules = [_]Rule{
    .{ .row = "role-transfer", .count = "transfers", .keys = "entry anchor constructor role origin template seed source W S captures kind sourceStatus" },
    .{ .row = "role-capture", .count = "captures", .keys = "transfer binding input W S sourceStatus" },
    .{ .row = "role-port", .count = "ports", .keys = "owner tag lhs rhs values source" },
    .{ .row = "role-call", .count = "calls", .keys = "owner site target callee arguments captures" },
    .{ .row = "role-input", .count = "inputs", .keys = "owner position port capture defining local" },
    .{ .row = "role-field", .count = "fields", .keys = "allocation selector value" },
    .{ .row = "role-allocation", .count = "allocations", .keys = "kind origin fields base shape complete" },
    .{ .row = "role-query", .count = "queries", .keys = "port observation seed sourceStatus" },
    .{ .row = "role-fact", .count = "facts", .keys = "query answer" },
    .{ .row = "role-edge", .count = "edges", .keys = "source target kind call seal" },
    .{ .row = "role-derivation", .count = "derivations", .keys = "target source via" },
    .{ .row = "role-transport", .count = "transports", .keys = "kind edge via call input formal actual binding" },
    .{ .row = "role-module", .count = "modules", .keys = "declarations name" },
    .{ .row = "role-declaration", .count = "declarations", .keys = "template exported anchor name" },
    .{ .row = "role-template", .count = "templates", .keys = "site body inputs lexical" },
    .{ .row = "role-site", .count = "sites", .keys = "source" },
    .{ .row = "role-origin", .count = "origins", .keys = "kind site target" },
    .{ .row = "role-selector", .count = "selectors", .keys = "kind key" },
    .{ .row = "role-anchor", .count = "anchors", .keys = "module declaration kind site" },
    .{ .row = "role-seal", .count = "seals", .keys = "anchor kind initializer" },
    .{ .row = "role-observation", .count = "observations", .keys = "mode control prefix selector kind role constructor anchor capture" },
    .{ .row = "role-answer", .count = "answers", .keys = "kind input observation origin anchor site reason" },
    .{ .row = "role-seed", .count = "seeds", .keys = "template anchor role" },
    .{ .row = "role-binding", .count = "bindings", .keys = "seed input W S runtime" },
    .{ .row = "role-obligation", .count = "obligations", .keys = "query needs next" },
    .{ .row = "role-constructor", .count = "constructors", .keys = "kind origin callbacks roles arguments" },
    .{ .row = "role-layout", .count = "layouts", .keys = "selector position" },
    .{ .row = "role-execution", .count = "execution", .keys = "owner site kind target argument" },
    .{ .row = "role-export", .count = "exports", .keys = "owner launch port" },
};
fn known(value: []const u8, choices: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, choices, ' ');
    while (words.next()) |word| if (std.mem.eql(u8, word, value)) return true;
    return false;
}
pub fn field(line: []const u8, key: []const u8) ![]const u8 {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    while (words.next()) |word| {
        const eq = std.mem.indexOfScalar(u8, word, '=') orelse continue;
        if (std.mem.eql(u8, word[0..eq], key)) return word[eq + 1 ..];
    }
    return error.MissingRoleField;
}
pub fn number(line: []const u8, key: []const u8) !u32 {
    return std.fmt.parseInt(u32, try field(line, key), 10);
}
fn valueValid(tag: []const u8, key: []const u8, value: []const u8) !void {
    if (value.len == 0) return error.EmptyRoleValue;
    if (known(key, "entry name key")) return;
    var choices: ?[]const u8 = null;
    if (known(key, "control runtime complete") or (std.mem.eql(u8, key, "capture") and std.mem.eql(u8, tag, "role-input"))) choices = "true false";
    if (std.mem.eql(u8, key, "sourceStatus")) choices = "closed absent symbolic non_static unproved";
    if (std.mem.eql(u8, key, "mode")) choices = "W S";
    if (std.mem.eql(u8, key, "prefix")) choices = "none field role";
    if (std.mem.eql(u8, key, "tag")) choices = "input alias alternatives function literal opaque runtime allocation closure project call constructor seal residual";
    if (std.mem.eql(u8, key, "reason")) choices = "higher_order projection shape native_flow missing_body missing_binding unproductive dispatch metadata materialization_control";
    if (std.mem.eql(u8, key, "kind")) {
        if (std.mem.eql(u8, tag, "role-transfer")) choices = "callback runtime";
        if (std.mem.eql(u8, tag, "role-origin")) choices = "function literal opaque runtime allocation closure constructor";
        if (std.mem.eql(u8, tag, "role-allocation")) choices = "record tuple list tagged";
        if (std.mem.eql(u8, tag, "role-selector")) choices = "field tuple";
        if (std.mem.eql(u8, tag, "role-edge")) choices = "copy substitute seal";
        if (std.mem.eql(u8, tag, "role-transport")) choices = "actual binding";
        if (std.mem.eql(u8, tag, "role-answer")) choices = "absent input origin static_leaf production runtime_external unknown_materialization residual";
        if (std.mem.eql(u8, tag, "role-execution")) choices = "known_call launch evaluate descriptor residual";
    }
    if (choices) |allowed| {
        if (!known(value, allowed)) return error.InvalidRoleValue;
        return;
    }
    const is_range = known(key, "declarations values arguments captures fields shape inputs roles");
    const coordinate = std.mem.eql(u8, key, "source") and known(tag, "role-port role-site");
    if (is_range or coordinate) {
        var fields = std.mem.splitScalar(u8, value, ':');
        var n: usize = 0;
        while (fields.next()) |part| {
            _ = try std.fmt.parseInt(u32, part, 10);
            n += 1;
        }
        if (n != @as(usize, if (coordinate) 3 else 2)) return error.InvalidRoleRange;
        return;
    }
    _ = try std.fmt.parseInt(u32, value, 10);
}
/// Strictly validate the one complete final producer section before stripping it.
pub fn before(full: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, full, header) orelse return error.MissingRoleHeader;
    if ((at != 0 and full[at - 1] != '\n') or std.mem.indexOfPos(u8, full, at + header.len, "entry-role-transfers ") != null or !std.mem.endsWith(u8, full, "\n")) return error.InvalidRoleHeader;
    var seen: [rules.len]u64 = @splat(0);
    var expected: [rules.len]u64 = @splat(0);
    var count_headers: u8 = 0;
    var extra_rows: u8 = 0;
    var source_words: u64 = 0;
    var source_rows: u64 = 0;
    var solver_rows: u64 = 0;
    var last_decl: ?u64 = null;
    var seen_keys: u64 = 0;
    var lines = std.mem.splitScalar(u8, full[at + header.len ..], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (extra_rows != 0) return error.TrailingRoleRows;
        if (!std.mem.startsWith(u8, line, "  ")) return error.InvalidRoleIndent;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const tag = words.next().?;
        if (known(tag, "role-counts role-directory-counts")) {
            const bit: u8 = if (std.mem.eql(u8, tag, "role-counts")) 1 else 2;
            if (count_headers & bit != 0) return error.DuplicateRoleCounts;
            count_headers |= bit;
            while (words.next()) |word| {
                const eq = std.mem.indexOfScalar(u8, word, '=') orelse return error.InvalidRoleCount;
                const key = word[0..eq];
                const n = try std.fmt.parseInt(u64, word[eq + 1 ..], 10);
                var found = false;
                var key_index: usize = 0;
                for (rules, 0..) |r, i| if (std.mem.eql(u8, key, r.count)) {
                    expected[i] = n;
                    key_index = i;
                    found = true;
                    break;
                };
                if (!found) {
                    if (std.mem.eql(u8, key, "sourceWords")) {
                        source_words = n;
                        key_index = rules.len;
                    } else if (std.mem.eql(u8, key, "sourceRows")) {
                        source_rows = n;
                        key_index = rules.len + 1;
                    } else if (std.mem.eql(u8, key, "solverRows")) {
                        solver_rows = n;
                        key_index = rules.len + 2;
                    } else return error.UnknownRoleCount;
                }
                const key_bit = @as(u64, 1) << @intCast(key_index);
                if (seen_keys & key_bit != 0) return error.DuplicateRoleCount;
                seen_keys |= key_bit;
            }
            continue;
        }
        if (count_headers != 3) return error.IncompleteRoleCounts;
        if (std.mem.eql(u8, tag, "role-extra")) {
            extra_rows += 1;
            if (try number(line, "words") != source_words) return error.InvalidRoleExtra;
            _ = words.next();
            var n: u64 = 0;
            while (words.next()) |word| {
                _ = try std.fmt.parseInt(u32, word, 10);
                n += 1;
            }
            if (n != source_words) return error.InvalidRoleExtra;
            continue;
        }
        var found = false;
        for (rules, 0..) |r, i| {
            if (!std.mem.eql(u8, tag, r.row)) continue;
            found = true;
            const raw_id = words.next() orelse return error.MissingRoleId;
            if (std.mem.eql(u8, tag, "role-declaration")) {
                var ids = std.mem.splitScalar(u8, raw_id, ':');
                const module = try std.fmt.parseInt(u32, ids.next().?, 10);
                const decl = try std.fmt.parseInt(u32, ids.next() orelse return error.InvalidRoleId, 10);
                if (ids.next() != null) return error.InvalidRoleId;
                const pair_key = (@as(u64, module) << 32) | decl;
                if (last_decl) |previous| if (pair_key <= previous) return error.DuplicateRoleId;
                last_decl = pair_key;
            } else if (try std.fmt.parseInt(u64, raw_id, 10) != seen[i]) return error.InvalidRoleId;
            var keys = std.mem.tokenizeScalar(u8, r.keys, ' ');
            while (keys.next()) |key| {
                const word = words.next() orelse return error.MissingRoleField;
                const eq = std.mem.indexOfScalar(u8, word, '=') orelse return error.InvalidRoleField;
                if (!std.mem.eql(u8, word[0..eq], key)) return error.InvalidRoleField;
                try valueValid(tag, key, word[eq + 1 ..]);
            }
            if (words.next() != null) return error.UnknownRoleField;
            seen[i] += 1;
            break;
        }
        if (!found) return error.UnknownRoleRow;
    }
    if (seen_keys != (@as(u64, 1) << (rules.len + 3)) - 1 or count_headers != 3 or extra_rows != 1 or !std.mem.eql(u64, &seen, &expected)) return error.IncompleteRoleSection;
    var actual_source: u64 = 0;
    var actual_solver: u64 = 0;
    for (rules, 0..) |r, i| {
        if (known(r.count, "modules declarations templates sites origins selectors anchors seals constructors layouts execution exports ports calls inputs fields allocations")) actual_source += seen[i];
        if (known(r.count, "queries facts edges seeds bindings obligations derivations transports")) actual_solver += seen[i];
    }
    if (source_rows != actual_source or solver_rows != actual_solver + seen[7]) return error.IncorrectRoleWork;
    return full[0..at];
}

pub const Range = struct { start: u32, len: u32 };
pub fn range(line: []const u8, key: []const u8) !Range {
    var parts = std.mem.splitScalar(u8, try field(line, key), ':');
    const start = try std.fmt.parseInt(u32, parts.next().?, 10);
    const len = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidRoleRange, 10);
    if (parts.next() != null) return error.InvalidRoleRange;
    return .{ .start = start, .len = len };
}
pub fn id(line: []const u8) !u32 {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    _ = words.next();
    return std.fmt.parseInt(u32, words.next() orelse return error.MissingRoleId, 10);
}
/// Dense text table indexes, allocated by the test and borrowing only stdout.
pub const Parsed = struct {
    tables: [rules.len][][]const u8,
    words: []u32,
    pub fn init(a: std.mem.Allocator, full: []const u8) !Parsed {
        _ = try before(full);
        const at = std.mem.indexOf(u8, full, header).?;
        const body = full[at + header.len ..];
        var lines = std.mem.splitScalar(u8, body, '\n');
        const counts = lines.next().?;
        const dirs = lines.next().?;
        var p: Parsed = undefined;
        for (rules, 0..) |r, i| {
            const line = if (i < 12) counts else dirs;
            p.tables[i] = try a.alloc([]const u8, try number(line, r.count));
        }
        p.words = try a.alloc(u32, try number(counts, "sourceWords"));
        var offsets: [rules.len]usize = @splat(0);
        while (lines.next()) |line| {
            var tokens = std.mem.tokenizeScalar(u8, line, ' ');
            const tag = tokens.next() orelse continue;
            if (std.mem.eql(u8, tag, "role-extra")) {
                _ = tokens.next();
                for (p.words) |*word| word.* = try std.fmt.parseInt(u32, tokens.next().?, 10);
            }
            for (rules, 0..) |r, i| if (std.mem.eql(u8, tag, r.row)) {
                p.tables[i][offsets[i]] = line;
                offsets[i] += 1;
                break;
            };
        }
        return p;
    }
    pub fn rows(p: *const Parsed, tag: []const u8) ![][]const u8 {
        for (rules, 0..) |r, i| if (std.mem.eql(u8, tag, r.row)) return p.tables[i];
        return error.UnknownRoleRow;
    }
    pub fn row(p: *const Parsed, tag: []const u8, index: u32) ![]const u8 {
        const table = try p.rows(tag);
        if (index >= table.len) return error.InvalidRoleId;
        return table[index];
    }
    pub fn sourceName(p: *const Parsed, site_id: u32) ![]const u8 {
        const site = try p.row("role-site", site_id);
        var parts = std.mem.splitScalar(u8, try field(site, "source"), ':');
        const module = try std.fmt.parseInt(u32, parts.next().?, 10);
        const decl = try std.fmt.parseInt(u32, parts.next().?, 10);
        const directory = try range(try p.row("role-module", module), "declarations");
        if (decl >= directory.len) return error.InvalidRoleId;
        return field(try p.row("role-declaration", directory.start + decl), "name");
    }
};
