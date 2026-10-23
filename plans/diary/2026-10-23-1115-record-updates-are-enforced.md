## 2026-10-23 11:15 CEST — record updates are enforced where list writes are (R4 of #315)

**What I did.** Removed the record skip in `Enforce`, added §31.9's three codes
(`record_still_used`, `top_level_record_changed`, `record_may_be_shared`; `view_changes_model`
shared) and a record message, `Message.buildRecord`, whose fix is `{ Record.copy r | … }`. The
corpus harness counts record lines as refusals. Core is clean: `Log`'s four context updates copy
the outer context, and `Schedule.shifted` makes a new `Metadata`. Fixed the programs whose
refusals were real sharing (the todo page and server, the `Ref` callbacks, the micro pages' top-level
`init`, the keyed table's index swap, now `List.swap`), and adjusted four `build/bad/inline`
fixtures so that the refusal each tests stays theirs. Four `build/bad/everywhere/Record*` fixtures
pin the codes. The remaining inventory is decided in §31.9's *As built*, with five new issues
(#867–#871) for the limits it found.

**What I learned.** The core pack checks core and the in-place platforms with enforcement, so the
first build after removing the skip refused core itself: the pack is the earliest gate a record rule
meets. `Log`'s `here` is not owned: it is the outer fiber's context or the top-level `initial`, so the
copies are real fixes, not a way to get green. A precise `List.filter` turned the todo page's
approximate refusals into exact ones that name the real bug: `save { t | done = … }` would have
changed the model's todo before the server answered.
