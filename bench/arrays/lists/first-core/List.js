// The build-time sibling of lists/first-core/List.beni (research/38 §17). It exists so the beni
// build passes boundary.md §4's four checks; `lists.mjs` replaces `_core/List.foreign.mjs` with
// `ports/first.js` when it bundles, so none of this is measured. It is a correct copy-on-write
// array over plain JS arrays anyway, so a program built with it runs.
export const cons = (head, tail) => [head].concat(tail);
export const eq = (m0, xs, ys) => {
  if (xs.length !== ys.length) return false;
  for (let i = 0; i < xs.length; i++) if (!m0(xs[i], ys[i])) return false;
  return true;
};
export const compare = (m0, xs, ys) => {
  const n = Math.min(xs.length, ys.length);
  for (let i = 0; i < n; i++) {
    const o = m0(xs[i], ys[i]);
    if (o !== "EQ") return o;
  }
  return xs.length === ys.length ? "EQ" : xs.length < ys.length ? "LT" : "GT";
};
export const length = (xs) => xs.length;
export const unsafeGet = (xs, i) => xs[i];
export const set = (xs, i, v) => {
  if (i < 0 || i >= xs.length || xs[i] === v) return xs;
  const c = xs.slice();
  c[i] = v;
  return c;
};
export const push = (xs, v) => {
  const c = xs.slice();
  c.push(v);
  return c;
};
export const pop = (xs) => xs.slice(0, -1);
export const slice = (xs, from, to) => xs.slice(from, to);
export const append = (xs, ys) => xs.concat(ys);
export const builder = (n) => [];
export const add = (b, x) => {
  b.push(x);
  return b;
};
export const done = (b) => b;
