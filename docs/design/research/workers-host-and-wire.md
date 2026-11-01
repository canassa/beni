# Workers: measured host access and emitted representations

**Decided by the owner, 2026-10-30:** [C for realms](https://github.com/canassa/beni/issues/1315#issuecomment-6525030806)
and [shared wire names](https://github.com/canassa/beni/issues/1305#issuecomment-6525031242).
The source census and emission measurements below remain evidence. Historical
provenance analysis and universal codecs are compared alternatives, not adopted.

2026-10-30, source revision `ff8e02df3` (compiler code `4215e996f`).
This supplements the retained [primary-source inventory](workers-api-research.md).
All commands and probes ran on Dagon in the isolated workers-design-fix lane.
The compiler probe is beni, compiled by a locally built Debug compiler; emitted
output was inspected, not handwritten. No browser timing result is claimed.

## 1. Host-access census before choosing a mechanism

[host-accesses.csv](workers/host-accesses.csv) records each occurrence with
file, line, primitive, name class and syntactic receiver origin;
[host-access-counts.json](workers/host-access-counts.json) contains the totals.
The scan recursively covers every `.beni` in the three directories, lexes
comments and strings out of code, and counts calls to Js.global/get/set/call/
apply/construct/at/setAt/method/each (including nested calls separately).
It includes data-only accesses: this is the complete candidate access surface,
**not** a claim that every get reaches a browser object. Other Js conversion,
reflection and foreign paths must retain native types under C (§2).

| Source | Operations | Literal global | Dynamic global | Literal member | Dynamic member | Value operation |
|---|---:|---:|---:|---:|---:|---:|
| browser-inline | 321 | 52 | 1 | 184 | 15 | 69 |
| browser | 1,100 | 92 | 2 | 736 | 15 | 255 |
| core | 1,435 | 137 | 0 | 969 | 21 | 308 |

A value operation has no named-member argument (apply, construct, at, setAt,
each); `method` creates a callback receiving native `this` and is also a
value operation. C retains the receiver and callback types; B would have tracked hidden provenance. Dynamic member means its name is not one
string literal at that syntax site, even if later inference proves a finite
set. Get/call totals alone are 184, 634 and 807 respectively. These totals
supersede the brief's approximate counts because the scope is recursive and
includes all selected primitives. Foreign token counts are 3/19/71, including
native type declarations; those counts are not all foreign functions.

| Receiver origin (syntactic, disjoint) | inline | browser | core |
|---|---:|---:|---:|
| Global selector itself | 53 | 94 | 137 |
| Immediately nested Js.global result | 39 | 74 | 133 |
| Direct declaration parameter | 109 | 450 | 558 |
| Local/computed value | 120 | 482 | 607 |

The lexical parameter row includes plain data; it is not a native-host count.
A second source review classifies every row's receiver and records its containing
declaration, source line and reason in
[host-access-classified.csv](workers/host-access-classified.csv), with totals in
[host-access-classified-counts.json](workers/host-access-classified-counts.json).
It follows local allocation/return shapes and helper contracts: for example,
Rt's slot records are plain data but their node fields hold native objects;
Inline's tableOf uses Array.from on DOM queries; Http's reader result is a plain
iterator-result record and its value is Uint8Array; Log.console binds `out`
to the console root before selecting its method from Level. Native URL.parse,
Headers.has/get/set/iteration, Response.text and Node.compareDocumentPosition
are classified by receiver provenance, not by familiar method names. Form.elements
and select.options are native collections; composedPath and Array.from results
are plain arrays. Inline.adopt/madeOf retain querySelectorAll NodeLists through
page/made/push; only tableOf materializes its array. The $a anchor expando
belongs to native Elements. roots accepts a caller-supplied element collection
and is mixed, rather than falsely assuming every renderer collection is Array. This is a reviewed
source census, not output from the proposed checker.

| Receiver/operation class | inline | browser | core |
|---|---:|---:|---:|
| Native host receiver/root | 180 | 329 | 47 |
| Portable data/ECMAScript/beni runtime record | 127 | 715 | 1,288 |
| Caller-dependent callable or generic raw-value helper | 14 | 56 | 100 |
| Total sites | 321 | 1,100 | 1,435 |

The 170 mixed sites are classified, not unreviewed: stored/passed callables
need their callee/capture effects; generic Schema/Debug inspection needs the
input's host provenance; a guarded Error/DOMException or Promise callback can
have different native/data origins. There is no single context-independent
native count for these polymorphic definitions. They are not marked safe.
The classification provides **556 definite native sites**, 2,130 portable
receiver operations and 170 input-dependent sites. Portable receiver does not
mean a whole expression is realm-free: Object helpers and plain container
fields can carry a native value or invoke a callback, whose obligations must
still propagate. Each nested host operation has its own row.

| Native sites by source of receiver | inline | browser | core |
|---|---:|---:|---:|
| Global lookup (literal / dynamic) | 34 / 1 | 63 / 2 | 15 / 0 |
| Immediate global result | 23 | 47 | 12 |
| Given declaration parameter | 52 | 93 | 6 |
| Traced local/computed native value | 70 | 124 | 14 |
| Native sites with dynamic global/member names (overlaps rows above) | 8 | 14 | 2 |

Thus 151 definite native sites receive their object directly as a parameter;
another 208 reach a traced native local/computed value, often returned from a
helper or callback. The JSON also splits every mixed/data site by those origins,
so none of the original 1,209 local/computed sites disappears into a remainder.
For example, the 15/15/21 dynamic-member sites divide between native controls,
history and console versus generated record fields and generic schema input;
only the former need finite native member keys. This is why a literal-global
check or blanket ban on dynamic record names would be wrong.

The three dynamic globals are inline/Listen.beni:17 and browser/Listen.beni:24,
34, all selecting `target`. Dynamic members are Navigation (one per platform),
Inline/Rt (14 each), core Log (2) and Schema (19). Navigation/renderer helpers
must preserve host receiver shapes; Schema's field names on proven plain data
remain legal. Log's selected console member must become finite checked keys.
Listen takes typed Window/Document/worker targets instead of a global-name
String. Event-name strings remain ordinary method arguments and are supported.

The existing-module audit in research §8 identifies URL preparation's hidden
`document.baseURI` dependency and DOM-bearing event values. The 151 definite native
parameter sites plus traced locals and mixed callbacks explain why foreign tags or literal-global-only
checking cannot establish the promised guarantee.

## 2. Mechanism, migration and budget

[Workers §4](../workers.md#4-a-realm-check-that-covers-beni-over-js) specifies C,
selected by the owner. The [comparison](workers-realm-options.md) retains A and B
as alternatives not adopted. Native identities are ordinary generated types;
realm requirements follow ordinary call and evidence summaries, not hidden
shape provenance through Js.Value.

Migration first measures the Task and renderer callback storage rewrite. The
census counts 130 erased-callable use sites, including 41 in core/Task.beni;
it does not count storage declarations or Js.from conversion producers. Audit
those before estimating the rewrite. Generated operations replace native raw
access, while HostFree prevents erasure and Host.Raw quarantines unknown intake.
Plain dynamic data remains supported. The three dynamic globals become typed
target selection; dynamic native members become cases over typed operations.

Realm masks use a byte plus ordinary inferred obligations. C has no B-style
32-bit host-flow graph reference. Wire plans retain a classification byte and
interned selective-normalization plan reference. Generated binding artifacts
load by demand; type SCCs memoize HostFree and Wire. Measure >250k LOC/s, the
100k-line build target, cold and warm latency, interface bytes and peak RSS.
Cover callbacks, recursive typed containers, 1, 10 and 100 entries, shared wire
graphs and static dispatch. Native types and identity upcasts must preserve the
emit/release/ byte goldens. Changed native metadata, exported summaries, entry
rows or wire plans invalidate reverse users; unchanged summaries do not.

## 3. Current emitted layouts, inspected rather than assumed

[emission-evidence.json](workers/emission-evidence.json) records the complete
beni probe, commands, hashes and byte counts. Build `Shapes.beni` with
`beni build Shapes.beni --platform=node --library --out=dev`, then the same
with `--release --out=release`. Development Shapes is 1,861 bytes, release
698; all `.mjs` modules total 6,944/2,002 bytes (maps excluded). These measure
this baseline library only, **not** either proposed worker optimizer.

| Beni value | Actual development representation | Release and structured-clone verdict |
|---|---|---|
| Int/Float/Bool/String/unit | primitive number/boolean/string/null, per backend §4 | Clone unchanged; null is unit, not a callable value |
| Plain record | own fields `count`, `label` | Library preserves public names; app build can rename fields. Clone preserves current fields, but independent builds need compatible names |
| Tuple | ordinary object with `a`, `b` slots | Same structural layout in probe; clone-safe recursively |
| Union/Maybe | object with `$` tag string and `a` payload; Empty/Nothing padded with `a: null` in probe | Public library tags retained; internal app tags may rename/flatten. Clone-safe only under matching layout, without singleton identity assumptions |
| Nominal/opaque Box | `$: Box`, `a` payload; equality functions live separately | No own method; clone-safe if payload is, and type contract permits crossing. Nominality alone is not a codec requirement |
| Materialized List | native array | Clone-safe recursively, subject to shared names in elements |
| Current List view | object with `b`, `o`, `length`, `p` and **function-valued `$plain`** | Same method-bearing view under minification: direct clone fails. Materialize/rebuild via representation plan |
| Current Dict | plain tagged Dict/Node/Leaf tree; node color/key/value/children in slots | Clone-safe if keys/values are. Inspect `_core/Dict.mjs`; no native index in today's implementation |
| Current Set | tagged wrapper around that Dict tree | Same conditional clone safety |
| Functions, closures, Task/fiber/scope/resume values | callable or runtime-owned graph | Not Wire; state-local only |
| Native opaque handles | native interface-specific | Inventory decides clone/move/unsupported; GPU device and WASM instance are not wire data, Wasm.Module has prose-defined serialization |
| Raw Js.Value | unconstrained | No derived Wire evidence; explicit typed native/data boundary required |

`backend.md` §4 specifies newer list views and ordered Dict `{entries,index}`
with native Map. Those are intended, not today's tree. Map itself is clonable:
its presence does not prove that every Dict needs a codec. If an index depends
on identity, receiver reconstruction must preserve the key/index invariant;
the type/representation proof must establish it. Hidden methods, caches or
native resources must be inspected individually, not generalized from a name.
The application release golden `tests/corpus/emit/release/app/SpecRecordLambdaField.js`
renames record `tag` to `a`; library exports pin names and cannot demonstrate
independent-entry compatibility. Optimized-away fields need no wire identity,
but an escaping payload cannot be eliminated merely because local reads are gone.

## 4. Owner decision: pay where representation actually requires it

**Decided: shared wire-visible names within one build, with selective
normalization.** Plain data then pays native serialization/deserialization only.
Keep explicit schemas/version validation at external or cross-build channels.
This is the selected contract against an unconditional extra traversal,
not a measured claim of parity with SolidJS 2 or Effect v4.

| Cost | Universal canonical codec | Shared wire-visible names + normalization |
|---|---|---|
| Simple payload CPU | Encode walk + native clone + decode walk | Native clone; checks/fingerprint still apply |
| Allocation | Canonical graph before send and local graph after receive, unless proven fused | No extra graph for clone-stable shapes; normalize affected paths only |
| Payload size | Canonical fields/tags independent of local naming | Common field/tag assignment; may lengthen names due to cross-entry interference |
| Optimizer | Independent entry layouts; extra codec code/roots | Union naming constraints for wire-visible fields/tags; keep DCE/inlining and non-wire naming independent |
| Hidden representation | Specialized encoder/decoder | Same required normalization, not blanket permission to clone opaque internals |
| Cross-version peer | Canonical format still needs version/schema compatibility | Explicit external schema or declared stable protocol, never assume build-local names match |
| Compiler cost | Derive/memoize codecs for each concrete representation pair | Derive/memoize clone-stability plus normalization; global wire-name allocation phase |

An O(N) encode/decode pass adds up to two payload graph walks and allocations
on top of the browser's clone; absolute cost, fusion and compression need a
real implementation. The current compiler has neither multi-entry alternative,
so a fake handwritten JS codec benchmark would not answer this decision.
The beni probe establishes current shapes and bytes only. #1296 and #1300
implement shared names and measure them on the corpus: raw/minified/brotli bytes per entry and unique
build total, compiler time/RSS, cold/warm ready, p50/p95/p99 send-to-reply,
allocation/GC, frame stalls against the SolidJS 2 harness and effects overhead
against pinned Effect v4. Include empty, nested records/unions, arrays/list
views, tree/ordered Dict, cyclic native graphs, cloned/moved buffers, 1/10/100
entries and deliberately conflicting short names. Publish browser/machine,
payload counts and raw samples. Universal codecs are not adopted. The measurements validate the selected
shared-name design against budgets; they do not choose a design.
