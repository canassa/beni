# 34 — Compiled schemas in JavaScript

Research, 2026-09-22. This is evidence for the open schema-representation fork,
not a schema specification or permission to implement it. The benchmark lives
in [`bench/schema-libraries`](../../../bench/schema-libraries/README.md).
This work changes no production compiler, core, platform or project-build file;
only benchmark research, this report, queue/diary records and source-submodule
pointers are in scope.

## 1. Question and measurement contract

Should Beni's proposed `schema` declaration compile to specialized code, or
elaborate to an interpreted library? Report [32](32-schemas-at-effect-parity.md)
describes the intended library surface; [33](33-schema-prototype.md) establishes
that two endpoints can be represented in ordinary Beni, but does not establish
production context guarantees or representative performance. Its roughly
110 ns trivial round-trip is not a comparator for these JSON workloads.
Report [28](28-jsx-in-beni.md) separates declarative syntax from the compiler's
ability to specialize its implementation. This investigation makes the same
distinction for schemas.

The discipline is report [29](29-rendering-strategies-measured.md)'s:
**orderings and per-operation medians, never a single ratio or a geometric mean
of ratios**. A vendor's throughput claim is not evidence here. Neither a fast
success case nor a large bundle alone decides the language's representation.

The full contract was written before timing in
[`PROTOCOL.md`](../../../bench/schema-libraries/PROTOCOL.md). One committed
payload set is shared by all subjects. Decode includes JSON parsing, strict
validation and construction of the renamed program value. Encode validates the
program value before renaming and serialization. Unknown properties are errors;
there is no coercion or defaulting; integers must be safe integers and numbers
finite. Native failures are normalized to structured paths, not host prose.
Native parser cloning remains part of a library's cost.

| Workload | Shape | Wrong type / missing key / unknown key |
|---|---|---|
| flat | Eight declared fields, two renamed keys, optional nickname | age / email / unexpected |
| list | 1,000 flat records | item 777 age / item 333 email / item 999 unexpected |
| union | 1,000 values across four tagged variants | item 776 user.age / item 501 count / item 999 unexpected |
| tree | Binary tree, depth 8, 511 nodes | depth-8 label / depth-4 id / root unexpected |
| typeahead | Report 32 §5.11 response, 20 hits | hits[17].title / total / hits[0].unexpected |

The three invalid forms are different fault locations, **not** a complete
Cartesian product of every fault kind at every depth. The eight-field record
has seven required fields and one optional. The typeahead's `hit_id` maps to
program `id`; `total` is required here, rather than defaulting to zero as in
report 32, to honor the no-defaults protocol. Keys are reordered in additional
untimed checks. Unsafe/fractional integers, null optional fields and non-finite
encode values are also checked.

Renames use a common mapping pass after native validation. This equalizes the
work but **does not measure native fused transformation codecs**. FJS is a
serializer, not a strict validator: its encode row explicitly includes the
hand-written guard. There is no FJS decode result. The JSON floor intentionally
does no validation and therefore accepts the semantically invalid JSON inputs.

The hand-written row is straight-line shape-specific validation and
serialization, without a schema interpreter or dynamic code generator. It is
the requested compiler-emission reference. A library ahead of it triggers an
equivalent-work audit; a hand-written JavaScript program is not a mathematical
lower bound on all possible generated programs. Such orderings must be retained
and explained, not erased to manufacture a ceiling.

Each timed cell warms up in fixed batches with convergence recorded, then takes
35 samples. Nine fresh workers run serially: three groups, three repeats each,
with deterministic rotation of library order. Within each group/cell we retain
the lowest repetition median, as requested for this machine's scheduling noise;
all samples and all raw-process orderings remain available. This selection is
optimistic and need not select the same physical process for every cell.
The common sink observes shallow output shape; strings contribute their length
and end characters rather than length alone, without recursively walking
decoded data. Its small cost is included for every row. This observes character
access but does not measure UTF-8 byte materialization or network transmission;
we do not claim a portable guarantee about V8's internal string representation.

The machine is an Apple M2 Pro, 12 CPU cores, 16 GiB RAM, macOS arm64. Node
**24.19.0** comes from `nix develop`, not the host installation; esbuild is
**0.28.2**. The capture includes the exact V8 version and power snapshot. It ran
on AC power with AC low-power mode disabled, under `caffeinate -i`. We did not
change persistent power settings. macOS does not expose a supported per-process
P-core affinity or fixed CPU-frequency control here; frequency, thermal state,
OS activity and core scheduling were **not controlled**. A timing flake seen on Apple
Silicon is the reason for repeated processes, not proof that every fluctuation is E-core
scheduling. Source builds and the project gates completed before timing.

Gross and net-of-JSON costs are both reported. Net is a **difference of measured
medians**, not an isolated validation benchmark or a paired confidence interval.
On decode, the floor returns wire shape while codec rows return mapped program
shape, so the shallow sink observes slightly different key names; subtraction
does not perfectly remove identical downstream work.
Encode failures do not serialize: subtracting successful `JSON.stringify` in
those rows is a counterfactual comparison and can be negative. It is not a
negative execution time or “validation-only” cost.
The encode floor receives the committed wire object, selected outside timing;
other encoders receive the program value and pay for the rename. Thus the valid
floor serializes the same keys and payload, without measuring a rename itself.
Invalid variants likewise use each path's committed wire object, but only valid
encode has exactly the successful output payload and bytes; failure subtraction
remains counterfactual.
An initial partial run used program keys for this baseline; it was stopped and
discarded before a complete capture, then the entire matrix was restarted.
A later complete diagnostic capture exposed a different reporting defect during
review: the flat-only entries for four baseline libraries imported generic
schema builders that retained unrelated array, union or lazy branches. That did
not change the steady-state adapters, but it overstated those browser bundles
and their aligned cold imports. The raw diagnostic capture is retained as
`preliminary-results.json.gz` (uncompressed SHA-256
`ca533054fd99f7bce232c5d800125420032d2778fe3c3057f0447174b8c16861`) and is
excluded from every conclusion below. After specializing only those flat entry
schemas, the entire single-command capture—not just startup and bundles—was run
again so this report does not splice observations from different captures.

One terminology correction matters: `JSON.stringify` is the requested
serialization **baseline**, not an inescapable physical floor. Typia, FJS and
the hand-written serializer emit JSON directly and need not call it on the
whole value. Likewise, “hand-written ceiling” names our reference implementation,
not proof of an optimum. A negative net encode value or a library ahead of that
reference is an audit trigger, not by itself proof of missing work.

Startup is measured separately in fresh processes, not charged to steady-state
cells. Browser ESM bundles are real esbuild outputs, minified and tree-shaken
for the flat workload only, with Brotli quality 11. CSP probes disable string
code generation in Node; they are not an HTTP browser-policy test and do not
measure fallback performance. Optional Chrome and practitioner-comment research
are outside the primary evidence.
“Cold” here means a fresh module cache, not a flushed OS file cache, cold disk,
browser network transfer or browser startup. Flat-entry import includes its
schema construction; the separate full-adapter observations split import,
construction/compile and first call. Default Zod may defer generation until
that first call. Fresh-process startup has three observations, not the 35
steady-state batch samples.

## 2. Versions, builds, and compilation mechanisms

Source provenance and pinned build commands are recorded alongside the harness.
The existing Effect submodule is not re-pinned. “Compiled” is not one category:
build-time generation, runtime generation, cached interpreter closures and
native serialization have different startup, CSP and dynamic-composition costs.


| Subject | Version / tag | Commit | Build used |
|---|---|---|---|
| ajv | 8.20.0 / v8.20.0 | `0fba0b8e649909613cfce0999b149cd08f4a4987` | source-built |
| typia | 15.0.0 / v15.0.0 | `78124b0523b4e989aedb64fe4cd4e1fd59c44a2d` | source-built |
| typebox | 1.3.34 / 1.3.34 | `5177875a4854e5cf2c49d0b8f938704ca79205ae` | source-built |
| arktype | 2.2.3 / arktype@2.2.3 | `03b1f015d9b7c5af5dac2caed1aeedefaf705ab3` | source-built |
| fast-json-stringify | 7.0.1 / v7.0.1 | `6aa2ed4cc403cf68d7c31ee4dd14724372fea664` | checked-in JS |
| zod | 4.6.5 / v4.6.5 | `59bbc03e10c636b9eb3c393dfeb552819774ec21` | source-built |
| valibot | 1.5.0 / v1.5.0 | `5016198907beb383f5a6d8bbcb4c7f1586d7c6a3` | source-built |
| effect | 4.0.0-rc.116 / existing pin | `3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5` | source-built |

All eight subjects use submodule source artifacts; there is no published-runtime
substitution. Typia and Effect staging uses identical-version registry manifests
for published export layouts, **not registry implementation files**. The root
lockfile pins harness tools; upstream workspace locks govern direct-source
transitives. Ajv's tag has no development lockfile, so its source build is not
fully transitively reproducible. FJS's checked-in JavaScript needs no compile step.
See [source build commands](../../../bench/schema-libraries/scripts/build-sources.sh)
and [provenance](../../../bench/schema-libraries/provenance.json) for tools,
entry hashes and the complete build outcomes. Dependencies were installed inside
the respective submodule trees; only pointers are committed. Source pointers are
commit `c5ba612`; all eight measured implementations come from those source
trees, with no published-package implementation substituted.

