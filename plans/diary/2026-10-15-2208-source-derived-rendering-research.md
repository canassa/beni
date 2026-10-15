## 2026-10-15 22:08 CEST — Source-derived rendering research

**What I did**

Replaced the shallow research 105 comparison for #172 with research 106 and
`bench/rendering-design/`: ten distinct UI shapes, 198 seeded apps, 396 real
tea/direct builds, BIR-derived dependencies and ownership witnesses, four
experimental directions, independent vanilla and two actual Solid ports.
Measured 1,422 growth bundles and fitted family slopes; ran 1,422 minified
validation pages, 22 lifetime probes and 16 large-list correctness pages.
Ran 828 real-click measurements on quiet pinned azathoth, with raw traces,
IQRs, source/bundle identities and standalone graphs. Preserved actual Solid,
Vue Vapor and Marko compiler output. Updated the existing PR #180 branch.

No repository gates or suites ran. An ordinary compiler build on the Mac was
killed in build_id; the retained real compiler builds used a fresh ReleaseFast
compiler in an isolated azathoth worktree. Other worktrees were left alone.
The earlier large synthetic sweep was stopped and excluded from this replacement.

**What I learned**

Local reducers were smallest among the compiled candidates: mixed N32 7.29 kB
brotli against TEA 11.82, direct 17.06 and vanilla 3.89. More static wiring did
not win bytes. The catalogue's finite factory set bends the growth curve, so
report upper-range slopes and do not extrapolate to a 500 kB real application.
Local routing still misses vanilla's single-row edit time: model traversal
remains. Solid's actual reconciler makes 10k reversal much faster than today's
runtime. The larger oracle exposed and corrected my early node-placement and
Solid API mistakes before final measurements. Direct's nested-helper defect
fails 28 generated pages (#189); it is retained visibly, not worked around.
