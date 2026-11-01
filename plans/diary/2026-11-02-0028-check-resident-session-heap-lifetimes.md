## 2026-11-02 00:28 CET — Check resident Session heap lifetimes

**What I did**

Moved the API driver to the compiler's safe library, target and backend. Its
Session uses a DebugAllocator and exits nonzero on a leak after deinitializing
all Session state. Removed the unused profile, dropped the ineffective
multi-worker claim and clarified that diagnostic messages are worker-borrowed.
Kept the revisions' public type Int stable, with unit as the erroneous body.

**What I learned**

A tiny input fits one worker even when eight are requested. Informational
diagnostics are required for the warning revision; removing the option emits
empty arrays, so it remains with a comment. Int also needs the ordinary core
package enabled explicitly in this API client. The native-entry half remains
outside this PR. An accidental foreign global-stash application was undone;
subsequent proof runs use this worktree's explicit patch instead.
