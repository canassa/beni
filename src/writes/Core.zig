//! The core summary table (`docs/design/write-sets.md` §3.7; the owner's
//! decision O4: a table in the compiler, beside the guarantees it cites).
//!
//! A row gives a core function's result as an abstract value over its
//! arguments' abstract values. Every row restates a promise `core/` or the
//! backend already makes about identity — `backend.md` §4 (*Identity: what
//! an operation returns unchanged*) and the header comments of
//! `core/List.beni` — and every row names the `run/` fixture that pins that
//! promise in both builds. A reader who finds a row the sibling does not
//! honour has found a defect in the sibling, not in the row.
//!
//! The `run/` fixtures the rows below name as pins of an identity —
//! `ListIdentity`, `ListIndexedIdentity` and `WriteRowsIdentity` — were
//! retired on 2026-10-16 (issue #210), with the identity promises dropped on
//! 2026-10-13 (`ownership-checker.md` §27): those citations are historical.
//!
//! A core function with no row is summarised from its body like a user
//! function (§3.3, *Calls to core and platform functions*); one whose body
//! reaches a `foreign` gets `Fresh` there. Nothing is ever wrong for want of
//! a row, only coarse.

const std = @import("std");

pub const Row = enum {
    /// `List.map xs f`: `xs` itself when every result is `===` its element,
    /// else a list of `xs`'s length whose `i`th element is `f (xs[i])`.
    /// `backend.md` §4, *Identity*: "`map` and `indexedMap` whose every
    /// result is the element they were given return their input".
    /// Pinned: `run/ListIndexedIdentity` ("map identity").
    map,
    /// `List.indexedMap xs f`: as `map`, with the index facts of §3.3.
    /// Pinned: `run/ListIndexedIdentity` ("indexedMap identity").
    indexed_map,
    /// `List.filter xs f`: a subsequence of `xs`'s own elements, in order;
    /// `xs` itself when every element is kept. Pinned: `run/ListIdentity`
    /// ("filter element"), `run/ListIndexedIdentity` ("filter all").
    filter,
    /// `List.filterMap xs f`: a subsequence when `f` answers `Just` of its
    /// own element or `Nothing`. Pinned: `run/WriteRowsIdentity`.
    filter_map,
    /// `List.update xs k f`: `xs` itself out of range or when `f` answers
    /// its element; else `xs` with position `k` rewritten. Pinned:
    /// `run/ListIndexedIdentity` ("update -1", "update length",
    /// "update same").
    update,
    /// `List.set xs k v`: likewise. Pinned: `run/ListIndexedIdentity`.
    set,
    /// `List.swap xs i j`. Pinned: `run/ListIndexedIdentity`.
    swap,
    /// `List.push xs v`: `xs`'s elements, then `v`. Pinned:
    /// `run/WriteRowsIdentity` ("push element").
    push,
    /// `List.append xs ys` (and `++` on lists): `xs`'s elements then
    /// `ys`'s. Pinned: `run/ListIdentity` ("append element", "append xs []").
    append,
    /// `List.cons v xs`: `v`, then `xs`'s elements. Pinned:
    /// `run/WriteRowsIdentity` ("cons element").
    cons,
    /// `List.pop`, `take`, `drop`, `slice`: a prefix, a suffix or a view of
    /// `xs`'s own elements. Pinned: `run/ListIdentity` ("take element"),
    /// `run/ListIndexedIdentity`.
    remove_some,
    /// `List.tail xs`: `Just` of a view, or `Nothing`.
    tail,
    /// `List.insertAt xs k v`. Pinned: `run/ListIndexedIdentity`.
    insert_at,
    /// `List.removeAt xs k`. Pinned: `run/ListIndexedIdentity`.
    remove_at,
    /// `List.reverse`, `sort`, `sortBy`, `sortWith`: `xs`'s elements, each
    /// once (`backend.md` §4, invariant 6). Pinned: `run/WriteRowsIdentity`
    /// ("reverse element").
    permute,
    /// `List.get xs k`: `Just` of the element itself, or `Nothing`. Pinned:
    /// `run/WriteRowsIdentity` ("get element").
    get,
    /// `List.head xs`: `get xs 0`.
    head,
    /// `List.last xs`: `Just` of some element, or `Nothing`.
    last,
    /// `Debug.log tag x`: `x` itself — the sibling returns its argument.
    /// A promise this document made (§5.4 item 3). Pinned:
    /// `run/WriteRowsIdentity` ("Debug.log").
    debug_log,
    /// `Debug.todo`: never returns.
    debug_todo,
    /// `List.foldl`, `foldr`: `Fresh`, except a fold whose accumulator is
    /// a dictionary its callback edits (write-sets.md, amended 2026-10-25).
    fold,
    /// The ordered `Dict`'s rows (write-sets.md, amended 2026-10-25: positions
    /// in a `Dict`, O3 lifted). Each restates `language.md` §6.8's promise of
    /// what the operation does to the storage's keys and order; the writes are
    /// in place (`backend.md` §4, *Ordered dictionaries*).
    dict_insert,
    dict_remove,
    dict_update,
    dict_swap,
    dict_insert_at,
    dict_sort_by,
    dict_filter,
    dict_map,
    dict_get,
    dict_empty,
    /// `Log.annotate key value work`, `Log.span label work`, `Log.minimum
    /// level work`, `Log.withSink f work`: `work ⊤` itself — each runs its
    /// last argument once, in a log context, and returns what it returns
    /// (`core/Log.beni`, `within`). So an `update` arm written inside one
    /// has its model and its command read through it (`boundary.md`
    /// §9.8.16 (b), #751). A command with a body made inside one is not
    /// read yet (`unscopedCommands` in `Writes.zig`; #1003). Pinned:
    /// `browser/inline/LogScopeInUpdate`, `build/bad/inline/CommandInLogScope`.
    log_scope,
    /// A value nothing relates to the old model: the scalars and the other
    /// folds of `List`, every other `Dict` and every `Set` function,
    /// `Basics`, `Int`, `Float`, `String`, `Char`, `Cmd`, `Sub`, `Task`, `Js`.
    fresh,
};

