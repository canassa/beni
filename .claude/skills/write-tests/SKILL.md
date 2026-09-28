---
name: write-tests
description: Write black-box tests for beni, the Elm-like to JavaScript compiler. Use when asked to write tests, add coverage, add a scenario, or test compiler behaviour. The binary under test is a closed box driven by source files on disk and flags; its outputs are emitted JavaScript, diagnostics and exit codes — and the emitted JavaScript is itself run to prove it behaves. Guides boundary choice, corpus tests, diagnostic assertions, golden discipline, fuzzing and the harness contract.
---

# Test writer for beni

You are writing tests for a compiler written in Zig. Read this whole file before
writing a test. Zig API questions go through the `zig-developer` skill (std source
at `references/zig/lib/std/`), never memory.

## Philosophy: black-box, boundary first

Labels like unit/integration say nothing about what is being tested. What matters
is the **boundary**: what is inside the box and what is outside. Everything inside
is closed — the test touches it only through inputs, outputs and observable side
effects.

The first question for every test: *what behaviour am I validating, and what is the
smallest boundary that still represents it?* There are exactly three answers here.

### Boundary 1 — the compiler binary (the default, ~80% of tests)

`zig build test-blackbox`. The REAL compiler, built ReleaseSafe by Zig's
self-hosted backend and installed at `./zig-out/safe/bin/beni`
(`./zig-out/safe-llvm/bin/beni`, built by LLVM, under `-Dllvm`; `BENI_EXE`
either way), is spawned as a child process
against a temp project directory, configured **only** through CLI flags, env
vars and the files on disk. Inputs are `.beni` sources and
a manifest; outputs are the emitted JS, the diagnostics on stderr, the exit code,
and whatever lands in the out dir and cache dir.

There is no network and there are no stub servers — a compiler's "world" is a
filesystem. The harness builds that world: a temp project dir, a temp cache dir,
and an assertion API over both.

The test asks: *if the compiler were rewritten from scratch, would this test still
pass?* — and the module graph enforces the answer. The blackbox module imports
`std`, the harness, and the public diagnostic schema. It **cannot** import `Ast`,
`Sema`, `InternPool`, `JsIr` or any other internal: that is a compile error, not a
rule. A test that reaches into the compiler's guts is testing an implementation
that will change.

The daemon (§4 of the design doc) is driven the same way: the harness speaks its
socket protocol, because the daemon *is* the product. Watch-mode and incremental
behaviour can only be tested here.

### Boundary 2 — the emitted program (the semantic oracle)

Compile a program, then **run the emitted JavaScript** under Node and assert what
it printed or returned. This is the boundary that proves codegen is *correct*
rather than merely *stable*, and it is the one Elm's own suite never had.

Use it for: evaluation semantics, pattern-match dispatch, tail-call loops not
overflowing the stack, record update, string/list behaviour, arity and partial
application, numeric edge cases, and every `CodeGenBugs`-style regression.

```
source → beni → out.mjs → node → stdout compared to expected
```

A bug that changes emitted JS *shape* but not its behaviour must not fail these
tests; a bug that changes behaviour must. That is the whole point, and it is why
this boundary — not golden text — is the default for codegen work.

### Boundary 3 — a pure function, hermetic

`zig build test`. No processes, no filesystem, no sockets. For code that is
internal, self-contained and infrastructure-free: the unifier and its level
bookkeeping, occurs-check behaviour, SCC decomposition of binding groups, the
decision-tree compiler, the interner, the arena, permalink/slug helpers, and
**every parser's fuzz harness**.

Choose it only when testing through the binary would need dozens of scenarios to
reach the cases. Even here the function is a black box: inputs and outputs, no
reaching into private state.

The suites are separate build steps and **never folded together**: `test` stays
hermetic so it is fast and deterministic; `test-blackbox` depends on the install
step and spawns processes.

## Why this shape — the lesson from Elm's deleted suite

