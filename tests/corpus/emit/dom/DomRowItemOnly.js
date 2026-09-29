import { template as $markup$template, slot as $markup$slot, forKeyed as $markup$forKeyed, delegate as $markup$delegate } from "./_platform/runtime.foreign.mjs";
const DomRowItemOnly$t53 = $markup$template("<table>", 0);
const DomRowItemOnly$k53 = { m: (v$4, cx$5) => {
  const r$6 = DomRowItemOnly$t53();
  const c$7 = $markup$slot(r$6, null, cx$5);
  $markup$forKeyed(c$7, v$4[0], v$4[1], v$4[2], v$4[3]);
  return { s: r$6, q: null, e: r$6, c0: c$7 };
}, p: (i$8, v$9) => {
  $markup$forKeyed(i$8.c0, v$9[0], v$9[1], v$9[2], v$9[3]);
} };
const DomRowItemOnly$t51 = $markup$template("<tr><td> </td><td><a> </a></td><td><a>x", 0);
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
    const $t$13 = model$1.selected.$ === "Just" && model$1.selected.a === item$10.id ? "danger" : "";
    const $t$14 = item$10.id;
    const $t$15 = { $: "Select", a: item$10.id };
    const $t$16 = item$10.label;
    const $t$17 = { $: "Remove", a: item$10.id };
    const r$18 = DomRowItemOnly$t51();
    const w$19 = r$18.firstChild;
    const w$20 = w$19.firstChild;
    const w$21 = w$19.nextSibling;
    const w$22 = w$21.firstChild;
    const w$23 = w$22.firstChild;
    const w$24 = w$21.nextSibling;
    const w$25 = w$24.firstChild;
    $markup$delegate(["click"]);
    r$18.setAttribute("class", $t$13);
    w$20.data = $t$14;
    w$22.$$click = $t$15;
    if (cx$12 !== null) {
      w$22.$$cx = cx$12;
    }
    w$23.data = $t$16;
    w$25.$$click = $t$17;
    if (cx$12 !== null) {
      w$25.$$cx = cx$12;
    }
    return { s: r$18, q: null, e: r$18, w0: r$18, w2: w$20, w4: w$22, w5: w$23, w7: w$25, a0: $t$13, a1: $t$14, a2: $t$15, a3: $t$16, a4: $t$17 };
  }, p: (i$26, item$27, position$28) => {
    const $t$29 = model$1.selected.$ === "Just" && model$1.selected.a === item$27.id ? "danger" : "";
    if ($t$29 !== i$26.a0) {
      i$26.w0.setAttribute("class", $t$29);
      i$26.a0 = $t$29;
    }
    if (item$27 !== i$26.x) {
      const $t$30 = item$27.id;
      const $t$31 = { $: "Select", a: item$27.id };
      const $t$32 = item$27.label;
      const $t$33 = { $: "Remove", a: item$27.id };
      if ($t$30 !== i$26.a1) {
        i$26.a1 = $t$30;
        i$26.w2.data = $t$30;
      }
      if ($t$31 !== i$26.a2) {
        i$26.a2 = $t$31;
        i$26.w4.$$click = $t$31;
      }
      if ($t$32 !== i$26.a3) {
        i$26.a3 = $t$32;
        i$26.w5.data = $t$32;
      }
      if ($t$33 !== i$26.a4) {
        i$26.a4 = $t$33;
        i$26.w7.$$click = $t$33;
      }
    }
  }, i: false, f: null }, [model$1.selected]] };
};
export { DomRowItemOnly$Msg$$compare, DomRowItemOnly$Msg$$eq, DomRowItemOnly$table };
