//! Rules of the whole of `src/` that no type can enforce, enforced by
//! reading the sources (`check/rules_test.zig` holds the checker's own).
//!
//! **No hash map keyed by a dense id** (`fast-compiler.md` §5 rule 5, the
//! lint Roc runs in CI). An id that indexes an array — a `Var`, a `Symbol`,
//! an instruction, a declaration, any `enum(u32)` the compiler numbers — is
//! looked up by indexing a column beside that array: a stamped column
//! (`stamped.zig`) when the scope is short-lived, so clearing it is one
//! increment (`Graph.name_rows`, `check/Retained.zig`'s boundary sets).
//! Hashing it costs a hash per lookup and a table that grows by rehashing.
//! The size of the id's domain is not by itself a reason to hash it; a
//! measurement can be, and the allowlist says which.
//!
//! What the rule reads: every `HashMap`, `ArrayHashMap` and their `Auto`
//! and `Unmanaged` spellings, `int_hash.Map`, `Symbol.Map` and `U32Set`, at
//! a declaration (a pointer to one, `*std.…`, and a function's parameter
//! list are uses, not declarations). Its key is dense when it is `u32` or
//! the name of an `enum(u32)` declared anywhere in `src/`, however it is
//! qualified. A composite key — a struct, a tuple, a slice — is not a dense
//! id and is not read.
//!
//! **The allowlist** names each exception by file and by a text its line
//! holds, with why a column does not serve there. An entry nothing matches
//! is an error too, so the list cannot outlive what it excuses.

const std = @import("std");
const testing = std.testing;

const Allowed = struct {
    /// Under `src/`.
    path: []const u8,
    /// Text of the declaration's line.
    needle: []const u8,
    why: []const u8,
};

/// Lowering's name tables: a file names a few hundred of its worker's
/// symbols. Stamped columns per worker, indexed by symbol, were built and
/// measured (2026-09-29, a cold `check` of the 100k-line generated corpus
/// at one job): 0.4 % fewer instructions, but 233 more page faults and 1 MB
/// more resident, and lowering 3 % slower, because a column touches a slot
/// for every symbol the worker has ever declared a name with, where a map
/// lives in the per-file arena's warm pages.
const lowering_names = "a file's names, sparse in the worker's symbols; a column was measured slower (above)";

