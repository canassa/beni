//! One module's typed markup tree (docs/design/boundary.md §9.4.2), built
//! from its `Bir`, the markup section of its dispatch table
//! (checker-v2.md §25.7) and the vocabulary module's interface rows: what
//! the build's markup lowering is handed, and beside it what the compiler
//! keeps to answer the lowering's questions — which instruction each value
//! is, which lambda each row is, which token each node was written at.
//!
//! **A value is a handle.** The lowering never sees the beni code behind an
//! attribute or a hole; each is a slot here, and the compiler evaluates the
//! instruction slots of a root, in the order `language.md` §6 gives, where
//! the program evaluates the root (`js/Lower.zig`). The other slots are
//! reads that evaluate nothing — a captured local, a field path through
//! one, a class list written in place rebuilt from its entries' values, a
//! constant prop — and are spelled where the lowering asks for them.
//!
//! Only the markup of declarations that survive reachability is here, so a
//! lowering meets exactly the roots the build ships.

const std = @import("std");
const Allocator = std.mem.Allocator;
const m = @import("beni_markup");
const Bir = @import("../bir/Bir.zig");
const Dispatch = @import("../check/Dispatch.zig");
const Interface = @import("../resolve/Interface.zig");
const InternPool = @import("../InternPool.zig");

const Inst = Bir.Inst;

pub const Input = struct {
    bir: *const Bir,
    /// The module's index, for the tree's sites.
    module: u32,
    dispatch: *const Dispatch,
    /// The vocabulary module's interface: the rows the dispatch table's
    /// markup section indexes.
    vocabulary: *const Interface,
    interner: *const InternPool.Global,
    /// The declarations that survive, in declaration order.
    live: []const u32,
    /// Every module's interface, indexed by module: whether an imported
    /// value a hole calls is a markup primitive.
    interfaces: []const Interface = &.{},
    /// What an `==` compares, which only the emitter's view of types can
    /// say: no selector is recognised without it (language.md §11.9).
    comparison: ?Comparison = null,
};

/// How an `==` or `/=` compares (language.md §11.9, *a selector*).
pub const Comparison = struct {
    ctx: *anyopaque,
    /// `cmp` is the method call; `other` is its operand that is not the
    /// selector.
    classify: *const fn (ctx: *anyopaque, cmp: Inst.Index, other: Inst.Index) Test,

    pub const Test = union(enum) {
        /// Neither of the two below.
        none,
        /// `===` on the two operands (`strict_eq`).
        strict,
        /// `other` applies this constructor, of one field, and the
        /// comparison is its tag and `===` on that field (backend.md §4).
        ctor: Inst.Index,
    };
};

/// What one value slot stands for.
pub const Value = union(enum) {
    /// An instruction the compiler evaluates where the root is evaluated.
    inst: Inst.Index,
    /// A captured local, read whole.
    capture: u32,
    /// A field path through a captured local: a `Bir.MarkupInput` record.
    input: Bir.ExtraIndex,
    /// A class or style list written in place, as the list: rebuilt from
    /// its entries in `Tree.entries`.
    entries: m.Range,
    /// A prop with no instruction: a quoted value's text, or a bare name.
    string: []const u8,
    true,
    /// A reference to the top-level function a hole calls (`Hole.call`):
    /// spelled wherever it is asked for, and evaluates nothing.
    callee: Inst.Index,
    /// That hole's call, made of its callee's slot and its arguments' —
    /// instruction slots of the root — where it is asked for.
    call: struct { callee: u32, args: m.Value.Range },
    /// A selector's probe (`Row.selector`): the input the `Bir.MarkupInput`
    /// record reads, itself, or — when `ctor` is set — its field when it
    /// is that constructor and itself otherwise.
    probe: struct { input: Bir.ExtraIndex, ctor: Inst.OptionalIndex },
};

/// What the compiler needs to place a row: the lambda, what `lowering`
/// peeled off its body, and the body.
pub const RowSource = struct {
    function: Inst.Index,
    shape: Bir.RowShape,
    lets: Bir.SubRange,
    body: Inst.OptionalIndex,
};

/// What the compiler needs to call a component.
pub const ComponentSource = struct {
    callee: Inst.Index,
    /// The written props, as `Bir.MarkupItem` records.
    props: Bir.SubRange,
};

pub const Built = struct {
    tree: m.Tree,
    /// Parallel to `tree.roots`: the root's instruction, ascending.
    root_insts: []const u32,
    /// Parallel to `tree.nodes`: the token each node was written at.
    node_tokens: []const u32,
    values: []const Value,
    /// Parallel to `tree.rows`.
    rows: []const RowSource,
    /// Parallel to `tree.components`.
    components: []const ComponentSource,
    /// Parallel to `tree.items`: an event's payload extractor, as a value
    /// of the vocabulary module's interface, or `Dispatch.Markup.no_row`.
    extractors: []const u32,

    /// The root whose instruction is `inst`.
    pub fn rootAt(b: *const Built, inst: u32) ?m.Root.Index {
        var lo: usize = 0;
        var hi: usize = b.root_insts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (b.root_insts[mid] < inst) lo = mid + 1 else hi = mid;
        }
        if (lo < b.root_insts.len and b.root_insts[lo] == inst) return @fromBackingInt(@intCast(lo));
        return null;
    }
};

/// Build the tree of every markup root in `input.live`'s declarations.
/// Null when there is none. Everything is allocated in `arena`.
pub fn build(arena: Allocator, input: Input) Allocator.Error!?Built {
    var b: Builder = .{ .arena = arena, .in = input };
    try b.sortRows();
    try b.findRoots();
    if (b.root_insts.items.len == 0) return null;
    // A markup root's slot in `roots` is its instruction's rank, fixed
    // before any is built, because a row finds its body's root by it.
    b.roots = try arena.alloc(m.Root, b.root_insts.items.len);
    for (0..b.roots.len) |i| try b.buildRoot(@intCast(i), @fromBackingInt(@intCast(b.root_insts.items[i])));
    try b.lambdaRoots();
    try b.selectors();
    const item_only = try b.itemOnly();
    const constant = try b.constants();
    return .{
        .tree = .{
            .roots = b.roots,
            .rows = b.tree_rows.items,
            .nodes = b.nodes.items,
            .elements = b.elements.items,
            .fragments = b.fragments.items,
            .texts = b.texts.items,
            .holes = b.holes.items,
            .components = b.components.items,
            .fors = b.fors.items,
            .shows = b.shows.items,
            .items = b.items.items,
            .entries = b.entries.items,
            .props = b.props.items,
            .children = b.children.items,
            .strings = .{ .bytes = b.string_bytes.items, .spans = b.spans.items },
            .vocabulary = .{
                .elements = b.element_facts.items,
                .attributes = b.attribute_facts.items,
                .events = b.event_facts.items,
            },
            .requires = m.gated,
            .item_only = item_only,
            .constant = constant,
        },
        .root_insts = b.root_insts.items,
        .node_tokens = b.node_tokens.items,
        .values = b.values.items,
        .rows = b.row_sources.items,
        .components = b.component_sources.items,
        .extractors = b.extractors.items,
    };
}

