// Elm's `Array` (elm/core 1.0.5, a 32-way trie with a tail), exactly as `elm make --optimize` 0.19.2
// compiles it, called through each function's uncurried `.f` (report 38 §1's adapter). elm/elm-raw.js
// is that compiler's output of elm/src/Main.elm, with the Array functions handed out at its end as
// `globalThis.ElmArr` (Elm has no way to export a JavaScript function). Elm has no `pop`, `insert`,
// `remove`, `prepend` or sort for `Array`; they are its `slice`, `push` and `append`, or its
// `toList`/`fromList`, as an Elm program writes them. `x :: rest` is the surface's view.
import './elm/elm-raw.js';
const A = globalThis.ElmArr, F2 = A.F2;
export const empty = A.empty;
export const fromArray = (arr) => A.initialize.f(arr.length, (i) => arr[i]);
export const toArray = (a) => A.foldl.f(F2((x, z) => { z.push(x); return z; }), [], a);
export const length = A.length;
export const get = (a, i) => A.get.f(i, a).a; // Just is { $: 0, a } under --optimize
export const set = (a, i, v) => A.set.f(i, v, a);
export const push = (a, v) => A.push.f(v, a);
export const pop = (a) => A.slice.f(0, -1, a);
export const slice = (a, s, e) => A.slice.f(s, e, a);
export const concat = (a, b) => A.append.f(a, b);
export const insert = (a, i, v) => A.append.f(A.push.f(v, A.slice.f(0, i, a)), A.slice.f(i, A.length(a), a));
export const remove = (a, i) => A.append.f(A.slice.f(0, i, a), A.slice.f(i + 1, A.length(a), a));
export const sort = (a, cmp) => fromArray(toArray(a).sort(cmp));
export const forEach = (a, f) => { A.foldl.f(F2((x, z) => { f(x); return z; }), 0, a); };
