## 2026-09-22 11:28 CEST — Close the schema prototype as dated research

**What I did**

- Pulled first: the default rebase pull refused the existing uncommitted work;
  `git pull --no-rebase --ff-only` preserved it and reported already up to date.
  Read the plan, report, complete prototype tree and CLAUDE rules 1–5. Reproduced
  the original 50/50 and its exact sizes before changing a file.
- Added three limitation assertions for the tagged reader: fractional payload
  loses its field path, `maxDepth = 0` is ignored, reordered keys are rejected.
  Recorded the unenforced context-ownership gap as report 33 §4's fifth bullet;
  did not change the representation or start its next slice.
- Added a nested recursive-definition probe. It found omission, not duplication:
  only the outer definition survives. Pinned the whole two-sided description
  and recorded this separate defect as queue row 61, without fixing it.
- Changed the malformed-JSON fixture to assert boundary-owned `invalid JSON`.
  Proved it red first (only that assertion failed, other 53 passed), then made
  `Wire.parse` normalize host `SyntaxError` to that message.
- Ran the full Node 24 / Chrome 153 runner: 54/54, both negative fixtures exact,
  deterministic dev/release outputs at jobs 1/8. Committed `results.json` exactly
  as captured. Development 113,935 raw / 17,970 concatenated Brotli; release
  61,696 / 14,541. All three project gates, Beni formatting and staged whitespace
  checks passed. No production `src/`, `core/`, `platforms/` or build file changed;
  even the prototype's `src/Schema.beni` was left untouched during close-out.
- Committed the evidence as `9a8f903`, separately from this report/plan/queue/diary
  close-out commit. The artifact is dated research, not a feature or build gate.
  Left the untracked `.agents` and `AGENTS.md` symlinks out of both commits.

**What I learned**

- A transparent record of arbitrary endpoint functions cannot guarantee context
  threading. Correct library combinators do not make hand-written endpoints
  safe: the interpreter or closed construction must own paths and traversal
  limits. This is a guarantee-shaped reason for the next AST representation.
- The dedupe premise needed checking: `List.append` is in `object2Endpoint`,
  whereas `recursiveEndpoint` publishes a singleton and loses nested definitions.
  No duplicates in this probe does not mean definitions are correct or deduped.
- Pinning complete, deliberately wrong results documents an experiment's limits;
  it is not production conformance. A host engine's syntax-error prose is not a
  stable fixture contract, even when Node and Chrome happen to agree.