**Ajv 8.20.0.** Ajv lowers JSON Schema to JavaScript source, optimizes that
source, and calls `new Function` to construct the validator at runtime
([source](https://github.com/ajv-validator/ajv/blob/0fba0b8e649909613cfce0999b149cd08f4a4987/lib/compile/index.ts#L160-L180)).
That ordinary row therefore requires dynamic code generation. Its standalone
mode serializes the same generated validation functions as an ES module
([source](https://github.com/ajv-validator/ajv/blob/0fba0b8e649909613cfce0999b149cd08f4a4987/lib/standalone/index.ts#L29-L66));
construction needs code generation, but the emitted module's validation calls
continue functioning when string code generation is blocked.

**typia 15.0.0.** `validateEquals<T>` is intentionally only a transform marker:
the untransformed runtime function throws
([source](https://github.com/samchon/typia/blob/78124b0523b4e989aedb64fe4cd4e1fd59c44a2d/packages/typia/src/module.ts#L501-L529)).
The TypeScript 7 / `ttsc` transform replaces the marker ahead of time with
specialized validation code, so steady-state validation does not use dynamic
code generation and continues functioning when string code generation is
blocked. The tagged source explicitly labels
TypeScript 6 plus `ts-patch` as the typia 12 legacy path and says not to mix it
with the current toolchain
([source](https://github.com/samchon/typia/blob/78124b0523b4e989aedb64fe4cd4e1fd59c44a2d/website/src/content/docs/setup/legacy.mdx#L5-L19)).

**TypeBox 1.3.34.** This is the current `typebox` package, not the legacy
`@sinclair/typebox` package; the compiled API is `Compile` from
`typebox/compile`. `Compile` constructs a `Validator`
([source](https://github.com/sinclairzx81/typebox/blob/5177875a4854e5cf2c49d0b8f938704ca79205ae/src/compile/compile.ts#L36-L52)),
which builds source and evaluates it when the environment permits, but falls
back to the schema engine when evaluation is unavailable
([source](https://github.com/sinclairzx81/typebox/blob/5177875a4854e5cf2c49d0b8f938704ca79205ae/src/schema/build.ts#L43-L71)).
The value row is interpreted; the compiled row is normally generated and has a
built-in fallback rather than failing construction when string evaluation is
blocked. Its environment check attempts evaluation once before choosing that
fallback.

**ArkType 2.2.3.** ArkType normally precompiles schema traversals at
construction and binds the generated functions onto each node
([source](https://github.com/arktypeio/arktype/blob/03b1f015d9b7c5af5dac2caed1aeedefaf705ab3/ark/schema/scope.ts#L179-L203)).
Compilation calls a dynamic `Function` constructor
([source](https://github.com/arktypeio/arktype/blob/03b1f015d9b7c5af5dac2caed1aeedefaf705ab3/ark/schema/shared/compile.ts#L113-L126)),
but the default configuration probes CSP and sets `jitless`, which skips
precompilation
([probe](https://github.com/arktypeio/arktype/blob/03b1f015d9b7c5af5dac2caed1aeedefaf705ab3/ark/util/functions.ts#L95-L109),
[fallback](https://github.com/arktypeio/arktype/blob/03b1f015d9b7c5af5dac2caed1aeedefaf705ab3/ark/schema/scope.ts#L712-L716)).
It is therefore runtime-generated normally and continues through its
interpreter fallback when evaluation is blocked, although the capability probe itself attempts
`new Function` once.

**fast-json-stringify 7.0.1.** The library writes a serializer body and creates
the executable serializer with `new Function`
([source](https://github.com/fastify/fast-json-stringify/blob/6aa2ed4cc403cf68d7c31ee4dd14724372fea664/index.js#L200-L240)).
It is therefore runtime code generation and fails when string code generation
is blocked. It does
not natively satisfy this investigation's symmetric validation/error contract,
so the strict encode row is named `fast-json-stringify+handwritten-guard`; the
guard is a declared deviation and must not be attributed to the library.

**Zod 4.6.5.** Zod's default object parser is hybrid, not purely interpreted:
it emits a shape-specialized fast path and enables it when JIT is configured and
evaluation is available, otherwise it calls the generic parser
([source](https://github.com/colinhacks/zod/blob/59bbc03e10c636b9eb3c393dfeb552819774ec21/packages/zod/src/v4/core/schemas.ts#L2352-L2392)).
The benchmark therefore exposes the normal `zod` row and an explicit
`zod-jitless` interpreter baseline. That row uses the per-parse `jitless`
option, which selects the interpreter but does not avoid the cached capability
probe performed while the schema is initialized. Only global jitless skips the
probe
([source](https://github.com/colinhacks/zod/blob/59bbc03e10c636b9eb3c393dfeb552819774ec21/packages/zod/src/v4/core/util.ts#L517-L530)).
The caught probe and fallback make validation work under CSP, but may still
produce a browser `securitypolicyviolation` event.

**Valibot 1.5.0.** Valibot interprets a composed schema: the measured strict
object schema loops
over entries, invokes each child schema's `~run`, accumulates structured paths,
checks undeclared keys, and returns the dataset
([source](https://github.com/open-circle/valibot/blob/5016198907beb383f5a6d8bbcb4c7f1586d7c6a3/library/src/schemas/strictObject/strictObject.ts#L89-L235)).
There is no generated validator in this path, so construction is composition
and does not attempt string code generation.

**Effect 4.0.0-rc.116.** The measured default uses cached interpreted entries:
the registry starts with compiler adapters disabled, lazily compiles the AST to
interpreter closures, and caches them by AST
([source](https://github.com/Effect-TS/effect/blob/3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5/packages/effect/src/internal/schema/compilerRegistry.ts#L33-L86)).
Effect also has an opt-in compiler registry with fast decode operations and
interpreter fallback
([source](https://github.com/Effect-TS/effect/blob/3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5/packages/effect/src/internal/schema/compilerRegistry.ts#L88-L145)),
but that distinct compiled configuration is not a row in this matrix. The
default row does not attempt string code generation.


### 2.1. Explicit departures and configuration costs

- Latest Typia 15.0.0, released on the investigation date, uses TypeScript 7.0.2
  with `ttsc` 0.28.1. **The owner approved latest Typia with its supported `ttsc`
  transformer on 2026-09-22**, superseding the original `ts-patch` requirement:
  ts-patch 4.0.1 fails with TS7, and TS6 reaches an incompatible Typia15 plugin
  descriptor. This is a current-release transformer candidate, not an
  untransformed runtime shim and not evidence for an older ts-patch release.
  No older release was silently selected. Source builds and emitted proof
  succeed with the approved native toolchain.
- Typia uses `validateEquals`, `finite:true`, `undefined:false`, exact optional
  properties and safe-integer tags. Its normal surplus-key count shortcut loses
  the offending property's path. A **never-valued template index signature**
  preserves closed-object behavior on the measured JSON values while requesting native per-key diagnostics;
  its extra valid-path key traversal is included. This is documented in the
  [proof](../../../bench/schema-libraries/typia/README.md), not a hand-written
  validator or post-hoc guess of the key. The emitted
  [flat validator/serializer](../../../bench/schema-libraries/typia/generated/flat.js)
  is the transformer evidence.
- TypeBox's current `Compile` API replaces the prompt's legacy `TypeCompiler`
  spelling. Both Value and Compile use the same JSON Schema shapes. On failure,
  Compile falls back to native interpreted error production (and checks again);
  that cost is retained. `maxErrors:64` ensures the selected union branch's
  native fault exists before branch-noise normalization. Both TypeBox and Ajv
  complete native union validation and error production before normalization
  filters to the discriminant-selected `oneOf` branch: unrelated native issue
  records are omitted from common output, but their validation and allocation
  work remains in failure timing.
- Ajv uses `allErrors:false`, `strict:true`, `coerceTypes:false`,
  `useDefaults:false`; standalone is generated from the same configuration.
  Union error normalization retains the discriminant-selected native branch,
  not the unrelated failed alternatives of `oneOf`. Native `oneOf` validation
  can still do more union work than Zod's discriminated union before that
  normalization; this is the measured configuration, not a universal property
  of either library.
- Zod uses the standard `zod` v4 export. The direction-specific flat entries
  tree-shake the requested API, but this investigation does not separately
  measure `zod/mini` and makes no minimal-Zod or recommendation claim from it.
- The shared contract requires a fault path, not identical prose or identical
  numbers of native issue records. Valibot aborts early; Effect uses
  `errors:"first"` and `onExcessProperty:"error"`; other native diagnostic
  machinery is retained. Duplicate issues at the same path are allowed.
- Outside JSON-shaped data, Ajv and both TypeBox rows accept a **present optional
  key valued `undefined`**, contrary to the absent-or-string rule. Separate
  untimed encode probes record that deviation; no manual guard hides it.
  The tested key `unexpected` valued `undefined` is rejected by every validating
  row in its final configuration. This is not proof for all JavaScript-only
  keys/values and does not introduce JavaScript undefined into Beni.
- Reviewing Typia's emitted `never` branch found a further JS-only hole:
  `null !== value && undefined === value` accepts an undefined-valued key matching
  the never-prefix. The adapter subsequently drops it. Thus the declared `never`
  type is not a guarantee of the generated runtime behavior. This is a separate
  upstream finding, not patched or included as a passing strictness claim.
  Ordinary unknown JSON keys in the timed matrix are still rejected with paths.
- The hand-written row's `for...in` checks include inherited enumerable keys;
  measured payloads and program values are plain objects. Prototype-bearing
  objects, accessors and hostile proxies are not a cross-library contract here.

## 3. Results

The selected final capture is complete and qualified (`results.json` SHA-256
`d33501cdab1f5253b29a6f947cc312c6655eefacc908d153b0351438bc673f1c`).
It contains nine fresh processes, 4,500 supported timed process-cells and 35
samples per cell: 157,500 retained batch observations. The 180 additional
records are FJS's explicitly unsupported decode direction. No timing cell or
sample was dropped after seeing its value.

Descriptive tables: **group 0**, lowest converged repetition median from its
three fresh processes; p10/p90 are that same repetition's 35 batch samples.
`†` means none of the group's repetitions met the bounded warm-up criterion;
the lowest raw median is shown but excluded from stable-order conclusions.
All groups, raw samples and flips are in `results.json`. Units: **ns/op**.
Net columns subtract the corresponding JSON floor median, not quantiles.
FJS has no decode row. Failure stringify nets are counterfactual, not work performed.

### Decode — success

| Workload | Row | Median | p10 | p90 | Net parse |
|---|---|---:|---:|---:|---:|
| flat | json-floor | 446.2 | 428.4 | 471.6 | 0.0 |
| flat | handwritten | 497.0 | 482.9 | 512.1 | 50.8 |
| flat | ajv | 507.5 | 477.6 | 560.1 | 61.3 |
| flat | ajv-standalone | 501.5 | 490.6 | 511.4 | 55.3 |
| flat | typia | 540.5 | 531.6 | 558.1 | 94.3 |
| flat | typebox-value | 7341 | 7111 | 7561 | 6895 |
| flat | typebox-compiled | 621.1 | 603.0 | 649.8 | 174.9 |
| flat | arktype | 662.8 | 643.8 | 686.2 | 216.5 |
| flat | zod | 653.7 | 634.6 | 678.3 | 207.5 |
| flat | zod-jitless | 1227 | 1201 | 1280 | 780.5 |
| flat | valibot | 1008 | 970.8 | 1051 | 561.7 |
| flat | effect | 1256 | 1211 | 1303 | 810.2 |
| list | json-floor | 351596 | 341125 | 366991 | 0.0 |
| list | handwritten | 431703 | 421660 | 449318 | 80107 |
| list | ajv | 390104 | 381096 | 407364 | 38508 |
| list | ajv-standalone | 389979 | 380208 | 409172 | 38383 |
| list | typia | 418886 | 410706 | 434227 | 67290 |
| list | typebox-value | 6107083 | 5987642 | 6343650 | 5755487 |
| list | typebox-compiled | 509948 | 492548 | 536039 | 158352 |
| list | arktype | 541625 | 535346 | 557585 | 190029 |
| list | zod | 584781 | 569225 | 612958 | 233185 |
| list | zod-jitless | 1104479 | 1077813 | 1151692 | 752883 |
| list | valibot | 921416 | 901667 | 954833 | 569821 |
| list | effect | 1259000 | 1237258 | 1415233 | 907404 |
| union | json-floor | 232036 | 226479 | 239642 | 0.0 |
| union | handwritten | 284417 | 275942 | 293874 | 52380 |
| union | ajv | 383677 | 374119 | 405431 | 151641 |
| union | ajv-standalone | 384490 | 371181 | 405754 | 152453 |
| union | typia | 302016 | 295168 | 319758 | 69979 |
| union | typebox-value | 5184125 | 5134416 | 5316850 | 4952089 |
| union | typebox-compiled | 387812 | 378390 | 409579 | 155776 |
| union | arktype | 412974 | 408158 | 420026 | 180937 |
| union | zod | 423813 | 410198 | 449727 | 191776 |
| union | zod-jitless | 764813 | 748421 | 796833 | 532776 |
| union | valibot | 794083 | 772566 | 841792 | 562047 |
| union | effect | 918583 | 875617 | 1000916 | 686547 |
| tree | json-floor | 99110 | 96598 | 102159 | 0.0 |
| tree | handwritten | 104461 | 102441 | 108334 | 5351 |
| tree | ajv | 112116 | 108391 | 116743 | 13006 |
| tree | ajv-standalone | 112297 | 110001 | 118370 | 13187 |
| tree | typia | 138458 | 133809 | 142979 | 39348 |
| tree | typebox-value | 3595291 | 3503992 | 3735400 | 3496181 |
| tree | typebox-compiled | 106354 | 103984 | 112268 | 7244 |
| tree | arktype | 312660 | 308178 | 318360 | 213550 |
| tree | zod | 232896 | 228175 | 246108 | 133786 |
| tree | zod-jitless | 354333 | 342574 | 370894 | 255223 |
| tree | valibot | 568344 | 546627 | 1357810 | 469234 |
| tree | effect | 340181 | 332364 | 368467 | 241071 |
| typeahead | json-floor | 2730 | 2660 | 2805 | 0.0 |
| typeahead | handwritten | 3052 | 2963 | 3162 | 322.3 |
| typeahead | ajv | 3052 | 2979 | 3147 | 322.2 |
| typeahead | ajv-standalone | 3092 | 3018 | 3208 | 361.8 |
| typeahead | typia | 3444 | 3289 | 3625 | 713.7 |
| typeahead | typebox-value | 45885 | 44779 | 48026 | 43155 |
| typeahead | typebox-compiled | 3122 | 3061 | 3166 | 391.8 |
| typeahead | arktype | 4772 | 4691 | 4891 | 2042 |
| typeahead | zod | 4226 | 4079 | 6596 | 1497 |
| typeahead | zod-jitless | 7330 | 7130 | 7826 | 4600 |
| typeahead | valibot | 5934 | 5713 | 6111 | 3204 |
| typeahead | effect | 9380 | 9123 | 9861 | 6650 |

### Decode — failure

| Workload | Fault | Row | Median | p10 | p90 | Net parse |
|---|---|---|---:|---:|---:|---:|
| flat | wrong_type | json-floor | 461.3 | 451.9 | 481.1 | 0.0 |
| flat | wrong_type | handwritten | 464.7 | 454.9 | 488.4 | 3.5 |
| flat | wrong_type | ajv | 676.6 | 658.2 | 705.8 | 215.3 |
| flat | wrong_type | ajv-standalone | 671.9 | 660.0 | 706.0 | 210.6 |
| flat | wrong_type | typia | 794.2 | 777.6 | 821.7 | 332.9 |
| flat | wrong_type | typebox-value | 12709 | 12414 | 13396 | 12248 |
| flat | wrong_type | typebox-compiled | 9361 | 9141 | 9806 | 8900 |
| flat | wrong_type | arktype | 3598 | 3472 | 4052 | 3137 |
| flat | wrong_type | zod | 1725 | 1684 | 1908 | 1264 |
| flat | wrong_type | zod-jitless | 2368 | 2285 | 2537 | 1906 |
| flat | wrong_type | valibot | 783.6 | 764.3 | 807.2 | 322.3 |
| flat | wrong_type | effect | 1408 | 1370 | 1468 | 947.1 |
| flat | missing_key | json-floor | 387.3 | 377.6 | 400.1 | 0.0 |
| flat | missing_key | handwritten | 393.1 | 384.3 | 407.0 | 5.7 |
| flat | missing_key | ajv | 445.4 | 427.0 | 463.3 | 58.0 |
| flat | missing_key | ajv-standalone | 443.0 | 430.7 | 468.1 | 55.7 |
| flat | missing_key | typia | 814.0 | 793.3 | 861.6 | 426.7 |
| flat | missing_key | typebox-value | 8455 | 8171 | 8821 | 8067 |
| flat | missing_key | typebox-compiled | 8354 | 8050 | 8646 | 7967 |
| flat | missing_key | arktype | 3212 | 3103 | 3334 | 2824 |
| flat | missing_key | zod | 1718 | 1666 | 2164 | 1330 |
| flat | missing_key | zod-jitless | 2249 | 2152 | 2389 | 1862 |
| flat | missing_key | valibot | 628.8 | 610.2 | 657.2 | 241.5 |
| flat | missing_key | effect | 1181 | 1147 | 1223 | 794.1 |
| flat | unknown_key | json-floor | 450.4 | 432.8 | 458.0 | 0.0 |
| flat | unknown_key | handwritten | 468.8 | 457.4 | 483.3 | 18.4 |
| flat | unknown_key | ajv | 497.8 | 485.2 | 522.0 | 47.4 |
| flat | unknown_key | ajv-standalone | 497.4 | 485.3 | 519.9 | 47.0 |
| flat | unknown_key | typia | 1105 | 1066 | 1177 | 655.0 |
| flat | unknown_key | typebox-value | 11380 | 11082 | 11991 | 10930 |
| flat | unknown_key | typebox-compiled | 9739 | 9514 | 10114 | 9289 |
| flat | unknown_key | arktype | 3718 | 3604 | 3861 | 3268 |
| flat | unknown_key | zod | 1863 | 1806 | 1941 | 1413 |
| flat | unknown_key | zod-jitless | 2368 | 2306 | 2522 | 1917 |
| flat | unknown_key | valibot | 1101 | 1073 | 1151 | 651.0 |
| flat | unknown_key | effect | 1187 | 1158 | 1229 | 736.1 |
| list | wrong_type | json-floor | 349475 | 342364 | 363608 | 0.0 |
| list | wrong_type | handwritten | 400521 | 388236 | 420274 | 51046 |
| list | wrong_type | ajv | 368729 | 359647 | 385278 | 19254 |
| list | wrong_type | ajv-standalone | 366433 | 360520 | 386248 | 16958 |
| list | wrong_type | typia | 487270 | 473621 | 515796 | 137795 |
| list | wrong_type | typebox-value | 12604792 | 12409983 | 12873558 | 12255317 |
| list | wrong_type | typebox-compiled | 8519625 | 8308667 | 8856442 | 8170150 |
| list | wrong_type | arktype | 1804000 | 1753492 | 1846475 | 1454525 |
| list | wrong_type | zod | 550479 | 532917 | 582400 | 201004 |
| list | wrong_type | zod-jitless | 1044646 | 999758 | 1080258 | 695171 |
| list | wrong_type | valibot | 764042 | 744886 | 789508 | 414567 |
| list | wrong_type | effect | 1024479 | 995108 | 1066379 | 675004 |
| list | missing_key | json-floor | 354035 | 343815 | 363704 | 0.0 |
| list | missing_key | handwritten | 368883 | 362337 | 393440 | 14849 |
| list | missing_key | ajv | 363382 | 353729 | 376915 | 9347 |
| list | missing_key | ajv-standalone | 356275 | 350788 | 375567 | 2240 |
| list | missing_key | typia | 472472 | 456583 | 493417 | 118437 |
| list | missing_key | typebox-value | 10026791 | 9873283 | 10301450 | 9672756 |
| list | missing_key | typebox-compiled | 8476584 | 8259708 | 8700584 | 8122549 |
| list | missing_key | arktype | 1752458 | 1739392 | 1831442 | 1398423 |
| list | missing_key | zod | 554812 | 535642 | 581904 | 200778 |
| list | missing_key | zod-jitless | 1045583 | 1016375 | 1104896 | 691549 |
| list | missing_key | valibot | 529969 | 517942 | 553187 | 175934 |
| list | missing_key | effect | 647417 | 630385 | 672536 | 293382 |
| list | unknown_key | json-floor | 352319 | 343943 | 366237 | 0.0 |
| list | unknown_key | handwritten | 415317 | 407503 | 429300 | 62997 |
| list | unknown_key | ajv | 377250 | 370861 | 392486 | 24931 |
| list | unknown_key | ajv-standalone | 408635 | 401863 | 429625 | 56316 |
| list | unknown_key | typia | 587385 | 576000 | 632477 | 235066 |
| list | unknown_key | typebox-value | 13780791 | 13575184 | 14106359 | 13428472 |
| list | unknown_key | typebox-compiled | 8636416 | 8418325 | 8818225 | 8284097 |
| list | unknown_key | arktype | 1979875 | 1913921 | 2053012 | 1627556 |
| list | unknown_key | zod | 631569 | 621333 | 645861 | 279250 |
| list | unknown_key | zod-jitless | 1047084 | 1012025 | 1103892 | 694765 |
| list | unknown_key | valibot | 870764 | 852594 | 901119 | 518445 |
| list | unknown_key | effect | 1128437 | 1104763 | 1164100 | 776118 |
| union | wrong_type | json-floor | 236417 | 230460 | 246860 | 0.0 |
| union | wrong_type | handwritten | 259286 | 251785 | 269287 | 22869 |
| union | wrong_type | ajv | 338437 | 330225 | 388158 | 102021 |
| union | wrong_type | ajv-standalone | 340625 | 332482 | 356082 | 104208 |
| union | wrong_type | typia | 379479 | 371544 | 403904 | 143062 |
| union | wrong_type | typebox-value | 17013250 | 16691208 | 17253167 | 16776833 |
| union | wrong_type | typebox-compiled | 13489416 | 13151325 | 13735675 | 13252999 |
| union | wrong_type | arktype | 1212167 | 1155550 | 1302825 | 975750 |
| union | wrong_type | zod | 390000 | 380808 | 415377 | 153583 |
| union | wrong_type | zod-jitless | 745625 | 715730 | 777175 | 509208 |
| union | wrong_type | valibot | 648431 | 632006 | 670331 | 412014 |
| union | wrong_type | effect | 738187 | 719392 | 770144 | 501771 |
| union | missing_key | json-floor | 232574 | 226544 | 247133 | 0.0 |
| union | missing_key | handwritten | 249369 | 241804 | 263392 | 16795 |
| union | missing_key | ajv | 305078 | 294807 | 320326 | 72504 |
| union | missing_key | ajv-standalone | 303089 | 295988 | 320129 | 70515 |
| union | missing_key | typia | 362854 | 346721 | 382400 | 130280 |
| union | missing_key | typebox-value | 15695083 | 15445450 | 15924217 | 15462509 |
| union | missing_key | typebox-compiled | 13405709 | 13146692 | 13691658 | 13173135 |
| union | missing_key | arktype | 1153854 | 1140159 | 1193754 | 921280 |
| union | missing_key | zod | 403701 | 393906 | 417647 | 171127 |
| union | missing_key | zod-jitless | 751028 | 720472 | 893356 | 518454 |
| union | missing_key | valibot | 508896 | 495310 | 550567 | 276322 |
| union | missing_key | effect | 559028 | 546825 | 580325 | 326454 |
| union | unknown_key | json-floor | 232112 | 225943 | 240958 | 0.0 |
| union | unknown_key | handwritten | 274351 | 266480 | 282720 | 42239 |
| union | unknown_key | ajv | 369469 | 360788 | 395510 | 137357 |
| union | unknown_key | ajv-standalone | 367117 | 355388 | 389525 | 135005 |
| union | unknown_key | typia | 391448 | 379962 | 415592 | 159336 |
| union | unknown_key | typebox-value | 18190709 | 18064392 | 18439667 | 17958597 |
| union | unknown_key | typebox-compiled | 13506334 | 13206250 | 13764250 | 13274222 |
| union | unknown_key | arktype | 1228125 | 1205217 | 1267946 | 996013 |
| union | unknown_key | zod | 397618 | 388086 | 415378 | 165506 |
| union | unknown_key | zod-jitless | 753347 | 736720 | 783925 | 521235 |
| union | unknown_key | valibot | 764153 | 736767 | 800325 | 532041 |
| union | unknown_key | effect | 878597 | 857978 | 912714 | 646485 |
| tree | wrong_type | json-floor | 99818 | 96739 | 103753 | 0.0 |
| tree | wrong_type | handwritten | 97537 | 95377 | 101604 | -2280 |
| tree | wrong_type | ajv | 100691 | 98093 | 104381 | 873.3 |
| tree | wrong_type | ajv-standalone | 100981 | 99848 | 103809 | 1164 |
| tree | wrong_type | typia | 165705 | 160101 | 175719 | 65887 |
| tree | wrong_type | typebox-value | 4110708 | 4014242 | 4244492 | 4010890 |
| tree | wrong_type | typebox-compiled | 4004750 | 3929966 | 4147950 | 3904932 |
| tree | wrong_type | arktype | 320349 | 317378 | 329543 | 220531 |
| tree | wrong_type | zod | 247403 | 240970 | 256466 | 147585 |
| tree | wrong_type | zod-jitless | 365047 | 346931 | 382170 | 265229 |
| tree | wrong_type | valibot | 110367 | 106294 | 112405 | 10549 |
| tree | wrong_type | effect | 109882 | 107557 | 112977 | 10064 |
| tree | missing_key | json-floor | 99918 | 97723 | 102684 | 0.0 |
| tree | missing_key | handwritten | 97641 | 95048 | 102060 | -2277 |
| tree | missing_key | ajv | 99405 | 96590 | 104719 | -513.2 |
| tree | missing_key | ajv-standalone | 100030 | 97231 | 103835 | 112.5 |
| tree | missing_key | typia | 159550 | 155564 | 173233 | 59632 |
| tree | missing_key | typebox-value | 4027000 | 3937325 | 4140708 | 3927082 |
| tree | missing_key | typebox-compiled | 4012083 | 3883675 | 4131916 | 3912165 |
| tree | missing_key | arktype | 319677 | 313916 | 329847 | 219759 |
| tree | missing_key | zod | 256045 | 249271 | 267971 | 156127 |
| tree | missing_key | zod-jitless | 363818 | 352819 | 382771 | 263900 |
| tree | missing_key | valibot | 104604 | 102741 | 107638 | 4686 |
| tree | missing_key | effect | 105587 | 103825 | 108671 | 5669 |
| tree | unknown_key | json-floor | 99750 | 97547 | 103453 | 0.0 |
| tree | unknown_key | handwritten | 97698 | 95575 | 101605 | -2052 |
| tree | unknown_key | ajv | 97708 | 96071 | 102072 | -2042 |
| tree | unknown_key | ajv-standalone | 98627 | 96704 | 101587 | -1123 |
| tree | unknown_key | typia | 202656 | 193431 | 213263 | 102906 |
| tree | unknown_key | typebox-value | 4016166 | 3950450 | 4148117 | 3916416 |
| tree | unknown_key | typebox-compiled | 4044667 | 3985959 | 4238842 | 3944917 |
| tree | unknown_key | arktype | 316203 | 312111 | 319131 | 216453 |
| tree | unknown_key | zod | 247819 | 235024 | 253658 | 148069 |
| tree | unknown_key | zod-jitless | 361823 | 353109 | 380054 | 262073 |
| tree | unknown_key | valibot | 571010 | 547036 | 1876569 | 471260 |
| tree | unknown_key | effect | 101208 | 98902 | 104203 | 1458 |
| typeahead | wrong_type | json-floor | 2728 | 2632 | 2798 | 0.0 |
| typeahead | wrong_type | handwritten | 2970 | 2874 | 3072 | 242.3 |
| typeahead | wrong_type | ajv | 3430 | 3331 | 3517 | 702.3 |
| typeahead | wrong_type | ajv-standalone | 3396 | 3326 | 3500 | 668.6 |
| typeahead | wrong_type | typia | 5119 | 4831 | 5384 | 2391 |
| typeahead | wrong_type | typebox-value | 97661 | 95742 | 101080 | 94933 |
| typeahead | wrong_type | typebox-compiled | 59960 | 58243 | 62853 | 57233 |
| typeahead | wrong_type | arktype | 12046 | 11614 | 12580 | 9319 |
| typeahead | wrong_type | zod | 5438 | 5272 | 8897 | 2710 |
| typeahead | wrong_type | zod-jitless | 8688 | 8370 | 9034 | 5960 |
| typeahead | wrong_type | valibot | 5402 | 5236 | 5564 | 2674 |
| typeahead | wrong_type | effect | 9307 | 9163 | 10067 | 6579 |
| typeahead | missing_key | json-floor | 2701 | 2598 | 2772 | 0.0 |
| typeahead | missing_key | handwritten | 2713 | 2662 | 2795 | 12.0 |
| typeahead | missing_key | ajv | 2772 | 2670 | 2869 | 70.2 |
| typeahead | missing_key | ajv-standalone | 2783 | 2684 | 2861 | 81.3 |
| typeahead | missing_key | typia | 4877 | 4618 | 5163 | 2176 |
| typeahead | missing_key | typebox-value | 58781 | 57889 | 60490 | 56080 |
| typeahead | missing_key | typebox-compiled | 58277 | 56377 | 61743 | 55575 |
| typeahead | missing_key | arktype | 11625 | 11297 | 12099 | 8923 |
| typeahead | missing_key | zod | 5220 | 5131 | 5545 | 2518 |
| typeahead | missing_key | zod-jitless | 8604 | 8264 | 8984 | 5902 |
| typeahead | missing_key | valibot | 5682 | 5533 | 6016 | 2981 |
| typeahead | missing_key | effect | 9556 | 9222 | 9989 | 6854 |
| typeahead | unknown_key | json-floor | 2813 | 2729 | 2921 | 0.0 |
| typeahead | unknown_key | handwritten | 2875 | 2820 | 2977 | 62.1 |
| typeahead | unknown_key | ajv | 3203 | 3116 | 3301 | 390.0 |
| typeahead | unknown_key | ajv-standalone | 3180 | 3082 | 3317 | 367.3 |
| typeahead | unknown_key | typia | 4798 | 4617 | 4967 | 1985 |
| typeahead | unknown_key | typebox-value | 62527 | 61079 | 65716 | 59715 |
| typeahead | unknown_key | typebox-compiled | 60209 | 58188 | 63061 | 57397 |
| typeahead | unknown_key | arktype | 11290 | 10844 | 11638 | 8477 |
| typeahead | unknown_key | zod | 5565 | 5420 | 5792 | 2752 |
| typeahead | unknown_key | zod-jitless | 8889 | 8421 | 9306 | 6076 |
| typeahead | unknown_key | valibot | 3219 | 3156 | 3292 | 406.8 |
| typeahead | unknown_key | effect | 4358 | 4296 | 4635 | 1545 |

### Encode — success

| Workload | Row | Median | p10 | p90 | Net stringify |
|---|---|---:|---:|---:|---:|
| flat | json-floor | 364.0 | 355.0 | 375.7 | 0.0 |
| flat | handwritten | 470.0 | 460.2 | 486.1 | 106.0 |
| flat | ajv | 409.5 | 399.0 | 419.1 | 45.5 |
| flat | ajv-standalone | 417.0 | 409.8 | 431.2 | 53.0 |
| flat | typia | 949.1 | 927.8 | 1007 | 585.1 |
| flat | typebox-value | 6451 | 6313 | 6726 | 6087 |
| flat | typebox-compiled | 534.8 | 520.4 | 553.0 | 170.8 |
| flat | arktype | 589.9 | 581.1 | 598.8 | 225.9 |
| flat | fast-json-stringify+handwritten-guard | 539.0 | 523.8 | 570.6 | 175.0 |
| flat | zod | 560.3 | 549.7 | 585.1 | 196.3 |
| flat | zod-jitless | 1133 | 1104 | 1193 | 768.7 |
| flat | valibot | 890.5 | 861.9 | 938.9 | 526.6 |
| flat | effect | 1143 | 1108 | 1192 | 779.2 |
| list | json-floor | 266289 | 252481 | 276642 | 0.0 |
| list | handwritten | 586448 | 560021 | 673800 | 320159 |
| list | ajv | 308430 | 294917 | 322850 | 42142 |
| list | ajv-standalone | 305493 | 296883 | 330158 | 39204 |
| list | typia | 932125 | 906000 | 982275 | 665836 |
| list | typebox-value | 6042542 | 5880184 | 6267517 | 5776253 |
| list | typebox-compiled | 429969 | 419954 | 448637 | 163680 |
| list | arktype | 450958 | 443265 | 466435 | 184670 |
| list | fast-json-stringify+handwritten-guard | 588177 | 561464 | 661869 | 321889 |
| list | zod | 518708 | 493296 | 544983 | 252419 |
| list | zod-jitless | 1005916 | 979788 | 1041254 | 739628 |
| list | valibot | 835177 | 810615 | 867946 | 568888 |
| list | effect | 1188625 | 1138921 | 1248787 | 922336 |
| union | json-floor | 152919 | 149830 | 155766 | 0.0 |
| union | handwritten | 264500 | 252070 | 303809 | 111581 |
| union | ajv | 296198 | 288777 | 330492 | 143279 |
| union | ajv-standalone | 296969 | 288025 | 319335 | 144050 |
| union | typia | 548334 | 531759 | 594350 | 395415 |
| union | typebox-value | 5107458 | 5038008 | 5325225 | 4954539 |
| union | typebox-compiled | 304660 | 298701 | 315660 | 151741 |
| union | arktype | 325313 | 321227 | 342079 | 172394 |
| union | fast-json-stringify+handwritten-guard | 446375 | 430533 | 497075 | 293456 |
| union | zod | 337500 | 327898 | 351594 | 184581 |
| union | zod-jitless | 653986 | 636761 | 691689 | 501067 |
| union | valibot | 714278 | 693453 | 747358 | 561359 |
| union | effect | 800875 | 770519 | 895360 | 647956 |
| tree | json-floor | 46251 | 45235 | 47482 | 0.0 |
| tree | handwritten | 57171 | 55379 | 59635 | 10920 |
| tree | ajv | 61433 | 59754 | 63494 | 15182 |
| tree | ajv-standalone | 60641 | 58511 | 62892 | 14390 |
| tree | typia | 199604 | 193522 | 212389 | 153353 |
| tree | typebox-value | 3522500 | 3465483 | 3626708 | 3476249 |
| tree | typebox-compiled | 54756 | 53004 | 58446 | 8505 |
| tree | arktype | 258844 | 255951 | 263771 | 212593 |
| tree | fast-json-stringify+handwritten-guard | 74113 | 71895 | 78100 | 27862 |
| tree | zod | 190185 | 182493 | 312368 | 143934 |
| tree | zod-jitless | 298879 | 289850 | 314660 | 252628 |
| tree | valibot | 530889 | 508635 | 1640378 | 484638 |
| tree | effect | 291505 | 281836 | 304930 | 245254 |
| typeahead | json-floor | 1621 | 1579 | 1697 | 0.0 |
| typeahead | handwritten | 4449 | 4352 | 4606 | 2828 |
| typeahead | ajv | 1844 | 1796 | 1930 | 223.4 |
| typeahead | ajv-standalone | 1870 | 1811 | 1932 | 248.8 |
| typeahead | typia | 6892 | 6569 | 7167 | 5272 |
| typeahead | typebox-value | 45027 | 43988 | 47234 | 43406 |
| typeahead | typebox-compiled | 1893 | 1865 | 1938 | 271.9 |
| typeahead | arktype | 3618 | 3563 | 3693 | 1998 |
| typeahead | fast-json-stringify+handwritten-guard | 4137 | 4018 | 4304 | 2516 |
| typeahead | zod | 2969 | 2858 | 3111 | 1348 |
| typeahead | zod-jitless | 6166 | 6026 | 6876 | 4545 |
| typeahead | valibot | 4665 | 4508 | 4865 | 3044 |
| typeahead | effect | 8221 | 7913 | 8463 | 6600 |

### Encode — failure

| Workload | Fault | Row | Median | p10 | p90 | Net stringify |
|---|---|---|---:|---:|---:|---:|
| flat | wrong_type | json-floor | 369.1 | 362.9 | 391.0 | 0.0 |
| flat | wrong_type | handwritten | 27.7 | 26.9 | 28.3 | -341.5 |
| flat | wrong_type | ajv | 218.4 | 215.1 | 226.3 | -150.7 |
| flat | wrong_type | ajv-standalone | 221.2 | 215.0 | 229.7 | -147.9 |
| flat | wrong_type | typia | 346.1 | 333.9 | 364.1 | -23.1 |
| flat | wrong_type | typebox-value | 11845 | 11557 | 12407 | 11476 |
| flat | wrong_type | typebox-compiled | 8711 | 8464 | 9152 | 8342 |
| flat | wrong_type | arktype | 2916 | 2859 | 3023 | 2547 |
| flat | wrong_type | fast-json-stringify+handwritten-guard | 30.1 | 29.2 | 31.1 | -339.0 |
| flat | wrong_type | zod | 1217 | 1180 | 2658 | 847.9 |
| flat | wrong_type | zod-jitless | 1846 | 1785 | 2056 | 1476 |
| flat | wrong_type | valibot | 333.7 | 319.8 | 351.2 | -35.4 |
| flat | wrong_type | effect | 902.8 | 866.8 | 953.6 | 533.7 |
| flat | missing_key | json-floor | 324.9 | 317.4 | 334.2 | 0.0 |
| flat | missing_key | handwritten | 27.0 | 26.0 | 28.3 | -297.8 |
| flat | missing_key | ajv | 57.6 | 56.2 | 58.9 | -267.3 |
| flat | missing_key | ajv-standalone | 65.0 | 63.6 | 66.9 | -259.9 |
| flat | missing_key | typia | 439.3 | 419.5 | 457.6 | 114.4 |
| flat | missing_key | typebox-value | 7941 | 7794 | 8359 | 7616 |
| flat | missing_key | typebox-compiled | 7739 | 7570 | 7982 | 7414 |
| flat | missing_key | arktype | 2707 | 2644 | 2797 | 2383 |
| flat | missing_key | fast-json-stringify+handwritten-guard | 29.4 | 28.9 | 31.2 | -295.5 |
| flat | missing_key | zod | 1245 | 1194 | 1355 | 919.7 |
| flat | missing_key | zod-jitless | 1814 | 1746 | 3631 | 1489 |
| flat | missing_key | valibot | 247.3 | 241.5 | 259.9 | -77.6 |
| flat | missing_key | effect | 754.8 | 728.7 | 796.6 | 430.0 |
| flat | unknown_key | json-floor | 381.0 | 374.3 | 395.9 | 0.0 |
| flat | unknown_key | handwritten | 50.7 | 50.0 | 52.4 | -330.3 |
| flat | unknown_key | ajv | 66.1 | 64.5 | 69.3 | -314.9 |
| flat | unknown_key | ajv-standalone | 74.9 | 72.6 | 77.5 | -306.1 |
| flat | unknown_key | typia | 673.5 | 647.0 | 712.0 | 292.4 |
| flat | unknown_key | typebox-value | 10806 | 10360 | 11296 | 10425 |
| flat | unknown_key | typebox-compiled | 9252 | 8868 | 9728 | 8871 |
| flat | unknown_key | arktype | 3123 | 3086 | 3256 | 2742 |
| flat | unknown_key | fast-json-stringify+handwritten-guard | 55.2 | 54.0 | 58.0 | -325.8 |
| flat | unknown_key | zod | 1349 | 1303 | 1447 | 968.0 |
| flat | unknown_key | zod-jitless | 1825 | 1762 | 1960 | 1444 |
| flat | unknown_key | valibot | 650.7 | 634.9 | 679.8 | 269.7 |
| flat | unknown_key | effect | 670.8 | 656.6 | 735.5 | 289.8 |
| list | wrong_type | json-floor | 264363 | 255858 | 285435 | 0.0 |
| list | wrong_type | handwritten | 50207 | 49024 | 52228 | -214157 |
| list | wrong_type | ajv | 19692 | 19080 | 20812 | -244671 |
| list | wrong_type | ajv-standalone | 19253 | 18889 | 20901 | -245111 |
| list | wrong_type | typia | 141989 | 135012 | 155679 | -122374 |
| list | wrong_type | typebox-value | 12248542 | 12025725 | 12423833 | 11984179 |
| list | wrong_type | typebox-compiled | 8181167 | 8052725 | 8304875 | 7916804 |
| list | wrong_type | arktype | 1463875 | 1432134 | 1520159 | 1199512 |
| list | wrong_type | fast-json-stringify+handwritten-guard | 33142 | 32545 | 34269 | -231221 |
| list | wrong_type | zod | 197892 | 191640 | 208138 | -66472 |
| list | wrong_type | zod-jitless | 670361 | 662214 | 751667 | 405998 |
| list | wrong_type | valibot | 401550 | 392368 | 416477 | 137187 |
| list | wrong_type | effect | 657528 | 644912 | 699803 | 393165 |
| list | missing_key | json-floor | 262426 | 260036 | 273236 | 0.0 |
| list | missing_key | handwritten | 21589 | 20970 | 22360 | -240837 |
| list | missing_key | ajv | 9346 | 9043 | 9776 | -253080 |
| list | missing_key | ajv-standalone | 8970 | 8790 | 9370 | -253456 |
| list | missing_key | typia | 115725 | 112003 | 128488 | -146701 |
| list | missing_key | typebox-value | 9676209 | 9511592 | 9832275 | 9413783 |
| list | missing_key | typebox-compiled | 8004000 | 7835442 | 8238992 | 7741574 |
| list | missing_key | arktype | 1404771 | 1372471 | 1450937 | 1142345 |
| list | missing_key | fast-json-stringify+handwritten-guard | 14293 | 13969 | 14668 | -248132 |
| list | missing_key | zod | 273656 | 265999 | 289160 | 11231 |
| list | missing_key | zod-jitless | 697306 | 671511 | 719067 | 434880 |
| list | missing_key | valibot | 169463 | 166954 | 173959 | -92963 |
| list | missing_key | effect | 286018 | 279564 | 292827 | 23592 |
| list | unknown_key | json-floor | 266976 | 260539 | 279307 | 0.0 |
| list | unknown_key | handwritten | 63729 | 62877 | 66255 | -203247 |
| list | unknown_key | ajv | 25440 | 24323 | 26603 | -241536 |
| list | unknown_key | ajv-standalone | 59526 | 58401 | 61803 | -207450 |
| list | unknown_key | typia | 247833 | 242889 | 259990 | -19143 |
| list | unknown_key | typebox-value | 13489625 | 13246308 | 13815483 | 13222649 |
| list | unknown_key | typebox-compiled | 8262000 | 8091450 | 8485442 | 7995024 |
| list | unknown_key | arktype | 1640584 | 1622284 | 1664421 | 1373607 |
| list | unknown_key | fast-json-stringify+handwritten-guard | 65577 | 63790 | 68143 | -201399 |
| list | unknown_key | zod | 273687 | 268048 | 294752 | 6711 |
| list | unknown_key | zod-jitless | 677278 | 662783 | 715617 | 410302 |
| list | unknown_key | valibot | 505896 | 497281 | 526502 | 238920 |
| list | unknown_key | effect | 750014 | 729775 | 777714 | 483038 |
| union | wrong_type | json-floor | 152865 | 148762 | 181893 | 0.0 |
| union | wrong_type | handwritten | 26648 | 26398 | 27797 | -126216 |
| union | wrong_type | ajv | 108646 | 102898 | 148179 | -44219 |
| union | wrong_type | ajv-standalone | 107267 | 101776 | 114969 | -45598 |
| union | wrong_type | typia | 142115 | 137425 | 152480 | -10750 |
| union | wrong_type | typebox-value | 16700042 | 16486625 | 17147284 | 16547177 |
| union | wrong_type | typebox-compiled | 13206292 | 13047292 | 13487675 | 13053427 |
| union | wrong_type | arktype | 959541 | 932184 | 1073133 | 806676 |
| union | wrong_type | fast-json-stringify+handwritten-guard | 27385 | 26943 | 29119 | -125480 |
| union | wrong_type | zod | 145356 | 141503 | 157643 | -7509 |
| union | wrong_type | zod-jitless | 488521 | 470367 | 565486 | 335656 |
| union | wrong_type | valibot | 411992 | 394290 | 439245 | 259127 |
| union | wrong_type | effect | 487839 | 476792 | 524477 | 334974 |
| union | missing_key | json-floor | 151919 | 147684 | 174502 | 0.0 |
| union | missing_key | handwritten | 17520 | 17133 | 18211 | -134399 |
| union | missing_key | ajv | 70446 | 67251 | 74955 | -81472 |
| union | missing_key | ajv-standalone | 69609 | 65242 | 73228 | -82309 |
| union | missing_key | typia | 126500 | 122022 | 137084 | -25419 |
| union | missing_key | typebox-value | 15358458 | 15181850 | 15627250 | 15206539 |
| union | missing_key | typebox-compiled | 12994166 | 12856741 | 13236325 | 12842247 |
| union | missing_key | arktype | 919264 | 909392 | 952920 | 767345 |
| union | missing_key | fast-json-stringify+handwritten-guard | 17930 | 17626 | 18400 | -133988 |
| union | missing_key | zod | 146115 | 142015 | 156342 | -5804 |
| union | missing_key | zod-jitless | 490715 | 468064 | 595944 | 338797 |
| union | missing_key | valibot | 265823 | 254826 | 276421 | 113904 |
| union | missing_key | effect | 311208 | 303855 | 327932 | 159290 |
| union | unknown_key | json-floor | 151538 | 146203 | 175909 | 0.0 |
| union | unknown_key | handwritten | 34947 | 34282 | 36331 | -116591 |
| union | unknown_key | ajv | 133364 | 127646 | 141744 | -18173 |
| union | unknown_key | ajv-standalone | 133773 | 127645 | 142758 | -17765 |
| union | unknown_key | typia | 157616 | 150405 | 167540 | 6078 |
| union | unknown_key | typebox-value | 17875458 | 17620600 | 18077108 | 17723920 |
| union | unknown_key | typebox-compiled | 13281500 | 13132467 | 13545792 | 13129962 |
| union | unknown_key | arktype | 979875 | 962912 | 1022546 | 828337 |
| union | unknown_key | fast-json-stringify+handwritten-guard | 35695 | 34950 | 36451 | -115843 |
| union | unknown_key | zod | 148081 | 145271 | 155796 | -3457 |
| union | unknown_key | zod-jitless | 483344 | 467974 | 552792 | 331806 |
| union | unknown_key | valibot | 538854 | 509269 | 575798 | 387316 |
| union | unknown_key | effect | 621951 | 603828 | 660026 | 470413 |
| tree | wrong_type | json-floor | 45868 | 45190 | 47767 | 0.0 |
| tree | wrong_type | handwritten | 461.3 | 448.3 | 481.8 | -45407 |
| tree | wrong_type | ajv | 2372 | 2305 | 2458 | -43496 |
| tree | wrong_type | ajv-standalone | 2374 | 2328 | 2499 | -43494 |
| tree | wrong_type | typia | 61938 | 60795 | 69528 | 16069 |
| tree | wrong_type | typebox-value | 3955541 | 3881575 | 4103650 | 3909673 |
| tree | wrong_type | typebox-compiled | 3869500 | 3814634 | 4066167 | 3823632 |
| tree | wrong_type | arktype | 220545 | 217919 | 224403 | 174677 |
| tree | wrong_type | fast-json-stringify+handwritten-guard | 470.9 | 459.5 | 494.7 | -45397 |
| tree | wrong_type | zod | 147113 | 139022 | 158783 | 101244 |
| tree | wrong_type | zod-jitless | 254000 | 246608 | 267147 | 208132 |
| tree | wrong_type | valibot | 8385 | 8040 | 32387 | -37483 |
| tree | wrong_type | effect | 8982 | 8603 | 9637 | -36886 |
| tree | missing_key | json-floor | 46456 | 45272 | 48244 | 0.0 |
| tree | missing_key | handwritten | 248.7 | 242.8 | 258.9 | -46207 |
| tree | missing_key | ajv | 1220 | 1181 | 1260 | -45236 |
| tree | missing_key | ajv-standalone | 1232 | 1205 | 1287 | -45224 |
| tree | missing_key | typia | 57931 | 56062 | 64170 | 11475 |
| tree | missing_key | typebox-value | 3917584 | 3852117 | 4070866 | 3871128 |
| tree | missing_key | typebox-compiled | 3900375 | 3798750 | 4067642 | 3853919 |
| tree | missing_key | arktype | 218392 | 215387 | 222290 | 171937 |
| tree | missing_key | fast-json-stringify+handwritten-guard | 254.9 | 249.2 | 266.2 | -46201 |
| tree | missing_key | zod | 140632 | 137299 | 150585 | 94176 |
| tree | missing_key | zod-jitless | 252108 | 247659 | 264833 | 205653 |
| tree | missing_key | valibot | 4556 | 4398 | 15921 | -41899 |
| tree | missing_key | effect | 4556 | 4475 | 4955 | -41900 |
| tree | unknown_key | json-floor | 46195 | 45306 | 47854 | 0.0 |
| tree | unknown_key | handwritten | 31.3 | 30.3 | 32.2 | -46164 |
| tree | unknown_key | ajv | 71.8 | 70.7 | 73.9 | -46124 |
| tree | unknown_key | ajv-standalone | 75.2 | 72.8 | 77.7 | -46120 |
| tree | unknown_key | typia | 95054 | 92647 | 104098 | 48859 |
| tree | unknown_key | typebox-value | 3912000 | 3808883 | 4095592 | 3865805 |
| tree | unknown_key | typebox-compiled | 3923708 | 3826875 | 4058667 | 3877513 |
| tree | unknown_key | arktype | 213562 | 211183 | 220535 | 167367 |
| tree | unknown_key | fast-json-stringify+handwritten-guard | 33.7 | 32.6 | 34.6 | -46162 |
| tree | unknown_key | zod | 142600 | 133428 | 281864 | 96405 |
| tree | unknown_key | zod-jitless | 253576 | 245968 | 392581 | 207381 |
| tree | unknown_key | valibot | 475633 | 450680 | 1442093 | 429438 |
| tree | unknown_key | effect | 600.5 | 576.4 | 643.0 | -45595 |
| typeahead | wrong_type | json-floor | 1595 | 1555 | 1671 | 0.0 |
| typeahead | wrong_type | handwritten | 263.3 | 257.3 | 274.1 | -1331 |
| typeahead | wrong_type | ajv | 686.3 | 667.2 | 710.7 | -908.3 |
| typeahead | wrong_type | ajv-standalone | 688.6 | 667.6 | 706.4 | -906.0 |
| typeahead | wrong_type | typia | 2243 | 2137 | 2538 | 648.5 |
| typeahead | wrong_type | typebox-value | 94831 | 92347 | 98936 | 93236 |
| typeahead | wrong_type | typebox-compiled | 57006 | 55161 | 60044 | 55411 |
| typeahead | wrong_type | arktype | 9003 | 8851 | 9318 | 7408 |
| typeahead | wrong_type | fast-json-stringify+handwritten-guard | 199.4 | 196.2 | 206.5 | -1395 |
| typeahead | wrong_type | zod | 2431 | 2358 | 4396 | 836.3 |
| typeahead | wrong_type | zod-jitless | 5879 | 5617 | 8748 | 4285 |
| typeahead | wrong_type | valibot | 2573 | 2518 | 2747 | 978.4 |
| typeahead | wrong_type | effect | 6528 | 6216 | 6918 | 4933 |
| typeahead | missing_key | json-floor | 1585 | 1540 | 1642 | 0.0 |
| typeahead | missing_key | handwritten | 26.4 | 25.7 | 27.5 | -1558 |
| typeahead | missing_key | ajv | 61.5 | 59.5 | 62.8 | -1523 |
| typeahead | missing_key | ajv-standalone | 66.1 | 64.1 | 68.2 | -1519 |
| typeahead | missing_key | typia | 1875 | 1794 | 1976 | 290.3 |
| typeahead | missing_key | typebox-value | 55011 | 53602 | 57991 | 53426 |
| typeahead | missing_key | typebox-compiled | 55174 | 54233 | 58116 | 53589 |
| typeahead | missing_key | arktype | 8614 | 8377 | 8941 | 7029 |
| typeahead | missing_key | fast-json-stringify+handwritten-guard | 29.0 | 28.1 | 30.2 | -1556 |
| typeahead | missing_key | zod | 2356 | 2264 | 4176 | 771.0 |
| typeahead | missing_key | zod-jitless | 5666 | 5432 | 7528 | 4081 |
| typeahead | missing_key | valibot | 2883 | 2812 | 2999 | 1298 |
| typeahead | missing_key | effect | 6689 | 6407 | 7085 | 5104 |
| typeahead | unknown_key | json-floor | 1645 | 1597 | 1713 | 0.0 |
| typeahead | unknown_key | handwritten | 92.5 | 89.4 | 96.6 | -1553 |
| typeahead | unknown_key | ajv | 352.6 | 343.4 | 366.1 | -1292 |
| typeahead | unknown_key | ajv-standalone | 366.5 | 358.7 | 384.3 | -1279 |
| typeahead | unknown_key | typia | 1876 | 1817 | 2033 | 230.7 |
| typeahead | unknown_key | typebox-value | 59559 | 57766 | 61479 | 57914 |
| typeahead | unknown_key | typebox-compiled | 56977 | 56453 | 58700 | 55332 |
| typeahead | unknown_key | arktype | 8089 | 7855 | 8279 | 6443 |
| typeahead | unknown_key | fast-json-stringify+handwritten-guard | 91.6 | 89.6 | 96.2 | -1553 |
| typeahead | unknown_key | zod | 2543 | 2454 | 5763 | 897.7 |
| typeahead | unknown_key | zod-jitless | 5896 | 5750 | 8972 | 4251 |
| typeahead | unknown_key | valibot | 382.2 | 371.7 | 404.8 | -1263 |
| typeahead | unknown_key | effect | 1392 | 1360 | 1475 | -252.8 |


## 4. Startup, browser size, and CSP

The flat-only browser bundle is distinct from the full matrix adapter. A
pre-generated validator does not bring its build-time compiler into the bundle;
a runtime-codegen validator normally does. This distinction matters for Beni's
browser-first target even when their hot-loop orderings match.

The final flat-only, browser-ESM bundles all passed the execution and input-list
audits. These are the standard requested package surfaces; in particular, Zod
is not the separately unmeasured `zod/mini` surface.

| Row | Direction | Raw B | Brotli-11 B |
|---|---|---:|---:|
| json-floor | decode | 151 | 120 |
| json-floor | encode | 157 | 117 |
| handwritten | decode | 1926 | 712 |
| handwritten | encode | 2113 | 754 |
| ajv | decode | 125063 | 34172 |
| ajv | encode | 124992 | 34162 |
| ajv-standalone | decode | 5469 | 1275 |
| ajv-standalone | encode | 5362 | 1240 |
| typia | decode | 5295 | 1758 |
| typia | encode | 6032 | 2040 |
| typebox-value | decode | 123485 | 28577 |
| typebox-value | encode | 123414 | 28556 |
| typebox-compiled | decode | 138319 | 31432 |
| typebox-compiled | encode | 138248 | 31394 |
| arktype | decode | 154669 | 41839 |
| arktype | encode | 154592 | 41811 |
| fast-json-stringify+handwritten-guard | encode | 218482 | 50451 |
| zod | decode | 91316 | 23650 |
| zod | encode | 91310 | 23666 |
| zod-jitless | decode | 91318 | 23704 |
| zod-jitless | encode | 91312 | 23637 |
| valibot | decode | 6158 | 1913 |
| valibot | encode | 6152 | 1919 |
| effect | decode | 75674 | 22536 |
| effect | encode | 75668 | 22553 |

Fresh-process startup imports the **unbundled** flat entry with the same flat API
as the browser bundle; it is not startup of the emitted browser bundle. This
matters, for example, because the generated Typia entry retains an unused Typia
import at Node load while esbuild removes it. Construction is `n/a` because the
entry performs it during import. Import and first call are separate marginal
medians of three fresh processes. “To first validation” is instead the median
of `import + first call` within each raw repetition, not a sum of those two
marginal medians. Units are milliseconds.

| Row | Direction | Import ms | First call ms | To first validation ms |
|---|---|---:|---:|---:|
| json-floor | decode | 0.909 | 0.013 | 0.928 |
| json-floor | encode | 0.809 | 0.023 | 0.831 |
| handwritten | decode | 3.418 | 0.088 | 3.507 |
| handwritten | encode | 3.477 | 0.100 | 3.577 |
| ajv | decode | 76.612 | 0.155 | 76.767 |
| ajv | encode | 70.858 | 0.163 | 71.034 |
| ajv-standalone | decode | 2.960 | 0.168 | 3.123 |
| ajv-standalone | encode | 3.295 | 0.166 | 3.456 |
| typia | decode | 54.124 | 0.213 | 54.333 |
| typia | encode | 44.775 | 0.335 | 45.110 |
| typebox-value | decode | 264.827 | 0.956 | 265.754 |
| typebox-value | encode | 264.721 | 0.933 | 265.654 |
| typebox-compiled | decode | 267.373 | 0.117 | 267.490 |
| typebox-compiled | encode | 269.670 | 0.117 | 269.795 |
| arktype | decode | 134.236 | 0.173 | 134.414 |
| arktype | encode | 189.572 | 0.160 | 189.733 |
| fast-json-stringify+handwritten-guard | encode | 96.809 | 0.241 | 97.049 |
| zod | decode | 80.062 | 1.167 | 81.229 |
| zod | encode | 97.674 | 1.187 | 98.853 |
| zod-jitless | decode | 127.796 | 1.011 | 128.811 |
| zod-jitless | encode | 131.165 | 0.994 | 132.118 |
| valibot | decode | 10.309 | 0.269 | 10.576 |
| valibot | encode | 8.545 | 0.232 | 8.772 |
| effect | decode | 175.156 | 0.939 | 176.095 |
| effect | encode | 184.257 | 0.860 | 185.117 |

The all-workload adapter splits construction/compile from import. To keep all
five workloads visible without pretending that one is representative, these
are the minimum–maximum medians across them, again in milliseconds.

| Row | Direction | Import ms range | Construction ms range | First call ms range |
|---|---|---:|---:|---:|
| json-floor | decode | 0.705–1.243 | 0.016–0.019 | 0.011–0.392 |
| json-floor | encode | 0.774–0.966 | 0.015–0.018 | 0.019–0.316 |
| handwritten | decode | 2.402–3.228 | 0.026–0.032 | 0.115–1.099 |
| handwritten | encode | 2.349–2.785 | 0.028–0.031 | 0.171–1.471 |
| ajv | decode | 57.285–66.120 | 12.877–15.325 | 0.176–1.748 |
| ajv | encode | 57.875–71.383 | 12.914–15.033 | 0.177–1.719 |
| ajv-standalone | decode | 4.666–5.044 | 0.036–0.043 | 0.183–2.898 |
| ajv-standalone | encode | 4.294–5.927 | 0.032–0.035 | 0.180–2.656 |
| typia | decode | 46.561–48.181 | 0.042–0.056 | 0.228–1.974 |
| typia | encode | 46.404–47.354 | 0.039–0.047 | 0.363–3.853 |
| typebox-value | decode | 268.636–286.471 | 0.060–0.092 | 0.912–14.913 |
| typebox-value | encode | 265.681–288.329 | 0.063–0.095 | 0.928–14.824 |
| typebox-compiled | decode | 266.040–269.997 | 1.599–2.178 | 0.080–1.333 |
| typebox-compiled | encode | 265.886–290.849 | 1.480–2.087 | 0.082–1.184 |
| arktype | decode | 142.858–209.679 | 2.840–11.276 | 0.191–3.125 |
| arktype | encode | 156.329–198.490 | 2.746–11.028 | 0.178–2.203 |
| fast-json-stringify+handwritten-guard | encode | 75.608–97.826 | 4.044–5.722 | 0.275–15.326 |
| zod | decode | 87.157–124.350 | 0.829–3.702 | 1.151–5.035 |
| zod | encode | 98.138–118.753 | 0.699–4.163 | 1.396–4.521 |
| zod-jitless | decode | 82.177–130.607 | 0.861–3.570 | 0.755–6.117 |
| zod-jitless | encode | 89.953–129.577 | 0.661–3.671 | 0.910–5.325 |
| valibot | decode | 7.817–8.386 | 0.186–0.455 | 0.234–3.945 |
| valibot | encode | 8.038–8.762 | 0.176–0.442 | 0.244–3.911 |
| effect | decode | 157.799–186.440 | 0.237–0.390 | 0.818–5.795 |
| effect | encode | 163.227–178.431 | 0.248–0.365 | 0.893–5.786 |

These cold-process numbers are descriptive, not amortized hot-loop costs. They
also include Node module loading from an unflushed OS cache and are not browser
download, parse, or execution timings.

The blocked-string-code-generation probe produced the expected outcome for all
13 rows. A successful row completed 49 construction and call checks; a failing
row failed at construction, so has no call count.

| Row | Blocked-eval feasible | Calls checked | Matched expectation |
|---|---|---:|---|
| json-floor | yes | 49 | yes |
| handwritten | yes | 49 | yes |
| ajv | no | — | yes |
| ajv-standalone | yes | 49 | yes |
| typia | yes | 49 | yes |
| typebox-value | yes | 49 | yes |
| typebox-compiled | yes | 49 | yes |
| arktype | yes | 49 | yes |
| fast-json-stringify+handwritten-guard | no | — | yes |
| zod | yes | 49 | yes |
| zod-jitless | yes | 49 | yes |
| valibot | yes | 49 | yes |
| effect | yes | 49 | yes |

Dynamic composition is a separate axis from the hot-loop implementation:

| Subject | Input and time of specialization | New runtime shape / blocked-eval behavior |
|---|---|---|
| Ajv | JSON Schema, `compile` at runtime | Compile new schema; `new Function` blocked under CSP |
| Ajv standalone | Same generated validators, emitted before deployment | Select/combine shipped validators; arbitrary new schema needs the compiler again; shipped code works without eval |
| Typia | TypeScript type and tags, transformed before deployment | Select/combine compiled functions; arbitrary runtime schema cannot become a new erased TS type; emitted functions work without eval |
| TypeBox Value | Runtime JSON Schema, interpreted each call | Dynamic schema works without eval |
| TypeBox Compile | Runtime JSON Schema becomes validation source | New schema can compile; automatic interpreter fallback under CSP; current API also exposes standalone `Code`, unmeasured here |
| ArkType | Runtime type expressions/schema nodes become traversal functions | Dynamic composition remains available; cached CSP probe selects jitless fallback |
| FJS + guard | Runtime JSON Schema becomes serialization source | New serializer needs eval; standalone export exists but is not this measured row; strict validation is the separate guard |
| Zod / jitless | Runtime schema composition; default object fast path is generated lazily | Dynamic composition works; evaluation-disabled fallback works, but the capability probe can still emit a CSP violation event |
| Valibot | Runtime compositional schema objects and child `~run` calls | Dynamic composition works without eval |
| Effect default | Runtime inspectable AST, cached parser closures | Dynamic AST composition works without eval; optional compiler registry unmeasured |

The blocked-eval result is a Node feasibility probe, not a browser CSP/event
test or a fallback-speed result: the TypeBox, ArkType and Zod fallback paths are
not their normal compiled timing rows.
An application requiring **no attempted eval**, rather than only continued
functionality when eval is blocked, must also disable capability probes where
the API permits for TypeBox, ArkType and Zod (for example Zod's global jitless
setting).

## 5. Stability and equivalent-work audits

Ten of 4,500 raw timed process-cells did not meet the bounded warm-up criterion.
Every one of the 500 selected cells in each of the three best-of-three groups
had a converged candidate, so neither the descriptive group-0 tables nor the
three-group comparisons use a nonconverged fallback. There were no measurement
failures.

Ordering was not stable enough for a total ranking. Of 2,880 comparable
pair/dimension relations, 2,789 kept one direction in all three best-of-three
groups and 91 flipped. Across the nine raw processes, 2,630 kept one direction,
155 flipped, and 95 lacked all nine converged comparisons; those 95 are not
called stable. For scale, define the “largest numeric flip” as the largest ratio
between two medians in any observation belonging to a pair that reverses
somewhere else. The raw maximum was Ajv standalone **19,651.063 ns/op** versus
Ajv **57,417.000 ns/op** in group 2/repetition 0 on list encode `wrong_type`
(2.922×); the opposite order appears in group 2/repetition 1 at **20,164.063**
versus **19,967.611 ns/op**. The group-selected maximum was hand-written
**86.412 ns/op** versus FJS + guard **51.362 ns/op** in group 2 on flat encode
`unknown_key` (1.682×); group 0 reverses it at **50.734** versus **55.226
ns/op**. These are examples of why a winner table would be misleading, not
estimates of uncertainty or evidence that row rotation caused the change.

There are nevertheless useful partial orders against Zod. “Selected” below
means the relation held for every matching workload/path in all three selected
groups. “All nine raw” is claimed only where every underlying comparison
converged in all nine processes.

| Relation | Selected three groups | All nine raw, where qualified |
|---|---|---|
| Ajv < Zod | decode/encode, success/failure | decode and encode failure |
| Ajv standalone < Zod | decode/encode, success/failure | decode and encode failure |
| Typia < Zod | decode success and failure | — |
| TypeBox Compile < Zod | decode and encode success | — |
| Zod < TypeBox Compile | decode and encode failure | decode and encode failure |
| Zod < ArkType | decode and encode failure | decode and encode failure |
| FJS + guard < Zod | encode failure | encode failure |

The missing all-nine success claims are deliberate: the ten raw
nonconvergences touch some otherwise consistently ordered success comparisons,
TypeBox Compile crosses Zod in raw success observations, and ArkType and FJS
cross Zod on at least one selected-group success workload.

All 65 group/workload/operation contexts in which a row preceded the
hand-written reference were retained and audited. The audit rechecked that each
native adapter performs parse, native validation, the common rename on success,
and JSON or specialized serialization as declared; invalid paths skip mapping
and serialization. Correctness preflight had already established exact fault
paths, structurally equal success values, native details and nonmutation. Zod,
Valibot and Effect retain their native cloned/built success values—the adapters
do not discard them—and primitive hand/tree success may legitimately return the
already allocated parsed object.

No omitted work explained the orderings. The reference is deliberately one
straight-line implementation, not an optimized compiler proof: its serializer
uses explicit per-string `JSON.stringify` plus JavaScript concatenation, while
Ajv, TypeBox and ArkType validate then stringify the whole mapped value and
Typia emits a specialized serializer. Native key traversal, union dispatch and
first-fault order also differ while satisfying the common contract. FJS uses
the same hand-written guard, so its close failure ties and flips remain
plausible measurement/code-layout variation rather than evidence of a missing
guard. This audit does not causally profile every win, and it cannot turn the
chosen reference into a universal performance ceiling; it found no basis to
delete a result or retune a row.

The capture retains raw process medians, best-of-three group selections,
pairwise flips and all ceiling-audit contexts in `results.json`.
Unstable cells do not support a stable-order claim.
The p10/p90 interval describes batch observations, not a confidence interval on
a population mean. A repeated median ordering, especially with overlapping
intervals, is not a proof that a small difference survives another machine,
engine release or payload distribution. No significance or universal speedup
claim is made from this one-machine experiment.

## 6. What this can mean for Beni's fork

The narrowest fair comparison with the requested baseline is a per-operation
range, not an aggregate score. The following are **gross median ratios to the
matching Zod cell** across all workloads and all three group selections; below
1 is faster than Zod in those observations. Success ranges contain 15 ratios
(five workloads × three groups), and failure ranges contain 45 (five workloads
× three faults × three groups). No geometric mean is computed.

| Row | Decode success | Decode failure | Encode success | Encode failure |
|---|---:|---:|---:|---:|
| Ajv | 0.481–0.964× | 0.259–0.929× | 0.323–0.909× | 0.00050–0.901× |
| Ajv standalone | 0.482–0.934× | 0.258–0.923× | 0.319–0.912× | 0.00053–0.903× |
| Typia | 0.595–0.881× | 0.460–0.984× | 1.050–2.345× | 0.284–1.064× |
| TypeBox Compile | 0.457–0.978× | 4.864–34.588× | 0.288–0.954× | 6.167–90.855× |
| ArkType | 0.895–1.346× | 1.225–3.306× | 0.869–1.375× | 1.405–7.399× |
| FJS + hand-written guard | — | — | 0.390–1.584× | 0.00023–0.241× |

The extremely small encode-failure ratios are expected from early rejection:
those paths do not serialize, while Zod still performs its native diagnostic
work. They are not “net serializer” speedups, and FJS's number is principally
the declared hand-written guard. Conversely, TypeBox Compile's success fast
path does not predict its failure path, which re-enters interpreted error
production. The table therefore supports conditional statements about these
payloads and paths only; it does not produce one library verdict.

For this fork, the evidence establishes that static specialization can be
materially competitive with or faster than the measured Zod path while keeping
small shipped validators—Ajv standalone and Typia are the clearest examples—but
it does not select a single implementation. Their trade differs: standalone and
ahead-of-time generation restrict arbitrary new runtime shapes, while dynamic
systems retain composition and may pay runtime compilation, interpretation,
larger bundles, or a distinct failure path. A Beni design can keep an
inspectable Effect-class representation and common context contract, then
specialize statically known declarations without promising that every dynamic
schema takes the same path.

This experiment measures synchronous JSON-shaped boundaries with one fault per
invalid input. It does not measure Effect's effectful transformations,
cancellation, arbitrary refinements, Beni reflection, schema composition across
modules, or the code-size growth of hundreds of specialized schema declarations.
Those remain conditions on any conclusion, not features to discard for speed.

Report 33's context finding also survives either performance outcome: arbitrary
user-constructed endpoints can lose paths and options. Compilation by itself
does not establish that guarantee. A production representation must specify
which layer owns context, and how compiled and dynamic paths obey the same
contract. A declaration can describe an inspectable schema while an optimizer
specializes only statically known parts; the experiment must not turn a range
of implementation options into a false syntax-versus-library binary.
