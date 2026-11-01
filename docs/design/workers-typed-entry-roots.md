# Typed entry declaration and role roots

Specified 2026-10-31, approved for implementation on base97d15b3c6.
Purpose: preserve immutable ordinary Program declaration/role type evidence.
This proves neither Wire, ownership, launch safety nor complete continuations.

## Actual source seam

Module.check P9 still has decl_scheme for private/inferred/polymorphic values;
its worker TypeStore then expires. Dispatch.decl_heads retains identity only.
ContinuationPlan exports suspension owners only. TypeKeys.wild loses evidence.
Types.build precedes Driver and assigns all nominal identities. Types.find is
the existing package/module/type resolver. Entry.Plan.Kind.program and
Role(index,wire/local,path) become authoritative only after Emit.checkContract.

## Finite publication artifact

Add Dispatch.entry_roots with present flag, MultiArrayList rows
{decl:Bir.DeclIndex,scheme:Interface.SchemeIndex}, and ordinary Interface terms.
Rows sorted/unique; scheme order equals row order. Scheme.body is the complete
ordinary value scheme, not its function result or reconstructed Program shape.
Retain original arguments, canonical aliases, quantifier kinds, where constraints,
identity/crossing flags, effects. Distinct owners keep distinct quantifier scopes.
Private values need no annotation; functions returning/records containing Program
are not candidates. Include constraint-only owner quantifiers.

At final clean P9 export selected decl_scheme using the same Effects.Publication
and identity-quantifier mapping as ContinuationPlan. No body binder mapping:
only owner schemes are exported. Reuse ScopedTerms iterative traversal with
ordinary Schemes.add envelope via tiny private single-root Writer seam selecting
scoped_mode and checking scoped_invalid. Preserve public add/addPlanRoot output.
Schemes1484/Effects1474 lines: factor new helpers rather than exceed1500.
No Effects changes. Register checker files in rules_test; child reads via Walk.
No arbitrary private depth cap; missing clean evidence is a compiler fault,
never usable-empty. Callable/raw/generic types remain valid ordinary schemes;
unused Wire-unfriendly values must not acquire diagnostics.

## Pre-check name selection lifecycle

An immutable EntrySelection holds platform package/module/type names plus source
manifest origin/layer. Derive from the SAME chain entryKinds as Emit.Options,
ALL kinds, not only top runtime. Legacy without entryKinds selects none.
After Types.build and before workers, resolve once with Graph.find/Types.find;
matching actual non-alias nominal types populate a dense TypeId bitset. Foreign
nominal Program heads remain selectable (current checkEntryKinds rejects aliases,
not foreign declarations). Missing/alias names select nothing and produce NO preliminary contract diagnostics. Full later
checkEntryKinds retains public/layer/duplicate/runtime/constructor/launch/role
validation. Invalid metadata may harmlessly overselect; selection is never proof.
Preserve graph duplicate_module boundary; no short-name identity comparison.

Match each value's resolved outer nominal head against this bitset, retaining
the original aliased scheme. Never select by annotation/ctor syntax/pub/result.
Work is name resolution + dense bitset + existing declaration scan + selected
reachable term export. Ordinary checking is independent of metadata success.

Session.checkPhases derives requests from options.chain. Explicit non-chain
callers assembling Emit.Options.entry_kinds must pass identical requests BEFORE
checking when they request typed-root inspection. Share one small request builder.
Existing checkContract can still validate without roots. New root consumers
must explicitly report unavailable/recheck-required for missing publication;
no fake root from heads, no checker rerun hidden inside Emit.

## Cache/version/reset

Distinct dispatch section; sidecar16 ->17, private EntryRoots schema1.
Public Interface version unchanged. Existing stable TypeRefs, not serialized
dense TypeIds/Vars/pointers/Plan indexes. Reuse/refactor accepted private ordinary
term validators instead of duplicating a type language or large codec.

