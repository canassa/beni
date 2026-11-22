## 2026-11-10 15:06 CET — a checkbox fixture for an arm that branches on a Bool (#1216)

**What I did.** Worker `inline-bool-payload`, issue #1216. The issue said that `browser-inline`
refuses `onCheck={SetAgree}` when the `SetAgree on` arm has `if on then … else …`. I built the
program on master 4435a7704a first: it builds, in development and with `--release`, also with the
`if` in a helper and in `browser/prerender/EarlyInput`. I then built the parent of cd53732fcc
(#1176, the dispatcher for handler values that name no key): it refuses the program with the text
of the issue. So #1176 fixed #1216 and no fixture showed it. I added
`tests/corpus/browser/inline/CheckBoolArm`: two checkboxes, one arm with the `if` in place and one
with the `if` in a helper, each box checked and cleared. The blessed transcript agrees with the
intent comment. A temporary copy under `browser/tea/` gave the same transcript, with one known
difference: an empty text hole is `""` on `browser-tea` and nothing on `browser-inline`.

**What I learned.** A `Bool` payload gives the write-set pass one key for each value, so the
constructor `SetAgree` names no single key and its event goes through the path of #1176; in a
sandbox page release folds it to `a=>{if(a){k();return}r()}` with no message made. Reproduce on
master before any design work: this issue was six days stale. The temporary `browser/tea/` copy
failed its value-fuzz case with "mounted 0 programs", and a copy of `inline/CounterLocal` fails
the same way, so it is the harness and not this page: #2432.
