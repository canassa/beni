# S1's byte gap and the release compiler's latency — findings, 2026-10-22

Written by the latency manager session for the owner. Two parts: what the release compiler's
latency work found and changed (#464), and an in-depth reading of why S1 (#297) is above its byte
bar. Every number is measured on dagon (x86-64 Linux) unless it says otherwise.

## Part 1 — Release compiler latency (#464)

### Result

The research dashboard (`unique-components`, `--lists none`, seed 1), ReleaseFast,
`beni build --release --no-cache --jobs=1`:

| build | 2026-10-19 | now (master) |
|---|---|---|
| N = 64 | never finished (killed at 21 GiB) | about 160–170 ms, about 95 MB |
| N = 64 without the `withDefault` merge | 1.33 s | about 150 ms |
| N = 16 | 0.55 s | about 60 ms |

Every output byte stayed the same at every step, or got smaller where a PR says so and lists it.

### What was wrong

1. **Points-to (fact 3) did work proportional to sites × properties × readers.** A spread
   re-walked every source site and property on every change; a member read re-unioned every
   site's property; every var that copied another kept and regrew its own copy of the set.
2. **Types were thrown away**, so one shared helper (`Result.withDefault`) merged every widget's
   model into one set that flowed back into every widget.
3. **Run-level waste:** memory was taken fresh on every one of the six analyses (a quarter of the
   wall time was page faults), the small-function inliner was capped at 256 calls per pass, and
   constructor folding finished in three passes what it could finish in one.

### What was merged

| PR | Change | Effect |
|---|---|---|
| #485 | copy edges, field summaries, load cells | N = 64 builds at all: 6.5 s |
| #494, #495 | counters; repairs of the new machinery | — |
| #497 | one shared copy of each site set (hash-consed) | storage 20–117× smaller |
| #500 | a read of `v.p` reads `v`'s field summary | edges per run 419k → 92k on the no-merge build |
| #501 | the structural passes keep their scans per statement | `specialise` with small sets 387 → 146 ms |
| #493, #560, #561, #528 | the type-key artifact and the declared-type filter | N = 64 1.96 s |
| #566 | bindings and arguments from member reads are copy edges | N = 64 0.69 s |
| #567 | a spread target's untouched fields share one var | 0.45 s |
| #569 | a var that copies one var has that var's summary | 0.37 s |
| #572 | batched first-in-first-out join worklist, set ids | no-op joins 464k → 42 |
| #578 | folds deferred to the end of a sweep | 0.33 s |
| #581, #584 | an analysis keeps fact 3 when nothing it reads changed | one solve fewer at N = 64 |
| #586 | regenerated skill API references (master was red) | — |
| #591 | the inliner writes every independent candidate per scan; no cap | inliner 40 → 15 ms |
| #592 | one reused arena for each fact-3 run | page faults −45%, RSS −⅓ |
| #602, #604 | constructor folding finishes in one pass | 3 passes → 1, 6 analyses → 4 |
| #605 | fact 3's lookups without searching | fact 3 −10–14% |
| #611 | each module lowered once | lowerings 151 → 80 |
| #612 | fact 3's lists grow in place; huge pages on Linux | faults −61%, N = 64 201 → 169 ms |

Closed after measuring, because they gained under 1% or added risk for nothing: #616 (spreads by
difference), #635 (driver skips; its finding stands: the driver already runs an analysis only after
a real change), #634 (the inliners' scratch memory is first-time fill, not garbage).

### What remains, and the floor

The latest whole-build profile (`plans/build-profile-2026-10-21b.md`) puts this program's floor at
75–90 ms single-threaded and 50–60 ms with `--jobs=8`. The remaining structural step is the
combined solver (`backend.md` §9): slice 4 (facts 1, 2, 4 and 5 in one sparse solve) is PR #647,
in its gates; slices 5 and 6 follow, and slice 6 is what removes the repeated analyses
(estimated −30 to −45 ms). `--jobs=8` saves only 13 ms today, because ownership, writes and
`specialise` run serially.

