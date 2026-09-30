import { List$unsafeGet, List$view, List$cons } from "./_core/List.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const TailModConsLoop$mapRec = (xs$1, f$2) => {
  const $root = [];
  for (;;) {
    if (xs$1.length === 0) {
      return $root;
    } else {
      const x$3 = List$unsafeGet(xs$1, 0);
      const rest$4 = List$view(xs$1, 1);
      $root.push(f$2(x$3));
      xs$1 = rest$4;
    }
  }
};
const TailModConsLoop$twice = (xs$1) => {
  const $root = [];
  for (;;) {
    if (xs$1.length === 0) {
      return $root;
    } else {
      const x$2 = List$unsafeGet(xs$1, 0);
      const rest$3 = List$view(xs$1, 1);
      $root.push(x$2);
      $root.push(x$2);
      xs$1 = rest$3;
    }
  }
};
const TailModConsLoop$filterRec = (xs$1, keep$2) => {
  const $root = [];
  for (;;) {
    if (xs$1.length === 0) {
      return $root;
    } else {
      const x$3 = List$unsafeGet(xs$1, 0);
      const rest$4 = List$view(xs$1, 1);
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
