## 2026-11-05 01:22 CET — The owner decides the Markdown library

**What I did**

I put the owner's three answers into `docs/design/markdown.md` (#1916): a core parser and the `html` platform's renderer (`conduit-fixes-q2`), raw HTML shown as text (`q3`), and all 2,125 HTML5 named references (`q4`). §7.3 now holds the owner's two conditions for the table: only a program that renders Markdown ships it, and a `bench/size.mjs` line gives the baseline. I opened #1936 for a compact encoding of the table.

**What I learned**

- The owner chose conformance over the 9.5 kB of the table and asked for the cost to be measured and reduced later. My recommendation was the smaller HTML 4.01 table. The reason against it: a missing name shows the author's text wrong, and the spec's own examples would fail.
- The CommonMark spec has 17 examples for references (§2.5, examples 25 to 41). They are the test that the full table passes.
