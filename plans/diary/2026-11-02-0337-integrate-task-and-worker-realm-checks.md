## 2026-11-02 03:37 CET — Integrate Task and worker realm checks

**What I did**

Rebased typed Task onto the merged realm checker. Preserved both realm and
callback-holder summary data through the conflicts. Regenerated the two
conflicting emission goldens. Traced the integration's deep arithmetic crash
with GDB and moved general-call temporaries out of recursive arithmetic
lowering (#1673).

**What I learned**

The existing 4095-term addition cases type-checked but exhausted the emitter's
native stack. Both development and release now build and run at that same
accepted depth. The full emission corpus confirms that separating the Zig
frames changes no generated JavaScript.
