# Executable schema cases

`cases/Cases.beni` is one ordinary Beni program whose `results` value contains
54 exact boolean assertions after the 2026-09-22 close-out (originally 50).
`Main.main` hands that complete list to the
prototype `Probe`; `expected-labels.json` prevents silently dropping or adding a
case. The runner executes the same result set in development and release builds
at jobs 1 and 8, and in Chrome for both output modes.

The cases exercise both successful values and complete failures:

- fallible decode and encode, flip and double flip, and endpoint projections;
- explicit generic list composition for string and numeric wire forms of the
  same `Int` program type, including an indexed conversion issue;
- missing, explicit null, and present value as three distinct roundtrips;
- external names such as `user-id` while Beni records keep `userId`;
- nominal program and encoded tagged unions whose shared `value` key has a
  different type by variant;
- recursive encoded `String` payloads transformed to program `Int` payloads,
  finite named descriptions, and full paths for depth failures in both
  directions;
- default/explicit first-error behavior, all-error collection, unknown-key
  policy, nested refinements, and pre-conversion program validation;
- safe-integer limits, JSON bridge failures, nonfinite values, duplicate and
  special object keys, and the platform boundary's depth bound.

Every issue assertion compares the full `{ path, direction, code, message }`
record and complete issue list. Success assertions likewise compare the whole
program or wire value. `cases/negative/` adds two compiler-boundary fixtures:
an encoded `Count` rejects a `String` payload where `Int` is declared, and
equal-looking program/encoded unions cannot be mixed. Their complete JSON
diagnostic arrays are checked and a failed build must write no output.

`Benchmark.run` performs one transformed decode and encode per iteration and
returns a known checksum. `benchmark-expected.json` records 10,000 iterations,
checksum 440,000, and the operation description so timing cannot accidentally
measure an empty loop. This is a representative prototype workload, not a claim
of Effect parity or a per-combinator benchmark.

## Honest limits exposed by the cases

`AllErrors` can combine independent field endpoint failures, including one
primitive mismatch and one custom conversion-like endpoint failure. It cannot
run a later whole-record transformation when a structural field failure prevents
constructing that record. The `cross-stage all-errors limitation is explicit`
case pins that behavior. Effect likewise cannot apply a whole-record
transformation to a record that did not parse; the finding is that implementing
independent field transformations as one later record stage loses sibling error
coverage. A production design needs per-field schema composition if it promises
those issues together.

For K15(c), the tagged-union cases claim only that **two nominal unions
type-check distinctly**, with differently typed payloads sharing a key—not a
correct codec. The hand-written endpoint recognizes the prototype's emitted
key order. The modules `MessageEncoded` and `MessageProgram` are stand-ins only,
not future nested namespace resolution.

The 2026-09-22 close-out adds three limitation assertions against that endpoint:
fractional count `1.5` returns a complete safe-integer issue with path `[]`
instead of `[Key "value"]`; count `3.0` succeeds under `maxDepth = 0`; reordered
`value`/`kind` keys return a tagged-message issue with path `[]`. They pin observed
wrong behavior, not desired guarantees. The top-level `Schema.decode` call
creates a fresh root context and the custom reader never enters bounded object
traversal. Context ownership is unenforced, not repaired in this artifact.

The fourth added assertion nests recursive `WireNode` in recursive `NestedNode`
and compares the entire encoded/decoded description. No duplication occurs:
only the outer definition survives, leaving the inner `WireNode` reference
unresolved. This separate omission is recorded in the queue, not fixed.

The malformed-JSON assertion now expects the boundary-owned `Err "invalid JSON"`
for host `SyntaxError`, not V8's diagnostic prose. It was run red before that
boundary change; the other 53 assertions passed unchanged.

The small record helpers cover arity one and two. Successful composite paths
perform more than one validation traversal, and first-error record code may
eagerly evaluate later pure readers before selecting the first issue; neither is
a performance or future-effects design. No generator API exists in the
prototype, so there is no fabricated “successful sampling” case for impossible
refinements. Rejection/exhaustion remains required if generation is added.

Finally, all stored functions here are synchronous. Their execution proves the
data representation but says nothing about suspension or cancellation; see
`EFFECTS.md` for the unresolved abstraction-boundary question and the executable
acceptance cases effects must eventually pass.
