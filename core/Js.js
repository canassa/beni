// The sibling JavaScript of `Js.beni`: the intrinsics as functions. A call
// of one is compiled in place and never reaches this file; it is here for
// check 2, and for a declaration passed as a value.

// A list's elements as a fresh array, which the host may keep and write
// (boundary.md §4: a list crosses as a plain array, read by the protocol).
const args = (xs) => (Array.isArray(xs) ? xs : xs.$plain()).slice();

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
export const construct = (c, xs) => new c(...args(xs));
export const array = (xs) => args(xs);
export const each = (xs, f) => {
  for (const x of xs) f(x);
  return null;
};
export const at = (o, k) => o[k];
export const setAt = (o, k, v) => {
  o[k] = v;
  return null;
};
const throw_ = (v) => {
  throw v;
};
export { throw_ as throw };
export const ref = (v) => ({ v });
export const read = (r) => r.v;
export const write = (r, v) => {
  r.v = v;
  return null;
};
const finally_ = (body, cleanup) => {
  try {
    return body();
  } finally {
    cleanup();
  }
};
export { finally_ as finally };
