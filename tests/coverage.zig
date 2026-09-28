//! Which lines of the compiler the black-box tests execute: `zig build
//! coverage`.
//!
//!   coverage --exe=E --hits=H --src=S --out=O [--top=N] -- <command...>
//!   coverage --exe=E --hits=H --src=S --out=O [--top=N] --report-only
//!
//! `E` is the compiler the command's tests spawn, built with LLVM's
//! SanitizerCoverage `trace-pc-guard` instrumentation around
//! `tests/coverage/runtime.zig`: every process of it records each guarded
//! block the first time it runs, as one byte in the shared hits file `H`.
//!
//! The first form deletes `H`, runs the command (a child `zig build
//! coverage-run`, whose black-box suites and corpus spawn `E`; the unit
//! tests do not run), measures its wall and CPU time, then reports whatever
//! was collected — also when a test failed. `--report-only` reports what
//! `H` holds without running anything (`zig build coverage --
//! --report-only`; the command, which the build step always passes, is
//! then ignored).
//!
//! The report maps what ran to lines of `S`:
//!
//!   1. `E`'s symbol table gives its functions, and each is decoded
//!      (`coverage/x86.zig`) into a control-flow graph
//!      (`coverage/cfg.zig`), in which every call of the coverage callback
//!      names its guard: a guard that is set in `H` proves its block ran.
//!   2. Blocks LLVM left unguarded are inferred from those that ran, by
//!      dominance and post-dominance only (`coverage/cfg.zig` has the
//!      rules and what they assume).
//!   3. The DWARF line table maps addresses to lines: a line is covered
//!      when a block holding one of its rows ran, and counted when it has
//!      any row. A line the optimiser folded away has none, and is in
//!      neither count.
//!
//! It writes `O/summary.md` — the total, a row per directory under `src/`
//! and one per file — and `O/lcov.info`, which `genhtml` turns into a
//! browsable report. Every figure leaves out the tests' own lines: files
//! named `*_test.zig` and the lines of `test` blocks. A covered line is one
//! that ran, not one whose effect a test checked.
//!
//! Exits with the command's exit code, after reporting what was collected.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const elf = std.elf;
const Dwarf = std.debug.Dwarf;
const cfg = @import("coverage/cfg.zig");

const usage =
    \\usage: coverage --exe=E --hits=H --src=S --out=O [--top=N] -- <command...>
    \\       coverage --exe=E --hits=H --src=S --out=O [--top=N] --report-only
    \\
;

/// The hits file's header: a 64-bit count of the processes that mapped it
/// (`coverage/runtime.zig`).
const hits_header_len = 8;

const Options = struct {
    exe: []const u8 = "",
    hits: []const u8 = "",
    src: []const u8 = "",
    out: []const u8 = "",
    /// How many files the "most uncovered" list names.
    top: usize = 10,
    report_only: bool = false,
    command: []const []const u8 = &.{},
};

