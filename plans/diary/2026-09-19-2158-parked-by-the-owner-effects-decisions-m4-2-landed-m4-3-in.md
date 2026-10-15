## 2026-09-19 21:58 CEST — parked by the owner; effects decisions; M4-2 landed, M4-3 in flight

**What I did**

- **M4-2** landed (`13dfa84`..`ea89358`): the front end on disk, the AST
  deliberately not cached. Warm `check` 62 → 39.5 ms, warm `build` 122 → 100.5 —
  the `< 120 ms` warm-start budget met for the first time. By hand: a body edit
  in a leaf re-lowered 1 file and re-checked 2 modules; every artifact truncated
  → 14 re-lowered, 0 re-checked, output identical to `--no-cache`.
- **M4-3** specified (`4b51386`): thirty kinds of cross-module fact, an
  instrumented run that saw none the list lacks, and two demonstrated programs
  where the interface hash holds while an importer goes from exit 0 to exit 1 —
  hence a second hash, the dependency digest. Its implementer was running in
  `slice/m4-3` when work was parked.
- **Effects decisions with the owner** (sheet `plans/effects-decisions.md`): A1
  defects are fatal and the wall's job to prevent, finalisers infallible,
  `Exit a = Done a | Cancelled`, the seven interruption rules; A5 `impure` used
  from the slice that infers it; A6 `sync` in the first cut; A8 `main` stays,
  keep-alive, exit 0/1/130. A7 (services) was mid-discussion.
- **The owner parked implementation**: no new agents after M4-3 finishes.
  `plans/resume.md` is the single place to resume from.

**What I learned**

- **The owner's instinct simplified my design twice in one conversation.** I
  proposed catching defects at the fiber boundary with a list-of-reasons
  outcome type; "isn't it beni/core's responsibility that this never happens?"
  turned that into: defects are fatal, finalisers infallible, and the outcome
  type lost its `Cause`. The argument I had missed was mine to find — JS fibers
  share a heap, so containing a throw means running on state nobody can vouch
  for. When a design needs a rich failure taxonomy, first ask who is allowed to
  fail.
- **Explain decisions in the user's terms, one case at a time.** The
  five-question shortlist stalled until it became "a foreign throws", "an
  interrupt arrives", "what is the type of `user`?". Jargon I had stopped
  hearing ("from the first slice") cost a round trip.
- **A spec's prediction is a test of the spec.** M4-1 predicted 55–70 ms and
  got 63; M4-2 predicted 28–38 and got 39.5, with the miss localised to one
  phase (`decode`) the spec had not measured. Requiring a number before the
  code exists is cheap and tells you afterwards whether the model was right.
