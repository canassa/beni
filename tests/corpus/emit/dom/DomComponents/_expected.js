import { Rt$template, Rt$slot, Rt$childHtml } from "./_platform/Rt.mjs";
import { Card$view } from "./Card.mjs";
const DomComponents$t14 = Rt$template("<main><!><!>", 0);
const DomComponents$k14 = { m: (v$3, cx$4) => {
  const r$5 = DomComponents$t14();
  const w$6 = r$5.firstChild;
  const w$7 = w$6.nextSibling;
  const c$8 = Rt$slot(r$5, w$6, cx$4);
  const c$9 = Rt$slot(r$5, w$7, cx$4);
  Rt$childHtml(c$8, v$3[2](v$3[1]));
  Rt$childHtml(c$9, v$3[5](v$3[4]));
  return { s: r$5, q: null, e: r$5, c0: c$8, c1: c$9, a0_0: v$3[0], a0c: v$3[1], a1c: v$3[4] };
}, p: (i$10, v$11) => {
  if (v$11[0] !== i$10.a0_0 || v$11[1] !== i$10.a0c) {
    i$10.a0_0 = v$11[0];
    i$10.a0c = v$11[1];
    Rt$childHtml(i$10.c0, v$11[2](v$11[1]));
  }
  if (v$11[4] !== i$10.a1c) {
    i$10.a1c = v$11[4];
    Rt$childHtml(i$10.c1, v$11[5](v$11[4]));
  }
} };
const DomComponents$t14n4 = Rt$template("Welcome, <b> </b>!", 4);
const DomComponents$k14n4 = { m: (v$12, cx$13) => {
  const r$14 = DomComponents$t14n4();
  const w$15 = r$14.firstChild;
  const w$16 = w$15.nextSibling;
  const w$17 = w$16.firstChild;
  const w$18 = w$16.nextSibling;
  w$17.data = v$12[0];
  return { s: w$15, q: null, e: w$18, w2: w$17, a0: v$12[0] };
}, p: (i$19, v$20) => {
  if (v$20[0] !== i$19.a0) {
    i$19.a0 = v$20[0];
    i$19.w2.data = v$20[0];
  }
} };
const DomComponents$t14n6 = Rt$template("no values", 0);
const DomComponents$k14n6 = { m: (v$22, cx$23) => {
  const r$24 = DomComponents$t14n6();
  return { s: r$24, q: null, e: r$24 };
}, p: (i$25, v$26) => {
} };
const DomComponents$b14n6 = { t: DomComponents$k14n6, v: null };
const DomComponents$page = (r$1) => {
  const $t$1 = r$1.title;
  const $t$2 = r$1.name;
  return { t: DomComponents$k14, v: [$t$1, { t: DomComponents$k14n4, v: [$t$2] }, (children$21) => Card$view({ children: children$21, title: $t$1 }), "static", DomComponents$b14n6, (children$27) => Card$view({ children: children$27, title: "static" })] };
};
export { DomComponents$page };
