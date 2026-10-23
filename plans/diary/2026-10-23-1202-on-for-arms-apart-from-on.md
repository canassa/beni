## 2026-10-23 12:02 CEST — `on` for arms apart from `on`

**What I did.** #874: since #866, every browser-inline page shipped the arm walk and the
four-argument `on`, also a page with no handler inside an arm. The runtime now has two functions:
`on(node, f, kind)`, as it was before #866, and `onArm(node, f, kind, arms)`, which only a handler
inside eager arms names. Dead-export removal drops `onArm` and the walk from a page that does not
name it. `browser-inline.md` §8.2's table and its #844 amendment say so. 23 `emit/release/inline`
goldens of pages with no arm handler lost the walk: 20 are their pre-#866 bytes again, and the three
that #873 also moved differ from pre-#866 only by #873's change; `ArmListener`, which has both kinds of handler,
grew 30 B raw, the price of the two functions on one page. Red first: the new `CounterLocal` golden
fails against the unchanged runtime.

**What I learned.** A runtime function whose argument is optional pays for its widest caller on
every page. When only some pages need the wide form, a second export is free for the others,
because Minify removes exports nothing imports.
