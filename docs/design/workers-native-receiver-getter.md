# Initial receiver API refinement

2026-11-01. Immutable addition to 114319e6 and 6a080fad; no implementation or tests run.

First slice is narrower than the optional known-return propagation described in 6a080fad: only an exact attested constructor result and simple source aliases. User function returns, formals, alternatives/joins, aggregate projections, Js.to/from and Host.Raw remain residual. No return-environment inference is required.

`ConstructorWitness { call: RealmBuild.CallId, result: PortId, binding: QualifiedDecl, digest: [32]u8, recipe: ConstructorAbi, nominal_owner: Graph.Index, nominal_type: Interface.TypeIndex }` is issued from an actual direct ContractUse after comparing its call/result/native_exec to the current Registry's checked declaration, type, recipe and winning supplier provenance. All source inputs come from the current validated RealmBuild/Input graph; no independent caller-supplied BIR can establish a witness.

`ReceiverRow { port: PortId, state: unknown|constructed, witness: optional WitnessId }` is owned by the preparation result. Builder retains a dense fixed descriptor `{ kind: unknown|alias|constructor_result, predecessor: PortId }` per source port. Source-local nonfunction let/local/top/import aliases are copied from exact original descriptor edges; constructor_result refers to the checked ContractUse result. No edges come from type equivalence, effect identities, emission liveness or exposure bits. O(P+C) slots/visits plus existing source lookup work; a single shared traversal for this native family, not one whole graph per native callable. Every allocation and visit is counted.

Iterative memoization propagates a witness only along alias edges ending at an actual constructor base. A visiting-cycle without a base is unknown; no guessed positive. First slice does not implement alternatives. If the producer exposes an alternative/join descriptor, it is unknown (not first/preferred predecessor). A future join extension must prove ALL alternatives, retaining their witnesses and activation/grounding, without manufacturing one constructor CallId for several calls. No favorable leaf shortcut.

`GetterUse { call: CallId, receiver: PortId, witness: WitnessId }` is checked only for the exact attested getter and direct saturated call. Receiver alias proof proves value brand; constructor/getter execution and retained/deferred obligations remain in current independent selected-use analysis. Current preparation returns no ready getter table on missing witness. No readiness is serialized or recovered from an old output pack.

Registered acceptance must include actual ordinary checked Js.to laundering source in cold/dev/release; failure precedes emission/adoption. Seed a valid output pack first, then change the receiver to the forged value: require no adoption and no new output; retained prior valid pack is unchanged. Include same-module unrelated genuine constructor, simple aliases of forged value, unknown return/formal/aggregate branches, and a cyclic alias mutation supplement. Positive direct/alias receivers exercise runtime getter access and evaluation order exactly once through existing JsIr/harnesses. None of these CLI cases has been executed yet; the getter does not exist.

This is the implementation boundary proposed for review, not authorization or a new HostFree/ownership guarantee. No temporary resources beyond this parent-owned note.

## Implementation authority (2026-11-01)

Part of #1585 / #1295 / PR #1304. Base bfa1d9e40ebbe7138d668f6886b4b42c246964b6.
The approved callable is `pub foreign impure encoding : TextEncoder → String`.
It reads the WebIDL TextEncoderCommon encoding attribute through the includes
edge of TextEncoder. The primary algorithm returns utf-8; unexpected host
failures stay defects. Source/effect/type/realm attestation is checked for each
of two indexed recipes. Constructor ABI1 keeps its existing semantics; getter
ABI2 is distinct. Exact boolean/ABI fact validation remains mandatory.

The source supplier has one immutable generated module containing both ordinary
foreign callables and the original opaque TextEncoder type. Registry publication
is atomic and precedes cache installation/reuse authority. No same-bytes physical
supplier acquires native authority. Ordinary String is the existing native string
representation. No Uint8Array, Buffer, Task storage or ownership change occurs.

Receiver preparation uses source-owned alias descriptors retained by RealmBuild;
no arbitrary independently supplied BIR or type-derived provenance is accepted.
A typed source call through Js.to remains opaque even though Lower erases the
conversion. The constructor base is not inferred from the residual witness or
Exposure's native-result bit. Getter emission is unavailable until exact receiver
proof and the current selected-use/retention gate both pass. Unreachable imports
need no emitted getter facade. Each live recipe has its own disposition/fact.

Receiver-alias recording is explicitly demand-only: RealmBuild.Input defaults
receiver_origins=false. Ordinary realm inspection and constructor-only emission
retain no alias sidecar and run no receiver pass. Emission requests it only when
the current Reach retains the getter; an absent requested sidecar cannot prove
a receiver. The same single graph then supplies all getter receiver witnesses.

## Exhaustive invocation coverage correction

The receiver gate enumerates **all selected getter calls**, not only the subset
for which the builder produced a receiver ContractUse. An owned dense CallId
index is constructed once from existing contracts, validating the exact
call/argument/result/native-execution joins and rejecting duplicate entries.
Every definitely selected getter invocation must find its unique contract and
constructor-result witness before exposure analysis or emit-pack adoption.
Missing contracts are receiver-unavailable. At strict-fix checkpoint405, implicit
field/method dispatch had no normalized receiver contract and was refused even
for a direct constructor alias. The following section defines the exact current
normalization; other missing contracts remain unavailable. Aggregate projections
never gain a construction witness from this normalization.
Explicit unary calls retain their supported direct/alias behavior. Original
evaluation dependencies are unchanged. Construction and checking cost O(C+K)
for original calls C and contract rows K, with one owned port slot per call;
there is no per-native graph expansion or new source cap.

## Exact implicit receiver normalization and totality metadata

The exhaustive selected-call gate remains mandatory. For the exact currently
attested `text_encoder_to_string` getter only, ordinary static dispatch supplies
the original BIR receiver in `field_access.lhs` or `method_call.lhs`. When there
are zero written arguments and the source-resolved callee is the attested native
execution, the builder records that exact receiver port in Call.argument and
ContractUse.argument. This is the same subject-first call shape as
Lower.receiverCall; it does not infer a receiver from a type or field spelling.
The existing constructor witness then accepts direct results/simple aliases and
refuses aggregate, formal, returned and cast origins. The original evaluation
edges and escapes remain present. No constructor or generic method gets this
new normalization. One contract per original call preserves O(P+C) storage and
work; missing/duplicate contracts still fail closed at the exhaustive gate.

Both canonical foreign impure schemes require `total=false`, independently of
their rung1 effect block. Scheme.total represents purity plus termination, not
merely non-suspension. Common fresh/cached attestation therefore rejects a
structurally valid true bit and rechecks source before installation. The public
IFC format and ordinary totality rules are unchanged.

The implicit normalization additionally requires the original source callee ref
kind `top` or `external`. Lower.methodCallExpr's `field` case calls a stored
function without prepending its record receiver; it must never use this static
receiver rule. Such stored-field calls remain outside this initial subset.
