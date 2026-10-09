//! The markup lowering interface (docs/design/boundary.md §9.4), version
//! 1.8: what the compiler hands a platform's markup lowering, and everything
//! the lowering may do with it.
//!
//! A lowering imports this module as `beni_markup` and nothing of the
//! compiler besides. It sees one `Tree` per module — every fact the checker
//! decided about that module's markup, in the shape a lowering walks — and
//! writes JavaScript through a `Context`, which is the whole of its reach:
//! a restricted builder that can spell no name the lowering was not given,
//! the values the compiler evaluated for it, and the imports of its own
//! runtime (§9.4.3–§9.4.4).
//!
//! **Every enumeration is non-exhaustive** and every node is read through an
//! accessor, so a lowering's `switch` needs an `else` prong and compiles
//! unchanged when a later minor version adds a member (§9.4.6). Handles —
//! `Name`, `Expr`, `Block`, `Value.Index` — are opaque: the compiler maps
//! each to what it stands for, and a lowering can make one only by asking.

const std = @import("std");

/// The version of the interface this module declares (§9.4.6). Version 1.0
/// is `boundary.md` §9.4 as written on 2026-09-29; 1.1 adds `Hole.call`,
/// 1.2 `Tree.item_only` and `Context.rowValuesApart`, 1.3 `Row.selector`,
/// 1.4 `Tree.constant`, 1.5 a root's inputs and reads, `Lowering.groups`
/// and the calls that evaluate a grouped root's values, 1.6 the program
/// hook (`Lowering.program`, `Program`, the calls that read one),
/// `Lowering.placements` and `Lowering.no_markup_values`, 1.7 the calls
/// a program lowering compiles messages and holes with (`programKeys`,
/// `programHole`, `programCalls`, `programUpdate`, `programArm`,
/// `programViewEnter`, `programMessage`, `programDispatch`), `reachesDebug`
/// and `Build.fuzz`, 1.8 the calls a program lowering compiles a `For`'s rows
/// with (`programList`, `programEdits`, `programIndex`, `rowValuesOf`,
/// `programRowBake`).
pub const version: Version = .{ .major = 1, .minor = 8 };

/// The newest version whose gated feature a tree can use. No minor version
/// has gated one yet, so every tree requires 1.0 and every lowering of
/// major version 1 is handed it.
pub const gated: Version = .{ .major = 1, .minor = 0 };

pub const Version = struct {
    major: u16,
    minor: u16,

    /// Whether a lowering written against `targets` renders every feature a
    /// tree that `requires` this version uses: the same major version, and
    /// a minor at least as new.
    pub fn covers(targets: Version, requires: Version) bool {
        return targets.major == requires.major and targets.minor >= requires.minor;
    }
};

/// A lowering: what a platform's Zig module lists in `pub const lowerings`
/// (§9.5), and what a manifest's `"markup".lowering` names.
pub const Lowering = struct {
    /// What a manifest's `"lowering"` names.
    name: []const u8,
    /// The interface version the lowering was written against (§9.4.6).
    targets: Version,
    /// The markup runtime's exports this lowering's emitted code imports,
    /// each with its parameter count (§9.4.5).
    runtime: []const RuntimeExport,
    /// Runs once per module that has a surviving markup root, before any of
    /// its roots: hoists what the module needs.
    module: *const fn (cx: *Context, tree: *const Tree) Error!void,
    /// Runs where the program evaluates a root of kind `expression`, with
    /// the root's values already evaluated; returns what the root evaluates
    /// to.
    root: *const fn (cx: *Context, tree: *const Tree, root: Root.Index) Error!Expr,
    /// 1.5: the lowering evaluates a grouped root's values itself
    /// (`Context.grouped`), so the compiler does not evaluate them where the root stands.
    groups: bool = false,
    /// 1.6: the program constructors this lowering compiles whole, by
    /// module and value name in the platform chain (`Tea.sandbox`), each a
    /// `foreign` of its platform. Every call of one is handed to `program`;
    /// any other use of one is `view_not_compiled`; a use of one the
    /// lowering refuses (`Named.refused`) is `not_implemented`. Empty:
    /// none, and `program` is never called.
    programs: []const Named = &.{},
    /// 1.6: the program hook (`browser-direct.md` §11.1). Runs where a call
    /// of one of `programs` stands, instead of the call's argument, and
    /// returns the program's mount: the call is compiled as the
    /// constructor applied to it, so the constructor's JavaScript makes
    /// the platform's `Program` of the mount. The record is not evaluated;
    /// what the lowering asks of it is (`Context.programInit`).
    program: ?*const fn (cx: *Context, tree: *const Tree, p: *const Program) Error!Expr = null,
    /// 1.6: the values that place programs on a page, which a lowering
    /// lists when one program value mounted twice would share one state:
    /// the compiler refuses a top-level program value named twice among
    /// what `main`'s placements place (`program_mounted_twice`). Empty:
    /// none is refused.
    placements: []const Placement = &.{},
    /// 1.6: set when the lowering has no run-time value of the markup type:
    /// a markup root that is not a program's `view` (`Program.view_root`)
    /// and every use of a markup primitive is `not_implemented`, with this
    /// text as the message, and the markup runtime is not held to the
    /// primitives (§9.4.5). Null: markup is a value, as before.
    no_markup_values: ?[]const u8 = null,
};

/// 1.6: a value of a module of the platform chain, by the module's name and
/// its own.
pub const Named = struct {
    module: []const u8,
    name: []const u8,
    /// Set: the lowering refuses the value — every use of it is
    /// `not_implemented`, with this text as the message, and the hook never
    /// sees it. How a lowering turns away another architecture's program
    /// constructor that its runtime cannot run (`Browser.hosted` under one
    /// that compiles The Elm Architecture itself).
    refused: ?[]const u8 = null,
};

/// 1.6: a value that places programs, and which of its arguments are them.
pub const Placement = struct {
    module: []const u8,
    name: []const u8,
    places: Places,

    pub const Places = enum(u8) {
        /// Its one argument, a list: each element a program (`programs`).
        list,
        /// Its first argument (`mountAt`).
        first,
        _,
    };
};

