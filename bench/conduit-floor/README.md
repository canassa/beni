# Conduit byte references

Research 101's local production builds. No compiler, runtime or application
source in beni changes. Work goes in `zig-out/conduit-floor/`; nothing runs on
azathoth. The sources, exact revisions and every adjustment are in
[`references.json`](references.json). The reference implementations' licenses
apply to their archived generated code and source maps.

With Node 24.19.0 / npm 11.17.0 and the repo's `zorg` shell:

```sh
zorg build test test-blackbox fmt-check beni-fmt-check
node bench/conduit-floor/build.mjs
node bench/conduit-floor/measure.mjs
node bench/conduit-floor/probe.mjs
CHROME='/path/to/chrome' node bench/conduit-floor/smoke.mjs
```

Install the existing analysis dependencies with `npm ci` in
`bench/ui/apps/solid1` if absent. `build.mjs` installs the references from the
committed lockfiles, restores only the listed reference files, and invokes
their production scripts. It also builds the explicitly adjusted variants.
It can overwrite edits **inside those disposable reference checkouts**.
`BENI` overrides `zig-out/safe/bin/beni` for `measure.mjs`.

Solid uses its upstream npm lock with line endings normalized to LF; dependency
entries are unchanged. Vanilla's upstream `yarn.lock` is
retained, but the measured build uses the committed npm lock: npm resolves the
upstream ranges, and a Git dependency is fetched as an archive of the exact
commit in upstream's yarn lock. This avoids the obsolete `git://` transport
and npm preparing that Git dependency's development tree. No dependency source
is patched. `--ignore-scripts` avoids dependency install scripts. Webpack 4
needs `NODE_OPTIONS=--openssl-legacy-provider` on Node 24; the script supplies it.

Results:

- `manifest.json`: compiler/reference pins, Node, file lists.
- `sizes.json`: exact file hashes, raw/gzip/brotli, source provenance and ordered
  runtime/Markdown/application accounting. Runtime includes beni core/platforms
  or external JS dependencies, Babel helpers and webpack bootstrap. Application
  includes app-owned routing/helpers, emitted DOM functions, startup and residual
  unmapped/stub bytes. Attribution variants are syntax checked, **not runnable**.
- `excerpts.json`: readable versions of actual emitted snippets; not measured
  pretty-printed output.
- `probes.json`: **nonexecutable**, independent deletion probes. Their deltas
  cannot be added or claimed as available savings.
- `smoke.json`: local Chrome, mocked API, home/article/editor startup plus a
  favorite click. This is a limited source-audit check, not feature conformance.
- `validation.json`: local constituent-check verdict and limitations.
- `*.gz`: lossless storage of each measured JS response/map and deletion probe.
  Gzip envelopes are storage, not the brotli result.

To reprice frozen archives without rebuilding the compilers/references:

```sh
node bench/conduit-floor/measure.mjs --archive
```

Every JS response is compressed independently (brotli quality 11 with input
size hint; gzip 9), then summed over **all routes**, including lazy chunks once.
HTML, CSS, fonts, images, maps and unloaded plans are excluded. The additional
concatenated result is a compression-context diagnostic, not a transfer total.
Solid's explicit single-chunk variant uses Rollup's `--inlineDynamicImports`;
it is not obtained by pretending concatenated chunks form a valid bundle.
