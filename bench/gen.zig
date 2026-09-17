//! Deterministic synthetic-corpus generator (docs/design/frontend.md §5).
//!
//! Writes a project of roughly `target_lines` lines whose shape follows real
//! Elm code — module docs, a few imports, a record alias, a custom type,
//! `init`/`update`/`view`-style functions, mostly small helpers, some large
//! `case`, records, pipelines, lambdas, interpolated and multiline strings —
//! in the language of docs/design/language.md, so the M1 front end runs over
//! it clean. The §2 performance budget is stated against this corpus, so it
//! must be honest: every construct here is one the grammar (§3) and the
//! layout rules (§4) accept, and nothing here shadows, duplicates or leaves a
//! name unbound (§5–§7).
//!
//! **Type-correct by construction** (checker.md §9): the `check` line of the
//! benchmark measures inference, and a generated corpus full of type errors
//! would measure the error path instead. Every random expression this
//! produces has type `Int`, every call is saturated, every `if` condition is
//! a comparison, and every record literal sets exactly the fields its alias
//! declares. A type error in the generated corpus is a generator bug.
//!
//! Determinism: module `i` is a pure function of `(seed, i)`, so the same
//! seed and size always produce byte-identical files, and the bench can
//! regenerate rather than check the tree in. Layout is close to the
//! formatter's canonical style (§9) but deliberately not identical: `fmt
//! --check` over the generated tree therefore exercises the compare-and-list
//! path rather than the all-canonical shortcut, which is the more useful
//! benchmark. Do not "fix" this without replacing that coverage.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_seed: u64 = 0xBE21;

/// Which shape the many-small-files corpus is written in.
///
/// `dispatch` is the C1 corpus of `plans/static-dispatch-spike.md` §7: the
/// SAME project — same module count, same paths, same declaration names —
/// with the operations that static dispatch changes written the way
/// `docs/design/static-dispatch-spike.md` spells them. Every `§` below is a
/// section of THAT document; the `M` rows are the plan's §7. Every random draw is made in the same order in
/// both modes (a mode that skips a draw renames every later declaration),
/// so the only difference between the two trees is the text of the
/// declarations dispatch touches, and M1b compares like with like.
///
/// What changes, and which row of §7 each part feeds:
///
///   - `helper<i>` takes its module's `Msg<i>` as its first parameter, so
///     every call to it is a method call `(Reset).helper<i> n` (§1) —
///     including the cross-module ones, `(P<k>.Reset).helper<k> n`, which
///     is §1.1's `M.v.m a` row and the implicit graph edge of §6.8. The
///     receiver is a NOMINAL type on purpose: §1.2 looks a `type alias`
///     through to its expansion, so a record alias like `Model<i>` would
///     make every one of these a field call, not a method call.
///   - one declaration in four is a CONSTRAINED helper: annotated with a
///     §2 `where` clause when the plain declaration would have been
///     annotated, and otherwise unannotated with the same constraint
///     INFERRED from a method call in its body (§6.4's promotion). Its
///     visibility and its annotated-ness are the plain mode's, because
///     writing the interface is what the `check` line is most sensitive to.
///   - those helpers are CALLED: at a concrete type, where the evidence
///     argument is supplied (§8.1), and from inside another constrained
///     helper, where it is forwarded (§8.2). A constrained declaration
///     nobody calls exercises only half the feature.
///   - `==` is used on a record (`model == init<i>`) and on a custom type
///     (`msg == Reset`), the two derived-`eq` shapes of §3 and §9. The
///     operators are how derivation is reached at all: §1.3 rule 2 lets
///     only an operator-marked call derive.
///   - one module in sixteen builds a `Dict` and a `Set` with **no**
///     comparator argument (§5.3), through method calls `acc.insert k v`.
///
/// **The dispatch tree does not parse until S2 lands the `where` clause.**
/// The dot-call form already parses (§1.1: `x.m a` needs no grammar
/// change), so what stops it today is the annotations, not the calls. It is
/// generated now so the harness, the baselines and the file-list comparison
/// are in place before the language changes under them.
pub const Mode = enum { plain, dispatch };

pub const Stats = struct {
    files: u32,
    lines: u64,
    bytes: u64,
};

/// Generate under `out_dir` (created if missing) until at least
/// `target_lines` lines exist. Modules are written as `Gen/…/<Name>.beni`.
pub fn generate(gpa: Allocator, io: Io, out_dir: []const u8, seed: u64, target_lines: u64) !Stats {
    return generateMode(gpa, io, out_dir, seed, target_lines, .plain);
}

/// `generate` in a chosen `Mode`.
///
/// The module COUNT is always the plain mode's count, even in `dispatch`:
/// the two trees must hold the same files or M1b compares a 623-module
/// corpus against a 624-module one and reports the difference as a cost of
/// the feature. Counting is a second pass of the plain generator into a
/// discarding writer — cheap next to writing the files, and the only way to
/// know the boundary without letting the dispatch tree's own line count
/// move it.
pub fn generateMode(gpa: Allocator, io: Io, out_dir: []const u8, seed: u64, target_lines: u64, mode: Mode) !Stats {
    var root = try Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer root.close(io);
    try root.createDirPath(io, "Gen/Data");
    try root.createDirPath(io, "Gen/Ui");

    const count = try moduleCount(seed, target_lines);
    var stats: Stats = .{ .files = 0, .lines = 0, .bytes = 0 };
    var buffer: Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        buffer.clearRetainingCapacity();
        const lines = try writeModuleMode(&buffer.writer, seed, index, mode);
        var path_buf: [64]u8 = undefined;
        const rel = modulePath(&path_buf, index);
        try root.writeFile(io, .{ .sub_path = rel, .data = buffer.written() });
        stats.files += 1;
        stats.lines += lines;
        stats.bytes += buffer.written().len;
    }
    return stats;
}

/// How many modules the PLAIN generator needs to reach `target_lines`. The
/// file list of every mode is this many modules, in `modulePath` order.
pub fn moduleCount(seed: u64, target_lines: u64) !u32 {
    var discard: Io.Writer.Discarding = .init(&.{});
    var lines: u64 = 0;
    var index: u32 = 0;
    while (lines < target_lines or index == 0) : (index += 1) {
        lines += try writeModule(&discard.writer, seed, index);
    }
    return index;
}

// ---------------------------------------------------------------------------
// The wide shape: one very large module
// ---------------------------------------------------------------------------

/// How `generateWide` spends a declaration budget. Every field is a pure
/// function of `declarations`, so the proportions are fixed and the
/// README's trend line compares like with like across sizes.
///
/// The split exists because the costs it is aimed at are *per module*,
/// and each needs a different quantity to be large. Each part below names
/// the pass whose cost it drives and the quantity that drives it; the
/// point is to make every one of these a term the trend line can see, so
/// that a pass which is linear in it today and quadratic in it tomorrow
/// shows up as a bend rather than as a bug report.
///
///   - `simple` — many `pub` VALUES in one module, which is what
///     `Check.fillInterface` pays per exported value against the module's
///     declaration list. Every declaration the shape writes is `pub`: the
///     same module without `pub` was two orders of magnitude cheaper.
///   - `simple` again — many INDEPENDENT declarations, which is what
///     `Check.bindingGroups` → `Constrain.sccGroups` pays per component.
///     Nothing here is mutually recursive, so the component count IS the
///     declaration count, which is the worst case for that pass.
///   - `chain` — a long DEPENDENCY CHAIN between types, whose last link is
///     a function type (the one thing that makes an alias not equatable).
///     A chain is what separates a worklist from a re-scanning fixpoint in
///     `Types.settleEquatable`: with it, "settled" has to travel `chain`
///     steps.
///   - `width` — WIDE records rather than many of them, because the
///     record-literal and record-update field lookups in `Constrain` cost
///     per field of the same literal. `width` grows with the budget and
///     `builders` does not, so the record term moves with `width` alone.
pub const WideShape = struct {
    /// Fields in the `Wide` alias, and so in every literal and update over
    /// it. Floored at the 100 the review asked for and capped at 800,
    /// which is the widest record the quadratic was ever measured at;
    /// past that the file is mostly one record.
    width: u32,
    /// How many functions build a `Wide`, and how many update one. Fixed,
    /// so that the record line of the trend moves with `width` alone.
    builders: u32,
    /// Links in the `type alias` chain.
    chain: u32,
    /// Plain `pub` one-liners: whatever is left of the budget.
    simple: u32,

    pub const builder_count: u32 = 20;
    pub const min_width: u32 = 100;
    pub const max_width: u32 = 800;
    pub const min_chain: u32 = 8;
    pub const max_chain: u32 = 2000;

    /// Declarations that are neither `simple` nor builders nor chain
    /// links: the `Wide` alias and the `apply` that keeps the chain from
    /// being dead code.
    const fixed: u32 = 2;

    pub fn init(declarations: u32) WideShape {
        const width = std.math.clamp(declarations / 20, min_width, max_width);
        const chain = std.math.clamp(declarations / 10, min_chain, max_chain);
        const spoken_for = 2 * builder_count + chain + fixed;
        return .{
            .width = width,
            .builders = builder_count,
            .chain = chain,
            .simple = declarations -| spoken_for,
        };
    }

    /// The smallest module the shape can write: the builders, the
    /// shortest chain and the two fixed declarations. A `--wide=` below
    /// this gets this.
    pub const floor: u32 = 2 * builder_count + min_chain + fixed;

    /// Total `pub` declarations the shape actually writes: `declarations`
    /// once the budget covers `floor`, and `floor` below that.
    pub fn total(shape: WideShape) u32 {
        return shape.simple + 2 * shape.builders + shape.chain + fixed;
    }
};

/// Generate the wide corpus under `out_dir` (created if missing): one
/// module of `declarations` `pub` declarations, plus a small consumer so
/// the interface that module exports is one somebody actually pays for.
///
/// This is the second shape, and it exists because the first one cannot
/// see what it is for. `generate` writes hundreds of ~160-line modules,
/// which is the right shape for throughput per byte and the wrong one for
/// anything quadratic in a single module's declaration count: 624 small
/// files hold the per-module terms flat no matter how big the project
/// gets. See `WideShape` for which cost each part of the budget is aimed
/// at.
///
/// Type-correct by construction, like `generate`: every value here is an
/// `Int`, every call is saturated, every record literal sets exactly the
/// `width` fields `Wide` declares, and every update names only fields the
/// base has. `beni check` on the output must exit 0 with no diagnostics; a
/// diagnostic is a generator bug.
/// The one big module, and the small consumer that imports it. Both path
/// segments are upper identifiers, so both files have a module name
/// (language.md §1).
pub const wide_bulk_path = "Wide/Bulk.beni";
pub const wide_main_path = "Wide/Main.beni";

pub fn generateWide(gpa: Allocator, io: Io, out_dir: []const u8, seed: u64, declarations: u32) !Stats {
    var root = try Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer root.close(io);
    try root.createDirPath(io, "Wide");

    var buffer: Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    var stats: Stats = .{ .files = 0, .lines = 0, .bytes = 0 };
    const shape: WideShape = .init(declarations);

    // Mixed with a constant of its own so `--wide` and `--generate` at the
    // same seed do not draw the same stream; the two corpora are unrelated.
    var prng: std.Random.DefaultPrng = .init(seed ^ 0x5749_4445_0000_0001);
    var g: Wide = .{ .w = &buffer.writer, .rng = prng.random(), .shape = shape };
    try g.bulk();
    try root.writeFile(io, .{ .sub_path = wide_bulk_path, .data = buffer.written() });
    stats.files += 1;
    stats.lines += g.lines;
    stats.bytes += buffer.written().len;

    buffer.clearRetainingCapacity();
    var m: Wide = .{ .w = &buffer.writer, .rng = prng.random(), .shape = shape };
    try m.main();
    try root.writeFile(io, .{ .sub_path = wide_main_path, .data = buffer.written() });
    stats.files += 1;
    stats.lines += m.lines;
    stats.bytes += buffer.written().len;
    return stats;
}

