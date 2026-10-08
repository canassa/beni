# 60 — Message-indexed rendering, written by hand: the spike research 58 asked for

*2026-10-08. A hand-written spike. Nothing in the compiler, `core/` or the platforms changed. P3
is the JavaScript that research 58 §9's architecture, message-indexed rendering, would emit for
five beni programs. It uses only facts research 58 §4 says a whole-program compiler can prove from
the beni source. It was measured beside beni (merged `master`), P2, vanilla JS and Solid 1, traced
and untraced, with bytes, and then judged against research 58's kill criteria.*

## 0. The verdict

| kill criterion (research 58 §9) | result | verdict |
|---|---|---|
| flat sweeps within **1.15×** vanilla, untraced | holes 10: 1.18, holes 10 000: 1.04, live 10 000: 1.25, depth 128: 1.29 | **missed** on three of four |
| list sweeps within **1.3×** vanilla, untraced | rows 30 000 one-row edit: 1.31, swap: 0.98 | **missed** by 0.01 on the edit; met on the swap |
| table app bytes ≤ **2×** vanilla (2 830 B) | **3 454 B** (2.44×) | **missed** |

Read literally, the architecture fails all three criteria. Read for *where* the time and the bytes
go, it does what research 58 said it would. Every miss is outside the renderer:

- **The rows edit** is 1.31× because of core's `List.update` on a 30 000-element trie. Run once per
  message, it is cold code, and it costs about 0.03 ms. Remove that one call and the same page is
  at **1.16×** (0.072 against 0.062 traced, §4.3).
- **Depth 128** pays for beni's model half: 128 distinct `bumpK` functions, each a spread. Folding
  them into one recursive function, as P2's is, removes 0.011 of the 0.031 ms gap (§4.3). In-place
  update (W4) would remove the rest.
- **Holes 10 and live 10 000** sit at P2's level: 0.065 against P2's 0.065 and 0.068. That is the
  cost of an immutable model and one compare a group. Research 58 §1(iii) put it at 0.005–0.007 ms.
  Here it is one or two ticks of the 5 µs clock.
- **The table app's bytes** are 3 454. P3's own module is **2 243** with core imported, which is
  under the bound. The other ~1.2 kB is core's `List` that this program reaches: the trie behind
  `[ x, …rows ]`, `++`, `indexedMap`, `filter` and `get`. beni ships the same code today (5 510 B).
  The criterion as written cannot be met by any renderer while the table app's model uses those
  list operations.

So the renderer comes within about 1.2× of vanilla on every page, and its curves are flat where
vanilla's are flat. What keeps beni off the criteria is now the model half: the representation of
`List`, the shape of nested updates, and code that runs once per message and so never gets
optimised. Research 58's slice 5 (in-place update) and the release optimiser address those; a
renderer change cannot. §6 sets out what this means for the plan.

Headline numbers, untraced, P3 against today's beni:

| page | P3 | beni | vanilla |
|---|--:|--:|--:|
| rows 30 000, one-row edit | 0.105 ms | 0.450 | 0.080 |
| rows 30 000, swap | 0.137 ms | 1.17 | 0.140 |
| live 10 000 | 0.075 ms | 2.79 | 0.060 |
| holes 10 000 | 0.070 ms | 0.112 | 0.067 |

P3's holes 10 000 page is 442 B where beni's is 61 905 B. On the table P3 is within 1.05× of
vanilla on eight of nine operations; the ninth, swap, is the map idiom (§3.5).

---

## 1. Method

- **Subjects:** `p3` (this spike), `beni` (development build from `zig-out/fast/bin/beni`, ReleaseFast,
  current `master`), `p2`, `vanillajs`, `solid1`. All were built in the worktree. Solid 1's sweep
  bundles were copied from the main checkout after checking that their generated sources were
  byte-identical (`apps/solid1/gen/*.jsx`).
