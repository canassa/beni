import { List$foldl, List$range } from "./_core/List.mjs";
import { Array$empty, Array$push, Array$repeat, Array$update, Array$get, Array$foldl } from "./_core/Array.mjs";
import { Basics$modBy, Basics$mul, Basics$add, Basics$sub, Basics$min } from "./_core/Basics.mjs";
import { $dup } from "rc-rt";
// research/42 R1 by hand: Array.empty is a pinned constant passed where a value is consumed (O2)
const Build$collect = (n$1) => List$foldl(List$range(1, n$1), $dup(Array$empty), (x$2, acc$3) => Array$push(acc$3, Basics$modBy(Basics$mul(x$2, x$2), 1000)));
const Build$histogram = (samples$1, buckets$2) => List$foldl(samples$1, Array$repeat(0, buckets$2), (x$3, acc$4) => Array$update(acc$4, Basics$modBy(x$3, buckets$2), (c$5) => Basics$add(c$5, 1)));
const Build$via = (dp$1, i$2, coin$3) => {
  const $t$1 = Array$get(dp$1, Basics$sub(i$2, coin$3));
  if ($t$1.$ === "Just") {
    const c$4 = $t$1.a;
    return Basics$add(c$4, 1);
  } else {
    return 1000000000;
  }
};
const Build$coinsHelp = ($in$0, n$2, $in$2) => {
  Build$coinsHelp: while (true) {
    const i$1 = $in$0;
    const dp$3 = $in$2;
    if (i$1 > n$2) {
      return dp$3;
    } else {
      const best$4 = Basics$min(Basics$min(Build$via(dp$3, i$1, 1), Build$via(dp$3, i$1, 5)), Basics$min(Build$via(dp$3, i$1, 11), Build$via(dp$3, i$1, 23)));
      $in$0 = Basics$add(i$1, 1);
      $in$2 = Array$push(dp$3, best$4);
      continue Build$coinsHelp;
    }
  }
};
const Build$coins = (n$1) => Build$coinsHelp(1, n$1, Array$push($dup(Array$empty), 0));
const Build$total = (arr$1) => Array$foldl(arr$1, 0, (v$2, s$3) => Basics$add(s$3, v$2));
export { Build$collect, Build$histogram, Build$coins, Build$total };
