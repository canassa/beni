import { Io$sleep } from "./_platform/Io.mjs";
import { Basics$add, Basics$mul, Basics$sub } from "./_core/Basics.mjs";
import { Task$andThen, Task$isWaiting } from "./_core/Task.mjs";
const SuspendShapes$fetch = (n$1) => Task$andThen(Io$sleep(n$1), ($t$1) => Basics$add(n$1, 1));
const SuspendShapes$pick = (n$1) => {
  const $k$2 = ($t$3) => {
    const m$2 = $t$3;
    return Basics$mul(m$2, 2);
  };
  if (n$1 > 0) {
    return Task$andThen(SuspendShapes$fetch(n$1), ($t$4) => $k$2($t$4));
  } else {
    return $k$2(0);
  }
};
const SuspendShapes$total = ($in$0, $in$1) => {
  SuspendShapes$total: while (true) {
    const xs$1 = $in$0;
    const acc$2 = $in$1;
    if (xs$1.$ === 0) {
      return acc$2;
    } else {
      const x$3 = xs$1.a;
      const rest$4 = xs$1.b;
      const $t$5 = SuspendShapes$fetch(x$3);
      if (Task$isWaiting($t$5)) {
        return Task$andThen($t$5, ($t$5) => {
          $in$0 = rest$4;
          $in$1 = Basics$add(acc$2, $t$5);
          return SuspendShapes$total($in$0, $in$1);
        });
      }
      $in$0 = rest$4;
      $in$1 = Basics$add(acc$2, $t$5);
      continue SuspendShapes$total;
    }
  }
};
const SuspendShapes$twice = (f$1, x$2) => f$1(f$1(x$2));
const SuspendShapes$twice$s = (f$1, x$2) => Task$andThen(f$1(x$2), ($t$6) => f$1($t$6));
const SuspendShapes$both = (n$1) => Task$andThen(SuspendShapes$twice$s(SuspendShapes$fetch, n$1), ($t$8) => Basics$add($t$8, SuspendShapes$twice((k$2) => Basics$add(k$2, 1), n$1)));
const SuspendShapes$plain = (n$1) => n$1 <= 0 ? 0 : Basics$add(n$1, SuspendShapes$plain(Basics$sub(n$1, 1)));
export { SuspendShapes$fetch, SuspendShapes$pick, SuspendShapes$total, SuspendShapes$both, SuspendShapes$plain };
