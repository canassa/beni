//! `backend.md` §9's release optimiser, **item 2**: short names, emitted
//! directly. The largest single win in the slice — identifiers are 66.8% of
//! unminified bytes — and the cheapest to state, because `JsIr` names are one
//! column and the printer is the only thing that turns one into bytes. There
//! is no mangler and no second traversal of the tree: this pass decides an
//! ORDINAL per name and `spell` turns an ordinal into at most three bytes.
//!
//! **Two namespaces, and the split is measured** (§9, table F: reusing the
//! alphabet per declaration is worth 4 878 brotli bytes over one flat one).
//!
//!   - **One whole-program namespace for names that cross a file**: every
//!     top-level declaration, every derived function, every synthesised
//!     comparator. They appear in an `import` or an `export` specifier and
//!     the two files must agree, so `Globals` is one table for the BUILD and
//!     both ends read it. A `JsIr.Name` carries a module qualifier exactly
//!     when it is one of these, so no side table says which is which.
//!   - **One namespace per top-level declaration for its locals**:
//!     parameters, `let` `const`s, leaf bindings, `$t$n`, `$p$n`, `$in$<i>`,
//!     `$m$k`, and the `$j$<d>$<b>` / `$c$<d>` / loop labels. The alphabet
//!     restarts in every declaration, skipping only the short names the
//!     globals THIS declaration mentions were given. Labels share the binding
//!     namespace: JavaScript keeps them apart and one table is simpler.
//!
//! **Assignment is in emission order, not frequency order** (§9, and a
//! departure from §9's own list, measured): a name is a function of where the
//! declaration sits in the module body and where the binding sits inside it,
//! both input-derived, so `--jobs=1` and `--jobs=8` agree (CLAUDE.md rule 5).
//! Closure's `RenameVars` gives the reason it also compresses better —
//! symbols declared close together get similar names.
//!
//! **What is NOT renamed, and the list is closed** (§9, `boundary.md` §4):
//! the `imported` half of a sibling specifier, which is the sibling's own
//! export name; `run` in the entry file, which is hand-written JavaScript's;
//! every property name — the `$` tag, the `a`/`b`/`c`… slots, record fields —
//! which is item 4's and the second slice's; and anything inside a
//! `*.foreign.mjs`, which is copied verbatim and never parsed. The printer
//! says which of those a name slot is by the ROLE it passes, so the list is
//! enforced at every call site rather than guessed from the name.
//!
//! **The self-check** is `verify`, in the spirit of `Lower`'s `requireLive`:
//! in a safety build, after each declaration is assigned, no two names in one
//! scope may share a spelling and no spelling may be a reserved word or a
//! host global. A collision here is a `SyntaxError` at load or a silently
//! wrong value in somebody's program, and the whole point of the check is to
//! make it a stopped build with the name in it instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const JsIr = @import("JsIr.zig");
const Print = @import("Print.zig");

const Node = JsIr.Node;
const Index = Node.Index;
const NameIndex = JsIr.NameIndex;

// ---------------------------------------------------------------------------
// The alphabet
// ---------------------------------------------------------------------------

/// The 54 characters a name may start with. `DefaultNameGenerator`'s order,
/// quoted in report 12 §2.2.
const first_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ$_";
/// Those 54 plus the digits, **digits last**: putting them first "would end up
/// balancing the huffman tree" and cost compressed bytes.
const rest_chars = first_chars ++ "0123456789";

/// The spelling of one ordinal. Closure's mixed radix: the first character
/// comes from a 54-letter alphabet and every later one from a 64-character
/// alphabet, with a borrow between them so that nothing is skipped.
pub fn spell(ordinal: u32, buf: *[8]u8) []const u8 {
    var building = ordinal;
    var len: usize = 0;
    buf[len] = first_chars[building % first_chars.len];
    len += 1;
    building /= first_chars.len;
    while (building > 0 and len < buf.len) {
        building -= 1;
        buf[len] = rest_chars[building % rest_chars.len];
        len += 1;
        building /= rest_chars.len;
    }
    return buf[0..len];
}

