# 32 — Schemas at Effect parity: one declaration, both directions, a differing wire shape

**Commissioned by** the project owner, 2026-09-21, after reading
[report 31](31-derived-codecs.md): *"We need something as powerful as Effect schemas. That's the
gold standard."* · *"In Effect the schema is both an encoder, decoder and type."* · *"There are two
different types for the same schema. The encoded and decoded. Deriving schema from type is not
enough. Most real life schemas have different representations."* · *"I am starting to lean in the
new syntax camp."* · *"It needs feature parity with Effect schemas, like allowing custom
transformations, etc."*

**Status:** research. It designs and it argues; it does **not** decide, except where the owner
already has. §0.4 lists the decisions: four are the owner's and are marked **DECIDED**, the rest
are open and numbered **K1**–**K16**.

---

## Revision 2 — 2026-09-21

The owner read revision 1 and settled the model. Their words, from
[`plans/queue.md`](../../../plans/queue.md), *Owner decisions on schemas, 2026-09-21*:

> **"We are defining a schema User, not a type User."** · Both types exist from the first cut and
> are reached through the schema, as in Effect: **`User.Type`** and **`User.Encoded`**. · **No
> shorthand**: bare `User` in a type annotation is not the program type; a developer who wants a
> short name writes `type alias Person = User.Type` themselves. · Nothing appears under an invented
> name (no `UserWire`), and no source is generated: the declaration is the only text.

| What changed | Where | Why |
|---|---|---|
| **K4 is superseded** — the declaration no longer declares a type. `schema User = { … }` defines a **schema**, and `User.Type` / `User.Encoded` are reached through it | §0, §4.2 | the owner's decision |
| **K9 is superseded** — there is a wire type after all, it is called `Encoded`, and it is reached through the schema rather than living under an invented name | §0, §4.6 | the owner's decision |
| **K1 is reversed** — `Schema` carries **two** type parameters, `Schema e a`. Revision 1 dropped the wire parameter because a record's and a union's wire side could not be typed; under the owner's model `User.Encoded` has to be a real type anyway, and once it is, the two objections are answerable (§3.2) | §3 throughout | forced by the decision, and it buys the typed pair `decode` / `encode` that makes `Encoded` useful |
| **K2 is amended** — a schema is still reached as `X.schema ()`, but almost no code writes that, because the namespace also holds `X.parse`, `X.read`, `X.write`, `X.decode`, `X.encode` | §0.3, §4.7 | the `()` survives for one verified reason (§4.7) and is now out of the way |
| **A field position holds a SCHEMA, not a type** (new, **K14**) | §4.3 | it is the honest reading of "we are defining a schema", and it simplifies `as` / `via` / `default` into operations on the field's schema |
| **`via` is flipped** relative to the owner's sketch: the field names the **wire** schema and the conversion says what it becomes — `createdAt : Int via Date.millis`, not `createdAt : Date via Date.millis` | §4.4 | under K14 the field position already holds a schema, so `Date` there would mean "the `Date` schema", which is not what the field is on the wire |
| Three new open decisions | §0.4 | **K13** what kind of name `User` is · **K15** what a tagged union's `Encoded` is · **K16** what else the namespace holds |
| Parity re-counted, two rows added, one row moved | §1, §2 | `Schema.flip` becomes expressible; `toType` / `toEncoded` gain rows |
| All worked examples rewritten, and one added | §5 | §5.10 is a v1→v2 migration over **encoded** shapes, which is the example that shows what `Encoded` is for |
| Cost and slice order revised | §8 | the namespace is new resolver work; the library gains a parameter |

**One phrase this revision avoids.** The owner reacted badly to "the compiler generates" and "code
generation", and they are the wrong words. Nothing is generated: **the declaration is the only text
there is**, exactly as a `type` declaration is the only text behind `==`. What the compiler does is
*read* the declaration and know two record types from it — which is not "computing a type from a
value in the type system", the thing the owner's constraints forbid. The distinction matters, so
here it is once, plainly: a type-level computation is a program a *user* writes in the type
language, like TypeScript's `Partial<T>`; what happens here is the compiler reading one declaration
and knowing what it says, like reading `type Colour = Red | Green` and knowing how `==` compares
two colours. The first is a feature of the type system that users program; the second is the
compiler doing its job.

---

**The constraints the owner set, and they bind every line below.** No code generation tools. No
macros. No powerful type-system features — **no higher-kinded types, no type classes, no computing
a type from a value**. beni stays a simple Elm-family language.

**How it was built.** Effect v4's [`SCHEMA.md`](../../../references/effect/packages/effect/SCHEMA.md)
(7 358 lines) was read whole, as the feature inventory; `migration/schema.md`, `ARBITRARY.md` and
`OPTIC.md` were skimmed only as far as they show what is derived *from* a schema. Effect's
implementation was deliberately not read. Every beni sample that is **not** marked `[proposed]` was
parse- and type-checked with the installed `./zig-out/bin/beni` and, where it matters, built and
read back as emitted JavaScript; the transcripts are quoted where a claim rests on one (§3.9,
§4.7, §4.8). The model for how a new syntax is added is [report 28](28-jsx-in-beni.md) §0: sugar
over a plain library form, the plain form stays, the vocabulary belongs to a library and not to the
compiler, and the cost is estimated per compiler phase.

**Vocabulary, once, in plain words.** A **schema** says three things about one kind of data at the
same time: what it looks like *on the wire* (in a JSON payload, a form submission, a `localStorage`
entry), what it looks like *in the program*, and how to get from either to the other. **Reading**
turns a wire value into a program value and can fail. **Writing** turns a program value into a wire
value and cannot. A **wire key** is the name a field has on the wire, which need not be the name it
has in the program: `user_name` on the wire, `name` in the program. A schema's two types are its
**`Encoded`** (the wire shape, as a beni type) and its **`Type`** (the program shape).

---
## 0. The design in two pages

### 0.1 What you write

Two layers, as JSX is two layers in report 28.

**Layer 1 is an ordinary beni library**, `core/Schema`. A `Schema e a` is a value: it holds an
inspectable description of the wire shape, a reader and a writer. `e` is the wire type, `a` the
program type. Nothing in layer 1 is new language — every signature in §3 was checked against
`language.md` as it stands.

**Layer 2 is one new declaration**, `schema`, which the compiler reads. It is the only text there
is; from it you can refer to two types and a handful of values, all under the schema's own name.

Five examples. `[proposed]` marks the declaration; everything else is beni today.

**(1) A record whose wire shape is not its program shape.**

```elm
-- [proposed]
pub schema User =
    { name : String as "user_name"
    , createdAt : Int via Date.millis
    , age : Int default 0
    , email : Email optional
    }
```

**(2) A tagged union.**

```elm
-- [proposed]
pub schema Shape tagged "kind" of
      Circle { radius : Float } as "circle"
    | Rect { w : Float, h : Float } as "rect"
```

**(3) A validated type — its module owns the only constructor, so bad input cannot forge one.**

```elm
-- [proposed], in Email.beni
pub opaque schema Email = String via conversion
```

**(4) A generic container.**

```elm
-- [proposed]
pub schema Page a =
    { items : List a
    , next : String optional
    }
```

**(5) Composition — a field whose type is another schema.**

```elm
-- [proposed]
pub schema Order =
    { id : String
    , buyer : User          -- the `User` schema, not a type
    , total : String via Money.conversion
    }
```

### 0.2 What you can then refer to

Nothing has an invented name. Everything hangs off the schema's own name:

| You write | You can refer to | Which is |
|---|---|---|
| `schema User = { … }` | `User.Type` | `{ name : String, createdAt : Date, age : Int, email : Maybe Email.Type }` |
| | `User.Encoded` | `{ user_name : String, createdAt : Int, age : Maybe Int, email : Maybe String }` |
| | `User.schema` | `() -> Schema User.Encoded User.Type` |
| | `User.parse`, `User.read`, `User.write` | JSON text and `Value` in and out |
| | `User.decode`, `User.encode` | the typed pair, `User.Encoded ↔ User.Type` |
| `schema Page a = { … }` | `Page.Type a`, `Page.Encoded e` | each an ordinary 1-ary type |
| `schema Shape tagged "kind" of …` | `Shape.Type` | `Circle { radius : Float } \| Rect { w : Float, h : Float }` |
| | `Shape.Encoded` | `{ kind : String, radius : Maybe Float, w : Maybe Float, h : Maybe Float }` — §4.6 |
| `opaque schema Email = String via …` | `Email.Type` | an opaque type whose constructor is private to `Email.beni` |
| | `Email.Encoded` | `String` |

**No shorthand, by the owner's decision.** Bare `User` in a type position is not the program type.
A short name is the developer's to make:

```elm
type alias Person =
    User.Type


pub greet : Person -> String
greet p =
    "hello ${p.name}"
```

Checked, exit 0, with a stand-in module: `User.Type` and `User.Encoded` already resolve today as
module-qualified types, and `Page.Type Int` already resolves as an ordinary type application
(§4.8).

### 0.3 Using it

```elm
pub load : String -> Result (List Schema.Issue) (Page.Type User.Type)
load text =
    Schema.parse (Page.schema ()) text


pub toRow : User.Type -> User.Encoded
toRow u =
    User.encode u
```

`Schema.parse (Page.schema ()) text` is how a schema is **composed**; `User.encode u` is how it is
**used**, and most code only ever does the second. The `()` in `Page.schema ()` is not decoration —
§4.7 shows the one verified reason it is there — and it appears only where a schema is passed to
another schema.

### 0.4 The decisions

Four are the owner's and are settled. Twelve are open, numbered so that an id never moves.

---

**DECIDED (owner, 2026-09-21) — the schema is the defined thing.** *"We are defining a schema User,
not a type User."* `schema User = { … }` defines a schema; it does not double as a type
declaration. **This supersedes K4** of revision 1, which said the declaration declares the type
too. The consequence worked through in §4.2: `User` is a *name for a schema*, and the program type
is `User.Type`.

**DECIDED (owner, 2026-09-21) — both types exist, and they are called `Type` and `Encoded`.** As in
Effect. **This supersedes K9** of revision 1, which recommended no wire type at all. Revision 1's
argument — that a caller wanting the wire shape wants it as data — was half right and is answered
in §3.2: the *description* is still data (`Schema.describe`), and the *type* is what makes the
`decode` / `encode` pair, forms, fixtures and migrations typed.

**DECIDED (owner, 2026-09-21) — no shorthand.** Bare `User` is not `User.Type`. A developer who
wants a short name writes `type alias Person = User.Type`.

**DECIDED (owner, 2026-09-21) — nothing under an invented name, and no generated source.** The
declaration is the only text, the way `type` is the only text behind `==`.

---

**K1 — how many type parameters does `Schema` carry? REVERSED in revision 2.** Revision 1 said one
(`Schema a`), because a record's wire type is a mapped type and a union's members must be one type.
Revision 2 says **two**, `Schema e a`.

```elm
pub decode : Schema e a, e -> Result (List Issue) a
pub encode : Schema e a, a -> e
```

*Why the reversal is honest and not obedience:* the owner's decision makes `User.Encoded` a real
type whatever the library does, so the question is no longer *whether* the wire type exists but
whether the library may say it. Once it exists, both revision-1 objections have answers. The record
objection: the compiler reads the declaration and knows both record types — it is not computing one
from the other in the type system — and the hand-written form names its own encoded record and
supplies two extra functions at `build` (§3.4). The union objection: a tagged union's `Encoded` is a
*flattened record*, which is a type (K15, §4.6). And the gain is exactly what the second parameter
is for — the typed `decode` / `encode` pair, without which `Encoded` is a name with nothing to do.
*Cost, stated:* every library signature grows a parameter (`list : Schema e a -> Schema (List e)
(List a)`), and a hand-written record schema writes four functions at `build` instead of two.
*Reversible:* no, cheaply. *Rule 7:* nothing refused.

**K2 — is a schema reached as a value or a nullary function? AMENDED.** Still
`X.schema : () -> Schema X.Encoded X.Type`, and §4.7 gives the one verified reason: `where a.schema`
must be reachable by return-type dispatch, and `a.schema` with no arguments is a field access, not a
method call (`language.md` §6.3) — verified, with the diagnostic quoted. What is new is that the
namespace also holds `parse`, `read`, `write`, `decode`, `encode`, so the `()` appears only when one
schema is passed to another. *Reversible:* yes, if `language.md` §6.3 ever admits a nullary method
call on a constrained type variable. *Rule 7:* the cost is one `()` at a composition site.

**K3 — does every type get a schema automatically, the way it gets `eq`? STANDS.** No. A bodyless
`schema Point` over an existing `type alias Point` asks for the structural one in one line, and
`Point.Type` is then `Point` itself and `Point.Encoded` is its structural wire shape. Against the
automatic version, three reasons, the first a guarantee: **a validated type must not get one** — a
structural default peels `Email.Type` to `String` and wraps unchecked, which is report 31 §4.2's
Roc panic; `eq` has one correct answer where a wire format has many, and a default one silently
becomes a published contract that a field rename changes with no diagnostic; and Roc took the
opt-in route after shipping derivation (report 31 §3.2). *Reversible:* yes, as a relaxation.
*Rule 7:* refuses nothing; the hatch is one line, and the missing-schema diagnostic already exists
and already names the fix (§4.9).

