## 2026-10-22 17:40 CEST — Declare hosted entry ownership

**What I did**

Specified the hosted entry protocol for #750 before implementing it: update and
settle own the current state, their results are installed, and Host arguments
cross the runtime boundary. Added the entry word on written-out callback record
parameters of core and platform declarations, removed constructor-name matching,
and annotated Browser, Tea and Page constructors. The hosted state invariant
checks both writers, their escapes, retained handlers and aliases. Added malformed
word fixtures, the accepted reduction, six retention negatives, fresh settlement,
and a renamed constructor with a tuple state and shared-state control. Audited and
pinned the trusted constructor and host bodies; updated the developer-facing skill
and regenerated its API references.

The required view-handler negative exposed #766: the old checker skipped retained
handler captures when messages were scalar. Proved that unsafe acceptance with
the pre-change compiler and fixed it in the shared entry path. Targeted protocol,
word-flip, cache and body-pin checks pass. Updated to current master and preserved
its shared entry reach indexes while resolving the overlap. Final run hashes and
gates use the shared dagon lock before the PR; all work uses this one dagon clone,
the self-hosted compiler and the flake shell. No measuring, copying fallback,
weakened check, budget change or private-table exemption.

**What I learned**

A hosted driver has two state transitions. Treating settlement only as a read
would lose both its writes and the values it can retain. A scalar message also
says nothing about what a rendered handler keeps in its environment. Protocol
selection belongs to the declaration's entry word; state shape and callback roles
come from its types, so a constructor's name and the parameter's position do not
change the ownership verdict.
