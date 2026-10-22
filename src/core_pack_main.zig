//! Makes the checked core (docs/design/fast-compiler.md §8, *The checked
//! core, embedded*):
//!
//! ```
//! core_pack <core dir> <build id, 32 hex digits> <out> [<name> <root> <dir>]...
//! ```
//!
//! Only `build.zig` runs this, once per compiler it builds, between building
//! this small program and building that compiler: it checks every module of
//! the core in `<core dir>` exactly as `beni check` would — the same option
//! string, every key computed with the build id of the compiler that will
//! carry the result — and then, for each platform that compiler carries,
//! every module of that platform's chain exactly as `beni check
//! --platform=<name>` would. It writes each core and platform file's
//! front-end artifact, each core and platform module's cache entry, each
//! such module's reachability edge lists (`js/EdgePack.zig`) and each
//! module's emitted text, split in the units a join splices
//! (`js/EmitPack.zig`), into one blob (`cache/Pack.zig`), which that
//! compiler embeds as `core_pack`.
//!
//! **The platforms are the target compiler's, not this program's.** Each
//! `<name> <root> <dir>` triple is one row of the table that compiler embeds
//! (`build.zig`'s `embedPlatforms`): `<dir>` holds exactly the files it
//! embeds, under the same relative paths, and `<root>` is the package root
//! it gives them. The triples become a table of the same shape here, so the
//! chain, the store's paths, the embedded siblings and therefore every key
//! are the ones that compiler computes — while this program is built once,
//! whatever platforms a compiler carries.
//!
//! **One run per chain.** A platform module's key carries what its chain
//! says about markup (`cache/Key.zig`), so one module can have a row per
//! chain it can be checked in; a row two chains share is one row. Each run
//! after the first reads the rows the earlier ones made, so core is checked
//! once and a platform's dependency once per distinct key.
//!
//! **It refuses to make an incomplete pack.** A core or platform module
//! that is not in it would be checked by every build, which is the cost the
//! pack exists to remove, and nothing else would say so; a core or a
//! platform with an error cannot be carried at all. Either fails the build
//! of beni, with the diagnostics.
//!
//! A program of its own, and not a hidden command of `beni`, because it is
//! on the path of every build of beni after an edit under `src/`: this root
//! reaches the front end, the checker, the reachability edge builder
//! (`js/Reach.zig`), the lowering and the printer — every phase up to the
//! bytes a build emits, which is what the rows hold — and not the
//! formatter or the development loop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const beni = @import("beni");
const Session = beni.Session;
const Pack = beni.cache.Pack;
const Key = beni.cache.Key;
const platform = beni.platform;
const Bir = beni.bir.Bir;
const Dispatch = beni.check.Dispatch;
const Graph = beni.resolve.Graph;
const InternPool = beni.InternPool;
const EdgePack = beni.js.EdgePack;
const Emit = beni.js.Emit;
const EmitPack = beni.js.EmitPack;
const Funnel = beni.js.Funnel;
const Join = beni.js.Join;
const JsIr = beni.js.JsIr;
const Lower = beni.js.Lower;
const Print = beni.js.Print;
const Reach = beni.js.Reach;
const SchemaGraph = beni.js.SchemaGraph;
const SourceMap = beni.js.SourceMap;

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = init.minimal.args.toSlice(arena) catch return fail(stderr, "out of memory", .{});
    if (args.len < 4 or (args.len - 4) % 3 != 0) {
        return fail(stderr, "usage: core_pack <core dir> <build id> <out> [<name> <root> <dir>]...", .{});
    }
    const core_dir = args[1];
    var build_id: [16]u8 = undefined;
    const digits = args[2];
    if (digits.len != 32) return fail(stderr, "the build id is 32 hex digits, not '{s}'", .{digits});
    _ = std.fmt.hexToBytes(&build_id, digits) catch return fail(stderr, "the build id is 32 hex digits, not '{s}'", .{digits});

    const triples = args[4..];
    const table = arena.alloc(platform.Embedded, triples.len / 3) catch return fail(stderr, "out of memory", .{});
    for (table, 0..) |*row, i| {
        const t = triples[i * 3 ..][0..3];
        row.* = readPlatform(arena, io, t[0], t[1], t[2]) catch |err|
            return fail(stderr, "cannot read the platform '{s}' from '{s}': {t}", .{ t[0], t[2], err });
    }

    var writer: Pack.Writer = .{};
    defer writer.deinit(gpa);
    var made: []u8 = &.{};
    defer gpa.free(made);

    // Core alone, then each platform's chain over the rows made so far.
    for (0..table.len + 1) |run| {
        var chain_failure: ?platform.Failure = null;
        const chain: ?platform.Chain = if (run == 0) null else platform.resolveChainIn(arena, io, table[run - 1].name, table, &chain_failure) catch |err| switch (err) {
            error.OutOfMemory => return fail(stderr, "out of memory", .{}),
            error.Failed => {
                _ = platform.report(stderr, chain_failure.?);
                return fail(stderr, "the platform '{s}' has no chain", .{table[run - 1].name});
            },
        };
        const what = if (run == 0) "the core" else table[run - 1].name;
        const blob = check(gpa, io, stderr, core_dir, build_id, &writer, made, if (chain) |*c| c else null, what) catch |err| switch (err) {
            error.OutOfMemory => return fail(stderr, "out of memory", .{}),
            error.Reported => return 1,
        };
        gpa.free(made);
        made = blob;
    }

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[3], .data = made }) catch |err|
        return fail(stderr, "cannot write '{s}': {t}", .{ args[3], err });
    return 0;
}

