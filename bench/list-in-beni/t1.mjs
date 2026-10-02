// The tier-1 workloads: the operations that move to beni with today's `Js`.
const P = (m, n) => m.LB2$make(n);
const T = (m, n) => m.LB2$pushed(n);
const V = (m, n) => m.LB2$tailOf(m.LB2$make(n + 1));
export default [
  ['eq-plain', P, (m, xs) => m.LB2$equal(xs, xs)],
  ['eq-trie', T, (m, xs) => m.LB2$equal(xs, xs)],
  ['compare-plain', P, (m, xs) => m.LB2$compare(xs, xs)],
  ['compare-view', V, (m, xs) => m.LB2$compare(xs, xs)],
  ['slice-plain', P, (m, xs, n) => m.LB2$slice(xs, n)],
  ['slice-view', V, (m, xs, n) => m.LB2$slice(xs, n)],
  ['insertAt', P, (m, xs, n) => m.LB2$insertAt(xs, n)],
  ['removeAt', P, (m, xs, n) => m.LB2$removeAt(xs, n)],
  ['swap-plain', P, (m, xs, n) => m.LB2$swap(xs, n)],
  ['swap-trie', T, (m, xs, n) => m.LB2$swap(xs, n)],
  ['concat', (m, n) => m.LB2$chunks(n), (m, xs) => m.LB2$concat(xs)],
  ['concatMap', P, (m, xs) => m.LB2$concatMap(xs)],
];
