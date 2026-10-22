## 2026-10-22 18:32 CEST — Preserve ownership through folded dictionary tree paths

**What I did**

Bisected the safe singleton dictionary/tuple refusal from #731 to master.
c65cc73ec (#737) is the first bad commit; its parent accepts. Retained the
selected container's conditional native-tree fact instead of expanding
structural alternatives into a reflexive separation requirement. Caller
construction annotations and separation between distinct arrivals remain.
Promoted the red-first fixture from #761, added tuple-field and key/value
sharing controls, and invalidated old summary blocks.

The ownership corpus passes with every prior verdict unchanged; four goldens
change summary metadata only. The reduction and the four reported browser
programs pass enforcement. The deferred #663 two-key case remains refused.
Integrated master's entry-ownership changes and passed the locked full gate.
An earlier full gate hit the chat transcript's delayed first receive; that
test passed in isolation and in the integration gate. No checks or waits were
weakened. No copies in core/platforms, measurements, LLVM or budget changes.
The genuine Ref copies and pending-index repairs follow separately for #210.

**What I learned**

A folded tree's alternative contents are not simultaneous stored aliases.
The existing conditional native Dict obligation must survive the new
per-path construction guards; replacing it with a self-separation requirement
loses precision before the caller supplies an entirely fresh value.
