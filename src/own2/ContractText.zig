//! L4: a contract's text (`docs/design/ownership-v2.md` §2.10, §3.5): the
//! `summary` line of `beni dump --stage=ownership`, each field in the
//! canonical order the table keeps it in.
//!
//! Obligations kept here: none of §2.14's (text only).

const std = @import("std");
const Ids = @import("Ids.zig");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const Forest = @import("Forest.zig");

const Rel = Contract.Rel;
const Range = Contract.Range;
const Table = Contract.Table;
const Id = Contract.Id;
const StoredCond = Contract.StoredCond;
const none: u32 = Ids.none_int;

/// How a contract's text names a step, a declaration and a field.
pub const Names = struct {
    ctx: *anyopaque,
    field: *const fn (ctx: *anyopaque, rank: u32) []const u8,
};

/// `rel`'s text: `.f`, `.0`, `#c.i`, `[*]`, `⟲`, `◆`, `◇`, `⟨n⟩`; `ε` for none.
pub fn relText(slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, r: Rel) std.Io.Writer.Error!void {
    return wordsText(places, names, w, slots.relWords(r));
}

fn wordsText(places: *const Place.Table, names: Names, w: *std.Io.Writer, words: []const u32) std.Io.Writer.Error!void {
    if (words.len == 0) return w.writeAll("ε");
    for (words) |word| {
        const s = Place.Step.fromWord(word);
        switch (s.kind) {
            .field => try w.print(".{s}", .{names.field(names.ctx, s.payload)}),
            .index => try w.print(".{d}", .{s.payload}),
            .ctor_arg => {
                const ca = places.ctorArgOf(s);
                try w.print("#{d}.{d}", .{ ca[0], ca[1] });
            },
            .elem => try w.writeAll("[*]"),
            .contents => try w.writeAll("◆"),
            .env => try w.writeAll("◇"),
            .slot => try w.print("⟨{d}⟩", .{s.payload}),
            .level => try w.writeAll("⟲"),
        }
    }
}

fn condText(t: *const Table, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, c: StoredCond) std.Io.Writer.Error!void {
    if (c.no) return w.writeAll("no");
    const run = t.occsOf(c);
    if (run.len == 0) return w.writeAll("yes");
    try w.writeAll("⇐ sel");
    var last: u32 = none;
    for (run) |o| {
        if (Contract.occParam(o) != last) {
            if (last != none) try w.writeAll("}");
            try w.print(" π{d}{{", .{Contract.occParam(o) + 1});
            last = Contract.occParam(o);
        } else try w.writeAll(",");
        try relText(slots, places, names, w, Contract.occRel(o));
        if (Contract.isDeep(o)) try w.writeAll("*");
        if (Contract.isApart(o)) try w.writeAll("~");
    }
    try w.writeAll("}");
}

fn effectsText(t: *const Table, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, field: []const u8, r: Range) std.Io.Writer.Error!void {
    if (r.len != 0) try w.writeAll(field);
    for (t.effectsOf(r)) |e| {
        try w.print(" π{d}", .{e.j + 1});
        try relText(slots, places, names, w, e.slot);
        if (e.deep) try w.writeAll("*");
    }
}

/// A result tree's entries in the canonical order; a kid equal to an
/// earlier sibling prints as `.1 = .0` (§2.10 *Text*).
const Res = struct {
    t: *const Table,
    c: Id,
    slots: *const Slots.Table,
    places: *const Place.Table,
    names: Names,
    w: *std.Io.Writer,
    first: bool = true,

    fn entry(ctx: *anyopaque, path: []const u32, open: bool, run: []const Contract.Arrival, as: ?[]const u32) std.Io.Writer.Error!void {
        const r: *Res = @ptrCast(@alignCast(ctx));
        const w = r.w;
        try w.writeAll(if (r.first) " " else ", ");
        r.first = false;
        try wordsText(r.places, r.names, w, path);
        if (as) |o| {
            try w.writeAll(" = ");
            return wordsText(r.places, r.names, w, o);
        }
        if (open) try w.writeAll("…");
        for (run) |a| switch (a.kind) {
            .param => {
                try w.print(" π{d}", .{a.j + 1});
                try relText(r.slots, r.places, r.names, w, a.slot);
                if (a.deep) try w.writeAll("*");
            },
            .fresh => try w.writeAll(" fresh"),
            .shared => try w.writeAll(" shared"),
            .cb => {
                const l = r.t.labelAt(r.c, a.j);
                try w.print(" cb(π{d}", .{l.j + 1});
                try relText(r.slots, r.places, r.names, w, l.slot);
                try w.print("@{d})", .{l.origin[2]});
            },
            .top => try w.writeAll(" ⊤"),
        };
    }
};

fn arrivalsText(t: *const Table, c: Id, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, root: Contract.Node) std.Io.Writer.Error!void {
    var r: Res = .{ .t = t, .c = c, .slots = slots, .places = places, .names = names, .w = w };
    try Forest.text(&t.trees, places, root, &r, Res.entry);
}

/// The contract's text, the dump's `summary` line after its name.
pub fn print(t: *const Table, c: Id, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const h = t.heads.items[c];
    if (h.flags.pessimistic) try w.writeAll("pessimistic; ");
    if (h.flags.cross) try w.writeAll("res crossing") else if (!h.flags.returns) try w.writeAll("res ⊥") else {
        try w.writeAll("res");
        try arrivalsText(t, c, slots, places, names, w, h.res_root);
    }
    try w.writeAll("; nondup ");
    try condText(t, slots, places, names, w, h.res_cond);
    try effectsText(t, slots, places, names, w, "; reads", h.reads);
    try effectsText(t, slots, places, names, w, "; writes", h.writes);
    if (h.writes.len != 0) try w.writeAll("; req ");
    if (h.writes.len != 0) try condText(t, slots, places, names, w, h.req);
    try effectsText(t, slots, places, names, w, "; escapes", h.escapes);
    for (t.labelsOf(h.labels)) |l| {
        try w.print("; label π{d}", .{l.j + 1});
        try relText(slots, places, names, w, l.slot);
        try w.print("@{d} {t}", .{ l.origin[2], l.calls });
        for (t.suppliesOf(l.supplies)) |s| {
            try w.print(" [{d}:", .{s.k + 1});
            try arrivalsText(t, c, slots, places, names, w, s.res_root);
            try effectsText(t, slots, places, names, w, " kept", s.kept);
            try w.writeAll(" sep ");
            try condText(t, slots, places, names, w, s.cond);
            try w.writeAll("]");
        }
    }
    if (h.flags.once) try w.writeAll("; once");
}
