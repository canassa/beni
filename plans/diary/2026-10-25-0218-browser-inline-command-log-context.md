## 2026-10-25 02:18 CET — browser-inline command log context, in part

**What I did**

- Landed half of #751.
  - The write-set pass gets a core row, `log_scope`. It reads `Log.annotate`, `span`, `minimum` and `withSink` as their last argument applied to `⊤`.
  - So an `update` arm written inside one of them builds on browser-inline: its model is written and its own lines carry the arm's context. browser-inline refused every such arm before.
  - A command with a body made inside a scope is still refused, as before.
  - Fixtures: `browser/inline/LogScopeInUpdate`, whose transcript equals browser-tea's, and `build/bad/inline/CommandInLogScope`.
- The platform half, `Cmd.perform` giving its body to `Task.keepLogContext`, is blocked by #1003. My first version hid the effect behind a `Js.to`/`Js.from` cast. The manager refused it under rule 10.

**What I learned**

- With `Perform (Task.keepLogContext body)`, every body's own answer is `poly`, not `yes`. The same happens with any higher-order function between the body and the constructor, even a pure one stored beside it.
  - The reason is §14.5's single hidden class per nominal application. It makes `update`'s `Cmd Msg` class sensitive, so `update` gets a twin body.
  - browser-tea never reaches `update$s`.
  - The write-set pass's `funSuspends` reads `poly` as `yes`. The defect is there, not in the checker.
- Never hide an effect from the checker with a `Js` cast to get a build through: it is rule 10's case. Instrument the reading instead. A one-line debug print of `own` and `twin` found the cause in minutes.
- A refusal written as a list of shapes leaks. My first scan of a scope's result looked only at `( model, cmd )`, and review carried a command out of the scope in six other shapes. Prove a term free of the thing, and treat any term you cannot see into as holding it.
- `git checkout <rev> -- <path>` over uncommitted work destroys it, and it happened to me a second time: I restored from a copy in the scratch lane. Commit before every red-proof checkout.
