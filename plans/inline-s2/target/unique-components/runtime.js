// The tea-inline runtime: what every compiled app shares, whatever it contains.
//
// - DOM helpers: elements built once, then bindings write text and properties
//   only when the value differs.
// - Batching: actions schedule bindings; one microtask flush runs each scheduled binding once.
// - Conditional blocks (`when`) and keyed lists (`list`), the only structural changes.

// ---------------------------------------------------------------------------------------------
// Batching

let pending = new Set();
let done = null;

// Schedule bindings: functions, or (nested) arrays of them. `undefined` entries are skipped,
// so a widget nobody reads can pass its empty `readers`.
export function schedule(...work) {
  for (const f of work.flat(Infinity)) if (f) pending.add(f);
  done ||= Promise.resolve().then(flush);
}

// Run every scheduled binding once (bindings scheduled meanwhile run in the same flush).
export function flush() {
  done = null;
  for (const f of pending) {
    pending.delete(f);
    f();
  }
}

// Resolved once the DOM reflects everything scheduled so far.
export function settled() {
  return Promise.resolve(done);
}

// Drop pending work (on unmount).
export function cancel() {
  pending.clear();
}

// ---------------------------------------------------------------------------------------------
// DOM

// A new element with its static attributes and text, appended to `parent` when given.
export function el(tag, parent, attrs, content) {
  const node = document.createElement(tag);
  for (const k in attrs) node.setAttribute(k, attrs[k]);
  if (content != null) node.textContent = content;
  parent?.append(node);
  return node;
}

export function text(node, value) {
  value = String(value);
  if (node.textContent !== value) node.textContent = value;
}

// A live property: a form control's value unless `key` names another (checked, disabled, or a
// reflected ARIA state: ariaPressed, …).
export function prop(node, value, key = "value") {
  if (node[key] !== value) node[key] = value;
}

// A listener: for clicks unless `type` says otherwise.
export function on(node, handler, type = "click") {
  node.addEventListener(type, handler);
}

// A conditional block: `node`, built once in place, swaps with an empty text node (made on first
// use and kept on the node) to hide it. `when(node, cond)` puts whichever should be in the page in
// the place of the other (a no-op when it already is: `replaceWith` does nothing on a node out of
// the page).
export function when(node, cond) {
  const anchor = (node.anchor ||= new Text());
  (cond ? anchor : node).replaceWith(cond ? node : anchor);
}


export const tpl = (html) => { const t = document.createElement("template"); t.innerHTML = html; return t.content.firstChild; };
export const just = (a) => ({ $: 0, a });
export const nothing = { $: 1, a: null };
export const empty = () => ({ entries: [], index: new Map() });
export const size = (d) => d.entries.length;
export const keyAt = (d, i) => (i >= 0 && i < d.entries.length ? just(d.entries[i][0]) : nothing);
export const count = (d, f) => { let n = 0; for (const e of d.entries) if (f(e[1])) n++; return n; };
export function insert(d, k, v) { const e = d.index.get(k); if (e) e[1] = v; else { const n = [k, v]; d.entries.push(n); d.index.set(k, n); } return d; }
export function remove(d, k) { const e = d.index.get(k); if (e) { d.entries.splice(d.entries.indexOf(e), 1); d.index.delete(k); } return d; }
export function update(d, k, f) { const e = d.index.get(k), r = f(e ? just(e[1]) : nothing); return r.$ === 0 ? insert(d, k, r.a) : remove(d, k); }
export function filter(d, f) { const r = empty(); for (const [k, v] of d.entries) if (f(k, v)) insert(r, k, v); return r; }
export function fromList(l) { const d = empty(); for (const [k, v] of l) insert(d, k, v); return d; }
export function list(parent, get, build) {
  let R = [], M = new Map(), last;
  const make = (k, v) => { const r = build(k, v); r.k = k; r.v = v; r[1](v); M.set(k, r); return r; };
  const L = () => {
    const d = get();
    if (d === last) return;
    last = d;
    const old = M, N = [];
    let kept = 0;
    M = new Map();
    R.forEach((r, i) => { r.p = i; });
    for (const [k, v] of d.entries) {
      let r = old.get(k);
      if (r) { kept++; old.delete(k); M.set(k, r); if (r.v !== v) { r.v = v; r[1](v); } } else r = make(k, v);
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
    const e = get().index.get(k), r = M.get(k);
    if (!e) { if (r) { R.splice(R.indexOf(r), 1); M.delete(k); r[0].remove(); } }
    else if (r) { r.v = e[1]; r[1](r.v); }
    else { const n = make(k, e[1]); R.push(n); parent.append(n[0]); }
  };
  return L;
}
