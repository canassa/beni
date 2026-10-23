//! The ownership checker's error messages (`docs/design/ownership-checker.md`
//! §28.6; thesis Chapter 8, *Error Reporting*).
//!
//! Every message has the thesis's fixed shape: one sentence naming the
//! operation, the list and why it is a problem here; the places — what keeps
//! the list, the edit, the later read — each as a numbered source line with a
//! caret run and a label, in source order; what the program would see if the
//! change happened in place; the fix, written out with `List.copy`; and the
//! verdict line, which says whether this is sharing the text shows, a limit of
//! the checker, or the language's rule.
//!
//! The message holds its own excerpts, so the renderer prints none after it.
//! It is built from report lines (`Ownership.Demand`) and the source, which
//! `Src` hands over; nothing here reads a file or a session.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diagnostic = @import("diagnostic");
const Ownership = @import("Ownership.zig");

const Demand = Ownership.Demand;
const Cause = Ownership.Cause;
const none = Ownership.none;

/// The four codes (§28.6), by a line's verdict; a record update's are
/// §31.9's, `view_changes_model` shared with lists.
pub fn code(d: Demand) diagnostic.Code {
    if (d.record) return switch (d.verdict) {
        .accepted => unreachable,
        .pending => .record_may_be_shared,
        .rejected => |c| switch (c) {
            .top_level => .top_level_record_changed,
            .read_only => .view_changes_model,
            else => if (d.approx) .record_may_be_shared else .record_still_used,
        },
    };
    return switch (d.verdict) {
        .accepted => unreachable,
        .pending => .list_may_be_shared,
        .rejected => |c| switch (c) {
            .top_level => .top_level_list_changed,
            .read_only => .view_changes_model,
            else => if (d.approx) .list_may_be_shared else .list_still_used,
        },
    };
}

/// What a message needs of the source.
pub const Src = struct {
    ctx: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The start of token `tok` of module `m`.
        start: *const fn (ctx: *const anyopaque, m: u32, tok: u32) diagnostic.Position,
        /// The end, exclusive, of token `tok` of module `m`.
        end: *const fn (ctx: *const anyopaque, m: u32, tok: u32) diagnostic.Position,
        /// Line `line` of module `m`'s file, without its terminator.
        line: *const fn (ctx: *const anyopaque, m: u32, line: u32) []const u8,
        /// Module `m`'s file, as a diagnostic names it.
        path: *const fn (ctx: *const anyopaque, m: u32) []const u8,
        /// The token of declaration `d`'s name in module `m`, or `none`.
        decl_token: *const fn (ctx: *const anyopaque, m: u32, d: u32) u32,
        /// Declaration `d`'s name, and module `m`'s.
        decl_name: *const fn (ctx: *const anyopaque, m: u32, d: u32) []const u8,
        module_name: *const fn (ctx: *const anyopaque, m: u32) []const u8,
    };

    fn start(s: Src, m: u32, tok: u32) diagnostic.Position {
        return s.vtable.start(s.ctx, m, tok);
    }
    fn end(s: Src, m: u32, tok: u32) diagnostic.Position {
        return s.vtable.end(s.ctx, m, tok);
    }
    fn line(s: Src, m: u32, n: u32) []const u8 {
        return s.vtable.line(s.ctx, m, n);
    }
    fn path(s: Src, m: u32) []const u8 {
        return s.vtable.path(s.ctx, m);
    }
};

/// One place a message shows: a run of tokens of a module, and its label.
const Place = struct {
    m: u32,
    first: u32,
    last: u32,
    label: []const u8,
};

/// The text of tokens `first` to `last` of module `m`, when they are on one
/// line; null otherwise.
fn text(src: Src, m: u32, first: u32, last: u32) ?[]const u8 {
    if (first == none or last == none) return null;
    const a = src.start(m, first);
    const b = src.end(m, last);
    if (a.line != b.line or b.col <= a.col) return null;
    const ln = src.line(m, a.line);
    const lo = diagnostic.codePointOffset(ln, a.col - 1);
    const hi = diagnostic.codePointOffset(ln, b.col - 1);
    if (lo > hi or hi > ln.len) return null;
    return ln[lo..hi];
}

/// `x` in backticks when it is short enough to read inside a sentence.
fn quoted(a: Allocator, x: ?[]const u8) Allocator.Error!?[]const u8 {
    const t = x orelse return null;
    if (diagnostic.codePoints(t) > 48) return null;
    return try std.fmt.allocPrint(a, "`{s}`", .{t});
}

/// A detail meant for the report, as the end of a sentence: section
/// references in parentheses are the report's, not the reader's.
fn plain(a: Allocator, detail: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < detail.len) {
        if (detail[i] == '(') {
            if (std.mem.indexOfScalarPos(u8, detail, i, ')')) |close| {
                if (std.mem.indexOf(u8, detail[i..close], "§") != null) {
                    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
                    i = close + 1;
                    continue;
                }
            }
        }
        try out.append(a, detail[i]);
        i += 1;
    }
    return out.items;
}

