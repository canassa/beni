## 2026-11-05 12:24 CET — A traversal's callback element is taken

**What I did.** S4's first step (#1975): `List.map xs λl → List.push l 1` is accepted in place. A `taken` read is out
of its container in the relation (`Taken.zig`), so `mapHelp`'s pending `a` holds the others, and a builder holding the
frame's own answer no longer turns the label's condition to `no` at the self pass (`Fed.covering`). §2.11.3 has *a
taken supply*, Appendix C.6 has each row as built. Fixtures `run/SanitiserTakenElement` and `…Apart`.

**What I learned.** The brief expected the kept supply to explain most of the known list. It explains 11 positions.
The rest are other rules: 45 fold rows are the accumulator's supply, and result separation (#1978) and per-slot
conditions (#1979) are separate gaps, so C.6 row 2 and `EditAnsweredList` do not pass yet. Dropping the container's
condition in the split alone changes nothing, because `π1[*]*` also arrives from the builder holder; the mutation that
shows the rule matters drops the supply's condition at the caller, and then the reds trap. `fed` was unnecessary: the
function's `ε*~` covers what an answer can hold beyond its element, and keeps a capture answer apart from the list
accepted. CLAUDE.md names `zig build test-run-hashes`; no such step exists on this tree.