Validate scopes, quantifiers/constraints/effects, DAG/alias cycles, no err,
unique strictly text-ordered ACTUAL record symbols, nominal kind/arity, row
decl bounds/value kind, scheme order, normalized root head == decl_heads.
Retain accepted head-projection memo and compact-alias work guarantees.

Before installing ANY directory/pack/interface-cutoff cache hit, after Types.build,
CURRENT selection completeness requires a root for every matching decl_heads.
A changed selection needing absent roots causes normal source recheck. Extra
validated roots from an older superset are allowed, but checked Plan.find governs
current consumption. Narrowing can reuse. Explicit empty is not complete under
a new selector. No source/public-interface hash pollution is necessary because
selection changes no source checking semantics. Unchanged public interface cannot
skip required private refresh. Old codec misses; all installed artifact paths,
including embedded packs, need this check. Core normally cannot refer to platform
Program, but apply coverage uniformly. Test interface-cutoff behavior explicitly.

Dispatch owns/free/replaces roots. Own/dependency errors clear them; no error
artifact cached. Requests run-lived/owned; bitset Check.run-lived; no borrowed
scratch or Plan in artifacts. Selection/view state resets at run start and
before checked replacement including early failures/contract revalidation.
Prefer no persistent query cache. Coordinate any Session hook with discovery
owner, who owns Session.entry_graph and Compact*. No modifications there now.

## Real typed-role consumer

Extend existing hidden checked entry inspector AFTER successful full contract
validation: candidate(module,decl) -> Plan.find(actual Program TypeId) -> owned
scheme -> canonical Program args -> checked wire roles. Print exact scheme,
candidate and result. Separately summarize local-role exclusion: local arguments
remain in full type evidence but are never traversed for Wire transport queries.

Immutable view = artifact+scheme+term+substitution environment+remaining path.
Select Program argument[index], follow aliases/record fields/extensions by ACTUAL
interned symbol. Results: root(view), generic obligation(view,remaining path),
or known closed shape mismatch. A completed var remains generic, not Wire=true.
Preserve ambient scheme where/effect/identity obligations; no unification/fresh
monomorphic guesses. Unused mismatch is inspector evidence only, not source
rejection. Reachable instance discharge belongs to later saturated discovery.

InterfaceTerms defines meanings, but its recursive instantiateRoot has public512
depth cap: do not run deep private evidence through it. A small private iterative
InterfaceView/RoleRoots cursor reuses accepted substituted-head projection logic,
without a full store/new type vocabulary. Bound work by encoded graph times total
explicit path steps/queries, no alias diamond expansion or retained popped frames.
Projected leaves retain ambient effect blocks rather than fabricate detached ones.

## Private nominal payloads: required follow-up, not silently included

The next isolated publication/cache/inspection slice is specified in
[workers-nominal-layouts.md](workers-nominal-layouts.md). It does not implement
Wire classification or the cross-artifact cursor.

Secret a roots retain identity/args, NOT ADT constructor payload definitions.
Public Interface.Ctor omits private/hidden constructors; payload_params is coarse.
Missing layout never means nullary/safe. Before WireShape classification, publish
private declaring-module layouts with ordinary ctor argument terms, owning type
quantifiers and canonical aliases via Publish.ctorTerms/Types.Builder authority.
Publish ALL local nominal layouts or separately design precheck demand lifecycle:
dependency private stores may expire before consumer root is known.
Private evidence is not a source export or construction permission.
Foreign/schema endpoint needs explicit opaque/schema-plan evidence, never fake ADT.
Recursion is nominal graph/fixpoint, not cyclic term expansion.
Root slice reports layout-unavailable if later classifier asks; layout codec,
completeness and costs require separately reviewed finite deliverable.

## Implementation and evidence plan

1. Approve normative doc first. New EntryRoots/EntryRootBuild, entry/Selection,
   small Writer seam, Module P9, Driver coverage and dedicated codec helper.
   No Task/Suspend/Inline/Lower/Effects changes.