/// 1.6: one call of a program constructor, as the compiler found it
/// (`write-sets.md` §1.1's shape). What the record holds is read through
/// the context (`programInit`); the shapes say what the compiler could
/// reach.
pub const Program = struct {
    /// Which of `Lowering.programs` is called.
    constructor: u32,
    /// The argument is a record literal written at the call, whose fields
    /// the shapes below describe. False: it is anything else — a local, a
    /// value a call computes, a top-level record — and every shape is
    /// `computed`.
    record: bool,
    /// What `view` is.
    view: Shape,
    /// `view == .markup`: the root of this module's tree that is the
    /// function's body.
    view_root: ?Root.Index,
    /// What `update` is: `markup` and `function` alike are functions this
    /// module declares or the record writes; `other_module` or `computed`.
    update: Shape,

    pub const Shape = enum(u8) {
        /// A top-level function of this module or a lambda written in the
        /// record, whose body is markup written in place.
        markup,
        /// A top-level function or a lambda whose body is anything else.
        function,
        /// A function of another module.
        other_module,
        /// Anything else: a value a call computes, a local.
        computed,
        _,
    };

    /// Where `Context.programReport` points.
    pub const Part = enum(u8) { call, init, update, view, _ };
    /// What `Context.programReport` reports.
    pub const Code = enum(u8) { not_implemented, view_not_compiled, _ };

    /// 1.7: one leaf message key of the program (`write-sets.md` §4.4),
    /// what `Context.programKeys` lists.
    pub const Key = struct {
        /// The key as `beni dump --stage=writes` names it, for a handler's
        /// name (`Inc`, `GotPage · Typed`, `(any)`, `*`).
        name: []const u8,
        /// The handler's parameter count: the fields of the constructor,
        /// for a key that is one named constructor; one, the message
        /// itself, for any other.
        params: u32,
        /// The key's write set is `value ρ` (class `*`): its handler
        /// re-runs every group of the page (`browser-direct.md` §4.1,
        /// `patchAll`).
        star: bool,
    };

    /// 1.7: what `Context.programHole` says of one hole of the program's
    /// `view`: a text hole (`node`) or an attribute (`item`, its index in
    /// `Tree.items`).
    pub const HoleRef = union(enum) { node: Node.Index, item: u32 };

    pub const HoleFacts = struct {
        /// The hole's anchored read set (`write-sets.md` §3.6), as a
        /// number: two holes of one program have one number exactly when
        /// they read the same model paths. What a group is (§5.3).
        group: u32,
        /// No key's write set conflicts with the read set (§2.5): the hole
        /// shows the same value for the page's life (§9.1, R3).
        static: bool,
        /// `static`, and §9.1 bakes it: the text the template holds in the
        /// hole's place, verbatim (plain: nothing to escape). Null
        /// otherwise.
        bake: ?[]const u8,
        /// Where the hole is written, `Main.beni:12:9`, for a message that
        /// names it; empty when the pass did not see it.
        where: []const u8 = "",
    };

    /// 1.8: what `Context.programList` says of one `For` of the program's
    /// `view`.
    pub const ListFacts = struct {
        /// Its `each` is exactly a path of the model or of an enclosing
        /// row's item (`browser-direct.md` §6.2): a key's edits name what
        /// changed. False: a derived list, which every key whose writes
        /// conflict with its reads `replaced`.
        exact: bool,
        /// K3 (`browser-direct.md` §6, as amended for S2): the number of
        /// rows `init` gives, each written into the template
        /// (`Context.programRowBake`); null when the list is made at mount.
        baked: ?u32 = null,
    };

    /// 1.8: an index symbol of a key's edits (`write-sets.md` §2.3), which
    /// `Context.programIndex` evaluates; `every` stands for every row, and
    /// `unknown` for a position the handler cannot compute.
    pub const Index = enum(u32) {
        every = std.math.maxInt(u32),
        unknown = std.math.maxInt(u32) - 1,
        _,
    };

    /// 1.8: a list's edit tag (`write-sets.md` §2.3), as an edit says it.
    pub const Tag = enum(u8) { set, append, prepend, clear, insert, remove_at, swap, all, remove_some, permute, replaced, _ };

    /// 1.8: one thing a key's write set does to a `For`'s rows
    /// (`Context.programEdits`).
    pub const Edit = struct {
        /// The rows of the enclosing `For`s it is under, outermost first:
        /// one index per enclosing `For` (`every`: in each of its rows).
        outer: []const Index,
        what: What,

        pub const What = union(enum) {
            /// The list's shape: its tag and the tag's index symbols
            /// (`unknown` where the tag has none).
            shape: struct { tag: Tag, a: Index = .unknown, b: Index = .unknown },
            /// The rows at `at` (`every`: each row): call the row groups
            /// `groups` (`HoleFacts.group` numbers) on them; `rekey` when
            /// the row's key may change there.
            rows: struct { at: Index, groups: []const u32, rekey: bool = false },
        };
    };

    /// 1.7: what a view event's handler value makes when its event fires
    /// (`Context.programMessage`).
    pub const Message = union(enum) {
        /// The message is key `key`'s constructor applied: call that key's
        /// handler with `args`.
        key: struct { key: u32, args: []const Expr },
        /// A message value, which only a dispatcher can route.
        value: Expr,
    };
};

pub const Error = error{ OutOfMemory, Reported };

/// One export of the markup runtime a lowering's emitted code imports.
pub const RuntimeExport = struct {
    name: []const u8,
    arity: u8,
};

/// The compile-time half of §9.4.6's check: a lowering written against a
/// major version this interface is not, or a newer minor, does not compile
/// into beni. The registry `build.zig` generates calls it for every
/// lowering it lists.
pub fn checkTargets(comptime l: Lowering) void {
    if (l.targets.major != version.major or l.targets.minor > version.minor) {
        @compileError(std.fmt.comptimePrint(
            "the markup lowering '{s}' targets interface {d}.{d}, and this beni has interface {d}.{d}",
            .{ l.name, l.targets.major, l.targets.minor, version.major, version.minor },
        ));
    }
}

// ---- The typed markup tree (§9.4.2) -----------------------------------------

