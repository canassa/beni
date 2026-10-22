## 2026-10-22 22:19 CEST — a corpus-wide check of fact 3's call graph

**What I did**

- Built `--check-call-graph` (#685, step a). This hidden, test-only flag recomputes fact 3's call-graph reachability after every solve, with the roots executability had before #686. It then rewrites every function body that some solve left unreached as a `throw`. The corpus's release passes (`run/`, `--schema-library`, the `browser/` pages and the value-fuzz pages) build with it.
- On master the corpus is green with the check on, so it finds no body that is called but missed. When I forced every body to count as unreached, `run/Closures` and `browser/Button` failed with the thrown message, which shows the check is wired up.

**What I learned**

- The first oracle run looked like two holes, `ReleaseImplicitKeys` and `HttpServerBadClients`. Both were roots my oracle had left out: functions held under an implicit host key, and functions held in a site's `any`. A check like this needs every root the analysis uses, or its findings are noise.
- #685's original evidence, TaskRootScope's bracket use function, no longer reproduces. `stack.pop()` reads a method off an array, which escapes the array, and with it the frames the array holds.