/// Whether an ordinal's spelling may not be used as a binding.
///
/// `Print.isReservedWord` is the ECMAScript set plus `eval` and `arguments`,
/// which an ES module may not bind because it is always strict. `undefined` is
/// here and not there for a reason: it is not a reserved word, it is a
/// property of the global object, and the emitter DOES write it — §4's
/// unreachable arms lower to `undefined_lit`. A local spelled `undefined`
/// would shadow it and turn `return undefined` into a read of that local.
/// `NaN` and `Infinity` ride along; nothing emits them today and the same
/// argument would apply the day something does.
fn reserved(ordinal: u32) bool {
    var buf: [8]u8 = undefined;
    const text = spell(ordinal, &buf);
    if (Print.isReservedWord(text)) return true;
    for ([_][]const u8{ "undefined", "NaN", "Infinity" }) |global| {
        if (std.mem.eql(u8, global, text)) return true;
    }
    return false;
}

/// The first ordinal at or after `from` whose spelling may be bound.
fn usable(from: u32) u32 {
    var o = from;
    while (reserved(o)) o += 1;
    return o;
}

// ---------------------------------------------------------------------------
// The whole-program namespace
// ---------------------------------------------------------------------------

/// One table for the BUILD, keyed by the `Name` VALUE rather than by a
/// per-module `NameIndex`, because that is the only thing two modules share:
/// `Lower` builds the `import` specifier and the `export` list from the same
/// `Name`, so renaming on this key renames both ends of every edge.
pub const Globals = struct {
    map: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    /// The next ordinal to hand out. A counter and never a hash order, which
    /// is what makes the table deterministic even though it is a hash map.
    next: u32 = 0,

    const Key = struct { module: u32, base: u32, tag: u32 };

    fn key(n: JsIr.Name) Key {
        return .{ .module = @intFromEnum(n.module), .base = @intFromEnum(n.base), .tag = n.tag };
    }

    pub fn deinit(g: *Globals, gpa: Allocator) void {
        g.map.deinit(gpa);
        g.* = undefined;
    }

    /// This name's ordinal, assigning one on first encounter.
    pub fn intern(g: *Globals, gpa: Allocator, n: JsIr.Name) Allocator.Error!u32 {
        const got = try g.map.getOrPut(gpa, key(n));
        if (got.found_existing) return got.value_ptr.*;
        const ordinal = usable(g.next);
        g.next = ordinal + 1;
        got.value_ptr.* = ordinal;
        return ordinal;
    }

    /// This name's ordinal, or null when nothing has assigned one. The entry
    /// file reads it that way: `Emit.emitEntry` writes an `import` by hand and
    /// has to spell `main` the way the module that exports it does.
    pub fn lookup(g: *const Globals, n: JsIr.Name) ?u32 {
        return g.map.get(key(n));
    }
};

// ---------------------------------------------------------------------------
// One module's locals
// ---------------------------------------------------------------------------

/// What a name slot IS, decided at the printer's call site and never inferred
/// from the name. The closed list of §9's "what is NOT renamed" lives here.
pub const Role = enum {
    /// A binding or a reference to one — a declaration's name, a parameter, an
    /// `ident`, a label, an `export` entry, the `local` half of an `import`
    /// specifier. Renamed under `--release`; reserved-escaped in a dev build.
    binding,
    /// A property key, or the `imported` half of a sibling specifier. Never
    /// touched, in either mode.
    fixed,
};

/// What went wrong, for the safety-build self-check. Carried rather than
/// panicked so that `Emit` can report it as an ordinary `internal` diagnostic
/// with the offending name in it.
pub const Failure = struct {
    kind: Kind,
    /// The name the check objected to. `Emit` spells it through the session's
    /// interner, which this type deliberately does not hold.
    name: NameIndex,

    pub const Kind = enum {
        /// Two names in one scope were given one spelling.
        collision,
        /// A generated spelling is a reserved word or a host global.
        reserved,
        /// A reference reached the printer with no assignment behind it.
        unresolved,

        pub fn text(k: Kind) []const u8 {
            return switch (k) {
                .collision => "two names in one scope were given the same short spelling",
                .reserved => "a short spelling is a reserved word or a host global",
                .unresolved => "a reference has no short name behind it",
            };
        }
    };
};

