## 2026-11-04 14:23 CET — Preserve qualified empty-type identity

**What I did**

Tightened Unicode conversion so qualified Never references resolve explicit module aliases before the prelude. A user module imported as Basics keeps its own type; an alias of the real Basics module converts its empty type. Added a black-box regression and captured the incorrect pre-fix output.

**What I learned**

A qualified spelling is not proof of identity. The same per-file import information that keeps unqualified Never safe also determines whether a qualified name refers to the prelude.
