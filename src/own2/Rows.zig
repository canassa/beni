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
//! **v2's words** (§2.13.6, §2.13.7), read against the PLACE's kind — a
//! sequence's `[*]`, a cell's `◆` — which the place adapter derives from the
//! `sequence`/`cell` type metadata; a word whose place lacks that kind is
//! no word (R-5.10.3) — except a callback whose answer is put back: one
//! whose places give no write-back makes the whole signature `⊤call`, since
//! dropping the write-back would say the answer is discarded. No name is
//! read: a renamed type gives the same row.
//!
//! | word | row |
//! |---|---|
//! | `written` | `RW` at ε only (a storage write, never deeper) |
//! | `stored` | `RA`; the returned sequence's `[*]` holds it, κ there by §2.9's construction rule with its own `excl` |
//! | `taken` (function parameter) | its supply is `elem(π₁·ρ)`, taken and owned |
//! | `taken` (result) | `elem(π₁·ρ)`, π₁ `A` at `[*]`, the split recorded with `excl π₁` |
//! | `builderdone` | parameter 1's node itself |
//! | `concatenated` | storage π₁ (`A` at ε) or fresh, `[*]` both inputs', κ lost for list-kind elements, `apart`∧`excl` for records |
//! | `cellread` + `lent` / `lentoptional` | π₁ `R`, its handle in `refs`; `loan(π₁◆·ρ)`, at the carrier's payload step for the second |
//! | `cellwrite`/`cellcomplete` | π₁ `R`, `W` at `◆`, in `refs` |
//! | `consumed cellstored` | `RS`: the value goes behind the barrier |
//! | `cellupdate`/`cellmodify` + `stored` | called once, its supply `π₁◆` taken and owned; the write-back of its answer (`cellmodify`: of its `.1`) at `π₁◆`; `cellmodify` returns its `.0` or a loan of the slot |
//! | `cellnew` / `cellempty` | a fresh handle, `◆ ↦ π₁` or empty |
//! | `elementof` | `π₁[*]` itself, π₁ `R` and `A` at `[*]`: no split, nothing taken |
//! | `copyof` | fresh storage, `[*]` `π₁[*]`, κ there lost for list-kind elements, `excl π₁[*]` for records, none where they cross |
//! | `prepended` | `stored` π₁ in front of `returned` π₂: storage π₂ or fresh, `[*]` `π₁` and `π₂[*]`, κ by the construction rule; no write |
//! | `once taken stored` (callback) | the answer (or a carrier's payload, `fn_payload`) stored at `written returned` π₁'s `[*]` by the construction rule, and its write-back there; a carrier's nullary answer removes |
//!
//! The slot relation's versions and the loan lifetimes are S8's (§2.13.7);
//! these rows carry what a class can say today.
//!
//! A crossing position (a `cross` place) carries no cell whatever its word.
//! `entry` is recorded on the class and read by S7's `Entry`.
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
    /// The written-out function type's result place, or null: where a
    /// `stored` callback's answer is read (§2.13.6).
    fn_result: ?PlaceId = null,
    /// A callback whose argument and answer are a Maybe-like carrier over
    /// the element (§2.13.6's `stored` row): the step to the carrier's
    /// unary payload, which the adapter resolved and validated (one
    /// nullary and one unary constructor). Null: the element itself.
    fn_payload: ?Step = null,
    /// The parameter's declared type is a bare type variable: the value can
    /// hold any structure and the callee may read any of it, so every word
    /// on it applies at every depth (§2.13.6, #1105).
    type_variable: bool = false,
};

