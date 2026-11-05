# Preserve wrapped Worker constructor results

Fixes-after #1937, found while integrating #1941. The new native host projection recognized success with `instanceof globalThis.Worker`. A legitimate wrapper returns a real Worker outside the wrapper's prototype chain, so managed browser probes stopped before starting their workers. The reduced Chrome fixture printed `type syntax security type syntax` instead of `ok syntax security type type`; it also demonstrates that a renamed TypeError must keep its class-based classification.

Specify the boundary correction first: identify the two documented DOMException names and TypeError, preserve successful native identities, and keep the sibling's existing rethrow of all other exceptions. The compiler now checks those caught failure classes instead of inspecting the successful result's constructor. No wrapper identity assumption, broader catch, callback erasure or ownership/publication rule change is added.

The reduced WrappedWorkerCreate fixture uses an actual native Worker through a constructor wrapper and verifies each documented error in development and release. It passes after the fix, as do native-value tests and all ownership pin checks. Re-read the complete NativeHost shared span before updating its 31 affected pins: all other worded host operations keep their same branches, aliases, writes and callback counts. Their names and hashes are preserved in ~/worktree-evidence/wd-fiber/p6/merge-1941/worker-fix-pins.json.

The final full Workers and Chrome results are recorded in that evidence directory's final-results.txt; prior red integration and fixture runs are retained. No budgets change. This is a separate correction commit after the resolved integration merge, as requested by the manager.