/// What was measured around the command.
const Measured = struct {
    wall_us: u64 = 0,
    cpu_us: u64 = 0,
    load_start: ?[3]f64 = null,
    load_end: ?[3]f64 = null,
    exit: i32 = 0,
    ran: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            options.command = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, arg, "--report-only")) {
            options.report_only = true;
        } else if (value(arg, "--exe=")) |v| {
            options.exe = v;
        } else if (value(arg, "--hits=")) |v| {
            options.hits = v;
        } else if (value(arg, "--src=")) |v| {
            options.src = v;
        } else if (value(arg, "--out=")) |v| {
            options.out = v;
        } else if (value(arg, "--top=")) |v| {
            options.top = std.fmt.parseUnsigned(usize, v, 10) catch {
                try stderr.print("coverage: bad --top: {s}\n", .{arg});
                return 2;
            };
        } else {
            try stderr.print("coverage: unknown argument {s}\n{s}", .{ arg, usage });
            return 2;
        }
    }
    if (options.exe.len == 0 or options.hits.len == 0 or options.src.len == 0 or options.out.len == 0 or
        (options.command.len == 0 and !options.report_only))
    {
        try stderr.writeAll(usage);
        return 2;
    }

    const cwd = Io.Dir.cwd();
    var measured: Measured = .{};
    if (!options.report_only) {
        cwd.deleteFile(io, options.hits) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        if (std.fs.path.dirname(options.hits)) |dir| try cwd.createDirPath(io, dir);
        measured = try runCommand(arena, io, init.environ_map, options, stderr);
    }

    const hits = cwd.readFileAlloc(io, options.hits, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("coverage: nothing was collected: {s} does not exist\n", .{options.hits});
            return if (measured.exit != 0) 1 else 2;
        },
        else => return err,
    };
    const started = Io.Clock.awake.now(io);
    const analysis = analyse(arena, io, options, hits) catch |err| {
        try stderr.print("coverage: cannot map {s} to lines of {s}: {t}\n", .{ options.exe, options.src, err });
        return 2;
    };
    try stderr.print("coverage: mapped {d} blocks to lines in {d:.1} s\n", .{
        analysis.stats.blocks,
        @as(f64, @floatFromInt(durationUs(started.durationTo(Io.Clock.awake.now(io))))) / std.time.us_per_s,
    });
    const files = try tally(arena, io, options.src, analysis.lines);

    try cwd.deleteTree(io, options.out);
    try cwd.createDirPath(io, options.out);
    const markdown = try render(arena, files, measured, analysis.stats, options);
    const summary_path = try std.fs.path.join(arena, &.{ options.out, "summary.md" });
    try cwd.writeFile(io, .{ .sub_path = summary_path, .data = markdown.full });
    const lcov_path = try std.fs.path.join(arena, &.{ options.out, "lcov.info" });
    try cwd.writeFile(io, .{ .sub_path = lcov_path, .data = try renderLcov(arena, options.src, files) });
    try stderr.writeAll(markdown.terminal);
    try stderr.print("coverage: per-file table at {s}; `genhtml -o {s}/html {s}` for HTML\n", .{ summary_path, options.out, lcov_path });

    if (measured.exit != 0) {
        try stderr.print("coverage: `{s}` exited {d}; the report covers what ran\n", .{ options.command[0], measured.exit });
        return 1;
    }
    return 0;
}

fn value(arg: []const u8, comptime prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, arg, prefix)) arg[prefix.len..] else null;
}

/// Run the command with the terminal as its output, and measure it.
fn runCommand(arena: Allocator, io: Io, parent_env: *const std.process.Environ.Map, options: Options, stderr: *Io.Writer) !Measured {
    var measured: Measured = .{ .ran = true, .load_start = loadAverage(arena, io) };
    var env = try parent_env.clone(arena);
    // The command reports its own progress to the terminal, not to a
    // progress pipe this process was handed.
    _ = env.swapRemove("ZIG_PROGRESS");

    try stderr.print("coverage: running `{s}` on the instrumented compiler\n", .{try std.mem.join(arena, " ", options.command)});
    try stderr.flush();
    const started = Io.Clock.awake.now(io);
    var child = try std.process.spawn(io, .{
        .argv = options.command,
        .environ_map = &env,
        .request_resource_usage_statistics = true,
    });
    const term = try child.wait(io);
    measured.wall_us = durationUs(started.durationTo(Io.Clock.awake.now(io)));
    measured.load_end = loadAverage(arena, io);
    measured.exit = switch (term) {
        .exited => |code| code,
        else => -1,
    };
    if (comptime @TypeOf(child.resource_usage_statistics.rusage) == ?std.posix.rusage) {
        if (child.resource_usage_statistics.rusage) |ru| {
            measured.cpu_us = tvUs(ru.utime) + tvUs(ru.stime);
        }
    }
    return measured;
}

