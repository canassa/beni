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
    "pub foreign impure new : ⊤ → TextEncoder\n\n" ++
    "pub foreign impure encoding : TextEncoder → String\n";
pub const idl_sha256 = "f820cd04584ca7f815b8cee1381d76e27363090cd62e0cb88962d8188bc7c90a";
pub const node_sha256 = "47f15d2c6395318e04d4038fefafbcbda59a054238dd18045dc333d229e9488a";

pub const getter_node_sha256 = "673c836054c0c1a5da8c28c947a04778c5df47d8d654184439148a4c53480472";
pub const getter_algorithm_sha256 = "e1421f1791b202717883c452a6267129ce5fb3ca13652e5022a2b6d2a11fc262";

pub const Row = struct {
    schema: u32 = 1,
    adapter_revision: u32 = 2,
    identity: Origin = .text_encoder_v1,
    file: u32,
    member_start: u32,
    member_end: u32,
    getter_start: u32 = 817,
    getter_end: u32 = 855,
    includes_start: u32 = 1181,
    idl_digest: [32]u8,
    source_digest: [32]u8,
    node_digest: [32]u8,
    getter_node_digest: [32]u8,
    getter_algorithm_digest: [32]u8,
    rung: u8 = 1,
    realm_mask: u8 = 0x1f,
    expected_error: ExpectedError = .none,
    status: Status = .awaiting_realm,
};

pub fn row(file: u32, start: u32, end: u32) Row {
    var out: Row = .{ .file = file, .member_start = start, .member_end = end, .idl_digest = undefined, .source_digest = undefined, .node_digest = undefined, .getter_node_digest = undefined, .getter_algorithm_digest = undefined };
    _ = std.fmt.hexToBytes(&out.idl_digest, idl_sha256) catch unreachable;
    _ = std.fmt.hexToBytes(&out.node_digest, node_sha256) catch unreachable;
    _ = std.fmt.hexToBytes(&out.getter_node_digest, getter_node_sha256) catch unreachable;
    _ = std.fmt.hexToBytes(&out.getter_algorithm_digest, getter_algorithm_sha256) catch unreachable;
    std.crypto.hash.sha2.Sha256.hash(source, &out.source_digest, .{});
    return out;
}

/// Versioned attestation domain included in own keys AND exported fingerprints.
/// Physical/ordinary suppliers never acquire this domain from equal source bytes.
pub const provenance = "native-text-encoder:2;adapter=2;idl=" ++ idl_sha256 ++
    ";node=" ++ node_sha256 ++ ";signature=Unit->TextEncoder,TextEncoder->String;recipes=1,2;effect=1;realm=31;expected=none;status=awaiting-realm;row=" ++ @embedFile("TextEncoder.binding.zon");

/// Actual pinned generator output, regenerated and compared in native tests.
pub const candidate: Row = @import("TextEncoder.binding.zon");
