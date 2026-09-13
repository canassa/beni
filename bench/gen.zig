//! Deterministic synthetic-corpus generator (docs/design/frontend.md §5).
//!
//! Writes a project of roughly `target_lines` lines whose shape follows real
//! Elm code — module docs, a few imports, a record alias, a custom type,
//! `init`/`update`/`view`-style functions, mostly small helpers, some large
//! `case`, records, pipelines, lambdas, interpolated and multiline strings —
//! in the language of docs/design/language.md, so the M1 front end runs over
//! it clean. The §2 performance budget is stated against this corpus, so it
//! must be honest: every construct here is one the grammar (§3) and the
//! layout rules (§4) accept, and nothing here shadows, duplicates or leaves a
//! name unbound (§5–§7).
//!
//! **Type-correct by construction** (checker.md §9): the `check` line of the
//! benchmark measures inference, and a generated corpus full of type errors
//! would measure the error path instead. Every random expression this
//! produces has type `Int`, every call is saturated, every `if` condition is
//! a comparison, and every record literal sets exactly the fields its alias
//! declares. A type error in the generated corpus is a generator bug.
//!
//! Determinism: module `i` is a pure function of `(seed, i)`, so the same
//! seed and size always produce byte-identical files, and the bench can
//! regenerate rather than check the tree in. Layout is close to the
//! formatter's canonical style (§9) but deliberately not identical: `fmt
//! --check` over the generated tree therefore exercises the compare-and-list
//! path rather than the all-canonical shortcut, which is the more useful
//! benchmark. Do not "fix" this without replacing that coverage.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_seed: u64 = 0xBE21;

pub const Stats = struct {
    files: u32,
    lines: u64,
    bytes: u64,
};

/// Generate under `out_dir` (created if missing) until at least
/// `target_lines` lines exist. Modules are written as `Gen/…/<Name>.beni`.
pub fn generate(gpa: Allocator, io: Io, out_dir: []const u8, seed: u64, target_lines: u64) !Stats {
    var root = try Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer root.close(io);
    try root.createDirPath(io, "Gen/Data");
    try root.createDirPath(io, "Gen/Ui");

    var stats: Stats = .{ .files = 0, .lines = 0, .bytes = 0 };
    var buffer: Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var index: u32 = 0;
    while (stats.lines < target_lines or index == 0) : (index += 1) {
        buffer.clearRetainingCapacity();
        const lines = try writeModule(&buffer.writer, seed, index);
        var path_buf: [64]u8 = undefined;
        const rel = modulePath(&path_buf, index);
        try root.writeFile(io, .{ .sub_path = rel, .data = buffer.written() });
        stats.files += 1;
        stats.lines += lines;
        stats.bytes += buffer.written().len;
    }
    return stats;
}

/// The abuse inputs too big to check into `bench/pathological/`
/// (the limit there is 256 KB). Each is one file, one line, and is
/// regenerated on demand by `bench --pathological=<name>` so the repository
/// does not carry ten megabytes of `1, 1, 1, …` forever.
///
/// Only `big-list` is over the 200 ms that earns a permanent place (500 ms,
/// 228 MB peak at M1d); the other three are here because they are the same
/// shape one size down and are what the next regression will be measured
/// against.
pub const Pathological = enum {
    /// 10 MB of `[ 1, 1, … ]` on one line. VALID: it must lex, parse and
    /// lower clean, which is what makes it a throughput case rather than
    /// an error case. 3.5 M tokens, 3.5 M nodes.
    @"big-list",
    /// 10 MB of one string literal: one token, and the case where the
    /// lexer's inner loop is everything.
    @"big-string",
    /// 10 MB of one identifier: one token, interned once, and a hash of
    /// ten megabytes.
    @"big-ident",
    /// 100 000 nested `\x ->`: right-nested, so the parser recurses and
    /// the depth guard stops it at 4096 — with 4095 `shadowing` errors
    /// under it, which is the diagnostic-volume case.
    @"deep-lambdas",

    pub fn parse(name: []const u8) ?Pathological {
        return std.meta.stringToEnum(Pathological, name);
    }

    /// Where the case is written under the output directory. Every path
    /// segment is an upper identifier so the file has a module name
    /// (language.md §1).
    pub fn path(which: Pathological) []const u8 {
        return switch (which) {
            .@"big-list" => "Gen/BigList.beni",
            .@"big-string" => "Gen/BigString.beni",
            .@"big-ident" => "Gen/BigIdent.beni",
            .@"deep-lambdas" => "Gen/DeepLambdas.beni",
        };
    }
};

/// Write one pathological case under `out_dir`, replacing whatever was
/// there.
pub fn generatePathological(gpa: Allocator, io: Io, out_dir: []const u8, which: Pathological) !Stats {
    var buffer: Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try writePathological(&buffer.writer, which);

    var root = try Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer root.close(io);
    try root.createDirPath(io, "Gen");
    const text = buffer.written();
    try root.writeFile(io, .{ .sub_path = which.path(), .data = text });
    return .{ .files = 1, .lines = std.mem.count(u8, text, "\n"), .bytes = text.len };
}

const ten_megabytes = 10 * 1024 * 1024;

