# Selected source execution and native obligation consumer

Normative implementation proposal, 2026-11-01. Baseline combined source tree
7de8d098eefc918dd7e358edb54780576f1c9aa6. Refines workers.md §4, the source-owned
realm component, and workers-native-realm-builder.md. Root reviews this exact
boundary before broad consumer code. No new language/type/effect/ownership rule,
privilege, compiler budget, source cap, native lowering or public worker gate.

## Parallel boundary and ownership

The builder author owns check/RealmBuild.zig, optional RealmValues.zig,
RealmBuildTest.zig, their exact beni/rules registration lines and builder fixtures.
Its immutable owned Output resolves original source value origins, execution
edges, native value identities and residuals, independently of Plan/root choice.
The selected consumer owns entry/RealmConsume.zig, RealmInspect.zig,
dump/entries.zig, the selected-source field/reset in entry/CompactGraph.zig,
necessary request/entry wiring, consumer-only tests/fixtures and this document.
Any new check helper stays below1500lines with both explicit registries; consumer
helpers also stay below1500. No overlapping helper, build or registration edits
without a narrow coordinated patch. No duplicate ownership-v2 work.

The completed source lane remains frozen. New builder/consumer lanes start from
exact7de. Parent will independently compose/review before final full gates/costs.
No builds during parent full gates; later focused Debug builds require a slot.

## Immutable downward APIs and lifetime

RealmBuild.Input borrows current Graph, Artifacts/BIR, checked Interfaces and their
Provenance, checked Dispatch.realm_sources, and []const Realms.NativeSeed only
for build duration. Module-indexed slices have Graph.count entries; source/module/
scope/instruction/declaration identities must be current and bounds checked.
No TypeStore, Effects, root-rung or signature-equivalence identity is available.

Builder Output owns dense per-module scope/port/declaration ranges, exact original
value origins, Realms exec/site/edge/seed tables, all local source residuals,
original invocation rows and native callable identities/digests. It exposes:

- scopeExec(module, Source.ScopeId): optional ExecId;
- callableAt(QualifiedDecl): optional callable ExecId from the declaration VALUE;
- callableAtInstruction(module, Bir.Inst.Index): optional callable ExecId from the
  exact original instruction value;
- initializerOf(QualifiedDecl): optional initializer ExecId;
- instructionScope(module, Bir.Inst.Index): original global ScopeId when present;
- declaration/instruction/origin lookup and input(): immutable Realms.Input view.

A callback/runtime source site invokes its callable VALUE origin. A zero-parameter
alias declaration is not treated as its initializer's function body. Initializer
roots use initializerOf, and no unknown site is repaired by name/type matching.
Original source references resolve imported Interface.ValueIndex through CURRENT
Provenance.valueDecl, never by equating that index with BIR declaration.

ValueUse rows retain original SiteId/PortId, invocation|retention|escape kind and
optional native ExecId. Invocation rows link the actual CallId/classification so
blocked/unsupported syntax cannot become a definite execution discharge. Unknown
aggregate/callback escape remains its original port plus residual: no transitive
native identity sets, environment products or root-times-native matrix.

RealmConsume.Input borrows { graph:*const Graph, plan:*const Plan,
entries:*const CompactGraph, selected:?Realms.QualifiedDecl, library:bool }.
consume(gpa,input,built:*const RealmBuild.Output) returns an owned Result with
roots, demanded-exec and retained-declaration bits, Realms.Result facts/witnesses,
per-native aggregate obligation rows and explicit Work counters. Result.deinit
releases all owned buffers. No pointer into Input, a growable row or scratch escapes.
No result is installed as a reusable whole-entry proof or persisted to cache.

The builder Output and Result are local to one prepare call and destroyed after
rendering the owned Prepared.bytes. No semantic lookup API is used after Session
artifacts are replaced. A subsequent Session.run/error repair rebuilds from the
current checked store; there is no stale graph cache or secret reconstruction.
Owned printed bytes may outlive their source as historical output, never as a
fresh callable/emission certificate.

## Exact current selection authority

A source-site helper chooses callableAt(QualifiedDecl) when instruction is none,
otherwise callableAtInstruction on the exact original instruction. It never guesses
an alternative path. instructionScope is a scope witness, not callable identity.