/// The wide module's generator. It keeps none of `Module`'s scope
/// bookkeeping — nothing here binds a local whose name could collide with
/// a sibling — so it is its own struct rather than a mode of that one; all
/// it needs is the writer, the line count the bench reports, and the
/// shape.
const Wide = struct {
    w: *Io.Writer,
    rng: std.Random,
    shape: WideShape,
    lines: u64 = 0,

    fn line(g: *Wide, indent: usize, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
        try g.w.splatByteAll(' ', indent);
        try g.w.print(fmt, args);
        try g.w.writeByte('\n');
        g.lines += 1;
    }

    fn blank(g: *Wide) Io.Writer.Error!void {
        try g.w.writeByte('\n');
        g.lines += 1;
    }

    fn declGap(g: *Wide) Io.Writer.Error!void {
        try g.blank();
        try g.blank();
    }

    /// A small constant, so two runs at the same seed and size are
    /// byte-identical but the literals are not all the same digit.
    fn konst(g: *Wide) u32 {
        return g.rng.uintLessThan(u32, 100);
    }

    // ---- Wide.Bulk ------------------------------------------------------

    fn bulk(g: *Wide) Io.Writer.Error!void {
        try g.line(0, "--! Wide.Bulk: {d} pub declarations and {d}-field records in ONE module.", .{ g.shape.total(), g.shape.width });
        try g.line(0, "--! Generated by bench/gen.zig; the per-module costs the many-small-files", .{});
        try g.line(0, "--! corpus cannot see. See `WideShape` for which cost each part is aimed at.", .{});
        try g.declGap();

        try g.wideAlias();
        try g.declGap();
        try g.aliasChain();
        try g.declGap();
        try g.applyFn();
        var i: u32 = 0;
        while (i < g.shape.builders) : (i += 1) {
            try g.declGap();
            try g.builderFn(i);
            try g.declGap();
            try g.updateFn(i);
        }
        i = 0;
        while (i < g.shape.simple) : (i += 1) {
            try g.declGap();
            try g.simpleFn(i);
        }
    }

    /// `{ f0 : Int, …, f{width-1} : Int }`, one field per line with the
    /// leading commas the layout rules want (language.md §4).
    fn wideAlias(g: *Wide) Io.Writer.Error!void {
        try g.line(0, "--| The record every builder below sets every field of.", .{});
        try g.line(0, "pub type alias Wide =", .{});
        try g.line(4, "{{ f0 : Int", .{});
        var i: u32 = 1;
        while (i < g.shape.width) : (i += 1) try g.line(4, ", f{d} : Int", .{i});
        try g.line(4, "}}", .{});
    }

    /// `Chain0 = Chain1`, …, `Chain{n-1} = Int -> Int`.
    ///
    /// The direction matters, and so does writing them in this order.
    /// Every type starts out optimistically equatable and turns false only
    /// once the type it names has, so putting the function type LAST means
    /// "false" has to travel the whole chain against the order the table
    /// is scanned in — `chain` steps, each of which a fixpoint that
    /// re-scans pays for over every type in the program. Put the function
    /// type first and the same chain settles in a single pass, which
    /// measures nothing.
    fn aliasChain(g: *Wide) Io.Writer.Error!void {
        var i: u32 = 0;
        while (i < g.shape.chain) : (i += 1) {
            if (i != 0) try g.declGap();
            try g.line(0, "pub type alias Chain{d} =", .{i});
            if (i + 1 == g.shape.chain) {
                try g.line(4, "Int -> Int", .{});
            } else {
                try g.line(4, "Chain{d}", .{i + 1});
            }
        }
    }

    /// Uses the chain, so it is reachable from a value and not a run of
    /// dead type declarations a checker could in principle skip.
    ///
    /// It names the LAST link and not `Chain0` on purpose. Expanding
    /// `Chain0` walks every link, and a written type may not nest more
    /// than 512 deep — so at `--wide=5120` and up the annotation would be
    /// `nesting_too_deep` and the corpus would stop checking clean, which
    /// is a generator bug (see the header). The last link expands in one
    /// step at every size, and the chain is what `settleEquatable` walks
    /// whether or not a value names its head.
    fn applyFn(g: *Wide) Io.Writer.Error!void {
        try g.line(0, "pub apply : Chain{d}, Int -> Int", .{g.shape.chain - 1});
        try g.line(0, "apply f n =", .{});
        try g.line(4, "f n", .{});
    }

    fn builderFn(g: *Wide, n: u32) Io.Writer.Error!void {
        try g.line(0, "pub wideOf{d} : Int -> Wide", .{n});
        try g.line(0, "wideOf{d} n =", .{n});
        try g.line(4, "{{ f0 = n + {d}", .{g.konst()});
        var i: u32 = 1;
        while (i < g.shape.width) : (i += 1) try g.line(4, ", f{d} = n + {d}", .{ i, g.konst() });
        try g.line(4, "}}", .{});
    }

    fn updateFn(g: *Wide, n: u32) Io.Writer.Error!void {
        try g.line(0, "pub bump{d} : Wide -> Wide", .{n});
        try g.line(0, "bump{d} w =", .{n});
        try g.line(4, "{{ w", .{});
        try g.line(8, "| f0 = w.f0 + {d}", .{g.konst()});
        var i: u32 = 1;
        while (i < g.shape.width) : (i += 1) try g.line(8, ", f{d} = w.f{d} + {d}", .{ i, i, g.konst() });
        try g.line(4, "}}", .{});
    }

    /// One plain `pub` declaration. Every eighth is UNANNOTATED, and the
    /// annotated ones sometimes call the nearest one: a top-level
    /// dependency edge only exists towards an unannotated value (an
    /// annotation already breaks the recursion), so without them the SCC
    /// graph would be edgeless and Tarjan would not be doing what it does
    /// in production. The references only ever point backwards, so no
    /// group is bigger than one declaration and the component count stays
    /// equal to the declaration count — which is the case that costs the
    /// most.
    fn simpleFn(g: *Wide, n: u32) Io.Writer.Error!void {
        if (n % 8 == 7) {
            try g.line(0, "pub tally{d} =", .{n});
            try g.line(4, "bulk{d} {d}", .{ n - 1, g.konst() });
            return;
        }
        try g.line(0, "pub bulk{d} : Int -> Int", .{n});
        try g.line(0, "bulk{d} n =", .{n});
        if (n >= 8 and g.rng.uintLessThan(u8, 100) < 50) {
            try g.line(4, "n + tally{d} + {d}", .{ (n / 8) * 8 - 1, g.konst() });
        } else {
            try g.line(4, "n + {d}", .{g.konst()});
        }
    }

    // ---- Wide.Main ------------------------------------------------------

    /// The consumer. `Wide.Bulk`'s interface is built whether or not
    /// anyone reads it, but a project where nothing imports the big module
    /// would not exercise cross-module resolution against it at all.
    fn main(g: *Wide) Io.Writer.Error!void {
        try g.line(0, "--! Wide.Main: reads Wide.Bulk's interface, so building it is a cost paid.", .{});
        try g.declGap();
        try g.line(0, "import Wide.Bulk as Bulk", .{});
        try g.declGap();
        try g.line(0, "pub total : Int", .{});
        try g.line(0, "total =", .{});
        try g.line(4, "(Bulk.bump0 (Bulk.wideOf0 {d})).f{d}", .{ g.konst(), g.shape.width - 1 });
    }
};

/// The abuse inputs too big to check into `bench/pathological/`
/// (the limit there is 256 KB). Each is one file, one line, and is
/// regenerated on demand by `bench --pathological=<name>` so the repository
/// does not carry ten megabytes of `1, 1, 1, …` forever.
///
/// Only `big-list` is over the 200 ms that earns a permanent place (500 ms,
/// 228 MB peak at M1d); the other three are here because they are the same
/// shape one size down and are what the next regression will be measured
/// against.
pub const Pathological = struct {
    case: Case,
    /// `constraint-chain=<n>`: how long the chain is. Ignored by every
    /// other case, which takes no size.
    n: u32 = default_chain,

    /// Big enough that the accumulation is unmistakable, small enough that
    /// `--pathological=constraint-chain` with no size still finishes; §7
    /// M2 sweeps {10, 100, 1000, 5000} explicitly.
    pub const default_chain: u32 = 1000;

    pub const Case = enum {
        /// 10 MB of `[ 1, 1, … ]` on one line. VALID: it must lex, parse and
        /// lower clean, which is what makes it a throughput case rather than
        /// an error case. 3.5 M tokens, 3.5 M nodes.
        @"big-list",
        /// 10 MB of one string literal: one token, and the case where the
        /// lexer's inner loop is everything.
        @"big-string",
        /// 10 MB of one identifier: one token, interned once, and a hash of
        /// ten megabytes.
        @"big-ident",
        /// 100 000 nested `\x ->`: right-nested, so the parser recurses and
        /// the depth guard stops it at 4096 — with 4095 `shadowing` errors
        /// under it, which is the diagnostic-volume case.
        @"deep-lambdas",
        /// `plans/static-dispatch-spike.md` §7 M2: `n` UNANNOTATED `pub`
        /// functions, each taking one polymorphic parameter, adding one new
        /// method call on it and calling the one before it. `f<n>`'s
        /// inferred scheme therefore carries `n` method constraints — and
        /// because nothing is annotated, every one of them is promoted onto
        /// the module's interface (§6.4). This is the shape report 18 §2.3
        /// argues about and nobody has measured: check time against `n`,
        /// constraints per scheme, and the length of the rendered scheme.
        ///
        /// Unlike its four neighbours this is not one huge line; it is
        /// `n` small declarations, and what it stresses is the checker
        /// rather than the lexer.
        ///
        /// **It parses and checks clean TODAY, and that is the point.**
        /// `x.m<i> 1` is `apply(field_access(x, m<i>), [1])` already
        /// (`static-dispatch-spike.md` §1.1: the call form needs no grammar
        /// change), so on `master` this module is a chain of *row-polymorphic
        /// field calls* — `x` is inferred as an open record of `n` function
        /// fields — and the baseline it produces measures record extension
        /// and field lookup, NOT method constraints. After S3 the same bytes
        /// are a chain of `n` METHOD CONSTRAINTS on a type variable.
        ///
        /// The two numbers are therefore both meaningful and must never be
        /// read as before/after of the same mechanism: the `master` run is
        /// the row-polymorphism cost the language already pays for this
        /// shape, and the branch run is what the constraint machinery costs
        /// for it. §7 M2's table records both, labelled.
        @"constraint-chain",
    };

    /// `<name>` or `<name>=<n>`. A size is only accepted by the case that
    /// takes one, so `--pathological=big-list=7` is an error rather than a
    /// number that is silently dropped.
    pub fn parse(spec: []const u8) ?Pathological {
        const split = std.mem.indexOfScalar(u8, spec, '=');
        const name = if (split) |i| spec[0..i] else spec;
        const case = std.meta.stringToEnum(Case, name) orelse return null;
        const size = split orelse return .{ .case = case };
        if (case != .@"constraint-chain") return null;
        const n = std.fmt.parseInt(u32, spec[size + 1 ..], 10) catch return null;
        if (n == 0) return null;
        return .{ .case = case, .n = n };
    }

    /// Where the case is written under the output directory. Every path
    /// segment is an upper identifier so the file has a module name
    /// (language.md §1).
    pub fn path(which: Pathological) []const u8 {
        return switch (which.case) {
            .@"big-list" => "Gen/BigList.beni",
            .@"big-string" => "Gen/BigString.beni",
            .@"big-ident" => "Gen/BigIdent.beni",
            .@"deep-lambdas" => "Gen/DeepLambdas.beni",
            .@"constraint-chain" => "Gen/ConstraintChain.beni",
        };
    }
};

/// Write one pathological case under `out_dir`, replacing whatever was
/// there.
pub fn generatePathological(gpa: Allocator, io: Io, out_dir: []const u8, which: Pathological) !Stats {
    var buffer: Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try writePathological(&buffer.writer, which);

    var root = try Io.Dir.cwd().createDirPathOpen(io, out_dir, .{});
    defer root.close(io);
    try root.createDirPath(io, "Gen");
    const text = buffer.written();
    try root.writeFile(io, .{ .sub_path = which.path(), .data = text });
    return .{ .files = 1, .lines = std.mem.count(u8, text, "\n"), .bytes = text.len };
}

const ten_megabytes = 10 * 1024 * 1024;

