import { Rt$template, Rt$childHtml, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { Card$view } from "./Card.mjs";
const DomComponents$t14n4 = Rt$template("Welcome, <b> </b>!", 4);
const DomComponents$k14n4 = { m: (v$7, cx$8) => {
  const r$9 = DomComponents$t14n4();
  const w$10 = r$9.firstChild;
  const w$11 = w$10.nextSibling;
  const w$12 = w$11.firstChild;
  const w$13 = w$11.nextSibling;
  w$12.data = v$7[0];
  return { s: w$10, q: null, e: w$13, w2: w$12, a0: v$7[0] };
}, p: (i$14, v$15) => {
  if (v$15[0] !== i$14.a0) {
    i$14.a0 = v$15[0];
    i$14.w2.data = v$15[0];
  }
} };
const DomComponents$t14n6 = Rt$template("no values", 0);
const DomComponents$k14n6 = { m: (v$17, cx$18) => {
  const r$19 = DomComponents$t14n6();
  return { s: r$19, q: null, e: r$19 };
}, p: (i$20, v$21) => {
} };
const DomComponents$b14n6 = { t: DomComponents$k14n6, v: null };
const DomComponents$p14 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if ($in$3.title !== i$1.g0_0 || $in$3.name !== i$1.g0_1) {
    i$1.g0_0 = $in$3.title;
    i$1.g0_1 = $in$3.name;
    const $t$4 = $in$3.title;
    const $t$5 = $in$3.name;
    const made$6 = { t: DomComponents$k14n4, v: [$t$5] };
    if ($t$4 !== i$1.a0_0 || made$6 !== i$1.a0c) {
      i$1.a0_0 = $t$4;
      i$1.a0c = made$6;
      Rt$childHtml(i$1.c0, Card$view({ children: made$6, title: $t$4 }));
    } else {
      Rt$restate(i$1.c0);
    }
  } else {
    Rt$restate(i$1.c0);
  }
  if (i$1.g1 === undefined) {
    i$1.g1 = true;
    const made$16 = DomComponents$b14n6;
    if (made$16 !== i$1.a1c) {
      i$1.a1c = made$16;
      Rt$childHtml(i$1.c1, Card$view({ children: made$16, title: "static" }));
    } else {
      Rt$restate(i$1.c1);
    }
  } else {
    Rt$restate(i$1.c1);
  }
  i$1.l = i$1.c0.l || i$1.c1.l;
};
const DomComponents$t14 = Rt$template("<main><!><!>", 0);
const DomComponents$k14 = { m: (v$22, cx$23) => {
  const r$24 = DomComponents$t14();
  const w$25 = r$24.firstChild;
  const w$26 = w$25.nextSibling;
  const c$27 = Rt$slot(r$24, w$25, cx$23);
  const c$28 = Rt$slot(r$24, w$26, cx$23);
  const i$29 = { s: r$24, q: null, e: r$24, c0: c$27, c1: c$28, a0_0: undefined, a0c: undefined, a1c: undefined, g0_0: NaN, g0_1: NaN, g1: undefined };
  DomComponents$p14(i$29, v$22);
  return i$29;
}, p: DomComponents$p14, l: true };
const DomComponents$page = (r$1) => ({ t: DomComponents$k14, v: [r$1] });
export { DomComponents$page };
//# sourceMappingURL=DomComponents.mjs.map
