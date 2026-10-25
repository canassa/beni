// The stale-read sanitiser for lists (docs/design/ownership-v2.md §7.3). The
// compiler writes this file as `_core/_sanitize.mjs` only under the hidden,
// test-only `--sanitize-lists`, and only when a module it wrote imports it.
//
// An accepted list write is copy-and-poison. The writer runs on a fresh plain
// copy of its base, and when it returns, the old base is made a value whose
// every read throws. A holder older than the write then holds the old list, and
// it traps where it reads it, which is exactly a read that an in-place write
// would make stale. The writer's other operands, and every read its callback
// makes, run before the poison, as they run before the store of an in-place
// write. A program that runs clean under it reads no old version of any list
// it writes, so its in-place run prints the same.
//
// A list is a plain array, a view `{ b, o, length, p, $plain }` or a trie
// header `{ length, h, hc, T, t, p, $plain }` (`core/List.beni`).
//
// - A plain array loses its elements and keeps its `length`: JavaScript makes
//   an array's `length` non-configurable, so it cannot throw. Each index is a
//   hole, and a hole is read from the prototype, which is a proxy that throws.
//   So does every method the array is read through (`slice`, `concat`, the
//   iterator).
// - A view's own properties throw, `length` included, and its base array is
//   poisoned as well: a view aliases its base's cells.
// - A trie header's own properties throw, and so does every array of its
//   storage: the head, the tail, the plain copy `p` and each node and leaf of
//   its tree, down to the elements, which are left alone. Another list over
//   those arrays — `List.drop` of a trie is a header over the same ones, and a
//   loop holds `p` — aliases the trie, so its read after the write is stale.
//   A writer's result never shares them: it is built from the copy.

const stale = (site, what) => {
  throw new Error(`beni: a stale read of a list (${what}), which ${site} changed in place`);
};

const trap = (site) =>
  new Proxy(Object.create(null), {
    get: (_, key) => stale(site, `read ${String(key)}`),
    has: (_, key) => stale(site, `test ${String(key)}`),
  });

const poisonArray = (a, site) => {
  const n = a.length;
  a.length = 0;
  a.length = n;
  Object.setPrototypeOf(a, trap(site));
};

const poisonObject = (o, site) => {
  for (const key of Reflect.ownKeys(o)) {
    Object.defineProperty(o, key, { get: () => stale(site, `read ${String(key)}`), configurable: false });
  }
};

// A tree node at shift `s` (`core/List.beni`'s `leafAt`): above 0 its
// children are nodes, at 0 it is a leaf of elements.
const poisonNode = (node, s, site) => {
  if (!Array.isArray(node)) return;
  if (s > 0) for (const child of node) poisonNode(child, s - 5, site);
  poisonArray(node, site);
};

const poison = (xs, site) => {
  if (Array.isArray(xs)) return poisonArray(xs, site);
  // Every part is read before any is poisoned.
  const view = xs.o !== undefined;
  const { b, p, h, t, T } = xs;
  poisonObject(xs, site);
  for (const a of view ? [b, p] : [h, t, p]) if (Array.isArray(a)) poisonArray(a, site);
  if (!view && T !== undefined) {
    const { r, s } = T;
    poisonObject(T, site);
    poisonNode(r, s, site);
  }
};

// `List.<writer>(base, …rest)` under the sanitiser: `site` names the write.
// A base already poisoned traps here, where the copy reads it.
export const list = (site, writer, base, ...rest) => {
  const copy = (Array.isArray(base) ? base : base.$plain()).slice();
  const result = writer(copy, ...rest);
  poison(base, site);
  return result;
};

// A writer handed on as a value (`apply List.push xs`): each call of it is a
// write under the sanitiser.
export const writer = (site, f) => (base, ...rest) => list(site, f, base, ...rest);
