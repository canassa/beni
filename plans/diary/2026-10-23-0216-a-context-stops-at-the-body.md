## 2026-10-23 02:16 CEST — A context stops at the body

**What I did**

- Built the owner's answer to `node-log-q4` (#818): a message's `update` has
  the program's log context, whoever sends the message.
- The spec: a dated amendment to `boundary.md` §9.8.16 (b), and notes in
  proposal §17.5 and §17.11.
- The code: `Rt.beni`'s `$$root`, the one way into a program's `update`,
  runs `update` inside `Task.withoutLogContext` when `Task.hasLogContext`
  says that the caller has a context. The call of `update` is written twice,
  so that a release build in which nothing sets a slot keeps only the plain
  one.
- The fixture: `LogCommandContext`'s `Done`, which the bodies of `Task` (no
  fiber) and `TaskWait` (a fiber) send, now writes lines. Without the change,
  they carry the sender's annotation, its debug line is written, and its
  command keeps the sender's context.

**What I learned**

- `slotted` is not the only cell that a dead write can stop the release
  optimiser from folding. My first `withoutLogContext` ran through
  `inLogContext`, so it reached `here ⊤` (`newFiber` writes `fibered`) and
  `pushFinalizer` (`addFinalizer` writes `finalising`). The branch was dead
  in release, but a hosted page with no fiber kept the teardown: 6 `finally`,
  not 5, which `build_test` caught.
- A function whose work cannot wait needs no finaliser record to put a slot
  back: a `Js.finally` does it, and writes no cell.
- #769's `keepLogContext` reaches the same writes, through `inLogContext`.
  I checked a `Tea.element` page whose one command, a `Cmd.log`, makes no
  fiber: its release output has the same size, 5 100 bytes, with and without
  the call. So on that page, the call costs nothing. #811 changes the
  teardown, so its fix is measured on such a page too.
