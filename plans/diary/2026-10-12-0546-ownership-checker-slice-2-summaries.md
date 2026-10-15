## 2026-10-12 05:46 CEST — ownership checker, slice 2: summaries

**What I did.** Specified slice 2 in `ownership-checker.md` §15–§16 (the manager's answers to §14,
then the summary's fields, read-off, application at a call with the caller's side of a written
parameter, function-value classes, the optimistic fixpoint with a join, the width cap, the library's
asserted primitive rows, and the interface block it will publish) and built it in `src/own/`:
every function and top-level value gets a summary, computed on demand in dependency order; calls
go through them; lambdas get classes checked against what their callee supplies; recursive groups
iterate to a joined fixpoint. Twenty `core/List` primitives over `Js` carry asserted rows; `map`,
`update`, the folds, `Dict` and the rest are inferred. The dump gained call-site demands, `value`
lines, a `pending` verdict, summary lines and `--ownership-totals`, and checks core itself. Ten
new fixtures, a differential one against the Lean model's verdicts, and research 76.

**What I learned.** Slice 1's provisional acceptances mostly hold (294 of 311 outside the list
tests) and TodoMVC's I5 rejection goes away; every application demand is accepted or waits for the
entry protocol. The one thing inference cannot reach is the destructive read: `update`, `map`, the
folds and `Dict.update` hand an element out while the container is still read, so a callback that
edits its element is rejected — all four disagreements with the Lean model are this. Summaries
needed two thesis pieces slice 1 did not: folding recursive types (every `Dict` summary blew the
cap) and numbering fresh cells by the result paths they reach (Conduit's `update` had 2 601
provenances). A top-level value must share only the cells its definition makes, or `Dict.empty`
poisons every dictionary. The pass costs 38–74 % of a check when it runs; `check` itself does not
run it and did not move.
