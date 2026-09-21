# M3d — chunking and `lazy`: the work-up

**Status:** plan, 2026-09-18. Nothing is started. Written for the project owner to read *before* any
M3d code exists, because this milestone adds a **keyword to the language** and because the feature it
is named after may not be buildable yet. Language-surface questions are raised here as decisions
(§6), not taken. Backend-internal decisions are taken in [`backend.md`](../docs/design/backend.md)
§10 with their reasons, and §10 marks everything that waits on §6 as PENDING with a pointer here.

**What this is.** [`backend.md`](../docs/design/backend.md) §10 is twenty lines of conclusions from
[`research/12-js-output-and-chunking.md`](../docs/design/research/12-js-output-and-chunking.md).
This is the work-up against the repository at `f03dc17`: what those twenty lines actually decided,
what they left open, the one problem nobody has faced squarely (a `lazy` load is asynchronous and
the language has no way to say so), what the colouring costs on the graph `src/js/Reach.zig` already
builds, and what the output looks like afterwards. Every claim about today's code is a `file:line`.

---

## 1. What §10 and report 12 decided, and what they left open

### 1.1 The four sentences of §10 that are decided

> "Entry points are `main` and every `lazy` declaration. Each declaration's colour is the set of entry
> points that reach it; declarations sharing a colour share a chunk. **"Reaches" is §9's walk with
> more than one seed, over §9's graph** — the colouring adds a lattice, not a second graph."
> (`backend.md` §10)

> "The colour is **hash-consed from the first line written**… dart2js's `ImportSetLattice` is the
> structure to copy." — "A **merge pass** follows, budgeted by compression rather than request count:
> four chunks cost about 6.6% of compressed bytes and sixteen about 18%, before any chunk has saved
> anything. A chunk whose private content does not repay that is folded back." — "The assigner
> **synthesises the cross-chunk `import`/`export` bindings itself**, and is budgeted with the
> assigner rather than after it… esbuild's `computeCrossChunkDependencies` is the model." (§10)

