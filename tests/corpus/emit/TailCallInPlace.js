import { String$length, String$fromInt } from "./_core/String.mjs";
import { List$close } from "./_core/List.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const TailCallInPlace$sum = (n$1, acc$2) => {
  while (!(n$1 <= 0)) {
    acc$2 = acc$2 + n$1;
    n$1 = n$1 - 1;
  }
  return acc$2;
};
const TailCallInPlace$swap = (a$1, b$2, n$3) => {
  while (!(n$3 <= 0)) {
    n$3 = n$3 - 1;
    const $t$1 = b$2;
    b$2 = a$1;
    a$1 = $t$1;
  }
  return a$1 - b$2;
};
const TailCallInPlace$logged = (a$1, b$2) => {
  while (!(a$1 <= 0)) {
    const $t$2 = a$1 - 1;
    b$2 = String$length(String$fromInt(a$1)) + b$2;
    a$1 = $t$2;
  }
  return b$2;
};
const TailCallInPlace$closures = ($in$0, acc$2) => {
  const $acc = [];
  for (;;) {
    const n$1 = $in$0;
    if (n$1 <= 0) {
      return List$close($acc.reverse(), acc$2);
    } else {
      $acc.push((x$3) => x$3 + n$1);
      $in$0 = n$1 - 1;
    }
  }
};
const TailCallInPlace$main = Node$printLines([]);
export { TailCallInPlace$main, TailCallInPlace$sum, TailCallInPlace$swap, TailCallInPlace$logged, TailCallInPlace$closures };
//# sourceMappingURL=TailCallInPlace.mjs.map
