## 2026-11-05 01:45 CET — Native projection review

**What I did**

Addressed the six review follow-ups for #1937. Private typed host projections
now require direct saturated calls; values, arguments and placeholder functions
are refused before emission. A black-box test modifies the real core Headers
module and proves all three were accepted before this fix. A public-wrapper
reference and explicit lambda remain valid. A check/bad fixture pins the
application fence too. Worker result adaptation recognizes a successful Worker
instead of assuming DOMException inherits Error. The new happy-dom page covers
query selection found/missing/SyntaxError, every Worker construction result and
Storage.set quota. Its scripted DOMException deliberately does not inherit
Error; the old compiler reports both DOMException failures as successful workers.
The page scripts the standard selector failure because happy-dom 20.14.5 uses
the wrong exception name for invalid selectors. Real found/missing queries run
against its DOM.

Corrected the RegExp spec row, gave Map.has its borrowed receiver word with a
pinned native body/summary, and simplified ReadResult.host_value to its actual
identity getter. Re-read the affected ownership bodies and updated only their
pins. Targeted refusal, native generation, browser, ownership audits and both
format checks pass. No full gate rerun, as requested by the manager.

**What I learned**

A raw native sibling is not a first-class implementation of the typed Opt ABI:
only Lower's recipe normalizes host values. Rejecting private escapes protects
that invariant while public beni wrappers remain ordinary functions. Testing
DOMException without Error inheritance exposes an otherwise invisible success
misclassification.