2. Immutable role cursor + actual hidden entries inspector, coordinated with
   Compact owner. Warm inspector must use loaded artifact, not source recompute.
3. Exact CLI records private/inferred/aliased/polymorphic/where/effect/foreign
   nominal/no-site/indirect ctor cases; function/record negatives; local callable
   and raw state excluded; generic path obligation/completed root/closed mismatch;
   unrelated owners both a; actual nominal shadowing in representable graphs.
4. Cold/warm/forced interface+dispatch roundtrip/relocation/jobs equal; warm
   modules_checked0. Changed selector adds missing root with unchanged source AND
   public interface -> recheck -> next warm0; narrowed reuse; metadata override
   paths use new checked Plan; error/restore/repeated run; pack/cutoff coverage.
5. Deep2048/compact aliases scale; malformed scope/effects/symbol aliases/nominal
   kind-arity/row-head mutations repair cache, never panic or usable-empty.
   Codec fuzz/checker rules, no file-limit exception.
6. Representative emitted JS byte identity; individual release no-growth and
   behavior gates. Controlled same-base selected/zero-selection compiler costs,
   cache bytes, existing optimized plain+dispatch >250kLOC/s and build budgets.
   Counters alone are not throughput evidence.

Selected publication uses coverage-based cache fallback; this does not publish
every nominal-headed value by default or change the source language.

## Review addendum: owned role results, cache order, compact inspector

Reviewed against current source seams on parent integration base9c41e70e0;
ordinary metadata APIs remain as on eb89. These details supersede any ambiguity
about temporary cursor frames, cache comparison order, or printing.

### Role result ownership and indices

The consumer owns a RoleResults object for the whole inspector/planning pass:
MultiArrayList Result rows, MultiArrayList Frame rows, and shared extra words.
ResultIndex, FrameIndex and ViewIndex are typed enums with explicit none values.
A Result is {view:ViewIndex,kind,remaining,path:Range}; a View is
{scheme:SchemeIndex,term:TermIndex,env:FrameIndex}. One owner borrows one artifact,
so ArtifactIndex is implicitly zero; SchemeIndex also names its quantifier scope.
A Frame is {start,len}, a range of ViewIndex words in shared extra. Parent
environments reside on argument Views, not a redundant parent field. Remaining
path symbols occupy disjoint, Result-owned ranges of the SAME extra buffer.
Candidate/checked-role identifiers stay in the consumer's request/print context.
Arguments are original immutable views, never expanded substituted trees. The frame determines the
lexical interpretation of alias-body var(i); the owner scheme remains explicit
and its own quantifier var(i) is never confused with an alias formal.

Every Frame referenced by any Result or Frame is owned by RoleResults and immutable
after publication. Cursor stacks contain indices only and may pop/reallocate without
invalidating results. ArtifactIndex resolves through a pass-owned stable table
borrowing immutable Dispatch.entry_roots artifacts; those remain alive until AFTER
RoleResults.deinit/reset. Neither memory addresses nor slices into cursor stack or
scratch frames appear in Result/View/Frame. The consumer must destroy results before
Session.run resets/deinitializes checked artifacts. No result escapes this owner.

Allocate frame/extra storage in the result owner, using ordinary growable flat
containers (or its owned arena); reallocations preserve indices. One bulk deinit.
Reuse capacity only after every result/view from the previous pass is dead; an
internal generation assertion may catch stale view use but is not serialized.
Do not allocate a separate arena/box per node. Same alias application/environment
can intern the same immutable frame using a pass-local hash table of typed keys.
Argument Views reference original artifact terms and existing environment indices;
they do not copy or expand argument graphs.

The cursor uses the accepted projection summaries to jump projecting aliases WITHOUT
allocating frames. Only nonprojecting bodies that must be entered create retained
environment nodes; each such node corresponds to bounded normalization/query work.
Popped cursor frames are never retained merely to maintain stack offsets. The
result environment is a separate immutable DAG: every argument environment refers strictly to
an older FrameIndex, so cycles cannot be created by construction. A result ending
at a generic obligation owns the complete environment chain and remaining-path
Range, including symbol references, exactly as a completed result does.

