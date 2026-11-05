//! L4: a contract's text (`docs/design/ownership-v2.md` §2.10, §3.5): the `summary` line of
//! `beni dump --stage=ownership`, each field in canonical order. Obligations kept here: none (text).
const std = @import("std");
const Place = @import("Place.zig");
const Slots = @import("Slots.zig");
const Contract = @import("Contract.zig");
const AnsOcc = @import("AnsOcc.zig");
const Forest = @import("Forest.zig");

const Table = Contract.Table;
const Id = Contract.Id;

/// How a contract's text names a field.
pub const Names = struct {
    ctx: *anyopaque,
    field: *const fn (ctx: *anyopaque, rank: u32) []const u8,
};

/// `rel`'s text: `.f`, `.0`, `#c.i`, `[*]`, `⟲`, `◆`, `◇`, `⟨n⟩`; `ε` for none.
pub fn relText(slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, r: Contract.Rel) std.Io.Writer.Error!void {
    return wordsText(places, names, w, slots.relWords(r));
}

fn wordsText(places: *const Place.Table, names: Names, w: *std.Io.Writer, words: []const u32) std.Io.Writer.Error!void {
    if (words.len == 0) return w.writeAll("ε");
    for (words) |word| {
        const s = Place.Step.fromWord(word);
        switch (s.kind) {
            .field => try w.print(".{s}", .{names.field(names.ctx, s.payload)}),
            .index => try w.print(".{d}", .{s.payload}),
            .ctor_arg => try w.print("#{d}.{d}", .{ places.ctorArgOf(s)[0], places.ctorArgOf(s)[1] }),
            .elem => try w.writeAll("[*]"),
            .contents => try w.writeAll("◆"),
            .env => try w.writeAll("◇"),
            .slot => try w.print("⟨{d}⟩", .{s.payload}),
            .level => try w.writeAll("⟲"),
        }
    }
}

fn condText(t: *const Table, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, field: []const u8, c: Contract.StoredCond) std.Io.Writer.Error!void {
    try w.writeAll(field);
    if (c.no) return w.writeAll("no");
    const run = t.occsOf(c);
    if (run.len == 0) return w.writeAll("yes");
    try w.writeAll("⇐ sel");
    var last: u32 = std.math.maxInt(u32);
    for (run) |o| {
        const j = if (Contract.isFed(o)) Contract.fedParam(o) else Contract.occParam(o);
        if (j != last) {
            if (last != std.math.maxInt(u32)) try w.writeAll("}");
            try w.print(" π{d}{{", .{j + 1});
            last = j;
        } else try w.writeAll(",");
        try relText(slots, places, names, w, Contract.occRel(o));
        if (Contract.isDeep(o)) try w.writeAll("*");
        if (Contract.isApart(o)) try w.writeAll("~");
        if (Contract.isFed(o)) try AnsOcc.text(w, o);
    }
    try w.writeAll("}");
}

fn effectsText(t: *const Table, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, field: []const u8, r: Contract.Range) std.Io.Writer.Error!void {
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
    eff: ?u32 = null, // reads (an effect tree) of this parameter, not arrivals

    fn entry(ctx: *anyopaque, path: []const u32, open: bool, run: []const Contract.Arrival, as: ?[]const u32) std.Io.Writer.Error!void {
        const r: *Res = @ptrCast(@alignCast(ctx));
        const w = r.w;
        if (r.eff) |j| {
            try w.print(" π{d}", .{j + 1});
            try wordsText(r.places, r.names, w, path);
            if (as != null) try w.print(" = π{d}", .{j + 1});
            return if (as) |o| wordsText(r.places, r.names, w, o) else if (open) w.writeAll("*");
        }
        try w.writeAll(if (r.first) " " else ", ");
        r.first = false;
        try wordsText(r.places, r.names, w, path);
        if (as) |o| {
            try w.writeAll(" = ");
            return wordsText(r.places, r.names, w, o);
        }
        if (open) try w.writeAll("…");
        for (run) |a| switch (a.kind) {
            .param, .lent => {
                try w.print(" {s}π{d}", .{ if (a.kind == .lent) "lent " else "", a.j + 1 });
                try relText(r.slots, r.places, r.names, w, a.slot);
                if (a.deep) try w.writeAll("*");
            },
            .fresh => try w.writeAll(" fresh"),
            .shared => try w.writeAll(" shared"),
            .cb => {
                const l = r.t.labelAt(r.c, a.j);
                try w.print(" cb(π{d}", .{l.j + 1});
                try relText(r.slots, r.places, r.names, w, l.slot);
                try w.print("@{d})", .{l.origin[2] & ~Contract.last_origin});
            },
            .top => try w.writeAll(" ⊤"),
            .host => try w.writeAll(" host"),
        };
    }
};

fn arrivalsText(t: *const Table, gpa: std.mem.Allocator, c: Id, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer, root: Contract.Node, eff: ?u32, twins: bool) std.Io.Writer.Error!void {
    var r: Res = .{ .t = t, .c = c, .slots = slots, .places = places, .names = names, .w = w, .eff = eff };
    try Forest.text(&t.trees, gpa, places, root, &r, Res.entry, twins);
}

/// The contract's text, the dump's `summary` line after its name.
pub fn print(t: *const Table, gpa: std.mem.Allocator, c: Id, slots: *const Slots.Table, places: *const Place.Table, names: Names, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const h = t.heads.items[c];
    if (h.flags.pessimistic) try w.writeAll("pessimistic; ");
    if (h.flags.cross) try w.writeAll("res crossing") else if (!h.flags.returns) try w.writeAll("res ⊥") else {
        try w.writeAll("res");
        try arrivalsText(t, gpa, c, slots, places, names, w, h.res_root, null, true);
    }
    for ([_]Contract.StoredCond{ h.res_cond, h.res_read }, [_][]const u8{ "; nondup ", "; answers " }) |x, n| if (n[2] == 'n' or !x.no) try condText(t, slots, places, names, w, n, x);
    if (h.reads.len != 0) try w.writeAll("; reads");
    for (t.readsOf(h.reads)) |x| try arrivalsText(t, gpa, c, slots, places, names, w, x[1], x[0], true);
    if (h.writes.len != 0) try w.writeAll("; writes");
    for (t.writesOf(h.writes)) |x| try arrivalsText(t, gpa, c, slots, places, names, w, x[1], x[0], false);
    if (h.writes.len != 0) try condText(t, slots, places, names, w, "; req ", h.req);
    try effectsText(t, slots, places, names, w, "; escapes", h.escapes);
    for (t.storesOf(h.stores)) |s| {
        try w.print("; stores π{d}", .{s.j + 1});
        try relText(slots, places, names, w, s.slot);
        try condText(t, slots, places, names, w, " ", s.cond);
    }
    for (t.labelsOf(h.labels)) |l| {
        try w.print("; label π{d}", .{l.j + 1});
        try relText(slots, places, names, w, l.slot);
        try w.print("@{d} {t}", .{ l.origin[2] & ~Contract.last_origin, l.calls });
        for (t.suppliesOf(l.supplies)) |s| {
            try w.print(" [{d}{s}:", .{ s.k + 1, if (s.walk) " walk" else if (s.each) " each" else "" });
            try arrivalsText(t, gpa, c, slots, places, names, w, s.res_root, null, true);
            try effectsText(t, slots, places, names, w, " kept", s.kept);
            try condText(t, slots, places, names, w, " sep ", s.cond);
            try condText(t, slots, places, names, w, " below ", s.below);
            try w.writeAll("]");
        }
    }
    if (h.flags.once) try w.writeAll("; once");
}
