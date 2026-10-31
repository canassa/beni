# Cross-artifact ordinary type cursor — proposed slice B

Implementation specified 2026-10-31 after manager review. Part of #1294/#1296
on PR #1304. This document precedes the slice B implementation.

Prerequisite accepted/pushed slice A is fef928da4205b331b3b1f17928900d78fed13cf3,
tree19f9c7e2b513a9d35c9d63935f66b777f0c90b1d. Its cursor source seams match the
reviewed A patch2f9e3cadc7aa3122455eb4b3dd7cd42a68bdecc594542b561bbbf18a0ddcf5b3;
additional accepted reporting/design/validation changes do not alter those seams.
Production format remains private dispatch18, EntryRoots1 and NominalLayouts1.

This is a used, owned ordinary-type reader foundation. It preserves source type
identity, binders and evidence while crossing from a selected Program role to a
private nominal's declaring payload. It does not classify Wire/HostFree, infer C,
certify continuations, prove ownership or permit a public launch. In particular,
walking a function node does not establish that its callback contract is solved.
No source grammar or decided guarantee changes. No owner decision is needed for
this bounded reader; downstream classifier work remains explicit.

## Existing seams and scope

EntryRoots owns complete selected declaration schemes. Current RoleRoots borrows
ONE such Interface, owns views/frames/results, and expands aliases or follows a
role's record path. Its View.scheme identifies that original scheme; its alias
frame owns argument views. Projection summaries already avoid expanding identity
alias diamonds. This is used by TypedInspect AFTER full Plan validation.

A's NominalLayouts owns every local nominal's declaring artifact. An ADT owner's
scheme bundles the owner application first, then ordered constructor payloads.
The anchor fixes declared parameter order, including phantoms and actual final
kinds. Constructor arguments are terms in that SAME owner scheme. Native and
schema owners have explicit unavailable contracts, no payload scheme. Aliases
have canonical Interface.TypeRef.body terms, not fake ADT rows.

B replaces the one-artifact cursor kernel with a pass-owned multi-artifact kernel
and retains RoleRoots as a thin compatibility facade. Refactor one shared alias/
projection/field operation; do not create a second decoder or reconstruct types
from BIR annotations. Old RoleRoots output and its exact tests remain unchanged.
New inspector output is appended after the existing complete A output.

No Session entry_graph/discovery/template algorithm, Module publication, dispatch
codec, checker inference, Task/Inline runtime, JS lowering, native binding table
or public API change is required by B. Small Profile/Emit/inspector integration
may be needed for actual counters and checked consumption. Add helper files
rather than enlarge checker files past 1500 lines; register any checker helpers.

## Pass owner, registry and lifetime

One TypeCursor owner belongs to one serial checked inspector/planning pass. It
borrows the immutable current Graph, Types, Dispatch and global interner and
owns every cursor row, frame, path, memo and result it publishes. Deinit before
Session.run/reset, checked-artifact replacement or Plan revalidation. Results do
not escape that owner. No query result is cached in Dispatch or across runs.
An internal generation assertion may detect stale handles; no generation is
serialized or treated as source identity.

ArtifactIndex identifies (current Graph.Index module, artifact kind). B registers
only entry_roots.types and nominal_layouts.types. Artifact rows store these typed
indices, not an Interface pointer. The owner resolves a row through its borrowed
Dispatch slice. Deterministic module/kind slots or a single dense module-to-slot
array avoid a hash map keyed by module. Materialize per-artifact memo columns
lazily when first touched. Zero role queries allocate no cursor registry/memos.

For each registered artifact, resolve each stable TypeRef once using existing
package/declaring-module/type identity resolution. Retain a dense local TypeRef
index -> current TypeId column. Do not use importing-module exports as nominal
identity, compare bare spellings, or serialize the TypeId. This also works when
an inferred public value mentions a hidden type its consumer never imports.

A per-TOUCHED-module local TypeId-offset -> OwnerIndex column maps nominal heads
to A's owner rows. Size it to Types.entry_offsets[m+1]-entry_offsets[m], never to
all global types per module. Fill from the validated local owner table, excluding
ordinary aliases. No all-global scan/allocation per artifact and no dense-ID map.
Every resolved owner must match current declaring module, declaration, identity,
kind and arity; use A's installed coverage authority, not public ctor exports.

