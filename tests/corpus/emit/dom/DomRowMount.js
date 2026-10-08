import { Rt$template, Rt$delegate, Rt$forKeyed, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { Html$targetValue } from "./_platform/_html/Html.mjs";
import { String$fromInt, String$compare } from "./_core/String.mjs";
const DomRowMount$t57 = Rt$template("<li><a> </a><input>", 0);
const DomRowMount$p59 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if ($in$3.rows !== i$1.g0_0 || $in$3.picked !== i$1.g0_1) {
    i$1.g0_0 = $in$3.rows;
    i$1.g0_1 = $in$3.picked;
    const $t$4 = $in$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const made$7 = { m: (item$8, position$9, cx$10) => {
      const r$11 = DomRowMount$t57();
      const w$12 = r$11.firstChild;
      const w$13 = w$12.firstChild;
      const w$14 = w$12.nextSibling;
      Rt$delegate(["click", "input"]);
      if (cx$10 !== null) {
        w$12.$$cx = cx$10;
        w$12.$$clickF = 4;
      }
      w$14.$$inputX = Html$targetValue;
      if (cx$10 !== null) {
        w$14.$$cx = cx$10;
        w$14.$$inputF = 4;
      }
      return { s: r$11, q: null, e: r$11, w0: r$11, w1: w$12, w2: w$13, w3: w$14, a0: undefined, a1: undefined, a2: undefined, a3: undefined, a4: undefined, x: undefined };
    }, p: (i$15, item$16, position$17) => {
      const $t$18 = $in$3.picked === item$16.id ? "on" : "";
      if ($t$18 !== i$15.a0) {
        i$15.w0.setAttribute("class", $t$18);
        i$15.a0 = $t$18;
      }
      if (item$16 !== i$15.x) {
        const $t$19 = String$fromInt(item$16.id);
        const $t$20 = { $: "Pick", a: item$16.id, b: null };
        const $t$21 = item$16.label;
        const $t$23 = ($p$22) => ({ $: "Typed", a: item$16.id, b: $p$22 });
        if ($t$19 !== i$15.a1) {
          i$15.a1 = $t$19;
          i$15.w0.style.setProperty("order", $t$19);
        }
        if ($t$20 !== i$15.a2) {
          i$15.a2 = $t$20;
          i$15.w1.$$click = $t$20;
        }
        if ($t$21 !== i$15.a3) {
          i$15.a3 = $t$21;
          i$15.w2.data = $t$21;
        }
        if ($t$23 !== i$15.a4) {
          i$15.a4 = $t$23;
          i$15.w3.$$input = $t$23;
        }
      }
    }, w: true, i: false, f: null, g: 0, z: $in$3.picked };
    Rt$forKeyed(i$1.c0, $t$4, $t$6, made$7, [$in$3.picked]);
  } else {
    Rt$restate(i$1.c0);
  }
  i$1.l = i$1.c0.w || i$1.c0.l;
};
const DomRowMount$t59 = Rt$template("<ul>", 0);
const DomRowMount$k59 = { m: (v$24, cx$25) => {
  const r$26 = DomRowMount$t59();
  const c$27 = Rt$slot(r$26, null, cx$25);
  const i$28 = { s: r$26, q: null, e: r$26, c0: c$27, g0_0: NaN, g0_1: NaN };
  DomRowMount$p59(i$28, v$24);
  return i$28;
}, p: DomRowMount$p59, l: true };
const DomRowMount$t89 = Rt$template("<li>", 0);
const DomRowMount$p91 = (i$29, v$30) => {
  const $in$31 = v$30[0];
  if ($in$31.rows !== i$29.g0_0 || $in$31.picked !== i$29.g0_1) {
    i$29.g0_0 = $in$31.rows;
    i$29.g0_1 = $in$31.picked;
    const $t$32 = $in$31.rows;
    const $t$34 = ($p$33) => $p$33.id;
    const made$35 = { m: (item$36, position$37, cx$38) => {
      const $t$39 = item$36.label;
      const $t$40 = $in$31.picked === item$36.id ? "on" : "";
      const r$41 = DomRowMount$t89();
      r$41.setAttribute("title", $t$39);
      r$41.setAttribute("class", $t$40);
      return { s: r$41, q: null, e: r$41, w0: r$41, a0: $t$39, a1: $t$40 };
    }, p: (i$42, item$43, position$44) => {
      const $t$46 = $in$31.picked === item$43.id ? "on" : "";
      if ($t$46 !== i$42.a1) {
        i$42.w0.setAttribute("class", $t$46);
        i$42.a1 = $t$46;
      }
      if (item$43 !== i$42.x) {
        const $t$45 = item$43.label;
        if ($t$45 !== i$42.a0) {
          i$42.w0.setAttribute("title", $t$45);
          i$42.a0 = $t$45;
        }
      }
    }, i: false, f: null, g: 0, z: $in$31.picked };
    Rt$forKeyed(i$29.c0, $t$32, $t$34, made$35, [$in$31.picked]);
  } else {
    Rt$restate(i$29.c0);
  }
  i$29.l = i$29.c0.w || i$29.c0.l;
};
const DomRowMount$t91 = Rt$template("<ul>", 0);
const DomRowMount$k91 = { m: (v$47, cx$48) => {
  const r$49 = DomRowMount$t91();
  const c$50 = Rt$slot(r$49, null, cx$48);
  const i$51 = { s: r$49, q: null, e: r$49, c0: c$50, g0_0: NaN, g0_1: NaN };
  DomRowMount$p91(i$51, v$47);
  return i$51;
}, p: DomRowMount$p91, l: true };
const DomRowMount$t115 = Rt$template("<li> ", 0);
const DomRowMount$p117 = (i$52, v$53) => {
  const $in$54 = v$53[0];
  if ($in$54.rows !== i$52.g0_0 || $in$54.picked !== i$52.g0_1) {
    i$52.g0_0 = $in$54.rows;
    i$52.g0_1 = $in$54.picked;
    const $t$55 = $in$54.rows;
    const $t$57 = ($p$56) => $p$56.id;
    const made$58 = { m: (item$59, position$60, cx$61) => {
      const $t$62 = $in$54.picked === item$59.id;
      const $t$63 = item$59.label;
      const r$64 = DomRowMount$t115();
      const w$65 = r$64.firstChild;
      if ($t$62) {
        r$64.classList.toggle("on", true);
      }
      w$65.data = $t$63;
      return { s: r$64, q: null, e: r$64, w0: r$64, w1: w$65, a0: $t$62, a1: $t$63 };
    }, p: (i$66, item$67, position$68) => {
      const $t$69 = $in$54.picked === item$67.id;
      if ($t$69 !== i$66.a0) {
        i$66.a0 = $t$69;
        i$66.w0.classList.toggle("on", $t$69);
      }
      if (item$67 !== i$66.x) {
        const $t$70 = item$67.label;
        if ($t$70 !== i$66.a1) {
          i$66.a1 = $t$70;
          i$66.w1.data = $t$70;
        }
      }
    }, i: false, f: null, g: 0, z: $in$54.picked };
    Rt$forKeyed(i$52.c0, $t$55, $t$57, made$58, [$in$54.picked]);
  } else {
    Rt$restate(i$52.c0);
  }
  i$52.l = i$52.c0.w || i$52.c0.l;
};
const DomRowMount$t117 = Rt$template("<ul>", 0);
const DomRowMount$k117 = { m: (v$71, cx$72) => {
  const r$73 = DomRowMount$t117();
  const c$74 = Rt$slot(r$73, null, cx$72);
  const i$75 = { s: r$73, q: null, e: r$73, c0: c$74, g0_0: NaN, g0_1: NaN };
  DomRowMount$p117(i$75, v$71);
  return i$75;
}, p: DomRowMount$p117, l: true };
const DomRowMount$Msg$$order = { Pick: 0, Typed: 1 };
const DomRowMount$Msg$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return DomRowMount$Msg$$order[$x.$] < DomRowMount$Msg$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Pick":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    default:
      const $o$0 = $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
      if ($o$0 !== "EQ") {
        return $o$0;
      }
      return String$compare($x.b, $y.b);
  }
};
const DomRowMount$Msg$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Pick":
      return $x.a === $y.a;
    default:
      return $x.a === $y.a && $x.b === $y.b;
  }
};
const DomRowMount$after = (model$1) => ({ t: DomRowMount$k59, v: [model$1] });
const DomRowMount$before = (model$1) => ({ t: DomRowMount$k91, v: [model$1] });
const DomRowMount$toggled = (model$1) => ({ t: DomRowMount$k117, v: [model$1] });
export { DomRowMount$Msg$$compare, DomRowMount$Msg$$eq, DomRowMount$after, DomRowMount$before, DomRowMount$toggled };
//# sourceMappingURL=DomRowMount.mjs.map
