## 2026-11-09 08:17 CET — An inline development build writes no `_platform/Tea.mjs`

**What I did**

- Reproduced #2106 on master `9d5a878494`: a `Tea.sandbox` page built for `browser-inline` in development wrote `_platform/Tea.mjs` and its map. No module imported them.
- Added `Emitter.cutConstructors` in `src/js/Emit.zig`. For a lowering that sets `constructs`, it cuts the callee instruction of each program constructor call (`Reach.Input.cuts`). The rule that finds the calls is the rule of `Lower.findPrograms` and `Lower.programConstructorOf`.
- Added `tests/corpus/emit/inline/NoConstructorFile/`, whose `_expected.absent` names the two files. It failed without the fix (`UnexpectedOutputFile`) and passes with it.
- Amended `browser-inline.md` §10.5 (dated 2026-11-09). Gates green; no other golden moved.

**What I learned**

- An emit project fixture can assert that a file is absent with `_expected.absent`. It is the only way to golden a file that is not there.
- `Lower.programCall` and reachability must agree about the callee of a program call. `cutPrerender` already did this for `Browser.prerender`; the constructors needed the same cut.
- A blessing run with `-Dcorpus` reports a failed `build` part when the filter matches no case of that part. The blessed golden is still written.
