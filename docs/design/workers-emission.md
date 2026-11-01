# Worker build planning and entry projections

Specified 2026-10-30. This implements the decided contract in workers.md §2–§5.
The restructuring below is required by that contract. It does not introduce a
new language feature or change a guarantee. Implementation is incremental;
this document does not claim multiple entries already emit.

## Build-wide state and entry-local state

The existing emitter has one Entry, one reachability result and one runtime
module. Separate planning facts from the mutable state used to emit an entry.
A build plan belongs to the Session. Its references are typed integer indices
into arrays, not pointers into another entry's arena.

The build plan stores resolved entryKinds, discovered Program declarations,
launch edges, canonical entry identities, protocol representation plans and
wire-visible field and tag naming constraints. A Program reference identifies
its package, module and declaration. The runtime selection belongs to its
entryKind. Markup adapters remain separate from entry runtime modules: a plain
worker runtime does not need markup exports or lowering.

Each entry projection owns its reachable declaration and initializer sets,
EntryHost proof, runtime roots, native binding obligations, private field
constraints, hoisted declarations and pending output. Reusing a projection
must reset these fields; sharing a mutable Emitter.live result across entries
is forbidden. Shared interned type and interface data is immutable during
parallel projection work. Each worker has its own scratch arena.

Typed global callback queues are module instances local to each realm. Realm
summary seeds and call constraints retain their owning declaration so a
projection includes only reachable producers. A page callback that uses the
DOM must not seed the worker instance of the same Task queue. Sharing interned
types does not merge the two entries' availability proofs. Pin this with a page
and worker that both use Task while only the page registers a DOM callback.

## Discovery before parallel work

Resolve and validate the platform table first. Constructor metadata identifies
its callback protocol and entry parameter index; launch metadata identifies its
Program argument. Resolve these symbols through checked interfaces. Unknown
symbols, inconsistent nominal types, parameter roles or runtime types are
invalid_entry_kind, without partially written output.

Start with the ordinary page root or explicit standalone entry. A reachable
launch discovers its finite set of static Program references. Their deferred
callback declarations are roots of the worker projection, not executable page
initializers. Repeat discovery until no new Program reference appears. Intern
an already-discovered reference instead of recursively expanding it. Opaque
factories that could synthesize executable code remain worker_entry_not_static.

Sort the final references by canonical package, module and declaration identity
before assigning entry indices. Stable output IDs derive from those canonical
identities, independently of discovery order and job scheduling. Detect output
path collisions for the whole plan before creating any output file. The page
keeps its existing entry path. Workers use the reserved _workers entry namespace
and descriptor URLs are relative to their referring entry artifact.

## Projection, naming and emission

For each entry, collect runtime roots, deferred bodies and evaluated initializers
in that realm. A module containing both page and worker declarations is projected
by declaration. Importing the shared source module does not authorize running
its page-only initializer in a worker. Reachability must include evaluated
initializer effects and their ordinary realm summaries.

Infer C's native realm obligations through ordinary types and callable summaries.
Discharge HostFree, Wire, callback protocol and backing-ownership obligations
before accepting a launch path. The presence of an entry runtime table by itself
is not permission to expose workers before these checks are implemented.

Collect the field and constructor interference constraints from all wire-visible
representation plans. Union them once in deterministic order and assign one
wire naming table for the build. Non-wire names remain entry-local. A projection
may shorten or eliminate private fields without changing another entry's wire
layout. Clone-stable plans emit direct sends. Only non-crossing representation
paths get normalization and reconstruction; universal codecs are not introduced.

Lower each projection with its own roots, runtime, EntryHost proof and private
state, plus the immutable build wire table. Existing optimizer and field naming
algorithms can be reused behind this boundary. Sharing an emitted chunk requires
identical code and initializer semantics valid in every importing realm;
otherwise keep distinct projections. Reuse is optional; isolation is mandatory.

All generated files remain pending until every projection and collision check
succeeds. Bootstrap installs the defect reporting and native error paths before
user initializers evaluate. Runtime run is called synchronously and starts its
owned root fiber. The runtime's ready handshake, not return from run, confirms
that worker init completed. An impure or suspending runtime body cannot bypass
its declared boundary through an erased callback.

## Interfaces, validation and measurements

Publish canonical Program references, resolved entry roles and callback protocol
versions in library artifacts. URLs alone cannot reconstruct deferred roots.
Cache keys include the binding-table revision, exported native types and realm
summaries, Wire plans and entry roles. An ordinary body change that leaves the
exported facts intact does not invalidate unrelated reverse users.

First validate the generic runtime table independently of markup, including the
full Program-to-unit type and non-suspension contract. Then validate standalone
entry selection, finite launch discovery and independent initialization before
adding shared wire naming. This is an implementation dependency order, not a
change to the final contract or an excuse to expose an unchecked worker API.

Fixtures must show page-only initializers absent from workers, worker-only
initializers absent from the page, a mixed module projected into both, nested
launches, cyclic discovery, unresolved factories, changed imported descriptors,
relative paths and failed-build atomic output. Compare jobs 1 and 8 twice.
Wire fixtures deliberately collide short names across entries and exchange
stable records, tagged unions and normalized List views in both directions.

Record total unique and marginal entry bytes, including emit/release/ goldens,
compiler time and peak memory. Realm checking retains >250k LOC/s; workers.md's
transport, cleanup, SolidJS 2 and Effect v4 measurements remain required. A failed
budget is a defect to resolve, not permission to remove typing or isolation.

## Resolved entry plan: first implementation boundary

The next slice retains resolved metadata in Session.entry_plan while continuing
to emit one ordinary top entry. It does not add source discovery or move the
whole projection at once. Existing development and release output must remain
byte-identical for unchanged programs.

The plan owns flat tables for kinds, constructors, launches and parameter roles.
A kind retains the checked nominal TypeId, declaring interface identity and
arity, native realm, platform layer, runtime declaration and ranges of its other
rows. A declaration reference stores module, declaration and interface scheme
indices. Role paths use a shared array of interned symbols. No row retains a
pointer into a temporary alias-expansion frame or a manifest arena. The selected
top Program identity and runtime are reused by main validation, runtime roots,
imports, specialization and entry emission instead of resolving them again.

All TypeIds and scheme indices belong to the current checked store. Clear the
plan before Session.run can replace that store, clear it before each new
contract-validation attempt, and free its tables in Session.deinit. Revalidation
rebuilds facts rather than accepting an earlier proof because names still match.
An invalid row or failed validation publishes no usable plan. A fresh emitter
may keep the independently resolved top nominal identity only for main diagnostic
comparison after a rejected contract; it is not retained in the Session plan.
Table capacity may
be retained across attempts; selected indices and row lengths must be reset.

Before validation, markup compatibility may inspect the manifest's declared
runtime candidate solely to choose which legacy exports to request. That is not
a proof. After validation, runtime selection consumes only the resolved plan.
Legacy platforms still receive their existing runtime-file or markup behavior.
The raw table remains available for diagnostics and later implementation stages;
its mere presence never certifies Wire, callback ownership or realm availability.

Tests pin plan clearing and replacement, runtime removal and rejected rechecks,
and agreement between check and build diagnostics. Existing runtime execution
tests and byte comparisons cover both output modes. This establishes a used build-wide metadata boundary before
independent projections and finite entry discovery are added.
