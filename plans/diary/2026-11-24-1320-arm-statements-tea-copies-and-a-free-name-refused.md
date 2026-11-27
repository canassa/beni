## 2026-11-24 13:20 CET — Arm statements, tea copies and a free name refused

**What I did.** Three slices of #966. (1) #2672: `Rename.verifyBound` did not catch a free name
the lowering emits, because it asks only about names a declaration declares somewhere; with
#2673's fix reverted, `browser/inline/NamedRows` threw `ReferenceError` in development and
built in release with `w$18` spelled as a runtime binding. `Rename.enter` now refuses a local no
place declares, in every build (#2678, `backend.md` §9 item 2). (2) The 58 `browser/tea` pages
that built on `browser-inline` with no copy were copied with their transcripts (#2680): 34
identical, 10 marker or text-node splits, 6 documented platform differences, 6 defects pinned
with issues (#2675, #2676, #2677, #2679, #2616); `ListenerOrder` left out (its `flush` step).
(3) #2625's arm statements: an arm with `let`s no hole reads runs them in the choice of the arm
(interface 1.40, `programBranchChooseAll`, `programBranchStatementGroups`), and the region, `For`
or `Show` holding it is in their read sets. Owner question #2681 (an effectful choice of arm);
defect #2682 (`SendStatements`, an internal error). Sweep: 200 of 364 before and after.

**What I learned.** A safety check that asks only about what it has seen declared cannot see a
name nobody declares; the cheap form of the check belongs in every build. Perl `s|…|…|` with
`\|` in the pattern is an alternation: it matched at the top of two files and wrote code into
their doc comments, which `zig fmt` caught. The write-set pass extends the call path by a hole's
token but not by a `For`'s, so a lookup of a row's facts must not add it. An arm of `<></>` has no
unit, so whether a branch has statements is the branch's to say, not the units' — the review
found its `Debug.todo` dropped. Left for #2625: a region in an eager arm, a helper's or another
module's markup as a region, a region on a prerendered page; #2637's other-module markup in a row
was not started.