const Builder = struct {
    arena: Allocator,
    in: Input,
    /// The dispatch table's markup rows, by record: a record's index in
    /// `Bir.extra` is unique in the module.
    by_node: []const Dispatch.Markup = &.{},
    root_insts: std.ArrayList(u32) = .empty,
    /// Per root instruction that is the body of a row compiled in place,
    /// the row: marks it `row_markup`.
    row_bodies: std.ArrayList(u32) = .empty,
    /// The `lambda` rows, each a `row_lambda` root of its own once every
    /// markup root is built.
    pending_lambdas: std.ArrayList(u32) = .empty,
    roots: []m.Root = &.{},
    tree_rows: std.ArrayList(m.Row) = .empty,
    row_sources: std.ArrayList(RowSource) = .empty,
    nodes: std.ArrayList(m.Node) = .empty,
    node_tokens: std.ArrayList(u32) = .empty,
    elements: std.ArrayList(m.Element) = .empty,
    fragments: std.ArrayList(m.Fragment) = .empty,
    texts: std.ArrayList(m.Text) = .empty,
    holes: std.ArrayList(m.Hole) = .empty,
    components: std.ArrayList(m.Component) = .empty,
    component_sources: std.ArrayList(ComponentSource) = .empty,
    fors: std.ArrayList(m.For) = .empty,
    shows: std.ArrayList(m.Show) = .empty,
    items: std.ArrayList(m.Item) = .empty,
    /// Parallel to `items`: an event's payload extractor, as a value of the
    /// vocabulary module's interface, or `Dispatch.Markup.no_row`.
    extractors: std.ArrayList(u32) = .empty,
    entries: std.ArrayList(m.Entry) = .empty,
    props: std.ArrayList(m.Prop) = .empty,
    children: std.ArrayList(m.Node.Index) = .empty,
    values: std.ArrayList(Value) = .empty,
    string_bytes: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(m.Strings.Span) = .empty,
    /// The vocabulary rows named, re-indexed densely: per row of the
    /// interface's table, its index here, or `none`.
    element_rows: []u32 = &.{},
    attribute_rows: []u32 = &.{},
    event_rows: []u32 = &.{},
    element_facts: std.ArrayList(m.ElementFacts) = .empty,
    attribute_facts: std.ArrayList(m.AttributeFacts) = .empty,
    event_facts: std.ArrayList(m.EventFacts) = .empty,

    /// Per declaration, once the selector search walked it, each
    /// instruction's parent (`parentsOf`); empty until the first.
    parent_maps: []?[]const Parent = &.{},

    const none = std.math.maxInt(u32);

    fn bir(b: *const Builder) *const Bir {
        return b.in.bir;
    }

    fn sortRows(b: *Builder) !void {
        const rows = try b.arena.dupe(Dispatch.Markup, b.in.dispatch.markup);
        std.mem.sort(Dispatch.Markup, rows, {}, struct {
            fn lessThan(_: void, x: Dispatch.Markup, y: Dispatch.Markup) bool {
                return x.node < y.node;
            }
        }.lessThan);
        b.by_node = rows;
        b.element_rows = try b.arena.alloc(u32, b.in.vocabulary.elements.len);
        @memset(b.element_rows, none);
        b.attribute_rows = try b.arena.alloc(u32, b.in.vocabulary.attributes.len);
        @memset(b.attribute_rows, none);
        b.event_rows = try b.arena.alloc(u32, b.in.vocabulary.events.len);
        @memset(b.event_rows, none);
    }

    /// The dispatch row of the record at `node`, if the checker wrote one.
    fn rowOf(b: *const Builder, record: u32) ?Dispatch.Markup {
        var lo: usize = 0;
        var hi: usize = b.by_node.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (b.by_node[mid].node < record) lo = mid + 1 else hi = mid;
        }
        if (lo < b.by_node.len and b.by_node[lo].node == record) return b.by_node[lo];
        return null;
    }

    /// Every markup instruction of a surviving declaration, ascending, and
    /// which of them are the bodies of rows compiled in place.
    fn findRoots(b: *Builder) !void {
        const tags = b.bir().insts.items(.tag);
        for (b.in.live) |index| {
            const d = b.bir().decls[index];
            if (!d.kind.isValue()) continue;
            for (d.inst_start.int()..d.inst_end.int()) |i| {
                if (tags[i] != .markup) continue;
                try b.root_insts.append(b.arena, @intCast(i));
            }
        }
        std.mem.sort(u32, b.root_insts.items, {}, std.sort.asc(u32));
    }

    fn rootIndexOf(b: *const Builder, inst: u32) ?u32 {
        const found = std.sort.binarySearch(u32, b.root_insts.items, inst, struct {
            fn order(key: u32, item: u32) std.math.Order {
                return std.math.order(key, item);
            }
        }.order) orelse return null;
        return @intCast(found);
    }

    fn buildRoot(b: *Builder, index: u32, inst: Inst.Index) !void {
        const start: u32 = @intCast(b.values.items.len);
        // A root that is the body of a row compiled in place is placed by
        // the lowering in the row's function; every other one is evaluated
        // where it stands.
        const top = try b.node(@fromBackingInt(@intCast(b.bir().instData(inst).lhs)));
        b.roots[index] = .{
            .site = .{ .module = b.in.module, .inst = inst.int() },
            .kind = if (std.mem.indexOfScalar(u32, b.row_bodies.items, inst.int()) != null) .row_markup else .expression,
            .node = top,
            .values = .{ .start = start, .len = @as(u32, @intCast(b.values.items.len)) - start },
        };
    }

    /// Each `lambda` row's root, after every markup root: one value, the
    /// lambda's body, which is the row's result. Its instruction is past
    /// every markup root's, so `root_insts` stays ascending.
    fn lambdaRoots(b: *Builder) !void {
        const pending = b.pending_lambdas.items;
        if (pending.len == 0) return;
        const grown = try b.arena.alloc(m.Root, b.roots.len + pending.len);
        @memcpy(grown[0..b.roots.len], b.roots);
        for (pending, b.roots.len..) |row_index, at| {
            const start: u32 = @intCast(b.values.items.len);
            _ = try b.value(.{ .inst = b.row_sources.items[row_index].body.unwrap().? });
            grown[at] = .{
                .site = b.tree_rows.items[row_index].site,
                .kind = .row_lambda,
                .node = .none,
                .values = .{ .start = start, .len = 1 },
            };
            try b.root_insts.append(b.arena, none);
            b.tree_rows.items[row_index].body = @fromBackingInt(@intCast(at));
        }
        b.roots = grown;
    }

    fn value(b: *Builder, v: Value) !m.Value.Index {
        const at: u32 = @intCast(b.values.items.len);
        try b.values.append(b.arena, v);
        return @fromBackingInt(@intCast(at));
    }

    fn string(b: *Builder, bytes: []const u8) !m.Strings.Index {
        const at: u32 = @intCast(b.spans.items.len);
        try b.spans.append(b.arena, .{ .start = @intCast(b.string_bytes.items.len), .len = @intCast(bytes.len) });
        try b.string_bytes.appendSlice(b.arena, bytes);
        return @fromBackingInt(@intCast(at));
    }

    fn symbolText(b: *const Builder, s: Bir.SymbolIndex) []const u8 {
        return b.in.interner.slice(b.bir().symbol(s));
    }

    fn ifaceText(b: *const Builder, s: Interface.SymbolIndex) []const u8 {
        return b.in.interner.slice(b.in.vocabulary.symbols[@backingInt(s)]);
    }

    fn addNode(b: *Builder, kind: m.Node.Kind, payload: usize, token: u32) !m.Node.Index {
        const at: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(b.arena, .{ .kind = kind, .payload = @intCast(payload) });
        try b.node_tokens.append(b.arena, token);
        return @fromBackingInt(@intCast(at));
    }

    fn childList(b: *Builder, start: Bir.ExtraIndex, end: Bir.ExtraIndex) !m.Range {
        const records = b.bir().extraSlice(.{ .start = start, .end = end }, Bir.ExtraIndex);
        // The children's own nodes first, depth first, so the range of
        // this list's indices is contiguous in `children`.
        const indices = try b.arena.alloc(m.Node.Index, records.len);
        for (records, indices) |r, *slot| slot.* = try b.node(r);
        const range_start: u32 = @intCast(b.children.items.len);
        try b.children.appendSlice(b.arena, indices);
        return .{ .start = range_start, .len = @intCast(indices.len) };
    }

    fn node(b: *Builder, at: Bir.ExtraIndex) Allocator.Error!m.Node.Index {
        const bir_ = b.bir();
        switch (bir_.markupKind(at)) {
            .element => {
                const e = bir_.extraData(at, Bir.MarkupElement);
                const row = b.rowOf(@backingInt(at));
                const element_row = if (row) |r| try b.elementRow(r.row, b.symbolText(e.name)) else .none;
                const items = try b.itemList(e.items_start, e.items_end);
                const children = try b.childList(e.children_start, e.children_end);
                try b.elements.append(b.arena, .{ .row = element_row, .items = items, .children = children });
                return b.addNode(.element, b.elements.items.len - 1, e.token);
            },
            .fragment => {
                const f = bir_.extraData(at, Bir.MarkupFragment);
                const children = try b.childList(f.children_start, f.children_end);
                try b.fragments.append(b.arena, .{ .children = children });
                return b.addNode(.fragment, b.fragments.items.len - 1, f.token);
            },
            .text => {
                const t = bir_.extraData(at, Bir.MarkupText);
                try b.texts.append(b.arena, .{ .text = try b.string(b.symbolText(t.text)) });
                return b.addNode(.text, b.texts.items.len - 1, t.token);
            },
            .hole => {
                const h = bir_.extraData(at, Bir.MarkupHole);
                const kind: m.HoleKind = if (b.rowOf(@backingInt(at))) |r| @fromBackingInt(@intCast(r.detail)) else .html;
                if (kind == .html) if (b.helperCallee(h.value)) |callee| {
                    // The arguments are the root's values, evaluated where
                    // the call's would have been; the call is made where
                    // the lowering asks for the hole's value (§11.6).
                    const d = bir_.instData(h.value);
                    const args = bir_.extraSlice(bir_.subRange(@fromBackingInt(@intCast(d.rhs))), Inst.Index);
                    const args_start: u32 = @intCast(b.values.items.len);
                    for (args) |arg| _ = try b.value(.{ .inst = arg });
                    const range: m.Value.Range = .{ .start = args_start, .len = @intCast(args.len) };
                    const callee_value = try b.value(.{ .callee = callee });
                    const call = try b.value(.{ .call = .{ .callee = @backingInt(callee_value), .args = range } });
                    try b.holes.append(b.arena, .{ .value = call, .kind = kind, .call = .{ .callee = callee_value, .args = range } });
                    return b.addNode(.hole, b.holes.items.len - 1, h.token);
                };
                try b.holes.append(b.arena, .{ .value = try b.value(.{ .inst = h.value }), .kind = kind });
                return b.addNode(.hole, b.holes.items.len - 1, h.token);
            },
            .component => {
                const c = bir_.extraData(at, Bir.MarkupComponent);
                const spread: ?m.Value.Index = if (c.spread.unwrap()) |s| try b.value(.{ .inst = s }) else null;
                const props_start: u32 = @intCast(b.props.items.len);
                for (bir_.extraSlice(.{ .start = c.props_start, .end = c.props_end }, Bir.ExtraIndex)) |item_at| {
                    const item = bir_.extraData(item_at, Bir.MarkupItem);
                    if (item.kind == .spread) continue;
                    const v: Value = if (item.constant != .none and item.value == .none)
                        (if (item.constant == .string) Value{ .string = b.bir().string_bytes[item.constant_offset..][0..item.constant_len] } else Value.true)
                    else if (item.value.unwrap()) |vi| .{ .inst = vi } else .true;
                    try b.props.append(b.arena, .{ .field = try b.string(b.symbolText(item.name)), .value = try b.value(v) });
                }
                const props: m.Range = .{ .start = props_start, .len = @as(u32, @intCast(b.props.items.len)) - props_start };
                var children_value: ?m.Value.Index = null;
                var children_nodes: m.Range = .{ .start = 0, .len = 0 };
                switch (c.children_form) {
                    .absent => {},
                    .hole => {
                        const records = bir_.extraSlice(.{ .start = c.children_start, .end = c.children_end }, Bir.ExtraIndex);
                        for (records) |r| {
                            if (bir_.markupKind(r) != .hole) continue;
                            children_value = try b.value(.{ .inst = bir_.extraData(r, Bir.MarkupHole).value });
                        }
                    },
                    .fragment => children_nodes = try b.childList(c.children_start, c.children_end),
                }
                try b.components.append(b.arena, .{ .props = props, .spread = spread, .children = children_value, .children_nodes = children_nodes });
                try b.component_sources.append(b.arena, .{ .callee = c.callee, .props = .{ .start = c.props_start, .end = c.props_end } });
                return b.addNode(.component, b.components.items.len - 1, c.token);
            },
            .@"for", .show => {
                const is_for = bir_.markupKind(at) == .@"for";
                const f = bir_.extraData(at, Bir.MarkupForm);
                const row = b.rowOf(@backingInt(at));
                const list = try b.value(.{ .inst = f.list.unwrap().? });
                const key: ?m.Value.Index = if (f.mode == .key_function) try b.value(.{ .inst = f.keyed.unwrap().? }) else null;
                const fallback: ?m.Value.Index = if (f.fallback.unwrap()) |v| try b.value(.{ .inst = v }) else null;
                const arity: u8 = if (row) |r| @max(r.arity, 1) else 1;
                const row_index = try b.formRow(f.row, arity);
                if (is_for) {
                    try b.fors.append(b.arena, .{
                        .each = list,
                        .fallback = fallback,
                        .mode = if (row) |r| @fromBackingInt(@intCast(r.detail)) else .reference,
                        .key = key,
                        .item_is_primitive = if (row) |r| r.primitive else false,
                        .row = row_index,
                    });
                    return b.addNode(.for_, b.fors.items.len - 1, f.token);
                }
                try b.shows.append(b.arena, .{
                    .when = list,
                    .fallback = fallback,
                    .mode = if (row) |r| @fromBackingInt(@intCast(r.detail)) else .identity,
                    .key = key,
                    .value_is_primitive = if (row) |r| r.primitive else false,
                    .body = row_index,
                });
                return b.addNode(.show, b.shows.items.len - 1, f.token);
            },
        }
    }

    // ---- Selectors (language.md §11.9, backend.md §15.5) -----------------
    //
    // A keyed `markup` row's input is a selector when every read of it in
    // the row — through field accesses, and into the same-module functions
    // it is passed to, as the row's inputs are followed — is one operand of
    // an `==` or `/=` whose other operand is the row's list key: the key
    // function's field path written through the row's item, or a
    // one-field constructor applied to it, compared as `===` or as a tag
    // and a `===` field (`Input.comparison`). Anything else — a read inside
    // the input, a `let`, a `case`, a record, another module's function, a
    // key that is not the list key — and the row has no selector, which is
    // always correct: a selector only lets a render skip more rows.

    /// A field (`Bir` symbol) or a tuple slot, one step of a path.
    const Link = u64;
    const tuple_bit: Link = 1 << 32;
    const max_links = 8;

    const Path = struct {
        len: u8 = 0,
        links: [max_links]Link = undefined,

        fn append(p: Path, l: Link) ?Path {
            if (p.len == max_links) return null;
            var q = p;
            q.links[q.len] = l;
            q.len += 1;
            return q;
        }

        fn slice(p: *const Path) []const Link {
            return p.links[0..p.len];
        }

        fn eql(p: Path, q: Path) bool {
            return std.mem.eql(Link, p.slice(), q.slice());
        }
    };

    /// A local of the frame being searched that reads the selector's
    /// captured local (`item` false) or the row's item (`item` true)
    /// through `path`.
    const Bind = struct { local: u32, item: bool, path: Path };

    const Parent = struct { inst: u32 = none, pos: u32 = 0 };

    const Hunt = struct {
        /// The input's path through its captured local.
        target: Path,
        /// The list key's path through the item.
        key: Path,
        /// How the comparisons seen so far compare: null before the first.
        strict: ?bool = null,
        /// The constructor they compare against, when not strict.
        ctor: ?Inst.Index = null,
        /// Frames searched, bounded so a deep or recursive helper chain
        /// gives up rather than costs.
        frames: u32 = 0,
    };

    const max_frames = 64;
    const max_depth = 8;

    fn selectors(b: *Builder) Allocator.Error!void {
        if (b.in.comparison == null) return;
        const bir_ = b.bir();
        for (b.fors.items) |f| {
            const row_index = @backingInt(f.row);
            const row = &b.tree_rows.items[row_index];
            if (row.kind != .markup or row.inputs.len == 0) continue;
            const key: Path = switch (f.mode) {
                .reference => .{},
                .key => b.keyPath(f.key orelse continue) orelse continue,
                else => continue,
            };
            const source = b.row_sources.items[row_index];
            const decl = b.declOf(source.function.int()) orelse continue;
            const lambda = bir_.instData(source.function);
            const params = bir_.extraSlice(bir_.subRange(@fromBackingInt(@intCast(lambda.lhs))), Inst.Index);
            if (params.len == 0) continue;
            // The row function's instructions: the run from the lowest its
            // operands reach to the function itself, as `readsOnly` finds
            // an expression's, so an operand the walk did not know is
            // still searched.
            var walked: std.ArrayList(u32) = .empty;
            try b.subtree(source.function, &walked);
            var lo = source.function.int();
            for (walked.items) |i| lo = @min(lo, i);
            var frame: std.ArrayList(u32) = .empty;
            for (lo..source.function.int() + 1) |i| try frame.append(b.arena, @intCast(i));
            for (0..row.inputs.len) |k| {
                const record = switch (b.values.items[row.inputs.start + k]) {
                    .input => |r| r,
                    else => continue,
                };
                const input = bir_.extraData(record, Bir.MarkupInput);
                var target: Path = .{};
                for (0..input.len) |j| target = target.append(b.inputLink(input.link(j))) orelse break;
                if (target.len != input.len) continue;
                var env: std.ArrayList(Bind) = .empty;
                try env.append(b.arena, .{ .local = input.local, .item = false, .path = .{} });
                _ = try b.bindPattern(&env, decl, params[0].int(), true, .{});
                var search: Hunt = .{ .target = target, .key = key };
                if (!try b.hunt(&search, decl, frame.items, env.items, 0)) continue;
                if (search.strict == null) continue;
                const probe = try b.value(.{ .probe = .{
                    .input = record,
                    .ctor = if (search.ctor) |c| c.toOptional() else .none,
                } });
                row.selector = .{ .input = @intCast(k), .probe = probe };
                break;
            }
        }
    }

    fn inputLink(b: *const Builder, link: u32) Link {
        if (link & Bir.tuple_link != 0) return tuple_bit | (link & ~Bir.tuple_link);
        return @backingInt(b.bir().symbols[link]);
    }

    /// The declaration an instruction belongs to.
    fn declOf(b: *const Builder, inst: u32) ?u32 {
        for (b.bir().decls, 0..) |d, i| {
            if (d.inst_start.int() <= inst and inst < d.inst_end.int()) return @intCast(i);
        }
        return null;
    }

    /// A key function's path through its item: `\r -> r.a.b`, or `.a`.
    fn keyPath(b: *Builder, v: m.Value.Index) ?Path {
        const bir_ = b.bir();
        const inst = switch (b.values.items[@backingInt(v)]) {
            .inst => |i| i,
            else => return null,
        };
        if (bir_.instTag(inst) != .lambda) return null;
        const d = bir_.instData(inst);
        const params = bir_.extraSlice(bir_.subRange(@fromBackingInt(@intCast(d.lhs))), Inst.Index);
        if (params.len != 1 or bir_.instTag(params[0]) != .pat_var) return null;
        const env = [_]Bind{.{ .local = bir_.instData(params[0]).lhs, .item = true, .path = .{} }};
        return b.itemPath(d.rhs, &env);
    }

    /// The path through the row's item `inst` reads — a local bound to it,
    /// then field and tuple accesses — or null when it reads anything else.
    fn itemPath(b: *const Builder, inst: u32, env: []const Bind) ?Path {
        const bir_ = b.bir();
        const tags = bir_.insts.items(.tag);
        const datas = bir_.insts.items(.data);
        var links: [max_links]Link = undefined;
        var n: usize = 0;
        var cur = inst;
        while (true) : (cur = datas[cur].lhs) {
            const link: Link = switch (tags[cur]) {
                .field_access => @backingInt(bir_.symbols[datas[cur].rhs]),
                .tuple_index => tuple_bit | datas[cur].rhs,
                else => break,
            };
            if (n == max_links) return null;
            links[n] = link;
            n += 1;
        }
        if (tags[cur] != .local) return null;
        const bind = for (env) |e| {
            if (e.local == datas[cur].lhs) break e;
        } else return null;
        if (!bind.item) return null;
        var path = bind.path;
        while (n > 0) {
            n -= 1;
            path = path.append(links[n]) orelse return null;
        }
        return path;
    }

    /// Bind the locals `pattern` (of declaration `decl`) binds to `path`
    /// through the item or the captured local. False for a pattern whose
    /// locals it cannot follow; an item's are then simply not bound, so
    /// no comparison against them is its key.
    fn bindPattern(b: *Builder, env: *std.ArrayList(Bind), decl: u32, pattern: u32, item: bool, path: Path) Allocator.Error!bool {
        const bir_ = b.bir();
        const d = bir_.instData(@fromBackingInt(@intCast(pattern)));
        switch (bir_.instTag(@fromBackingInt(@intCast(pattern)))) {
            .pat_var => try env.append(b.arena, .{ .local = d.lhs, .item = item, .path = path }),
            .pat_wild => {},
            .pat_record => {
                const base = bir_.decls[decl].locals_start;
                for (bir_.extraSlice(Bir.inlineRange(d), u32)) |local| {
                    if (base + local >= bir_.locals.len) return item;
                    const name = bir_.locals[base + local].name.unwrap() orelse return item;
                    const field = path.append(@backingInt(bir_.symbols[name])) orelse return item;
                    try env.append(b.arena, .{ .local = local, .item = item, .path = field });
                }
            },
            else => return item,
        }
        return true;
    }

    /// Every instruction's parent in declaration `decl`, and the operand
    /// position it has there.
    fn parentsOf(b: *Builder, decl: u32) Allocator.Error![]const Parent {
        if (b.parent_maps.len == 0) {
            b.parent_maps = try b.arena.alloc(?[]const Parent, b.bir().decls.len);
            @memset(b.parent_maps, null);
        }
        if (b.parent_maps[decl]) |p| return p;
        const d = b.bir().decls[decl];
        const base = d.inst_start.int();
        const map = try b.arena.alloc(Parent, d.inst_end.int() - base);
        @memset(map, .{});
        var found: std.ArrayList(u32) = .empty;
        for (base..d.inst_end.int()) |i| {
            found.clearRetainingCapacity();
            try b.operands(@intCast(i), &found);
            for (found.items, 0..) |o, pos| {
                if (o >= base and o < d.inst_end.int()) map[o - base] = .{ .inst = @intCast(i), .pos = @intCast(pos) };
            }
        }
        b.parent_maps[decl] = map;
        return map;
    }

    /// Whether every read of the selector in `insts` (of `decl`, its
    /// locals bound by `env`) is a comparison with the list key.
    fn hunt(b: *Builder, h: *Hunt, decl: u32, insts: []const u32, env: []const Bind, depth: u32) Allocator.Error!bool {
        h.frames += 1;
        if (depth > max_depth or h.frames > max_frames) return false;
        const bir_ = b.bir();
        const tags = bir_.insts.items(.tag);
        const datas = bir_.insts.items(.data);
        const parents = try b.parentsOf(decl);
        const base = bir_.decls[decl].inst_start.int();
        for (insts) |i| {
            if (tags[i] != .local) continue;
            const bind = for (env) |e| {
                if (e.local == datas[i].lhs) break e;
            } else continue;
            if (bind.item) continue;
            // Up through the accesses, to where the value read is used.
            var top = i;
            var path = bind.path;
            while (true) {
                const p = parents[top - base];
                if (p.inst == none or p.pos != 0) break;
                path = switch (tags[p.inst]) {
                    .field_access => path.append(@backingInt(bir_.symbols[datas[p.inst].rhs])),
                    .tuple_index => path.append(tuple_bit | datas[p.inst].rhs),
                    else => break,
                } orelse return false;
                top = p.inst;
            }
            const at = parents[top - base];
            const shorter = @min(path.len, h.target.len);
            if (!std.mem.eql(Link, path.slice()[0..shorter], h.target.slice()[0..shorter])) continue;
            if (path.len > h.target.len) return false;
            if (at.inst == none) return false;
            if (path.len == h.target.len and tags[at.inst] == .method_call) {
                if (!b.compared(h, at, env)) return false;
            } else if (!try b.passed(h, at, path, env, depth)) return false;
        }
        return true;
    }

    /// The selector's read is operand `at.pos` of `at.inst`: an `==` or
    /// `/=` against the list key.
    fn compared(b: *Builder, h: *Hunt, at: Parent, env: []const Bind) bool {
        const bir_ = b.bir();
        const tags = bir_.insts.items(.tag);
        const datas = bir_.insts.items(.data);
        if (tags[at.inst] != .method_call or at.pos > 1) return false;
        const d = datas[at.inst];
        const mc = bir_.extraData(@fromBackingInt(@intCast(d.rhs)), Bir.MethodCall);
        if (mc.origin != .eq and mc.origin != .neq) return false;
        const args = bir_.extraSlice(.{ .start = mc.args_start, .end = mc.args_end }, Inst.Index);
        if (args.len != 1) return false;
        const other: u32 = if (at.pos == 0) args[0].int() else d.lhs;
        const c = b.in.comparison.?;
        const operand: u32 = switch (c.classify(c.ctx, @fromBackingInt(@intCast(at.inst)), @fromBackingInt(@intCast(other)))) {
            .none => return false,
            .strict => blk: {
                if (h.strict == false) return false;
                h.strict = true;
                break :blk other;
            },
            .ctor => |ctor| blk: {
                if (h.strict == true or tags[other] != .call or datas[other].lhs != ctor.int()) return false;
                const fields = bir_.extraSlice(bir_.subRange(@fromBackingInt(@intCast(datas[other].rhs))), Inst.Index);
                if (fields.len != 1) return false;
                if (h.ctor) |first| {
                    if (tags[first.int()] != tags[ctor.int()] or datas[first.int()].lhs != datas[ctor.int()].lhs or
                        datas[first.int()].rhs != datas[ctor.int()].rhs) return false;
                } else h.ctor = ctor;
                h.strict = false;
                break :blk fields[0].int();
            },
        };
        const key = b.itemPath(operand, env) orelse return false;
        return key.eql(h.key);
    }

    /// A read of a record holding the selector is argument `at.pos` of
    /// `at.inst`: a saturated call of a function of this module, whose
    /// body is searched with its parameters bound.
    fn passed(b: *Builder, h: *Hunt, at: Parent, path: Path, env: []const Bind, depth: u32) Allocator.Error!bool {
        const bir_ = b.bir();
        const tags = bir_.insts.items(.tag);
        const datas = bir_.insts.items(.data);
        if (tags[at.inst] != .call or at.pos == 0) return false;
        const callee = datas[at.inst].lhs;
        if (tags[callee] != .top) return false;
        const f = datas[callee].lhs;
        if (f >= bir_.decls.len) return false;
        const fd = bir_.decls[f];
        if (fd.kind != .value) return false;
        const args = bir_.extraSlice(bir_.subRange(@fromBackingInt(@intCast(datas[at.inst].rhs))), Inst.Index);
        const params = bir_.extraSlice(.{ .start = fd.params_start, .end = fd.params_end }, Inst.Index);
        if (args.len != params.len or at.pos - 1 >= params.len) return false;
        var inner: std.ArrayList(Bind) = .empty;
        for (args, params, 0..) |arg, param, k| {
            if (k == at.pos - 1) {
                if (!try b.bindPattern(&inner, f, param.int(), false, path)) return false;
            } else if (b.itemPath(arg.int(), env)) |through| {
                _ = try b.bindPattern(&inner, f, param.int(), true, through);
            }
        }
        var body: std.ArrayList(u32) = .empty;
        for (fd.inst_start.int()..fd.inst_end.int()) |i| try body.append(b.arena, @intCast(i));
        return b.hunt(h, f, body.items, inner.items, depth + 1);
    }

    // ---- Values that are the same on every evaluation (boundary.md §9.4.6, 1.4)
    //
    // A literal, a constructor of no fields — one shared object, a bare tag
    // or a boolean (backend.md §4) — and a reference to a top-level value
    // or function: none can be a different JavaScript value on the next
    // render, so a lowering need not keep or compare it.

    fn constants(b: *Builder) Allocator.Error![]const bool {
        const out = try b.arena.alloc(bool, b.values.items.len);
        for (b.values.items, out) |v, *c| c.* = switch (v) {
            .inst => |inst| b.constantInst(inst),
            .string, .true, .callee => true,
            else => false,
        };
        return out;
    }

    fn constantInst(b: *const Builder, inst: Inst.Index) bool {
        const bir_ = b.bir();
        const d = bir_.instData(inst);
        return switch (bir_.instTag(inst)) {
            .int, .float, .char, .string => true,
            .top => d.lhs < bir_.decls.len and bir_.decls[d.lhs].kind.isValue(),
            .ext_value => true,
            .ctor => blk: {
                if (d.lhs >= bir_.ctors.len) break :blk false;
                const c = bir_.ctors[d.lhs];
                break :blk Bir.SubRange.len(.{ .start = c.args_start, .end = c.args_end }) == 0;
            },
            .ext_ctor => d.lhs < b.in.interfaces.len and d.rhs < b.in.interfaces[d.lhs].ctors.len and
                b.in.interfaces[d.lhs].ctors[d.rhs].arity == 0,
            else => false,
        };
    }

    // ---- Values that read only the item (language.md §11.11) -------------
    //
    // A value of a `markup` row's root is item-only when every local its
    // expression reads is bound inside that expression or by the row's
    // item pattern: no capture, no `let` the row peeled off, no position.
    // It is then the same whenever the item is, so a lowering may leave it,
    // and what it writes, alone on a patch whose item did not change.
    //
    // The expression's instructions are found twice, and a local must pass
    // both: by its operands, and as the contiguous run from the lowest of
    // those to the value itself, which is how lowering lays an expression
    // out. An operand the walk did not know would still be in the run.

    fn itemOnly(b: *Builder) Allocator.Error![]const bool {
        const out = try b.arena.alloc(bool, b.values.items.len);
        @memset(out, false);
        const bir_ = b.bir();
        for (b.tree_rows.items, b.row_sources.items) |row, source| {
            if (row.kind != .markup) continue;
            const f = source.function.int();
            const decl = for (bir_.decls) |d| {
                if (d.inst_start.int() <= f and f < d.inst_end.int()) break d;
            } else continue;
            const lambda = bir_.instData(source.function);
            const params = bir_.extraSlice(bir_.subRange(@fromBackingInt(@intCast(lambda.lhs))), Inst.Index);
            if (params.len == 0) continue;
            var item: std.ArrayList(u32) = .empty;
            try b.subtree(params[0], &item);
            const body = b.roots[@backingInt(row.body)];
            for (0..body.values.len) |k| {
                const v = body.values.start + k;
                out[v] = switch (b.values.items[v]) {
                    .inst => |inst| try b.readsOnly(decl, inst, item.items),
                    .callee, .string, .true => true,
                    else => false,
                };
            }
            // A helper's call reads what its arguments read.
            for (0..body.values.len) |k| {
                const v = body.values.start + k;
                switch (b.values.items[v]) {
                    .call => |c| {
                        var all = true;
                        for (0..c.args.len) |j| all = all and out[c.args.start + j];
                        out[v] = all;
                    },
                    else => {},
                }
            }
        }
        return out;
    }

    fn readsOnly(b: *Builder, decl: Bir.Decl, inst: Inst.Index, item: []const u32) Allocator.Error!bool {
        const bir_ = b.bir();
        var walked: std.ArrayList(u32) = .empty;
        try b.subtree(inst, &walked);
        var lo = inst.int();
        for (walked.items) |i| lo = @min(lo, i);
        const tags = bir_.insts.items(.tag);
        const datas = bir_.insts.items(.data);
        var i = lo;
        while (i <= inst.int()) : (i += 1) {
            if (tags[i] != .local) continue;
            const local = datas[i].lhs;
            if (decl.locals_start + local >= bir_.locals.len) return false;
            const binder = bir_.locals[decl.locals_start + local].inst.int();
            if (binder >= lo and binder <= inst.int()) continue;
            if (std.mem.indexOfScalar(u32, item, binder) != null) continue;
            return false;
        }
        return true;
    }

    /// Every instruction of the expression or pattern at `root`.
    fn subtree(b: *Builder, root: Inst.Index, out: *std.ArrayList(u32)) Allocator.Error!void {
        var stack: std.ArrayList(u32) = .empty;
        try stack.append(b.arena, root.int());
        while (stack.pop()) |i| {
            try out.append(b.arena, i);
            try b.operands(i, &stack);
        }
    }

    /// The instructions `inst` has as operands (`bir/Lower.zig`'s
    /// `operandsOf`, with a markup item's class and style entries).
    fn operands(b: *Builder, inst: u32, out: *std.ArrayList(u32)) Allocator.Error!void {
        const bir_ = b.bir();
        const d = bir_.insts.items(.data)[inst];
        const extra = bir_.extra;
        switch (bir_.insts.items(.tag)[inst]) {
            .tuple, .list, .interp, .pat_tuple, .pat_list => try out.appendSlice(b.arena, extra[d.lhs..d.rhs]),
            .record => {
                var f = d.lhs;
                while (f < d.rhs) : (f += 2) try out.append(b.arena, extra[f + 1]);
            },
            .record_update => {
                try out.append(b.arena, d.lhs);
                var f = extra[d.rhs];
                while (f < extra[d.rhs + 1]) : (f += 2) try out.append(b.arena, extra[f + 1]);
            },
            .field_access, .tuple_index, .@"try", .pat_as, .pat_spread => try out.append(b.arena, d.lhs),
            .call, .pat_ctor => {
                try out.append(b.arena, d.lhs);
                try out.appendSlice(b.arena, extra[extra[d.rhs]..extra[d.rhs + 1]]);
            },
            .method_call => {
                try out.append(b.arena, d.lhs);
                const mc = bir_.extraData(@fromBackingInt(@intCast(d.rhs)), Bir.MethodCall);
                try out.appendSlice(b.arena, extra[@backingInt(mc.args_start)..@backingInt(mc.args_end)]);
            },
            .type_dispatch => {
                const t = bir_.extraData(@fromBackingInt(@intCast(d.rhs)), Bir.TypeDispatch);
                try out.appendSlice(b.arena, extra[@backingInt(t.args_start)..@backingInt(t.args_end)]);
            },
            .lambda, .let => {
                try out.appendSlice(b.arena, extra[extra[d.lhs]..extra[d.lhs + 1]]);
                try out.append(b.arena, d.rhs);
            },
            .let_def => {
                const def = bir_.extraData(@fromBackingInt(@intCast(d.lhs)), Bir.LetDef);
                try out.appendSlice(b.arena, extra[@backingInt(def.params_start)..@backingInt(def.params_end)]);
                try out.append(b.arena, d.rhs);
            },
            .case => {
                try out.append(b.arena, d.lhs);
                try out.appendSlice(b.arena, extra[extra[d.rhs]..extra[d.rhs + 1]]);
            },
            .let_pattern, .branch => {
                try out.append(b.arena, d.lhs);
                try out.append(b.arena, d.rhs);
            },
            .let_stmt => try out.append(b.arena, d.rhs),
            .markup => {
                var values: std.ArrayList(Inst.Index) = .empty;
                try bir_.markupValues(b.arena, @fromBackingInt(@intCast(d.lhs)), &values);
                for (values.items) |v| try out.append(b.arena, v.int());
                try b.entryValues(@fromBackingInt(@intCast(d.lhs)), out);
            },
            else => {},
        }
    }

    /// The class and style entries' values of the markup tree at `at`.
    fn entryValues(b: *Builder, at: Bir.ExtraIndex, out: *std.ArrayList(u32)) Allocator.Error!void {
        const bir_ = b.bir();
        const items: Bir.SubRange, const children: Bir.SubRange = switch (bir_.markupKind(at)) {
            .element => blk: {
                const e = bir_.extraData(at, Bir.MarkupElement);
                break :blk .{ .{ .start = e.items_start, .end = e.items_end }, .{ .start = e.children_start, .end = e.children_end } };
            },
            .fragment => blk: {
                const f = bir_.extraData(at, Bir.MarkupFragment);
                break :blk .{ .{ .start = f.children_start, .end = f.children_start }, .{ .start = f.children_start, .end = f.children_end } };
            },
            .component => blk: {
                const c = bir_.extraData(at, Bir.MarkupComponent);
                break :blk .{ .{ .start = c.props_start, .end = c.props_end }, .{ .start = c.children_start, .end = c.children_end } };
            },
            else => return,
        };
        for (bir_.extraSlice(items, Bir.ExtraIndex)) |it| {
            const item = bir_.extraData(it, Bir.MarkupItem);
            for (bir_.extraSlice(.{ .start = item.entries_start, .end = item.entries_end }, Bir.ExtraIndex)) |e| {
                try out.append(b.arena, bir_.extraData(e, Bir.MarkupEntry).value.int());
            }
        }
        for (bir_.extraSlice(children, Bir.ExtraIndex)) |c| try b.entryValues(c, out);
    }

    /// The callee of a hole's value when it is a helper call a platform may
    /// skip (language.md §11.6): a call of a top-level function — of any
    /// module, not a constructor, not a markup primitive — whose site passes
    /// no evidence. A local function could capture what its arguments do
    /// not show, and evidence is an argument no identity test sees.
    fn helperCallee(b: *const Builder, inst: Inst.Index) ?Inst.Index {
        const bir_ = b.bir();
        if (bir_.instTag(inst) != .call) return null;
        const callee: Inst.Index = @fromBackingInt(@intCast(bir_.instData(inst).lhs));
        const d = bir_.instData(callee);
        switch (bir_.instTag(callee)) {
            .top => {
                if (d.lhs >= bir_.decls.len) return null;
                const decl = bir_.decls[d.lhs];
                if (!decl.kind.isValue() or decl.kind == .vocab_markup) return null;
            },
            .ext_value => {
                if (d.lhs >= b.in.interfaces.len) return null;
                const iface = &b.in.interfaces[d.lhs];
                if (d.rhs >= iface.values.len or iface.values[d.rhs].is_markup_primitive) return null;
            },
            else => return null,
        }
        for ([_]Inst.Index{ inst, callee }) |at| {
            if (b.in.dispatch.siteOf(at)) |site| {
                if (b.in.dispatch.argsAt(site.evidence).len != 0) return null;
            }
        }
        return callee;
    }

    /// A `For`'s row or a `Show`'s body: its function a value of the
    /// enclosing root when it is called per item, its captures and inputs
    /// values of that root otherwise; its body a root of its own.
    fn formRow(b: *Builder, record: u32, arity: u8) !m.Row.Index {
        const r = b.bir().extraData(@fromBackingInt(@intCast(record)), Bir.MarkupRow);
        const index: u32 = @intCast(b.tree_rows.items.len);
        const site: m.Site = .{ .module = b.in.module, .inst = r.function.int() };
        var row: m.Row = .{
            .site = site,
            .kind = switch (r.shape) {
                .markup => .markup,
                .lambda => .lambda,
                .function => .function,
            },
            .body = @fromBackingInt(@intCast(0)),
            .function = null,
            .arity = arity,
            .reads_index = arity == 2,
            .captures = .{ .start = 0, .len = 0 },
            .inputs = .{ .start = 0, .len = 0 },
        };
        switch (r.shape) {
            .function => {
                const f = try b.value(.{ .inst = r.function });
                row.function = f;
                row.inputs = .{ .start = @backingInt(f), .len = 1 };
            },
            .markup, .lambda => {
                const captures_start: u32 = @intCast(b.values.items.len);
                for (b.bir().extraSlice(.{ .start = r.captures_start, .end = r.captures_end }, u32)) |local| {
                    _ = try b.value(.{ .capture = local });
                }
                row.captures = .{ .start = captures_start, .len = @as(u32, @intCast(b.values.items.len)) - captures_start };
                const inputs_start: u32 = @intCast(b.values.items.len);
                var at = @backingInt(r.inputs_start);
                while (at < @backingInt(r.inputs_end)) : (at += Bir.extraLen(Bir.MarkupInput)) {
                    _ = try b.value(.{ .input = @fromBackingInt(@intCast(at)) });
                }
                row.inputs = .{ .start = inputs_start, .len = @as(u32, @intCast(b.values.items.len)) - inputs_start };
            },
        }
        const lambda_body: Inst.OptionalIndex = if (r.shape == .lambda) blk: {
            const d = b.bir().instData(r.function);
            break :blk @as(Inst.Index, @fromBackingInt(@intCast(d.rhs))).toOptional();
        } else r.body;
        try b.tree_rows.append(b.arena, row);
        try b.row_sources.append(b.arena, .{
            .function = r.function,
            .shape = r.shape,
            .lets = .{ .start = r.lets_start, .end = r.lets_end },
            .body = lambda_body,
        });
        switch (r.shape) {
            .markup => {
                const body = r.body.unwrap().?;
                try b.row_bodies.append(b.arena, body.int());
                b.tree_rows.items[index].body = @fromBackingInt(@intCast(b.rootIndexOf(body.int()).?));
                // A body's instruction comes before its row's, so its root
                // is usually built already; one built later reads
                // `row_bodies`.
                b.roots[b.rootIndexOf(body.int()).?].kind = .row_markup;
            },
            .lambda => try b.pending_lambdas.append(b.arena, index),
            .function => {},
        }
        return @fromBackingInt(@intCast(index));
    }

    fn itemList(b: *Builder, start: Bir.ExtraIndex, end: Bir.ExtraIndex) !m.Range {
        const bir_ = b.bir();
        const range_start: u32 = @intCast(b.items.items.len);
        for (bir_.extraSlice(.{ .start = start, .end = end }, Bir.ExtraIndex)) |at| {
            const item = bir_.extraData(at, Bir.MarkupItem);
            if (item.kind == .spread) continue;
            const row = b.rowOf(@backingInt(at));
            const kind: m.Item.Kind = if (row) |r| switch (r.kind) {
                .event => .event,
                .escape => .escape,
                else => .attribute,
            } else if (item.kind == .escape) .escape else .attribute;
            var out: m.Item = .{
                .kind = kind,
                .name = try b.string(b.symbolText(item.name)),
                .attribute = .none,
                .event = .none,
                .class = if (row) |r| (if (kind == .event) .string else @fromBackingInt(@intCast(r.detail))) else .string,
                .form = if (row) |r| (if (kind == .event) @fromBackingInt(@intCast(r.detail)) else .message) else .message,
                .url = if (row) |r| r.url else false,
                .value = undefined,
            };
            switch (kind) {
                .attribute => if (row) |r| {
                    out.attribute = try b.attributeRow(r.row);
                    if (out.attribute != .none) out.url = out.url or b.attribute_facts.items[@backingInt(out.attribute)].url;
                },
                .event => if (row) |r| {
                    out.event = try b.eventRow(r.row);
                },
                else => {},
            }
            // Items keep their slot in `items` before their values are
            // found: an entry list appends to `entries` and values only.
            out.value = try b.itemValue(item);
            try b.items.append(b.arena, out);
            const extractor = if (kind == .event) if (row) |r| r.extractor else Dispatch.Markup.no_row else Dispatch.Markup.no_row;
            try b.extractors.append(b.arena, extractor);
        }
        return .{ .start = range_start, .len = @as(u32, @intCast(b.items.items.len)) - range_start };
    }

    fn itemValue(b: *Builder, item: Bir.MarkupItem) !m.ItemValue {
        const bir_ = b.bir();
        const entry_records = bir_.extraSlice(.{ .start = item.entries_start, .end = item.entries_end }, Bir.ExtraIndex);
        if (entry_records.len != 0) {
            const entries_start: u32 = @intCast(b.entries.items.len);
            for (entry_records) |at| {
                const e = bir_.extraData(at, Bir.MarkupEntry);
                const name = try b.string(bir_.string_bytes[e.name_offset..][0..e.name_len]);
                const v: m.ItemValue = if (e.constant != .none)
                    .{ .kind = .constant, .constant = try b.constant(e.constant, e.constant_offset, e.constant_len), .dynamic = null, .entries = .{ .start = 0, .len = 0 } }
                else
                    .{ .kind = .dynamic, .constant = noConstant(), .dynamic = try b.value(.{ .inst = e.value }), .entries = .{ .start = 0, .len = 0 } };
                try b.entries.append(b.arena, .{ .name = name, .value = v });
            }
            const range: m.Range = .{ .start = entries_start, .len = @as(u32, @intCast(b.entries.items.len)) - entries_start };
            return .{ .kind = .entries, .constant = noConstant(), .dynamic = try b.value(.{ .entries = range }), .entries = range };
        }
        if (item.constant != .none) {
            return .{ .kind = .constant, .constant = try b.constant(item.constant, item.constant_offset, item.constant_len), .dynamic = null, .entries = .{ .start = 0, .len = 0 } };
        }
        const v = item.value.unwrap() orelse
            return .{ .kind = .constant, .constant = .{ .kind = .bool, .text = try b.string(""), .bool = true }, .dynamic = null, .entries = .{ .start = 0, .len = 0 } };
        return .{ .kind = .dynamic, .constant = noConstant(), .dynamic = try b.value(.{ .inst = v }), .entries = .{ .start = 0, .len = 0 } };
    }

    fn noConstant() m.Constant {
        return .{ .kind = .none, .text = @fromBackingInt(@intCast(0)), .bool = false };
    }

    fn constant(b: *Builder, c: Bir.Constant, offset: u32, len: u32) !m.Constant {
        const text = b.bir().string_bytes[offset..][0..len];
        return switch (c) {
            .none => noConstant(),
            .string => .{ .kind = .string, .text = try b.string(text), .bool = false },
            .number => .{ .kind = .number, .text = try b.string(text), .bool = false },
            .true => .{ .kind = .bool, .text = try b.string(""), .bool = true },
            .false => .{ .kind = .bool, .text = try b.string(""), .bool = false },
        };
    }

    // ---- The vocabulary rows, re-indexed densely --------------------------

    /// The facts of the row an element resolved to, named as the element
    /// is written: a pattern row (`"*-*"`) is one row of facts per name
    /// that matched it, since a lowering writes the name.
    fn elementRow(b: *Builder, iface_row: u32, written: []const u8) !m.ElementRow {
        if (iface_row >= b.element_rows.len) return .none;
        const row = b.in.vocabulary.elements[iface_row];
        const pattern = row.facts & Interface.VocabRow.pattern_bit != 0;
        if (pattern) {
            for (b.element_facts.items, 0..) |f, i| {
                if (std.mem.eql(u8, b.stringText(f.name), written)) return @fromBackingInt(@intCast(i));
            }
        }
        if (pattern or b.element_rows[iface_row] == none) {
            const at: u32 = @intCast(b.element_facts.items.len);
            try b.element_facts.append(b.arena, .{
                .name = try b.string(if (pattern) written else b.ifaceText(row.name)),
                .void = row.has(.void),
                .namespace = if (row.has(.svg)) .svg else if (row.has(.mathml)) .mathml else .html,
            });
            if (pattern) return @fromBackingInt(@intCast(at));
            b.element_rows[iface_row] = at;
        }
        return @fromBackingInt(@intCast(b.element_rows[iface_row]));
    }

    fn stringText(b: *const Builder, i: m.Strings.Index) []const u8 {
        const span = b.spans.items[@backingInt(i)];
        return b.string_bytes.items[span.start..][0..span.len];
    }

    fn attributeRow(b: *Builder, iface_row: u32) !m.AttributeRow {
        if (iface_row >= b.attribute_rows.len) return .none;
        if (b.attribute_rows[iface_row] == none) {
            const row = b.in.vocabulary.attributes[iface_row];
            const name = try b.string(b.ifaceText(row.name));
            b.attribute_rows[iface_row] = @intCast(b.attribute_facts.items.len);
            try b.attribute_facts.append(b.arena, .{
                .name = name,
                .property = if (!row.has(.property)) null else if (row.arg.unwrap()) |a| try b.string(b.ifaceText(a)) else name,
                .stateful = row.has(.stateful),
                .url = row.has(.url),
                .raw = row.has(.raw),
                .classes = row.has(.classes),
                .styles = row.has(.styles),
            });
        }
        return @fromBackingInt(@intCast(b.attribute_rows[iface_row]));
    }

    fn eventRow(b: *Builder, iface_row: u32) !m.EventRow {
        if (iface_row >= b.event_rows.len) return .none;
        if (b.event_rows[iface_row] == none) {
            const row = b.in.vocabulary.events[iface_row];
            const text = b.ifaceText(row.name);
            // The DOM event's name: the `name` fact's, else the name after
            // `on`, lower-cased.
            const dom_name = if (row.arg.unwrap()) |a| try b.string(b.ifaceText(a)) else blk: {
                const rest = if (std.mem.startsWith(u8, text, "on")) text[2..] else text;
                const lowered = try b.arena.dupe(u8, rest);
                for (lowered) |*c| c.* = std.ascii.toLower(c.*);
                break :blk try b.string(lowered);
            };
            b.event_rows[iface_row] = @intCast(b.event_facts.items.len);
            try b.event_facts.append(b.arena, .{
                .name = try b.string(text),
                .dom_name = dom_name,
                .delegated = row.has(.delegated),
                .prevent_default = row.has(.prevent_default),
                .stop_propagation = row.has(.stop_propagation),
                .has_extractor = row.via != .none,
            });
        }
        return @fromBackingInt(@intCast(b.event_rows[iface_row]));
    }
};
