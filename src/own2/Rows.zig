//! L6: rows as data (`docs/design/ownership-v2.md` §2.13.1, §2.13.6,
//! §2.13.13; oc §24.2): the classes that are not read off a body. A worded
//! constructor's from its type (`ctorClass`), a derived `eq`/`compare`'s
//! composed of its components' (`derivedClass`). Nothing here names a declaration, a type or
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
//! | `fresh` | `fresh 1` at every path, approximate (a recast: the call made it, its contents may be shared), κ `lost` only where objects sit below, `yes` for a list of plain values |
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

/// A leaf holding `⊤`: its κ derives as `lost` (§2.9) under any map.
fn topLeaf(env: Env, at: PlaceId) Error!NodeId {
    const top = try env.cells.top(env.gpa, env.account());
    return env.shapes.leaf(env.gpa, env.account(), at, try env.cells.sets.insert(env.gpa, env.charge, .none, top.int(), 0));
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
        // A `List` of functions is a function slot only when its words say
        // how often the elements are called (`once`, `many`, `unused`), as
        // v1 reads it (oc §30.9); a `borrowed` list of functions is a plain
        // parameter.
        const as_function = prm.fn_params != null and (!prm.list_of_fns or has(words, .once) or has(words, .many) or has(words, .unused));
        if (as_function) {
            const fps = prm.fn_params.?;
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
                    try supplies.append(gpa, .{ .j = j, .k = @intCast(k), .node = node, .label = .none, .owned = has(words, .owned), .taken = false, .kappa = .none });
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
    var items: std.ArrayList(Cond.Item) = .empty;
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
    var kappas: Cond.Kappas = .none;
    if (!crosses(env, type_place)) {
        const k = try env.conds.apart(gpa, env.charge, env.cells, env.places, items.items, null);
        kappas = (try env.conds.kappaSet(gpa, env.charge, .none, res, false, k)).ctx;
    }
    return sums.add(env, .{ .params = params.items, .res = res, .kappas = kappas, .origin = .asserted });
}

/// Whether a use shape carries the mark `m` anywhere (its `reach`).
fn usesMark(env: Env, use: NodeId, m: Cell.Mark) Error!bool {
    if (use == .none) return false;
    const r = try env.shapes.reach(env.gpa, env.account(), &env.cells.sets, use);
    return env.cells.sets.member(r, (try env.cells.mark(env.gpa, env.account(), m, 0)).int());
}

/// A derived `eq`/`compare`'s class (§2.13.6, §2.13.13): both arguments
/// read deeply, a crossing result; origin `asserted`. The derived method
/// calls the components' own `eq`/`compare` (`components`, the classes of
/// the user-written ones), so it is what they are: a component that lets
/// its argument escape (`E` anywhere in its use) makes the derived
/// argument `E` deep, and a component that writes makes it `writes`
/// (R-5.13.1's `comparison_changes_value` then fires through it). A
/// comparison cannot keep its argument in its result (`Bool`/`Order`
/// cross), so `A` never arises.
pub fn derivedClass(env: Env, sums: *Summary.Table, arg_place: PlaceId, result_place: PlaceId, components: []const ClassId) Error!ClassId {
    var escapes = false;
    var writes = false;
    for (components) |c| {
        try env.charge.reserve(env.gpa, .inspection, 1);
        writes = writes or sums.get(c).writes;
        for (sums.paramUses(c)) |u| escapes = escapes or try usesMark(env, u, .e);
    }
    const use = if (crosses(env, arg_place)) NodeId.none else try Summary.Table.markUse(env, .none, arg_place, &.{}, .{ .r = true, .e = escapes, .deep = true }, &.{});
    const res = try env.shapes.nothing(env.gpa, env.account(), result_place);
    return sums.add(env, .{ .params = &.{ use, use }, .res = res, .writes = writes, .origin = .asserted });
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
    try testing.expectEqual(Cond.yes, try env.kappa(f.sums.get(c3).kappas, f.sums.get(c3).res));
    // fresh alone: the call made it, its contents may be shared: a recast,
    // whose κ is lost only where objects sit below — a `List Int` is yes (G4).
    const c4 = try fromWords(env, &f.sums, .{ .params = &.{}, .result = list, .result_words = bits(&.{.fresh}) });
    try testing.expectEqualStrings("summary h: res ~fresh1 (words)", try f.text(c4, "h"));
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
    try testing.expectEqualStrings("summary s: π1 R; res ~cb(π1[*]) ~fresh1; π1[*] calls many (words)", try f.text(c5, "s"));
    try testing.expectEqual(@as(u32, 1), f.sums.get(c5).slots.len);
    // v1's rule: without `once`/`many`/`unused` a `List` of functions is a
    // plain parameter — `borrowed List (a → b)` is R, no slot, no calls.
    const c6 = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = funs, .words = bits(&.{.borrowed}), .fn_params = &.{}, .list_of_fns = true }}, .result = list, .result_words = bits(&.{ .fresh, .exclusive }) });
    try testing.expectEqualStrings("summary t: π1 R; res fresh1 (words)", try f.text(c6, "t"));
    try testing.expectEqual(@as(u32, 0), f.sums.get(c6).slots.len);
    try testing.expectEqual(@as(u32, 0), f.sums.funCount(c6));
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
    // One tracked argument: no atom; the class owns its κ.
    const one = try ctorClass(env, &f.sums, t, &.{ s0, s1 }, &.{ list, int }, false);
    try testing.expectEqual(Cond.yes, try env.kappa(f.sums.get(one).kappas, f.sums.get(one).res));
    try testing.expectEqual(Cond.Kind.atom, f.conds.kind(try env.kappa(f.sums.get(c).kappas, f.sums.get(c).res)));
    // eq/compare over components whose `eq` only reads: both arguments
    // read deeply, a crossing result.
    const reader = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = list, .words = bits(&.{.borrowed}) }, .{ .place = list, .words = bits(&.{.borrowed}) } }, .result = int });
    const eq = try derivedClass(env, &f.sums, list, int, &.{reader});
    try testing.expectEqualStrings("summary eq: π1 R, π2 R (asserted)", try f.text(eq, "eq"));
    try testing.expect(try Summary.Table.usedAt(env, f.sums.paramUses(eq)[0], &.{Step.elem}));
    try testing.expect(!f.sums.get(eq).writes);
    // A user-written component `eq` that lets its argument escape (through
    // a wordless foreign) or writes it: the derived class says so.
    const escaper = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = list }, .{ .place = list, .words = bits(&.{.borrowed}) } }, .result = int });
    const eq2 = try derivedClass(env, &f.sums, list, int, &.{ reader, escaper });
    try testing.expectEqualStrings("summary eq2: π1 RE, π2 RE (asserted)", try f.text(eq2, "eq2"));
    const writer = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = list, .words = bits(&.{.consumed}) }, .{ .place = list, .words = bits(&.{.borrowed}) } }, .result = int });
    const eq3 = try derivedClass(env, &f.sums, list, int, &.{writer});
    try testing.expect(f.sums.get(eq3).writes);
    try testing.expectEqualStrings("summary eq3: π1 R, π2 R (asserted)", try f.text(eq3, "eq3"));
}

