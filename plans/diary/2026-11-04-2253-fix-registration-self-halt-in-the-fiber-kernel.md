## 2026-11-04 22:53 CET — Fix registration self-halt in the fiber kernel

**What I did**

Built the one-Control-Cell Task kernel and intrusive unit wait lists in #1909, integrated the browser runtime changes, re-read the moved ownership pin bodies and ran the targeted overlap checks. The controlled harness against b612dbf382 reduced parked storage from 1170 to 448 bytes per fiber and spawn/join from 658 to 245 ns. Remaining page growth and the protocol work are tracked in #1907.

The review reproduced synchronous cancellation during host registration: host activity had been used as a wait-kind discriminator, so a returned canceller could be decoded as an intrusive list. Added an independent list-kind bit and immediate cancellation after registration, with a run fixture proving the canceller clears the gate once and the body stays cancelled. Removed the dead listing flag and clarified that frames and cancellers are called at their typed endpoints, while resume/result data are not. Corrected three ownership-summary goldens: these are changes from this kernel, not inherited failures; every demand/verdict line remains identical.

**What I learned**

An activity flag is not a representation tag. Synchronous user code can cancel registration before the host canceller exists, so the return from registration needs its own cancellation check. Delivered intrusive values still need a rollback protocol before Queue/Semaphore adopt them; today's unit waits have no resource to lose. Custom-scheduler teardown currently scans the whole tree. Both later-slice debts are recorded on #1719. The correctness fix's temporary S3 cap debt is explicitly owned by #1907; protocol lowering must restore the original 3967-byte bound.
