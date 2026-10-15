## 2026-10-15 01:50 CEST — Ownership differential bridge in progress

**What I did**

Started the Lean-to-beni bridge in the isolated `ownership-differential-bridge`
worktree: specified the translation, exported existing streams with observational
checker breadcrumbs, translated the common subset, compared ownership dump and
browser-direct enforcement, added real runtime observations and reduction, and
prepared three opt-in compiler source mutations. An initial fixture experiment
translated 244 of 490 programs and found ten program-level Zig-accepts/Lean-rejects
leads; all ten agreed under real runtimes on their final values. These preliminary
counts predate added read observations and translation refinements. Started the
long bound-2/three-seed run on an isolated Linux snapshot pinned to CPUs 0–7.
The user requested a restart prompt while that run was processing enumeration.
Detailed handoff is in this worktree's ignored `zig-out/ownership-bridge-handoff.md`.
No PR or task commit yet; final CI, audit, gates and source-mutation runs remain.

**What I learned**

The real checker reports multiple obligations at one source span and deduplicates
its enforcement diagnostics there; comparison must group source sites. Lean
aborts on its first failure, and canonical summary failures cannot be imputed
to unrelated concrete demands. Private builders, identity-preserving close and
abstract event/model protocols require explicit skips. Runtime confirmation
needs read snapshots as well as final values. Do not rebuild the oracle binary
while a campaign is spawning its reducer. macOS archive resource forks must be
excluded from a Linux source snapshot: the Lean audit correctly rejects them.

### Ownership differential bridge — completed evidence

**What I did**

Finished the Lean-to-beni bridge in its isolated worktree and opened PR #115.
The corrected campaign covers 116,456 inputs: 43,066 translations checked
against real browser-tea values and 73,390 counted skips. It retains all 2,358
program verdict leads with typed minima and paired real runtime observations,
plus 1,167 site-only leads blocked by other refusals. None is a confirmed
shipping runtime defect. Compressed evidence preserves every source and minimum.
The three isolated Zig holes add 95, 12 and 9 program verdict leads on the bounded
CI stream. Neither ownership checker was weakened or otherwise changed in policy.

Added capture and asynchronous-failure regressions. Captured atoms are evaluated
once into separate bindings, and an unused explicit capture slot is a skip.
CI checks every translated value and rejects missing batch accounting; pinned
coverage floors prevent a translator from silently degrading into skips.
Minima preserve the rejection class, flag full-message changes and model limits,
and count their final-frontier skips. Repeated emitted declaration keys are
unknown rather than borrowing another instance's successful checker visit.

**What I learned**

Final-value agreement does not establish capture or alias fidelity. The first
Disjoint minimum erased an unused capture, which exposed a translator defect;
that preliminary evidence is superseded. A failed asynchronous batch could also
leave the work queue before its error was observed; the old runner falsely
returned success for 32 translations with zero value checks. Both now have
regressions that establish the prior failure and the corrected behavior.

The shipping browser-direct library still calls persistent list operations, so
real runtime agreement cannot confirm its future in-place guarantee. Report
verdict catches separately from runtime catches. The handoff's remote `zorg`
was a Zig symlink; the final experiments use the checksum-pinned real Zorg.
Linux gates pass. macOS's serial full gate has the two known case-folding
failures; parallel runs also exposed CPU-time fallback variability, with no
budget change or exemption. The original checkout's unrelated work is untouched.
