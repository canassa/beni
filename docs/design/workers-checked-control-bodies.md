# Checked generated control bodies — bounded implementation contract

Specified 2026-10-31 before source implementation. Part of #1295/PR #1304,
following workers-continuation-plan.md sections 4–6 and the independent review
of typed-control-proposal.md. Prerequisite integration is tree
43cedeac98c3a94fa4680d8d6dd9f97803f188cd (fef928da4 plus frozen B patch
b4213661af49ec5babf86e04e7dc052916b26de0b64abd7903875da5680150bd).
B was accepted as 07cd108a9 after exact-tree gates and hard-budget validation
(see the 2026-10-31-2103 manager diary). This document authorizes no
production Task/Lower/Suspend switch and no C/HostFree/Wire/launch claim.

## 1. Exact milestone and five helper boundaries

The milestone is actual source BIR remainder and ordered capture VALUES →
ordinary generated control declarations → ordinary frontend/checker → independent
source-region rewrite validation → nonpartial hidden checked-body inspection.
Checking only signatures, an identity helper, a mock foreign operation, or a
body which omits the real source remainder does not satisfy it.

Five new implementation helpers, with small explicit plumbing in existing files:

1. check/ControlSourcePlan.zig: build(LiveInput) returns owned Artifact; ordinary
   scoped roots, source regions/captures/body instructions, codec and common
   install verification. LiveInput includes actual inst_type/local_type,
   decl_scheme/decl_body, authoritative lexical binder readings, Effects,
   callee evidence, source BIR and final crossing/identity authority.
2. check/ControlBuild.zig: produce(Artifact, source BIR, finite selected sites)
   returns owned Batch{ordinary Beni source, source→generated region/binder/
   operation/operand maps, source obligations}. It emits actual bodies, never
   certifies their correctness or substitutes custom type equality.
3. check/GeneratedUnit.zig: check(Batch, ordinary options) returns owned
   CheckedUnit{Session, actual checked BIR/Dispatch/Interface, diagnostics}.
   Its fresh independent Session uses SourceStore.addEmbedded for one owned APP
   body module plus the fixed APP bridge, with the existing core syntax option
   only for validated runtime production (§9), then ordinary Session.run. Source
   bytes outlive that Session. No mutation of live parallel Driver arrays. Generated options are rebuilt explicitly:
checked-controls=false and control-required mask empty, never inherited from
the source graph. Check validates any nonempty bitmap length equals Graph.count
before indexing; an invalid request bitmap is an explicit internal request error.
4. check/ControlProof.zig: verify(source Artifact+BIR, Batch, CheckedUnit)
   validates exact permitted operation/binder/operand rewrites and complete
   region coverage, THEN returns a body receipt. Ordinary checking remains the
   only authority for type/effect compatibility; rewrite validation independently
   rejects same-typed source substitutions and effect reordering.
5. dump/checked_controls.zig: prepare(checked receipt+source plans) returns owned
   rendered bytes; write only after source/generated diagnostics, ownership and
   provenance checks all pass. It consumes actual checked generated bodies.

New helpers stay below src/check's 1500-line limit. Module/Driver/Check/Dispatch,
dispatch_bytes/Incremental, Session/CLI/beni test registration receive narrowly
specified plumbing, not body-transform code. Existing Task/Ref/Suspend/Lower
production behavior and all default inspector/emit output remain unchanged.

## 2. Actual ordinary generated-unit route and batching

SourceStore.addEmbedded already accepts owned in-memory source. GeneratedUnit
uses Session.init with ordinary core-package checking and the same normal
checked-core pack, seeds the deterministic compiler-owned APP body and fixed
APP bridge with the existing core syntax option (§9), and calls
Session.run with no filesystem source paths. Standard lex/parse/bir Lower,
Graph.build, interface skeleton/Resolve, Types.build, Driver.go and Module.check
P1–P9 run. Ordinary effects/sync/generalization/exhaustiveness and enabled
own/own2 enforcement run; no forged module index, unchecked scheme stub, foreign
signature or equality-only 'check' path exists. Refs in the new graph resolve
from stable package/module/declaration identity; source Graph.Index/TypeId never
crosses into generated graph identity.

Ordinary Session ownership options must honor explicitly requested ownership plus
ownership_everywhere/records_in_place even without a platform chain. A missing
chain supplies no inPlace promise, but cannot nullify explicit everywhere
checking. GeneratedUnit sets ordinary ownership when that enforcement is asked;
it never writes Session.enforce_ownership directly or calls a private bypass.
Default chainless checking without explicit ownership remains unchanged.
The caller passes RESOLVED source session.enforce_ownership into the standalone
generated everywhere-enforcement option, preserving a source platform chain's
ordinary enforcement even though that chain is not copied into GeneratedUnit.
Receipts label resolved enforcement explicitly and render retained same-run own2
reports, including unchecked or unavailable coverage (§23). Enforcement is not
complete ownership proof; owningStorageProved remains false. Source-required
own/own2 diagnostics cannot disappear across the batch boundary.

