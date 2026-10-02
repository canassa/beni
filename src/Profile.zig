//! `--self-profile` (docs/design/frontend.md §6, fast-compiler.md §12).
//!
//! Records one complete (`X`) event per phase per file and per serial step,
//! plus counters at exit, and writes Chrome trace-event JSON
//! (`{"traceEvents":[...]}`) that Perfetto and speedscope open directly.
//!
//! Recording is per thread into a buffer preallocated at session start, so a
//! worker never allocates or synchronises to record: `end` is a bounds check
//! and a store. A full buffer counts the drop instead of growing — the count
//! is written as a `dropped_events` counter so a truncated trace says so.
//! With the flag off, every entry point is one `enabled` check and a return.
//!
//! Counters are what the incrementality tests assert ("dependents were not
//! re-checked"), which is why they exist before there is anything to count.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Profile = @This();

enabled: bool,
io: Io,
/// The origin every timestamp is measured from.
origin: Io.Timestamp,
/// One buffer per thread id, index = worker index (`tid` in the trace).
threads: []ThreadBuffer,
/// Written once, serially, at exit — never from a worker.
counters: [Counter.count]u64 = @splat(0),

/// A phase or serial step. Emitted as the event's `name`.
pub const Phase = enum {
    enumerate,
    read,
    lex,
    parse,
    lower,
    format,
    merge_interners,
    /// Serial (checker.md §4.2–§4.4): naming every module, building the
    /// import edges, finding cycles and producing the topological order.
    graph,
    /// Serial for now (checker.md §4.4 allows DAG parallelism later):
    /// cross-module name resolution and interface building, in that order.
    resolve,
    /// Serial, once per run: numbering every declared type of every module
    /// and settling equatability (checker.md §5). It has its own row
    /// because it can DOMINATE a build — a project of long alias chains
    /// spent 1.3 s of a 1.35 s compile here — and a phase that can dominate
    /// and does not appear in the trace defeats the instrument
    /// (`fast-compiler.md` §12).
    types,
    /// The persistent cache's key pass (`fast-compiler.md` §8): serial, once
    /// per run, over `graph.order`. It hashes every module's source and
    /// every sibling `.js`, which is why it has a row of its own — it is the
    /// one cost a run with no cache directory still pays, and a cost that
    /// does not appear in the trace defeats the instrument
    /// (`fast-compiler.md` §12).
    cache_key,
    /// The dependency digest pass (`checker.md` §7, `fast-compiler.md` §8):
    /// one 128-bit value per module beside its interface hash, carrying what a
    /// dependent reads about it that the record does not say. Its own row for
    /// `cache_key`'s reason — it runs on every checking run, cache directory or
    /// not, and a cost that does not appear in the trace defeats the instrument.
    dep_digest,
    /// Reading the cache entries, serial, once per run before the workers
    /// start (`fast-compiler.md` §8): `InternPool.Global` is thread-confined
    /// and a cross-process load must `getOrPut`, so the reads cannot be on
    /// the DAG.
    cache_load,
    /// Writing the cache entries, serial, once per run after the check
    /// (`fast-compiler.md` §8). One `create` and one `rename` per module
    /// written, which is the number `plans/m4-1.md` §7 measurement 3 exists
    /// to watch on the cold path.
    cache_store,
    /// Writing one file's front-end artifact, **on the worker that produced
    /// it**, inside the per-file phase (`fast-compiler.md` §8, `plans/m4-2.md`
    /// §6 A). Not a serial pass and not a pass of its own: that phase already
    /// does file I/O, is already parallel, and already reports nothing on
    /// failure. Its own row because the cold-path cost of six times the module
    /// cache's bytes is the number §6 B was argued on.
    frontend_store,
    /// Reading, validating, verifying and re-interning one file's front-end
    /// artifact, on the worker, in place of `read`+`lex`+`parse`+`lower`
    /// (`fast-compiler.md` §8). It is emitted on a MISS too, with zero bytes,
    /// so the row counts every lookup and not only the ones that paid off.
    frontend_load,
    /// The four halves of `frontend_load`, nested inside it, which is the
    /// split `plans/m4-2.md` §11 measurement 4 asks for and the one the
    /// symbol decision rests on: the `open`+`read`, the body-hash check and
    /// column decode, the structural `verify`, and the re-intern of the
    /// string table into the worker's `Local` pool. They double-count against
    /// their parent, like `constrain` and `solve` inside `check`.
    frontend_read,
    frontend_decode,
    frontend_verify,
    frontend_intern,
    /// Decoding, verifying, re-interning and installing one core file's
    /// front-end artifact from the checked core the binary carries
    /// (`fast-compiler.md` §8, *The checked core, embedded*), on the worker,
    /// in place of `lex`+`parse`+`lower`. Emitted on a hit only: a miss
    /// costs a binary search.
    embedded_load,
    /// Type checking, per module (checker.md §9). `constrain` and `solve`
    /// are the two halves of `check` so the constraint/solve split of
    /// research/02 §1 is visible in a trace, not just in the source.
    check,
    constrain,
    solve,
    /// Pattern usefulness, per module (checker.md §6.6, §9). Separate from
    /// `solve` because it runs after it, over the declarations that solved
    /// clean, and a regression in one must not be read as a regression in
    /// the other.
    exhaustive,
    /// The new checker's phases after P4 (`checker-v2.md` §5), per module
    /// and nested inside `check` like the three above, so no cost hides
    /// between events: P5's eager derived contexts and rows, P6's
    /// elaboration into the dispatch table, P8's publication of the
    /// interface record, and P9's round trips, cycle check, evidence assert
    /// and schema plan.
    derived,
    /// Effect inference's solve (transparent-effects-proposal.md §14.4),
    /// after `derived` and before `elaborate`: its own row because it is
    /// new work on every module, which program uses effects or not, and its
    /// cost is a budget (`plans/effects-plan.md` §3).
    effects,
    elaborate,
    publish,
    finish,
    /// Reachability elimination, once per build (`backend.md` §9): the
    /// declaration graph and the walk over it, inside `emit` and before a
    /// byte is lowered. Its own row because it is the pass that decides how
    /// much work `emit` then does — a build whose `emit` grew wants to know
    /// whether this grew with it or in spite of it — and because §9's
    /// throughput acceptance is stated about the two together.
    eliminate,
    /// Code generation, once per build (`backend.md` §13): `Bir` → `JsIr` →
    /// bytes for every module, plus the platform checks and the writes.
    /// `bench`'s `emit` line measures the same work without the I/O.
    emit,
    /// One module's `Bir` → `JsIr` → bytes, inside `emit`, on the worker
    /// that took it. Under `--release` a module has two: lowering and
    /// planning, then renaming and printing.
    emit_module,
    /// `--release` of an application: whole-program specialisation
    /// (`backend.md` §9), on the calling thread between lowering and
    /// printing.
    specialise,
    /// The writes that end `emit`: the output record, every output file,
    /// and the removal of what only the previous build wrote.
    write,
    render,
};

