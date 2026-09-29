// The sibling JavaScript of `Browser.beni` (docs/design/boundary.md §4): a
// program is an array of mounts, `{ a, n }` — the record it was given, and
// the id of the element it mounts at or null for `document.body` — which
// only the platform's runtime reads.

export const program = (p) => [{ a: p, n: null }];

export const mountAt = (program, id) => program.map((m) => ({ a: m.a, n: id }));

export const programs = (list) => {
  const all = [];
  for (let at = list; at.$ === 1; at = at.b) for (const m of at.a) all.push(m);
  return all;
};
