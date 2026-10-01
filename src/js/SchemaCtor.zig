//! A tagged schema endpoint's constructor, as the backend sees it
//! (`docs/design/schema.md` §4, §6, *The specialised path, as specified for
//! S4*): where it sits in its family, how many siblings it has, whether it
//! takes its payload, and its name. Both families of one variant are the
//! same JavaScript value — `{$: "Count", a: payload}`, or the bare tag when
//! no variant of the union has a payload — and a schema endpoint never gets
//! integer tags (`Fields.zig`), so this is all a use, a pattern or a derived
//! function needs. `Lower`, `Decision` and `Reach` read it, the way
//! `Exhaustive` reads the same two tables.

const std = @import("std");
const Bir = @import("../bir/Bir.zig");
const Graph = @import("../resolve/Graph.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");

const Symbol = InternPool.Symbol;

pub const Info = struct {
    /// Its position among its family's constructors, source order.
    order: u32,
    /// How many constructors the family has.
    count: u32,
    /// Whether it takes a payload: 0 or 1.
    arity: u32,
    /// Whether any constructor of the family takes one: the representation
    /// is the padded object when it does, the bare tag when not.
    padded: bool,
    /// The variant's name, which is the tag.
    name: Symbol,
    /// The schema's name and the module that declares it.
    schema: Symbol,
    module: Graph.Index,
    /// The declaring module's own instruction or not, for a key.
    ext: bool,
    /// The schema declaration's index in its module, when it is this one's;
    /// the interface's schema index otherwise.
    owner: u32,
};

/// The constructor a `schema_ctor_top` or `ext_schema_ctor` instruction of
/// `bir` (module `module`) names, or null for any other instruction.
pub fn of(bir: *const Bir, module: Graph.Index, interfaces: []const Interface, inst: Bir.Inst.Index) ?Info {
    if (inst.int() >= bir.insts.len) return null;
    const data = bir.instData(inst);
    switch (bir.instTag(inst)) {
        .schema_ctor_top => {
            if (data.lhs >= bir.decls.len) return null;
            const d = bir.decls[data.lhs];
            const variants = taggedVariants(bir, d) orelse return null;
            const ref = Bir.SchemaCtorRef.unpack(data.rhs);
            if (ref.variant >= variants.len) return null;
            var padded = false;
            for (variants) |vi| padded = padded or variantPayload(bir, vi);
            return .{
                .order = ref.variant,
                .count = @intCast(variants.len),
                .arity = @intFromBool(variantPayload(bir, variants[ref.variant])),
                .padded = padded,
                .name = bir.symbol(@enumFromInt(bir.instData(variants[ref.variant]).lhs)),
                .schema = bir.symbol(d.name),
                .module = module,
                .ext = false,
                .owner = data.lhs,
            };
        },
        .ext_schema_ctor => {
            if (data.lhs >= interfaces.len) return null;
            const iface = &interfaces[data.lhs];
            if (data.rhs >= iface.schema_ctors.len) return null;
            const ctor = iface.schema_ctors[data.rhs];
            const si = @intFromEnum(ctor.schema);
            if (si >= iface.schemas.len) return null;
            const schema = iface.schemas[si];
            const from, const to = switch (ctor.endpoint) {
                .type => .{ schema.program_ctors_start, schema.program_ctors_end },
                .encoded => .{ schema.encoded_ctors_start, schema.encoded_ctors_end },
            };
            if (data.rhs < from or data.rhs >= to or to > iface.schema_ctors.len) return null;
            var padded = false;
            for (iface.schema_ctors[from..to]) |sibling| padded = padded or sibling.arity != 0;
            return .{
                .order = data.rhs - from,
                .count = to - from,
                .arity = ctor.arity,
                .padded = padded,
                .name = iface.symbol(ctor.name),
                .schema = iface.symbol(schema.name),
                .module = @enumFromInt(data.lhs),
                .ext = true,
                .owner = si,
            };
        },
        else => return null,
    }
}

/// The variant instructions of a tagged schema declaration, or null for a
/// record schema.
pub fn taggedVariants(bir: *const Bir, d: Bir.Decl) ?[]const Bir.Inst.Index {
    var at = d.schema_body.unwrap() orelse return null;
    var budget = bir.insts.len + 1;
    while (budget > 0 and at.int() < bir.insts.len) : (budget -= 1) switch (bir.instTag(at)) {
        .schema_value, .schema_paren => at = @enumFromInt(bir.instData(at).lhs),
        else => break,
    };
    if (at.int() >= bir.insts.len or bir.instTag(at) != .schema_tagged) return null;
    return bir.extraSlice(bir.subRange(@enumFromInt(bir.instData(at).rhs)), Bir.Inst.Index);
}

pub fn variantPayload(bir: *const Bir, variant: Bir.Inst.Index) bool {
    const v = bir.extraData(@enumFromInt(bir.instData(variant).rhs), Bir.SchemaVariant);
    return v.payload != .none;
}
