## 2026-11-01 23:46 CET — Retain imported callback effect joins

**What I did**

Preserved pure effect classes shared by different scheme variables in an
interface block. The existing block format can express the callback/nominal
result join; it no longer disappears because it lacks a fixed rung or edge.
Added an imported factory regression with synchronous and yielding callbacks.

**What I learned**

The same-module holder resumes correctly, but an imported factory loses its
callback/result effect join. With the fix stashed, development loses the yield
continuation and release also drops the synchronous callback's side effect.
The fixed development and release programs both print pure callback followed
by after yield. The callback and nominal holder design stays unchanged.
