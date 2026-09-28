# beni

A compiler for an Elm-like language that emits JavaScript, written in Zig. It
keeps Elm's guarantees and error quality while being built for speed: flat
data-oriented IRs, per-file parallelism, and a resident daemon for incremental
rebuilds.

## Details about the project

- **Language**: Elm 0.19 with a short list of deliberate departures, all in
  [`language.md`](docs/design/language.md) §0. Two are large. There is **no
  automatic currying**: every call is saturated, function types are n-ary and
  written `Int, Int -> Int`, and partial application is written `f a _`. And
  there **is static dispatch**, adopted 2026-09-18: a type's methods are the
  `pub` values of the module declaring it, `x.m a` calls one, a top-level
  annotation may carry `where a.compare : a, a -> Order`, and `==` and `<` call
  the receiver type's `eq`/`compare`, derived when it declares none. Contract:
  [`static-dispatch-spike.md`](docs/design/static-dispatch-spike.md) — the file
  name is historical, the document is normative. A further departure is in progress:
  `schema` declarations have frontend support; their `Type` and `Encoded`
  members await checker support. [`schema.md`](docs/design/schema.md) owns the
  contract and open choices. Record alias and schema declaration bodies accept
  layout sugar for braces; their formatter always emits vertical layout
  (`language.md` §3–§4/§9, `schema.md` §2/A.5).
- **Target**: modern JavaScript, ES modules. `Int` is a double. **Beni is primarily a
  browser language, and the browser platform comes before Node** (the owner, 2026-09-19).
  Node is today's only platform because it is what the test harness needs, not because it is
  the goal: weigh every design choice — the fiber runtime's scheduler, output size, chunking,
  source maps, what `main` is — by what it does in a browser first.
- **Compiler**: Zig 0.16, pinned with Node 24 by `flake.nix`; `direnv allow`
  puts both on `PATH`.
- **Budgets**: >250k LOC/s cold per core for checking, an 800 ms cold build for
  100k lines ([`fast-compiler.md`](docs/design/fast-compiler.md) §2).

## M0–M2 — complete

Token SoA, arenas, intern pool, benchmark harness and the determinism test; the
lexer, LL(k) parser with error recovery, BIR lowering and the formatter, all
parallel per file; then packages, the module graph, interfaces, the type store,
constrain/solve, exhaustiveness and DAG-parallel module checking.

## The checker rewrite (2026-09-24 — 2026-09-27)

Five reviews of the old checker found ~30 defects, half of them programs that
checked and then misbehaved, so the owner ordered a ground-up rewrite. The new
checker is `src/check/`; its
normative architecture is [`checker-v2.md`](docs/design/checker-v2.md), which
supersedes the parts of `checker.md` and `static-dispatch-spike.md` its notes
name. [`plans/checker-findings.md`](plans/checker-findings.md) catalogues every
defect, [`plans/checker-rewrite.md`](plans/checker-rewrite.md) holds the
rewrite's slices with an *As built* note each and §1.1's table of the old
checker's six root causes. Red fixtures for open findings live in `tests/pending/`, run by
`zig build test-pending` (never by the gates); timing scenarios by
`test-pending-perf` and, once fixed, `test-perf`. Owner decisions D1–D16 and
their amendments are `checker-v2.md` §21–§21.1. Declaration order never
changes whether a program checks or what it prints (`ordering_test.zig`).

## M3 — in progress

**Schemas have frontend and checker support** (2026-09-22):
[`schema.md`](docs/design/schema.md) records the fork — an inspectable description
plus specialised top-level parse/print functions, both success and failure paths
compiled, each direction independently eliminated. Runtime composition uses
`core/Schema` under the same engine-owned context contract and differential tests.
Validation lowers to JsIr over raw host values, with no Value-ADT marshalling.
The parser accepts both brace and aligned declaration bodies, the formatter
emits nonempty record bodies and tagged variants as layout, and unresolved
schema plans survive in AST/BIR dumps and the frontend cache. The checker
resolves schema namespaces and both endpoint types, publishes
member/constructor schemes, and caches an immutable resolved plan.
`core/Schema` supplies the public type surface; executable library functions
are still to come. `check` and interface dumps accept schemas; `build` refuses
them from emit before any output, with `not_implemented`: their parse and
print are not generated yet. A.6 owns interface v2, frontend artifact v3 (now
v4: a new token and a wider exposed row), cache entry v2 (now v3) and the
unhashed plan v1. Remaining decisions lead the document; H4 remains open. The
incrementality-first schema work schema.md A.2–A.4 records has landed.

