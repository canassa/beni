// The sibling JavaScript of `Dict.beni` (docs/design/boundary.md §4): the
// ordered storage of `backend.md` §4, *Ordered dictionaries*. A dictionary is
// `{ entries, index }`: `entries` holds private `[key, value]` pairs in
// insertion order, and `index` maps each key to its pair, so a lookup or a
// replacement touches no position and a removal rewrites no later one.
// Keys are `Int` or `String`, which `Map` compares by value (SameValueZero:
// `-0` and `0` are one key). Nothing here can fail, so nothing catches.
//
// The public writers copy: they answer new storage and leave their
// argument as it was. A write that the ownership checker v3 accepts is
// made the argument's own by the in-place oracle (`inplace_runtime.mjs`);
// no build writes a dictionary in place without that acceptance
// (`ownership-v3-kernel.md` §12). `put` and `permute` write in place, and
// only `Dict.beni`'s own loops call them, on storage those loops made.

const pairOf = (d, k) => d.index.get(k);

const cloned = (d) => {
  const entries = new Array(d.entries.length);
  const index = new Map();
  for (let i = 0; i < entries.length; i++) {
    const pair = [d.entries[i][0], d.entries[i][1]];
    entries[i] = pair;
    index.set(pair[0], pair);
  }
  return { entries, index };
};

export const empty = (_) => ({ entries: [], index: new Map() });
export const size = (d) => d.entries.length;
export const has = (d, k) => d.index.has(k);
export const valueFor = (d, k) => pairOf(d, k)[1];
export const keyIndex = (d, i) => d.entries[i][0];
export const isIndex = (d, i) => Number.isInteger(i) && i >= 0 && i < d.entries.length;
export const valueAt = (d, i) => d.entries[i][1];
export const traverseAt = (d, i) => d.entries[i][1];
export const keySame = (a, b) => a === b;
export const same = (a, b) => a === b;
export const copy = (d) => cloned(d);

// `put` on storage only `Dict.beni`'s loop that made it can see.
export const put = (d, k, v) => {
  const pair = pairOf(d, k);
  if (pair === undefined) {
    const fresh = [k, v];
    d.index.set(k, fresh);
    d.entries.push(fresh);
  } else {
    pair[1] = v;
  }
  return d;
};

export const insert = (d, k, v) => {
  const pair = pairOf(d, k);
  if (pair !== undefined && Object.is(pair[1], v)) return d;
  return put(cloned(d), k, v);
};

export const remove = (d, k) => {
  if (!d.index.has(k)) return d;
  const c = cloned(d);
  const pair = pairOf(c, k);
  c.entries.splice(c.entries.indexOf(pair), 1);
  c.index.delete(k);
  return c;
};

export const swap = (d, a, b) => {
  const p = pairOf(d, a);
  const q = pairOf(d, b);
  if (p === undefined || q === undefined || p === q) return d;
  const c = cloned(d);
  const i = d.entries.indexOf(p);
  const j = d.entries.indexOf(q);
  const x = c.entries[i];
  c.entries[i] = c.entries[j];
  c.entries[j] = x;
  return c;
};

export const insertAt = (d, at, k, v) => {
  const c = cloned(d);
  const old = pairOf(c, k);
  if (old !== undefined) c.entries.splice(c.entries.indexOf(old), 1);
  // `at > 0` is false for NaN, which an Int can be: it clamps to 0.
  const i = at > 0 ? Math.min(Math.trunc(at), c.entries.length) : 0;
  const pair = [k, v];
  c.entries.splice(i, 0, pair);
  c.index.set(k, pair);
  return c;
};

// The entries in the order `keys` names, a permutation of `d`'s keys that
// `sortBy` made. It copies, as the other public writers do.
export const permute = (d, keys) => {
  const ks = Array.isArray(keys) ? keys : keys.$plain();
  const c = cloned(d);
  for (let i = 0; i < ks.length; i++) c.entries[i] = c.index.get(ks[i]);
  return c;
};
