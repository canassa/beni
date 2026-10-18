## 2026-10-18 19:37 CEST — S1 is judged after #315 and the shared validator

**What I did**

I recorded the owner's decision and set the work moving.

- **The decision.** #315, in-place record writes, moves ahead of #294 and S2's design pass. The 1.1× cap stays. S1's done criterion becomes: the `./rr measure` fit, taken after #315 and the shared validator, is at most 1.1× tea-inline on `--lists none`.
  - Cuts 1–7 merge as they land, each with its fit, and nothing is closed on a projection.
  - Every report gives the fit (sizes 1, 4, 16, 64 and 256, seeds 1–3), not a deletion table. The validation line is reported separately, as a fit: the same apps with validation stubbed, then the difference.
- **What this rests on.**
  - Before it, #372 (PR 3) measured 2 223 + 307.0 B per widget against tea-inline's 2 025 + 146.1. A deletion table put the per-widget gap in validation (about 70 B), binding call sites and headers (about 37 B) and handlers (about 24 B).
  - #372's read-only review found #373: a piece the HTML parser moves shifts the element table. It has been on master since #351.
- **A flag I raised with the owner.** The shared validator, measured on the generator before #370, saved nothing per schema (39.6 against 38.1 B). It added 310–410 B once, and it broke the frozen S0 bar (PushAndTimer 583 → 1 079). It is now being measured inside the real research fit, on top of #372. If the fit shows it costs more than it saves, or still breaks S0's bar, the done criterion needs the owner again.
- **#315.** A planning pass is reading §31 against `src/own/` and the O-slices (#317–#322). It is to report what exists, the dependencies, the rollout risk, a slice plan and the owner's questions.

**What I learned**

- **A deletion table is a guide, not a measure.** Rows move when they are reclassified (handlers 30 → 61 B). Removing code outright overstates what reshaping it saves: the slice-parameter closures came out +1 to +8 B per widget, where deleting the headers had suggested −26.