Two operational findings:
- **Two managers steer dagon in opposite directions.** At 2026-10-21 16:13 UTC another session
  recorded that the owner moved the priority back to S1 and stopped a latency probe; later the owner
  told this session to work on milliseconds. Both sets of agents share dagon's CPU.
- **dagon's disk filled** (3.6 GB free). Clearing this session's finished worktrees' build caches
  freed 227 GB. Other sessions' worktrees hold more: `beni-records-r1` 159 GB of cache,
  `beni-inline-s1`, `beni-lvl` and `beni-poly` about 170 GB together.

## Part 2 — Why S1 is above its byte bar

### The bar and where S1 stands

S1's bar (#297, `plans/direct-rewrite.md` §4): bytes ≤ 1.1 × tea-inline at N = 1 and N = 256.
The S1 team's latest fits, brotli, all 15 points (`--lists none`, sizes 1–256, seeds 1–3):

| scenario | beni-inline | tea-inline × 1.1 | ratio |
|---|---|---|---|
| unique-components, per widget | 256.7 | 160.7 | 1.60× |
| unique-components, fixed | 2 749 | 2 227 | |
| big-component, per widget | 91.1 | 79.0 | 1.15× |
| big-component, fixed | 2 055 | 1 708 | |

Validation, measured by the S1 team with a compiler-constant stub, is 18–19 B per widget and about
650 B fixed. It was the largest item on 18 October (122 B per widget) and is no longer the problem.

### Method

