import { List$base, List$offset, List$view, List$close, List$push, List$drop } from "./_core/List.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const ListScalarView$sum = (xs$1, acc$2) => {
  const $t$1 = List$base(xs$1);
  xs$1 = List$offset(xs$1);
  for (;;) {
    if ($t$1.length === xs$1) {
      return acc$2;
    } else {
      const x$3 = $t$1[xs$1];
      const rest$4 = xs$1 + 1;
      xs$1 = rest$4;
      acc$2 = acc$2 + x$3;
    }
  }
};
const ListScalarView$mapRec = (xs$1, f$2) => {
  const $t$3 = List$base(xs$1);
  xs$1 = List$offset(xs$1);
  const $root = [];
  for (;;) {
    if ($t$3.length === xs$1) {
      return $root;
    } else {
      const x$3 = $t$3[xs$1];
      const rest$4 = xs$1 + 1;
      $root.push(f$2(x$3));
      xs$1 = rest$4;
    }
  }
};
const ListScalarView$merge = (xs$1, ys$2) => {
  const $t$6 = xs$1;
  const $t$5 = List$base(xs$1);
  xs$1 = List$offset(xs$1);
  const $t$8 = ys$2;
  const $t$7 = List$base(ys$2);
  ys$2 = List$offset(ys$2);
  const $root = [];
  for (;;) {
    if ($t$5.length === xs$1) {
      return List$close($root, $t$7.length - ys$2 === $t$8.length ? $t$8 : List$view($t$7, ys$2));
    } else {
      const x$3 = $t$5[xs$1];
      const restX$4 = xs$1 + 1;
      if ($t$7.length === ys$2) {
        return List$close($root, $t$5.length - xs$1 === $t$6.length ? $t$6 : List$view($t$5, xs$1));
      } else {
        const y$5 = $t$7[ys$2];
        const restY$6 = ys$2 + 1;
        if (x$3 <= y$5) {
          $root.push(x$3);
          xs$1 = restX$4;
          ys$2 = ys$2;
        } else {
          $root.push(y$5);
          xs$1 = xs$1;
          ys$2 = restY$6;
        }
      }
    }
  }
};
const ListScalarView$dropWhile = (xs$1, keep$2) => {
  const $t$10 = xs$1;
  const $t$9 = List$base(xs$1);
  xs$1 = List$offset(xs$1);
  for (;;) {
    if ($t$9.length === xs$1) {
      return $t$9.length - xs$1 === $t$10.length ? $t$10 : List$view($t$9, xs$1);
    } else {
      const x$3 = $t$9[xs$1];
      const rest$4 = xs$1 + 1;
      if (keep$2(x$3)) {
        xs$1 = rest$4;
      } else {
        return $t$9.length - xs$1 === $t$10.length ? $t$10 : List$view($t$9, xs$1);
      }
    }
  }
};
const ListScalarView$capture = ($in$0, $in$1) => {
  const $t$11 = List$base($in$0);
  $in$0 = List$offset($in$0);
  for (;;) {
    const xs$1 = $in$0;
    const acc$2 = $in$1;
    if ($t$11.length === xs$1) {
      return acc$2;
    } else {
      const rest$3 = xs$1 + 1;
      $in$0 = rest$3;
      $in$1 = List$push(acc$2, () => List$view($t$11, rest$3).length);
    }
  }
};
const ListScalarView$notAWalk = (xs$1, n$2) => {
  for (;;) {
    if (xs$1.length === 0) {
      return n$2;
    } else {
      const rest$3 = List$view(xs$1, 1);
      xs$1 = List$drop(rest$3, 1);
      n$2 = n$2 - 1;
    }
  }
};
const ListScalarView$main = Node$printLines([]);
export { ListScalarView$main, ListScalarView$sum, ListScalarView$mapRec, ListScalarView$merge, ListScalarView$dropWhile, ListScalarView$capture, ListScalarView$notAWalk };