pub const Tree = struct {
    /// The module's markup sites, in instruction order.
    roots: []const Root,
    /// `For` rows and `Show` bodies.
    rows: []const Row,
    /// Every `Node.Index` points in here; `payload` indexes the array of
    /// the node's kind.
    nodes: []const Node,
    elements: []const Element,
    fragments: []const Fragment,
    texts: []const Text,
    holes: []const Hole,
    components: []const Component,
    fors: []const For,
    shows: []const Show,
    /// Attributes, escapes and events, in source order per element.
    items: []const Item,
    /// Class and style lists written in place.
    entries: []const Entry,
    props: []const Prop,
    /// Ranges of children, in source order.
    children: []const Node.Index,
    /// Markup names, text and constants: UTF-8, text already trimmed and
    /// decoded (language.md §11.4).
    strings: Strings,
    /// The vocabulary rows the nodes name, with their facts.
    vocabulary: Vocabulary,
    /// The newest interface version whose gated feature the tree uses.
    requires: Version,
    /// 1.2: per value, whether it is a value of a `markup` row's root that
    /// reads nothing but the row's item — no input, no capture, no position
    /// — so it is the same whenever the item is. Empty: none is known to.
    item_only: []const bool = &.{},
    /// 1.4: per value, whether it is the same JavaScript value every time
    /// it is evaluated — a literal, a constructor of no fields, a top-level
    /// value or function — so it need not be kept or compared from render
    /// to render. Empty: none is known to be.
    constant: []const bool = &.{},

    /// 1.5: per value of a root of kind `expression`, a range of
    /// `read_sets`: the positions in its root's `reads` of the paths it
    /// reads. Empty: no value is known to read anything.
    value_reads: []const Range = &.{},
    read_sets: []const u32 = &.{},
    /// 1.5: per value, whether evaluating it may have an effect other than
    /// `Debug`'s (language.md §11.11): a lowering evaluates such a value of
    /// a grouped root on every render. Empty: none may.
    every_render: []const bool = &.{},
    /// 1.5: per value, `k + 1` when the value is exactly its root's `k`-th
    /// read — a local read through its fields and nothing more — and 0
    /// otherwise. Empty: none is known to be.
    value_paths: []const u32 = &.{},

    /// The position in its root's `reads` of the path value `v` is
    /// exactly, if it is one (`value_paths`).
    pub fn pathOf(t: *const Tree, v: Value.Index) ?u32 {
        const at = @backingInt(v);
        if (at >= t.value_paths.len or t.value_paths[at] == 0) return null;
        return t.value_paths[at] - 1;
    }

    /// Whether value `v` is the same on every evaluation (`constant`).
    pub fn isConstant(t: *const Tree, v: Value.Index) bool {
        const at = @backingInt(v);
        return at < t.constant.len and t.constant[at];
    }

    /// Whether value `v` is evaluated on every render (`every_render`).
    pub fn everyRender(t: *const Tree, v: Value.Index) bool {
        const at = @backingInt(v);
        return at < t.every_render.len and t.every_render[at];
    }

    /// The positions in its root's `reads` of the paths value `v` reads
    /// (`value_reads`).
    pub fn readsOf(t: *const Tree, v: Value.Index) []const u32 {
        const at = @backingInt(v);
        if (at >= t.value_reads.len) return &.{};
        const r = t.value_reads[at];
        return t.read_sets[r.start..][0..r.len];
    }

    /// Whether value `v` reads only its row's item (`item_only`).
    pub fn itemOnly(t: *const Tree, v: Value.Index) bool {
        const at = @backingInt(v);
        return at < t.item_only.len and t.item_only[at];
    }

    pub fn root(t: *const Tree, i: Root.Index) Root {
        return t.roots[@backingInt(i)];
    }

    pub fn row(t: *const Tree, i: Row.Index) Row {
        return t.rows[@backingInt(i)];
    }

    pub fn kind(t: *const Tree, n: Node.Index) Node.Kind {
        return t.nodes[@backingInt(n)].kind;
    }

    pub fn element(t: *const Tree, n: Node.Index) Element {
        return t.elements[t.payload(n, .element)];
    }

    pub fn fragment(t: *const Tree, n: Node.Index) Fragment {
        return t.fragments[t.payload(n, .fragment)];
    }

    pub fn text(t: *const Tree, n: Node.Index) Text {
        return t.texts[t.payload(n, .text)];
    }

    pub fn hole(t: *const Tree, n: Node.Index) Hole {
        return t.holes[t.payload(n, .hole)];
    }

    pub fn component(t: *const Tree, n: Node.Index) Component {
        return t.components[t.payload(n, .component)];
    }

    pub fn for_(t: *const Tree, n: Node.Index) For {
        return t.fors[t.payload(n, .for_)];
    }

    pub fn show(t: *const Tree, n: Node.Index) Show {
        return t.shows[t.payload(n, .show)];
    }

    pub fn childrenOf(t: *const Tree, r: Range) []const Node.Index {
        return t.children[r.start..][0..r.len];
    }

    pub fn itemsOf(t: *const Tree, r: Range) []const Item {
        return t.items[r.start..][0..r.len];
    }

    pub fn entriesOf(t: *const Tree, r: Range) []const Entry {
        return t.entries[r.start..][0..r.len];
    }

    pub fn propsOf(t: *const Tree, r: Range) []const Prop {
        return t.props[r.start..][0..r.len];
    }

    pub fn string(t: *const Tree, i: Strings.Index) []const u8 {
        return t.strings.get(i);
    }

    pub fn elementFacts(t: *const Tree, r: ElementRow) ElementFacts {
        return t.vocabulary.elements[@backingInt(r)];
    }

    pub fn attributeFacts(t: *const Tree, r: AttributeRow) AttributeFacts {
        return t.vocabulary.attributes[@backingInt(r)];
    }

    pub fn eventFacts(t: *const Tree, r: EventRow) EventFacts {
        return t.vocabulary.events[@backingInt(r)];
    }

    fn payload(t: *const Tree, n: Node.Index, expected: Node.Kind) u32 {
        const node = t.nodes[@backingInt(n)];
        std.debug.assert(node.kind == expected);
        return node.payload;
    }
};

/// Where a root or a row sits: the module's index and its instruction's
/// (backend.md §15.2). What identifies a template, never its text.
pub const Site = struct { module: u32, inst: u32 };

pub const Root = struct {
    site: Site,
    kind: Kind,
    /// The markup; `.none` for `row_lambda`, whose last value is its result.
    node: Node.Index,
    /// The values this root evaluates, in evaluation order (language.md §6).
    values: Value.Range,
    /// 1.5, `expression` only: values that each read one local of the
    /// enclosing declaration whole — every local a value reads, bound
    /// outside the root, in first-use order.
    inputs: Value.Range = .{ .start = 0, .len = 0 },
    /// 1.5, `expression` only: values that each read one path through one
    /// of the inputs — every path a value reads, distinct, in first-use
    /// order (`Tree.readsOf`).
    reads: Value.Range = .{ .start = 0, .len = 0 },
    /// 1.5, `expression` only: values that each are a constant `let` of
    /// the enclosing declaration only this root's values read, which the
    /// root evaluates (`Context.bindLet`), in source order.
    lets: Value.Range = .{ .start = 0, .len = 0 },

    pub const Index = enum(u32) { _ };
    pub const Kind = enum(u8) { expression, row_markup, row_lambda, _ };
};

