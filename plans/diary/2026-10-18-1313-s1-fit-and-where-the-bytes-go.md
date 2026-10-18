## 2026-10-18 13:13 CEST — S1's fit, and where the bytes go

**What I did**

- **Merged #350 (S1 PR 1) and #351 (S1 PR 2).**
  - #351 lowers another module's arms and view as pieces.
  - Its read-only review found a silent miscompile: a `let` in another module's `view` was skipped. It also found a regression from master (a `_ →` arm refused). Both are fixed with fixtures, red first, and D-d is built.
  - An arm the tracking doesn't specialise is now the ordinary call with D-e's rebuilt message, as master did. That turns several wrong-cause refusals into programs that build. I accepted this departure from the brief's refusal list.
- **The owner's milestones 1–3 are reached.**
  - The generated `unique-components` app on `--lists none` passes `./rr check` at N = 1, 4, 16, 64 and 256, seeds 1–3, with 0 mismatches.
  - The research repo is untouched: everything runs in a `git clone --shared` with a load hook, and `./rr measure` writes into the clone's `results/`.
- **The fit (`./rr measure`, brotli):** beni-inline **3 375 + 335.2 B per widget** (R² 0.998), tea-inline **2 025 + 146.1**. The ratio is 1.79 at N = 1 and 2.25 at N = 256, against a frozen cap of 1.1.
- **Compile time is superlinear (#352).** `specialise` is over 90% of the build: 6.5 s at N = 256 and 12 s at N = 512, with 2.3 GB RSS. `browser-tea` grows too, less steeply.

**The per-widget bytes, seed 1, N = 16 → 64, deletion against the source map:**

| category | B/widget |
|---|---|
| validation of what the host pushes | 122.2 |
| binding pieces and their wrappers | 115.4 |
| html | 67.9 |
| handlers | 28.1 |
| wiring | 13.6 |
| arm pieces | 6.2 |
| other | 13.4 |

**Question 3 for the owner: validation against the cap.** The cap is 1.1 × 146.1 ≈ 161 B per widget. tea-inline validates nothing (`structuredClone`). Even if everything else matched tea-inline byte for byte, validation could cost about 15 B per widget at most. Today it is 122, because each widget's `replace` and its share of `Snapshot` are a specialised decoder with full error reporting, and `Result.withDefault` throws that reporting away.
- **Levers inside the current design:**
  - compile a reader whose error is discarded to bare failures;
  - call it directly instead of through `Schema$declared`;
  - share the object loop between readers.

  I expect these to halve the cost, not to bring it to 15.
- **What could reach 15 B:** validating through a compact description run by one shared validator, per widget only a description literal. That leans against `schema.md`'s fork, which compiles each schema to its own parse and print. So the question is the owner's.
- **My pick:** keep the bar, try the three levers first, one attempt each, and measure what is left. If it is still far over, the description-driven validator for readers whose error is discarded is the one to try, with the owner's agreement, since it touches `schema.md`.
- **The conservative path, taken meanwhile:** nothing changes in `schema.md`, and the levers go ahead.

**What I learned**

- **A read-only reviewer running repros found what both @claude reviews missed.** It found a silent miscompile and a regression, and its N = 257 repro showed that S1 had never lifted the caps the brief required. Static reads alone keep missing this class.
- **Deletion against the source map attributes brotli honestly enough to steer.** The categories sum within 5% of the measured slope.
