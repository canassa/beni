import { Rt$template, Rt$delegate, Rt$listen, Rt$identity } from "./_platform/Rt.mjs";
import { Html$targetValue } from "./_platform/_html/Html.mjs";
const DomEvents$Focused = { $: "Focused", a: null };
const DomEvents$Sent = { $: "Sent", a: null };
const DomEvents$t16 = Rt$template("<form><button>go</button><input>", 0);
const DomEvents$k16 = { m: (v$6, cx$7) => {
  const r$8 = DomEvents$t16();
  const w$9 = r$8.firstChild;
  const w$10 = w$9.nextSibling;
  Rt$delegate(["submit", "click", "input", "keydown"]);
  r$8.$$submit = v$6[0];
  r$8.$$submitF = 1;
  if (cx$7 !== null) {
    r$8.$$cx = cx$7;
  }
  w$9.$$click = v$6[1];
  if (cx$7 !== null) {
    w$9.$$cx = cx$7;
  }
  w$10.$$input = v$6[2];
  w$10.$$inputX = Html$targetValue;
  if (cx$7 !== null) {
    w$10.$$cx = cx$7;
  }
  w$10.$$focus = v$6[3];
  Rt$listen(w$10, "focus", 0);
  w$10.$$keydown = v$6[4];
  w$10.$$keydownX = Rt$identity;
  return { s: r$8, q: null, e: r$8, w0: r$8, w1: w$9, w3: w$10, a0: v$6[0], a1: v$6[1], a2: v$6[2], a3: v$6[3], a4: v$6[4] };
}, p: (i$11, v$12) => {
  if (v$12[0] !== i$11.a0) {
    i$11.a0 = v$12[0];
    i$11.w0.$$submit = v$12[0];
  }
  if (v$12[1] !== i$11.a1) {
    i$11.a1 = v$12[1];
    i$11.w1.$$click = v$12[1];
  }
  if (v$12[2] !== i$11.a2) {
    i$11.a2 = v$12[2];
    i$11.w3.$$input = v$12[2];
  }
  if (v$12[3] !== i$11.a3) {
    i$11.a3 = v$12[3];
    i$11.w3.$$focus = v$12[3];
  }
  if (v$12[4] !== i$11.a4) {
    i$11.a4 = v$12[4];
    i$11.w3.$$keydown = v$12[4];
  }
} };
const DomEvents$view = (n$1) => {
  const $t$1 = { $: "Clicked", a: n$1 };
  const $t$3 = ($x$2) => ({ $: "Typed", a: $x$2 });
  const $t$5 = ($x$4) => ({ $: "Down", a: $x$4 });
  return { t: DomEvents$k16, v: [DomEvents$Sent, $t$1, $t$3, DomEvents$Focused, $t$5] };
};
export { DomEvents$view };
//# sourceMappingURL=DomEvents.mjs.map
