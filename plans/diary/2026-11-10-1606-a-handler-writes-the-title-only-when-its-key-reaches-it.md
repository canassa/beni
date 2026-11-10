## 2026-11-10 16:06 CET — A handler writes the title only when its key reaches it

**What I did**

- Issue #1168, debt of #1163. On `browser-inline`, every handler of a
  `Tea.document` called the title's function after its write pass.
- The write-set pass now gives `Program.title_reads`: the anchored reads of
  the `title` field of the view's result. It is ρ when the view's walk is not
  complete, and for a result that is not the record the view wrote.
- The emitter gives one bit per key, `retitles`: a write of the key conflicts
  with a title read. The markup interface has `programRetitles(key)`, version
  1.26. The `inline` lowering emits the call only for a key with that bit.
- `browser-inline.md` §10.2 and `boundary.md` §9.4.6 have dated amendments.
- Fixtures: `emit/release/inline/DocumentTitleReads` (the `Inc` handler ends
  with the title call, the `Tap` handler has none) and the page
  `browser/inline/DocumentTitleReads`.

**What I learned**

- `browser-inline` refuses a `view` that has a local binding (§5, class 1),
  for a document also. The issue text says the title is evaluated "with the
  view's `let`s", but no program that builds has one. My first fixture had a
  binding and the build refused it.
- A red proof must compile. My first toggle left a parameter unused, and the
  run failed on the compile error. I read only the exit code and took it for
  the golden mismatch. Read the failing case's name in the log before you
  call a run red.
- The page fixture is green before and after: the old code was correct, only
  not minimal. Only the emit golden can be red before the change.
