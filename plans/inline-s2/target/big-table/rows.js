// The keyed rows of a Dict (S2 target, pair index): R in the Dict's order, M from key to row.
export const tpl = (html) => { const t = document.createElement("template"); t.innerHTML = html; return t.content.firstChild; };
export function list(parent, get, build) {
  let R = [], M = new Map();
  const make = (k, v) => { const r = build(k, v); r.k = k; r.v = v; r[1](v); M.set(k, r); return r; };
  const L = (all) => {
    const E = get().entries, old = M, N = [];
    let kept = 0;
    M = new Map();
    R.forEach((r, i) => { r.p = i; });
    for (const [k, v] of E) {
      let r = old.get(k);
      if (r) { kept++; old.delete(k); M.set(k, r); if (all || r.v !== v) { r.v = v; r[1](v); } } else r = make(k, v);
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
  // After insert, remove or update of k (an existing key never moves; a new one is appended).
  L.at = (k) => {
    const e = get().index.get(k), r = M.get(k);
    if (!e) { if (r) { R.splice(R.indexOf(r), 1); M.delete(k); r[0].remove(); } }
    else if (r) { r.v = e[1]; r[1](r.v); }
    else { const n = make(k, e[1]); R.push(n); parent.append(n[0]); }
  };
  L.swap = (a, b) => {
    let A = M.get(a), B = M.get(b);
    if (!A || !B || A === B) return;
    let x = R.indexOf(A), y = R.indexOf(B);
    if (x > y) { [x, y] = [y, x]; [A, B] = [B, A]; }
    const n = B[0].nextSibling;
    R[x] = B; R[y] = A;
    parent.insertBefore(B[0], A[0]);
    parent.insertBefore(A[0], n);
  };
  return L;
}
