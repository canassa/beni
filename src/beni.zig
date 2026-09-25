//! Library root (docs/design/frontend.md §2): re-exports every internal
//! module and is the root of the hermetic test suite (`zig build test`).
//! `main.zig` is a thin shell over this; the bench harness imports it too.

const std = @import("std");

/// Printed by `beni version`. Bumped per milestone until there is a release.
pub const version = "0.1.0-m1";

/// The compiler build id (`fast-compiler.md` §8), printed by `beni version`
/// after the version so that a bug report names the compiler that wrote a
/// cache.
pub const build_id = @import("build_id.zig");

pub const Arena = @import("Arena.zig");
pub const Artifacts = @import("Artifacts.zig");
pub const Cli = @import("Cli.zig");
pub const InternPool = @import("InternPool.zig");
pub const Profile = @import("Profile.zig");
pub const Session = @import("Session.zig");
pub const SourceStore = @import("SourceStore.zig");
pub const platform = @import("platform.zig");
pub const Token = @import("lex/Token.zig");
pub const Tokenizer = @import("lex/Tokenizer.zig");
pub const lex = struct {
    pub const Token = @import("lex/Token.zig");
    pub const Tokenizer = @import("lex/Tokenizer.zig");
    pub const Diagnostics = @import("lex/Diagnostics.zig");
};
pub const Ast = @import("parse/Ast.zig");
pub const Parse = @import("parse/Parse.zig");
pub const parse = struct {
    pub const Ast = @import("parse/Ast.zig");
    pub const Parse = @import("parse/Parse.zig");
    pub const Diagnostics = @import("parse/Diagnostics.zig");
};
pub const js = struct {
    pub const JsIr = @import("js/JsIr.zig");
    pub const Lower = @import("js/Lower.zig");
    pub const Print = @import("js/Print.zig");
    pub const Emit = @import("js/Emit.zig");
    pub const Sibling = @import("js/Sibling.zig");
    pub const Manifest = @import("js/Manifest.zig");
};
pub const build = struct {
    pub const Command = @import("build/Command.zig");
};
pub const fmt = struct {
    pub const Format = @import("fmt/Format.zig");
    pub const Command = @import("fmt/Command.zig");
};
pub const Bir = @import("bir/Bir.zig");
pub const Lower = @import("bir/Lower.zig");
pub const bir = struct {
    pub const Bir = @import("bir/Bir.zig");
    pub const Lower = @import("bir/Lower.zig");
    pub const Diagnostics = @import("bir/Diagnostics.zig");
    pub const prelude = @import("bir/prelude.zig");
};
pub const resolve = struct {
    pub const Graph = @import("resolve/Graph.zig");
    pub const Interface = @import("resolve/Interface.zig");
    pub const Resolve = @import("resolve/Resolve.zig");
    pub const iface_bytes = @import("resolve/iface_bytes.zig");
    pub const Diagnostics = @import("resolve/Diagnostics.zig");
};
pub const frontend = struct {
    pub const artifact_bytes = @import("frontend/artifact_bytes.zig");
};
pub const cache = struct {
    pub const Key = @import("cache/Key.zig");
    pub const FileKey = @import("cache/FileKey.zig");
    pub const entry_bytes = @import("cache/entry_bytes.zig");
    pub const type_body = @import("cache/type_body.zig");
    pub const dispatch_bytes = @import("cache/dispatch_bytes.zig");
    pub const Dir = @import("cache/Dir.zig");
    pub const Digest = @import("cache/Digest.zig");
};
pub const check = struct {
    pub const TypeStore = @import("check/TypeStore.zig");
    pub const Types = @import("check/Types.zig");
    pub const Constrain = @import("check/Constrain.zig");
    pub const Solve = @import("check/Solve.zig");
    pub const Schemes = @import("check/Schemes.zig");
    pub const Render = @import("check/Render.zig");
    pub const Diagnostics = @import("check/Diagnostics.zig");
    pub const Check = @import("check/Check.zig");
    pub const reads = @import("check/reads.zig");
    pub const Dispatch = @import("check/Dispatch.zig");
    pub const Convention = @import("check/Convention.zig");
    pub const Command = @import("check/Command.zig");
};
pub const check2 = struct {
    pub const Check = @import("check2/Check.zig");
    pub const Driver = @import("check2/Driver.zig");
    pub const Incremental = @import("check2/Incremental.zig");
    pub const Module = @import("check2/Module.zig");
};
pub const dump = struct {
    pub const tokens = @import("dump/tokens.zig");
    pub const ast = @import("dump/ast.zig");
    pub const bir = @import("dump/bir.zig");
    pub const interface = @import("dump/interface.zig");
    pub const types = @import("dump/types.zig");
    pub const graph = @import("dump/graph.zig");
    pub const dispatch = @import("dump/dispatch.zig");
};
pub const render = struct {
    pub const text = @import("render/text.zig");
    pub const json = @import("render/json.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(lex);
    std.testing.refAllDecls(parse);
    std.testing.refAllDecls(bir);
    std.testing.refAllDecls(resolve);
    std.testing.refAllDecls(frontend);
    std.testing.refAllDecls(cache);
    std.testing.refAllDecls(check);
    std.testing.refAllDecls(check2);
    std.testing.refAllDecls(dump);
    std.testing.refAllDecls(fmt);
    std.testing.refAllDecls(js);
    std.testing.refAllDecls(build);
    std.testing.refAllDecls(render);
}
