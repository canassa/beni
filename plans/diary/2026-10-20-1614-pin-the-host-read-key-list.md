## 2026-10-20 16:14 UTC — pin the host-read key list

**What I did**

Rebased the one commit onto `ffc2fdb`. A unit test now pins
`implicit_host_keys` to `toJSON`, `toString` and `valueOf`, three
names. `run/ReleaseImplicitKeys` still prints `1`, `x5y` and `1` in
both builds. The run hash did not move.

A probe wrote an unread `constructor` and used the object only with
`&`. Both builds printed `0`. Release was `({}&1)`. `prototype_names`
stops a missing `constructor` folding to `undefined`. It does not keep
an own key.

`Js.object` still refuses a `__proto__` key (`check/bad/core/JsObjectKey`).
A `Js.set` of `__proto__` to an object whose `valueOf` returns 7
printed `1` in development and `0` under `--release`. Release wrote
`({}&1)` and dropped the assignment. That write is unfixed.

**What I learned**

`neverWritten` and the two drop predicates answer different questions.
A name on `prototype_names` can still leave its literal. A write of
`__proto__` sets `[[Prototype]]`, so "nothing read the name" is the
wrong test for it. Putting that name on the host-read list would
describe a different fact.
