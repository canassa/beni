## 2026-11-04 14:17 CET — Accept ASCII notation

**What I did**

Accepted ASCII notation alongside Unicode, restored spelling-preserving formatting, and added public `fmt --to-unicode`. Retired the two spelling migration flags, kept structural unit migration, and converted the playground sources to ASCII. Added runtime twins, formatter coverage, accepted Never and product fixtures, and updated the language contracts and developer skill.

**What I learned**

The parser already built identical nodes for the old spellings. The important formatter distinction is detecting products by either separator tag. Formatting before conversion avoids moving same-line case branches when an ASCII arrow shrinks. Unit comments can survive by replacing only the two delimiter tokens.
