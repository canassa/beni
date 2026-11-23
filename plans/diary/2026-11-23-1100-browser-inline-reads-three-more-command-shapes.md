## 2026-11-23 11:00 CET — browser-inline reads three more command shapes

**What I did.** The inline sweep of the 357 `browser/tea` + `browser/dom` pages had 28 stop at
"the write-set pass could not read this command". Their commands were of four shapes. Three are
read now (`write-sets.md` and `browser-inline.md` §4, amended 2026-11-23): `Debug.todo` is ⊥ in
the pass, not `Fresh`; `Task.bracket` and `Task.onExit` answer their use's or their work's value;
and a `List.map` whose callback makes a command is a list that `Cmd.batch` reads. The fourth shape,
keyed commands, needs a key table in the runtime. It stays refused, the message now names it, and
it has its own issue (#2615). I copied 16 tea pages to `browser/inline`: 6 have the same
transcript, and 10 name their difference in a header. I added two new pages and two `build/bad`
refusals. With one sweep script, the count went from 104 to 120. The diary of #2614 said 108,
from a different method.

**What I learned.** Most of the 28 were defect pages, because a `Boom → Debug.todo` arm made the
whole key's command unknown. The copied pages show three gaps in inline's defect teardown (#2616):
`update`'s bracket release does not run, there is no 1 000 ms deadline, and the crash screen does
not show a cleanup's throw. A page test of mine first failed silently because a `<p>` and a
`<button>` had the same id: `click #x` clicks the first one.
