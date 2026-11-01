# Selected-entry emitter state

Specified 2026-10-31 under workers-emission.md's build-wide/entry-local boundary.
This slice emits exactly the existing selected top entry, or the existing library
root set. It changes no language, runtime, ownership, entry-discovery acceptance,
output layout, root policy or byte budget. Multiple executable entries and public
worker launch remain blocked on their separately decided proofs.

## Input, validation and freeze

Emit.run first validates the existing platform contract and finds the selected
ordinary entry in the existing order. Validation uses fresh contract scratch:
legacy markup runtime module and rejected-contract diagnostic Program identity.
An invalid contract publishes no selected emission input or pending output.

BuildInput is an immutable value borrowed through a const pointer by the emitter.
It contains the existing Options and, after successful validation/findEntry, a
Selected value: selected module/declaration (or library null), const current
Session.entry_plan, resolved legacy runtime module and top Program identity.
The pre-validation input has no Selected value. The transition replaces the
input pointer with a stack-owned frozen value; no emission worker starts before
this transition. The selected plan is not copied, inferred or reconstructed by
name. Its rows belong to the current checked Session; no reset or revalidation
occurs while this emission borrows them. Runtime lookup after selection consumes
that frozen plan. Before selection, validation may inspect the mutable Session
plan and the raw manifest only for its already-decided validation duties.

The emitter retains an explicit mutable Session service reference. Profiling,
interner insertion for compiler-generated names, artifact pack/cache access and
existing module worker behavior are not made immutable by a cast or a cloned
Session. Checked source artifacts and the selected plan remain read-only after
freeze. This boundary is not permission for concurrent projection use of mutable
Session services; future parallel entries need their own service protocol.

## Entry-owned mutable projection

The nested Projection owns the state currently derived for one emission:

- Reach.Input, module edges/cache-read columns/forwarding facts and Reach.Result;
  extra runtime roots, lifted roots/cuts, schema-share roots and schema graph;
- lowering/write-set/markup data, lifted piece arenas, per-module ownership-clean
  inputs, debug context, specialization roots and representation keys;
- short global/imported/hand-written namespaces, field/boundary tables, hoist and
  bare-global state, source-map root, markup exports and starts;
- pending outputs, owned printed byte buffers, result counters and owned result
  text. Pending output is not Session or BuildInput storage.

The worker pool and every mutable projection field belong to this one entry.
BuildInput has none of live, pending, renaming, lowering or reachability state.
Existing worker structs still point at their one emitter; they cannot borrow a
second entry's live/naming/pending result. This is control state, not a persisted
IR: no new cache schema or pointer-bearing serialized representation is added.
Keep nested helper types bounded; no new check helper or registry exemption.

Contract scratch remains separate from Projection and immutable Selected. The
contract's runtime module and diagnostic identity are copied into Selected only
when usable; no fresh plan or runtime authority is supplied by an old projection.

## Root and output invariants

All original pass calls and root constructors retain their order and arguments.
Coarse runtime roots, fuzz roots, lifted/deferred roots and schema-share roots
remain distinct fields or inputs; no union is silently substituted for another.
Reach.collectRoots retains all evaluated initializer dependencies and ordinary
source effects. This slice does not treat a deferred body as an evaluated
initializer, remove initializer effects, use partial compact discovery as
executable authority or invent an EntryHost proof.

The frozen selected entry feeds elimination, module emission, entry and page
shell generation. Legacy runtime import/specialization selection and checked
Plan.runtime are unchanged. Library has a frozen selection with no ordinary
entry and retains the existing library export-root behavior. Runtime refinement,
field naming, source maps, lowering reuse and hoisting retain their algorithms.

All pending outputs still pass existing output collision, symbolic-link and
record preflight before flush. Failed preparation leaves prior output untouched;
no output or projection state survives to the next Emit.run. This does not claim
filesystem transactionality after a failing flush or a functioning broken writer.
Existing error codes, diagnostics and resource/I/O conventions are unchanged.

## Lifetime and cleanup

One Projection is fresh for every run/check/inspection attempt. Its release
routine is called on success, semantic refusal and resource error. It releases
any remaining write-set pass, every owned printed buffer and every piece arena,
and deinitializes owned result-text buffers that were not moved to Result.
It then resets its fields to empty/defaults, not dangling pointers into freed
scratch or workers. Scratch-owned tables are discarded by the caller's existing
arena reset; do not individually free them. Pool teardown still follows the
existing run scope and waits for all jobs before scratch is reset.

Result.diagnostics/messages and result text remain gpa-owned and transferred to
the caller. Stage transfers transactionally: if a later toOwnedSlice allocation
fails, release earlier transferred buffers/messages and leave remaining lists
with their original cleanup owner. Diagnostic list backing storage is freed on failure; transferred
messages are never freed by projection cleanup. Cleanup must not require a
selected input, because validation and preparation can fail before publication.
BuildInput and Selected contain no individually allocated new tables.

## Validation required for acceptance

No output golden may be blessed for this refactor. Compare baseline and candidate
full output trees, paths and bytes, in both development and release, including
maps, shared validators, generic runtime, legacy runtime, library, markup/direct
lowering and hoisted output. Use source-selected fixtures and actual runtime
execution, not hand-written JavaScript. Verify jobs 1 and 8 twice with identical
outputs. Keep baseline compiler, commands, hashes and comparison receipts.

Register a resident --watch scenario that exercises a successful selected build,
post-selection emitter preparation refusal, then successful changed source in
the same Session. The refusal must leave the exact previous output tree intact;
the repaired output must equal a fresh one-shot build and execute the repaired
program. Exercise development and release separately to cover hoisted state.
Use an existing ordinary emitter error such as output-path preflight, not a new
mutation flag or a checker failure that never enters the emitter. Include a
successful initializer plus deferred callback path in these source programs.
Bound all live-process waits through existing Live and stop on every exit path.

Supplement with hermetic projection-release/reset tests through observable state
where practical, including no selected input and repeated empty release. Existing
platform/runtime, build, devloop, source-map, release/emit golden, cache and
entry-root suites remain required. Actual counts and failures go in the diary.
The manager reviews the source freeze then runs full unfiltered gates and any
necessary cost checks; Debug development builds only in the author lane unless
separately authorized. No budget increase or output-byte regression is accepted.
