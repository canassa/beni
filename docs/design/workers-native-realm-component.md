# Source-owned native realm component: Phase 2

Normative implementation proposal, 2026-11-01, baseline frozen emitter/C tree
be99c406745374979db981d3a6efc6f9452136ec on accepted07cd. Root reviews this
concrete boundary before broad checker hooks. Refines workers.md §4 and the
separately owned workers-native-callable-constructor.md. No new source syntax,
ownership-v2 implementation, trusted cast, realm restriction, source cap, compiler
budget or public worker gate is introduced.

## Initial proof domain and nonclaims

Implement actual checked-source direct/static callable identity, source/global/
local aliases, known returned functions, closed record/tuple selected fields,
evaluated initializers, and deferred known lambda/function bodies. Source actuals
that require formal/generic callback substitution, opaque nominal callback
projection, dynamic alternatives, method/evidence invocation not resolved by the
ordinary dispatcher, or recursive value-origin equations not resolved by this
initial domain retain explicit residuals. Ordinary source acceptance is unchanged.
No residual becomes all-realms; no incomplete entry is certified.

Execution recursion among known functions is supported by the finite five-bit
solver. Recursive returned-value origin equations are a different problem and
remain residual until implemented. Do not treat an owner revisitation as safe.
Known returned lambdas may capture known static/local aliases; a captured formal
callback remains a scoped obligation, even when a later caller appears simple.
The initial implementation does not enumerate closure environments or specialize
source functions per actual-argument tuple.

The result distinguishes violated, unresolved and complete within the inspected
execution inventory. It also lists discharged native binding obligations. Existing
raw-host primitives not covered by an explicit checked contract remain residual.
A proved TextEncoder operation does not certify the rest of its entry, C,
EntryHost, HostFree, Wire, storage, move/loan ownership or launch. No public realm
gate or production Task representation is switched by this foundation.

## Independent identities and storage

`check/Realms.zig` is the owned finite mask/residual solver. `check/RealmSource.zig`
owns recording/frozen source event data; a separate bounded builder/inspector may
be split as needed. Every new check helper is registered in rules_test and the
hermetic root, and stays below1500lines. All persistent rows use fixed-size SoA
records and flat owned ranges. Typed IDs have an explicit none sentinel.

- ScopeId: one original module declaration, with lexical function/let nesting
  anchored by actual BIR source instructions, not binder names.
- ExecId: execution of a top-level initializer OR an original function/lambda/let
  body. The evaluation of a function value is separate from calling its body.
- PortId: the value at an original expression/binding/formal/result/capture or
  exact record/tuple field. A known function value points at its source ExecId.
- SiteId: one actual source call/read/projection/copy event, retaining declaration,
  BIR instruction and lexical scope. Repeated constraint visits do not add a
  second source event. Dense per-instruction columns/epochs provide indexing.
- QualifiedDecl: module + original declaration index after ordinary resolution;
  serialized external references use stable module/package identity, rebound on
  install, never previous Graph ordinals.

ExecId/PortId are never TypeStore.find/resolved, Effects.node, rung,
Dispatch.Suspend, Interface.TermIndex or nominal-holder class. Ordinary type/effect
variables can be borrowed temporary anchors during recording and final validation,
but never create realm equality and never escape Module's owner. In particular
Unify.flat function merging and Effects.constructor's holder join are not copied
into this graph. Matching function signatures grant no identity relationship.

## Recorder APIs and actual hooks

Recorder.init(module,bir,allocator) reserves declaration/expression ID columns once.
It borrows the module's BIR and temporary ordinary store only until freeze. API
names below are proposed exact responsibilities, not existing functions:

- declaration(decl,body,params,ordinaryRoot) at constrain/Decl.declBody reserves a
  top-level ExecId: initializer for no parameters, function execution otherwise.
  Its result PortId points at the actual body value; a top-level function value
  has a separate source declaration port pointing at its function ExecId.
- function(decl,inst,body,params,ordinaryArrow) at constrain/Expr lambda creation
  and Decl.defineBinding let_def creation reserves a lexical function execution
  and original value/result/formal ports BEFORE unification can merge arrows.
- expression(decl,inst,ordinaryExpected) records original source value syntax at
  Expr.expr entry. On repeated visits verify same source identity and keep one
  row; it is not a per-solver-context flow graph. Capture original top/local
  references, aliases, literal record/tuple construction and selected field paths.
