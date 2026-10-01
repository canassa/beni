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
const Opt = @import("Opt.zig");

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
    // A host global a release build writes by its bare name (`bare_globals`)
    // is never a binding's spelling, so no name in any scope shadows it.
    return isBareGlobal(text);
}

/// The host globals a release build writes without `globalThis.`
/// (`backend.md` §9, *Compact statements*, item 8): `Js.global "document"`
/// is `document`. None is ever an ordinal's spelling (`reserved`), and a
/// scope-hoisted build writes one bare only when no hand-written file binds
/// it as written (`Emit.bareBlocked`).
pub const bare_globals = [_][]const u8{
    "AbortController",    "Array",                "Boolean",               "CustomEvent",
    "Date",               "DocumentFragment",     "Element",               "Error",
    "Event",              "HTMLElement",          "Intl",                  "JSON",
    "Map",                "Math",                 "Node",                  "Number",
    "Object",             "Promise",              "RangeError",            "Reflect",
    "Set",                "String",               "Symbol",                "Text",
    "TypeError",          "URL",                  "URLSearchParams",       "WeakMap",
    "WeakSet",            "cancelAnimationFrame", "clearInterval",         "clearTimeout",
    "console",            "crypto",               "decodeURIComponent",    "document",
    "encodeURIComponent", "fetch",                "getComputedStyle",      "history",
    "isFinite",           "isNaN",                "localStorage",          "location",
    "matchMedia",         "navigator",            "parseFloat",            "parseInt",
    "performance",        "queueMicrotask",       "requestAnimationFrame", "sessionStorage",
    "setInterval",        "setTimeout",           "structuredClone",       "window",
};

