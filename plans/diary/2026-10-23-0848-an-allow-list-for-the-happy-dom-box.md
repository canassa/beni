## 2026-10-23 08:48 CEST — an allow list for the happy-dom box

**What I did**

- Answered round 2 of the review of #817. F1: the deny list of round 1
  read happy-dom's computed style, and 13 more shapes gave a wrong box:
  viewport units and `pt`, `@media`, logical margins, a border style with
  no width, `offset-path`, `transform-style`, an animation, `rtl` with
  `right`, `hidden`, a closed `details`, and the default margins and
  borders of `p` and `fieldset`.
- Replaced the deny list with the reviewer's allow list. It reads only
  markup and inline style: no style sheet and no `style` or `link`
  element, a `div` or `span`, the inline properties `position`, `left`,
  `top`, `width`, `height` and `touch-action` on the element and each
  ancestor, lengths as `Npx` or `0`, and no hidden ancestor, `dialog` or
  closed `details`. The README and the amendment state the list.
- Ran the reviewer's probe as it is and as a copy with no `style`
  element, in both DOMs: each happy-dom box is Chrome's box or 0.
- F2: rebased onto master; the one conflict was a run-hash file, and
  rerere staged master's side. F3: `browser/tea/PointerInput` in the
  amendment.

**What I learned**

- A rule that reads happy-dom's computed style inherits every part of CSS
  that happy-dom computes in another way. A rule that reads only the
  markup and the inline style can name what it allows.
- happy-dom keeps `inset` as one inline property, and a `<link>` adds no
  style sheet when CSS loading is off, so the rule also looks for the
  elements.
- Chrome refuses a socket path longer than 107 bytes: a `TMPDIR` of
  `zig-out/scratch/557/tmp` in this worktree stopped `test-browser` with
  `ChromeDidNotStart`, where `zig-out/scratch/f1/tmp` had worked.
  `zig-out/t` is short enough.