pub fn writePathological(w: *Io.Writer, which: Pathological) Io.Writer.Error!void {
    switch (which) {
        .@"big-list" => {
            try w.writeAll("main =\n    [ 1");
            // `, 1` is three bytes; the head and tail are negligible.
            for (0..ten_megabytes / 3) |_| try w.writeAll(", 1");
            try w.writeAll(" ]\n");
        },
        .@"big-string" => {
            try w.writeAll("main =\n    \"");
            try w.splatByteAll('a', ten_megabytes);
            try w.writeAll("\"\n");
        },
        .@"big-ident" => {
            try w.splatByteAll('a', ten_megabytes);
            try w.writeByte('\n');
        },
        .@"deep-lambdas" => {
            try w.writeAll("main =\n    ");
            for (0..100_000) |_| try w.writeAll("\\x -> ");
            try w.writeAll("1\n");
        },
    }
}

/// `Gen/Page12.beni`, `Gen/Data/Store13.beni`, `Gen/Ui/Widget14.beni`.
pub fn modulePath(buf: []u8, index: u32) []const u8 {
    return switch (index % 3) {
        0 => std.fmt.bufPrint(buf, "Gen/Page{d}.beni", .{index}),
        1 => std.fmt.bufPrint(buf, "Gen/Data/Store{d}.beni", .{index}),
        else => std.fmt.bufPrint(buf, "Gen/Ui/Widget{d}.beni", .{index}),
    } catch unreachable;
}

/// The module name for `modulePath(index)`.
pub fn moduleName(buf: []u8, index: u32) []const u8 {
    return switch (index % 3) {
        0 => std.fmt.bufPrint(buf, "Gen.Page{d}", .{index}),
        1 => std.fmt.bufPrint(buf, "Gen.Data.Store{d}", .{index}),
        else => std.fmt.bufPrint(buf, "Gen.Ui.Widget{d}", .{index}),
    } catch unreachable;
}

/// Write module `index` and return its line count.
pub fn writeModule(writer: *Io.Writer, seed: u64, index: u32) Io.Writer.Error!u64 {
    var prng: std.Random.DefaultPrng = .init(seed ^ (@as(u64, index) +% 1) *% 0x9E3779B97F4A7C15);
    var g: Module = .{ .w = writer, .rng = prng.random(), .index = index };
    try g.module();
    return g.lines;
}

