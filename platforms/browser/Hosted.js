// The sibling JavaScript of `Hosted.beni` (docs/design/boundary.md §4,
// §9.8): one export per `foreign` value, under the same name. Only the keys
// are left here: everything else is beni over `Js`.

// ---- Keys: by their types' identities, then by their types' `compare` -----

// `{ t, c, v }`: the identity of the key's type, the compiler's string
// (static-dispatch-spike.md §8.6); the type's own `compare`, the `where`
// clause's evidence; and the value (boundary.md §9.8.3).
export const keyOf = (compare, type, value) => ({ t: type, c: compare, v: value });

// Two keys of one identity are of one type, so either's `compare` orders
// both; keys of two types are ordered by their identities' text.
export const compareKeys = (a, b) => {
  if (a === b) return "EQ";
  if (a.t !== b.t) return a.t < b.t ? "LT" : "GT";
  return a.c(a.v, b.v);
};
