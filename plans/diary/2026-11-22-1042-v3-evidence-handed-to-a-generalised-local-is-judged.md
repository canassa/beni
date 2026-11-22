## 2026-11-22 10:42 CET — v3: evidence handed to a generalised local is judged

**What I did**

- Lane fix178, #2601 (a soundness fault from blind round BL). A local function generalised over a
  `where` (a lambda, a local definition, a `_` placeholder) takes its evidence as hidden parameters;
  the call or the reference that hands it in carries the dispatch site. `Frame.call` read a site's
  evidence only where the callee was a declaration, and a `.local` reference never read it. So a
  method that writes its parameter, handed through such a local, was accepted and wrote the base in
  place: lists, records, dicts, a cell's contents; through `==`, `<`, `List.sort`, `List.member` over
  a user `eq`/`compare`, and through return-type dispatch.
- Present at cb0b57f8e1 (10 TRAP) and at the list phase's head e72a8bfd80 (7 TRAP; that head's
  oracle has only the sanitised leg, and the three cell programs were refused there because cells
  were not yet in place).
- Fix: every call, whatever its callee, and every `.local` reference judge their site's evidence. A
  safe-build check in `Check.checkCovered`: every site with evidence in a walked declaration was
  judged, whatever its instruction's form. The corpus and all sweeps ran through it with no panic.
  Kernel §6 rule 11 and §9 amended.
- `bench/ownership-sweeps/evidence.mjs` (256 programs: method writes or reads × list, record, dict,
  cell × 12 forms; 12 operator forms; return-type dispatch in 4 forms; live/dead). Base: 51 TRAP.
  Fix: 0 faults, every write refused, every read control accepted and SAME.
- Fixtures `run/EvidenceLocalGeneric` (read-only evidence, writes after the call accepted and run in
  place) and `run/EvidenceLocalGenericLive` (16 refusals). The live one fails on the base binary.
- One read-only Opus reviewer: no fault in about 40 writing shapes (pipes, aliases, folds,
  `sortBy`, mutual locals, spawned fibers, markup holes, cross-module and derived evidence,
  recursive groups). It found a type-checker panic on a `where`-generic function in a `schema via`,
  on the base too: #2602.
- Evidence: root dumps, 0 of 2 511 differ (the 2 new fixtures added); ledger 309 of 319 both;
  134 322 sweep programs dump-diffed: 99 changed (98 of `evidence`, the new live fixture), all now
  refused, 0 faults under the four legs; v3 on the real roots 3 750 to 3 766 ms (ReleaseFast LLVM,
  load near 40, +0.4 %); `zig build gates` exit 0 after a rebase onto fix176. Four runs before it failed on load alone: two `check_test` tests sit near their guards (about 5 s per `browser` program checked, the same on the base): #2603.

**What I learned**

- A rule that says "the caller was judged" needs a check that every caller is judged, or a new
  calling form opens a hole quietly. The safe-build check makes that a panic.
- Do not check out another commit in the worktree while a sweep reads it: the corpus sweep's
  programs are symlinks into the worktree, so its dumps saw the old sources. I dumped them again.
- Precision lost, by the rule: a writing method handed through a local is refused even where the
  base is dead after the call (as `addOnce Sink xs` is). Also a method declared as a constant
  (`pub eq = potEq`) reached through a local `==` is refused, while the direct `==` is accepted.
