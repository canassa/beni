# Demand-only canonical solved-type diagnostic index

Specified 2026-11-01, Part of #1296; implementation issue #1580 and PR #1304.
This is a diagnostic construction milestone. It publishes no HostFree, Wire,
realm or ownership certificate. `workers.md` remains authoritative: HostFree
memoizes solved SCCs in O(T+F), with F field edges. Positional tuple components
are fields under section 5; the inventory's F_record counts only record fields.
Representation-needed nominal argument gates still require their own field-work
accounting proof. No gate/classifier/enforcement is implemented here.

## Input, demand and lifetime

Existing `solved_required` enables this optional TypeStore index BEFORE its first
variable. No new CLI flag, request-bit cache key or serialized field is added.
An unrequested store retains no index allocation and performs no index scan;
its mutation paths pay the explicit optional-index branch. An index cannot be
enabled after variables exist. A fresh store/reset starts without authority.
The index belongs to the store's arena and dies with it; retained stores retain
both, and error/dependency-tainted modules publish no index proof.

Actual descriptor content, ordinary union root choice/rank/weight, original Var
IDs and declaring scheme/formal/nominal scopes remain unchanged. No substituted
payload or cursor environment is materialized. Alias actual AND diagnostic
arguments remain distinct indexed structural edges; this does not classify
both as representation fields.

## Construction and invariants

`CanonicalIndex` owns flat SoA class and edge tables and a dense live-class list.
Class IDs correspond to the actual source Var allocated by ordinary `fresh`.
Only live actual UF roots have class authority. Each live class has indexed
incoming/outgoing lists; each active edge carries its canonical target, kind,
selector and doubly linked list positions. Retired edge slots use a free list.
No per-node allocation, dense-ID hash map, per-owner transitive bitset or
owner/environment product is introduced.

All ordinary semantic mutations synchronize the index: fresh inserts a class;
setContent replaces that class's outgoing incidences; merge removes the two
old outgoing sets, redirects incoming incidences from the actual dropped root
to the actual kept root, removes the dropped live class and installs survivor
content; equal-root merge is a content replacement; expandAlias removes the
alias's outgoing set, redirects its incoming incidences to actual, removes its
class and preserves actual's outgoing set. Rank/mark/copy changes and ordinary
find path compression do not alter class authority. Registering content uses
Walk's structural child decoder and original metadata. Construction resolves
raw child Vars against actual parents and charges every traversed parent edge;
those resolutions do not mutate or change ordinary root choices.

The implementation deliberately follows ordinary root choice, not a separate
small-to-large reverse-incidence heuristic. Redirect count may be superlinear
in final graph size across mutation history. All registration, removal,
redirection, raw-parent traversal and live-list work is explicit; NO immutable
union amortization or HostFree O(T+F) construction claim follows. Space includes
historical class slots, live-list capacity and peak reusable edge slots. No
late scan of allocated D is disguised as canonical classifier input.

## Failure and output boundaries

Existing merge/content/alias mutators cannot return allocation errors. Any index
allocation failure immediately sets sticky failure and invalidates ALL index
authority. Ordinary mutation still completes with its existing semantics. Every
requested index validation/export/statistics operation checks failure first and
returns OutOfMemory; no stale index, empty proof or partial index output is
accepted. The failed index does not resume; only destroying/recreating its
store may regain authority. Default/unrequested mutations allocate no index.

Cursor construction and EVERY next operation first refuse sticky OOM. Each
mutation advances a generation; nodes and child cursors borrow that generation.
Every subsequent operation rejects an invalidated borrow, including a stale node
whose old live position has been reused. Mutation cannot let a previously
created cursor yield stale or partial authority. The borrow protocol is checked
at runtime, not an unchecked caller assumption.

The final index visitor walks the live-class list and active outgoing edges.
Its targets are already canonical class IDs, so compact target positions come
from class slots in O(1). It performs no scan of dead descriptors/retired edge
slots and no raw-Var find or parent-chain traversal. This narrowly proves an
export cost of O(T_live+E_live), not normative O(T+F). A visitor's yielded source
Var remains diagnostic provenance, never a cache-installed current Var.

Requested Module publication is transactional: check sticky failure before
constructing A, hold A in a local owned temporary during same-store comparison,
and transfer ownership to dispatch only after successful validation. Any failed
comparison destroys the temporary. Existing early/errdefer clearEntryEvidence
still clears all current evidence on errors; the temporary does not depend on
Driver/Session teardown to prevent publication. A later dispatch round-trip
failure remains covered by that existing errdefer.

Existing A producer remains the independent diagnostic oracle on clean requested
checks. Its O(D+E_store+R+Q) construction and comparison costs are separately
reported; consequently the whole requested CLI still scans D. The oracle may
compare each indexed source Var/target to A's direct descriptor map, but the
usable index visitor itself does not use that map. No cloned persistent graph
or format-22 change is needed. Existing inspector bytes, public facts and cached
payload bytes stay exact. Warm cache installation does not invent an index for
an absent ordinary source store; optional profile events only describe actual
source index work, not a cached certificate.

## Validation and acceptance

Hermetic semantic tests cover live targets, shared/cyclic edges, equal/unequal
union, source identity, survivor replacement, alias deletion, retired-slot
reuse, many dead descriptors, fresh/reset lifetime and default absent index.
Allocator-failure controls cover each allocating mutation path and failed
finalization, retaining ordinary UF behavior and refusing all partial authority.
Actual CLI controls compare accepted A inventories/old inspector prefixes,
ordinary cache/public bytes and dev/release trees, including source/cold/warm,
errors/restore and default-after-query. Wide repeated tuples and real nominal
applications distinguish positional fields, raw arguments and F_record without
publishing a safety answer. Profile counters attach to actual loop bodies;
verification/export counters are separate from construction counters.

Manager independently reviews source, focused controls and exact final tree;
full gates and existing checker/build/RSS budgets remain required before
acceptance. Routine development uses pinned self-hosted Zig Debug. No budgets,
source limits, native assumptions or ownership rules are relaxed.
