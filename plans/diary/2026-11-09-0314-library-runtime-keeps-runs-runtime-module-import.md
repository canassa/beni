## 2026-11-09 03:14 CET — A library runtime keeps run's runtime module import

**What I did**

- Issue #1877. `beni build --release --library` cut a program runtime's `import { escape } from "beni:Views"`, but it kept `run`, which calls `escape`.
- Added the `build_test` fixture *a release library keeps the runtime module import that the kept run uses*. It was red on master and is green now.
- Added `Emitter.markupRuntimeKeep` in `src/js/Emit.zig`. It gives the exports that `--release` keeps of the markup runtime. `copyAssets`, `copyMarkupRuntime` and `programUses` use it, so the cut file and the import list come from one set.
- Added a dated amendment to `backend.md` §15.1, *The runtime module*.

**What I learned**

- `escape` is a legacy JavaScript global. An unbound `escape` does not throw: it calls the global, which returns the text unchanged. A fixture must check the output, not only a `ReferenceError`.
