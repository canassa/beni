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
//! interns into its own `Local`; after the parallel phase the driver calls
//! `Global.merge` for each worker IN WORKER INDEX ORDER, which returns the
//! remap table `local symbol → global symbol` the worker then applies to its
//! token payloads and Bir references. Merging in a fixed order is what makes
//! global symbol numbering deterministic regardless of scheduling.
//!
//! `Global` is thread-confined to that merge step in M1. Sharding it for
//! concurrent lookups (Zig's `InternPool` encoding with the thread id in the
//! high bits) is M4 work and is deliberately not started here.
//!
//! Hash: `std.hash.Wyhash`, seed 0, because it has a streaming form (`update`
//! byte-by-byte is what the tokenizer needs) and is what `std` uses for
//! string keys. The design asks for this to be measured, not guessed; that
//! measurement is M1a's, once there is a tokenizer to drive it. Switching to
//! an FxHash-style multiply-xor is a one-line change confined to `Hasher`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Symbol = enum(u32) {
    _,

    pub fn toOptional(s: Symbol) Optional {
        return @enumFromInt(@intFromEnum(s));
    }

    pub const Optional = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(o: Optional) ?Symbol {
            return if (o == .none) null else @enumFromInt(@intFromEnum(o));
        }
    };
};

/// Streaming hash over the bytes of one identifier.
pub const Hasher = struct {
    state: std.hash.Wyhash,

    pub const seed: u64 = 0;

    pub fn init() Hasher {
        return .{ .state = .init(seed) };
    }

    pub fn update(h: *Hasher, bytes: []const u8) void {
        h.state.update(bytes);
    }

    pub fn updateByte(h: *Hasher, byte: u8) void {
        h.state.update(&.{byte});
    }

    pub fn final(h: *Hasher) u64 {
        return h.state.final();
    }

    /// One-shot form, identical to streaming the same bytes.
    pub fn hash(bytes: []const u8) u64 {
        return std.hash.Wyhash.hash(seed, bytes);
    }
};

