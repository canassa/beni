## 2026-10-31 16:47 CET — own2 5d2: the counted calls

**What I did**
- Added the counted tests of S3b slice 5d2 (`ownership-v2.md` §8, #1421):
  - `wrap (wrap … r)`, same-module and imported, with an `ident` control, at 10 and 100 calls.
  - The `wrap2` twin under a kids writer.
  - #1146's X_k chain through `apply` and `kappaOf` (`Calls.zig`).
  - `rebuilt` at 65 and 130 fields.
  - R-7.4's Θ(NK) ring.
- Tightened the source-lanes test to G_f = 0.
- Filed four findings without pinning a ceiling for them: #1488, #1489, #1490, and the comment on #1289.

**What I learned**
- #1097's done condition already held on master. The push chain and `rebuilt` both spend 0 growth, so the lanes test was only stale.
- `Grafter.graft` was deleted on 2026-10-30 (779616128). The #1146 count was always on `linkArgs`, which `apply` still calls, so moving the count onto the view path meant calling `apply`.
- The `deep` read is where the X_k chain is quadratic, not the view. It is also quadratic on the raw `res`.
- A tree-insert chain is far worse than #1289 says:
  - Θ(n²) when read.
  - Exponential when published: 9.2 M records at 10 calls.
- A two-branch tree insert over lists does not check at all (#1489, likely #1372).
- The machine was at load 20–57. A K = 16 ring took 57 s, so the NK witness stays at k ≤ 3.
