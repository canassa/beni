## 2026-11-05 01:09 CET — Browser Program review fixes

**What I did**

Updated the Program contracts to describe closed typed mount jobs. Restricted
compiler-owned Browser.Bridge recognition to the loaded browser layer. Restored
the precise suspending-view diagnostic, while preserving separate bad callbacks.
Added named missing-body and stopped-page request regressions, and removed
parentheses left around type atoms in generated API references. Constructor rung
alignment remains #1934 until typed inline Programs make construction pure.

**What I learned**

A module spelling is insufficient authority for a compiler-owned bridge. An
aggregate effect demand may repeat a precise callback demand; the full causal
path identifies that repetition without merging independent mistakes. The shared
gate evidence precedes #1924, so comparison must account for that reviewed change
as well as this follow-up. The manager reviews and merges the follow-up PR.
