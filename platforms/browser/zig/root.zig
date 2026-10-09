//! The `browser` platform's Zig (docs/design/boundary.md §9.5): the `dom`
//! markup lowering, which compiles a view into templates the page clones
//! and patches (backend.md §15.3–§15.5).

const beni_markup = @import("beni_markup");

pub const lowerings = [_]beni_markup.Lowering{@import("dom.zig").lowering};

/// The `dom` lowering's template writer, which `browser-direct`'s `direct`
/// lowering writes its static sites with (`dom.staticTemplate`).
pub const dom = @import("dom.zig");

test {
    _ = @import("dom.zig");
}
