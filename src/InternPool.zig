//! Identifier interning (docs/design/frontend.md §3.3, fast-compiler.md §5.1).
//!
//! Every identifier-like token is interned while it is scanned: the
//! tokenizer feeds bytes to a `Hasher` as it consumes them and then calls
//! `Local.getOrPutHashed` with the finished hash, so no identifier is hashed
//! twice. A `Symbol` is an index into the pool that produced it; equality of
//! two symbols from the SAME pool is an integer compare.
//!
//! Two pools exist because a single shared interner serialises exactly the
//! phase being parallelised (oxc lost ~30% to that, research/03). Each worker
//! interns into its own `Local`; after the parallel phase the driver walks
//! the FILES in index order (sorted path order) and calls `Global.mergeOne`
//! for each symbol a file's tokens and Bir reference, then `mergeRest` for
//! the ones none does, by text. That fills each worker's remap table
//! `local symbol → global symbol`, which it then applies to its token
//! payloads and Bir references. A global id is therefore a function of the
//! input alone (`fast-compiler.md` §10): it used to be `Global.merge` per
//! worker in worker index order, which numbered a symbol by which worker
//! the `next_file` race handed its file to, and the first choice made by id
//! that reached an output — `unifyRecord`'s — varied between identical runs.
//! Ids are still not a stable ORDER for anything a user sees: they
//! shift with every edit to an earlier file, so a user-visible choice goes
//! by text.
//!
//! `Global` is thread-confined to that merge step. Sharding it for
//! concurrent lookups (Zig's `InternPool` encoding with the thread id in the
//! high bits) is daemon work and is deliberately not started here.
//!
//! Hash: an FxHash-style multiply-xor, one multiply per byte, because the
//! tokenizer feeds bytes one at a time as it scans and identifiers are short.
//! Measured against `std.hash.Wyhash` streamed byte by byte, on the
//! generated 100k-line corpus (ReleaseFast, best of 5, single thread, lex
//! phase including interning): see `hasher_kind` for the numbers. Both forms
//! are kept behind that comptime switch so the measurement can be repeated
//! when the identifier mix changes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Symbol = enum(u32) {
    _,

    pub fn toOptional(s: Symbol) Optional {
        return @enumFromInt(@intFromEnum(s));
    }

    /// A hash map keyed by symbol, hashed by one multiplication. `std`'s
    /// `AutoContext` runs Wyhash over the key's four bytes, and on a record
    /// of 65 537 fields its per-field lookups were a tenth of lowering. A
    /// symbol is a small integer, so the product's low bits (the slot) are
    /// a permutation of the key's and its high bits (`std`'s fingerprint)
    /// mix all of them.
    pub fn Map(comptime V: type) type {
        return std.HashMapUnmanaged(Symbol, V, HashContext, std.hash_map.default_max_load_percentage);
    }

    pub const HashContext = struct {
        pub fn hash(_: HashContext, s: Symbol) u64 {
            return @as(u64, @intFromEnum(s)) *% 0x9E37_79B9_7F4A_7C15;
        }

        pub fn eql(_: HashContext, a: Symbol, b: Symbol) bool {
            return a == b;
        }
    };

    pub const Optional = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(o: Optional) ?Symbol {
            return if (o == .none) null else @enumFromInt(@intFromEnum(o));
        }
    };
};

/// A remap slot `Global.mergeOne` has not filled yet. No pool reaches
/// this many symbols: a `Symbol` is a u32 index into a u32-offset pool.
pub const unmapped: Symbol = @enumFromInt(std.math.maxInt(u32));

/// Which streaming hash `Hasher` is. Measured on the generated
/// 100k-line corpus (`zig build bench -- --generate=100000`: 626 files,
/// 1.82 MB, 299k tokens; lex phase including interning, ReleaseFast, best
/// of 5, three runs each):
///
///   fx      9.6 / 9.6 / 9.7 ms   179–182 MB/s   10.3–10.5 M lines/s
///   wyhash  10.7 / 11.4 / 10.8 ms  153–162 MB/s   8.8–9.3 M lines/s
///
/// Wyhash's streaming form buffers 48 bytes and pays a call per `update`,
/// which is the wrong shape for one byte at a time; Fx is one multiply.
pub const hasher_kind: enum { fx, wyhash } = .fx;

/// Streaming hash over the bytes of one identifier. The tokenizer calls
/// `updateByte` per byte while scanning and `final` once; `hash` is the
/// one-shot form and must agree with the streamed one byte for byte.
pub const Hasher = switch (hasher_kind) {
    .fx => FxHasher,
    .wyhash => WyhashHasher,
};