/// The names of the bases a group of lines writes, as a sentence lists them.
fn baseList(a: Allocator, lines: []const Demand) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines, 0..) |l, i| {
        if (i > 0) try out.appendSlice(a, if (i + 1 == lines.len) " and " else ", ");
        try out.print(a, "`{s}`", .{l.base});
    }
    return out.items;
}

fn isName(base: []const u8) bool {
    return base.len > 0 and base[0] != '<';
}

fn before(src: Src, m: u32, x: u32, y: u32) bool {
    return src.start(m, x).order(src.start(m, y)) == .lt;
}

/// The message for a declaration that reached one of the checker's limits
/// (§16.7, `ownership_limit`): the declaration, the limit, what it measured,
/// and that the limit is the compiler's. The renderer shows the
/// declaration's name under it.
pub fn limit(a: Allocator, src: Src, m: u32, h: Ownership.LimitLine) Allocator.Error![]const u8 {
    const name = try std.fmt.allocPrint(a, "{s}.{s}", .{ src.vtable.module_name(src.ctx, m), h.name });
    const what = switch (h.limit) {
        .none => unreachable,
        .rounds => try std.fmt.allocPrint(a, "`{s}`'s ownership summary did not settle within the checker's limit of {d} rounds", .{ name, h.limit.cap() }),
        .entries => try std.fmt.allocPrint(a, "`{s}`'s ownership summary needs {d} entries, more than the checker's limit of {d}", .{ name, h.at, h.limit.cap() }),
        .path_entries => try std.fmt.allocPrint(a, "`{s}`'s ownership summary needs {d} entries at one path, more than the checker's limit of {d}", .{ name, h.at, h.limit.cap() }),
        .owned_atoms => try std.fmt.allocPrint(a, "`{s}`'s ownership summary rests on {d} places where its function arguments must return lists they own, more than the checker's limit of {d}", .{ name, h.at, h.limit.cap() }),
        .value_cells => try std.fmt.allocPrint(a, "checking `{s}` needs whether {d} lists are each held once, more than the checker's limit of {d}", .{ name, h.at, h.limit.cap() }),
        .fixpoint => try std.fmt.allocPrint(a, "checking `{s}` needs a fixpoint that did not settle within the checker's limit of {d} rounds", .{ name, h.limit.cap() }),
        .conditions => try std.fmt.allocPrint(a, "`{s}`'s ownership summary needs {d} conditions on what its arguments share, more than the checker's limit of {d}", .{ name, h.at, h.limit.cap() }),
        .callbacks => try std.fmt.allocPrint(a, "checking `{s}` needs a chain of more than {d} function arguments, each handed what the one before returned, which is the checker's limit", .{ name, h.limit.cap() }),
    };
    return std.fmt.allocPrint(a,
        \\{s} (ownership-checker.md §16.7).
        \\
        \\This is a limit of the compiler, not sharing in your code: the checker
        \\cannot tell which lists `{s}` changes or keeps, so it refuses the build
        \\rather than guess.
    , .{ what, h.name });
}

