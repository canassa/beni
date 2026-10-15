## 2026-10-14 01:56 CEST — preserve fresh fold accumulator ownership

**What I did**

Continued ownership-fold-invariant from up-to-date origin/master. Specified the
fold invariant and its Lean-oracle risk, then implemented separate container
conditions for all four List/Dict folds and focused edits. Tea.want uses
Dict.update without copying its tap list. Promoted SubscriptionTapFold and added
three page variants, a four-fold ownership report, and five rejected build twins.

Recovered the pre-fix regression logs: the subscription builder fails on master,
and the capture-after-append closure twin incorrectly succeeds there. Corrected
recursive summary convergence to compare the new container conditions, with a
focused unit check. Every pre-existing ownership golden remains unchanged.

Native zorg build gates with pinned Node 24: 1 293 pass, 15 skip, exactly the four
acknowledged macOS failures (two case-folding, two browser-driver CPU budgets).
Run hashes were recorded in the preceding work; the corpus passed and the only
recording failures were the two known case-folding tests. No LLVM validation.
Preparing the PR and the requested Claude review; no merge is authorised.

**What I learned**

The needed invariant owns each edited list container, not the opaque taps'
captures. A shared descendant still requires its own proof before a nested write.
Separation checks must inspect every other result position, including retained
closures and positions preceding the written root. A deep condition that has
already failed must not hide a container condition still weakening in recursion.
