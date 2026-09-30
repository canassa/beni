// The sibling JavaScript of `Page.beni` (docs/design/boundary.md §4): a
// view is plain data, and only `runtime.js` touches the page.
//
// A `List` is read as every sibling reads one (backend.md §4's protocol):
// the array itself, or `$plain()` of a view or a trie. The view keeps a
// copy, which nothing else holds.

const spine = (list) => (Array.isArray(list) ? list : list.$plain()).slice();

export const element = (tag, attributes, children) => ({ tag, attributes: spine(attributes), children: spine(children) });

export const text = (data) => ({ tag: null, data });

export const attribute = (name, value) => ({ kind: "attribute", name, value });

export const value = (v) => ({ kind: "value", value: v });

export const onClick = (msg) => ({ kind: "on", name: "click", handler: () => msg });

export const onInput = (toMsg) => ({ kind: "on", name: "input", handler: (event) => toMsg(event.target.value) });

export const onKeyDown = (toMsg) => ({ kind: "on", name: "keydown", handler: (event) => toMsg(event.key) });

export const show = (view) => ({ init: null, update: null, view: () => view });

export const sandbox = (program) => ({ init: program.init, update: program.update, view: program.view });