/// The message for a group of lines that share one root cause (§28.5): the
/// same position, verdict, cause and detail; `lines[0]` speaks for them.
pub fn build(a: Allocator, src: Src, m: u32, lines: []const Demand) Allocator.Error![]const u8 {
    if (lines[0].record) return buildRecord(a, src, m, lines);
    const d = lines[0];
    const cause: ?Cause = switch (d.verdict) {
        .rejected => |c| c,
        else => null,
    };
    const exact = d.verdict == .rejected and !d.approx;
    const entry = std.mem.startsWith(u8, d.op, "entry ");
    // A function value that must return a list it owns (§28.6, amended).
    // It is a rejection, never a pending line: `needLine`, `needAt` and
    // `needUnknown` fix the verdict `need`.
    const need = cause == .need and std.mem.eql(u8, d.op, "value");
    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn s(o: *std.ArrayList(u8), al: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
            try o.print(al, fmt, args);
        }
    }.s;

    const edit_text = try quoted(a, text(src, m, d.span[0], d.span[1]));
    const base_source = text(src, m, d.base_span[0], d.base_span[1]);
    const base_name: []const u8 = if (lines.len > 1)
        try baseList(a, lines)
    else if (isName(d.base))
        try std.fmt.allocPrint(a, "`{s}`", .{d.base})
    else if (try quoted(a, base_source)) |q|
        q
    else
        "the list";
    const holder: []const u8 = if (d.holder.len > 0) try std.fmt.allocPrint(a, "`{s}`", .{d.holder}) else "something";
    const edit_line = if (d.span[0] != none) src.start(m, d.span[0]).line else 0;
    const read_line = if (d.read_span[0] != none) src.start(m, d.read_span[0]).line else 0;
    const top = try topName(a, src, m, d);
    // The function an entry line is about: `update`, `view`.
    const entry_fn: []const u8 = if (entry) blk: {
        const f = d.op["entry ".len..];
        break :blk if (std.mem.lastIndexOfScalar(u8, f, '.')) |dot| f[dot + 1 ..] else f;
    } else "";

    // ---- the sentence ----------------------------------------------------
    const op = d.op;
    if (std.mem.eql(u8, op, "construction") or std.mem.eql(u8, op, "++")) {
        try w(&out, a, "{s} adds to the end of {s} itself", .{ edit_text orelse "This list", base_name });
    } else if (std.mem.startsWith(u8, op, "List.")) {
        try w(&out, a, "`{s}` changes {s} in place", .{ op, base_name });
    } else if (std.mem.startsWith(u8, op, "call ")) {
        try w(&out, a, "`{s}` changes {s} in place", .{ op["call ".len..], if (isName(d.base) or lines.len > 1) base_name else "a list it is handed" });
    } else if (entry) {
        try w(&out, a, "`{s}` changes {s} in place", .{ entry_fn, base_name });
    } else if (std.mem.eql(u8, op, "send")) {
        try w(&out, a, "Sending {s} gives the list up to `update`", .{base_name});
    } else if (need) {
        try w(&out, a, "{s} must return a list it owns", .{try functionName(a, d.base)});
    } else if (std.mem.eql(u8, op, "value")) {
        try w(&out, a, "`{s}` changes a list it is handed in place", .{d.base});
    } else {
        try w(&out, a, "This changes {s} in place", .{base_name});
    }
    if (d.verdict == .pending) {
        try w(&out, a, ", and the function that does it goes where the checker cannot see every call of it: {s}.", .{try plain(a, d.detail)});
    } else if (need) {
        if (exact)
            try w(&out, a, ", but {s}.", .{try plain(a, d.detail)})
        else
            try w(&out, a, ", and the checker cannot show that it does.", .{});
    } else if (cause) |c| switch (c) {
        .later_use => try w(&out, a, ", but {s} is read again afterwards.", .{holder}),
        .alias => try w(&out, a, ", but {s} still holds the old list and is read afterwards.", .{holder}),
        .captured => try w(&out, a, ", but {s}, a function that holds the list, is used afterwards.", .{holder}),
        .level => try w(&out, a, ", and the checker cannot tell the levels of a recursive value apart: it keeps one place for all of them, so {s} may hold the list at another level.", .{if (d.holder.len > 0) holder else "another part of the same operation"}),
        .held_operand => try w(&out, a, ", but a value computed earlier in the same expression still holds the list.", .{}),
        .top_level => if (entry)
            try w(&out, a, ", but when the program starts {s} `{s}`, a top-level value.", .{ if (lines.len > 1) "each is" else "it is", top })
        else
            try w(&out, a, ", but it is `{s}`, a top-level value.", .{top}),
        .read_only => try w(&out, a, ", but the runtime hands `{s}` the model to read only.", .{entry_fn}),
        .disjoint => if (exact)
            try w(&out, a, ", but another part of the same operation reads the same list.", .{})
        else
            try w(&out, a, ", and the checker cannot show that nothing else still holds the list.", .{}),
        else => if (exact)
            try w(&out, a, ", but {s}.", .{try plain(a, d.detail)})
        else
            try w(&out, a, ", and the checker cannot show that nothing else still holds the list.", .{}),
    };
    try out.appendSlice(a, "\n\n");

    // ---- the places ------------------------------------------------------
    var places: std.ArrayList(Place) = .empty;
    const changed: []const u8 = if (std.mem.eql(u8, op, "send"))
        "the list is given up here"
    else if (entry)
        try std.fmt.allocPrint(a, "the runtime hands `{s}` the model here", .{entry_fn})
    else if (need)
        "the function is handed on here"
    else
        "the list is changed in place here";
    if (d.span[0] != none) try places.append(a, .{ .m = m, .first = d.span[0], .last = d.span[1], .label = changed });
    if (need and d.via_token != none and d.via_token != d.span[0])
        try places.append(a, .{ .m = m, .first = d.via_token, .last = d.via_token, .label = "the function here may return a list it does not own" });
    if (cause) |c| switch (c) {
        .alias, .captured, .call, .level => if (d.keep_token != none and d.holder.len > 0) {
            const verb: []const u8 = if (c == .captured) "holds" else "keeps";
            try places.append(a, .{ .m = m, .first = d.keep_token, .last = d.keep_token, .label = try std.fmt.allocPrint(a, "{s} {s} the list here", .{ holder, verb }) });
        },
        .held_operand => if (d.via_token != none) {
            try places.append(a, .{ .m = m, .first = d.via_token, .last = d.via_token, .label = "this value, computed first, still holds the list" });
        },
        else => {},
    };
    if (cause == .call and d.via_token != none) {
        const label = if (d.holder.len > 0)
            try std.fmt.allocPrint(a, "{s} may hold the list through this call", .{holder})
        else
            "this call may answer the same list";
        try places.append(a, .{ .m = m, .first = d.via_token, .last = d.via_token, .label = label });
    }
    if (cause) |c| switch (c) {
        .later_use, .alias, .call, .captured, .level => if (d.read_span[0] != none) {
            const verb: []const u8 = if (c == .captured) "used" else "read";
            // A read written before the edit, as a tuple's first item, that
            // happens after it, when the tuple is built.
            const label = if (d.span[0] != none and before(src, m, d.read_span[0], d.span[0]))
                try std.fmt.allocPrint(a, "{s} is taken here, and {s} after the change", .{ holder, verb })
            else
                try std.fmt.allocPrint(a, "and {s} is {s} here, after the change", .{ holder, verb });
            try places.append(a, .{ .m = m, .first = d.read_span[0], .last = d.read_span[1], .label = label });
        },
        else => {},
    };
    std.mem.sort(Place, places.items, src, placeLess);
    try writePlaces(a, &out, src, m, places.items);
    // A top-level value is defined elsewhere, perhaps in another file.
    if (d.top) |t| {
        const tok = src.vtable.decl_token(src.ctx, t[0], t[1]);
        if (tok != none) {
            if (t[0] != m) try w(&out, a, "\n`{s}` is defined in {s}:\n\n", .{ top, src.path(t[0]) }) else try out.appendSlice(a, "\n");
            try writePlaces(a, &out, src, t[0], &.{.{ .m = t[0], .first = tok, .last = tok, .label = "the top-level list is defined here" }});
        }
    }
    try out.appendSlice(a, "\n");

    // ---- what the program would see -----------------------------------
    if (exact) {
        if (cause) |c| switch (c) {
            .later_use, .alias => if (read_line != 0) {
                try w(&out, a, "If the list were changed in place, {s} would see the change when it is read on line {d}.\n\n", .{ holder, read_line });
            },
            .captured => if (read_line != 0) {
                try w(&out, a, "If the list were changed in place, {s} would see the change when it is used on line {d}.\n\n", .{ holder, read_line });
            },
            .held_operand => try w(&out, a, "If the list were changed in place, that value would already hold the change when it is used.\n\n", .{}),
            .disjoint => try w(&out, a, "If the list were changed in place, the other part would read it changed.\n\n", .{}),
            .top_level => try w(&out, a, "A top-level value is shared by every part of the program and never changes: changed in place, it would change for every part that reads it.\n\n", .{}),
            .read_only => try w(&out, a, "The runtime keeps the model it hands `{s}` for the next message and the next render, so a change in place would be seen by both.\n\n", .{entry_fn}),
            else => {},
        };
    }

    // ---- the fix ---------------------------------------------------------
    var fixed = false;
    if (cause != .top_level and cause != .read_only) {
        const fix_line = copyLine(a, src, m, d) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoBase => null,
        };
        if (fix_line) |line| {
            const lead = if (exact)
                try std.fmt.allocPrint(a, "To change a copy and leave {s} as it was, copy it there:", .{if (isName(d.base)) try std.fmt.allocPrint(a, "`{s}`", .{d.base}) else "the list"})
            else if (cause == .level)
                "To be safe, change a copy, or copy the list where it is put into the recursive value, so that no two of its levels hold the same list:"
            else
                "To be safe, change a copy:";
            try w(&out, a, "{s}\n\n{s}\n\n", .{ lead, line });
            if (cause == .level) try w(&out, a, "A record field is copied the same way, with `Record.copy`.\n\n", .{});
            fixed = true;
        }
    }
    if (cause == .top_level) {
        if (entry)
            try w(&out, a, "Build the value inside `init ⊤`, so that each call makes fresh lists:\n\n    init ⊤ = …\n\nCall that function where the model is made. Wrapping `{s}` in `λ⊤ → {s}` still returns the same shared value.\n\n", .{ top, top })
        else {
            const whole = if (d.top) |t| t[2] == 1 else false;
            var copy = if (whole or d.base.len == 0) top else d.base;
            // Report paths qualify this module, but its own name is not an
            // import alias that the suggested source expression can use.
            const prefix = try std.fmt.allocPrint(a, "{s}.", .{src.vtable.module_name(src.ctx, m)});
            if (std.mem.startsWith(u8, copy, prefix)) copy = copy[prefix.len..];
            try w(&out, a, "Make `{s}` a function that builds a fresh value at each call, or change a copy: `List.copy {s}`.\n\n", .{ top, copy });
        }
        fixed = true;
    } else if (cause == .read_only) {
        try w(&out, a, "Let `{s}` build a new list instead, or change a copy: `List.copy {s}`.\n\n", .{ entry_fn, d.base });
        fixed = true;
    } else if (cause == .alias and edit_line != 0 and d.holder.len > 0) {
        try w(&out, a, "Or, if {s} only needs the list as it was, read it before line {d}.\n\n", .{ holder, edit_line });
    }
    if (!fixed) {
        if (need)
            try w(&out, a, "Have the function return a list it owns: a new list, or a copy made with `List.copy`.\n\n", .{})
        else if (d.verdict == .pending)
            try w(&out, a, "Call it where it is written, or have it change a copy, made with `List.copy`.\n\n", .{})
        else if (cause == .payload)
            try w(&out, a, "Build the messages the page sends from values that are not the model's lists, or have `update` change a copy of what a message carries, made with `List.copy`.\n\n", .{})
        else if (entry and cause == .escaped)
            try w(&out, a, "Compute what a command or a subscription needs from the list before it is made, so that it keeps that value and not the list; or hand it a copy, made with `List.copy`.\n\n", .{})
        else if (entry)
            try w(&out, a, "Copy the list with `List.copy` where the model gets it, so that nothing else holds the list `{s}` changes.\n\n", .{entry_fn})
        else
            try w(&out, a, "Copy the list with `List.copy` before it is changed, so the change cannot reach anything else that holds it.\n\n", .{});
    }

    // ---- the verdict -----------------------------------------------------
    if (d.verdict == .pending) {
        try w(&out, a, "This is a limit of the checker, not proof of sharing: a call it cannot see may hand the function a list something else still holds.", .{});
    } else if (cause) |c| switch (c) {
        .top_level => if (entry)
            try w(&out, a, "This is the language's rule for top-level values, whether or not anything else reads the list. `init` builds its model; a top-level value it returns is still shared (ownership-checker.md §22.2).", .{})
        else
            try w(&out, a, "This is the language's rule for top-level values, whether or not anything else reads the list (ownership-checker.md §4.2).", .{}),
        .read_only => try w(&out, a, "This is the platform's rule for `{s}`, whether or not anything else reads the list.", .{entry_fn}),
        .level => try w(&out, a, "This is a limit of the checker, not proof of sharing: it keeps one place for all the levels of a recursive value, so it cannot show that two levels hold different lists (language.md §6.8).", .{}),
        else => if (exact) switch (c) {
            .later_use, .alias, .captured => if (read_line != 0)
                try w(&out, a, "This is sharing the checker can see: {s} is {s} on line {d}, after the change.", .{ holder, if (c == .captured) "used" else "read", read_line })
            else
                try w(&out, a, "This is sharing the checker can see: {s}.", .{try plain(a, d.detail)}),
            .held_operand => try w(&out, a, "This is sharing the checker can see: the value computed first holds the list until the expression uses it.", .{}),
            .disjoint => try w(&out, a, "This is sharing the checker can see: two parts of one operation reach the same list.", .{}),
            else => try w(&out, a, "This is sharing the checker can see: {s}.", .{try plain(a, d.detail)}),
        } else try w(&out, a, "This is a limit of the checker, not proof of sharing: {s}.", .{try plain(a, d.detail)}),
    };
    return out.items;
}

