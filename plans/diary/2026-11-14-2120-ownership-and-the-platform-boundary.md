## 2026-11-14 21:20 CET — Ownership and the platform boundary (report 137)

**What I did.** A design study, no code: research report 137. I read the v3 kernel, reports 116 to
135, `boundary.md` §9.4.8, `backend.md` §4 and §15.5, the runtime's page loop and keyed `For`,
the markup interface and issues #2502 to #2508. I sorted every proven stale-list fault since the
kernel text into boundary and interior. I wrote the page loop as typed generic beni in fourteen
application programs on `node` and judged them with v3. I measured a guard flag on a state cell in
Node. I wrote the options, the prior art for the boundary, a target design ("contracts at the
wall") with its soundness argument, and an ordered plan.

**What I learned.**

- 22 of the 26 proven fault classes are at the boundary, and the four interior ones all date from
  2026-11-13. The interior closes because every construct has a rule and every `switch` is
  exhaustive. The boundary has no such closing rule: the checker keeps a hand-written copy of what
  the platforms do, and that code had 235 commits in 30 days.
- The entry rule is not a description of the platform. It is a private copy of an analysis that the
  general rules lack. v3 refuses 9 of 11 safe ways to write the page loop as a generic function: a
  state handed from one function parameter to another, a borrowed look between two steps, a
  function in a record field, and a state kept in a cell.
- The runtime is untyped (`mount : V, V → ⊤`), so a walk of it can derive only "everything
  escapes". Even `Tea.element`, typed beni, is believed by its word `entry`; the model is found
  by the field name `update`.
- The sanitiser cannot see an identity test (its copy is a new object), happy-dom fires no `blur`
  on removal, and no build writes a list in place yet (`List.push` copies below 32). So one fault
  class has no oracle. `staleSites` already lists the poisoned arrays, so `Js.same` could trap.
- `keeps_let` and the list of callers read off the backend are the two boundary fixes of a
  different kind: the fact comes from the code that knows it, with "keeps everything" as default.
  The recommendation makes that the only kind.
- A busy flag on the one state cell costs 0.36 ns for each message (7.42 against 7.78 ns).
