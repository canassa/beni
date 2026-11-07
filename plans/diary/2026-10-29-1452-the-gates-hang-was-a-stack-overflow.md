## 2026-10-29 14:52 CET — the gates hang was a stack overflow in the printer's depth test

**What I did.** `zig build gates -j4` on #1127's tree hung twice: the log stopped two
minutes in, the scope burned 14 minutes of CPU and then nothing, and `timeout` killed it
at 5 400 s and at 1 500 s. A third run was sampled every 30 s (`ps --forest`, `pstree`,
`memory.current`, `memory.swap.current`, `memory.events`) and, at the first idle minute,
every stalled leaf got a `gdb -batch -p <pid> -ex 'thread apply all bt'` through `sudo`
(yama's `ptrace_scope` is 1). The leaf was `unit_test`, test 275, `js.Print.test "a chain
deeper than the recursive printer survives…"`: its `small_stack` thread took a SEGV, and
Zig's segfault handler sat forever in `SelfInfo.Elf.findModule` on the `self_info`
lock while the hang guard waited in `debug.print` on the stderr mutex the handler holds.
Run directly, the binary segfaults at that test with any seed. Under gdb the overflowing
stack is the printer's own recursion, `rawRecursive` → `expression` → `raw`, with
`testing.allocator`'s DWARF stack-trace capture at the bottom. Debug frames: 3 664 B,
240 B, 144 B, about 3.9 KB a level; at `recursion_limit` 256 the levels alone took
about 1 000 KB of the 1 024 KB small stack. The fix of item 6's second review made
`rawRecursive` 32 B larger (3 632 → 3 664), and 256 × 32 B = 8 KB was the margin.
Lowered `recursion_limit` to 128 (half the small stack), with the frames in its doc
comment, and corrected `deep_chain`'s comment, which promised a third of the stack to
spare. Opened the harness issue: a SEGV on a test thread deadlocks the test process, so
a stack overflow hangs the gates to the timeout instead of failing them; the missing
margin test is in the same issue.

**What I learned.** A gate that stops writing and stops using CPU is a deadlock, not a
slow test: sample the scope's `cpu.stat` and `memory.events` to tell the two apart, and
take the backtraces before stopping it, because the stalled state is the evidence and it
does not survive the stop. The build runner prints nothing for a test process that never
answers, and the per-test hang guard is only as good as its way out: `std.debug.print`
takes the stderr lock, which a segfault handler on another thread can hold forever. A
recursion limit set by hand against a measured stack keeps no margin by itself: the
frames grow with every edit of the function, so the limit must leave room, and the
number and the frames it rests on belong in the comment next to it.