pub const Counter = enum {
    files,
    bytes,
    tokens,
    nodes,
    insts,
    diagnostics,
    /// Bytes the formatter produced, over the files it formatted (a file
    /// with a diagnostic has no canonical form and is not formatted). It is
    /// the `fmt` counterpart of `bytes`: the two together say how much of
    /// the input the formatter actually rewrote, and `fmt` runs that would
    /// silently stop formatting show up as a zero here.
    formatted_bytes,
    /// Modules in the graph, edges between them, and interfaces built
    /// (checker.md §4). The incrementality tests assert these did NOT
    /// move when only a body changed, which is why they exist now.
    modules,
    edges,
    interfaces,
    /// Code generation (`backend.md` §13): files and bytes of JavaScript
    /// `beni build` wrote. They are counters and not a line on stdout
    /// because `frontend.md` §1 gives stdout to the product and stderr to
    /// diagnostics, and a build's product is the files themselves — so
    /// "how much did it write" belongs in the trace, where the
    /// incrementality tests can assert that an edit rewrote ONE file.
    emitted_files,
    emitted_bytes,
    /// The checker's work (checker.md §9). The incrementality tests assert
    /// these did NOT move when only a body changed.
    unifications,
    generalisations,
    instantiations,
    /// v2's derived-context fixpoints over the modules it checked
    /// (`Check.Counters.derived_context_runs`): 0 on a fully warm run, the
    /// witness that a cache hit installs the published derived contexts
    /// instead of recomputing them (checker-v2.md §14.3).
    derived_context_runs,
    /// The persistent cache (`fast-compiler.md` §8). Modules whose entry was
    /// loaded and installed, modules whose entry was absent or unusable, and
    /// modules whose own check actually ran — which is what a warm-rebuild
    /// claim is made of, and the reason these exist before there is anything
    /// to load.
    ///
    /// `cache_hits + modules_checked` is every module of the graph; an
    /// uncacheable module counts as neither a hit nor a miss, because it was
    /// never eligible.
    cache_hits,
    cache_misses,
    modules_checked,
    /// Bytes written to the cache directory this run, over the entries that
    /// were actually stored. Zero without `--cache-dir`.
    cache_bytes,
    /// The front-end cache (`fast-compiler.md` §8). **These three are
    /// the load-bearing half of the cache's tests**: a phase that did not run is
    /// otherwise indistinguishable from a phase that ran fast, and §12's rule
    /// that a cost which does not appear in the trace defeats the instrument
    /// has a converse — a SAVING that does not appear in a counter is a
    /// timing and not a fact. A warm run must report 0 for all three.
    files_lexed,
    files_parsed,
    files_lowered,
    /// Files whose artifact was loaded and installed, and files whose
    /// artifact was absent or unusable. `frontend_hits + files_lowered` is
    /// every file of the project; a run with no cache directory counts
    /// neither, because nothing was eligible.
    frontend_hits,
    frontend_misses,
    /// The checked core the binary carries (`fast-compiler.md` §8, *The
    /// checked core, embedded*): core files whose front-end artifact, and
    /// core modules whose cache entry, were installed from it. Counted apart
    /// from `frontend_hits` and `cache_hits`, which are the cache
    /// directory's: `cache_hits + embedded_modules + modules_checked` is
    /// every module of the graph, and a build of an ordinary program on the
    /// embedded core checks no core module at all.
    embedded_files,
    embedded_modules,
    /// Bytes of front-end artifact written this run, over the files actually
    /// stored. Zero without `--cache-dir`.
    frontend_bytes,
    /// `--release`'s whole-program specialisation (`backend.md` §9): the
    /// statement lists its list sweeps copied to rewrite (`Spec.Stats`).
    /// A list holding nothing a sweep could act on is not counted, so the
    /// count does not grow with code the sweeps leave as it was.
    spec_lists_examined,

    pub const count = @typeInfo(Counter).@"enum".fields.len;
};