One batch for all selected source modules/sites per hidden invocation, not a
fresh Session/core/graph per site. Core uses the ordinary pack once per batch.
Record actual batch/core checking counts and costs. More advanced immutable
pipeline sharing is not silently assumed; if ordinary pack reuse cannot meet
measured budgets, specify the necessary real shared boundary before restructuring.

First supported bodies use captured locals and ordinary primitive/core-visible
types/operations: atomic unit/scoped variables/known core primitives, plus the
first-order synchronous callback over those atomic roots. Known nested-function,
alias or other nominal capture shapes are explicitly uncertified in this first
producer; this is a supported proof-shape boundary, not source rejection or a
recursion depth cap. Primitive identity includes package AND actual core module,
not bare type spelling. Private imports/constructors/types, recursive local definitions,
locally polymorphic captures and unsupported regions produce explicit uncertified
hidden-query results. No foreign stand-ins or privileged source namespace.
A later internal declaration projection must retain real backing body/scheme,
visibility provenance and read coverage before those cases can be certified.
Unsupported is not missing evidence and is never certification or a production
fallback; ordinary source acceptance remains unchanged.

## 3. Source capture, finalization and certificate gate

Capture immutable roots while original Module's store is alive, after final P8
scheme/effect/identity/crossing publication. Any provisional region analysis may
happen after P6, but finalize against final P8/P9 roots and discard on later
module/dependency diagnostics. Do not retain Vars/pointers or require keep_stores.
Existing ContinuationPlan1 stays symbolic and byte-compatible in meaning.

Module type-clean publication is NOT ownership success. Source and generated
body-proof consumers run only after Driver.checkInner and requested ordinary
own/own2 enforcement, after all relevant diagnostics are available. Ownership
errors do not poison ordinary type evidence today: do not change that global
rule to make this receipt convenient. The receipt is withheld on either source
or generated ownership failure. Fresh/cached support must obey this same gate.

Use actual original source lexical binder pairings, not annotation names or
freshly inferred generic placeholders. One ordinary scoped writing epoch retains
owner published/body roots, site input/output, captures and source effect paths.
Original schemes, callback effects, where/kind/identity/crossing constraints and
poly suspension obligations remain authoritative and separately identified from
generated scheduler-body effects. No generated sync annotation may strengthen
an originally unresolved/suspending callback. Source capture publication includes
its actual Effects.Publication block and identity quantifiers. Before printing
sync for the first-used callee capture, resolve the retained ordinary effect path
to that exact captured function term in its source scheme and require that
class's sync bit. A body call's own=no bit alone is insufficient. Unresolved,
poly or suspending source callbacks are explicitly uncertified, never annotated
sync merely because capture position is zero. Additional capture binders remain
separate from unrelated owner parameters.

## 4. Finite region graph, liveness and source rewrite authority

Use distinct typed Scope/Site/Region/Capture/Operation indices, fixed SoA rows
and flat typed sidecars. Keep source declaration/inst/local identity and stable
source origins; never dense-ID hash maps, IR pointers or per-node allocation.

Partition source BIR control flow once per selected declaration into shared
regions at suspension/control boundaries. Compute lexical definitions/uses once;
backward liveness uses shared region/capture representation. Do not scan a whole
suffix for every site, clone overlapping suffix bodies or duplicate alias/type
graphs. Emit every selected source operation once in its shared remainder helper;
Direct and Parked paths call that SAME real helper. Successor edges carry ordered
actual captures/input values. Charge actual capture/argument edges separately;
retain sharing in capture-set roots instead of materializing every suffix set.
Construction bound: source instruction/def-use/control edges plus actual distinct
published capture/argument edges and scoped type evidence. No per-site whole-IR
scan or n-site×n-instruction remainder copying. Growing tests include long
OVERLAPPING tails, not just independent tiny declarations. More general loop
liveness needs its own finite bound before support expands.

Initial supported region is the actual straight-line remainder after a unit
suspension with local captured value/next and a saturated call/return. Definition,
use and source order are BIR facts. Captures are ordered by first source operand use (callee then arguments),
deduplicated by a dense epoch-marked local index; resumed input is separate. The map
retains source binding definition, original solved capture root, actual call
operands and source body region, not just capture display text.

ControlProof verifies each selected original operation is copied once, covered
by an explicitly permitted structural rewrite, or the exact consumed suspension
operation. Every covered source instruction must be accounted for; unlisted
omissions, duplicated/reordered effects, swapped same-typed local operands,
changed callees or changed literal values fail provenance validation. Checked
Nullary rewrites are interpreted through the existing Dispatch authority. New
generated slot/case/job scaffolding has explicit allowed tags and source-site
association. Validate actual generated BIR operands/binders, not a trusted
producer's self-reported source map alone. A changed generated body cannot reuse
an old receipt. Do not call this arbitrary program equivalence: the receipt says
source-region-mapped AND generated-body-ordinarily-typechecked.

## 5. Rank-one control and fixed source anchors