## Fixed rows and lexical substitution

Use distinct enum(u32) indices with none sentinels: ArtifactIndex, ScopeIndex,
ViewIndex, FrameIndex, ResultIndex and OriginIndex. Range is start/len into typed
flat sidecars. All variable-length data is in owner-level arrays, not node boxes.
The following are conceptual row fields, not a mandate for a specific bit packing:

- Scope: artifact, tag (scheme or alias_formals), scheme/ref payload. A root or
  nominal scheme has its original Interface.SchemeIndex. An alias-formal scope
  names the canonical TypeRef whose body owns those positions.
- View: artifact, term, lexical_scope, environment FrameIndex. It is an immutable
  structural reference, never a materialized substituted term tree.
- Frame: target ScopeIndex plus a flat range of argument ViewIndex. Argument
  views retain their ORIGINAL artifact/scope/environment. There is no borrowed
  slice into a cursor stack and no redundant mutable parent frame.
- Result: view, origin, result kind, and an owned remaining path range when a
  projection is incomplete. ResultIndex is the external query handle.
- Origin: parent OriginIndex, operation tag, source/result views and typed
  operation payload (root scheme, field/index, alias ref, or nominal owner/
  constructor/argument). Fixed fields and flat sidecars retain source provenance.

Lexical scope and query provenance solve different problems. var(0) in a layout
owner, var(0) in a root scheme, and var(0) in an alias body are different binders
regardless of display names. Resolving a formal selects its stored actual view
and therefore restores that view's artifact, scope and environment. A root var
with no environment stays an ordinary generic obligation. An alias formal may
not remain unbound after a saturated, validated alias application; that is an
internal invalid-view error, not a freshly guessed quantifier.

A nominal boundary builds ONE frame binding owner scheme positions to the app's
argument views in declared order. Payload views use the declaring artifact,
actual owner scheme and that frame. Never reinstantiate a dependency's BIR or
read annotation-variable spellings. Two unrelated owners named a keep distinct
ScopeIndex values. Phantom positions remain present even if no payload reads them.

The alias body has no independent Scheme quantifier row in today's Interface;
do not manufacture kinds/constraints for it from its variable names. Its formal
positions are substituted with actual views. Quantifier metadata queries resolve
to the original actual/root or nominal-owner scheme. Ordinary checked arity/kind
compatibility remains authority; the cursor performs no unification or inference.

Each frame's argument environments reference already-published frames. Frames
and views are immutable after publication. Reallocating SoA or sidecars does not
invalidate results; keep indices/copy fixed rows before a call that may grow the
same container. Interning composite structural keys may reuse frames/views, but
never enumerate Cartesian products or specialize by whole caller environments.

## Operations and evidence provenance

Suggested public operations return ResultIndex, never a bare scratch-backed view:

- root(module, declaration, checked kind/role): find the retained EntryRoots
  scheme using actual checked Plan identity. Exclude local roles BEFORE reading
  their argument. Preserve callable/raw local state in the full scheme evidence.
- normalize(result): substitute lexical variables and expand aliases to the next
  ordinary head. Reuse one accepted projection summary per encoded artifact DAG.
  A projecting alias jumps directly to its actual argument without a frame.
- project(result, owned field path): follow aliases, actual interned field names
  and record extensions. Return complete, generic obligation plus the exact
  remaining suffix, or known closed shape mismatch. Own the suffix before return.
- children(result): expose ordered tuple/app/function/record children as owned
  result references; record extensions remain explicit. This is structural
  access only and confers no Wire or callback judgment.
- payloads(result): after normalization of a nominal app, resolve its declaring
  owner, bind the actual argument views once, and return an owned constructor/
  argument result range in the declaring owner scheme. Preserve constructor
  source ordinals, names and nullary/empty ADT distinctions.

