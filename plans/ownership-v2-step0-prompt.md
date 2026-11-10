# Prompt: the step 0 prototype of report 110

*For an agent. The owner asked for it on 2026-11-10.*

---

Build the step 0 prototype of `docs/design/research/110-ownership-v2-design-review.md` (§6, §7). Decide with
measurements whether it is the next path for beni's ownership checker. Treat the codebase as yours, and fix
the sketch where it is wrong.

**Build:** lists only, behind a hidden flag, beside v1 and v2. Do not change v1 or v2.

- Reuse v2's lower half.
- Add locations with a call map.
- Add `own`/`shared` permissions; `shared` is the default and refuses.
- Add contracts for first-order code, and for known lambdas at `core/`'s loops.
- Add the write rule with today's liveness, and recursive groups.

**Measure:** against v1 and v2, on a ReleaseFast build, using `bench/ownership-v2-review.mjs`.

- Real list writes accepted (of 308).
- Traps and output differences on the sanitiser corpus and on a generator that you write.
- Lines per second on the 32 roots.
- Every loss against v2, by cause.

**Gate:** at least 300 of 308 accepted, no trap, and more than 500 000 lines per second.

**Deliver on this pull request (#2451):** the prototype code, with the gates green, and
`docs/design/research/111-ownership-step0-prototype.md`. The report opens with a verdict of one paragraph:
go, no go, or go with changes. It then gives the measurements with their commands, the losses by cause, and
the next step. Do not merge. `CLAUDE.md`'s rules apply.