Generate ordinary Control a = Direct a | Parked (Slot a) and Slot a as ordinary
Ref.Ref (Maybe a). First source corpus contains real generic, Int and String
owners whose source remainder is next value after unit suspension. Generated
producer/consumer declarations retain that actual remainder/captured VALUES.
An explicit Direct/Parked model producer is ordinarily checked, but is not
Task.yieldNow's sentinel implementation; producerModelChecked and
actualTaskProducerProved remain distinct, the latter false.

Emit original generic owner annotations as rigid ordinary binders/constraints,
and fixed Int/String annotations for actual source sites. Generated helper
annotations are derived from those source anchors, not mutually inferred fresh
variables which can specialize together. A negative wrong-Slot test changes
ONLY the Int output expression/use to Slot String under unchanged rigid source
anchors: ordinary constructor/call/Ref.set body typing must reject it. A second
wrong-typed capture/callee operand must similarly fail ordinary body typing.
A same-typed captured-local substitution passes typing but MUST fail ControlProof
source-operation/operand mapping. These are deliberately different authorities.

The real helper captures Slot unit, Slot b, actual value:a and next:sync(a→b).
It evaluates the actual source operation and publishes its result to the exact
output slot. Missing input is an internal defect, never silent Nothing. An
ordinary Debug.todo path is permitted only in this nonexecuted prototype; it
cannot survive a production release switch or justify a Debug exemption.

Current Ref.get returns lent a and Ref.set stores consumed a; Ref's implementation
still erases through Js.Value. Unit input does not certify generic owning Slot
extraction, output/capture ownership or HostFree. Run applicable ownership checks
and report real failures. Complete proper typed owning Slot/closure mechanics
before production; no unchecked cast, raw field, copying fallback or ownership
waiver. An existing typed signature is only ordinary body typing evidence here.

## 6. Source/cache ownership and hidden output

ControlSourcePlan IS persisted as a new Dispatch private artifact, schema1;
bump dispatch18→19 and its build/core-pack/cache identities. It has exact states:
absent (capture not requested), complete (including complete-empty) and explicit
per-site unsupported within a complete inventory. 'Complete' means source-site
inventory/capture finished, NEVER body/type/runtime certification. Required
missing authority within a supported capture is an error, not unsupported.

The hidden --checked-controls invocation selects ALL source APP modules in that
check graph, excluding core/platform dependencies unless an explicit future
selection API names them. Before Driver starts, translate that deterministic
module selection into Check.Options.control_required_modules, a borrowed dense
bool array with exactly Graph.count slots (empty means no request). Driver passes
the module's request bit into Module.Input. Required sites are exactly the
module's current ordered EffectPlan sites with own!=no OR body!=no, including
function-definition sites inventoried explicitly unsupported by this first body
producer. A complete plan covers each such site once. No source instruction
index is guessed before source/checked EffectPlan authority exists.

The ordinary source cache key does NOT vary with this inspection request: new
format19 can hold absent or complete plan. Common candidate preinstall first
validates any present artifact structurally/against current BIR+EffectPlan. For a
required module, absent candidate control plan produces an explicit ordinary
source miss and live Module capture. A complete candidate with the exact
EffectPlan site inventory (even unsupported rows) installs without fresh source
checking. Thus the first query after an ordinary cache may recheck required
source modules; the second warm identical query has sourceChecks=0. Normal
no-request checking accepts absent and never labels it complete. A normal fresh
source edit may replace old complete metadata with absent; the next explicit
query then misses and captures again. The sourceChecks=0 warm guarantee applies
to ordinary cached ownership1 runs; ordinary ownership2 disables cache today and
retains that policy. No hidden store reconstruction or separate
source checker exists. Core pack source is reused once by the generated batch,
not invalidated or regenerated per site by this optional app evidence request.

Stable source BIR keys pin body origins; serialize ordinary private terms/text
identity, never Session Vars/TypeIds/Graph indices. Zero-site requested modules
publish explicit complete-empty; unrequested modules absent. Source error/dependency
taint discards usable source plan under the existing final clean gate. This
optional request state is not a proof cache and does not grant ownership success.

Common install validation checks region/capture bounds, owner/local definition
and source def/use coverage, site EffectPlan/callee agreement, ordinary lexical
scopes/kinds/arity/effect paths and source-BIR identity. Old/mutated bytes safely
miss/rebuild under existing Driver authority. No private unchecked decoder or
secret reconstruction from expired stores. Any capture-on-demand request which
needs a new artifact causes an explicit ordinary cache miss, not silently using
absent metadata. Source body edits invalidate maps even when public types match.

Generated remainder/control helpers are pub ONLY inside the isolated internal
GeneratedControls app unit, which is never installed as a user package/API.
Their ordinary inferred schemes/effects survive through normal Interface
publication after its Module store is released; no retained raw Var is needed.
The consumer prints the ACTUAL checked generated Interface roots/effect blocks
and Dispatch/BIR evidence, not source annotations or source-plan roots labeled
as generated inference. Private Control/Slot/Job identities remain ordinary
hidden nominal/alias references under that same generated unit authority.

