## 2026-11-07 01:53 CET — Port the deep escape through summaries fix (#2179)

**What I did**

Ported #1869 from the deleted workers-hostfree branch. In `Ownership.zig`'s summary read-off,
`rec_only` was `listFacing(cell) == null`, so a whole record a callee keeps escaped as its object
alone. Now only an explicit object-only cell (`c ∖ All`) is shallow. Added §31.8's deep-escape note,
adapted to master's stores (no `Js.Any`, `Js.Cell`, `Js.Opt` or `Js.Builder`), the skill's
ownership-words paragraph, and two `ownership/core` fixtures: `DeepEscapeWrapper` (wrappers over
`Js.ref` and `Js.set`, inline controls, a read-only control) and `DeepEscapeImported` (an imported
`Js.ref` wrapper, fresh and cached). On master the three wrapper updates are accepted; with the
fix they are rejected `escaped`, as the inline ones are. No other golden moved and page sizes are
byte-identical to master.

**What I learned**

The original also changed `RecordCapture`'s golden and added `RecordCaptureFresh`, whose summaries
name the HostFree `JobStorage` shape; master's RecordCapture output does not change with this fix.
