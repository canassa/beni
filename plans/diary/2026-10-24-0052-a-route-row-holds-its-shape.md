## 2026-10-24 00:52 CEST — A route row holds its shape

**What I did.** #915, second slice. Some widgets write `replace` as `Result.withDefault
(Json.decodeValue state) model`. When the program takes the shapes side of the fork, the row of
such a widget now holds that run's shape, not the widget's wrapper function. The `…Shaped` loaders
run core's `validShape` of the shape, which the lowering passes to them, and give the decoded value
or the old one. They tell a shape from a function by `typeof`, so a `case`-shaped `replace` keeps
its function. Reachability cuts the tail's call of the wrapper and roots the shape and
`validShape`, so the wrapper is gone from S1's output. The function's module exports the codec's
shape for development builds. New fixtures: `emit/release/inline/ShapeLoader`, and
`browser/inline/ShapeLoader` with `CaseLoader`'s transcript unchanged.

**What I learned.**
- The route rows are final only in `buildDirect`, after elimination. But `eliminate` can already
  read the Writes programs and decide on shapes. A cut at the call's callee and two pinned roots
  then say everything reachability must know.
- `Js.to` into a `Result` in platform code makes `Result` visible to JavaScript. Every `Result` in
  the build then gets string tags. A beni function type for the parameter (`V, V → Result V V`)
  keeps the tags integers.
- A function passed to `loadRows` and called in a `map` callback is not inlined: it is a call
  across a function boundary. The shaped and unshaped row loaders are therefore two functions, and
  they share the copy loop.
