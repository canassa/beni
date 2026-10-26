//! L6: rows as data (`docs/design/ownership-v2.md` §2.13.1, §2.13.6,
//! §2.13.13; oc §24.2): the classes that are not read off a body. A worded
//! declaration's class comes from its ownership words (`fromWords`), a
//! constructor's from its type (`ctorClass`), a derived `eq`/`compare`'s is
//! read-only (`derivedClass`). Nothing here names a declaration, a type or
//! a module: the caller hands places, word bit sets and arities (§5's
//! fence: no name is compared to text).
//!
//! **Today's words** (R-5.10.2, `Ast.OwnWord`), with their rows:
//!
//! | on a parameter | row |
//! |---|---|
//! | `unused` | nothing |
//! | `borrowed` | `R` at ε |
//! | `aliased` | `RA`; `res` may hold it anywhere: a `recast` of the parameter's leaf at ρ, approximate at every path |
//! | `returned` | `RA`; `res ε` is it |
//! | `escaped` | `RE` |
//! | `consumed` | `RW` deep (`S`) |
//! | none | `escaped` (the worst case, R-5.10.3) |
//!
//! | on a function parameter (or each element of a `List` of functions, a slot at `[*]`) | row |
//! |---|---|
//! | `once` / `many` / `unused` | `calls ≤1` / `many` / `0`, seen |
//! | `owned` | each supply a fresh cell, owned; else `⊤` borrowed |
//! | `escaped` | kept by JavaScript: `RE`, `calls many`, unseen |
//! | `returned` / `aliased` | `res ε cb_j` / `res` holds `cb_j` anywhere, approximate |
//!
//! | on the result | row |
//! |---|---|
//! | `fresh exclusive` | `fresh 1`, κ `yes` |
//! | `fresh` | `fresh 1` at every path, approximate, κ `lost` (a recast: the call made it, its contents may be shared) |
//! | `escaped` | `esc 1` likewise, κ `lost` |
//! | `unknown`, or none without a `returned` parameter | `⊤`, κ `lost` |
//!
//! A crossing position (a `cross` place) carries no cell whatever its word.
//! `entry` is recorded on the class and read by S7's `Entry`. The new
//! type/value words of §2.13.6 are S2b's and are not read here.
//!
//! Every class record goes through `Summary.add`, which reserves it; the
//! cells and nodes a row makes are reserved by the tables they enter.
//!
//! Obligations kept here: O9 (a row states its body: a word that says less
//! than the code does is a defect of the trusted surface, pinned by
//! R-5.10.7; a wordless `foreign` is pessimistic), O10 (`⊤` never empty).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Cell = @import("Cell.zig");
const Shape = @import("Shape.zig");
const Cond = @import("Cond.zig");
const Summary = @import("Summary.zig");
const Ast = @import("../parse/Ast.zig");

pub const Word = Ast.OwnWord;
pub const ClassId = Ids.ClassId;
pub const NodeId = Ids.NodeId;
pub const PlaceId = Ids.PlaceId;
pub const CellId = Ids.CellId;
pub const SetId = Ids.SetId;
pub const Step = Place.Step;
pub const Env = Summary.Env;
pub const Error = Ids.ChargeError;

/// One parameter of a worded signature: its place, its word bits
/// (`Word.bit`), and when its type is a function written out (or a `List`
/// of one) that function's parameter places.
pub const Param = struct {
    place: PlaceId,
    words: u32 = 0,
    /// The written-out function type's parameter places, or null.
    fn_params: ?[]const PlaceId = null,
    /// `List (a → b)`: `fn_params` describes each element (oc §30.9).
    list_of_fns: bool = false,
};

pub const Signature = struct {
    params: []const Param,
    result: PlaceId,
    result_words: u32 = 0,
    entry: bool = false,
};

fn has(words: u32, word: Word) bool {
    return words & word.bit() != 0;
}

/// A leaf at `at` holding `fresh k`/`esc k` (`result`/`esc` with no
/// label, the class's own fresh cell).
fn freshLeaf(env: Env, o: Cell.Origin, k: u32, at: PlaceId) Error!NodeId {
    const c = try env.cells.result(env.gpa, env.account(), o, .none, k, at, Cell.Kind.ofPlace(env.places.kind(at)));
    return env.shapes.leaf(env.gpa, env.account(), at, try env.cells.sets.insert(env.gpa, env.charge, .none, c.int(), 0));
}

