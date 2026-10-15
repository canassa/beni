## 2026-10-02 10:59 CEST — Routing, HTTP v2, teardown, Unicode, and core leaving JavaScript

**What I did** (as manager; Opus agents in worktrees implemented every slice)
- Landed HTTP v2 and routing: `Url` in core over the host's `URL.parse`, elm/url's parser and
  builder, `Browser.Navigation`, link requests, `Tea.document`/`Tea.application`, deep links in
  `beni serve`, `Http` on elm/http 2.0 (multipart, progress, typed errors). JSON over HTTP is
  parked on `http-json-blocked`: `Http` importing `Schema` puts its pages over the test budget.
- Landed the defect teardown (`boundary.md` §9.8.14) and fixed a kernel leak: a fiber started by
  a finaliser of a cancelled fiber outlived it (also through scopes).
- Landed the Unicode notation (→ ← ≠ ≤ ≥ ▷ ◁ … ×), with code-point columns; ASCII forms refused.
- `core/Basics.js` and `core/Debug.js` are gone (beni over `Js`, new `Js.typeIs`); `Basics.eq`
  by name fixed for list forms and `()`; equality 1.5–7× faster.
- Studies: research 48 (Effect v4 parity ledger, plan P0–P10), 49 (fiber kernel in beni, needs
  `Js.suspending`), 50 (List.js in beni, needs `Js.object`/`Js.method`). Their compiler
  findings landed: emitter-called core values exported and returned, exit-first loops printed as
  `while` (compare 1.17× faster), exact specialiser speedups (the List port now fits the budget).
- Fixed: a dangling-else in release printing, a suspendable-twin-only module never written, field
  renaming through `Js.from` in twins, cache identity missing embedded core/platform files/build.zig,
  a `--core-root` core lacking an emitter import now refused, path-dependent dev hashes in the
  harness, two timer-flaky fixtures.

**What I learned**
- My merge script must check the merge itself succeeded before gating and pushing: twice it gated
  and pushed an unchanged master, and once a hand-merged test file was committed broken (reset
  and redone before push).
- Dirty-set incrementality in `Spec` cannot be exact (facts fall, travel past callers, and fact 3
  depends on walk order); exact per-statement savings were enough for the List port.
- Agents' scratch output filled /tmp (8 GB tmpfs); clean old scratch directories routinely.
