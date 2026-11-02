## Rebase release worker hoisting over generic Wire

**What I did**

Rebased the hoisting PR onto the workers branch after generic Wire normalization
and its shared open-row field palette. Refreshed emitted-program run hashes and
validated the managed browser corpus in Chromium in development and release,
including GenericWire and OpenRowNames, plus the worker release emit goldens.

**What I learned**

The compiler changes compose without a rebase conflict. The open-record wire
labels from the new base remain part of lowering alongside final-artifact
worker URLs; the integration checks exercise both normalization and hoisting.

**Validation note**

The first full hash refresh had one failure: the 480,000-waiter semaphore
fixture's development process exited 255 without output during the concurrent
run. Both builds passed in isolation. The full refresh was then run with `-j1`
to finish the index with less concurrent load, keeping every expectation and
hang guard unchanged.
The serial refresh recorded 3,199 verified program hashes with no failed runs.
