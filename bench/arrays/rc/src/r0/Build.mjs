import { List$foldl, List$range } from "./_core/List.mjs";
import { Array$empty, Array$push, Array$pushU, Array$copy, Array$repeat, Array$update, Array$get, Array$foldl } from "./_core/Array.mjs";
import { Basics$modBy, Basics$mul, Basics$add, Basics$sub, Basics$min } from "./_core/Basics.mjs";
// research/42 R0 by hand. `List.foldl` with a literal lambda is inlined into its loop (§16.3's R4);
// the accumulator is then a loop variable, and the loop is a callee whose accumulator is
// consumed-unique: its entry copies an initial value it cannot prove unique (S3). Array.empty is
// a constant, so collect copies it (zero elements).
const Build$collect = (n$1) => {
  let xs$ = List$range(1, n$1), acc$3 = Array$copy(Array$empty);
  while (xs$.$ !== 0) {
    const x$2 = xs$.a;
    xs$ = xs$.b;
    acc$3 = Array$pushU(acc$3, Basics$modBy(Basics$mul(x$2, x$2), 1000));
  }
  return acc$3;
};
// Array.repeat's result is fresh, so it needs no copy
const Build$histogram = (samples$1, buckets$2) => {
  let xs$ = samples$1, acc$4 = Array$repeat(0, buckets$2);
  while (xs$.$ !== 0) {
    const x$3 = xs$.a;
    xs$ = xs$.b;
    acc$4 = Array$update(acc$4, Basics$modBy(x$3, buckets$2), (c$5) => Basics$add(c$5, 1));
  }
  return acc$4;
};
// The same without the inlining: the lambda's `acc` is a closure parameter, which no summary can
// make unique, so the call of the consumed-unique `Array.update` copies first (S3) — per sample.
const Build$histogramNoInline = (samples$1, buckets$2) => List$foldl(samples$1, Array$repeat(0, buckets$2), (x$3, acc$4) => Array$update(Array$copy(acc$4), Basics$modBy(x$3, buckets$2), (c$5) => Basics$add(c$5, 1)));
const Build$via = (dp$1, i$2, coin$3) => {
  const $t$1 = Array$get(dp$1, Basics$sub(i$2, coin$3));
  if ($t$1.$ === "Just") {
    const c$4 = $t$1.a;
    return Basics$add(c$4, 1);
  } else {
    return 1000000000;
  }
};
// coinsHelp: `dp` is consumed-unique (S2); coins passes a fresh push result, so no copy
const Build$coinsHelp = ($in$0, n$2, $in$2) => {
  Build$coinsHelp: while (true) {
    const i$1 = $in$0;
    const dp$3 = $in$2;
    if (i$1 > n$2) {
      return dp$3;
    } else {
      const best$4 = Basics$min(Basics$min(Build$via(dp$3, i$1, 1), Build$via(dp$3, i$1, 5)), Basics$min(Build$via(dp$3, i$1, 11), Build$via(dp$3, i$1, 23)));
      $in$0 = Basics$add(i$1, 1);
      $in$2 = Array$pushU(dp$3, best$4);
      continue Build$coinsHelp;
    }
  }
};
const Build$coins = (n$1) => Build$coinsHelp(1, n$1, Array$push(Array$empty, 0));
const Build$total = (arr$1) => Array$foldl(arr$1, 0, (v$2, s$3) => Basics$add(s$3, v$2));
export { Build$histogramNoInline, Build$collect, Build$histogram, Build$coins, Build$total };
