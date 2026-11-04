## 2026-11-04 20:30 CET — The browser keeps one undo history per page

**What I did**

I answered the review of PR #1897 (the spec of #142) in a new commit. §10.2 and §10.5 now say in the past tense that the owner decided. §1 and §6 point to the beni editor that supersedes CodeMirror. §10.7 says that the interim adapter for `syntax.js` is JavaScript that goes with `editor.js`. §10.10 covers pasted tabs and gives a cost for each dropped feature. A test in headless Chromium 153 checked the reason behind my `q5` recommendation and found it wrong, so I withdrew it and asked `playground-beni-q8` instead. I also asked `q6` (the frame's program: a URL or a typed `srcdoc`) and `q7` (the load-error listener). On a branch of its own, `srcdoc.js` became `playground/src/Srcdoc.beni`. That pull request waits for `q6`.

**What I learned**

- Chromium keeps one undo history for the whole document. After `insertText` in field A and then in field B, an undo with A focused took back B's edit. After code set a field's value, an undo in that field did nothing. The page from that test is `zig-out/scratch/undo/undo.html` in the worktree. It is not in the tree, so its three cases are written in `playground.md` §10.10, *Undo*.
- The browser runtime does not write a `value` that the field already shows (`platforms/browser/Rt.beni:1746`). So typing keeps the browser's history, and only a value that the program changes clears it.
- The owner closed `srcdoc` as a script sink on 2026-09-29 (`untyped_srcdoc_attribute`). The playground's frame uses `srcdoc`, so #1890 is a question, not a plain vocabulary row.
- A `--release --library` build renames its exports, so hand-written JavaScript cannot import from it (#1901). The playground uses the development build: its `Srcdoc` closure is 6 007 bytes raw, against 1 040 for a release build.
- The 192 000-input check of the `positions.js` draft (the entry of 20:07) used a seeded generator over ten fixed pieces of text, 3 000 texts and lines and columns from -1 to 6. The script was in the scratch directory and is not in the tree.
