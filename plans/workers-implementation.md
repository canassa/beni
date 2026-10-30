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

Implementation resumed after clarifying the stop condition. Three agents own
runtime metadata, typed runtime storage and native binding foundations. Their
concrete design documents precede their code. The manager owns the emission
restructuring specification and final integration. No completed implementation
or performance result is claimed by this plan; later entries record validated
commits and remaining work.