`docs/design/research/11-elm-testing.md` records what happened to elm/compiler's tests: deleted in
2018, never restored, 1,252 commits later there is still no suite and the only CI
builds a binary on tagged releases. Three failure modes to design against:

1. **Binary pass/fail on error cases.** Elm's `bad/` fixtures asserted only "this
   failed to compile" — never *which* error. For a language whose selling point is
   diagnostics, that leaves the flagship feature untested. **We assert the whole
   diagnostic.**
2. **Whole-file golden JS.** Every codegen change churned every snapshot, which
   makes the suite expensive to keep and easy to resent. **We run the program
   instead, and keep goldens narrow** (below).
3. **Silent decay.** The cabal test stanza was fully commented out *before* the
   tests were deleted. A suite that can be disabled without anyone noticing will
   be. **CI runs both suites on every commit and fails loudly** — never a
   tag-only pipeline.

## NEVER / ALWAYS

**NEVER**
- Import a compiler internal into a blackbox test. If you need `InternPool` to
  observe something, you are at the wrong boundary.
- Assert only that compilation failed. Assert the diagnostic: code, span, message.
- Golden the whole emitted file when running it would prove the same thing.
- Reach the compiler any way but files, flags, env and the daemon socket. If a
  behaviour cannot be reached that way, that is a **design bug in the compiler** —
  report it, do not work around it.
- Use `std.debug.print` assertions, `expect(true)`, or "is defined" checks.
- Match a diagnostic with `indexOf`/substring when the whole struct is available.
- Sleep for a fixed time and hope. Use the harness's bounded waits, which assert a
  concrete terminal condition and fail loudly on timeout.
- Let a test leak a process, a port, a thread or a temp directory.

**ALWAYS**
- Assert **the whole object** — response, diagnostic, or captured record.
- Verify side effects *and their absence*: on a failed compile, assert that no
  output file was written and no cache entry was created.
- Put a new parser behind a fuzz harness in the hermetic suite.
- Run the tiers of CLAUDE.md's *Testing tiers* green before reporting (see
  *Running the tests* below).

## CRITICAL: assertions must be broad

Assert the **entire** diagnostic or record, not the fields you think might break.

```zig
const r = try world.compile("Main.beni");
try testing.expectEqual(@as(u8, 1), r.exit_code);
try testing.expectEqual(@as(usize, 1), r.diagnostics.len);

try testing.expectEqualDeep(Diagnostic{
    .code = .too_few_args,
    .severity = .@"error",
    .span = .{ .file = "Main.beni", .start = .{ .row = 7, .col = 20 }, .end = .{ .row = 7, .col = 28 } },
    .title = "TOO FEW ARGS",
    .message = "The `get` function expects 2 arguments, but it got only 1:",
}, r.diagnostics[0]);
```

There is no `expect.any()`. Dynamic values (timestamps, temp paths, durations) are
**copied from the actual into the expected value** and then checked for *shape*
with harness helpers (`expectTempPath`, `expectRecentMicros`). Everything else is
a literal.

**The missing-argument diagnostic is load-bearing** — §9.3 keeps currying only on
the condition that this diagnostic lands convincingly. It gets its own fixture
suite in M2, and those tests are the evidence for that decision.

## Corpus tests: the directory is the assertion

Elm's one genuinely good idea, worth copying exactly: walk a fixture tree at test
time and generate one case per file, named by its path. Adding a test is dropping
in a file.

```
tests/corpus/
  good/            compiles clean; each has an adjacent .expected (stdout when run)
  bad/             must fail, each with a .diag file: the whole expected diagnostic
  regress/         named after the bug: Shadowing2.beni, TailRecursion_ListAny.beni
```

Fixtures are one idea each and as small as the idea allows. Put the intent in a
comment in the fixture itself. A `bad/` fixture without a `.diag` file is a
failure, not a pass — that is the Elm gap, mechanically closed.