Emit.inspectEntry already validates the complete ordinary entry contract and
finds the actual selected top source declaration. dump/entries retains that exact
module/declaration in CompactGraph.selected_source (an optional Ir.Site with
instruction none). CompactGraph.reset clears it alongside all prior checked-store
indices. A separate realm_request enum unprepared|selected|selection_missing|
open_library records the actual inspection request, reset to unprepared. Direct
write cannot treat an unprepared/failed inspection as a successful missing selection;
it rejects it before a prefix. Successful library/no-selection preflight records
that explicit state. No library mode is guessed from source or a nullable root. No selected source is recovered from an entry name, constructor alias,
Graph order, nominal type or a callback's matching signature.

entries.inspect runs ordinary Emit inspection and typed preflight, then existing
CompactDiscover when Plan is validated/selected. Only after discovery and new
realm preflight succeed does it publish selected_source. Any semantic failure
leaves it absent. Legacy/no selected-kind/library paths remain explicit partial
states, with no guessed node realm. entries.write uses only that current stored
source plus current Plan and graph; it never reruns a source search by spelling.

Current Plan.validated and selected bounds are checked before reading exactly its
Kind. The selected runtime comes from Plan.runtime() and retains its actual
QualifiedDecl and ordinary scheme authority. The ordinary entry row must be unique
and its kind agree with Plan.selected; inconsistent installed identities are
internal evidence errors before positive output. Normal absence/incomplete static
entry discovery is an unresolved state, not a new source rejection.

Report counters for selected-source reads, selected-kind reads, selected-runtime
reads, ordinary-entry rows, registry/native-seed rows and seeded kernel reads.
Tests assert nonzero real authoritative reads; exit0 alone is not acceptance.

## Retained code and demanded execution are separate

One selected ordinary entry is consumed. Other discovered entry kinds/launch
relationships are not silently executed in its realm. Root rows retain exact
original source and reason:

1. The actual selected top declaration's initializer executes while constructing
   its value. An unsupported non-initializer shape is explicit unresolved.
2. The validated selected runtime callable body is an execution root. A value alias
   is resolved through callableAt, not through its initializer identity.
3. CompactGraph.scopes for the unique ordinary entry retain exact source witnesses.
   Metadata-backed callback/runtime roots resolve the actual callable value.
   Derived callable/evaluated/initializer scope rows alone do not bypass builder
   call classification: absent a matching exact direct evaluation authority they
   are POSSIBLE roots. The definite builder edges already cover admitted strict
   calls from definite roots. A missing mapping remains a source-root residual,
   never an assumed safe node.
4. CompactGraph.live_nodes for that same entry is conservative CODE retention.
   It marks retained original declarations. A retained zero-parameter initializer
   without an additional exact existing load/evaluation witness is a POSSIBLE root,
   not definitely executed. It cannot grant invoked_checked or upgrade entry
   certainty. Retained function/foreign bodies likewise are never definitely
   executed merely because code is live. Unsupported derived/schema/twin/lift
   execution authority remains partial; no descriptor cut or exact-code/load claim
   is inferred from declaration liveness.

Strict argument/field initializer calls remain builder edges in their actual
ambient. Creating/returning/storing a lambda does not demand its body. Demand is
an iterative walk from these roots along only the builder's admitted direct
execution/evaluation edges. Definite and possible demand each have one dense bit
per original ExecId, at most two visits per node/edge; a possible path never
upgrades definite invocation. A possible initializer remains explicitly partial
until an actual existing emission/load witness is implemented.
Calls under case/try/markup remain residual/possible calls: they cannot discharge
an unconditionally invoked native operation merely because its name is known.
Source execution recursion is a finite graph cycle; origin cycles/formal/generic/
opaque projections and unknown callback substitutions retain explicit residuals.
No substitution is inferred from Plan types, rung equality or a known actual alone.

The existing Compact discovery_complete remains false. This consumer does not
upgrade it. Even complete facts for every explicitly represented root do not
certify complete worker discovery, construction effects, C, transport, ownership,
launch, continuation runtime or the whole selected entry.

## Actual native seed adapter and obligation states

The outer entry facade reads only completed Phase1 Registry Installed rows.
For the one existing indexed TextEncoder row it takes target module and
checked.declaration, allowed candidate.realm_mask and SHA256 of the existing
versioned native Source.provenance domain (which includes recipe/signature/effect/
realm/expected-error/IDL/source row authority). The installed ordinary nominal,
scheme/effect and winning source-supplier attestation remain Phase1's authority.
No named source declaration, isEmbedded/core_root flag, cached alleged origin,
matching type/rung, empty seed list or arbitrary public test mask supplies a seed.
The fixed one-row adapter follows the existing indexed closed Origin registry,
not a source cap. New recipes must extend that decided registry API explicitly.