First generated body checking runs explicitly on a hidden --checked-controls
query; it is not a source type-check rerun or a persisted bodyChecked flag.
Any future generated cache uses exact generated bytes+source body/plan revision+
checked dependency/effect revisions and normal install authority. Validate
provenance after ordinary generated checking even on hits. Pre-render the entire
new receipt only after source/generated typing/effects/ownership AND mapping
success. No partial positive output on missing evidence or either failure.
Unsupported shapes are explicitly uncertified; supported-but-failed generated
checking is failure; missing required authority is an internal evidence error.

Print actual generated checked decl/body IDs, source owner/site/region, copied
operations/ordered captures, source/generator schemes/effect identities and
producerModelChecked=true, actualTaskProducerProved=false,
runtimeRepresentationProved=false, taskMigrated=false, C=false, launch=false.
Leave old --continuations/default output unchanged. Ordinary wrong-Slot diagnostics
show generated spans plus source-origin mapping; do not substitute custom equality
messages. No public launch or Js conversion gate is enabled.

## 7. Production blockers and validation ownership

Generated closed unit jobs retain actual captures within ordinary closures and a
finite per-entry site union; no universal polymorphic a field. Distinguish
continuation/macrotask ⊤→⊤ jobs from scheduler ⊤→Bool jobs. Generic helpers remain
rank-one symbolic. Typed queue producers AND consumers must migrate together.

Production switch remains blocked on complete checked source regions/private
refs/generic owning extraction, joins and tail/building loops, sentinel payload
constructor/eliminator pairing and capture-before-invalidation, Direct no channel
read/no slot/frame/boxed-result allocation, realm instance isolation, stale/double
resume tokens, interruption/cancellation/finalizer failure/order, independent
schedulers and fatal deadlines. The representation pass consumes the EXACT
checked body; no separately regenerated unchecked JS or raw payload cast.

Required first actual registered blackbox cases: generic+Int+String body/capture
stdout; ordinary wrong-Slot diagnostic under rigid anchors; ordinary wrong-typed
capture diagnostic; same-type operand/order tamper provenance failure; unchanged
source scheme/effect transcripts; cold/warm/jobs1/8/roundtrip/relocation/errorrestore;
nonpartial missing-authority and failed-proof behavior; overlapping-suffix growth.
Supplement with hermetic rows/codec tests, explicitly register new namespaces in
src/beni.zig and test roots, and enumerate actual named runs separately from
import wrappers/shards. No tests were run in writing this contract.

Normal no-query emission/runtime bytes remain exact. Full unfiltered gates on
final integrated source; exclusive manager-granted measurements compare actual
Debug development compiler baseline/candidate, ordinary check vs generated-pass
cost, batch/core work, peak RSS/table/plan/cache bytes, and long overlapping sites.
Maintain >250k LOC/s and <800ms cold100k plus applicable existing ordinary budgets.
Later production work retains EVERY original individual dev/release/raw/Brotli
budget and VM allocation/runtime parity gate. Counters are not VM allocations.
No builds/tests/timings during the manager's quiet window; no budget waiver.

## 8. Hidden fault-injection boundary for actual negative tests

Only the explicit hidden checked-controls query accepts a tamper selector. The
ordinary generated checker still runs on the resulting REAL body. wrong-slot
changes only an actual Int site's output initializer to String under unchanged
source-rigid annotations. same-type-operand swaps two same-typed source operands
inside the real remainder. scaffold-return-slot returns a fresh same-typed Slot
instead of the Slot written by its job. The latter two must pass ordinary body
typing then fail source/scaffold provenance; they are not expected type errors.
Drop/duplicate region metadata fault modes retain the unchanged generated body
and must fail independent exact selected-site inventory validation. No fault
mode certifies source, bypasses checker/provenance, affects a normal query or
switches production runtime behavior. Full diagnostic and nonpartial stdout
receipts come from actual registered tests, never predicted outcomes.

## 9. Ordinary source-role correction: validated core syntax on APP bodies

Actual ordinary frontend tests reject explicit sync in APP declarations with
misplaced_sync. This is the existing intended rule, not a compiler regression.
The validated runtime-body producer uses the existing Session.options.core
syntax permission while retaining APP graph identity for ownership diagnostics.
Ordinary GeneratedUnit.check(source) remains APP with core=false and continues
to reject sync; it cannot promote arbitrary caller bytes into the runtime role.
No sync annotation is dropped or source privilege expanded to make typing pass.

The internal path is GeneratedUnit.checkRuntime(gpa, io, RuntimeSource, options,
diagnostics). ControlBuild.RuntimeSource names its produced Batch, exact original
checked inputs/interner and explicit test tamper mode. Before assigning any core
role, ControlBuild validates every source plan against its actual BIR/effect site
inventory and deterministically renders it again; bytes and batch members must
match the produced artifact. This constant second linear rendering is charged
and measured. It is producer-origin validation, NOT type checking or a receipt.
There is no general `kind=core`/`core=true` switch on arbitrary source-string API.
Only the bounded checked-BIR producer's fixed declarations/escaped operands may
reach this route; the first producer emits no foreign/native declarations.

