import { Array$foldl, Array$filter, Array$slice, Array$sortWith, Array$get, Array$length } from "./_core/Array.mjs";
import { Basics$add, Basics$compare, Basics$idiv, Basics$sub, Basics$modBy, Basics$mul } from "./_core/Basics.mjs";
import { List$cons } from "./_core/List.mjs";
import { $drop } from "rc-rt"; // R1
const Decoded$Maybe$Nothing = { $: "Nothing", a: null };
const Decoded$countIn = (items$1, c$2) => Array$foldl(items$1, 0, (it$3, n$4) => it$3.category === c$2 ? Basics$add(n$4, 1) : n$4);
const Decoded$total = (items$1) => Array$foldl(items$1, 0.0, (it$2, s$3) => Basics$add(s$3, it$2.price));
const Decoded$inCategory = (items$1, c$2) => Array$filter(items$1, (it$3) => it$3.category === c$2);
// research/42 R1 by hand: the sorted array is fresh and dead once sliced
const Decoded$cheapest = (items$1, k$2) => {
  const s$ = Array$sortWith(items$1, (a$3, b$4) => Basics$compare(a$3.price, b$4.price));
  const r$ = Array$slice(s$, 0, k$2);
  $drop(s$); // R1
  return r$;
};
const Decoded$find = (items$1, id$2, $in$2, $in$3) => {
  Decoded$find: while (true) {
    const lo$3 = $in$2;
    const hi$4 = $in$3;
    if (lo$3 > hi$4) {
      return Decoded$Maybe$Nothing;
    } else {
      const mid$5 = Basics$idiv(Basics$add(lo$3, hi$4), 2);
      const $t$1 = Array$get(items$1, mid$5);
      if ($t$1.$ === "Just") {
        const it$6 = $t$1.a;
        if (it$6.id === id$2) {
          return { $: "Just", a: it$6 };
        } else {
          if (it$6.id < id$2) {
            $in$2 = Basics$add(mid$5, 1);
            $in$3 = hi$4;
            continue Decoded$find;
          } else {
            $in$2 = lo$3;
            $in$3 = Basics$sub(mid$5, 1);
            continue Decoded$find;
          }
        }
      } else {
        return Decoded$Maybe$Nothing;
      }
    }
  }
};
const Decoded$lookupsHelp = (items$1, $in$1, k$3, $in$3) => {
  Decoded$lookupsHelp: while (true) {
    const j$2 = $in$1;
    const acc$4 = $in$3;
    if (j$2 >= k$3) {
      return acc$4;
    } else {
      const id$5 = Basics$modBy(Basics$mul(j$2, 7919), Array$length(items$1));
      const $t$2 = Decoded$find(items$1, id$5, 0, Basics$sub(Array$length(items$1), 1));
      if ($t$2.$ === "Just") {
        const it$6 = $t$2.a;
        $in$1 = Basics$add(j$2, 1);
        $in$3 = Basics$add(acc$4, it$6.price);
        continue Decoded$lookupsHelp;
      } else {
        $in$1 = Basics$add(j$2, 1);
        $in$3 = acc$4;
        continue Decoded$lookupsHelp;
      }
    }
  }
};
const Decoded$lookups = (items$1, k$2) => Decoded$lookupsHelp(items$1, 0, k$2, 0.0);
const Decoded$pageHelp = (items$1, $in$1, start$3, $in$3) => {
  Decoded$pageHelp: while (true) {
    const i$2 = $in$1;
    const acc$4 = $in$3;
    if (i$2 < start$3) {
      return acc$4;
    } else {
      const $t$3 = Array$get(items$1, i$2);
      if ($t$3.$ === "Just") {
        const it$5 = $t$3.a;
        $in$1 = Basics$sub(i$2, 1);
        $in$3 = List$cons(it$5.name, acc$4);
        continue Decoded$pageHelp;
      } else {
        $in$1 = Basics$sub(i$2, 1);
        $in$3 = acc$4;
        continue Decoded$pageHelp;
      }
    }
  }
};
const Decoded$page = (items$1, start$2, size$3) => Decoded$pageHelp(items$1, Basics$sub(Basics$add(start$2, size$3), 1), start$2, { $: 0, a: null, b: null });
export { Decoded$countIn, Decoded$total, Decoded$inCategory, Decoded$cheapest, Decoded$lookups, Decoded$page };
