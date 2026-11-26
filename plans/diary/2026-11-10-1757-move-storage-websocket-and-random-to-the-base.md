## 2026-11-10 17:57 CET — Move Storage, WebSocket and Random to the base

**What I did**

- Moved `Storage`, `WebSocket` and `Random` from `browser` to `browser-base`. Every capability
  family of the base design's §7 step 2 is now in the base.
- Added prerendered inline fixtures `BaseStorage`, `BaseWebSocket` and `BaseRandom`, and the
  refusals `BaseStorageInView` and `BaseRandomInInit`.
- Measured the inline TodoMVC again: it now stops at three markup limits, not at capabilities.

**What I learned**

- A blessing run's `-Dcorpus` filter is a substring. `prerender/Base` rewrote every existing
  `Base*` golden too. They came back identical, but use the exact fixture name.
- A fixture over randomness shows a property of the draw, never the draw.