const allowlist = [_]Allowed{
    .{ .path = "InternPool.zig", .needle = "std.HashMapUnmanaged(Symbol, V, HashContext", .why = "the definition of `Symbol.Map`, whose every use is listed here" },
    .{ .path = "frontend/artifact_bytes.zig", .needle = "var table: std.AutoArrayHashMapUnmanaged(InternPool.Symbol, u32)", .why = "writing an artifact only: a file's symbols in first-use order, which is the order written" },
    .{ .path = "check/Evidence.zig", .needle = "rejected: std.AutoHashMapUnmanaged(Var, std.ArrayList(Flag))", .why = "the error path: a receiver a rejection was reported on" },
    .{ .path = "check/Schema.zig", .needle = "var memo: std.AutoHashMapUnmanaged(Var, Var)", .why = "a schema endpoint's copy, once per schema declaration; the store's own copy memo is the instantiator's while this runs" },
    .{ .path = "check/Publish.zig", .needle = "var seen: std.AutoHashMapUnmanaged(Types.TypeId, void)", .why = "once per module, over the few types its interface names" },
    .{ .path = "check/Publish.zig", .needle = "slots: InternPool.Symbol.Map(u32)", .why = "a constructor's payload fields by name, once per published constructor" },
    .{ .path = "check/Schemes.zig", .needle = "ref_index: int_hash.Map(TypeStore.TypeId, u32)", .why = "an interface's type references, few per module, from a session-wide id space; measured in place" },
    .{ .path = "check/Render.zig", .needle = "by_var: std.AutoHashMapUnmanaged(Var, []const u8)", .why = "the error path: a message's variable names" },
    .{ .path = "check/Render.zig", .needle = "qualified: std.AutoHashMapUnmanaged(TypeStore.TypeId, void)", .why = "the error path: a message's type names" },
    .{ .path = "check/Render.zig", .needle = "var seen: std.AutoHashMapUnmanaged(Var, void)", .why = "the error path: one message's variables" },
    .{ .path = "check/Render.zig", .needle = "var by_name: std.AutoHashMapUnmanaged(Symbol, TypeStore.TypeId)", .why = "the error path: one message's type names" },
    .{ .path = "check/Producers.zig", .needle = "var seen: std.AutoHashMapUnmanaged(u32, void)", .why = "the error path: the producers one message names" },
    .{ .path = "bir/Lower.zig", .needle = "values: Symbol.Map(NameEntry)", .why = lowering_names },
    .{ .path = "bir/Lower.zig", .needle = "ctor_names: Symbol.Map(NameEntry)", .why = lowering_names },
    .{ .path = "bir/Lower.zig", .needle = "types: Symbol.Map(NameEntry)", .why = lowering_names },
    .{ .path = "bir/Lower.zig", .needle = "schemas: Symbol.Map(NameEntry)", .why = lowering_names },
    .{ .path = "bir/Lower.zig", .needle = "import_by_alias: Symbol.Map(u32)", .why = lowering_names },
    .{ .path = "bir/Lower.zig", .needle = "import_by_module: Symbol.Map(u32)", .why = lowering_names },
    .{ .path = "bir/Lower.zig", .needle = "scope_index: Symbol.Map(u32)", .why = lowering_names },
    .{ .path = "bir/Lower.zig", .needle = "type_param_index: Symbol.Map(u32)", .why = lowering_names },
    .{ .path = "bir/Lower.zig", .needle = "map: std.AutoHashMapUnmanaged(Symbol, TokenIndex)", .why = "one markup tag's attribute names, only past 16 of them; sparse in the worker's symbols like the name tables" },
    .{ .path = "bir/Lower.zig", .needle = "parents: std.AutoHashMapUnmanaged(u32, []Parent)", .why = "markup rows only: the few declarations a row's analysis reaches" },
    .{ .path = "bir/Lower.zig", .needle = "summaries: std.AutoArrayHashMapUnmanaged(u32, Summary)", .why = "markup rows only: the functions a row's analysis reaches, iterated in the order reached" },
    .{ .path = "bir/Lower.zig", .needle = "set: U32Set", .why = "a record's field names, only past 16 fields" },
    .{ .path = "u32_set.zig", .needle = "var set: U32Set = .{};", .why = "the set's own test" },
    .{ .path = "check/Edges.zig", .needle = "var seen: U32Set", .why = "the evidence terms one edge walk reaches, a few of the session's" },
    .{ .path = "check/Report.zig", .needle = "error_regions: U32Set", .why = "the error path: the instructions already reported" },
    .{ .path = "js/Lower.zig", .needle = "calls: U32Set", .why = "the calls one derived body makes" },
    .{ .path = "js/Lower.zig", .needle = "requests: U32Set", .why = "the derived rows one module requests" },
};

/// The spellings of a hash map type whose first argument is its key.
const keyed = [_][]const u8{ "HashMapUnmanaged(", "HashMap(", "int_hash.Map(" };
/// A key-first spelling that is not a dense-keyed map.
const string_keyed = [_][]const u8{ "StringHashMap", "StringArrayHashMap" };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "//");
}

/// The last name of a possibly qualified type, `Bir.Inst.Index` → `Index`.
fn lastName(key: []const u8) []const u8 {
    const t = std.mem.trim(u8, key, " ");
    const dot = std.mem.lastIndexOfScalar(u8, t, '.') orelse return t;
    return t[dot + 1 ..];
}

/// Whether `key` is a dense id: `u32`, or a name `dense` holds, qualified
/// or not. Anything with structure in it is not.
fn denseKey(key: []const u8, dense: *const std.StringHashMapUnmanaged(void)) bool {
    const t = std.mem.trim(u8, key, " ");
    for (t) |c| if (!(isIdent(c) or c == '.')) return false;
    if (std.mem.eql(u8, t, "u32")) return true;
    return dense.contains(lastName(t));
}

/// The start of the type expression `at` is in: back over a qualified name.
fn typeStart(line: []const u8, at: usize) usize {
    var i = at;
    while (i > 0 and (isIdent(line[i - 1]) or line[i - 1] == '.')) i -= 1;
    return i;
}

