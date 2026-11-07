## 2026-10-31 23:18 CET — own2: one cell for a generic call's fresh result

**What I did.** Fixed #1516, an unsound accept in ownership v2. A local
bound to the result of a generic callee (`l0 = wrap b`, `wrap : a → List a`)
was written in place (`List.push l0 …`, `[ …l0, x ]`) though `l0` was read
again. `Grafter.mapCell` made the image `result ι·k` of a callee's fresh cell
at the reader's place. A forced view node reads its own cells at the view's
place, which since #1350 is the instantiated one (`List (List Int)`), but
`Shape.viewReach` maps the template's reach cell by cell at the template's
place (`List a`). So one fresh object had two cells: the demand was on the
node's own cell, and the holder `l0` was paired through its reach, which named
only the other. Now `mapCell` takes no place and uses the class cell's own.
Fixtures `ownership/GenericResultHeld` and `GenericResultHeldImported`, with
v2 goldens; both fail with the fix reverted. As-built note in
`ownership-v2.md` §2.11, *A view stands at its answer's place*.

**What I learned.** A small oracle (Node: generate families of generic
calls, read the v2 dump, interpret each function with copy semantics and with
in-place writes where accepted) found 990 unsafe accepts out of 4 464
functions on master, 0 after the fix, and 3 930 unsafe with every verdict
forced to accepted. My first run reported 360: the generator shared AST nodes
between functions, so each write's source position was the last function's.
An oracle needs its own check that it can fail, and a check that each write
reads its own verdict. The corpus verdicts (ownership, run, core) did not
change by one line.
