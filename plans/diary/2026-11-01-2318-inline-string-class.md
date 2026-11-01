## 2026-11-01 23:18 CET — Inline String class bindings

**What I did**

Separated scalar String class values from class-list values in the Inline
lowering. Retained constant attribute escaping and compared dynamic native
attributes before writing. Ported DOM, prerender and emission regressions.

**What I learned**

Master refuses the constant String class as a class-list compiler limit. The
fixture proves that with the source fix stashed. The existing SVG element
limit remains separate from String attribute lowering.
