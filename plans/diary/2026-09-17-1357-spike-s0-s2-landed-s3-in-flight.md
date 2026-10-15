## 2026-09-17 13:57 CEST — spike S0–S2 landed, S3 in flight

**What I did**

- **Roc research, before the spike.** Confirmed via Zulip that Roc deleted abilities
  (type classes) for static dispatch in early 2025, and characterised what the trade
  actually is: constrained parametric polymorphism kept, the *declaration layer* dropped —
  no nameable class, no grouped members, no conformance declaration, no orphans (which
  abilities never had either). Return-position dispatch reached parity via `module(a)`.
  Sources in the conversation; the durable half went into report 20.
- **S0** (`9f47e9d`, `d0226bc`): the normative spec `docs/design/static-dispatch-spike.md`
  and `plans/static-dispatch-c1-rewrite.md`, written by one agent from the plan, reviewed
  read-only (5 blocking / 15 must-fix / 15 minor — the dispatch table's own worked example
  miscompiled, caller/callee evidence order could silently disagree, no way to request a
  derived function from a using module), fixed, then amended again from report 20. Nine
  manager decisions recorded in Appendix A: eager nominal derivation, eta-expanded evidence
  in value position, code-point order for `String`/`Char` `<`, no `let` generalisation over
  a constrained variable (evidence stays one level, captured lexically), `==` pins both
  operands, `well_known` as an operator enum, discharge tables journaled with the store,
  obligations printing both the call and the constraint's origin, `where`-only type
  variables forbidden. 44 rows in Appendix A by the end.
- **Research 20** (`97018d3`): a code-level walk of Roc's implementation for S3–S6, verified
  citation-by-citation (~200 checked, ~20 line drifts corrected, all three headline findings
  held). Every citation now prefixed `roc:`/`beni:`.
- **S1** (`c870e9a`, `5833928`): the harness and its baselines. The harness review found the
  churn instrument scoring 130 of 258 non-compiling edits, size totals that were 34 copies of
  core, R5/R6 encodings that compiled identically, and a `--dispatch` corpus with +14 % `pub`
  values — all fixed before a single baseline was taken. Baselines captured on an idle
  machine from a ReleaseFast build in a `beni-s1` worktree (kept for S8's interleaving).
- **S2** (`19ddd37`): the front end. Review found no panics in 800 fuzz cases, but
  `type_dispatch` compiled to `undefined` with rc 0, `basicsValue` emitted `undefined` when
  core lacked a value, and operator sections lost their name and pre-solve type in
  diagnostics. Thirteen fixes, each with a fail-first fixture; two fixtures could not be made
  to fail before and are recorded as such rather than dressed up.
- **S3 launched** as two agents: the checker (§6, §7, §10) and §6.8's implicit graph edges.

**What I learned**

- **The headline finding is already in the baseline.** On today's compiler, adding an
  operation to a parameter typed `a` is rejected on every annotated declaration (16/16 in
  core) and changes the interface on every unannotated one (14/14). That is report 18 §2.3
  measured before dispatch exists; S8's job is the C1 column, not the C0 one.
- **The plan's `Descriptor` claim was wrong in a way that helps.** `Flags` 8→12 bytes fits
  the existing 16-byte `Content` payload; `Descriptor` stays 40 bytes, so M1a measures time
  only.
- **A green suite coexisted with rc-0 `undefined` twice in one slice** (rule 3 in
  CLAUDE.md, again). Both were caught only by a reviewer building programs outside the
  corpus. `bir/` and `parse/` goldens prove shape, never behaviour; every new syntax needs a
  `check/` or `run/` fixture even when the checker cannot yet do anything but refuse it.
- **Two pre-existing `master` defects** found while measuring M2: `Render.writeRecord`
  flattens under a 64-field guard and silently drops the `| r` tail, and `Schemes.Writer.
  max_depth` writes `<error>` into an interface that `beni check` exits 0 on. Both need
  fixtures on `master`; neither is the spike's.
- **Spec line numbers drift under concurrent editing.** Every reviewer's `:N` was off by
  the amount the file had grown since they opened it; matching by content, not line, is the
  only thing that worked.
- **`git worktree` is the right tool for fail-first proofs and baselines** when agents share
  a tree: no stashing, and a ReleaseFast binary of a known commit that survives later work.
