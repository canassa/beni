# Compiling the framework away — the plan

*2026-10-08. The order of work toward the owner's goal: **vanilla JavaScript is the floor, and
beni's output should come as close to it as it can, in speed and in bytes**. Sources: research 58
(the design and the criteria), 59 (where the time and bytes go today), 60 (the design written by
hand and measured), 61 and 62 (how often a message's writes are known). This is a plan, not a
contract: every slice is specified in `docs/design/` before it is built (rule 1), and the plan
follows the slices' measurements.*

*Rewritten 2026-10-09 around the owner's decision of 2026-10-08 to stop patching today's
`browser` platform and rewrite P3 from first principles as a second platform, `browser-direct`,
specified in [`docs/design/browser-direct.md`](../docs/design/browser-direct.md). §1, §2, the
names R2–R6, M1–M4, B1, V1–V3 and §6 are kept so that documents pointing here still resolve; each
item of §3–§4 now says whether it survives, merges into a direct slice, or is dropped; §5 is the
new order; §7 is the direct platform's slices. Section numbers are never renumbered.*

## 1. The bar: research 58's criteria, kept as written

**The owner, 2026-10-08:** keep the criteria. They judge the whole output, model included, and
are not restated after research 60 missed them.

| criterion (research 58 §9) | beni today | P3 by hand (research 60) | `browser-direct`, expected (design §13) |
|---|--:|--:|--:|
| flat sweeps ≤ **1.15×** vanilla, untraced: holes 10 / holes 10 000 / live rows 10 000 / depth 128 | 1.64 / 1.67 / 46.5 / 2.57 | 1.18 / 1.04 / 1.25 / 1.29 | ≤ 1.15 / ≤ 1.15 / ≤ 1.15 / ≤ 1.3 until S7, then ≤ 1.15 |
| list sweeps ≤ **1.3×**: rows 30 000 one-row edit / swap | 5.63 / 8.36 | 1.31 / 0.98 | ≤ 1.3 (≤ 1.15 after S7) / ≤ 1.0 |
| table app bundle ≤ **2×** vanilla (≤ 2 830 B) | 5 510 B (3.89×) | 3 454 B (2.44×) | ≈ 2 650 B [estimate]; the criterion most likely to miss, by core's `List` |
| every table operation ≤ **1.2×** vanilla (a goal in §9, not a kill criterion) | 7 of 9 | 8 of 9 (swap 4.2×) | 9 of 9, `select` ≤ 1.0× |

*Untraced is research 60's real-click mode. Ratios come from that report's batch. The last column
is a hypothesis — P3's hand-written numbers and the design's estimates, not a measurement of a
generated program; each slice replaces it with a number.*

**Every slice reports this table**, measured traced and untraced against vanilla, P2, P3 and
Solid 1, with bytes (`scaling-sizes.mjs`, `sizes.mjs`), on the same machine in one batch — and,
since 2026-10-09, on **both platforms** (`beni` and `beni-direct`, development and release). A
slice's result is the change in these numbers. A slice that moves none of them needs a reason
to exist.

## 2. Rules every slice keeps

- **Analysis says "possibly changed"; a comparison says "changed"** (research 58 §3.3). Analysis
  never decides by itself that something is unchanged. A missed write is a wrong page, which beni
  cannot have.
- **An unknown write set is a cost, never an error** (rule 7). No slice restricts what `update` may
  call or how it is written. A message whose writes cannot be bounded runs today's path.
- **The guarantees stay:** controlled inputs show the model, a defect stops the page, no broad
  `catch` (rule 9), and messages apply in order, each once. *(Amended 2026-10-09: "one render per
  turn" is a property of today's platform; on `browser-direct` a handler writes as it runs and
  there is no render — design §4.3, the owner's Q2.)*
- **Differential testing.** Every specialised path is checked against the general one on every
  `browser/` corpus page, step by step, before it merges. *(Amended 2026-10-09: on
  `browser-direct` the general path is today's platform — every `browser/direct/` fixture is built
  for both and both transcripts must equal the golden, design §12.3.)*
- **Red first, no bending** (rules 3 and 10). Every slice has fixtures that fail first. A slice
  that hits a wall stops and reports it; it does not change the design or the bar.
- **Every byte of runtime justifies itself** (the owner, 2026-10-08: "adding runtime is a
  balancing act"). A runtime piece is shipped only by a page that reaches it, and the design's
  cost table (§3 there) says what each buys. A fast path added to machinery the direct platform
  replaces is patching, and is not done (the R1 withdrawal, §6).

## 3. The work, in order — what survives, merges or is dropped

Each item keeps its name and source; its state after the rewrite is in bold.

### Track R — the renderer and its runtime

**R1. The per-message plumbing** (research 59 §1.6). **Dropped.** Three of its fast paths were
built on 2026-10-08 (constant property names, one walk per mount node, one render slot per
turn, map flags) and the owner withdrew and reverted them the same day: they sped up machinery
the direct platform replaces (design §4.2–§4.3 remove the walk, the queue, the built names and
the context chain outright). The measurement stays (research 59 §1); the `DefectInTurnRender`
guard it found is kept.

**R2. Controlled inputs by an edited-inputs set** (research 58 §5(c); research 60 §5.2).
**Survives, shared.** Built on `browser` on 2026-10-08 (`backend.md` §15.3, *Controlled inputs*);
the direct platform reuses the contract and the code, reconciling at the end of the dispatch
(design §8.1, slice S4). It took live rows 10 000 from 46.5× to P2's level on P3.

**R3. Values that never change** (research 58 §4 W2). **Merges into S1.** The consumer of
`write-sets.md` §9.1 is the direct lowering's template (design §5.1); it is not built on
`browser`. Research 61: 27% of holes overall, 0 of 16 in TodoMVC, 13 of 16 in the table app, so
it is credited with bytes and mount on component-style pages and with no speed on list-heavy ones.

**R4. Per-message write sets and handlers** (research 58 §4 W1/W3, §9). **Merges into S1–S3: it
is the direct platform's dispatch** (design §4), with the specifics kept — beni's selector
(design §6.4), guard-aware writes (`write-sets.md` §3.3), `Debug.log` order by `language.md`
§11.11 — and one specific changed: handlers write directly and stage nothing (design §4.3, the
owner's Q2). *2026-10-08, the owner's decision after V1 (research 62):* the analysis is built
**with nested-message dispatch and same-variant analysis**, as a sound static analysis, and
**gated** on a read-only pass first — `docs/design/write-sets.md` (§4.4 keys, §8 the gate, §9.2)
— which stands unchanged: the pass is shared compiler work and the direct platform is its first
consumer. R4 is not built on `browser`.

**R5. List edits read off `update`.** **Merges into S2–S3** (design §6.2–§6.3), in the same
order, the most common first: append and clear; the `map` idiom through the identity walk
(core's `map` already keeps `===` elements, so slice C's diff is not needed for it); `filter`
through the merge; `List.update k`, `set`, `swap`, `removeAt` as exact scripts (no user in the
repository, research 61 §4.2; built because they are the cheapest scripts and the sweeps use
them). The parked branch `r56-slice-C-over-budget` stays reference only.

**R6. One keyed pass** (research 59 §4). **Merges into S3**: the direct platform ships one
reconciler, P3's, and only for a list some key replaces or permutes (design §6.3). *The owner,
2026-10-08:* the 2026-10-04 decision to keep `Rt.trimmed` on `browser` is open; it is now moot
for `browser` (no further renderer work there) and decided for `browser-direct`.

### Track M — the model half (the wall research 60 found)

**M1. Depth: no per-level functions** (research 59 §3; research 60 §4.3). **Merges into S4 and
S7.** The dispatch half (`Rt$patch` through 128 kinds) does not exist on the direct platform — a
nested update is the arm plus the groups its write set reaches (design §7.3); the copy half is
S7's in-place update (design §7.4). Not built on `browser`.

**M2. `List` when it runs cold** (research 60 §5.1, §6(a)). **Survives as a measurement, in S2
and S3**, on both platforms: the rows ablation (research 60 §4.3) and B1's part-by-part bytes,
plus the building-loop rule (design §7.2) that keeps an accumulator loop's list a plain array.
Rule 10 applies: `List`'s design is the owner's; a finding against it is reported, not acted on.

**M3. Updating the top-level model in place** (research 58 §4 W4, §5(b); research 55).
**Becomes S7**, with its proof obligation written (design §7.4: ownership, and the two rules that
keep identity compares and in-place writes apart) and the owner's W27 amendment (Q4) before it.

**M4. Wide models.** **Merges into S1 and S7.** Below V8's limit the growth was the root patch's
compares, which per-key handlers remove (S1); past 1 020 fields the spread is V8's dictionary
cliff until in-place (S7).

### Track B — bytes outside the renderer

**B1.** **Survives.** Re-measure the table app part by part (research 59 §4's method) on both
platforms at S3 and at S5, and TodoMVC at S5. The remaining distance to ≤ 2 830 B on the direct
platform is expected to be core's `List` (research 60 §4.6: ~1.2 kB before the building-loop
rule; design §13 estimates ~400 B after). What to do about core's `List` is decided from that
measurement, under M2's rule 10 caveat.

### Track U — fewer unknown messages (deferred)

**U1. Reduce the messages that fall back to `patchAll`** (the owner, 2026-10-09: "yes, but on a
later stage; we start with patch all"). Until then, a message whose write set is unbounded
(Conduit's `ChangedUrl`) runs `patchAll`, as `browser-direct.md` §4.1 specifies. The later
work:
- **Three tiers per message:** known at compile time (exact writes); known cheaply when the
  message runs (a run-time switch, still precise); only the new value says (a comparison of the
  smallest replaced part, never the whole page).
- **Six extensions to `write-sets.md`:**
  - split a handler on the constructor of a closed-type value `update` computes and branches
    on (routing: one precise handler per route);
  - run-time positions as any pure expression of the payload and model, and `Dict`/`Set` key
    steps;
  - "replaced at this path" as a write kind, with a compiled patch of that subtree only;
  - function values, by defunctionalisation (the whole program's closures are known);
  - summary rows for every `foreign`, static-dispatch evidence specialised before the
    analysis, and widening for recursion over the model;
  - caps sized against real apps.
- **A byte rule:** precision is chosen per message against bytes. The precise handler is
  emitted only when it pays for itself, otherwise the fallback stays.
- **The measure:** the residual share of `*` and replaced-subtree messages per app (Conduit,
  TodoMVC, the corpus), before and after, with bytes.

Specified first, as one amendment to `write-sets.md` and `browser-direct.md`, with the same
adversarial review loop. Not before S6 (Conduit) has measured `patchAll`'s real cost.

## 4. Validation that gates the analysis work

**V1. A realistic application before R4 and R5 are specified** (research 61 §7). **Done**:
research 62 (Conduit) found 11% of dispatched constructors bounded as the classifier read them
and 94–97% with nested dispatch and same-variant rebuilds, which the owner then put into the
analysis; the gate is now `write-sets.md` §8.2 (≥ ⅔ of Conduit's leaf keys bounded), run as a
corpus case, and the direct platform's S6 criterion.

**V2.** **Survives.** Every slice's measurement follows §1 and research 60's protocol: real-click
untraced plus traced, load recorded, one batch per comparison, pages rebuilt by the compiler under
test (`scaling.mjs` stamps each page with the beni that built it) — on both platforms, with the
subjects and pages design §12.2 lists, a slice's batch under fifteen minutes and the full batch
opt-in.

**V3. Adversarial agents try to break the page** (the owner, 2026-10-08). **Survives, on the
direct platform**, after S4 and again after S6, and after every later slice that specialises
rendering: agents write beni programs designed to make a page show something its model does not
hold: a stale value, a missing or extra element, a controlled input out of sync, a wrong row after
a list edit. They also try to reach a run-time error or a page that stops. Each attempt runs as a
`browser/direct/` fixture built for both platforms (the differential check of §2), in happy-dom
and in Chrome. A program that breaks the page is a defect: it gets a red-first fixture and a fix,
and the spec rule it got past is corrected. The campaign reports what it tried, not only what it
found. It covers write-set limits (`write-sets.md`'s *the limits, in plain words*), list edit
scripts, branches, nested pages, controlled inputs, direct and delegated events, `Html.map`
composition, two programs on a page, and anything the lowering assumes.

## 5. Order, and what can run in parallel

*Rewritten 2026-10-09.*

1. **Now:** the write-set analysis's read-only pass and dump (`write-sets.md` §8), already in
   progress, shared compiler work with no platform consumer yet; and **S0** (§7), which needs
   nothing of it.
2. **Then, in order:** S1, S2, S3 — the first three slices, each on the previous, each measured
   on both platforms. After S3 the direct platform has either met the table app's targets or
   shown which piece cannot (design §13's kill criteria 1–4), before any guarantee machinery is
   built on it.
3. **Then:** S4 (guarantees and the rest of rendering), then the first V3 campaign.
4. **Then:** S5 (effects and TodoMVC), with Q5 taken before it; S6 (Conduit), then the second V3.
5. **Then, after Q4:** S7 (in-place update).
6. **Then:** S8, the decision: one batch, one report, one platform kept.

Nothing further is built on `browser`'s renderer or runtime while the two platforms are compared:
a defect there is fixed; a fast path there is patching (§2). At most three agents at a time; only
one browser batch at a time (a lock file, as on 2026-10-08).

## 6. Decisions

*Taken by the owner, 2026-10-08:*
- **R2 approved:** controlled inputs are kept by the edited-inputs set (`backend.md` §15.3 to
  be amended). The spec lists every way an input's value can change and how each is caught.
- **R6 open:** the 2026-10-04 decision to keep `Rt.trimmed` is not binding; the measurements decide.
- **The write-set analysis's open choices (O1–O8) taken as recommended**; its limits are written in
  plain words at the end of `docs/design/write-sets.md`. **V3 added**: adversarial agents try to break
  the page once the analysis has consumers.

*Taken by the owner, 2026-10-08, later the same day:*
- **R1's fast paths withdrawn and reverted** (commits `914220c91`, `3dca026cb`, `73cc03f9f`):
  they sped up machinery the compile-away work replaces; a fast path on that machinery is
  patching. The measured record (research 59) stays.
- **Rewrite P3 from scratch and first principles, on a separate platform, so the current one can
  still be compared with it.** "The target is fast and small runtime"; vanilla is the floor in
  speed and bytes; "my size/speed rule was about the minimizer step, not for adding runtime;
  adding runtime is a balancing act." The design is `docs/design/browser-direct.md`
  (2026-10-09); this plan's §7 is its build order.

*Taken by the owner, 2026-10-09:*
- **The direct platform's questions Q1–Q6 (`browser-direct.md` §15) taken as recommended**: payload
  read at the event; direct writes, no batching; `flush` a no-op and `Dom.rendered` at the end of
  the dispatch; W27 amended for in-place update before S7; non-suspending subscriptions off fibers
  before S5; TEA as the direct platform's architecture. "Start building it." S0 starts.
- **Track U deferred:** reducing unknown messages (the tier model and six analysis extensions)
  is planned but starts later; the direct platform begins with `patchAll` as specified.

*Still the owner's:*
- Anything M2 or B1 finds against `List`'s representation. Report it to the owner; do not act on it.
- Restating any criterion in §1. Not to be proposed again without new evidence.

## 7. The direct platform's slices

*Added 2026-10-09.* The slices of `docs/design/browser-direct.md` §14, with their state. Each is
specified before it is built, has red-first fixtures (`browser/direct/`, `emit/direct/`), and is
measured on both platforms, P3, vanilla and Solid 1 in one batch (§1's table). A slice that misses
its kill criterion (design §13) stops and reports; it does not bend the design or the bar.

| slice | what it builds | proves / kill criterion | state |
|---|---|---|---|
| **S0** — the stats gate, the platform and the harness | first the analysis-only **stats gate** (`dump --stage=writes`'s `site`, `markup_value_roots`, `carriers`, `pairs`, `reconciler` and `patchAll` lines over every corpus app, the table app, TodoMVC and Conduit; the Conduit driver logging each dispatch's key; `size-parts.mjs` on a `set`-only program for the trie's write half); then `platforms/browser-direct/` (manifest, `Tea` with `sandbox`, `Rt` with `send` and `run`, `zig/direct.zig`) registered in `build.zig`; the program hook in the markup interface (`boundary.md` §9.4.6, a dated minor version); a static `view` mounted inside the guard; the mounted-twice refusal; the harness subjects `beni-direct`/`beni-direct-release`; `bench/size.mjs`'s page line; `browser/direct/Hello` built both ways | ≥ ⅔ of Conduit's keys bounded, `patchAll` on ≤ 10 % of the scripts' dispatches, a handful of value roots, pairs linear in keys, the trie's write half as §13 assumed (design §13 kill 1); the empty page ≤ 300 B brotli (today 1 234) and imports nothing of `Rt` but `send` and `run`; the two platforms measured side by side | **stats gate built 2026-10-09; kill criterion 1 fires** (research 64): bounded 90/91 and value roots 0 hold; static (48 corpus programs over 5 %, all root writes of non-record models or `Debug.todo`), dynamic (9 of 62 dispatches, 14.5 %), pairs (Conduit 9.21 per key against a median of 0–0.33) and the trie (the table app's `++` ships the write half) fire. Stopped for the owner's decision. **Platform and harness built** (research 65): the floor is 399 B and imports nothing of the runtime module (`Direct`) but `run` — kill 2 passes, the 300 B target is missed |
| **S1** — holes and the two oracles | text and attribute holes, constancy and baking (R3), per-key handlers with direct writes (R4) and listener bodies inside the guard, read-at-event, the `*` key for an opaque `update`, groups and slots; **differential fuzzing** (random key sequences replayed on both platforms, DOM-equal after each step, fixed seeds in the gates) and the **development verify mode** (every group compared after each dispatch, a defect if any would change), both on every direct page from here on; the holes, width, burst and stream sweeps | the holes handler is one compare and one write; holes 10 000 ≤ 1.15× untraced; bytes grow with N by the HTML only; bursts at the K = 1 ratio | todo; **Q1 and Q2 answered first** |
| **S2** — rows | `For` keyed and positional, row templates and instances, static-key holes, the exact edit scripts with tag guards (R5's `set`/`update`/swap/append/prepend/clear/insert/remove, guarded by the tag's condition and never by list identity), delegated listeners for delegatable events and direct ones for the rest, the mount measurement of listener placement and of expandos against a lookup; the rows sweep | rows edit ≤ 1.3×, swap ≤ 1.0×; no reconciler in a bundle whose keys are all exact; `List`'s cold cost measured (M2) | todo |
| **S3** — the table app and the TodoMVC shape | the one reconciler (R6) for `replaced`/`permute`, the identity walk and the filter merge (R5), the selector and key map with their order, helper inlining under the size gate and shared sites, the building-loop rule in the backend (both platforms), `Html.map` static composition, the dispatcher for carriers; B1's part-by-part bytes on both platforms; `browser/direct/FilteredFor` (a filtered `For` with a toggle) measured at 100 and 1 000 todos | every table operation ≤ 1.2×, `select` ≤ 1.0×; bytes ≤ 2 830 or the miss attributed to core's `List`; **no operation slower than P3, `select` ≥ 30 % faster, bytes ≤ 0.85× P3's** or stop (design §13) | todo |
| **S4** — guarantees and the rest of rendering | controlled inputs (R2, shared, plus the no-op send after an edit), defects, crash screen and teardown, branches and `Show` with teardown's reset and liveness, derived values per arm, nested updates (M1's dispatch half), the value path for recursive helpers and `List Html` holes, programs per mount and nested programs; the live, derived, depth, helper-rows and helper-tree sweeps; the first V3 campaign after it | live rows ≤ 1.15×, derived flat, depth ≤ 1.3×; every `browser/dom/` transcript equal on both platforms | todo; **Q3 answered first** |
| **S5** — effects and TodoMVC | `Tea.element`/`document`/`application`, the command driver copied and driven by handlers, subscriptions diffed by write set, the after-render point, `flush` a no-op (Q3); every `browser/tea/` fixture; `bench/todomvc/` with a vanilla subject, routing and sandbox builds both | the routing build ≤ 2× vanilla TodoMVC and below Svelte 4's 4 246 (which depends on Q5; without it the target is the sandbox build's); its three messages at 100 todos ≤ 1.2× vanilla (≤ 1.3× at 1 000, toggle-one through the reconciler); both improve on today's platform or the win was constancy (design §13 kill 6) | todo; **Q5 answered before the target is set** |
| **S6** — Conduit | nested keys and same-variant rebuilds through handlers, `patchAll` for the `*` key, the three Conduit scripts on both platforms, bytes and three timed messages; the second V3 campaign | ≥ ⅔ of keys bounded (the gate); ≤ 10 % of dispatches reach `patchAll`; bytes ≤ 0.7× today's 30 842 | todo |
| **S7** — in-place update (M3, M4's cliff) | the ownership analysis and the assignments in handlers; the identity fixtures extended with design §7.4's two rules | width, depth and rows at ≤ 1.15× | todo; needs Q4 |
| **S8** — the decision | one batch of everything on both platforms, P3, vanilla and Solid 1; one report | the owner keeps one platform and the other is deleted | todo |

**Shared and not shared** (design §12.1): the compiler, its analyses, `core`, `html`, `browser`'s
capability modules and the defect teardown, the corpus driver and the bench harness are one copy;
the `direct` lowering, its `Rt` and its `Tea` (the command driver copied, ~300 lines) are the
platform's own and go with it at S8.
