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
//! measure that instead), `--wide=<declarations>` (the other generated
//! shape: ONE module of that many `pub` declarations under
//! `.zig-cache/bench-wide`, which is what makes anything quadratic in a
//! single module's declaration count visible — `--generate` spreads its
//! lines over hundreds of small files and holds those terms flat),
//! `--iterations=<n>` (default 5), `--seed=<n>`, `--dispatch` (write the
//! `--generate` corpus in the static-dispatch shape of
//! `docs/design/static-dispatch-spike.md` instead — the same modules, the same
//! declaration names, the same size, with method calls, `where` clauses,
//! `==` on records and custom types and comparator-free `Dict`/`Set`; it is
//! the C1 corpus of that plan's §7 and it does NOT parse until S2).
//!
//! `--pathological=constraint-chain=<n>` is the §7 M2 case: `n` unannotated
//! `pub` functions, each adding one method constraint to the scheme the one
//! before it inferred.
//!
//! `emit` is the back end's line (`backend.md` §13, target > 5 MB/s of
//! JavaScript): `Bir` → `JsIr` → bytes for every module of a project that
//! has already been checked, with `mb_per_s` measured over the JavaScript
//! PRODUCED rather than the beni consumed, because that is the number §2
//! states and the one an output-size budget is compared against.
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
const JsLower = beni.js.Lower;
const JsPrint = beni.js.Print;
const Bir = beni.Bir;
const Graph = beni.resolve.Graph;
const iface_bytes = beni.resolve.iface_bytes;
const Ast = beni.Ast;
const Arena = beni.Arena;
const Session = beni.Session;

const Options = struct {
    corpus: []const u8 = "bench/corpus",
    generate: ?u64 = null,
    /// `--pathological=<name>`: measure one of the abuse inputs too big to
    /// check in (`gen.Pathological`) instead of a corpus.
    pathological: ?gen.Pathological = null,
    /// `--wide=<declarations>`: measure `gen.generateWide` at that size
    /// instead of a corpus. Like `--generate`, it replaces the corpus, so
    /// passing both measures whichever is applied last.
    wide: ?u32 = null,
    /// `--dispatch`: write `--generate`'s corpus in the static-dispatch
    /// shape (`gen.Mode`). A tree of its own, so the two corpora of §7 can
    /// sit side by side and be measured interleaved.
    dispatch: bool = false,
    iterations: u32 = 5,
    seed: u64 = gen.default_seed,
};

const generated_dir = ".zig-cache/bench-gen";
const dispatch_dir = ".zig-cache/bench-gen-dispatch";
const pathological_dir = ".zig-cache/bench-pathological";
const wide_dir = ".zig-cache/bench-wide";

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
        try stderr.print("bench: bad arguments ({t}); usage: bench [--corpus=<dir>] [--generate=<lines>] [--dispatch] [--wide=<declarations>] [--pathological=<name>[=<n>]] [--iterations=<n>] [--seed=<n>]\n", .{err});
        return 2;
    };

    var corpus = options.corpus;
    if (options.generate) |lines| {
        // Regenerated every run: it is cheap, it is deterministic, and it
        // keeps the generated tree out of the repository.
        const mode: gen.Mode = if (options.dispatch) .dispatch else .plain;
        const dir = if (options.dispatch) dispatch_dir else generated_dir;
        Io.Dir.cwd().deleteTree(io, dir) catch {};
        const stats = try gen.generateMode(gpa, io, dir, options.seed, lines, mode);
        try stderr.print("bench: generated {d} files, {d} lines, {d} bytes ({t}) under {s}\n", .{ stats.files, stats.lines, stats.bytes, mode, dir });
        corpus = dir;
    }
    if (options.wide) |declarations| {
        // Regenerated every run, like `--generate`, and for the same
        // reasons: deterministic, and a 130k-line single module is not
        // something to carry in the repository.
        Io.Dir.cwd().deleteTree(io, wide_dir) catch {};
        const shape: gen.WideShape = .init(declarations);
        const stats = try gen.generateWide(gpa, io, wide_dir, options.seed, declarations);
        try stderr.print(
            "bench: generated {d} pub declarations ({d} simple, {d} chain links, {d} builders over {d} fields), {d} lines, {d} bytes under {s}\n",
            .{ shape.total(), shape.simple, shape.chain, 2 * shape.builders, shape.width, stats.lines, stats.bytes, wide_dir },
        );
        corpus = wide_dir;
    }
    if (options.pathological) |which| {
        Io.Dir.cwd().deleteTree(io, pathological_dir) catch {};
        const stats = try gen.generatePathological(gpa, io, pathological_dir, which);
        try stderr.print("bench: generated {t} n={d} ({d} bytes) under {s}\n", .{ which.case, which.n, stats.bytes, pathological_dir });
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
    const emitted = try measureEmit(gpa, io, corpus, options.iterations);
    try printEmitLine(stdout, emitted);
    total.ns += emitted.ns;
    try printLine(stdout, "total", total);

    // Outside `total`: serializing an interface is not a phase of a cold
    // build and never runs in one. It is the row `plans/m4-slice-zero.md`
    // §8 items 1–3 ask for, so a warm build's cost can be argued about
    // with numbers before D1 is taken.
    const ifaces = try measureIface(gpa, io, corpus, options.iterations);
    try printIfaceLine(stdout, ifaces);

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
        } else if (std.mem.eql(u8, arg, "--dispatch")) {
            options.dispatch = true;
        } else if (std.mem.startsWith(u8, arg, "--wide=")) {
            const declarations = try std.fmt.parseInt(u32, arg["--wide=".len..], 10);
            if (declarations == 0) return error.ZeroDeclarations;
            options.wide = declarations;
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
    /// The derived-context fixpoints v2 ran (`Contexts.run`, checker-v2.md
    /// §11.2), summed over the modules it CHECKED. A module installed from
    /// the cache runs none: its rows are read off its record (I10, §14.3 *as
    /// built by R10*), which is what a warm run's 0 here says.
    derived_context_runs: u64 = 0,
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
        // By name: `CheckMeasurement` mirrors `Check.Counters`, and a
        // counter added there but not copied here would print as zero.
        inline for (@typeInfo(@TypeOf(session.checked.counters)).@"struct".fields) |f| {
            @field(counts, f.name) = @field(session.checked.counters, f.name);
        }
        counts.diagnostics = session.diagnostics.items.len;
    }
    return if (best == std.math.maxInt(u64)) 0 else best;
}