pub fn isBareGlobal(text: []const u8) bool {
    // Every ordinal below 3 510 spells one or two characters: the common
    // case asks nothing more.
    if (text.len < 3) return false;
    for (bare_globals) |g| {
        if (std.mem.eql(u8, g, text)) return true;
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
    /// A scope-hoisted build (§9, *One scope-hoisted file under
    /// `--release`*): spellings no ordinal may take, because a hand-written
    /// file in the one scope reads that name without binding it, or binds it
    /// under that spelling itself. Null everywhere else, where the table is
    /// exactly what it always was.
    skip: ?*const Spellings = null,
    /// Ordinals an `internAvoiding` passed over for its own name only, in
    /// ascending order: the next name without that constraint takes the
    /// first of them, so a constraint costs a place in the order and not a
    /// spelling.
    holes: std.ArrayList(u32) = .empty,

    pub const Spellings = std.StringHashMapUnmanaged(void);

    pub const Key = struct { module: u32, base: u32, tag: u32 };

    pub fn key(n: JsIr.Name) Key {
        return .{ .module = @intFromEnum(n.module), .base = @intFromEnum(n.base), .tag = n.tag };
    }

    pub fn deinit(g: *Globals, gpa: Allocator) void {
        g.map.deinit(gpa);
        g.holes.deinit(gpa);
        g.* = undefined;
    }

    /// This name's ordinal, assigning one on first encounter.
    pub fn intern(g: *Globals, gpa: Allocator, n: JsIr.Name) Allocator.Error!u32 {
        return g.internAvoiding(gpa, n, null);
    }

    /// `intern`, where the name may not be spelled like anything in `avoid`:
    /// a hand-written file's top-level binding, which is renamed throughout
    /// its file to this spelling and must not meet a name the file writes
    /// and keeps (§9, *One scope-hoisted file under `--release`*).
    pub fn internAvoiding(g: *Globals, gpa: Allocator, n: JsIr.Name, avoid: ?*const Spellings) Allocator.Error!u32 {
        const got = try g.map.getOrPut(gpa, key(n));
        if (got.found_existing) return got.value_ptr.*;
        var buf: [8]u8 = undefined;
        for (g.holes.items, 0..) |hole, i| {
            if (avoid) |set| if (set.contains(spell(hole, &buf))) continue;
            _ = g.holes.orderedRemove(i);
            got.value_ptr.* = hole;
            return hole;
        }
        while (true) {
            const ordinal = g.usableGlobal(g.next);
            g.next = ordinal + 1;
            if (avoid) |set| if (set.contains(spell(ordinal, &buf))) {
                try g.holes.append(gpa, ordinal);
                continue;
            };
            got.value_ptr.* = ordinal;
            return ordinal;
        }
    }

    /// The first ordinal at or after `from` a whole-program name may take.
    fn usableGlobal(g: *const Globals, from: u32) u32 {
        var o = usable(from);
        const set = g.skip orelse return o;
        var buf: [8]u8 = undefined;
        while (set.contains(spell(o, &buf))) o = usable(o + 1);
        return o;
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
///
/// `globals` is read and never written here: every whole-program name a
/// module mentions has its ordinal before the module is printed
/// (`collectGlobals`, then `Globals.intern` in module order), which is what
/// lets modules print on several threads while they share the table.
pub const Module = struct {
    ir: *const JsIr,
    globals: *const Globals,
    gpa: Allocator,
    /// Set only by `collectGlobals`: the walk then records every
    /// whole-program name in the order it first meets it, and assigns
    /// nothing.
    met: ?*Met = null,
    /// The ordinal assigned to each local `NameIndex`, valid when `stamp`
    /// agrees with `current`. One array for the module and a stamp per
    /// declaration, so restarting the alphabet costs no `@memset`.
    local: []u32,
    stamp: []u32,
    current: u32 = 0,
    /// The locals of the declaration being assigned, in emission order.
    order: std.ArrayList(NameIndex) = .empty,
    /// The scopes of the declaration being assigned, scope 0 the
    /// declaration itself, each after its parent: a function's parameters
    /// and body, a loop's body, a block, a `switch`'s cases. An `if`'s arms
    /// are the scope around them, because the printer may write an arm's
    /// statements into the list around it (`Print.compactIf`).
    scopes: std.ArrayList(Scope) = .empty,
    /// The scope the walk is in.
    scope: u32 = 0,
    /// Per local (valid when `stamp` agrees with `current`): the innermost
    /// scope that holds every place the name is written, its declaration
    /// and every use.
    home: []u32 = &.{},
    /// Every place a local is written, in print order.
    occurs: std.ArrayList(Occurrence) = .empty,
    /// A loop's variable declared just before it (`collectList`), and the
    /// scope its declaration stands in.
    /// Per local (valid when `pulled_stamp` agrees with `current`): a
    /// loop's variable declared just before the loop (`collectList`), and
    /// the scope its declaration stands in.
    pulled_outer: []u32 = &.{},
    pulled_stamp: []u32 = &.{},
    /// `enter`'s, per local: the scope a name was last met in.
    last_scope: []u32 = &.{},
    last_stamp: []u32 = &.{},
    /// The labels of the statements the walk is inside.
    labels: std.ArrayList(u32) = .empty,
    /// `collectExpr`'s explicit stack, shared by the walks it nests.
    stack: std.ArrayList(Index) = .empty,
    /// The ordinals the globals this declaration mentions were given, as a
    /// bitset over the range a local could possibly be assigned from. A global
    /// above that range cannot collide with a local, so it is not recorded.
    taken: []bool = &.{},
    failure: ?Failure = null,

    const Scope = struct { parent: u32, depth: u32 };
    const Occurrence = struct { scope: u32, name: u32 };

    pub fn ordinal(m: *const Module, n: NameIndex) ?u32 {
        const name = m.ir.name(n);
        if (name.module != .none) return m.globals.lookup(name);
        const i = n.unwrap() orelse return null;
        if (i >= m.local.len or m.stamp[i] != m.current) return null;
        return m.local[i];
    }

    /// Assign the namespace of one top-level statement of `ir.body`.
    ///
    /// **A spelling is reused in scopes that cannot see each other**
    /// (`backend.md` §9, item 2, *amended 2026-10-02*): a local's names
    /// are handed out per scope, parent before child, each the lowest
    /// ordinal that no global this declaration mentions has and no name of
    /// an enclosing scope that is USED inside this scope has. A name of an
    /// enclosing scope that is not used inside may be shadowed, which is
    /// how two loops' bodies, two closures and a closure and the function
    /// around it come to share `a`, `b`, `c`… — what a hand minifier writes,
    /// and what brotli matches. Within one scope the order is the order the
    /// printer meets the names, as before (CLAUDE.md rule 5).
    pub fn enter(m: *Module, stmt: Index) Allocator.Error!void {
        m.current += 1;
        m.order.clearRetainingCapacity();
        m.occurs.clearRetainingCapacity();
        m.scopes.clearRetainingCapacity();
        try m.scopes.append(m.gpa, .{ .parent = 0, .depth = 0 });
        m.scope = 0;
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

        const scope_count = m.scopes.items.len;
        // The names each scope holds, bucketed in `order`'s order.
        const homed = try m.bucket(scope_count, m.order.items.len, HomeOf{ .m = m });
        // The names of enclosing scopes each scope uses: every scope from
        // an occurrence up to, not including, the name's home. A name met
        // again in the scope it was last met in adds nothing; any other
        // repeat is harmless, a mark set twice.
        var blocked_pairs: std.ArrayList(Occurrence) = .empty;
        defer blocked_pairs.deinit(m.gpa);
        for (m.occurs.items) |occ| {
            if (m.last_stamp[occ.name] == m.current and m.last_scope[occ.name] == occ.scope) continue;
            m.last_stamp[occ.name] = m.current;
            m.last_scope[occ.name] = occ.scope;
            var s = occ.scope;
            const home = m.home[occ.name];
            while (s != home) {
                try blocked_pairs.append(m.gpa, .{ .scope = s, .name = occ.name });
                s = m.scopes.items[s].parent;
            }
        }
        const blocked = try m.bucket(scope_count, blocked_pairs.items.len, PairOf{ .pairs = blocked_pairs.items });

        const busy = try m.gpa.alloc(bool, bound);
        defer m.gpa.free(busy);
        @memset(busy, false);
        const extra = try m.gpa.alloc(bool, bound);
        defer m.gpa.free(extra);
        @memset(extra, false);
        var pulled_here: std.ArrayList(u32) = .empty;
        defer pulled_here.deinit(m.gpa);
        for (0..scope_count) |s| {
            for (blocked.items(s)) |x| {
                const o = m.local[x];
                if (o < bound) busy[o] = true;
            }
            // A loop's variable whose declaration may stay in the scope
            // around the loop takes no spelling that scope's names have, nor
            // one of the names of enclosing scopes it uses: it is given
            // first, and the loop's other names step around it.
            pulled_here.clearRetainingCapacity();
            const parent = m.scopes.items[s].parent;
            for (homed.items(s)) |i| {
                if (s == 0 or m.pulled_stamp[i] != m.current or m.pulled_outer[i] != parent) continue;
                for (homed.items(parent)) |x| if (m.local[x] < bound) {
                    extra[m.local[x]] = true;
                };
                for (blocked.items(parent)) |x| if (m.local[x] < bound) {
                    extra[m.local[x]] = true;
                };
                var o: u32 = 0;
                while (true) {
                    o = usable(o);
                    if (o >= bound or (!m.taken[o] and !busy[o] and !extra[o])) break;
                    o += 1;
                }
                @memset(extra, false);
                m.local[i] = o;
                if (o < bound) busy[o] = true;
                try pulled_here.append(m.gpa, i);
            }
            var next: u32 = 0;
            for (homed.items(s)) |i| {
                if (std.mem.indexOfScalar(u32, pulled_here.items, i) != null) continue;
                while (true) {
                    next = usable(next);
                    if (next >= bound or (!m.taken[next] and !busy[next])) break;
                    next += 1;
                }
                m.local[i] = next;
                next += 1;
            }
            for (pulled_here.items) |i| if (m.local[i] < bound) {
                busy[m.local[i]] = false;
            };
            for (blocked.items(s)) |x| {
                const o = m.local[x];
                if (o < bound) busy[o] = false;
            }
        }
        m.verify(mentioned.items, homed, blocked, busy);
    }

    /// Items bucketed by scope, each bucket in the items' order.
    const Buckets = struct {
        start: []u32,
        flat: []u32,

        fn items(b: Buckets, s: usize) []const u32 {
            return b.flat[b.start[s]..b.start[s + 1]];
        }
    };

    const HomeOf = struct {
        m: *const Module,
        fn at(h: HomeOf, k: usize) Occurrence {
            const i = h.m.order.items[k].unwrap().?;
            return .{ .scope = h.m.home[i], .name = i };
        }
    };

    const PairOf = struct {
        pairs: []const Occurrence,
        fn at(p: PairOf, k: usize) Occurrence {
            return p.pairs[k];
        }
    };

    /// A counting sort of `count` (scope, name) items by scope.
    fn bucket(m: *Module, scope_count: usize, count: usize, source: anytype) Allocator.Error!Buckets {
        const start = try m.gpa.alloc(u32, scope_count + 1);
        @memset(start, 0);
        for (0..count) |k| start[source.at(k).scope + 1] += 1;
        for (1..start.len) |s| start[s] += start[s - 1];
        const fill = try m.gpa.dupe(u32, start[0..scope_count]);
        defer m.gpa.free(fill);
        const flat = try m.gpa.alloc(u32, count);
        for (0..count) |k| {
            const item = source.at(k);
            flat[fill[item.scope]] = item.name;
            fill[item.scope] += 1;
        }
        return .{ .start = start, .flat = flat };
    }

    /// The innermost scope holding both `a` and `b`.
    fn common(m: *const Module, a: u32, b: u32) u32 {
        var x = a;
        var y = b;
        while (m.scopes.items[x].depth > m.scopes.items[y].depth) x = m.scopes.items[x].parent;
        while (m.scopes.items[y].depth > m.scopes.items[x].depth) y = m.scopes.items[y].parent;
        while (x != y) {
            x = m.scopes.items[x].parent;
            y = m.scopes.items[y].parent;
        }
        return x;
    }

    /// Walk into a scope of its own; `leave` with what this returned.
    fn push(m: *Module) Allocator.Error!u32 {
        const saved = m.scope;
        if (m.met != null) return saved;
        const depth = m.scopes.items[saved].depth + 1;
        m.scope = @intCast(m.scopes.items.len);
        try m.scopes.append(m.gpa, .{ .parent = saved, .depth = depth });
        for (m.labels.items) |label| try m.occurs.append(m.gpa, .{ .scope = m.scope, .name = label });
        return saved;
    }

    fn leave(m: *Module, saved: u32) void {
        m.scope = saved;
    }

    /// The safety-build wall. Compiled away outside one (`runtime_safety` is
    /// comptime-known); where it is compiled in it is linear scans of the
    /// lists `enter` built, which is the cheapest place to turn "the skip
    /// set was wrong" from a `SyntaxError` in somebody's program into a
    /// stopped build. `busy` is `enter`'s, all false.
    fn verify(m: *Module, mentioned: []const u32, homed: Buckets, blocked: Buckets, busy: []bool) void {
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
        // Within a scope the ordinals are distinct, and none is the ordinal
        // of a name of an enclosing scope that the scope uses: one mark per
        // name, linear, where the all-pairs form was 46 s of a safety
        // build's `--release` on a derived `compare` with 65 535 `$o$<i>`.
        // "Cannot fire" is `enter`'s claim; a check is how a claim survives
        // an edit. (Every ordinal is below `busy.len`: `enter` hands out at
        // most one per name and global.)
        for (0..m.scopes.items.len) |s| {
            const names = homed.items(s);
            defer for (names) |i| {
                if (m.local[i] < busy.len) busy[m.local[i]] = false;
            };
            for (names) |i| {
                const o = m.local[i];
                if (o >= busy.len) continue;
                if (busy[o]) {
                    m.failure = .{ .kind = .collision, .name = @enumFromInt(i) };
                    return;
                }
                busy[o] = true;
            }
            for (blocked.items(s)) |x| {
                if (m.local[x] >= busy.len or !busy[m.local[x]]) continue;
                m.failure = .{ .kind = .collision, .name = @enumFromInt(x) };
                return;
            }
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
        if (i >= m.ir.names.len) return;
        const name = m.ir.name(n);
        if (name.module != .none) {
            if (m.met) |met| return met.see(m.gpa, n);
            const o = m.globals.lookup(name) orelse return m.unresolved(n);
            try mentioned.append(m.gpa, o);
            return;
        }
        if (m.met != null) return;
        try m.occurs.append(m.gpa, .{ .scope = m.scope, .name = i });
        if (m.stamp[i] == m.current) {
            // Already in this declaration's list: its home widens to hold
            // this place too.
            m.home[i] = m.common(m.home[i], m.scope);
            return;
        }
        m.stamp[i] = m.current;
        m.local[i] = std.math.maxInt(u32); // assigned below; a read before then is a bug
        m.home[i] = m.scope;
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
                const label: NameIndex = @enumFromInt(d.lhs);
                try m.see(label, mentioned);
                // A label may not be declared again inside its own
                // statement: every scope there uses it (`push`).
                const labelled = m.met == null and label.unwrap() != null and m.ir.name(label).module == .none;
                if (labelled) try m.labels.append(m.gpa, label.unwrap().?);
                defer if (labelled) {
                    _ = m.labels.pop();
                };
                const saved = try m.push();
                defer m.leave(saved);
                try m.collectList(m.ir.subRange(@enumFromInt(d.rhs)), mentioned);
            },
            .for_of => {
                const f = m.ir.extraData(@enumFromInt(d.rhs), JsIr.ForOf);
                // The iterable is in the scope of the head's `let`: `for(let
                // a of a)` reads the new `a`, before it is initialised.
                const saved = try m.push();
                defer m.leave(saved);
                try m.see(@enumFromInt(d.lhs), mentioned);
                try m.collectExpr(f.iterable, mentioned);
                try m.collectList(f.body(), mentioned);
            },
            .break_stmt, .continue_stmt => try m.see(@enumFromInt(d.lhs), mentioned),
            .switch_stmt => {
                try m.collectExpr(@enumFromInt(d.lhs), mentioned);
                const saved = try m.push();
                defer m.leave(saved);
                for (m.ir.extraSlice(m.ir.subRange(@enumFromInt(d.rhs)), Index)) |c| try m.collect(c, mentioned);
            },
            .switch_case => {
                if (@as(Node.OptionalIndex, @enumFromInt(d.lhs)).unwrap()) |t| try m.collectExpr(t, mentioned);
                try m.collectList(m.ir.subRange(@enumFromInt(d.rhs)), mentioned);
            },
            .expr_stmt, .throw_stmt => try m.collectExpr(@enumFromInt(d.lhs), mentioned),
            // Each block is always braced, so each is a scope of its own.
            .try_stmt => {
                const t = m.ir.extraData(@enumFromInt(d.rhs), JsIr.Try);
                {
                    const saved = try m.push();
                    defer m.leave(saved);
                    try m.collectList(t.body(), mentioned);
                }
                const saved = try m.push();
                defer m.leave(saved);
                try m.collectList(t.finalBody(), mentioned);
            },
            else => {},
        }
    }

    fn collectList(m: *Module, range: JsIr.SubRange, mentioned: *std.ArrayList(u32)) Allocator.Error!void {
        const list = m.ir.extraSlice(range, Index);
        var i: usize = 0;
        while (i < list.len) : (i += 1) {
            // `let n=a;` just before an unlabelled loop: `n` is the loop's,
            // since the printer may write it in the loop's `for` head
            // (`Print.forHead`) — but it is given no spelling the scope
            // around the loop has, nor one of the names of enclosing scopes
            // that scope uses, since the printer may as well leave it where
            // it is (`pulled_outer`). `a` is evaluated where it stands.
            if (m.met == null and i + 1 < list.len and m.ir.tag(list[i]) == .let_decl and
                m.ir.tag(list[i + 1]) == .while_true and
                @as(NameIndex, @enumFromInt(m.ir.data(list[i + 1]).lhs)) == .none)
            {
                const d = m.ir.data(list[i]);
                const n: NameIndex = @enumFromInt(d.lhs);
                if (n.unwrap()) |index| if (index < m.ir.names.len and m.ir.name(n).module == .none) {
                    if (@as(Node.OptionalIndex, @enumFromInt(d.rhs)).unwrap()) |v| try m.collectExpr(v, mentioned);
                    const saved = try m.push();
                    defer m.leave(saved);
                    try m.see(n, mentioned);
                    m.pulled_stamp[index] = m.current;
                    m.pulled_outer[index] = saved;
                    try m.collectList(m.ir.subRange(@enumFromInt(m.ir.data(list[i + 1]).rhs)), mentioned);
                    i += 1;
                    continue;
                };
            }
            try m.collect(list[i], mentioned);
        }
    }

    fn collectFunc(m: *Module, record: JsIr.ExtraIndex, mentioned: *std.ArrayList(u32)) Allocator.Error!void {
        const f = m.ir.extraData(record, JsIr.Func);
        // The parameters and the body are one scope: a body's `let` may not
        // take a parameter's name.
        const saved = try m.push();
        defer m.leave(saved);
        for (m.ir.extraSlice(f.params(), NameIndex)) |n| try m.see(n, mentioned);
        try m.collectList(f.body(), mentioned);
    }

    /// Iterative, over `stack` (`JsIr.pushOperands`), in print order:
    /// an expression is as deep as the longest chain the compiler built. A
    /// `member`'s key and a `property`'s key are PROPERTY names and are item
    /// 4's, not this pass's, so no operand walk yields them.
    fn collectExpr(m: *Module, root: Index, mentioned: *std.ArrayList(u32)) Allocator.Error!void {
        const base = m.stack.items.len;
        defer m.stack.shrinkRetainingCapacity(base);
        try m.stack.append(m.gpa, root);
        while (m.stack.items.len > base) {
            const node = JsIr.popOperand(&m.stack).?;
            switch (m.ir.tag(node)) {
                .ident => try m.see(@enumFromInt(m.ir.data(node).lhs), mentioned),
                .arrow => try m.collectFunc(@enumFromInt(m.ir.data(node).lhs), mentioned),
                else => try m.ir.pushOperands(m.gpa, &m.stack, node),
            }
        }
    }
};

/// A renamer for one module. Its own lists come from `gpa`, an arena reset
/// after the module. Every whole-program name the module mentions must
/// already be in `globals`; one that is not is reported as `unresolved`.
pub fn begin(gpa: Allocator, ir: *const JsIr, globals: *const Globals) Allocator.Error!Module {
    const local = try gpa.alloc(u32, ir.names.len);
    const stamp = try gpa.alloc(u32, ir.names.len);
    @memset(stamp, 0);
    const home = try gpa.alloc(u32, ir.names.len);
    const pulled_outer = try gpa.alloc(u32, ir.names.len);
    const pulled_stamp = try gpa.alloc(u32, ir.names.len);
    @memset(pulled_stamp, 0);
    const last_scope = try gpa.alloc(u32, ir.names.len);
    const last_stamp = try gpa.alloc(u32, ir.names.len);
    @memset(last_stamp, 0);
    return .{
        .ir = ir,
        .globals = globals,
        .gpa = gpa,
        .local = local,
        .stamp = stamp,
        .home = home,
        .pulled_outer = pulled_outer,
        .pulled_stamp = pulled_stamp,
        .last_scope = last_scope,
        .last_stamp = last_stamp,
    };
}

/// The whole-program names one module mentions, each once, in the order the
/// printer meets them. Handing each module's list to `Globals.intern`, one
/// module after another in module order, numbers the table exactly as
/// printing the modules one after another would — so no name depends on
/// which thread printed which module, or when (CLAUDE.md rule 5).
///
/// `plan` is the one the module is printed under: a statement it drops is
/// never printed, so its names are not met here either. The list comes from
/// `gpa`, an arena, as the walk's own lists do.
pub fn collectGlobals(gpa: Allocator, ir: *const JsIr, plan: *const Opt.Plan) Allocator.Error![]const NameIndex {
    const empty: Globals = .{};
    var met: Met = .{ .seen = try .initEmpty(gpa, ir.names.len) };
    var m: Module = .{ .ir = ir, .globals = &empty, .gpa = gpa, .local = &.{}, .stamp = &.{}, .met = &met };
    var unused: std.ArrayList(u32) = .empty;
    for (ir.extraSlice(ir.body, Index)) |stmt| {
        if (plan.isDropped(stmt)) continue;
        try m.collect(stmt, &unused);
    }
    return met.order.items;
}

/// What `collectGlobals` records: whole-program names by first encounter.
/// A module's names are distinct by value (`JsIr.Builder.intern`), so a
/// name's index is its identity and a bit per index is the seen set.
const Met = struct {
    seen: std.DynamicBitSetUnmanaged,
    order: std.ArrayList(NameIndex) = .empty,

    fn see(met: *Met, gpa: Allocator, n: NameIndex) Allocator.Error!void {
        if (met.seen.isSet(n.int())) return;
        met.seen.set(n.int());
        try met.order.append(gpa, n);
    }
};

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

test "a module's whole-program names are collected once each, in print order, skipping dropped statements" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var b: JsIr.Builder = .init(gpa);
    const module: JsIr.Symbol = @enumFromInt(1);
    const f = try b.intern(.qualified(module, @enumFromInt(10)));
    const g = try b.intern(.qualified(module, @enumFromInt(11)));
    const h = try b.intern(.qualified(module, @enumFromInt(12)));
    const x = try b.intern(.local(@enumFromInt(20)));
    // `const f = g;`, `const h = x;` (a local, never collected), then
    // `const x = f;` — `f` again, which is not collected twice.
    const s1 = try testNode(&b, .const_decl, f.int(), (try testNode(&b, .ident, g.int(), 0)).int());
    const s2 = try testNode(&b, .const_decl, h.int(), (try testNode(&b, .ident, x.int(), 0)).int());
    const s3 = try testNode(&b, .const_decl, x.int(), (try testNode(&b, .ident, f.int(), 0)).int());
    const ir = try b.toOwned(try b.addRange(&.{ s1, s2, s3 }));

    try testing.expectEqualSlices(NameIndex, &.{ f, g, h }, try collectGlobals(gpa, &ir, &Opt.Plan.none));

    // A statement the plan drops is never printed, so its names are not met.
    const dropped = try gpa.alloc(u32, (ir.nodes.len + 31) / 32);
    @memset(dropped, 0);
    dropped[s2.int() / 32] |= @as(u32, 1) << @intCast(s2.int() % 32);
    const plan: Opt.Plan = .{ .dropped = dropped };
    const met = try collectGlobals(gpa, &ir, &plan);
    try testing.expectEqualSlices(NameIndex, &.{ f, g }, met);

    // Numbered in that order, the renamer finds every name it meets.
    var globals: Globals = .{};
    for (met) |n| _ = try globals.intern(gpa, ir.name(n));
    var m = try begin(gpa, &ir, &globals);
    try m.enter(s1);
    try testing.expectEqual(@as(?Failure, null), m.failure);
    try testing.expectEqual(@as(?u32, 0), m.ordinal(f));
    try testing.expectEqual(@as(?u32, 1), m.ordinal(g));
}

const small_stack = @import("../small_stack.zig");

/// Twice the depth a walk that recursed once per link fails at on
/// `small_stack.size`: a `collectExpr` that recursed into each `&&`'s
/// operands finished 2 000 links on the Debug test binary and overflowed at
/// 5 000.
const deep_chain = 10_000;

test "a function returning a && chain deeper than a recursive walk survives is named down to its deepest link" {
    // A derived `eq` is one left-nested `&&` as long as its record is wide.
    // The collecting walk keeps its own stack (`JsIr.pushOperands`), so
    // the names are assigned on `small_stack`'s few pages. The one local
    // that only the chain's deepest link reads is the second name met in
    // the function's scope — after its parameter, which may take the
    // function's own spelling since the body never names the function — so
    // it is given ordinal 1 only if the walk reached the bottom first.
    try small_stack.run(nameDeepChain, .{});
}

/// `function f(a) { return z && a && … && a; }`.
fn nameDeepChain() !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var b: JsIr.Builder = .init(gpa);
    const f = try b.intern(.local(@enumFromInt(0)));
    const a = try b.intern(.local(@enumFromInt(1)));
    const z = try b.intern(.local(@enumFromInt(2)));
    var chain = try testNode(&b, .ident, z.int(), 0);
    for (1..deep_chain) |_| {
        const operand = try testNode(&b, .ident, a.int(), 0);
        const pair = try b.addRecord(JsIr.Binary{ .left = chain, .right = operand });
        chain = try testNode(&b, .binary, @intFromEnum(pair), @intFromEnum(JsIr.BinaryOp.logical_and));
    }
    const decl = try testFunc(&b, f, a, &.{try testNode(&b, .return_stmt, chain.int(), 0)});
    const ir = try b.toOwned(try b.addRange(&.{decl}));

    var globals: Globals = .{};
    var m = try begin(gpa, &ir, &globals);
    try m.enter(decl);
    try testing.expectEqual(@as(?Failure, null), m.failure);
    try testing.expectEqual(@as(?u32, 0), m.ordinal(f));
    try testing.expectEqual(@as(?u32, 0), m.ordinal(a));
    try testing.expectEqual(@as(?u32, 1), m.ordinal(z));
}

