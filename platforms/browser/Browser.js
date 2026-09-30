// The sibling JavaScript of `Browser.beni` (docs/design/boundary.md §4): a
// program is an array of mounts, `{ a, n, k, h }` — the record it was
// given, the id of the element it mounts at or null for `document.body`,
// 1 for a `hosted` program and 0 for a plain one, and `attach` — which
// only the platform's runtime reads.
//
// A sibling may not import another file (backend.md §2), so this one
// reaches the render loop the one way it can: `run` hands every mount's
// `h` the loop before it mounts anything (backend.md §15.11), and `flush`
// and `onRendered` call it. Before a program runs there is no loop, and
// there is nothing to render.

let loop = null;

const attach = (l) => {
  loop = l;
};

export const program = (p) => [{ a: p, n: null, k: 0, h: attach }];

export const hosted = (p) => [{ a: p, n: null, k: 1, h: attach }];

export const mountAt = (program, id) => program.map((m) => ({ a: m.a, n: id, k: m.k, h: m.h }));

export const programs = (list) => {
  const all = [];
  for (let at = list; at.$ === 1; at = at.b) for (const m of at.a) all.push(m);
  return all;
};

export const flush = (unit) => {
  if (loop !== null) loop.flush();
  return null;
};

export const onRendered = (resume) => {
  if (loop === null) {
    resume(null);
    return null;
  }
  return loop.rendered(resume);
};
