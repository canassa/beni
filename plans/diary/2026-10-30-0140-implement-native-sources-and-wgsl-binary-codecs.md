## 2026-10-30 01:40 CET — Implement native sources and WGSL binary codecs

**What I did**

Added explicit WGSL host-shareable layout/codecs and native exact-word Atomics in beni. Added complete native source identities, ImageData allocation/view aliasing, image decode and bitmap options, VideoFrame capture/clone/close, canvas acquisition and bitmaprenderer ownership, and structured-clone/transfer packets with native brand checks. Chromium evidence exercises all seven source arms and native sender invalidation, bitmap consumption and snapshots. Focused binary fixtures run both output modes and verify published WGSL offsets and bytes. Updated the generated API and a binary/source skill guide. Worker client/host work continues; filed #1287 for the proper non-markup beni entry runtime it requires, with compiler work delegated separately.

**What I learned**

OffscreenCanvas dimensions and setters do not prove detachment. There is no side-effect-free native detached getter, so readiness explicitly requires context validation instead of inventing a shadow state. Native transfer rejects a second attempt on the same canvas. The first transfer probes exposed an incorrect test assumption about resize failure, which was corrected against HTML and actual Chromium behavior. Zero-copy bitmap presentation invalidates bitmap aliases while independent VideoFrame references remain live. Native helper constructors and shader layout must keep byte offsets separate from typed-array element counts.