/// One run: check `core_dir` and, with `chain`, every module of it, adding
/// the rows `made` does not already hold to `writer`. Returns the blob of
/// every row so far, having made sure it holds one for every core and
/// platform file and module of the run.
fn check(
    gpa: Allocator,
    io: Io,
    stderr: *Io.Writer,
    core_dir: []const u8,
    build_id: [16]u8,
    writer: *Pack.Writer,
    made: []const u8,
    chain: ?*const platform.Chain,
    what: []const u8,
) error{ OutOfMemory, Reported }![]u8 {
    const cpus: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, 64));
    // `beni check`'s options, every one that is a term of a key
    // (`cache/Key.zig`'s option string), and `--platform`'s: a pack made with
    // any other would hold rows no build looks up.
    var session = try Session.init(gpa, io, .{
        .jobs = @max(cpus, 1),
        .size_by_work = true,
        .core_package = true,
        .core_root = core_dir,
        .informational = true,
        .platform = if (chain) |c| c.top().name else null,
        .chain = chain,
        .pack_out = writer,
        .pack_in = if (made.len == 0) null else made,
        .pack_build_id = build_id,
        // Every build installs these records: they carry the crossing bits.
        .crossing_always = true,
    });
    defer session.deinit();

    const summary = session.run(&.{}, Session.check_phases, stderr) catch |err| switch (err) {
        error.InputPath => {
            const failure = session.io_failure.?;
            _ = fail(stderr, "cannot read '{s}': {t}", .{ failure.path, failure.err });
            return error.Reported;
        },
        error.OutOfMemory => return error.OutOfMemory,
        else => |e| {
            _ = fail(stderr, "{t}", .{e});
            return error.Reported;
        },
    };
    if (summary.errors != 0) {
        _ = fail(stderr, "{s} does not check", .{what});
        return error.Reported;
    }
    try addEdges(gpa, &session, writer, made);
    try addEmit(gpa, stderr, &session, writer, made, chain, what);

    // Every core and platform file and module of the run, or no pack.
    const blob = try writer.write(gpa);
    errdefer gpa.free(blob);
    const pack = Pack.Pack.init(blob);
    var files: u32 = 0;
    for (0..session.store.count()) |i| {
        if (session.store.package(@fromBackingInt(@intCast(i))) == .app) continue;
        files += 1;
        if (pack.find(.frontend, session.file_keys[i]) == null) {
            _ = fail(stderr, "checking {s}, '{s}' left no front-end artifact", .{ what, session.store.path(@fromBackingInt(@intCast(i))) });
            return error.Reported;
        }
    }
    if (files == 0) {
        _ = fail(stderr, "no core modules under '{s}'", .{core_dir});
        return error.Reported;
    }
    // The chain's program constructors and placements, once: `refuses` asks
    // which modules are cacheable at all.
    var calls_state: std.heap.ArenaAllocator = .init(gpa);
    defer calls_state.deinit();
    const calls = try programCalls(calls_state.allocator(), chain);
    for (0..session.graph.count()) |i| {
        const m: @TypeOf(session.graph).Index = @fromBackingInt(@intCast(i));
        if (session.graph.modulePackage(m) == .app) continue;
        if (!session.keys.isCacheable(m) or pack.find(.entry, session.keys.of(m)) == null) {
            _ = fail(stderr, "checking {s}, the module '{s}' left no cache entry", .{ what, session.store.path(session.graph.moduleFile(m)) });
            return error.Reported;
        }
        for (EdgePack.every_options) |options| {
            if (pack.find(.edges, EdgePack.key(session.keys.of(m), options)) == null) {
                _ = fail(stderr, "checking {s}, the module '{s}' left no edge lists", .{ what, session.store.path(session.graph.moduleFile(m)) });
                return error.Reported;
            }
        }
        // A module the maker refuses has no row to require (`backend.md`
        // §9, *The maker*; `fast-compiler.md` §8): no embedded module is
        // refused today, and the day one is, its emit rows are simply
        // absent, exactly as its edge lists' rule would have them.
        if (refuses(&session, calls, m, session.artifacts.bir(session.graph.moduleFile(m)))) continue;
        for (EmitPack.every_options) |options| {
            if (pack.find(.emit, EmitPack.key(session.keys.of(m), options)) == null) {
                _ = fail(stderr, "checking {s}, the module '{s}' left no emitted text", .{ what, session.store.path(session.graph.moduleFile(m)) });
                return error.Reported;
            }
        }
    }
    return blob;
}

