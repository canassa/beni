# Compiled schema investigation — measurement contract (2026-09-22)

Research only. No production changes. Read CLAUDE rule 8: orderings and
per-operation medians, never a geometric mean of ratios or an assumed speedup.

## Shared shapes

The manager owns `spec.mjs`, `common.mjs`, `handwritten.mjs` and committed
`payloads/*.json`. Workload ids: `flat`, `list`, `union`, `tree`, `typeahead`.
Wire flat has eight declared fields: `user-id` safe integer, `display-name`
string, `email` string, `age` safe integer, `active` boolean, `score` finite
number, `role` string, and optional `nickname` string. Program keys rename
`user-id` to `userId` and `display-name` to `displayName` only.
List is 1,000 flat records. Union is 1,000 mixed variants:
`{kind:"user",user:Flat}`, `{kind:"count",count:SafeInt}`,
`{kind:"text",text:String}`, `{kind:"point",x:Finite,y:Finite}`.
Tree is a binary tree of depth 8 (root depth 0), 511 nodes, each
`{id:SafeInt,label:String,children:Tree[]}`. Typeahead follows report 32 §5.11:
`{hits:[{hit_id:String,title:String}],total:SafeInt}`, 20 hits; program uses
`id` in each hit. No defaults: `total` is required in this strict comparison.

Every object is closed. No coercion/defaults. Optional means absent or a string,
not undefined/null; JSON inputs have no undefined. Integer bounds are
[-9007199254740991,9007199254740991]. Each workload has valid, wrong_type,
missing_key, unknown_key payloads and corresponding program values. Fault paths
are committed with payload metadata. The error contract is a structured issue
with the exact fault path (array of string/number); messages need not match.

## Adapter interface

Each `adapters/ID.mjs` exports `meta` and `create(workload, direction)` returning
a synchronous `run(input)` function. `direction` is `decode` or `encode`.
Decode input is the committed JSON text; encode input is the corresponding
program object. Return `{ok:true,value}` (program value or JSON string) or
`{ok:false,issues:[{path:[...],code:String}]}`. Inspect native error details;
never silently use the handwritten validator to repair a subject's validation.

`spec.mjs` exports `schemaFor(workload, direction)` JSON Schema (wire on decode,
program on encode), `toProgram(workload,value)`, `toWire(workload,value)`.
`common.mjs` exports `makeCodec(workload,direction,validate,serialize)`;
`validate(value)` returns null on success or structured issue array on failure;
`serialize` defaults to JSON.stringify. Native schema validation must precede
mapping so an unknown key cannot be stripped before checking. A common mapping
pass deliberately equalizes rename work; native codec-fusion is not measured.

Rows: json-floor; handwritten; ajv; ajv-standalone; typia; typebox-value;
typebox-compiled; arktype; fast-json-stringify; zod; zod-jitless; valibot; effect.
Zod's default object parser uses runtime code generation in this release;
`zod-jitless` is the explicit interpreted traversal control.
FJS is encode-only and cannot meet validation/error rules natively: label any
strict row explicitly `fast-json-stringify+handwritten-guard`, and report that
guard as a deviation rather than attributing validation to FJS.

## Measurement and evidence

Validate all subjects before timing: exact successful value, exact rejected
fault path, no mutations, unsafe-integer and reordered-key adversarial checks.
JSON floor intentionally does no validation and is excluded from those checks.
Consume every output to prevent dead-code measurements. Warm-up must record
convergence (bounded attempts; nonconvergence reported), then >=30 fixed-batch
samples, median/p10/p90 ns/op. Rotate row order deterministically per process.
Run three independent process groups, each repeated three times (nine complete
processes); select the best median within each group/cell for scheduling noise,
retain all raw samples. Report all group orderings and pairwise flips, not only
the selected global best. Never hide a library beating the hand-written row:
flag it, audit equivalent work, and investigate the reference implementation.

Decode gross includes parse+validate+mapping; encode gross includes
validate+mapping+serialization. The encode floor receives the committed wire
object (chosen outside timing, no rename charged), so it serializes the same
payload as a valid codec. Report raw JSON floor separately and subtract the
same-workload/direction/path floor for net cost, without clamping negative
values. Failure skips serialization: encode failure net-of-stringify is a
counterfactual difference, NOT validation-only time; label this explicitly.

Measure cold import, construction/compile, first call in fresh processes; real
tree-shaken esbuild flat-only bundles (pinned tool), raw and Brotli quality 11.
Do not bundle a matrix of unrelated workload definitions into the flat entry.
Measure CSP via a code-generation-disabled process where feasible. typia proof
must include emitted transformed flat code, not just an installed transformer.

`run.mjs` is the one-command entry, stdout exactly one JSON document; progress
goes to stderr. Commit that capture as results.json. Optional Chrome/HN work
comes only after primary evidence is complete. No benchmark while project gates
or dependency builds are running.
