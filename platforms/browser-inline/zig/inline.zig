//! The `inline` program lowering (docs/design/browser-inline.md): a program
//! of The Elm Architecture is compiled, not run, into the output tea-inline
//! writes (`../reactivity-research/frameworks/tea-inline/`). Where a program
//! constructor is called, the compiler hands this lowering the program, and
//! the lowering returns its **mount**, a function of the mount node that
//! `Inline.run` calls inside the dispatch guard:
//!
//!     (root) => {
//!       let model = init;
//!       root.insertAdjacentHTML("beforeend", "<div><output></output><button>+1");
//!       const n = root.lastChild;
//!       own(() => { n.remove(); });
//!       const E = n.querySelectorAll("*");
//!       const table = [[[]]];
//!       entry(() => { text(E[0], `${model.count}`); }, table[0][0]);
//!       on(E[1], () => { model.count = model.count + 1; pass(table[0][0]); });
//!       first();
//!     }
//!
//! The view's static markup is one HTML string, written once after the
//! mount node's children, with the end tags HTML makes optional left out
//! (§8.2); each element code refers to is `E[n]` by document order. A
//! binding is one write guarded by a compare (`text`, `prop`, `when`),
//! grouped into one binding entry per set of read sets, which the runtime's
//! `entry` adds to the bucket of each model path it reads in the program's
//! table (§8.4, amended 2026-10-22). Another module's markup is that
//! module's root factory, which makes its own entries — into another root's
//! buckets too — and wires its events. A key's handler is its arm of
//! `update`, then one synchronous pass of the buckets its writes reach, each
//! entry once (§8.3). What the mount added is undone by the function it
//! registers with `own`, which `stop` runs (`boundary.md` §9.4.5, amended
//! 2026-10-17). Everything this lowering cannot compile exactly is a build
//! error that names its class and what to write instead
//! (`browser-inline.md` §5) — never a fallback.

const std = @import("std");
const m = @import("beni_markup");
const parser = @import("platform_html").parser_table;

pub const lowering: m.Lowering = .{
    .name = "inline",
    .targets = .{ .major = 1, .minor = 30 },
    .runtime = &.{
        // `(f, x, read)`: the dispatch guard, which every entry into program
        // code goes through; `read`, an event's `via` extractor, is called
        // first, even when the send waits (boundary.md §9.8.20 (d), #559).
        .{ .name = "send", .arity = 3 },
        // `(f)`: what undoes the mount, run once by `stop`.
        .{ .name = "own", .arity = 1 },
        // Install a subscription with the renderer's captured event entry.
        .{ .name = "subscribe", .arity = 1 },
        .{ .name = "startWork", .arity = 2 },
        .{ .name = "update", .arity = 1 },
        // `(id)`: the element a program mounts at.
        .{ .name = "root", .arity = 1 },
        // `(⊤)`: the page's unmount (`boundary.md` §9.4.5).
        .{ .name = "stop", .arity = 1 },
        // Modifier effects must also be inert on host-retained stopped nodes.
        .{ .name = "stopped", .arity = 1 },
        // `(cmd, dispatch)`: a command's bodies, queued on the guard to run
        // after the dispatch's write pass (`boundary.md` §9.8.4, as amended
        // 2026-10-17), each message one sends handed to `dispatch`.
        .{ .name = "commands", .arity = 2 },
        // The bindings and the listener (`browser-inline.md` §8.2).
        .{ .name = "text", .arity = 2 },
        .{ .name = "prop", .arity = 3 },
        // `(url)`: the value a URL binding writes, `""` for a script URL
        // (§10.5, amended 2026-11-05).
        .{ .name = "safeUrl", .arity = 1 },
        .{ .name = "when", .arity = 2 },
        .{ .name = "on", .arity = 4 },
        // A `For`'s rows (§9, amended 2026-11-23): `(html)` its row's
        // template, and `(parent, end, list, key, make, set)` its rows made to
        // agree with its list.
        .{ .name = "forTemplate", .arity = 1 },
        .{ .name = "forRows", .arity = 6 },
        // `(parent, before, text)`: a text node of a row made and placed.
        .{ .name = "rowText", .arity = 3 },
        // `on` for a handler inside eager arms, apart so that a page with
        // none ships neither it nor its arm walk (#874).
        .{ .name = "onArm", .arity = 5 },
        // `(node)`: a piece root's table of elements (§8.4).
        .{ .name = "part", .arity = 1 },
        // The group runner (§8.4, amended 2026-10-22): `(f, bucket)` makes a
        // binding entry, `(bucket)` and `(buckets)` run a write pass, and
        // `(⊤)` the first pass.
        .{ .name = "entry", .arity = 2 },
        .{ .name = "pass", .arity = 1 },
        .{ .name = "passes", .arity = 1 },
        .{ .name = "first", .arity = 1 },
        // `(rows, elements, from, table, at)`: a run of roots mounted
        // through one table (§8.4, amended 2026-10-24).
        .{ .name = "roots", .arity = 5 },
        // The pushed-state loader (§8.4, amended 2026-10-22 and 2026-10-24):
        // `(model, table, key, raw)` a keyed route, `(model, rows, raws)`
        // routes in turn; the `…Planned` pair for rows with copy plans, and
        // the `…Shaped` ones for rows that may hold a shape, which take
        // `validShape` last.
        .{ .name = "load", .arity = 4 },
        .{ .name = "loadAll", .arity = 3 },
        .{ .name = "loadPlanned", .arity = 4 },
        .{ .name = "loadAllPlanned", .arity = 3 },
        .{ .name = "loadShaped", .arity = 5 },
        .{ .name = "loadAllShaped", .arity = 4 },
        .{ .name = "loadShapedPlanned", .arity = 5 },
        .{ .name = "loadAllShapedPlanned", .arity = 4 },
        // The `…Const` ones for shape rows that may hold constants (§8.4,
        // amended 2026-10-24, #946).
        .{ .name = "loadShapedConst", .arity = 5 },
        .{ .name = "loadAllShapedConst", .arity = 4 },
        .{ .name = "loadShapedPlannedConst", .arity = 5 },
        .{ .name = "loadAllShapedPlannedConst", .arity = 4 },
        // The string form (`prerender.md` §4.3): a text as an element's
        // content holds it, one in a `pre`, a `textarea` or a `listing`, and
        // an attribute's value, quoted.
        .{ .name = "escape", .arity = 1 },
        .{ .name = "escapePre", .arity = 1 },
        .{ .name = "escapeAttribute", .arity = 1 },
        // `(root, html, arms, tags)`: the hydrating mount's table, the
        // prerendered page taken over or mounted fresh (`prerender.md` §6).
        .{ .name = "take", .arity = 4 },
        // Input before the takeover (`prerender.md` §6.5): `(at)` the
        // capture script's records taken, before `take`; `(node, kind, f)`
        // a listener added and noted, `on` and `onArm` through it; and
        // `(top)` the records inside the unit taken over handed to the
        // listeners noted.
        .{ .name = "caught", .arity = 1 },
        .{ .name = "listen", .arity = 3 },
        .{ .name = "onTaken", .arity = 4 },
        .{ .name = "onArmTaken", .arity = 5 },
        .{ .name = "deliver", .arity = 1 },
        // `(⊤)`, `(⊤)` and `(title)`: an application's address and key, and
        // a document's title written (§10).
        .{ .name = "address", .arity = 1 },
        // `(address, route)` the `Url` of a route, `(address)` the one a
        // hydrating application's `init` is handed, and `(url)` the page's
        // own address sent after the first render (`prerender.md` §7.3).
        .{ .name = "routeUrl", .arity = 2 },
        .{ .name = "pageUrl", .arity = 1 },
        .{ .name = "arrived", .arity = 1 },
        // `(schema, at)` the value and route a page of a data site holds,
        // and `(schema, text)` the prerender tree's decode of a page's text
        // (`prerender.md` §8.6, §8.5).
        .{ .name = "pageData", .arity = 2 },
        .{ .name = "decoded", .arity = 2 },
        .{ .name = "navigationKey", .arity = 1 },
        .{ .name = "title", .arity = 1 },
    },
    .module = module,
    .root = root,
    .groups = true,
    .programs = &.{
        .{ .module = "Tea", .name = "sandbox" },
        .{ .module = "Tea", .name = "element" },
        // `browser-inline.md` §10: an element whose view is a document,
        // and one that owns the page's address too.
        .{ .module = "Tea", .name = "document" },
        .{ .module = "Tea", .name = "application", .routed = true },
    },
    .program = program,
    .piece = piece,
    .placements = &.{
        .{ .module = "Browser", .name = "mountAt", .places = .first },
        // `prerender.md` §7.2: the program prerendered at each route.
        .{ .module = "Browser", .name = "prerender", .places = .prerender },
        // `prerender.md` §8.4: the program of each page's value.
        .{ .module = "Browser", .name = "prerenderData", .places = .prerender_data },
    },
    .places = true,
    .constructs = true,
    .arm_fields = true,
    .effects = .{
        .sub = "Sub",
        .cmd = "Cmd",
        .entry_capture = .{ .module = "Listen", .name = "callback" },
        .command_context = true,
        .after_render = true,
        .update_writers = &.{
            .{ .package = .core, .module = "Task", .name = "withClock" },
            .{ .package = .core, .module = "Task", .name = "withLogContext" },
            .{ .package = .core, .module = "Task", .name = "withScheduler" },
            .{ .package = .core, .module = "Task", .name = "addFinalizer" },
            .{ .package = .core, .module = "Task", .name = "cleanupFiber" },
        },
    },
    .no_markup_values = no_markup_values,
    .prerenders = true,
};

const controlled_for = "a `For` inside a control whose value changes, other than as its only child";

const no_markup_values =
    \\A limit of the compiler: `browser-inline` has no markup value yet; it compiles markup only
    \\as a program's `view`, written in place (`docs/design/browser-inline.md` §5, class 1).
    \\Write markup held, passed or returned by a helper in place in the `view`, or build this
    \\program with `--platform=browser-tea`.
;

fn module(cx: *m.Context, tree: *const m.Tree) m.Error!void {
    _ = cx;
    _ = tree;
}

/// Unreachable: `no_markup_values` refuses every root that is not a
/// program's `view`.
fn root(cx: *m.Context, tree: *const m.Tree, index: m.Root.Index) m.Error!m.Expr {
    return cx.notImplemented(tree.root(index).node, no_markup_values);
}

/// The class-1 refusal (`browser-inline.md` §5): a limit of the compiler, a
/// construct this platform does not compile yet, and what to write instead.
fn later(cx: *m.Context, n: m.Node.Index, what: []const u8) m.Error {
    const message = std.fmt.allocPrint(cx.arena,
        \\A limit of the compiler: `browser-inline` does not compile {s} yet
        \\(`docs/design/browser-inline.md` §5, class 1). Write the `view` without it, or build this
        \\program with `--platform=browser-tea`, which compiles it.
    , .{what}) catch return error.OutOfMemory;
    return cx.notImplemented(n, message);
}

/// The class-4 refusal (`browser-inline.md` §5): a limit of the compiler
/// that no slice of the plan has yet in its area.
fn limit(cx: *m.Context, n: m.Node.Index, what: []const u8) m.Error {
    const message = std.fmt.allocPrint(cx.arena,
        \\A limit of the compiler: {s} (`docs/design/browser-inline.md` §8.7; §5, class 4). The
        \\program is valid: it builds with `--platform=browser-tea`.
    , .{what}) catch return error.OutOfMemory;
    return cx.notImplemented(n, message);
}

/// The program hook: the mount of a `Tea.sandbox` or a `Tea.element`.
fn program(cx: *m.Context, tree: *const m.Tree, p: *const m.Program) m.Error!m.Expr {
    if (!p.record) return cx.programReport(.call, .view_not_compiled,
        \\This program's record is a value computed when the page runs, so `browser-inline`
        \\cannot compile its `view`: the platform has no renderer to hand a `view` it did not
        \\compile. Write the record where `Tea.sandbox` or `Tea.element` is called
        \\(`docs/design/browser-inline.md` §5, class 3).
    );
    switch (p.view) {
        .markup => {},
        // `let`s and statements around markup (§8.2, amended 2026-11-23),
        // but not on a page that prerenders.
        .function => if (!p.view_lets) return cx.programReport(.view, .not_implemented,
            \\A limit of the compiler: `browser-inline` compiles a `view` whose body is markup
            \\written in place, after any `let`s, and this one's computes its markup — an `if`, a
            \\`case` or a call — which it does not compile yet (`docs/design/browser-inline.md` §8.2;
            \\§5, class 1). Write the markup in place as the body of `view`, with the choice in a
            \\hole, or build this program with `--platform=browser-tea`.
        ) else if (cx.build.prerender != .none) return cx.programReport(.view, .not_implemented,
            \\A limit of the compiler: `browser-inline` does not compile a `view` with `let`s on a
            \\page that prerenders yet (`docs/design/browser-inline.md` §8.2; §5, class 1). Write
            \\the values in the markup, or build this program with `--platform=browser-tea`.
        ),
        .other_module => return cx.programReport(.view, .not_implemented,
            \\A limit of the compiler: `browser-inline` compiles a `view` declared in the module that
            \\calls the program's constructor, and this one is another module's, which it does not compile yet
            \\(`docs/design/browser-inline.md` §5, class 1). Declare `view` beside the program, or
            \\build this program with `--platform=browser-tea`.
        ),
        else => return cx.programReport(.view, .view_not_compiled,
            \\This program's `view` is a value computed when the page runs, not a function whose
            \\body the compiler can reach as markup, so `browser-inline` cannot compile it: the
            \\platform has no renderer to hand a `view` it did not compile. Name a function, or
            \\write a lambda, whose body is the markup (`docs/design/browser-inline.md` §5,
            \\class 3).
        ),
    }
    const index = p.view_root.?;
    const r = tree.root(index);
    // The prerender tree (`prerender.md` §3.1, §4): `init` and `view` pure,
    // or the build is refused, then the render function in the mount's
    // place.
    if (cx.build.prerender == .tree) {
        try cx.programPure(.init);
        try cx.programPure(.view);
    }
    var page: Page = .{ .cx = cx, .tree = tree, .p = p, .index = index };
    try page.ctxs.append(cx.arena, .{ .parent = null, .node = .none, .arm = 0, .root = index });
    page.top_nodes = try page.markup(r.node, .{}, 0, true);
    if (cx.build.prerender == .tree) return page.render(r.node);
    return page.mount(r.node);
}

// ---- Pieces (`browser-inline.md` §8.4) ------------------------------------

/// What a piece's owner records for the program site: the facts of
/// `m.PieceFacts.data`, in the request's arena.
const PieceData = struct {
    /// The name of the piece that is the root's static markup, its end tags
    /// all written, and its top element's name.
    html: []const u8,
    top: []const u8,
    /// The elements numbered below the top element.
    count: u32,
    /// The root factory's name (`browser-inline.md` §8.4, amended
    /// 2026-10-22), null when the root has no binding and no event: then
    /// nothing is called for it.
    root: ?[]const u8,
    /// What the factory takes after the elements: one holder per argument of
    /// the root's function (`arity`), the root's own row when it fills it,
    /// the program's table when it fills another root's, then one handler
    /// per constructor of `handlers`.
    arity: u32,
    own_row: bool,
    table: bool,
    handlers: []const PieceHandler,
    /// The static markup as a tree, which the program site checks again in
    /// the scope it places the piece in: the parser rebuilds markup by
    /// what is open around it, across the boundary of the piece (#373).
    nodes: []const Html,
    /// The prerender tree's (`prerender.md` §4.1): the name of the root's
    /// render function, `<Module>$<declaration>$$render$<n>`, which takes
    /// the ordinal of the root's first eager arm in the unit, then what the
    /// factory takes after the elements; and how many eager arms the root
    /// has.
    render: ?[]const u8 = null,
    arms: u32 = 0,
    /// The hydrating mount's (`prerender.md` §6.2): the root's eager arms,
    /// by index in its table, its top element 0.
    arm_runs: []const ArmRun = &.{},
    /// The event kinds the root listens to, each once, sorted: what the
    /// capture script of the program's page listens to (`prerender.md`
    /// §6.5, amended 2026-10-29).
    kinds: []const []const u8 = &.{},
};

/// A constructor the root's events send, its fields, and the buckets of the
/// controls one of its events is on: what that event's handler runs
/// whatever it writes (§8.3, *Controlled inputs*).
const PieceHandler = struct { ctor: m.Ctor, fields: u32, controls: []const m.Program.BucketRef };

const no_program: m.Program = .{ .constructor = 0, .record = true, .view = .markup, .view_root = null, .update = .computed };

/// The piece hook: another module's program shows this root, the body of a
/// function its `view` calls. The root is one factory
/// (`<Module>$<declaration>$$root$<n>`, §8.4, amended 2026-10-22), called at
/// mount with the root's elements, one holder per argument of its function,
/// the buckets it fills and one handler per constructor its events send: it
/// makes each binding entry of the root, adds it to the buckets of what it
/// reads, and wires each event. Its static markup is a piece of its own.
fn piece(cx: *m.Context, tree: *const m.Tree, req: *const m.PieceRequest) m.Error!void {
    const js = cx.js;
    var page: Page = .{ .cx = cx, .tree = tree, .p = &no_program, .index = req.root, .piece = true };
    const pg = &page;
    try pg.ctxs.append(cx.arena, .{ .parent = null, .node = .none, .arm = 0, .root = req.root });
    const r = tree.root(req.root);
    pg.top_nodes = try pg.markup(r.node, .{}, 0, true);
    if (pg.top_nodes.len != 1 or pg.top_nodes[0].kind != .element) return limit(cx, r.node, "`browser-inline` writes another module's markup as pieces when it is one element, and this is not");
    for (pg.writes.items) |w| if (w.target == null) return later(cx, r.node, "a binding of the top element of another module's markup");
    for (pg.events.items) |ev| if (ev.target == null) return later(cx, ev.node, "an event on the top element of another module's markup");
    // D-d: a `let` of the view read by one hole is that hole's value; one
    // several read is a memo node, S3's (§8.2).
    for (0..r.lets.len) |k| if (cx.rootLetReaders(req.root, @intCast(k)) > 1) return limit(cx, r.node, "a `let` of this `view` is read by several holes, and `browser-inline` computes a `let` in the binding of the one hole that reads it (D-d); one several holes read is a memo node, which slice S3 brings");
    pg.elements = try cx.fresh("elements");
    const plan = cx.pieceRoot();
    pg.row = plan.row;
    // One holder per argument of the root's function: what the program
    // hands the factory for it, read through as the plan says.
    const holders = try cx.arena.alloc(m.Name, plan.args.len);
    for (holders) |*x| x.* = try cx.fresh("model");
    pg.holders = holders;
    pg.own = try cx.fresh("row");
    pg.table = try cx.fresh("table");
    try pg.guardGroups();
    try pg.group();
    try pg.letsOnce();
    try pg.argsOnce();
    const a = req.arena;
    const body = try js.block();
    pg.body = body;
    // Each binding entry, made in document order and added to its buckets.
    for (pg.functions.items) |*f| try pg.writeEntry(body, f);
    // The events: one handler per constructor, in the order of its first
    // event — the root's own when the plan moved its key here (§8.4,
    // amended 2026-10-22), else a parameter the program hands.
    var handlers: std.ArrayList(PieceHandler) = .empty;
    var params: std.ArrayList(m.Name) = .empty;
    var controls: std.ArrayList(std.ArrayList(m.Program.BucketRef)) = .empty;
    var locals: std.ArrayList(Local) = .empty;
    const names = try cx.arena.alloc(m.Name, pg.events.items.len);
    // Each event's moved key's handler, null for one the program hands.
    const local_of = try cx.arena.alloc(?usize, pg.events.items.len);
    @memset(local_of, null);
    for (pg.events.items, names, local_of) |ev, *name, *local| {
        const v = switch (ev.item.value.kind) {
            .dynamic => ev.item.value.dynamic.?,
            else => return limit(cx, ev.node, "this event's handler is a message written as a literal, which `browser-inline` cannot route to a key"),
        };
        const payload_form = ev.item.form == .payload;
        const sent = cx.pieceEventCtor(v, payload_form) orelse return limit(cx, ev.node, "`browser-inline` wires an event of another module's markup by the constructor alone, which takes the event's payload or nothing, and this event's handler value is a constructor applied to values, or not a constructor");
        const moved_key: ?u32 = for (plan.moved) |mv| {
            if (mv.ctor.module == sent.ctor.module and mv.ctor.index == sent.ctor.index) break mv.key;
        } else null;
        // The buckets of a control this event is on (§8.3).
        var own_controls: std.ArrayList(m.Program.BucketRef) = .empty;
        for (pg.functions.items) |f| for (f.writes.items) |wi| {
            const w = pg.writes.items[wi];
            if (!w.stateful or w.target != ev.target) continue;
            try addRefs(cx.arena, &own_controls, try pg.functionBuckets(&f));
        };
        if (moved_key) |key| {
            const li = for (locals.items, 0..) |x, k| {
                if (x.key == key) break k;
            } else blk: {
                try locals.append(cx.arena, .{ .key = key, .fields = sent.fields, .name = try cx.fresh("on") });
                break :blk locals.items.len - 1;
            };
            name.* = locals.items[li].name;
            local.* = li;
            locals.items[li].uses += 1;
            locals.items[li].payload = payload_form;
            try addRefs(cx.arena, &locals.items[li].controls, own_controls.items);
        } else {
            const hi = for (handlers.items, 0..) |h, k| {
                if (std.meta.eql(h.ctor, sent.ctor)) break k;
            } else blk: {
                try handlers.append(cx.arena, .{ .ctor = sent.ctor, .fields = sent.fields, .controls = &.{} });
                try params.append(cx.arena, try cx.fresh("on"));
                try controls.append(cx.arena, .empty);
                break :blk handlers.items.len - 1;
            };
            name.* = params.items[hi];
            try addRefs(cx.arena, &controls.items[hi], own_controls.items);
        }
    }
    // Each moved key's handler: its arm piece writes the slice the root
    // holds, in place, then its write pass. One a single event sends is
    // written inside that event's listener instead (§8.4, amended
    // 2026-10-24): the payload is read first, exactly where the call read
    // it, and the arm still runs inside `on`'s dispatch guard.
    for (locals.items) |*x| {
        if (inside(x)) continue;
        const hblk = try js.block();
        const fields = try cx.arena.alloc(m.Name, x.fields);
        for (fields) |*f| f.* = try cx.fresh("value");
        try localArm(pg, hblk, x, fields);
        try js.constant(body, x.name, try js.arrow(fields, hblk));
    }
    // Each event wired to its handler; in the client of a prerendering
    // build through `listen` (`prerender.md` §6.5, amended 2026-10-29).
    pg.taking = cx.build.prerender == .client;
    for (pg.events.items, names, local_of) |ev, name, local| {
        const facts = tree.eventFacts(ev.item.event);
        const dom = tree.string(facts.dom_name);
        const kind: ?[]const u8 = if (std.mem.eql(u8, dom, "click")) null else dom;
        const h = try js.name(name);
        var listener = h;
        const own: ?*Local = if (local) |li| (if (inside(&locals.items[li])) &locals.items[li] else null) else null;
        // An event's `via` extractor goes to the runtime with the listener,
        // which takes what it reads: `send` calls it while the event is
        // dispatched, even when the send is queued (§9.8.20 (d), #559).
        const read: ?m.Expr = if (ev.item.form == .payload) try cx.extractor(ev.index) else null;
        if (ev.item.form == .payload) {
            const e = try cx.fresh(if (read != null) "value" else "event");
            const blk = try js.block();
            if (own) |x| {
                const value = if (read != null) e else try cx.fresh("value");
                if (read == null) try js.constant(blk, value, try js.name(e));
                try localArm(pg, blk, x, &.{value});
                listener = try js.arrow(&.{e}, blk);
            } else if (read == null) {
                try js.expression(blk, try js.call(h, &.{try js.name(e)}));
                listener = try js.arrow(&.{e}, blk);
            }
        } else if (own) |x| {
            const blk = try js.block();
            try localArm(pg, blk, x, &.{});
            listener = try js.arrow(&.{}, blk);
        }
        const node = try pg.ref(ev.target);
        if (!facts.prevent_default and !facts.stop_propagation) {
            try js.expression(body, try pg.onCall(node, listener, kind, ev.ctx, read));
            continue;
        }
        const active = try pg.armActivity(ev.ctx);
        const evn = try cx.fresh("event");
        const dom_blk = try js.block();
        if (facts.prevent_default or facts.stop_propagation) {
            const stopped = try js.block();
            try js.@"return"(stopped, null);
            try js.@"if"(dom_blk, try js.call(try js.name(try cx.runtime("stopped")), &.{}), stopped, null);
        }
        if (active) |active_test| {
            const inactive = try js.block();
            try js.@"return"(inactive, null);
            try js.@"if"(dom_blk, try js.unary(.not, active_test), inactive, null);
        }
        if (facts.prevent_default) try js.expression(dom_blk, try js.call(try js.member(try js.name(evn), "preventDefault"), &.{}));
        if (facts.stop_propagation) try js.expression(dom_blk, try js.call(try js.member(try js.name(evn), "stopPropagation"), &.{}));
        try js.expression(dom_blk, try js.call(try js.name(try cx.runtime("send")), if (read) |rd| &.{ listener, try js.name(evn), rd } else &.{ listener, try js.name(evn) }));
        try js.expression(body, try pg.addListener(node, kind orelse "click", try js.arrow(&.{evn}, dom_blk)));
    }
    const out_handlers = try a.alloc(PieceHandler, handlers.items.len);
    for (out_handlers, handlers.items, controls.items) |*o, h, c| o.* = .{ .ctor = h.ctor, .fields = h.fields, .controls = try a.dupe(m.Program.BucketRef, c.items) };
    // The factory, when the root has anything to do at mount.
    var root_name: ?[]const u8 = null;
    if (pg.functions.items.len != 0 or pg.events.items.len != 0) {
        var all: std.ArrayList(m.Name) = .empty;
        try all.append(cx.arena, pg.elements.?);
        try all.appendSlice(cx.arena, holders);
        if (pg.used_own) try all.append(cx.arena, pg.own.?);
        if (pg.used_table) try all.append(cx.arena, pg.table.?);
        try all.appendSlice(cx.arena, params.items);
        const base = try std.fmt.allocPrint(a, "{s}$$root${d}", .{ req.decl, req.ordinal });
        try cx.pieceExport(base, try js.arrow(all.items, body));
        root_name = base;
    }
    // The prerender tree's render function of the root (`prerender.md`
    // §4.1), beside its factory and its string.
    var render_name: ?[]const u8 = null;
    var arms: u32 = 0;
    for (pg.writes.items) |w| {
        if (w.what == .when) arms += 1;
    }
    if (cx.build.prerender == .tree) {
        const rblk = try js.block();
        const base = try cx.fresh("arm");
        try cx.pieceViewEnter(rblk, try pg.viewArgs());
        var rn: Render = .{ .pg = pg, .out = try cx.fresh("html"), .base = base };
        try rn.unit(rblk, null);
        cx.programViewLeave();
        const render_params = try cx.arena.alloc(m.Name, 1 + holders.len);
        render_params[0] = base;
        @memcpy(render_params[1..], holders);
        const render_base = try std.fmt.allocPrint(a, "{s}$$render${d}", .{ req.decl, req.ordinal });
        try cx.pieceExport(render_base, try js.arrow(render_params, rblk));
        render_name = render_base;
    }
    // The root's arms, for the hydrating mount of the program that shows
    // it (`prerender.md` §6.2).
    var layout: Layout = .{ .a = cx.arena };
    try layout.unit(pg, pg.top_nodes[0]);
    const data = try a.create(PieceData);
    // The static markup, a piece of its own: every end tag of the top
    // element written, since the program site writes more after it.
    var html: std.ArrayList(u8) = .empty;
    try serialise(cx.arena, &html, pg.top_nodes, null, false);
    const html_base = try std.fmt.allocPrint(a, "{s}$$html${d}", .{ req.decl, req.ordinal });
    try cx.pieceExport(html_base, try js.string(html.items));
    data.* = .{
        .html = html_base,
        .top = try a.dupe(u8, pg.top_nodes[0].name),
        .nodes = try copyHtml(a, pg.top_nodes),
        .count = pg.count,
        .root = root_name,
        .arity = @intCast(holders.len),
        .own_row = pg.used_own,
        .table = pg.used_table,
        .handlers = out_handlers,
        .render = render_name,
        .arms = arms,
        .arm_runs = try a.dupe(ArmRun, layout.arms.items),
        .kinds = try copyKinds(a, try pg.eventKinds()),
    };
    req.facts.* = .{ .written = true, .data = data };
}

/// A handler a piece's factory writes itself: a moved key's (§8.4, amended
/// 2026-10-22), its fields, its name, and the buckets of the controls its
/// events are on.
const Local = struct { key: u32, fields: u32, name: m.Name, controls: std.ArrayList(m.Program.BucketRef) = .empty, uses: u32 = 0, payload: bool = false };

/// Whether a moved key's handler is written inside the listener of the one
/// event that sends it, whose fields that event gives: the payload, or
/// nothing.
fn inside(x: *const Local) bool {
    return x.uses == 1 and x.fields == @intFromBool(x.payload);
}

/// A moved key's arm into `blk`, its fields `fields`: the arm piece writes
/// the slice the root holds, in place, then the write pass of the buckets
/// its key's writes reach and of the controls its events are on.
fn localArm(pg: *Page, blk: m.Block, x: *Local, fields: []const m.Name) m.Error!void {
    const cx = pg.cx;
    try cx.pieceArm(blk, x.key, fields, try cx.js.name(pg.holders[0]));
    var refs: std.ArrayList(m.Program.BucketRef) = .empty;
    try addRefs(cx.arena, &refs, cx.keyBuckets(x.key));
    try addRefs(cx.arena, &refs, x.controls.items);
    std.mem.sort(m.Program.BucketRef, refs.items, {}, refLess);
    try pg.writePass(blk, refs.items);
}

