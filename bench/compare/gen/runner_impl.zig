//! The runner (docs/design/compare-bench.md §8.2, §9–§11, §14): prepare the
//! dependencies, generate every project, warm up and confirm, time the
//! interleaved rounds, fit, and hand the numbers to `report.zig`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Tree = @import("Tree.zig");
const gen = @import("gen.zig");
const print = @import("print/print.zig");
const Rng = @import("Rng.zig");
const fit = @import("fit.zig");
const report = @import("report.zig");
const runner = @import("runner.zig");

const Lang = print.Lang;
const Mode = runner.Mode;
const Options = runner.Options;

/// A project is one family, or all of them (§5.2).
pub const Project = union(enum) {
    family: Tree.Family,
    total,

    pub fn name(p: Project) []const u8 {
        return switch (p) {
            .family => |f| @tagName(f),
            .total => "total",
        };
    }
};

pub const projects: [9]Project = blk: {
    var ps: [9]Project = undefined;
    for (Tree.Family.all, 0..) |f, i| ps[i] = .{ .family = f };
    ps[8] = .total;
    break :blk ps;
};

/// One measured point: a language, a mode, a project and a size.
pub const Point = struct {
    lang: Lang,
    mode: Mode,
    project: usize, // index into `projects`
    size: u32,
    dir: []const u8,
    stats: print.Stats,
    nodes: u64,
    /// Wall time of each sample, ms, the spawn included.
    samples: std.ArrayList(f64) = .empty,
    /// CPU time of each sample, ms: user + sys from `wait4`'s rusage, which
    /// covers the compiler and every child it reaped (§10.6, amended
    /// 2026-09-28). The headline fits these.
    cpu_samples: std.ArrayList(f64) = .empty,
    /// Roc only: its own `--timings` figure for "Shared Lowering and
    /// Compile-Time Evaluation", ms, from the warm-up run (§9).
    roc_cte_ms: f64 = 0,
};

const Ctx = struct {
    gpa: Allocator,
    io: Io,
    a: Allocator,
    o: Options,
    out: *Io.Writer,
    err: *Io.Writer,
    env: *std.process.Environ.Map,
    work: []const u8,
    deps: []const u8,
    tools: Tools = .{},
    offline: bool = true,
};

const Tools = struct {
    beni: []const u8 = "",
    elm: []const u8 = "",
    gleam: []const u8 = "",
    roc: []const u8 = "",
    purs: []const u8 = "",
    tsc: []const u8 = "",
    taskset: []const u8 = "",
    unshare: []const u8 = "",
    spago: []const u8 = "",
    git: []const u8 = "",
    zig: []const u8 = "",
    cp: []const u8 = "",
    cat: []const u8 = "",
};

fn which(c: *Ctx, name: []const u8) ?[]const u8 {
    const path = c.env.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |d| {
        if (d.len == 0) continue;
        const full = std.fs.path.join(c.a, &.{ d, name }) catch return null;
        Io.Dir.cwd().access(c.io, full, .{ .execute = true }) catch continue;
        return full;
    }
    return null;
}

fn exists(c: *Ctx, path: []const u8) bool {
    Io.Dir.cwd().access(c.io, path, .{}) catch return false;
    return true;
}

