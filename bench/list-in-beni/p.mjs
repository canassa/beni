// The whole-runtime workloads: every form, every writer and reader whose code moved.
const P = (m, n) => m.LB2$make(n);
const T = (m, n) => m.LB2$pushed(n);
const H = (m, n) => m.LB2$prepended(n);
const V = (m, n) => m.LB2$tailOf(m.LB2$make(n + 1));
export default [
  ['noop', T, (m, xs) => xs],
  ['flatten-trie', T, (m, xs) => m.LB2$pushSum(xs)],
  ['flatten-headed', H, (m, xs) => m.LB2$pushSum(xs)],
  ['flatten-views', P, (m, xs) => m.LB2$appendViews(xs)],
  ['pushMany', P, (m, xs, n) => m.LB2$pushMany(n)],
  ['consMany', P, (m, xs, n) => m.LB2$consMany(n)],
  ['push-trie', T, (m, xs) => m.LB2$push(xs)],
  ['push-plain', P, (m, xs) => m.LB2$push(xs)],
  ['cons-trie', H, (m, xs) => m.LB2$cons(xs)],
  ['cons-plain', P, (m, xs) => m.LB2$cons(xs)],
  ['pop-trie', T, (m, xs) => m.LB2$pop(xs)],
  ['popAll-trie', T, (m, xs) => m.LB2$popAll(xs)],
  ['set-trie', T, (m, xs, n) => m.LB2$set(xs, n)],
  ['set-plain', P, (m, xs, n) => m.LB2$set(xs, n)],
  ['append-trie', T, (m, xs) => m.LB2$append(xs)],
  ['append-plain', P, (m, xs) => m.LB2$append(xs)],
  ['get-trie', T, (m, xs, n) => m.LB2$get(xs, n)],
  ['get-headed', H, (m, xs, n) => m.LB2$get(xs, n)],
  ['sumGet-trie', T, (m, xs) => m.LB2$sumGet(xs)],
  ['sumGet-view', V, (m, xs) => m.LB2$sumGet(xs)],
  ['drop-trie', T, (m, xs, n) => m.LB2$drop(xs, n)],
  ['drop-plain', P, (m, xs, n) => m.LB2$drop(xs, n)],
  ['walk-trie', T, (m, xs) => m.LB2$walk(xs)],
  ['walk-headed', H, (m, xs) => m.LB2$walk(xs)],
  ['sum-trie', T, (m, xs) => m.LB2$sum(xs)],
  ['eq-plain', P, (m, xs) => m.LB2$equal(xs, xs)],
  ['compare-plain', P, (m, xs) => m.LB2$compare(xs, xs)],
  ['slice-plain', P, (m, xs, n) => m.LB2$slice(xs, n)],
  ['insertAt', P, (m, xs, n) => m.LB2$insertAt(xs, n)],
  ['removeAt', P, (m, xs, n) => m.LB2$removeAt(xs, n)],
  ['swap-trie', T, (m, xs, n) => m.LB2$swap(xs, n)],
  ['concat', (m, n) => m.LB2$chunks(n), (m, xs) => m.LB2$concat(xs)],
];
