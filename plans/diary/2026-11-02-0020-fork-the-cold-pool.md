## 2026-11-02 00:20 CET — fork the cold pool

**What I did**

- Wrote §4.4's *The fork of a cold pool* (#1623, point 1): what is forked and when, why a fork is
  a rebuild, ids, why the copy is not charged, and the safety builds' sample check.
- Built it. `src/own2/Fork.zig` is a deep copy and a deep comparison, generic over the tables'
  types; a pointer field that `Groups.forkPolicy` does not name is a compile error. `Groups`
  plans the dump's cold runs, saves a pool at each callee prefix a later fresh cold run shares,
  and forks the longest saved prefix instead of walking it again. A check saves nothing.
- Evidence: 3 972 cases byte-identical to master (accounts included): every ownership fixture,
  single-file, multi-module and `core/`, with and without `--ownership-rewalk-check`, at
  `--jobs=1` and `--jobs=4`; `check --ownership-everywhere`; all of `run/` with
  `--ownership-everywhere`; core itself. A planted fork defect (one memo dropped) panics in the
  safety check.
- FoldCertificate's flagged dump: 27.33G → 17.10G instructions.

**What I learned**

- Master's cold pool is already history dependent: a run that continues the previous pool walks
  its missing callees after the previous root, not in group order. The fork keeps that path as it
  is and replaces only the fresh rebuilds, whose state is a pure function of the walk sequence.
- Between two solves `Module.account` can point into a `results` buffer that has moved (a copied
  callee group appends and walks nothing). Nothing reads it before the next `charging`.
- The Nix store's `perf` was garbage-collected mid-session; a `nix build -o` root keeps it.
