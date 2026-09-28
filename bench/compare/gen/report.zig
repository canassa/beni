//! The results file and the README tables (docs/design/compare-bench.md §13).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Tree = @import("Tree.zig");
const print = @import("print/print.zig");
const fit = @import("fit.zig");
const runner = @import("runner.zig");
const impl = @import("runner_impl.zig");

const Lang = print.Lang;
const Mode = runner.Mode;

pub const Input = struct {
    a: Allocator,
    io: Io,
    o: runner.Options,
    points: []impl.Point,
    unit_nodes: [8]u64,
    sizes: []const u32,
    load_start: [3]f64,
    load_end: [3]f64,
    started: Io.Timestamp,
    offline: bool,
    versions: [6][]const u8,
    out: *Io.Writer,
    machine: impl.Machine,
    toolchain: impl.Toolchain,
};

/// What a series fits (§10.6, amended 2026-09-28): CPU time (user + sys)
/// is the headline, and wall time is recorded beside it. For Roc the results
/// file also keeps a fit less its `--timings` compile-time evaluation (§9);
/// the README does not report it: `--timings` counts Roc's artifact publishing
/// as type checking, so what remains is not a checking figure.
const Metric = enum { cpu, wall, cpu_less_cte };

/// One (language, mode, project): its points by size and the fits.
const Series = struct {
    points: [16]?*impl.Point = @splat(null),
    medians: [16]f64 = undefined,
    slope: f64 = 0,
    slope_min: f64 = 0,
    intercept: f64 = 0,
    r2: f64 = 0,
    nodes_per_unit: f64 = 0,
    tokens_per_unit: f64 = 0,
    lines_per_unit: f64 = 0,

    /// Set by `render`: the per-1k figure the results file recorded.
    recorded_per1k: ?f64 = null,

    fn per1k(s: Series) f64 {
        if (s.recorded_per1k) |x| return x;
        return if (s.nodes_per_unit == 0) 0 else s.slope / s.nodes_per_unit * 1000;
    }
    fn per1kTokens(s: Series) f64 {
        return if (s.tokens_per_unit == 0) 0 else s.slope / s.tokens_per_unit * 1000;
    }
};

const n_proj = impl.projects.len;
const Grid = [6][2][n_proj]?Series;

fn samplesOf(a: Allocator, p: *const impl.Point, metric: Metric) []f64 {
    const src = switch (metric) {
        .wall => p.samples.items,
        .cpu, .cpu_less_cte => p.cpu_samples.items,
    };
    const out = a.dupe(f64, src) catch unreachable;
    if (metric == .cpu_less_cte) for (out) |*x| {
        x.* -= p.roc_cte_ms;
    };
    return out;
}

fn index(in: Input, lang: Lang, mode: Mode, proj: usize, metric: Metric) ?Series {
    var s: Series = .{};
    var any = false;
    for (in.points) |*p| {
        if (p.lang != lang or p.mode != mode or p.project != proj) continue;
        const k = std.mem.indexOfScalar(u32, in.sizes, p.size).?;
        s.points[k] = p;
        any = true;
    }
    if (!any) return null;
    const n = in.sizes.len;
    var xs: [16]f64 = undefined;
    var mins: [16]f64 = undefined;
    var nodes: [16]f64 = undefined;
    var toks: [16]f64 = undefined;
    var lines: [16]f64 = undefined;
    for (0..n) |k| {
        const p = s.points[k].?;
        xs[k] = @floatFromInt(p.size);
        const xsamp = samplesOf(in.a, p, metric);
        mins[k] = if (xsamp.len == 0) 0 else fit.minimum(xsamp);
        s.medians[k] = if (xsamp.len == 0) 0 else fit.median(xsamp);
        nodes[k] = @floatFromInt(p.nodes);
        toks[k] = @floatFromInt(p.stats.tokens);
        lines[k] = @floatFromInt(p.stats.lines);
    }
    const l = fit.ols(xs[0..n], s.medians[0..n]);
    s.slope = l.slope;
    s.intercept = l.intercept;
    s.r2 = l.r2;
    s.slope_min = fit.ols(xs[0..n], mins[0..n]).slope;
    s.nodes_per_unit = fit.ols(xs[0..n], nodes[0..n]).slope;
    s.tokens_per_unit = fit.ols(xs[0..n], toks[0..n]).slope;
    s.lines_per_unit = fit.ols(xs[0..n], lines[0..n]).slope;
    return s;
}

