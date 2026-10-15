## 2026-10-12 19:54 CEST — animation-frame subscriptions

**What I did.** `Browser.Events.onAnimationFrame`/`onAnimationFrameDelta` and their direct forms
(`boundary.md` §9.8.18), beni over `Js`: one frame clock, one `requestAnimationFrame` per frame for
every subscriber, cancelled when the last leaves; the frame's listeners run under `Task.fromHost`, so
its messages render inside the rAF callback. The page driver gained virtual frames (`frame`,
`frames`) in both DOMs; fixtures `browser/tea/AnimationFrames` and `AnimationFrameStops`. PR #70.

**What I learned.** Adding constructors to `Browser.Events`' shared `Key` type grew an `onResize`
page by 39 raw bytes (the release tag table holds every constructor); a separate `FrameKey` type keeps
non-frame pages byte-identical. Without `Task.fromHost` the frame's render still lands before paint
(microtask checkpoint), but after the callback — the fixture's `frame … tasks` tells the two apart.
Six `test-browser` fixtures fail on Chrome 154 with master's own driver (trusted events, two defect
pages); not this slice's.
