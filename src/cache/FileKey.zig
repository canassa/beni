//! The front-end artifact's key (docs/design/fast-compiler.md §8, *The
//! front-end artifacts, and the file key*): 128 bits over everything that can
//! reach one FILE's lowering, and nothing else.
//!
//! ```
//! "BENIFEK\x00"           8       magic
//! key_version: u32                bumped whenever this recipe changes
//! build_id: [16]u8                the compiler build id, exactly as the
//!                                 module key takes it (`src/build_id.zig`)
//! package: u8                     SourceStore.Package — app, core or platform
//! lower_bits: u8                  bit 0 `Lower.Options.core`, bit 1 `.platform`
//! name_len: u32, name             the DOTTED module name, `Lower.Options.module_name`
//! source_hash: [16]u8             over the module's source bytes
//! ```
//!
//! **It is not `Key.zig`'s module key, and that is the whole reason for a
//! second file.** The transitive module key folds every import's key, so a body edit in a
//! leaf moves every transitive importer's module key. It must not move their
//! FRONT END: a `Bir` is a function of one file's bytes, and lowering is
//! handed `(text, tokens, tree, interner, Options{core, platform,
//! module_name})` and is specified to read no other module (`frontend.md`
//! §6). So the recipe carries those inputs and no import, no sibling `.js`
//! and no `core_epoch`.
//!
//! **`--pattern-budget` and the informational switch are NOT in it**, though
//! they are in the module key: neither reaches lowering, and putting them in
//! would throw the front end away for a flag that cannot change a token. The
//! module NAME is in it because `self_import` reads it; the package and the
//! two permission bits because `foreign` and `equatable` are lexically gated.
//!
//! The hash is `iface_bytes.hash` — `SipHash128(1, 3)` with an all-zero key —
//! so there is one hash function in the compiler.
//!
//! **What a moving key COSTS, said plainly.** The recipe hashes the source
//! BYTES, so a whitespace-only or comment-only edit moves the file key and
//! throws that file's front end away: every token `start` moved, and a
//! comment is a token the `Bir` indexes through `doc_start`/`doc_end`. One
//! file's lex, parse and lower is ~66 µs on the 100k corpus, so the cost is
//! real and small, and it is bounded to the ONE file that was edited —
//! which is exactly what this key buys over the module key. Doing better
//! needs a form-insensitive key, which is the interface firewall's question
//! and not this one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SourceStore = @import("../SourceStore.zig");
const iface_bytes = @import("../resolve/iface_bytes.zig");
const Key = @import("Key.zig");

/// First eight bytes of every file key's byte string. Different from the
/// module key's, so the two recipes can never produce one digest from one
/// byte string by accident.
pub const magic = "BENIFEK\x00";

/// Bumped whenever the meaning of any byte of the recipe changes. Every
/// artifact written by an older recipe then misses, which is the only
/// migration a cache ever needs.
pub const key_version: u32 = 1;

/// Same width and same renderer as the module key's, so one hex printer and
/// one fan-out serve both.
pub const FileKey = Key.Key;

pub const none: FileKey = @splat(0);

pub fn hex(k: FileKey) [32]u8 {
    return iface_bytes.hashHex(k);
}

/// Everything the recipe reads about one file. `core` and `platform` are
/// `Lower.Options`' two bits as that file's lowering actually runs with them
/// — `Session.fileIsCore` and `Session.fileMayDeclareForeign` — and not the
/// run's `--core`, for `Key.OptionBits`' reason: sharper is a smaller key,
/// never a wronger one.
pub const Terms = struct {
    build_id: [16]u8,
    package: SourceStore.Package,
    core: bool,
    platform: bool,
    /// The dotted module name.
    name: []const u8,
    source_hash: [16]u8,
};

/// The recipe's byte string, appended to `out`. Exposed so a test can assert
/// the BYTES rather than only the digest: a recipe change that produced the
/// same 16 bytes for two different inputs would be invisible to a test that
/// only ever compared keys.
pub fn writeBytes(gpa: Allocator, out: *std.ArrayList(u8), t: Terms) Allocator.Error!void {
    try out.appendSlice(gpa, magic);
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, key_version, .little);
    try out.appendSlice(gpa, &word);
    try out.appendSlice(gpa, &t.build_id);
    try out.append(gpa, @intFromEnum(t.package));
    try out.append(gpa, lowerBits(t.core, t.platform));
    std.mem.writeInt(u32, &word, @intCast(t.name.len), .little);
    try out.appendSlice(gpa, &word);
    try out.appendSlice(gpa, t.name);
    try out.appendSlice(gpa, &t.source_hash);
}

pub fn lowerBits(core: bool, platform: bool) u8 {
    return @as(u8, @intFromBool(core)) | (@as(u8, @intFromBool(platform)) << 1);
}

