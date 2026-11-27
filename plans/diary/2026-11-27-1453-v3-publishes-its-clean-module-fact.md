## 2026-11-27 14:53 CET — v3 publishes its clean-module fact to the lowering

**What I did**

- Since `browser-inline` is judged by v3, its inline goldens were 2.2% larger after brotli: v1's
  clean table (`Hoists.Table.clean`) lets the lowering trust that an update keeps its base's object
  (a nested store skipped, `answersParam`, the write-set pass's `Input.in_place`), and v3 gave no
  such fact. v3 now publishes two facts per module from its own lines (`own3/Enforce.zig`):
  `Check.records_in_place` (every `record_update` is an update the channel lists as accepted) and
  `Check.record_calls` (the calls at which v3 accepted a write of a record argument). The emitter
  reads them only in a build of a chain that names v3 with no oracle (`Emitter.recordsInPlaceV3`).
  Kernel §11 has a closing paragraph on them. Closes #2724.
- The 50 goldens are v1's bytes again, all but `ShowKeyed`, whose hole reads v3 binds in another
  order: 58 712 → 57 429 bytes after brotli (v1: 57 425).
- Refusal and false-word texts name no prototype and no flag when the platform chose v3
  (`session.ownership_v3_platform`); 63 diagnostics re-blessed. Closes #2725.

**What I learned**

- The first try lost a write: with the model's identity trusted, the arm's `e=b` goes away, and the
  release optimiser then dropped `K(e,"later")` as an unused pure call, the #2642 shape
  (`emit/release/inline/ReleaseCalleeWrite`). v1 marks such a call as a store through
  `writesAt`; v3 needed the same row, its accepted `callsite` lines that write a record.
- Comparing the new v3 build of every inline emit fixture with a v1 build from the same binary
  (`--ownership=v1`) found the gaps quicker than reading goldens.