/// One module's generator: a PRNG, a writer, and the scoping bookkeeping
/// that keeps the output free of shadowing.
const Module = struct {
    w: *Io.Writer,
    rng: std.Random,
    index: u32,
    lines: u64 = 0,
    /// Locals in scope in the function being generated, innermost last.
    locals: [24][]const u8 = undefined,
    /// Whether `locals[i]` holds an `Int`. A let-bound FUNCTION is in scope
    /// — a name chosen next to it must not collide with it — but it is not
    /// an `Int` and must never be written where one belongs, or the corpus
    /// stops type-checking (checker.md §9).
    local_is_int: [24]bool = undefined,
    local_count: usize = 0,
    /// Next fresh suffix when the realistic name pool is exhausted.
    fresh: u32 = 0,
    /// Earlier modules imported with `exposing (helperK)`.
    exposed: [4]u32 = undefined,
    exposed_count: usize = 0,
    /// Earlier modules imported with `as PK`.
    aliased: [4]u32 = undefined,
    aliased_count: usize = 0,
    /// Which optional fields this module's `Model` alias declares. A record
    /// literal is closed, so `init` must set exactly these.
    has_ratio: bool = false,
    has_selected: bool = false,

    const local_pool = [_][]const u8{
        "acc",   "item",  "total",  "count",  "first", "rest",  "key",   "value",
        "left",  "right", "n",      "k",      "s",     "t",     "xs",    "ys",
        "label", "width", "height", "amount", "index", "found", "limit", "step",
    };

    const words = [_][]const u8{
        "alpha", "beta",   "gamma", "delta", "report", "user",  "order", "item",
        "total", "status", "ready", "done",  "north",  "south", "east",  "west",
    };

    /// A prelude function on `Int`, with the number of atoms that saturate
    /// it. Every call the generator writes is saturated: an accidental
    /// partial application is exactly the `too_few_args` of checker.md §8.3,
    /// and a corpus full of them would measure the error path.
    const PreludeCall = struct { prefix: []const u8, arity: u8 };

    const prelude_calls = [_]PreludeCall{
        .{ .prefix = "max", .arity = 2 },
        .{ .prefix = "min", .arity = 2 },
        .{ .prefix = "clamp 0 10", .arity = 1 },
        .{ .prefix = "modBy 3", .arity = 1 },
        .{ .prefix = "always 1", .arity = 1 },
    };

    // ---- output helpers ------------------------------------------------

    fn line(g: *Module, indent: usize, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
        try g.w.splatByteAll(' ', indent);
        try g.w.print(fmt, args);
        try g.w.writeByte('\n');
        g.lines += 1;
    }

    fn blank(g: *Module) Io.Writer.Error!void {
        try g.w.writeByte('\n');
        g.lines += 1;
    }

    fn declGap(g: *Module) Io.Writer.Error!void {
        try g.blank();
        try g.blank();
    }

    fn chance(g: *Module, percent: u8) bool {
        return g.rng.uintLessThan(u8, 100) < percent;
    }

    fn pick(g: *Module, comptime T: type, items: []const T) T {
        return items[g.rng.uintLessThan(usize, items.len)];
    }

    // ---- scoping --------------------------------------------------------

    /// Bind a fresh local: a pool name not yet in scope, else `v<n>`.
    fn bind(g: *Module) []const u8 {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const candidate = g.pick([]const u8, &local_pool);
            if (!g.inScope(candidate)) return g.push(candidate);
        }
        for (local_pool) |candidate| if (!g.inScope(candidate)) return g.push(candidate);
        g.fresh += 1;
        // A tiny leak-free trick: the fresh names live in a static table so
        // no allocation is needed for the rare overflow case.
        return g.push(fresh_names[g.fresh % fresh_names.len]);
    }

    const fresh_names = [_][]const u8{ "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8" };

    fn push(g: *Module, name: []const u8) []const u8 {
        return g.pushTyped(name, true);
    }

    /// In scope for name choice, never used as a value.
    fn pushFunction(g: *Module, name: []const u8) []const u8 {
        return g.pushTyped(name, false);
    }

    fn pushTyped(g: *Module, name: []const u8, is_int: bool) []const u8 {
        std.debug.assert(g.local_count < g.locals.len);
        g.locals[g.local_count] = name;
        g.local_is_int[g.local_count] = is_int;
        g.local_count += 1;
        return name;
    }

    fn inScope(g: *const Module, name: []const u8) bool {
        for (g.locals[0..g.local_count]) |l| if (std.mem.eql(u8, l, name)) return true;
        return false;
    }

    fn scopeMark(g: *const Module) usize {
        return g.local_count;
    }

    fn scopeReset(g: *Module, mark: usize) void {
        g.local_count = mark;
    }

    /// An `Int`-valued local, or null when there is none: a scan over at
    /// most 24 entries, once per atom.
    fn anyLocal(g: *Module) ?[]const u8 {
        var count: usize = 0;
        for (g.local_is_int[0..g.local_count]) |is_int| {
            if (is_int) count += 1;
        }
        if (count == 0) return null;
        var wanted = g.rng.uintLessThan(usize, count);
        for (g.locals[0..g.local_count], g.local_is_int[0..g.local_count]) |name, is_int| {
            if (!is_int) continue;
            if (wanted == 0) return name;
            wanted -= 1;
        }
        return null;
    }

    // ---- module ---------------------------------------------------------

    fn module(g: *Module) Io.Writer.Error!void {
        var name_buf: [64]u8 = undefined;
        try g.line(0, "--! {s}: {s} {s} logic for the synthetic project.", .{ moduleName(&name_buf, g.index), g.pick([]const u8, &words), g.pick([]const u8, &words) });
        if (g.chance(50)) try g.line(0, "--! Generated by bench/gen.zig; every construct is language.md-valid.", .{});
        try g.blank();
        try g.imports();
        try g.declGap();

        try g.modelAlias();
        try g.declGap();
        try g.msgType();
        if (g.chance(40)) {
            try g.declGap();
            try g.shapeType();
        }
        try g.declGap();
        try g.initFn();
        try g.declGap();
        try g.updateFn();
        try g.declGap();
        try g.helperFn();
        try g.declGap();
        try g.sumFn();

        // The rest: mostly small helpers, with the occasional large case.
        const extra = 4 + g.rng.uintLessThan(u32, 10);
        var i: u32 = 0;
        while (i < extra) : (i += 1) {
            try g.declGap();
            try g.randomFn(i);
        }
    }

    fn imports(g: *Module) Io.Writer.Error!void {
        // Earlier modules only, ascending, distinct — so imports are sorted
        // by path and never duplicated.
        var candidates: [4]u32 = undefined;
        var n: usize = 0;
        if (g.index > 0) {
            const want = @min(@as(u32, 1 + g.rng.uintLessThan(u32, 3)), g.index);
            while (n < want) {
                const c = g.rng.uintLessThan(u32, g.index);
                if (std.mem.indexOfScalar(u32, candidates[0..n], c) != null) continue;
                candidates[n] = c;
                n += 1;
            }
        }
        // Path order: Gen.Data.* < Gen.Page* < Gen.Ui.*; sort by name text.
        std.mem.sort(u32, candidates[0..n], {}, struct {
            fn lessThan(_: void, a: u32, b: u32) bool {
                var ba: [64]u8 = undefined;
                var bb: [64]u8 = undefined;
                return std.mem.lessThan(u8, moduleName(&ba, a), moduleName(&bb, b));
            }
        }.lessThan);
        var name_buf: [64]u8 = undefined;
        for (candidates[0..n]) |k| {
            const name = moduleName(&name_buf, k);
            switch (g.rng.uintLessThan(u8, 3)) {
                0 => try g.line(0, "import {s}", .{name}),
                1 => {
                    try g.line(0, "import {s} as P{d}", .{ name, k });
                    g.aliased[g.aliased_count] = k;
                    g.aliased_count += 1;
                },
                else => {
                    try g.line(0, "import {s} exposing (Model{d}, helper{d})", .{ name, k, k });
                    g.exposed[g.exposed_count] = k;
                    g.exposed_count += 1;
                },
            }
        }
        if (n == 0) try g.line(0, "import List", .{});
    }

    fn modelAlias(g: *Module) Io.Writer.Error!void {
        try g.line(0, "--| The state this module keeps.", .{});
        try g.line(0, "pub type alias Model{d} =", .{g.index});
        try g.line(4, "{{ count : Int", .{});
        try g.line(4, ", name : String", .{});
        try g.line(4, ", items : List Int", .{});
        // Which optional fields exist is remembered, because a record
        // literal is CLOSED: `init` has to set exactly these and no others
        // or the corpus does not type-check.
        g.has_ratio = g.chance(50);
        g.has_selected = g.chance(30);
        if (g.has_ratio) try g.line(4, ", ratio : Float", .{});
        if (g.has_selected) try g.line(4, ", selected : Maybe Int", .{});
        try g.line(4, "}}", .{});
    }

    fn msgType(g: *Module) Io.Writer.Error!void {
        try g.line(0, "pub type Msg{d}", .{g.index});
        try g.line(4, "= Increment", .{});
        try g.line(4, "| Decrement", .{});
        try g.line(4, "| SetName String", .{});
        if (g.chance(50)) try g.line(4, "| Add Int Int", .{});
        try g.line(4, "| Reset", .{});
    }

    fn shapeType(g: *Module) Io.Writer.Error!void {
        try g.line(0, "pub opaque type Shape{d}", .{g.index});
        try g.line(4, "= Circle Float", .{});
        try g.line(4, "| Rect Float Float", .{});
        try g.line(4, "| Point", .{});
    }

    fn initFn(g: *Module) Io.Writer.Error!void {
        try g.line(0, "pub init{d} : Model{d}", .{ g.index, g.index });
        try g.line(0, "init{d} =", .{g.index});
        try g.w.splatByteAll(' ', 4);
        try g.w.print("{{ count = {d}, name = \"{s}\", items = [ {d}, {d}, {d} ]", .{
            g.rng.uintLessThan(u32, 10), g.pick([]const u8, &words), g.rng.uintLessThan(u32, 9), g.rng.uintLessThan(u32, 99), g.rng.uintLessThan(u32, 999),
        });
        if (g.has_ratio) try g.w.print(", ratio = {d}.{d}", .{ g.rng.uintLessThan(u32, 9), g.rng.uintLessThan(u32, 99) });
        if (g.has_selected) try g.w.print(", selected = Just {d}", .{g.rng.uintLessThan(u32, 9)});
        try g.w.writeAll(" }\n");
        g.lines += 1;
    }

    fn updateFn(g: *Module) Io.Writer.Error!void {
        const mark = g.scopeMark();
        defer g.scopeReset(mark);
        try g.line(0, "pub update{d} : Msg{d} -> Model{d} -> Model{d}", .{ g.index, g.index, g.index, g.index });
        try g.line(0, "update{d} msg model =", .{g.index});
        _ = g.push("msg");
        _ = g.push("model");
        try g.line(4, "case msg of", .{});
        try g.line(8, "Increment ->", .{});
        try g.line(12, "{{ model | count = model.count + 1 }}", .{});
        try g.blank();
        try g.line(8, "Decrement ->", .{});
        try g.line(12, "{{ model | count = model.count - 1 }}", .{});
        try g.blank();
        try g.line(8, "SetName newName ->", .{});
        if (g.chance(50)) {
            try g.line(12, "if String.length newName > {d} then", .{g.rng.uintLessThan(u32, 40)});
            try g.line(16, "model", .{});
            try g.line(12, "else", .{});
            try g.line(16, "{{ model | name = newName }}", .{});
        } else {
            try g.line(12, "{{ model | name = newName, count = 0 }}", .{});
        }
        try g.blank();
        try g.line(8, "_ ->", .{});
        try g.line(12, "init{d}", .{g.index});
    }

    fn helperFn(g: *Module) Io.Writer.Error!void {
        const mark = g.scopeMark();
        defer g.scopeReset(mark);
        try g.line(0, "--| A small numeric helper every module exports.", .{});
        try g.line(0, "pub helper{d} : Int -> Int", .{g.index});
        try g.line(0, "helper{d} n =", .{g.index});
        _ = g.push("n");
        switch (g.rng.uintLessThan(u8, 3)) {
            0 => try g.line(4, "n * {d} + {d}", .{ 1 + g.rng.uintLessThan(u32, 9), g.rng.uintLessThan(u32, 100) }),
            1 => try g.line(4, "max n {d} - min n {d}", .{ g.rng.uintLessThan(u32, 100), g.rng.uintLessThan(u32, 10) }),
            else => try g.line(4, "modBy {d} (abs n)", .{2 + g.rng.uintLessThan(u32, 30)}),
        }
    }

    fn sumFn(g: *Module) Io.Writer.Error!void {
        const mark = g.scopeMark();
        defer g.scopeReset(mark);
        try g.line(0, "pub sum{d} : List Int -> Int", .{g.index});
        try g.line(0, "sum{d} xs =", .{g.index});
        _ = g.push("xs");
        try g.line(4, "case xs of", .{});
        try g.line(8, "[] ->", .{});
        try g.line(12, "0", .{});
        try g.blank();
        try g.line(8, "first :: rest ->", .{});
        try g.line(12, "first + sum{d} rest", .{g.index});
    }

    // ---- the random helpers ------------------------------------------

    fn randomFn(g: *Module, n: u32) Io.Writer.Error!void {
        const mark = g.scopeMark();
        defer g.scopeReset(mark);
        // Only the first kinds are "small"; the weights favour them.
        const kind = g.rng.weightedIndex(u8, &.{ 20, 14, 12, 12, 10, 8, 8, 6, 5, 4 });
        switch (kind) {
            0 => try g.oneLiner(n),
            1 => try g.letFn(n),
            2 => try g.pipelineFn(n),
            3 => try g.ifFn(n),
            4 => try g.recordFn(n),
            5 => try g.tupleFn(n),
            6 => try g.stringFn(n),
            7 => try g.multilineFn(n),
            8 => try g.questionFn(n),
            else => try g.bigCaseFn(n),
        }
    }

    fn fnName(g: *Module, buf: []u8, n: u32, base: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}{d}_{d}", .{ base, g.index, n }) catch unreachable;
    }

    fn oneLiner(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "scale");
        if (g.chance(60)) try g.line(0, "{s} : Int -> Int", .{name});
        try g.line(0, "{s} n =", .{name});
        _ = g.push("n");
        try g.w.splatByteAll(' ', 4);
        try g.expr(2);
        try g.w.writeByte('\n');
        g.lines += 1;
    }

    fn letFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "compute");
        try g.line(0, "{s} : Int -> Int -> Int", .{name});
        try g.line(0, "{s} left right =", .{name});
        _ = g.push("left");
        _ = g.push("right");
        try g.line(4, "let", .{});
        const bindings = 1 + g.rng.uintLessThan(u32, 3);
        const with_twice = g.chance(30);

        // A `let` group's bindings are mutually recursive (language.md §6.2):
        // EVERY name it binds is in scope in EVERY value, including values
        // written earlier in the block. So all the names are chosen and
        // pushed here, before the first value is written — otherwise a
        // lambda parameter picked inside binding 1 only avoids bindings 0..1
        // and can collide with binding 2, which is a `shadowing` error in
        // the generator's own output (the bug this loop's shape fixes).
        var names: [3][]const u8 = undefined;
        for (names[0..bindings]) |*slot| slot.* = g.bind();
        if (with_twice) _ = g.pushFunction("twice");

        for (names[0..bindings], 0..) |local, i| {
            if (i != 0 and g.chance(50)) try g.blank();
            if (g.chance(30)) try g.line(8, "{s} : Int", .{local});
            if (g.chance(50)) {
                try g.line(8, "{s} =", .{local});
                try g.w.splatByteAll(' ', 12);
            } else {
                try g.w.splatByteAll(' ', 8);
                try g.w.print("{s} = ", .{local});
            }
            try g.expr(2);
            try g.w.writeByte('\n');
            g.lines += 1;
        }
        if (with_twice) {
            // A let-bound function with its own parameter: fresh against
            // every sibling binding, which is already in scope.
            const mark = g.scopeMark();
            const param = g.bind();
            try g.line(8, "twice {s} =", .{param});
            try g.line(12, "{s} * 2", .{param});
            g.scopeReset(mark);
        }
        try g.line(4, "in", .{});
        try g.w.splatByteAll(' ', 4);
        try g.expr(3);
        try g.w.writeByte('\n');
        g.lines += 1;
    }

    fn pipelineFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "process");
        try g.line(0, "{s} : List Int -> Int", .{name});
        try g.line(0, "{s} xs =", .{name});
        _ = g.push("xs");
        try g.line(4, "xs", .{});
        const steps = 2 + g.rng.uintLessThan(u32, 4);
        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            switch (g.rng.uintLessThan(u8, 4)) {
                0 => try g.line(8, "|> List.filter (\\x -> x > {d})", .{g.rng.uintLessThan(u32, 50)}),
                1 => try g.line(8, "|> List.map (\\x -> x * {d})", .{1 + g.rng.uintLessThan(u32, 9)}),
                2 => try g.line(8, "|> List.map helper{d}", .{g.index}),
                else => try g.line(8, "|> List.reverse", .{}),
            }
        }
        if (g.chance(50)) {
            try g.line(8, "|> List.foldl (\\x acc -> acc + x) 0", .{});
        } else {
            try g.line(8, "|> sum{d}", .{g.index});
        }
    }

    fn ifFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "classify");
        try g.line(0, "{s} : Int -> String", .{name});
        try g.line(0, "{s} n =", .{name});
        _ = g.push("n");
        try g.line(4, "if n < 0 then", .{});
        try g.line(8, "\"negative\"", .{});
        const arms = g.rng.uintLessThan(u32, 3);
        var i: u32 = 0;
        const indent: usize = 4;
        while (i < arms) : (i += 1) {
            try g.line(indent, "else if n < {d} then", .{(i + 1) * 10});
            try g.line(indent + 4, "\"{s}\"", .{g.pick([]const u8, &words)});
        }
        try g.line(indent, "else", .{});
        if (g.chance(40)) {
            try g.line(indent + 4, "\"big: ${{n}}\"", .{});
        } else {
            try g.line(indent + 4, "String.fromInt n ++ \" is big\"", .{});
        }
    }

    fn recordFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "rename");
        try g.line(0, "{s} : String -> Model{d} -> Model{d}", .{ name, g.index, g.index });
        try g.line(0, "{s} label model =", .{name});
        _ = g.push("label");
        _ = g.push("model");
        if (g.chance(50)) {
            try g.line(4, "{{ model | name = label, count = model.count + {d} }}", .{g.rng.uintLessThan(u32, 5)});
        } else {
            try g.line(4, "{{ model", .{});
            try g.line(8, "| name = String.toUpper label", .{});
            try g.line(8, ", items = List.map .count [ model ]", .{});
            try g.line(4, "}}", .{});
        }
    }

    fn tupleFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "split");
        try g.line(0, "{s} : ( Int, String ) -> ( String, Int )", .{name});
        try g.line(0, "{s} pair =", .{name});
        _ = g.push("pair");
        if (g.chance(50)) {
            try g.line(4, "( pair.1, pair.0 * {d} )", .{1 + g.rng.uintLessThan(u32, 4)});
        } else {
            try g.line(4, "case pair of", .{});
            try g.line(8, "( count, label ) ->", .{});
            try g.line(12, "( label ++ \"!\", count )", .{});
        }
    }

    fn stringFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "greet");
        try g.line(0, "{s} : String -> Int -> String", .{name});
        try g.line(0, "{s} who times =", .{name});
        _ = g.push("who");
        _ = g.push("times");
        switch (g.rng.uintLessThan(u8, 3)) {
            0 => try g.line(4, "\"Hello, ${{who}}! You have ${{times}} new items.\\n\"", .{}),
            1 => try g.line(4, "\"\\\"${{who}}\\\" said: \" ++ String.repeat times \"$\"", .{}),
            else => try g.line(4, "String.fromChar '{c}' ++ who ++ \"\\t\" ++ String.fromInt times", .{g.pick(u8, "abcxyz")}),
        }
    }

    fn multilineFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "banner");
        try g.line(0, "{s} : String", .{name});
        try g.line(0, "{s} =", .{name});
        try g.line(4, "\\\\{s} report", .{g.pick([]const u8, &words)});
        try g.line(4, "\\\\==============", .{});
        if (g.chance(50)) try g.line(4, "\\\\SELECT * FROM {s} WHERE id = ${{id}}", .{g.pick([]const u8, &words)});
    }

    fn questionFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "parseTwice");
        try g.line(0, "{s} : String -> Result String Int", .{name});
        try g.line(0, "{s} s =", .{name});
        _ = g.push("s");
        try g.line(4, "Ok (parseOne{d}_{d} s? * 2)", .{ g.index, n });
        try g.declGap();
        try g.line(0, "parseOne{d}_{d} : String -> Result String Int", .{ g.index, n });
        try g.line(0, "parseOne{d}_{d} s =", .{ g.index, n });
        try g.line(4, "case String.toInt s of", .{});
        try g.line(8, "Just value ->", .{});
        try g.line(12, "Ok value", .{});
        try g.blank();
        try g.line(8, "Nothing ->", .{});
        try g.line(12, "Err \"not a number: ${{s}}\"", .{});
    }

    fn bigCaseFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "describe");
        try g.line(0, "{s} : Int -> String", .{name});
        try g.line(0, "{s} code =", .{name});
        _ = g.push("code");
        try g.line(4, "case code of", .{});
        const arms = 8 + g.rng.uintLessThan(u32, 40);
        var i: u32 = 0;
        while (i < arms) : (i += 1) {
            if (i != 0) try g.blank();
            if (i == 0) {
                try g.line(8, "-1 ->", .{});
            } else if (g.chance(20)) {
                // The same VALUE as the decimal arm would have been, spelled
                // in hex: the point is to exercise the lexer's hex path, and
                // `i * 16` made arm 1 (`0x10`) and arm 16 collide, which is
                // a `redundant_pattern` in generated code — a generator bug
                // (checker.md §9).
                try g.line(8, "0x{X} ->", .{i});
            } else {
                try g.line(8, "{d} ->", .{i});
            }
            if (g.chance(15)) {
                // A nested construct inside the branch: layout rule 2.
                try g.line(12, "let", .{});
                const mark = g.scopeMark();
                const local = g.bind();
                try g.line(16, "{s} =", .{local});
                try g.line(20, "code * {d}", .{i + 1});
                try g.line(12, "in", .{});
                try g.line(12, "\"{s} ${{{s}}}\"", .{ g.pick([]const u8, &words), local });
                g.scopeReset(mark);
            } else {
                try g.line(12, "\"{s} {s}\"", .{ g.pick([]const u8, &words), g.pick([]const u8, &words) });
            }
        }
        try g.blank();
        try g.line(8, "_ ->", .{});
        try g.line(12, "\"unknown\"", .{});
    }

    // ---- single-line expressions ---------------------------------------

    /// Write one expression on the current line. Nested binary operands
    /// are always parenthesised, so no chain is ambiguous or
    /// non-associative.
    fn expr(g: *Module, depth: u32) Io.Writer.Error!void {
        if (depth == 0) return g.atom();
        switch (g.rng.uintLessThan(u8, 9)) {
            0, 1 => {
                // Arithmetic only: a comparison or a logical operator would
                // produce a `Bool` where the caller wants an `Int`.
                try g.operand(depth - 1);
                try g.w.print(" {s} ", .{g.pick([]const u8, &.{ "+", "-", "*", "//", "^" })});
                try g.operand(depth - 1);
            },
            2 => {
                try g.w.print("helper{d} ", .{g.index});
                try g.atom();
            },
            3 => {
                // Saturated, always: a partial application here is the
                // TOO FEW ARGS the checker is right to complain about.
                const call = g.pick(PreludeCall, &prelude_calls);
                try g.w.print("{s} ", .{call.prefix});
                try g.atom();
                if (call.arity == 2) {
                    try g.w.writeByte(' ');
                    try g.atom();
                }
            },
            4 => {
                // Lambda applied through a prelude function.
                const mark = g.scopeMark();
                const param = g.bind();
                try g.w.print("List.foldl (\\{s} carry -> carry + {s}) 0 [ ", .{ param, param });
                g.scopeReset(mark);
                try g.atom();
                try g.w.writeAll(" ]");
            },
            5 => {
                try g.w.writeAll("Maybe.withDefault ");
                try g.atom();
                try g.w.writeAll(" (Just ");
                try g.atom();
                try g.w.writeByte(')');
            },
            6 => try g.crossModuleCall(),
            7 => {
                try g.w.writeAll("negate ");
                try g.operand(depth - 1);
            },
            else => {
                // The condition is a comparison, so it really is a `Bool`.
                try g.w.writeAll("if ");
                try g.operand(depth - 1);
                try g.w.print(" {s} ", .{g.pick([]const u8, &.{ "==", "/=", "<", ">", "<=", ">=" })});
                try g.operand(depth - 1);
                try g.w.writeAll(" then ");
                try g.atom();
                try g.w.writeAll(" else ");
                try g.atom();
            },
        }
    }

    /// An operand of a binary operator: an atom, or a parenthesised
    /// sub-expression.
    fn operand(g: *Module, depth: u32) Io.Writer.Error!void {
        if (depth == 0 or g.chance(50)) return g.atom();
        try g.w.writeByte('(');
        try g.expr(depth);
        try g.w.writeByte(')');
    }

    fn crossModuleCall(g: *Module) Io.Writer.Error!void {
        if (g.exposed_count > 0 and g.chance(50)) {
            const k = g.exposed[g.rng.uintLessThan(usize, g.exposed_count)];
            try g.w.print("helper{d} ", .{k});
            return g.atom();
        }
        if (g.aliased_count > 0) {
            const k = g.aliased[g.rng.uintLessThan(usize, g.aliased_count)];
            try g.w.print("P{d}.helper{d} ", .{ k, k });
            return g.atom();
        }
        try g.w.print("helper{d} ", .{g.index});
        return g.atom();
    }

    /// An `Int`-typed atom. Every local in scope is one — the generator
    /// only ever binds `Int`s — so the whole expression language is closed
    /// under `Int`, which is what makes the corpus type-correct without a
    /// type checker inside the generator.
    fn atom(g: *Module) Io.Writer.Error!void {
        switch (g.rng.uintLessThan(u8, 8)) {
            0, 1, 2 => if (g.anyLocal()) |l| try g.w.writeAll(l) else try g.w.print("{d}", .{g.rng.uintLessThan(u32, 100)}),
            3, 4 => try g.w.print("{d}", .{g.rng.uintLessThan(u32, 1000)}),
            5 => try g.w.print("0x{X}", .{g.rng.uintLessThan(u32, 4096)}),
            6 => try g.w.print("( {d}, \"{s}\" ).0", .{ g.rng.uintLessThan(u32, 9), g.pick([]const u8, &words) }),
            else => try g.w.print("init{d}.count", .{g.index}),
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the same seed and index produce identical bytes; different seeds differ" {
    var a: Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    var c: Io.Writer.Allocating = .init(testing.allocator);
    defer c.deinit();

    const lines_a = try writeModule(&a.writer, default_seed, 7);
    const lines_b = try writeModule(&b.writer, default_seed, 7);
    _ = try writeModule(&c.writer, default_seed + 1, 7);
    try testing.expectEqualStrings(a.written(), b.written());
    try testing.expectEqual(lines_a, lines_b);
    try testing.expect(!std.mem.eql(u8, a.written(), c.written()));
    try testing.expectEqual(lines_a, std.mem.count(u8, a.written(), "\n"));
}

test "generated modules respect the lexical rules the lexer enforces" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (0..40) |i| {
        out.clearRetainingCapacity();
        _ = try writeModule(&out.writer, default_seed, @intCast(i));
        const text = out.written();
        // No tabs, no CR, LF-terminated, no trailing whitespace on any line,
        // declarations at column 1 and continuations indented.
        try testing.expect(std.mem.indexOfScalar(u8, text, '\t') == null);
        try testing.expect(std.mem.indexOfScalar(u8, text, '\r') == null);
        try testing.expect(text[text.len - 1] == '\n');
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            try testing.expect(l.len == 0 or l[l.len - 1] != ' ');
        }
        try testing.expect(std.mem.startsWith(u8, text, "--! "));
        try testing.expect(std.mem.indexOf(u8, text, "\nimport ") != null);
        try testing.expect(std.mem.indexOf(u8, text, "\npub type alias Model") != null);
    }
}