pub fn writePathological(w: *Io.Writer, which: Pathological) Io.Writer.Error!void {
    switch (which.case) {
        .@"big-list" => {
            try w.writeAll("main =\n    [ 1");
            // `, 1` is three bytes; the head and tail are negligible.
            for (0..ten_megabytes / 3) |_| try w.writeAll(", 1");
            try w.writeAll(" ]\n");
        },
        .@"big-string" => {
            try w.writeAll("main =\n    \"");
            try w.splatByteAll('a', ten_megabytes);
            try w.writeAll("\"\n");
        },
        .@"big-ident" => {
            try w.splatByteAll('a', ten_megabytes);
            try w.writeByte('\n');
        },
        .@"deep-lambdas" => {
            try w.writeAll("main =\n    ");
            for (0..100_000) |_| try w.writeAll("\\x -> ");
            try w.writeAll("1\n");
        },
        .@"constraint-chain" => try writeConstraintChain(w, which.n),
    }
}

/// `f1 … fn`, unannotated and `pub`, each adding one NEW method call on its
/// single polymorphic parameter and calling its predecessor on the same
/// parameter (`plans/static-dispatch-spike.md` §7 M2).
///
/// Three properties make this the accumulation case and not a chain of
/// unrelated declarations:
///
///   - Nothing is annotated, so no `where` clause can discharge a
///     constraint early and every one of them has to ride out on the
///     inferred scheme (§6.4). An annotation anywhere in the chain would
///     cut it in two and measure half of it.
///   - Every method name is DISTINCT (`m1 … mn`), so the constraint sets
///     really grow; the same name `n` times would merge to one constraint
///     (§6.2) and the curve would be flat for the wrong reason.
///   - `f<i>` calls `f<i-1>` on its own parameter, so `f<i-1>`'s whole set
///     is instantiated and unified into `f<i>`'s at every link — the
///     quadratic term, if there is one, is here.
///
/// `+` pins every method's result to `Int`, which keeps the scheme readable
/// (`a -> Int`, `n` constraints) rather than growing a result variable per
/// link as well.
///
/// On `master` and on this branch before S3 the same text checks CLEAN as a
/// chain of row-polymorphic field calls; see `Pathological.Case` for why the
/// two baselines are not the same measurement.
fn writeConstraintChain(w: *Io.Writer, n: u32) Io.Writer.Error!void {
    try w.print(
        \\--! Gen.ConstraintChain: {d} unannotated `pub` functions, each adding one
        \\--! operation to the set the one before it inferred.
        \\--! Generated by bench/gen.zig for plans/static-dispatch-spike.md §7 M2.
        \\--!
        \\--! This checks clean BEFORE static dispatch too, as a chain of
        \\--! row-polymorphic field calls on an open record of `n` function fields.
        \\--! After S3 the same bytes are `n` method constraints on a type variable.
        \\--! The two runs measure different mechanisms and are labelled separately.
        \\
        \\
    , .{n});
    var i: u32 = 1;
    while (i <= n) : (i += 1) {
        if (i != 1) try w.writeByte('\n');
        try w.print("pub f{d} x =\n", .{i});
        if (i == 1) {
            try w.print("    x.m1 1\n", .{});
        } else {
            try w.print("    x.m{d} 1 + f{d} x\n", .{ i, i - 1 });
        }
    }
}

/// `Gen/Page12.beni`, `Gen/Data/Store13.beni`, `Gen/Ui/Widget14.beni`.
pub fn modulePath(buf: []u8, index: u32) []const u8 {
    return switch (index % 3) {
        0 => std.fmt.bufPrint(buf, "Gen/Page{d}.beni", .{index}),
        1 => std.fmt.bufPrint(buf, "Gen/Data/Store{d}.beni", .{index}),
        else => std.fmt.bufPrint(buf, "Gen/Ui/Widget{d}.beni", .{index}),
    } catch unreachable;
}

/// The module name for `modulePath(index)`.
pub fn moduleName(buf: []u8, index: u32) []const u8 {
    return switch (index % 3) {
        0 => std.fmt.bufPrint(buf, "Gen.Page{d}", .{index}),
        1 => std.fmt.bufPrint(buf, "Gen.Data.Store{d}", .{index}),
        else => std.fmt.bufPrint(buf, "Gen.Ui.Widget{d}", .{index}),
    } catch unreachable;
}

/// Write module `index` and return its line count.
pub fn writeModule(writer: *Io.Writer, seed: u64, index: u32) Io.Writer.Error!u64 {
    return writeModuleMode(writer, seed, index, .plain);
}

/// Which declaration kind each of a module's random helpers is. Recorded by
/// a dry run of the module and read by the real one, so the dispatch mode
/// can tell — BEFORE writing a constrained helper — whether a later
/// declaration will be there to call it (`oneLiner`). A constrained helper
/// nobody calls forwards no evidence, and the §7 backend rows would then
/// measure declarations without their call sites.
///
/// A dry run is honest because both modes draw from the PRNG in the same
/// order: the plan describes the module that is about to be written.
const Plan = struct {
    kinds: [24]u8 = @splat(no_kind),
    count: usize = 0,

    const no_kind: u8 = 255;
    /// `randomFn`'s first two kinds, the only ones that end in an
    /// expression this generator can wrap a call around.
    const one_liner: u8 = 0;
    const let_fn: u8 = 1;

    /// Declarations after slot `n` that are guaranteed to drain one pending
    /// helper. A `oneLiner` on a slot that may itself BE a helper is not
    /// counted: it would consume one and add one, draining nothing.
    fn drains(plan: *const Plan, after: u32) usize {
        var found: usize = 0;
        for (plan.kinds[0..plan.count], 0..) |k, i| {
            if (i <= after) continue;
            if (k == let_fn or (k == one_liner and !isWhereSlot(@intCast(i)))) found += 1;
        }
        return found;
    }
};

/// Which `randomFn` slots may carry a constrained helper in dispatch mode.
/// One in four: enough `where` clauses and inferred constraints to measure,
/// few enough that the dispatch tree stays inside the size budget it shares
/// with the plain one (§7 compares per-byte and per-line work).
fn isWhereSlot(n: u32) bool {
    return n % 4 == 0;
}

/// `writeModule` in a chosen `Mode`. Both modes draw from the PRNG in the
/// same order, so module `index` has the same declarations under the same
/// names in either one; see `Mode` for what the dispatch text changes.
pub fn writeModuleMode(writer: *Io.Writer, seed: u64, index: u32, mode: Mode) Io.Writer.Error!u64 {
    const stream = seed ^ (@as(u64, index) +% 1) *% 0x9E3779B97F4A7C15;
    var plan: Plan = .{};
    if (mode == .dispatch) {
        var discard: Io.Writer.Discarding = .init(&.{});
        var dry_prng: std.Random.DefaultPrng = .init(stream);
        var dry: Module = .{ .w = &discard.writer, .rng = dry_prng.random(), .index = index, .record = &plan };
        try dry.module();
    }
    var prng: std.Random.DefaultPrng = .init(stream);
    var g: Module = .{
        .w = writer,
        .rng = prng.random(),
        .index = index,
        .mode = mode,
        .plan = if (mode == .dispatch) &plan else null,
    };
    try g.module();
    return g.lines;
}