/// A `For` row or a `Show` body: the function applied per item.
pub const Row = struct {
    /// The row function's instruction.
    site: Site,
    kind: Kind,
    /// `markup`: a `row_markup` root; `lambda`: a `row_lambda` root;
    /// `function`: unused.
    body: Root.Index,
    /// `function`: the row function, a value of the enclosing root.
    function: ?Value.Index,
    /// 1 (the item) or 2 (the item and its position; `For` only).
    arity: u8,
    /// The body may use the position.
    reads_index: bool,
    /// Values of the enclosing root: the locals the body uses, whole.
    captures: Value.Range,
    /// Values of the enclosing root: what a skip compares besides the item
    /// and the position (language.md §11.9); for `function`, the function.
    inputs: Value.Range,
    /// 1.3: the input that is a selector (language.md §11.9), set only on
    /// the `markup` row of a `For` keyed by a key function or by reference.
    /// Null: none is.
    selector: ?Selector = null,

    pub const Index = enum(u32) { _ };
    pub const Kind = enum(u8) { markup, lambda, function, _ };
};

/// 1.3: a row input read only in `==`/`/=` comparisons with the row's list
/// key (boundary.md §9.4.6). A row whose item, position and other inputs
/// are as last render's, and whose list key is `===` neither to last
/// render's probe nor to this one's, may be skipped when only it changed.
pub const Selector = struct {
    /// Its position among `Row.inputs`.
    input: u32,
    /// A value of the enclosing root that evaluates nothing, asked for
    /// wherever the inputs may be: the one key the comparisons can hold
    /// for, or a value `===` to no key.
    probe: Value.Index,
};

pub const Node = struct {
    kind: Kind,
    payload: u32,

    pub const Index = enum(u32) { none = std.math.maxInt(u32), _ };
    pub const Kind = enum(u8) { element, fragment, text, hole, component, for_, show, _ };
};

pub const Element = struct { row: ElementRow, items: Range, children: Range };
pub const Fragment = struct { children: Range };
/// Trimmed and decoded: the text the page shows.
pub const Text = struct { text: Strings.Index };
pub const Hole = struct {
    value: Value.Index,
    kind: HoleKind,
    /// 1.1: set on an `html` hole whose value is a saturated call of a
    /// top-level function that passes no evidence (language.md §11.6). The
    /// hole's `value` is the call made of these, so a lowering that ignores
    /// this renders the hole as before.
    call: ?Call = null,
};

/// A helper call in a hole: `callee` evaluates nothing and may be asked for
/// anywhere in the module, a hoisted kind included; `args` are values of
/// the root. A lowering may make the call only when an argument is not
/// `===` the one it was given last render (§9.4.4).
pub const Call = struct { callee: Value.Index, args: Value.Range };
pub const HoleKind = enum(u8) { text_string, text_number, text_char, text_bool, html, maybe_html, list_html, _ };

pub const Component = struct {
    props: Range,
    spread: ?Value.Index,
    /// `children` written as one hole: that hole's value.
    children: ?Value.Index,
    /// `children` written as markup between the tags: the children, which
    /// the lowering renders as one markup value and hands to
    /// `cx.componentCall`. Empty otherwise.
    children_nodes: Range,
    /// 1.5: the call may have an effect other than `Debug`'s: a lowering
    /// makes it on every render, never skipped.
    impure: bool = false,
};

pub const For = struct {
    each: Value.Index,
    fallback: ?Value.Index,
    mode: Mode,
    key: ?Value.Index,
    item_is_primitive: bool,
    row: Row.Index,

    pub const Mode = enum(u8) { key, position, reference, _ };
};

pub const Show = struct {
    when: Value.Index,
    fallback: ?Value.Index,
    mode: Mode,
    key: ?Value.Index,
    value_is_primitive: bool,
    body: Row.Index,

    pub const Mode = enum(u8) { key, identity, _ };
};

/// One attribute, escape or event, in source order.
pub const Item = struct {
    kind: Kind,
    name: Strings.Index,
    /// `attribute`: its row.
    attribute: AttributeRow,
    /// `event`: its row.
    event: EventRow,
    /// `attribute`, `escape`: the value class the checker recorded.
    class: Class,
    /// `event`: the handler's form.
    form: Form,
    /// `attribute`, `escape`: the value is a URL — the row says `url`, or
    /// the escape's name is one a URL is written to — so a lowering must
    /// refuse a script URL in it.
    url: bool,
    value: ItemValue,

    pub const Kind = enum(u8) { attribute, escape, event, _ };
    pub const Form = enum(u8) { message, payload, _ };
};

pub const Class = enum(u8) { string, int, float, bool, maybe_string, class_list, style_list, _ };

pub const ItemValue = struct {
    kind: Kind,
    /// `constant`: known at compile time (language.md §11.5).
    constant: Constant,
    /// `dynamic`: the value (for an event, the handler). `entries`: the
    /// whole list, for a lowering that writes it through its runtime
    /// rather than entry by entry.
    dynamic: ?Value.Index,
    /// `entries`: into `Tree.entries`.
    entries: Range,

    pub const Kind = enum(u8) { constant, dynamic, entries, _ };
};

pub const Constant = struct {
    kind: Kind,
    /// `string`: its text; `number`: its JavaScript spelling.
    text: Strings.Index,
    bool: bool,

    pub const Kind = enum(u8) { none, string, number, bool, _ };
};

/// One entry of a class or style list written in place; its value is a
/// constant or dynamic.
pub const Entry = struct { name: Strings.Index, value: ItemValue };

pub const Prop = struct { field: Strings.Index, value: Value.Index };

/// An opaque handle: the compiler maps it to what computes it.
pub const Value = struct {
    pub const Index = enum(u32) { _ };
    pub const Range = struct {
        start: u32,
        len: u32,

        pub fn at(r: Value.Range, i: u32) Value.Index {
            std.debug.assert(i < r.len);
            return @fromBackingInt(@intCast(r.start + i));
        }
    };
};

pub const Range = struct { start: u32, len: u32 };

pub const Strings = struct {
    bytes: []const u8,
    spans: []const Span,

    pub const Index = enum(u32) { _ };
    pub const Span = struct { start: u32, len: u32 };

    pub fn get(s: *const Strings, i: Index) []const u8 {
        const span = s.spans[@backingInt(i)];
        return s.bytes[span.start..][0..span.len];
    }
};