fn tvUs(tv: std.posix.timeval) u64 {
    return @as(u64, @intCast(tv.sec)) * std.time.us_per_s + @as(u64, @intCast(tv.usec));
}

fn durationUs(d: Io.Duration) u64 {
    return @intCast(@divFloor(d.nanoseconds, std.time.ns_per_us));
}

/// How the blocks were accounted for.
const Stats = struct {
    processes: u64 = 0,
    functions: u64 = 0,
    /// Functions whose graph could not be trusted, so nothing was inferred
    /// in them.
    unsound_functions: u64 = 0,
    blocks: u64 = 0,
    guards: u64 = 0,
    guards_hit: u64 = 0,
    /// Blocks a set guard proved ran, and blocks the rules added.
    blocks_guarded_ran: u64 = 0,
    blocks_inferred: u64 = 0,
    /// Calls of the coverage callback whose guard was not found.
    unmatched_sites: u64 = 0,
};

/// For each line of one file, what the line table and the blocks say.
const LineState = enum(u2) {
    /// No row: no code, or code the optimiser folded away.
    none,
    /// Code, none of which ran.
    code,
    /// Code, some of which ran.
    ran,
};

const Analysis = struct {
    stats: Stats,
    /// Every file under the source directory that has a row, relative to
    /// it, with its lines' states (line `n` at index `n - 1`).
    lines: std.StringArrayHashMapUnmanaged(std.ArrayList(LineState)),
};

/// Everything the report reads from the binary.
const Binary = struct {
    image: cfg.Image,
    /// The functions, ascending, none overlapping.
    functions: []Function,
    dwarf: Dwarf,

    const Function = struct { address: u64, code: []const u8 };
};