Every operation appends/reuses compact Origin rows rooted in the original
selected scheme/role. Crossing a nominal boundary also records the owner scheme.
Aliases record expansion provenance; projection summaries may record one compact
summary edge referring to the original encoded DAG, never expand a diamond just
to print a path. Following a formal retains both the substitution edge and the
actual view's original scope. Immutable origin chains form an owned DAG.

This keeps the root's original where/identity/crossing/effect authority and every
entered owner scheme available after return and after cursor reuse. Do not detach
an apparently monomorphic role into a synthetic scheme, discard ambient method
constraints, rewrite effect paths to empty, or infer purity from a cursor head.
Retain effect blocks exactly with their source schemes; mapping a later C query
onto those paths needs its own reviewed proof consumer. B does not expose a
function-effect certification API. If a later consumer needs evidence not present
in A, report that prerequisite explicitly rather than treating absence as proof.

Opaque results are explicit: native_contract_unavailable, schema_type_contract_
unavailable and schema_encoded_contract_unavailable. Empty ctor ranges cannot
produce ordinary-nullary or clone-safe conclusions. A confirmed ADT with zero
constructors is distinct. A generic projected var is obligation, never safe.
Functions remain ordinary function nodes; B does not reject unused function/raw
payloads or introduce worker serialization diagnostics.

## Finite actual inspector consumer

Extend the EXISTING hidden checked entry inspector after its complete validation.
Build and validate the new owned section before writing any inspector output;
missing clean evidence must not leave a valid-looking partial graph/prefix.
Preserve the entire previous typed-root and A nominal output byte for byte, then
append a versioned cursor section labeled proof=ordinary-types, wire=false.

The consumer has two finite components:

1. For each checked candidate's explicit wire role, project the retained root and
   expose at most ONE payload boundary of its normalized nominal head. Print the
   actual argument frame and normalized immediate payload heads. Do not recurse
   from an instantiated nominal payload into another instantiated owner. Local
   roles print excluded and do not create payload queries.
2. Print a source-finite template/reference directory for the touched declaring
   artifacts. Register each artifact once; scan its encoded term/ref columns once
   and link each nominal TypeRef to its declaring owner/artifact. Enqueue newly
   referenced DECLARING artifacts, not instantiated argument tuples. Each artifact
   and owner template is emitted once; canonical payload terms/roots refer to A's
   already printed ordinary tables. Argument terms remain symbolic, scoped views.

The directory may inventory all encoded nominal refs of a touched A artifact,
including unused local owners. Say this explicitly; it is not precise entry
reachability. Charge/measure those real source-column visits. Do not repeat the
same large alias body per owner just to discover its references; artifact-level
memo/scans preserve sharing. Native/schema rows terminate at unavailable states.

For Recursive a = Leaf a | Next (Recursive (List a)), print the template edge
Recursive -> Recursive with symbolic argument List a and its owner scope. For a
root Recursive Int the immediate frame is a -> Int. Never enqueue Recursive Int,
Recursive (List Int), Recursive (List (List Int)), ... . Mutual/module recursion
also stays an owner/template graph. Repeated owner identity is a graph edge, NOT
a solved Wire proof or a permission to drop the argument transform.

The cursor API itself supports explicit additional payload/project operations;
unit/black-box consumer tests can issue finite explicit paths to prove multi-hop
substitution. Its caller must supply a finite demand schedule. This inspector's
schedule above is source-bounded; it is not a partially implemented classifier
whose safety changes when a recursion limit is reached. Future Wire/HostFree
classification needs symbolic/parametric SCC summaries and its own reviewed
complexity proof. No source cap, silent deoptimization or arbitrary depth refusal.

## Availability, validation and cache boundaries

B trusts only fully checked current Plan and installed A/EntryRoots artifacts.
Before output, required root/layout absence or unresolved clean identity is an
explicit internal missing-evidence/recheck-required diagnostic. Corrupt cache
bytes still go through existing common Driver preinstall coverage -> ordinary
miss/source repair; the cursor never installs or mutates cache candidates and
never secretly reruns the checker. No usable partial result survives preparation
failure. OOM propagates with complete owner cleanup.

