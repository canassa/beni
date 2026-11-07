## 2026-10-29 11:14 CET — Two log-context PRs meet the ownership v2 net

**What I did**

- Rebased #918 (#811) onto `master` `d331cb7da`, whose gates now hold the
  ownership v2 differential. Its first gates run failed on two kinds of
  golden only: `tests/corpus/ownership/core.v2.unchecked`, because
  `withSlotsOf` adds 24 lines to `core/Task.beni`, and the missing
  `.v2.unchecked` of the two new pages. I made them with
  `BENI_WRITE_EXPECTED=1` and `BENI_BLESS_ONLY`, as `ownership-v2.md` §7.2
  says, and checked the core diff by script: only moved lines and one new
  entry, `Task withSlotsOf (not built: call)`.
- Stacked #859 on the new #918 and did the same: `restoreSlots` is 4 lines
  longer, so 90 `Task` entries move. Opened it as #1134, with base
  `node-log-teardown-context`.
- Answered the review of #1134. No code changed, but the amendment of
  `boundary.md` §9.8.16 (b) said more than the code does. It now says that
  the order holds only when the body closes nothing after the throw (#921),
  that a body in a fiber that ends drops `update`'s finalisers (#1154), and
  that a body with no log context of its own keeps `update`'s (#1153).

**What I learned**

- A `.v2.unchecked` golden names line ranges, so every change to a core
  file moves the entries below it. Expect a core golden diff with each
  `core/` change, and check that it holds only moved lines. A comment that
  keeps its line count moves nothing.
- The core golden is checked before core's parity, so a golden failure
  hides the parity result. A bless run of the whole ownership walk shows
  both: it writes the golden, then runs the parity.
- `BENI_BLESS_ONLY` matches a fixture's path, and the core golden's path
  separately, so one value cannot bless both. Two bless runs do it.
- The gates with the v2 net peak near 10G. The first run in a job after
  other steps hit the heavy-run cap; the gates alone stayed under it.
- "In every case" in a spec amendment is a claim on every path. The
  fixtures pinned two paths, and the reviewer's probes found three more
  where the text was wrong. Before I write such a sentence, I list the
  paths: with and without a context, in a fiber and not, the body closes a
  scope or ends or waits.
