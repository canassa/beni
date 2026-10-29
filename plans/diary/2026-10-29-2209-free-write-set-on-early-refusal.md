## 2026-10-29 22:09 CET — Free the write-set pass on an early refusal

**What I did**

- #1237: `Emit.run` freed the write-set pass (`e.writes`) only in `buildDirect`, so a refusal between the pass and `emitModules` (`debug_in_release`, `refuseMarkupWithoutLowering`, a check moved there) leaked about 55 allocations in a `browser-inline` build. The `run` defer now frees it.
- Added `build/bad-release/inline/` (browser-inline, `--release`, no `--allow-debug`) with `DebugLogInView`. Red before the fix with 55 SafeAllocator leak lines in the golden mismatch; green after.

**What I learned**

- The leak did not need #1218's moved check: `refuseDebug` on a browser-inline app already reached it on master, and no fixture covered that.
- Under heavy machine load (load average 50) two long fixtures hit the 120 s guard in a full gates run; both pass alone.
