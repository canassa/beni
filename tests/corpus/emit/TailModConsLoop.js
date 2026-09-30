import { List$cons } from "./_core/List.mjs";
import { Node$printLines } from "./_platform/Node.mjs";
const TailModConsLoop$mapRec = (xs$1, f$2) => {
  const $root = { $: 1, a: null, b: null };
  let $last = $root;
  for (;;) {
    if (xs$1.$ === 0) {
      $last.b = { $: 0, a: null, b: null };
      return $root.b;
    } else {
      const x$3 = xs$1.a;
      const rest$4 = xs$1.b;
      $last.b = { $: 1, a: f$2(x$3), b: null };
      $last = $last.b;
      xs$1 = rest$4;
    }
  }
};
const TailModConsLoop$twice = (xs$1) => {
  const $root = { $: 1, a: null, b: null };
  let $last = $root;
  for (;;) {
    if (xs$1.$ === 0) {
      $last.b = { $: 0, a: null, b: null };
      return $root.b;
    } else {
      const x$2 = xs$1.a;
      const rest$3 = xs$1.b;
      $last.b = { $: 1, a: x$2, b: null };
      $last = $last.b;
      $last.b = { $: 1, a: x$2, b: null };
      $last = $last.b;
      xs$1 = rest$3;
    }
  }
};
const TailModConsLoop$filterRec = (xs$1, keep$2) => {
  const $root = { $: 1, a: null, b: null };
  let $last = $root;
  for (;;) {
    if (xs$1.$ === 0) {
      $last.b = { $: 0, a: null, b: null };
      return $root.b;
    } else {
      const x$3 = xs$1.a;
      const rest$4 = xs$1.b;
      if (keep$2(x$3)) {
        $last.b = { $: 1, a: x$3, b: null };
        $last = $last.b;
        xs$1 = rest$4;
      } else {
        xs$1 = rest$4;
      }
    }
  }
};
const TailModConsLoop$plain = (n$1, xs$2) => List$cons(n$1, xs$2);
const TailModConsLoop$main = Node$printLines({ $: 0, a: null, b: null });
export { TailModConsLoop$main, TailModConsLoop$mapRec, TailModConsLoop$twice, TailModConsLoop$filterRec, TailModConsLoop$plain };
