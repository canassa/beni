## 2026-10-25 01:39 CEST — browser-inline correctness sweep

**What I did**

- Checked five open browser-inline defects again on `origin/master` 7aa6b06c9.
  - **#559 reproduces.** A command body that dispatches a `pointerdown` makes `Html.pointer` throw `TypeError`. I fixed it in PR #960. The runtime's `send`, `on` and `onArm` now take the event's extractor as one more argument, and `send` calls it first, inside the guard, even when the send waits. The red-first fixtures are `browser/inline/PointerInSend` and `InputInSend`. PointerInSend covers the program's markup, an `if` arm, and another module's markup, and passes in happy-dom and Chrome. InputInSend covers `onInput`'s half of the defect.
  - **#644 reproduces.** A tagger's `Debug.log` never runs. The cause is outside the platform: the write-set pass keeps only the tagger's constructor, and the lowering interface has no way to emit the tagger. The issue asks for #640's source consumer, which has not landed. I stopped and left the red fixture uncommitted.
  - **#466 is fixed by #610.** `HelperEventBinding` is the issue's reproducer with the correct transcript.
  - **#751 cannot be seen yet.** browser-inline refuses (class 4) any `update` arm whose result is inside `Log.annotate`. The fix starts in `src/writes/`. I stopped and reported.
  - **#642** is a proposal only: keep the caret's distance from the end of the value on a differing write to the focused text control.
- Filed #959. `Listen.on`'s busy path has the same gap as #559: a throw inside a nested dispatch does not stop the page.

**What I learned**

- The DOM never hands a listener's throw back to the code that dispatched the event. It reports the throw to the window. So in a dispatch nested in a running send, the dispatch guard does not see the throw. The code there has to call `defect` itself, with `Js.finally` and a flag.
- Pay-for-what-you-use lost here. A separate `sendVia`, shipped only to pages with an extractor, had to be a guard of its own to avoid making a closure per event. That cost those pages +64 brotli on average. One more argument on `send`, `on` and `onArm` costs +17 on those pages and +21 on pages without an extractor.
- `onInput` and `onChange` also have `via` extractors (`targetValue`), so the controlled-input pages changed too, not only the pointer pages.
- `git stash` is shared by every worktree. Never use it to prove a fixture red. Use `git checkout origin/master -- <paths>`, and commit first, because `git checkout HEAD -- <paths>` throws away uncommitted work. I lost one rewrite that way and had to rebuild it.