Report 12 §3.1 is the evidence for the first (esbuild, Rollup, dart2js and Scala.js all converged on
entry-set colouring), §2.6 for the third (the measured table: 2 chunks +3.0% brotli, 4 chunks +6.6%,
16 chunks +18.2%, corroborated by Khan Academy's +2.5% at file granularity), and §3.3 for the fourth
(closure-compiler#4264, open: *"Code is relocated without synthesising the matching export/import."*).

`fast-compiler.md` §9.5 adds two decisions that sit there rather than in `backend.md`:
*"**Opt-in per program, release only:** entry points are `main` plus every `lazy` declaration, so a
program with no `lazy` emits exactly one file"* and *"**Per declaration rather than a coarser
unit**"*.

### 1.2 What they left open, in the documents' own words

- **The type of a `lazy` reference.** `fast-compiler.md` §9.5 specifies the rewrite —
  *"`pub lazy adminDashboard : Model -> Html Msg` seen by importers as `Task LoadError (Model -> Html
  Msg)`"* — and then, in a block quote of its own: *"**Open.** That rewritten type names `Task`,
  which `transparent-effects-proposal.md` removes. Whatever replaces `Task` replaces it here."*
  P2 §2 is what removed it: *"**Deferral is a thunk.** `\() -> fetchSummary id` … This is what
  replaces `Task e a`."* **So the one piece of surface syntax M3d is named after is specified in terms
  of a type the language has decided not to have.** §2 of this plan is that problem.
- **What a `lazy` declaration means to the constant folder** — report 12's open question 1, verbatim:
  *"Dart's one restriction this report could not dismiss is that a deferred library's constants are
  not constants. beni must decide, and no precedent erases the problem."*
- **The chunk-count distribution** — report 12's open question 2, *"the biggest unquantified risk in
  the chunking plan"*: no source measures what declaration-granular colouring produces, and the
  report had no large beni program to measure. **The merge threshold** follows from it and §10 gives
  no number. **How chunks are NAMED** nothing anywhere says, and CLAUDE.md rule 5 requires it be
  input-derived.
- **What a "route" is.** §1's acceptance — *"a two-route program splits and both routes run"* — uses a
  word that appears nowhere in `boundary.md`. §6 decision 4.

---

## 2. The async problem, faced squarely

**The tension in one paragraph.** `import()` returns a promise. Loading code later is therefore an
asynchronous operation in every JavaScript target there is. beni today is a pure, synchronous
language with no effect system: `main` is emitted as a module-level constant, evaluated at import
time — measured, `const Main$main = Node$print(Main$greet("world"))` in `out/Main.mjs` — and the
platform runtime is four lines that write `program.out` and set `process.exitCode`
(`platforms/node/runtime.js`, copied to `out/_platform/runtime.foreign.mjs`). **There is no point in a
beni program today at which anything can wait for anything.** Report 12 §4.3 is the paragraph that
was supposed to dissolve this, and note its tense:

> "**This is the finding that should shape beni's answer. Asyncification is the universal cost of
> code splitting, and beni has already paid it.** In a language whose effects are values interpreted
> by a platform (§3.1), everything effectful is already a `Task`/`Cmd`."

That sentence was true of the design as it stood in the `Task`-and-`Cmd` era. It is **not true of the
repository**: there is no `Task`, no `Cmd`, no `Sub`, no scheduler, and P2 removed the type the
argument leans on. The cost report 12 says is already paid has not been paid; it has been *deferred*
to the effects milestone. Four ways out.

### (a) `lazy` yields a platform-level value the platform runs

`lazy dashboard : Int -> String` is seen by importers at an opaque `Lazy (Int -> String)`, and the
platform's `Program` interpreter resolves it:

```js
// out/_main.mjs — the platform owns the load
const mod = await import("./chunk/Admin.dashboard.mjs");
run(Main$main, { "Admin$dashboard": mod.Admin$dashboard });
```

**What it needs:** a `Lazy a` type in the language or in core; a rule for what a caller may do with
one (`Lazy.map`? `Lazy.andThen`? — that is a monad, i.e. `Task` under another name); a platform
`Program` that is a *continuation* rather than a value, so the runtime can load and resume. **What it
forecloses:** it invents an effect type for one feature, shortly before P2 deletes it again, and
`boundary.md` §4's shape rule would have to admit it. **Verdict: reject.** It is report 12 §4.5
candidate 2 with the module-as-value part removed and the cost intact.

### (b) Chunking with no language feature: static multi-entry

Two entry points, one build, all imports static, nothing asynchronous.

```
beni build --release --platform=node A.beni B.beni
→ out/chunk/shared.0.mjs     what both reach
  out/main.A.mjs             A's private code + `run(A$main)`
  out/main.B.mjs             B's private code + `run(B$main)`
```

```js
// out/main.A.mjs
import { List$foldl, Dict$insert } from "./chunk/shared.0.mjs";
const A$report = (xs) => …;
run(A$main);
```

**What it needs from the language:** nothing. **From the checker:** nothing. **From the backend:**
the whole of §10 except the deferral — colouring, the merge pass, cross-chunk bindings, chunk naming,
determinism. **From the platform:** nothing; each entry file is exactly what `Emit.emitEntry` writes
today (`src/js/Emit.zig:840-858`), one per entry. **From the CLI:** the `missing_main` refusal at
`src/js/Emit.zig:575-591` — *"This project has more than one `main`… Build them separately."* — has
to become a multi-entry build, a change to `boundary.md` §5.3's "a build is a pair of ONE entry point
and ONE platform" that §5.3 itself anticipates: *"M3 may ship one pair per invocation, but the
manifest concept M4 introduces should carry the set."*

**Does it meet §1's acceptance?** Under the reading "route = entry program", yes, and it is testable
today: two entry files, both run under Node, both print. Under the reading "route = a screen of a
single-page application", no — that needs a browser platform (B4) *and* deferral.

**What it forecloses:** nothing. Every part of it is a prefix of the `lazy` design; `lazy` adds
entries to the same seed set. **Verdict: this is the buildable half of M3d.**

### (c) Top-level `await import()` in the compiler-written entry file

```js
// out/_main.mjs — legal ESM, top-level await
const { Admin$dashboard } = await import("./chunk/Admin.dashboard.mjs");
run(Main$main);
```

This compiles and runs, and it loads the chunk **unconditionally, before `main`** — not laziness, a
slower static import. Making the load conditional needs a condition from the program, and a pure
synchronous program cannot express one. **Verdict: reject as a design, keep as a mechanism** — it is
the shape the entry file takes when effects land, and it needs no platform change, because
`_main.mjs` is compiler-written.

### (d) `lazy` waits for effects; ship (b) now

Under P2 there is **no type rewrite at all**. A `lazy` declaration is an ordinary declaration whose
`suspends` bit is set by the marker instead of by inference, and P2 §2's rule — *"Effectful calls
look like ordinary calls"* — means the call site is unchanged:

```elm
pub lazy dashboard : Model -> Html            -- declared type, unchanged
view : Model -> Html
view model =
    dashboard model                            -- `view` now suspends; `sync` refuses it
```

```js
// E3's L1 lowering; the load is a `foreign suspends` primitive
const Main$view = (model, $k) => $load(chunk_2, ($m) => $m.Admin$dashboard(model, $k));
```

**What it needs:** P2's slices **E1** (the bits exist and are inferred), **E3** (L1 lowering) and,
for the diagnostic report 12 §4.4 demands, **E2** (`sync`). It needs no new type, no `Lazy`, no
`Task`. **What it forecloses:** nothing, and it *removes* a cost: report 12 §4.5 priced candidate 1's
*"the declared type and the use type differ — a real readability hazard needing good diagnostics"*,
and under transparent effects that hazard does not exist, because nothing about the type changes.

### Recommendation

**(d), with (b) shipped first and now.** Concretely:

1. **`lazy` is blocked on effects and the block is hard.** Not "awkward", not "would be nicer after":
   there is no expressible type for a deferred value in the language as it stands, and inventing one
   means building the thing P2 deletes. **This reorders the roadmap: `lazy` moves from M3d to an
   E-slice, and M3d keeps the chunker.** The owner should know that §1's line "M3d — chunking and
   `lazy`" is a milestone containing two items with a six-month dependency between them.
2. **Everything else in M3d is unblocked and worth real bytes.** Measured below: bundling today's
   output into one file is worth **22% of compressed bytes** on `Dictionaries`, and that needs no
   language feature, no second entry and no `lazy`.
3. **Effects makes `lazy` cheaper, not just possible.** One contextual word, one bit set instead of
   inferred, one `foreign suspends` primitive in the platform, and the stray-reference diagnostic
   that GWT never built falls out of E2's `sync` check for free. That is the smallest version of this
   feature anyone has shipped, and it is only available on the other side of E3.

**The one thing to decide now rather than later** is that `lazy` will be a *marker that sets an
inferred bit*, not a *type rewrite*. It costs nothing to write that down and it keeps anyone from
building `Lazy a`.

---

## 3. Entry-set colouring on Reach's graph

### 3.1 The algorithm, and why it is three lines of new code

`src/js/Reach.zig` already produces, for one seed set, a `Result` of two `DynamicBitSetUnmanaged`s
per module — `decls` and `derived` (`src/js/Reach.zig:103-123`) — over node identities that are
input-derived end to end (`:63-67`). Colouring is that pass run once per entry:

1. **Entries** `E`, in canonical order: the entry declarations, ordered by `(Graph.Index, DeclIndex)`,
   both input-derived. For an application build today `|E| = 1`.
2. **One `Reach.run` per entry**, each seeded with that entry alone. `|E|` results.
3. **Transpose**: node *n*'s colour is the `|E|`-bit vector of which results marked it. Liveness —
   §9's existing answer — is the OR of the bits, so one machine does both and §9's `Live` is
   recovered by folding rather than by a separate walk.
4. **Intern** the distinct vectors. dart2js's `ImportSetLattice` exists because 401 deferred imports
   produced 2.9M sets and 5 GB of heap (report 12 §3.3); at `|E| ≤ 64` a `u64` key into a hash map is
   the same structure at a thousandth of the code, and the trie is what is needed past that.
5. **Every colour containing the main entry is the main chunk.** dart2js's rule, quoted in report 12
   §3.1: *"The main output unit contains any code accessed directly from `main`. Such code may be
   accessed by deferred imports too, but because it is accessed from the main entrypoint of the
   program, **possibly synchronously**, we do not split out the code or defer it."*

**Cost**: `|E| × O(nodes)` for a walk that is *"278 nodes for the null program, O(declarations) at any
size, microseconds against §13's 800 ms budget"* (§9). It becomes a fixpoint worth optimising when
`|E|` reaches the hundreds, which is a `lazy`-era problem.

**The chunk graph is a DAG, and that is a theorem rather than a hope.** If `d → e` then every entry
reaching `d` reaches `e`, so `colour(e) ⊇ colour(d)`: a chunk imports only from chunks whose colour is
a strict superset, and the main chunk — which absorbs every colour containing `main` — has no
outgoing cross-chunk edge at all. Rollup's `CIRCULAR_CHUNK`, Scala.js's `maxExcludedHopCount` and its
two-of-three "(unproven)" lemmas (report 12 §3.3) are all repairing a property beni gets from the
colour order.

### 3.2 The merge pass: promote entries, do not move declarations

The naive merge — "fold a small chunk into a bigger one" — **breaks the DAG property**, because the
relocated code still references colours the destination does not contain, and the fix cascades. The
formulation that cannot go wrong is dart2js's `ImportSetTransition` (report 12 §4.2: *"if import X is
loaded, treat Y as loaded too, run to a fixpoint"*) used as the merge mechanism:

> **To fold a chunk, promote its entry.** A lazy root whose private content does not repay a split is
> added to the main entry's seed set and the colouring is re-run. Repeat until no candidate is
> under the threshold.

It is acyclic by construction, deterministic if candidates are considered in canonical entry order,
and it is what GWT does under duress — *"every fixup demotes the atom to leftovers"* (report 12 §3.3).

**The threshold, provisional and marked as such.** Report 12 §2.6 prices one extra chunk at ~3% of
compressed bytes and four at 6.6%; dart2js measured an empty part at 1 080 bytes and *"53 of 370
completely empty"*. Proposed: a candidate chunk is kept iff its private content is **≥ 4 096 raw
bytes and ≥ 5% of the program's raw bytes**. Both numbers are guesses against report 12's open
question 2 and must be re-derived from `bench/size.mjs` on the first program large enough to have an
opinion.

### 3.3 Naming, determinism, and what goes where

| Thing | Chunk | Why |
|---|---|---|
| the main chunk | **`out/_main.mjs`**, the platform's artifact, with `run(main)` appended | it is already the file `Emit.emitEntry` writes (`src/js/Emit.zig:840-858`); making it the main chunk keeps the artifact path unchanged |
| a colour that is one lazy root | `out/chunk/<Module>.<name>.mjs` | readable, input-derived, and it names the thing the author marked |
| a colour of two or more lazy roots | `out/chunk/shared.<i>.mjs`, `i` the colour's index in the canonical colour order | input-derived; no content hash, so a golden is stable |
| a derived `eq`/`compare` | its own node, coloured like any other (`Reach.Kind.derived`) | §9 already makes it a node |
| a `$$order` table | its `compare`'s chunk | *"lives and dies with its `compare`"* (§9); not a node |
| the primitive comparators `eq$prim`, `compare$prim`, `compare$char` | every chunk that wants one emits its own | discovered by `Lowerer.needs` during lowering, not nodes (§9); they are three small functions and duplicating beats a cross-chunk edge |
| an eta-expanded evidence closure | the chunk of the declaration whose site built it | it is not a node; *"an eta-expansion is built from a site's targets, and the targets are the edges"* (§9) |
| a `*.foreign.mjs` sibling | **its own file, unchunked**, at today's path; every chunk that uses one of its exports imports it | a sibling is copied whole and never parsed (`boundary.md` §4); ESM evaluates a module once, so duplicated imports are free |
| `platform/runtime.foreign.mjs` | its own file, imported by the main chunk | *"the runtime sibling is copied whole, so it needs no root of its own"* (§9) |

**Determinism** needs nothing new. Entry order, node identity, colour order and chunk names are all
functions of sorted paths and source order; the colouring's output is a *set*, so `--jobs=1` against
`--jobs=8` covers it exactly as it covers §9 (CLAUDE.md rule 5).

### 3.4 Three compositions

**With `--library`.** A library's consumers are not in the build, so there is no entry set to colour
by. `--release --library` emits **one chunk**. Saying so is better than pretending: §9 already
measures that elimination *"shrinks a program; it barely shrinks a library"* (48 of 59 derived
functions survive), and chunking a library is the same shape of nothing.

**With §9's release namer.** Nothing to do, and this is the single largest thing beni gets for free.
The namer's *"one whole-program namespace for names that cross a file"* means a top-level name is
assigned before any chunk exists and does not depend on where the declaration lands — so **chunk
assignment can never rename anything**, and Rollup's `deconflictChunk.ts` (266 lines) has no analogue
here. Report 12 §3.3 names this as Elm's actual blocker: *"each code split segment would have a
unique 'fingerprint' of obfuscation"*. Confirmed against today's dev output too: names are
`Module$name`, globally unique by construction, which is why the hand-assembled bundle in §4 runs.

**With M4.** Today one source module is one output file, so *"one edit rewrites one small file"*
(`src/js/Emit.zig:6-10`), which is what the 15 ms warm budget is measured against; under chunking a
declaration's output file depends on the whole program. **The two never meet**: chunking is
release-only and release is not the warm path. The cacheable unit stays what §9 says — per-module
edge lists and per-module `JsIr` — and a chunk file is a concatenation of already-lowered statements,
memcpy-class work. What release cannot cache is the *name table*: §9 promises only that *"a name is a
function of the declaration's position in `emissionOrder`"*, and inserting a declaration shifts every
name after it. A stated non-guarantee, not a regression M3d introduces.

**With M5.** §11 already says *"per-file chunks rebased once at join time"*, which is exactly chunk
assembly: each declaration's mappings are recorded at print time and rebased by the chunk's running
line offset. One `.map` per chunk file. No new mechanism.

---

## 4. Does one-`.mjs`-per-source-module survive?

**Measured today, Debug binary at `f03dc17`, dev builds, brotli `-q 11` through Node's `zlib` — the
same encoder `bench/size.mjs` uses:**

| Program | files | raw | Σ per-file brotli | one file, headers intact | one file, module headers dropped |
|---|---:|---:|---:|---:|---:|
| hello world | 5 | 2 138 | 1 152 | 835 (**−27.5%**) | 772 (**−33.0%**) |
| `run/Dictionaries` | 20 | 44 313 | 11 908 | 9 290 (**−22.0%**) | 8 758 (**−26.5%**) |

*Method and its limits: files are concatenated in sorted-path order, which is not a runnable program
(the constants would hit the temporal dead zone), so these are size proxies, not builds. The third
column drops lines matching a relative `import … from "./…"` or `export {`, which is what a real
bundle removes.*

Two consequences the documents do not currently state.

**First: `bench/size.mjs` cannot see any of this.** `measureTree` concatenates every `.mjs` under
`out/` and compresses the concatenation (`bench/size.mjs:255-279`, `Buffer.concat(chunks)`), so
today's headline `brotli_bytes` is **already the idealised single-file number**. The instrument must
gain a `split_brotli_bytes` column — the sum of per-file brotli — or M3d's largest win is invisible
to the benchmark that is supposed to prove it.

**Second: the split between generated and hand-written code decides how much is reachable.** Of
`Dictionaries`' 11 908 compressed bytes, **6 425 (54%) are the seven `*.foreign.mjs` siblings**;
bundling only the generated half leaves 3 548 + 6 425 = 9 973, a −16.2% win rather than −26.5%.
Bundling the siblings too is worth the remaining **1 215 brotli bytes**, and this plan declines it: a
sibling is hand-written JavaScript copied verbatim, two siblings may collide on an internal helper
name, and separating their scopes needs a JavaScript parser, *"which is the dependency `boundary.md`
§4's wall exists to avoid"* (§9). Left on the table with the number, as §9 left per-export sibling
elimination. It gets worse under `--release`, where the generated half shrinks ~55% and the siblings
do not shrink at all — report 12 §3.3's *"90% is runtime plus library, and no chunker can split it"*
arriving in our own output.

**The decision.** Option **(iii), both, by mode and not by flag** — which is what `fast-compiler.md`
§9.5 already says (*"Two build modes, one graph"*) and what M3d makes true:

- **dev** stays one `.mjs` per source module, mirroring the source tree. It is the warm-rebuild path,
  it is what a dev server needs to compute which modules an edit affects (§9.5's ESM row), and every
  `emit/` golden is a dev-build golden.
- **release** is chunks, and with one entry and no `lazy` that is **one file** — the degenerate case
  of the colouring, worth 22% before the merge pass has anything to merge.
- **No manifest**, for now. Nothing reads one: the entry file is compiler-written and the chunk
  specifiers are compiler-written. A manifest becomes necessary when a browser platform needs to
  preload, which is B4's problem.

**User-visible, and flagged rather than decided:** a release build stops writing `out/<Module>.mjs`,
so anything that imported a beni module by path breaks. There is no such consumer in the repository,
and `--library` (which is how one would build something to be imported) emits one chunk and can keep
per-module files if the owner prefers — §6 decision 5.

---

## 5. Slice plan

Discipline is `plans/effects-plan.md` §4's and `static-dispatch-spike.md`'s: spec section first →
implement → fixtures that fail before and pass after, proved by stashing → three gates → review →
commit → diary.

| Slice | Spec first | Touches | Fail-first fixtures | Measurement |
|---|---|---|---|---|
| **D0 — the contract** | this plan and `backend.md` §10 (done with this pass) | docs only | — | review |
| **D1 — release emits one file** | §10's *Assembly* and *Order within a chunk* | `Emit` (a chunk writer between `emitModules` and `emitEntry`), `Print.print` gains "print these statements into this buffer", `JsIr` untouched | `run/` corpus re-run under `--release` asserts unchanged `.expected` (§9's release testing already buys this); `emit/release/ChunkSingleFile` golden: one file, no `import` of a generated module, sibling imports hoisted, `run(main)` last; `emit/release/ChunkOrder` — a three-module diamond whose declarations must come out in module-topological order or throw a TDZ `ReferenceError` | `bench/size.mjs` gains `split_brotli_bytes`; the −22% is the number |
| **D2 — colouring, merge, cross-chunk bindings** | §10's *The colouring*, *The merge*, *Cross-chunk bindings* | a new `src/js/Chunk.zig` over `Reach.Result`s; `Emit` | needs a second entry — see below | chunk count and per-chunk brotli per program; the merge threshold re-derived |
| **D3 — multi-entry builds** (owner decision 2) | `boundary.md` §5.3's pair becomes a set; `backend.md` §2's CLI table | `Cli.parseBuild`, `Emit.findEntry` (`:565-614`), `emitEntry` per entry | `run/` project fixtures: a two-entry program whose shared module is in neither entry file, both entries run, both print | shared-chunk bytes against building twice |
| **D4 — `lazy`** | `language.md` §3 grammar + a §6 subsection (PROPOSED until decision 1); `checker.md`; `backend.md` §10's PENDING block | parser, `Bir`, checker (the `suspends` bit), `Reach` roots, `Chunk` | `run/LazyTwoRoutes`: both routes load and print, in order; `check/bad/LazyFromSync`: a `lazy` reached from `main`'s synchronous path | initial-chunk bytes against the unsplit program |

**Independence.** D1 is independent of every language question and is the slice worth the most bytes.
D2 is independent of `lazy` but not of *some* second entry, so it lands with D3 or not at all. D3 is
a build-contract change and needs decision 2. **D4 is blocked on effects E1–E3** (§2) and on decision
1 and 3. So: **D1 → D3 → D2 now; D4 after E3.**

**What the corpus harness needs, and it is not free.** A `run/` fixture is a single `.beni` copied
into a world and built (`tests/blackbox/corpus_test.zig:453-479`), and what is executed is the fixed
path `out/_main.mjs` (`tests/blackbox/world.zig`). Smallest honest change: a `run/` fixture that is
a **directory** builds every `.beni` in it in one invocation — the shape `emit/` already has
(`:503-533`) — and runs each entry file in sorted order, concatenating stdout against one
`.expected`. One `Kind` field and one loop, and it is what makes "both routes run" assertable.

---

## 6. Decisions only the owner can take

**1. The surface of `lazy`, if it is a surface at all.**
*Options:* (a) a reserved **keyword**; (b) a **contextual word** in annotation position, the way
`where` is (`static-dispatch-spike.md` §2.2) and `equatable` is (`language.md` §3); (c) a **core
function the compiler recognises**, `Lazy.of`-shaped.
**Recommendation: (b), with the rule that a `lazy` declaration must be annotated.** A reserved
keyword costs every program that ever wants `lazy` as a name — and every Elm reader knows `lazy` as
`Html.Lazy.lazy`, a function name, not a keyword. A contextual word is decidable here with the same
three tokens and no backtracking: at a declaration, a `lower_ident` whose text is `lazy`, followed by
a `lower_ident`, followed by `':'`, is the marker; anything else is an ordinary declaration, so
`lazy x = x + 1` still declares a function called `lazy`. Note that this **requires the annotation**,
which is a rule worth having anyway — `main` already carries one for the same reason (`boundary.md`
§5), and a chunk boundary is exactly the place a reader should be told the type. (c) cannot work: a
function's argument is a value, and *"a `LazyRef` passed as data is precisely how you create a
reference the reachability analysis cannot see through"* (report 12 §4.5, candidate 4, rejected).

**2. Does M3d ship static multi-entry chunking first?**
*Options:* (a) yes — D1 and D3 land now and `lazy` follows effects; (b) no — M3d waits for effects
entirely; (c) D1 only (the single-file release bundle) and no colouring until `lazy` exists.
**Recommendation: (a).** (b) leaves 22% of compressed bytes on the floor for a milestone that has
nothing to do with the blocker. (c) ships the colouring with no way to exercise it — a pass whose
only test is the one-colour case is a pass that will be wrong the first time it has two. Multi-entry
is also the build contract `boundary.md` §5.3 already says is coming (*"the manifest concept M4
introduces should carry the set"*), so this is paying for it early rather than inventing it.
**What it costs:** the `missing_main` refusal at `src/js/Emit.zig:575-591` is re-specified, and
`boundary.md` §5.3's "ONE entry point and ONE platform" becomes "one platform, a set of entry
points". The per-platform half is untouched.

**3. Does `lazy` wait for effects?**
*Options:* (a) yes, as an E-slice after E3; (b) no — invent `Lazy a` now; (c) no — ship `lazy` as a
pure *packaging* marker that splits chunks but loads them all statically, and make it lazy later.
**Recommendation: (a), and the dependency is not negotiable.** (b) builds the type P2 deletes. (c) is
worse than it sounds: a keyword called `lazy` that is not lazy would ship a promise the compiler does
not keep, and it bakes in "a lazy reference has the declared type" at exactly the moment that becomes
true anyway — so it buys nothing and spends the word. The honest form of (c) is decision 2's
multi-entry, which splits code without claiming to defer it.
**This reorders the roadmap**, and the owner is the only person who can: `backend.md` §1's "M3d —
chunking and `lazy`" becomes "M3d — chunking", and `lazy` joins `plans/effects-plan.md` as a slice
after E3.

**4. What is a "route", and does M3d need a browser platform?**
*Options:* (a) restate §1's acceptance as *"a two-ENTRY program splits and both entries run"* and
keep B3–B5 after M3d; (b) keep "route", which makes M3d depend on B4; (c) move B3/B4 before M3d.
**Recommendation: (a).** "Route" is not a word `boundary.md` defines, and on the Node platform the
only entry point is `main` (`boundary.md` §5; §9's root list: *"Today that is `main` and nothing
else"*). Restating the acceptance in terms of entries makes it satisfiable by D3 and keeps
`boundary.md` §8's order — B3 ports, B4 browser, B5 `Intl` — after M3d, for a better reason than §1
gives: ports add roots to §9's root list, and a root set that grows after the chunker exists is a far
smaller change than a chunker written against a root set that does not.

**5. Does a `--release --library` build keep per-module files?**
*Options:* (a) one chunk, like any other release build; (b) per-module files with short names, so a
library stays importable module by module.
**Recommendation: (a) for now, and say so in `backend.md` §2.** A library consumer today is
hypothetical — there is no package registry and no cross-package import of compiled output — and (b)
can be added without breaking (a). Flagged because it is user-visible and because it is the one place
where "release output is chunks" might be wrong for the artifact's purpose.

**6. Is `lazy` restricted to function-typed declarations?** (Decide with 1 and 3; it is not
actionable until D4.)
*Options:* (a) yes — the call is the suspension point; (b) no — reading the name suspends.
**Recommendation: (a).** A top-level beni value is emitted as a module-level constant evaluated at
import time, *"outside any fiber, with no scheduler to park on"* (`plans/effects-plan.md` §5,
decision 5, measured). A `lazy` constant would have to suspend at module-evaluation time, which is
the one place in the design where nothing can. Restricting the marker to function types also answers
report 12's open question 1 — *"what a `lazy` declaration means to the constant folder"* — by
construction: there is no constant to fold.

---

## 7. Could not determine

- **The chunk-count distribution a declaration-granular colouring produces on a real beni program.**
  Report 12's own open question 2, unchanged: there is still no beni program in this repository large
  enough to have routes. Until there is, the merge threshold of §3.2 is a guess with a method
  attached rather than a measurement.
- **Whether the release namer's emission-order assignment survives multi-entry** without a byte-level
  surprise. §9 promises names are a function of position in `emissionOrder`; with several entries the
  *order of modules* is unchanged (sorted path), so it should hold exactly — but no build has ever
  had two entries, and "should" is the word §9's own three wrong edge sets were written with.
- **What a chunk costs at Node start-up as against over a network.** Every figure in report 12 §2.6
  and every figure in §4 above is a *compressed transfer* number. A Node CLI reads uncompressed files
  from disk, where the cost of twenty files is twenty `stat`s and twenty parses, not bytes. Nobody has
  measured beni's start-up, and until B4 exists the Node platform is the only consumer of the output
  chunking is supposed to help.
- **Whether concatenating siblings is safe in practice.** §4 prices it at 1 215 brotli bytes on
  `Dictionaries` and declines it on a name-collision argument. Whether the seven siblings in this
  repository actually collide was not checked, because the check would not generalise: the rule has
  to hold for siblings nobody has written yet.
- **The interaction report 12 §4.4 warns about** — *"§9.3's saturated-call specialization is exactly
  the kind of whole-program pass that defeated GWT's splitter — the interaction must be designed, not
  discovered"*. It is moot as written, because §6 dropped the specialiser with currying. The live
  version of the question is §9's release inliner: a single-use inline that pulls a declaration's body
  across a chunk boundary would make a lazy chunk's code eager. It is currently *local* to one
  declaration (§9 item 1), so it cannot; nothing enforces that it stays local.