/// `refs` added to `into`, each once.
fn addRefs(a: std.mem.Allocator, into: *std.ArrayList(m.Program.BucketRef), refs: []const m.Program.BucketRef) !void {
    for (refs) |ref| {
        for (into.items) |x| {
            if (x.row == ref.row and x.bucket == ref.bucket) break;
        } else try into.append(a, ref);
    }
}

/// A deep copy of `nodes` into `a`, which outlives the lowering that made
/// them.
fn copyHtml(a: std.mem.Allocator, nodes: []const Html) std.mem.Allocator.Error![]const Html {
    const out = try a.alloc(Html, nodes.len);
    for (out, nodes) |*o, x| {
        o.* = x;
        o.name = try a.dupe(u8, x.name);
        o.attributes = try a.dupe(u8, x.attributes);
        o.children = try copyHtml(a, x.children);
        o.dynamic = try a.dupe(Dynamic, x.dynamic);
        o.value = if (x.value) |v| try a.dupe(u8, v) else null;
    }
    return out;
}

/// Why the parser would rebuild `nodes` written in `scope`, or null: the
/// same rules the walk applies to a unit's own markup (`element`).
fn rebuilt(scope: parser.Scope, nodes: []const Html) ?[]const u8 {
    for (nodes) |x| switch (x.kind) {
        .text => if (parser.movesText(scope.parent)) return "the parser moves text written here out of the table",
        .element => {
            if (parser.misplaced(scope, x.name, false)) |why| return why;
            if (parser.misnested(scope, x.name)) |why| return why;
            if (!x.void) if (rebuilt(scope.enter(x.name), x.children)) |why| return why;
        },
        .piece => {},
    };
    return null;
}

/// One node of the static markup, as `serialise` writes it.
const Html = struct {
    /// `piece`: another module's root, its markup the piece `piece` of the
    /// page names, written in its place; `name` is its top element's.
    kind: enum { element, text, piece },
    piece: u32 = 0,
    /// The element's name, or the text, escaped.
    name: []const u8,
    /// ` name=value…`, written.
    attributes: []const u8 = "",
    void: bool = false,
    children: []const Html = &.{},
    /// The context the node's values are evaluated in (`Page.ctxs`): what
    /// the string form enters to write it (`prerender.md` §4.1).
    ctx: u32 = 0,
    /// An element's place (`Write.target`): null for the unit's top
    /// element.
    target: ?u32 = null,
    /// Where in `attributes` each write of an attribute whose value changes
    /// stands, in the order of the element's items: the string form writes
    /// the value `init` gives it there.
    dynamic: []const Dynamic = &.{},
    /// The value of a `value` attribute written into `attributes`, as the
    /// program gives it: what an `option` is selected by (`prerender.md`
    /// §4.1).
    value: ?[]const u8 = null,
};

/// A write of an attribute whose value changes, at byte `at` of its
/// element's `attributes`.
const Dynamic = struct { at: u32, write: u32 };

/// Where a binding's or an event's values are evaluated: the `view`'s root
/// (context 0), or an eager arm of a branch in an enclosing context.
const Ctx = struct {
    parent: ?u32,
    /// The branch's hole, or the helper call's; `none` for the `view`.
    node: m.Node.Index,
    arm: u32,
    arms: u32 = 2,
    root: m.Root.Index,
    /// The selector read group of an arm.
    group: ?u32 = null,
    entry_groups: []const u32 = &.{},
    /// An eager arm of a branch (§8.2), or the markup of a function of the
    /// program's own module the hole calls, written in place (§8.4,
    /// amended 2026-10-19): entered with its arguments evaluated in the
    /// enclosing context.
    kind: enum { arm, call } = .arm,
};

/// One part of a text binding: text written as it is, or a hole's value.
const Part = union(enum) { text: []const u8, value: m.Value.Index };

/// What a property or attribute binding writes: a hole's value, or a
/// constant — a URL whose check turns on a character outside ASCII, which
/// the runtime's `safeUrl` decides (§10.5, amended 2026-11-05). A constant
/// reads nothing and evaluates nothing.
const Operand = union(enum) { value: m.Value.Index, text: []const u8 };

/// One write of the page (§8.2), on an element: `null` is the unit's top
/// element, any other number its descendant of that place in document
/// order.
const Write = struct {
    target: ?u32,
    ctx: u32,
    /// The read sets it is in, sorted, each once.
    groups: []const u32,
    what: union(enum) {
        text: []const Part,
        /// `key` null without `attribute_only`: the control's `value`.
        /// `attribute_only` writes a scalar String class via native attributes,
        /// including empty strings. `attribute`: its name as the
        /// markup writes it, and `boolean`, whether its value is a `Bool`:
        /// what the string form writes it as (`prerender.md` §4.1). `url`
        /// (with `attribute_only`): the attribute holds a URL, and the
        /// binding and the string form write `safeUrl(value)` (§10.5,
        /// amended 2026-11-05).
        prop: struct { value: Operand, key: ?[]const u8, attribute: []const u8 = "", boolean: bool = false, attribute_only: bool = false, url: bool = false },
        /// Hidden while the branch at `node` takes another arm than `shown`.
        /// `arms`: how many arms the branch has.
        when: struct { node: m.Node.Index, shown: u32, arms: u32 = 2 },
        event: u32,
        /// Evaluate a choice whose only reachable markup is empty.
        observe: m.Node.Index,
        /// A `For`, the only child of the element at `target`: its rows
        /// made to agree with its list (§9, amended 2026-11-23). An index
        /// into `Page.fors`.
        rows: u32,
    },
    /// A `stateful` attribute: a control the user edits (§8.3).
    stateful: bool = false,
    /// A text write whose value is a `String`, not a lone number.
    string: bool = true,
};

/// One event of the page, on an element.
const Event = struct {
    node: m.Node.Index,
    target: ?u32,
    ctx: u32,
    item: m.Item,
    /// Its index in `Tree.items`.
    index: u32,
    captures: []const u32 = &.{},
};

/// One binding function — a binding entry (§8.4, amended 2026-10-22): the
/// writes of one set of read sets.
const Function = struct {
    groups: []const u32,
    writes: std.ArrayList(u32) = .empty,
    /// An entry with no write (§8.2, amended 2026-11-23): the `view`'s
    /// statements, or the memo node of the view root's `let` `memo`, which
    /// evaluates it into its slot.
    kind: enum { writes, statements, memo } = .writes,
    memo: u32 = 0,
};

/// Another module's root the page shows as pieces: its hole, its top
/// element's place, its facts, and the name of its elements.
const PieceUse = struct {
    node: m.Node.Index,
    target: u32,
    data: *const PieceData,
    elements: m.Name = undefined,
};

/// Pieces `start .. start + len`, roots mounted through one table (§8.4,
/// amended 2026-10-24): each has a factory that takes its elements, its
/// holders, its own row — rows `row .. row + len`, in order — and, when it
/// fills another root's row, the table, and no handler. `elements`: where
/// each root's top element is — `len` element children of one element
/// (null: the page's top node) in order, from its child `from` on — or
/// anywhere, each then read by its place.
const Run = struct {
    start: u32,
    len: u32,
    row: u32,
    elements: union(enum) { children: struct { parent: ?u32, from: u32 }, places },
};

// ---- Rows: `For` (`browser-inline.md` §9, the simple form) --------------

/// A `For` of the page: its node and its row, planned.
/// `end`: the element its rows stand before — its next sibling, a plain
/// element — or null when the rows are its parent's last children.
const ForUse = struct { node: m.Node.Index, plan: *const RowPlan, end: ?u32 };

/// A `For`'s row, planned before anything is written (§9, amended
/// 2026-11-23): its template's HTML, and what its `set` writes, in document
/// order. A row's elements are numbered within the row, as a unit's are:
/// `null` is the row's top element, `n` its `n`-th descendant.
const RowPlan = struct {
    html: []const u8,
    /// Some op refers to a descendant of the row's top element.
    elements: bool,
    ops: []const RowOp,
    /// The row, or a row of a `For` in it, has an event: the page then has
    /// its dispatcher, which every row's listener hands its message.
    events: bool,
    /// The row, or a row of a `For` in it, has a control the user edits
    /// (§8.3, *Controlled inputs*).
    stateful: bool,
};

/// One thing a row's `set` does, on the element at `target`.
const RowOp = struct {
    target: ?u32,
    what: union(enum) {
        /// The element's whole text: texts and text holes.
        text: struct { parts: []const Part, string: bool },
        /// A property, or an attribute written as one (§8.2's `prop`).
        /// `attribute_only`: written with `setAttribute` when it differs,
        /// as a scalar `String` class is (§8.2) — in a row, also any other
        /// attribute of a `String` or a number that is no DOM property,
        /// its value written as a string.
        prop: struct { value: Operand, key: ?[]const u8, attribute: []const u8, attribute_only: bool, url: bool, number: bool = false },
        /// A text node of an element whose children mix elements and text
        /// holes: `make` creates it, before the element child `anchor`
        /// (null: at the end), and `set` writes a hole's, kept as the row's
        /// `t<slot>`. `value` null: a constant text, `text`.
        child_text: struct { anchor: ?u32, slot: u32, value: ?m.Value.Index, text: []const u8, number: bool },
        /// An event: `set` keeps its handler value in the row's `h<slot>`,
        /// which the listener `make` wired reads at the event.
        event: struct { item: m.Item, index: u32, slot: u32 },
        /// A `For`, the only child of the element: its rows synced.
        rows: struct { node: m.Node.Index, plan: *const RowPlan, end: ?u32 },
    },
};

/// Where the rows of the `For` at `children[i]` stand, in element `e`:
/// before the element after it, whose place is `next` — the place the
/// walk gives the next element — or, as its parent's last children, at
/// the end (null). Refused beside anything else after it, whose node the
/// lowering does not hold, and in an element whose own value a control
/// writes, which would be written before the rows its value chooses among.
fn forEnd(pg: *Page, e: m.Element, children: []const m.Node.Index, i: usize, next: u32) m.Error!?u32 {
    const tree = pg.tree;
    for (tree.itemsOf(e.items)) |it| {
        if (it.kind != .attribute or it.attribute == .none or it.value.kind != .dynamic) continue;
        if (tree.attributeFacts(it.attribute).stateful) return later(pg.cx, children[i], "a `For` beside other children of a control whose value changes");
    }
    if (i + 1 == children.len) return null;
    if (tree.kind(children[i + 1]) != .element) return later(pg.cx, children[i], "a `For` followed by text, a hole or another `For` in its element");
    return next;
}

/// Whether element `e` is a control whose value changes: an attribute of
/// it the user edits (`value`, `checked`) has a value the model gives.
fn controlled(tree: *const m.Tree, e: m.Element) bool {
    for (tree.itemsOf(e.items)) |it| {
        if (it.kind != .attribute or it.attribute == .none or it.value.kind != .dynamic) continue;
        if (tree.attributeFacts(it.attribute).stateful) return true;
    }
    return false;
}

/// The walk of one row's markup (`RowBuild.plan`): what §9's simple form
/// compiles, and the refusals of everything else, each class 1 (§5).
const RowBuild = struct {
    pg: *Page,
    count: u32 = 0,
    ops: std.ArrayList(RowOp) = .empty,
    slots: u32 = 0,
    texts: u32 = 0,
    under_control: u32 = 0,
    events: bool = false,
    stateful: bool = false,

    /// `For` `n`'s row, planned; `scope` is its parent element's.
    fn plan(pg: *Page, n: m.Node.Index, scope: parser.Scope) m.Error!*const RowPlan {
        const tree = pg.tree;
        const cx = pg.cx;
        const f = tree.for_(n);
        if (f.fallback != null) return later(cx, n, "a `For` with a `fallback`");
        const row = tree.row(f.row);
        if (row.kind != .markup) return later(cx, n, "a `For` whose row function is not a lambda whose body is one element written in place");
        const top = tree.root(row.body).node;
        if (tree.kind(top) != .element) return later(cx, top, "a `For` row that is not one element");
        var b: RowBuild = .{ .pg = pg };
        const html = try b.element(top, scope, true);
        var out: std.ArrayList(u8) = .empty;
        // The template is parsed alone: its closing run is left out.
        try serialise(pg.a(), &out, &.{html}, null, true);
        const elements = for (b.ops.items) |op| {
            if (op.target != null) break true;
            switch (op.what) {
                .child_text => |x| if (x.anchor != null) break true,
                .rows => |x| if (x.end != null) break true,
                else => {},
            }
        } else false;
        const p = try pg.a().create(RowPlan);
        p.* = .{ .html = out.items, .elements = elements, .ops = b.ops.items, .events = b.events, .stateful = b.stateful };
        return p;
    }

    fn element(b: *RowBuild, n: m.Node.Index, scope: parser.Scope, top: bool) m.Error!Html {
        const pg = b.pg;
        const tree = pg.tree;
        const cx = pg.cx;
        cx.at(n);
        const e = tree.element(n);
        const facts = tree.elementFacts(e.row);
        const name = tree.string(facts.name);
        if (facts.namespace != .html) return later(cx, n, "an element of the SVG or MathML namespace");
        if (parser.misnested(scope, name)) |why| return cx.report(n, why);
        const target: ?u32 = if (top) null else blk: {
            b.count += 1;
            break :blk b.count - 1;
        };
        // A `For` in a row, the only child of its element: synced by the
        // row's `set`, before the element's own attributes are written (a
        // `select`'s `value` chooses among the options its rows make).
        const own_children = tree.childrenOf(e.children);
        const rows = !facts.void and own_children.len == 1 and tree.kind(own_children[0]) == .for_;
        const below_control = !rows and controlled(tree, e);
        if (below_control) b.under_control += 1;
        defer if (below_control) {
            b.under_control -= 1;
        };
        if (rows) {
            if (parser.content(name) != .normal) return later(cx, n, "the content of an element whose content the parser reads as text");
            if (b.under_control != 0) return later(cx, own_children[0], controlled_for);
            const p = try plan(pg, own_children[0], scope.enter(name));
            try b.ops.append(pg.a(), .{ .target = target, .what = .{ .rows = .{ .node = own_children[0], .plan = p, .end = null } } });
            b.events = b.events or p.events;
            b.stateful = b.stateful or p.stateful;
        }
        var attributes: std.ArrayList(u8) = .empty;
        for (tree.itemsOf(e.items), 0..) |it, i| try b.item(n, target, it, e.items.start + @as(u32, @intCast(i)), &attributes);
        const base: Html = .{ .kind = .element, .name = name, .attributes = attributes.items, .target = target };
        if (facts.void) {
            var out = base;
            out.void = true;
            return out;
        }
        const inner = scope.enter(name);
        const children = tree.childrenOf(e.children);
        if (parser.content(name) != .normal and children.len != 0) return later(cx, n, "the content of an element whose content the parser reads as text");
        if (rows) return base;
        // Texts and text holes only, a hole among them: the element's text
        // is one write, as a unit's (§8.2).
        var holes: u32 = 0;
        const texts = for (children) |child| {
            switch (tree.kind(child)) {
                .text => {},
                .hole => if (textHole(tree.hole(child).kind)) {
                    holes += 1;
                } else break false,
                else => break false,
            }
        } else true;
        if (texts and holes != 0) {
            if (parser.movesText(inner.parent)) return cx.report(n, "the parser moves text written here out of the table");
            var parts: std.ArrayList(Part) = .empty;
            var string = true;
            for (children) |child| switch (tree.kind(child)) {
                .text => try parts.append(pg.a(), .{ .text = tree.string(tree.text(child).text) }),
                else => {
                    const h = tree.hole(child);
                    if (h.kind == .text_number) string = false;
                    try parts.append(pg.a(), .{ .value = h.value });
                },
            };
            try b.ops.append(pg.a(), .{ .target = target, .what = .{ .text = .{ .parts = parts.items, .string = string or parts.items.len > 1 } } });
            return base;
        }
        // Elements beside text holes: each text a node `make` creates
        // before the element after it, one per text or hole, as
        // `browser-tea` keeps them.
        const mixed = for (children) |child| {
            if (tree.kind(child) == .hole and textHole(tree.hole(child).kind)) break true;
        } else false;
        if (mixed and parser.movesText(inner.parent)) return cx.report(n, "the parser moves text written here out of the table");
        var pending: std.ArrayList(usize) = .empty;
        var out: std.ArrayList(Html) = .empty;
        for (children, 0..) |child, ci| switch (tree.kind(child)) {
            .for_ => {
                if (b.under_control != 0) return later(cx, child, controlled_for);
                const end = try forEnd(pg, e, children, ci, b.count);
                const p = try plan(pg, child, inner);
                try b.ops.append(pg.a(), .{ .target = target, .what = .{ .rows = .{ .node = child, .plan = p, .end = end } } });
                b.events = b.events or p.events;
                b.stateful = b.stateful or p.stateful;
            },
            .text => {
                if (parser.movesText(inner.parent)) return cx.report(child, "the parser moves text written here out of the table");
                if (mixed) {
                    try pending.append(pg.a(), b.ops.items.len);
                    try b.ops.append(pg.a(), .{ .target = target, .what = .{ .child_text = .{ .anchor = null, .slot = 0, .value = null, .text = tree.string(tree.text(child).text), .number = false } } });
                    continue;
                }
                var text: std.ArrayList(u8) = .empty;
                try escapeText(pg.a(), &text, tree.string(tree.text(child).text));
                try out.append(pg.a(), .{ .kind = .text, .name = text.items });
            },
            .element => {
                const el = try b.element(child, inner, false);
                for (pending.items) |i| b.ops.items[i].what.child_text.anchor = el.target;
                pending.clearRetainingCapacity();
                try out.append(pg.a(), el);
            },
            .hole => {
                const h = tree.hole(child);
                if (!textHole(h.kind)) return later(cx, child, "a hole of markup in a `For` row");
                try pending.append(pg.a(), b.ops.items.len);
                try b.ops.append(pg.a(), .{ .target = target, .what = .{ .child_text = .{ .anchor = null, .slot = b.texts, .value = h.value, .text = "", .number = h.kind == .text_number } } });
                b.texts += 1;
            },
            .component => return later(cx, child, "a component in a `For` row"),
            .show => return later(cx, child, "a `Show`"),
            else => return later(cx, child, "this markup in a `For` row"),
        };
        var el = base;
        el.children = out.items;
        return el;
    }

    /// An attribute or an event of row element `n` (`target`): a constant
    /// one in the template, any other an op of `set`.
    fn item(b: *RowBuild, n: m.Node.Index, target: ?u32, it: m.Item, index: u32, out: *std.ArrayList(u8)) m.Error!void {
        const pg = b.pg;
        const tree = pg.tree;
        const cx = pg.cx;
        switch (it.kind) {
            .attribute => {},
            .event => {
                if (it.value.kind != .dynamic) return limit(cx, n, "this event's handler is a message written as a literal, which `browser-inline` cannot route to a key");
                try b.ops.append(pg.a(), .{ .target = target, .what = .{ .event = .{ .item = it, .index = index, .slot = b.slots } } });
                b.slots += 1;
                b.events = true;
                return;
            },
            else => return later(cx, n, "an escape attribute"),
        }
        const name = tree.string(it.name);
        var stateful = false;
        var attribute_only = false;
        var property: ?[]const u8 = null;
        if (it.attribute != .none) {
            const f = tree.attributeFacts(it.attribute);
            attribute_only = f.classes and it.class == .string;
            if (f.raw or f.styles or (f.classes and !attribute_only)) return later(cx, n, "an attribute written as raw HTML, or a class or style list");
            if (f.property) |prop| property = tree.string(prop);
            stateful = f.stateful;
        }
        // A URL, as a unit's (§10.5, amended 2026-11-05).
        if (it.url) {
            const plain = std.mem.indexOfScalar(u8, name, ':') == null;
            switch (it.value.kind) {
                .constant => {
                    const c = it.value.constant;
                    switch (c.kind) {
                        .string => {
                            const text = tree.string(c.text);
                            if (scriptUrl(text)) |script| return writeValue(pg.a(), out, name, if (script) "" else text);
                            if (!plain) return later(cx, n, "a URL whose first characters are outside ASCII, in an attribute with a namespace prefix");
                            try b.ops.append(pg.a(), .{ .target = target, .what = .{ .prop = .{ .value = .{ .text = text }, .key = null, .attribute = name, .attribute_only = true, .url = true } } });
                            return;
                        },
                        .number => return writeAttribute(pg.a(), out, name, c, tree),
                        else => return later(cx, n, "an attribute that holds a URL"),
                    }
                },
                .dynamic => {
                    if (it.class != .string) return later(cx, n, "an attribute that holds a URL, whose value changes and is not a `String`");
                    if (!plain) return later(cx, n, "an attribute with a namespace prefix that holds a URL and whose value changes");
                    try b.ops.append(pg.a(), .{ .target = target, .what = .{ .prop = .{ .value = .{ .value = it.value.dynamic.? }, .key = null, .attribute = name, .attribute_only = true, .url = true } } });
                    return;
                },
                else => return later(cx, n, "an attribute that holds a URL"),
            }
        }
        switch (it.value.kind) {
            .constant => {
                if (stateful) return later(cx, n, "a constant value of a control");
                return writeAttribute(pg.a(), out, name, it.value.constant, tree);
            },
            .dynamic => {},
            else => return later(cx, n, "this attribute's value"),
        }
        const key: ?[]const u8 = if (attribute_only) null else if (property) |prop|
            (if (std.mem.eql(u8, prop, "value")) null else prop)
        else if (it.class == .bool and isBoolProperty(name))
            name
        else if (std.mem.indexOfScalar(u8, name, ':') == null and (it.class == .string or it.class == .int or it.class == .float)) {
            // No DOM property: the attribute itself, its value a string.
            try b.ops.append(pg.a(), .{ .target = target, .what = .{ .prop = .{ .value = .{ .value = it.value.dynamic.? }, .key = null, .attribute = name, .attribute_only = true, .url = false, .number = it.class != .string } } });
            return;
        } else return later(cx, n, "an attribute that is not a DOM property and whose value changes");
        if (stateful) b.stateful = true;
        try b.ops.append(pg.a(), .{ .target = target, .what = .{ .prop = .{ .value = .{ .value = it.value.dynamic.? }, .key = key, .attribute = name, .attribute_only = attribute_only, .url = false } } });
    }
};

fn addKind(a: std.mem.Allocator, kinds: *std.ArrayList([]const u8), k: []const u8) m.Error!void {
    for (kinds.items) |x| if (std.mem.eql(u8, x, k)) return;
    try kinds.append(a, k);
}

