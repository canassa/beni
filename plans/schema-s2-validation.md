# Schema S2 validation — 2026-09-22

The starting revision was `021f331`; the first action was `git pull`, which was
already up to date. The contract and implementation are
[`schema.md` A.6](../docs/design/schema.md#a6--s2-type-surface-interface-and-resolved-plan-2026-09-22).

## Contract and formats

`core/Schema.beni` supplies public types, without library functions. Its opaque
`Schema`, `Conversion` and host `Value` representations remain engine-owned;
Q11 remains open. A.6 specifies the named Issue/Options fields and code types,
Q7 constructor patterns, endpoint terms and all serialised plan rows.

The hashed interface contains public schema names and arities, seven member
kinds and complete schemes, structural endpoint expansions or distinct nominal
identities, constructor payload schemes and visibility. Source parameter names
are excluded, so alpha-renaming is not a public change. The unhashed sidecar
contains the resolved plan, source positions and conversion expression targets.
Canonical private endpoint definitions and settled capability bits feed the
existing named-type digest; executable conversion bodies never feed that hash.

| Format | Before | After |
|---|---:|---:|
| Interface | 1 | 2: fourteen columns, including schemas/members/constructors |
| Frontend artifact | 2 | 3 |
| Cache entry | 1 | 2: interface, dispatch, schema plan, diagnostics |
| Resolved schema plan | absent | `BENISPL\0`, version 1, twenty-two columns |

Readers reject incompatible versions and invalid enum, padding, ownership,
range and reference data. The plan is immutable and does not expose a TypeStore.
A.6 records its exact node vocabulary and payload layout.

## Corpus acceptance

The compact two-schema interface golden is
[`TwoSchemas/_expected.iface`](../tests/corpus/check/good/TwoSchemas/_expected.iface).
It shows Event's two distinct nominal endpoints, both Text/Count constructor
families and all seven members, followed by User's two structural endpoint
expansions and seven members.

Good cases: `TwoSchemas/`, `SchemaMembers/`, `SchemaTypeNameControl`,
`MixedRecursive`, `SchemaWinsModuleAlias/`, `ModulePrefixWinsSchemaRoot/`,
and the moved `SchemaUnsupported`. SchemaMembers covers all
three import spellings, generic factories with one program endpoint and two
wire endpoints, differently typed same-key variant payloads, both constructor
families in patterns, optional/nullable/both, matching conversions, private
schemas, recursive tagged types, and public signatures using private generic
endpoints. MixedRecursive covers the valid record-to-tagged recursive boundary. The two
namespace overlap cases prove that a collision requires two valid complete
paths, not merely the same root spelling. The collision diagnostic names both
source locations. Qualified and exposed imports exercise both constructor
families in expressions and patterns.

Bad cases (each has an exact JSON diagnostic golden):

- `DuplicateSchemaKeyDiscriminator`
- `DuplicateSchemaKeyFields`
- `DuplicateSchemaModifier`
- `DuplicateSchemaTag`
- `ExpectedSchema`
- `ExpectedSchemaValue`
- `MissingPatternsSchemaEncoded`
- `MissingPatternsSchemaType`
- `PrivateSchemaMember/`
- `RecursiveRecordSchema`
- `RedundantPatternSchemaEncoded`
- `RedundantPatternSchemaType`
- `SchemaConversionMismatch`
- `SchemaEndpointEquality/`
- `SchemaEndpointMismatch`
- `SchemaNameCollision/`
- `SchemaRecursivePayloadMismatch`
- `SchemaUsedAsType`
- `SchemaUsedAsValue`
- `SchemaUsedAsValueGeneric`
- `UnknownSchemaConstructorMember`
- `UnknownSchemaMember`
- `UnknownSchemaValueMember`
- `WrongSchemaOperandArityGeneric`
- `WrongSchemaOperandArityList`
- `WrongSchemaOperandArityPrimitive`
- `WrongSchemaTypeArity`

The build case is `build/bad/SchemaNotGenerated/`. Its source checks successfully,
but ordinary and library builds exit 1 with empty stdout and no output directory.
The emit guard runs before entry discovery, also covered without a `main`.
Its diagnostic, anchored on the schema name, is:

> This schema is checked, but its parse and print are not generated until schema S4.

## Fail-first evidence

Before touching implementation source, the requested good and bad corpus cases
were run against the S1 compiler. Declaration-only schemas received S1's
`not_implemented`; bare schema types/values received `unbound_type` or
`unbound_constructor`; qualified members and constructors received
`unknown_module_alias`. These differ from the new good exits and exact bad
code/message/span goldens. `DuplicateSchemaModifier` was already-green S1
coverage and is explicitly a control, not a newly fixed defect.

Row 70 was proved separately: `SchemaRecordNullable` exited 1 with
`unexpected_token` on `nullable` at 2:24. The one-line parser fix routes the
brace body through the value-modifier path and produces the expected enclosing
`schema_nullable` AST. Its commit passed all three gates.

The existing `bir/SchemaDeclarations.bir` golden deliberately changes imported
conversion leaves from inert `schema_expr_ref` placeholders to ordinary
`qualified` leaves plus `import_value` dependencies. These dependencies are
required for mixed schema/value SCCs and cache invalidation; A.6 records the
permanent S2 representation. The reverse proof also compares the reversed
output with the original S1 golden, separately from the new S2 expectation.

During implementation, additional targeted probes caught and then covered
operand arity checks, recursive tagged payload typing, source-order-independent
endpoint capabilities and a valid mixed record/tagged cycle. The first failing
candidate and subsequent successful runs were retained outside the repository.

## Interface, cache and firewall

The persistent black-box suite covers schema interface and plan round-trips,
cache cold/warm behavior, private conversion edits, public field edits and
parameter alpha-renaming. A malformed-plan test rewrites both record endpoint
term tags to nominal applications while retaining valid indices: the earlier
binary wrongly accepted the entry (12 hits, zero checks); the final reader
now misses, rechecks and restores exactly the original entry bytes. The rejected
entry is cleared from both the loaded slot and cutoff hit state, allowing the
canonical rewrite; merely deinitializing its payload was insufficient. The existing corpus determinism matrix visits the new
fixtures with jobs 1 and 8, so the new interface columns are compared by
construction. Interface dump round-trips compare pretty and raw outputs; dump
has no persistent-cache flag, so cache claims use actual cached interface bytes
and `--iface-hash`, not an unsupported dump option.

An independent check of the final compiler used a Models/Consumer project and read
the interface sections from the cache entries:

| Run | Modules checked | Cache hits | Files lowered |
|---|---:|---:|---:|
| Cold | 13 | 0 | 13 |
| Warm | 0 | 13 | 0 |
| Private conversion body edit | 1 | 12 | 1 |
| Public field rename | 2 | 11 | 1 |

Cold/warm and private-edit hashes were identical. The serialized schema
interface bytes were exactly identical after the private edit and changed after
the public field edit. The importer was checked only for the public edit.
A separate generic parameter alpha-rename checked one module, preserved every
interface hash and left the importer behind the firewall. Endpoint-capability
error diagnostics also compare byte-for-byte cold and warm. SchemaMembers has
18 warm hits, zero checks and zero unifications. The two namespace-overlap
fixtures also passed 32 cold/warm checks across jobs 1/8 and plain, frontend,
interface and combined round-trips; the ambiguity diagnostic retains both
origins. Cached qualified names are recovered from source positions, because
frontend artifacts intentionally omit token payloads.

## Reverse-patch proof and gates

The source-only proof uses baseline `2d2c0e7`, after the type-surface commit and
before row 70. No stash was used:

```sh
git diff 2d2c0e7 -- src > /tmp/beni-s2-proof/source.patch
git apply --check -R /tmp/beni-s2-proof/source.patch
git apply -R /tmp/beni-s2-proof/source.patch
git diff --exit-code 2d2c0e7 -- src
zig build
zig build test-blackbox --summary all
```

The source comparison exited 0: reversed `src/` was exactly the baseline.
The initial proof patch SHA-256 was
`711fa5b3e98b134e582a534a5e13e4a25ed48cae5b65dc889637df92edd6d67f`.
After the final validation fixes, the source patch was regenerated and reversed
again. `git diff --exit-code 2d2c0e7 -- src` again proved the exact same baseline
used by the full reversed suite, and the original refusal was rechecked. The
final patch SHA-256 is
`35835974bbc80e3f7e4f763c33fd6699b3a8e9699367a4adfb2284dcc43142ae`.

The original `SchemaUnsupported` source, run at its original relative path,
returned exit 1 and **byte-identical original JSON**, including its 4:8–4:12
span and old diagnostic:

> This schema is parsed and preserved, but its endpoint types and members are not
> checked until schema S2.

The reversed compiler also reproduced the original S1 `SchemaDeclarations.bir`
byte-for-byte, and row 70's nullable brace body again exited 1.

The full reversed corpus produced **exactly 36 expected assertion failures**:
35 new/moved cases and the deliberately upgraded BIR golden. The remaining new
case, `DuplicateSchemaModifier`, passed as the S1 control. No unexpected corpus
case failed. The three schema-specific scenario tests also failed as expected.
The acceptance matrix failed only for the new `SchemaNotGenerated` project:
S1 refuses before checking/caching, so it cannot supply S2's required warm hit.

The first reversed run also exposed a misplaced `pub` in the existing layout
comparison test. That test-only edit was corrected, and the **entire 104-test
blackbox group was rerun against the same reversed compiler**: 103 passed and
only the new wall test failed. Thus no unchanged case remained failing.
An earlier focused invocation had placed `--test-filter` after a dependency
module and executed zero root tests; its empty logs were discarded. Corrected
focused invocations reported actual `1/1` execution, and the final full gate
below is authoritative.

The patch was reapplied with `git apply`. Recomputing `git diff 2d2c0e7 -- src`
produced the same final SHA-256, proving exact restoration. All final gates
passed on the restored source:

| Gate | Result |
|---|---|
| `zig build test --summary all` | 468/468 tests; 12/12 build steps |
| `zig build test-blackbox --summary all` | 287/287 tests; 33/33 build steps |
| `zig build fmt-check --summary all` | 2/2 build steps |

The full black-box result includes the corpus determinism/round-trip matrix,
cache/firewall scenarios, runtime corpus and release second pass. Each command
exited 0. Logs are `/tmp/beni-s2-final-green-{test,blackbox,fmt}.log`.

## Commits and unrelated findings

- `2d2c0e7` — define schema checker contracts and core types; three gates green.
- `875f623` — accept modifiers on brace schema bodies; three gates green.
- S2 implementation commit: recorded in the session report after validation.

Both prerequisite commits were pushed. Queue rows 71 and 72 record separately
reproduced baseline defects: imported ordinary types lose arities above 255,
and ordinary wrapper equality ignores a payload type's custom public `eq`.
Neither ordinary-type defect is fixed by S2.
