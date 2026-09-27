//! Printing a program (docs/design/compare-bench.md §3.8): one module to
//! bytes, and a whole project to a directory with its scaffolding from
//! `templates/`. The body of a module is printed first, recording what it
//! referenced, and its header (imports) is written from that record, so a
//! module imports exactly what its text uses in that language and mode.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Tree = @import("../Tree.zig");
const gen = @import("../gen.zig");
const common = @import("common.zig");
const ml = @import("ml.zig");
const typescript = @import("typescript.zig");
const count = @import("count.zig");

pub const Lang = common.Lang;
pub const Stats = common.Stats;

pub const Options = struct {};

pub const Output = struct {
    path: []const u8,
    text: []const u8,
    stats: Stats,
};

pub fn modulePath(a: Allocator, lang: Lang, name: []const u8, kind: Tree.ModuleKind) ![]const u8 {
    return switch (lang) {
        .beni => std.fmt.allocPrint(a, "{s}.beni", .{name}),
        .elm => std.fmt.allocPrint(a, "src/{s}.elm", .{name}),
        .gleam => if (kind == .main) a.dupe(u8, "src/compare.gleam") else std.fmt.allocPrint(a, "src/{s}.gleam", .{common.gleamModule(a, name)}),
        .roc => std.fmt.allocPrint(a, "{s}.roc", .{name}),
        .purescript => std.fmt.allocPrint(a, "src/{s}.purs", .{name}),
        .typescript => std.fmt.allocPrint(a, "src/{s}.ts", .{name}),
    };
}

pub fn module(a: Allocator, prog: *const gen.Program, mi: u32, lang: Lang, opts: Options) !Output {
    _ = opts;
    const t = &prog.tree;
    const m = t.modules.items[mi];
    var body: Writer.Allocating = .init(a);
    const refs = try a.alloc(bool, t.modules.items.len);
    @memset(refs, false);
    var stats: Stats = .{ .modules = 1 };
    var lib: common.LibUse = .{};
    if (lang == .typescript) {
        var p: typescript.P = .{ .t = t, .uses = prog.info.uses, .module = mi, .w = &body.writer, .a = a, .refs = refs };
        if (m.kind == .base) try body.writer.writeAll(ts_base_helpers);
        for (m.types.items) |d| try p.typeDecl(d);
        for (m.fns.items) |f| try p.fnDecl(f);
        stats.annotations = p.annotations;
        stats.explicit_type_args = p.explicit_type_args;
        stats.invoked_arrows = p.invoked_arrows;
    } else {
        var p: ml.P = .{ .lang = lang, .t = t, .uses = prog.info.uses, .module = mi, .w = &body.writer, .a = a, .refs = refs, .roc_defaulted = if (lang == .roc) prog.roc_defaulted else null, .ps_typed = if (lang == .purescript) prog.ps_typed else null };
        for (m.types.items) |d| try p.typeDecl(d);
        for (m.fns.items) |f| try p.fnDecl(f);
        stats.annotations = p.annotations;
        lib = p.lib;
    }
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try header(a, w, t, mi, lang, refs, lib);
    if (lang == .roc) {
        try w.print("{s} :: [].{{", .{m.name});
        try w.writeAll(body.written());
        try w.writeAll("}\n");
    } else try w.writeAll(body.written());
    if (m.kind == .main) try mainWrapper(w, lang);
    const text = out.written();
    const c = count.count(text);
    stats.tokens = c.tokens;
    stats.lines = c.lines;
    return .{ .path = try modulePath(a, lang, m.name, m.kind), .text = text, .stats = stats };
}

const ts_base_helpers =
    \\export function absurd(x: never): never {
    \\  return x;
    \\}
    \\
    \\export function pair<a, b>(x: a, y: b): readonly [a, b] {
    \\  return [x, y];
    \\}
    \\
    \\
;

