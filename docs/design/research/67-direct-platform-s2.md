# 67 — The direct platform, slice S2: rows, and kill criterion 4

*2026-10-09. What `browser-direct.md` §14's slice S2 built and what it measured against §13's
kill criterion 4. S2 is `For`, keyed and positional; row templates and instances; static-key
holes; the exact edit scripts under their tags' guards; the delegated listener per list with
buffered walks; direct listeners for events that do not bubble; native `stopPropagation` and
`preventDefault`; and K3, a constant list baked into the HTML. The specification is
`browser-direct.md`'s *Amended 2026-10-09 (slice S2, as specified)* and *(as built)*, the
interface `boundary.md` §9.4.6 version 1.8, and the bound reads `write-sets.md`'s amendment
*which `[*]` is a row's own*. All figures are **[measured]** by the commands in §8.*

---

## 0. The answer in six sentences

1. **Kill criterion 4 fires, on the swap.** The 30 000-row edit holds: **0.088 ms against
   vanilla's 0.070, 1.26×** (bar 1.3×), untraced. The 30 000-row swap does not: **0.127 against
   0.113, 1.12×** (bar 1.0×), and at 10, 1 000 and 10 000 rows 1.13×, 1.08× and 1.15×.
2. **The swap's gap is not the script.** P3, research 60's hand-written page with the same edit
   in the DOM, measures the same **0.127 ms (1.12×)** in the same batch. The handler is two
   `insertBefore`s and two array writes, as vanilla's; what vanilla does not do is the model:
   `List.swap` is two `List.set`s, and at 30 000 rows a path copy of a trie each, where vanilla
   swaps two slots of its array. That is §7's model half (S7's in-place update; B1), not S2's.
   Reported under rule 10, nothing tuned.
3. **No reconciler ships**: S2 has none, and the rows page's bundle is 1 863 B brotli (P3 1 643,
   vanilla 415, `browser-tea` 3 832) with the trie's write half in it (the edit's `List.update`
   past 256 elements). The bundle half of the criterion holds.
4. **The delegated listener and expandos are kept, by measurement.** A listener per row mounts
   9–11 % slower at 1 000, 10 000 and 30 000 rows; no other general form of finding a row's
   instance mounts measurably faster, and the index lookup's row event grows with the list
   (0.74 ms against 0.26 at 30 000).
5. **K3 bakes a constant list's rows into the template**: on `BakedList`'s three-row menu the
   release bundle is 1 930 B brotli against 1 972 for the same menu made at mount, and no row is
   made when the page loads.
6. **Two oracles found three things on the new pages**: a row whose item no hole shows kept a
   stale item (verify mode; fixed: every element write visits its row), two adjacent rows
   swapped by moving both lost a focus the reconciler keeps (sweep fuzz; fixed), and — open —
   **S2's scripts are not rank-correct where a key repeats** (sweep fuzz; §5).

## 1. What was built

- **The pass** (`src/writes/Writes.zig`): a `For` row's item is a root of its own, anchored to
  the list's `[*]` as before, so every read set and dump line is unchanged; each hole's reads
  carry a **bound depth** (how many enclosing rows a read came through the item root of), its
  innermost `For`, its row path (for K3) and, for an `each` hole, the key path and `init`'s rows.
- **The compiler** (`src/js/Emit.zig`'s `DirectLists`, `src/js/Lower.zig`): per `For` and per
  key, the **edits** — the list's shape (its tag and index symbols) and row visits (the rows at
  one index, or every row; the row groups to call there; whether the key may change) — under the
  enclosing `For`s' rows they are in; index symbols as recipes the handler evaluates before the
  arm; `rowValuesOf`; K3's per-row texts. Interface version 1.8.
- **The lowering** (`platforms/browser-direct/zig/direct.zig`): sites (the view's root, each
  `For` row), a descriptor per list `{ p, n, r, m, o, k, u }`, `make(it, L, j)` building an
  instance `{ e, it, l, u, i, …nodes, …slots, …lists }`, a function per row group, the scripts,
  the index and every-row visits, nested lists, the delegated listener and own listeners, the
  verify mode's list check, and refusals naming S3 and S4.
- **The runtime** (`Direct.beni`): `mount`, `adopt`, `append`, `prepend`, `clear`, `insert`,
  `removeAt`, `swap`, `row`, `rekey`, `each`, `positional`, `delegate`, `listen`, `verifyList`.
  Every loop is here: the builder has none.
- **`dom`** (`platforms/browser/zig/dom.zig`): three hooks `browser` leaves unset — `bake_list`,
  `row`, `close_all` — and the bake callbacks take the planner. `browser`'s and `browser-tea`'s
  output is byte-identical: the whole `browser/` and `emit/dom` corpus built by the base and by
  this branch, development and release, diffs empty.