/// One module's generator: a PRNG, a writer, and the scoping bookkeeping
/// that keeps the output free of shadowing.
const Module = struct {
    w: *Io.Writer,
    rng: std.Random,
    index: u32,
    mode: Mode = .plain,
    lines: u64 = 0,
    /// Locals in scope in the function being generated, innermost last.
    locals: [24][]const u8 = undefined,
    /// Whether `locals[i]` holds an `Int`. A let-bound FUNCTION is in scope
    /// — a name chosen next to it must not collide with it — but it is not
    /// an `Int` and must never be written where one belongs, or the corpus
    /// stops type-checking (checker.md §9).
    local_is_int: [24]bool = undefined,
    local_count: usize = 0,
    /// Next fresh suffix when the realistic name pool is exhausted.
    fresh: u32 = 0,
    /// Earlier modules imported with `exposing (helperK)`.
    exposed: [4]u32 = undefined,
    exposed_count: usize = 0,
    /// Earlier modules imported with `as PK`.
    aliased: [4]u32 = undefined,
    aliased_count: usize = 0,
    /// Which optional fields this module's `Model` alias declares. A record
    /// literal is closed, so `init` must set exactly these.
    has_ratio: bool = false,
    has_selected: bool = false,
    /// The `where`-constrained helpers this module has written, and whether
    /// each one has a CALL SITE yet. A constrained declaration nobody calls
    /// never forwards an evidence parameter, so the `$m$k` argument of
    /// `static-dispatch-spike.md` §8.2 would never appear in the corpus at
    /// all and the backend row of §7 would measure declarations only.
    /// Names are copied in because `fnName` writes into the caller's stack
    /// buffer.
    where_names: [8][32]u8 = undefined,
    where_len: [8]u8 = undefined,
    where_called: [8]bool = undefined,
    where_count: usize = 0,
    /// Set on the dispatch run: what the dry run saw.
    plan: ?*const Plan = null,
    /// Set on the dry run: where to record it.
    record: ?*Plan = null,

    const local_pool = [_][]const u8{
        "acc",   "item",  "total",  "count",  "first", "rest",  "key",   "value",
        "left",  "right", "n",      "k",      "s",     "t",     "xs",    "ys",
        "label", "width", "height", "amount", "index", "found", "limit", "step",
    };

    const words = [_][]const u8{
        "alpha", "beta",   "gamma", "delta", "report", "user",  "order", "item",
        "total", "status", "ready", "done",  "north",  "south", "east",  "west",
    };

    /// A prelude function on `Int`, with the number of atoms that saturate
    /// it. Every call the generator writes is saturated: an accidental
    /// partial application is exactly the `too_few_args` of checker.md §8.3,
    /// and a corpus full of them would measure the error path.
    const PreludeCall = struct { prefix: []const u8, arity: u8 };

    const prelude_calls = [_]PreludeCall{
        .{ .prefix = "max", .arity = 2 },
        .{ .prefix = "min", .arity = 2 },
        .{ .prefix = "clamp 0 10", .arity = 1 },
        .{ .prefix = "modBy 3", .arity = 1 },
        .{ .prefix = "always 1", .arity = 1 },
    };

    // ---- output helpers ------------------------------------------------

    fn line(g: *Module, indent: usize, comptime fmt: []const u8, args: anytype) Io.Writer.Error!void {
        try g.w.splatByteAll(' ', indent);
        try g.w.print(fmt, args);
        try g.w.writeByte('\n');
        g.lines += 1;
    }

    fn blank(g: *Module) Io.Writer.Error!void {
        try g.w.writeByte('\n');
        g.lines += 1;
    }

    fn declGap(g: *Module) Io.Writer.Error!void {
        try g.blank();
        try g.blank();
    }

    fn chance(g: *Module, percent: u8) bool {
        return g.rng.uintLessThan(u8, 100) < percent;
    }

    fn dispatch(g: *const Module) bool {
        return g.mode == .dispatch;
    }

    /// Which of `Msg<i>`'s two methods this module's `where` helpers
    /// constrain: `update<i> : Msg<i>, Model<i> -> Model<i>` or
    /// `helper<i> : Msg<i>, Int -> Int`. Both go through §6.3's module
    /// lookup, and the first puts a non-`Int` type into a `where` clause.
    ///
    /// Neither is the well-known `compare`, and that is not an oversight:
    /// §1.3 rule 2 says only an OPERATOR-marked call may derive, so a
    /// hand-written `x.compare y` on a type with no `pub compare` is
    /// `unknown_method` by design. The derivation path of §9 is reached by
    /// the `==` this corpus writes on records and on custom types, which is
    /// where it is actually exercised.
    ///
    /// One kind PER MODULE, so every helper in a module carries the same
    /// constraint and can therefore forward its evidence to the one before
    /// it; both are in the corpus because the modules alternate.
    fn updateWhere(g: *const Module) bool {
        return g.index % 2 == 0;
    }

    /// Remember a `where` helper so a later expression can call it.
    fn recordWhere(g: *Module, name: []const u8) void {
        if (g.where_count == g.where_names.len or name.len > 32) return;
        @memcpy(g.where_names[g.where_count][0..name.len], name);
        g.where_len[g.where_count] = @intCast(name.len);
        g.where_called[g.where_count] = false;
        g.where_count += 1;
    }

    fn whereName(g: *const Module, i: usize) []const u8 {
        return g.where_names[i][0..g.where_len[i]];
    }

    /// The oldest `where` helper with no call site yet, marked as called.
    /// Takes no random draw: a draw here would have to be taken in plain
    /// mode too, and that would move the plain corpus, which is the
    /// baseline every other number is read against.
    /// The most recently written helper, called or not. A second
    /// constrained helper in a module forwards into it even when the first
    /// already has a call site: the point of the shape is the `$m$k`
    /// argument passed from one constrained declaration to another, and it
    /// costs two bytes over calling the constraint directly.
    /// A value of this module's own nominal type, for use as a method
    /// receiver (§1.2's module rule). `Reset` is a nullary constructor of
    /// `Msg<i>`, which every module declares, and the parentheses are what
    /// make it an ATOM rather than the head of a qualified name: bare
    /// `Reset.helper<i>` lexes as `qualified_lower` — module `Reset`, value
    /// `helper<i>` — which is §1.1's `M.f x` row and not a method call.
    const receiver = "(Reset)";

    fn lastWhere(g: *const Module) ?[]const u8 {
        if (g.where_count == 0) return null;
        return g.whereName(g.where_count - 1);
    }

    fn pendingWhereCount(g: *const Module) usize {
        var n: usize = 0;
        for (g.where_called[0..g.where_count]) |called| {
            if (!called) n += 1;
        }
        return n;
    }

    /// Whether a constrained helper written at slot `n` is certain to be
    /// called. Writing one drains at most one pending helper and then adds
    /// itself, so the module needs `max(pending, 1)` guaranteed drain slots
    /// after `n`. This is the whole reason `Plan` exists.
    fn canAffordWhere(g: *const Module, n: u32) bool {
        const plan = g.plan orelse return false;
        return plan.drains(n) >= @max(g.pendingWhereCount(), 1);
    }

    fn takeUncalledWhere(g: *Module) ?[]const u8 {
        for (0..g.where_count) |i| {
            if (g.where_called[i]) continue;
            g.where_called[i] = true;
            return g.whereName(i);
        }
        return null;
    }

    /// Which modules carry the comparator-free `Dict`/`Set` of §5.3, §5.4.
    /// One module in sixteen: enough that the corpus really contains the
    /// operations M5's R1/R2 time, few enough that the `let` block and the
    /// two `import` lines it needs stay inside the size budget the two
    /// corpora have to share (§7: the `check` line's LOC/s and the front
    /// end's MB/s both compare per-byte work).
    fn usesDict(g: *const Module) bool {
        return g.dispatch() and g.index % 16 == 1;
    }

    fn pick(g: *Module, comptime T: type, items: []const T) T {
        return items[g.rng.uintLessThan(usize, items.len)];
    }

    // ---- scoping --------------------------------------------------------

    /// Bind a fresh local: a pool name not yet in scope, else `v<n>`.
    fn bind(g: *Module) []const u8 {
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            const candidate = g.pick([]const u8, &local_pool);
            if (!g.inScope(candidate)) return g.push(candidate);
        }
        for (local_pool) |candidate| if (!g.inScope(candidate)) return g.push(candidate);
        g.fresh += 1;
        // A tiny leak-free trick: the fresh names live in a static table so
        // no allocation is needed for the rare overflow case.
        return g.push(fresh_names[g.fresh % fresh_names.len]);
    }

    const fresh_names = [_][]const u8{ "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8" };

    fn push(g: *Module, name: []const u8) []const u8 {
        return g.pushTyped(name, true);
    }

    /// In scope for name choice, never used as a value.
    fn pushFunction(g: *Module, name: []const u8) []const u8 {
        return g.pushTyped(name, false);
    }

    fn pushTyped(g: *Module, name: []const u8, is_int: bool) []const u8 {
        std.debug.assert(g.local_count < g.locals.len);
        g.locals[g.local_count] = name;
        g.local_is_int[g.local_count] = is_int;
        g.local_count += 1;
        return name;
    }

    fn inScope(g: *const Module, name: []const u8) bool {
        for (g.locals[0..g.local_count]) |l| if (std.mem.eql(u8, l, name)) return true;
        return false;
    }

    fn scopeMark(g: *const Module) usize {
        return g.local_count;
    }

    fn scopeReset(g: *Module, mark: usize) void {
        g.local_count = mark;
    }

    /// An `Int`-valued local, or null when there is none: a scan over at
    /// most 24 entries, once per atom.
    fn anyLocal(g: *Module) ?[]const u8 {
        var count: usize = 0;
        for (g.local_is_int[0..g.local_count]) |is_int| {
            if (is_int) count += 1;
        }
        if (count == 0) return null;
        var wanted = g.rng.uintLessThan(usize, count);
        for (g.locals[0..g.local_count], g.local_is_int[0..g.local_count]) |name, is_int| {
            if (!is_int) continue;
            if (wanted == 0) return name;
            wanted -= 1;
        }
        return null;
    }

    // ---- module ---------------------------------------------------------

    fn module(g: *Module) Io.Writer.Error!void {
        var name_buf: [64]u8 = undefined;
        try g.line(0, "--! {s}: {s} {s} logic for the synthetic project.", .{ moduleName(&name_buf, g.index), g.pick([]const u8, &words), g.pick([]const u8, &words) });
        if (g.chance(50)) try g.line(0, "--! Generated by bench/gen.zig; every construct is language.md-valid.", .{});
        try g.blank();
        try g.imports();
        try g.declGap();

        try g.modelAlias();
        try g.declGap();
        try g.msgType();
        if (g.chance(40)) {
            try g.declGap();
            try g.shapeType();
        }
        try g.declGap();
        try g.initFn();
        try g.declGap();
        try g.updateFn();
        try g.declGap();
        try g.helperFn();
        try g.declGap();
        try g.sumFn();

        // The rest: mostly small helpers, with the occasional large case.
        const extra = 4 + g.rng.uintLessThan(u32, 10);
        var i: u32 = 0;
        while (i < extra) : (i += 1) {
            try g.declGap();
            try g.randomFn(i);
        }
    }

    fn imports(g: *Module) Io.Writer.Error!void {
        // `Dict` and `Set` are not prelude modules (language.md Appendix A),
        // so the comparator-free shape of §5.3 needs them by name. Written
        // around the `Gen.*` block so the whole list stays sorted by module
        // name: `Dict` < `Gen.…` < `List` < `Set`.
        if (g.usesDict()) try g.line(0, "import Dict", .{});
        // Earlier modules only, ascending, distinct — so imports are sorted
        // by path and never duplicated.
        var candidates: [4]u32 = undefined;
        var n: usize = 0;
        if (g.index > 0) {
            const want = @min(@as(u32, 1 + g.rng.uintLessThan(u32, 3)), g.index);
            while (n < want) {
                const c = g.rng.uintLessThan(u32, g.index);
                if (std.mem.indexOfScalar(u32, candidates[0..n], c) != null) continue;
                candidates[n] = c;
                n += 1;
            }
        }
        // Path order: Gen.Data.* < Gen.Page* < Gen.Ui.*; sort by name text.
        std.mem.sort(u32, candidates[0..n], {}, struct {
            fn lessThan(_: void, a: u32, b: u32) bool {
                var ba: [64]u8 = undefined;
                var bb: [64]u8 = undefined;
                return std.mem.lessThan(u8, moduleName(&ba, a), moduleName(&bb, b));
            }
        }.lessThan);
        var name_buf: [64]u8 = undefined;
        for (candidates[0..n]) |k| {
            const name = moduleName(&name_buf, k);
            switch (g.rng.uintLessThan(u8, 3)) {
                0 => try g.line(0, "import {s}", .{name}),
                1 => {
                    try g.line(0, "import {s} as P{d}", .{ name, k });
                    g.aliased[g.aliased_count] = k;
                    g.aliased_count += 1;
                },
                else => {
                    // In dispatch mode the same two names are exposed and
                    // NEITHER is used: `helper<k>` is reached through the
                    // receiver's TYPE, in the module that declares it, with
                    // no import of the value at all (§1, §6.8). That is the
                    // edge the parallel checker has to learn about, and it
                    // only exists if the corpus reaches a method the
                    // importer never named. The alias is what puts module
                    // `k`'s constructors in reach, since the receiver has to
                    // be a value of a type module `k` declares.
                    if (g.dispatch()) {
                        try g.line(0, "import {s} as P{d} exposing (Model{d}, helper{d})", .{ name, k, k, k });
                    } else {
                        try g.line(0, "import {s} exposing (Model{d}, helper{d})", .{ name, k, k });
                    }
                    g.exposed[g.exposed_count] = k;
                    g.exposed_count += 1;
                },
            }
        }
        if (n == 0) try g.line(0, "import List", .{});
        if (g.usesDict()) try g.line(0, "import Set", .{});
    }

    fn modelAlias(g: *Module) Io.Writer.Error!void {
        try g.line(0, "--| The state this module keeps.", .{});
        try g.line(0, "pub type alias Model{d} =", .{g.index});
        try g.line(4, "{{ count : Int", .{});
        try g.line(4, ", name : String", .{});
        try g.line(4, ", items : List Int", .{});
        // Which optional fields exist is remembered, because a record
        // literal is CLOSED: `init` has to set exactly these and no others
        // or the corpus does not type-check.
        g.has_ratio = g.chance(50);
        g.has_selected = g.chance(30);
        if (g.has_ratio) try g.line(4, ", ratio : Float", .{});
        if (g.has_selected) try g.line(4, ", selected : Maybe Int", .{});
        try g.line(4, "}}", .{});
    }

    fn msgType(g: *Module) Io.Writer.Error!void {
        try g.line(0, "pub type Msg{d}", .{g.index});
        try g.line(4, "= Increment", .{});
        try g.line(4, "| Decrement", .{});
        try g.line(4, "| SetName String", .{});
        if (g.chance(50)) try g.line(4, "| Add Int Int", .{});
        try g.line(4, "| Reset", .{});
    }

    fn shapeType(g: *Module) Io.Writer.Error!void {
        try g.line(0, "pub opaque type Shape{d}", .{g.index});
        try g.line(4, "= Circle Float", .{});
        try g.line(4, "| Rect Float Float", .{});
        try g.line(4, "| Point", .{});
    }

    fn initFn(g: *Module) Io.Writer.Error!void {
        try g.line(0, "pub init{d} : Model{d}", .{ g.index, g.index });
        try g.line(0, "init{d} =", .{g.index});
        try g.w.splatByteAll(' ', 4);
        try g.w.print("{{ count = {d}, name = \"{s}\", items = [ {d}, {d}, {d} ]", .{
            g.rng.uintLessThan(u32, 10), g.pick([]const u8, &words), g.rng.uintLessThan(u32, 9), g.rng.uintLessThan(u32, 99), g.rng.uintLessThan(u32, 999),
        });
        if (g.has_ratio) try g.w.print(", ratio = {d}.{d}", .{ g.rng.uintLessThan(u32, 9), g.rng.uintLessThan(u32, 99) });
        if (g.has_selected) try g.w.print(", selected = Just {d}", .{g.rng.uintLessThan(u32, 9)});
        try g.w.writeAll(" }\n");
        g.lines += 1;
    }

    fn updateFn(g: *Module) Io.Writer.Error!void {
        const mark = g.scopeMark();
        defer g.scopeReset(mark);
        try g.line(0, "pub update{d} : Msg{d}, Model{d} -> Model{d}", .{ g.index, g.index, g.index, g.index });
        try g.line(0, "update{d} msg model =", .{g.index});
        _ = g.push("msg");
        _ = g.push("model");
        try g.line(4, "case msg of", .{});
        try g.line(8, "Increment ->", .{});
        try g.line(12, "{{ model | count = model.count + 1 }}", .{});
        try g.blank();
        try g.line(8, "Decrement ->", .{});
        try g.line(12, "{{ model | count = model.count - 1 }}", .{});
        try g.blank();
        try g.line(8, "SetName newName ->", .{});
        if (g.chance(50)) {
            try g.line(12, "if String.length newName > {d} then", .{g.rng.uintLessThan(u32, 40)});
            try g.line(16, "model", .{});
            try g.line(12, "else", .{});
            try g.line(16, "{{ model | name = newName }}", .{});
        } else {
            try g.line(12, "{{ model | name = newName, count = 0 }}", .{});
        }
        try g.blank();
        try g.line(8, "_ ->", .{});
        try g.line(12, "init{d}", .{g.index});
    }

    fn helperFn(g: *Module) Io.Writer.Error!void {
        const mark = g.scopeMark();
        defer g.scopeReset(mark);
        try g.line(0, "--| A small numeric helper every module exports.", .{});
        // The one declaration the whole corpus calls, so it is the one
        // worth routing through dispatch. The receiver is `Msg<i>`, the
        // module's CUSTOM type, and not `Model<i>`: `Model<i>` is a
        // `type alias` for a record, and §1.2 looks an alias through to its
        // expansion, so `m.helper<i> n` on one is a field call on a record
        // with no such field (`missing_field`), not a method call. The
        // module rule needs a NOMINAL type — `type`, `opaque type` or
        // `foreign type` — and `Msg<i>` is the one every module declares.
        //
        // The receiver is not read. A `Msg<i>` cannot appear in the `Int`
        // arithmetic these bodies are made of, and spending a `case` on it
        // would cost more bytes than the whole dispatch shape has to give
        // (§7 compares the two corpora per byte). What is being measured is
        // the call and its resolution, and both are unaffected.
        if (g.dispatch()) {
            try g.line(0, "pub helper{d} : Msg{d}, Int -> Int", .{ g.index, g.index });
            try g.line(0, "helper{d} msg n =", .{g.index});
            _ = g.pushFunction("msg");
        } else {
            try g.line(0, "pub helper{d} : Int -> Int", .{g.index});
            try g.line(0, "helper{d} n =", .{g.index});
        }
        _ = g.push("n");
        // Every arm draws exactly what it drew before, in the same order:
        // a mode that drew one number fewer would rename every declaration
        // after it and the two trees would stop being the same project.
        switch (g.rng.uintLessThan(u8, 3)) {
            0 => try g.line(4, "n * {d} + {d}", .{ 1 + g.rng.uintLessThan(u32, 9), g.rng.uintLessThan(u32, 100) }),
            1 => try g.line(4, "max n {d} - min n {d}", .{ g.rng.uintLessThan(u32, 100), g.rng.uintLessThan(u32, 10) }),
            else => try g.line(4, "modBy {d} (abs n)", .{2 + g.rng.uintLessThan(u32, 30)}),
        }
    }

    fn sumFn(g: *Module) Io.Writer.Error!void {
        const mark = g.scopeMark();
        defer g.scopeReset(mark);
        // The comparator-free `Dict`/`Set` of §5.3 and §5.4, in a
        // declaration that already has the right type and is already
        // called from the pipelines: `Dict.empty` takes no ordering, and
        // `insert`/`get` reach `k.compare` through the `where` clause on
        // their own annotations. Draws nothing, so the stream is untouched.
        if (g.usesDict()) {
            try g.line(0, "pub sum{d} : List Int -> Int", .{g.index});
            try g.line(0, "sum{d} xs =", .{g.index});
            try g.line(4, "let", .{});
            try g.line(8, "counts = List.foldl xs Dict.empty (\\x acc -> acc.insert x 1)", .{});
            try g.line(8, "unique = List.foldl xs Set.empty (\\x acc -> acc.insert x)", .{});
            try g.line(4, "in", .{});
            try g.line(4, "Maybe.withDefault (counts.get 3) 0 + Set.size unique", .{});
            return;
        }
        try g.line(0, "pub sum{d} : List Int -> Int", .{g.index});
        try g.line(0, "sum{d} xs =", .{g.index});
        _ = g.push("xs");
        try g.line(4, "case xs of", .{});
        try g.line(8, "[] ->", .{});
        try g.line(12, "0", .{});
        try g.blank();
        try g.line(8, "first :: rest ->", .{});
        try g.line(12, "first + sum{d} rest", .{g.index});
    }

    // ---- the random helpers ------------------------------------------

    fn randomFn(g: *Module, n: u32) Io.Writer.Error!void {
        const mark = g.scopeMark();
        defer g.scopeReset(mark);
        // Only the first kinds are "small"; the weights favour them.
        const kind = g.rng.weightedIndex(u8, &.{ 20, 14, 12, 12, 10, 8, 8, 6, 5, 4 });
        if (g.record) |plan| {
            if (plan.count < plan.kinds.len) {
                plan.kinds[plan.count] = @intCast(kind);
                plan.count += 1;
            }
        }
        switch (kind) {
            0 => try g.oneLiner(n),
            1 => try g.letFn(n),
            2 => try g.pipelineFn(n),
            3 => try g.ifFn(n),
            4 => try g.recordFn(n),
            5 => try g.tupleFn(n),
            6 => try g.stringFn(n),
            7 => try g.multilineFn(n),
            8 => try g.questionFn(n),
            else => try g.bigCaseFn(n),
        }
    }

    fn fnName(g: *Module, buf: []u8, n: u32, base: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}{d}_{d}", .{ base, g.index, n }) catch unreachable;
    }

    fn oneLiner(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "scale");
        const annotated = g.chance(60);
        // One in four of these is a CONSTRAINED helper in dispatch mode
        // (`isWhereSlot`), when the module can guarantee it a call site.
        //
        // Visibility and annotated-ness are exactly the plain mode's: these
        // declarations are private in both trees, and this one is annotated
        // exactly when the plain one would have been. Interface writing is
        // what §7 M1b is most sensitive to (`fillInterface` is per exported
        // value; the M2d entry in bench/README.md measures it at 19x), so a
        // dispatch tree with 14 % more `pub` values would report the cost of
        // exporting as a cost of dispatch.
        //
        // Annotated, the constraint is DECLARED in a §2 `where` clause.
        // Unannotated, the same constraint is INFERRED from the method call
        // in the body and promoted at generalisation (§6.4) — which is the
        // case report 18 §2.3 argues about, so both belong in the corpus.
        if (g.dispatch() and isWhereSlot(n) and g.canAffordWhere(n)) {
            const via_update = g.updateWhere();
            if (annotated) {
                try g.line(0, "{s} : a, Int -> Int", .{name});
                if (via_update) {
                    try g.line(4, "where a.update{d} : a, Model{d} -> Model{d}", .{ g.index, g.index, g.index });
                } else {
                    try g.line(4, "where a.helper{d} : a, Int -> Int", .{g.index});
                }
            }
            try g.line(0, "{s} x n =", .{name});
            _ = g.pushFunction("x");
            _ = g.push("n");
            try g.w.splatByteAll(' ', 4);
            // Forward this declaration's own evidence into the previous
            // constrained helper when there is one (§8.2's `$m$k` argument)
            // — which also infers the constraint in the unannotated case,
            // through the callee's scheme. With no predecessor the body uses
            // the constraint directly.
            if (g.takeUncalledWhere() orelse g.lastWhere()) |previous| {
                try g.w.print("{s} x (", .{previous});
            } else if (via_update) {
                try g.w.print("(x.update{d} init{d}).count + (", .{ g.index, g.index });
            } else {
                try g.w.print("x.helper{d} (", .{g.index});
            }
            try g.expr(2);
            try g.w.writeAll(")\n");
            g.lines += 1;
            g.recordWhere(name);
            return;
        }
        if (annotated) try g.line(0, "{s} : Int -> Int", .{name});
        try g.line(0, "{s} n =", .{name});
        _ = g.push("n");
        try g.w.splatByteAll(' ', 4);
        // A constrained helper written earlier in this module that still has
        // no call site is wrapped around the body. No draw is taken, so the
        // plain stream is untouched, and it is the only place a helper in a
        // module that writes exactly one is guaranteed to be called from.
        const wrap = if (g.dispatch()) g.takeUncalledWhere() else null;
        if (wrap) |helper| try g.w.print("{s} {s} (", .{ helper, receiver });
        try g.expr(2);
        if (wrap != null) try g.w.writeByte(')');
        try g.w.writeByte('\n');
        g.lines += 1;
    }

    fn letFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "compute");
        try g.line(0, "{s} : Int, Int -> Int", .{name});
        try g.line(0, "{s} left right =", .{name});
        _ = g.push("left");
        _ = g.push("right");
        try g.line(4, "let", .{});
        const bindings = 1 + g.rng.uintLessThan(u32, 3);
        const with_twice = g.chance(30);

        // A `let` group's bindings are mutually recursive (language.md §6.2):
        // EVERY name it binds is in scope in EVERY value, including values
        // written earlier in the block. So all the names are chosen and
        // pushed here, before the first value is written — otherwise a
        // lambda parameter picked inside binding 1 only avoids bindings 0..1
        // and can collide with binding 2, which is a `shadowing` error in
        // the generator's own output (the bug this loop's shape fixes).
        var names: [3][]const u8 = undefined;
        for (names[0..bindings]) |*slot| slot.* = g.bind();
        if (with_twice) _ = g.pushFunction("twice");

        for (names[0..bindings], 0..) |local, i| {
            if (i != 0 and g.chance(50)) try g.blank();
            if (g.chance(30)) try g.line(8, "{s} : Int", .{local});
            if (g.chance(50)) {
                try g.line(8, "{s} =", .{local});
                try g.w.splatByteAll(' ', 12);
            } else {
                try g.w.splatByteAll(' ', 8);
                try g.w.print("{s} = ", .{local});
            }
            try g.expr(2);
            try g.w.writeByte('\n');
            g.lines += 1;
        }
        if (with_twice) {
            // A let-bound function with its own parameter: fresh against
            // every sibling binding, which is already in scope.
            const mark = g.scopeMark();
            const param = g.bind();
            try g.line(8, "twice {s} =", .{param});
            try g.line(12, "{s} * 2", .{param});
            g.scopeReset(mark);
        }
        try g.line(4, "in", .{});
        try g.w.splatByteAll(' ', 4);
        const wrap = if (g.dispatch()) g.takeUncalledWhere() else null;
        if (wrap) |helper| try g.w.print("{s} {s} (", .{ helper, receiver });
        try g.expr(3);
        if (wrap != null) try g.w.writeByte(')');
        try g.w.writeByte('\n');
        g.lines += 1;
    }

    fn pipelineFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "process");
        // A pipeline whose map step is a METHOD call on a value of a type
        // this module declares (§1) — what `List.map xs helper<i>` becomes
        // once `helper<i>` is a method of `Model<i>`. The receiver is the
        // module's own `init<i>` rather than a new parameter: a parameter
        // would change the declaration's TYPE in every pipeline, including
        // the ones whose steps never draw a map, and pay bytes for nothing.
        try g.line(0, "{s} : List Int -> Int", .{name});
        try g.line(0, "{s} xs =", .{name});
        _ = g.push("xs");
        try g.line(4, "xs", .{});
        const steps = 2 + g.rng.uintLessThan(u32, 4);
        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            switch (g.rng.uintLessThan(u8, 4)) {
                0 => try g.line(8, "|> List.filter (\\x -> x > {d})", .{g.rng.uintLessThan(u32, 50)}),
                1 => try g.line(8, "|> List.map (\\x -> x * {d})", .{1 + g.rng.uintLessThan(u32, 9)}),
                2 => if (g.dispatch())
                    // `x.m _` is the placeholder over a method call
                    // (`static-dispatch-spike.md` §1.1, the `x.m _ b` row):
                    // a lambda over `method_call`, and shorter than writing
                    // the lambda out.
                    try g.line(8, "|> List.map ({s}.helper{d} _)", .{ receiver, g.index })
                else
                    try g.line(8, "|> List.map helper{d}", .{g.index}),
                else => try g.line(8, "|> List.reverse", .{}),
            }
        }
        if (g.chance(50)) {
            try g.line(8, "|> List.foldl 0 (\\x acc -> acc + x)", .{});
        } else {
            try g.line(8, "|> sum{d}", .{g.index});
        }
    }

    fn ifFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "classify");
        // `==` on a CUSTOM TYPE (§3): `Msg<i>` has no `pub eq`, so this
        // is the derived `eq` of §9 over a padded constructor record, which
        // is one of the two shapes M4 and M5's R4 are about.
        const custom_eq = g.dispatch() and n % 3 == 0;
        if (custom_eq) {
            try g.line(0, "{s} : Msg{d}, Int -> String", .{ name, g.index });
            try g.line(0, "{s} msg n =", .{name});
            _ = g.pushFunction("msg");
        } else {
            try g.line(0, "{s} : Int -> String", .{name});
            try g.line(0, "{s} n =", .{name});
        }
        _ = g.push("n");
        if (custom_eq) {
            try g.line(4, "if msg == Reset then", .{});
        } else {
            try g.line(4, "if n < 0 then", .{});
        }
        try g.line(8, "\"negative\"", .{});
        const arms = g.rng.uintLessThan(u32, 3);
        var i: u32 = 0;
        const indent: usize = 4;
        while (i < arms) : (i += 1) {
            try g.line(indent, "else if n < {d} then", .{(i + 1) * 10});
            try g.line(indent + 4, "\"{s}\"", .{g.pick([]const u8, &words)});
        }
        try g.line(indent, "else", .{});
        if (g.chance(40)) {
            try g.line(indent + 4, "\"big: ${{n}}\"", .{});
        } else {
            try g.line(indent + 4, "String.fromInt n ++ \" is big\"", .{});
        }
    }

    fn recordFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "rename");
        try g.line(0, "{s} : String, Model{d} -> Model{d}", .{ name, g.index, g.index });
        try g.line(0, "{s} label model =", .{name});
        _ = g.push("label");
        _ = g.push("model");
        // `==` on a RECORD (§3): five fields, one of them a `List Int`,
        // so the derived `eq` of §9 recurses — the shape M5's R4 times and
        // M4 measures the bytes of. Same line count as the plain form.
        if (g.chance(50)) {
            const bump = g.rng.uintLessThan(u32, 5);
            try g.line(4, "{{ model | name = label, count = model.count + {d} }}", .{bump});
        } else if (g.dispatch()) {
            try g.line(4, "if model == init{d} then", .{g.index});
            try g.line(8, "model", .{});
            try g.line(4, "else", .{});
            try g.line(8, "{{ model | name = String.toUpper label }}", .{});
        } else {
            try g.line(4, "{{ model", .{});
            try g.line(8, "| name = String.toUpper label", .{});
            try g.line(8, ", items = List.map [ model ] .count", .{});
            try g.line(4, "}}", .{});
        }
    }

    fn tupleFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "split");
        try g.line(0, "{s} : ( Int, String ) -> ( String, Int )", .{name});
        try g.line(0, "{s} pair =", .{name});
        _ = g.push("pair");
        if (g.chance(50)) {
            try g.line(4, "( pair.1, pair.0 * {d} )", .{1 + g.rng.uintLessThan(u32, 4)});
        } else {
            try g.line(4, "case pair of", .{});
            try g.line(8, "( count, label ) ->", .{});
            try g.line(12, "( label ++ \"!\", count )", .{});
        }
    }

    fn stringFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "greet");
        try g.line(0, "{s} : String, Int -> String", .{name});
        try g.line(0, "{s} who times =", .{name});
        _ = g.push("who");
        _ = g.push("times");
        switch (g.rng.uintLessThan(u8, 3)) {
            0 => try g.line(4, "\"Hello, ${{who}}! You have ${{times}} new items.\\n\"", .{}),
            1 => try g.line(4, "\"\\\"${{who}}\\\" said: \" ++ String.repeat \"$\" times", .{}),
            else => try g.line(4, "String.fromChar '{c}' ++ who ++ \"\\t\" ++ String.fromInt times", .{g.pick(u8, "abcxyz")}),
        }
    }

    fn multilineFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "banner");
        try g.line(0, "{s} : String", .{name});
        try g.line(0, "{s} =", .{name});
        try g.line(4, "\\\\{s} report", .{g.pick([]const u8, &words)});
        try g.line(4, "\\\\==============", .{});
        if (g.chance(50)) try g.line(4, "\\\\SELECT * FROM {s} WHERE id = ${{id}}", .{g.pick([]const u8, &words)});
    }

    fn questionFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "parseTwice");
        try g.line(0, "{s} : String -> Result String Int", .{name});
        try g.line(0, "{s} s =", .{name});
        _ = g.push("s");
        try g.line(4, "Ok (parseOne{d}_{d} s? * 2)", .{ g.index, n });
        try g.declGap();
        try g.line(0, "parseOne{d}_{d} : String -> Result String Int", .{ g.index, n });
        try g.line(0, "parseOne{d}_{d} s =", .{ g.index, n });
        try g.line(4, "case String.toInt s of", .{});
        try g.line(8, "Just value ->", .{});
        try g.line(12, "Ok value", .{});
        try g.blank();
        try g.line(8, "Nothing ->", .{});
        try g.line(12, "Err \"not a number: ${{s}}\"", .{});
    }

    fn bigCaseFn(g: *Module, n: u32) Io.Writer.Error!void {
        var buf: [32]u8 = undefined;
        const name = g.fnName(&buf, n, "describe");
        try g.line(0, "{s} : Int -> String", .{name});
        try g.line(0, "{s} code =", .{name});
        _ = g.push("code");
        try g.line(4, "case code of", .{});
        const arms = 8 + g.rng.uintLessThan(u32, 40);
        var i: u32 = 0;
        while (i < arms) : (i += 1) {
            if (i != 0) try g.blank();
            if (i == 0) {
                try g.line(8, "-1 ->", .{});
            } else if (g.chance(20)) {
                // The same VALUE as the decimal arm would have been, spelled
                // in hex: the point is to exercise the lexer's hex path, and
                // `i * 16` made arm 1 (`0x10`) and arm 16 collide, which is
                // a `redundant_pattern` in generated code — a generator bug
                // (checker.md §9).
                try g.line(8, "0x{X} ->", .{i});
            } else {
                try g.line(8, "{d} ->", .{i});
            }
            if (g.chance(15)) {
                // A nested construct inside the branch: layout rule 2.
                try g.line(12, "let", .{});
                const mark = g.scopeMark();
                const local = g.bind();
                try g.line(16, "{s} =", .{local});
                try g.line(20, "code * {d}", .{i + 1});
                try g.line(12, "in", .{});
                try g.line(12, "\"{s} ${{{s}}}\"", .{ g.pick([]const u8, &words), local });
                g.scopeReset(mark);
            } else {
                try g.line(12, "\"{s} {s}\"", .{ g.pick([]const u8, &words), g.pick([]const u8, &words) });
            }
        }
        try g.blank();
        try g.line(8, "_ ->", .{});
        try g.line(12, "\"unknown\"", .{});
    }

    // ---- single-line expressions ---------------------------------------

    /// Write one expression on the current line. Nested binary operands
    /// are always parenthesised, so no chain is ambiguous or
    /// non-associative.
    fn expr(g: *Module, depth: u32) Io.Writer.Error!void {
        if (depth == 0) return g.atom();
        switch (g.rng.uintLessThan(u8, 9)) {
            0, 1 => {
                // Arithmetic only: a comparison or a logical operator would
                // produce a `Bool` where the caller wants an `Int`.
                try g.operand(depth - 1);
                try g.w.print(" {s} ", .{g.pick([]const u8, &.{ "+", "-", "*", "//", "^" })});
                try g.operand(depth - 1);
            },
            2 => {
                // `helper<i>` is a method of `Model<i>` in dispatch mode, so
                // the call goes through a receiver: `init<i>` is this
                // module's own `Model<i>` and is always in scope.
                //
                // A constrained helper with no call site yet takes priority:
                // called at the CONCRETE type `Model<i>`, it is the site
                // that has to supply the evidence argument (§8.1), and it
                // costs the same bytes and the same draws as the method call
                // it displaces.
                if (g.dispatch()) {
                    if (g.takeUncalledWhere()) |helper| {
                        try g.w.print("{s} {s} ", .{ helper, receiver });
                    } else {
                        try g.w.print("{s}.helper{d} ", .{ receiver, g.index });
                    }
                } else {
                    try g.w.print("helper{d} ", .{g.index});
                }
                try g.atom();
            },
            3 => {
                // Saturated, always: a partial application here is the
                // TOO FEW ARGS the checker is right to complain about.
                const call = g.pick(PreludeCall, &prelude_calls);
                try g.w.print("{s} ", .{call.prefix});
                try g.atom();
                if (call.arity == 2) {
                    try g.w.writeByte(' ');
                    try g.atom();
                }
            },
            4 => {
                // Lambda applied through a prelude function.
                const mark = g.scopeMark();
                const param = g.bind();
                try g.w.print("List.foldl [ ", .{});
                g.scopeReset(mark);
                try g.atom();
                try g.w.print(" ] 0 (\\{s} carry -> carry + {s})", .{ param, param });
            },
            5 => {
                try g.w.writeAll("Maybe.withDefault (Just ");
                try g.atom();
                try g.w.writeAll(") ");
                try g.atom();
            },
            6 => try g.crossModuleCall(),
            7 => {
                try g.w.writeAll("negate ");
                try g.operand(depth - 1);
            },
            else => {
                // The condition is a comparison, so it really is a `Bool`.
                try g.w.writeAll("if ");
                try g.operand(depth - 1);
                try g.w.print(" {s} ", .{g.pick([]const u8, &.{ "==", "/=", "<", ">", "<=", ">=" })});
                try g.operand(depth - 1);
                try g.w.writeAll(" then ");
                try g.atom();
                try g.w.writeAll(" else ");
                try g.atom();
            },
        }
    }

    /// An operand of a binary operator: an atom, or a parenthesised
    /// sub-expression.
    fn operand(g: *Module, depth: u32) Io.Writer.Error!void {
        if (depth == 0 or g.chance(50)) return g.atom();
        try g.w.writeByte('(');
        try g.expr(depth);
        try g.w.writeByte(')');
    }

    fn crossModuleCall(g: *Module) Io.Writer.Error!void {
        // The cross-module method call of §6.8: the receiver's type is
        // declared in the other module, and the method is resolved there —
        // through an `exposing` list that does not name it, or through an
        // alias. This is the call shape that forces an implicit graph edge,
        // and the reason the generated corpus is worth running the checker
        // over at all once S3 lands.
        if (g.exposed_count > 0 and g.chance(50)) {
            const k = g.exposed[g.rng.uintLessThan(usize, g.exposed_count)];
            if (g.dispatch()) {
                if (g.takeUncalledWhere()) |helper| {
                    try g.w.print("{s} {s} ", .{ helper, receiver });
                } else {
                    try g.w.print("(P{d}.Reset).helper{d} ", .{ k, k });
                }
            } else {
                try g.w.print("helper{d} ", .{k});
            }
            return g.atom();
        }
        if (g.aliased_count > 0) {
            const k = g.aliased[g.rng.uintLessThan(usize, g.aliased_count)];
            if (g.dispatch()) {
                if (g.takeUncalledWhere()) |helper| {
                    try g.w.print("{s} {s} ", .{ helper, receiver });
                } else {
                    try g.w.print("(P{d}.Reset).helper{d} ", .{ k, k });
                }
            } else {
                try g.w.print("P{d}.helper{d} ", .{ k, k });
            }
            return g.atom();
        }
        // The module that imports nothing: its own method, or a constrained
        // helper still waiting for a call site.
        if (g.dispatch()) {
            if (g.takeUncalledWhere()) |helper| {
                try g.w.print("{s} {s} ", .{ helper, receiver });
            } else {
                try g.w.print("{s}.helper{d} ", .{ receiver, g.index });
            }
        } else {
            try g.w.print("helper{d} ", .{g.index});
        }
        return g.atom();
    }

    /// An `Int`-typed atom. Every local in scope is one — the generator
    /// only ever binds `Int`s — so the whole expression language is closed
    /// under `Int`, which is what makes the corpus type-correct without a
    /// type checker inside the generator.
    fn atom(g: *Module) Io.Writer.Error!void {
        switch (g.rng.uintLessThan(u8, 8)) {
            0, 1, 2 => if (g.anyLocal()) |l| try g.w.writeAll(l) else try g.w.print("{d}", .{g.rng.uintLessThan(u32, 100)}),
            3, 4 => try g.w.print("{d}", .{g.rng.uintLessThan(u32, 1000)}),
            5 => try g.w.print("0x{X}", .{g.rng.uintLessThan(u32, 4096)}),
            6 => try g.w.print("( {d}, \"{s}\" ).0", .{ g.rng.uintLessThan(u32, 9), g.pick([]const u8, &words) }),
            else => try g.w.print("init{d}.count", .{g.index}),
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the same seed and index produce identical bytes; different seeds differ" {
    var a: Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    var c: Io.Writer.Allocating = .init(testing.allocator);
    defer c.deinit();

    const lines_a = try writeModule(&a.writer, default_seed, 7);
    const lines_b = try writeModule(&b.writer, default_seed, 7);
    _ = try writeModule(&c.writer, default_seed + 1, 7);
    try testing.expectEqualStrings(a.written(), b.written());
    try testing.expectEqual(lines_a, lines_b);
    try testing.expect(!std.mem.eql(u8, a.written(), c.written()));
    try testing.expectEqual(lines_a, std.mem.count(u8, a.written(), "\n"));
}

test "generated modules respect the lexical rules the lexer enforces" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (0..40) |i| {
        out.clearRetainingCapacity();
        _ = try writeModule(&out.writer, default_seed, @intCast(i));
        const text = out.written();
        // No tabs, no CR, LF-terminated, no trailing whitespace on any line,
        // declarations at column 1 and continuations indented.
        try testing.expect(std.mem.indexOfScalar(u8, text, '\t') == null);
        try testing.expect(std.mem.indexOfScalar(u8, text, '\r') == null);
        try testing.expect(text[text.len - 1] == '\n');
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            try testing.expect(l.len == 0 or l[l.len - 1] != ' ');
        }
        try testing.expect(std.mem.startsWith(u8, text, "--! "));
        try testing.expect(std.mem.indexOf(u8, text, "\nimport ") != null);
        try testing.expect(std.mem.indexOf(u8, text, "\npub type alias Model") != null);
    }
}

