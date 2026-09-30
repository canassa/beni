import { cons as List$cons } from "./List.foreign.mjs";
import { Basics$sub, Basics$add } from "../_core/Basics.mjs";
import { $dupA, $dropA } from "rc-rt";
// research/42, R1 by hand. A cons cell is uncounted: it keeps the token it was given forever,
// and anything read out of it is dup'd (§3, rule O5). Every element here has a type variable's
// type, so every dup and drop is the dynamic `…A` form.
const List$foldl = ($in$0, $in$1, func$3) => {
  List$foldl: while (true) {
    const xs$1 = $in$0;
    const acc$2 = $in$1;
    if (xs$1.$ === 0) {
      return acc$2;
    } else {
      const x$4 = $dupA(xs$1.a);
      const rest$5 = xs$1.b;
      $in$0 = rest$5;
      $in$1 = func$3(x$4, acc$2);
      continue List$foldl;
    }
  }
};
const List$repeatHelp = ($in$0, $in$1, value$3) => {
  List$repeatHelp: while (true) {
    const result$1 = $in$0;
    const n$2 = $in$1;
    if (n$2 <= 0) {
      $dropA(value$3); // R1
      return result$1;
    } else {
      $in$0 = List$cons($dupA(value$3), result$1);
      $in$1 = Basics$sub(n$2, 1);
      continue List$repeatHelp;
    }
  }
};
const List$repeat = (value$1, n$2) => List$repeatHelp({ $: 0, a: null, b: null }, n$2, value$1);
const List$rangeHelp = (lo$1, $in$1, $in$2) => {
  List$rangeHelp: while (true) {
    const hi$2 = $in$1;
    const list$3 = $in$2;
    if (lo$1 <= hi$2) {
      $in$1 = Basics$sub(hi$2, 1);
      $in$2 = List$cons(hi$2, list$3);
      continue List$rangeHelp;
    } else {
      return list$3;
    }
  }
};
const List$range = (lo$1, hi$2) => List$rangeHelp(lo$1, hi$2, { $: 0, a: null, b: null });
const List$length = (xs$1) => List$foldl(xs$1, 0, ($p$1, n$2) => {
  $dropA($p$1); // R1
  return Basics$add(n$2, 1);
});
const List$reverse = (list$1) => List$foldl(list$1, { $: 0, a: null, b: null }, List$cons);
const List$takeHelp = ($in$0, $in$1, $in$2) => {
  List$takeHelp: while (true) {
    const n$1 = $in$0;
    const list$2 = $in$1;
    const acc$3 = $in$2;
    if (n$1 <= 0) {
      return acc$3;
    } else {
      if (list$2.$ === 0) {
        return acc$3;
      } else {
        const x$4 = $dupA(list$2.a);
        const xs$5 = list$2.b;
        $in$0 = Basics$sub(n$1, 1);
        $in$1 = xs$5;
        $in$2 = List$cons(x$4, acc$3);
        continue List$takeHelp;
      }
    }
  }
};
const List$take = (list$1, n$2) => List$reverse(List$takeHelp(n$2, list$1, { $: 0, a: null, b: null }));
export { List$cons, List$foldl, List$repeat, List$range, List$length, List$reverse, List$take };