/// The message for a group of record lines (§31.9): §28.6's shape, with the
/// subject a record and the fix written with `Record.copy` (§31.15). A
/// later read of a field is never in it: the lowering reads it first
/// (§31.14), so every holder a message names is used whole.
fn buildRecord(a: Allocator, src: Src, m: u32, lines: []const Demand) Allocator.Error![]const u8 {
    const d = lines[0];
    const cause: ?Cause = switch (d.verdict) {
        .rejected => |c| c,
        else => null,
    };
    const exact = d.verdict == .rejected and !d.approx;
    const entry = std.mem.startsWith(u8, d.op, "update entry ");
    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn s(o: *std.ArrayList(u8), al: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
            try o.print(al, fmt, args);
        }
    }.s;

    const edit_text = try quoted(a, text(src, m, d.span[0], d.span[1]));
    const base_source = text(src, m, d.base_span[0], d.base_span[1]);
    const base_name: []const u8 = if (lines.len > 1)
        try baseList(a, lines)
    else if (isName(d.base))
        try std.fmt.allocPrint(a, "`{s}`", .{d.base})
    else if (try quoted(a, base_source)) |q|
        q
    else
        "the record";
    const holder: []const u8 = if (d.holder.len > 0) try std.fmt.allocPrint(a, "`{s}`", .{d.holder}) else "something";
    const read_line = if (d.read_span[0] != none) src.start(m, d.read_span[0]).line else 0;
    const top = try topName(a, src, m, d);
    // The function an entry line is about: `update`.
    const entry_fn: []const u8 = if (entry) blk: {
        const f = d.op["update entry ".len..];
        const name = if (std.mem.indexOfScalar(u8, f, ' ')) |sp| f[0..sp] else f;
        break :blk if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[dot + 1 ..] else name;
    } else "";
    // A call that changes the record it is handed (§31.7): `(M.f writes it)`.
    const writer: ?[]const u8 = blk: {
        const k = std.mem.indexOf(u8, d.note, " writes it") orelse break :blk null;
        break :blk d.note[0..k];
    };

    // ---- the sentence ----------------------------------------------------
    if (entry) {
        try w(&out, a, "`{s}` changes the record at {s} in place", .{ entry_fn, base_name });
    } else if (writer) |f| {
        try w(&out, a, "`{s}` changes {s} in place", .{ f, base_name });
    } else if (edit_text) |t| {
        try w(&out, a, "{s} changes {s} itself", .{ t, base_name });
    } else {
        try w(&out, a, "This update changes {s} itself", .{base_name});
    }
    if (d.verdict == .pending) {
        try w(&out, a, ", and the function that does it goes where the checker cannot see every call of it: {s}.", .{try plain(a, d.detail)});
    } else if (cause) |c| switch (c) {
        .later_use => try w(&out, a, ", but {s} is used whole afterwards.", .{holder}),
        .alias => try w(&out, a, ", but {s} still holds the old record and is used whole afterwards.", .{holder}),
        .captured => try w(&out, a, ", but {s}, a function that holds the record, is used afterwards.", .{holder}),
        .held_operand => try w(&out, a, ", but a value computed earlier in the same expression still holds the record.", .{}),
        .top_level => if (entry)
            try w(&out, a, ", but when the program starts it is `{s}`, a top-level value.", .{top})
        else
            try w(&out, a, ", but it is `{s}`, a top-level value.", .{top}),
        .read_only => try w(&out, a, ", but the runtime hands `{s}` the model to read only.", .{entry_fn}),
        .disjoint => if (exact)
            try w(&out, a, ", but another part of the same operation holds the same record.", .{})
        else
            try w(&out, a, ", and the checker cannot show that nothing else still holds the record.", .{}),
        else => if (exact)
            try w(&out, a, ", but {s}.", .{try plain(a, d.detail)})
        else
            try w(&out, a, ", and the checker cannot show that nothing else still holds the record.", .{}),
    };
    try out.appendSlice(a, "\n\n");

    // ---- the places ------------------------------------------------------
    var places: std.ArrayList(Place) = .empty;
    const changed: []const u8 = if (entry)
        try std.fmt.allocPrint(a, "the runtime hands `{s}` the model here", .{entry_fn})
    else
        "the record is changed in place here";
    if (d.span[0] != none) try places.append(a, .{ .m = m, .first = d.span[0], .last = d.span[1], .label = changed });
    if (cause) |c| switch (c) {
        .alias, .captured, .call, .element => if (d.keep_token != none and d.holder.len > 0) {
            const verb: []const u8 = if (c == .captured) "holds" else "keeps";
            try places.append(a, .{ .m = m, .first = d.keep_token, .last = d.keep_token, .label = try std.fmt.allocPrint(a, "{s} {s} the record here", .{ holder, verb }) });
        },
        .held_operand => if (d.via_token != none) {
            try places.append(a, .{ .m = m, .first = d.via_token, .last = d.via_token, .label = "this value, computed first, still holds the record" });
        },
        else => {},
    };
    if (cause == .call and d.via_token != none) {
        const label = if (d.holder.len > 0)
            try std.fmt.allocPrint(a, "{s} may hold the record through this call", .{holder})
        else
            "this call may answer the same record";
        try places.append(a, .{ .m = m, .first = d.via_token, .last = d.via_token, .label = label });
    }
    if (cause) |c| switch (c) {
        .later_use, .alias, .call, .captured, .element => if (d.read_span[0] != none) {
            const label = if (d.span[0] != none and before(src, m, d.read_span[0], d.span[0]))
                try std.fmt.allocPrint(a, "{s} is taken here, and used after the change", .{holder})
            else
                try std.fmt.allocPrint(a, "and {s} is used here, after the change", .{holder});
            try places.append(a, .{ .m = m, .first = d.read_span[0], .last = d.read_span[1], .label = label });
        },
        else => {},
    };
    std.mem.sort(Place, places.items, src, placeLess);
    try writePlaces(a, &out, src, m, places.items);
    if (d.top) |t| {
        const tok = src.vtable.decl_token(src.ctx, t[0], t[1]);
        if (tok != none) {
            if (t[0] != m) try w(&out, a, "\n`{s}` is defined in {s}:\n\n", .{ top, src.path(t[0]) }) else try out.appendSlice(a, "\n");
            try writePlaces(a, &out, src, t[0], &.{.{ .m = t[0], .first = tok, .last = tok, .label = "the top-level record is defined here" }});
        }
    }
    try out.appendSlice(a, "\n");

    // ---- what the program would see -----------------------------------
    if (exact) {
        if (cause) |c| switch (c) {
            .later_use, .alias, .captured => if (read_line != 0) {
                try w(&out, a, "If the record were changed in place, {s} would carry the new values of the changed fields when it is used on line {d}.\n\n", .{ holder, read_line });
            },
            .held_operand => try w(&out, a, "If the record were changed in place, that value would already hold the change when it is used.\n\n", .{}),
            .disjoint => try w(&out, a, "If the record were changed in place, the other part would see it changed.\n\n", .{}),
            .top_level => try w(&out, a, "A top-level value is shared by every part of the program and never changes: changed in place, it would change for every part that reads it.\n\n", .{}),
            .read_only => try w(&out, a, "The runtime keeps the model it hands `{s}` for the next message and the next render, so a change in place would be seen by both.\n\n", .{entry_fn}),
            else => {},
        };
    }

    // ---- the fix ---------------------------------------------------------
    var fixed = false;
    if (cause != .top_level and cause != .read_only and !entry) {
        const fix_line = recordCopyLine(a, src, m, d) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoBase => null,
        };
        if (fix_line) |line| {
            const lead = if (exact)
                try std.fmt.allocPrint(a, "To change a copy and leave {s} as it was, copy it there:", .{if (isName(d.base)) try std.fmt.allocPrint(a, "`{s}`", .{d.base}) else "the record"})
            else
                "To be safe, change a copy:";
            try w(&out, a, "{s}\n\n{s}\n\n", .{ lead, line });
            fixed = true;
        }
    }
    if (cause == .top_level) {
        if (entry)
            try w(&out, a, "Build the value inside `init ⊤`, so that each call makes a fresh record:\n\n    init ⊤ = …\n\nCall that function where the model is made. Wrapping `{s}` in `λ⊤ → {s}` still returns the same shared value.\n\n", .{ top, top })
        else {
            try w(&out, a, "Make `{s}` a function that builds a fresh record at each call, `{s} ⊤`, or change a copy: `{{ Record.copy {s} | … }}`.\n\n", .{ top, top, top });
        }
        fixed = true;
    } else if (cause == .read_only) {
        try w(&out, a, "Let `{s}` build a new record instead, or change a copy made with `Record.copy`.\n\n", .{entry_fn});
        fixed = true;
    }
    if (!fixed) {
        if (d.verdict == .pending)
            try w(&out, a, "Call it where it is written, or have it change a copy, made with `Record.copy`.\n\n", .{})
        else if (cause == .payload)
            try w(&out, a, "Build the messages the page sends from values that are not the model's records, find the model's own record by its key, or have `update` change a copy of what a message carries, made with `Record.copy`.\n\n", .{})
        else if (entry and cause == .escaped)
            try w(&out, a, "Compute what a command or a subscription needs from the record before it is made, so that it keeps that value and not the record; or hand it a copy, made with `Record.copy`.\n\n", .{})
        else if (entry)
            try w(&out, a, "Copy the record with `Record.copy` where the model gets it, so that nothing else holds the record `{s}` changes.\n\n", .{entry_fn})
        else
            try w(&out, a, "Copy the record with `Record.copy` before it is changed, so the change cannot reach anything else that holds it.\n\n", .{});
    }

    // ---- the verdict -----------------------------------------------------
    if (d.verdict == .pending) {
        try w(&out, a, "This is a limit of the checker, not proof of sharing: a call it cannot see may hand the function a record something else still holds.", .{});
    } else if (cause) |c| switch (c) {
        .top_level => if (entry)
            try w(&out, a, "This is the language's rule for top-level values, whether or not anything else reads the record. `init` builds its model; a top-level value it returns is still shared (ownership-checker.md §31.8).", .{})
        else
            try w(&out, a, "This is the language's rule for top-level values, whether or not anything else reads the record (ownership-checker.md §31.4).", .{}),
        .read_only => try w(&out, a, "This is the platform's rule for `{s}`, whether or not anything else reads the record.", .{entry_fn}),
        else => if (exact) switch (c) {
            .later_use, .alias, .captured => if (read_line != 0)
                try w(&out, a, "This is sharing the checker can see: {s} is used whole on line {d}, after the change.", .{ holder, read_line })
            else
                try w(&out, a, "This is sharing the checker can see: {s}.", .{try plain(a, d.detail)}),
            .held_operand => try w(&out, a, "This is sharing the checker can see: the value computed first holds the record until the expression uses it.", .{}),
            .disjoint => try w(&out, a, "This is sharing the checker can see: two parts of one operation reach the same record.", .{}),
            else => try w(&out, a, "This is sharing the checker can see: {s}.", .{try plain(a, d.detail)}),
        } else try w(&out, a, "This is a limit of the checker, not proof of sharing: {s}.", .{try plain(a, d.detail)}),
    };
    return out.items;
}