M3a emits JavaScript that runs, against the Node platform; M3b's tail-call loop,
its decision trees for pattern matching and its `?` have landed
([`backend.md`](docs/design/backend.md) §8, §7, §4); and M3c's first piece,
**reachability-driven dead code elimination**, has landed with it (§9,
`src/js/Reach.zig`) — an empty program went from 70 684 bytes in 19 files to
2 149 in 5, with `derived_bytes` exactly 0. **M3b's list in §1 is now spent**:
interpolation, tuples and record update worked in M3a, and `Int32` — the last
item, a language gap and not a codegen one — was built on 2026-09-19.
[`backend.md`](docs/design/backend.md) is the contract,
[`fast-compiler.md`](docs/design/fast-compiler.md) §13 the build order.

**M3c's first `--release` slice has landed** — §9's *The release optimiser*,
items 1, 2, 3 and 5: local dead bindings and single-use inlining
(`src/js/Opt.zig`), two namespaces of short names (`src/js/Rename.zig`),
compact printing and joined `const` runs (`src/js/Print.zig`). The flag is no
longer refused; `--source-maps` still is. `bench/corpus` fell 126 436 → 55 593
raw and 21 840 → **15 017** brotli (−31%), `run/Dictionaries` 7 008 → 5 860
(−16%), the floor 835 → 789. **Development output did not move by one byte**,
which is what makes an `emit/` golden that changes a finding. The whole `run/`
corpus is built and run a SECOND time under the flag, 121 programs, +13 s of
`test-blackbox`; `emit/release/` is the golden directory for shape claims and
`ReleaseDeadDebug.release-expected` is the one place the two builds
legitimately differ. **`--release` refuses a build that reaches `Debug`** (the
owner's decision, 2026-09-19 — Elm's `--optimize` rule): `debug_in_release`,
exit 1, nothing written, the use sites named, so "a release build behaves
exactly as the development build does" holds with no exception and §9 *Item
4*'s "pin every field if `Debug` survives" is withdrawn. The corpus's release
second pass carries a hidden, test-only `--allow-debug`, because `Debug.log`
is its only instrument for evaluation order (24 of the 121 fixtures);
`tests/corpus/build/bad-release/` is the kind that does not pass it, and
`ReleaseDeadDebug.release-expected` is now a harness-only fact. Still to come
in M3c: **item 4**, type-directed field ambiguation, which needs a per-build
field-interference artifact the backend
does not receive (§9's *What the second slice owes*), integer constructor tags
riding with it, and chunking (§10).

**The output tree's reserved names begin with `_`** (2026-09-21):
`_main.mjs`, `_core/` and `_platform/`. They were `main.mjs`, `core/` and
`platform/`, every one of them a name a module path can take — and the first was
a live defect, not a hazard: `Main.beni` emits `Main.mjs`, which on APFS and
NTFS IS `main.mjs`, so the entry shim overwrote the module and then imported
itself. 31 of 277 `test-blackbox` cases failed on darwin, all of them that. A
module name segment is an upper identifier, so `_` is the one region no module
can reach; `output_path_collision` is the backstop for the rest, folding every
path a build would write with ASCII lower-casing before the first byte is
written. A platform may now declare the entry file's name (`"entry"`, subject to
the same rule, `invalid_entry_file` otherwise), which finishes
[`boundary.md`](docs/design/boundary.md) §5.2's "declares … rather than
hardcoding". [`backend.md`](docs/design/backend.md) §2, *The output tree does
not depend on the file system's case sensitivity*.

**`core/Int32` has landed** (2026-09-19), the owner's decision taken: exact
32-bit work has its own type, total and wrapping, with `mul` on `Math.imul`
because a 32-bit product can exceed 2⁵³ and `Bitwise` alone therefore cannot
fake it. Only core may write `foreign` (rule 6), so if core did not ship
wrapping multiply nobody could add it. `*` is deliberately unavailable and
`==`/`<` are, through the module's own `pub eq`/`pub compare`; it is **not** in
the prelude, so `import Int32`. `language.md` §2.5 and Appendix A,
[`checker.md`](docs/design/checker.md) Appendix B's signature list,
[`backend.md`](docs/design/backend.md) §1 and §4. The emitter needed no change;
`tests/corpus/run/Int32Hash` writes FNV-1a, xorshift32 and murmur3's `fmix32`
in beni and checks them against published vectors.

