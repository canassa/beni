## 2026-10-15 16:40 CEST — Research 102: where beni's output bytes go

**What I did**

- Wrote research 102 (`docs/design/research/102-beni-output-size.md`) and
  `bench/output-size/`. I priced Conduit's `--release` bundles on master
  (tea 31,745 B, direct 38,243 B brotli) against Terser and esbuild. I
  attributed every byte by origin with the release source maps, using research
  99's alone and ordered accounts. App code is split by kind from the original
  names in the map. I priced the guarantees and compared each job with the
  Solid single-chunk reference of research 101.
- Built executable prototypes. Each one runs `ConduitEditor`, `ConduitReader`
  and `ConduitTour` through the gates' driver and matches the golden and the
  unchanged bundle. Request bodies through compiled `print` save 2,223 /
  2,188 B. Top-level single-use inlining saves 180 / 1,577 B. Shared schema
  field readers save 972 / 799 B. `&&true` saves 138 / 31 B and quotes save
  123 / −18 B.

**What I learned**

- Minification is not the gap. Terser saves 1,298 B (tea) and 2,947 B
  (direct), 7% and 12% of the distance to Solid. Direct's share is almost
  all one missing transform: 511 top-level bindings that are read once.
- The largest avoidable cost is `Http.jsonBody` taking a `Schema` value.
  That ships the whole library interpreter even though every declared schema
  has a compiled `print`.
- Beni's UI runtime is Solid's size (5.5 kB against 5.4 kB alone). The rest
  is guarantees (about 6 kB), TEA's patch functions (3.9 kB) and richer
  libraries. Row reconciliation alone is bigger than all of Solid's `web.js`.
- `tests/browser/driver.mjs` can be pointed at a hand-edited bundle directly
  (direct needs `--no-comments`). That makes bundle-edit prototypes cheap to
  check for behaviour.
