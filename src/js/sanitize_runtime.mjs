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
  const header = xs.$h;
  if (header === undefined) {
    const base = xs.b;
    poisonObject(xs, site);
    return poisonArray(base, site);
  }
  // Read every alias before installing any of its traps. The token is
  // shared runtime metadata and is never poisoned.
  const cache = header.cache, tail = header.tail, root = header.root;
  const arrays = [cache.flat, tail.values];
  if (header.treeCount > 0) arrays.push(root.a);
  poisonObject(xs, site);
  for (const array of arrays) if (Array.isArray(array)) poisonArray(array, site);
  const objects = [header, cache, tail];
  if (header.treeCount > 0) objects.push(root);
  for (const object of objects) poisonObject(object, site);
};

const fresh = (xs) => {
  if (Array.isArray(xs)) return xs.slice();
  return xs.$h !== undefined ? xs.$plain().slice() : xs.b.slice(xs.o);
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
