# Schemas — specification

## Open decisions for the owner

**Status:** normative. Frontend support and the layout declaration spelling
(§2/A.5) and checking (§3–§4/A.6) are implemented; library
interpretation and specialised execution await the later slices of §10. Q3, Q6, Q9 and Q11
below remain open; their recommendations guide the affected later slice, not the frontend.
Q1, Q2, Q4, Q5, Q7, Q8 and Q10 are decided (A.2/A.6).
Q12's scheduling is A.3/A.4: the frontend and the numeric-alias checker fix may run in parallel; both precede checking.
Question identifiers and section numbers stay stable. Append later decisions
to Appendix A.

*Amended 2026-10-02 (A.9, A.10).* No schema question is open any more. The rest of the milestone is
specified in §11 (defaults), §12 (schemas derived from a type), §13 (suspending conversions), §14
(what is derived from a schema), §15 (the Effect v4 parity ledger) and §16 (the slices, which
replace §10's S3–S5). The sentences above that call Q3, Q6, Q9 and Q11 open are superseded by
those sections.

| ID | Question | Recommendation | Cost and alternative |
|---|---|---|---|
| Q3 | Does v1 have defaults? **Answered 2026-10-02 (A.7): yes, Effect-class defaults in the declaration.** | No declaration modifier and no implicit defaults in v1; explicit fallible transformations may deliberately recover missing data. | More application code. Alternatively add Effect-style directional defaults with separate missing/null/failure triggers and encode omission rules. Report 34's no-defaults protocol is evidence scope, not an owner decision about the language. |
| Q6 | What metadata must descriptions carry, and do JSON Schema output and generators ship in v1? **Answered 2026-10-02 (A.9): everything.** | Carry both endpoints (including opaque conversion targets), external keys, presence/nullability, tag literals, named recursive definitions, check identifiers/parameters, annotations and an explicit opaque-check marker now. Ship inspection in v1; ship JSON Schema and generators later as libraries with fallible results. | Larger descriptions when retained. Omitting metadata now makes later tooling incomplete. Arbitrary functions cannot be translated to JSON Schema or guaranteed to yield a sample; never silently weaken a check. |
| Q9 | Where does differential testing enter the gates? **Answered 2026-10-02 (A.9): in the gates, as recommended.** | Every schema semantic fixture runs compiled and forced-library paths inside `zig build test-blackbox`, in development/release, with exact values and Issue lists; jobs 1/8 determinism remains mandatory. | Additional runtime; measure the gate cost with specialisation. A separate optional job is cheaper locally but can let the two semantics drift. Differential agreement alone is insufficient: both also assert an independent expected answer. |
| Q11 | What is the stored-function abstraction after P2? **Answered 2026-10-02 (A.9): conversions may suspend; inferred per schema.** | Keep two explicit endpoint semantics and separate directional callbacks, but do not freeze an opaque `Schema e a` ABI until H4's seven cases pass. Investigate inferred directional bits across the abstraction/interface boundary. | The library is synchronous and an internal representation may change. Making every schema call suspending is an alternative only with measured cost and owner acceptance; this spec chooses neither an effects runtime nor that alternative. |

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
or opaque schema form adopted here. *(Amended 2026-10-02: §11 adds the `default` and `initial`
field modifiers.)*

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
values through ordinary functions. *(Amended 2026-10-02, A.8: §12 adds the well-known method
`codec`, which selects a derived wire form from a Type for `Json.decode` and its relatives. Namespace
lookup itself is unchanged, and a structural endpoint is never silently read with a declared
schema's renames, §12.2 step 0.)*

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

The frontend stores that unresolved plan as a schema declaration plus a contiguous BIR
instruction graph. The declaration has a dedicated `schema_body` root and is
in neither the value nor type namespace. Plan instructions retain operand
name tokens, ordered argument edges, record fields, ordered modifiers, decoded
external keys/tags, tagged variants and explicit grouping. A `via` retains the
ordinary Atom tree, but unresolved nonlocal leaves use schema-expression
reference instructions carrying their symbol and source token; lexical locals
inside a parenthesised lambda or let remain ordinary local references. Checking can
therefore resolve the tree without reparsing source, and the frontend does not report an
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
existential type syntax or higher-kinded type is licensed. The library work must demonstrate
that the plain library builders express every accepted declaration and keep
context closed. Q11 deliberately leaves the stored-function ABI unfrozen.

`describe` collects the entire reachable graph on **both** endpoints. Traverse
in declared field/variant order; assign definition identities from stable
schema identity and structural position; deduplicate by identity, not display
name. Every reference resolves exactly once, including a nested recursive
schema within another recursive schema. This closes the missing
child definitions of nested recursive descriptions and avoids expanding recursion. Describing never runs a
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
specified before the library work.

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
ceiling 4,096; these numeric choices require the library and specialisation proof below, not an
assumption that JavaScript guarantees that many frames.

The ceiling must cover both interpreters and emitted workers, including helper
frames, conversion nesting and JSON output, across supported browser engines
and Node. `List.map5` already overflowed near 3,700 calls, a different
function. The library and specialisation work must establish a conservative ceiling and the boundary handling
needed to preserve G1/G3 when callers have already consumed stack; record the
result here before shipping. No explicit traversal-frame stack is required.
The queue tracks this implementation proof.

*Amended 2026-10-01 (S3; §16's* As built *note has the measurements).* The library's numbers:
**the default is 512 and the ceiling 1 024**, `Schema.maxDepthCeiling`. A cold operation in a
fresh Node process overflowed no sooner than 3 537 depth units, so the ceiling keeps a margin of
3.4× for a caller's own frames and for engines with smaller stacks; JSON output at the ceiling
nests well inside `JSON.stringify`'s own limit (about 4 145 levels). A caller that has already
spent most of the stack can still overflow inside the bound: that is a `RangeError`, a defect that
crashes (CLAUDE.md rule 9), never caught and turned into an issue. S4's emitted workers owe the
same measurement.

Decode/read paths use external keys; encode paths use declared Beni keys for
program input, and an external-output failure uses its external key. Direction
and failing endpoint must remain distinguishable in the final Issue design
(§4). List indices are zero-based. A failed discriminator points at its key;
a variant payload adds no fictitious JSON field. Engine-attached relative
conversion paths are appended to the current path. Empty relative paths mean
this value, never the root. Missing-key and unknown-key failures include the
key itself; a key-count shortcut that loses it is invalid (report 34).

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
not inherit the benchmark's JSON-only results (the queue records two such divergences).

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

### The builder API

*Added 2026-10-01, before the library was written* (§16, S3; the "concrete builder API" the
paragraph above asks for). This is `core/Schema`'s surface for building and running a schema
at run time. A declaration (§2) means exactly what the builders below build from it, and S4's
specialised code must agree with them (§10).

**Types.** `Schema e a` and `Conversion b a` stay `pub foreign type`s (A.6). Four builder types
are added, all `pub opaque type`s:

| Type | Holds |
|---|---|
| `Fields pe pa` | the fields of a record schema being built, with two products: `pe` holds the fields' Encoded values and `pa` their Type values, each a tuple nested to the left, `( ( ( (), a ), b ), c )` |
| `Mapping p r` | a product turned into a record (`to : p -> r`) and back (`from : r -> p`) |
| `Variant e a` | one variant of a tagged schema |
| `Injection p a` | a variant's constructor `p -> a`, and the test `a -> Maybe p` that takes it apart |

**Builders.**

```text
string : Schema String String         bool  : Schema Bool Bool
int    : Schema Int Int               float : Schema Float Float
finiteFloat : Schema Float Float      null  : Schema (Nullable Never) (Nullable Never)
value  : Schema Value Value

list     : Schema e a -> Schema (List e) (List a)
nullable : Schema e a -> Schema (Nullable e) (Nullable a)

fields   : Fields () ()
field    : Fields pe pa, String, Schema e a -> Fields ( pe, e ) ( pa, a )
optional : Fields pe pa, String, Schema e a -> Fields ( pe, Presence e ) ( pa, Presence a )
key      : Fields pe pa, String -> Fields pe pa
mapping  : sync (p -> r), sync (r -> p) -> Mapping p r
record   : Fields pe pa, Mapping pe e, Mapping pa a -> Schema e a

injection : sync (p -> a), sync (a -> Maybe p) -> Injection p a
variant   : String, String, Schema pe pa, Injection pe e, Injection pa a -> Variant e a
nullary   : String, String, Injection () e, Injection () a -> Variant e a
tagged    : String, List (Variant e a) -> Schema e a

conversion : sync (b -> Result (List Issue) a), sync (a -> Result (List Issue) b) -> Conversion b a
converted  : Schema e b, Conversion b a -> Schema e a
issue      : String -> Issue
issueAt    : List PathSegment, String -> Issue

recursive  : String, sync (Schema e a -> Schema e a) -> Schema e a
flip, typeOnly, encodedOnly, describe   -- as listed above
defaultOptions : Options              maxDepthCeiling : Int
decodeWith : Schema e a, Options, e -> Result (List Issue) a       -- and encodeWith, readWith,
                                                                    -- writeWith, parseWith, printWith
```

The ten operations listed above keep their signatures; each also has its `…With` form, which takes
`Options` after the schema.

**Each declaration form, built.** Every form §2 accepts is a composition of these builders, which
is what makes the library the semantics of a declaration:

| Declaration | Builders |
|---|---|
| a primitive or `Value` operand | `string`, `bool`, `int`, `float`, `finiteFloat`, `null`, `value` |
| `List S` | `list s` |
| `f : S` | `field fs "f" s` |
| `f : S as "k"` | `field fs "f" s \|> key "k"` |
| `f : S nullable` | `field fs "f" (nullable s)` |
| `f : S optional` (and `optional nullable`) | `optional fs "f" s` (and `optional fs "f" (nullable s)`) |
| `f : S via c` | `field fs "f" (converted s c)` |
| a record body | `record fs mapping mapping`; the two mappings are often one polymorphic pair, because both records have the declared field names |
| `tagged "k" of A as "a" { … } \| B` | `tagged "k" [ variant "A" "a" payload injE injA, nullary "B" "B" injE injA ]`, where the payload is a `record` |
| a parameter `a` | an ordinary function argument: `page : Schema e a -> Schema (Page e) (Page a)` |
| a reference to a recursive schema | `recursive "Tree" (\tree -> …)` |

```elm
-- §2's `User`, built: Encoded and Type are both { userId : Int, nickname : Presence (Nullable String) }.
toUser ( ( (), userId ), nickname ) =
    { userId = userId, nickname = nickname }

fromUser u =
    ( ( (), u.userId ), u.nickname )

user =
    Schema.record
        (Schema.fields
            |> Schema.field "userId" Schema.int
            |> Schema.key "user-id"
            |> Schema.optional "nickname" (Schema.nullable Schema.string))
        (Schema.mapping toUser fromUser)
        (Schema.mapping toUser fromUser)
```

**What the builders decide.**

- **A construction failure is carried, not thrown.** These are failures of the schema, not of a
  value: two fields with one name or one external key, `key` with no field before it or a second
  `key` on one field, two variants with one tag or one name, a payload field on the
  discriminator's key, a variant payload that is not a `record`, a `tagged` with no variant, a
  recursive schema used while its body is being built (the only way a reference can dangle), and
  reading or writing an endpoint that holds a conversion's target (below). Every operation on a
  schema that reaches one returns `Err` with one `InvalidSchema` issue at the root path, before it
  reads its input; `describe` shows the place as `Invalid`. Which failure is reported is the first
  in declared order.
- **An endpoint holding a conversion's target has no external form** (§5, A.4). `read`, `write`,
  `parse` and `print` refuse a host end on such an endpoint before reading anything: reading a
  flipped `String via decimalInt`, or `typeOnly` of it. Its typed operations work: `typeOnly`
  decodes and encodes an opaque target as identity (no checks exist until S6).
- **Recursion.** `recursive name f` passes `f` the schema it defines and builds the body once, the
  first time it is needed. A reference resolves by the definition's identity, never by `name`: two
  schemas built with one name are two definitions. A reference entered again at the same position,
  with no field, element or payload read in between, is the nonproductive cycle of §4 and fails
  there with `InvalidSchema`.
- **`flip (flip s)` is `s`**, the same schema, so a double flip restores its values, failures and
  description exactly.
- **Options.** `defaultOptions` is `FirstError`, `Ignore`, `maxDepth = 512`, `reportInput = False`.
  A `maxDepth` below 0 or above `maxDepthCeiling` is `InvalidOptions` at the root, before the
  schema is looked at. The ceiling is the measured one of §16's *As built* note.
- **Issues.** A path segment names a key as the operation's **input** names it: the external key
  when the input is Encoded (`decode`, `read`, `parse`), the declared name when it is a Type value
  (`encode`, `write`, `print`). A failure of what is **written** — a non-finite `Float` printed, a
  `Value` that nests past the bound — is named as the output names it. `endpoint` is relative to the
  schema the operation was called on: the input endpoint for a failure of the input; the output
  endpoint for a conversion's failure, for any failure below an encoding conversion (its output is
  on its way to the Encoded endpoint), and for a failure of what is written. A conversion's own
  issues keep their `code` and `message`; the engine puts the current path in front of theirs and
  sets `direction`, `endpoint` and `input`, and an empty `Err` is one `ConversionFailed`.
- **Codes.** `WrongShape`: not the JSON type the schema reads (and not an object, array or `null`
  where one is needed). `InvalidValue`: a number outside the safe-integer range, or a non-finite one
  for `finiteFloat`. `MissingKey` at the key; `UnknownKey` at the key, under `Reject`, in the
  object's own-key order; `UnknownTag` at the discriminator, for an unknown or non-string tag;
  `DepthExceeded` at the child the bound stopped; `ParseFailed` at the root, with the host's
  message; `PrintFailed` at the value JSON cannot hold.
- **Host values.** Reading tests own keys only. Writing builds each object with no prototype, its
  keys in field order and a variant's discriminator first, so `__proto__` and `constructor` are
  ordinary keys both ways.
- **A typed tagged value** is matched by the variants' projections in order; a value none of them
  takes (an `Injection` left out) is `InvalidSchema` at its path.
- **Effects.** The builders are `foreign pure`; every function they keep — a mapping, an
  injection, a conversion, a recursive schema's body — is declared `sync`, because the engine
  calls it during a run (`boundary.md` §4), so a conversion that may suspend is refused where it is
  passed. The runners and `describe` are `foreign impure`: they call those functions, and an
  impure one must not be dropped or moved with the call. S9's join table (§13.2) replaces the
  `sync` marks with directional classes; S3 makes no H4 claim.

**The engine is the sibling, and why.** The engine is `core/Schema.js`, and `Schema.beni` declares
the builders and runners over it as `foreign`s — §6's and A.1's "library interpretation uses
privileged core foreign primitives over the same host value". It was first written in beni over
core's `Js`, and that version is measured in §16's *As built* note: **core is checked whole by every
compilation**, the engine's 1 300 lines of beni added about 33 ms (a ReleaseSafe compiler) to every
`beni` process whether or not the program imported `Schema`, and `zig build test-blackbox` went
from 563 to 1 142 user-seconds. Declared as `foreign`s, the same surface costs 2.7 ms. The
sibling builds and reads the beni values it shares with the program — `Ok` and `Err`, `Present` and
`Missing`, `Null` and `NonNull`, `Just` and `Nothing`, an `Issue`, a `Shape`, a tuple, a list —
by the representation of `backend.md` §4, and every such type is named in a `foreign` annotation
here, so `--release` keeps its field names and string tags (`boundary.md` §4, *What JavaScript may
read of a beni value*). A value at a type variable — a user's record, a `Type` value — the engine
only passes to the functions it was handed, never reads. `JSON.parse` reports malformed text by
throwing a `SyntaxError`; the engine catches exactly that error and re-throws any other (CLAUDE.md
rule 9). `JSON.stringify` needs no catch: what the engine prints is objects and arrays it built,
finite numbers, strings, booleans and `null`, nested no deeper than the bound.

*Amended 2026-10-01: the engine is beni again* (the owner's direction, core written in beni;
`plans/core-in-beni.md`). The wall above is gone — a process checks only the core modules its
program reaches (`checker.md` §4, amended the same day), so a program that does not import `Schema`
pays nothing for it — and `core/Schema.js` is deleted: nothing in the engine needs JavaScript that
`Js` cannot write. `Schema.beni` keeps every public type and signature; its opaque types stay
`foreign type`s, each the engine's own record seen through a cast at a type variable, so no type of
the engine is one JavaScript "can see" and a release build renames all of them. The values it shares
with the program — `Result`, `Maybe`, `Presence`, `Nullable`, `Issue`, `Shape`, the products — it
builds and reads by ordinary construction and patterns, the host value (a parsed document, the
object a `write` makes) through `Js`, and its own sequences — a record's fields, a union's
variants, the issues of a run — are host arrays, so a program using it pulls in none of `List`'s
array-backed machinery. `JSON.parse`'s `SyntaxError` is caught by `Js.catchIf`, which re-throws
anything else. The builders are pure, their reads of the arrays they build behind `Js.pure`.

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

### Lists are arrays

*Added 2026-10-01; specified, not built* (`backend.md` §4, *Lists are arrays*;
`boundary.md` §4, *How a sibling sees a `List`*). The table's "input
positions/cons cells as appropriate" becomes input positions only: a `List` is
array-backed, and the engine and the specialised workers are hand-written or
emitted JavaScript that reads and makes lists under the sibling protocol.

- **Decoding (parse, read).** The input is a JavaScript array tested with
  `Array.isArray` and walked by index; the index is the path segment
  (`Index i`, zero-based) and depth is counted as for any child. The output
  list is **a fresh plain array** the worker builds in input order with
  `push` and hands over when the list succeeds — a builder in `backend.md`
  §4's sense, never written after. A worker **may adopt the input array
  itself** as the output only when both hold: every element's validation
  returns its input unchanged (a `List Int`, a `List String`, a list of a
  schema with no conversion), and the array was created by the same
  operation (`parse` calling `JSON.parse` on its own string). An array the
  caller handed in as a host value is never adopted, because the host may
  still write it.
- **Encoding (print, write).** A list is read through the protocol —
  `Array.isArray(xs) ? xs : xs.$plain()` — and walked by index. When the
  encoded elements are the elements themselves, the plain array may be given
  to `JSON.stringify` as it is; otherwise the worker builds the external
  array.
- **Failure paths** allocate as before; a failed list allocates no output.
- Nothing here depends on which of the three forms a list is in, and a
  decoded list is plain, so reading it back is O(1) per element.

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
builder calls are library operations; specialisation need not perform general constant
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
compiler rows have **not landed in this capture** and remain owed. Specialisation adds a
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

*Amended 2026-10-02 (A.9, A.10).* Q11 is decided and the runtime spike has landed. §13 specifies
the abstraction this paragraph left open: two directional classes per `Schema`, a compiler-known
join table for `core/Schema`, and a suspendable twin of the library engine. It also authorises that
work. The other refusals above still stand: no blanket suspending fallback, and no duplicated
sync/async public API. The seven cases below are §13's acceptance.

The effects work, after P2, owes all seven acceptance cases there through **both** paths:

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
`duplicate_schema_modifier` is emitted by frontend lowering; the remaining codes are
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

Checking accepts schema programs in `check` and in resolution-requiring dumps.
`build` still reports `not_implemented` on the schema name from `Emit.run`,
before entry discovery or any output: “This schema is checked, but its parse
and print are not generated yet.” This replaces the frontend's
refusal; a successful check does not claim executable runners. A frontend or
checker error keeps its own diagnostic without adding this refusal.

## 9. What v1 leaves out

The committed scope excludes an effects runtime (the effects work follows P2), implicit
currying/evidence selection of schema arguments, arbitrary computation of types
from runtime descriptions, and automatic replacement of platform ports.
The first two follow the accepted language model; runtime type computation
would need a separate type-system design; ports need a boundary contract and
measurement before replacement. Schema parse/print do not change main or grant
ordinary packages foreign privilege.

The following exclusions are settled except defaults (Q3) and tooling (Q6),
which remain recommendations. *(Amended 2026-10-02: defaults are §11 and tooling is §14. Dict,
tuples and rest fields are scheduled by §15–§16, and §15 gives each row's milestone status.)*

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

*Amended 2026-10-02: §16 re-cuts the slices after S2 for the whole milestone. The rules of this
section (red first, both paths, independent expected answers, and differential execution inside
`test-blackbox`, which Q9 settled) apply to every one of them.*

The frontend, including §2/A.5’s brace-equivalent layout spelling, has landed,
and so has the independent checker fix for numeric literals through primitive aliases
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
| S1 — frontend | §2, §8; syntax decisions settled in A.2; independent of the numeric-alias fix | `parse/good`, `parse/bad`, `fmt`, `bir`: records, modifier boundaries, contextual-word values, generic operands, tagged recursion, recovery and comment retention | AST/BIR dumps expose source intent, formatter is idempotent and parse-preserving, every new parse diagnostic exact; later phases explicitly refuse unsupported schema builds instead of succeeding without them |
| S2 — checker (**implemented**, 2026-09-22) | §3–§4, §8; settle Q7; fix numeric literals through primitive aliases first | `check/good` interfaces for two schemas/module, alias/exposing/qualified access, explicit generic arguments, distinct union endpoints; `check/bad` for every new code, wrong endpoints, private members and constructor exhaustiveness | Types and names work through imported/serialized interfaces; cache miss/hit and jobs 1/8 agree; schema plan and sidecar format specified and tested; remove the frontend's whole-input schema exclusion from resolver fuzz; no successful build silently omits runners |
| S3 — library and description | §1, §4–§5, §9; settle Q3/Q6 and concrete Issue/builders; prove the native-recursion ceiling; preserve Q11 | `run/`: both fallible directions, flip twice, projections with different endpoint shapes, renamed keys, every missing/null/present combination, ordered sibling structural+conversion failures, FirstError laziness, depth 0/bound/bound+1, prototype keys, nested recursive definition closure, runtime construction errors | Plain builders express each accepted declaration and obey closed context; exact values/Issues/description graphs in development/release; JSON host failures return Result; no H4 claim or fixed effects ABI |
| S4 — specialisation | §6 and this section; settle Q9; prove the native-recursion ceiling | `run/` differential twins; `emit/`, `emit/release/`, `emit/app/`: direct checks, compiled failure branches, loops, recursive workers, parse-only/print-only/description-only DCE; cached cross-module callback dependencies | Both paths yield identical expected values and complete Issue lists; all three gates pass; add **beni** to `bench/schema-libraries` with strict/no-default options, publish per-operation medians, faults, startup, sizes and caveats; measure many-schema growth and browser behavior before a parity claim |
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
output trees; interface/cache round trips are part of checking's and specialisation's acceptance.

The three existing gates remain `zig build test`, `zig build test-blackbox`,
`zig build fmt-check`. Q9 recommends putting differential execution in the
second; it is **not wired by this spec commit**. Chrome semantic checks and
report 34 performance measurements are specialisation evidence, not timing thresholds in
an otherwise deterministic correctness gate. A failing test is investigated,
not fixed by blessing all goldens. No new measurements are run for this document.

## 11. Defaults

*Added 2026-10-02; specified, not built* (A.7, A.10). The owner put defaults in the declaration and
set Effect v4 as the bar. Effect separates three questions, and so does this section: **what
triggers** a default, **which direction** it serves, and **what encoding does** with a value equal
to it. Effect's semantics are taken from its documentation
([`SCHEMA.md`](../../references/effect/packages/effect/SCHEMA.md) *Decoding Defaults* L623–L763,
*Default Values in Constructors* L3030–L3147, *Omitting a Key During Encoding* L3549–L3603,
*Fallbacks* L6696–L6766); its implementation was not read.

### 11.1 The surface

Two new field modifiers extend §2's `FieldModifier`:

```text
FieldModifier   := … | DefaultModifier | 'initial' Atom
DefaultModifier := 'default' 'encoded'? Atom ('when' Trigger ('or' Trigger)*)? 'omitted'?
Trigger         := 'missing' | 'null' | 'invalid'
```

- **`default`** is a *decoding* default (Effect's `withDecodingDefault*` and `catchDecoding`).
- **`initial`** is a *constructor* default (Effect's `withConstructorDefault`), used by §11.6's
  `make`.
- **`encoded`** says the default is written as an Encoded value and decoded like a value that was
  read (Effect's encoded-side variants). Without it, the default is a Type value (Effect's
  `…Type` variants).
- **`when`** lists the triggers. With no `when`, the trigger is `missing` alone, which is
  Effect's `…Key` behaviour and Roc's (§12.1).
- **`omitted`** is an encoding policy (§11.4).

Every new word is contextual inside this production only, as §2's modifier words are, so no
existing name is reserved. `Atom` is §2's expression atom: a call needs parentheses. After
`default`, the word `encoded` is always the side word, so a value named `encoded` is written
`(encoded)`. A trigger word is read as a trigger only after `when` or `or`. Each of `default`
and `initial` may appear once per field; a second one is `duplicate_schema_modifier`.

```elm
-- NEW SYNTAX (§11). Missing → 20; present null → an Issue, as for any Int.
pub schema Settings =
    pageSize : Int default 20
    theme : String default "light" when missing or null
    retries : String via decimalInt default encoded "3"
    locale : String as "lang" default "en" when missing or invalid omitted
    createdAt : Int initial (Clock.now ())
```

The formatter keeps the written order of words inside one modifier. It never adds a `when` that
was left out, and it never drops one.

### 11.2 Types

A trigger never changes the field's **Type**. It widens the **Encoded** field by the layer the
trigger absorbs: `missing` adds `Presence`, and `null` adds `Nullable`. A Type default `d` has
the Type field's type. An `encoded` default has the Encoded field's type *before* the trigger
layers are added, which is the type a value read at that key has.

| Field | Type field | Encoded field | `d` (Type side) | `d` (`encoded`) |
|---|---|---|---|---|
| `f : S default d` | A | Presence E | A | E |
| `… when null` | A | Nullable E | A | E |
| `… when missing or null` | A | Presence (Nullable E) | A | E |
| `… when invalid` | A | E | A | E |
| `f : S nullable default d` (missing) | Nullable A | Presence (Nullable E) | Nullable A | Nullable E |
| `f : S optional default d when null` | Presence A | Presence (Nullable E) | Presence A | E |
| `f : S via c default d` | a (from c) | per the rows above, over S's E | a | E of S |
| `f : S initial d` | unchanged | unchanged | — (`d` : the Type field) | — |

**Two combinations claim one state twice**, and each is `conflicting_schema_modifiers` (§11.8):
`optional` with the trigger `missing`, and `nullable` with the trigger `null`. Both would give one
external state two meanings, which G5 forbids. Every other combination is accepted. The last two
data rows are what Effect's examples do with `transformOptional`: "missing means null" is
`nullable default Null`, and "null means missing" is `optional default Missing when null`.

### 11.3 Decoding

The effective order is §2's: rename at the boundary, then presence and the null test, then the
inner schema or conversion. A default enters at the layer of its trigger:

1. **`missing`**: the external key, after `as`, is not an own property. Its default fires, and
   the field is not read. The other spelling of a renamed key is still an unknown key, as §6's
   *renamed key* row says.
2. **`null`**: the key is present and its value is JSON `null`. Its default fires.
3. **`invalid`**: the present value fails the field's own operand, whether by shape, conversion
   or check, at the field path or below it. The default replaces the field's result, and **the
   issues that failure produced are discarded**, under FirstError and AllErrors alike. This is
   Effect's `catchDecoding`. It never fires on its own: only an author who wrote `invalid` gets
   it. It never applies to the enclosing record's structural checks, to unknown keys under
   Reject, or to the encoding direction.

**What a fired default produces.**
- A Type default is evaluated, then the Type endpoint's checks on that field run on it, exactly as
  they would on a decoded value. A default that fails a check is a `CheckFailed` issue at the field
  path, whose message names the default. A well-typed default is not exempt from the checks: §5's
  rule that "typed encode still validates refinements" applies here too.
- An `encoded` default is decoded through the field's whole operand (conversions, checks, nested
  defaults) as if it had been read at that key, and its failures are ordinary issues at that path.

**Evaluation.** A default expression is evaluated **each time its default fires**, at the field's
place in declaration-order traversal, and never when the key supplies the value. This is Effect's
"executed each time a default value is needed" (L3050). A pure default may be evaluated once by
the backend, since that is unobservable. An impure default, such as `Debug.log`, is ordered among
its siblings' conversions. A suspending default makes the decoding direction suspend (§13). A
FirstError traversal that stopped earlier does not evaluate it.

### 11.4 Encoding

The Type field always holds a value, so encoding has one decision: whether to write the key
when the value equals its default.

- **Written** (the default, and Effect's: `withDecodingDefault`'s encode is a passthrough). The
  value is encoded and the key is always written. The program value round-trips:
  `decode (encode v) == v`. The external document can gain a key it did not have.
- **`omitted`** (opt-in, Effect's `SchemaGetter.omit`). For a Type default, the key is left out
  when the value `==` the evaluated default. For an `encoded` default, it is left out when the
  encoded output `==` it. `==` is the type's `eq` (`static-dispatch-spike.md` §3), derived when the
  module declares none. The program value still round-trips, because decoding the omission fires
  the same default. The external document can lose a key that equalled the default.

`omitted` requires the trigger `missing`. Without it, the omitted key could not be read back, so
any other set of triggers is `omitted_default_needs_missing`. `omitted` also requires a **pure**
default: re-evaluating an impure or suspending default could produce a different value, so the
round trip would silently change the data. That case is `omitted_default_not_pure`. A field type
without `eq` reports the existing `not_equatable` or `unknown_method`. `null` and `invalid` defaults
are decoding-only: encoding never writes `null` because a default exists.

### 11.5 Projections and flip

- **`flip`** swaps the directions (§5), so a flipped schema's *encoding* fills defaults, and a
  double flip restores them.
- **`typeOnly`** validates the Type endpoint, whose field is always present, so its defaults
  vanish.
- **`encodedOnly`** validates the Encoded endpoint, whose `Presence`/`Nullable` layers already
  admit the triggering states, so its defaults vanish too.
- **`describe`** carries them (§11.7).

### 11.6 Constructor defaults: `Init` and `make`

Every schema's namespace gains two members, appended to A.6's fixed member order:

- `Init`, a type: the Type endpoint with every field that has an `initial` removed. This applies
  recursively through inline nested field blocks, but not through a referenced schema, whose own
  `make` the author calls in the `initial` expression.
- `make : Init -> Result (List Issue) Type`. Generic schemas take their explicit schema arguments
  first, as the factory does.

`make` fills each `initial` in declaration order, evaluating it on every call, and then validates
the result against the Type endpoint (`typeOnly`'s decoding). That is Effect's "a constructor
creates a value of the schema's type, running all validations" (L2923), with `Result` in place of
the throw, which makes it Effect's `makeOption` with its issues kept. A schema with no `initial` has
`Init` equal to `Type`, and its `make` is validation alone. An impure `initial` makes `make` impure,
and a suspending one makes it suspend (§13).

```elm
-- NEW SYNTAX (§11.6).
case Settings.make { pageSize = 50, theme = "dark", retries = 3, locale = "pt" } of
    Ok settings -> settings.createdAt   -- filled by `initial`
    Err issues -> …
```

In this slice `initial` is accepted only in a record-bodied schema, including its nested inline
blocks. In a tagged variant's payload it is `misplaced_initial`. That is a capability not yet
specified, not a rule: §15 row *tagged `make`* proposes `Message.Init` as a third constructor
family, for S8 (§16).

### 11.7 The description, the plan and the interface

- **The description.** A field carries `default : Maybe { side, triggers, encoding, value }` and
  `initial : Maybe { value }`. `value` is an opaque thunk reference, because a default is a Beni
  value and describing never runs it (§5). §14's derived artefacts read it by encoding it, which
  can fail. The JSON Schema `default` keyword is computed this way.
- **The plan.** The resolved plan (A.6) moves to its next format version. The field row's `flags`
  gains bit 1 `missing`, bit 2 `null`, bit 3 `invalid`, bit 4 `encoded`, bit 5 `omitted`, bit 6
  has-default and bit 7 has-initial. A new `defaults` column follows `fields`, with one 16-byte row
  per defaulted field: `{ field: FieldIndex, default_expr: Bir.Inst.OptionalIndex, initial_expr:
  Bir.Inst.OptionalIndex, token: u32 }`. Both expressions are resolved BIR subtrees, like a `via`
  root, and their references are real value dependencies.
- **The interface.** `schema_members` gains the kinds `Init` and `make`, after `printWith`. Their
  schemes are complete (A.6), so the next interface format version follows.
- **The frontend artifact.** It changes version for the new modifier rows.

### 11.8 Diagnostics

Appended to §8's list:

| Code | Title | Primary region and message shape |
|---|---|---|
| `conflicting_schema_modifiers` | CONFLICTING SCHEMA MODIFIERS | The trigger: "`optional` already gives a missing key a meaning here; `default … when missing` would give it a second." The other pair (`nullable` with `null`) is the same. The hint names the combination the author probably wants. |
| `omitted_default_needs_missing` | OMITTED DEFAULT CANNOT BE READ BACK | `omitted`: "An omitted key is read back as missing, but this default does not fire on `missing`." |
| `omitted_default_not_pure` | OMITTED DEFAULT MUST BE PURE | `omitted`: "This default can produce a different value each time, so leaving the key out could change the data on a round trip." The message shows the chain, as `sync_boundary` does. |
| `misplaced_initial` | `initial` IS ONLY FOR RECORD SCHEMAS | The word: "A variant payload has no `make` yet." The message points to the field. |

A default whose type does not match is the ordinary `type_mismatch`, with the field as context.

### 11.9 How both paths implement defaults

- **The specialised worker** inlines each trigger as a branch. In the decode worker,
  `hasOwn(raw, k) ? … : <default>`. The `null` test comes before the operand. An `invalid` field
  runs its operand into a temporary Result and selects the default on `Err`, without appending
  that Err's issues. In the print worker, `omitted` compiles to one `eq` call before the key is
  written. A pure literal default is a constant.
- **The library engine** interprets the same three triggers from the field node, with the same
  order, the same evaluation counts and the same issues.
- The differential rule (§10, Q9) covers every fixture below.

### 11.10 Fixtures the defaults slice owes

Each fixture is red first. Behaviour belongs in `run/`, through both paths, with an independent
expected answer.

- **Triggers:**
  - missing fires, present wins, and present `null` is an Issue unless `null` is a trigger;
  - `missing or null`;
  - `invalid` over a wrong shape, a failed conversion, a failed check and a failure two levels
    below the field;
  - under AllErrors, a recovered `invalid` adds no issue, and a later sibling's failure is still
    reported.
- **Sides:**
  - `String via decimalInt default encoded "3"` decodes to 3;
  - an encoded default that fails its conversion is an Issue at the field;
  - a Type default that fails a target check is `CheckFailed` at the field.
- **Encoding:**
  - a value equal to the default is written without `omitted`;
  - it is absent with `omitted`;
  - an unequal value is written either way;
  - every case round-trips the program value.
- **Interactions:**
  - with `as "k"`, the default fires on `k` missing, and the Beni-name spelling is an unknown key
    that Reject reports;
  - `nullable default Null`;
  - `optional default Missing when null`;
  - a default inside a tagged payload;
  - a default inside a recursive schema at depth;
  - `flip` and a double flip;
  - `typeOnly`/`encodedOnly` without defaults.
- **Evaluation:** `Debug.log` defaults (the corpus's evaluation-order instrument) fire only when
  triggered, once each, in declaration order, and not after a FirstError stop.
- **`make`:**
  - `initial` fills its field;
  - `Init` omits the field;
  - `make` returns `CheckFailed` for an invalid result;
  - a nested inline `initial`;
  - `make` on a schema without `initial` validates.
- **`check/bad`:** every §11.8 code; `duplicate_schema_modifier` for two `default`s; a wrong-typed
  default; `omitted` on a function-typed field.
- **`parse/good`, `fmt`, `bir`:**
  - every word and order;
  - `default (encoded)`;
  - `when` lists;
  - values named `default`, `initial`, `missing`, `when` and `or` stay values;
  - layout and brace spellings give identical dumps.
- **`emit/` and `emit/app/`:** an inline default branch; `omitted`'s one `eq` call; a program
  using only `parse` ships no `make` and no `initial` expression.
- **Interface and cache:** `Init`/`make` in `dump --stage=interface`; cache miss and hit agree; a
  private default edit does not move the interface hash, and a changed `Init` does.

## 12. Schemas derived from a type

*Added 2026-10-02; specified, not built* (A.8, A.10). This is the zero-ceremony end of the
feature: `Json.decode text` returns a value of whatever type the program uses it at, and the
compiler derives the schema from that type. It is checked by the same engine, with the same issues,
the same specialisation, the same differential tests and the same `--release` behaviour as a
declared schema. When the JSON does not look like the type, a declared schema (§2, §11) remains
the tool.

### 12.1 What Roc does, from primary sources

Report 31 read no Roc source. This section does, at the vendored `references/roc`
(`f083385b`, the Zig compiler), with the pre-rewrite compiler at tag `0.0.0-alpha2-rolling` and
Zulip as context.

**The old design (abilities, the Rust compiler).**
- `Decoding` and `DecoderFormatting` worked over `List U8`.
- `DecodeError : [TooShort]` was the only error, with no path, field or message
  (`crates/compiler/builtins/roc/Decode.roc` L53, L68–L77, L141–L164).
- Derivation covered strings, lists, numbers, Bool, tuples and *closed* records. Tag unions were
  `Underivable // yet`, and optional record fields and type variables were refused
  (`crates/compiler/derive_key/src/decoding.rs` L40–L131).
- A missing field was decoded from empty bytes, and roc-json's `Option` used that trick to mean
  absent (`crates/compiler/derive/src/decoding/record.rs` L22–L71).
- Opaque types had to opt in with `implements [Decoding]`.

**The complaints on Zulip.**
- Errors carried no information. The answer was that custom error types "would need associated
  types on abilities, which we don't intend to add" (Ayaz Hafiz, #ideas › Decode Errors,
  345114039).
- The design was "not powerful enough to represent many of the patterns that serde can"
  (Brendan Hansknecht, *Revamped Encode and Decode*, 447120962).

**The current design (static dispatch, the Zig compiler).**
- A type has `parser_for` and `encoder_for` methods. A format is any type with the container
  protocol's methods (`src/build/roc/Builtin.roc` L1–L59; `docs/langref/static-dispatch.md`
  L65–L95, L353–L389).
- Structural types derive automatically. A nominal type opts in by writing `parser_for : _`.
- The derivable shapes are:
  - records, tag unions and tuples;
  - Bool, Str and the number types;
  - `List` and `Box`;
  - `Set` and `Dict` whose key has `is_eq` and `to_hash`.
- Functions, the empty union and rigid variables are not derivable
  (`src/check/Check.zig` ~L33380–L33661).
- **The target comes from the return type.** `Json.parse : Str -> Try(a, [InvalidJson(Str),
  ..errs]) where [a.Parseable(...)]` (`Builtin.roc` L270).
- **Inference works without an annotation.** `test/cli/JsonParseInferredArticle.roc` parses an
  article whose fields are known only from `article.title`, `article.author`, `article.views`
  and `article.tags`.
- **An inferred record is closed at the fields the program reads.** `closeRecordRowForDerivedParse`
  (`Check.zig` L33507–L33531) says: "once the dispatch has been deferred as far as it can go and
  nothing further is coming, take the fields the row has as the fields it gets and close it".
  When a field's own type never resolved, the result is the generic missing-method report
  (`src/check/report.zig` L2403–L2441).
- **Extra fields are skipped**, and a skipped value must still be valid JSON
  (`test/cli/JsonScalarParseEdgeCases.roc` L14–L27).
- **Missing, null and defaults** (`test/cli/JsonOptionalFieldKinds.roc`):
  - a missing required field is `MissingRequiredField("name")`, the bare name with no path;
  - `Try(a, [Missing])` reads absence and omits the key on encode;
  - `Try(a, [Null])` reads `null`;
  - nesting the two distinguishes all three states;
  - a defaulted record field fills absence, but "an explicit null is NOT absence: it stays a parse
    error";
  - "Encode always emits a defaulted field" (L90–L112).
- **Renaming is format-wide only**: `JsonEncoding` has `Default`, `CamelCase` and a `rename_field`
  (`Builtin.roc` L1482–L1497). Richard Feldman is "really resistant" to per-field annotations
  because of the combinatoric explosion across formats (#ideas › CBOR serialization, 627140731 to
  627142176).
- **Tags** encode as `"A"` with no payload, `{"B": v}` with one, and `{"C": [v1, v2]}` with more
  (`Builtin.roc` L1068–L1139, L1727–L1753). A discriminated union such as `{"type": "error", …}`
  needs a hand-written parser (#beginners, 622298071).
- **The error type**: `InvalidJson` carries the constant text "Invalid JSON" (`Builtin.roc`
  L324–L325).
- **The intent**: "the ergonomics of JavaScript's `JSON.parse()` but with eager validation"
  (Richard Feldman, #ideas › static dispatch - decoding, 481594968).

**Not verified.** Nested-path reporting (no test covers it). `TryFieldCaseless`. The roc-lang.org
builtins pages, which are generated from the cited source.

**What beni takes:**
- return-type dispatch;
- inference with Roc's closing rule;
- structural derivation with nominal types derived under the module rule;
- skipped extra fields;
- absence and `null` as distinct states;
- Roc's tag wire form.

**What beni does better:**
- full paths and structured issues (§5), where Roc's error is a bare field name or a constant
  string;
- one engine with declared schemas, so the step from "the JSON looks like my type" to "it does
  not" is a declaration with renames, defaults and conversions, not a hand-written parser.

### 12.2 The well-known method `codec`

**This amends §3's last paragraph** ("adds no well-known `a.schema` method and never selects a wire
format from a Type"). A.8 is the owner's reversal of it.

- `core/Schema` declares `pub type alias Codec a = Schema Value a`. This is a schema whose Encoded
  endpoint is the untyped host value: the Type endpoint and the wire, with no typed Encoded
  endpoint to name. `Schema.erased : Schema e a -> Codec a` forgets a declared schema's Encoded
  type and keeps its behaviour.
- The well-known method is **`codec : () -> Codec a`**. Its type mentions only `a`, so a `where`
  clause naming it satisfies the closure rule (`static-dispatch-spike.md` §2.4). `a.schema : () ->
  Schema e a` would not, because `e` occurs only in the constraint.

`core/Json` is a new core module, not in the prelude, so a program writes `import Json`:

```elm
decode      : String -> Result (List Issue) a                 where a.codec : () -> Codec a
encode      : a -> Result (List Issue) String                 where a.codec : () -> Codec a
decodeWith  : Options, String -> Result (List Issue) a        where a.codec : () -> Codec a
encodeWith  : Options, a -> Result (List Issue) String        where a.codec : () -> Codec a
decodeValue : Value -> Result (List Issue) a                  where a.codec : () -> Codec a
encodeValue : a -> Result (List Issue) Value                  where a.codec : () -> Codec a
```

`Schema.derived : () -> Codec a where a.codec : () -> Codec a` hands the derived schema to ordinary
composition, for example `Page.schema (Schema.derived ())`.

**Resolution of `(T, codec)`** extends `static-dispatch-spike.md` §3.3, in this order:

0. **A schema endpoint answers with its declaration.** A tagged schema's nominal `Message.Type`
   answers with `Schema.erased (Message.schema ())`. A *structural* endpoint, a record alias,
   is just a record type, so it is derived by step 3 with its Beni field names. To read
   `"user-id"`, call `User.parse` or pass `User.schema ()`. The two spellings never silently
   merge.
1. **The table** answers `Int` (§5's safe integer, both ways), `Float` (a JSON number; encoding a
   non-finite value is an Issue, §5), `Bool`, `String`, `Char` (a string of exactly one scalar
   value), `()` (the empty array, as the zero-tuple) and `Value` (identity).
2. **The module rule.** The declaring module's `pub codec` wins, as a `pub eq` does. Core uses it
   for its containers:
   - `List a` and `Array a` are arrays;
   - `Set a` is an array: encode writes it in set order, and decode reports a duplicate element as
     `InvalidValue` at its index;
   - `Dict k v` is an object when `k`'s codec describes a JSON string at its encoded end (`String`,
     or an opaque over `String`) and an array of `[k, v]` pairs otherwise. Two keys that write one
     property, or a repeated pair key, are an `InvalidValue` issue at the later position;
   - `Maybe a` is under §12.4;
   - `Int32` is a safe integer within 32-bit range.

   A user module's `pub codec` is how a validated newtype reads JSON. It is typically
   `Schema.erased (Schema.converted Schema.string userIdConversion)`, which runs the smart
   constructor (report 31 §4.2, "peel or reject": **peel, through the checked constructor**).
3. **Derivation by shape**, structural and recursive like `eq` (§12.3), for records, tuples and
   every `type` whose constructors are visible at the derivation site.
4. Otherwise `no_derived_codec` (§12.7).

**An opaque type is derived only inside its own module.** From any other module its constructors
are not visible, so a derived decoder would build values that skip the invariant the type exists
for. That is a guarantee, not taste. The error's hint is to declare `pub codec` in the type's
module, and that module may derive it there by writing `pub codec () = Schema.derived ()`.

For its own type, the module can write `pub codec () = Schema.structural ()`. `Schema.structural` is
compiler-known: at that site, resolution of the outermost type skips step 2, so the method does not
call itself. Every other position resolves normally. It is accepted only in the module that declares
the type; anywhere else it would bypass the module's invariant, so it is `no_derived_codec`.

Functions, foreign types other than `Value`, and extensible records with a rigid row are not
derivable. `Never` derives a schema that always fails with `WrongShape`, which is total: no value
has that type, so no guarantee is at stake.

### 12.3 The derived wire form

- **A record** is a JSON object keyed by its Beni field names. Every field is required except
  under §12.4. Encode writes keys in field-name order, which is beni's record order. Unknown keys
  follow `Options.unknownKeys`: **Ignore by default**, as in §5 and Roc.
- **A tuple**, and `()`, is an array of exactly its arity. A wrong length is `WrongShape`.
- **A custom type** uses Roc's form:
  - a nullary constructor is its name as a string (`"Red"`);
  - one argument is `{"Circle": v}`;
  - two or more are `{"Rect": [w, h]}`.

  An object that does not have exactly one own key is `WrongShape`. An unknown name is
  `UnknownTag`. The path goes through the constructor name and then the index, for example
  `[Field "Rect", Index 1]`.
- **Type parameters** become evidence, as for `eq`. `Tree a` derives once, with `a`'s codec
  passed in.
- **Recursion** goes through the type's own nominal identity under the §5 depth bound. A recursive
  structural alias is already refused by the language.
- **A derived description** has the same vocabulary as a declared one. Custom types add one node
  kind, `external_tagged` (the plan's next format version, beside §11.7's), whose rows are a
  variant's name and its argument references. Tuples, sets and dicts reuse `list` with a tuple,
  set or dict marker.

### 12.4 `Maybe`, presence and null

- **In a record field, absence means `Nothing`.** A `null` also means `Nothing` unless the inner
  type itself accepts `null`. Encoding `Nothing` omits the key.
- So `x : Maybe Int` accepts missing, `null` and `3`. And `x : Maybe (Maybe Int)` is exact: missing
  is `Nothing`, `null` is `Just Nothing`, and `3` is `Just (Just 3)`. That is Roc's nested
  `Try(Try(a, [Null]), [Missing])` (§12.1), with no new type.
- **Anywhere else** (list element, tuple element, root, constructor argument), `Maybe a` is
  `null` or `a`. If `a` itself accepts `null`, as with `Maybe (Maybe b)` or `Maybe Value`, the two
  `Nothing`s cannot be told apart. That is `no_derived_codec` with the reason, because a codec
  that cannot round-trip would be a silent wrong answer.
- `Schema.Presence a` and `Schema.Nullable a` derive their exact meanings: a field-only presence,
  and a `null`/value pair. They are the precise spelling when the lenient `Maybe` field is not
  wanted. `Presence` outside a field is `no_derived_codec`.

### 12.5 How the target type is found

The constraint `a.codec` arrives on a fresh variable at each `Json.decode` call
(`static-dispatch-spike.md` §4.2). That variable is resolved by the first of three routes that
applies:

1. **An annotation**, on the binding or the enclosing declaration: `config : Result (List Issue)
   Config`.
2. **Inference from later use.** The constraint is deferred to the end of the enclosing top-level
   declaration, as §4.2's later-use route allows, and is resolved there. Then **Roc's closing rule
   applies**: a record type under the constraint whose row variable is still open and does *not*
   occur in the declaration's generalised scheme is closed to the fields it has. A field whose own
   type never resolved is `derived_codec_needs_type`, which names the field and asks for an
   annotation.
3. **Forwarding.** When the variable does occur in the scheme, the constraint is the
   declaration's. It is written in an annotation's `where` clause, or, unannotated, promoted into
   the inferred suffix (§6.4) and chosen by the caller. A row that escapes into the scheme is
   never closed.

```elm
-- NEW (§12). `article` is inferred as { author : String, tags : List String, title : String, views : Int }.
summarize : String -> String
summarize text =
    case Json.decode text of
        Ok article -> article.title ++ " by " ++ article.author ++ ", " ++ String.fromInt article.views
                        ++ " views: " ++ String.join ", " article.tags
        Err issues -> Schema.formatIssues issues
```

Closing happens after unification has seen every use in the declaration, so a record passed to
`f : { r | name : String, age : Int } -> …` has gained `age` first. `dump --stage=types` prints the
closed shape. Every rule above is deterministic, with no dependence on worker order (CLAUDE.md
rule 5).

### 12.6 Closed records, extra fields, and a refactor that stops reading a field

- **The decoded record is always closed.** A record type cannot be built with fields nobody named.
  An inferred decode is closed at the read set, and an annotated one at its declaration.
- **Extra JSON fields** are unknown keys. They are ignored under the default Ignore and reported at
  their own paths under `Json.decodeWith { … | unknownKeys = Reject }`. With an inferred shape,
  Reject is legitimate but strict: every key the program does not read is reported.
- **A refactor that stops reading a field narrows the check.** This is the defined meaning, and
  Roc's: an inferred decode validates exactly what the program reads. The key that is no longer
  read becomes an unknown key, ignored by default, so a malformed value there no longer fails the
  decode. No guarantee is lost: a value the program never reads cannot make it misbehave, and every
  read stays checked before any field is touched. A contract that must hold independently of the
  reads, such as validating a document that is forwarded or stored, or conforming to an API, is
  written as a type annotation or a declared schema, and then a removed read changes nothing. No
  warning is specified: the narrowing is visible in `dump --stage=types` and in the description,
  and a lint would be a warning, never an error (CLAUDE.md rule 7).

### 12.7 Diagnostics

| Code | Title | Primary region and message shape |
|---|---|---|
| `no_derived_codec` | CANNOT DERIVE A CODEC | The `Json.decode`/`encode` (or `Schema.derived`) use: "`Model` cannot be read from JSON: its field `onClick` is a function (`msg -> Html msg`)." The message names the path to the first underivable position, as `eq`'s nested reason does, and gives one reason: a function; a foreign type; an opaque type outside its module ("declare `pub codec` in `UserId`'s module"); `Schema.structural` outside the type's module; an extensible record; a `Maybe` that accepts `null` outside a field; a `Presence` outside a field. |
| `derived_codec_needs_type` | DECODED TYPE IS NOT KNOWN | The field access or the `Json.decode` call: "I can see this decoded record has a field `meta`, but nothing says what type it is." The hint is an annotation. |

A use whose variable reaches a rigid annotation variable with no `where` is the existing
`missing_where_constraint`.

### 12.8 One engine: issues, specialisation, differential testing, release

- **A derived codec is a schema.** The checker synthesises a resolved schema plan (A.6's
  vocabulary plus `external_tagged`) from the type. The engine runs it with §5's context, options,
  depth bound, traversal order and issues.
- **Specialisation.** At a call whose target type is concrete, the derived plan is specialised
  exactly as a declaration is: straight-line workers, loops, and failure branches that build their
  own issue. Through evidence, the schema value passed is the callee's specialised worker, so a
  generic decode is not demoted to interpretation.
- **Where it is emitted.** A nominal type's derived codec is emitted in its declaring module,
  eagerly, like derived `eq`/`compare`, and removed by reachability when unused (`backend.md`
  §9). A structural shape (record, tuple) is emitted once per using module, keyed by its canonical
  shape: sorted field names, with one evidence parameter per position, as for derived `eq`
  (`static-dispatch-spike.md` §9.2).
- **The interface.** Derivability from outside the declaring module is a settled property of each
  named type, published beside `eq`/`compare`'s derived contexts (`checker-v2.md` §11) and covered
  by the interface hash.
- **Differential testing (Q9).** Every derived fixture runs through the compiled path and the
  forced library path, against an independently written expected answer.
- **`--release`** changes nothing observable.
- **Effects.** A derived codec has no conversions, so it is pure, unless a module-provided `codec`
  in its tree suspends. That class arrives through the evidence (§13).

### 12.9 Fixtures the derived-schema slice owes

- **`run/`, both paths:**
  - every table type;
  - records, nested records and tuples;
  - each custom-type wire form, with a payload record;
  - `Maybe` and nested `Maybe` in fields, elements and the root;
  - `Presence` and `Nullable`;
  - `Dict String v` and a `Dict` with non-string keys;
  - a `Set` duplicate;
  - a recursive `Tree a` at the depth bound and one past it;
  - a safe integer one past 2⁵³;
  - an opaque type through its module's `pub codec`;
  - Ignore and Reject;
  - FirstError and AllErrors paths through a constructor;
  - `encode` of NaN;
  - `Json.decode` inferred from use, matching Roc's article test;
  - a forwarding generic decoder across a module;
  - `Schema.derived` inside a declared schema.
- **`check/bad`:** every §12.7 reason; an opaque type decoded outside its module; an unresolved
  field type; a structural alias decoded where a declared schema with renames exists, which is
  accepted, and a `run/` twin shows it reads Beni names.
- **`dispatch/`:** the dispatch site and its evidence; a closed inferred row in
  `dump --stage=types`.
- **`emit/`:** a derived record worker without interpretation; DCE of an unused derived codec.

## 13. Suspending conversions

*Added 2026-10-02; specified, not built* (A.9 Q11, A.10). This supersedes §7's "synchronous until
P2" and its refusal to authorise an effects implementation, now that the owner has decided and the
runtime spike has landed (`transparent-effects-proposal.md` §14–§16).

### 13.1 Two classes per schema

- `transparent-effects-proposal.md` §14.5 gives every application of a nominal type one hidden
  class. **`Schema e a` and `Conversion b a` carry two: a decoding class and an encoding class.**
  `Codec a` is `Schema Value a`, so it carries both too. A `Check a` carries one.
- One class could not let `flip` move suspension from decoding to encoding, which is H4 case 2
  (§7).
- The interface block (§14.6 there) gains the step kind `7`, *directional class `i`* (`0` decoding,
  `1` encoding), after an application's argument steps. That bumps the interface format.

### 13.2 Where the classes are joined

`core/Schema`'s builders are `foreign`, and §14.3 rule 6 makes a callback handed to a `foreign`
independent of the call. So the joins are a **compiler-known table for `core/Schema`**, the way
`eq`/`compare` have a table. It is normative and closed: a new builder adds a row here in the same
commit (rule 1).

| Builder | Joins |
|---|---|
| `conversion dec enc` | `dec`'s arrow ⊑ result.decoding; `enc`'s arrow ⊑ result.encoding |
| `converted s c` | s.decoding, c.decoding ⊑ result.decoding; s.encoding, c.encoding ⊑ result.encoding |
| `flip s` | s.decoding ⊑ result.encoding; s.encoding ⊑ result.decoding |
| `typeOnly s`, `encodedOnly s` | the projected endpoint's checks ⊑ both result classes |
| a check builder over `f` | `f`'s arrow ⊑ the check's class |
| `checked s k` | k ⊑ s's two classes (checks run both ways, §5) |
| record, list, tagged, reference, `erased` and the rest | every child's decoding ⊑ result.decoding; every child's encoding ⊑ result.encoding |
| `decode`, `read`, `parse` (and `…With`) | s.decoding ⊑ the call's ambient (§14.3 rule 1) |
| `encode`, `write`, `print` (and `…With`) | s.encoding ⊑ the call's ambient |
| `describe` | nothing: it runs no callback |

**Generated members join directly**, because they are ordinary top-level functions (§7):
- `parse`/`parseWith`'s arrow gains every reachable `via` decoding callback, every check, every
  `default` expression and every referenced schema's decoding class;
- `print`/`printWith` gains the encoding side;
- `make` gains its `initial` expressions and the Type checks;
- `schema ()`'s result carries the two joins;
- a generic factory's result depends on its argument schemas' classes, which are summary
  dependencies (§14.4 there).

So `List.map`-style polymorphism holds: one `Page` serves pure and suspending element schemas.

### 13.3 What a program sees

- **A schema whose classes stay pure is emitted exactly as today, at no cost.**
- When a decoding class may suspend, `User.parse` is a suspending function. Its callers suspend,
  and the `sync` rule (`transparent-effects-proposal.md` §15) refuses it wherever suspension is forbidden, such as a page's
  `view` and `update`, or `main`. The chain names the field: "`update` calls `User.parse`, which
  suspends: field `avatar` converts with `Image.load`, which suspends."
- Decoding and encoding are independent. A schema that suspends only when decoding has a pure
  `print`.

### 13.4 The two paths

- **The specialised worker** uses the backend's suspendable form (`transparent-effects-proposal.md`
  §16.3) only in the workers whose class may suspend, along the path from the root to the
  suspending call. Other workers are untouched.
- **The library engine** is a privileged `core` sibling. It gets a suspendable **twin**,
  `<name>$$steps`, written against §16.1's protocol: one sentinel, one pending suspension. The
  lowering selects it at a call whose class may suspend, as `backend.md` §4's derived comparisons
  select their `$$steps` twin.
- In both, the traversal state survives the park and is resumed without re-traversal: path, depth,
  accumulated issues, finished sibling results and the position in the key walk. There is still one
  public API: no duplicated sync/async runner exists (§7).

### 13.5 Ordering, errors and cancellation

- **Sequential traversal stays the contract** (§5): FirstError starts no later sibling, and
  AllErrors runs siblings in declaration order, one at a time, so effect order equals traversal
  order. Concurrency is a separate option (§15 row *concurrency*).
- **A failure after a suspension is an ordinary directional failure** (H4 case 6).
- **Interrupting the fiber** stops the traversal at its suspension point. No later conversion runs,
  and the finalisers registered by conversions run (`transparent-effects-proposal.md` §16).

### 13.6 Fixtures

The seven cases in §7 are this slice's acceptance, through **both** paths, each with
`dump --stage=interface` showing the directional classes. They are joined by:
- a pure schema whose emitted bytes are identical to the pre-slice golden;
- a `sync_boundary` from `update`, and from `main` calling `parse`, with the field-naming chain;
- a suspending `default` and `initial`;
- a derived codec whose module-provided element `codec` suspends.

## 14. What is derived from a schema

*Added 2026-10-02; specified, not built* (A.9 Q6, A.10). The owner's answer is everything in the
milestone, and **a check written as a beni function is carried as an explicit opaque check in every
artefact, never dropped or weakened**. Each artefact reads the description (§5). Each returns a
`Result` when it can fail, and each states where it is weaker than the schema.

### 14.1 Check metadata

`Check a` is the library's check value. Its description entry is `Known KnownCheck` or
`Opaque { id : String, message : String }`.
- `KnownCheck` is a closed core type covering minimum and maximum length, `nonEmpty`, `pattern`
  (an ECMAScript regex source), `between`, `greaterThan`/`lessThan` with inclusive or exclusive
  bounds, `multipleOf`, `int32`, `finite`, unique items, `minEntries` and `maxEntries`, and a
  string format (`uuid`, `email`, `uri`, `date`, `dateTime`).
- A check built from a beni predicate is `Opaque`. Its `id` is the check's stable identity: the
  declaration path plus its ordinal in the plan. It never changes with worker order.

This closes Q6's "check identifiers/parameters … explicit opaque-check marker".

### 14.2 JSON Schema

```elm
toJsonSchema : Schema e a, JsonSchemaOptions -> Result (List Issue) JsonSchema
type alias JsonSchema = { document : Value, opaque : List OpaqueSite }
type alias JsonSchemaOptions = { dialect : Dialect, unknownKeys : UnknownKeys, endpoint : Endpoint }
```

- `Dialect` is `Draft2020_12` (the default) or `Draft07`. `endpoint` is normally `Encoded`, the
  wire.
- **Records** become `properties`. `required` lists every field without `optional` and without a
  `missing` default. Reject becomes `additionalProperties: false`.
- **Primitives:** `nullable` is `{"anyOf": [X, {"type": "null"}]}`. `Int` is `{"type": "integer"}`
  with the safe bounds.
- **Tagged unions** become `oneOf` with a `const` discriminator. Derived custom types use
  single-key objects.
- **Recursion** uses `$defs`/`$ref` by stable definition identity.
- **Defaults:** a default's `default` keyword is the encoded default, computed by encoding it, and
  a failure is an Err.
- **Known checks** become their keywords.
- **Opaque material:** every opaque check, and every `via` (a fallible conversion can reject a
  well-formed encoded value), adds `"x-beni-opaque": {"id", "message"}` at its position and an
  `OpaqueSite { path, id, message }` to `opaque`. **The document is therefore exactly as strong as
  the schema where `opaque` is empty, and the list names every place where it is weaker.**
- **Annotations** map `title`, `description` (from doc comments), `examples` and `deprecated` to
  their keywords.

### 14.3 Generators

```elm
sample  : Schema e a, Seed -> Result (List Issue) ( a, Seed )
samples : Schema e a, Int, Seed -> Result (List Issue) ( List a, Seed )
shrink  : Schema e a, a -> List a
```

- `Seed` comes from a core `Random` module. The pure half of `platforms/browser/Random.beni`
  (`Seed`, `Generator`, `step`; PCG, as Elm's is) moves to core, and the platform re-exports it and
  keeps `generate`, the command. A schema library in core cannot import a platform.
  *Amended 2026-10-02 (`boundary.md` §9.8.11 (a)): done. The core module is **`Random.Pcg`** — a
  platform module named `Random` shadows a core one of that name and could not import it — and
  each platform's `Random` names its seeds and generators as Elm does and adds `value`.*
- **What is generated.** Generation builds an Encoded value that satisfies the known checks, then
  *decodes* it. Conversions, defaults and opaque checks therefore run, and every sample is a value
  the schema accepts. A decode that fails is retried, up to `maxAttempts` (100 by default, in
  `SampleOptions`). After that the result is `Err` with the new issue code `SampleFailed`, naming
  the opaque checks that rejected. A sample is never promised for an unsatisfiable check.
- **Recursion** chooses a non-recursive variant past `maxDepth`.
- **Shrinking** shrinks the Encoded value towards the empty or zero value and keeps the candidates
  that decode.
- The annotation `Schema.generateWith gen` overrides one node, as Effect's arbitrary override does.

### 14.4 Pretty printing, equivalence, issue formatting

- **`pretty : Schema e a, a -> String`** renders a Type value with declared names and nominal
  constructors, in Beni literal syntax. An opaque conversion target is rendered through its
  encoding, and as `<TypeName>` when that encoding fails. It is total.
- **`equivalence : Schema e a -> (a, a -> Bool) where a.eq : a, a -> Bool`** is `==`.
  - beni already derives structural equality from the type (`static-dispatch-spike.md` §9), so the
    schema adds no second notion of it.
  - A module's `pub eq` overrides it, as Effect's `overrideToEquivalence` does.
  - `encodedEquivalence : Schema e a -> (a, a -> Result (List Issue) Bool) where e.eq : e, e ->
    Bool` compares wire forms.
- **Formatting.**
  - `formatIssues : List Issue -> String` is the default English rendering, one line per issue with
    the path in JSON-pointer-like form.
  - `Schema.issueCodec : () -> Codec Issue` sends issues over the wire (Effect's
    `StandardSchemaV1FailureResult`).
  - Per-node messages are the annotations `message`, `missingKeyMessage` and `unknownKeyMessage`
    (§15).
  - Issues stay a flat ordered list with full paths (A.2 Q4), not Effect's issue tree. The path
    carries what the tree's nesting does, and a `case` on `IssueCode` is the formatter hook.

### 14.5 Representation, import and code generation

- `Schema.descriptionCodec : () -> Codec Description` persists and transmits a description, which
  is Effect's `toJson`/`fromJson`.
- `fromDescription : Description, (String -> Maybe (Check Value)) -> Result (List Issue) (Schema
  Value Value)` rebuilds an **untyped** validator. Typed rebuilding would compute a type from a
  value (§9). Opaque checks are resolved by id through the supplied function. An unresolved one is
  an `Err` naming it, never a silently weaker validator.
- `fromJsonSchema : Value -> Result (List Issue) (Schema Value Value)` imports a JSON Schema the
  same way, at runtime. **Typed** import is tooling: a `beni schema import` command that writes
  `schema` declarations. It is a generator of source, not a language feature (report 32 row 146).
- `toSource : Description -> String` prints the `schema` declaration a description came from, or
  the nearest one when the description is derived.

### 14.6 Diff and patch, and optics

- `diff : Schema e a, a, a -> Result (List Issue) (List PatchOp)` produces RFC 6902 operations
  over the two encoded forms. `applyPatch : Schema e a, a, List PatchOp -> Result (List Issue) a`
  applies them and re-decodes the result, so a patch cannot produce an invalid value.
- **Optics** (Effect's `toIso`, `OPTIC.md`) need a checked field reference (report 32 H5), which
  the language does not have. They are specified separately as the milestone's last slice (§16).
  The proposed shape is generated lens members, `User.at.name : Lens User.Type String`. Until then
  this row is *missing*.

## 15. Effect v4 parity, feature by feature

*Added 2026-10-02* (A.10). This walks [`SCHEMA.md`](../../references/effect/packages/effect/SCHEMA.md)'s
feature list and `ARBITRARY.md`.

**Status** is:
- **spec'd**, with its section, if this document specified it before this slice;
- **now** if this slice specifies it (§11–§14);
- **proposed** if it is missing, with a proposed beni shape that must be specified before it is
  built (rule 1);
- **n/a** where the feature exists only for TypeScript or JavaScript, with the reason.

Report 32's 164 rows are the finer inventory. This table is the parity ledger, and its *proposed*
rows are scheduled in §16.

| Effect feature (SCHEMA.md) | Status | beni shape |
|---|---|---|
| Primitives, `Null`, `Unknown` (L204) | spec'd §4 | String, Bool, safe Int, Float, finite Float, `Null`, `Value` |
| Literals, union of literals (L243, L2068) | proposed | `schema Color = enum of Red as "red" \| Green as "green"`: a nominal all-nullary Type, a bare string on the wire |
| String checks and formats (L296, L324) | now §14.1 | `KnownCheck` with `check` (row *filters*) |
| Numbers, integers (L336, L358) | spec'd §4–§5 / now §14.1 | safe `Int`, finite `Float`; `between`, `multipleOf`, `int32` checks |
| BigInt (L369) | proposed | needs a core `BigInt` type first (§9); then a `String` and number conversion |
| Dates (L405) | proposed | the platform's time module declares `pub codec` and a `Conversion String Time` (ISO 8601) |
| Template literals and their parser (L410, L452) | proposed | `Schema.template : Template a -> Schema String a`, built from `Template.literal` and `Template.capture schema` with `map2`-style combination; no template literal *types* (a computed type, §9) |
| Struct (L492) | spec'd §2 | record schema |
| `optionalKey` (L496) | spec'd §4 | `optional`, typed `Presence` |
| `mutableKey` (L496) | n/a | beni values are immutable |
| `optional` (absent or `undefined`) and `NullOr` (L525) | spec'd §4 | beni has no `undefined`; `optional`, `nullable` and both, distinct |
| Omitting a value when transforming optional fields (L564) | now §11 / proposed | `default … when null`; the presence-level conversion below |
| `optionalKey(Never)` (L597) | n/a | a TypeScript type trick |
| Decoding defaults, encoded or type side, key or `undefined` (L623–L763) | now §11 | `default`, `default encoded`, `when missing \| null \| invalid` |
| Manual decoding defaults (L765) | now §11 | `default … when missing or null`, `when invalid` |
| Optional fields as `Option` (L855) | spec'd §4 / now §12.4 | `Presence`, `Nullable`; derived `Maybe` fields |
| Key annotations, `messageMissingKey` (L993, L1018) | proposed | `annotate` modifier (row *annotations*) with `missingKeyMessage` and `unknownKeyMessage` |
| Unexpected keys (L1039) | spec'd §5 | `Options.unknownKeys = Ignore \| Reject` |
| Index signatures, number keys (L1046, L1823) | now §12.2 / proposed | derived `Dict`; in declarations a `Dict k v` operand with key conversions, where colliding keys are an Issue and never "last wins" (report 32 row 55) |
| `StructWithRest` | proposed | a `rest` field modifier: `extra : Dict String Value rest` collects unclaimed keys and writes them back |
| Renaming encoded keys (L1108) | spec'd §2 | `as "k"` |
| Reusing fields, `pick`/`omit`/`merge`/`partial`/`required`, mapping fields and keys (L1140–L1459) | proposed | **declaration derivation**: `schema Patch = partial User`, `schema Summary = pick User (id, name)`, `schema Admin = extend User` plus fields, `schema Wire = derive Model.User keys snake_case`. The compiler writes a new declaration with its own Type from the old one's syntax and plan. This is a computed *declaration*, not a computed type, so §9's objection does not apply. It also gives derived codecs Roc's format-wide renaming without per-field annotations. |
| Opaque structs (L1460, L3687) | spec'd §4 / §12.2 | a tagged schema's nominal Type; `pub opaque type` with `pub codec` |
| Tagged structs (L1487) | spec'd §2 | `tagged "kind" of`, where the tag is the constructor |
| Tuples, rest elements, element annotations (L1518–L1752) | now §12.3 / proposed | derived tuples; in declarations a `( A, B )` operand, and a rest element as a trailing `List` operand |
| Arrays, unique arrays (L1753, L1765) | spec'd §4 / proposed | `List a`; a `unique` known check using the element type's `eq` |
| Records, key transformations (L1780–L1930) | proposed | as for index signatures |
| Unions, first match, exclusive unions (L1931–L1996) | proposed | `schema Id = untagged of IntId Int \| TextId String` tries variants in order and builds the declared constructor; `exclusive` makes two matches an Issue |
| Deriving unions (`mapMembers`) (L1997) | proposed | declaration derivation (above): `schema B = extend A` with variants |
| Tagged unions and their helpers (`cases`, `guards`, `match`) (L2108–L2233) | spec'd §2 / n/a | `case` is the matcher and the compiler proves it exhaustive |
| Recursive schemas (L2235) | spec'd §2 / proposed | explicit nominal recursion is spec'd. A self-referencing *record* schema is proposed: its Type elaborates to a nominal single-constructor record type, since a structural alias cannot recurse (§8) |
| `declare`, `declareConstructor` (L2315–L2521) | spec'd §4 | `Value` plus `via` a `Conversion`; generic schemas take explicit schema arguments |
| Filters, return shapes, groups, abort (L2523–L2793) | proposed | a `check Atom` value modifier taking `Check a`. Checks are built with `Schema.predicate : String, (a -> Bool) -> Check a` and `Schema.judge : (a -> List Issue) -> Check a`, which gives relative paths and several issues. `Schema.allOf` groups checks and `Schema.aborting` stops after a failure. The plan's `check` node (A.6) already exists. |
| Structural filters' ordering (L2824) | spec'd §5 | composite checks wait for their children |
| Effectful filters (L2855) | now §13 | a check may suspend; its class joins both directions |
| Refinements narrowing the type (L2794) | n/a | a computed type; an opaque type with a `via` conversion is the stronger nominal form |
| Brands (L2810) | spec'd §4 / §12.2 | `pub opaque type`, a real nominal type rather than a phantom brand |
| Constructors, `make`, `makeOption` (L2921–L3029) | now §11.6 | `make : Init -> Result (List Issue) Type`, which validates |
| Constructor defaults, nested, effectful (L3030–L3147) | now §11.6, §13 | `initial`, evaluated per call; impure or suspending through the inferred classes |
| Tagged `make` | proposed | `Message.Init` as a third constructor family; `initial` in payloads |
| Transformations as values, the type, composition (L3149–L3372) | spec'd §4–§5 | `Conversion b a`, `via`, `converted`; composition decodes forward and encodes backward |
| Effectful transformations | now §13 | inferred per direction |
| Passthrough helpers, strict mode (L3405–L3486) | n/a | TypeScript subtyping negotiation; beni unifies or reports |
| Managing optional keys (`transformOptional`) (L3487) | proposed | `presence via c` with `c : Conversion (Presence b) (Presence a)`: a conversion that sees and can produce absence |
| Omitting a key during encoding, `tagDefaultOmit` (L3549) | now §11.4 / proposed | `default … omitted`; `presence via`, whose encoder returns `Missing` |
| Flipping (L3605) | spec'd §5 | `flip`, involutive |
| Classes, `TaggedClass`, `Error`, `TaggedError` (L3683–L4630) | n/a / spec'd | a module with a nominal type is beni's class; error types are ordinary custom types with a schema |
| JSON support, `fromJsonString` (L4635) | spec'd §4 / now §12 | `parse`/`print`; `Json.decode`/`encode` |
| Base64, Base64Url, hex, URI component (L4674) | proposed | `Conversion String String` values in `core/Schema`; the byte-array variants follow a core bytes type |
| FormData, URLSearchParams (L4756, L4834) | proposed | browser platform adapters `Form.toValue`, `Url.queryToValue` producing `Value`, plus a schema-level string-leaf option for form fields |
| Canonical codecs: JSON, StringTree, ISO (L4906–L5191) | spec'd §1 / proposed | `Value` is the JSON one; StringTree is the adapter option above; ISO is n/a with no optics |
| XML encoder (L5192) | proposed | an adapter outside core over `write`'s `Value` |
| JSON Schema output, metadata, encoded-side annotations, optional fields, custom types, constraints (L5251–L5726) | now §14.2 | `toJsonSchema` with the opaque list |
| Equivalence (L5727) | now §14.4 | `==` (derived `eq`); `encodedEquivalence` |
| Optics (L5779) | proposed §14.6 | generated `User.at.field` lenses, after a checked field reference |
| Differ / JSON Patch (L5839) | now §14.6 | `diff`, `applyPatch` |
| Representation, persistence, rebuild (L5920–L6217) | spec'd §5 / now §14.5 | `describe`, `descriptionCodec`, untyped `fromDescription` |
| JSON Schema import (L6259) | now §14.5 | an untyped runtime validator; typed import as a source generator |
| Code generation (L6324) | now §14.5 | `toSource` |
| Concurrent product parsing (L6342) | proposed | `Options.concurrency = Sequential \| Bounded Int \| Unbounded` over the fiber runtime's `spawn`. Completion-order effects and the first-error interruption follow Effect, while issues stay in traversal order. Sequential stays the default. |
| `reportInput` (L6384) | spec'd A.6 | `Options.reportInput`, off by default |
| Formatters, hooks, inline messages, failure over the wire (L6409–L6691) | now §14.4 / proposed | `formatIssues`, `issueCodec`; message annotations (row *annotations*) |
| Fallbacks, `catchDecoding`, with a service (L6696–L6766) | now §11 | `default … when invalid`; a service is an ordinary argument |
| Middlewares (L6692) | proposed | `Schema.mapDecoded : Schema e a, (Result (List Issue) a -> Result (List Issue) a) -> Schema e a`, and its encode twin. The callback sees relative issues only and cannot reset context (§5). |
| Annotations, typed and key-level (L6926, L6983) | proposed | an `annotate Atom` value modifier taking `Annotation`, with `Schema.title`, `examples`, `deprecated`, `message`, `missingKeyMessage`, `unknownKeyMessage` and `generateWith`. Doc comments are `description`, and the plan's `annotation` node (A.6) already exists. |
| Separate requirement parameters `RD`/`RE` (L7004) | now §13 | two inferred directional classes, with nothing written |
| `is`/`asserts` guards | n/a | there is no `unknown`; `decode` on `typeOnly` validates a typed value |
| Experimental JIT/AOT compilers (L68) | spec'd §6 | every declaration is specialised ahead of time, with no `new Function` |
| Arbitrary (`ARBITRARY.md`) | now §14.3 | `sample`, `samples`, `shrink`, `generateWith` |
| Standard Schema V1 (L6411) | n/a | a JavaScript interop contract; a platform package may adapt it |

## 16. The schema milestone's slices

*Added 2026-10-02* (A.10). This plans the whole milestone from where §10 stands. S1 (frontend) and
S2 (checker) have landed, and §10's S3–S5 are re-cut below. Sizes are relative:
- **S**: one implementer and reviewer pass;
- **M**: about two;
- **L**: three or more, or a slice that may need splitting when its spec is read against the code.

Every slice is red-first under §10's rules, through both paths where it has runtime behaviour,
and lands with all three gates green.

| # | Slice | Contract | Depends on | Size | Done means |
|---|---|---|---|---|---|
| S3 | Engine and library interpreter (**built**, 2026-10-01; *As built* below) | §1, §4–§5, A.6; the concrete builder API is specified first, in this document | S2 | L | `Issue`/`Options` semantics; records, lists, tagged, primitives, `via`, `optional`/`nullable`, recursion; the native-recursion ceiling measured and recorded in §5; §10's S3 fixture list |
| S4 | Specialisation, `build` unwalled, differential harness | §6, §10, Q9 | S3 | L | parse/print workers; the forced-library switch, test-only; every schema fixture runs both paths in `test-blackbox`; DCE per direction; `bench/schema-libraries` gains a beni row |
| S5 | Defaults and `make` | §11 | S4 | M | §11.10 |
| S6 | Checks, annotations, check metadata | §14.1, §15 rows *filters*, *annotations* | S4 | M | the `check` and `annotate` modifiers; `KnownCheck`; opaque ids; messages |
| S7 | Derived codecs and `core/Json` | §12 | S4 (S5 is not needed) | L | §12.9; `Codec`, `erased`, `derived`; the closing rule; the interface property |
| S8 | Declaration surface completion | §15 rows *enum*, *untagged*, *tuples*, *Dict*, *rest*, *presence via*, *recursive records*, *tagged `make`* | S5, S6 | L | each row specified as a dated §2/§4 amendment first, then built |
| S9 | Suspending schemas | §13 | S4, effects runtime (landed) | L | §13.6 and §7's seven cases through both paths |
| S10 | JSON Schema output | §14.2 | S6 | M | both dialects; the opaque list; defaults; recursion; a validator cross-check of samples (S11) once S11 lands |
| S11 | Generators | §14.3 | S6 | M | core `Random`, re-exported by the browser platform; `sample`/`samples`/`shrink`; `SampleFailed`; depth; overrides; every sample decodes |
| S12 | Pretty, equivalence, formatting, representation, diff | §14.4–§14.6 | S6, S7 | M | `pretty`, `encodedEquivalence`, `formatIssues`, `issueCodec`, `descriptionCodec`, `fromDescription`, `fromJsonSchema`, `toSource`, `diff`/`applyPatch` |
| S13 | Declaration derivation | §15 row *pick/omit/partial* | S8 | M | `partial`, `pick`, `omit`, `extend`, `derive … keys …`, specified first |
| S14 | Adapters and conversions | §15 rows *Base64*, *FormData*, *Dates*, *template*, *concurrency* | S8, S9 | M | the core conversions; the browser adapters; the template builder; the concurrency option over `spawn` |
| S15 | Optics | §14.6 | S13; a checked field-reference spec | M | specified, then built; until then §15 marks it *proposed* |

**Order.** S3 → S4 is the trunk.
- S5, S6, S7 and S9 can then run in parallel worktrees: they touch different sections of the plan
  and the engine, and S9 touches the checker's effect classes, which the others do not.
- S8 builds on S5 and S6. S10–S12 need S6's metadata.
- S13–S15 close the milestone.
- The performance claim of §6 is re-measured after S8 and again at the end, with the many-schema
  code-size curve §6 says is still owed.

**As built — S3** (2026-10-01). `core/Schema.beni` declares the builder API of §5 (*The builder
API*) over `core/Schema.js`, the engine; `build` still refuses `schema` declarations (§8), and a
program that only builds schemas with the library builds and runs, under `--release` too.

- **The engine is the sibling.** It was written first in beni over core's `Js`, with a `typeof`
  intrinsic added for it, and passed every fixture below in both builds. Then the gates measured
  it: core is checked whole by every `beni` process, whether or not the program imports `Schema`,
  and the module's check went from 0.34 ms to 34 ms (ReleaseSafe compiler, `--self-profile`,
  best of 5; 1 300 lines of code, the solver alone 15 ms). Four tests already near their budget
  went over it, and `zig build test-blackbox` went from 563 to 1 142 user-seconds in one A/B at
  moderate load. As `foreign`s over a JavaScript engine the module checks in 2.7 ms, every test is
  inside its budget, and the `typeof` intrinsic was withdrawn with the beni engine. **Core's
  checking cost is per process** — the persistent cache does not help a test's fresh directory —
  so every line of beni added to core is paid by every test; whatever else S5–S15 add to core
  (`Json`, `Random`) meets the same wall, and checking only the core modules a program reaches is
  the fix that would lift it. It is not built here. *Amended 2026-10-01:* it is built
  (`checker.md` §4, amended the same day): a core module nothing imports is no longer lowered or
  checked, so a program that does not import `Schema` pays nothing for it. *Amended again
  2026-10-01: the engine is beni* (§5's amendment), `core/Schema.js` deleted. **Its check is in
  budget, and the 34 ms was the safe build's.** `Schema.beni` is 2 242 lines, 1 480 of them code;
  its check takes 25.8 ms on the ReleaseSafe compiler the tests run and 3.6 ms on the ReleaseFast
  LLVM one users get (solve 1.8, constrain 0.6, effects 0.4; the front end 1.1 more), 315 000 code
  lines a second whole — inside `fast-compiler.md` §2's 250 000. The safe build is 7.2× slower on
  it and 7.8× slower on `core/List` (9.3 against 1.2 ms), the one factor across modules, so the
  engine's shape holds no checker hotspot; the solver is the largest phase in both, as everywhere.
  What a Schema program now pays is real but bounded: `run/SchemaFailures` builds in 596 M
  instructions (413 M with the JavaScript engine) and under `--release` in 2 078 M (1 229 M),
  whole-program specialisation of the engine being most of the difference; every test is inside
  its budget. Release brotli of `bench/schema-library`'s `SchemaSize`: 4 531 → **4 503**. Speed, A/B
  interleaved on one pinned core: as **applications** (whole-program specialised; 300 000
  operations, wall ms, median of 7) parse 358 → 351, decode 162 → 158, print 466 → 469 — no
  slowdown; as the bench's **`--library`** build, which specialises nothing, 5–38 % slower (read
  flat 402 → 501 ns, decode flat 320 → 442 ns, parse list 0.92 → 1.05 ms): the hand-written
  engine was specialised by hand, and a library build of beni-written core is not specialised at
  all. That is the wall, recorded in `plans/core-in-beni.md`. *Amended 2026-10-02:* a library
  build is specialised now (`backend.md` §9, amended), a self-call after `||` or `&&` is a tail
  call (§8, amended), and the record loop writes `Object.hasOwn` and `push` out: the bench is
  within 1–3 % on valid input and 4–6 % on failures (`plans/core-in-beni.md`).
- **The ceiling** (§5's amendment): `maxDepthCeiling` 1 024, default 512. The deepest value one
  cold operation survived in a fresh Node 24 process (default stack, 984 KB), by bisection over
  processes, in depth units: a tree whose level is a payload, a field and an element (three
  units) — parse 3 546, print 3 537, decode 3 537; a chain whose link is a payload and a field —
  parse 4 688, encode 4 654. Warm, the same operations reach 4 350–5 700. One level of a value
  costs two frames, `run`'s and its record's or list's loop, and each conversion or `nullable` on
  the way one more. The first, beni engine needed seven frames a level and overflowed at 1 366
  units; pulling a level's work into the loops' first turn and out of the recursion is what
  bought the margin. Not measured: SpiderMonkey and JavaScriptCore, and a caller that has already
  spent the stack.
- **Release found a defect elsewhere**: whole-program specialisation gave the top-level bindings
  a body written in place declares no whole-program name, and dropped the tag of every `Result` a
  stored conversion returned; fixed in `Spec`, with `run/SpecializeFreshTopLevel`.
- **Fixtures** (`run/`, each a project with a `Show` module, built and run in development and
  under `--release`): `SchemaDirections` (both fallible directions, flip twice, projections with
  different endpoint shapes, renamed keys, endpoints with no external form), `SchemaPresence`
  (every missing/null/present combination of the four field forms, a renamed optional field
  under `Reject`), `SchemaFailures` (AllErrors' order — unknown keys, a structural failure, a
  conversion's, a refinement's; FirstError's laziness by `Debug.log`; a whole-record conversion
  waiting for its fields; a conversion's issues moved, its empty `Err`; `reportInput`),
  `SchemaTagged` (the discriminator, key order, unknown and non-string tags, two nominal
  families, nullary variants, a recursive union's deep path), `SchemaDepth` (depth 0, 1, 2, 512
  and the ceiling, each with one level more; invalid options; a printed `Value` within the bound,
  and one 20 000 deep), `SchemaProtoKeys`, `SchemaDescribe` (both endpoints, nested recursive
  definitions met once, two definitions with one name, no conversion run), `SchemaConstruction`
  (every construction failure, a reference used while its body is built, a nonproductive cycle),
  `SchemaJson` (`ParseFailed` with the host's message, `PrintFailed` at the key, `JSON.parse`'s
  rounding, a `Value` holding NaN). Each was red against the library before it: no builder
  existed. Not covered: a `.crash` scenario for the `JSON.parse` re-throw — it throws nothing but
  a `SyntaxError` for a string, so no input forces another error.
- **Size** (`bench/schema-library/run.mjs`, brotli 11 of the whole output): a program that parses
  report 34's `flat` user and prints it back is **4 534** bytes under `--release` (12 786 raw),
  against 133 for the empty program; development 16 741. Nearly all of it is the engine, which a
  build that uses any runner ships whole; `describe` and what only it reaches are cut. No
  hand-minifying pass was made beyond writing to the compactor's rules: S4's specialised code is
  the size path, and the library ships to programs that compose schemas at run time.
- **Speed** (the same harness, `--release --library`, Node 24, Ryzen 9 5950X, `taskset -c 8`,
  load 37–39, median per call of 15 interleaved samples, the interquartile range within ±3 %):
  `flat` — `JSON.parse` 728 ns, parse 1 537, `read` of the parsed object 568, parse failing on a
  wrong type 1 427, on a missing key 1 204, on an unknown key under `Reject` and `AllErrors`
  1 690, typed decode 473; `JSON.stringify` 791, print 2 124. `list` — `JSON.parse` 651 µs,
  parse 1 122 µs; `JSON.stringify` 670 µs, print 1 558 µs. These are the library's numbers for
  S4 to be measured against, not a comparison with any other library.

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
This keeps the library from imposing report 34's unfused cost on specialisation.

### A.2 — Surface and traversal decisions (2026-09-22)

Owner review accepted Q1: input schema plus fallible `Conversion b a`, optional
target checks defaulting to none; Q2: the recommended v1 primitives with
Dict/tuples/BigInt deferred; Q4: ordinary `Result (List Issue)` and nonempty Err
invariant; Q5: Effect defaults and a bounded maxDepth with native recursion;
Q8: schema/parse/print plus parseWith/printWith only, typed operations in the
library; Q10: schema operands, separate Presence/Nullable, explicit nominal
recursion. §§2–6 record these decisions. Exact safe depth numbers still need
implementation evidence (a portable native-recursion ceiling). Q3/Q6/Q7/Q9/Q11 remain open.

### A.3 — Implementation order (2026-09-22)

The owner delegated Q12. Schedule the frontend next; fix the confirmed numeric-alias defect
before checking. Continue checking, the library and specialisation in dependency order after their remaining decisions;
the effects work follows P2 and H4. The first three M4 steps recorded as preceding schemas have landed, so this
places schemas ahead of remaining M4 work without rewriting that history.
This revision changes documents only; it does not claim any slice landed.


### A.4 — Opaque boundary construction and parallel scheduling (2026-09-22)

The owner settled Q6's representation clause: an opaque target is reachable
only through its conversion; typeOnly retains optional checks (identity if none),
and read/write construction fails if Type contains an opaque target without a
structural description (§5). Q6's metadata and JSON Schema/generator scope
remain open. The numeric-alias defect is an independent checker fix with check/good fixtures:
it may run in parallel with the frontend, and must land before checking. This updates A.3's
ordering without making the fix a dependency of the frontend.


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
and `let` are unchanged. This surface slice follows the frontend and precedes checking.


### A.6 — Checked type surface, interface and resolved plan (2026-09-22)

The owner confirmed Q7: constructor patterns use exactly the expression name.
The program family is `Message.Count row`; the encoded family is
`Message.Encoded.Count row`; a module prefix may precede either. Exposing a
schema exposes neither family as bare constructors.

`core/Schema.beni` establishes the public type surface which the library and specialisation
implement against. `Presence` and `Nullable` are distinct custom types.
`Issue` is a record carrying `path : List PathSegment`, `direction : Direction`,
`endpoint : Endpoint`, a structured `IssueCode`, `message : String`, and
`input : Maybe Value`; `Value` is an opaque host handle rather than a Beni
value tree. `Options` is a record with `errors : ErrorMode`,
`unknownKeys : UnknownKeys`, `maxDepth : Int`, and `reportInput : Bool`.
Defaults are `FirstError`, `Ignore`, and `reportInput = False`; the library's stack
proof still decides the default and maximum depth numbers. `InvalidSchema`
covers a malformed or dangling description and nonproductive recursion;
`ConversionFailed` includes a callback which violates the nonempty `Err`
invariant. `Schema e a`, `Conversion b a`, and `Value` are `pub foreign type`s
whose JavaScript representations belong to the engine. This is a type
contract, not a frozen representation: Q11 remains open and checking adds no
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
this is the explicit checking boundary after the frontend's version 2 unresolved schema graph,
and its existing `verifySchemaInst` validation remains mandatory. *(2026-09-24: the
checker rewrite made it version 4 — `Token.Tag` gained `dot_dot`, which
shifts later tags, and `Bir.Exposed` gained `all_ctors_token` — with no change
to the schema sections.)* Once checked, `via`
leaves use ordinary value-reference instructions and declaration references:
these are real value dependencies for mixed schema/value SCCs and cache keys.
The BIR dump therefore shows `qualified` and `import_value` for imported
conversion leaves where the frontend showed inert `schema_expr_ref` placeholders. This
is a permanent dependency representation, not a temporary execution surface.

The unhashed cache sidecar gains one resolved-plan section. The cache entry
becomes version 2 (3 since the checker rewrite, whose `dispatch` section is
`dispatch_bytes` format 2, `checker-v2.md` §14.3) and its sections are `interface`, `dispatch`, `schema_plan`,
`diagnostics`. *(2026-09-28: plan format 2 and entry format 4 — plan terms name an
alias and carry its body on the `type_refs` row, as interface terms do, `checker-v2.md` §14.2 and
§14.3.)* `schema_plan` uses magic `BENISPL\0`, format version 1, the
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
the presence of opaque checks. When checked, an arbitrary `via` expression sets both:
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
local and external call dependencies. Checking does not split it into directional
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

*Amended 2026-09-26 (checker rewrite, `checker-v2.md` §11.5).* Under the
new checker the property bytes are read off the derived contexts in P9, not off settled session
bits, and a cache hit of a module it checked restores nothing into the session table: the
old checker's settle (`Schema.settleProperties`) is not on its path. What a dependent observes
about an endpoint — whether and how it derives `eq` and `compare`, and its `equatable` gate — is
in the record's hidden rows, which the interface hash covers; the digest's named-type rows hash
the table's bits, which are the same in a cold and a warm build. The old checker kept the rule
above until it was deleted (2026-09-27), with `Schema.settleProperties` and the table's schema
property bits.

Checking moves the temporary wall rather than removing it. `check` accepts a valid
schema program and all resolution-requiring dumps see these interface members.
`build` stops in `Emit.run`, before `findEntry` and before writing any path,
with `not_implemented` on the schema name: “This schema is checked, but its
parse and print are not generated yet.” A schema program cannot
build successfully without its runners.

### A.7 — Defaults in the declaration; Effect's power is the bar (2026-10-02)

The owner answered **Q3: defaults belong in the schema definition**, and set the bar for
the whole feature: **"The schema definition must be as powerful as Effect."** v1 therefore
has Effect v4–class field defaults declared in the schema, with the distinctions Effect
draws: what triggers a default (a missing key, an explicit `null`, and — never silently —
an invalid value only where the author asks), which direction it applies to (a decoding
default when reading, a constructor default when a value is built in code), and how
encoding treats a value equal to its default (written or omitted, declared, so a round trip
never changes data). Both execution paths — specialised code and the library interpreter —
implement them with identical results and identical issues. The Q3 row in the open table
above is superseded by this entry; the exact surface syntax is the next schema slice's to
specify against `references/effect` (`Schema.optionalWith`, `withDecodingDefault`,
`withConstructorDefault`, `optionalToRequired`, and their v4 equivalents).

### A.8 — A schema derived from a type, as Roc decodes (2026-10-02)

The owner accepted that the zero-ceremony end of the feature is **type-directed decoding**: a
`Json.decode`-style operation whose decoder is derived from the type the program uses the result
at — annotated or inferred, through static dispatch's return-type dispatch, the way `eq` and
`compare` are derived — so a value parsed from JSON is validated against the shape the program
reads before any field is touched (Roc's `Decode` ability is the model; verify its exact
behaviour from primary sources before specifying). A derived decoder is a schema generated from a
type and runs on the same engine as declared schemas: the same issues, specialisation,
differential testing and release behaviour. Declared `schema`s (A.7's Effect-class power:
renames, two representations, defaults, transformations) remain the tool when the JSON does not
look like the type. Open questions the specification slice must settle: closed versus open
inferred records, extra JSON fields, and what a refactor that stops reading a field does to the
check.

### A.9 — Q6, Q9 and Q11 answered (2026-10-02)

The owner answered the remaining open questions:

- **Q6 — everything.** Inspection (the description), JSON Schema output, sample-data generators,
  and the rest of what Effect derives from a schema (pretty printing, equivalence, and the like)
  are part of the schema milestone, not later libraries. A check written as a beni function is
  carried as an explicit opaque check — never dropped or weakened — in every derived artefact.
- **Q9 — agreed.** Every schema semantic fixture runs both execution paths (specialised code and
  the library interpreter) inside the gates, in development and release, and also asserts an
  independently written expected answer.
- **Q11 — yes.** A conversion may suspend. Whether a schema suspends is inferred from its
  conversions: a schema whose conversions never suspend stays synchronous at no cost; one that
  may suspend decodes and encodes as suspending operations, and the `sync` rule refuses it where
  suspension is not allowed (`view`, `update`).

The open-decisions table at the top is superseded by A.7–A.9; no schema question is open.

### A.10 — The rest of the milestone, specified (2026-10-02)

This slice turns A.7–A.9 into contract. Each new section's text is normative; this entry records
the choices that were not forced by the owner's words, so they can be reversed.

- **Defaults (§11).**
  - The triggers are spelled after `when`. `missing` alone is the default trigger, as in Effect's
    `…Key` APIs and in Roc.
  - `invalid` is opt-in and discards the recovered issues.
  - Encoding writes the value by default (Effect's passthrough, Roc's "always emits"), and
    `omitted` is the declared alternative. Two refusals protect the round trip:
    `omitted_default_needs_missing` and `omitted_default_not_pure`.
  - A Type default still runs the Type endpoint's checks.
  - Constructor defaults use a separate word, `initial`, because Effect separates the two
    directions. `make` validates and returns `Result`, as Effect's `makeOption` does with issues
    kept.
  - *Reversal:* make `default` imply `initial`, or let `make` skip validation. No other section
    depends on either choice.
- **Derived schemas (§12).** Roc's actual behaviour was read from source (§12.1) and its four
  load-bearing choices are taken:
  - return-type dispatch;
  - inferred records closed at the fields read;
  - extra fields skipped;
  - its tag wire form.

  The method is `codec : () -> Codec a`, with `Codec a = Schema Value a`, because a `where`
  clause cannot mention a typed Encoded variable that is not in the annotation
  (`static-dispatch-spike.md` §2.4). An opaque type derives only inside its module, where
  `Schema.structural` asks for its shape. A structural schema endpoint is derived with its Beni
  names, never read with a declaration's renames. *Reversal of the closing rule:* demand an
  annotation (Roc's old compiler). That costs the inferred `Json.decode` and nothing else.
- **Suspension (§13).**
  - `Schema` and `Conversion` carry two directional classes, not §14.5's one, so `flip` can move
    suspension (H4 case 2).
  - `core/Schema`'s builders get a compiler-known join table, because rule 6 there would otherwise
    lose every callback's bits.
  - The library engine gets a suspendable twin. This follows the derived comparisons' `$$steps`
    precedent rather than adding a public async API.
- **Artefacts (§14).**
  - Every artefact names where it is weaker than the schema (the JSON Schema `opaque` list,
    `SampleFailed`, the resolver argument of `fromDescription`), so an opaque check is never
    silently dropped.
  - Generation decodes what it generates, so every sample is accepted by the schema.
  - `equivalence` is `==`, because the language already derives it.
  - The pure half of the browser platform's `Random` moves to core, because a core library cannot
    import a platform.
- **Parity (§15).**
  - The type-computation rows that report 32 marked *cannot* (`pick`, `omit`, `partial`, `extend`,
    `mapMembers`) are proposed as **declaration derivation**, which computes a new declaration at
    compile time and not a type from a value. This is the one place where this slice disagrees with
    report 32, which recommended against it.
  - Optics remain *proposed* until a checked field reference is specified.
- **Slices (§16).** S3 and S4 are the trunk. S5, S6, S7 and S9 can run in parallel worktrees once
  S4 lands, and S15 closes the milestone.
