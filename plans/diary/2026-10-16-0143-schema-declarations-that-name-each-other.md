## 2026-10-16 01:43 CEST — Schema declarations that name each other

**What I did**

- Fixed #196. Two tagged schemas that name each other made the checker report
  an `internal` once per derived-context pass. The cause: `ContextUnits.mentions`
  read a schema's references off `declRefs`, but a schema body records none. Its
  operands are resolved in place (`schema_target_top`). A tagged endpoint
  therefore had no mention edges. The two schemas were two units, and the first
  one's pass ran the second's fixpoint nested, which read the first's
  approximation. `mentions` now reads the resolved operands too
  (checker-v2.md §11.5, *amended 2026-10-16*).
- Probing the shapes the issue asked for found two more defects, both fixed:
  - A record schema between two tagged ones that name it (`Expr` holds `Stmts`,
    which holds `Stmt`, which holds `Stmts`) was a false `recursive_alias` in one
    declaration order. Naming a tagged schema built it first, and the build met
    the record still building. A tagged schema is its nominal endpoints, so
    `Schema.localTarget` now names it without building it.
  - A generic pair that hands its parameter round (`Ping a` ↔ `Pong a`)
    described without end. `describe` overflowed in the compiled path, and so
    did every use in `--schema-library`. Each reference called the other's
    description factory, which made a new `describedRecursive` cell per level.
    `SchemaLower.descNode` now describes such a reference as the member's body
    under its own cell, inside the referring description. A scope of in-scope
    cells replaced the single `self`.
- Fixtures: `check/good/SchemaMutualTagged` (the issue's reproducer),
  `check/bad/SchemaMutualExclusion` (a function reached through the cycle, the
  encoded side still compares), `run/SchemaDeclMutual` (a pair, a ring of three,
  a cycle through a record schema and a generic pair; parse, failure paths,
  print and compare; `.compiled-schemas`; the library differential), the
  mutual pairs in `run/SchemaDescribeDeclared`, and three `ordering_test`
  permutations. I proved each part red on its own by applying the fix one
  file at a time.
- Filed #213: polymorphic recursion (`Nested a` holding `Nested (List a)`) still
  overflows in `describe` and in the library path, self-recursive or not. It
  owes a spec decision (schema.md §4, *amended 2026-10-16*).

**What I learned**

- The scratchpad directory is shared with other sessions. `r2/` already held
  another session's `Holes.beni`. Keep probes in a uniquely named subdirectory.
- A schema body's references never reach `declRefs`, so `bindingGroups` does
  not see schema-to-schema edges either. That is harmless there, because a
  schema group demands what it names, but any new reader of schema
  dependencies has to walk the body.