fn kindLess(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn copyKinds(a: std.mem.Allocator, kinds: []const []const u8) m.Error![]const []const u8 {
    const out = try a.alloc([]const u8, kinds.len);
    for (out, kinds) |*o, k| o.* = try a.dupe(u8, k);
    return out;
}

fn runOf(runs: []const Run, piece_index: u32) ?Run {
    for (runs) |r| if (piece_index >= r.start and piece_index < r.start + r.len) return r;
    return null;
}

/// One eager arm of a unit, as the hydrating mount reads it
/// (`prerender.md` §6.2): the index of its element in the unit's table —
/// the top element is 0, its descendant of place `n` is `n + 1` — how many
/// elements the arm holds, its own and its descendants, and the index of
/// its parent.
const ArmRun = struct { at: u32, len: u32, parent: u32 };

/// A unit's elements in document order, as the hydrating mount's table
/// holds them (`prerender.md` §6.2, §6.4): each one's name, lower case, as
/// the page's `localName` gives it, every one checked in every build
/// (§6.4, amended 2026-10-29, #1186); and the unit's eager arms in document
/// order, which is the order of their ordinals (§4.1).
const Layout = struct {
    a: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    arms: std.ArrayList(ArmRun) = .empty,

    /// The unit of `pg`, whose top element is `top`.
    fn unit(l: *Layout, pg: *Page, top: Html) m.Error!void {
        const arm_at = try l.a.alloc(bool, pg.count);
        @memset(arm_at, false);
        for (pg.writes.items) |w| if (w.what == .when) {
            arm_at[w.target.?] = true;
        };
        try l.push(top.name);
        try l.walk(top.children, 0, 0, arm_at, pg.pieces.items);
        std.debug.assert(l.names.items.len == pg.count + 1);
    }

    fn push(l: *Layout, name: []const u8) m.Error!void {
        const lower = try l.a.alloc(u8, name.len);
        _ = std.ascii.lowerString(lower, name);
        try l.names.append(l.a, lower);
    }

    /// `nodes`, the children of the element at index `parent`, of the unit
    /// whose top element is at index `base`: the program's, or a piece's.
    fn walk(l: *Layout, nodes: []const Html, parent: u32, base: u32, arm_at: []const bool, pieces: []const PieceUse) m.Error!void {
        for (nodes) |n| switch (n.kind) {
            .text => {},
            .element => {
                const at: u32 = @intCast(l.names.items.len);
                std.debug.assert(base + n.target.? + 1 == at);
                try l.push(n.name);
                const arm = arm_at.len != 0 and arm_at[at - base - 1];
                const slot = l.arms.items.len;
                if (arm) try l.arms.append(l.a, .{ .at = at, .len = 0, .parent = parent });
                try l.walk(n.children, at, base, arm_at, pieces);
                if (arm) l.arms.items[slot].len = @as(u32, @intCast(l.names.items.len)) - at;
            },
            // Another module's root: its top element, its elements and its
            // arms, numbered after its top element's index.
            .piece => {
                const u = pieces[n.piece];
                const at: u32 = @intCast(l.names.items.len);
                std.debug.assert(u.target + 1 == at);
                try l.push(u.data.top);
                for (u.data.arm_runs) |r| try l.arms.append(l.a, .{ .at = r.at + at, .len = r.len, .parent = r.parent + at });
                try l.walk(u.data.nodes[0].children, at, at, &.{}, &.{});
                std.debug.assert(l.names.items.len == at + 1 + u.data.count);
            },
        };
    }
};

/// Where a piece's top element stands: its parent's place (null: the top
/// node) and its place among the parent's element children.
const Place = struct { parent: ?u32, at: u32 };

/// The places of the pieces among `nodes`, numbered as `element` and
/// `pieceHole` number them; false when a piece's number is not the one the
/// walk counts, which then says nothing of where pieces stand.
fn placesOf(nodes: []const Html, parent: ?u32, count: *u32, pieces: []const PieceUse, places: []?Place) bool {
    var at: u32 = 0;
    for (nodes) |n| switch (n.kind) {
        .text => {},
        .element => {
            const t = count.*;
            count.* += 1;
            at += 1;
            if (!placesOf(n.children, t, count, pieces, places)) return false;
        },
        .piece => {
            const u = pieces[n.piece];
            if (u.target != count.*) return false;
            places[n.piece] = .{ .parent = parent, .at = at };
            at += 1;
            count.* += 1 + u.data.count;
        },
    };
    return true;
}

/// One program's page, as the lowering builds it.
const Page = struct {
    cx: *m.Context,
    tree: *const m.Tree,
    p: *const m.Program,
    index: m.Root.Index,
    /// The view's static markup, as nodes.
    top_nodes: []const Html = &.{},
    /// How many descendants of the top element are numbered.
    count: u32 = 0,
    ctxs: std.ArrayList(Ctx) = .empty,
    writes: std.ArrayList(Write) = .empty,
    guarded_ctx: []bool = &.{},
    unsafe_ctx: []bool = &.{},
    events: std.ArrayList(Event) = .empty,
    functions: std.ArrayList(Function) = .empty,
    /// The mount's body, the model's name, the top node and its
    /// descendants by place.
    body: m.Block = undefined,
    model: m.Name = undefined,
    node: ?m.Name = null,
    elements: ?m.Name = null,
    /// `elements` is the one element code refers to, not the list.
    single: bool = false,
    /// The client of a prerendering build (`prerender.md` §6.2):
    /// `elements` is the hydrating mount's table, the top element at 0 and
    /// its descendant of place `n` at `n + 1`, and every piece's table is
    /// cut from it.
    hydrating: bool = false,
    /// A hydrating application's: the `Url` its `init` was handed, which
    /// the mount compares the page's address with once `onUrlChange`
    /// listens (`prerender.md` §7.3).
    route_url: ?m.Name = null,
    /// The client of a prerendering build, whose page may hold input made
    /// before the takeover (`prerender.md` §6.5, amended 2026-10-29): each
    /// listener is wired through the runtime's `listen`, which notes it for
    /// the delivery.
    taking: bool = false,
    /// The handlers by key, named when something first calls one.
    handlers: []?m.Name = &.{},
    /// Per key, the buckets of the stateful controls its events are on.
    controls: []std.ArrayList(m.Program.BucketRef) = &.{},
    dispatch: ?m.Name = null,
    /// A document's function that writes its title (§10).
    retitle: ?m.Name = null,
    /// The page is another module's root, written as pieces (`piece`).
    piece: bool = false,
    pieces: std.ArrayList(PieceUse) = .empty,
    /// The page's `For`s (§9, amended 2026-11-23), and whether a row of
    /// one has an event: the page then has its dispatcher.
    fors: std.ArrayList(ForUse) = .empty,
    row_events: bool = false,
    /// The walk is below a control whose value changes, not as its only
    /// child's `For`: a `For` there is refused (§9, amended 2026-11-23).
    under_control: u32 = 0,
    /// The root plan (§8.4, amended 2026-10-22): this unit's row of the
    /// program's table; a piece's holders, one per argument of its
    /// function; the names of its own row and of the program's table, and
    /// whether its code reads them; the program's model cell.
    row: ?u32 = null,
    holders: []const m.Name = &.{},
    own: ?m.Name = null,
    table: ?m.Name = null,
    used_own: bool = false,
    used_table: bool = false,
    cell: ?m.Name = null,
    /// Per `let` of the view's root, its memo slot when several binding
    /// functions read it (§8.2, amended 2026-11-23); and the groups of the
    /// view's statements, null when it has none.
    memo: []?m.Name = &.{},
    memo_mask: []const bool = &.{},
    statements: ?[]const u32 = null,

    fn a(pg: *Page) std.mem.Allocator {
        return pg.cx.arena;
    }

    /// The event kinds the unit listens to — its own events' and its
    /// pieces' — each once, sorted by byte (`prerender.md` §6.5, amended
    /// 2026-10-29).
    fn eventKinds(pg: *Page) m.Error![]const []const u8 {
        var kinds: std.ArrayList([]const u8) = .empty;
        for (pg.events.items) |ev| try addKind(pg.a(), &kinds, pg.tree.string(pg.tree.eventFacts(ev.item.event).dom_name));
        for (pg.pieces.items) |u| for (u.data.kinds) |k| try addKind(pg.a(), &kinds, k);
        std.mem.sort([]const u8, kinds.items, {}, kindLess);
        return kinds.items;
    }

    /// The kinds the capture script records: `eventKinds` but the pointer
    /// events, whose payload is read while the event is dispatched — the
    /// box of the element whose listener runs, its `currentTarget` — which
    /// a delivery after the dispatch cannot give (`prerender.md` §6.5,
    /// amended 2026-10-29).
    fn capturedKinds(pg: *Page) m.Error![]const []const u8 {
        var kinds: std.ArrayList([]const u8) = .empty;
        for (try pg.eventKinds()) |k| {
            if (std.mem.indexOf(u8, k, "pointer") == null) try kinds.append(pg.a(), k);
        }
        return kinds.items;
    }

    /// The capture script of a prerendered page (`prerender.md` §6.5,
    /// amended 2026-10-29): it records each event of `kinds` on the unit
    /// before the takeover, for the mount's `caught`. Empty when the unit
    /// listens to nothing.
    fn captureScript(pg: *Page) m.Error![]const u8 {
        const kinds = try pg.capturedKinds();
        if (kinds.len == 0) return "";
        var list: std.ArrayList(u8) = .empty;
        for (kinds, 0..) |k, i| {
            if (i != 0) try list.append(pg.a(), ',');
            // A kind is a DOM event name the vocabulary declares: letters,
            // digits, `-` and `:`, nothing a JSON string escapes, and
            // nothing that ends a script.
            for (k) |c| std.debug.assert(std.ascii.isAlphanumeric(c) or c == '-' or c == ':' or c == '_');
            try list.print(pg.a(), "\"{s}\"", .{k});
        }
        return std.fmt.allocPrint(pg.a(),
            \\<script>(()=>{{let d=document,r=[],k=[{s}],f=e=>{{let t=e.target;t.closest?.("[data-beni]")&&r.push([e,t.value,t.checked,t.selectedIndex])}};for(let n of k)d.addEventListener(n,f,!0);window.$beni=()=>{{for(let n of k)d.removeEventListener(n,f,!0);return r}};d.currentScript.remove()}})()</script>
        , .{list.items});
    }

    /// A hole's facts, refused when the write-set pass did not reach the
    /// hole: its group would be unknown, and no key's pass could name it.
    /// No pass calls every binding (`browser-inline.md` §8.3, amended
    /// 2026-10-19), so this is a limit of the compiler in every build.
    fn known(pg: *Page, n: m.Node.Index, facts: m.Program.HoleFacts) m.Error!m.Program.HoleFacts {
        if (facts.group != std.math.maxInt(u32)) return facts;
        return limit(pg.cx, n, "the write-set pass did not reach this hole on the `view`'s call path, so `browser-inline` cannot say which messages change it; write it in the program's own `view`, or a function the `view` calls directly");
    }

    /// `For` `n`, the only child of the element at `target` (§9, amended
    /// 2026-11-23): its row planned, and one write of the element whose
    /// read set is the `For`'s — its list, its key, and what its rows read
    /// (the write-set pass's edge of the `For`).
    fn forChild(pg: *Page, n: m.Node.Index, target: ?u32, ctx: u32, scope: parser.Scope, end: ?u32) m.Error!void {
        if (pg.piece) return later(pg.cx, n, "a `For` in another module's markup");
        if (pg.under_control != 0) return later(pg.cx, n, controlled_for);
        const facts = try pg.known(n, pg.cx.programHole(.{ .node = n }));
        const p = try RowBuild.plan(pg, n, scope);
        try pg.fors.append(pg.a(), .{ .node = n, .plan = p, .end = end });
        pg.row_events = pg.row_events or p.events;
        try pg.writes.append(pg.a(), .{ .target = target, .ctx = ctx, .groups = try sorted(pg.a(), &.{facts.group}), .what = .{ .rows = @intCast(pg.fors.items.len - 1) } });
    }

    /// The values of the root a `For`'s write reads: its list, its key
    /// function and its row's captures.
    fn forValues(pg: *Page, n: m.Node.Index, out: *std.ArrayList(m.Value.Index)) m.Error!void {
        const f = pg.tree.for_(n);
        try out.append(pg.a(), f.each);
        if (f.mode == .key) if (f.key) |k| try out.append(pg.a(), k);
        const row = pg.tree.row(f.row);
        for (0..row.captures.len) |k| try out.append(pg.a(), row.captures.at(@intCast(k)));
    }

    /// The call that syncs `For` `n`'s rows into `parent`, into `blk`, its
    /// values already evaluated there: `rows(parent, list, key, make, set)`,
    /// the key `undefined` by position, `null` by reference.
    fn writeRows(pg: *Page, blk: m.Block, parent: m.Expr, end: m.Expr, n: m.Node.Index, p: *const RowPlan) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        const f = pg.tree.for_(n);
        const row = pg.tree.row(f.row);
        const key = switch (f.mode) {
            .key => try cx.value(f.key.?),
            .position => try js.literal(.undefined),
            else => try js.literal(.null),
        };
        // The row's captures, read where the `For` stands, under names its
        // `set` reads them by.
        const captures = try pg.a().alloc(m.Name, row.captures.len);
        for (captures, 0..) |*c, k| {
            c.* = try cx.fresh("capture");
            try js.constant(blk, c.*, try cx.value(row.captures.at(@intCast(k))));
        }
        const each = try cx.value(f.each);

        // The template, parsed once at the mount.
        const template = try cx.fresh("template");
        try js.constant(pg.body, template, try js.call(try js.name(try cx.runtime("forTemplate")), &.{try js.string(p.html)}));

        // `make`: a row's node cloned, its elements found, its listeners
        // wired; each hands the dispatcher the message the row's `set` last
        // kept, applied to the event's payload when it takes one.
        const mk = try js.block();
        const node = try cx.fresh("node");
        try js.constant(mk, node, try js.call(try js.member(try js.name(template), "cloneNode"), &.{try js.literal(.true)}));
        const elements: ?m.Name = if (p.elements) blk: {
            const e = try cx.fresh("elements");
            try js.constant(mk, e, try js.call(try js.member(try js.name(node), "querySelectorAll"), &.{try js.string("*")}));
            break :blk e;
        } else null;
        const made = try cx.fresh("row");
        var props: std.ArrayList(m.Property) = .empty;
        try props.append(pg.a(), .{ .key = "n", .value = try js.name(node) });
        if (elements) |e| try props.append(pg.a(), .{ .key = "e", .value = try js.name(e) });
        // The texts of an element that mixes elements and text holes, each
        // made before the element after it; a hole's kept for `set`.
        for (p.ops) |op| if (op.what == .child_text) {
            const ct = op.what.child_text;
            const parent_el = if (op.target) |t| try js.index(try js.name(elements.?), try pg.num(t)) else try js.name(node);
            const anchor = if (ct.anchor) |t| try js.index(try js.name(elements.?), try pg.num(t)) else try js.literal(.null);
            const made_text = try js.call(try js.name(try cx.runtime("rowText")), &.{ parent_el, anchor, try js.string(ct.text) });
            if (ct.value == null) {
                try js.expression(mk, made_text);
                continue;
            }
            const t = try cx.fresh("text");
            try js.constant(mk, t, made_text);
            try props.append(pg.a(), .{ .key = try std.fmt.allocPrint(pg.a(), "t{d}", .{ct.slot}), .value = try js.name(t) });
        };
        try js.constant(mk, made, try js.object(props.items));
        for (p.ops) |op| if (op.what == .event) {
            const ev = op.what.event;
            const at = if (op.target) |t| try js.index(try js.name(elements.?), try pg.num(t)) else try js.name(node);
            const kept = try js.member(try js.name(made), try std.fmt.allocPrint(pg.a(), "h{d}", .{ev.slot}));
            const rb = try js.block();
            var read_params: []const m.Name = &.{};
            if (ev.item.form == .payload) {
                const e = try cx.fresh("event");
                read_params = try pg.a().dupe(m.Name, &.{e});
                const payload = if (try cx.extractor(ev.index)) |x| try js.call(x, &.{try js.name(e)}) else try js.name(e);
                try js.@"return"(rb, try cx.call(kept, &.{payload}));
            } else try js.@"return"(rb, kept);
            const read = try js.arrow(read_params, rb);
            const facts = pg.tree.eventFacts(ev.item.event);
            const dom = pg.tree.string(facts.dom_name);
            const dispatch = try js.name(pg.dispatch.?);
            if (!facts.prevent_default and !facts.stop_propagation) {
                const kind = if (std.mem.eql(u8, dom, "click")) try js.literal(.undefined) else try js.string(dom);
                try js.expression(mk, try js.call(try js.name(try cx.runtime("on")), &.{ at, dispatch, kind, read }));
                continue;
            }
            const e = try cx.fresh("event");
            const lb = try js.block();
            const stopped = try js.block();
            try js.@"return"(stopped, null);
            try js.@"if"(lb, try js.call(try js.name(try cx.runtime("stopped")), &.{}), stopped, null);
            if (facts.prevent_default) try js.expression(lb, try js.call(try js.member(try js.name(e), "preventDefault"), &.{}));
            if (facts.stop_propagation) try js.expression(lb, try js.call(try js.member(try js.name(e), "stopPropagation"), &.{}));
            try js.expression(lb, try js.call(try js.name(try cx.runtime("send")), &.{ dispatch, try js.name(e), read }));
            try js.expression(mk, try js.call(try js.member(at, "addEventListener"), &.{ try js.string(dom), try js.arrow(&.{e}, lb) }));
        };
        try js.@"return"(mk, try js.name(made));

        // `set`: the row's values evaluated with its item, its position and
        // the captures bound, then each write, kept handler and inner `For`
        // in document order.
        const st = try js.block();
        const r = try cx.fresh("row");
        const value_item = try cx.fresh("item");
        const position = try cx.fresh("position");
        _ = try cx.rowValues(st, f.row, value_item, if (row.arity == 2) position else null, captures);
        const row_node = try js.member(try js.name(r), "n");
        for (p.ops) |op| {
            const at = if (op.target) |t| try js.index(try js.member(try js.name(r), "e"), try pg.num(t)) else row_node;
            switch (op.what) {
                .text => |x| {
                    const value = if (x.parts.len == 1 and x.parts[0] == .value)
                        try cx.value(x.parts[0].value)
                    else value: {
                        const tp = try pg.a().alloc(m.TemplatePart, x.parts.len);
                        for (tp, x.parts) |*t, part| t.* = switch (part) {
                            .text => |s| .{ .text = s },
                            .value => |v| .{ .expr = try cx.value(v) },
                        };
                        break :value try js.template(tp);
                    };
                    const shown = if (x.string) value else try js.template(&.{.{ .expr = value }});
                    try js.expression(st, try js.call(try js.name(try cx.runtime("text")), &.{ at, shown }));
                },
                .prop => |x| {
                    const value = switch (x.value) {
                        .value => |v| try cx.value(v),
                        .text => |t| try js.string(t),
                    };
                    if (x.attribute_only) {
                        try pg.writeStringAttribute(st, at, x.attribute, if (x.number) try js.template(&.{.{ .expr = value }}) else value, x.url);
                    } else if (x.key) |k| {
                        try js.expression(st, try js.call(try js.name(try cx.runtime("prop")), &.{ at, value, try js.string(k) }));
                    } else try js.expression(st, try js.call(try js.name(try cx.runtime("prop")), &.{ at, value }));
                },
                .event => |x| try js.assign(st, try js.member(try js.name(r), try std.fmt.allocPrint(pg.a(), "h{d}", .{x.slot})), try cx.value(x.item.value.dynamic.?)),
                .child_text => |x| if (x.value) |v| {
                    const value = try cx.value(v);
                    const shown = if (x.number) try js.template(&.{.{ .expr = value }}) else value;
                    try js.expression(st, try js.call(try js.name(try cx.runtime("text")), &.{ try js.member(try js.name(r), try std.fmt.allocPrint(pg.a(), "t{d}", .{x.slot})), shown }));
                },
                .rows => |x| try pg.writeRows(st, at, if (x.end) |t| try js.index(try js.member(try js.name(r), "e"), try pg.num(t)) else try js.literal(.null), x.node, x.plan),
            }
        }
        try js.expression(blk, try js.call(try js.name(try cx.runtime("forRows")), &.{
            parent,
            end,
            each,
            key,
            try js.arrow(&.{}, mk),
            try js.arrow(&.{ r, value_item, position }, st),
        }));
    }

    fn num(pg: *Page, n: u32) m.Error!m.Expr {
        return pg.cx.js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{n}));
    }

    // ---- The walk: markup, writes and events ---------------------------

    /// The markup of node `n` of context `ctx`, in `scope`, refusing what
    /// S1 does not compile; `top`: `n` is at the unit's top level.
    fn markup(pg: *Page, n: m.Node.Index, scope: parser.Scope, ctx: u32, top: bool) m.Error![]const Html {
        const tree = pg.tree;
        pg.cx.at(n);
        switch (tree.kind(n)) {
            .fragment => {
                var out: std.ArrayList(Html) = .empty;
                for (tree.childrenOf(tree.fragment(n).children)) |child| try out.appendSlice(pg.a(), try pg.markup(child, scope, ctx, top));
                return out.items;
            },
            .element => return pg.a().dupe(Html, &.{try pg.element(n, scope, ctx, top)}),
            .text => {
                if (parser.movesText(scope.parent)) return pg.cx.report(n, "the parser moves text written here out of the table");
                var text: std.ArrayList(u8) = .empty;
                try escapeText(pg.a(), &text, tree.string(tree.text(n).text));
                return pg.a().dupe(Html, &.{.{ .kind = .text, .name = text.items, .ctx = ctx }});
            },
            // An `html` hole among a fragment's children — a view helper's
            // body (§8.4) — is a helper call or an eager `when`, as among an
            // element's; a text hole there has no element to write.
            .hole => {
                if (tree.hole(n).kind != .html) return later(pg.cx, n, "a hole outside an element");
                var out: std.ArrayList(Html) = .empty;
                if (try pg.cx.programPiece(n)) |piece_facts| {
                    try out.append(pg.a(), try pg.pieceHole(n, piece_facts, ctx, scope));
                } else if (!try pg.helper(n, scope, ctx, &out)) try pg.when(n, scope, ctx, &out);
                return out.items;
            },
            .component => return later(pg.cx, n, "a component"),
            .for_ => return later(pg.cx, n, "a `For` that is not the only child of its element"),
            .show => return later(pg.cx, n, "a `Show`"),
            else => return later(pg.cx, n, "this markup"),
        }
    }

    fn element(pg: *Page, n: m.Node.Index, scope: parser.Scope, ctx: u32, top: bool) m.Error!Html {
        const tree = pg.tree;
        const e = tree.element(n);
        const facts = tree.elementFacts(e.row);
        const name = tree.string(facts.name);
        if (facts.namespace != .html) return later(pg.cx, n, "an element of the SVG or MathML namespace");
        if (parser.misnested(scope, name)) |why| return pg.cx.report(n, why);
        // The top element is the unit's node; every other has its place.
        const target: ?u32 = if (top and ctx == 0) null else blk: {
            pg.count += 1;
            break :blk pg.count - 1;
        };
        // A `For`, the only child of its element (§9, amended 2026-11-23):
        // one write of the element, which makes its rows agree with its list,
        // made before the element's own attributes are written — a
        // `select`'s `value` chooses among the options its rows make.
        const own_children = tree.childrenOf(e.children);
        const rows = !facts.void and own_children.len == 1 and tree.kind(own_children[0]) == .for_;
        const rows_at = pg.writes.items.len;
        if (rows) {
            if (parser.content(name) != .normal) return later(pg.cx, n, "the content of an element whose content the parser reads as text");
            try pg.forChild(own_children[0], target, ctx, scope.enter(name), null);
        }
        var attributes: std.ArrayList(u8) = .empty;
        // Each attribute whose value changes, where it stands among the
        // written ones, and a written `value` (`prerender.md` §4.1).
        var dynamic: std.ArrayList(Dynamic) = .empty;
        var value: ?[]const u8 = null;
        for (tree.itemsOf(e.items), 0..) |it, i| {
            const before = pg.writes.items.len;
            if (try pg.item(n, target, ctx, it, e.items.start + @as(u32, @intCast(i)), &attributes)) |v| value = v;
            if (pg.writes.items.len != before and pg.writes.items[before].what == .prop)
                try dynamic.append(pg.a(), .{ .at = @intCast(attributes.items.len), .write = @intCast(before) });
        }
        // A control whose value changes, around its only child's `For`:
        // the rows and the value written by one binding, of both their read
        // sets, the rows first — the value chooses among the rows, whatever
        // write reaches either (§9, amended 2026-11-23).
        if (rows and controlled(tree, e)) {
            var all: std.ArrayList(u32) = .empty;
            for (pg.writes.items[rows_at..]) |w| if (w.target == target and (w.what == .rows or w.stateful)) try all.appendSlice(pg.a(), w.groups);
            const merged = try sorted(pg.a(), all.items);
            for (pg.writes.items[rows_at..]) |*w| if (w.target == target and (w.what == .rows or w.stateful)) {
                w.groups = merged;
            };
        }
        const below_control = !rows and controlled(tree, e);
        if (below_control) pg.under_control += 1;
        defer if (below_control) {
            pg.under_control -= 1;
        };
        const base: Html = .{ .kind = .element, .name = name, .attributes = attributes.items, .ctx = ctx, .target = target, .dynamic = dynamic.items, .value = value };
        if (facts.void) {
            var out = base;
            out.void = true;
            return out;
        }
        const inner = scope.enter(name);
        const children = tree.childrenOf(e.children);
        if (parser.content(name) != .normal and children.len != 0) return later(pg.cx, n, "the content of an element whose content the parser reads as text");
        if (rows) return base;
        // Texts and text holes only, a hole among them: the element's text
        // is one binding, mixed or alone.
        var holes: u32 = 0;
        const texts = for (children) |child| {
            switch (tree.kind(child)) {
                .text => {},
                .hole => if (textHole(tree.hole(child).kind)) {
                    holes += 1;
                } else break false,
                else => break false,
            }
        } else true;
        if (texts and holes != 0) {
            if (parser.movesText(inner.parent)) return pg.cx.report(n, "the parser moves text written here out of the table");
            var out = base;
            out.children = try pg.textOf(target, ctx, children);
            return out;
        }
        var out: std.ArrayList(Html) = .empty;
        for (children, 0..) |child, ci| {
            // A `For` beside other children: its rows stand before the
            // element after it, or at its parent's end.
            if (tree.kind(child) == .for_) {
                try pg.forChild(child, target, ctx, inner, try forEnd(pg, e, children, ci, pg.count));
                continue;
            }
            if (tree.kind(child) == .hole) {
                const h = tree.hole(child);
                if (textHole(h.kind)) return limit(pg.cx, child, "`browser-inline` writes a text hole as its element's whole text, and this one stands beside an element; wrap the hole and the text around it in an element of their own");
                if (h.kind != .html) return later(pg.cx, child, "a hole that is not text of a `String`, a `Char` or a number");
                if (try pg.cx.programPiece(child)) |piece_facts| {
                    try out.append(pg.a(), try pg.pieceHole(child, piece_facts, ctx, inner));
                    continue;
                }
                if (try pg.helper(child, inner, ctx, &out)) continue;
                try pg.when(child, inner, ctx, &out);
                continue;
            }
            try out.appendSlice(pg.a(), try pg.markup(child, inner, ctx, false));
        }
        var element_ = base;
        element_.children = out.items;
        return element_;
    }

    /// The text of element `n` (`target`), its children texts and holes:
    /// baked into the markup when every hole is, else one binding.
    fn textOf(pg: *Page, target: ?u32, ctx: u32, children: []const m.Node.Index) m.Error![]const Html {
        const tree = pg.tree;
        var parts: std.ArrayList(Part) = .empty;
        var groups: std.ArrayList(u32) = .empty;
        var baked: std.ArrayList(u8) = .empty;
        var all_baked = true;
        // Whether the text written is a `String` already: no lone number.
        var string = true;
        for (children) |child| switch (tree.kind(child)) {
            .text => {
                const s = tree.string(tree.text(child).text);
                try parts.append(pg.a(), .{ .text = s });
                try baked.appendSlice(pg.a(), s);
            },
            else => {
                const h = tree.hole(child);
                const facts = try pg.known(child, pg.cx.programHole(.{ .node = child }));
                if (facts.bake) |b| {
                    try parts.append(pg.a(), .{ .text = b });
                    try baked.appendSlice(pg.a(), b);
                } else {
                    all_baked = false;
                    try parts.append(pg.a(), .{ .value = h.value });
                    if (h.kind == .text_number) string = false;
                    try groups.append(pg.a(), facts.group);
                }
            },
        };
        if (all_baked) {
            if (baked.items.len == 0) return &.{};
            var escaped: std.ArrayList(u8) = .empty;
            try escapeText(pg.a(), &escaped, baked.items);
            return pg.a().dupe(Html, &.{.{ .kind = .text, .name = escaped.items, .ctx = ctx }});
        }
        try pg.writes.append(pg.a(), .{ .target = target, .ctx = ctx, .groups = try sorted(pg.a(), groups.items), .what = .{ .text = parts.items }, .string = string or parts.items.len > 1 });
        return &.{};
    }

    /// The page's string, `html`, with each piece's mark replaced by that
    /// piece's name: one string, or a template of the two.
    fn htmlValue(pg: *Page, html: []const u8) m.Error!m.Expr {
        const js = pg.cx.js;
        if (std.mem.indexOfScalar(u8, html, 0) == null) return js.string(html);
        var parts: std.ArrayList(m.TemplatePart) = .empty;
        var rest = html;
        while (std.mem.indexOfScalar(u8, rest, 0)) |open| {
            if (open != 0) try parts.append(pg.a(), .{ .text = rest[0..open] });
            const close = open + 1 + std.mem.indexOfScalar(u8, rest[open + 1 ..], 0).?;
            const index = std.fmt.parseInt(u32, rest[open + 1 .. close], 10) catch unreachable;
            const u = pg.pieces.items[index];
            try parts.append(pg.a(), .{ .expr = try js.name(try pg.cx.programPieceName(u.node, u.data.html)) });
            rest = rest[close + 1 ..];
        }
        if (rest.len != 0) try parts.append(pg.a(), .{ .text = rest });
        return js.template(parts.items);
    }

    /// An `html` hole that is another module's root, written as pieces
    /// (§8.4): its static markup in place, its elements numbered after its
    /// top element's place.
    fn pieceHole(pg: *Page, n: m.Node.Index, facts: *const m.PieceFacts, ctx: u32, scope: parser.Scope) m.Error!Html {
        if (!facts.written) return error.Reported;
        const data: *const PieceData = @ptrCast(@alignCast(facts.data.?));
        // The piece's markup was checked where its own module wrote it, at a
        // root; the parser reads it where it stands in this page (#373).
        if (rebuilt(scope, data.nodes)) |why| return pg.cx.report(n, why);
        if (ctx != 0) return later(pg.cx, n, "another module's markup inside an `if` or a `case` of the `view`");
        try pg.pieces.append(pg.a(), .{ .node = n, .target = pg.count, .data = data });
        pg.count += 1 + data.count;
        return .{ .kind = .piece, .name = data.top, .piece = @intCast(pg.pieces.items.len - 1), .ctx = ctx };
    }

    /// An `html` hole whose value calls a function of the program's own
    /// module that returns markup written in place (§8.4, amended
    /// 2026-10-19): its markup is walked here, in a context of its own,
    /// whose values are evaluated with the call's arguments bound, and its
    /// holes have the facts of the call's path. False when the hole is not
    /// such a call, for `when` to try; a call that is one but cannot be
    /// written in place is refused.
    fn helper(pg: *Page, n: m.Node.Index, scope: parser.Scope, ctx: u32, out: *std.ArrayList(Html)) m.Error!bool {
        const cx = pg.cx;
        const callee = cx.programCallee(n) orelse return false;
        const r = callee.root orelse switch (callee.refusal) {
            .not_markup => return false,
            .recursive => return later(cx, n, "a function returning markup that calls itself"),
            .other_module => return false,
            else => return later(cx, n, "this call of a function returning markup"),
        };
        if (callee.maps != 0) return later(cx, n, "a function returning markup under `Html.map` in the program's own module");
        if (callee.statements) return later(cx, n, "a function returning markup whose body has `let`s that no hole reads");
        const facts = cx.programHole(.{ .node = n });
        try pg.ctxs.append(pg.a(), .{ .parent = ctx, .node = n, .arm = 0, .root = r, .group = facts.group, .entry_groups = facts.entry_groups, .kind = .call });
        const inner: u32 = @intCast(pg.ctxs.items.len - 1);
        try cx.programInlineEnter(null, n, null, false);
        defer cx.programInlineLeave();
        try out.appendSlice(pg.a(), try pg.markup(pg.tree.root(r).node, scope, inner, false));
        return true;
    }

    /// An `html` hole among an element's children: an eager `when`
    /// (§8.2, D-b) — an `if` one arm of which is one element written in
    /// place and the other `<></>`. Its element is in the markup, in the
    /// arm's context; the `when` is a write of the hole's context.
    fn when(pg: *Page, n: m.Node.Index, scope: parser.Scope, ctx: u32, out: *std.ArrayList(Html)) m.Error!void {
        const cx = pg.cx;
        const tree = pg.tree;
        const not_when = "markup held in data or chosen at run time, or a branch whose arms are not each one element or `<></>`";
        const br = cx.programBranch(n) orelse return later(cx, n, not_when);
        if (br.arms.len < 2) return later(cx, n, not_when);
        // Each arm one element written in place, or `<></>`: one eager
        // `when` per element arm (§8.2, D-b; a `case`, amended 2026-10-19).
        var shown: std.ArrayList(u32) = .empty;
        var removed = false;
        for (br.arms, 0..) |arm, k| {
            if (arm.dead) {
                removed = true;
                continue;
            }
            const r = switch (arm.what) {
                .markup => |r| r,
                else => return later(cx, n, not_when),
            };
            const node = tree.root(r).node;
            const empty = tree.kind(node) == .fragment and tree.fragment(node).children.len == 0;
            if (empty) continue;
            if (tree.kind(node) != .element) return later(cx, n, not_when);
            if (!arm.eager or arm.statements) return later(cx, n, "an `if` or a `case` in markup whose shown arm reads a variable the branch binds, or has `let`s,");
            try shown.append(pg.a(), @intCast(k));
        }
        if (shown.items.len == 0 and !removed) return later(cx, n, not_when);
        const facts = try pg.known(n, cx.programHole(.{ .node = n }));
        if (shown.items.len == 0) {
            // Retain selector and helper-argument effects and throws.
            var groups: std.ArrayList(u32) = .empty;
            try groups.append(pg.a(), facts.group);
            var at: ?u32 = ctx;
            while (at) |c| : (at = pg.ctxs.items[c].parent) {
                const call = pg.ctxs.items[c];
                if (call.kind != .call) continue;
                try groups.appendSlice(pg.a(), call.entry_groups);
            }
            try pg.writes.append(pg.a(), .{ .target = null, .ctx = ctx, .groups = try sorted(pg.a(), groups.items), .what = .{ .observe = n } });
            return;
        }
        for (shown.items) |s| {
            const armRoot = br.arms[s].what.markup;
            try pg.ctxs.append(pg.a(), .{ .parent = ctx, .node = n, .arm = s, .arms = @intCast(br.arms.len), .root = armRoot, .group = facts.group });
            const inner: u32 = @intCast(pg.ctxs.items.len - 1);
            // The `when` before the arm's own writes: document order. It
            // reads what choosing the arm reads, and no more (§8.2, amended
            // 2026-10-24): every value of the shown arm is a write of its
            // own, in the groups of its own hole, and `when` only puts the
            // element or its placeholder in the page.
            try pg.writes.append(pg.a(), .{ .target = pg.count, .ctx = ctx, .groups = try sorted(pg.a(), &.{facts.selector_group orelse facts.group}), .what = .{ .when = .{ .node = n, .shown = s, .arms = @intCast(br.arms.len) } } });
            _ = try cx.programBranchEnter(null, n, s, false, null);
            defer cx.programInlineLeave();
            try out.append(pg.a(), try pg.element(tree.root(armRoot).node, scope, inner, false));
        }
    }

    /// An attribute or an event of element `n` (`target`): a constant one
    /// written into the markup, one `init` bakes too, any other a write; an
    /// event recorded for the mount to wire. Returns the value of a `value`
    /// attribute it wrote into the markup, as the program gives it.
    fn item(pg: *Page, n: m.Node.Index, target: ?u32, ctx: u32, it: m.Item, index: u32, out: *std.ArrayList(u8)) m.Error!?[]const u8 {
        const tree = pg.tree;
        const cx = pg.cx;
        switch (it.kind) {
            .attribute => {},
            .event => {
                var captures: std.ArrayList(u32) = .empty;
                var groups: std.ArrayList(u32) = .empty;
                // Piece listeners already use their constructor directly and
                // never reenter helper arguments at dispatch.
                var at: ?u32 = if (pg.piece) null else ctx;
                while (at) |c| : (at = pg.ctxs.items[c].parent) {
                    const call_ctx = pg.ctxs.items[c];
                    if (call_ctx.kind != .call) continue;
                    const call = tree.hole(call_ctx.node).call orelse continue;
                    const total = for (0..call.args.len) |i| {
                        if (!cx.valuePureTotal(call.args.at(@intCast(i)))) break false;
                    } else true;
                    if (total) continue;
                    try captures.append(pg.a(), c);
                    try groups.append(pg.a(), call_ctx.group.?);
                }
                const ei: u32 = @intCast(pg.events.items.len);
                try pg.events.append(pg.a(), .{ .node = n, .target = target, .ctx = ctx, .item = it, .index = index, .captures = captures.items });
                if (captures.items.len != 0) try pg.writes.append(pg.a(), .{ .target = target, .ctx = ctx, .groups = try sorted(pg.a(), groups.items), .what = .{ .event = ei } });
                return null;
            },
            else => return later(cx, n, "an escape attribute"),
        }
        const name = tree.string(it.name);
        var stateful = false;
        var attribute_only = false;
        var property: ?[]const u8 = null;
        if (it.attribute != .none) {
            const f = tree.attributeFacts(it.attribute);
            attribute_only = f.classes and it.class == .string;
            if (f.raw or f.styles or (f.classes and !attribute_only)) return later(cx, n, "an attribute written as raw HTML, or a class or style list");
            if (f.property) |prop| property = tree.string(prop);
            stateful = f.stateful;
        }
        // A URL (§10.5, amended 2026-11-05). A constant one, and one `init`
        // bakes, is checked here, by `safeUrl`'s rule (`backend.md` §15.3,
        // the `dom` lowering's table), and written into the markup — as
        // nothing for a script URL. Any other is a binding of the attribute
        // whose value is `safeUrl(value)`: one that changes, and a constant
        // or a baked one whose answer turns on a character outside ASCII,
        // which `\s` may match — the runtime decides it, as `browser`'s does.
        if (it.url) {
            // `setAttribute` gives no attribute a namespace (`xlink:href`).
            const plain = std.mem.indexOfScalar(u8, name, ':') == null;
            switch (it.value.kind) {
                .constant => {
                    const c = it.value.constant;
                    switch (c.kind) {
                        .string => {
                            const text = tree.string(c.text);
                            if (scriptUrl(text)) |script| {
                                try writeValue(pg.a(), out, name, if (script) "" else text);
                                return null;
                            }
                            if (!plain) return later(cx, n, "a URL whose first characters are outside ASCII, in an attribute with a namespace prefix");
                            // It reads nothing: the first pass alone writes it.
                            try pg.writes.append(pg.a(), .{ .target = target, .ctx = ctx, .groups = &.{}, .what = .{ .prop = .{ .value = .{ .text = text }, .key = null, .attribute = name, .attribute_only = true, .url = true } } });
                            return null;
                        },
                        .number => {
                            try writeAttribute(pg.a(), out, name, c, tree);
                            return null;
                        },
                        else => return later(cx, n, "an attribute that holds a URL"),
                    }
                },
                .dynamic => {
                    if (it.class != .string) return later(cx, n, "an attribute that holds a URL, whose value changes and is not a `String`");
                    if (!plain) return later(cx, n, "an attribute with a namespace prefix that holds a URL and whose value changes");
                    const facts = try pg.known(n, cx.programHole(.{ .item = index }));
                    if (facts.bake) |b| if (scriptUrl(b)) |script| {
                        try writeValue(pg.a(), out, name, if (script) "" else b);
                        return null;
                    };
                    try pg.writes.append(pg.a(), .{ .target = target, .ctx = ctx, .groups = try sorted(pg.a(), &.{facts.group}), .what = .{ .prop = .{ .value = .{ .value = it.value.dynamic.? }, .key = null, .attribute = name, .attribute_only = true, .url = true } } });
                    return null;
                },
                else => return later(cx, n, "an attribute that holds a URL"),
            }
        }
        switch (it.value.kind) {
            .constant => {
                // A control's value in the markup would be its default, not
                // what it shows: a constant one is a write too.
                if (stateful) return later(cx, n, "a constant value of a control");
                try writeAttribute(pg.a(), out, name, it.value.constant, tree);
                const c = it.value.constant;
                return if (std.mem.eql(u8, name, "value") and c.kind == .string) tree.string(c.text) else null;
            },
            .dynamic => {},
            else => return later(cx, n, "this attribute's value"),
        }
        const v = it.value.dynamic.?;
        const facts = try pg.known(n, cx.programHole(.{ .item = index }));
        if (facts.bake) |b| if (!stateful and property == null) {
            try writeValue(pg.a(), out, name, b);
            return if (std.mem.eql(u8, name, "value")) b else null;
        };
        // A boolean attribute whose DOM property has its name, or a
        // property: written through it (§8.2).
        const key: ?[]const u8 = if (attribute_only) null else if (property) |prop|
            (if (std.mem.eql(u8, prop, "value")) null else prop)
        else if (it.class == .bool and isBoolProperty(name))
            name
        else
            return later(cx, n, "an attribute that is not a DOM property and whose value changes");
        try pg.writes.append(pg.a(), .{ .target = target, .ctx = ctx, .groups = try sorted(pg.a(), &.{facts.group}), .what = .{ .prop = .{ .value = .{ .value = v }, .key = key, .attribute = name, .boolean = it.class == .bool, .attribute_only = attribute_only } }, .stateful = stateful });
        return null;
    }

    // ---- The mount ----------------------------------------------------

    /// The mount (`browser-inline.md` §3–§4, §8): the element found, `init`
    /// evaluated (a release build drops it when nothing reads it and it has
    /// no effect), the markup written once after the element's children,
    /// the elements found, the program's table made, the program's own
    /// binding entries made, each key's handler, each event wired, each
    /// root's factory called, the first pass, each subscription started,
    /// `init`'s command queued, and what undoes the mount registered.
    fn mount(pg: *Page, view_node: m.Node.Index) m.Error!m.Expr {
        const cx = pg.cx;
        const js = cx.js;
        if (pg.top_nodes.len > 1) return later(cx, view_node, "a `view` of more than one top-level node");
        // The statements of a `view` with `let`s, one entry of their own
        // (§8.2, amended 2026-11-23).
        if (pg.p.view_lets) {
            const groups = cx.programViewStatementGroups() orelse return limit(cx, view_node, "the write-set pass gave no read set for a statement of this `view`, and `browser-inline` runs a statement again when what it reads is written");
            if (groups.len != 0) pg.statements = try pg.a().dupe(u32, groups);
        }
        const element_ = pg.p.constructor >= 1;
        const keys = cx.programKeys();
        pg.handlers = try pg.a().alloc(?m.Name, keys.len);
        @memset(pg.handlers, null);

        // What the program's subscriptions and commands are, refused first.
        var subs: []const m.Program.Subscription = &.{};
        if (element_) {
            switch (cx.programSubscriptions()) {
                .set => |s| subs = s,
                .model => return cx.programReport(.call, .not_implemented,
                    \\A limit of the compiler: this program's subscriptions depend on its model, and
                    \\`browser-inline` compiles a set of subscriptions that is the same for the page's life;
                    \\a set that changes it does not compile yet (`docs/design/browser-inline.md` §3; §5,
                    \\class 1). Write `subscriptions` so that it does not read the model, and let `update`
                    \\ignore what it does not need.
                ),
                .no_key => |where| return cx.programReport(.call, .program_shape, try std.fmt.allocPrint(cx.arena,
                    \\The subscription at {s} hands its values to a tagger that does not give one of the
                    \\program's message constructors, and `browser-inline` calls the handler of that
                    \\constructor's key with each value directly, with no message made
                    \\(`docs/design/browser-inline.md` §3; §5, class 3). Tag the value with a constructor of
                    \\the message that takes it — `Pushed Value`, tagged with `Pushed` — and decide in
                    \\`update` what it means.
                , .{where})),
                .limit => |where| return cx.programReport(.call, .not_implemented, try std.fmt.allocPrint(cx.arena,
                    \\A limit of the compiler: the subscription at {s} tags its values with a message whose
                    \\handler the write-set pass decides only from the value itself — the constructor wraps
                    \\the value, or `update` matches on what the value holds — and `browser-inline` calls a
                    \\handler chosen when the program is built (`docs/design/browser-inline.md` §3; §5,
                    \\class 4). The program is valid: it builds with `--platform=browser-tea`.
                , .{where})),
                else => return cx.programReport(.call, .not_implemented,
                    \\A limit of the compiler: the write-set pass could not read this program's
                    \\subscriptions as a list of `Sub.on` declarations with constant keys
                    \\(`docs/design/browser-inline.md` §3; §5, class 4). Write them with `Sub.on`,
                    \\`Sub.batch`, `Sub.map` and `Sub.none`, each key a constant.
                ),
            }
        }
        // A value that reaches its key as a message (§10.3) goes through the
        // dispatcher, as a command's messages do.
        var messages = false;
        for (subs) |s| {
            if (s.fields > 1) return cx.programReport(.call, .not_implemented, try std.fmt.allocPrint(cx.arena,
                \\A limit of the compiler: `browser-inline` does not compile the subscription at {s} yet:
                \\its message's constructor takes the value in more than one field
                \\(`docs/design/browser-inline.md` §5, class 1). Give the constructor one field for the
                \\value.
            , .{s.where}));
            if (s.message) {
                messages = true;
                continue;
            }
            if (s.handler >= keys.len) return cx.programReport(.call, .not_implemented, "A limit of the compiler: a subscription's key has no handler.");
            if (s.fields != 0 and keys[s.handler].fields != s.fields) return cx.programReport(.call, .not_implemented, try std.fmt.allocPrint(cx.arena,
                \\A limit of the compiler: `browser-inline` does not compile the subscription at {s} yet:
                \\its tagger supplies {d} constructor fields, but the selected handler expects {d}
                \\(`docs/design/browser-inline.md` §5, class 1). This field mapping is not supported yet.
            , .{ s.where, s.fields, keys[s.handler].fields }));
            _ = try pg.handler(s.handler);
        }
        // A command that runs sends messages of any key: every key is then
        // reached, through the dispatcher.
        var runs = (element_ and try pg.command(null)) or messages;
        // A row's event hands its message to the dispatcher (§9, amended
        // 2026-11-23), whose name the rows' listeners are written with
        // before any handler is.
        if (pg.row_events) {
            runs = true;
            pg.dispatch = try cx.fresh("dispatch");
        }

        pg.body = try js.block();
        const body = pg.body;
        const id = try cx.fresh("id");
        const at = try cx.fresh("root");
        // The element: the one a placement written at the call names, the
        // page's body for `main` itself, or the one the program value is
        // handed. A constant argument is one a release build folds into
        // `root`.
        const which = switch (pg.p.placed) {
            .at => |text_| try js.string(text_),
            .body => try js.literal(.undefined),
            else => try js.name(id),
        };
        try js.constant(body, at, try js.call(try js.name(try cx.runtime("root")), &.{which}));
        // The client of a prerendering build takes the prerendered page over
        // (`prerender.md` §6): its view is one element of its own, or the
        // prerender tree's render function refused it.
        pg.hydrating = cx.build.prerender == .client;
        if (pg.hydrating and pg.fors.items.len != 0) return later(cx, pg.fors.items[0].node, "a `For` in a prerendered page");
        if (pg.hydrating and (pg.top_nodes.len != 1 or pg.top_nodes[0].kind != .element or pg.top_nodes[0].ctx != 0))
            return later(cx, view_node, "a prerendered page of a `view` whose top-level node is not one element of its own; it does not prerender it");
        // A program of each page's value reads it from the page before
        // `init` (`prerender.md` §8.6): `[route, value]`, the value bound to
        // the lambda's parameter, which `init` reads.
        const data: ?m.Name = if (pg.p.data) blk: {
            const d = try cx.fresh("data");
            const schema = try cx.programDataSchema(body);
            try js.constant(body, d, try js.call(try js.name(try cx.runtime("pageData")), &.{ schema, try js.name(at) }));
            try cx.programDataBind(body, try js.index(try js.name(d), try js.number("1")));
            break :blk d;
        } else null;
        // An application's `init` is handed the page's address and key
        // (§10), read inside the mount's guard.
        // A hydrating one's is the route its page carries, never `location`
        // (`prerender.md` §7.3); one of a page's value, the route its value
        // came with (§8.6), whether the page is taken over or not.
        const init = if (pg.p.constructor == 3) blk: {
            const address = if (data) |d| a: {
                const u = try cx.fresh("url");
                try js.constant(body, u, try js.call(try js.name(try cx.runtime("routeUrl")), &.{ try js.string(cx.build.address), try js.index(try js.name(d), try js.number("0")) }));
                pg.route_url = u;
                break :a try js.name(u);
            } else if (pg.hydrating) a: {
                const u = try cx.fresh("url");
                try js.constant(body, u, try js.call(try js.name(try cx.runtime("pageUrl")), &.{try js.string(cx.build.address)}));
                pg.route_url = u;
                break :a try js.name(u);
            } else try js.call(try js.name(try cx.runtime("address")), &.{});
            break :blk try cx.programStart(body, &.{
                address,
                try js.call(try js.name(try cx.runtime("navigationKey")), &.{}),
            });
        } else try cx.programInit(body);
        // The model, kept only when something reads it.
        pg.model = try cx.fresh("model");
        const titled = pg.p.constructor >= 2;
        const reads_model = pg.writes.items.len != 0 or pg.events.items.len != 0 or pg.pieces.items.len != 0 or subs.len != 0 or runs or titled or pg.statements != null;
        if (reads_model) {
            const first_model = if (element_) try js.member(init, "a") else init;
            // A root reaches the model through the program's cell when no
            // object of it is one every key keeps (§8.4, amended 2026-10-22):
            // the model is then held in the cell's one slot.
            if (cx.programModelCell()) {
                pg.cell = try cx.fresh("cell");
                try js.constant(body, pg.cell.?, try js.array(&.{first_model}));
            } else try js.let(body, pg.model, first_model);
        }
        // A document's title (§10): one function of the model, called after
        // the first pass and after each handler's write pass, which writes
        // the title when it differs from the page's.
        if (titled) {
            const blk = try js.block();
            const value = try cx.programField(blk, .title, try pg.modelRef());
            try js.expression(blk, try js.call(try js.name(try cx.runtime("title")), &.{value}));
            pg.retitle = try cx.fresh("retitle");
            try js.constant(body, pg.retitle.?, try js.arrow(&.{}, blk));
        }
        if (pg.hydrating) {
            cx.at(view_node);
            var html: std.ArrayList(u8) = .empty;
            try serialise(pg.a(), &html, pg.top_nodes, null, true);
            // A unit whose page has a capture script takes the input it
            // recorded, before `take` and before any listener is added
            // (`prerender.md` §6.5, amended 2026-10-29).
            if ((try pg.capturedKinds()).len != 0) {
                pg.taking = true;
                try js.expression(body, try js.call(try js.name(try cx.runtime("caught")), &.{try js.name(at)}));
            }
            try pg.take(at, html.items);
        } else if (pg.top_nodes.len == 1) {
            cx.at(view_node);
            var html: std.ArrayList(u8) = .empty;
            // The whole string the parser reads: nothing is appended after
            // it, so the end of the input may close the last node's path.
            try serialise(pg.a(), &html, pg.top_nodes, null, true);
            try js.expression(body, try js.call(try js.member(try js.name(at), "insertAdjacentHTML"), &.{ try js.string("beforeend"), try pg.htmlValue(html.items) }));
            pg.node = try cx.fresh("node");
            try js.constant(body, pg.node.?, try js.member(try js.name(at), "lastChild"));
            // Each piece registers what removes it as it is added, so a mount
            // that throws halfway leaves nothing `stop` cannot take back.
            const undo = try js.block();
            try js.expression(undo, try js.call(try js.member(try js.name(pg.node.?), "remove"), &.{}));
            try js.expression(body, try js.call(try js.name(try cx.runtime("own")), &.{try js.arrow(&.{}, undo)}));
        }
        // The runs of roots mounted through one table (§8.4, amended
        // 2026-10-24), and whether a piece is reached other than as a child
        // of its run's parent. The hydrating mount has none: a run reads
        // each root's table from the page, and a piece's table is cut from
        // the merged one (`prerender.md` §6.2).
        const root_runs = if (pg.hydrating) &.{} else try pg.rootRuns();
        const piece_placed = for (pg.pieces.items, 0..) |_, i| {
            const r = runOf(root_runs, @intCast(i)) orelse break true;
            switch (r.elements) {
                .children => |c| if (c.parent != null) break true,
                .places => break true,
            }
        } else false;
        // The elements code refers to, by place.
        const placed = piece_placed or for (pg.writes.items) |w| {
            if (w.target != null) break true;
        } else for (pg.events.items) |ev| {
            if (ev.target != null) break true;
        } else for (pg.fors.items) |f| {
            if (f.end != null) break true;
        } else false;
        if (placed and !pg.hydrating) {
            // One element referred to is reached by its path from the top
            // node, which costs less than the list of all of them; more are
            // read from the list (§8.2).
            const only = pg.onlyTarget();
            const path = if (only) |t| try pathOf(pg.a(), pg.top_nodes[0].children, t) else null;
            if (path) |steps| {
                pg.elements = try cx.fresh("element");
                pg.single = true;
                var e: m.Expr = try js.name(pg.node.?);
                for (steps) |i| e = if (i == 0) try js.member(e, "firstChild") else try js.index(try js.member(e, "childNodes"), try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{i})));
                try js.constant(body, pg.elements.?, e);
            } else {
                pg.elements = try cx.fresh("elements");
                try js.constant(body, pg.elements.?, try js.call(try js.member(try js.name(pg.node.?), "querySelectorAll"), &.{try js.string("*")}));
            }
        }

        // Each piece's elements, below its top element; a run's are found
        // as each of its roots is mounted.
        for (pg.pieces.items, 0..) |*u, i| {
            if (runOf(root_runs, @intCast(i)) != null) continue;
            u.elements = try cx.fresh("elements");
            if (pg.hydrating) {
                // The slice of the merged table below the root's top
                // element: its elements are a run of it (`prerender.md`
                // §6.2).
                const from = u.target + 2;
                try js.constant(body, u.elements, try js.call(try js.member(try js.name(pg.elements.?), "slice"), &.{
                    try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{from})),
                    try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{from + u.data.count})),
                }));
                continue;
            }
            try js.constant(body, u.elements, try js.call(try js.name(try cx.runtime("part")), &.{try pg.ref(u.target)}));
        }
        // Handler-bound arguments share the handler's lifetime. Release
        // them even when a host keeps a node after the program is stopped.
        // Register only after the element/part table constants above exist.
        const release_bindings = try js.block();
        var retains = false;
        for (pg.events.items) |ev| if (ev.captures.len != 0) {
            retains = true;
            try js.assign(release_bindings, try pg.eventBindingFor(ev), try js.literal(.undefined));
        };
        if (retains) try js.expression(body, try js.call(try js.name(try cx.runtime("own")), &.{try js.arrow(&.{}, release_bindings)}));

        // The program's table (§8.4, amended 2026-10-22): a row per root
        // that has buckets, each bucket made before any root fills one, so a
        // root may add to another's in either order.
        const rows = cx.programRows();
        pg.table = try cx.fresh("table");
        if (rows.len != 0) {
            const row_exprs = try pg.a().alloc(m.Expr, rows.len);
            for (rows, row_exprs) |n, *re| {
                const buckets = try pg.a().alloc(m.Expr, n);
                for (buckets) |*b| b.* = try js.array(&.{});
                re.* = try js.array(buckets);
            }
            try js.constant(body, pg.table.?, try js.array(row_exprs));
        }
        pg.row = cx.programRootRow(null);

        // The program's own binding entries, in document order.
        try pg.guardGroups();
        try pg.group();
        try pg.memos();
        try pg.letsOnce();
        try pg.argsOnce();
        for (pg.functions.items) |*f| try pg.writeEntry(body, f);
        // A `For` whose read set some key writes is in a bucket that key's
        // pass runs: an entry of no bucket runs at the first pass alone, and
        // its rows would never follow a write (§9, amended 2026-11-23).
        if (std.debug.runtime_safety) for (pg.functions.items) |*f| for (f.writes.items) |wi| {
            const w = pg.writes.items[wi];
            if (w.what != .rows) continue;
            var written = false;
            for (0..keys.len) |k| for (w.groups) |g| {
                if (cx.programCalls(@intCast(k), g)) written = true;
            };
            if (written) std.debug.assert((try pg.functionBuckets(f)).len != 0);
        };

        // Plan events before writing handlers: each key determines which
        // stateful controls its arm writes back. Each DOM listener carries
        // its own arm.
        var plans: std.ArrayList(Plan) = .empty;
        for (pg.events.items) |ev| try plans.append(pg.a(), try pg.plan(ev));
        // Per key, the buckets of a stateful control one of its events is
        // on: its handler runs them whatever it writes (§8.3).
        pg.controls = try pg.a().alloc(std.ArrayList(m.Program.BucketRef), keys.len);
        @memset(pg.controls, .empty);
        var stateful_at: std.AutoHashMapUnmanaged(?u32, std.ArrayList(m.Program.BucketRef)) = .empty;
        for (pg.functions.items) |*f| for (f.writes.items) |wi| {
            const w = pg.writes.items[wi];
            if (!w.stateful) continue;
            const slot = try stateful_at.getOrPut(pg.a(), w.target);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try addRefs(pg.a(), slot.value_ptr, try pg.functionBuckets(f));
        };
        // A control in a `For`'s row is written back by every key: its
        // event goes through the dispatcher, which may reach any (§8.3,
        // *Controlled inputs*; §9, amended 2026-11-23).
        for (pg.functions.items) |*f| for (f.writes.items) |wi| {
            const w = pg.writes.items[wi];
            if (w.what != .rows or !pg.fors.items[w.what.rows].plan.stateful) continue;
            const bs = try pg.functionBuckets(f);
            for (pg.controls) |*c| try addRefs(pg.a(), c, bs);
        };
        // DOM sites get their arm at wiring. Only non-DOM consumers need
        // a named handler; all sites still contribute to key-wide controls.
        const refs = try pg.a().alloc(u32, keys.len);
        @memset(refs, 0);
        const named = try pg.a().alloc(bool, keys.len);
        @memset(named, false);
        for (subs) |s| if (!s.message) {
            refs[s.handler] += 1;
            named[s.handler] = true;
        };
        for (plans.items, 0..) |pl, i| {
            const fs = stateful_at.get(pg.events.items[i].target);
            const k = pl.key orelse {
                // Its message may be any key's, through the dispatcher: every
                // key is then reached, and each writes the control back
                // (§8.3, amended 2026-11-05).
                runs = true;
                if (fs) |s| for (pg.controls) |*c| try addRefs(pg.a(), c, s.items);
                continue;
            };
            refs[k] += 1;
            if (fs) |s| try addRefs(pg.a(), &pg.controls[k], s.items);
        }
        // Each piece's handlers, by the key the constructor reaches through
        // the hole's maps.
        const piece_keys = try pg.a().alloc([]m.Context.PieceKey, pg.pieces.items.len);
        for (pg.pieces.items, piece_keys) |u, *ks| {
            ks.* = try pg.a().alloc(m.Context.PieceKey, u.data.handlers.len);
            for (u.data.handlers, ks.*) |h, *pk| {
                pk.* = cx.programPieceKey(u.node, h.ctor) orelse {
                    // A key the pass cut or could not split names its own
                    // cause before the maps are blamed.
                    for (keys) |key| if (key.star or key.cap != .none) try pg.refuseKey(key);
                    return limit(cx, u.node, "an event of this other module's markup sends a message whose key `browser-inline` cannot name through the `Html.map`s around the call, each of which must be a constructor of one field");
                };
                const k = pk.key;
                if (keys[k].fields != (if (pk.whole) 1 else h.fields)) return limit(cx, u.node, "an event of this other module's markup sends a message whose key's handler takes another number of fields");
                refs[k] += 1;
                try addRefs(pg.a(), &pg.controls[k], h.controls);
            }
        }
        for (refs, 0..) |r, k| if (r != 0 and element_) {
            if (try pg.command(@intCast(k))) runs = true;
        };
        if (runs) {
            // The dispatcher hands each handler its leaf's fields, however
            // deep the key (`programDispatch`).
            for (0..keys.len) |k| {
                refs[k] += 1;
                named[k] = true;
                if (element_) _ = try pg.command(@intCast(k));
            }
            if (pg.dispatch == null) pg.dispatch = try cx.fresh("dispatch");
        }

        // Each handler body writes the model, then its write pass runs the
        // buckets the key's writes reach, each entry once, then its command
        // is queued.
        const any = for (refs) |r| {
            if (r != 0) break true;
        } else false;
        const update = if (any) try cx.programUpdate(body) else null;
        const listeners = try pg.a().alloc(m.Expr, plans.items.len);
        // Initialized exactly for refs[k] != 0: every plan and piece key
        // contributes a reference before its body reads passes[k], as do
        // subscription and dispatcher consumers before a named body.
        const passes = try pg.a().alloc([]const m.Program.BucketRef, keys.len);
        for (keys, 0..) |key, k| {
            if (refs[k] == 0) continue;
            try pg.refuseKey(key);
            passes[k] = try pg.passOf(@intCast(k), key);
            if (!named[k]) continue;
            const params = try pg.a().alloc(m.Name, key.fields);
            for (params) |*x| x.* = try cx.fresh("value");
            const blk = try js.block();
            try pg.handlerBody(blk, @intCast(k), params, update, passes[k]);
            try js.constant(body, try pg.handler(@intCast(k)), try js.arrow(params, blk));
        }
        // Each local listener contains its arm, its fields bound to what
        // the event's message holds, even when another event has the key.
        for (plans.items, listeners) |pl, *l| {
            const k = pl.key orelse {
                // What `send` reads of the event: the message the handler
                // value makes, which the dispatcher then takes (§8.3, amended
                // 2026-11-05) — of what the event's extractor reads, when it
                // has one, read first.
                try js.@"return"(pl.blk, pl.message.?);
                l.* = if (pl.read) |rd| made: {
                    const e = try cx.fresh("event");
                    const outer = try js.block();
                    try js.constant(outer, pl.event.?, try js.call(rd, &.{try js.name(e)}));
                    try js.nested(outer, pl.blk);
                    break :made try js.arrow(&.{e}, outer);
                } else if (pl.event) |e| try js.arrow(&.{e}, pl.blk) else try js.arrow(&.{}, pl.blk);
                continue;
            };
            const params = try pg.a().alloc(m.Name, keys[k].fields);
            for (params) |*x| x.* = try cx.fresh("value");
            if (pl.args.len != params.len) return limit(cx, pl.node, "this event's message has another number of fields than its key's handler takes");
            for (params, pl.args) |x, arg| try js.constant(pl.blk, x, arg);
            try pg.handlerBody(pl.blk, k, params, update, passes[k]);
            l.* = if (pl.event) |e| try js.arrow(&.{e}, pl.blk) else try js.arrow(&.{}, pl.blk);
        }
        if (pg.dispatch) |d| {
            const msg = try cx.fresh("msg");
            const blk = try js.block();
            const all = try pg.a().alloc(m.Name, keys.len);
            for (all, 0..) |*x, k| x.* = try pg.handler(@intCast(k));
            try cx.programDispatch(blk, try js.name(msg), all);
            try js.constant(body, d, try js.arrow(&.{msg}, blk));
        }

        // Each event wired. A listener with neither flag is the runtime's
        // `on`, the event's name left out for a click.
        // An event whose message goes through the dispatcher hands `send`
        // the dispatcher, and its listener as what `send` reads of the
        // event, while the event is dispatched (§8.3, amended 2026-11-05).
        for (plans.items, listeners, pg.events.items) |pl, f, evinfo| {
            const node = try pg.ref(pl.target);
            if (evinfo.captures.len == 0 and !pl.flags.prevent_default and !pl.flags.stop_propagation) {
                const call = if (pl.key == null)
                    try pg.onCall(node, try js.name(pg.dispatch.?), pl.kind, evinfo.ctx, f)
                else
                    try pg.onCall(node, f, pl.kind, evinfo.ctx, pl.read);
                try js.expression(body, call);
                continue;
            }
            const active = if (evinfo.captures.len != 0) try pg.eventBindingFor(evinfo) else try pg.armActivity(evinfo.ctx);
            // The guard retains one callback made during mount; dispatch
            // must not allocate a new handler closure.
            const listener = try cx.fresh("listener");
            try js.constant(body, listener, f);
            const ev = try cx.fresh("event");
            const dom = try js.block();
            if (pl.flags.prevent_default or pl.flags.stop_propagation) {
                const stopped = try js.block();
                try js.@"return"(stopped, null);
                try js.@"if"(dom, try js.call(try js.name(try cx.runtime("stopped")), &.{}), stopped, null);
            }
            if (active) |active_test| {
                const inactive = try js.block();
                try js.@"return"(inactive, null);
                try js.@"if"(dom, try js.unary(.not, active_test), inactive, null);
            }
            if (pl.flags.prevent_default) try js.expression(dom, try js.call(try js.member(try js.name(ev), "preventDefault"), &.{}));
            if (pl.flags.stop_propagation) try js.expression(dom, try js.call(try js.member(try js.name(ev), "stopPropagation"), &.{}));
            const send = try js.name(try cx.runtime("send"));
            const call = if (pl.key == null)
                try js.call(send, &.{ try js.name(pg.dispatch.?), try js.name(ev), try js.name(listener) })
            else if (pl.read) |rd|
                try js.call(send, &.{ try js.name(listener), try js.name(ev), rd })
            else
                try js.call(send, &.{ try js.name(listener), try js.name(ev) });
            try js.expression(dom, call);
            try js.expression(body, try pg.addListener(node, pl.kind orelse "click", try js.arrow(&.{ev}, dom)));
        }

        // Each piece's root factory (§8.4, amended 2026-10-22), in placement
        // order: its elements, what it holds of the model, the buckets it
        // fills, and a handler per constructor its events send.
        if (pg.pieces.items.len != 0) try cx.programViewEnter(body, try pg.modelRef());
        var next_run: usize = 0;
        for (pg.pieces.items, piece_keys, 0..) |u, ks, i| {
            // A run is mounted where its first root stands: one row per
            // root, `[factory, holder…]`, and one call of the runtime's
            // `roots`, which calls each factory in turn with the root's
            // elements, its holders, its own row and the table.
            if (next_run < root_runs.len and root_runs[next_run].start <= i) {
                const r = root_runs[next_run];
                if (i + 1 == r.start + r.len) next_run += 1;
                if (i != r.start) continue;
                const run_rows = try pg.a().alloc(m.Expr, r.len);
                const tops = try pg.a().alloc(m.Expr, r.len);
                for (run_rows, tops, pg.pieces.items[r.start..][0..r.len]) |*rr, *top, w| {
                    const hs = try cx.programRootArgs(body, w.node, pg.model, pg.cell);
                    std.debug.assert(hs.len == w.data.arity);
                    const row_items = try pg.a().alloc(m.Expr, 1 + hs.len);
                    row_items[0] = try js.name(try cx.programPieceName(w.node, w.data.root.?));
                    @memcpy(row_items[1..], hs);
                    rr.* = try js.array(row_items);
                    if (r.elements == .places) top.* = try pg.ref(w.target);
                }
                const elements, const from = switch (r.elements) {
                    .children => |c| .{ try js.member(try pg.ref(c.parent), "children"), c.from },
                    .places => .{ try js.array(tops), 0 },
                };
                try js.expression(body, try js.call(try js.name(try cx.runtime("roots")), &.{
                    try js.array(run_rows),
                    elements,
                    try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{from})),
                    try js.name(pg.table.?),
                    try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{r.row})),
                }));
                continue;
            }
            const factory = u.data.root orelse continue;
            const blk = body;
            const holders = try cx.programRootArgs(blk, u.node, pg.model, pg.cell);
            std.debug.assert(holders.len == u.data.arity);
            var args: std.ArrayList(m.Expr) = .empty;
            try args.append(pg.a(), try js.name(u.elements));
            try args.appendSlice(pg.a(), holders);
            const row = cx.programRootRow(u.node);
            // The owner filled its own row only when the plan gave it one,
            // and a table only when the program has one.
            std.debug.assert(!u.data.own_row or row != null);
            std.debug.assert(!(u.data.own_row or u.data.table) or rows.len != 0);
            if (u.data.own_row) try args.append(pg.a(), try js.index(try js.name(pg.table.?), try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{row.?}))));
            if (u.data.table) try args.append(pg.a(), try js.name(pg.table.?));
            for (ks, u.data.handlers) |pk, h| {
                // Each handler its own body. A whole-message leaf receives the
                // message its constructor's fields make.
                const hblk = try js.block();
                const fields = try pg.a().alloc(m.Name, h.fields);
                const field_exprs = try pg.a().alloc(m.Expr, h.fields);
                for (fields, field_exprs) |*f, *fe| {
                    f.* = try cx.fresh("value");
                    fe.* = try js.name(f.*);
                }
                const params = if (pk.whole) p: {
                    const value = try cx.fresh("value");
                    try js.constant(hblk, value, try cx.programPieceMessage(u.node, h.ctor, pk.key, field_exprs));
                    break :p try pg.a().dupe(m.Name, &.{value});
                } else fields;
                try pg.handlerBody(hblk, pk.key, params, update, passes[pk.key]);
                try args.append(pg.a(), try js.arrow(fields, hblk));
            }
            try js.expression(blk, try js.call(try js.name(try cx.programPieceName(u.node, factory)), args.items));
        }
        if (pg.pieces.items.len != 0) cx.programViewLeave();
        // Every root has made its entries: the first pass, before the
        // subscriptions start and `init`'s command runs.
        if (pg.functions.items.len != 0 or pg.pieces.items.len != 0) try js.expression(body, try js.call(try js.name(try cx.runtime("first")), &.{}));
        if (pg.retitle) |r| try js.expression(body, try js.call(try js.name(r), &.{}));

        // Each subscription started: the first declaration of each key
        // starts it, and each value goes through every declaration of that
        // key in order, each a dispatch of its own.
        // A program with scoped subscriptions but no commands needs no
        // whole-message dispatcher. Give its task root a private identity
        // instead of reaching a dispatcher that the plan never created.
        var work_owner: ?m.Expr = null;
        for (subs) |s| if (s.waits) {
            if (pg.dispatch) |dispatch| {
                work_owner = try js.name(dispatch);
            } else {
                const owner = try cx.fresh("workOwner");
                try js.constant(body, owner, try js.object(&.{}));
                work_owner = try js.name(owner);
            }
            break;
        };
        for (subs, 0..) |s, i| {
            if (s.first != i) continue;
            const v = try cx.fresh("v");
            const sends = try js.block();
            var declarations: usize = 0;
            for (subs) |t| {
                if (t.first == i) declarations += 1;
            }
            for (subs, 0..) |t, j| {
                if (t.first != i) continue;
                // A message with no payload passes none: `send`'s argument is
                // `undefined` either way.
                // A value that reaches its key as a message is the message,
                // sent to the dispatcher (§10.3).
                const call = if (t.message)
                    try js.call(try js.name(try cx.runtime("send")), &.{ try js.name(pg.dispatch.?), try cx.programSubscriptionMessage(@intCast(j), try js.name(v)) })
                else if (t.whole)
                    // A key whose handler takes the message itself — no step,
                    // or a default step last — is handed the message the
                    // tagger makes of the value, not the value (§3, amended
                    // 2026-11-09, #2258).
                    try js.call(try js.name(try cx.runtime("send")), &.{ try js.name(try pg.handler(t.handler)), try cx.programSubscriptionMessage(@intCast(j), try js.name(v)) })
                else blk: {
                    const handler_ = try js.name(try pg.handler(t.handler));
                    break :blk try js.call(try js.name(try cx.runtime("send")), if (t.fields == 0) &.{handler_} else &.{ handler_, try js.name(v) });
                };
                // One declaration's send is the runtime's `send` itself, whose
                // result is `undefined` and which no start reads (§3, amended
                // 2026-10-24).
                if (declarations == 1) try js.@"return"(sends, call) else try js.expression(sends, call);
            }
            const send = try js.arrow(if (s.fields == 0) &.{} else &.{v}, sends);
            // What the start returns, the remover, is owned where it is made.
            const install = if (s.entry or s.waits) try js.block() else body;
            const start = try cx.programSubscriptionStart(install, @intCast(i), send);
            const registered = if (s.waits) blk: {
                try js.@"return"(install, start);
                break :blk try js.call(try js.name(try cx.runtime("startWork")), &.{ work_owner.?, try js.arrow(&.{}, install) });
            } else if (s.entry) blk: {
                try js.@"return"(install, start);
                break :blk try js.call(try js.name(try cx.runtime("subscribe")), &.{try js.arrow(&.{}, install)});
            } else start;
            try js.expression(body, try js.call(try js.name(try cx.runtime("own")), &.{registered}));
        }
        // A hydrating application's own address, once `onUrlChange` listens:
        // sent when it is not the route `init` was handed (`prerender.md`
        // §7.3).
        if (pg.route_url) |u| try js.expression(body, try js.call(try js.name(try cx.runtime("arrived")), &.{try js.name(u)}));
        // `init`'s command, after the mount's writes.
        if (element_ and (cx.programCommand(null) == .runs or cx.programCommand(null) == .suspends)) {
            try js.expression(body, try js.call(try js.name(try cx.runtime("commands")), &.{ try js.member(init, "b"), try js.name(pg.dispatch.?) }));
        }
        // The input made before the takeover, handed to its listeners last
        // (`prerender.md` §6.5, amended 2026-10-29).
        if (pg.taking) try js.expression(body, try js.call(try js.name(try cx.runtime("deliver")), &.{
            try js.index(try js.name(pg.elements.?), try js.number("0")),
        }));
        return js.arrow(&.{id}, body);
    }

    // ---- Hydration (`prerender.md` §6) ----------------------------------

    /// The hydrating mount's table (`prerender.md` §6.1–§6.4): the
    /// runtime's `take` given the mount element, the unit's string, each
    /// eager arm as three numbers — its element's index in the table, how
    /// many elements it holds, its parent's index — and the tag of each
    /// element of the table, space-separated, which the mount checks the
    /// page against in every build: the table is by index, so an element no
    /// code refers to, taken out or put in, moves those that code refers to
    /// (§6.4, amended 2026-10-29, #1186).
    fn take(pg: *Page, at: m.Name, html: []const u8) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        var layout: Layout = .{ .a = pg.a() };
        try layout.unit(pg, pg.top_nodes[0]);
        const arms = try pg.a().alloc(m.Expr, 3 * layout.arms.items.len);
        for (layout.arms.items, 0..) |r, k| for ([_]u32{ r.at, r.len, r.parent }, 0..) |x, j| {
            arms[3 * k + j] = try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{x}));
        };
        var tags: std.ArrayList(u8) = .empty;
        for (layout.names.items, 0..) |name, i| {
            if (i != 0) try tags.append(pg.a(), ' ');
            try tags.appendSlice(pg.a(), name);
        }
        pg.elements = try cx.fresh("elements");
        try js.constant(pg.body, pg.elements.?, try js.call(try js.name(try cx.runtime("take")), &.{
            try js.name(at),
            try pg.htmlValue(html),
            try js.array(arms),
            try js.string(tags.items),
        }));
    }

    // ---- The string form (`prerender.md` §4) ---------------------------

    /// The program's render function, in the prerender tree in the mount's
    /// place (`prerender.md` §4.1): given the route, it evaluates `init` and
    /// gives the unit's HTML — the static string with each hole's value in
    /// its place, the arms `init`'s model hides left out.
    fn render(pg: *Page, view_node: m.Node.Index) m.Error!m.Expr {
        const cx = pg.cx;
        const js = cx.js;
        if (pg.top_nodes.len > 1) return later(cx, view_node, "a `view` of more than one top-level node");
        if (pg.top_nodes.len == 0 or pg.top_nodes[0].kind != .element or pg.top_nodes[0].ctx != 0)
            return later(cx, view_node, "a prerendered page of a `view` whose top-level node is not one element of its own; it does not prerender it");
        if (pg.fors.items.len != 0) return later(cx, pg.fors.items[0].node, "a `For` in a prerendered page");
        const body = try js.block();
        const route = try cx.fresh("route");
        // A program of each page's value renders from the value its schema
        // decodes from the page's text (`prerender.md` §8.5 item 5), or gives
        // the issues, `{ issues }`, and renders nothing.
        const text: ?m.Name = if (pg.p.data) blk: {
            const t = try cx.fresh("text");
            const d = try cx.fresh("data");
            const schema = try cx.programDataSchema(body);
            try js.constant(body, d, try js.call(try js.name(try cx.runtime("decoded")), &.{ schema, try js.name(t) }));
            const failed = try js.block();
            try js.@"return"(failed, try js.name(d));
            try js.@"if"(body, try js.member(try js.name(d), "issues"), failed, null);
            try cx.programDataBind(body, try js.member(try js.name(d), "value"));
            break :blk t;
        } else null;
        // An application's `init` is handed its route's `Url`, made from the
        // project's origin and base (`prerender.md` §7.3), and the key.
        const init = if (pg.p.constructor == 3)
            try cx.programStart(body, &.{
                try js.call(try js.name(try cx.runtime("routeUrl")), &.{ try js.string(cx.build.address), try js.name(route) }),
                try js.call(try js.name(try cx.runtime("navigationKey")), &.{}),
            })
        else
            try cx.programInit(body);
        const first_model = if (pg.p.constructor >= 1) try js.member(init, "a") else init;
        pg.model = try cx.fresh("model");
        if (cx.programModelCell()) {
            pg.cell = try cx.fresh("cell");
            try js.constant(body, pg.cell.?, try js.array(&.{first_model}));
        } else try js.let(body, pg.model, first_model);
        // A document's page has its title too (`prerender.md` §7.5), and the
        // render function gives `[html, title]`.
        const title: ?m.Name = if (pg.p.constructor >= 2) try cx.fresh("title") else null;
        if (title) |t| try js.constant(body, t, try cx.programField(body, .title, try pg.modelRef()));
        try cx.programViewEnter(body, try pg.modelRef());
        var r: Render = .{ .pg = pg, .out = try cx.fresh("html"), .route = route };
        try r.unit(body, title);
        cx.programViewLeave();
        if (text) |t| return js.arrow(&.{ route, t }, body);
        return js.arrow(&.{route}, body);
    }

    /// What a key's handler is refused by (§8.7): an `update` computed when
    /// the page runs has no arm to write (class 3); a `*` key, by its kind
    /// (§5, the owner, 2026-10-17) — lost precision is a limit of the
    /// compiler (class 4), an inferred whole write of a record of several
    /// fields the language rule (class 3), and a model of one value is
    /// written exactly and accepted, every binding called.
    fn refuseKey(pg: *Page, key: m.Program.Key) m.Error!void {
        const cx = pg.cx;
        if (pg.p.update == .computed) return cx.programReport(.update, .program_shape,
            \\This program's `update` is a value computed when the page runs, so `browser-inline`
            \\cannot write each message's arm into the handler of its key: a handler is the arm itself,
            \\with no message made (`docs/design/browser-inline.md` §8.7; §5, class 3). Name a function
            \\of the program's modules as `update`, or write a lambda whose body chooses the arm.
        );
        // A key the depth limit or the rounds of a recursive function cut
        // (`Program.Key.cap`): what it writes below the cut is not known
        // (§8.7, class 4) until the pass folds paths precisely (#286).
        if (!key.star and (key.cap == .depth or key.cap == .rounds)) {
            const spelled_ = if (key.spelled.len != 0) key.spelled else key.name;
            const where = if (key.cap == .depth) "at its depth limit, 8 steps below the model" else "where a recursive function needs more than the pass's 4 rounds";
            const fix = if (key.cap == .depth) "a model nested less deeply builds here" else "a function that recurses over a smaller structure builds here";
            return cx.programReport(.update, .not_implemented, try std.fmt.allocPrint(cx.arena,
                \\A limit of the compiler: the write-set pass cut what key `{s}` writes {s}, so it cannot
                \\say which bindings those writes reach (`docs/design/browser-inline.md` §8.7; §5, class 4).
                \\The program is valid: it builds with `--platform=browser-tea`, and {s}.
            , .{ spelled_, where, fix }));
        }
        if (!key.star) return;
        // The key as the program spells it: `Run`. A key of no steps whose
        // message type the pass does not know (an `update` with no
        // annotation) is the program's one key, never `(any)`.
        const spelled = if (key.spelled.len != 0) key.spelled else key.name;
        const name = if (std.mem.eql(u8, spelled, "(any)"))
            "every message of the program"
        else
            try std.fmt.allocPrint(cx.arena, "key `{s}`", .{spelled});
        switch (key.star_kind) {
            // It opens the sentence: `Key …`, `Every message …`.
            .whole_record => return cx.programReport(.update, .program_shape, try std.fmt.allocPrint(cx.arena,
                \\{s} writes the whole model, a record of several fields, in one value, which hides
                \\which of its fields changed, so no binding of the page can be chosen for it:
                \\`browser-inline` writes only the bindings a key's writes reach, and never checks the
                \\whole page again (`docs/design/browser-inline.md` §8.7; §5, class 3). Write the fields
                \\the arm changes, as a record update of the model — `{{ model | field = … }}` — or, for
                \\a replacement of the whole model, a declared `replace` once the language has one.
            , .{try capital(cx.arena, name)})),
            .precision => {
                const lost = key.lost orelse return cx.programReport(.update, .not_implemented, try std.fmt.allocPrint(cx.arena,
                    \\A limit of the compiler: the write-set pass lost track of what {s} writes{s}, and
                    \\says it writes the whole model, so it cannot tell which of the model's fields change
                    \\(`docs/design/browser-inline.md` §8.7; §5, class 4). The program is valid: it builds
                    \\with `--platform=browser-tea`.
                , .{ name, capOf(key.cap) }));
                const what = if (lost.text.len != 0) try std.fmt.allocPrint(cx.arena, "`{s}`", .{lost.text}) else try std.fmt.allocPrint(cx.arena, "the expression at {s}", .{lost.where});
                // The function called, as the text spells it: its first word.
                const callee = lost.text[0 .. std.mem.indexOfAny(u8, lost.text, " (") orelse lost.text.len];
                const why = switch (lost.kind) {
                    .parameter => try std.fmt.allocPrint(cx.arena, "a call of `{s}`, a function-valued parameter, which the compiler cannot see through", .{callee}),
                    .local => try std.fmt.allocPrint(cx.arena, "a call of `{s}`, a function a pattern or a `let` binds, which the compiler knows only as a value", .{callee}),
                    .record => "a record of a type the compiler cannot read",
                    else => "a call whose result the compiler cannot see into",
                };
                if (key.cap != .none) return cx.programReportAt(lost.site, .not_implemented, try std.fmt.allocPrint(cx.arena,
                    \\A limit of the compiler: the write-set pass stopped following what {s} writes at
                    \\{s}{s}, so it cannot tell which of the model's fields change
                    \\(`docs/design/browser-inline.md` §8.7; §5, class 4). Write the arm with less nesting, or
                    \\build this program with `--platform=browser-tea`, where the program is valid.
                , .{ name, what, capOf(key.cap) }));
                const more = if (lost.more == 0) "" else try std.fmt.allocPrint(cx.arena, " (and {d} more place{s})", .{ lost.more, if (lost.more == 1) "" else "s" });
                return cx.programReportAt(lost.site, .not_implemented, try std.fmt.allocPrint(cx.arena,
                    \\A limit of the compiler: {s} writes the whole model with {s}{s}, {s}, so the
                    \\compiler cannot tell which of the model's fields change (`docs/design/browser-inline.md`
                    \\§8.7; §5, class 4). Write each change in `update` itself — a message per change, each
                    \\writing its fields — and the bindings it reaches follow. The program is valid: it
                    \\builds with `--platform=browser-tea`.
                , .{ name, what, more, why }));
            },
            // A model of one value: its one write is the model, exactly.
            .single_value => {},
            // A key the write-set pass never made: the program is one it did
            // not analyse. Never passed on, so no handler is written without
            // its pass (`browser-inline.md` §8.3, amended 2026-10-19).
            .none, _ => return cx.programReport(.update, .not_implemented,
                \\A limit of the compiler: the write-set pass did not analyse this program, so
                \\`browser-inline` cannot say which bindings a message reaches
                \\(`docs/design/browser-inline.md` §8.3; §5, class 4). The program is valid: it builds
                \\with `--platform=browser-tea`.
            ),
        }
    }

    /// The cap of the write-set pass that cut a key's writes, in words, for
    /// a diagnostic: empty when none did.
    fn capOf(cap: m.Program.Key.Cap) []const u8 {
        return switch (cap) {
            .depth => " past the write-set pass's depth limit of 8 steps below the model",
            .alternatives => " past the write-set pass's limit of 16 alternatives",
            .instantiation => " where calls of functions nest past the write-set pass's limit of 8",
            .rounds => " where a recursive function needs more rounds than the write-set pass's 4",
            .size => " past the write-set pass's term size limit",
            .work => " past the write-set pass's work limit",
            .leaves => " past the write-set pass's 256 message keys",
            else => "",
        };
    }

    /// Key `k`'s handler's name, made the first time it is asked for.
    fn handler(pg: *Page, k: u32) m.Error!m.Name {
        if (pg.handlers[k]) |h| return h;
        const keys = pg.cx.programKeys();
        const h = try pg.cx.fresh(try std.fmt.allocPrint(pg.a(), "on{s}", .{handlerHint(keys[k].name)}));
        pg.handlers[k] = h;
        return h;
    }

    /// Whether key `key`'s command — or `init`'s, for null — runs; one that
    /// may suspend also runs; one the pass could not read is refused.
    fn command(pg: *Page, key: ?u32) m.Error!bool {
        const cx = pg.cx;
        switch (cx.programCommand(key)) {
            .none => return false,
            .runs, .suspends => return true,
            else => return cx.programReport(if (key == null) .init else .update, .not_implemented,
                \\A limit of the compiler: the write-set pass could not read this command as
                \\`Cmd.none`, `Cmd.batch` or `Cmd.perform` (`docs/design/browser-inline.md` §4; §5,
                \\class 4). Write the command where `update` returns it, with those three.
            ),
        }
    }

    /// The runs of two roots or more mounted through one table (§8.4,
    /// amended 2026-10-24): pieces next to each other in placement order,
    /// each with a factory that takes no handler and fills its own row, the
    /// rows next to each other in the same order. Any other root is called
    /// as it is.
    fn rootRuns(pg: *Page) m.Error![]const Run {
        const pieces = pg.pieces.items;
        if (pieces.len < 2) return &.{};
        const places = try pg.a().alloc(?Place, pieces.len);
        @memset(places, null);
        var count: u32 = 0;
        const top = pg.top_nodes[0];
        if (top.kind != .element or !placesOf(top.children, null, &count, pieces, places)) @memset(places, null);
        var runs: std.ArrayList(Run) = .empty;
        var i: u32 = 0;
        while (i < pieces.len) {
            const row = pg.runRow(i) orelse {
                i += 1;
                continue;
            };
            var len: u32 = 1;
            while (i + len < pieces.len) : (len += 1) {
                const next = pg.runRow(i + len) orelse break;
                if (next != row + len) break;
            }
            if (len >= 2) {
                // The roots' top elements are element children of one
                // element, next to each other in order, or each is read by
                // its place.
                const first = places[i];
                const children = first != null and for (0..len) |k| {
                    const p = places[i + k] orelse break false;
                    if (p.parent != first.?.parent or p.at != first.?.at + k) break false;
                } else true;
                try runs.append(pg.a(), .{
                    .start = i,
                    .len = len,
                    .row = row,
                    .elements = if (children) .{ .children = .{ .parent = first.?.parent, .from = first.?.at } } else .places,
                });
            }
            i += len;
        }
        return runs.items;
    }

    /// Piece `i`'s own row, when its root can be one of a run's.
    fn runRow(pg: *Page, i: u32) ?u32 {
        const u = pg.pieces.items[i];
        if (u.data.root == null or !u.data.own_row or u.data.handlers.len != 0) return null;
        return pg.cx.programRootRow(u.node);
    }

    /// The one descendant the page's code refers to, when it is one.
    fn onlyTarget(pg: *Page) ?u32 {
        if (pg.pieces.items.len != 0) return null;
        var only: ?u32 = null;
        for (pg.writes.items) |w| if (w.target) |t| {
            if (only != null and only.? != t) return null;
            only = t;
        };
        for (pg.events.items) |ev| if (ev.target) |t| {
            if (only != null and only.? != t) return null;
            only = t;
        };
        for (pg.fors.items) |f| if (f.end) |t| {
            if (only != null and only.? != t) return null;
            only = t;
        };
        return only;
    }

    /// The element at `target`: the top node, or its descendant by place.
    fn ref(pg: *Page, target: ?u32) m.Error!m.Expr {
        const js = pg.cx.js;
        if (pg.hydrating) return js.index(try js.name(pg.elements.?), try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{if (target) |t| t + 1 else 0})));
        const t = target orelse return js.name(pg.node.?);
        if (pg.single) return js.name(pg.elements.?);
        return js.index(try js.name(pg.elements.?), try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{t})));
    }

    // ---- Binding functions --------------------------------------------

    /// A helper call is not an arm; context zero is the view itself.
    /// Every actual enclosing arm has a when write and its own anchor.
    /// The anchor is in place exactly while that arm is hidden, even in
    /// a detached mount. Require all enclosing arms to be selected.
    fn armActivity(pg: *Page, ctx: u32) m.Error!?m.Expr {
        const js = pg.cx.js;
        var active: ?m.Expr = null;
        var at: ?u32 = ctx;
        while (at) |c| : (at = pg.ctxs.items[c].parent) {
            const context = pg.ctxs.items[c];
            if (context.kind != .arm or context.parent == null) continue;
            // Markup indices repeat across helper calls; the parent context
            // identifies the source occurrence whose anchor this arm uses.
            const target = for (pg.writes.items) |w| {
                if (w.what != .when) continue;
                const arm = w.what.when;
                if (w.ctx == context.parent.? and arm.node == context.node and arm.shown == context.arm) break w.target;
            } else unreachable;
            const anchor = try js.member(try pg.ref(target), "$a");
            const selected = try js.unary(.not, try js.member(anchor, "parentNode"));
            // Outermost first: a hidden guarded parent may never have
            // initialized an inner arm's anchor.
            active = if (active) |inner| try js.binary(.logical_and, selected, inner) else selected;
        }
        return active;
    }

    /// The runtime's `on` for a listener with neither flag and no captured
    /// arguments: `on(node, f)`, the event's name left out for a click; or,
    /// inside eager arms, `onArm(node, f, kind, arms)` with the arms'
    /// elements outermost first, which `onArm` asks before the event enters
    /// the guard (§8.2, #466; the same test `armActivity` writes in place).
    /// A page with no handler in an arm never names `onArm` (#874).
    fn onCall(pg: *Page, node: m.Expr, f: m.Expr, kind: ?[]const u8, ctx: u32, read: ?m.Expr) m.Error!m.Expr {
        const js = pg.cx.js;
        const arms = try pg.armElements(ctx);
        if (arms.len == 0) {
            const on = try js.name(try pg.cx.runtime(if (pg.taking) "onTaken" else "on"));
            if (read) |rd| return js.call(on, &.{ node, f, if (kind) |k| try js.string(k) else try js.literal(.undefined), rd });
            if (kind) |k| return js.call(on, &.{ node, f, try js.string(k) });
            return js.call(on, &.{ node, f });
        }
        const on_arm = try js.name(try pg.cx.runtime(if (pg.taking) "onArmTaken" else "onArm"));
        const which = if (arms.len == 1) arms[0] else try js.array(arms);
        if (read) |rd| return js.call(on_arm, &.{ node, f, try js.string(kind orelse "click"), which, rd });
        return js.call(on_arm, &.{ node, f, try js.string(kind orelse "click"), which });
    }

    /// A listener written in place: `node.addEventListener(kind, f)`, or in
    /// the client of a prerendering build the runtime's `listen(node, kind,
    /// f)`, which notes it for the delivery of input made before the
    /// takeover (`prerender.md` §6.5, amended 2026-10-29).
    fn addListener(pg: *Page, node: m.Expr, kind: []const u8, f: m.Expr) m.Error!m.Expr {
        const js = pg.cx.js;
        if (pg.taking) return js.call(try js.name(try pg.cx.runtime("listen")), &.{ node, try js.string(kind), f });
        return js.call(try js.member(node, "addEventListener"), &.{ try js.string(kind), f });
    }

    /// The element of each eager arm around context `ctx`, outermost first:
    /// the element whose `when` anchor (`$a`) stands in its place while the
    /// arm is hidden (`armActivity`'s targets).
    fn armElements(pg: *Page, ctx: u32) m.Error![]const m.Expr {
        var inner_first: std.ArrayList(m.Expr) = .empty;
        var at: ?u32 = ctx;
        while (at) |c| : (at = pg.ctxs.items[c].parent) {
            const context = pg.ctxs.items[c];
            if (context.kind != .arm or context.parent == null) continue;
            const target = for (pg.writes.items) |w| {
                if (w.what != .when) continue;
                const arm = w.what.when;
                if (w.ctx == context.parent.? and arm.node == context.node and arm.shown == context.arm) break w.target;
            } else unreachable;
            try inner_first.append(pg.a(), try pg.ref(target));
        }
        std.mem.reverse(m.Expr, inner_first.items);
        return inner_first.items;
    }

    fn within(pg: *Page, ctx: u32, ancestor: u32) bool {
        var at: ?u32 = ctx;
        while (at) |c| : (at = pg.ctxs.items[c].parent) if (c == ancestor) return true;
        return false;
    }

    fn eventBindingFor(pg: *Page, ev: Event) m.Error!m.Expr {
        return pg.cx.js.member(try pg.ref(ev.target), try std.fmt.allocPrint(pg.a(), "$h{d}", .{ev.index}));
    }

    fn eventBinding(pg: *Page, ei: u32) m.Error!m.Expr {
        return pg.eventBindingFor(pg.events.items[ei]);
    }

    fn capturedArguments(pg: *Page, ei: u32, calls: []const CallArgs) m.Error!m.Expr {
        var args: std.ArrayList(m.Expr) = .empty;
        for (pg.events.items[ei].captures) |ctx| {
            const values = for (calls) |call| {
                if (call.ctx == ctx) break call.args;
            } else unreachable;
            try args.appendSlice(pg.a(), values);
        }
        return pg.cx.js.array(args.items);
    }

    fn writeReads(pg: *Page, w: Write, out: *std.ArrayList(m.Value.Index)) m.Error!void {
        switch (w.what) {
            .text => |parts| for (parts) |part| switch (part) {
                .value => |v| try out.append(pg.a(), v),
                else => {},
            },
            .prop => |x| switch (x.value) {
                .value => |v| try out.append(pg.a(), v),
                .text => {},
            },
            .when => |x| try out.append(pg.a(), pg.tree.hole(x.node).value),
            .observe => |n| try out.append(pg.a(), pg.tree.hole(n).value),
            .event => {},
            .rows => |i| try pg.forValues(pg.fors.items[i].node, out),
        }
    }

    fn unsafeLets(pg: *Page, ctx: u32, values: []const m.Value.Index) m.Error!void {
        var at: ?u32 = ctx;
        while (at) |c| : (at = pg.ctxs.items[c].parent) {
            const r = pg.ctxs.items[c].root;
            const lets = pg.tree.root(r).lets;
            for (try pg.neededLets(r, values), 0..) |needed, k| {
                if (needed and !pg.cx.valuePureTotal(lets.at(@intCast(k)))) pg.unsafe_ctx[c] = true;
            }
        }
    }

    /// Only pure, total work may be eager. A guarded arm's bindings also
    /// read its selector: a reveal must compute current values even when
    /// only the selector changed since the last hidden data update.
    fn guardGroups(pg: *Page) m.Error!void {
        pg.unsafe_ctx = try pg.a().alloc(bool, pg.ctxs.items.len);
        pg.guarded_ctx = try pg.a().alloc(bool, pg.ctxs.items.len);
        @memset(pg.unsafe_ctx, false);
        @memset(pg.guarded_ctx, false);
        for (pg.writes.items) |w| {
            var reads: std.ArrayList(m.Value.Index) = .empty;
            try pg.writeReads(w, &reads);
            for (reads.items) |v| if (!pg.cx.valuePureTotal(v)) {
                pg.unsafe_ctx[w.ctx] = true;
            };
            // A retained event binding exists only in its selected arm,
            // including an arm inside the helper that supplied its values.
            if (w.what == .event) pg.unsafe_ctx[w.ctx] = true;
            try pg.unsafeLets(w.ctx, reads.items);
        }
        for (pg.ctxs.items, 0..) |c, ci| {
            if (c.kind != .call) continue;
            const call = pg.tree.hole(c.node).call orelse continue;
            var args: std.ArrayList(m.Value.Index) = .empty;
            for (0..call.args.len) |i| {
                const v = call.args.at(@intCast(i));
                try args.append(pg.a(), v);
                if (!pg.cx.valuePureTotal(v)) pg.unsafe_ctx[ci] = true;
            }
            try pg.unsafeLets(c.parent.?, args.items);
        }
        const below = try pg.a().dupe(bool, pg.unsafe_ctx);
        var ci = pg.ctxs.items.len;
        while (ci > 0) {
            ci -= 1;
            const c = pg.ctxs.items[ci];
            if (c.parent) |parent| {
                if (below[ci]) {
                    below[parent] = true;
                    if (c.kind == .arm) pg.guarded_ctx[ci] = true;
                }
            }
        }
        for (pg.writes.items) |*w| {
            var at: ?u32 = w.ctx;
            var selector_group: ?u32 = null;
            while (at) |c| : (at = pg.ctxs.items[c].parent) {
                if (pg.guarded_ctx[c]) selector_group = pg.ctxs.items[c].group;
            }
            // A branch's group includes its selector and all arm reads.
            // Keep its guarded effects and visibility in one preparation,
            // so a later throw cannot follow an earlier visibility write.
            var groups: std.ArrayList(u32) = .empty;
            if (selector_group) |g| {
                try groups.append(pg.a(), g);
            } else try groups.appendSlice(pg.a(), w.groups);
            // Complete argument reads belong to every binding that enters
            // an effectful helper call, including a guarded descendant.
            at = w.ctx;
            while (at) |c| : (at = pg.ctxs.items[c].parent) {
                const ctx = pg.ctxs.items[c];
                if (ctx.kind != .call) continue;
                try groups.appendSlice(pg.a(), ctx.entry_groups);
            }
            w.groups = try sorted(pg.a(), groups.items);
        }
        // One preflight owns a guarded arm, its visibility write and all
        // descendant argument evaluations. Nested/alternative guards and
        // retained captures can overlap; close their cohorts before taking
        // the union of their read groups, never split one again afterwards.
        const Cohort = struct {
            fn representative(parents: []u32, index: u32) u32 {
                var at = index;
                while (parents[at] != at) at = parents[at];
                return at;
            }
            fn unite(parents: []u32, left: u32, right: u32) void {
                const x = representative(parents, left);
                const y = representative(parents, right);
                parents[@max(x, y)] = @min(x, y);
            }
        };
        const parents = try pg.a().alloc(u32, pg.writes.items.len);
        for (parents, 0..) |*parent, wi| parent.* = @intCast(wi);
        for (pg.ctxs.items, 0..) |context, ci_index| {
            if (!pg.guarded_ctx[ci_index]) continue;
            const guarded: u32 = @intCast(ci_index);
            var first: ?u32 = null;
            for (pg.writes.items, 0..) |w, wi_| {
                const visibility = w.ctx == context.parent and w.what == .when and w.what.when.node == context.node;
                if (!pg.within(w.ctx, guarded) and !visibility) continue;
                const wi: u32 = @intCast(wi_);
                if (first) |earlier| Cohort.unite(parents, earlier, wi) else first = wi;
            }
        }
        const additions = try pg.a().alloc(std.ArrayList(u32), pg.writes.items.len);
        @memset(additions, .empty);
        for (pg.events.items) |ev| for (ev.captures) |capture| {
            var first: ?u32 = null;
            for (pg.writes.items, 0..) |w, wi_| {
                if (!pg.within(w.ctx, capture)) continue;
                const wi: u32 = @intCast(wi_);
                if (first) |earlier| Cohort.unite(parents, earlier, wi) else first = wi;
            }
            if (first) |wi| try additions[wi].append(pg.a(), pg.ctxs.items[capture].group.?);
        };
        const groups = try pg.a().alloc(std.ArrayList(u32), pg.writes.items.len);
        @memset(groups, .empty);
        for (pg.writes.items, 0..) |w, wi| {
            const cohort = Cohort.representative(parents, @intCast(wi));
            try groups[cohort].appendSlice(pg.a(), w.groups);
            try groups[cohort].appendSlice(pg.a(), additions[wi].items);
        }
        for (groups) |*set| set.items = @constCast(try sorted(pg.a(), set.items));
        for (pg.writes.items, 0..) |*w, wi| w.groups = groups[Cohort.representative(parents, @intCast(wi))].items;
    }

    fn prepares(pg: *Page, f: *const Function) bool {
        if (f.writes.items.len == 0) return false;
        const first = pg.writes.items[f.writes.items[0]].ctx;
        for (f.writes.items) |wi| {
            if (pg.writes.items[wi].what == .event) return true;
            var at: ?u32 = pg.writes.items[wi].ctx;
            while (at) |c| : (at = pg.ctxs.items[c].parent) {
                if (pg.guarded_ctx[c]) return true;
                if (!pg.unsafe_ctx[c]) continue;
                var before: ?u32 = first;
                const earlier = while (before) |b| : (before = pg.ctxs.items[b].parent) {
                    if (b == c) break true;
                } else false;
                if (!earlier) return true;
            }
        }
        return false;
    }

    /// The writes grouped by their sets of read sets, one function each, in
    /// the order of their first write: the page's document order.
    fn group(pg: *Page) m.Error!void {
        var by: std.StringHashMapUnmanaged(u32) = .empty;
        for (pg.writes.items, 0..) |w, i| {
            const key = std.mem.sliceAsBytes(w.groups);
            const slot = try by.getOrPut(pg.a(), key);
            if (!slot.found_existing) {
                slot.value_ptr.* = @intCast(pg.functions.items.len);
                try pg.functions.append(pg.a(), .{ .groups = w.groups });
            }
            const f = &pg.functions.items[slot.value_ptr.*];
            try f.writes.append(pg.a(), @intCast(i));
        }
    }

    /// Enter context `ctx` for evaluation, outermost first: the `view` with
    /// the model, then each eager arm. Returns how many arms were entered.
    const CallArgs = struct { ctx: u32, args: []const m.Expr };

    fn enter(pg: *Page, blk: m.Block, ctx: u32, saved: ?*std.ArrayList(CallArgs), reads: []const m.Value.Index) m.Error!u32 {
        var chain: std.ArrayList(u32) = .empty;
        var at: ?u32 = ctx;
        while (at) |c| : (at = pg.ctxs.items[c].parent) try chain.insert(pg.a(), 0, c);
        if (pg.piece) {
            try pg.cx.pieceViewEnter(blk, try pg.viewArgs());
        } else try pg.cx.programViewEnter(blk, try pg.modelRef());
        // Each level's `let`s that `reads`, or a call's arguments, read,
        // bound as soon as the level is entered, in its own declaration: an
        // argument of a deeper call may read them (D-d; §8.2, amended
        // 2026-11-23).
        try pg.bindLets(blk, pg.ctxs.items[0].root, try pg.levelValues(ctx, reads, 0));
        for (chain.items[1..]) |c| {
            const x = pg.ctxs.items[c];
            switch (x.kind) {
                .arm => {
                    try pg.cx.programBranchEager(x.node, x.arm);
                    try pg.bindLets(blk, x.root, try pg.levelValues(ctx, reads, c));
                },
                .call => {
                    // A binding function may enter a helper again through a
                    // nested arm. Rebind its parameters each time, but evaluate
                    // effectful arguments only at the first entry of this call
                    // context. Sibling calls have distinct context IDs.
                    const cached: ?[]const m.Expr = if (saved) |entries| for (entries.items) |entry| {
                        if (entry.ctx == c) break entry.args;
                    } else null else null;
                    const args = cached orelse args: {
                        var unsafe = false;
                        // The call's arguments are values of the enclosing root.
                        if (pg.tree.hole(x.node).call) |call| {
                            const vs = try pg.a().alloc(m.Value.Index, call.args.len);
                            for (vs, 0..) |*v, i| {
                                v.* = call.args.at(@intCast(i));
                                unsafe = unsafe or !pg.cx.valuePureTotal(v.*);
                            }
                            try pg.cx.rootValues(blk, pg.ctxs.items[x.parent.?].root, vs);
                        }
                        const evaluated = try pg.cx.programInlineArgs(blk, x.node);
                        if (saved) |entries| if (unsafe) {
                            const bound = try pg.a().alloc(m.Expr, evaluated.len);
                            for (evaluated, bound) |value, *name| {
                                const n = try pg.cx.fresh("arg");
                                try pg.cx.js.constant(blk, n, value);
                                name.* = try pg.cx.js.name(n);
                            }
                            try entries.append(pg.a(), .{ .ctx = c, .args = bound });
                            break :args bound;
                        };
                        break :args evaluated;
                    };
                    try pg.cx.programInlineEnter(blk, x.node, args, false);
                    try pg.bindLets(blk, x.root, try pg.levelValues(ctx, reads, c));
                },
            }
        }
        return @intCast(chain.items.len - 1);
    }

    /// The roots of context `ctx` and every context around it, outermost
    /// first: each has `let`s a binding of `ctx` may read (D-d), a view
    /// helper's among them (§8.4).
    fn chainRoots(pg: *Page, ctx: u32) m.Error![]const m.Root.Index {
        var out: std.ArrayList(m.Root.Index) = .empty;
        var at: ?u32 = ctx;
        while (at) |c| : (at = pg.ctxs.items[c].parent) try out.insert(pg.a(), 0, pg.ctxs.items[c].root);
        return out.items;
    }

    /// The helper call whose declaration `ctx`'s values are written in: the
    /// nearest call context on its path, itself included; null for the
    /// unit's own (the `view`'s, or a piece's function's). An arm is written
    /// in its branch's declaration.
    fn declOf(pg: *const Page, ctx: u32) ?u32 {
        var at: ?u32 = ctx;
        while (at) |c| : (at = pg.ctxs.items[c].parent) {
            if (c != 0 and pg.ctxs.items[c].kind == .call) return c;
        }
        return null;
    }

    /// Of `reads`, the values of context `ctx`, and the arguments of the
    /// calls on its path, those written in the declaration of `level`, a
    /// context on that path: what may read `level`'s root's `let`s. A value
    /// of another declaration names its locals by other numbers, so testing
    /// it against this root's `let`s would match a local it does not read.
    fn levelValues(pg: *Page, ctx: u32, reads: []const m.Value.Index, level: u32) m.Error![]const m.Value.Index {
        const decl = pg.declOf(level);
        var out: std.ArrayList(m.Value.Index) = .empty;
        if (pg.declOf(ctx) == decl) try out.appendSlice(pg.a(), reads);
        var at: ?u32 = ctx;
        while (at) |c| : (at = pg.ctxs.items[c].parent) {
            const x = pg.ctxs.items[c];
            if (c == 0 or x.kind != .call or pg.declOf(x.parent.?) != decl) continue;
            const call = pg.tree.hole(x.node).call orelse continue;
            for (0..call.args.len) |i| try out.append(pg.a(), call.args.at(@intCast(i)));
        }
        return out.items;
    }

    fn leave(pg: *Page, arms: u32) void {
        for (0..arms) |_| pg.cx.programInlineLeave();
        pg.cx.programViewLeave();
    }

    /// The arguments of a piece's function, each read from its holder
    /// (`cx.pieceRootArg`): what `pieceViewEnter` binds its parameters to.
    fn viewArgs(pg: *Page) m.Error![]const m.Expr {
        const args = try pg.a().alloc(m.Expr, pg.holders.len);
        for (args, pg.holders, 0..) |*x, h, k| x.* = try pg.cx.pieceRootArg(@intCast(k), try pg.cx.js.name(h));
        return args;
    }

    /// The program's model: its cell's one slot when it has one
    /// (`cx.programModelCell`), else its local.
    fn modelRef(pg: *Page) m.Error!m.Expr {
        const js = pg.cx.js;
        if (pg.cell) |c| return js.index(try js.name(c), try js.number("0"));
        return js.name(pg.model);
    }

    /// Bucket `ref` of the program's table: this piece's own row's, or the
    /// table's, written `row[b]` or `table[r][b]`.
    fn bucketExpr(pg: *Page, at: m.Program.BucketRef) m.Error!m.Expr {
        const js = pg.cx.js;
        const b = try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{at.bucket}));
        if (pg.piece and pg.row != null and pg.row.? == at.row) {
            pg.used_own = true;
            return js.index(try js.name(pg.own.?), b);
        }
        pg.used_table = true;
        // A bucket exists only in a table the program made: no plan names one
        // for a program with no row.
        std.debug.assert(pg.piece or pg.cx.programRows().len != 0);
        const row = try js.index(try js.name(pg.table.?), try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{at.row})));
        return js.index(row, b);
    }

    /// `refs`, sorted and each once, as one expression when they are every
    /// bucket of one row — the row itself — or every bucket of every row of
    /// the program's table — `table.flat()`; null otherwise.
    fn wholeRows(pg: *Page, refs: []const m.Program.BucketRef) m.Error!?m.Expr {
        const js = pg.cx.js;
        const rows = pg.cx.programRows();
        const first = refs[0].row;
        if (refs[refs.len - 1].row == first and refs.len == rows[first]) {
            if (pg.piece and pg.row != null and pg.row.? == first) {
                pg.used_own = true;
                return try js.name(pg.own.?);
            }
            if (pg.table == null) return null;
            pg.used_table = true;
            return try js.index(try js.name(pg.table.?), try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{first})));
        }
        var total: usize = 0;
        for (rows) |n| total += n;
        if (refs.len != total or pg.table == null) return null;
        pg.used_table = true;
        return try js.call(try js.member(try js.name(pg.table.?), "flat"), &.{});
    }

    /// The buckets binding function `f` reads: those of each read set it is
    /// in, sorted, each once.
    fn functionBuckets(pg: *Page, f: *const Function) m.Error![]const m.Program.BucketRef {
        var out: std.ArrayList(m.Program.BucketRef) = .empty;
        for (f.groups) |g| try addRefs(pg.a(), &out, pg.cx.groupBuckets(g));
        std.mem.sort(m.Program.BucketRef, out.items, {}, refLess);
        return out.items;
    }

    /// Binding function `f` made a binding entry into `blk` (§8.4, amended
    /// 2026-10-22): the runtime's `entry` gives it its ordinal and adds it to
    /// each bucket of what it reads. One that reads no bucket runs in the
    /// first pass alone.
    fn writeEntry(pg: *Page, blk: m.Block, f: *const Function) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        const fbody = try js.block();
        try pg.writeFunction(fbody, f);
        const refs = try pg.functionBuckets(f);
        // One bucket, or an array of the buckets: `entry` adds `f` to each.
        const buckets = if (refs.len == 0) try js.array(&.{}) else if (refs.len == 1) try pg.bucketExpr(refs[0]) else array: {
            const list = try pg.a().alloc(m.Expr, refs.len);
            for (list, refs) |*x, b| x.* = try pg.bucketExpr(b);
            break :array try js.array(list);
        };
        try js.expression(blk, try js.call(try js.name(try cx.runtime("entry")), &.{ try js.arrow(&.{}, fbody), buckets }));
    }

    /// A write pass of `refs` into `blk`: the runtime's `pass` of one
    /// bucket, `passes` of several, nothing for none.
    fn writePass(pg: *Page, blk: m.Block, refs: []const m.Program.BucketRef) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        if (refs.len == 0) return;
        if (refs.len == 1) return js.expression(blk, try js.call(try js.name(try cx.runtime("pass")), &.{try pg.bucketExpr(refs[0])}));
        // Every bucket of one row is that row, an array of buckets, and every
        // bucket of every row is the table's rows flattened (§8.4, amended
        // 2026-10-23, #896): the same buckets, without a list of them all.
        if (try pg.wholeRows(refs)) |whole| return js.expression(blk, try js.call(try js.name(try cx.runtime("passes")), &.{whole}));
        const list = try pg.a().alloc(m.Expr, refs.len);
        for (list, refs) |*x, b| x.* = try pg.bucketExpr(b);
        try js.expression(blk, try js.call(try js.name(try cx.runtime("passes")), &.{try js.array(list)}));
    }

    /// Root `r`'s `let`s that `values` read, directly or through a later
    /// `let`, evaluated into `blk` and read under their names (D-d).
    fn bindLets(pg: *Page, blk: m.Block, r: m.Root.Index, values: []const m.Value.Index) m.Error!void {
        const cx = pg.cx;
        const lets = pg.tree.root(r).lets;
        const needed = try pg.neededLets(r, values);
        for (0..lets.len) |kk| {
            if (!needed[kk]) continue;
            if (pg.memoOf(r, @intCast(kk))) {
                try cx.bindLet(r, @intCast(kk), pg.memo[kk].?);
                continue;
            }
            const lv = lets.at(@intCast(kk));
            try cx.rootValues(blk, r, &.{lv});
            const n = try cx.fresh("let");
            try cx.js.constant(blk, n, try cx.value(lv));
            try cx.bindLet(r, @intCast(kk), n);
        }
    }

    /// Which of root `r`'s `let`s `values` read, directly or through a
    /// later `let`.
    fn neededLets(pg: *Page, r: m.Root.Index, values: []const m.Value.Index) m.Error![]bool {
        const cx = pg.cx;
        const lets = pg.tree.root(r).lets;
        const needed = try pg.a().alloc(bool, lets.len);
        @memset(needed, false);
        var k = lets.len;
        while (k > 0) {
            k -= 1;
            for (values) |v| if (cx.valueReadsLet(r, @intCast(k), v)) {
                needed[k] = true;
                break;
            };
            if (needed[k]) continue;
            // A memo node's `let` is read from its slot: what it reads is
            // its entry's to evaluate (§8.2, amended 2026-11-23).
            for (k + 1..lets.len) |j| if (needed[j] and !pg.memoOf(r, @intCast(j)) and cx.valueReadsLet(r, @intCast(k), lets.at(@intCast(j)))) {
                needed[k] = true;
                break;
            };
        }
        return needed;
    }

    /// What binding function `f` reads in context `ctx`: each `when`'s
    /// branch value, which picks its arm, then its writes' values, which
    /// are appended to `values` too.
    fn functionReads(pg: *Page, f: *const Function, ctx: u32, values: *std.ArrayList(m.Value.Index)) m.Error![]const m.Value.Index {
        var reads: std.ArrayList(m.Value.Index) = .empty;
        for (f.writes.items) |wi| {
            const w = pg.writes.items[wi];
            if (w.ctx != ctx) continue;
            switch (w.what) {
                .text => |parts| for (parts) |part| switch (part) {
                    .value => |v| try values.append(pg.a(), v),
                    else => {},
                },
                .prop => |x| switch (x.value) {
                    .value => |v| try values.append(pg.a(), v),
                    .text => {},
                },
                .event => {},
                .rows => |i| try pg.forValues(pg.fors.items[i].node, values),
                .when => |x| try reads.append(pg.a(), pg.tree.hole(x.node).value),
                .observe => |n| try reads.append(pg.a(), pg.tree.hole(n).value),
            }
        }
        try reads.appendSlice(pg.a(), values.items);
        return reads.items;
    }

    /// D-d, as built: a `let` is evaluated in each binding function that
    /// reads it, directly or through another `let`, so one that two
    /// functions read would run twice in a pass that calls both — a
    /// `Debug.log` in it would log twice. That is a memo node, S3's (§8.2).
    /// A view helper's argument that may have an effect (`valueSafe`) is
    /// evaluated by each binding function that enters the call's context,
    /// and by none when no write is in it: it must be exactly one, as a
    /// `let` must (`letsOnce`), or the effect runs another number of times
    /// than a pass of the program runs it (#436's review).
    fn argsOnce(pg: *Page) m.Error!void {
        for (pg.ctxs.items, 0..) |x, ci| {
            if (x.kind != .call) continue;
            const call = pg.tree.hole(x.node).call orelse continue;
            const safe = for (0..call.args.len) |i| {
                if (!pg.cx.valueSafe(call.args.at(@intCast(i)))) break false;
            } else true;
            if (safe) continue;
            var entering: u32 = 0;
            for (pg.functions.items) |*f| {
                var enters = false;
                for (f.writes.items) |wi| {
                    var at: ?u32 = pg.writes.items[wi].ctx;
                    while (at) |c| : (at = pg.ctxs.items[c].parent) {
                        if (c == ci) enters = true;
                    }
                }
                if (enters) entering += 1;
            }
            if (entering != 1) return limit(pg.cx, x.node, "an argument of this function call may have an effect, and `browser-inline` evaluates a call written in place in each binding function that reads it (§8.4); one that several functions read, or none, is a memo node, which slice S3 brings");
        }
    }

    /// Whether `let` `k` of root `r` is a memo node: the view root's, read
    /// from its slot (§8.2, amended 2026-11-23).
    fn memoOf(pg: *const Page, r: m.Root.Index, k: u32) bool {
        return !pg.piece and r == pg.index and k < pg.memo_mask.len and pg.memo_mask[k];
    }

    /// The view root's `let`s several binding functions read, directly or
    /// through another `let`, made memo nodes, and the view's statements:
    /// each an entry of its own before every other (§8.2, amended
    /// 2026-11-23). A `let` a memo node's value reads is read by that node
    /// too, so the set grows until no `let` outside it has two readers.
    fn memos(pg: *Page) m.Error!void {
        if (pg.piece) return;
        const cx = pg.cx;
        const js = cx.js;
        const r = pg.index;
        const lets = pg.tree.root(r).lets;
        pg.memo = try pg.a().alloc(?m.Name, lets.len);
        @memset(pg.memo, null);
        const mask = try pg.a().alloc(bool, lets.len);
        @memset(mask, false);
        pg.memo_mask = mask;
        // A `let` an event's handler value reads — or an argument of a call
        // the event is in — is a memo node whoever else reads it: the handler
        // takes the value the last pass computed, as the page shows it, and
        // evaluates nothing of the `let` at the event.
        for (pg.events.items) |ev| {
            if (ev.item.value.kind != .dynamic) continue;
            const vals = try pg.levelValues(ev.ctx, &.{ev.item.value.dynamic.?}, 0);
            for (mask, 0..) |*is, k| {
                for (vals) |v| if (cx.valueReadsLet(r, @intCast(k), v)) {
                    is.* = true;
                };
            }
        }
        const readers = try pg.a().alloc(u32, lets.len);
        // A reader is a context a binding function enters: one function that
        // writes in two contexts evaluates its `let`s once in each, so two
        // count. Only the values written in the `view`'s own declaration
        // read its `let`s (`levelValues`).
        while (lets.len != 0) {
            @memset(readers, 0);
            for (pg.functions.items) |*f| {
                var done: std.ArrayList(u32) = .empty;
                for (f.writes.items) |first| {
                    const ctx = pg.writes.items[first].ctx;
                    if (std.mem.indexOfScalar(u32, done.items, ctx) != null) continue;
                    try done.append(pg.a(), ctx);
                    var values: std.ArrayList(m.Value.Index) = .empty;
                    const reads = try pg.functionReads(f, ctx, &values);
                    for (try pg.neededLets(r, try pg.levelValues(ctx, reads, 0)), readers) |yes, *n| n.* += @intFromBool(yes);
                }
            }
            for (mask, 0..) |is, k| if (is) {
                for (try pg.neededLets(r, &.{lets.at(@intCast(k))}), readers) |yes, *n| n.* += @intFromBool(yes);
            };
            var grew = false;
            for (mask, readers) |*is, n| if (!is.* and n > 1) {
                is.* = true;
                grew = true;
            };
            if (!grew) break;
        }
        var front: std.ArrayList(Function) = .empty;
        if (pg.statements) |groups| try front.append(pg.a(), .{ .groups = try sorted(pg.a(), groups), .kind = .statements });
        for (mask, 0..) |is, k| if (is) {
            const facts = cx.programLet(r, @intCast(k));
            if (facts.group == std.math.maxInt(u32)) return limit(cx, pg.tree.root(r).node, "the write-set pass gave no read set for a `let` of this `view` that several binding functions read, and `browser-inline` computes such a `let` again when what it reads is written");
            const slot = try cx.fresh("memo");
            try js.let(pg.body, slot, null);
            pg.memo[k] = slot;
            try front.append(pg.a(), .{ .groups = try sorted(pg.a(), &.{facts.group}), .kind = .memo, .memo = @intCast(k) });
        };
        if (front.items.len == 0) return;
        try pg.functions.insertSlice(pg.a(), 0, front.items);
    }

    fn letsOnce(pg: *Page) m.Error!void {
        var seen: std.AutoHashMapUnmanaged(u64, u32) = .empty;
        for (pg.functions.items, 0..) |*f, fi| {
            var done: std.ArrayList(u32) = .empty;
            for (f.writes.items) |first| {
                const ctx = pg.writes.items[first].ctx;
                if (std.mem.indexOfScalar(u32, done.items, ctx) != null) continue;
                try done.append(pg.a(), ctx);
                var values: std.ArrayList(m.Value.Index) = .empty;
                const reads = try pg.functionReads(f, ctx, &values);
                var chain: std.ArrayList(u32) = .empty;
                var at: ?u32 = ctx;
                while (at) |c| : (at = pg.ctxs.items[c].parent) try chain.append(pg.a(), c);
                for (chain.items) |level| {
                    const r = pg.ctxs.items[level].root;
                    const needed = try pg.neededLets(r, try pg.levelValues(ctx, reads, level));
                    for (needed, 0..) |yes, k| {
                        if (!yes) continue;
                        if (pg.memoOf(r, @intCast(k))) continue;
                        const key = (@as(u64, @backingInt(r)) << 32) | k;
                        const gop = try seen.getOrPut(pg.a(), key);
                        if (gop.found_existing and gop.value_ptr.* != fi) return limit(pg.cx, pg.tree.root(r).node, "a `let` of this `view` is read by several binding functions, directly or through another `let`, and `browser-inline` computes a `let` in each function that reads it (D-d); one several read is a memo node, which slice S3 brings");
                        gop.value_ptr.* = @intCast(fi);
                    }
                }
            }
        }
    }

    const PreparedWrite = struct { value: m.Expr, selected: ?m.Name };
    const PreparedBranch = struct { ctx: u32, node: m.Node.Index, name: m.Name };

    /// Invocation-local preparation, before any DOM write. Contexts are
    /// entered once, in document order; a selected arm owns its effects.
    /// Only temporary names escape a guarded block, never memo state.
    const Preparation = struct {
        pg: *Page,
        f: *const Function,
        declarations: m.Block,
        first: []u32,
        writes: []?PreparedWrite,
        branches: std.ArrayList(PreparedBranch) = .empty,
        reads: std.ArrayList(m.Value.Index) = .empty,
        call_args: std.ArrayList(CallArgs) = .empty,

        fn temporary(p: *Preparation, hint: []const u8) m.Error!m.Name {
            const n = try p.pg.cx.fresh(hint);
            try p.pg.cx.js.let(p.declarations, n, null);
            return n;
        }

        fn branch(p: *Preparation, into: m.Block, ctx: u32, node: m.Node.Index) m.Error!m.Expr {
            const pg = p.pg;
            for (p.branches.items) |b| if (b.ctx == ctx and b.node == node) return pg.cx.js.name(b.name);
            const n = try p.temporary("arm");
            const value = try pg.cx.programBranchArm(into, node);
            try pg.cx.js.assign(into, try pg.cx.js.name(n), value);
            try p.branches.append(pg.a(), .{ .ctx = ctx, .node = node, .name = n });
            return pg.cx.js.name(n);
        }

        fn context(p: *Preparation, ctx: u32, into: m.Block, selected: ?m.Name) m.Error!void {
            const pg = p.pg;
            const cx = pg.cx;
            const js = cx.js;
            const r = pg.ctxs.items[ctx].root;
            // Only the values written in this context's declaration read its
            // root's `let`s (`levelValues`).
            const decl = pg.declOf(ctx);
            var vals: std.ArrayList(m.Value.Index) = .empty;
            for (p.f.writes.items) |wi| {
                if (pg.declOf(pg.writes.items[wi].ctx) == decl) try pg.writeReads(pg.writes.items[wi], &vals);
            }
            for (pg.ctxs.items, 0..) |x, ci| {
                if (ci == 0 or x.kind != .call or p.first[ci] == std.math.maxInt(u32) or pg.declOf(x.parent.?) != decl) continue;
                const call = pg.tree.hole(x.node).call orelse continue;
                for (0..call.args.len) |i| try vals.append(pg.a(), call.args.at(@intCast(i)));
            }
            try pg.bindLets(into, r, vals.items);
            // A context and a child can interleave in the document. Prepare
            // each write and each child's first write at its original place.
            for (p.f.writes.items) |wi| {
                for (pg.ctxs.items, 0..) |child, ci| {
                    if (child.parent != ctx or p.first[ci] != wi) continue;
                    switch (child.kind) {
                        .arm => {
                            var body = into;
                            var active = selected;
                            if (pg.guarded_ctx[ci]) {
                                const taken = try p.branch(into, ctx, child.node);
                                const n = try p.temporary("selected");
                                const chosen = if (child.arms > 2) try js.binary(.strict_eq, taken, try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{child.arm}))) else if (child.arm == 0) try js.unary(.not, taken) else taken;
                                try js.assign(into, try js.name(n), chosen);
                                body = try js.block();
                                active = n;
                            }
                            try cx.programBranchEager(child.node, child.arm);
                            defer cx.programInlineLeave();
                            try p.context(@intCast(ci), body, active);
                            if (pg.guarded_ctx[ci]) try js.@"if"(into, try js.name(active.?), body, null);
                        },
                        .call => {
                            if (pg.tree.hole(child.node).call) |call| {
                                const args = try pg.a().alloc(m.Value.Index, call.args.len);
                                for (args, 0..) |*v, i| v.* = call.args.at(@intCast(i));
                                try cx.rootValues(into, r, args);
                            }
                            const args = try cx.programInlineArgs(into, child.node);
                            try p.call_args.append(pg.a(), .{ .ctx = @intCast(ci), .args = args });
                            try cx.programInlineEnter(into, child.node, args, false);
                            defer cx.programInlineLeave();
                            try p.context(@intCast(ci), into, selected);
                        },
                    }
                }
                const w = pg.writes.items[wi];
                if (w.ctx != ctx) continue;
                const value = switch (w.what) {
                    .text => |parts| value: {
                        var values: std.ArrayList(m.Value.Index) = .empty;
                        for (parts) |part| switch (part) {
                            .value => |v| try values.append(pg.a(), v),
                            else => {},
                        };
                        try cx.rootValues(into, r, values.items);
                        const text = if (parts.len == 1 and parts[0] == .value)
                            try cx.value(parts[0].value)
                        else text: {
                            const tp = try pg.a().alloc(m.TemplatePart, parts.len);
                            for (tp, parts) |*t, part| t.* = switch (part) {
                                .text => |s| .{ .text = s },
                                .value => |v| .{ .expr = try cx.value(v) },
                            };
                            break :text try js.template(tp);
                        };
                        break :value if (w.string) text else try js.template(&.{.{ .expr = text }});
                    },
                    .prop => |x| switch (x.value) {
                        .value => |v| value: {
                            try cx.rootValues(into, r, &.{v});
                            break :value try cx.value(v);
                        },
                        .text => |t| try js.string(t),
                    },
                    .event => |ei| try pg.capturedArguments(ei, p.call_args.items),
                    .rows => |i| return later(cx, pg.fors.items[i].node, "a `For` whose binding prepares a guarded arm or a helper argument that may fail"),
                    .observe => |n| try p.branch(into, ctx, n),
                    .when => |x| value: {
                        const taken = try p.branch(into, ctx, x.node);
                        break :value if (x.arms > 2)
                            try js.binary(.strict_ne, taken, try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{x.shown})))
                        else if (x.shown == 0) taken else try js.unary(.not, taken);
                    },
                };
                const n = try p.temporary("value");
                try js.assign(into, try js.name(n), value);
                p.writes[wi] = .{ .value = try js.name(n), .selected = selected };
            }
        }
    };

    /// A scalar String class is an HTML attribute. Keep its binding compare
    /// and evaluate
    /// its target and desired value exactly once, including effectful helpers.
    /// A URL's desired value is `safeUrl(value)` (§10.5, amended 2026-11-05).
    fn writeStringAttribute(pg: *Page, blk: m.Block, target: m.Expr, attribute: []const u8, value: m.Expr, url: bool) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        const node = try cx.fresh("attributeNode");
        const desired = try cx.fresh("attributeValue");
        try js.constant(blk, node, target);
        try js.constant(blk, desired, if (url) try js.call(try js.name(try cx.runtime("safeUrl")), &.{value}) else value);
        const current = try js.call(try js.member(try js.name(node), "getAttribute"), &.{try js.string(attribute)});
        const changed = try js.binary(.strict_ne, current, try js.name(desired));
        const write = try js.block();
        try js.expression(write, try js.call(try js.member(try js.name(node), "setAttribute"), &.{ try js.string(attribute), try js.name(desired) }));
        try js.@"if"(blk, changed, write, null);
    }

    fn writePrepared(pg: *Page, blk: m.Block, f: *const Function) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        const first = try pg.a().alloc(u32, pg.ctxs.items.len);
        @memset(first, std.math.maxInt(u32));
        const prepared = try pg.a().alloc(?PreparedWrite, pg.writes.items.len);
        @memset(prepared, null);
        var p: Preparation = .{ .pg = pg, .f = f, .declarations = blk, .first = first, .writes = prepared };
        for (f.writes.items) |wi| {
            const w = pg.writes.items[wi];
            first[w.ctx] = @min(first[w.ctx], wi);
            try pg.writeReads(w, &p.reads);
        }
        var ci = pg.ctxs.items.len;
        while (ci > 0) {
            ci -= 1;
            if (pg.ctxs.items[ci].parent) |parent| first[parent] = @min(first[parent], first[ci]);
            if (first[ci] == std.math.maxInt(u32) or pg.ctxs.items[ci].kind != .call) continue;
            if (pg.tree.hole(pg.ctxs.items[ci].node).call) |call| {
                for (0..call.args.len) |i| try p.reads.append(pg.a(), call.args.at(@intCast(i)));
            }
        }
        const body = try js.block();
        if (pg.piece) {
            try cx.pieceViewEnter(body, try pg.viewArgs());
        } else try cx.programViewEnter(body, try pg.modelRef());
        try p.context(0, body, null);
        cx.programViewLeave();
        try js.nested(blk, body);
        // All selected values succeeded. Only now may visibility or text
        // change, including writes in earlier sibling contexts.
        for (f.writes.items) |wi| {
            const w = pg.writes.items[wi];
            const ready = prepared[wi].?;
            const into = if (ready.selected != null) try js.block() else blk;
            const node = try pg.ref(w.target);
            switch (w.what) {
                .event => |ei| {
                    try js.assign(into, try pg.eventBinding(ei), ready.value);
                    if (ready.selected) |n| {
                        const cleared = try js.block();
                        try js.assign(cleared, try pg.eventBinding(ei), try js.literal(.undefined));
                        try js.@"if"(blk, try js.name(n), into, cleared);
                        continue;
                    }
                },
                .text => try js.expression(into, try js.call(try js.name(try cx.runtime("text")), &.{ node, ready.value })),
                .prop => |x| if (x.attribute_only) {
                    try pg.writeStringAttribute(into, node, x.attribute, ready.value, x.url);
                } else if (x.key) |key| {
                    try js.expression(into, try js.call(try js.name(try cx.runtime("prop")), &.{ node, ready.value, try js.string(key) }));
                } else {
                    try js.expression(into, try js.call(try js.name(try cx.runtime("prop")), &.{ node, ready.value }));
                },
                .when => try js.expression(into, try js.call(try js.name(try cx.runtime("when")), &.{ node, ready.value })),
                .observe, .rows => {},
            }
            if (ready.selected) |n| try js.@"if"(blk, try js.name(n), into, null);
        }
    }

    /// A binding function's body: per context its writes are in, the
    /// context entered, the `let`s it reads and every value that may throw
    /// evaluated first, then each write made with its other values
    /// evaluated just before it (§8.2, *Evaluation order*).
    fn writeFunction(pg: *Page, blk: m.Block, f: *const Function) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        switch (f.kind) {
            .writes => {},
            // The view's statements, evaluated for what they do (§8.2,
            // amended 2026-11-23).
            .statements => {
                const arms = try pg.enter(blk, 0, null, &.{});
                _ = try cx.programViewStatements(blk);
                pg.leave(arms);
                return;
            },
            // A memo node: the `let`, the `let`s its value reads first,
            // evaluated into its slot.
            .memo => {
                const lv = pg.tree.root(pg.index).lets.at(f.memo);
                const arms = try pg.enter(blk, 0, null, &.{lv});
                try cx.rootValues(blk, pg.index, &.{lv});
                try js.assign(blk, try js.name(pg.memo[f.memo].?), try cx.value(lv));
                pg.leave(arms);
                return;
            },
        }
        if (pg.prepares(f)) return pg.writePrepared(blk, f);
        var done: std.ArrayList(u32) = .empty;
        var call_args: std.ArrayList(CallArgs) = .empty;
        for (f.writes.items) |first| {
            const ctx = pg.writes.items[first].ctx;
            if (std.mem.indexOfScalar(u32, done.items, ctx) != null) continue;
            try done.append(pg.a(), ctx);
            var takens: std.ArrayList(struct { node: m.Node.Index, name: m.Name }) = .empty;
            var values: std.ArrayList(m.Value.Index) = .empty;
            const reads = try pg.functionReads(f, ctx, &values);
            // The `let`s of the view's body its root takes (`Root.lets`, D-d):
            // each the function reads evaluated as `enter` enters its root, in
            // source order, and no other (`letsOnce`: no other function reads
            // it; `memos`: one several read is read from its slot).
            // An arm's root is never the view's own, so their `let`s, bound per
            // root and ordinal, never alias.
            if (ctx != 0) std.debug.assert(pg.ctxs.items[ctx].root != pg.ctxs.items[0].root);
            const arms = try pg.enter(blk, ctx, &call_args, reads);
            // A value that may throw (`cx.valueSafe`: a call other than a basic
            // operator) is evaluated before the function's first write, so a
            // throw leaves the page as it was (§8.2, *Evaluation order*); each
            // other value is evaluated just before its write, where release
            // writes it in place. `prepares` handles unproven totality
            // before this legacy valueSafe path is used.
            var unsafe: std.ArrayList(m.Value.Index) = .empty;
            for (values.items) |v| if (!cx.valueSafe(v)) try unsafe.append(pg.a(), v);
            try cx.rootValues(blk, pg.ctxs.items[ctx].root, unsafe.items);
            // So is the arm a `when` takes, when its value may throw.
            var early: std.ArrayList(struct { node: m.Node.Index, name: m.Name }) = .empty;
            for (f.writes.items) |wi| {
                const w = pg.writes.items[wi];
                if (w.ctx != ctx) continue;
                const hn = switch (w.what) {
                    .when => |x| x.node,
                    .observe => |n| n,
                    else => continue,
                };
                if (cx.valueSafe(pg.tree.hole(hn).value)) continue;
                if (for (early.items) |e| {
                    if (e.node == hn) break true;
                } else false) continue;
                const t = try cx.fresh("arm");
                try js.constant(blk, t, try cx.programBranchArm(blk, hn));
                try early.append(pg.a(), .{ .node = hn, .name = t });
            }
            for (f.writes.items) |wi| {
                const w = pg.writes.items[wi];
                if (w.ctx != ctx) continue;
                var own: std.ArrayList(m.Value.Index) = .empty;
                switch (w.what) {
                    .text => |parts| for (parts) |part| switch (part) {
                        .value => |v| if (cx.valueSafe(v)) try own.append(pg.a(), v),
                        else => {},
                    },
                    .prop => |x| switch (x.value) {
                        .value => |v| if (cx.valueSafe(v)) try own.append(pg.a(), v),
                        .text => {},
                    },
                    .rows => |i| {
                        var all: std.ArrayList(m.Value.Index) = .empty;
                        try pg.forValues(pg.fors.items[i].node, &all);
                        for (all.items) |v| if (cx.valueSafe(v)) try own.append(pg.a(), v);
                    },
                    .when, .event, .observe => {},
                }
                try cx.rootValues(blk, pg.ctxs.items[ctx].root, own.items);
                const node = try pg.ref(w.target);
                switch (w.what) {
                    .event => unreachable,
                    .rows => |i| try pg.writeRows(blk, node, if (pg.fors.items[i].end) |t| try pg.ref(t) else try js.literal(.null), pg.fors.items[i].node, pg.fors.items[i].plan),
                    .text => |parts| {
                        const value = if (parts.len == 1 and parts[0] == .value)
                            try cx.value(parts[0].value)
                        else value: {
                            const tp = try pg.a().alloc(m.TemplatePart, parts.len);
                            for (tp, parts) |*t, part| t.* = switch (part) {
                                .text => |s| .{ .text = s },
                                .value => |v| .{ .expr = try cx.value(v) },
                            };
                            break :value try js.template(tp);
                        };
                        // `text` takes a string: a lone number is written as
                        // one, by a template (`browser-inline.md` §8.2).
                        const shown = if (w.string) value else try js.template(&.{.{ .expr = value }});
                        try js.expression(blk, try js.call(try js.name(try cx.runtime("text")), &.{ node, shown }));
                    },
                    .prop => |x| {
                        const value = switch (x.value) {
                            .value => |v| try cx.value(v),
                            .text => |t| try js.string(t),
                        };
                        if (x.attribute_only) {
                            try pg.writeStringAttribute(blk, node, x.attribute, value, x.url);
                        } else if (x.key) |key| {
                            try js.expression(blk, try js.call(try js.name(try cx.runtime("prop")), &.{ node, value, try js.string(key) }));
                        } else try js.expression(blk, try js.call(try js.name(try cx.runtime("prop")), &.{ node, value }));
                    },
                    .observe => |n| {
                        const prepared = for (early.items) |e| {
                            if (e.node == n) break true;
                        } else false;
                        if (!prepared) try js.expression(blk, try cx.programBranchArm(blk, n));
                    },
                    .when => |x| {
                        // The arm taken, once per function for all of a
                        // branch's `when`s.
                        const taken = for (early.items) |e| {
                            if (e.node == x.node) break try js.name(e.name);
                        } else for (takens.items) |t| {
                            if (t.node == x.node) break try js.name(t.name);
                        } else blk: {
                            const t = try cx.fresh("arm");
                            try js.constant(blk, t, try cx.programBranchArm(blk, x.node));
                            try takens.append(pg.a(), .{ .node = x.node, .name = t });
                            break :blk try js.name(t);
                        };
                        // Of two arms, the number is the test: hidden while it is
                        // not the shown one — itself when that is the first, else
                        // its negation. Of more, a comparison.
                        const hidden = if (x.arms > 2) try js.binary(.strict_ne, taken, try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{x.shown}))) else if (x.shown == 0) taken else try js.unary(.not, taken);
                        try js.expression(blk, try js.call(try js.name(try cx.runtime("when")), &.{ node, hidden }));
                    },
                }
            }
            pg.leave(arms);
        }
    }

    // ---- Listeners ----------------------------------------------------

    /// Event `ev`'s listener, planned: its block, which reads the payload
    /// through the event's extractor and evaluates the message the handler
    /// value makes, read at the event (Q1); the key it reaches and that
    /// key's fields. The mount then ends the block with the key's handler,
    /// or a call of it — or, for a message no key can be named for when the
    /// program is built, returns the message, which the dispatcher takes.
    fn plan(pg: *Page, ev: Event) m.Error!Plan {
        const cx = pg.cx;
        const js = cx.js;
        const tree = pg.tree;
        const facts = tree.eventFacts(ev.item.event);
        const dom = tree.string(facts.dom_name);
        const kind: ?[]const u8 = if (std.mem.eql(u8, dom, "click")) null else dom;
        const v = switch (ev.item.value.kind) {
            .dynamic => ev.item.value.dynamic.?,
            else => return limit(cx, ev.node, "this event's handler is a message written as a literal, which `browser-inline` cannot route to a key"),
        };
        const blk = try js.block();
        var event: ?m.Name = null;
        var payload: ?m.Expr = null;
        // With a `via` extractor the listener takes what it reads, and the
        // runtime's `send` calls it while the event is dispatched, even
        // when the send is queued (boundary.md §9.8.20 (d), #559).
        var read: ?m.Expr = null;
        if (ev.item.form == .payload) {
            read = try cx.extractor(ev.index);
            const e = try cx.fresh(if (read != null) "payload" else "event");
            event = e;
            payload = try js.name(e);
        }
        var saved: std.ArrayList(CallArgs) = .empty;
        if (ev.captures.len != 0) {
            var offset: u32 = 0;
            for (ev.captures) |c| {
                const call = tree.hole(pg.ctxs.items[c].node).call.?;
                const args = try pg.a().alloc(m.Expr, call.args.len);
                for (args) |*arg| {
                    arg.* = try js.index(try pg.eventBindingFor(ev), try js.number(try std.fmt.allocPrint(pg.a(), "{d}", .{offset})));
                    offset += 1;
                }
                try saved.append(pg.a(), .{ .ctx = c, .args = args });
            }
        }
        // The view root's `let`s the handler value, or an argument of a call
        // it is in, reads are memo nodes (`memos`): read from their slots
        // (§8.2, amended 2026-11-23).
        const arms = try pg.enter(blk, ev.ctx, if (ev.captures.len == 0) null else &saved, &.{v});
        const message = try cx.programMessageFields(blk, v, payload);
        pg.leave(arms);
        return switch (message) {
            .key => |kc| .{ .node = ev.node, .target = ev.target, .blk = blk, .event = event, .read = read, .key = kc.key, .args = kc.args, .kind = kind, .flags = facts },
            // A message no key can be named for when the program is built —
            // a function of the event, a call, a message the model holds —
            // goes through the dispatcher (§8.3, amended 2026-11-05).
            .value => |value| .{ .node = ev.node, .target = ev.target, .blk = blk, .event = event, .read = read, .key = null, .args = &.{}, .message = value, .kind = kind, .flags = facts },
        };
    }

    /// Key `k`'s handler body into `blk`, its fields `params`: the arm
    /// writes the model, then the write pass runs the buckets the key's
    /// writes reach — and those of a control the key's events show — each
    /// entry once, in document order, then the key's command is queued.
    fn handlerBody(pg: *Page, blk: m.Block, k: u32, params: []const m.Name, update: ?m.Expr, pass: []const m.Program.BucketRef) m.Error!void {
        if (!pg.p.update_context) return pg.handlerBodyIn(blk, k, params, update, pass);
        const js = pg.cx.js;
        const body = try js.block();
        try pg.handlerBodyIn(body, k, params, update, pass);
        try js.expression(blk, try js.call(try js.name(try pg.cx.runtime("update")), &.{try js.arrow(&.{}, body)}));
    }

    fn handlerBodyIn(pg: *Page, blk: m.Block, k: u32, params: []const m.Name, update: ?m.Expr, pass: []const m.Program.BucketRef) m.Error!void {
        const cx = pg.cx;
        const js = cx.js;
        const element_ = pg.p.constructor >= 1;
        const incoming = try cx.fresh("before");
        try js.constant(blk, incoming, try pg.modelRef());
        const before = try js.name(incoming);
        const next = try cx.programArmFields(k, blk, params, before, update);
        // The root plan proved that no key gives the model another object
        // (`programModelKept`, §8.4 amended 2026-10-23): the arm wrote the
        // object the model holds, and the handler stores nothing back. The
        // arm still runs, as a statement — a binding nothing reads is
        // dropped whole by release (`Opt`), and its writes with it — and an
        // element's pair is kept only for its command.
        const kept = cx.programModelKept();
        const commands = element_ and (cx.programCommand(k) == .runs or cx.programCommand(k) == .suspends);
        if (kept and !commands) {
            if (next != before) try js.expression(blk, next);
            try pg.writePass(blk, pass);
            if (pg.retitle) |r| try js.expression(blk, try js.call(try js.name(r), &.{}));
            return;
        }
        var result = next;
        if (element_) {
            const pair = try cx.fresh("result");
            try js.constant(blk, pair, next);
            result = try js.name(pair);
        }
        // An arm that wrote the model in place answers the object the model
        // already holds, as `before` itself (`programArmFields`; the compiler
        // side is `Lower.directArmFields`): no store. A handle that is not
        // `before` stores, which is never wrong — unless the root plan proved
        // that no key gives the model another object (`programModelKept`,
        // §8.4 amended 2026-10-23): then the arm's model is the one the model
        // holds, for an element's pair too, and there is nothing to store.
        if (!kept and (element_ or next != before)) try js.assign(blk, try pg.modelRef(), if (element_) try js.member(result, "a") else result);
        try pg.writePass(blk, pass);
        if (pg.retitle) |r| try js.expression(blk, try js.call(try js.name(r), &.{}));
        if (element_) switch (cx.programCommand(k)) {
            .runs, .suspends => try js.expression(blk, try js.call(try js.name(try cx.runtime("commands")), &.{ try js.member(result, "b"), try js.name(pg.dispatch.?) })),
            else => {},
        };
    }

    /// Key `k`'s write pass (§8.3, §8.4 amended 2026-10-22): the buckets
    /// the key's writes conflict with, by the root plan, and those of the
    /// controls its events are on, sorted, each once; the runner runs each
    /// entry once, in document order. There is no coarse pass: a `*` key
    /// reaches here only for a model of one value (`refuseKey`), whose whole
    /// write is that value, and the buckets it reaches are the ones its
    /// writes conflict with like any other key's.
    fn passOf(pg: *Page, k: u32, the: m.Program.Key) m.Error![]const m.Program.BucketRef {
        // By construction: `refuseKey` ran for this key before its handler,
        // and refuses every `*` key but one of a model of one value.
        if (the.star) std.debug.assert(the.star_kind == .single_value);
        // Null only for a program the pass did not analyse, whose keys
        // `refuseKey` refused (`.none`); refused here too, so no build mode
        // writes a handler without its pass.
        _ = pg.cx.programGroupsOf(k) orelse return pg.cx.programReport(.update, .not_implemented,
            \\A limit of the compiler: the write-set pass did not analyse this program, so
            \\`browser-inline` cannot say which bindings a message reaches
            \\(`docs/design/browser-inline.md` §8.3; §5, class 4). The program is valid: it builds
            \\with `--platform=browser-tea`.
        );
        var out: std.ArrayList(m.Program.BucketRef) = .empty;
        try addRefs(pg.a(), &out, pg.cx.keyBuckets(k));
        if (pg.controls.len != 0) try addRefs(pg.a(), &out, pg.controls[k].items);
        std.mem.sort(m.Program.BucketRef, out.items, {}, refLess);
        return out.items;
    }
};

