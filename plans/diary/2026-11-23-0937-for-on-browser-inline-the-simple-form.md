## 2026-11-23 09:37 CET — `For` on browser-inline, the simple form

**What I did.** Built the owner's 2026-11-23 decision on #298: `For` over a `List` compiles on
`browser-inline` (keyed, by position, by reference), with no edits from write sets. One binding
per `For`, whose read set is the write-set pass's edge of the `For`, calls `Inline.forRows`:
rows matched by key and rank, every row's `set` run, LIS moves, and the focused row held in
place. Row events go through the dispatcher with the message kept at `set`. A `For` may also
stand before sibling elements, nest in a row, and rows may mix text holes and elements. Spec:
`browser-inline.md` §9's dated note. 46 `browser/tea` pages copied to `browser/inline`
(30 with the same transcript, 16 with one listed difference in a header comment), four new
pages, nine refusals, one release golden. The inline sweep of the 357 tea/dom pages went from
60 (64 counting project sources found by `find`) to 108. Runtime: `forRows` 396 B brotli in a page.

**What I learned.** A controlled `select` and the `For` of its options must be one binding, or
a pass can write the value before its option exists (found by the review). `Dict` `For` cannot
start until S2b and #961. The biggest remaining refusals are commands the write-set pass cannot
read (28) and `view`s with `let`s (23).
