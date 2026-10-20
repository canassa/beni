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
- `optional` marks a field whose key may be missing; its type becomes `Presence a`
  (`Missing | Present a`).
- `nullable` admits `null`; its type becomes `Nullable a` (`Null | NonNull a`).
- `via conversion` converts after parsing and before printing, with a `Conversion b a`.
- `tagged "kind" of` declares a union. Each variant carries its payload fields; the tag is written
  under the discriminator key.
- A parameter (`Page a`) is a schema the caller supplies: `Page.schema (User.schema ⊤)`.
- A schema may name itself or another schema of its module. Recursion goes through a `tagged`
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
message. A `parse` never throws.

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

## The library

`core/Schema` has the same engine as a library, for a schema built at run time: builders
(`Schema.string`, `Schema.int`, `Schema.list`, `Schema.record` with `Schema.field` and
`Schema.optional`, `Schema.nullable`, `Schema.tagged`), the runners (`Schema.parse`, `Schema.print`, `Schema.decode`, `Schema.encode`) and `Schema.describe`,
which renders a description. A `schema` declaration compiles to specialised code and is faster
than the library on every workload; use the library where the shape is known only at run time.

`Json.decode text` and `Json.encode value` read and write a plain type through its derived
`codec` method (`where a.codec`); `api-core.md` has their types.

Sources: `docs/design/schema.md` §1–§5, §12; `core/Schema.beni`; `core/Json.beni`.