/// Only the rows this module's nodes name, re-indexed densely.
pub const Vocabulary = struct {
    elements: []const ElementFacts,
    attributes: []const AttributeFacts,
    events: []const EventFacts,
};

pub const ElementRow = enum(u32) { none = std.math.maxInt(u32), _ };
pub const AttributeRow = enum(u32) { none = std.math.maxInt(u32), _ };
pub const EventRow = enum(u32) { none = std.math.maxInt(u32), _ };

pub const ElementFacts = struct {
    name: Strings.Index,
    void: bool,
    namespace: Namespace,

    pub const Namespace = enum(u8) { html, svg, mathml, _ };
};

pub const AttributeFacts = struct {
    name: Strings.Index,
    /// `property`: the JavaScript name (the attribute's own when unnamed).
    property: ?Strings.Index,
    stateful: bool,
    url: bool,
    raw: bool,
    classes: bool,
    styles: bool,
};

pub const EventFacts = struct {
    name: Strings.Index,
    dom_name: Strings.Index,
    delegated: bool,
    prevent_default: bool,
    stop_propagation: bool,
    has_extractor: bool,
};

// ---- The builder surface (§9.4.3) -------------------------------------------

/// A name the lowering was given or made.
pub const Name = enum(u32) { _ };
/// A JavaScript expression.
pub const Expr = enum(u32) { _ };
/// An appendable list of JavaScript statements.
pub const Block = enum(u32) { _ };

/// The build's options, read-only.
pub const Build = struct {
    /// `--release`.
    release: bool,
    /// `--library`: no entry file, so no program start (§9.4.5).
    library: bool,
    /// 1.7: `--fuzz`, a hidden test-only flag (`browser-direct.md` §8.3):
    /// a program lowering makes each mounted program's messages reachable
    /// as values from outside the page, for differential fuzzing.
    fuzz: bool = false,
};

