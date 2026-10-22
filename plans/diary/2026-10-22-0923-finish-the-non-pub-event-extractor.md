## 2026-10-22 09:23 CEST — finish the non-pub event extractor

**What I did**

- Took over PR #639 (Closes #532). A Cursor agent wrote it on a host that
  could not count instructions. I rebased it on master and answered the
  seven points of its `@claude` review.
- `Reach.privateExtractor` is now the one lookup for the `foreign` that a
  vocabulary event's `via` names when it is not `pub`. The reachability
  edge, the export list and the lowering's import call it. The markup tree
  keeps the event's vocabulary row instead of the name.
- A `via` with no declaration now stops a safety build, and the import by
  name passes the liveness wall, as a `pub` extractor's import does.
- Added `browser/dom/PrivateViaInVocabulary`, where only the vocabulary
  module uses the event. Also added a build test: an extractor whose event
  no surviving root names is not exported, and its body is not shipped.

**What I learned**

- To show that a fixture covers one branch, break only that branch. With
  the same-module branch broken, only the new page failed.
- When the export of a dead declaration is forced, the liveness wall of a
  safety build refuses the build. It fires before a text check of the
  output can see the name.
- `beni fmt` puts a short markup body on the line of its `=`. Run
  `beni fmt --check` on a new fixture before the gates, because a format
  fix changes the source and so the run hash.
- `chat_example_test` failed one time under a load average of 15 to 18: a
  `receive` step waits 5 s, and the page's first message came later. The
  next run of the same code passed.