pub const Signature = struct {
    params: []const Param,
    result: PlaceId,
    result_words: u32 = 0,
    entry: bool = false,
    /// `lentoptional` (§2.13.6): the step from the result's place to the
    /// unary payload of its Maybe-like carrier, which the adapter resolved
    /// and validated (one nullary and one unary constructor). Null: none.
    optional_payload: ?Step = null,
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

/// The class a worded signature gives (oc §24.2, R-5.10.2/3; ownership-v2.md
/// §2.13.6 for v2's words), origin `words`. A v2 word whose place does not
/// have the kind the word reads — a sequence's `[*]`, a cell's `◆` — is no
/// word: the position falls back to the pessimistic default (R-5.10.3).
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
    var refs: SetId = .none;
    var kappas: Cond.Kappas = .none;
    // Each fun's runs of `supplies` and `backs`, cut into slices once the
    // lists are complete.
    var fun_runs: std.ArrayList([4]u32) = .empty;
    defer fun_runs.deinit(gpa);
    var backs: std.ArrayList(Summary.Back) = .empty;
    defer backs.deinit(gpa);
    // The values stored into the result container's `[*]`: each `stored`
    // parameter's cell, and a `stored` callback's answer (§2.13.6).
    var stored: std.ArrayList(CellId) = .empty;
    defer stored.deinit(gpa);
    // The returned container a `stored` value is put into: its leaf is
    // built below, with the stored values at `[*]`, not in the loop.
    var into: ?u32 = null;
    var any_stored = false;
    for (sig.params, 0..) |prm, iu| {
        if (!has(prm.words, .stored) or prm.fn_params != null) continue;
        any_stored = true;
        if (!crosses(env, prm.place)) try stored.append(gpa, try paramCell(env, @intCast(iu), prm.place));
    }
    // The callback whose answer goes back at the element position of
    // parameter 1: one, or none (two would be an ambiguous destination).
    var elem_back: ?ElemBack = null;
    var elem_backs: u32 = 0;
    for (sig.params, 0..) |prm, iu| if (try elementBack(env, sig, @intCast(iu), prm)) |b| {
        elem_backs += 1;
        elem_back = b;
    };
    if (elem_backs > 1) elem_back = null;
    // A callback whose answer is put back where the places give it no
    // write-back — no destination of the kind, an answer that is not the
    // element or the cell's contents, two answers for one destination, a
    // cell word without `stored` — is not a row of fewer words: dropping the
    // write-back would say the answer is discarded, which allows more than
    // the code does. The signature is no row at all, `⊤call` (R-5.10.3).
    for (sig.params, 0..) |prm, iu| {
        if (prm.fn_params == null or prm.words & (Word.stored.bit() | cell_callback) == 0) continue;
        const fits = if (prm.words & cell_callback != 0)
            has(prm.words, .stored) and try cellBack(env, sig, prm, prm.words) != null
        else if (elem_back) |b| b.i == iu else false;
        if (!fits) return pessimistic(env, sums, sig);
    }
    if (elem_back) |b| {
        into = 0;
        if (!crosses(env, env.places.child(sig.params[0].place, Step.elem).?)) try stored.append(gpa, b.answer);
    } else if (any_stored) for (sig.params, 0..) |prm, iu| {
        if (has(prm.words, .returned) and isSequence(env, prm.place) and !crosses(env, sig.result)) into = @intCast(iu);
    };
    const entry_bit = Word.entry.bit();
    for (sig.params, 0..) |prm, iu| {
        const i: u32 = @intCast(iu);
        var words = prm.words & ~entry_bit;
        // A cell word when parameter 1 is not a cell, or `written` on a
        // place that is no storage, is not a word (R-5.10.3).
        if (words & cell_words != 0 and !(sig.params.len > 0 and isCell(env, sig.params[0].place))) words &= ~cell_words;
        if (has(words, .written) and !(isSequence(env, prm.place) or isCell(env, prm.place) or env.places.kind(prm.place) == .dict)) words &= ~Word.written.bit();
        // A callback's answer put back (§2.13.6): into parameter 1's `◆`
        // with `cellupdate`/`cellmodify`, at its element position with
        // `once taken stored`. A selector whose places do not fit is no
        // word (R-5.10.3): the callback loses it, and `stored` with it.
        var back: ?Summary.Back = null;
        if (prm.fn_params != null and has(words, .stored)) {
            if (words & cell_callback != 0) {
                back = try cellBack(env, sig, prm, words);
            } else if (elem_back) |b| {
                if (b.i == i) back = b.back;
            }
            if (back == null) words &= ~(Word.stored.bit() | cell_callback);
        } else words &= ~cell_callback;
        if (words == 0) words = Word.escaped.bit();
        var use: NodeId = .none;
        // A `List` of functions is a function slot only when its words say
        // how often the elements are called (`once`, `many`, `unused`), as
        // v1 reads it (oc §30.9); a `borrowed` list of functions is a plain
        // parameter. `cellupdate`/`cellmodify` say once.
        const once_words = Word.once.bit() | Word.cellupdate.bit() | Word.cellmodify.bit();
        const as_function = prm.fn_params != null and (!prm.list_of_fns or has(words, .once) or has(words, .many) or has(words, .unused));
        if (as_function) {
            const fps = prm.fn_params.?;
            // A function (or a list of them): how often it is called, what
            // it is handed, whether JavaScript keeps it.
            const kept = has(words, .escaped);
            const calls: Summary.Calls = if (has(words, .unused)) .zero else if (words & once_words != 0) .once else .many;
            var j = i;
            if (prm.list_of_fns) {
                j = n + @as(u32, @intCast(slots.items.len));
                const root = try env.places.rootPath(gpa, prm.place);
                const at = (try env.places.extend(gpa, env.charge, root, Step.elem)) orelse root;
                try slots.append(gpa, .{ .param = i, .path = at });
            }
            // `taken` (§2.13.6): the supply is a materialised element of the
            // first container argument; `cellupdate`/`cellmodify` the first
            // parameter's `◆` contents, taken and owned (§2.13.7).
            const first: ?Param = if (sig.params.len > 0) sig.params[0] else null;
            const takes_elem = has(words, .taken) and first != null and isContainer(env, first.?.place);
            const takes_contents = words & cell_callback != 0;
            const run_start: u32 = @intCast(supplies.items.len);
            if (calls != .zero) {
                for (fps, 0..) |fp, k| {
                    if (k == 0 and (takes_elem or takes_contents)) {
                        const c = if (takes_elem) try takenElem(env, first.?.place) else try contentsCell(env, first.?.place);
                        const leaf = try env.shapes.leaf(gpa, env.account(), fp, try env.cells.sets.insert(gpa, env.charge, .none, c.int(), 0));
                        // A carrier argument (`Maybe v`): the taken element
                        // at its payload, nothing in the nullary alternative.
                        const node = if (takes_elem and prm.fn_payload != null and back != null)
                            try env.shapes.node(gpa, env.account(), fp, .none, try env.shapes.overPut(gpa, env.account(), Ids.none_int, prm.fn_payload.?, try env.shapes.leaf(gpa, env.account(), env.places.child(fp, prm.fn_payload.?).?, env.shapes.cells(leaf))))
                        else
                            leaf;
                        // A built node's own κ at ε is its cells', as for `res` below.
                        const kappa: Cond.Kappas = if (node == leaf) .none else blk: {
                            const own = try env.shapes.leaf(gpa, env.account(), fp, try env.shapes.cellsOf(gpa, env.account(), &env.cells.sets, node));
                            break :blk (try env.conds.kappaSet(gpa, env.charge, .none, node, try env.conds.kappaOf(gpa, env.charge, env.view(), .none, own, false))).ctx;
                        };
                        try supplies.append(gpa, .{ .j = j, .k = 0, .node = node, .label = .none, .owned = true, .taken = true, .kappa = kappa });
                        continue;
                    }
                    const node = if (has(words, .owned)) try freshLeaf(env, .result, 0, fp) else try topLeaf(env, fp);
                    try supplies.append(gpa, .{ .j = j, .k = @intCast(k), .node = node, .label = .none, .owned = has(words, .owned), .taken = false, .kappa = .none });
                }
            }
            // Supplies and write-backs are appended to one list each; the
            // fun's slices are cut below, once the lists are complete. The
            // answer put back is the effect (§2.13.6), not a `need` on all
            // of it: `cellmodify` demands nothing of its `.0`.
            const back_start: u32 = @intCast(backs.items.len);
            if (back) |b| try backs.append(gpa, b);
            try funs.append(gpa, .{ .j = j, .calls = calls, .seen = !kept });
            try fun_runs.append(gpa, .{ run_start, @intCast(supplies.items.len - run_start), back_start, @intCast(backs.items.len - back_start) });
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
                // `cellmodify`: the answer's `.0` is returned, and where it
                // may overlap the slot it is a loan of it.
                if (has(words, .cellmodify)) {
                    returned = true;
                    const first_part = (try env.places.extend(gpa, env.charge, try env.places.rootPath(gpa, prm.fn_result.?), try Step.index(env.account(), 0))).?;
                    const part = try env.cells.symbolic(gpa, env.account(), env.places, .cb, Ids.none_int, first_part, j);
                    const part_leaf = try env.shapes.leaf(gpa, env.account(), env.places.pathPlace(first_part), try env.cells.sets.insert(gpa, env.charge, .none, part.int(), 0));
                    res = try addRes(env, res, if (env.places.pathPlace(first_part) == sig.result) part_leaf else try env.shapes.recast(gpa, env.account(), sig.result, part_leaf));
                    res = try addRes(env, res, try loanLeaf(env, first.?.place, sig.result));
                }
            }
            try params.append(gpa, use);
            continue;
        }
        var m: Summary.Marks = .{};
        if (!has(words, .unused)) m.r = true;
        if (has(words, .aliased) or has(words, .returned) or has(words, .stored)) m.a = true;
        // `concatenated`: the result may be parameter 1's storage, so it is kept.
        if (i == 0 and has(sig.result_words, .concatenated)) m.a = true;
        if (has(words, .escaped)) m.e = true;
        if (has(words, .consumed)) {
            m.w = true;
            m.deep = true;
            writes = true;
        }
        // `written` (R-4.10.9): a write of the storage at ε, never deeper.
        if (has(words, .written)) {
            m.w = true;
            writes = true;
        }
        // A bare type variable (§2.13.6, #1105): the marks hold below ε.
        if (prm.type_variable and !m.isEmpty()) m.deep = true;
        if (!m.isEmpty() and !crosses(env, prm.place)) use = try Summary.Table.markUse(env, .none, prm.place, &.{}, m, &.{});
        // A sequence result read off at `[*]` (`taken`, `concatenated`):
        // the elements are kept (`A` there).
        if (i == 0 and sig.result_words & (Word.taken.bit() | Word.concatenated.bit() | Word.elementof.bit() | Word.copyof.bit()) != 0 and isSequence(env, prm.place))
            use = try Summary.Table.markUse(env, use, prm.place, &.{Step.elem}, .{ .a = true }, &.{});
        if (i == 1 and has(sig.result_words, .concatenated) and isSequence(env, prm.place))
            use = try Summary.Table.markUse(env, use, prm.place, &.{Step.elem}, .{ .a = true }, &.{});
        // A cell operation (§2.13.7): the handle's stable slot is in
        // `refs`; a write is a writer demand on its `◆`.
        if (words & (Word.cellread.bit() | Word.cellwrite.bit() | Word.cellcomplete.bit()) != 0) {
            refs = try env.cells.sets.insert(gpa, env.charge, refs, (try paramCell(env, i, prm.place)).int(), 0);
            if (!has(words, .cellread)) {
                use = try Summary.Table.markUse(env, use, prm.place, &.{Step.contents}, .{ .w = true }, &.{});
                writes = true;
            }
        }
        try params.append(gpa, use);
        const p = try paramCell(env, i, prm.place);
        const p_leaf = try env.shapes.leaf(gpa, env.account(), prm.place, try env.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
        if (crosses(env, prm.place) or crosses(env, sig.result)) {
            // A crossing value has no paths to hold what it is handed, but it
            // may hold it: the parameter rides in the result as a recast, so
            // its reach is what flowed in (§2.13.6, #1102).
            if (has(words, .returned) or has(words, .aliased)) res = try addRes(env, res, try env.shapes.recast(gpa, env.account(), sig.result, p_leaf));
            continue;
        }
        if (has(words, .returned) and into != i) {
            returned = true;
            // The result IS the parameter: its leaf at the result's place
            // (a cast when the places differ structurally is the call's,
            // §2.13.9).
            res = try addRes(env, res, if (prm.place == sig.result) p_leaf else try env.shapes.recast(gpa, env.account(), sig.result, p_leaf));
        }
        if (has(words, .aliased)) res = try addRes(env, res, try env.shapes.recast(gpa, env.account(), sig.result, p_leaf));
    }
    // Cut the funs' supply and write-back slices now that the lists are
    // complete.
    for (funs.items, fun_runs.items) |*f, run| {
        f.supplies = supplies.items[run[0]..][0..run[1]];
        f.backs = backs.items[run[2]..][0..run[3]];
    }
    const rw = sig.result_words;
    // The returned container with the stored values at `[*]` (§2.9's
    // construction rule: κ there is the base's, `apart` the arrivals, each
    // stored value's own). `prepended`: parameter 1 put in front of a
    // `returned` parameter 2, whose storage the result may share, or fresh.
    if (into) |r| {
        returned = true;
        const prepends = has(rw, .prepended) and r == 1 and sig.params.len == 2 and has(sig.params[0].words, .stored);
        const built = try storedInto(env, sig, r, stored.items, prepends);
        res = try addRes(env, res, built.node);
        kappas = built.kappas;
    }
    const first_place: ?PlaceId = if (sig.params.len > 0) sig.params[0].place else null;
    if (crosses(env, sig.result)) {
        if (res == .none) res = try env.shapes.nothing(gpa, env.account(), sig.result);
    } else if (has(rw, .fresh)) {
        const f = try freshLeaf(env, .result, 1, sig.result);
        res = try addRes(env, res, if (has(rw, .exclusive)) f else try env.shapes.recast(gpa, env.account(), sig.result, f));
    } else if (has(rw, .escaped)) {
        res = try addRes(env, res, try env.shapes.recast(gpa, env.account(), sig.result, try freshLeaf(env, .esc, 1, sig.result)));
    } else if (has(rw, .taken) and first_place != null and isSequence(env, first_place.?)) {
        // A materialised element of parameter 1, in force for the frame.
        returned = true;
        const c = try takenElem(env, first_place.?);
        res = try addRes(env, res, try env.shapes.leaf(gpa, env.account(), sig.result, try env.cells.sets.insert(gpa, env.charge, .none, c.int(), 0)));
    } else if (has(rw, .elementof) and first_place != null and isSequence(env, first_place.?) and !crosses(env, first_place.?)) {
        // An element of parameter 1 read in place: `π₁[*]` itself, with no
        // split and nothing taken (§2.13.6).
        returned = true;
        const at = env.places.child(first_place.?, Step.elem).?;
        const leaf = try env.shapes.leaf(gpa, env.account(), at, try env.cells.sets.insert(gpa, env.charge, .none, (try paramCellAtIndex(env, 0, first_place.?)).int(), 0));
        res = try addRes(env, res, if (at == sig.result) leaf else try env.shapes.recast(gpa, env.account(), sig.result, leaf));
    } else if (has(rw, .copyof) and first_place != null and isSequence(env, first_place.?) and !crosses(env, first_place.?) and isSequence(env, sig.result)) {
        returned = true;
        const built = try copyOf(env, sig);
        res = try addRes(env, res, built.node);
        kappas = built.kappas;
    } else if (has(rw, .lent) and first_place != null and isCell(env, first_place.?)) {
        returned = true;
        res = try addRes(env, res, try loanLeaf(env, first_place.?, sig.result));
    } else if (has(rw, .lentoptional) and first_place != null and isCell(env, first_place.?) and sig.optional_payload != null and env.places.child(sig.result, sig.optional_payload.?) != null) {
        // The empty alternative, or a loan at the unary payload's path.
        returned = true;
        const payload = env.places.child(sig.result, sig.optional_payload.?).?;
        const over = try env.shapes.overPut(gpa, env.account(), Ids.none_int, sig.optional_payload.?, try loanLeaf(env, first_place.?, payload));
        res = try addRes(env, res, try env.shapes.node(gpa, env.account(), sig.result, .none, over));
    } else if ((has(rw, .cellnew) or has(rw, .cellempty)) and isCell(env, sig.result)) {
        // A fresh handle; `◆` initially parameter 1, or empty.
        returned = true;
        const handle = try env.cells.sets.insert(gpa, env.charge, .none, (try env.cells.result(gpa, env.account(), .result, .none, 1, sig.result, .ref)).int(), 0);
        var over: u32 = Ids.none_int;
        if (has(rw, .cellnew) and first_place != null and !crosses(env, first_place.?)) {
            const contents = env.places.child(sig.result, Step.contents).?;
            const p = try paramCell(env, 0, first_place.?);
            const leaf = try env.shapes.leaf(gpa, env.account(), contents, try env.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
            over = try env.shapes.overPut(gpa, env.account(), Ids.none_int, Step.contents, leaf);
        }
        res = try addRes(env, res, try env.shapes.node(gpa, env.account(), sig.result, handle, over));
    } else if (has(rw, .concatenated) and sig.params.len >= 2 and isSequence(env, sig.params[0].place) and isSequence(env, sig.params[1].place) and isSequence(env, sig.result)) {
        returned = true;
        const built = try concatenation(env, sig);
        res = try addRes(env, res, built.node);
        kappas = built.kappas;
    } else if (has(rw, .builderdone) and first_place != null and isSequence(env, first_place.?) and !crosses(env, first_place.?)) {
        // Parameter 1's storage, its cells, children and κ unchanged: the
        // result is its node, as `returned` makes it (§2.13.6).
        if (!returned) {
            returned = true;
            const p = try paramCell(env, 0, first_place.?);
            const p_leaf = try env.shapes.leaf(gpa, env.account(), first_place.?, try env.cells.sets.insert(gpa, env.charge, .none, p.int(), 0));
            res = try addRes(env, res, if (first_place.? == sig.result) p_leaf else try env.shapes.recast(gpa, env.account(), sig.result, p_leaf));
        }
    } else if (has(rw, .unknown) or !returned) {
        res = try addRes(env, res, try topLeaf(env, sig.result));
    }
    // A built node's own κ at ε is its cells', as a leaf of them reads:
    // its children's conditions are the map's, set where they were built.
    if (res != .none and env.shapes.kind(res) == .node and env.conds.kappaGet(kappas, res) == null) {
        const own = try env.shapes.leaf(gpa, env.account(), env.shapes.place(res), try env.shapes.cellsOf(gpa, env.account(), &env.cells.sets, res));
        kappas = (try env.conds.kappaSet(gpa, env.charge, kappas, res, try env.conds.kappaOf(gpa, env.charge, env.view(), .none, own, false))).ctx;
    }
    return sums.add(env, .{
        .params = params.items,
        .res = res,
        .kappas = kappas,
        .funs = funs.items,
        .slots = slots.items,
        .refs = refs,
        .writes = writes,
        .entry = sig.entry,
        .origin = .words,
    });
}

/// The cell words, which read a `◆`.
const cell_words = Word.cellread.bit() | Word.cellwrite.bit() | Word.cellcomplete.bit() | Word.cellstored.bit() |
    Word.cellupdate.bit() | Word.cellmodify.bit();

/// A sequence's place (`sequence` metadata, through the place adapter): a
/// list with its `[*]`.
fn isSequence(env: Env, at: PlaceId) bool {
    return env.places.kind(at) == .list and env.places.child(at, Step.elem) != null;
}

/// A cell's place (`cell` metadata): a `ref` with its barrier `◆`.
fn isCell(env: Env, at: PlaceId) bool {
    return env.places.kind(at) == .ref and env.places.child(at, Step.contents) != null;
}

/// `⊤call` over the signature's places (§2.11, R-5.10.3): every parameter
/// `RAEW` deep, every function parameter called many times, unseen, its
/// answer put back anywhere; the result `⊤`.
fn pessimistic(env: Env, sums: *Summary.Table, sig: Signature) Error!ClassId {
    var places: std.ArrayList(PlaceId) = .empty;
    defer places.deinit(env.gpa);
    var funs: std.ArrayList(u32) = .empty;
    defer funs.deinit(env.gpa);
    for (sig.params, 0..) |prm, i| {
        try places.append(env.gpa, prm.place);
        if (prm.fn_params != null and !prm.list_of_fns) try funs.append(env.gpa, @intCast(i));
    }
    return sums.unknown(env, places.items, funs.items, sig.result);
}

/// The callback words that put the answer back into a cell's `◆`.
const cell_callback = Word.cellupdate.bit() | Word.cellmodify.bit();

/// A container of elements (`sequence` metadata, or a dict's value
/// position): a list or dict place with its `[*]`.
fn isContainer(env: Env, at: PlaceId) bool {
    const k = env.places.kind(at);
    return (k == .list or k == .dict) and env.places.child(at, Step.elem) != null;
}

/// A `stored` callback whose answer goes back at parameter 1's element
/// position, the answer's selected cell `cb_j·selected`, and the effect.
/// The row compares the answer with the whole `π₁[*]` (`storedInto`):
/// §2.13.6 compares it with the remainder, the taken position removed,
/// which a row cannot spell; `Calls` removes it under the call's split when
/// it applies the write-back (#1081). The row is only less precise.
const ElemBack = struct { i: u32, answer: CellId, back: Summary.Back };

/// Parameter `i`'s element write-back (§2.13.6's callback `stored`), when
/// its words and places make one: `once taken stored`, no cell word; a
/// `written returned` container as parameter 1; the callback's argument
/// and answer the element, or both a carrier over it whose payload the
/// answer stores (`fn_payload`), its nullary alternative a removal.
fn elementBack(env: Env, sig: Signature, i: u32, prm: Param) Error!?ElemBack {
    const want = Word.stored.bit() | Word.once.bit() | Word.taken.bit();
    if (prm.fn_params == null or prm.list_of_fns or prm.words & want != want or prm.words & cell_callback != 0) return null;
    if (i == 0 or prm.fn_params.?.len == 0) return null;
    const into = sig.params[0];
    const dest_words = Word.written.bit() | Word.returned.bit();
    if (into.words & dest_words != dest_words or !isContainer(env, into.place)) return null;
    const elem = env.places.child(into.place, Step.elem).?;
    const answer = prm.fn_result orelse return null;
    const arg = prm.fn_params.?[0];
    var selected = try env.places.rootPath(env.gpa, answer);
    if (prm.fn_payload) |s| {
        if (env.places.child(answer, s) != elem or env.places.child(arg, s) != elem) return null;
        selected = (try env.places.extend(env.gpa, env.charge, selected, s)).?;
    } else if (answer != elem or arg != elem) return null;
    const j = i;
    const dest = (try env.places.extend(env.gpa, env.charge, try env.places.rootPath(env.gpa, into.place), Step.elem)).?;
    return .{
        .i = i,
        .answer = try env.cells.symbolic(env.gpa, env.account(), env.places, .cb, Ids.none_int, selected, j),
        .back = .{ .selected = selected, .dest = dest, .dest_param = 0, .mode = .element, .removes = prm.fn_payload != null },
    };
}

/// A cell callback's write-back (§2.13.6): `cellupdate stored` puts its
/// whole answer, `cellmodify stored` the answer's `.1`, into parameter 1's
/// `◆`; null when the places do not fit (the answer, or its `.1`, is not
/// the contents' place).
fn cellBack(env: Env, sig: Signature, prm: Param, words: u32) Error!?Summary.Back {
    if (prm.list_of_fns or sig.params.len == 0 or !isCell(env, sig.params[0].place)) return null;
    if (@popCount(words & cell_callback) != 1) return null;
    const contents = env.places.child(sig.params[0].place, Step.contents).?;
    const answer = prm.fn_result orelse return null;
    var selected = try env.places.rootPath(env.gpa, answer);
    if (has(words, .cellmodify)) {
        const second = try Step.index(env.account(), 1);
        if (env.places.child(answer, second) != contents) return null;
        if (env.places.child(answer, try Step.index(env.account(), 0)) == null) return null;
        selected = (try env.places.extend(env.gpa, env.charge, selected, second)).?;
    } else if (answer != contents) return null;
    const dest = (try env.places.extend(env.gpa, env.charge, try env.places.rootPath(env.gpa, sig.params[0].place), Step.contents)).?;
    return .{ .selected = selected, .dest = dest, .dest_param = 0, .mode = .cell };
}

/// `param πᵢ` at its root.
fn paramCell(env: Env, i: u32, at: PlaceId) Error!CellId {
    return env.cells.symbolic(env.gpa, env.account(), env.places, .param, i, try env.places.rootPath(env.gpa, at), 0);
}

/// `param π₁·step`.
fn paramCellAt(env: Env, at: PlaceId, step: Step) Error!CellId {
    const root = try env.places.rootPath(env.gpa, at);
    const path = (try env.places.extend(env.gpa, env.charge, root, step)) orelse root;
    return env.cells.symbolic(env.gpa, env.account(), env.places, .param, 0, path, 0);
}

/// `elem(π₁·ρ)`: the element the call materialises from parameter 1's
/// container cell, ρ the call itself (label `none`), its split recorded
/// with the container's κ at `[*]` (§2.2) — `excl π₁`.
fn takenElem(env: Env, list: PlaceId) Error!CellId {
    const container = try paramCell(env, 0, list);
    const at = env.places.child(list, Step.elem).?;
    _ = try env.cells.split(env.gpa, env.account(), container, Ids.none_int, .none, try env.conds.excl(env.gpa, env.charge, container));
    return env.cells.refine(env.gpa, env.account(), .elem, container, .none, 0, at, Cell.Kind.ofPlace(env.places.kind(at)));
}

/// Parameter 1's `◆` contents, `param π₁·◆`.
fn contentsCell(env: Env, cell: PlaceId) Error!CellId {
    return paramCellAt(env, cell, Step.contents);
}

/// A loan of parameter 1's `◆` (§2.13.7) at `at`: `loan(π₁·◆·ρ)`.
fn loanLeaf(env: Env, cell: PlaceId, at: PlaceId) Error!NodeId {
    const contents = try contentsCell(env, cell);
    const loan = try env.cells.refine(env.gpa, env.account(), .loan, contents, .none, 0, at, Cell.Kind.ofPlace(env.places.kind(at)));
    return env.shapes.leaf(env.gpa, env.account(), at, try env.cells.sets.insert(env.gpa, env.charge, .none, loan.int(), 0));
}

const Built = struct { node: NodeId, kappas: Cond.Kappas };

/// Parameter `r`'s container with the `stored` values at `[*]`: κ at
/// `[*]` by §2.9's construction rule, one store after another. `fresh`
/// (`prepended`): the storage is parameter `r`'s or a fresh one.
fn storedInto(env: Env, sig: Signature, r: u32, stored: []const CellId, fresh: bool) Error!Built {
    const gpa = env.gpa;
    const list = sig.params[r].place;
    const at = env.places.child(list, Step.elem).?;
    const base = try paramCell(env, r, list);
    const base_elem = try paramCellAtIndex(env, r, list);
    var cells = try env.cells.sets.insert(gpa, env.charge, .none, base_elem.int(), 0);
    var k = try env.conds.kappaOf(gpa, env.charge, env.view(), .none, try env.shapes.leaf(gpa, env.account(), at, cells), true);
    var excls = Cond.yes;
    for (stored) |v| {
        const v_leaf = try env.shapes.leaf(gpa, env.account(), at, try env.cells.sets.insert(gpa, env.charge, .none, v.int(), 0));
        k = try env.conds.lower(gpa, env.charge, env.view(), .none, k, cells, v_leaf, true, null);
        // The stored value's own condition as a position (C.10 item 5):
        // what the caller's argument is at that path, its `excl`, added
        // once the stores are done so the arrivals' group stays on top of
        // κ for the next store to grow (`Cond.lower`).
        excls = try env.conds.@"and"(gpa, env.charge, excls, try env.conds.excl(gpa, env.charge, v));
        cells = try env.cells.sets.insert(gpa, env.charge, cells, v.int(), 0);
    }
    k = try env.conds.@"and"(gpa, env.charge, k, excls);
    const elems = try env.shapes.leaf(gpa, env.account(), at, cells);
    var storage = try env.cells.sets.insert(gpa, env.charge, .none, base.int(), 0);
    if (fresh) storage = try env.cells.sets.insert(gpa, env.charge, storage, (try env.cells.result(gpa, env.account(), .result, .none, 1, list, .list)).int(), 0);
    const node = try env.shapes.node(gpa, env.account(), list, storage, try env.shapes.overPut(gpa, env.account(), Ids.none_int, Step.elem, elems));
    const res = if (list == sig.result) node else try env.shapes.recast(gpa, env.account(), sig.result, node);
    return .{ .node = res, .kappas = try env.conds.kappaSetAt(gpa, env.charge, .none, &.{Step.elem}, elems, k) };
}

/// `param πᵢ[*]`.
fn paramCellAtIndex(env: Env, i: u32, list: PlaceId) Error!CellId {
    const root = try env.places.rootPath(env.gpa, list);
    const path = (try env.places.extend(env.gpa, env.charge, root, Step.elem)).?;
    return env.cells.symbolic(env.gpa, env.account(), env.places, .param, i, path, 0);
}

/// `concatenated` (§2.13.6): storage parameter 1's or fresh, contents the
/// union of both `[*]`s. κ at `[*]` is lost where the elements are of a
/// list's kind; for records it holds when both inputs are exclusive and
/// apart (one condition, kind-filtered, R-4.10.7/8).
fn concatenation(env: Env, sig: Signature) Error!Built {
    const gpa = env.gpa;
    const at = env.places.child(sig.result, Step.elem).?;
    const a = try paramCellAtIndex(env, 0, sig.params[0].place);
    const b = try paramCellAtIndex(env, 1, sig.params[1].place);
    const cells = try env.cells.sets.insert(gpa, env.charge, try env.cells.sets.insert(gpa, env.charge, .none, a.int(), 0), b.int(), 0);
    const elems = try env.shapes.leaf(gpa, env.account(), at, cells);
    const storage = try env.cells.sets.insert(gpa, env.charge, try env.cells.sets.insert(gpa, env.charge, .none, (try paramCell(env, 0, sig.params[0].place)).int(), 0), (try env.cells.result(gpa, env.account(), .result, .none, 1, sig.result, .list)).int(), 0);
    const node = try env.shapes.node(gpa, env.account(), sig.result, storage, try env.shapes.overPut(gpa, env.account(), Ids.none_int, Step.elem, elems));
    const k = if (env.places.kind(at) == .record) blk: {
        var items = [_]Cond.Item{ .{ .cell = a, .approx = false }, .{ .cell = b, .approx = false } };
        const together = try env.conds.apart(gpa, env.charge, env.cells, env.places, &items, null);
        break :blk try env.conds.@"and"(gpa, env.charge, together, try env.conds.@"and"(gpa, env.charge, try env.conds.excl(gpa, env.charge, a), try env.conds.excl(gpa, env.charge, b)));
    } else if (env.places.holds(at).isEmpty()) Cond.yes else Cond.lost;
    return .{ .node = node, .kappas = try env.conds.kappaSetAt(gpa, env.charge, .none, &.{Step.elem}, elems, k) };
}

/// `copyof` (§2.13.6): fresh storage holding parameter 1's elements, `[*]`
/// `π₁[*]`. κ at `[*]` is lost where the elements are of a list's kind (or
/// any other kind that holds cells), `excl π₁[*]` for records (copying the
/// storage does not make two of them one), `yes` where they cross.
fn copyOf(env: Env, sig: Signature) Error!Built {
    const gpa = env.gpa;
    const at = env.places.child(sig.result, Step.elem).?;
    const storage = try env.cells.sets.insert(gpa, env.charge, .none, (try env.cells.result(gpa, env.account(), .result, .none, 1, sig.result, .list)).int(), 0);
    // Crossing elements carry no cell: the copy is its fresh storage.
    if (crosses(env, at)) return .{ .node = try env.shapes.node(gpa, env.account(), sig.result, storage, Ids.none_int), .kappas = .none };
    const a = try paramCellAtIndex(env, 0, sig.params[0].place);
    const elems = try env.shapes.leaf(gpa, env.account(), at, try env.cells.sets.insert(gpa, env.charge, .none, a.int(), 0));
    const node = try env.shapes.node(gpa, env.account(), sig.result, storage, try env.shapes.overPut(gpa, env.account(), Ids.none_int, Step.elem, elems));
    const k = if (env.places.kind(at) == .record)
        try env.conds.excl(gpa, env.charge, a)
    else if (env.places.holds(at).isEmpty()) Cond.yes else Cond.lost;
    return .{ .node = node, .kappas = try env.conds.kappaSetAt(gpa, env.charge, .none, &.{Step.elem}, elems, k) };
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
        kappas = (try env.conds.kappaSet(gpa, env.charge, .none, res, k)).ctx;
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
            // 7 `Ref (List Int)`: a cell, one `◆`.
            7 => {
                try out.append(g.gpa, .{ .step = Step.contents, .@"var" = 0 });
                return .{ .kind = .ref, .head = 700 };
            },
            // 8 `Maybe (List Int)`: `Nothing | Just (List Int)`.
            8 => {
                try out.append(g.gpa, .{ .step = (g.table.ctorStep(g.gpa, g.account, 1, 0) catch unreachable), .@"var" = 0 });
                return .{ .kind = .ctor, .head = 800 };
            },
            // 9 `List { a, b }`: a sequence of records.
            9 => {
                try out.append(g.gpa, .{ .step = Step.elem, .@"var" = 5 });
                return .{ .kind = .list, .head = 200 };
            },
            // 10 `Vec (List Int)`, a renamed sequence: the same kind and
            // children as 2 under another head.
            10 => {
                try out.append(g.gpa, .{ .step = Step.elem, .@"var" = 0 });
                return .{ .kind = .list, .head = 999 };
            },
            // 11 `Box (List Int)`, a renamed cell.
            11 => {
                try out.append(g.gpa, .{ .step = Step.contents, .@"var" = 0 });
                return .{ .kind = .ref, .head = 998 };
            },
            // 12 `List Int → List Int`, a function written out.
            12 => return .{ .kind = .closure, .head = 301 },
            // 13 `List Int × List Int`, what `cellmodify`'s callback answers.
            13 => {
                try out.append(g.gpa, .{ .step = (Step.index(g.account, 0) catch unreachable), .@"var" = 0 });
                try out.append(g.gpa, .{ .step = (Step.index(g.account, 1) catch unreachable), .@"var" = 0 });
                return .{ .kind = .tuple };
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
            return (try ff.conds.kappaSet(testing.allocator, ff.env().charge, .none, n, k)).ctx;
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
        const joined = try Summary.Table.joinRes(env, else_node, else_k, then_node, try withK(&f, then_node, then_k), .choice);
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

test "v2's words: sequence writes and stores, a taken element, a builder's done, a concatenation" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const list = try f.placeOf(0);
    const int = try f.placeOf(1);
    const lists = try f.placeOf(2);
    const recs = try f.placeOf(9);
    const fun = try f.placeOf(12);
    // push : written returned List (List Int), stored List Int → List (List Int)
    const push = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, .{ .place = list, .words = bits(&.{.stored}) } }, .result = lists });
    try testing.expectEqualStrings("summary push: π1 RAW, π2 RA; res [*] π1[*] π2{apart [π1[*]] [π2], excl π1[*], excl π2}, π1 (words)", try f.text(push, "push"));
    const at = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{.borrowed}) }, .{ .place = int, .words = bits(&.{.borrowed}) } }, .result = list, .result_words = bits(&.{.taken}) });
    try testing.expectEqualStrings("summary traverseAt: π1 R, π1[*] A; res elem(π1·λ) (words)", try f.text(at, "traverseAt"));
    const focus = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, .{ .place = int, .words = bits(&.{.borrowed}) }, .{ .place = fun, .words = bits(&.{ .once, .taken }), .fn_params = &.{list} } }, .result = lists });
    try testing.expectEqualStrings("summary focus: π1 RAW, π3 R; res π1; π3 calls ≤1, supply 1 elem(π1·λ) owned taken (words)", try f.text(focus, "focus"));
    const done = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, .{ .place = int, .words = bits(&.{.borrowed}) } }, .result = lists, .result_words = bits(&.{.builderdone}) });
    try testing.expectEqualStrings("summary done: π1 RAW; res π1 (words)", try f.text(done, "done"));
    const app = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{.written}) }, .{ .place = lists, .words = bits(&.{.borrowed}) } }, .result = lists, .result_words = bits(&.{.concatenated}) });
    try testing.expectEqualStrings("summary append: π1 RAW, π1[*] A, π2 R, π2[*] A; res [*] π1[*] π2[*]{lost}, fresh1 π1 (words)", try f.text(app, "append"));
    const appr = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = recs, .words = bits(&.{.written}) }, .{ .place = recs, .words = bits(&.{.borrowed}) } }, .result = recs, .result_words = bits(&.{.concatenated}) });
    try testing.expectEqualStrings("summary append: π1 RAW, π1[*] A, π2 R, π2[*] A; res [*] π1[*] π2[*]{apart [π1[*]] [π2[*]], excl π1[*], excl π2[*]}, fresh1 π1 (words)", try f.text(appr, "append"));
}

