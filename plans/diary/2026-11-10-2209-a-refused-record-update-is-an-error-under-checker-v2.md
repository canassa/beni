## 2026-11-10 22:09 CET — a refused record update is an error under checker v2

Part of #1018 (S5b, fourth part).

**What I did**

- In a build that enforces, checker v2 makes one error for each refused record line, with the record codes (`record_still_used`, `record_may_be_shared`, `top_level_record_changed`). The message's last sentence names the fix, `Record.copy`.
- The record pass's limit is a limit: a line `limit <name>: <limit> (record pass)` in the report, and one `ownership_limit` error.
- The v2 check of an `ownership/` fixture reads record lines too. Fifteen `run/` fixtures changed, each for a reason: ten name the record refusals in a golden, three accepted twins change a copy, and my two fixtures of the step before have new names and a refusals golden.
- One new fixture, `ownership/RecordTopLevel`, and `.v2.diag` goldens on three fixtures, pin the three codes.
- Two mutants (`record_refusal_quiet`, `record_limit_quiet`), each killed. Two mutants of the step before survive now and are equivalent.

**What I learned**

- A step can make the last step's guard invisible. In the step before, a module with a refusal kept the spread, and two mutants of that rule were killed by programs. Now the build stops at the refusal, so no program can show the rule. The mutants survive with no change of their code. I kept the guard, because the conversion reads it and v1 has the same second guard, and I wrote the reason beside the survivors.
- Three accepted fixtures were written when an update was a copy. Their comment said so: "a copy the update made". When an update writes in place, such a fixture is refused, and the honest repair is the explicit copy, not a refusals golden: the fixture is the accepted twin of a refused one, and its sanitised run is the evidence.
- The known-differences list keys an entry by line and column. I first added a comment line to a fixture, and thirty entries were stale. I rewrote the comment in the same number of lines; then two entries moved, by the width of `Record.copy `.
- The v2 check of an `ownership/` fixture, and its `.v2.diag`, run only where the fixture has a `.v2` file. My first blessed `.v2.diag` was empty and the case was green: an empty golden that nothing reads looks like a passing test.
- The record pass uses the allowance of the list pass and costs more for updates. The near-limit test's declaration (92 updates of one record) is under the allowance in the list pass and over it in the record pass. With enforcement this is visible: it is an error where v1 has none.
- A limit's diagnostic has no position of its own. It points at the module's first region.
