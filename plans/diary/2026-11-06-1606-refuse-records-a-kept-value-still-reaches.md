## 2026-11-06 16:06 CET — refuse records a kept value still reaches

**What I did.** Fixed #1000 and #1001 in v1. The record probe read only the root of what a call hands
to a function value, and a failed probe is what brings §16.4's keep edge into play. Three edits: the probe
covers every path of the value; a read after a probe is a use, because nothing hoists it; a local that
holds something inside the handed value is a holder of it. The holder rule applies to lists too.
Promoted both pending fixtures and added `run/` fixtures with accepted twins. Each edit is proved
necessary by reverting it alone.

**What I learned.** The twins were worse than the issues. `b = f r` then `r.x`, with `f` a callback that
writes `r`, printed the written value on master. A probe counted a field read as hoisted, and only
real demands publish hoists. A list below a kept record, bound before the call, also trapped under the
sanitiser. Over 2018 roots no verdict moved, so no refusal reaches core, a platform, an example or
`bench/corpus`. Only `browser-inline` enforces, and its summaries did not move. #1990's probes are
unchanged (233 probes, 25 still wrong), so that root is another one. The accepted cost: a read in one arm
and a write in another arm of a callee are refused together. `test-run-hashes` is no longer a build
step, though CLAUDE.md names it; the hashes are a local cache now.
