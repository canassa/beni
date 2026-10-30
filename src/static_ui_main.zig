//! Generate a bounded static UI measurement driver through JsIr and Print.
//! No application or existing benchmark JavaScript is rewritten.
const std = @import("std");
const J = @import("js/JsIr.zig");
const Print = @import("js/Print.zig");
const InternPool = @import("InternPool.zig");
const I = J.Node.Index;
const G = struct {
    a: std.mem.Allocator,
    b: J.Builder,
    names: InternPool.Local,
    fn node(g: *G, t: J.Node.Tag, l: u32, r: u32) !I {
        return g.b.addParts(t, J.Node.no_pos, l, r);
    }
    fn name(g: *G, s: []const u8) !J.NameIndex {
        return g.b.intern(.local(try g.names.getOrPut(g.a, s)));
    }
    fn id(g: *G, s: []const u8) !I {
        return g.node(.ident, @backingInt(try g.name(s)), 0);
    }
    fn str(g: *G, s: []const u8) !I {
        const x = try g.b.addString(s);
        return g.node(.string, x[0], x[1]);
    }
    fn num(g: *G, n: u32) !I {
        const x = try g.b.addString(try std.fmt.allocPrint(g.a, "{d}", .{n}));
        return g.node(.number, x[0], x[1]);
    }
    fn dot(g: *G, x: I, s: []const u8) !I {
        return g.node(.member, x.int(), @backingInt(try g.name(s)));
    }
    fn at(g: *G, x: I, k: I) !I {
        return g.node(.index_get, x.int(), k.int());
    }
    fn call(g: *G, f: I, xs: []const I) !I {
        return g.node(.call, f.int(), @backingInt(try g.b.addRecord(try g.b.addRange(xs))));
    }
    fn method(g: *G, x: I, s: []const u8, xs: []const I) !I {
        return g.call(try g.dot(x, s), xs);
    }
    fn bin(g: *G, op: J.BinaryOp, l: I, r: I) !I {
        return g.node(.binary, @backingInt(try g.b.addRecord(J.Binary{ .left = l, .right = r })), @backingInt(op));
    }
    fn arr(g: *G, xs: []const I) !I {
        const r = try g.b.addRange(xs);
        return g.node(.array, @backingInt(r.start), @backingInt(r.end));
    }
    fn obj(g: *G, keys: []const []const u8, xs: []const I) !I {
        var ps: std.ArrayList(I) = .empty;
        for (keys, xs) |k, v| try ps.append(g.a, try g.node(.property, @backingInt(try g.name(k)), v.int()));
        const r = try g.b.addRange(ps.items);
        return g.node(.object, @backingInt(r.start), @backingInt(r.end));
    }
    fn decl(g: *G, s: []const u8, x: I) !I {
        return g.node(.const_decl, @backingInt(try g.name(s)), x.int());
    }
    fn let(g: *G, s: []const u8, x: I) !I {
        return g.node(.let_decl, @backingInt(try g.name(s)), x.int());
    }
    fn set(g: *G, x: I, y: I) !I {
        return g.node(.assign_stmt, x.int(), y.int());
    }
    fn expr(g: *G, x: I) !I {
        return g.node(.expr_stmt, x.int(), 0);
    }
    fn ret(g: *G, x: I) !I {
        return g.node(.return_stmt, x.int(), 0);
    }
    fn arrow(g: *G, names: []const []const u8, body: []const I) !I {
        var ns: std.ArrayList(J.NameIndex) = .empty;
        for (names) |s| try ns.append(g.a, try g.name(s));
        const p = try g.b.addNames(ns.items);
        const b = try g.b.addRange(body);
        return g.node(.arrow, @backingInt(try g.b.addRecord(J.Func{ .params_start = p.start, .params_end = p.end, .body_start = b.start, .body_end = b.end })), 0);
    }
    fn when(g: *G, condition: I, body: []const I) !I {
        const t = try g.b.addRange(body);
        const e = try g.b.addRange(&.{});
        return g.node(.if_stmt, condition.int(), @backingInt(try g.b.addRecord(J.If{ .then_start = t.start, .then_end = t.end, .else_start = e.start, .else_end = e.end })));
    }
    fn fail(g: *G, condition: I, msg: []const u8) !I {
        return g.when(condition, &.{try g.node(.throw_stmt, (try g.call(try g.id("Error"), &.{try g.str(msg)})).int(), 0)});
    }
    fn loop(g: *G, variable: []const u8, array: I, body: []const I) !I {
        const b = try g.b.addRange(body);
        return g.node(.for_of, @backingInt(try g.name(variable)), @backingInt(try g.b.addRecord(J.ForOf{ .iterable = array, .body_start = b.start, .body_end = b.end })));
    }
    fn then(g: *G, promise: I, ps: []const []const u8, body: []const I) !I {
        return g.method(promise, "then", &.{try g.arrow(ps, body)});
    }
    fn resolve(g: *G) !I {
        return g.method(try g.id("Promise"), "resolve", &.{});
    }
    fn now(g: *G) !I {
        return g.method(try g.id("performance"), "now", &.{});
    }
    fn render(g: *G, ss: []const I) ![]const u8 {
        const r = try g.b.addRange(ss);
        var ir = try g.b.toOwned(r);
        try ir.verify();
        const bytes = try Print.print(g.a, g.a, &ir, .fromLocal(&g.names), .{});
        g.b = .init(g.a);
        return bytes;
    }
};