- **Pages:** holes N = 10 and 10 000; the burst sweep K = 1, 3, 10, 30, 100, 300, 1 000 on the
  1 000-hole page; rows N = 30 000, `change` and `swap`; live rows N = 10 000; depth D = 128; and
  the table app's nine operations.
- **Traced:** `scaling.mjs --full` (2 pages × 4 samples, a real click, script ms from a Chrome
  trace) and `bench.mjs --n=10` (official throttling).
- **Untraced (new, `scaling.mjs --untraced`):** the same real click, timed in the page instead of
  from a trace. The clock starts in a capture-phase `click` listener on `window`, which runs before
  any of the page's listeners. It stops in a microtask queued by a bubble-phase listener on
  `window`, which runs after every page listener and after every microtask those listeners queued.
  Clicks nested inside the real one (the burst button's synthetic clicks) fall inside the interval.
  Style, layout and paint do not. It takes 2 pages × 12 samples.
  - The interval includes the browser's own click dispatch, about 0.05 ms, so it is research 56
    §2.4's kind of number (vanilla 0.085 there).
  - `performance.now()` has 5 µs resolution here, so ratios at 0.06 ms move in steps of about 8%.
  - The older loop, research 56's synthetic clicks, is kept as `--untraced=synthetic`. It is not
    the primary number because it measures the burst path (§5).
- **Bytes:** `scaling-sizes.mjs` and `sizes.mjs`. Each subject is minified with terser, then
  compressed with brotli 11. P3 imports core's modules from the development build. For its bytes
  it is scope-hoisted into one module first (`lib/imports.mjs`'s `hoisted`), the shape beni's
  `--release` ships, so terser also drops the core functions nothing calls.
- **Correctness:** two checks.
  - `p3-verify.mjs`, new, is a differential check. Each P3 page and its beni page are driven
    through the same steps, and after every step the two DOMs must be equal: every element,
    attribute and text, and every input's `.value`. Comments are skipped (beni's slot markers), and
    an empty `class` equals none. The steps are real clicks, bursts of synthetic clicks, and typing
    into inputs. The table case has 19 steps: run, select, swap twice, update, two removes, append,
    select, a burst of swaps, a burst of updates, replace, clear twice, 10 000 rows, select, swap,
    append, replace.
  - `verify.mjs` with `--subjects=p3`.
  - All cases pass, as do the sweeps' own `done` checks on every sample.
- **Machine and load:** Ryzen 9 5950X, Chrome 153.0.8010.36, pinned with `--taskset=8-15`, under the
  shared lock. Before each batch the machine was allowed to fall below a 1-minute load of 4.
  Another user's jobs had pushed it to 30–50 earlier. Two batches whose load rose during the run
  were taken again: the traced lists batch, which reached 23, and the untraced flat batch.
  - Load across the kept batches: 1.1–4.8 for the sweeps and 0.8–6.2 for the table. The worst was
    6.19, at the start of `select`.
  - Runs: 14:04–14:41 UTC; the ablations at 14:41–14:44.
- **Results:** `bench/ui/results/2026-10-08-p3-{traced,untraced}-{flat,lists,burst-a,burst-b}.json`,
  `-table.json`, `-sizes.json`, `-rows-ablations.json` and `-depth-ablations.json`. `node
  report-p3.mjs` prints §4's tables.

## 2. What P3 is, and the decisions research 58 left open

P3's **model half is beni's own output, verbatim**. The `init` literals, every `update` branch, and
helpers like `buildFrom`, `swapRows` and `bumpK` are copied from the development build. Core's
`List` is imported from that build (`out/.../beni-dev/_core/List.mjs`), so lists are the same array
or trie, and every edit costs what it costs in beni. **The view half is what changes**:

1. **One handler per `Msg` constructor.** The handler runs the constructor's `update` branch. It
   then applies the list edit the branch implies and marks the groups its write set can reach (W1,
   W3). No message object is built, and nothing in `update` dispatches on a constructor.
2. **Groups are the unit of code, compares the unit of safety.** The flush at the end of the
   dispatch runs the marked groups. Each group compares what it reads with the slot holding what it
   last wrote, and writes only on a difference. A group with one caller is inlined into the flush;
   a shared expression stays a function (`rowClass`, used by mount and by the class group).
3. **Constancy (W2).** A hole whose path no branch writes is written once, at mount. If `init` also
   gives it a literal, the hole is template text. A written hole whose `init` value is a literal
   has that value in the template and in its slot, so the mount writes nothing.
4. **Staging and bursts.** A trusted event's handler runs inside a turn, and the flush follows when
   it returns. Any other message queues one microtask, so K synthetic clicks render once. This is
   beni's rule since research 56's A, unchanged.
5. **Guarantees.** A handler or a flush that throws sets `dead`, and nothing more runs. There is no
   `catch` anywhere: `try`/`finally` with an `ok` flag, as beni's release runtime does it, and the
   exception reaches the console. Controlled inputs always show the model (§3.3).

Where research 58 is silent, P3 chose as follows:

| question | choice | why |
|---|---|---|
| **Event delivery** | A direct `addEventListener` on every handler node outside a list, and one delegated listener on the list's parent element (the `<tbody>`) for nodes inside rows. The walk stops at the parent, or where a handler detached the row. | A node outside any list is mounted once and never moved, which a compiler knows from the template. A listener on it removes beni's walk from the target to `document`, the `${key}X`/`${key}F` lookups and the `$$cx` chain, which research 58 §1 row 1 calls an artefact. Inside rows, a listener per row would cost one `addEventListener` per row created. Research 58 §4 keeps "delegation inside rows" in the irreducible runtime, and vanilla's table delegates on the `<tbody>` too. |
| **Where list edits happen** | In the handler, at once (DOM moves, inserts, removals, the instance array). Group runs wait for the flush. | Research 58 §9: "apply its list edit script to the affected `For` instances; mark the groups … the flush … runs marked groups". The burst win comes from not re-running groups, and a structural edit cannot be merged across messages anyway. |
| **Marks on rows** | A flag and a queue per **instance**, not per index. | A later message in the same burst can move the row. |
| **What a row's handler sends** | Read from the instance when the event fires (`i.it.id`). | The payload `row.id` is the key, fixed for an instance. Nothing is allocated per row, where beni allocates one message object per handler. |
| **Exact edits against idioms** | Exact edits (`List.update k`, `List.swap i j`, `xs ++ fresh`, `[]`) become instance operations. A `List.map`/`indexedMap`/`filter` idiom, or a list not derived from the old one, goes through one keyed `reconcile`: trim the same keys at both ends (marking items that changed), make the two moves of crossed ends, then match the middle by key. | Research 58 §5(a): the map idiom is "a walk comparing each element with its instance's item", and the filter is a one-pass merge. The trimming does both, in one function the page needs anyway for `Run` (§3.5). |
| **Duplicate keys** | `reconcile` keeps the first old instance for a key and makes new ones for later duplicates. | This is keyed-correct, but beni chains duplicates. No page here has duplicates. |
| **`Select`** | No selector analysis. The class group runs over every row instance. | W3(Select) = every row's class group; that is the architecture as specified. beni today also proves `model.selected == Just row.id` is a selector and visits two rows. §3.5 measures what dropping that costs. |
| **W4 (in-place model)** | Not used. Every message spreads the model, and depth copies its path. | It is research 58's last slice and depends on the earlier ones. The kill criteria should hold without it. |
| **Template use** | The root template is parsed once and adopted (it has one use); row templates are cloned. | Inline on single use (§7). |
| **Development or release** | One P3 page, with release behaviour on a defect (stop, log). | Research 58 §9: both builds emit the same handlers. The crash screen is the same code in both. |

## 3. Per page: what was emitted, and the fact behind it

### 3.1 Holes (`apps/scaling/holes.mjs`, `p3`)

`name`, `count` and `cls` are written by no branch and are literals in `init` (W2). Their N − 1
holes are template text, byte for byte what vanilla's page holds. `tick` is written by `Go`: W1(Go) =
{tick}, and W3(Go) = the one group. The page reduces to `Go = () => { model = { ...model, tick:
model.tick + 1 }; mark(1) }` and a flush that compares `model.tick` with its slot and writes the
text node. The burst sweep uses the 1 000-hole page as it is.

### 3.2 Rows (`rows.mjs`, `p3`)

- W2: `id` is written by no branch, so it is written at mount and has no group. `label` is one row
  group.
- W1(Go) = {version, rows[K].label} with K the literal `target(n)`. No hole reads `version`. The
  edit is "row K's item changed", so the handler points instance K at `List.unsafeGet rows K` and
  marks it.
- W1(Swap) = {rows ← swap 1 (n − 2)}. The edit swaps two instances: two `insertBefore` calls and
  two writes to the instance array. Nothing a row shows changed, so no group runs.
- Each edit applies only when `List.update`/`List.swap` returned a new list. That is their own
  guard, read as an identity check.

### 3.3 Live rows (`live.mjs`, `p3`)

- W1(Go) = {tick}: one group, and **no row is visited**.
- W1(Edit) = rows[*].label through `List.map`, with length, order and keys kept (`{ row | label }`
  keeps `id`). Its edit is the positional identity walk: O(n), research 58 §5(a)'s cost for the
  idiom without slice C. `Edit` is not on the measured path.
- A row's one group writes the input's value (only when the DOM differs, as beni's controlled
  input does) and the inlined `cell`'s text.
- **The dirty set** (research 58 §5(c)). The `<tbody>`'s `input` listener marks the input dirty,
  then sends `Edit`. After the groups run, each dirty input is compared with the model and set back
  if they differ, and the set is emptied. A render visits the inputs a user touched and no others.
  The differential check types into the 4th and the 10 000th inputs, clears one, and finds every
  `.value` equal to beni's after every step.

### 3.4 Depth (`depth.mjs`, `p3`)

- The model half is beni's `init1…init128` and `bump1…bump128`.
- W2: no branch writes a `label`, and once the top-level constants are inlined `init` is literal,
  so all 128 labels are template text. Every `viewK` is used once and inlined into one 128-level
  template, and the walk to the leaf is unrolled.
- W1(Go) = {root.child¹²⁷.v} through `bump1`'s summary. One group reads the path, unrolled, and
  compares.

### 3.5 The table app (`apps/p3/bench.js`)

| constructor | write set, as the source has it | emitted edit |
|---|---|---|
| Run, RunLots | rows ← a list built from `[]` (not derived from the old one; keys may meet old ones) | `reconcile` (finds no kept key, so `textContent = ""` and one fragment) |
| Add | rows ← `model.rows ++ fresh` (the old list is a prefix) | append: new instances only |
| Update | `indexedMap … { row \| label }`: rows[*].label, keys and order kept | `reconcile`'s trimming = the identity walk; 100 rows marked |
| SwapRows | `indexedMap … b \| a \| row`: elements may come from other positions | `reconcile`: crossed ends, two moves |
| Remove | `filter`: order kept, some removed | `reconcile`: trimming finds the gap |
| Clear | rows ← `[]`, and the `<tbody>` holds only the list | `textContent = ""` |
| Select | selected | every row's class group |

The jumbotron is template text, and so are the six `button` calls, because all their arguments are
literals. Each button gets a direct listener calling its constructor's handler.

The table app does not write `List.swap`. It writes the swap as `indexedMap` with `if i == 1 then b
else if i == 998 then a else row`. A write-set analysis that understood guards on the index
(`i == literal`, `mod i 10 == 0`) could emit exact edits for both Update and SwapRows. Research 58
§4 does not list that, so P3 does not use it (§6).

## 4. Measurements

Script ms, median [interquartile range], and each median ÷ vanilla's. Bytes are minified + brotli
11 (beni's are its `--release` build).

### 4.1 Flat sweeps

**Holes, N = 10**

| subject | traced | ÷ v | untraced | ÷ v | bytes |
|---|--:|--:|--:|--:|--:|
| p3 | 0.060 [0.055–0.067] | 1.21 | 0.065 [0.060–0.071] | 1.18 | 394 |
| beni | 0.099 [0.093–0.125] | 1.97 | 0.090 [0.079–0.105] | 1.64 | 1 241 |
| p2 | 0.070 [0.062–0.076] | 1.39 | 0.065 [0.060–0.070] | 1.18 | 397 |
| vanillajs | 0.050 [0.046–0.056] | 1.00 | 0.055 [0.055–0.060] | 1.00 | 168 |
| solid1 | 0.104 [0.100–0.118] | 2.08 | 0.090 [0.085–0.098] | 1.64 | 2 948 |

**Holes, N = 10 000**

| subject | traced | ÷ v | untraced | ÷ v | bytes |
|---|--:|--:|--:|--:|--:|
| p3 | 0.060 [0.059–0.066] | 1.09 | 0.070 [0.065–0.075] | 1.04 | 442 |
| beni | 0.122 [0.108–0.179] | 2.23 | 0.112 [0.094–0.136] | 1.67 | 61 905 |
| p2 | 0.486 [0.375–0.830] | 8.83 | 0.383 [0.355–0.444] | 5.67 | 26 691 |
| vanillajs | 0.055 [0.051–0.059] | 1.00 | 0.067 [0.064–0.070] | 1.00 | 195 |
| solid1 | 0.115 [0.100–0.132] | 2.08 | 0.110 [0.100–0.116] | 1.63 | 55 497 |

**Live rows, N = 10 000** (an unrelated field changes)

| subject | traced | ÷ v | untraced | ÷ v | bytes |
|---|--:|--:|--:|--:|--:|
| p3 | 0.062 [0.056–0.064] | 1.28 | 0.075 [0.070–0.081] | 1.25 | 1 049 |
| beni | 2.67 [2.54–2.80] | 55.2 | 2.79 [2.43–3.13] | 46.5 | 3 448 |
| p2 | 0.049 [0.046–0.057] | 1.01 | 0.068 [0.065–0.075] | 1.13 | 243 |
| vanillajs | 0.049 [0.044–0.059] | 1.00 | 0.060 [0.060–0.070] | 1.00 | 243 |
| solid1 | 0.102 [0.097–0.111] | 2.11 | 0.120 [0.110–0.125] | 2.00 | 3 516 |

(P2's live page is vanilla's page: research 29's P2 has no controlled inputs to keep.)

**Depth, D = 128**

| subject | traced | ÷ v | untraced | ÷ v | bytes |
|---|--:|--:|--:|--:|--:|
| p3 | 0.087 [0.071–0.100] | 1.54 | 0.090 [0.080–0.101] | 1.29 | 1 237 |
| beni | 0.367 [0.262–0.517] | 6.45 | 0.180 [0.162–0.250] | 2.57 | 3 127 |
| p2 | 0.065 [0.059–0.071] | 1.14 | 0.075 [0.070–0.081] | 1.07 | 412 |
| vanillajs | 0.057 [0.051–0.060] | 1.00 | 0.070 [0.065–0.075] | 1.00 | 294 |
| solid1 | 0.248 [0.232–0.268] | 4.36 | 0.192 [0.150–0.241] | 2.75 | 4 486 |

### 4.2 List sweeps

**Rows, N = 30 000, one row edited**

| subject | traced | ÷ v | untraced | ÷ v | bytes |
|---|--:|--:|--:|--:|--:|
| p3 | 0.109 [0.105–0.113] | 1.49 | 0.105 [0.090–0.114] | 1.31 | 1 643 |
| beni | 0.449 [0.434–0.466] | 6.14 | 0.450 [0.412–0.491] | 5.63 | 3 835 |
| p2 | 3.04 [2.97–3.11] | 41.7 | 2.78 [2.65–3.00] | 34.7 | 1 053 |
| vanillajs | 0.073 [0.063–0.080] | 1.00 | 0.080 [0.070–0.085] | 1.00 | 415 |
| solid1 | 0.128 [0.115–0.139] | 1.75 | 0.127 [0.120–0.140] | 1.59 | 3 576 |

**Rows, N = 30 000, two rows swapped**

| subject | traced | ÷ v | untraced | ÷ v | bytes |
|---|--:|--:|--:|--:|--:|
| p3 | 0.126 [0.122–0.135] | 1.32 | 0.137 [0.129–0.145] | 0.98 | 1 643 |
| beni | 0.845 [0.823–0.892] | 8.85 | 1.17 [0.906–1.32] | 8.36 | 3 835 |
| p2 | 2.68 [2.48–2.78] | 28.1 | 2.85 [2.73–2.98] | 20.4 | 1 053 |
| vanillajs | 0.096 [0.093–0.101] | 1.00 | 0.140 [0.125–0.160] | 1.00 | 415 |
| solid1 | 6.43 [5.31–7.35] | 67.3 | 5.58 [4.23–6.47] | 39.8 | 3 576 |

(The untraced rows batch ran at load 1.6–4.8, the traced one at 1.2–2.7. Vanilla's swap differs
between the two modes by more than P3's does, so P3's 0.98 untraced and 1.32 traced bracket the
truth.)

### 4.3 Where the misses are: ablations (traced, 3 pages × 6)

| case | subject | script ms |
|---|---|--:|
| rows 30 000 edit | p3 | 0.103 [0.083–0.110] |
| | p3 without `List.update` (`p3-abl-nolist`: the instance gets `{ ...row, label }` directly) | **0.072** [0.062–0.078] |
| | vanillajs | 0.062 [0.056–0.066] |
| | vanilla holding P3's 30 000 instances and text-node wrappers (`vanilla-wrappers`) | 0.060 [0.054–0.071] |
| depth 128 | p3 | 0.080 [0.070–0.114] |
| | p3 with one recursive bump (`p3-abl-onebump`) | 0.069 [0.057–0.082] |
| | p2 | 0.053 [0.051–0.057] |
| | vanillajs | 0.049 [0.043–0.050] |

- **The rows edit.** The renderer is within 1.16× of vanilla. About 0.03 ms of the 0.04 ms gap is
  `List.update` on the trie: a path copy of three 32-slot arrays and a header. In Node, hot, that
  is 0.25 µs a call (`out/listcost.mjs`, not committed). In the page it runs once per click and
  never warms up.
- **Holding instances costs nothing.** Vanilla holding everything P3 holds per row is as fast as
  vanilla.
- **Depth.** One recursive function in place of 128 recovers about a third of the gap. What
  remains (0.069 against P2's 0.053) is P3's loop around the handler plus the 127-step path read.
  Both pages copy 128 records per message, and W4 removes that copy.

### 4.4 Bursts, on the 1 000-hole page

| K | p3 traced | vanilla traced | p3 untraced | beni untraced | vanilla untraced | solid1 untraced |
|--:|--:|--:|--:|--:|--:|--:|
| 1 | 0.148 (1.94×) | 0.076 | 0.080 (1.23×) | 0.113 | 0.065 | 0.115 |
| 3 | 0.151 (1.99×) | 0.076 | 0.085 (1.06×) | 0.123 | 0.080 | 0.150 |
| 10 | 0.221 (1.61×) | 0.138 | 0.110 (1.10×) | 0.142 | 0.100 | 0.225 |
| 30 | 0.341 (1.19×) | 0.286 | 0.185 (1.00×) | 0.252 | 0.185 | 0.435 |
| 100 | 0.863 (1.02×) | 0.849 | 0.422 (0.94×) | 0.513 | 0.450 | 0.878 |
| 300 | 2.22 (1.00×) | 2.23 | 0.955 (0.86×) | 1.15 | 1.11 | 1.96 |
| 1 000 | 6.82 (0.98×) | 6.96 | 2.81 (0.87×) | 3.28 | 3.21 | 5.79 |

P3 keeps beni's burst win and slightly widens it. From K = 30 it is at or below vanilla, which
writes the text node K times where P3 writes it once. Below K = 10 it pays the microtask that
batching needs: a synthetic click is untrusted, so it renders in a microtask, and the trace
charges that microtask about 0.05 ms (research 56 §2.2). Medians and IQRs for every cell are in
the results files (`node report-p3.mjs`).

### 4.5 The table benchmark (official throttling, n = 10, script ms)

| operation | p3 | beni | p2 | vanillajs | solid1 | p3 ÷ vanilla |
|---|--:|--:|--:|--:|--:|--:|
| create 1k | 5.24 [4.85–5.48] | 5.08 | 4.55 | 5.07 [4.76–5.29] | 5.63 | 1.03 |
| replace 1k | 11.5 [11.4–11.7] | 11.8 | 11.6 | 11.0 [10.8–11.2] | 13.5 | 1.05 |
| update every 10th | 0.93 [0.82–1.10] | 1.34 | 1.17 | 1.01 [0.84–1.05] | 2.01 | 0.92 |
| select | 1.55 [1.37–1.70] | **1.07** | 2.14 | 1.74 [1.58–1.80] | 1.99 | 0.89 |
| swap | 0.66 [0.48–0.88] | 1.30 | 0.94 | 0.16 [0.13–0.61] | 2.02 | 4.16 |
| remove | 0.26 [0.22–0.42] | 0.49 | 0.54 | 0.54 [0.54–0.56] | 0.64 | 0.48 |
| create 10k | 48.8 [48.3–49.4] | 50.6 | 43.6 | 47.6 [47.1–47.9] | 55.1 | 1.03 |
| append 1k | 4.65 [4.61–4.71] | 5.52 | 4.33 | 4.84 [4.83–4.89] | 5.17 | 0.96 |
| clear | 22.4 [22.1–22.9] | 24.3 | 22.8 | 22.1 [21.7–22.3] | 24.3 | 1.01 |

- **Swap.** Vanilla's swap is bimodal: 0.13–0.61 here, and 0.39 on this morning's batch. Either
  way P3's is not research 58's estimated 0.45. Both of P3's costs are O(n): the model's
  `indexedMap` over 1 000 rows, and `reconcile`'s key compares. P3 is still twice as fast as beni.
- **Select.** P3 is slower than beni, 1.55 against 1.07, because it dropped beni's selector and
  walks 1 000 rows. P3 is still under vanilla.
- **Everything else** is within 1.05× of vanilla, and remove is twice as fast as vanilla.

### 4.6 Bytes: the table app (minified + brotli 11)

| subject | bytes | ÷ vanilla |
|---|--:|--:|
| vanillajs | 1 415 | 1.00 |
| P2 | 1 537 | 1.09 |
| P3's own module (core imported, not counted) | 2 243 | 1.59 |
| **P3** (scope-hoisted with the core it reaches) | **3 454** | **2.44** |
| Solid 1 | 4 354 | 3.08 |
| beni `--release` | 5 510 | 3.89 |

- Core's reachable `List` minifies to about 1.8 kB alone and adds about 1.2 kB in the bundle. It
  is reached by the model half: `cons` through `[ x, …rows ]`, `++`, `indexedMap`, `filter` and
  `get`.
- Renaming the record fields, which beni's release item 4 does, saves 4 bytes after brotli.
- On the sweeps P3 is 394–442 B on the holes pages at any N (beni 1 241 → 61 905), 1 049 B on live
  rows (beni 3 448), and 1 643 B on rows (beni 3 835). On depth 128 it is 1 237 B (beni 3 127),
  almost all of it the model half's 128 `initK`/`bumpK` declarations.

## 5. What surprised me

1. **The renderer is no longer where the time goes.** Once groups run only when a message can
   reach them, the gap to vanilla is core's data structures running cold. One `List.update` per
   click costs 0.03 ms in the page and 0.25 µs hot. Each message runs model code once, so it never
   gets optimised. That argues for slice 5 (in-place top-level update) and for looking at core's
   `List` in the page, not in a hot loop. It does not argue for any further renderer work.
2. **The live-rows line, the largest loss in research 58 §2.2, disappears completely.** It was 50×
   vanilla; with a dirty set and W1(Go) = {tick} it is 1.25× untraced, P2's level. That needs no
   analysis beyond the write set.
3. **The table app's bytes are the model's, not the renderer's.** Research 58 §7 estimated
   2 500–3 000 B. The renderer and handlers fit that estimate, but the estimate did not count core:
   about 1.2 kB of `List` the program reaches through ordinary list code. Vanilla gets the same job
   from `Array.prototype`.
4. **The program's idioms decide what the compiler can know.** The table app writes its swap and
   its update as `indexedMap` with index guards, so P3 reaches `reconcile` for both. A guard-aware
   write set (`i == 1`, `mod i 10 == 0`) would make both exact edits. It is a small, common
   pattern, and research 58 §4 does not list it.
5. **beni's selector earns its keep.** Dropping it for the architecture's plain "run the class
   group on every row" made `select` 45% slower than beni. P3 should keep it.
6. **A microtask is not free outside a trace either.** In-page, `queueMicrotask` plus its run costs
   3–5 µs in this Chrome with DevTools attached (`out/probe-micro.mjs`). Research 56's
   synthetic-click loop therefore charges beni and P3 a microtask that a user's trusted click never
   pays. That is why the untraced mode here times real clicks.

## 6. What this means for research 58's plan

- **The architecture holds; the criteria measured the model too.** On the renderer's own terms
  (the rows ablation, holes 10 000, the bursts, eight of the nine table operations) P3 is within 1.0–1.2× of
  vanilla, and flat where vanilla is flat. Research 58's fallback goal, "flat at Solid's constant",
  is beaten everywhere: P3 is below Solid 1 on every page and every table operation.
  - Taken literally, the kill criteria say stop.
  - My recommendation is to **build slices 1–3 as planned** and rewrite criterion 1 as "the
    renderer within 1.15×, with the model half measured separately". The owner should decide that,
    not this spike.
- **Order of work.** Research 58's order still holds:
  1. The dirty set is the largest win and needs no analysis.
  2. Constancy takes holes 10 000 from 61 905 B to 442 B.
  3. Write sets and per-constructor handlers.

  To that order, add two items:
  - **(a)** Measure core's cold costs: `List.update` on a trie, and the spread chains of nested
    updates.
  - **(b)** Bring slice 5 (W4) forward for depth-like models.

  Keep beni's selector inside slice 3, and add index guards to the W1 analysis (§5.4).
- **The bytes criterion** should be restated against what the page reaches. Either "≤ 2× vanilla
  excluding core", which P3 meets at 2 243 B (1.59×), or a separate bound on core's `List` for a
  page that uses `cons`, `++`, `indexedMap` and `filter`. Shrinking that `List` is a core question,
  not a rendering one.
- **Not done here:** research 58's compiler-side feasibility spike (S2, W1/W2 over the TEA corpus)
  and the width sweep. Duplicate keys in `reconcile` are untested.
