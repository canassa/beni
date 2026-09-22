# 33 — Schema representation prototype

Commissioned by the owner on 2026-09-22: start the prototype, with Sol agents
implementing and the manager planning and independently validating. The bounded
contract is [the prototype plan](../../../plans/schema-prototype.md); the code is
under [`bench/schema-prototype`](../../../bench/schema-prototype/).

**Close-out, 2026-09-22:** committed as a dated research artifact, with the
posture of `references/talks/`: this report is the record and the code is its
evidence, not a feature or supported library. It is not wired into `zig build`
and is not a gate. The original results below remain historical; dated additions
record the independent review and expanded capture.

## 1. What this experiment is

An ordinary-Beni library with an isolated platform for JSON marshalling and
reporting. There are no production compiler, core, grammar or build changes.
Existing modules stand in for future schema namespaces. This is executable
research, not adoption of report 32's superseded representation or proof of
Effect feature/performance parity.

`Schema encoded decoded` stores two explicit endpoints and two fallible
conversions. Each endpoint owns its reader, writer, validator and description.
`flip` exchanges the endpoints and conversions; projections select an actual
endpoint instead of trying to recover the program structure from the wire shape.
Generic combinators receive schemas explicitly. Presence and nullability have
separate constructors, and external key spelling is confined to field readers
and writers.

The prototype uses transparent record aliases. It does **not** establish that
the proposed opaque nominal schema representation preserves inferred effects.
The source-based [effect analysis](../../../bench/schema-prototype/EFFECTS.md)
records the directional suspension/cancellation experiment still owed before
the representation can be fixed.

## 2. Validation method

The [runner](../../../bench/schema-prototype/RUNNER.md) copies source into a
fresh temporary project, builds it with the real compiler, executes the emitted
JavaScript and checks its complete expected result. Development and release are
each built with jobs 1 and 8; complete output trees are byte-compared within each
mode. Negative source fixtures compare whole diagnostics and require no emitted
output. Chrome checks the same semantic results as Node.

Browser timing calls an exported Beni function repeatedly, with a known checksum;
it does not time repeated imports of an already evaluated constant. Raw and
Brotli sizes cover the complete emitted test application, not a minimal schema
runtime. Timings are a baseline for the named workload only. There is no measured
Effect comparison and no general parsing-throughput claim.

## 3. Results

The manager independently ran the frozen prototype on 2026-09-22 with the
compiler built from `dee4bb8`, Zig 0.16.0, Node 24.19.0 and Chrome
153.0.8010.48 on darwin/arm64. The capture file
[`results.json`](../../../bench/schema-prototype/results.json) is refreshed by
the close-out run below; the initial figures are retained here as recorded.

- **50 exact assertions passed** in four Node executions (development/release,
  jobs 1/8) and both Chrome executions. One assertion deliberately records the
  known staged-error limitation; this is not 50 Effect-conformance claims.
- Both compile-negative fixtures matched their entire diagnostic arrays and
  emitted no output. They reject an incorrectly typed encoded payload and
  mixing nominal program/encoded unions.
- Development outputs were byte-identical across jobs 1/8, as were release
  outputs. Result records also matched between modes and engines.
- `beni fmt --check bench/schema-prototype` passed independently.

| Mode | Emitted files | Raw bytes | Concatenated Brotli bytes | Median browser batch |
|---|---:|---:|---:|---:|
| Development | 18 | 109,459 | 17,590 | 1.2 ms |
| Release | 18 | 59,394 | 14,207 | 1.2 ms |

Each browser batch performs 10,000 decimal-text-to-Int decodes and reverse
encodes, returning checksum 440,000. Eleven samples are retained, including
warm-up/JIT variation; the complete timings are in the capture. This tiny,
constant-input microbenchmark is not representative application throughput,
does not establish a development/release speed ordering, and is not an Effect
comparison. Separate per-operation and representative recursive/record
workloads remain owed. Size includes all test assertions and reporting code;
concatenated Brotli is not independent-file network transfer size.

