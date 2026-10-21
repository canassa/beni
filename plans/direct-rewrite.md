# The direct platform, rewritten from the output — the plan

*2026-10-17. The owner's decision: throw `browser-direct` away and start from scratch. This is
the order of work, the bars and the rules for the second attempt. It is a plan, not a contract:
every slice lands against a golden and a measurement, and the plan follows the measurements.
Section numbers are never renumbered (CLAUDE.md rule 2). Sources: the first platform's own
reports (research 70, 73, 87, 91, 100), the compile-to-vanilla studies (105, 106), and the
reactivity-research project at `../reactivity-research` (its `notes/`, `results/` and
`frameworks/tea-inline/`), which measured beni's two browser platforms against seven other
approaches on six generated scenario families, 1 to 256 units, three seeds each.*

## 0. The plan in one paragraph

The output is the specification. A prototype emitter in the research project, **tea-inline**,
already writes the JavaScript this platform must produce: a handler is the `update` arm inlined
into the listener, writing the model's fields and scheduling the bindings that read them; a
binding is one DOM write guarded by a compare; a keyed list edits rows in place and reconciles
only when the array is replaced; a unit (page, tab, modal) is markup plus a function plus its
disposers; a derived value is a memo node with its readers written into its writer. Its runtime is
730 B brotli, its slope is at or below hand-written vanilla's on every scenario that has one, its
local events are flat in N and faster than Solid's everywhere. The rewrite builds the lowering
that produces that output from beni source, **slice by slice, each slice pinned by goldens taken
from tea-inline and measured on the research scenario that exercises it**, starting from an empty
runtime and adding bytes only where a golden needs them. The analyses the first platform built —
write sets per message key, anchored read sets, the ownership checker — are kept; they are the
hard part and they were never the problem. The strict rule holds from the first slice: a key the
analysis cannot bound, a structural write it cannot name, a markup site it cannot number, are
build errors that say why, never a coarse fallback.

## 1. Why a rewrite, in numbers

What the first platform shipped on the research scenarios (brotli bytes, fitted baseline + slope
per unit; `../reactivity-research/results/2026-10-17-*-2/README.md`):

| scenario | vanilla | tea-inline | Solid 1 | beni-direct v1 |
|---|---|---|---|---|
| shared-components (N ≥ 16) | — | 3.4 k + 22 | 9.5 k + 28 | 19.4 k + 144 |
| unique-components | — | 2.7 k + 172 | 8.6 k + 228 | 13.2 k + 854 |
| big-component | — | 1.9 k + 81 | 7.7 k + 92 | 14.4 k + 227 |
| big-table (N ≥ 4) | 4.2 k + 255 | 4.1 k + 149 | 10.1 k + 226 | no build past N = 15 |
| derived-graph (N ≥ 16) | 2.9 k + 142 | 3.5 k + 101 | 9.4 k + 123 | 17.0 k + 292, no build past ~160 |
| routed-app | 4.2 k + 451 | 4.5 k + 309 | 13.1 k + 430 | 20.1 k + 1 022 |

Where the bytes are, N = 1 unique-components, one widget, raw minified (`perSource`): the app
(`W1` + `Main`) 14.9 kB; `Rt` + `Direct` + `Tea` + `Hosted` 14.5 kB; `Task` 4.3 kB; `Dict` 3.9 kB;
`List` 3.3 kB. tea-inline's whole app for the same widget is 2.4 kB raw and its runtime 1.0 kB.

The causes, each a nameable decision and none a limit of the approach:

1. **The host boundary drags the effects runtime in.** `Tea.element` is the only way to hear from
   the host, and it brings the fiber kernel, `Dict` and the command driver's keyed tables.
2. **Messages survive across modules.** A key below a helper (`updateWith … (W.update sub w)`)
   rebuilds the sub-message as a value, keeps the `case`, and spreads per arm; the `Html.map`
   leaves a `$$cx` context chain. Every component-structured program is this case.
3. **Per-instance specialisation, no sharing by kind.** `Main` is 142 kB raw at N = 64 against
   36 kB on browser-tea; a 30-slot scope record and guard flags per instance.
