// The document of the playground's output frame (docs/design/playground.md
// §5, §4.6): the emitted files and the CSS pane's text as JSON, and the
// frame's bootstrap, `frame.js`, which loads them.

/// `value` as JSON that a `<script>` element holds: no `<` may close it
/// early.
const json = (value) => JSON.stringify(value).replaceAll("<", "\\u003c");

/// The `srcdoc` of a frame that runs `files` (each emitted path to its
/// text) with `script`, the text of `frame.js`, and `css`, the CSS pane's
/// text. With an empty pane it is the document of before the pane, byte for
/// byte: no `beni-css` element, so the frame gets no `<style>`.
export function srcdoc(files, css, script) {
  return [
    '<!doctype html><html><head><meta charset="utf-8">',
    `<script id="beni-files" type="application/json">${json(files)}</script>`,
    css === "" ? "" : `<script id="beni-css" type="application/json">${json(css)}</script>`,
    `<script>${script}</script>`,
    "</head><body></body></html>",
  ].join("");
}