fn measure(g: *G, solid: bool, layout: bool) ![]const u8 {
    const opts = try g.id("opts");
    const n = try g.dot(opts, "n");
    const sent = try g.dot(opts, "sent");
    const nodes = try g.id("nodes");
    const button = try g.id("button");
    const i = try g.id("i");
    var loop: std.ArrayList(I) = .empty;
    try loop.append(g.a, try g.when(try g.bin(.ge, i, n), &.{try g.node(.break_stmt, @backingInt(J.NameIndex.none), 0)}));
    try loop.append(g.a, try g.expr(try g.method(button, "click", &.{})));
    if (solid) try loop.append(g.a, try g.expr(try g.method(try g.id("window"), "__flush", &.{})));
    if (layout) try loop.append(g.a, try g.expr(try g.dot(try g.dot(try g.id("document"), "body"), "offsetHeight")));
    try loop.append(g.a, try g.set(i, try g.bin(.add, i, try g.num(1))));
    const lr = try g.b.addRange(loop.items);
    const count = try g.bin(.add, sent, n);
    const j = try g.id("j");
    const expected = try g.method(try g.id("String"), "call", &.{ try g.node(.null_lit, 0, 0), try g.method(try g.id("Math"), "floor", &.{try g.bin(.div, try g.bin(.sub, try g.bin(.add, count, try g.num(49)), j), try g.num(50))}) });
    const checks = try g.loop("node", try g.id("checked"), &.{
        try g.fail(try g.bin(.strict_ne, try g.dot(try g.id("node"), "textContent"), expected), "counter mismatch inside timed eval; delayed rendering is not accepted"),
        try g.set(j, try g.bin(.add, j, try g.num(1))),
    });
    const fnn = try g.arrow(&.{"opts"}, &.{
        try g.decl("nodes", try g.method(try g.id("document"), "querySelectorAll", &.{try g.str("h2 span")})),
        try g.fail(try g.bin(.strict_ne, try g.dot(nodes, "length"), try g.num(50)), "expected exactly 50 counters"),
        try g.decl("button", try g.method(try g.id("document"), "getElementById", &.{try g.str("bump")})),
        try g.fail(try g.bin(.strict_eq, button, try g.node(.null_lit, 0, 0)), "missing bump button"),
        try g.decl("start", try g.now()),
        try g.let("i", try g.num(0)),
        try g.node(.while_true, @backingInt(J.NameIndex.none), @backingInt(try g.b.addRecord(lr))),
        try g.decl("elapsed", try g.bin(.sub, try g.now(), try g.id("start"))),
        try g.decl("checked", try g.method(try g.id("document"), "querySelectorAll", &.{try g.str("h2 span")})),
        try g.fail(try g.bin(.strict_ne, try g.dot(try g.id("checked"), "length"), try g.num(50)), "expected exactly 50 counters after timing"),
        try g.let("j", try g.num(0)),
        checks,
        try g.fail(try g.node(.unary, (try g.method(try g.id("Number"), "isFinite", &.{try g.id("elapsed")})).int(), @backingInt(J.UnaryOp.not)), "nonfinite timing"),
        try g.ret(try g.obj(&.{ "elapsed", "sent" }, &.{ try g.id("elapsed"), count })),
    });
    const text = try g.render(&.{try g.expr(fnn)});
    return std.mem.trimEnd(u8, text, ";\n \r");
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2 and args.len != 5) return error.ExpectedOutputPath;
    var g: G = .{ .a = a, .b = .init(a), .names = try .init(a) };
    var evals: [4][]const u8 = undefined;
    evals[0] = try measure(&g, false, false);
    evals[1] = try measure(&g, false, true);
    evals[2] = try measure(&g, true, false);
    evals[3] = try measure(&g, true, true);
    for (evals[0..2]) |source| std.debug.assert(std.mem.indexOf(u8, source, "__flush") == null);
    const output = try driver(&g, evals);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = output });
    if (args.len == 5) {
        const answer = try g.decl("answer", try g.num(42));
        const exports = try g.b.addNames(&.{try g.name("answer")});
        const fixture = try g.render(&.{ answer, try g.node(.export_stmt, @backingInt(exports.start), @backingInt(exports.end)) });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = fixture });
        const smoke = try importSmoke(&g, args[2]);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[3], .data = smoke });
        const tests = try evaluatorTests(&g, evals);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[4], .data = tests });
    }
}