- call(decl,inst,ambientDeclOrFunction,actualCalleeInst,argumentInsts,resultPort)
  records actual invocation at the existing Tree.called/source call generation
  seam. Ambient comes from original declaration and ambient_site, not a type
  class. Do not count a deferred field-read reservation as a call. Reconcile
  method/evidence targets after P6 using actual Dispatch callee provenance; if
  the domain cannot represent the call, record an explicit residual at that site.
  Dot.arrow activates a reserved bare-field method edge: observe its ORIGINAL
  Effects.Site call/ambient there, after activation (never its effect-class
  representative). Every Source.isCall requires a matching real observation at
  freeze, including unsupported calls; missing observer wiring is an internal
  evidence error, not silently covered lexical metadata.
- copy(owner,site,originalScheme,originalToCopyPairs) at Instantiate.copy before
  TypeStore.copy memo clears observes the source use/copy event. Initial capture
  counts observations only; it does not retain or certify substitution pairs.
  Known binding identity comes from the actual source read/definition event. It does NOT join
  realm variables by those type pairs. Known value forwarding comes from actual
  source read/definition identity. The initial formal/generic mapping event remains
  an obligation until its source port substitution is implemented, not a guessed
  effect-class transfer. Imported reads record their actual resolved declaration.
- freeze(input) after final P6/P8/P9 success verifies original instruction/decl/
  scope ownership, ordinary function anchors and final dispatch targets, producing
  an owned Source artifact. No live Store Vars are retained. A module/ dependency
  error publishes absent, not partial valid rows. Free temporary borrowed mappings
  before the module store/effects defers run.

Constrain hooks do not change constraints, unification, effect inference,
generalization, demand checks, ownership or ordinary publication. `Context` gains
an optional Recorder pointer, analogous to existing Effects; null in callers that
request no native realm evidence. The recorder is an observer, not a second type
checker. An expression's semantic callable relationship comes from typed source
value flow, never equality of expected type roots.

## Finite origin resolution and execution graph construction

Known-value ports form source-finite expressions: known function, source reference,
alias, closed record/tuple, field selection, call result, or explicit residual.
Resolve source references by original declarations/local definitions. A call-result
port may forward to the known callee's original result port ONLY without formal/
capture substitution. If that result depends on unresolved formals, retain the
obligation; never infer an actual result merely from its function type.

Use an iterative memoized graph walk with visiting/finished states for unary
forwarding and call-result dependencies. Every original port/dependency is visited
once. A value-origin cycle yields a residual, not a positive portable result.
Closed literal record fields use an indexed source field directory. Resolve field
queries by bounded integer radix ordering and a merge against the original field
rows (or an equally proven linear representation), not a per-query scan of every
field or a dense-ID hash map. Tuple positions index flat original ranges. Unknown
extensions/opaque projections remain residual in this initial domain.

For each source call with a uniquely known callable port, add its callee execution
constraint to the original ambient execution node. Reading/storing/returning a
function adds value flow but no execution edge. Argument and record initializer
calls remain in their actual ambient, so strict operand effects execute regardless
of whether the result is used. Nested lambda body calls stay on that lambda's
ExecId; mere closure creation does not run them. Never union sibling callable
fields solely because their nominal/effect holder class joined them.

The graph is fixed before solving. Native seeds enter only from the completed
Phase1 immutable registry: NativeSeed{QualifiedDecl,stableBindingDigest,allowed},
currently TextEncoder mask0x1f, never matched by source spelling/type/rung.
Attestation pending or missing is an unresolved native obligation. A compiler-
private test seed provider can seed actual checked fixture declarations with
narrower masks; it has no CLI/JSON/source privilege and changes no production row.

Every ExecId starts with five candidate bits, but this initialization is NOT proof:
it also has coverage/residual state. A source function with all statements/calls
covered and no unknown/native residual may finish complete. An unvisited/missing
source body, external function or unsupported call cannot become complete just
because no bit was removed. Each explicit seed intersects its execution mask.
Along an actual callee→caller edge, remove every unavailable callee bit from the
caller. Source residual propagation uses a separate fixed obligation-presence bit
and retained original witness IDs; do not materialize a root-times-all-residuals
matrix. Deterministic source/type paths are retained for explanations; the final
public worker realm diagnostic's shortest call-chain guarantee remains required
when that diagnostic is activated.

