import { length as Array$length, unsafeGet as Array$unsafeGet, set as Array$set, push as Array$push, slice as Array$slice, append as Array$append, fromList as Array$fromList, sortWith as Array$sortWith } from "./Array.foreign.mjs";
import { Basics$add, Basics$sub } from "../_core/Basics.mjs";
import { List$cons, List$repeat, List$reverse, List$length } from "../_core/List.mjs";
import { $dup, $drop, $dupA, $dropA, $pin } from "rc-rt";
// research/42, R1 by hand. Borrow signatures (Lean's collectO, §3 rule O1): arr is BORROWED in
// get, foldl, foldlHelp, foldr, foldrHelp, map, indexedMap, indexedMapHelp; OWNED in update and
// filter (update passes it to `set`; filter may return it). Closure parameters are always owned.
const Array$Maybe$Nothing = { $: "Nothing", a: null };
// O6: a module constant is pinned
const Array$empty = $pin(Array$fromList({ $: 0, a: null, b: null }));
// O5: the element leaves the array into an uncounted Maybe, so it gains a holder
const Array$get = (arr$1, i$2) => 0 <= i$2 && i$2 < Array$length(arr$1) ? { $: "Just", a: $dupA(Array$unsafeGet(arr$1, i$2)) } : Array$Maybe$Nothing;
const Array$update = (arr$1, i$2, func$3) => {
  const $t$1 = Array$get(arr$1, i$2);
  if ($t$1.$ === "Just") {
    const x$4 = $dupA($t$1.a);
    return Array$set(arr$1, i$2, func$3(x$4));
  } else {
    return arr$1;
  }
};
const Array$foldlHelp = (arr$1, $in$1, n$3, $in$3, func$5) => {
  Array$foldlHelp: while (true) {
    const i$2 = $in$1;
    const acc$4 = $in$3;
    if (i$2 >= n$3) {
      return acc$4;
    } else {
      $in$1 = Basics$add(i$2, 1);
      $in$3 = func$5($dupA(Array$unsafeGet(arr$1, i$2)), acc$4);
      continue Array$foldlHelp;
    }
  }
};
const Array$foldl = (arr$1, acc$2, func$3) => Array$foldlHelp(arr$1, 0, Array$length(arr$1), acc$2, func$3);
const Array$foldrHelp = (arr$1, $in$1, $in$2, func$4) => {
  Array$foldrHelp: while (true) {
    const i$2 = $in$1;
    const acc$3 = $in$2;
    if (i$2 < 0) {
      return acc$3;
    } else {
      $in$1 = Basics$sub(i$2, 1);
      $in$2 = func$4($dupA(Array$unsafeGet(arr$1, i$2)), acc$3);
      continue Array$foldrHelp;
    }
  }
};
const Array$foldr = (arr$1, acc$2, func$3) => Array$foldrHelp(arr$1, Basics$sub(Array$length(arr$1), 1), acc$2, func$3);
const Array$initializeHelp = ($in$0, $in$1, func$3) => {
  Array$initializeHelp: while (true) {
    const i$1 = $in$0;
    const acc$2 = $in$1;
    if (i$1 < 0) {
      return acc$2;
    } else {
      $in$0 = Basics$sub(i$1, 1);
      $in$1 = List$cons(func$3(i$1), acc$2);
      continue Array$initializeHelp;
    }
  }
};
const Array$initialize = (n$1, func$2) => Array$fromList(Array$initializeHelp(Basics$sub(n$1, 1), { $: 0, a: null, b: null }, func$2));
const Array$repeat = (value$1, n$2) => Array$fromList(List$repeat(value$1, n$2));
const Array$map = (arr$1, func$2) => Array$fromList(List$reverse(Array$foldl(arr$1, { $: 0, a: null, b: null }, (x$3, acc$4) => List$cons(func$2(x$3), acc$4))));
const Array$indexedMapHelp = (arr$1, $in$1, n$3, $in$3, func$5) => {
  Array$indexedMapHelp: while (true) {
    const i$2 = $in$1;
    const acc$4 = $in$3;
    if (i$2 >= n$3) {
      return acc$4;
    } else {
      $in$1 = Basics$add(i$2, 1);
      $in$3 = List$cons(func$5(i$2, $dupA(Array$unsafeGet(arr$1, i$2))), acc$4);
      continue Array$indexedMapHelp;
    }
  }
};
const Array$indexedMap = (arr$1, func$2) => Array$fromList(List$reverse(Array$indexedMapHelp(arr$1, 0, Array$length(arr$1), { $: 0, a: null, b: null }, func$2)));
const Array$filter = (arr$1, isGood$2) => {
  const kept$3 = Array$foldr(arr$1, { $: 0, a: null, b: null }, (x$5, acc$6) => {
    if (isGood$2($dupA(x$5))) return List$cons(x$5, acc$6);
    $dropA(x$5); // R1
    return acc$6;
  });
  const n$4 = List$length(kept$3);
  if (n$4 === Array$length(arr$1)) return arr$1;
  $drop(arr$1); // R1
  return Array$fromList(kept$3);
};
export { Array$length, Array$unsafeGet, Array$set, Array$push, Array$slice, Array$append, Array$fromList, Array$sortWith, Array$empty, Array$get, Array$update, Array$foldl, Array$foldr, Array$initialize, Array$repeat, Array$map, Array$indexedMap, Array$filter };
