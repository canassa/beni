## 2026-11-11 03:14 CET — 46 open record lines are beside a schema member

Part of #2477. Part of #1018. New issue #2480.

**What I did**

- 46 more open record lines of the parity net's known list have a reason: 34 are writes of a parse's answer, and 12 are updates of a new copy after `Schema.decode` took a schema value.
- New fixture `ownership/RecordBesideSchema` with its goldens: four writes that v1 accepts and v2 refuses, one of them a list's.
- New issue #2480: after `Schema.decode` takes a schema value, checker v2 refuses each later write of the declaration as `escaped`, also of an object that is made after that call. 158 lines stay open.

**What I learned**

- My first reading of the 12 lines was wrong. `update <call Record.copy>: rejected escaped` looked like a defect of `Record.copy` in the record pass. Four small probes found no such defect: a copy of a parameter, of a top-level value, and of a value that an unknown function took were each accepted. The cause was a line above the update, in another call.
- The probe that found it changed one thing at a time. With the schema value alone: accepted. With a parse alone: accepted. With `Schema.decode` and a schema value: each later write refused, also a push onto a new list. A table of such rows is the evidence that an issue needs, and it took less time than a reading of the checker's code.
- A cause word in a refusal names the rule that failed. It does not name the line that made the rule fail. `escaped` at line 250 was true for the model, and the escape was at line 248.
- Two known gaps made one new defect visible. v2 cannot identify a schema member (S7), and it reads core's `Schema.decode` as pessimistic (S6). Each alone refuses little. Together they escape a value that the model takes to hold each object, and the escape has no limit in time. The general defect is in neither gap, so it has its own issue.
- I put the probe into the corpus as a fixture of known debt. Its v2 golden holds four refusals that are wrong for the language, and the `.v2` file says so. A probe in a scratch directory proves a thing once. A fixture fails on the day that the thing changes.
