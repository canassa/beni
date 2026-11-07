## 2026-11-06 22:38 CET — a virtual call is an evaluation's

**What I did.** Fixed #2166 in `src/own2/`. A contract's labels are sorted, so an index moves when the contract gains a
label, and `e.w.virt` and `supply_of` kept a virtual call under `(call, index)` across rounds. My first fix named the record
by the label's identity and the code. Review showed the table itself was not needed, so `evaluate` now cuts `Frame.calls`
back to the walk's, empties `Frame.supplies`, and makes each virtual call from the labels it reads. `virt`, `supply_of` and
`Call.answers` are gone, a supply's key is its `Frame.supplies` index, and every index in a contract lives in the evaluation.
`AnswerKeep.repeats` counts only a direct label or one passed on now. `Virtual.zig` holds the making, for Eval's size target.

**What I learned.** The issue's probe was two defects deep. `b2` still trapped with identity keys alone, because the pair
memo of #2146 lost `q` too. Auditing `virt` found a third: a code read as unknown made its escape only in the evaluation that
made its record, so the round that judged a capture's write went without it (`run/SanitiserWildCodeRounds`). I also called
`repeats` conservative in the PR, and that was wrong: `true` lets a holder off, so a stale label was the permissive way round.
I had read the name and not its callers.

I kept `virt` at first by arguing its ids must be stable for `Kept`. That argument was weak. `Kept` compares ids only when the
group's print says the round read what the one before read, and then the evaluation is the same one with the same numbers.
The roots left behind are unreachable and cost 0.12 % of core's records. Measure the simple design before defending the
table. `Frame.cbs` does stay, since a leaf `answer` holds its index.

A generator of mine shows a limit: `r` held whole is refused when `q` reaches only `r.1` and `r.0` is read (#2202).