/// Code generation (`backend.md` §13): `Bir` → `JsIr` → bytes, over a
/// project that has already been checked. The session is built once, outside
/// the timed region, because what this measures is the BACK END and not the
/// front end that feeds it — the other lines already own that.
const EmitMeasurement = struct {
    modules: u64 = 0,
    /// Bytes of JavaScript produced.
    bytes: u64 = 0,
    /// beni lines behind them, for `loc_per_s`.
    lines: u64 = 0,
    nodes: u64 = 0,
    ns: u64 = 0,
};

fn measureEmit(gpa: std.mem.Allocator, io: Io, corpus: []const u8, iterations: u32) !EmitMeasurement {
    var sink: Io.Writer.Discarding = .init(&.{});
    var session = try Session.init(gpa, io, .{ .jobs = 1, .diagnostics = .json, .core_package = true });
    defer session.deinit();
    _ = session.run(&.{corpus}, Session.check_phases, &sink.writer) catch return .{};

    const count = session.graph.count();
    var arena: Arena = .init(std.heap.page_allocator);
    defer arena.deinit();

    // Every module's `Bir` and a specifier per module: what `js/Emit.zig`
    // hands the lowering, computed once so the loop below is emit and
    // nothing else.
    const birs = try gpa.alloc(*const Bir, count);
    defer gpa.free(birs);
    const specifiers = try gpa.alloc([]const u8, count);
    defer gpa.free(specifiers);
    defer for (specifiers) |s| gpa.free(s);
    var made: usize = 0;
    errdefer for (specifiers[0..made]) |s| gpa.free(s);
    for (birs, specifiers, 0..) |*b, *specifier, i| {
        const m: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
        const file = session.graph.moduleFile(m);
        b.* = session.artifacts.bir(file);
        specifier.* = try std.fmt.allocPrint(gpa, "./{s}.mjs", .{session.store.moduleName(file)});
        made += 1;
    }

    var best: u64 = std.math.maxInt(u64);
    var m: EmitMeasurement = .{ .modules = count };
    var iteration: u32 = 0;
    while (iteration < iterations + 1) : (iteration += 1) {
        var bytes: u64 = 0;
        var lines: u64 = 0;
        var nodes: u64 = 0;
        const start = Io.Timestamp.now(io, .awake);
        for (0..count) |i| {
            const module: Graph.Index = @enumFromInt(@as(u32, @intCast(i)));
            const file = session.graph.moduleFile(module);
            const tokens = session.artifacts.tokens(file);
            var lowered = try JsLower.lower(gpa, arena.allocator(), &session.interner, .{
                .bir = birs[i],
                .token_starts = tokens.items(.start),
                .module = module,
                .graph = &session.graph,
                .interfaces = session.resolution.interfaces,
                .dispatch = if (module.int() < session.checked.dispatch.len)
                    &session.checked.dispatch[module.int()]
                else
                    &JsLower.Dispatch.empty,
                .types = &session.checked.types,
                .specifiers = specifiers,
                .sibling = "./x.js",
            });
            defer lowered.ir.deinit(gpa);
            defer {
                for (lowered.diagnostics) |d| gpa.free(d.message);
                gpa.free(lowered.diagnostics);
            }
            nodes += lowered.ir.nodes.len;
            const text = try JsPrint.print(gpa, &lowered.ir, .fromGlobal(&session.interner), .{});
            defer gpa.free(text);
            bytes += text.len;
            arena.reset(.retain_capacity);
            lines += session.store.lineStarts(file).len;
        }
        const ns: u64 = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        if (iteration == 0) continue; // warm-up
        best = @min(best, ns);
        m.bytes = bytes;
        m.lines = lines;
        m.nodes = nodes;
    }
    m.ns = if (best == std.math.maxInt(u64)) 0 else best;
    return m;
}

