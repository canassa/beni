## 2026-11-04 02:23 CET — Typed DOM row shrink blocker

**What I did**

Read the workers-delivery lane rules and frozen Html.Runtime protocol, verified
its hash on 9e33118a17, created the hostfree-dom-rows worktree and issue #1825,
and compared the existing row algorithms with the typed native catalogue.

**What I learned**

Positional shrinking pops the existing row array (Rt.beni:780), but the typed
Array catalogue cannot remove elements or reduce length. Preserving the required
allocation shape needs a manager-approved native operation. Reported the reduced
[a,b] to [a] case; saved evidence under worktree-evidence/wd-dom-rows. No
implementation workaround or compiler build was started.
