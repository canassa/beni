## 2026-11-23 11:00 CET — browser-inline reads two more command shapes

**What I did.** The inline sweep of the 357 `browser/tea` + `browser/dom` pages had 28 stop at
"the write-set pass could not read this command". Their commands were of four shapes. Two are
read now (`write-sets.md` and `browser-inline.md` §4, amended 2026-11-23): `Debug.todo` is ⊥ in
the pass, not `Fresh`, and `Task.bracket` and `Task.onExit` answer the value of their use or
their work. The third shape, a `Cmd.batch` over a `List.map`, was built and then withdrawn. The
review found that it makes a common idiom compile into an older lowering defect: a field written
in place is read again after the store, inside a nested closure (#2617). Keyed commands, the fourth
shape, need a key table in the runtime. They stay refused, the message now names them, and they
have an issue (#2615). The review also found two older ways a build misruns, and both are now
refusals: a lost list was read as an empty batch, and an alternative that suspends hid one the pass
could not read. I copied 14 tea pages to `browser/inline`: 4 have the same transcript, and 10 name
their difference in a header. I added one new page and four `build/bad` refusals. With one sweep
script the count went from 104 to 118. The diary of #2614 says 108, from a different method.

**What I learned.** Most of the 28 pages test defects, so a `Boom → Debug.todo` arm made the
command of the whole key unknown. The copied pages show three gaps in inline's defect teardown
(#2616). A test of mine first failed without an error because a `<p>` and a `<button>` had the same
id. The reviewer's best probe used a read of the written field in the command, not a hole.