/// A complete event. `file` is a file index (or `no_file` for serial steps)
/// resolved to a path only at write time, so a worker stores 32 bytes and
/// no pointer.
pub const Event = struct {
    phase: Phase,
    file: u32,
    bytes: u32,
    start_ns: u64,
    duration_ns: u64,

    pub const no_file = std.math.maxInt(u32);
};

/// One worker's event buffer. Only that worker writes it, which is what
/// makes recording lock-free — but "no lock" is not "no contention": at 32
/// bytes two workers' buffers shared a cache line, so every `record` on one
/// core invalidated the other's line. Padded to a whole line so the
/// independence is real and not just formal.
pub const ThreadBuffer = struct {
    events: []Event,
    len: usize = 0,
    dropped: u64 = 0,
    _pad: [cache_line - (@sizeOf([]Event) + 2 * @sizeOf(usize)) % cache_line]u8 = undefined,
};

/// `std.atomic.cache_line` is the target's line size; naming it here keeps
/// the padding expression readable.
const cache_line = std.atomic.cache_line;

comptime {
    std.debug.assert(@sizeOf(ThreadBuffer) % cache_line == 0);
}

/// Handed back by `begin`, consumed by `end`.
pub const Token = struct { start_ns: u64 };

pub const Options = struct {
    enabled: bool,
    /// Number of thread buffers: one per worker.
    threads: u32,
    /// Fixed capacity of each buffer, in events. Overflow is counted.
    events_per_thread: usize = 4096,
};

pub fn init(gpa: Allocator, io: Io, options: Options) Allocator.Error!Profile {
    var profile: Profile = .{
        .enabled = options.enabled,
        .io = io,
        .origin = if (options.enabled) Io.Timestamp.now(io, .awake) else .zero,
        .threads = &.{},
    };
    if (!options.enabled) return profile;

    profile.threads = try gpa.alloc(ThreadBuffer, options.threads);
    errdefer gpa.free(profile.threads);
    var allocated: usize = 0;
    errdefer for (profile.threads[0..allocated]) |buffer| gpa.free(buffer.events);
    for (profile.threads) |*buffer| {
        buffer.* = .{ .events = try gpa.alloc(Event, options.events_per_thread) };
        allocated += 1;
    }
    return profile;
}

pub fn deinit(profile: *Profile, gpa: Allocator) void {
    for (profile.threads) |buffer| gpa.free(buffer.events);
    gpa.free(profile.threads);
    profile.* = undefined;
}

fn nowNs(profile: *const Profile) u64 {
    const now = Io.Timestamp.now(profile.io, .awake);
    return @intCast(profile.origin.durationTo(now).nanoseconds);
}

