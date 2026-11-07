## 2026-10-29 22:32 CET — the cloudflare siblings move to beni

**What I did.** Step 11 of `plans/runtime-in-beni.md`, PR 10 of #877: the four exports of
`Worker.js`, `Worker/Object.js` and `Worker/Storage.js` have beni bodies. Three are a `catch` each,
written as `Js.catchIf` naming the one failure the host documents — `new URL`'s `TypeError`,
`idFromString`'s `TypeError`, `kv.put`'s `Error` with `SQLITE_FULL` in its message — and throwing
the rest again; the fourth, `repliesIn`, is the walk over a message's arrays and plain objects with
a `Set` of what was seen, `Object.getPrototypeOf` and `Object.values` through `Js.call`. The
three siblings are deleted; `runtime.js` is the platform's one file of JavaScript. Spec first:
the plan's row 11 and *Step 11*, `core-in-beni.md` step 4, `boundary.md`'s Workers paragraph and
its two lines that named the siblings. `ObjectCounter` gains the `byId` round trip and a text that
is no id, since no fixture reached `idFromString` before.

**What I learned.** A platform's `catch`es move one by one into `Js.catchIf` with no change of
meaning: the test lambda is the class or the message text the sibling tested, and the throw of
everything else is the intrinsic's own contract. A walk the sibling wrote with `v[k]` has no
dynamic key in `Js`; `Object.values` through `Js.call` is the same walk with no key at all.
