import { forKeyed as $markup$forKeyed, delegate as $markup$delegate } from "./_platform/runtime.foreign.mjs";
import { Rt$template, Rt$slot } from "./_platform/Rt.mjs";
const DomRowItemOnly$t53 = Rt$template("<table>", 0);
const DomRowItemOnly$k53 = { m: (v$4, cx$5) => {
  const r$6 = DomRowItemOnly$t53();
  const c$7 = Rt$slot(r$6, null, cx$5);
  $markup$forKeyed(c$7, v$4[0], v$4[1], v$4[2], v$4[3]);
  return { s: r$6, q: null, e: r$6, c0: c$7 };
}, p: (i$8, v$9) => {
  $markup$forKeyed(i$8.c0, v$9[0], v$9[1], v$9[2], v$9[3]);
} };
const DomRowItemOnly$t51 = Rt$template("<tr><td> </td><td><a> </a></td><td><a>x", 0);
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
const DomRowItemOnly$table = (model$1) => {
  const $t$1 = model$1.rows;
  const $t$3 = ($p$2) => $p$2.id;
  return { t: DomRowItemOnly$k53, v: [$t$1, $t$3, { m: (item$10, position$11, cx$12) => {
    const r$13 = DomRowItemOnly$t51();
    const w$14 = r$13.firstChild;
    const w$15 = w$14.firstChild;
    const w$16 = w$14.nextSibling;
    const w$17 = w$16.firstChild;
    const w$18 = w$17.firstChild;
    const w$19 = w$16.nextSibling;
    const w$20 = w$19.firstChild;
    $markup$delegate(["click"]);
    if (cx$12 !== null) {
      w$17.$$cx = cx$12;
    }
    if (cx$12 !== null) {
      w$20.$$cx = cx$12;
    }
    return { s: r$13, q: null, e: r$13, w0: r$13, w2: w$15, w4: w$17, w5: w$18, w7: w$20, a0: undefined, a1: undefined, a2: undefined, a3: undefined, a4: undefined, x: undefined };
  }, p: (i$21, item$22, position$23) => {
    const $t$24 = model$1.selected.$ === "Just" && model$1.selected.a === item$22.id ? "danger" : "";
    if ($t$24 !== i$21.a0) {
      i$21.w0.setAttribute("class", $t$24);
      i$21.a0 = $t$24;
    }
    if (item$22 !== i$21.x) {
      const $t$25 = item$22.id;
      const $t$26 = { $: "Select", a: item$22.id };
      const $t$27 = item$22.label;
      const $t$28 = { $: "Remove", a: item$22.id };
      if ($t$25 !== i$21.a1) {
        i$21.a1 = $t$25;
        i$21.w2.data = $t$25;
      }
      if ($t$26 !== i$21.a2) {
        i$21.a2 = $t$26;
        i$21.w4.$$click = $t$26;
      }
      if ($t$27 !== i$21.a3) {
        i$21.a3 = $t$27;
        i$21.w5.data = $t$27;
      }
      if ($t$28 !== i$21.a4) {
        i$21.a4 = $t$28;
        i$21.w7.$$click = $t$28;
      }
    }
  }, w: true, i: false, f: null, g: 0, z: model$1.selected.$ === "Just" ? model$1.selected.a : model$1.selected }, [model$1.selected]] };
};
export { DomRowItemOnly$Msg$$compare, DomRowItemOnly$Msg$$eq, DomRowItemOnly$table };