The independent normal Session queues compiler-owned GeneratedControls.beni and
tiny ControlBridge.beni in package APP, with a normal import of GeneratedControls.
Session.options.core=true supplies the existing CLI --core syntax permission to
this isolated, validated source graph, including the fixed bridge. APP identity
keeps ordinary ownership diagnostics enabled; syntax permission is not an
ownership exemption. Imported Ref/Maybe retain CORE identity and the existing
core pack is reused once. Resolve the returned root by stable APP:GeneratedControls identity and
consume its ACTUAL checked BIR/Dispatch/Interface, not the app bridge's root.
Private helpers may be pub inside this isolated internal module solely to retain
normal published inferred schemes/effects. The module is never installed in the
user source Session or exposed as a public package/launch capability.

The first source-positive fixture uses the existing explicit --core role so its
source sync contract is legal and actually ordinarily checked. Retain the normal
APP misplaced_sync negative and a core→app warm-cache transition proving that
cached privileged evidence cannot grant an ordinary app a source privilege.
Callback sync still requires the exact source effect endpoint; a core role alone
is not a sync proof. Ref erasure/loan limitations and all storage/runtime/ownership
certification blockers remain unchanged. This correction introduces no source
language feature, native exemption, unchecked cast or ownership budget waiver.

Required own2 GeneratedUnit integration runs in registered packed-compiler
blackbox tests. The unit-test build intentionally has an empty core pack; actual
own2 whole-core sessions exceeded its existing 1000ms guard, so their failed
receipts are retained and coverage moves to the proper closed-binary boundary.
No guard increase, skipped enforcement or false claim of an own2 pass is allowed.

## 10. Declaration-relative BIR local authority

BIR local operands and pattern/LetDef local IDs are DECLARATION-relative;
Bir.locals and Module.local_type are module-flat. Capture identity therefore is
(source declaration, relative local), and definition/type reads use the actual
owner's locals_start + relative local. Validate relative < locals_end-locals_start
before adding. Dense marks and lookup slices use that owner's module-flat range,
never a relative integer as a module-global local or another declaration's root.
Generated helper and control local IDs likewise belong to their own declaration.
This refines existing lexical identity guarantees, not a source/language change.

## 11. Closed job field syntax and actual inferred effect evidence

The current grammar has no sync marker on an ADT constructor payload. Generate
Job's concrete closed callback field as ordinary (⊤ → ⊤), NOT a new field syntax
or a universal raw callback. The actual generated site lambda must independently
have own=no and body=no under its ordinarily checked EffectPlan before its
source/scaffold receipt is issued. Source callee sync annotations remain on the
legal core top-level parameters and still require source effect endpoint proof;
they are not removed. Absence of a lambda site means no under the existing
EffectPlan's deliberate no/no row omission, only because this is a fresh fully
checked generated module with complete ordinary effect planning. No standalone
field annotation invents scheduler or realm authority. This bounded per-lambda
fact is not a public generic Job storage contract, C proof or production Task
certification; the complete finite runtime executor/queue contract remains owed.

## 12. Actual sealed job result class; no default-no certification

A missing/default no EffectPlan row alone does NOT certify the closed job class.
Generate an ordinary core sync-receiving identity sealer and public per-site
job factory. The factory returns the actual lambda through that sealer; its
normal published Interface must expose the RESULT function's actual inferred
sync class, with no unresolved dependencies/sensitivity and no suspending rung.
The validator requires this exact RESULT path, not any matching-shaped function.
Generate an ordinary per-site sync-receiving Job packer as the only constructor
site, and validate the actual factory/packer/call/slot/capture relationship and
all Job construction sites. Every supported closed job must pass this gate.

The source remainder is still emitted once in restN. The job factory captures
its actual input/output slots and source values; Direct invokes restN directly,
Parked creates the job through the checked factory/packer. Ordinary top-level
sync parameters are existing core syntax; no Job field marker is added. Original
source callback sync authority is unchanged. If the ordinary solver does not
publish the required RESULT class, the body remains uncertified; no own=no,
absence, type-text assertion or private raw cast supplies a substitute.

## 13. Direct authoritative source roots instead of duplicated types

For the initial exact top-level-parameter domain, ControlSourcePlan owns NO copy
of an Interface/type/effect/quantifier graph. Its region.scheme directly names
the SAME Dispatch.continuations Scope.scheme of its exact source declaration.
Capture rows retain declaration-relative local, actual binding definition,
recomputed source parameter ordinal and TermIndex in that original scope.
Input is the exact original continuation site's type; output is the BODY bundle
slot1 function result; capture type is that BODY function parameter by ordinal.
Owner/body quantified kinds/where/identity/crossing/effect authority is therefore
preserved by identity, not a new comparator or reconstructed binder spelling.
This supersedes duplicated source-type storage described in earlier sections.