pub fn run(c0: Ctx) !u8 {
    var c = c0;
    const o = c.o;
    // §8.1: every tool on PATH first.
    var missing: std.ArrayList([]const u8) = .empty;
    inline for (.{ "elm", "gleam", "purs", "tsc", "taskset", "unshare", "cp", "cat", "git", "zig", "spago" }) |name| {
        if (which(&c, name)) |p| @field(c.tools, name) = p else if (!std.mem.eql(u8, name, "spago")) try missing.append(c.a, name);
    }
    c.tools.beni = o.beni;
    if (!exists(&c, c.tools.beni)) try missing.append(c.a, "beni (the ReleaseFast build; `zig build compare` makes it)");
    if (missing.items.len > 0) {
        try c.err.writeAll("compare: missing tools:");
        for (missing.items) |m| try c.err.print(" {s}", .{m});
        try c.err.writeAll("\nEnter the compare shell first: nix develop .#compare (docs/design/compare-bench.md §8.1)\n");
        return 2;
    }
    c.tools.roc = try std.fs.path.join(c.a, &.{ c.deps, "roc-src/zig-out/bin/roc" });
    // §10.2: offline unless `--online`.
    const probe = try runCmd(&c, &.{ c.tools.unshare, "-rn", "true" }, ".", null);
    c.offline = probe.ok;
    if (!c.offline and !o.online) {
        try c.err.writeAll("compare: `unshare -rn` is unavailable; pass --online to measure with the network (recorded as offline: false)\n");
        return 2;
    }
    try prepare(&c);
    // `--prepare` alone: fetch and build the dependencies, nothing else.
    if (o.prepare) return 0;

    const sizes: []const u32 = if (o.smoke) &.{1} else o.sizes;
    const runs: u32 = if (o.smoke) 0 else o.runs;
    const load_start = loadavg(&c);
    const started = Io.Timestamp.now(c.io, .real);

    // Generate every project (§5.2) and write it once per language.
    var points: std.ArrayList(Point) = .empty;
    var unit_nodes: [8]u64 = @splat(0);
    const run_dir = try std.fs.path.join(c.a, &.{ c.work, "run" });
    Io.Dir.cwd().deleteTree(c.io, run_dir) catch {};
    for (o.modes) |mode| {
        for (projects, 0..) |proj, pi| {
            for (sizes) |size| {
                var arena_state = std.heap.ArenaAllocator.init(c.gpa);
                defer arena_state.deinit();
                const ga = arena_state.allocator();
                var diag: Io.Writer.Allocating = .init(ga);
                const fams: []const Tree.Family = switch (proj) {
                    .family => |f| &.{f},
                    .total => &Tree.Family.all,
                };
                const annotate: u32 = if (mode == .annotated) 100 else 0;
                const prog = gen.generate(ga, .{ .seed = o.seed, .size = size, .families = fams, .annotate = annotate }, &diag.writer) catch |e| {
                    try c.err.print("compare: the oracle refused seed 0x{X}, {s}, size {d}, {t}:\n{s}\n", .{ o.seed, proj.name(), size, mode, diag.written() });
                    return e;
                };
                var nodes: u64 = 0;
                for (prog.tree.modules.items, prog.info.sizes) |m, s| {
                    if (m.kind == .unit) nodes += s.nodes;
                    if (m.kind == .unit and proj == .family and size == sizes[sizes.len - 1] and mode == o.modes[0]) unit_nodes[@intFromEnum(m.family) - 1] += s.nodes;
                }
                for (o.langs) |lang| {
                    const dir = try std.fmt.allocPrint(c.a, "{s}/{t}/{t}/{s}-{d}", .{ run_dir, mode, lang, proj.name(), size });
                    var d = try Io.Dir.cwd().createDirPathOpen(c.io, dir, .{});
                    defer d.close(c.io);
                    const st = try print.project(ga, c.io, d, &prog, lang);
                    try setup(&c, lang, dir);
                    try points.append(c.a, .{ .lang = lang, .mode = mode, .project = pi, .size = size, .dir = dir, .stats = st, .nodes = nodes });
                }
            }
        }
    }
    try c.out.print("compare: {d} points generated under {s}\n", .{ points.items.len, run_dir });

    // Warm-up doubles as confirmation (§10.4, §11).
    var warm_ns: u64 = 0;
    for (points.items) |*p| {
        const t0 = Io.Timestamp.now(c.io, .awake);
        const r = try timed(&c, p.*, true);
        p.roc_cte_ms = r.cte_ms;
        warm_ns += @intCast(t0.durationTo(Io.Timestamp.now(c.io, .awake)).nanoseconds);
        if (!r.ok) {
            try c.err.print(
                \\compare: {t} refused a generated project — a generator bug by definition (§11).
                \\  mode {t}, project {s}, size {d}, seed 0x{X}, generator {s}
                \\  project kept at {s}
                \\  reproduce: zig build compare-gen -- --seed=0x{X} --size={d} --families={s} --annotate={d} --langs={t}
                \\--- compiler output ---
                \\{s}
                \\
            , .{ p.lang, p.mode, projects[p.project].name(), p.size, o.seed, o.generator_hash, p.dir, o.seed, p.size, familiesArg(projects[p.project]), @as(u32, if (p.mode == .annotated) 100 else 0), p.lang, r.output });
            // The build runner keeps only the end of a long stderr: the whole
            // report also goes to a file.
            const report_path = try std.fs.path.join(c.a, &.{ c.work, "failure.txt" });
            Io.Dir.cwd().writeFile(c.io, .{ .sub_path = report_path, .data = try std.fmt.allocPrint(c.a, "{t} {t} {s}-{d}\n{s}\n{s}\n", .{ p.lang, p.mode, projects[p.project].name(), p.size, p.dir, r.output }) }) catch {};
            try c.err.print("compare: the report is also in {s}\n", .{report_path});
            return 1;
        }
    }
    const warm_s = @as(f64, @floatFromInt(warm_ns)) / 1e9;
    try c.out.print("compare: every compiler accepted every project (warm-up {d:.1} s)\n", .{warm_s});
    // `--runs=0`: confirmation at every size, and no timing.
    if (o.smoke or runs == 0) return 0;
    const estimate = warm_s * @as(f64, @floatFromInt(runs));
    try c.out.print("compare: estimated {d:.0} s for {d} rounds\n", .{ estimate, runs });
    if (estimate > 2 * 30 * 60) try c.out.writeAll("compare: WARNING the estimate is over twice the §14 budget; continuing\n");

    // Interleaved rounds (§10.5): every point once per round, in an order
    // drawn from (seed, round).
    const order = try c.a.alloc(usize, points.items.len);
    for (0..runs) |round| {
        for (order, 0..) |*x, i| x.* = i;
        var rng = Rng.forUnit(o.seed, 0xC0FFEE, @intCast(round));
        var i = order.len;
        while (i > 1) {
            i -= 1;
            const j = rng.below(@intCast(i + 1));
            std.mem.swap(usize, &order[i], &order[j]);
        }
        for (order) |pi| {
            const p = &points.items[pi];
            const r = try timed(&c, p.*, false);
            if (!r.ok) {
                try c.err.print("compare: {t} failed a timed run of {s} (exit or timeout)\n", .{ p.lang, p.dir });
                return 1;
            }
            try p.samples.append(c.a, r.ms);
            try p.cpu_samples.append(c.a, r.cpu_ms);
        }
        const la = loadavg(&c);
        try c.out.print("compare: round {d}/{d} done, load {d:.2} {d:.2} {d:.2}\n", .{ round + 1, runs, la[0], la[1], la[2] });
        try c.out.flush();
    }
    const load_end = loadavg(&c);
    return report.write(.{
        .a = c.a,
        .io = c.io,
        .o = o,
        .points = points.items,
        .unit_nodes = unit_nodes,
        .sizes = sizes,
        .load_start = load_start,
        .load_end = load_end,
        .started = started,
        .offline = c.offline,
        .versions = try versions(&c),
        .out = c.out,
        .machine = try machine(&c),
        .toolchain = try toolchain(&c),
    });
}

