## 2026-10-30 19:54 CET — own2: a component's two parameter uses are merged by path (#1344 re-review)

**What I did.** The re-review found a lost write: `component()` joined the
component class's two parameter uses with `Shape.join`, which makes a `union` of
two nodes, and `Calls.marked` does not go into a union. A comparison that writes
below its first field (`Outer2.eq` calls `Inner.eq`, `π1#Outer2.1#Inner.0 W`
against `π2` read only) lost the write. `UseMerge` merges the two use shapes
path by path instead (a leaf, or anything else, becomes a deep leaf of what
both reach). Fixtures: a writer at depth 2 and depth 3, in one module and
imported; a list, a tuple, a fresh value around a parameter, a parameter used
twice and a call through a function; `Ref.make [ xs ]` kept beside `xs`.
The wide test pins 80 against 160 fields (ratio at most 2.2); the doubling DAG
test moved to #1356.

**What I learned.** The depth-1 fixtures could not see this: with one
parameter's use the join is the use itself. A single-module fixture needs
`eq` to read the second argument too, or the two uses are equal. With the
writes now found, a wide type costs about 243 records a field (not 120) and
stops on a lane invariant near 300 fields (#1358). The cost the earlier
numbers showed was the writes that were lost. The cycle collapse still marks
all of a recursive type as written (#1357).
