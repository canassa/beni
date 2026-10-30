# Browser worker implementation on PR #1304

The owner authorized implementation on the existing PR. Large restructures
required by the decided design are specified first, then implemented. Stop and
notify the owner only for an undecided decision, a change to a decided design,
a rule exception, or an approach that sacrifices a guarantee or budget.

All development runs on Dagon. New code is beni or Zig. Use Zig's development
compiler and independent worktree caches. Scratch and TMPDIR stay under the
agent's owned ~/.cache/beni-agents directory. Agents do focused validation;
the manager reviews source, integrates changes and runs full gates serially.
Every agent cleans its owned worktree, local branch and scratch after its
commits have been retrieved. All accepted code goes to the same PR.

## Work and dependencies

| Work | Tracking | Validation and integration boundary |
|---|---|---|
| Generic runtime metadata independent of markup | #1293 | entryKinds symbol, Program, result and effect checks through check and build; legacy runtime compatibility; no unchecked public launch |
| Typed runtime storage migration | #1295 | Producer and storage census; typed renderer dispatch ABI and behavioral fixtures; specify Task continuations and scheduler before code; retain suspension protocol and exact native failures |
| Native binding generation | #1295 | Pinned WebIDL parser and merged index; deterministic generated nominal types and upcasts; reject malformed input and missing required adapter metadata; integrate through an actual build command |
| Build-wide planning and per-entry projection | #1294 | workers-emission.md; finite static entry discovery, isolated initializers, stable IDs, atomic output and jobs 1/8 fixtures |
| Shared-name wire plans and native backing moves | #1296 | Build-wide field and tag constraints; selective normalization; fingerprints, negative ownership tests and byte goldens |
| Managed runtime and complete APIs | #1297–#1300 | Callback protocol checks in v2; scoped cancellation, cleanup, defect domains, ports, transfer inventory, bounded pools and stream credits; real browser fixtures |

Compiler foundations may be integrated independently when complete and tested.
A public worker launch cannot land until the realm, Wire and ownership proofs
are present. Service Workers have a separate design. Proposal-only transfers
remain explicitly gated. The same PR stays open throughout implementation.

## Session status

The independently landable foundation checkpoint implements generic runtime
metadata with strict six-key tables, the Session-owned validated entry plan,
the pinned native binding catalogue, and the typed Buffer primitive with its
generated sibling, core-override checks and ordinary type/effect tests. The
prerender export-root correction remains paired with its regression and keeps
the call-graph guard enabled. Manager source review, full run-hash recording and full unfiltered gates passed
on Dagon for foundation code commit d61f2d338. CI validates the pushed head next.

The typed Inline queue and its coordinated callback ABI are deliberately held
out of this checkpoint. The candidate has passed source review, focused corpus
and real Chromium behavior validation, but remains under performance validation.
The existing Inline implementation and inline run hashes stay unchanged here;
the candidate mixed-type fixture will accompany the eventual accepted queue
migration. No budget is waived.

Task continuation storage, remaining callback consumers, per-entry realm and Wire
proofs, and public worker launching remain pending. This checkpoint does not
complete C or enable worker launch. All further accepted work stays on PR #1304.