fn header(a: Allocator, w: *Writer, t: *const Tree, mi: u32, lang: Lang, refs: []const bool, lib: common.LibUse) !void {
    const m = t.modules.items[mi];
    switch (lang) {
        .beni => {
            for (refs, 0..) |r, j| if (r) try w.print("import {s}\n", .{t.modules.items[j].name});
            if (m.kind == .main) try w.writeAll("import Node exposing (Program)\n");
            try w.writeAll("\n\n");
        },
        .elm => {
            if (m.kind == .main) {
                try w.writeAll("module Main exposing (main, total)\n\n");
            } else try w.print("module {s} exposing (..)\n\n", .{m.name});
            for (refs, 0..) |r, j| if (r) try w.print("import {s}\n", .{t.modules.items[j].name});
            try w.writeAll("\n\n");
        },
        .purescript => {
            try w.print("module {s} where\n\n", .{m.name});
            if (lib.prelude or m.kind == .main) try w.writeAll("import Prelude\n\n");
            if (lib.list_type or lib.list_nil or lib.list_cons or lib.list_filter) {
                var items: std.ArrayList([]const u8) = .empty;
                if (lib.list_nil) try items.append(a, "List(..)") else if (lib.list_type) try items.append(a, "List");
                if (lib.list_cons) try items.append(a, "(:)");
                if (lib.list_filter) try items.append(a, "filter");
                try w.writeAll("import Data.List (");
                for (items.items, 0..) |it, i| try w.print("{s}{s}", .{ if (i > 0) ", " else "", it });
                try w.writeAll(")\n");
            }
            if (lib.foldable) try w.writeAll("import Data.Foldable (foldl)\n");
            if (lib.tuple_ctor) try w.writeAll("import Data.Tuple (Tuple(..))\n") else if (lib.tuple_type) try w.writeAll("import Data.Tuple (Tuple)\n");
            if (m.kind == .main) try w.writeAll("import Effect (Effect)\nimport Effect.Console (log)\n");
            for (refs, 0..) |r, j| if (r) try w.print("import {s} as {s}\n", .{ t.modules.items[j].name, t.modules.items[j].name });
            try w.writeAll("\n");
        },
        .gleam => {
            if (lib.gleam_int or m.kind == .main) try w.writeAll("import gleam/int\n");
            if (m.kind == .main) try w.writeAll("import gleam/io\n");
            if (lib.gleam_list) try w.writeAll("import gleam/list\n");
            for (refs, 0..) |r, j| if (r) try w.print("import {s}\n", .{common.gleamModule(a, t.modules.items[j].name)});
            try w.writeAll("\n");
        },
        .roc => {
            for (refs, 0..) |r, j| if (r) try w.print("import {s}\n", .{t.modules.items[j].name});
            try w.writeAll("\n");
        },
        .typescript => {
            for (refs, 0..) |r, j| if (r) try w.print("import * as {s} from \"./{s}\";\n", .{ t.modules.items[j].name, t.modules.items[j].name });
            try w.writeAll("\n");
        },
    }
}

/// The entry forms of §7.2, after `total`.
fn mainWrapper(w: *Writer, lang: Lang) !void {
    switch (lang) {
        .beni => try w.writeAll(
            \\main : Program
            \\main =
            \\    Node.print (String.fromInt (total 1))
            \\
        ),
        .elm => try w.writeAll(
            \\main : Program () () ()
            \\main =
            \\    Platform.worker
            \\        { init = \_ -> ( (), Cmd.none )
            \\        , update = \_ _ -> ( (), Cmd.none )
            \\        , subscriptions = \_ -> Sub.none
            \\        }
            \\
        ),
        .gleam => try w.writeAll(
            \\pub fn main() -> Nil {
            \\  io.println(int.to_string(total(1)))
            \\}
            \\
        ),
        .purescript => try w.writeAll(
            \\main :: Effect Unit
            \\main = log (show (total 1))
            \\
        ),
        .roc, .typescript => {},
    }
}

// ---- projects ----

pub const templates = struct {
    pub const elm_json = @embedFile("../templates/elm/elm.json");
    pub const gleam_toml = @embedFile("../templates/gleam/gleam.toml");
    pub const gleam_manifest = @embedFile("../templates/gleam/manifest.toml");
    pub const spago_dhall = @embedFile("../templates/purescript/spago.dhall");
    pub const packages_dhall = @embedFile("../templates/purescript/packages.dhall");
    pub const tsconfig = @embedFile("../templates/typescript/tsconfig.json");
};

/// Write one project: every module of `prog` in `lang`, and the scaffolding.
/// Returns the summed statistics of the modules.
pub fn project(a: Allocator, io: Io, dir: Io.Dir, prog: *const gen.Program, lang: Lang) !Stats {
    var total: Stats = .{};
    switch (lang) {
        .elm => try dir.writeFile(io, .{ .sub_path = "elm.json", .data = templates.elm_json }),
        .gleam => {
            try dir.writeFile(io, .{ .sub_path = "gleam.toml", .data = templates.gleam_toml });
            try dir.writeFile(io, .{ .sub_path = "manifest.toml", .data = templates.gleam_manifest });
        },
        .purescript => {
            try dir.writeFile(io, .{ .sub_path = "spago.dhall", .data = templates.spago_dhall });
            try dir.writeFile(io, .{ .sub_path = "packages.dhall", .data = templates.packages_dhall });
        },
        .typescript => try dir.writeFile(io, .{ .sub_path = "tsconfig.json", .data = templates.tsconfig }),
        .beni, .roc => {},
    }
    if (lang != .beni and lang != .roc) try dir.createDirPath(io, "src");
    for (prog.tree.modules.items, 0..) |_, mi| {
        const o = try module(a, prog, @intCast(mi), lang, .{});
        try dir.writeFile(io, .{ .sub_path = o.path, .data = o.text });
        total.add(o.stats);
    }
    return total;
}