fn topLeaf(env: Env, at: PlaceId) Error!NodeId {
    const top = try env.cells.top(env.gpa, env.account());
    const n = try env.shapes.leaf(env.gpa, env.account(), at, try env.cells.sets.insert(env.gpa, env.charge, .none, top.int(), 0));
    _ = try env.conds.setKappa(env.gpa, env.charge, n, Cond.lost);
    return n;
}

fn crosses(env: Env, at: PlaceId) bool {
    return env.places.kind(at) == .cross;
}

/// `n` or `union(acc, n)`.
fn addRes(env: Env, acc: NodeId, n: NodeId) Error!NodeId {
    if (acc == .none) return n;
    return env.shapes.@"union"(env.gpa, env.account(), &env.cells.sets, acc, n);
}

/// The class a worded signature gives (oc §24.2, R-5.10.2/3), origin
/// `words`.
pub fn fromWords(env: Env, sums: *Summary.Table, sig: Signature) Error!ClassId {
    const gpa = env.gpa;
    const n: u32 = @intCast(sig.params.len);
    var params: std.ArrayList(NodeId) = .empty;
    defer params.deinit(gpa);
    var funs: std.ArrayList(Summary.DraftFun) = .empty;
    defer funs.deinit(gpa);
    var supplies: std.ArrayList(Summary.Supply) = .empty;
    defer supplies.deinit(gpa);
    var slots: std.ArrayList(Summary.Slot) = .empty;
    defer slots.deinit(gpa);
    var res: NodeId = .none;
    var returned = false;
    var writes = false;
    // Each fun's run of `supplies`, cut into slices once the list is complete.
    var fun_runs: std.ArrayList([2]u32) = .empty;
    defer fun_runs.deinit(gpa);
    const entry_bit = Word.entry.bit();
    for (sig.params, 0..) |prm, iu| {
        const i: u32 = @intCast(iu);
        var words = prm.words & ~entry_bit;
        if (words == 0) words = Word.escaped.bit();
        var use: NodeId = .none;
        if (prm.fn_params) |fps| {
            // A function (or a list of them): how often it is called, what
            // it is handed, whether JavaScript keeps it.
            const kept = has(words, .escaped);
            const calls: Summary.Calls = if (has(words, .unused)) .zero else if (has(words, .once)) .once else .many;
            var j = i;
            if (prm.list_of_fns) {
                j = n + @as(u32, @intCast(slots.items.len));
                const root = try env.places.rootPath(gpa, prm.place);
                const at = (try env.places.extend(gpa, env.charge, root, Step.elem)) orelse root;
                try slots.append(gpa, .{ .param = i, .path = at });
            }
            const first: u32 = @intCast(supplies.items.len);
            if (calls != .zero) {
                for (fps, 0..) |fp, k| {
                    const node = if (has(words, .owned)) try freshLeaf(env, .result, 0, fp) else try topLeaf(env, fp);
                    try supplies.append(gpa, .{ .j = j, .k = @intCast(k), .node = node, .point = 0, .owned = has(words, .owned), .taken = false, .cond = if (has(words, .owned)) Cond.yes else Cond.lost });
                }
            }
            // Supplies are appended to one list; the fun's slice is cut
            // below, once the list is complete.
            try funs.append(gpa, .{ .j = j, .calls = calls, .seen = !kept });
            try fun_runs.append(gpa, .{ first, @intCast(supplies.items.len - first) });
            if (kept) {
                use = try Summary.Table.markUse(env, .none, prm.place, &.{}, .{ .r = true, .e = true }, &.{});
            } else if (calls != .zero or prm.list_of_fns) {
                use = try Summary.Table.markUse(env, .none, prm.place, &.{}, .{ .r = true }, &.{});
            }
            if (!crosses(env, sig.result)) {
                const root = try env.places.rootPath(gpa, sig.result);
                const cb = try env.cells.symbolic(gpa, env.account(), env.places, .cb, Ids.none_int, root, j);
                const cb_leaf = try env.shapes.leaf(gpa, env.account(), sig.result, try env.cells.sets.insert(gpa, env.charge, .none, cb.int(), 0));
                if (has(words, .returned)) {
                    returned = true;
                    res = try addRes(env, res, cb_leaf);
                }
                if (has(words, .aliased)) res = try addRes(env, res, try env.shapes.recast(gpa, env.account(), sig.result, cb_leaf));
            }
            try params.append(gpa, use);
            continue;
        }
        var m: Summary.Marks = .{};
        if (!has(words, .unused)) m.r = true;
        if (has(words, .aliased) or has(words, .returned)) m.a = true;
        if (has(words, .escaped)) m.e = true;
        if (has(words, .consumed)) {
            m.w = true;
            m.deep = true;
            writes = true;
        }
        if (!m.isEmpty() and !crosses(env, prm.place)) use = try Summary.Table.markUse(env, .none, prm.place, &.{}, m, &.{});
        try params.append(gpa, use);
        if (crosses(env, prm.place) or crosses(env, sig.result)) continue;
        const root = try env.places.rootPath(gpa, prm.place);
        const p = try env.cells.symbolic(gpa, env.account(), env.places, .param, i, root, 0);
        const p_leaf = try env.shapes.leaf(gpa, env.account(), prm.place, try env.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
        if (has(words, .returned)) {
            returned = true;
            // The result IS the parameter: its leaf at the result's place
            // (a cast when the places differ structurally is the call's,
            // §2.13.9).
            res = try addRes(env, res, if (prm.place == sig.result) p_leaf else try env.shapes.recast(gpa, env.account(), sig.result, p_leaf));
        }
        if (has(words, .aliased)) res = try addRes(env, res, try env.shapes.recast(gpa, env.account(), sig.result, p_leaf));
    }
    // Cut the funs' supply slices now that the list is complete.
    for (funs.items, fun_runs.items) |*f, run| f.supplies = supplies.items[run[0]..][0..run[1]];
    const rw = sig.result_words;
    if (crosses(env, sig.result)) {
        res = try env.shapes.nothing(gpa, env.account(), sig.result);
    } else if (has(rw, .fresh)) {
        const f = try freshLeaf(env, .result, 1, sig.result);
        res = try addRes(env, res, if (has(rw, .exclusive)) f else try env.shapes.recast(gpa, env.account(), sig.result, f));
    } else if (has(rw, .escaped)) {
        res = try addRes(env, res, try env.shapes.recast(gpa, env.account(), sig.result, try freshLeaf(env, .esc, 1, sig.result)));
    } else if (has(rw, .unknown) or !returned) {
        res = try addRes(env, res, try topLeaf(env, sig.result));
    }
    return sums.add(env, .{
        .params = params.items,
        .res = res,
        .funs = funs.items,
        .slots = slots.items,
        .writes = writes,
        .entry = sig.entry,
        .origin = .words,
    });
}

/// A constructor's class (§2.13.1): `res` a node at the type's place with
/// `C#i ↦ πᵢ` for every tracked argument, every tracked πᵢ `A`, κ(res)
/// `apart` over the arguments' cells (I-κ's two-paths clause). A
/// record-alias constructor is a record literal: `fresh 1` at ε and field
/// steps. `steps[i]` is argument `i`'s step; `arg_places[i]` its place.
pub fn ctorClass(env: Env, sums: *Summary.Table, type_place: PlaceId, steps: []const Step, arg_places: []const PlaceId, record_alias: bool) Error!ClassId {
    const gpa = env.gpa;
    std.debug.assert(steps.len == arg_places.len);
    var params: std.ArrayList(NodeId) = .empty;
    defer params.deinit(gpa);
    var children: u32 = Ids.none_int;
    var items: std.ArrayList(Cond.Table.Item) = .empty;
    defer items.deinit(gpa);
    for (arg_places, steps, 0..) |at, s, iu| {
        const i: u32 = @intCast(iu);
        if (crosses(env, at)) {
            try params.append(gpa, .none);
            continue;
        }
        try params.append(gpa, try Summary.Table.markUse(env, .none, at, &.{}, .{ .a = true }, &.{}));
        const root = try env.places.rootPath(gpa, at);
        const p = try env.cells.symbolic(gpa, env.account(), env.places, .param, i, root, 0);
        try items.append(gpa, .{ .cell = p, .approx = false });
        const leaf = try env.shapes.leaf(gpa, env.account(), at, try env.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
        children = try env.shapes.overPut(gpa, env.account(), children, s, leaf);
    }
    var cells: SetId = .none;
    if (record_alias) {
        const f = try env.cells.result(gpa, env.account(), .result, .none, 1, type_place, .record);
        cells = try env.cells.sets.insert(gpa, env.charge, .none, f.int(), 0);
    }
    const res = if (crosses(env, type_place)) try env.shapes.nothing(gpa, env.account(), type_place) else try env.shapes.node(gpa, env.account(), type_place, cells, children);
    if (!crosses(env, type_place)) {
        const k = try env.conds.apart(gpa, env.charge, env.cells, env.places, items.items, null);
        _ = try env.conds.setKappa(gpa, env.charge, res, k);
    }
    return sums.add(env, .{ .params = params.items, .res = res, .origin = .asserted });
}

/// A derived `eq`/`compare`'s class (§2.13.6, §2.13.13): both arguments
/// read deeply, nothing kept, a crossing result; origin `asserted`.
pub fn derivedClass(env: Env, sums: *Summary.Table, arg_place: PlaceId, result_place: PlaceId) Error!ClassId {
    const use = if (crosses(env, arg_place)) NodeId.none else try Summary.Table.markUse(env, .none, arg_place, &.{}, .{ .r = true, .deep = true }, &.{});
    const res = try env.shapes.nothing(env.gpa, env.account(), result_place);
    return sums.add(env, .{ .params = &.{ use, use }, .res = res, .origin = .asserted });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A test type graph: 0 `List Int`, 1 `Int`, 2 `List (List Int)`, 3 a
/// function `Int → Int` (a closure leaf), 4 `List (Int → Int)`, 5 a record
/// `{ a : List Int, b : List Int }`, 6 `type T = C (List Int) Int (List Int)`.
const TestGraph = struct {
    table: *Place.Table,
    account: *Ids.Account,
    gpa: Allocator,

    fn describe(ctx: *anyopaque, v: u32, out: *std.ArrayList(Place.Child)) Allocator.Error!Place.Description {
        const g: *TestGraph = @ptrCast(@alignCast(ctx));
        switch (v) {
            0 => {
                try out.append(g.gpa, .{ .step = Step.elem, .@"var" = 1 });
                return .{ .kind = .list, .head = 200 };
            },
            1 => return .{ .kind = .cross },
            2 => {
                try out.append(g.gpa, .{ .step = Step.elem, .@"var" = 0 });
                return .{ .kind = .list, .head = 200 };
            },
            3 => return .{ .kind = .closure, .head = 300 },
            4 => {
                try out.append(g.gpa, .{ .step = Step.elem, .@"var" = 3 });
                return .{ .kind = .list, .head = 200 };
            },
            5 => {
                try out.append(g.gpa, .{ .step = (Step.field(g.account, 10) catch unreachable), .@"var" = 0 });
                try out.append(g.gpa, .{ .step = (Step.field(g.account, 11) catch unreachable), .@"var" = 0 });
                return .{ .kind = .record };
            },
            6 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 0, 0) catch unreachable), .@"var" = 0 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 0, 1) catch unreachable), .@"var" = 1 });
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 0, 2) catch unreachable), .@"var" = 0 });
                return .{ .kind = .ctor, .head = 600 };
            },
            else => unreachable,
        }
    }
};

