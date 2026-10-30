# Worker realms: three compiler designs on the same census

2026-10-30. This is an **owner decision**, not adoption of a new checker.
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
Js.global/get/call is forbidden elsewhere. Each privileged wrapper states a
realm word. The wrapper implementation and its raw access contract remain a
reviewed promise, like today's foreign sibling: a false promise or misspelled
raw member inside that wall is not proved correct by ordinary typing. Literal
root/realm consistency can be checked cheaply, but that is not a proof of an
arbitrary received object's member. This is stronger than merely scattering
trusted realm words through ordinary code, and still has a larger trusted base
than B/C. Dynamic selection must choose typed wrapper operations, not grant
arbitrary strings authority. Beni-over-Js wrappers need the same operation-level
failure review as foreign functions; declaring a rung does not wrap exceptions.

**B — native table plus hidden value provenance.** Retain the previously
specified mechanism in workers §4: each relevant value has a native/plain/union/
unresolved descriptor alongside its beni type. Symbolic argument/result/capture
paths survive Js.Value/from/to, generic helpers, containers and closures. Literal
member access consults the native table; finite typed keys handle dynamic host
selection. Static-dispatch evidence and initializers export the same obligations.
This proves native member/realm availability through existing raw code, including
inside wrappers, provided the graph is precise enough. Unknown reflection fails
closed. The cost is a second shape-flow problem, sparse interface graphs and
precision diagnostics in addition to ordinary type inference. This option is
specified, retained and **no longer selected** pending the owner's decision.

**C — generated real beni native types and ordinary realm summaries.** Generate
nominal opaque native types and typed operations from the pinned IDL, inside the
platform wall. For example Browser.Host.Document exports type Document;
Browser.Host.Storage exports Storage. The native object itself is the value,
not a record containing it. Document.querySelector receives Document and returns
a typed nullable Element; generated callback arguments name their Event subtype.
Native inheritance uses generated explicit identity upcasts (for example to
EventTarget), rather than adding general subtyping or unsafe downcasts to beni.
Typed accessors/operations have source-local realm bounds derived from the native
table; ordinary call/evidence summaries intersect those bounds. There is no
parallel hidden native-shape graph through Js.Value. All expected operation
failures retain exact typed adapters, which IDL alone cannot generate completely.

I recommend **C**: it places object identity in the existing type system, catches
misspelled members and wrong receivers at ordinary call sites, and makes the
no-Js.Value public-boundary rule in #1277/#1278 apply consistently down to native
access. It has a larger deliberate source migration than B, including runtime
callback storage, and needs a generated-binding/lowering design. That is a cost
to measure, not a reason to pretend B is free or adopt C without the owner.

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

A Js.Value becomes a native type only through a privileged generated validator
with a typed mismatch result. The validator uses the native interface's actual
brand/acquisition contract, not a structural property-name test or unchecked
Js.to. Cross-realm objects require spec-valid branding, not an assumption that
instanceof the current realm's constructor always works. Ordinary applications
cannot manufacture a brand. DOM-created objects and native event callbacks
arrive already typed. Unanticipated validation/adapter faults remain defects;
no catch-all turns them into a mismatch. Platform-private expandos use typed
owner-managed storage/accessors with fixed keys; dynamic bookkeeping data is
separate from the native receiver. HostFree erasure of those owners is refused.

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

All three owe the same >250k LOC/s cold/core and 100k-line build benchmark,
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

A/C native handles lower to the underlying host object. Identity upcasts,
phantom/interface indices and typed selector dispatch specialize away; known
member accesses become the same direct host operation. No boxing, proxy,
runtime type dictionary, duplicate receiver object or registration table is
allowed merely for static typing. B's hidden descriptors also erase entirely.
Validators and exact failure guards remain only where the old operation already
required validation; static facts do not add dynamic validation at every access.
Unreachable generated bindings are not emitted. Dynamic heterogeneous selection
can need an ordinary case in all options; compare equivalent safe programs.

Release bytes must not grow because of typed handles. Each implementation must
add emit/release goldens for global acquisition, member get/set/call, native
return value, callback, typed container round-trip, inheritance upcast and dynamic
selector specialization. Compare emitted operation/identity and raw/minified/
brotli bytes against the same safe untyped baseline, with the same error guards.
No allocation may appear. Add execution fixtures proving receiver identity and
native failure behavior; output bytes alone do not prove semantics. No result
is claimed before these are built. A/B also retain high-level typed public APIs;
C makes #1277/#1278's no-Js.Value signatures consistent with the lower native
surface instead of requiring a second representation contract beneath them.
