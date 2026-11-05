## 2026-11-02 19:31 CET — own2 integrator folds hof-holes and symbolic below

**What I did**
- Folded `own2-hof-holes` (fast-forward) and `own2-symbolic-below` (cherry-pick) into `own2-slot-domain-tests`
  (#1685). Both branches had added a deep occurrence on bit 62 with the same meaning; the conflicts in `Contract`,
  `Distinct`, `Eval.keptAt` and `Rows.ctor` keep both: a symbol `↓p` and a type variable's or opaque slot both give
  a deep occurrence, and `keptAt` reads set elements and joins the supply slot.
- Formatted `UpdateBaseField`, `SanitiserEscapedCallback` and `SanitiserPassedLabel` (positions moved in their goldens
  and the known list) and moved the near-limit test's allowances with h's growth, as the test asks.
- `DotFieldCall` and `UnknownCallee`: master's v2 acceptance traps under `--ownership=v2 --sanitize-lists`; the
  refusal stays, pinned by `run/SanitiserFieldCall`.
- `O-MapControl`: every label answer was taken to hold anything, so an answer pending beside the label's next call
  kept that call's supply. An answer of a direct call now holds what that call supplied and what the label's function
  slot holds (§2.9.2 step 7), and a passed-on judgement no longer counts the label's own function as an operand.
  `run/SanitiserCallbackAnswerPending`; `SanitiserPassedLabel` still refuses.
- The ledger found one merge-only regression (`List.unzipHelp`'s put calls refused): symbolic below's "a deep
  occurrence reaches every result slot" made a type variable's deep occurrence never apart. Fixed by matching
  arrivals by prefix both ways.

**What I learned**
- Two lanes that each invent a flag bit for "deep" will agree on the bit and differ on what reads it; the ledger,
  not the gates, caught the difference.
- The prober's probes need `--core` for the cast family; a runner that retries with `--core` builds all but three,
  which have no source to fix (two) or no `main` (one, given one).
