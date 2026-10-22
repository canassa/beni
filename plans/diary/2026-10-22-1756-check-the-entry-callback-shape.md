## 2026-10-22 17:56 CEST — Check the entry callback shape

**What I did**

Answered PR #767's review. Its callback-shape note exposed an unsafe acceptance:
a platform declared a one-argument settle callback, whose state writer was lost
by the two-argument hosted protocol. Added that reduction red-first (check
incorrectly returned success), then required the exact update and settle arities
and the hosted update's whole-state result before supplying an entry row.
An unsupported row leaves all writers pending. The reduction is now refused,
and all targeted entry tests pass. Added settle to the namespace comment.
Confirmed the frontend and ownership cache versions were bumped and the other
arguments' effects still run before the opaque program result is returned.
Declined the suggested performance run because the owner prohibited measuring.
The review fix gets a final shared-lock gate before merging.

**What I learned**

A declaration is trusted for runtime retention, but the checker must first know
that its callback roles match the row it instantiates. A missing role cannot be
silently treated as a crossing argument. Unsupported protocols keep their pending
demands; they do not acquire ownership through a partial row.
