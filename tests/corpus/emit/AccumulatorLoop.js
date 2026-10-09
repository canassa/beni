import { List$close, List$append, List$cons } from "./_core/List.mjs";
import { Debug$logAs } from "./_core/Debug.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const AccumulatorLoop$prepend = (n$1, acc$2) => {
  const $acc = [];
  while (!(n$1 <= 0)) {
    $acc.push(n$1);
    n$1 = n$1 - 1;
  }
  return List$close($acc.reverse(), acc$2);
};
const AccumulatorLoop$two = (n$1, acc$2) => {
  const $acc = [];
  while (!(n$1 <= 0)) {
    const $t$1 = n$1 - 1;
    const $t$2 = Debug$logAs("[\"i\",[]]", "a", n$1);
    const $t$3 = Debug$logAs("[\"i\",[]]", "b", n$1);
    $acc.push($t$3, $t$2);
    n$1 = $t$1;
  }
  return List$close($acc.reverse(), acc$2);
};
const AccumulatorLoop$append = (n$1, acc$2) => {
  const $acc = [];
  while (!(n$1 <= 0)) {
    $acc.push(n$1);
    n$1 = n$1 - 1;
  }
  return List$append(acc$2, $acc);
};
const AccumulatorLoop$tupled = (n$1, acc$2) => {
  const $acc = [];
  while (!(n$1 <= 0)) {
    $acc.push(n$1);
    n$1 = n$1 - 1;
  }
  return { a: List$close($acc.reverse(), acc$2), b: n$1 };
};
const AccumulatorLoop$reads = (n$1, acc$2) => {
  while (!(acc$2.length >= n$1)) {
    acc$2 = List$cons(n$1, acc$2);
  }
  return acc$2;
};
const AccumulatorLoop$main = Node$printLines([]);
export { AccumulatorLoop$main, AccumulatorLoop$prepend, AccumulatorLoop$two, AccumulatorLoop$append, AccumulatorLoop$tupled, AccumulatorLoop$reads };
//# sourceMappingURL=AccumulatorLoop.mjs.map
