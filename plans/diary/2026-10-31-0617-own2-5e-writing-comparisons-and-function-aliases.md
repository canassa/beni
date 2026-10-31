## 2026-10-31 06:17 CET — own2 5e: writing comparisons and function aliases

**What I did**

- Built S3b PR 5e (#1434, part of #1016) on the plan in `ownership-v2.md` §8 and the manager's Q4 and Q5
  on #1421.
- R-5.13.1: a type's `eq` or `compare` (the module's value of that name whose first parameter is of a
  type the module declares, `pub` or not) is walked with `comparison` set. Each demand the six
  conditions accept as `param` becomes a refusal with the new cause `comparison`, a position rule, and
  the new code `comparison_changes_value`. A refused demand keeps its cause. The class keeps its `W`.
- R-5.5.6: an alias of a function (a value with no parameters whose body is a bare name, of a function
  scheme) is not walked. A call follows the callee's names through `Prepass.aliasTarget`, across
  modules, and applies what the end of the chain has: words, walked class, group port or block class.
  The line names that function, as v1 does.
- Specified in place: §2.11 and §2.13.13 item 13 have *As built* notes, R-6.3 has the cause, language.md
  §10 has the code, the corpus README has `.v2.diag`. Groups' line target is 1 840.
- Fixtures: `ComparisonWrites` (from `tests/pending/check/bad/inline/`, with a `.v2.diag` that the
  harness now compares), `AliasWriterCall` (from `tests/pending/ownership/`), new `AliasGroupCall` and
  `AliasImported`. Each fails on master's `src/`. 31 known entries.

**What I learned**

- A top-level alias cannot be in a recursive group: `again = pushN` with `pushN` calling `again` is
  "a value defined in terms of itself", the checker's error. So the group fixture has the target in
  the group and the alias outside it.
- A private `eq` answers `==` inside its module (Dispatch resolves it there). For this reason the
  comparison test does not require `pub`, though `Prepass.method_of` does.
- Fourteen existing fixtures had a writing comparison accepted as `param` (eight `Cmp*`,
  `ContainerOverWriter*`, `DerivedOverWriter*`, `EvidenceDeep`, `PrivateEqThroughShapes`). Their
  summaries and blocks did not change. Their `.v2.ownership` goldens also had stale summary and
  account lines, which the harness does not compare.
- After an edit under `src/`, `zig build gates` took 2 min 8 s on this machine, and the full
  corpus took 70 s.
