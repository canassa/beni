//! The compiler build id (docs/design/fast-compiler.md §8, *The persistent
//! cache, and its key*): 16 bytes that change whenever the compiler changes,
//! computed by `build.zig` and handed in as a build option.
//!
//! It is the term of the cache key that says "these bytes were produced by
//! THIS compiler". Everything a module's check depends on that is not in its
//! sources and not in the option string is in the compiler's own code, so a
//! key that did not carry the compiler would serve an entry written by a
//! different one — the failure mode a cache may not have, because it is a
//! wrong answer that depends on history.
//!
//! **The recipe is `build.zig`'s `compilerBuildId`**, and it is stated there
//! rather than here because that is where it runs: `SipHash128(1, 3)` over a
//! recipe tag, the Zig version string, the optimize mode, the target triple,
//! `build.zig`, every file under `src/`, every file of the embedded core and
//! every file of every platform the binary carries — name then bytes, in
//! sorted path order. **Everything the binary is built from**, and nothing
//! less: until recipe v2 (2026-10-02) the embedded core, the platforms'
//! files other than their Zig and `build.zig` were left to the per-module
//! key terms, so two binaries that differed in them alone had one id, and
//! the only thing keeping one from serving the other's entries was that
//! every term downstream happened to cover what differed.
//!
//! The per-module terms still hash each `.beni` and sibling `.js` a check
//! reads, which is finer, and `--core-root` relies on them: a core read from
//! disk is not in the id, and an edit to it re-checks only what can observe
//! it (`fast-compiler.md` §8). `--cache-build-id=<s>` is the escape hatch.
//!
//! *Deviation from the spec's letter, recorded deliberately.* §8 lists
//! `beni.version` as a separate term. It is not hashed separately here,
//! because `src/beni.zig` — the file the constant lives in — is one of the
//! files under `src/`, so its bytes are already in the digest; hashing it
//! again would buy nothing and would make `build.zig` parse Zig source to
//! find the literal. The property the term exists for, "the id moves when the
//! version does", holds unchanged.

const std = @import("std");
const build_options = @import("build_options");
const iface_bytes = @import("resolve/iface_bytes.zig");

/// The id itself. Little-endian is not a question: these are opaque bytes and
/// they are fed into the key in the order they are written here.
pub const bytes: [16]u8 = build_options.build_id;

/// The id as the 32 lowercase hex digits `beni version` prints, through the
/// same formatter `--iface-hash` uses — there is one hex renderer in the
/// compiler for the same reason there is one hash function.
pub fn hex() [32]u8 {
    return iface_bytes.hashHex(bytes);
}

const testing = std.testing;

test "the build id is not all zeroes, and its hex is 32 lowercase digits" {
    // A build option that silently defaulted to zero would make every cache
    // entry of every compiler build interchangeable, which is exactly the
    // bug the term exists to prevent — and it would be invisible, because
    // the cache would still work.
    try testing.expect(!std.mem.allEqual(u8, &bytes, 0));
    const digits = hex();
    try testing.expectEqual(@as(usize, 32), digits.len);
    for (digits) |c| try testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
}