// ---------------------------------------------------------------------------
// Appendix C's worked derivation, checked with the S1/S2 modules
// ---------------------------------------------------------------------------
//
// `docs/design/ownership-v2.md` Appendix C derives `mapHelp`'s and
// `foldlFrom`'s classes on paper. S2 has no walker, no `Calls` and no
// read-off, so these tests do by hand what those will do — instantiate a
// callee's atoms at the recursive call (the substitution C.2's table names)
// and fold its labels (§2.2, §2.10's read-off: a label under `[*]` or of the
// frame's own group folds, two different labels folding into one emit
// `within`) — and let S2's own operations do the rest: §2.9's construction
// rule (`Cond.lower`), the instantiation (`Cond.instantiate`), the joins of
// the two arms (`Cond.join`, `Summary.Table.joinRes`) and the order
// (`Cond.leq`). Each round's κ (and, for foldlFrom, `res` and the feedback
// supply) is compared with the table's row, and the fixpoint is the round
// the next round reproduces. What the tests do NOT check: the uses, calls
// and supplies of mapHelp's class, which only a walker reads off (S3b);
// and the fold rule itself, which the test applies as C.2 states it.

/// The derivation's cells and labels: `π₁ a`, `π₄ acc`, `π₆ b` and the
/// callback's results `cb₅@ℓ` at `res[*]` (mapHelp) or `res` (foldlFrom).
const Derivation = struct {
    f: *Fixture,
    lists: PlaceId,
    list: PlaceId,
    elem_path: Ids.PathId,
    root_path: Ids.PathId,
    /// ι_f, ι_rec, ι_t, and the folded ι_f⋆ and ι_rec⋆.
    l_f: Ids.LabelId,
    l_f_star: Ids.LabelId,
    l_rec_star: Ids.LabelId,
    /// `ι_rec·ι_f⋆` and `ι_rec·ι_rec⋆`: the callee's labels prefixed with
    /// the recursive call, before the read-off folds them.
    l_rec_f_star: Ids.LabelId,
    l_rec_rec_star: Ids.LabelId,
    /// `ι_rec·ι_f`: the callee's unfolded callback label (foldlFrom).
    l_rec_f: Ids.LabelId,

    const i_f: u32 = 10;
    const i_rec: u32 = 11;
    const i_t: u32 = 12;

    fn init(f: *Fixture) !Derivation {
        const gpa = testing.allocator;
        const lists = try f.placeOf(2);
        const root = try f.places.rootPath(gpa, lists);
        const f_star = try f.cells.label(gpa, &f.account, i_f, .none, true);
        const rec_star = try f.cells.label(gpa, &f.account, i_rec, .none, true);
        return .{
            .f = f,
            .lists = lists,
            .list = try f.placeOf(0),
            .root_path = root,
            .elem_path = (try f.places.extend(gpa, f.env().charge, root, Step.elem)).?,
            .l_f = try f.cells.label(gpa, &f.account, i_f, .none, false),
            .l_f_star = f_star,
            .l_rec_star = rec_star,
            .l_rec_f_star = try f.cells.label(gpa, &f.account, i_rec, f_star, false),
            .l_rec_rec_star = try f.cells.label(gpa, &f.account, i_rec, rec_star, false),
            .l_rec_f = try f.cells.label(gpa, &f.account, i_rec, try f.cells.label(gpa, &f.account, i_f, .none, false), false),
        };
    }

    fn param(d: *Derivation, i: u32, at_elem: bool) !CellId {
        return d.f.cells.symbolic(testing.allocator, &d.f.account, &d.f.places, .param, i, if (at_elem) d.elem_path else d.root_path, 0);
    }

    /// `cb₅@ℓ`: what the function parameter π₅ (j = 4) answered at `ℓ`.
    fn cb(d: *Derivation, l: Ids.LabelId, at_elem: bool) !CellId {
        return d.f.cells.symbolic(testing.allocator, &d.f.account, &d.f.places, .cb, l.int(), if (at_elem) d.elem_path else d.root_path, 4);
    }

    fn set(d: *Derivation, cs: []const CellId) !SetId {
        var s: SetId = .none;
        for (cs) |c| s = try d.f.cells.sets.insert(testing.allocator, d.f.env().charge, s, c.int(), 0);
        return s;
    }

    fn excl(d: *Derivation, c: CellId) !Ids.CondId {
        return d.f.conds.excl(testing.allocator, d.f.env().charge, c);
    }

    fn apart2(d: *Derivation, a: CellId, b: CellId) !Ids.CondId {
        return d.f.conds.apartAtom(testing.allocator, d.f.env().charge, try d.set(&.{ a, b }));
    }

    fn all(d: *Derivation, ks: []const Ids.CondId) !Ids.CondId {
        var acc = Cond.yes;
        for (ks) |k| acc = try d.f.conds.@"and"(testing.allocator, d.f.env().charge, acc, k);
        return acc;
    }

    /// Two conditions name the same atoms.
    fn same(d: *Derivation, a: Ids.CondId, b: Ids.CondId) !bool {
        const gpa = testing.allocator;
        const charge = d.f.env().charge;
        return try d.f.conds.leq(gpa, charge, a, b) and try d.f.conds.leq(gpa, charge, b, a);
    }
};

