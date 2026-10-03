//! Constraint generation for markup (checker-v2.md §25.3–§25.5): one
//! `markup` root, its tree, and the value instructions the tree names.
//!
//! **A root is `H m`**, `H` the build's markup type and `m` one fresh
//! variable shared by every node of the root: every handler's message, every
//! markup hole's parameter, every nested element and component. Markup inside
//! a hole or a row is a root of its own, whose `m` meets this one through
//! the hole's `renderable` obligation or the row's function type.
//!
//! **Names are resolved here**, against the vocabulary (`check/Markup.zig`),
//! because what a name resolves to is a function of its text and the rows
//! alone. What the syntax and the rows decide on their own — an unknown
//! name, a quoted or bare value the declared type does not admit, a `void`
//! element given children, a `raw` attribute, a quoted `on…` name — is a
//! `markup_fault` node, reported when the solver reaches it. What needs a
//! type is an obligation (§25.4), a `markup_obligation` node.
//!
//! Items are generated in source order, attributes and events interleaved as
//! written, then the children, depth first: the order their instructions lie
//! in (`frontend.md` §9.7). Nothing about the result depends on it (I9).

const std = @import("std");
const Bir = @import("../../bir/Bir.zig");
const InternPool = @import("../../InternPool.zig");
const TypeStore = @import("../TypeStore.zig");
const Tree = @import("Tree.zig");
const Expr = @import("Expr.zig");
const Vocabulary = @import("../Markup.zig");
const Obligations = @import("../Obligations.zig");
const CategoryFile = @import("../Category.zig");
const Walk = @import("../Walk.zig");

const Generator = Tree.Generator;
const Constraint = Tree.Constraint;
const Category = Tree.Category;
const Var = Tree.Var;
const Error = Tree.Error;
const Symbol = InternPool.Symbol;
const FormAttribute = CategoryFile.FormAttribute;

/// Constrain the markup root `inst` to have type `expected`.
pub fn root(g: *Generator, inst: Bir.Inst.Index, expected: Var, category: Category) Error!Constraint {
    // No vocabulary: the module has its `no_markup_vocabulary` from P1, so
    // poison and stay quiet.
    const vocab = g.cx.markup orelse return g.equal(expected, try g.fresh(.err), inst, category);
    var w: Walker = .{ .g = g, .vocab = vocab, .inst = inst, .m = try g.freshFlex() };
    defer w.parts.deinit(g.cx.scratch);
    g.markup_roots += 1;
    defer g.markup_roots -= 1;
    try w.add(try g.equal(expected, try w.html(), inst, category));
    try w.node(@fromBackingInt(@intCast(g.cx.bir.instData(inst).lhs)));
    return g.conj(w.parts.items);
}

