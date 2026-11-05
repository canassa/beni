## 2026-11-05 00:41 CET — Keep native host projections typed

**What I did**

Replaced the earlier erased draft with typed Js.Opt projections after HostFree correctly rejected a native map cast. Specified every absence mapping with its operation's specification source. Added generated typed Map.has; KeyMap and Map guard typed gets with membership. Compiler recipes normalize host absence into the existing sentinel, and generated beni code constructs Maybe/Result. Callback payloads and optional host inputs stay typed.

The original renderer-storage HostFree test still has exactly six expected erasures; a new targeted check of KeyMap, Map, nullable headers and a payload callback has zero diagnostics. Native regeneration, the release-shape/runtime scenario, WebSocketDirect and CloudflareNative fixtures pass. Full default-on platform checking is tracked by #1807, rather than bypassing the known Browser/Rt erasures.

**What I learned**

Passing Just/Ok as first-class optMatch arms emitted a constructor arrow and call. Literal lambda arms use existing inline lowering, and literal native callback adapters can use the same checked binding path. Concrete opt_plain already worked; generic escape rules remain unchanged. The bounded round recovers 300 brotli bytes over the base's 316 emit files (312297 → 311997); empty browser/tea pages stay eight bytes smaller (1299 → 1291). HTTP (+34) and effects (+40) retain wrapper costs, tracked with the other local costs in #1923. These figures supersede the erased draft's earlier measurements.