/// The dense keys the declarations on `line` are hashed by, one per map.
fn denseMaps(line: []const u8, dense: *const std.StringHashMapUnmanaged(void), out: *[8][]const u8) usize {
    if (isComment(line)) return 0;
    // A parameter list names a map it is handed, not one it declares.
    if (std.mem.indexOf(u8, line, "fn ") != null) return 0;
    var n: usize = 0;
    var from: usize = 0;
    while (from < line.len and n < out.len) {
        // The earliest map spelling from here.
        var best: ?struct { at: usize, len: usize, key: ?[]const u8 } = null;
        for (keyed) |k| {
            const at = std.mem.indexOfPos(u8, line, from, k) orelse continue;
            if (best == null or at < best.?.at) best = .{ .at = at, .len = k.len, .key = null };
        }
        inline for (.{ "Symbol.Map(", "U32Set" }) |k| {
            if (std.mem.indexOfPos(u8, line, from, k)) |at| {
                if (best == null or at < best.?.at) best = .{ .at = at, .len = k.len, .key = if (k[0] == 'S') "Symbol" else "u32" };
            }
        }
        const b = best orelse break;
        from = b.at + b.len;
        const start = typeStart(line, b.at);
        // `*T` is a pointer to a map, `const U32Set = @import` the type.
        if (start > 0 and line[start - 1] == '*') continue;
        const spelled = line[start..from];
        var skip = false;
        for (string_keyed) |s| {
            if (std.mem.indexOf(u8, spelled, s) != null) skip = true;
        }
        if (skip) continue;
        if (b.key) |fixed| {
            if (std.mem.eql(u8, fixed, "u32") and std.mem.indexOf(u8, line, "@import") != null) continue;
            if (std.mem.eql(u8, fixed, "u32") and std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "pub const U32Set")) continue;
            out[n] = fixed;
            n += 1;
            continue;
        }
        const comma = std.mem.indexOfScalarPos(u8, line, from, ',') orelse continue;
        const key = line[from..comma];
        if (!denseKey(key, dense)) continue;
        out[n] = std.mem.trim(u8, key, " ");
        n += 1;
    }
    return n;
}

fn lineStart(text: []const u8, at: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
}

fn lineEnd(text: []const u8, at: usize) usize {
    return std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
}

/// The starts of the lines of `text` that mention a map spelling, in
/// order: the only lines `denseMaps` can find anything on. One pass per
/// spelling over the whole text, rather than every spelling per line, keeps
/// the test inside its budget in a Debug build.
fn candidateLines(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(usize)) !void {
    out.clearRetainingCapacity();
    for ([_][]const u8{ "HashMap", "Map(", "U32Set" }) |spelling| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, spelling)) |at| {
            const start = lineStart(text, at);
            from = lineEnd(text, at);
            if (std.mem.indexOfScalar(usize, out.items, start) == null) try out.append(gpa, start);
        }
    }
    std.mem.sort(usize, out.items, {}, std.sort.asc(usize));
}

/// Every `enum(u32)` declared in `text`, by name, into `dense`.
fn collectDense(gpa: std.mem.Allocator, text: []const u8, dense: *std.StringHashMapUnmanaged(void)) !void {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, " = enum(u32)")) |at| {
        from = at + 1;
        const before = std.mem.trimEnd(u8, text[lineStart(text, at)..at], " ");
        var i = before.len;
        while (i > 0 and isIdent(before[i - 1])) i -= 1;
        const name = before[i..];
        if (name.len == 0) continue;
        const got = try dense.getOrPut(gpa, name);
        if (!got.found_existing) got.key_ptr.* = try gpa.dupe(u8, name);
    }
}

const Source = struct { path: []const u8, text: []const u8 };

fn readSources(gpa: std.mem.Allocator, io: std.Io, out: *std.ArrayList(Source)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const text = try dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 24));
        errdefer gpa.free(text);
        try out.append(gpa, .{ .path = try gpa.dupe(u8, entry.path), .text = text });
    }
}