/// Start timing. Cheap enough to call unconditionally; returns a dummy when
/// disabled.
pub fn begin(profile: *const Profile) Token {
    if (!profile.enabled) return .{ .start_ns = 0 };
    return .{ .start_ns = profile.nowNs() };
}

/// How long ago `token` was taken, in nanoseconds. For a caller that sums
/// several disjoint stretches into one event (the checker's `constrain` and
/// `solve`, which interleave per binding group) and records the total with
/// `record`.
pub fn since(profile: *const Profile, token: Token) u64 {
    if (!profile.enabled) return 0;
    return profile.nowNs() - token.start_ns;
}

/// Record an event whose duration the caller measured itself. Same
/// thread-confinement rule as `end`.
pub fn record(profile: *Profile, tid: u32, phase: Phase, file: u32, bytes: u32, duration_ns: u64) void {
    if (!profile.enabled) return;
    const buffer = &profile.threads[tid];
    if (buffer.len == buffer.events.len) {
        buffer.dropped += 1;
        return;
    }
    buffer.events[buffer.len] = .{
        .phase = phase,
        .file = file,
        .bytes = bytes,
        .start_ns = profile.nowNs() -| duration_ns,
        .duration_ns = duration_ns,
    };
    buffer.len += 1;
}

/// Record the event started by `token` on thread `tid`. Only that thread may
/// call this with that `tid`.
pub fn end(profile: *Profile, tid: u32, token: Token, phase: Phase, file: u32, bytes: u32) void {
    if (!profile.enabled) return;
    const end_ns = profile.nowNs();
    const buffer = &profile.threads[tid];
    if (buffer.len == buffer.events.len) {
        buffer.dropped += 1;
        return;
    }
    buffer.events[buffer.len] = .{
        .phase = phase,
        .file = file,
        .bytes = bytes,
        .start_ns = token.start_ns,
        .duration_ns = end_ns - token.start_ns,
    };
    buffer.len += 1;
}

/// Add to a counter. Serial use only (the driver sums per-worker tallies
/// after the join and calls this once per counter).
pub fn addCounter(profile: *Profile, c: Counter, value: u64) void {
    if (!profile.enabled) return;
    profile.counters[@intFromEnum(c)] += value;
}

pub fn counter(profile: *const Profile, c: Counter) u64 {
    return profile.counters[@intFromEnum(c)];
}

/// Total events recorded across all threads (not counting dropped ones).
pub fn eventCount(profile: *const Profile) usize {
    var n: usize = 0;
    for (profile.threads) |buffer| n += buffer.len;
    return n;
}

/// Write the trace. `file_paths[i]` names file index `i` in `args.file`.
/// Timestamps are microseconds (Chrome's unit) with three decimals so
/// nanosecond phases stay visible.
pub fn write(profile: *const Profile, writer: *Io.Writer, file_paths: []const []const u8) Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try json.beginObject();
    try json.objectField("traceEvents");
    try json.beginArray();
    for (profile.threads, 0..) |buffer, tid| {
        for (buffer.events[0..buffer.len]) |event| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(@tagName(event.phase));
            try json.objectField("cat");
            try json.write("phase");
            try json.objectField("ph");
            try json.write("X");
            try json.objectField("ts");
            try writeMicros(&json, event.start_ns);
            try json.objectField("dur");
            try writeMicros(&json, event.duration_ns);
            try json.objectField("pid");
            try json.write(1);
            try json.objectField("tid");
            try json.write(tid);
            try json.objectField("args");
            try json.beginObject();
            if (event.file != Event.no_file) {
                try json.objectField("file");
                try json.write(if (event.file < file_paths.len) file_paths[event.file] else "?");
            }
            try json.objectField("bytes");
            try json.write(event.bytes);
            try json.endObject();
            try json.endObject();
        }
    }
    const end_ns = profile.nowNs();
    inline for (@typeInfo(Counter).@"enum".fields) |field| {
        try writeCounter(&json, field.name, end_ns, profile.counters[field.value]);
    }
    var dropped: u64 = 0;
    for (profile.threads) |buffer| dropped += buffer.dropped;
    try writeCounter(&json, "dropped_events", end_ns, dropped);
    try json.endArray();
    try json.endObject();
    try writer.writeByte('\n');
}

fn writeMicros(json: *std.json.Stringify, ns: u64) Io.Writer.Error!void {
    try json.print("{d}.{d:0>3}", .{ ns / 1000, ns % 1000 });
}

