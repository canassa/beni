//! The `node` platform's Zig (docs/design/boundary.md §9.5): the `ssr`
//! markup lowering, which renders a view to a string of HTML
//! (backend.md §15.6).

const beni_markup = @import("beni_markup");

pub const lowerings = [_]beni_markup.Lowering{@import("ssr.zig").lowering};