fn grid(in: Input, metric: Metric) Grid {
    var g: Grid = undefined;
    for (Lang.all, 0..) |lang, li| for ([_]Mode{ .annotated, .inferred }, 0..) |mode, mi| for (0..n_proj) |pi| {
        g[li][mi][pi] = if (metric == .cpu_less_cte and lang != .roc) null else index(in, lang, mode, pi, metric);
    };
    return g;
}

fn fitJson(w: *Io.Writer, s: Series) !void {
    try w.writeAll("{ \"medians\": {");
    for (0..16) |k| {
        const p = s.points[k] orelse break;
        try w.print("{s} \"{d}\": {d:.2}", .{ if (k > 0) "," else "", p.size, s.medians[k] });
    }
    try w.print(" }}, \"slope_ms_per_unit\": {d:.3}, \"slope_min\": {d:.3}, \"intercept_ms\": {d:.2}, \"r2\": {d:.4}, \"ms_per_1k_nodes\": {d:.4}, \"ms_per_1k_tokens\": {d:.4} }}", .{ s.slope, s.slope_min, s.intercept, s.r2, s.per1k(), s.per1kTokens() });
}

fn samplesJson(w: *Io.Writer, in: Input, s: Series, cpu: bool) !void {
    try w.writeAll("{");
    for (in.sizes, 0..) |size, k| {
        try w.print("{s} \"{d}\": [", .{ if (k > 0) "," else "", size });
        const xs = if (cpu) s.points[k].?.cpu_samples.items else s.points[k].?.samples.items;
        for (xs, 0..) |x, j| try w.print("{s}{d:.2}", .{ if (j > 0) ", " else "", x });
        try w.writeAll("]");
    }
    try w.writeAll(" }");
}

