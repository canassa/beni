## 2026-11-02 15:18 CET — Preserve open-row worker wire names

**What I did**

Included open record rows in the shared field palette, accepted role variables
that remain unfixed, and removed the dead concrete-message diagnostic. Updated
the entry-runtime skill reference. An imported-worker Chrome fixture puts List
views in known open-row fields under page-only field pressure. A second covers
unused error/event roles and an inferred Program. Both fail with their fixes
stashed and pass in development and release. Stream/chunk transport remains #1692.

**What I learned**

Lowering a new Wire node kind is not enough: the shared-name collector must see
it too. Ordinary echo coverage can hide a palette mismatch when both realms
happen to choose the same names. Unfixed phantom roles need no invented value
type; concrete function and native-value rejections remain unchanged.
