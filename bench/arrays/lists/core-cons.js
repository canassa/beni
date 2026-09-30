// Candidate A of research/38 §16, the cons list beni ships today. The scenarios run beni's own
// output unchanged against the compiled `core/List`; this file is only the harness's hooks, plus the
// lowering's `$` primitives over cons cells, which "A-via-calls" uses to check that lists.mjs's
// rewrite of the emitted code changes nothing but the representation.
export const $nil = { $: 0, a: null, b: null };
export const $isNil = (x) => x.$ === 0;
export const $isCons = (x) => x.$ === 1;
export const $hd = (x) => x.a;
export const $tl = (x) => x.b;
export const $cons = (h, t) => ({ $: 1, a: h, b: t });
export const $fromArray = (arr) => fromJs(arr);

export function fromJs(arr) { let l = $nil; for (let i = arr.length - 1; i >= 0; i--) l = { $: 1, a: arr[i], b: l }; return l; }
export function toJs(l) { const out = []; for (; l.$ === 1; l = l.b) out.push(l.a); return out; }
export function walk(l, visit) { for (let k = 0; l.$ === 1; l = l.b, k++) visit(l.a, k); }
export const kind = () => 'cons';

// tail calls modulo cons (lib/rewrite.js's `trmc`): the destination-passing loop beni emits, with the
// root cell's unused head holding the last cell
export const $trmcStart = () => { const r = { $: 1, a: null, b: null }; r.a = r; return r; };
export const $trmcAdd = (r, h) => { const c = { $: 1, a: h, b: null }; r.a.b = c; r.a = c; };
export const $trmcDone = (r, t) => { r.a.b = t; return r.b; };