/// Well-known symbols with fixed indices in `Global` (frontend.md §3.3): the
/// names the checker and the backend refer to without a lookup. Declaration
/// order IS the index; append only. The set is `main`, the prelude module
/// names (language.md Appendix A), and the core function each operator of
/// language.md §6.5 desugars to.
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
    apL,
    apR,
    composeL,
    composeR,

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
    /// table never rehashes bytes).
    entries: std.MultiArrayList(Entry) = .empty,
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
        return @intCast(pool.entries.len);
    }

    fn slice(pool: *const Pool, symbol: Symbol) []const u8 {
        const e = pool.entries.get(@intFromEnum(symbol));
        return pool.bytes.items[e.offset..][0..e.len];
    }

    fn getOrPut(pool: *Pool, gpa: Allocator, bytes: []const u8) Allocator.Error!Symbol {
        return pool.getOrPutHashed(gpa, Hasher.hash(bytes), bytes);
    }

    /// `hash` must be `Hasher.hash(bytes)`; checked in safe builds.
    fn getOrPutHashed(pool: *Pool, gpa: Allocator, hash: u64, bytes: []const u8) Allocator.Error!Symbol {
        std.debug.assert(hash == Hasher.hash(bytes));
        if (pool.slots.len == 0 or (pool.entries.len + 1) * 4 > pool.slots.len * 3) {
            try pool.grow(gpa);
        }
        const mask = pool.slots.len - 1;
        var i: usize = @intCast(hash & mask);
        while (true) : (i = (i + 1) & mask) {
            const slot = pool.slots[i];
            if (slot == empty_slot) break;
            const e = pool.entries.get(slot);
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
        const index: u32 = @intCast(pool.entries.len);
        try pool.entries.append(gpa, .{ .offset = offset, .len = @intCast(bytes.len), .hash = hash });
        pool.slots[i] = index;
        return @enumFromInt(index);
    }

    /// Double the slot table and reinsert from the stored hashes.
    fn grow(pool: *Pool, gpa: Allocator) Allocator.Error!void {
        const new_len = @max(min_slots, pool.slots.len * 2);
        const new_slots = try gpa.alloc(u32, new_len);
        @memset(new_slots, empty_slot);
        const mask = new_len - 1;
        for (pool.entries.items(.hash), 0..) |hash, index| {
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

    pub const empty: Local = .{};

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
};

/// The session's interner: well-known symbols first, then every worker's
/// symbols in merge order. Thread-confined to the merge step and the serial
/// phases after it (sharding for concurrent access is M4).
pub const Global = struct {
    pool: Pool = .{},

    /// Registers the `WellKnown` symbols so their indices are fixed.
    pub fn init(gpa: Allocator) Allocator.Error!Global {
        var global: Global = .{};
        errdefer global.deinit(gpa);
        inline for (@typeInfo(WellKnown).@"enum".fields) |field| {
            const symbol = try global.pool.getOrPut(gpa, field.name);
            std.debug.assert(@intFromEnum(symbol) == field.value);
        }
        return global;
    }

    pub fn deinit(global: *Global, gpa: Allocator) void {
        global.pool.deinit(gpa);
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

    /// Fold `local` into the global pool and return the remap table:
    /// `remap[@intFromEnum(local_symbol)]` is the global symbol. Caller owns
    /// the returned slice. Call once per worker, in worker index order.
    pub fn merge(global: *Global, gpa: Allocator, local: *const Local) Allocator.Error![]Symbol {
        const n = local.pool.entries.len;
        const remap = try gpa.alloc(Symbol, n);
        errdefer gpa.free(remap);
        const offsets = local.pool.entries.items(.offset);
        const lens = local.pool.entries.items(.len);
        const hashes = local.pool.entries.items(.hash);
        for (remap, offsets, lens, hashes) |*out, offset, len, hash| {
            out.* = try global.pool.getOrPutHashed(gpa, hash, local.pool.bytes.items[offset..][0..len]);
        }
        return remap;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Local dedups equal bytes and distinguishes different ones" {
    var local: Local = .empty;
    defer local.deinit(testing.allocator);
    const a = try local.getOrPut(testing.allocator, "view");
    const b = try local.getOrPut(testing.allocator, "model");
    const c = try local.getOrPut(testing.allocator, "view");
    try testing.expectEqual(a, c);
    try testing.expect(a != b);
    try testing.expectEqual(@as(u32, 2), local.count());
    try testing.expectEqualStrings("view", local.slice(a));
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
    try testing.expectEqualStrings("composeR", global.slice(WellKnown.composeR.symbol()));
    try testing.expectEqualStrings("Debug", global.slice(WellKnown.Debug.symbol()));
    // Looking a well-known name up returns its fixed index, never a new one.
    try testing.expectEqual(WellKnown.apR.symbol(), try global.getOrPut(testing.allocator, "apR"));
    try testing.expectEqual(@as(u32, WellKnown.count), global.count());
}

test "merge remaps every local symbol and shares across workers" {
    var global = try Global.init(testing.allocator);
    defer global.deinit(testing.allocator);

    var w0: Local = .empty;
    defer w0.deinit(testing.allocator);
    var w1: Local = .empty;
    defer w1.deinit(testing.allocator);

    const w0_view = try w0.getOrPut(testing.allocator, "view");
    const w0_main = try w0.getOrPut(testing.allocator, "main");
    const w1_update = try w1.getOrPut(testing.allocator, "update");
    const w1_view = try w1.getOrPut(testing.allocator, "view");

    const remap0 = try global.merge(testing.allocator, &w0);
    defer testing.allocator.free(remap0);
    const remap1 = try global.merge(testing.allocator, &w1);
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
    for (0..20_000) |_| {
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
    try testing.expect(local.count() > Pool.min_slots); // the table grew at least once
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
            const remap = try global.merge(gpa, &local);
            gpa.free(remap);
        }
    }.run, .{});
}
