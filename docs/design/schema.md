# Schemas — specification

## Open decisions for the owner

**Status:** normative. S1 frontend support and the layout declaration spelling
(§2/A.5) and S2 checking (§3–§4/A.6) are implemented; library
interpretation and specialised execution await S3–S4. Q3, Q6, Q9 and Q11
below remain open; their recommendations guide the affected later slice, not S1.
Q1, Q2, Q4, Q5, Q7, Q8 and Q10 are decided (A.2/A.6).
Q12's scheduling is A.3/A.4: S1 and row 67 may run in parallel; both precede S2.
Question identifiers and section numbers stay stable. Append later decisions
to Appendix A.

| ID | Question | Recommendation | Cost and alternative |
|---|---|---|---|
| Q3 | Does v1 have defaults? | No declaration modifier and no implicit defaults in v1; explicit fallible transformations may deliberately recover missing data. | More application code. Alternatively add Effect-style directional defaults with separate missing/null/failure triggers and encode omission rules. Report 34's no-defaults protocol is evidence scope, not an owner decision about the language. |
| Q6 | What metadata must descriptions carry, and do JSON Schema output and generators ship in v1? | Carry both endpoints (including opaque conversion targets), external keys, presence/nullability, tag literals, named recursive definitions, check identifiers/parameters, annotations and an explicit opaque-check marker now. Ship inspection in v1; ship JSON Schema and generators later as libraries with fallible results. | Larger descriptions when retained. Omitting metadata now makes later tooling incomplete. Arbitrary functions cannot be translated to JSON Schema or guaranteed to yield a sample; never silently weaken a check. |
| Q9 | Where does differential testing enter the gates? | Every schema semantic fixture runs compiled and forced-library paths inside `zig build test-blackbox`, in development/release, with exact values and Issue lists; jobs 1/8 determinism remains mandatory. | Additional runtime; measure the gate cost in S4. A separate optional job is cheaper locally but can let the two semantics drift. Differential agreement alone is insufficient: both also assert an independent expected answer. |
| Q11 | What is the stored-function abstraction after P2? | Keep two explicit endpoint semantics and separate directional callbacks, but do not freeze an opaque `Schema e a` ABI until H4's seven cases pass. Investigate inferred directional bits across the abstraction/interface boundary. | S3 is synchronous and an internal representation may change. Making every schema call suspending is an alternative only with measured cost and owner acceptance; this spec chooses neither an effects runtime nor that alternative. |

The source of settled decisions is [the queue](../../plans/queue.md), *Owner
decisions on schemas*, 2026-09-21 and 2026-09-22, and the commissioned fork
recorded in A.1. [Report 32](research/32-schemas-at-effect-parity.md) supplies
vocabulary and the original 162-row Effect inventory (revision 2 appends rows
163–164); it is research with superseded sections, not this contract. Reports
[33](research/33-schema-prototype.md) and
[34](research/34-compiled-schemas-in-javascript.md) supply representation and
performance evidence, not additional settled surface decisions.

This is a delta on the existing contracts. §2 extends `language.md` §3/§5 and
`frontend.md` §1/§7; §3–§4 extend `checker.md` §4–§8; §6 extends `backend.md`
§2/§4–§6/§9; §5 and §7 extend `boundary.md` §4–§5. Each wired contract points
here; the detail lives here once. Settled schema rules here prevail over the
older research.

## 1. What a schema is, and the guarantees

A schema describes two typed endpoints and a fallible conversion in each
direction. `schema User = …` defines the schema; `User.Type` is its program
type and `User.Encoded` its encoded **Beni** type. Bare `User` in a type
annotation is not shorthand for either. An author may declare an alias.

- **G1 — No exception escapes in either direction.**
- **G2 — Every failure carries a path, including the empty path for a root failure.**
- **G3 — Depth is bounded and exceeding the bound returns a failure value.**
- **G4 — Unknown keys are decided by a documented policy, never silently by an implementation accident.**
- **G5 — Both directions are total functions into `Result`.**

Every rule below is tested against G1–G5. A rule that buys none is a warning,
an explicit escape hatch or deferred capability, not a new error. Existing
language typing, scope and exhaustiveness rules continue to hold: their
purpose is to keep those guarantees true of a well-typed caller. G4 permits
an explicit, documented Ignore default; it does not require a warning for
every stripped key. Ignore is the default.

Totality covers schema traversal and defined boundary failures on finite
inputs. As elsewhere in Beni it is not a termination proof for arbitrary
user recursion, a promise to recover out-of-memory termination, or permission
to use `Debug.todo` as a transformation. Custom conversions return failures as
values; privileged primitives obey `boundary.md` §4.1. A schema cannot make
an arbitrary callback terminating or prove its round-trip law.

`Encoded` and `Type` both use the declared Beni field names. For
`userId : Int as "user-id"`, both typed records have `userId`; only external
reading/writing uses `"user-id"`. This applies even when the external name is
a valid Beni identifier. `Encoded` is neither raw JSON nor a record with
quoted field names. The three semantic levels are an external host value,
typed Encoded and typed Type. `Value` is an opaque boundary handle over the
host value, not a recursively marshalled Beni ADT. JSON.parse supplies the
host value directly. Compiled validation reads it in one pass, constructing
the typed result without first constructing a Value tree or a whole Encoded
intermediate. The library uses privileged core primitives over the same host
representation; neither path pays an eager marshalling pass.

A declaration produces an inspectable description value **and** specialised
ordinary top-level parse/print functions. Both success and failure paths are
compiled. The description is the plain form that remains available, under
[report 28 §0](research/28-jsx-in-beni.md); runtime composition uses the library
path. Both obey §5, including the same errors. Specialisation is not a second
schema language and is not reserved for `--release`.

## 2. The declaration

The following is **new syntax**, in `language.md` §3's `:=`, `?`, `*`, `+`
notation used by the frontend contract. The fixed skeleton admits schemas,
fields, renames, tagged variants and explicit parameters.

```text
Decl          := DocComment? Visibility? (… | SchemaDecl)
SchemaDecl    := 'schema' upper_ident lower_ident* SchemaBody
SchemaBody    := '=' (SchemaRecord | SchemaFieldBlock | SchemaOperand ValueModifier*)
               | 'tagged' string 'of' (SchemaVariant ('|' SchemaVariant)* | LayoutVariant+)
SchemaFieldBlock := LayoutSchemaField+
LayoutSchemaField := DocComment? lower_ident ':' (SchemaOperand FieldModifier* | SchemaFieldBlock)
LayoutVariant := upper_ident ('as' string)? (SchemaFieldBlock | '{' '}')?
SchemaRecord  := '{' (SchemaField (',' SchemaField)*)? '}'
SchemaField   := DocComment? lower_ident ':' SchemaOperand FieldModifier*
SchemaOperand := SchemaHead SchemaAtom* | SchemaRecord
SchemaHead    := upper_ident | qualified_upper | lower_ident
SchemaAtom    := upper_ident | qualified_upper | lower_ident
               | '(' SchemaOperand ')' | SchemaRecord
FieldModifier := 'as' string | ValueModifier | 'optional'
ValueModifier := 'via' Atom | 'nullable'
SchemaVariant := upper_ident SchemaRecord? ('as' string)?
```

`Atom` is the existing expression atom including its abutting access chain;
a multi-argument conversion expression must be parenthesised. The atom has
type `Conversion b a`; ordinary call arity is unchanged. `optional` belongs to
a field position, where absence has meaning;
`nullable` composes at a value position. Modifier words terminate schema
application at the current delimiter depth. Schema parameters with those
spellings can be parenthesised as operands; they are not globally reserved.
A modifier applies once; two external names for one field are ambiguous and
reported by §8. The effective order is rename at the boundary, presence then
null test, then the inner schema/conversion; written modifier order does not
silently change this. Explicit library composition expresses other orders.

`schema` is contextual at declaration start before an upper name; `schema = 1`
stays a value declaration. `tagged`, `via`, `optional`, `nullable` are contextual
inside this production; `as` and `of` reuse existing keyword tokens. Indentation
is the existing declaration/continuation layout, not braces overriding layout.
Layout is sugar: field blocks and variant lists desugar to the brace/bar
spelling, producing the same `schema_record`, `schema_tagged` and other AST
nodes, and byte-identical AST/BIR dumps. `language.md` §4's field/variant
columns bound each body: siblings align, smaller columns end a block, and
operand/modifier continuations stay right of their field. After `name :`, a
later-line, deeper `lower_ident ':'` opens a nested field block; otherwise
parse a schema operand. A field head following an already-started operand at
another column is diagnosed, never interpreted as implicit nesting. Brackets
set no column, including a parenthesised `via` atom spanning lines. Braces
remain available as input and where a block cannot go (an inline operand,
an empty record, or a record carrying outer field/value modifiers).