const Entry = struct { []const u8, Row };

/// The `List` rows, by value name.
const list_rows = [_]Entry{
    .{ "map", .map },
    .{ "indexedMap", .indexed_map },
    .{ "filter", .filter },
    .{ "filterMap", .filter_map },
    .{ "update", .update },
    .{ "set", .set },
    .{ "swap", .swap },
    .{ "push", .push },
    .{ "append", .append },
    .{ "cons", .cons },
    .{ "pop", .remove_some },
    .{ "take", .remove_some },
    .{ "drop", .remove_some },
    .{ "slice", .remove_some },
    .{ "tail", .tail },
    .{ "insertAt", .insert_at },
    .{ "removeAt", .remove_at },
    .{ "reverse", .permute },
    .{ "sort", .permute },
    .{ "sortBy", .permute },
    .{ "sortWith", .permute },
    .{ "get", .get },
    .{ "head", .head },
    .{ "last", .last },
    .{ "foldl", .fold },
    .{ "foldr", .fold },
};

/// The `Dict` rows, by value name.
const dict_rows = [_]Entry{
    .{ "insert", .dict_insert },
    .{ "remove", .dict_remove },
    .{ "update", .dict_update },
    .{ "swap", .dict_swap },
    .{ "insertAt", .dict_insert_at },
    .{ "sortBy", .dict_sort_by },
    .{ "filter", .dict_filter },
    .{ "map", .dict_map },
    .{ "get", .dict_get },
    .{ "empty", .dict_empty },
};

/// The modules every function of which is `Fresh` of its arguments, save
/// the exceptions `bodied` lists.
const fresh_modules = [_][]const u8{ "Dict", "Set", "Basics", "Int", "Float", "String", "Char", "Cmd", "Sub", "Task", "Js", "Html", "Schema" };

/// Core functions summarised from their bodies although their module is in
/// `fresh_modules`: `Basics.identity x = x` and `always`, by their bodies
/// (§3.7).
const bodied = [_][2][]const u8{
    .{ "Basics", "identity" },
    .{ "Basics", "always" },
};

/// The row for `module.name`, or null when the function is summarised from
/// its body. Only asked of core and platform functions.
pub fn row(module: []const u8, name: []const u8) ?Row {
    if (std.mem.eql(u8, module, "List")) {
        for (list_rows) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
        return .fresh;
    }
    if (std.mem.eql(u8, module, "Dict")) {
        for (dict_rows) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
        return .fresh;
    }
    if (std.mem.eql(u8, module, "Debug")) {
        if (std.mem.eql(u8, name, "log")) return .debug_log;
        if (std.mem.eql(u8, name, "todo")) return .debug_todo;
        return .fresh;
    }
    if (std.mem.eql(u8, module, "Log")) {
        for ([_][]const u8{ "annotate", "span", "minimum", "withSink" }) |n| if (std.mem.eql(u8, n, name)) return .log_scope;
        return null;
    }
    for (bodied) |b| if (std.mem.eql(u8, b[0], module) and std.mem.eql(u8, b[1], name)) return null;
    for (fresh_modules) |m| if (std.mem.eql(u8, m, module)) return .fresh;
    return null;
}

test "rows" {
    try std.testing.expectEqual(Row.map, row("List", "map").?);
    try std.testing.expectEqual(Row.fold, row("List", "foldl").?);
    try std.testing.expectEqual(Row.fresh, row("List", "length").?);
    try std.testing.expectEqual(Row.debug_log, row("Debug", "log").?);
    try std.testing.expectEqual(Row.log_scope, row("Log", "annotate").?);
    try std.testing.expectEqual(@as(?Row, null), row("Log", "info"));
    try std.testing.expectEqual(@as(?Row, null), row("Basics", "identity"));
    try std.testing.expectEqual(@as(?Row, null), row("Maybe", "map"));
    try std.testing.expectEqual(Row.dict_insert, row("Dict", "insert").?);
    try std.testing.expectEqual(Row.fresh, row("Dict", "size").?);
    try std.testing.expectEqual(Row.fresh, row("Set", "insert").?);
}