test "v2's words: a cell's make, read, write, update, modify and completion; an optional loan" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const list = try f.placeOf(0);
    const int = try f.placeOf(1);
    const ref = try f.placeOf(7);
    const maybe = try f.placeOf(8);
    const fun = try f.placeOf(12);
    const make = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = list, .words = bits(&.{.consumed}) }}, .result = ref, .result_words = bits(&.{.cellnew}) });
    try testing.expectEqualStrings("summary make: π1 RS; res fresh1, ◆ π1 (words)", try f.text(make, "make"));
    const empty = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = int, .words = bits(&.{.unused}) }}, .result = ref, .result_words = bits(&.{.cellempty}) });
    try testing.expectEqualStrings("summary empty: res fresh1 (words)", try f.text(empty, "empty"));
    const get = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = ref, .words = bits(&.{.cellread}) }}, .result = list, .result_words = bits(&.{.lent}) });
    try testing.expectEqualStrings("summary get: π1 R; res loan(π1◆·λ) (words)", try f.text(get, "get"));
    const poll = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = ref, .words = bits(&.{.cellread}) }}, .result = maybe, .result_words = bits(&.{.lentoptional}), .optional_payload = try f.places.ctorStep(testing.allocator, &f.account, 1, 0) });
    try testing.expectEqualStrings("summary poll: π1 R; res #C.0 loan(π1◆·λ) (words)", try f.text(poll, "poll"));
    const done = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = ref, .words = bits(&.{.cellread}) }}, .result = int });
    try testing.expectEqualStrings("summary isDone: π1 R (words)", try f.text(done, "isDone"));
    const set = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellwrite}) }, .{ .place = list, .words = bits(&.{ .consumed, .cellstored }) } }, .result = int });
    try testing.expectEqualStrings("summary set: π1 R, π1◆ W, π2 RS (words)", try f.text(set, "set"));
    // `cellupdate stored` puts the whole answer back into `◆`;
    // `cellmodify stored` its `.1`, and returns its `.0` or a loan of the
    // slot (§2.13.6). The write-back is the effect, not a `need`.
    const pair = try f.placeOf(13);
    const update = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellwrite}) }, .{ .place = fun, .words = bits(&.{ .cellupdate, .stored }), .fn_params = &.{list}, .fn_result = list } }, .result = int });
    try testing.expectEqualStrings("summary update: π1 R, π1◆ W, π2 R; π2 calls ≤1, supply 1 π1◆ owned taken, stores answer at π1◆ (words)", try f.text(update, "update"));
    const modify = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellwrite}) }, .{ .place = fun, .words = bits(&.{ .cellmodify, .stored }), .fn_params = &.{list}, .fn_result = pair } }, .result = list });
    try testing.expectEqualStrings("summary modify: π1 R, π1◆ W, π2 R; res cb2.0 loan(π1◆·λ); π2 calls ≤1, supply 1 π1◆ owned taken, stores answer.1 at π1◆ (words)", try f.text(modify, "modify"));
    const complete = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellcomplete}) }, .{ .place = list, .words = bits(&.{ .consumed, .cellstored }) } }, .result = int });
    try testing.expectEqualStrings("summary complete: π1 R, π1◆ W, π2 RS (words)", try f.text(complete, "complete"));
    const wrong = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = list, .words = bits(&.{.cellread}) }}, .result = list, .result_words = bits(&.{.lent}) });
    try testing.expectEqualStrings("summary wrong: π1 RE; res ⊤{lost} (words)", try f.text(wrong, "wrong"));
}

