## 2026-10-22 10:04 CEST — review round of the non-pub event extractor

**What I did**

- Fixed the four findings of pointer-review on PR #639. A vocabulary module
  that used its own event with a `pub` `via` imported the extractor from
  itself, so its development module declared `Probe$probe` twice and did not
  load. The `pub` path of `extractor` now writes the local name there too,
  as the private path does. The reviewer's test project is now the page
  `browser/dom/PubViaInVocabulary`.
- Corrected two amendments: in the vocabulary module itself, the lowering
  writes the extractor's name and imports nothing. Rebased on master and
  recorded the run hashes again.

**What I learned**

- A red check script that takes a file from `HEAD~N` must name the commit
  before the fix, not count back. I added a commit after the fix, so
  `HEAD~2` was the fix itself, and the first red run passed. Check that the
  old file does not hold the fix before the run.
- The review's case of a `pub` extractor in its own module was a defect
  before this PR. The same function had the same-module test on one path
  only.