/// The renamer for one module. Created once per module, then driven by the
/// printer one top-level declaration at a time: `enter` assigns that
/// declaration's namespace and `ordinal` reads it back.
pub const Module = struct {
    ir: *const JsIr,
    globals: *Globals,
    gpa: Allocator,
    /// The ordinal assigned to each local `NameIndex`, valid when `stamp`
    /// agrees with `current`. One array for the module and a stamp per
    /// declaration, so restarting the alphabet costs no `@memset`.
    local: []u32,
    stamp: []u32,
    current: u32 = 0,
    /// The locals of the declaration being assigned, in emission order.
    order: std.ArrayList(NameIndex) = .empty,
    /// `collectExpr`'s explicit stack (CK-81), shared by the walks it nests.
    stack: std.ArrayList(Index) = .empty,
    /// The ordinals the globals this declaration mentions were given, as a
    /// bitset over the range a local could possibly be assigned from. A global
    /// above that range cannot collide with a local, so it is not recorded.
    taken: []bool = &.{},
    failure: ?Failure = null,

    pub fn ordinal(m: *const Module, n: NameIndex) ?u32 {
        const name = m.ir.name(n);
        if (name.module != .none) return m.globals.lookup(name);
        const i = n.unwrap() orelse return null;
        if (i >= m.local.len or m.stamp[i] != m.current) return null;
        return m.local[i];
    }

    /// Assign the namespace of one top-level statement of `ir.body`.
    pub fn enter(m: *Module, stmt: Index) Allocator.Error!void {
        m.current += 1;
        m.order.clearRetainingCapacity();
        var mentioned: std.ArrayList(u32) = .empty;
        defer mentioned.deinit(m.gpa);
        try m.collect(stmt, &mentioned);

        // The highest ordinal a local can need is one per local, so a global
        // at or above that bound is out of reach and need not be avoided.
        const bound = m.order.items.len + mentioned.items.len + 1;
        if (m.taken.len < bound) m.taken = try m.gpa.realloc(m.taken, bound);
        @memset(m.taken[0..bound], false);
        for (mentioned.items) |o| {
            if (o < bound) m.taken[o] = true;
        }

        var next: u32 = 0;
        for (m.order.items) |n| {
            while (true) {
                next = usable(next);
                if (next >= bound or !m.taken[next]) break;
                next += 1;
            }
            const i = n.unwrap().?;
            m.local[i] = next;
            m.stamp[i] = m.current;
            next += 1;
        }
        m.verify(mentioned.items);
    }

    /// The safety-build wall. Compiled away outside one (`runtime_safety` is
    /// comptime-known); where it is compiled in it is two linear scans of
    /// lists that hold a declaration's locals and the globals it mentions,
    /// which is the cheapest place to turn "the skip set was wrong" from a
    /// `SyntaxError` in somebody's program into a stopped build.
    fn verify(m: *Module, mentioned: []const u32) void {
        if (!std.debug.runtime_safety) return;
        if (m.failure != null) return;
        for (m.order.items) |n| {
            const i = n.unwrap().?;
            const o = m.local[i];
            if (reserved(o)) {
                m.failure = .{ .kind = .reserved, .name = n };
                return;
            }
            for (mentioned) |g| {
                if (g != o) continue;
                m.failure = .{ .kind = .collision, .name = n };
                return;
            }
        }
        // Distinctness among the locals themselves. `enter` hands out a
        // strictly increasing ordinal so this cannot fire; it is here because
        // "cannot fire" is the claim, and a check is how a claim survives an
        // edit. It checks the stronger claim, that the ordinals INCREASE
        // along `order` (which `see` keeps free of repeats), because that is
        // linear: the all-pairs form was quadratic in a declaration's locals,
        // 46 s of a safety build's `--release` on a derived `compare` with
        // 65 535 `$o$<i>` (CK-81).
        for (m.order.items[0..m.order.items.len -| 1], m.order.items[@min(1, m.order.items.len)..]) |a, b| {
            if (m.local[a.unwrap().?] < m.local[b.unwrap().?]) continue;
            m.failure = .{ .kind = .collision, .name = a };
            return;
        }
    }

    /// Note that a reference reached the printer with nothing behind it.
    pub fn unresolved(m: *Module, n: NameIndex) void {
        if (!std.debug.runtime_safety) return;
        if (m.failure != null) return;
        m.failure = .{ .kind = .unresolved, .name = n };
    }

    // ---- The collecting walk ----------------------------------------------
    //
    // In PRINT order, statement for statement, so that "emission order" is
    // the order the bytes come out in and not an approximation of it. A
    // qualified name is interned into the whole-program table where it is
    // first met; an unqualified one joins this declaration's list.

    fn see(m: *Module, n: NameIndex, mentioned: *std.ArrayList(u32)) Allocator.Error!void {
        const i = n.unwrap() orelse return;
        if (i >= m.local.len) return;
        const name = m.ir.name(n);
        if (name.module != .none) {
            try mentioned.append(m.gpa, try m.globals.intern(m.gpa, name));
            return;
        }
        if (m.stamp[i] == m.current) return; // already in this declaration's list
        m.stamp[i] = m.current;
        m.local[i] = std.math.maxInt(u32); // assigned below; a read before then is a bug
        try m.order.append(m.gpa, n);
    }

    fn collect(m: *Module, stmt: Index, mentioned: *std.ArrayList(u32)) Allocator.Error!void {
        const d = m.ir.data(stmt);
        switch (m.ir.tag(stmt)) {
            .import_stmt => {
                const imp = m.ir.extraData(@enumFromInt(d.lhs), JsIr.Import);
                // Only the `local` half: the `imported` one is the sibling's
                // own export name and may not move (`boundary.md` §4).
                for (m.ir.extraSlice(imp.specs(), JsIr.Specifier)) |spec| try m.see(spec.local, mentioned);
            },
            .export_stmt => for (m.ir.extraSlice(JsIr.inlineRange(d), NameIndex)) |n| try m.see(n, mentioned),
            .const_decl => {
                try m.see(@enumFromInt(d.lhs), mentioned);
                try m.collectExpr(@enumFromInt(d.rhs), mentioned);
            },
            .let_decl => {
                try m.see(@enumFromInt(d.lhs), mentioned);
                if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| try m.collectExpr(v, mentioned);
            },
            .func_decl, .gen_decl => {
                try m.see(@enumFromInt(d.lhs), mentioned);
                try m.collectFunc(@enumFromInt(d.rhs), mentioned);
            },
            .assign_stmt => {
                try m.collectExpr(@enumFromInt(d.lhs), mentioned);
                try m.collectExpr(@enumFromInt(d.rhs), mentioned);
            },
            .return_stmt => if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |v| try m.collectExpr(v, mentioned),
            .if_stmt => {
                try m.collectExpr(@enumFromInt(d.lhs), mentioned);
                const branches = m.ir.extraData(@enumFromInt(d.rhs), JsIr.If);
                try m.collectList(branches.thenBody(), mentioned);
                try m.collectList(branches.elseBody(), mentioned);
            },
            .while_true, .block_stmt => {
                try m.see(@enumFromInt(d.lhs), mentioned);
                try m.collectList(m.ir.subRange(@enumFromInt(d.rhs)), mentioned);
            },
            .break_stmt, .continue_stmt => try m.see(@enumFromInt(d.lhs), mentioned),
            .switch_stmt => {
                try m.collectExpr(@enumFromInt(d.lhs), mentioned);
                for (m.ir.extraSlice(m.ir.subRange(@enumFromInt(d.rhs)), Index)) |c| try m.collect(c, mentioned);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| try m.collectExpr(t, mentioned);
                try m.collectList(m.ir.subRange(@enumFromInt(d.rhs)), mentioned);
            },
            .expr_stmt, .throw_stmt => try m.collectExpr(@enumFromInt(d.lhs), mentioned),
            else => {},
        }
    }

    fn collectList(m: *Module, range: JsIr.SubRange, mentioned: *std.ArrayList(u32)) Allocator.Error!void {
        for (m.ir.extraSlice(range, Index)) |s| try m.collect(s, mentioned);
    }

    fn collectFunc(m: *Module, record: JsIr.ExtraIndex, mentioned: *std.ArrayList(u32)) Allocator.Error!void {
        const f = m.ir.extraData(record, JsIr.Func);
        for (m.ir.extraSlice(f.params(), NameIndex)) |n| try m.see(n, mentioned);
        try m.collectList(f.body(), mentioned);
    }

    /// Iterative, over `stack` (CK-81, `JsIr.pushOperands`), in print order:
    /// an expression is as deep as the longest chain the compiler built. A
    /// `member`'s key and a `property`'s key are PROPERTY names and are item
    /// 4's, not this pass's, so no operand walk yields them.
    fn collectExpr(m: *Module, root: Index, mentioned: *std.ArrayList(u32)) Allocator.Error!void {
        const base = m.stack.items.len;
        defer m.stack.shrinkRetainingCapacity(base);
        try m.stack.append(m.gpa, root);
        while (m.stack.items.len > base) {
            const node = m.stack.pop().?;
            switch (m.ir.tag(node)) {
                .ident => try m.see(@enumFromInt(m.ir.data(node).lhs), mentioned),
                .arrow => try m.collectFunc(@enumFromInt(m.ir.data(node).lhs), mentioned),
                else => try m.ir.pushOperands(m.gpa, &m.stack, node),
            }
        }
    }
};