test "no parameter inside a let block shadows one of the block's bindings" {
    // The generator's output must be free of `shadowing` (language.md §7.3),
    // and this is the one shape that ever slipped through: a `let` group is
    // mutually recursive, so a lambda parameter chosen while writing the
    // FIRST binding's value is in scope of the LAST binding's name too.
    // `beni check .zig-cache/bench-gen` is the end-to-end statement of the
    // same claim; this test makes it fail here, in milliseconds.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var blocks: usize = 0;
    for (0..120) |i| {
        out.clearRetainingCapacity();
        _ = try writeModule(&out.writer, default_seed, @intCast(i));
        blocks += try checkLetBlocks(out.written());
    }
    // `let` is one of ten random declaration kinds, so assert the scan
    // actually found blocks: a test that passes by finding nothing is not
    // a test.
    try testing.expect(blocks > 40);
}

/// Scan every top-level `let` block in `text` (the ones `letFn` writes, at
/// indent 4 with bindings at indent 8) and fail if any name bound inside it
/// — a lambda parameter, a let-bound function's parameter — repeats one of
/// the block's binding names, or if two bindings share a name. Returns the
/// number of blocks scanned.
fn checkLetBlocks(text: []const u8) !usize {
    var blocks: usize = 0;
    var binding_buf: [8][]const u8 = undefined;
    var bindings: []const []const u8 = binding_buf[0..0];
    var param_buf: [64][]const u8 = undefined;
    var params: []const []const u8 = param_buf[0..0];
    var in_block = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // A line at column 1 starts the next declaration and ends the block.
        if (in_block and line.len != 0 and line[0] != ' ') {
            try expectNoShadowing(bindings, params);
            in_block = false;
        }
        if (std.mem.eql(u8, line, "    let")) {
            in_block = true;
            blocks += 1;
            bindings = binding_buf[0..0];
            params = param_buf[0..0];
            continue;
        }
        if (!in_block) continue;

        if (std.mem.startsWith(u8, line, "        ") and line.len > 8 and line[8] != ' ') {
            const body = line[8..];
            if (std.mem.startsWith(u8, body, "twice ")) {
                bindings = try append(&binding_buf, bindings, "twice");
                params = try append(&param_buf, params, identAt(body["twice ".len..]));
            } else {
                const bound = identAt(body);
                const after = body[bound.len..];
                // ` = ` only: `name : Int` is the annotation of the
                // binding on the next line, not a second binding.
                if (bound.len != 0 and std.mem.startsWith(u8, after, " =")) {
                    bindings = try append(&binding_buf, bindings, bound);
                }
            }
        }
        var rest = line;
        while (std.mem.indexOf(u8, rest, "(\\")) |at| {
            rest = rest[at + 2 ..];
            params = try append(&param_buf, params, identAt(rest));
        }
    }
    if (in_block) try expectNoShadowing(bindings, params);
    return blocks;
}

