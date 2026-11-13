## 2026-11-13 02:51 CET — The markup rule, adopted in ownership v3

**What I did.** Carried out the owner's decision of 2026-11-13: a view's markup holds none of its
holes' lists once the runtime has it, and every runtime reads a hole's value only while it renders.
The rule is `boundary.md` §9.4.8; v3 trusts it at the entry (`entryCall`, `Mod.isView`) and
gives `Html.map` the markup rule. Real writes 279 → 292. One `.sanitize-lists-v3` fixture per
platform that renders markup, each proven to trap on a runtime broken on purpose in a second
worktree. Sweeps, sanitiser corpus and gates unchanged and green. Report 117 §9 has the audit table.
Issues #2502–#2507.

**What I learned.** Report 117 §5's one-line setting (markup holds nothing) is not sound: the
`dom` runtime reads a hole at render, after the program can write the list (report 114 §9 fault
3 comes back, and a pin fails). The rule is about what a runtime keeps after a render, so the
checker may use it only where markup reaches the runtime. The adversarial reviewer then showed
the rule's premise is false on `dom` in Chrome: a blur during a patch runs `update` mid-render
(#2502). The sanitiser cannot catch identity comparisons, and `List.push` still copies below 32
elements, so no build on this branch can show that class of fault yet.