/// Every core and platform module's reachability edge lists, one row per
/// option they depend on (`js/EdgePack.zig`; `fast-compiler.md` §8, *The
/// checked core, embedded*). A module whose rows an earlier run made, under
/// the same keys, is not built again: core's are made once, by the first.
fn addEdges(
    gpa: Allocator,
    session: *const Session,
    writer: *Pack.Writer,
    made: []const u8,
) error{OutOfMemory}!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const earlier = Pack.Pack.init(made);
    for (EdgePack.every_options) |options| {
        const in = try EdgePack.input(arena, session, options);
        var builder: Reach.Builder = .init(in, arena);
        for (0..session.graph.count()) |i| {
            const m: @TypeOf(session.graph).Index = @fromBackingInt(@intCast(i));
            if (session.graph.modulePackage(m) == .app or !session.keys.isCacheable(m)) continue;
            const key = EdgePack.key(session.keys.of(m), options);
            if (earlier.find(.edges, key) != null) continue;
            const bytes = try EdgePack.encode(gpa, try builder.module(m), &session.graph, &session.interner);
            defer gpa.free(bytes);
            try writer.add(gpa, .edges, key, bytes);
        }
    }
}

/// A program constructor or a placement of the chain's lowering
/// (`Lowerer.programConstructorOf`, `Lowerer.placementOf`): the module and
/// value a mention names.
const ProgramName = struct { module: []const u8, name: []const u8 };

/// Every core and platform module's development text, split in the units a
/// join splices, under both `--schema-library` answers (`js/EmitPack.zig`;
/// `backend.md` §9, *The embedded modules' printed text, in the pack*). One
/// row per option, and no row at all for a module the maker refuses
/// (`fast-compiler.md` §8, *a module with a codec plan has no row to
/// require*): the completeness check asks the same `refuses` question
/// before it demands one.
///
/// **Rows made, not read.** Every build still lowers and prints every
/// module; what the rows hold is proved by making them — each one is
/// decoded and joined back, and the join must reproduce the text it came
/// from, byte for byte, mark for mark, name for name.
fn addEmit(
    gpa: Allocator,
    stderr: *Io.Writer,
    session: *Session,
    writer: *Pack.Writer,
    made: []const u8,
    chain: ?*const platform.Chain,
    what: []const u8,
) error{ OutOfMemory, Reported }!void {
    var keep_state: std.heap.ArenaAllocator = .init(gpa);
    defer keep_state.deinit();
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const keep = keep_state.allocator();
    const scratch = scratch_state.allocator();
    const earlier = Pack.Pack.init(made);

    // Every module's `Bir`, and the world the maker lowers in: one
    // computation per run, as Emit's are per build.
    const count = session.graph.count();
    const birs = try keep.alloc(*const Bir, count);
    for (0..count) |i| {
        const m: Graph.Index = @fromBackingInt(@intCast(i));
        birs[i] = session.artifacts.bir(session.graph.moduleFile(m));
    }

    var mk: Maker = .{
        .gpa = gpa,
        .stderr = stderr,
        .session = session,
        .write = writer,
        .keep = keep,
        .scratch = scratch,
        .what = what,
        .live = try canonicalLive(keep, session, birs),
        .birs = birs,
        .core_private = if (session.graph.lookup(.core, InternPool.WellKnown.List.symbol())) |list|
            Lower.corePrivateDeclared(session.artifacts.bir(session.graph.moduleFile(list)))
        else
            @splat(true),
        .schemas = .{
            .graph = &session.graph,
            .plans = session.checked.plans,
            .birs = birs,
            .interfaces = session.resolution.interfaces,
            .provenance = session.resolution.provenance,
            .interner = &session.interner,
        },
        .calls = try programCalls(keep, chain),
    };

    // The last write to the session's pool until every module is lowered,
    // as in a build: from here the lowering reads the pool and writes only
    // its own overlay.
    try Lower.internFixedNames(gpa, &session.interner);

    for (0..count) |i| {
        const m: Graph.Index = @fromBackingInt(@intCast(i));
        if (session.graph.modulePackage(m) == .app or !session.keys.isCacheable(m)) continue;
        const module_key = session.keys.of(m);
        // Both options' rows, or neither: a module an earlier run made rows
        // for is not made again (`check`'s "One run per chain").
        var complete = true;
        for (EmitPack.every_options) |options| {
            if (earlier.find(.emit, EmitPack.key(module_key, options)) == null) complete = false;
        }
        if (complete) continue;
        try mk.moduleRow(m, module_key);
        _ = scratch_state.reset(.retain_capacity);
    }
}