The formatter always emits layout for nonempty declaration record bodies and
tagged variants, with four spaces per level, one field per line, a field's doc
comment directly above it at its column, and modifiers separated by one space.
It keeps field and variant order and string contents. `schema X =` ends the
head line; the record or operand body begins on the next line indented four
spaces. A tagged declaration keeps `tagged "key" of` on its head line, puts
`Variant as "tag"` at +4, and its payload fields at +8; a payloadless variant
has no field block. An explicitly empty payload prints `Variant as "tag" {}`
to preserve its AST: the empty-brace alternative is the empty-record exception,
not a payloadless variant. Inline brace forms retain their existing formatting.
Malformed layout fields recover at exactly the sibling column, or end the
block at a smaller column; column 1 still ends everything. Malformed brace
fields recover at the next sibling comma, closing brace or next top-level
declaration. `unexpected_token` and `expected_token` carry field context; no
new diagnostic code is needed. There is no bodyless schema, default modifier
or opaque schema form adopted here.

```elm
-- NEW SYNTAX; schema operands and distinct presence/null wrappers.
pub schema User =
    userId : Int as "user-id"
    nickname : String optional nullable

pub schema Page a =
    items : List a

pub schema Message tagged "kind" of
    Text as "text"
        value : String
    Count as "count"
        value : Int

pub schema Tree tagged "kind" of
    Leaf as "leaf"
        value : Int
    Branch as "branch"
        children : List Tree
```

A field without `as` uses its declared field name as the external key; a
variant without `as` uses its constructor name text as the external tag.
Discriminators, tags and external keys are case-sensitive string data. The
`string` positions here require literal, noninterpolated strings; runtime key
composition belongs to the ordinary library builders. Duplicate external keys
are checked within a record or selected variant payload, including collisions
with its discriminator; different variants may reuse a key with different
schemas. Duplicate tags are checked across the whole union.

A schema parameter denotes an explicitly supplied schema, not evidence inferred
from a program type. `Page.schema (UserV1.schema ())` and
`Page.schema (UserV2.schema ())` may yield the same Type with different Encoded
representations. Multiple parameters are supplied in declaration order in one
saturated call. A schema can refer to itself or another schema in its module;
recursive descriptions use references, not eager expansion. Cross-module cycles
remain ordinary `import_cycle`. V1 recursion uses explicit nominal tagged
unions; implicit recursive record wrapping is deferred. The tagged `Tree`
supplies the necessary nominal constructors.

**Grammar checks, 2026-09-22.** Against `./zig-out/bin/beni`, version
`0.1.0-m1 aa57fab71568ff4271a7090db1db11d6`, temporary projects were run with
`check --no-cache --diagnostics=json`. These are grammar/resolution probes,
not schema implementation tests or performance measurements:

| Probe | Observed result | What it establishes |
|---|---|---|
| Real `Models/User.beni` with `pub type alias Type = { userId : Int }`; use `Models.User.Type` and `Models.User.schema ()` | exit 0 | Existing multi-segment module-qualified names and unit-argument calls |
| The same module imported `as User`, with a record-valued `User.Type` annotation | exit 0 | Existing alias qualification, not a schema namespace |
| `Page.Type Models.User.Type`, with `Page.Type a = { items : List a }` | exit 0 | Ordinary fully applied qualified type constructors |
| Real `Message/Encoded.beni`; pattern `Message.Encoded.Count row` | exit 0 | Multi-segment constructor patterns already parse and resolve for a real module |
| Ordinary `Schema enc val` custom type storing two Result-returning functions; explicit `page : Schema enc val -> Schema (List enc) (List val)` | exit 0 | Two endpoint parameters, n-ary signatures and explicit schema arguments need no new type-system feature |
| Values named `schema`, `via`, `optional`, `nullable`, `tagged` | exit 0 | These words are not globally reserved today |
| `pub schema User = { userId : Int as "user-id" }` | exit 1, `unbound_constructor`, `expected_token` | The declaration is new; rejection is expected, not a defect |
| `import Models exposing (User)` where Models exports an ordinary type User; then `User.Type` | exit 1, `unknown_module_alias` | Exposure of an upper name does not create a namespace today |
| `type alias Tree = { children : List Tree }` | exit 1, `recursive_alias` | Recursive records cannot be implemented as ordinary aliases |
| `pub val = User`, without a constructor User | exit 1, `unbound_constructor` | An upper expression name is not a schema value |

The schema namespace resolver, modifier grammar, schema operand interpretation,
two types per declaration, namespace exposure and nominal encoded constructors
are **new language work**, even where their tokens already parse. A stand-in
module proves no more than the corresponding table row. The separate imported
primitive-alias probe and missing H4 plan heading are queued, not repaired here.

## 3. Names and resolution

K13(b) is decided. A schema name is a **schema namespace binding**, distinct
from a value, type, constructor and module. It contains fixed type members,
its constructor families and callable members (§4). It does not introduce
user-defined general-purpose namespaces or a runtime namespace object.

Inside Models, `User.Type` selects the local schema's Type. Outside:

| Import | Type access | Value access | Names introduced unqualified |
|---|---|---|---|
| `import Models` | `Models.User.Type`, `Models.User.Encoded` | `Models.User.schema ()`; `Models.User.parse text` | Models only |
| `import Models as M` | `M.User.Type` | `M.User.schema ()` | M only |
| `import Models exposing (User)` | `User.Type`, and `Models.User.Type` | `User.schema ()` | Models and User, **not** Type, Encoded, parse or Count |

Resolve the visible module prefix through the ordinary import table, then the
schema segment through that module's public schema table, then a member of the
required kind. A locally declared or explicitly exposed schema is the other
valid root. An Encoded constructor has one further segment, as proposed in Q7.
The result is a dense resolved target, not a string lookup at runtime. Importing
Models does not implicitly import a filesystem module Models.User. Conversely,
importing a real Models.User continues to work as before.

Resolve only roots actually in scope; where both a module alias and a schema
path could name the same qualified access, report `schema_name_collision`
with both origins, rather than picking whichever lookup succeeds first. The
escape is an explicit import alias. This refusal prevents silently selecting a
different codec (G5); merely sharing a spelling with an ordinary type in its
separate namespace is not this ambiguity. An ordinary type User may coexist,
but then bare User denotes that separately declared type, never the schema's
Type. A warning may explain the confusion; it is not a new mandatory error.

`pub schema` exports the schema and its public members; unmarked schemas are
module-local. Visibility applies at every path segment. Duplicate local schema
names reuse `duplicate_declaration`; conflicts with an exposed schema reuse
`shadows_import`/`duplicate_exposed_name`. Unknown/private module members reuse
`unknown_import_name`/`private_name`; an unknown schema member uses §8's code.
Bare schema User in a type position is `schema_used_as_type` with the hint
`User.Type` or an explicit alias. In expression position it is
`schema_used_as_value` with `User.schema ()` (or explicit schema arguments).
`exposing (User.Type)` and `exposing (User(..))` are not added to the exposing
grammar; `expected_token`/`unexpected_token` apply. Exposing User exports no
constructors into the file's bare constructor namespace.

Schema namespace lookup is not static dispatch. A nominal member Type is
owned by the declaring module, so its methods still follow
`static-dispatch-spike.md` §1.2. This feature adds no well-known `a.schema`
method and never selects a wire format from a Type. Users can pass schema
values through ordinary functions.

## 4. Elaboration

Elaboration records one schema identity and two endpoint types. Nonrecursive
record endpoints are structural aliases; tagged endpoints are **distinct nominal
custom unions**, even when their payloads happen to coincide. Each variant has
its own encoded payload; Text.value may be String and Count.value Int without
agreement between variants. Constructors `Message.Count` and
`Message.Encoded.Count` are both constructible and exhaustively matchable.
Their codec writes/reads the declared tag under the discriminator. The literal
tag is description data, not a literal type or an extra editable record field.

For an operand with endpoints E and A, the modifiers elaborate as follows:

| Field form | Type field | Encoded field | External operation |
|---|---|---|---|
| `f : S` | A | E | Require key f; validate through S |
| `f : S as "k"` | A, still named f | E, still named f | Read/write only k |
| `f : S nullable` | Nullable A | Nullable E | Required key; null distinct from non-null |
| `f : S optional` | Presence A | Presence E | Missing key distinct from a present value; null still fails unless S accepts it |
| `f : S optional nullable` | Presence (Nullable A) | Presence (Nullable E) | Missing, present null, present value remain distinct |
| `f : S via c` | a, from c : Conversion b a | e, from S : Schema e b | Decode S then c.from; encode c.to then S; b must unify with c's source |

