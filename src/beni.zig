//! Library root (docs/design/frontend.md §2): re-exports every internal
//! module and is the root of the hermetic test suite (`zig build test`).
//! `main.zig` is a thin shell over this; the bench harness imports it too.

const std = @import("std");

/// Printed by `beni version`. Bumped per milestone until there is a release.
pub const version = "0.0.0-m0";

pub const Arena = @import("Arena.zig");
pub const Artifacts = @import("Artifacts.zig");
pub const Cli = @import("Cli.zig");
pub const InternPool = @import("InternPool.zig");
pub const Profile = @import("Profile.zig");
pub const Session = @import("Session.zig");
pub const SourceStore = @import("SourceStore.zig");
pub const Token = @import("lex/Token.zig");
pub const Tokenizer = @import("lex/Tokenizer.zig");
pub const lex = struct {
    pub const Token = @import("lex/Token.zig");
    pub const Tokenizer = @import("lex/Tokenizer.zig");
    pub const Diagnostics = @import("lex/Diagnostics.zig");
};
pub const dump = struct {
    pub const tokens = @import("dump/tokens.zig");
};
pub const render = struct {
    pub const text = @import("render/text.zig");
    pub const json = @import("render/json.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(lex);
    std.testing.refAllDecls(dump);
    std.testing.refAllDecls(render);
}
