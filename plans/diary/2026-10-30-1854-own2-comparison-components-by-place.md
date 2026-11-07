## 2026-10-30 18:54 CET — own2: a derived comparison is composed at the places its components occur

**What I did.** Fixed #1331, two spurious refusals #1324 left. (1) The walk
of a derived comparison no longer enters a type that has a user-written
comparison of its own: it records the class at that place and stops, so a
read-only `Outer.eq` no longer picks up the `Inner.eq` of its fields. (2)
`Rows.derivedClass` now takes components as (place, class) and builds the
argument's use per place: `R` on the way, `R` deep on branches that lead to no
component, and `R`/`E`/`W` deep only at a component's place. Built once per
place with a memo (a doubling DAG type, `EvidenceDagBuildDepth32`, made a
first version that enumerated paths blow its limit); a cycle makes the place
it returns to a deep leaf with the union of what is below. Fixtures
`CmpWritesInside` and `CmpComponentsImported` hold both repros plus refused
companions (kept-written list, second tuple slot, list, recursive type). Six
earlier goldens and their known-file keys gained the path in the label
(`<Wrap …>#Wrap.0`, `[*]`); their verdicts did not move. §2.13 item 13 says it.

**What I learned.** I did not use `Dispatch.Derived.body`: the place graph
already holds the concrete type of every component, evidence arguments
included, so stopping at a ctor place with its own comparison is the same
resolution without a second table. A single module cannot hold both repros of
item 1: `eq` and `compare` are one value per module, so a type's own
comparison and its component's cannot both be named; the imported fixture
does. Path enumeration was the wrong first idea; shapes are persistent, so
build them per place.
