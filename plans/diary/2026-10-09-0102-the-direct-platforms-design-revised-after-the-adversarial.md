## 2026-10-09 01:02 CEST — The direct platform's design, revised after the adversarial review

**What I did**
- Revised `docs/design/browser-direct.md` for PR #24's adversarial review, section numbers kept.
  The five wrong-page/runtime-error findings each got a rule and a fixture: an arm's slots are
  reset to `undefined` at teardown so `A → B → A` writes (`BranchReturn`); every group, script,
  selector visit and derived value runs under its branch arm's liveness test (`LateResponse`);
  the selector visit runs after the scripts and skips a probe no row has (`SelectAndRemove`);
  non-bubbling events get direct listeners on row nodes and a row's `stopPropagation` calls the
  native one (`RowBlur`, `StopInRow`); `send` takes one function and one argument — a listener
  body, `dispatch`, the mount — so payload reads, `end()`, `run` and the mount are all inside the
  guard and any arity passes (`DefectInListener`, `DefectInMount`, `DefectInAfterRender`).
- Settled the rest: read-at-event stated against Elm's capture and made owner question Q1;
  detached-row events delivered; `const old = model` only where a script needs it; tags compose
  by `write-sets.md` §2.4 and a composition is `replaced`; every script guarded by its tag's
  condition from the instance array, never by list identity, so S7 re-pins nothing; indexed
  scripts read by `get`; a program mounted twice is refused (build and start); the controlled
  promise names exactly the `stateful` properties. Value roots, (key, group) pairs, reconciler
  and `patchAll` keys are dumped from S0 as a stats gate; inlining and specialisation have a
  size gate (shared sites); expandos are measured against a lookup in S2. The program-shape
  refusal is withdrawn: an opaque `update` is the single `*` key; only an unreachable `view` is
  refused, with the reason no fallback exists. §13: bursts at the K = 1 ratio, the long-list S7
  target conditioned on a container-owned plain list, every figure marked a hypothesis, TodoMVC's
  row names Q5, the routing build and the list sizes, and a "beat P3 or stop" criterion at S3.
  Differential fuzzing and a development verify mode from S1; a TodoMVC-shaped fixture in S3;
  owner questions gated in §14. `plans/compile-away.md` §6–§7 follow.

**What I learned**
- Module-level slots that outlive their nodes are a trap a per-instance design never had: the
  reset on teardown is the price of having no instance object, and it is one line per arm.
- "Guard a script by whether the list changed" was identity in disguise; the tag's own condition,
  read from the instance array, is what the handler actually knows, and it survives in-place
  update unchanged.
- A refusal that "costs nothing" still fails rule 7 when a cheaper fallback exists; the single
  `*` key was already in the design, so the refusal bought nothing.