/// rustc's FxHash step, `(rotl(h, 5) ^ byte) * K`, on 64 bits. The final
/// state is folded once so the low bits — what the open-addressed table
/// indexes with — depend on every byte, which a bare multiply chain does
/// not guarantee for the last few bytes.
const FxHasher = struct {
    state: u64,

    pub const seed: u64 = 0;
    const k: u64 = 0x517cc1b727220a95;

    pub fn init() FxHasher {
        return .{ .state = seed };
    }

    pub fn update(h: *FxHasher, bytes: []const u8) void {
        for (bytes) |byte| h.updateByte(byte);
    }

    pub inline fn updateByte(h: *FxHasher, byte: u8) void {
        h.state = (std.math.rotl(u64, h.state, 5) ^ byte) *% k;
    }

    pub fn final(h: *FxHasher) u64 {
        return h.state ^ (h.state >> 32);
    }

    pub fn hash(bytes: []const u8) u64 {
        var h: FxHasher = .init();
        h.update(bytes);
        return h.final();
    }
};

/// `std.hash.Wyhash` streamed one byte at a time — what `std` uses for
/// string keys, kept for re-measurement.
const WyhashHasher = struct {
    state: std.hash.Wyhash,

    pub const seed: u64 = 0;

    pub fn init() WyhashHasher {
        return .{ .state = .init(seed) };
    }

    pub fn update(h: *WyhashHasher, bytes: []const u8) void {
        h.state.update(bytes);
    }

    pub inline fn updateByte(h: *WyhashHasher, byte: u8) void {
        h.state.update(&.{byte});
    }

    pub fn final(h: *WyhashHasher) u64 {
        return h.state.final();
    }

    pub fn hash(bytes: []const u8) u64 {
        return std.hash.Wyhash.hash(seed, bytes);
    }
};

/// Well-known symbols with fixed indices in `Global` AND in every `Local`
/// made by `Local.init` (frontend.md §3.3): the names the checker and the
/// backend refer to without a lookup. Declaration order IS the index, so a
/// `WellKnown` and its `Symbol` are the same number in both pools and neither
/// needs a table. That holds within one build of the compiler and no further:
/// entries come and go from the MIDDLE of this list as the language changes —
/// `composeL`/`composeR` went with `>>` and `<<`, then `apL`/`apR` with the
/// desugaring of `|>` and `<|` — so an index is not a value to persist. When
/// a daemon starts writing indices into an on-disk cache, that cache has
/// to be keyed on the compiler build, not merely checked for new names at the
/// end. The set is `main`, the prelude module names (language.md Appendix
/// A), the core function each operator of language.md §6.5 desugars to, and
/// every name the prelude exposes (types, constructors, values), so that
/// lowering decides "is this symbol a prelude name?" by comparing its index
/// against `count` and never touches a table (`bir/prelude.zig`).
pub const WellKnown = enum(u32) {
    main,
    // Prelude modules.
    Basics,
    List,
    Maybe,
    Result,
    String,
    Char,
    Debug,
    Schema,
    // Operator functions, in the order of the language.md §6.5 table.
    add,
    sub,
    mul,
    fdiv,
    idiv,
    pow,
    append,
    cons,
    eq,
    neq,
    lt,
    gt,
    le,
    ge,
    @"and",
    @"or",
    // `|>` and `<|` are syntax, not calls (language.md §6.5, §6.7): they
    // rearrange the application they are written in and desugar to no
    // function at all, so — unlike every operator above — they contribute
    // no name here.
    // Prelude types not already listed as modules (Appendix A).
    Int,
    Float,
    Bool,
    Order,
    Never,
    Presence,
    Nullable,
    Issue,
    Options,
    Conversion,
    Value,
    // Prelude constructors.
    True,
    False,
    Just,
    Nothing,
    Ok,
    Err,
    LT,
    EQ,
    GT,
    // Prelude values, all from `Basics`, in Appendix A's order.
    toFloat,
    round,
    floor,
    ceiling,
    truncate,
    max,
    min,
    compare,
    not,
    xor,
    modBy,
    remainderBy,
    negate,
    abs,
    clamp,
    sqrt,
    logBase,
    e,
    pi,
    cos,
    sin,
    tan,
    acos,
    asin,
    atan,
    atan2,
    degrees,
    radians,
    turns,
    toPolar,
    fromPolar,
    isNaN,
    isInfinite,
    identity,
    always,
    never,
    // NOT a prelude name, and in no namespace: the letter the checker gives
    // the type variable of a well-known method's own type, so a message
    // about `==` says `a` and not `number`
    // (`docs/design/static-dispatch-spike.md` §3.1, which took it from
    // `core/Basics.beni`'s `eq : equatable a, a -> Bool`). `prelude.zig`'s
    // three namespace functions answer null for it, so `a` stays an
    // ordinary identifier in every program.
    a,
    // Core's fiber module and the two of its values the code generator
    // writes into a function that may suspend
    // (`docs/design/transparent-effects-proposal.md` §16.1).
    Task,
    andThen,
    isWaiting,
    // NOT prelude names either: the `core/List` values the code generator
    // calls. For a list pattern (`docs/design/backend.md` §7, *List
    // patterns over arrays*): an element, the list after a spread with
    // nothing behind it, and the elements a spread covers when items follow
    // it; and a building loop's exit (§8, *Tail calls modulo cons, onto an
    // array*). `unsafeGet`, `view` and `close` are core-private. And the
    // base array and offset a scalar view reads a walked list by (§8,
    // *Scalar views*), core-private too.
    unsafeGet,
    view,
    slice,
    close,
    base,
    offset,

    pub fn symbol(w: WellKnown) Symbol {
        return @enumFromInt(@intFromEnum(w));
    }

    pub const count = @typeInfo(WellKnown).@"enum".fields.len;
};