Each of five bits and the incomplete bit transitions at most once per node, each
original edge is inspected only for those fixed transitions. Storage/work is
O(V+E+P): original execution/value/event/field/path rows and explicit bindings,
not generated environment products or a transitive formal-dependency closure.
Existing ordinary instantiation work is recorded/charged once, not multiplied by
all schemes or all source instructions. If the concrete origin resolver cannot
meet this bound, fix/specify it before implementation; no cap or budget waiver.

## Owned cache/lifetime and integration contract

Source schema1 is recorded data, not a solved realm certificate. Store it as an
owned private `Dispatch.realm_sources` artifact, released by Dispatch.deinit and
Module.clearEntryEvidence/error restoration. Phase1 author explicitly handed
Dispatch and dispatch_bytes to Phase2 (no Phase1 edits planned there). Append one
final RealmSource column, private dispatch19→20, Source schema1; public ordinary
Interface18 is unchanged in this foundation. An absent column payload is absent
evidence; a schema1 captured record carries the complete source inventory. Update
all affected private-version/relative-column test locators intentionally. No broad
hooks until root approves these responsibilities and the small record API.

Concrete request: Session.Options.native_realms=false by default. Existing
hidden --entries/dump-stage=entries enables it; no new CLI flag is added. Session
passes Check.Options.realm_required_modules, empty when disabled and otherwise
Graph.count booleans covering every checked module in this query. Driver passes
Module.Input.realm_required and rejects a missing required Source record through
the existing cache-admission miss. GeneratedUnit child Sessions keep native_realms
false/empty requests; no foreign graph bitmap is inherited.

Evidence is demand-driven under that explicit query/request. Required modules with absent/malformed source artifacts use ordinary
cache miss/source capture. A subsequent warm query reuses semantically validated
persisted source records without rechecking; normal non-query paths may accept
absent but never label it complete. Request lengths are validated against current
Graph.count before indexing. The initial request includes the inspected source
execution inventory and required native module; no selected source silently drops
out because an artifact is absent.

The artifact carries complete declaration/site inventory plus per-site covered or
residual status. Common install verifies exact BIR scope/definition/reference/
call/projection relationships and complete unique source inventory before publishing
rows; a well-shaped cached “unsupported” downgrade cannot skip required calls.
Use the same verifier on fresh/roundtrip/disk/pack installation, before wholesale
publication. Stable native keys and current supplier origin are re-attested by
Phase1. Private source body changes regenerate this module's source record even
when its public ordinary scheme is unchanged; this pass consumes current per-module
records, not a stale cached whole-entry proof. Future exported realm summaries
need explicit Interface/digest publication and are not claimed by this private
source-record foundation.

The actual selected-root consumer takes const per-module Source artifacts,
completed native seeds, validated Plan selected kind/runtime and ordinary entry
reachability inventory. It resolves actual selected entry/runtime execution and
evaluated initializer roots; deferred callable bodies become demanded only through
actual calls/explicit deferred execution roots, never module-import presence alone.
Integrate entry/RealmInspect.prepare into dump/entries alongside the existing
TypedInspect preflight, before writing the old compact prefix. Append its
pre-rendered native-realm section AFTER the existing A/B typed sections; preserve
those prefixes and all ordinary build output. The input includes completed
registry seeds through a const downward view, not a Bindings dependency inside
the solver. A legacy platform without a validated Plan selected kind reports
selection_missing and no complete entry; do not guess realm from platform name.
Semantic missing/corrupt required evidence is reported through existing Emit.Item
structured diagnostic handling before positive output; unsupported source flow is
a residual, not a user error. Existing output remains byte-identical. Missing
or raw-host coverage yields entryComplete=false and explicit residual witnesses;
individual native obligations can be discharged without certifying the whole entry.

## Required first acceptance tests and file boundary

Use registered actual ordinary typed source plus private narrow test seeds:
identical-signature impure functions with disjoint realm masks stay independent;
known local/import aliases; return known function then call it vs merely return;
evaluated initializer vs unused deferred callback; closed record good/bad field
selection does not inherit its sibling mask; mutual execution recursion terminates
with correct restrictions. Formal/captured-generic/opaque/projection/value-cycle
cases remain visibly unresolved. Actual selected Plan roots must exercise producer
and consumer, not only a hand-constructed solver graph or exit0.

