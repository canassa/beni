// The Node platform's markup runtime (docs/design/backend.md §15.6): what
// the `ssr` lowering's emitted code imports, and the `html` vocabulary's
// markup primitives. Markup under `ssr` is `{ t: string }`, HTML already
// escaped, so a rendered string is never escaped twice.
//
// It reads a `List` as every sibling reads one — cons cells, `$ === 1` for
// a cell with `a` its head and `b` its tail — and a tuple as `{ a, b }`.

const replacements = { "&": "&amp;", "<": "&lt;", '"': "&quot;", "\r": "&#13;" };
const replace = (c) => replacements[c];

// Text as a page's parser reads it back.
export const escape = (text) => text.replace(/[&<\r]/g, replace);

// A double-quoted attribute value as a page's parser reads it back.
export const escapeAttr = (value) => value.replace(/[&<"\r]/g, replace);

// Elm's rule: a URL whose scheme is `javascript:`, or `data:text/html`,
// with any whitespace or control character where a browser ignores one,
// runs script, so it is written as nothing.
const scriptUrl =
  /^[\s\x00-\x20]*(j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t\s*:|d\s*a\s*t\s*a\s*:\s*t\s*e\s*x\s*t\s*\/\s*h\s*t\s*m\s*l\s*[,;])/i;
export const safeUrl = (url) => (scriptUrl.test(url) ? "" : url);

// The rows of `items` concatenated, each `row(item, position)` a block; the
// fallback's text when there are none.
export const list = (items, row, fallback) => {
  if (items.$ !== 1) return fallback === null ? "" : fallback.t;
  let out = "";
  let position = 0;
  for (let at = items; at.$ === 1; at = at.b) {
    out += row(at.a, position).t;
    position += 1;
  }
  return out;
};

// A class list's text: the names whose flag is `True`, a name holding
// whitespace being several, each once, in first-occurrence order.
export const classes = (entries) => {
  const seen = new Set();
  const names = [];
  for (let at = entries; at.$ === 1; at = at.b) {
    if (!at.a.b) continue;
    for (const name of at.a.a.split(/[\t\n\f\r ]+/)) {
      if (name === "" || seen.has(name)) continue;
      seen.add(name);
      names.push(name);
    }
  }
  return names.join(" ");
};

// A style list's text: each property once, in first-occurrence order, with
// its last value; an empty last value removes it.
export const styles = (entries) => {
  const values = new Map();
  for (let at = entries; at.$ === 1; at = at.b) values.set(at.a.a, at.a.b);
  let out = "";
  for (const [name, value] of values) if (value !== "") out += `${name}:${value};`;
  return out;
};

// Text written into a raw-text element (a `<style>`), where nothing is
// decoded: as it is, but for `</` before the element's own name, in any
// case, which would end the element early and is written `<\/` — in CSS,
// a `/` escaped is a `/`.
export const rawText = (text, tag) => text.replace(new RegExp(`</(?=${tag})`, "gi"), "<\\/");

// `Html.text`: the text, as a text hole shows it.
export const text = (s) => ({ t: escape(s) });

// `Html.map`: a string carries no handler for the function to wrap.
export const map = (html, f) => html;
