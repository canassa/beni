# Native realm source graph builder

Normative API proposal, 2026-11-01. Part of #1295 and PR1304. Base combined tree
7de8d098eefc918dd7e358edb54780576f1c9aa6. This refines the source-owned native realm
component; root and the selected-root consumer author review this boundary before
implementation. No new syntax, intrinsic, effect/ownership rule, source cap or
budget. The separate consumer selects execution roots; this builder does not.

## Ownership and exact borrowed input

New helpers: src/check/RealmBuild.zig (graph construction), optionally
src/check/RealmValues.zig (iterative value resolution and field directory), and
registered builder tests in src/check/RealmBuildTest.zig. Each stays below 1500
lines and receives explicit beni.zig/rules_test registration. This lane owns only
those files, their precise registration lines, new builder fixture paths, this
document and its append-only diary. The other author owns selected Plan/root/
deferred demand consumer, RealmInspect and dump/entries integration. Neither lane
changes the other's source without a narrow agreed patch.

RealmBuild.Input borrows, for build duration only:
- graph: *const Graph;
- artifacts: *const Artifacts (current resolved BIR by graph.moduleFile);
- interfaces: []const Interface and provenance: []const Interface.Provenance;
- dispatch: []const Dispatch, whose realm_sources were validated before install;
- native_seeds: []const Realms.NativeSeed, from the completed native registry;
- allocator supplied as build's ordinary argument.

All module-indexed slices must have Graph.count entries. Missing required Source
or malformed indices are evidence errors, not an empty safe graph. Normal
unsupported source is a returned residual. No TypeStore or Effects pointer is
an input. BIR and original Source must belong to this same checked Session.
The builder is downstream of the common semantic install verifier; it does not
substitute another typecheck or parse a diagnostic string as authority.

External VALUE refs use current module identity plus Interface.ValueIndex. Resolve
the index with that module's current Interface.Provenance.valueDecl, checking
ordinary Interface bounds and the resulting actual declaration. Do not use value
index as declaration index or resolve by spelling. Top references use their
original declaration index. For locals, add the owning declaration's locals_start
to the declaration-relative index, then use the retained actual local definition.
Ctor/schema/type namespaces are never treated as value indices.

NativeSeed is exactly { target: QualifiedDecl, allowed: u8, binding_digest: [32]u8 }.
Only the completed Phase1 registry supplies production rows, including status
awaiting_realm (this is provenance, not prior execution discharge). Validate mask,
unique target and actual foreign callable scope; do not recover seeds from names,
core package, isEmbedded, matching types, rung, or serialized alleged attestation.
Production builder imports no Bindings module: its caller owns that downward seam.
Private unit tests append Realms.Seed{origin=private_test} to the actual built
source graph before solving, under the existing builtin.is_test kernel fence.
Production Input has no private seed provider or source/CLI privilege.

## Owned output and typed indices

Realms.ExecId/PortId/ScopeId/SiteId and QualifiedDecl remain the shared types.
RealmBuild.Output owns:
- modules: dense ModuleRange entries giving scope/port/declaration ranges;
- scopes: original Source scope identity -> ExecId and body/result PortId;
- declarations: dense original declaration -> value PortId and optional initializer
  ExecId (separate from the function ExecId stored in that value);
- ports: original instruction/declaration identity and resolved Origin;
- calls: original SiteId, ambient ExecId, callee PortId/optional resolved ExecId,
  result PortId, and direct/residual classification;
- execs/sites/edges/seeds in the existing Realms.Input SoA layout;
- residuals: original site/source/reason/optional referenced PortId;
- native_values: exact QualifiedDecl/digest/ExecId rows, independently of whether
  any call demands their execution;
- Work counters for original scopes/ports/fields/dependencies, memo visits,
  field-directory steps, calls/edges and residual rows.

Output.deinit releases every owned table. No borrowed Source/BIR/Interface slice,
raw Var, pointer to a growable table element, or scratch reference escapes build.
Lookup APIs declaration(QualifiedDecl), instruction(module, inst), scope(module,
Source.ScopeId), origin(PortId), initializer(QualifiedDecl), and input() return
indices/value copies or const views valid only while Output lives. Consumers must
reacquire views after construction; Output is immutable once returned.

