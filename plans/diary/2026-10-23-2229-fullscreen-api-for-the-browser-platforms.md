## 2026-10-23 22:29 CEST — Fullscreen API for the browser platforms

**What I did**

Added full screen to `Dom` (issue #903): `requestFullscreen`, `exitFullscreen`,
`fullscreenElement`, `onFullscreenChange` and `eachFullscreenChange`, written in
beni over `Js`. A refusal is a `FullscreenError` value: `NoElement`,
`Unsupported`, `NotActivated` or `Refused`. A rejection that is not a
`TypeError` is a defect in the waiting fiber. `boundary.md` §9.8.6 has the
amendment. The page driver now scripts the Fullscreen API in both DOMs, with a
`fullscreen` step. `browser/tea/Fullscreen` covers success, Escape, exit and
every refusal. The driver change re-recorded every browser run hash.

**What I learned**

- On this aarch64 macOS host, `zorg build -fincremental --watch` panics with
  `TODO(MachO2): load archive`. A one-shot `zorg build` works.
- Clean `master` fails four `ownership/core` cases on this host
  (`CastAcross`, `FullCast`, `GrowingCast`, `GrowingReturnedFunction`), besides
  the two case-folding `build_test` cases. Linux CI passes them.
- happy-dom's `document` is no instance of its `Document`. Patch the
  `document` object, not `Document.prototype`.
- `run/WebSocketFaults` ended with SIGTERM once on this host under
  `test-run-hashes`. Its hash stays as on `master`.
