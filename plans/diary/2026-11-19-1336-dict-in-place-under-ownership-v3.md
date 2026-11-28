## 2026-11-19 13:36 CET — Dict in place under ownership v3 (research report 160)

**What I did**

- Built the owner's `Dict` representation on `ownership-v2-design-review` (branch `own3-dict160`):
  ordered `[key, value]` entries and a `Map` from key to entry, `pub equatable keyed foreign type
  Dict k v`, `Set` a box over it, `empty ⊤`, `copy`, `swap`, `insertAt`, `sortBy`, `keyAt`. Public
  writers copy; only a write v3 accepts is made in place, under the oracle.
- Gave the primitives v3 rows (v2-only words, so v1 reads none; v2 reads keyed rows as no word
  through `own2/Keyed.zig`). A key is a position for `insert`, `remove` and `valueFor`; `remove`'s
  position widened rule 10 to writers with no stored value.
- Routed accepted `Dict`/`Set` writes through `--sanitize-lists` (copy and poison the header) and
  `--lists-in-place` (move the written storage into the base's header), including the walked writers
  and `sortBy`'s evidence path. A mutant v3 with no later-read test was caught on every live probe.
- Kernel §12, report 160, `dicts.mjs` (4 428 programs), the sweeps, the ledger, the big-table bench,
  timing, two adversarial reviews, `zig build gates` and `gates -Dllvm` green.

**What I learned**

- Copying writers make a fold of inserts O(n²): `run/MarkdownLimits` hit the hang guard (#2569).
- A fold over a type variable whose seed is a row's `fresh exclusive` dictionary is refused at the
  next write (`disjoint`), where a `[]` seed is not (#2570 item 5).
- The v1/v2 parity list is keyed by position text; a filter by substring removed unrelated `⟨Tree⟩`
  lines once. Remove only what the stale check names.
- The corpus harness blesses dev and release passes in parallel; a second run settles a golden that
  a race left stale.
