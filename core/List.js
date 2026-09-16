// The sibling JavaScript of `List.beni` (docs/design/boundary.md §4).
//
// `List a` is a `foreign type`, so it has no beni constructors and its
// representation is the emitter's: a cons cell is `{ $: 1, a: head, b: tail }`
// and the empty list is `{ $: 0, a: null, b: null }`, padded to one shape
// because fast-compiler.md §9.4 measures ~11% on Firefox for padding and
// names Elm's unpadded `List` as the counter-example. This file and
// `js/Lower.zig` are the two places that know it.
//
// The parameter lists mirror the beni signatures, which are subject first and
// function last: `foldl(list, acc, f)`. `cons(head, tail)` is the exception,
// because `::` desugars to it and takes the element first.
//
// `foldl` and `foldr` take an N-ARY function: function types are n-ary and
// every call is saturated (§9.3), so the callback of `(a, b -> b)` is reached
// as `f(x, acc)` and never as `f(x)(acc)`.

const nil = { $: 0, a: null, b: null };

export const cons = (head, tail) => ({ $: 1, a: head, b: tail });

export const foldl = (list, acc, f) => {
  let out = acc;
  for (let at = list; at.$ === 1; at = at.b) out = f(at.a, out);
  return out;
};

// Right fold, iteratively: recursing here would recurse to the depth of the
// list, which is exactly why List.beni declares it `foreign`.
export const foldr = (list, acc, f) => {
  const items = [];
  for (let at = list; at.$ === 1; at = at.b) items.push(at.a);
  let out = acc;
  for (let i = items.length - 1; i >= 0; i--) out = f(items[i], out);
  return out;
};
