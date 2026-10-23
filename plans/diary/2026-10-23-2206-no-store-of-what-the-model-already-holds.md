## 2026-10-23 22:06 CEST — no store of what the model already holds (#896, cause 3)

**What I did.** After the routes fix, three no-op shapes were left in S1's output. I removed each
one where the store changes nothing:
- **The handler's `model = next`.** The root plan now also reports `model_kept` (no key's
  `Key.replaced` has a prefix of ρ), through interface 1.18 `programModelKept`. The handler then
  runs the arm as a statement and stores nothing: `K(a,f)`, not `let b=f,c=K(a,b);f=c`.
- **The Tick arm's store-back.** `{ model | w7 = W7.tick model.w7 }` stored `b.a=ia(b.a)`.
  `Lower.answersFieldObject` extends #888's `sameFieldObject` to a call whose function answers its
  parameter's object: every tail is the parameter, an in-place update of it (`clean_modules`), or
  such a call. The call now runs as a statement and nothing is stored.
- **The dead `,c`.** I added a printer rule (`backend.md` §9 *Compact statements* item 10). In
  release, a name or literal operand nothing reads is dropped, nested sequences are flattened,
  and a discarded object literal prints as its values.

New page and golden: `TickInPlace`, red against #899's binary. 35 `emit/release` goldens moved,
and every page transcript stayed the same. `./rr check` passed 24/24. #901 is the remaining
debt: a program-owned `case` arm's unread temporary.

**What I learned.** When the handler stops reading the arm's result, release's dead-binding pass
drops the whole call, writes and all. Beni functions are pure to the checker, but in-place writes
behind a held slice are effects. The first try silently deleted the push handler's body, and I saw it in S1's output (`$=a=>{x(…)}`) before any page ran. So the arm must stay as a statement, and a
skipped store's temporary is turned into its call. A Print unit test used a bare `g;` as a filler
statement. It now uses `g()`, because a bare name as a statement is the very thing release now
leaves out.
