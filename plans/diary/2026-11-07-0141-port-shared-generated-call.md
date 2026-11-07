## 2026-11-07 01:41 CET — Port the shared generated call fix (#2178)

**What I did**

Ported #1784 from the deleted workers-hostfree branch: `Spec.zig` counts a call by the number
of times the scan lists it (`countedCalls`), retracts and extends its subtree that many times,
and a pending call list rewrites each node once. Added the toy platform's `shared-toy` lowering
and `external-platform/SharedCallForward`, driven by `external_platform_test.zig`. Without the
fix the release build panics (`reached unreachable code`, exit 255); with it both builds print
`rightleft/rightleft`. Page sizes are byte-identical to master.

**What I learned**

The original's second fixture, `SharedGeneratedOperands`, depends on the `typed-toy` lowering
and `Js.Any` packets of the HostFree design, which master does not have, so it was not ported.
