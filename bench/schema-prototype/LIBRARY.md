# Schema prototype library

This directory is an executable representation probe, not a proposed `core/Schema`
API. `Schema e a` contains two explicit `Endpoint`s and two fallible conversions.
An endpoint contains its description, JSON-value reader/writer, and validator.
Consequently `flip`, `typeOnly`, and `encodedOnly` swap or select real endpoint
data and behavior; none attempts to reconstruct the program side from the wire
description.

`Options` and `Context` carry first/all-error selection, unknown-field policy,
the current path, direction, and a recursion depth bound. Issues retain only a
path, direction, code and message. Rejected input is not retained by default,
matching Effect's default issue behavior. The defaults are first error, ignored
unknown fields, and depth 64; callers explicitly select all-error collection.

The primitive surface is intentionally small: strings, booleans, null, safe
integers, lists, nullable values, required/optional fields, one- and two-field
record endpoints, explicit transformations/refinements, and named recursive
endpoints. Optionality (`Presence`) and nullability (`Nullable`) are separate,
so their composition represents missing, explicit null, and a value distinctly.
Generic composition always takes an explicit schema argument (`Schema.list`).

Safe integer decoding and encoding reject non-whole numbers and numbers outside
JavaScript's exact integer range. JSON printing can also fail, including for
non-finite numbers. Refinements are endpoint validators, so they run before an
encoding conversion when installed on the program endpoint and after decoding
into that endpoint.

## Known bounds

- **Close-out review, 2026-09-22: context is advisory for custom endpoints.**
  `endpoint`/`make` accept arbitrary functions and the aliases are transparent.
  Nothing ensures a caller's options, path or depth are threaded. The tagged
  fixture loses the `value` path by calling top-level `decode`, and accepts a
  record under `maxDepth = 0`. Both compile and run with exit 0; both are pinned
  as limitations, not fixed. Closed construction or an interpreter owning
  context needs a specification pass in the next representation slice.
- The record helpers stop at arity two; the prototype tests representation, not
  a production builder API.
- `Description` is a descriptive skeleton. It records primitives, lists,
  optional fields, refinements, objects, unions, and named references, but has
  no literal vocabulary or annotations and is not yet sufficient for production
  reflection, JSON Schema output, or arbitrary generation.
- `AllErrors` aggregates independent endpoint field errors and list element
  errors. A `Field` currently accepts an `Endpoint`, not a two-sided `Schema`,
  so independent per-field transformations must be moved into a staged
  whole-record conversion. If another field prevents construction of that
  record, the later conversion cannot run and its issue is not aggregated.
  This is a limitation of the prototype's field combinator: Effect can compose
  and aggregate independent child schemas, while an equivalent Effect
  whole-record transform also cannot run without its record input. A production
  design needs per-field schema composition; this probe must not be described
  as parity.
- Recursion uses an explicit name, explicit definition shape, and a thunk for
  operations. This avoids a targetless deferred node and makes descriptions
  finite, but it is manually assembled because Beni has no `schema` declaration.
- **Nested definitions probe, 2026-09-22:** nesting recursive `WireNode` in
  recursive `NestedNode` produces no duplicate definitions. It exposes a
  different defect: `recursiveEndpoint` publishes only `(name, definition)`
  and drops the body's child definitions, leaving the `WireNode` reference
  unresolved in `describe`. The full two-sided description is pinned as a
  limitation and the omission is queued, not fixed. `List.append` is in
  `object2Endpoint`, not `recursiveEndpoint`; that concatenation has no dedupe,
  and absence of duplicates in this nested probe does not establish dedupe.
- The stored functions are synchronous. Their shape does not prove that future
  inferred suspension/cancellation can flow through stored functions. In
  particular, the two-field helper evaluates both pure field results before its
  first-error combiner selects one; that would need lazy/effect-aware traversal
  before storing effectful readers.
- Successful composite `read`/`write` operations validate more than once:
  fields validate at their boundary, and the enclosing schema validates each
  typed endpoint again. For an identity `fromEndpoint` schema this can traverse
  the same endpoint three times. Pure validators make the result correct, but
  this is measurable duplicate work and another reason this representation is
  not ready for effectful validators without a traversal redesign.
- No generic sampler is provided. In particular an unsatisfiable refinement is
  a valid schema and must cause generation to fail rather than fabricate data.
