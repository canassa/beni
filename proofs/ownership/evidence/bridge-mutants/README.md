# Zig source controls

`report.json` lists every new program and site caught on the bounded CI stream.
Each baseline/dead/disjoint/shared directory has a complete compressed evidence
bundle, inspectable with `scripts/bridge-evidence.mjs case <directory> <id>`.
Verdict catches and runtime disagreements are separate: all three controls were
caught by verdicts, and no real runtime mismatch was confirmed.

These runs predate the final duplicate-site censoring. Their declaration-group
agreement/precision totals are retained for provenance. Control catches use
Lean-rejected main sites and whole programs; those were already unambiguous and
are unchanged by the censoring. Minima include recovered final-frontier skip
counts and original/final rejection messages.
