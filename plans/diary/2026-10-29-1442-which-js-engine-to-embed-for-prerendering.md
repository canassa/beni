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
engine's `Math.pow` and `sin` are whatever the Zig link resolves the C names to (compiler-rt or
the target's libc, per engine and even per optimisation mode, as the reviewer showed with `nm`
after I had blamed "the libm"), so the same engine prints `10.0 ^ k` differently linked with musl
than with glibc. Linking C also makes the native Linux `beni` dynamic. Between the two QuickJS
lines the difference is small: Bellard's is faster and traps under ReleaseSafe's UBSan on one
missing cast that QuickJS-ng has; QuickJS-ng wins on shipping clean and on cadence.
