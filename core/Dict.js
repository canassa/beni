// Ordered storage, private to core/Dict (backend.md §4, Ordered dictionaries).
// Map holds positions; iteration reads the key/value entry pairs directly.
export const empty = () => ({ entries: [], index: new Map() });
export const singleton = (k, v) => ({ entries: [[k, v]], index: new Map([[k, 0]]) });
export const size = (d) => d.entries.length;
export const position = (d, k) => {
  const i = d.index.get(k);
  return i === undefined ? -1 : i;
};
export const keyAt = (d, i) => d.entries[i][0];
export const valueAt = (d, i) => d.entries[i][1];
export const traverseAt = (d, i) => d.entries[i][1];
export const keySame = (a, b) => a === b;
export const same = (a, b) => a === b;
export const insert = (d, k, v) => {
  const i = d.index.get(k);
  if (i === undefined) {
    d.index.set(k, d.entries.length);
    d.entries.push([k, v]);
  } else {
    d.entries[i][1] = v;
  }
  return d;
};
export const remove = (d, k) => {
  const i = d.index.get(k);
  if (i !== undefined) {
    d.entries.splice(i, 1);
    d.index.delete(k);
    for (let j = i; j < d.entries.length; j++) d.index.set(d.entries[j][0], j);
  }
  return d;
};
export const copy = (d) => {
  const entries = [];
  for (let i = 0; i < d.entries.length; i++) entries.push([d.entries[i][0], d.entries[i][1]]);
  return { entries, index: new Map(d.index) };
};
export const swap = (d, a, b) => {
  const i = d.index.get(a), j = d.index.get(b);
  if (i !== undefined && j !== undefined && i !== j) {
    const entry = d.entries[i];
    d.entries[i] = d.entries[j];
    d.entries[j] = entry;
    d.index.set(a, j);
    d.index.set(b, i);
  }
  return d;
};
export const insertAt = (d, at, k, v) => {
  const old = d.index.get(k);
  if (old !== undefined) d.entries.splice(old, 1);
  const i = Math.max(0, Math.min(at, d.entries.length));
  d.entries.splice(i, 0, [k, v]);
  for (let j = old === undefined ? i : Math.min(old, i); j < d.entries.length; j++) d.index.set(d.entries[j][0], j);
  return d;
};
export const permute = (d, keys) => {
  // sortBy supplies a complete permutation; read through Lists protocol.
  const ks = Array.isArray(keys) ? keys : keys.$plain();
  const entries = [];
  for (let i = 0; i < ks.length; i++) entries.push(d.entries[d.index.get(ks[i])]);
  for (let i = 0; i < entries.length; i++) {
    d.entries[i] = entries[i];
    d.index.set(entries[i][0], i);
  }
  return d;
};