The source operand `Null` maps both endpoints to `Schema.Nullable Never`; its
sole inhabited successful value is `Schema.Null`, so `Never` alone is not an
endpoint. `FiniteFloat` maps both endpoints to `Float`; finite-value validation
remains an explicit primitive identity in the resolved plan.

Required/non-nullable is the default for primitives which do not themselves
admit null. Modifiers do not introduce JavaScript undefined or a general Beni
null. Optionality tests key presence, never truthiness: false, zero and empty
text are present. Transformations that collapse states are explicit and their
changed endpoints must be typed. `as` is applied once at external traversal,
not again during typed encode/decode or a projection.

Generic `Page a` yields `Page.Type a` and `Page.Encoded e`, with independent
endpoint variables related only by the supplied `Schema e a`. Its
factory is `Schema e a -> Schema (Page.Encoded e) (Page.Type a)`; a nongeneric
factory is `() -> Schema User.Encoded User.Type`. No annotation-level
computation of a type from an arbitrary runtime value is introduced.

The frontend emits unresolved schema plans with source regions and local
namespace skeletons. It cannot inspect an imported conversion's inferred type
while doing per-file BIR lowering. The checker resolves operands, unifies
conversion endpoints and produces an immutable, per-module **schema plan** for
the backend. This extends the backend input deliberately: it receives resolved
node kinds, child references, constructor targets, field names, conversion call
targets and provenance, never a live TypeStore. Do not pretend the declaration
can disappear into ordinary calls before imported types are known. Ordinary
library construction remains the semantic elaboration; the plan retains the
static shape needed to specialise it.

S1 stores that unresolved plan as a schema declaration plus a contiguous BIR
instruction graph. The declaration has a dedicated `schema_body` root and is
in neither the value nor type namespace. Plan instructions retain operand
name tokens, ordered argument edges, record fields, ordered modifiers, decoded
external keys/tags, tagged variants and explicit grouping. A `via` retains the
ordinary Atom tree, but unresolved nonlocal leaves use schema-expression
reference instructions carrying their symbol and source token; lexical locals
inside a parenthesised lambda or let remain ordinary local references. S2 can
therefore resolve the tree without reparsing source, and S1 does not report an
ordinary unbound-value error for a name whose schema meaning is not available
yet. All edges are indices or ranges in the flat BIR and every instruction
keeps its source token. Changing these tags or the declaration row bumps the
frontend artifact version; its reader validates every enum, root and range
before use.

`via` takes an input schema and a fallible conversion:

```text
conversion : (b -> Result (List Issue) a),
             (a -> Result (List Issue) b) -> Conversion b a
converted  : Schema e b, Conversion b a -> Schema e a
```

`Conversion b a` carries optional target checks, defaulting to none. Adding a
check uses a library combinator; it does not require a `Schema a a` endpoint.
Callback issues carry relative paths; the engine prefixes them and enforces
nonempty Err lists. Successful conversion into a runs its target checks;
conversion back validates b against the source endpoint before continuing.
The result keeps S.Encoded = e, including when S already transforms e to b.
Thus `String via decimalInt` has Encoded String and Type Int.

`Presence a = Missing | Present a` and `Nullable a = Null | NonNull a` are
separate library types. Field operands name schemas; primitive operand names
map to core/Schema. V1 includes String, Bool, safe Int, general and finite
Float, null, Value, lists, records, tagged unions, optionality and nullability,
with literal checks and enums as library combinators. Dict, tuples and BigInt
wait (§9); there are no literal types.

The schema namespace has `schema`, `parse`, `print`, `parseWith`, `printWith`,
Type/Encoded and their constructor families. Typed decode/encode, read/write,
flip and projections live only in core/Schema over `User.schema ()`.
Generic runners take explicit schema arguments first, then options for With,
then input. Parse takes JSON String; print returns JSON String. Parse returns `Result (List Issue) User.Type` (with generic parameters where
applicable); print returns `Result (List Issue) String`. Err payloads are nonempty. Issue records carry path,
direction, endpoint, structured code, message and optional reported input;
A.6 specifies their concrete public field and code declarations.

The interface required by `checker.md` §4/§7 contains:

- public schema names and their member-kind table, parameter arities and order;
- Type/Encoded alias expansions or nominal identities and constructor payload
  schemes, with visibility and qualified display names;
- factory/runner schemes with explicit schema parameters and ordinary arities;
- stable references by package, module, schema and member text, never session
  TypeId, Graph.Index or worker completion order.

Source positions, private executable schema plans and generated call targets
belong in the unhashed cache sidecar, with source/operand dependency hashes.
An importing checker sees the public endpoint contract without opening the
producer's source. Importing codegen may call the producer's specialised
function without importing its description. A public signature change moves
the interface hash; a private conversion body edit invalidates its emitted
body, and any code that specialised it, without fabricating a public type
change. A.6 specifies the added serialized columns, versions and sidecar
layout; readers discard on a version change.
Round-trip/cold/cache-hit results must agree, including schema member names.

Types, variants and plan node ids are assigned in source-derived order before
parallel work. Recursive SCCs use finite references; recursive instantiation
must not expand the type or description forever. Explicit nominal
recursion avoids inventing an implicit recursive alias fix.
Nonproductive cycles (a reference cycle with no input descent) must fail at
construction/execution under §5 rather than overflow or hang.

## 5. The description and `core/Schema`

**Context contract:** the schema engine owns and threads direction, full path,
root options, depth and unknown-key policy through every compiled or library
step; user transformations receive values and return relative failures, never
replace or reset that context.

This is the closure of report 33 §4's fifth finding, not advice to endpoint
authors. Public construction cannot accept raw `(Context, Value) -> …`
readers/writers or a transparent record of endpoints. Ordinary combinators
construct the engine's nodes; structural traversal and final Issue construction
belong to the engine. Typed conversion callbacks can fail, but cannot report
an absolute path that discards their parent's path, change options, claim that
a child consumed no depth, or supply their own key walker. A callback may
start an independent public parse, but that is a new root operation, not a
child traversal or a means to satisfy the parent's structural obligations.

Each endpoint retains its identity and checks; conversion targets may be
opaque rather than structurally described. Logical vocabulary:

| Node/data | Must retain |
|---|---|
| primitive | primitive identity, safe-integer/finite/general-number distinction |
| record/product | ordered fields; declared and external names separately; child schema references; presence/null flags |
| list | child schema reference; element index during traversal |
| tagged union | discriminator key, ordered literal tags, separate program/encoded constructor identities and payload references |
| conversion | source schema, target type identity and optional checks (none by default), separate fallible directional call targets; mark undescribed targets opaque |
| check | endpoint on which it runs; order; executable predicate/conversion reference; Q6's machine-readable metadata or explicit opaque marker |
| recursive reference | stable definition identity; a closed definition table, not an anonymous Deferred node |
| annotation | side and node/field it describes; Q6 decides the export/generation metadata surface |

This is a semantic vocabulary, not an existential Beni ADT declaration.
Heterogeneous fields may be implemented with typed private combinators and
closures over their children; inspection returns plain structural data with
stable references. No cast, runtime reflection on arbitrary Beni records,
existential type syntax or higher-kinded type is licensed. S3 must demonstrate
that the plain library builders express every accepted declaration and keep
context closed. Q11 deliberately leaves the stored-function ABI unfrozen.

`describe` collects the entire reachable graph on **both** endpoints. Traverse
in declared field/variant order; assign definition identities from stable
schema identity and structural position; deduplicate by identity, not display
name. Every reference resolves exactly once, including a nested recursive
schema within another recursive schema. This closes queue row 61's missing
child definitions and avoids expanding recursion. Describing never runs a
conversion or validator; a function body is not inspectable data.

The following core/Schema operations are required. `Failure` below abbreviates
`List Issue`, with nonempty Err as an invariant, not a built-in type.

```text
decode      : Schema e a, e -> Result Failure a
encode      : Schema e a, a -> Result Failure e
flip        : Schema e a -> Schema a e
typeOnly    : Schema e a -> Schema a a
encodedOnly : Schema e a -> Schema e e
describe    : Schema e a -> Description
read        : Schema e a, Value -> Result Failure a
write       : Schema e a, a -> Result Failure Value
parse       : Schema e a, String -> Result Failure a
print       : Schema e a, a -> Result Failure String
```