fn refLess(_: void, x: m.Program.BucketRef, y: m.Program.BucketRef) bool {
    if (x.row != y.row) return x.row < y.row;
    return x.bucket < y.bucket;
}

/// An event's listener, planned (`Page.plan`).
const Plan = struct {
    node: m.Node.Index,
    target: ?u32,
    blk: m.Block,
    /// The listener's parameter, when it reads the event.
    event: ?m.Name,
    /// The event's `via` extractor, which `send` applies to the event
    /// before the listener takes what it read.
    read: ?m.Expr,
    /// The key the handler value reaches, and that key's fields; null for
    /// a value that names no key when the program is built, whose message
    /// goes through the dispatcher (§8.3, amended 2026-11-05).
    key: ?u32,
    args: []const m.Expr,
    /// For a null `key`: the message the handler value makes, the value
    /// of `blk`, which `send` evaluates while the event is dispatched.
    message: ?m.Expr = null,
    kind: ?[]const u8,
    flags: m.EventFacts,
};

/// The string form of a unit (`prerender.md` §4.1): code that evaluates
/// each hole's value as a binding would, in its context, and writes the
/// unit's HTML into one string, `out`.
///
/// It writes every end tag but a void element's. §8.2 leaves out the end
/// tags the parser closes the same way, which depends on the next sibling;
/// in the string form a sibling may be an arm `init` hides, and an end tag
/// written is closed by the parser exactly as one left out would be, so the
/// tree is §8.2's either way (§4.2).
const Render = struct {
    pg: *Page,
    /// The string, appended to.
    out: m.Name,
    /// The constant text written since the last value, not yet appended.
    pending: std.ArrayList(u8) = .empty,
    /// The next eager arm's ordinal among the unit's, in document order,
    /// from `base` — the parameter a piece's render function is handed, the
    /// ordinal of its first arm in the unit it is written into — or from 0.
    arm: u32 = 0,
    base: ?m.Name = null,
    /// The value of the `select` whose options are being written, and the
    /// flag that one of them is marked selected by it.
    select: ?Select = null,
    /// The program site's: the route the unit is rendered for, written as
    /// its top element's `data-beni` (`prerender.md` §4.2). Null in a piece.
    route: ?m.Name = null,

    const Select = struct { value: m.Name, marked: m.Name };

    /// An arm's branch, chosen in `blk` once for the sibling arms of one
    /// branch.
    const Taken = struct { ctx: u32, node: m.Node.Index, name: m.Name };

    fn js(r: *Render) m.Js {
        return r.pg.cx.js;
    }

    fn text(r: *Render, bytes: []const u8) m.Error!void {
        try r.pending.appendSlice(r.pg.a(), bytes);
    }

    /// The constant text written so far appended to the string.
    fn flush(r: *Render, blk: m.Block) m.Error!void {
        if (r.pending.items.len == 0) return;
        const js_ = r.js();
        try js_.assign(blk, try js_.name(r.out), try js_.binary(.add, try js_.name(r.out), try js_.string(try r.pg.a().dupe(u8, r.pending.items))));
        r.pending.clearRetainingCapacity();
    }

    /// `e`, a string, appended after the text written so far.
    fn append(r: *Render, blk: m.Block, e: m.Expr) m.Error!void {
        try r.flush(blk);
        const js_ = r.js();
        try js_.assign(blk, try js_.name(r.out), try js_.binary(.add, try js_.name(r.out), e));
    }

    /// The runtime's function `name` of the string form applied to `v`.
    fn runtime(r: *Render, name: []const u8, v: m.Expr) m.Error!m.Expr {
        const js_ = r.js();
        return js_.call(try js_.name(try r.pg.cx.runtime(name)), &.{v});
    }

    /// The unit into `blk`: the string, every node of the view, and the
    /// string returned — with the page's `title` after it, `[html, title]`,
    /// when there is one.
    fn unit(r: *Render, blk: m.Block, title: ?m.Name) m.Error!void {
        const js_ = r.js();
        try js_.let(blk, r.out, try js_.string(""));
        // The program's page begins with its capture script, when its unit
        // listens (`prerender.md` §6.5, amended 2026-10-29).
        if (r.route != null) try r.text(try r.pg.captureScript());
        try r.enter(blk, 0);
        try r.nodes(blk, r.pg.top_nodes, 0);
        try r.flush(blk);
        try js_.@"return"(blk, if (title) |t| try js_.array(&.{ try js_.name(r.out), try js_.name(t) }) else try js_.name(r.out));
    }

    /// Context `c` entered: the `let`s of its root that anything written in
    /// it reads, bound (D-d), and the choices whose only reachable markup is
    /// empty evaluated, as a binding evaluates them.
    fn enter(r: *Render, blk: m.Block, c: u32) m.Error!void {
        const pg = r.pg;
        var reads: std.ArrayList(m.Value.Index) = .empty;
        for (pg.writes.items) |w| if (pg.within(w.ctx, c)) try pg.writeReads(w, &reads);
        for (pg.ctxs.items, 0..) |x, ci| {
            if (ci == c or x.kind != .call or !pg.within(@intCast(ci), c)) continue;
            const call = pg.tree.hole(x.node).call orelse continue;
            for (0..call.args.len) |i| try reads.append(pg.a(), call.args.at(@intCast(i)));
        }
        try pg.bindLets(blk, pg.ctxs.items[c].root, reads.items);
        for (pg.writes.items) |w| if (w.ctx == c and w.what == .observe) {
            try r.js().expression(blk, try pg.cx.programBranchArm(blk, w.what.observe));
        };
    }

    /// The context directly below `c` on the way to `target`, which is
    /// inside it.
    fn below(r: *Render, c: u32, target: u32) u32 {
        var at = target;
        while (r.pg.ctxs.items[at].parent.? != c) at = r.pg.ctxs.items[at].parent.?;
        return at;
    }

    /// `list`, nodes of context `c` or of contexts inside it, into `blk`: a
    /// run of the markup of one call written in place entered once, an arm
    /// written when the branch takes it.
    fn nodes(r: *Render, blk: m.Block, list: []const Html, c: u32) m.Error!void {
        const pg = r.pg;
        const cx = pg.cx;
        var taken: std.ArrayList(Taken) = .empty;
        var i: usize = 0;
        while (i < list.len) {
            const n = list[i];
            if (n.ctx == c) {
                try r.node(blk, n, c);
                i += 1;
                continue;
            }
            const step = r.below(c, n.ctx);
            const x = pg.ctxs.items[step];
            switch (x.kind) {
                .call => {
                    var end = i + 1;
                    while (end < list.len and pg.within(list[end].ctx, step)) end += 1;
                    // The call's arguments are values of the enclosing
                    // root, evaluated as a binding entering it evaluates them.
                    if (pg.tree.hole(x.node).call) |call| {
                        const args = try pg.a().alloc(m.Value.Index, call.args.len);
                        for (args, 0..) |*v, k| v.* = call.args.at(@intCast(k));
                        try cx.rootValues(blk, pg.ctxs.items[c].root, args);
                    }
                    const args = try cx.programInlineArgs(blk, x.node);
                    try cx.programInlineEnter(blk, x.node, args, false);
                    try r.enter(blk, step);
                    try r.nodes(blk, list[i..end], step);
                    cx.programInlineLeave();
                    i = end;
                },
                .arm => {
                    std.debug.assert(n.kind == .element and n.ctx == step);
                    try r.armOf(blk, n, c, step, &taken);
                    i += 1;
                },
            }
        }
    }

    /// Eager arm `step`'s element `n`, in context `c`: written when the
    /// branch takes the arm, and in its place, when it does not, the
    /// comment that names its ordinal (`prerender.md` §4.1, §6.3). An arm
    /// inside it writes nothing then.
    fn armOf(r: *Render, blk: m.Block, n: Html, c: u32, step: u32, taken: *std.ArrayList(Taken)) m.Error!void {
        const pg = r.pg;
        const cx = pg.cx;
        const js_ = r.js();
        const x = pg.ctxs.items[step];
        try r.flush(blk);
        const branch = for (taken.items) |t| {
            if (t.ctx == c and t.node == x.node) break try js_.name(t.name);
        } else blk_: {
            const name = try cx.fresh("arm");
            try js_.constant(blk, name, try cx.programBranchArm(blk, x.node));
            try taken.append(pg.a(), .{ .ctx = c, .node = x.node, .name = name });
            break :blk_ try js_.name(name);
        };
        // Of two arms, the number is the test, as `when`'s: the first arm
        // is shown while it is falsy. Of more, a comparison.
        const shown = if (x.arms > 2)
            try js_.binary(.strict_eq, branch, try js_.number(try std.fmt.allocPrint(pg.a(), "{d}", .{x.arm})))
        else if (x.arm == 0) try js_.unary(.not, branch) else branch;
        const ordinal = r.arm;
        r.arm += 1;
        const then = try js_.block();
        try cx.programBranchEager(x.node, x.arm);
        try r.enter(then, step);
        try r.element(then, n, step);
        cx.programInlineLeave();
        try r.flush(then);
        const otherwise = try js_.block();
        const comment = if (r.base) |base|
            try js_.template(&.{
                .{ .text = "<!--" },
                .{ .expr = try js_.binary(.add, try js_.name(base), try js_.number(try std.fmt.allocPrint(pg.a(), "{d}", .{ordinal}))) },
                .{ .text = "-->" },
            })
        else
            try js_.string(try std.fmt.allocPrint(pg.a(), "<!--{d}-->", .{ordinal}));
        try r.append(otherwise, comment);
        try js_.@"if"(blk, shown, then, otherwise);
    }

    /// One node of context `c`.
    fn node(r: *Render, blk: m.Block, n: Html, c: u32) m.Error!void {
        switch (n.kind) {
            .text => try r.text(n.name),
            .element => try r.element(blk, n, c),
            .piece => try r.piece(blk, n),
        }
    }

    /// Another module's root, written by the render function its module
    /// wrote for it, handed the ordinal of its first arm and what the
    /// program hands its factory.
    fn piece(r: *Render, blk: m.Block, n: Html) m.Error!void {
        const pg = r.pg;
        const cx = pg.cx;
        const js_ = r.js();
        const u = pg.pieces.items[n.piece];
        const holders = try cx.programRootArgs(blk, u.node, pg.model, pg.cell);
        const args = try pg.a().alloc(m.Expr, 1 + holders.len);
        args[0] = try js_.number(try std.fmt.allocPrint(pg.a(), "{d}", .{r.arm}));
        @memcpy(args[1..], holders);
        r.arm += u.data.arms;
        try r.append(blk, try js_.call(try js_.name(try cx.programPieceName(u.node, u.data.render.?)), args));
    }

    /// Write `wi`'s value, evaluated into `blk` in context `c` and bound:
    /// a text as its binding writes it, a property's value.
    fn value(r: *Render, blk: m.Block, c: u32, wi: u32) m.Error!m.Expr {
        const pg = r.pg;
        const cx = pg.cx;
        const js_ = r.js();
        const w = pg.writes.items[wi];
        const root_ = pg.ctxs.items[c].root;
        const v = switch (w.what) {
            .text => |parts| v: {
                var values: std.ArrayList(m.Value.Index) = .empty;
                for (parts) |part| switch (part) {
                    .value => |x| try values.append(pg.a(), x),
                    else => {},
                };
                try cx.rootValues(blk, root_, values.items);
                const shown = if (parts.len == 1 and parts[0] == .value)
                    try cx.value(parts[0].value)
                else shown: {
                    const tp = try pg.a().alloc(m.TemplatePart, parts.len);
                    for (tp, parts) |*t, part| t.* = switch (part) {
                        .text => |s| .{ .text = s },
                        .value => |x| .{ .expr = try cx.value(x) },
                    };
                    break :shown try js_.template(tp);
                };
                break :v if (w.string) shown else try js_.template(&.{.{ .expr = shown }});
            },
            .prop => |x| switch (x.value) {
                .value => |pv| v: {
                    try cx.rootValues(blk, root_, &.{pv});
                    break :v try cx.value(pv);
                },
                .text => |t| try js_.string(t),
            },
            else => unreachable,
        };
        const name = try cx.fresh("value");
        try js_.constant(blk, name, v);
        return js_.name(name);
    }

    /// ` name="value"`, the value a string of `v`, escaped.
    fn quoted(r: *Render, blk: m.Block, name: []const u8, v: m.Expr) m.Error!void {
        try r.text(" ");
        try r.text(name);
        try r.text("=\"");
        try r.append(blk, try r.runtime("escapeAttribute", try r.js().template(&.{.{ .expr = v }})));
        try r.text("\"");
    }

    /// Element `n` of context `c`: its start tag with every attribute
    /// `init` gives a value, its text or its children, and its end tag.
    fn element(r: *Render, blk: m.Block, n: Html, c: u32) m.Error!void {
        const pg = r.pg;
        const js_ = r.js();
        try r.text("<");
        try r.text(n.name);
        var at: usize = 0;
        // A control's value that is its content, or its options'.
        var content: ?m.Expr = null;
        var chosen: ?m.Expr = null;
        for (n.dynamic) |d| {
            try r.text(n.attributes[at..d.at]);
            at = d.at;
            const x = pg.writes.items[d.write].what.prop;
            const v = try r.value(blk, c, d.write);
            if (!x.attribute_only and x.key == null and std.mem.eql(u8, n.name, "textarea")) {
                content = v;
            } else if (!x.attribute_only and x.key == null and std.mem.eql(u8, n.name, "select")) {
                chosen = v;
            } else if (x.boolean) {
                // A boolean attribute: present when true.
                try r.flush(blk);
                const yes = try js_.block();
                try js_.assign(yes, try js_.name(r.out), try js_.binary(.add, try js_.name(r.out), try js_.string(try std.fmt.allocPrint(pg.a(), " {s}", .{x.attribute}))));
                try js_.@"if"(blk, v, yes, null);
            } else try r.quoted(blk, x.attribute, if (x.url) try r.runtime("safeUrl", v) else v);
        }
        try r.text(n.attributes[at..]);
        // An option whose value is the `select`'s: the first such is
        // marked selected, as the select's `value` selects it.
        if (std.mem.eql(u8, n.name, "option")) if (r.select) |s| if (n.value) |own| {
            try r.flush(blk);
            const yes = try js_.block();
            try js_.assign(yes, try js_.name(r.out), try js_.binary(.add, try js_.name(r.out), try js_.string(" selected")));
            try js_.assign(yes, try js_.name(s.marked), try js_.literal(.true));
            const test_ = try js_.binary(.logical_and, try js_.unary(.not, try js_.name(s.marked)), try js_.binary(.strict_eq, try js_.name(s.value), try js_.string(own)));
            try js_.@"if"(blk, test_, yes, null);
        };
        // The unit's top element carries the route it was rendered for,
        // which the hydrating client hands `init` (`prerender.md` §4.2,
        // §7.3).
        if (n.target == null and c == 0 and !pg.piece) try r.quoted(blk, "data-beni", try js_.name(r.route.?));
        try r.text(">");
        if (n.void) return;
        const pre = std.mem.eql(u8, n.name, "pre") or std.mem.eql(u8, n.name, "textarea") or std.mem.eql(u8, n.name, "listing");
        const escape = if (pre) "escapePre" else "escape";
        for (pg.writes.items, 0..) |w, wi| {
            if (w.what != .text or w.target != n.target or w.ctx != c) continue;
            try r.append(blk, try r.runtime(escape, try r.value(blk, c, @intCast(wi))));
        }
        if (content) |v| try r.append(blk, try r.runtime(escape, try js_.template(&.{.{ .expr = v }})));
        const outer = r.select;
        if (chosen) |v| {
            const value_name = try pg.cx.fresh("chosen");
            try js_.constant(blk, value_name, v);
            const marked = try pg.cx.fresh("marked");
            try js_.let(blk, marked, try js_.literal(.false));
            r.select = .{ .value = value_name, .marked = marked };
        }
        try r.nodes(blk, n.children, c);
        r.select = outer;
        try r.text("</");
        try r.text(n.name);
        try r.text(">");
    }
};

