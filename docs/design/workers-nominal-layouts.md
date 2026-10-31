# Private nominal layouts for Wire prerequisites

Implementation specified 2026-10-31. Slice A only: complete declaring-module
layout publication, cache coverage and an actual checked inspector consumer.
This is ordinary type evidence, not Wire/HostFree/callback/ownership/launch proof.
The entry foundation was accepted at7eca9716c. This slice's initial pending
dependency and final accepted base remain pinned separately in its receipts;
this document does not claim acceptance of the implementation or its costs.

## Declaring authority and lifetime

Publish all local nominal declarations, including hidden types/constructors and
unused types, at clean Module.check P9. No entry selection or construction site
selects this artifact. Alias bodies remain canonical ordinary Interface terms.
A module with no nominals publishes explicit complete-empty metadata.

The final KeyKinds.Preparation owns an indexed per-TypeId table of declaring
parameter Vars in declared order. Its initialization binds declaration slots,
including phantom parameters; its ordinary run settles parameter requirements.
Module retains the final table through P9: start with initial preparation and
replace the borrowed table after the final via-schema preparation finishes.
Both tables/Vars live in Module's scratch arena and current TypeStore, which
outlive P9. They never escape into Dispatch. The publisher validates each local
owner's parameter count against Types.Entry.arity and source declaration slots;
it uses these actual parameter roots, not a scan of annotation-variable names,
field-variable roots, or names as identity. Schema endpoint slots come from
Schema.State's actual endpoint parameter table. Final kind requirements are
those settled by ordinary preparation, including via-conversion changes.

CtorTypes is the shared ordinary constructor-input helper. Public ctor publication
continues to create/bind/read exactly the roots it currently uses, preserving its
bytes. Private publication binds final declaring parameter roots to the owner's
actual declared slots and reads payload arguments through Context.builder's
schema-aware Types.Builder authority. It does not instantiate a dependency's BIR.
No fresh monomorphic guesses, ordinary type changes, or binder sharing between
unrelated owners. No map keyed only by dense TypeId: use indexed table/range
storage for dense ids and stable symbolic references in persistent artifacts.

Types.keyKinds publishes only closed key domains: it is not the full numeric/
appendable binder-kind authority. Publication preserves the actual final parameter
Vars. Cache validation uses the same ordinary kindOfName rule on DECLARED formal
slots, met with settled keyKinds, and checks stored kind flags by formal position. Ordinary display names remain
writer-defined (a kind-incompatible display name is omitted); they are never
parameter identity.
This validates source binder slots without scanning annotation variables or
reconstructing binder identities. Opaque/schema rows need no payload binders.

## Private artifact

Dispatch.nominal_layouts owns an artifact with present flag, schema1, fixed
MultiArrayList owner/constructor rows, flat argument ranges and ordinary private
Interface terms. Owner rows are in current declaring type order and retain:
actual declaring TypeRef, BIR declaration identity, arity and layout kind. ADT
rows additionally retain one owner scheme; explicit opaque/schema rows have no
payload scheme and do not manufacture endpoint binders. ADT rows retain every constructor's source ordinal, name and
ordered argument terms. Constructor names do not grant source access.

One ordinary tuple scheme bundles owner application T p0..pn first, then ordered
payload roots. The anchor preserves declared/phantom quantifier positions and
kinds; the owner scheme has EXACTLY arity quantifiers, never extra temporary
flexible variables; args refer to terms in this same scheme scope. Use existing private
Schemes.addPrivate/ScopedTerms, including canonical aliases, constraints, effects,
identity and crossing flags. There is no second serialized type language.

Foreign/native and schema endpoints have explicit distinct row kinds and no
ordinary ADT payload layout. A missing or empty constructor range never makes
these clone-safe/nullary. Schema rows identify the existing checked endpoint;
native rows retain actual opaque nominal identity. Their later precise
serialization/transfer contracts are unavailable here. Alias identities need no
ADT row; their canonical expansions remain terms.

Nominal recursion remains application edges, not cyclic term expansion. Empty
ADT is accepted as such only when the declaring authority explicitly proves it.
All mutable stores/scratch roots are consumed while alive; Dispatch owns only
immutable ordinary terms and row indices. Own/dependency errors discard this
artifact; no usable partial/empty proof is cached.

## Private depth and ordinary reader policy