`flip` swaps endpoints **and** the two fallible directions. A double flip
restores their values, failures and checks. `typeOnly` and `encodedOnly` select
an actual endpoint and its checks, remove the cross-endpoint transformation,
and validate that endpoint in both directions. For an opaque conversion target,
typed projections run its optional checks, or are identity when none exist.
They do not rerun the conversion or invent structural checks. An opaque target
is reachable only through its conversion; constructing read/write operations
for any schema whose Type endpoint contains an opaque target without a
structural description fails at construction, not at runtime. For structurally
described endpoints, Encoded's external record shape
uses `as` keys; Type's endpoint uses declared Beni keys. Both tagged endpoint
representations retain the declared discriminator and literal tags, but map to
their own nominal constructor family. Thus flipping also selects the other
endpoint's external reader/writer; it does not pretend raw JSON has type e.
Projections cannot be implemented by reusing the other endpoint's reader. Composition decodes forward and encodes
backward, stopping a dependent chain at failure. Checks belong to an endpoint,
not to whichever function happened to be called first. Typed encode still
validates refinements: a Beni Int can be unsafe even though it is well typed.
No general guarantee of `encode (decode x) == x` is claimed for normalising or
lossy conversions; round-trip tests are explicit laws a schema author chooses.

The ordinary form includes primitive schemas, list construction, ordered record
field builders and a final typed product mapping, variant injection/projection
builders, deferred references, checks and fallible conversion composition.
Record builders carry both endpoint accumulators; their user mappings turn
already traversed typed products into records and back. They do not own paths
or key policy. An incorrect same-typed field swap is still a user conversion
bug; the declaration reads both directions from one field list. A dynamic
builder given duplicate keys/tags or a dangling reference returns a construction
failure, not a corrupt executable schema. The concrete builder API must be
specified before S3.

### Traversal and failure rules

One engine operation creates one root context, validates options, and hands it
to every child. The root starts at depth zero and path `[]`. Entering a field,
list element or variant payload increments structural depth; a limit is tested
**before** descent. A rename, check, conversion or reference resolution does
not reset depth. A nonproductive recursive-reference cycle is detected by the
active reference chain at the same input position and fails there. Lists use
iteration; recursive structures use bounded native recursion. Options default
to FirstError, Ignore unknown keys, sequential traversal and reportInput false,
following Effect. A root may override these through With. `maxDepth` has a
finite implementation ceiling: negative, nonintegral or above-ceiling requests
fail as invalid options at the root. The proposed default is 512 and candidate
ceiling 4,096; these numeric choices require the S3/S4 proof below, not an
assumption that JavaScript guarantees that many frames.

The ceiling must cover both interpreters and emitted workers, including helper
frames, conversion nesting and JSON output, across supported browser engines
and Node. Queue row 39 already records overflow near 3,700 calls for a different
function. S3/S4 must establish a conservative ceiling and the boundary handling
needed to preserve G1/G3 when callers have already consumed stack; record the
result here before shipping. No explicit traversal-frame stack is required.
Queue row 69 tracks this implementation proof.

Decode/read paths use external keys; encode paths use declared Beni keys for
program input, and an external-output failure uses its external key. Direction
and failing endpoint must remain distinguishable in the final Issue design
(§4). List indices are zero-based. A failed discriminator points at its key;
a variant payload adds no fictitious JSON field. Engine-attached relative
conversion paths are appended to the current path. Empty relative paths mean
this value, never the root. Missing-key and unknown-key failures include the
key itself; a key-count shortcut that loses it is invalid (report 34, row 62).

Follow pinned Effect's synchronous product order: check the enclosing shape,
then excess keys under Reject, then declared fields in declaration order;
lists visit increasing index. Unknown keys follow the adapter's stable own-key
order (JSON's post-parse object order), independent of schema hash-table order.
Tagged dispatch first validates the discriminator, then processes only the
selected payload; the discriminator is a claimed key. Input key reordering
cannot change acceptance or the decoded value. It may reorder multiple
unknown-key issues; it may not affect declared-field traversal.

FirstError is lazy: later siblings and their conversions are not started.
AllErrors visits independent siblings even if an earlier field's structural
validation failed. Each field performs its structural checks and conversions
before moving on; there is no whole-record Encoded staging barrier that hides
a later sibling's conversion failure. A composite check or whole-record
conversion waits until all children succeeded; no fictitious partial record is
passed to it. Both directions obey this dependency rule. Issues are appended
in traversal order, not sorted after execution. Sequential is the synchronous
contract; concurrency is effects work (§7), not an optimisation of it.

Unknown keys are either ignored by the chosen policy or rejected at their own
paths. They are never copied accidentally to a closed typed record. Keys such
as `__proto__`, `constructor` and `toString` are ordinary external keys: use
own-property lookup and safe output property construction, never inherited
lookup or prototype mutation. JSON duplicate keys follow JSON.parse's last
value semantics; this specification does not invent lossless token parsing.
Arbitrary host objects, getters, proxies and JS undefined are not Beni Value.
A future foreign-object adapter must specify them inside the privilege wall,
not inherit the benchmark's JSON-only results (queue rows 64–65).

`Schema.int` uses safe-integer validation both ways: integral finite numbers
within −(2^53−1)…2^53−1. JSON numbers have JSON.parse semantics, including
rounding before schema validation. Float and finite Float remain distinct;
printing NaN/infinity as JSON null is not a successful numeric encoding.
JSON printing of negative zero follows JSON.stringify semantics. Parsing or
printing malformed/unrepresentable data returns Result with a root or precise
child path. The format adapter catches defined host failures under
`boundary.md` §4.1. It must not recursively marshal unbounded host data before
the engine can apply its bound. There is no host-to-Value marshalling step;
JSON output must also respect the bound and translate defined host failures.

### Pinned Effect semantics

Routine behavior follows **Effect 4.0.0-rc.116**, commit
`3d59ae6d5f9ff3e52cb6ed4a9f325320580218d5`, read locally:

- [SchemaAST.ts](../../references/effect/packages/effect/src/SchemaAST.ts),
  `ParseOptions` (around line 451) and object parser (around 2910): first errors,
  ignored excess properties, sequential products by default; excess-key
  pointers and checks before fields. These are the adopted defaults.
- [Schema.ts](../../references/effect/packages/effect/src/Schema.ts),
  `optionalKey`, `NullOr`, `toType`, `toEncoded` and `isInt` (around 7548): exact
  presence separate from null, endpoint projection, Number.isSafeInteger.
  Beni's optional corresponds to **optionalKey**, not Effect's
  optional(UndefinedOr); Beni has no undefined value.
- [SchemaTransformation.ts](../../references/effect/packages/effect/src/SchemaTransformation.ts),
  `Transformation.flip` and `compose` (around 178–260): swap both directions,
  compose decode forward and encode backward.
- [SchemaGetter.ts](../../references/effect/packages/effect/src/SchemaGetter.ts),
  JSON getter (around 1225): JSON.parse, not preserved number lexemes.

Explicit Beni departures are typed presence wrappers, a bounded traversal,
closed context ownership around callbacks, and the compiler-produced static
path. Effect's callbacks can receive options and construct issues themselves;
copying that escape would reintroduce report 33's gap. No per-behavior owner
question is needed where this pinned implementation already supplies the rule.

## 6. Codegen

A declaration emits ordinary module-local top-level values/functions. A
nongeneric description is an immutable finite graph constant; `schema ()`
returns it through the typed library wrapper. A generic description is a
constant skeleton with parameter slots; its factory fills those slots from
explicit schema arguments. Recursive edges are ids/references, not an eager
factory call to itself during module initialisation.

`User.parse`/`User.print` are independently reachable compiled directions.
The resolved schema plan lowers directly into JsIr: raw host inputs are not
well-typed Beni values, so routing validation through typed BIR would require
a marshaller or an unsound cast. Library interpretation uses privileged
core foreign primitives over the same host value. Emitted runners use normal
saturated arities, ordinary cross-module calls, and normal Result constructors. Internally, a root wrapper
creates context once and invokes a specialised worker accepting the engine's
context. Child calls use workers, never root wrappers that reset it.

Development names encode schema boundaries with a reserved separator, e.g.
`Models$User$$parse`, `Models$User$$print`, `Models$User$$description`, distinct
from ordinary `Models.User` module members. Encoded constructor identities
likewise include the endpoint. Reuse `backend.md` §4's actual ADT/list/record
representations and §5's import/export machinery; no runtime schema namespace
object, source generator, user macro or emitted Beni file is involved.

| Construct | Specialised emitted shape, in both directions |
|---|---|
| record | Test object shape; implement excess-key policy; direct own-key presence/read checks per field; bind each validated/transformed child once; construct the typed record with canonical key order after evaluation in declaration order. Reverse uses typed field reads and safe external-key writes. |
| list | A loop over input positions/cons cells as appropriate, with index and depth carried by the engine; output in original order. No JavaScript recursive call per list cell. |
| tagged union | Read/test the discriminator once; switch over literal tags; compile each payload's checks and failures. Reverse switches over the input endpoint's nominal constructor; no flattened record of Maybe payloads. |
| recursive schema | Specialised native-recursive workers; references call the known worker with the existing path/depth and check the bounded depth before descent. Never infinitely expand a recursive schema at compile time or recurse on the host stack without a bound. |
| renamed key | Read/write `raw["user-id"]`, construct/read Beni `userId`; the other external spelling is an unknown key, not an alias accepted opportunistically. |
| transformation | Direct ordinary call of the chosen directional function after its input endpoint succeeds; test Result and attach engine context to relative failures; validate the output endpoint. |
| failure | The same specialised branch that detects failure constructs its Issue at that path and continues/stops per options. No retry through a generic interpreter to discover why the fast predicate failed. |

“Straight-line” means specialised shape tests and direct calls; lists have
loops and unions branches. It does not mean unrolling runtime lengths.
Error objects, captured failing input and rendered error prose are allocated
only after failure; success may allocate its result value and traversal state.
A shared cold helper may construct a known Issue, but must not interpret a
description or rerun user conversions. The callback's own Result failure is
ordinary data, not an exception or a new interpreter fallback.

For example, **emission pseudocode**, not a new host API or fixed Result ABI:

```text
User.parse(text):
    ctx = root(options, decoding)
    raw = jsonParseOrFailure(text, ctx)
    requireObject(raw, ctx)
    checkExcessKeys(raw, ["user-id"], ctx)
    requireOwnKey(raw, "user-id", ctx)
    id = requireSafeInteger(raw["user-id"], child(ctx, "user-id"))
    return Ok({ userId: id })

User.print(value):
    ctx = root(options, encoding)
    id = requireSafeInteger(value.userId, child(ctx, "userId"))
    return jsonPrintOrFailure({ ["user-id"]: id }, ctx)
```

For the single-field record under a caller-selected FirstError policy, the
worker's JavaScript has this shape (helper names are illustrative trusted core
operations, not public API or an adopted internal ABI):

