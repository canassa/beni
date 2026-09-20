# 32 — Schemas at Effect parity: one declaration, both directions, a differing wire shape

**Commissioned by** the project owner, 2026-09-21, after reading
[report 31](31-derived-codecs.md): *"We need something as powerful as Effect schemas. That's the
gold standard."* · *"In Effect the schema is both an encoder, decoder and type."* · *"There are two
different types for the same schema. The encoded and decoded. Deriving schema from type is not
enough. Most real life schemas have different representations."* · *"I am starting to lean in the
new syntax camp."* · *"It needs feature parity with Effect schemas, like allowing custom
transformations, etc."*

**Status:** research. It designs and it argues; it does **not** decide. §0 lists the twelve
decisions that are the owner's, numbered **K1**–**K12**.

**The constraints the owner set, and they bind every line below.** No code generation tools. No
macros. No powerful type-system features — **no higher-kinded types, no type classes, no computing
a type from a value**. beni stays a simple Elm-family language.

**How it was built.** Effect v4's [`SCHEMA.md`](../../../references/effect/packages/effect/SCHEMA.md)
(7 358 lines) was read whole, as the feature inventory; `migration/schema.md`, `ARBITRARY.md` and
`OPTIC.md` were skimmed only as far as they show what is derived *from* a schema. Effect's
implementation was deliberately not read. Every beni sample that is **not** marked `[proposed]` was
parse- and type-checked with the installed `./zig-out/bin/beni` and, where it matters, built and
read back as emitted JavaScript; the transcripts are quoted where a claim rests on one (§3.9,
§4.7). The model for how a new syntax is added is [report 28](28-jsx-in-beni.md) §0: sugar over a
plain library form, the plain form stays, the vocabulary belongs to a library and not to the
compiler, and the cost is estimated per compiler phase.

**Vocabulary, once, in plain words.** A **schema** is one value that says three things about a type
at the same time: what it looks like *on the wire* (in a JSON payload, a form submission, a
`localStorage` entry), what it looks like *in the program*, and how to get from either to the
other. **Reading** turns a wire value into a program value and can fail. **Writing** turns a
program value into a wire value and cannot. A **wire key** is the name a field has on the wire,
which need not be the name it has in the program: `user_name` on the wire, `name` in the program.

---

## 0. The design in two pages

### 0.1 What you write, and what you get

Two layers, exactly as JSX is two layers in report 28.

**Layer 1 is an ordinary beni library**, `core/Schema`. A `Schema a` is a value you build by
calling functions. It holds three things: an inspectable description of the wire shape, a reader
and a writer. Nothing in layer 1 is new language — every signature in §3 was checked against
`language.md` as it stands today.

**Layer 2 is one new declaration**, `schema`, which the compiler understands. It produces the
program type *and* its schema from one place, and desugars into layer-1 calls with no residue — so
there is one semantics, one optimiser and one set of diagnostics, which is report 28 §10's answer
to "two ways to write the same thing".

Five examples. `[proposed]` marks the declaration syntax; everything else is beni today.

**(1) A record whose wire shape is not its program shape.**

```elm
-- [proposed]
pub schema User =
    { name : String as "user_name"
    , createdAt : Date via Date.millis
    , age : Int default 0
    , email : Maybe Email
    }
```

You get the type `User`, a reader that accepts
`{"user_name":"ada","createdAt":1700000000000}`, and a writer that produces it again. `age` is `0`
when the key is absent. `email` is `Nothing` when the key is absent *or* `null`, and is written
only when it is `Just`.

**(2) A custom type with a discriminator and per-variant wire names.**

```elm
-- [proposed]
pub schema Shape tagged "kind" of
      Circle { radius : Float } as "circle"
    | Rect { w : Float, h : Float } as "rect"
```

`{"kind":"circle","radius":2}` reads as `Circle { radius = 2 }`.

**(3) A validated type owns its own schema**, so bad input can never produce an invalid value.
`Email`'s constructor is private to its module and the only route in is `fromString`, so a reader
that produces an `Email` ran the check — report 31 §4.2's live Roc bug cannot happen here, because
there is no structural path past the constructor (K3). Full listing in §5.3; the schema is one
line:

```elm
pub schema : () -> Schema Email
schema () =
    Schema.tried Schema.string fromString toString
```

**(4) A generic container, with its element's schema arriving through a `where` clause.** This is
the hand-written layer-1 form of what `schema Page a = { … }` generates, and it compiles today:
`a.schema ()` is [`static-dispatch-spike.md`](../static-dispatch-spike.md) §4's return-type
dispatch and the evidence arrives as a hidden leading parameter (§3.9 has the emitted JavaScript).

```elm
pub type alias Page a =
    { items : List a
    , next : Maybe String
    }


pub schema : () -> Schema (Page a)
    where a.schema : () -> Schema a
schema () =
    Schema.object
        |> Schema.field "items" (Schema.list (a.schema ()))
        |> Schema.optionalField "next" Schema.string
        |> Schema.build
            (\( ( (), i ), n ) -> { items = i, next = n })
            (\p -> ( ( (), p.items ), p.next ))
```

**(5) Running one.**

```elm
pub load : String -> Result (List Schema.Issue) (Page Money)
load text =
    Schema.parse (Page.schema ()) text
```

### 0.2 The three findings that shape everything else

**Finding 1 — the wire side must not be a beni type parameter.** `Schema wire a` reads well until
you write the wire type of a record: the wire side of `{ name : String, createdAt : Date }` is
`{ user_name : String, createdAt : Int }`, and producing that type from the first is a *mapped
type*, which the owner's constraints forbid and beni does not have. The same wall stands at a
tagged union, where each variant's payload has a different wire type and a list's members must be
one type (§3.5). So the wire side is **described by the value and typed as one ordinary type**,
`Schema.Value`, a small JSON-shaped tree. The *information* the owner asked for is all there; only
the type parameter goes (**K1**, argued in full in §3.2).

**Finding 2 — every schema must be a function, not a constant.** Two independent reasons, both
demonstrated against the live compiler:

- a recursive type's schema names itself, and a top-level *value* reachable from its own
  initialiser is `cyclic_value` (`language.md` §7); a top-level *function* may recurse freely;
- a generic type's schema needs evidence, and spike §8.1 makes evidence a *leading parameter*, so a
  zero-parameter declaration with evidence has to become a function — which §8.1 says the checker
  refuses first and which it does not in fact refuse for an *annotated* declaration (§3.9 has the
  resulting exit-0 miscompile, a `master` defect independent of this report).

So the shape is `schema : () -> Schema T`, uniformly (**K2**). Not a workaround: it is the same
precaution `Dict.empty : () -> Dict k v` was written as during the static-dispatch spike (A.8), and
uniformity is what lets one clause, `where a.schema : () -> Schema a`, serve every type.

**Finding 3 — record schemas are built by name with no language feature at all.** This is the crux
the brief names. The answer is a left-nested accumulator: `Schema.object` is the empty record,
`Schema.field` adds one, `Schema.build` closes it with a pair of functions between the accumulator
and the record. §3.4 evaluates the three candidates and §3.4.1 says why the rescript-schema builder
is not available. The chain type-checks today, pipe-first, with no arity family and no cap:

```elm
Schema.object
    |> Schema.field "user_name" Schema.string
    |> Schema.field "age" Schema.int
    |> Schema.build
        (\( ( (), n ), a ) -> { name = n, age = a })
        (\u -> ( ( (), u.name ), u.age ))
```

The one seam where a hand-written call can still go wrong is that pair of functions. That is
elm-codec's field-order bug surviving in one place instead of everywhere — and the `schema`
declaration removes it, because the compiler writes the field list and both functions from one
source. **That is the argument for layer 2 that is about a guarantee and not about keystrokes.**

### 0.3 The twelve decisions that are the owner's

Each gives an example, the options, a recommendation, whether it is reversible, and — where
something is refused — the CLAUDE.md rule 7 check: *what guarantee does the refusal buy, and what
is the escape hatch?*

**K1 — Is the wire side a beni type parameter?** `Schema wire a`, or `Schema a` with the wire
described by the value.
*Options:* (a) `Schema wire a`; (b) `Schema a` plus an inspectable `Node` and one `Value` type.
*Recommend* **(b)**: (a) cannot type a record's wire side without mapped types, cannot type a
union's members at all, and doubles every signature. *Reversible:* not cheaply — it is the
library's central type. *Rule 7:* nothing refused; everything (a) can say, `describe` says.

**K2 — Is a schema a value or a nullary function?** `pub schema : Schema User` or
`pub schema : () -> Schema User`.
*Options:* (a) a value, with functions only where a `where` clause is needed; (b) a nullary
function, always. *Recommend* **(b)**, on Finding 2: (a) is refused for recursive types and
miscompiles for generic ones, and a mixed rule would make the well-known method's type differ per
type, so `where a.schema` could not be written once. *Reversible:* yes, if `constrained_constant`
is extended to annotated declarations **and** a compiler-inserted thunk is added for recursive
ones — two checker changes, not a design change. *Rule 7:* the cost is one `()` per use and a
rebuilt schema value per call; §8.3 prices the rebuild.

**K3 — Does every type get a `schema` automatically, the way it gets `eq`?** Does `Point.schema`
exist for `pub type alias Point = { x : Float, y : Float }` without being asked for?
*Options:* (a) yes, derived structurally like `eq`/`compare`; (b) no, but `schema Point` with no
body asks for the structural one in one line; (c) no, always write it out.
*Recommend* **(b)**. Against (a), three reasons, the first a guarantee: **a validated type must not
get one** — a structural default peels `Email` to `String` and wraps unchecked, which is exactly
the Roc defect of report 31 §4.2, and there it was a runtime panic; `eq` has one correct answer
where a wire format has many, and a default one silently becomes a published API contract that a
field rename changes with no diagnostic; and Roc took (b) after shipping derivation (report 31
§3.2). *Reversible:* yes — (b) → (a) is a relaxation. *Rule 7:* (b) refuses nothing; the hatch is
one line, and the missing-schema diagnostic already exists and already names the fix (§4.5).

**K4 — Does the `schema` declaration declare the type too?** `pub schema User = { name : String as
"user_name" }`, versus a `type alias` plus a schema that names the fields again.
*Options:* (a) one declaration produces both; (b) the schema annotates an existing type; (c)
annotations go on the `type alias` itself. *Recommend* **(a)**, the owner's sketch: (b) writes
every field name twice and invites drift; (c) puts wire vocabulary inside a type declaration, which
is Scala's XML mistake one scope down (§9). A type you already have, or a *second* wire form for
one, is written with layer 1 — the plain form rule 7 requires to stay, exercised in §5.8.
*Reversible:* yes. *Rule 7:* nothing refused.

**K5 — Can writing fail?** `write : Schema a, a -> Value`, or `… -> Result (List Issue) Value`.
*Options:* (a) total; (b) fallible, as Effect's encoding is. *Recommend* **(a)**: it is a guarantee
— *a value you hold can always be serialised* — and without it every caller that only writes still
pays a `Result`. *Reversible:* not cheaply; it is in every signature. *Rule 7:* what is refused is
a conversion whose *writing* direction can fail, which says the program type admits values the wire
cannot represent — a gap in the type, whose honest fix is to make those values unconstructible.
Honest limitation: someone who genuinely wants a fallible writer must widen the wire schema so the
reader refuses what the writer emitted, which is worse. **Flag this as the decision most likely to
want revisiting.**

**K6 — JSON only, or format-neutral?** *Options:* (a) `Schema` reads and writes JSON text; (b) one
`Value` tree, with JSON text, a port payload, form data and query strings as *adapters* into it.
*Recommend* **(b)**: Effect reached the same shape from the other end and needed four canonical
codecs to do it; one `Value` plus adapters is the same coverage with one concept, and it is what
lets a form builder and a query-string reader exist without a second library. *Reversible:* yes.
*Rule 7:* nothing refused.

**K7 — Does `core` ship `Schema`, and is JSON text parsing `foreign`?** *Options:* (a) a platform
concern; (b) `core/Schema.beni` plus a `foreign` JSON pair in core. *Recommend* **(b)**. Report 31
§7 question 6 asks this and nothing settles it; three things do now. The well-known table (§4.5)
must answer `schema` for `Int`, `String`, `List a`, and can only point at core. Rule 6 says only
core may write `foreign`, so if core does not ship `JSON.parse` nobody can — the `Int32` argument
exactly. And a hand-written parser is a real cost against a native one. `core/Json.js` wraps
`JSON.parse` in `try`/`catch` and returns a `Result`, per [`boundary.md`](../boundary.md) §4.1.
*Reversible:* the module's location, yes; the `foreign`, no. *Rule 7:* nothing refused.

**K8 — Are ports re-specified on top of this?** *Options:* (a) keep
[`boundary.md`](../boundary.md) §3.1's port codec generator as a second mechanism; (b) a port's
payload type is one whose `schema` resolves, and the generator is deleted. *Recommend* **(b), but
not in the first slice**: one admitted set instead of two, one depth bound instead of two, and a
port payload gains renames, defaults and tagged unions for nothing — conditional on a measurement,
because a port hands JavaScript straight across today and routing it through a `Value` tree costs
an allocation per message (§8.5). *Reversible:* yes; deleting the generator is the last step.
*Rule 7:* §3.1's refusals become "this type has no `schema`", the same set with a better message.

**K9 — Is a `User.Wire` type generated?** *Options:* (a) also emit
`pub type alias User.Wire = { user_name : String, … }`; (b) no wire type, and `describe` returns a
`Node`. *Recommend* **(b)**. Ask who needs it: a caller who wants the wire shape wants it as
*data* (a JSON Schema, a form, a fixture) and `Node` is that; a caller who wants it as a *type*
wants to hand-build a wire value, which is writing the payload twice and is what the schema exists
to prevent. Generating it also forces a name into a second namespace and makes a module's interface
depend on its schema bodies. *Reversible:* yes, additively. *Rule 7:* nothing refused — the plain
form can always declare its own record type and a schema between the two.