test "v2's words read the place's kind, never its name: a renamed sequence and cell give the same rows" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const list = try f.placeOf(0);
    const int = try f.placeOf(1);
    const Pair = struct { a: u32, b: u32 };
    // `List (List Int)` against `Vec (List Int)`, `Ref` against `Box`.
    for ([_]Pair{ .{ .a = 2, .b = 10 }, .{ .a = 7, .b = 11 } }) |pair| {
        var texts: [2][]const u8 = undefined;
        for ([_]u32{ pair.a, pair.b }, 0..) |v, k| {
            const at = try f.placeOf(v);
            const sig: Signature = if (f.places.kind(at) == .list)
                .{ .params = &.{ .{ .place = at, .words = bits(&.{ .written, .returned }) }, .{ .place = list, .words = bits(&.{.stored}) } }, .result = at }
            else
                .{ .params = &.{ .{ .place = at, .words = bits(&.{.cellwrite}) }, .{ .place = list, .words = bits(&.{ .consumed, .cellstored }) } }, .result = int };
            texts[k] = try f.text(try fromWords(env, &f.sums, sig), "row");
        }
        try testing.expectEqualStrings(texts[0], texts[1]);
    }
    // The flags a row's consumers read: a storage or slot write is a
    // write; a cell operation names the handle in `refs`; a read does not
    // write.
    const lists = try f.placeOf(2);
    const ref = try f.placeOf(7);
    const push = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, .{ .place = list, .words = bits(&.{.stored}) } }, .result = lists });
    try testing.expect(f.sums.get(push).writes and f.sums.get(push).refs == .none);
    const get = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = ref, .words = bits(&.{.cellread}) }}, .result = list, .result_words = bits(&.{.lent}) });
    try testing.expect(!f.sums.get(get).writes and f.cells.sets.count(f.sums.get(get).refs) == 1);
    const set = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellwrite}) }, .{ .place = list, .words = bits(&.{ .consumed, .cellstored }) } }, .result = int });
    try testing.expect(f.sums.get(set).writes and f.sums.get(set).refs == f.sums.get(get).refs);
}

