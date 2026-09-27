const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Tree = @import("Tree.zig");
const gen = @import("gen.zig");
const print = @import("print/print.zig");

pub const Mode = enum { annotated, inferred };

pub const Options = struct {
    seed: u64 = gen.default_seed,
    size: u32 = 1,
    sizes: []const u32 = &.{ 1, 2, 4, 8, 16 },
    runs: u32 = 7,
    families: []const Tree.Family = &Tree.Family.all,
    langs: []const print.Lang = &print.Lang.all,
    modes: []const Mode = &.{ .annotated, .inferred },
    annotate: u32 = 100,
    cpu: u32 = 2,
    label: ?[]const u8 = null,
    out: ?[]const u8 = null,
    prepare: bool = false,
    /// `compare gen --golden`: rewrite `print/golden/` (§15).
    golden: bool = false,
    online: bool = false,
    smoke: bool = false,
    timeout_s: u32 = 300,
    generator_hash: []const u8 = "",
    beni: []const u8 = "",
    repo: []const u8 = ".",
    roc_commit: []const u8 = "",
};

pub fn parseOptions(a: Allocator, args: []const []const u8) !Options {
    var o: Options = .{};
    for (args) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const key = if (eq) |i| arg[0..i] else arg;
        const val = if (eq) |i| arg[i + 1 ..] else "";
        if (std.mem.eql(u8, key, "--seed")) {
            o.seed = try std.fmt.parseInt(u64, val, 0);
        } else if (std.mem.eql(u8, key, "--size")) {
            o.size = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, key, "--sizes")) {
            var xs: std.ArrayList(u32) = .empty;
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |x| try xs.append(a, try std.fmt.parseInt(u32, x, 10));
            o.sizes = xs.items;
        } else if (std.mem.eql(u8, key, "--runs")) {
            o.runs = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, key, "--families")) {
            var xs: std.ArrayList(Tree.Family) = .empty;
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |x| try xs.append(a, Tree.Family.parse(x) orelse return error.UnknownFamily);
            o.families = xs.items;
        } else if (std.mem.eql(u8, key, "--langs")) {
            var xs: std.ArrayList(print.Lang) = .empty;
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |x| try xs.append(a, print.Lang.parse(x) orelse return error.UnknownLanguage);
            o.langs = xs.items;
        } else if (std.mem.eql(u8, key, "--modes")) {
            var xs: std.ArrayList(Mode) = .empty;
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |x| try xs.append(a, std.meta.stringToEnum(Mode, x) orelse return error.UnknownMode);
            o.modes = xs.items;
        } else if (std.mem.eql(u8, key, "--annotate")) {
            o.annotate = try std.fmt.parseInt(u32, val, 10);
            if (o.annotate > 100) return error.BadAnnotate;
        } else if (std.mem.eql(u8, key, "--cpu")) {
            o.cpu = try std.fmt.parseInt(u32, val, 10);
        } else if (std.mem.eql(u8, key, "--label")) {
            o.label = val;
        } else if (std.mem.eql(u8, key, "--out")) {
            o.out = val;
        } else if (std.mem.eql(u8, key, "--golden")) {
            o.golden = true;
        } else if (std.mem.eql(u8, key, "--prepare")) {
            o.prepare = true;
        } else if (std.mem.eql(u8, key, "--online")) {
            o.online = true;
        } else if (std.mem.eql(u8, key, "--quick")) {
            o.sizes = &.{ 1, 2, 4 };
            o.runs = 3;
        } else if (std.mem.eql(u8, key, "--timeout")) {
            o.timeout_s = try std.fmt.parseInt(u32, val, 10);
        } else return error.UnknownOption;
    }
    return o;
}

pub fn run(gpa: Allocator, io: Io, a: Allocator, o: Options, stdout: *Io.Writer, stderr: *Io.Writer, env: *std.process.Environ.Map) !u8 {
    return @import("runner_impl.zig").start(gpa, io, a, o, stdout, stderr, env);
}
