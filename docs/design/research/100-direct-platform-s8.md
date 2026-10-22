# 100 — Browser-direct: the fixed decision batch

> Test policy, 2026-10-22: per-test instruction limits, grants and reference CPU
> requirements were removed (#740). Each test or corpus case now has a
> 120-second wall-clock hang guard. Older counts and budget references below
> describe historical evidence, not a current gate or an outstanding grant.
> Performance remains the job of `test-perf` and `bench`.


*2026-10-15. Research only; no platform changed. Measured master
`6c327a9f17050941bc170f9e888160795ca471f5` on azathoth.
Research 100 was free on master and in open PR file lists; research 101
explicitly leaves it for this batch. All results below are measured unless
identified as source inspection, an inference, a target or outstanding work.*

## 0. Answer

**Do not retire tea. Direct fails kill criteria 1, 4, 5 and 6 in this batch;
2 and 3 pass their numbered tripwires, and 7 agrees with analysis.
Criterion 8 has no observed unintended platform divergence here, but correctness acceptance
remains incomplete: native Chrome is red on one CSS-precision golden and the
full V3 campaigns remain owed.** The three S4 endpoint targets all miss.
My recommendation is to **stop direct in its current form**, for the reasons
and contrary evidence at the end. This is evidence for the owner's decision,
not an implementation of that decision. Sternhalma’s selection distribution
is bimodal, so its median contrast is not treated as a stable headline speedup.

The fixed counts all completed. The clean batch wall window was **12:20:31–15:16:17 UTC,
2 h 55 min 46 s**, including the roughly three-minute setup-only app stall
and native report processing. The actual 200-page app grid occupies 17.112 s
of that window. This follows the owner’s instruction to finish the original
batch despite the underestimated memory cost. Initial setup and its invalidated
epoch add about 42 minutes from the first machine capture; the original
two-hour estimate was not met. The setup errors and zero-sample app setup
stall are disclosed in §6 and the retained protocol, not hidden as retries.

| Criterion | Verdict | Measured evidence / mechanism |
|---|--:|--:|
| 1 — statistics | **fires** | Navigation 9/62 = 14.52% patchAll; real-app star/value roots, pair-series and trie tripwires also fail (§5). |
| 2 — floor | passes | 327 B brotli; imports only Direct.run, no Task. The 300 B estimate still misses. |
| 3 — holes | passes measured tripwires | 10,000 holes 1.0125× vanilla; one cached text compare/write; non-HTML source exactly 953 B at every N. Corpus/verify evidence is qualified under criterion 8. |
| 4 — rows | **fires** | 30,000-row swap 1.2500× vanilla, above amended 1.15×; immutable model/list work remains, with visit guards. Edit 1.2059× meets pre-S7 1.3×. |
| 5 — table / P3 | **fires** | Create 1.3227×, update 1.2222× vanilla; update 1.2901× P3. Normalized 4,188 B, core 698 / non-core 3,490, versus 2,830 / 600 / 2,400. |
| 6 — TodoMVC, timing rejudged | **fires** | Sandbox grows 6,169→6,774 B; 1,000-todo sandbox add 0.605→0.705 ms, 1.1653× tea, separate IQRs. Routing add point ratio 1.0833× tea. |
| 7 — built versus predicted | passes observed scripts | Every one of 62 dispatches enters its predicted instance/group set; five empty Internal messages enter zero groups. |
| 8 — correctness | not accepted as complete | Linux gate green; Chrome 568 cases / one Sternhalma CSS serialization golden mismatch. No observed unintended differential/fuzz/verify mismatch; full V3 debt remains. |

The tables below cover each requested scenario before the protocol and
mechanism discussion. No aggregate ratio substitutes for an operation.

## 1. Official js-framework-benchmark

The **runner's own reports** are retained:
[pooled](../../../bench/s8/results/jfb-pooled/report/index.html),
[round 1](../../../bench/s8/results/jfb/report/index.html),
[round 2](../../../bench/s8/results/jfb-1/report/index.html),
[round 3](../../../bench/s8/results/jfb-2/report/index.html),
[round 4](../../../bench/s8/results/jfb-3/report/index.html).
Serve a report directory over HTTP to use its interactive views. The pooled
report uses all four rounds' raw observations, not averages of their medians.
Its native presentation/aggregate is descriptive; acceptance below uses the
individual operations and the separate rate-1 measurements.

**Native click-to-paint total, ms: median [Q1–Q3].** Twenty observations/cell;
select has sixty under upstream's additional-ten protocol. These are the native
runner's benchmark intervals, throttles and warm-ups, not the UI sweep interval.

| Operation | Vanilla | Solid 1.9.3 | Beni tea | Beni direct |
|---|--:|--:|--:|--:|
| 01_run1k | 66.350 [66.075–66.900] | 69.400 [69.200–70.300] | 67.800 [67.600–68.025] | 67.500 [67.375–67.800] |
| 02_replace1k | 71.950 [71.700–72.325] | 77.150 [76.800–78.100] | 74.300 [74.000–74.950] | 74.250 [73.950–74.800] |
| 03_update10th1k_x16 | 31.100 [30.675–31.350] | 33.600 [33.200–33.725] | 33.000 [32.700–33.300] | 32.850 [32.425–33.050] |
| 04_select1k | 7.3500 [7.2000–7.6000] | 9.1000 [8.8000–9.4000] | 7.4500 [7.2750–7.7000] | 7.3000 [7.2000–7.6000] |
| 05_swap1k | 35.100 [34.800–35.325] | 38.500 [38.275–39.150] | 37.350 [36.975–37.700] | 36.800 [36.350–37.025] |
| 06_remove-one-1k | 34.300 [34.000–35.000] | 35.300 [34.975–35.725] | 34.300 [33.975–34.525] | 34.600 [34.350–34.900] |
| 07_create10k | 700.050 [695.750–706.075] | 735.300 [731.700–743.425] | 726.750 [722.850–731.225] | 729.350 [727.675–736.125] |
| 08_create1k-after1k_x2 | 75.500 [75.275–76.350] | 78.650 [78.350–79.200] | 76.600 [76.375–76.975] | 76.300 [76.200–76.425] |
| 09_clear1k_x8 | 24.800 [24.475–25.025] | 28.900 [28.675–32.425] | 25.800 [25.475–26.350] | 25.100 [24.800–25.625] |

Native memory, size and first paint follow the runner's units:
**MiB** for `measureUserAgentSpecificMemory`, **KiB** for size,
**ms** for first paint. Memory n=20; size/paint n=4. Native compressed size
is a different measurement from the release brotli byte tables below.

| Native measure | Vanilla | Solid 1.9.3 | Beni tea | Beni direct |
|---|--:|--:|--:|--:|
| 21_ready-memory (MiB) | 0.5737 [0.5734–0.5738] | 0.6013 [0.5998–0.6014] | 0.6188 [0.6156–0.6190] | 0.6032 [0.6016–0.6035] |
| 22_run-memory (MiB) | 1.8818 [1.8717–1.8832] | 2.6835 [2.6642–2.6864] | 2.1324 [2.1298–2.1383] | 2.0524 [2.0508–2.0596] |
| 25_run-clear-memory (MiB) | 0.6502 [0.6475–0.6568] | 0.7779 [0.7744–0.7805] | 0.7848 [0.7836–0.7896] | 0.7415 [0.7402–0.7484] |
| 41_size-uncompressed (KiB) | 11.300 [11.300–11.300] | 11.500 [11.500–11.500] | 13.300 [13.300–13.300] | 11.400 [11.400–11.400] |
| 42_size-compressed (KiB) | 2.5000 [2.5000–2.5000] | 4.5000 [4.5000–4.5000] | 5.5000 [5.5000–5.5000] | 4.5000 [4.5000–4.5000] |
| 43_first-paint (ms) | 63.100 [60.450–65.750] | 79.400 [73.175–87.575] | 63.000 [55.650–77.725] | 70.000 [51.125–94.125] |

Direct and tea are close in native total time. Direct uses less memory in
all three states. The raw report also contains native script medians; the
[generated tables](../../../bench/s8/results/tables.md) reproduce every one.
The short throttled script values are not used to rank parity. Both beni entries
pass the runner's keyed checks. The upstream CSP command also prints unrelated
Elm failures; this is not represented as a clean CSP certification.

## 2. Unthrottled UI table and scaling

**Rate-1 traced script ms, median [Q1–Q3], 20 fresh pages/cell.**
Solid 1 here is 1.9.15, Solid 2 is 2.0.0-rc.9; these local UI implementations
are distinct from the official runner's Solid 1.9.3 entry.

| Operation | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 01_run1k | 11.984 [8.0495–14.243] | 14.518 [8.9830–16.479] | 17.456 [15.329–18.619] | 15.277 [12.743–16.486] | 15.851 [13.684–17.782] | 14.980 [12.563–15.969] |
| 02_replace1k | 14.803 [12.843–16.224] | 18.490 [16.839–19.652] | 19.529 [16.261–20.975] | 15.685 [10.897–17.497] | 16.742 [15.184–17.655] | 16.816 [15.615–17.199] |
| 03_update10th1k_x16 | 0.7605 [0.7450–0.8427] | 1.4445 [1.3397–1.4808] | 2.2980 [2.1972–2.7170] | 1.3115 [1.2552–1.4948] | 0.9295 [0.9103–0.9395] | 0.7205 [0.6935–0.7298] |
| 04_select1k | 0.5095 [0.4657–0.5517] | 0.5695 [0.5238–0.5998] | 1.0950 [1.0442–1.2113] | 0.3050 [0.2990–0.3565] | 0.4245 [0.4083–0.5115] | 0.4500 [0.4070–0.5035] |
| 05_swap1k | 0.4110 [0.4000–0.4407] | 1.5715 [1.5160–1.6587] | 1.8000 [1.7465–1.9070] | 0.7565 [0.7308–0.8495] | 0.4350 [0.4190–0.4930] | 0.4305 [0.4075–0.4848] |
| 06_remove-one-1k | 0.5820 [0.5620–0.6130] | 0.5350 [0.4830–0.5938] | 0.7950 [0.7765–0.8515] | 0.3875 [0.3568–0.4185] | 0.2550 [0.2313–0.2750] | 0.3180 [0.3000–0.3340] |
| 07_create10k | 55.592 [51.358–58.199] | 64.804 [59.061–67.533] | 78.786 [75.181–79.858] | 57.547 [51.232–59.443] | 60.951 [58.837–62.697] | 57.923 [53.804–60.763] |
| 08_create1k-after1k_x2 | 10.219 [9.5270–10.680] | 11.364 [8.9718–12.080] | 12.446 [9.3402–13.124] | 10.687 [10.008–11.139] | 10.046 [5.1655–11.479] | 10.092 [9.5857–10.611] |
| 09_clear1k_x8 | 10.464 [7.8128–11.332] | 10.607 [8.1420–11.287] | 11.792 [9.7710–12.582] | 10.410 [6.8120–11.111] | 10.598 [8.0868–11.963] | 10.799 [8.4328–11.309] |

| Operation | Direct / vanilla | Direct / P3 | Direct / tea |
|---|--:|--:|--:|
| 01_run1k | 1.3227× | 1.0581× | 1.0375× |
| 02_replace1k | 1.1310× | 0.9956× | 1.0674× |
| 03_update10th1k_x16 | 1.2222× | 1.2901× | 0.7087× |
| 04_select1k | 0.8332× | 0.9433× | 1.3918× |
| 05_swap1k | 1.0584× | 1.0105× | 0.5750× |
| 06_remove-one-1k | 0.4381× | 0.8019× | 0.6581× |
| 07_create10k | 1.0964× | 1.0523× | 1.0592× |
| 08_create1k-after1k_x2 | 0.9832× | 0.9955× | 0.9401× |
| 09_clear1k_x8 | 1.0129× | 0.9814× | 1.0181× |

Create-1,000 crosses 1.2× by its point median, with broad overlapping
IQRs. Update crosses 1.2× and has separate IQRs from vanilla and P3; the
no-operation-slower-than-P3 condition fails there. Close create/swap/P3
orderings with overlapping IQRs do not establish superiority. Select meets
the vanilla bar but tea is faster. The owner already accepted the earlier
select/P3 result: the withdrawn 30% select stop is **not reinstated**.

The table's byte criterion uses its specified **Terser normalization**, separately
from the unmodified application downloads. The byte miss is not core alone:
even free core leaves 3,490 B against 2,400. P3's 3,122 B gives an 0.85×
bar of 2,653.7 B; direct also exceeds the older fixed 2,935.9 B reading.

| Table subject | As-emitted/served brotli B | Normalized brotli B |
|---|--:|--:|
| Vanilla | 2172 | 1415 |
| Solid 1 | 4356 | 4354 |
| Solid 2 | 22131 | 21988 |
| Tea | 5365 | 5206 |
| Direct | 4340 | 4188 |
| P3, hoisted with reached imports | 6261 | 3122 |

| Normalized direct part | Ordered charge B | Independent leave-one-out B |
|---|--:|--:|
| Core | 698 | 698 |
| Runtime | 1657 | 1565 |
| App | 1297 | 1197 |
| Startup/residual | 536 | — |
| Whole | 4188 | not a sum of independent deletions |

The normalized core share is the contract's leave-one-out; the other
ordered charges are compression accounting. Independent leave-one-out values
are not additive.

**Required sweep endpoints**, untraced real-click ms, median [Q1–Q3].
Each ordinary cell contains 24 clicks clustered in **two** fresh pages.
The full grids, including every available P3 subject, are in §7.

| Endpoint | Vanilla | Direct | Direct / vanilla | Target |
|---|--:|--:|--:|--:|
| holes/tick/10000 | 0.2000 [0.1750–0.2100] | 0.2025 [0.1813–0.2150] | 1.0125× | ≤1.15× |
| rows/change/30000 | 0.0850 [0.0800–0.0963] | 0.1025 [0.0950–0.1200] | 1.2059× | ≤1.3× pre-S7; ≤1.15× owned/plain after S7 |
| rows/swap/30000 | 0.1300 [0.1250–0.1400] | 0.1625 [0.1450–0.1863] | 1.2500× | ≤1.15× pre-S7; ≤1.0× after S7 |
| width/field/1024 | 0.2025 [0.1850–0.2163] | 1.1575 [1.1325–1.1875] | 5.7160× | ≤1.3× pre-S7; ≤1.15× after S7 |
| depth/leaf/128 | 0.2225 [0.2138–0.2450] | 0.6300 [0.5337–0.7413] | 2.8315× | ≤1.3× pre-S7; ≤1.15× after S7 |
| derived/tick/100000 | 0.2125 [0.2050–0.2250] | 0.2600 [0.2250–0.2800] | 1.2235× | flat and ≤1.15× |
| live/tick/10000 | 0.0700 [0.0687–0.0800] | 0.1150 [0.0950–0.1200] | 1.6429× | ≤1.15× |
| helperRows/tick/10000 | 0.0800 [0.0700–0.0863] | 0.1175 [0.1100–0.1313] | 1.4688× | ≤1.15× |
| tree/tick/12 | 0.2050 [0.1950–0.2113] | 0.2600 [0.2175–0.2850] | 1.2683× | ≤1.15× |

**All three pooled S4 endpoint ratios miss their bars**: live 1.6429×, derived 1.2235×,
depth 2.8315×. Derived medians range 0.2250–0.2600 ms; its final/initial
median is +14.3%, with overlapping IQRs and only two page clusters. Skipping
the sort/filter on tick is source evidence, not a proof of flat elapsed time.
The new sweep grid received the fixed operation postconditions, not a new
value-fuzz/verify campaign for every generated parameter. The corpus evidence
does not discharge that S1 obligation on its own.
The S4 amendment introduces no new numbered kill criterion; these remain
reported target misses.

The intermediate points also remain visible: holes 3,000 is 1.1728× by its
median, despite both named holes endpoints meeting 1.15×. Width 17 and 32 are
1.2073× and 1.1852×, missing the ≤256-field static-heavy 1.15× point bar, while
width 256 is 1.0937×. These nonmonotonic two-page results do not establish a
new threshold mechanism or justify selecting a favorable endpoint.

Swap fires criterion 4 under the **amended pre-S7 1.15× bar**, not the older
1.0× bar. Its direct IQR is 0.1450–0.1863 versus vanilla 0.1250–0.1400 ms.
The slower-than-P3 prong also fires literally: its pooled point ratio is
1.0833×. The overlapping IQRs qualify the strength of that ordering, not the
literal verdict. By page, direct/P3 is 1.0154× on page 0 and a displayed
tie (0.1500/0.1500 ms) on page 1. Direct/vanilla is 1.2692× and 1.153846×;
the latter exceeds 1.15 by only about 0.5 microseconds, not a resolved margin.
These page contrasts qualify the pooled result. The shipped-reconciler prong is also unmet: exact unique-key
edits bypass it, but duplicate-key fallback code remains, as the later
rank-correctness amendment requires. Thus all three stated swap/reconciler
conditions are accounted for; preserving the required fallback does not mean
the original no-reconciler byte promise was achieved. S7's record/list in-place promises have not been credited:
the inspected output still contains record spreads.

**The nine endpoints, separated by page.** These are medians of twelve clicks
per page, recomputed from retained rows; no new observations. In particular,
derived 100,000 is 1.0714× vanilla on page 0 and 1.2759× on page 1: the pooled
miss should not be described as agreement between independent pages.

### Endpoint page 0

| Endpoint | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| holes/tick/10000 | 0.2000 | 0.3350 | 0.3975 | 0.2725 | 0.1950 | 0.2400 |
| rows/change/30000 | 0.0925 | 0.1375 | 0.1925 | 0.5750 | 0.1050 | 0.1275 |
| rows/swap/30000 | 0.1300 | 7.6075 | 4.5200 | 0.9800 | 0.1650 | 0.1625 |
| width/field/1024 | 0.2075 | 0.4200 | 0.5400 | 1.4075 | 1.1625 | — |
| depth/leaf/128 | 0.2175 | 0.8300 | 1.1050 | 0.5400 | 0.5700 | 0.3900 |
| derived/tick/100000 | 0.2100 | 0.4375 | 0.5125 | 0.3050 | 0.2250 | — |
| live/tick/10000 | 0.0725 | 0.1450 | 0.1750 | 0.1575 | 0.1200 | 0.1150 |
| helperRows/tick/10000 | 0.0800 | 0.2075 | 0.2500 | 0.1800 | 0.1250 | — |
| tree/tick/12 | 0.2075 | 0.3275 | 0.4150 | 0.3075 | 0.2800 | — |

### Endpoint page 1

| Endpoint | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| holes/tick/10000 | 0.1975 | 0.3375 | 0.3875 | 0.2950 | 0.2100 | 0.2025 |
| rows/change/30000 | 0.0800 | 0.1500 | 0.2100 | 0.5300 | 0.1025 | 0.1125 |
| rows/swap/30000 | 0.1300 | 6.0950 | 4.5825 | 1.1825 | 0.1500 | 0.1500 |
| width/field/1024 | 0.1925 | 0.4325 | 0.5475 | 1.4375 | 1.1525 | — |
| depth/leaf/128 | 0.2275 | 0.8275 | 1.3575 | 0.6450 | 0.6500 | 0.2825 |
| derived/tick/100000 | 0.2175 | 0.3700 | 0.5350 | 0.3650 | 0.2775 | — |
| live/tick/10000 | 0.0700 | 0.1400 | 0.1975 | 0.1675 | 0.0975 | 0.0850 |
| helperRows/tick/10000 | 0.0725 | 0.1975 | 0.2950 | 0.1600 | 0.1150 | — |
| tree/tick/12 | 0.2050 | 0.3275 | 0.3475 | 0.3175 | 0.2400 | — |

Sweep bytes below are normalized by the existing scaling-size protocol.
Width/depth growth is the endpoint delta divided by added fields/levels, not
whole-bundle bytes divided by N.

| Endpoint | Direct brotli B | Byte target / observation |
|---|--:|--:|
| holes 10,000 | 564 | non-HTML source 953 B at every N; growth only HTML |
| rows 30,000 | 2735 | ~1.5 kB estimate missed |
| width 1,024 | 2995 | 2.434 B/additional field > 2 |
| depth 128 | 2647 | 16.740 B/additional level > 4 |
| derived 100,000 | 1407 | > 1,000 |
| live 10,000 | 2734 | > 1,100 |
| helper rows 10,000 | 1050 | no separate numbered byte tripwire |
| helper tree 12 | 2655 | reported, no separate byte bar |

Bursts miss the ≤1.15× point target at K=3 and 10 (1.2056× and
1.2065×); their ratios are not exactly K=1's 1.0408×. Other measured K pass
the point bar, with the complete spreads below. Stream point ratios are
1.1051× / 0.9655× / 1.0027× for K=1/10/100, but **two windows cannot certify**
the stream condition. No sample count was increased to settle either question.

## 3. Real applications on both platforms

**Unmodified production release JavaScript, brotli 11 bytes with size hint.**
Core is removed first, runtime second; the app/startup remainder closes the
account. These are ordered in-context charges, not independently compressed
downloads or sums of independent removal savings. Maps reproduce the executable
bytes exactly; source/map archives and binding provenance are retained.

| App / platform | App + startup B | Core B | Runtime B | Whole B |
|---|--:|--:|--:|--:|
| conduit/tea | 15880 | 7874 | 7635 | 31389 |
| conduit/direct | 21222 | 7970 | 8778 | 37970 |
| todomvc/tea | 2779 | 1889 | 4245 | 8913 |
| todomvc/direct | 3178 | 1942 | 4354 | 9474 |
| sternhalma/tea | 4060 | 2161 | 1525 | 7746 |
| sternhalma/direct | 5009 | 2217 | 2516 | 9742 |
| Bike Wars/tea | — | — | — | release rejected |
| Bike Wars/direct | — | — | — | release rejected |

Direct's whole-bundle changes against tea are **Conduit +6,581 B /
20.97%; full TodoMVC +561 B / 6.29%; Sternhalma +1,996 B / 25.77%**.
The conditional Conduit target is ≤0.7× the contract’s 30,842 B baseline,
21,589.4 B. It is not achieved; its shared-site/pair-gate precondition fails
too. Passing built visit prediction is not acceptance of that byte hypothesis.
These are the full routing/editing/persistence TodoMVC sources, not the
reduced benchmark variants in §4.

**Native messages, untraced capture-to-eight-microtasks ms, median [Q1–Q3],
20 fresh pages per platform/message.** Every recorded app result satisfies
the harness's resulting DOM/property/error checks; TodoMVC persistence settles.
The two-platform transcript signatures agree for every measured full-app page.

### Conduit

| Message | Tea | Direct | Direct / tea |
|---|--:|--:|--:|
| feed tab | 0.6650 [0.6400–0.7363] | 0.7200 [0.7000–0.7488] | 1.0827× |
| favorite | 0.5000 [0.4875–0.5212] | 0.5450 [0.5187–0.5688] | 1.0900× |
| editor keystroke | 0.6000 [0.5850–0.6312] | 0.5600 [0.5450–0.5850] | 0.9333× |

### Full TodoMVC

| Message | Tea | Direct | Direct / tea |
|---|--:|--:|--:|
| add at 100 | 0.6850 [0.6637–0.7475] | 0.6775 [0.6462–0.7162] | 0.9891× |
| toggle at 100 | 0.3850 [0.3688–0.4263] | 0.3475 [0.3325–0.3875] | 0.9026× |
| clear at 100 | 0.7750 [0.7637–0.8112] | 0.7875 [0.7600–0.8912] | 1.0161× |

### Sternhalma

| Message | Tea | Direct | Direct / tea |
|---|--:|--:|--:|
| choose two players | 8.1450 [5.4900–8.2637] | 4.8325 [4.6987–5.4087] | 0.5933× |
| new game | 3.0350 [2.4688–3.3225] | 4.3450 [4.2138–4.4412] | 1.4316× |

Conduit is mixed: feed/favorite favor tea by their point medians; editor
input favors direct, with some boundary overlap in the IQRs. Full TodoMVC is
close except its modest toggle improvement. Sternhalma selection has a **40.7% lower pooled direct median**, but tea is
bimodal: six observations are 4.915–5.500 ms and fourteen are
8.015–8.480 ms. The pooled tea median lies in the upper mode. Direct spans
4.605–8.060 ms, including its high observation; comparison with tea's lower mode gives a much smaller gap
and some overlap. The bimodality is unexplained; tiering, scheduling or which
queued work the eight-microtask boundary includes were not isolated.
A read-only post-review split finds low-mode sample indices 0, 5, 7, 12,
14 and 19: three run first and three second; the high mode splits seven/seven.
The observed mode is therefore not associated with first/second position in
these twenty samples, and low observations are not confined to early pages.
This does not establish a cause or rule out other scheduling/tiering effects.
Reset's direct median is 43.2% higher within this same interval. Neither
contrast measures layout/paint or whole user-perceived latency, and selection
is not used below as a settled 40.7% platform win. These setup/reset operations
do not price drag/drop gameplay.

### Bike Wars

On the frozen revision, **both production releases fail `debug_in_release`**:
`Debug.log` at `examples/bike-wars/src/Helpers.beni:69:13`. Both development
and test-only `--release --allow-debug` probes build successfully on both
platforms. Thus research 98's old direct document-helper blocker is cleared;
this failure is the release policy applied to app source, not an unresolved
direct ownership or lowering rejection. No test-only bundle is presented as
production bytes or used for substitute timings.

Master advanced during the fixed batch: `62b91b10a` removes that log and
`682515f0b` adds paired Bike Wars browser coverage. This report does not claim
current master cannot build the game; its production timing/byte cells are
unavailable on the frozen comparison source. §9 adds the release bytes of a
later master.

## 4. Criterion 6: the deferred timing, rejudged

These are **both required benchmark variants**, each on both platforms,
plus the existing vanilla subject: sandbox has editing but no persistence or
routing; NoEditing has routing and line persistence but no editing. Vanilla
retains upstream JSON persistence/editing and commits add on Tab/change,
where beni commits on Enter/keydown. They are documented benchmark subjects,
not feature-identical reference applications.

**Untraced ms, median [Q1–Q3], 20 fresh pages/cell, at both sizes.**

| Size / message | Tea sandbox | Direct sandbox | Tea routing | Direct routing | Vanilla |
|---|--:|--:|--:|--:|--:|
| 100/add | 0.7275 [0.6100–0.8575] | 0.6150 [0.5437–0.6687] | 1.5650 [1.2512–1.9800] | 1.2275 [0.9900–1.3850] | 2.1500 [1.9087–2.7238] |
| 100/toggle | 0.3925 [0.3550–0.5388] | 0.3900 [0.3238–0.5300] | 0.8750 [0.6250–1.0825] | 0.7700 [0.6650–0.8775] | 0.4675 [0.3188–0.5700] |
| 100/clear | 0.8350 [0.7287–1.0812] | 1.1475 [0.9825–1.6975] | 1.5400 [1.1188–1.8238] | 1.3950 [1.0338–1.7963] | 1.6125 [1.0725–2.0100] |
| 1000/add | 0.6050 [0.5525–0.6262] | 0.7050 [0.6837–0.7263] | 1.0500 [1.0262–1.1812] | 1.1375 [0.9938–1.2087] | 9.5625 [9.5500–9.7225] |
| 1000/toggle | 0.4450 [0.4000–0.4813] | 0.4200 [0.3850–0.4488] | 0.6400 [0.5587–0.6800] | 0.5900 [0.5025–0.6675] | 0.9450 [0.8863–1.0750] |
| 1000/clear | 3.4225 [3.3600–3.5325] | 3.2475 [3.2188–3.5163] | 3.5100 [3.2925–3.7137] | 3.2600 [3.1987–3.4563] | 7.5250 [7.2912–7.6462] |

| Size / message / variant | Direct / tea | Direct / vanilla |
|---|--:|--:|
| 100/add/Sandbox | 0.8454× | 0.2860× |
| 100/add/NoEditing | 0.7843× | 0.5709× |
| 100/toggle/Sandbox | 0.9936× | 0.8342× |
| 100/toggle/NoEditing | 0.8800× | 1.6471× |
| 100/clear/Sandbox | 1.3743× | 0.7116× |
| 100/clear/NoEditing | 0.9058× | 0.8651× |
| 1000/add/Sandbox | 1.1653× | 0.0737× |
| 1000/add/NoEditing | 1.0833× | 0.1190× |
| 1000/toggle/Sandbox | 0.9438× | 0.4444× |
| 1000/toggle/NoEditing | 0.9219× | 0.6243× |
| 1000/clear/Sandbox | 0.9489× | 0.4316× |
| 1000/clear/NoEditing | 0.9288× | 0.4332× |

| Release variant | Tea brotli B | Direct brotli B | Direct − tea B |
|---|--:|--:|--:|
| Sandbox | 6169 | 6774 | 605 |
| NoEditing | 8258 | 7096 | -1162 |
| Vanilla reference | 1722 | — | — |

**Criterion 6 fires on bytes and timing.** Sandbox is 605 B / 9.81%
larger; routing is 1,162 B / 14.07% smaller. At 1,000 todos, sandbox add is
1.1653× tea with separate IQRs; routing add is 1.0833× by its median with
overlap. Sandbox clear at 100 is 1.3743× tea with overlapping IQRs. The other
cells improve or nearly tie tea; in particular **clear at 1,000 is faster in
both direct variants in this batch**, not an excuse carried forward from
earlier results. The amendment's premise—direct smaller on both variants
and faster at 100 todos—therefore no longer holds on this measured revision:
Sandbox is larger and its 100-todo clear point median regresses.

Against vanilla, routing toggle at 100 is 1.6471×, missing the 1.2× target;
both 1,000-todo toggles satisfy the special 1.3× bar. Routing's 7,096 B also
misses both 2× current vanilla (3,444 B) and the fixed 4,246 B Svelte reference.
The amendment deferred the timing decision to S8, not beyond it. S6/S7's
possible future improvements do not turn these measured misses into passes.

## 5. Statistics, built visits and correctness

The historical enumerator on this frozen master, without the new extra-app
hook, covers **103 programs**. Explicit Sternhalma and Bike Wars projects add
two supplemental real-app checks, for **105**. Static checks exclude the
eight separate Conduit page programs as the existing protocol specifies.
The ledgers are separated here because extending a population can change a
median-based test; no threshold or inconvenient fixture is removed.

| Population on frozen master | Programs | Static rows / over 5% | Value-root exceptions | Bounded pair-series size |
|---|--:|---|---|--:|
| Default enumerator | 103 | 95 / 52 | ValuePath 2/7; none with >3 roots | 78 |
| Supplemental app checks | +2 | +2 / +2 | Sternhalma 5/12; Bike Wars 7/9 | +2 |
| Expanded census | 105 | 97 / 54 | All three above | 80 |

Criterion 1 already fires in the default population: static fixtures,
ValuePath's fraction, dynamic navigation, the pair test and trie writer.
The real-app >3-root and 33%/50% static findings belong to the supplement.
The “no value roots” statement in browser-direct.md's helper amendment is
about **Conduit**, whose 79 sites / zero roots are unchanged, not the entire
corpus. The older [research-97 S0 artifact](../../../bench/conduit/results/2026-10-15-profiles/s0.json)
already contains ValuePath 2/7. There is no new reversal from zero to two
corpus roots here. Navigation 9/62 and Conduit 782/96 are likewise
reconfirmations of known tripwires, not newly discovered regressions.

| Criterion 1 component | Measurement | Verdict / mechanism |
|---|--:|--:|
| Conduit bounded keys | 96/97 = 98.97% | passes ≥ two thirds |
| Static constructors | Conduit 1/75 = 1.33%; Sternhalma 2/6 = 33.33%; Bike 1/2 = 50%; 54/97 rows >5% | fires; rebuilt model variants / opaque updates widen keys |
| Dynamic patchAll | Reader 2/18, Editor 1/12, Tour 6/32; total 9/62 = 14.52% | fires >10%; ChangedUrl navigation is a star key |
| Value roots | ValuePath 2/7; Sternhalma 5/12; Bike 7/9 | fires >5% and, in real apps, >3; value placements retain fallback traversal |
| Pairs versus keys | Conduit 782/96 = 8.1458; median ratio 0.3333; two-times bar 0.6667 | fires; shared helper/site fan-out across keys |
| Set-only trie write half | fromPlain + trieSet reached; indexedMap control reaches neither | fires; persistent List representation/path-copy cost |

The pair series has 80 programs with bounded keys; its log-log fitted
exponent is 1.5121, a descriptive cross-program fit, not a proof of asymptotic
complexity. The specified largest/median test fails by itself, in both ledgers: the
largest and median ratios are unchanged by the two additions. Its 0.6667 bar
is driven by low-ratio small/guard fixtures, making it a weak diagnostic of
asymptotic growth on real applications. The fitted exponent is another
descriptive view of heterogeneous programs; neither establishes a complexity
law. “Any realistic program must fail” is not demonstrated, and the owner’s
bar is not silently replaced. Adding the real
apps exposes material fallback shapes: Sternhalma's SetPlayers/Reset are star
keys; Bike's `KeyDown · Nothing` is star. Five and seven value roots respectively
are not just synthetic corpus stress cases. Their direct plans retain the
declared rule: a placement gates entry, then entered unbound values visit all
their dynamic groups. This is safe fallback behavior with measured costs.

**Criterion 7 passes its observed comparison.** All 62 independently predicted
instance/group sets match actual entries before comparisons. All nine actual
patchAll calls match star keys; the five empty-write Internal messages call
zero groups. This pass is limited to those **three Conduit scripts**:
full TodoMVC, Sternhalma and Bike Wars were not included in this separately
recorded predicted-versus-actual visit-count comparison. This does not waive
criterion 1's excessive frequency or count
capture/preparation/selection as free.

| Correctness check | Result | Scope / limitation |
|---|--:|--:|
| zorg build gates | **exit 0**, 53.66 s | Unit/black-box, paired corpus/value fuzz/verify, formatting; x86-64 Linux hardware instruction budget. |
| zorg build test-browser | **exit 1**, 147.05 s | 568 corpus cases, one Sternhalma expected-versus-Chrome golden mismatch. |
| Timed native app postconditions | all pass | 200 full-app + 240 Conduit pages; full-app DOM/properties/title/error signatures and Todo persistence agree. |
| Full V3 adversarial campaigns | owed | Neither ordinary corpus passes nor these measurement postconditions replace them. |

The entire retained **4,988-line Sternhalma expected/actual transcript
matches after normalizing only decimal pixel numbers inside style attributes
to six significant digits** (1,456 changed lines). For example, expected
`275.751289px` is Chrome's `275.751px`. The raw failure and
[diagnostic method/hashes](../../../bench/s8/results/chrome-sternhalma-diagnosis.json)
remain committed. No golden was blessed and native Chrome was not repeated. This identifies
evidence consistent with a CSS serialization oracle mismatch, rather than
an observed stale screen. That causal classification is an inference from
the narrow normalization. No separate full tea-only Sternhalma golden replay
was performed, so this log does not establish whether its full golden would
also fail; the two timed release transitions agree across platforms;
**native validation nevertheless remains red**. The full-app native pairs
cover selection/reset, not a replacement for the full Sternhalma oracle.

The green Linux gate's log contains an informational doc-example warning and
a misleading “failed command” print, exactly as research 87's green log does;
the command exits zero and the example summary says OK. The Chrome command
really exits one. Both statuses and times are retained in `validation.json`.
The owner's documented blur-between-handlers ordering difference retains its
per-platform Chrome goldens; intended differences are not counted as defects.
Criterion 8 is therefore reported as incomplete acceptance, not inferred green
from the absence of an observed differential failure.

## 6. Mechanisms and protocol

**Helper-heavy applications pay a real representation cost.** Conduit's
same-source direct bundle is 6,581 B (20.97%) larger than tea. The table,
which emits no parameterised helper protocol, is 1,025 B (19.11%) smaller.
The independent archived-source probes find Conduit has 331 consumer-matrix
entries / 53 distinct masks, 146 group descriptors, 146 patch entry functions
and 57 restate functions. These are emitted definitions, not the 114 analysis
leaf groups or a count of active instances. The matrix occupies 41,039 raw bytes but stubbing
it saves only 1,545 brotli bytes; patch declarators occupy 20,935 raw bytes and
save 3,507 B when stubbed alone. Descriptor and restate removals save 572 and
76 B alone. These are broken programs, not executable optimisations, and the
savings cannot be summed. They locate costs; they do not establish recoverable
budget. Full TodoMVC has 19 matrix entries / seven masks and four patch
entries; Sternhalma has fourteen patch entries and no matrix; table has neither.

Research [95](95-parameterised-markup-templates.md)'s helper entries preserve
captured inputs, instance ownership, controlled properties and restates. Removing
those guarantees to make the bundle small would change the platform contract.
Research [99](99-direct-bytes.md) prices shorter path IDs and other encodings
against an earlier bundle, not an unimplemented saving credited to this one.
Its older Conduit direct baseline is 37,768 B; this frozen revision is 37,970 B
following placement/eligibility fixes. Research [101](https://github.com/canassa/beni/blob/d10749f70a2060230c99cd196d70c15c2666eb9b/docs/design/research/101-conduit-byte-floor.md)
independently gets 37,970 B. Its shared-selection/lexical-factory redesign has a
conditional 0–2 kB planning envelope, not evidence that all 6.6 kB can disappear.
The cost is conditional on application shape; neither a universal 20% penalty
nor an inherent lower bound for precise updates is established.

Later research [102](https://github.com/canassa/beni/blob/1c5d160494268bc7aa963f662e4bf41234b6c63a/docs/design/research/102-beni-output-size.md)
on newer source reports executable prototypes: single-use top-level inlining
saves 1,577 B direct / 180 B tea; compiled request-body printing, with the typed
error retained, saves 2,154 / 2,319 B. Their combined bundles are 34,515 /
29,353 B, still a 5,162 B gap. These are useful contrary evidence to an
inevitable fixed byte floor, not changes present in this frozen batch or
savings added to its deletion probes. Their source revision and baselines
differ from this report.

**Group precision and whole-message work are different claims.** Conduit's
62 observed dispatches call the groups predicted by analysis, so criterion 7
can pass while criterion 1's dynamic navigation count fails. Nine `patchAll`
dispatches are 14.52%, exceeding 10%; six occur in the deliberately navigating
Tour, two in Reader and one in Editor. `ChangedUrl` is a `*` key by design.
Five empty-write `Internal` messages call zero groups, yet capture, preparation,
consumer selection and scheduling can still run. Correct group counts do not
prove the whole operation is cheap. Research
[97](97-conduit-dispatch-profiles.md)'s profiles explain this distinction;
this campaign does not claim a new native/JS microsecond decomposition.

**Ownership errors remain a developer-facing cost.** Research
[98](98-browser-app-ownership.md) identifies three idiomatic repairs developers
will meet: allocate an initial model inside `init ⊤` rather than returning a
top-level seed from a lambda; encode a queued persistence snapshot before
constructing the command closure; copy a retained list before appending to its
base. Sternhalma similarly needs a fresh board for each game. The errors include `top_level_list_changed`, `list_still_used` and the
approximate `list_may_be_shared`. Several diagnostic sites can arise from one
shared append root, as Bike Wars demonstrates.
`list_may_be_shared` is deliberately conservative, not proof that ordinary
native input has already corrupted the app. TodoMVC's original witness requires
two synthetic sends in one task; only intermediate cross-tab storage events
differ in the full app, not its native-input UI or final stored value. Captured
view environments can retain models too; an init-function surface alone does
not establish ownership. The guarantees matter, but understanding allocation,
retention and queued snapshots is a material usability burden.

**Table update does not become an indexed DOM edit.** The emitted `Update`
uses an indexed map to create the 100 changed row records, then `walk` compares
all 1,000 instance identities and calls a separate label writer for each change.
P3 also walks, but keeps its marked-row writer in its own loop. This revision
additionally emits `groupProgram` / `groupOnce`: the dispatch advances an epoch,
and each affected instance/group reads and writes its `$$directGroups` stamp
before the label writer. The source-map-identified declarations are archived in
`helper-anatomy.json`. They prevent overlapping structural/read visits from
running a group twice; their absence on a helper-free page is not established.
Research 87's earlier profiles located its update gap in the walk and writer,
but their microsecond counts are not transferred to this different bundle.
This batch identifies the extra operations without pretending to price each.
The create-1,000 point miss has a wide overlapping IQR: keyed row bookkeeping,
DOM cloning and the seeded data builder are all in that interval, and no fresh
profile separates their contributions. It is not a resolved isolated renderer
regression.

**TodoMVC's filtered list still reaches the general reconciler.** Both benchmark
variants render `For each={List.filter model.todos …}`. The source's precise
message does not give an exact index edit for that derived `each`. For add at
1,000, direct scans the retained prefix, then `reconcileRows` allocates the
next-row array, copies that prefix, builds its matching structures and finally
runs `rekeyAll` over the list. Tea's `trimmed` pass retains its key map and
touches map entries for added/removed rows. Both still pay the model/filter
work and persistence where enabled. These concrete different paths are a
mechanism for the add gap, not a measured allocation/CPU decomposition.
Clear removes the first half in this fixture; tea can trim the retained suffix
too, while direct only trims a prefix. That potential disadvantage is not
presented as a measured clear-at-1,000 regression: direct actually wins those
two cells here. Removing rank-correct duplicate handling or changing the
fixture would not test the stated design.

**Rows swap still copies model/list state.** `List.swap` calls `List.set`
twice; the warmed long-list representation path-copies its persistent trie.
The model is spread, then direct's exact `exchange` applies the guarded
rank-correct edit and DOM moves. Vanilla changes two array slots. P3 shares
the persistent-list model cost and its swap IQR overlaps direct's here.
This identifies the work S7 was supposed to remove, while keeping the new
epoch/key/visit machinery distinct; no isolated price claims that it explains
all 32.5 microseconds of the vanilla gap.

**Depth and width are separate limitations.** At depth 128, the write dump
records the eight-step path cap. It widens the leaf write to the subtree,
and the inspected handler calls 121 text groups, with **8,107 child-property
accesses** across those called bodies. The bundle contains 129 object
expressions with spreads, including the nested updates and outer model.
Repeated root-relative paths explain extra work beyond just model copying;
in-place updates alone would leave the widened visits. Width 1,024 still
spreads the whole record to change one field, retaining the wide-object
copy cost that S7 was meant to remove. Their measured 2.8315× and 5.7160×
ratios have a concrete source mechanism, without an isolated microsecond price.

**Live/derived retain a fixed path but do not meet the vanilla bar.** The
archived live tick is `()=>{_(null);d={...d,d:d.d+1};q()}`; helper rows similarly
advance the epoch, spread the model and call one root group. Derived's tick
also does not sort/filter or traverse its list again. Controlled restoration,
guards and host work remain part of the elapsed interval. The source rules
out an explicit row walk in those tick handlers; it does not decompose the
remaining 45 microseconds at live 10,000 or prove flat elapsed time. Their byte
floors retain mount-time rows/control machinery or filter/sort code. The
unresolved native/JS share is kept open, as in research 87, rather than a
claimed new causal profile.

### Measurement protocol and provenance

The measurement checkout on **azathoth**, `~/src/github.com/canassa/beni`, was
pulled to master **`6c327a9f17050941bc170f9e888160795ca471f5`** before preparing
this batch. No compiler, core, platform or application source was changed.
The compiler was built there with **`zorg build -Doptimize=ReleaseFast`**,
then frozen as `zig-out/beni-s8-frozen`: SHA-256
`af3e0494dbad405fd55ef5abe87127040d31468d27e6566d8a49854b8c37b0d9`,
build ID `7445da00731bab8c2bf686c8b48bf033`.

The machine is an Intel Xeon E-2386G, six physical cores/twelve logical CPUs.
Chromium **153.0.8010.36**, Node **24.19.0**, and Zorg **0.17.1+zorg.1**
run in `nix develop .#browser`. Harnesses use **0–1,6–7**; Chrome and its
children use **2–5,8–11**, as in research [87](87-direct-platform-s4.md) §1.
The existing **powersave / balance_performance** settings are retained.
These are dedicated cores by scheduling, not kernel isolation. An older idle
headless Chrome process (parent PID 1, observed about 0.1–0.2% CPU) remained
running; this is not a claim of strict process isolation. The captured
live `/proc` affinities, full executable/source SHAs, package versions, CPU
siblings, governor and machine details accompany the results.

The counts were announced before timing: official JFB **four rounds × five
ordinary CPU/memory observations per cell**, with the upstream select protocol's
additional ten observations yielding **60 select observations** over four
rounds; native size/first-paint has four observations. UI table: **20 fresh
pages per operation/candidate**. Sweeps: **two pages, five warm-ups and twelve
measured clicks per page**, or 24 observations clustered in two pages; stream
has **two three-second windows**. TodoMVC criterion 6 and each full-app message:
**20 fresh pages per cell**. Conduit also has a separate 20-page traced pass.
Nothing was selectively repeated, trimmed or extended after seeing results.
The new full-app harness also had a setup-only virtual-frame stall before
its first timed message. A live CDP snapshot shows its stopwatch was not yet
installed; setup was corrected and the entire app grid started at zero retained
observations. Earlier phases were not repeated.

The JFB, UI table and app orders rotate, with two-platform app comparisons
alternating. Sweep order is weaker: page 0 uses Tea, Direct, Solid 2,
Solid 1, P3 where available, Vanilla; page 1 shifts that list once. Every
cell repeats those same two positions per candidate. It is a fixed,
two-position rotation, not balanced across all available positions (five or six), and a position
effect can bias every ratio the same way.
Fresh pages share browser processes; they are not fresh browser launches.
The 200-page full-app grid ran from 15:16:00.065 to 15:16:17.177 UTC:
17.112 seconds, about 85.56 ms of wall time per page including setup, input,
postconditions and close. Each row gets a new CDP target in the same browser;
there is no frame wait or CSS load. That throughput is not its message latency.

The initial preparation mistakenly overlapped a compiler build. When the
compiler SHA mismatch was found, the entire affected JFB epoch was invalidated,
not just its slower/faster cells. Its raw data and explanation remain under
`results/invalid-build-race/` and are excluded from all tables. The completed
compiler was frozen, every candidate rebuilt, and an artifact barrier recorded
before the clean campaign; the same hashes are checked after timing. No app or
sweep timing from the invalid epoch is used. The original two-hour estimate
underpriced upstream memory sampling. After the setup correction the owner
explicitly answered **“Finish the fixed batch”** to preserving the original
counts rather than stopping near two hours. `PROTOCOL.md` retains the original
plan, attempted global caps, correction and that superseding instruction.

Official JFB is commit **`44f20790ba5ce71f5e782dc1b19a25cc9c628dbc`**, using
its own browser driver, throttles, memory protocol and report. Single-framework
invocations enforce the requested rotation because upstream's framework
argument order is not execution order. No measurement implementation is
replaced. The pooled report concatenates all four rounds' observations and
recomputes their statistics; every round's native report is also retained.
Short throttled script numbers are descriptive, not evidence of parity.

Research [84](84-throttled-short-operations.md)'s rate-1 protocol applies to
the UI and app comparisons. The UI table reports trace-derived **script time**;
ordinary sweeps report **untraced capture-to-microtask elapsed time**. App
messages report **capture through eight microtasks**, including queued work;
setup is outside the interval. The existing UI-table, ordinary sweeps and criterion-6
TodoMVC setup includes forced GC outside timing; the new full-app and Conduit
message harnesses do not force GC. TodoMVC's existing six toggle warm-ups stay
outside timing. Conduit uses scripted API fixtures; the full apps use their
fixture environment without CSS and Sternhalma uses its virtual clock. The
Sternhalma operations are native clicks, not a synthetic drag presented as
native input. These intervals must not be mixed numerically with each other
or with JFB's click-to-paint total. All tables give median and **[Q1–Q3]**,
using linear interpolation, with no outlier deletion. IQRs describe these
samples, not confidence intervals. The 24 sweep clicks have only two page
clusters; the two stream windows cannot certify the stream threshold.

Brotli is Node zlib quality **11 with input-size hint**, all emitted release
JavaScript, including its trailing newline; maps, HTML, CSS and unloaded direct
plans are excluded. No external minifier changes the full-app download figures. The legacy
`todo-sizes.json` omitted the size hint; `todo-release-bytes.json` reprices the
exact timed files consistently, checks their hashes and archives them.
Mapped builds must reproduce the executable bytes. Ordered initializer stubs
charge core first, runtime second, then app/startup/residual, with no DCE or
reoptimisation. Those charges sum exactly but depend on order and compression
context. Independent deletion prices are diagnostic and **cannot be added**.
Criterion 5 separately uses the existing normalized `size-parts.mjs` protocol
and core's **leave-one-out** share, as the contract requires.

Master advanced during the fixed campaign. In particular `62b91b10a` removes
Bike Wars' `Debug.log`, and `682515f0b` adds its paired browser coverage. The
measured failure is a fact about the frozen starting revision, not a claim
that current master cannot release-build the game. Research
[101](https://github.com/canassa/beni/blob/d10749f70a2060230c99cd196d70c15c2666eb9b/docs/design/research/101-conduit-byte-floor.md), published during this run, independently
reproduces this batch's Conduit bytes and bounds representation redesigns;
its external references have feature gaps and do not replace this batch's
like-for-like tea/direct comparisons.

The original audit checked retained counts and hashes. The
[review audit](../../../bench/s8/results/review-audit.json) additionally verifies
twelve ordered observations on each of two sweep pages, every available P3
cell, all 208 JFB invocations against the operation/round rotation in the logs,
180 UI-table iterations, 120 Todo rounds and 100 app rounds. App position is
inferred from chronological append order, not an independently recorded
position field; Conduit records explicit positions and balances both modes.
These assertions read existing evidence and add no observations.

The Conduit order repair is applied before any timing in this batch. With
only two subjects, the old rotate-then-reverse loop cancelled rotation and
always ran tea first. The 2026-10-14 two-subject artifact is order-confounded;
the sign change here must not be treated as a causal platform improvement.
This does **not** invalidate the three-subject comparisons in research 95/97:
their [research-95 timing](../../../bench/conduit/results/2026-10-15-timing.json)
and [research-97 timing](../../../bench/conduit/results/2026-10-15-profiles/timing.json)
name tea, old direct and new direct, for which
rotate/reverse does rotate positions. Machines, source and modes also differ
across those studies; no before/after speed attribution is made here.

Full provenance is [recorded here](../../../bench/s8/results/provenance.json):
kernel 6.18.55, 33,558,818,816 RAM bytes, executable SHA-256s and all twelve
governor/preferences. JFB round peak one-minute loads were 2.44, 0.82, 1.62
and 1.14. The final prepared-artifact verification and empty production-source
diff establish the frozen inputs. The full timing/audit inputs are under
[bench/s8](../../../bench/s8/README.md); `summary.json` uses `samples` for
observation counts so TodoMVC's `n` remains its 100/1,000 scenario dimension.

After the red native check, the post script stopped. Only the unfinished
source-diff/provenance collection resumed at that point.
The later review changed read-only audit/analysis code, so the full Linux gate
was run again: **39.59 s, exit 0**, recorded in
[review validation](../../../bench/s8/results/review-validation.json).
Native Chrome and all comparisons were left unchanged.
The original source fingerprints correspond to the files in commit
`95d875e7b`; that commit preserves the measurement/report code. The later
analysis scripts have their own hashes in the review validation. Timing
harnesses, application bundles and raw observations did not change.

## 7. Complete research-87 grids

Columns use the same six UI candidates throughout. **Ordinary cells: untraced
real-click ms, median [Q1–Q3], 24 observations from two pages.** Stream is the
explicit exception: traced script ms/message, two three-second windows.
“—” means no P3 generator, not a failed candidate or an invented comparison:
29 unavailable build points correspond to 33 operation/size cells.

### holes/tick

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 10 | 0.2000 [0.1900–0.2100] | 0.3750 [0.3500–0.4100] | 0.4400 [0.4187–0.5600] | 0.3025 [0.2938–0.3275] | 0.2225 [0.2087–0.2600] | 0.2225 [0.2087–0.2463] |
| 30 | 0.2175 [0.2075–0.2413] | 0.4225 [0.4000–0.4475] | 0.4300 [0.4013–0.5463] | 0.3250 [0.2837–0.3750] | 0.2450 [0.2100–0.2650] | 0.2275 [0.2150–0.2687] |
| 100 | 0.2400 [0.2075–0.2650] | 0.3600 [0.3500–0.3825] | 0.4750 [0.4387–0.5350] | 0.3700 [0.2975–0.4025] | 0.2175 [0.1988–0.2363] | 0.2300 [0.2175–0.2475] |
| 300 | 0.2000 [0.1875–0.2050] | 0.3625 [0.3500–0.3912] | 0.4350 [0.4050–0.5588] | 0.3050 [0.2787–0.3350] | 0.2200 [0.1975–0.2350] | 0.2250 [0.2000–0.2463] |
| 1000 | 0.2050 [0.1900–0.2200] | 0.3625 [0.3388–0.4213] | 0.4650 [0.4237–0.5475] | 0.3025 [0.2850–0.3462] | 0.2100 [0.1600–0.2300] | 0.2250 [0.2150–0.2450] |
| 3000 | 0.2025 [0.1900–0.2150] | 0.3725 [0.3550–0.3812] | 0.4250 [0.4187–0.5462] | 0.3700 [0.3388–0.4112] | 0.2375 [0.2187–0.2713] | 0.2175 [0.2087–0.2450] |
| 10000 | 0.2000 [0.1750–0.2100] | 0.3375 [0.3200–0.3550] | 0.3950 [0.3688–0.4225] | 0.2925 [0.2600–0.3313] | 0.2025 [0.1813–0.2150] | 0.2250 [0.1888–0.2650] |

### rows/change

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 10 | 0.2450 [0.2188–0.2850] | 0.3750 [0.3588–0.4475] | 0.5225 [0.4725–0.5600] | 0.3250 [0.2988–0.4313] | 0.2550 [0.2450–0.2713] | 0.2975 [0.2562–0.3313] |
| 30 | 0.2125 [0.1938–0.2375] | 0.3650 [0.3487–0.3775] | 0.5350 [0.4550–0.5812] | 0.3900 [0.3075–0.4575] | 0.2450 [0.2400–0.2850] | 0.2750 [0.2537–0.3363] |
| 100 | 0.2150 [0.2050–0.2312] | 0.3675 [0.3450–0.4413] | 0.4700 [0.4250–0.5450] | 0.3550 [0.3250–0.4200] | 0.2400 [0.2338–0.2775] | 0.2675 [0.2438–0.3075] |
| 300 | 0.2225 [0.2038–0.2313] | 0.3900 [0.3588–0.4750] | 0.4450 [0.4050–0.5562] | 0.4900 [0.4188–0.5500] | 0.3050 [0.2625–0.3713] | 0.2750 [0.2500–0.3725] |
| 1000 | 0.2125 [0.2050–0.2313] | 0.3800 [0.3550–0.4725] | 0.4500 [0.4137–0.5550] | 0.3900 [0.3738–0.4913] | 0.2675 [0.2488–0.3588] | 0.3525 [0.2850–0.4025] |
| 3000 | 0.1650 [0.1587–0.1813] | 0.3000 [0.2800–0.3563] | 0.3450 [0.3188–0.3750] | 0.4400 [0.3300–0.5700] | 0.2050 [0.1900–0.2338] | 0.2375 [0.2088–0.3037] |
| 10000 | 0.1175 [0.0987–0.1450] | 0.1725 [0.1637–0.1800] | 0.2075 [0.1887–0.2612] | 0.3525 [0.3425–0.4000] | 0.1550 [0.1287–0.1850] | 0.1575 [0.1200–0.1825] |
| 30000 | 0.0850 [0.0800–0.0963] | 0.1450 [0.1337–0.1550] | 0.1975 [0.1788–0.2163] | 0.5525 [0.5137–0.6013] | 0.1025 [0.0950–0.1200] | 0.1250 [0.0950–0.1300] |

### rows/swap

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 10 | 0.3150 [0.3025–0.3362] | 0.5925 [0.5338–0.6425] | 0.8050 [0.7150–0.8513] | 0.5250 [0.4388–0.5612] | 0.3925 [0.3537–0.4362] | 0.3575 [0.3425–0.3937] |
| 30 | 0.3350 [0.3137–0.3738] | 0.6750 [0.6025–0.7162] | 0.7650 [0.7025–0.8662] | 0.4925 [0.4487–0.5775] | 0.3800 [0.3550–0.4463] | 0.3500 [0.3250–0.4475] |
| 100 | 0.3250 [0.3000–0.3563] | 0.7275 [0.6300–0.7875] | 0.8975 [0.8375–1.0787] | 0.6550 [0.6012–0.7425] | 0.3875 [0.3612–0.4125] | 0.3400 [0.3187–0.3975] |
| 300 | 0.3775 [0.3200–0.4663] | 1.0400 [0.9750–1.1563] | 1.2350 [0.9975–1.4788] | 0.6975 [0.5888–0.7325] | 0.4875 [0.3625–0.5275] | 0.4575 [0.3713–0.5000] |
| 1000 | 0.3150 [0.3000–0.3413] | 1.5600 [1.4962–1.6250] | 1.5950 [1.3475–2.3112] | 0.8100 [0.7900–0.9150] | 0.3625 [0.3388–0.4050] | 0.3725 [0.3500–0.3963] |
| 3000 | 0.2525 [0.2237–0.3313] | 3.9650 [2.2563–4.2363] | 1.8425 [1.6962–3.0525] | 0.5050 [0.4613–0.5525] | 0.2900 [0.2525–0.3400] | 0.3550 [0.2812–0.3950] |
| 10000 | 0.1550 [0.1450–0.1600] | 4.9300 [3.3825–6.1388] | 2.5375 [2.4262–3.3413] | 0.5950 [0.5475–0.7575] | 0.1750 [0.1637–0.1813] | 0.2000 [0.1750–0.2225] |
| 30000 | 0.1300 [0.1250–0.1400] | 6.9800 [5.1450–8.0213] | 4.5500 [4.4613–4.6238] | 0.9950 [0.9575–1.3063] | 0.1625 [0.1450–0.1863] | 0.1500 [0.1438–0.1950] |

### filtered/toggle

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.1975 [0.1737–0.2150] | 0.3550 [0.3350–0.3900] | 0.4825 [0.4150–0.5525] | 0.3600 [0.3250–0.4638] | 0.4025 [0.3475–0.4600] | — |
| 1000 | 0.2050 [0.1850–0.2250] | 0.4000 [0.3575–0.4613] | 0.4100 [0.3887–0.4825] | 0.3925 [0.3650–0.4563] | 0.5525 [0.4637–0.7263] | — |

### filtered/filter

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 1.0375 [0.4763–1.6825] | 2.5350 [2.1337–3.9375] | 3.1750 [2.3425–4.0675] | 3.0200 [2.0100–3.5125] | 2.3300 [1.8537–3.2375] | — |
| 1000 | 4.8425 [2.2887–6.6925] | 11.655 [7.8525–13.614] | 9.9700 [8.1437–12.986] | 9.6950 [7.3412–12.558] | 8.6475 [6.9938–12.830] | — |

### filtered/tick

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.2025 [0.1850–0.2412] | 0.3750 [0.3400–0.4387] | 0.4800 [0.4237–0.5750] | 0.3150 [0.2937–0.3650] | 0.2100 [0.1950–0.2412] | — |
| 1000 | 0.2175 [0.1800–0.2275] | 0.3875 [0.3538–0.4100] | 0.4875 [0.4237–0.5663] | 0.2850 [0.2600–0.3163] | 0.2000 [0.1787–0.2125] | — |

### width/field

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 4 | 0.2100 [0.1987–0.2200] | 0.4050 [0.3850–0.4400] | 0.5200 [0.4850–0.7275] | 0.3300 [0.3113–0.3662] | 0.2400 [0.2238–0.2575] | — |
| 8 | 0.2125 [0.1937–0.2212] | 0.4125 [0.3888–0.4400] | 0.5950 [0.5087–0.6725] | 0.3475 [0.3000–0.3762] | 0.2150 [0.2050–0.2363] | — |
| 16 | 0.2050 [0.1987–0.2263] | 0.4150 [0.3900–0.4325] | 0.5300 [0.4988–0.6700] | 0.3250 [0.3013–0.3413] | 0.2225 [0.2100–0.2488] | — |
| 17 | 0.2050 [0.1987–0.2425] | 0.4100 [0.3800–0.4313] | 0.5950 [0.5425–0.7075] | 0.3175 [0.2875–0.3487] | 0.2475 [0.2250–0.2687] | — |
| 20 | 0.2050 [0.1950–0.2213] | 0.4125 [0.3838–0.4575] | 0.5200 [0.4975–0.6787] | 0.3400 [0.3050–0.3550] | 0.2225 [0.2050–0.2475] | — |
| 32 | 0.2025 [0.1888–0.2150] | 0.4075 [0.3837–0.4888] | 0.5075 [0.4787–0.6775] | 0.3250 [0.2850–0.3687] | 0.2400 [0.2100–0.2925] | — |
| 64 | 0.2325 [0.1900–0.2650] | 0.4500 [0.4188–0.4663] | 0.6625 [0.5450–0.7788] | 0.3825 [0.3375–0.4325] | 0.2375 [0.2000–0.2575] | — |
| 128 | 0.2175 [0.1900–0.2500] | 0.4175 [0.3938–0.4538] | 0.6025 [0.5588–0.7675] | 0.3450 [0.3125–0.4387] | 0.2225 [0.2100–0.2525] | — |
| 256 | 0.2400 [0.2000–0.2662] | 0.4375 [0.4025–0.4950] | 0.5525 [0.5187–0.7050] | 0.3675 [0.3537–0.4663] | 0.2625 [0.2287–0.2950] | — |
| 1024 | 0.2025 [0.1850–0.2163] | 0.4200 [0.3937–0.4675] | 0.5425 [0.5150–0.7025] | 1.4275 [1.3900–1.5325] | 1.1575 [1.1325–1.1875] | — |

### depth/leaf

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 1 | 0.2050 [0.1938–0.2163] | 0.4125 [0.3937–0.4575] | 0.5400 [0.5125–0.7562] | 0.3175 [0.3000–0.3862] | 0.2200 [0.2100–0.2363] | 0.2325 [0.2075–0.2563] |
| 2 | 0.2100 [0.1975–0.2213] | 0.4300 [0.4162–0.4463] | 0.5375 [0.5137–0.7388] | 0.3325 [0.3125–0.3663] | 0.2275 [0.2175–0.2550] | 0.2400 [0.2200–0.2650] |
| 4 | 0.2200 [0.2100–0.2300] | 0.4625 [0.4125–0.5062] | 0.5875 [0.5537–0.7500] | 0.3275 [0.3037–0.3688] | 0.2275 [0.2200–0.2438] | 0.2350 [0.2138–0.2500] |
| 8 | 0.2100 [0.2000–0.2300] | 0.4475 [0.4350–0.4950] | 0.5675 [0.5387–0.7812] | 0.3200 [0.3100–0.3875] | 0.2325 [0.2200–0.2413] | 0.2525 [0.2450–0.2975] |
| 16 | 0.2200 [0.1950–0.2300] | 0.4950 [0.4725–0.5650] | 0.7025 [0.6375–0.8025] | 0.3475 [0.3237–0.4325] | 0.2375 [0.2150–0.2712] | 0.2350 [0.2100–0.2912] |
| 32 | 0.2125 [0.1988–0.2188] | 0.5075 [0.4888–0.5538] | 0.9000 [0.7788–1.0288] | 0.4725 [0.4337–0.5950] | 0.2825 [0.2475–0.3187] | 0.2425 [0.2300–0.2775] |
| 64 | 0.2150 [0.2088–0.2262] | 0.5900 [0.5625–0.7037] | 0.9325 [0.7338–1.1487] | 0.5300 [0.4575–0.6512] | 0.4150 [0.3938–0.4588] | 0.3075 [0.2587–0.3613] |
| 128 | 0.2225 [0.2138–0.2450] | 0.8275 [0.6800–1.1113] | 1.3350 [1.1400–1.5038] | 0.6400 [0.5400–0.9863] | 0.6300 [0.5337–0.7413] | 0.3775 [0.2837–0.4363] |

### derived/tick

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.2200 [0.2150–0.2500] | 0.4000 [0.3787–0.4763] | 0.4350 [0.4187–0.5675] | 0.3375 [0.2837–0.3663] | 0.2275 [0.2038–0.2550] | — |
| 300 | 0.2100 [0.2000–0.2200] | 0.3775 [0.3600–0.4088] | 0.4400 [0.4087–0.5750] | 0.3500 [0.3138–0.3700] | 0.2400 [0.2213–0.2750] | — |
| 1000 | 0.2025 [0.1900–0.2500] | 0.4000 [0.3600–0.4500] | 0.4450 [0.4100–0.5463] | 0.3750 [0.3413–0.4250] | 0.2375 [0.2137–0.2662] | — |
| 3000 | 0.2075 [0.1950–0.2200] | 0.3775 [0.3550–0.4275] | 0.4200 [0.4050–0.5525] | 0.2975 [0.2837–0.3750] | 0.2450 [0.2100–0.2687] | — |
| 10000 | 0.2100 [0.1988–0.2313] | 0.3875 [0.3700–0.4212] | 0.4600 [0.4137–0.5725] | 0.3000 [0.2800–0.3700] | 0.2250 [0.2050–0.2413] | — |
| 30000 | 0.2175 [0.2050–0.2362] | 0.4400 [0.3862–0.4513] | 0.4325 [0.4150–0.5738] | 0.3625 [0.2900–0.4112] | 0.2350 [0.2150–0.2562] | — |
| 100000 | 0.2125 [0.2050–0.2250] | 0.3975 [0.3638–0.4463] | 0.5350 [0.4962–0.6550] | 0.3275 [0.2950–0.3912] | 0.2600 [0.2250–0.2800] | — |

### live/tick

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.2400 [0.2200–0.2562] | 0.3775 [0.3537–0.3962] | 0.4625 [0.4187–0.5450] | 0.3350 [0.2950–0.3675] | 0.3275 [0.3037–0.3750] | 0.2175 [0.2088–0.2400] |
| 300 | 0.1975 [0.1850–0.2300] | 0.3675 [0.3488–0.3862] | 0.4550 [0.4100–0.5488] | 0.3275 [0.3088–0.3875] | 0.2550 [0.2450–0.2775] | 0.2250 [0.2050–0.2562] |
| 1000 | 0.2300 [0.1888–0.2500] | 0.3675 [0.3537–0.3900] | 0.4825 [0.4425–0.5250] | 0.3375 [0.3137–0.3837] | 0.2525 [0.2350–0.3000] | 0.2300 [0.2100–0.2862] |
| 3000 | 0.1200 [0.1138–0.1375] | 0.2400 [0.2237–0.2562] | 0.2850 [0.2687–0.3462] | 0.2150 [0.1900–0.2475] | 0.1875 [0.1437–0.2125] | 0.1525 [0.1337–0.1825] |
| 10000 | 0.0700 [0.0687–0.0800] | 0.1400 [0.1300–0.1562] | 0.1875 [0.1675–0.2088] | 0.1650 [0.1475–0.1812] | 0.1150 [0.0950–0.1200] | 0.1125 [0.0750–0.1163] |

### helperRows/tick

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 100 | 0.1925 [0.1837–0.2137] | 0.3550 [0.3488–0.3700] | 0.4500 [0.4100–0.5800] | 0.3150 [0.2887–0.3762] | 0.2200 [0.1950–0.2512] | — |
| 300 | 0.1950 [0.1837–0.2100] | 0.3650 [0.3550–0.3862] | 0.4625 [0.4188–0.5825] | 0.3150 [0.2937–0.3463] | 0.2250 [0.2050–0.2413] | — |
| 1000 | 0.1950 [0.1850–0.2212] | 0.3825 [0.3638–0.3963] | 0.4450 [0.4187–0.5525] | 0.3150 [0.2888–0.3463] | 0.2200 [0.1987–0.2463] | — |
| 3000 | 0.1200 [0.1087–0.1300] | 0.3300 [0.3137–0.3525] | 0.4500 [0.3988–0.5387] | 0.2950 [0.2637–0.3162] | 0.2675 [0.2275–0.2813] | — |
| 10000 | 0.0800 [0.0700–0.0863] | 0.2025 [0.1950–0.2150] | 0.2700 [0.2463–0.3025] | 0.1675 [0.1587–0.1800] | 0.1175 [0.1100–0.1313] | — |

### tree/tick

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 4 | 0.2050 [0.1875–0.2200] | 0.3650 [0.3538–0.3825] | 0.5125 [0.4275–0.5500] | 0.3100 [0.2850–0.3525] | 0.2475 [0.2350–0.2875] | — |
| 6 | 0.2225 [0.1950–0.2762] | 0.3700 [0.3550–0.3812] | 0.4850 [0.4150–0.5562] | 0.3100 [0.2850–0.3413] | 0.2400 [0.2175–0.2625] | — |
| 8 | 0.2050 [0.1950–0.2263] | 0.3825 [0.3638–0.4000] | 0.5100 [0.4375–0.6125] | 0.3325 [0.2800–0.3688] | 0.2850 [0.2350–0.3325] | — |
| 10 | 0.2025 [0.1900–0.2250] | 0.3675 [0.3600–0.3925] | 0.5475 [0.4338–0.5800] | 0.3175 [0.2850–0.3463] | 0.2575 [0.2438–0.2800] | — |
| 12 | 0.2050 [0.1950–0.2113] | 0.3275 [0.2238–0.3612] | 0.3700 [0.3412–0.4750] | 0.3100 [0.2837–0.3413] | 0.2600 [0.2175–0.2850] | — |

### burst/burst

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 1 | 0.2450 [0.2250–0.2875] | 0.4725 [0.4550–0.4925] | 0.4900 [0.4437–0.6475] | 0.4000 [0.3600–0.4500] | 0.2550 [0.2387–0.2812] | 0.2800 [0.2650–0.3100] |
| 3 | 0.2675 [0.2550–0.2963] | 0.6150 [0.5575–0.6662] | 0.5450 [0.5125–0.5963] | 0.4400 [0.4050–0.4663] | 0.3225 [0.2887–0.3600] | 0.2950 [0.2750–0.3075] |
| 10 | 0.3875 [0.3688–0.4262] | 0.9100 [0.8738–1.0162] | 0.6800 [0.6600–0.7362] | 0.6200 [0.5788–0.7313] | 0.4675 [0.3950–0.5375] | 0.4000 [0.3900–0.4250] |
| 30 | 0.7650 [0.7100–0.8150] | 1.7875 [1.6737–1.9013] | 1.2250 [1.1487–1.3275] | 0.9575 [0.8725–1.1262] | 0.7900 [0.7225–0.8338] | 0.6900 [0.6600–0.7187] |
| 100 | 1.8975 [1.7675–2.0688] | 3.6700 [3.5475–3.8638] | 2.8750 [2.7488–3.0575] | 2.4050 [2.0400–2.6625] | 1.8000 [1.7388–1.9525] | 1.5750 [1.4488–1.6812] |
| 300 | 4.7075 [4.5488–4.8162] | 8.7075 [8.5150–8.8637] | 6.7025 [6.6450–6.9050] | 4.5675 [4.4012–4.7138] | 4.7750 [4.6300–4.9388] | 3.8650 [3.7450–4.0550] |
| 1000 | 13.055 [12.864–13.326] | 18.647 [18.260–18.995] | 16.517 [16.271–16.906] | 12.535 [12.400–12.679] | 13.390 [13.240–13.719] | 11.393 [11.211–11.667] |

### stream/stream — two stream windows

| N / K | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |
|---|--:|--:|--:|--:|--:|--:|
| 1 | 0.2358 [0.2355–0.2361] | 0.3886 [0.3878–0.3895] | 0.4855 [0.4801–0.4909] | 0.3553 [0.3486–0.3620] | 0.2606 [0.2599–0.2613] | 0.2972 [0.2951–0.2994] |
| 10 | 0.0431 [0.0428–0.0434] | 0.0693 [0.0689–0.0696] | 0.0695 [0.0689–0.0702] | 0.0509 [0.0501–0.0518] | 0.0416 [0.0416–0.0417] | 0.0463 [0.0452–0.0474] |
| 100 | 0.0192 [0.0191–0.0193] | 0.0315 [0.0315–0.0315] | 0.0277 [0.0277–0.0277] | 0.0191 [0.0188–0.0194] | 0.0192 [0.0192–0.0193] | 0.0176 [0.0176–0.0176] |

## 8. Recommendation

I recommend **stop direct in its current form and keep tea**. Direct has not
earned retiring the existing platform: multiple independent stop conditions
remain fired, its helper-heavy releases grow, TodoMVC's deferred condition still
fails, and the correctness campaigns are unfinished. The mechanisms are
different problems—visit/coalescing overhead, widened deep paths, persistent
model/list work, general filtered-list reconciliation, value fallbacks and
helper protocol bytes. A promise to finish in-place updates does not price or
solve all of them. Research 101's conditional redesign envelope also does not
demonstrate that Conduit's excess can be recovered.

The evidence against stopping is substantial: the empty mounted page is
smaller, holes stay constant outside HTML, direct avoids large unrelated-view
work, keyed edit meets its current bar, the table is 19.1% smaller than tea,
and Sternhalma selection has a lower direct median, with the unexplained
tea bimodality making it weaker evidence of a stable advantage. Research 102
also supplies concrete compiler byte opportunities on a newer baseline. Direct wins table update/swap/
remove relative to tea and Conduit editor input. Those results justify the
research and preserve useful compiler facts; they do not establish one
platform that wins across the measured applications.

Keeping both would retain that potential while funding two lowerings/runtimes,
the outstanding V3 work, byte redesign and the ownership usability costs.
Developers would still meet fresh-initialization requirements, retained-list
copies and approximate sharing errors around captures/commands. The measured
benefits do not yet justify imposing those costs on every tea application.
The owner decides whether that further investment is worthwhile. No platform,
application, threshold or golden is changed by this report.

## 9. Addendum, 2026-10-15: Bike Wars' release bytes

The frozen batch has no release bytes for Bike Wars (§3): its source called
`Debug.log`, and `--release` refuses a build that reaches `Debug`. Commit
`62b91b10a` (pull request #121) removed the call. This addendum measures the
two release builds with §3's method on master `f1ab9cc87` (issue #158).

| App / platform | App + startup B | Core B | Runtime B | Whole B | Raw B |
|---|--:|--:|--:|--:|--:|
| Bike Wars/tea | 5169 | 2045 | 1991 | 9205 | 28373 |
| Bike Wars/direct | 6025 | 2135 | 2930 | 11090 | 35421 |

Direct's whole bundle is **+1,885 B / 20.48%** against tea.

- The compiler is newer than the batch's `6c327a9f1`. Thus these rows are
  not part of §3's frozen comparison, and §0's answer does not use them.
- Both builds exit 0 with no `--allow-debug`. Each prints two
  `prepend_in_loop` warnings (`src/Helpers.beni:36` and `:51`).
- The compiler is a ReleaseSafe beni built from `f1ab9cc87`, SHA-256
  `2de3fb93b04400ce144a1cf345f7ac364350d55b0a0db7dcfaec87bcde48dc96`. Node
  is v24.19.0.
- [`bike-wars-2026-10-15/app-builds.json`](../../../bench/s8/results/bike-wars-2026-10-15/app-builds.json)
  records the commands, the statuses, the SHA-256 of each bundle and the
  binding provenance. The `.mjs.gz` and `.map.gz` files beside it keep the
  bundles and their maps.
- `bench/size.mjs` now builds every application under `examples/` as it
  ships, dev and `--release` with no `--allow-debug` (its `app` lines). Its
  `bike-wars` line has the same release bytes as the tea row: 28373 raw and
  9205 brotli.

To measure again, install the harness's parsers first
(`npm ci` in `bench/ui/apps/solid1`), then run:

```sh
S8_APPS=bike S8_RESULTS=bench/s8/results/bike-wars-2026-10-15 \
  BENI="$PWD/zig-out/safe/bin/beni" node bench/s8/build-apps.mjs
```