test "v2's words: stores into one sequence keep one arrivals group, and n stores make one group" {
    // Two stored parameters: one `apart` group over the base's elements and
    // both values, not a group per store.
    {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const env = f.env();
        const lists = try f.placeOf(2);
        const list = try f.placeOf(0);
        const two = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, .{ .place = list, .words = bits(&.{.stored}) }, .{ .place = list, .words = bits(&.{.stored}) } }, .result = lists });
        try testing.expectEqualStrings("summary put2: π1 RAW, π2 RA, π3 RA; res [*] π1[*] π2 π3{apart [π1[*]] [π2] [π3], excl π1[*], excl π2, excl π3}, π1 (words)", try f.text(two, "put2"));
    }
    // n stored parameters: still one group (the quadratic form had n). The
    // row's total cost is `Cond.lower`'s, quadratic in arrivals of distinct
    // bases (#1054), so it is not asserted here.
    for ([_]u32{ 8, 64 }) |n| {
        var f: Fixture = .{};
        try f.init();
        defer f.deinit();
        const lists = try f.placeOf(2);
        const list = try f.placeOf(0);
        const params = try testing.allocator.alloc(Param, n + 1);
        defer testing.allocator.free(params);
        params[0] = .{ .place = lists, .words = bits(&.{ .written, .returned }) };
        for (params[1..]) |*p| p.* = .{ .place = list, .words = bits(&.{.stored}) };
        const c = try fromWords(f.env(), &f.sums, .{ .params = params, .result = lists });
        var it = f.shapes.overEntries(f.shapes.get(f.sums.get(c).res).a);
        const elems = it.next().?.node;
        const k = try f.conds.kappaOf(testing.allocator, f.env().charge, f.env().view(), f.sums.get(c).kappas, elems, true);
        var groups: u32 = 0;
        var members: u32 = 0;
        var at = f.conds.atoms.iterate(try f.conds.flat(testing.allocator, f.env().charge, k));
        while (at.next()) |e| {
            const a = f.conds.get(.from(e.key));
            if (a.atom != .apart) continue;
            groups += 1;
            members = f.cells.sets.count(.from(a.a));
        }
        try testing.expectEqual(@as(u32, 1), groups);
        try testing.expectEqual(n + 1, members);
    }
}