test "no parameter inside a let block shadows one of the block's bindings" {
    // The generator's output must be free of `shadowing` (language.md §7.3),
    // and this is the one shape that ever slipped through: a `let` group is
    // mutually recursive, so a lambda parameter chosen while writing the
    // FIRST binding's value is in scope of the LAST binding's name too.
    // `beni check .zig-cache/bench-gen` is the end-to-end statement of the
    // same claim; this test makes it fail here, in milliseconds.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var blocks: usize = 0;
    for (0..120) |i| {
        out.clearRetainingCapacity();
        _ = try writeModule(&out.writer, default_seed, @intCast(i));
        blocks += try checkLetBlocks(out.written());
    }
    // `let` is one of ten random declaration kinds, so assert the scan
    // actually found blocks: a test that passes by finding nothing is not
    // a test.
    try testing.expect(blocks > 40);
}

/// Scan every top-level `let` block in `text` (the ones `letFn` writes, at
/// indent 4 with bindings at indent 8) and fail if any name bound inside it
/// — a lambda parameter, a let-bound function's parameter — repeats one of
/// the block's binding names, or if two bindings share a name. Returns the
/// number of blocks scanned.
fn checkLetBlocks(text: []const u8) !usize {
    var blocks: usize = 0;
    var binding_buf: [8][]const u8 = undefined;
    var bindings: []const []const u8 = binding_buf[0..0];
    var param_buf: [64][]const u8 = undefined;
    var params: []const []const u8 = param_buf[0..0];
    var in_block = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // A line at column 1 starts the next declaration and ends the block.
        if (in_block and line.len != 0 and line[0] != ' ') {
            try expectNoShadowing(bindings, params);
            in_block = false;
        }
        if (std.mem.eql(u8, line, "    let")) {
            in_block = true;
            blocks += 1;
            bindings = binding_buf[0..0];
            params = param_buf[0..0];
            continue;
        }
        if (!in_block) continue;

        if (std.mem.startsWith(u8, line, "        ") and line.len > 8 and line[8] != ' ') {
            const body = line[8..];
            if (std.mem.startsWith(u8, body, "twice ")) {
                bindings = try append(&binding_buf, bindings, "twice");
                params = try append(&param_buf, params, identAt(body["twice ".len..]));
            } else {
                const bound = identAt(body);
                const after = body[bound.len..];
                // ` = ` only: `name : Int` is the annotation of the
                // binding on the next line, not a second binding.
                if (bound.len != 0 and std.mem.startsWith(u8, after, " =")) {
                    bindings = try append(&binding_buf, bindings, bound);
                }
            }
        }
        var rest = line;
        while (std.mem.indexOf(u8, rest, "(\\")) |at| {
            rest = rest[at + 2 ..];
            params = try append(&param_buf, params, identAt(rest));
        }
    }
    if (in_block) try expectNoShadowing(bindings, params);
    return blocks;
}

