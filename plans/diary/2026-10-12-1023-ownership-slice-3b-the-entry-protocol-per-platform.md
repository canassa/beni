## 2026-10-12 10:23 CEST — Ownership slice 3b: the entry protocol, per platform

**What I did.** Specified (`ownership-checker.md` §19–§20) and built the entry protocol: a call of a
program constructor with an entry row (browser-direct's `Tea.*` the direct row; browser-tea's `Tea.*` and
`Browser.program` the template row) computes the model at entry as a fixpoint of `init` and `update`,
escapes what commands, subscriptions and the runtime's calls keep, and checks each path `update` writes:
`accepted entry` on browser-direct, `rejected platform` on the template platforms, `read-only` for `view`,
`payload` where a message may reach the write (owned sends are not built). `Cmd.map` now holds key paths
outermost first and prepends into a new list; `Sub.batch` joins into a list that starts empty: slice 3a's 69
key-path rejections are gone at no measured cost. `Dict.update` is a focus primitive whose supply is asserted
taken and owned, with values stored at one folded path kept apart (`sep`) and core/Dict's no-duplicate
obligation on the trusted surface. Ownership fixtures take a `.platform` file. Research 78 measures it.

**What I learned.** The thesis's "one verdict on both back ends" and Change 8 reconcile cleanly as one
computation plus a platform cause. browser-direct already evaluates `init` in the mount and refuses a program
value mounted twice, so Change 4 needs no API change there. `List.copy` is the idiom but costs a second copy
under persistent lists; a construction whose base is a new literal (`[ …[ s ], …path ]`) reads the caller's
list for free. Carrying a view's messages round the entry fixpoint doubled Conduit's model for no verdict:
the payload rule already covers every demand they reach. A ReleaseFast build started before later edits
looked like a Debug/Release miscompile; check the binary's timestamp before suspecting the compiler. The
next walls for real apps are owned sends (Conduit), the `Js.pure` escape rule (TodoMVC's `encode`) and the
coarse view-event rule.
