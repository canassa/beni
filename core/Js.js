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
export const bitOr = (a, b) => a | b;
export const bitXor = (a, b) => a ^ b;
export const shiftLeft = (a, n) => a << n;
export const shiftRight = (a, n) => a >> n;
export const shiftRightZero = (a, n) => a >>> n;
export const rem = (a, b) => a % b;
export const typeOf = (v) => typeof v;
export const typeIs = (v, t) => typeof v === t;
export const instanceOf = (v, c) => v instanceof c;
// A call is always written as the literal (backend.md §4, *`Js.regExp` is a
// literal*); passed as a value, the two strings make the same expression.
export const regExp = (pattern, flags) => new RegExp(pattern, flags);
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
// Catches what `test` holds of and nothing else: anything else is thrown on
// unchanged (CLAUDE.md rule 9).
export const catchIf = (body, test, handler) => {
  try {
    return body();
  } catch (e) {
    if (!test(e)) throw e;
    return handler(e);
  }
};

// A call with a lambda is written as the lambda's body (backend.md §4,
// *`Js.pure` is its body*); passed as a value, it calls what it is given.
const pure_ = (body) => body();
export { pure_ as pure };

// What a build never reads from here: `Js.development` is written in place
// as `true` or `false` for the build (backend.md §4, *`Js.development` is
// the build's mode*), so this is only the export check 2 counts.
export const development = (unit) => true;

// The same for `Js.maySuspend`, written in place as its answer: passed as a
// value it cannot know what it is asked about, and a function that may
// suspend is the safe answer.
export const maySuspend = (f) => true;

// Written in place as its body, like `pure` (backend.md §4,
// *`Js.suspending` is its body*); passed as a value, it calls what it is
// given.
export const suspending = (body) => body();