/// A renamer for one module, allocating from `gpa` (an arena in practice).
pub fn begin(gpa: Allocator, ir: *const JsIr, globals: *Globals) Allocator.Error!Module {
    const local = try gpa.alloc(u32, ir.names.len);
    const stamp = try gpa.alloc(u32, ir.names.len);
    @memset(stamp, 0);
    return .{ .ir = ir, .globals = globals, .gpa = gpa, .local = local, .stamp = stamp };
}

// ---------------------------------------------------------------------------
// Tests
//
// The alphabet and the whole-program table. What a MODULE comes out spelled
// like is `tests/corpus/emit/release/`'s, and that a renamed program still
// computes its answer is the whole `run/` corpus's, built a second time under
// the flag.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the alphabet is 54 first characters and 64 after, digits last" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a", spell(0, &buf));
    try testing.expectEqualStrings("b", spell(1, &buf));
    try testing.expectEqualStrings("z", spell(25, &buf));
    try testing.expectEqualStrings("A", spell(26, &buf));
    try testing.expectEqualStrings("Z", spell(51, &buf));
    try testing.expectEqualStrings("$", spell(52, &buf));
    try testing.expectEqualStrings("_", spell(53, &buf));
    // The roll-over to two characters, and the borrow that keeps it dense.
    try testing.expectEqualStrings("aa", spell(54, &buf));
    try testing.expectEqualStrings("ba", spell(55, &buf));
    try testing.expectEqualStrings("ab", spell(54 + 54, &buf));
}