/// One open-addressed, insertion-ordered string table. `Local` and `Global`
/// are both this; they differ in who owns them and when they may be touched.
const Pool = struct {
    /// Every interned identifier's bytes, back to back.
    bytes: std.ArrayList(u8) = .empty,
    /// Per symbol: where its bytes are, and its hash (kept so growing the
    /// table never rehashes bytes). One record per symbol and not a
    /// `MultiArrayList`: every read wants the whole record, and a
    /// `MultiArrayList.get` recomputes every column's address first, which
    /// Zig's own backend does not fold away.
    entries: std.ArrayList(Entry) = .empty,
    /// Open-addressed slots holding `@intFromEnum(Symbol)` or `empty_slot`.
    /// Length is a power of two; linear probing.
    slots: []u32 = &.{},

    const Entry = struct { offset: u32, len: u32, hash: u64 };
    const empty_slot = std.math.maxInt(u32);
    const min_slots = 64;

    fn deinit(pool: *Pool, gpa: Allocator) void {
        pool.bytes.deinit(gpa);
        pool.entries.deinit(gpa);
        gpa.free(pool.slots);
        pool.* = undefined;
    }

    fn count(pool: *const Pool) u32 {
        return @intCast(pool.entries.items.len);
    }

    fn slice(pool: *const Pool, symbol: Symbol) []const u8 {
        const e = pool.entries.items[@intFromEnum(symbol)];
        return pool.bytes.items[e.offset..][0..e.len];
    }

    fn getOrPut(pool: *Pool, gpa: Allocator, bytes: []const u8) Allocator.Error!Symbol {
        return pool.getOrPutHashed(gpa, Hasher.hash(bytes), bytes);
    }

    /// `hash` must be `Hasher.hash(bytes)`, checked in a safety build (Debug,
    /// ReleaseSafe) by hashing the identifier again.
    fn getOrPutHashed(pool: *Pool, gpa: Allocator, hash: u64, bytes: []const u8) Allocator.Error!Symbol {
        if (std.debug.runtime_safety) std.debug.assert(hash == Hasher.hash(bytes));
        if (pool.slots.len == 0 or (pool.entries.items.len + 1) * 4 > pool.slots.len * 3) {
            try pool.grow(gpa);
        }
        const mask = pool.slots.len - 1;
        var i: usize = @intCast(hash & mask);
        while (true) : (i = (i + 1) & mask) {
            const slot = pool.slots[i];
            if (slot == empty_slot) break;
            const e = pool.entries.items[slot];
            if (e.hash == hash and std.mem.eql(u8, pool.bytes.items[e.offset..][0..e.len], bytes)) {
                return @enumFromInt(slot);
            }
        }
        // Not present: append bytes and entry, then claim the slot. The
        // two appends come before the slot write so a failed allocation
        // leaves the table consistent.
        const offset: u32 = @intCast(pool.bytes.items.len);
        try pool.bytes.appendSlice(gpa, bytes);
        errdefer pool.bytes.shrinkRetainingCapacity(offset);
        const index: u32 = @intCast(pool.entries.items.len);
        try pool.entries.append(gpa, .{ .offset = offset, .len = @intCast(bytes.len), .hash = hash });
        pool.slots[i] = index;
        return @enumFromInt(index);
    }

    /// The symbol whose bytes are `bytes`, or null. Reads the table and
    /// writes nothing — see `Global.find` for why that distinction is worth
    /// a second function.
    fn find(pool: *const Pool, bytes: []const u8) ?Symbol {
        return pool.findHashed(Hasher.hash(bytes), bytes);
    }

    /// `find` with the hash already taken: `hash` is `Hasher.hash(bytes)`.
    fn findHashed(pool: *const Pool, hash: u64, bytes: []const u8) ?Symbol {
        if (pool.slots.len == 0) return null;
        const mask = pool.slots.len - 1;
        var i: usize = @intCast(hash & mask);
        while (true) : (i = (i + 1) & mask) {
            const slot = pool.slots[i];
            if (slot == empty_slot) return null;
            const e = pool.entries.items[slot];
            if (e.hash == hash and std.mem.eql(u8, pool.bytes.items[e.offset..][0..e.len], bytes)) {
                return @enumFromInt(slot);
            }
        }
    }

    /// Double the slot table and reinsert from the stored hashes.
    fn grow(pool: *Pool, gpa: Allocator) Allocator.Error!void {
        const new_len = @max(min_slots, pool.slots.len * 2);
        const new_slots = try gpa.alloc(u32, new_len);
        @memset(new_slots, empty_slot);
        const mask = new_len - 1;
        for (pool.entries.items, 0..) |entry, index| {
            const hash = entry.hash;
            var i: usize = @intCast(hash & mask);
            while (new_slots[i] != empty_slot) i = (i + 1) & mask;
            new_slots[i] = @intCast(index);
        }
        gpa.free(pool.slots);
        pool.slots = new_slots;
    }
};

