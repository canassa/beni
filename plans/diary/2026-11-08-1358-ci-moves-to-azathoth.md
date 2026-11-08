## 2026-11-08 13:58 CET — CI moves to azathoth

**What I did**

- Built and deployed (infra `baada25`, owner-authorised) four ephemeral
  GitHub Actions runners on azathoth: one slice (CPUQuota 800%, CPUWeight 20,
  MemoryHigh 12G, MemoryMax 14G, no swap), nix-daemon bounded (4 CPUs, 4G,
  max-jobs 2, cores 4), an nftables table that rejects the runners' and
  nixbld's traffic to the host's ports and private ranges (DNS and loopback
  ephemeral ports allowed), nix-ld, ARC cap 16 → 8 GiB. The runners wait for
  their PAT in `/var/lib/secrets/github-runner-beni.token`.
- Moved every job of the four workflows to `[self-hosted, azathoth]`: no Nix
  installer, no Nix store cache, no `sudo sysctl` for Chromium, cache keys
  `-azathoth-`, the Claude workflows only for OWNER/MEMBER/COLLABORATOR (#2263).
- Fixed #2086/#2053: the harness gives an emitted program a `PATH` of the dev
  shell's `sh` and `sleep` directories (`World.program_path`).

**What I learned**

- With no `PATH`, NixOS's `/bin/sh` searches `/no-such-path`. Besides the two
  red fixtures, `ChildProcessKillAfter`, `ChildProcessShutdown` and
  `ChildProcessCancelledLatched` passed on NixOS while their `exec sleep 1000`
  failed at once, so they did not test what they say there.
- The run-hash digest must not cover the `PATH`: `run_hash_test` runs a
  verified program again with no Node on `PATH` and expects the same digest.
- The github-runner module's default work directory is under `/run`, a tmpfs;
  a job's Zig caches belong on disk.
- Chromium's sandbox runs under the runner's unit once `RestrictNamespaces` is
  off and the filter keeps `chroot` and `capset` (checked on azathoth).
- `zig build test-playground` peaks at 3.7 GiB, cold, 282 s on dagon.