fn bootstrap(g: *G) ![]const u8 {
    const link = try g.id("link");
    const latch = try g.id("latch");
    const f = try g.arrow(&.{"entry"}, &.{
        try g.decl("link", try g.method(try g.id("document"), "createElement", &.{try g.str("link")})),
        try g.set(try g.dot(link, "rel"), try g.str("modulepreload")),
        try g.set(try g.dot(link, "href"), try g.id("entry")),
        try g.decl("latch", try g.method(try g.id("Promise"), "withResolvers", &.{})),
        try g.set(try g.dot(link, "onload"), try g.dot(latch, "resolve")),
        try g.set(try g.dot(link, "onerror"), try g.dot(latch, "reject")),
        try g.expr(try g.method(try g.dot(try g.id("document"), "head"), "append", &.{link})),
        try g.ret(try g.then(try g.dot(latch, "promise"), &.{}, &.{
            try g.decl("t0", try g.now()),
            try g.ret(try g.then(try g.node(.dynamic_import, (try g.id("entry")).int(), 0), &.{}, &.{try g.set(try g.dot(try g.id("window"), "__mount"), try g.bin(.sub, try g.now(), try g.id("t0")))})),
        })),
    });
    return std.mem.trimEnd(u8, try g.render(&.{try g.expr(f)}), ";\n \r");
}

