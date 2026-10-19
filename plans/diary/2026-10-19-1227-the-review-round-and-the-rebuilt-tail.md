## 2026-10-19 12:27 CEST — the review round, and where a rebuilt tail lives

**What I did**

- Answered PR #438's `@claude` review, finding by finding. One fix: a comment at the
  `schema_shapes` pass in `Lower.zig` (`valid_sites`) naming the gap, #432 and the rule that the
  fact must land before a build reads rows — a doc comment naming an issue, the file's own style
  (`issue #328`, `issue #349`), not a `// TODO`.
- Confirmed the reads the review questioned, no change needed. The export list's lift read
  (`Lower.zig:2872`) is safe because the tail is a rebuilt byte: §9's join step 3 recomputes the
  tail and "a row stores nothing for it", so the read can only reach the reading build's own
  bytes — the per-declaration lifts that DO pick stored bytes are asked (`livePiece`,
  `liftPieces`). `Pack`'s sharing compares the payload bytes themselves
  (`offsets.getOrPutAssumeCapacity(p.bytes)`, `.edges`/`.emit` only), so a future kind that
  legitimately differs per option cannot be silently merged. `EmitPack`'s identity guard is the
  decoder's ident-index bound plus the maker's self-check on identities and their counts.
- Declined three with reasons: an `inline` hint on `ask`/`askSelf` (the medians already price the
  call; a codegen change without a measurement is not how this tree decides, and slice 3 is where
  the asks start to pay), a unit test over `refuses` (black-box tests are the asset and #417 owns
  the fixture, at the step a refusal changes what a build does), and a tie-break in
  `nullaryDecls`' sort (the key travels with its value, so nothing can mispair; the comparator and
  the element sequence are master's own, so a tie's order is the same deterministic choice and is
  pinned by the goldens, the `diff -r` trees and the determinism test; a secondary key would move
  bytes wherever a tie exists, for slice 3 to price).
- Commented on #94 with the maker's per-build cost the review asked be tracked (9 s compile plus
  1 s run, fresh cache; the pack 4 182 851 → 6 672 561 bytes), and re-ran `zig build gates` on the
  comment's tree before pushing it.

**What I learned**

- "A read whose answer reaches a printed byte" is narrower than it sounds: the join rebuilds the
  head and the tail, and the completeness rule's reason — reuse must not splice across a
  difference — stops at the row's text. A question about a rebuilt byte is answered by the build
  that rebuilds it, and a reviewer sees the read, not the boundary, so the boundary has to be
  named: in the reply, and now at the shape site in code.
- A review finding comes in three kinds — a real gap, a confirmation request, and a suggestion
  whose cost is a measurement. Answering each in kind (fix, confirm, decline-with-reason) is the
  job; the declines were cheaper to defend than to implement, and each names the slice, rule or
  measurement it would have to come with.