const Fixture = struct {
    places: Place.Table = .{},
    cells: Cell.Table = .{},
    shapes: Shape.Table = .{},
    conds: Cond.Table = undefined,
    sums: Summary.Table = .{},
    account: Ids.Account = .{},
    graph: TestGraph = undefined,
    arena: std.heap.ArenaAllocator = undefined,

    fn init(f: *Fixture) !void {
        f.graph = .{ .table = &f.places, .account = &f.account, .gpa = testing.allocator };
        f.conds = try Cond.Table.init(testing.allocator, .growth(&f.account));
        f.arena = std.heap.ArenaAllocator.init(testing.allocator);
    }

    fn deinit(f: *Fixture) void {
        f.places.deinit(testing.allocator);
        f.cells.deinit(testing.allocator);
        f.shapes.deinit(testing.allocator);
        f.conds.deinit(testing.allocator);
        f.sums.deinit(testing.allocator);
        f.account.deinit(testing.allocator);
        f.arena.deinit();
    }

    fn env(f: *Fixture) Env {
        return .{ .gpa = testing.allocator, .charge = .growth(&f.account), .places = &f.places, .cells = &f.cells, .shapes = &f.shapes, .conds = &f.conds };
    }

    fn placeOf(f: *Fixture, v: u32) !PlaceId {
        return f.places.of(testing.allocator, &f.account, .{ .ctx = &f.graph, .describe = TestGraph.describe }, v);
    }

    fn text(f: *Fixture, c: ClassId, name: []const u8) ![]const u8 {
        var buf: std.Io.Writer.Allocating = .init(f.arena.allocator());
        try f.sums.print(f.env(), f.arena.allocator(), &buf.writer, c, name, test_names);
        return buf.toOwnedSlice();
    }
};

