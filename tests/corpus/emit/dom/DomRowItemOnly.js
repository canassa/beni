import { Rt$template, Rt$delegate, Rt$forKeyed, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
const DomRowItemOnly$t51 = Rt$template("<tr><td> </td><td><a> </a></td><td><a>x", 0);
const DomRowItemOnly$p53 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if ($in$3.rows !== i$1.g0_0 || $in$3.selected !== i$1.g0_1) {
    i$1.g0_0 = $in$3.rows;
    i$1.g0_1 = $in$3.selected;
    const $t$4 = $in$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const made$7 = { m: (item$8, position$9, cx$10) => {
      const r$11 = DomRowItemOnly$t51();
      const w$12 = r$11.firstChild;
      const w$13 = w$12.firstChild;
      const w$14 = w$12.nextSibling;
      const w$15 = w$14.firstChild;
      const w$16 = w$15.firstChild;
      const w$17 = w$14.nextSibling;
      const w$18 = w$17.firstChild;
      Rt$delegate(["click"]);
      if (cx$10 !== null) {
        w$15.$$cx = cx$10;
      }
      if (cx$10 !== null) {
        w$18.$$cx = cx$10;
      }
      return { s: r$11, q: null, e: r$11, w0: r$11, w2: w$13, w4: w$15, w5: w$16, w7: w$18, a0: undefined, a1: undefined, a2: undefined, a3: undefined, a4: undefined, x: undefined };
    }, p: (i$19, item$20, position$21) => {
      const $t$22 = $in$3.selected.$ === "Just" && $in$3.selected.a === item$20.id ? "danger" : "";
      if ($t$22 !== i$19.a0) {
        i$19.w0.setAttribute("class", $t$22);
        i$19.a0 = $t$22;
      }
      if (item$20 !== i$19.x) {
        const $t$23 = item$20.id;
        const $t$24 = { $: "Select", a: item$20.id };
        const $t$25 = item$20.label;
        const $t$26 = { $: "Remove", a: item$20.id };
        if ($t$23 !== i$19.a1) {
          i$19.a1 = $t$23;
          i$19.w2.data = $t$23;
        }
        if ($t$24 !== i$19.a2) {
          i$19.a2 = $t$24;
          i$19.w4.$$click = $t$24;
        }
        if ($t$25 !== i$19.a3) {
          i$19.a3 = $t$25;
          i$19.w5.data = $t$25;
        }
        if ($t$26 !== i$19.a4) {
          i$19.a4 = $t$26;
          i$19.w7.$$click = $t$26;
        }
      }
    }, w: true, i: false, f: null, g: 0, z: $in$3.selected.$ === "Just" ? $in$3.selected.a : $in$3.selected };
    Rt$forKeyed(i$1.c0, $t$4, $t$6, made$7, [$in$3.selected]);
  } else {
    Rt$restate(i$1.c0);
  }
  i$1.l = i$1.c0.w || i$1.c0.l;
};
const DomRowItemOnly$t53 = Rt$template("<table>", 0);
const DomRowItemOnly$k53 = { m: (v$27, cx$28) => {
  const r$29 = DomRowItemOnly$t53();
  const c$30 = Rt$slot(r$29, null, cx$28);
  const i$31 = { s: r$29, q: null, e: r$29, c0: c$30, g0_0: NaN, g0_1: NaN };
  DomRowItemOnly$p53(i$31, v$27);
  return i$31;
}, p: DomRowItemOnly$p53, l: true };
const DomRowItemOnly$Msg$$order = { Select: 0, Remove: 1 };
const DomRowItemOnly$Msg$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return DomRowItemOnly$Msg$$order[$x.$] < DomRowItemOnly$Msg$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Select":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    default:
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
  }
};
const DomRowItemOnly$Msg$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Select":
      return $x.a === $y.a;
    default:
      return $x.a === $y.a;
  }
};
const DomRowItemOnly$table = (model$1) => ({ t: DomRowItemOnly$k53, v: [model$1] });
export { DomRowItemOnly$Msg$$compare, DomRowItemOnly$Msg$$eq, DomRowItemOnly$table };
//# sourceMappingURL=DomRowItemOnly.mjs.map
