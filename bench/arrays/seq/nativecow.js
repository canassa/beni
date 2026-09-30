// native CoW: a plain JS array copied on every write by the ES2023 builtins a JavaScript programmer
// reaches for (report 38 §1): `with`, `toSpliced`, `toSorted`, spread, `slice`, `concat`. None of them
// returns its input for a no-op (§7).
export const empty = [];
export const fromArray = (arr) => arr;
export const toArray = (a) => a;
export const length = (a) => a.length;
export const get = (a, i) => a[i];
export const set = (a, i, v) => a.with(i, v);
export const push = (a, v) => [...a, v];
export const pop = (a) => a.slice(0, -1);
export const slice = (a, s, e) => a.slice(s, e);
export const concat = (a, b) => a.concat(b);
export const insert = (a, i, v) => a.toSpliced(i, 0, v);
export const remove = (a, i) => a.toSpliced(i, 1);
export const swap = (a, i, j) => a.with(i, a[j]).with(j, a[i]);
export const prepend = (a, v) => [v, ...a];
export const sort = (a, cmp) => a.toSorted(cmp);
export const forEach = (a, f) => a.forEach((x) => { f(x); });
export const chunks = (a) => [a];
