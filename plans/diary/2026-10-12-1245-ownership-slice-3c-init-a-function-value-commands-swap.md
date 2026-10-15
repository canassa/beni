## 2026-10-12 12:45 CEST — Ownership slice 3c: init a function, value commands, swap

**What I did.** Specified (`boundary.md` §9.8.16, `ownership-checker.md` §21–§22, `frontend.md` §11.10)
and built the owner's two decisions on slice 3b. `init` is a function of `⊤` the platform calls once per
mount on every program constructor (`Browser.program`, browser-tea's and browser-direct's `Tea.*`, the
test page platform); browser-direct lowers `λ⊤ → e` as `e` in the mount so `emit/direct/` did not move,
and the write-set pass and the entry protocol read `init`'s result the same way. `beni fmt
--migrate-init` migrated 277 files; the rest by hand (Zig tests' programs, bench generators, two fixtures
the edit cannot reach, TodoMVC's `init ⊤ = …`). `Storage.save`, `Http.send` and `Log.write` take the
value they store, send or log; every closure-taking constructor stays, with an inventory saying why.
`List.swap`'s row is asserted (`excl if π₁ excl`), the other writers checked against the thesis.
Research 79 measures it.

**What I learned.** Making `init` a function erased the one specified behavioural difference between
browser-tea and browser-direct (`InitThrows`' `.tea-expected`): the template platforms now call it at
mount too. Value commands remove a command's capture but not an encoder's: TodoMVC's saving variants stay
`escaped` through `String.join`'s `Js.pure` lambda, so Change 5 decides them, not O5. Conduit's whole-model
capture was a navigation key computed inside a `Cmd.do`; hoisting it leaves exactly the five owned-send
rejections slice 3d is for. The release optimiser cannot see through a record field's lambda, so `init`
as a function costs up to 23 brotli bytes on an `element` page — a purity fact for such fields would buy
it back. Splitting one working tree into reviewable green commits is easiest by saving the later commits'
files aside, committing, running the gates on that state, then restoring.
