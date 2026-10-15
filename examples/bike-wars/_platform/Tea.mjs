import { List$foldl, List$append, List$unsafeGet } from "../_core/List.mjs";
import { Cmd$items } from "../_platform/_browser/Cmd.mjs";
import { Task$openRoot, Task$spawnIn, Task$cancel, Task$andThen } from "../_core/Task.mjs";
import { Dict$empty, Dict$update, Dict$get, Dict$insert, Dict$member, Dict$foldl } from "../_core/Dict.mjs";
import { Maybe$withDefault } from "../_core/Maybe.mjs";
import { Hosted$compare, Hosted$retap, Hosted$closeRelay, Hosted$hear, Hosted$unhear, Hosted$fibered, Hosted$runHeard, Hosted$relay, Hosted$title } from "../_platform/_browser/Hosted.mjs";
import { Browser$hosted } from "../_platform/_browser/Browser.mjs";
const Tea$Idle = { $: "Idle", a: null };
const Tea$item = (host$1, it$2, state$3) => {
  switch (it$2.$) {
    case "Perform":
      {
        const job$4 = it$2.a;
        return undefined;
      }
    case "Now":
      {
        const job$5 = it$2.a;
        return undefined;
      }
    case "Keyed":
      {
        const path$6 = it$2.a;
        const policy$7 = it$2.b;
        const job$8 = it$2.c;
        return undefined;
      }
    case "KeyedNow":
      {
        const path$9 = it$2.a;
        const policy$10 = it$2.b;
        const job$11 = it$2.c;
        return undefined;
      }
    case "Cancel":
      {
        const path$12 = it$2.a;
        return undefined;
      }
    case "CancelAll":
      {
        const prefix$13 = it$2.a;
        return undefined;
      }
    default:
      {
        const work$17 = it$2.a;
        return undefined;
      }
  }
};
const Tea$perform = (host$1, cmd$2, state$3) => List$foldl(Cmd$items(cmd$2), state$3, (it$4, s$5) => Tea$item(host$1, it$4, s$5));
const Tea$start = (host$1, $p$1) => {
  const model$2 = $p$1.a;
  const cmd$3 = $p$1.b;
  return Tea$perform(host$1, cmd$3, { jobs: Dict$empty, live: Tea$Idle, model: model$2, scope: Task$openRoot(null) });
};
const Tea$step = (host$1, $p$2, state$4) => {
  const model$2 = $p$2.a;
  const cmd$3 = $p$2.b;
  return Tea$perform(host$1, cmd$3, { ...state$4, model: model$2 });
};
const Tea$want = (k$1, kind$2, t$3, d$4) => Dict$update(Hosted$compare, d$4, k$1, (current$5) => {
  const $t$3 = Maybe$withDefault(current$5, { a: kind$2, b: [] });
  const first$6 = $t$3.a;
  const taps$7 = $t$3.b;
  return { $: "Just", a: { a: first$6, b: List$append(taps$7, [t$3]) } };
});
const Tea$keep = (scope$1, wanted$2, k$3, l$4, d$5) => {
  const $t$4 = Dict$get(Hosted$compare, wanted$2, k$3);
  if ($t$4.$ === "Just") {
    const taps$6 = $t$4.a.b;
    Hosted$retap(l$4.relay, taps$6);
    return Dict$insert(Hosted$compare, d$5, k$3, l$4);
  } else {
    l$4.stop(scope$1);
    return d$5;
  }
};
const Tea$inFiber$s = (scope$1, r$2, body$3) => {
  const fiber$4 = Task$spawnIn(scope$1, body$3);
  return (s$5) => {
    Hosted$closeRelay(r$2);
    Task$spawnIn(s$5, () => Task$cancel(fiber$4));
    return null;
  };
};
const Tea$hear = (r$1) => {
  Hosted$hear(r$1);
  return ($p$6) => Hosted$unhear(r$1);
};
const Tea$begin = (scope$1, r$2, kind$3) => Hosted$fibered(null) ? Tea$inFiber$s(scope$1, r$2, () => Hosted$runHeard(r$2)) : Tea$hear(r$2);
const Tea$arrive = (host$1, scope$2, k$3, kind$4, taps$5, d$6) => {
  const $t$8 = Dict$member(Hosted$compare, d$6, k$3);
  $j$0$1: {
    if (!$t$8) {
      if (taps$5.length > 0) {
        const first$7 = List$unsafeGet(taps$5, 0);
        const r$8 = Hosted$relay(host$1, first$7);
        Hosted$retap(r$8, taps$5);
        return Dict$insert(Hosted$compare, d$6, k$3, { relay: r$8, stop: Tea$begin(scope$2, r$8, kind$4) });
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  return d$6;
};
const Tea$diff = (host$1, scope$2, declared$3, live$4) => {
  const wanted$5 = List$foldl(declared$3, Dict$empty, ($p$9, d$10) => {
    const k$7 = $p$9.a;
    const kind$8 = $p$9.b;
    const t$9 = $p$9.c;
    return Tea$want(k$7, kind$8, t$9, d$10);
  });
  const kept$6 = Dict$foldl(live$4, Dict$empty, (k$11, l$12, d$13) => Tea$keep(scope$2, wanted$5, k$11, l$12, d$13));
  return Dict$foldl(wanted$5, kept$6, (k$14, $p$10, d$17) => {
    const kind$15 = $p$10.a;
    const taps$16 = $p$10.b;
    return Tea$arrive(host$1, scope$2, k$14, kind$15, taps$16, d$17);
  });
};
const Tea$lives = (l$1) => {
  if (l$1.$ === "Idle") {
    return Dict$empty;
  } else {
    const live$2 = l$1.a;
    return live$2;
  }
};
const Tea$settle = (host$1, sub$2, state$3) => {
  if (sub$2.$ === "None") {
    const $t$11 = state$3.live;
    if ($t$11.$ === "Idle") {
      return state$3;
    } else {
      const live$5 = $t$11.a;
      return { ...state$3, live: { $: "Running", a: Tea$diff(host$1, state$3.scope, [], live$5) } };
    }
  } else {
    const declared$4 = sub$2.a;
    return { ...state$3, live: { $: "Running", a: Tea$diff(host$1, state$3.scope, declared$4, Tea$lives(state$3.live)) } };
  }
};
const Tea$element = (app$1) => {
  const $t$12 = (host$2) => Tea$start(host$2, app$1.init(null));
  const $t$13 = (host$3, msg$4, state$5) => Tea$step(host$3, app$1.update(msg$4, state$5.model), state$5);
  const $t$14 = (host$6, state$7) => Tea$settle(host$6, app$1.subscriptions(state$7.model), state$7);
  const $t$15 = (state$8) => app$1.view(state$8.model);
  return Browser$hosted({ init: $t$12, settle: $t$14, update: $t$13, view: $t$15 });
};
const Tea$titled = (page$1) => {
  Hosted$title(page$1.title);
  return page$1.body;
};
const Tea$document = (app$1) => {
  const $t$16 = app$1.init;
  const $t$17 = app$1.update;
  const $t$18 = (model$2) => Tea$titled(app$1.view(model$2));
  const $t$19 = app$1.subscriptions;
  return Tea$element({ init: $t$16, subscriptions: $t$19, update: $t$17, view: $t$18 });
};
export { Tea$element, Tea$document };
//# sourceMappingURL=Tea.mjs.map
