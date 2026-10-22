## 2026-10-22 21:32 CEST — Keep callback ownership conditional

### What I did

Recorded CK-268 red first: a unit-state Durable Object with Object.none
was refused despite having no list writer. Kept the possible writer as a
conditional callback-result ownership requirement, through slots, wrappers,
recursive joins, carried protocols and summary block v26. Unknown writers
remain conservative. Dependency sets have their own ordinary union; an empty
set of dependencies is not the universal set that an empty record write set
means.

Promoted the Workers reduction. Added a two-module control for read-only and
writing callbacks, recursive propagation and aliases returned to a later
write. The imported wrapper retains both sharing refusals from cache. Every
earlier ownership golden is unchanged. All twelve Workers projects check
under ownership-everywhere with zero LIST refusals; their development and
release transcripts pass. Refreshed the nine remaining Workers hash pairs
against the current emitter (the three others were refreshed with #792).
The emitted CrossRequest tree matches the pre-change compiler byte for byte.

The completion-candidate audit, with the four approved Ref copies applied
separately, covers 1,503 roots/module sets and 1,295 LIST lines: zero rejected,
zero pending, no dump/check errors. It includes Workers, development Debug
fixtures and the benchmark prototype's platform. Saved the copies for their
own PR. The locked self-hosted full gate passes. The #663 DictFocusGrow
control keeps its checked red signature and owner deferral to #294.

### What I learned

The opaque response was correctly unknown. The error was demanding ownership
unconditionally when only another generic callback might write a borrowed
supply. Keeping that dependency until its actual is known accepts the
nonwriters without asserting a host allocation fresh or changing any
unknown-callable control.