/// `list` with `name` appended, in `buf`. The buffers are sized for the
/// shapes `letFn` writes; overflowing one means the generator grew a case
/// this scan no longer covers, which is a failure, not a silent truncation.
fn append(buf: [][]const u8, list: []const []const u8, name: []const u8) ![]const []const u8 {
    if (list.len == buf.len) return error.ScanBufferTooSmall;
    buf[list.len] = name;
    return buf[0 .. list.len + 1];
}

fn expectNoShadowing(bindings: []const []const u8, params: []const []const u8) !void {
    for (bindings, 0..) |b, i| {
        for (bindings[i + 1 ..]) |other| if (std.mem.eql(u8, b, other)) {
            std.debug.print("let block binds `{s}` twice\n", .{b});
            return error.DuplicateBinding;
        };
        for (params) |p| if (std.mem.eql(u8, b, p)) {
            std.debug.print("parameter `{s}` shadows a sibling let binding\n", .{p});
            return error.ParameterShadowsBinding;
        };
    }
}

/// The identifier at the start of `s`, empty when there is none.
fn identAt(s: []const u8) []const u8 {
    var n: usize = 0;
    while (n < s.len and (std.ascii.isAlphanumeric(s[n]) or s[n] == '_')) n += 1;
    return s[0..n];
}