**Landed inside M3**: static dispatch, whole — `where` clauses, dot-call,
well-known `eq`/`compare` with derivation, return-type dispatch, and `core/`
rewritten around them. It was built as a spike, measured
([`research/19`](docs/design/research/19-static-dispatch-spike-results.md)) and
adopted on 2026-09-18, reversing two `fast-compiler.md` §3.1 decisions.

**The no-currying change has landed**, in slices: the removal of `>>`/`<<`,
the `_` placeholder, the `let x <- e` bind, n-ary function types through the
parser, BIR, checker and backend — every emitted call is saturated and there is
no calling convention (`backend.md` §6) — and `core/` rewritten subject-first
with `|>` flipped to pipe-first.

### Owed after the static-dispatch adoption

*Historical (the old checker these items describe was deleted on 2026-09-27; `checker-v2.md` covers the same ground).* Report 19 §14, items 1–5. **All five are done** (2026-09-18): the `foreign` arity rule is enforced as `boundary.md` §4's check 4
(A.84), the inferred-`where` suffix is capped at 64 constraints and an
unannotated declaration over the cap is `too_many_inferred_constraints`, which
bounds the n² with it —
[`static-dispatch-spike.md`](docs/design/static-dispatch-spike.md) §6.4, §10.11,
A.83 — and dead-code elimination has landed.

1. ~~**Dead-code elimination** (already M3c).~~ **Done**: it is
   [`backend.md`](docs/design/backend.md) §9's reachability elimination,
   `src/js/Reach.zig`, always on for every build. Derivation is still eager, so
   every type ships an `eq` and a `compare` whether or not anything calls them;
   what changed is that a build no longer WRITES the ones it cannot reach. The
   floor went from 70 684 bytes in 19 files to 2 149 in 5 and its
   `derived_bytes` from 3 159 to 0, so an output-size figure is no longer an
   upper bound. `--library` roots a build at its exported surface instead
   (§2), which is what `bench/corpus` and the `emit/` corpus are measured with.
2. ~~**An arity check for a `foreign` carrying a `where` clause**, or
   withdrawal of that combination.~~ **Done** (2026-09-18): it is
   [`boundary.md`](docs/design/boundary.md) §4's **check 4** — every
   `foreign`'s sibling export must take evidence count + declared arity
   parameters, a non-function `foreign` must export a value, and the two
   export forms whose parameter list cannot be counted (a bare name, a rest
   parameter) are refused. `foreign_arity_mismatch`; no JavaScript parser;
   every existing sibling passed unchanged
   ([`static-dispatch-spike.md`](docs/design/static-dispatch-spike.md) §5.2,
   §11, A.7, A.84).
3. ~~**The two `master` printer defects** report 19 §3.1 reproduces.~~ **Done**:
   a record truncated past 64 extension links prints `… | ` and
   stays open, and `<error>` never reaches an interface unreported — the cause
   was a 256-slot stack in the poisoned-type scan, not `Schemes.Writer.max_depth`
   as report 19 guessed (`checker.md` §7, §8.2).
4. ~~**A cap or a diagnostic for the inferred `where` suffix.**~~ **Done**: the
   cap is 64 and over it the declaration promotes nothing, so a promoted suffix
   is at most 64 clauses. The `ambiguous_method_receiver` warning is also on by
   default now, for the root package only (spec §6.4, §10.9, §10.11, A.83).
5. ~~**A position on the n² obligation count** of an unannotated chain.~~
   **Done**, and it is the same rule: dropping the set at the cap stops it
   feeding the next link, so a chain costs ⌈n/65⌉ diagnostics in linear time
   and memory instead of n(n+1)/2 constraints (spec §10.11).

M4 is the daemon and incrementality: its first part has landed, including
the on-disk cache and interface firewall; remaining incrementality work and the
daemon are still ahead ([`queue.md`](plans/queue.md), M4 rows). M5 is source
maps, code splitting and LSP, and has not started.

## Effects, and what blocked them

