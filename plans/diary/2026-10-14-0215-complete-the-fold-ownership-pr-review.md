## 2026-10-14 02:15 CEST — complete the fold ownership PR review

**What I did**

Pushed the structural allocation recorder and entry-namespace tests to PR #88,
then answered every first-review finding. Claude's follow-up read the changes,
the namespace tests and the three new accepted pages, found no soundness bug,
and confirmed the structural selection and namespace coverage. Answered every
follow-up point, including the exact unit-test gap and the List.foldl seed.

Kept the new pages focused on ownership: CallbackOrderFoldr already pins both
List and Dict direction with exact callback transcripts, and passed in the full
gates. Final native zorg gates remain 1 295 pass, 15 skip and the four unchanged
Mac failures. No further code change, LLVM run or merge. Lean modelling and
cap-exhaustion coverage stay explicit follow-up in queue row 85.

**What I learned**

The review confirms that seeding recorded callback allocations, excluding
supplied cells, makes id collisions conservative. Existing order-sensitive
black-box coverage is preferable to duplicating it in an ownership regression.
The two namespace tests prove the supplied-cell boundary, not every possible
callback condition; the broader oracle proof remains an acknowledged risk.
