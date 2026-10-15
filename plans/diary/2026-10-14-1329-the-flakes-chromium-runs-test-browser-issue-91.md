## 2026-10-14 13:29 CEST — the flake's Chromium runs test-browser (issue #91)

**What I did**

Found why `nix develop .#browser` Chromium did not start: nixpkgs' wrapper
puts the caller's `LD_LIBRARY_PATH` in front of its own libraries. A host
`libasound.so.2` built for glibc 2.43 then stops Chromium 153 (glibc 2.42)
before `main`. Reproduced it on a CachyOS host with only that library on
the path; the message is the one research 90 reports.

The browser shell's `chromium` is now a wrapper that unsets
`LD_LIBRARY_PATH` and `LD_PRELOAD`, then runs nixpkgs' Chromium. The new
flake check `checks.<system>.browser-chromium` puts an empty
`libasound.so.2` on the path and runs `chromium --version`. It fails on the
unwrapped Chromium (exit 127, "file too short") and passes on the wrapper.

`nix develop .#browser -c zig build test-browser`, with the host
`libasound` on `LD_LIBRARY_PATH`: 348 of 348 cases pass. `browser/tea/
BikeWars` got `_expected.chrome-expected` for the `#222` against
`rgb(34, 34, 34)` difference; `tests/corpus/README.md` lists it. CLAUDE.md
*Building* says how to run it.

**What I learned**

The flake's Chromium started on this host until a host library entered
`LD_LIBRARY_PATH`. The defect was the environment, not the pinned build.
The harness waits its full 30 s when Chrome exits at once; its log then
shows the cause. A check for an early exit is a possible follow-up.