const TestNames = struct {
    fn field(_: *anyopaque, rank: u32) []const u8 {
        return if (rank == 10) "a" else if (rank == 11) "b" else "?";
    }
    fn ctor(_: *anyopaque, _: u32, _: u32) []const u8 {
        return "C";
    }
    fn decl(_: *anyopaque, _: u32, _: u32) []const u8 {
        return "M.v";
    }
};
var test_names_ctx: u8 = 0;
const test_names: Summary.Names = .{ .ctx = &test_names_ctx, .field = TestNames.field, .ctor = TestNames.ctor, .decl = TestNames.decl };

fn bits(words: []const Word) u32 {
    var acc: u32 = 0;
    for (words) |x| acc |= x.bit();
    return acc;
}

test "today's parameter and result words give oc §24.2's rows" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const list = try f.placeOf(0);
    const int = try f.placeOf(1);
    // `push : written returned List a, borrowed Int, …`-like: returned is
    // RA with res π1; borrowed R; a crossing parameter carries nothing.
    const c1 = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = list, .words = bits(&.{.returned}) }, .{ .place = int, .words = bits(&.{.borrowed}) } }, .result = list });
    try testing.expectEqualStrings("summary push: π1 RA; res π1 (words)", try f.text(c1, "push"));
    // No word is `escaped`; no result word and no returned parameter is ⊤.
    const c2 = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = list }}, .result = list });
    try testing.expectEqualStrings("summary f: π1 RE; res ⊤{lost} (words)", try f.text(c2, "f"));
    // consumed: RS, writes. fresh exclusive: fresh1, κ yes. unused: nothing.
    const c3 = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = list, .words = bits(&.{.consumed}) }, .{ .place = list, .words = bits(&.{.unused}) } }, .result = list, .result_words = bits(&.{ .fresh, .exclusive }) });
    try testing.expectEqualStrings("summary g: π1 RS; res fresh1 (words)", try f.text(c3, "g"));
    try testing.expect(f.sums.get(c3).writes and !f.sums.get(c1).writes);
    try testing.expectEqual(Cond.yes, try f.conds.kappaOf(testing.allocator, env.charge, &f.shapes, &f.cells, f.sums.get(c3).res));
    // fresh alone: the call made it, contents may be shared: a recast, lost.
    const c4 = try fromWords(env, &f.sums, .{ .params = &.{}, .result = list, .result_words = bits(&.{.fresh}) });
    try testing.expectEqualStrings("summary h: res ~fresh1{lost} (words)", try f.text(c4, "h"));
    try testing.expectEqual(Shape.Kind.recast, f.shapes.kind(f.sums.get(c4).res));
    // aliased: RA and the parameter anywhere in the result, approximate;
    // a demand below the result still finds the parameter (an ancestor).
    const lists = try f.placeOf(2);
    const c5 = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = list, .words = bits(&.{.aliased}) }}, .result = lists, .result_words = bits(&.{.escaped}) });
    try testing.expectEqualStrings("summary k: π1 RA; res ~esc1 ~π1{lost} (words)", try f.text(c5, "k"));
    const below = try f.shapes.cellsAt(testing.allocator, &f.account, &f.places, &f.cells, f.sums.get(c5).res, &.{Step.elem});
    try testing.expectEqual(@as(u32, 2), f.cells.sets.count(below));
    // A crossing result: nothing, whatever the words.
    const c6 = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = list, .words = bits(&.{.borrowed}) }}, .result = int, .result_words = bits(&.{.fresh}) });
    try testing.expectEqualStrings("summary n: π1 R (words)", try f.text(c6, "n"));
    try testing.expect(f.sums.get(c6).entry == false);
    const c7 = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = list, .words = bits(&.{ .borrowed, .entry }) }}, .result = int, .entry = true });
    try testing.expect(f.sums.get(c7).entry);
}

