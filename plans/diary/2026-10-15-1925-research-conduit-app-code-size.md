## 2026-10-15 19:25 CEST — Research 104: why Conduit's own code is big

**What I did**

Wrote research 104 (`docs/design/research/104-conduit-app-code-size.md`) and
`bench/app-code-size/`. Built Conduit `--release` on master `6508aeb3f` (tea
31,609 B, direct 38,175 B) and painted every byte of the app's views and
update/init/requests with the construct that emitted it, then priced each
construct alone and in order by deleting its bytes; did the same for Solid's
adjusted RealWorld. Put four views side by side (preview, comment row, editor,
nav link) in source, tea, direct and Solid. Ran five executable rewrites of the
shipped bundles through Conduit's three corpus scripts: one test per hole
(−208), closures instead of instance records (−210), shared static kinds
(−16), static liveness (−254), stacked −861 B on tea; constructor padding
(−97 tea, −35 direct) and direct's unread kept-value stores (−106) as probes.
A hand-written Solid-style feed preview made the bundle 165 B larger.

**What I learned**

Without schemas the app costs 12.4 kB (tea) and 17.5 kB (direct) against
Solid's 6.9 kB. Tea's view gap (2.8 kB) is re-render bookkeeping (+1.8 kB) and
kind scaffolding (+1.2 kB); HTML, walks, writes, events and component calls are
at par. Direct adds 5.3 kB of parameterised-template protocol, which is all of
its excess over tea. The update gap is TEA's plumbing and features; Terser
takes only 4–5% of it. Brotli prices difference, not volume: shared shapes are
nearly free, per-site names and field codes are not, so a one-view redesign
always looks like a loss and must be priced across every view. Direct's
handlers have become tea's tag dispatch plus a mask-key lookup in Conduit.