fn loadBinary(arena: Allocator, io: Io, path: []const u8) !Binary {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    if (bytes.len < @sizeOf(elf.Elf64.Ehdr)) return error.NotAnElfFile;
    const header = std.mem.bytesToValue(elf.Elf64.Ehdr, bytes[0..@sizeOf(elf.Elf64.Ehdr)]);
    if (!std.mem.eql(u8, header.ident[0..4], elf.MAGIC) or header.ident[elf.EI.CLASS] != elf.ELFCLASS64 or
        header.ident[elf.EI.DATA] != elf.ELFDATA2LSB or header.machine != .X86_64) return error.NotAnX8664ElfFile;

    const shdr_size = @sizeOf(elf.Elf64.Shdr);
    if (header.shoff + @as(u64, header.shnum) * shdr_size > bytes.len) return error.TruncatedElfFile;
    const shdrs = try arena.alloc(elf.Elf64.Shdr, header.shnum);
    for (shdrs, 0..) |*s, k| s.* = std.mem.bytesToValue(elf.Elf64.Shdr, bytes[header.shoff + k * shdr_size ..][0..shdr_size]);
    const names = try sectionBytes(bytes, shdrs[header.shstrndx]);

    var binary: Binary = .{
        .image = .{ .callback = 0, .guards = 0, .guard_count = 0, .data = &.{} },
        .functions = &.{},
        .dwarf = .{},
    };
    var segments: std.ArrayList(cfg.Image.Segment) = .empty;
    var symtab: ?elf.Elf64.Shdr = null;
    var found_guards = false;
    for (shdrs) |s| {
        const name = std.mem.sliceTo(names[@min(s.name, names.len)..], 0);
        if (std.mem.eql(u8, name, "__sancov_guards")) {
            binary.image.guards = s.addr;
            binary.image.guard_count = s.size / 4;
            found_guards = true;
        } else if (s.type == .SYMTAB) {
            symtab = s;
        } else if (s.flags.shf.ALLOC and !s.flags.shf.EXECINSTR and s.type != .NOBITS and !s.flags.shf.TLS) {
            try segments.append(arena, .{ .address = s.addr, .bytes = try sectionBytes(bytes, s) });
        } else if (std.mem.startsWith(u8, name, ".debug_")) {
            inline for (@typeInfo(Dwarf.Section.Id).@"enum".fields) |field| {
                if (std.mem.eql(u8, name[1..], field.name)) {
                    binary.dwarf.sections[field.value] = .{ .data = try sectionBytes(bytes, s), .owned = false };
                }
            }
        }
    }
    binary.image.data = segments.items;
    if (!found_guards) return error.NotInstrumented;
    const symbols = symtab orelse return error.NoSymbolTable;
    if (symbols.link >= shdrs.len) return error.NoSymbolTable;
    const strings = try sectionBytes(bytes, shdrs[symbols.link]);
    const symbol_bytes = try sectionBytes(bytes, symbols);

    var functions: std.ArrayList(Binary.Function) = .empty;
    const sym_size = @sizeOf(elf.Elf64.Sym);
    var k: usize = 0;
    while (k + sym_size <= symbol_bytes.len) : (k += sym_size) {
        const sym = std.mem.bytesToValue(elf.Elf64.Sym, symbol_bytes[k..][0..sym_size]);
        if (sym.info.type != .FUNC or sym.shndx == 0 or sym.shndx >= shdrs.len) continue;
        const section = shdrs[sym.shndx];
        if (!section.flags.shf.EXECINSTR) continue;
        const name = std.mem.sliceTo(strings[@min(sym.name, strings.len)..], 0);
        if (std.mem.eql(u8, name, "__sanitizer_cov_trace_pc_guard")) binary.image.callback = sym.value;
        if (sym.size == 0 or sym.value < section.addr or sym.value + sym.size > section.addr + section.size) continue;
        const code = try sectionBytes(bytes, section);
        try functions.append(arena, .{ .address = sym.value, .code = code[sym.value - section.addr ..][0..sym.size] });
    }
    if (binary.image.callback == 0) return error.NoCoverageCallback;
    // Ascending; of several symbols at one address the largest; none that
    // starts inside the one before it.
    std.mem.sort(Binary.Function, functions.items, {}, struct {
        fn lessThan(_: void, a: Binary.Function, b: Binary.Function) bool {
            if (a.address != b.address) return a.address < b.address;
            return a.code.len > b.code.len;
        }
    }.lessThan);
    var kept: usize = 0;
    for (functions.items) |f| {
        if (kept != 0) {
            const last = functions.items[kept - 1];
            if (f.address < last.address + last.code.len) continue;
        }
        functions.items[kept] = f;
        kept += 1;
    }
    binary.functions = functions.items[0..kept];
    var no_return: std.ArrayList(u64) = .empty;
    for (binary.functions) |f| {
        if (!cfg.returns(f.address, f.code)) try no_return.append(arena, f.address);
    }
    binary.image.no_return = no_return.items;
    return binary;
}

fn sectionBytes(bytes: []const u8, s: elf.Elf64.Shdr) ![]const u8 {
    if (s.type == .NOBITS) return &.{};
    if (s.offset + s.size > bytes.len) return error.TruncatedElfFile;
    return bytes[s.offset..][0..s.size];
}

/// Every block of the binary, ascending, and whether it ran.
const Blocks = struct {
    starts: std.ArrayList(u64) = .empty,
    ends: std.ArrayList(u64) = .empty,
    ran: std.ArrayList(bool) = .empty,

    /// Whether the block holding `address` ran, or null when no function's
    /// block holds it.
    fn at(blocks: Blocks, address: u64) ?bool {
        const starts = blocks.starts.items;
        var lo: usize = 0;
        var hi: usize = starts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (starts[mid] <= address) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        if (address >= blocks.ends.items[lo - 1]) return null;
        return blocks.ran.items[lo - 1];
    }
};

