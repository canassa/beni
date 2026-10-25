## 2026-10-25 02:18 CET — browser-inline command log context

**What I did**

- Fixed #751. The write-set pass gets a core row, `log_scope`, for `Log.annotate`, `span`, `minimum` and `withSink`. The row is their last argument applied to `⊤`. Before this, browser-inline refused any `update` arm written inside one of them (class 4).
- `browser-inline`'s `Cmd.perform` gives its body to `Task.keepLogContext`.
- The fixture is `browser/inline/LogCommandContext`. Its transcript equals browser-tea's for the same program. It is refused on master, and it gives the default context with the write-set change alone.
- Release output did not change by one byte. Six ownership summaries changed. No verdict changed.

**What I learned**

- `Cmd.perform body = Perform (Task.keepLogContext body)` made the program's body count as suspendable (`own` was not `no`). browser-inline then refused every command with class 2. Two other fixes were possible:
  - `sync` on `perform`'s parameter. That works, but it turns the class-2 limit into the language error `sync_boundary`.
  - Reading `keepLogContext` at the type `(Send msg → ⊤) → (Send msg → ⊤)` through `Js.to`/`Js.from`. This keeps the decided diagnostic, so I chose it.
- Why the checker made the body suspendable through `keepLogContext`'s `(a → b !impure) → (a → b !impure)` is not explained. It may hide the same cost in `browser`'s `Hosted.job`.
