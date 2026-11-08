## 2026-11-08 16:56 CET — WebGPU render review fixes

**What I did.** Answered the independent review of the WebGPU render PR
(#2266): a batch now checks a render pipeline's bind group layout against
its own device (a fixture printed `Ok` before), an occlusion query left
open at a pass's end or begun twice is refused locally, a host's format
refusal names every candidate format, and new fixtures pin hostile format
errors as defects, every remaining render command and refusal, and the
device-only failures that come back as `Validation` in Chrome. The skill
gained a checked render example.

**What I learned.** `foreign` is a keyword, so a fixture cannot name a value
so. An argument of a `_` placeholder call is evaluated inside the lambda,
so a value that suspends must be bound before a sync callback names it.
