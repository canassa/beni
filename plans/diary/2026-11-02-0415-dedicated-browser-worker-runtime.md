## 2026-11-02 04:15 CET — Dedicated browser worker runtime

**What I did**

Added the gated Browser.Worker runtime using Task's public API: owned startup,
typed calls and events, cancellation with cleanup, cooperative close and abort,
and fatal worker reports. The bootstrap bounds early messages and preserves
MessageEvent metadata. Wire plans normalize List views across every payload.

Chrome fixtures cover development and release, including genuinely parked init
and handle callbacks. A synchronous boot closure retains typed callback calls
before the opaque Program boundary, so hidden Task completion callbacks stay
inside core. The old test transport uses the same technique for #1660.

**What I learned**

An already-closed owner can begin cleanup before Hello. The worker must accept
Close before initialization, and open must refuse a Ready from a closing peer.
Unused entry-kind constructor metadata also belongs outside ordinary platform
cache keys. Borrowed callback state (#1658) and private Log-context transport
(#1665) remain follow-ups; no public Log API was added.