fn familiesArg(p: Project) []const u8 {
    return switch (p) {
        .family => |f| @tagName(f),
        .total => "inference,polymorphism,patterns,depth,recursion,data,imports,everyday",
    };
}

// ---- commands (§9) ----

const Result = struct { ok: bool, ms: f64 = 0, cpu_ms: f64 = 0, cte_ms: f64 = 0, output: []const u8 = "" };

fn runCmd(c: *Ctx, argv: []const []const u8, cwd: []const u8, env: ?*const std.process.Environ.Map) !Result {
    const r = std.process.run(c.a, c.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .environ_map = env }) catch |e| {
        return .{ .ok = false, .output = try std.fmt.allocPrint(c.a, "{s}: {t}", .{ argv[0], e }) };
    };
    const ok = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    const both = try std.mem.concat(c.a, u8, &.{ r.stdout, r.stderr });
    return .{ .ok = ok, .output = both };
}

/// The timed command of §9, for `p`, wrapped in `unshare -rn` and `taskset`.
fn command(c: *Ctx, p: Point, argv: *std.ArrayList([]const u8)) !void {
    if (c.offline) try argv.appendSlice(c.a, &.{ c.tools.unshare, "-rn" });
    try argv.appendSlice(c.a, &.{ c.tools.taskset, "-c", try std.fmt.allocPrint(c.a, "{d}", .{c.o.cpu}) });
    switch (p.lang) {
        .beni => try argv.appendSlice(c.a, &.{ c.tools.beni, "check", "--no-cache", "--jobs=1", "--platform=node", "." }),
        .elm => try argv.appendSlice(c.a, &.{ c.tools.elm, "make", "src/Main.elm", "--output=/dev/null", "+RTS", "-N1", "-RTS" }),
        .gleam => try argv.appendSlice(c.a, &.{ c.tools.gleam, "check" }),
        .roc => try argv.appendSlice(c.a, &.{ c.tools.roc, "check", "--no-cache", "--jobs=1", "--no-color", "Main.roc" }),
        .purescript => try argv.appendSlice(c.a, &.{ c.tools.purs, "compile", try std.fmt.allocPrint(c.a, "{s}/purescript/.spago/*/*/src/**/*.purs", .{c.deps}), "src/**/*.purs", "-o", "output", "--codegen", "corefn", "+RTS", "-N1", "-RTS" }),
        .typescript => try argv.appendSlice(c.a, &.{ c.tools.tsc, "-p", ".", "--singleThreaded" }),
    }
}

