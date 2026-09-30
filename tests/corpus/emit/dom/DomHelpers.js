import { template as $markup$template, insertText as $markup$insertText, slot as $markup$slot, childHtml as $markup$childHtml, forKeyed as $markup$forKeyed, text as Html$text } from "./_platform/runtime.foreign.mjs";
const DomHelpers$t10 = $markup$template("<b> <!>", 0);
const DomHelpers$k10 = { m: (v$1, cx$2) => {
  const r$3 = DomHelpers$t10();
  const w$4 = r$3.firstChild;
  const w$5 = w$4.nextSibling;
  const x$6 = $markup$insertText(r$3, w$4, v$1[0]);
  const x$7 = $markup$insertText(r$3, w$5, v$1[1]);
  return { s: r$3, q: null, e: r$3, x0: x$6, x1: x$7, a0: v$1[0], a1: v$1[1] };
}, p: (i$8, v$9) => {
  if (v$9[0] !== i$8.a0) {
    i$8.a0 = v$9[0];
    i$8.x0.data = v$9[0];
  }
  if (v$9[1] !== i$8.a1) {
    i$8.a1 = v$9[1];
    i$8.x1.data = v$9[1];
  }
} };
const DomHelpers$t27 = $markup$template("<div><!><!>", 0);
const DomHelpers$k27 = { m: (v$10, cx$11) => {
  const r$12 = DomHelpers$t27();
  const w$13 = r$12.firstChild;
  const w$14 = w$13.nextSibling;
  const c$15 = $markup$slot(r$12, w$13, cx$11);
  const c$16 = $markup$slot(r$12, w$14, cx$11);
  $markup$childHtml(c$15, DomHelpers$label(v$10[0], v$10[1]));
  $markup$childHtml(c$16, DomHelpers$label(v$10[2], v$10[3]));
  return { s: r$12, q: null, e: r$12, c0: c$15, c1: c$16, a0_0: v$10[0], a0_1: v$10[1] };
}, p: (i$17, v$18) => {
  if (v$18[0] !== i$17.a0_0 || v$18[1] !== i$17.a0_1) {
    i$17.a0_0 = v$18[0];
    i$17.a0_1 = v$18[1];
    $markup$childHtml(i$17.c0, DomHelpers$label(v$18[0], v$18[1]));
  }
} };
const DomHelpers$t44 = $markup$template("<ul>", 0);
const DomHelpers$k44 = { m: (v$19, cx$20) => {
  const r$21 = DomHelpers$t44();
  const c$22 = $markup$slot(r$21, null, cx$20);
  $markup$forKeyed(c$22, v$19[0], null, v$19[1], null);
  return { s: r$21, q: null, e: r$21, c0: c$22 };
}, p: (i$23, v$24) => {
  $markup$forKeyed(i$23.c0, v$24[0], null, v$24[1], null);
} };
const DomHelpers$t42 = $markup$template("<li>", 0);
const DomHelpers$t69 = $markup$template("<b> ", 0);
const DomHelpers$k69 = { m: (v$34, cx$35) => {
  const r$36 = DomHelpers$t69();
  const w$37 = r$36.firstChild;
  w$37.data = v$34[0];
  return { s: r$36, q: null, e: r$36, w1: w$37, a0: v$34[0] };
}, p: (i$38, v$39) => {
  if (v$39[0] !== i$38.a0) {
    i$38.a0 = v$39[0];
    i$38.w1.data = v$39[0];
  }
} };
const DomHelpers$t85 = $markup$template("<i><!><!>", 0);
const DomHelpers$k85 = { m: (v$40, cx$41) => {
  const r$42 = DomHelpers$t85();
  const w$43 = r$42.firstChild;
  const w$44 = w$43.nextSibling;
  const x$45 = $markup$insertText(r$42, w$43, v$40[0]);
  const x$46 = $markup$insertText(r$42, w$44, v$40[1]);
  return { s: r$42, q: null, e: r$42, x0: x$45, x1: x$46, a0: v$40[0], a1: v$40[1] };
}, p: (i$47, v$48) => {
  if (v$48[0] !== i$47.a0) {
    i$47.a0 = v$48[0];
    i$47.x0.data = v$48[0];
  }
  if (v$48[1] !== i$47.a1) {
    i$47.a1 = v$48[1];
    i$47.x1.data = v$48[1];
  }
} };
const DomHelpers$t96 = $markup$template("<div><!><!><!>", 0);
const DomHelpers$k96 = { m: (v$52, cx$53) => {
  const r$54 = DomHelpers$t96();
  const w$55 = r$54.firstChild;
  const w$56 = w$55.nextSibling;
  const w$57 = w$56.nextSibling;
  const c$58 = $markup$slot(r$54, w$55, cx$53);
  const c$59 = $markup$slot(r$54, w$56, cx$53);
  const c$60 = $markup$slot(r$54, w$57, cx$53);
  $markup$childHtml(c$58, v$52[0]);
  $markup$childHtml(c$59, v$52[1]);
  $markup$childHtml(c$60, v$52[2]);
  return { s: r$54, q: null, e: r$54, c0: c$58, c1: c$59, c2: c$60 };
}, p: (i$61, v$62) => {
  $markup$childHtml(i$61.c0, v$62[0]);
  $markup$childHtml(i$61.c1, v$62[1]);
  $markup$childHtml(i$61.c2, v$62[2]);
} };
const DomHelpers$eq$prim = ($x, $y) => $x === $y;
const DomHelpers$label = (name$1, n$2) => ({ t: DomHelpers$k10, v: [name$1, n$2] });
const DomHelpers$page = (name$1, n$2) => ({ t: DomHelpers$k27, v: [name$1, n$2, "fixed", 1] });
const DomHelpers$rows = (names$1) => ({ t: DomHelpers$k44, v: [names$1, { m: (item$25, position$26, cx$27) => {
  const r$28 = DomHelpers$t42();
  const c$29 = $markup$slot(r$28, null, cx$27);
  $markup$childHtml(c$29, DomHelpers$label(item$25, 0));
  return { s: r$28, q: null, e: r$28, c0: c$29, a0_0: item$25 };
}, p: (i$30, item$31, position$32) => {
  if (item$31 !== i$30.a0_0) {
    i$30.a0_0 = item$31;
    $markup$childHtml(i$30.c0, DomHelpers$label(item$31, 0));
  }
}, i: false, f: null }] });
const DomHelpers$same = ($m$0, x$1, y$2) => {
  const $t$33 = $m$0(x$1, y$2) ? "same" : "different";
  return { t: DomHelpers$k69, v: [$t$33] };
};
const DomHelpers$others = (n$1) => {
  function twice$2(m$3) {
    return { t: DomHelpers$k85, v: [m$3, m$3] };
  }
  const $t$49 = DomHelpers$same(DomHelpers$eq$prim, n$1, 1);
  const $t$50 = twice$2(n$1);
  const $t$51 = Html$text("t");
  return { t: DomHelpers$k96, v: [$t$49, $t$50, $t$51] };
};
export { DomHelpers$page, DomHelpers$rows, DomHelpers$others };