/// The update's line with its base copied (§31.15): `{ Record.copy r | … }`
/// for an update's own base, `(Record.copy r)` for an argument a callee
/// changes. `NoBase` when the base is not written on one line.
fn recordCopyLine(a: Allocator, src: Src, m: u32, d: Demand) error{ NoBase, OutOfMemory }![]const u8 {
    if (d.base_span[0] == none) return error.NoBase;
    const s = src.start(m, d.base_span[0]);
    const e = src.end(m, d.base_span[1]);
    if (s.line != e.line) return error.NoBase;
    const ln = src.line(m, s.line);
    const lo = diagnostic.codePointOffset(ln, s.col - 1);
    const hi = diagnostic.codePointOffset(ln, e.col - 1);
    if (lo >= hi or hi > ln.len) return error.NoBase;
    const base = ln[lo..hi];
    const atom = std.mem.indexOfScalar(u8, base, ' ') == null;
    const arg = if (atom) base else try std.fmt.allocPrint(a, "({s})", .{base});
    // An update's base: `{ base |`, where the call needs no parentheses.
    const in_update = std.mem.endsWith(u8, std.mem.trimEnd(u8, ln[0..lo], " "), "{") and
        std.mem.startsWith(u8, std.mem.trimStart(u8, ln[hi..], " "), "|");
    const enclosed = lo > 0 and hi < ln.len and ln[lo - 1] == '(' and ln[hi] == ')';
    const wrapped = if (in_update or enclosed)
        try std.fmt.allocPrint(a, "Record.copy {s}", .{arg})
    else
        try std.fmt.allocPrint(a, "(Record.copy {s})", .{arg});
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{d}|{s}{s}{s}", .{ s.line, ln[0..lo], wrapped, ln[hi..] });
    return out.items;
}