Origin is a tagged result: scalar, callable(ExecId), record(aggregate PortId),
tuple(aggregate PortId), or residual(reason, witness PortId). Scalar does not mean portable,
owning or host-free. Pattern/annotation/scaffold metadata has no callable origin.
Each original instruction gets at most one port, each original declaration at
most one extra declaration-value port. Local/capture/result aliases refer to those
existing ports; they do not create per-use environments. Each Source scope gets
one ExecId, including initializer and foreign scopes.

### Consumer accessor and use-row handshake

The shared accessor spellings are scopeExec(module, Source.ScopeId),
callableAt(QualifiedDecl), callableAtInstruction(module, Bir.Inst.Index),
initializerOf(QualifiedDecl), and instructionScope(module, Bir.Inst.Index).
They return typed IDs/optional IDs or evidence errors; callableAt returns no
callable for a scalar or residual origin rather than inventing a function body.
The consumer can inspect the original PortId and residual when resolution fails.
A root site with instruction=none refers to its declaration VALUE origin; callback
or runtime roots call callableAt, never blindly invoke an initializer. Evaluated
roots instead use initializerOf or a validated exact original execution scope.

ValueUse is a fixed row { kind: invocation | retention | escape, source: Source,
scope: ScopeId, site: SiteId = none, call: CallId = none, port: PortId,
native_exec: ExecId = none }. A pure retention read has source/scope and no
artificial call/residual SiteId. Invocation/escape rows link their actual CallId,
whose classification is direct or residual. Blocked known calls remain residual;
callee identity alone cannot authorize positive invocation discharge. Exact known native origins retain the
registry identity/digest through native_values. Retention means original source
value flow, not current reachability or invocation. The builder records original
call operand/return/use relations once; the consumer selects the relevant rows.
Without an exact source formal-use/substitution contract, every original
non-scalar call argument retains an escape obligation, even for a known source
callee. This classification must not depend on partially constructed target
coverage or declaration/module order. Scalar literal arguments have no callable
obligation; a formal Unit value still has an explicit residual value origin in
this initial untyped-origin component. No signature-derived authority is guessed.
An unknown argument/callback or opaque aggregate escape retains its original port
and explicit residual, not a fabricated native target. Do not enumerate every
transitive native inside every aggregate/closure or multiply uses by selected roots.
A missing target cannot make such an escape safe.

Consumer CompactGraph.live_nodes is conservative code retention, not evidence that
a function body ran. The consumer uses actual execution scopes and validated Plan
roots separately, plus evaluated initializer inventory. Open library roots/unknown
callback escapes stay unresolved even if a native facade is retained. This output
does not request or authorize any code-generation gate.

## Finite value-resolution rules

Declaration with explicit parameters yields its own function ExecId. Declaration
without parameters forwards its value to its actual body port but retains its
separate initializer ExecId. Lambda and parameterized let_def yield their own
source scope's ExecId. A zero-parameter let_def forwards to its RHS. A plain let
expression forwards to its final body, while all statement/initializer effects
remain inventoried in their actual lexical ambient.

Local/top/imported reads forward through exact source definitions. Formal
parameters and pattern destructuring not implemented by this domain yield explicit
formal/pattern residuals. A captured known static/local binding follows that same
source definition; a captured formal remains residual. No actual-argument
substitution or environment specialization is performed.

A uniquely resolved callable call result forwards to that ExecId's original body
result port. This supports a known returned lambda or static function, including
static captures. A result depending on formal substitution remains residual even
when this particular caller supplies a simple actual. No type-signature equality
makes a returned function known. A foreign/native call result is opaque unless
there is an independently specified value contract; this constructor-only seed
has none and its result does not become another callable.

Closed record/tuple literals retain field/element port references. Reading one
field resolves only that selected value origin, not sibling callable bodies.
Strict calls inside all field initializers still belong to their original ambient.
Record update/extension and opaque nominal projection remain explicit residuals.
Method/type-dispatch/bare-field method invocation can use a unique actual resolved
Source.Ref.top/external target; a true field call resolves its receiver's closed
field then that callable. Unresolved ordinary evidence remains residual. A bare
field with Source.isCall=true is invocation, never a pure field read.

