## 2026-10-22 18:41 CEST — Repair pending ownership fixture registration

**What I did**

Removed the deleted EnumCycle fixture from the pending index. Registered the
existing two-key DictFocusGrow limitation as CK-267, with its finding header,
catalogue entry and confirmed red signature. Kept its correct accepted golden
and the owner's #663 deferral to #294. The targeted pending run now passes,
reporting the intended wrong Maybe.map ownership verdict. The locked full
gate passes. This is separate from the precision fix in #761 for #210.

**What I learned**

The pending registry is validated before a case filter is applied, so a stale
path can hide a malformed finding header in a different targeted fixture.
Fixing the registration makes the known refusal observable without accepting
it as correct or extending the owner's exception.
