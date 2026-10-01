import { Rt$template, Rt$insertText, Rt$attr } from "./_platform/Rt.mjs";
const DomTemplates$t3 = Rt$template("<div class=\"a b\"id=x><span>hi</span><br><p>there <b>you &amp; me", 0);
const DomTemplates$k3 = { m: (v$1, cx$2) => {
  const r$3 = DomTemplates$t3();
  return { s: r$3, q: null, e: r$3 };
}, p: (i$4, v$5) => {
} };
const DomTemplates$b3 = { t: DomTemplates$k3, v: null };
const DomTemplates$t19 = Rt$template("<p>Hello <!>, you have <!> items and <!> more.", 0);
const DomTemplates$k19 = { m: (v$9, cx$10) => {
  const r$11 = DomTemplates$t19();
  const w$12 = r$11.firstChild.nextSibling;
  const w$13 = w$12.nextSibling.nextSibling;
  const w$14 = w$13.nextSibling.nextSibling;
  const x$15 = Rt$insertText(r$11, w$12, v$9[0]);
  const x$16 = Rt$insertText(r$11, w$13, v$9[1]);
  const x$17 = Rt$insertText(r$11, w$14, v$9[2]);
  return { s: r$11, q: null, e: r$11, x0: x$15, x1: x$16, x2: x$17, a0: v$9[0], a1: v$9[1], a2: v$9[2] };
}, p: (i$18, v$19) => {
  if (v$19[0] !== i$18.a0) {
    i$18.a0 = v$19[0];
    i$18.x0.data = v$19[0];
  }
  if (v$19[1] !== i$18.a1) {
    i$18.a1 = v$19[1];
    i$18.x1.data = v$19[1];
  }
  if (v$19[2] !== i$18.a2) {
    i$18.a2 = v$19[2];
    i$18.x2.data = v$19[2];
  }
} };
const DomTemplates$t32 = Rt$template("<tr><td class=col-md-1> </td><td class=col-md-4><a> ", 0);
const DomTemplates$k32 = { m: (v$22, cx$23) => {
  const r$24 = DomTemplates$t32();
  const w$25 = r$24.firstChild;
  const w$26 = w$25.firstChild;
  const w$27 = w$25.nextSibling;
  const w$28 = w$27.firstChild;
  const w$29 = w$28.firstChild;
  w$26.data = v$22[0];
  w$29.data = v$22[1];
  return { s: r$24, q: null, e: r$24, w2: w$26, w5: w$29, a0: v$22[0], a1: v$22[1] };
}, p: (i$30, v$31) => {
  if (v$31[0] !== i$30.a0) {
    i$30.a0 = v$31[0];
    i$30.w2.data = v$31[0];
  }
  if (v$31[1] !== i$30.a1) {
    i$30.a1 = v$31[1];
    i$30.w5.data = v$31[1];
  }
} };
const DomTemplates$t51 = Rt$template("<div aria-label=static><input disabled type=text>", 0);
const DomTemplates$k51 = { m: (v$36, cx$37) => {
  const r$38 = DomTemplates$t51();
  r$38.setAttribute("id", v$36[0]);
  r$38.setAttribute("title", v$36[1]);
  Rt$attr(r$38, "hidden", v$36[2] ? "" : null);
  r$38.setAttribute("tabindex", v$36[3]);
  return { s: r$38, q: null, e: r$38, w0: r$38, a0: v$36[0], a1: v$36[1], a2: v$36[2], a3: v$36[3] };
}, p: (i$39, v$40) => {
  if (v$40[0] !== i$39.a0) {
    i$39.w0.setAttribute("id", v$40[0]);
    i$39.a0 = v$40[0];
  }
  if (v$40[1] !== i$39.a1) {
    i$39.w0.setAttribute("title", v$40[1]);
    i$39.a1 = v$40[1];
  }
  if (v$40[2] !== i$39.a2) {
    Rt$attr(i$39.w0, "hidden", v$40[2] ? "" : null);
    i$39.a2 = v$40[2];
  }
  if (v$40[3] !== i$39.a3) {
    i$39.w0.setAttribute("tabindex", v$40[3]);
    i$39.a3 = v$40[3];
  }
} };
const DomTemplates$t55 = Rt$template("<!>", 0);
const DomTemplates$k55 = { m: (v$41, cx$42) => {
  const r$43 = DomTemplates$t55();
  return { s: r$43, q: null, e: r$43 };
}, p: (i$44, v$45) => {
} };
const DomTemplates$b55 = { t: DomTemplates$k55, v: null };
const DomTemplates$static = DomTemplates$b3;
const DomTemplates$text = (r$1) => {
  const $t$6 = r$1.name;
  const $t$7 = r$1.count;
  const $t$8 = r$1.more;
  return { t: DomTemplates$k19, v: [$t$6, $t$7, $t$8] };
};
const DomTemplates$only = (row$1) => {
  const $t$20 = row$1.id;
  const $t$21 = row$1.label;
  return { t: DomTemplates$k32, v: [$t$20, $t$21] };
};
const DomTemplates$attributes = (r$1) => {
  const $t$32 = r$1.id;
  const $t$33 = r$1.title;
  const $t$34 = r$1.off;
  const $t$35 = r$1.tab;
  return { t: DomTemplates$k51, v: [$t$32, $t$33, $t$34, $t$35] };
};
const DomTemplates$nothing = DomTemplates$b55;
export { DomTemplates$static, DomTemplates$text, DomTemplates$only, DomTemplates$attributes, DomTemplates$nothing };
