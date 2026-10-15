## 2026-10-12 01:56 CEST — release: one declaration per name around a loop

**What I did.** Fixed CK-222, the `--release` module that declared one name twice and did not
load. `Rename` named a `let` just before a loop as the loop's own, homed in the loop's scope, on
the assumption that the printer would write it in the loop's `for` head; the printer chose an
earlier member of the run (the variable's update was not the loop's last statement), so both
sibling loops' variables stayed in the scope around them under one spelling. The printer's
choice is now one predicate, `Print.headOf`, which `Rename` asks through `Rename.Heads`; a
safety build checks they agree (`mispulled`). Promoted the pending fixture to
`run/ReleaseRedeclared` and added `run/ReleaseRedeclaredSiblings`, both red before the fix;
`backend.md` §9 item 2 amended.

**What I learned.** Completing the renamer's own model instead (siblings' pulled variables kept
apart) also fixed it but cost +19 and +9 brotli on two `browser-direct` goldens whose loops were
fine: asking the printer is both exact and cheaper. Raw bytes are unchanged everywhere; 17
`Schema*` programs and the keyed reconciler rename one variable each. The old run walk also
`continue`d past a declaration run that ends its list without printing it; the refactor prints
it, and no corpus program reaches it (raw bytes unchanged).
