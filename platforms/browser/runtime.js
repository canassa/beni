// The browser platform's one runtime file (docs/design/backend.md §15.3–
// §15.5, §15.11): the program runtime and the `dom` lowering's markup
// runtime at once, so a delegated listener can hand a message to the
// program that owns the node it fired on (boundary.md §9.2).
//
// **All of it but `safeUrl` is written in beni**, in `Rt.beni`, this
// platform's runtime module (boundary.md §9.2, *A runtime module*;
// `plans/runtime-in-beni.md`): an instance's nodes, templates, slots, a
// block's mount and patch, the render loop and the mount, the `Html`,
// `Maybe Html` and `List Html` holes, a text hole's node, the attribute
// writes, the class and style lists, the markup primitives `text` and
// `map`, the events — the delegated listener, `delegate`, `start`, `listen`
// and `identity` — and the lists and conditionals: `forKeyed`,
// `forPosition`, `show` and `hide`. Both are compiled with the program, and
// only what a page reaches is written.
//
// Parts of `Rt.beni` are ported from dom-expressions' client runtime (MIT,
// © Ryan Carniato; references/dom-expressions/packages/runtime/src):
// `template` from client.js `template`, the class and style diffs from
// `className` and `style`, the delegated listener from `eventHandler`, and
// `reconcile` from reconcile.js (udomdiff) with its slot ownership tags
// removed, since every node here has one owning slot.

// ---- Attributes (backend.md §15.3, §15.6) --------------------------------

// Elm's rule: a URL whose scheme is `javascript:`, or `data:text/html`,
// with any whitespace or control character where a browser ignores one,
// runs script, so it is written as nothing. It stays here: `Js` writes no
// regular expression literal, and the one function has nothing a page could
// specialise (`plans/runtime-in-beni.md`, step 2).
const scriptUrl =
  /^[\s\x00-\x20]*(j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t\s*:|d\s*a\s*t\s*a\s*:\s*t\s*e\s*x\s*t\s*\/\s*h\s*t\s*m\s*l\s*[,;])/i;
export const safeUrl = (url) => (scriptUrl.test(url) ? "" : url);
