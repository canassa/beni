# Exact native emission authority and first-class constructor facade

Normative proposal for root review, 2026-11-01. No compiler edits or runtime enablement are authorized by this document. It refines the existing one-constructor design. No new language/type/effect/ownership rule, source cap, all-mask exemption, or EntryHost/C/discovery certificate is introduced.

## 1. The precise Unit call-contract lemma

Use the current attested Registry row, not a new serialized per-expression Unit flag. Bindings.validate already proves the exact ordinary native signature has one Unit argument, no quantified/evidence parameters, and the pinned native nominal result. An ordinary-clean original saturated call, whose actual source value origin resolves to that same installed QualifiedDecl/native execution identity and digest, therefore has an actual argument VALUE of Unit. That value cannot contain or escape a Beni callable. This applies equally to a direct reference and a first-class alias/known-returned function whose original value origin resolves to the exact binding. Matching signatures or rung1 alone establish no identity.

The producer must match the original call's one explicit argument and original callee port to the resolved native identity. Initially admit the existing plain `.call` form; other activated/method forms require their existing exact argument mapping, not an arity guess. A blocked call remains blocked. Ordinary checking must have succeeded for the same checked source inventory. No claim is made from an unvalidated Source node, a cache-supplied bit, an opaque callee, or a polymorphic/unsaturated call.

Record an explicit value-only discharge witness `{CallId, originalArgumentPort, NativeExecId, bindingDigest, contract=saturated_unit}`. Suppress only that argument's escape obligation. Do NOT change the argument port's general origin, remove its source node, remove calls used to compute it, clear any ambient execution residual, mark its computation pure, or authorize a blocked invocation. In `new (effectReturningUnit())`, evaluation of the effect retains all existing edges and residuals. In `invoke new`, the argument is the native callable itself and this lemma does not apply. The same-type forged binding and a different ordinary function taking Unit also do not qualify.

Implementation seam: the registry adapter supplies a downward immutable argument-contract enum validated alongside its existing NativeSeed. `RealmBuild.executions` matches the original call/argument and exact native target, then records this value-only discharge instead of `escape` for that one value. The kernel remains unaware of Bindings; the adapter is the only production contract supplier. Original source inventories and ordinary cache/install authority are unchanged. No source schema bump is needed for a fact rederived from the current registry and current checked call each build. Existing `TypeStore.resolvedContent(v)` can recognize `.structure.unit` before freeze, but is unnecessary here and would require additional cache authority if persisted; do not add that broader mechanism for this slice.

## 2. Immutable authority table

Add a small build-owned native emission helper (proposed `native/Emission.zig`). It owns no checker state and imports no mutable effect store. Its input is the current installed Registry, current checked source graph and builder/consumer output, actual validated selected Plan/source root, and the final ordinary Reach value-liveness that this build will lower.

Suggested types:

- `BindingIdentity { target: QualifiedDecl, digest: [32]u8, recipe: construct_text_encoder_v1 }`.
- `RecipeRow { identity, native_type: { module: Graph.Index, index: Interface.TypeIndex }, ordinary_scheme: { module: Graph.Index, index: Interface.SchemeIndex }, argument_contract: saturated_unit, expected_error: none_unexpected_defect }` — current Registry attestation only.
- `UseWitness { source, call: ?CallId, port, kind: invocation|retention|escape|unit_value_discharge, disposition: checked|disjoint|closed_deferred|unresolved }` — all original identities preserved.
- `Disposition { unreachable, ready, refused }` and `Row { identity, disposition, witnesses: Range, deferred_obligations: Range }`.
- `Prepared { rows, witnesses, obligations, selected_source, selected_kind, selected_realm }`, immutable after validation, explicitly deinitialized after every Lower worker joins. No pointers/indices into destroyed builders, growable borrowed MAL slices, or unification stores survive; copy fixed source coordinates/IDs and witnesses into owned storage or retain their owning immutable builder for the entire consumer lifetime.

There is deliberately no serialization of ready rows. `ready` means that this build may emit the pinned facade under all applicable use obligations; it does not mean complete EntryHost or that every retained facade was actually invoked. `unreachable` requires the exact native callable declaration not to be live; a type-only import can therefore remain attested without an execution proof or facade. `refused` preserves the original reason/witness and produces the existing unavailable/not-implemented diagnostic before Lower/output.