- **Fixtures**:
  - rebuilt on `browser-direct` from `browser/dom`, each naming what moved to S3 or S4:
    `Keyed`, `KeyedInPlace`, `RowItemOnly`, `RowMountOrder` (`.tea-expected`: a value runs only
    where its reads were written, §4.1), `ForAtEnds`; and `ForForms`, owed since `backend.md`
    §15.5, written here;
  - new: `NestedFor`, `StopInRow` (a vocabulary of its own on both platforms: a
    `platform-tea/` beside `platform/`), `RowBlur`, `DetachedRowEvent`, `NoOpEdits`,
    `RowReadsList` (bound reads), `BakedList` (K3), `DuplicateKeys` (the open defect, §5);
  - `emit/direct/ListScripts` and `emit/release/direct/ListScripts` (every script's shape),
    `emit/direct/BakedList`;
  - `build/bad/direct/ForReconciler`, `ForMap`, `ForRowBranch`.
- **The fuzzer**: bursts — a message or a click sent 33 to 40 times, each its own task — from a
  second stream of the seed, so a page's pushes cross the trie's threshold.

## 2. Kill criterion 4

| part | bar | measured, untraced, release | verdict |
|---|---|---|---|
| the 30 000-row edit | ≤ 1.3× vanilla | **0.088 / 0.070 ms = 1.26×** (P3 0.095 = 1.36×) | **holds** |
| the 30 000-row swap | ≤ 1.0× vanilla | **0.127 / 0.113 ms = 1.12×** (P3 0.127 = 1.12×) | **fires** |
| the reconciler | only where a list needs it | none in any bundle: S2 builds none | **holds** |

The swap at every point, untraced (median ms [quartiles], 24 samples):

| N | beni-direct-release | P3 | vanilla | × vanilla |
|--:|--:|--:|--:|--:|
| 10 | 0.102 [0.090–0.110] | 0.100 [0.095–0.108] | 0.090 [0.085–0.095] | 1.13 |
| 1 000 | 0.108 [0.095–0.120] | 0.110 [0.100–0.120] | 0.100 [0.090–0.110] | 1.08 |
| 10 000 | 0.115 [0.110–0.123] | 0.115 [0.110–0.121] | 0.100 [0.095–0.110] | 1.15 |
| 30 000 | 0.127 [0.120–0.135] | 0.127 [0.125–0.135] | 0.113 [0.110–0.120] | 1.12 |

The generated page equals P3 at every point. Research 60 measured P3's swap at 0.98× on another
day; in this batch the hand-written page is 1.08–1.15×, and the generated one with it. The
remainder is what both do and vanilla does not: the immutable model's `List.swap` (two `set`s;
past 256 elements, a trie path copy each) and the spread of the model record. §13 left the
rows edit's model cost to S7 (in-place, a container-owned plain list) and did not for the swap;
the swap's bar assumed P3's 0.98. The finding is the owner's (rule 10).

## 3. Listener placement and how a row is found (§4.2, §6.1)

`bench/ui/rowstate.mjs`: one rows page, five forms differing only in the mechanism, ten pages
each, untraced real clicks; bytes are the mechanism's code minified, brotli 11.

| rows | form | mount ms, median [q1–q3] | × expando | row event ms | bytes |
|--:|---|--:|--:|--:|--:|
| 1 000 | expando (shipped) | 5.26 [5.17–5.82] | 1.00 | 0.165 | 280 |
| 1 000 | listener per row | 5.86 [5.78–6.26] | 1.11 | 0.097 | 139 |
| 1 000 | index | 5.12 [5.08–5.34] | 0.97 | 0.210 | 264 |
| 1 000 | key map | 5.23 [5.17–5.53] | 0.99 | 0.153 | 271 |
| 1 000 | `WeakMap` | 5.45 [5.37–6.11] | 1.03 | 0.165 | 279 |
| 10 000 | expando | 47.5 [46.5–48.2] | 1.00 | 0.240 | |
| 10 000 | listener per row | 51.6 [51.2–52.7] | 1.09 | 0.158 | |
| 10 000 | index | 46.1 [45.5–47.6] | 0.97 | 0.398 | |
| 10 000 | key map | 48.8 [47.6–49.5] | 1.03 | 0.220 | |
| 10 000 | `WeakMap` | 47.9 [47.5–48.8] | 1.01 | 0.235 | |
| 30 000 | expando | 131.7 [131.1–132.3] | 1.00 | 0.260 | |
| 30 000 | listener per row | 144.9 [143.9–147.7] | 1.10 | 0.180 | |
| 30 000 | index | 130.2 [127.2–131.2] | 0.99 | 0.735 | |
| 30 000 | key map | 130.0 [129.0–132.1] | 0.99 | 0.235 | |
| 30 000 | `WeakMap` | 141.5 [140.3–142.7] | 1.07 | 0.248 | |

