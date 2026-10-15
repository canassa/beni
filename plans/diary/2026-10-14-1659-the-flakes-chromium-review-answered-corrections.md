## 2026-10-14 16:59 CEST — the flake's Chromium: review answered, corrections

**What I did**

Answered the review of PR #96. The wrapper now unsets only
`LD_LIBRARY_PATH`. The check `checks.<system>.browser-chromium` now
runs the `chromium` that `devShells.<system>.browser` puts on `PATH`.
With plain `pkgs.chromium` in the shell, the check fails ("file too
short"). With the wrapper, it passes. The CLAUDE.md text is narrower
and in STE. On the branch, with the host `libasound` on
`LD_LIBRARY_PATH`, `test-browser` passes.

A local merge of current master (`b03a8d369`) fails the gates on this
host. `browser/direct/HttpJson` and `HttpJsonBody` use 4 799 M and
4 941 M instructions of the 4 300 M budget. Their run hashes are
current, so the cost is the compiler's builds. The merge changes no
file that they read, so the branch stays on its last green base and
the merge is not pushed.

`test-browser` on that local merge, with the host `libasound` on
`LD_LIBRARY_PATH`: 476 of 478 cases pass, `BikeWars` included. Two
pages from master's direct browser effects work fail in Chrome, also
without `LD_LIBRARY_PATH`: `browser/direct/NavigateCommands` and
`Router`, `[value fuzz]`, because `__beniFuzzMounts` is undefined in
the page. This PR does not change them.

A project collaborator accepted the flake check as an exception to
rule 3: the corpus drives only the `beni` binary and cannot see the
dev shell. A person still runs `test-browser` once on the NixOS host
where the failure happened, before the merge.

**Corrections to the 13:29 entry**

- "the message is the one research 90 reports" is wrong. Research 90
  says only "a glibc mismatch in `libasound`", and no report has the
  error text. The owner's cause is in the repository:
  `bench/ui/results/2026-10-08-scaling.md:275`,
  `docs/design/research/67-direct-platform-s2.md:246` and
  `plans/diary.md:4147`. The login environment points
  `LD_LIBRARY_PATH` at an `alsa-lib` for a newer glibc.
- "unsets `LD_LIBRARY_PATH` and `LD_PRELOAD`" no longer holds. The
  dynamic linker applies `LD_PRELOAD` to the wrapper's own bash before
  `unset` runs. That half did not do what the text said, and no test
  covered it, so it is removed.
- The wrapper keeps out a host library directory only if the directory
  holds no glibc library. A directory with `libc.so.6` stops the
  wrapper's bash and `node` before Chromium.
- On this host the flake's Chromium started before the change. Here,
  only the `BikeWars` golden changed the result. The flake change was
  checked against a simulated cause.
- The first gates run was before the diary entry, not on the committed
  tree. The docs test reads only `core/`, so the result is the same.

**What I learned**

Search the repository for the cause before calling it unknown: three
lines already named it. A check must use the thing it names, here the
shell, or a revert passes it.
