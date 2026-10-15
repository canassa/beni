## 2026-09-28 20:58 CEST — coverage from LLVM block guards, without kcov

**What I did**
- Replaced kcov in `zig build coverage` with SanitizerCoverage
  `trace-pc-guard`. The instrumented LLVM ReleaseSafe beni's root is
  `tests/coverage/runtime.zig`: the module constructor maps one shared
  hits file (a process count, then a byte per guard) and the callback
  writes a guard's byte the first time its block runs, so a process that
  panics or is killed keeps its hits (checked with SIGSEGV and SIGKILL
  mid-run: each kept 1 800 to 2 800 guards). A one-line C file defines
  `__sancov_lowest_stack`.
- Wrote the report in Zig: `tests/coverage/x86.zig` (a length and
  control-flow decoder, whose instruction boundaries matched objdump on
  all 1 588 005 instructions of the binary's `.text`),
  `tests/coverage/cfg.zig` (per-function graphs, jump tables, calls of
  functions that cannot return, dominator and post-dominator inference)
  and `tests/coverage.zig` (ELF symbols and sections, DWARF rows through
  `std.debug.Dwarf`, `summary.md` and `lcov.info`). Dropped the wrapper,
  kcov from the flake (lcov, for `genhtml`, instead) and
  `BENI_TIMEOUT_SCALE`.
- Full run on today's master: 3.6 s wall, 68 CPU-s, 2 557 processes,
  92.0% of 22 965 lines (kcov took 12 minutes and 9 100 CPU-s).

**What I learned**
- kcov on the same instrumented binary and the same 502 processes agreed
  on 99.45% of 22 773 lines: 115 lines ran that the rules could not prove,
  10 the other way, which were rows without a statement marker or sharing
  an address with another line's.
- Two things the first graphs got wrong. A call of a panic handler falls
  through, in the machine code, into the next block, and that invented
  edge hid dominators: the tokenizer read 72.9% until a call of a function
  with no return path ended its block. And a labelled switch dispatches
  through `jmp [table + reg]` with an index already scaled, not only
  `[table + index*8]`.
- The DWARF line table names a few lines past the end of their file;
  `genhtml` refuses those, so the report drops them.
