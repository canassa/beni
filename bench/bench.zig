//! Throughput harness, `zig build bench` (docs/design/frontend.md §5,
//! fast-compiler.md §12).
//!
//! Runs each front-end phase over every file of a corpus, `iterations`
//! times after a warm-up, and prints one JSON line per phase plus a `total`:
//!
//! ```
//! {"phase":"read","files":312,"bytes":4194304,"tokens":0,"nodes":0,"insts":0,"ms":41.2,"mb_per_s":101.8,"loc_per_s":2431000}
//! ```
//!
//! Options: `--corpus=<dir>` (default `bench/corpus`), `--generate=<lines>`
//! (write a synthetic project of that size under `.zig-cache/bench-gen` and
//! measure that instead), `--iterations=<n>` (default 5), `--seed=<n>`.
//!
//! Phases so far: `read` (bytes through `SourceStore`), `lex` (the
//! tokenizer, interning included, into fresh per-file output lists — the
//! production shape), `parse` (the parser over pre-lexed tokens, nodes
//! and extra to a fresh gpa-owned tree per file, scratch from one arena
//! reset between files, as a worker does) and `lower` (Ast → Bir over
//! pre-parsed trees, same memory shape, `insts` counted). The phases are
//! timed single-threaded and serially so the figure is per-core
//! throughput, which is what the §2 budget is stated in. `lines` is the
//! newline count, `tokens` includes each file's `eof`; `nodes` and `insts`
//! are the parse and lower outputs.

const std = @import("std");
const Io = std.Io;
const beni = @import("beni");
const gen = @import("gen.zig");
const SourceStore = beni.SourceStore;
const Tokenizer = beni.Tokenizer;
const InternPool = beni.InternPool;
const Parse = beni.Parse;
const Lower = beni.Lower;
const Ast = beni.Ast;
const Arena = beni.Arena;
const Session = beni.Session;

const Options = struct {
    corpus: []const u8 = "bench/corpus",
    generate: ?u64 = null,
    /// `--pathological=<name>`: measure one of the abuse inputs too big to
    /// check in (`gen.Pathological`) instead of a corpus.
    pathological: ?gen.Pathological = null,
    iterations: u32 = 5,
    seed: u64 = gen.default_seed,
};

const generated_dir = ".zig-cache/bench-gen";
const pathological_dir = ".zig-cache/bench-pathological";

/// Files under a directory with this name get a line of their own (§12:
/// "every real slow file ever encountered gets frozen into the benchmark
/// set forever" — a per-file line is what makes one of them visible when
/// the aggregate is dominated by hundreds of ordinary modules).
const pathological_marker = "bench/pathological/";

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
        try stderr.print("bench: bad arguments ({t}); usage: bench [--corpus=<dir>] [--generate=<lines>] [--pathological=<name>] [--iterations=<n>] [--seed=<n>]\n", .{err});
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
    if (options.pathological) |which| {
        Io.Dir.cwd().deleteTree(io, pathological_dir) catch {};
        const stats = try gen.generatePathological(gpa, io, pathological_dir, which);
        try stderr.print("bench: generated {s} ({d} bytes) under {s}\n", .{ @tagName(which), stats.bytes, pathological_dir });
        corpus = pathological_dir;
    }

    // Enumerate once; every phase runs over the same numbered files.
    var store: SourceStore = .{};
    defer store.deinit(gpa);
    store.addPath(gpa, io, corpus, null, .app) catch |err| {
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
    const lowered = try measureLower(gpa, io, &store, options.iterations);
    try printLine(stdout, "lower", lowered);
    total.add(lowered);
    const resolved = try measureResolve(gpa, io, corpus, options.iterations);
    try printResolveLine(stdout, resolved);
    total.ns += resolved.ns;
    const checked = try measureCheck(gpa, io, corpus, options.iterations, resolved.total_ns, total.lines);
    try printCheckLine(stdout, checked);
    total.ns += checked.ns;
    try printLine(stdout, "total", total);

    // One line per pathological file, so a single slow file cannot hide in
    // a corpus average. `--pathological=<name>` measures one file and gets
    // a per-file line for it too, because the whole corpus IS that file.
    for (0..store.count()) |i| {
        const file: SourceStore.Index = @enumFromInt(i);
        const p = store.path(file);
        if (std.mem.indexOf(u8, p, pathological_marker) == null and options.pathological == null) continue;
        try printFileLine(gpa, io, stdout, &store, file, options.iterations);
    }
    return 0;
}