**Run hashes.** A `run/` fixture also carries a `.run-hash`: per build (dev,
release), a SHA-256 of the whole emitted output tree, the golden and the Node
version, recorded only after that JavaScript ran and matched. The gates skip
Node for a build whose digest is listed and run it otherwise, so they verify
every change whether or not the hashes are current; stale ones only cost
Node runs, reported as one line. After an emitter, runtime or `core/` change,
a new or re-blessed `run/` fixture, or a Node upgrade, run `zig build
test-run-hashes` (with `-Dcorpus=run/MyFixture` for one) and commit the rewritten files. It never records a hash for a
build whose output does not match — that build is reported and gets none.

## Golden output: narrow, normalized, blessable

Goldens are for codegen *shape* claims that running the program cannot observe:
"this self-recursive function became a `while` loop", "this constructor emits a
uniform object shape", "this saturated call emitted a direct n-ary call and not an
`A2` adapter" (§9.3's specializer is measured here).

Rules that keep goldens from rotting the way Elm's did:
- Golden the **extracted declaration**, not the whole file.
- Normalize before comparing: strip the preamble, stable-sort emitted decls.
- Bless with `BENI_WRITE_EXPECTED=1`, and say so in the failure message. Force the
  value before writing so an error cannot truncate a golden to empty — Elm's
  harness got this right and it is worth copying.

## Test file structure

One `test "..."` per scenario, at file top level. Order the file as a story:
happy path first and complete; variations next; errors last, each verifying that
**nothing** happened. Use the banners — they make phases scannable:

```zig
test "self-recursive function compiles to a loop and does not overflow" {
    // ┌─────────────────────────────────────────┐
    // │ PREPARE                                 │
    // └─────────────────────────────────────────┘

    // ┌─────────────────────────────────────────┐
    // │ EXECUTE                                 │
    // └─────────────────────────────────────────┘

    // ┌─────────────────────────────────────────┐
    // │ VERIFY OUTPUT                           │
    // └─────────────────────────────────────────┘

    // ┌─────────────────────────────────────────┐
    // │ VERIFY SIDE EFFECTS                     │
    // └─────────────────────────────────────────┘
}
```

## The harness contract

`tests/blackbox/world.zig` and `session.zig`. If a scenario needs something they
do not offer, add it **there**, once. Starting point for the spawn protocol is
lar's verified-0.16 harness at `/home/canassa/lar/tests/blackbox/session.zig` —
same "same binary, env only" discipline, minus the sockets.

The world offers: build a project dir from a literal map of path → source; run the
compiler; run the emitted JS under Node and capture stdout; edit one file and
recompile (for incrementality); read the cache dir; assert on stderr.

Incremental scenarios are first-class, because §8 is where the design's risk is:
compile, edit a body, recompile, and assert **that dependents were not re-checked**
— observable through `--self-profile` counters, which exist for exactly this.

## Abuse scenarios are first-class

Hostile and degenerate source is a supported input, not an edge case: deeply nested
expressions and records, a 10MB literal, invalid UTF-8, mixed line endings, cyclic
imports, a module importing itself, duplicate declarations, unterminated strings and
comments at EOF, a file that is one long line. Each must produce a diagnostic, never
a panic, a hang, or an OOM — and must leave no partial output behind.

Size every generated input to the smallest that reaches what it is about: one
level past a nesting cap, one entry past a width limit, and for a regression
the size that failed before the fix — never ten times past. A declaration-order
test tries a fixed set of orders (the written one, the reversed one, a few
seeded shuffles, and any order a defect needed), never every permutation.

## Fixtures: capture, don't invent

Goldens come from real runs and carry a comment saying where they came from.
Prefer real Elm programs translated to beni over hand-written toys — the
`references/elm` clone has the shape of real code, and idiomatic input is what the
performance budget in §2 is stated against. Fixture files live under
`tests/fixtures/` and reach the hermetic suite via `addAnonymousImport` +
`@embedFile`, so it never touches the filesystem.

## Fuzz every byte-eater (hermetic suite)

The lexer, the parser, the manifest reader, and the cache-artifact loader. Contract:
**does not panic**. Arbitrary bytes may parse or may fail; under ReleaseSafe an
out-of-bounds index traps here first.

