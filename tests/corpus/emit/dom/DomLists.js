import { Rt$template, Rt$forKeyed, Rt$restate, Rt$slot, Rt$insertText, Rt$forPosition, Rt$show, Rt$hide } from "./_platform/Rt.mjs";
import { List$head } from "./_core/List.mjs";
const DomLists$p18 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  const x$4 = $in$3;
  if (x$4 !== i$1.g0_0) {
    i$1.g0_0 = x$4;
    i$1.w1.data = x$4;
  }
};
const DomLists$t18 = Rt$template("<li> ", 0);
const DomLists$k18 = { m: (v$5, cx$6) => {
  const r$7 = DomLists$t18();
  const w$8 = r$7.firstChild;
  const i$9 = { s: r$7, q: null, e: r$7, w1: w$8, g0_0: NaN };
  DomLists$p18(i$9, v$5);
  return i$9;
}, p: DomLists$p18 };
const DomLists$t42 = Rt$template("<tr><td> ", 0);
const DomLists$p44 = (i$10, v$11) => {
  const $in$12 = v$11[0];
  if ($in$12.rows !== i$10.g0_0 || $in$12.selected !== i$10.g0_1) {
    i$10.g0_0 = $in$12.rows;
    i$10.g0_1 = $in$12.selected;
    const $t$13 = $in$12.rows;
    const $t$15 = ($p$14) => $p$14.id;
    const made$16 = { m: (item$17, position$18, cx$19) => {
      const $t$20 = item$17.id === $in$12.selected;
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
      const $t$28 = item$26.id === $in$12.selected;
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
    }, i: false, f: null, g: 0, z: $in$12.selected };
    Rt$forKeyed(i$10.c0, $t$13, $t$15, made$16, [$in$12.selected]);
  } else {
    Rt$restate(i$10.c0);
  }
  i$10.l = i$10.c0.w || i$10.c0.l;
};
const DomLists$t44 = Rt$template("<table><tbody>", 0);
const DomLists$k44 = { m: (v$30, cx$31) => {
  const r$32 = DomLists$t44();
  const w$33 = r$32.firstChild;
  const c$34 = Rt$slot(w$33, null, cx$31);
  const i$35 = { s: r$32, q: null, e: r$32, c0: c$34, g0_0: NaN, g0_1: NaN };
  DomLists$p44(i$35, v$30);
  return i$35;
}, p: DomLists$p44, l: true };
const DomLists$t62 = Rt$template("<li>none", 0);
const DomLists$k62 = { m: (v$42, cx$43) => {
  const r$44 = DomLists$t62();
  return { s: r$44, q: null, e: r$44 };
}, p: (i$45, v$46) => {
} };
const DomLists$b62 = { t: DomLists$k62, v: null };
const DomLists$t58 = Rt$template("<li>. <!>", 0);
const DomLists$t72 = Rt$template("<li>blank", 0);
const DomLists$k72 = { m: (v$66, cx$67) => {
  const r$68 = DomLists$t72();
  return { s: r$68, q: null, e: r$68 };
}, p: (i$69, v$70) => {
} };
const DomLists$b72 = { t: DomLists$k72, v: null };
const DomLists$p77 = (i$71, v$72) => {
  const $in$73 = v$72[0];
  const x$74 = $in$73;
  if (x$74 !== i$71.g0_0) {
    i$71.g0_0 = x$74;
    i$71.w1.data = x$74;
  }
};
const DomLists$t77 = Rt$template("<li> ", 0);
const DomLists$k77 = { m: (v$75, cx$76) => {
  const r$77 = DomLists$t77();
  const w$78 = r$77.firstChild;
  const i$79 = { s: r$77, q: null, e: r$77, w1: w$78, g0_0: NaN };
  DomLists$p77(i$79, v$75);
  return i$79;
}, p: DomLists$p77 };
const DomLists$p81 = (i$36, v$37) => {
  const $in$38 = v$37[0];
  const x$39 = $in$38.names;
  if (x$39 !== i$36.g0_0) {
    i$36.g0_0 = x$39;
    const $t$40 = $in$38.names;
    const $t$41 = $in$38.names;
    const $t$47 = $in$38.names;
    const made$48 = { m: (item$49, position$50, cx$51) => {
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
    }, i: true, f: null };
    Rt$forPosition(i$36.c0, $t$40, made$48, null);
    const made$60 = { b: (item$61, position$62) => DomLists$viewName(item$61), i: false, f: DomLists$b62 };
    Rt$forKeyed(i$36.c1, $t$41, null, made$60, [DomLists$viewName]);
    const made$63 = { b: (item$64, position$65) => {
      const $t$80 = item$64 === "" ? DomLists$b72 : { t: DomLists$k77, v: [item$64] };
      return $t$80;
    }, i: false, f: null };
    Rt$forKeyed(i$36.c2, $t$47, null, made$63, null);
  } else {
    Rt$restate(i$36.c0);
    Rt$restate(i$36.c1);
    Rt$restate(i$36.c2);
  }
  i$36.l = i$36.c0.w || i$36.c0.l || i$36.c1.w || i$36.c1.l || i$36.c2.w || i$36.c2.l;
};
const DomLists$t81 = Rt$template("<div><ol></ol><ul></ul><ul>", 0);
const DomLists$k81 = { m: (v$81, cx$82) => {
  const r$83 = DomLists$t81();
  const w$84 = r$83.firstChild;
  const w$85 = w$84.nextSibling;
  const w$86 = w$85.nextSibling;
  const c$87 = Rt$slot(w$84, null, cx$82);
  const c$88 = Rt$slot(w$85, null, cx$82);
  const c$89 = Rt$slot(w$86, null, cx$82);
  const i$90 = { s: r$83, q: null, e: r$83, c0: c$87, c1: c$88, c2: c$89, g0_0: NaN };
  DomLists$p81(i$90, v$81);
  return i$90;
}, p: DomLists$p81, l: true };
const DomLists$t96 = Rt$template("<p>none", 0);
const DomLists$k96 = { m: (v$97, cx$98) => {
  const r$99 = DomLists$t96();
  return { s: r$99, q: null, e: r$99 };
}, p: (i$100, v$101) => {
} };
const DomLists$b96 = { t: DomLists$k96, v: null };
const DomLists$t102 = Rt$template("<p> of <!>", 0);
const DomLists$k102 = { m: (v$108, cx$109) => {
  const r$110 = DomLists$t102();
  const w$111 = r$110.firstChild;
  const w$112 = w$111.nextSibling;
  const x$113 = Rt$insertText(r$110, w$111, v$108[0]);
  const x$114 = Rt$insertText(r$110, w$112, v$108[1]);
  return { s: r$110, q: null, e: r$110, x0: x$113, x1: x$114, a0: v$108[0], a1: v$108[1] };
}, p: (i$115, v$116) => {
  if (v$116[0] !== i$115.a0) {
    i$115.a0 = v$116[0];
    i$115.x0.data = v$116[0];
  }
  if (v$116[1] !== i$115.a1) {
    i$115.a1 = v$116[1];
    i$115.x1.data = v$116[1];
  }
} };
const DomLists$p104 = (i$91, v$92) => {
  const $in$93 = v$92[0];
  if ($in$93.rows !== i$91.g0_0 || $in$93.selected !== i$91.g0_1) {
    i$91.g0_0 = $in$93.rows;
    i$91.g0_1 = $in$93.selected;
    const $t$94 = List$head($in$93.rows);
    const $t$96 = ($p$95) => $p$95.id;
    const made$104 = (value$105) => {
      const $t$106 = value$105.label;
      const $t$107 = $in$93.selected;
      return { t: DomLists$k102, v: [$t$106, $t$107] };
    };
    if ($t$94.$ === "Just") {
      const value$102 = $t$94.a;
      const key$103 = $t$96(value$102);
      if (key$103 !== i$91.a0k || value$102 !== i$91.a0v || $in$93.selected !== i$91.a0i0) {
        i$91.a0k = key$103;
        i$91.a0v = value$102;
        i$91.a0i0 = $in$93.selected;
        Rt$show(i$91.c0, key$103, made$104(value$102));
      } else {
        Rt$restate(i$91.c0);
      }
    } else {
      i$91.a0k = i$91.c0;
      Rt$hide(i$91.c0, DomLists$b96);
    }
  } else {
    Rt$restate(i$91.c0);
  }
  i$91.l = i$91.c0.l;
};
const DomLists$t104 = Rt$template("<!>", 4);
const DomLists$k104 = { m: (v$117, cx$118) => {
  const r$119 = DomLists$t104();
  const w$120 = r$119.firstChild;
  const c$121 = Rt$slot(null, w$120, cx$118);
  const i$122 = { s: null, q: c$121, e: w$120, c0: c$121, a0k: undefined, a0v: undefined, a0i0: undefined, g0_0: NaN, g0_1: NaN };
  DomLists$p104(i$122, v$117);
  return i$122;
}, p: DomLists$p104, l: true };
const DomLists$viewName = (name$1) => ({ t: DomLists$k18, v: [name$1] });
const DomLists$table = (model$1) => ({ t: DomLists$k44, v: [model$1] });
const DomLists$lists = (model$1) => ({ t: DomLists$k81, v: [model$1] });
const DomLists$first = (model$1) => ({ t: DomLists$k104, v: [model$1] });
export { DomLists$table, DomLists$lists, DomLists$first };
//# sourceMappingURL=DomLists.mjs.map