const Walker = struct {
    g: *Generator,
    vocab: *Vocabulary,
    /// The root: where every node's constraints and faults are attributed.
    inst: Bir.Inst.Index,
    /// The root's message variable.
    m: Var,
    parts: std.ArrayList(Constraint) = .empty,

    fn add(w: *Walker, c: Constraint) Error!void {
        try w.parts.append(w.g.cx.scratch, c);
    }

    fn bir(w: *const Walker) *const Bir {
        return w.g.cx.bir;
    }

    /// `H m`, fresh.
    fn html(w: *Walker) Error!Var {
        return w.g.applied(w.vocab.markup_type, &.{w.m});
    }

    fn expr(w: *Walker, inst: Bir.Inst.Index, expected: Var, category: Category) Error!void {
        try w.add(try Expr.expr(w.g, inst, expected, category));
    }

    /// A value typed on its own, for an item nothing resolved.
    fn free(w: *Walker, value: Bir.Inst.OptionalIndex) Error!void {
        const v = value.unwrap() orelse return;
        try w.expr(v, try w.g.freshFlex(), .{ .tag = .general });
    }

    fn fault(w: *Walker, kind: Tree.MarkupFault.Kind, token: u32, name: Symbol, tag: Symbol, t: ?Var) Error!void {
        const payload = try w.g.addExtra(Tree.MarkupFault{
            .kind = kind,
            .token = token,
            .name = name,
            .tag = tag,
            .type = if (t) |v| @backingInt(v) else 0,
        });
        try w.add(try w.g.add(.markup_fault, w.inst, payload, 0, .{}));
    }

    fn obligation(w: *Walker, kind: Obligations.Kind, region: Bir.Inst.Index, vars: []const Var, index: u32) Error!void {
        const payload = try w.g.addExtra(Tree.MarkupObligation{
            .kind = @backingInt(kind),
            .count = @intCast(vars.len),
            .v0 = vars[0],
            .v1 = if (vars.len > 1) vars[1] else vars[0],
            .v2 = if (vars.len > 2) vars[2] else vars[0],
            .index = index,
        });
        try w.add(try w.g.add(.markup_obligation, region, payload, 0, .{}));
    }

    /// A copy of a vocabulary row's type, or null when it has none.
    fn rowType(w: *Walker, row: *Vocabulary.Row) Error!?Var {
        const scheme = try w.vocab.typeOf(row) orelse return null;
        const t = try w.g.freshFlex();
        try w.add(try w.g.instantiate(t, scheme, w.inst, .{}));
        return t;
    }

    fn node(w: *Walker, at: Bir.ExtraIndex) Error!void {
        const g = w.g;
        g.depth += 1;
        defer g.depth -= 1;
        // The parser bounds how deep markup nests, counting elements and
        // holes; this also counts each hole's expression, so a file it
        // accepted can reach it (`Generator.depth`).
        if (g.depth > Generator.max_depth) return g.cx.noteTooDeepAs(w.inst, @backingInt(g.decl), .markup);
        const b = w.bir();
        switch (b.markupKind(at)) {
            .element => try w.element(b.extraData(at, Bir.MarkupElement)),
            .fragment => {
                const f = b.extraData(at, Bir.MarkupFragment);
                try w.children(f.children_start, f.children_end);
            },
            .text => {},
            .hole => try w.hole(at),
            .component => try w.component(b.extraData(at, Bir.MarkupComponent)),
            .@"for", .show => try w.form(at),
        }
    }

    fn children(w: *Walker, start: Bir.ExtraIndex, end: Bir.ExtraIndex) Error!void {
        for (w.bir().extraSlice(.{ .start = start, .end = end }, Bir.ExtraIndex)) |c| try w.node(c);
    }

    /// A hole: its value, and whether it can be rendered (§25.4).
    fn hole(w: *Walker, at: Bir.ExtraIndex) Error!void {
        const h = w.bir().extraData(at, Bir.MarkupHole);
        const t = try w.g.freshFlex();
        try w.expr(h.value, t, .{ .tag = .general });
        try w.obligation(.renderable, h.value, &.{ t, w.m }, @backingInt(at));
    }

    fn element(w: *Walker, e: Bir.MarkupElement) Error!void {
        const b = w.bir();
        const tag = b.symbol(e.name);
        const items = b.extraSlice(.{ .start = e.items_start, .end = e.items_end }, Bir.ExtraIndex);
        const row = w.vocab.element(tag) orelse {
            // Typed as if absent: one misspelling is one message.
            try w.fault(.unknown_element, e.token, tag, tag, null);
            for (items) |at| try w.free(b.extraData(at, Bir.MarkupItem).value);
            return w.children(e.children_start, e.children_end);
        };
        for (items) |at| try w.item(tag, at);
        const kids = b.extraSlice(.{ .start = e.children_start, .end = e.children_end }, Bir.ExtraIndex);
        if (row.has(.void) and kids.len != 0) try w.fault(.void_children, nodeToken(b, kids[0]), tag, tag, null);
        try w.children(e.children_start, e.children_end);
    }

    /// One attribute, escape or event of the element `tag` (§25.3).
    fn item(w: *Walker, tag: Symbol, at: Bir.ExtraIndex) Error!void {
        const g = w.g;
        const b = w.bir();
        const it = b.extraData(at, Bir.MarkupItem);
        switch (it.kind) {
            .spread => return w.free(it.value),
            .escape => {
                const name = b.symbol(it.name);
                // An `on…` name is an event handler the page would run as
                // script (the owner's refusal): the typed event is the way.
                const text = g.cx.interner.slice(name);
                if (text.len >= 2 and std.ascii.eqlIgnoreCase(text[0..2], "on")) {
                    try w.fault(.event_escape, it.token, name, tag, null);
                    return w.free(it.value);
                }
                // An iframe's `srcdoc` is a document the page runs, its
                // scripts included (the owner's decision).
                if (std.ascii.eqlIgnoreCase(text, "srcdoc")) {
                    try w.fault(.srcdoc_escape, it.token, name, tag, null);
                    return w.free(it.value);
                }
                const v = it.value.unwrap() orelse return;
                return w.expr(v, try g.primitive(g.cx.types.well_known.string), .{ .tag = .markup_attribute, .index = @backingInt(name) });
            },
            .attr => {},
        }
        const name = b.symbol(it.name);
        const row = w.vocab.item(tag, name) orelse {
            try w.fault(.unknown_attribute, it.token, name, tag, null);
            return w.free(it.value);
        };
        switch (row.form) {
            .event => try w.event(row, name, at, it),
            else => try w.attribute(row, name, at, it),
        }
    }

    fn attribute(w: *Walker, row: *Vocabulary.Row, name: Symbol, at: Bir.ExtraIndex, it: Bir.MarkupItem) Error!void {
        const g = w.g;
        if (row.has(.raw) and g.cx.graph.modulePackage(g.cx.module) == .app) try w.fault(.raw_attribute, it.token, name, name, null);
        const class = try w.vocab.classOf(row) orelse return w.free(it.value);
        const lists = row.has(.classes) or row.has(.styles);
        switch (it.form) {
            // Decided from the syntax: a quoted value is a `String`, or
            // `Just` one for a `Maybe String` (§25.3).
            .quoted => {
                if (class != .string and class != .maybe_string) {
                    try w.fault(.quoted_value, it.token + 2, name, name, row.type.unwrap());
                    return w.free(it.value);
                }
                const v = it.value.unwrap() orelse return;
                try w.expr(v, try g.primitive(g.cx.types.well_known.string), .{ .tag = .markup_attribute, .index = @backingInt(name) });
            },
            .bare => if (class != .bool) try w.fault(.bare_value, it.token, name, name, row.type.unwrap()),
            .braced => {
                const v = it.value.unwrap() orelse return;
                if (lists) {
                    const t = try g.freshFlex();
                    try w.expr(v, t, .{ .tag = .general });
                    const flag: u32 = if (row.has(.styles)) Obligations.markup_flag else 0;
                    return w.obligation(.attr_form, v, &.{t}, @backingInt(at) | flag);
                }
                const t = try w.rowType(row) orelse return w.free(it.value);
                try w.expr(v, t, .{ .tag = .markup_attribute, .index = @backingInt(name) });
            },
        }
    }

    /// An event's handler: its value, then which of the two forms it is
    /// (§25.4). A handler written bare or quoted is the `Bool` or `String`
    /// it spells, and meets the event as any value would.
    fn event(w: *Walker, row: *Vocabulary.Row, name: Symbol, at: Bir.ExtraIndex, it: Bir.MarkupItem) Error!void {
        const g = w.g;
        const wk = g.cx.types.well_known;
        const handler = try g.freshFlex();
        if (it.value.unwrap()) |v| {
            try w.expr(v, handler, .{ .tag = .general });
        } else {
            try w.add(try g.equal(handler, try g.primitive(if (it.form == .bare) wk.bool else wk.string), w.inst, .{ .tag = .markup_handler, .index = @backingInt(name) }));
        }
        const payload = try w.rowType(row) orelse try g.fresh(.err);
        try w.obligation(.handler, it.value.unwrap() orelse w.inst, &.{ handler, payload, w.m }, @backingInt(at));
        // The page calls a handler's function form while it dispatches the
        // event: `sync` (checker-v2.md §25.6, transparent-effects-proposal.md
        // §15.2 item 4). The value form carries no class, and demands nothing.
        if (g.cx.effects) |e| if (it.value.unwrap()) |v| try e.demand(.{ .v = handler, .kind = .handler, .site = @backingInt(v) });
    }

    /// A component is typed exactly as the call it means (§25.5): the
    /// callee against `{ props } -> H m`, the record closed, or updated from
    /// a leading spread.
    fn component(w: *Walker, c: Bir.MarkupComponent) Error!void {
        const g = w.g;
        const b = w.bir();
        const wk = g.cx.types.well_known;
        const props = b.extraSlice(.{ .start = c.props_start, .end = c.props_end }, Bir.ExtraIndex);
        const kids = b.extraSlice(.{ .start = c.children_start, .end = c.children_end }, Bir.ExtraIndex);
        const children_field = c.children_form != .absent and !hasChildrenProp(w, props);

        const count = props.len + @intFromBool(children_field);
        const pairs = try g.cx.scratch.alloc(TypeStore.Field, count);
        defer g.cx.scratch.free(pairs);
        for (props, 0..) |at, i| pairs[i] = .{ .name = b.symbol(b.extraData(at, Bir.MarkupItem).name), .value = try g.freshFlex() };
        const children_symbol = g.cx.graph.markup.children.unwrap();
        if (children_field) pairs[props.len] = .{ .name = children_symbol orelse return, .value = try g.freshFlex() };
        const range = try g.cx.store.addFields(pairs);

        const callee = try g.freshFlex();
        // Rendering the component calls it (transparent-effects-proposal.md §14.3 rule 1).
        try g.called(callee, c.callee);
        try w.expr(c.callee, callee, .{ .tag = .general });
        const argument: Var = if (c.spread.unwrap()) |spread| blk: {
            // Record update over the spread value (§6.5): the base must
            // have every written field, and the argument is the base.
            const base = try g.freshFlex();
            try w.expr(spread, base, .{ .tag = .general });
            const required = try g.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = try g.freshFlex() } } });
            try w.add(try g.equal(required, base, spread, .{ .tag = .record_update, .index = Category.no_field }));
            break :blk base;
        } else try g.fresh(.{ .structure = .{ .record = .{ .fields = range, .ext = try g.fresh(.{ .structure = .empty_record }) } } });

        const args_start: u32 = @intCast(g.tree.extra.items.len);
        try g.tree.extra.append(g.gpa, @backingInt(argument));
        const call = try g.addExtra(Tree.Call{ .callee = callee, .args_start = args_start, .args_len = 1, .result = try w.html(), .flavor = .call });
        try w.add(try g.add(.call, c.callee, call, 0, .{}));

        for (props) |at| {
            const it = b.extraData(at, Bir.MarkupItem);
            const field = b.symbol(it.name);
            const v = fieldIn(g, range, field) orelse continue;
            const category: Category = .{ .tag = if (c.spread != .none) .record_update else .record_field, .index = @backingInt(field) };
            if (it.value.unwrap()) |value| {
                try w.expr(value, v, category);
            } else {
                const t = try g.primitive(if (it.form == .bare) wk.bool else wk.string);
                try w.add(try g.equal(v, t, c.callee, category));
            }
        }
        if (children_field) {
            const v = fieldIn(g, range, children_symbol.?).?;
            switch (c.children_form) {
                .absent => {},
                // Exactly one hole: `children` is its value.
                .hole => {
                    const h = b.extraData(kids[0], Bir.MarkupHole);
                    try w.expr(h.value, v, .{ .tag = .record_field, .index = @backingInt(children_symbol.?) });
                },
                // Anything else: one markup value, the children as a
                // fragment — a root of its own, whose messages are the
                // ones the `children` prop takes, exactly as in the call
                // `M.c { children = <>…</> }` (language.md §11.13).
                .fragment => {
                    var inner: Walker = .{ .g = g, .vocab = w.vocab, .inst = w.inst, .m = try g.freshFlex() };
                    defer inner.parts.deinit(g.cx.scratch);
                    try w.add(try g.equal(v, try inner.html(), c.callee, .{ .tag = .markup_children }));
                    for (kids) |k| try inner.node(k);
                    try w.add(try g.conj(inner.parts.items));
                },
            }
        } else if (c.children_form == .fragment) {
            for (kids) |k| try w.node(k);
        }
    }

    fn hasChildrenProp(w: *const Walker, props: []const Bir.ExtraIndex) bool {
        const b = w.bir();
        for (props) |at| {
            if (std.mem.eql(u8, w.g.cx.interner.slice(b.symbol(b.extraData(at, Bir.MarkupItem).name)), "children")) return true;
        }
        return false;
    }

    /// `For` and `Show` (§25.4).
    fn form(w: *Walker, at: Bir.ExtraIndex) Error!void {
        const g = w.g;
        const b = w.bir();
        const wk = g.cx.types.well_known;
        const f = b.extraData(at, Bir.MarkupForm);
        const is_for = b.markupKind(at) == .@"for";
        const a = try g.freshFlex();
        if (f.list.unwrap()) |list| {
            const wanted = try g.applied(if (is_for) wk.list else wk.maybe, &.{a});
            try w.expr(list, wanted, formCategory(if (is_for) .each else .when));
        }
        if (f.fallback.unwrap()) |fallback| try w.expr(fallback, try w.html(), formCategory(.fallback));
        if (f.keyed.unwrap()) |keyed| switch (f.mode) {
            .key_function => {
                const k = try g.freshFlex();
                const key_function = try g.func(&.{a}, k);
                try w.expr(keyed, key_function, formCategory(.keyed));
                // Called by the page while it renders: `sync` (§25.6).
                if (g.cx.effects) |e| try e.demand(.{ .v = key_function, .kind = .key, .site = @backingInt(keyed) });
                try w.obligation(.key, keyed, &.{k}, @backingInt(at));
            },
            // A mode, not a value: the literal is the prelude's `Bool`.
            else => try w.expr(keyed, try g.primitive(wk.bool), formCategory(.keyed)),
        };
        if (f.row != Bir.none_extra) try w.rowFunction(@fromBackingInt(@intCast(f.row)), a, is_for);
        // Whether the item is a primitive-`eq` type, which the record says,
        // and which a `For` that does not say how it is keyed is warned
        // about in a module of the root package.
        const warn = is_for and f.mode == .absent and g.cx.graph.modulePackage(g.cx.module) == .app;
        try w.obligation(.item, w.inst, &.{a}, @backingInt(at) | if (warn) Obligations.markup_flag else 0);
    }

    /// A row function: a lambda meets `a -> H m`, or `a, Int -> H m` in a
    /// `For` when it has two parameters; anything else is decided by its
    /// type (`row`).
    fn rowFunction(w: *Walker, at: Bir.ExtraIndex, a: Var, is_for: bool) Error!void {
        const g = w.g;
        const b = w.bir();
        const r = b.extraData(at, Bir.MarkupRow);
        const category: Category = .{ .tag = .markup_row, .index = if (is_for) 0 else 1 };
        switch (r.shape) {
            .markup, .lambda => {
                const lambda = b.instData(r.function);
                const params = b.extraSlice(b.subRange(@fromBackingInt(@intCast(lambda.lhs))), Bir.Inst.Index).len;
                const wanted = if (is_for and params == 2)
                    try g.func(&.{ a, try g.primitive(g.cx.types.well_known.int) }, try w.html())
                else
                    try g.func(&.{a}, try w.html());
                try w.expr(r.function, wanted, category);
                if (g.cx.effects) |e| try e.demand(.{ .v = wanted, .kind = .row, .site = @backingInt(r.function) });
            },
            .function => {
                const f = try g.freshFlex();
                try w.expr(r.function, f, .{ .tag = .general });
                // A row function is called by the page while it renders: `sync`
                // (§25.6), whichever shape it has.
                if (g.cx.effects) |e| try e.demand(.{ .v = f, .kind = .row, .site = @backingInt(r.function) });
                try w.obligation(.row, r.function, &.{ f, a, w.m }, @backingInt(at) | if (is_for) Obligations.markup_flag else 0);
            },
        }
    }
};

fn formCategory(which: FormAttribute) Category {
    return .{ .tag = .markup_form, .index = @backingInt(which) };
}

fn fieldIn(g: *Generator, range: TypeStore.Range, name: Symbol) ?Var {
    return Walk.fieldIn(g.cx.store, range, name);
}

/// The token a node's record starts with: every node record holds one
/// after its kind.
pub fn nodeToken(b: *const Bir, at: Bir.ExtraIndex) u32 {
    return b.extra[@backingInt(at) + 1];
}
