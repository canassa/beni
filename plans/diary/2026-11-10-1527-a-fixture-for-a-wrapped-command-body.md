## 2026-11-10 15:27 CET — a fixture for a wrapped command body (#1003)

**What I did.** Worker `cmd-perform-poly`. #1003 said that the write-set pass read a `poly` command
body as one that may suspend. I tried its reduction on master `4435a7704a`: the three changes to
`platforms/browser-inline/Cmd.beni` (`Perform (Task.keepLogContext body)`, `Perform (same body)`,
`Perform body enter`) all build now, and a helper whose callback suspends stays refused, class 2.
The fix was `8f1b60a62e` (2026-11-02), which added `commandBodySuspends`: a `poly` body is applied
to its real sender. The evidence is on the issue. The coordinator then asked for a fixture. I added
`browser/inline/CommandBodyWrapped` (a body through `through f = λx → f x`, and a helper that calls
a captured callback, both made in `update`, both run) and `build/bad/inline/WrappedSuspendingCommand`
(the same `through` with a body that waits). Red proof: with `.poly => return true` in
`commandBodySuspends`, the page is refused with class 2. Gates green.

**What I learned.**
- The pass does not read the body of the platform's `Cmd.perform`: it takes the argument of the
  call as the command's body. So a change inside `Cmd.beni` does not show to it, and a fixture for
  this must be a user program.
- A user program that writes `Cmd.perform (Task.keepLogContext λsend → …)` is refused with class 4:
  the wrapped body is not a function term to the pass. That, and the log context of a command body
  on `browser-inline`, is #2435. `boundary.md` §9.8.16 (b) still names #1003 as the reason; #2435
  owns the amendment.
- `-Dcorpus=<text>` with `BENI_WRITE_EXPECTED=1` prints `blessed` for each matched golden, also
  when the file did not change.
