## 2026-11-02 07:26 CET — ownership v2: slice 4 done, DOD S0–S4, the local-domain question

**What I did** (as manager of ownership v2; agents built, adversarial reviewers checked each PR)
- Finished S3b slice 4: the fold certificate (#1529, closes #1485, #1559, #1570), after the spec (#1519, #1572) went through 4+ review rounds and two independent Astra rounds that found real holes.
- Fixed unsound accepts. In v2: #1516 (generic call result), #1523 (`leq` missing `⟲` children), #1530 (pattern reads), #1526 (slice memo key), #1582 (knot entry not moved). In v1, the default checker: #1568 (canonical-marker levels).
- Landed the v2 stale-read trap (`--ownership=v2 --sanitize-lists`, #1555, follow-ups #1569 and #1583) and fold-first `propagate` (#1554).
- Data-oriented layout work S0–S4 (#1648, #1650, #1659, #1669, #1674) cut instructions 3.2–3.4×, with no verdict change. In the LLVM build, dictionaries dominated (35–55%), and S3 replaced them.
- Test speed: v1 guard table (#1598, 4× on the tuple-DAG fixtures), harness duplicates removed (#1586), safety allocator made opt-in (#1611), playground job reduced to hand-picked programs (#1575).
- Specified the worker protocol and native backing moves, and moved the `Ref` work forward to follow S4 (#1672, seven review rounds).
- Ran two experiments on `Dict.removeMin`: compact recursive contracts (#1655), then contracts + S6d (#1671).

**What I learned**
- Rules that are exact on paper keep turning out to depend on the representation. Every review round found a real hole, so the rounds are worth their cost.
- Contracts fix recursion growth. But the cost of one walk of a body is v2's local value model: shape nodes, routes, views read lazily, and κ per position. removeMin does about 100k records per walk against a 65,536 budget. The open question for the owner is whether to move to a slot-keyed local domain. A second Astra review is drafted at `~/.cache/beni-agents/astra-review2/prompt.md`.
- Cutting cost per record (DOD) and cutting the number of records (the domain) are separate problems. The budget counts records.
- Two independently reviewed changes can still clash (the atom rule and the certificate, #1559). Cross-checks must not charge the real account or leave table state behind (#1545, #1632).