pub fn write(in: Input) !u8 {
    const a = in.a;
    const cpu = grid(in, .cpu);
    const wall = grid(in, .wall);
    const net = grid(in, .cpu_less_cte);
    const date = dateOf(in.started);
    const name = if (in.o.label) |l| try std.fmt.allocPrint(a, "{s}-{s}", .{ date, l }) else try a.dupe(u8, &date);
    const path = try std.fmt.allocPrint(a, "{s}/bench/compare/results/{s}.json", .{ in.o.repo, name });

    var json: Io.Writer.Allocating = .init(a);
    const w = &json.writer;
    // Schema 2 (2026-09-28): CPU and wall fits side by side; Roc's
    // compile-time evaluation per size.
    try w.print("{{\n  \"schema\": 2,\n  \"date\": \"{s}\",\n", .{isoOf(in.started)});
    try w.print("  \"generator\": {{ \"hash\": \"{s}\", \"seed\": \"0x{X}\", \"sizes\": [", .{ in.o.generator_hash, in.o.seed });
    for (in.sizes, 0..) |s, i| try w.print("{s}{d}", .{ if (i > 0) ", " else "", s });
    try w.print("], \"runs\": {d},\n    \"unit_nodes\": {{", .{in.o.runs});
    const largest: f64 = @floatFromInt(in.sizes[in.sizes.len - 1]);
    for (Tree.Family.all, 0..) |f, i| try w.print("{s} \"{t}\": {d:.0}", .{ if (i > 0) "," else "", f, @as(f64, @floatFromInt(in.unit_nodes[i])) / largest });
    try w.writeAll(" } },\n");
    try w.print("  \"machine\": {{ \"cpu\": \"{s}\", \"nproc\": {d}, \"kernel\": \"{s}\", \"cpu_pinned\": {d},\n", .{ in.machine.cpu, in.machine.nproc, in.machine.kernel, in.o.cpu });
    try w.print("               \"loadavg\": {{ \"start\": [{d:.2}, {d:.2}, {d:.2}], \"end\": [{d:.2}, {d:.2}, {d:.2}] }} }},\n", .{ in.load_start[0], in.load_start[1], in.load_start[2], in.load_end[0], in.load_end[1], in.load_end[2] });
    try w.print("  \"offline\": {},\n", .{in.offline});
    try w.print("  \"toolchain\": {{ \"nixpkgs_compare_rev\": \"{s}\", \"zig\": \"{s}\", \"beni_commit\": \"{s}\", \"beni_dirty\": {}, \"roc_commit\": \"{s}\" }},\n", .{ in.toolchain.nixpkgs_compare_rev, in.toolchain.zig, in.toolchain.beni_commit, in.toolchain.beni_dirty, in.toolchain.roc_commit });
    try w.writeAll("  \"headline\": \"cpu\",\n  \"lang_order\": [");
    for (in.o.langs, 0..) |l, i| try w.print("{s}\"{t}\"", .{ if (i > 0) ", " else "", l });
    try w.writeAll("],\n  \"langs\": {\n");
    for (in.o.langs, 0..) |lang, oi| {
        const li = @intFromEnum(lang);
        try w.print("    \"{t}\": {{\n      \"version\": \"{f}\", \"command\": \"{s}\",\n", .{ lang, std.zig.fmtString(in.versions[li]), impl.commandText(lang) });
        try w.writeAll("      \"modes\": {\n");
        var first_mode = true;
        for ([_]Mode{ .annotated, .inferred }, 0..) |mode, mi| {
            if (std.mem.indexOfScalar(Mode, in.o.modes, mode) == null) continue;
            if (!first_mode) try w.writeAll(",\n");
            first_mode = false;
            try w.print("        \"{t}\": {{\n          \"projects\": {{\n", .{mode});
            for (0..n_proj) |pi| {
                const s = cpu[li][mi][pi] orelse continue;
                try w.print("            \"{s}\": {{\n              \"size\": {{", .{impl.projects[pi].name()});
                for (in.sizes, 0..) |size, k| {
                    const p = s.points[k].?;
                    try w.print("{s} \"{d}\": {{ \"nodes\": {d}, \"tokens\": {d}, \"lines\": {d}, \"modules\": {d}, \"annotations\": {d}, \"explicit_type_args\": {d}, \"invoked_arrows\": {d} }}", .{ if (k > 0) "," else "", size, p.nodes, p.stats.tokens, p.stats.lines, p.stats.modules, p.stats.annotations, p.stats.explicit_type_args, p.stats.invoked_arrows });
                }
                try w.print(" }},\n              \"nodes_per_unit\": {d:.1},\n              \"cpu_samples\": ", .{s.nodes_per_unit});
                try samplesJson(w, in, s, true);
                try w.writeAll(",\n              \"wall_samples\": ");
                try samplesJson(w, in, s, false);
                try w.writeAll(",\n              \"cpu\": ");
                try fitJson(w, s);
                try w.writeAll(",\n              \"wall\": ");
                try fitJson(w, wall[li][mi][pi].?);
                if (net[li][mi][pi]) |ns| {
                    try w.writeAll(",\n              \"compile_time_evaluation_ms\": {");
                    for (in.sizes, 0..) |size, k| try w.print("{s} \"{d}\": {d:.1}", .{ if (k > 0) "," else "", size, s.points[k].?.roc_cte_ms });
                    try w.writeAll(" },\n              \"cpu_less_compile_time_evaluation\": ");
                    try fitJson(w, ns);
                }
                try w.print("\n            }}{s}\n", .{if (pi + 1 < n_proj) "," else ""});
            }
            try w.print("          }},\n          \"additivity\": {{ \"cpu\": {d:.3}, \"wall\": {d:.3} }}\n        }}", .{ additivity(cpu[li][mi]), additivity(wall[li][mi]) });
        }
        try w.print("\n      }}\n    }}{s}\n", .{if (oi + 1 < in.o.langs.len) "," else ""});
    }
    try w.writeAll("  }\n}\n");
    try Io.Dir.cwd().writeFile(in.io, .{ .sub_path = path, .data = json.written() });
    try in.out.print("compare: wrote {s}\n", .{path});

    try writeReadme(in, cpu, wall, name);
    return 0;
}