fn driver(g: *G, evaluators: [4][]const u8) ![]const u8 {
    const bootstrap_text = try bootstrap(g);
    const mount_text = std.mem.trimEnd(u8, try g.render(&.{try g.expr(try g.dot(try g.id("window"), "__mount"))}), ";\n \r");
    const ready_test = try g.bin(.logical_and, try g.bin(.strict_ne, try g.dot(try g.id("window"), "__mount"), try g.node(.undefined_lit, 0, 0)), try g.bin(.strict_ne, try g.method(try g.id("document"), "getElementById", &.{try g.str("bump")}), try g.node(.null_lit, 0, 0)));
    const ready_text = std.mem.trimEnd(u8, try g.render(&.{try g.expr(ready_test)}), ";\n \r");

    const cfg = try g.id("cfg");
    const fs = try g.id("fs");
    const browser = try g.id("browser");
    const server = try g.id("server");
    const row = try g.id("row");
    const page = try g.id("page");
    const subject = try g.id("subject");
    const result = try g.id("result");
    const repeat = try g.decl("repeat", try g.arrow(&.{ "count", "body" }, &.{
        try g.let("chain", try g.resolve()),
        try g.loop("k", try g.method(try g.call(try g.id("Array"), &.{try g.id("count")}), "keys", &.{}), &.{try g.set(try g.id("chain"), try g.then(try g.id("chain"), &.{}, &.{try g.ret(try g.call(try g.id("body"), &.{try g.id("k")}))}))}),
        try g.ret(try g.id("chain")),
    }));
    const summary = try g.decl("summary", try g.arrow(&.{"xs"}, &.{try g.ret(try g.obj(&.{ "median", "q25", "q75", "n" }, &.{
        try g.method(try g.id("trace"), "median", &.{try g.id("xs")}),
        try g.method(try g.id("trace"), "quantile", &.{ try g.id("xs"), try g.bin(.div, try g.num(1), try g.num(4)) }),
        try g.method(try g.id("trace"), "quantile", &.{ try g.id("xs"), try g.bin(.div, try g.num(3), try g.num(4)) }),
        try g.dot(try g.id("xs"), "length"),
    }))}));
    const evaluate = try g.decl("evaluate", try g.arrow(&.{ "page", "row", "n", "layout", "solid" }, &.{
        try g.decl("key", try g.bin(.add, try g.bin(.mul, try g.call(try g.id("Number"), &.{try g.id("solid")}), try g.num(2)), try g.call(try g.id("Number"), &.{try g.id("layout")}))),
        try g.decl("source", try g.bin(.add, try g.bin(.add, try g.bin(.add, try g.str("("), try g.at(try g.id("evaluators"), try g.id("key"))), try g.str(")(")), try g.bin(.add, try g.method(try g.id("JSON"), "stringify", &.{try g.obj(&.{ "n", "sent" }, &.{ try g.id("n"), try g.dot(row, "sent") })}), try g.str(")")))),
        try g.ret(try g.then(try g.method(page, "eval", &.{try g.id("source")}), &.{"sample"}, &.{ try g.set(try g.dot(row, "sent"), try g.dot(try g.id("sample"), "sent")), try g.ret(try g.dot(try g.id("sample"), "elapsed")) })),
    }));
    const inline_subject = try g.decl("inlineSubject", try g.arrow(&.{ "name", "dir" }, &.{
        try g.decl("entry", try g.bin(.add, try g.bin(.add, try g.str("/out/"), try g.id("dir")), try g.str("/_main.mjs"))),
        try g.decl("code", try g.bin(.add, try g.bin(.add, try g.str(try std.fmt.allocPrint(g.a, "({s})(", .{bootstrap_text})), try g.method(try g.id("JSON"), "stringify", &.{try g.id("entry")})), try g.str(");"))),
        try g.ret(try g.obj(&.{ "name", "kind", "solid", "html" }, &.{ try g.id("name"), try g.str("html"), try g.node(.false_lit, 0, 0), try g.bin(.add, try g.bin(.add, try g.str("<!doctype html><html><head><meta charset=utf-8><link href=/css/currentStyle.css rel=stylesheet></head><body><script type=module>"), try g.id("code")), try g.str("</script></body></html>")) })),
    }));
    const hash = try g.decl("hashFile", try g.arrow(&.{"path"}, &.{try g.ret(try g.method(try g.method(try g.method(try g.id("crypto"), "createHash", &.{try g.str("sha256")}), "update", &.{try g.method(fs, "readFileSync", &.{try g.id("path")})}), "digest", &.{try g.str("hex")}))}));
    // Build the per-page Promise pipeline from inside out.
    const collect = try g.then(try g.call(try g.id("repeat"), &.{ try g.num(2), try g.arrow(&.{"phase"}, &.{
        try g.decl("layout", try g.bin(.strict_eq, try g.id("phase"), try g.num(1))),
        try g.decl("field", try g.node(.cond, (try g.id("layout")).int(), @backingInt(try g.b.addRecord(J.Cond{ .consequent = try g.str("layout"), .alternate = try g.str("script") })))),
        try g.ret(try g.call(try g.id("repeat"), &.{ try g.num(20), try g.arrow(&.{}, &.{
            try g.ret(try g.then(try g.call(try g.id("evaluate"), &.{ page, row, try g.num(100), try g.id("layout"), try g.dot(subject, "solid") }), &.{"elapsed"}, &.{try g.expr(try g.method(try g.at(row, try g.id("field")), "push", &.{try g.bin(.mul, try g.id("elapsed"), try g.num(10))}))})),
        }) })),
    }) }), &.{}, &.{
        try g.fail(try g.bin(.logical_or, try g.bin(.strict_ne, try g.dot(try g.dot(row, "script"), "length"), try g.num(20)), try g.bin(.strict_ne, try g.dot(try g.dot(row, "layout"), "length"), try g.num(20))), "missing samples"),
        try g.set(try g.dot(row, "scriptSummary"), try g.call(try g.id("summary"), &.{try g.dot(row, "script")})),
        try g.set(try g.dot(row, "layoutSummary"), try g.call(try g.id("summary"), &.{try g.dot(row, "layout")})),
        try g.expr(try g.method(try g.dot(result, "rows"), "push", &.{row})),
    });
    const warm = try g.then(try g.call(try g.id("evaluate"), &.{ page, row, try g.num(1), try g.node(.false_lit, 0, 0), try g.dot(subject, "solid") }), &.{"elapsed"}, &.{
        try g.set(try g.dot(row, "first"), try g.id("elapsed")),
        try g.ret(try g.then(try g.call(try g.id("evaluate"), &.{ page, row, try g.num(300), try g.node(.false_lit, 0, 0), try g.dot(subject, "solid") }), &.{}, &.{try g.ret(collect)})),
    });
    const mounted = try g.then(try g.method(page, "eval", &.{try g.str(mount_text)}), &.{"mount"}, &.{
        try g.fail(try g.node(.unary, (try g.method(try g.id("Number"), "isFinite", &.{try g.id("mount")})).int(), @backingInt(J.UnaryOp.not)), "nonfinite mount timing"),
        try g.set(try g.dot(row, "mount"), try g.id("mount")),
        try g.ret(try g.then(try g.method(page, "send", &.{ try g.str("Emulation.setCPUThrottlingRate"), try g.obj(&.{"rate"}, &.{try g.id("throttle")}) }), &.{}, &.{try g.ret(warm)})),
    });
    const pipeline = try g.then(try g.method(page, "waitFor", &.{try g.str(ready_text)}), &.{}, &.{try g.ret(mounted)});
    const per_page = try g.decl("measurePage", try g.arrow(&.{ "subject", "pageIndex", "throttle" }, &.{
        try g.decl("row", try g.obj(&.{ "subject", "page", "dispatchThrottle", "sent", "script", "layout", "mountThrottle" }, &.{ try g.dot(subject, "name"), try g.id("pageIndex"), try g.id("throttle"), try g.num(0), try g.arr(&.{}), try g.arr(&.{}), try g.num(1) })),
        try g.ret(try g.then(try g.method(browser, "newPage", &.{try g.bin(.add, try g.bin(.add, try g.dot(server, "origin"), try g.str("/s/")), try g.bin(.add, try g.dot(subject, "name"), try g.str("/")))}), &.{"page"}, &.{
            try g.ret(try g.method(pipeline, "finally", &.{try g.arrow(&.{}, &.{try g.ret(try g.method(page, "close", &.{}))})})),
        })),
    }));
    const pages = try g.call(try g.id("repeat"), &.{ try g.num(2), try g.arrow(&.{"t"}, &.{
        try g.decl("throttle", try g.node(.cond, (try g.bin(.strict_eq, try g.id("t"), try g.num(0))).int(), @backingInt(try g.b.addRecord(J.Cond{ .consequent = try g.num(1), .alternate = try g.num(4) })))),
        try g.ret(try g.call(try g.id("repeat"), &.{ try g.num(6), try g.arrow(&.{"p"}, &.{
            try g.ret(try g.call(try g.id("repeat"), &.{ try g.num(3), try g.arrow(&.{"k"}, &.{
                try g.ret(try g.call(try g.id("measurePage"), &.{ try g.at(try g.id("subjects"), try g.bin(.rem, try g.bin(.add, try g.id("p"), try g.id("k")), try g.num(3))), try g.id("p"), try g.id("throttle") })),
            }) })),
        }) })),
    }) });
    const runs = try g.then(try g.method(try g.id("cdp"), "launch", &.{try g.obj(&.{ "chrome", "taskset" }, &.{ try g.dot(cfg, "chrome"), try g.dot(cfg, "taskset") })}), &.{"launched"}, &.{
        try g.set(browser, try g.id("launched")),                                                                                                                                       try g.set(try g.dot(result, "chrome"), try g.dot(browser, "version")),
        try g.ret(try g.then(try g.method(try g.id("serving"), "serve", &.{try g.id("subjects")}), &.{"listening"}, &.{ try g.set(server, try g.id("listening")), try g.ret(pages) })),
    });
    const artifact_paths = [_]I{
        try g.bin(.add, try g.str("/out/"), try g.bin(.add, try g.dot(cfg, "oldDir"), try g.str("/_main.mjs"))),
        try g.bin(.add, try g.str("/out/"), try g.bin(.add, try g.dot(cfg, "newDir"), try g.str("/_main.mjs"))),
        try g.str("/out/solid2/static.js"),
        try g.str("/apps/solid2/package-lock.json"),
        try g.str("/lib/cdp.mjs"),
        try g.str("/lib/serve.mjs"),
        try g.str("/lib/trace.mjs"),
    };
    var artifact_hashes: [7]I = undefined;
    for (artifact_paths, 0..) |path, i| artifact_hashes[i] = try g.call(try g.id("hashFile"), &.{try g.bin(.add, try g.dot(cfg, "root"), path)});
    const artifacts = try g.obj(&.{ "oldEntry", "newEntry", "solidStatic", "solidLock", "cdp", "serve", "trace" }, &artifact_hashes);
    const aggregates = try g.loop("subject", try g.id("subjects"), &.{
        try g.loop("rate", try g.arr(&.{ try g.num(1), try g.num(4) }), &.{
            try g.decl("group", try g.method(try g.dot(result, "rows"), "filter", &.{try g.arrow(&.{"item"}, &.{try g.ret(try g.bin(.logical_and, try g.bin(.strict_eq, try g.dot(try g.id("item"), "subject"), try g.dot(subject, "name")), try g.bin(.strict_eq, try g.dot(try g.id("item"), "dispatchThrottle"), try g.id("rate"))))})})),
            try g.fail(try g.bin(.strict_ne, try g.dot(try g.id("group"), "length"), try g.num(6)), "missing group pages"),
            try g.expr(try g.method(try g.dot(result, "summary"), "push", &.{try g.obj(&.{ "subject", "dispatchThrottle", "script", "layout", "first", "mount", "mountThrottle" }, &.{
                try g.dot(subject, "name"),                                                                                                                                         try g.id("rate"),
                try g.call(try g.id("summary"), &.{try g.method(try g.id("group"), "flatMap", &.{try g.arrow(&.{"item"}, &.{try g.ret(try g.dot(try g.id("item"), "script"))})})}), try g.call(try g.id("summary"), &.{try g.method(try g.id("group"), "flatMap", &.{try g.arrow(&.{"item"}, &.{try g.ret(try g.dot(try g.id("item"), "layout"))})})}),
                try g.call(try g.id("summary"), &.{try g.method(try g.id("group"), "map", &.{try g.arrow(&.{"item"}, &.{try g.ret(try g.dot(try g.id("item"), "first"))})})}),      try g.call(try g.id("summary"), &.{try g.method(try g.id("group"), "map", &.{try g.arrow(&.{"item"}, &.{try g.ret(try g.dot(try g.id("item"), "mount"))})})}),
                try g.num(1),
            })})),
        }),
    });
    const finish = try g.then(runs, &.{}, &.{
        try g.set(try g.dot(result, "summary"), try g.arr(&.{})),                                                                                                                            aggregates,
        try g.set(try g.dot(result, "finishedMs"), try g.method(try g.id("Date"), "now", &.{})),                                                                                             try g.fail(try g.bin(.strict_ne, try g.dot(try g.dot(result, "rows"), "length"), try g.num(36)), "missing pages"),
        try g.expr(try g.method(fs, "writeFileSync", &.{ try g.dot(cfg, "output"), try g.method(try g.id("JSON"), "stringify", &.{ result, try g.node(.null_lit, 0, 0), try g.num(2) }) })),
    });
    const body = try g.arrow(&.{"libs"}, &.{
        try g.decl("cdp", try g.at(try g.id("libs"), try g.num(0))), try g.decl("serving", try g.at(try g.id("libs"), try g.num(1))), try g.decl("trace", try g.at(try g.id("libs"), try g.num(2))),
        repeat,                                                      summary,                                                         evaluate,
        inline_subject,                                              hash,                                                            try g.decl("subjects", try g.arr(&.{ try g.call(try g.id("inlineSubject"), &.{ try g.str("inline-old"), try g.dot(cfg, "oldDir") }), try g.call(try g.id("inlineSubject"), &.{ try g.str("inline-new"), try g.dot(cfg, "newDir") }), try g.obj(&.{ "name", "kind", "entry", "solid" }, &.{ try g.str("solid2"), try g.str("solid"), try g.str("static"), try g.node(.true_lit, 0, 0) }) })),
        try g.let("browser", try g.node(.null_lit, 0, 0)),           try g.let("server", try g.node(.null_lit, 0, 0)),
        try g.decl("result", try g.obj(&.{ "config", "oldCompilerHash", "newCompilerHash", "node", "cpu", "settings", "rows", "startedMs", "artifacts" }, &.{
            cfg,
            try g.call(try g.id("hashFile"), &.{try g.dot(cfg, "oldCompiler")}),
            try g.call(try g.id("hashFile"), &.{try g.dot(cfg, "newCompiler")}),
            try g.dot(try g.id("process"), "version"),
            try g.dot(try g.at(try g.method(try g.id("os"), "cpus", &.{}), try g.num(0)), "model"),
            try g.obj(&.{ "pages", "samples", "messages", "warmup", "units", "mountBoundary", "mountThrottle", "dispatchThrottle" }, &.{ try g.num(6), try g.num(20), try g.num(100), try g.num(300), try g.str("script/layout us per message; first/mount ms"), try g.str("Inline: preloaded dynamic import evaluation; Solid: application render timer; initialization boundaries differ"), try g.num(1), try g.arr(&.{ try g.num(1), try g.num(4) }) }),
            try g.arr(&.{}),
            try g.method(try g.id("Date"), "now", &.{}),
            artifacts,
        })),
        per_page,
        try g.ret(try g.method(finish, "finally", &.{try g.arrow(&.{}, &.{
            try g.when(try g.bin(.strict_ne, server, try g.node(.null_lit, 0, 0)), &.{try g.expr(try g.method(try g.dot(server, "server"), "close", &.{}))}),
            try g.when(try g.bin(.strict_ne, browser, try g.node(.null_lit, 0, 0)), &.{try g.ret(try g.method(browser, "close", &.{}))}),
        })})),
    });
    var imports: std.ArrayList(I) = .empty;
    for ([_][]const u8{ "cdp", "serve", "trace" }) |name| try imports.append(g.a, try g.node(.dynamic_import, (try g.bin(.add, try g.bin(.add, try g.str("file://"), try g.dot(cfg, "root")), try g.str(try std.fmt.allocPrint(g.a, "/lib/{s}.mjs", .{name})))).int(), 0));
    var eval_nodes: [4]I = undefined;
    for (evaluators, 0..) |text, i| eval_nodes[i] = try g.str(text);
    const setup = try g.then(try g.method(try g.id("Promise"), "all", &.{try g.arr(&.{ try g.node(.dynamic_import, (try g.str("node:fs")).int(), 0), try g.node(.dynamic_import, (try g.str("node:os")).int(), 0), try g.node(.dynamic_import, (try g.str("node:crypto")).int(), 0) })}), &.{"system"}, &.{
        try g.decl("fs", try g.at(try g.id("system"), try g.num(0))),                                                                                                                              try g.decl("os", try g.at(try g.id("system"), try g.num(1))), try g.decl("crypto", try g.at(try g.id("system"), try g.num(2))),
        try g.decl("cfg", try g.method(try g.id("JSON"), "parse", &.{try g.method(fs, "readFileSync", &.{ try g.at(try g.dot(try g.id("process"), "argv"), try g.num(2)), try g.str("utf8") })})), try g.decl("evaluators", try g.arr(&eval_nodes)),             try g.ret(try g.method(try g.method(try g.id("Promise"), "all", &.{try g.arr(imports.items)}), "then", &.{body})),
    });
    return g.render(&.{try g.expr(try g.method(setup, "catch", &.{try g.arrow(&.{"error"}, &.{ try g.expr(try g.method(try g.id("console"), "error", &.{try g.id("error")})), try g.set(try g.dot(try g.id("process"), "exitCode"), try g.num(1)) })}))});
}