Build/cached coverage walks original ContinuationPlan scopes/sites in their
existing canonical ranges once. Compute one dense module-flat local→parameter
ordinal map from actual declaration parameter patterns/Local.inst definitions;
include unit patterns in the actual function arity and never assume local ID
is parameter ordinal. Source BODY roots must be admitted literal func nodes;
owner aliases/nonparameter captures stay explicitly unsupported initially.
Normal checked Nullary/site kinds and input unit types follow the actual saved
ordinary site, not source spelling or an assumed argument offset.

At installation recompute the admitted source shape and lexical parameter
projection, then require the EXACT expected scope/input/output/capture roots.
A stored region=none is legal only when this recomputation cannot admit that
source site. Downgrading an admitted site to unsupported, changing source capture
terms/output consistently, or duplicating/dropping selected regions fails common
install coverage and repairs from source. No per-site whole-body/capture scan:
source shape/body roots are prepared once per scope, captures once per admitted
shared region, and each actual site/header/edge is visited a bounded number.

Callee sync is looked up by the exact original source BODY slot1→parameter
ordinal effect path, never by TermIndex equality or matching function shape.
Actual alias steps are retained if/when that root shape is admitted; this first
literal-root domain does not transparently discard expansion steps to borrow
another callback's class. Two identical-signature callbacks with only one
source sync demand must remain distinct. No ordinary checking is rerun to create
this authority, no raw Var survives the live capture, and no source acceptance
limit or production fallback follows from unsupported proof shapes.

Private schema1/dispatch19 remain the pending, unaccepted format. Capture records
now contain the parameter ordinal and existing term reference; the header's old
standalone type-record length word is reserved zero, not an alternate type
language. Malformed old experimental records safely miss; no accepted format is
silently reinterpreted. Default absent and requested complete-empty stay distinct.

## 14. Ordinary display-root relationship is not structure-object equality

constrain/Decl.displayReading intentionally builds the same annotation tree over
the SAME checked rigid variables while never unifying its structural objects.
ContinuationPlan's BODY bundle may use that ordinary display reading. Therefore
live local/formal function-object Var identity is not a sound additional capture
check and must not be substituted for the ordinary declaration parameter binding.
While the store lives, require the actual local_type root to exist and retain
its defining BIR parameter identity; the original ordinary source checker and
its captured annotation/body binder relationship establish that parameter's
published BODY type. Project that exact original scope/parameter root. Do not
unify display structures, compare display-name spellings, or add a bespoke type
equality checker. All cache lexical projection/root/effect-path checks remain.

## 15. Actual generated Interface declaration provenance

Ordinary Interface.values is sorted independently from source BIR.interface.
The proof owner maps generated schemes using the normal resolver's actual
Interface.Provenance.value_decl table, not assumed source order or per-helper
name scans. Validate length, declaration bounds/kind/name and uniqueness once;
retain one dense declaration→ordinary SchemeIndex map for all factory/packer/
sealer/result-class reads. This is source provenance, not a binder/type equality
heuristic, and stays within the checked generated Session's lifetime.

## 16. Discharge retained checked sync dependencies; preserve their rows

The actual ordinary result class can be sync=true/rung=impure and retain a
dependency on its captured sync parameter. Raw dependency-list emptiness is NOT
the guarantee. Preserve every ordinary class/dependency row. Prove no unresolved
suspension by a bounded iterative walk of the finite class graph: validate every
index, reject rung2 and unsupported sensitivity, reject active cycles rather
than treating a repeated visit as safe, and memoize only fully proved nodes.

Every dependency must have an explicit witness: an exact generated factory
parameter path (param 2+capture index) with an ordinarily checked sync class,
independently matched to that capture's exact original source BODY parameter
path and sync contract, or a separately supported ordinary checked closed/pure
body witness. A class which merely has rung0/no dependencies is not a closed-body
witness; unknown input callbacks stay obligations. This first producer admits
the exact captured-callee path and checked constructed/sealed lambda root; other
closed-body cases remain uncertified until their actual witness is implemented.

Print raw result dependency count and each source-scope/parameter/class→factory
parameter/class witness alongside unresolved=0. Do not remove dependencies,
match by function shape/TermIndex, invent sync or infer C/realm/storage proof.
The retained source callback/effect obligations remain part of ordinary exported
schemes. Add real poly/suspending job negatives through the ordinary checking/
provenance boundary; no NoSuspend conclusion follows from EffectPlan omission.

## 17. One structured failure document

The hidden consumer collects every source-origin item before rendering. It exports
those items through `Session.exportLate` with owned arena lifetime spanning the
independent generated check. GeneratedUnit defers ordinary diagnostic rendering;
on failure it supplies these structured origins as `Session.foreign` and calls
`renderLate` exactly once. Actual generated type/ownership diagnostics remain the
ordinary held diagnostics, with their codes, messages and generated source spans.
A provenance-only failure renders all source origins in one source-session call.
No JSON parsing, array concatenation or replacement generic type error is used.
Success never prints failure-origin items. This rule applies to text and JSON.

## 18. Held warnings and the actual suspending-job negative

