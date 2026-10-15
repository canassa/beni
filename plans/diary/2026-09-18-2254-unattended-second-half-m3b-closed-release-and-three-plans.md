## 2026-09-18 22:54 CEST — unattended, second half: M3b closed, `--release`, and three plans for the owner

**What I did** (same arrangement: Opus agents implement, I validate and commit)

- **M3b is closed** apart from `Int32`, which does not exist in the language
  (owner decision): `?` codegen (`b545b60` — a test and a `return` of the
  failing object itself; BIR has a dedicated `try` instruction, the audit and
  `language.md` were both wrong about that), record literals evaluate in written
  order (`2bf6f03`).
- **M3c slice 1, `--release`** (`e605066`..`822eab5`): dead bindings, narrow
  single-use inlining, two-namespace emission-order names, compact printing,
  `const` joining. `bench/corpus` 126 436 → 55 593 raw, 21 840 → 15 017 brotli;
  the whole `run/` corpus runs a second time under `--release`.
- **Three more exit-0 holes closed**: `let` forward value references
  (`3c8fbf8`), top-level value cycles (`a9b77c9`, a checker pass that walks
  dispatch-table edges because a method call leaves no `refs` row), and the
  exhaustiveness budget, whose flat and pair-keyed fast paths (`992ab59`,
  `0d2c1c5`) also make lookup tables linear to check.
- **The interface record is pure** (`792bf76`): it named types by a
  whole-program `TypeId`, so a type added to any earlier module renumbered
  untouched interfaces — and a RENAME of a mentioned type did not change the
  bytes at all. Found by the M4 audit, fixed the same hour.
- `sortBy` computes each key once (`128002b`); evaluation order is normative
  and guarded; `check`'s budget default is 5 M.
- **Three plans for the owner, no code behind any of them**:
  `plans/effects-plan.md` (8 decisions), `plans/m3d-plan.md` (6 — `lazy` is
  hard-blocked on effects), `plans/m4-plan.md` (9 — disk cache before daemon;
  slice zero does not exist). Plus `plans/state-of-the-compiler.md`: measured
  on a quiet machine, check 1.3 M LOC/s per core (5× budget), cold 100k build
  109 ms (7×), floor 2 147 bytes against C0's 65 214.

**Correction to an earlier statement**: commit `128002b` and my report at the
time said `sortBy`'s fix makes R3Sorting 18 % slower. That was measured beside
building agents. On a quiet machine the same C0 source through both compilers
costs +1.9 %, and R3's C1 side reads 808 ns/op, not 928. The mechanism is real
(GC 7.4 → 18.5 ms on R3's profile — a pair per element); the size of it was
noise. The ABBA-on-a-quiet-machine rule exists for this, and I broke it by
accepting an interleaved number taken on a busy one.

**What I learned**

- **The widened-inliner experiment is the pattern to repeat.** The release spec
  restricted inlining to atoms and member chains on a bytes argument; asking the
  implementer to widen it and sweep the corpus showed the restriction is a
  SAFETY rule (four programs reorder or duplicate evaluation). A spec rule
  justified by measurement alone should always get the "what breaks if we
  don't" run before it is written down as merely an optimisation choice.
- **Three more of my specs were corrected by their implementers** (DCE's edge
  set ×3, release's count array and substitution key, §7's default edge). Every
  one was found by a mechanism, not by reading: a compile-time self-check
  (`requireLive`, `Rename.verify`) or the corpus running under the new mode.
  Specs state intent; the self-check and the second corpus pass are what make
  an implementer's deviation visible the moment it matters.
- **A design audit is worth running BEFORE the milestone, by reading code.**
  The M4 audit found a leak that every existing instrument was structurally
  blind to (determinism tests vary `--jobs`, churn edits the module it diffs),
  and it cost one slice today against a re-bless per milestone later.
- **Owner-gated work piles up fast in unattended mode.** By the end, effects,
  M3d's `lazy`, M4's ordering and `Int32` all waited on decisions; what kept
  the queue moving was the audit-by-experiment slices (M3b audit, evaluation
  order, state of the compiler), each of which surfaced real defects. When the
  roadmap is blocked, measure and audit — it found nine miscompile-class bugs
  today that no gate had caught.
- `beni check` cannot check a program that imports its platform — found only
  because a measurement wanted a warning count. Tooling gaps hide where the
  test corpus has no reason to go.
