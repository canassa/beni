# 59 — Where a message's time goes, and where the bytes go

*2026-10-08. A measurement and attribution study, asked for by research 58 §9 step 0 and §2.4.
Nothing under `src/`, `core/` or `platforms/` changed. Every ablation below is a hand edit of a
copy of the emitted JavaScript (`bench/ui/out/plumbing/`, as research 56 §2.3 made them), never a
build of the compiler, and none is proposed as written. Facts are in §1–§4; where a paragraph
says what a removal would need, that is the author's reading, and says so.*

**Questions.**
- **Q1.** Where does beni's extra time per message go, against P2 (hand-written TEA: one spread,
  compare-all, synchronous render), on the 10-hole page?
- **Q2.** Is model width 1 024 slow because of a V8 limit (research 58 §2.4)?
- **Q3.** Why does depth 128 cost 0.306 ms?
- **Q4.** Where do beni's `--release` bytes go: the table app, and per field, level and hole?

---

## 0. Findings

1. **The "0.035 ms plumbing constant" is mostly the Chrome trace, not beni.** On the 10-hole page,
   in the same batch: traced, beni 0.098 ms against P2's 0.063 (35 µs apart); untraced, timed in
   the page around real, trusted clicks, beni **19.4 µs** against P2's **11.7** and vanilla's
   **10.1** — **7.7 µs** apart. A trace multiplies every subject's script time by about 4–5 on this
   page (vanilla 10 → 48 µs), so it multiplies the gap too. Hot (thousands of clicks in a loop in
   the page) the gap is **0.7 µs**. Untraced, beni is faster than Solid 1 (26.5 µs) on real
   clicks; traced they tie. `--release` makes no difference to the constant.
2. **Attribution of the 7.7 µs** (real clicks 6–120, untraced; an ablation ladder whose steps sum to
   the gap, reproduced twice, cross-checked by a CPU profile):

   | piece | µs per message |
   |---|--:|
   | property names built per event (`` `$$${type}` ``, `` `${key}F` ``, `` `${key}X` ``) and looked up with the built strings | 1.9 |
   | walking past the handler to the document, after the handler fired | 1.2 |
   | the render queue: `waiting`, the `queued` array, `scheduled`, the flush's swap and loop | 1.4 |
   | `view`'s two objects and the generic root patch (`childHtml`, `patch`, `held`) | 1.3 |
   | `Html.map`'s `$$cx` lookup and `through` | 0.6 |
   | `turn`'s closure | 0.4 |
   | the delegated path itself: a document listener, `bubble`, `fire`, `$$root`, against a listener on the button | 2.1 |
   | beni's `update` and template patch against P2's | 0.5 |
   | `.disabled`, `mountAbove`, the `X` lookup, the `dead` check | ≈ 0 (−0.5 to +0.3 each, noise) |
   | the three `try … finally` guards | **not a cost** (removing them made it 1.2 µs slower, reproduced) |

   The rows sum to 7.7 µs with the guards and the near-zero rows counted at their measured values (−1.2 and −0.4). Every piece but delegation itself is removable by a change to the runtime (`Rt.beni`) or the
   emitter with no guarantee given up (§1.6). Delegation is Solid's choice too and is kept.
3. **Q2: research 58's claim holds.** V8's `kMaxNumberOfDescriptors` is `(1 << 10) − 4 = 1 020`
   (`src/objects/property-details.h:249`). A record of 1 020 fields spreads in 1.0 µs in Chrome;
   one of 1 021 is in dictionary mode and spreads in 165 µs (×161; Node: ×217), and
   `%HasFastProperties` flips at exactly 1 021. On the page, beni costs 0.218 ms at 1 020 fields and
   0.407 at 1 024. But the sweep is **not flat below the cliff**: beni grows from 0.132 ms at 256
   fields to 0.253 at 1 000, where Solid 1 stays at 0.10; a profile puts that on the root patch's
   1 000 compares, not the copy (§2).
4. **Q3: depth is linear, not quadratic, and not the path copy.** P2 does the same 128 spreads and
   128 patches in 21 µs a real click (6.5 hot); beni takes 99 (21 hot). Per level beni runs four
   frames — a patch function, a view helper and an update helper that are distinct for every level,
   and a megamorphic `b.t.p(…)` call through `Rt$patch` — and allocates `{t, v: [n]}` twice over;
   each distinct function runs once per message and never gets warm. Profile per message: the
   per-level patches 38.8 µs (14 of it the one DOM write), view helpers 27.6, `Rt$patch` and
   `childHtml` 30.4, update helpers 18.0 (§3).
5. **Q4: the table app's 5 510 bytes are 991 core, 2 231 runtime, 1 455 program in context**, plus
   813 that brotli finds shared between them. Keyed `For` alone is 1 478 B in context; beni ships
   two keyed passes where Solid 1 ships one. The List trie (526 B) is there because the program
   prepends its rows. Per element: a model field 14.1 B (the inline read-compare-write is 6.4), a
   level of depth 9.1 B (the distinct names linking four bindings a level), a hole 6.8 B (walk 3.7,
   slot 1.9, write 1.2) (§4).

---

## 1. Q1 — the per-message constant on the 10-hole page

### 1.1 Three ways to time a message, and why the trace overstates the gap