pub fn commandText(lang: Lang) []const u8 {
    return switch (lang) {
        .beni => "beni check --no-cache --jobs=1 --platform=node . (§9 row v1)",
        .elm => "elm make src/Main.elm --output=/dev/null +RTS -N1 -RTS (§9 row v1)",
        .gleam => "gleam check (§9 row v1)",
        .roc => "roc check --no-cache --jobs=1 Main.roc (§9 row v2)",
        .purescript => "purs compile '<deps>' 'src/**/*.purs' -o output --codegen corefn +RTS -N1 -RTS (§9 row v2)",
        .typescript => "GOMAXPROCS=1 tsc -p . --singleThreaded (§9 row v1)",
    };
}

fn envFor(c: *Ctx, lang: Lang) !*std.process.Environ.Map {
    const m = try c.a.create(std.process.Environ.Map);
    m.* = try c.env.clone(c.a);
    switch (lang) {
        .elm => try m.put("ELM_HOME", try std.fs.path.join(c.a, &.{ c.deps, "elm-home" })),
        .typescript => try m.put("GOMAXPROCS", "1"),
        else => {},
    }
    return m;
}

/// Clear what §9's last column says, untimed.
fn reset(c: *Ctx, p: Point) !void {
    var d = try Io.Dir.cwd().openDir(c.io, p.dir, .{});
    defer d.close(c.io);
    switch (p.lang) {
        .beni => d.deleteTree(c.io, ".beni-cache") catch {},
        .elm => d.deleteTree(c.io, "elm-stuff") catch {},
        .gleam => d.deleteTree(c.io, "build/dev/javascript/compare") catch {},
        .roc, .typescript => {},
        .purescript => {
            d.deleteTree(c.io, "output") catch {};
            const src = try std.fs.path.join(c.a, &.{ c.deps, "purescript/output" });
            const r = try runCmd(c, &.{ c.tools.cp, "-a", src, "output" }, p.dir, null);
            if (!r.ok) return error.RestoreFailed;
        },
    }
}

/// Reset, then run `p`'s command once. `confirm` captures the output and
/// applies §11's acceptance (no error, and no warning where the language
/// exits 0 on one); otherwise output is discarded and only time is kept.
fn timed(c: *Ctx, p: Point, confirm: bool) !Result {
    try reset(c, p);
    var argv: std.ArrayList([]const u8) = .empty;
    try command(c, p, &argv);
    const env = try envFor(c, p.lang);
    if (confirm) {
        // Roc's warm-up also reports its phases (§9): its compile-time
        // evaluation is disclosed, and subtracted in a side column.
        if (p.lang == .roc) try argv.insert(c.a, argv.items.len - 1, "--timings");
        const t0 = Io.Timestamp.now(c.io, .awake);
        const r = try runCmd(c, argv.items, p.dir, env);
        const ms = @as(f64, @floatFromInt(t0.durationTo(Io.Timestamp.now(c.io, .awake)).nanoseconds)) / 1e6;
        if (!r.ok) return .{ .ok = false, .output = r.output };
        if (!accepted(p.lang, r.output)) return .{ .ok = false, .output = r.output };
        return .{ .ok = true, .ms = ms, .cte_ms = if (p.lang == .roc) rocCte(r.output) else 0 };
    }
    const t0 = Io.Timestamp.now(c.io, .awake);
    var child = try std.process.spawn(c.io, .{ .argv = argv.items, .cwd = .{ .path = p.dir }, .environ_map = env, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .request_resource_usage_statistics = true });
    const term = try child.wait(c.io);
    const ms = @as(f64, @floatFromInt(t0.durationTo(Io.Timestamp.now(c.io, .awake)).nanoseconds)) / 1e6;
    // `unshare` and `taskset` exec the compiler rather than fork it, so
    // the rusage is the compiler's own plus its reaped children's.
    const ru = child.resource_usage_statistics.rusage orelse return error.NoRusage;
    const us = (@as(i64, ru.utime.sec) + @as(i64, ru.stime.sec)) * 1_000_000 + @as(i64, ru.utime.usec) + @as(i64, ru.stime.usec);
    const cpu_ms = @as(f64, @floatFromInt(us)) / 1000;
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (ms > @as(f64, @floatFromInt(c.o.timeout_s)) * 1000) return .{ .ok = false, .ms = ms };
    return .{ .ok = ok, .ms = ms, .cpu_ms = cpu_ms };
}

