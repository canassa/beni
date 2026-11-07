## 2026-10-30 16:27 CET — The holder index's second review round (#1214, PR #1323)

**What I did.** Fixed a use-after-free in the descent: the loop over a state's cached
children read `kid_cache` through a slice while `expand` appended to it, so a grown list
fed freed memory as steps, `child` fell back to listing holds, and the doubling DAG was
exponential again (66 160 records at depth 12). The loop indexes the list now, and no other
loop iterates a list its body can grow. A cover that falls back is counted on the dump's
account line (`hold listings`), and under runtime safety a child step must be a real child.
The depth-12 test bounds records from depth 8 to 12 (137 → 181) and refuses any listing.
Holds below a join are approximate and `element` (the manager's decision, `JoinHolds`), and
§2.8 condition 5 states the whole rule. The branch was rewritten into four commits that each
build.

**What I learned.**
- The fallback hid the bug: it was correct, just slow, so nothing but a cost bound could see
  it. A fallback that exists for rare shapes must be counted and refused where it should not
  happen.
- A pointer or slice into a list is dead after any call that may append to that list,
  including calls three levels down.
