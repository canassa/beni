# Schemas

A `schema` declaration describes one piece of data at two typed ends: its **Encoded** form (what
JSON carries) and its program **Type**. The compiler writes a `parse` and a `print` for it, both
checked, and a description a program can inspect.

## The declaration

```beni
pub schema User =
    userId : Int as "user-id"
    nickname : String optional nullable
    tags : List String


pub schema Page a =
    items : List a
    total : Int


pub schema Message tagged "kind" of
    Text as "text"
        value : String
    Count as "count"
        value : Int
```

- A field is `name : Schema` plus modifiers. Fields are written in layout, one per line.
- `as "key"` renames the field or the variant on the wire. Without it the name is the key.
- `optional` marks a field whose key can be missing; its type becomes `Presence a`
  (`Missing | Present a`).
- `nullable` admits `null`; its type becomes `Nullable a` (`Null | NonNull a`).
- `via conversion` converts after parsing and before printing, with a `Conversion b a`.
- `tagged "kind" of` declares a union. Each variant carries its payload fields; the tag is written
  under the discriminator key.
- A parameter (`Page a`) is a schema the caller supplies: `Page.schema (User.schema ⊤)`.
- A schema can name itself or another schema of its module. Recursion goes through a `tagged`
  union.
- Operands: `String`, `Int`, `Float`, `FiniteFloat`, `Bool`, `Null`, `Value`, `List s`, a record,
  another schema.

## What a declaration gives you

| Member | Is |
|---|---|
| `User.Type` | the program type: a record alias, or a custom type for a `tagged` schema |
| `User.Encoded` | the wire type, with the renamed keys and the presence wrappers |
| `User.schema ⊤` | the `Schema User.Encoded User.Type` value, for `core/Schema` |
| `User.parse text` | `String → Result (List Issue) User.Type`, from JSON text |
| `User.print value` | `User.Type → Result (List Issue) String`, to JSON text |
| `User.parseWith`, `User.printWith` | the same with options first |

`import Models` gives `Models.User.Type` and `Models.User.parse`; `import Models exposing (User)`
gives `User.Type` and `User.parse`. The name `User` alone is not a type (`schema_used_as_type`)
and not a value (`schema_used_as_value`).

Every failure is a value: an `Issue` carries the path, the direction, a structured code and a
message. A `parse` never throws. With `reportInput = True`, an issue retains the failing input
when it is plain data. If the input contains a callback or native value, `Issue.input` is
`Nothing` (owner, 2026-11-02); reporting is off by default.

```beni
import Schema exposing (Issue)


pub schema User =
    userId : Int as "user-id"
    name : String


pub greeting : String → Result (List Issue) String
greeting json =
    user = User.parse json?
    Ok "hello ${user.name}"


pub roundTrip : User.Type → Result (List Issue) String
roundTrip user = User.print user
```

## Compiled composition

Every schema runs compiled workers. The builders in core/Schema construct and combine those
workers: Schema.string, Schema.int, Schema.list, Schema.nullable, Schema.converted,
Schema.record with Schema.field and Schema.optional, Schema.tagged, and Schema.recursive.
The runners include Schema.parse, Schema.print, Schema.decode, Schema.encode, Schema.read and
Schema.write, with options in their With forms. Schema.describe returns inspection data.
Descriptions are not executable validators.

Schema.flip, Schema.typeOnly and Schema.encodedOnly are unavailable.
Runtime imports from a description or JSON Schema are unavailable.

`Json.decode text` and `Json.encode value` read and write a plain type through its derived
`codec` method (`where a.codec`); `api-core.md` has their types.

Sources: `docs/design/schema.md` §1–§5, §12; `core/Schema.beni`; `core/Json.beni`.
