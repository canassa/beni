## 2026-11-07 22:42 CET — Refuse beni-side string timers in workers

**What I did.** I closed #2211's item 1a on the beni side. A kept
`Js.global "setTimeout"`/`"setInterval"` in a worker build now passes only
as the callee of `Js.apply`, and a `globalThis`/`self` timer member only
through `Js.call`. In both cases the first list element must be provably a
function: `Js.method`, `Js.from` of a lambda, a declared function or a `let`
function, or the same through a one-parameter `Js.from` wrapper
(`RealmCheck.zig`, `workers.md` §4). There are four refusal fixtures and a
positive fixture that runs in Chrome. Page sizes are identical to master.

**What I learned.** Item 1b, the `constructor` route, hits a design wall.
Its precise rule says every kept member name is a literal other than
`constructor`. That rule refuses `Browser/WorkerWire.beni`'s field reads,
which every browser worker build keeps. The reads are safe (own fields of
beni values) but the rule cannot prove them. `Js.at` also takes a
type-variable index, so a string index type-checks. I stopped there and
gave the sites to the owner in the PR. A typed `Timers.setTimeout` already
exists among the native bindings. If platform code moved to it, the timer
rule would no longer need to read syntax.
