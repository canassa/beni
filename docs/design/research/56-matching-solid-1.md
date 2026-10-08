# Matching Solid 1: why it beats beni, and what closes the gap

**Commissioned by** the owner, 2026-10-04: *"Investigate why Solid beats beni and find a solution.
Rules: idiomatic beni code, no hacks. Everything else is up for discussion, including architecture
changes to beni and TEA. Solid 1 speed across all benchmarks is the bar."* The losses are the ones
the scaling sweeps found ([`2026-10-04-scaling.md`](../../../bench/ui/results/2026-10-04-scaling.md)):
a fixed ≈ 0.05 ms per message on every page, and four curves — view size, long-list change, model
width, derived view — where beni grows and Solid 1 stays flat.

**What this is.** A diagnosis with evidence, three proposals prototyped as hand edits of beni's
emitted JavaScript and runtime, and their measurements against Solid 1.9.15 and today's beni on
every sweep, the table benchmark and the static page. **What this is not.** A built feature: no
file under `src/`, `core/` or `platforms/` changed (rule 1). The owner decides; §8 asks.

**Facts and opinions are kept apart.** §1–§5 are measurements and what they directly show. §6
(the proposals' design) and §7 (the recommendation) are the author's judgement.

**Read §0, then §7.**

---

## 0. Findings

### 0.1 The answer, per loss

Script ms per message, median, unthrottled, click to paint from a trace (the scaling harness's
sample; `results/2026-10-04-r56-final.json`, 2 pages × 4 samples per point, confirmed where marked by
`r56-residuals.json`, 4 × 6). **next** is today's beni with the three proposals applied where they
apply (§6): A everywhere, B on pages whose roots read fields (on the rows page that is only the
list hole's guard and the hoisted row), C on the keyed list.

| loss | cause, measured | point | beni today | **next** | Solid 1 |
|---|---|---|--:|--:|--:|
| fixed floor | the render runs in a **microtask**: one more top-level callback, which the harness's trace instrumentation charges ≈ 0.05 ms (an empty `queueMicrotask` in vanilla JS costs 0.051, §2) | holes 10 | 0.146 | **0.093** | 0.088 |
| view size | `view` evaluates every value and `p` compares every hole: O(N) | holes 1 000 | 0.211 | **0.095** | 0.082 |
| | | holes 10 000 (4 × 6) | 0.859 | **0.105** | 0.096 |
| long list, one row changes | the renderer copies the trie flat (`$plain()`) and visits every row: O(n) | rows 1 000 (4 × 6) | 0.175 | **0.118** | 0.088 |
| | | rows 30 000 (4 × 6) | 0.472 | **0.148** | 0.106 |
| model width | the floor to 256 fields; at 1 024, the record **copy** in `update` (0.25 ms cold, P2 pays the same) | width 256 (4 × 6) | 0.177 | **0.106** | 0.100 |
| | | width 1 024 | 0.493 | 0.393 | 0.104 |
| model depth | the floor | depth 16 | 0.171 | **0.114** | 0.124 |
| derived view, inline | `view` re-sorts on every render; Solid's `createMemo` does not | derived 100 000 | 6.62 | **0.085** | 0.095 |
| burst, K messages per task | K = 1: the microtask, outside a trusted dispatch (§4.6) | burst 1 | 0.206 | 0.176 | 0.134 |
| | beni renders once per task; Solid 1 once per write | burst 100 | 0.905 | **0.823** | 1.13 |
| static page (trace) | the floor | 50 holes, 51 fields | 0.159 | **0.096** | 0.103 |

**Where next reaches Solid 1** (median within one page's spread, ≈ 0.01 ms, or below): every
holes point (10 → 10 000), every width point to 256, every depth point, every derived point, the
static page, every swap from 100 rows, every burst from K = 10 — and the table benchmark, where beni
already led Solid 1 on eight of nine operations and A adds to the lead (§5.2). **Where it does not**:

- **a long keyed list's one-row change**, 1.3–1.4× (0.03–0.04 ms at 1 000–30 000 rows): the rest is
  in the message's dispatch and `List.update`'s trie copy, not the render (§4.2, untraced split);
- **model width 1 024**: the copy of a 1 024-field record, which every immutable update of it pays
  (P2, hand-written TEA, pays the same 0.33 ms; §4.3);
- **a burst of one or three synthetic clicks** sent by page script: the render stays in a microtask
  there, on purpose — rendering at once would give up the batching that wins every burst from K = 30
  (§4.6);
- **the table's `append`** in the development build only (5.54 against 5.22 ms; `--release` 5.02),
  which none of the proposals touches (§5.2).

### 0.2 What the programmer writes

**Nothing different.** Every number above is of the programs the sweeps already generate, written as
a beni developer writes them: the projection in `view` (`shown = top model.items`), the row edit
through `List.update`, one immutable model, no annotation, no `lazy`, no selector, no signal, no
store. Proposal B makes the derived view's most natural form the fast one: today the fast form needs
the table moved into a helper so a render can skip it (`beni-helper`, 0.143 at 100 000 — itself
above Solid 1 by the floor).

### 0.3 The three proposals, in one line each

- **A — render at the end of the browser's dispatch.** A message sent from the listener of a trusted
  event renders when that listener returns — exactly where the microtask would have run — so no
  callback is added. Ten lines of `Rt.beni`; +50 brotli bytes; nothing observable changes (§6.1).
- **B — the template computes its own values, by what they read.** A root's block carries its inputs
  (`[model]`); the kind evaluates each value inside `p`, grouped by the field paths it reads, and runs
  a group only when one of its paths changed. A `let` of `view` read only by the root becomes one of
  its values, so a derived value is recomputed only when what it reads changed — Solid's
  `createMemo`, recovered from the reads. Interface and lowering change; output gets **smaller**
  (§6.2).
- **C — a list says what changed since an older version.** `core/List` gains `xs.$diff(old)`, which
  for two tries finds the changed positions by walking only the nodes they do not share; `forKeyed`
  patches those rows and visits no other. +200–400 brotli bytes where a keyed list reaches a trie
  (§6.3).

### 0.4 Recommendation (opinion)

Build **A, then B, then C**, each specified first and measured on this harness before the next
(§7). Ask the owner the four questions of §8 — chief among them whether a 1 024-field model is a
target (it is the one sweep point no proposal here can reach), and whether B's evaluation order
amendment is acceptable.

---

## 1. Method

- **Harness.** `bench/ui/match.mjs`, new: the scaling sweeps' sample exactly (`scaling.mjs`,
  research 29 §1) — one real click on a fresh page's target after five warm-up clicks, click to
  paint from a Chrome trace analysed by `lib/trace.mjs` (js-framework-benchmark's `timeline.ts`),
  several samples per page, subjects rotated per page — **unthrottled**, because the scaling report
  showed that 4x throttling adds a random 0.4–0.7 ms pause to anything under a millisecond. The table
  benchmark is `bench.mjs` unchanged (the official per-operation throttling); the static page is
  `micro.mjs` unchanged, plus the trace sample above. Two more modes of `match.mjs`, for diagnosis
  only: **halves** (`halves.mjs`'s split — `performance.now()` around a synthetic click, then to a
  microtask queued after it, **no trace running**) and **profile** (a V8 CPU profile at a 10 µs
  interval around each real click; it attributed 85–98 % of samples to `(program)` and is quoted
  nowhere below for that reason).
- **Programs.** The scaling sweeps' own generated programs (`apps/scaling/*.mjs`), unchanged, built
  by `scaling.mjs --build-only --full` with this worktree's beni (`zig build -Doptimize=ReleaseFast`
  at `6235729f2`, the brief's `master`). Solid 1.9.15 built as js-framework-benchmark builds it. The
  static page on Solid 1 is new: `apps/solid1/build-static.mjs`, gen-micro's Solid 2 page with Solid
  1's imports.
- **Prototypes.** `bench/ui/match-variants.mjs`: each variant is a copy of the **development** build
  with named text edits — to `_platform/_browser/Rt.mjs` (the runtime module's output), `Main.mjs`
  (the emitted program) or `_core/List.mjs` — written to `out/match/`. They are what the compiler and
  runtime *would* emit; none is a build of the compiler. The release build was not edited (its names
  are short); the scaling report found development and `--release` within noise everywhere, and the
  table below agrees. Bytes are estimated by `match-size.mjs` (terser then brotli 11 over the base and
  the variant alike, §5.4).
- **Machine.** AMD Ryzen 9 5950X, Chrome 153.0.8010.36 headless (nixpkgs `chromium`), Node 24.19.0,
  Chrome pinned to CPUs 8–15; one benchmark process at a time; 1-minute load 0.1–1.8 at batch starts.
- **Reading the numbers.** Medians with interquartile ranges; orderings and per-operation medians,
  never a geometric mean (rule 8). One page's samples spread by about ±0.01 ms at these sizes; a
  difference smaller than that is a tie.
- **Time budgets**, stated before each run and met: diagnosis runs 1–5 min each; the table, 10 min
  (9 operations × 4 subjects × 10); the final batch of 40 points × 4 subjects, 9 min; the residual
  check, 7 min; the static page under `micro.mjs`, 5 min.

| file | what |
|---|---|
| `results/2026-10-04-r56-floor.json` | §2: the floor's ablations, `holes:10`, 4 × 6 |
| `results/2026-10-04-r56-halves.json` | §2.4, §4: the untraced split |
| `results/2026-10-04-r56-final.json` | §3–§5: every sweep, beni / next / Solid 1 (/ beni-helper) |
| `results/2026-10-04-r56-residuals.json` | §0.1: the close points again, 4 × 6 |
| `results/2026-10-04-r56-table-A.json` | §5.2: the table benchmark, beni / release / A / Solid 1 |
| `results/2026-10-04-r56-static-micro.json` | §5.3: the static page, in-page |

`node match-report.mjs <file>` prints any of the `match.mjs` files as tables; `report.mjs` the
table's; the static page's are `micro.mjs` rows.

---

## 2. The fixed overhead: one more callback, and what the trace charges for it

### 2.1 Where the 0.05 ms is

The 10-hole page, one message. One sample's main-thread events inside the click (`match.mjs
--dump`):

```
beni      0.000 EventDispatch click          +0.124
          0.008   FunctionCall Rt$delegated  +0.070   listener: fire, send, update
          0.079   UpdateCounters
          0.085   FunctionCall (anonymous)   +0.028   the microtask: flush, view, patch
          0.105   InvalidateLayout                    the one text write
          0.114   UpdateCounters
Solid 1   0.000 EventDispatch click          +0.087
          0.009   FunctionCall N             +0.060   listener: signal write, effect, text write
          0.056   InvalidateLayout
          0.071   UpdateCounters
```

beni's message is **two** top-level callbacks — the delegated listener, then the microtask that
renders (W28, "copy Solid 2"; `backend.md` §15.11) — where Solid 1's is one: `writeSignal` runs the
effects inside the handler (`solid-js/dist/solid.js:652`; `runUpdates` at `:819` flushes before it
returns). Chrome's DevTools timeline, which the harness records (it is js-framework-benchmark's
method), instruments each top-level callback with a `FunctionCall` event and an `UpdateCounters`
event whose arguments are the heap's statistics and the document's counters.

### 2.2 What one more callback costs by itself

Vanilla JavaScript writing the one text node, and the same with one **empty** `queueMicrotask(() =>
{})` after the write (`vanilla-microtask`; 4 pages × 6):

| subject | script ms |
|---|--:|
| vanilla | **0.045** [0.042–0.050] |
| vanilla + an empty microtask | **0.096** [0.089–0.101] |
| vanilla, the write moved into a microtask | 0.095 [0.089–0.105] |
| P2 (research 29's hand-compiled TEA, synchronous) | 0.052 [0.048–0.057] |
| Solid 1 | 0.088 [0.082–0.095] |
| beni | 0.142 [0.130–0.158] |

**An empty microtask costs 0.051 ms in this harness** — more than Solid 1's whole message above
vanilla (0.043).

### 2.3 Taking the pieces out of beni

Ablations of the development build, same batch:

| variant | removed | script ms |
|---|---|--:|
| beni | — | 0.142 [0.130–0.158] |
| `abl-nofinally` | the `try … finally` around a handler and a flush | 0.135 [0.128–0.157] |
| `abl-sync` | the render, moved into the send (the microtask still queued, now empty) | 0.138 [0.124–0.151] |
| `abl-nomicro` | the render in the send, **no microtask queued** | **0.085** [0.075–0.097] |
| **A** (§6.1) | the microtask, for a trusted event only | **0.085** [0.076–0.099] |

The guards cost nothing measurable; moving the render does nothing while a microtask is queued;
**removing the microtask puts beni on Solid 1.**

### 2.4 Without a trace

Measured in the page with no trace running (`--mode=halves`, 4 × 5; each includes the synthetic
click's own dispatch, vanilla's 0.085): **beni 0.133 [0.124–0.140], Solid 1 0.110 [0.105–0.121],
P2 0.090.** So with no instrumentation beni's message costs ≈ 0.02 ms more than Solid 1's — the
delegated walk, `update` and a `view` of eleven values — and the rest of the harness's 0.05 is the
instrumentation of the second callback. The harness's number is js-framework-benchmark's number, so
the floor is worth removing; most of it is not something a user feels.

### 2.5 Solid 2 has the same floor, for the same reason

Solid 2 flushes in a microtask (`references/solid/packages/signals/src/core/scheduler.ts:410`,
`queueMicrotask(flush)`); the scaling report measured it at 0.15–0.16 ms on every small page — beni's
floor, not Solid 1's.

**Cause, in one sentence:** beni renders in a microtask, and each top-level callback costs ≈ 0.05 ms
of the harness's own instrumentation; Solid 1 renders inside the handler.

---

## 3. The four curves: what grows, and why

### 3.1 View size — every value, every render

`view` evaluates every value of the root, builds the block's array, and `p` compares each with what
it last wrote (`backend.md` §15.3): O(N) per message whatever changed. Today's emitted code for the
10-hole page — the eleven reads in `view`, eleven comparisons in `p` — is this exactly; at 10 000
holes it is 0.86 ms against Solid 1's 0.10 (Solid's effect per hole runs only when its signal
changed). P2, the hand-written version of the same design, grows the same way (0.42 at 10 000 in the
scaling report).

### 3.2 A long keyed list, one row changes — every row, every render

`List.update` on a list of more than 256 elements makes a trie (once) and then copies one path per
set (`core/List.beni`, `set`, `trieSet`). The render then calls `forKeyed`, whose fast path
(`trimmed`, `startRows`) takes the list's plain copy — `$plain()`, O(n), made once per trie header,
and every update is a new header — and visits every row: an identity check and a stamp write each
(`backend.md` §15.5). Untraced (halves): at 30 000 rows the render half is **0.385 ms** of beni's
0.538; Solid 1's whole message is 0.175 — one signal write, one text write.

### 3.3 Model width — the floor, then the record copy

To 256 fields the curve is the floor (beni 0.177 vs 0.101 at 256). At 1 024 the update itself grows:
untraced, the click half (listener and `update`) is **0.335 ms** for beni, **0.332 for P2**, 0.090
for Solid 1. P2 differs from beni in everything but `update`'s `{ ...model, f512: … }`, so the copy
of a 1 024-field record is the cost; Solid's store sets one property.

### 3.4 Derived view — the projection, every render

`shown = top model.items` in `view` filters and sorts the items on every message, linear in N (6.62
ms at 100 000). Solid derives it in `createMemo`, which re-runs only when `items()` changes
(`solid.js:244`). beni's existing helper skip (`language.md` §11.6) recovers it when the programmer
moves the table into a helper (`beni-helper`, flat at 0.143 — the floor above Solid 1).

### 3.5 Depth

Both grow slowly with depth (+0.13 ms from 1 to 128 for beni, +0.10 for Solid 1 in this batch; the
scaling report had the opposite order, +0.06 against +0.09 — the deep pages are noisy), and beni sits
above Solid 1 by the floor.

---

## 4. The proposals, measured, per sweep

`results/2026-10-04-r56-final.json`; script ms, median [IQR], 2 pages × 4; Solid 1 in the same
batch. "next" = A + B + C where each applies (§0.1).

### 4.1 View size

| N | beni | **next** | Solid 1 |
|--:|--:|--:|--:|
| 10 | 0.146 [0.126–0.163] | **0.093** [0.072–0.103] | 0.088 [0.083–0.093] |
| 100 | 0.146 [0.135–0.159] | **0.088** [0.085–0.098] | 0.082 [0.078–0.093] |
| 1 000 | 0.211 [0.201–0.227] | **0.095** [0.087–0.100] | 0.082 [0.074–0.095] |
| 3 000 | 0.356 [0.300–0.411] | 0.123 [0.105–0.186] | 0.085 [0.081–0.093] |
| 10 000 | 0.859 [0.806–1.36] | 0.188 [0.107–0.304] | 0.105 [0.098–0.126] |
| 3 000, 4 × 6 | | **0.097** [0.084–0.122] | 0.089 [0.083–0.099] |
| 10 000, 4 × 6 | | **0.105** [0.093–0.159] | 0.096 [0.088–0.102] |

Flat. The large pages have outlier samples for both (Solid 1's IQR reached 0.084–0.165 in one
re-run); their typical trace is next 0.091 against Solid 1's 0.082, the write landing 0.068 against
0.056 ms after the click. A alone (A without B) is 0.157 at 1 000 and 0.764 at 10 000; B alone is
0.144 and 0.169: **B flattens the curve, A lowers it.**

### 4.2 A long keyed list

| rows | change: beni | **next** | Solid 1 | swap: beni | **next** | Solid 1 |
|--:|--:|--:|--:|--:|--:|--:|
| 10 | 0.160 | 0.104 | 0.088 | 0.211 | 0.161 | 0.149 |
| 100 | 0.171 | 0.105 | 0.085 | 0.242 | **0.171** | 0.187 |
| 1 000 | 0.175 | 0.121 | 0.092 | 0.237 | **0.198** | 0.392 |
| 3 000 | 0.265 | 0.137 | 0.098 | | | |
| 10 000 | 0.314 | 0.138 | 0.107 | 0.672 | **0.662** | 2.22 |
| 30 000 | 0.472 | 0.149 | 0.122 | 0.857 | **0.855** | 5.43 |
| 1 000, 4 × 6 | | 0.118 [0.112–0.131] | 0.088 [0.081–0.104] | | | |
| 30 000, 4 × 6 | | 0.148 [0.136–0.162] | 0.106 [0.103–0.129] | | | |

**The change is flat, and 0.03–0.04 ms above Solid 1.** C alone took 30 000 rows from 0.487 to 0.205,
A on top to 0.147. The residual is not the render: untraced at 30 000 (halves), next's render half
is **0.067 ms against Solid 1's 0.055**; its click half is 0.158 against 0.120 — the delegated
listener and `update`, i.e. `List.update`'s path copy (a header, a tree record, the path's arrays
and a 32-slot leaf), a closure call and the spread of the row and the model, run cold. Closing it is
not one of the three proposals (§8 question 2's neighbour: a specialised trie set, or the runtime's
dispatch trims of §6.5, each worth a few µs; neither prototyped). **Swap** keeps beni's lead and
widens it: Solid 1 diffs the whole new array (`reconcileArrays`), beni's `forKeyed` finds the swapped
pair at the ends.

### 4.3 Model width

| W | beni | **next** | Solid 1 |
|--:|--:|--:|--:|
| 4 | 0.141 | **0.085** | 0.105 |
| 16 | 0.131 | **0.095** | 0.104 |
| 17 | 0.143 | **0.091** | 0.100 |
| 64 | 0.145 | **0.101** | 0.105 |
| 256 | 0.177 | 0.118 | 0.101 |
| 256, 4 × 6 | | **0.106** [0.093–0.120] | 0.100 [0.088–0.107] |
| 1 024 | 0.493 | 0.393 | 0.104 |

To 256 fields next is with or below Solid 1. **At 1 024 it is not, and none of the three can make
it so**: the cost is `update` copying the record (§3.3), which B does not touch (it removes `p`'s
1 024 comparisons, 0.493 → 0.393). Parity there needs an update that does not copy (§6.5).

### 4.4 Depth

| D | beni | **next** | Solid 1 |
|--:|--:|--:|--:|
| 1 | 0.139 | **0.096** | 0.102 |
| 4 | 0.147 | **0.101** | 0.108 |
| 16 | 0.171 | **0.114** | 0.124 |
| 64 | 0.233 | 0.154 [0.139–0.216] | 0.146 [0.141–0.149] |
| 128 | 0.270 | 0.219 [0.179–0.338] | 0.205 [0.190–0.226] |

A alone; with or below Solid 1 everywhere within the spread of the deep pages.

### 4.5 Derived view

| N | beni (inline) | beni-helper | **next** (inline) | Solid 1 |
|--:|--:|--:|--:|--:|
| 100 | 0.186 | 0.142 | **0.089** | 0.091 |
| 1 000 | 0.287 | 0.140 | **0.085** | 0.087 |
| 10 000 | 0.869 | 0.144 | **0.086** | 0.091 |
| 100 000 | 6.62 | 0.143 | **0.085** | 0.095 |

The idiomatic inline program, flat and with Solid 1, 78× faster than today at 100 000. A alone does
nothing here (0.260 at 1 000); B alone is what memoises the projection.

### 4.6 Bursts

| K synthetic clicks in one task | beni | **next** | Solid 1 |
|--:|--:|--:|--:|
| 1 | 0.206 | 0.176 | 0.134 |
| 3 | 0.254 | 0.179 | 0.149 |
| 10 | 0.299 | **0.253** | 0.253 |
| 30 | 0.437 | **0.394** | 0.532 |
| 100 | 0.905 | **0.823** | 1.13 |
| 1 000 | 6.10 | **6.10** | 8.85 |

The burst's clicks are `go.click()` calls from a page-script listener: **untrusted** events, sent
while foreign JavaScript is on the stack, so A rightly keeps their microtask — it is what makes K
messages one render. At K = 1 and 3 that microtask is the §2 floor (0.04 ms); from K = 10 next is
with or below Solid 1, which renders once per message.

---

## 5. The table benchmark, the static page, and bytes

### 5.1 What the table and the static page measure differently

Both throttle (the table) or run warm in the page (`micro.mjs`), so the 0.05 ms floor is a smaller
share of them, and the table's operations are dominated by mount and list work that §3's curves do
not touch.

### 5.2 The table benchmark

`bench.mjs`, the official throttling, n = 10, script ms median (`r56-table-A.json`). beni-A is the
development build with A only (B and C change nothing the table's operations do: every operation
replaces or edits the whole row list, or moves the selection, which the selector already handles).

| operation | beni | beni `--release` | **beni + A** | Solid 1 | beni + A ÷ Solid 1 |
|---|--:|--:|--:|--:|--:|
| create 1k | 4.68 | 4.64 | **4.67** | 4.88 | 0.96 |
| replace 1k | 11.0 | 11.1 | **10.8** | 12.4 | 0.87 |
| update 10th (4x) | 1.52 | 1.36 | **1.31** | 1.58 | 0.83 |
| select (4x) | 1.14 | 1.17 | **1.00** | 1.62 | 0.62 |
| swap (4x) | 0.96 | 0.93 | **0.87** | 1.61 | 0.54 |
| remove (2x) | 0.53 | 0.50 | **0.47** | 0.55 | 0.86 |
| create 10k | 49.5 | 49.2 | **49.6** | 55.3 | 0.90 |
| append 1k | 5.54 | **5.02** | 5.52 | 5.22 | 1.06 |
| clear (8x) | 21.9 | 22.4 | **22.1** | 23.1 | 0.96 |

**beni already leads Solid 1 on eight of nine operations** (the selector, the ends-first `forKeyed`
and row-mount-through-patch of research 39 did that); A takes 0.1–0.2 ms more off each throttled
one. **Append loses in the development build only** (1.06; release 0.96): a gap of 0.5 ms between
two builds of the same program, which is `--release`'s specialisation, not the renderer, and none of
the proposals touches it.

### 5.3 The static page

The trace sample (`final.json`, `static:50`): **beni 0.159, next 0.096, Solid 1 0.103**,
beni-helper 0.160. In the page (`micro.mjs`, 4 pages × 10, median):

| subject | µs per message, 1x | 4x | first message, ms, 1x | mount, ms, 1x |
|---|--:|--:|--:|--:|
| P2 | 3.90 | 14.0 | 0.320 | 3.38 |
| **beni next** | **4.90** | **18.8** | 0.485 | 4.04 |
| beni `--release` | 5.20 | 19.8 | **0.465** | **3.62** |
| beni helpers | 5.50 | 20.1 | 0.750 | 4.18 |
| beni | 5.65 | 20.8 | 0.620 | 4.15 |
| Solid 1 | 6.45 | 27.3 | 0.495 | 4.23 |
| Solid 2 | 7.45 | 31.2 | 0.740 | 6.12 |

Warm, beni is already below Solid 1 per message; cold (the first message), the development build is
above it (0.620 vs 0.495) and `--release` and next are with it.

### 5.4 Bytes

`match-size.mjs`: terser then brotli 11 of `Main.mjs`, `Rt.mjs` and `List.mjs`, base against
variant, development builds (an estimate of the delta, not of release output):

| change | holes 10 | static 50 | derived | rows |
|---|--:|--:|--:|--:|
| A | +52 | +52 | +50 | +50 |
| B (with A) | −100 | −400 | +39 | — |
| C (with A, and B's row hoist) | — | — | — | +422 |

B **shrinks** output: each value's code is written once, inside `p`, where today it is written in
`view` and again in `m` and `p`. C as prototyped is too large (§6.3).

---

## 6. The proposals, in detail

*Design, and the author's judgement.*

### 6.1 A — render at the end of the browser's dispatch

**Mechanism.** `Rt.beni` gains two flags, `sync` and `inFlush`. The delegated listener (`delegated`;
`listen`'s stub for a non-delegated event, likewise) checks before it bubbles whether the event is
**trusted** (`event.isTrusted`: the browser dispatched it, so nothing but the browser is beneath the
listener) and **no flush is running**. If both hold it sets `sync`; a mount's `send` seeing `sync`
stages its render as today but queues no microtask; when the listener returns it clears `sync` and
flushes if a render is staged. Every other send — a synthetic `el.click()` from page script, a fiber,
a timer, a message from an event the browser fires inside a render (a `blur` when a focused node is
removed) — queues the microtask as today. The prototype is `evflush` in `match-variants.mjs`.

**Why nothing a program can see changes.** HTML performs a microtask checkpoint whenever a callback
returns to an empty JavaScript stack, and a trusted event's listener returns to one. Today's
microtask therefore runs at the very point A flushes: after the delegated listener, before any later
listener of the same event and before any microtask the update queued — the order `backend.md` §15.11
promises ("it queues the program's render and a flush **before** it runs `update`"). Several
handlers in one bubbling walk are one render (one listener call); a burst of synthetic clicks is one
render (§4.6); `Browser.flush` and the after-render phase are unchanged.

**What changes.** `platforms/browser/Rt.beni` only, about ten lines. `backend.md` §15.11's *A message
does not render at once* gains: "…unless it was sent from the listener of an event the browser
dispatched while no flush runs, in which case the flush runs when that listener returns — where the
microtask would have run." W28's substance (staged messages, batched renders, `Browser.flush`, the
after-render phase) stands; only Solid 2's microtask goes where it has no visible effect.

**Cost and risks.** +50 brotli bytes. No compile time. No risk to field identity, determinism or
purity; no `catch` (rule 9): a throwing handler stops the page through `fire`'s guard as today. To
pin: two handlers in one walk render once; a synthetic burst renders once; a trusted event inside a
render does not flush re-entrantly.

### 6.2 B — the template computes its own values, by what they read

**Mechanism.** A root's block carries its **inputs** — the locals its values read, in first-use
order, usually `[model]` — instead of its values. The kind evaluates the values inside `p`,
**grouped by the field paths each reads** — the analysis `language.md` §11.9 already makes for a
row's inputs (MD31: field paths of each captured local, through same-module functions by summary,
else the whole local), applied to every root — and a group runs only when one of its paths is not
`===` the value it saw last:

```js
p: (i, v) => {
  const model = v[0];
  { const x = model.tick; if (x !== i.g0) { i.g0 = x; i.n16.data = x; } }
  { const x = model.name; if (x !== i.g1) { i.g1 = x; i.n19.data = x; i.n24.data = x; /* … */ } }
  { const x = model.items; if (x !== i.g2) { i.g2 = x; i.d0 = Main$top(x); Rt$forKeyed(i.c2, i.d0, Main$key, Main$row, null); } }
}
```

The root **mounts through its patch** (`backend.md` §15.5's `w`): `m` clones, walks, writes the
constants, sets each guard to `undefined` — which no beni value is — and calls `p`. A value that
reads a whole local (`f model`, `f` from another module) is guarded by the local and runs every
render, as today; `--self-profile` counts such values as it counts rows' whole inputs. Constant
values (`Tree.constant`) are written at mount and never compared — today's emitter still compares
the rows page's `"Go"` and `"Swap"` handlers on every render.

**The `let` rule** (what flattens the derived view). A `let` of the function enclosing a root whose
every use is inside that root's values is **a value of that root**, with its own read set: `shown =
top model.items` is computed when `model.items` is not the list it was computed from, and the `For`
that shows it receives the same list and skips. A `let` also used outside the root (in an `if` that
chooses between two roots) stays where it is (§6.5's extension would reach it).

**What it subsumes.** The helper-call skip (§11.6), the component skip (§11.8) and a `For`'s or
`Show`'s early-out become one rule: a call in a hole is a value whose arguments' paths guard it. An
event handler with arguments (`onClick={Open model.page}`) is rebuilt only when `model.page`
changed, where today every render builds a new message and rewrites `$$click`.

**What changes.** Interface 1.5 (`boundary.md` §9.4): for an `expression` root, `Root.inputs`,
`Tree.reads` (each value's paths) and a placing call, `cx.rootValuesGrouped`, the counterpart of
`rowValuesApart` that evaluates the values inside the kind with the inputs bound. `dom.zig` emits `p`
by groups and mounts through it; `ssr` ignores the groups (it renders once). The compiler extends
the read-set analysis from rows to roots (linear in the values) and applies the `let` rule in the
markup record (`checker-v2.md` §25.7) and `Lower`. No runtime change.

**The semantics it needs** (`language.md` §6's markup rows, §11.11). Today each value of a root is
evaluated in source order, once per render. Under B: **a value is evaluated at mount, and later
only in a render in which one of its paths is not `===` what it was at its last evaluation; the
values evaluated in one render run group by group, groups in first-use order, values within a group
in source order.** It is the relaxation §11.11 already makes for rows, helpers and components, for
the same reason: values are pure, so only `Debug.log` can tell — and `--release` refuses `Debug`, so
the two builds still behave alike. An `impure` value is never grouped away (§11.11's effects rule).

**Cost and risks.** Bytes go down (§5.4). Compile time: one more linear pass over each root's
values. Field identity is used exactly as today (W27); determinism holds (first-use order is
input-derived). The analysis can only make a value run more often than needed, never less: a
dependency it cannot see is a guard on the whole local. That is the property Svelte 3's `$:` lacked
(§6.6).

### 6.3 C — a list says what changed since an older version

**Mechanism.** `core/List` gains a protocol point, `xs.$diff(old)`: for two tries of one length and
shape, the positions and items at which they differ, found by descending only into nodes the two do
not share — O(changes × log₃₂ n), since a set copies one path and shares the rest; `null` when they
are not comparable (a plain array, a view, another length or offset). `forKeyed` asks it first when
its inputs and selector are as last time and last render's keys were distinct; if every changed item
keeps its row's key it patches those rows and visits no other. Anything else takes today's path.
The prototype is `listDiff` (`List$trieDiff`, `Rt$edited`).

**What changes.** `core/List.beni`: `$diff` as a `Js.method` on the trie header beside `$plain`
(`backend.md` §4's protocol; §15.5 reserved a fourth point, `$chunks()`, for the leaf walk).
`Rt.beni`: a guard at the head of `forKeyed`'s render branch and the helper. No compiler change.

**Cost and risks.** +404 brotli as prototyped, on every page that reaches a trie and a keyed list —
too much; written in beni, specialised by `--release` and with the head and tail cases folded into
the tree walk, the slice must bring it under 200 or report why not. A `$diff` that missed a change
would leave a stale row, so its fixtures are a property test against an element-wise comparison over
chains of `set`, `update`, `push`, `swap` and views, and `browser/dom/` pages for the near misses (a
changed key, a swap, a length change).

### 6.4 Considered, not recommended

- **Render synchronously at every `send`** (Solid 1's order): closes the floor as A does but renders
  once per message, giving up the burst, where beni leads both Solids from K = 30.
- **A signal graph under TEA** (research 29 §8's P4): measured there equal to Solid 2 on every
  operation and 12× the bytes. B gets the skipping from the reads, without a graph.
- **Memo per call site for every `Html`-returning function** (B's extension): a hidden memo slot per
  call site, so a helper's `let`s are kept across renders even when control flow uses them. Not
  prototyped; worth specifying after B if a real program needs it.
- **A wide record as a persistent structure** (fields in chunks), for the 1 024-field model: every
  record operation's code changes for a shape nobody writes on purpose. Refused on complexity.
- **Updating the model in place** when the old one is provably dead (research 55). B removes one
  obstacle research 55's preface names (the renderer would keep values, not the model), but the proof
  needs whole-program alias analysis through `Cmd` closures and programs that keep old models (undo).
  A research question, not a slice.
- **Trimming the dispatch path** (the `${key}X`/`${key}F` strings made per event, the guard per
  handler): `abl-nofinally` is inside the noise (0.135 vs 0.142), and A already closes the floor. It
  is a candidate for the long list's residual (§4.2), unmeasured.

### 6.5 Svelte 3's invalidation, and why B is not it

`plans/browser-decisions.md`'s disagreement 14 asks why Svelte 5 replaced Svelte 3/4's compile-time
invalidation with signals, and the owner asked for that to be answered before W42 is built. **This
report did not answer it from primary sources** (no Svelte source is vendored; experiment X3 stays
open). By construction, B differs from Svelte 3/4 in three ways: it never decides from the analysis
alone *whether* something changed — it compares values, so an unseen dependency costs a re-evaluation,
not a stale screen; it has no bit budget (a guard is a field, not a bit of a 31-bit mask); and its
state is immutable, so there is no mutation for a compiler to miss. Whether those were Svelte's
reasons is X3's to confirm.

*Amended 2026-10-04: X3, read from primary sources, before slice B was built* (the owner's standing
condition, `plans/browser-decisions.md` disagreement 14). Svelte's own account of the move, in its
words:

- **The runes announcement** (the Svelte team, 20 September 2023,
  [svelte.dev/blog/runes](https://svelte.dev/blog/runes)): compile-time reactivity *"only works for
  `let` declarations at the top level of a component, which can cause confusion. Having code behave
  one way inside `.svelte` files and another inside `.js` can make it hard to refactor code"*. Its
  example: `const multiplyByHeight = (width) => width * height;` then
  `$: area = multiplyByHeight(width);` — *"Because the `$: area = ...` declaration can only 'see'
  `width`, it won't be recalculated when `height` changes. As a result, code is hard to refactor,
  and understanding the intricacies of when Svelte chooses to update which values can become rather
  tricky beyond a certain level of complexity."* And the gain it names for signals: *"changes to a
  value inside a large list needn't invalidate all the other members of the list."*
- **The Svelte 5 migration guide**, section *`$:` → `$derived`/`$effect`*
  ([svelte.dev/docs/svelte/v5-migration-guide](https://svelte.dev/docs/svelte/v5-migration-guide)):
  *"`$:` dependencies were determined through static analysis of the dependencies. This worked in
  most cases, but could break in subtle ways during a refactoring where dependencies would be for
  example moved into a function and no longer be visible as a result"*; *"`$:` only updated directly
  before rendering, which meant you could read stale values in-between rerenders"*; *"`$:` only ran
  once per tick, which meant that statements may run less often than you think"*; *"`$:` statements
  were also ordered by using static analysis of the dependencies. In some cases there could be ties
  and the ordering would be wrong as a result, needing manual interventions"*; and TypeScript.
- **The legacy reference for `$:`**
  ([svelte.dev/docs/svelte/legacy-reactive-assignments](https://svelte.dev/docs/svelte/legacy-reactive-assignments)):
  *"The dependencies of a `$:` statement are determined at compile time — they are whichever
  variables are referenced (but not assigned to) inside the statement"*, so `$: doubled = double()`
  does not re-run when `count` changes; statements are *"ordered topologically"*; and a mutation of
  an object or array that is not an assignment does not invalidate it.

**What applies to B, problem by problem** (the author's reading):

1. *A dependency hidden in a function is invisible, and the value goes stale* — the problem B could
   share, and the one it must not. Svelte's analysis decided **whether** to recompute from the
   names written in the statement, and a function that read `height` from its closure or from
   component state was a read nobody saw. In beni a function reads only its arguments and immutable
   top-level values: there is no component state, no assignment, no closure over anything that
   changes between renders except the locals of the function being rendered. So a value's reads
   are exactly the locals it uses, and B's analysis follows each: a field path where the use is a
   field access or an argument of a same-module function whose summary says which fields it reads
   (the analysis rows already have, `language.md` §11.9), **the whole local everywhere else** — a
   call of another module's function, a `case`, a record, and a call of a *local* function, which is
   itself a local (a closure made in this render, compared by identity, so every render runs it).
   Where the analysis cannot see, it compares more, never less: stale is not a possible outcome,
   only a re-evaluation. B's slice must hold that line in its fixtures (a read through a helper, a
   local function, a `case`, a record, another module), and a value whose reads the compiler cannot
   bound — evidence a `where` clause passes, a `?` that returns from the enclosing function — is not
   grouped at all.
2. *Stale values between renders; once per tick; run less often than you think* — `$:` values were
   program state other code could read. B's values are read only by the render that computes them
   (B2 moves a `let` only when every use is inside the root), so there is no "between renders" in
   which to see one.
3. *Ordering ties* — `$:` statements assigned state, so their order mattered. B's values are pure;
   only `Debug` can see their order, which the owner accepted (`language.md` §11.11, amended
   2026-10-04).
4. *Mutation is not assignment* — beni has no mutation; an untouched field is the same value (W27,
   §11.12), which is what B's guards compare.
5. *Top level only; `.svelte` and `.js` behave differently* — B has no syntax and no second
   semantics: a root in a helper module, a component, a nested root are grouped by the same rule,
   and the page is the same whether or not a value is grouped. Only the cost differs.
6. *A large list invalidates every member* — not B's to fix: that is C (§6.3).

**Verdict: none of Svelte's reasons is a problem B shares**, provided its analysis keeps the
"whole local when unsure" rule and compares rather than trusts; the one hazard Svelte names that B
could reproduce — a dependency hidden in a function — cannot arise in beni for a top-level function,
and for a local function it is a guard on the function value itself. B is built.

---

## 7. Recommendation, and the order to build it in

*Opinion, from §2–§5.*

**Build A, then B, then C.** A is ten lines of one runtime file, changes nothing a program can see,
and moves every sweep's small sizes, the static page and the throttled table operations onto or below
Solid 1. B is the architectural change the brief invited — the template computes its own values from
what they read — and it is what turns beni's two linear curves flat, while shrinking output. C is a
library change with one runtime hook and closes the long list's curve. None asks the programmer for
anything; B makes the natural derived view the fast one.

Each slice: specified first (rule 1), fixtures that fail before it (rule 3), and this report's
harness before and after on every benchmark, Solid 2 back in the batch, before the next starts.

1. **A.** Spec: `backend.md` §15.11 (§6.1's sentence); a note on W28. Build: `Rt.beni`. Fixtures in
   `browser/tea/`: two handlers in one walk render once; a synthetic burst renders once; a trusted
   `focus`/`blur` inside a render renders in the next flush; `Browser.flush` in a handler unchanged.
2. **B1 — roots carry inputs; values placed in the kind by read set.** Spec: interface 1.5
   (`boundary.md` §9.4.2, §9.4.6), `backend.md` §15.3's hole table and §15.4 (a block's `v` is the
   root's inputs), `language.md` §6's markup rows and §11.11. Build: the read-set analysis from rows
   to roots (`frontend.md` §9.7's machinery); `dom.zig`'s grouped `p` and mount through it. Fixtures:
   `emit/dom/` goldens of a grouped kind; `browser/dom/` pages whose `Debug.log`s show which values
   run per render — one field changed, two, a whole local, a handler with an argument, a helper call,
   a component; every existing golden unchanged in what the page shows.
3. **B2 — the `let` rule.** Spec: `language.md` §11.11. Build: the markup record and `Lower`.
   Fixtures: the derived page as a `browser/dom/` page whose projection logs once per change of the
   list and not per message; a `let` used outside the root that still runs per render.
4. **C.** Spec: `backend.md` §4 and §15.5. Build: `core/List.beni`, `Rt.beni`. Fixtures: the `run/`
   property test of §6.3; a `browser/dom/` page editing one row of a trie-backed list that logs which
   rows run; the near misses taking the full pass. Bytes held under +200 brotli.
5. **Re-measure everything** and write the new scaling report.

Together (§5.4's estimates): +50 brotli for A on every page, −100 to −400 for B on the pages
measured, +200–400 for C where a keyed list reaches a trie. No new syntax, no new decision for the
programmer, no change to any guarantee.

## 8. What remains, and questions for the owner

1. **Model width at 1 024 fields.** The record copy (§3.3); parity needs an update that does not
   copy, which is research 55's open question, not a slice. Up to 256 fields next is with Solid 1.
   *Is a 1 024-field model a target, or is 256 the end of the idiomatic range?*
2. **A long list's one-row change: 0.03–0.04 ms left** (§4.2), in the dispatch and `List.update`'s
   trie set run cold, not the render. *Worth a follow-up slice (a specialised trie set, the dispatch
   trims), measured against this residual?* The author would take it after C.
3. **Messages sent outside a trusted dispatch** — page script's synthetic clicks (the burst at K = 1),
   timers, fibers — still render in a microtask and pay the §2 floor in a trace. *Extend A's rule to
   beni's own host callbacks* (a timer or a fiber resumption that beni registered also returns to an
   empty stack, so the same argument holds)? The author recommends it as a follow-up; it was not
   prototyped. Synthetic events from foreign script keep the microtask, for batching.
4. **B's evaluation order** (§6.2): values evaluated by group, not in source order across groups.
   *Acceptable as `language.md` §11.11's amendment, given `--release` refuses `Debug`?* And X3 (§6.5)
   is still to be read before W42's rung is built.

---

## 9. Built, and measured (2026-10-04)

*Facts: what was built, and the measurements of the built compiler.* A, B (both parts) and C were
built as §6 proposes, each specified first (`backend.md` §15.11 *A render at the end of a turn*,
§15.4 *A root computes its own values* and *The `let` rule*, §4 *a fourth point* and §15.5;
`boundary.md` §9.4.6 version 1.5; `language.md` §11.11). **A and B are on the slice branch; C is
not**: it misses its byte budget (§9.3) and is kept on a branch of its own,
`r56-slice-C-over-budget`, for the owner to decide.

### 9.1 Method

One batch for all four compilers, so each slice is measured against the one before it under the
same noise: `scaling.mjs --full` gained `--variants=<name>=<beni>,…`, a subject per other beni
binary, built from the same generated programs (`results/2026-10-04-r56-slices.json`: `beni` is
the compiler before A, `beni-A`, `beni-B` and `beni-C` the three slices, ReleaseFast builds).
The table benchmark is `bench.mjs` with each compiler's development build of `apps/beni` as an
extra subject (`…-slices-table.json`), the static page `micro.mjs` (`…-slices-static.json`) and
`match.mjs --cases=static:50` (`…-slices-static-trace.json`). Chrome pinned to CPUs 8–15, nothing
else running, development builds unless named; medians.

### 9.2 Sweeps: script ms per message (2 pages × 4 samples)

| point | before | A | **B** | C | Solid 1 |
|---|--:|--:|--:|--:|--:|
| holes 10 | 0.144 | 0.089 | **0.093** | 0.085 | 0.084 |
| holes 1 000 | 0.199 | 0.168 | **0.096** | 0.104 | 0.083 |
| holes 10 000 | 0.839 | 0.768 | **0.111** | 0.107 | 0.085 |
| rows 1 000, change | 0.184 | 0.133 | **0.141** | 0.113 | 0.090 |
| rows 30 000, change | 0.460 | 0.419 | **0.456** | 0.158 | 0.120 |
| rows 30 000, swap | 0.942 | 0.876 | **0.794** | 0.840 | 5.36 |
| width 256 | 0.166 | 0.123 | **0.120** | 0.115 | 0.090 |
| width 1 024 | 0.415 | 0.409 | **0.349** | 0.373 | 0.096 |
| depth 16 | 0.163 | 0.110 | **0.123** | 0.108 | 0.123 |
| derived 1 000 | 0.302 | 0.237 | **0.089** | 0.084 | 0.083 |
| derived 100 000 | 6.63 | 6.66 | **0.092** | 0.089 | 0.083 |
| burst 1 | 0.223 | 0.237 | **0.170** | 0.178 | 0.121 |
| burst 100 | 0.899 | 0.913 | **0.794** | 0.816 | 1.15 |
| stream 1 (per message) | 0.120 | 0.118 | **0.072** | 0.071 | 0.071 |

Every point is in the JSON; these are the ones §0.1 names. **A takes the floor off** (holes 10:
0.144 → 0.089; every width and depth point to Solid 1's); **B flattens view size and the derived
view** (holes 10 000: 0.768 → 0.111; derived 100 000: 6.66 → 0.092, against Solid 1's 0.083);
**C flattens the long list's edit** (30 000 rows: 0.456 → 0.158).

### 9.3 Bytes, release builds, brotli

| page | before | A | B | C |
|---|--:|--:|--:|--:|
| table app | 5 571 | 5 593 (+22) | 5 487 (−106) | 5 757 (+270) |
| static page | 2 562 | 2 664 (+102) | 2 668 (+4) | — |
| holes 10 | 1 217 | 1 258 (+41) | 1 245 (−13) | — |
| holes 1 000 | 18 756 | 18 812 (+56) | 8 524 (−10 288) | — |
| rows 1 000 | 3 992 | 4 042 (+50) | 3 852 (−190) | 4 148 (+296) |
| derived 1 000 | 3 761 | 3 816 (+55) | 3 657 (−159) | 3 777 (+120) |
| width 256 | 6 215 | 6 133 (−82) | 5 598 (−535) | — |

A costs 41–102 bytes on pages with events (the static page's +102 is the most; `emit/release/split/
HolesPage` +59; a page with no event, 0). B shrinks every page but the static one (+4), as §5.4
estimated. **C costs +270 to +296 on a page with a trie and a keyed list, +120 on a page with a
keyed list only, and +200 on any release program that makes a trie** — `emit/release/app/SpecMaybe`
825 → 1 025 — because the protocol puts `$diff` in every trie header, so every program that writes
a list of 32 or more ships it, renderer or not. Its budget was 200. The function was cut to the
tree and the tail (the head is not walked) and made a plain function of the list (no method
closure) before this measurement; a hand-minimal version of the same two pieces, written as
JavaScript, is still about 230 brotli bytes, so the budget is not within reach of this design.

### 9.4 The table benchmark and the static page

Table, script ms, n = 10 (`report.mjs`): B against Solid 1 — create 1k 4.54 / 4.99, replace 10.2 /
11.9, update every 10th 1.23 / 1.58, select 0.82 / 1.37, swap 0.87 / 1.69, remove 0.48 / 0.56,
create 10k 49.6 / 55.4, **append 5.64 / 5.20** (release 5.06), clear 22.8 / 23.7. The compiler
before A: 4.75, 10.1, 1.42, 1.12, 1.24, 0.53, 49.2, 5.56, 22.0. The static page, in-page µs per
message: B 4.82, release 5.05, before 5.50, Solid 1 6.85; first message 0.507 ms (release 0.382)
against Solid 1's 0.468. In a trace (`static:50`): B 0.105, release 0.091, Solid 1 0.094.

### 9.5 Where beni does not yet match Solid 1 (B, the slice branch)

- **A long keyed list's one-row edit**: 0.141 at 1 000 rows, 0.456 at 30 000 (Solid 1: 0.090,
  0.120). C closes most of it (0.113, 0.158) and is not landed (§9.3); what remains with C is §4.2's
  residual, the dispatch and `List.update`'s trie copy (0.03–0.04 ms), as predicted.
- **The 1 024-field model**: 0.349 against 0.096, the record copy (§3.3); out of scope.
- **A burst of one to three synthetic clicks**: 0.170 against 0.121 at K = 1, the microtask kept on
  purpose (§4.6); from K = 10 beni is below Solid 1.
- **Large views, a little**: holes 1 000–10 000 at 0.096–0.111 against 0.083–0.085 — one test per
  group and the per-op tests left inside a group that reads several paths.
- **The table's append** in the development build (5.64 / 5.20); `--release` 5.06.

### 9.6 After the review: the fixes, re-measured

The review of A and B found markup nested in a value no longer patched on every render (a
controlled input in an `if` hole or a `let` of markup kept a rejected edit; `Random.value` in a
view that reads nothing, or nested, stopped drawing), a `let` two roots could take evaluated by
both, a constant `raw` attribute written again whenever its group reran, a cubic pass over a
view's `let`s, and — older than slice B — helper calls and components skipped even when their
markup held a controlled input or their call an effect. Each is fixed with a page fixture that fails
on the compiler before it (`browser/dom/StatefulNested`, `EveryRenderNested`, `EveryRenderTop`,
`ConstantWriteOnce`, `LetOneOwner`, `LetChain` — 79.9 billion instructions before, inside the
budget after — `SkippedCallsLive` and `HelperSkip`), specified in `language.md` §11.11, `boundary.md`
§9.4.6 and `backend.md` §15.4 as amended after review. **Still open, and older than this work:** a `For` row or a `Show` body that a render skips — its item and inputs unchanged — is not patched, so a controlled input inside a row keeps an edit `update` rejected; the same restate would close it, and it is not done here. *(Closed by the second review, §9.8.)*

Same batch, the slice-B compiler against the fixed one (`results/2026-10-04-r56-review-fixes.json`,
2 pages × 4 samples; Solid 1 beside them), script ms, median:

| point | B | fixed | Solid 1 |
|---|--:|--:|--:|
| holes 10 | 0.090 | 0.091 | 0.084 |
| holes 1 000 | 0.098 | 0.097 | 0.082 |
| holes 10 000 | 0.116 | 0.111 | 0.095 |
| rows 1 000, change | 0.139 | 0.133 | 0.095 |
| derived 100 000 | 0.093 | 0.091 | 0.090 |

The table's update-every-10th, n = 30 (`…-review-fixes-update.json`): A 1.07 [0.96–1.36], B 1.34
[1.08–1.51], fixed 1.15 [1.03–1.43], Solid 1 1.74 — the three beni builds' interquartile ranges
overlap, so B's apparent cost on this operation is not established; select, n = 20: B 0.82, fixed
0.74, Solid 1 1.54. **The fixes cost no measured speed.** Bytes: the empty page does not move; a
page that maps markup (`Html.map`) or calls a helper or component pays `restate` (HolesPage +49
brotli).

### 9.7 Slice C, option 2: how the renderer reaches a core function (proposal)

*Opinion, for the specification.* The owner chose to take `$diff` off the trie header so that
only a page with a keyed list pays for it. The renderer is `Rt.beni`, a platform module; the
function must read a trie's private fields, which `backend.md` §4 keeps to `core/List` (readers
see `length`, `Array.isArray` and `$plain()` only). The options under `boundary.md`'s rules:

1. **A public `List` function** (`List.changes`). Refused: it is not a function of its arguments'
   values — two equal lists answer differently by where they came from — so a program could
   observe sharing, which beni promises it cannot (`language.md` §11.12).
2. **A core-private value the code generator names** (as it names `unsafeGet`). Refused: those are
   for code the compiler writes, and `Rt.beni` is source, which can name only what an interface
   exposes.
3. **A privileged core module, `Js.Lists`, importable only where `Js` is** (recommended). `Js` is
   already refused outside platform packages (`check/bad/JsOutsidePlatform`); the rule extends to
   the modules under it. `core/Js/Lists.beni` holds `diff : List a, List a → Js.Value` — the
   `[ position, element, … ]` array or null of §4's *fourth point* — written in beni over `Js`,
   reading the header's fields, and the protocol section says this module, like `List`, may read
   them. `Rt.forKeyed` imports it; reachability keeps it exactly where a keyed `For` is rendered,
   and a program that makes tries without one ships none of it.

**Bytes**, from the C branch (`r56-slice-C-over-budget`): the release rows page paid +296 brotli
with `$diff` a key of every trie header and the functions in `List`; the key itself is about 10
of those, so option 3 costs **≈ 285 bytes on a page with a keyed list and a trie, and 0 on any
other** (the C branch charged +200 to every program that builds a trie, `emit/release/app/
SpecMaybe` 825 → 1 025). That is still over the 200 budget. Levers, each to be measured one at a
time before the slice: walk the tail as part of the last leaf's loop rather than a call of its own
(≈ 20); fold `edited`'s key check into `forKeyed`'s existing start-rows pass (≈ 30); answer only
the first 32 changes and take the full pass beyond (no saving in bytes, a bound on work). Whether
those reach 200 is not known until they are written; if they do not, the decision returns to the
owner with the measured figure.

### 9.8 After the second review: restate, not evaluate again

The second review found §9.6's mechanism incomplete: markup reached through a helper call that is
not itself the hole (`{if m.open then field "a" m.text else <span />}`, `Html.map (field …)`, a
`let` or a `case` branch holding one) was still frozen, a top-level constant placed again was
never reconciled (older than this work), a `For` row or `Show` body skipped with unchanged inputs
neither, and §9.6's rule that a helper or component op runs every render had made calls with
render-built arguments run every render. One design replaces §9.6's static one
(`backend.md` §15.4, *A skipped group restates its slots*; `boundary.md` §9.4.6;
`language.md` §11.11, all amended): a value is never evaluated again for the markup it holds. A
skipped group's `else` restates its slots; `Rt.patch` handed the very block it shows patches it
again when its kind is live; a `Show` left as it was restates its body; a `For` whose row
function is live or makes blocks restates its rows. Helper and component calls are back in their
groups (only an impure one runs every render), so `DomComponents` calls `Card$view` only when
its group's paths change. Fixtures: `browser/dom/SkippedMarkupLive` (ten inputs, each
rejected; every one kept its edit on the compiler before) and `HelperSkip`, whose `boxed` now logs
each call and is not called when only the count changes.

A first cut kept each list's row function in its slot for the restate; the release optimiser
then could not see the table app's row objects whole and lost their specialisation (table app
5 556 → 5 730 brotli). The slot now keeps only a live row function's `p`: 5 615 (+59), the rest
being `restate` itself and the `else` branches. `emit/release/split/HolesPage` 1 796 → 1 844
(+48); the empty page does not move (446).

Same batch, the §9.6 compiler against this one (`results/2026-10-04-r56-review2.json`, 2 pages × 4
samples), script ms, median:

| point | §9.6 | restate | Solid 1 |
|---|--:|--:|--:|
| holes 10 | 0.077 | 0.073 | 0.071 |
| holes 1 000 | 0.081 | 0.069 | 0.074 |
| holes 10 000 | 0.101 | 0.085 | 0.077 |
| rows 1 000, change | 0.122 | 0.120 | 0.084 |
| rows 30 000, change | 0.434 | 0.434 | 0.096 |
| derived 1 000 | 0.075 | 0.068 | 0.066 |
| derived 100 000 | 0.075 | 0.076 | 0.071 |

(`rows 30 000, swap` is bimodal page to page for both compilers, 0.80–1.30, and is not read.) The
table, `…-review2-update.json` and `…-review2-select.json`: update every 10th, n = 30, §9.6 1.04
[0.98–1.22], restate 1.00 [0.84–1.09], Solid 1 1.48; select, n = 20, 0.61 [0.47–0.76], 0.72
[0.57–0.93], Solid 1 1.21 — interquartile ranges overlap. *Corrected by the third review (§9.9):*
the claim that followed here — "a list whose rows are not live is not walked" — was false. A
row was live whenever its markup held a slot, a block row's and a `List Html` hole's always, and
a live compiled row was restated by its `p`, which evaluates every value of the row; a list
restated every live row after its pass, the rows it had just patched included. None of the
points above has such a row, which is why they did not move.

### 9.9 After the third review: what is live is decided at run time

The third review found four costs §9.8 introduced: a live compiled row re-evaluated in full on
every render (each `Debug.log` in a row printed on every message), every live row patched twice
in a render that patched it, a list of blocks walked on every render whatever it held, and every
slot under a skipped group visited. One change answers all four (`backend.md` §15.4, as amended
after the third review): **liveness is a property of the instance, kept at run time** (`i.l`,
written by its kind's `p` from its slots; a slot's `l`, a list's `w`), so a restate visits only
instances that are live — under a tree of helpers none of which holds an input, nothing; a row
compiled in place is restated by its row function's `r`, which writes its `stateful` attributes
from the values the row keeps and restates its slots, **evaluating nothing**; and a list's pass
stamps the live rows it patched and restates only the others. A kind or row function that cannot
be live carries no `l` and the runtime keeps no bookkeeping for it, and a list's `w` is the row
walk itself, so a page with no list ships none of it. Fixture: `browser/dom/LiveRowsOnce` — rows
with a controlled input, a helper and `Debug.log`, keyed and positional; on the §9.8 compiler
every message printed every row and a mount printed each twice, now a row prints only when its
item changed.

Same batch, four subjects — "master" (*corrected in §9.10:* the slice branch at `2bac01c1f`, before §9.8, not `master`), §9.8 (`246bd8b74`), now, Solid 1
— (`results/2026-10-04-r56-review3.json`, `…-review3-helper-rows.json`, 2 pages × 4 samples),
script ms, median. Three sweeps are new (`bench/ui/apps/scaling/`): `live`, N keyed rows each
holding a controlled input and a helper's markup, `helperRows`, the same with the input replaced
by text, and `tree`, a recursive helper D levels deep (2^(D+1) − 1 calls); in each an unrelated
counter ticks.

| point | master | §9.8 | now | Solid 1 |
|---|--:|--:|--:|--:|
| holes 10 | 0.078 | 0.074 | 0.074 | 0.071 |
| holes 1 000 | 0.071 | 0.075 | 0.077 | 0.074 |
| holes 10 000 | 0.091 | 0.088 | 0.087 | 0.080 |
| rows 1 000, change | 0.126 | 0.116 | 0.121 | 0.082 |
| rows 30 000, change | 0.423 | 0.446 | 0.428 | 0.098 |
| derived 100 000 | 0.072 | 0.072 | 0.073 | 0.075 |
| helper rows 1 000 | 0.074 | 0.094 | 0.074 | 0.075 |
| helper rows 10 000 | 0.085 | 0.240 | 0.086 | 0.081 |
| helper tree, 8 191 calls | 0.171 | 0.177 | 0.081 | 0.082 |
| live rows 100 | 0.067 | 0.092 | 0.123 | 0.073 |
| live rows 1 000 | 0.073 | 0.303 | 0.255 | 0.072 |
| live rows 10 000 | 0.090 | 2.987 | 2.247 | 0.088 |

A tree of helpers and rows that hold only a helper now cost what master's do — master never
visited them, and was wrong for the ones that held an input. **Live rows still cost a visit per
row per render**: 0.22 µs a row — its `r`, the read of its input's `value` from the page to
compare with the one the row keeps, and its helper slot's check; the same rows without the input
are not visited at all (helper rows above), so the visit is the whole cost. That is the price of the guarantee as specified — a
controlled input shows the model after every render, wherever it stands — paid by every input on
the page on every message, where master paid nothing and kept a rejected edit, and Solid keeps
no such guarantee. Making it proportional to the inputs the user actually edited (an `input`
listener that records the edited elements, reconciled after the render) is a change of §15.3's
contract, recorded here as the next step rather than taken.

The table benchmark, n = 10 (`…-review3-table.json`; n = 30 for update and select,
`…-review3-update-select.json`): master / §9.8 / now / Solid 1 — create 1k 3.59 / 3.48 / 3.48 /
3.80, replace 7.46 / 7.51 / 7.47 / 8.72, update every 10th 1.11 / 1.11 / 1.12 / 1.49, select 0.76 /
0.69 / 0.71 / 1.30, swap 0.70 / 0.73 / 0.85 / 1.27, remove 0.42 / 0.45 / 0.44 / 0.50, create 10k
38.1 / 37.9 / 38.0 / 43.3, append 4.19 / 4.23 / 4.21 / 3.95, clear 16.5 / 15.9 / 15.3 / 16.3 — every
beni interquartile range overlaps the others'. Bytes, release, brotli: the table app 5 556 /
5 615 / 5 639, `emit/release/split/HolesPage` 1 796 / 1 844 / 1 870, the empty page 446 throughout.

### 9.10 As merged, against Solid 1 and vanilla JS (2026-10-08)

*Facts.* A and B with every review fix, as merged to `master` (`84de8d94d`), measured for the first
time, with vanilla JavaScript on every sweep as the floor. The full tables, the method and the
caveats are [`bench/ui/results/2026-10-08-scaling.md`](../../../bench/ui/results/2026-10-08-scaling.md).
2 pages × 4 samples per point, 1x, script ms, median.

*A correction to §9.9:* its column headed "master" is the slice branch at `2bac01c1f`, which already
had A, B and §9.6's fixes. It is not the `master` of that day. The live-rows, helper-rows and
helper-tree sweeps have never been run on the compiler before A.

| point | beni | Solid 1 | vanilla | beni ÷ Solid 1 |
|---|--:|--:|--:|--:|
| holes 10 | 0.103 | 0.092 | 0.044 | 1.12 |
| holes 10 000 | 0.124 | 0.098 | 0.045 | 1.27 |
| rows 1 000, change | 0.148 | 0.091 | 0.049 | 1.63 |
| rows 30 000, change | 0.442 | 0.117 | 0.061 | 3.78 |
| rows 30 000, swap | 0.835 | 5.38 | 0.101 | 0.16 |
| width 256 | 0.105 | 0.106 | 0.041 | 0.99 |
| width 1 024 | 0.377 | 0.097 | 0.043 | 3.89 |
| depth 16 | 0.121 | 0.115 | 0.043 | 1.05 |
| depth 128 | 0.306 | 0.210 | 0.042 | 1.46 |
| derived 100 000 | 0.094 | 0.093 | 0.044 | 1.01 |
| live rows 1 000 | 0.300 | 0.088 | 0.043 | 3.41 |
| live rows 10 000 | 2.42 | 0.108 | 0.049 | 22.4 |
| helper rows 10 000 | 0.099 | 0.100 | 0.046 | 0.99 |
| helper tree, D = 12 | 0.088 | 0.091 | 0.045 | 0.97 |
| burst 1 | 0.179 | 0.123 | 0.054 | 1.46 |
| burst 100 | 0.836 | 1.19 | 0.738 | 0.70 |

The table benchmark (n = 10, script ms; beni, `--release`, Solid 1, vanilla):
- create 1k: 4.55, 4.65, 4.90, 4.67
- replace: 10.1, 10.5, 11.8, 9.68
- update every 10th: 1.45, 1.51, 1.68, 0.71
- select: 0.90, 0.99, 1.70, 1.39
- swap: 0.97, 0.95, 1.76, 0.39
- remove: 0.48, 0.47, 0.56, 0.53
- create 10k: 49.4, 48.9, 55.5, 47.6
- append: 5.62, 5.00, 5.23, 4.88
- clear: 22.4, 21.6, 22.5, 21.2

The development build is ahead of Solid 1 on seven operations, level on clear and behind on append.
The release build is ahead on all nine.

**What the batch says.**
- **Where beni matches Solid 1, both are about 2× vanilla** (0.04–0.05 ms per message).
- **§9.5's list still stands, with three changes:**
  - **Live rows now lead it.** 0.24 µs a row, 22× Solid 1 at 10 000 rows; the next slice.
  - **A deep model (64–128 levels) is 1.3–1.5× Solid 1.** This report did not name it before.
  - **Large views are 1.20–1.27× at 1 000–10 000 holes.** Earlier batches put them nearer.
- **The long keyed list's one-row edit is 3.8× at 30 000 rows,** as before, until slice C lands.

## Appendix: reproducing

```sh
cd bench/ui && nix develop ../..#browser
node build.mjs                                   # the table's and the static page's builds
node scaling.mjs --build-only --full             # the sweeps' programs
(cd apps/solid1 && node build-static.mjs)        # the static page on Solid 1
node match.mjs --cases=holes:10 --subjects=beni,solid1,vanillajs,vanilla-microtask,abl-nomicro,A-evflush \
  --pages=4 --samples=6 --taskset=8-15            # §2
node match.mjs --cases=<sweep>:<param>[:<op>],… --subjects=beni,next,solid1 --pages=2 --samples=4 \
  --taskset=8-15 --out=results/<file>.json        # §4
node match-table.mjs --variants=A-evflush         # registers beni-A-evflush for bench.mjs
node bench.mjs --subjects=beni,beni-release,beni-A-evflush,solid1 --n=10 --taskset=8-15
node match-size.mjs                               # §5.4
```

Files: `bench/ui/match.mjs` (harness), `match-variants.mjs` (every prototype, as edits),
`match-report.mjs`, `match-size.mjs`, `match-table.mjs`, `apps/solid1/build-static.mjs`. All are
prototypes and instruments; none is a gate.
