## 2026-11-04 20:20 CET — Map copied bodies to the module they came from

**What I did**

Built part 2 of #141: in a `--release` source map, a body that whole-program specialisation copies from another module maps to the lines it came from, not to the call. The owner chose the representation (Cesar, 2026-11-04, dashboard question `release-map-js-q1`): a position stays 4 bytes, and a copied node's `pos` names a row of a per-module table `JsIr.far` of (module, offset). `Spec.Copy.posOf` writes the rows, also for two `knownExpr` lines that wrote a source offset into the destination before; `Spec.Copy.site` is gone. The printer keeps the raw `pos` in its marks, and `SourceMap.Stretch.far` resolves the rows to entries of `sources` in both layouts. I amended `backend.md` §11.2 (*Copied bodies*), updated two `build_test` tests, added a library test and a `SourceMap` unit test, and checked them red with copies that get no position.

**What I learned**

- The rows cost 424 bytes on `bench/corpus`, 8.8 KB on Conduit and 2.1 KB on Sternhalma; peak RSS does not move. Even `Node.print "x"` has 6 rows, because core bodies are copied into `Main`.
- With maps, the cost is the text of the new sources (`sourcesContent`): +128 KB on Sternhalma, +10 M instructions.
- A copy has no frame of its own. The crash frame of a copied `Debug.todo` now reads `at describe (…/Debug.beni:43:15)`: the call's line is not in the trace. A map cannot hold both.
- Item 6 of §11.2 (a kept operand keeps its position) was tested through a copy. With copies mapped to their own source, the test needs a kept call that is not copied: `Aid.bad` with two calls.
- `Opt.zig` changed on master after my first baseline, so measurements need a master binary at the branch's own base.
