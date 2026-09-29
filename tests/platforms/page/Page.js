// The sibling JavaScript of `Page.beni` (docs/design/boundary.md §4): a
// view is plain data, and only `runtime.js` touches the page.
//
// A `List` is read as every sibling reads one: cons cells, `$ === 1` for a
// cell with `a` its head and `b` its tail.

const spine = (list) => {
  const items = [];
  for (let at = list; at.$ === 1; at = at.b) items.push(at.a);
  return items;
};

export const element = (tag, attributes, children) => ({ tag, attributes: spine(attributes), children: spine(children) });

export const text = (data) => ({ tag: null, data });

export const attribute = (name, value) => ({ kind: "attribute", name, value });

export const value = (v) => ({ kind: "value", value: v });

export const onClick = (msg) => ({ kind: "on", name: "click", handler: () => msg });

export const onInput = (toMsg) => ({ kind: "on", name: "input", handler: (event) => toMsg(event.target.value) });

export const onKeyDown = (toMsg) => ({ kind: "on", name: "keydown", handler: (event) => toMsg(event.key) });

export const show = (view) => ({ init: null, update: null, view: () => view });

export const sandbox = (program) => ({ init: program.init, update: program.update, view: program.view });
