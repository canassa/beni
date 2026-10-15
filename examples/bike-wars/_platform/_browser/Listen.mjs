import { Task$callback, Task$andThen, Task$isWaiting, Task$bracket$s } from "../../_core/Task.mjs";
const Listen$on = (target$1, name$2, read$3, send$4) => {
  const host$5 = globalThis[target$1];
  const handler$6 = (event$7) => send$4(read$3(event$7));
  host$5.addEventListener(name$2, handler$6);
  return () => host$5.removeEventListener(name$2, handler$6);
};
const Listen$open = (listener$1) => {
  const l$2 = [[], null, null];
  const handler$3 = (v$4) => {
    const waiting$5 = l$2[1];
    if (waiting$5 === null) {
      return l$2[0].push(v$4);
    } else {
      l$2[1] = null;
      return waiting$5(v$4);
    }
  };
  l$2[2] = listener$1(handler$3);
  return l$2;
};
const Listen$open$s = (listener$1) => {
  const l$2 = [[], null, null];
  const handler$3 = (v$4) => {
    const waiting$5 = l$2[1];
    if (waiting$5 === null) {
      return l$2[0].push(v$4);
    } else {
      l$2[1] = null;
      return waiting$5(v$4);
    }
  };
  l$2[2] = listener$1(handler$3);
  return l$2;
};
const Listen$close = (l$1) => l$1[2](null);
const Listen$take = (l$1, resume$2) => {
  const queue$3 = l$1[0];
  if (queue$3.length > 0) {
    resume$2(queue$3.shift());
    return null;
  } else {
    l$1[1] = resume$2;
    return () => {
      l$1[1] = null;
      return null;
    };
  }
};
const Listen$next = (l$1) => Task$callback((resume$2) => Listen$take(l$1, resume$2));
const Listen$pump$s = (l$1, f$2) => {
  Listen$pump$s: for (;;) {
    const $t$2 = Listen$next(l$1);
    if (Task$isWaiting($t$2)) {
      return Task$andThen($t$2, ($t$2) => Task$andThen(f$2($t$2), ($t$3) => Listen$pump$s(l$1, f$2)));
    }
    const $t$3 = f$2($t$2);
    if (Task$isWaiting($t$3)) {
      return Task$andThen($t$3, ($t$3) => Listen$pump$s(l$1, f$2));
    }
  }
};
const Listen$each$s = (listener$1, f$2) => Task$bracket$s(() => Listen$open$s(listener$1), (l$3, $p$4) => Listen$close(l$3), (l$4) => Listen$pump$s(l$4, f$2));
export { Listen$on, Listen$each$s };
//# sourceMappingURL=Listen.mjs.map