Result storage/work is bounded by visited encoded graph times total explicit query
path steps/queries, plus input/output table sizes; no expanded alias diamond or
materialized substitution tree. Keep the projection/head memo once per artifact
DAG, not once per query. All extra ranges checked before publication. No free-standing
role scheme is synthesized: where/effect/identity constraints stay in the original
scheme scope named by each View. A later compiler consumer retaining results beyond
this pass must MOVE the entire result owner and retain its artifact owners, or
explicitly clone compact referenced tables; returning scratch-backed Views is forbidden.

### One shared cache preparation/coverage gate

Current concrete order is:
1. Session.checkPhases computes source key ingredients and allocates cached slots.
2. Check.run builds current Types, then resolves EntrySelection names into bitset.
3. Driver.check calls Incremental.claim on the DAG. claim first tries
   CacheEntry.loadFindingBytes for checked pack, then loadFinding for directory;
   both only decode/validate and populate the same cached[module] slot.
   Interface-cutoff reuses a key based on actual dependency interface hashes;
   it is not an independent permission to install incomplete private evidence.
4. Driver.checkInner is the SINGLE pre-install gate, after claim and before
   Incremental.install moves interfaces/Dispatch/plans or releases dependents.

Add one shared prepare/verify helper at that gate, e.g.
EntryRoots.prepareCoverage(loadedSidecar,module,bir?,graph,types,selection,scratch).
It returns ready or source_recheck (allocation failure remains an error).
It must run for prepopulated Check.Options.cached slots too, not only freshly
loaded directories. Incremental.install accepts only the checked ready path;
no alternate install caller may bypass it. Keep existing ordinary schema/hoist/
continuation/decl-head checks at this gate as well.

IMPORTANT: decoded Loaded.table.decl_heads currently stores serialized TypeRef
indices DISGUISED as TypeId until dispatch_bytes.resolve in Incremental.install.
Comparing those integers directly with selected TypeIds is incorrect. Factor one
nonmutating validated sidecar reference resolver used by BOTH coverage and install
(e.g. Loaded.resolveTypeRef / existing resolveType implementation exposed privately).
Coverage maps each serialized head through its TypeRef(package,module,type) to
current Types FIRST; missing nominal identity is source_recheck, not none accepted
as no match. A serialized explicit no_ref alone denotes no nominal head.
Never call the mutating whole resolve twice; it is not idempotent.

The helper validates unresolved sidecar heads against BIR when present, builds or
streams current dense heads via the shared resolver, validates each root's own
stable Interface.TypeRefs against current Types (kind/arity), normalizes its head,
compares it with the resolved declaration head, and only THEN applies selection
coverage. Resolving private root references may use a scratch dense ref-id table
during validation; no such borrowed table escapes in the immutable artifact.
Installation subsequently resolves/moves the complete Dispatch exactly once using
the same resolver semantics. No private artifact dense ids are serialized.

No directory/pack type resolution is performed before Types.build; loadFinding
merely parses stable references. A read-only interface preview/shell may be used
to calculate keys, but it cannot certify or install typed roots. A path having
only an interface and no dispatch sidecar is source_recheck even with no selected
roots: absence is not a present-empty clean artifact. A path lacking BIR cannot
validate declaration row count/value kinds/provenance: ensure/load its existing
frontend BIR artifact before the shared gate, or source_recheck through the normal
source/frontend path. Do not invent declaration evidence from public values.
The current Driver already has BIR at this gate; explicitly preserve that invariant.
If required source/frontend assets genuinely cannot be obtained, propagate the
normal input/cache recovery diagnostic, never an available-but-empty proof.