test "v2's result selectors: an element read in place, a fresh copy, a prepend" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const list = try f.placeOf(0);
    const int = try f.placeOf(1);
    const lists = try f.placeOf(2);
    const recs = try f.placeOf(9);
    const rec = try f.placeOf(5);
    const fun = try f.placeOf(3);
    // at, unsafeGet : borrowed List a, borrowed Int → elementof a
    const at = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{.borrowed}) }, .{ .place = int, .words = bits(&.{.borrowed}) } }, .result = list, .result_words = bits(&.{.elementof}) });
    try testing.expectEqualStrings("summary at: π1 R, π1[*] A; res π1[*] (words)", try f.text(at, "at"));
    // copy : borrowed List a → copyof List a, over lists and over records
    const copy = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = lists, .words = bits(&.{.borrowed}) }}, .result = lists, .result_words = bits(&.{.copyof}) });
    try testing.expectEqualStrings("summary copy: π1 R, π1[*] A; res [*] π1[*]{lost}, fresh1 (words)", try f.text(copy, "copy"));
    const copyr = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = recs, .words = bits(&.{.borrowed}) }}, .result = recs, .result_words = bits(&.{.copyof}) });
    try testing.expectEqualStrings("summary copy: π1 R, π1[*] A; res [*] π1[*]{excl π1[*]}, fresh1 (words)", try f.text(copyr, "copy"));
    const copyi = try fromWords(env, &f.sums, .{ .params = &.{.{ .place = list, .words = bits(&.{.borrowed}) }}, .result = list, .result_words = bits(&.{.copyof}) });
    try testing.expectEqualStrings("summary copy: π1 R, π1[*] A; res fresh1 (words)", try f.text(copyi, "copy"));
    // sortWith : borrowed List a, many (a, a → Order) → copyof List a
    const sort = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = recs, .words = bits(&.{.borrowed}) }, .{ .place = fun, .words = bits(&.{.many}), .fn_params = &.{ rec, rec } } }, .result = recs, .result_words = bits(&.{.copyof}) });
    try testing.expectEqualStrings("summary sortWith: π1 R, π1[*] A, π2 R; res [*] π1[*]{excl π1[*]}, fresh1; π2 calls many, supply 1 ⊤ borrowed{lost}, supply 2 ⊤ borrowed{lost} (words)", try f.text(sort, "sortWith"));
    // cons : stored a, returned List a → prepended List a
    const cons = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = list, .words = bits(&.{.stored}) }, .{ .place = lists, .words = bits(&.{.returned}) } }, .result = lists, .result_words = bits(&.{.prepended}) });
    try testing.expectEqualStrings("summary cons: π1 RA, π2 RA; res [*] π1 π2[*]{apart [π1] [π2[*]], excl π1, excl π2[*]}, fresh1 π2 (words)", try f.text(cons, "cons"));
    try testing.expect(!f.sums.get(cons).writes);
}

