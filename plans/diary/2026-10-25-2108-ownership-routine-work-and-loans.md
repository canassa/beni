## 2026-10-25 21:08 CET — Ownership routine work and loans

**What I did**

Verified the re-check against the design and origin/master c349ed1fc. Added bounded source lanes for final validation, direct queries/calls, transfer settlement and identity/delta entry work; removed full-frame solver replays. Explicitly qualified the general recursive/update/wide-main families where products remain unproved source-linear. Ordinary collection stores now preserve loans and their regions; deep rejection remains at ownership-transfer, cell-store and escape boundaries. Documented copy depth and sufficient fixes. Removed the proposed v1 adapter: v2 accepts both Send protocols while the existing API/corpus stays unchanged until switch-over. Added runtime lane invariant checks and name-independent logical credit assignment.

The read-only adversarial verifier checked the revised core and found no remaining counterexample within the stated bounds. Its compound-obligation, ancestry-accounting and shared-memo-credit findings were folded in. Audits map all 260 requirement IDs and 45 pending roots, with zero bad module edges among 99 imports. Estimate: 131 implementer-days, 110-day dependency path, 14 slices. Only the two design documents and this diary changed; no compiler tests or new measurements are claimed. PR #1010 receives the Round 8 table; the worktree is removed after pushing, without merging.

**What I learned**

A guard on superlinear growth must not charge another routine validation or direct query merely because the body is longer. That does not establish a general linear algorithm: transfers×versions, demands×holders and calls×obligations remain real products, and the requirement must say so. A loan may safely pass through a collection-building callee within its original region; copying the outer collection removes only that storage's loan, not its children's.
