# Schema prototype — executable representation probe

Status: bounded prototype completed and independently validated 2026-09-22;
[report 33](../docs/design/research/33-schema-prototype.md) records evidence and
remaining representation work. The owner requested Sol implementation agents with
the main agent planning, managing and validating. This is a research prototype,
not production schema syntax or an adoption of report 32 revision 2 unchanged.

## 1. Contract and scope

Owner decisions in `plans/queue.md`, *Owner decisions on schemas, 2026-09-22*,
override report 32. Read `language.md`, `boundary.md` and the relevant compiler
contracts before using their behavior. Effect at the recorded submodule commit
is the semantic reference. Ordinary Beni must implement the typed library; only
the isolated prototype platform may declare foreign JSON and reporting primitives.

All executable artifacts live under `bench/schema-prototype/`. No production
compiler, core, language grammar or global build changes are planned. Existing
module-qualified types serve as stand-ins for proposed nested schema namespaces;
this does not prove the future namespace implementation. No commits are requested.

**Close-out decision, 2026-09-22 (supersedes the original no-commit scope):**
commit as a dated research artifact in two commits, evidence first and report/
plan/queue/diary second. The report is the record and `results.json` is captured
evidence. Do not wire this into `zig build` or make it a gate. Pin the custom
endpoint context/depth/key-order failures, stabilize malformed-JSON errors and
probe nested definitions; record representation gaps without fixing them.

## 2. Questions to answer by running code

1. Can a two-sided schema implement fallible decode/encode, flip, and projections
   without recovering program-side structure from the wire-side description?
2. Can explicit schema arguments compose two wire forms for the same program type?
3. Can independent key presence and nullability preserve missing/null/value?
4. Can an encoded custom union preserve variants with differently typed shared keys?
5. Can transformed recursive schemas terminate, describe their references, and
   report bounded-depth errors with full paths in both directions?
6. Can first/all errors and unknown-field options propagate through composition?
7. Can JSON failure and numeric boundaries return values, including encoding failure?
8. What is the measured output size and browser execution cost of this representation?

The representation is experimental: prefer explicit descriptions/validators for
both endpoints and context threaded through readers/writers. A transformation
must receive enough information about its target to implement typeOnly honestly.
JSON ownership must avoid Schema/Json import cycles. Recursive description uses
named references with definitions, not a targetless DeferredNode. Do not claim
generic successful sampling from arbitrary checks; rejection/exhaustion is required.

## 3. Shared boundary for parallel work

The platform directory is `bench/schema-prototype/platform/`. Its `Wire.beni`
declares the shared public wire ADT:

```elm
pub type Value
    = Null
    | Flag Bool
    | Number Float
    | Text String
    | Array (List Value)
    | Object (List ( String, Value ))

pub foreign parse : String -> Result String Value
pub foreign print : Value -> Result String String
```

JSON marshalling must be bounded and report failure as Result; JSON-only printing
rejects nonfinite numbers instead of silently writing null. It follows ordinary
JSON.parse numeric semantics, not a claimed lossless numeric-token parser.

The platform's `Probe` module declares an opaque Program and
`finish : List ( String, Bool ) -> Program`. Its portable runtime exposes a
structured result through `globalThis.__schemaPrototype` and writes one JSON line
to console. Tests contain no Debug reachability and must pass release unchanged.

Library sources live in `bench/schema-prototype/src/`; the library owner publishes
its proposed public signatures early for the scenario owner. Scenarios live in
`bench/schema-prototype/cases/`, with `Cases.results : List ( String, Bool )` and
`Main.main = Probe.finish Cases.results`. Every label checks an exact expected
value, including whole Issue structures, rather than merely observing success.

## 4. Work ownership

- Sol library: `src/`, plus `LIBRARY.md` documenting representation and API.
- Sol runner: `platform/`, `run.mjs`, browser measurement machinery and runner docs.
- Sol scenarios: `cases/`, `CASES.md`, and `EFFECTS.md` reviewing stored-function
  effect compatibility against P2 and Effect. Effects are not implemented in beni
  today; runnable synchronous storage is not evidence of inferred suspension.
- Manager: this plan, acceptance review, integration fixes coordinated with owners,
  final results report, independent reruns, project gates and diary.

## 5. Acceptance and limits

The runner builds real Beni files in temporary directories through the installed
binary, runs emitted JavaScript, checks all named scenarios, and cleans up. Run
development and release output and compare results. Use the pinned Node 24 via
the dev shell; browser execution is primary performance evidence. Record engine,
platform, raw/brotli bytes and per-operation medians, with no unsupported Effect
parity claim. Check determinism with jobs 1 and 8 where practical.

Manager independently reruns the prototype, examines failures and missing scenarios,
and runs `zig build test`, `zig build test-blackbox`, `zig build fmt-check`.
If compiler defects emerge, capture a fail-first corpus fixture and diagnose before
expanding scope. The report separates executed proof, source-based reasoning and
unfinished research. An unproven H4 or namespace implementation must stay unproven.