Input scopes/indices/ranges are validated by the existing private codecs plus
cursor construction checks. A shape mismatch/generic obligation is ordinary
inspection evidence, not an internal fault or a new source rejection. Invalid
foreign/schema contracts remain explicit unavailable, not a cache miss that can
turn them into ordinary ADTs.

There is NO persistent cursor/query cache, so B needs no dispatch/public Interface
version bump or hash pollution. Pass-local memo keys include actual artifact,
lexical scope, term and environment where relevant. A single raw TermIndex cannot
identify variables across artifacts/schemes. Reset invalidates all handles.

A body/private payload edit reuses only ordinary installed artifacts under current
Driver rules. The next inspector follows the refreshed DECLARING layout even if
a reverse user's unchanged public interface allowed it to stay cached. Test this
using A's genuine same-digest private-formal rename cutoff, and separately scalar
payload edits that already invalidate both modules on the accepted baseline.
Do not claim a nonexistent cutoff. A future persistent Wire summary must key on
the queried private layout ABI closure plus role/native/schema/representation
revisions; ordinary public hashes alone cannot certify it. B introduces no such
summary/fingerprint.

## Required regression and cost matrix

Black-box checked inspector tests are the principal evidence; registered units
supplement the immutable-owner/algorithm invariants. Count ACTUAL tests. No JS
implementation/test probes: real Beni/Zig and existing generated-output harnesses.

- Private imported Secret a, hidden/no-site constructors, private nominal types
  exposed only through public function schemes; two-hop imported aliases and
  payloads; same-spelled a/name in unrelated owners/packages; multiple/phantom
  parameters, final numeric/key kinds, where/identity/crossing metadata.
- Alias projection plus nested nonprojecting aliases, aliases in actual arguments,
  records/extensions, generic role paths and closed mismatch. Distinct root and
  owner var(0) must remain distinct. Root local callable/raw state is excluded.
- Return a payload result, issue many further queries/reallocations and reuse the
  cursor, then normalize/project the ORIGINAL result. Do the same for generic
  remaining-path results after caller path mutation and owner/frame growth.
- One/two-step explicit payload operations bind Int and String independently to
  the same owner; a variable passed through another owner's a must resolve to the
  original scope. No source-name equality or current-cursor stack dependence.
- Direct/mutual recursion and Recursive (List a) template output are finite and
  retain symbolic argument edges; no enumerated specializations. Counted growing
  owner/alias diamond tests prove sharing rather than merely a passing timeout.
- Native opaque, both schema endpoints, true nullary and empty ADTs are distinct.
  Unused function/raw payloads check unchanged and never receive false Wire=true.
- Cold/warm/jobs1/8/twice/relocation/forced interface+dispatch roundtrip output
  EXACT; zero warm source checks, unchanged warm cache bytes. Inspector failure
  emits no partial output; error/restore and repeated Session reset erase handles.
- Cached private layout update/cutoff, bad embedded entry -> directory/source
  repair, malformed root/layout scope/identity/arity/version still follow A's
  common install gate. No second decoder or unchecked error fallback.
- Full unfiltered gates on final tree; existing generated dev/release program
  trees and each release golden byte-identical for this reader-only slice.

Expose optional owner-local actual work counters: touched artifacts/refs/terms,
projection summary nodes, normalize steps, frames/views/results/origins published,
owner lookups and payload edges. Counters are observations, not budgets or a
separate authority. Join through existing serial/profile reduction after the pass;
never write shared Profile from parallel workers. Disabled profile uses null sinks.

Let E be encoded nodes/refs of touched artifacts, A their explicit argument/field
edges, and P total explicit query/path work. Registry/template preparation is
O(E+A), plus existing indexed identity resolution. Structural queries retain
compact original views and work proportional to actual encoded query work; no
expanded alias diamond or concrete recursive closure. Report counters separately
from measured time, and pin both source demand size and emitted row counts.

Measure same-accepted-A baseline versus B: selected rich/private and zero-selected
ordinary check/build, inspector cold/warm, many-module/touched-artifact inventory,
large shared aliases, deep private inputs at accepted depths, peak RSS, all owned
table bytes and cache bytes. Ordinary no-inspector execution should perform no
cursor work. Inspector time/output may increase for real new evidence; no invented
speed-parity claim. Preserve >250k LOC/s plain/dispatch checker and <800ms cold100k
build budgets using normal optimized verification when required by final scope;
routine iteration uses the Zig development Debug build. No weakened gate, source
cap, dropped failed sample, byte waiver or safety claim from counters alone.