The page is `bench/ui/apps/scaling/holes.mjs` at N = 10: one counter that ticks, nine holes that
read values no message changes. Subjects: beni's development build, its `--release` build, Solid
1.9.15, P2 and vanilla JS, all built by `scaling.mjs` with the ReleaseFast compiler at master
`b1fe0f401`. Three measurements, each in one batch with the subjects rotated per page:

- **traced** (`scaling.mjs`, js-framework-benchmark's method): a real click after five warm-up
  clicks, script ms from a Chrome trace, 2 pages × 4 samples;
- **real clicks, untraced** (`plumbing.mjs --mode=cdp`, new): trusted clicks sent by CDP
  `Input.dispatchMouseEvent`, each timed in the page from a capturing `click` listener on `window`
  (the dispatch's first listener) to a bubbling one (its last), so every framework listener is
  inside and the browser's hit test outside. Clicks 6 to 120 or 200, 6–10 pages per subject.
  `performance.now()` is coarsened to 5 µs in the page, so a single click's time is a multiple of
  5 µs; the means over hundreds of clicks resolve below that, and they are what is quoted, with the
  median and range of the per-page means;
- **hot loop, untraced** (`plumbing.mjs --mode=loop`, new): in the page, 2 000 warm-up clicks, then
  30 runs of 1 000 `el.click()` timed together. A synthetic click is untrusted, and beni renders an
  untrusted event's message in a microtask; so every beni subject here has `true` written where
  its listener reads `event.isTrusted`, the one edit that makes it take a real click's path.

| subject | traced, ms median [IQR] | real clicks, µs mean (median of page means [range]) | hot loop, ns median of page medians |
|---|--:|--:|--:|
| beni | 0.098 [0.088–0.117] | 19.4 (19.0 [18.4–21.5]) | 3 390 |
| beni `--release` | 0.100 [0.083–0.103] | 20.1 (20.0 [19.7–21.2]) | 3 429 |
| Solid 1 | 0.097 [0.089–0.105] | 26.5 (26.3 [25.6–27.2]) | 5 556 |
| P2 | 0.063 [0.059–0.066] | 11.7 (11.6 [11.0–12.4]) | 2 745 |
| vanilla | 0.048 [0.041–0.051] | 10.1 (10.1 [9.5–10.9]) | 2 681 |
| **beni − P2** | **0.035** | **7.7** | **0.67 µs** |

Sources: `results/2026-10-08-r59-holes-trace.json`, `-cdp-ladder.json` and `-cdp-ladder-2.json`
(beni, P2 and vanilla: the mean of the two batches; release and Solid 1 from
`-tiers-holes-default.json`), `-loop-ladder.json`. Batches ran 14:22–14:48 UTC at a 1-minute load
of 1.1–2.6.

What this says:

- **The trace multiplies, it does not add.** Untraced to traced, vanilla goes 10 → 48 µs, P2
  12 → 63, beni 19 → 98: a factor of 4–5 on each. Research 56 §2.2 measured the trace's charge for
  a second top-level callback (0.05 ms); beni no longer has one, and what remains is a charge that
  grows with the JavaScript run. So the traced gap (35 µs) is the untraced gap (7.7 µs) times the
  trace's factor, and research 58 §2.3's 0.035 ms is a property of the instrument as much as of
  beni.
- **Warmness matters, and the benchmark samples the coldest clicks.** Real-click means by click
  number, beni against P2: clicks 6–20, 26.3 against 15.5; 21–60, 17.6 against 11.2; 61–120, 18.7
  against 11.0. The traced sample is clicks 6–9. Hot, the gap is 0.67 µs, a tenth of the
  real-click gap: most of the real-click cost is beni's code and data being cold between clicks
  (a real click comes after a millisecond of idle), not the instructions themselves.
- **Untraced, beni is faster than Solid 1** on real clicks (19.4 against 26.5 µs) and hot (3.4
  against 5.6 µs). Traced, they tie (0.098 against 0.097).
- **`--release` does not move the constant** (20.1 against 19.4 µs; 0.100 against 0.098 ms).

### 1.2 The ablations

Each removes one piece from a copy of the development build's `Rt.mjs` (`plumbing.mjs`'s
`ablations`, with the exact edits):

| name | removed |
|---|---|
| `constkeys` | the property names built per event (`` `$$${type}` `` in `delegated`, `` `${key}F` `` in `bubble`, `` `${key}X` `` in `fire`), written as constants |
| `stopwalk` | the walk after the handler fires: `bubble` returns instead of going on to the document |
| `nodisabled` | the `.disabled` read at each node the walk passes |
| `knownroot` | `mountAbove`'s second walk from the handler to the mount: the mount is `document.body` |
| `nocx` | `Html.map`'s chain: the `$$cx` lookup and `through` |
| `nox` | the payload decoder lookup (`$$clickX`) |
| `nofinally` | the three `try … finally` defect guards (in `fire`, `turn` and `flush`) |
| `noturn` | `turn`'s closure: the delegated listener sets `turning` and calls `bubble` itself |
| `noqueue` | the queue: a message sent during a turn is rendered at once, not pushed onto `queued` for the flush at the turn's end |
| `noview` | `view`'s `{t, v: [model]}` and the generic patch: the render calls the template's `p` on the instance |
| `nodead` | the `$$root` closure's `dead` check |
| `direct` | delegation itself: no document listener; a listener on `#go` calls `update` and the template's patch |

`lad-k` removes the first k in the table's order; `all` is `lad-11`. A ladder's steps sum exactly
to the whole, so it attributes the gap without assuming the pieces are independent; each piece is
also measured alone.

### 1.3 Real clicks, untraced: the ladder

Real clicks 6–120, 8 pages per subject, µs mean per message. Two batches minutes apart
(`-cdp-ladder.json`, `-cdp-ladder-2.json`); two copies of beni in each gave 19.35/19.14 and
19.31/19.68.

| step | batch 1 | batch 2 | mean | step's cost |
|---|--:|--:|--:|--:|
| beni | 19.25 | 19.50 | 19.37 | |
| − `constkeys` | 17.30 | 17.55 | 17.43 | 1.94 |
| − `stopwalk` | 16.15 | 16.32 | 16.24 | 1.19 |
| − `nodisabled` | 16.48 | 16.63 | 16.56 | −0.32 |
| − `knownroot` | 16.57 | 16.62 | 16.60 | −0.04 |
| − `nocx` | 16.04 | 16.03 | 16.04 | 0.56 |
| − `nox` | 15.96 | 16.36 | 16.16 | −0.12 |
| − `nofinally` | 17.28 | 17.37 | 17.33 | **−1.17** |
| − `noturn` | 16.95 | 16.85 | 16.90 | 0.43 |
| − `noqueue` | 15.68 | 15.33 | 15.51 | 1.39 |
| − `noview` | 14.20 | 14.23 | 14.22 | 1.29 |
| − `nodead` | 14.34 | 14.22 | 14.28 | −0.06 |
| `direct` | 12.18 | 12.14 | 12.16 | 2.12 |
| P2 | 11.68 | 11.65 | 11.67 | 0.49 |
| **sum of steps** | | | | **7.70** |

The same pieces one at a time (`-cdp-single.json`, 8 pages; that batch's beni was 21.0/22.5 and P2
12.7, so read the differences): `constkeys` −2.7, `stopwalk` −0.9, `knownroot` −0.6, `noturn`
−0.6, `noqueue` −0.5, `nocx` −0.4, `nodisabled`, `nox`, `nodead` within ±0.3, `nofinally` +0.4,
`noview` +2.0, `all` −5.3. Alone, the pieces after the walk are smaller than on the ladder and
`noview` is not a saving; on the ladder, with the walk gone, the queue and the view are each worth
about 1.3 µs. The per-page spread is about ±1 µs, so a step under 0.5 µs is not resolved.

**The guards.** Removing the three `try … finally` blocks, after the steps before it, made the
message **1.2 µs slower**, in both batches. Alone it was +0.4. Research 56 §2.3 found them free
under the trace. Why removing them costs time was not investigated (a guess: it changes what V8
inlines into `bubble`); the finding for this study is only that they are not part of the gap.

### 1.4 The same, in a CPU profile

`plumbing.mjs --mode=cdp --profile`: V8's sampling profiler at 10 µs over real clicks 6–60, six
pages, self time per message (`-cdp-profile.json`; grouped by `plumbing-profile.mjs`). The
harness's own two listeners (3–5 µs) are left out; `(program)`, the browser's time between
clicks, is too.

| beni, development | µs | P2 | µs |
|---|--:|---|--:|
| the template's patch (`Main$p50`, of which the one `.data` write 5.4) | 5.6 | `render` (of which the `.data` write 5.6) | 5.6 |
| delegation: `delegated`'s closure (the `` `$$${type}` `` line) 2.0, `bubble` 1.4, `fire` 0.8, `mountAbove` 0.6, `delegated` 0.6 | 5.4 | the listener | 1.4 |
| `$$root`, `turn`, `flush`, `render` | 2.4 | `update` | 0.4 |
| `view` 0.8, `patch` and `childHtml` 0.6 | 1.4 | | |
| **total** | **14.8** | | **7.4** |

The 7.4 µs difference matches the ladder's 7.7. Both say the same thing about the template patch:
the one DOM write costs the same 5.6 µs in beni and in P2, and the compares around it are nothing.
TEA's model — a spread and compare-all — is not where the time goes; the dispatch around it is.

### 1.5 Hot, for scale

In the hot loop (§1.1) the whole gap is 0.67 µs, and removing every piece (`all`) leaves 0.06 µs.
Alone, in the quietest batch (`-loop.json`, load 2.6, 4 pages): `constkeys` −0.43 µs, `stopwalk`
−0.42, every other piece −0.1 to −0.2, within that batch's noise. The second batch's ladder
(`-loop-ladder.json`) puts `constkeys` first again (−0.17 to −0.35) and nothing else above noise.
So the built property names are the largest piece hot as well as cold.

### 1.6 Which pieces are removable, and what each would need

The author's reading of the measurements; no guarantee is given up by any of these.

| piece | µs (real clicks) | removal needs |
|---|--:|---|
| built property names | 1.9 | a runtime change: `delegate` builds `$$click`, `$$clickF`, `$$clickX` once per registered event type and `bubble`/`fire` read them from there. A string concatenated per event is a new string whose lookup V8 must internalise first; a constant is not. |
| the walk past the handler | 1.2 | a runtime change. The walk goes on to the document so that an ancestor's handler for the same event also fires (bubbling), and `fire` then walks up again (`mountAbove`) to find the mount. One walk that finds the handlers and the mount together, stopping at the mount's root, keeps bubbling and removes the second walk; stopping at the first handler would need to know that no ancestor has one (a count per event type, or the compiler). |
| the render queue | 1.4 | a runtime change: on a trusted event's turn, one pending-render slot per mount instead of an array swapped and looped by `flush`. The batching guarantee (one render per turn) is kept. |
| `view`'s objects and the generic root patch | 1.3 | an emitter or runtime change: the root's `view` returns the same kind every time here, so the render could call its patch with the model directly; the `{t, v}` pair is needed only when the kind can change. |
| `Html.map`'s `$$cx` | 0.6 | an emitter change: write `$$cx` only on nodes inside an `Html.map`, and read it only when the handler says so. |
| `turn`'s closure | 0.4 | a runtime change (`delegated` does the turn inline). |
| delegation itself | 2.1 | not proposed. Solid 1 and dom-expressions delegate too; a listener per element costs mount time and memory on lists. |
| guards, `.disabled`, `X`, `dead` | ≈ 0 | nothing to remove. |

Together the removable pieces are about 6.8 µs of the 7.7 on real clicks and 0.6 of the 0.67 hot;
`all` measured 14.3 µs against P2's 11.7 and `direct` 12.2.

---

## 2. Q2 — width 1 024: V8's descriptor limit

**The constant exists and is 1 020.** V8 `main` at `1fce324253b9` (2026-10-01),
`src/objects/property-details.h:242–249`:

```cpp
static const int kDescriptorIndexBitCount = 10;
// The maximum number of descriptors we want in a descriptor array.  It should
// fit in a page and also the following should hold:
// kMaxNumberOfDescriptors + kFieldsAdded <= PropertyArray::kMaxLength.
static const int kMaxNumberOfDescriptors = (1 << kDescriptorIndexBitCount) - 4;
```

(1 << 10) − 4 = 1 020. `src/objects/map.cc:591` and `:622` (`Map::CopyWithField`,
`Map::CopyWithConstant`) refuse to add a field to a map that already has that many descriptors,
and the object is then normalised to dictionary mode. A second limit could have put the cliff
lower: `Factory::ObjectLiteralMapFromCache` (`src/heap/factory.cc:4698`) gives a literal of
`JSObject::kMapCacheSize` = 128 or more properties (`src/objects/js-objects.h:977`) the slow-object
map. It does not apply to these literals: they measure fast from 128 to 1 020.

**Measured** (`bench/ui/spread-micro.mjs`): a literal of W fields `f0 … fW−1` and the update the
width page compiles to, `{ ...m, fK: m.fK + 1 }`, in loops of about 5 ms, 15 runs, median [IQR]
ns per spread. In Chrome 153 (`plumbing.mjs --mode=spread`, 3 pages, median of the pages'
medians, `-spread.json`) and in Node 24.19 (V8 13.6) with `--allow-natives-syntax` for
`%HasFastProperties`; both on CPUs 8–15 at load 1.2.

| W | Chrome, ns per spread | Node, ns per spread | Node, literal and result fast? |
|--:|--:|--:|:-:|
| 64 | 62 [61–65] | 83 [80–84] | yes |
| 128 | 150 [149–153] | 145 [145–146] | yes |
| 256 | 284 [284–290] | 278 [254–279] | yes |
| 512 | 534 [534–540] | 481 [481–483] | yes |
| 1 000 | 1 021 [1 014–1 026] | 914 [869–915] | yes |
| 1 016 | 1 036 [1 031–1 036] | 874 [873–875] | yes |
| 1 020 | 1 024 [1 022–1 029] | 886 [885–888] | yes |
| **1 021** | **165 000** [164 492–165 078] | **191 949** [191 290–192 288] | **no** |
| 1 024 | 165 234 [165 000–165 273] | 193 707 [192 053–204 139] | no |
| 1 030 | 173 047 [172 891–173 203] | 200 526 [199 861–200 830] | no |
| 2 048 | — | 392 477 [391 347–396 099] | no |

**The claim holds.** To 1 020 fields a record is a fast-mode object and its spread costs about
1 ns a field. At 1 021 it is a dictionary-mode object and the spread costs 161× more in Chrome,
217× in Node, about 0.17–0.19 µs a field. The step is exactly at `kMaxNumberOfDescriptors`. (A
first run of this micro at a 1-minute load of 40, discarded, read 10–15× slower throughout; the
step was the same.)

**On the page** (`scaling.mjs --sweeps=width --params=…`, traced, 2 pages × 4 samples,
`-width.json`, load 0.7–1.1):

| W | beni ms | Solid 1 ms | vanilla ms |
|--:|--:|--:|--:|
| 256 | 0.132 [0.121–0.181] | 0.104 [0.096–0.119] | 0.042 [0.039–0.047] |
| 512 | 0.162 [0.131–0.205] | 0.101 [0.096–0.105] | 0.043 [0.041–0.044] |
| 1 000 | 0.253 [0.206–0.307] | 0.101 [0.094–0.119] | 0.045 [0.041–0.048] |
| 1 016 | 0.244 [0.221–0.306] | 0.112 [0.105–0.119] | 0.044 [0.042–0.045] |
| 1 020 | 0.218 [0.204–0.324] | 0.098 [0.096–0.109] | 0.044 [0.042–0.044] |
| 1 024 | 0.407 [0.372–0.457] | 0.118 [0.093–0.124] | 0.047 [0.043–0.051] |
| 1 030 | 0.383 [0.356–0.484] | 0.109 [0.098–0.121] | 0.044 [0.043–0.046] |

The step between 1 020 and 1 024 fields is 0.19 ms traced. Profiled on real clicks
(`-width1024-profile.json`), beni's `update` takes 244 µs a message at 1 024 fields against 15 µs
at 1 000 (`-width1000-profile.json`), and the garbage collector 127 µs against 82: the dictionary
copy, and the larger dictionary objects it leaves.

**What research 58 §2.4 missed: the curve is not flat below the cliff.** beni's message doubles
from 256 to 1 000 fields (0.132 → 0.253 ms) while Solid 1 and vanilla stay flat. The copy is not
why: it is 1 µs at 1 000 fields hot, 15 µs cold. The profile at 1 000 fields puts 37 µs on the
root template's patch (`Main$p3026`), one function of 1 000 read-compare-write blocks, run once
per message, and 25 µs more on the calls into it (`Rt$patch`, `childHtml`); Solid 1 runs the one
effect whose signal changed. That is the compare-all render of a view whose 999 other holes read
fields no message writes — research 58 §1 (ii)'s constancy case, not immutability's.

What it means for beni: the 1 024 point measures V8's dictionary mode, not the cost of an
immutable record, and a record past 1 020 fields is not a program anyone writes by hand (it could
be generated — a schema, a table of settings). Research 58's advice not to design for it stands;
the cliff is not beni's, since any JavaScript object past 1 020 named properties is in dictionary
mode, and Solid 1's and vanilla's pages escape it only because they never copy their model. A
warning for a record type past 1 020 fields would be cheap and true; whether it is wanted is the
owner's call (rule 7: a warning, not a refusal).

---

## 3. Q3 — depth 128

### 3.1 It is linear, and it is not the path copy

`apps/scaling/depth.mjs`: the changing value sits D records deep; each level is its own record type,
its own `view` helper and its own update helper (`bumpK`), the way a nested model is written. P2
does the same work by hand with **one** recursive `bump` and **one** recursive `patch`.

| D = 128 | traced ms (`-depth-trace.json`) | real clicks µs mean (`-depth-cdp.json`) | hot loop µs (`-depth-loop.json`) |
|---|--:|--:|--:|
| beni | 0.339 [0.217–0.487] | 99.0 | 21.0 |
| beni `--release` | 0.302 [0.217–0.403] | 90.9 | 19.8 |
| Solid 1 | 0.223 [0.203–0.231] | 87.1 | 43.9 |
| P2 | 0.056 [0.054–0.059] | 21.2 | 6.5 |
| vanilla | 0.044 [0.042–0.049] | 14.2 | 3.0 |
| **beni at D = 1** | 0.113 [0.092–0.126] | 26.7 | — |

Per level, beni costs (99.0 − 26.7) / 127 = **0.57 µs** on real clicks and about **0.12 µs** hot
more than P2. The 10-08 sweep's points (1, 2, 4 … 128: 0.090 → 0.306 ms) rise by about the same
amount per level all the way (1.9 µs a level to 64, 1.5 from 64 to 128): linear, not quadratic.
And the path copy is not the cost: P2 copies the same 128 records and patches the same 128 levels
in 21 µs a real click, 6.5 hot — research 58's estimate of a few µs for the copy was right.

### 3.2 Where the time goes

CPU profile over real clicks 6–40, 4 pages, self time per message, grouped
(`-depth-profile.json`, `plumbing-profile.mjs`):

| beni, development | µs | P2 | µs |
|---|--:|---|--:|
| per-level patch functions (`Main$p…`, 128 of them; the leaf's one DOM write about 14) | 38.8 | `patch`, one recursive function (the DOM write about 11.5) | 12.5 |
| per-level view helpers, `viewK n = {t: kind, v: [n]}` | 27.6 | — | |
| `Rt$patch`, `Rt$childHtml` (one line: `b.t.p(i, b.v)`, 23 µs) | 30.4 | — | |
| per-level update helpers, `bumpK n = {...n, child: bumpK+1(n.child)}` | 18.0 | `bump`, one recursive function | 5.4 |
| delegation | 7.6 | listener | 1.9 |
| `$$root`, `turn`, `flush`, GC | 4.2 | | |
| **total** | **≈ 126** | | **≈ 20** |

Per level and message, beni runs four frames — the level's patch, the next level's view helper,
`Rt$childHtml` → `Rt$patch`, which calls the next patch through `b.t.p(…)` — and allocates two
objects (`{t, v}` and its one-element array) besides the copy. Three of those four functions are
distinct at every level, and each is called once per message; P2's two functions are called 128
times per message. Two measurements say what that costs:

- **Hot, the four frames and two allocations cost about 0.12 µs a level** (21.0 against 6.5 µs over
  127 levels).
- **Cold, they cost 0.57 µs a level**, and the extra is not the interpreter alone. With
  `--js-flags=--always-sparkplug` (`-tiers-depth-*.json`; `lib/chrome-js-flags.sh`) beni's
  clicks 6–20 drop from 138 to 85 µs, but clicks 21–60 stay at 78–82 µs, as without the flag.
  `--no-lazy-feedback-allocation` makes no click band faster. (In all three runs clicks 61–100 cost more than 21–60, 107–161 µs; that was not investigated.) The author's reading of what stays: each function's inline caches
  and code being cold — 384 small functions touched once per message, with the one call site in
  `Rt$patch` that sees all 128 patch functions megamorphic — where P2's two functions are warm
  after one message.

`b.t.p(i, b.v)`'s 23 µs is the clearest single line: it is the dispatch to 127 different targets
from one call site.

### 3.3 What would remove it

The author's reading. The view helper and its two objects exist so the slot can compare kinds
(`b.t === i.t`); here every `viewK` returns the same kind every time, which the emitter knows. A
child slot whose kind is fixed could call that kind's patch directly with the record, which
removes the helper, both allocations and the megamorphic dispatch — about 58 of the 126 µs above
— and turns the call into a monomorphic one. That is an emitter change, no guarantee involved. It
does not make 128 distinct per-level functions into one: real nested models have distinct types
at each level, so the sweep's identical levels overstate what sharing code would buy. The per-level
bytes (§4.2) have the same cause.

---

## 4. Q4 — where the bytes go

Everything here is `sizes.mjs`'s measure: the bundle through terser (`--compress --mangle
--module`), then brotli 11. beni is its `--release` build (one scope-hoisted file) from the
ReleaseFast compiler at `b1fe0f401`; the table app is 5 510 bytes, as the 10-08 report says.

### 4.1 The table app, by part

The release bundle's top-level bindings have short names, so `bench/ui/size-parts.mjs` carries a
hand-written map from each binding to its part, read off the bundle against `Rt.beni`, `core/` and
`apps/beni/Main.beni`. Brotli is not additive, so two measures are given:

- **alone**: the part's declarations by themselves, minified, brotli 11 — what it costs with
  nothing to share a dictionary with. An upper bound.
- **in context (leave one out)**: the whole bundle with the part's declarations replaced by stubs
  that still name the bindings they used (so removing a part never makes another part's code
  dead), minified again, against the whole. This is the column to read. The parts' figures sum to
  4 697 of 5 510; the other 813 bytes are what brotli finds in common between parts (the same
  idioms in runtime, core and program), which exist only because the parts are together.

A third measure, the parts peeled off in turn, sums exactly but charges the stubs' own 697 bytes to
"what is left"; it is in `size-parts.mjs`'s output and not used here.

| part | what it is for | alone | in context |
|---|---|--:|--:|
| **core** | | **1 447** | **991** |
| List: the 32-way trie, views, `[ x, …xs ]` | the program builds its 1 000 rows by prepending, `[ { id, label }, …rows ]` in `buildFrom`; a prepend past 32 items is the trie with a head buffer | 895 | 526 |
| `List.append` | append 1 000 rows | 407 | 188 |
| `List.get` | picking the words, `swapRows` | 163 | 85 |
| `List.indexedMap` | update every 10th, `swapRows` | 195 | 88 |
| `List.filter` | remove | 213 | 82 |
| `Basics.modBy`, `Maybe.Nothing` | | 68 | 16 |
| **platform runtime (`Rt`)** | | **2 794** | **2 231** |
| keyed `For`: the in-place pass (`trimmed`) | a list whose last keys were distinct: rows matched at the start, the end and a swapped pair before the key map — the order of Solid's `mapArray` + `reconcileArrays` | 820 | 588 |
| keyed `For`: the full pass (`keyedPass`, `forKeyed`) | every row by its key, duplicate keys allowed | 622 | 400 |
| keyed `For`: the move reconciler (`reconcile`, `park`) | the DOM moves, removes and inserts | 490 | 341 |
| keyed `For`: row mount and patch, selection, `sameInputs` | | 242 | 106 |
| delegation: listener, walk, `fire`, registration | one `click` listener on the document | 339 | 230 |
| scheduler: queue, `turn`, `flush`, defect guards, `mount`, `run` | render at the end of a trusted dispatch or in a microtask; stop on a defect (rule 9) | 382 | 185 |
| slots: `slot`, `unit`, `patch`, `childHtml`, `restate` | holes that hold markup (the six buttons, the table body) | 338 | 176 |
| DOM ranges: `first`, `last`, `put`, `drop` | | 233 | 112 |
| `template` | | 113 | 68 |
| **program** | | **1 730** | **1 455** |
| view: three templates, their kinds and patches, the button helper | | 1 031 | 858 |
| data: the word lists and `buildData` | | 453 | 360 |
| `update`, with `swapRows` | | 327 | 218 |
| message constructors, `init`, start-up | | 162 | 70 |
| shared between parts | | | 813 |
| **total** | | | **5 510** |

Core, runtime and program rows are each a separate leave-one-out (`--map=table-coarse`), as are
the finer rows (`--map=table` and `--map=table-for`), so the fine rows need not add to their part's
row.

**What each part does, and what vanilla (1 415 B) and Solid 1 (4 354 B) ship for it:**

- **The program, 1 455 B**, is the part vanilla's 1 415 corresponds to: its author writes the same
  data generation, a row template, and a handler per operation. They are about the same size;
  beni's `view` is one declaration and vanilla's is seven imperative operations.
- **Keyed `For`, 1 478 B in context (1 865 alone)**: vanilla has none — it writes each operation's
  DOM moves by hand (swap is two `insertBefore`s). Solid 1 ships `mapArray` and
  `reconcileArrays`, 868 B alone (`size-solid1-parts.mjs`, from `solid-js` 1.9.15's `dist` files,
  measured the same way). beni carries **two** passes where Solid carries one: the in-place pass
  that does Solid's job, and a full keyed pass with its move reconciler, which lets a list hold two
  rows with the same key and still render. Solid keys rows by item identity and has no such case.
  The second pass is about 740 B in context.
- **Delegation, 230 B**: vanilla writes two delegated listeners by hand (the buttons, `tbody`), a
  few dozen bytes. Solid 1's `delegateEvents` + `eventHandler` are 511 B alone, beni's 339.
- **Scheduler and guards, 185 B**: vanilla has none (it writes the DOM in the handler, and an
  exception reaches the console). Solid 1's equivalent — signals, computations, the update queue,
  ownership and cleanup — is 2 408 B alone, the largest part of its bundle.
- **Slots, DOM ranges, template, 356 B**: vanilla clones one row template; Solid 1's `insert`
  family is 944 B alone and `template` 191.
- **core's List, 969 B in context**: vanilla and Solid's program use arrays and
  `Array.prototype`. The trie (526 B) is there because `buildFrom` prepends rows one at a time,
  which is idiomatic beni; a program building its list with `List.initialize` or by pushing would
  not pull it in. That is the program's choice, not a fixed cost of the runtime.

Solid 1's figures are each part alone, unbundled, with the branches its production build also
keeps (`Transition`, `ExternalSourceConfig`), so they are upper bounds like beni's "alone" column
and sum to more than its bundle for the same reason.

### 4.2 What one more field, level or hole adds

`bench/ui/size-marginal.mjs` builds two points of a sweep, minifies each, cuts each kind of
per-element code out of the minified text by a pattern, and takes brotli with and without it; a
kind's bytes per element are the difference of its saving at the two points over the number of
elements between them. Adjacent points (256 and 257 fields, 1 000 and 1 001 holes, 64 and 65
levels) were built and diffed to read the code, but their brotli difference is noise (1 000 →
1 001 holes is +70 B, 64 → 65 levels −88 B): brotli's price for a repeated shape is a slope. The
tables use 128 → 256 fields, 64 → 128 levels and 100 → 1 000 holes.

The 10-08 report's 16.0, 13.8 and 6.1 B are fits from the first point to the last, and the slope is
not constant: 14.1 B a field over 128 → 256 (15.6 over 256 → 1 024); 9.1 B a level over 64 → 128
(the first levels cost 58, then 26, 23, 22, 19, 15 B each as brotli learns the shape); 6.8 B a hole
over 100 → 1 000.

**One more model field** (each field shown in its own hole), 14.1 B:

| what the field adds, as minified | raw chars | brotli B |
|---|--:|--:|
| the root patch: `let x=m.hb;x!==i.g200_0&&(i.g200_0=x,i.w422.data=x);` | 56 | 6.4 |
| the mount's walk to the hole: `u=p.nextSibling,v=u.firstChild,` | 36 | 2.8 |
| `init`'s field: `hb:200,` | 6 | 1.6 |
| the instance's two slots: `w422:v,` and `g200_0:NaN,` | 19 | 1.1 |
| the template's `<p> </p>` | 8 | 0.4 |
| the rest, by difference | | 1.8 |

The read-compare-remember-write is the largest piece: beni writes each hole's check out in full,
where Solid 1 writes a call, `P(Si,()=>n.f200)` (`insert` with a getter), and keeps the compare in
its runtime. That is the compiled template's trade — it is what puts beni ahead on `update every
10th` and `select` — and it costs about 6 B a hole.

Two things that look like waste are not. The long instance slot names (`g200_0`, `w422`) count up
in order and brotli predicts them: replacing each with a short distinct name **adds** 2.7 B a
field. And the release build's short record field names (`hb` for `f200`) against the source names
(`size-field-names.mjs`): 3 613 against 3 435 B at 128 fields, 5 417 against 5 378 at 256, 17 436
against 16 547 at 1 024 — the short names cost a little here, because `f0 … f1023` is a counting
sequence brotli predicts. A real program's field names are not, so this says nothing against
short names in general.

**One more level of depth**, 9.1 B (64 → 128):

| what the level adds, as minified | raw chars | brotli B, cut alone |
|---|--:|--:|
| its patch function: label compare and write, child compare, `childHtml(i.c1, {t: kind, v: [child]})` or `restate` | 183 | 1.4 |
| its kind: `{m: (v, cx) => {clone, instance with walk and slot, patch}, p, l: !0}` | 140 | 0.4 |
| its template, `g("<div class=level><span> ")`, the same text at every level | 33 | 0.9 |
| its update helper, `x=a=>({...a,c:y(a.c)})` | 25 | −1.8 |
| its initial record's label (terser nests the 128 records into one literal) | 14 | 1.1 |
| all of the above cut together | | 6.3 |

A level is about 395 characters of code identical at every level except for the names that link
it to the next (the next kind in the patch, the patch and template in the kind, the next helper in
the update helper). Brotli removes the repeated body and charges for those distinct names, which is
why no single kind accounts for much and all of them together account for 6.3 of the 9.1. Solid
1's 3.2 B a level is the same effect with one component function per level instead of beni's four
bindings. Calling a fixed kind's patch directly (§3.3) would remove the view helper and its
references; sharing one kind between identical levels would take the rest toward zero, but only
this sweep's levels are identical.

**One more hole**, 6.8 B (100 → 1 000; nine holes in ten read a value no message changes):

| what the hole adds, as minified | raw chars | brotli B |
|---|--:|--:|
| the mount's walk to it, one or two `x=y.nextSibling` / `.firstChild` | 31 | 3.7 |
| its instance slot, `w500:Ts,` | 9 | 1.9 |
| its write inside its value's group, `i.w500.data=w,` | 20 | 1.2 |
| its `<p> </p>` or `<p>x</p>` | 8 | −0.1 |

All of it is code for values that never change after the mount (research 58 §1 (ii)): a constancy
analysis would drop the slot and the write and keep the walk for mount, or bake the value into the
template and drop all three.

---

## 5. Method, files and caveats

- **Machine.** AMD Ryzen 9 5950X, Chrome 153.0.8010.36 headless pinned to CPUs 8–15, Node 24.19.0.
  Every browser batch took the shared bench lock and ran at a 1-minute load under 3.7 (each JSON
  file records its load at start and end); the machine was shared with other jobs through the
  afternoon, and two batches run under a load of 20–80 were discarded, not reported.
- **Compiler.** The ReleaseFast beni at `zig-out/fast/bin/beni`, built from master `b1fe0f401`.
- **New harness** (`bench/ui/`, all instruments, none a gate):
  - `plumbing.mjs`: the loop, real-click, profile and spread modes, and the ablations as edits;
  - `plumbing-report.mjs` and `plumbing-profile.mjs`: its tables;
  - `spread-micro.mjs`: Q2's loop, for Node and the page;
  - `size-parts.mjs`, `size-marginal.mjs`, `size-solid1-parts.mjs`, `size-field-names.mjs`: Q4;
  - `lib/chrome-js-flags.sh`: Chromium with extra V8 flags;
  - `scaling.mjs --params=…`: a sweep's points from the command line.
- **Results** (`bench/ui/results/2026-10-08-r59-*.json`): `loop`, `loop-ladder`, `cdp`,
  `cdp-ladder`, `cdp-ladder-2`, `cdp-single`, `cdp-profile`, `holes-trace`, `depth-cdp`,
  `depth1-cdp`, `depth-loop`, `depth-profile`, `depth-trace`, `width`, `width1000-profile`,
  `width1024-profile`, `spread`, and `tiers-{depth,holes}-{default,alwayssparkplug,nolazyfeedbackallocation}`.
- **Caveats.**
  - The real-click timing starts at the first listener and ends at the last, so it leaves out the
    browser's input handling and hit test (the same for every subject), and it includes the two
    timing listeners themselves (3–5 µs in the profiles, the same for every subject).
  - Real clicks are 1–2 ms apart (two CDP round trips each), which is what makes caches cold; a
    benchmark's clicks are further apart still.
  - The ablations change one thing each but are not what a fixed runtime would be; §1.6's
    removals would need measuring when built.
  - Absolute µs move between batches by up to 30% (beni 19.4 in one, 22 in another); differences
    within a batch are what the tables use.
  - Chromium/V8 only.

To reproduce, from `bench/ui` in `nix develop ..#browser` with `LD_LIBRARY_PATH` unset:

```sh
B=../../zig-out/fast/bin/beni
node scaling.mjs --build-only --full --sweeps=holes --params=10 --subjects=beni,beni-release,solid1,p2,vanillajs --beni=$B
node scaling.mjs --build-only --full --sweeps=depth --params=1,64,128 --subjects=beni,beni-release,solid1,p2,vanillajs --beni=$B
node scaling.mjs --build-only --full --sweeps=width --params=128,256,1000,1016,1020,1024,1030 --subjects=beni,beni-release,solid1,vanillajs --beni=$B
node plumbing.mjs --mode=cdp --pages=8 --clicks=120 --subjects=beni,beni-again,p2,vanillajs,abl-lad1,…,abl-lad11,abl-direct --taskset=8-15
node plumbing.mjs --mode=loop --pages=8 --subjects=beni,p2,vanillajs,solid1,abl-all,… --taskset=8-15
node plumbing.mjs --mode=cdp --profile --interval=10 --clicks=60 --subjects=beni,p2 --taskset=8-15
node plumbing.mjs --page=depth/128 --mode=cdp --profile --clicks=40 --subjects=beni,p2,solid1 --taskset=8-15
node plumbing.mjs --mode=spread --subjects=vanillajs --pages=3 --taskset=8-15
node --allow-natives-syntax spread-micro.mjs
node build.mjs && node size-parts.mjs --map=table-for && node size-marginal.mjs
```