fn textHole(kind: m.HoleKind) bool {
    return switch (kind) {
        .text_string, .text_number, .text_char => true,
        else => false,
    };
}

/// The boolean attributes whose DOM property has the attribute's name and
/// reflects it (`browser-inline.md` §8.2).
fn isBoolProperty(name: []const u8) bool {
    for ([_][]const u8{ "disabled", "hidden", "multiple", "open", "required" }) |x| {
        if (std.mem.eql(u8, x, name)) return true;
    }
    return false;
}

fn sorted(a: std.mem.Allocator, groups: []const u32) ![]const u32 {
    const out = try a.dupe(u32, groups);
    std.mem.sort(u32, out, {}, std.sort.asc(u32));
    var n: usize = 0;
    for (out) |g| {
        if (n != 0 and out[n - 1] == g) continue;
        out[n] = g;
        n += 1;
    }
    return out[0..n];
}

/// A handler's name hint from its key's name: its letters and digits.
fn handlerHint(key: []const u8) []const u8 {
    var end: usize = 0;
    while (end < key.len and std.ascii.isAlphanumeric(key[end])) end += 1;
    return if (end == 0) "Key" else key[0..end];
}

// ---- The markup string (§8.2) -------------------------------------------

/// A constant attribute, written into `out`.
fn writeAttribute(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, c: m.Constant, tree: *const m.Tree) !void {
    switch (c.kind) {
        .string, .number => try writeValue(a, out, name, tree.string(c.text)),
        .bool => if (c.bool) {
            try out.append(a, ' ');
            try out.appendSlice(a, name);
        },
        .none => {
            try out.append(a, ' ');
            try out.appendSlice(a, name);
        },
        else => {},
    }
}

