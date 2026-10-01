// The browser platform's one runtime file (docs/design/backend.md §15.3–
// §15.5, §15.11): the program runtime and the `dom` lowering's markup
// runtime at once, so a delegated listener can hand a message to the
// program that owns the node it fired on (boundary.md §9.2).
//
// **Most of it is written in beni**, in `Rt.beni`, this platform's runtime
// module (boundary.md §9.2, *A runtime module*; `plans/runtime-in-beni.md`):
// an instance's nodes, templates, slots, a block's mount and patch, the
// render loop and the mount, the `Html`, `Maybe Html` and `List Html`
// holes, a text hole's node, the attribute writes but for classes, styles
// and URLs, the markup primitives `text` and `map`, the events — the
// delegated listener, `delegate`, `start`, `listen` and `identity` — and
// the lists and conditionals: `forKeyed`, `forPosition`, `show` and `hide`.
// This file holds the rest, and reads the beni half through the import
// below; both are compiled with the program, and only what a page reaches
// is written.
//
// Parts are ported from dom-expressions' client runtime (MIT, © Ryan
// Carniato; references/dom-expressions/packages/runtime/src): `template`
// (now in `Rt.beni`) from client.js `template`, the class and style diffs
// from `className` and `style`, the delegated listener (now in `Rt.beni`)
// from `eventHandler`, and `reconcile` (now in `Rt.beni`) from
// reconcile.js (udomdiff) with its slot ownership tags removed, since every
// node here has one owning slot.
//
// A `List` is read as every sibling reads one — by backend.md §4's
// protocol, `elements` in `Rt.beni` — and a tuple as `{ a, b }`.
//
// The page is reached through `globalThis`, a capability of this file
// and of `Rt.beni`'s `Js` calls alone: the code the compiler emits for a
// view touches only the nodes the runtime hands it.
import { elements } from "beni:Rt";

// ---- Attributes (backend.md §15.3, §15.6) --------------------------------

// The names whose flag is `True`, a name holding whitespace being several.
const classSet = (list) => {
  const names = new Set();
  const a = elements(list);
  for (let k = 0; k < a.length; k++) {
    if (!a[k].b) continue;
    for (const name of a[k].a.split(/[\t\n\f\r ]+/)) if (name !== "") names.add(name);
  }
  return names;
};

// `(el, list, previous)`: the element has exactly the classes the list
// names; what only the previous list held is removed.
export const classes = (el, list, previous) => {
  const next = classSet(list);
  const old = previous === null ? null : classSet(previous);
  if (old !== null) for (const name of old) if (!next.has(name)) el.classList.remove(name);
  for (const name of next) if (old === null || !old.has(name)) el.classList.add(name);
};

// Each property's last value.
const styleMap = (list) => {
  const values = new Map();
  const a = elements(list);
  for (let k = 0; k < a.length; k++) values.set(a[k].a, a[k].b);
  return values;
};

// `(el, list, previous)`: each property set to its last value in the list,
// an empty value removing it; a property only the previous list set is
// removed.
export const styles = (el, list, previous) => {
  const next = styleMap(list);
  const old = previous === null ? null : styleMap(previous);
  const style = el.style;
  if (old !== null) for (const name of old.keys()) if (!next.has(name)) style.removeProperty(name);
  for (const [name, value] of next) if (old === null || old.get(name) !== value) style.setProperty(name, value);
};

// Elm's rule: a URL whose scheme is `javascript:`, or `data:text/html`,
// with any whitespace or control character where a browser ignores one,
// runs script, so it is written as nothing. It stays here: `Js` writes no
// regular expression literal, and the one function has nothing a page could
// specialise (`plans/runtime-in-beni.md`, step 2).
const scriptUrl =
  /^[\s\x00-\x20]*(j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t\s*:|d\s*a\s*t\s*a\s*:\s*t\s*e\s*x\s*t\s*\/\s*h\s*t\s*m\s*l\s*[,;])/i;
export const safeUrl = (url) => (scriptUrl.test(url) ? "" : url);
