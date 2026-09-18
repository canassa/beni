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
// function last: `eq(m0, xs, ys)`. `cons(head, tail)` is the exception,
// because `::` desugars to it and takes the element first.
//
// **`foldl` and `foldr` used to live here and no longer do** (backend.md §8).
// They were the only `foreign` values in the repository with a function type
// anywhere in them, and a JavaScript loop cannot park when its beni callback
// suspends; they left for beni in the same commit as the tail-call loop,
// because a beni `foldl` without the loop would be a stack bomb inside core
// itself. What is left here is first-order, which is what
// `research/17-platform-primitives.md` §3.4 counts.

const nil = { $: 0, a: null, b: null };

export const cons = (head, tail) => ({ $: 1, a: head, b: tail });

// `eq`, §9.5's loop. The evidence parameter of static-dispatch-spike.md §8.1
// comes FIRST and the declared arguments follow, so a sibling of a
// `pub foreign … where` is written with evidence count + declared arity
// parameters (§5.2, A.7). Nothing checks that count at build time —
// `Sibling.zig` checks export and import coverage and not arity — so this
// line is the contract, and `tests/corpus/run/ListElementEq.beni` is what
// catches it if it moves.
//
// A LOOP and not recursion: a list long enough to be interesting is longer
// than the JavaScript stack, and nothing turns a self-call in a hand-written
// sibling into one.
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

// `compare`, §9.5's other loop, and the same contract as `eq` above: the
// evidence parameter comes FIRST, nothing checks the count at build time,
// and `tests/corpus/run/ListOrdering.beni` is what catches it if it moves.
//
// An `Order` is a bare tag string, because a type whose constructors are
// all nullary has no payload to carry (backend.md §4). The first pair that
// differs decides; if the loop runs off the end of one list with everything
// before it equal, the SHORTER list is `LT`, which is Elm's order and the
// one `List.sort` on a `List (List Int)` has to produce.
export const compare = (m0, xs, ys) => {
  let a = xs;
  let b = ys;
  while (a.$ === 1 && b.$ === 1) {
    const o = m0(a.a, b.a);
    if (o !== "EQ") return o;
    a = a.b;
    b = b.b;
  }
  if (a.$ === b.$) return "EQ";
  return a.$ === 0 ? "LT" : "GT";
};