/// The "Shared Lowering and Compile-Time Evaluation" line of `roc check
/// --timings`, in ms (0 when absent).
fn rocCte(output: []const u8) f64 {
    const key = "Shared Lowering and Compile-Time Evaluation";
    const at = std.mem.indexOf(u8, output, key) orelse return 0;
    var i = at + key.len;
    while (i < output.len and output[i] == ' ') i += 1;
    var j = i;
    while (j < output.len and (std.ascii.isDigit(output[j]) or output[j] == '.')) j += 1;
    const v = std.fmt.parseFloat(f64, output[i..j]) catch return 0;
    const unit = output[j..@min(output.len, j + 2)];
    if (std.mem.startsWith(u8, unit, "us") or std.mem.startsWith(u8, unit, "µ")) return v / 1000;
    if (std.mem.eql(u8, unit, "ms")) return v;
    if (unit.len > 0 and unit[0] == 's') return v * 1000;
    return v;
}

/// §11 and §19 V2: Gleam exits 0 on warnings, and PureScript's one expected
/// warning in inferred mode is `MissingTypeDeclaration`.
fn accepted(lang: Lang, output: []const u8) bool {
    switch (lang) {
        .gleam => {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |line| if (std.mem.startsWith(u8, line, "warning")) return false;
        },
        .purescript => {
            var i: usize = 0;
            while (std.mem.indexOfPos(u8, output, i, "/errors/")) |at| {
                const end = std.mem.indexOfPos(u8, output, at, ".md") orelse break;
                const name = output[at + "/errors/".len .. end];
                if (!std.mem.eql(u8, name, "MissingTypeDeclaration")) return false;
                i = end;
            }
        },
        // beni's one expected warning, in the inferred mode: a `pub`
        // declaration without an annotation whose inferred type carries a
        // method constraint (`==` on values nothing else fixes).
        .beni => {
            var it = std.mem.splitScalar(u8, output, '\n');
            while (it.next()) |line| {
                if (!std.mem.startsWith(u8, line, "-- ")) continue;
                if (std.mem.indexOf(u8, line, "CONSTRAINT IN AN INFERRED INTERFACE") == null) return false;
            }
            if (std.mem.indexOf(u8, output, "error") != null) return false;
        },
        else => {},
    }
    return true;
}

// ---- dependencies (§8.2) ----

