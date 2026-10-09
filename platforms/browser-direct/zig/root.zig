//! The `browser-direct` platform's Zig (docs/design/boundary.md §9.5): the
//! `direct` lowering, which compiles a program of The Elm Architecture
//! whole rather than its markup one root at a time
//! (docs/design/browser-direct.md).

const beni_markup = @import("beni_markup");

pub const lowerings = [_]beni_markup.Lowering{@import("direct.zig").lowering};

test {
    _ = @import("direct.zig");
}
