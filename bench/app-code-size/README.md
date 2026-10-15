# Conduit's own code, construct by construct

Research 104's measurements: why Conduit's application code (not core, not
the platform runtime, not the schemas) is larger in beni's two browser
platforms than in the Solid reference, and what Solid-like encodings would
weigh. No compiler, core, platform or application source changes. Nothing
here runs on azathoth; heavy steps were pinned with `taskset -c 8-23`.

Every size is the research 97/99/101/102 protocol: the one `_main.mjs`
response, Node zlib brotli quality 11 with the size hint. The Solid
reference is research 101's adjusted single-chunk RealWorld build, read from
`bench/conduit-floor/results/`.

```sh
npm ci --prefix bench/output-size                 # acorn, terser, trace-mapping (research 102's lock)
zig build -Doptimize=ReleaseFast                  # or BENI=<a beni>
node bench/app-code-size/build.mjs                # build + archive tea/direct, plain and mapped (zig-out/output-size/)
node bench/app-code-size/account.mjs              # every byte of views and logic by construct, alone and ordered
node bench/app-code-size/solid.mjs [dir --show]   # the same account for the Solid reference
node bench/app-code-size/views.mjs                # four views side by side, alone, and pretty excerpts
node bench/app-code-size/names.mjs                # identifiers by kind, alone (beni and Solid)
node bench/app-code-size/terser.mjs               # each area before and after Terser
node bench/app-code-size/logic-units.mjs          # update/init/requests declaration by declaration
node bench/app-code-size/proto-preview.mjs        # one view rewritten by hand (feed preview, tea)
node bench/app-code-size/prototypes.mjs           # the uniform executable rewrites, alone and stacked, verified
node bench/app-code-size/show.mjs tea '^p272$'    # a unit with its bytes bracketed by construct, to check the painter
node bench/app-code-size/alone.mjs <bundle> name… # what deleting some declarations alone costs
```

`classify.mjs` paints each byte of the two areas with a construct: the
innermost AST node a rule claims, names resolved with scope (a local `m` is
not core/Task's top-level `m`). The areas are research 102's: *views* are the
generated markup units (`tN`, `kN`, `pN`, `bN`, `dg`/`dp`/`dr`) and direct's
`main`; *logic* is the rest of the app outside the schemas (update/init, view
functions, requests, routes, helpers). `account.mjs` then deletes each
construct's bytes, alone and cumulatively in table order, and recompresses:
the ordered rows of an area add up exactly to the area's cost (the response
minus the response without the area's bytes). Deleted variants are not
JavaScript; they locate a cost and are never run.

The `proto-*.mjs` rewrites are executable. `prototypes.mjs` runs each over
the tea bundle alone and stacked (guards → closures → static → live), plus
the padding and dead-store probes, and runs Conduit's three corpus scripts
(`bench/output-size/verify.mjs`: Editor, Reader, Tour under happy-dom through
the gates' driver); a rewrite counts only when every transcript equals the
corpus golden and the unchanged bundle's. Tea rewrites also run
`feed-favorite.steps` (`verify-favorite.mjs`): favourite and unfavourite from
the feed list, which no corpus script clicks, against the unchanged bundle.

Results (`results/`):

- `manifest.json`: commit, compiler hash, bundle hashes and sizes.
- `beni-{tea,direct}.mjs(.map).gz`: the measured bundles and release maps.
- `account.json`, `solid-account.json`: the construct tables.
- `views.json`, `excerpts/*.js`: the four views, alone, and their code.
- `names.json`, `terser.json` (+ `terser-*.mjs.gz`), `logic-units.json`.
- `proto-preview.json` (+ `.mjs.gz`), `prototypes.json`, `proto-stack-tea.mjs.gz`.
