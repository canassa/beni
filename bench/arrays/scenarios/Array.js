// The build-time sibling of scenarios/Array.beni. It exists only so the beni build passes
// boundary.md §4's four checks (one export per `foreign`, each with its parameter list written
// out); `scenarios.mjs` replaces `_core/Array.foreign.mjs` with each candidate's port when it
// bundles, so none of this code is ever measured. It is a correct copy-on-write array anyway, so
// a program built with it runs.
const nil = { $: 0, a: null, b: null };
export const length = (a) => a.length;
export const unsafeGet = (a, i) => a[i];
export const set = (a, i, v) => {
  if (i < 0 || i >= a.length || a[i] === v) return a;
  const c = a.slice();
  c[i] = v;
  return c;
};
export const push = (a, v) => {
  const c = a.slice();
  c.push(v);
  return c;
};
export const pop = (a) => a.slice(0, -1);
export const slice = (a, s, e) => a.slice(s, e);
export const append = (a, b) => a.concat(b);
export const fromList = (l) => {
  const c = [];
  for (; l.$ === 1; l = l.b) c.push(l.a);
  return c;
};
export const toList = (a) => {
  let l = nil;
  for (let i = a.length - 1; i >= 0; i--) l = { $: 1, a: a[i], b: l };
  return l;
};
export const sortWith = (a, cmp) => a.slice().sort((x, y) => {
  const o = cmp(x, y);
  return o === "LT" ? -1 : o === "GT" ? 1 : 0;
});
