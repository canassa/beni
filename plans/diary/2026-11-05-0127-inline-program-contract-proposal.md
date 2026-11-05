## 2026-11-05 01:27 CET — Inline Program contract proposal

**What I did**

Started the inline proposal branch from the merged browser review fixes. Traced
the existing fourteen refusals through Program/SSR wrappers, row loaders and
listeners. Sent the manager a private typed contract proposal before changing
interfaces or implementation. The implementation must close #1934.

**What I learned**

A source constructor can honestly be pure while storing an effectful unreachable
mount job: construction and invocation have different effects. Closed typed load
batches can preserve the existing decode-all-then-copy ordering without storing
heterogeneous decoder callbacks in raw arrays. Native listeners can reuse the
existing typed event registration and dispatch guard.
