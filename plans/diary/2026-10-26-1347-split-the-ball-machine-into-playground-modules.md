## 2026-10-26 13:47 CET — Split the ball machine into playground modules

**What I did**

Implemented #1083: the ball machine is a nine-module browser fixture, copied into the
playground once. Its 49-line `Control.beni` opens first and shows the four control
fibers, manual semaphore acquisition/release, timed batches and exponential retries.
Sensors, gates, the bucket, trapdoor, simulation, SVG view and page wiring are separate.
The existing capacity and batch controls remain connected to the running machine.

Added editable source tabs, per-file diagnostics and navigation, complete project
compilation/dumps, and project sharing that retains every module and the selected file.
Single-file links retain their format. Added Chrome checks for imported-module edits,
undo across tab switches, diagnostics, dumps, sharing and switching back to a single-file
sample. The full playground Chrome script passed with zero failures. The existing ball
machine transcript is unchanged; refreshed its development, release and fuzz run hashes.

Implemented prerequisite #1084: `dump --stage=types` accepts a directory and prints project
modules in path order. Its black-box regression failed before the fix and passed after it.
Updated the design and the installed skill's CLI reference. The WebAssembly/native parity
suite now includes the ball project and its Types and Ownership dumps.

**What I learned**

The CLI loads only paths explicitly given to it; an imported module is not discovered from
`Main.beni` alone. The worker must hand it the whole project. Ownership already accepted
directories, while Types needed a directory writer. CodeMirror renders only a viewport of a
file, so browser assertions about the controller use the visible scope and four spawns.
On macOS Chrome, editor select-all and end-of-document need the macOS modifier keys.

Used Zorg throughout on this AArch64 Mac. Its incremental Mach-O linker panicked with
`TODO(MachO2): load archive` during the watcher's first build; the watcher exited and all
successful builds used one-shot Zorg commands.

The full `zorg build gates -j2` completed with 1697/1718 tests passing,
16 skipped and five failing test groups. Two failures are the existing APFS
case-folding tests (#90); ownership has four golden mismatches already present in
the pre-change ReleaseSafe binary (#1085); the other two groups encountered removed
`direct/` fixtures retained by ignored cache files. Moved those cache-only directories
to `/tmp/beni-playground-stale-corpus/` without deleting them. The feature checks,
format checks and updated ball transcript pass. No goldens were changed to hide
these failures. Kept the implementation uncommitted because the repository requires
green gates before committing or opening a pull request.

`zorg build test-blackbox-corpus -Dllvm -Dcorpus=ownership/core/CastAcross -j2`
passes the unchanged golden, narrowing #1085 to the native backend/optimization path.

The focused `test-playground -Dllvm -Dtest-filter="ball machine project"`
passes: native and shipped WebAssembly agree on development, mapped and release
builds and on the complete project's Types and Ownership dumps, all exiting zero.
The original parity shard containing the project also completed successfully.
Opened the refactored project locally with `Control.beni` selected.
