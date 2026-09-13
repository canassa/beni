//! Throughput harness, `zig build bench` (docs/design/frontend.md §5,
//! fast-compiler.md §12).
//!
//! Runs each front-end phase over every file of a corpus, `iterations`
//! times after a warm-up, and prints one JSON line per phase plus a `total`:
//!
//! ```
//! {"phase":"read","files":312,"bytes":4194304,"tokens":0,"nodes":0,"ms":41.2,"mb_per_s":101.8,"loc_per_s":2431000}
//! ```
//!
//! Options: `--corpus=<dir>` (default `bench/corpus`), `--generate=<lines>`
//! (write a synthetic project of that size under `.zig-cache/bench-gen` and
//! measure that instead), `--iterations=<n>` (default 5), `--seed=<n>`.
//!
//! Phases so far: `read` (bytes through `SourceStore`), `lex` (the
//! tokenizer, interning included, into fresh per-file output lists — the
//! production shape) and `parse` (the parser over pre-lexed tokens, nodes
//! and extra to a fresh gpa-owned tree per file, scratch from one arena
//! reset between files, as a worker does). The phases are timed
//! single-threaded and serially so the figure is per-core throughput, which
//! is what the §2 budget is stated in. `lines` is the newline count,
//! `tokens` includes each file's `eof`; the `parse` line reports the node
//! count in the `tokens` field's neighbour, `nodes`.

const std = @import("std");
const Io = std.Io;
const beni = @import("beni");
const gen = @import("gen.zig");
const SourceStore = beni.SourceStore;
const Tokenizer = beni.Tokenizer;
const InternPool = beni.InternPool;
const Parse = beni.Parse;
const Arena = beni.Arena;

const Options = struct {
    corpus: []const u8 = "bench/corpus",
    generate: ?u64 = null,
    iterations: u32 = 5,
    seed: u64 = gen.default_seed,
};

const generated_dir = ".zig-cache/bench-gen";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};
    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const options = parseArgs(args[1..]) catch |err| {
        try stderr.print("bench: bad arguments ({t}); usage: bench [--corpus=<dir>] [--generate=<lines>] [--iterations=<n>] [--seed=<n>]\n", .{err});
        return 2;
    };

    var corpus = options.corpus;
    if (options.generate) |lines| {
        // Regenerated every run: it is cheap, it is deterministic, and it
        // keeps the generated tree out of the repository.
        Io.Dir.cwd().deleteTree(io, generated_dir) catch {};
        const stats = try gen.generate(gpa, io, generated_dir, options.seed, lines);
        try stderr.print("bench: generated {d} files, {d} lines, {d} bytes under {s}\n", .{ stats.files, stats.lines, stats.bytes, generated_dir });
        corpus = generated_dir;
    }

    // Enumerate once; every phase runs over the same numbered files.
    var store: SourceStore = .{};
    defer store.deinit(gpa);
    store.addPath(gpa, io, corpus, null) catch |err| {
        try stderr.print("bench: cannot read corpus '{s}': {t}\n", .{ corpus, err });
        return 2;
    };
    try store.finish(gpa);
    if (store.count() == 0) {
        try stderr.print("bench: corpus '{s}' has no .beni files\n", .{corpus});
        return 2;
    }

    var total: Measurement = .{};
    const read = try measureRead(gpa, io, &store, options.iterations);
    try printLine(stdout, "read", read);
    total.add(read);
    const lex = try measureLex(gpa, io, &store, options.iterations);
    try printLine(stdout, "lex", lex);
    total.add(lex);
    const parsed = try measureParse(gpa, io, &store, options.iterations);
    try printLine(stdout, "parse", parsed);
    total.add(parsed);
    try printLine(stdout, "total", total);
    return 0;
}