/// `list` with `name` appended, in `buf`. The buffers are sized for the
/// shapes `letFn` writes; overflowing one means the generator grew a case
/// this scan no longer covers, which is a failure, not a silent truncation.
fn append(buf: [][]const u8, list: []const []const u8, name: []const u8) ![]const []const u8 {
    if (list.len == buf.len) return error.ScanBufferTooSmall;
    buf[list.len] = name;
    return buf[0 .. list.len + 1];
}

fn expectNoShadowing(bindings: []const []const u8, params: []const []const u8) !void {
    for (bindings, 0..) |b, i| {
        for (bindings[i + 1 ..]) |other| if (std.mem.eql(u8, b, other)) {
            std.debug.print("let block binds `{s}` twice\n", .{b});
            return error.DuplicateBinding;
        };
        for (params) |p| if (std.mem.eql(u8, b, p)) {
            std.debug.print("parameter `{s}` shadows a sibling let binding\n", .{p});
            return error.ParameterShadowsBinding;
        };
    }
}

/// The identifier at the start of `s`, empty when there is none.
fn identAt(s: []const u8) []const u8 {
    var n: usize = 0;
    while (n < s.len and (std.ascii.isAlphanumeric(s[n]) or s[n] == '_')) n += 1;
    return s[0..n];
}

