## 2026-10-21 20:33 CEST — guard handler lifetimes in release

**What I did**

Answered #630's review request with a tiny release golden: two `preventDefault`
listeners send the same key, and each callback remains in a mount-scope binding.
The DOM listeners pass those bindings to `send`; they do not allocate handlers
at dispatch. The fixture uses its own minimal platform vocabulary.

Proved the regression oracle red in a separate worktree by removing only the
mount-scope hoisting. That build emits both handler arrows inside the DOM
listeners and fails with `GoldenMismatch`. The current implementation passes.
No optimizer pin, runtime change or new handler algorithm was added.

Also clarified the initialized-pass invariant and the per-listener arm comment.
Production executable code is unchanged. The earlier frozen compiler, isolated
fits and combined behavior packet remain identified by their original heads;
this follow-up does not rewrite or reprice them. The owner-approved general
#618 declaration-totality work continues separately.

**What I learned**

A runtime transcript cannot observe this allocation placement. The small release
shape is the direct regression oracle: a future optimization that moves the
callbacks into dispatch will fail this fixture.