The sibling scan occurs before Reach. It may recognize `RecipeRow.identity` to avoid demanding a handwritten sibling for that exact generated declaration, but this is not a ready row. Later every LIVE recognized recipe must obtain `ready` before emission/adoption. Ordinary unrelated foreign declarations retain all existing checks. An unrecognized source/physical override never receives a recipe row.

## 3. Required use closure; no rowstate-only gate

The current native row and global `useCoverage` summary are inspection results, not this table's eligibility predicate. An invoked_checked row can coexist with an unattributed aggregate escape. Such a row alone is insufficient.

The authority producer must enumerate the original use domain applicable to the selected closed build and the live native value: exact selected runtime/callback/initializer roots, source calls reachable through its classified edges, possible roots not proved irrelevant, and all live retention/escape paths of the native value. It needs complete native-relevant use coverage, not whole worker discovery. A source region may be excluded only by actual original value/field/closure-flow proof that it cannot carry or invoke this identity. Source absence, missing roots, or unknown value origin does not prove disjointness.

For the initial reducer, conservatively refuse any applicable unknown/aggregate escape which has not been proved disjoint. This is an explicit unsupported proof case, not a compiler source rejection cap. Existing known original record/tuple and selected-field origins can support exact disjointness; do not scan every aggregate independently per use or expand environments. If broader closure/aggregate reachability is needed, build one source-indexed fixed-point dependency graph for this one binding, with native-reachable and unresolved bits and original witnesses, each bit propagated once per edge. Unresolved formal values remain unresolved; no type/signature equivalence creates callable identity. This is a separate reviewed producer extension, not an assumption already provided by RealmBuild.