The builder validates target/mask/unique foreign callable identity and copies
QualifiedDecl/digest into native value and kernel seed rows. Missing attestation
means unavailable/incomplete. Initial all-five-bit masks are not evidence. Solve
all original execution nodes once with Realms.solve; use its actual facts and
original-edge witnesses without deleting dependency rows.

Per-native reporting accumulates original selected retained/demanded ValueUse
rows by dense native execution index, not root-by-native products:

- unused: no selected retained value or admitted invocation;
- deferred_retained: exact attested callable value is retained, with its original
  port/source/digest and retained realm obligation; no body execution is claimed;
- invoked_checked: an admitted original invocation in demanded execution names
  that exact native ExecId, with valid selected Plan realm and complete native
  fact including that bit;
- unresolved: unknown invocation/escape, unsupported/blocked call classification,
  missing selection/seed/identity or unavailable native contract prevents that
  particular discharge. Keep separate checked/possible/unresolved invocation,
  retention and escape counts. ANY relevant unresolved invocation or escape
  dominates aggregate status even if another use was checked; aggregation is
  order-independent. Print individual checked use facts separately instead of
  hiding a mixed unknown use behind invoked_checked. Retained unknown aggregate escapes remain explicit port
  residuals, with useCoverage=partial; no per-native identity is invented for them.

Deferred_retained does not certify unknown escapes and is NOT final lowerability.
This stage always reports nativeLowering=false. The later production adapter
consumer must require its own complete applicable-use coverage; no final emission
permission is granted by these hidden states. Native callable identity, operation
availability, selected execution reachability and whole-entry completeness remain
separate facts. A native call-result foreign object does not acquire a callable
origin or a hidden shape graph through Js.Value.

## Proof states, output and errors

For each represented root print actual allowed mask/incomplete/seed witness,
selected realm when present, and covered|violated|unresolved state. Root rows
also state definite or possible; possible roots remain unresolved and cannot claim
an execution violation/discharge solely from conservative retention. A known missing
selected bit is a valid represented-root violation even if other evidence remains
unresolved; unresolved cannot become covered from an unchanged full mask.
The selected summary is missing_selection, unresolved or violated while global
entry/discovery coverage is partial. EntryComplete and public realm proof stay
false. Hidden inspection is not the future worker_realm_violation diagnostic;
that public diagnostic retains its separately decided shortest inferred-chain
obligation. Hidden witnesses are deterministic valid original source/edge paths.

Keep the entire existing compact/ordinary typed/cursor/source-record prefix.
Append native-realm-execution schema1 with exact input/work/root/native/residual
rows after the source-record section. Build/solve/render the entire new section
before writing any old prefix. entries.inspect also preflights it after discovery,
using existing structured Emit.Item diagnostics for missing/corrupt authority.
Unsupported source returns explicit residual output, not an ordinary user error.
OOM/resource/writer propagation keeps the existing command convention; no promise
of further diagnostic output through a broken writer or full IO atomicity.

Source schema1/private Dispatch21/public Interface18 remain unchanged. No derived
whole-entry fact is cached. Required Source capture and common semantic admission
remain demand-driven under existing --entries/dump-stage=entries with every
checked module requested, including packed core. Native acceptsCached remains the
FIRST common install predicate. Child GeneratedUnit requests remain disabled.

## Bound and required actual tests

For M modules, V original exec/value/source rows, E original dependency/call edges,
P actual fields/paths, L supplied liveness rows, R supplied selected scope rows and
U original ValueUses, builder and consumer add O(M+V+E+P+L+R+U) storage/work.
Realms' fixed five bits plus incomplete transition at most six times per node.
Consumer retains two demand bits and CSR adjacency over original edges, walks each
edge at most twice for definite/possible demand, scans roots/liveness/uses once, and aggregates natives by
indexed rows. No root-times-graph clone, transitive formal/native sets, repeated
field scans, source-size cap or budget waiver. Record actual counts and later
ordinary-work/cold/warm/profile costs; asymptotics are not measured acceptance.

Registered actual ordinary Beni tests must cover selected Plan/runtime/root reads,
actual registry/native_seed and solver seed-read counters including real mask31,
current imported ValueIndex0 -> BIR declaration1, main alias vs constructor source,
explicit selected initializer vs possible retained initializer vs unused deferred
native callback, mixed known direct invocation plus unknown escape of the SAME
native callable (unresolved must dominate regardless of source order), callback invoked vs merely
returned, known aliases/closed selected field vs bad sibling, independent identical
signature functions using compiler-private test seeds, unresolved formal/opaque/
unknown escape and blocked case/try/markup calls. Private test seeds are built-in
test-only and never a CLI/source option. No hand-built graph-only positive proof.