4. **Derived values recompute as a block**: a local edit costs O(N) calls (7.85× for 8× the size),
   and the compiler's output and memory grow about N² (#282).
5. **The ownership checker's width cap** (64 paths) refuses flat models (#286, #289).
6. **No lifetime**: no unmount (W51), every page's templates built at module load, no lazy modules.
7. **Guarantees priced per page**, not per use: rank-correct duplicates and their key map, the
   dispatch guard, multi-program mount, `browser-tea`'s move order kept for oracle parity at the
   cost of LIS (research 73 §5).

And the process cause: a 3 000-line normative design written before the output, with the lowering
drifting from it (§4.1 says "no message"; the output has one). The rewrite inverts the order.

## 2. The target output

**Goldens come from tea-inline**, generated, not hand-written:

```sh
cd ../reactivity-research
./rr generate unique-components tea-inline --size 1 --seed 1    # generated/unique-components/n1-s1/tea-inline/src/
./rr generate big-table         tea-inline --size 1 --seed 1
./rr generate derived-graph     tea-inline --size 4 --seed 1
./rr generate routed-app        tea-inline --size 2 --seed 1
./rr generate shared-components tea-inline --size 4 --seed 1
```

Each slice copies the constructs its golden needs into `tests/corpus/emit/release/direct/` as
beni programs with expected output, written in tea-inline's shape (`frameworks/tea-inline/README.md`
documents every construct and the reason for each byte-saving choice; `template/runtime.js`,
`rows.js`, `routes.js`, `graph.js` are the runtime). The expected JavaScript is the shape, not the
bytes: names and numbering may differ; a message object, a `case`, a scope record, a block
recompute, a subscription list that is never removed may not.

**What is in a golden, construct by construct** (the research README, §"From a click to the DOM"
and the per-scenario sections):

| construct | the output |
|---|---|
| a message arm | inlined into its control's listener: field writes, then `schedule(G[i], …)` of the groups of exactly the fields written; no `Msg`, no `case` |
| a binding | `() => text(E[n], expr)` / `prop(…)`, in the group of each field it reads; one compare, one write |
| static markup | one HTML string per unit, parsed once; elements by document order (`E[n]`) |
| a keyed list | rows `[node, set]` keyed by id; in-place `add`/`drop`/`swap` from the arm that knows the row; reconcile (LIS) only when the array is replaced |
| a conditional | `when(node, cond)` on a node built in place (eager), until lifetime says otherwise |
| a derived `let` | a memo node: compute, compare, store, queue its static readers; rank-ordered flush |
| a unit (page, tab, modal) | markup + function + disposers (`up`/`down`); readers of outliving state register and unregister |
| a shared kind | one factory per kind, one positional config row per use |
| an external event | the key's handler called with the decoded payload; an exact snapshot writes every model field (owner amendment, 2026-10-21) |

Research 106 recommended "compiler-recognised factory sharing, local reducers (C) as the
start, B as comparator". The research project measured A (tea-inline), B (tea-dirtybits) and C
(tea-local) on all six scenarios: A and C tie on bytes within 5–10 % either way, A is faster on
every scenario and 2.7× faster on derived-graph, and A is the one with lifetime and memo nodes
built and measured. Factory sharing is in A's shared-components emitter. So the target is A's
output with C's per-kind instance factory where a kind is used more than once.

## 3. Rules every slice keeps

- **The output is the spec.** A slice is done when its goldens pass and its scenario's bars (§4)
  are met. Design prose covers only what a golden cannot: the analysis rules and the error
  taxonomy. No amendments-in-place document of the first platform's size.
- **Start from nothing.** The platform imports nothing of `browser-tea`'s `Rt`, `Hosted`, driver
  or kernel. The empty mounted program is ≤ 300 B brotli (the first platform's one criterion that
  held: 327 B). Every runtime function is added by the golden that needs it; the known total is
  tea-inline's 730 B plus about 170 B for units and about 250 B for memo nodes.
- **Strict, not coarse.** No `patchAll`, no value path, no "re-check the page". A key of class `*`,
  a structural write the recogniser cannot name, a markup site that cannot be numbered, a cap of
  the analysis reached: each is a build error naming the key, the tier and the cause, and what
  to write instead. Compiler limits are a separate error class and say so. This reverses
  `compile-away.md` §2's "an unknown write set is a cost, never an error" for this platform; the
  reason is §1's seventh cause and research 71's precedent (ownership: an error, with numbers).
