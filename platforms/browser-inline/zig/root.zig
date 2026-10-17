//! The `browser-inline` platform's Zig (docs/design/boundary.md §9.5): the
//! `inline` lowering, which compiles a program of The Elm Architecture whole,
//! with no task kernel, into the shape tea-inline writes
//! (docs/design/browser-inline.md).

const beni_markup = @import("beni_markup");

pub const lowerings = [_]beni_markup.Lowering{@import("inline.zig").lowering};

test {
    _ = @import("inline.zig");
}