test "the dispatch corpus is a pure function of seed and index, and is not the plain one" {
    var a: Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();

    const lines_a = try writeModuleMode(&a.writer, default_seed, 7, .dispatch);
    const lines_b = try writeModuleMode(&b.writer, default_seed, 7, .dispatch);
    _ = try writeModuleMode(&plain.writer, default_seed, 7, .plain);
    try testing.expectEqualStrings(a.written(), b.written());
    try testing.expectEqual(lines_a, lines_b);
    try testing.expectEqual(lines_a, std.mem.count(u8, a.written(), "\n"));
    try testing.expect(!std.mem.eql(u8, a.written(), plain.written()));
}

test "dispatch modules respect the lexical rules the lexer enforces" {
    // The same claim the plain corpus makes. It is the ONLY end-to-end
    // statement available about the dispatch tree until S2 lands the
    // syntax, because until then `beni check` on it cannot parse.
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (0..40) |i| {
        out.clearRetainingCapacity();
        _ = try writeModuleMode(&out.writer, default_seed, @intCast(i), .dispatch);
        const text = out.written();
        try testing.expect(std.mem.indexOfScalar(u8, text, '\t') == null);
        try testing.expect(std.mem.indexOfScalar(u8, text, '\r') == null);
        try testing.expect(text[text.len - 1] == '\n');
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            try testing.expect(l.len == 0 or l[l.len - 1] != ' ');
        }
        try testing.expect(std.mem.startsWith(u8, text, "--! "));
        try testing.expect(std.mem.indexOf(u8, text, "\nimport ") != null);
        try testing.expect(std.mem.indexOf(u8, text, "\npub type alias Model") != null);
    }
}

test "the dispatch tree is the same project as the plain one, written with dispatch" {
    // M1b compares the two corpora directly (§7), so anything that differs
    // between them other than the dispatch text is a confound. Four are
    // guarded here because each one would land on a different row of the
    // table as if it were a cost of the feature:
    //
    //   - the module list and the declaration names (the project itself);
    //   - the count of `pub` values, because writing the interface is what
    //     the checker is most sensitive to (bench/README.md's M2d entry
    //     measures `fillInterface` at 19x on a module whose declarations
    //     are `pub`);
    //   - the count of ANNOTATED declarations, because an annotation is a
    //     written type to check against rather than one to infer;
    //   - the size, in lines and in bytes, because `loc_per_s` and
    //     `mb_per_s` are both per-unit-of-input rates.
    var plain: Io.Writer.Allocating = .init(testing.allocator);
    defer plain.deinit();
    var disp: Io.Writer.Allocating = .init(testing.allocator);
    defer disp.deinit();

    const modules = try moduleCount(default_seed, 20_000);
    try testing.expect(modules > 40);

    var a: Shape = .{};
    var b: Shape = .{};
    var helpers: WhereHelpers = .{};
    var found: struct {
        method: bool = false,
        cross_module: bool = false,
        where_update: bool = false,
        where_method: bool = false,
        inferred: bool = false,
        record_eq: bool = false,
        custom_eq: bool = false,
        dict: bool = false,
        set: bool = false,
        placeholder: bool = false,
    } = .{};
    for (0..modules) |i| {
        plain.clearRetainingCapacity();
        disp.clearRetainingCapacity();
        a.lines += try writeModuleMode(&plain.writer, default_seed, @intCast(i), .plain);
        b.lines += try writeModuleMode(&disp.writer, default_seed, @intCast(i), .dispatch);
        try expectSameDeclarations(plain.written(), disp.written());
        a.count(plain.written());
        b.count(disp.written());
        try helpers.count(disp.written());

        const text = disp.written();
        if (std.mem.indexOf(u8, text, ".helper") != null) found.method = true;
        if (std.mem.indexOf(u8, text, "(P") != null and std.mem.indexOf(u8, text, ".Reset).helper") != null) found.cross_module = true;
        if (std.mem.indexOf(u8, text, "    where a.update") != null) found.where_update = true;
        if (std.mem.indexOf(u8, text, "    where a.helper") != null) found.where_method = true;
        if (std.mem.indexOf(u8, text, "if model == init") != null) found.record_eq = true;
        if (std.mem.indexOf(u8, text, "if msg == Reset then") != null) found.custom_eq = true;
        if (std.mem.indexOf(u8, text, "List.foldl xs Dict.empty (\\x acc -> acc.insert x 1)") != null) found.dict = true;
        if (std.mem.indexOf(u8, text, "List.foldl xs Set.empty (\\x acc -> acc.insert x)") != null) found.set = true;
        if (std.mem.indexOf(u8, text, "|> List.map ((Reset).helper") != null) found.placeholder = true;
    }
    // Every part of the M1b shape is really in the tree. A flag that
    // silently stopped firing would leave a corpus that measures the
    // feature's cost on code that does not use it, which is M1a.
    try testing.expect(found.method);
    try testing.expect(found.cross_module);
    try testing.expect(found.where_update);
    try testing.expect(found.where_method);
    try testing.expect(found.record_eq);
    try testing.expect(found.custom_eq);
    try testing.expect(found.dict);
    try testing.expect(found.set);
    try testing.expect(found.placeholder);

    // Interface shape: identical. See the header above for why each matters.
    try testing.expectEqual(a.pub_values, b.pub_values);
    try testing.expectEqual(a.annotated, b.annotated);

    // Within 2 % of the lines and 3 % of the bytes. Dispatch text is
    // genuinely longer — a method call names its receiver — so the byte
    // budget is the looser of the two, but it is a budget: at 6 % the
    // front end's MB/s rows would be comparing different amounts of input.
    try expectWithin("lines", a.lines, b.lines, 2);
    try expectWithin("bytes", a.bytes, b.bytes, 3);

    // Every constrained helper is CALLED. A constrained declaration nobody
    // calls never makes a call site pass an evidence argument, so §8.1's
    // `$m$k` would appear in the corpus as a parameter and never as an
    // argument, and the backend rows of §7 would measure half the feature.
    try testing.expect(helpers.total > 20);
    try testing.expectEqual(@as(usize, 0), helpers.uncalled);
    // …at a concrete type, which is the site that has to SUPPLY evidence…
    try testing.expect(helpers.concrete_sites > 10);
    // …and from inside another constrained helper, which is the site that
    // has to FORWARD the evidence it was given: two levels.
    try testing.expect(helpers.forwarding_sites > 0);
}

