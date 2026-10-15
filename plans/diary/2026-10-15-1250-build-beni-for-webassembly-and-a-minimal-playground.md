## 2026-10-15 12:50 CEST — build beni for WebAssembly and a minimal playground

**What I did**

Issue #128, first pull request. I specified the playground in
`docs/design/playground.md` and the single-threaded path in
`fast-compiler.md` §10, *A build with no threads*. The owner's three
decisions are recorded there: `browser-direct` only at launch, CodeMirror 6
from a CDN, and the page in `playground/`.

The compiler now builds for `wasm32-wasi`. Each place that starts a thread
has a comptime guard on `builtin.single_threaded` and runs its work on the
calling thread; the main stack is a check thread's 64 MiB plus 1 MiB. Three
more changes were needed: the profile's thread buffer is aligned to a cache
line instead of padded by a sum that assumed a 64-bit `usize`, and stdout and
stderr are streams, because Node's WASI refuses a positional write.

The page runs the compiler in a worker on its own WASI shim,
`playground/wasi.js`, and the program in a sandboxed frame. `zig build
playground` writes the site. The gates compare a native single-threaded
compiler and a self-hosted `.wasm` with the threaded compiler;
`zig build test-playground` compares the shipped `.wasm` on 765 corpus
programs, all byte-identical.

**What I learned**

- The self-hosted wasm backend compiles beni in about 7 s, but its code costs
  5 to 7 billion instructions on a `browser-direct` page under Node, over the
  budget. LLVM's costs about 1 billion with `--liftoff-only`. V8's tier-up
  costs more than it saves in one short run.
- The test runner raises its stack limit to 256 MiB and every child inherits
  it, so a stack-size test passes even with a too-small stack. Starting the
  compiler from `sh` with the soft limit of a login shell made the test fail
  without the fix, as it must.
- In Chrome the engine's stack, not the 64 MiB shadow stack, bounds the
  nesting depth: 606 levels of `f (f (… 1))`, where the native compiler
  builds 4 000.
- `ReleaseSmall` is 2.15 MB after brotli and as fast as `ReleaseFast` after
  the first compile; TodoMVC compiles in about 37 ms in Chrome 153.
