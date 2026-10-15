## 2026-10-10 01:07 CEST — S2: answering PR #41's adversarial review

**What I did**
- `rekey` compares keys by SameValueZero (`NaN` equals `NaN`); compound keys are already
  `key_not_primitive`. Red-first fixture `browser/direct/RekeyNaN`.
- Duplicate keys left the gates: the golden that pinned `browser-direct`'s wrong output is gone,
  and CK-221 is red in `tests/pending/browser/direct/DuplicateKeys` — five lists, one per script,
  `browser-tea`'s transcript expected — recorded as an S3 blocker. `KeyedInPlace` appends a
  fresh key.
- The verify mode compares every element (a loop) and counts the rows a list marked (`$v`, dev
  only) in its parent. Two tests break a build where each looks and must stop the page; the
  negative controls (cap restored, count removed) run silent.
- A `browser/direct/` page's value fuzz is now a case of its own, budgeted alone, with its own
  `.fuzz-run-hash`: every page fuzzes values in the gates and `value_fuzz_in_sweep` is gone.
  `ListValues` reaches every shape script with fuzzed indices. Largest case 3.8 of 4.3 billion.
- `RemoveFocusedRow` pins that nothing in S2 nests a delegated dispatch; `ForHelperTwoLists`
  that a `For` used on two lists is refused.

**What I learned**
- The reviewer's "verify passes a stale middle row" was half right: rows were always compared
  one by one; the cap only reached a list inside a row. The test had to be built to find that.
- My "every build re-checks `Direct`" was wrong: builds install the checked modules from the
  binary. The real wall is `dump`, whose missing `informational` bit misses every embedded key —
  850 million instructions, 165 with the bit.
- Splitting a case is the budget rule's own remedy (one test per branch); an opt-out list was not.
- Chrome fires `blur` on removing a focused input; its queued message lands between two
  delegated handlers on `browser-direct` and after both on `browser-tea`. Q1's corner.
