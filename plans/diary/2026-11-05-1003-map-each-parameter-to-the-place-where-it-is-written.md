## 2026-11-05 10:03 CET — Map each parameter to the place where it is written

**What I did**

Built part 3 of #141, the last part: in a `--release` source map, each parameter maps to the place where the beni source writes it, with its beni name. The owner chose the representation (Cesar, 2026-11-05, dashboard question `release-map-js-q3`): a range of positions in each `JsIr.Func`, after the body, one `pos` for each parameter. Only `Lower` gives real positions (`Builder.addFuncAt`); every function that the compiler invents gets `no_pos` through `Builder.addFunc`. `Suspend`, `Lower.methodFunc`, `Spec.applyDrops` and `Spec.Copy` keep the places, and a copy into another module gives them by part 2's rule. The printer marks a parameter only under `--release`; a bare `a=>` parameter keeps the function's name, so Node still names the frame after the function. I amended `backend.md` §11.2 (*Parameters*), added two `build_test` tests and a `JsIr` unit test, changed two frame tests, and checked them red three ways. The branch is on part 2's branch, because a copied parameter needs part 2's rows.

**What I learned**

- My recommendation in q2 (a table of (name, position) rows for each module) was wrong. `JsIr` keeps one `NameIndex` for each distinct name, and a parameter's tag restarts for each declaration, so `f x` and `g x` share one `x`. The owner saw it; the new test is that case.
- A copy gives each local a fresh `$i` name, so a copied parameter has no beni name in the map (#1962).
- A test copy must be a real copy: with one call of `List.indexedMap`, Spec specialises the lambda inside `Aid`, and the red run passed. Two calls copy it into `main`.
- Without maps, the tests' beni costs 0.18% to 0.23% more instructions in a release build. A profile puts it in `Spec`: each walk reads a whole `Func` record to find the body, and the self-hosted backend reads and checks all 6 words. The LLVM ReleaseFast beni pays 0.04% to 0.07%. An `inline` `ownPos` changed nothing; the profile, not a guess, found the place.
- Every function pays 8 bytes and 4 for each parameter: 12 KB on `bench/corpus`, 23 KB on Conduit. Peak RSS does not move.
