
export const just = (a) => ({ $: 0, a });
export const nothing = { $: 1, a: null };
export const empty = () => ({ entries: [], index: new Map() });
export const size = (d) => d.entries.length;
export const member = (d, k) => d.index.has(k);
export const keyAt = (d, i) => (i < d.entries.length ? just(d.entries[i][0]) : nothing);
export function insert(d, k, v) {
  const p = d.index.get(k);
  if (p === undefined) { d.index.set(k, d.entries.length); d.entries.push([k, v]); } else d.entries[p][1] = v;
  return d;
}
export function remove(d, k) {
  let p = d.index.get(k);
  if (p !== undefined) {
    const e = d.entries;
    e.splice(p, 1);
    d.index.delete(k);
    for (; p < e.length; p++) d.index.set(e[p][0], p);
  }
  return d;
}
export function swap(d, a, b) {
  const p = d.index.get(a), q = d.index.get(b);
  if (p !== undefined && q !== undefined) { const e = d.entries, t = e[p]; e[p] = e[q]; e[q] = t; d.index.set(a, q); d.index.set(b, p); }
  return d;
}
export function update(d, k, f) {
  const p = d.index.get(k), r = f(p === undefined ? nothing : just(d.entries[p][1]));
  return r.$ === 0 ? insert(d, k, r.a) : remove(d, k);
}
export function filter(d, f) { const r = empty(); for (const [k, v] of d.entries) if (f(k, v)) insert(r, k, v); return r; }
export function fromList(l) { const d = empty(); for (const [k, v] of l) insert(d, k, v); return d; }
export function foldl(d, a, f) { for (const [k, v] of d.entries) a = f(k, v, a); return a; }
export function keys(d) { return d.entries.map((e) => e[0]); }
export function sortBy(d, c, f) {
  const t = d.entries.map((e) => [f(e[0], e[1]), e]);
  t.sort((a, b) => c(a[0], b[0]));
  d.entries = t.map((x) => x[1]);
  d.index.clear();
  d.entries.forEach((e, i) => d.index.set(e[0], i));
  return d;
}
