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
// - A plain array loses its elements, and its `length` becomes the written
//   list's: JavaScript makes an array's `length` non-configurable, so it
//   cannot throw, but it can say what an in-place write would have left
//   there. A stale read of the length alone (`List.length`, a pattern's
//   `[]` or `[ _, …_ ]` test) then answers what the in-place run answers,
//   and the program's output differs from its golden; a read past it traps.
//   Each index is a hole, and a hole is read from the prototype, which is a
//   proxy that throws. So does every method the array is read through
//   (`slice`, `concat`, the iterator).
// - A view's own properties throw, `length` included, and its base array is
//   poisoned as well: a view aliases its base's cells.
// - A trie header's own properties throw, and so do its tree's (`T`), the
//   head, the tail, the plain copy `p` and the tree's root array. Another
//   list over that storage — `List.drop` of a trie is a header over the same
//   `T`, or a new `T` over the same root, head and tail, and a loop holds
//   `p` — aliases the trie, so its read after the write is stale, and every
//   way into the storage passes one of those. A writer's result never shares
//   them: it is built from the copy. Poisoning them is O(1); the nodes and
//   leaves below the root are left alone, since only the root reaches them.
//   An empty tree (`tc` 0) may be `core/List`'s one shared `noTree`, and
//   holds nothing, so it is never poisoned.

const stale = (site, what) => {
  throw new Error(`beni: a stale read of a list (${what}), which ${site} changed in place`);
};

const trap = (site) =>
  new Proxy(Object.create(null), {
    get: (_, key) => stale(site, `read ${String(key)}`),
    has: (_, key) => stale(site, `test ${String(key)}`),
  });

const poisonArray = (a, site, n = a.length) => {
  a.length = 0;
  a.length = n;
  Object.setPrototypeOf(a, trap(site));
};

const poisonObject = (o, site) => {
  for (const key of Reflect.ownKeys(o)) {
    Object.defineProperty(o, key, { get: () => stale(site, `read ${String(key)}`), configurable: false });
  }
};

// `n`: the written list's length, which a plain base takes.
const poison = (xs, site, n) => {
  if (Array.isArray(xs)) return poisonArray(xs, site, n);
  // Every part is read before any is poisoned.
  const view = xs.o !== undefined;
  const { b, p, h, t, T } = xs;
  poisonObject(xs, site);
  for (const a of view ? [b, p] : [h, t, p]) if (Array.isArray(a)) poisonArray(a, site);
  if (!view && T !== undefined && T.tc > 0) {
    const { r } = T;
    poisonObject(T, site);
    if (Array.isArray(r)) poisonArray(r, site);
  }
};

const own = (a) => (Array.isArray(a) ? a.slice() : a);

// The list a write runs on: a fresh copy of `xs` that shares none of the
// storage `poison` poisons. A plain array or a view is copied whole. A trie is
// copied as its header, head, tail, tree and root, O(32): the nodes below the
// root are shared, which no writer writes (they path-copy), and which
// `poison` leaves alone.
const fresh = (xs) => {
  if (Array.isArray(xs)) return xs.slice();
  if (xs.o !== undefined || xs.T === undefined) return xs.$plain().slice();
  const { length, h, hc, T, t, $plain } = xs;
  const tree = T.tc > 0 ? { r: own(T.r), s: T.s, off: T.off, tc: T.tc } : T;
  return { length, h: own(h), hc, T: tree, t: own(t), p: null, $plain };
};

// `List.<writer>(base, …rest)` under the sanitiser: `site` names the write.
// A base already poisoned traps here, where the copy reads it.
export const list = (site, writer, base, ...rest) => {
  const copy = fresh(base);
  const result = writer(copy, ...rest);
  poison(base, site, result.length);
  return result;
};

// A writer handed on as a value (`apply List.push xs`): each call of it is a
// write under the sanitiser.
export const writer = (site, f) => (base, ...rest) => list(site, f, base, ...rest);
