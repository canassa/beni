//! The `html` platform's Zig (docs/design/boundary.md §9.5): no lowering of
//! its own, only the HTML parser's table, which every lowering that serves
//! the `html` vocabulary imports as `platform_html` so that `dom` and `ssr`
//! agree on what a string of markup parses into (backend.md §15.3, §15.6).

const beni_markup = @import("beni_markup");

/// `html` declares the vocabulary and the markup type and names no
/// lowering; `node` and `browser` lower it.
pub const lowerings = [_]beni_markup.Lowering{};

pub const parser_table = @import("parser_table.zig");