**K4 — SUPERSEDED** by the owner's first decision above. Kept in place so the id never moves.

**K5 — can writing fail? STANDS.** No: `write : Schema e a, a -> Value` and
`encode : Schema e a, a -> e` are both total. The guarantee is *a value you hold can always be
serialised*, and without it every caller that only writes still pays a `Result`. *Rule 7:* what is
refused is a conversion whose writing direction can fail, which says the program type admits values
the wire cannot represent — a gap in the type, whose honest fix is to make those values
unconstructible. **Flag this as the decision most likely to want revisiting**; under two parameters
it is also more visible, because `encode`'s result type is now written down.

**K6 — JSON only, or format-neutral? STANDS.** Format-neutral: one `Value` tree, with JSON text, a
port payload, form data and query strings as adapters into it. The two-parameter shape sharpens
this: `Encoded` is the *typed* wire shape and `Value` the *untyped* one, and the two steps are
separately available (`readEncoded`, `writeEncoded`, §3.3), which is what makes §5.10's migration
possible.

**K7 — does `core` ship `Schema`, and is JSON text parsing `foreign`? STANDS.** Yes and yes. The
well-known table (§4.9) must answer `schema` for `Int`, `String`, `List a`, and can only point at
core; rule 6 says only core may write `foreign`, so if core does not ship `JSON.parse` nobody can.
`core/Json.js` wraps it in `try`/`catch` and returns a `Result`, per
[`boundary.md`](../boundary.md) §4.1.

**K8 — are ports re-specified on this? STANDS, and is now stronger.** A port's payload gains a
*typed* `Encoded`, so the port's JavaScript side has a shape the compiler can name — which the
existing generator cannot express at all. Still slice S6, still conditional on measuring a
`readForeign` fast path against the generator (§8.5).

**K9 — SUPERSEDED** by the owner's second decision above. Kept in place.

**K10 — may a transformation perform an effect while reading? STANDS.** Conditionally, and the
condition is a question the effects spec has not answered: `transparent-effects-proposal.md` §1
makes `suspends` part of a function's type, and a `Schema e a` stores its reader in a *field*, not
a parameter — §2's bit-polymorphism promise covers higher-order *parameters* and does not discuss
fields. Until that has a position, layer 1 is sync-only and enrichment is a pass over the decoded
value (§5.7 argues that is the right shape anyway).

**K11 — what does a wire number past 2⁵³ do? STANDS.** Refuse it with an ordinary `Refused` issue;
the hatches are `Int32` and a `Schema.bigText` that keeps the digits as a `String`.

**K12 — what happens to a wire key the schema does not mention? STANDS.** Ignore by default,
`Reject` available, preserve not offered — a beni record is closed, so preserving means a declared
`List ( String, Value )` field.

**K13 — NEW: what kind of name is `User` after `schema User = { … }`?** `User.Type` lexes today as a
single `qualified_upper` token and resolves as "the type `Type` in the module aliased `User`"
(verified, §4.8). So a schema name must behave like a module alias.

*Options:* **(a)** a **nested namespace** in the declaring module, visible unqualified in that file
and reachable from outside through `exposing (User)`; **(b)** (a) plus full qualification
`Models.User.Type`, which needs `resolveQualified` to split at more than the last dot; **(c)** **the
module is the namespace** — one schema per file, `User.beni` holding the declaration and no name on
it, so `User.Type` is an ordinary module-qualified type and **no compiler change is needed at all**
(verified today, §4.8).
*Recommendation:* **(a)**, with (c) named as the fallback if the resolver cost is unwelcome — (c)
costs zero compiler work and buys one-schema-per-file, which is a real constraint on a module that
naturally holds `Hit` and `HitPage` together. (b) is (a) plus a second dot-splitting rule and
should wait until someone wants it.
*Reversible:* (a) → (b) is additive; (a) → (c) is not.
*Rule 7:* under (a), a `schema User` in a file that also has `import User` is refused
(`duplicate_import_alias`); nothing else is withheld.

**K14 — NEW: does a field position hold a type or a schema?**

```elm
-- [proposed]
pub schema Order =
    { buyer : User }        -- the `User` SCHEMA, or the type `User.Type`?
```

*Options:* **(a)** a schema — `User` there names the schema, and the field's two types are
`User.Type` and `User.Encoded`; **(b)** a type — `buyer : User.Type`, and the compiler looks up
"the schema for `User.Type`" through the well-known method.
*Recommendation:* **(a)**, and it is the honest reading of "we are defining a schema". Three things
follow, and all three are simplifications: `String`, `Int`, `List a` in a field position are
*schemas* under those names, so `name : String` needs no lookup at all; `as`, `via` and `default`
become **operations on the field's schema** rather than three unrelated keywords (§4.4); and a type
with **two** schemas — the v1/v2 case of §5.9, which is the case "derive the schema from the type"
cannot do — stays reachable inside a declaration, because the field names the schema it means.
Under (b) the second wire form is unreachable from any declaration.
*Reversible:* no, cheaply — it is the reading of every declaration body.
*Rule 7:* what (a) refuses is naming a bare program type in a field position when that type has no
schema; the diagnostic says so and names `schema T` as the fix.

**K15 — NEW: what is a tagged union's `Encoded`?** The tag's text (`"circle"`) cannot be a beni
type, and beni has no structural sum type, so the encoded side of a union cannot mirror its shape.

*Options:* **(a)** a **flattened record** — the tag key as `String`, then every field of every
variant, each `Maybe` because only one variant's fields are present at a time; **(b)** `Value`,
untyped; **(c)** a second nominal type with the same constructor names, reached through a nested
namespace (`Shape.Encoded.Circle`), which lexes but needs a naming scheme nobody asked for.
*Recommendation:* **(a)**, with the rule that two variants sharing a field name must agree on its
encoded type or the declaration is refused. It is a real type, it is the actual wire shape of a
flat tagged union, and it is what a form, a fixture and a migration want. Checked, exit 0 (§4.6).
*What is lost relative to Effect:* the correlation between the tag and which fields are present is
not in the type — `{ kind = "circle", w = Just 3 }` type-checks and the reader refuses it. Effect
keeps that correlation because TypeScript has discriminated unions of object types; beni does not,
and that is a fact of the language rather than of this design.
*Reversible:* yes; (a) → (c) is additive.
*Rule 7:* the refusal is the field-name disagreement, and it buys a type that cannot lie about a
field's wire type. The hatch is to rename one variant's field with `as`.

**K16 — NEW: what else does the namespace hold besides the two types?**

*Options:* **(a)** `schema` only, so every use is `Schema.parse (User.schema ()) text`; **(b)**
`schema` plus `parse`, `read`, `write`, `decode`, `encode`.
*Recommendation:* **(b)**. It is five names, each a one-line application of `schema`, and it is what
makes the common case read like the thing it is — `User.encode u`, `User.parse text` — while the
`()` retreats to composition sites. It also makes K13(c) attractive, because under (c) these are
literally ordinary `pub` values of a module and the whole declaration is sugar for text somebody
could have written.
*Reversible:* yes, additively.
*Rule 7:* nothing refused; every one of the five is writable by hand over `X.schema ()`.

---

## 1. What "parity" means here

