## 2026-10-22 13:55 CEST — Retain recursive returned functions

**What I did**

Resumed #210 after the owner confirmed that the moved `RecursiveHolds`
refusals are correct: `Node xs` and `One xs` retain the list before the
callee pushes onto it. Restored function slots and read-only function
classes in recursive summaries. The join preserves each callback protocol,
capture, requirement and unknown function alternative, and compares class
contents when checking the fixpoint. Slot keys persist across rounds.

Promoted the red returned-validator browser fixture into the corpus. Its
emitted program renders two errors. Added a cross-module ownership cache
round trip, controls for direct and top-level-bound unknown functions,
a shared validator, and a three-member recursive cycle whose class contents
need multiple rounds to propagate a shared result. Advanced ownership blocks
to version 22 and added a dated specification amendment.

**What I learned**

An uncarriable function is unknown, not the empty approximation of a recursive
member. That alternative must survive nonrecursive forwarding and top-level
values too. The new negative control caught its loss in the first draft.
Function identity itself is not a mutable cell; captured lists keep their
separate provenance entries and remain subject to the ordinary checks.

The existing ownership reports have no accepted demand changed to rejected.
The only additional refusals are the two owner-approved retaining callbacks
in `RecursiveHolds`; no safe accepted whole program becomes rejected.
The positive scan also found existing sharing in the dispatch doubling
fixture and the writes page fixture, now reported on #210 for separate fixes.
All work and self-hosted builds run on dagon, without LLVM or measurements.