## Reviewable integration order

1. Manager reviews this draft and appends its accepted contract to docs/design/
   BEFORE implementation. Link from workers-typed-entry-roots and nominal-layouts;
   do not renumber existing sections. Wait for accepted A, reconcile exact hashes.
2. Factor the one-artifact normalization/projection kernel behind current RoleRoots
   facade. Preserve existing CLI prefix and all actual registered root tests.
3. Add owned registry/scopes/frames/provenance, declaring-owner payload operation,
   and immutable reuse tests. Keep classifier/continuation/runtime work out.
4. Add the finite checked inspector section and black-box regression matrix,
   including true cutoff/restore behavior and deterministic symbolic recursion.
5. Parent independently reviews scopes/lifetime/error output, validates costs,
   runs final unfiltered gates, then commits/pushes to PR1304 only. Clean owned
   worktrees/caches/processes after parent retrieves source and evidence.

## Concrete preparation and imported-table seam

The new inspector preparation owns the cursor until both the compact/typed prefix
and suffix finish writing. dump.entries.write prepares it before writing ANY
prefix; direct TypedInspect.write does the same. The diagnostic path may prepare
and destroy a checked view to turn missing authority into the existing explicit
internal diagnostic before discovery/output. Do not retain that owner on Session.
These real passes count in inspector costs, never ordinary no-inspector checking.

The finite directory reuses old A tables already printed for app/kind/candidate
modules. If it first reaches a declaring dependency whose nominal table the old A
consumer did not print, emit that ordinary raw table ONCE inside the new section.
Share the existing nominal-inspection predicate, rather than changing the old
prefix or referencing an unprinted table. Normalize origins may retain a compact
input-to-output edge whose source encoded alias DAG and original environment
provide expansion provenance; no expanded effect-path or diamond is synthesized.

Concrete preparation also renders the entire NEW suffix to an owned byte buffer
before any old compact prefix is written. The old prefix is streamed unchanged;
no later cursor query, validation or allocation is needed to append the suffix.
Count that real suffix buffer in peak owned memory; do not buffer the old graph.

The finite inspector may show the normalized IMMEDIATE structural children of a
returned payload head (record fields/extension, function arguments/result, tuple
or nominal arguments). This is one explicit child step, not another nominal
payload boundary or recursive specialization schedule. Print interned field
selectors by TEXT, never session Symbol integer, to preserve jobs determinism.

## Schema endpoint alias identity

A result also retains its original structural-leaf ViewIndex across normalization.
Ordinary role field traversal expands aliases transparently, but payload lookup
normalizes from that retained leaf and stops at a checked schema_endpoint alias.
Its declaring schema-Type/Encoded owner remains explicit contract-unavailable,
not an ordinary record or ADT. Substituting an alias formal restores the actual
view before this check. Directory resolution includes schema-endpoint aliases in
A owner lookup; other aliases retain their canonical source body only. This is
identity retention, not a schema Wire adapter or a new serialized type variant.

Output atomicity here covers new cursor semantic/authority validation failures and
new suffix construction before publication. Old A prefix rendering can still
allocate, and the caller IO writer may fail after receiving bytes; this slice
does not claim atomic IO or all-OOM output for the entire existing inspector.

Scope construction checks its tagged domain BEFORE indexing combined scope slots:
scheme index < schemes.len; alias_formals index < type_refs.len and has a
canonical alias body. An invalid scheme cannot occupy an alias slot or create a
complete result whose term is none. Bound frames must target the exact view scope.

Payload-head identity normalization records an explicit payload_head origin from
the retained leaf, rather than labeling a restored schema alias as ordinary
forward normalization from an already expanded record. Structural child origins
distinguish type arguments, function arguments/result, tuple elements and record
extension/fields directly; they do not rely on an out-of-band child print row to
recover a source effect-path step. This is provenance, never effect certification.