**K10 — May a transformation perform an effect while reading?** e.g.
`Schema.tried Schema.string Users.lookup Users.idOf`.
*Options:* (a) yes, once the effects work lands; (b) never — reading is pure and enrichment is a
pass after reading. *Recommend* **(a) conditionally**, and the condition is a question the effects
spec has not answered:
[`transparent-effects-proposal.md`](../transparent-effects-proposal.md) §1 makes `suspends` part of
a function's *type*, and a `Schema a` stores its reader in a **field**, not a parameter — §2's
bit-polymorphism promise covers higher-order *parameters* and does not discuss fields. Until that
has a position, layer 1 is sync-only and enrichment is a pass over the decoded value, which is (b)
and loses one traversal. *Reversible:* yes, additively either way. *Rule 7:* (b) as an interim
withholds an Effect capability and says so. §3.7 has the detail, §5.7 argues the recommendation does
not change when the question is answered, and §10 carries it as the main could-not-determine.

**K11 — What does a wire number past 2⁵³ do?** `Schema.parse Schema.int "9007199254740993"` reads
back as 9007199254740992 — a silent wrong answer, the class rule 7 exists to refuse. Report 31 §4.3
asks this and nothing answers it. *Options:* (a) accept it, as `JSON.parse` does; (b) refuse a wire
number outside ±(2⁵³−1) with an ordinary `Refused` issue; (c) a compile-time diagnostic.
*Recommend* **(b)**: (c) is not available because the offending value is data, not a type, and (a)
is the silent wrong answer. The program gets a `Result` it already handles, and the two hatches are
`Int32` (`language.md` §2.5) and a `Schema.bigText` that keeps the digits as a `String`.
*Reversible:* yes. *Rule 7:* the refusal buys "no silent wrong answer at the boundary" and both
hatches are named in the message.