test "a declaration of 16 384 locals is named and self-checked in linear time" {
    // A derived `compare` binds one `$o$<i>` per position of its record, so
    // one declaration holds as many locals as the widest record has
    // fields, up to 65 535. The safety-build self-check once compared every
    // pair of them, 46 s of a `--release` build at that width; it compares
    // neighbours now. A quarter of the width is enough to tell the two
    // apart: the all-pairs check takes this test far past the test CPU
    // budget, the neighbour check a small part of it.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const width = 16_384;
    var b: JsIr.Builder = .init(gpa);
    const f = try b.intern(.local(@enumFromInt(0)));
    const a = try b.intern(.local(@enumFromInt(1)));
    const locals = try gpa.alloc(NameIndex, width);
    const stmts = try gpa.alloc(Index, width);
    for (locals, stmts, 0..) |*local, *stmt, i| {
        local.* = try b.intern(.local(@enumFromInt(2 + i)));
        stmt.* = try testNode(&b, .const_decl, local.int(), (try testNode(&b, .ident, a.int(), 0)).int());
    }
    const decl = try testFunc(&b, f, a, stmts);
    const ir = try b.toOwned(try b.addRange(&.{decl}));

    var globals: Globals = .{};
    var m = try begin(gpa, &ir, &globals);
    try m.enter(decl);
    try testing.expectEqual(@as(?Failure, null), m.failure);
    try testing.expectEqual(@as(?u32, 1), m.ordinal(locals[0]));
    for (locals[0 .. width - 1], locals[1..]) |earlier, later| {
        try testing.expect(m.ordinal(earlier).? < m.ordinal(later).?);
    }
}

