//! The cross-language type-checking benchmark (docs/design/compare-bench.md).
//!
//!   compare gen   [--seed=S] [--size=K] [--families=a,b] [--langs=x,y] [--annotate=P] [--out=DIR]
//!   compare run   [--prepare] [--seed=S] [--sizes=1,2,4,8,16] [--runs=5] [--langs=…]
//!                 [--modes=annotated,inferred] [--cpu=2] [--quick] [--label=…] [--online]
//!                 [--timeout=300]
//!   compare smoke size 1, both modes, one untimed run: acceptance only
//!   compare render --from=FILE  rewrite the README tables from a results file
//!
//! `zig build compare-gen`, `zig build compare` and `zig build compare-smoke`
//! run these (§12). The generator does not import `src/`, and `src/` does not
//! import it (§3.1).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Tree = @import("Tree.zig");
const gen = @import("gen.zig");
const print = @import("print/print.zig");
const runner = @import("runner.zig");
const build_options = @import("compare_options");

pub const roc_commit = "a3ce7f1bb784b6cb0c3f5f05acd2cd8a762ed3e0";

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try stderr.writeAll("usage: compare gen|run|smoke [options] (docs/design/compare-bench.md §12)\n");
        return 2;
    }
    const cmd = args[1];
    var opts = runner.parseOptions(arena, args[2..]) catch |err| {
        try stderr.print("compare: bad arguments ({t})\n", .{err});
        return 2;
    };
    opts.generator_hash = build_options.generator_hash;
    opts.beni = build_options.beni_exe;
    opts.repo = build_options.repo_root;
    opts.roc_commit = roc_commit;
    if (std.mem.eql(u8, cmd, "gen")) {
        return genCommand(gpa, io, arena, opts, stdout, stderr);
    } else if (std.mem.eql(u8, cmd, "run")) {
        return runner.run(gpa, io, arena, opts, stdout, stderr, init.environ_map);
    } else if (std.mem.eql(u8, cmd, "smoke")) {
        opts.smoke = true;
        return runner.run(gpa, io, arena, opts, stdout, stderr, init.environ_map);
    } else if (std.mem.eql(u8, cmd, "render")) {
        const from = opts.from orelse {
            try stderr.writeAll("compare render: needs --from=<results file>\n");
            return 2;
        };
        return @import("report.zig").render(arena, io, opts, from, stdout);
    }
    try stderr.print("compare: unknown command {s}\n", .{cmd});
    return 2;
}

/// `compare gen`: one project per language into `--out` (§12).
fn genCommand(gpa: Allocator, io: Io, arena: Allocator, opts: runner.Options, stdout: *Io.Writer, stderr: *Io.Writer) !u8 {
    _ = gpa;
    if (opts.golden) {
        const golden = @import("print/golden_test.zig");
        const prog = try golden.program(arena);
        for (print.Lang.all) |lang| {
            const path = try std.fmt.allocPrint(arena, "{s}/bench/compare/gen/print/golden/{t}.txt", .{ opts.repo, lang });
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try golden.render(arena, &prog, lang) });
            try stdout.print("wrote {s}\n", .{path});
        }
        return 0;
    }
    const out_dir = opts.out orelse try std.fs.path.join(arena, &.{ opts.repo, "bench/compare/work/gen" });
    var diag: Io.Writer.Allocating = .init(arena);
    const prog = gen.generate(arena, .{ .seed = opts.seed, .size = opts.size, .families = opts.families, .annotate = opts.annotate }, &diag.writer) catch |err| {
        try stderr.print("compare gen: seed 0x{X}: {s}\n", .{ opts.seed, diag.written() });
        return err;
    };
    var nodes: u64 = 0;
    for (prog.info.sizes) |s| nodes += s.nodes;
    try stdout.print("seed 0x{X}, size {d}, annotate {d}: {d} modules, {d} nodes\n", .{ opts.seed, opts.size, opts.annotate, prog.tree.modules.items.len, nodes });
    if (opts.size == 1) for (prog.tree.modules.items, prog.info.sizes) |m, s| try stdout.print("    {s:<8} {d:>6} nodes {d:>4} decls {d:>4} case leaves\n", .{ m.name, s.nodes, s.decls, s.leaves });
    for (opts.langs) |lang| {
        const dir_path = try std.fs.path.join(arena, &.{ out_dir, @tagName(lang) });
        Io.Dir.cwd().deleteTree(io, dir_path) catch {};
        var dir = try Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
        defer dir.close(io);
        const st = try print.project(arena, io, dir, &prog, lang);
        try stdout.print("  {s:<10} {d:>8} tokens {d:>7} lines  {d} annotations  {d} explicit type args  {d} invoked arrows  -> {s}\n", .{ @tagName(lang), st.tokens, st.lines, st.annotations, st.explicit_type_args, st.invoked_arrows, dir_path });
    }
    return 0;
}

test {
    _ = @import("Rng.zig");
    _ = @import("Type.zig");
    _ = @import("Tree.zig");
    _ = @import("names.zig");
    _ = @import("gen.zig");
    _ = @import("validate_test.zig");
    _ = @import("print/count.zig");
    _ = @import("print/golden_test.zig");
    _ = @import("fit.zig");
}