test "every pathological case is one line, the size it claims, and named by a valid module path" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    inline for (@typeInfo(Pathological).@"enum".fields) |field| {
        const which: Pathological = @enumFromInt(field.value);
        out.clearRetainingCapacity();
        try writePathological(&out.writer, which);
        const text = out.written();
        // The point of every one of these is that the payload is on ONE
        // line: a file with a million short lines is a different stress.
        try testing.expect(std.mem.count(u8, text, "\n") <= 2);
        try testing.expect(text[text.len - 1] == '\n');
        try testing.expect(text.len > 500_000);
        // `Pathological.parse` round-trips the name the flag takes.
        try testing.expectEqual(@as(?Pathological, which), Pathological.parse(field.name));
        // Every path segment is an upper identifier (language.md §1), so
        // the file has a module name and `beni check` on it does not
        // report `invalid_module_path` instead of what it is here for.
        var segments = std.mem.splitScalar(u8, which.path(), '/');
        while (segments.next()) |segment| {
            const stem = if (std.mem.endsWith(u8, segment, ".beni")) segment[0 .. segment.len - ".beni".len] else segment;
            try testing.expect(stem.len != 0 and std.ascii.isUpper(stem[0]));
        }
    }
    try testing.expectEqual(@as(?Pathological, null), Pathological.parse("no-such-case"));
}

test "module paths are valid upper-identifier segments" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Gen/Page0.beni", modulePath(&buf, 0));
    try testing.expectEqualStrings("Gen/Data/Store1.beni", modulePath(&buf, 1));
    try testing.expectEqualStrings("Gen/Ui/Widget2.beni", modulePath(&buf, 2));
    try testing.expectEqualStrings("Gen.Ui.Widget14", moduleName(&buf, 14));
}