/// The read-off's fold of one cell (§2.2): the labels the table folds, by
/// the rule C.2 states.
fn foldCell(d: *Derivation, c: CellId, fold_direct: bool) !CellId {
    const cells = &d.f.cells;
    if (cells.origin(c) != .cb) return c;
    const l: Ids.LabelId = .from(cells.get(c).a);
    if (l == d.l_rec_f_star or l == d.l_rec_rec_star or l == d.l_rec_f) return d.cb(d.l_rec_star, cells.place(c) != d.lists and fold_direct);
    if (l == d.l_f and fold_direct) return d.cb(d.l_f_star, true);
    return c;
}

/// An instantiation at ι_rec, as `Calls` will do it (S3b): each callee atom
/// mapped through the substitution, then folded. `excl π₆[*]` is the
/// argument's condition at that path; a `sep`/`apart` between two cells is
/// compared at the argument's cells; one that compares two cells folding
/// into one label is that label's `within` (§2.10's read-off).
const Instantiation = struct {
    d: *Derivation,
    /// The parameter cell the call substitutes (π₆[*] for mapHelp, π₄ for
    /// foldlFrom) ↦ these cells, and their condition there.
    p6e: CellId,
    p6e_to: []const CellId,
    p6e_kappa: Ids.CondId,
    /// mapHelp folds a direct callback label (it is under `[*]`);
    /// foldlFrom does not.
    fold_direct: bool,
    /// False: the read-off's fold alone, no call between (a store's own
    /// κ, read off in its own frame).
    prefix: bool = true,

    fn image(in: *Instantiation, c: CellId) ![]const CellId {
        if (!in.prefix) {
            const out = try in.d.f.arena.allocator().alloc(CellId, 1);
            out[0] = c;
            return out;
        }
        if (c == in.p6e) return in.p6e_to;
        const cells = &in.d.f.cells;
        if (cells.origin(c) == .cb) {
            const l: Ids.LabelId = .from(cells.get(c).a);
            const prefixed = if (l == in.d.l_f_star) in.d.l_rec_f_star else if (l == in.d.l_rec_star) in.d.l_rec_rec_star else if (l == in.d.l_f) in.d.l_rec_f else l;
            const out = try in.d.f.arena.allocator().alloc(CellId, 1);
            out[0] = try in.d.cb(prefixed, cells.place(c) != in.d.lists);
            return out;
        }
        const out = try in.d.f.arena.allocator().alloc(CellId, 1);
        out[0] = c;
        return out;
    }

    fn atom(ctx: *anyopaque, t: *Cond.Table, gpa: Allocator, charge: Ids.Charge, a: Cond.Cond) Error!Ids.CondId {
        const in: *Instantiation = @ptrCast(@alignCast(ctx));
        const d = in.d;
        switch (a.atom) {
            .excl => {
                const c: CellId = .from(a.a);
                if (c == in.p6e and in.prefix) return in.p6e_kappa;
                var acc = Cond.yes;
                for (try in.image(c)) |x| acc = try t.@"and"(gpa, charge, acc, try t.excl(gpa, charge, try foldCell(d, x, in.fold_direct)));
                return acc;
            },
            .apart, .sep => {
                // The two sides: a sep's cells, or a two-member group's.
                var sides: [2]CellId = undefined;
                if (a.atom == .sep) {
                    sides = .{ .from(a.a), .from(a.b) };
                } else {
                    var it = d.f.cells.sets.iterate(.from(a.a));
                    sides[0] = .from(it.next().?.key);
                    sides[1] = .from(it.next().?.key);
                    std.debug.assert(it.next() == null);
                }
                var acc = Cond.yes;
                for (try in.image(sides[0])) |x| for (try in.image(sides[1])) |y| {
                    const fx = try foldCell(d, x, in.fold_direct);
                    const fy = try foldCell(d, y, in.fold_direct);
                    const k = if (fx == fy) blk: {
                        // Two labels folding into one: the read-off's `within`.
                        std.debug.assert(x != y);
                        break :blk try t.within(gpa, charge, .from(d.f.cells.get(fx).a));
                    } else try t.apartAtom(gpa, charge, try d.set(&.{ fx, fy }));
                    acc = try t.@"and"(gpa, charge, acc, k);
                };
                return acc;
            },
            .within => {
                // within(ι_rec⋆) ↦ within(ι_rec·ι_rec⋆), which folds back.
                std.debug.assert(@as(Ids.LabelId, .from(a.a)) == d.l_rec_star);
                return t.within(gpa, charge, d.l_rec_star);
            },
            else => unreachable,
        }
    }
};