/// The README block (§13.2), generated whole: never edited by hand.
fn writeReadme(in: Input, cpu: Grid, wall: Grid, name: []const u8) !void {
    const a = in.a;
    var md: Io.Writer.Allocating = .init(a);
    try tables(in, &md.writer, cpu, wall, name);
    try in.out.writeAll(md.written());
    const readme_path = try std.fmt.allocPrint(a, "{s}/bench/compare/README.md", .{in.o.repo});
    const readme = try Io.Dir.cwd().readFileAlloc(in.io, readme_path, a, .limited(1 << 22));
    const begin = "<!-- compare:results:begin -->";
    const end = "<!-- compare:results:end -->";
    const b = std.mem.indexOf(u8, readme, begin) orelse return error.NoMarkers;
    const e = std.mem.indexOf(u8, readme, end) orelse return error.NoMarkers;
    const updated = try std.mem.concat(a, u8, &.{ readme[0 .. b + begin.len], "\n", md.written(), readme[e..] });
    try Io.Dir.cwd().writeFile(in.io, .{ .sub_path = readme_path, .data = updated });
}

/// `compare render --from=results/<name>.json` (§12): rewrite the README
/// block from a committed results file, with no compiler run, so a change
/// to how the tables are worded reaches the published numbers without
/// re-measuring them.
pub fn render(a: Allocator, io: Io, o: runner.Options, from: []const u8, out: *Io.Writer) !u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, from, a, .limited(1 << 26));
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
    const top = root.object;
    if (int(top.get("schema").?) != 2) return error.UnsupportedSchema;

    const generator = top.get("generator").?.object;
    var sizes: std.ArrayList(u32) = .empty;
    for (generator.get("sizes").?.array.items) |s| try sizes.append(a, @intCast(int(s)));
    var opts = o;
    opts.seed = try std.fmt.parseInt(u64, generator.get("seed").?.string, 0);
    opts.runs = @intCast(int(generator.get("runs").?));
    opts.generator_hash = generator.get("hash").?.string;
    const machine_obj = top.get("machine").?.object;
    opts.cpu = @intCast(int(machine_obj.get("cpu_pinned").?));
    const load = machine_obj.get("loadavg").?.object;
    const toolchain_obj = top.get("toolchain").?.object;

    var langs: std.ArrayList(Lang) = .empty;
    for (top.get("lang_order").?.array.items) |l| try langs.append(a, Lang.parse(l.string) orelse return error.UnknownLanguage);
    opts.langs = langs.items;

    var modes: std.ArrayList(Mode) = .empty;
    var points: std.ArrayList(impl.Point) = .empty;
    const langs_obj = top.get("langs").?.object;
    for (langs.items) |lang| {
        const modes_obj = langs_obj.get(@tagName(lang)).?.object.get("modes").?.object;
        for ([_]Mode{ .annotated, .inferred }) |mode| {
            const mode_obj = (modes_obj.get(@tagName(mode)) orelse continue).object;
            if (std.mem.indexOfScalar(Mode, modes.items, mode) == null) try modes.append(a, mode);
            const projects_obj = mode_obj.get("projects").?.object;
            for (impl.projects, 0..) |proj, pi| {
                const p = (projects_obj.get(proj.name()) orelse continue).object;
                const size_obj = p.get("size").?.object;
                const cpu_obj = p.get("cpu_samples").?.object;
                const wall_obj = p.get("wall_samples").?.object;
                const cte_obj = if (p.get("compile_time_evaluation_ms")) |v| v.object else null;
                for (sizes.items) |size| {
                    const key = try std.fmt.allocPrint(a, "{d}", .{size});
                    const st = size_obj.get(key).?.object;
                    var point: impl.Point = .{
                        .lang = lang,
                        .mode = mode,
                        .project = pi,
                        .size = size,
                        .dir = "",
                        .nodes = @intCast(int(st.get("nodes").?)),
                        .stats = .{
                            .tokens = @intCast(int(st.get("tokens").?)),
                            .lines = @intCast(int(st.get("lines").?)),
                            .annotations = @intCast(int(st.get("annotations").?)),
                            .explicit_type_args = @intCast(int(st.get("explicit_type_args").?)),
                            .invoked_arrows = @intCast(int(st.get("invoked_arrows").?)),
                            .modules = @intCast(int(st.get("modules").?)),
                        },
                        .roc_cte_ms = if (cte_obj) |c| float(c.get(key).?) else 0,
                    };
                    for (cpu_obj.get(key).?.array.items) |x| try point.cpu_samples.append(a, float(x));
                    for (wall_obj.get(key).?.array.items) |x| try point.samples.append(a, float(x));
                    try points.append(a, point);
                }
            }
        }
    }
    opts.modes = modes.items;

    const stem = std.fs.path.stem(from);
    const in: Input = .{
        .a = a,
        .io = io,
        .o = opts,
        .points = points.items,
        .unit_nodes = @splat(0),
        .sizes = sizes.items,
        .load_start = triple(load.get("start").?),
        .load_end = triple(load.get("end").?),
        .started = .zero,
        .offline = top.get("offline").?.bool,
        .versions = @splat(""),
        .out = out,
        .machine = .{ .cpu = machine_obj.get("cpu").?.string, .nproc = @intCast(int(machine_obj.get("nproc").?)), .kernel = machine_obj.get("kernel").?.string },
        .toolchain = .{
            .nixpkgs_compare_rev = toolchain_obj.get("nixpkgs_compare_rev").?.string,
            .zig = toolchain_obj.get("zig").?.string,
            .beni_commit = toolchain_obj.get("beni_commit").?.string,
            .beni_dirty = toolchain_obj.get("beni_dirty").?.bool,
            .roc_commit = toolchain_obj.get("roc_commit").?.string,
        },
    };
    // The samples were written rounded to two decimals, so a fit redone from
    // them can move a printed digit: the fits the run recorded replace it.
    // Those recorded to one more decimal than the table prints can still
    // round differently in their last digit.
    var cpu = grid(in, .cpu);
    var wall = grid(in, .wall);
    for (langs.items) |lang| {
        const li = @intFromEnum(lang);
        const modes_obj = langs_obj.get(@tagName(lang)).?.object.get("modes").?.object;
        for ([_]Mode{ .annotated, .inferred }, 0..) |mode, mi| {
            const mode_obj = (modes_obj.get(@tagName(mode)) orelse continue).object;
            const projects_obj = mode_obj.get("projects").?.object;
            for (impl.projects, 0..) |proj, pi| {
                const p = (projects_obj.get(proj.name()) orelse continue).object;
                if (cpu[li][mi][pi]) |*s| recorded(s, p.get("cpu").?.object);
                if (wall[li][mi][pi]) |*s| recorded(s, p.get("wall").?.object);
            }
        }
    }
    try writeReadme(in, cpu, wall, stem);
    return 0;
}

