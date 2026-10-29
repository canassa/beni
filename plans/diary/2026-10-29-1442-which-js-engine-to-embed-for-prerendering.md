## 2026-10-29 14:42 CET — Which JavaScript engine to embed for prerendering

**What I did.** The research pass for P5 of prerendered pages (#1162, part of #1160): report
108. Built Bellard's QuickJS 2026-06-04 and QuickJS-ng 0.17.0 with `zig build` alone for the four
flake systems, Windows and `wasm32-wasi`; wrote a 200-line host (raw context, no `Date`, no
`Math.random`, a module loader, a virtual-clock event loop); linked each engine into a scratch
copy of beni to measure the binary; ran an engine sweep (2²⁰ doubles, every code point's case and
class), two beni programs over core's numbers and strings, and all 613 `run/` programs in both
builds under Node and both engines; timed a 7 504-element page. Built Kiesel, the Zig-native
engine, and dropped it. Recommended QuickJS-ng. Filed #1164 (`String.fromFloat` writes
`1e+21.0`) and #1166 (`Schema` copies the engine's `JSON.parse` message into a value).

**What I learned.** The engines are exact wherever ECMAScript is exact: not one difference from
V8 in a million printed doubles or in the case mapping of every code point. What differs is what
the standard leaves open or does not cover, and that is where §5.1's "by construction" breaks:
`Url.fromString` is pure and calls the WHATWG `URL`, which no embeddable engine has; and an
engine's `Math.pow` is its libm's, so the same engine prints `10.0 ^ k` differently linked with
musl than with glibc, which would make a page depend on the build machine. Linking C also makes
the native Linux `beni` dynamic. The sanitizer was the deciding test between the two QuickJS
lines: Bellard's traps on its first eval under the UBSan Zig gives ReleaseSafe C code.
