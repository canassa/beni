## 2026-09-21 22:03 CEST — the flake had one system, and macOS folds `main.mjs` onto `Main.mjs`

**What I did**

- `flake.nix` named a single `system = "x86_64-linux"`, so the first checkout on an
  aarch64-darwin machine got *no* devShell at all and direnv fell back to the ambient
  environment — which had a `zig` from `~/.nix-profile` but no `node`, so gate 2 could
  not have run even in principle. Rewrote it with a `systems` list and a `forAllSystems`
  helper over `nixpkgs.lib.genAttrs`; the package list, the comments and the `shellHook`
  are untouched. The shell builds on darwin from the public cache alone:
  `zig 0.16.0 · node v24.19.0 · zls 0.16.0 · jq 1.8.2`.
- Ran the three gates on darwin. `fmt-check` and `test` pass. **`test-blackbox` fails,
  31 of 277**, and the cause is one defect, not thirty-one.

**What I learned**

- `src/js/Emit.zig:1371` hardcodes the entry file as `out/main.mjs`, and the conventional
  entry module `Main.beni` emits `out/Main.mjs` into the same directory. **APFS is
  case-insensitive by default**, so the two are one file: whichever is written second
  wins, and here the shim wins. The surviving `out/Main.mjs` is the shim, whose
  `import { Main$main } from "./Main.mjs"` now resolves to *itself* —
  `SyntaxError: does not provide an export named 'Main$main'`, exit 1. Every failing
  test is downstream of that: 14 `expected 0, found 1`, 9 golden-output mismatches, the
  `Debug.todo` message, and the platform's exit code 3 arriving as 1.
- The harness has the same hazard from the other side: `build_test.zig:1684` asserts
  `!w.exists("out/main.mjs")` to prove `--library` writes no entry file, and on a
  case-insensitive filesystem a perfectly correct `Main.mjs` makes that assertion lie.
- §5.2 says "the platform declares this … rather than hardcoding one", and the entry
  file's NAME is the one part of the output shape that is still hardcoded in the emitter.
  A fix that moves the name into `platforms/node/beni.json` would be §5.2 being finished
  rather than amended — but it is a spec change and the owner's call, so nothing is
  changed here beyond the flake.
- A separate, non-blocking observation: `abuse_test`'s "5 000 empty modules produce
  identical output" hit the harness's 60 s `CompilerTimeout` on this machine. Not
  investigated; it may be nothing more than a cold `.zig-cache` and a first run.
