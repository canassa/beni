## 2026-10-31 07:14 CET — The doc-example gate's "failed command" (#1400)

**What I did.** Reproduced `zig build test-blackbox-docs` on `origin/master`: it
prints the skip list, `doc-example gate: OK`, then `failed command: …`, and
exits 0 (`1/1 tests passed`). `zig build gates` exits 0 as well. Nothing
failed. Zig's build runner echoes the stderr of any step that wrote to it,
passing or not, and follows it with `failed command: …`. `docs_test` wrote its
informational report with `std.debug.print`. The test now keeps the report in
a buffer and prints it only when the gate fails (`errdefer`). The gate's
checks are unchanged. Gates are green with no `failed command` line left.

**What I learned.** The `--listen` protocol, the 1 s budget and stray files
were not involved. Agents who saw a non-zero exit were most likely reading the
echo, or a pipe's status (`| tail`). The note in `docs_test.zig` already said
the exit code decides, but the echo still looks like a failure. A passing test
should write nothing to stderr.