fn analyse(arena: Allocator, io: Io, options: Options, hits_file: []const u8) !Analysis {
    var binary = try loadBinary(arena, io, options.exe);
    const guard_count = binary.image.guard_count;
    if (hits_file.len != hits_header_len + guard_count) return error.HitsFileIsFromAnotherBuild;
    const hits = hits_file[hits_header_len..];
    var stats: Stats = .{
        .processes = std.mem.readInt(u64, hits_file[0..hits_header_len], .little),
        .functions = binary.functions.len,
        .guards = guard_count,
    };
    for (hits) |h| stats.guards_hit += @intFromBool(h != 0);

    // Blocks, one function at a time in a scratch arena.
    var blocks: Blocks = .{};
    var scratch_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch_state.deinit();
    for (binary.functions) |f| {
        _ = scratch_state.reset(.retain_capacity);
        const scratch = scratch_state.allocator();
        const graph = try cfg.build(scratch, binary.image, f.address, f.code);
        stats.unsound_functions += @intFromBool(!graph.sound);
        stats.unmatched_sites += graph.unmatched_sites;
        const ran = try scratch.alloc(bool, graph.blockCount());
        @memset(ran, false);
        for (graph.sites) |site| {
            if (hits[site.guard] != 0) ran[site.block] = true;
        }
        for (ran) |r| stats.blocks_guarded_ran += @intFromBool(r);
        try cfg.infer(scratch, graph, ran);
        for (graph.starts, 0..) |start, b| {
            try blocks.starts.append(arena, start);
            try blocks.ends.append(arena, if (b + 1 < graph.starts.len) graph.starts[b + 1] else graph.end);
            try blocks.ran.append(arena, ran[b]);
            stats.blocks_inferred += @intFromBool(ran[b]);
        }
    }
    stats.blocks_inferred -= stats.blocks_guarded_ran;
    stats.blocks = blocks.starts.items.len;

    // Lines.
    try binary.dwarf.open(arena, .little);
    var lines: std.StringArrayHashMapUnmanaged(std.ArrayList(LineState)) = .empty;
    const src_prefix = try srcPrefix(arena, &binary.dwarf, options.src);
    for (binary.dwarf.compile_unit_list.items) |*cu| {
        binary.dwarf.populateSrcLocCache(arena, .little, cu) catch |err| switch (err) {
            error.MissingDebugInfo => continue,
            else => return err,
        };
        const slc = &cu.src_loc_cache.?;
        // Each file of the unit: its line states, when it is under `src/`.
        const file_lines = try arena.alloc(?usize, slc.files.len);
        for (slc.files, file_lines) |file, *slot| {
            slot.* = null;
            const path = try filePath(arena, slc, file);
            if (!std.mem.startsWith(u8, path, src_prefix)) continue;
            const entry = try lines.getOrPut(arena, path[src_prefix.len..]);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            slot.* = entry.index;
        }
        const offset: u32 = @intFromBool(slc.version < 5);
        for (slc.line_table.keys(), slc.line_table.values()) |address, row| {
            if (row.line == 0 or row.file < offset or row.file - offset >= file_lines.len) continue;
            const list = &lines.values()[file_lines[row.file - offset] orelse continue];
            const ran = blocks.at(address) orelse continue;
            if (list.items.len < row.line) try list.appendNTimes(arena, .none, row.line - list.items.len);
            const state = &list.items[row.line - 1];
            state.* = if (ran or state.* == .ran) .ran else .code;
        }
    }
    return .{ .stats = stats, .lines = lines };
}

/// The binary's source directory, with a trailing slash: where the root
/// source file `main.zig` was when the binary was built. That is `src`
/// unless the build cache handed over a binary another checkout of the
/// same sources compiled.
fn srcPrefix(arena: Allocator, dwarf: *Dwarf, src: []const u8) ![]const u8 {
    const own = try std.fmt.allocPrint(arena, "{s}/", .{src});
    for (dwarf.compile_unit_list.items) |*cu| {
        dwarf.populateSrcLocCache(arena, .little, cu) catch continue;
        const slc = &cu.src_loc_cache.?;
        var fallback: ?[]const u8 = null;
        for (slc.files) |file| {
            const path = try filePath(arena, slc, file);
            if (std.mem.startsWith(u8, path, own)) return own;
            if (std.mem.endsWith(u8, path, "/src/main.zig")) fallback = path[0 .. path.len - "main.zig".len];
        }
        if (fallback) |p| return p;
    }
    return own;
}

