## 2026-10-15 20:34 CEST — Weigh Bike Wars' release build

**What I did**

- Checked issue #158 on master `f1ab9cc87`. Pull request #121 removed the
  `Debug.log` from `Helpers.toLine`, and `beni build --release` of Bike
  Wars exits 0 on both browser platforms. It prints two `prepend_in_loop`
  warnings and no error.
- Added `app` lines to `bench/size.mjs`. They build every application
  under `examples/` from its own `beni.json`, dev and `--release`. The
  release build takes no `--allow-debug`, so a program that reaches
  `Debug` fails the script. Bike Wars' release line: 28 373 B raw,
  9 205 B brotli.
- `bench_test.zig` checks the lines. With the old `Debug.log` back, 4 of
  its 5 tests fail with `debug_in_release` at `src/Helpers.beni:69:13`.
- Added research 100 §9: Bike Wars' release bytes with §3's method.
  Whole brotli is 9 205 B on `browser-tea` and 11 090 B on
  `browser-direct` (+20.48%). Two environment variables let
  `bench/s8/build-apps.mjs` measure one application into its own
  directory, so the frozen batch's results do not change.

**What I learned**

- `bench/size.mjs` builds every release with `--allow-debug`, for the
  `run/` programs that use `Debug.log`. Thus it could not show a release
  that `debug_in_release` refuses. A line for a shipped application must
  not use that flag.
- §3's harness needs `acorn` and `@jridgewell/trace-mapping` from
  `bench/ui/apps/solid1/node_modules`. The lockfile's exact versions,
  installed into a scratch directory, give the same bytes.
