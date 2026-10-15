## 2026-10-15 20:04 CEST — Link the playground licence notices

**What I did**

PR #155 (the playground's CSS pane, #143) was merged before I pushed the
answers to its review, so they go in a follow-up, issue #171:

- The page's note links `vendor/LICENSES.txt` and `samples/LICENSES.txt`.
  A gate check and a Chrome check prove the links, and that the site serves
  the files.
- The tabs name their panels with `aria-controls`.
- A test pins that a link with an empty `css=` opens no program, as an empty
  `code=` does.

Before #155 merged, at the coordinator's request, I also changed CSS edits:
the page sends the new CSS to the running frame by `postMessage`, so the
program keeps its state. An edit of the beni source still restarts it.

**What I learned**

- A draft PR can be merged while its worker still pushes answers to the
  review. Check the PR's state before you merge `master` into the branch.
  A squash merge then shows as conflicts in every file it touched.
- A message to a new frame can arrive before the frame listens. The frame
  posts `ready`, and the page sends the CSS again if it changed.