/// One worker's interner. Owned by that worker for the whole parallel phase;
/// nothing else reads it until `Global.merge`.
pub const Local = struct {
    pool: Pool = .{},

    /// No symbols at all. Enough for the lexer and the parser; lowering
    /// needs `init`, which fixes the well-known indices first.
    pub const empty: Local = .{};

    /// A pool whose first `WellKnown.count` symbols are the well-known names
    /// at their `WellKnown` indices — the same prefix `Global.init` has, so
    /// `Global.merge` maps them to themselves and lowering can classify a
    /// symbol as a prelude name by its index alone.
    pub fn init(gpa: Allocator) Allocator.Error!Local {
        var local: Local = .{};
        errdefer local.deinit(gpa);
        try registerWellKnown(&local.pool, gpa);
        return local;
    }

    /// True when `init` (not `empty`) made this pool: the well-known prefix
    /// is in place. Lowering asserts it.
    pub fn hasWellKnown(local: *const Local) bool {
        return local.pool.entries.items.len >= WellKnown.count;
    }

    pub fn deinit(local: *Local, gpa: Allocator) void {
        local.pool.deinit(gpa);
    }

    /// Number of distinct symbols interned so far.
    pub fn count(local: *const Local) u32 {
        return local.pool.count();
    }

    pub fn slice(local: *const Local, symbol: Symbol) []const u8 {
        return local.pool.slice(symbol);
    }

    pub fn getOrPut(local: *Local, gpa: Allocator, bytes: []const u8) Allocator.Error!Symbol {
        return local.pool.getOrPut(gpa, bytes);
    }

    /// For the tokenizer: `hash` is the `Hasher` result over exactly `bytes`.
    pub fn getOrPutHashed(local: *Local, gpa: Allocator, hash: u64, bytes: []const u8) Allocator.Error!Symbol {
        return local.pool.getOrPutHashed(gpa, hash, bytes);
    }

    /// The symbol for `bytes` if this pool already has it, and null
    /// otherwise — a lookup, never an insertion. Lowering asks it whether a
    /// prefix of a qualified token names an import alias: a text
    /// the pool has never seen cannot be one.
    pub fn find(local: *const Local, bytes: []const u8) ?Symbol {
        return local.pool.find(bytes);
    }
};