test "every ordinal has a distinct spelling, over the whole two-character range" {
    // 54 + 54*64 = 3510 one- and two-character names. Uniqueness is the
    // property the whole pass rests on: two names in one scope with one
    // spelling is a wrong value, not a missing byte.
    const count = 54 + 54 * 64;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    var texts: std.ArrayList([]u8) = .empty;
    defer {
        for (texts.items) |t| testing.allocator.free(t);
        texts.deinit(testing.allocator);
    }
    for (0..count) |i| {
        var buf: [8]u8 = undefined;
        const text = spell(@intCast(i), &buf);
        try testing.expect(text.len <= 2);
        const owned = try testing.allocator.dupe(u8, text);
        try texts.append(testing.allocator, owned);
        const got = try seen.getOrPut(testing.allocator, owned);
        try testing.expect(!got.found_existing);
    }
}

test "a reserved word and a host global are never handed out" {
    // `in`, `do` and `if` are two-character names the alphabet would reach;
    // `undefined` is not reserved and is written by the emitter, so a local
    // spelled that way would shadow the value §4's unreachable arms return.
    try testing.expect(reserved(ordinalOf("in")));
    try testing.expect(reserved(ordinalOf("do")));
    try testing.expect(reserved(ordinalOf("if")));
    try testing.expect(!reserved(0));
    var buf: [8]u8 = undefined;
    try testing.expect(!Print.isReservedWord(spell(usable(ordinalOf("in")), &buf)));
}

/// The ordinal whose spelling is `text`, by search — a test convenience, not
/// something the pass needs.
fn ordinalOf(text: []const u8) u32 {
    var i: u32 = 0;
    while (i < 54 + 54 * 64) : (i += 1) {
        var buf: [8]u8 = undefined;
        if (std.mem.eql(u8, spell(i, &buf), text)) return i;
    }
    unreachable;
}

test "the whole-program table hands out ordinals in call order and repeats itself" {
    const gpa = testing.allocator;
    var g: Globals = .{};
    defer g.deinit(gpa);
    const a: JsIr.Name = .{ .module = @enumFromInt(1), .base = @enumFromInt(2), .tag = 0 };
    const b: JsIr.Name = .{ .module = @enumFromInt(1), .base = @enumFromInt(3), .tag = 0 };
    try testing.expectEqual(@as(u32, 0), try g.intern(gpa, a));
    try testing.expectEqual(@as(u32, 1), try g.intern(gpa, b));
    try testing.expectEqual(@as(u32, 0), try g.intern(gpa, a));
    try testing.expectEqual(@as(?u32, 1), g.lookup(b));
    // A name nothing has interned has no ordinal, which is how the entry file
    // learns that the module it imports from never exported one.
    try testing.expectEqual(@as(?u32, null), g.lookup(.{ .module = @enumFromInt(9), .base = @enumFromInt(9), .tag = 0 }));
}
