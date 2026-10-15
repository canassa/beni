# Ownership soundness fix evidence — 2026-10-15

`before-ci/` and `after-ci/` retain the complete original-program interpreter
judgments and a replay of all 401 historical reverse leads. The pre-fix audit
intentionally failed its zero-confirmed-leads assertion (7 divergences); the
post-fix audit passed (0). Both used the same canonical streams. The baseline
long-run judgments remain in `../bridge-triage/`, with 201 confirmed originals.

`fixture-before.json` records explicit browser-direct checks of the six
unchanged pending witnesses: all exited 0 without a diagnostic. With the fix
set aside, the six promoted corpus refusals also fail as expected exit 1 / got
0; restored they pass with full `.diag` goldens. `app-impact.json` records the
full before/after diagnostics of four TodoMVC variants, TodoRouting and
Sternhalma, all byte-identical.

The follow-up report is `../../BRIDGE-FIX-RESULTS.md`. Its commands replay
original sources with the unchanged Lean checker and both interpreters.
The campaign compiler is frozen before starting; audit.json records its hash.
No persistent-runtime reduction is used to classify a program as safe/unsafe.

`after-long/` additionally retains the full campaign's report and compressed
sources/verdicts, including site-only leads. Its `audit.json` and
`judgments.json.gz` independently judge all 1,725 remaining original program
leads: none diverges. Exact stream SHA-256 hashes and coverage match the old
campaign. All six original cluster membership sets have zero surviving
program-level acceptances, and the 401 reverse refusals are unchanged.
