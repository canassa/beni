// research/42 §8: the declarations the list variants replace, by hand, in the rewritten output of
// research/38 §16 (dist/lists/R for R2, dist/lists/C for R0). rc/lists.mjs swaps each named
// `const` for the text here and fails if a name is missing. Everything not named is B's (for R2)
// or C's (for R0) code, unchanged.
export const DECLS = {
  // R2: the sticky bit. Records and tuples that hold a List are counted (rule O5): they carry
  // `rc`, and the last use of an owned one takes its fields — moved if it is unique, shared if
  // not (rule O4). Nothing else changes: `prependFold` and `chainPaths` are B's code as it is,
  // because foldl already threads its accumulator and `$hd` already shares what it reads.
  R2: {
    'Lib.mjs': {
      Lib$recordFold: `const Lib$recordFold = (xs$1) => {
  const final$2 = List$foldl(xs$1, { rc: 1, count: 0, seen: $nil }, (x$3, st$4) => {
    const seen$ = st$4.rc === 1 ? st$4.seen : $share(st$4.seen);
    return { ...st$4, rc: 1, seen: List$cons(Basics$mul(x$3, 2), seen$), count: Basics$add(st$4.count, 1) };
  });
  return List$reverse(final$2.seen);
};`,
      Lib$partitionFold: `const Lib$partitionFold = (xs$1) => List$foldr(xs$1, { rc: 1, a: $nil, b: $nil }, (x$2, pair$3) => {
  const u$ = pair$3.rc === 1;
  const evens$4 = u$ ? pair$3.a : $share(pair$3.a);
  const odds$5 = u$ ? pair$3.b : $share(pair$3.b);
  return Basics$modBy(x$2, 2) === 0 ? { rc: 1, a: List$cons(x$2, evens$4), b: odds$5 } : { rc: 1, a: evens$4, b: List$cons(x$2, odds$5) };
});`,
    },
    'Todo.mjs': {
      Todo$create: `const Todo$create = (n$1) => ({ rc: 1, items: List$map(List$range(1, n$1), (i$2) => ({ done: false, id: i$2, label: "todo" })), nextId: Basics$add(n$1, 1) });`,
      Todo$update: `const Todo$update = (msg$1, model$2) => {
  const u$ = model$2.rc === 1;
  switch (msg$1.$) {
    case "Add":
      {
        const nextId$ = model$2.nextId;
        const items$ = u$ ? model$2.items : $share(model$2.items);
        return { ...model$2, rc: 1, items: List$cons({ done: false, id: nextId$, label: "todo" }, items$), nextId: Basics$add(nextId$, 1) };
      }
    case "Remove":
      {
        const id$3 = msg$1.a;
        return { ...model$2, rc: 1, items: List$filter(model$2.items, (i$4) => i$4.id !== id$3) };
      }
    default:
      {
        const id$5 = msg$1.a;
        return { ...model$2, rc: 1, items: List$map(model$2.items, (i$6) => i$6.id === id$5 ? { ...i$6, done: Basics$not(i$6.done) } : i$6) };
      }
  }
};`,
    },
  },
  // R0: static. On top of C's rules (research/38 §16.3), scalar replacement of the fold's state:
  // after R4 inlines List.foldl/foldr with a literal lambda, a record or tuple that is built fresh
  // on every iteration and read only by the next one is split into one loop variable per field,
  // and R1 (the local builder) then applies to each List field. Neither needs more than the
  // declaration; `chainPaths` shares its tails by design, and the TEA model is held by the runtime,
  // so both stay C's.
  R0: {
    'Lib.mjs': {
      Lib$recordFold: `const Lib$recordFold = (xs$1) => {
  $span(xs$1);
  const a = $SA, n = a.length, seen = [];
  let count = 0;
  for (let o = $SO; o < n; o++) { seen.push(Basics$mul(a[o], 2)); count = Basics$add(count, 1); }
  return $fromBuilder(seen);
};`,
      Lib$partitionFold: `const Lib$partitionFold = (xs$1) => {
  $span(xs$1);
  const a = $SA, o = $SO, evens = [], odds = [];
  for (let k = a.length - 1; k >= o; k--) { const x = a[k]; if (Basics$modBy(x, 2) === 0) evens.push(x); else odds.push(x); }
  return { a: $fromBuilderRev(evens), b: $fromBuilderRev(odds) };
};`,
    },
  },
};
