# Compiling the framework away — the plan

*2026-10-08. The order of work toward the owner's goal: **vanilla JavaScript is the floor, and
beni's output should come as close to it as it can, in speed and in bytes**. Sources: research 58
(the design and the criteria), 59 (where the time and bytes go today), 60 (the design written by
hand and measured), 61 (how often a message's writes are known). This is a plan, not a contract:
every slice is specified in `docs/design/` before it is built (rule 1), and the plan follows the
slices' measurements.*

## 1. The bar: research 58's criteria, kept as written

**The owner, 2026-10-08:** keep the criteria. They judge the whole output, model included, and
are not restated after research 60 missed them.

| criterion (research 58 §9) | beni today | P3 by hand (research 60) |
|---|--:|--:|
| flat sweeps ≤ **1.15×** vanilla, untraced: holes 10 / holes 10 000 / live rows 10 000 / depth 128 | 1.64 / 1.67 / 46.5 / 2.57 | 1.18 / 1.04 / 1.25 / 1.29 |
| list sweeps ≤ **1.3×**: rows 30 000 one-row edit / swap | 5.63 / 8.36 | 1.31 / 0.98 |
| table app bundle ≤ **2×** vanilla (≤ 2 830 B) | 5 510 B (3.89×) | 3 454 B (2.44×) |
| every table operation ≤ **1.2×** vanilla (a goal in §9, not a kill criterion) | 7 of 9 | 8 of 9 (swap 4.2×) |

*Untraced is research 60's real-click mode. Ratios come from that report's batch.*

**Every slice reports this table**, measured traced and untraced against vanilla, P2, P3 and
Solid 1, with bytes (`scaling-sizes.mjs`, `sizes.mjs`), on the same machine in one batch. A
slice's result is the change in these numbers. A slice that moves none of them needs a reason
to exist.

## 2. Rules every slice keeps

- **Analysis says "possibly changed"; a comparison says "changed"** (research 58 §3.3). Analysis
  never decides by itself that something is unchanged. A missed write is a wrong page, which beni
  cannot have.
- **An unknown write set is a cost, never an error** (rule 7). No slice restricts what `update` may
  call or how it is written. A message whose writes cannot be bounded runs today's path.
- **The guarantees stay:** controlled inputs show the model, a defect stops the page, no broad
  `catch` (rule 9), and one render per turn (bursts).
- **Differential testing.** Every specialised path is checked against the general one on every
  `browser/` corpus page, step by step, before it merges.
- **Red first, no bending** (rules 3 and 10). Every slice has fixtures that fail first. A slice
  that hits a wall stops and reports it; it does not change the design or the bar.

## 3. The work, in order

Each item: what it is, its source, what it should move, and what it needs.

### Track R — the renderer and its runtime

**R1. The per-message plumbing** (research 59 §1.6). These are runtime and emitter changes, and
no guarantee changes. They should take beni from 19.4 to about 12.6 µs per real click, against
P2's 11.7.
- Build `$$click`/`$$clickF`/`$$clickX` once per registered event type instead of per event
  (1.9 µs).
- One walk that finds both the handlers and the mount, which keeps bubbling to ancestors'
  handlers (1.2 µs). The spec must state the bubbling semantics.
- One pending-render slot per mount on a trusted turn, keeping one render per turn (1.4 µs).
- A root whose kind never changes is patched with the model directly, with no `{t, v}` pair
  (1.3 µs).
- `$$cx` only under `Html.map` (0.6 µs); `turn` inline (0.4 µs).

**R2. Controlled inputs by an edited-inputs set** (research 58 §5(c); research 60 §5.2). The
delegated input listener marks the input it handled. After the render, only marked inputs are
reconciled with the model. A form `reset` marks the form's inputs. This changes `backend.md`
§15.3's contract, so it is specified first. It should take live rows 10 000 from 46.5× to P2's
level. Fixtures: typed and rejected, typed and accepted, autofill, reset, a row removed while
marked. This replaces the handover's "live rows, next slice".

**R3. Values that never change** (research 58 §4 W2). A hole whose paths no `update` branch
writes is written at mount only, with no group and no comparison. If `init` gives it a literal,
it is part of the template's HTML. Research 60: holes 10 000 goes from 61 905 B to 442 B.
Research 61: 27% of holes overall, none in TodoMVC, 13 of 16 in the table app. Specified in
`backend.md` §15.4. Needs the whole-program write summary that R4 also uses, so build that once.

**R4. Per-message write sets and handlers** (research 58 §4 W1/W3, §9). For each `Msg`
constructor, emit a handler that:
- runs that `update` branch;
- marks only the groups whose read paths meet the constructor's write set;
- leaves the flush to run the marked groups once, keeping comparisons and staging.

A constructor whose write set is unbounded marks everything, which is today's path. Groups are
emitted once and called; one is inlined only when it has a single caller. The specifics:
- **Keep beni's selector:** dropping it made `select` 45% slower (research 60 §5.5).
- **Add guard-aware writes** (`if i == k`, `if mod i 10 == 0` inside `indexedMap`), which
  research 60 §5.4 found the table app needs.
- **`Debug.log` order** follows `language.md` §11.11.
- **Before the spec, run V1** (§4).

**R5. List edits read off `update`**, in research 61's order, the most common first:
1. **Append and clear** (57 append writes in the corpus).
2. **`List.map` that keeps unchanged parts of the trie**, plus slice C's diff under option 2
   (research 56 §9.7). This reaches the `List.map (λr → if r.id == id …)` idiom that is half of
   real apps' messages (research 61). The parked branch `r56-slice-C-over-budget` is reference
   only.
3. **`filter` that removes by key**: a pattern to recognise, not a general mechanism.
4. **`List.update k`, `set`, `swap`, `removeAt`**: no current use in the repository, so last.

**R6. One keyed pass** (research 59 §4). Keyed `For` is 1 478 B of the table app because beni
ships two keyed passes where Solid ships one. Measure whether `Rt.trimmed`'s prefix/suffix/swap
pass still earns its bytes once R5 gives list edits their own path. The owner kept it for speed
on 2026-10-04, so a removal goes back to the owner with numbers.

### Track M — the model half (the wall research 60 found)

**M1. Depth: no per-level functions** (research 59 §3; research 60 §4.3). Two changes:
- the emitter calls each level's patch directly, instead of through `Rt$patch`'s dispatch to a
  different function at each level (about half of depth 128's cost);
- nested record updates do not emit one function per level (one recursive function recovered a
  third of P3's gap).

**M2. `List` when it runs cold** (research 60 §5.1, §6(a)). A single `List.update` on a
30 000-element trie costs 0.03 ms in the page and 0.25 µs hot, because model code runs once per
message and never gets optimised. Measure core's cold paths in the page, not in a loop. Find what
makes the trie path copy expensive when cold. Also measure the trie's share of the table app's
bytes: research 59 counts 526 B, pulled in by prepending rows. Rule 10 applies here: `List`'s
design (one array-backed sequence) is the owner's decision. A finding against it is reported,
not acted on.

**M3. Updating the top-level model in place** (research 58 §4 W4, §5(b); research 55). Once R4
leaves the renderer no reason to keep the old model, a `Model` that is provably held only by the
runtime can be updated in place. This removes the copies behind depth and, past V8's 1 020-field
limit (research 59 §2), the dictionary-mode cliff. Specified after R4 lands; inner types later.

**M4. Wide models.** Below V8's limit, beni's growth with width is the root patch comparing every
field (research 59 §2). R4 removes those comparisons. Past 1 020 fields, V8 itself is the cliff
and nothing is planned for it (research 58 §2.4).

### Track B — bytes outside the renderer

**B1.** Re-measure the table app part by part after R1, R5 and R6 (research 59 §4's method). The
remaining distance to ≤ 2 830 B is expected to be core's `List` (research 60 §4.6: ~1.2 kB) and
R6's keyed pass. What to do about core's `List` is decided from that measurement, under M2's
rule 10 caveat.

## 4. Validation that gates the analysis work

**V1. A realistic application before R4 and R5 are specified** (research 61 §7). 65 of the 71
programs research 61 counted are our own fixtures, and none contains the idioms that make a write
set unbounded (restoring the model from a decoder, undo history, recursion over the model). The
RealWorld app (Conduit) already planned in the handover is the candidate. Re-run
`bench/writesets/classify.mjs` on it. The bar is research 58's: if fewer than about two thirds of
its constructors have bounded write sets, R4 and R5 shrink to R2, R3 and R5's append/clear.

**V2.** Every slice's measurement follows §1 and research 60's protocol: real-click untraced plus
traced, load recorded, one batch per comparison, pages rebuilt by the compiler under test
(`scaling.mjs` stamps each page with the beni that built it).

## 5. Order, and what can run in parallel

1. **Now, in parallel:** R1 and R2 (both runtime, different code), and V1 (build Conduit).
2. **Then:** R3, with the write summary it shares with R4; M1.
3. **Then, after V1's verdict:** R4, then R5 in the order above.
4. **Alongside R4/R5:** M2's measurement.
5. **Then:** M3, R6, B1.

At most three agents at a time; only one browser batch at a time (a lock file, as on 2026-10-08).

## 6. Decisions still the owner's

- R2's change to `backend.md` §15.3: how a controlled input's guarantee is kept.
- R6: removing `Rt.trimmed`, if the measurements say so.
- Anything M2 finds against `List`'s representation.
- Restating any criterion in §1. Not to be proposed again without new evidence.