Exact selected Plan callback-role edges are existing typed invocation obligations, unlike arbitrary higher-order escape. Reusing them requires the actual selected constructor/role and original value-origin binding (CompactDiscover's callback origin/role), not merely membership of a function in conservative live code. An arbitrary `invoke Encoder.new` or an opaque aggregate passed to an unknown callback stays unresolved. If this explicit mapping is absent, the candidate is refused; it is not excused by mask31.

Every relevant invocation must be selected-realm checked and nonblocked. Every retained value must either be consumed by those known checked uses or have a closed deferred obligation whose complete source use domain is retained and cannot escape. Library/exported or unknown callback obligations require public obligation publication that is currently unavailable; they remain refused. A direct first-class alias subsequently called through an exactly resolved origin is a checked use and does not require pretending its earlier value read was invocation. Merely retained-but-unused first-class code does not automatically become ready from `deferred_retained`.

Unrelated entry residuals remain explicitly unresolved; this slice does not claim full discovery/C/EntryHost. But unresolved evidence needed to establish this native's use closure cannot be ignored. The producer must expose both its relevant coverage decision and original unresolved witnesses, rather than flipping the Registry's awaiting_realm flag.

## 4. Emitter ordering and reuse authority

Keep public denial until the complete pipeline is reviewed. In the implemented path:

1. Reset previous build state. Obtain current ordinary Registry attestation; perform contract/sibling checking with exact recipe recognition only.
2. Validate the selected entry/Plan through the existing emitter route. Compute ordinary Reach/projection at the existing pass positions; no change to initializer/deferred policy or source alias guard.
3. Build current source-native uses and their required consumer evidence; intersect with final live callable identities. Prepare and validate ALL live native dispositions before `emitModules`, any Lower call, any `slot.adopt`, any EmitPack text reuse, or output preflight/flush.
4. Publish an immutable `Prepared` borrowed by Lower workers. `Lower.foreign_value` and `Lower.importStatements` consult the SAME exact current row. Missing/refused live rows cannot fall through to sibling handling or an unbound name. The table is destroyed only after workers join.

Ready status is never read from EmitPack/Funnel/disk. A current-build pre-adoption scan is mandatory even if all source/IR/text is reusable: a changed selected realm, source root, or escape use can invalidate readiness without changing the native module's bytes. Record recipe identity/revision as a Lower input dependency through the normal reuse contract; the ordinary generated-source fingerprint already distinguishes provenance and recipe source. Reused emitted units must be from the same recipe/ABI convention, and every current live use must pass the current gate first. No need to serialize current realm selection into reusable constructor text if it is selection-invariant and the independent gate always runs before adoption; do not reuse a cached positive decision.

For non-native projects public checkContract keeps its existing no-entry-search meaning. Native-candidate public check --platform and build both require the shared non-rendering selected-use readiness route specified in §8.5; recipe recognition alone cannot make public check succeed while build refuses unavailable use evidence. The present inspection-only intent never satisfies that gate.

## 5. First-class facade and strict Unit

For the attested live ready binding, emit one ordinary named callable under its existing Beni module/export name. Preserve its one-argument foreign convention. Its body is existing `JsIr.new_call` of the pinned global TextEncoder with ZERO host arguments. Return the native object directly. No manual JS, dynamic apply, per-object wrapper, builtin/typeword, noThrow annotation, or Js.Value erasure.

Patch the currently empty foreign_value declaration branch and the sibling-import list using the same identity. Keep `unwrittenArgs` unchanged: a foreign Unit parameter is not an ordinary `.value` unit-pattern erasure. The actual argument is evaluated exactly once before entering the facade. Any later direct-call optimization must preserve argument evaluation BEFORE host-global read/construction, including exceptions. Existing new_call conservative Spec behavior remains; no CSE or impurity weakening. Reach must not tag construction inert or parameter-forwarding.

## 6. Acceptance tests and proposed source ownership

Proposed files: new native/Emission helper and tests/registration; narrow Bindings/downward-contract plumbing; RealmBuild value-only argument discharge/witness; exact selected-use proof helper as necessary; Emit/Lower immutable input and declaration/import handling; no broad Spec or ownership change. Norm first, isolated lane only, helpers within existing limits.

Required real tests: ordinary Registry + saturated direct Unit and effectful Unit; first-class alias/known-returned identity; wrong same-signature binding; native callable passed to arbitrary callback; unknown aggregate holding it; blocked call; direct checked plus unresolved escape; type-only/unreachable import; unsupported library/deferred publication; mask-negative private seed; failed check/repair; physical identical override and forged cache; cold/warm/jobs/roundtrip/relocation. Add current-build authority failure with reused Lower/EmitPack bytes present, proving no module/output is adopted before refusal.

Actual dev/release existing Node/browser harness transcripts and pre/post-Spec IR must establish once-only argument evaluation, zero host args, correct first-class convention, allocation impurity, exact native nominal return, no sibling import/facade for unreachable types, and no output on refusal. Compare raw/gzip/Brotli and actual phase counters; parent coordinates CPU/full gates. No completion, cost, ownership-runtime, or launch claim is made here.

## 7. Production request before common installation

Current `check/Command.zig:50` requests Source only for --entries; ordinary build currently has no such request. The ready-table implementation must include an internal build request, not rely on users running the inspection CLI first.

Add a default-false Session option expressing **native emission preparation requested**, set by build/Command's ordinary build path (including its watch/recreated Session options), and by the native-readiness public check --platform route described in §8.5. Inspection-only --entries remains the separate existing native_realms request. It is not a CLI authority switch and is distinct from the existing explicit `native_realms` inspection request. At `Session.runCheckOnBigStack` before constructing Check.Options/Runner (current :2618), the resolved Graph and winning SourceStore supplier are already available. Compute:

`capture_required = options.native_realms OR (options.prepare_native_emission AND any current graph file has a compiler-generated native candidate Origin)`.

Scan current Graph files using `store.nativeOrigin(graph.moduleFile(module))`, after supplier resolution. Do not trigger on module spelling, isEmbedded, core_root, a persisted native claim, or a stale Registry from the preceding run. The Origin here requests evidence only; ordinary source/interface/Registry validation later decides whether it is actually the pinned recipe. Invalid candidate source can trigger extra checking but cannot gain emission authority. A physical same-byte override has no generated Origin, so follows the ordinary foreign path.

When capture_required is false, pass the existing empty required-module slice: no Source capture, new counters, optional allocation, extra type roots, or changed cache requirement for ordinary no-native builds. When true, the initial supported producer requires source inventories for the complete currently checked graph (not merely the generated module), because aliases, closures, evaluated arguments and callbacks can reside elsewhere. Allocate the Graph.count bitmap, set these required modules, and keep it alive only through Runner completion as today. Measure this native-only cost honestly; do not claim no extra work for candidate-containing builds.

Driver's existing admission conjunction at :475-479 must apply before Incremental.install for disk and embedded-pack candidates. Missing required Source means an ordinary miss/recheck; malformed or downgraded Source fails the existing common semantic verifier. Do not install an old no-Source pack row and then discover missing evidence during Lower. Warm Source-bearing rows may reuse only after the same current BIR/module-ref/intrinsic verifier passes. Current attestation validation remains an independent prerequisite; Source presence never grants native authority.

Session.run already resets Registry/Plan/graph before input enumeration. Recompute the capture requirement on every run and every recreated watch Session; do not leave the boolean sticky after a generated import disappears. Cache keys do not serialize a ready decision. No private version bump is needed solely for selecting already-existing optional Source records; any actual persisted row change needs its normal coordinated revision.

Production use preparation must consume the existing build's frozen selected input/Plan and current Reach data directly. Do not call dump.entries.inspect or Emit.inspectEntry from inside a running emitter: those APIs reset Session graph/Plan and perform their own contract search. Factor a non-rendering producer that accepts actual selected source/Plan/current checked inventory and returns the immutable authority table. Inspection may call that shared producer for evidence, but inspection intent itself is not authority. No formatted output is parsed, and all preparation/errors precede parallel lowering, reused unit adoption and file output.

Trigger regressions: ordinary no-native cold/warm builds retain empty Source requirement and previous counters/output; real generated import makes old pack/disk rows without Source miss once, then warm source0 reuse; adding/removing the import in a reused Session/watch re-evaluates the request; physical identical override does not gain capture-derived native authority; selected-root/realm change re-runs readiness even when all checked module records are warm.

## 8. First implementation checkpoint: closed no-callback Program

Root scoped the first runtime-capable checkpoint separately from realistic callback forwarding. Use a real ordinary selected Program with an empty constructors/launches/parameters metadata list, a public nullary Program constructor, and a runtime `run : Start.Program → ⊤; run _ = ⊤`. Main evaluates the native construction in its initializer, then returns the ordinary Program value. Validate this exact fixture through the existing checker/Plan before treating its syntax as accepted evidence. It does not require inventing callback roles or changing the language.

Variants must exercise:

- direct `Encoder.new ⊤`;
- `alias = Encoder.new`, then `alias ⊤`;
- a capture-free known helper returning `Encoder.new`, followed by actual invocation of that returned value;
- `make argument = Encoder.new argument`, called with Unit, exercising the exact native call-contract lemma for the formal Unit value;
- an effectful Unit computation using another supported checked construction before returning Unit, so the first slice can preserve strict effects without granting authority to an unsupported raw-host effect. Broader logging/opaque argument effects remain explicit residuals until their actual relevant-use proof is available.

The initial gate admits only the actual closed no-callback selection and complete native-relevant uses it can prove. The existing entry-discovery/basic callback fixture remains inspection-only/unavailable for normal native lowering at this checkpoint. In particular, its eleven unattributed escapes are NOT cleared by the Unit lemma. No public worker launch is activated. This is staged proof support, not a source-size cap or a waiver; completing callback transfer authority follows in the same PR.

### 8.1 Exact recipe domains and ownership

`RecipeRow.native_type` is `{module: native.module, index: native.checked.type_index}` in that module's current Interface; its scheme is `{module, index: native.checked.scheme}`. These are the existing `Bindings.Checked` domains. If `Bindings.Installed.nominal` is needed for comparing current resolved nominal identity, keep it as a separate explicitly named resolved identity, never reinterpret its integer as an Interface index. The table owns/copies those stable current-Session coordinates plus digest; workers borrow the table only while the current checked Session survives.

### 8.2 Initial source-finite coverage algorithm

Do not read dead `RealmValues.Fields`, `tuple_ranges`, or `tuple_ports` through `Output.Origin.value`. Those tables currently die at the end of Build.build. The first checkpoint needs no aggregate expansion: any applicable argument/escape whose origin is record, tuple, formal, pattern, opaque, value-cycle or missing remains unresolved, except the exact Unit call-contract discharge. A known first-class callable origin is not an aggregate and can be mapped through its retained ExecId and exact NativeValue identity.

Use current owned Output rows and a single shared reverse execution index. Seed native Exec with bit N (may execute this binding); seed an execution with bit U for an unresolved call/blocked execution in its body. For each existing classified execution edge caller→callee, propagate N/U from callee to caller. Each bit rises once per Exec; each edge is visited at most twice, preserving one original source witness per raised bit. Reuse the kernel's separate allowed/incomplete facts for the actual realm check; these two applicability bits never overwrite them.

For each currently applicable original ValueUse, inspect its existing origin once:

- scalar or exact Unit-discharge witness: no callable-value escape;
- exact native callable: native use, retain its original Call/source/port witness;
- known source callable: its Exec's N/U decides whether invoking or escaping this closure is native-relevant or unresolved; its captured values must also be known safe, as below;
- other origins: unresolved for initial authority, never treated as absent merely because they have no immediate native_exec.

Closed first-class aliases and known returned functions retain the same native Exec identity; they do not need environment expansion. The actual ordinary final Reach declaration list bounds retained code to scan; selected roots and possible retained initializer obligations use existing consumer rows. Do not include every unreachable module declaration just because it exists in the Source record. Conversely, do not drop applicable possible roots to obtain a positive result.

For captures, the first checkpoint admits capture-free known helpers only. Derive capture presence from the actual original lexical scope/local-definition mapping: any original local read whose definition belongs outside the function scope is a capture, with its original definition/read witness. Scan source locals/read sites once, use precomputed lexical parent intervals (or equivalent linear owner mapping), and retain an owned per-Exec capture-presence/witness row in Output. Do not infer capture absence from zero arguments or from a callable Origin alone. Capturing helpers remain refused until the sidecars below are implemented. Native/foreign and top-level alias-value origins use their exact existing source identity, not a fabricated capture-free lambda.

Additional memory/work is O(X + E + P + U): execution count X, existing classified edges E, original ports/local-read inventory P, and retained original use rows U. At most two execution-bit transitions per node; no per-native/per-role graph clone, context/product enumeration, or source cap. Current recipe count is one. Work counters report actual scans/edges/transitions. This bound is for the new reducer, not a relabelling of whole-pipeline discovery cost.

Before marking `ready`, all applicable invocation sites must be direct/realm-checked, every native-relevant escape must be discharged by exact known use authority, and all applicable unknowns must be absent. Initial library/export/deferred-without-complete-use-domain/aggregate/opaque callback cases remain refused. A mere `.deferred_retained` inspection row never bypasses this predicate.

### 8.3 Follow-on aggregate/capture storage (not silently assumed)

To broaden proof support, retain owned original adjacency in Output during the existing descriptor scan: dense per-port aggregate ranges plus `{selector: field(Symbol)|tuple(index), child: PortId}` edges, and dense per-Exec capture ranges plus `{originalRead, originalDefinition, valuePort}` edges. Each original field/tuple element/read contributes at most one row; no per-use copy. Move/copy these arrays into Output and free them in Output.deinit; no borrowed private trie or arena slice survives. A resolved projection follows its selected child's origin, so `Pair.good` does not inherit an unselected bad sibling. An escaping whole aggregate includes all original children. Unknown extension/pattern/formal structure remains explicit unresolved.

The fixed-point extension uses original aggregate-child, capture, and classified execution edges, with the same N/U bits and no per-role expansion. Alias/result origins are already memoized by RealmValues; identity cycles stay unresolved. This does not itself establish selected callback transfer authority. That needs the distinct anchored witnesses below.

### 8.4 Real callback fixture mapping and why it is a follow-on

Actual consumer-probe1/cold.stdout reports Main.main roles 0=Main.begin, 1=Main.first, 2/3=Main.callbacks lambdas, all S=closed. Child anchors Main.foo/Main.bar have distinct role bindings although both constructions have source Main.make@43. Therefore `(constructor site, role)` is not an identity-safe transfer key.

An eventual owned `RoleTransfer` snapshot must retain `{EntryId/AnchorId, KindId, constructor OriginId, role ordinal, callback OriginId, W/S completion, original substitute CallId/source, input owner/ordinal, actual argument source port, original field selector path}`. Produce it from the existing selected observation and actual `CompactSolve.deliver(.substitute)` branch, whose `input.owner == call.target` check and original argument/capture slot lookup are already authoritative; never reconstruct it from names or final callback source alone. Copy stable source coordinates and selected IDs before the Compact IR/solver dies. Keep one row per existing relevant solver edge/delivery, indexed/shared; no per-consumer cloned trace or new environment combinations. Retain actual added counters and the existing solver's own bounds separately.

Map Graph.Callback through `origins[callback.origin].site` to builder `callableAt`/`callableAtInstruction`; map its constructor through the corresponding selected construction/anchor and exact Plan role. A role-transfer discharge is for that anchored original argument/capture route only. Main.foo and Main.bar must not authorize each other through their shared helper site. The runtime's unknown role parameter is covered only by the declared selected callback invocation contract; an unrelated `invoke Encoder.new` remains unknown.

The exact basic-family unresolved sites are Main.second@22; make@42/43; foo@46; bar@49; begin@68/70; main@78/79; Start.make@45; Worker.make@45. Helper transports into callbacks/constructors require the anchored substitutions above. Worker.open additionally requires actual selected launch-target/child-entry witnesses. Main.second's Int argument is a separate exact ordinary scalar-value fact, not a callback identity; do not clear it with Unit or a native realm mask. These are explicit next producer tasks, not guarantees already established by this initial no-callback checkpoint.

### 8.5 Public check/build agreement

Until an actual selected-use authority table can be prepared, both ordinary native build and public `check --platform` remain refused with no output, as today. The initial implementation MUST NOT simply remove checkContract's pending-native guard while leaving check without a selected-use producer.

For native candidates only, add a non-rendering public-check preparation route that performs the same actual selection/readiness procedure as build (using the same immutable producer API); if selection/use proof is unavailable, it refuses. It may do additional analysis for this new native feature, but must not emit modules or claim an entry certificate. Non-native public check retains its existing no-entry-search semantics. An alternative contract-only recipe validation can remain an internal helper, but it is not the public success path for an executable pending-native candidate. Public check and build share the same refusal reasons and current registry/use witnesses, with build alone proceeding to Lower and output. Both must request Source before common cache installation when native readiness is requested; no late second checker run or inspection-output parsing.

### 8.6 Exposure bits include returned values, not only invocation

The initial N/U reducer in §8.2 must include function RESULT exposure. A capture-free function returning `Encoder.new` can expose the binding without executing it; treating its zero execution-edge count as disjoint would be unsound. Use a single graph with both owned Exec and Port nodes:

- a callable Port has an exposure edge to its actual origin Exec;
- an Exec has exposure edges to its original result Port and to actual captures (captures initially seed U/refuse), in addition to existing classified callee Exec edges;
- scalar ports seed neither bit; native facade Exec seeds N; unknown/formal/pattern/value-cycle/aggregate ports seed U in the initial no-aggregate domain;
- memoized alias/known-return origins retain the same original result/callable identity; no actual parameter is substituted into a shared input cell.

An attested native constructor RESULT is the exact ordinary foreign nominal result, not the callable facade. Add a value-only `native_result` witness for its exact original Call.result port; it is disjoint from the constructor callable identity, without asserting HostFree/Wire/serializability or deleting the construction edge/effect. Follow this witness only through the existing exact memoized origin/witness forwarding; an unrelated opaque result is not covered. This permits a capture-free `make unit = Encoder.new unit` helper to return its object without inventing callable exposure, while a helper returning `Encoder.new` itself remains N. Any later unsupported inspection/escape of the opaque native object retains the ordinary residual policy.

Every graph node has at most two monotone transitions. The bound is O(P + X + E + U) plus original result/capture edges (one result per scope, initially one capture-presence witness per scope); no function-per-use traversal. With later aggregate sidecars, add their original field/tuple/capture edge counts once. This is the concrete fixed-point graph; an implementation omitting result exposure must not be accepted.

## 9. Actual minimal-fixture validation and nullary data result

The real ordinary Debug probe accepts the selected no-callback Start.Program
fixture, with actual source/runtime reads and zero root misses. Its nullary
`Start.Program` result is ordinary data, but the initial realm value-origin
solver intentionally leaves constructor namespace values opaque. The exposure
reducer may prove this specific value disjoint from a callable using the original
BIR constructor namespace and existing ordinary arity: local Bir.Ctor argument
range empty, or external current Interface.Ctor.arity zero. It never interprets
an external constructor index as Interface.ValueIndex, never assumes an unknown
constructor is nullary, and does not generalize this to schema/native payloads.
A non-nullary constructor or unavailable metadata stays unresolved. This
value-only proof leaves original initializer effects and calls unchanged.

Actual baseline direct, forwarding, known-return and nested effectful-Unit cases
have represented native uses. The formal-Unit helper has exactly one escape at
its original argument port, confirming the scoped discharge implementation
rather than a global unknown-clearing rule. The proof still explicitly reports
whole worker discovery and EntryHost as incomplete.

## 10. Exact facade reuse question

The fixed constructor facade records `native_recipe` in the existing Funnel for
its exact module/declaration. Its answer identifies the current exact attested recipe/ABI, independent of
execution disposition. Ready/refused is never serialized; the fresh per-build
gate separately requires readiness before reuse or lowering. EmitPack advances from version 2 to 3 for this additional question;
it is separate from the private Dispatch schema. The recipe and its digest are
compiler-owned constants for this one recipe, under the existing compiler build
identity and ordinary module source key. A different supplier, signature or
recipe cannot inherit a true answer: current registry/source validation and the
per-build disposition run before cached/adopted lowering, and the old row format
is unavailable. This is not a cached realm certificate. Ordinary modules ask no
new recipe question and preserve their lowering shape.

## 11. Final emitted declaration retention is independent of compact discovery

The authority input borrows the current final `Reach.Result`, not one native-live
boolean. CompactGraph retention can be empty for a no-callback Program and is
not the final emitted-code set. The producer checks every actual live ordinary
value/foreign declaration against its original builder declaration port. A
native-exposed callable whose execution is not demanded remains a deferred
obligation and refuses this initial closed slice. Unknown value exposure also
refuses; it cannot disappear because CompactGraph has no ordinary entry row.
This scans original declarations once and uses the same N/U result, without
re-running per-function walks. Lifted/derived/twin live code is unsupported in
this initial slice unless independently covered; it is never silently omitted.
The BIR pointers used for constructor disjointness are derived inside authority
preparation from the same Source artifacts and Graph; callers cannot supply a
second graph to manufacture a nullary result. Reach provenance/dispatch/table
lengths must identify those same current inputs. These are per-build borrowed
inputs; only copied recipe/disposition/witness rows survive preparation.

## 12. Retained code and evaluated module initializers

Final Reach declaration retention is not itself an execution root. The consumer
accepts two separate optional inputs: retained declarations (possible initializer
obligations), and actual evaluated initializer roots. Both default empty for the
inspector. The initial generic emission producer can supply the latter only for
a live unconsumed ordinary `.value` whose current `Convention.definitionOf` is
`.constant`: the SAME predicate used by `Lower.declarationAs` to emit the body
immediately in a top-level const/let. It additionally requires the original
builder initializer; a function body is never substituted. Parameter, lambda,
applied, thunk and unavailable conventions do not gain this evidence. Program
lowering/cuts/consumed projections require their own evaluation witness and are
not admitted by this initial generic native slice.

The exact no-callback fixture `encoded = Encoder.new ⊤` therefore needs an
explicit generic eager-initializer witness; disjointness of its object RESULT
cannot erase its construction. Without that witness the retained initializer
remains possible and refuses if it exposes native execution or unresolved value
origins. Native-unrelated complete inert retained initializers need no execution
realm proof. Selected initializer/runtime roots keep their existing independent
authority. All inputs are original QDecl rows, indexed/deduplicated once, with no
fabricated CompactGraph entry or callback row and no per-environment expansion.

## 13. Optional ordinary profiling

The emission producer uses the existing optional Session Profile. Every actual
builder run contributes to `realm_builder_runs` and its actual field steps;
completed exposure passes report their nodes, edges, monotone transitions and
edge deliveries. Refusal before a producer runs reports no invented work. No
profile request means no new file/output or enabled counter collection. These
are actual operations, not a replacement budget or a constant allowance.

## 14. No redundant compact discovery for the closed initial slice

Before any ready disposition, the actual validated selected kind must have zero
constructors, launches, roles and type arity. This exact predicate is enforced by
authority preparation. Production supplies an explicitly empty compact view;
it does not run CompactDiscover or manufacture ordinary entry rows. The exact
selected initializer/runtime and separately witnessed final-Reach retention and
evaluation roots supply all this slice's obligations. Nonzero kinds refuse before
readiness. This does not prove discovery complete, C, EntryHost or child launch,
and does not fund another compact/shared-budget pass. Callback RoleTransfer
publication remains separate required work for broader programs.

## 15. Runtime observation fixture

Runtime tests use the unchanged Node harness with a preload generated entirely
through verified JsIr and the ordinary printer. The preload wraps the real
TextEncoder in a Proxy and logs constructor-property reads and constructions;
it returns the real `Reflect.construct` result. This is test-host observation,
not a generated binding implementation or an owning/native-value wrapper. A
second mode throws an unexpected host defect. Ordinary Beni fixtures supply
first-class/returned calls and nested effectful Unit arguments; no handwritten
JavaScript program or new Beni intrinsic is introduced. Dev and release runs
must preserve the exact constructor count and argument effects, and refusal
cases must execute neither preload-invoked program nor emitted native facade.

## 16. General JsIr transfer failure cleanup (#1544)

The runtime observation allocation sweep exposed an existing general-allocator
failure in Builder.toOwned. Every detached column needs a temporary owner until
all fallible transfers succeed; on failure those owners free detached storage,
and the caller's ordinary Builder.deinit frees remaining builder storage. The
successful IR, representation and allocator policy stay unchanged. This is not
an arena-only contract: production Lower uses its general allocator. Retain the
original failing host fixture and add an independent all-column allocation sweep;
no arena substitution may be called proof of Builder's failure cleanup.

Fallible extra/string/name transfers happen before infallible node transfer.
Thus the builder's cached node columns still identify owned nodes on failure;
only previously detached auxiliary columns are freed by their temporary owners.
No successful-path copy or additional retained representation is introduced.

## 17. Exact closed recipe ABI in the emitted unit question

`native_recipe.where` is a closed ABI code, not zero/unused. Code1 is
`text_encoder_unit_constructor_v1`: actual TextEncoder type/callable attestation,
row schema1 / text_encoder_v1 / adapter revision1, an ordinary strict Unit
parameter evaluated by the caller exactly once, then a direct zero-argument
`new globalThis.TextEncoder()`, raw native result, no exception conversion or
value wrapper. This code is immutable; a changed calling/lowering ABI requires
a new code and mapping, not reuse of code1. This is independent of the ordinary
effect rung and the current execution disposition.

The per-build table stores the ABI selected from the exact attested installed
row. Lower records the exact ABI code with its qualified declaration; reuse
answers true only if both that code and the actual declaration still match.
Zero (the earlier unpublished question), unknown and changed codes answer false,
even if a constructor row is present. Row schema/identity/adapter mismatches
cannot manufacture code1. EmitPack3 persists this semantic question, never the
ready state. Every adoption still requires the fresh source/realm/use gate;
no SourceView/exported-fingerprint assumption replaces the explicit ABI question.

This query is positive-only: Lower asks it only when emitting the actual
attested facade. A serialized native_recipe with answer=false is malformed,
not evidence of absence. The decoder structurally rejects old/unknown ABI codes
and false answers before comparison. The lowering reuse handler also validates
that format and returns its match directly, never compares a false unavailable
answer with stored false. Thus no-current-native, old code and changed ABI are
cache misses for either stored Boolean; they cannot certify a negative recipe.

## 18. Ordinary CLI activation of the closed slice

After the frozen source-consumer and authority review, the ordinary Emit.run is
the same tested pipeline; the temporary outer Phase1 denial is removed, without
a test-mode branch or new flag. Public check --platform of an installed candidate
performs the same actual selected entry/runtime discovery, current Reach and
native authority preparation before returning success. This native-specific
check performs no lowering/adoption/output. Ordinary no-native contract checks
keep their existing no-entry-search behavior. Inspection stays evidence-only.
Unsupported callbacks, open libraries, deferred/opaque obligations and missing
source remain refusals; no Worker/EntryHost/C/owning completion follows.

## 19. Reserved logical export names in ordinary siblings

Existing JsIr export_stmt carries logical Name values. For an unqualified local
whose binding spelling needs reserved-word escaping, the printer emits the
escaped local binding `as` its fixed logical ModuleExportName. Thus logical new
is bound as $new but exported as new. Qualified Beni names and nonreserved local
exports remain byte-identical. No new IR node, codec, Beni syntax or visitor is
introduced; fixed export names admit keywords without binding escaping. Actual
sibling scanner and Node tests must observe exact new, not an arbitrary wrapper
or manually written JavaScript fixture.

## 20. Actual emitted-pack reuse controls

Extract the existing maker rowUnit/ident/text/moduleRef encoding unchanged into
EmitPackRecord, shared by the ordinary maker and test fixture. The fixture first
ordinary-checks canonical source and prepares its current native table, then
runs real Lower with Funnel.Recorder and ordinary Print.Context. It serializes
those actual units with EmitPack.encode and Pack.Writer under the actual current
module key; neither readiness nor fabricated unit text is installed. A fresh
ordinary Session receives the resulting pack bytes and runs the public gate.
Positive native-unit adoption must be observed; changed application deferred
obligations leave the same native row key eligible but refuse before adoption
or output. Invalid ABI/negative facts with otherwise valid envelope cannot be
adopted. The normal maker does not gain native selection or recipe authority.
Its ordinary-control pack bytes must compare exactly before and after extraction.

## 21. Canonical native fact Boolean (#1550)

A native_recipe positive answer is the exact byte1. The decoder must preserve
its raw byte until validity is checked; bytes2 through255 are malformed even
though they are nonzero. Other preexisting question formats are unchanged.
Valid-envelope raw-byte controls mutate only this byte, verify rejection, then
restore byte1 and verify acceptance. This format check is separate from current
attestation/readiness and cannot be described as a per-build proof.
