## 2026-10-14 17:02 CEST — preserve unseen tagger ownership

**What I did**

Answered the ownership PR review with exact constructor comments, direct and
bound tagger refusals, a custom markup wrapper refusal, a sorted operand
lookup and its safety assertion. Additional adversarial probes found that an
unseen lambda tagger could return a retained shared list after render-only
data was correctly excluded from event payloads. Specified and enforced its
owned-result requirement, including conditional cell-free capture requirements
and forwarding callback obligations with actual supply facts. Added three
rejected probes; fourteen rejected twins now accompany the four accepted
Conduit shapes. Scalar callback results retain their valid Int/String uses.
The full Conduit check still accepts 26/26 demands, with every pre-existing
ownership-corpus demand verdict unchanged. Native zorg gates finish with
1,295 passing tests, 15 skips and only the four authorized macOS failures.
The pending browser/direct audit passes all 15 pins. No LLVM was used.

**What I learned**

Correcting the rendered-data approximation exposed a masked unseen-callback
requirement. Returning a captured message is safe only when callers prove it
contains no mutable cell; forwarding a callback must preserve its actual
supplies as well as its owned-result obligation. The earlier diary's six HTTP
promotions is corrected here: HttpFailures retains a separate work-slot-inside-
traversal-callback limit, so it remains pending unchanged with one approximate
list_still_used diagnostic. Five HTTP promotions stand. Conduit's original
three runtime scripts still stop at the separate document-helper lowering gap.
