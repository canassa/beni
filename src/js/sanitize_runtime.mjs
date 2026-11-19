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
//   there. A read of the length that a foreign sibling makes then answers
//   what the in-place run answers, and the program's output differs from its
//   golden; a read past it traps. Every length read the compiler lowers
//   (`List.length`, a pattern's `[]` or `[ _, …_ ]` test) goes through
//   `len`, which traps on a poisoned plain array.
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
//
// A poisoned list traps where it is read, but `===` reads nothing. So each
// write also links its base to what it answered, and `same`, which `Js.same`
// outside core lowers to, traps where the two operands are distinct here and
// one object in place (research report 140): a value kept from before an
// in-place write compares equal to the written list there, and the program
// would decide otherwise.

const stale = (site, what) => {
  throw new Error(`beni: a stale read of a list (${what}), which ${site} changed in place`);
};

const trap = (site) =>
  new Proxy(Object.create(null), {
    get: (_, key) => stale(site, `read ${String(key)}`),
    has: (_, key) => stale(site, `test ${String(key)}`),
  });

// The site that made each poisoned plain array stale, for `len`.
const staleSites = new WeakMap();

// The identity trap (research report 140). In place, a write answers its
// base: the old list and the new are one object. Here they are two, so an
// identity compare of the two answers what no in-place run answers. Each
// written base that is not a view (a view is never written in place: its
// write makes a new array) is linked to what its write answered, with the
// site; `same` follows the links to the list each operand is now, in place.
const successors = new WeakMap();

const latest = (v) => {
  while (typeof v === "object" && v !== null && successors.has(v)) v = successors.get(v).next;
  return v;
};

const poisonArray = (a, site, n = a.length) => {
  staleSites.set(a, site);
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

// Dictionaries and sets (`ownership-v3-kernel.md` §12): a `Dict` is a header
// `{ entries, index }` (`core/Dict.js`), and a `Set` is a box around one
// (a constructor's object, or, unboxed, the header itself). A site names a
// writer of `Dict` or `Set` by its first word.
const keyedSite = (site) => /^`(Dict|Set)\./.test(site);

const isHeader = (x) => typeof x === "object" && x !== null && x.index instanceof Map && Array.isArray(x.entries);

// The header a dictionary or a set holds.
const headerOf = (x) => {
  if (isHeader(x)) return x;
  for (const key of Reflect.ownKeys(x)) if (isHeader(x[key])) return x[key];
  throw new Error("beni: the sanitiser met a dictionary it cannot read");
};

const cloneHeader = (d) => {
  const entries = d.entries.map((pair) => [pair[0], pair[1]]);
  return { entries, index: new Map(entries.map((pair) => [pair[0], pair])) };
};

// A fresh copy of a dictionary or a set: a writer run on it shares no
// storage with the base, which is poisoned after.
const freshKeyed = (x) => {
  if (isHeader(x)) return cloneHeader(x);
  const box = { ...x };
  for (const key of Reflect.ownKeys(box)) if (isHeader(box[key])) box[key] = cloneHeader(box[key]);
  return box;
};

// The old dictionary or set loses its storage: every read of it traps,
// where an in-place run would read what the write left.
const poisonKeyed = (x, site) => {
  const h = headerOf(x);
  const { entries } = h;
  poisonObject(h, site);
  poisonArray(entries, site);
  if (h !== x) poisonObject(x, site);
};

// `List.<writer>(base, …rest)` under the sanitiser: `site` names the write.
// A base already poisoned traps here, where the copy reads it.
export const list = (site, writer, base, ...rest) => settle(base, start(site, writer, base, ...rest), site);

// The first half of a write: the writer runs on a fresh copy. A write that
// may park (a suspendable twin, `name$s`) is lowered as `start`, the wait,
// then `settle` with the answer, so the base is poisoned once the writer
// is done, as an in-place store comes after its callback returns.
export const start = (site, writer, base, ...rest) => writer(keyedSite(site) ? freshKeyed(base) : fresh(base), ...rest);

// The second half: the old base poisoned, and linked to the answer.
export const settle = (base, result, site) => {
  if (keyedSite(site)) {
    poisonKeyed(base, site);
    successors.set(base, { next: result, site });
    return result;
  }
  const view = !Array.isArray(base) && base.o !== undefined;
  poison(base, site, result.length);
  if (!view) successors.set(base, { next: result, site });
  return result;
};

// `[ x, …xs, … ]`: an item before a construction's base. In place it goes
// in front of the base, so the answer is the base (`backend.md` §4,
// *Writes*); here it is a new list, linked to the written base's answer.
export const front = (x, xs, site) => {
  const result = [x, ...(Array.isArray(xs) ? xs : xs.$plain())];
  if (Array.isArray(xs) || xs.o === undefined) successors.set(xs, { next: result, site });
  return result;
};

// A writer handed on as a value (`apply List.push xs`): each call of it is a
// write under the sanitiser.
export const writer = (site, f) => (base, ...rest) => list(site, f, base, ...rest);

// `xs.length` under the sanitiser. A stale plain array answers its length
// without throwing, so a read of it that goes through here traps. A view or a
// trie header throws on its own.
export const len = (xs) => {
  if (Array.isArray(xs) && staleSites.has(xs)) stale(staleSites.get(xs), "read length");
  return xs.length;
};

// Records (research report 142). In place, an update writes its base's own
// object: every name the program kept of it is one object. Here an update
// makes a copy, so the objects of one in-place identity are one group, the
// newest last. A name older than the newest reads the newest's fields in
// place: each field whose value differs from the newest's is poisoned on it,
// so a read of it traps where an in-place run would read another value.
// `same` traps an identity compare of two members of one group.
const groups = new WeakMap();

export const record = (base, copy, site) => {
  let group = groups.get(base);
  if (group === undefined) {
    group = [base];
    groups.set(base, group);
  }
  for (const old of group) {
    for (const key of Reflect.ownKeys(copy)) {
      const d = Object.getOwnPropertyDescriptor(old, key);
      if (d === undefined || d.get !== undefined) continue;
      if (d.value === copy[key]) continue;
      Object.defineProperty(old, key, {
        get: () => {
          throw new Error(`beni: a stale read of a record (read ${String(key)}), which ${site} changed in place`);
        },
        configurable: false,
      });
    }
  }
  group.push(copy);
  groups.set(copy, group);
  return copy;
};

// `Js.same a b` outside core under the sanitiser: `a === b`, or a trap when
// an in-place run would answer otherwise, which is when the two are
// distinct here and one list in place: one was kept before a write that
// answered the other, or both were. A compare whose answer an in-place
// write cannot change answers as `===` does.
export const same = (a, b) => {
  if (a !== b && typeof a === "object" && a !== null && groups.has(a) && groups.get(a) === groups.get(b)) {
    throw new Error(`beni: an identity compare of a record that an update changed in place since it was kept`);
  }
  if (a !== b && typeof a === "object" && a !== null && latest(a) === latest(b)) {
    const kept = successors.has(a) ? a : b;
    throw new Error(`beni: an identity compare of a list that ${successors.get(kept).site} changed in place since it was kept`);
  }
  return a === b;
};