/// Everything a lowering may do, and there is nothing else.
pub const Context = struct {
    build: Build,
    js: Js,
    /// Working memory for the lowering, freed when the module's lowering
    /// ends: nothing allocated here outlives it.
    arena: std.mem.Allocator,
    impl: *anyopaque,
    vtable: *const VTable,

    /// The markup node every following JavaScript node is positioned at.
    pub fn at(cx: *Context, node: Node.Index) void {
        cx.vtable.at(cx.impl, node);
    }

    /// A local name, unique in the module.
    pub fn fresh(cx: *Context, hint: []const u8) Error!Name {
        return cx.vtable.fresh(cx.impl, hint);
    }

    /// A module-level `const` whose initialiser must be pure, emitted after
    /// the module's imports in hoist order.
    pub fn hoist(cx: *Context, hint: []const u8, init: Expr) Error!Name {
        return cx.vtable.hoist(cx.impl, hint, init);
    }

    /// A module-level function declaration, hoisted likewise.
    pub fn hoistFunction(cx: *Context, hint: []const u8, params: []const Name, body: Block) Error!Name {
        return cx.vtable.hoist_function(cx.impl, hint, params, body);
    }

    /// The name the module's first hoist under `hint` was given — what `module`
    /// hoisted, read back in `root` — or null. A lowering keeps no state of
    /// its own between calls (§9.6), so this is how a root finds it.
    pub fn hoisted(cx: *Context, hint: []const u8) ?Name {
        return cx.vtable.hoisted(cx.impl, hint);
    }

    /// The import of one of the lowering's declared runtime exports.
    pub fn runtime(cx: *Context, name: []const u8) Error!Name {
        return cx.vtable.runtime(cx.impl, name);
    }

    /// What value `v` is bound to: in `root`, a value of that root; inside
    /// a function a row was placed in, a value of that row's root.
    pub fn value(cx: *Context, v: Value.Index) Error!Expr {
        return cx.vtable.value(cx.impl, v);
    }

    /// Emit the row's root's values into `block`, with the item, the
    /// position and each capture bound to the names given — or, with no
    /// captures given, read where the function is placed. Returns a
    /// `lambda` row's result and null for a `markup` row.
    pub fn rowValues(cx: *Context, block: Block, row: Row.Index, item: Name, index: ?Name, captures: []const Name) Error!?Expr {
        return cx.vtable.row_values(cx.impl, block, row, item, index, captures);
    }

    /// `rowValues`, with the values named in `apart` — each one `Tree.itemOnly`
    /// — emitted into `apart_block` instead, after the others: a lowering
    /// that runs `apart_block` only when the item changed recomputes nothing
    /// that could not have changed (1.2). A value not item-only stays in
    /// `block`.
    pub fn rowValuesApart(cx: *Context, block: Block, apart_block: Block, row: Row.Index, item: Name, index: ?Name, captures: []const Name, apart: []const Value.Index) Error!?Expr {
        return cx.vtable.row_values_apart(cx.impl, block, apart_block, row, item, index, captures, apart);
    }

    /// 1.5: whether the compiler left root `r`'s values for the lowering
    /// to evaluate (a lowering that sets `Lowering.groups` only): what the
    /// root evaluates to where it stands then reads only `Root.inputs`.
    pub fn grouped(cx: *Context, r: Root.Index) bool {
        return cx.vtable.grouped(cx.impl, r);
    }

    /// 1.5: from here until `unbindInputs`, each of grouped root `r`'s
    /// inputs' locals is read under the name given, one per input.
    pub fn bindInputs(cx: *Context, r: Root.Index, names: []const Name) Error!void {
        return cx.vtable.bind_inputs(cx.impl, r, names);
    }

    /// 1.5: from here until `unbindInputs`, grouped root `r`'s `k`-th
    /// `let` (`Root.lets`) is read under `name`.
    pub fn bindLet(cx: *Context, r: Root.Index, k: u32, name: Name) Error!void {
        return cx.vtable.bind_let(cx.impl, r, k, name);
    }

    pub fn unbindInputs(cx: *Context, r: Root.Index) void {
        cx.vtable.unbind_inputs(cx.impl, r);
    }

    /// 1.5: evaluate the values of grouped root `r` named in `values` into
    /// `block`, in the root's order, with its inputs bound.
    pub fn rootValues(cx: *Context, block: Block, r: Root.Index, values: []const Value.Index) Error!void {
        return cx.vtable.root_values(cx.impl, block, r, values);
    }

    /// A call of a beni function value, which takes its arguments directly.
    pub fn call(cx: *Context, callee: Expr, args: []const Expr) Error!Expr {
        return cx.js.call(callee, args);
    }

    /// The component's call: the props record built as a record literal is
    /// (or a record update over the spread), with its evidence. `children`
    /// is the lowering's rendering of `Component.children_nodes`, and must
    /// be given exactly when they are not empty.
    pub fn componentCall(cx: *Context, node: Node.Index, children: ?Expr) Error!Expr {
        return cx.vtable.component_call(cx.impl, node, children);
    }

    /// The event's payload extractor, or null when it has none.
    pub fn extractor(cx: *Context, item: u32) Error!?Expr {
        return cx.vtable.extractor(cx.impl, item);
    }

    /// The payload of a `Just`, or `null` for `Nothing`.
    pub fn maybe(cx: *Context, e: Expr) Error!Expr {
        return cx.vtable.maybe(cx.impl, e);
    }

    /// Whether a `Maybe` is `Just`: what tells `Just ()`, whose payload is
    /// `null`, from `Nothing`.
    pub fn isJust(cx: *Context, e: Expr) Error!Expr {
        return cx.vtable.is_just(cx.impl, e);
    }

    /// Contribute one pair of program start data (§9.4.5).
    pub fn start(cx: *Context, key: []const u8, val: []const u8) Error!void {
        return cx.vtable.start(cx.impl, key, val);
    }

    /// Report `markup_restructured` at the node; the lowering then returns
    /// the error, and the build writes nothing.
    pub fn report(cx: *Context, node: Node.Index, message: []const u8) error{ OutOfMemory, Reported } {
        return cx.vtable.report(cx.impl, node, message);
    }

    /// 1.6: report `not_implemented` at the node — markup this lowering
    /// does not compile yet; the lowering then returns the error.
    pub fn notImplemented(cx: *Context, node: Node.Index, message: []const u8) error{ OutOfMemory, Reported } {
        return cx.vtable.not_implemented(cx.impl, node, message);
    }

    /// 1.6, inside `Lowering.program` only: emit the evaluation of the
    /// program's `init` into `block`, bound to a name that `--release` keeps
    /// when `init` may have an effect, and return that name. At most once
    /// per program: `init` is evaluated where the lowering places the
    /// block, and nowhere else.
    pub fn programInit(cx: *Context, block: Block) Error!Expr {
        return cx.vtable.program_init(cx.impl, block);
    }

    /// 1.6, inside `Lowering.program` only: report `code` at a part of the
    /// program's call; the lowering then returns the error.
    pub fn programReport(cx: *Context, part: Program.Part, code: Program.Code, message: []const u8) error{ OutOfMemory, Reported } {
        return cx.vtable.program_report(cx.impl, part, code, message);
    }

    /// 1.7, inside `Lowering.program` only: the program's leaf message
    /// keys (`write-sets.md` §4.4), in the order `beni dump --stage=writes`
    /// prints them — a key's named children before its default one. A
    /// program the write-set pass does not recognise (§1.1) has one key,
    /// `*`. Every message the program can receive is under exactly one.
    pub fn programKeys(cx: *Context) []const Program.Key {
        return cx.vtable.program_keys(cx.impl);
    }

    /// 1.7, inside `Lowering.program` only: what the write-set pass says of
    /// one hole of the program's `view` root.
    pub fn programHole(cx: *Context, hole: Program.HoleRef) Program.HoleFacts {
        return cx.vtable.program_hole(cx.impl, hole);
    }

    /// 1.7, inside `Lowering.program` only: whether key `key`'s write set
    /// conflicts with read set `group` (`write-sets.md` §2.5, with tag
    /// reads): whether that key's handler must call the group.
    pub fn programCalls(cx: *Context, key: u32, group: u32) bool {
        return cx.vtable.program_calls(cx.impl, key, group);
    }

    /// 1.7, inside `Lowering.program` only: the program's `update` as a
    /// function value, evaluated into `block`, when some key's arm calls it
    /// rather than being written in place (an `update` of another module,
    /// or computed); null when every arm is written in place. At most once
    /// per program.
    pub fn programUpdate(cx: *Context, block: Block) Error!?Expr {
        return cx.vtable.program_update(cx.impl, block);
    }

    /// 1.7, inside `Lowering.program` only: key `key`'s arm of `update`
    /// (`browser-direct.md` §4.1, step 1), its statements into `block`,
    /// with the message's payload read from `params` (`Program.Key.params`
    /// of them) and the old model from `model`; returns the new model.
    /// `update` is `programUpdate`'s result.
    pub fn programArm(cx: *Context, key: u32, block: Block, params: []const Name, model: Expr, update: ?Expr) Error!Expr {
        return cx.vtable.program_arm(cx.impl, key, block, params, model, update);
    }

    /// 1.7, inside `Lowering.program` only: from here until
    /// `programViewLeave`, the `view` root's inputs are what `view` makes
    /// of `model` — its parameter bound to it, into `block` — so that
    /// `rootValues` and `programMessage` evaluate the root's values against
    /// that model. A new function's scope, as `bindInputs` is.
    pub fn programViewEnter(cx: *Context, block: Block, model: Expr) Error!void {
        return cx.vtable.program_view_enter(cx.impl, block, model);
    }

    pub fn programViewLeave(cx: *Context) void {
        cx.vtable.program_view_leave(cx.impl);
    }

    /// 1.7, inside `programViewEnter`: an event's handler value `value`,
    /// with the event's `payload` for a payload-form handler, as what it
    /// sends — the key and its handler's arguments when the value is a
    /// constructor (applied) whose key is a handler's, read at the event
    /// (`browser-direct.md` §4.2, Q1), or else the message value.
    pub fn programMessage(cx: *Context, block: Block, handler: Value.Index, payload: ?Expr) Error!Program.Message {
        return cx.vtable.program_message(cx.impl, block, handler, payload);
    }

    /// 1.7, inside `Lowering.program` only: the dispatcher's body
    /// (`browser-direct.md` §4.4) into `block` — the message `msg`'s tags
    /// read along the key tree, and `handlers[k]` called with key `k`'s
    /// payload read from it. A message under no key is impossible
    /// (`write-sets.md` §4.4), so the last key is the fallback.
    pub fn programDispatch(cx: *Context, block: Block, msg: Expr, handlers: []const Name) Error!void {
        return cx.vtable.program_dispatch(cx.impl, block, msg, handlers);
    }

    /// 1.7: whether evaluating value `v` may call `Debug` — directly or
    /// through any function it calls, transitively. A value the
    /// development verify mode would print again by evaluating it twice
    /// (`browser-direct.md` §8.3).
    pub fn reachesDebug(cx: *Context, v: Value.Index) bool {
        return cx.vtable.reaches_debug(cx.impl, v);
    }

    /// 1.8, inside `Lowering.program` only: what the write-set pass says
    /// of a `For` node of the program's `view`.
    pub fn programList(cx: *Context, node: Node.Index) Program.ListFacts {
        return cx.vtable.program_list(cx.impl, node);
    }

    /// 1.8, inside `Lowering.program` only: what key `key`'s write set
    /// does to the rows of `For` node `node` (`browser-direct.md` §6.2):
    /// its shape edits and its row visits, each under the enclosing `For`s'
    /// rows it is in. Empty: the key changes nothing the list shows.
    pub fn programEdits(cx: *Context, key: u32, node: Node.Index) []const Program.Edit {
        return cx.vtable.program_edits(cx.impl, key, node);
    }

    /// 1.8, inside `Lowering.program` only: index symbol `index` of key
    /// `key`'s edits, evaluated into `block` from the handler's `params`
    /// and the old model `model` (the arm has not replaced it); null when the handler
    /// cannot evaluate it.
    pub fn programIndex(cx: *Context, key: u32, block: Block, params: []const Name, model: Expr, index: Program.Index) Error!?Expr {
        return cx.vtable.program_index(cx.impl, key, block, params, model, index);
    }

    /// 1.8: `rowValues` for the values named in `values` only — each a value
    /// of the row's root — with the item and position bound and the row's
    /// `let`s evaluated, in the root's order; none binds the item alone.
    pub fn rowValuesOf(cx: *Context, block: Block, row: Row.Index, item: Name, index: ?Name, values: []const Value.Index) Error!void {
        return cx.vtable.row_values_of(cx.impl, block, row, item, index, values);
    }

    /// 1.8, inside `Lowering.program` only: the text the template holds for
    /// row `row` of a `For` K3 bakes, in the place of a hole of its row,
    /// verbatim; null when that hole is not baked.
    pub fn programRowBake(cx: *Context, hole: Program.HoleRef, row: u32) ?[]const u8 {
        return cx.vtable.program_row_bake(cx.impl, hole, row);
    }
};

