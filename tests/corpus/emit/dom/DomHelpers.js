import { Rt$template, Rt$insertText, Rt$childHtml, Rt$slot, Rt$forKeyed, Rt$text } from "./_platform/Rt.mjs";
const DomHelpers$p10 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  const $in$4 = v$2[1];
  const x$5 = $in$3;
  if (x$5 !== i$1.g0_0) {
    i$1.g0_0 = x$5;
    i$1.x0.data = x$5;
  }
  const x$6 = $in$4;
  if (x$6 !== i$1.g1_0) {
    i$1.g1_0 = x$6;
    i$1.x1.data = x$6;
  }
};
const DomHelpers$t10 = Rt$template("<b> <!>", 0);
const DomHelpers$k10 = { m: (v$7, cx$8) => {
  const r$9 = DomHelpers$t10();
  const w$10 = r$9.firstChild;
  const w$11 = w$10.nextSibling;
  const x$12 = Rt$insertText(r$9, w$10, "");
  const x$13 = Rt$insertText(r$9, w$11, "");
  const i$14 = { s: r$9, q: null, e: r$9, x0: x$12, x1: x$13, g0_0: undefined, g1_0: undefined };
  DomHelpers$p10(i$14, v$7);
  return i$14;
}, p: DomHelpers$p10 };
const DomHelpers$p27 = (i$15, v$16) => {
  const $in$17 = v$16[0];
  const $in$18 = v$16[1];
  if ($in$17 !== i$15.g0_0 || $in$18 !== i$15.g0_1) {
    i$15.g0_0 = $in$17;
    i$15.g0_1 = $in$18;
    if ($in$17 !== i$15.a0_0 || $in$18 !== i$15.a0_1) {
      i$15.a0_0 = $in$17;
      i$15.a0_1 = $in$18;
      Rt$childHtml(i$15.c0, DomHelpers$label($in$17, $in$18));
    }
  }
  if (i$15.g1 === undefined) {
    i$15.g1 = true;
    {
      Rt$childHtml(i$15.c1, DomHelpers$label("fixed", 1));
    }
  }
};
const DomHelpers$t27 = Rt$template("<div><!><!>", 0);
const DomHelpers$k27 = { m: (v$19, cx$20) => {
  const r$21 = DomHelpers$t27();
  const w$22 = r$21.firstChild;
  const w$23 = w$22.nextSibling;
  const c$24 = Rt$slot(r$21, w$22, cx$20);
  const c$25 = Rt$slot(r$21, w$23, cx$20);
  const i$26 = { s: r$21, q: null, e: r$21, c0: c$24, c1: c$25, a0_0: undefined, a0_1: undefined, g0_0: undefined, g0_1: undefined, g1: undefined };
  DomHelpers$p27(i$26, v$19);
  return i$26;
}, p: DomHelpers$p27 };
const DomHelpers$t42 = Rt$template("<li>", 0);
const DomHelpers$p44 = (i$27, v$28) => {
  const $in$29 = v$28[0];
  const x$30 = $in$29;
  if (x$30 !== i$27.g0_0) {
    i$27.g0_0 = x$30;
    const made$31 = { m: (item$32, position$33, cx$34) => {
      const r$35 = DomHelpers$t42();
      const c$36 = Rt$slot(r$35, null, cx$34);
      Rt$childHtml(c$36, DomHelpers$label(item$32, 0));
      return { s: r$35, q: null, e: r$35, c0: c$36, a0_0: item$32 };
    }, p: (i$37, item$38, position$39) => {
      if (item$38 !== i$37.a0_0) {
        i$37.a0_0 = item$38;
        Rt$childHtml(i$37.c0, DomHelpers$label(item$38, 0));
      }
    }, i: false, f: null };
    Rt$forKeyed(i$27.c0, $in$29, null, made$31, null);
  }
};
const DomHelpers$t44 = Rt$template("<ul>", 0);
const DomHelpers$k44 = { m: (v$40, cx$41) => {
  const r$42 = DomHelpers$t44();
  const c$43 = Rt$slot(r$42, null, cx$41);
  const i$44 = { s: r$42, q: null, e: r$42, c0: c$43, g0_0: undefined };
  DomHelpers$p44(i$44, v$40);
  return i$44;
}, p: DomHelpers$p44 };
const DomHelpers$t69 = Rt$template("<b> ", 0);
const DomHelpers$k69 = { m: (v$46, cx$47) => {
  const r$48 = DomHelpers$t69();
  const w$49 = r$48.firstChild;
  w$49.data = v$46[0];
  return { s: r$48, q: null, e: r$48, w1: w$49, a0: v$46[0] };
}, p: (i$50, v$51) => {
  if (v$51[0] !== i$50.a0) {
    i$50.a0 = v$51[0];
    i$50.w1.data = v$51[0];
  }
} };
const DomHelpers$p85 = (i$52, v$53) => {
  const $in$54 = v$53[0];
  const x$55 = $in$54;
  if (x$55 !== i$52.g0_0) {
    i$52.g0_0 = x$55;
    i$52.x0.data = x$55;
    i$52.x1.data = x$55;
  }
};
const DomHelpers$t85 = Rt$template("<i><!><!>", 0);
const DomHelpers$k85 = { m: (v$56, cx$57) => {
  const r$58 = DomHelpers$t85();
  const w$59 = r$58.firstChild;
  const w$60 = w$59.nextSibling;
  const x$61 = Rt$insertText(r$58, w$59, "");
  const x$62 = Rt$insertText(r$58, w$60, "");
  const i$63 = { s: r$58, q: null, e: r$58, x0: x$61, x1: x$62, g0_0: undefined };
  DomHelpers$p85(i$63, v$56);
  return i$63;
}, p: DomHelpers$p85 };
const DomHelpers$p96 = (i$64, v$65) => {
  const $in$66 = v$65[0];
  const $in$67 = v$65[1];
  const x$68 = $in$66;
  if (x$68 !== i$64.g0_0) {
    i$64.g0_0 = x$68;
    const $t$69 = DomHelpers$same(DomHelpers$eq$prim, $in$66, 1);
    Rt$childHtml(i$64.c0, $t$69);
  }
  if ($in$66 !== i$64.g1_0 || $in$67 !== i$64.g1_1) {
    i$64.g1_0 = $in$66;
    i$64.g1_1 = $in$67;
    const $t$70 = $in$67($in$66);
    Rt$childHtml(i$64.c1, $t$70);
  }
  if (i$64.g2 === undefined) {
    i$64.g2 = true;
    const $t$71 = Rt$text("t");
    Rt$childHtml(i$64.c2, $t$71);
  }
};
const DomHelpers$t96 = Rt$template("<div><!><!><!>", 0);
const DomHelpers$k96 = { m: (v$72, cx$73) => {
  const r$74 = DomHelpers$t96();
  const w$75 = r$74.firstChild;
  const w$76 = w$75.nextSibling;
  const w$77 = w$76.nextSibling;
  const c$78 = Rt$slot(r$74, w$75, cx$73);
  const c$79 = Rt$slot(r$74, w$76, cx$73);
  const c$80 = Rt$slot(r$74, w$77, cx$73);
  const i$81 = { s: r$74, q: null, e: r$74, c0: c$78, c1: c$79, c2: c$80, g0_0: undefined, g1_0: undefined, g1_1: undefined, g2: undefined };
  DomHelpers$p96(i$81, v$72);
  return i$81;
}, p: DomHelpers$p96 };
const DomHelpers$eq$prim = ($x, $y) => $x === $y;
const DomHelpers$label = (name$1, n$2) => ({ t: DomHelpers$k10, v: [name$1, n$2] });
const DomHelpers$page = (name$1, n$2) => ({ t: DomHelpers$k27, v: [name$1, n$2] });
const DomHelpers$rows = (names$1) => ({ t: DomHelpers$k44, v: [names$1] });
const DomHelpers$same = ($m$0, x$1, y$2) => {
  const $t$45 = $m$0(x$1, y$2) ? "same" : "different";
  return { t: DomHelpers$k69, v: [$t$45] };
};
const DomHelpers$others = (n$1) => {
  function twice$2(m$3) {
    return { t: DomHelpers$k85, v: [m$3] };
  }
  return { t: DomHelpers$k96, v: [n$1, twice$2] };
};
export { DomHelpers$page, DomHelpers$rows, DomHelpers$others };
//# sourceMappingURL=DomHelpers.mjs.map
