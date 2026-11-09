## 2026-11-09 05:50 CET — prune stale skill files before the install

**What I did**

- Reproduced #1987 on master: a stray file under `zig-out/share/beni/skills/beni/references/` made `zig build test-blackbox-skill` fail with `expected 32, found 33`.
- Added `tests/install_prune.zig`. A Run step runs it before `addInstallDirectory`. It deletes each entry of `<prefix>/share/beni/skills/` that `skills/` does not have, or has with a different kind.
- After the fix, the same run with a stray file and a stray folder passed, and both were gone. `zig build install --prefix <p>` pruned only `<p>/share/beni/skills/`; a file beside it stayed.
- `frontend.md` §12.2 says that the install deletes stale entries.

**What I learned**

- Zig 0.17 has no custom build steps with a make function. The configure phase does not know the install prefix either. `b.graph.path(.install_prefix, sub)` gives a lazy path that a Run step resolves at make time, so a small tool is the way to act on the prefix.
- `addInstallDirectory` walks only the source. It never sees an installed file that the source lacks.
