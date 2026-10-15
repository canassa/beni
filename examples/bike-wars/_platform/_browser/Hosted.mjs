import { keyOf as Hosted$keyOf, compareKeys as Hosted$compareKeys } from "./Hosted.foreign.mjs";
import { List$base, List$offset } from "../../_core/List.mjs";
import { Task$soon, Task$onShutdown, Task$andThen } from "../../_core/Task.mjs";
import { Listen$each$s } from "../../_platform/_browser/Listen.mjs";
const Hosted$host = (x$1) => x$1;
const Hosted$guest = (v$1) => v$1;
const Hosted$send = (h$1, msg$2) => h$1.send(msg$2);
const Hosted$key = ($m$0, $m$1, k$1) => Hosted$keyOf($m$0, $m$1, k$1);
const Hosted$compare = (a$1, b$2) => Hosted$compareKeys(a$1, b$2);
const Hosted$hook = (start$1, tag$2) => Hosted$guest([Hosted$host(start$1), Hosted$host(tag$2)]);
const Hosted$relay = (h$1, tp$2) => Hosted$guest({ b: Hosted$host(tp$2)[0], h: Hosted$host(h$1), open: true, q: null, t: Hosted$host([tp$2]), x: null });
const Hosted$through = (h$1, taps$2, value$3) => {
  const $t$1 = List$base(taps$2);
  taps$2 = List$offset(taps$2);
  while ($t$1.length !== taps$2) {
    const tp$4 = $t$1[taps$2];
    const rest$5 = taps$2 + 1;
    Hosted$send(h$1, tp$4[1](value$3));
    taps$2 = rest$5;
  }
  return null;
};
const Hosted$tagged = (r$1, value$2) => r$1.open ? Hosted$through(r$1.h, Hosted$guest(r$1.t), value$2) : null;
const Hosted$heard = new globalThis.Set();
let Hosted$released = false;
const Hosted$queue = (work$1) => {
  Task$soon(work$1);
  return null;
};
const Hosted$deliverQueued = (r$1, i$2) => {
  for (;;) {
    const q$3 = r$1.q;
    if (i$2 < q$3.length) {
      Hosted$tagged(r$1, q$3[i$2]);
      i$2 = i$2 + 1;
    } else {
      r$1.q = null;
      return null;
    }
  }
};
const Hosted$arrive = (r$1, value$2) => {
  const q$3 = r$1.q;
  if (q$3 === null) {
    r$1.q = [value$2];
    return Hosted$queue(() => Hosted$deliverQueued(r$1, 0));
  } else {
    return q$3.push(value$2);
  }
};
const Hosted$hear = (rl$1) => {
  const r$2 = Hosted$host(rl$1);
  return Hosted$queue(() => {
    if (r$2.open) {
      if (!Hosted$released) {
        Hosted$released = true;
        Task$onShutdown(() => {
          for (const x$3 of Hosted$heard) {
            x$3.x(null);
          }
          return Hosted$heard.clear();
        });
      }
      Hosted$heard.add(r$2);
      r$2.x = r$2.b((value$4) => Hosted$arrive(r$2, value$4));
      return null;
    } else {
      return null;
    }
  });
};
const Hosted$runHeard = (rl$1) => {
  const r$2 = Hosted$host(rl$1);
  return Listen$each$s(r$2.b, (value$3) => Hosted$tagged(r$2, value$3));
};
const Hosted$fibered = () => globalThis.__beniFiberSubscriptions === true;
const Hosted$retap = (r$1, taps$2) => {
  Hosted$host(r$1).t = Hosted$host(taps$2);
  return null;
};
const Hosted$closeRelay = (r$1) => {
  Hosted$host(r$1).open = false;
  return null;
};
const Hosted$unhear = (rl$1) => {
  const r$2 = Hosted$host(rl$1);
  r$2.open = false;
  const x$3 = r$2.x;
  if (x$3 === null) {
    return null;
  } else {
    r$2.x = null;
    Hosted$heard.delete(r$2);
    return x$3(null);
  }
};
const Hosted$title = (text$1) => {
  const document$2 = globalThis.document;
  if (document$2.title === text$1) {
    return null;
  } else {
    document$2.title = text$1;
    return null;
  }
};
export { Hosted$key, Hosted$compare, Hosted$hook, Hosted$relay, Hosted$hear, Hosted$runHeard, Hosted$fibered, Hosted$retap, Hosted$closeRelay, Hosted$unhear, Hosted$title };
//# sourceMappingURL=Hosted.mjs.map