test "Appendix C.2: mapHelp's κ at res[*] reaches the table's row at round 4 and round 5 reproduces it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var d = try Derivation.init(&f);
    const gpa = testing.allocator;
    const env = f.env();
    const v = env.view();
    const p6e = try d.param(5, true);
    const cb_f = try d.cb(d.l_f, true);
    const cb_f_star = try d.cb(d.l_f_star, true);
    const cb_rec_star = try d.cb(d.l_rec_star, true);

    // Step 3: `put b i (func …)` stores cb₅@ι_f into π₆'s storage. §2.9's
    // construction rule on the base π₆[*]: κ(N_p[*]) = κ(π₆[*]) ∧
    // apart{π₆[*], cb₅@ι_f} ∧ excl(cb₅@ι_f), C.2's `excl π₆ ∧ sep(cb₅@ι_f,
    // π₆[*]) ∧ excl(cb₅@ι_f)` (a two-member `apart` is v1's `sep`).
    const base_kappa = try f.conds.kappaOf(gpa, env.charge, v, .none, try f.shapes.leaf(gpa, &f.account, d.list, try d.set(&.{p6e})), true);
    try testing.expect(try d.same(base_kappa, try d.excl(p6e)));
    const stored = try f.shapes.leaf(gpa, &f.account, d.list, try d.set(&.{cb_f}));
    const k_np = try f.conds.lower(gpa, env.charge, v, .none, base_kappa, try d.set(&.{p6e}), stored, true, null);
    try testing.expect(try d.same(k_np, try d.all(&.{ try d.excl(p6e), try d.excl(cb_f), try d.apart2(p6e, cb_f) })));

    // The rounds, κ at res[*]: the else arm gives κ(π₆[*]); the then arm the
    // callee's previous κ instantiated at ι_rec (π₆[*] ↦ N_p[*]'s cells,
    // whose condition is k_np) and folded; the two arms join.
    // k_np with its ι_f folded by the read-off, as C.2 round 3 reads it.
    var fold_only: Instantiation = .{ .d = &d, .p6e = p6e, .p6e_to = &.{}, .p6e_kappa = .none, .fold_direct = true, .prefix = false };
    const k_np_folded = try f.conds.instantiate(gpa, env.charge, k_np, .{ .ctx = &fold_only, .atom = Instantiation.atom });
    try testing.expect(try d.same(k_np_folded, try d.all(&.{ try d.excl(p6e), try d.excl(cb_f_star), try d.apart2(p6e, cb_f_star) })));
    var in: Instantiation = .{ .d = &d, .p6e = p6e, .p6e_to = &.{ p6e, cb_f }, .p6e_kappa = k_np_folded, .fold_direct = true };
    const interp: Cond.Interp = .{ .ctx = &in, .atom = Instantiation.atom };
    const else_arm = try d.excl(p6e);
    // Round 1: A(ι_rec) = ∅, so the then arm adds nothing.
    var rounds: [6]Ids.CondId = undefined;
    rounds[1] = else_arm;
    var k: usize = 2;
    while (k <= 5) : (k += 1) {
        // Round 2: the callee is round 1, whose κ excl π₆ instantiates to
        // k_np, ι_f folded by the read-off (it occurs under `[*]`).
        const then_arm = try f.conds.instantiate(gpa, env.charge, rounds[k - 1], interp);
        rounds[k] = try f.conds.join(gpa, env.charge, else_arm, then_arm);
    }
    // Round 2's row: excl π₆ ∧ excl(ι_f⋆) ∧ sep(ι_f⋆, π₆[*]).
    try testing.expect(try d.same(rounds[2], try d.all(&.{ try d.excl(p6e), try d.excl(cb_f_star), try d.apart2(p6e, cb_f_star) })));
    // Round 3's row adds excl(ι_rec⋆), sep(ι_rec⋆, π₆[*]), sep(ι_f⋆, ι_rec⋆).
    const round3 = try d.all(&.{
        try d.excl(p6e),              try d.excl(cb_f_star),          try d.excl(cb_rec_star),
        try d.apart2(p6e, cb_f_star), try d.apart2(p6e, cb_rec_star), try d.apart2(cb_f_star, cb_rec_star),
    });
    try testing.expect(try d.same(rounds[3], round3));
    // Round 4's row: round 3 ∧ within(ι_rec⋆), the fold of sep((ι_rec·ι_f⋆),
    // (ι_rec·ι_rec⋆)).
    const round4 = try d.all(&.{ round3, try f.conds.within(gpa, env.charge, d.l_rec_star) });
    try testing.expect(try d.same(rounds[4], round4));
    // Round 5 reproduces round 4: the fixpoint, F(x) ⊑ x.
    try testing.expect(try d.same(rounds[5], rounds[4]));
    // The rounds climb: each is below (stronger than) the next.
    for (1..5) |r| try testing.expect(try f.conds.leq(gpa, env.charge, rounds[r], rounds[r + 1]));
    // Without the read-off's fold rule S2's `sep` answers the folded pair
    // `lost` (one folded label twice, §2.9): `within` is the read-off's,
    // owed by S3b (C.10).
    try testing.expectEqual(Cond.lost, try f.conds.sep(gpa, env.charge, &f.cells, &f.places, cb_rec_star, cb_rec_star, false, null));
}