/// `JsIr` restricted to what a template needs. Assignment is a statement,
/// never an expression; there are no loops, no `switch`, no `throw`, no
/// spread, no import or export, and no name the lowering was not given.
pub const Js = struct {
    impl: *anyopaque,
    vtable: *const VTable,

    pub fn string(js: Js, bytes: []const u8) Error!Expr {
        return js.vtable.literal(js.impl, .string, bytes);
    }

    /// A number literal, spelled as JavaScript spells it.
    pub fn number(js: Js, spelling: []const u8) Error!Expr {
        return js.vtable.literal(js.impl, .number, spelling);
    }

    pub fn literal(js: Js, which: Literal) Error!Expr {
        return js.vtable.literal(js.impl, which, "");
    }

    /// `` `a${b}c` ``.
    pub fn template(js: Js, parts: []const TemplatePart) Error!Expr {
        return js.vtable.template(js.impl, parts);
    }

    pub fn name(js: Js, n: Name) Error!Expr {
        return js.vtable.name(js.impl, n);
    }

    pub fn call(js: Js, callee: Expr, args: []const Expr) Error!Expr {
        return js.vtable.call(js.impl, callee, args);
    }

    /// `object.field`, the field a constant name.
    pub fn member(js: Js, target: Expr, field: []const u8) Error!Expr {
        return js.vtable.member(js.impl, target, field);
    }

    /// `object[index]`.
    pub fn index(js: Js, target: Expr, at: Expr) Error!Expr {
        return js.vtable.index(js.impl, target, at);
    }

    pub fn object(js: Js, properties: []const Property) Error!Expr {
        return js.vtable.object(js.impl, properties);
    }

    pub fn array(js: Js, elements: []const Expr) Error!Expr {
        return js.vtable.array(js.impl, elements);
    }

    pub fn arrow(js: Js, params: []const Name, body: Block) Error!Expr {
        return js.vtable.arrow(js.impl, params, body);
    }

    /// `test ? consequent : alternate`.
    pub fn cond(js: Js, test_: Expr, consequent: Expr, alternate: Expr) Error!Expr {
        return js.vtable.cond(js.impl, test_, consequent, alternate);
    }

    pub fn binary(js: Js, op: BinaryOp, left: Expr, right: Expr) Error!Expr {
        return js.vtable.binary(js.impl, op, left, right);
    }

    pub fn unary(js: Js, op: UnaryOp, operand: Expr) Error!Expr {
        return js.vtable.unary(js.impl, op, operand);
    }

    pub fn block(js: Js) Error!Block {
        return js.vtable.block(js.impl);
    }

    /// `const name = value;`
    pub fn constant(js: Js, into: Block, n: Name, value: Expr) Error!void {
        return js.vtable.statement(js.impl, into, .{ .constant = .{ .name = n, .value = value } });
    }

    /// `let name;` or `let name = value;`
    pub fn let(js: Js, into: Block, n: Name, value: ?Expr) Error!void {
        return js.vtable.statement(js.impl, into, .{ .let = .{ .name = n, .value = value } });
    }

    /// `target = value;`, to a local, a member or an index.
    pub fn assign(js: Js, into: Block, target: Expr, value: Expr) Error!void {
        return js.vtable.statement(js.impl, into, .{ .assign = .{ .target = target, .value = value } });
    }

    pub fn @"if"(js: Js, into: Block, condition: Expr, then: Block, otherwise: ?Block) Error!void {
        return js.vtable.statement(js.impl, into, .{ .@"if" = .{ .condition = condition, .then = then, .otherwise = otherwise } });
    }

    pub fn @"return"(js: Js, into: Block, value: ?Expr) Error!void {
        return js.vtable.statement(js.impl, into, .{ .@"return" = value });
    }

    pub fn expression(js: Js, into: Block, value: Expr) Error!void {
        return js.vtable.statement(js.impl, into, .{ .expression = value });
    }

    /// `{ … }`, the statements of `inner`.
    pub fn nested(js: Js, into: Block, inner: Block) Error!void {
        return js.vtable.statement(js.impl, into, .{ .block = inner });
    }
};

pub const Literal = enum(u8) { string, number, true, false, null, undefined, _ };

pub const TemplatePart = union(enum) {
    text: []const u8,
    expr: Expr,
};

pub const Property = struct { key: []const u8, value: Expr };

pub const BinaryOp = enum(u8) { strict_eq, strict_ne, logical_and, logical_or, add, _ };
pub const UnaryOp = enum(u8) { not, type_of, _ };

