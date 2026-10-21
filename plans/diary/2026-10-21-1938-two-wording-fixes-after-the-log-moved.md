## 2026-10-21 19:38 CEST — two wording fixes after the log moved

**What I did**

- Fixed the two wording nits the reviews of #547 and #549 left for later: `boundary.md` §9.8.1
  still named `Log` among the modules that gain a command (it is `Cmd.log` since the move), and
  the serve driver's README and comment said that every IPv4 address becomes `<address>`.
- Recorded the server fixtures' run hashes again: each record covers the driver's bytes, so a
  comment in the driver moves all 25 of them.
- Carried #547 and #549 through five rebases while `master` moved, each with one locked job of
  skill-api, test-run-hashes and the gates, then a lease push at once.

**What I learned**

- A served fixture's run hash covers the driver's bytes, comments included. A change to the
  driver is cheapest in a PR of its own, so that no other open PR conflicts in those 25 files.
- When `master` moves during the gates by a docs-only commit with no conflict, rebasing onto it
  and pushing at once is safe: the gated tree and the pushed tree differ by that file alone.