test "v2's stored callback: the answer put back at the element position, a carrier's payload, and its removal" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const list = try f.placeOf(0);
    const int = try f.placeOf(1);
    const lists = try f.placeOf(2);
    const maybe = try f.placeOf(8);
    const fun = try f.placeOf(12);
    // focus : written returned List a, borrowed Int, once taken stored (a → a) → List a
    const focus = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, .{ .place = int, .words = bits(&.{.borrowed}) }, .{ .place = fun, .words = bits(&.{ .once, .taken, .stored }), .fn_params = &.{list}, .fn_result = list } }, .result = lists });
    try testing.expectEqualStrings("summary focus: π1 RAW, π3 R; res [*] cb3 π1[*]{apart [cb3] [π1[*]], excl cb3, excl π1[*]}, π1; π3 calls ≤1, supply 1 elem(π1·λ) owned taken, stores answer at π1[*] (words)", try f.text(focus, "focus"));
    // The carrier form, `Maybe a → Maybe a`: `Just`'s payload is stored,
    // `Nothing` removes the taken position.
    const payload = try f.places.ctorStep(testing.allocator, &f.account, 1, 0);
    const mfocus = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, .{ .place = int, .words = bits(&.{.borrowed}) }, .{ .place = fun, .words = bits(&.{ .once, .taken, .stored }), .fn_params = &.{maybe}, .fn_result = maybe, .fn_payload = payload } }, .result = lists });
    try testing.expectEqualStrings("summary focusMaybe: π1 RAW, π3 R; res [*] cb3#C.0 π1[*]{apart [cb3#C.0] [π1[*]], excl cb3#C.0, excl π1[*]}, π1; π3 calls ≤1, supply 1  owned taken, stores answer#C.0 at π1[*] or removes (words)", try f.text(mfocus, "focusMaybe"));
    // No destination, an answer that is not the element, or two answers for
    // one destination: no row of fewer words (which would say the answer is
    // discarded) but `⊤call`, the pessimistic class (R-5.10.3).
    const nodest = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{.borrowed}) }, .{ .place = int, .words = bits(&.{.borrowed}) }, .{ .place = fun, .words = bits(&.{ .once, .taken, .stored }), .fn_params = &.{list}, .fn_result = list } }, .result = lists });
    try testing.expectEqualStrings("summary nodest: π1 RAES, π2 RAES, π3 RAES; res ⊤{lost}; π3 calls many, need owned, unseen", try f.text(nodest, "nodest"));
    try testing.expectEqual(Summary.Origin.unknown, f.sums.get(nodest).origin);
    const wrong = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, .{ .place = int, .words = bits(&.{.borrowed}) }, .{ .place = fun, .words = bits(&.{ .once, .taken, .stored }), .fn_params = &.{list}, .fn_result = int } }, .result = lists });
    try testing.expectEqualStrings("summary wrong: π1 RAES, π2 RAES, π3 RAES; res ⊤{lost}; π3 calls many, need owned, unseen", try f.text(wrong, "wrong"));
    const cb: Param = .{ .place = fun, .words = bits(&.{ .once, .taken, .stored }), .fn_params = &.{list}, .fn_result = list };
    const two = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, cb, cb }, .result = lists });
    try testing.expectEqual(Summary.Origin.unknown, f.sums.get(two).origin);
    // A cell callback without `stored`, or whose answer is not the contents.
    const ref = try f.placeOf(7);
    const bare = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellwrite}) }, .{ .place = fun, .words = bits(&.{.cellupdate}), .fn_params = &.{list}, .fn_result = list } }, .result = int });
    try testing.expectEqual(Summary.Origin.unknown, f.sums.get(bare).origin);
    const off = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellwrite}) }, .{ .place = fun, .words = bits(&.{ .cellupdate, .stored }), .fn_params = &.{list}, .fn_result = int } }, .result = int });
    try testing.expectEqual(Summary.Origin.unknown, f.sums.get(off).origin);
}

