## 2026-11-04 20:07 CET — The owner replaces CodeMirror with a beni editor

**What I did**

I recorded four owner decisions in the spec of #142 (PR #1897). Cesar took `browser-tea` for the page (`playground-beni-q1`) and a typed WebAssembly module with the WASI host in beni (`q2`). For `q3` and `q4` he took neither option: "replace CodeMirror with a simple editor written in beni itself". So `playground.md` gets §10.10, the beni editor: a `textarea` for each file over a highlighted `<pre>`, what it keeps from CodeMirror and what it drops, and the tests and measurements of its pull request. I closed #1881, #1882 and #1893 as not planned, opened #1900 (the selection of a text field), and asked `playground-beni-q5` (the browser's undo, or a history in beni). The order of the file pull requests changed: `srcdoc.js` and `syntax.js` go first, and `page.js`, `editor.js` and `positions.js` go together, last.

**What I learned**

- `html` already has most of what a `textarea` editor needs: key events with `preventDefault`, the modifier keys, `targetValue`, and a controlled `value` that keeps the caret (`Html.beni:110`, `:889`; `Rt.beni:1744-1763`). The selection is the one gap.
- A `textarea` that grows to its text (`rows` = its lines, no wrap) scrolls with its highlighted copy in one pane, so no code keeps two scroll positions in step.
- The `positions.js` slice I prepared first is not needed: the beni editor counts code points, as the compiler does, and only the selection wrapper converts to UTF-16 units. I measured the draft against `positions.js` on 192 000 inputs (no difference) and kept it out of the tree.
- Setting a `textarea`'s value from code clears the browser's undo history, so Tab needs `execCommand("insertText")` or an undo history in beni. That is `q5`.