/// The session's interner: well-known symbols first, then every worker's
/// symbols in merge order. Thread-confined to the merge step and the serial
/// phases after it (sharding for concurrent access is daemon work).
pub const Global = struct {
    pool: Pool = .{},
    /// Per symbol, its position among the symbols `rankByText` saw, in byte
    /// order of their text; empty until it runs, and short of any symbol
    /// interned after it. A sort by text over many names reads these
    /// integers instead of comparing their bytes (`textRank`).
    text_rank: []u32 = &.{},

    /// Registers the `WellKnown` symbols so their indices are fixed.
    pub fn init(gpa: Allocator) Allocator.Error!Global {
        var global: Global = .{};
        errdefer global.deinit(gpa);
        try registerWellKnown(&global.pool, gpa);
        return global;
    }

    pub fn deinit(global: *Global, gpa: Allocator) void {
        gpa.free(global.text_rank);
        global.pool.deinit(gpa);
    }

    /// Keep `rank`, allocated with `gpa`, as every symbol's position in text
    /// order (`textRank`); it must order the symbols as their texts do.
    /// What it answers is only ever an ORDER the texts already have, so a
    /// sort that reads it and one that does not agree.
    pub fn setTextRank(global: *Global, gpa: Allocator, rank: []u32) void {
        gpa.free(global.text_rank);
        global.text_rank = rank;
    }

    /// `symbol`'s position in text order (`rankByText`), or null when it
    /// has none.
    pub inline fn textRank(global: *const Global, symbol: Symbol) ?u32 {
        const i = @intFromEnum(symbol);
        return if (i < global.text_rank.len) global.text_rank[i] else null;
    }

    pub fn count(global: *const Global) u32 {
        return global.pool.count();
    }

    pub fn slice(global: *const Global, symbol: Symbol) []const u8 {
        return global.pool.slice(symbol);
    }

    pub fn getOrPut(global: *Global, gpa: Allocator, bytes: []const u8) Allocator.Error!Symbol {
        return global.pool.getOrPut(gpa, bytes);
    }

    /// In a safety build, move every symbol's bytes to fresh storage and
    /// overwrite the old, as a growth of the pool may; elsewhere, nothing.
    /// A `slice` is valid only until the pool next grows, and whether an
    /// insertion grows it depends on how full it happens to be — so a slice
    /// held across one fails only when some unrelated input fills the pool
    /// to its edge. Called where a phase grows the pool after others have
    /// read it, this makes every such slice fail in every test, whatever
    /// the input: a markup primitive's name, kept past
    /// `Lower.internFixedNames`, once resolved to no export at all.
    pub fn moveBytesForSafety(global: *Global, gpa: Allocator) Allocator.Error!void {
        if (!std.debug.runtime_safety) return;
        var old = global.pool.bytes;
        var moved: std.ArrayList(u8) = try .initCapacity(gpa, old.capacity);
        moved.appendSliceAssumeCapacity(old.items);
        @memset(old.allocatedSlice(), 0xaa);
        old.deinit(gpa);
        global.pool.bytes = moved;
    }

    /// The symbol for `bytes` if this pool already has it, and null
    /// otherwise — a LOOKUP, never an insertion.
    ///
    /// It exists for `resolve/iface_bytes.zig`. Loading a serialized record
    /// turns its `strings` blob back into symbols, and that load runs on a
    /// worker thread, where `getOrPut` would append to a pool this header
    /// declares thread-confined: two workers loading two records at once
    /// would race on `bytes`, `entries` and `slots` alike. Within one
    /// session the lookup cannot legitimately miss — every string in a
    /// record that session wrote was interned by that session — so the
    /// caller turns a miss into `internal` rather than growing the pool.
    ///
    /// The cache's cross-process load is the case that CAN miss, and it runs
    /// serially before any worker starts, which is where `getOrPut` belongs.
    pub fn find(global: *const Global, bytes: []const u8) ?Symbol {
        return global.pool.find(bytes);
    }

    /// Map ONE symbol of `local` into this pool, unless `remap` already
    /// has it: the step `Session.run` takes for each symbol a file
    /// references, walking the files in index order, so that global ids
    /// are numbered by the input and not by which worker lexed what
    /// (`fast-compiler.md` §10). `remap` starts all `unmapped`.
    pub fn mergeOne(global: *Global, gpa: Allocator, local: *const Local, remap: []Symbol, symbol: Symbol) Allocator.Error!void {
        const i = @intFromEnum(symbol);
        if (remap[i] != unmapped) return;
        const e = local.pool.entries.items[i];
        remap[i] = try global.pool.getOrPutHashed(gpa, e.hash, local.pool.bytes.items[e.offset..][0..e.len]);
    }

    /// Map every symbol of `locals` that `mergeOne` has not, in the order
    /// of their TEXT (then by pool, which cannot change the answer: equal
    /// text is one global symbol). What no file references is the
    /// well-known prefix, which maps to itself, and whatever a phase
    /// interned without recording — ordering it by text keeps even its ids
    /// independent of the worker a file went to.
    pub fn mergeRest(global: *Global, gpa: Allocator, locals: []const *const Local, remaps: []const []Symbol) Allocator.Error!void {
        const Left = struct { pool: u32, symbol: u32 };
        var left: std.ArrayList(Left) = .empty;
        defer left.deinit(gpa);
        for (remaps, 0..) |remap, p| {
            for (remap, 0..) |r, i| {
                if (r == unmapped) try left.append(gpa, .{ .pool = @intCast(p), .symbol = @intCast(i) });
            }
        }
        const ByText = struct {
            locals: []const *const Local,
            fn lessThan(cx: @This(), a: Left, b: Left) bool {
                const ta = cx.locals[a.pool].slice(@enumFromInt(a.symbol));
                const tb = cx.locals[b.pool].slice(@enumFromInt(b.symbol));
                return switch (std.mem.order(u8, ta, tb)) {
                    .lt => true,
                    .gt => false,
                    .eq => a.pool < b.pool,
                };
            }
        };
        std.mem.sort(Left, left.items, ByText{ .locals = locals }, ByText.lessThan);
        for (left.items) |l| try global.mergeOne(gpa, locals[l.pool], remaps[l.pool], @enumFromInt(l.symbol));
    }
};