/// The counts the two trees must agree on.
const Shape = struct {
    pub_values: usize = 0,
    annotated: usize = 0,
    lines: u64 = 0,
    bytes: u64 = 0,

    fn count(shape: *Shape, text: []const u8) void {
        shape.bytes += text.len;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (l.len == 0 or l[0] == ' ' or std.mem.startsWith(u8, l, "--")) continue;
            var rest = l;
            if (std.mem.startsWith(u8, rest, "pub ")) {
                rest = rest["pub ".len..];
                if (!std.mem.startsWith(u8, rest, "type ") and !std.mem.startsWith(u8, rest, "opaque type ")) {
                    shape.pub_values += 1;
                }
            }
            if (std.mem.startsWith(u8, rest, "import ")) continue;
            if (std.mem.startsWith(u8, rest, "type ") or std.mem.startsWith(u8, rest, "opaque type ")) continue;
            if (std.mem.indexOf(u8, rest, " : ") != null) shape.annotated += 1;
        }
    }
};

fn expectWithin(what: []const u8, plain: u64, dispatch: u64, percent: u64) !void {
    const delta = @abs(@as(i64, @intCast(dispatch)) - @as(i64, @intCast(plain)));
    const budget = plain * percent / 100;
    if (delta > budget) {
        std.debug.print(
            "dispatch corpus is {d} {s} against {d} plain, over the {d} % budget of {d}\n",
            .{ dispatch, what, plain, percent, budget },
        );
        return error.DispatchCorpusDrifted;
    }
}

/// Call sites of the `where`-constrained helpers, over the whole tree.
const WhereHelpers = struct {
    total: usize = 0,
    uncalled: usize = 0,
    /// `scale<i>_<n> (Reset) …`: a call at a concrete NOMINAL type, which
    /// is where the evidence argument is supplied.
    concrete_sites: usize = 0,
    /// `scale<i>_<n> x …`: a call from inside another constrained helper,
    /// which is where the evidence argument is forwarded.
    forwarding_sites: usize = 0,

    const marker = " x n =";

    fn count(h: *WhereHelpers, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            if (l.len == 0 or l[0] == ' ') continue;
            if (!std.mem.endsWith(u8, l, marker)) continue;
            const name = l[0 .. l.len - marker.len];
            h.total += 1;

            var buf: [4][48]u8 = undefined;
            // Every occurrence of the name is followed by a space: the
            // annotation (`name : a, …`), the definition (`name x n =`) and
            // every call (`name init<i> …`, `name x (`). Matching the
            // trailing space is also what keeps `scale1_1` from matching
            // `scale1_10`.
            const with_space = try std.fmt.bufPrint(&buf[0], "{s} ", .{name});
            const annotation = try std.fmt.bufPrint(&buf[1], "{s} : a,", .{name});
            const declarations: usize = if (std.mem.indexOf(u8, text, annotation) != null) 2 else 1;
            const uses = std.mem.count(u8, text, with_space) - declarations;
            if (uses == 0) h.uncalled += 1;

            const concrete = try std.fmt.bufPrint(&buf[2], "{s} (Reset)", .{name});
            h.concrete_sites += std.mem.count(u8, text, concrete);
            const forwarded = try std.fmt.bufPrint(&buf[3], "{s} x (", .{name});
            h.forwarding_sites += std.mem.count(u8, text, forwarded);
        }
    }
};

/// Fail unless the two texts declare the same names at column 1, in the same
/// order. The declaration list IS the module's interface shape, and holding
/// it fixed is what lets M1b attribute a difference to dispatch rather than
/// to a different program.
fn expectSameDeclarations(plain: []const u8, dispatch: []const u8) !void {
    var a = std.mem.splitScalar(u8, plain, '\n');
    var b = std.mem.splitScalar(u8, dispatch, '\n');
    var last_left: []const u8 = "";
    var last_right: []const u8 = "";
    while (true) {
        // An annotation and its definition both name the declaration, and
        // whether a declaration HAS an annotation differs between the modes
        // (the `where` helpers always do). Collapsing the repeat compares
        // the declarations themselves rather than the lines.
        const left = nextDeclaration(&a, &last_left);
        const right = nextDeclaration(&b, &last_right);
        if (left == null and right == null) return;
        if (left == null or right == null) {
            std.debug.print("declaration lists differ in length: {?s} vs {?s}\n", .{ left, right });
            return error.DeclarationListsDiffer;
        }
        if (!std.mem.eql(u8, left.?, right.?)) {
            std.debug.print("declaration `{s}` became `{s}`\n", .{ left.?, right.? });
            return error.DeclarationRenamed;
        }
    }
}

/// The next declared NAME: a column-1 line that is not a comment, not an
/// import and not a type declaration, with `pub` stripped, skipping a
/// repeat of `last` (an annotation followed by its definition).
fn nextDeclaration(lines: *std.mem.SplitIterator(u8, .scalar), last: *[]const u8) ?[]const u8 {
    while (lines.next()) |l| {
        if (l.len == 0 or l[0] == ' ' or std.mem.startsWith(u8, l, "--")) continue;
        var rest = l;
        if (std.mem.startsWith(u8, rest, "pub ")) rest = rest["pub ".len..];
        if (std.mem.startsWith(u8, rest, "import ")) continue;
        if (std.mem.startsWith(u8, rest, "type ")) continue;
        if (std.mem.startsWith(u8, rest, "opaque type ")) continue;
        const name = identAt(rest);
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, last.*)) continue;
        last.* = name;
        return name;
    }
    return null;
}

test "the wide module is a pure function of seed and size, and holds the shape it claims" {
    var a: Io.Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Io.Writer.Allocating = .init(testing.allocator);
    defer b.deinit();

    const shape: WideShape = .init(2000);
    var pa: std.Random.DefaultPrng = .init(default_seed);
    var ga: Wide = .{ .w = &a.writer, .rng = pa.random(), .shape = shape };
    try ga.bulk();
    var pb: std.Random.DefaultPrng = .init(default_seed);
    var gb: Wide = .{ .w = &b.writer, .rng = pb.random(), .shape = shape };
    try gb.bulk();
    try testing.expectEqualStrings(a.written(), b.written());
    try testing.expectEqual(ga.lines, std.mem.count(u8, a.written(), "\n"));

    const text = a.written();
    // The four shapes the corpus exists to make expensive (see `WideShape`),
    // each asserted by its last member: a count that silently fell to zero
    // would still `check` clean and measure nothing.
    try testing.expect(std.mem.indexOf(u8, text, "\n    , f99 : Int\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\npub bump19 : Wide -> Wide\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\npub type alias Chain199 =\n    Int -> Int\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\npub bulk1752 : Int -> Int\n") != null);
    // EVERY declaration is `pub`: `fillInterface`'s cost is per exported
    // value, and the same module without `pub` was two orders of magnitude
    // cheaper, which is the whole point of the shape.
    var declarations: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (l.len == 0 or l[0] == ' ' or std.mem.startsWith(u8, l, "--")) continue;
        if (std.mem.startsWith(u8, l, "pub ")) {
            // An annotation and its definition are one declaration; count
            // the annotation, and the definition line repeats the name
            // without `pub`.
            declarations += 1;
            continue;
        }
        // The only other column-1 lines are those definition lines.
        try testing.expect(std.mem.indexOfScalar(u8, l, '=') != null);
    }
    try testing.expectEqual(@as(usize, shape.total()), declarations);
}

test "the wide shape spends its whole budget, at every size" {
    // A budget smaller than the fixed part must not underflow, and a big
    // one must not overshoot: the README's trend is only readable if
    // `--wide=n` really writes n declarations.
    for ([_]u32{ 1, 10, 64, 400, 2000, 4000, 8000, 20_000, 100_000 }) |n| {
        const shape: WideShape = .init(n);
        try testing.expect(shape.width >= WideShape.min_width);
        try testing.expect(shape.width <= WideShape.max_width);
        try testing.expect(shape.chain <= WideShape.max_chain);
        try testing.expectEqual(@max(n, WideShape.floor), shape.total());
    }
}

test "every pathological case is the size and shape it claims, and named by a valid module path" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    inline for (@typeInfo(Pathological.Case).@"enum".fields) |field| {
        const case: Pathological.Case = @enumFromInt(field.value);
        const which: Pathological = .{ .case = case };
        out.clearRetainingCapacity();
        try writePathological(&out.writer, which);
        const text = out.written();
        try testing.expect(text[text.len - 1] == '\n');
        switch (case) {
            // The point of the four originals is that the payload is on ONE
            // line: a file with a million short lines is a different stress.
            .@"big-list", .@"big-string", .@"big-ident", .@"deep-lambdas" => {
                try testing.expect(std.mem.count(u8, text, "\n") <= 2);
                try testing.expect(text.len > 500_000);
            },
            // The chain is the opposite shape on purpose: many small
            // declarations, and what it makes expensive is the checker, not
            // the lexer. Its size assertion is therefore a DECLARATION
            // count, and the last link has to name the one before it — a
            // chain whose links stopped referring to each other would check
            // instantly and measure nothing (§7 M2).
            .@"constraint-chain" => {
                const n = Pathological.default_chain;
                try testing.expectEqual(@as(usize, n), std.mem.count(u8, text, "\npub f"));
                try testing.expect(std.mem.indexOf(u8, text, "\npub f1 x =\n    x.m1 1\n") != null);
                var buf: [64]u8 = undefined;
                const last = try std.fmt.bufPrint(&buf, "\npub f{d} x =\n    x.m{d} 1 + f{d} x\n", .{ n, n, n - 1 });
                try testing.expect(std.mem.indexOf(u8, text, last) != null);
            },
        }
        // `Pathological.parse` round-trips the name the flag takes.
        try testing.expectEqual(@as(?Pathological, which), Pathological.parse(field.name));
        // Every path segment is an upper identifier (language.md §1), so
        // the file has a module name and `beni check` on it does not
        // report `invalid_module_path` instead of what it is here for.
        var segments = std.mem.splitScalar(u8, which.path(), '/');
        while (segments.next()) |segment| {
            const stem = if (std.mem.endsWith(u8, segment, ".beni")) segment[0 .. segment.len - ".beni".len] else segment;
            try testing.expect(stem.len != 0 and std.ascii.isUpper(stem[0]));
        }
    }
    try testing.expectEqual(@as(?Pathological, null), Pathological.parse("no-such-case"));
    // Only the chain takes a size, and it must be a positive number: a
    // typo has to be an error, not a silently ignored suffix.
    try testing.expectEqual(@as(?Pathological, .{ .case = .@"constraint-chain", .n = 5000 }), Pathological.parse("constraint-chain=5000"));
    try testing.expectEqual(@as(?Pathological, null), Pathological.parse("constraint-chain=0"));
    try testing.expectEqual(@as(?Pathological, null), Pathological.parse("constraint-chain=x"));
    try testing.expectEqual(@as(?Pathological, null), Pathological.parse("big-list=7"));
}

test "the constraint chain is a pure function of its length and grows one constraint per link" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var again: Io.Writer.Allocating = .init(testing.allocator);
    defer again.deinit();
    try writeConstraintChain(&out.writer, 64);
    try writeConstraintChain(&again.writer, 64);
    try testing.expectEqualStrings(out.written(), again.written());

    const text = out.written();
    // Every method name distinct: the same name 64 times would MERGE to one
    // constraint (§6.2) and the case would measure nothing.
    var i: u32 = 1;
    var buf: [32]u8 = undefined;
    while (i <= 64) : (i += 1) {
        const method = try std.fmt.bufPrint(&buf, "x.m{d} 1", .{i});
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, method));
    }
    // No annotation anywhere: a `:` outside the doc header would let a
    // constraint discharge early and halve the case.
    try testing.expect(std.mem.indexOfScalar(u8, text[std.mem.indexOf(u8, text, "pub f1").?..], ':') == null);
}

test "module paths are valid upper-identifier segments" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Gen/Page0.beni", modulePath(&buf, 0));
    try testing.expectEqualStrings("Gen/Data/Store1.beni", modulePath(&buf, 1));
    try testing.expectEqualStrings("Gen/Ui/Widget2.beni", modulePath(&buf, 2));
    try testing.expectEqualStrings("Gen.Ui.Widget14", moduleName(&buf, 14));
}