- **Analysis says "possibly changed"; a compare says "changed"** (kept from `compile-away.md`).
  A handler drives its groups from the write set and never from identity; in-place writes and
  identity compares never meet (`browser-direct.md` §7.4).
- **Immutable first, in place where proven.** tea-dirtybits (immutable, structural sharing) is
  within 10–25 % of tea-inline everywhere. An arm writes in place where the ownership checker
  accepts it and copies where it does not; a checker cap is an error, not a silent copy.
  *Amended 2026-10-17 (the owner):* **no copy.** A record update the checker cannot prove safe in place
  is a compile error, exactly as a shared list edit is; the program copies explicitly where it must
  keep the old value. The checker, in-place lists and in-place records are the base language's, on
  every platform, not this platform's. The checker has no limits: it judges any program by scaling
  precisely, never by coarsening (#315, #286, #289, #293).
- **The analyses are kept**: `write-sets.md`'s pass (90 of Conduit's 91 keys bounded), anchored
  read sets, the ownership checker. Every slice consumes them; none re-derives them.
- **Compile time linear in N**, measured at N = 256 on every scenario from slice 1, so a quadratic
  lowering is caught at the first scenario and not at the fourth (#282).
- **The guarantee ledger is decided once** (§8), before slice 1, and not re-litigated per slice.

## 4. The bars, per scenario

Measured in the research project, which already has the beni generators for every scenario
(`scenarios/<scenario>/shared/beni.js`), the correctness check with its same-task pass, the
locality rule and the size and CPU runners. No new test programs.

```sh
cd ../reactivity-research
./rr check   <scenario> beni-direct                 # correctness, same-task, disposal; locality for prototypes
./rr work    <scenario> beni-direct --sizes 16,256  # calls per action, N = 16 against 256
./rr measure <scenario> beni-direct                 # sizes, seeds 1–3, into a scratch --out
./rr bench   <scenario> beni-direct --quick         # script µs per event
```

A slice meets its bar when, on its scenario, seeds 1–3:

- `./rr check` passes at every size in `runs.json`, same-task included;
- **bytes**: total ≤ 1.1 × tea-inline at N = 1 and at N = 256 (baseline and slope both);
- **CPU**: median local event ≤ 1.1 × tea-inline (`--quick` for iteration, the full method for
  the record);
- **locality**: every local action ≤ 1.1× calls from N = 16 to 256 (tea-inline is 1.00);
- **compile**: time and peak RSS linear in N to 256;
- beni-direct is listed in `runs.json` for the scenario at sizes 1–256, and `./rr report` runs.

The research project's rule 2 applies: an implementation the owner has not checked by hand through
`./rr serve` is not in the numbers.

## 5. The slices

Each slice: what lands, its golden, its scenario and bar, what it depends on. The order is the
order of the gaps by bytes, with the boundary first because every scenario dispatches.

### S0 — the boundary without the kernel, and the empty page

- `Sub.on` over a host event compiles to `addEventListener` and the key's handler; a timer
  subscription to `setInterval`/`clearInterval` with its remover; a pushed value decoded by the
  derived codec, with the decoder's failure a typed refusal and no error prose in release.
- A `Cmd` that cannot suspend is a direct call. A suspending command or subscription is a build
  error in this slice ("needs the task kernel: not on this platform yet"); the kernel returns
  behind reachability in S6.
- `dispose`/unmount (W51): the program's root closed, its listeners and timers removed; the
  research adapter stops reaching past the API.
- **Golden**: the empty program; one program with one window subscription and one timer.
- **Bar**: empty ≤ 300 B; with the subscription ≤ 450 B.

### S1 — holes and handlers, across modules

- Static markup per module as one HTML string, optional end tags left out; elements by document
  order; texts and attributes that never change baked in (`write-sets.md` §9.1's constancy).
- Per-field binding groups; a binding in the group of each field it reads; cross-module readers
  register into the source module's table at mount (readers above their source only, the
  compiler checks).
- **Every leaf key's arm inlined into its control's listener, through helpers and module
  boundaries**: `updateWith`, `Html.map` over a constructor, a widget module's `update` called
  from `Main`. No message value, no `case`, no context chain. A key reached only through an
  opaque `update` is an error.
- Record writes in place where the ownership checker accepts, spread otherwise. Enum cycles as
  comparison chains. Number inputs refusing out-of-range values before the write.
- One flush per task (microtask) or synchronous writes: decision D3 (§9).
- **Golden**: the counter; a widget with a list of texts; two widgets, one reading the other.
- **Scenario**: unique-components and big-component, sizes 1–256. Bar per §4.
- **Depends on**: S0; the ownership checker on records (exists).
- *Amended 2026-10-17 (the owner, after S1's design pass; #297):*
  - **The bar.** S1 meets §4's full bar on a **no-list-widgets variant** of the generators, sizes 1–256. The unmodified scenarios' list widgets edit rows by id, so those scenarios are **S2's** done criterion.
  - **CPU** is measured with record spreads. The N = 256 miss is owed to #315 (the checker does not judge records yet) and re-checked when #315 lands.
  - **Caps.** The write-set pass's leaf, alternative and size caps are lifted. `k` and the round cap are replaced by #286's precise folding.
  - **Conditionals** are eager `when` here, not in S4.
  - **Cross-module readers** are static calls from the writer key's handler, with no registration until S4. This replaces the "register into the source module's table" bullet above.
  - **View `let`s.** One read by one hole is substituted here; one read by several holes is S3's memo node.
  - **An arm that reads its message whole** builds that message in that arm only.
  - **Handlers** live at the program site, measured against tea-inline's in-widget handlers.
  - **The "Depends on" line above is wrong:** the checker does not judge records (#315).

### S2 — keyed rows

- A row template per list, parsed once; a row builder returning `[node, set]`; the row's own
  controls carry their arm with the row's item in scope.
- **Exact edits from the write set**: append → `add`; `removeAt`/remove-by-id → `drop`; two
  index writes → `exchange`; update-by-id → the row's `set`. The map-with-id-guard idiom
  (`List.map (λr → if r.id == id then … else r)`) is recognised exactly and lowered to the
  key-map lookup; an unrecognised structural write is an error that names the idiom or the keyed
  primitive (§6). Selection `selected == item.id` as the two-row special case.
- One reconciler, LIS-based (udomdiff), shipped only for a list some key replaces or permutes
  (sort, server rows, snapshot); never `browser-tea`'s move order.
- The id → row map built lazily on the first by-id edit after the set of rows changes.
- **Golden**: the todo list; the js-framework-benchmark table.
- **Scenario**: big-table, sizes 1–256, 1 000 and 10 000 rows. Bar per §4, plus CPU on every
  table operation ≤ 1.2× vanilla, swap ≤ 1.0×.
- **Depends on**: S1; `List` as a plain array with in-place edits under ownership (decided
  2026-10-15); the recogniser (exists in the write-set pass; the lowering must consume it).

### S3 — derived values

- A constant `let` of `view` read by markup is a memo node: compute, compare with the slot, store,
  queue its readers; readers are static lists written into the writer's code; a rank-ordered
  flush so a diamond's bottom runs once; an unchanged value queues nothing.
- Displays reading one cell inlined into the cell; displays reading several run after every
  formula.
- Aggregates over a list re-read the list; an item edit queues the formulas that read the field
  written.
- **Golden**: a three-formula chain with a cut-off; a diamond.
- **Scenario**: derived-graph, fan-out low/mid/high, sizes 1–256. Bar per §4, plus compile
  linear (the first platform died at N ≈ 190).
- **Depends on**: S1, S2 (the items table).

### S4 — lifetime

- A unit (a page, a tab panel, a modal, a `Show` body): markup + function + disposers; built on
  enter, torn down on leave (nodes, timers, registrations into groups that outlive it).
- Readers of state that outlives the unit (global fields, a page's fields read by its tab)
  register on build and unregister on `down`; a write schedules only what is mounted.
- Page state fresh on every mount; a stale event for a unit that left in the same task is a
  no-op (the research check's same-task pass).
- No lazy modules yet; whether `lazy` is a compile-time split point is decision D5 (§9).
- **Golden**: two pages behind a shell, one with a tab and a modal.
- **Scenario**: routed-app, sizes 1–256. Bar per §4, plus mount O(shown) (the first platform's
  mount grew 9.8× from N = 16 to 256).
- **Depends on**: S1; W51 from S0.

### S5 — shared kinds

- A kind used more than once is one factory with a positional config row per use (§5.2's
  shared-site gate, applied, with the gate's constants measured not estimated); summaries
  reading other widgets' state register into their sources' tables.
- **Golden**: three counters and a summary.
- **Scenario**: shared-components, sizes 1–256. Bar per §4 (tea-inline: 3.4 k + 22 B per widget).
- **Depends on**: S1.

### S6 — a real application

- The task kernel behind reachability: a command that suspends brings `core/Task`, nothing else
  does; `Http`, URL routing, storage.
- The strict rule run in report mode over TodoMVC and Conduit first (as research 71 did for
  ownership), every would-be error classified as idiom / intended-global / compiler cap, then
  switched on.
- **Bar**: TodoMVC routing build below Svelte 4's 4 246 B; Conduit ≤ 0.7 × the first platform's
  (research 100's number), every key's handler bounded but the declared route change.
- **Depends on**: S0–S5; the keyed primitive and `replace` (§6).

## 6. Parallel work in `core` and the analyses

Not slices of the platform; each has its own issue and can land in any order.

- **`Dict` on a JavaScript `Map`** (#294), then write-set positions in `Dict` (O3): makes
  `Dict.update k` an exact write at `[k]`. S2 needs neither; keyed-by-`Dict` rows come after both.
- **A keyed primitive**: either exact recognition of the three list idioms (map-with-id-guard,
  filter, append) as named edits, or a keyed collection in `core` whose edits name their element
  (`update id f`, `remove id`, `insert`, `swap`). The strict rule's error for an unrecognised
  structural write points at it. Decision D2 (§9).
- **Exact whole-model writes** (owner amendment, 2026-10-21): snapshots, undo and route changes
  return the new model directly. The existing exact `.whole_record` fact expands to value writes
  of all model fields at the consumer, including every leaf below a nested field. This reverses
  the former class 3 rule; no declaration or new syntax is needed. Lost precision stays class 4.
- **The ownership checker's caps** (#286, #289, #293): a cap is an error that says "limit of the
  checker"; per-field summaries for records of independent fields so a flat model does not hit
  the width cap.
- **Research-project generators**: `scenarios/*/shared/beni.js` will need the keyed primitive and
  exact field sets for snapshots; no replacement declaration is required (owner amendment,
  2026-10-21). The keyed primitive remains independent.

## 7. Risks

- **The recogniser rots.** Exact recognition of the map-with-id-guard is the single thing between
  O(1) and O(n) on the most common event, and syntactic recognisers are brittle (a helper, a
  flipped guard, `indexedMap`). The strict error plus the keyed primitive are the net; the
  rejection rate on the generators and on Conduit is the number to watch.
- **Bytes grow with read edges**: 2.4 B per edge against Solid's 1.1 (the research critique, §4),
  crossover predicted near 17 reads per binding. The scenarios stay far below it; a design with a
  value read by every row (a theme, a locale) needs per-row registration, which is not in any
  slice. Forbid or build: decision D6.
- **Compile-time scaling**: in the bar from S1, measured at 256 on every scenario.
- **Overfitting to the generators**: tea-inline was tuned on them for four rounds; two held-out
  scenarios still favoured it, but tree/recursion and reorder-heavy lists were never built. S6's
  real application is the check, and the research critique's two unbuilt scenarios
  (`notes/2026-10-16-tea-inline-critique.md` §3) are the next if S6 surprises.

## 8. The guarantee ledger

Decided once, before S1 (the owner; defaults proposed):

| guarantee | first platform | proposed |
|---|---|---|
| a defect stops the page (`try … finally` guard) | every entry | keep: measured free (research 59) |
| controlled inputs show the model | edited set, when a `stateful` attribute exists | keep, pay-per-use: the research check requires it |
| rank-correct duplicate keys and their key map | every keyed list | development build only; release assumes distinct keys, the check (`./rr check`) catches duplicates |
| several programs on one page | every page | drop from release until a program needs it |
| `browser-tea`'s move order (oracle parity) | kept, cost LIS | drop: LIS; the oracle compares DOM content and keyed identity, not move order |
| a queued send mid-dispatch | every page | keep (11 B) |
| no runtime exceptions, typed host failures, exhaustive matches, managed effects | — | unchanged: CLAUDE.md rules 7–9 are not the platform's to trade |

## 9. Decisions for the owner

- **D1 — source model**: TEA (`update`/`view`, write sets per key) stays. Research 106 left it
  open; the research project shows TEA lowers to the same output as Marko's signals-in-source
  with the analysis the compiler already has. Proposed: TEA.
- **D2 — keyed primitive or recogniser** (§6). Proposed: both, recogniser as sugar over the
  primitive's semantics, error otherwise.
- **D3 — microtask flush or synchronous writes.** tea-inline batches to a microtask (needs the
  by-id lookups before every row action); the first platform wrote synchronously. Proposed:
  synchronous, one handler one write pass; measured in S1 against the golden either way.
- **D4 — iteration order and key types for `Dict` on `Map`** (#294).
- **D5 — `lazy`**: a compile-time split point under whole-program numbering, or separate
  compilation (Marko's model; costs the 15–20 % whole-program tricks). Proposed: split point.
- **D6 — a global value read inside every row**: forbid (error) or build per-row registration.
  Proposed: error until a real program needs it.
- **D7 — the ledger of §8.**

*Amended 2026-10-17 (the owner).* **D3** is decided: synchronous — one write pass at the end of the
dispatch, inside the handler's guard; measured against tea-inline's microtask in S1 (#296). **D2 and
D4** are decided together (#294, #298): **`Dict` is the keyed collection**, ordered by insertion —
an entries array plus a `Map<key, position>` index; keys are `Int` or `String`; order is part of
the value (`eq` includes it), and `compare` is removed from `Dict` and `Set`. `List` is positional
only and there is **no idiom recogniser**: a structural edit of `List` rows by id is the strict
rule's error naming `Dict.update`. This supersedes §6's "keyed-by-`Dict` rows come after both" and
its keyed-primitive bullet: write-set positions in `Dict` are on S2's path, and the research
generators change to `Dict`. D5, D6 and D7 remain open.

*Amended 2026-10-17 (the owner), the rest of §9:*
- **D5** is deferred to S4.
- **D6:** the error stands until S6. S6's Conduit golden adds per-row registration, because its feed rows read the viewer's follow and favourite state. Its cost per row is measured first with a research variant: big-table with one column reading a global, a one-line generator option.
- **D7:** §8 is confirmed as proposed:
  - the defect guard stays;
  - the mid-dispatch queue stays;
  - LIS replaces `browser-tea`'s move order;
  - duplicate-key checks are development-only;
  - several programs on one page are out of release;
  - controlled inputs are pay-per-use.

**The strict rule's refusals are two kinds** (§3), and the diagnostics keep the split (idiom / intended-global / compiler cap):
- *Compiler limits* are temporary, labelled as limits of the compiler, and each is closed by the slice in its area. Examples: a suspending command before S6, a model-dependent subscription set before S4, `lazy` before D5, an analysis cap.
- *Language rules* are permanent: they are the decision to depart from Elm, not gaps waiting for a slice. Examples: a structural write to a `List` of rows, an opaque `update`, a markup site that cannot be numbered. Their text never says "not yet".

*Amended 2026-10-21 (the owner):* the former exact whole-model class 3 refusal is reversed.
A `.whole_record` key is accepted as value writes of every known model field, selected through
the existing group conflicts. Other keys remain narrow. A `.precision` key stays class 4; no
whole-page fallback, warning or new replacement syntax is introduced.

## 10. How this plan is tracked

The parent issue holds the slices as sub-issues (S0–S6) and the parallel core work (#294 and the
issues §6 names). Each slice's issue carries its golden, its scenario, its bar and its measured
result when it lands; a slice that misses its bar stops and reports which mechanism did not
deliver (rule 10), as the first platform's slices did. Every session appends to
`plans/diary.md`.