/// A function value a `need` line is about, as the sentence's subject.
fn functionName(a: Allocator, base: []const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, base, "<lambda>")) return "A lambda";
    if (base.len == 0 or base[0] == '<') return "A function value";
    return std.fmt.allocPrint(a, "`{s}`", .{base});
}

/// A top-level value's name: bare in its own module, qualified in another.
fn topName(a: Allocator, src: Src, m: u32, d: Demand) Allocator.Error![]const u8 {
    const t = d.top orelse return "a top-level value";
    if (t[0] == none) return "a top-level value";
    const name = src.vtable.decl_name(src.ctx, t[0], t[1]);
    if (t[0] == m) return name;
    return std.fmt.allocPrint(a, "{s}.{s}", .{ src.vtable.module_name(src.ctx, t[0]), name });
}

fn placeLess(src: Src, x: Place, y: Place) bool {
    const a = src.start(x.m, x.first);
    const b = src.start(y.m, y.first);
    return a.order(b) == .lt;
}

/// Each place as `N|` and its line, a caret run under it and its label; the
/// numbers right-aligned to the widest.
fn writePlaces(a: Allocator, out: *std.ArrayList(u8), src: Src, m: u32, places: []const Place) Allocator.Error!void {
    var width: usize = 1;
    for (places) |p| width = @max(width, digits(src.start(m, p.first).line));
    var last_line: u32 = 0;
    for (places) |p| {
        const s = src.start(m, p.first);
        const e = src.end(m, p.last);
        const ln = src.line(m, s.line);
        if (s.line != last_line) {
            try padLeft(a, out, s.line, width);
            try out.print(a, "|{s}\n", .{ln});
            last_line = s.line;
        }
        const line_cols = diagnostic.codePoints(ln);
        const carets: usize = if (e.line == s.line and e.col > s.col) e.col - s.col else @max(1, line_cols + 1 -| s.col);
        try out.appendNTimes(a, ' ', width + s.col);
        try out.appendNTimes(a, '^', carets);
        try out.print(a, " {s}\n", .{p.label});
    }
}

