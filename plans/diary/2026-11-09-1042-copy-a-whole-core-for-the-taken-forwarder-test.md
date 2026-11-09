## 2026-11-09 10:42 CET — copy a whole core for the taken-forwarder test

**What I did.** The taken-forwarder test in `tests/blackbox/check_test.zig`
called `World.copyTreeInto("core", "core", "")`. The helper skips each name
that starts with the prefix, and every name starts with `""`, so it copied no
file. The test wrote only its edited `List.beni` and `Dict.beni` (#2316).
`copyTree` and `copyTreeInto` now take `?[]const u8`: `null` copies every
file, and an empty prefix is `error.EmptySkipPrefix`. The test passes `null`.
No other caller passed an empty prefix. To prove the test, I removed the
`taken` word from the BIR dump's `own2` row: the test failed with
`ForwarderMissed`. I restored it, and the gates passed.

**What I learned.** A "skip names with this prefix" argument has a value
that skips everything. Make "skip nothing" its own value (`null`), and
refuse the value that empties the tree.