pub const Statement = union(enum) {
    constant: struct { name: Name, value: Expr },
    let: struct { name: Name, value: ?Expr },
    assign: struct { target: Expr, value: Expr },
    @"if": struct { condition: Expr, then: Block, otherwise: ?Block },
    @"return": ?Expr,
    expression: Expr,
    block: Block,
};

/// What the compiler implements behind `Context` and `Js`. A lowering never
/// calls it directly.
pub const VTable = struct {
    at: *const fn (impl: *anyopaque, node: Node.Index) void,
    fresh: *const fn (impl: *anyopaque, hint: []const u8) Error!Name,
    hoist: *const fn (impl: *anyopaque, hint: []const u8, init: Expr) Error!Name,
    hoist_function: *const fn (impl: *anyopaque, hint: []const u8, params: []const Name, body: Block) Error!Name,
    hoisted: *const fn (impl: *anyopaque, hint: []const u8) ?Name,
    runtime: *const fn (impl: *anyopaque, name: []const u8) Error!Name,
    value: *const fn (impl: *anyopaque, v: Value.Index) Error!Expr,
    row_values: *const fn (impl: *anyopaque, block: Block, row: Row.Index, item: Name, index: ?Name, captures: []const Name) Error!?Expr,
    row_values_apart: *const fn (impl: *anyopaque, block: Block, apart_block: Block, row: Row.Index, item: Name, index: ?Name, captures: []const Name, apart: []const Value.Index) Error!?Expr,
    grouped: *const fn (impl: *anyopaque, r: Root.Index) bool,
    bind_inputs: *const fn (impl: *anyopaque, r: Root.Index, names: []const Name) Error!void,
    unbind_inputs: *const fn (impl: *anyopaque, r: Root.Index) void,
    bind_let: *const fn (impl: *anyopaque, r: Root.Index, k: u32, name: Name) Error!void,
    root_values: *const fn (impl: *anyopaque, block: Block, r: Root.Index, values: []const Value.Index) Error!void,
    component_call: *const fn (impl: *anyopaque, node: Node.Index, children: ?Expr) Error!Expr,
    extractor: *const fn (impl: *anyopaque, item: u32) Error!?Expr,
    maybe: *const fn (impl: *anyopaque, e: Expr) Error!Expr,
    is_just: *const fn (impl: *anyopaque, e: Expr) Error!Expr,
    start: *const fn (impl: *anyopaque, key: []const u8, value: []const u8) Error!void,
    report: *const fn (impl: *anyopaque, node: Node.Index, message: []const u8) error{ OutOfMemory, Reported },
    not_implemented: *const fn (impl: *anyopaque, node: Node.Index, message: []const u8) error{ OutOfMemory, Reported },
    program_init: *const fn (impl: *anyopaque, block: Block) Error!Expr,
    program_report: *const fn (impl: *anyopaque, at: Program.Part, code: Program.Code, message: []const u8) error{ OutOfMemory, Reported },
    program_keys: *const fn (impl: *anyopaque) []const Program.Key,
    program_hole: *const fn (impl: *anyopaque, hole: Program.HoleRef) Program.HoleFacts,
    program_calls: *const fn (impl: *anyopaque, key: u32, group: u32) bool,
    program_update: *const fn (impl: *anyopaque, block: Block) Error!?Expr,
    program_arm: *const fn (impl: *anyopaque, key: u32, block: Block, params: []const Name, model: Expr, update: ?Expr) Error!Expr,
    program_view_enter: *const fn (impl: *anyopaque, block: Block, model: Expr) Error!void,
    program_view_leave: *const fn (impl: *anyopaque) void,
    program_message: *const fn (impl: *anyopaque, block: Block, handler: Value.Index, payload: ?Expr) Error!Program.Message,
    program_dispatch: *const fn (impl: *anyopaque, block: Block, msg: Expr, handlers: []const Name) Error!void,
    reaches_debug: *const fn (impl: *anyopaque, v: Value.Index) bool,
    program_list: *const fn (impl: *anyopaque, node: Node.Index) Program.ListFacts,
    program_edits: *const fn (impl: *anyopaque, key: u32, node: Node.Index) []const Program.Edit,
    program_index: *const fn (impl: *anyopaque, key: u32, block: Block, params: []const Name, model: Expr, index: Program.Index) Error!?Expr,
    row_values_of: *const fn (impl: *anyopaque, block: Block, row: Row.Index, item: Name, index: ?Name, values: []const Value.Index) Error!void,
    program_row_bake: *const fn (impl: *anyopaque, hole: Program.HoleRef, row: u32) ?[]const u8,

    literal: *const fn (impl: *anyopaque, which: Literal, text: []const u8) Error!Expr,
    template: *const fn (impl: *anyopaque, parts: []const TemplatePart) Error!Expr,
    name: *const fn (impl: *anyopaque, n: Name) Error!Expr,
    call: *const fn (impl: *anyopaque, callee: Expr, args: []const Expr) Error!Expr,
    member: *const fn (impl: *anyopaque, target: Expr, field: []const u8) Error!Expr,
    index: *const fn (impl: *anyopaque, target: Expr, at: Expr) Error!Expr,
    object: *const fn (impl: *anyopaque, properties: []const Property) Error!Expr,
    array: *const fn (impl: *anyopaque, elements: []const Expr) Error!Expr,
    arrow: *const fn (impl: *anyopaque, params: []const Name, body: Block) Error!Expr,
    cond: *const fn (impl: *anyopaque, test_: Expr, consequent: Expr, alternate: Expr) Error!Expr,
    binary: *const fn (impl: *anyopaque, op: BinaryOp, left: Expr, right: Expr) Error!Expr,
    unary: *const fn (impl: *anyopaque, op: UnaryOp, operand: Expr) Error!Expr,
    block: *const fn (impl: *anyopaque) Error!Block,
    statement: *const fn (impl: *anyopaque, into: Block, s: Statement) Error!void,
};

test "a lowering covers the trees of its own major version up to its minor" {
    const t = std.testing;
    try t.expect(Version.covers(.{ .major = 1, .minor = 0 }, .{ .major = 1, .minor = 0 }));
    try t.expect(Version.covers(.{ .major = 1, .minor = 3 }, .{ .major = 1, .minor = 0 }));
    try t.expect(!Version.covers(.{ .major = 1, .minor = 0 }, .{ .major = 1, .minor = 4 }));
    try t.expect(!Version.covers(.{ .major = 2, .minor = 0 }, .{ .major = 1, .minor = 0 }));
}