```zig
test "fuzz tokenizer" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const len = smith.sliceWithHash(&buf, 0xB3A17);
            var t = Tokenizer.init(buf[0..len]);
            while (t.next().tag != .eof) {}
        }
    }.testOne, .{});
}
```

(`std.testing.fuzz(context, testOne, options)` — verified 0.16; lar's
`src/mqtt.zig:845` is a working example.)

## Status and prerequisites

Both suites exist (M0–M1). The harness is `tests/blackbox/world.zig`, the walker
`tests/blackbox/corpus_test.zig`, and the corpus has four kinds (`parse/good`, `parse/bad`,
`fmt`, `bir`) plus `regress/`; `docs/design/frontend.md` §7 is the contract. Bless with
`BENI_WRITE_EXPECTED=1`, narrow it with `BENI_BLESS_ONLY=<substring>`.

The toolchain prerequisites are in place: `flake.nix` + `.envrc` pin **Zig 0.16.0**
and **Node 24**, so Boundary 2 (running the emitted JavaScript) is available from
the first test — build it in rather than deferring it. Invoke Node through the dev
shell, never a host binary, so CI and laptops agree on the version.

## Running the tests: cheapest tier first

CLAUDE.md's *Testing tiers* is the rule; in short:

The black-box steps spawn a ReleaseSafe beni built by Zig's self-hosted
backend: a 3 s compile, every safety check intact, debug info kept.

- **Tier 0, while writing the test** — run only what it touches:
  - one fixture or kind: `zig build test-blackbox-corpus -Dcorpus=run/MyFixture`
    (the path substring; also blesses with `BENI_WRITE_EXPECTED=1`);
  - one black-box file: `zig build test-blackbox-<file>`, narrowed
    to one test with `-Dtest-filter=<part of its name>`;
  - unit tests: `zig build test -Dtest-filter=<name>`;
  - a pending fixture: `zig build test-pending -Dcorpus=<path>`.
- **Tier 1, once, when it is done and before committing** — `zig build gates`.
- **Extra, only when it applies** — `zig build gates -Dllvm`: the LLVM
  build users get, about 70 s more compile. Run it once for a change that
  is sensitive to the code generator or to safety checks, before a
  release, or when the owner asks.

To prove a fixture fails before the fix (rule 3), run it at Tier 0 with the
fix set aside, not the whole suite. Never run two full suites at once, never
re-run a green one, and read a failure from the log instead of re-running.

**What a test costs.** `zig build test-time-report` runs the gates (or
`-Dtime-step=<step>`) with `BENI_TEST_TIMING` set and writes per-test,
per-fixture and per-tool CPU tables into `plans/test-time-report.md`. Look
there before adding an expensive scenario, and at the table's CPU column,
not its wall column. A spawn that bypasses `World` (a bare
`std.process.run`) is invisible to it except as "unrecorded" child CPU, so
spawn through `world.spawnAndCapture`/`spawnAndCaptureIn`.

## Checklist before reporting done

- [ ] Right boundary: the binary, unless it is a semantics question (run the JS) or
      a pure function (hermetic).
- [ ] Blackbox file imports only `std`, the harness and the diagnostic schema.
- [ ] Every knob reached through files/flags/env/socket; missing ones reported as
      compiler design bugs.
- [ ] **All assertions broad** — `expectEqualDeep` on the whole diagnostic or
      record; dynamic fields copied then shape-checked.
- [ ] `bad/` fixtures have a `.diag`; no test asserts merely "it failed".
- [ ] Goldens are extracted and normalized, not whole-file; bless path documented.
- [ ] Happy path first and complete; errors last and verifying no side effects.
- [ ] Banners present; one `test` per scenario; no fixed sleeps, only bounded waits.
- [ ] Every new parser has a fuzz test in the hermetic suite.
- [ ] Tier 0 green while writing, then `zig build gates` green once, before
      the commit (plus `-Dllvm` when it applies); no leaked process or temp dir.