/// A private extension of a `Global` that other threads are reading: what
/// one task needs to intern while the session's pool is shared and may not
/// grow. Text the global pool already holds answers with its global symbol;
/// any other text is interned HERE, under a symbol with `bit` set, which no
/// global symbol has.
///
/// It is how the emitter lowers modules on several threads at once. A
/// lowering invents names (`$m$3`, `Main$eq$Point`) and the printer spells
/// them by their TEXT, so which pool a name went to never reaches an
/// output; what must hold is that one module's names come from one pool,
/// so that equal text is one symbol inside that module. Two overlays may
/// hold the same text under different symbols, and a pass that compares
/// names ACROSS modules must first map them into the global pool
/// (`Emit`'s release merge does, in module order).
pub const Overlay = struct {
    global: *const Global,
    pool: Pool = .{},

    /// Set on every symbol this overlay hands out and on no global one: a
    /// global pool is never 2³¹ names long.
    pub const bit: u32 = 1 << 31;

    pub fn init(global: *const Global) Overlay {
        return .{ .global = global };
    }

    pub fn deinit(o: *Overlay, gpa: Allocator) void {
        o.pool.deinit(gpa);
    }

    pub fn isOverlay(symbol: Symbol) bool {
        return @intFromEnum(symbol) & bit != 0;
    }

    pub fn slice(o: *const Overlay, symbol: Symbol) []const u8 {
        const i = @intFromEnum(symbol);
        if (i & bit != 0) return o.pool.slice(@enumFromInt(i & ~bit));
        return o.global.slice(symbol);
    }

    /// The global symbol for `bytes` if the shared pool has it, else this
    /// overlay's. Never writes the global pool.
    pub fn getOrPut(o: *Overlay, gpa: Allocator, bytes: []const u8) Allocator.Error!Symbol {
        const hash = Hasher.hash(bytes);
        if (o.global.pool.findHashed(hash, bytes)) |s| return s;
        const local = try o.pool.getOrPutHashed(gpa, hash, bytes);
        std.debug.assert(@intFromEnum(local) & bit == 0);
        return @enumFromInt(@intFromEnum(local) | bit);
    }

    /// The symbol for `bytes` in either pool, or null. Never writes.
    pub fn find(o: *const Overlay, bytes: []const u8) ?Symbol {
        const hash = Hasher.hash(bytes);
        if (o.global.pool.findHashed(hash, bytes)) |s| return s;
        const local = o.pool.findHashed(hash, bytes) orelse return null;
        return @enumFromInt(@intFromEnum(local) | bit);
    }
};

