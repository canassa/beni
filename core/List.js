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

// `eq`, §9.5's loop. The evidence parameter of static-dispatch-spike.md §8.1
// comes FIRST and the declared arguments follow, so a sibling of a
// `pub foreign … where` is written with evidence count + declared arity
// parameters (§5.2, A.7). Nothing checks that count at build time —
// `Sibling.zig` checks export and import coverage and not arity — so this
// line is the contract, and `tests/corpus/run/ListElementEq.beni` is what
// catches it if it moves.
//
// A LOOP and not recursion: a list long enough to be interesting is longer
// than the JavaScript stack, which is why `foldr` above is a loop too.
export const eq = (m0, xs, ys) => {
  let a = xs;
  let b = ys;
  while (a.$ === 1 && b.$ === 1) {
    if (!m0(a.a, b.a)) return false;
    a = a.b;
    b = b.b;
  }
  return a.$ === b.$;
};
