## 2026-11-02 01:57 CET — Preserve worker boundary values

**What I did**

Fixed worker entry reachability so constructors supplied by a peer retain their
case arms. Program wire roles now require concrete message types at their
declaration, including nested variables after alias expansion. The temporary
restriction has follow-up #1652 for selective runtime normalization.

Emitted normalization metadata uses type parameter indices and shared field
paths. The worker transport normalizes the selected subfield. Wire obligations
map annotated readings to scheme quantifiers by identity rather than by name.
Added Chrome and diagnostic regressions, proved the original failures, and
rebased onto the workers branch after its master merge.

**What I learned**

An entry's constructor builders do not describe the values its peers can send.
An annotation's rigid reading also has different variable identities from its
published scheme; preserving that relationship prevents same-name scope leaks.