**K12 — What happens to a wire key the schema does not mention?** *Options:* ignore (Effect's and
Elm's default), reject, preserve. *Recommend* **ignore by default**, `Reject` available in
`Options`, preserve **not** offered — a beni record is closed, so preserving means a
`List ( String, Value )` field, which the author declares when they want it and which nothing can
add behind their back. *Reversible:* yes. *Rule 7:* preserve is refused because there is nowhere to
put values the type does not already mention; the hatch is one declared field.

---

## 1. What "parity" means here

**Parity means every capability in `SCHEMA.md` is answered.** §2 walks the document section by
section and gives each capability one of five answers — **same** (beni does it, spelled much as
Effect does), **different** (beni does it, spelled differently; the row shows the spelling),
**not needed** (the capability exists because of JavaScript or TypeScript and has no beni
referent), **cannot** (not expressible under the owner's constraints; the row says what is lost),
**help** (needs something from the language; the row says what) — and says where it lives: **D**
the `schema` declaration, **L** the library, **B** both, **—** nowhere.

**The counts. 162 rows: same 40, different 67, not needed 39, cannot 14, needs language help 2.**
The sixteen non-routine rows are collected in §2.15 so they can be read without the table, together
with the seven things the *compiler* must supply or the owner must decide, which are a different
list and are numbered **H1**–**H7**.

---

## 2. The Effect feature inventory, and beni's answer to each

### 2.1 Elementary schemas (`SCHEMA.md` *Defining Elementary Schemas*, L200–L486)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 1 | `Schema.String` / `Number` / `Boolean` (L204) | the basic wire types | **same** — `Schema.string`, `Schema.float`, `Schema.bool`; plus `Schema.int` because beni distinguishes them | L |
| 2 | `Schema.BigInt` (L369) | integers past 2⁵³ | **different** — `Schema.bigText`, which keeps the digits as a `String`; beni has no bigint type (K11) | L |
| 3 | `Schema.Symbol` (L217) | JavaScript symbols | **not needed** — no such value in beni | — |
| 4 | `Schema.Undefined` / `Null` / `Void` (L264) | the three empties | **different** — one `Schema.null` for the wire's `null`; `undefined` and `void` have no beni referent | L |
| 5 | coercion via `decodeTo(String, Getter.String())` (L221) | turn anything into a string | **different** — an explicit `Schema.tried`; beni will not guess, because a coercion that always succeeds hides the case it should have reported | L |
| 6 | `Schema.Literal("tuna")` (L243) | this exact value and no other | **different** — `Schema.literal "tuna" : Schema ()`; there are no literal *types* in beni, so a literal schema carries no information into the program and exists to constrain the wire | L |
| 7 | `Schema.Literals([…])` (L274) | a closed set of strings | **different** — `Schema.enumerated : List ( String, a ) -> Schema a`, which maps wire strings onto a beni custom type's constructors, exhaustively | B |
| 8 | `Schema.UniqueSymbol` (L256) | a symbol literal | **not needed** | — |
| 9 | `.literals` / `.members` accessors (L282) | read the set back out | **different** — `Schema.describe` returns a `Node`, and `ChoiceNode` carries the tags | L |
| 10 | `.check(isMinLength …)` and the eight other string checks (L296) | constrain a string | **same** — `Schema.checked`, plus the same named checks as library values | L |
| 11 | `SchemaTransformation.trim()` / `toLowerCase` / `toUpperCase` (L314) | normalise on read | **same** — `Schema.trimmed`, `Schema.lowercased`, `Schema.uppercased` | L |
| 12 | `isUUID` / `isBase64` / `isBase64Url` (L324) | common string formats | **same** — the same names as checks | L |
| 13 | number checks `isBetween`/`isGreaterThan`/… (L336) | constrain a number | **same** | L |
| 14 | `Schema.Finite` (L341) | not NaN, not infinity | **same** — `Schema.finite`; note the well-known table already records that `Float`'s `compare` is not a total order on NaN (spike §3.2) | L |
| 15 | `isInt()` / `isInt32()` (L358) | whole numbers | **different** — `Schema.int` is a schema, not a check, because beni's `Int` is a type; `Schema.int32 : Schema Int32` for the 32-bit one | L |
| 16 | BigInt filter factories `makeIsBetween(order)` (L369) | build checks for an ordered type | **different** — one generic `Schema.between : Schema a, a, a -> Schema a where a.compare : a, a -> Order`; static dispatch makes the `order` argument unnecessary | L |
| 17 | `Schema.Date` (L405) | a valid `Date` | **different** — `Date` is a platform type, and its schema is a `via` conversion the platform package declares (`Date.millis`, `Date.iso8601`) | B |
| 18 | `Schema.TemplateLiteral` (L410) | `${string}@${string}` as a *type* | **cannot** — beni has no literal or template types. Lost: the compile-time guarantee that a string matches a shape. Mitigation: a validated type (`Email`) whose constructor runs the check, which is strictly stronger at run time and weaker at compile time | — |
| 19 | `Schema.TemplateLiteralParser` (L452) | split a string into typed parts | **different** — an ordinary `Schema.tried` over `String.split`; §5.6's `Money` is exactly this | L |

### 2.2 Structs — shape, optionality, defaults (L492–L991)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 20 | `Schema.Struct({…})` (L492) | an object with known keys | **different** — `schema T = { … }`, desugaring to `object`/`field`/`build` (§3.4) | B |
| 21 | `optionalKey` (L496) | the key may be absent | **different** — `Maybe a` in the declaration (K12 note in §4.3) | B |
| 22 | `mutableKey` (L496) | the field is writable | **not needed** — beni has no mutability | — |
| 23 | `optional` (absent **or** `undefined`) (L525) | TypeScript's other optionality | **not needed** — beni has no `undefined`; the wire distinction that survives is absent-vs-`null`, which row 21 and row 24 cover | — |
| 24 | `NullOr` (L525) | the value may be `null` | **different** — folded into `Maybe`: one field rule accepts absent **or** `null` and writes the key only when `Just` (§4.3). Effect's 4×2 matrix of `optionalKey`/`optional`/`NullOr` collapses to three combinators because beni has `Maybe` and no `undefined` | B |
| 25 | omitting a value when transforming an optional field (L564) | drop `undefined` from the output | **not needed** — same reason | — |
| 26 | `optionalKey(Schema.Never)` (L597) | a key that may appear but never has a value | **not needed** — a TypeScript type-level trick | — |
| 27 | `withDecodingDefault*`, four APIs (L623) | substitute a value when the key is missing | **different** — one `default e` annotation; the four APIs are (key-absent vs also-`undefined`) × (wire-side vs program-side default), and beni has neither axis: there is no `undefined`, and `default` is always written in the **program** type because that is what the field's declared type is | B |
| 28 | nested decoding defaults (L716) | a default inside a default | **same** — falls out; a nested `schema` is an ordinary field | B |
| 29 | manual decoding defaults via `decodeTo` (L765) | a fallback rule more specific than "missing" | **different** — `Schema.recovered : Schema a, (List Issue -> Maybe a) -> Schema a` | L |
| 30 | `OptionFromOptionalKey` and its two siblings (L855) | optional field as an `Option` | **same** — this *is* beni's only spelling; `Maybe` is not an alternative to absence, it is how absence is represented | B |
| 31 | `annotateKey({description, messageMissingKey})` (L993) | document one key, and name its missing-key error | **different** — `-- |` doc comments on a declaration field feed `NamedNode`; a custom missing-key message is `Schema.expecting` in layer 1 | B |
| 32 | `messageUnexpectedKey` (L1018) | custom message for an excess key | **different** — a field of `Options`, not an annotation, because it is one message per build and not per schema | L |
| 33 | `onExcessProperty: ignore \| error` (L1039) | what to do with keys nobody claimed | **same** — `Options.unknown = Ignore \| Reject` (K12) | L |
| 34 | `StructWithRest` / index signatures (L1046) | fixed keys plus any others | **different** — a declared field of type `List ( String, Value )` with `Schema.rest`; beni records are closed, so the catch-all has to be somewhere the type can see it | B |
| 35 | `encodeKeys({userId: "user_id"})` (L1108) | rename keys on the wire only | **different** — `as "user_id"` on the field. This is the single most-wanted row in report 31 §4.1 | D |
| 36 | reusing fields by spreading `.fields` (L1140) | share a group of fields between types | **different** — a nested record field (`meta : Timestamps`), or write the group out. See row 37 | B |
| 37 | `mapFields(Struct.pick([…]))` (L1189) | a new schema keeping some fields | **cannot** — the result's decoded type is a record type nobody declared, and beni cannot compute a type from a type. Lost: deriving `UserSummary` from `User` mechanically. Mitigation: declare the second type and its schema; §4.8 sketches a later `schema B from A` sugar that copies *annotations* (syntax, not types) | — |
| 38 | `Struct.omit` (L1213) | as above, dropping fields | **cannot**, same reason | — |
| 39 | `Struct.assign` / `fieldsAssign` (L1233) | add fields to a struct schema | **cannot**, same reason | — |
| 40 | `unsafePreserveChecks` (L1265) | keep whole-struct filters across a field map | **not needed** — rows 37–39 do not exist | — |
| 41 | `Struct.evolve` (L1295) | change one field's schema | **cannot** — and `Schema.atField : Schema a, String, (Schema x -> Schema x) -> Schema a` cannot be typed either, because `x` is not known | — |
| 42 | `Struct.map(optionalKey)` — "partial" (L1320) | every field optional | **cannot**; this is `Partial<T>`, the mapped type. Lost: a PATCH-request schema derived from a resource schema. Mitigation: declare the patch type, whose fields are `Maybe`, and the two schemas side by side | — |
| 43 | `Struct.mapPick` / `mapOmit` (L1343) | the same over a subset | **cannot**, same reason | — |
| 44 | `Struct.evolveKeys` / `renameKeys` (L1385, L1412) | rename the *program* field names | **cannot** — again a computed record type. Note this is not row 35: that renames the wire, which beni does with `as` | — |
| 45 | `Struct.evolveEntries` (L1435) | rename key and change schema together | **cannot**, same reason | — |
| 46 | `TaggedStruct("A", …)` / `Schema.tag` (L1487) | a struct carrying a discriminator | **different** — the discriminator belongs to the *union* (`tagged "kind"`), because in beni the tag is the constructor and does not exist as a field of the program value | D |

### 2.3 Tuples, arrays, dictionaries (L1518–L1929)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 47 | `Schema.Tuple([A, B])` (L1518) | fixed-length heterogeneous array | **different** — `Schema.pair`, `Schema.triple`; beni tuples are arity ≥ 2 and unbounded in the language but a schema family must stop somewhere. Recommend 2 and 3, and a record past that, which is also what `language.md` §6.4 encourages | L |
| 48 | `TupleWithRest` (L1522) | fixed head, then more | **different** — `Schema.pair a (Schema.list b)` | L |
| 49 | element `annotateKey` (L1547) | document / name a position | **different** — positions are named by index in an `Issue`'s path | L |
| 50 | `mapElements` with `Tuple.pick`/`omit`/`append`/`evolve`/`map`/`renameIndices` (L1572–L1711) | derive a tuple schema from another | **cannot** — computed tuple types. Lost: mechanical tuple surgery, which is rare | — |
| 51 | `Schema.Array(item)` (L1753) | a homogeneous list | **same** — `Schema.list` | L |
| 52 | `Schema.mutable` on arrays (L1757) | writable arrays | **not needed** | — |
| 53 | `Schema.UniqueArray` (L1765) | no duplicates | **different** — `Schema.checked s "no duplicates" (…)`, and beni's derived `eq` supplies the comparison for free (spike §9), where Effect has to build an `Equivalence` first | L |
| 54 | `Schema.Record(key, value)` (L1780) | a dictionary with dynamic keys | **different** — `Schema.dict : Schema a -> Schema (List ( String, a ))`, plus `Schema.dictInto : Schema a -> Schema (Dict String a)` when an ordered map is wanted | L |
| 55 | record key transformations (`snakeToCamel`) (L1786) | rewrite dynamic keys | **different** — `Schema.dictKeys : Schema (List ( String, a )), (String -> String), (String -> String) -> …`. Effect's duplicate-key rule (last write wins, completion order under concurrency) becomes a stated rule: **beni keeps the first** and reports the collision as an `Issue`, because "last one wins" is a silent wrong answer | L |
| 56 | number keys (L1823) | `{1: "a"}` | **different** — the key schema is a conversion; keys are strings on the wire in every format | L |
| 57 | literal struct from `Record(Literals, v)` (L1871) | a fixed key set from a union | **not needed** — that is a record, which beni declares directly | — |

### 2.4 Unions (L1931–L2233)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 58 | `Schema.Union([A, B])`, first match wins (L1931) | a value that is one of several shapes | **different** — `Schema.oneOf : List (Attempt a) -> Schema a`, where an `Attempt` pairs a schema with a constructor of the *one* beni type the union decodes into. TypeScript's structural union has no beni referent; a beni union is a declared custom type | B |
| 59 | excluding incompatible members / one message (L1939) | a readable error for a failed union | **same** — the `Issue` list names the tag key and the tags it knows (§3.6) | L |
| 60 | exclusive union `{mode: "oneOf"}` (L1980) | exactly one member may match | **different** — `Schema.exactlyOneOf`, same list, different rule. Cheap, so worth having | L |
| 61 | `Union.mapMembers` (L1997) | derive a union schema | **cannot** — computed union type | — |
| 62 | union of literals (L2068) | a closed string set | **different** — row 7's `Schema.enumerated` | B |
| 63 | `Schema.TaggedUnion({A: {…}})` (L2108) | discriminated union with `_tag` | **different** — `schema T tagged "kind" = …`; the discriminator key is named because real APIs use `type`, `kind`, `op`, not `_tag` | D |
| 64 | `toTaggedUnion` with `cases` / `discriminants` / `isAnyOf` / `guards` / `match` (L2135) | work with the variants after the fact | **not needed** — `case` is the matcher, the compiler proves it exhaustive (`checker.md` §6.6), and pattern matching is not a library feature in beni | — |

### 2.5 Recursion (L2235–L2313)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 65 | `Schema.suspend(() => Category)` (L2235) | a schema that refers to itself | **same** — `Schema.deferred : (() -> Schema a) -> Schema a`, and because of K2 the argument is the schema function itself: `Schema.deferred commentSchema`. Effect needs `suspend` for TypeScript's sake; beni needs it because `language.md` §7 refuses a cyclic top-level *value* — a different reason for the same combinator (§5.5) | L |

### 2.6 Declaring custom types (L2315–L2521)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 66 | `Schema.declare(isX)` (L2319) | teach Schema a type it cannot see into | **different** — `Schema.custom : Node, Reader a, (a -> Value) -> Schema a`. There is no type guard, because beni has no `unknown` to guard against: the only untyped input is `Value` | L |
| 67 | `expected: "URL"` annotation (L2351) | a readable name in the error | **same** — `Schema.expecting : Schema a, String -> Schema a` | L |
| 68 | `toCodecJson` annotation + `Schema.link` (L2371) | give an opaque type a JSON form | **not needed** — every beni schema *is* its own wire description; there is no "opaque type with no wire form" to bridge to | — |
| 69 | `Schema.declareConstructor` (parametric) (L2440) | a schema factory for `Box<A>` | **different** — an ordinary function `boxSchema : () -> Schema (Box a) where a.schema : () -> Schema a`. Effect's curried two-step call exists to fix TypeScript's inference; beni's `where` clause does the same job in the annotation (§5.4) | L |
| 70 | `Schema.instanceOf(URL)` (L2349) | shorthand for a class guard | **not needed** — no classes | — |

### 2.7 Validation — filters and refinements (L2523–L2919)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 71 | `.check(makeFilter(p))` (L2523) | reject values the type admits | **same** — `Schema.checked : Schema a, String, (a -> Bool) -> Schema a` | L |
| 72 | filter `title` / `description` / `message` (L2543) | say what failed | **different** — one `String` message, because `title`/`description`/`message` is a three-way split beni has no reader for | L |
| 73 | the identifier-vs-`expected`-vs-`message` precedence rule (L2562) | which label a formatter shows | **not needed** — one message, no precedence to specify | — |
| 74 | filter return shapes: `true`/`false`/`string`/`Issue`/`{path,issue}`/array (L2591) | rich failures from one predicate | **different** — two functions instead of six shapes: `Schema.checked` (a `Bool`) and `Schema.judged : Schema a, (a -> List Issue) -> Schema a` (an empty list is success). Row 74's `{path,issue}` case — "password and confirmPassword must match" *at* `["password"]` — is what `judged` exists for | L |
| 75 | schema type preserved after filtering (L2643) | `.fields` still reachable after `.check` | **not needed** — beni has no method-carrying schema type; `describe` reads through checks | — |
| 76 | filters as first-class, reusable across types (L2682) | `isMinLength` on strings *and* arrays | **different** — `isMinLength` is structural polymorphism over "anything with a length", which beni cannot say; it gets `String.length` and `List.length` checks separately, or one check over a `where a.length : a -> Int` clause, which is the static-dispatch answer | L |
| 77 | `{errors: "all"}` (L2726) | collect every failure | **same** — `Options.report = AllOf \| FirstOnly` | L |
| 78 | `.abort()` on a filter (L2750) | stop after this one fails | **different** — `Schema.abortingCheck`, same idea | L |
| 79 | `makeFilterGroup` (L2774) | a reusable bundle of checks | **different** — an ordinary function `Schema a -> Schema a`; beni composes functions, so a "group" needs no type | L |
| 80 | `Schema.refine` (L2794) | narrow the *type* as well as the value | **cannot** — `arr is [string, string, ...string[]]` is a type computed from a predicate. Lost: `NonEmptyList` falling out of a check. Mitigation: declare `type NonEmpty a = NonEmpty a (List a)` and give it a schema; the check then lives in its constructor, which is beni's validated-type pattern and is stronger | — |
| 81 | `Schema.brand("UserId")` (L2810) | two types that are both strings but must not mix | **different** — `pub opaque type UserId = UserId String` is a real nominal type, and a real one is better than a phantom one: it cannot be erased by a cast. Cost: one constructor allocation per value, where Effect's brand is free. Honest, and §8.3 prices it | B |
| 82 | structural filters and their ordering rule (L2824) | "run length checks only after the items parsed" | **same** — the same rule, and it must be stated: a check on a record runs only if every field read (§3.6) | L |
| 83 | effectful filters (`Getter.checkEffect`) (L2855) | validate against a service | **help** — K10; the bit-in-a-field question | L |
| 84 | filter factories (L2893) | parameterised checks | **same** — an ordinary function returning a function | L |

### 2.8 Constructors (L2921–L3147)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 85 | `schema.make(input)`, throws (L2921) | build a validated value in memory | **not needed** — beni does not throw; a record literal is the constructor, and a *validated* type's constructor is its module's `fromString`-shaped function returning `Result` | — |
| 86 | `makeOption` (L2925) | the non-throwing form | **same** — that *is* the beni form: `Email.fromString : String -> Result String Email` | — |
| 87 | `make` on unions and composed schemas (L2947) | construct through any schema | **not needed** — constructors are the language's | — |
| 88 | branded constructors (L2960) | `make` returns the branded type | **not needed** — row 81's opaque type has a real constructor | — |
| 89 | refined constructors (L2995) | `make` returns the refined type | **not needed** — row 80 | — |
| 90 | `withConstructorDefault` (L3030) | a default at construction, not at decoding | **different** — a `pub defaults : User` value in the module, and `{ User.defaults | name = "ada" }`. This is report 28 §7's answer to the same question for component props, and it needs nothing new | L |
| 91 | nested constructor defaults (L3070) | defaults inside defaults | **different** — nested record update | L |
| 92 | effectful constructor defaults, from a service (L3091) | a default that reads config | **different** — an ordinary function `User.blank : Config -> User`; a default that performs is not a default | L |

### 2.9 Transformations (L3149–L3603)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 93 | transformations are first-class reusable values (L3153) | define `trim` once, use everywhere | **different** — `pub type alias Via b a = { from : b -> Result String a, to : a -> b }`, an ordinary record. This is what `via` takes (§4.4) | B |
| 94 | `Transformation<T,E,RD,RE>` and five `Getter` kinds (L3197) | the transformation type | **different** — one `Via`. Effect's `TransformOptional` exists for `undefined`; `TransformEffect` is K10; `Passthrough` is `identity` | L |
| 95 | `composeTransformation` (L3245) | chain two conversions | **different** — `Schema.viaThen : Via b a, Via c b -> Via c a`, or just compose the functions by naming the argument (`language.md` §0 removed `>>`) | L |
| 96 | `decodeTo(target, transformation)` (L3279) | read into a *different* schema | **different** — `Schema.mapped : Schema b, (b -> a), (a -> b) -> Schema a` | L |
| 97 | `decode(transformation)` (L3310) | same type, transformed | **different** — `Schema.mapped` with the same type | L |
| 98 | inline `transform({decode, encode})` (L3325) | a one-off total conversion | **same** — `Schema.mapped` | L |
| 99 | `transformEffect` — fallible or async (L3349) | a conversion that can fail | **help** — the fallible half is `Schema.tried : Schema b, (b -> Result String a), (a -> b) -> Schema a`, reading may fail and writing may not (K5); the **async** half is K10, which is why this row is not simply `different` | L |
| 100 | schema composition by chaining `decodeTo` (L3373) | metres → kilometres → miles | **same** — `Schema.mapped` over a `Schema.mapped` | L |
| 101 | `passthrough` / `passthroughSubtype` / `passthroughSupertype` (L3405) | compose when the two sides nearly line up | **not needed** — all three exist to negotiate TypeScript subtyping; beni unifies or it does not | — |
| 102 | `{strict: false}` (L3464) | turn the above off | **not needed** | — |
| 103 | `transformOptional` (L3487) | a conversion that may produce no value | **different** — the `Maybe` field combinators (row 24) cover the cases that survive | L |
| 104 | `Getter.omit()` / `tagDefaultOmit` (L3549) | drop a key when writing | **different** — `Schema.omittedWhen : Schema a, (a -> Bool) -> Schema a` as a field modifier; the common case (a tag that is implied) does not arise, because beni's tag is the constructor | L |
| 105 | `Schema.flip(schema)` (L3605) | swap the two directions | **not needed** — its uses are validating the encoding direction (beni's writing is total, K5) and producing an encoding-side JSON Schema (`describe` already returns the wire side, §6) | — |
| 106 | flipped constructors (L3659) | build an encoded value | **not needed** — K9; nobody should be hand-building wire values | — |

### 2.10 Classes and opaque types (L3683–L4629)

Every row here exists because TypeScript has classes. beni's equivalent of "a nominal type with
methods" is a module: [`static-dispatch-spike.md`](../static-dispatch-spike.md) §1.2's module rule
makes a type's methods the `pub` values of the module that declares it, which is the whole of rows
107–122 with no library involvement.

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 107 | `Schema.Opaque<Person>()(Struct)` (L3687) | a distinct type over a struct | **different** — `pub opaque type Person = Person { … }` | — |
| 108 | static methods on an opaque struct (L3773) | attach helpers | **not needed** — module `pub` values | — |
| 109 | annotations and filters on an opaque struct (L3809) | name it in errors | **same** — `Schema.expecting` | L |
| 110 | recursive opaque structs (L3847) | a tree of them | **same** — row 65 | L |
| 111 | branded opaque structs (L3931) | two identical shapes that must not mix | **not needed** — an opaque type already is | — |
| 112 | `class X extends Schema.Struct({…})` (L3988) | hang statics on a schema | **not needed** | — |
| 113 | validating an existing class's constructor args (L4043) | guard a constructor | **not needed** | — |
| 114 | `instanceOf` plus an explicit encoding (L4100) | a schema for a foreign class | **different** — a platform type gets its schema from its own module, like `Date` (row 17) | L |
| 115 | `Schema.Class<A>("A")({…})` (L4233) | prototype-backed instances | **not needed** | — |
| 116 | class-level filters (L4256) | cross-field validation | **same** — `Schema.judged` on the record schema (row 74) | L |
| 117 | branded classes (L4287) | as row 111 | **not needed** | — |
| 118 | class annotations (L4336) | metadata on the type | **different** — doc comments and `Schema.named` | B |
| 119 | `A.extend<B>("B")({…})` (L4357) | subclass with more fields | **not needed** — no inheritance in beni | — |
| 120 | recursive classes (L4413) | as row 110 | **not needed** | — |
| 121 | `TaggedClass` (L4506) | a class with a `_tag` | **different** — a constructor of a custom type | — |
| 122 | `Schema.Error` / `TaggedError` (L4564, L4574) | errors that are schemas | **different** — a beni error is a constructor of a `Result`'s error type, and giving it a schema is an ordinary `schema` declaration. The *useful* half — "send this error over the wire" — falls straight out | B |

### 2.11 Serialisation and formats (L4631–L5245)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 123 | `UnknownFromJsonString` (L4637) | parse JSON text to an untyped value | **same** — `Json.parse : String -> Result String Value`, `foreign` in core (K7) | L |
| 124 | `fromJsonString(schema)` (L4654) | parse and validate in one | **same** — `Schema.parse : Schema a, String -> Result (List Issue) a` | L |
| 125 | `StringFromBase64` / `Base64Url` / `Hex` / `UriComponent` (L4674) | string encodings | **same** — the same four as `Via` values | L |
| 126 | `Uint8ArrayFrom*` (L4744) | the binary variants | **different** — later; beni has no byte array yet; [`boundary.md`](../boundary.md) §6 lists typed arrays as a roadmap capability, and this row is its first customer | L |
| 127 | `fromFormData(schema)` (L4756) | read an HTML form, bracket notation for nesting | **same** — `Form.toValue : FormData -> Value` in the browser platform, then any schema. Effect needs `toCodecStringTree` beside it because its schemas are typed by their encoded side; beni needs nothing extra, because every leaf arriving as `Text` is a property of the *adapter*, and `Schema.int` reading a `Text` is one `tried` | L |
| 128 | `fromURLSearchParams` (L4834) | the same for query strings | **same**, same adapter shape | L |
| 129 | canonical codecs as a concept (L4906) | one schema → many wire formats | **different** — one `Value` and adapters (K6); Effect's four canonical codecs collapse into that | L |
| 130 | `toCodecJson` (L4914) | the JSON one | **not needed** — `Value` *is* the JSON one | — |
| 131 | custom encodings take priority over the default (L5059) | your `Date` form beats the built-in | **same** — a `via` on the field beats the type's own `schema` (§4.4) | D |
| 132 | `toCodecStringTree` (L5094) | everything as strings | **different** — an `Options` flag on the *adapter*, not a second schema | L |
| 133 | `toCodecIso` (L5156) | a lens-friendly plain-object view | **not needed** — beni has no optics library today; see row 141 | — |
| 134 | `toEncoderXml` (L5192) | XML output | **different** — one more adapter over `Value`, written outside core, later | L |

### 2.12 What is derived from a schema (L5247–L6338, `ARBITRARY.md`, `OPTIC.md`)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 135 | `toJsonSchemaDocument` — draft-2020-12 (L5251) | describe the wire for OpenAPI or a validator | **same** — `Node -> Value` in a `schema-json` package; §6 | L |
| 136 | draft-07 conversion (L5320) | older dialect | **same**, a second function | L |
| 137 | `title` / `description` / `default` / `examples` / `readOnly` / `writeOnly` (L5360) | JSON Schema's standard metadata | **different** — `title` and `description` from doc comments and `Schema.named`; `examples` from `Schema.example`; `readOnly`/`writeOnly` have no beni referent and are dropped | B |
| 138 | `annotateEncoded` (L5411) | annotate the wire side, not the program side | **not needed** — `Node` *is* the wire side, so an annotation on a schema lands there already | — |
| 139 | `toEquivalence` (L5727) | derived structural equality | **not needed** — and beni is ahead: `eq` is derived from the **type** by the compiler (spike §9), so it works for values that never came from a schema. Effect must derive it from a schema because TypeScript has no structural equality at run time | — |
| 140 | `overrideToEquivalence` (L5762) | replace the derived one | **same** — declare `pub eq` in the type's module and it wins (spike §3.3 step 1) | — |
| 141 | `toIso` — optics from a schema (L5779) | edit deeply nested data | **not needed** — no optics library today; when there is one, `Node` is what it would read. Worth noting: record update already reaches one level, and `language.md` §6.3 refuses `{ r.a | … }`, so nested update is a real beni gap that optics would answer — see `plans/browser-platform.md` §1.1's "one `let` line" comment | — |
| 142 | `toDifferJsonPatch` (L5839) | RFC 6902 patches for any typed value | **different** — a function over two `Value`s in a `schema-patch` package; it needs `write` and nothing else | L |
| 143 | `SchemaRepresentation` — inspect a schema structurally (L5920) | see what a schema says | **same** — `Schema.describe : Schema a -> Node`, and §6 argues this is why the description must be data | L |
| 144 | `toJson` / `fromJson` of a representation (L6125) | store a schema, send a schema | **same** — `Node -> Value` works; the other direction is row 145 | L |
| 145 | `fromRepresentation` + revivers (L6148) | rebuild a runtime schema from stored JSON | **cannot** — rebuilding yields a `Schema a` whose `a` came from the data, which is computing a type from a value. Lost: schema-over-the-wire, and runtime schema registries. Mitigation: the *description* still travels (row 144) and can be rendered, diffed and validated against; only the typed reader cannot be rebuilt | — |
| 146 | `fromJsonSchemaDocument` — import JSON Schema (L6259) | consume someone's OpenAPI | **cannot** at run time, though available as a tool — an external generator that writes `schema` declarations into a file is not a language feature and is not forbidden; it is the same thing `json2elm` and `swagger-elm` are, and report 31 §2 shows every Elm shop built one. **Difference from Elm: here the generator's output is one declaration per type rather than two hand-maintained functions** | — |
| 147 | `toCodeDocument` — generate source from a schema (L6324) | codegen | **same** — outside the language, as row 146 | — |
| 148 | `Arbitrary.schema` — test data (`ARBITRARY.md` L758) | property-based testing | **different** — `Schema.sample : Schema a, Seed -> ( a, Seed )` over `Node`; report 17 §4.9 already has a seeded PRNG that is `pure`. Shrinking is a later, separate concern | L |
| 149 | `toStandardSchemaV1` (L6411) | interop with other JS validators | **not needed** — a JavaScript ecosystem contract; a platform package could adapt one if it ever mattered | — |

### 2.13 Parse options, errors, middleware (L6340–L6766)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 150 | `concurrency` when parsing products (L6342) | parse fields in parallel | **not needed** — only meaningful with effectful transformations (K10), and even then §3.7 argues against it: reading a product is CPU work | — |
| 151 | `reportInput: true` (L6384) | put the offending value in the message | **same** — an `Options` field, off by default, with the same privacy warning Effect gives. beni can afford it more cheaply: an `Issue` already carries the `Value` it refused, and the *formatter* decides whether to print it | L |
| 152 | formatter hooks — `leafHook`, `checkHook` (L6409) | translate every message in one place | **different** — an `Issue` is an ordinary beni custom type, so "a formatter" is a `case` the application writes, and i18n is `case` over a language. Effect needs a hook mechanism because its issues are opaque; beni's are data | L |
| 153 | inline custom messages on a schema (L6609) | field-specific wording | **same** — the message argument of `Schema.checked`, and `Schema.expecting` | L |
| 154 | `StandardSchemaV1FailureResult` over the wire (L6651) | send validation errors to a client | **same** — `Issue` gets its own `schema`, which is the feature eating its own tail and is a good test of it | B |
| 155 | `catchDecoding(() => fallback)` (L6696) | a default when reading fails | **same** — `Schema.recovered` (row 29) | L |
| 156 | `catchDecodingWithContext` (L6730) | a fallback from a service | **different** — an ordinary function argument; beni has no implicit context | L |
| 157 | `middlewareDecoding` (L6761) | wrap the whole read | **different** — `Schema.around : Schema a, (Reader a -> Reader a) -> Schema a`, one function, which is what a middleware is | L |

### 2.14 Type machinery and tooling (L6768–L7051, L40–L198)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 158 | `resolveAnnotations`, user-extensible annotation keys (L6926) | attach arbitrary metadata | **different** — a closed `Node` with a `NamedNode String Node` and an `ExtraNode String Value` case; open extension by module augmentation is a TypeScript feature | L |
| 159 | `resolveAnnotationsKey` — key-level annotations (L6983) | metadata on a field position | **same** — `ObjectNode` carries a per-field record | L |
| 160 | separate `RD` / `RE` requirement parameters (L7004) | decoding needs a DB, encoding does not | **not needed** under K1; and under K10 it is the same question — beni's two inferred bits are per function, and a reader and a writer are two functions, so the split falls out without being written | — |
| 161 | `Schema.is` / `asserts` type guards (L6170, migration L42) | narrow an `unknown` | **not needed** — there is no `unknown` in beni. `Schema.is : Schema a, Value -> Bool` is one line if anyone wants it | L |
| 162 | JIT / AOT schema compilers (L68) | make parsing fast | **different** — beni compiles ahead of time by construction; the analogue is `--release` turning a schema value into a specialised reader (§8.3), which needs no `new Function` and works where CSP forbids one | — |

### 2.15 The sixteen rows that are not routine

**Cannot, under the owner's constraints (14 rows).** Ten of the fourteen are one thing said ten
ways: **beni cannot compute a type from a type.**

| Row | What | What is lost |
|---|---|---|
| 18 | template-literal *types* | a compile-time guarantee that a string matches a shape; a validated type gives a run-time one instead |
| 37, 38, 39 | `Struct.pick` / `omit` / `assign` | deriving a summary or an extended schema mechanically |
| 41 | `Struct.evolve` | changing one field's schema without rewriting the struct |
| 42, 43 | `partial` / `required` / subset maps | a PATCH-request schema derived from a resource schema — the most valuable of the ten |
| 44, 45 | `renameKeys` / `evolveEntries` (program-side) | mechanical renaming of program field names |
| 50 | tuple surgery | rare |
| 61 | `Union.mapMembers` | rare |
| 80 | `refine` narrowing a type | `NonEmptyList` from a predicate; a declared type with a checked constructor is stronger |
| 145 | rebuilding a schema from stored JSON | schema-over-the-wire and runtime registries; the *description* still travels |
| 146 | importing a JSON Schema at run time | nothing, if an external generator writes `schema` declarations instead — which is what every Elm shop already built (report 31 §2) |

**Needs language help (2 rows).** Row **83** (effectful filters) and row **99** (asynchronous
transformations), both blocked on the same question, **H4**.

The mitigation for the ten type-computation rows is the same and is honest rather than clever:
**declare the second type and its schema.** §4.8 sketches a later `schema Summary from User = …`
that copies *annotations* from another declaration — syntax over syntax, not a type computation, so
it is available if the duplication proves painful. It is deliberately not in this design.

**What the compiler must supply, or the owner decide (7).** A different list from the two above:
these are not capabilities, they are the work and the open questions.

| # | What is needed | Who owns it |
|---|---|---|
| H1 | the `schema` declaration: one new top-level form, grammar, lowering, formatter, diagnostics | §4, §8.1 |
| H2 | `schema` as a well-known method with a compiler table for primitives and core containers, on the `eq`/`compare` model | §4.5 |
| H3 | `constrained_constant` extended to *annotated* declarations, or K2 taken — because today an annotated nullary declaration with a `where` clause is an exit-0 miscompile | §3.9 — **a `master` defect, independent of this report** |
| H4 | a position on whether a function's `suspends` bit is polymorphic when the function is a *field of a record*, not a parameter | K10, §3.7 |
| H5 | (only if the owner wants library-level renames) a compiler-checked field reference, so `Schema.rename .name "user_name"` can be checked. **Recommend not doing it** — §3.4.3 | K4 |
| H6 | (only for the ten type-computation "cannot" rows) type-level record operations. **Recommend not doing it** | §2.15 |
| H7 | a decision on `Int` past 2⁵³ at the boundary — a rule, not a feature | K11 |

---

## 3. The library layer, designed

### 3.1 The core types

```elm
--| What a wire value looks like, whatever the format.
pub type Value
    = Null
    | Flag Bool
    | Number Float
    | Text String
    | Array (List Value)
    | Object (List ( String, Value ))


--| Where in the value an issue was found.
pub type Step
    = AtField String
    | AtIndex Int
    | AtVariant String


pub type Issue
    = WrongType (List Step) String Value
    | Missing (List Step) String
    | Refused (List Step) String


--| The inspectable description. No type parameter: a description says what is
--| on the wire, and the wire has one type.
pub type Node
    = TextNode
    | NumberNode
    | FlagNode
    | NullNode
    | ArrayNode Node
    | ObjectNode (List ( String, Node ))
    | ChoiceNode String (List ( String, Node ))
    | OptionalNode Node
    | CheckedNode Node String
    | NamedNode String Node
    | ExtraNode String Value
    | DeferredNode


pub type alias Reader a =
    Value -> Result (List Issue) a


pub opaque type Schema a
    = Schema
        { node : Node
        , read : Reader a
        , write : a -> Value
        }
```

**`Schema a` is opaque, not a `type alias` for the record.** Under `language.md` §6.3 and spike
§1.2, `x.m a` on a *record* is a field call and on a *nominal* type is a method call. Opaque makes
`s.checked "…" f` dispatch to `Schema.checked`, which is what gives the library the dot-call
ergonomics of §3.8 — and it keeps the three fields private, so `Schema.custom` is the only way to
build an inconsistent one.

**`Node` is the answer to "inspectable descriptions, not opaque function pairs."** A `Schema a`
carries both: the functions do the work, and `Node` is what a JSON-Schema generator, a form builder
or a documentation tool reads (§6). The two cannot drift, because every combinator builds them
together in one expression.

### 3.2 Why the wire side is not a type parameter (K1)

`Schema wire a` is the obvious design and it fails three times.

**It cannot type a record.** `schema User = { name : String as "user_name", createdAt : Date via
Date.millis }` has wire side `{ user_name : String, createdAt : Int }`. Producing that type from
`User` is a mapped type: rename some keys, replace some value types, per field. beni has no
construct that computes a record type from a record type, and adding one is the "no computing a
type from a value / from a type" line the owner drew.

**It cannot type a union at all.** `Schema.choice "kind" [ circleVariant, rectVariant ]` needs the
list to be homogeneous. Under `Schema wire a` the two members have *different* wire types, so the
list has no element type. §3.5 shows that even under `Schema a` the payload type must be erased,
and that erasure is exactly what a second parameter would re-expose.

**It doubles every signature for no reader.** Nothing in §6's derived artefacts reads the wire
*type*; they read the wire *description*, because a JSON Schema document, a form and a fixture are
all data.

What is kept: `describe` returns the full wire shape as data, and the type checker still guarantees
the program side. What is lost: a compile-time check that two schemas agree on their wire type —
which is exactly the comparison `Schema.roundTrips` makes at run time (§7.2), and which nothing in
the Effect docs shows anyone performing at the type level either.

### 3.3 Primitives and composites

```elm
pub describe : Schema a -> Node
pub read : Schema a, Value -> Result (List Issue) a
pub write : Schema a, a -> Value
pub custom : Node, Reader a, (a -> Value) -> Schema a

pub string : Schema String
pub int : Schema Int
pub float : Schema Float
pub bool : Schema Bool
pub null : Schema ()
pub literal : String -> Schema ()
pub value : Schema Value                       -- the identity schema

pub list : Schema a -> Schema (List a)
pub dict : Schema a -> Schema (List ( String, a ))
pub nullable : Schema a -> Schema (Maybe a)
pub pair : Schema a, Schema b -> Schema ( a, b )
pub triple : Schema a, Schema b, Schema c -> Schema ( a, b, c )
pub enumerated : List ( String, a ) -> Schema a
    where a.eq : a, a -> Bool
```

`enumerated` needs `a.eq` for its writing direction — it has to find the value in the table — and
that is one line where every other language in the survey needs a hand-written `toString`. It is the
static-dispatch dividend in miniature.

### 3.4 The crux: building a record schema by name

Three candidates were evaluated. The brief names all three.

**(a) Only the compiler may make record schemas** — the `schema` declaration is the sole
constructor and the library offers adjustments. Rejected: it breaks report 28 §0's rule that the
sugar must desugar into a form that stays available, it makes a second wire form unwritable
(§5.8), and the library could then not be tested without the declaration.

#### 3.4.1 (b) A rescript-schema builder — and why it is not available

```
S.object(s => { id: s.field("Id", S.float), tags: s.fieldOr("Tags", …, []) })
```

In beni this is `Schema.record (\s -> { id = s.field "Id" Schema.float, … })`, and the question the
brief asks is whether beni's type system can type `s.field` so the result is `Schema Film`. **It
can** — `field : Fields, String, Schema x -> x` types fine. The trouble is entirely at run time,
and there are three separate blocks:

1. **`s.field "Id" Schema.float` has to return a `Float` that is not a float.** rescript-schema
   returns a sentinel and later finds it by identity. In beni that value is typed `Float` and the
   author may compute on it — `s.field "a" Schema.float + 1.0` type-checks and produces a silent
   wrong answer, which is the exact class CLAUDE.md rule 7 says must not exist. Tracing the
   construction is otherwise legal under purity: running the lambda once is a pure call.
2. **The library would have to inspect the record it got back**, to learn which program field each
   sentinel landed in. beni has no reflection: `Debug.toString` is the only thing close and
   `--release` refuses a build that reaches `Debug` at all (`backend.md` §9); records are emitted
   as plain objects with sorted keys (`backend.md` §4) and nothing in the language reads a key set.
3. **Only core may write `foreign`** (rule 6), so a library needing either capability cannot be an
   ordinary package — and putting sentinel-and-reflect machinery into core to serve one API is not
   a capability gap, it is a design choice with a safe alternative.

So: **not available**, and the reason is a guarantee rather than a limit of the type system.

#### 3.4.2 (c) The left-nested accumulator — recommended

```elm
pub object : Schema ()
pub field : Schema r, String, Schema x -> Schema ( r, x )
pub optionalField : Schema r, String, Schema x -> Schema ( r, Maybe x )
pub defaulted : Schema r, String, Schema x, x -> Schema ( r, x )
pub rest : Schema r, String -> Schema ( r, List ( String, Value ) )
pub build : Schema r, (r -> a), (a -> r) -> Schema a
```

Each `field` grows the accumulator by one, so a record of *n* fields has accumulator
`(…(( (), x₁ ), x₂ )…, xₙ)`, and `build` closes it with two functions. There is **no arity family
and no cap** — a cap would be a rule-7 restriction bought for nothing, and Elm's `mapN` stopping at
8 is the prior art everyone has hit. The §0.2 chain is verbatim from the scratchpad, `beni check
--no-cache` exit 0; `( ( (), n ), a )` is an ordinary nested tuple pattern in a lambda parameter,
which `language.md` §3's `LetPattern` admits because `()` and tuples of qualifying patterns both
qualify.

**Where this can still go wrong, stated plainly.** If two adjacent fields have the same type and
the author swaps them in *one* of the two lambdas, nothing complains. That is elm-codec's bug,
reduced from "every field, every time" to "one seam, written twice", and the two halves of this
design answer it: the `schema` declaration writes both lambdas from one list of fields, so they
cannot disagree, and `Schema.roundTrips` (§7.2) is a one-line test that catches it when they are
hand-written.

**The alternative considered and rejected**: carry a setter per field
(`field : …, (a -> x), (a, x -> a) -> …`) and start from a blank `a`, which removes the seam
entirely because each field knows how to put itself back. It needs a blank value of the record type
— and a validated field like `Email` has no blank, by construction. Rejected for that reason.

#### 3.4.3 Adjusting a record schema afterwards, and checked field references (H5)

`Schema.rename : Schema a, String, String -> Schema a` (old wire key → new) is writable and looks
useful for a second wire form, but it takes two bare `String`s and a key that is not there is a
no-op — a silent wrong answer. **Recommendation: do not ship it in the first slice.** The
declaration covers renaming, the second wire form is written out (§5.8), and an unchecked stringly
adjustment is the kind of API that looks convenient and reports nothing.

`Schema.rename .name "user_name"` would be checkable if `.name` carried its field's *name* into
the type — a field-name literal kind, which is a type computed from a value. **Recommend not doing
it (H5):** it buys a check for an API this section recommends not shipping, and it opens the door
the owner closed.

### 3.5 Tagged unions, and where erasure is forced

```elm
pub opaque type Variant a
    = Variant
        { tag : String
        , node : Node
        , read : Reader a
        , write : a -> Maybe Value
        }


pub variant : String, Schema x, (x -> a), (a -> Maybe x) -> Variant a
pub choice : String, List (Variant a) -> Schema a
pub oneOf : List (Attempt a) -> Schema a
pub exactlyOneOf : List (Attempt a) -> Schema a
```

`variant` takes the wire tag, the payload's schema, the constructor, and a *matcher* that says
whether a given `a` is this variant — which is one `case` arm the author (or the compiler) writes.
Reading: find the tag, run that variant's reader, apply the constructor. Writing: try each
matcher in order and write the first that answers; the compiler-generated version is total by
construction because it covers every constructor.

**The payload type `x` is erased.** It cannot appear in `Variant a`, because
`type Variant a = Variant String (Schema x) …` leaves `x` unbound, which is `unbound_type_variable`
(`language.md` §7) — existential quantification, which beni does not have and should not get. The
erasure is free, because `variant` closes over the payload schema when it builds the two functions,
and the *description* survives in `node`. This is the second reason K1 goes the way it does: a wire
type parameter would have to be erased here too, and then it would be a type parameter that is
absent exactly where unions are.

### 3.6 Transformations, checks, recursion, and running

```elm
pub mapped : Schema b, (b -> a), (a -> b) -> Schema a
pub tried : Schema b, (b -> Result String a), (a -> b) -> Schema a
pub checked : Schema a, String, (a -> Bool) -> Schema a
pub abortingCheck : Schema a, String, (a -> Bool) -> Schema a
pub judged : Schema a, (a -> List Issue) -> Schema a
pub expecting : Schema a, String -> Schema a
pub named : Schema a, String -> Schema a
pub example : Schema a, a -> Schema a
pub recovered : Schema a, (List Issue -> Maybe a) -> Schema a
pub around : Schema a, (Reader a -> Reader a) -> Schema a
pub deferred : (() -> Schema a) -> Schema a
```

**Ordering rule, taken from Effect (row 82) and stated because it is observable.** A check on a
composite runs only after every part of that composite read successfully. With
`Options.report = AllOf`, an inner failure is reported and the outer check does not run; with
`FirstOnly`, reading stops at the first `Issue`. The reason is that a whole-record check is written
against a whole record, and there is no whole record to hand it.

**Running:**

```elm
pub type Unknown
    = Ignore
    | Reject


pub type Report
    = FirstOnly
    | AllOf


pub type alias Options =
    { unknown : Unknown, report : Report, maxDepth : Int }


pub defaults : Options
pub readWith : Schema a, Options, Value -> Result (List Issue) a
pub parse : Schema a, String -> Result (List Issue) a
pub parseWith : Schema a, Options, String -> Result (List Issue) a
pub print : Schema a, a -> String
pub roundTrips : Schema a, a -> Bool
    where a.eq : a, a -> Bool
```

`maxDepth` is [`boundary.md`](../boundary.md) §3.1's depth bound, promoted from a port-generator
constant to a field, and it does the same job for the same reason: *"a decoder that recurses past
the bound fails as a value rather than as a stack overflow."* Default 512, matching the checker's
own type-reading limit (`language.md` §10).

**Three ways in, one schema.** `parse` takes JSON text. `readWith` takes a `Value` — which is what a
port payload, a form and a query string all become through their adapters. And
`Schema.readForeign : Schema a, Options, Foreign -> Result (List Issue) a` reads an
already-parsed JavaScript value without building a `Value` tree first; it is the fast path §8.5
wants for ports, and it is the one place the library needs help from core.

### 3.7 Effectful transformations (K10, H4)

The brief asks: can a transformation simply call a service, and what does that do to `decode`'s own
bits? The answer is a question the effects spec has not answered.

`transparent-effects-proposal.md` §1 derives that `suspends` must be part of a function's *type*,
because separate compilation carries nothing else across a module boundary. §2 then promises
bit-polymorphism for higher-order functions: `List.map : List a, (a -> b) -> List b` serves a pure
callback and an effectful one, "one definition, no signature change".

A `Schema a` stores its reader in a **field**, not a parameter. So:

- if the bit is polymorphic for a function in a field too, `Schema a` is one type and an effectful
  transformation costs nothing in the surface — which is the best outcome and is what Effect needs
  `RD`/`RE` type parameters for (row 160);
- if it is not, `Schema a` splits into a sync and a suspending flavour, and every combinator is
  written twice. That is unacceptable, and the design would instead keep reading pure and make
  enrichment a pass over the decoded value.

**Until that has a position, layer 1 is pure.** What is lost is one Effect capability (rows 83, 92,
99-async, 156) and one worked example (§5.7). What is gained is that nothing in this design has to
be unbuilt when the effects spec answers. The question belongs in
[`plans/effects-plan.md`](../../../plans/effects-plan.md)'s list of owner decisions, and §5.7 argues
that even *with* the answer, reading should not perform: a schema is run on data from the network,
and a reader that itself reaches the network turns one round trip into *n*.

### 3.8 Ergonomics: dot-calls and pipes, checked

Both forms work today, `beni check --no-cache` exit 0:

```elm
pub nonEmpty : Schema String
nonEmpty =
    Schema.string.checked "must not be empty" (\s -> s /= "")


pub emails : Schema (List String)
emails =
    nonEmpty
        |> Schema.list
        |> Schema.checked "at least one" (\xs -> List.length xs > 0)
```

The first line is spike §1.1's `M.v.m a` row — a method call whose receiver is a qualified value —
and it reads exactly as Effect's `Schema.String.check(...)` does. This is worth noting because it
is free: static dispatch already bought the library its fluent surface.

### 3.9 Two facts established against the live compiler

**(i) Evidence flows, and the emitted code is right.** Building the §5 examples as a library
(`beni build --library --platform=node`) emits:

```js
const App$prices = ($p$1) => Page$schema(Money$schema, null);
const App$load = (text$1) => Schema$parse(App$prices(null), text$1);
```

`Page$schema(Money$schema, null)` is the evidence parameter first and the `()` second, exactly as
spike §8.1 specifies. **The generic-schema design works end to end on today's compiler with no
language change.**

**(ii) A `master` defect, found while probing K2 (H3).** An *annotated* top-level declaration with
no parameters and a `where` clause is emitted as a JavaScript function, while every consumer reads
it as a value. Minimal reproduction, exit 0, three files:

```elm
pub blank : List a
    where a.eq : a, a -> Bool
blank =
    []


pub blankInts : List Int
blankInts =
    blank
```

```js
// Blank.mjs
const Blank$blank = ($m$0) => ({ $: 0, a: null, b: null });
const Blank$blankInts = () => Blank$blank(Blank$eq$prim);
// Sees.mjs — reads it as a value
const Sees$n = List$length(Blank$blankInts);
```

`List$length` receives a function. Spike §8.1 says *"the checker refuses it first
(`constrained_constant`, §6.4), so the backend never meets one"* — and §10.10 says
`constrained_constant` is about an *inferred* scheme, so the annotated case falls between the two.
This is not caused by anything in this report; it is why K2 recommends the thunk, and it deserves
a fixture under `tests/corpus/check/bad/` whatever the owner decides about schemas.

---

## 4. The `schema` declaration

### 4.1 Grammar sketch

In `language.md` §3's notation, adding one alternative to `Decl` and nothing else:

```
Decl        := DocComment? Visibility? (TypeAlias | TypeDecl | TopAnnotation
                                       | Definition | Foreign | SchemaDecl)

SchemaDecl  := 'schema' upper_ident lower_ident* SchemaBody
SchemaBody  := '=' '{' SchemaField (',' SchemaField)* '}'          -- a record
             | 'tagged' string 'of' Variant ('|' Variant)*         -- a custom type
             | ε                                                   -- derive for an existing type

SchemaField := DocComment? lower_ident ':' Type FieldOpt*
FieldOpt    := 'as' string                    -- the wire key
             | 'via' Atom                     -- a two-way conversion, `Via b a`
             | 'default' Atom                 -- used when the key is absent or null

Variant     := upper_ident TypeAtom* ('as' string)?
```

**`schema` is a contextual word, not a keyword**, recognised exactly as `where` and `equatable` are
(`language.md` §3, spike §2.2): a `lower_ident` spelled `schema`, at the start of a declaration,
followed by an `upper_ident`. `schema = 1` at column 1 stays an ordinary declaration of a value
called `schema`, which matters because `schema` is the name of the method every module will define.
`tagged`, `of`, `as`, `via` and `default` are likewise contextual and only inside a `SchemaBody`;
`as` is already a keyword and is reused.

**Layout** is `language.md` §4 rule 2 and nothing more. **Formatting**: one field per line, the
`,` leading each continuation as records already do, modifiers separated by single spaces and
**never aligned** — `language.md` §9 aligns nothing, and the owner's sketch shows columns that the
formatter would collapse. Say that explicitly, because the sketch is what people will copy.

### 4.2 What it declares

`pub schema User = { … }` declares **two** names:

- the type `User`, exactly as `pub type alias User = { … }` would, with every modifier stripped;
- the value `pub schema : () -> Schema User` in this module.

`pub schema Shape tagged "kind" of …` declares `pub type Shape = …` and the same value. A bodyless
`schema Point` declares only the value, structurally, for an existing `Point`.

Because the value is called `schema` and lives in the type's declaring module, **the module rule
gives it to `x.schema` and to `where a.schema` for free** — no new resolution path, no new table
except §4.5's.

### 4.3 The field rules, and the optionality matrix

Effect spends L496–L991 on optionality because TypeScript distinguishes absent, `undefined` and
`null`, on both the type side and the encoded side. beni has `Maybe` and no `undefined`, so the
matrix collapses:

| Declared | Wire, reading | Wire, writing |
|---|---|---|
| `age : Int` | the key must be present and non-`null` | always written |
| `age : Int default 0` | absent or `null` → `0` | always written |
| `email : Maybe Email` | absent or `null` → `Nothing` | written only when `Just` |
| `extra : List ( String, Value )` with `rest` | everything no other field claimed | written back out |

**`Maybe` accepting absent *or* `null` is a decision, not an accident.** Real payloads use both for
the same idea and often inconsistently in one API; a rule that distinguishes them makes the author
guess, and guessing wrong is a read failure on live data. The strict variants
(`Schema.absentField`, `Schema.nullField`) stay in layer 1 for the author who knows their API and
wants the tighter check. That is rule 7's shape: the forgiving default, and the strict one is
available.

**No inline checks in the declaration.** `age : Int where age >= 0` is deliberately not offered.
The rule-7 argument is a guarantee: a checked value that is typed `Int` can be *constructed* without
the check anywhere else in the program, so the check is a property of one decoding path and not of
the value — which is precisely the forgery hole report 31 §4.2 documents. A constrained value is a
validated type (`Age`, `Email`, `Username`), its module owns the only constructor, and its schema
runs the check. Nothing is withheld: the escape hatch is a three-line module and layer 1's
`Schema.checked` is always available for the cases where the value really is unconstrained.

### 4.4 `via`

```elm
pub type alias Via b a =
    { from : b -> Result String a
    , to : a -> b
    }
```

`createdAt : Date via Date.millis` says: the wire side is whatever `Via`'s first parameter is
(`Int` here, from `Date.millis : Via Int Date`), its schema is `Int`'s own, and the two directions
are the record's fields. A total conversion writes `from = \n -> Ok (…)`. `via` beats the field
type's own `schema` — Effect's row 131 rule, and the right one.

`via` is an ordinary value, so a platform ships `Date.millis`, `Date.iso8601`, `Date.seconds` side
by side and the author picks. That is the whole of Effect's `DateFromMillis`/`DateFromString`
family with no schema-library involvement.

### 4.5 Type parameters, and where `a`'s schema comes from

```elm
-- [proposed]
pub schema Page a =
    { items : List a
    , next : Maybe String
    }
```

desugars to the §0.1 example (4), whose annotation is
`pub schema : () -> Schema (Page a) where a.schema : () -> Schema a` — **the `where` clause is
generated, one constraint per type parameter that is actually reachable from a field**. Return-type
dispatch then supplies `a.schema ()` at each use. This is spike §4 doing exactly the job it was
built for, and §3.9(i) shows the emitted code.

**The well-known method table (H2).** `Int`, `Float`, `Bool`, `String`, `Char`, `Order`, `Never`,
`()` and tuples resolve `schema` from a table inside the compiler, **before** the module rule —
which is spike §3.2's arrangement for `eq`/`compare`, and for the same reason: those types are
declared in `core/Basics` and `core/String`, and `core/Schema` imports them, so a `pub schema` in
`Basics` would be an `import_cycle` (spike §5, the core-cycle constraint). The table's entries point
at `core/Schema`'s own combinators. `List a`, `Maybe a`, `Result e a`, `Dict k v` and `Set a` join
it for the same reason, each carrying its parameters' evidence.

Everything else resolves by the module rule, and a type whose module has no `schema` is
`unknown_method` — **which is already a good diagnostic and already names the fix.** Verbatim,
today:

```
-- UNKNOWN METHOD --------------------------------------------- src/Use.beni:7:5

`Int` has no method called `schema`.

I resolve `x.schema` in the module that declares `x`'s type. That module is
`Basics`, and it has no `pub` value called `schema`.
…
`schema` was required by `pageSchema`'s annotation.
```

That is report 31's *"'no schema for this type' must be a compile-time diagnostic, never a run-time
crash"*, satisfied with **no new diagnostic code** — the message only needs its hint changed to
name `schema T`.

### 4.6 Desugaring, field by field

| Written | Becomes |
|---|---|
| `schema T = { … }` | `pub type alias T = { … }` + `pub schema : () -> Schema T` |
| `f : X` | `\|> Schema.field "f" <X's schema>` |
| `f : X as "k"` | `\|> Schema.field "k" <X's schema>` |
| `f : Maybe X` | `\|> Schema.optionalField "f" <X's schema>` |
| `f : X default e` | `\|> Schema.defaulted "f" <X's schema> e` |
| `f : X via v` | `\|> Schema.field "f" (Schema.tried <b's schema> v.from v.to)` |
| `f : List X` | `\|> Schema.field "f" (Schema.list <X's schema>)` |
| the whole record | `Schema.object` … `\|> Schema.build <assemble> <disassemble>` |
| `schema T tagged "k" of` | `Schema.choice "k" [ … ]` |
| a variant `C P as "c"` | `Schema.variant "c" <P's schema> C (\v -> case v of C p -> Just p; _ -> Nothing)` |
| a variant with no `as` | wire tag is the constructor name verbatim |
| `schema T` (bodyless) | the structural schema for `T`'s declared shape |
| `<X's schema>` | `X.schema ()` for a nominal `X`, the table's entry for a well-known one, a type parameter's evidence for a variable |

`<assemble>` is `\( ( … ( (), x₁ ) …, xₙ ) -> { f₁ = x₁, …, fₙ = xₙ }` and `<disassemble>` its
inverse, both generated from the same field list in the same order. §5.1 shows all of it for a real
type.

### 4.7 Interactions

| With | What happens |
|---|---|
| `eq` / `compare` derivation | nothing changes. They derive from the **type**, and a `schema` declaration declares an ordinary type. A module that declares both a `schema` and a `pub eq` keeps its `pub eq` (spike §3.3 step 1) |
| `pub` and modules | `pub schema T` makes both names `pub`; a private `schema T` gives a private type and a private method, and `private_method` fires for an outside caller exactly as it does today |
| opaque types | a `pub opaque type` may **not** get a bodyless `schema T` from outside its module, and should not get one from inside either unless the author means it (K3). The validated pattern writes the schema by hand, in the module, through the checked constructor |
| the formatter | one new printer case; no alignment; the `\|` of a tagged body leads its line as a `type` declaration's does |
| `dump --stage=bir` | the declaration is gone by BIR — it lowers to an ordinary `type alias` skeleton plus an ordinary declaration — so `bir` goldens show only calls, which is report 28 §10's "one semantics" proof and is what an `emit/` golden should assert |
| type parameters with no schema | `where_variable_unbound` cannot fire (the clause is generated); a *use* at a type with no `schema` is §4.5's `unknown_method` |
| what is refused | a field whose type is a function, an extended record, a type variable with no generated constraint, or a `foreign type` with no `schema` — which is [`boundary.md`](../boundary.md) §3.1's admitted set exactly, arrived at by a different route |
| **where the refusal lands** | at the **declaration** when the offending type is written there (a function-typed field); at the **use** when it is a type parameter instantiated badly. Both are compile-time; neither is a run-time crash. This answers report 31 §7 question 4 |

### 4.8 What is deliberately not in the declaration

- **No inline checks** (§4.3).
- **No `schema B from A`** — the sugar that would answer nine of §2.15's eleven "cannot" rows by
  copying another declaration's field annotations. It is syntax over syntax, so it is *available*,
  but it is a second feature and should be commissioned only if the duplication is measured to
  hurt.
- **No wire type** (K9).
- **No JSON-specific knobs.** `as`, `via` and `default` are format-neutral: they mean "this key",
  "this conversion", "this fallback" in a form and a query string too. §9 treats this as the answer
  to the drift objection, and it is the line to hold.

---

## 5. Worked examples

Each is shown as (i) Effect, from `SCHEMA.md`; (ii) beni declaration syntax, `[proposed]`;
(iii) the desugared layer-1 form. Every (iii) was checked.

### 5.1 A user with renamed, defaulted and date fields

**(i) Effect** (L1108, L623, L4914):

```ts
const User = Schema.Struct({
  userId: Schema.FiniteFromString,
  accountName: Schema.String,
  age: Schema.Number.pipe(Schema.withDecodingDefault(Effect.succeed(0))),
  createdAt: Schema.Date
}).pipe(Schema.encodeKeys({ userId: "user_id", accountName: "account_name" }))
```

**(ii) beni** `[proposed]`:

```elm
pub schema User =
    { userId : Int as "user_id"
    , accountName : String as "account_name"
    , age : Int default 0
    , createdAt : Date via Date.millis
    }
```

**(iii) desugared:**

```elm
pub type alias User =
    { userId : Int
    , accountName : String
    , age : Int
    , createdAt : Date
    }


pub schema : () -> Schema User
schema () =
    Schema.object
        |> Schema.field "user_id" Schema.int
        |> Schema.field "account_name" Schema.string
        |> Schema.defaulted "age" Schema.int 0
        |> Schema.field "createdAt" (Schema.tried Schema.int Date.millis.from Date.millis.to)
        |> Schema.build
            (\( ( ( ( (), u ), n ), a ), c ) ->
                { userId = u, accountName = n, age = a, createdAt = c }
            )
            (\r -> ( ( ( ( (), r.userId ), r.accountName ), r.age ), r.createdAt ))
```

Note what Effect needs and beni does not: `FiniteFromString` exists because JSON ids often arrive as
strings *and* because TypeScript has one `number`; beni writes `Int` and, when the id really is a
string on the wire, `userId : Int via Int.text`.

### 5.2 A tagged union with a discriminator and per-variant wire names

**(i) Effect** (L2135):

```ts
const Shape = Schema.Union([
  Schema.Struct({ kind: Schema.tag("circle"), radius: Schema.Finite }),
  Schema.Struct({ kind: Schema.tag("rect"), w: Schema.Finite, h: Schema.Finite })
]).pipe(Schema.toTaggedUnion("kind"))
```

**(ii) beni** `[proposed]`:

```elm
pub schema Shape tagged "kind" of
      Circle { radius : Float } as "circle"
    | Rect { w : Float, h : Float } as "rect"
```

**(iii) desugared** (checked, exit 0):

```elm
pub type Shape
    = Circle { radius : Float }
    | Rect { w : Float, h : Float }


circlePayload : () -> Schema { radius : Float }
circlePayload () =
    Schema.object
        |> Schema.field "radius" Schema.float
        |> Schema.build
            (\( (), r ) -> { radius = r })
            (\c -> ( (), c.radius ))


rectPayload : () -> Schema { w : Float, h : Float }
rectPayload () =
    Schema.object
        |> Schema.field "w" Schema.float
        |> Schema.field "h" Schema.float
        |> Schema.build
            (\( ( (), w ), h ) -> { w = w, h = h })
            (\r -> ( ( (), r.w ), r.h ))


pub schema : () -> Schema Shape
schema () =
    Schema.choice "kind"
        [ Schema.variant "circle"
            (circlePayload ())
            Circle
            (\s ->
                case s of
                    Circle c ->
                        Just c

                    _ ->
                        Nothing
            )
        -- the "rect" variant is the same three lines over `rectPayload` and `Rect`
        ]
```

The generated matchers are what makes writing total: every constructor has one, so `choice`'s
"first matcher that answers" always answers.

### 5.3 A validated `Email`

**(i) Effect** (L2810, L2794) uses a brand plus a check, and the brand is erased at run time:

```ts
const Email = Schema.String.check(Schema.isIncludes("@")).pipe(Schema.brand("Email"))
```

**(ii) and (iii) beni — the same thing, because the declaration has nothing to add.** §0.1 example
(3), unchanged. The difference from Effect is worth naming: Effect's `Email` *is* a `string` at run
time and a cast produces an unvalidated one; beni's is a nominal type whose only constructor is
private, so **there is no expression in the language that produces an invalid `Email`**, whether or
not it came through a schema. That is the guarantee K3 protects.

### 5.4 A paginated generic response

**(i) Effect** (L2440) needs `declareConstructor`'s two-step call, or a plain generic function:

```ts
const Page = <A extends Schema.Top>(item: A) =>
  Schema.Struct({ items: Schema.Array(item), next: Schema.optionalKey(Schema.String) })
```

**(ii) beni** `[proposed]`:

```elm
pub schema Page a =
    { items : List a
    , next : Maybe String
    }
```

**(iii) desugared** — §0.1 example (4), checked, and built: §3.9(i) has the JavaScript. The
difference from Effect is that the element schema is not an *argument*: `Page.schema ()` at type
`Page Money` finds `Money.schema` by the `where` clause, so a caller writes
`Schema.parse (Page.schema ()) text` with no mention of `Money`.

### 5.5 A recursive comment tree

**(i) Effect** (L2235):

```ts
const Comment: Schema.Codec<Comment> = Schema.Struct({
  body: Schema.String,
  replies: Schema.Array(Schema.suspend((): Schema.Codec<Comment> => Comment))
})
```

**(ii) beni** `[proposed]` — nothing special is written; the compiler inserts the deferral when a
field's schema reaches the type being declared:

```elm
pub schema Comment =
    { body : String
    , replies : List Comment
    }
```

**(iii) desugared** (checked, exit 0) — note the type must be a `type`, not a `type alias`, because
a self-referential alias is `recursive_alias`, and the schema must be a **function**, because a
self-referential top-level *value* is `cyclic_value`:

```elm
pub type Comment
    = Comment { body : String, replies : List Comment }


pub schema : () -> Schema Comment
schema () =
    Schema.object
        |> Schema.field "body" Schema.string
        |> Schema.field "replies" (Schema.list (Schema.deferred schema))
        |> Schema.build
            (\( ( (), b ), r ) -> Comment { body = b, replies = r })
            (\(Comment c) -> ( ( (), c.body ), c.replies ))
```

Two consequences the declaration must handle and that are worth stating in the spec: **a recursive
`schema T = { … }` declares a `type` with one constructor, not a `type alias`**, and the
`build` functions wrap and unwrap that constructor. The compiler knows which case it is in, because
it knows whether any field's type reaches `T`. A reader hits `Options.maxDepth` before the
JavaScript stack does.

### 5.6 A fallible custom transformation: `"12.50 USD"` ↔ `Money`

**(i) Effect** (L3349):

```ts
const Money = Schema.String.pipe(Schema.decodeTo(MoneySchema,
  SchemaTransformation.transformEffect({
    decode: (s, o) => …Effect.fail(new SchemaIssue.InvalidValue({message: "…"}, s, o)),
    encode: (m) => Effect.succeed(`${m.cents / 100} ${m.currency}`)
  })))
```

**(ii) and (iii) beni** — a validated type again, and `tried` is the whole of it (checked, exit 0):

```elm
pub opaque type Money
    = Money { cents : Int, currency : String }


pub fromText : String -> Result String Money
fromText text =
    case String.split text " " of
        [ amount, currency ] ->
            case String.toFloat amount of
                Just a ->
                    Ok (Money { cents = round (a * 100), currency = currency })

                Nothing ->
                    Err "the amount is not a number: ${amount}"

        _ ->
            Err "expected \"<amount> <currency>\", got ${text}"


pub toText : Money -> String
toText (Money m) =
    "${toFloat m.cents / 100} ${m.currency}"


pub schema : () -> Schema Money
schema () =
    Schema.tried Schema.string fromText toText
```

`fromText` returns `Result String Money` and `toText` is total — K5 in one file. And because
`fromText` is a `pub` value of `Money`'s own module, it is also `Money`'s public constructor and its
`Via` record is `{ from = fromText, to = toText }`, usable as `via Money.text` from any other
schema. One function, three jobs.

### 5.7 An effectful transformation — and the argument for refusing it

**(i) Effect** (L7004, row 160) — decoding an id into a full user through a `UserDatabase` service:

```ts
declare const User: Schema.Codec<{id: string, name: string}, string, UserDatabase, never>
const decoding = Schema.decodeEffect(User)("user-123")
```

**(ii) beni: do not do this, and the reason is not the type system.** Under transparent effects the
code would be unremarkable — `Schema.tried Schema.string Users.lookup Users.idOf`, with `lookup`
inferred `suspends` and nothing written anywhere. Two things argue against allowing it:

1. **It turns one round trip into *n*.** A schema is run on a payload that already arrived. A reader
   that itself performs runs once per occurrence — a list of 200 ids is 200 lookups, serialised,
   inside a function whose type says "read this value". Effect's answer is the `concurrency` parse
   option (row 150), which is a knob to manage a problem the shape created.
2. **It makes reading non-repeatable.** `Schema.roundTrips` (§7.2), `Schema.sample` (row 148) and
   `--release`'s specialised reader (§8.3) all assume reading a value twice gives the same answer.

**The recommended shape** is the ordinary beni one — read, then enrich:

```elm
pub load : String -> Result (List Schema.Issue) (List User)
load text =
    let
        ids =
            Schema.parse (Schema.list Schema.string) text?
    in
    Ok (List.map ids Users.lookup)
```

`?` unwraps the read, `List.map` performs, and the two concerns stay apart. This is K10's
option (b), and it is recommended **on design grounds** rather than because the effects question
(H4) is open — which means the answer to H4 does not change the recommendation, only whether the
capability exists for the person who insists.

### 5.8 One type, two wire forms — v1 and v2 of an API

This is the case K4 keeps layer 1 available for, and it is the shape report 31 §4.1 says every real
API eventually has. `User` is declared once with its v2 schema; v1 is an ordinary value in whatever
module cares:

```elm
-- [proposed] in User.beni — v2 is the type's own schema
pub schema User =
    { name : String as "user_name"
    , age : Int default 0
    }
```

```elm
-- in ApiV1.beni — a second wire form, ordinary beni, no new language
import User exposing (User)


pub userV1 : () -> Schema User
userV1 () =
    Schema.object
        |> Schema.field "userName" Schema.string
        |> Schema.field "userAge" Schema.int
        |> Schema.build
            (\( ( (), n ), a ) -> { name = n, age = a })
            (\u -> ( ( (), u.name ), u.age ))
```

Both are `Schema User`, so `Schema.parse (ApiV1.userV1 ()) old` and
`Schema.parse (User.schema ()) new` produce the same type and a migration is
`User.schema () |> Schema.print |> …`. **The wire form is a value, not a property of the type**,
which is the single most important thing K1 buys and the thing "derive the schema from the type"
cannot do.

### 5.9 The typeahead program's HTTP, rewritten

`plans/browser-platform.md` §1.1's `Api` record has `search : String -> Result HttpError (List Hit)`
and `Hit` declared as a bare `type alias` with no wire story at all — the payload is assumed. With
schemas the assumption becomes a declaration, and the only line of the program that changes is
inside the real API implementation:

```elm
-- [proposed] replaces `type alias Hit = { id : HitId, title : String }`
pub schema Hit =
    { id : HitId as "hit_id"
    , title : String
    }


pub schema HitPage =
    { hits : List Hit
    , total : Int default 0
    }
```

```elm
-- the platform side, `[proposed]` for Http and Send only
realApi : Api
realApi =
    { search = searchReal
    , setFavourite = setFavouriteReal
    }


searchReal : String -> Result HttpError (List Hit)
searchReal q =
    let
        body =
            Http.getText "/search?q=${q}"?
    in
    case Schema.parse (HitPage.schema ()) body of
        Ok page ->
            Ok page.hits

        Err issues ->
            Err (BadPayload (Schema.explain issues))
```

Three things to notice. `HttpError` gains a `BadPayload String` constructor, which is the payload
failure becoming a **constructor in the result type** — [`boundary.md`](../boundary.md) §4.1's recipe
applied one level up. `update` and `view` are untouched, because the schema lives at the boundary
where it belongs. And the test double in the same file passes `Hit` values directly and never
touches a schema, so the schema costs the tests nothing — which is the property that makes
`Schema.roundTrips` (§7.2) worth adding as the *one* schema test a program writes.

---

## 6. What is derived from a schema, and why the description must be data

Five artefacts, each a pure function of `Node` (plus `write` for two of them), each in its own
package so that a program that wants none of them ships none of them (§8.4):

| Artefact | Function | Why it needs `Node` and not the functions |
|---|---|---|
| **JSON Schema / OpenAPI** | `JsonSchema.of : Node -> Value` | a JSON Schema document is a *description*; you cannot recover one by calling a reader |
| **Test data** | `Sample.of : Node, Seed -> ( Value, Seed )`, then `read` | generating a valid value means walking the description; report 17 §4.9's seeded PRNG is `pure`, so this is an ordinary function |
| **A form** | `Form.of : Node -> Html msg` | a text input per `TextNode`, a select per `ChoiceNode`, a repeater per `ArrayNode` — this is the browser platform's most obvious first customer |
| **API documentation** | `Docs.of : Node -> String` | `NamedNode` carries the doc comment from the declaration |
| **JSON Patch** | `Patch.between : Schema a, a, a -> List Op` | needs `write` as well, per row 142 |

**Equality is the one Effect derives from a schema that beni does not need**: `eq` and `compare`
come from the *type*, derived by the compiler (spike §9), so they work for values that never met a
schema. Effect has to derive `Equivalence` from a schema because TypeScript has no run-time
structural equality. That asymmetry is worth recording, because it is the clearest case where
static dispatch already paid for something the schema feature would otherwise have to.

**The link to the server/client gap.** `references/talks/2024-ryan-carniato-ways-to-build-web-apps/notes.md`
records that the three architectures differ mainly in *what crosses the wire*: an SPA "ships the
template once and then fetches only data forever after", server components ship "template plus data
on every interaction", and an SSR'd SPA pays "double data" — the data once in the HTML and again as
serialised JSON for hydration. Carniato's own speculation is "server signals": serialise a coloured
reactive graph rather than diffing HTML. Every one of those sentences is a sentence about
serialising typed program state across a wire, and a full-stack beni project —
[`boundary.md`](../boundary.md) §5.3 makes one project with two platforms a first-class requirement
— has exactly the problem, one schema module imported by both builds. **A schema value is what makes
"the same type on both sides" a compile-time fact rather than a convention**, and it is the piece
`boundary.md` §5.3 assumes and does not supply.

---

## 7. Guarantees (CLAUDE.md rule 7)

### 7.1 What the feature guarantees

| Guarantee | How |
|---|---|
| **The reader and the writer cannot disagree about a field's name, its position, or whether it is optional** | they are built from one list of fields in one expression. This is the guarantee report 31 §5 says is the *only* rule-7-legitimate justification for the feature, and it is the one that survives the shape-mismatch objection, because `as` / `via` / `default` keep it true when the shapes differ |
| **No run-time crash on bad input** | reading is total: every failure is an `Issue` in a `Result`. The depth bound (`Options.maxDepth`) makes a hostile payload fail as a value rather than as a stack overflow, which is `boundary.md` §3.1's rule promoted to a field |
| **A validated type cannot be forged through reading** | its constructor is private to its module and its schema is written there, through the checked constructor. K3 refuses the structural default that would peel past it — the Roc defect of report 31 §4.2 |
| **"No schema for this type" is a build error** | `unknown_method` from the module rule, at the declaration when the type is written there and at the use when it is a type parameter (§4.7). No run-time "missing codec" exists to report |
| **Writing never fails** | K5 |
| **No silent wrong answer past 2⁵³** | K11 |
| **The declaration adds no semantics** | it desugars into layer-1 calls before BIR, so `dump --stage=bir` and an `emit/` golden can prove the two forms produce identical bytes — report 28 §10's answer to "two ways", made mechanical |

### 7.2 What is trusted rather than proven

A custom transformation is trusted to satisfy one law:

> for every `x` the program can hold, `from (to x) == Ok x`.

The compiler cannot prove it — `from` and `to` are ordinary functions — and neither can Effect. What
beni can do that Elm cannot is make it **checkable in one line**, because `eq` is derived for every
type (spike §9) and needs no argument:

```elm
pub roundTrips : Schema a, a -> Bool
    where a.eq : a, a -> Bool
roundTrips s sample =
    case read s (write s sample) of
        Ok back ->
            back == sample

        Err _ ->
            False
```

Checked, exit 0, and so is its use — `Money.fromText` returns a `Result`, so the test unwraps it:

```elm
pub moneySurvives : Bool
moneySurvives =
    case Money.fromText "12.50 USD" of
        Ok m ->
            Schema.roundTrips (Money.schema ()) m

        Err _ ->
            False
```

One line like that catches the `build` seam of §3.4.2, a swapped `as`, and a `via` whose two
directions disagree.
With row 148's `Sample.of` it becomes a property test over generated values, which is the form
`ARBITRARY.md` argues for and the form report 31 §5 says nobody writes because nothing makes it
cheap.

The second trusted law is weaker and should be stated rather than assumed: **`write` is not
canonical.** Two program values that are `eq` may produce different `Value`s if a custom `to`
chooses differently, and the same program value may produce different bytes across builds if a
field's order changed. Anyone hashing or signing a payload needs a canonicalising writer, which is
an additional function over `Value` and not a property of the schema.

### 7.3 What it deliberately does not restrict

- **It does not require the declaration.** Layer 1 is complete on its own; §5.8's second wire form
  is only writable there, and a program may never use `schema` at all.
- **It does not require a schema to exist for a type.** K3: nothing is derived until asked.
- **It does not own the wire format.** `Value` and the adapters are ordinary code, so a format
  nobody thought of is a package.
- **It does not restrict what a transformation may do.** `from` is any function; the only rule is
  that it returns a `Result` rather than throwing, which it cannot do anyway.
- **It does not cap the number of fields.** §3.4.2.

---

## 8. Cost

### 8.1 Compiler phases, with line estimates

Anchored on report 28 §9.1's method — string interpolation and the `case` decision tree as the two
comparable features already in the tree — and on the existing port codec generator, which is the
nearest thing to this work that has been built.

| Phase | File (current size) | Change | Lines of Zig |
|---|---|---|---|
| Lexer | `src/lex/Tokenizer.zig` (1 944) | **none** — `schema`, `tagged`, `of`, `via`, `default` are contextual words recognised in the parser, as `where` and `equatable` are (spike §2.2) | **0** |
| Parser | `src/parse/Parse.zig` (4 468) | `parseSchemaDecl`, the field list, the variant list, the five modifiers, the three-token contextual lookahead, two recovery cases | **300–420** |
| AST | `src/parse/Ast.zig` (1 172) | 3 node tags (`schema_decl`, `schema_field`, `schema_variant`) with `extra` records | **90–140** |
| BIR lowering | `src/bir/Lower.zig` (4 215) | the whole desugaring of §4.6: synthesise the `type`/`type alias`, the annotation with its generated `where` clause, the pipeline, and both lambdas; decide recursive-or-not | **450–650** |
| Checker | `src/check/Constrain.zig` (1 642) | the well-known `schema` table of §4.5 beside the `eq`/`compare` one, and its resolution order | **120–200** |
| Formatter | `src/fmt/Format.zig` (3 272) | one declaration printer, the field and variant lists, modifier spacing | **200–280** |
| Dump | `src/dump/ast.zig` | `ast` gains three tags; `bir` gains nothing | **40** |
| Diagnostics | `src/*/Diagnostics.zig` | 4–6 new codes (a duplicate wire key, a duplicate field, a modifier that contradicts the field type, a `via` whose type does not line up) plus the hint change in `unknown_method` | **150–220** |
| **Total, layer 2** | | | **≈ 1 350–1 950** |
| **Layer 1** | `core/Schema.beni`, `core/Json.beni`, `core/Json.js` | beni, not Zig: the combinators, `Value`, `Node`, `Issue`, the adapters | **≈ 900–1 300 lines of beni**, ≈ 40 of JavaScript |

The total is within a few per cent of report 28's JSX estimate (≈ 1 300–1 900), which is the right
sanity check: both features are one new declaration shape that desugars into ordinary calls, and
neither touches the checker's core, the cache format or the interface hash.

**Throughput** (`fast-compiler.md` §2's >250k LOC/s): the lexer is untouched, so the risk is zero by
construction; the parser gains one arm on the declaration switch; lowering does more work per
`schema` declaration than per ordinary one, bounded by the field count.

**Determinism** (rule 5): field order is source order, the generated `where` clause's constraint
order is type-parameter order, and the accumulator is left-nested, so nothing depends on a hash or a
thread. The one place an implementer could break it is the order of the generated `where` clause's
constraints; state that it is the order the parameters are *declared* in and not the order fields
mention them.

**M4**: a `schema` declaration produces ordinary declarations by BIR, so a module's interface is
whatever its annotations say and `checker.md` §7's serialised form is unchanged. The interface
firewall is unaffected.

### 8.2 Output size

Reachability elimination (`backend.md` §9) is declaration-granular and always on, so **a schema
nobody reaches is not written**. Because `schema` is a *method*, the edge that keeps it alive is a
dispatch site, which §9's leg 3 already walks — so a type whose `schema` is never used costs zero
bytes, exactly as its derived `eq` does today (`derived_bytes` went to 0 for the null program).

A schema value that *is* reached costs roughly: one `Node` object per node, one closure per
combinator, and the `build` lambdas. For a ten-field record that is on the order of 30 small objects
and 25 closures, built once per `schema ()` call — call it 1.5–2.5 kB of emitted source before
compression, against perhaps 1.2 kB for a hand-written Elm decoder/encoder pair for the same record,
which is the honest comparison and is a small loss.

### 8.3 `--release`, and what it could do later

Three things, in the order they are worth doing, and **none of them is in the first slice**:

1. **Memoise the thunk.** K2 makes every schema a function, so `User.schema ()` rebuilds the tree on
   every call. A `--release` pass could hoist a nullary `schema` whose body has no evidence
   parameter into a module-level `const`, which is a dead-binding-elimination-adjacent transform
   §9's item 1 machinery already has the shape for. Safe because reading is pure (K10/§5.7).
2. **Specialise the reader.** A schema whose `Node` is fully known at compile time can be compiled
   to a straight-line reader over the raw JavaScript value — no `Value` tree, no closure per field.
   This is Effect's JIT/AOT compiler (row 162) arriving as an ordinary compiler pass instead, which
   is strictly better: no `new Function`, so it works under a Content Security Policy, and no
   startup cost.
3. **Drop the `Node`** when `describe` is unreachable, which reachability already decides.

Item 2 is the one that matters for the browser-first stance, and it is also what makes K8 (ports on
schemas) affordable. It should be a separate commission with its own measurement.

### 8.4 What lands where

| Package | What | Why |
|---|---|---|
| `core/Schema.beni` | `Value`, `Node`, `Issue`, every combinator, `Options`, `readWith`, `roundTrips` | the well-known table has to point somewhere, and only core can be pointed at without an import cycle (§4.5) |
| `core/Json.beni` + `core/Json.js` | `pub foreign parse : String -> Result String Value` and `pub foreign print : Value -> String` | **yes, JSON text parsing is `foreign` in core** (K7). `JSON.parse` throws, so the sibling wraps it in `try`/`catch` and returns a `Result`, per `boundary.md` §4.1. Rule 6 makes this core's job or nobody's |
| the browser platform | `Form.toValue`, `Query.toValue`, `Date.millis` / `Date.iso8601` | format and platform adapters belong to the platform, exactly as report 28 §5.1 puts the element table there |
| `schema-json` (a package) | `JsonSchema.of : Node -> Value` | nobody should pay for OpenAPI who does not ask |
| `schema-sample` (a package) | test data | same |

### 8.5 Slice order

**Library first, declaration second**, and the argument is not habit:

- **S1 — `core/Schema` and `core/Json`.** The whole of layer 1, in beni, with corpus fixtures under
  `tests/corpus/run/` that read and write real payloads. It ships value on its own: today every beni
  program that touches JSON has nothing at all.
- **S2 — the well-known table (H2)** and `where a.schema : () -> Schema a` as a *hand-written*
  pattern. This is checker work, it is small, and §3.9(i) shows it already works.
- **S3 — H3**, the `constrained_constant` defect, with its fixture. Independent, and it should not
  wait for this feature.
- **S4 — the declaration** (§4), for records only, desugaring to S1.
- **S5 — `tagged`**, the union half.
- **S6 — K8**, ports re-specified on schemas, conditional on a measurement of `readForeign` against
  the existing generator.
- **S7 — the derived artefacts** (§6), one package at a time, starting with whichever the browser
  platform needs first.

The reverse order was considered. It fails on the same argument report 28 §10 makes: if the
declaration lands first, its desugaring target is invented to suit it, and the plain form ends up as
something nobody would write by choice — which is how a "sugar over a library" design quietly
becomes a second language.

---

## 9. The strongest case against

Stated at full strength first.

**1. Scala shipped XML literals for fifteen years and removed them.** The stated reasons were parser
and specification complexity (report 28 §2.5). A data-format syntax welded into a general-purpose
language ages with the format, and the exit is expensive because it is in everybody's source. JSON
will not be the last wire format.

**2. Gleam refuses derivation on purpose** — "clarity over convenience" — and Elm's defence of
hand-written decoders is the one real argument: *"The automatic decoders/encoders in Haskell only
work if the shape of your JSON perfectly matches your record definition"* (report 31 §3.1). A
feature justified by the 1:1 case is justified by the case that does not occur.

**3. Two ways to do one thing.** Every schema becomes writable twice. `language.md` has resisted
this elsewhere — there are no operator sections, `(|>)` does not exist — and this would be the
second deliberate duplication the language takes on, after JSX.

**4. The declaration drifts toward JSON-specific knobs.** `as` and `default` are innocuous. Then
somebody wants `nullAs`, then `emptyStringAsMissing`, then a date format string, then
`caseInsensitive`, and in three years the declaration is a small configuration language that only
makes sense against one API's habits.

**5. It is a lot of compiler for a library problem.** ≈ 1 700 lines of Zig, six new diagnostics, a
formatter case, a new well-known method — to save writing two lambdas.

**6. The guarantee is thinner than it sounds.** "Reader and writer cannot disagree" is true of the
*generated* pair, but a `via` is two hand-written functions and the compiler proves nothing about
them. The round-trip law is still trusted, exactly as it is in Elm.

### What in this design answers each

- **(1) Scala** is answered by what goes into the grammar. The declaration knows about *fields*,
  *variants*, *keys*, *conversions* and *fallbacks* — a shape, not a vocabulary. There is no `json`
  anywhere in §4's grammar, no format name, no dialect; `Value` and every adapter are ordinary beni
  in a library, exactly as report 28 §5.1 puts the HTML element table in the platform package. The
  specific wound Scala took — a second parser with a mode flag between two grammars — does not
  arise: §8.1's lexer line is **0**.
- **(2) shape mismatch** is answered by conceding it and building for it. `as`, `via`, `default` and
  `tagged "kind"` exist because 1:1 is the rare case; report 31 §3.3 is right that
  derived-versus-hand-written is a false dichotomy, and this design takes the third option
  throughout. §5.8's two wire forms for one type is the test that a "derive from the type" design
  fails and this one passes.
- **(3) two ways** is answered by making it literally one program: the declaration desugars in
  `bir/Lower.zig` and an `emit/` golden proves the two forms produce identical bytes (§4.7). One
  semantics, one optimiser, one set of diagnostics. And the second way is not redundant — §5.8's
  second wire form is *only* writable in layer 1, which is why rule 7 requires it to exist.
- **(4) drift** is answered by a line drawn in §4.8 and worth writing into the spec: **a modifier
  must mean something in a form submission and a query string, not only in JSON.** `as`, `via` and
  `default` all pass; `nullAs` and a date format string do not, and both are one-line library calls
  in the desugared form. The line is testable, which is what makes it hold.
- **(5) cost** is answered by the split. ≈ 1 700 lines is layer **2**, and layer 1 is beni that has
  to exist either way: today a beni program cannot read JSON at all, so S1 is not optional and is
  not part of this argument. What the declaration buys for its own cost is §7.1's first row — the
  seam of §3.4.2 closed by construction — which is the guarantee, not the keystrokes.
- **(6) the guarantee is thinner** is conceded and priced. The generated pair is proven; a `via` is
  trusted, and §7.2 says so and gives the one-line test that checks it. That is strictly better than
  the status quo, where *both* directions are hand-written and nothing checks either. It is not a
  proof and this report does not claim one.

---

## 10. Could not determine, and an index

### 10.1 Could not determine

1. **Whether a function's `suspends` bit is polymorphic when the function is a field of a record**
   (H4, K10). This is the report's largest open item. It is a question for
   [`transparent-effects-proposal.md`](../transparent-effects-proposal.md), not for this design, and
   §5.7 argues the recommendation does not change either way.
2. **What a schema actually costs in emitted bytes and in read throughput.** §8.2's figures are
   estimates from counting nodes and closures, not measurements; nothing was built. The comparison
   that matters — a generated reader against a hand-written Elm decoder, both after brotli — needs
   S1 to exist.
3. **Whether `readForeign` can beat the existing port generator** (K8, S6). Unmeasured, and the
   whole of K8 turns on it.
4. **Whether `Options.maxDepth = 512` is the right number.** It is taken from the checker's own
   type-reading limit for symmetry, not from a measurement of JavaScript stack depth under the
   emitted reader.
5. **How much of `core/Schema` can be written without new core primitives.** `String.split`,
   `String.toFloat` and `Dict` exist; whether reading an `Object` efficiently needs anything new was
   not checked.
6. **Whether the ten type-computation "cannot" rows of §2.15 actually hurt.** No beni program
   exists to measure the duplication `schema B from A` would remove. That is the right reason to
   leave it out, and the wrong reason to claim the rows do not matter.
7. **Effect's implementation was not read**, by instruction. Every claim about Effect here is from
   its documentation, so where the docs are silent about a semantic — the exact ordering of checks
   against transformations, for instance — this report is too.

### 10.2 The `SCHEMA.md` headings relied on

Every top-level heading of `SCHEMA.md` was read, and each is cited by line number in the row or
rows of §2 that answer it. Mapping, heading → §2 subsection:

| `SCHEMA.md` heading (line) | §2 |
|---|---|
| *Design Philosophy*, *Runtime Performance*, *Experimental schema compilers* (L17, L40, L68) | 2.14 |
| *Defining Elementary Schemas* — Primitives, Literals, Strings, String formats, Numbers, Integers, BigInts, Dates, Template literals (L200) | 2.1 |
| *Structs* and its thirteen subsections (L492) | 2.2 |
| *Tuples*, *Arrays*, *Records* and their subsections (L1518) | 2.3 |
| *Unions* and its six subsections (L1931) | 2.4 |
| *Recursive Schemas* (L2235) | 2.5 |
| *Declaring Custom Types* (L2315) | 2.6 |
| *Validation* and its fourteen subsections (L2523) | 2.7 |
| *Constructors* (L2921) | 2.8 |
| *Transformations* (L3149) and *Flipping Schemas* (L3605) | 2.9 |
| *Classes and Opaque Types* (L3683) | 2.10 |
| *Serialization*, including all four canonical codecs and the XML encoder (L4631) | 2.11 |
| *Schema Generation and Tooling* (L5247) and *Schema Representation* (L5920) | 2.12 |
| *Parsing Options* (L6340), *Error Handling and Formatting* (L6380), *Middlewares* (L6692) | 2.13 |
| *Advanced Topics* (L6768) and *Integrations* (L7053) | 2.14 |

Also read, only for what is derived from a schema:
[`ARBITRARY.md`](../../../references/effect/packages/effect/ARBITRARY.md) — *How Effect Builds a
Generator from Schema*, *Schema Checks and Rejected Values*, *Custom Shrinking*, *Declaration
Schemas*, *Current Limitations*, *Use Schema as the Public Generation Language*;
[`OPTIC.md`](../../../references/effect/packages/effect/OPTIC.md) — *Generating an Optic from a
Schema*, *Known Limitations*; and
[`migration/schema.md`](../../../references/effect/migration/schema.md) — the summary table and the
`optionalWith` decision tree, which is the clearest statement anywhere of how many optionality
spellings v3 had and why v4 reduced them.
