## 2026-09-22 14:22 CEST — Schema contract review decisions

**What I did**

Revised schema.md around the owner's Q1/Q2/Q4/Q5/Q8/Q10 decisions: optional
conversion target checks, the v1 primitive set, ordinary Result failures,
Effect defaults with bounded native recursion, the smaller namespace and
explicit nominal recursion with separate presence/nullability. Made the raw
host representation and direct JsIr validation explicit, removing the implied
Value-ADT marshalling pass. Removed repeated conditional wording, retained the
five outstanding owner questions, and appended A.2/A.3 without renumbering.
Updated CLAUDE and the queue: delegated scheduling puts S1 next, with the
broader numeric-alias defect fixed before S2. No compiler or runtime changes.

**What I learned**

Optional target checks preserve typed projections but do not supply an external
representation for an arbitrary target; Q6 and row 68 retain that S3 obligation.
A 4,096-depth ceiling is not proven safe by choosing native recursion: existing
queue row 39 records another function overflowing near 3,700 calls. New row 69
requires evidence for both paths, helper frames, browsers and caller stack
before shipping; this does not reopen native recursion. Row 67 is confirmed
for local/imported Int and Float aliases and owes fail-first check/good fixtures.
Relative links, stable section numbers, unchanged G1–G5, open-decision IDs and
stale-wording checks passed, as did git diff --check. No measurement runs or
compiler gates rerun for this documentation-only revision.