/// Whether the `browser` runtime's `safeUrl` refuses `url`, as the `dom`
/// lowering decides a constant one (`platforms/browser/zig/dom.zig`,
/// `scriptUrl`, whose pattern this is): `^[\s\x00-\x20]*(javascript:|
/// data:text/html[,;])`, letters in any case and `\s` between any two, or
/// null when the answer turns on a character outside ASCII, which `\s` may
/// match.
fn scriptUrl(url: []const u8) ?bool {
    var i: usize = 0;
    while (i < url.len and url[i] <= 0x20) i += 1;
    if (i < url.len and url[i] >= 0x80) return null;
    const javascript = scriptPrefix(url, i, "javascript:") orelse return null;
    if (javascript) return true;
    return scriptPrefix(url, i, "data:text/html");
}

fn scriptPrefix(url: []const u8, start: usize, word: []const u8) ?bool {
    var i = start;
    const html = word[word.len - 1] == 'l';
    for (word, 0..) |w, n| {
        if (n != 0) {
            while (i < url.len and isUrlSpace(url[i])) i += 1;
        }
        if (i == url.len) return false;
        if (url[i] >= 0x80) return null;
        if (std.ascii.toLower(url[i]) != w) return false;
        i += 1;
    }
    if (!html) return true;
    while (i < url.len and isUrlSpace(url[i])) i += 1;
    if (i == url.len) return false;
    if (url[i] >= 0x80) return null;
    return url[i] == ',' or url[i] == ';';
}