Resolution is iterative and memoized by PortId with unseen/visiting/finished
states. Each forwarding edge is visited once; call-result resolution first resolves
callee and then exactly one result port; projection first resolves aggregate then
exactly one selected field. Value-origin cycles yield a residual with an original
witness, never all-realms. Known function execution recursion is a separate finite
solver edge cycle and remains supported.

## Field directory and bound

Construct one immutable closed-record field directory per original literal from
current BIR.Field name/value pairs, validated against Source child inventory.
Use global interned u32 symbol identities, not spelling comparisons. A compact
binary radix trie stores at most two nodes per field plus one root per record;
branch bit positions strictly increase and are bounded by the existing 32-bit
symbol width. Insertion and lookup visit at most 32 branch positions (lookup additionally
reads one leaf). Counters distinguish field queries: total directory steps are
bounded by 64 per insertion plus 33 per lookup. A duplicate
key or mismatch to the clean ordinary source is an evidence error. No per-query
whole-record scan, environment product, arbitrary hash-table performance assumption,
per-role graph clone or per-root residual closure is allowed. Tuple lookup indexes
its original flat element range. All trie nodes and counters remain owned/freed.

Thus construction and origin resolution use O(M+V+E+P) storage/work for actual
module, original scope/instruction/declaration/field/path edges and binding rows;
32 is the existing identifier width, not a source cap or new compiler budget.
Record observable actual row/visit counts in tests; do not assert performance from
this proof alone. If concrete implementation needs repeated unresolved projections
or result contexts, fix the algorithm before claiming this bound.

## Execution coverage and deferred values

For each actual original call with uniquely known callee, add one callee->ambient
edge with its original site. Reading/storing/returning a function adds no call edge.
Keep strict operand calls even when an argument/result is unused. Calls under a
nested function belong only to that nested ExecId; constructing a closure does not
execute its body. Top-level initializer execution is exposed to the selected-root
consumer as a separate root inventory, not falsely attributed to each value read.

An unresolved value alone does not poison unrelated execution: e.g. a function
returning an unused formal can have known execution while its result origin is
residual. An unresolved CALLEE, raw foreign operation, unsupported control/implicit
operation, or missing execution semantics makes the affected execution incomplete
with a precise source witness. Blocked calls under case/try/markup retain their original call and witness but
are residual-classified even if their callee origin resolves. They cannot receive
a positive native-invocation discharge or be described as definitely executed.
Case/try/markup remain residual in this initial
execution domain even if some nested calls are statically identifiable; do not
certify skipped alternatives as unconditional execution.

Use .source coverage only for an execution with no local uncovered operation;
.unavailable plus its first deterministic residual site otherwise. Keep all original
local residual rows once for inspection, not a root-times-residual matrix. Attested
foreign callable scopes use .native_required with their actual seed; arbitrary
foreign scopes are unavailable. The native value row survives deferred reads even
if no call currently invokes it. The consumer separately reports retained-deferred
obligations versus demanded execution/realm discharge, and open-library/unknown
escape obligations remain unresolved. Neither builder nor consumer may interpret
an all-five-bit initial mask as complete without coverage.

The existing Realms.solve receives immutable output rows. This builder does not
select Plan roots, choose realms, grant sibling exemption, emit a facade, switch a
public worker gate, or declare C/EntryHost/Wire/HostFree/ownership/launch complete.

## Required registered tests before handoff

Use actual ordinary checked Beni source and the real frozen Source observer, not
hand-built positive graphs alone. Verify exact source identities and independent
same-signature functions using private disjoint-mask seeds; local/import aliases;
known function returned then called vs merely returned; static captured binding vs
formal capture; initializer calls vs unused deferred bodies; closed good field vs
bad sibling; strict field/argument effects; actual method/field distinction;
recursive execution vs cyclic value origins; unknown callback and opaque projection
residuals. Import ValueIndex must differ from declaration index in a fixture.

Add source-family counters for many aliases/shared results/large closed records and
many selected fields showing fixed-per-original-row work, no repeated field scans.
Test allocation-failure cleanup and immutable result lifetime after growth. Exact
native registry seeds need an integration fixture, and unknown/same-spelling/physical
override foreigns must not obtain a seed. The consumer author adds selected Plan,
root-demand and deferred-output tests separately. No builds while parent gates run;
focused Debug tests require the coordinated slot, no full gates or timing here.
