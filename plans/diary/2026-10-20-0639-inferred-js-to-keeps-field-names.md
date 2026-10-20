## 2026-10-20 06:39 UTC — inferred Js.to keeps field names

**What I did**

Reproduced canassa/beni#367 on upstream master `26425aa`. An unannotated
`row = Js.to (made ⊤)` then `row.missed` prints `missed` in a development
build. The release build reads a short key (`a.c`) and the value is
`undefined`. A nested `inner = row.hole` then `inner.buried` throws,
`Cannot read properties of undefined`. The same fault hits a `let`-bound
`Js.from` whose parameter is a type variable at the cast and a record at
the call in that declaration.

The boundary walk only read the variable the cast was unified into. The
`let` generalises that variable before the body instantiates it, so the
walk stopped at a type variable and release renamed the field. `Instantiate.copy`
now records later copies of type variables reachable from that variable,
while the cast's declaration is being solved, and the walk reads those
copies. A copy made for another declaration is not recorded.
`tests/corpus/run/JsToInferredRecord` prints `missed`, `buried` and `sent`
in both builds. `zig build gates` cannot count instructions on this host.
`zig build test test-blackbox fmt-check beni-fmt-check` exited 0, and
`zig build test-run-hashes` under Node v24.19.0 added that fixture's
`_expected.run-hash`. No other hash file changed.

**What I learned**

A polymorphic `Js.to` or `Js.from` in another declaration still must not
pin. `core/Schema.beni`'s `fromHost` and `core/Task.beni`'s `guest` say the
host only stores the value. Following every later instantiation would pin
fields of every record those functions are used at. A separate `pub open ⊤
= Js.to (made ⊤)` whose caller reads `.missed` still prints `undefined`
under `--release`. That limit is
https://github.com/canassa/beni/issues/503.