/// `\s` in ASCII.
fn isUrlSpace(c: u8) bool {
    return (c >= 0x09 and c <= 0x0D) or c == ' ';
}

test "a constant URL is checked as the browser runtime's safeUrl checks it" {
    const t = std.testing;
    try t.expectEqual(@as(?bool, false), scriptUrl("/blog/7"));
    try t.expectEqual(@as(?bool, true), scriptUrl(" \x01\tJaVa\nscript :x"));
    try t.expectEqual(@as(?bool, true), scriptUrl("DATA: text / html ;base64,eA=="));
    try t.expectEqual(@as(?bool, false), scriptUrl("javascript.html"));
    try t.expectEqual(@as(?bool, null), scriptUrl("\xc2\xa0javascript:x"));
    try t.expectEqual(@as(?bool, false), scriptUrl("/caf\xc3\xa9"));
}

/// ` name=value`: unquoted where the parser reads it back so, bare when
/// empty, double-quoted otherwise.
fn writeValue(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try out.append(a, ' ');
    try out.appendSlice(a, name);
    if (value.len == 0) return;
    try out.append(a, '=');
    if (unquoted(value)) return escapeAmpersand(a, out, value);
    try out.append(a, '"');
    try escapeAttribute(a, out, value);
    try out.append(a, '"');
}