```js
const Models$User$$read = (raw, ctx) => {
  if (!Schema$isObject(raw)) {
    return Schema$failure(ctx, [], "wrong_shape", "expected an object");
  }
  if (Schema$rejectUnknown(ctx)) {
    for (const key of Schema$ownKeys(raw)) {
      if (key !== "user-id") {
        return Schema$failure(ctx, [key], "unknown_key", "unexpected key");
      }
    }
  }
  if (!Schema$hasOwn(raw, "user-id")) {
    return Schema$failure(ctx, ["user-id"], "missing", "required key");
  }
  if (!Schema$canDescend(ctx)) {
    return Schema$failure(ctx, ["user-id"], "depth", "depth limit reached");
  }
  const id = raw["user-id"];
  if (!Schema$isSafeInteger(id)) {
    return Schema$failure(ctx, ["user-id"], "check", "expected a safe integer");
  }
  return { $: "Ok", a: { userId: id } };
};
```

The failure helper attaches the relative suffix to ctx and constructs the
chosen Issue/Result representation; it does not rediscover the failing branch
from a description. A print worker has the same safe-integer failure test over
`value.userId` before constructing the external `"user-id"` property. AllErrors
emits accumulation branches in place of these early returns. A child worker
receives incremented context; this leaf example only needs a descent check.

Every `require…` above stands for a compiled test and a compiled failure branch,
not an actual throwing helper. AllErrors retains successful child temporaries
and failed-child state until the composite result is known. Both directions
validate even where the Beni type alone cannot enforce the refinement.

**The static/dynamic line.** A syntactic declaration has a known skeleton and
is specialised. References to other declarations are known calls, including
across interfaces; callbacks need not be evaluated or inlined to specialise
the surrounding structure. Generic parameter slots take the library path
when their schema values are supplied at runtime, while the known outer shape
remains specialised. Runtime branches selecting schemas and ordinary runtime
builder calls are library operations; S4 need not perform general constant
evaluation or whole-program monomorphisation. A future recogniser may specialise
statically known plain builder composition, but may change no semantics. There
is no eval/new Function, including capability probes, on either path.

A declaration that depends on a dynamic child must pass its **existing engine
context** to that child's library worker. A differential test forces the whole
root through the library; simply comparing two wrappers calling the same
specialised worker is not evidence. Neither path may select itself through a
user-visible “fast but less diagnostic” mode.

**DCE.** Description, parse, print and each additional runner/worker are separate
declaration nodes. Parse reaches its decoder/check targets and failure helpers;
print reaches its encoder/check targets and helpers. Neither gets an automatic
edge to the opposite direction or the description. A reflection or dynamic
schema use reaches the description and the executable child/callback data it
actually needs. An application using only parse must be able to ship no print
and no unused description; `--library` still roots the exported surface.
Resolved schema-plan edges join the shared edge walk used for reachability and
initialisation, so callback-only references cannot disappear. Recursive graph
constants use references and dependency-ordered initialisation, not a TDZ cycle.

`--release` applies the existing renaming, local-binding and printing rules,
with identical results and Issues. It does not enable specialisation, drop
validation, change integer acceptance or external key/tag strings. Never
rebuild untouched input subobjects merely as an optimiser rewrite: field
identity remains load-bearing for browser UI (CLAUDE.md rule 8). Impure callback
rules, when effects land, constrain duplication/elimination as for any call.

**Performance target, not a Beni measurement.** The commissioning summary is
13–18× smaller brotli than Zod/Effect, about 3 ms import versus 80–270 ms,
2–4× below Zod on selected net-validation comparisons, and roughly 15× loss
when a compiled success path delegates failures to interpretation. Report 34
§4's exact flat decode cells are Ajv standalone **1,275 B**, Typia **1,758 B**,
Zod **23,650 B**, Effect **22,536 B** (brotli-11); imports **2.960 ms** for Ajv
standalone, **80.062** Zod, **175.156** Effect, **267.373** TypeBox Compile.
Typia's unbundled import is **54.124 ms**, not 3 ms. These cells explain the
architecture target without claiming every AOT implementation has one cost.

Report 34 §6's selected gross decode-success ratios to Zod are **0.482–0.934×**
for Ajv standalone; TypeBox Compile decode-failure ratios are **4.864–34.588×**
(and encode-failure **6.167–90.855×**). Thus “2–4×” and “15×” are not universal
orderings or acceptance thresholds. Net is subtraction of measured medians,
not isolated validation time. There are 91 flipped selected pairwise orderings.
The capture is one machine, synchronous JSON-shaped data and one fault per
invalid payload; native rename is not fused, browser bundles cover only the
flat workload, and startup is Node fresh-module import with an unflushed OS
cache, not browser loading. No many-schema code-size curve, effectful codec or
arbitrary-JS-object parity is established. The fused-decoder and optional Effect
compiler rows have **not landed in this capture** and remain owed. S4 adds a
Beni row and reports per-operation medians/orderings, both directions and all
fault paths, without a geometric-mean parity claim or a new measurement here.

## 7. Effects

Effectful transformations are part of the intended design. Synchronous delivery
first does not make “decode then fetch” a language restriction. An emitted
parse or print is an ordinary top-level function: under P2 its `suspends` and
`impure` bits are inferred from the directional calls it makes, like any other
function. Specialisation cannot bypass those calls or their inference.