fn digits(n: u32) usize {
    var x = n;
    var k: usize = 1;
    while (x >= 10) : (x /= 10) k += 1;
    return k;
}

fn padLeft(a: Allocator, out: *std.ArrayList(u8), n: u32, width: usize) Allocator.Error!void {
    try out.appendNTimes(a, ' ', width - digits(n));
    try out.print(a, "{d}", .{n});
}

/// The edit's line with its base wrapped in `List.copy` (§28.6), as an
/// excerpt line; `NoBase` when the base is not written on one line.
fn copyLine(a: Allocator, src: Src, m: u32, d: Demand) error{ NoBase, OutOfMemory }![]const u8 {
    if (d.base_span[0] == none) return error.NoBase;
    const s = src.start(m, d.base_span[0]);
    const e = src.end(m, d.base_span[1]);
    if (s.line != e.line) return error.NoBase;
    const ln = src.line(m, s.line);
    const lo = diagnostic.codePointOffset(ln, s.col - 1);
    const hi = diagnostic.codePointOffset(ln, e.col - 1);
    if (lo >= hi or hi > ln.len) return error.NoBase;
    const base = ln[lo..hi];
    // `List.copy`'s argument: the base, in parentheses unless it is one
    // name or path. The call itself: bare after a spread and before `++`,
    // in parentheses as an argument.
    const atom = std.mem.indexOfScalar(u8, base, ' ') == null;
    const arg = if (atom) base else try std.fmt.allocPrint(a, "({s})", .{base});
    const spread = std.mem.endsWith(u8, ln[0..lo], "…");
    const left_of_append = std.mem.startsWith(u8, std.mem.trimStart(u8, ln[hi..], " "), "++");
    // A base the line already wraps in parentheses, `(f ⊤)`: they become
    // the call's, so the line does not gain a second pair.
    const enclosed = lo > 0 and hi < ln.len and ln[lo - 1] == '(' and ln[hi] == ')';
    const wrapped = if (spread or left_of_append or enclosed)
        try std.fmt.allocPrint(a, "List.copy {s}", .{arg})
    else
        try std.fmt.allocPrint(a, "(List.copy {s})", .{arg});
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{d}|{s}{s}{s}", .{ s.line, ln[0..lo], wrapped, ln[hi..] });
    return out.items;
}
