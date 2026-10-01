// The sibling JavaScript of `Browser.beni` (docs/design/boundary.md §4): a
// program is an array of mounts, `{ a, n, h }` (`program`'s and `hosted`'s
// are made in beni, in `Browser.beni`) — the record it was given, the id of
// the element it mounts at or null for `document.body`, and for a `hosted`
// program the function that turns it into a record the platform's runtime
// mounts — which only the runtime reads. The hosted loop is `Browser.beni`'s
// too (`plans/runtime-in-beni.md`).

export const mountAt = (program, id) => program.map((m) => ({ a: m.a, n: id, h: m.h }));

export const programs = (list) => {
  const all = [];
  const items = Array.isArray(list) ? list : list.$plain();
  for (let k = 0; k < items.length; k++) for (const m of items[k]) all.push(m);
  return all;
};
