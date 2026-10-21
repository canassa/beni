## 2026-10-21 08:32 UTC — release keeps a computed proto set

**What I did**

`run/ReleaseProtoComputed` sets `[[Prototype]]` through `Js.setAt` with a
binding, a parameter and `String.append`, then writes `n`. On upstream
`17e21f9b9`, development printed `1`, `1`, `1` and `9`. Release printed
`0`, `0`, `0` and `9`. The release file had `a.__proto__=b` and no
`a.n=1`. `run/ReleaseProtoSet` printed `1`, `1`, `9` and `1` in both
builds on that compiler.

Fact 3 escapes the object unless the key node is a string literal other
than `"__proto__"` or a numeric literal. Those two cannot be that string.
A name, a call, `true`, `false`, `null`, `undefined`, and an index loop's
variable still escape. Both builds of `run/ReleaseProtoComputed` print
`1`, `1`, `1` and `9`, and the release file keeps `a.n=1`.
`run/ReleaseProtoSet` stays `1`, `1`, `9` and `1`.
`emit/release/core/IndexLiteralDrop` keeps the `k` write and the `[0]`
write and drops the unread `n` write. That file is the same bytes the
master compiler emits for the same source. #520 stays open.

The rebase onto `17e21f9b9` moved no run hash and no golden. The fast-path
file is the same bytes that compiler emits. One `bench/size.mjs` run on
each compiler against that base, the two runs at once, load 0.43 at the
start and 1.84 at the end on 4 cores. `bench/corpus` release is 73 711
raw, 21 964 gzip and 19 280 brotli on both. The 536 programs present on
both sides have the same release sizes. The total rises by the new
fixture alone, 687 raw, 320 gzip and 299 brotli.

**What I learned**

The drop happens before the key is folded. Release still prints
`a.__proto__=b`, so the literal escape from #513 never sees the key that
decided the drop. A numeric literal is the IR tag `number`, so it is not
the string `"__proto__"`. An index loop's variable is a name, and a name
can be that string, so the loop still escapes. Core and platform modules
are wild in the representation-key artifact, so that artifact cannot tell
this parameter from an `Int` index.