fn prepare(c: *Ctx) !void {
    try Io.Dir.cwd().createDirPath(c.io, c.deps);
    const tmpl = print.templates;
    // Elm: ELM_HOME filled by one online `elm make` of a template project.
    const elm_home = try std.fs.path.join(c.a, &.{ c.deps, "elm-home" });
    if (!exists(c, try std.fs.path.join(c.a, &.{ elm_home, "0.19.2/packages/elm/json" }))) {
        const d = try std.fs.path.join(c.a, &.{ c.deps, "elm" });
        var dir = try Io.Dir.cwd().createDirPathOpen(c.io, d, .{});
        defer dir.close(c.io);
        try dir.writeFile(c.io, .{ .sub_path = "elm.json", .data = tmpl.elm_json });
        try dir.createDirPath(c.io, "src");
        try dir.writeFile(c.io, .{ .sub_path = "src/Main.elm", .data = "module Main exposing (main)\n\n\nmain : Program () () ()\nmain =\n    Platform.worker { init = \\_ -> ( (), Cmd.none ), update = \\_ _ -> ( (), Cmd.none ), subscriptions = \\_ -> Sub.none }\n" });
        try c.out.writeAll("compare: preparing Elm packages (online)\n");
        const env = try envFor(c, .elm);
        const r = try runCmd(c, &.{ c.tools.elm, "make", "src/Main.elm", "--output=/dev/null" }, d, env);
        if (!r.ok) return fail(c, "elm", r.output);
    }
    // Gleam: the manifest's packages, and gleam_stdlib compiled once.
    const gleam_dir = try std.fs.path.join(c.a, &.{ c.deps, "gleam" });
    if (!exists(c, try std.fs.path.join(c.a, &.{ gleam_dir, "build/packages/gleam_stdlib" }))) {
        var dir = try Io.Dir.cwd().createDirPathOpen(c.io, gleam_dir, .{});
        defer dir.close(c.io);
        try dir.writeFile(c.io, .{ .sub_path = "gleam.toml", .data = tmpl.gleam_toml });
        try dir.writeFile(c.io, .{ .sub_path = "manifest.toml", .data = tmpl.gleam_manifest });
        try dir.createDirPath(c.io, "src");
        try dir.writeFile(c.io, .{ .sub_path = "src/compare.gleam", .data = "pub fn main() -> Nil {\n  Nil\n}\n" });
        try c.out.writeAll("compare: preparing Gleam packages (online)\n");
        const r = try runCmd(c, &.{ c.tools.gleam, "check" }, gleam_dir, null);
        if (!r.ok) return fail(c, "gleam", r.output);
    }
    // PureScript: `spago install`, then a deps-only `output/` in CoreFn.
    const ps_dir = try std.fs.path.join(c.a, &.{ c.deps, "purescript" });
    if (!exists(c, try std.fs.path.join(c.a, &.{ ps_dir, "output/Prelude" }))) {
        var dir = try Io.Dir.cwd().createDirPathOpen(c.io, ps_dir, .{});
        defer dir.close(c.io);
        try dir.writeFile(c.io, .{ .sub_path = "spago.dhall", .data = tmpl.spago_dhall });
        try dir.writeFile(c.io, .{ .sub_path = "packages.dhall", .data = tmpl.packages_dhall });
        if (!exists(c, try std.fs.path.join(c.a, &.{ ps_dir, ".spago/prelude" }))) {
            if (c.tools.spago.len == 0) return fail(c, "purescript", "spago is not on PATH");
            try c.out.writeAll("compare: preparing PureScript packages (online, spago install)\n");
            const r = try runCmd(c, &.{ c.tools.spago, "install" }, ps_dir, null);
            if (!r.ok) return fail(c, "spago", r.output);
        }
        const r = try runCmd(c, &.{ c.tools.purs, "compile", ".spago/*/*/src/**/*.purs", "-o", "output", "--codegen", "corefn" }, ps_dir, null);
        if (!r.ok) return fail(c, "purs", r.output);
    }
    // Roc: the Zig compiler at the pinned commit (§8.1).
    if (!exists(c, c.tools.roc)) {
        const src = try std.fs.path.join(c.a, &.{ c.deps, "roc-src" });
        try c.out.print("compare: building Roc {s} from source (online; several minutes)\n", .{c.o.roc_commit});
        if (!exists(c, src)) {
            const r = try runCmd(c, &.{ c.tools.git, "clone", "--filter=blob:none", "--no-checkout", "https://github.com/roc-lang/roc.git", src }, c.deps, null);
            if (!r.ok) return fail(c, "git clone", r.output);
        }
        var r = try runCmd(c, &.{ c.tools.git, "fetch", "origin", c.o.roc_commit }, src, null);
        r = try runCmd(c, &.{ c.tools.git, "checkout", "-q", c.o.roc_commit }, src, null);
        if (!r.ok) return fail(c, "git checkout", r.output);
        const cache = try std.fs.path.join(c.a, &.{ c.deps, "roc-zig-cache" });
        r = try runCmd(c, &.{ c.tools.zig, "build", "roc", "-Doptimize=ReleaseFast", "--cache-dir", cache }, src, null);
        if (!r.ok) return fail(c, "roc build", r.output);
    }
}

fn fail(c: *Ctx, what: []const u8, output: []const u8) error{PrepareFailed} {
    c.err.print("compare: preparing {s} failed:\n{s}\n", .{ what, output }) catch {};
    return error.PrepareFailed;
}