On source_recheck: deinit rejected loaded entry, set cached[module]=null, clear
cutoff.hit and cutoff.embedded, then continue normal Module.check in that same
Driver.checkInner invocation. This is the established malformed-sidecar fallback.
Do not return to Emit, silently re-run checking from an inspector, or mark the
bad entry installed. A failed pack completeness check may directly recheck source;
a second directory attempt is optional recovery only if it passes this SAME gate.
Module.check publishes fresh private roots; normal publish/storeEntries updates
the sidecar even if public interface hash did not change. Dependents are released
only after fresh publication. Hit/profile and cache slots must describe that path.

Tests should force pack and directory candidates, Check.Options preloaded-hit path
where applicable, source recheck after changed selector with identical public hash,
and no-sidecar/missing-BIR recovery. They must observe source-check counters and
actual artifact output, not just a helper's Boolean.

### Compact, sharing-preserving inspector

The real inspector prints an immutable graph, not recursively expanded type text.
For each candidate print source identity, scheme id, head nominal reference and
root TermIndex; then the referenced ordinary Scheme row, quantified/where/effect
rows and reachable term/type-ref definitions ONCE by stable artifact-local id.
Term edges print references (e.g. t12 = alias r3 [t4,t5]), aliases print named stable
nominal identities and canonical body reference separately. Preserve distinct
alias identity even when transparent normalization found the same Program head.
Recursive ADT payloads are not expanded; they remain nominal references.

Print role results as kind+View(term/scope/environment ids)+remaining path. Print
result environment frames once by FrameIndex with argument View refs, without
substituting every argument into every alias body. Include local-role excluded
summary without traversing its arguments into Wire queries. Effects print compact
encoded path/class references with symbol text, not expanded application trees.
Escape actual symbols deterministically; numbering/traversal uses stored artifact
row order and deterministic role order, never pointer/hash iteration order.

An explicit-stack reachable-row traversal with visited bits bounds printing by
unique reachable rows+edges+printed result/frame rows. It preserves graph sharing
for diamond inputs and never invokes the public InterfaceTerms512 reader or a
recursive source-style type renderer. Small exact output fixtures establish format;
deep2048 and diamond32/64 assert bounded output row/edge counts and actual alias
identity preservation, cold/warm/forced roundtrip bytes equal. This is inspection
of ordinary typed evidence, not a claim that the candidate is executable or Wire.

Implementation detail: TypedInspect.validate preflights availability for ALL current
checked Program candidates without allocation or output. The existing consumer
can map unavailable evidence to its ordinary internal diagnostic before printing;
TypedInspect.write performs the same preflight before emitting any graph bytes.
One RoleRoots owner borrows exactly one immutable artifact, making ArtifactIndex
implicitly zero; every owned View still carries its original SchemeIndex.

Validation scope: encoded ordinary alias diamonds32/64 test deterministic cursor
work and flat graph output. Actual source diamonds8/16 additionally test the
complete checker/publication/inspector path. The existing annotation constrain
phase expands larger source identity diamonds on both baseline and candidate;
source32 timeout evidence is retained separately, not hidden by a new product
cap or credited as a metadata regression. Private inferred depth2048 is tested
through the full cold/warm/forced-roundtrip CLI path.

Role result representation is pinned: project returns typed ResultIndex; each
Result owns a Range of remaining field-symbol words in the SAME shared extra
buffer used for Frame arguments. The consumed-prefix count is separate. The
original caller/Plan path may be mutated or released immediately after project;
returned obligations retain their own suffix. Frame/Result ranges never overlap
by accident, and every interpretation uses its owning row kind. No borrowed path
slice or expanded substitution is stored.

Name splitting exactly mirrors the established checked entry resolver: dotted
names split at the last dot; a bare name uses that same spelling for both module
and type. Preliminary selection may not reject/skip an existing checked kind
because of this legacy spelling fallback. Full checked validation remains the
only authority; this adds no new manifest shorthand or language rule.

