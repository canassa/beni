import { Rt$template, Rt$insertText, Rt$childHtml, Rt$restate, Rt$slot, Rt$forKeyed, Rt$text } from "./_platform/Rt.mjs";
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
    } else {
      Rt$restate(i$15.c0);
    }
  } else {
    Rt$restate(i$15.c0);
  }
  if (i$15.g1 === undefined) {
    i$15.g1 = true;
    if (i$15.a1 === undefined) {
      Rt$childHtml(i$15.c1, DomHelpers$label("fixed", 1));
      i$15.a1 = true;
    } else {
      Rt$restate(i$15.c1);
    }
  } else {
    Rt$restate(i$15.c1);
  }
  i$15.l = i$15.c0.l || i$15.c1.l;
};
const DomHelpers$t27 = Rt$template("<div><!><!>", 0);
const DomHelpers$k27 = { m: (v$19, cx$20) => {
  const r$21 = DomHelpers$t27();
  const w$22 = r$21.firstChild;
  const w$23 = w$22.nextSibling;
  const c$24 = Rt$slot(r$21, w$22, cx$20);
  const c$25 = Rt$slot(r$21, w$23, cx$20);
  const i$26 = { s: r$21, q: null, e: r$21, c0: c$24, c1: c$25, a0_0: undefined, a0_1: undefined, a1: undefined, g0_0: undefined, g0_1: undefined, g1: undefined };
  DomHelpers$p27(i$26, v$19);
  return i$26;
}, p: DomHelpers$p27, l: true };
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
      return { s: r$35, q: null, e: r$35, c0: c$36, a0_0: item$32, l: c$36.l };
    }, p: (i$37, item$38, position$39) => {
      if (item$38 !== i$37.a0_0) {
        i$37.a0_0 = item$38;
        Rt$childHtml(i$37.c0, DomHelpers$label(item$38, 0));
      } else {
        Rt$restate(i$37.c0);
      }
      i$37.l = i$37.c0.l;
    }, l: true, r: (i$40) => {
      Rt$restate(i$40.c0);
    }, i: false, f: null };
    Rt$forKeyed(i$27.c0, $in$29, null, made$31, null);
  } else {
    Rt$restate(i$27.c0);
  }
  i$27.l = i$27.c0.w || i$27.c0.l;
};
const DomHelpers$t44 = Rt$template("<ul>", 0);
const DomHelpers$k44 = { m: (v$41, cx$42) => {
  const r$43 = DomHelpers$t44();
  const c$44 = Rt$slot(r$43, null, cx$42);
  const i$45 = { s: r$43, q: null, e: r$43, c0: c$44, g0_0: undefined };
  DomHelpers$p44(i$45, v$41);
  return i$45;
}, p: DomHelpers$p44, l: true };
const DomHelpers$t69 = Rt$template("<b> ", 0);
const DomHelpers$k69 = { m: (v$47, cx$48) => {
  const r$49 = DomHelpers$t69();
  const w$50 = r$49.firstChild;
  w$50.data = v$47[0];
  return { s: r$49, q: null, e: r$49, w1: w$50, a0: v$47[0] };
}, p: (i$51, v$52) => {
  if (v$52[0] !== i$51.a0) {
    i$51.a0 = v$52[0];
    i$51.w1.data = v$52[0];
  }
} };
const DomHelpers$p85 = (i$53, v$54) => {
  const $in$55 = v$54[0];
  const x$56 = $in$55;
  if (x$56 !== i$53.g0_0) {
    i$53.g0_0 = x$56;
    i$53.x0.data = x$56;
    i$53.x1.data = x$56;
  }
};
const DomHelpers$t85 = Rt$template("<i><!><!>", 0);
const DomHelpers$k85 = { m: (v$57, cx$58) => {
  const r$59 = DomHelpers$t85();
  const w$60 = r$59.firstChild;
  const w$61 = w$60.nextSibling;
  const x$62 = Rt$insertText(r$59, w$60, "");
  const x$63 = Rt$insertText(r$59, w$61, "");
  const i$64 = { s: r$59, q: null, e: r$59, x0: x$62, x1: x$63, g0_0: undefined };
  DomHelpers$p85(i$64, v$57);
  return i$64;
}, p: DomHelpers$p85 };
const DomHelpers$p96 = (i$65, v$66) => {
  const $in$67 = v$66[0];
  const $in$68 = v$66[1];
  const x$69 = $in$67;
  if (x$69 !== i$65.g0_0) {
    i$65.g0_0 = x$69;
    const $t$70 = DomHelpers$same(DomHelpers$eq$prim, $in$67, 1);
    Rt$childHtml(i$65.c0, $t$70);
  } else {
    Rt$restate(i$65.c0);
  }
  if ($in$67 !== i$65.g1_0 || $in$68 !== i$65.g1_1) {
    i$65.g1_0 = $in$67;
    i$65.g1_1 = $in$68;
    const $t$71 = $in$68($in$67);
    Rt$childHtml(i$65.c1, $t$71);
  } else {
    Rt$restate(i$65.c1);
  }
  if (i$65.g2 === undefined) {
    i$65.g2 = true;
    const $t$72 = Rt$text("t");
    Rt$childHtml(i$65.c2, $t$72);
  } else {
    Rt$restate(i$65.c2);
  }
  i$65.l = i$65.c0.l || i$65.c1.l || i$65.c2.l;
};
const DomHelpers$t96 = Rt$template("<div><!><!><!>", 0);
const DomHelpers$k96 = { m: (v$73, cx$74) => {
  const r$75 = DomHelpers$t96();
  const w$76 = r$75.firstChild;
  const w$77 = w$76.nextSibling;
  const w$78 = w$77.nextSibling;
  const c$79 = Rt$slot(r$75, w$76, cx$74);
  const c$80 = Rt$slot(r$75, w$77, cx$74);
  const c$81 = Rt$slot(r$75, w$78, cx$74);
  const i$82 = { s: r$75, q: null, e: r$75, c0: c$79, c1: c$80, c2: c$81, g0_0: undefined, g1_0: undefined, g1_1: undefined, g2: undefined };
  DomHelpers$p96(i$82, v$73);
  return i$82;
}, p: DomHelpers$p96, l: true };
const DomHelpers$eq$prim = ($x, $y) => $x === $y;
const DomHelpers$label = (name$1, n$2) => ({ t: DomHelpers$k10, v: [name$1, n$2] });
const DomHelpers$page = (name$1, n$2) => ({ t: DomHelpers$k27, v: [name$1, n$2] });
const DomHelpers$rows = (names$1) => ({ t: DomHelpers$k44, v: [names$1] });
const DomHelpers$same = ($m$0, x$1, y$2) => {
  const $t$46 = $m$0(x$1, y$2) ? "same" : "different";
  return { t: DomHelpers$k69, v: [$t$46] };
};
const DomHelpers$others = (n$1) => {
  function twice$2(m$3) {
    return { t: DomHelpers$k85, v: [m$3] };
  }
  return { t: DomHelpers$k96, v: [n$1, twice$2] };
};
export { DomHelpers$page, DomHelpers$rows, DomHelpers$others };
//# sourceMappingURL=DomHelpers.mjs.map