test "no hash map is keyed by a dense id outside the allowlist" {
    const gpa = testing.allocator;
    const io = testing.io;
    var sources: std.ArrayList(Source) = .empty;
    defer {
        for (sources.items) |s| {
            gpa.free(s.path);
            gpa.free(s.text);
        }
        sources.deinit(gpa);
    }
    try readSources(gpa, io, &sources);
    try testing.expect(sources.items.len > 100);

    var dense: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = dense.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        dense.deinit(gpa);
    }
    for (sources.items) |s| try collectDense(gpa, s.text, &dense);
    // The ids every IR is built from are among them.
    for ([_][]const u8{ "Symbol", "Var", "TypeId", "Index" }) |name| try testing.expect(dense.contains(name));

    var used = [_]bool{false} ** allowlist.len;
    var bad: usize = 0;
    var starts: std.ArrayList(usize) = .empty;
    defer starts.deinit(gpa);
    for (sources.items) |s| {
        if (std.mem.eql(u8, s.path, "rules_test.zig")) continue;
        try candidateLines(gpa, s.text, &starts);
        for (starts.items) |start| {
            const line = s.text[start..lineEnd(s.text, start)];
            const n = std.mem.count(u8, s.text[0..start], "\n") + 1;
            var keys: [8][]const u8 = undefined;
            const found = denseMaps(line, &dense, &keys);
            for (keys[0..found]) |key| {
                var allowed = false;
                for (allowlist, 0..) |a, i| {
                    if (!std.mem.eql(u8, a.path, s.path) or std.mem.indexOf(u8, line, a.needle) == null) continue;
                    allowed = true;
                    used[i] = true;
                }
                if (allowed) continue;
                std.debug.print("src/{s}:{d}: a hash map keyed by `{s}`, a dense id: index a column instead (fast-compiler.md §5 rule 5), or list it in src/rules_test.zig with why a column does not serve\n", .{ s.path, n, key });
                bad += 1;
            }
        }
    }
    for (allowlist, used) |a, u| {
        if (u) continue;
        std.debug.print("src/rules_test.zig: the allowlist entry for src/{s} (`{s}`) matches nothing: remove it\n", .{ a.path, a.needle });
        bad += 1;
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "a dense key is told from a composite one, and a pointer from a declaration" {
    const gpa = testing.allocator;
    var dense: std.StringHashMapUnmanaged(void) = .empty;
    defer dense.deinit(gpa);
    try dense.put(gpa, "Var", {});
    try dense.put(gpa, "Index", {});
    var keys: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 1), denseMaps("    seen: std.AutoHashMapUnmanaged(Var, void) = .empty,", &dense, &keys));
    try testing.expectEqualStrings("Var", keys[0]);
    try testing.expectEqual(@as(usize, 1), denseMaps("var m: std.AutoArrayHashMapUnmanaged(Bir.Inst.Index, u8) = .empty;", &dense, &keys));
    try testing.expectEqual(@as(usize, 1), denseMaps("given: std.AutoHashMapUnmanaged(u32, Range) = .empty,", &dense, &keys));
    try testing.expectEqual(@as(usize, 1), denseMaps("slots: InternPool.Symbol.Map(u32) = .empty,", &dense, &keys));
    try testing.expectEqual(@as(usize, 1), denseMaps("    set: U32Set = .{},", &dense, &keys));
    try dense.put(gpa, "TypeId", {});
    try testing.expectEqual(@as(usize, 1), denseMaps("ref_index: int_hash.Map(TypeStore.TypeId, u32) = .empty,", &dense, &keys));
    try testing.expectEqual(@as(usize, 0), denseMaps("    derived: std.AutoHashMapUnmanaged(MemoKey, WantedId) = .empty,", &dense, &keys));
    try testing.expectEqual(@as(usize, 0), denseMaps("active_deep: std.AutoArrayHashMapUnmanaged([2]Var, void) = .empty,", &dense, &keys));
    try testing.expectEqual(@as(usize, 0), denseMaps("var said: std.AutoHashMapUnmanaged(struct { Types.TypeId, Symbol }, void) = .empty;", &dense, &keys));
    try testing.expectEqual(@as(usize, 0), denseMaps("    names: std.StringHashMapUnmanaged(Var) = .empty,", &dense, &keys));
    try testing.expectEqual(@as(usize, 0), denseMaps("fn cap(s: *Solve, promoted: *std.AutoHashMapUnmanaged(Var, void)) Error!void {", &dense, &keys));
    try testing.expectEqual(@as(usize, 0), denseMaps("    seen: *std.AutoHashMapUnmanaged(Var, void),", &dense, &keys));
    try testing.expectEqual(@as(usize, 0), denseMaps("const U32Set = @import(\"../u32_set.zig\").U32Set;", &dense, &keys));
    try testing.expectEqual(@as(usize, 0), denseMaps("    // seen: std.AutoHashMapUnmanaged(Var, void)", &dense, &keys));
}