/// Replace a refit by the fit the run recorded, which it made before the
/// samples were rounded for the file.
fn recorded(s: *Series, fit_obj: std.json.ObjectMap) void {
    s.slope = float(fit_obj.get("slope_ms_per_unit").?);
    s.slope_min = float(fit_obj.get("slope_min").?);
    s.intercept = float(fit_obj.get("intercept_ms").?);
    s.r2 = float(fit_obj.get("r2").?);
    s.recorded_per1k = float(fit_obj.get("ms_per_1k_nodes").?);
}

fn int(v: std.json.Value) i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => unreachable,
    };
}

fn float(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch unreachable,
        else => unreachable,
    };
}

fn triple(v: std.json.Value) [3]f64 {
    const xs = v.array.items;
    return .{ float(xs[0]), float(xs[1]), float(xs[2]) };
}

/// Σ family slopes / total slope (§10.6).
fn additivity(s: [n_proj]?Series) f64 {
    var sum: f64 = 0;
    for (s[0 .. n_proj - 1]) |x| if (x) |y| {
        sum += y.slope;
    };
    const total = s[n_proj - 1] orelse return 0;
    return if (total.slope == 0) 0 else sum / total.slope;
}

fn tables(in: Input, w: *Io.Writer, cpu: Grid, wall: Grid, name: []const u8) !void {
    const langs = in.o.langs;
    const tot = n_proj - 1;
    try w.print("Run `{s}`: seed 0x{X}, sizes", .{ name, in.o.seed });
    for (in.sizes) |s| try w.print(" {d}", .{s});
    try w.print(", {d} runs per point, CPU {d} pinned, load {d:.1}→{d:.1} (1-min average), {s}. ", .{ in.o.runs, in.o.cpu, in.load_start[0], in.load_end[0], if (in.offline) "offline" else "ONLINE" });
    try w.print("The generator is `{s}`; the raw samples are in `results/{s}.json`. ", .{ in.o.generator_hash[0..@min(in.o.generator_hash.len, 19)], name });
    try w.writeAll("Times are **CPU time** (user + sys of the compiler and its children, from `wait4`); wall time is recorded beside it.\n\n");
    // 1. Totals.
    try w.writeAll("**Total** (every family, one unit of each): the slope is CPU milliseconds per added unit, the cost of 8 more modules.\n\n");
    try w.writeAll("| language | annotated ms/unit | ms/1k nodes | × beni | R² | wall ms/unit | inferred ms/unit | ms/1k nodes | × beni | R² | wall ms/unit |\n|---|---|---|---|---|---|---|---|---|---|---|\n");
    const beni_a = if (cpu[0][0][tot]) |s| s.per1k() else 0;
    const beni_i = if (cpu[0][1][tot]) |s| s.per1k() else 0;
    for (langs) |lang| {
        const li = @intFromEnum(lang);
        try w.print("| {s}{s} |", .{ langName(lang), if (lang == .typescript) "¹" else if (lang == .roc) "²" else "" });
        for ([_]usize{ 0, 1 }) |mi| {
            if (cpu[li][mi][tot]) |s| {
                const base = if (mi == 0) beni_a else beni_i;
                try w.print(" {d:.2} | {d:.3} | {d:.1}× | {d:.4} | {d:.2} |", .{ s.slope, s.per1k(), if (base == 0) 0 else s.per1k() / base, s.r2, wall[li][mi][tot].?.slope });
            } else try w.writeAll(" — | — | — | — | — |");
        }
        try w.writeAll("\n");
    }
    // What Roc's `check` spends its time on (§9, §10.7): a profile, dated
    // and disclosed, never a figure derived from Roc's `--timings`.
    const roc = @intFromEnum(Lang.roc);
    if (cpu[roc][0][tot] != null or cpu[roc][1][tot] != null) {
        try w.writeAll("\n² Roc's `check` command is");
        for ([_]usize{ 0, 1 }, 0..) |mi, i| if (cpu[roc][mi][tot]) |s| {
            const base = if (mi == 0) beni_a else beni_i;
            try w.print("{s} {d:.1}× beni's {s}", .{ if (i > 0) " and" else "", if (base == 0) 0 else s.per1k() / base, if (mi == 0) "annotated" else "inferred" });
        };
        try w.writeAll(", and most of that command is not type checking. " ++ roc_profile.split);
        if (!std.mem.startsWith(u8, in.toolchain.roc_commit, roc_profile.commit)) {
            try w.print(" This run measured Roc `{s}`, not the profiled commit.", .{in.toolchain.roc_commit[0..@min(in.toolchain.roc_commit.len, 7)]});
        }
        try w.writeAll("\n");
    }
    // 2 and 3. Per family, ms per 1 000 nodes.
    for ([_]usize{ 0, 1 }) |mi| {
        if (std.mem.indexOfScalar(Mode, in.o.modes, if (mi == 0) Mode.annotated else Mode.inferred) == null) continue;
        try w.print("\n**Per family, {s} mode**, CPU ms per 1 000 nodes (slope over the family's own projects; additivity is Σ families / total):\n\n| family |", .{if (mi == 0) "annotated" else "inferred"});
        for (langs) |lang| try w.print(" {s}{s} |", .{ langName(lang), if (lang == .typescript) "¹" else "" });
        try w.writeAll("\n|---|");
        for (langs) |_| try w.writeAll("---|");
        try w.writeAll("\n");
        for (0..n_proj) |pi| {
            try w.print("| {s} |", .{impl.projects[pi].name()});
            for (langs) |lang| {
                if (cpu[@intFromEnum(lang)][mi][pi]) |s| {
                    // Roc's recursion cell is mostly canonicalisation (²).
                    const flagged = lang == .roc and impl.projects[pi] == .family and impl.projects[pi].family == .recursion;
                    try w.print(" {d:.3}{s} |", .{ s.per1k(), if (flagged) "²" else "" });
                } else try w.writeAll(" — |");
            }
            try w.writeAll("\n");
        }
        try w.writeAll("| additivity |");
        for (langs) |lang| try w.print(" {d:.2} |", .{additivity(cpu[@intFromEnum(lang)][mi])});
        try w.writeAll("\n");
    }
    try w.writeAll("\n¹ TypeScript checks a different kind of program in its own idiom: structural assignability, no `Int`/`Float` split, parameters always annotated, and more annotations in the inferred mode than any other language (compare-bench.md §2.6, §6.3).\n\n");
    // Annotations actually written in the inferred mode, from the data.
    if (cpu[0][1][tot]) |bs| {
        const last = in.sizes.len - 1;
        const base = bs.points[last].?.stats.annotations;
        try w.print("Signatures and typed binders written in the inferred mode, total project at size {d}: {d} in beni, Elm, Gleam and Roc (Base and the entry points)", .{ in.sizes[last], base });
        if (cpu[@intFromEnum(Lang.purescript)][1][tot]) |ps| {
            const n = ps.points[last].?.stats.annotations;
            if (n == base) {
                try w.writeAll("; PureScript needed none beyond them at this seed (the signatures and binder types of compare-bench.md §19 V10 are written only where its classes would be ambiguous, and are counted when they are)");
            } else try w.print("; {d} in PureScript, whose {d} more are the signatures and binder types of compare-bench.md §19 V10", .{ n, n - base });
        }
        if (cpu[@intFromEnum(Lang.typescript)][1][tot]) |ts| try w.print("; {d} annotation sites in TypeScript (§6.3)", .{ts.points[last].?.stats.annotations});
        try w.writeAll(".\n\n");
    }
    // §10.6: an additivity outside 0.8–1.2 is flagged.
    for (langs) |lang| for ([_]usize{ 0, 1 }) |mi| {
        const x = additivity(cpu[@intFromEnum(lang)][mi]);
        if (x != 0 and (x < 0.8 or x > 1.2)) {
            try w.print("**Flagged (§10.6):** {s}'s additivity in the {s} mode is {d:.2}, outside 0.8–1.2: its family slopes do not sum to its total slope.", .{ langName(lang), if (mi == 0) "annotated" else "inferred", x });
            if (lang == .elm) try w.writeAll(" The cause is Elm's own runtime options (see *Caveats*): its per-family slopes are inflated by nursery first-touch faults, and its total row is unaffected.");
            try w.writeAll("\n\n");
        }
    };
}