test "function parameters: calls, owned supplies, escaped, returned; a list of functions is a slot" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const list = try f.placeOf(0);
    const fun = try f.placeOf(3);
    const funs = try f.placeOf(4);
    // `many owned (List Int → List Int)`: calls many, each supply fresh and owned.
    const c1 = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = list, .words = bits(&.{.borrowed}) }, .{ .place = fun, .words = bits(&.{ .many, .owned }), .fn_params = &.{list} } }, .result = list, .result_words = bits(&.{ .fresh, .exclusive }) });
    try testing.expectEqualStrings("summary m: π1 R, π2 R; res fresh1; π2 calls many, supply 1 fresh owned (words)", try f.text(c1, "m"));
    // `once` without owned: the supply is ⊤ borrowed; `returned` makes the
    // result what it returns.
    const c2 = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = fun, .words = bits(&.{ .once, .returned }), .fn_params = &.{list} }}, .result = list });
    try testing.expectEqualStrings("summary p: π1 R; res cb1; π1 calls ≤1, supply 1 ⊤ borrowed{lost} (words)", try f.text(c2, "p"));
    // `escaped` function: kept by JavaScript, calls many, unseen, RE.
    const c3 = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = fun, .words = bits(&.{.escaped}), .fn_params = &.{} }}, .result = list, .result_words = bits(&.{.unknown}) });
    try testing.expectEqualStrings("summary q: π1 RE; res ⊤{lost}; π1 calls many, unseen (words)", try f.text(c3, "q"));
    // `unused` function: calls 0, no use.
    const c4 = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = fun, .words = bits(&.{.unused}), .fn_params = &.{list} }}, .result = list, .result_words = bits(&.{ .fresh, .exclusive }) });
    try testing.expectEqualStrings("summary r: res fresh1; π1 calls 0 (words)", try f.text(c4, "r"));
    // `many aliased List (⊤ → a)` (Task.raceOk): a slot at π1[*], its result
    // anywhere in the result, approximate.
    const c5 = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = funs, .words = bits(&.{ .many, .aliased }), .fn_params = &.{}, .list_of_fns = true }}, .result = list, .result_words = bits(&.{.fresh}) });
    try testing.expectEqualStrings("summary s: π1 R; res ~cb(π1[*]) ~fresh1{lost}; π1[*] calls many (words)", try f.text(c5, "s"));
    try testing.expectEqual(@as(u32, 1), f.sums.get(c5).slots.len);
}

