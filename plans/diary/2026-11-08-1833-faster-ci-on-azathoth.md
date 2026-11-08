## 2026-11-08 18:33 CET — faster CI on azathoth

**What I did**

- Measured the first azathoth run (four runners at 800%): ~25 min against
  GitHub's 16–20, and `generated_wall_ms` (2 s wall bound) failed under CPU
  starvation. Opened #2272, the owner's decision; the test is unchanged.
- Infra (`4e26760`, `408a64b`, deployed with a rollback guard): the runner
  slice at 1000%, nix-daemon inside it, three runners, host caches for Zig and
  run hashes in `/var/cache/beni-ci` written only by a master run of ci.yml
  that proves itself with GitHub's OIDC token, GC roots for the dev shells,
  and the token-file race fixed (PathChanged, ConditionFileNotEmpty, retry).
- Workflows: `.github/ci-cache.sh` replaces actions/cache for the Zig and
  run-hash caches.
- Measured `#2264`: cold after the change 18.8 min, warm with three runners
  13.4 and a repeat, warm with two runners 15.0. Lean (13 min, one CPU)
  is the critical path whenever it runs.

**What I learned**

- `lean` runs on one CPU for ~13 min: more CPU does not shorten it, only
  starting it at once does. That is why three runners beat two.
- On ZFS 2.4 with block cloning, restoring a 3.5 GB Zig cache is a reflink copy
  that takes under a second.
- With four jobs at 800% each job got ~2 CPUs; the wall-clock assertion in the
  gates is the first thing that breaks under that.
