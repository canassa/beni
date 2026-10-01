import { Rt$template, Rt$slot, Rt$forKeyed, Rt$forPosition, Rt$insertText, Rt$show, Rt$hide } from "./_platform/Rt.mjs";
import { List$head } from "./_core/List.mjs";
const DomLists$t18 = Rt$template("<li> ", 0);
const DomLists$k18 = { m: (v$1, cx$2) => {
  const r$3 = DomLists$t18();
  const w$4 = r$3.firstChild;
  w$4.data = v$1[0];
  return { s: r$3, q: null, e: r$3, w1: w$4, a0: v$1[0] };
}, p: (i$5, v$6) => {
  if (v$6[0] !== i$5.a0) {
    i$5.a0 = v$6[0];
    i$5.w1.data = v$6[0];
  }
} };
const DomLists$t44 = Rt$template("<table><tbody>", 0);
const DomLists$k44 = { m: (v$10, cx$11) => {
  const r$12 = DomLists$t44();
  const w$13 = r$12.firstChild;
  const c$14 = Rt$slot(w$13, null, cx$11);
  Rt$forKeyed(c$14, v$10[0], v$10[1], v$10[2], v$10[3]);
  return { s: r$12, q: null, e: r$12, c0: c$14 };
}, p: (i$15, v$16) => {
  Rt$forKeyed(i$15.c0, v$16[0], v$16[1], v$16[2], v$16[3]);
} };
const DomLists$t42 = Rt$template("<tr><td> ", 0);
const DomLists$t62 = Rt$template("<li>none", 0);
const DomLists$k62 = { m: (v$32, cx$33) => {
  const r$34 = DomLists$t62();
  return { s: r$34, q: null, e: r$34 };
}, p: (i$35, v$36) => {
} };
const DomLists$b62 = { t: DomLists$k62, v: null };
const DomLists$t81 = Rt$template("<div><ol></ol><ul></ul><ul>", 0);
const DomLists$k81 = { m: (v$38, cx$39) => {
  const r$40 = DomLists$t81();
  const w$41 = r$40.firstChild;
  const w$42 = w$41.nextSibling;
  const w$43 = w$42.nextSibling;
  const c$44 = Rt$slot(w$41, null, cx$39);
  const c$45 = Rt$slot(w$42, null, cx$39);
  const c$46 = Rt$slot(w$43, null, cx$39);
  Rt$forPosition(c$44, v$38[0], v$38[1], null);
  Rt$forKeyed(c$45, v$38[2], null, v$38[3], v$38[4]);
  Rt$forKeyed(c$46, v$38[5], null, v$38[6], null);
  return { s: r$40, q: null, e: r$40, c0: c$44, c1: c$45, c2: c$46 };
}, p: (i$47, v$48) => {
  Rt$forPosition(i$47.c0, v$48[0], v$48[1], null);
  Rt$forKeyed(i$47.c1, v$48[2], null, v$48[3], v$48[4]);
  Rt$forKeyed(i$47.c2, v$48[5], null, v$48[6], null);
} };
const DomLists$t58 = Rt$template("<li>. <!>", 0);
const DomLists$t72 = Rt$template("<li>blank", 0);
const DomLists$k72 = { m: (v$64, cx$65) => {
  const r$66 = DomLists$t72();
  return { s: r$66, q: null, e: r$66 };
}, p: (i$67, v$68) => {
} };
const DomLists$b72 = { t: DomLists$k72, v: null };
const DomLists$t77 = Rt$template("<li> ", 0);
const DomLists$k77 = { m: (v$69, cx$70) => {
  const r$71 = DomLists$t77();
  const w$72 = r$71.firstChild;
  w$72.data = v$69[0];
  return { s: r$71, q: null, e: r$71, w1: w$72, a0: v$69[0] };
}, p: (i$73, v$74) => {
  if (v$74[0] !== i$73.a0) {
    i$73.a0 = v$74[0];
    i$73.w1.data = v$74[0];
  }
} };
const DomLists$t96 = Rt$template("<p>none", 0);
const DomLists$k96 = { m: (v$79, cx$80) => {
  const r$81 = DomLists$t96();
  return { s: r$81, q: null, e: r$81 };
}, p: (i$82, v$83) => {
} };
const DomLists$b96 = { t: DomLists$k96, v: null };
const DomLists$t104 = Rt$template("<!>", 4);
const DomLists$k104 = { m: (v$84, cx$85) => {
  const r$86 = DomLists$t104();
  const w$87 = r$86.firstChild;
  const c$88 = Rt$slot(null, w$87, cx$85);
  let key$89 = c$88;
  let shown$90 = null;
  if (v$84[0].$ === "Just") {
    const value$91 = v$84[0].a;
    key$89 = v$84[1](value$91);
    shown$90 = value$91;
    Rt$show(c$88, key$89, v$84[3](value$91));
  } else {
    Rt$hide(c$88, v$84[2]);
  }
  return { s: null, q: c$88, e: w$87, c0: c$88, a0k: key$89, a0v: shown$90, a0i0: v$84[4] };
}, p: (i$92, v$93) => {
  if (v$93[0].$ === "Just") {
    const value$94 = v$93[0].a;
    const key$95 = v$93[1](value$94);
    if (key$95 !== i$92.a0k || value$94 !== i$92.a0v || v$93[4] !== i$92.a0i0) {
      i$92.a0k = key$95;
      i$92.a0v = value$94;
      i$92.a0i0 = v$93[4];
      Rt$show(i$92.c0, key$95, v$93[3](value$94));
    }
  } else {
    i$92.a0k = i$92.c0;
    Rt$hide(i$92.c0, v$93[2]);
  }
} };
const DomLists$t102 = Rt$template("<p> of <!>", 0);
const DomLists$k102 = { m: (v$99, cx$100) => {
  const r$101 = DomLists$t102();
  const w$102 = r$101.firstChild;
  const w$103 = w$102.nextSibling;
  const x$104 = Rt$insertText(r$101, w$102, v$99[0]);
  const x$105 = Rt$insertText(r$101, w$103, v$99[1]);
  return { s: r$101, q: null, e: r$101, x0: x$104, x1: x$105, a0: v$99[0], a1: v$99[1] };
}, p: (i$106, v$107) => {
  if (v$107[0] !== i$106.a0) {
    i$106.a0 = v$107[0];
    i$106.x0.data = v$107[0];
  }
  if (v$107[1] !== i$106.a1) {
    i$106.a1 = v$107[1];
    i$106.x1.data = v$107[1];
  }
} };
const DomLists$viewName = (name$1) => ({ t: DomLists$k18, v: [name$1] });
const DomLists$table = (model$1) => {
  const $t$7 = model$1.rows;
  const $t$9 = ($p$8) => $p$8.id;
  return { t: DomLists$k44, v: [$t$7, $t$9, { m: (item$17, position$18, cx$19) => {
    const $t$20 = item$17.id === model$1.selected;
    const $t$21 = item$17.label;
    const r$22 = DomLists$t42();
    const w$23 = r$22.firstChild;
    const w$24 = w$23.firstChild;
    if ($t$20) {
      r$22.classList.toggle("danger", true);
    }
    w$24.data = $t$21;
    return { s: r$22, q: null, e: r$22, w0: r$22, w2: w$24, a0: $t$20, a1: $t$21 };
  }, p: (i$25, item$26, position$27) => {
    const $t$28 = item$26.id === model$1.selected;
    if ($t$28 !== i$25.a0) {
      i$25.a0 = $t$28;
      i$25.w0.classList.toggle("danger", $t$28);
    }
    if (item$26 !== i$25.x) {
      const $t$29 = item$26.label;
      if ($t$29 !== i$25.a1) {
        i$25.a1 = $t$29;
        i$25.w2.data = $t$29;
      }
    }
  }, i: false, f: null, g: 0, z: model$1.selected }, [model$1.selected]] };
};
const DomLists$lists = (model$1) => {
  const $t$30 = model$1.names;
  const $t$31 = model$1.names;
  const $t$37 = model$1.names;
  return { t: DomLists$k81, v: [$t$30, { m: (item$49, position$50, cx$51) => {
    const r$52 = DomLists$t58();
    const w$53 = r$52.firstChild;
    const w$54 = w$53.nextSibling;
    const x$55 = Rt$insertText(r$52, w$53, position$50);
    const x$56 = Rt$insertText(r$52, w$54, item$49);
    return { s: r$52, q: null, e: r$52, x0: x$55, x1: x$56, a0: position$50, a1: item$49 };
  }, p: (i$57, item$58, position$59) => {
    if (position$59 !== i$57.a0) {
      i$57.a0 = position$59;
      i$57.x0.data = position$59;
    }
    if (item$58 !== i$57.x) {
      if (item$58 !== i$57.a1) {
        i$57.a1 = item$58;
        i$57.x1.data = item$58;
      }
    }
  }, i: true, f: null }, $t$31, { b: (item$60, position$61) => DomLists$viewName(item$60), i: false, f: DomLists$b62 }, [DomLists$viewName], $t$37, { b: (item$62, position$63) => {
    const $t$75 = item$62 === "" ? DomLists$b72 : { t: DomLists$k77, v: [item$62] };
    return $t$75;
  }, i: false, f: null }] };
};
const DomLists$first = (model$1) => {
  const $t$76 = List$head(model$1.rows);
  const $t$78 = ($p$77) => $p$77.id;
  return { t: DomLists$k104, v: [$t$76, $t$78, DomLists$b96, (value$96) => {
    const $t$97 = value$96.label;
    const $t$98 = model$1.selected;
    return { t: DomLists$k102, v: [$t$97, $t$98] };
  }, model$1.selected] };
};
export { DomLists$table, DomLists$lists, DomLists$first };
//# sourceMappingURL=DomLists.mjs.map
