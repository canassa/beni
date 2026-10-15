# Conduit output size

Research 102's measurements: where the bytes of Conduit's `--release` bundle
come from, what Terser would still take out, and executable prototypes of the
savings. No compiler, core, platform or application source changes; the
prototypes are hand edits of a built bundle or of a copy of the application
under `zig-out/`. Nothing here runs on azathoth.

Every size is the research 97/99/101 protocol: the one `_main.mjs` response,
Node zlib brotli quality 11 with the input-size hint (gzip 9 alongside).

```sh
npm ci --prefix bench/output-size            # terser 5.51.2, esbuild 0.28.2, acorn, trace-mapping
zig build -Doptimize=ReleaseFast             # or BENI=<a beni> for build.mjs/proto.mjs
node bench/output-size/build.mjs             # build + archive tea/direct, plain and mapped
node bench/output-size/minify.mjs zig-out/output-size/tea.mjs zig-out/output-size/direct.mjs
node bench/output-size/ablate.mjs zig-out/output-size/tea.mjs zig-out/output-size/direct.mjs
node bench/output-size/attribute.mjs         # every byte by origin, alone and ordered
node bench/output-size/markup.mjs            # markup by generated kind; HTML strings vs Solid
node bench/output-size/solid.mjs             # the Solid single-chunk reference, same method
NOTE=… node bench/output-size/proto.mjs jsonbody zig-out/proto/jsonbody/src   # see results/jsonbody.patch
node bench/output-size/price.mjs             # guarantee and component groups, alone
node bench/output-size/edits.mjs             # bundle-edit prototypes, priced and run
node bench/output-size/verify.mjs <tea|direct> <bundle.mjs> [label]
```

(`minify.json` and `ablate.json` were written with `OUT=bench/output-size/results/…`.)

`verify.mjs` runs Conduit's three corpus scripts (`ConduitEditor`,
`ConduitReader`, `ConduitTour`) against a bundle under happy-dom, through the
gates' own `tests/browser/driver.mjs` (direct with `--no-comments`, as the
corpus walker runs it), and requires the transcript to equal both the corpus
golden and the unchanged bundle's transcript. The transcripts include every
request's method, URL, headers and body.

Results:

- `manifest.json`: commit, compiler hash, the two baselines' hashes and sizes.
- `beni-{tea,direct}.mjs(.map).gz`: the measured bundles and release maps.
- `minify.json`, `ablate.json`: Terser and esbuild variants; Terser compress
  options left out one at a time and switched on one at a time.
- `terser-dropped-*.json`: top-level bindings Terser removes, by source.
- `attribution.json`: units, raw bytes, alone and ordered brotli per group;
  per-app-module alone; `attribution-*-residual.mjs.gz` is the fully stubbed file.
- `markup.json`, `solid.json`, `price.json`: the finer tables.
- `prototypes.json`, `proto-jsonbody-*.mjs(.map).gz`, `jsonbody.patch`: the
  source-level prototype (request bodies through each schema's compiled print).
- `edits.json`: bundle-edit prototypes (including `jsontyped`, the source prototype
  with `Http.jsonBody`'s typed `Unprintable` error put back), savings and corpus verdicts.

Stubbed attribution variants are syntax checked and never run: they locate a
cost in context, not an available saving, and alone deltas do not add up.
