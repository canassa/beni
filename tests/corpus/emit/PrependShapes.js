import { List$cons, List$close, List$base, List$offset, List$foldl, List$unsafeGet, List$view, List$append } from "./_core/List.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const PrependShapes$plain = (x$1, xs$2) => List$cons(x$1, xs$2);
const PrependShapes$viaCons = (x$1, xs$2) => List$cons(x$1, xs$2);
const PrependShapes$twoItems = (a$1, b$2, xs$3) => List$cons(a$1, List$cons(b$2, xs$3));
const PrependShapes$appendTo = (xs$1, ys$2) => {
  const $t$1 = List$base(xs$1);
  xs$1 = List$offset(xs$1);
  const $root = [];
  while ($t$1.length !== xs$1) {
    const x$3 = $t$1[xs$1];
    const rest$4 = xs$1 + 1;
    $root.push(x$3);
    xs$1 = rest$4;
  }
  return List$close($root, ys$2);
};
const PrependShapes$reverseInto = (xs$1, acc$2) => {
  const $t$1 = List$base(xs$1);
  xs$1 = List$offset(xs$1);
  while ($t$1.length !== xs$1) {
    const x$3 = $t$1[xs$1];
    const rest$4 = xs$1 + 1;
    const next$5 = List$cons(x$3, acc$2);
    xs$1 = rest$4;
    acc$2 = next$5;
  }
  return acc$2;
};
const PrependShapes$foldPrepend = (xs$1) => List$foldl(xs$1, [], (x$2, acc$3) => {
  const next$4 = List$cons(x$2, acc$3);
  return next$4;
});
const PrependShapes$suffix = (list$1) => {
  $j$0$1: {
    if (list$1.length > 0) {
      if (list$1.length > 1) {
        const b$2 = List$unsafeGet(list$1, 1);
        const tail$3 = List$view(list$1, 2);
        return List$cons(b$2, tail$3);
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  return list$1;
};
const PrependShapes$sums = (acc$1, list$2) => {
  const $t$1 = List$base(list$2);
  list$2 = List$offset(list$2);
  for (;;) {
    $j$0$1: {
      if ($t$1.length > list$2) {
        if ($t$1.length > list$2 + 1) {
          const a$3 = $t$1[list$2];
          const b$4 = $t$1[list$2 + 1];
          const tail$5 = list$2 + 2;
          acc$1 = List$append(acc$1, [a$3 + b$4]);
          list$2 = tail$5 - 1;
          continue;
        } else {
          break $j$0$1;
        }
      } else {
        break $j$0$1;
      }
    }
    return acc$1;
  }
};
const PrependShapes$reconsed = (list$1) => {
  if (list$1.length === 0) {
    return [];
  } else {
    const h$2 = List$unsafeGet(list$1, 0);
    const t$3 = List$view(list$1, 1);
    return List$cons(h$2, t$3);
  }
};
const PrependShapes$main = Node$printLines([]);
export { PrependShapes$main, PrependShapes$plain, PrependShapes$viaCons, PrependShapes$twoItems, PrependShapes$appendTo, PrependShapes$reverseInto, PrependShapes$foldPrepend, PrependShapes$suffix, PrependShapes$sums, PrependShapes$reconsed };
//# sourceMappingURL=PrependShapes.mjs.map
