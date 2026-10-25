## 2026-10-25 02:29 CET — a callback that keeps a record the callee writes

**What I did**
- #983 (#962) and #984 (`sortWith`) merged. Worked on #982, which is a miscompile on master: a callee hands a
  function a record and writes the record afterwards, while the function (`Box`, `λq → Box q`) keeps it.
  Three changes, in #995 (a draft):
  - a probe counts an update that replaces every field as a use of the record;
  - `callbackKeeps` gets a record twin;
  - `passOn` takes the lambda's closure, so a captured record is named instead of `⊤`.
  `build/bad/inline/RecordCallbackKeeps` shows 44 on master, where the right answer is 4.
- The owner froze `src/own/` for a rewrite. The run-time `Schema.read` fix became a pending acceptance
  test (CK-271, #994). #976 (sends) was assessed: it needs a deep record demand on a send's payload, which
  is new structure, so it is parked.

**What I learned**
- A keep edge that reads only a summary cannot know whether a write comes before or after the call. A
  write before the call, with the written record returned, is refused, and the list twin has the same blind
  spot. A precise rule needs a "written after the supply" fact for each supply.
- A probe reads the supplied value at ε. A record inside a fresh literal handed on (`f [ r ]`), or a record
  below the one handed on that is written through a local, escapes it. These are the next holes for v2.