- **Listener placement**: a listener per row is 9–11 % slower to mount, so by §4.2's rule the
  delegated listener stays. Its row event is faster (no walk), by 0.07–0.08 ms.
- **Instance lookup**: the index form's 1–3 % lead is inside its quartiles, and its event is
  O(n) (`indexOf` among the children); the key map reads the key from the page, which a row
  need not show; the `WeakMap` is 7 % slower at 30 000. Expandos ship.

## 4. Every benchmark (V2)

Subjects: `beni`, `beni-release` (today's `browser-tea`), `beni-direct` (development, with its
verify mode), `beni-direct-release`, P3, Solid 1, vanilla. Chrome 153 headless, `--taskset=8-15`,
unthrottled. The rows sweep is `--full` at 10, 1 000, 10 000 and 30 000 (2 pages × 4 samples);
the other sweeps quick (1 page × 3 samples); the table app `bench.mjs`, n = 5, 4× throttled. The
JSON is `bench/ui/results/2026-10-09-s2-*.json`.

**Skipped by `browser-direct`, with the compiler's reason:**

| page | reason | slice |
|---|---|---|
| depth | markup as a value: its `view1 … viewD` helpers | S3 (helpers), §14 schedules the sweep at S4 |
| derived | a `view` whose body computes its markup (a `let`) | S4 (§5.4) |
| live | markup as a value (each row's helper) and controlled inputs | S4 |
| helper rows, helper tree | markup as a value | S3 (helpers), S4 (the recursive helper) |
| the table app | markup as a value: its `button` helper | S3 |

**Rows, change (the middle row's label), untraced:**

| N | beni | beni-release | beni-direct | beni-direct-release | Solid 1 | P3 | vanilla |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 10 | 0.087 | 0.093 | 0.085 | 0.065 | 0.095 | 0.065 | 0.060 |
| 1 000 | 0.107 | 0.110 | 0.532 | 0.070 | 0.100 | 0.075 | 0.060 |
| 10 000 | 0.195 | 0.208 | 5.35 | 0.080 | 0.107 | 0.085 | 0.065 |
| 30 000 | 0.392 | 0.415 | 15.6 | 0.088 | 0.120 | 0.095 | 0.070 |

**Rows, swap, untraced:**

| N | beni | beni-release | beni-direct | beni-direct-release | Solid 1 | P3 | vanilla |
|--:|--:|--:|--:|--:|--:|--:|--:|
| 10 | 0.130 | 0.120 | 0.115 | 0.102 | 0.140 | 0.100 | 0.090 |
| 1 000 | 0.170 | 0.160 | 0.563 | 0.108 | 0.400 | 0.110 | 0.100 |
| 10 000 | 0.390 | 0.313 | 5.60 | 0.115 | 2.24 | 0.115 | 0.100 |
| 30 000 | 0.815 | 0.680 | 16.0 | 0.127 | 5.34 | 0.127 | 0.113 |

Traced, the same order: change at 30 000 is 0.425 / 0.421 / 15.6 / **0.084** / 0.113 / 0.093 /
0.064 (1.31×), swap 0.833 / 0.675 / 16.0 / **0.125** / 5.30 / 0.123 / 0.099 (1.26×). The
development build's 15.6 ms is the verify mode's list check, O(rows) per dispatch.

**The sweeps S1 built, re-run** (untraced, release ÷ vanilla, informational): holes 10 / 1 000
/ 10 000 at 1.18 / 1.08 / 1.07; width 8 / 20 / 256 at 1.00 / 1.08 / 1.00; burst 1 / 30 / 1 000
at 1.07 / 1.08 / 1.03. S2 moved none of them.

**The table app** (script ms, today's subjects; `beni-direct` skipped):

| subject | run1k | replace1k | update10th | select | swap | remove | create10k | append | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| beni | 4.57 | 10.1 | 1.07 | 0.78 | 0.95 | 0.47 | 49.5 | 5.57 | 22.5 |
| beni-release | 4.60 | 10.4 | 1.40 | 0.87 | 0.92 | 0.36 | 49.2 | 5.03 | 21.2 |
| P3 | 4.59 | 9.95 | 0.48 | 1.22 | 0.70 | 0.30 | 49.0 | 4.56 | 21.3 |
| vanilla | 4.54 | 9.63 | 0.85 | 1.31 | 0.12 | 0.54 | 47.1 | 4.82 | 21.2 |
| Solid 1 | 4.91 | 11.6 | 1.87 | 1.58 | 1.54 | 0.56 | 55.6 | 5.15 | 22.7 |

**Bytes** (minified, brotli 11 / gzip -9, `scaling-sizes.mjs`), rows:

| N | beni `--release` | beni-direct `--release` | Solid 1 | vanilla | P3 |
|--:|--:|--:|--:|--:|--:|
| 10 | 3 819 / 4 190 | 1 842 / 2 032 | 3 565 / 3 935 | 408 / 524 | 1 637 / 1 800 |
| 1 000 | 3 831 / 4 198 | 1 855 / 2 042 | 3 572 / 3 941 | 415 / 532 | 1 644 / 1 807 |
| 30 000 | 3 832 / 4 202 | 1 863 / 2 046 | 3 576 / 3 947 | 415 / 535 | 1 643 / 1 811 |

§13 estimated ~1.5 kB for this page; it is 1 863, 220 B over P3. The trie's write half is in it
— the edit's `List.update` past 256 elements births a trie (§7.2) — and the delegated walk and
the list functions the page reaches (`mount`, `row`, `swap`). The bundle does not grow with N.

## 5. The open defect: duplicate keys

`language.md` §11.9 matches rows that share a key by their rank among those rows. S2's scripts
edit the row at the index the write set names, which is the same thing only when the key is
unique. With a repeated key, `removeAt`, `insert`, `prepend`, `swap` and a key change put a
row's node — its focus, an uncontrolled input's text — on another item than `browser-tea`
does; the text, the holes and the items are the same on both. The sweep found it on
`KeyedInPlace` (forty duplicate rows appended, text typed into one, a removal), and
`browser/direct/DuplicateKeys` pins the difference with a `.tea-expected`. The fix is S3's: a
keyed script hands its edit to §6.3's reconciler when the key it touches is not unique, which
needs a count per key kept by `make` and the removals. S2 did not build it: the reconciler is
S3's, and nothing short of it moves the nodes as the reconcile does.

## 6. The oracles

- **The verify mode** checks every list after every dispatch (length, each row's item, the rows'
  order in the page, each row's holes and lists). It found a stale item: `KeyedInPlace`'s second
  list has no hole that reads `done`, so its rows were not visited when `done` was written, and
  a listener body reading the item would have sent the old one. Every element write now visits
  its row. A deliberately broken visit (row groups never called at an index) was caught at the
  first click; with every `[*]` taken for the row's own, `RowReadsList` was caught at the first
  click (§1's bound reads).
- **The fuzz**: the gates fuzz every new page, events in the gates and values in `zig build
  fuzz` for the pages over budget (§7). `zig build fuzz -Dcorpus=browser/direct/` (fifty seeds
  of sixty steps) passes on every page but `KeyedInPlace`, the duplicate keys of §5. Before the
  bursts were made one task each, they also reported differences that are §4.3's (Q2): a
  thirty-eight-click burst in one task is one render on `browser-tea` and thirty-eight writes
  here, and a `class` toggled on and off leaves `class=""` (`Holes`), a removed button stops
  receiving clicks (`DetachedRowEvent`). A user's clicks are tasks; the bursts now are.

## 7. Budgets

Every new page fits the 4.3-billion-instruction budget on a fresh run with event fuzzing, and
none with value fuzzing: by the owner's rule they are in `value_fuzz_in_sweep` with their
counts (4.5–5.7 billion). So are three S1 pages, `DefectInHandler`, `DefectInListener` and
`DefectInMount` (4.31–4.41 billion): each of a page's seven builds checks the runtime module
`Direct`, which S2's list functions grew. No budget was raised.

## 8. Commands

- `node bench/ui/rowstate.mjs --taskset=8-15 --pages=10`
- `node scaling.mjs --full [--untraced] --sweeps=rows --points=rows=10/1000/10000/30000
  --subjects=beni,beni-release,beni-direct,beni-direct-release,p3,vanillajs,solid1
  --taskset=8-15`
- `node scaling.mjs [--untraced] --sweeps=holes,width,burst[,stream]` and
  `--sweeps=depth,derived,live,helperRows,tree`, same subjects
- `node bench.mjs --subjects=… --n=5 --taskset=8-15`
- `node scaling.mjs --build-only --full --subjects=beni,beni-release,beni-direct-release,solid1,vanillajs`,
  then `node scaling-sizes.mjs`
- `zig build fuzz -Dcorpus=browser/direct/`
- each batch from `env -u LD_LIBRARY_PATH nix develop .#browser`, under the bench lock
