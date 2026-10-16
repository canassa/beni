## 2026-10-16 11:43 CEST — a record update keeps the lambda's key

**What I did.** PR #183 (issue #95) had an adversarial review. It found no behaviour defect, but one
program grew in raw and brotli bytes. `run app n` copies `app` with `{ app | tag = 2 }` and calls
`app.step n` once. The use count said "one use", so the release optimiser wrote `step`'s body at
the call. But the spread reads every key of `app`, so the key and the lambda stayed: the body was
in the output two times (raw 440 → 456). Now a key holds its value for the use count only when its
object literal neither escapes nor has every key read. The new fixture
`emit/release/app/SpecRecordLambdaUpdate` is red without the change. §9 says it, and it now calls
the marking of copied bodies a guard, not an exact count (a node newer than the facts has no
value). It also names the `update` rewrite that moved `split/HolesPage`. I rebased on `f9ade83c5`
(55 commits) and measured again. `bench/size.mjs` is 15 smaller and 1 larger (`ApiAndRoutes` +3
brotli, raw −22). The `browser/` corpus has 590 builds: 290 smaller, 5 larger, no raw increase.
Conduit `browser-tea` is now 48 brotli bytes smaller. Cesar accepted the Conduit +6 of the old
base (`release-purity-q2`).

**What I learned.**

- "Only holds it" was true of a key only while fact 3 can drop the key. A spread is the one read
  that reads a key without a node whose value is the function, so the walk did not see it. A
  condition that a later pass must meet ("the key goes") has to be checked with that pass's own
  test (`keyUnread`), not assumed.
- My `browser/` script dropped 20 project builds on errors and counted the rest. Count the builds
  and the failures, and compare the count with the corpus, before a total goes into a PR.
- `beni fmt --check` is a gate for a fixture too: a program copied from a review is not always
  in formatter form.
- A rebase over 55 commits conflicted in 289 run-hash files and nowhere else. `git rebase --skip`
  of the two commits that only held run hashes was the clean way through: the hashes are recorded
  again after the rebase anyway.
