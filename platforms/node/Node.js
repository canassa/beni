// The sibling JavaScript of `Node.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name, and nothing else.
//
// A `Program` is marshalled to plain data — `{ code, out }` — and never
// holds a reference to anything of Node's. That is §4.1's first two rules,
// and it is what lets `runtime.js` be the only file that touches the host.

const spine = (list) => {
  const items = [];
  for (let at = list; at.$ === 1; at = at.b) items.push(at.a);
  return items;
};

export const print = (line) => ({ code: 0, out: `${line}\n` });

export const printLines = (lines) => {
  const items = spine(lines);
  return { code: 0, out: items.length === 0 ? "" : `${items.join("\n")}\n` };
};

export const exitWith = (code, line) => ({ code, out: `${line}\n` });
