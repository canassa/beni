# Worker realms: three compiler designs on the same census

**Decided C, the owner, 2026-10-30, [#1315](https://github.com/canassa/beni/issues/1315#issuecomment-6525030806).**
C is the contract in workers.md §4. A and B below record the comparison only.
The owner selected protocol rows without language changes in #1319 and shared
wire names in #1305; those are no longer open choices.

## What the owner decided

A realm is a JavaScript execution environment with its own global APIs.
A page and a worker are different realms: a page has the DOM and localStorage,
while a worker does not.

All three options provide this application guarantee: **a worker build never
calls an API unavailable in a worker, and misuse is caught at compile time.**
Option A relies on audited platform implementations to make that promise true.
Options B and C also check native access inside those implementations.

### Same platform code under each option

These are proposed beni fragments inside the platform package, not executable
examples of today's API. Storage access can be denied by browser policy, so
the typed operations return Result StorageError (Maybe String). Native helpers
below represent the same exact policy guard; none catches an unknown defect.
A's manually audited ManualStorage.localItem and B's guardedStorageItem invoke
the acquisition callback inside their guard. Each handles
the specified SecurityError from the localStorage getter separately from getItem.
It never evaluates the getter before entering the guard. Unknown exceptions
remain defects. The C helper performs the same guarded steps. A passes typed Element to its
manually maintained wrapper; B directly accesses a Js.Value receiver whose
origin the hidden analysis must prove. This is the key implementation difference.
The DOM operation reads textContent. Both snippets require a page realm.

**A: manually maintained typed wrappers.** The platform author writes and audits typed
wrappers and their realm metadata. ManualStorage.localItem contains the deferred
localStorage getter and its precise guard. ManualNode.textContent is another wrapper;
its body performs the raw Node textContent read. An application calls
the exported wrapper. The manually authored wrapper signature is checked; its raw implementation
still needs review. Its hypothetical realm contract is privileged metadata,
not accepted beni syntax. The snippets contain no realm metadata.

```text
pub readTheme : ⊤ → Result StorageError (Maybe String)
readTheme ⊤ = ManualStorage.localItem "theme"
pub text : Element → Maybe String
text element = ManualNode.textContent element
```

**B: hidden native information follows each value.** The platform keeps raw Js
expressions. The checker traces the receiver from localStorage and the DOM
acquisition or caller argument. It infers the page requirement.

```text
pub readTheme : ⊤ → Result StorageError (Maybe String)
readTheme ⊤ = guardedStorageItem (λ⊤ → Js.global "localStorage") "theme"
pub text : Js.Value → Maybe String
text element = nullableString (Js.get element "textContent")
```

**C: generated typed browser operations.** The platform author calls generated
operations. There is no raw object cast. The Element upcast is explicit because
textContent belongs to Node. Storage.localItem is the typed composition of
Window storage acquisition and getItem, including their exact error adapters.

```text
pub readTheme : ⊤ → Result StorageError (Maybe String)
readTheme ⊤ = Storage.localItem "theme"
pub text : Element → Maybe String
text element = Node.textContent (Element.toNode element)
```

For an application worker calling readTheme, the proposed diagnostic text is:

- A: `worker_realm_violation: Jobs.handle calls readTheme, which requires Window; this entry runs in DedicatedWorker.`
- B: `worker_realm_violation: Jobs.handle → readTheme → localStorage requires Window; this entry runs in DedicatedWorker.`
- C: `worker_realm_violation: Jobs.handle → readTheme → Window.localStorage requires Window; this entry runs in DedicatedWorker.`

For the same worker reaching inline text through a callback, the text is:

- A: `worker_realm_violation: Jobs.handle reaches Inline.text through a callback; Inline.text requires Window.`
- B: `worker_realm_violation: Jobs.handle reaches Node.textContent through Inline.text; the receiver comes from Window.document.`
- C: `worker_realm_violation: Jobs.handle reaches Node.textContent through Inline.text; Node is unavailable in DedicatedWorker.`

These are specified diagnostic goldens for future implementation, not output
claimed from a probe. The source span and shortest call chain accompany each.

### Costs before choosing

**C introduces two concepts.** HostFree checks that data contains no browser
objects or erased functions. Host.Raw is an opaque type for unknown values
received from the browser, which must be checked before use. They need language
and checker specifications, tests and interface support.

Core Task and the renderer must retain real callback types instead of putting
functions in Js.Value. The existing census counts **130 erased-callable use
sites**, including **41 in core/Task.beni**, **11 in
platforms/browser-inline/Inline.beni**, and **12 in platforms/browser/Rt.beni**.
The remaining 66 are in the other platform and core files listed in the census.
These are apply or construct expressions classified mixed. They are not counts
of callback storage declarations or erasure-producing conversions. Js.from and
Js.to were outside the census primitive list. The storage rewrite's size is
unknown; a typed queue and callback producer audit is the first migration task.

Beni has no subtyping. C therefore needs explicit conversions from Element to
Node and from Node to EventTarget. A source-reviewed projection of the inline
census has **32 native-operation sites requiring at least one upcast: 12 in
Browser/Navigation.beni and 20 in Inline.beni**. Each is listed in
[inline-upcasts.csv](workers/inline-upcasts.csv). This projection keeps element
helpers typed Element, event traversal typed Node, anchor detection typed
HTMLAnchorElement, and the navigation click typed MouseEvent. Generated methods
live on their declaring interface; mixin members are projected onto their
implementing interface. Some conversions traverse two inheritance edges.
One operation can require both a receiver and argument conversion. The count
is operation sites, not conversion expressions. Generic helper call boundaries
and checked downcasts are additional work and are not included. Sharing a
converted local or choosing a different helper type changes the source edit
count. This is a stated migration plan, not a language-intrinsic minimum.

C also needs a Zig WebIDL binding generator. The pinned package has **346 IDL
files, 2,782 declaration blocks and 11,620 member rows**. The complete
[count receipt](workers/binding-surface-counts.json) records every block and the
counting method. That is 8,257 interface, mixin and namespace member rows plus
3,363 dictionary fields. The generated surface must cover them, merge partials,
expand includes, and add typed inheritance conversions. Overloads, enum and
callback types, getters and setters, checked adapters and name collisions still
need generation rules. Generated declaration count and bytes are **unknown
until that generator is measured**. The 102 worker-specific blocks in the
older inventory are not the size of this full binding package.

**B keeps most raw expressions but adds a second analysis beside type checking.**
It follows native objects through aliases, containers, callback captures and
generic calls. The census identifies 24 dynamic native selections requiring
rewrites. The other 702 native or mixed sites retain expressions but need flow
proofs. Precision loss can reject valid code. Interface graph size and analysis
time must be measured; the fixed five-byte descriptor target excludes those
graphs. There is no generated public binding package, but a pinned native table
and precise error adapters are still required.

**A has the smallest compiler addition and the largest audited promise.**
Authors maintain wrappers for 556 native sites and preserve typed callbacks and
containers at 170 mixed sites. The wrapper declarations must cover the same
native surface as C, manually rather than through the proposed generator.
Wrong code inside an audited raw wrapper can invalidate its promise. Callback
storage changes remain necessary outside the trusted boundary. Moving more
runtime code inside that boundary reduces migration only by increasing the
amount that ordinary checking cannot prove safe.

### Decision and next action

The owner chose C. Native objects stay visible in ordinary types, so wrong
receivers and members are caught without a second hidden shape analysis.
#1295 first measures the Task and renderer callback-typing migration, including
the 130 erased-callable uses and the 41 Task sites. Then it specifies and measures
the generated package, HostFree and Host.Raw. No measured rewrite size is claimed.

The implementation must retain **>250k LOC/s** and the **emit/release/** byte
goldens for equivalent native operations, callbacks and explicit upcasts.
No wrapper or registration table may appear merely for static typing.
#1297 through #1300 implement the runtime on this gate. Callback obligations
use protocol rows and v2 inferred summaries under the decided #1319 contract.
#1296 and #1300 implement and measure the shared names selected in #1305.
A and B do not receive implementation slices.

2026-10-30. The following is the retained comparison; C is now adopted.
The complete [census](workers-host-and-wire.md#1-host-access-census-before-choosing-a-mechanism)
counts 556 definite native sites, 170 caller-dependent sites and 2,130 portable
receiver operations. [realm-options-migration.csv](workers/realm-options-migration.csv)
assigns an action under each option to all 726 native/mixed rows, preserving
file, line, declaration, receiver and classification reason. No site count is
an estimate of changed lines, generated bindings, engineer time or checker speed.

The pinned WebRef/BCD receipts and native algorithms remain the primary evidence
in [the original research](workers-api-research.md). WebIDL supplies interfaces,
Global/Exposed, inheritance/includes, overloads, callback and member types; prose
still supplies failure predicates and native state constraints. None of these
options makes an interface exposure proof into a browser-support guarantee.

## 1. The three candidates

**A — manually authored typed wrappers at a privileged boundary.** A small
platform surface exposes opaque native handles and typed operations. Containers
and callbacks keep those real beni types outside the boundary. Raw native
Js.global/get/call is forbidden elsewhere. Each privileged wrapper would supply audited realm metadata. The wrapper implementation and its raw access contract remain a
reviewed promise, like today's foreign sibling: a false promise or misspelled
raw member inside that wall is not proved correct by ordinary typing. Literal
root/realm consistency can be checked cheaply, but that is not a proof of an
arbitrary received object's member. This is stronger than merely scattering
trusted realm metadata through ordinary code, and still has a larger trusted base
than B and C. Dynamic selection must choose typed wrapper operations, not grant
arbitrary strings authority. Beni-over-Js wrappers need the same operation-level
failure review as foreign functions; declaring a rung does not wrap exceptions.

**B — native table plus hidden value provenance.** The compared, unadopted mechanism would give each relevant value a native/plain/union/
unresolved descriptor alongside its beni type. Symbolic argument/result/capture
paths survive Js.Value/from/to, generic helpers, containers and closures. Literal
member access consults the native table; finite typed keys handle dynamic host
selection. Static-dispatch evidence and initializers export the same obligations.
This proves native member/realm availability through existing raw code, including
inside wrappers, provided the graph is precise enough. Unknown reflection fails
closed. The cost is a second shape-flow problem, sparse interface graphs and
precision diagnostics in addition to ordinary type inference. This option was not adopted.

**C — generated real beni native types and ordinary realm summaries.** Generate
nominal opaque native types and typed operations from the pinned IDL, inside the
platform wall. For example Browser.Host.Document exports type Document;
Browser.Host.Storage exports Storage. The native object itself is the value,
not a record containing it. Document.querySelector receives Document and returns
a typed nullable Element; generated callback arguments use their declared IDL types. EventTarget
callbacks declared as Event stay Event. Richer event-name/subtype bindings need
a pinned prose event map and checked native branding; an event-name String
is not permission to cast an arbitrary Event.
Native inheritance uses generated explicit identity upcasts (for example to
EventTarget), rather than adding general subtyping or unsafe downcasts to beni.
Typed accessors/operations have binding-local realm bounds derived from the native
table; ordinary call/evidence summaries intersect those bounds. There is no
parallel hidden native-shape graph through Js.Value. All expected operation
failures retain exact typed adapters, which IDL alone cannot generate completely.

The owner selected **C**: it places object identity in the existing type system, catches
misspelled members and wrong receivers at ordinary call sites, and makes the
no-Js.Value public-boundary rule in #1277/#1278 apply consistently down to native
access. It has a larger deliberate source migration than B, including runtime
callback storage, and needs a generated-binding/lowering design. That remains a cost to measure as an acceptance gate, not an undecided choice.

## 2. What each proves

| Case | A: wrapper boundary | B: hidden provenance | C: generated native types |
|---|---|---|---|
| Wrong receiver/member | Caller signature catches wrong handle; typo/lie inside raw wrapper can escape | Table checks receiver shape and literal member, including wrapper body | Generated symbol/type checks receiver/member; no raw typed-host access bypass |
| Dynamic names | Select typed operations; raw privileged implementation is audited | Finite literal/key union checked against receiver shape; unknown String rejected | Case over typed operations or homogeneous generated selector type; no unchecked String-to-member cast |
| Callback | Typed boundary signature/effect summary outside wrapper; wrapper must deliver promised native type | Infer argument/result/capture native shapes and effects | Callback argument/result and captures have ordinary native types/effects; generated trampoline preserves them |
| Container | Typed handles retained outside wrapper; raw internal storage trusted | Descriptor paths/joins follow raw native-bearing storage | List/record/Ref/native typed container carries element type; heterogeneous storage uses a typed union |
| Static dispatch | Evidence links typed wrapper's declared realm | Evidence also carries hidden flow summary | Existing evidence schemes carry native types and ordinary inferred realm mask |
| Initializer | Reachable initializer calls intersect declared realms | Also analyzes hidden native flows | Ordinary typed initializer graph intersects member/call realm masks |
| Reflection/erasure | Unchecked native reflection confined to audited boundary | Unknown reflection becomes unresolved, not portable | Raw conversion requires host-free data evidence; typed native object/callback cannot erase to Js.Value |
| Limit | Wrapper promise may lie | Precision loss can reject valid code; explicit typed recovery needed | Generated declarations/privileged validator can be wrong; pin/validate generation and test native adapters |

Under C, Js.Value represents plain dynamic data, not an existential native
handle or an erased callable. Its conversion intrinsics require structural
`HostFree` evidence: no native handle or callable in any reachable field,
container or opaque representation. This is a memoized type-graph judgment,
not a value-flow pass; unknown type variables retain an obligation. Callable
storage stays typed (including callbacks that capture nothing but call a DOM
operation), so a callback's realm/effect cannot disappear into raw data.
Internal queues/Task/renderer records that currently erase callbacks must use
typed records, typed closure unions or ordinary polymorphic containers. They
still lower to their existing arrays/objects; no wrapper allocation is added.

Unknown native intake uses a separate privileged opaque **Host.Raw** token,
not Js.Value. Generated WebIDL any/object results, foreign unknown values and
unknown callback arguments enter this quarantine; ordinary known IDL types
arrive typed. Raw cannot be passed to Js.from/to/get/call, generic data helpers,
ordinary containers or public platform APIs. Private typed quarantine queues
may own Raw while awaiting validation, without exposing its payload. Its only
eliminators are generated native validators or checked data-acquisition adapters.
This is an explicit nominal type boundary, not hidden provenance through Value.

A native validator returns Result NativeValidationError Document (or its own interface)
using a spec-valid brand operation, not a structural property test or unchecked
Js.to. Cross-realm objects do not rely on instanceof the current realm's
constructor. Native brands are privileged; ordinary applications cannot create
them. If an interface has no sound non-invoking brand check, generic raw intake
returns RawValidationUnsupported and only its trusted typed acquisition path
is exposed. This does not remove that interface's typed constructors/methods.
Unknown validator faults remain defects, never a broad mismatch catch.
The private generated signature spells both expected outcomes explicitly:

```text
type NativeValidationError = NativeMismatch | RawValidationUnsupported
validateDocument : Raw → Result NativeValidationError Document
```

The validator is impure; it executes only the selected native brand operation.


Plain Js.Value enters generic helpers only through a data proof. Safe primitive
intake is separate from aggregate intake. A trusted JSON parse or native clone
deserialization path can certify plain aggregate production, after schema and
native-handle checks; arbitrary foreign objects cannot claim that certificate.
There is no universal non-invoking Proxy detector. If proving a raw aggregate
would require an untrusted accessor/proxy trap, keep it Raw or return the typed
UnsupportedRawData outcome. Do not invoke the trap and then pretend the object
was proven safe. Native brand/schema operations use only their exact documented
predicates; trusted acquisition is not an unchecked raw-to-Value alias.

Thus old untyped Js.Value native intake migrates to Raw followed by validation;
a genuinely plain Js.Value cannot secretly contain a native object. Creating a
native object from plain data uses its typed factory, not a cast. Generated
known callback parameters arrive typed; any/object parameters follow the same
quarantine and validation rules before reaching ordinary app callbacks.

Platform-private expandos use typed owner-managed storage/accessors with fixed
keys; dynamic bookkeeping data is separate from the native receiver. HostFree
erasure of those owners is refused. ECMAScript builtin function namespaces and
method values also stay typed under C; Math or a captured builtin callable is
not a plain Value loophole. Known portable primitive/string/array operations
still lower directly, and typed internal container representations can carry
callbacks without erasing their schemes. This extends the portable-container
migration caveat below; it is not another hidden value-shape analysis.

Generated operations carry the native identity in a checked platform binding
artifact: IDL interface/member/overload, beni signature, realm set, effects,
expected-error adapter and direct-lowering recipe. The generator is Zig and
outputs beni declarations/artifact data, not handwritten JavaScript. Loading
validates these rows against the pinned native table and resolved declarations;
ordinary packages cannot author them. Hand-authored high-level modules can
compose these typed operations without duplicating the hidden system from B.
Missing native prose failures are tracked before exposing an operation.

## 3. Exact migration accounting

The CSV's rows are the migration unit. A site can share a changed helper or
annotation with another row, so totals must not be called edit-line counts.

| Planned obligation | A | B | C |
|---|---:|---:|---:|
| Definite native expressions redirected to typed operations | 556 wrapper calls | 24 dynamic selections; 532 other native expressions retained | 556 generated typed bindings/accesses |
| Caller-dependent callable sites | 130 typed callback bridges | 130 expressions retained, checked flow summaries | 130 retained typed callable paths, eliminating erasure |
| Other caller-dependent sites | 40 typed validator/container bridges | 40 expressions retained, checked flow summaries | 40 typed container/input-validation paths |
| Total native/mixed sites with a concrete migration/proof obligation | 726 | 726 | 726 |

The 556 native sites are exactly 112 literal globals, 3 dynamic globals,
373 literal members, 21 dynamic members and 47 value operations. For B this
migration plan deliberately replaces all 24 dynamic host selectors with explicit
finite selectors, even where a future analysis might infer the finite strings;
that makes the change count reproducible. The 532 other native and all 170 mixed
expressions can retain their spelling, but their declarations/interfaces still
gain B's summaries. A and C redirect all 556 and retype the 170 mixed paths;
this includes caller/parameter/callback declarations, not just access syntax.

The 2,130 portable receiver operations remain data operations under all three.
That does **not** promise 2,130 untouched lines: a portable container storing a
native handle/callback must become typed under A/C, whereas B follows it with
hidden paths. Those extra declaration/storage edits are dependency consequences,
not additional native access sites. Their final edit count is unknown until the
migration is built; it is not substituted for the exact 556/170 census counts.
No rule moves the runtime to handwritten JS or exempts it from the new guarantee.

## 4. Compiler, interfaces and incremental cost

| Work | A | B | C |
|---|---|---|---|
| New analysis | Boundary access gate + ordinary realm-mask fixed point | Native shape/path/union constraints and SCC solving alongside realm masks | Ordinary nominal types and generated member checking + realm masks + HostFree type SCC judgment |
| Binding work | Hand-authored typed wrappers and audited primitive contracts | Pinned native table, intrinsic transfer summaries, shape projections | Zig IDL binding generator, signature/overload validation, erasing lowering recipes |
| Interface payload | Existing type/effect scheme, realm byte, privileged-contract revision | Realm byte + 32-bit flow-graph reference and variable sparse graph; Wire separate | Existing nominal schemes/ordinary evidence, realm byte; native binding identity/table revision; memoized HostFree fact |
| Cache invalidation | Changed wrapper type/bound/contract invalidates reverse users | Changed exported paths/shape/table invalidates reverse users; same summary body change does not | Changed native signature/member realm/adapter contract invalidates imported binding users; ordinary changed exported type/realm invalidates reverse users |
| Main cost risk | Manual boundary completeness; growing wrappers | Union/path growth and widening precision, especially generics/closures | Generated surface size, overload resolution and migration to typed containers |

Realm masks use the fixed native universe and a monotone O(V+E) graph pass
(with a fixed small number of bit removals). C adds no per-expression hidden
shape node: the ordinary interned type already identifies the native object.
HostFree is O(T+F) over solved type nodes/field edges with SCC memoization,
sharing representation traversal with Wire where possible. Generated bindings
are loaded on demand from indexed artifacts; importing Document must not check
the entire IDL corpus. Overloads use bounded indexed candidate sets followed by
ordinary arity/type constraints, never an unbounded speculative solver. A can
have the smallest compiler addition, at the cost of the largest audited promise.
B's earlier five-byte fixed summary target excludes its variable graph payload.
C's extra fixed realm byte excludes ordinary native type schemes and binding
artifacts. None of these is a measured total memory or speed claim.

C must meet the same >250k LOC/s cold/core and 100k-line build benchmark,
including cold/warm caches, peak RSS, interface/artifact bytes, generic callback
chains, native containers, static dispatch and 1/10/100 entry graphs. Run C both
with a tiny binding subset and the entire generated native package indexed.
Report generation time separately from incremental user checking. HostFree and
Wire generic obligations must not repeatedly traverse the same type graph.
A budget failure is an issue, not permission to weaken checking or erase types.

## 5. Same mistakes, diagnostics and emitted cost

| Mistake | A | B | C |
|---|---|---|---|
| Worker calls Window localStorage | worker_realm_violation at typed wrapper call | worker_realm_violation with hidden receiver/call path | worker_realm_violation at typed Window/storage operation, ordinary evidence path |
| Misspell localStorage in raw implementation | Not necessarily caught; wrapper audit required | unknown_host_member from native table | Unknown generated member/symbol; suggestion from Window's typed surface |
| String chosen as native property | forbidden_raw_host_access outside wrapper | dynamic_host_name, show known shape and typed key fix | Type mismatch: expected typed selector/operation, got String |
| Erase Document through generic record | Allowed only inside audited wrapper wall | Retains hidden shape; downstream access checked | host_value_erasure at Js.from/to, with offending field/type path and typed-container fix |
| Raw data used as Document | Boundary validator required | unresolved_host_provenance or native-shape mismatch | Expected Document, got Js.Value; point to privileged validated acquisition |
| DOM effect hidden in callback/evidence | Boundary's declared effect/realm chain | Callback shape/capture witness | Ordinary callback/evidence realm witness, never an untyped erased function |

A and C native handles lower to the underlying host object. Identity upcasts,
phantom/interface indices and typed selector dispatch specialize away; known
member accesses become the same direct host operation. No boxing, proxy,
runtime type dictionary, duplicate receiver object or registration table is
allowed merely for static typing. B's hidden descriptors also erase entirely.
Validators and exact failure guards remain only where the old operation already
required validation; static facts do not add dynamic validation at every access.
Unreachable generated bindings are not emitted. Dynamic heterogeneous selection
can need an ordinary case in all options; compare equivalent safe programs.

Release bytes must not grow because of typed handles. The C implementation must
add emit/release goldens for global acquisition, member get/set/call, native
return value, callback, typed container round-trip, inheritance upcast and dynamic
selector specialization. Compare emitted operation/identity and raw/minified/
brotli bytes against the same safe untyped baseline, with the same error guards.
No allocation may appear. Add execution fixtures proving receiver identity and
native failure behavior; output bytes alone do not prove semantics. No result
is claimed before these are built. A/B also retain high-level typed public APIs;
C makes #1277/#1278's no-Js.Value signatures consistent with the lower native
surface instead of requiring a second representation contract beneath them.
