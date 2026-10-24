// The keyed rows of a Dict (S2 target).
export const tpl = (html) => { const t = document.createElement("template"); t.innerHTML = html; return t.content.firstChild; };
export function list(parent, get, build) {
  let R = [];
  
  const make = (k, v) => { const r = build(k, v); r.k = k; r.v = v; r[1](v); return r; };
  const L = (all) => {
    const E = get().entries, old = new Map(), N = [];
    let kept = 0;
    R.forEach((r, i) => { r.p = i; old.set(r.k, r); });
    for (const [k, v] of E) {
      let r = old.get(k);
      if (r) { kept++; old.delete(k); if (all || r.v !== v) { r.v = v; r[1](v); } } else r = make(k, v);
      N.push(r);
    }
    R = N;
    if (!kept) { const f = new DocumentFragment(); for (const r of N) f.append(r[0]); parent.replaceChildren(f); return; }
    for (const r of old.values()) r[0].remove();
    const P = N.map((r) => r.p ?? -1), t = [], prev = [], stay = [];
    P.forEach((x, i) => {
      if (x < 0) return;
      let lo = 0, hi = t.length;
      while (lo < hi) { const m = (lo + hi) >> 1; P[t[m]] < x ? (lo = m + 1) : (hi = m); }
      prev[i] = lo ? t[lo - 1] : -1;
      t[lo] = i;
    });
    for (let i = t[t.length - 1]; i >= 0; i = prev[i]) stay[i] = 1;
    let next = null;
    for (let i = N.length; i--; ) { const n = N[i][0]; if (!stay[i]) parent.insertBefore(n, next); next = n; }
  };
  L.at = (k) => {
    const d = get(), j = d.index.get(k);
    if (j === undefined) { const i = R.findIndex((r) => r.k === k); if (i >= 0) R.splice(i, 1)[0][0].remove(); }
    else if (R[j]?.k === k) { const r = R[j]; r.v = d.entries[j][1]; r[1](r.v); }
    else if (j === R.length && d.entries.length === j + 1) { const n = make(k, d.entries[j][1]); R.push(n); parent.append(n[0]); }
    else {
      const i = R.findIndex((r) => r.k === k), v = d.entries[j][1];
      let r;
      if (i < 0) r = make(k, v); else { r = R.splice(i, 1)[0]; r.v = v; r[1](v); }
      parent.insertBefore(r[0], R[j]?.[0] ?? null);
      R.splice(j, 0, r);
    }
  };
  L.swap = (a, b) => {
    const d = get();
    let x = d.index.get(a), y = d.index.get(b);
    if (x === undefined || y === undefined || x === y) return;
    if (x > y) [x, y] = [y, x];
    const A = R[x], B = R[y], n = B[0].nextSibling;
    R[x] = B; R[y] = A;
    parent.insertBefore(B[0], A[0]);
    parent.insertBefore(A[0], n);
  };

  return L;
}
