import { Rt$template, Rt$forKeyed, Rt$slot, Rt$insertText, Rt$forPosition, Rt$show, Rt$hide } from "./_platform/Rt.mjs";
import { List$head } from "./_core/List.mjs";
const DomLists$p18 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if ($in$3 !== i$1.g0_0) {
    i$1.g0_0 = $in$3;
    if ($in$3 !== i$1.a0) {
      i$1.a0 = $in$3;
      i$1.w1.data = $in$3;
    }
  }
};
const DomLists$t18 = Rt$template("<li> ", 0);
const DomLists$k18 = { m: (v$4, cx$5) => {
  const r$6 = DomLists$t18();
  const w$7 = r$6.firstChild;
  const i$8 = { s: r$6, q: null, e: r$6, w1: w$7, a0: undefined, g0_0: undefined };
  DomLists$p18(i$8, v$4);
  return i$8;
}, p: DomLists$p18 };
const DomLists$t42 = Rt$template("<tr><td> ", 0);
const DomLists$p44 = (i$9, v$10) => {
  const $in$11 = v$10[0];
  if ($in$11.rows !== i$9.g0_0 || $in$11.selected !== i$9.g0_1) {
    i$9.g0_0 = $in$11.rows;
    i$9.g0_1 = $in$11.selected;
    const $t$12 = $in$11.rows;
    const $t$14 = ($p$13) => $p$13.id;
    const made$15 = { m: (item$16, position$17, cx$18) => {
      const $t$19 = item$16.id === $in$11.selected;
      const $t$20 = item$16.label;
      const r$21 = DomLists$t42();
      const w$22 = r$21.firstChild;
      const w$23 = w$22.firstChild;
      if ($t$19) {
        r$21.classList.toggle("danger", true);
      }
      w$23.data = $t$20;
      return { s: r$21, q: null, e: r$21, w0: r$21, w2: w$23, a0: $t$19, a1: $t$20 };
    }, p: (i$24, item$25, position$26) => {
      const $t$27 = item$25.id === $in$11.selected;
      if ($t$27 !== i$24.a0) {
        i$24.a0 = $t$27;
        i$24.w0.classList.toggle("danger", $t$27);
      }
      if (item$25 !== i$24.x) {
        const $t$28 = item$25.label;
        if ($t$28 !== i$24.a1) {
          i$24.a1 = $t$28;
          i$24.w2.data = $t$28;
        }
      }
    }, i: false, f: null, g: 0, z: $in$11.selected };
    Rt$forKeyed(i$9.c0, $t$12, $t$14, made$15, [$in$11.selected]);
  }
};
const DomLists$t44 = Rt$template("<table><tbody>", 0);
const DomLists$k44 = { m: (v$29, cx$30) => {
  const r$31 = DomLists$t44();
  const w$32 = r$31.firstChild;
  const c$33 = Rt$slot(w$32, null, cx$30);
  const i$34 = { s: r$31, q: null, e: r$31, c0: c$33, g0_0: undefined, g0_1: undefined };
  DomLists$p44(i$34, v$29);
  return i$34;
}, p: DomLists$p44 };
const DomLists$t62 = Rt$template("<li>none", 0);
const DomLists$k62 = { m: (v$40, cx$41) => {
  const r$42 = DomLists$t62();
  return { s: r$42, q: null, e: r$42 };
}, p: (i$43, v$44) => {
} };
const DomLists$b62 = { t: DomLists$k62, v: null };
const DomLists$t58 = Rt$template("<li>. <!>", 0);
const DomLists$t72 = Rt$template("<li>blank", 0);
const DomLists$k72 = { m: (v$64, cx$65) => {
  const r$66 = DomLists$t72();
  return { s: r$66, q: null, e: r$66 };
}, p: (i$67, v$68) => {
} };
const DomLists$b72 = { t: DomLists$k72, v: null };
const DomLists$p77 = (i$69, v$70) => {
  const $in$71 = v$70[0];
  if ($in$71 !== i$69.g0_0) {
    i$69.g0_0 = $in$71;
    if ($in$71 !== i$69.a0) {
      i$69.a0 = $in$71;
      i$69.w1.data = $in$71;
    }
  }
};
const DomLists$t77 = Rt$template("<li> ", 0);
const DomLists$k77 = { m: (v$72, cx$73) => {
  const r$74 = DomLists$t77();
  const w$75 = r$74.firstChild;
  const i$76 = { s: r$74, q: null, e: r$74, w1: w$75, a0: undefined, g0_0: undefined };
  DomLists$p77(i$76, v$72);
  return i$76;
}, p: DomLists$p77 };
const DomLists$p81 = (i$35, v$36) => {
  const $in$37 = v$36[0];
  if ($in$37.names !== i$35.g0_0) {
    i$35.g0_0 = $in$37.names;
    const $t$38 = $in$37.names;
    const $t$39 = $in$37.names;
    const $t$45 = $in$37.names;
    const made$46 = { m: (item$47, position$48, cx$49) => {
      const r$50 = DomLists$t58();
      const w$51 = r$50.firstChild;
      const w$52 = w$51.nextSibling;
      const x$53 = Rt$insertText(r$50, w$51, position$48);
      const x$54 = Rt$insertText(r$50, w$52, item$47);
      return { s: r$50, q: null, e: r$50, x0: x$53, x1: x$54, a0: position$48, a1: item$47 };
    }, p: (i$55, item$56, position$57) => {
      if (position$57 !== i$55.a0) {
        i$55.a0 = position$57;
        i$55.x0.data = position$57;
      }
      if (item$56 !== i$55.x) {
        if (item$56 !== i$55.a1) {
          i$55.a1 = item$56;
          i$55.x1.data = item$56;
        }
      }
    }, i: true, f: null };
    Rt$forPosition(i$35.c0, $t$38, made$46, null);
    const made$58 = { b: (item$59, position$60) => DomLists$viewName(item$59), i: false, f: DomLists$b62 };
    Rt$forKeyed(i$35.c1, $t$39, null, made$58, [DomLists$viewName]);
    const made$61 = { b: (item$62, position$63) => {
      const $t$77 = item$62 === "" ? DomLists$b72 : { t: DomLists$k77, v: [item$62] };
      return $t$77;
    }, i: false, f: null };
    Rt$forKeyed(i$35.c2, $t$45, null, made$61, null);
  }
};
const DomLists$t81 = Rt$template("<div><ol></ol><ul></ul><ul>", 0);
const DomLists$k81 = { m: (v$78, cx$79) => {
  const r$80 = DomLists$t81();
  const w$81 = r$80.firstChild;
  const w$82 = w$81.nextSibling;
  const w$83 = w$82.nextSibling;
  const c$84 = Rt$slot(w$81, null, cx$79);
  const c$85 = Rt$slot(w$82, null, cx$79);
  const c$86 = Rt$slot(w$83, null, cx$79);
  const i$87 = { s: r$80, q: null, e: r$80, c0: c$84, c1: c$85, c2: c$86, g0_0: undefined };
  DomLists$p81(i$87, v$78);
  return i$87;
}, p: DomLists$p81 };
const DomLists$t96 = Rt$template("<p>none", 0);
const DomLists$k96 = { m: (v$94, cx$95) => {
  const r$96 = DomLists$t96();
  return { s: r$96, q: null, e: r$96 };
}, p: (i$97, v$98) => {
} };
const DomLists$b96 = { t: DomLists$k96, v: null };
const DomLists$t102 = Rt$template("<p> of <!>", 0);
const DomLists$k102 = { m: (v$105, cx$106) => {
  const r$107 = DomLists$t102();
  const w$108 = r$107.firstChild;
  const w$109 = w$108.nextSibling;
  const x$110 = Rt$insertText(r$107, w$108, v$105[0]);
  const x$111 = Rt$insertText(r$107, w$109, v$105[1]);
  return { s: r$107, q: null, e: r$107, x0: x$110, x1: x$111, a0: v$105[0], a1: v$105[1] };
}, p: (i$112, v$113) => {
  if (v$113[0] !== i$112.a0) {
    i$112.a0 = v$113[0];
    i$112.x0.data = v$113[0];
  }
  if (v$113[1] !== i$112.a1) {
    i$112.a1 = v$113[1];
    i$112.x1.data = v$113[1];
  }
} };
const DomLists$p104 = (i$88, v$89) => {
  const $in$90 = v$89[0];
  if ($in$90.rows !== i$88.g0_0 || $in$90.selected !== i$88.g0_1) {
    i$88.g0_0 = $in$90.rows;
    i$88.g0_1 = $in$90.selected;
    const $t$91 = List$head($in$90.rows);
    const $t$93 = ($p$92) => $p$92.id;
    const made$101 = (value$102) => {
      const $t$103 = value$102.label;
      const $t$104 = $in$90.selected;
      return { t: DomLists$k102, v: [$t$103, $t$104] };
    };
    if ($t$91.$ === "Just") {
      const value$99 = $t$91.a;
      const key$100 = $t$93(value$99);
      if (key$100 !== i$88.a0k || value$99 !== i$88.a0v || $in$90.selected !== i$88.a0i0) {
        i$88.a0k = key$100;
        i$88.a0v = value$99;
        i$88.a0i0 = $in$90.selected;
        Rt$show(i$88.c0, key$100, made$101(value$99));
      }
    } else {
      i$88.a0k = i$88.c0;
      Rt$hide(i$88.c0, DomLists$b96);
    }
  }
};
const DomLists$t104 = Rt$template("<!>", 4);
const DomLists$k104 = { m: (v$114, cx$115) => {
  const r$116 = DomLists$t104();
  const w$117 = r$116.firstChild;
  const c$118 = Rt$slot(null, w$117, cx$115);
  const i$119 = { s: null, q: c$118, e: w$117, c0: c$118, a0k: undefined, a0v: undefined, a0i0: undefined, g0_0: undefined, g0_1: undefined };
  DomLists$p104(i$119, v$114);
  return i$119;
}, p: DomLists$p104 };
const DomLists$viewName = (name$1) => ({ t: DomLists$k18, v: [name$1] });
const DomLists$table = (model$1) => ({ t: DomLists$k44, v: [model$1] });
const DomLists$lists = (model$1) => ({ t: DomLists$k81, v: [model$1] });
const DomLists$first = (model$1) => ({ t: DomLists$k104, v: [model$1] });
export { DomLists$table, DomLists$lists, DomLists$first };
//# sourceMappingURL=DomLists.mjs.map
