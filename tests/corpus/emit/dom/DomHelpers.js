import { Rt$template, Rt$insertText, Rt$childHtml, Rt$slot, Rt$forKeyed, Rt$text } from "./_platform/Rt.mjs";
const DomHelpers$p10 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  const $in$4 = v$2[1];
  if ($in$3 !== i$1.g0_0) {
    i$1.g0_0 = $in$3;
    if ($in$3 !== i$1.a0) {
      i$1.a0 = $in$3;
      i$1.x0.data = $in$3;
    }
  }
  if ($in$4 !== i$1.g1_0) {
    i$1.g1_0 = $in$4;
    if ($in$4 !== i$1.a1) {
      i$1.a1 = $in$4;
      i$1.x1.data = $in$4;
    }
  }
};
const DomHelpers$t10 = Rt$template("<b> <!>", 0);
const DomHelpers$k10 = { m: (v$5, cx$6) => {
  const r$7 = DomHelpers$t10();
  const w$8 = r$7.firstChild;
  const w$9 = w$8.nextSibling;
  const x$10 = Rt$insertText(r$7, w$8, "");
  const x$11 = Rt$insertText(r$7, w$9, "");
  const i$12 = { s: r$7, q: null, e: r$7, x0: x$10, x1: x$11, a0: undefined, a1: undefined, g0_0: undefined, g1_0: undefined };
  DomHelpers$p10(i$12, v$5);
  return i$12;
}, p: DomHelpers$p10 };
const DomHelpers$p27 = (i$13, v$14) => {
  const $in$15 = v$14[0];
  const $in$16 = v$14[1];
  if ($in$15 !== i$13.g0_0 || $in$16 !== i$13.g0_1) {
    i$13.g0_0 = $in$15;
    i$13.g0_1 = $in$16;
    if ($in$15 !== i$13.a0_0 || $in$16 !== i$13.a0_1) {
      i$13.a0_0 = $in$15;
      i$13.a0_1 = $in$16;
      Rt$childHtml(i$13.c0, DomHelpers$label($in$15, $in$16));
    }
  }
  if (i$13.g1 === undefined) {
    i$13.g1 = true;
    {
      Rt$childHtml(i$13.c1, DomHelpers$label("fixed", 1));
    }
  }
};
const DomHelpers$t27 = Rt$template("<div><!><!>", 0);
const DomHelpers$k27 = { m: (v$17, cx$18) => {
  const r$19 = DomHelpers$t27();
  const w$20 = r$19.firstChild;
  const w$21 = w$20.nextSibling;
  const c$22 = Rt$slot(r$19, w$20, cx$18);
  const c$23 = Rt$slot(r$19, w$21, cx$18);
  const i$24 = { s: r$19, q: null, e: r$19, c0: c$22, c1: c$23, a0_0: undefined, a0_1: undefined, g0_0: undefined, g0_1: undefined, g1: undefined };
  DomHelpers$p27(i$24, v$17);
  return i$24;
}, p: DomHelpers$p27 };
const DomHelpers$t42 = Rt$template("<li>", 0);
const DomHelpers$p44 = (i$25, v$26) => {
  const $in$27 = v$26[0];
  if ($in$27 !== i$25.g0_0) {
    i$25.g0_0 = $in$27;
    const made$28 = { m: (item$29, position$30, cx$31) => {
      const r$32 = DomHelpers$t42();
      const c$33 = Rt$slot(r$32, null, cx$31);
      Rt$childHtml(c$33, DomHelpers$label(item$29, 0));
      return { s: r$32, q: null, e: r$32, c0: c$33, a0_0: item$29 };
    }, p: (i$34, item$35, position$36) => {
      if (item$35 !== i$34.a0_0) {
        i$34.a0_0 = item$35;
        Rt$childHtml(i$34.c0, DomHelpers$label(item$35, 0));
      }
    }, i: false, f: null };
    Rt$forKeyed(i$25.c0, $in$27, null, made$28, null);
  }
};
const DomHelpers$t44 = Rt$template("<ul>", 0);
const DomHelpers$k44 = { m: (v$37, cx$38) => {
  const r$39 = DomHelpers$t44();
  const c$40 = Rt$slot(r$39, null, cx$38);
  const i$41 = { s: r$39, q: null, e: r$39, c0: c$40, g0_0: undefined };
  DomHelpers$p44(i$41, v$37);
  return i$41;
}, p: DomHelpers$p44 };
const DomHelpers$t69 = Rt$template("<b> ", 0);
const DomHelpers$k69 = { m: (v$43, cx$44) => {
  const r$45 = DomHelpers$t69();
  const w$46 = r$45.firstChild;
  w$46.data = v$43[0];
  return { s: r$45, q: null, e: r$45, w1: w$46, a0: v$43[0] };
}, p: (i$47, v$48) => {
  if (v$48[0] !== i$47.a0) {
    i$47.a0 = v$48[0];
    i$47.w1.data = v$48[0];
  }
} };
const DomHelpers$p85 = (i$49, v$50) => {
  const $in$51 = v$50[0];
  if ($in$51 !== i$49.g0_0) {
    i$49.g0_0 = $in$51;
    if ($in$51 !== i$49.a0) {
      i$49.a0 = $in$51;
      i$49.x0.data = $in$51;
    }
    if ($in$51 !== i$49.a1) {
      i$49.a1 = $in$51;
      i$49.x1.data = $in$51;
    }
  }
};
const DomHelpers$t85 = Rt$template("<i><!><!>", 0);
const DomHelpers$k85 = { m: (v$52, cx$53) => {
  const r$54 = DomHelpers$t85();
  const w$55 = r$54.firstChild;
  const w$56 = w$55.nextSibling;
  const x$57 = Rt$insertText(r$54, w$55, "");
  const x$58 = Rt$insertText(r$54, w$56, "");
  const i$59 = { s: r$54, q: null, e: r$54, x0: x$57, x1: x$58, a0: undefined, a1: undefined, g0_0: undefined };
  DomHelpers$p85(i$59, v$52);
  return i$59;
}, p: DomHelpers$p85 };
const DomHelpers$p96 = (i$60, v$61) => {
  const $in$62 = v$61[0];
  const $in$63 = v$61[1];
  if ($in$62 !== i$60.g0_0) {
    i$60.g0_0 = $in$62;
    const $t$64 = DomHelpers$same(DomHelpers$eq$prim, $in$62, 1);
    Rt$childHtml(i$60.c0, $t$64);
  }
  if ($in$62 !== i$60.g1_0 || $in$63 !== i$60.g1_1) {
    i$60.g1_0 = $in$62;
    i$60.g1_1 = $in$63;
    const $t$65 = $in$63($in$62);
    Rt$childHtml(i$60.c1, $t$65);
  }
  if (i$60.g2 === undefined) {
    i$60.g2 = true;
    const $t$66 = Rt$text("t");
    Rt$childHtml(i$60.c2, $t$66);
  }
};
const DomHelpers$t96 = Rt$template("<div><!><!><!>", 0);
const DomHelpers$k96 = { m: (v$67, cx$68) => {
  const r$69 = DomHelpers$t96();
  const w$70 = r$69.firstChild;
  const w$71 = w$70.nextSibling;
  const w$72 = w$71.nextSibling;
  const c$73 = Rt$slot(r$69, w$70, cx$68);
  const c$74 = Rt$slot(r$69, w$71, cx$68);
  const c$75 = Rt$slot(r$69, w$72, cx$68);
  const i$76 = { s: r$69, q: null, e: r$69, c0: c$73, c1: c$74, c2: c$75, g0_0: undefined, g1_0: undefined, g1_1: undefined, g2: undefined };
  DomHelpers$p96(i$76, v$67);
  return i$76;
}, p: DomHelpers$p96 };
const DomHelpers$eq$prim = ($x, $y) => $x === $y;
const DomHelpers$label = (name$1, n$2) => ({ t: DomHelpers$k10, v: [name$1, n$2] });
const DomHelpers$page = (name$1, n$2) => ({ t: DomHelpers$k27, v: [name$1, n$2] });
const DomHelpers$rows = (names$1) => ({ t: DomHelpers$k44, v: [names$1] });
const DomHelpers$same = ($m$0, x$1, y$2) => {
  const $t$42 = $m$0(x$1, y$2) ? "same" : "different";
  return { t: DomHelpers$k69, v: [$t$42] };
};
const DomHelpers$others = (n$1) => {
  function twice$2(m$3) {
    return { t: DomHelpers$k85, v: [m$3] };
  }
  return { t: DomHelpers$k96, v: [n$1, twice$2] };
};
export { DomHelpers$page, DomHelpers$rows, DomHelpers$others };
//# sourceMappingURL=DomHelpers.mjs.map
