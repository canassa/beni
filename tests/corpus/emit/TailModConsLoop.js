import { List$base, List$offset, List$cons } from "./_core/List.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const TailModConsLoop$mapRec = (xs$1, f$2) => {
  const $t$1 = List$base(xs$1);
  xs$1 = List$offset(xs$1);
  const $root = [];
  for (;;) {
    if ($t$1.length === xs$1) {
      return $root;
    } else {
      const x$3 = $t$1[xs$1];
      const rest$4 = xs$1 + 1;
      $root.push(f$2(x$3));
      xs$1 = rest$4;
    }
  }
};
const TailModConsLoop$twice = (xs$1) => {
  const $t$3 = List$base(xs$1);
  xs$1 = List$offset(xs$1);
  const $root = [];
  for (;;) {
    if ($t$3.length === xs$1) {
      return $root;
    } else {
      const x$2 = $t$3[xs$1];
      const rest$3 = xs$1 + 1;
      $root.push(x$2);
      $root.push(x$2);
      xs$1 = rest$3;
    }
  }
};
const TailModConsLoop$filterRec = (xs$1, keep$2) => {
  const $t$5 = List$base(xs$1);
  xs$1 = List$offset(xs$1);
  const $root = [];
  for (;;) {
    if ($t$5.length === xs$1) {
      return $root;
    } else {
      const x$3 = $t$5[xs$1];
      const rest$4 = xs$1 + 1;
      if (keep$2(x$3)) {
        $root.push(x$3);
        xs$1 = rest$4;
      } else {
        xs$1 = rest$4;
      }
    }
  }
};
const TailModConsLoop$plain = (n$1, xs$2) => List$cons(n$1, xs$2);
const TailModConsLoop$main = Node$printLines([]);
export { TailModConsLoop$main, TailModConsLoop$mapRec, TailModConsLoop$twice, TailModConsLoop$filterRec, TailModConsLoop$plain };
//# sourceMappingURL=TailModConsLoop.mjs.map