fn parseArgs(args: []const [:0]const u8) !Options {
    var options: Options = .{};
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--corpus=")) {
            options.corpus = arg["--corpus=".len..];
        } else if (std.mem.startsWith(u8, arg, "--generate=")) {
            options.generate = try std.fmt.parseInt(u64, arg["--generate=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--iterations=")) {
            options.iterations = try std.fmt.parseInt(u32, arg["--iterations=".len..], 10);
            if (options.iterations == 0) return error.ZeroIterations;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            options.seed = try std.fmt.parseInt(u64, arg["--seed=".len..], 0);
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}

const Measurement = struct {
    files: u64 = 0,
    bytes: u64 = 0,
    tokens: u64 = 0,
    nodes: u64 = 0,
    lines: u64 = 0,
    /// Wall time of one iteration over the whole corpus (the best of the
    /// timed iterations), in nanoseconds.
    ns: u64 = 0,

    fn add(total: *Measurement, m: Measurement) void {
        total.files = @max(total.files, m.files);
        total.bytes = @max(total.bytes, m.bytes);
        total.lines = @max(total.lines, m.lines);
        total.tokens = @max(total.tokens, m.tokens);
        total.nodes = @max(total.nodes, m.nodes);
        total.ns += m.ns;
    }
};

/// Read every file's bytes through the store. One warm-up iteration, then
/// the best of `iterations`. Leaves the bytes in the store for `measureLex`.
fn measureRead(gpa: std.mem.Allocator, io: Io, store: *SourceStore, iterations: u32) !Measurement {
    var best: u64 = std.math.maxInt(u64);
    var m: Measurement = .{ .files = store.count() };
    var iteration: u32 = 0;
    while (iteration < iterations + 1) : (iteration += 1) {
        var bytes: u64 = 0;
        var lines: u64 = 0;
        const start = Io.Timestamp.now(io, .awake);
        for (0..store.count()) |i| {
            const file: SourceStore.Index = @enumFromInt(i);
            try store.read(gpa, io, file);
            const text = store.bytes(file);
            bytes += text.len;
            lines += std.mem.count(u8, text, "\n");
        }
        const ns: u64 = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        if (iteration == 0) continue; // warm-up
        best = @min(best, ns);
        m.bytes = bytes;
        m.lines = lines;
    }
    m.ns = best;
    return m;
}

/// Tokenize every file (already read) into fresh output lists with a fresh
/// per-iteration interner, the way one worker would see a cold session.
/// Freeing the outputs is inside the timed region, which is conservative:
/// production keeps them.
fn measureLex(gpa: std.mem.Allocator, io: Io, store: *SourceStore, iterations: u32) !Measurement {
    var best: u64 = std.math.maxInt(u64);
    var m: Measurement = .{ .files = store.count() };
    var iteration: u32 = 0;
    while (iteration < iterations + 1) : (iteration += 1) {
        var interner: InternPool.Local = .empty;
        defer interner.deinit(gpa);
        var bytes: u64 = 0;
        var lines: u64 = 0;
        var tokens: u64 = 0;
        const start = Io.Timestamp.now(io, .awake);
        for (0..store.count()) |i| {
            const file: SourceStore.Index = @enumFromInt(i);
            const text = store.bytes(file);
            var out: Tokenizer.Output = .empty;
            defer out.deinit(gpa);
            try Tokenizer.tokenize(gpa, text, &interner, &out);
            bytes += text.len;
            lines += out.line_starts.items.len - 1;
            tokens += out.tokens.len;
        }
        const ns: u64 = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        if (iteration == 0) continue; // warm-up
        best = @min(best, ns);
        m.bytes = bytes;
        m.lines = lines;
        m.tokens = tokens;
    }
    m.ns = best;
    return m;
}

/// Parse every file from tokens lexed once outside the timed region (the
/// lexer has its own line). The tree goes to `gpa` like production; the
/// scratch arena is reset between files like a worker's.
fn measureParse(gpa: std.mem.Allocator, io: Io, store: *SourceStore, iterations: u32) !Measurement {
    var interner: InternPool.Local = .empty;
    defer interner.deinit(gpa);
    const outputs = try gpa.alloc(Tokenizer.Output, store.count());
    defer gpa.free(outputs);
    var lexed: usize = 0;
    defer for (outputs[0..lexed]) |*out| out.deinit(gpa);
    for (outputs, 0..) |*out, i| {
        out.* = .empty;
        try Tokenizer.tokenize(gpa, store.bytes(@enumFromInt(i)), &interner, out);
        lexed += 1;
    }

    var arena: Arena = .init(std.heap.page_allocator);
    defer arena.deinit();
    var best: u64 = std.math.maxInt(u64);
    var m: Measurement = .{ .files = store.count() };
    var iteration: u32 = 0;
    while (iteration < iterations + 1) : (iteration += 1) {
        var bytes: u64 = 0;
        var lines: u64 = 0;
        var tokens: u64 = 0;
        var nodes: u64 = 0;
        const start = Io.Timestamp.now(io, .awake);
        for (outputs, 0..) |*out, i| {
            const file: SourceStore.Index = @enumFromInt(i);
            const text = store.bytes(file);
            var tree = try Parse.parse(gpa, arena.allocator(), text, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
            defer tree.deinit(gpa);
            arena.reset(.retain_capacity);
            bytes += text.len;
            lines += out.line_starts.items.len - 1;
            tokens += out.tokens.len;
            nodes += tree.nodes.len;
        }
        const ns: u64 = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        if (iteration == 0) continue; // warm-up
        best = @min(best, ns);
        m.bytes = bytes;
        m.lines = lines;
        m.tokens = tokens;
        m.nodes = nodes;
    }
    m.ns = best;
    return m;
}

fn printLine(writer: *Io.Writer, phase: []const u8, m: Measurement) !void {
    const ms = @as(f64, @floatFromInt(m.ns)) / 1e6;
    const seconds = @as(f64, @floatFromInt(@max(m.ns, 1))) / 1e9;
    const mb_per_s = @as(f64, @floatFromInt(m.bytes)) / (1024 * 1024) / seconds;
    const loc_per_s: u64 = @intFromFloat(@as(f64, @floatFromInt(m.lines)) / seconds);
    try writer.print(
        "{{\"phase\":\"{s}\",\"files\":{d},\"bytes\":{d},\"tokens\":{d},\"nodes\":{d},\"ms\":{d:.1},\"mb_per_s\":{d:.1},\"loc_per_s\":{d}}}\n",
        .{ phase, m.files, m.bytes, m.tokens, m.nodes, ms, mb_per_s, loc_per_s },
    );
}