fn writeCounter(json: *std.json.Stringify, name: []const u8, ts_ns: u64, value: u64) Io.Writer.Error!void {
    try json.beginObject();
    try json.objectField("name");
    try json.write(name);
    try json.objectField("ph");
    try json.write("C");
    try json.objectField("ts");
    try writeMicros(json, ts_ns);
    try json.objectField("pid");
    try json.write(1);
    try json.objectField("tid");
    try json.write(0);
    try json.objectField("args");
    try json.beginObject();
    try json.objectField(name);
    try json.write(value);
    try json.endObject();
    try json.endObject();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// The trace shape the tests parse back. Mirrors what `write` emits.
const TraceEvent = struct {
    name: []const u8,
    cat: ?[]const u8 = null,
    ph: []const u8,
    ts: f64,
    dur: ?f64 = null,
    pid: u32,
    tid: u32,
    args: struct { file: ?[]const u8 = null, bytes: ?u32 = null, files: ?u64 = null, bytes_total: ?u64 = null },
};

test "write emits valid Chrome trace JSON with events and counters" {
    var profile = try Profile.init(testing.allocator, testing.io, .{ .enabled = true, .threads = 2, .events_per_thread = 8 });
    defer profile.deinit(testing.allocator);

    const t0 = profile.begin();
    profile.end(0, t0, .read, 0, 120);
    const t1 = profile.begin();
    profile.end(1, t1, .read, 1, 7);
    const t2 = profile.begin();
    profile.end(0, t2, .merge_interners, Event.no_file, 0);
    profile.addCounter(.files, 2);
    profile.addCounter(.bytes, 127);
    try testing.expectEqual(@as(usize, 3), profile.eventCount());

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try profile.write(&out.writer, &.{ "A.beni", "B.beni" });

    // Parse it back with std.json: the file is valid JSON of the expected
    // shape, and the events are the ones recorded.
    const parsed = try std.json.parseFromSlice(struct { traceEvents: []TraceEvent }, testing.allocator, out.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const events = parsed.value.traceEvents;
    try testing.expectEqual(@as(usize, 3 + Counter.count + 1), events.len);

    try testing.expectEqualStrings("read", events[0].name);
    try testing.expectEqualStrings("X", events[0].ph);
    try testing.expectEqualStrings("phase", events[0].cat.?);
    try testing.expectEqual(@as(u32, 0), events[0].tid);
    try testing.expectEqualStrings("A.beni", events[0].args.file.?);
    try testing.expectEqual(@as(u32, 120), events[0].args.bytes.?);
    try testing.expect(events[0].dur.? >= 0);

    try testing.expectEqualStrings("merge_interners", events[1].name);
    try testing.expectEqual(@as(?[]const u8, null), events[1].args.file);

    try testing.expectEqualStrings("read", events[2].name);
    try testing.expectEqual(@as(u32, 1), events[2].tid);
    try testing.expectEqualStrings("B.beni", events[2].args.file.?);

    // Counters, in enum order, then dropped_events.
    const files = events[3];
    try testing.expectEqualStrings("files", files.name);
    try testing.expectEqualStrings("C", files.ph);
    try testing.expectEqual(@as(u64, 2), files.args.files.?);
    try testing.expectEqualStrings("dropped_events", events[events.len - 1].name);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"dropped_events\":0") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"bytes\":127") != null);
}

test "a full buffer counts drops instead of growing" {
    var profile = try Profile.init(testing.allocator, testing.io, .{ .enabled = true, .threads = 1, .events_per_thread = 2 });
    defer profile.deinit(testing.allocator);
    for (0..5) |i| profile.end(0, profile.begin(), .lex, @intCast(i), 0);
    try testing.expectEqual(@as(usize, 2), profile.eventCount());
    try testing.expectEqual(@as(u64, 3), profile.threads[0].dropped);

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try profile.write(&out.writer, &.{});
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"dropped_events\":3") != null);
    // A file index without a path is written as "?" rather than crashing.
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"file\":\"?\"") != null);
}

test "a disabled profile records nothing and allocates nothing" {
    var profile = try Profile.init(testing.allocator, testing.io, .{ .enabled = false, .threads = 4 });
    defer profile.deinit(testing.allocator);
    profile.end(0, profile.begin(), .read, 0, 1);
    profile.addCounter(.files, 1);
    try testing.expectEqual(@as(usize, 0), profile.threads.len);
    try testing.expectEqual(@as(usize, 0), profile.eventCount());
    try testing.expectEqual(@as(u64, 0), profile.counter(.files));
}