test "a loop's body reuses a spelling of the scope around it that it does not use, and no other" {
    // `function f(a) { const x2 = a; for (;;) { const x = a; } for (;;) {
    // const y = x2; } }`: the first body uses `a`, so `x` takes `x2`'s
    // spelling, which that body never reads; the second uses `x2`, so `y`
    // takes `a`'s.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var b: JsIr.Builder = .init(gpa);
    const f = try b.intern(.local(@enumFromInt(0)));
    const a = try b.intern(.local(@enumFromInt(1)));
    const x = try b.intern(.local(@enumFromInt(2)));
    const y = try b.intern(.local(@enumFromInt(3)));
    const x2 = try b.intern(.local(@enumFromInt(4)));
    const none = @intFromEnum(NameIndex.none);
    const decl_x2 = try testNode(&b, .const_decl, x2.int(), (try testNode(&b, .ident, a.int(), 0)).int());
    const first = try b.addRecord(try b.addRange(&.{try testNode(&b, .const_decl, x.int(), (try testNode(&b, .ident, a.int(), 0)).int())}));
    const second = try b.addRecord(try b.addRange(&.{try testNode(&b, .const_decl, y.int(), (try testNode(&b, .ident, x2.int(), 0)).int())}));
    const loop1 = try testNode(&b, .while_true, none, @intFromEnum(first));
    const loop2 = try testNode(&b, .while_true, none, @intFromEnum(second));
    const decl = try testFunc(&b, f, a, &.{ decl_x2, loop1, loop2 });
    const ir = try b.toOwned(try b.addRange(&.{decl}));

    var globals: Globals = .{};
    var m = try begin(gpa, &ir, &globals);
    try m.enter(decl);
    try testing.expectEqual(@as(?Failure, null), m.failure);
    // The function's scope: `a`, then `x2`.
    try testing.expectEqual(@as(?u32, 0), m.ordinal(a));
    try testing.expectEqual(@as(?u32, 1), m.ordinal(x2));
    // The first body uses `a`: `x` steps over it, onto `x2`'s spelling.
    try testing.expectEqual(@as(?u32, 1), m.ordinal(x));
    // The second uses `x2`: `y` takes `a`'s, which it does not use.
    try testing.expectEqual(@as(?u32, 0), m.ordinal(y));
}

fn testNode(b: *JsIr.Builder, tag: Node.Tag, lhs: u32, rhs: u32) !Index {
    return b.addNode(.{ .tag = tag, .pos = Node.no_pos, .data = .{ .lhs = lhs, .rhs = rhs } });
}

/// `function <name>(<param>) { <body> }`.
fn testFunc(b: *JsIr.Builder, name: NameIndex, param: NameIndex, body: []const Index) !Index {
    const params = try b.addNames(&.{param});
    const stmts = try b.addRange(body);
    const func = try b.addRecord(JsIr.Func{
        .params_start = params.start,
        .params_end = params.end,
        .body_start = stmts.start,
        .body_end = stmts.end,
    });
    return testNode(b, .func_decl, name.int(), @intFromEnum(func));
}