The description's stored callbacks, recursive thunks and endpoint validators
are **H4**, a P2 question, synchronous until P2 lands. `Schema e a` naming only
two data parameters does not prove that hidden function bits survive an opaque
nominal abstraction or an imported interface. This contract fixes semantic
endpoints and context ownership, not that ABI. Q11 remains open; no unconditional
purity claim about a conversion, no blanket suspending fallback, no duplicated
sync/async public API and no effects-runtime implementation is authorised here.
The requested `plans/effects-plan.md` “§H4” does not exist at this revision;
its §3 and §7 cover related inference risks. The concrete H4 obligation is
[the prototype's EFFECTS.md](../../bench/schema-prototype/EFFECTS.md), and the
missing plan anchor is recorded in the queue.

S5, after P2, owes all seven acceptance cases there through **both** paths:

1. A suspending decoder and pure encoder exported from A through the intended
   abstraction; B composes object/list, parks/resumes, returns the exact value,
   and its interface retains only the decoder's suspension bit.
2. Flip moves suspension to encoding; double flip restores both bits and behavior.
3. One generic combinator accepts pure and suspending transformations in the same
   program; local extraction gives P2's specified monomorphisation diagnostic
   rather than wrong lowering.
4. Suspension inside recursive fields/lists retains the complete path and depth;
   cancellation stops further conversions and runs registered finalisers.
5. FirstError starts no later siblings; AllErrors follows its specified scheduling
   policy, retains every Issue, and records the expected effect order.
6. Failures after suspension in either direction, including flip, remain ordinary
   directional failures, never suspension objects mistaken for successful data.
7. Main, DOM and foreign callback boundaries either admit a specified async
   contract or reject a suspending runner with the full sync diagnostic chain.

Independent directional impurity must survive as well. Passing these requires
compiler/runtime work; today's synchronous prototype cannot settle it.

## 8. Diagnostics

These new compiler codes are appended to `language.md` §10, in this order.
`duplicate_schema_modifier` is emitted by S1 lowering; the remaining codes are
reserved for later slices. Every error protects a unique typed
or executable interpretation (G1/G5), or correct failure context (G2–G4);
none refuses an inconvenient but unambiguous valid schema for taste.

| Code | Title | Primary region and message shape |
|---|---|---|
| `schema_used_as_type` | SCHEMA IS NOT A TYPE | The bare schema name: “`User` names a schema. Its program type is `User.Type`; its encoded type is `User.Encoded`.” |
| `schema_used_as_value` | SCHEMA IS NOT A VALUE | The bare schema name: “`User` names a schema namespace. Pass its description with `User.schema ()`.” For generics, name required schema arguments instead of suggesting unit. |
| `schema_name_collision` | AMBIGUOUS SCHEMA NAME | The second binding/path: “`User` can name this schema and this module alias.” Show both locations and an import-alias example. |
| `unknown_schema_member` | UNKNOWN SCHEMA MEMBER | The final segment: “`User` has no [type/value/constructor] member called `X`.” List members of the required kind, respecting visibility. |
| `expected_schema` | EXPECTED A SCHEMA | The operand: “This field needs a schema, but `T` names a type/value.” Show the actual kind and how to name a declared schema or explicit schema parameter. |
| `duplicate_schema_key` | DUPLICATE EXTERNAL KEY | The second field/tag discriminator collision: “Both `a` and `b` read and write `k`.” Show both field regions and the external key. |
| `duplicate_schema_tag` | DUPLICATE SCHEMA TAG | The second variant: “`A` and `B` both use tag `t` under `kind`.” Show both declarations; do not report shared payload field names across different variants. |
| `duplicate_schema_modifier` | DUPLICATE SCHEMA MODIFIER | The second modifier: “This field already has [modifier] here.” Show the first region; two `via` conversions should be explicitly composed. |
| `schema_conversion_mismatch` | SCHEMA CONVERSION MISMATCH | The via expression: show expected source/target endpoint types and actual types separately, plus the originating field. For S : Schema e b and c : Conversion b a, require matching b and produce Schema e a. |

Reuse ordinary parse codes for malformed syntax, `duplicate_field` for Beni
field names, `duplicate_type_parameter`/`unbound_type_variable` for parameters,
`wrong_type_arity` for Type/Encoded application, ordinary call-arity diagnostics
for factories/runners, and `type_mismatch` for mixing nominal endpoints.
`missing_patterns`/`redundant_pattern` continue to decide both constructor
families. Recursive records obey the existing recursive-alias rule; v1 recursive
schemas use explicit nominal tagged unions.

Each new code gets a full diagnostic golden: stable code, title, severity,
span, full prose and ordering. Render qualified member types in source spelling;
wrap prose after interpolation under `checker.md` §8.4. Compiler errors cause
exit 1 and no build output. Runtime validation failures are **Issue values in
Result**, not compiler diagnostics, stderr output or process exit codes; their
fixtures assert complete values.

S2 accepts schema programs in `check` and in resolution-requiring dumps.
`build` still reports `not_implemented` on the schema name from `Emit.run`,
before entry discovery or any output: “This schema is checked, but its parse
and print are not generated until schema S4.” This replaces S1's frontend
refusal; a successful check does not claim executable runners. A frontend or
checker error keeps its own diagnostic without adding this refusal.

## 9. What v1 leaves out

The committed scope excludes an effects runtime (S5 follows P2), implicit
currying/evidence selection of schema arguments, arbitrary computation of types
from runtime descriptions, and automatic replacement of platform ports.
The first two follow the accepted language model; runtime type computation
would need a separate type-system design; ports need a boundary contract and
measurement before replacement. Schema parse/print do not change main or grant
ordinary packages foreign privilege.

The following exclusions are settled except defaults (Q3) and tooling (Q6),
which remain recommendations:

| Capability | Why wait | Where it would go |
|---|---|---|
| Dict/dynamic key schemas, tuples | Key conversion collisions and tuple representation/arity need a precise contract | §2/§4/§5 library combinators |
| exact BigInt / lossless numeric lexemes | Beni has no exact large-integer representation; JSON.parse already rounds | core numeric/boundary design, then §5 adapters |
| declaration defaults | Missing/null/failure recovery and encode omission must not be conflated | Q3, §2/§4 and directional library nodes |
| JSON Schema output and generators | Arbitrary checks/conversions cannot be inferred from functions; unsatisfiable checks cannot promise a sample | Q6, description interpreters returning Result; explicit unsupported/check metadata |
| implicit recursive record wrapping and opaque-schema sugar | Need constructor ownership, names and construction rules; report 32 left a circular constructor/conversion story | §2–§4; ordinary explicit nominal types and typed conversion endpoints remain available |
| rest-field preservation | Closed Type needs an explicit place for extras and collision rules | record vocabulary in §5 |

Mapped-type operations (pick/omit/partial), JSON Schema import creating new
static types at runtime, optics and patch interpreters are not smuggled into
v1 under “Effect parity”. Report 32's inventory remains the capability backlog;
a second explicit type/schema is available where type computation is absent.
Library inspection/format adapters may evolve without adding compiler-known
JSON-specific modifiers. Ordinary validation checks do not claim a nominal
value invariant; opaque types with checked constructors are available when
that stronger invariant is wanted. There is no ban on checks simply because
an author can construct an unchecked value of the same structural type.

## 10. Testing and slices

S1 provides the frontend, including §2/A.5’s brace-equivalent layout spelling;
the independent row 67 checker fix has also landed
(A.4). Q7 is confirmed in A.6. Later slices retain the dependencies below.
Each begins with a fixture that fails on the preceding compiler/library; prove
red, implement, then reverse the fix in an isolated copy to prove the regression
is specific.
A negative fixture must first be shown to diagnose the intended defect, not
merely fail because `schema` is still unknown. Runtime behavior belongs under
`tests/corpus/run/`, and emitted JS is executed. No in-source test substitutes
for this boundary. Follow the write-tests skill when implementation starts.

| Slice | Contract | Red fixtures first | Done means |
|---|---|---|---|
| S1 — frontend | §2, §8; syntax decisions settled in A.2; independent of row 67 | `parse/good`, `parse/bad`, `fmt`, `bir`: records, modifier boundaries, contextual-word values, generic operands, tagged recursion, recovery and comment retention | AST/BIR dumps expose source intent, formatter is idempotent and parse-preserving, every new parse diagnostic exact; later phases explicitly refuse unsupported schema builds instead of succeeding without them |
| S2 — checker (**implemented**, 2026-09-22) | §3–§4, §8; settle Q7; fix queue row 67 first | `check/good` interfaces for two schemas/module, alias/exposing/qualified access, explicit generic arguments, distinct union endpoints; `check/bad` for every new code, wrong endpoints, private members and constructor exhaustiveness | Types and names work through imported/serialized interfaces; cache miss/hit and jobs 1/8 agree; schema plan and sidecar format specified and tested; remove S1’s whole-input schema exclusion from resolver fuzz; no successful build silently omits runners |
| S3 — library and description | §1, §4–§5, §9; settle Q3/Q6 and concrete Issue/builders; prove row 69; preserve Q11 | `run/`: both fallible directions, flip twice, projections with different endpoint shapes, renamed keys, every missing/null/present combination, ordered sibling structural+conversion failures, FirstError laziness, depth 0/bound/bound+1, prototype keys, nested recursive definition closure, runtime construction errors | Plain builders express each accepted declaration and obey closed context; exact values/Issues/description graphs in development/release; JSON host failures return Result; no H4 claim or fixed effects ABI |
| S4 — specialisation | §6 and this section; settle Q9; prove row 69 | `run/` differential twins; `emit/`, `emit/release/`, `emit/app/`: direct checks, compiled failure branches, loops, recursive workers, parse-only/print-only/description-only DCE; cached cross-module callback dependencies | Both paths yield identical expected values and complete Issue lists; all three gates pass; add **beni** to `bench/schema-libraries` with strict/no-default options, publish per-operation medians, faults, startup, sizes and caveats; measure many-schema growth and browser behavior before a parity claim |
| S5 — effects after P2 | §7; resolve Q11 in the effects specification first | All seven EFFECTS.md cases: `run/`, cross-module `.iface`, `check/bad` sync/extraction diagnostics, cancellation/finalisers and both directions | Directional bits and context survive abstraction/import/suspension in compiled and library paths, no conversion after cancellation, exact effect order and ordinary failures, unchanged sync behavior |

The differential corpus runs **every schema semantic fixture** via the emitted
path and an explicitly forced library path, with the same input, options and
schema, comparing complete success values or full ordered Issue lists. It also
asserts independent expected answers: two identical bugs do not pass. Include
AllErrors with a structural failure in one field and a conversion failure in
a later sibling, a dynamic child below a specialised parent, encode-only
failure after flip, and recursive failures with renamed external keys. Exercise
typed decode/encode and text/Value boundaries, not just valid JSON parsing.

A test-only way to force library interpretation must be specified with Q9;
it must not become a production flag changing semantics. Description-only
execution must not silently call a cached compiled validator. `emit/` asserts
shape, `run/` asserts behavior, and DCE fixtures assert absent files/declarations
as well as values. Jobs 1/8 twice byte-compare dumps, diagnostics and complete
output trees; interface/cache round trips are part of S2/S4 acceptance.

The three existing gates remain `zig build test`, `zig build test-blackbox`,
`zig build fmt-check`. Q9 recommends putting differential execution in the
second; it is **not wired by this spec commit**. Chrome semantic checks and
report 34 performance measurements are S4 evidence, not timing thresholds in
an otherwise deterministic correctness gate. A failing test is investigated,
not fixed by blessing all goldens. No new measurements are run for this document.

## Appendix A. Decisions log

### A.1 — Description plus specialised functions (2026-09-22)

**Decided by the owner in this specification commission:** a declaration
produces an inspectable description and specialised top-level parse/print
functions; both success and failure paths compile, errors allocate only on
failure, and each direction is independently reachable by DCE. Runtime
composition retains the library path. Both paths obey §5's one context contract
and are differentially tested.

Evidence: report 33's two endpoints work, but arbitrary user endpoints lose
paths/options/depth with exit 0; report 34's AOT size/startup cells and separate
failure timings support specialisation without abandoning inspection or runtime
composition. §6 records the numbers and their limits. This replaces report 32's
“specialise later under release” recommendation; it does not claim H4 solved.

The compiled path validates the raw host value in one pass and never constructs
a Value ADT. Generated validation is JsIr, because its input is untyped host
data, not typed BIR. The library path uses core foreign primitives over the
same host value. `Value` is an opaque handle, not a marshalling requirement.
This keeps S3 from imposing report 34's unfused cost on S4.

### A.2 — Surface and traversal decisions (2026-09-22)

Owner review accepted Q1: input schema plus fallible `Conversion b a`, optional
target checks defaulting to none; Q2: the recommended v1 primitives with
Dict/tuples/BigInt deferred; Q4: ordinary `Result (List Issue)` and nonempty Err
invariant; Q5: Effect defaults and a bounded maxDepth with native recursion;
Q8: schema/parse/print plus parseWith/printWith only, typed operations in the
library; Q10: schema operands, separate Presence/Nullable, explicit nominal
recursion. §§2–6 record these decisions. Exact safe depth numbers still need
implementation evidence (queue row 69). Q3/Q6/Q7/Q9/Q11 remain open.

### A.3 — Implementation order (2026-09-22)

The owner delegated Q12. Schedule S1 next; fix confirmed numeric-alias defect
67 before S2. Continue S2–S4 in dependency order after their remaining decisions;
S5 follows P2 and H4. The recorded M4-first slices 1–3 have landed, so this
places schemas ahead of remaining M4 work without rewriting that history.
This revision changes documents only; it does not claim any slice landed.


### A.4 — Opaque boundary construction and parallel scheduling (2026-09-22)

The owner settled Q6's representation clause: an opaque target is reachable
only through its conversion; typeOnly retains optional checks (identity if none),
and read/write construction fails if Type contains an opaque target without a
structural description (§5). Q6's metadata and JSON Schema/generator scope
remain open. Row 67 is an independent checker fix with check/good fixtures:
it may run in parallel with S1, and must land before S2. This updates A.3's
ordering without making the fix a dependency of S1.


### A.5 — Layout record declarations (2026-09-22)

The owner adopted option A of [research 35](research/35-record-syntax-in-ml-languages.md)
§5.1–§5.2/§5.5, with Lean's field-ending column rule (§3.1) and Koka's
explicit desugaring model as evidence. Bare aligned fields after `=` in record
`type alias` and `schema` declarations, nested whole-field blocks, and aligned
tagged schema variants are sugar for the existing brace/bar forms. Both inputs
produce identical AST/BIR dumps; no checker, resolver, BIR or backend semantics
change. Two-token `lower_ident ':'` lookahead and the enclosing field column
decide nesting and continuation (`language.md` §3–§4).

The formatter always chooses vertical layout for nonempty closed declaration
record bodies and tagged variants, even for one-line input. Braces remain
where a block cannot go: inline record types/operands, extensible records,
ordinary `type` constructor payloads, empty records and all record values.
A schema record with outer modifiers remains a brace operand because the
layout field-block production has no outer modifiers. Ordinary `type`, `case`
and `let` are unchanged. This surface slice follows S1 and precedes S2.


### A.6 — S2 type surface, interface and resolved plan (2026-09-22)

The owner confirmed Q7: constructor patterns use exactly the expression name.
The program family is `Message.Count row`; the encoded family is
`Message.Encoded.Count row`; a module prefix may precede either. Exposing a
schema exposes neither family as bare constructors.

`core/Schema.beni` establishes the public type surface which S3 and S4
implement against. `Presence` and `Nullable` are distinct custom types.
`Issue` is a record carrying `path : List PathSegment`, `direction : Direction`,
`endpoint : Endpoint`, a structured `IssueCode`, `message : String`, and
`input : Maybe Value`; `Value` is an opaque host handle rather than a Beni
value tree. `Options` is a record with `errors : ErrorMode`,
`unknownKeys : UnknownKeys`, `maxDepth : Int`, and `reportInput : Bool`.
Defaults are `FirstError`, `Ignore`, and `reportInput = False`; S3's stack
proof still decides the default and maximum depth numbers. `InvalidSchema`
covers a malformed or dangling description and nonproductive recursion;
`ConversionFailed` includes a callback which violates the nonempty `Err`
invariant. `Schema e a`, `Conversion b a`, and `Value` are `pub foreign type`s
whose JavaScript representations belong to the engine. This is a type
contract, not a frozen representation: Q11 remains open and S2 adds no
directional callback ABI or library functions.

The hashed interface grows three columns. `schemas` is sorted by schema-name
text; `schema_members` is grouped by schema in the fixed order `Type`,
`Encoded`, `schema`, `parse`, `print`, `parseWith`, `printWith`; and
`schema_ctors` is grouped by schema, program family before encoded family,
then variant source order. `Schema.params_len` is the parameter arity; source
parameter spellings remain in the unhashed plan's Definition range. Interface
dumps generate ordinal names as they do for ordinary type rows, so
alpha-renaming a parameter does not move the interface hash.
Only public schemas occur in an interface; member and constructor rows retain
an explicit visibility bit and readers require it to be public.

```text
Schema (32 bytes)
  name: SymbolIndex
  params_len: u32
  members_start, members_end: u32
  program_ctors_start, program_ctors_end: u32
  encoded_ctors_start, encoded_ctors_end: u32

SchemaMember (16 bytes)
  name: SymbolIndex
  schema: SchemaIndex
  scheme: SchemeIndex
  kind: u8       Type | Encoded | schema | parse | print | parseWith | printWith
  arity: u8      255 means derive the larger arity from params_len and scheme
  flags: u8      bit 0 visible
  pad: u8        zero

SchemaCtor (16 bytes)
  name: SymbolIndex
  schema: SchemaIndex
  scheme: SchemeIndex
  endpoint: u8   Type | Encoded
  arity: u8      zero or one
  flags: u8      bit 0 visible
  pad: u8        zero
```

Every member and constructor has a complete scheme. `Page.Type` quantifies
the declared program parameter `a`; `Page.Encoded` independently quantifies
its encoded parameter `e`; the factory quantifies each `(e, a)` pair and takes
the corresponding explicit `Schema e a` arguments. A structural endpoint is
an `alias` term carrying both its stable `(package, module, "User.Type")`
identity and expansion; a tagged endpoint is an `app` term naming that stable
nominal identity. `Encoded` uses the parallel identity. Constructor schemes
include their payload and nominal result. Factory and runner schemes include
all explicit schema parameters and their ordinary saturated arity. Thus an
importer reconstructs every endpoint and callable from the interface alone;
it never opens the producer's BIR. Generated full endpoint identities such as
`Page.Type` and `Page.Encoded`, generated encoded-side quantifier names, and
the fixed member names are pre-interned serially before workers or cache loads
begin.

The member `arity` byte is a lookup hint for the ordinary case, not a language
limit. Values through 254 are exact; 255 means the complete arity is derived
from the schema's `params_len` and the member's scheme. No schema declaration
is refused merely because its explicit parameter count does not fit in a byte.

The interface byte format becomes version 2 with fourteen columns, in order:
`values`, `types`, `ctors`, `schemes`, `term_tags`, `term_lhs`, `term_rhs`,
`extra`, `type_refs`, `schemas`, `schema_members`, `schema_ctors`, `symbols`,
`strings`. Existing scalar, alignment, symbol-text and little-endian rules are
unchanged. Readers validate schema/member/constructor ranges, kinds, schemes,
arity and visibility. Any failure, including a
version mismatch, is a cache miss. The front-end artifact becomes version 3;
this is the explicit S2 boundary after S1's version 2 unresolved schema graph,
and its existing `verifySchemaInst` validation remains mandatory. *(2026-09-24: the
checker rewrite's R1 made it version 4 — `Token.Tag` gained `dot_dot`, which
shifts later tags, and `Bir.Exposed` gained `all_ctors_token` — with no change
to the schema sections.)* In S2, `via`
leaves use ordinary value-reference instructions and declaration references:
these are real value dependencies for mixed schema/value SCCs and cache keys.
The BIR dump therefore shows `qualified` and `import_value` for imported
conversion leaves where S1 showed inert `schema_expr_ref` placeholders. This
is a permanent dependency representation, not a temporary execution surface.

The unhashed cache sidecar gains one resolved-plan section. The cache entry
becomes version 2 (3 since the checker rewrite's R2a, whose `dispatch` section is
`dispatch_bytes` format 2, `checker-v2.md` §14.3) and its sections are `interface`, `dispatch`, `schema_plan`,
`diagnostics`. `schema_plan` uses magic `BENISPL\0`, format version 1, the
standard column table, little-endian scalars, four-byte alignment and
zero-filled gaps. It has these columns in order:

```text
definitions, node_tags, node_lhs, node_rhs, node_tokens,
fields, variants, conversions, checks, annotations, extra,
term_tags, term_lhs, term_rhs, type_extra, type_refs,
literals, literal_bytes, symbols, schema_targets, ctor_targets, strings
```

`definitions` is source order. One 44-byte row contains the schema-name
`SymbolIndex`, own `Bir.DeclIndex`, parameter `extra` range, root node,
program and encoded endpoint `TypeRefIndex` values, canonical generic program
and encoded endpoint `TermIndex` roots, the schema-name token, one settled
property byte per endpoint, and two zero pad bytes. Property bits are
equatable, comparable and has-function in bits 0–2; all other bits are zero.
The two canonical terms carry the resolved declaration-generic endpoint expansions;
the dependency digest reads those terms for a private endpoint reachable from
a public scheme, never an incidental specialized use and never executable
plan or `via` data.
Nodes are SoA rows `(tag, lhs, rhs, token)` with this finite meaning:

| Tag | `lhs` | `rhs` |
|---|---|---|
| `parameter` | declaration parameter ordinal | zero |
| `primitive` | `String`, `Bool`, safe `Int`, `Float`, finite `Float`, null or `Value` | zero |
| `reference` | `SchemaTargetIndex` | `extra` range of child node arguments |
| `record` | first `FieldIndex` | past-last `FieldIndex` |
| `list` | child `NodeIndex` | zero |
| `tagged` | discriminator `LiteralIndex` | `extra` range of `VariantIndex` values |
| `conversion` | source `NodeIndex` | `ConversionIndex` |
| `check` | checked child `NodeIndex` | `CheckIndex` |
| `annotation` | annotated child `NodeIndex` | `AnnotationIndex` |
| `nullable` | child `NodeIndex` | zero |

Optionality is a field flag because it is meaningful only at a record field.
A 20-byte field row is `{ name: SymbolIndex, external: LiteralIndex,
child: NodeIndex, flags: u8, pad: [3]u8, token: u32 }`, with bit 0 meaning
optional. A 24-byte variant row is `{ name: SymbolIndex,
external: LiteralIndex, payload: NodeIndex.Optional, program_ctor:
CtorTargetIndex, encoded_ctor: CtorTargetIndex, token: u32 }`. A 16-byte
conversion row is `{ expr: Bir.Inst.Index, target_term: TermIndex,
token: u32, flags: u8, pad: [3]u8 }`; flags distinguish an opaque target and
the presence of opaque checks. In S2 an arbitrary `via` expression sets both:
its target type is known, while its description and any engine-owned target
checks are opaque, so the plan must not claim their known absence. A 20-byte
check row is `{ endpoint: u8,
kind: u8, flags: u8, pad: u8, order: u32, call: Bir.Inst.OptionalIndex,
metadata: LiteralIndex.Optional, token: u32 }`; its kind distinguishes an
executable check from the explicit opaque-check marker, and its endpoint and
order preserve the §5 vocabulary. A 20-byte annotation row is `{ side: u8,
target_kind: u8, pad: [2]u8, target: u32, key: LiteralIndex.Optional,
value: LiteralIndex.Optional, token: u32 }`; `target_kind` says whether the
target is a node or field and `side` says program, encoded or both. The
expression root is retained because `via` accepts
an arbitrary Atom, including a parenthesised lambda or let, rather than only a
bare function. Its resolved BIR subtree and ordinary reference edges carry all
local and external call dependencies. S2 does not split it into directional
engine callbacks.

The plan's `term_*`, `type_extra` and `type_refs` columns use the interface's
flat type-term encoding for conversion target identities, including structural
targets; they never contain a session `TypeId`. Literals are two-word
`(start, len)` rows into `literal_bytes`. A `type_refs` row is 12 bytes in the
interface order `{ module: SymbolIndex, name: SymbolIndex, package: u8,
pad: [3]u8 }`. A `schema_targets` row is 12 bytes:
`{ package: u8, pad: [3]u8, module: SymbolIndex, schema: SymbolIndex }`.
A `ctor_targets` row is 12 bytes: `{ schema: SchemaTargetIndex,
variant: SymbolIndex, endpoint: u8, pad: [3]u8 }`. Every pad byte is zero.
On disk each `symbols` word is a byte offset into `strings`, exactly as in the
interface format; loading re-interns that length-prefixed string and keeps the
column's order. Live dense module/schema/constructor indices are reconstructed
only after graph and interface installation.

Every node, definition, field, variant, conversion, term, range, literal,
symbol and target index is bounds-checked on load; every tag, enum and zero pad
is validated. Definition, node and variant order is source-derived before
parallel checking. A bad plan or unknown version discards the whole cache
entry without a diagnostic. Source tokens and conversion roots are meaningful
because the cache key pins the module's source and front-end artifact. The
plan, positions, private schemas and conversion expression targets remain
outside the interface hash. A private `via` body edit therefore invalidates
the module and any specialisation which reads it without moving its public
interface hash; a public endpoint/member/constructor scheme edit does move the
hash and crosses the firewall.

The dependency-digest recipe and version remain unchanged. Schema endpoint
identities are ordinary stable `type_refs`, so its existing closed set of
named types includes public endpoints and any private endpoint reachable from
a public scheme. Those named-type rows carry the settled equatable, comparable
and has-function bits and alias expansion exactly as for other types. The
whole plan and a private conversion body do not enter the digest.
The property bytes themselves are unhashed sidecar data, restored for every
definition including private schemas on a cache hit. The existing named-type
digest rows then hash those restored settled properties exactly as on a cold
check; the sidecar does not become an additional digest input.

*Amended 2026-09-26 (checker rewrite R8b, `checker-v2.md` §11.5 *as built by R8b*).* Under the
new checker the property bytes are read off the derived contexts in P9, not off settled session
bits, and a cache hit of a module it checked restores nothing into the session table: the
old checker's settle (`Schema.settleProperties`) is not on its path. What a dependent observes
about an endpoint — whether and how it derives `eq` and `compare`, and its `equatable` gate — is
in the record's hidden rows, which the interface hash covers; the digest's named-type rows hash
the table's bits, which are the same in a cold and a warm build. The old checker kept the rule
above until R12 deleted it (2026-09-27), with `Schema.settleProperties` and the table's schema
property bits.

S2 moves the temporary wall rather than removing it. `check` accepts a valid
schema program and all resolution-requiring dumps see these interface members.
`build` stops in `Emit.run`, before `findEntry` and before writing any path,
with `not_implemented` on the schema name: “This schema is checked, but its
parse and print are not generated until schema S4.” A schema program cannot
build successfully without its runners.