A checked-controls source run defers rendering, including without a platform.
Generated runtime success also holds its ordinary diagnostics. The consumer
exports those diagnostics with owned copies of paths/messages/source excerpts
into the command's arena; the final command render combines them with held
source warnings and any later platform diagnostics. No diagnostic borrows a
generated Session after its deinitialization. Failure combines source warnings,
mapped origins and actual generated errors in the single failure render.

The hidden `suspending-job` fault adds an actual `Task.yieldNow` operation inside
one generated sealed job lambda. Original source callback contracts are
unchanged. This is ordinary source checked by the normal sync boundary checker;
a successful positive receipt is forbidden. It tests the generated body, not a
fabricated effect-class row or a change to ordinary accepted source.

## 19. Explicit source inspection for every admitted or unsupported site

Successful hidden queries expose each authoritative source scope's owner/BODY
roots, exact lexical BODY-parameter effect paths, and every source site's
checked or uncertified state with its structural/callback/binder/type reason.
The scope/site traversal follows existing canonical flat ranges once; no lookup
uses function-type equality. Both sibling callback paths remain visible even
when only one is called. Original raw type/effect tables are emitted for zero
supported bodies as well. Such rows report source authority, never certification
of unsupported bodies or the production Task implementation. The complete
section is prepared before any query stdout is published.

Parameter inventory and effect-path inventory are distinct. Every direct
OWNER/BODY function parameter is exposed with its original term and lexical
ordinal, including unused callback parameters. Effect rows are printed only
when ordinary publication actually contains that path/class: unused poly
callbacks can have no BODY effect row. Absence provides no sync authority and
is never relabeled as a manufactured class; raw source tables retain the full
available representation. Source callback certification still requires the
exact present BODY path described above.

Success diagnostic export receives only ordinary held diagnostics from the
generated Session (`exportLate` with no late items). Their file order is already
sorted, and each file's excerpt buffer is the SourceStore's actual owned buffer.
Copy contiguous repeated source-buffer identities once, memoizing original
pointer+length and its owned copy. Messages/spans stay distinct; no source names
supply binder/type authority. Thus owned excerpt bytes are bounded by generated
source files with diagnostics, rather than diagnostic-count times module size.

## 20. Command publication and failure classification

Command owns an optional Prepared receipt until every requested platform load,
entry contract check and final structured diagnostic render succeeds. Only then
is the checked-control section written. Late platform errors publish no receipt;
stdout/stderr writer failures do not imply physical I/O atomicity.

Preparation explicitly reports whether an ordinary failure diagnostic document
was successfully rendered. Such actual generated/source errors remain intact,
with no appended fallback array. Unrendered evidence/proof failures receive one
ordinary structured internal diagnostic at `<checked-controls>` and exit1.
Inapplicable hidden faults are usage failures (exit2); allocation, worker/input
and I/O failures also exit2. When rendering is possible they receive one
structured diagnostic naming the actual error. A broken writer cannot promise
further diagnostic output; failed fallback allocation/rendering returns2.
Reporter tests exercise usable-writer allocation errors, a deliberately failed
render allocation, and an exhausted writer without changing any budget.

## 21. Standalone ownership enforcement exposes an existing logical summary limit

