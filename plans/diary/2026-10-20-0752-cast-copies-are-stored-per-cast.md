## 2026-10-20 07:52 UTC — cast copies are stored per cast

**What I did**

Addressed the review of canassa/beni#502. `jsCast` has its doc comment
again, and `noteCastImage` has its own. Each cast now has its own list of
later copies (`Instantiate.CastCopies`), parallel to `Solve.casts`. The
boundary walk reads that list once. `copy` looks up the casts of the
declaration being solved once per declaration, then only those lists.
The cast variable itself is not pushed a second time.

The cross-declaration limit is named in `checker-v2.md` §28, `backend.md`
§9 and the 06:39 diary entry.
https://github.com/canassa/beni/issues/503

Run hashes stay on Node v24.19.0. `tests/blackbox/run_hash.zig` and the
checked-in lines use that version, and `flake.nix` selects `nodejs_24`.
The new fixture's hash was already recorded with it, so it was left as it
is. `JsToInferredRecord` still prints `missed`, `buried` and `sent` in
both builds. A separate declaration still prints `undefined` in release.

One cold `beni build` of a platform function with 2 000 `Js.to` bindings
and a field read of each took 42.653 s on the previous compiler and
0.569 s after this restructure, with that project's `.beni-cache` removed.
One sample each.

**What I learned**

`copy` may use `stacks.vars` and `TypeStore.nextMark` for this walk.
Pass 1 has already emptied the stack. `wantInOrder`, `mapped` and
`recordCopy` do not call `copy` and do not use that stack. An import is
read in `reference` before `copy` runs. The callers (`Solve`, `Groups`,
`Instances`, `Codec`, `Contexts`, `substitute`) do not hold the stack
across the call.
