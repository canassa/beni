## 2026-10-22 03:56 CEST — Restore the Codegen section heading

**What I did**

Answered #667's documentation review finding: restored the existing
Codegen section title on one line. The amendment insertion had split off
its subtitle. Checked the exact heading and the diff's whitespace. The
compiler and verified program outputs have no changes in this correction.

**What I learned**

A section-pointer insertion must retain the complete heading, including the
subtitle after its comma. Number-only checks do not catch a broken anchor.
