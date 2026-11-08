## 2026-11-08 02:55 CET — WebGPU foundation: review fixes on the generated surface and the init waits

**What I did.** Answered an independent review of #2254. `Size64` is now 0 … 2⁵³ − 1, the
domain Web IDL's ConvertToInt gives `[EnforceRange] unsigned long long` (the contract said
2⁶⁴ − 2048, which the host refuses; §3.1 corrected). `NumericDomain` carries the scalar's
`DomainError`, with `Gpu.Error.atPath`. The generator reads snapshots member by member (a
missing or mistyped member is a defect naming it; seven newer or feature-bound members are
`Maybe Int`), classifies limits by an explicit table, and puts the four length-checked
sequence arms behind opaque lists. The census test now looks for each declaration in its own
block, and a test drops a member, an enum value and a flag constant to show it fails.

The init waits no longer lose anything to a cancel. Each request makes a channel first, a
detached fiber of the requesting program; the promise's reaction classifies the outcome
(recording the adapter or device, freeing a refused adapter) whether or not anyone still
waits; an abandoned device is destroyed; an unexpected late outcome, and a throw inside any
reaction, reach the program as a defect. A device holds the channel until the host reports
its loss, so the sentinel ends. A `TypeError` with no feature requested is a defect.

**What I learned.** Web IDL caps every 64-bit integer type at 2⁵³ − 1 before
`[EnforceRange]` checks, so no GPU number is ever above it. A platform cannot keep a module
from the program it is the top of (#2256): only a layered platform's re-exports hide it.
`%` is not beni; an IDL enum's comments can hold quoted words that are not values.