fn printEmitLine(writer: *Io.Writer, m: EmitMeasurement) !void {
    const seconds = @as(f64, @floatFromInt(@max(m.ns, 1))) / 1e9;
    const mb_per_s = @as(f64, @floatFromInt(m.bytes)) / (1024 * 1024) / seconds;
    const loc_per_s: u64 = @intFromFloat(@as(f64, @floatFromInt(m.lines)) / seconds);
    try writer.print(
        "{{\"phase\":\"emit\",\"modules\":{d},\"js_bytes\":{d},\"nodes\":{d},\"lines\":{d}," ++
            "\"ms\":{d:.2},\"mb_per_s\":{d:.1},\"loc_per_s\":{d}}}\n",
        .{ m.modules, m.bytes, m.nodes, m.lines, milliseconds(m.ns), mb_per_s, loc_per_s },
    );
}

/// Every `u64` field of `CheckMeasurement`, in declaration order, then the
/// three derived timings. Reflective in the SAME way the copy out of
/// `Solve.Counters` is: a counter added to the struct and forgotten here
/// used to print nothing at all, which is the one failure mode a benchmark
/// line must not have — a missing field reads as "the feature costs
/// nothing" rather than as a bug.
/// The serialized interface (M4 slice zero): how big a module's record is,
/// what the three operations over it cost, and what a whole check costs
/// with every record round-tripped.
///
/// **What it is for.** `plans/m4-slice-zero.md` §8 lists three numbers that
/// a decision about the warm build needs and that nothing could produce:
/// bytes per module, serialize/deserialize/hash time, and the fraction of a
/// check a load would replace. The last is the one that matters — the
/// firewall is only worth having if reading a record is much cheaper than
/// recomputing it — and `roundtrip_check_ns` against `cold_check_ns` is its
/// upper bound, because a round trip pays for BOTH halves where a warm
/// build pays for one.
const IfaceMeasurement = struct {
    modules: u64 = 0,
    bytes: u64 = 0,
    min_bytes: u64 = 0,
    median_bytes: u64 = 0,
    max_bytes: u64 = 0,
    /// Source bytes behind those records, for the ratio §2 estimates.
    source_bytes: u64 = 0,
    write_ns: u64 = 0,
    read_ns: u64 = 0,
    hash_ns: u64 = 0,
    cold_check_ns: u64 = 0,
    roundtrip_check_ns: u64 = 0,
};

