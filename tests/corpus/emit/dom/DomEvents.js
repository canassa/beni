import { template as $markup$template, delegate as $markup$delegate, listen as $markup$listen, identity as $markup$identity } from "./_platform/runtime.foreign.mjs";
import { Html$targetValue } from "./_platform/_html/Html.mjs";
const DomEvents$t16 = $markup$template("<form><button>go</button><input>", 0);
const DomEvents$k16 = { m: (v$8, cx$9) => {
  const r$10 = DomEvents$t16();
  const w$11 = r$10.firstChild;
  const w$12 = w$11.nextSibling;
  $markup$delegate(["submit", "click", "input", "keydown"]);
  r$10.$$submit = v$8[0];
  r$10.$$submitF = 1;
  if (cx$9 !== null) {
    r$10.$$cx = cx$9;
  }
  w$11.$$click = v$8[1];
  if (cx$9 !== null) {
    w$11.$$cx = cx$9;
  }
  w$12.$$input = v$8[2];
  w$12.$$inputX = Html$targetValue;
  if (cx$9 !== null) {
    w$12.$$cx = cx$9;
  }
  w$12.$$focus = v$8[3];
  $markup$listen(w$12, "focus", 0);
  w$12.$$keydown = v$8[4];
  w$12.$$keydownX = $markup$identity;
  return { s: r$10, q: null, e: r$10, w0: r$10, w1: w$11, w3: w$12, a0: v$8[0], a1: v$8[1], a2: v$8[2], a3: v$8[3], a4: v$8[4] };
}, p: (i$13, v$14) => {
  if (v$14[0] !== i$13.a0) {
    i$13.a0 = v$14[0];
    i$13.w0.$$submit = v$14[0];
  }
  if (v$14[1] !== i$13.a1) {
    i$13.a1 = v$14[1];
    i$13.w1.$$click = v$14[1];
  }
  if (v$14[2] !== i$13.a2) {
    i$13.a2 = v$14[2];
    i$13.w3.$$input = v$14[2];
  }
  if (v$14[3] !== i$13.a3) {
    i$13.a3 = v$14[3];
    i$13.w3.$$focus = v$14[3];
  }
  if (v$14[4] !== i$13.a4) {
    i$13.a4 = v$14[4];
    i$13.w3.$$keydown = v$14[4];
  }
} };
const DomEvents$view = (n$1) => {
  const $t$1 = { $: "Sent", a: null };
  const $t$2 = { $: "Clicked", a: n$1 };
  const $t$4 = ($x$3) => ({ $: "Typed", a: $x$3 });
  const $t$5 = { $: "Focused", a: null };
  const $t$7 = ($x$6) => ({ $: "Down", a: $x$6 });
  return { t: DomEvents$k16, v: [$t$1, $t$2, $t$4, $t$5, $t$7] };
};
export { DomEvents$view };
