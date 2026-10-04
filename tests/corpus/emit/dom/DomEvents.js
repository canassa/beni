import { Rt$template, Rt$delegate, Rt$listen, Rt$identity } from "./_platform/Rt.mjs";
import { Html$targetValue } from "./_platform/_html/Html.mjs";
const DomEvents$Focused = { $: "Focused", a: null };
const DomEvents$Sent = { $: "Sent", a: null };
const DomEvents$p16 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if (i$1.g0 === undefined) {
    i$1.g0 = true;
    const $t$5 = ($x$4) => ({ $: "Typed", a: $x$4 });
    const $t$7 = ($x$6) => ({ $: "Down", a: $x$6 });
    if (DomEvents$Sent !== i$1.a0) {
      i$1.a0 = DomEvents$Sent;
      i$1.w0.$$submit = DomEvents$Sent;
    }
    if ($t$5 !== i$1.a2) {
      i$1.a2 = $t$5;
      i$1.w3.$$input = $t$5;
    }
    if (DomEvents$Focused !== i$1.a3) {
      i$1.a3 = DomEvents$Focused;
      i$1.w3.$$focus = DomEvents$Focused;
    }
    if ($t$7 !== i$1.a4) {
      i$1.a4 = $t$7;
      i$1.w3.$$keydown = $t$7;
    }
  }
  if ($in$3 !== i$1.g1_0) {
    i$1.g1_0 = $in$3;
    const $t$8 = { $: "Clicked", a: $in$3 };
    if ($t$8 !== i$1.a1) {
      i$1.a1 = $t$8;
      i$1.w1.$$click = $t$8;
    }
  }
};
const DomEvents$t16 = Rt$template("<form><button>go</button><input>", 0);
const DomEvents$k16 = { m: (v$9, cx$10) => {
  const r$11 = DomEvents$t16();
  const w$12 = r$11.firstChild;
  const w$13 = w$12.nextSibling;
  Rt$delegate(["submit", "click", "input", "keydown"]);
  r$11.$$submitF = 1;
  if (cx$10 !== null) {
    r$11.$$cx = cx$10;
  }
  if (cx$10 !== null) {
    w$12.$$cx = cx$10;
  }
  w$13.$$inputX = Html$targetValue;
  if (cx$10 !== null) {
    w$13.$$cx = cx$10;
  }
  Rt$listen(w$13, "focus", 0);
  w$13.$$keydownX = Rt$identity;
  const i$14 = { s: r$11, q: null, e: r$11, w0: r$11, w1: w$12, w3: w$13, a0: undefined, a1: undefined, a2: undefined, a3: undefined, a4: undefined, g0: undefined, g1_0: undefined };
  DomEvents$p16(i$14, v$9);
  return i$14;
}, p: DomEvents$p16 };
const DomEvents$view = (n$1) => ({ t: DomEvents$k16, v: [n$1] });
export { DomEvents$view };
//# sourceMappingURL=DomEvents.mjs.map
