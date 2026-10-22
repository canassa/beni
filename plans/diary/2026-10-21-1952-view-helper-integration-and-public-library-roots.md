## 2026-10-21 — view-helper integration and public library roots

**What I did.** Resumed the browser-inline helper work for #295 on master
`f4cee4260`, without changing the published #436 branch or worktree. #610
integrates its final helper head `025037596` by an ordinary merge. The approved
#459 selected-arm semantics and #466 event-binding lifetimes are preserved;
master's normative solver is unchanged. Fourteen run-hash records changed with
the current compiler. Full reference hash recording, gates and pending checks
passed on tree `b9f2bddeaccc3f2b573479766391b582678bbd71` before publication.
The PR requires a squash merge because of the original branch history.

**Review follow-up.** The GitHub review asked whether a captured helper argument
refreshes inside an already-selected inner arm. The permanent HelperEventInner
transcript now bumps only the argument's input while both selectors stay true:
binding logs advance to 6/106, then dispatch sends 6/106 without evaluating the
arguments again. Both development and release runs pass. No read-group code
change was needed.

The review also exposed #613: a public markup helper built with `--library`
was consumed without an internal reference to request its declaration, so a
successful build silently omitted the export. Exact pre-helper master refuses
that value with the existing class-1 markup-value diagnostic. A black-box
regression first failed with expected exit 1, actual 0. The correction keeps
public root-package library values unconsumed, including pieces, so the
existing lowering reports the complete diagnostic and writes no output. This
preserves the current supported program set; it adds no language restriction.
The platform skill now describes helper eligibility and binding lifetimes.

**Validation and remaining work.** Evidence is retained on dagon under
`/home/canassa/.cache/beni-codex-view-current/`. Final reference checks and LLVM
qualification follow this review batch. The measurement agent owns matched
before/after unique-components and big-component grids, lists none, sizes
1,4,16,64,256, seeds 1–3, with compiler-constant validator-stub lines. Those
measurements and byte identity remain required before merge. The S1 bars have
not changed; no current fit success is claimed. #476's static-Bool helper-hole
refusal is separate work in its own worktree. Lean remains paused.
