## 2026-10-30 19:25 CET — own2: temporary arguments read, a write's other paths linear

**What I did.** Fixed #1330 and #1334 in one branch, `own2-temp-args`.

#1330: a callee's read below a parameter part was lost when the argument
was a new value. `rbc { b = g.x }` with `rbc r = List.length r.b.c` gave
`π1.x R`, so a push of the list `g.x.c` holds, with `g` read later, was
accepted; v1 refuses it. The read-off only looked at a local's root cells,
so a temporary (a record, a tuple, a constructor, a call's result, a field
of one) and a local that is a construction (`h = { b = g.x }; rbc h`) were
never composed. `Transfer.readsOf` now walks each call argument and case
scrutinee with the callee's use node, as a DAG, down to the value's
leaves, and records the parameter cells it meets (`param_reads`). The
read-off marks `R` there and grafts the callee's use below them. They are
not liveness uses: those are a local's (§2.7), and the frame's own demands
were already right, because the reads that build the temporary are whole
uses at an ancestor. Fixtures `ownership/CallTempArgument` and
`CallTempArgumentImported` have v1's verdicts and fail on master.

#1334: a callee writing n fields of one parameter cost its caller n², and
hit `ownership_summary_size` at 256 fields (the invariant of the issue
had already moved to growth in #1329's last round). Two cells whose bases
may not alias never conflict in Disjoint, so a write's other-paths operand
now keeps only the cells whose alias key is one of the base's, and a node
of the write's path finds its children beside the write by those keys
through `Calls.Beside`, an index built once per call. 64 → 256 fields:
4 445 → 18 455 records; a literal of 64 → 128 lists: 5 275 → 10 857 (was
53 017 → 226 795). Two counted build tests pin it, and
`ownership/CallOtherPathsKeys` pins the conflicts the index must still
find.

Verdicts over every `ownership/` fixture and `run/` program are unchanged.
23 summaries gain `R` at an `A` path below a new record (`sameParam`:
`π1[*] A` → `RA`), from the graft's rule that every marked path is read;
`CallFieldStep.written` gains `π1[*] R`, which v1 also has.

**What I learned.** `List.length (pick g.x).c` with an unannotated `pick`
is still lost: a call result at a type variable's place is a place-only
recast, and a step into it is the whole value, approximately. Fitting the
target to its type first does not help, since the recasts compose to a
same-place recast over a leaf, which `recastPart` refuses (it also marks an
approximate part). I opened #1350. Root reads of every consumed temporary
cost the 600-spread and escape counted tests their bounds; a store or a
binding only moves a value, so reads are taken only at calls and case
scrutinees, and a bare local's root is the read-off's own. Transfer hit
its §5 size target; the index went to Calls, which had room.
