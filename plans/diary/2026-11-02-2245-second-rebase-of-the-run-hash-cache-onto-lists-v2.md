## 2026-11-02 22:45 CET — second rebase of the run-hash cache onto the lists-v2 pass

**What I did**

- Rebased #904 (`run-hashes-leave-git`) a second time, from the remote head
  8b95f8261 onto master 16f7437c4f, 130 commits later. 754 record files
  were modify/delete conflicts and 16 were new on master; every one is
  deleted in the one deletion commit, as before. 0 record files remain.
- Resolved the one content conflict, `tests/blackbox/corpus_test.zig`:
  master added the v2 twin of the lists pass (`out-lists-v2`,
  `.sanitize-lists-v2`, `BENI_IN_PLACE=lists-v2`) as a loop over two
  `ListsPass` rows, with its own slot in the fixture's record. On this
  branch the record is gone: each pass of the loop calls `runOnceCrash`,
  which looks the pass's digest up in the cache before Node and records
  it after the verdict, and the `lists-v2` sweep looks nothing up and
  records nothing, as the `lists` sweep does. A fixture whose
  `-refuses` golden the checker accepts runs its sanitised build through
  the same call: the case fails whatever the run prints.
- Added the v2 pin test beside the v1 one: a program whose lists-v2 pass
  must crash and does not fails the walk, and the cache holds the
  development pass's digest only.
- Fixed one README sentence that still gave the two sanitiser passes'
  digests to "the fixture's" record file: they go to the cache.
- Checked master's other changes: the new `browser-plan` and `browser`
  CI jobs run `test-browser` in Chrome, which uses no run-hash cache (the
  owner, 2026-10-28), so they need no restore or save; the nightly
  `schedule` runs the `tests` job, whose cache steps are unconditional.
  `browser/inline/` pages go through `runPage`, so they use the cache.
  No harness code reads or writes a record file.
- Gates `-j2` through heavy-run: green twice on the rebased head. Cold: 278 s wall, 1 048 s user + 251 s system CPU; 1 461 of 3 202 program runs had no verified digest and ran under Node (the 130 master commits changed their output), 11 775 digests after. Warm: 190 s wall, 773 s user + 182 s system CPU. Peak memory of the scope 3 810 MiB both times.
- The branch's own diff before and after the rebase differs only in the
  lists-v2 lines.

**What I learned**

- A rebase loop that resolves record conflicts with a glob `git rm` is
  wrong at a content-conflict stop: the glob removes every tracked record
  file, the code pick absorbs the deletion and git drops the deletion
  commit as "already upstream". Resolve only the conflicted record paths
  at every pick but the deletion pick.
- `git rerere` records a resolution at the first attempt and replays it
  on the second, so a reset and a redo of the rebase cost nothing.
- In zsh, `$ref:tests/x` is the modifier `:t` on `$ref`; write
  `${ref}:tests/x`.
