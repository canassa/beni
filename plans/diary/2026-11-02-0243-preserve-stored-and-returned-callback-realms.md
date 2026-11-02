## 2026-11-02 02:43 CET — Preserve stored and returned callback realms

**What I did**

Rebased workers-realm onto the Wire delivery, retaining both interface metadata fields and assigning distinct Wire and HostFree bits. Reproduced eight worker escapes before the fix, then attributed concrete callable writes through Ref, Js.Ref, Deferred and Queue to the writer's realm. Returned foreign callback receivers now own their callbacks' realm dependencies. Added nine diagnostic fixtures (including existing local-cell rejection) and portable browser twins. Updated the native host skill and documented generic erasure and foreign input obligations as the known gap #1663, also reported on #1636.

**What I learned**

The realm-only graph can account for writes without changing purity or suspension inference. A foreign factory's callback receiver must carry dependencies independently of the factory call. Generic flex/rigid variables still need deferred obligations across copying and interface publication; treating them as ordinary effect classes would broaden this repair and risk #1662. Targeted realm tests and the Chrome realm corpus pass. Chrome's singleton socket needs a short symlink to the worktree scratch directory on this long worktree path.