[`transparent-effects-proposal.md`](docs/design/transparent-effects-proposal.md)
is the live design argument: two inferred bits per function, a fiber runtime, no
surface syntax. It could not start until the no-currying change landed, because
effect flags have nowhere to live on a curried `{param, result}` chain.
[`research/17-platform-primitives.md`](docs/design/research/17-platform-primitives.md)
discharges its §10 item 0. A second constraint found there: the tail-call loop
had to land **before** effects, because it is what lets `List.foldl`/`foldr`
leave `foreign`, and until they did the proposal's own headline example
miscompiled. **Both have now landed**, and the proposal has had its spec pass:
[`plans/effects-plan.md`](plans/effects-plan.md) holds the slice plan and **eight
decisions that are the owner's to take before any effects code is written**. One
hazard survives in a new place: `List.eq`/`List.compare` are `foreign` with a
`where` clause, so their siblings are JavaScript loops calling beni evidence —
the shape `foldl` was.

## Building

```sh
zig build                 # install ./zig-out/bin/beni (-Doptimize, Debug by default)
zig build test            # hermetic unit tests
zig build test-blackbox   # spawns a ReleaseSafe beni (zig-out/safe/bin) against temp projects
zig build test-perf       # timing scenarios on a ReleaseFast beni (zig-out/perf/bin); not a gate
zig build bench -- --generate=100000   # per-phase throughput, ReleaseFast
zig build fmt-check       # zig fmt --check over src, build.zig, tests, bench
zig build gates           # the three gates (rule 4), concurrently
zig build --list-steps
```

Options for a cheaper run (they work on every step that builds or runs
tests; `gates` refuses the two filters, because a gate runs everything):

```sh
-Dquick                        # black-box compiler built by Zig's self-hosted backend
-Dtest-filter=<text>           # only tests whose name contains <text> (repeatable)
-Dcorpus=<text>                # only corpus fixtures whose path contains <text>
zig build test-blackbox-<file> # one black-box file: ordering, cache, corpus, abuse-wide, …
```

`-Dquick` builds the same ReleaseSafe compiler with Zig's self-hosted
backend into `zig-out/quick/bin/` (the LLVM one stays in `zig-out/safe/bin/`,
so switching rebuilds nothing). Every safety check still fires — bounds,
overflow, `unreachable`, `std.debug.assert`, everything gated on
`std.debug.runtime_safety` — and it keeps debug info, so a panic prints a
symbolised trace. It compiles in about 3 s instead of LLVM's 73 s; its code
runs two to four times slower, so a full suite costs about three times the
CPU. That is why Tier 2 below stays LLVM, and why Tier 0 exists.

`-Dcorpus` matches the fixture's repo-relative path (`run/`, `check/bad/`,
`Int32Hash`), in `test-blackbox`, `test-blackbox-corpus` and `test-pending`
alike; one that matches no fixture is a failure, not an empty green.

### Testing tiers — run the cheapest one that answers the question

Every full-suite run costs minutes of a 32-thread machine that other agents
share. Climb the tiers in order, and move up only when the one below is green.

| Tier | When | Command | After a `src/` edit |
|---|---|---|---|
| 0 | while editing | the targeted run for what you changed, with `-Dquick` | 3–12 s |
| 1 | the change looks done | `zig build gates -Dquick` | 1 min 53 s – 2 min 28 s |
| 2 | once, right before committing | `zig build gates` | 3 min 40 s – 4 min 51 s |

Tier 0 is one of: `zig build test-blackbox-corpus -Dquick -Dcorpus=run/Foo`
(one fixture, 3 s; a whole kind such as `-Dcorpus=run/`, 9 s), `zig build
test-blackbox-ordering -Dquick` (one black-box file, 9 s), `zig build test
-Dtest-filter=<name>` (unit tests, 3 s; all of them, 11 s), `zig build
fmt-check` (under 1 s). Tier 2 is the only one that tests the binary the gates
mean: rule 4.

Measured on the 32-thread development machine under the load other agents
put on it (load average 20–80), each number edit-to-green with one file under
`src/` changed. Under that load the single-threaded LLVM compile alone took
3 min; idle it takes 73 s, and Tier 1 is about 1 min against Tier 2's
1 min 40 s. Tier 1 finishes sooner by spending about three times Tier 2's CPU
(39 against 12 CPU-minutes), which is one more reason to reach it only once
Tier 0 is green.