/// `compute`, with no allocator: the byte string is bounded by the module
/// name, and a module name is bounded by `std.fs.max_path_bytes`, so the
/// whole recipe fits a stack buffer. That matters because this runs on a
/// WORKER, once per file, in the per-file phase — the one place in the
/// compiler where an allocation per file is a measurable row.
pub fn compute(t: Terms) FileKey {
    var buffer: [fixed_bytes + std.fs.max_path_bytes]u8 = undefined;
    var at: usize = 0;
    @memcpy(buffer[at..][0..8], magic);
    at += 8;
    std.mem.writeInt(u32, buffer[at..][0..4], key_version, .little);
    at += 4;
    @memcpy(buffer[at..][0..16], &t.build_id);
    at += 16;
    buffer[at] = @intFromEnum(t.package);
    at += 1;
    buffer[at] = lowerBits(t.core, t.platform);
    at += 1;
    const name = t.name[0..@min(t.name.len, std.fs.max_path_bytes)];
    std.mem.writeInt(u32, buffer[at..][0..4], @intCast(name.len), .little);
    at += 4;
    @memcpy(buffer[at..][0..name.len], name);
    at += name.len;
    @memcpy(buffer[at..][0..16], &t.source_hash);
    at += 16;
    return iface_bytes.hash(buffer[0..at]);
}

/// magic(8) + version(4) + build_id(16) + package(1) + lower_bits(1) +
/// name_len(4) + source_hash(16).
const fixed_bytes: usize = 50;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const sample_build_id: [16]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

fn sampleTerms() Terms {
    return .{
        .build_id = sample_build_id,
        .package = .app,
        .core = false,
        .platform = false,
        .name = "Json.Decode",
        .source_hash = @splat(0xAA),
    };
}

fn expectDifferentKeys(a: Terms, b: Terms) !void {
    if (std.mem.eql(u8, &compute(a), &compute(b))) {
        std.debug.print("two different inputs produced the same file key\n", .{});
        return error.KeysCollided;
    }
}

test "the file key's byte string is the recipe, field by field" {
    // The BYTES and not only the digest: a recipe that dropped a term would
    // still produce 16 plausible bytes, and a test that compared only keys
    // would pass on every input that happened not to collide.
    const gpa = testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var t = sampleTerms();
    t.core = true;
    t.platform = true;
    try writeBytes(gpa, &bytes, t);

    var at: usize = 0;
    try testing.expectEqualStrings(magic, bytes.items[at..][0..8]);
    at += 8;
    try testing.expectEqual(key_version, std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqualSlices(u8, &sample_build_id, bytes.items[at..][0..16]);
    at += 16;
    try testing.expectEqual(@as(u8, @intFromEnum(SourceStore.Package.app)), bytes.items[at]);
    at += 1;
    try testing.expectEqual(@as(u8, 0b11), bytes.items[at]);
    at += 1;
    try testing.expectEqual(@as(u32, 11), std.mem.readInt(u32, bytes.items[at..][0..4], .little));
    at += 4;
    try testing.expectEqualStrings("Json.Decode", bytes.items[at..][0..11]);
    at += 11;
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xAA)), bytes.items[at..][0..16]);
    at += 16;
    try testing.expectEqual(bytes.items.len, at);

    // The no-allocator form hashes exactly those bytes.
    try testing.expectEqual(iface_bytes.hash(bytes.items), compute(t));
}

test "every term of the recipe moves the file key, and the two bits move it apart" {
    {
        var t = sampleTerms();
        t.build_id = @splat(0);
        try expectDifferentKeys(sampleTerms(), t);
    }
    {
        var t = sampleTerms();
        t.package = .core;
        try expectDifferentKeys(sampleTerms(), t);
    }
    {
        var t = sampleTerms();
        t.name = "Json.Decoder";
        try expectDifferentKeys(sampleTerms(), t);
    }
    {
        var t = sampleTerms();
        t.source_hash = @splat(0xAB);
        try expectDifferentKeys(sampleTerms(), t);
    }
    // The two permission bits are separate terms, not one: `--core` and a
    // platform package's privilege are different permissions
    // (`Session.fileIsCore` against `fileMayDeclareForeign`), and a key that
    // conflated them would share one artifact between two lowerings that
    // accept different programs.
    {
        var core = sampleTerms();
        core.core = true;
        var platform = sampleTerms();
        platform.platform = true;
        try expectDifferentKeys(sampleTerms(), core);
        try expectDifferentKeys(sampleTerms(), platform);
        try expectDifferentKeys(core, platform);
    }
}

test "the recipe is length-prefixed, so two different splits cannot agree" {
    // Without the length word, `name = "AB"` followed by a source hash and
    // `name = "A"` followed by a different one could hash the same bytes.
    var a = sampleTerms();
    a.name = "AB";
    var b = sampleTerms();
    b.name = "A";
    try expectDifferentKeys(a, b);
}

test "the file key is a pure function, and is not the module key" {
    try testing.expectEqual(compute(sampleTerms()), compute(sampleTerms()));
    // Different magic, so no byte string is ever read by both recipes.
    try testing.expect(!std.mem.eql(u8, magic, Key.magic));
}