The private writer has no publication depth cap. Types.Builder's public recursive
reader policy must not become a new limit on accepted private data. If a private
iterative reader is required, factor shared ordinary node/alias construction
semantics into a helper before using it. Preserve public reader diagnostics and
public ctor output; do not widen a constant, silently omit a layout, add a source
refusal or inspect raw annotation-variable spellings. Compact aliases retain the
accepted memo/projection semantics, not materialized expansion trees. A clean
module lacking required private layout is a compiler fault, not Wire=false.

The concrete reader seam is shared type-child enumeration and node construction.
The existing recursive path keeps its ordinary depth/error policy. A private
iterative TypeRead helper uses the same construction operations, enabled only
by Builder.private_read; aliasBody propagates that flag. The nominal publisher
and its canonical-alias body reader use shallow=true and private_read=true.
Function sync marks, record extension order, schema lookup, named type identity,
key constraints and alias memoization retain the ordinary operations. No new
independent decoder or duplicated annotation-variable interpretation is added.

## Codec, verification and common install gate

Append private nominal-layout bytes to dispatch sidecar17→18; artifact schema1.
Keep public Interface export/version behavior unchanged. A separate codec helper
uses ordinary private Interface encoding and validators, stable names/TypeRefs,
not serialized TypeIds/Vars/Graph indices/pointers or cursor state. Old versions
miss normally. Validate all counts/ranges, owner and constructor uniqueness,
source ownership/arity/order, quantifier scope and flags, constraint/effect rows,
actual text-ordered record symbols, alias/DAG cycles and absence of err. Resolve
nominal references once against current Types and verify kind/arity.

Before every directory, embedded-pack or interface-cutoff install, the existing
common Driver preparation path verifies complete CURRENT local coverage, including
private constructors and schema/native distinctions. Missing/stale/malformed
coverage causes ordinary source recheck and repaired storage; cache slots and
hit/profile bits follow the actual path. A bad embedded pack may fall back to a
valid directory entry. Never accept unresolved identity as an absent owner.

Before installation, current Types may not yet hold an unpublished PRIVATE
owner's settled key domain. A global any slot is not a settled answer. Validate
stored formal kinds against the DECLARED formal bounds and any matching LOADED
ordinary interface facts, without installing/mutating global Types. For a private
owner absent from that ordinary interface, its validated checked layout artifact
is the retained ordinary kind authority; its kind must narrow the declared
formal bound and agree with any already-known key requirement. Fresh publication
separately requires the actual final Preparation Vars exactly. Never recheck
sources secretly to rediscover unpublished kinds or mutate globals before a cache
candidate has passed preparation.

A private payload edit may leave the public interface unchanged. Its module's
own source entry still refreshes; ordinary reverse users may remain cached only when BOTH the public record and
ordinary read/dependency digest remain unchanged. The existing digest can observe
private representation changes even when public record bytes do not change. The
inspector reads the fresh dependency artifact. No persistent Wire query cache is
introduced. Future Wire summaries/fingerprints must depend on this layout ABI
closure plus native/schema/role revisions, so an ordinary interface cutoff cannot
retain stale Wire proof. Publishing private layout grants no source constructors.

## Actual bounded consumer

Extend the existing checked hidden entry inspector after complete contract
validation. For each application module, each declaring module of a checked Program kind,
and each module containing a validated selected root, inspect its own nominal artifact and print compact owner schemes, constructor payload term
references and explicit native/schema-unavailable states. It may show all local
owners needed to demonstrate complete publication, including no-site/private ones;
it does not follow cross-module substitutions or classify Wire. Dependencies may
be inspected as their own artifacts. Cold/warm/roundtrip output must agree.
All output remains proof=ordinary-types,wire=false. No source reconstruction or
unification inside Emit, and no new language syntax/keyword/unchecked operation.
A missing clean artifact is explicit internal unavailable/recheck-required.

## Verification and performance

Pin private/no-site/public-opaque constructors, multiple/phantom parameters,
actual kinds, unrelated same-spelled owners, schema via conversion, nested alias
and record shapes, recursion and nonregular argument-changing recursion, explicit
foreign/schema opacity, and ordinary caller/root-local behavior. Test deep2048
instantiated payload arguments plus deeply written source at every previously
accepted depth and compact alias diamonds. Preserve all public ctor bytes.

