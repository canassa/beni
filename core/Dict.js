// Ordered storage, private to core/Dict (backend.md §4, Ordered dictionaries).
// `entries` holds the [key, value] pairs in insertion order; `index` maps a
// key to its pair, so a lookup and a replacement touch no position and a
// removal rewrites no later one. Iteration walks `entries` directly.
export const empty = () => ({ entries: [], index: new Map() });
export const singleton = (k, v) => {
  const pair = [k, v];
  return { entries: [pair], index: new Map([[k, pair]]) };
};
export const size = (d) => d.entries.length;
export const has = (d, k) => d.index.has(k);
export const valueFor = (d, k) => d.index.get(k)[1];
export const keyIndex = (d, i) => d.entries[i][0];
export const isIndex = (d, i) => Number.isInteger(i) && i >= 0 && i < d.entries.length;
export const valueAt = (d, i) => d.entries[i][1];
export const traverseAt = (d, i) => d.entries[i][1];
export const keySame = (a, b) => a === b;
export const same = (a, b) => a === b;
export const insert = (d, k, v) => {
  const pair = d.index.get(k);
  if (pair === undefined) {
    const fresh = [k, v];
    d.index.set(k, fresh);
    d.entries.push(fresh);
  } else {
    pair[1] = v;
  }
  return d;
};
export const remove = (d, k) => {
  const pair = d.index.get(k);
  if (pair !== undefined) {
    d.entries.splice(d.entries.indexOf(pair), 1);
    d.index.delete(k);
  }
  return d;
};
export const copy = (d) => {
  const entries = [];
  const index = new Map();
  for (let i = 0; i < d.entries.length; i++) {
    const pair = [d.entries[i][0], d.entries[i][1]];
    entries.push(pair);
    index.set(pair[0], pair);
  }
  return { entries, index };
};
export const swap = (d, a, b) => {
  const p = d.index.get(a);
  const q = d.index.get(b);
  if (p !== undefined && q !== undefined && p !== q) {
    const i = d.entries.indexOf(p);
    const j = d.entries.indexOf(q);
    d.entries[i] = q;
    d.entries[j] = p;
  }
  return d;
};
export const insertAt = (d, at, k, v) => {
  const old = d.index.get(k);
  if (old !== undefined) d.entries.splice(d.entries.indexOf(old), 1);
  // `at > 0` is false for NaN, which an Int can be: it clamps to 0.
  const i = at > 0 ? Math.min(at, d.entries.length) : 0;
  const pair = [k, v];
  d.entries.splice(i, 0, pair);
  d.index.set(k, pair);
  return d;
};
export const permute = (d, keys) => {
  // sortBy supplies a complete permutation; read through Lists protocol.
  const ks = Array.isArray(keys) ? keys : keys.$plain();
  for (let i = 0; i < ks.length; i++) d.entries[i] = d.index.get(ks[i]);
  return d;
};
