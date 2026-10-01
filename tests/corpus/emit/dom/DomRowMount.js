import { Rt$template, Rt$slot, Rt$forKeyed, Rt$delegate } from "./_platform/Rt.mjs";
import { Html$targetValue } from "./_platform/_html/Html.mjs";
import { String$fromInt, String$compare } from "./_core/String.mjs";
const DomRowMount$t59 = Rt$template("<ul>", 0);
const DomRowMount$k59 = { m: (v$4, cx$5) => {
  const r$6 = DomRowMount$t59();
  const c$7 = Rt$slot(r$6, null, cx$5);
  Rt$forKeyed(c$7, v$4[0], v$4[1], v$4[2], v$4[3]);
  return { s: r$6, q: null, e: r$6, c0: c$7 };
}, p: (i$8, v$9) => {
  Rt$forKeyed(i$8.c0, v$9[0], v$9[1], v$9[2], v$9[3]);
} };
const DomRowMount$t57 = Rt$template("<li><a> </a><input>", 0);
const DomRowMount$t91 = Rt$template("<ul>", 0);
const DomRowMount$k91 = { m: (v$29, cx$30) => {
  const r$31 = DomRowMount$t91();
  const c$32 = Rt$slot(r$31, null, cx$30);
  Rt$forKeyed(c$32, v$29[0], v$29[1], v$29[2], v$29[3]);
  return { s: r$31, q: null, e: r$31, c0: c$32 };
}, p: (i$33, v$34) => {
  Rt$forKeyed(i$33.c0, v$34[0], v$34[1], v$34[2], v$34[3]);
} };
const DomRowMount$t89 = Rt$template("<li>", 0);
const DomRowMount$t117 = Rt$template("<ul>", 0);
const DomRowMount$k117 = { m: (v$49, cx$50) => {
  const r$51 = DomRowMount$t117();
  const c$52 = Rt$slot(r$51, null, cx$50);
  Rt$forKeyed(c$52, v$49[0], v$49[1], v$49[2], v$49[3]);
  return { s: r$51, q: null, e: r$51, c0: c$52 };
}, p: (i$53, v$54) => {
  Rt$forKeyed(i$53.c0, v$54[0], v$54[1], v$54[2], v$54[3]);
} };
const DomRowMount$t115 = Rt$template("<li> ", 0);
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
const DomRowMount$after = (model$1) => {
  const $t$1 = model$1.rows;
  const $t$3 = ($p$2) => $p$2.id;
  return { t: DomRowMount$k59, v: [$t$1, $t$3, { m: (item$10, position$11, cx$12) => {
    const r$13 = DomRowMount$t57();
    const w$14 = r$13.firstChild;
    const w$15 = w$14.firstChild;
    const w$16 = w$14.nextSibling;
    Rt$delegate(["click", "input"]);
    if (cx$12 !== null) {
      w$14.$$cx = cx$12;
    }
    w$16.$$inputX = Html$targetValue;
    if (cx$12 !== null) {
      w$16.$$cx = cx$12;
    }
    return { s: r$13, q: null, e: r$13, w0: r$13, w1: w$14, w2: w$15, w3: w$16, a0: undefined, a1: undefined, a2: undefined, a3: undefined, a4: undefined, x: undefined };
  }, p: (i$17, item$18, position$19) => {
    const $t$20 = model$1.picked === item$18.id ? "on" : "";
    if ($t$20 !== i$17.a0) {
      i$17.w0.setAttribute("class", $t$20);
      i$17.a0 = $t$20;
    }
    if (item$18 !== i$17.x) {
      const $t$21 = String$fromInt(item$18.id);
      const $t$22 = { $: "Pick", a: item$18.id, b: null };
      const $t$23 = item$18.label;
      const $t$25 = ($p$24) => ({ $: "Typed", a: item$18.id, b: $p$24 });
      if ($t$21 !== i$17.a1) {
        i$17.a1 = $t$21;
        i$17.w0.style.setProperty("order", $t$21);
      }
      if ($t$22 !== i$17.a2) {
        i$17.a2 = $t$22;
        i$17.w1.$$click = $t$22;
      }
      if ($t$23 !== i$17.a3) {
        i$17.a3 = $t$23;
        i$17.w2.data = $t$23;
      }
      if ($t$25 !== i$17.a4) {
        i$17.a4 = $t$25;
        i$17.w3.$$input = $t$25;
      }
    }
  }, w: true, i: false, f: null, g: 0, z: model$1.picked }, [model$1.picked]] };
};
const DomRowMount$before = (model$1) => {
  const $t$26 = model$1.rows;
  const $t$28 = ($p$27) => $p$27.id;
  return { t: DomRowMount$k91, v: [$t$26, $t$28, { m: (item$35, position$36, cx$37) => {
    const $t$38 = item$35.label;
    const $t$39 = model$1.picked === item$35.id ? "on" : "";
    const r$40 = DomRowMount$t89();
    r$40.setAttribute("title", $t$38);
    r$40.setAttribute("class", $t$39);
    return { s: r$40, q: null, e: r$40, w0: r$40, a0: $t$38, a1: $t$39 };
  }, p: (i$41, item$42, position$43) => {
    const $t$45 = model$1.picked === item$42.id ? "on" : "";
    if ($t$45 !== i$41.a1) {
      i$41.w0.setAttribute("class", $t$45);
      i$41.a1 = $t$45;
    }
    if (item$42 !== i$41.x) {
      const $t$44 = item$42.label;
      if ($t$44 !== i$41.a0) {
        i$41.w0.setAttribute("title", $t$44);
        i$41.a0 = $t$44;
      }
    }
  }, i: false, f: null, g: 0, z: model$1.picked }, [model$1.picked]] };
};
const DomRowMount$toggled = (model$1) => {
  const $t$46 = model$1.rows;
  const $t$48 = ($p$47) => $p$47.id;
  return { t: DomRowMount$k117, v: [$t$46, $t$48, { m: (item$55, position$56, cx$57) => {
    const $t$58 = model$1.picked === item$55.id;
    const $t$59 = item$55.label;
    const r$60 = DomRowMount$t115();
    const w$61 = r$60.firstChild;
    if ($t$58) {
      r$60.classList.toggle("on", true);
    }
    w$61.data = $t$59;
    return { s: r$60, q: null, e: r$60, w0: r$60, w1: w$61, a0: $t$58, a1: $t$59 };
  }, p: (i$62, item$63, position$64) => {
    const $t$65 = model$1.picked === item$63.id;
    if ($t$65 !== i$62.a0) {
      i$62.a0 = $t$65;
      i$62.w0.classList.toggle("on", $t$65);
    }
    if (item$63 !== i$62.x) {
      const $t$66 = item$63.label;
      if ($t$66 !== i$62.a1) {
        i$62.a1 = $t$66;
        i$62.w1.data = $t$66;
      }
    }
  }, i: false, f: null, g: 0, z: model$1.picked }, [model$1.picked]] };
};
export { DomRowMount$Msg$$compare, DomRowMount$Msg$$eq, DomRowMount$after, DomRowMount$before, DomRowMount$toggled };
//# sourceMappingURL=DomRowMount.mjs.map
