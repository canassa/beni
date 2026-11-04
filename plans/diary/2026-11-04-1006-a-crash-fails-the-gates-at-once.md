## 2026-11-04 10:06 CET — a crash fails the gates at once, and the printer keeps half the small stack

**What I did**

- #1171. The fix of its item 1 was on master already (#1197): the runner's own crash handler
  writes `FAIL: test crashed (<signal>): <test>` with `write(2)` and exits. I added three probes
  that no test held: a thread that overflows while it holds std's debug-info lock (the deadlock
  of #1171), and a crash and an overflow on the main thread.
- I proved the old state with scratch copies of the runner: std's handler, and a hang guard that
  prints through `std.debug.print`. The lock probes hung past the 120 s guard with no line, and a
  scratch test under `zig build test` hung until `timeout` killed it at 200 s. With the branch,
  each probe fails in 2–53 ms, and `zig build test` names the test in 8 s.
- Item 2: `small_stack.mark()` notes a frame in a test binary, and `small_stack.deepest()` gives
  the bytes from the thread's first frame. `Printer.run` calls `mark` where the recursion stops.
  The new margin test failed on master: 128 levels used 50.5 % of the small stack.
  `recursion_limit` is now 112 (44.5 %), the owner's decision of 2026-11-04. The test measures
  from the thread's first frame, so the 25 KB of entry frames count.
- #1843 holds the same hazard in `Opt.mayWriteIn` and `Opt.height`.

**What I learned**

- std gives every thread a 256 KiB alternate signal stack, also when std's segfault handler is
  off (`std.options.signal_stack_size`). That is why the runner's handler can report an overflow.
- The build runner names the running test when a test process dies in server mode, and it
  continues with the next test.
- A printer level is two frames, not three: `expression` (or `raw`) and `rawRecursive`, 3 936 B
  in the self-hosted Debug build. LLVM's frames are 24 % smaller, so a stack margin depends on
  the code generator, and the gates' self-hosted build is the tight one.
- `-Dllvm` does not change the unit test binary. It changes only the compilers that the
  black-box tests run.