Embedded recovery is now pinned to one shared directory loader and the same
pre-install gate. Loaded entries carry a nonserialized Origin enum (unknown,
embedded, directory); correctness must not depend on optional profile columns.
After rejecting embedded/unknown bytes, release them, clear hit/embedded flags,
try directory once at the already finished key, then apply the entire same gate.
A rejected directory candidate falls through to one normal source check. This
allows a dynamic platform's newly selected builtin kind to become directory-warm
instead of repeatedly rejecting an immutable insufficient embedded pack.

The pack maker knows the complete registered platform table. Resolve its chains
first and collect one immutable union of all their preliminary kind-name requests;
pass that fixed superset to EVERY pack-making check, including each base-chain
run. Runtime consumers can use any subset, checked by ordinary coverage. This
keeps duplicate same-key pack entries content-consistent without changing generic
Pack.Writer deduplication, source keys or public interface hashes. Future dynamic
unregistered selectors still use the shared source/directory recovery path.

## Implemented boundary and validation ownership

The implementation adds no production Task, Suspend, Inline, Wire classifier,
transport launcher or generated payload channel. Fresh and cached roots use the
same ordinary Interface vocabulary. Empty requests take a constant publication
fast path and still produce an explicit complete-empty artifact. The ordinary
public interface format is unchanged; dispatch sidecar17 carries the separate
private schema1 section. Source errors clear artifacts rather than publishing
usable empty substitutes.

TypedInspect.validate performs an allocation-free authority/availability preflight.
TypedInspect.write prints through the existing flat interface graph printer and
owned view/frame rows. The existing entries consumer is responsible for mapping
internal unavailable evidence to its normal diagnostic, and only invokes typed
inspection for a validated, selected generic entry kind. Legacy plans can be
validated but have selected=none; they retain their existing partial/unsupported
inspection behavior. A temporary consumer integration hunk is handed off separately.

Compiler-cost/byte validation must use the final accepted base and matching
source/backend/cache flags. Focused tests are not a throughput or C/Wire proof.
Manager owns final full gates and acceptance; private nominal layout publication
remains a separately specified follow-up.

### Entry consumer preflight and unavailable evidence

The entries inspection bridge performs typed availability preflight after the
existing complete entry contract has validated, and before source discovery or
any compact/typed output. Only a validated Plan with a selected generic kind
enters typed inspection. A validated legacy Plan with selected=none keeps its
ordinary partial/unsupported compact output and does not require typed roots.

If the checked selected Plan has unavailable retained roots, inspection returns
an ordinary owned Emit.Item with the existing internal diagnostic code, anchored
to the ordinary entry declaration. The message identifies a compiler evidence
failure, not invalid source or a Wire failure. The caller renders it through its
existing diagnostic stream and prints no entry graph. No rechecking, cache
recovery, contract resolver, or emitter run is started at this consumer seam.
Diagnostic list/message ownership follows the existing inspection allocator;
allocation failures release all already-owned messages.

The public-internal entries.write boundary independently preflights before its
first byte. Direct callers therefore receive MissingEntryRoots with an empty
writer rather than partial compact output. Normal CLI callers have already
converted that condition into the explicit internal diagnostic during inspect.


## Dependency-tainted worker evidence

Outer declaration heads, symbolic continuations and typed entry roots require
clean transitive dependencies as well as a clean, non-quiet local module.
Dependency-tainted terms can contain error nodes without a local user error;
those terms must not enter private evidence publication or add an internal error
beside the original dependency diagnostic. Clear prior worker evidence before
fallible module setup and on escaping allocation errors. Quiet, poisoned, locally
erroneous and dependency-tainted modules retain absent evidence. Restoring valid
source may reuse the original clean cache entry through the ordinary rules.

## Owned cross-artifact consumer follow-on

[workers-cross-artifact-cursor.md](workers-cross-artifact-cursor.md) specifies
the shared owned ordinary-view kernel, declaring payload substitutions and finite
checked inspector consumer. It does not classify Wire or HostFree.


The next diagnostic-only ordinary store inventory is specified in [workers-solved-representations.md](workers-solved-representations.md); it does not add HostFree or Wire certification.
