## 2026-09-21 21:25 CEST — schemas: from "derived codecs" to a `schema` declaration at Effect parity

**What I did**

A design conversation with the owner, starting from report 31 (another session's) and ending in a
decided model. No code changed. One research agent, docs only, resumed once.

- The owner set the bar — "as powerful as Effect schemas" — and then corrected my first three
  proposals in turn: deriving a schema FROM a type is not enough ("there are two different types for
  the same schema… most real life schemas have different representations"); new syntax is wanted;
  and "we are defining a schema User, not a type User". Decided: `schema User = { … }` defines a
  schema; its types are reached through it as **`User.Type` / `User.Encoded`**; **no shorthand**.
  Recorded in `plans/queue.md` and memory.
- A quick family-only web survey (Elm, Gren, Lamdera, Gleam, Roc, Mint, Derw, Grain, plus
  rescript-schema and Thoth; no powerful type systems, no code generation — the owner's scope, after
  they stopped my first, too-broad brief): two camps — write reader and writer by hand (Elm, Gleam),
  or the compiler does it and cannot express a rename or a default (Roc, Mint, Lamdera); elm-codec
  and rescript-schema in between; nobody has one declaration giving both types and both directions.
- **Report 32** (`78e58b0`, revision 2 `e687c93`), designed from Effect's `SCHEMA.md` docs only:
  164 capabilities answered (same 43, different 67, not needed 38, cannot 14 — ten of them
  pick / omit / partial, a type computed from a type — help 2); `Schema e a` carries both sides;
  a field position holds a SCHEMA, so `via` names the wire side (`createdAt : Int via Date.millis`);
  a tagged union's `Encoded` is a flattened record; the schema is used as `User.parse` or passed as
  `User.schema ()`. K1–K16; K13–K16 await the owner.
- Validation: the agent's check projects re-run (exit 0); namespace claims verified with the binary
  (`User.Type` resolves as a qualified type; a Capitalised name in expression position is always a
  constructor); parity rows spot-checked against `SCHEMA.md`.
- **The report found a real compiler defect and I reproduced it — queue row 57**: an annotated
  top-level value with a `where` clause and no parameters builds with exit 0 and the program then
  throws `TypeError` at run time. NOT fixed; the owner has not yet said to.
- Committed the other session's work with this one at the owner's word: reports 30 and 31, the
  `hackernews` skill, its `CLAUDE.md` line and its diary entries.
- Answered two language questions from the docs and `core/`: beni has no `comparable` (static
  dispatch replaced it; any type can be a `Dict` key), and no arrays, so no bounds checks — every
  lookup returns `Maybe` or clamps; W35's `Array` would return `Maybe` on `get`.

**What I learned**

- **My vocabulary was the obstacle, twice.** "Codec", "derivation", "dispatch", "round-trip" made the
  first explanation unreadable; then "what the compiler generates", shown as source, read as code
  generation. What worked: one `User` and its JSON, and the two lists "what you write" / "what you
  can then refer to".
- The owner's model was better than mine each time it differed. "The schema is the thing" removed
  the invented `UserWire` name and the implicit type, and forced the two-parameter `Schema` that
  makes `Encoded` usable. Offer the sketch, then listen for the noun the owner uses.
- "No new syntax needed" was wrong, and the report's unargued "needs syntax" was right for a reason
  it did not give: without computing a type from a value, ONE text yielding TWO types is only
  possible if the compiler reads the declaration.
- Asking a design agent to verify grammar claims with the binary paid again: it is how the defect in
  row 57 surfaced, and how `Schema.parse User text` was ruled out before anyone got attached to it.
- A brief that is too broad gets stopped. The owner's four-line scope produced a better survey in
  2.5 minutes than my 40-line one would have in fifteen.