Why the LLVM compile cannot be made cheaper: about 95% of it is LLVM's O3
passes and machine-code generation, and Zig 0.16 runs them on one thread for
the whole program, with no flag to split or parallelise them; incremental
compilation does not shorten them either. Two things do help, and are set up:
every git worktree shares the main checkout's Zig cache (the dev shell sets
`ZIG_LOCAL_CACHE_DIR`), so a worktree whose sources match an earlier build
reuses it in seconds; and `-Dquick` skips LLVM entirely while iterating.

Only when relevant:

- `zig build test-perf` (21 s, ReleaseFast) when the change can move
  performance or touches a timing scenario;
- `zig build test-pending` (under 2 s, takes `-Dquick`) when adding,
  changing or promoting a fixture under `tests/pending/`;
- the determinism test is inside `gates`; there is nothing extra to run.

And three habits that waste more wall clock than any tier:

- **Never run two full-suite builds at once** — two `gates`, or `gates`
  beside `test-blackbox`. They compete for the same cores and both take
  twice as long.
- **Never re-run a green result to double-check it.** Green is green.
- **Read a failure from its log instead of re-running it.** Redirect the
  run to a file (`… > zig-out/gates.log 2>&1`) and read the `FAIL` lines;
  then re-run only the failing file or fixture, at Tier 0.

Every test binary runs under `tests/test_runner.zig`, std's runner plus
`BENI_TEST_SHARD=k/n`: `build.zig` runs the unit tests and the heavier
black-box binaries as several processes, each taking every n-th test, so a
suite takes about as long as its slowest test. A test that loops over
independent cases for many seconds is better written as several tests.
Run a test binary by hand (no `--listen`) to get each test's wall time.

`zig build test-time-report` answers "where does the test time go": it runs
`gates` (or `-Dtime-step=<step>`, with `-Dquick`, `-Dcorpus` and
`-Dtest-filter` passed on) in a child build with `BENI_TEST_TIMING=<dir>`,
so every test process records each test, corpus case and spawned `beni` or
`node` (wall, user, sys, max RSS), and renders the tables — per step, test,
fixture, tool, harness overhead and repeated commands — into
[`plans/test-time-report.md`](plans/test-time-report.md) between its markers
(`tests/time_report.zig`; `-- --out=- --top=N` to print instead). It costs
one full gates run, so it is not a tier; unset, the recording costs nothing.
Read CPU time, not wall: under load only CPU time is stable.

**`run/` runs Node only on JavaScript it has not verified.** Each
`tests/corpus/run/` fixture carries a `.run-hash` (`_expected.run-hash` in a
project): per build, dev and release, a SHA-256 of the whole emitted output
tree, the golden and the Node version, written only after that JavaScript ran
and matched (`tests/blackbox/run_hash.zig`). The walker always builds; when
the digest is listed it skips Node, and otherwise runs it exactly as before,
so a change to emitted code is never unverified. The gates print one line
when builds ran for want of a hash — never a failure. After a change to the
emitter, the runtime, `core/` or a `run/` golden, or a Node upgrade, run
`zig build test-run-hashes` (takes `-Dcorpus` and `-Dquick`) and commit the
rewritten `.run-hash` files with the change: it runs every selected program
and records a hash only for a build whose output matched, so a mismatch is
reported and gets none. On a merge conflict in `.run-hash` files, take
either side and regenerate.

The black-box suites run the compiler built ReleaseSafe: every invariant
check in `src/` is gated on `std.debug.runtime_safety`, never on
`builtin.mode == .Debug`, so it runs there as it does in Debug. It carries no
debug info (its LLVM compile is what a change under `src/` waits for), so a
crash it hits is traced by re-running the command with `zig-out/bin/beni`, or the
whole step under `-Dquick`, whose build keeps its debug info. An input a
black-box test generates is the smallest that reaches the limit or the
defect it is about — one past a cap, or the size that failed before a fix,
not ten times past it — and a declaration-order test tries a fixed set of
orders (written, reversed, a few seeded shuffles), never every permutation.

`beni dump --stage=tokens|ast|bir|types|interface` is the window into every
phase, and the dumps are corpus-tested, so they are outputs rather than
internals.

## The critical rules

### 1. The design documents are normative — specify before writing

