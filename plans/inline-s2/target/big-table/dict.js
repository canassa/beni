
export const just = (a) => ({ $: 0, a });
export const nothing = { $: 1, a: null };
export const empty = () => ({ entries: [], index: new Map() });
export const size = (d) => d.entries.length;
export const member = (d, k) => d.index.has(k);
export const keyAt = (d, i) => (i < d.entries.length ? just(d.entries[i][0]) : nothing);
export function insert(d, k, v) { const e = d.index.get(k); if (e) e[1] = v; else { const n = [k, v]; d.entries.push(n); d.index.set(k, n); } return d; }
export function remove(d, k) { const e = d.index.get(k); if (e) { d.entries.splice(d.entries.indexOf(e), 1); d.index.delete(k); } return d; }
export function swap(d, a, b) {
  const x = d.index.get(a), y = d.index.get(b);
  if (x && y) { const e = d.entries, p = e.indexOf(x), q = e.indexOf(y); e[p] = y; e[q] = x; }
  return d;
}
export function update(d, k, f) { const e = d.index.get(k), r = f(e ? just(e[1]) : nothing); return r.$ === 0 ? insert(d, k, r.a) : remove(d, k); }
export function filter(d, f) { const r = empty(); for (const [k, v] of d.entries) if (f(k, v)) insert(r, k, v); return r; }
export function fromList(l) { const d = empty(); for (const [k, v] of l) insert(d, k, v); return d; }
export function foldl(d, a, f) { for (const [k, v] of d.entries) a = f(k, v, a); return a; }
export function keys(d) { return d.entries.map((e) => e[0]); }
export function sortBy(d, c, f) { const t = d.entries.map((e) => [f(e[0], e[1]), e]); t.sort((a, b) => c(a[0], b[0])); d.entries = t.map((x) => x[1]); return d; }
