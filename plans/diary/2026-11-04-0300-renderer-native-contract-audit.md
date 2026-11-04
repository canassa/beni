## 2026-11-04 03:00 CET — Renderer native contract audit

**What I did**

Completed the trusted surface and body pins for typed native Array/KeyMap
storage and the renderer's style, event-message, append and rejection adapters.
Added typed call fixtures and unsafe flips for retention and returned aliases.
Fixed #1827 in the native generator: Document imports are sorted and adjacent.
Included the reviewed Event.dataOnly pin correction from b3c587f28e. Kept the
rendererTruncate body pin and v2 fixture; removed its spurious legacy surface
row, matching the existing written-only Js.Array operations. Imported the
reviewed rendererAt/rendererTruncate/rendererHas commits from the row lane.

**What I learned**

A returned fallback is eager: a defect cannot be used as a lazy getOr default.
The renderer needs its reviewed checked index read. Native storage retention
and returned defaults have observable ownership effects, pinned by the new
fixture. All scoped native-generator, surface, pin, flip and corpus checks
passed twice under the shared lock. Full-family gates remain in progress;
this is a checkpoint and does not claim the HostFree conversion is complete.
