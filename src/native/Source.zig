//! Compiler generated source supplier and pinned row format. Neither an origin
//! tag nor this row alone certifies an ordinary checked type/callable.
const std = @import("std");
pub const Origin = enum(u8) { none, text_encoder_v1 };
pub const Status = enum(u8) { awaiting_realm };
pub const ExpectedError = enum(u8) { none };
pub const module_name = "Browser.Host.TextEncoder";
pub const source: [:0]const u8 =
    "-- Generated from pinned TextEncoder constructor metadata; awaiting realm proof.\n" ++
    "pub foreign type TextEncoder\n\n" ++
    "pub foreign impure new : ⊤ → TextEncoder\n";
pub const idl_sha256 = "f820cd04584ca7f815b8cee1381d76e27363090cd62e0cb88962d8188bc7c90a";
pub const node_sha256 = "47f15d2c6395318e04d4038fefafbcbda59a054238dd18045dc333d229e9488a";

pub const Row = struct {
    schema: u32 = 1,
    adapter_revision: u32 = 1,
    identity: Origin = .text_encoder_v1,
    file: u32,
    member_start: u32,
    member_end: u32,
    idl_digest: [32]u8,
    source_digest: [32]u8,
    node_digest: [32]u8,
    rung: u8 = 1,
    realm_mask: u8 = 0x1f,
    expected_error: ExpectedError = .none,
    status: Status = .awaiting_realm,
};

pub fn row(file: u32, start: u32, end: u32) Row {
    var out: Row = .{ .file = file, .member_start = start, .member_end = end, .idl_digest = undefined, .source_digest = undefined, .node_digest = undefined };
    _ = std.fmt.hexToBytes(&out.idl_digest, idl_sha256) catch unreachable;
    _ = std.fmt.hexToBytes(&out.node_digest, node_sha256) catch unreachable;
    std.crypto.hash.sha2.Sha256.hash(source, &out.source_digest, .{});
    return out;
}

/// Versioned attestation domain included in own keys AND exported fingerprints.
/// Physical/ordinary suppliers never acquire this domain from equal source bytes.
pub const provenance = "native-text-encoder:1;adapter=1;idl=" ++ idl_sha256 ++
    ";node=" ++ node_sha256 ++ ";signature=Unit->TextEncoder;effect=1;realm=31;expected=none;status=awaiting-realm;row=" ++ @embedFile("TextEncoder.binding.zon");

/// Actual pinned generator output, regenerated and compared in native tests.
pub const candidate: Row = @import("TextEncoder.binding.zon");
