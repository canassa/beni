//! What the checker was looking at when it made an equality: the category
//! every diagnostic text picks its sentences by (checker.md §8). Shared by
//! the constraint generator and by `Diagnostics.zig`'s texts.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");

/// What the compiler was looking at when it made an equality. Carried on
/// every node because it costs one byte plus one word and is the difference
/// between "TYPE MISMATCH" and a sentence a person can act on.
pub const Category = struct {
    tag: Tag = .general,
    /// A 1-based position (`call_arg`, `list_entry`, `case_branch`,
    /// `tuple_element`, `ctor_arg`) or a field `Symbol` (`record_field`,
    /// `field_access`, `record_update`), by tag.
    ///
    /// A field tag with `no_field` is about the record as a whole. The
    /// sentinel cannot be 0: `Symbol` 0 is the first `InternPool.WellKnown`
    /// name, which is `main` — so overloading 0 made a record field
    /// actually named `main`, the likeliest field name in an Elm-like
    /// program, render as an empty name.
    index: u32 = 0,
    /// The instruction the sentence is ABOUT, when that is not the one the
    /// span points at: an argument mismatch underlines the argument but has
    /// to name the function, and the function is only reachable from the
    /// call. `.none` means "the region itself".
    owner: Bir.Inst.OptionalIndex = .none,

    /// `index` on a field-carrying tag when the message is about the record
    /// and not one of its fields. `Symbol.Optional`'s own sentinel, so the
    /// two agree.
    pub const no_field: u32 = std.math.maxInt(u32);

    pub const Tag = enum(u8) {
        general,
        /// A declaration's body against its own annotation.
        annotation,
        /// A `let` binding's body against its annotation.
        let_annotation,
        call_arg,
        list_entry,
        case_branch,
        case_pattern,
        record_field,
        field_access,
        record_update,
        interp_part,
        tuple_element,
        try_value,
        pattern,
        ctor_arg,
        /// The value side of a `let pattern = value`.
        destructure,
        schema_conversion,
        /// A requirement that came from a `where` clause, checked
        /// against the method type it resolved to (checker-v2.md §9.2).
        where_clause,
        /// A markup attribute's value against its declared type
        /// (checker-v2.md §25.3); `index` the attribute's name `Symbol`.
        markup_attribute,
        /// A `class` or `style` value against the form its type chose
        /// (§25.4); `index` the attribute's name `Symbol`.
        markup_list_attribute,
        /// An event's handler against the form its type chose (§25.4);
        /// `index` the event's name `Symbol`.
        markup_handler,
        /// A `For`'s or `Show`'s own attribute; `index` a `FormAttribute`.
        markup_form,
        /// A `For` row or a `Show` body against the function the form
        /// calls; `index` 0 for `For`, 1 for `Show`.
        markup_row,
        /// Markup in a hole, whose messages must be the root's.
        markup_child,
    };
};

/// Which attribute of `For` or `Show` a `markup_form` category is about.
pub const FormAttribute = enum(u32) { each, when, fallback, keyed };