`docs/design/` is not commentary. Where the code and a document disagree, that
is a bug in one of them, and the document usually wins. Every milestone here was
specified before it was written, and the one time that discipline slipped — the
2026-09-14 no-currying decision left in `fast-compiler.md` as a "pending spec
change" — nothing downstream of it could be implemented at all.

Read the contract for a phase before its code:
[`frontend.md`](docs/design/frontend.md),
[`checker.md`](docs/design/checker.md) with [`checker-v2.md`](docs/design/checker-v2.md) (normative for `src/check/` since the rewrite),
[`backend.md`](docs/design/backend.md),
[`boundary.md`](docs/design/boundary.md). Static dispatch cuts across all four
and has its own:
[`static-dispatch-spike.md`](docs/design/static-dispatch-spike.md). The four
point into it at each section it extends; the detail lives there, once.
Schemas have the same cross-cutting contract in
[`schema.md`](docs/design/schema.md), with pointers from the language, checker,
backend and boundary contracts; its open decisions must be settled before the
dependent implementation slices.

### 2. Never renumber a section in `docs/design/`

Hundreds of `§N` cross-references point into those documents from Zig source
comments, from corpus fixture intent comments, and from each other. Move text
between sections if you must; leave the numbering alone.

### 3. Tests are black-box, and they are the asset

The binary is a closed box driven by source files on disk and flags; its outputs
are emitted JavaScript, diagnostics and exit codes. **Every defect gets a fixture
under `tests/corpus/` that fails before the fix and passes after** — prove it by
stashing the fix. Prefer `tests/corpus/run/`, which executes the emitted
JavaScript, whenever behaviour is visible at runtime. In-source Zig tests are a
supplement and never the coverage.

A fully green `zig build test` has repeatedly coexisted with real defects that
only a corpus fixture or a read-only review caught. Treat a green suite as the
floor, not the evidence.

### 4. Three gates, and they pass on `master`

```sh
zig build gates    # test, test-blackbox and fmt-check in one build graph
```

`gates` runs the three steps concurrently, which is faster than chaining
them with `&&`; each step still works on its own. All three pass today, so a failure is yours. Never commit red or unformatted
code, and never commit a slice that is half-landed.

The gate before a commit is `zig build gates` exactly — LLVM, no `-Dquick`,
no filter — run once, right before committing (Tier 2 of *Testing tiers*
above). Iterate at Tiers 0 and 1; a green `-Dquick` run is not the gate.

### 5. Determinism is a requirement, not an aspiration

Ids are input-derived and assigned **before** any parallel work starts — module
index comes from sorted path, never completion order. The determinism test runs
the corpus at `--jobs=1` and `--jobs=8`, twice each, and byte-compares every
stream and output file. Anything that makes output depend on thread timing is a
bug, not a trade-off ([`fast-compiler.md`](docs/design/fast-compiler.md) §10).

### 6. `foreign` is privileged, and `core/` is embedded

Only platform packages may write `foreign`, and `core/` is compiled into the
binary. A `foreign` value binds to a sibling `.js` file by name, one export per
declaration, and four build-time checks enforce the shape
([`boundary.md`](docs/design/boundary.md) §4): the two-shape type rule, exact
export coverage, import coverage, and the export's arity. Do not widen that
surface to make something convenient — and note that §4's list of accepted
export FORMS is part of the contract, so a sibling writes its parameter list at
the export.

### 7. Guarantees, not restrictions

The owner's stance, 2026-09-19: **"Beni's job is to make the error guarantees —
like Elm does — but not to enforce anything on the devs. If devs need to reach
for `Int32` then let them."** `Int32` was an *example* of it, not the point.

Test every rule against the guarantee it buys. A rule that protects one — no
runtime exception, no silent wrong answer, exhaustive matches, managed effects —
stays, and is an error: irrefutable patterns in parameters, cyclic values, the
`foreign` wall and its arity check are all of this kind. A rule that only
encodes taste, or "you should not need that", does not belong: make it a
warning, give it an escape hatch, or drop it. The cap of 64 inferred constraints
is the model of a limit done right — it bounds a real blow-up and an annotation
lifts it.

A capability gap is filled **inside the wall**, not answered with "work around
it". Rule 6 means an ordinary developer cannot write `foreign`, so whatever
`core/` and the platforms do not ship, the language is withholding — wrapping
32-bit multiply was Elm's example of exactly that
([`fast-compiler.md`](docs/design/fast-compiler.md) §3.1). When recommending a
refusal where no guarantee is at stake, say so and offer the warning.

