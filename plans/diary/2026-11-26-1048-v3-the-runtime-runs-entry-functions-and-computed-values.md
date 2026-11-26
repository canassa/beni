## 2026-11-26 10:48 CET — v3: the runtime runs the entry's functions, and computed function values

**What I did**

- Fix lane fix215 on `ownership-v2-design-review` (base 2e4ddf9559), for #2695 (code reader CR9)
  and #2696 (blind round CN), both holes in kernel §13 item 12 (d).
- #2695: `send` runs `update`, and the render after it `view`, on the fiber that called `send`,
  which the program can mask or lend. `entryCall` gave the entry record's functions only their
  captures and parameters, so no rule read their `hosts`. Each function of the record now goes to
  `flowCode` at the default use; a new `Use.entry` skips only the refusal of writes of its own
  parameters, which the entry's rows judge. The adversarial reviewer found a neighbour in the same
  shortcut: an `update` that writes a list in a cell `main` made while a command holds it (`capw`,
  TRAP). Moving to `flowCode` closes both. The kernel gets *The ways in, from the code*, item 12:
  the runtime sites that run program code on the caller's fiber, and item 9's wrong sentence
  ("`update` is `sync`") is corrected.
- #2696: a call of a top-level value whose body computes a function (`if`, `case`, a call's
  answer, another module's value) read the value's contract, of arity 0, as the run's, so no
  `runs_on` was noted. A callee whose `own_params` is not the argument count is now a call of its
  value: code the walk does not know.
- Fixtures: `browser/inline/CellEntryHosts` and its live twin, `browser/inline/CellEntryCaptures`,
  `run/CellTopValueCall` and its live twin (12 shapes), `CellSendTypedLive` +1 refusal;
  `cells.mjs` `runon.frame` gains 15 entry shapes. Base: 6 live TRAP; fix: all live refused, dead
  twins SAME.
- Evidence: root dumps 2 573 roots, 0 verdict changes on real roots (summary bits only; core's
  `List.plainOf` gets `runs-on` from `isPlain = Js.to …`); sweep dump-diff of 2 183 programs (entry
  pages and top-level function values): 20 differ, 10 accepted → refused, all live `runon` pages,
  0 dead twins; the 20 under the four legs: 0 faults. Browser-inline pages: 308 checked, 228
  accepted before and after, 0 differ. Ledger 309 of 319 before and after. v3 on the real roots
  2 017.9 → 2 007.6 ms (ReleaseFast). Reviewer: one fault in pass 1 (fixed), none in pass 2.

**What I learned**

- A shortcut that calls two of `flowCode`'s helpers is a second copy of the rule, and it misses
  what the rule gains later. Route every function value through the one judgment.
- A contract describes a declaration, and a declaration with no parameters is a value, not a
  function. Comparing the argument count with `own_params` is the general test.
- A browser-inline page cannot be a live twin of an in-place cell write: the platform's own checker
  refuses the write in the plain build. The live twin lives in `cells.mjs` instead.