**Parity means every capability in `SCHEMA.md` is answered.** §2 walks the document section by
section and gives each capability one of five answers — **same** (beni does it, spelled much as
Effect does), **different** (beni does it, spelled differently; the row shows the spelling),
**not needed** (the capability exists because of JavaScript or TypeScript and has no beni
referent), **cannot** (not expressible under the owner's constraints; the row says what is lost),
**help** (needs something from the language; the row says what) — and says where it lives: **D**
the `schema` declaration, **L** the library, **B** both, **—** nowhere.

**The counts, revision 2. 164 rows: same 43, different 67, not needed 38, cannot 14, needs
language help 2.** Two rows are new (163, 164) and one moved from *not needed* to *same* (105),
all three because `Encoded` is now a type the library can name. The sixteen non-routine rows are
collected in §2.15 so they can be read without the table, together with the eight things the
*compiler* must supply or the owner must decide, which are a different list and are numbered
**H1**–**H8**.

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
| 7 | `Schema.Literals([…])` (L274) | a closed set of strings | **different** — `Schema.enumerated : List ( String, a ) -> Schema String a`, which maps wire strings onto a beni custom type's constructors, exhaustively | B |
| 8 | `Schema.UniqueSymbol` (L256) | a symbol literal | **not needed** | — |
| 9 | `.literals` / `.members` accessors (L282) | read the set back out | **different** — `Schema.describe` returns a `Node`, and `ChoiceNode` carries the tags | L |
| 10 | `.check(isMinLength …)` and the eight other string checks (L296) | constrain a string | **same** — `Schema.checked`, plus the same named checks as library values | L |
| 11 | `SchemaTransformation.trim()` / `toLowerCase` / `toUpperCase` (L314) | normalise on read | **same** — `Schema.trimmed`, `Schema.lowercased`, `Schema.uppercased` | L |
| 12 | `isUUID` / `isBase64` / `isBase64Url` (L324) | common string formats | **same** — the same names as checks | L |
| 13 | number checks `isBetween`/`isGreaterThan`/… (L336) | constrain a number | **same** | L |
| 14 | `Schema.Finite` (L341) | not NaN, not infinity | **same** — `Schema.finite`; note the well-known table already records that `Float`'s `compare` is not a total order on NaN (spike §3.2) | L |
| 15 | `isInt()` / `isInt32()` (L358) | whole numbers | **different** — `Schema.int` is a schema, not a check, because beni's `Int` is a type; `Schema.int32 : Schema Int32` for the 32-bit one | L |
| 16 | BigInt filter factories `makeIsBetween(order)` (L369) | build checks for an ordered type | **different** — one generic `Schema.between : Schema e a, a, a -> Schema e a where a.compare : a, a -> Order`; static dispatch makes the `order` argument unnecessary | L |
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
| 29 | manual decoding defaults via `decodeTo` (L765) | a fallback rule more specific than "missing" | **different** — `Schema.recovered : Schema e a, (List Issue -> Maybe a) -> Schema e a` | L |
| 30 | `OptionFromOptionalKey` and its two siblings (L855) | optional field as an `Option` | **same** — this *is* beni's only spelling; `Maybe` is not an alternative to absence, it is how absence is represented | B |
| 31 | `annotateKey({description, messageMissingKey})` (L993) | document one key, and name its missing-key error | **different** — `-- |` doc comments on a declaration field feed `NamedNode`; a custom missing-key message is `Schema.expecting` in layer 1 | B |
| 32 | `messageUnexpectedKey` (L1018) | custom message for an excess key | **different** — a field of `Options`, not an annotation, because it is one message per build and not per schema | L |
| 33 | `onExcessProperty: ignore \| error` (L1039) | what to do with keys nobody claimed | **same** — `Options.unknown = Ignore \| Reject` (K12) | L |
| 34 | `StructWithRest` / index signatures (L1046) | fixed keys plus any others | **different** — a declared field of type `List ( String, Value )` with `Schema.rest`; beni records are closed, so the catch-all has to be somewhere the type can see it | B |
| 35 | `encodeKeys({userId: "user_id"})` (L1108) | rename keys on the wire only | **different** — `as "user_id"` on the field. This is the single most-wanted row in report 31 §4.1 | D |
| 36 | reusing fields by spreading `.fields` (L1140) | share a group of fields between types | **different** — a nested record field (`meta : Timestamps`), or write the group out. See row 37 | B |
| 37 | `mapFields(Struct.pick([…]))` (L1189) | a new schema keeping some fields | **cannot** — the result's decoded type is a record type nobody declared, and beni cannot compute a type from a type. Lost: deriving `UserSummary` from `User` mechanically. Mitigation: declare the second type and its schema; §4.11 names a later `schema B from A` sugar that copies the field list (syntax over syntax, not a type computation) | — |
| 38 | `Struct.omit` (L1213) | as above, dropping fields | **cannot**, same reason | — |
| 39 | `Struct.assign` / `fieldsAssign` (L1233) | add fields to a struct schema | **cannot**, same reason | — |
| 40 | `unsafePreserveChecks` (L1265) | keep whole-struct filters across a field map | **not needed** — rows 37–39 do not exist | — |
| 41 | `Struct.evolve` (L1295) | change one field's schema | **cannot** — and `Schema.atField : Schema e a, String, (Schema ex ax -> Schema ex ax) -> Schema e a` cannot be typed either, because `x` is not known | — |
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
| 54 | `Schema.Record(key, value)` (L1780) | a dictionary with dynamic keys | **different** — `Schema.dict : Schema e a -> Schema (List ( String, e )) (List ( String, a ))`, plus `Schema.dictInto : Schema e a -> Schema (List ( String, e )) (Dict String a)` when an ordered map is wanted | L |
| 55 | record key transformations (`snakeToCamel`) (L1786) | rewrite dynamic keys | **different** — `Schema.dictKeys : Schema (List ( String, a )), (String -> String), (String -> String) -> …`. Effect's duplicate-key rule (last write wins, completion order under concurrency) becomes a stated rule: **beni keeps the first** and reports the collision as an `Issue`, because "last one wins" is a silent wrong answer | L |
| 56 | number keys (L1823) | `{1: "a"}` | **different** — the key schema is a conversion; keys are strings on the wire in every format | L |
| 57 | literal struct from `Record(Literals, v)` (L1871) | a fixed key set from a union | **not needed** — that is a record, which beni declares directly | — |

### 2.4 Unions (L1931–L2233)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 58 | `Schema.Union([A, B])`, first match wins (L1931) | a value that is one of several shapes | **different** — `Schema.oneOf : List (Attempt e a) -> Schema e a`, where an `Attempt` pairs a schema with a constructor of the *one* beni type the union decodes into. TypeScript's structural union has no beni referent; a beni union is a declared custom type | B |
| 59 | excluding incompatible members / one message (L1939) | a readable error for a failed union | **same** — the `Issue` list names the tag key and the tags it knows (§3.6) | L |
| 60 | exclusive union `{mode: "oneOf"}` (L1980) | exactly one member may match | **different** — `Schema.exactlyOneOf`, same list, different rule. Cheap, so worth having | L |
| 61 | `Union.mapMembers` (L1997) | derive a union schema | **cannot** — computed union type | — |
| 62 | union of literals (L2068) | a closed string set | **different** — row 7's `Schema.enumerated` | B |
| 63 | `Schema.TaggedUnion({A: {…}})` (L2108) | discriminated union with `_tag` | **different** — `schema T tagged "kind" = …`; the discriminator key is named because real APIs use `type`, `kind`, `op`, not `_tag` | D |
| 64 | `toTaggedUnion` with `cases` / `discriminants` / `isAnyOf` / `guards` / `match` (L2135) | work with the variants after the fact | **not needed** — `case` is the matcher, the compiler proves it exhaustive (`checker.md` §6.6), and pattern matching is not a library feature in beni | — |

### 2.5 Recursion (L2235–L2313)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 65 | `Schema.suspend(() => Category)` (L2235) | a schema that refers to itself | **same** — `Schema.deferred : (() -> Schema e a) -> Schema e a`, and because of K2 the argument is the schema function itself: `Schema.deferred commentSchema`. Effect needs `suspend` for TypeScript's sake; beni needs it because `language.md` §7 refuses a cyclic top-level *value* — a different reason for the same combinator (§5.5) | L |

### 2.6 Declaring custom types (L2315–L2521)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 66 | `Schema.declare(isX)` (L2319) | teach Schema a type it cannot see into | **different** — `Schema.custom : Node, Reader e a, (a -> e) -> Schema e a`. There is no type guard, because beni has no `unknown` to guard against: the only untyped input is `Value` | L |
| 67 | `expected: "URL"` annotation (L2351) | a readable name in the error | **same** — `Schema.expecting : Schema e a, String -> Schema e a` | L |
| 68 | `toCodecJson` annotation + `Schema.link` (L2371) | give an opaque type a JSON form | **not needed** — every beni schema *is* its own wire description; there is no "opaque type with no wire form" to bridge to | — |
| 69 | `Schema.declareConstructor` (parametric) (L2440) | a schema factory for `Box<A>` | **different** — an ordinary function `boxSchema : () -> Schema (Box.Encoded e) (Box.Type a) where a.schema : () -> Schema e a`. Effect's curried two-step call exists to fix TypeScript's inference; beni's `where` clause does the same job in the annotation (§5.4) | L |
| 70 | `Schema.instanceOf(URL)` (L2349) | shorthand for a class guard | **not needed** — no classes | — |

### 2.7 Validation — filters and refinements (L2523–L2919)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 71 | `.check(makeFilter(p))` (L2523) | reject values the type admits | **same** — `Schema.checked : Schema e a, String, (a -> Bool) -> Schema e a` | L |
| 72 | filter `title` / `description` / `message` (L2543) | say what failed | **different** — one `String` message, because `title`/`description`/`message` is a three-way split beni has no reader for | L |
| 73 | the identifier-vs-`expected`-vs-`message` precedence rule (L2562) | which label a formatter shows | **not needed** — one message, no precedence to specify | — |
| 74 | filter return shapes: `true`/`false`/`string`/`Issue`/`{path,issue}`/array (L2591) | rich failures from one predicate | **different** — two functions instead of six shapes: `Schema.checked` (a `Bool`) and `Schema.judged : Schema e a, (a -> List Issue) -> Schema e a` (an empty list is success). Row 74's `{path,issue}` case — "password and confirmPassword must match" *at* `["password"]` — is what `judged` exists for | L |
| 75 | schema type preserved after filtering (L2643) | `.fields` still reachable after `.check` | **not needed** — beni has no method-carrying schema type; `describe` reads through checks | — |
| 76 | filters as first-class, reusable across types (L2682) | `isMinLength` on strings *and* arrays | **different** — `isMinLength` is structural polymorphism over "anything with a length", which beni cannot say; it gets `String.length` and `List.length` checks separately, or one check over a `where a.length : a -> Int` clause, which is the static-dispatch answer | L |
| 77 | `{errors: "all"}` (L2726) | collect every failure | **same** — `Options.report = AllOf \| FirstOnly` | L |
| 78 | `.abort()` on a filter (L2750) | stop after this one fails | **different** — `Schema.abortingCheck`, same idea | L |
| 79 | `makeFilterGroup` (L2774) | a reusable bundle of checks | **different** — an ordinary function `Schema e a -> Schema e a`; beni composes functions, so a "group" needs no type | L |
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
| 93 | transformations are first-class reusable values (L3153) | define `trim` once, use everywhere | **different** — `pub type alias Conversion e a = { from : e -> Result String a, to : a -> e }`, an ordinary record that carries **both** sides. This is what `via` takes (§4.4) | B |
| 94 | `Transformation<T,E,RD,RE>` and five `Getter` kinds (L3197) | the transformation type | **different** — one `Conversion`. Effect's `TransformOptional` exists for `undefined`; `TransformEffect` is K10; `Passthrough` is `identity` | L |
| 95 | `composeTransformation` (L3245) | chain two conversions | **different** — `Schema.composed : Conversion e b, Conversion b a -> Conversion e a`, or just compose the functions by naming the argument (`language.md` §0 removed `>>`) | L |
| 96 | `decodeTo(target, transformation)` (L3279) | read into a *different* schema | **different** — `Schema.mapped : Schema ei e, (e -> a), (a -> e) -> Schema ei a` | L |
| 97 | `decode(transformation)` (L3310) | same type, transformed | **different** — `Schema.mapped` with the same type | L |
| 98 | inline `transform({decode, encode})` (L3325) | a one-off total conversion | **same** — `Schema.mapped` | L |
| 99 | `transformEffect` — fallible or async (L3349) | a conversion that can fail | **help** — the fallible half is `Schema.tried : Schema ei e, (e -> Result String a), (a -> e) -> Schema ei a`, reading may fail and writing may not (K5); the **async** half is K10, which is why this row is not simply `different` | L |
| 100 | schema composition by chaining `decodeTo` (L3373) | metres → kilometres → miles | **same** — `Schema.mapped` over a `Schema.mapped` | L |
| 101 | `passthrough` / `passthroughSubtype` / `passthroughSupertype` (L3405) | compose when the two sides nearly line up | **not needed** — all three exist to negotiate TypeScript subtyping; beni unifies or it does not | — |
| 102 | `{strict: false}` (L3464) | turn the above off | **not needed** | — |
| 103 | `transformOptional` (L3487) | a conversion that may produce no value | **different** — the `Maybe` field combinators (row 24) cover the cases that survive | L |
| 104 | `Getter.omit()` / `tagDefaultOmit` (L3549) | drop a key when writing | **different** — `Schema.omittedWhen : Schema e a, (a -> Bool) -> Schema e a` as a field modifier; the common case (a tag that is implied) does not arise, because beni's tag is the constructor | L |
| 105 | `Schema.flip(schema)` (L3605) | swap the two directions | **same** — `Schema.flipped : Schema e a -> Schema a e`. **Moved from *not needed* in revision 1**, where there was no second parameter to swap; with both sides typed, swapping them is meaningful and is what an encoding-direction validator wants | L |
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
| 124 | `fromJsonString(schema)` (L4654) | parse and validate in one | **same** — `Schema.parse : Schema e a, String -> Result (List Issue) a` | L |
| 125 | `StringFromBase64` / `Base64Url` / `Hex` / `UriComponent` (L4674) | string encodings | **same** — the same four as `Conversion` values | L |
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
| 143 | `SchemaRepresentation` — inspect a schema structurally (L5920) | see what a schema says | **same** — `Schema.describe : Schema e a -> Node`, and §6 argues this is why the description must be data | L |
| 144 | `toJson` / `fromJson` of a representation (L6125) | store a schema, send a schema | **same** — `Node -> Value` works; the other direction is row 145 | L |
| 145 | `fromRepresentation` + revivers (L6148) | rebuild a runtime schema from stored JSON | **cannot** — rebuilding yields a `Schema e a` whose `e` and `a` came from the data, which is computing a type from a value. Lost: schema-over-the-wire, and runtime schema registries. Mitigation: the *description* still travels (row 144) and can be rendered, diffed and validated against; only the typed reader cannot be rebuilt | — |
| 146 | `fromJsonSchemaDocument` — import JSON Schema (L6259) | consume someone's OpenAPI | **cannot** at run time, though available as a tool — an external generator that writes `schema` declarations into a file is not a language feature and is not forbidden; it is the same thing `json2elm` and `swagger-elm` are, and report 31 §2 shows every Elm shop built one. **Difference from Elm: here the generator's output is one declaration per type rather than two hand-maintained functions** | — |
| 147 | `toCodeDocument` — generate source from a schema (L6324) | codegen | **same** — outside the language, as row 146 | — |
| 148 | `Arbitrary.schema` — test data (`ARBITRARY.md` L758) | property-based testing | **different** — `Schema.sample : Schema e a, Seed -> ( a, Seed )` over `Node`; report 17 §4.9 already has a seeded PRNG that is `pure`. Shrinking is a later, separate concern | L |
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
| 157 | `middlewareDecoding` (L6761) | wrap the whole read | **different** — `Schema.around : Schema e a, (Reader e a -> Reader e a) -> Schema e a`, one function, which is what a middleware is | L |

### 2.14 Type machinery and tooling (L6768–L7051, L40–L198)

| # | Effect | What it is for | beni | Where |
|---|---|---|---|---|
| 158 | `resolveAnnotations`, user-extensible annotation keys (L6926) | attach arbitrary metadata | **different** — a closed `Node` with a `NamedNode String Node` and an `ExtraNode String Value` case; open extension by module augmentation is a TypeScript feature | L |
| 159 | `resolveAnnotationsKey` — key-level annotations (L6983) | metadata on a field position | **same** — `ObjectNode` carries a per-field record | L |
| 160 | separate `RD` / `RE` requirement parameters (L7004) | decoding needs a DB, encoding does not | **not needed** — and under K10 it is the same question — beni's two inferred bits are per function, and a reader and a writer are two functions, so the split falls out without being written | — |
| 161 | `Schema.is` / `asserts` type guards (L6170, migration L42) | narrow an `unknown` | **not needed** — there is no `unknown` in beni. `Schema.is : Schema e a, Value -> Bool` is one line if anyone wants it | L |
| 162 | JIT / AOT schema compilers (L68) | make parsing fast | **different** — beni compiles ahead of time by construction; the analogue is `--release` turning a schema value into a specialised reader (§8.3), which needs no `new Function` and works where CSP forbids one | — |
| 163 | `Schema.toType(schema)` (L418, L5997, migration L18) | the schema with its transformations stripped, on the program side | **same** — `Schema.typeOnly : Schema e a -> Schema a a`. **New in revision 2**: revision 1 had no second parameter, so there was no projection to make | L |
| 164 | `Schema.toEncoded(schema)` (L458, L5925, migration L17) | the same, on the wire side — validate a payload without running any conversion | **same** — `Schema.encodedOnly : Schema e a -> Schema e e`. **New in revision 2**, same reason; it is §5.10's first step done strictly | L |

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
**declare the second type and its schema.** §4.11 names a later `schema Summary from User = …`
that copies *annotations* from another declaration — syntax over syntax, not a type computation, so
it is available if the duplication proves painful. It is deliberately not in this design.

**What the compiler must supply, or the owner decide (8).** A different list from the two above:
these are not capabilities, they are the work and the open questions.

| # | What is needed | Who owns it |
|---|---|---|
| H1 | the `schema` declaration: one new top-level form, grammar, lowering, formatter, diagnostics | §4, §8.1 |
| H2 | `schema` as a well-known method with a compiler table for primitives and core containers, on the `eq`/`compare` model. Needed only for HAND-WRITTEN generic schemas: inside a declaration a field names its schema outright (K14) | §4.9 |
| H3 | `constrained_constant` extended to *annotated* declarations, or K2 taken — because today an annotated nullary declaration with a `where` clause is an exit-0 miscompile | §3.9 — **a `master` defect, independent of this report** |
| H4 | a position on whether a function's `suspends` bit is polymorphic when the function is a *field of a record*, not a parameter | K10, §3.7 |
| H5 | (only if the owner wants library-level renames) a compiler-checked field reference, so `Schema.rename .name "user_name"` can be checked. **Recommend not doing it** — §3.4 | — |
| H6 | (only for the ten type-computation "cannot" rows) type-level record operations. **Recommend not doing it** | §2.15 |
| H7 | a decision on `Int` past 2⁵³ at the boundary — a rule, not a feature | K11 |
| **H8** | **new in revision 2** — the schema namespace: `resolveQualified` consulting a schema table before the import aliases, a namespace section in the interface, and `exposing` admitting a namespace name. **Zero under K13(c)** | K13, §4.8, §8.1 |

---

## 3. The library layer, designed

### 3.1 The core types

```elm
--| What a wire value looks like, whatever the format. The UNTYPED wire side.
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


--| The inspectable description of the wire shape.
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


--| `e` is the TYPED wire side, `a` the program side.
pub opaque type Schema e a
    = Schema
        { node : Node
        , decode : e -> Result (List Issue) a
        , encode : a -> e
        , fromValue : Value -> Result (List Issue) e
        , toValue : e -> Value
        }


--| A two-way conversion that carries both sides, which is what lets the
--| compiler read a field's `Encoded` type off a `via`.
pub type alias Conversion e a =
    { from : e -> Result String a
    , to : a -> e
    }
```

**Three levels, not two, and that is what the second parameter buys.** `Value` is the untyped wire
(what `JSON.parse` gives you). `e` is the *typed* wire — `User.Encoded`, a beni record whose fields
are named as the wire names them. `a` is the program value. A schema knows both steps separately:
`fromValue`/`toValue` is the structural step (field names, shapes, primitive types) and
`decode`/`encode` is the transformation step (`via`, defaults, validated constructors). Effect
draws the line in the same place, and it is why `Encoded` is useful rather than decorative: §5.10's
v1→v2 migration runs entirely on the wire side and never builds a program value.

**`Schema e a` is opaque, not a `type alias` for the record.** Under `language.md` §6.3 and spike
§1.2, `x.m a` on a *record* is a field call and on a *nominal* type is a method call. Opaque makes
`s.checked "…" f` dispatch to `Schema.checked`, which is what gives the library the dot-call
ergonomics of §3.8 — and it keeps the five fields private, so `Schema.custom` is the only way to
build an inconsistent one.

**`Node` stays.** The *type* says what the wire shape is to the type checker; the *description*
says what it is to a program that wants to read it (§6). A JSON-Schema document, a form and a
fixture generator all want data, and a type is not data.

### 3.2 Two parameters: revision 1's objections, answered (K1)

Revision 1 dropped the wire parameter for two reasons and a third worry. Here they are again, with
what changed.

**Objection 1 — a record's wire type is a mapped type.** The wire side of
`{ name : String, createdAt : Date }` is `{ user_name : String, createdAt : Int }`, and *computing*
the second from the first is `Partial<T>`-shaped type-level programming, which beni does not have
and the owner forbids. **Still true, and no longer the question.** Under the owner's model the
declaration states both, and the compiler reads them — one declaration, two record types, the same
way `type Colour = Red | Green` gives the compiler everything it needs to compare two colours.
Nothing in the *type system* computes anything. A **hand-written** schema names its own encoded
record and supplies two more functions at `build` (§3.4), so nothing is derived there either.

**Objection 2 — a union's members must be one type.** `choice "kind" [ circleVariant, rectVariant ]`
needs a homogeneous list, and the variants' payloads differ. **Answered by K15**: the union's
encoded side is a single flattened record, so `Schema Shape.Encoded Shape.Type` is one type and the
per-variant payload types stay erased inside the closures exactly as in revision 1 (§3.5).

**Worry 3 — it doubles every signature.** True, and it is the price. `list : Schema e a -> Schema
(List e) (List a)` is longer than `list : Schema a -> Schema (List a)`, and a hand-written record
schema writes four functions where revision 1 wrote two. What is bought is the pair that makes
`Encoded` mean anything:

```elm
pub decode : Schema e a, e -> Result (List Issue) a
pub encode : Schema e a, a -> e
```

Without them `User.Encoded` is a name the type checker knows and no function accepts. With them a
form can hold `User.Encoded`, a fixture can be written as `User.Encoded`, a database row can be
`User.Encoded`, and a migration can rewrite `V1.Encoded` into `V2.Encoded` without ever
constructing a program value — which is §5.10, and which is the concrete answer to "what is
`Encoded` for".

**One naming trap, found by the checker.** `e` is a prelude *value* (Euler's number), so a
parameter may not be named `e`: `decode (Schema s) e =` is `SHADOWING`. As a *type* variable `e` is
fine — type variables are a different namespace. The library names the value `enc`.

### 3.3 Running a schema

```elm
pub describe : Schema e a -> Node
pub decode : Schema e a, e -> Result (List Issue) a       -- typed wire  -> program
pub encode : Schema e a, a -> e                           -- program     -> typed wire
pub readEncoded : Schema e a, Value -> Result (List Issue) e   -- Value  -> typed wire
pub writeEncoded : Schema e a, e -> Value                 -- typed wire -> Value
pub read : Schema e a, Value -> Result (List Issue) a     -- both steps
pub write : Schema e a, a -> Value                        -- both steps
pub parse : Schema e a, String -> Result (List Issue) a   -- JSON text
pub print : Schema e a, a -> String
pub is : Schema e a, Value -> Bool
pub explain : List Issue -> String
```

`read` is `readEncoded` then `decode`; `write` is `encode` then `writeEncoded`. Both pairs are
public because the halves are separately useful, and §5.10 is the example that needs the halves.

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
pub readWith : Schema e a, Options, Value -> Result (List Issue) a
pub parseWith : Schema e a, Options, String -> Result (List Issue) a
```

`maxDepth` is [`boundary.md`](../boundary.md) §3.1's depth bound promoted to a field, doing the same
job for the same reason: *"a decoder that recurses past the bound fails as a value rather than as a
stack overflow."* Default 512.

`Schema.readForeign : Schema e a, Options, Foreign -> Result (List Issue) a` reads an
already-parsed JavaScript value without building a `Value` tree; it is the fast path K8 needs and
is the one place the library asks core for help.

### 3.4 Primitives, composites, and the crux

```elm
pub string : Schema String String
pub int : Schema Int Int
pub float : Schema Float Float
pub bool : Schema Bool Bool
pub value : Schema Value Value
pub literal : String -> Schema String ()
pub enumerated : List ( String, a ) -> Schema String a
    where a.eq : a, a -> Bool

pub list : Schema e a -> Schema (List e) (List a)
pub nullable : Schema e a -> Schema (Maybe e) (Maybe a)
pub dict : Schema e a -> Schema (List ( String, e )) (List ( String, a ))
pub pair : Schema e1 a1, Schema e2 a2 -> Schema ( e1, e2 ) ( a1, a2 )

pub object : Schema () ()
pub field : Schema er ar, String, Schema ex ax -> Schema ( er, ex ) ( ar, ax )
pub optionalField : Schema er ar, String, Schema ex ax -> Schema ( er, Maybe ex ) ( ar, Maybe ax )
pub defaulted : Schema er ar, String, Schema ex ax, ax -> Schema ( er, Maybe ex ) ( ar, ax )
pub rest : Schema er ar, String -> Schema ( er, List ( String, Value ) ) ( ar, List ( String, Value ) )
pub build : Schema er ar, (ar -> a), (a -> ar), (er -> e), (e -> er) -> Schema e a
```

**The crux — building a record schema by name — is unchanged and still needs no language feature.**
A left-nested accumulator: `object` is the empty record, each `field` grows it by one, and `build`
closes it. Under two parameters the accumulator carries *both* sides — `( er, ex )` and
`( ar, ax )` — and `build` takes **four** functions instead of two: a pair between the accumulator
and the program record, and a pair between the accumulator and the encoded record. Checked, exit 0:

```elm
pub schema : () -> Schema Encoded Type
schema () =
    Schema.object
        |> Schema.field "user_name" Schema.string
        |> Schema.defaulted "age" Schema.int 0
        |> Schema.build
            (\( ( (), n ), a ) -> { name = n, age = a })
            (\u -> ( ( (), u.name ), u.age ))
            (\( ( (), n ), a ) -> { user_name = n, age = a })
            (\w -> ( ( (), w.user_name ), w.age ))
```

No arity family and no cap — a cap would be a rule-7 restriction bought for nothing, and Elm's
`mapN` stopping at 8 is the prior art everyone has hit. `( ( (), n ), a )` is an ordinary nested
tuple pattern in a lambda parameter, which `language.md` §3's `LetPattern` admits.

**The three candidates, and why this one.** *(a) Only the compiler may make record schemas* —
rejected: it breaks report 28 §0's rule that the sugar must desugar into a form that stays
available, it makes a second wire form unwritable (§5.9), and the library could not be tested
without the declaration. *(b) A rescript-schema builder*,
`Schema.record (\s -> { id = s.field "Id" Schema.float, … })` — the type system **can** type
`s.field`; what stops it is the run time, in three places, and the first is a guarantee:
`s.field "Id" Schema.float` must return a `Float` that is not a float, so
`s.field "a" Schema.float + 1.0` type-checks and gives a silent wrong answer (rule 7's forbidden
class — tracing the construction is otherwise fine, since running the lambda once is a pure call);
the library would then have to *inspect* the record it got back to learn which field each sentinel
landed in, and beni has no reflection (`Debug.toString` is the nearest thing and `--release`
refuses a build that reaches `Debug` at all, `backend.md` §9; records are plain objects with sorted
keys, `backend.md` §4); and only core may write `foreign` (rule 6), so a library needing either
capability cannot be an ordinary package. *(c) The accumulator* — recommended, above.

**Where a hand-written call can still go wrong.** Two adjacent fields of the same type, swapped in
one of the four lambdas, and nothing complains. That is elm-codec's bug reduced from "every field,
every time" to "one seam". Two things answer it: a declaration is **one** field list, and all four
lambdas are read off that one list, so there is nothing for them to disagree about; and
`Schema.roundTrips` (§7.2) is a one-line test that catches it when they are hand-written. The four-function seam is *wider* than revision 1's two-function
seam, which is an honest cost of K1 and another reason the declaration is the recommended surface.

**Adjustment after the fact (H5).** `Schema.rename : Schema e a, String, String -> Schema e a`
would take two bare strings, and a key that is not there would be a silent no-op. **Recommend not
shipping it**: the declaration covers renaming, and the second wire form is written out (§5.9).
`Schema.rename .name "user_name"` would be checkable only with a field-name literal kind — a type
computed from a value. **Recommend not doing that either.**

### 3.5 Tagged unions, and where erasure is forced

```elm
pub opaque type Variant e a
    = Variant
        { tag : String
        , node : Node
        , decode : e -> Result (List Issue) a
        , encode : a -> Maybe e
        }


pub variant : String, Schema ex ax, (ax -> a), (a -> Maybe ax), (ex -> e), (e -> Maybe ex) -> Variant e a
pub choice : String, List (Variant e a) -> Schema e a
pub attempt : Schema ex ax, (ax -> a), (a -> Maybe ax), (ex -> e), (e -> Maybe ex) -> Attempt e a
pub oneOf : List (Attempt e a) -> Schema e a
pub exactlyOneOf : List (Attempt e a) -> Schema e a
```

`variant` takes the wire tag, the payload's schema, a constructor and a matcher on the program
side, and a pair that lifts the payload's encoded record into and out of the union's flattened
encoded record. Reading: find the tag, run that variant's reader, apply the constructor. Writing:
try each matcher in order and write the first that answers; the declaration's version is total by
construction, because it covers every constructor.

**The payload types stay erased.** `type Variant e a = Variant String (Schema ex ax) …` leaves `ex`
and `ax` unbound, which is `unbound_type_variable` (`language.md` §7) — existential quantification,
which beni does not have and should not get. `variant` closes over the payload schema when it
builds the four functions, and the *description* survives in `node`. Note what the second parameter
did **not** cost here: `e` is the union's flattened record (K15), one type for every member, so the
list is homogeneous. Revision 1's second objection to two parameters was precisely this, and K15 is
what dissolves it.

### 3.6 Conversions, checks, recursion

```elm
pub converted : Schema ei e, Conversion e a -> Schema ei a
pub mapped : Schema ei e, (e -> a), (a -> e) -> Schema ei a
pub tried : Schema ei e, (e -> Result String a), (a -> e) -> Schema ei a
pub composed : Conversion e b, Conversion b a -> Conversion e a
pub checked : Schema e a, String, (a -> Bool) -> Schema e a
pub abortingCheck : Schema e a, String, (a -> Bool) -> Schema e a
pub judged : Schema e a, (a -> List Issue) -> Schema e a
pub between : Schema e a, a, a -> Schema e a
    where a.compare : a, a -> Order
pub expecting : Schema e a, String -> Schema e a
pub named : Schema e a, String -> Schema e a
pub example : Schema e a, a -> Schema e a
pub recovered : Schema e a, (List Issue -> Maybe a) -> Schema e a
pub around : Schema e a, (Reader e a -> Reader e a) -> Schema e a
pub deferred : (() -> Schema e a) -> Schema e a
pub flipped : Schema e a -> Schema a e
pub encodedOnly : Schema e a -> Schema e e
pub typeOnly : Schema e a -> Schema a a
pub roundTrips : Schema e a, a -> Bool
    where a.eq : a, a -> Bool
```

Note the three at the end, which revision 1 could not write. `flipped` is Effect's `Schema.flip`
(parity row 105, moved from *not needed* to *same*): with both sides typed, swapping them is
meaningful and is what an encoding-direction validator wants. `encodedOnly` and `typeOnly` are
Effect's `toEncoded` and `toType` (new rows 163, 164): the schema with its transformations
stripped, on one side or the other — what you want when you need to validate a wire payload without
running any conversion, which is exactly §5.10's first step done strictly.

`converted` is where a `Conversion` meets a schema, and it is what `via` desugars to. **The
`Conversion` carries both sides, which is the whole reason a `via` field's `Encoded` type is
knowable**: from `Date.millis : Conversion Int Date` the compiler reads `Int` on the left.

**Ordering rule, taken from Effect (row 82) and stated because it is observable.** A check on a
composite runs only after every part of that composite read successfully. With `report = AllOf` an
inner failure is reported and the outer check does not run; with `FirstOnly`, reading stops at the
first `Issue`.

### 3.7 Effectful transformations (K10, H4)

Can a transformation call a service, and what would that do to reading's own effect bits? The
answer is a question the effects spec has not answered.
[`transparent-effects-proposal.md`](../transparent-effects-proposal.md) §1 derives that `suspends`
must be part of a function's *type*, because separate compilation carries nothing else across a
module boundary; §2 then promises bit-polymorphism for higher-order functions. A `Schema e a`
stores its reader in a **field**, not a parameter. If the bit is polymorphic for a function in a
field, `Schema e a` is one type and an effectful conversion costs nothing in the surface — the best
outcome, and what Effect needs its `RD`/`RE` type parameters for (row 160). If it is not,
`Schema e a` splits into a sync and a suspending flavour and every combinator is written twice,
which is unacceptable; the design would then keep reading pure.

**Until that has a position, layer 1 is pure**, and §5.7 argues that even with the answer, reading
should not perform.

### 3.8 Ergonomics: dot-calls and pipes, checked

```elm
pub nonEmpty : Schema String String
nonEmpty =
    Schema.string.checked "must not be empty" (\s -> s /= "")


pub emails : Schema (List String) (List String)
emails =
    nonEmpty
        |> Schema.list
        |> Schema.checked "at least one" (\xs -> List.length xs > 0)
```

The first line is spike §1.1's `M.v.m a` row — a method call whose receiver is a qualified value —
and it reads exactly as Effect's `Schema.String.check(...)` does. Static dispatch already bought
the library its fluent surface.

### 3.9 Two facts established against the live compiler

**(i) The whole two-parameter model checks, end to end.** `beni check --no-cache` exit 0 on a
scratchpad project holding the library above, a `User` with a renamed and a defaulted field, a
generic `Page`, a validated `Email`, a flattened `Shape.Encoded`, and an application that writes

```elm
pub emails : () -> Schema (Page.Encoded Email.Encoded) (Page.Type Email.Type)
emails () =
    Page.schema ()
```

So `Page.Type Email.Type`, `Page.Encoded Email.Encoded`, `User.Type`, `User.Encoded` and an opaque
type *named* `Type` inside module `Email` all resolve with today's grammar and today's resolver.

**(ii) A `master` defect, found while probing K2 (H3).** An *annotated* top-level declaration with
no parameters and a `where` clause is emitted as a JavaScript function while every consumer reads
it as a value. Minimal reproduction, exit 0:

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
const Blank$blank = ($m$0) => ({ $: 0, a: null, b: null });
const Blank$blankInts = () => Blank$blank(Blank$eq$prim);
// another module, reading it as a value:
const Sees$n = List$length(Blank$blankInts);
```

Spike §8.1 says *"the checker refuses it first (`constrained_constant`, §6.4), so the backend never
meets one"*, and §10.10 scopes `constrained_constant` to *inferred* schemes, so the annotated case
falls between the two. It is `plans/queue.md` row 57, and it is why K2 keeps the `()`.

---

## 4. The `schema` declaration

### 4.1 Grammar sketch

In `language.md` §3's notation, adding one alternative to `Decl` and nothing else:

```
Decl        := DocComment? Visibility? (TypeAlias | TypeDecl | TopAnnotation
                                       | Definition | Foreign | SchemaDecl)

SchemaDecl  := 'schema' upper_ident lower_ident* SchemaBody
SchemaBody  := '=' '{' SchemaField (',' SchemaField)* '}'      -- a record schema
             | '=' FieldSchema FieldOpt*                       -- a schema over one value
             | 'tagged' string 'of' Variant ('|' Variant)*     -- a tagged union
             | ε                                               -- structural, for a type you have

SchemaField := DocComment? lower_ident ':' FieldSchema FieldOpt*
FieldSchema := (upper_ident | qualified_upper) FieldAtom*      -- a SCHEMA, not a type (K14)
             | lower_ident                                     -- a schema parameter
             | '{' SchemaField (',' SchemaField)* '}'          -- an inline record schema
FieldAtom   := (upper_ident | qualified_upper) | lower_ident | '(' FieldSchema ')'

FieldOpt    := 'as' string          -- the wire key
             | 'via' Atom           -- a Conversion; its left side is this field's Encoded
             | 'default' Atom       -- used when the key is absent or null
             | 'optional'           -- the key may be absent or null

Variant     := upper_ident FieldSchema? ('as' string)?
```

`Visibility` gains `pub opaque schema` for the validated form (§4.5).

**`schema` is a contextual word, not a keyword**, recognised as `where` and `equatable` are
(`language.md` §3, spike §2.2): a `lower_ident` spelled `schema`, at the start of a declaration,
followed by an `upper_ident`. `schema = 1` at column 1 stays an ordinary declaration of a value
named `schema` — which matters, because `schema` is the name of the value every namespace holds.
`tagged`, `of`, `as`, `via`, `default` and `optional` are likewise contextual and only inside a
`SchemaBody`; `as` is already a keyword and is reused.

**Layout** is `language.md` §4 rule 2 and nothing more. **Formatting:** one field per line, the `,`
leading each continuation as records already do, modifiers separated by single spaces and **never
aligned** — `language.md` §9 aligns nothing, and the owner's sketch shows columns the formatter
would collapse. Say so explicitly, because the sketch is what people will copy.

### 4.2 What a declaration defines (the owner's decision, worked through)

`pub schema User = { … }` defines **one thing: a schema called `User`.** It does not declare a
type. What you can then refer to is §0.2's table: `User.Type`, `User.Encoded`, `User.schema`, and —
under K16 — `User.parse`, `User.read`, `User.write`, `User.decode`, `User.encode`.

Nothing appears under a name the developer did not write. `Type` and `Encoded` are fixed words
inside the schema's own namespace, the way `eq` is a fixed word inside a type's module; there is no
`UserWire`, no `UserEncoded`, and no file of emitted beni anywhere.

**Where the two record types come from.** The compiler reads the declaration once and knows both.
That is the same act as reading `type Colour = Red | Green` and knowing how `==` compares two
colours (spike §9). It is not the thing the owner's constraints forbid — that is *type-level
programming*, a user writing `Partial<T>` in the type language — and the difference is who writes
the program: there, the user; here, nobody, because there is no program, only a declaration being
read.

### 4.3 A field position holds a schema (K14)

```elm
-- [proposed]
pub schema Order =
    { id : String            -- the built-in schema for strings
    , buyer : User           -- the `User` schema declared elsewhere
    , lines : List Line      -- the list-of-`Line`-schema
    , note : String optional
    }
```

`String`, `Int`, `Float`, `Bool`, `List`, `Maybe`, `Dict` and every declared schema are **names of
schemas** in this position. `Order.Type` is therefore `{ id : String, buyer : User.Type, lines :
List Line.Type, note : Maybe String }` and `Order.Encoded` is the same record with each field's
`Encoded` in place of its `Type`.

Three things fall out, and all three are simplifications:

1. **No lookup.** `name : String` means the string schema; nothing has to find "the schema for
   `String`". The well-known method table (§4.9) is then needed only for *hand-written* generic
   schemas, not for declarations.
2. **`as`, `via` and `default` stop being three unrelated keywords** and become operations on the
   field's schema (§4.4).
3. **A type with two schemas stays reachable.** §5.9's v1 and v2 schemas for the same program type
   are both nameable in a field position, which is the case "derive the schema from the type"
   cannot express at all.

The cost is one thing to learn: in a `schema` body, `String` is a schema. The report's view is that
this is *easier* to learn than the alternative, because it is what the declaration says it is — you
are defining a schema out of schemas.

### 4.4 The field modifiers, and how `Encoded` is read off each

This is the table the whole design rests on. For a field `f : S` with schema `S`:

| Written | `Type` field | `Encoded` field | Wire key | Reading | Writing |
|---|---|---|---|---|---|
| `f : S` | `S.Type` | `S.Encoded`, key `f` | `f` | the key must be present and not `null` | always written |
| `f : S as "k"` | `S.Type` | `S.Encoded`, key `k` | `k` | as above | as above |
| `f : S optional` | `Maybe S.Type` | `Maybe S.Encoded` | `f` | absent or `null` → `Nothing` | written only when `Just` |
| `f : S default v` | `S.Type` | `Maybe S.Encoded` | `f` | absent or `null` → `v` | always written |
| `f : Maybe S` | `Maybe S.Type` | `Maybe S.Encoded` | `f` | the key must be present; `null` → `Nothing` | always written |
| `f : S via c` where `c : Conversion S.Type x` | `x` | `S.Encoded` | `f` | `S` reads, then `c.from` | `c.to`, then `S` writes |
| `f : S rest` | `List ( String, Value )` | the same | — | every key no other field claimed | written back out |

**`via` is flipped relative to the owner's sketch, and this is the one place revision 2 disagrees
with the sketch's text.** The sketch wrote `createdAt : Date via Date.millis`. Under K14 the field
position holds a schema, so `Date` there would name *the `Date` schema* — which is not what the
field is on the wire. The field names the **wire** schema and the conversion says what it becomes:

```elm
createdAt : Int via Date.millis        -- Date.millis : Conversion Int Date
```

`Int` is what arrives; `Date.millis` turns it into a `Date`. Here `S` is `Int`, so `S.Type` is
`Int` and the conversion is `Conversion Int Date` — its **left** side is what the field's schema
decodes to, its **right** side is what the field becomes. So the row above reads: the field's
`Type` is the conversion's right side, its `Encoded` is the field schema's own `Encoded`, and the
two directions are the conversion's two functions. **A `Conversion` carrying both sides is what
makes a `via` field's `Encoded` readable straight off the text, with no inference at all** — which
is why revision 2 renames revision 1's `Via` to `Conversion` and keeps both parameters on it.

**Absent versus `null`.** `optional` accepts either, which is the forgiving rule, because real
payloads use both for the same idea and often inconsistently in one API. `Maybe S` is the stricter
reading — the key must be there and may be `null` — and the two strict-absent variants
(`Schema.absentField`, `Schema.nullField`) stay in layer 1 for an author who knows their API.

**No inline checks.** `age : Int where age >= 0` is deliberately not offered. The rule-7 argument is
a guarantee: a checked value typed `Int` can be *constructed* without the check anywhere else in the
program, so the check is a property of one decoding path and not of the value — the forgery hole of
report 31 §4.2. A constrained value is a validated schema (§4.5), whose module owns the only
constructor. Nothing is withheld: the hatch is a three-line module, and `Schema.checked` is always
available for values that really are unconstrained.

### 4.5 Validated schemas, and where the private constructor lives (`Email`)

A validated type is one that cannot be built except through a check. In beni that means an opaque
type whose constructor is private to its module. The schema declaration has to reach that
constructor without exposing it, so the body form is:

```elm
-- [proposed], in Email.beni
pub opaque schema Email = String via conversion
```

which reads: *`Email` is a schema; on the wire it is a `String`; `conversion` turns one into an
`Email.Type` and back.* What it defines:

- `Email.Type` — an **opaque** type. Its constructor is private to `Email.beni`, exactly as
  `pub opaque type` makes one today, and `opaque` on the schema declaration is what says so.
- `Email.Encoded` — `String`, read off `conversion`'s left side.
- `Email.schema`, `Email.parse`, … as usual.

The module writes the conversion and nothing else:

```elm
pub fromString : String -> Result String Email.Type
pub toString : Email.Type -> String


conversion : Schema.Conversion String Email.Type
conversion =
    { from = fromString, to = toString }
```

**Is `Email.Type` the same type as "the module's opaque `Email` type"? Yes — there is only one.**
Revision 1 had a module declaring `pub opaque type Email` *and* a schema beside it, and the two
names collided under the owner's model. Here the schema declaration is the only declaration, and
the opaque type it defines is reached as `Email.Type` like every other schema's. A module that
prefers the short name writes `type alias Addr = Email.Type` — the owner's no-shorthand rule,
applied by the author rather than by the compiler.

**Checked today, with the hand-written stand-in** (`pub opaque type Type = Email String` plus
`pub type alias Encoded = String` plus the conversion): exit 0, and the constructor `Email` stays
private while `Email.Type` is public. So the declaration above is sugar for text that already
compiles — which is what report 28 §0 asks of any new syntax.

**What this buys, and it is the guarantee K3 protects.** `Email.Type` has no structural route in.
There is no expression in the language that produces an invalid `Email.Type`, whether or not it
came through a schema. Effect's `brand` is erased at run time and a cast produces an unvalidated
one; this cannot.

### 4.6 A tagged union's `Encoded` (K15)

```elm
-- [proposed]
pub schema Shape tagged "kind" of
      Circle { radius : Float } as "circle"
    | Rect { w : Float, h : Float } as "rect"
```

`Shape.Type` is a nominal type with the constructors the declaration writes:

```elm
Circle { radius : Float } | Rect { w : Float, h : Float }
```

`Shape.Encoded` is the **flattened wire record**: the tag key as a `String`, then every field of
every variant with its own `Encoded` type wrapped in `Maybe`, because only one variant's fields are
present at a time.

```elm
{ kind : String
, radius : Maybe Float
, w : Maybe Float
, h : Maybe Float
}
```

Checked, exit 0, together with the `encode` function the declaration stands for:

```elm
pub encode : Type -> Encoded
encode s =
    case s of
        Circle c ->
            { kind = "circle", radius = Just c.radius, w = Nothing, h = Nothing }

        Rect r ->
            { kind = "rect", radius = Nothing, w = Just r.w, h = Just r.h }
```

**Why not the alternatives.** A second *nominal* type mirroring the variants would need constructor
names, and the only names available are the ones `Shape.Type` already uses — two types cannot share
constructor names in one file, and inventing `CircleEncoded` is the invented name the owner ruled
out. A nested namespace (`Shape.Encoded.Circle`) lexes as a three-segment `qualified_upper` and
would work, but it is a naming scheme nobody asked for and it costs a second dot-splitting rule in
the resolver. `Value` types nothing.

**The rule the declaration enforces.** Two variants that share a field name must agree on its
encoded type, or the declaration is refused with a diagnostic naming both variants and both types.
The hatch is one `as` on one of them.

**What is lost relative to Effect, plainly.** The correlation between the tag and which fields are
present is not in the type: `{ kind = "circle", w = Just 3.0, radius = Nothing, h = Nothing }`
type-checks and the *reader* refuses it. TypeScript keeps that correlation because it has
discriminated unions of object types; beni has no structural sum type, and that is a fact of the
language the owner chose rather than of this design. What is **not** lost is any run-time
guarantee: reading and writing are as exact as Effect's.

### 4.7 Why `X.schema` takes a `()` (K2)

Not style — a verified consequence of two rules that already exist.

A generic schema's element schema arrives by **return-type dispatch** (spike §4), and the form is
`a.schema`. But `language.md` §6.3 and spike §1.1 say *"`x.m` with no arguments is never a method
call"* — an application with no arguments is not an application. Writing `Schema.list a.schema` is
therefore a naming error, verbatim from the checker:

```
-- NAMING ERROR -------------------------------------------------- Page.beni:16:46

I cannot find a `a` variable.

16|        |> Schema.field "items" (Schema.list a.schema)
                                                ^
```

With the `()` it resolves, and the whole generic schema checks:

```elm
pub schema : () -> Schema (Encoded e) (Type a)
    where a.schema : () -> Schema e a
schema () =
    Schema.object
        |> Schema.field "items" (Schema.list (a.schema ()))
        |> Schema.optionalField "next" Schema.string
        |> Schema.build
            (\( ( (), i ), n ) -> { items = i, next = n })
            (\p -> ( ( (), p.items ), p.next ))
            (\( ( (), i ), n ) -> { items = i, next = n })
            (\w -> ( ( (), w.items ), w.next ))
```

Note the clause: **`where a.schema : () -> Schema e a` ties two annotation variables together.**
`e` occurs in the annotated type (`Encoded e`), so spike §2.4's closure rule is satisfied, and
unifying the constraint at a use pins `e` from `a`'s own schema. That is how a two-parameter schema
stays generic, and it checks today.

Two more reasons the `()` is the right call rather than a wart. A recursive schema names itself, and
a top-level *value* reachable from its own initialiser is `cyclic_value` (`language.md` §7) — a
function may recurse freely. And a generic schema needs evidence, which spike §8.1 makes a *leading
parameter*, so a zero-parameter declaration with evidence is exactly the `master` defect of §3.9(ii).

**And K16 keeps it out of the way.** `User.parse text`, `User.encode u`, `User.write u` have no
`()`. It appears only where one schema is passed to another.

### 4.8 What kind of name `User` is (K13), checked against the real grammar

`User.Type` lexes today as a single `qualified_upper` token (`language.md` §2.4: `Upper(.Upper)+`),
and `Lower.resolveQualified` (`src/bir/Lower.zig:1268-1294`) splits it at the **last** dot and
matches the module part against the file's import aliases and then the prelude's. So a schema name
has to sit where an import alias sits. Four things were verified:

| Probe | Result |
|---|---|
| `User.Type` and `User.Encoded` as types, with `import Models.User as User` | resolves, exit 0 |
| `Models.User.Type` with no alias, `Models/User.beni` a real module | resolves, exit 0 |
| `Page.Type Int` — a qualified type applied to an argument | resolves, exit 0 |
| `String.length User` — a Capitalised name in expression position | `UNKNOWN CONSTRUCTOR`; an upper name in an expression is a constructor, always |

The last row settles one thing immediately: **`Schema.parse User text` cannot work.** A schema is
passed as `User.schema ()` — a `qualified_lower`, which is an ordinary value — or, better, not
passed at all, because `User.parse text` is a function in the namespace (K16).

The three options for what `User` *is*, with their cost:

| | What | Compiler cost |
|---|---|---|
| **(a) recommended** | a nested namespace in the declaring module, visible unqualified there, reachable from outside through `exposing (User)` | one more table consulted in `resolveQualified`'s module lookup; a namespace section in `Bir` and in `Interface`; `exposing` admitting a namespace name (upper names already cover two kinds, so the *syntax* does not change); `duplicate_import_alias` extended to a schema name that collides with an import alias |
| **(b)** | (a) plus `Models.User.Type` from outside | (a) plus a second dot-splitting rule: on failure, split at the next dot left and look the middle segment up as a namespace in that module's interface |
| **(c)** | the module **is** the namespace — one schema per file, the declaration carries no name | **zero**: `User.Type` is then an ordinary module-qualified type and everything in the table above already works |

**Recommendation (a)**, with **(c) named as the fallback**. (c) is remarkable for costing nothing —
the §3.9(i) project is exactly (c) and compiles today — and its price is one schema per file, which
is a real constraint on a module that naturally holds `Hit` and `HitPage` together. (b) is additive
and should wait for someone to want it.

**Collisions and visibility under (a).** `schema User` in a file that also has `import User` is
refused (`duplicate_import_alias`); two `schema User` declarations in one file are
`duplicate_declaration`; a private `schema User` is file-local, and `pub schema User` puts the
namespace and everything in it into the interface. A schema name and a *type* of the same name can
coexist, because they are in different namespaces — but the report recommends a warning, because
`User` and `User.Type` being different things in one file is exactly the confusion the no-shorthand
rule exists to prevent.

### 4.9 Where a field's schema comes from, and what is refused

Inside a declaration, a field's schema is the name written there (K14). Outside one — in a
hand-written generic schema — it arrives through `where a.schema`, and that constraint resolves by
spike §1.2's module rule against `a`'s declaring module, with one table in front of it.

**The well-known table (H2).** `Int`, `Float`, `Bool`, `String`, `Char`, `Order`, `Never`, `()`,
tuples, `List a`, `Maybe a`, `Result e a`, `Dict k v` and `Set a` resolve `schema` from a table
inside the compiler, **before** the module rule — spike §3.2's arrangement for `eq`/`compare`, and
for the same reason: those types are declared in `core/Basics` and `core/String`, and `core/Schema`
imports them, so a `pub schema` in `Basics` would be an `import_cycle` (spike §5's core-cycle
constraint). The table's entries point at `core/Schema`'s own combinators.

Everything else resolves by the module rule, and a type whose module has no `schema` is
`unknown_method` — **a good diagnostic that already exists.** Verbatim, today:

```
-- UNKNOWN METHOD --------------------------------------------------- Use.beni:7:5

`Int` has no method called `schema`.

I resolve `x.schema` in the module that declares `x`'s type. That module is
`Basics`, and it has no `pub` value called `schema`.
…
`schema` was required by `pageSchema`'s annotation.
```

That is report 31's *"'no schema for this type' must be a compile-time diagnostic, never a run-time
crash"*, satisfied with **no new diagnostic code**; the hint only needs to name `schema T`.

**What a declaration refuses**, and it is [`boundary.md`](../boundary.md) §3.1's admitted set
arrived at by a different route: a field whose schema is a function type, an extended record, a
schema parameter with no generated constraint, or a name that is a *type* rather than a schema and
whose type has no `schema`. **Where the refusal lands:** at the **declaration** when the offending
name is written there; at the **use** when it is a schema parameter instantiated badly. Both are
compile-time, which answers report 31 §7 question 4.

### 4.10 Interactions

| With | What happens |
|---|---|
| `eq` / `compare` | unchanged. They derive from a *type*, and `User.Type` is an ordinary type; `Shape.Type` derives both structurally |
| `pub` | `pub schema User` exports the namespace and everything in it; `pub opaque schema Email` exports the namespace with `Email.Type`'s constructor private |
| imports | `exposing (User)` brings the namespace in (§4.8) |
| the formatter | one new printer case; no alignment; the `\|` of a tagged body leads its line as a `type` declaration's does |
| `dump --stage=bir` | the declaration is gone by BIR — it lowers to ordinary type aliases plus ordinary declarations — so `bir` goldens show only calls, which is report 28 §10's "one semantics" made mechanical, and what an `emit/` golden should assert |
| recursion | a schema whose field schemas reach itself is fine: `X.schema` is a function (§4.7), and the compiler inserts `Schema.deferred` at the back edge. `X.Type` must then be a `type` with a constructor rather than a `type alias`, because a self-referential alias is `recursive_alias` — §5.5 |
| `--release` | a namespace's five convenience values are ordinary declarations, so reachability elimination drops the ones nobody calls (§8.2) |

### 4.11 What is deliberately not in the declaration

- **No inline checks** (§4.3). A constrained value is a validated schema (§4.5).
- **No `schema B from A`** — the sugar that would answer ten of §2.15's fourteen "cannot" rows by
  copying another declaration's field list and modifiers. It is syntax over syntax, so it is
  *available*, but it is a second feature and should be commissioned only if the duplication is
  measured to hurt.
- **No shorthand for `X.Type`**, by the owner's decision. A developer who wants one writes
  `type alias Person = User.Type`.
- **No JSON-specific knobs, and this is the line to hold.** `as`, `via`, `default` and `optional`
  are format-neutral: each means something in a form submission and a query string as well as in
  JSON. A modifier that does not pass that test — `nullAs`, a date format string, `caseInsensitive`
  — belongs in layer 1, where it is one function call. §9 treats this as the answer to the drift
  objection, and the test is what makes it hold rather than a promise.

---

## 5. Worked examples

Each shows (i) Effect, from `SCHEMA.md`; (ii) the beni declaration, `[proposed]`; (iii) what you
can then refer to, with its type. Every (iii) was checked against the installed binary as a
hand-written stand-in for the declaration — which is also the proof that the declaration is sugar
over text somebody could have written.

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
    , createdAt : Int via Date.millis
    }
```

**(iii) what you can refer to:**

```elm
User.Type      -- { userId : Int, accountName : String, age : Int, createdAt : Date }
User.Encoded   -- { user_id : Int, account_name : String, age : Maybe Int, createdAt : Int }
User.schema    -- () -> Schema User.Encoded User.Type
User.parse     -- String -> Result (List Schema.Issue) User.Type
User.encode    -- User.Type -> User.Encoded
User.decode    -- User.Encoded -> Result (List Schema.Issue) User.Type
```

and the layer-1 text the declaration stands for, checked, exit 0 — note the four functions at
`build`, two per side:

```elm
pub schema : () -> Schema Encoded Type
schema () =
    Schema.object
        |> Schema.field "user_name" Schema.string
        |> Schema.defaulted "age" Schema.int 0
        |> Schema.build
            (\( ( (), n ), a ) -> { name = n, age = a })
            (\u -> ( ( (), u.name ), u.age ))
            (\( ( (), n ), a ) -> { user_name = n, age = a })
            (\w -> ( ( (), w.user_name ), w.age ))
```

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

**(iii) what you can refer to** — `Shape.Encoded` is K15's flattened record; both checked, exit 0:

```elm
pub type Type
    = Circle { radius : Float }
    | Rect { w : Float, h : Float }


pub type alias Encoded =
    { kind : String
    , radius : Maybe Float
    , w : Maybe Float
    , h : Maybe Float
    }


pub encode : Type -> Encoded
encode s =
    case s of
        Circle c ->
            { kind = "circle", radius = Just c.radius, w = Nothing, h = Nothing }

        Rect r ->
            { kind = "rect", radius = Nothing, w = Just r.w, h = Just r.h }
```

`Shape.Type`'s constructors are the names the declaration writes, and they are the module's own
constructors, so `case s of Circle c -> …` works everywhere with no qualification.

### 5.3 A validated `Email`

**(i) Effect** (L2810) uses a brand plus a check, and the brand is erased at run time:

```ts
const Email = Schema.String.check(Schema.isIncludes("@")).pipe(Schema.brand("Email"))
```

**(ii) beni** `[proposed]`, in `Email.beni`:

```elm
pub opaque schema Email = String via conversion
```

**(iii) what you can refer to**, checked, exit 0 — and note the constructor `Email` never leaves
the file:

```elm
pub opaque type Type
    = Email String


pub type alias Encoded =
    String


pub fromString : String -> Result String Type
fromString raw =
    if String.contains raw "@" then
        Ok (Email raw)

    else
        Err "not an email address"


pub toString : Type -> String
toString (Email raw) =
    raw


conversion : Schema.Conversion Encoded Type
conversion =
    { from = fromString, to = toString }


pub schema : () -> Schema Encoded Type
schema () =
    Schema.converted Schema.string conversion
```

**There is no expression in the language that produces an invalid `Email.Type`**, whether or not it
came through a schema. Effect's brand is a type-level marker over a `string` and a cast produces an
unvalidated one; this is a nominal type with a private constructor.

### 5.4 A paginated generic response

**(i) Effect** (L2440):

```ts
const Page = <A extends Schema.Top>(item: A) =>
  Schema.Struct({ items: Schema.Array(item), next: Schema.optionalKey(Schema.String) })
```

**(ii) beni** `[proposed]`:

```elm
pub schema Page a =
    { items : List a
    , next : String optional
    }
```

**(iii) what you can refer to** — two ordinary 1-ary types, and a schema whose `where` clause ties
them together (checked, exit 0; §4.7 has the body):

```elm
Page.Type a      -- { items : List a, next : Maybe String }
Page.Encoded e   -- { items : List e, next : Maybe String }
Page.schema      -- () -> Schema (Page.Encoded e) (Page.Type a) where a.schema : () -> Schema e a
```

and at a use, both parameters follow from one name:

```elm
pub emails : () -> Schema (Page.Encoded Email.Encoded) (Page.Type Email.Type)
emails () =
    Page.schema ()
```

Unlike Effect, the element schema is not an argument: `Page.schema ()` at type
`Page.Type Email.Type` finds `Email.schema` through the `where` clause.

### 5.5 A recursive comment tree

**(i) Effect** (L2235):

```ts
const Comment: Schema.Codec<Comment> = Schema.Struct({
  body: Schema.String,
  replies: Schema.Array(Schema.suspend((): Schema.Codec<Comment> => Comment))
})
```

**(ii) beni** `[proposed]` — nothing special is written:

```elm
pub schema Comment =
    { body : String
    , replies : List Comment
    }
```

**(iii) what you can refer to**, checked, exit 0. Two consequences the declaration handles: a
recursive `Type` is a `type` with one constructor, not a `type alias`, because a self-referential
alias is `recursive_alias`; and the schema is a **function**, because a self-referential top-level
*value* is `cyclic_value` (`language.md` §7):

```elm
pub type Type
    = Comment { body : String, replies : List Type }


pub type alias Encoded =
    Type


pub schema : () -> Schema Encoded Type
schema () =
    Schema.object
        |> Schema.field "body" Schema.string
        |> Schema.field "replies" (Schema.list (Schema.deferred schema))
        |> Schema.build
            (\( ( (), b ), r ) -> Comment { body = b, replies = r })
            (\(Comment c) -> ( ( (), c.body ), c.replies ))
            (\( ( (), b ), r ) -> Comment { body = b, replies = r })
            (\(Comment c) -> ( ( (), c.body ), c.replies ))
```

`Comment.Encoded` is `Comment.Type` here because no field transforms — which is a fact about this
schema and not a rule, and it is exactly what `Schema.encodedOnly` (row 163) reports. A reader hits
`Options.maxDepth` before the JavaScript stack does.

### 5.6 A fallible custom transformation: `"12.50 USD"` ↔ `Money`

**(i) Effect** (L3349) uses `transformEffect` with an `Issue` on the failing side.

**(ii) beni** `[proposed]`, in `Money.beni`:

```elm
pub opaque schema Money = String via conversion
```

**(iii) what you can refer to**, checked, exit 0:

```elm
pub opaque type Type
    = Money { cents : Int, currency : String }


pub type alias Encoded =
    String


pub fromText : String -> Result String Type
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


pub toText : Type -> String
toText (Money m) =
    "${toFloat m.cents / 100} ${m.currency}"


pub conversion : Schema.Conversion Encoded Type
conversion =
    { from = fromText, to = toText }
```

`fromText` returns `Result String Money.Type` and `toText` is total — K5 in one file. And because
`conversion` is `pub`, any other schema can name it: `total : String via Money.conversion` (§5.8).
One function, three jobs.

### 5.7 An effectful transformation — and the argument for refusing it

**(i) Effect** (L7004) decodes an id into a full user through a `UserDatabase` service, with the
requirement in the schema's type: `Schema.Codec<User, string, UserDatabase, never>`.

**(ii) beni: do not do this, and the reason is not the type system.** Under transparent effects the
code would be unremarkable — a `Conversion` whose `from` performs, inferred `suspends`, nothing
written anywhere. Two things argue against it:

1. **It turns one round trip into *n*.** A schema runs on a payload that already arrived; a reader
   that performs runs once per occurrence, and a list of 200 ids is 200 lookups inside a function
   whose type says "read this value". Effect's answer is the `concurrency` parse option (row 150),
   a knob for a problem the shape created.
2. **It makes reading non-repeatable**, and `roundTrips` (§7.2), `Sample.of` (row 148) and
   `--release`'s specialised reader (§8.3) all assume reading twice gives the same answer.

**The recommended shape** is the ordinary beni one — read, then enrich:

```elm
pub load : String -> Result (List Schema.Issue) (List Person)
load text =
    let
        ids =
            Schema.parse (Schema.list Schema.string) text?
    in
    Ok (List.map ids lookup)
```

Checked, exit 0. `?` unwraps the read, `List.map` performs, and the two concerns stay apart. This
is K10's option (b), recommended **on design grounds** — so the answer to H4 changes whether the
capability exists for someone who insists, not the recommendation.

### 5.8 Composition: a schema whose field is another schema

This is K14 doing its job, and it is the example that shows why a field position holds a schema.

**(ii) beni** `[proposed]`:

```elm
pub schema Order =
    { id : String
    , buyer : User
    , total : String via Money.conversion
    }
```

**(iii) what you can refer to**, checked, exit 0 — `Encoded` composes the same way `Type` does:

```elm
pub type alias Type =
    { id : String, buyer : User.Type, total : Money.Type }


pub type alias Encoded =
    { id : String, buyer : User.Encoded, total : Money.Encoded }


pub schema : () -> Schema Encoded Type
schema () =
    Schema.object
        |> Schema.field "id" Schema.string
        |> Schema.field "buyer" (User.schema ())
        |> Schema.field "total" (Money.schema ())
        |> Schema.build
            (\( ( ( (), i ), b ), t ) -> { id = i, buyer = b, total = t })
            (\o -> ( ( ( (), o.id ), o.buyer ), o.total ))
            (\( ( ( (), i ), b ), t ) -> { id = i, buyer = b, total = t })
            (\w -> ( ( ( (), w.id ), w.buyer ), w.total ))
```

`buyer : User` names the **schema**. Under the alternative (`buyer : User.Type`, K14 option (b))
the compiler would have to look up "the schema for `User.Type`" — and §5.9's second wire form for
that same type would then be unreachable from any declaration.

### 5.9 One type, two wire forms — v1 and v2 of an API

The shape report 31 §4.1 says every real API eventually has, and the case "derive the schema from
the type" cannot do at all. Two schemas, two `Encoded` types, **one** program type — which the
author states by declaring the second schema's `Type` to be the first's:

```elm
-- [proposed], in UserV1.beni
pub schema UserV1 =
    { name : String as "userName"
    , age : Int as "userAge"
    }
```

```elm
UserV1.Type      -- { name : String, age : Int }
UserV1.Encoded   -- { userName : String, userAge : Int }
User.Type        -- { name : String, age : Int } — the same record type, structurally
User.Encoded     -- { user_name : String, age : Maybe Int }
```

beni records are structural, so `UserV1.Type` and `User.Type` *are* the same type and a value read
by one is writable by the other with no conversion:

```elm
pub upgrade : String -> Result (List Schema.Issue) String
upgrade old =
    let
        u =
            Schema.parse (UserV1.schema ()) old?
    in
    Ok (Schema.print (User.schema ()) u)
```

When the program types genuinely differ, the author writes the mapping — and §5.10 shows the better
route, which is not to build a program value at all.

### 5.10 What `Encoded` is for: a v1 → v2 migration over the wire shapes

New in revision 2, and it is the example that pays for the second type parameter. A stored payload
has to move from v1's spelling to v2's. Doing it through the program type means reading a v1 row
into a `UserV1.Type` and writing it out as v2 — which fails for any row that v2's *checks* would
reject, even though the migration itself is only a rename. Doing it on the **encoded** side does
not:

```elm
--| A migration over the WIRE shapes. No program value is built, so a v1 row
--| that v2's checks would reject still migrates, and the rule is one record
--| expression the type checker reads.
pub toV2 : UserV1.Encoded -> User.Encoded
toV2 old =
    { user_name = old.userName, age = Just old.userAge }


pub migrate : Value -> Result (List Schema.Issue) Value
migrate raw =
    let
        old =
            Schema.readEncoded (UserV1.schema ()) raw?
    in
    Ok (Schema.writeEncoded (User.schema ()) (toV2 old))
```

Checked, exit 0. Three things to notice. `toV2` is an ordinary record expression and the **type
checker proves the migration total** — a forgotten field is `missing_field`, a renamed one is
`unknown_field`, and neither is a test anybody has to remember to write. `readEncoded` /
`writeEncoded` are §3.3's halves, so no conversion runs in either direction. And under revision 1's
one-parameter `Schema` **none of this could be written**, because `UserV1.Encoded` and
`User.Encoded` would not have been types — which is the concrete answer to "what is `Encoded` for",
and the reason K1 is reversed.

The same shape covers the other three uses: a **form** whose state is `User.Encoded` and whose
submit is `User.decode`; a **fixture** written as a `User.Encoded` literal, which the compiler
checks against the wire shape; and a **database row** typed `User.Encoded` rather than a bag of
strings.

### 5.11 The typeahead program's HTTP, rewritten

`plans/browser-platform.md` §1.1 declares `Hit` as a bare `type alias` with no wire story — the
payload is assumed. With schemas the assumption becomes a declaration, and only the real API
implementation changes:

```elm
-- [proposed]
pub schema Hit =
    { id : String as "hit_id"
    , title : String
    }


pub schema HitPage =
    { hits : List Hit
    , total : Int default 0
    }
```

```elm
-- the platform side; `[proposed]` for Http and Send only
searchReal : String -> Result HttpError (List Hit.Type)
searchReal q =
    let
        body =
            Http.getText "/search?q=${q}"?
    in
    case HitPage.parse body of
        Ok page ->
            Ok page.hits

        Err issues ->
            Err (BadPayload (Schema.explain issues))
```

Three things. `HttpError` gains a `BadPayload String` constructor — the payload failure becoming a
**constructor in the result type**, which is [`boundary.md`](../boundary.md) §4.1's recipe one level
up. `update` and `view` are untouched, because the schema lives at the boundary. And the test
double passes `Hit.Type` values directly and never touches a schema, so the schema costs the tests
nothing — which is what makes `Schema.roundTrips` worth adding as the *one* schema test a program
writes.

Note `HitPage.parse body` rather than `Schema.parse (HitPage.schema ()) body`: K16's namespace
functions are what make the call site read like the thing it does.

---

## 6. What comes out of a schema, and why the description is data as well as a type

Under the owner's model a schema now says the wire shape **twice**, and the two are for different
readers. `X.Encoded` is a *type*, so the **type checker** can hold a form's state, a fixture or a
database row to it, and §5.10's migration is checked rather than tested. `Schema.describe` returns
a `Node`, which is *data*, so a **program** can walk it — and a JSON Schema document, a generated
form and a fixture generator are all programs walking a description, not type-checking against one.
Neither replaces the other: a type cannot be iterated and a description cannot be unified.

Five artefacts, each a pure function of `Node` (plus `write` for two of them), each in its own
package so that a program that wants none of them ships none of them (§8.4):

| Artefact | Function | Why it needs `Node` and not the functions |
|---|---|---|
| **JSON Schema / OpenAPI** | `JsonSchema.of : Node -> Value` | a JSON Schema document is a *description*; you cannot recover one by calling a reader |
| **Test data** | `Sample.of : Node, Seed -> ( Value, Seed )`, then `read` | generating a valid value means walking the description; report 17 §4.9's seeded PRNG is `pure`, so this is an ordinary function |
| **A form** | `Form.of : Node -> Html msg` | a text input per `TextNode`, a select per `ChoiceNode`, a repeater per `ArrayNode` — this is the browser platform's most obvious first customer |
| **API documentation** | `Docs.of : Node -> String` | `NamedNode` carries the doc comment from the declaration |
| **JSON Patch** | `Patch.between : Schema e a, a, a -> List Op` | needs `write` as well, per row 142 |

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
| **"No schema for this type" is a build error** | `unknown_method` from the module rule, at the declaration when the name is written there and at the use when it is a schema parameter (§4.9). No run-time "missing codec" exists to report |
| **The two types cannot disagree with the reader and the writer** | new in revision 2. `X.Type` and `X.Encoded` are read off the same declaration the reader and writer are, so a payload that `X.encode` produces is a `X.Encoded` by construction, and §5.10 is type-checked rather than tested |
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
pub roundTrips : Schema e a, a -> Bool
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

One line like that catches the four-function `build` seam of §3.4, a swapped `as`, and a `via` whose two
directions disagree.
With row 148's `Sample.of` it becomes a property test over generated values, which is the form
`ARBITRARY.md` argues for and the form report 31 §5 says nobody writes because nothing makes it
cheap.

**A second law arrives with the second type parameter**, and it is the one `Encoded` rests on:
`decode s (encode s x) == Ok x`, for every `x` the program can hold. It is the same law one level
in — the structural step is not involved — and `Schema.roundTrips` tests the outer one, so a
`roundTripsEncoded` over `decode`/`encode` is worth having beside it. Where the two differ is
informative: if the outer law holds and the inner one fails, the fault is in a `Conversion`; if the
inner holds and the outer fails, it is in the structural step, which is the compiler's.

The third trusted law is weaker and should be stated rather than assumed: **`write` is not
canonical.** Two program values that are `eq` may produce different `Value`s if a custom `to`
chooses differently, and the same program value may produce different bytes across builds if a
field's order changed. Anyone hashing or signing a payload needs a canonicalising writer, which is
an additional function over `Value` and not a property of the schema.

### 7.3 What it deliberately does not restrict

- **It does not require the declaration.** Layer 1 is complete on its own, and a program may never
  write `schema` at all: it can declare its own `Type` and `Encoded` aliases and a schema between
  them, which is exactly what §3.9(i) does and what K13(c) makes the ordinary spelling.
- **It does not require a schema to exist for a type.** K3: nothing is derived until asked.
- **It does not own the wire format.** `Value` and the adapters are ordinary code, so a format
  nobody thought of is a package.
- **It does not restrict what a transformation may do.** `from` is any function; the only rule is
  that it returns a `Result` rather than throwing, which it cannot do anyway.
- **It does not cap the number of fields.** §3.4.

---

## 8. Cost

### 8.1 Compiler phases, with line estimates

Anchored on report 28 §9.1's method — string interpolation and the `case` decision tree as the two
comparable features already in the tree — and on the existing port codec generator, which is the
nearest thing to this work that has been built.

| Phase | File (current size) | Change | Lines of Zig |
|---|---|---|---|
| Lexer | `src/lex/Tokenizer.zig` (1 944) | **none** — `schema`, `tagged`, `of`, `via`, `default`, `optional` are contextual words recognised in the parser, as `where` and `equatable` are (spike §2.2) | **0** |
| Parser | `src/parse/Parse.zig` (4 468) | `parseSchemaDecl`, the field list (whose positions hold **schemas**, K14), the variant list, the six modifiers, `opaque schema`, the three-token contextual lookahead, two recovery cases | **320–450** |
| AST | `src/parse/Ast.zig` (1 172) | 3 node tags (`schema_decl`, `schema_field`, `schema_variant`) with `extra` records | **90–140** |
| BIR lowering | `src/bir/Lower.zig` (4 215) | the desugaring of §4.4: the two record types, the annotation with its `where` clause, the pipeline, and the **four** lambdas per record (two per side, K1); the flattened union `Encoded` (K15); recursive-or-not; the five namespace values (K16) | **550–800** |
| Checker | `src/check/Constrain.zig` (1 642) | the well-known `schema` table of §4.9 beside the `eq`/`compare` one, and its resolution order | **120–200** |
| **Resolver — new in revision 2** | `resolveQualified` (`src/bir/Lower.zig:1268`), `src/resolve/Interface.zig` (907), `src/resolve/Graph.zig` (905) | **K13(a)**: a schema-namespace table consulted before the import aliases; a namespace section in the interface; `exposing` admitting a namespace name; the collision diagnostic. **Zero under K13(c)** | **200–320**, or **0** |
| Formatter | `src/fmt/Format.zig` (3 272) | one declaration printer, the field and variant lists, modifier spacing | **200–280** |
| Dump | `src/dump/ast.zig` | `ast` gains three tags; `bir` gains nothing | **40** |
| Diagnostics | `src/*/Diagnostics.zig` | 5–8 new codes — a duplicate wire key; a duplicate field; a modifier that contradicts its field; a `via` whose conversion does not line up; two union variants disagreeing on a shared field's encoded type (K15); a schema name colliding with an import alias (K13) — plus the hint change in `unknown_method` | **180–260** |
| **Total, layer 2** | | | **≈ 1 700–2 490** under K13(a) · **≈ 1 500–2 170** under K13(c) |
| **Layer 1** | `core/Schema.beni`, `core/Json.beni`, `core/Json.js` | beni, not Zig: the combinators at two parameters, `Value`, `Node`, `Issue`, `Conversion`, the adapters | **≈ 1 000–1 450 lines of beni**, ≈ 40 of JavaScript |

**Revision 2 adds roughly 350–550 lines over revision 1, and all of it is the owner's model**: four
lambdas per record instead of two, the flattened union `Encoded`, the five namespace values, and —
the largest single item — the schema namespace, which is the only part of this design that touches
the resolver. Report 28's JSX estimate was ≈ 1 300–1 900 for a feature of comparable surface, so
layer 2 is now about half again as large as JSX. That is worth saying plainly, and K13(c) is the
option that takes most of it back.

**Throughput** (`fast-compiler.md` §2's >250k LOC/s): the lexer is untouched, so the risk there is
zero by construction; the parser gains one arm on the declaration switch; lowering does more work
per `schema` declaration than per ordinary one, bounded by the field count. The resolver change is
one extra table consulted on a qualified name that would otherwise have failed, so it costs nothing
on the common path.

**Determinism** (rule 5): field order is source order, the `where` clause's constraint order is
type-parameter order, and the accumulator is left-nested, so nothing depends on a hash or a thread.
Two places an implementer could break it: the order of the `where` clause's constraints, which must
be the order the parameters are *declared* in and not the order fields mention them; and the field
order of a union's flattened `Encoded` (K15), which must be variant order, then field order within
a variant, never a set iteration.

**M4**: a `schema` declaration produces ordinary declarations by BIR, so a module's interface is
whatever its annotations say — with one addition under K13(a), the namespace section, which is a
pure function of the declaration's text and therefore does not move the firewall
(`checker.md` §7).

### 8.2 Output size

Reachability elimination (`backend.md` §9) is declaration-granular and always on, so **a schema
nobody reaches is not written**. Because `schema` is a *method*, the edge that keeps it alive is a
dispatch site, which §9's leg 3 already walks — so a type whose `schema` is never used costs zero
bytes, exactly as its derived `eq` does today (`derived_bytes` went to 0 for the null program).
K16's five namespace values are ordinary declarations, so a program that calls only `User.parse`
does not ship `User.encode`.

A schema that *is* reached costs roughly one `Node` object per node, one closure per combinator,
and the four `build` lambdas. For a ten-field record that is on the order of 30 small objects and
27 closures, built once per `schema ()` call — call it 1.7–2.8 kB of emitted source before
compression, against perhaps 1.2 kB for a hand-written Elm decoder/encoder pair for the same
record. That is a small loss, and revision 2 makes it slightly larger than revision 1 because two
of the four `build` lambdas are the encoded side.

### 8.3 `--release`, and what it could do later

Three things, in the order they are worth doing, and **none is in the first slice**:

1. **Memoise the thunk.** K2 makes `X.schema` a function, so `User.schema ()` rebuilds the tree on
   every call. A `--release` pass could hoist a nullary `schema` whose body takes no evidence into
   a module-level `const` — a dead-binding-adjacent transform that §9's item 1 machinery already
   has the shape for, and safe because reading is pure (K10, §5.7).
2. **Specialise the reader.** A schema whose `Node` is fully known at compile time can compile to a
   straight-line reader over the raw JavaScript value — no `Value` tree, no closure per field.
   That is Effect's JIT/AOT compiler (row 162) arriving as an ordinary compiler pass instead,
   which is strictly better: no `new Function`, so it works under a Content Security Policy, and
   no startup cost. **Two parameters make this easier rather than harder**: the reader has a
   *typed* intermediate to specialise against, so the structural step can compile to direct field
   reads on a known record shape.
3. **Drop the `Node`** when `describe` is unreachable, which reachability already decides.

Item 2 is what matters for the browser-first stance and what makes K8 (ports on schemas)
affordable. It should be a separate commission with its own measurement.

### 8.4 What lands where

| Package | What | Why |
|---|---|---|
| `core/Schema.beni` | `Value`, `Node`, `Issue`, `Conversion`, every combinator, `Options`, `readWith`, `roundTrips` | the well-known table has to point somewhere, and only core can be pointed at without an import cycle (§4.9) |
| `core/Json.beni` + `core/Json.js` | `pub foreign parse : String -> Result String Value` and `pub foreign print : Value -> String` | **yes, JSON text parsing is `foreign` in core** (K7). `JSON.parse` throws, so the sibling wraps it in `try`/`catch` and returns a `Result`, per `boundary.md` §4.1. Rule 6 makes this core's job or nobody's |
| the browser platform | `Form.toValue`, `Query.toValue`, `Date.millis` / `Date.iso8601` | format and platform adapters belong to the platform, exactly as report 28 §5.1 puts the element table there |
| `schema-json` (a package) | `JsonSchema.of : Node -> Value` | nobody should pay for OpenAPI who does not ask |
| `schema-sample` (a package) | test data | same |

### 8.5 Slice order

**Library first, declaration second**, and the argument is not habit.

- **S1 — `core/Schema` and `core/Json`.** The whole of layer 1 at two parameters, in beni, with
  corpus fixtures under `tests/corpus/run/` that read and write real payloads. It ships value on
  its own: today a beni program that touches JSON has nothing at all.
- **S2 — the well-known table (H2)** and `where a.schema : () -> Schema e a` as a *hand-written*
  pattern. Checker work, small, and §3.9(i) shows it already works.
- **S3 — H3**, the annotated-constrained-constant defect (`plans/queue.md` row 57), with its
  fail-first fixture. Independent of schemas, and it should not wait for them.
- **S4 — K13**, the namespace: `schema X` with **no body**, over a type that already exists, so
  `X.Type`, `X.Encoded` and `X.schema` resolve and nothing else is new. This is the slice that
  proves the owner's model with the least code, and under K13(c) it is nearly free.
- **S5 — the record body** (§4.3, §4.4), desugaring to S1.
- **S6 — `opaque schema`** (§4.5), the validated form.
- **S7 — `tagged`** (§4.6), the union half and its flattened `Encoded`.
- **S8 — K8**, ports re-specified on schemas, conditional on measuring `readForeign` against the
  existing generator.
- **S9 — the derived artefacts** (§6), one package at a time, starting with whichever the browser
  platform needs first.

**What changed from revision 1's order:** the namespace is now its own slice and comes before any
body syntax, because it is the part of the owner's model that touches the resolver and the part
that can be wrong in a way the rest cannot fix. The reverse order — declaration first — was
considered and fails on report 28 §10's argument: its desugaring target would be invented to suit
it, and the plain form would end up as something nobody would write by choice, which is how "sugar
over a library" quietly becomes a second language.

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
  throughout. §5.9's two wire forms for one type is the test that a "derive from the type" design
  fails and this one passes.
- **(3) two ways** is answered by making it literally one program: the declaration desugars in
  `bir/Lower.zig` into ordinary type aliases and ordinary calls, and an `emit/` golden proves the
  two forms produce identical bytes (§4.10). One semantics, one optimiser, one set of diagnostics.
  Under the owner's model this is *easier* to hold than in revision 1, because the declaration now
  defines a schema and nothing else, and a schema is a value the library could already build — the
  §3.9(i) project is the declaration's output written by hand, and it compiles today.
- **(4) drift** is answered by a line drawn in §4.11 and worth writing into the spec: **a modifier
  must mean something in a form submission and a query string, not only in JSON.** `as`, `via` and
  `default` all pass; `nullAs` and a date format string do not, and both are one-line library calls
  in the desugared form. The line is testable, which is what makes it hold.
- **(5) cost** is answered by the split. ≈ 1 700 lines is layer **2**, and layer 1 is beni that has
  to exist either way: today a beni program cannot read JSON at all, so S1 is not optional and is
  not part of this argument. What the declaration buys for its own cost is §7.1's first row — the
  seam of §3.4 closed by construction — which is the guarantee, not the keystrokes.
- **(6) the guarantee is thinner** is conceded and priced. The pair the declaration stands for is proven; a `via` is
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
   that matters — a declared schema’s reader against a hand-written Elm decoder, both after brotli — needs
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

Added in revision 2:

8. **Which of K13's three options the owner wants**, and what (a) really costs in the resolver.
   §8.1's 200–320 lines is an estimate from reading `resolveQualified` and the interface record,
   not from writing any of it. K13(c) costs zero and was proved to compile; (a) was not built.
9. **Whether K15's flattened union `Encoded` is what people actually want.** It is a type, it is
   the real wire shape, and it loses the tag-to-fields correlation. Nobody has written a beni
   program with a tagged payload, so the loss is reasoned about rather than felt. The nested
   namespace (`Shape.Encoded.Circle`) is the escape and was not costed beyond "it lexes".
10. **Whether K14 — a field position holding a schema — is easier or harder to learn** than a field
    position holding a type. The argument here is that it is easier *because it is what the
    declaration says it is*; that is a claim about people, and no one has used it.
11. **Whether the four-function `build` is too much for a hand-written schema to be a real
    alternative.** Revision 1's two functions were already the widest seam in the design; two
    parameters doubled it. If hand-written schemas turn out to be unusable in practice, layer 1 is
    no longer the plain form rule 7 requires, and that would be an argument for revisiting K1.

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