fn filePath(arena: Allocator, slc: *const Dwarf.CompileUnit.SrcLocCache, file: anytype) ![]const u8 {
    if (std.fs.path.isAbsolute(file.path) or file.dir_index >= slc.directories.len) return file.path;
    return std.fs.path.join(arena, &.{ slc.directories[file.dir_index].path, file.path });
}

/// One source file's lines as the report counts them.
const File = struct {
    /// Relative to `src/`.
    path: []const u8,
    /// Lines with code, and how many of them ran.
    total: u32,
    covered: u32,
    /// Each line's state, test lines already set to `none`.
    lines: []const LineState,

    fn uncovered(f: File) u32 {
        return f.total - f.covered;
    }
};

/// Every file with a counted line, the tests' own lines taken out, sorted
/// by path.
fn tally(arena: Allocator, io: Io, src: []const u8, lines: std.StringArrayHashMapUnmanaged(std.ArrayList(LineState))) ![]File {
    var files: std.ArrayList(File) = .empty;
    for (lines.keys(), lines.values()) |path, list| {
        if (std.mem.endsWith(u8, path, "_test.zig")) continue;
        const full = try std.fs.path.join(arena, &.{ src, path });
        const source = Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const file = tallyFile(path, list.items, try testLines(arena, source));
        if (file.total != 0) try files.append(arena, file);
    }
    std.mem.sort(File, files.items, {}, struct {
        fn lessThan(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return files.items;
}

/// The lines of one file that are not in `test_lines`, and how many of
/// them ran; `states` is changed to leave the test lines out.
/// `test_lines` has an entry for every line of the source, and a line past
/// its end is left out too: the line table names a few, for code the
/// compiler generated.
fn tallyFile(path: []const u8, all_states: []LineState, test_lines: []const bool) File {
    const states = all_states[0..@min(all_states.len, test_lines.len)];
    var file: File = .{ .path = path, .total = 0, .covered = 0, .lines = states };
    for (states, 0..) |*state, index| {
        if (test_lines[index]) state.* = .none;
        if (state.* == .none) continue;
        file.total += 1;
        if (state.* == .ran) file.covered += 1;
    }
    return file;
}

/// For each line of `source`, whether it belongs to a `test` block: from a
/// line that opens one to the line that closes it at the same indentation,
/// which `zig fmt` guarantees.
pub fn testLines(arena: Allocator, source: []const u8) ![]bool {
    var count: usize = 1;
    for (source) |c| count += @intFromBool(c == '\n');
    const marks = try arena.alloc(bool, count);
    @memset(marks, false);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var index: usize = 0;
    var closing: ?[]const u8 = null;
    while (lines.next()) |line| : (index += 1) {
        const trimmed = std.mem.trimEnd(u8, line, " \r");
        if (closing) |indent| {
            marks[index] = true;
            if (trimmed.len == indent.len + 1 and std.mem.startsWith(u8, trimmed, indent) and trimmed[indent.len] == '}') closing = null;
            continue;
        }
        const body = std.mem.trimStart(u8, trimmed, " ");
        const opens = std.mem.startsWith(u8, body, "test ") or std.mem.startsWith(u8, body, "test{");
        if (opens and std.mem.endsWith(u8, body, "{")) {
            marks[index] = true;
            closing = trimmed[0 .. trimmed.len - body.len];
        }
    }
    return marks;
}

/// The files in the lcov tracefile format `genhtml` reads: one record per
/// file, a `DA` line per counted line with 1 for ran and 0 for not.
fn renderLcov(arena: Allocator, src: []const u8, files: []const File) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("TN:\n");
    for (files) |f| {
        try w.print("SF:{s}/{s}\n", .{ src, f.path });
        for (f.lines, 1..) |state, line| {
            if (state == .none) continue;
            try w.print("DA:{d},{d}\n", .{ line, @intFromBool(state == .ran) });
        }
        try w.print("LF:{d}\nLH:{d}\nend_of_record\n", .{ f.total, f.covered });
    }
    return out.written();
}

const Rendered = struct {
    /// `summary.md`: the headline, the directory table and every file.
    full: []const u8,
    /// What the terminal gets: the headline, the directory table and the
    /// files with the most uncovered lines.
    terminal: []const u8,
};

/// A line count and how many of it ran.
const Tally = struct {
    total: u64 = 0,
    covered: u64 = 0,

    fn add(t: *Tally, f: File) void {
        t.total += f.total;
        t.covered += f.covered;
    }

    fn percent(t: Tally) f64 {
        if (t.total == 0) return 0;
        return 100.0 * @as(f64, @floatFromInt(t.covered)) / @as(f64, @floatFromInt(t.total));
    }
};

/// The top-level directory under `src/` a file belongs to, or `.` for a
/// file directly in it.
fn topDirectory(path: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return ".";
    return path[0..slash];
}

fn render(arena: Allocator, files: []const File, measured: Measured, stats: Stats, options: Options) !Rendered {
    var total: Tally = .{};
    var dirs: std.StringArrayHashMapUnmanaged(Tally) = .empty;
    for (files) |f| {
        total.add(f);
        const entry = try dirs.getOrPut(arena, topDirectory(f.path));
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.add(f);
    }
    const Dir = struct { name: []const u8, tally: Tally };
    var dir_list: std.ArrayList(Dir) = .empty;
    for (dirs.keys(), dirs.values()) |name, t| try dir_list.append(arena, .{ .name = name, .tally = t });
    std.mem.sort(Dir, dir_list.items, {}, struct {
        fn lessThan(_: void, a: Dir, b: Dir) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    const by_uncovered = try arena.dupe(File, files);
    std.mem.sort(File, by_uncovered, {}, struct {
        fn lessThan(_: void, a: File, b: File) bool {
            if (a.uncovered() != b.uncovered()) return a.uncovered() > b.uncovered();
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    var head: Io.Writer.Allocating = .init(arena);
    const h = &head.writer;
    try h.print("Line coverage of src/: {d:.1}% ({d} of {d} lines)\n\n", .{ total.percent(), total.covered, total.total });
    try h.print("Collected from {d} compiler processes", .{stats.processes});
    if (measured.ran) {
        try h.print(" in {d:.1} s wall, {d:.0} CPU-s", .{
            @as(f64, @floatFromInt(measured.wall_us)) / std.time.us_per_s,
            @as(f64, @floatFromInt(measured.cpu_us)) / std.time.us_per_s,
        });
        if (measured.load_start) |l| try h.print("; load average {d:.1} at the start", .{l[0]});
        if (measured.load_end) |l| try h.print(", {d:.1} at the end", .{l[0]});
    }
    try h.writeAll(".\n");
    try h.print(
        "{d} of {d} guards set; of {d} blocks in {d} functions, {d} ran by their guard and {d} more by inference; " ++
            "{d} functions without a trusted graph, {d} guarded calls without a known guard.\n\n",
        .{ stats.guards_hit, stats.guards, stats.blocks, stats.functions, stats.blocks_guarded_ran, stats.blocks_inferred, stats.unsound_functions, stats.unmatched_sites },
    );
    try h.writeAll("| Directory | Lines | Covered | % |\n|---|---:|---:|---:|\n");
    for (dir_list.items) |d| {
        try h.print("| {s} | {d} | {d} | {d:.1} |\n", .{ d.name, d.tally.total, d.tally.covered, d.tally.percent() });
    }
    try h.print("| **total** | {d} | {d} | {d:.1} |\n\n", .{ total.total, total.covered, total.percent() });

    var term: Io.Writer.Allocating = .init(arena);
    try term.writer.writeAll(head.written());
    try term.writer.print("The {d} files with the most uncovered lines:\n\n| File | Uncovered | Lines | % |\n|---|---:|---:|---:|\n", .{@min(options.top, by_uncovered.len)});
    for (by_uncovered[0..@min(options.top, by_uncovered.len)]) |f| {
        try term.writer.print("| {s} | {d} | {d} | {d:.1} |\n", .{ f.path, f.uncovered(), f.total, (Tally{ .total = f.total, .covered = f.covered }).percent() });
    }
    try term.writer.writeAll("\n");

    var full: Io.Writer.Allocating = .init(arena);
    const w = &full.writer;
    try w.writeAll(
        \\# Line coverage
        \\
        \\Generated by `zig build coverage` (`tests/coverage.zig`): the lines of
        \\`src/` that some `beni` process spawned by the black-box suites or the
        \\corpus ran. The unit tests are not measured. A covered line is one that
        \\ran, not one whose effect a test checked.
        \\Files named `*_test.zig` and the lines of `test` blocks are left out.
        \\
        \\
    );
    try w.writeAll(head.written());
    try w.writeAll("## Every file\n\n| File | Lines | Covered | Uncovered | % |\n|---|---:|---:|---:|---:|\n");
    for (files) |f| {
        try w.print("| {s} | {d} | {d} | {d} | {d:.1} |\n", .{ f.path, f.total, f.covered, f.uncovered(), (Tally{ .total = f.total, .covered = f.covered }).percent() });
    }
    return .{ .full = full.written(), .terminal = term.written() };
}

/// `/proc/loadavg`'s three averages, or null where there is none.
fn loadAverage(arena: Allocator, io: Io) ?[3]f64 {
    const file = Io.Dir.cwd().openFile(io, "/proc/loadavg", .{}) catch return null;
    defer file.close(io);
    var buffer: [256]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const text = reader.interface.allocRemaining(arena, .limited(4096)) catch return null;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    var out: [3]f64 = undefined;
    for (&out) |*v| v.* = std.fmt.parseFloat(f64, words.next() orelse return null) catch return null;
    return out;
}

test {
    _ = cfg;
}

test "a file counts its lines with code and those that ran, leaving out the tests' lines and lines past its end" {
    // The sixth line is past the end of the five-line source.
    var states = [_]LineState{ .ran, .code, .none, .ran, .code, .ran };
    const file = tallyFile("lex/A.zig", &states, &.{ false, false, false, true, true });
    try std.testing.expectEqual(@as(u32, 2), file.total);
    try std.testing.expectEqual(@as(u32, 1), file.covered);
    try std.testing.expectEqualSlices(LineState, &.{ .ran, .code, .none, .none, .none }, file.lines);
}

test "the lines of a test block are marked, and nothing else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const marks = try testLines(arena.allocator(),
        \\fn f() void {}
        \\test "f" {
        \\    f();
        \\}
        \\const S = struct {
        \\    test {
        \\        if (true) {}
        \\    }
        \\    fn g() void {}
        \\};
    );
    try std.testing.expectEqualSlices(bool, &.{ false, true, true, true, false, true, true, true, false, false }, marks);
}

test "the lcov tracefile has a record per file and a DA line per counted line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const files = [_]File{.{ .path = "lex/A.zig", .total = 2, .covered = 1, .lines = &.{ .none, .ran, .code } }};
    try std.testing.expectEqualStrings(
        \\TN:
        \\SF:/repo/src/lex/A.zig
        \\DA:2,1
        \\DA:3,0
        \\LF:2
        \\LH:1
        \\end_of_record
        \\
    , try renderLcov(arena.allocator(), "/repo/src", &files));
}