/// Intern every `WellKnown` name, in declaration order, into an empty pool.
fn registerWellKnown(pool: *Pool, gpa: Allocator) Allocator.Error!void {
    std.debug.assert(pool.entries.items.len == 0);
    inline for (@typeInfo(WellKnown).@"enum".fields) |field| {
        const symbol = try pool.getOrPut(gpa, field.name);
        std.debug.assert(@intFromEnum(symbol) == field.value);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Local.init shares the well-known prefix with Global, so merge is the identity there" {
    var global = try Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    var local = try Local.init(testing.allocator);
    defer local.deinit(testing.allocator);
    try testing.expect(local.hasWellKnown());
    try testing.expect(!Local.empty.hasWellKnown());
    try testing.expectEqual(WellKnown.Just.symbol(), try local.getOrPut(testing.allocator, "Just"));
    const view = try local.getOrPut(testing.allocator, "scene");
    const remap = try mergeAllForTest(&global, testing.allocator, &local);
    defer testing.allocator.free(remap);
    for (remap[0..WellKnown.count], 0..) |g, i| try testing.expectEqual(@as(u32, @intCast(i)), @intFromEnum(g));
    try testing.expectEqual(@as(Symbol, @enumFromInt(WellKnown.count)), remap[@intFromEnum(view)]);
}

test "an overlay answers global text with the global symbol and keeps new text to itself" {
    const gpa = testing.allocator;
    var global = try Global.init(gpa);
    defer global.deinit(gpa);
    const view = try global.getOrPut(gpa, "scene");
    const before = global.count();

    var a: Overlay = .init(&global);
    defer a.deinit(gpa);
    var b: Overlay = .init(&global);
    defer b.deinit(gpa);
    try testing.expectEqual(view, try a.getOrPut(gpa, "scene"));
    try testing.expect(!Overlay.isOverlay(view));

    // New text: an overlay symbol, stable within its overlay, spelled back
    // by it, and never added to the shared pool.
    const x = try a.getOrPut(gpa, "$m$3");
    try testing.expect(Overlay.isOverlay(x));
    try testing.expectEqual(x, try a.getOrPut(gpa, "$m$3"));
    try testing.expectEqualStrings("$m$3", a.slice(x));
    try testing.expectEqualStrings("scene", a.slice(view));
    try testing.expectEqual(@as(?Symbol, x), a.find("$m$3"));
    try testing.expectEqual(@as(?Symbol, null), a.find("absent"));
    try testing.expectEqual(before, global.count());
    try testing.expectEqual(@as(?Symbol, null), global.find("$m$3"));

    // Another overlay holds the same text on its own: equal text is one
    // symbol inside an overlay, not across two.
    const y = try b.getOrPut(gpa, "$m$3");
    try testing.expect(Overlay.isOverlay(y));
    try testing.expectEqualStrings("$m$3", b.slice(y));
}

test "Local dedups equal bytes and distinguishes different ones" {
    var local: Local = .empty;
    defer local.deinit(testing.allocator);
    const a = try local.getOrPut(testing.allocator, "scene");
    const b = try local.getOrPut(testing.allocator, "model");
    const c = try local.getOrPut(testing.allocator, "scene");
    try testing.expectEqual(a, c);
    try testing.expect(a != b);
    try testing.expectEqual(@as(u32, 2), local.count());
    try testing.expectEqualStrings("scene", local.slice(a));
    try testing.expectEqualStrings("model", local.slice(b));
}

test "streaming Hasher matches the one-shot hash, byte by byte" {
    var h: Hasher = .init();
    for ("Json.Decode.string") |byte| h.updateByte(byte);
    try testing.expectEqual(Hasher.hash("Json.Decode.string"), h.final());

    var local: Local = .empty;
    defer local.deinit(testing.allocator);
    var h2: Hasher = .init();
    h2.update("Json.");
    h2.update("Decode.string");
    const streamed = try local.getOrPutHashed(testing.allocator, h2.final(), "Json.Decode.string");
    const direct = try local.getOrPut(testing.allocator, "Json.Decode.string");
    try testing.expectEqual(streamed, direct);
}

test "well-known symbols have stable indices in Global" {
    var global = try Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, WellKnown.count), global.count());
    try testing.expectEqual(@as(Symbol, @enumFromInt(0)), WellKnown.main.symbol());
    try testing.expectEqualStrings("main", global.slice(WellKnown.main.symbol()));
    try testing.expectEqualStrings("and", global.slice(WellKnown.@"and".symbol()));
    try testing.expectEqualStrings("Never", global.slice(WellKnown.Never.symbol()));
    try testing.expectEqualStrings("Debug", global.slice(WellKnown.Debug.symbol()));
    // Looking a well-known name up returns its fixed index, never a new one.
    try testing.expectEqual(WellKnown.cons.symbol(), try global.getOrPut(testing.allocator, "cons"));
    try testing.expectEqual(@as(u32, WellKnown.count), global.count());
}

test "merge remaps every local symbol and shares across workers" {
    var global = try Global.init(testing.allocator);
    defer global.deinit(testing.allocator);

    var w0: Local = .empty;
    defer w0.deinit(testing.allocator);
    var w1: Local = .empty;
    defer w1.deinit(testing.allocator);

    const w0_view = try w0.getOrPut(testing.allocator, "scene");
    const w0_main = try w0.getOrPut(testing.allocator, "main");
    const w1_update = try w1.getOrPut(testing.allocator, "update");
    const w1_view = try w1.getOrPut(testing.allocator, "scene");

    const remap0 = try mergeAllForTest(&global, testing.allocator, &w0);
    defer testing.allocator.free(remap0);
    const remap1 = try mergeAllForTest(&global, testing.allocator, &w1);
    defer testing.allocator.free(remap1);

    try testing.expectEqual(@as(usize, 2), remap0.len);
    try testing.expectEqual(@as(usize, 2), remap1.len);
    // `main` lands on its well-known index; `view` gets one global id from
    // both workers; `update` is new.
    try testing.expectEqual(WellKnown.main.symbol(), remap0[@intFromEnum(w0_main)]);
    try testing.expectEqual(remap0[@intFromEnum(w0_view)], remap1[@intFromEnum(w1_view)]);
    try testing.expectEqual(@as(Symbol, @enumFromInt(WellKnown.count)), remap0[@intFromEnum(w0_view)]);
    try testing.expectEqual(@as(Symbol, @enumFromInt(WellKnown.count + 1)), remap1[@intFromEnum(w1_update)]);
    try testing.expectEqual(@as(u32, WellKnown.count + 2), global.count());
    for (remap0, 0..) |g, i| try testing.expectEqualStrings(w0.slice(@enumFromInt(i)), global.slice(g));
    for (remap1, 0..) |g, i| try testing.expectEqualStrings(w1.slice(@enumFromInt(i)), global.slice(g));
}