/// Every phase over one file, best of `iterations` after a warm-up, as one
/// JSON line. Allocation shape follows the per-phase measurements: fresh
/// outputs per iteration, scratch from an arena reset between them.
fn printFileLine(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, store: *SourceStore, file: SourceStore.Index, iterations: u32) !void {
    var arena: Arena = .init(std.heap.page_allocator);
    defer arena.deinit();
    var best: [4]u64 = @splat(std.math.maxInt(u64));
    var m: Measurement = .{ .files = 1 };
    var iteration: u32 = 0;
    while (iteration < iterations + 1) : (iteration += 1) {
        var interner = try InternPool.Local.init(gpa);
        defer interner.deinit(gpa);

        var t = Io.Timestamp.now(io, .awake);
        try store.read(gpa, io, file);
        const text = store.bytes(file);
        var ns: [4]u64 = undefined;
        ns[0] = elapsed(io, &t);

        var out: Tokenizer.Output = .empty;
        defer out.deinit(gpa);
        try Tokenizer.tokenize(gpa, text, &interner, &out);
        ns[1] = elapsed(io, &t);

        var tree = try Parse.parse(gpa, arena.allocator(), text, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
        defer tree.deinit(gpa);
        ns[2] = elapsed(io, &t);

        var bir = try Lower.lower(gpa, arena.allocator(), text, out.tokens.slice(), &tree, &interner, .{
            .core = false,
            .module_name = store.moduleName(file),
        });
        defer bir.deinit(gpa);
        ns[3] = elapsed(io, &t);
        arena.reset(.retain_capacity);

        m.bytes = text.len;
        m.lines = out.line_starts.items.len - 1;
        m.tokens = out.tokens.len;
        m.nodes = tree.nodes.len;
        m.insts = bir.insts.len;
        if (iteration == 0) continue; // warm-up
        for (&best, ns) |*b, n| b.* = @min(b.*, n);
    }
    var total: u64 = 0;
    for (best) |b| total += b;
    try writer.print(
        "{{\"file\":\"{s}\",\"bytes\":{d},\"lines\":{d},\"tokens\":{d},\"nodes\":{d},\"insts\":{d}," ++
            "\"read_ms\":{d:.2},\"lex_ms\":{d:.2},\"parse_ms\":{d:.2},\"lower_ms\":{d:.2},\"ms\":{d:.2}}}\n",
        .{
            store.path(file),      m.bytes,               m.lines,
            m.tokens,              m.nodes,               m.insts,
            milliseconds(best[0]), milliseconds(best[1]), milliseconds(best[2]),
            milliseconds(best[3]), milliseconds(total),
        },
    );
}

fn elapsed(io: Io, t: *Io.Timestamp) u64 {
    const now = Io.Timestamp.now(io, .awake);
    const ns: u64 = @intCast(t.durationTo(now).nanoseconds);
    t.* = now;
    return ns;
}

fn milliseconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn parseArgs(args: []const [:0]const u8) !Options {
    var options: Options = .{};
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--corpus=")) {
            options.corpus = arg["--corpus=".len..];
        } else if (std.mem.startsWith(u8, arg, "--generate=")) {
            options.generate = try std.fmt.parseInt(u64, arg["--generate=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--pathological=")) {
            options.pathological = gen.Pathological.parse(arg["--pathological=".len..]) orelse return error.UnknownPathologicalCase;
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
    insts: u64 = 0,
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
        total.insts = @max(total.insts, m.insts);
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

/// Lower every file from trees parsed once outside the timed region (the
/// parser has its own line). The interner is the one that lexed the
/// tokens, made by `Local.init` as a worker's is; lowering adds the name
/// parts of qualified references to it on the first iteration only, which
/// is why the warm-up is not counted. The Bir goes to `gpa` like production.
fn measureLower(gpa: std.mem.Allocator, io: Io, store: *SourceStore, iterations: u32) !Measurement {
    var interner = try InternPool.Local.init(gpa);
    defer interner.deinit(gpa);
    const outputs = try gpa.alloc(Tokenizer.Output, store.count());
    defer gpa.free(outputs);
    const trees = try gpa.alloc(Ast, store.count());
    defer gpa.free(trees);
    var lexed: usize = 0;
    defer for (outputs[0..lexed]) |*out| out.deinit(gpa);
    var parsed: usize = 0;
    defer for (trees[0..parsed]) |*tree| tree.deinit(gpa);
    var arena: Arena = .init(std.heap.page_allocator);
    defer arena.deinit();
    for (outputs, trees, 0..) |*out, *tree, i| {
        const text = store.bytes(@enumFromInt(i));
        out.* = .empty;
        try Tokenizer.tokenize(gpa, text, &interner, out);
        lexed += 1;
        tree.* = try Parse.parse(gpa, arena.allocator(), text, out.tokens.slice(), out.comments.items, out.line_starts.items, out.diagnostics.items());
        parsed += 1;
        arena.reset(.retain_capacity);
    }

    var best: u64 = std.math.maxInt(u64);
    var m: Measurement = .{ .files = store.count() };
    var iteration: u32 = 0;
    while (iteration < iterations + 1) : (iteration += 1) {
        var bytes: u64 = 0;
        var lines: u64 = 0;
        var tokens: u64 = 0;
        var nodes: u64 = 0;
        var insts: u64 = 0;
        const start = Io.Timestamp.now(io, .awake);
        for (outputs, trees, 0..) |*out, *tree, i| {
            const file: SourceStore.Index = @enumFromInt(i);
            const text = store.bytes(file);
            var bir = try Lower.lower(gpa, arena.allocator(), text, out.tokens.slice(), tree, &interner, .{
                .core = false,
                .module_name = store.moduleName(file),
            });
            defer bir.deinit(gpa);
            arena.reset(.retain_capacity);
            bytes += text.len;
            lines += out.line_starts.items.len - 1;
            tokens += out.tokens.len;
            nodes += tree.nodes.len;
            insts += bir.insts.len;
        }
        const ns: u64 = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        if (iteration == 0) continue; // warm-up
        best = @min(best, ns);
        m.bytes = bytes;
        m.lines = lines;
        m.tokens = tokens;
        m.nodes = nodes;
        m.insts = insts;
    }
    m.ns = best;
    return m;
}

/// The serial half of `check` (checker.md §4): the module graph and
/// cross-module resolution, over a project that has ALREADY been lowered.
/// Measured through a whole `Session` rather than by calling `Graph.build`
/// directly, because what M2a has to keep honest is the cost `check` pays
/// — including the core package, which every run now carries.
const ResolveMeasurement = struct {
    modules: u64 = 0,
    edges: u64 = 0,
    interfaces: u64 = 0,
    /// The graph + resolve steps alone.
    ns: u64 = 0,
    /// The whole cold run, for the share the two steps are.
    total_ns: u64 = 0,
};

fn measureResolve(gpa: std.mem.Allocator, io: Io, corpus: []const u8, iterations: u32) !ResolveMeasurement {
    // The two steps are not reachable on their own from outside `Session`
    // — they run after the join, on the session's own state — so they are
    // measured as a DIFFERENCE: a cold run that stops after lowering, and
    // a cold run that goes on to resolve. Both include the core package,
    // because every `check` does.
    const lower_ns = try coldRun(gpa, io, corpus, iterations, Session.lower_phases, null);
    var m: ResolveMeasurement = .{};
    m.total_ns = try coldRun(gpa, io, corpus, iterations, Session.resolve_phases, &m);
    m.ns = m.total_ns -| lower_ns;
    return m;
}

/// One cold `check` over `corpus`, best of `iterations` after a warm-up.
/// Fills `counts` from the last session when asked.
fn coldRun(gpa: std.mem.Allocator, io: Io, corpus: []const u8, iterations: u32, phases: Session.Phases, counts: ?*ResolveMeasurement) !u64 {
    var sink: Io.Writer.Discarding = .init(&.{});
    var best: u64 = std.math.maxInt(u64);
    var iteration: u32 = 0;
    while (iteration < iterations + 1) : (iteration += 1) {
        var session = try Session.init(gpa, io, .{ .jobs = 1, .diagnostics = .json, .core_package = true });
        defer session.deinit();
        const start = Io.Timestamp.now(io, .awake);
        _ = session.run(&.{corpus}, phases, &sink.writer) catch continue;
        const ns: u64 = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        if (iteration == 0) continue; // warm-up
        best = @min(best, ns);
        if (counts) |c| {
            c.modules = session.graph.count();
            c.edges = session.graph.edgeCount();
            c.interfaces = session.resolution.interfaces.len;
        }
    }
    return if (best == std.math.maxInt(u64)) 0 else best;
}

/// Type checking alone (checker.md §9): constrain → solve → generalise over
/// a project that has already been lowered and resolved. Measured as a
/// DIFFERENCE, like `resolve`, because the step runs inside `Session` after
/// the join and is not reachable on its own — a cold run through
/// `resolve_phases` against a cold run through `check_phases`. Both include
/// core, because every `check` does.
///
/// `loc_per_s` is the figure §2's "> 250k LOC/s cold per core for checking
/// alone" is stated in, and it counts the CORPUS's lines, not core's: core
/// is a fixed 2,776-line cost every project pays once, and folding it into
/// the rate would flatter a big corpus and punish a small one.
const CheckMeasurement = struct {
    modules: u64 = 0,
    lines: u64 = 0,
    unifications: u64 = 0,
    generalisations: u64 = 0,
    instantiations: u64 = 0,
    obligations: u64 = 0,
    diagnostics: u64 = 0,
    /// The check step alone.
    ns: u64 = 0,
    /// The whole cold `check`, core included.
    total_ns: u64 = 0,
};

fn measureCheck(gpa: std.mem.Allocator, io: Io, corpus: []const u8, iterations: u32, resolve_total_ns: u64, lines: u64) !CheckMeasurement {
    var m: CheckMeasurement = .{ .lines = lines };
    m.total_ns = try coldCheck(gpa, io, corpus, iterations, &m);
    m.ns = m.total_ns -| resolve_total_ns;
    return m;
}

fn coldCheck(gpa: std.mem.Allocator, io: Io, corpus: []const u8, iterations: u32, counts: *CheckMeasurement) !u64 {
    var sink: Io.Writer.Discarding = .init(&.{});
    var best: u64 = std.math.maxInt(u64);
    var iteration: u32 = 0;
    while (iteration < iterations + 1) : (iteration += 1) {
        var session = try Session.init(gpa, io, .{ .jobs = 1, .diagnostics = .json, .core_package = true });
        defer session.deinit();
        const start = Io.Timestamp.now(io, .awake);
        _ = session.run(&.{corpus}, Session.check_phases, &sink.writer) catch continue;
        const ns: u64 = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        if (iteration == 0) continue; // warm-up
        best = @min(best, ns);
        counts.modules = session.graph.count();
        counts.unifications = session.checked.counters.unifications;
        counts.generalisations = session.checked.counters.generalisations;
        counts.instantiations = session.checked.counters.instantiations;
        counts.obligations = session.checked.counters.obligations;
        counts.diagnostics = session.diagnostics.items.len;
    }
    return if (best == std.math.maxInt(u64)) 0 else best;
}

fn printCheckLine(writer: *Io.Writer, m: CheckMeasurement) !void {
    const seconds = @as(f64, @floatFromInt(@max(m.ns, 1))) / 1e9;
    const loc_per_s: u64 = @intFromFloat(@as(f64, @floatFromInt(m.lines)) / seconds);
    try writer.print(
        "{{\"phase\":\"check\",\"modules\":{d},\"lines\":{d},\"unifications\":{d},\"generalisations\":{d}," ++
            "\"instantiations\":{d},\"obligations\":{d},\"diagnostics\":{d},\"ms\":{d:.2}," ++
            "\"loc_per_s\":{d},\"cold_check_ms\":{d:.1}}}\n",
        .{
            m.modules,        m.lines,                  m.unifications, m.generalisations,
            m.instantiations, m.obligations,            m.diagnostics,  milliseconds(m.ns),
            loc_per_s,        milliseconds(m.total_ns),
        },
    );
}

fn printResolveLine(writer: *Io.Writer, m: ResolveMeasurement) !void {
    const ms = @as(f64, @floatFromInt(m.ns)) / 1e6;
    const cold_ms = @as(f64, @floatFromInt(m.total_ns)) / 1e6;
    try writer.print(
        "{{\"phase\":\"resolve\",\"modules\":{d},\"edges\":{d},\"interfaces\":{d},\"ms\":{d:.2},\"cold_check_ms\":{d:.1}}}\n",
        .{ m.modules, m.edges, m.interfaces, ms, cold_ms },
    );
}

fn printLine(writer: *Io.Writer, phase: []const u8, m: Measurement) !void {
    const ms = @as(f64, @floatFromInt(m.ns)) / 1e6;
    const seconds = @as(f64, @floatFromInt(@max(m.ns, 1))) / 1e9;
    const mb_per_s = @as(f64, @floatFromInt(m.bytes)) / (1024 * 1024) / seconds;
    const loc_per_s: u64 = @intFromFloat(@as(f64, @floatFromInt(m.lines)) / seconds);
    try writer.print(
        "{{\"phase\":\"{s}\",\"files\":{d},\"bytes\":{d},\"tokens\":{d},\"nodes\":{d},\"insts\":{d},\"ms\":{d:.1},\"mb_per_s\":{d:.1},\"loc_per_s\":{d}}}\n",
        .{ phase, m.files, m.bytes, m.tokens, m.nodes, m.insts, ms, mb_per_s, loc_per_s },
    );
}