Clarified 2026-10-31 21:02 CET on Dagon after the final gate investigation (#1509).
Honouring explicit `--ownership-everywhere` without a platform chain must retain
ownership-checker §16.7's existing logical-entry limit of 262 144. It does not
turn that limit into a byte budget or a count of compressed storage nodes.

The unchanged pure tuple fixture `check/good/OwnershipAnnotationDag.beni` has
`t x = s (s x)`. Its normalized ownership summary has 1 276 786 entries, so
explicit enforcement must report `ownership_limit` at `t`, although the program
contains no list writes. The retained accepted baseline produces the SAME
1 276 786 / 262 144 diagnostic with `--platform=node`; its standalone invocation
previously passed only because a missing chain suppressed enforcement (#1509).
This is not new summary growth, a source-sharing error, or elapsed-time noise.

Keep the original fixture unchanged and assert the full existing diagnostic on
both standalone and platform-enforced routes. A separate smaller fixture ending
at `s` retains positive repeated-path/separation-comparison coverage. Neither
fixture may discard a path's guard, raise a cap, or bypass enforcement to pass.
Broad merging of annotation carriers is not justified by this regression:
condition identity and sharing across paths remain semantically significant.
No production ownership algorithm, summary representation, or budget changes
follow from this test correction.

## 22. Optional ordinary profile for the generated checking batch

Added 2026-10-31 21:20 CET on Dagon. When a checked-controls query has the existing
`--self-profile=<path>` option, its single independent generated checking Session
also uses ordinary profiling. Its file is the literal outer path followed by
`.checked-controls.json`; the outer profile remains at its original path. `-`
has no special meaning here, as in Session.writeProfile. The generated batch
borrows this derived path through its Session lifetime, including deinitialization.

The inner file is the ordinary Profile Chrome trace with existing phase events
and counters, including modules, embedded_modules, cache_hits and modules_checked.
Report actual generated-body/bridge check events and the existing counter
partition; do not invent counters or pin the size of the shipped core. This is
one generated batch, not one Session or profile per source suspension.

Without the outer option, generated profiling stays disabled: no derived-path
allocation, profile file, output change or enabled counters. An unsupported-only
query never starts a generated batch and therefore writes no inner profile.
Allocation or profile I/O failure follows the existing resource-error route and
prevents positive checked-control stdout; profile files already written are not
an atomic transaction. No CLI, type/effect rule, ownership authority, or runtime
behavior changes. This supplies §2's actual inner batch/core work evidence.

Profile consumers must choose fresh unique outer/derived paths for separately
measured queries. Unsupported-only means no inner Session or write: an existing
sidecar is neither removed nor overwritten, and is not evidence for the current
invocation. File absence demonstrates no new profile only with a fresh path.
Timed operations that do not request profiling continue to use self_profile=null.

## 23. Generated ownership enforcement and report authority (#1515)

The validated runtime producer uses the existing Session core option for syntax,
with GeneratedControls registered as APP and the fixed APP ControlBridge retained.
This is the ordinary CLI `--core` route, not Graph.Package.core: ordinary CORE
modules are pack inputs whose ownership diagnostics are not application reports.
Only deterministic validated producer bytes may select this option; arbitrary
GeneratedUnit.check strings remain APP with core=false. Imported Ref/Maybe retain
their real CORE identities. No ownership rule or enforcement exception changes.

Header sourceOwnershipEnforced/generatedOwnershipEnforced describe resolved
ordinary enforcement only. owningStorageProved=false remains explicit regardless
of checker selection. Under own2, retain and render the source and generated
modules' actual reports from their SAME ordinary checker run through the existing
ownership_v2_dump facility. Unchecked declarations/zero demands are visible, not
interpreted as full ownership proof; a missing retained report is unavailable.
Do not rerun a checker or parse report text to invent coverage authority. These
reports supplement ordinary body typing/source mapping; they do not certify
owning extraction, closure storage, or production Task.

A hidden ownership-conflict fault is generated canonically by the validated
producer. It adds an actual ordinary list mutation with a live alias, whose
ownership diagnostic must reject both own1 and own2 before ControlProof can issue
any receipt. This tests checkRuntime's real role, not only arbitrary-source check.
No positive stdout is permitted on that ordinary failure. Existing diagnostic
lifetimes, JSON framing, profiling, budgets and cache rules remain in force.

## 24. Bound Int suspension input (2026-11-01 refinement)

The next checked-body proof shape admits a single zero-parameter local definition
whose RHS is an actual ContinuationPlan suspension returning ordinary core Int,
followed by the existing saturated callback tail. Example, validated by the
ordinary Debug compiler before implementation:

```beni
pub joined : sync (Int, Int → Int), Task.Fiber Int, Int → Int
joined next fiber fallback =
    value = Task.join fiber
    next value fallback
```

The real BIR has let_def local3/value with RHS call16 and tail call20 using
next(local0), value(local3), fallback(local2). Its original scope scheme0 stores
site input term18 core Basics.Int, BODY output term16 Int, and exact sync callback
BODY parameter0 term12. Instruction/term numbers illustrate this fixture only;
the producer and common verifier derive identities from actual BIR/ContinuationPlan.

SourcePlan schema2 records discarded_unit versus bound_local, exact defining
instruction and declaration-relative local. Input remains the original site type;
output and capture types remain original BODY scope references. The resumed local
is separate from captures, and maps to its own generated remainder parameter.
The callback still must be an actual source parameter with its exact published
sync class. Other non-unit source shapes remain explicitly uncertified, without
source rejection, recursion/size caps or new type/ownership rules.

Both Direct payload and parked Just payload pass their exact generated local to
the shared real remainder. Ordinary checking checks rigid input/output types;
ControlProof separately checks the source definition/binder, every operand,
Direct/Just payload and exact input/output slots. Equal-typed fallback substitution
is a provenance failure even if typing succeeds. Original suspension is consumed,
not replayed; its Fiber operand is not a remainder capture. Every source definition
rewrite and retained operand is accounted for. Common install recomputes admission,
roots/bindings and inventory, rejecting region-none downgrade or tampered local.

This changes private Dispatch format20 to21, retaining the final realm_sources
column and ordinary public Interface18. Old SourcePlan schemas are cache misses,
not default binding guesses. SourcePlan and generated helpers remain one batch
with linear original instruction/operand/capture work; no copied type graph or
per-site checker Session. Existing unit bodies retain their behavior.

This is still the checked Direct/Parked MODEL supplied Control Int, not a proven
Task.join runtime producer. Ref.get remains borrowed input; no consuming Slot.take,
Ref rewrite, v2 implementation or owning/non-atomic extraction is authorized.
Actual ordinary APP+core-option GeneratedUnit checking and both requested ownership
modes remain unchanged, with same-run unavailable/unchecked coverage explicit.
actualTaskProducerProved, runtimeRepresentationProved, owningStorageProved,
taskMigrated, C and launch remain false. No production Task/Lower switch occurs.
