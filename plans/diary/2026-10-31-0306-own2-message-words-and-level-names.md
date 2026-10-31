## 2026-10-31 03:06 CET — own2: message words and level names

**What I did.** Fixed #1371, #1380 and #1405, which change message text only.
- #1371: a `⟲` was named by the head of the place it follows, and that place is the record inside the
  constructor (`#Tree.0`), whose head is 0, the module's first type. `Message.levelHead` now names the
  nearest constructor place above it on the same cycle: `r.kids[*]#Tree.0⟨Tree⟩.v`, not `⟨Outer⟩`.
- #1380 and #1405: both are the same word. `Transfer.otherPaths` adds the rest of the written argument as
  an operand of the demand, and v2 said "another operand of the same operation" for it. The operand now
  carries `other_paths` and the message says "another path of the same argument". The cause stays
  `disjoint`: §2.8 condition 4 puts it before Dead, and it says "no other path of the same argument".
  v1's `call`/`element`/`level` words for an approximate reach need the call that approximated, which v2's
  cells do not keep, so §2.8 now states that v2 words every reach `disjoint`.
- Pinned in `ownership/MessageWords` (`.v2` and `.v2.ownership`).

**What I learned.**
- The corpus parity compares verdicts only, so a cause word never failed it. A message is pinned only by a
  fixture with a `.v2.ownership`.
- A message-only change is checked by dumping every `ownership/*.beni` and `*/Main.beni` with the base
  and the new binary and diffing: the only lines that changed are the 57 "another operand" to "another path"
  lines of single-argument calls and one `⟨Outer⟩` to `⟨Tree⟩` line (AnsweredRead 122:17).
- `sameCycle(p, p)` is false for a place with no self-step, so a lookup for the cycle's constructor must
  accept the place itself.
