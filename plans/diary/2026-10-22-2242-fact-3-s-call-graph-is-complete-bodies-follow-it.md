## 2026-10-22 22:42 CEST — fact 3's call graph, argued complete, drives executability again

**What I did**

- Wrote the completeness argument for #685 in `backend.md` §9. It lists every way emitted JavaScript can run a beni function body and names the root or the edge that covers each one. Two classes stay conservatively rooted: a body with no fact-3 site, and every body when fact 3 did not reach its fixpoint.
- With the argument written, I took back #686's "every body is a root". A body runs again when an executable call reaches its site, and the roots are as before #686. A computed method's receiver now escapes as a named method's receiver does.
- Added `run/CallGraphComputedMethod` and `run/CallGraphComputedKey` to pin cases 2 and 3 under `--check-call-graph`. Recovered: 92 bytes in three programs. Cost: 0.3–0.5% instructions on the dashboards.

**What I learned**

- Both fixtures I wrote to find a hole passed before any fix. The array's elements sit in the site's `any`, which is a root, and a computed read is `readAll`, which is exact. The enumeration did not turn up a real hole on current master.
- Restoring graph-driven executability costs a little: the solve opens bodies one by one as calls reach them. So #686's rule bought speed as well as safety.