/// Whether an attribute value reads back the same unquoted: none of the
/// characters that end or change an unquoted value.
fn unquoted(value: []const u8) bool {
    for (value) |ch| switch (ch) {
        ' ', '\t', '\n', '\x0c', '\r', '"', '\'', '=', '<', '>', '`' => return false,
        else => {},
    };
    return true;
}

fn escapeAmpersand(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        else => try out.append(a, c),
    };
}

/// Text as the parser of an element's ordinary content reads it back.
fn escapeText(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '\r' => try out.appendSlice(a, "&#13;"),
        else => try out.append(a, c),
    };
}

/// A double-quoted attribute value as the parser reads it back.
fn escapeAttribute(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        '\r' => try out.appendSlice(a, "&#13;"),
        else => try out.append(a, c),
    };
}

/// `nodes`, the children of `parent` (null: the string's top level), into
/// `out`, each end tag left out where the parser closes the element there
/// as the end tag would: an optional one (`optionalEnd`), and any at the
/// very end of the string (`at_end`), which the parser closes at the end of
/// its input.
/// `at_end`: `nodes` end the whole string the parser reads — every end
/// tag of the last node's path is left out, which only the end of the input
/// closes as the end tags would, so the caller never appends to it.
fn serialise(a: std.mem.Allocator, out: *std.ArrayList(u8), nodes: []const Html, parent: ?[]const u8, at_end: bool) !void {
    _ = try serialiseOpen(a, out, nodes, parent, at_end, false);
}

/// `serialise`, and whether the last node is an element other than a `<p>`
/// whose end tag it left out: that element is still open, and a start tag
/// that would close the parent stops at it — an `<li>` stops its search at a
/// `<dd>`, a special element — so the parent then keeps its own end tag
/// before a sibling (`<ul><li><dd>x</li><li>`; the review of S1's first
/// pull request).
/// `in_select`: `nodes` are inside a `<select>`, where every end tag is
/// written, the select's own included (`optionalEnd`).
fn serialiseOpen(a: std.mem.Allocator, out: *std.ArrayList(u8), nodes: []const Html, parent: ?[]const u8, at_end: bool, in_select: bool) !bool {
    var open = false;
    for (nodes, 0..) |n, i| {
        open = false;
        const next: ?Html = if (i + 1 < nodes.len) nodes[i + 1] else null;
        switch (n.kind) {
            .text => try out.appendSlice(a, n.name),
            // A mark the mount replaces with the piece's string: the piece
            // writes every end tag of its own, so nothing of it is open.
            .piece => try out.print(a, "\x00{d}\x00", .{n.piece}),
            .element => {
                try out.append(a, '<');
                try out.appendSlice(a, n.name);
                try out.appendSlice(a, n.attributes);
                try out.append(a, '>');
                if (n.void) continue;
                const select = in_select or std.mem.eql(u8, n.name, "select");
                const last = next == null and at_end and !select;
                const child_open = try serialiseOpen(a, out, n.children, n.name, last, select);
                const popped = next == null and !select and if (parent) |p| poppedAtEnd(n, p) else false;
                if (!select and (last or popped or (optionalEnd(n.name, next, parent) and (next == null or !child_open)))) {
                    open = !std.mem.eql(u8, n.name, "p");
                    continue;
                }
                try out.appendSlice(a, "</");
                try out.appendSlice(a, n.name);
                try out.append(a, '>');
            },
        }
    }
    return open;
}

/// Whether element `name`'s end tag may be left out when `next` follows it
/// (null: its parent ends), in `parent` (null: unknown) — only where the
/// HTML standard's tree builder (§13.2.6) closes the element there exactly
/// as the end tag would:
///
/// - before a next sibling, the start tags that close it: an `<li>` an
///   open `<li>`, a `<dt>` or `<dd>` either, a cell a cell, a row a row, a
///   row group a row group, and the block elements whose start tag closes a `<p>` in
///   button scope (not `<table>`, which does only outside quirks mode, nor
///   `<form>`, which depends on the form pointer);
/// - at its parent's end, only a parent whose end tag generates implied end
///   tags (`impliesEnds`): any other end tag — `</span>`, `</label>`,
///   `</em>`, a custom element's — meets the open `<p>`, `<li>` or `<dd>`,
///   a special element, and is ignored, or runs the adoption agency for a
///   formatting element, which builds the tree anew.
///
/// The rules follow the HTML Living Standard's tree construction as parse5
/// 7.3.0 implements it (`tests/browser/parse5.mjs`), the parser the gates
/// check every page with: the standard before its rework of `select`
/// parsing for the customizable `<select>`, which replaced the "in select"
/// insertion mode. Nothing here depends on that mode: inside a `<select>`
/// every end tag is written (`serialiseOpen`'s `in_select`), so an
/// `<option>`, an `<optgroup>` and whatever they hold close where the tree
/// says under either revision (`browser/inline/SelectEndTags`).
fn optionalEnd(name: []const u8, next: ?Html, parent: ?[]const u8) bool {
    const eql = std.mem.eql;
    const nextIs = struct {
        fn f(n: ?Html, names: []const []const u8) bool {
            const x = n orelse return false;
            if (x.kind != .element) return false;
            for (names) |s| if (std.mem.eql(u8, s, x.name)) return true;
            return false;
        }
    }.f;
    const among = struct {
        fn f(s: []const u8, names: []const []const u8) bool {
            for (names) |x| if (std.mem.eql(u8, s, x)) return true;
            return false;
        }
    }.f;
    // At the parent's end: a parent known to close it.
    const ends = next == null and if (parent) |p| impliesEnds(p) or
        // A cell's end closes it, and a row's end closes a cell.
        (among(name, &.{ "td", "th" }) and eql(u8, p, "tr")) or
        (eql(u8, name, "tr") and among(p, &.{ "tbody", "thead", "tfoot" })) else false;
    if (eql(u8, name, "li")) return ends or nextIs(next, &.{"li"});
    if (eql(u8, name, "dt")) return nextIs(next, &.{ "dt", "dd" });
    if (eql(u8, name, "dd")) return ends or nextIs(next, &.{ "dt", "dd" });
    if (eql(u8, name, "td") or eql(u8, name, "th")) return ends or nextIs(next, &.{ "td", "th" });
    if (eql(u8, name, "tr")) return ends or nextIs(next, &.{"tr"});
    if (eql(u8, name, "thead")) return nextIs(next, &.{ "tbody", "tfoot" });
    if (eql(u8, name, "tbody")) return ends or nextIs(next, &.{ "tbody", "tfoot" });
    if (eql(u8, name, "p")) return ends or nextIs(next, &.{ "address", "article", "aside", "blockquote", "details", "dialog", "div", "dl", "fieldset", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main", "menu", "nav", "ol", "p", "pre", "search", "section", "ul" });
    return false;
}

/// Whether element `n`, the last node of a `parent`, needs no end tag of
/// its own (#916): `parent`'s end tag is one that pops every element open
/// above it (§13.2.6.4.7, *An end tag whose tag name is one of: "address",
/// …*), and `n` and every element its end tag leaves open below it —
/// its last child, when that one's end tag is left out too — is one that
/// pop closes exactly as its own end tag would (`poppable`), of another
/// name than `parent`'s, whose end tag would otherwise be the one the
/// parser matches. `<section><header><aside><p>x</section>`.
fn poppedAtEnd(n: Html, parent: []const u8) bool {
    if (!popsToSelf(parent)) return false;
    return openChainPoppable(n, parent);
}

/// Whether element `n` and the elements left open at its end are each
/// poppable and none is named `parent`.
fn openChainPoppable(n: Html, parent: []const u8) bool {
    if (n.kind != .element or n.void) return true;
    if (!poppable(n.name) or std.mem.eql(u8, n.name, parent)) return false;
    const last = if (n.children.len == 0) return true else n.children[n.children.len - 1];
    if (last.kind != .element or last.void) return true;
    // The last child's end tag is left out when `n`'s end pops it, or
    // where `optionalEnd` says `n`'s end closes it.
    const left_open = poppedAtEnd(last, n.name) or optionalEnd(last.name, null, n.name);
    return !left_open or openChainPoppable(last, parent);
}

/// The end tags that pop every element above their own: the list of
/// §13.2.6.4.7 but `listing` and `pre`, which nothing here writes open.
fn popsToSelf(name: []const u8) bool {
    for ([_][]const u8{
        "address", "article", "aside", "blockquote", "button", "center", "details", "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "main", "menu", "nav", "ol", "search", "section", "summary", "ul",
    }) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// The elements a pop closes exactly as their end tags would: none is a
/// formatting element, which the list of active formatting elements would
/// open again after the pop; nor a `form`, whose end tag also clears the
/// form element pointer; nor a scope's boundary, a table's part, a
/// `select` or a `template`, which change the insertion mode.
fn poppable(name: []const u8) bool {
    for ([_][]const u8{
        "address", "article", "aside", "blockquote", "button", "details", "dialog", "div",  "dl",    "dd",     "dt", "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "main", "menu", "nav", "ol", "ul", "li", "search", "section", "summary",
        "h1",      "h2",      "h3",    "h4",         "h5",     "h6",      "p",      "span", "label", "output",
    }) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

/// Whether the end tag of `name` generates implied end tags (§13.2.6.4.7):
/// it closes an open `<p>`, `<li>`, `<dd>`, `<dt>`, `<rp>` or `<rt>` inside it
/// (and an `<option>` or `<optgroup>`, whose end tags are always written).
fn impliesEnds(name: []const u8) bool {
    for ([_][]const u8{
        "address", "article", "aside", "blockquote", "button", "center", "details", "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "listing", "main", "menu", "nav", "ol", "pre", "search", "section", "summary", "ul",
        "li",      "dd",      "dt",    "h1",         "h2",     "h3",     "h4",      "h5",     "h6",  "td",  "th", "caption",  "body",       "html",
    }) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

test "text and attribute values are escaped as the parser reads them back" {
    const t = std.testing;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    try escapeText(t.allocator, &out, "a < b & \"c\"\r");
    try t.expectEqualStrings("a &lt; b &amp; \"c\"&#13;", out.items);
    out.clearRetainingCapacity();
    try escapeAttribute(t.allocator, &out, "a < b & \"c\"");
    try t.expectEqualStrings("a &lt; b &amp; &quot;c&quot;", out.items);
}

test "an attribute value is unquoted only where the parser reads it back so" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try writeValue(a, &out, "data-role", "inc");
    try writeValue(a, &out, "title", "a b");
    try writeValue(a, &out, "data-x", "");
    try writeValue(a, &out, "data-y", "x&y");
    try t.expectEqualStrings(" data-role=inc title=\"a b\" data-x data-y=x&amp;y", out.items);
}

test "optional end tags and the closing run are left out" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const li = Html{ .kind = .element, .name = "li", .children = &.{.{ .kind = .text, .name = "x" }} };
    const p = Html{ .kind = .element, .name = "p" };
    const button = Html{ .kind = .element, .name = "button" };
    const div = Html{ .kind = .element, .name = "div" };
    const ul = Html{ .kind = .element, .name = "ul", .children = &.{ li, li } };
    const section = Html{ .kind = .element, .name = "section", .children = &.{ ul, p, button, p, div, p } };
    var out: std.ArrayList(u8) = .empty;
    try serialise(a, &out, &.{section}, null, false);
    try t.expectEqualStrings("<section><ul><li>x<li>x</ul><p></p><button></button><p><div></div><p></section>", out.items);
    out.clearRetainingCapacity();
    try serialise(a, &out, &.{section}, null, true);
    try t.expectEqualStrings("<section><ul><li>x<li>x</ul><p></p><button></button><p><div></div><p>", out.items);
    // A `<p>` at the end of an `<a>` keeps its end tag.
    out.clearRetainingCapacity();
    try serialise(a, &out, &.{.{ .kind = .element, .name = "a", .children = &.{p} }}, null, false);
    try t.expectEqualStrings("<a><p></p></a>", out.items);
}

/// The child indices from `nodes`, the top element's children, down to the
/// element of place `target` among its descendants in document order.
/// Null when two texts stand side by side on the way, which the parser
/// makes one node.
fn pathOf(a: std.mem.Allocator, nodes: []const Html, target: u32) !?[]const u32 {
    var path: std.ArrayList(u32) = .empty;
    var count: u32 = 0;
    if (!try find(a, nodes, target, &count, &path)) return null;
    var level = nodes;
    for (path.items) |i| {
        for (level[0..i], 0..) |n, j| if (n.kind == .text and j + 1 < level.len and level[j + 1].kind == .text) return null;
        level = level[i].children;
    }
    return path.items;
}

fn find(a: std.mem.Allocator, nodes: []const Html, target: u32, count: *u32, path: *std.ArrayList(u32)) !bool {
    for (nodes, 0..) |n, i| {
        if (n.kind != .element) continue;
        try path.append(a, @intCast(i));
        if (count.* == target) return true;
        count.* += 1;
        if (try find(a, n.children, target, count, path)) return true;
        _ = path.pop();
    }
    return false;
}

test "an end tag is left out only where the parser closes the element there" {
    // Each case's expectation is what the HTML standard's tree builder
    // (§13.2.6) makes of the string: the parent's end tag closes an open
    // `<p>`, `<li>`, `<dd>` only when it generates implied end tags, and a
    // formatting or phrasing parent's does not, so the end tag stays.
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const el = struct {
        fn f(name: []const u8, children: []const Html) Html {
            return .{ .kind = .element, .name = name, .children = children };
        }
    }.f;
    const x: Html = .{ .kind = .text, .name = "x" };
    const cases = [_]struct { tree: Html, html: []const u8 }{
        .{ .tree = el("div", &.{el("p", &.{x})}), .html = "<div><p>x</div>" },
        .{ .tree = el("button", &.{el("p", &.{x})}), .html = "<button><p>x</button>" },
        .{ .tree = el("label", &.{el("p", &.{x})}), .html = "<label><p>x</p></label>" },
        .{ .tree = el("em", &.{el("p", &.{x})}), .html = "<em><p>x</p></em>" },
        .{ .tree = el("span", &.{el("li", &.{x})}), .html = "<span><li>x</li></span>" },
        .{ .tree = el("output", &.{el("dd", &.{x})}), .html = "<output><dd>x</dd></output>" },
        .{ .tree = el("x-y", &.{el("p", &.{x})}), .html = "<x-y><p>x</p></x-y>" },
        .{ .tree = el("a", &.{el("p", &.{x})}), .html = "<a><p>x</p></a>" },
        .{ .tree = el("ul", &.{ el("li", &.{x}), el("li", &.{x}) }), .html = "<ul><li>x<li>x</ul>" },
        .{ .tree = el("dl", &.{ el("dt", &.{x}), el("dd", &.{x}) }), .html = "<dl><dt>x<dd>x</dl>" },
        .{ .tree = el("section", &.{ el("p", &.{x}), el("div", &.{}) }), .html = "<section><p>x<div></section>" },
        .{ .tree = el("div", &.{ el("p", &.{x}), el("span", &.{}) }), .html = "<div><p>x</p><span></div>" },
        .{ .tree = el("div", &.{ el("p", &.{x}), el("table", &.{}) }), .html = "<div><p>x</p><table></table></div>" },
        // An end tag that pops every element open above it closes the last
        // child's open elements (#916), unless one is a formatting element,
        // which the parser opens again, a `form`, a table, or of its name.
        .{ .tree = el("section", &.{el("header", &.{el("aside", &.{el("p", &.{x})})})}), .html = "<section><header><aside><p>x</section>" },
        .{ .tree = el("div", &.{el("b", &.{x})}), .html = "<div><b>x</b></div>" },
        .{ .tree = el("div", &.{el("form", &.{})}), .html = "<div><form></form></div>" },
        .{ .tree = el("div", &.{el("table", &.{})}), .html = "<div><table></table></div>" },
        .{ .tree = el("div", &.{el("div", &.{x})}), .html = "<div><div>x</div></div>" },
        .{ .tree = el("span", &.{el("div", &.{x})}), .html = "<span><div>x</div></span>" },
        .{ .tree = el("section", &.{el("div", &.{el("section", &.{x})})}), .html = "<section><div><section>x</div></section>" },
        .{ .tree = el("div", &.{el("span", &.{el("em", &.{x})})}), .html = "<div><span><em>x</em></div>" },
        // Inside a `<select>` every end tag is written.
        .{ .tree = el("select", &.{ el("option", &.{x}), el("option", &.{x}) }), .html = "<select><option>x</option><option>x</option></select>" },
        .{ .tree = el("li", &.{el("p", &.{x})}), .html = "<li><p>x</li>" },
        .{ .tree = el("h2", &.{el("span", &.{el("p", &.{x})})}), .html = "<h2><span><p>x</p></span></h2>" },
        // An `<li>` or a `<dt>` stops its search for an open one at a `<dd>`
        // or an `<li>` still open: the parent keeps its end tag there.
        .{ .tree = el("ul", &.{ el("li", &.{el("dd", &.{x})}), el("li", &.{x}) }), .html = "<ul><li><dd>x</li><li>x</ul>" },
        .{ .tree = el("dl", &.{ el("dd", &.{el("li", &.{x})}), el("dt", &.{x}) }), .html = "<dl><dd><li>x</dd><dt>x</dl>" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        try serialise(a, &out, &.{c.tree}, null, false);
        try t.expectEqualStrings(c.html, out.items);
    }
}

/// `s` with its first letter upper case, to open a sentence.
fn capital(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try a.dupe(u8, s);
    if (out.len != 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}
