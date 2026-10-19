## 2026-10-19 21:51 UTC — Char refuses a lone surrogate

**What I did**

Reproduced issue 371 on the unfixed compiler. A JSON string of one lone surrogate decoded as a `Char` on the compiled reader, the validator worker, and the library interpreter. Each path accepted it because `Array.from(s).length === 1` counts code points. A lone surrogate is one code point and not a scalar value (`schema.md` §12.10).

Added `oneScalar` in `core/Schema` and called it from `prim`, `shapeChar`, and the generated reader. A pair that is one astral scalar stays one `Char`. Added `run/SchemaCharScalar`, and a lone high, a lone low, and one pair on `SchemaErrorUnreadShapes` so the shared shape reader runs.

`zig build gates` refused to run here (`perf_event_open` NOENT). `zig build test test-blackbox fmt-check beni-fmt-check` passed. Recorded the run hashes whose output changed.

**What I learned**

`Array.from` length is the wrong test for a scalar. `codePointAt` of a half is that half, and a scalar above U+FFFF is two UTF-16 units. `String.length` is specified in code points, so that use of `Array.from` is a different contract. `Char.toUpper` uses the same length to see whether casefold grew a `Char` that is already one scalar.

Development hashes moved wherever a build emits `core/Schema`, because the source map includes `oneScalar`. Measured on `SchemaDescribe`. The JavaScript was unchanged and the release hash did not move. Release hashes moved where the emitted JavaScript changed.
