//! Reviewed private typed string-key map; ECMA-262 16th edition (June 2025), §24.1.
//! Entries are an insertion-ordered snapshot of pairs; the values retain identity.
//! Proper native receivers and string keys have no ordinary failure to adapt.
const Operations = @import("Operations.zig");
const source = "https://262.ecma-international.org/16.0/#sec-map-objects";

pub const rows = [_]Operations.Row{
    .{ .source = .ecmascript, .owner = "Map", .member = "constructor", .module = "Browser.Host.Map", .name = "make", .signature = "⊤ → Map String a", .recipe = .map_make, .allowed = Operations.all, .algorithm = source },
    .{ .source = .ecmascript, .owner = "Map", .member = "get", .module = "Browser.Host.Map", .name = "get", .signature = "Map String a, String → Maybe a", .recipe = .map_get, .allowed = Operations.all, .algorithm = source },
    .{ .source = .ecmascript, .owner = "Map", .member = "has", .module = "Browser.Host.Map", .name = "has", .signature = "Map String a, String → Bool", .recipe = .map_has, .allowed = Operations.all, .algorithm = source },
    .{ .source = .ecmascript, .owner = "Map", .member = "set", .module = "Browser.Host.Map", .name = "set", .signature = "Map String a, String, a → ⊤", .recipe = .map_set, .allowed = Operations.all, .algorithm = source },
    .{ .source = .ecmascript, .owner = "Map", .member = "delete", .module = "Browser.Host.Map", .name = "remove", .signature = "Map String a, String → ⊤", .recipe = .map_delete, .allowed = Operations.all, .algorithm = source },
    .{ .source = .ecmascript, .owner = "Map", .member = "entries", .module = "Browser.Host.Map", .name = "entries", .signature = "Map String a → List (String × a)", .recipe = .map_entries, .allowed = Operations.all, .algorithm = source },
};