fn importSmoke(g: *G, path: []const u8) ![]const u8 {
    const promise = try g.node(.dynamic_import, (try g.str(try std.fmt.allocPrint(g.a, "file://{s}", .{path}))).int(), 0);
    const check = try g.then(promise, &.{"loaded"}, &.{
        try g.fail(try g.bin(.strict_ne, try g.dot(try g.id("loaded"), "answer"), try g.num(42)), "generated import did not return expected export"),
        try g.expr(try g.method(try g.id("console"), "log", &.{try g.str("dynamic import execution passed")})),
    });
    return g.render(&.{try g.expr(try g.method(check, "catch", &.{try g.arrow(&.{"error"}, &.{ try g.expr(try g.method(try g.id("console"), "error", &.{try g.id("error")})), try g.set(try g.dot(try g.id("process"), "exitCode"), try g.num(1)) })}))});
}

fn evaluatorTests(g: *G, evals: [4][]const u8) ![]const u8 {
    var sources: [4]I = undefined;
    for (evals, 0..) |s, i| sources[i] = try g.str(s);
    const nodes = try g.id("nodes");
    const sent = try g.id("sent");
    const rendering = try g.arrow(&.{}, &.{ try g.let("j", try g.num(0)), try g.loop("node", nodes, &.{
        try g.set(try g.dot(try g.id("node"), "textContent"), try g.call(try g.id("String"), &.{try g.method(try g.id("Math"), "floor", &.{try g.bin(.div, try g.bin(.sub, try g.bin(.add, sent, try g.num(49)), try g.id("j")), try g.num(50))})})),
        try g.set(try g.id("j"), try g.bin(.add, try g.id("j"), try g.num(1))),
    }) });
    const one = try g.decl("one", try g.arrow(&.{ "k", "broken" }, &.{
        try g.decl("nodes", try g.method(try g.method(try g.id("Array"), "from", &.{try g.method(try g.call(try g.id("Array"), &.{try g.num(50)}), "keys", &.{})}), "map", &.{try g.arrow(&.{}, &.{try g.ret(try g.obj(&.{"textContent"}, &.{try g.str("0")}))})})),
        try g.let("sent", try g.num(0)),
        try g.decl("render", rendering),
        try g.decl("button", try g.obj(&.{"click"}, &.{try g.arrow(&.{}, &.{
            try g.set(sent, try g.bin(.add, sent, try g.num(1))),
            try g.when(try g.bin(.strict_eq, try g.id("broken"), try g.num(1)), &.{try g.expr(try g.call(try g.id("queueMicrotask"), &.{try g.id("render")}))}),
            try g.when(try g.bin(.logical_and, try g.bin(.lt, try g.id("k"), try g.num(2)), try g.bin(.strict_eq, try g.id("broken"), try g.num(0))), &.{try g.expr(try g.call(try g.id("render"), &.{}))}),
        })})),
        try g.set(try g.dot(try g.node(.global_this, 0, 0), "document"), try g.obj(&.{ "querySelectorAll", "getElementById", "body" }, &.{
            try g.arrow(&.{}, &.{try g.ret(try g.node(.cond, (try g.bin(.strict_eq, try g.id("broken"), try g.num(2))).int(), @backingInt(try g.b.addRecord(J.Cond{ .consequent = try g.method(nodes, "slice", &.{try g.num(1)}), .alternate = nodes }))))}), try g.arrow(&.{}, &.{try g.ret(try g.id("button"))}), try g.obj(&.{"offsetHeight"}, &.{try g.num(0)}),
        })),
        try g.set(try g.dot(try g.node(.global_this, 0, 0), "window"), try g.node(.global_this, 0, 0)),
        try g.set(try g.dot(try g.id("window"), "__flush"), try g.arrow(&.{}, &.{try g.when(try g.bin(.strict_eq, try g.id("broken"), try g.num(0)), &.{try g.expr(try g.call(try g.id("render"), &.{}))})})),
        try g.decl("fn", try g.method(try g.node(.global_this, 0, 0), "eval", &.{try g.at(try g.id("sources"), try g.id("k"))})),
        try g.ret(try g.call(try g.id("fn"), &.{try g.obj(&.{ "n", "sent" }, &.{ try g.num(101), try g.num(0) })})),
    }));
    // Promises capture synchronous evaluator errors without adding a raw catch string.
    const positive = try g.then(try g.resolve(), &.{}, &.{try g.expr(try g.call(try g.id("one"), &.{ try g.id("k"), try g.num(0) }))});
    const negative = try g.method(try g.then(try g.resolve(), &.{}, &.{try g.ret(try g.call(try g.id("one"), &.{ try g.id("k"), try g.num(1) }))}), "then", &.{
        try g.arrow(&.{}, &.{try g.node(.throw_stmt, (try g.call(try g.id("Error"), &.{try g.str("broken rendering unexpectedly passed")})).int(), 0)}),
        try g.arrow(&.{"error"}, &.{try g.fail(try g.bin(.strict_ne, try g.dot(try g.id("error"), "message"), try g.str("counter mismatch inside timed eval; delayed rendering is not accepted")), "unexpected negative fixture failure")}),
    });
    const missing = try g.method(try g.then(try g.resolve(), &.{}, &.{try g.ret(try g.call(try g.id("one"), &.{ try g.id("k"), try g.num(2) }))}), "then", &.{
        try g.arrow(&.{}, &.{try g.node(.throw_stmt, (try g.call(try g.id("Error"), &.{try g.str("missing counters unexpectedly passed")})).int(), 0)}),
        try g.arrow(&.{"error"}, &.{try g.fail(try g.bin(.strict_ne, try g.dot(try g.id("error"), "message"), try g.str("expected exactly 50 counters")), "unexpected missing-node fixture failure")}),
    });
    const tests = try g.decl("run", try g.arrow(&.{"k"}, &.{try g.ret(try g.then(positive, &.{}, &.{try g.ret(try g.then(negative, &.{}, &.{try g.ret(missing)}))}))}));
    var chain = try g.resolve();
    for (0..4) |k| chain = try g.then(chain, &.{}, &.{try g.ret(try g.call(try g.id("run"), &.{try g.num(@intCast(k))}))});
    const passed = try g.then(chain, &.{}, &.{try g.expr(try g.method(try g.id("console"), "log", &.{try g.str("four evaluator paths, four delayed-render and four missing-node rejections passed")}))});
    return g.render(&.{ try g.decl("sources", try g.arr(&sources)), one, tests, try g.expr(try g.method(passed, "catch", &.{try g.arrow(&.{"error"}, &.{ try g.expr(try g.method(try g.id("console"), "error", &.{try g.id("error")})), try g.set(try g.dot(try g.id("process"), "exitCode"), try g.num(1)) })})) });
}

test {
    std.testing.refAllDecls(J);
    std.testing.refAllDecls(Print);
}