/// `addEmit`'s state for one run: the session after its checks, the world
/// every module is lowered in (`backend.md` §9, *The maker*) and what does
/// not change from module to module.
const Maker = struct {
    gpa: Allocator,
    stderr: *Io.Writer,
    session: *Session,
    write: *Pack.Writer,
    /// Alive for the whole run: the survivor sets, the `Bir`s and the
    /// program names.
    keep: Allocator,
    /// One module at a time, reset after each: the lowering, the printing,
    /// the records and the row's texts.
    scratch: Allocator,
    what: []const u8,
    live: Reach.Result,
    birs: []const *const Bir,
    core_private: Lower.CorePrivate,
    schemas: SchemaGraph,
    calls: []const ProgramName,

    /// What `checkRow` can find wrong. Every one but `OutOfMemory` is a
    /// defect of the maker's own machinery, to fix here.
    const RowError = error{ OutOfMemory, Unreadable, Text, Marks, Names };

    /// One module's row (`backend.md` §9, *The maker*): a module the maker
    /// refuses has no row at all; every other one is lowered with the
    /// canonical facts, printed in its pieces, split and checked by joining
    /// it back — then written under both options.
    fn moduleRow(mk: *Maker, m: Graph.Index, module_key: Key.Key) error{ OutOfMemory, Reported }!void {
        const session = mk.session;
        const file = session.graph.moduleFile(m);
        const bir = mk.birs[m.int()];
        if (refuses(session, mk.calls, m, bir)) return;
        var recorder: Funnel.Recorder = .{};
        var overlay: InternPool.Overlay = .init(&session.interner);
        defer overlay.deinit(mk.gpa);
        var lowered = Lower.lower(mk.gpa, mk.scratch, &overlay, .{
            .bir = bir,
            .birs = mk.birs,
            .provenance = session.resolution.provenance,
            .token_starts = session.artifacts.spans(file).starts,
            .module = m,
            .graph = &session.graph,
            .interfaces = session.resolution.interfaces,
            .dispatch = dispatchOf(session, m),
            .types = &session.checked.types,
            .specifiers = &.{},
            .sibling = "",
            .live = &mk.live,
            .schemas = &mk.schemas,
            .core_private = mk.core_private,
            .record = &recorder,
        }) catch |err| switch (err) {
            // A record with a hole in it: a defect in the funnel's bound,
            // not a module to ship (`Funnel.Recorder.reserve`).
            error.UnitRecordOverflow => {
                _ = fail(mk.stderr, "checking {s}, the funnel record of '{s}' overflowed", .{ mk.what, session.store.path(file) });
                return error.Reported;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer lowered.deinit(mk.gpa);
        if (lowered.diagnostics.len != 0) {
            for (lowered.diagnostics) |item| {
                _ = fail(mk.stderr, "checking {s}, lowering '{s}': {s}", .{ mk.what, session.store.path(file), item.message });
            }
            return error.Reported;
        }
        // The exact net (`backend.md` §9, *The unit list*): this module's
        // text reaches the markup runtime, so it is not cached — but a
        // module the maker refuses has no row, so the check-time scan
        // (`refuses`) must already have seen it, and one it did not is a
        // defect of that scan: fail here, where the module can be named.
        if (lowered.uses_markup_runtime) {
            _ = fail(mk.stderr, "checking {s}, the module '{s}' reaches the markup runtime, which a row cannot carry", .{ mk.what, session.store.path(file) });
            return error.Reported;
        }

        // The module's text, printed in its pieces and joined
        // (`backend.md` §9, *One `SourceMap.write`, and the marks survive*):
        // the head, one piece per unit, the tail. The units cover every
        // statement between the head and the tail.
        const names: Print.Names = .fromOverlay(&overlay);
        var context = try Print.Context.init(mk.scratch, &lowered.ir, names, lowered.unobserved, true);
        const body = context.bodyLen();
        var pieces: std.ArrayList(Join.Piece) = .empty;
        try pieces.ensureTotalCapacity(mk.scratch, lowered.units.len + 2);
        pieces.appendAssumeCapacity(try context.printRange(0, lowered.head_len));
        var builder: EmitPack.Builder = .init(mk.gpa);
        defer builder.deinit();
        builder.flags = .{
            .eq_prim = lowered.comparators & 1 != 0,
            .compare_prim = lowered.comparators & 2 != 0,
            .compare_char = lowered.comparators & 4 != 0,
            .compare_key = lowered.comparators & 8 != 0,
        };
        var runtime: u8 = 0;
        var covered = lowered.head_len;
        for (lowered.units) |unit| {
            std.debug.assert(unit.start == covered);
            covered = unit.end;
            std.debug.assert(unit.record != Funnel.no_record);
            const record = &recorder.units.items[unit.record];
            const numbered = context.names_out.items.len;
            const piece = try context.printRange(unit.start, unit.end);
            pieces.appendAssumeCapacity(piece);
            runtime |= record.runtime;
            try builder.addUnit(try mk.rowUnit(m, &builder, &context, &overlay, &recorder, record, piece, numbered), piece.text);
        }
        std.debug.assert(covered == body - lowered.tail_len);
        pieces.appendAssumeCapacity(try context.printRange(body - lowered.tail_len, body));
        const natural = try Join.join(mk.gpa, mk.scratch, pieces.items, "");
        defer mk.gpa.free(natural.text);
        // A module's flags are its units' or (`backend.md` §9, *The
        // funnel*): a runtime export reached outside any unit would be one
        // no row can carry.
        std.debug.assert((runtime != 0) == lowered.uses_runtime);
        builder.flags.deep = runtime & EmitPack.runtime_deep != 0;
        builder.flags.list_eq = runtime & EmitPack.runtime_list_eq != 0;
        builder.flags.list_compare = runtime & EmitPack.runtime_list_compare != 0;
        const bytes = try builder.encode(mk.gpa);
        defer mk.gpa.free(bytes);
        mk.checkRow(bytes, natural, pieces.items[0], pieces.items[pieces.items.len - 1], &lowered.ir, &overlay, context.names_src.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                _ = fail(mk.stderr, "checking {s}, the row of '{s}' does not join back ({t})", .{ mk.what, session.store.path(file), err });
                return error.Reported;
            },
        };
        for (EmitPack.every_options) |options| {
            try mk.write.add(mk.gpa, .emit, EmitPack.key(module_key, options), bytes);
        }
    }

    /// The row's unit for `record` and the piece just printed
    /// (`backend.md` §9, *What a unit carries*): the selector the funnel
    /// was opened with, the marks — with the identity behind each name the
    /// printer numbered — the identities the unit introduced, the imports
    /// it asked for, the facts it read, the runtime exports it reached and
    /// its edges.
    fn rowUnit(
        mk: *Maker,
        m: Graph.Index,
        builder: *EmitPack.Builder,
        context: *const Print.Context,
        overlay: *const InternPool.Overlay,
        recorder: *const Funnel.Recorder,
        record: *const Funnel.UnitRecord,
        piece: Join.Piece,
        numbered: usize,
    ) Allocator.Error!EmitPack.Unit {
        const scratch = mk.scratch;
        // The identities the printer numbered while printing this unit:
        // `Print.Context.names_src` is `names_out`'s source column, in the
        // same order.
        const introduced = try scratch.alloc(u32, context.names_src.items.len - numbered);
        for (introduced, context.names_src.items[numbered..]) |*slot, index| {
            slot.* = try mk.ident(builder, context.ir, overlay, index);
        }
        const marks = try scratch.alloc(EmitPack.Mark, piece.mappings.len);
        for (marks, piece.mappings) |*mark, mapping| {
            mark.* = .{
                .generated = mapping.generated,
                .source = mapping.source,
                .name = if (mapping.name == SourceMap.Mapping.no_name)
                    EmitPack.no_name
                else
                    try mk.ident(builder, context.ir, overlay, context.names_src.items[mapping.name]),
            };
        }
        const needed = try scratch.alloc(EmitPack.Needed, record.asks_end - record.asks_start);
        for (needed, record.asks(recorder)) |*need, ask| {
            need.* = .{
                .module = try mk.moduleRef(builder, m, @fromBackingInt(@intCast(ask.module))),
                .value = ask.value,
                .base = if (ask.base.unwrap()) |symbol| try mk.text(builder, overlay.slice(symbol)) else EmitPack.no_string,
            };
        }
        const facts = try scratch.alloc(EmitPack.Fact, record.facts_end - record.facts_start);
        for (facts, record.facts(recorder)) |*fact, asked| {
            fact.* = asked;
            fact.module = try mk.moduleRef(builder, m, @fromBackingInt(@intCast(asked.module)));
        }
        return .{
            .selector = record.selector,
            .marks = marks,
            .introduced = introduced,
            .needed = needed,
            .facts = facts,
            .runtime = record.runtime,
            .edges = record.edges,
        };
    }

    /// The row's identity slot for the printer's name `index`
    /// (`js/JsIr.Name`): its module part, base and tag, with the texts
    /// interned in the row's string table.
    fn ident(mk: *Maker, builder: *EmitPack.Builder, ir: *const JsIr, overlay: *const InternPool.Overlay, index: u32) Allocator.Error!u32 {
        const name = ir.name(@fromBackingInt(@intCast(index)));
        return builder.internIdent(.{
            .module = if (name.module.unwrap()) |symbol| try mk.text(builder, overlay.slice(symbol)) else EmitPack.no_string,
            .base = try mk.text(builder, overlay.slice(name.base)),
            .tag = name.tag,
        });
    }

    /// A row string: a stable copy in this module's scratch, interned in the
    /// row's table (an interned text must be stable until `encode`).
    fn text(mk: *Maker, builder: *EmitPack.Builder, bytes: []const u8) Allocator.Error!u32 {
        return builder.internString(try mk.scratch.dupe(u8, bytes));
    }

    /// The row's module reference for graph module `other`
    /// (`EmitPack.Needed.module`): 0 is this module, `k + 1` the slot of
    /// `modules[k]`.
    fn moduleRef(mk: *Maker, builder: *EmitPack.Builder, m: Graph.Index, other: Graph.Index) Allocator.Error!u32 {
        if (other == m) return EmitPack.self_slot;
        const name = try mk.text(builder, mk.session.interner.slice(mk.session.graph.moduleName(other)));
        return (try builder.internModule(mk.session.graph.modulePackage(other), name)) + 1;
    }

    /// The maker's self-check (`backend.md` §9, *The maker*): decode the row
    /// just written and join it back — the head and the tail as printed,
    /// the units' bytes, marks and names — and require the text and every
    /// mark to be the module's own, byte for byte and entry for entry.
    fn checkRow(
        mk: *Maker,
        bytes: []const u8,
        natural: Join.Joined,
        head: Join.Piece,
        tail: Join.Piece,
        ir: *const JsIr,
        overlay: *const InternPool.Overlay,
        identities: []const u32,
    ) RowError!void {
        const scratch = mk.scratch;
        const row = (try EmitPack.decode(scratch, bytes)) orelse return error.Unreadable;
        var pieces: std.ArrayList(Join.Piece) = .empty;
        try pieces.ensureTotalCapacity(scratch, row.units.len + 2);
        pieces.appendAssumeCapacity(head);
        // The replay's name list: the row's idents in the order the printer
        // first numbered them, the mirror of `names_out`/`names_src`.
        var names: std.ArrayList(u32) = .empty;
        for (row.units) |unit| {
            for (unit.introduced) |slot| {
                var seen = false;
                for (names.items) |other| seen = seen or other == slot;
                if (!seen) try names.append(scratch, slot);
            }
            const marks = try scratch.alloc(SourceMap.Mapping, unit.marks.len);
            for (marks, unit.marks) |*mark, encoded| {
                mark.* = .{
                    .generated = encoded.generated,
                    .source = encoded.source,
                    .name = if (encoded.name == EmitPack.no_name)
                        SourceMap.Mapping.no_name
                    else
                        indexOf(names.items, encoded.name) orelse return error.Names,
                };
            }
            try pieces.append(scratch, .{ .text = row.text[unit.start..][0..unit.len], .mappings = marks });
        }
        try pieces.append(scratch, tail);
        const again = try Join.join(mk.gpa, scratch, pieces.items, "");
        defer mk.gpa.free(again.text);
        if (!std.mem.eql(u8, again.text, natural.text)) return error.Text;
        if (again.mappings.len != natural.mappings.len) return error.Marks;
        for (again.mappings, natural.mappings) |a, n| {
            if (a.generated != n.generated or a.source != n.source or a.name != n.name) return error.Marks;
        }
        // And the identities themselves: the replay's list is
        // `context.names_src`'s, entry for entry.
        if (names.items.len != identities.len) return error.Names;
        for (names.items, identities) |slot, index| {
            const encoded = row.idents[slot];
            const name = ir.name(@fromBackingInt(@intCast(index)));
            if (encoded.tag != name.tag) return error.Names;
            if (!std.mem.eql(u8, row.strings[encoded.base], overlay.slice(name.base))) return error.Names;
            const module: ?[]const u8 = if (name.module.unwrap()) |symbol| overlay.slice(symbol) else null;
            if ((encoded.module == EmitPack.no_string) != (module == null)) return error.Names;
            if (module) |wanted| {
                if (!std.mem.eql(u8, row.strings[encoded.module], wanted)) return error.Names;
            }
        }
    }
};

/// The program constructors and placements of the chain's lowering
/// (`Lowerer.programConstructorOf`, `Lowerer.placementOf`), by module text
/// and name: a module that names one of these is not cached. Read by name,
/// because the maker's root cannot name the lowering's type — `build.zig`
/// gives it `beni` and nothing else.
fn programCalls(allocator: Allocator, chain: ?*const platform.Chain) Allocator.Error![]const ProgramName {
    var calls: std.ArrayList(ProgramName) = .empty;
    if (chain) |c| {
        if (c.firstMarkup("lowering")) |found| {
            if (Emit.findLowering(found.value)) |lowering| {
                for (lowering.programs) |p| try calls.append(allocator, .{ .module = p.module, .name = p.name });
                for (lowering.placements) |p| try calls.append(allocator, .{ .module = p.module, .name = p.name });
            }
        }
    }
    return calls.items;
}

/// Whether the maker refuses a module (`backend.md` §9, *The unit list* and
/// its refusals): a module that writes markup, that names a program
/// constructor or a placement of the chain's lowering, or that declares a
/// schema or owns a derived codec plan — machinery whose reads are not all
/// in the funnel, or whose units `emissionOrder` orders after the last
/// declaration. A refused module has no row at all, and `check` asks this
/// same question when it decides which modules must have one.
/// (`Lower.Result.uses_markup_runtime` is the second, exact net, after the
/// lowering has had its say.)
fn refuses(session: *const Session, calls: []const ProgramName, m: Graph.Index, bir: *const Bir) bool {
    if (bir.uses_markup) return true;
    for (bir.decls) |decl| {
        if (decl.kind == .schema) return true;
    }
    if (m.int() < session.checked.plans.len and session.checked.plans[m.int()].codecs.len != 0) return true;
    if (calls.len == 0) return false;
    const tags = bir.insts.items(.tag);
    for (bir.decls) |decl| {
        if (!decl.kind.isValue()) continue;
        var at = decl.inst_start.int();
        while (at < decl.inst_end.int()) : (at += 1) {
            if (tags[at] != .ext_value and tags[at] != .top) continue;
            const named = platformValue(session, m, bir, at) orelse continue;
            for (calls) |call| {
                if (std.mem.eql(u8, call.module, named.module) and std.mem.eql(u8, call.name, named.name)) return true;
            }
        }
    }
    return false;
}

/// The platform value instruction `at` names (`Lowerer.platformValue`,
/// whose `.ext_value` and `.top` are the two shapes a program constructor or
/// a placement is spelled in): its module's text and its own.
fn platformValue(session: *const Session, m: Graph.Index, bir: *const Bir, at: u32) ?ProgramName {
    const tags = bir.insts.items(.tag);
    const data = bir.insts.items(.data);
    switch (tags[at]) {
        .ext_value => {
            const other: Graph.Index = @fromBackingInt(@intCast(data[at].lhs));
            if (other.int() >= session.resolution.interfaces.len) return null;
            if (session.graph.modulePackage(other) != .platform) return null;
            const iface = &session.resolution.interfaces[other.int()];
            if (data[at].rhs >= iface.values.len) return null;
            const value = iface.values[data[at].rhs];
            return .{
                .module = session.interner.slice(session.graph.moduleName(other)),
                .name = session.interner.slice(iface.symbols[@backingInt(value.name)]),
            };
        },
        .top => {
            if (session.graph.modulePackage(m) != .platform) return null;
            if (data[at].lhs >= bir.decls.len) return null;
            const decl = bir.decls[data[at].lhs];
            return .{
                .module = session.interner.slice(session.graph.moduleName(m)),
                .name = session.interner.slice(bir.symbol(decl.name)),
            };
        },
        else => return null,
    }
}

/// The survivor sets of the world the maker lowers in (`backend.md` §9,
/// *The maker*): every declaration, twin, derived row, constructor and
/// schema member live. A build's own walk may keep fewer, and the units
/// whose questions it answers differently are the ones it lowers itself.
/// Lifts stay empty: only a direct build has them and the maker has no
/// handle. The runtime exports and comparator flags a module needs are read
/// through the funnel and recorded per unit; they need no set.
fn canonicalLive(arena: Allocator, session: *const Session, birs: []const *const Bir) Allocator.Error!Reach.Result {
    const count = session.graph.count();
    const modules = try arena.alloc(Reach.Live, count);
    const dispatch = try arena.alloc(*const Dispatch, count);
    for (modules, 0..) |*live, i| {
        const m: Graph.Index = @fromBackingInt(@intCast(i));
        const table = dispatchOf(session, m);
        const codecs = if (m.int() < session.checked.plans.len) session.checked.plans[m.int()].codecs.len else 0;
        dispatch[i] = table;
        live.* = .{
            .decls = try every(arena, birs[i].decls.len),
            .derived = try every(arena, table.derived.len),
            .twins = try every(arena, birs[i].decls.len),
            .ctors = try every(arena, birs[i].ctors.len),
            .schemas = try every(arena, (birs[i].decls.len + codecs) * SchemaGraph.Member.count),
        };
    }
    return .{
        .modules = modules,
        .provenance = session.resolution.provenance,
        .dispatch = dispatch,
    };
}

/// A survivor set with every member of `len` live.
fn every(arena: Allocator, len: usize) Allocator.Error!std.DynamicBitSetUnmanaged {
    var set = try std.DynamicBitSetUnmanaged.initEmpty(arena, len);
    for (0..len) |at| set.set(at);
    return set;
}

/// The module's dispatch table (`Emit.dispatchOf`), or the empty one.
fn dispatchOf(session: *const Session, m: Graph.Index) *const Dispatch {
    if (m.int() >= session.checked.dispatch.len) return &Dispatch.empty;
    return &session.checked.dispatch[m.int()];
}

/// The index of `value` in `items`, or null.
fn indexOf(items: []const u32, value: u32) ?u32 {
    for (items, 0..) |item, i| {
        if (item == value) return @intCast(i);
    }
    return null;
}

/// The row of `build.zig`'s platform table for the platform `name`, whose
/// files `build.zig` staged under `dir`: its `beni.json`, its `.beni`
/// modules and its other files, each relative path as that table spells it.
fn readPlatform(arena: Allocator, io: Io, name: []const u8, root: []const u8, dir: []const u8) !platform.Embedded {
    var rels: std.ArrayList([]const u8) = .empty;
    try collect(arena, io, dir, "", &rels);
    std.mem.sort([]const u8, rels.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    var files: std.ArrayList(platform.EmbeddedFile) = .empty;
    var assets: std.ArrayList(platform.EmbeddedAsset) = .empty;
    var manifest: ?[]const u8 = null;
    var handle = try Io.Dir.cwd().openDir(io, dir, .{});
    defer handle.close(io);
    for (rels.items) |rel| {
        const bytes = try beni.fs_read.readFileSentinel(io, handle, rel, arena, .limited(1 << 26));
        if (std.mem.eql(u8, rel, "beni.json")) {
            manifest = bytes;
        } else if (std.mem.endsWith(u8, rel, ".beni")) {
            try files.append(arena, .{ .rel = rel, .source = bytes });
        } else {
            try assets.append(arena, .{ .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel }), .bytes = bytes });
        }
    }
    return .{
        .name = name,
        .root = root,
        .manifest = manifest orelse return error.NoManifest,
        .files = files.items,
        .assets = assets.items,
    };
}

fn collect(arena: Allocator, io: Io, root: []const u8, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    const full = if (prefix.len == 0) root else try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, prefix });
    var handle = try Io.Dir.cwd().openDir(io, full, .{ .iterate = true });
    defer handle.close(io);
    var it = handle.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const rel = if (prefix.len == 0) try arena.dupe(u8, entry.name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .directory => try collect(arena, io, root, rel, out),
            .file, .sym_link => try out.append(arena, rel),
            else => {},
        }
    }
}

fn fail(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    stderr.print("core_pack: " ++ fmt ++ "\n", args) catch {};
    return 1;
}