The manager's full baseline `zig build test && zig build test-blackbox &&
zig build fmt-check` completed successfully under the pinned dev shell on
2026-09-22. The prototype adds no compiler or global build changes. Supplementary
independent checks of the JSON sibling exercised null, non-finite rejection,
prototype-named keys, duplicate-key rejection and the nesting bound under Node
24.19.0.

### Close-out capture — 2026-09-22

Before edits, `nix develop --command node bench/schema-prototype/run.mjs
--no-browser` reproduced **50/50**, both negative fixtures and every byte-size
figure above. The expanded capture now contains **54/54**: the three tagged
endpoint limitations and the nested-definition probe were added in place. Five
assertions in total pin known limitations, not desired production behavior.

The three new tagged labels and observed values are:

- `hand-written endpoint drops caller path (limitation)`: fractional count
  `1.5` returns `Err [{ path = [], direction = Decoding, code = Invalid
  "safe_integer", message = "expected a safe integer" }]`.
- `hand-written endpoint ignores depth bound (limitation)`: count `3.0` under
  `maxDepth = 0` returns `Ok (MessageProgram.Count { value = 3 })`.
- `hand-written endpoint rejects reordered keys (limitation)`: `value` before
  `kind` returns `Err [{ path = [], direction = Decoding, code = Expected
  "tagged message", message = "expected tagged message" }]`.

The host-error fixture now asserts `Err "invalid JSON"`, owned by `Wire.parse`
when it catches `SyntaxError`. With that assertion changed but the sibling not
yet fixed, the run failed only that case; all other 53 passed. No representation
code was changed to improve the limitation results.

The final full `run.mjs` exited 0 under Node 24.19.0 and Chrome 153.0.8010.53,
darwin/arm64: 54/54 in all four Node runs and both browser modes, both negative
fixtures exact, and output byte-identical between jobs 1 and 8. The committed
`results.json` is that run's unedited JSON output.

| Mode | Emitted files | Raw bytes (delta) | Concatenated Brotli bytes (delta) | Median browser batch |
|---|---:|---:|---:|---:|
| Development | 18 | 113,935 (+4,476) | 17,970 (+380) | 1.1 ms |
| Release | 18 | 61,696 (+2,302) | 14,541 (+334) | 1.1 ms |

Only fixture additions and stable syntax-error handling changed executable
evidence. These sizes include the added cases; the benchmark and its limits
are unchanged. No production `src/`, `core/`, `platforms/` or build file changed.

The close-out subsequently reran `zig build test && zig build test-blackbox &&
zig build fmt-check` under the pinned dev shell: exit 0. Beni fixture formatting
and staged whitespace checks also passed. Evidence was committed as `9a8f903`
(`📝 preserve the 2026-09-22 schema prototype`); this report and its planning
records are the separate close-out documentation commit.

## 4. Representation limits found during review

- A staged `Value -> encoded -> decoded` pipeline cannot collect a later
  sibling transformation error when an earlier structural failure prevents
  construction of the encoded record. This matters if that whole-record
  conversion implements independent field transformations. Effect also cannot
  run an arbitrary whole-record conversion on an invalid record: the equivalent
  comparison is with its independently composed field schemas. A production
  parser must preserve partial progress or compose child schema readers directly;
  merely adding an `AllErrors` option does not solve this.
- The description is a structural skeleton, not a sufficient production AST for
  reflection, JSON Schema generation or sampling. Optional/refinement markers
  exist, but discriminator literals and machine-readable checks/annotations are
  missing. Named recursive references alone do not discharge those requirements.
- Synchronous functions stored in aliases do not test inferred suspension,
  cancellation, effectful first-error short-circuiting or directional effects
  through an opaque nominal schema and imported interfaces. The two-field
  helper currently evaluates both pure readers before selecting its first
  issue; successful composite paths also repeat validation traversals.
- Namespace resolution, schema syntax and elaboration remain compiler work.
  A hand-written pair of nominal modules proves their payloads can be typed,
  not that proposed nested schema names already resolve. Its tagged reader
  recognizes the fixture's emitted key order, not arbitrary JSON object order.
- **2026-09-22 close-out — context is not guaranteed.** User-constructed
  endpoints can bypass options, paths and the depth bound with exit 0.
  `endpoint`/`make` accept arbitrary functions and transparent aliases cannot
  enforce context threading: the tagged fixture reports fractional `value` at
  path `[]` and accepts count `3` under `maxDepth = 0`. A production design
  needs closed construction or an interpreter that owns context around user
  transformations. This guarantee gap, not only field-schema composition, is
  the argument for an AST-shaped representation. It is recorded, not fixed;
  the next representation slice owes a specification pass first.
- JSON uses ordinary `JSON.parse` semantics, with bounded Beni-value marshalling.
  It does not preserve the original text of numeric tokens or supply an exact
  large-integer representation.

No generic sampler is claimed: unsatisfiable refinements cannot promise a
successful generated value. No asynchronous effects runtime is added by this
experiment.

**Additional close-out observation, 2026-09-22:** the nested-recursion definitions
probe found no duplication. `recursiveEndpoint` publishes a singleton rather
than appending body definitions; nested `WireNode` inside `NestedNode` therefore
leaves `ReferenceShape "WireNode"` without a definition. `object2Endpoint` is
where definitions are concatenated without dedupe. The full observed description
is pinned, and the distinct missing-definition defect is queued without a fix.

## 5. What to build next

Keep two explicit endpoints and fallible directions as the working model, but
do not freeze this record-of-functions representation as the production ABI.
The next representation slice should compose field **schemas**, including
their two directions, and collect independently reachable issues without a
whole-record staging barrier. Make first-error traversal lazy and eliminate
redundant validation before drawing performance conclusions.

In parallel with that design, discharge H4's directional effect propagation at
the stored-function/imported-interface boundary before committing to an opaque
schema type. Then revise report 32 into a coherent normative contract for
descriptions, namespace resolution, elaboration and diagnostics before adding
schema grammar. The prototype has supplied evidence for that work, not replaced
the specification pass.

**Close-out clarification, 2026-09-22:** context ownership is a stronger argument
against fixing this ABI than field composition alone. Closed construction or an
AST interpreter must own traversal policy around user conversions; asking every
endpoint author to pass `Context` correctly cannot supply that guarantee. This
artifact records the gap and does not start that representation slice.