fn measureIface(gpa: std.mem.Allocator, io: Io, corpus: []const u8, iterations: u32) !IfaceMeasurement {
    var m: IfaceMeasurement = .{};
    var sink: Io.Writer.Discarding = .init(&.{});

    var session = try Session.init(gpa, io, .{ .jobs = 1, .diagnostics = .json, .core_package = true });
    defer session.deinit();
    _ = session.run(&.{corpus}, Session.check_phases, &sink.writer) catch return m;

    const interfaces = session.resolution.interfaces;
    m.modules = interfaces.len;
    if (m.modules == 0) return m;
    for (0..session.store.count()) |i| {
        m.source_bytes += session.store.bytes(@enumFromInt(i)).len;
    }

    const sizes = try gpa.alloc(u64, interfaces.len);
    defer gpa.free(sizes);

    var best_write: u64 = std.math.maxInt(u64);
    var best_read: u64 = std.math.maxInt(u64);
    var best_hash: u64 = std.math.maxInt(u64);
    var iteration: u32 = 0;
    while (iteration < iterations + 1) : (iteration += 1) {
        var write_ns: u64 = 0;
        var read_ns: u64 = 0;
        var hash_ns: u64 = 0;
        var total_bytes: u64 = 0;
        for (interfaces, sizes) |*iface, *size| {
            var t = Io.Timestamp.now(io, .awake);
            const bytes = try iface_bytes.write(gpa, iface, &session.interner);
            defer gpa.free(bytes);
            write_ns += elapsed(io, &t);
            std.mem.doNotOptimizeAway(iface_bytes.hash(bytes));
            hash_ns += elapsed(io, &t);
            var back = iface_bytes.read(gpa, bytes, &session.interner) catch continue;
            read_ns += elapsed(io, &t);
            back.deinit(gpa);
            size.* = bytes.len;
            total_bytes += bytes.len;
        }
        if (iteration == 0) continue; // warm-up
        if (write_ns < best_write) best_write = write_ns;
        if (read_ns < best_read) best_read = read_ns;
        if (hash_ns < best_hash) best_hash = hash_ns;
        m.bytes = total_bytes;
    }
    m.write_ns = best_write;
    m.read_ns = best_read;
    m.hash_ns = best_hash;

    std.mem.sort(u64, sizes, {}, std.sort.asc(u64));
    m.min_bytes = sizes[0];
    m.median_bytes = sizes[sizes.len / 2];
    m.max_bytes = sizes[sizes.len - 1];

    m.cold_check_ns = try timedCheck(gpa, io, corpus, iterations, false);
    m.roundtrip_check_ns = try timedCheck(gpa, io, corpus, iterations, true);
    return m;
}

/// A whole cold `check` over `corpus`, with or without
/// `--roundtrip-interfaces`. Best of `iterations` after a warm-up, exactly
/// as `coldCheck` does it.
fn timedCheck(gpa: std.mem.Allocator, io: Io, corpus: []const u8, iterations: u32, roundtrip: bool) !u64 {
    var sink: Io.Writer.Discarding = .init(&.{});
    var best: u64 = std.math.maxInt(u64);
    var iteration: u32 = 0;
    while (iteration < iterations + 1) : (iteration += 1) {
        var session = try Session.init(gpa, io, .{
            .jobs = 1,
            .diagnostics = .json,
            .core_package = true,
            .roundtrip_interfaces = roundtrip,
        });
        defer session.deinit();
        const start = Io.Timestamp.now(io, .awake);
        _ = session.run(&.{corpus}, Session.check_phases, &sink.writer) catch continue;
        const ns: u64 = @intCast(start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds);
        if (iteration == 0) continue;
        best = @min(best, ns);
    }
    return if (best == std.math.maxInt(u64)) 0 else best;
}

fn printIfaceLine(writer: *Io.Writer, m: IfaceMeasurement) !void {
    try writer.print(
        "{{\"phase\":\"iface\",\"modules\":{d},\"bytes\":{d},\"bytes_per_module\":{d}" ++
            ",\"min_bytes\":{d},\"median_bytes\":{d},\"max_bytes\":{d},\"source_bytes\":{d}" ++
            ",\"write_ms\":{d:.3},\"hash_ms\":{d:.3},\"read_ms\":{d:.3}" ++
            ",\"cold_check_ms\":{d:.1},\"roundtrip_check_ms\":{d:.1}}}\n",
        .{
            m.modules,               m.bytes,                       m.bytes / @max(m.modules, 1),
            m.min_bytes,             m.median_bytes,                m.max_bytes,
            m.source_bytes,          milliseconds(m.write_ns),      milliseconds(m.hash_ns),
            milliseconds(m.read_ns), milliseconds(m.cold_check_ns), milliseconds(m.roundtrip_check_ns),
        },
    );
}

fn printCheckLine(writer: *Io.Writer, m: CheckMeasurement) !void {
    const seconds = @as(f64, @floatFromInt(@max(m.ns, 1))) / 1e9;
    const loc_per_s: u64 = @intFromFloat(@as(f64, @floatFromInt(m.lines)) / seconds);
    try writer.writeAll("{\"phase\":\"check\"");
    inline for (@typeInfo(CheckMeasurement).@"struct".fields) |f| {
        // `ns` and `total_ns` are reported below as `ms` and
        // `cold_check_ms`. Matched EXACTLY: a suffix test on "ns" also
        // matches `unifications`, `generalisations`, `instantiations` and
        // `obligations`, and silently dropped all four from the line.
        if (comptime !std.mem.eql(u8, f.name, "ns") and !std.mem.eql(u8, f.name, "total_ns")) {
            try writer.print(",\"{s}\":{d}", .{ f.name, @field(m, f.name) });
        }
    }
    try writer.print(
        ",\"ms\":{d:.2},\"loc_per_s\":{d},\"cold_check_ms\":{d:.1}}}\n",
        .{ milliseconds(m.ns), loc_per_s, milliseconds(m.total_ns) },
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
