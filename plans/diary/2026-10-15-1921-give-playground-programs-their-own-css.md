## 2026-10-15 19:21 CEST — Give playground programs their own CSS

**What I did**

Issue #143. I specified the CSS pane in `docs/design/playground.md` §4.6, with
dated notes in §4.2, §4.3, §4.5, §5 and §6. Then I built it:

- a `style.css` tab beside `Main.beni`, with CodeMirror's CSS grammar
  (`@codemirror/lang-css` 6.3.1, `@lezer/css` 1.3.8, vendored by `vendor.sh`);
- the CSS in the frame: a JSON element in the `srcdoc`, and a `<style>` that
  `frame.js` adds before the program mounts (`playground/srcdoc.js`);
- the CSS in the link, as `&css=`, only when the pane holds text;
- a CSS file for the counter and for TodoMVC, light and dark, down to 320 px.

TodoMVC's CSS is `todomvc-app-css` 2.4.3, which is CC-BY-4.0. The file holds
it unmodified between two markers, with the credit, and the changes follow.
`samples/LICENSES.txt` ships the notice. A gate test checks the copy against
the package's SHA-256.

I did not build item 3, the list of allowed style sheet URLs. The sandbox
does not stop an `@import` or a `url()` in the CSS, so the list would block
nothing. A Chrome check shows that an `@import` from another origin applies.

**What I learned**

- The Chrome test can check WCAG contrast from computed styles. It found the
  upstream placeholder at 2.85:1, under the 3:1 that 24 px text needs.
- A scheme change starts the samples' colour transitions. A contrast check
  must wait for them to end, or it reads a colour halfway.
- `zig` is not on `PATH` in an agent shell here, because `.envrc` is blocked.
  `nix develop -c zig …` works.