### 8. The UI is as fast as Solid, and JSX is part of the language

The owner, 2026-09-20: **"I want built in JSX in the language. … I want a Beni UI
to be fast, as fast as solid, the runtime cannot be a limitation."**

**SolidJS 2 is the performance gold standard for UI**, as Effect v4 is for
effects. No UI design is recommended on an assumption about speed: it is
measured against Solid 2 with report 29's harness (js-framework-benchmark in
headless Chrome, plus the static-heavy page the table benchmark cannot see), and
a design whose runtime is structurally slower is not proposed. Quote orderings
and per-operation medians; a geometric mean of ratios over sub-millisecond
operations did not reproduce and is never a parity claim.

What the evidence says today
([`research/27`](docs/design/research/27-solid-2-as-built.md),
[`28`](docs/design/research/28-jsx-in-beni.md),
[`29`](docs/design/research/29-rendering-strategies-measured.md)): most of
Solid's speed is its **compiler**, not its signals, and that half is open to The
Elm Architecture — `view` compiled to cloned templates with a reference check
per dynamic hole beats Solid 2 on script on every benchmark operation, while a
**virtual DOM is the slowest sensible design measured** and is a fallback at
most, never the architecture. It works because values are immutable and a record
update is a spread, so an untouched value is the *same object*: **field identity
is load-bearing**, and no optimiser change may break it. Signals stay possible
as a library and are not forbidden (rule 7); they buy no speed.

**JSX is a language feature** — grammar, typing, formatter, codegen — specified
before it is built (rule 1), with the element and attribute vocabulary declared
by a platform package, never known to the compiler (rule 6). The plain-call
form stays and produces the same type. The open decisions are the owner's, in
[`plans/browser-decisions.md`](plans/browser-decisions.md); the plan is
[`plans/browser-platform.md`](plans/browser-platform.md).

## Operational

### Captain's log — `plans/diary.md` (APPEND AFTER EVERY SESSION)

`plans/diary.md` is an **append-only** captain's log of all work on this repo.
**At the end of any session where you did real work, append an entry** —
heading `## YYYY-MM-DD HH:MM TZ — <short title>` (get the real timestamp with
`date`), then **What I did** and **What I learned**. Newest entries at the
**bottom**; never edit or delete a prior entry (correct a past statement in a
*new* entry). **Do this proactively — do NOT wait to be asked.**

### Skills

`zig-developer` for any Zig syntax, stdlib or build-system question — Zig's API
churns between releases, so do not answer from memory. `write-tests` for the
testing discipline above. `commit` for the repo's commit format. `roc-zulip` for
primary-source evidence on how Roc's compiler works and why, and `hackernews`
for what practitioners reported about shipping a technology — the users talking
back, where `references/talks/` is one person's prepared argument.

### References

`references/` holds large vendored submodules: the Zig compiler and std (the
gold standard for both idiomatic Zig and the data-oriented architecture beni
copies), `elm-core`, and **`references/effect`** — Effect-TS v4 (`main` at
`4.0.0-rc.116`, pinned 2026-09-19, shallow), the owner's **gold standard for the
effects work**: beni aims at Effect's level of quality and API coverage, while
not inheriting what Effect must do only because it lives in TypeScript
(generators, type-level encodings). **`references/solid`** (SolidJS 2, branch
`next`, `2.0.0-rc.9`, with its signals core in-tree) and
**`references/dom-expressions`** (the JSX compiler and DOM runtime Solid is built
on), pinned 2026-09-20, are the gold standard for UI performance (rule 8);
`references/elm-browser` and `references/elm-virtual-dom` are Elm's browser
runtime, read for report 24. Commit the submodule *pointer*, never vendored contents.

**`references/talks/`** is the one part of `references/` that holds plain files: talks
and streams kept as primary-source evidence, one directory each with `raw.txt`
(the paste, never edited), `transcript.md` (time-linked, lightly corrected) and
`notes.md` (the argument, a topic index, and what it means for beni's open
decisions). Auto-caption transcripts are unverified — quote from the video. A
talk is somebody's argument and is never normative. Its
[`README.md`](references/talks/README.md) is the index and the convention.