I read both bundles in full for unique-components seed 1 at N = 4, 16 and 64 (beni-inline from the
S1 team's `research-before-normal` build of 2026-10-21, tea-inline from the research repo), split
each into categories by code shape, and measured each category's brotli cost by deleting it. Then I
edited the actual output into each target shape, one change at a time, and re-measured, as
`browser-inline.md` §8.9 does. Per-widget figures are (N = 64 − N = 16) / 48. Caveats: one seed;
deletion costs are not additive under brotli; the edits are approximations (the in-place edit
covered 238 handlers, the rename skipped template strings, so both are lower bounds).

### What each side writes

tea-inline is one markup string and one closure per widget. In the closure, bindings are grouped by
field, and handlers write the model in place and schedule a group:

```js
c(e[3],()=>{t.cups=-1,n(r[0])})
```

It does not validate pushed state (`structuredClone` into the model), it uses UTF-16 `.length`, and
it writes `Math.min(19, s.cups + 5)` where the source says `clamp (cups + 5) (-10) 19`, because the
generator knows the lower bound is never reached.

beni-inline writes the same handler at the program site, with a two-level spread and a pass that
calls each binding function with its arguments:

```js
bj=()=>{let a=_a,d={...a,w1:{...a.w1,cups:-1}};_a=d;{jd(fb,_a.w1)}}
```

### Per-widget cost by category (brotli, deletion, seed 1)

| part | beni-inline | tea-inline | gap |
|---|---:|---:|---:|
| markup | 69.8 | 68.5 | +1 |
| bindings | 64.4 | 45.8 | +19 |
| handlers and their passes | ~61 | 33.6 | +27 |
| initial model | ~24 | 12.3 | +12 |
| validation (shared data, dispatch, net of decoders) | ~30 | 0 | +30 |
| enum-cycle functions, element tables | ~6 | ~3 | +3 |
| **total slope** | **286** | **173** | **+113** |

On 19 October the same comparison gave 288 against 173. For this seed the slope has not moved
since; across seeds the fit went from 264 to 257, almost all from #625.

### What each change is worth (edits to the actual output, brotli)

| edit | B/widget saved | owner |
|---|---:|---|
| record writes in place | 2.8 | #315 R6–R7, blocked on #286 |
| each pass as one nullary call per group | 15.7 | the 19 October "~27 B" item; #614 tried it and grew |
| `init` inlined | 2.1 | none — a defect, below |
| record field names shortened at N ≥ 29 | 4.8 | none — a defect, below |
| **all four** | **26** | |

After all four the slope is about 259 B per widget against a bar of 161 on the fits. With
validation at 18–19, **55–75 B per widget has no owner.** The 19 October estimate that "about 48 B
of the gap is owned by planned work" was too high: measured, it is about 26.

### Findings, in order of size

1. **In-place record writes buy CPU, not bytes, by themselves.** Brotli compresses the repeated
   spreads almost away (2.8 B per widget). They matter for bytes only as the precondition for
   finding 2.
2. **The per-widget scope is missing.** tea-inline's bindings read `t.cups` from a closure that
   holds the widget's slice; beni-inline's read `_a.w1.cups` and take `(elements, slice)` at every
   call. A closure cannot hold the slice while records are spread, because the slice is a new object
   after every write — which is why the 19 October diary says the closure headers wait for #315.
   With in-place writes the slice is stable and the tea-inline shape becomes possible. Not yet
   measured; the nullary-call edit alone saved 15.7 B per widget without changing the scoping.
   Owner: needs #286, then #315 R4–R7, then a change to "handlers live at the program site".
3. **Cross-widget readers are paid per writer.** Each writer's handler calls every reader's binding
   (`kd();oi();qi();ri();` in widget 1's coins handler). tea-inline registers each reader once into
   the field's group at mount and its handlers say `n(r[1])`. This is design decision D-c (static
   calls, no registration); its cost grows with writers × readers.
4. **Two defects, about 7 B per widget, no design change:**
   - each widget's `init` stays a function called once, `e=I(null)`: the `⊤` parameter is erased
     in the declaration but the call passes `null`, and the inliner does not take a call whose arity
     differs;
   - above 29 widgets the schema reader uses one shared validator driven by shape data
     (`L=[F,0,["coins",A],…]`) that returns records with the host's keys, so every model field keeps
     its source name in every handler and binding (`.w1` appears 354 times at N = 64, 8 times at
     N = 16).
5. **Bindings carry language costs:** values hoisted into `let`s under the evaluation-order rule
   (#618's totality addresses this), string length through a code-point helper, `Maybe` boxed,
   enum cycles still compiled as a `switch` in a labelled block.
6. **The S1 items in flight are single-digit cuts** — totality (#618; its full gates found a compiler
   panic), dynamic taggers (#640), exact whole-model writes (#641, held: compile-time neutrality not
   passed), helper correctness (#610). Some are correctness work, not size work. #614 was measured
   and rejected (+6 B per widget); #625 saved 7.6.
7. **The yardstick skips what beni guarantees.** tea-inline does not validate pushed state, counts
   UTF-16 units, and relies on generator knowledge (`clamp`'s unreachable bound). A compiler that
   keeps beni's guarantees pays for each.

### Status of the record-write work

#315's plan (2026-10-18): R1–R3 in parallel with #286, R4–R7 after it. Merged on 18–19 October:
record cells, the update demand in report mode, record writes in summaries, closures for record
writes (#388, #391, #408, #415, #421). Remaining: R4 enforcement, R5 the channel to the lowering,
R6 the in-place lowering, R7 `browser-inline`'s in-place writes — all waiting on #286 (the path
cut's conservative folding), which has had no activity since 19 October.

### Options

1. **Change the representation to reach the bar:** #286 → #315 R4–R7 → a per-widget scope →
   readers registered once per field group (synchronous, so D3 holds), with the two defects fixed
   alongside. This reverses "handlers live at the program site" and D-c. Before building it, measure
   the shape by editing the actual N = 16 and N = 64 output into it, as above (about an hour).
2. **Change the bar:** for example, judge the stub fit and report validation beside it, or set the
   bar against a tea-inline that validates and counts code points.
3. **Accept S1 above the bar** and move on.

Until one of these is chosen, further S1 slices are unlikely to converge.
