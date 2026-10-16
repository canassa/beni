## 2026-10-16 04:28 CEST — An unidentified callee's result is never owned

**What I did.** Issue #216, `ownership-checker.md` §30.10. §6.1's conservative call claimed its result was
a cell made by the call, so a function read out of a `Dict`, an element of a list of functions, one
handed on through a parameter, or a top-level value that is a lambda could return the top-level
`shared` and have it pushed onto in place, accepted `assumed`. Now such a result is `⊤call`: a write
onto it is an approximate `unknown` rejection and a `need` resting on it fails; `unknownCb` (a callback
whose actual has no class) answers the same. A dot call of a record field (`api.search q`) is now the
field's value called, as `(api.search) q` was, so it is a slot — without that, `DebouncedSearch` would
have been rejected. Schema constructors (`Tree.Leaf { … }`) and schema members (`Tags.parse`, #218's)
keep the made cell. A supply through a callback whose result holds a `⊤` labels approximate. The copy
suggestion no longer prints `((List.copy (f ⊤)))`. Fixtures: `ownership/UnknownCallee`,
`UnknownCalleeTagger`, `check/bad/direct/UnknownCalleeShared`, all red on master; `NominalHolds`
rewritten so rule 4 is pinned where it still decides something (a live conservative result as a
holder). `bench/ownership-everywhere.mjs`: 4 of 847 programs rejected — the three known and
`bench/corpus`'s `FormValidation`, a limit filed as #223. Conduit, TodoMVC, Sternhalma and Bike Wars
check clean on `browser-direct`. The Lean bridge at its CI bound: exit 0, 6 leads, none confirmed, as
on master.

**What I learned.** The measurement script does not cover `tests/corpus/ownership/`: the schema
constructor regression showed only as a cache test's miss in the gates (`SchemaCtorBlock`), because a
rejected check writes no cache entry. A summary that says `⊤call` is honest about a real limit: a
lambda's call of its own function parameter, or of a function a call returned, has no class, and
`FormValidation` is exactly that shape.
