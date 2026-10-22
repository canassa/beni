## 2026-10-22 18:17 CEST — Store Tea keys in private ordered arrays

**What I did**

Merged #767 after green dagon gates, CI and review. It closes #750 and #766,
implements the first entry-word piece of #319, and unblocks #294. Reused the
same dagon worktree on a fresh master branch and restored the direct-traversal
private-table draft from the retained-values evidence directory.

Tea's jobs, live subscriptions and wanted subscriptions now use a private sorted
array of key/value pairs. Binary search dispatches through Hosted.compare for a
Key and lexicographic comparison for a key path. Equal entries keep their stored
key. Prefix cancellation locates one range, stops its jobs in path order and
removes it with owned array operations. Commands and wanted declarations thread
their owned accumulators directly while bodies retain inner values; this avoids
the separate fold propagation defect tracked in #749 without exempting a write.

The no-Dict page test was red on master and green with the draft. Tea passes
check under ownership-everywhere with no diagnostics. The unchanged browser/tea
corpus and compare-EQ subscription fixture pass, as do the trusted body pins.
The final run hashes and gates use the shared dagon lock before the PR. There
is no public API change, ownership exemption, copying fallback, weakened check,
budget change or measuring. Dict keeps its current tree representation.

**What I learned**

The private operations were already ownership-clean locally; the missing hosted
entry row was the remaining boundary. Declaring both state transitions made the
same table draft acceptable without changing its storage proof. Scalar Dict keys
can now be constrained separately from the richer command and subscription keys,
whose type identity and own comparator remain W47's contract.

The first full gate found only the two HTTP release-emission goldens changed by
the new private table implementation. All other checks passed. Refreshed only
HttpSendTracked and HttpSendUntracked under the shared lock and verified their
targeted emit run. Their browser runtime inputs and expected results are unchanged.