test "Appendix C.4: foldlFrom's res, κ and feedback supply reach the table's row at round 3 and round 4 reproduces it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var d = try Derivation.init(&f);
    const gpa = testing.allocator;
    const env = f.env();
    // foldlFrom's res is at ε: π₄ acc and the callback's answers. A direct
    // callback call not under `[*]` does not fold; the recursive call's
    // labels do (C.4, round 2).
    const p4 = try d.param(3, false);
    const cb_f = try d.cb(d.l_f, false);
    const cb_rec_star = try d.cb(d.l_rec_star, false);
    const leafOf = struct {
        fn of(dd: *Derivation, cs: []const CellId) !NodeId {
            return dd.f.shapes.leaf(testing.allocator, &dd.f.account, dd.lists, try dd.set(cs));
        }
    }.of;
    const withK = struct {
        fn of(ff: *Fixture, n: NodeId, k: Ids.CondId) !Cond.Kappas {
            return (try ff.conds.kappaSet(testing.allocator, ff.env().charge, .none, n, false, k)).ctx;
        }
    }.of;
    // The call at ι_rec hands the callback's answer back as the
    // accumulator: π₄ ↦ cb₅@ι_f, whose condition there is its own `excl`.
    var in: Instantiation = .{ .d = &d, .p6e = p4, .p6e_to = &.{cb_f}, .p6e_kappa = try d.excl(cb_f), .fold_direct = false };
    const interp: Cond.Interp = .{ .ctx = &in, .atom = Instantiation.atom };
    // The else arm: res π₄, κ excl π₄.
    const else_node = try leafOf(&d, &.{p4});
    const else_k = try withK(&f, else_node, try d.excl(p4));
    const Round = struct { node: NodeId, kappas: Cond.Kappas, feedback: SetId };
    var rounds: [5]Round = undefined;
    // Round 1: A(ι_rec) = ∅; no recursive label has a supply yet.
    rounds[1] = .{ .node = else_node, .kappas = else_k, .feedback = .none };
    var r: usize = 2;
    while (r <= 4) : (r += 1) {
        const prev = rounds[r - 1];
        // The then arm: the callee's res mapped through the substitution and
        // folded, its κ instantiated by `Cond.instantiate`.
        var cells: std.ArrayList(CellId) = .empty;
        defer cells.deinit(gpa);
        var it = f.cells.sets.iterate(f.shapes.cells(prev.node));
        while (it.next()) |e| for (try in.image(.from(e.key))) |x| try cells.append(gpa, try foldCell(&d, x, false));
        const then_node = try leafOf(&d, cells.items);
        const then_k = try f.conds.instantiate(gpa, env.charge, try env.kappa(prev.kappas, prev.node), interp);
        const joined = try Summary.Table.joinRes(env, else_node, else_k, then_node, try withK(&f, then_node, then_k));
        // The feedback supply (§2.11 item 5): what the callback is handed
        // back as its accumulator at the folded label ι_rec⋆. At ι_rec·ι_f it
        // is π₄'s image; at ι_rec·ι_rec⋆ the callee's own feedback, mapped and
        // folded. Both labels fold into ι_rec⋆.
        var fb = try d.set(in.p6e_to);
        var fit = f.cells.sets.iterate(prev.feedback);
        while (fit.next()) |e| for (try in.image(.from(e.key))) |x| {
            fb = try f.cells.sets.insert(gpa, env.charge, fb, (try foldCell(&d, x, false)).int(), 0);
        };
        rounds[r] = .{ .node = joined.node, .kappas = joined.kappas, .feedback = fb };
    }
    // Round 2: res {π₄, cb₅@ι_f} (approximate), κ excl π₄ ∧ excl(ι_f); ι_rec⋆'s
    // feedback {cb₅@ι_f}.
    try testing.expectEqual(try d.set(&.{ p4, cb_f }), f.shapes.cells(rounds[2].node));
    try testing.expect(try d.same(try env.kappa(rounds[2].kappas, rounds[2].node), try d.all(&.{ try d.excl(p4), try d.excl(cb_f) })));
    try testing.expectEqual(try d.set(&.{cb_f}), rounds[2].feedback);
    // Round 3: res {π₄, ι_f, ι_rec⋆}, κ ∧ excl(ι_rec⋆); the feedback supply
    // {cb₅@ι_f, cb₅@ι_rec⋆}, C.4's supply 2.
    try testing.expectEqual(try d.set(&.{ p4, cb_f, cb_rec_star }), f.shapes.cells(rounds[3].node));
    try testing.expect(try d.same(try env.kappa(rounds[3].kappas, rounds[3].node), try d.all(&.{ try d.excl(p4), try d.excl(cb_f), try d.excl(cb_rec_star) })));
    try testing.expectEqual(try d.set(&.{ cb_f, cb_rec_star }), rounds[3].feedback);
    // Round 4: nothing new, the fixpoint.
    try testing.expectEqual(rounds[3].node, rounds[4].node);
    try testing.expect(try d.same(try env.kappa(rounds[4].kappas, rounds[4].node), try env.kappa(rounds[3].kappas, rounds[3].node)));
    try testing.expectEqual(rounds[3].feedback, rounds[4].feedback);
}
