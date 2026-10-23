## 2026-10-23 08:16 CEST — A throw in update keeps each release's context

**What I did**

- Fixed the review's R-F1 on #830. A body in a fiber holds a `bracket` and
  sends a message whose `update` throws inside `Log.annotate`. At the
  teardown, the body's release ran with no log context; on `master` it had
  the body's.
- The fix is in `Task.withoutLogContext`. When `update` throws and leaves
  finalisers, the slots stay as they are at the throw, and a restore of the
  caller's slots goes into the fiber's list under `update`'s finalisers. The
  fixture `browser/tea/LogUpdateDefect` shows each release with its own
  context, and it fails on the PR's earlier head.
- Added five senders to `LogCommandContext` (R-F2): an after-render body, a
  `Cmd.map` child's body, a keyed body after a wait, a focus that a body
  makes through `Html.map`, and the other program of `Browser.programs`.
  Each is red on `master`'s code.

**What I learned**

- A `Js.finally` that puts a slot back at once is right when the work
  returns, and wrong when the work throws and leaves finalisers. The
  teardown runs those finalisers later, last first, and each one sets the
  slots to the `old` that it saw. So the caller's restore must run after
  them, not before.
- The fix edits the finaliser list that is there. A call of `addFinalizer`
  would write `finalising`, and that write, even unreached, keeps the
  teardown in a release page with no fiber.
- The fix does not cover #811. There the body has no fiber, and the
  teardown runs the `outside` record's finalisers in a fiber with no slots.