test "a write-back is part of the class: the normal form tells it apart, a join keeps it, the order reads it" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const list = try f.placeOf(0);
    const int = try f.placeOf(1);
    const ref = try f.placeOf(7);
    const fun = try f.placeOf(12);
    const pair = try f.placeOf(13);
    // `cellupdate stored` against `cellmodify stored`, with one result
    // place: two different write-backs of one callback, `ε` and `.1`.
    const whole = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellwrite}) }, .{ .place = fun, .words = bits(&.{ .cellupdate, .stored }), .fn_params = &.{list}, .fn_result = list } }, .result = int });
    const second = try fromWords(env, &f.sums, .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellwrite}) }, .{ .place = fun, .words = bits(&.{ .cellmodify, .stored }), .fn_params = &.{list}, .fn_result = pair } }, .result = int });
    try testing.expect(!try f.sums.eq(env, whole, second));
    const joined = try f.sums.join(env, whole, second, .choice);
    try testing.expectEqual(@as(u32, 2), f.sums.fun(joined, 0).backs.len);
    try testing.expect(try f.sums.leq(env, whole, joined));
    try testing.expect(try f.sums.leq(env, second, joined));
    try testing.expect(!try f.sums.leq(env, joined, whole));
}

test "every row of the selectors and the write-backs is below `⊤call` over its places" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    const env = f.env();
    const list = try f.placeOf(0);
    const int = try f.placeOf(1);
    const lists = try f.placeOf(2);
    const recs = try f.placeOf(9);
    const rec = try f.placeOf(5);
    const fun3 = try f.placeOf(3);
    const fun = try f.placeOf(12);
    const ref = try f.placeOf(7);
    const maybe = try f.placeOf(8);
    const pair = try f.placeOf(13);
    const payload = try f.places.ctorStep(testing.allocator, &f.account, 1, 0);
    const sigs = [_]Signature{
        .{ .params = &.{ .{ .place = lists, .words = bits(&.{.borrowed}) }, .{ .place = int, .words = bits(&.{.borrowed}) } }, .result = list, .result_words = bits(&.{.elementof}) },
        .{ .params = &.{.{ .place = lists, .words = bits(&.{.borrowed}) }}, .result = lists, .result_words = bits(&.{.copyof}) },
        .{ .params = &.{.{ .place = recs, .words = bits(&.{.borrowed}) }}, .result = recs, .result_words = bits(&.{.copyof}) },
        .{ .params = &.{ .{ .place = recs, .words = bits(&.{.borrowed}) }, .{ .place = fun3, .words = bits(&.{.many}), .fn_params = &.{ rec, rec } } }, .result = recs, .result_words = bits(&.{.copyof}) },
        .{ .params = &.{ .{ .place = list, .words = bits(&.{.stored}) }, .{ .place = lists, .words = bits(&.{.returned}) } }, .result = lists, .result_words = bits(&.{.prepended}) },
        .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, .{ .place = int, .words = bits(&.{.borrowed}) }, .{ .place = fun, .words = bits(&.{ .once, .taken, .stored }), .fn_params = &.{list}, .fn_result = list } }, .result = lists },
        .{ .params = &.{ .{ .place = lists, .words = bits(&.{ .written, .returned }) }, .{ .place = int, .words = bits(&.{.borrowed}) }, .{ .place = fun, .words = bits(&.{ .once, .taken, .stored }), .fn_params = &.{maybe}, .fn_result = maybe, .fn_payload = payload } }, .result = lists },
        .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellwrite}) }, .{ .place = fun, .words = bits(&.{ .cellupdate, .stored }), .fn_params = &.{list}, .fn_result = list } }, .result = int },
        .{ .params = &.{ .{ .place = ref, .words = bits(&.{.cellwrite}) }, .{ .place = fun, .words = bits(&.{ .cellmodify, .stored }), .fn_params = &.{list}, .fn_result = pair } }, .result = list },
    };
    for (sigs) |sig| {
        const row = try fromWords(env, &f.sums, sig);
        const top = try pessimistic(env, &f.sums, sig);
        try testing.expect(try f.sums.leq(env, row, top));
        try testing.expect(!try f.sums.leq(env, top, row));
    }
}