Also test required missing/corrupt/coverage-downgraded cache source records,
error→repair reuse, cold/warm/jobs1/8/roundtrip/relocation and unbound/cross-scope IDs.
Tests retain actual source function/call IDs, ordinary anchor checks, native seed
read counters and residual counts. Parent grants build/test slots after norm/API
review; Debug Zig only, no LLVM/timing, no public gate. Root runs final integrated
full gates/costs after independent review. All allocation/error paths release their
owned rows and publish no stale source/certificate.

Phase2 owns new Realms/RealmSource/builder/inspector helpers; Context, Module,
constrain, Dot reserved-call activation and Instantiate observer hooks; dump/entries and existing check/dump
query request wiring; their explicit rules/test registrations
and focused tests. Phase1 owns Bindings/Generate/SourceStore/Session/Interface/cache
and its Driver acceptance predicate. Phase2 owns Dispatch/dispatch_bytes and its
new source verifier; Driver admission/request and Check.Options additions are
coordinated narrow deltas, preserving Phase1 native_sources/acceptsCached changes
when merged. Session request wiring is handed to Phase1, not edited concurrently.
Coordinate all such deltas explicitly before edits. No native author's
worktree, manager/cost source or parallel v2 code is modified by this lane.

### Schema1 external syntax normalization

All raw module-bearing BIR tags have Node.lhs canonicalized to zero:
ext_value,ext_ctor,ext_schema_member,ext_schema_ctor,ext_type,ext_schema_type,
ext_schema_target. Only supported external VALUE references and actual dispatched
value callees carry Ref.external, rewritten through module_refs. The other
namespace tags remain explicitly unsupported for initial value-origin resolution;
RHS stays in its original ctor/schema/type namespace, never Interface.ValueIndex.
Pattern/annotation nodes remain in complete inventory with their explicit role;
this normalization does not grant execution/callable identity. The common lexical
scanner performs exactly the same normalization before semantic comparison.
Source.extra contains instruction IDs only; symbols are re-interned by the codec.

### Ordinary intrinsic literal observations (source foundation correction)

The original checker intentionally does not give an expected `Var` to the
string/list arguments written in place by core `Js` intrinsics, nor to the
list/pair/key scaffolding of `Js.object` (§30 of checker-v2). Their source
instructions remain in the inventory. A separate observation records their
original declaration, ambient, instruction, and exact literal role at the
existing `inPlaceLiteral`/`objectFields` hook; it never invents a type variable.

The source scan and common admission verifier receive an optional downward
`IntrinsicContext` containing the current Graph, interner, and checked ordinary
Interfaces. They independently derive literal roles only for direct original
`ext_value` callees whose CURRENT package is core, module is Js, and checked
Interface value name identifies the intrinsic, and only its declared in-place
argument positions. The object shape is a list of two-element tuple fields with
string keys; ordinary object validity diagnostics retain their current authority.
The scanner retains all original children: list elements and object VALUES are
ordinary expression observations, including their actual calls. Host operations
remain explicit unresolved realm operations; a special literal role is not an
execution or transport certificate. Missing context derives no special roles,
so a cached special role cannot be admitted without this current authority.

The source schema remains unreleased schema 1, extending its Role discriminator;
public Interface 18 and private Dispatch 20 stay unchanged. Construction and
verification use one dense original-instruction role array, one original call/
argument/field traversal, with no generated instances or quadratic duplicate-key
rescan. Fresh captures require matching actual special observations; cache
admission recomputes the same roles and the entire lexical inventory. Changes of
package, callable value identity, argument position, or literal shape therefore
invalidate a forged role rather than hiding an expression from coverage.

Interpolation's literal `.chunk` parts likewise name no separate type: the
ordinary `.interp` hook records `interpolation_chunk` for precisely those parts.
The scan derives this role from the original interpolation operand edge even
without intrinsic context. Non-chunk interpolation values retain actual ordinary
expression observations and calls. A standalone `.chunk` is not exempted.

The hidden source foundation section prints `realm-literal` rows for every
non-Var literal role with its actual original module/instruction/declaration/
lexical scope. These rows report the validated source observation distinction;
they do not label any raw host operation complete or assign it a realm mask.

### Composition with the accepted bound-result C refinement

The independently reviewed ControlSourcePlan schema2 refinement intentionally
advances the outer private Dispatch to21 while preserving the final RealmSource
schema1 column and public Interface18. Source role/context admission remains
unchanged. Native supplier attestation is the FIRST common cache predicate before
realm source coverage and install; source evidence cannot replace it. Final
execution consumer and native lowering remain incomplete after this composition.
