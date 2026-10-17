## 2026-10-17 21:43 UTC — a scenario run hash ignores the build cache

**What I did**

Fixed #330. The run hash of a black-box scenario whose script sits in the
project directory (`check.mjs` in the `core/Schema` `--library` scenario, the
only one) took `dirname` of that path, got nothing, and walked `.`. That walk
includes `.beni-cache`, whose entries name the compiler, so any change under
`src/` staled the line in `tests/blackbox/run-hashes.txt` even when the
emitted JavaScript was the same. A script inside an output directory still
hashes that directory, byte for byte as before. A script in the project
directory now hashes its own bytes and every directory whose `_manifest.txt`
starts with `beni-manifest 1`, and nothing else. The domain string is
unchanged, so every other scenario line stays. Re-recorded the one line on
top of #329 (merged while this was in progress); the digest did not move
when the compiler was rebuilt from that merge, which is the defect being
gone. A test writes into `.beni-cache` and edits an unbuilt source and
requires the digest to stay, and requires the expectation, the emitted
bytes and the script to move it. A directory the walk cannot open fails
the digest instead of being skipped, and a beni manifest at the project
root is refused: no scenario builds with `--out=.`.

`zig build gates` refuses here (`perf_event_open: NOENT`).
`zig build test test-blackbox fmt-check beni-fmt-check` exited 0.

**What I learned**

`dirname` of a bare file name is null, and the old `orelse "."` is what
pulled the project into the digest. Skipping `.beni-cache` alone would
still hash the sources. The manifest header is how an output tree is told
from the rest of the project without the scenario naming `--out`. Zig's
default build summary prints nothing when every step succeeded, and a step
that wrote to stderr on the way to succeeding still gets a `failed command`
line; the exit code is the verdict.
