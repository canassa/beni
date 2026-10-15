## 2026-09-20 02:55 CEST — The browser design pass: reports 24–26 and the owner's sheet

**What I did**

The owner un-parked RESEARCH only ("Let's do 1"): what is a beni browser program, now that beni is
browser-first and an effectful call is just a call? No code changed; implementation stays parked.

- Vendored `references/elm-browser` and `references/elm-virtual-dom` (shallow, `657aa7b`), then ran
  three docs-only Opus researchers in parallel, one new file each, none committing:
  **24** Elm's browser runtime as built (`0ebdce5`), **25** the UI architecture design space
  (`d5c04c0`), **26** the browser as a host, measured in headless Chrome 153 with Firefox 156 as a
  second engine (`3302367`).
- Validated each before committing. 25: spot-checked five citations against the clones (TCA's
  prefix-path cancellation, Solid's promise-identity discard, Leptos's `ScopedFuture`, `elm/http`'s
  `cancel`, effect-atom's `interruptUnsafe`) — all hold. 24: `VirtualDom.js:674`, the line counts,
  the absence of `try`/`catch` in `Scheduler.js`, and the size figures re-measured from the built
  artifacts (109 530 raw / 22 722 brotli). 26: re-ran `e3b` (microtask-64 p50 358 / max 638 ms, never
  64 / 346, `MessageChannel` 0 / 1 at every budget) and `e8` (4G 1 056 / 357 / 703 ms, fast 3G
  3 437 / 1 156 / 2 281) on a quiet machine (load 0.08): both reproduce.
- A fourth agent wrote the synthesis: `plans/browser-decisions.md` (W1–W24, nine in tier 1, each
  answerable without reading the reports) and `plans/browser-platform.md` (worked program + test,
  kernel, slices B0–B9, output track O1–O3, edits owed to normative documents, whole-project
  sequence). I parse-checked its two beni examples with the compiler: clean once the proposed `sync`
  keyword is stripped and one `[ ... ]` elision is filled.
- `plans/queue.md` rows B-R1..B-P marked done; `plans/resume.md` §0 rewritten as the resume point.

**What I learned**

- **`sync` on `update` is a concurrency proof, not a boundary check.** A suspension point is the only
  place another fiber can interleave, so a `sync` `update` applies every message atomically. Elm has
  that for free because JavaScript cannot suspend a stack; beni will be able to, so it must be bought,
  and A6 already bought it. This is the argument for TEA-with-fibers and against an effectful
  `update`, and no document stated it before report 25.
- **A microtask yield is worse than no yield** for input latency (p50 371 vs 84 ms), and a macrotask
  hop costs only 2–4 µs. P2 §7.5's microtask tier should be withdrawn, not tuned; report 21's Node op
  budget of 512 does not transfer; the browser default is `MessageChannel` on a ~1 ms TIME slice.
- **A measurement overturned a document**: Elm's docs (and report 24, quoting them) say user-gesture
  capabilities die when work leaves the handler's tick; report 26 measured `window.open` surviving a
  4.9 s macrotask hop. Running the three reports in parallel and then cross-reading them in a
  synthesis is what caught it — the synthesis found six joins/disagreements no single report saw,
  including a re-entrancy hazard (a `sync` `send` re-entering the dispatcher) that Elm guards with a
  nineteen-line comment.
- "Fatal" has no browser mechanism: an uncaught throw kills nothing in either engine, so A1 needs a
  page meaning the platform implements (W2), and A8 has only a Node half (W9).
- One bundle reaches `main` 3.0× faster than 13 modules on 4G and fast 3G (round-trip depth, not
  bytes; HTTP/1.1 caveat), and 71.6 % of shipped bytes are unminified sibling `.js`. The single-file
  `--release` bundle is the recommended first slice when the owner un-parks: it needs no decision.
- Process: two researchers ran 25–60 % over their line budgets and said so; the content justified it.
  An early, flawed version of an experiment script (`e3`) was left beside the corrected one (`e3b`) —
  my first re-run hit the wrong one and "contradicted" the report. Re-run the script the report names.
