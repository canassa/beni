## 2026-10-23 00:12 CEST — The incremental watcher gives a correct beni

**What I did**

- Measured a Debug build of beni with Zorg 0.17.1 (self-hosted backend): 51 s with a
  cold local cache and a warm global one, about 40 s after an edit under `src/` on a
  loaded machine. Plain `-fincremental` without `--watch` gains nothing: Zig 0.17 keeps
  no incremental state between processes.
- Found that `--watch -fincremental` installed a stale beni. The build runner keeps one
  compiler process per artifact and sends it only "update", so a generated module root
  that moves to a new `o/<hash>/` path keeps the first build's file. The binary kept the
  old build id, checked core, embedded core and platforms.
- Added `-Dstable-generated` to `build.zig`. It copies those generated files to
  `.zig-cache/stable/<key>/`, a path that does not depend on their content. Each edit kind
  (`src/`, `core/`, `platforms/`) then gave the same build id and embedded core as a clean
  build, in about 4–8 s. `fast-compiler.md` §8 records it. CLAUDE.md tells agents to
  use the watcher, and never to run `zig` on AArch64 (the owner: it runs the machine out
  of memory).
- Had a Sonnet agent follow only the CLAUDE.md text with throwaway edits. Five of five
  binaries were correct. Its feedback went into the text: a start/stop recipe by process
  group (`pkill -f` killed its shell), how to tell the watcher is quiet, and that a
  failed build keeps the old binary.
- Gates green with `zorg build gates` (181 s). Pushed to `master` on the owner's order.

**What I learned**

- After an edit, the remaining wait is mostly the "check core for a compiler" step,
  about 3 s on one thread. Perf puts about half of it in the serial ownership pass
  (`Session.zig`, `checkSerial`). A ReleaseFast maker would save only about 18%.
- The watcher sees the build's own copies as edits and runs one or two extra builds per
  edit. The fix belongs in Zorg's build runner: ignore files the build itself wrote.