/// Where Roc's `check` time goes, from a CPU profile (compare-bench.md §9,
/// §10.7). The runner does not measure this: it is one profile of one
/// commit, stated with its date and commit wherever it is printed.
const roc_profile = struct {
    const commit = "a3ce7f1";
    const split =
        "Profiled on 2026-09-28 at Roc `a3ce7f1`, on the total project at size 16, its time splits into " ++
        "about 33% type inference and exhaustiveness (about 28 ms per unit, 5.5× beni), " ++
        "39% publishing a hashed checked-module artifact for its monomorphising native backend " ++
        "(`CheckedTypeStore.fromModule` and its helpers, which `check` always does), " ++
        "13% canonicalisation, 10% lowering, native code generation and compile-time evaluation, and 2% parsing. " ++
        "Roc's own `--timings` counts the publishing as *Type Checking*, so no figure here is derived from it. " ++
        "**The recursion family is flagged:** there canonicalisation, mostly its dependency graph, is 52% of Roc's time, " ++
        "so Roc's recursion column measures its dependency analysis more than its type checking (compare-bench.md §9, §10.7).";
};

fn langName(l: Lang) []const u8 {
    return switch (l) {
        .beni => "beni",
        .elm => "Elm",
        .gleam => "Gleam",
        .roc => "Roc",
        .purescript => "PureScript",
        .typescript => "TypeScript",
    };
}

fn dateOf(t: Io.Timestamp) [10]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(t.toSeconds()) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    var buf: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), @as(u32, md.day_index) + 1 }) catch unreachable;
    return buf;
}

fn isoOf(t: Io.Timestamp) [20]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(t.toSeconds()) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var buf: [20]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yd.year, md.month.numeric(), @as(u32, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() }) catch unreachable;
    return buf;
}
