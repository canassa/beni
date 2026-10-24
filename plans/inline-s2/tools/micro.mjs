// Micro-benchmark of one remove near the front of 1000 entries: Dict (entries + index, eager reindex) vs array splice, and the row lookup.
const N = 1000, REPS = 20000;
const mk = () => { const entries = [], index = new Map(); for (let i = 0; i < N; i++) { entries.push([i + 1, { id: i + 1 }]); index.set(i + 1, i); } return { entries, index }; };
function remove(d, k) { let p = d.index.get(k); if (p !== undefined) { const e = d.entries; e.splice(p, 1); d.index.delete(k); for (; p < e.length; p++) d.index.set(e[p][0], p); } }
function insertBack(d, k, v, at) { d.entries.splice(at, 0, [k, v]); for (let p = at; p < d.entries.length; p++) d.index.set(d.entries[p][0], p); }
const t = (name, f) => { for (let i = 0; i < 2000; i++) f(); const s = performance.now(); for (let i = 0; i < REPS; i++) f(); console.log(name, ((performance.now() - s) / REPS * 1000).toFixed(2), "µs"); };
{ const d = mk(); t("Dict.remove(4th) + reinsert (both reindex)", () => { const v = d.entries[3][1]; remove(d, 4); insertBack(d, 4, v, 3); }); }
{ const a = Array.from({ length: N }, (_, i) => ({ id: i + 1 })); t("array findIndex+splice(4th) + reinsert", () => { const i = a.findIndex((x) => x.id === 4); const v = a.splice(i, 1)[0]; a.splice(3, 0, v); }); }
{ const R = Array.from({ length: N }, (_, i) => ({ k: i + 1 })); t("rows findIndex (4th) + splice + reinsert", () => { const i = R.findIndex((r) => r.k === 4); const r = R.splice(i, 1)[0]; R.splice(3, 0, r); }); }
{ const R = Array.from({ length: N }, (_, i) => ({ k: i + 1 })); t("rows findIndex (last)", () => R.findIndex((r) => r.k === N)); }
// Variant: index maps key -> its pair; a removal finds the pair's position with a native indexOf.
{
  const entries = [], index = new Map();
  for (let i = 0; i < N; i++) { const e = [i + 1, { id: i + 1 }]; entries.push(e); index.set(i + 1, e); }
  t("pair-index remove(4th) + reinsert", () => { const e = index.get(4); entries.splice(entries.indexOf(e), 1); index.delete(4); entries.splice(3, 0, e); index.set(4, e); });
  t("pair-index position of the last key (indexOf)", () => entries.indexOf(index.get(N)));
}
{
  const N2 = 10000, entries = [], index = new Map();
  for (let i = 0; i < N2; i++) { entries.push([i + 1, {}]); index.set(i + 1, i); }
  t("10k: Dict.remove(4th) + reinsert (eager reindex)", () => { const v = entries[3]; let p = 3; entries.splice(p, 1); index.delete(4); for (; p < entries.length; p++) index.set(entries[p][0], p); entries.splice(3, 0, v); for (p = 3; p < entries.length; p++) index.set(entries[p][0], p); });
}
