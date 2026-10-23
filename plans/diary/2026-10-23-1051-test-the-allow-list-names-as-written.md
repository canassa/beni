## 2026-10-23 10:51 CEST — test the allow list's names as written

**What I did**

- Answered round 4 of the review of #817. F1: the `setProperty` wrapper
  lowercased a name before its test. I found the same fault in the names
  that the list reads from the `style` attribute: happy-dom drops
  `POSITION: relative`, Chrome applies it, and the list passed it. Both
  now test each name as written; the attribute text is only trimmed.
- F2: the README says which writes the marks see (the `style` attribute
  and `setProperty`) and which they do not (`cssText`, an assignment to
  a style property, `attachShadow`, `element.animate`), and that the
  getter marks on each read.

**What I learned**

- happy-dom drops a property name in another case, in the attribute and
  in `setProperty`. CSS names are not case-sensitive in Chrome. So a
  rule that compares names in lower case can pass a declaration that
  happy-dom never applied.
