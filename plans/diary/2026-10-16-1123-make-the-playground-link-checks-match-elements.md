## 2026-10-16 11:23 CEST — Make the playground link checks match elements

**What I did**

More work on PR #178 (issue #171), after the entry of 2026-10-15 20:04:

- Commit `a8398fb72` added the `tabs` gate check: the `aria-controls` of
  each tab names an element of the page.
- The machine ran out of memory at 22:00 and stopped the agents. No build of
  mine was running. I merged `origin/master` into the branch and ran the gates
  again, under the heavy lock and a 10 GB memory cap.
- An adversarial review found five small points. The two licence links now
  open a new tab: the page keeps an edit only in its editor, so a click that
  left the page could lose it. The gate's link checks now find an `<a>`
  element outside comments, and the `tabs` check finds a tab with `role`
  in any position. `playground.md` §4.6 and §6 say so.

**Correction.** The entry of 2026-10-15 20:04 says that a gate check proves the
links. It did not: it found the text `href="…"` anywhere in `index.html`, also
in a comment. Only the Chrome check proved the links. From this entry on, the
gate check proves them.

**What I learned**

- A check that looks for a substring of HTML also passes when the substring is
  in a comment, or in a tag with its attributes in another order. Run the check
  on a mutant to see that it can fail.
- A link that leaves an editor page in the same tab can lose the person's
  edit. The back/forward cache keeps the edit only when the browser uses it
  for that page.
