## 2026-09-18 05:30 CEST — S7 landed: return-type dispatch pinned

**What I did**

- **S7** (`0ef34da`) as a pin-and-close slice, on the read-only planner's finding
  that S2–S4 had already built return-type dispatch end to end. Six new
  fixtures, every one passing at base and recorded as such: the dump shape of
  a receiver-less site, the second trigger of §10.8, the `.any` undetermined
  arm, `run/DecodeInto` (forwarded evidence, a later-use `let`, a
  `number`-spelled variable through the A.53 bridge), its table, and a
  result-only quantifier crossing a module boundary. No `src/` change. §4's
  Roc citation now names the shipped `s_type_var_alias` form; A.77–A.80.
- Briefs for S6, S7 and S8 now live under `plans/`. S8 is split: S8a takes
  the rows never measured or measured on a superseded binary — M1a
  interleaved, M1b on one corpus with two compilers, M2 on the final tree,
  M5 R4–R6 with C1 programs, profiles, M7 — and S8b writes report 19.

**What I learned**

- **A brief that says "expected to pass at base" is the honest shape for a
  pin slice.** Three of the six S7 fixtures were predicted to pass and all
  six did; saying so up front kept the implementer from dressing pins up as
  fail-first proofs, which happened twice in S6.
- **The forwarded-evidence site is flat.** A forwarded `$m$k` is one slot,
  never a tree; pre-order nesting (A.68) only arises when the target itself
  takes evidence. The brief expected otherwise; the golden was right.
- Owed to a later pass: §10.8's message renders argument types as unresolved
  flexes because the rigid arm reports before the same `and_`'s argument
  constraints are solved. Cosmetic, pre-existing, out of S7's scope.