test "Global.find looks up without inserting" {
    var global = try Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    const before = global.count();
    // A name that is not there stays not there.
    try testing.expectEqual(@as(?Symbol, null), global.find("Json.Decode"));
    try testing.expectEqual(before, global.count());
    // One that is, at its own index, still without inserting.
    try testing.expectEqual(WellKnown.compare.symbol(), global.find("compare").?);
    try testing.expectEqual(before, global.count());
    // And after an insertion the lookup sees it.
    const view = try global.getOrPut(testing.allocator, "Json.Decode");
    try testing.expectEqual(view, global.find("Json.Decode").?);
    try testing.expectEqual(before + 1, global.count());
    // The empty string is a legal key and is not confused with "absent".
    try testing.expectEqual(@as(?Symbol, null), global.find(""));
    const empty_symbol = try global.getOrPut(testing.allocator, "");
    try testing.expectEqual(empty_symbol, global.find("").?);
}

test "randomized: Global.find agrees with getOrPut over the whole pool" {
    var global = try Global.init(testing.allocator);
    defer global.deinit(testing.allocator);
    var prng: std.Random.DefaultPrng = .init(0x1FACE);
    const random = prng.random();
    var keys: std.ArrayList(Symbol) = .empty;
    defer keys.deinit(testing.allocator);
    var buf: [12]u8 = undefined;
    for (0..4_000) |_| {
        const len = random.intRangeAtMost(usize, 1, buf.len);
        for (buf[0..len]) |*b| b.* = 'a' + random.uintLessThan(u8, 5);
        const key = buf[0..len];
        const hit = global.find(key);
        const symbol = try global.getOrPut(testing.allocator, key);
        if (hit) |h| try testing.expectEqual(symbol, h);
        try keys.append(testing.allocator, symbol);
    }
    // Everything interned is findable, at the index it was given.
    for (0..global.count()) |i| {
        const s: Symbol = @enumFromInt(i);
        try testing.expectEqual(s, global.find(global.slice(s)).?);
    }
}

test "randomized: Local agrees with a StringHashMap oracle across table growth" {
    var local: Local = .empty;
    defer local.deinit(testing.allocator);
    var oracle: std.StringHashMap(Symbol) = .init(testing.allocator);
    defer {
        var it = oracle.keyIterator();
        while (it.next()) |key| testing.allocator.free(key.*);
        oracle.deinit();
    }

    var prng: std.Random.DefaultPrng = .init(0xBE11);
    const random = prng.random();
    var buf: [12]u8 = undefined;
    for (0..2_000) |_| {
        // Short alphabet and short length so repeats are frequent.
        const len = random.intRangeAtMost(usize, 1, buf.len);
        for (buf[0..len]) |*b| b.* = 'a' + random.uintLessThan(u8, 4);
        const key = buf[0..len];

        const symbol = try local.getOrPut(testing.allocator, key);
        if (oracle.get(key)) |expected| {
            try testing.expectEqual(expected, symbol);
        } else {
            try testing.expectEqual(@as(u32, @intFromEnum(symbol)), oracle.count());
            try oracle.put(try testing.allocator.dupe(u8, key), symbol);
        }
        try testing.expectEqualStrings(key, local.slice(symbol));
    }
    try testing.expectEqual(oracle.count(), local.count());
    try testing.expect(local.count() > 8 * Pool.min_slots); // the table grew, several times over
}

test "no leak when allocation fails mid-insert" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator) !void {
            var local: Local = .empty;
            defer local.deinit(gpa);
            var global = try Global.init(gpa);
            defer global.deinit(gpa);
            for (0..100) |i| {
                var buf: [8]u8 = undefined;
                _ = try local.getOrPut(gpa, try std.fmt.bufPrint(&buf, "s{d}", .{i}));
            }
            const remap = try mergeAllForTest(&global, gpa, &local);
            gpa.free(remap);
        }
    }.run, .{});
}

/// Tests only: every symbol of `local`, in LOCAL order, through `mergeOne`.
/// The compiler never merges a whole pool at once — `Session.mergeInterners`
/// goes file by file — so this lives beside the tests and not on
/// `Global`, where it would invite a worker-order merge back.
fn mergeAllForTest(global: *Global, gpa: Allocator, local: *const Local) Allocator.Error![]Symbol {
    const remap = try gpa.alloc(Symbol, local.count());
    errdefer gpa.free(remap);
    @memset(remap, unmapped);
    for (0..remap.len) |i| try global.mergeOne(gpa, local, remap, @enumFromInt(i));
    return remap;
}
