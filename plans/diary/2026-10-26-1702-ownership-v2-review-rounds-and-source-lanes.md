## 2026-10-26 17:02 CET — Ownership v2: S3a review rounds and source lanes

**What I did**

- Took #1069 (Cond's observable frontier) and #1078 (S3a, lists in one
  declaration) through three review rounds each.
  - #1069: one frontier of paths for `propagate`, `kappaLeq` and `deep`.
    A recast and its inner are one position, also through a union's sides.
    Block writes κ as stored (format 7). The new tests fail on the old
    code.
  - #1078: holders found through the refinement chain at every refinement
    ancestor's canonical path (writes below a view). Materialised
    constructor arguments on recursive places. A taken element stored back
    is `shared`. Literal positions are apart under their split. Exactness
    per holder. Sibling work is linear (grouped chains, one pair per split
    run). An arm's value is a use. Holders of `⊤` are candidates.
- Made the v1/v2 verdict diff fail closed. It covers every ownership
  fixture. v2's dump names the declarations it does not check. Every other
  difference must be in `tests/blackbox/ownership-v2-known.txt`. The corpus
  harness checks every ownership fixture without a `.v2` the same way.
- #1070: the account keeps the kernel a walk is in. An instruction's
  transfer, a call's view, a demand's query and a holder's registration
  reserve in their source atom's lane. The graft (#1097, S3b) and run-wide
  operations (#1098, with #1073) stay named growth, by the manager's
  decision.

**What I learned**

- A differential that dumps only the programs both checkers accept cannot
  find a wrong acceptance. It also cannot find one when a missing demand
  hides among thousands of "not built" rows. A demand in a declaration the
  other side checked must match, or be listed.
- `⟲` folds a container and what lies under it to one canonical path, so a
  holder search by path alone loses the direction. The refinement chain at
  each refinement ancestor's path keeps it.
- Grafting the callee's class at every call is the main growth left in
  straight-line code. §4.1's call view by reference is what removes it, and
  that is S3b's rebuild of `Calls`.