/// Per project, untimed: link the prepared dependencies in.
fn setup(c: *Ctx, lang: Lang, dir: []const u8) !void {
    switch (lang) {
        .gleam => {
            const src = try std.fs.path.join(c.a, &.{ c.deps, "gleam/build" });
            const r = try runCmd(c, &.{ c.tools.cp, "-a", src, "build" }, dir, null);
            if (!r.ok) return fail(c, "gleam setup", r.output);
        },
        else => {},
    }
}

// ---- the machine and the toolchain (§13.1) ----

fn loadavg(c: *Ctx) [3]f64 {
    var out: [3]f64 = .{ 0, 0, 0 };
    // `/proc` files report size 0, so they are read through `cat`.
    const r = runCmd(c, &.{ c.tools.cat, "/proc/loadavg" }, ".", null) catch return out;
    const text = r.output;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    for (&out) |*x| x.* = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
    return out;
}

pub const Machine = struct { cpu: []const u8, nproc: usize, kernel: []const u8 };

fn machine(c: *Ctx) !Machine {
    var cpu: []const u8 = "unknown";
    if (runCmd(c, &.{ c.tools.cat, "/proc/cpuinfo" }, ".", null)) |res| {
        const text = res.output;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| if (std.mem.startsWith(u8, line, "model name")) {
            if (std.mem.indexOfScalar(u8, line, ':')) |i| cpu = std.mem.trim(u8, line[i + 1 ..], " \t");
            break;
        };
    } else |_| {}
    const u = std.posix.uname();
    return .{ .cpu = cpu, .nproc = std.Thread.getCpuCount() catch 0, .kernel = try c.a.dupe(u8, std.mem.sliceTo(&u.release, 0)) };
}

pub const Toolchain = struct { nixpkgs_compare_rev: []const u8, zig: []const u8, beni_commit: []const u8, beni_dirty: bool, roc_commit: []const u8 };

fn toolchain(c: *Ctx) !Toolchain {
    var rev: []const u8 = "unknown";
    const lock_path = try std.fs.path.join(c.a, &.{ c.o.repo, "flake.lock" });
    if (Io.Dir.cwd().readFileAlloc(c.io, lock_path, c.a, .limited(1 << 20))) |text| {
        if (std.mem.indexOf(u8, text, "\"nixpkgs-compare\": {")) |at| {
            if (std.mem.indexOfPos(u8, text, at, "\"rev\": \"")) |r| {
                const s = r + "\"rev\": \"".len;
                if (std.mem.indexOfScalarPos(u8, text, s, '"')) |e| rev = text[s..e];
            }
        }
    } else |_| {}
    const head = try runCmd(c, &.{ c.tools.git, "rev-parse", "HEAD" }, c.o.repo, null);
    const status = try runCmd(c, &.{ c.tools.git, "status", "--porcelain" }, c.o.repo, null);
    return .{
        .nixpkgs_compare_rev = rev,
        .zig = builtin.zig_version_string,
        .beni_commit = std.mem.trim(u8, head.output, " \n"),
        .beni_dirty = std.mem.trim(u8, status.output, " \n").len > 0,
        .roc_commit = c.o.roc_commit,
    };
}

fn versions(c: *Ctx) ![6][]const u8 {
    var out: [6][]const u8 = undefined;
    for (Lang.all, 0..) |lang, i| {
        const argv: []const []const u8 = switch (lang) {
            .beni => &.{ c.tools.beni, "version" },
            .elm => &.{ c.tools.elm, "--version" },
            .gleam => &.{ c.tools.gleam, "--version" },
            .roc => &.{ c.tools.roc, "version" },
            .purescript => &.{ c.tools.purs, "--version" },
            .typescript => &.{ c.tools.tsc, "--version" },
        };
        const r = try runCmd(c, argv, ".", null);
        out[i] = std.mem.trim(u8, r.output, " \n\r");
    }
    return out;
}

pub fn start(gpa: Allocator, io: Io, a: Allocator, o: Options, stdout: *Io.Writer, stderr: *Io.Writer, env: *std.process.Environ.Map) !u8 {
    const work = try std.fs.path.join(a, &.{ o.repo, "bench/compare/work" });
    return run(.{ .gpa = gpa, .io = io, .a = a, .o = o, .out = stdout, .err = stderr, .env = env, .work = work, .deps = try std.fs.path.join(a, &.{ work, "deps" }) });
}