Test cold/warm/jobs1/8/forced codec roundtrip/relocation, complete-empty modules,
all-private dependencies, private payload edits through public-interface cutoff,
embedded-pack fallback, error→restore and repeated Session resets. Corrupt missing
owner/ctor rows, scope/kinds/effects/identity/record symbols/nominal refs/arity,
cycles, ranges and versions: repair via miss/recheck, never panic or usable-empty.
Extend byte fuzzing and checker-module rules; respect1500-line checker files.

Existing self-profile counters expose actual publication owner/constructor/argument
rows, private written-node/alias-body walks and warm coverage local-header/ctor/
reference/term walks. Counters are worker-local Check.Counters and join through
Session's existing reflective profile reduction, never unsynchronized Profile
updates. Disabled profiling passes null work sinks. Increment at real loop bodies;
failed cache probes retain their work when source fallback replaces the module
counter. Coverage uses current module entry_offsets and only artifact-local ref
storage, not an all-global scan/allocation per module. Canonical alias body scopes
remain independent of outer owner parameter kinds/names.

Measure actual all-local publication/cache bytes, encoded nodes/visits/alias
sharing, cold/warm time and peak memory, including many unused types and native
modules. Compare the SAME accepted base with and without this slice, selected
and zero-selected entry metadata. Existing optimized plain/dispatch >250kLOC/s,
100k-line build target, individual release no-growth and ordinary behavior/byte
checks remain required. No budget waiver, deferred missing layout or new cap.


Private-cutoff evidence distinguishes two edits. A private payload formal rename
with the same ordinary indexed type/digest can keep Main cached while Library
refreshes. Retained ordinary display-name string bytes change; owner/ctor/argument
rows and every non-string private Interface column must remain identical. An
Int→String private scalar representation edit changes ordinary dependency digest
on the dependency baseline too: both baseline/candidate check Library+Main, while
public record bytes remain equal and fresh declaring payload evidence changes.
Neither case is permission to redesign ordinary digest policy or cache future
Wire proof without its independent queried-layout ABI closure.

## Dependency-error correction specified 2026-10-31

A module is eligible for nominal publication only when its own report is clean,
it is not quiet/poisoned, AND Driver's transitive dependency_errors is false.
Dependency-tainted ordinary terms can contain err without a local user diagnostic;
they must never enter the clean-layout verifier or cause a second internal error.
Clear any previous nominal artifact at Module.check entry, before fallible setup,
and discard it on every escaping allocation error as well as reported own errors.
Quiet, poisoned and dependency-tainted paths retain absent metadata, never a
complete-empty artifact. This does not change ordinary diagnostic/digest policy.
The common clean install gate still requires complete metadata; erroneous source
cannot publish or retain a usable layout. Restoring valid source may reuse its
previous clean cache entry under the ordinary existing cache rules.

Regression evidence must compare the actual accepted baseline's unknown-type
error against both cold/warm checks and build, prove no internal error or inspector
output/no emitted files, then restore source and prove exact original layout plus
zero-source-check warm reuse. Preserve the original frozen slice and its failing
before logs rather than replacing them with corrected claims.

The shared clearEntryEvidence boundary owns nominal layouts together with
declaration heads, continuations and typed entry roots. Its entry, escaping-error
and own/dependency-error paths clear all four artifacts as one publication unit.

## Normal benchmark reporting compatibility specified 2026-10-31

The normal benchmark CheckMeasurement mirrors every Check.Counters field because
its existing reflective copy and JSON printer use those names. Add all nine
nominal observation fields to that reporting record; do not change the measured
Session options, timing boundaries, iteration method, compiler flags or corpus.
Profiling stays disabled inside ordinary timed checking. The optional nominal
work observations therefore remain zero in those rows: zero observations never
mean zero publication/coverage cost. Actual timing still includes all work.
Separate profiled correctness/preparation controls retain positive source work
and warm coverage evidence. Existing inference counters retain their meaning.

The compiler build-id recipe includes build.zig, src, core and platform inputs;
it excludes benchmark source and design prose. This reporting-only correction
changes the benchmark binary/source manifest, not the already frozen compiler
CLI source identity or behavior. Preserve before/failure receipts and pin the
new benchmark artifact independently rather than rebuilding an unchanged CLI.

## Owned cross-artifact consumer follow-on

[workers-cross-artifact-cursor.md](workers-cross-artifact-cursor.md) specifies
the shared owned ordinary-view kernel, declaring payload substitutions and finite
checked inspector consumer. It does not classify Wire or HostFree.
