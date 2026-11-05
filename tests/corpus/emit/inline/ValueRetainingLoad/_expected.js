import { W1$init, W1$replace, W1$update, W1$view$$html$0, W1$update$$arm$0, W1$view$$root$0 } from "./W1.mjs";
import { W2$init, W2$replace, W2$update, W2$view$$html$0, W2$update$$arm$0, W2$update$$arm$1, W2$view$$root$0 } from "./W2.mjs";
import { Cmd$none } from "./_platform/_browser-inline/Cmd.mjs";
import { Inline$loadJob, Inline$runLoad, Inline$namedRoot, Inline$root, Inline$own, Inline$part, Inline$bucket, Inline$passes, Inline$pass, Inline$first, Inline$guarded, Inline$unchanged, Inline$client } from "./_platform/_browser-inline/Inline.mjs";
import { Schema$validContext } from "./_core/Schema.mjs";
import { Push$onPush$$lift$0 } from "./_platform/Push.mjs";
const ValueRetainingLoad$loadJob$1 = Inline$loadJob(($t$1, $t$2) => {
  const $t$3 = $t$1.w2;
  const $t$4 = $t$2.w2;
  const $t$5 = W2$replace($t$3, $t$4);
  if ($t$5 !== $t$4) {
    globalThis.Object.assign($t$4, $t$5);
  }
  return $t$2;
});
const ValueRetainingLoad$init = () => ({ a: { w1: W1$init(), w2: W2$init() }, b: Cmd$none });
const ValueRetainingLoad$replaced = (widget$1, state$2, model$3) => {
  switch (widget$1) {
    case "w1":
      {
        return model$3.w1 = W1$replace(state$2, model$3.w1), model$3;
      }
    case "w2":
      {
        return Inline$runLoad(ValueRetainingLoad$loadJob$1, { w2: state$2 }, model$3);
      }
    default:
      {
        return model$3;
      }
  }
};
const ValueRetainingLoad$Widgets$$readValid = (c, d, p, k, n, v) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return c.fail;
  }
  const $before$1 = 0;
  if (c.reject) {
    for (const $key$2 of globalThis.Object.keys(v)) {
      if ($key$2 !== "w1" && $key$2 !== "w2") {
        c.fail;
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$4 = d >= c.max;
  const $x$6 = v["w1"];
  if ($deep$4 || $x$6 === undefined) {
    return c.fail;
  }
  const $x$8 = v["w2"];
  if ($deep$4 || $x$8 === undefined) {
    return c.fail;
  }
  if (0 > $before$1) {
    return c.fail;
  }
  return { w1: $x$6, w2: $x$8 };
};
const ValueRetainingLoad$Snapshot$$readValid = (c, d, p, k, n, v) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return c.fail;
  }
  const $before$1 = 0;
  if (c.reject) {
    for (const $key$2 of globalThis.Object.keys(v)) {
      if ($key$2 !== "widgets") {
        c.fail;
        if (!c.all) {
          return c.fail;
        }
      }
    }
  }
  const $deep$4 = d >= c.max;
  const $x$6 = v["widgets"];
  if ($deep$4) {
    return c.fail;
  }
  const $f$5 = ValueRetainingLoad$Widgets$$readValid(c, d + 1, null, null, null, $x$6);
  if ($f$5 === c.fail && !c.all) {
    return c.fail;
  }
  if (0 > $before$1) {
    return c.fail;
  }
  return { widgets: $f$5 };
};
const ValueRetainingLoad$Event$$readValid = (c, d, p, k, n, v) => {
  if (typeof v !== "object" || v === null || globalThis.Array.isArray(v)) {
    return c.fail;
  }
  const $tag$1 = v["type"];
  switch ($tag$1) {
    case "serverSet":
      {
        if (d >= c.max) {
          return c.fail;
        }
        const $before$2 = 0;
        if (c.reject) {
          for (const $key$3 of globalThis.Object.keys(v)) {
            if ($key$3 !== "type" && $key$3 !== "widget" && $key$3 !== "state") {
              c.fail;
              if (!c.all) {
                return c.fail;
              }
            }
          }
        }
        const $deep$5 = d + 1 >= c.max;
        const $x$7 = v["widget"];
        if ($deep$5 || typeof $x$7 !== "string") {
          return c.fail;
        }
        const $x$9 = v["state"];
        if ($deep$5 || $x$9 === undefined) {
          return c.fail;
        }
        if (0 > $before$2) {
          return c.fail;
        }
        return { $: "ServerSet", a: { state: $x$9, widget: $x$7 } };
      }
    case "snapshot":
      {
        if (d >= c.max) {
          return c.fail;
        }
        const $before$10 = 0;
        if (c.reject) {
          for (const $key$11 of globalThis.Object.keys(v)) {
            if ($key$11 !== "type" && $key$11 !== "state") {
              c.fail;
              if (!c.all) {
                return c.fail;
              }
            }
          }
        }
        const $deep$13 = d + 1 >= c.max;
        const $x$15 = v["state"];
        if ($deep$13) {
          return c.fail;
        }
        const $f$14 = ValueRetainingLoad$Snapshot$$readValid(c, d + 2, null, null, null, $x$15);
        if ($f$14 === c.fail && !c.all) {
          return c.fail;
        }
        if (0 > $before$10) {
          return c.fail;
        }
        return { $: "Snapshot", a: { state: $f$14 } };
      }
    default:
      {
        return c.fail;
      }
  }
};
const ValueRetainingLoad$pushed = (value$1, model$2) => {
  const $t$1 = Schema$validContext();
  const $t$2 = ValueRetainingLoad$Event$$readValid($t$1, 0, null, null, null, value$1);
  const $t$3 = $t$2 === $t$1.fail ? { $: "Err", a: [] } : { $: "Ok", a: $t$2 };
  if ($t$3.$ === "Ok") {
    if ($t$3.a.$ === "ServerSet") {
      const event$3 = $t$3.a.a;
      return ValueRetainingLoad$replaced(event$3.widget, event$3.state, model$2);
    } else {
      const event$4 = $t$3.a.a;
      const widgets$5 = event$4.state.widgets;
      return { w1: W1$replace(widgets$5.w1, model$2.w1), w2: W2$replace(widgets$5.w2, model$2.w2) };
    }
  } else {
    return model$2;
  }
};
const ValueRetainingLoad$step = (msg$1, model$2) => {
  switch (msg$1.$) {
    case "W1Msg":
      {
        const sub$3 = msg$1.a;
        return W1$update(sub$3, model$2.w1), model$2;
      }
    case "W2Msg":
      {
        const sub$4 = msg$1.a;
        return W2$update(sub$4, model$2.w2), model$2;
      }
    default:
      {
        const value$5 = msg$1.a;
        return ValueRetainingLoad$pushed(value$5, model$2);
      }
  }
};
const ValueRetainingLoad$main = Inline$client(($id$2) => {
  const $root$3 = Inline$root(Inline$namedRoot("root"));
  const $init$4 = ValueRetainingLoad$init();
  const $cell$6 = [$init$4.a];
  $root$3.insertAdjacentHTML("beforeend", `<div data-role=app>${W1$view$$html$0}${W2$view$$html$0}`);
  const $node$7 = $root$3.lastChild;
  Inline$own(() => {
    $node$7.remove();
  });
  const $elements$8 = $node$7.querySelectorAll("*");
  const $elements$9 = Inline$part($elements$8[0]);
  const $elements$10 = Inline$part($elements$8[4]);
  const $table$11 = [[Inline$bucket(null), Inline$bucket(null), Inline$bucket(null), Inline$bucket(null)], [Inline$bucket(null), Inline$bucket(null), Inline$bucket(null), Inline$bucket(null)]];
  const $onPushed$1 = ($value$12) => {
    const $before$13 = $cell$6[0];
    const $result$14 = { a: ValueRetainingLoad$pushed($value$12, $before$13), b: Cmd$none };
    $cell$6[0] = $result$14.a;
    Inline$passes($table$11.flat());
  };
  const model$8 = $cell$6[0];
  W1$view$$root$0($elements$9, $cell$6, $table$11[0], () => {
    const $before$15 = $cell$6[0];
    const $t$16 = $before$15.w1;
    const $result$17 = { a: (W1$update$$arm$0($t$16), $before$15), b: Cmd$none };
    $cell$6[0] = $result$17.a;
    Inline$passes([$table$11[0][0], $table$11[0][1]]);
  });
  W2$view$$root$0($elements$10, $cell$6, $cell$6, $table$11[1], $table$11, ($value$18) => {
    const $before$19 = $cell$6[0];
    const $t$20 = $before$19.w2;
    const $result$21 = { a: (W2$update$$arm$0($value$18, $t$20), $before$19), b: Cmd$none };
    $cell$6[0] = $result$21.a;
    Inline$pass($table$11[1][3]);
  }, ($value$22) => {
    const $before$23 = $cell$6[0];
    const $t$24 = $before$23.w2;
    const $result$25 = { a: (W2$update$$arm$1($value$22, $t$24), $before$23), b: Cmd$none };
    $cell$6[0] = $result$25.a;
    Inline$passes([$table$11[1][0], $table$11[1][1], $table$11[1][2]]);
  });
  Inline$first();
  Inline$own(Push$onPush$$lift$0(($v$26) => Inline$guarded($onPushed$1, $v$26, Inline$unchanged)));
});
export { ValueRetainingLoad$main };
//# sourceMappingURL=ValueRetainingLoad.mjs.map
