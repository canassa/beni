## 2026-09-20 12:25 CEST — JSX and Solid's speed: reports 27–29, and the decision sheet revised

**What I did**

The owner read the browser design pass and changed the requirement: **"I want built in JSX in the
language. Also, clone and research SolidJS 2. I want a Beni UI to be fast, as fast as solid, the
runtime cannot be a limitation."** Still research only; implementation stays parked; no code changed.

- Recorded the direction in `plans/queue.md` (it withdrew W1, W4, W5, W6, W10 as written) and in
  memory; vendored `references/solid` (`next`, 2.0.0-rc.9, signals core in-tree) and
  `references/dom-expressions` (`4b29ac9`).
- Three parallel Opus researchers, one file each: **27** Solid 2 as built (`62c7108`), **28** JSX in
  beni (`2271159`), **29** rendering strategies measured (`740dd40`).
- Validation. 28: ran the binary — `<` at operand start is a syntax error today, `f a <b` parses as a
  comparison, `...` is two INVALID CHARACTERs; Mint and ReScript citations hold. 27: the uibench
  96/96 quote and the module-level tracking variables check out; `split2.mjs` and `refeq.mjs` re-run
  (3.2 ms of 21–23 ms for 1 000 rows; 9.8 µs to walk 10 000 rows) — reproduce. 29: read the P2/P3
  prototypes (mechanical, compiler-plausible), re-ran the seven-subject core for ten minutes on a
  quiet machine: **the ranking and per-op script medians reproduce; the headline "P3 equals vanilla's
  script cost (0.989)" does not (1.260)**. I put a validation note at the top of the report rather
  than let the claim travel.
- A fourth agent revised the synthesis: `plans/browser-decisions.md` rev 2 (W1–W45, withdrawn ids
  kept in place, seventeen tier-1 questions, a direct answer to the owner's three sentences) and
  `plans/browser-platform.md` rev 2 (JSX worked program, template renderer, language / rendering /
  core tracks, experiment X1). Queue, resume point and memory updated.
- The synthesis agent found a **compiler defect** while parse-checking its example; I reproduced it:
  `Ok ()` / `Just ()` patterns are reported as missing and a valid program is rejected. Queue row 56.
  Not fixed — parked — but it blocks `Result e ()`, so it is first when implementation resumes.

**What I learned**

- **The first synthesis recommended the right programming model on an unexamined assumption.** Report
  25 assumed a virtual DOM while listing "whether beni has one" as undetermined; the owner's one
  sentence exposed it. Measured, a vdom is the slowest sensible design (146× a template per message on
  a static-heavy page), and TEA survives *because* it was re-tested, not because it was assumed.
- **Solid's speed is mostly its compiler, not its signals** — templates, compile-time hole paths,
  delegation — and all of that is available to TEA. beni's immutability is what makes it cheap:
  a record update is a spread, so an unchanged row is the same object and `===` means deeply
  unchanged. That makes field identity LOAD-BEARING: it must become a written promise in
  `language.md` that constrains the optimiser forever (W27).
- **A geometric mean of ratios over sub-millisecond operations is not a reproducible number.** One
  op (vanilla's `swap`, 0.10 vs 0.57 ms) moved the headline by 20 %. Orderings and per-op medians
  reproduce; parity claims built on geo-means of tiny numbers do not. Re-running is what caught it.
- Report 25's "signals need a fourth fiber slot" was wrong: Solid's observer is a module variable
  restored synchronously, correct whenever tracked code is `sync`. So signals are possible as a
  library, buy no speed (P4 = Solid 2 at 12× the bytes), and rule 7 says: unshipped, never forbidden.
- JSX is cheap in beni for reasons beni already has: `<` is never prefix, shadowing is an error,
  strings already interpolate. Quoted text children remove the lexer mode AND make the formatter
  meaning-preserving by construction. The one real conflict is `f a <b`.
- The open technical question is W29: reports 28 ("`Html msg` is an ordinary value; recognise
  templates structurally") and 29 (prototypes that never build a tree) only meet if the recogniser
  sees the whole path to every hole — and an idiomatic view breaks that at every helper call. Two
  researchers working in parallel each assumed the other's half; only the cross-read found it.
- `dump --stage=ast` only parses. Two reports claimed their examples were "checked" with it and one
  shadowed `Basics.e`. Examples in a spec should go through `beni check`.
- beni's `List` has no indexed read: a capability gap (rule 7), not a speed problem.
