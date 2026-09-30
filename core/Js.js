// The sibling JavaScript of `Js.beni`: the intrinsics as functions. A call
// of one is compiled in place and never reaches this file; it is here for
// check 2, and for a declaration passed as a value.

const args = (xs) => {
  const out = [];
  for (let at = xs; at.$ === 1; at = at.b) out.push(at.a);
  return out;
};

const null_ = null;
export { null_ as null };
const undefined_ = undefined;
export { undefined_ as undefined };
export const from = (v) => v;
export const to = (v) => v;
export const same = (a, b) => a === b;
export const isNull = (v) => v === null;
export const isUndefined = (v) => v === undefined;
export const isNullish = (v) => v == null;
export const bitAnd = (a, b) => a & b;
export const global = (name) => globalThis[name];
export const get = (o, name) => o[name];
export const set = (o, name, v) => {
  o[name] = v;
  return null;
};
export const call = (o, name, xs) => o[name](...args(xs));
export const apply = (f, xs) => f(...args(xs));
export const array = (xs) => args(xs);
export const at = (o, k) => o[k];
const throw_ = (v) => {
  throw v;
};
export { throw_ as throw };
