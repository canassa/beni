import { Io$sleep } from "./_platform/Io.mjs";
import { Task$andThen, Task$isWaiting } from "./_core/Task.mjs";
import { List$unsafeGet, List$view, List$close } from "./_core/List.mjs";
const SuspendShapes$fetch = (n$1) => Task$andThen(Io$sleep(n$1), ($t$1) => n$1 + 1);
const SuspendShapes$pick = (n$1) => {
  const $k$2 = ($t$3) => {
    const m$2 = $t$3;
    return m$2 * 2;
  };
  if (n$1 > 0) {
    return Task$andThen(SuspendShapes$fetch(n$1), ($t$4) => $k$2($t$4));
  } else {
    return $k$2(0);
  }
};
const SuspendShapes$total = ($in$0, $in$1) => {
  SuspendShapes$total: for (;;) {
    const xs$1 = $in$0;
    const acc$2 = $in$1;
    if (xs$1.length === 0) {
      return acc$2;
    } else {
      const x$3 = List$unsafeGet(xs$1, 0);
      const rest$4 = List$view(xs$1, 1);
      const $t$5 = SuspendShapes$fetch(x$3);
      if (Task$isWaiting($t$5)) {
        return Task$andThen($t$5, ($t$5) => {
          $in$0 = rest$4;
          $in$1 = acc$2 + $t$5;
          return SuspendShapes$total($in$0, $in$1);
        });
      }
      $in$0 = rest$4;
      $in$1 = acc$2 + $t$5;
    }
  }
};
const SuspendShapes$fetchAll = ($in$0) => {
  const $root = [];
  SuspendShapes$fetchAll: for (;;) {
    const xs$1 = $in$0;
    if (xs$1.length === 0) {
      return $root;
    } else {
      const x$2 = List$unsafeGet(xs$1, 0);
      const rest$3 = List$view(xs$1, 1);
      const $t$6 = SuspendShapes$fetch(x$2);
      if (Task$isWaiting($t$6)) {
        return Task$andThen($t$6, ($t$6) => {
          $root.push($t$6);
          $in$0 = rest$3;
          return Task$andThen(SuspendShapes$fetchAll($in$0), ($built) => List$close($root, $built));
        });
      }
      $root.push($t$6);
      $in$0 = rest$3;
    }
  }
};
const SuspendShapes$twice = (f$1, x$2) => f$1(f$1(x$2));
const SuspendShapes$twice$s = (f$1, x$2) => Task$andThen(f$1(x$2), ($t$7) => f$1($t$7));
const SuspendShapes$both = (n$1) => Task$andThen(SuspendShapes$twice$s(SuspendShapes$fetch, n$1), ($t$9) => $t$9 + SuspendShapes$twice((k$2) => k$2 + 1, n$1));
const SuspendShapes$plain = (n$1) => n$1 <= 0 ? 0 : n$1 + SuspendShapes$plain(n$1 - 1);
export { SuspendShapes$fetch, SuspendShapes$pick, SuspendShapes$total, SuspendShapes$fetchAll, SuspendShapes$both, SuspendShapes$plain };