test "a constructor's class and a derived method's class" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const list = try f.placeOf(0);
    const int = try f.placeOf(1);
    const t = try f.placeOf(6);
    const s0 = try f.places.ctorStep(testing.allocator, &f.account, 0, 0);
    const s1 = try f.places.ctorStep(testing.allocator, &f.account, 0, 1);
    const s2 = try f.places.ctorStep(testing.allocator, &f.account, 0, 2);
    // `C : List Int, Int, List Int → T`: the tracked arguments A, the result
    // a node with `#C.0 ↦ π1`, `#C.2 ↦ π3`, κ `apart{π1, π3}`.
    const c = try ctorClass(env, &f.sums, t, &.{ s0, s1, s2 }, &.{ list, int, list }, false);
    try testing.expectEqualStrings("summary C: π1 A, π3 A; res #C.0 π1, #C.2 π3, {apart [π1] [π3]} (asserted)", try f.text(c, "C"));
    // A record alias constructor: a record literal, fresh at ε.
    const rec = try f.placeOf(5);
    const fa = try Step.field(&f.account, 10);
    const fb = try Step.field(&f.account, 11);
    const ra = try ctorClass(env, &f.sums, rec, &.{ fa, fb }, &.{ list, list }, true);
    try testing.expectEqualStrings("summary R: π1 A, π2 A; res .a π1, .b π2, fresh1{apart [π1] [π2]} (asserted)", try f.text(ra, "R"));
    // One tracked argument: no atom.
    const one = try ctorClass(env, &f.sums, t, &.{ s0, s1 }, &.{ list, int }, false);
    try testing.expectEqual(Cond.yes, try f.conds.kappaOf(testing.allocator, env.charge, &f.shapes, &f.cells, f.sums.get(one).res));
    // eq/compare: both arguments read deeply, a crossing result.
    const eq = try derivedClass(env, &f.sums, list, int);
    try testing.expectEqualStrings("summary eq: π1 R, π2 R (asserted)", try f.text(eq, "eq"));
    try testing.expect(try Summary.Table.usedAt(env, f.sums.paramUses(eq)[0], &.{Step.elem}));
    try testing.expect(!f.sums.get(eq).writes);
}