Also require missing legacy selection/open library, cold/warm/jobs1/8/roundtrip/
relocation and existing source semantic cache repair, error->repair reused Session
selection reset, independent source mutations, allocation-failure cleanup and
nonpartial semantic evidence errors. Preserve all failed attempts/used binaries.
No public native lowering, C/owning storage, HostFree/Wire/EntryHost or launch claim.

### Inspection-only contract staging seam

The Phase1 pending-native denial currently runs in Emit.checkContract before
inspectEntry can find an entry, so an actual native CLI producer cannot reach
this read-only consumer. Introduce private ContractIntent inspection|execution.
Public checkContract calls the private helper with execution; Emit.run retains
its existing early denial unchanged. ONLY inspectEntry calls inspection intent.
All ordinary entry filename/exports/lowering/runtime/type/effect/foreign-shape
checks remain identical. This is not a public option or execution exemption.

Inspection's sibling expected-export loop may omit ONLY the exact CURRENT
Session Registry Installed.module + checked.declaration foreign value, using
qualified checked identity. Its source/ordinary shape remains attested by Phase1.
Every other foreign retains normal sibling shape/export/arity/import checking,
including same-spelled ordinary modules, physical/core_root source overrides and
unrelated foreign declarations. The attested candidate gets no arbitrary .js
fallback: its omitted entry does not ask for a sibling or read one as authority.
Default execution intent still refuses it before output. This staging split
exposes recipe identity to inspection and does not emit a facade, grant a mask
proof, enable nativeLowering, or change a language/foreign rule.

Retain the small Emit-only source delta separately for root review. Actual CLI
controls must show native inspection reaching real registry/seed/roots, normal
build still denied with no output, ordinary same-name/physical override retaining
sibling checks, and unrelated missing/bad foreign sibling still diagnosed in
inspection. Existing native5 denial tests remain required.

### Deterministic artifact and actual trie-work measurement

Interned global symbol IDs are not scheduling-independent. The compact field trie
uses them for correct identity lookup, but its actual branch-step count can vary
with symbol assignment. The first packaged CLI probe observed cold227 vs warm240
steps with EVERY other byte/fact identical; both failed-comparison streams remain.
Do not expose this measurement as a scheduling-independent semantic artifact.

Normal output explicitly prints fieldStepsBound=64*fields+33*fieldQueries. This is
an identifier-width worst-case BOUND, never measured work/performance. Keep actual
Builder.Work.value.field_steps unchanged and add existing Profile counters
realm_builder_runs and realm_value_field_steps on each successful builder run.
Both inspection-preflight and final-render passes count; the mutable profile is
an explicit service argument and entries.write takes mutable Session for this
purpose, never a const cast. Tests require actual aggregate counters, expected
run count, and actual<=runs*bound, alongside exact normal bytes cold/warm/jobs/
roundtrip. No other counter or semantic fact is filtered/normalized.

Session.run keeps its existing early frontend/check profile flush, including early
source failures. Entry inspection/render happens AFTER that flush. Check --entries
and dump-stage entries therefore explicitly overwrite the same requested profile
again after late inspection/render, before their final return. A normal late
semantic failure flushes its actual completed preflight work before exit1; success
contains both builder runs. Late inspector/render failures attempt a best-effort final partial trace, preserving
exit/error/no-prefix behavior. The early trace remains until the final overwrite
is attempted. Profile IO failure can leave an incomplete file under the existing
streaming write convention; no new profile IO atomicity is promised. Preserve
exit2 and the existing profile path/error reporting convention. Never change expected runs2 to0
or claim late counters existed in the earlier snapshot.

### Reused Session diagnostic-wave lifetime correction

The actual resident success->type-failure->repair regression retained the previous
worker-owned type_mismatch after repair (same span/message); a fresh identical
repair returned0. Session.run reset entry facts but worker diagnostics survived,
and collectDiagnostics only cleared the borrowed aggregate before re-merging them.
At NEW RUN START only, clear the borrowed aggregate FIRST, then use existing
worker.truncateDiagnostics(gpa,0) to free/drop every prior error/warning message.
Never clear within a wave or suppress current diagnostics; native binding failure
remains fail-closed. The fixture refreshes existing numbered physical source bytes
via SourceStore.read, never requeues duplicate modules. Retain that separate setup
failure and exact stale-message before/fresh contrast evidence.
