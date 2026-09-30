import { deep as _derived$deep } from "./_core/_derived.mjs";
import { template as $markup$template, slot as $markup$slot, forKeyed as $markup$forKeyed, forPosition as $markup$forPosition } from "./_platform/runtime.foreign.mjs";
import { Maybe$withDefault, Maybe$Maybe$$eq } from "./_core/Maybe.mjs";
const DomSelectorNearMiss$t202 = $markup$template("<div><!><!><!><!><!><!>", 0);
const DomSelectorNearMiss$k202 = { m: (v$17, cx$18) => {
  const r$19 = DomSelectorNearMiss$t202();
  const w$20 = r$19.firstChild;
  const w$21 = w$20.nextSibling;
  const w$22 = w$21.nextSibling;
  const w$23 = w$22.nextSibling;
  const w$24 = w$23.nextSibling;
  const w$25 = w$24.nextSibling;
  const c$26 = $markup$slot(r$19, w$20, cx$18);
  const c$27 = $markup$slot(r$19, w$21, cx$18);
  const c$28 = $markup$slot(r$19, w$22, cx$18);
  const c$29 = $markup$slot(r$19, w$23, cx$18);
  const c$30 = $markup$slot(r$19, w$24, cx$18);
  const c$31 = $markup$slot(r$19, w$25, cx$18);
  $markup$forKeyed(c$26, v$17[0], v$17[1], v$17[2], v$17[3]);
  $markup$forKeyed(c$27, v$17[4], v$17[5], v$17[6], v$17[7]);
  $markup$forKeyed(c$28, v$17[8], v$17[9], v$17[10], v$17[11]);
  $markup$forPosition(c$29, v$17[12], v$17[13], v$17[14]);
  $markup$forKeyed(c$30, v$17[15], v$17[16], v$17[17], v$17[18]);
  $markup$forKeyed(c$31, v$17[19], v$17[20], v$17[21], v$17[22]);
  return { s: r$19, q: null, e: r$19, c0: c$26, c1: c$27, c2: c$28, c3: c$29, c4: c$30, c5: c$31 };
}, p: (i$32, v$33) => {
  $markup$forKeyed(i$32.c0, v$33[0], v$33[1], v$33[2], v$33[3]);
  $markup$forKeyed(i$32.c1, v$33[4], v$33[5], v$33[6], v$33[7]);
  $markup$forKeyed(i$32.c2, v$33[8], v$33[9], v$33[10], v$33[11]);
  $markup$forPosition(i$32.c3, v$33[12], v$33[13], v$33[14]);
  $markup$forKeyed(i$32.c4, v$33[15], v$33[16], v$33[17], v$33[18]);
  $markup$forKeyed(i$32.c5, v$33[19], v$33[20], v$33[21], v$33[22]);
} };
const DomSelectorNearMiss$t68 = $markup$template("<p> ", 0);
const DomSelectorNearMiss$t98 = $markup$template("<p> ", 0);
const DomSelectorNearMiss$t127 = $markup$template("<p> ", 0);
const DomSelectorNearMiss$t152 = $markup$template("<p> ", 0);
const DomSelectorNearMiss$t180 = $markup$template("<p> ", 0);
const DomSelectorNearMiss$t200 = $markup$template("<p> ", 0);
const DomSelectorNearMiss$eq$prim = ($x, $y) => $x === $y;
const DomSelectorNearMiss$eq$r$at = ($m$0, $x, $y, $d = 0) => $d > 400 ? _derived$deep([$m$0, $x.at, $y.at], $d) : $m$0($x.at, $y.at, $d + 1);
const DomSelectorNearMiss$isOn = (selected$1, id$2) => selected$1.$ === "Just" && selected$1.a === id$2 ? "on" : "";
const DomSelectorNearMiss$table = (model$1) => {
  const $t$1 = model$1.rows;
  const $t$3 = ($p$2) => $p$2.id;
  const $t$4 = model$1.rows;
  const $t$6 = ($p$5) => $p$5.id;
  const $t$7 = model$1.rows;
  const $t$9 = ($p$8) => $p$8.id;
  const $t$10 = model$1.rows;
  const $t$11 = model$1.rows;
  const $t$13 = ($p$12) => $p$12.id;
  const $t$14 = model$1.rows;
  const $t$16 = ($p$15) => $p$15.id;
  return { t: DomSelectorNearMiss$k202, v: [$t$1, $t$3, { m: (item$34, position$35, cx$36) => {
    const r$37 = DomSelectorNearMiss$t68();
    const w$38 = r$37.firstChild;
    return { s: r$37, q: null, e: r$37, w0: r$37, w1: w$38, a0: undefined, a1: undefined, x: undefined };
  }, p: (i$39, item$40, position$41) => {
    const $t$42 = model$1.selected.$ === "Just" && model$1.selected.a === item$40.parent ? "on" : "";
    if ($t$42 !== i$39.a0) {
      i$39.w0.setAttribute("class", $t$42);
      i$39.a0 = $t$42;
    }
    if (item$40 !== i$39.x) {
      const $t$43 = item$40.label;
      if ($t$43 !== i$39.a1) {
        i$39.a1 = $t$43;
        i$39.w1.data = $t$43;
      }
    }
  }, w: true, i: false, f: null }, [model$1.selected], $t$4, $t$6, { m: (item$44, position$45, cx$46) => {
    const r$47 = DomSelectorNearMiss$t98();
    const w$48 = r$47.firstChild;
    return { s: r$47, q: null, e: r$47, w0: r$47, w1: w$48, a0: undefined, a1: undefined, x: undefined };
  }, p: (i$49, item$50, position$51) => {
    const $t$52 = model$1.selected.$ === "Just" && model$1.selected.a === item$50.id ? "on" : "";
    const $t$53 = Maybe$withDefault(model$1.selected, 0);
    if ($t$52 !== i$49.a0) {
      i$49.w0.setAttribute("class", $t$52);
      i$49.a0 = $t$52;
    }
    if ($t$53 !== i$49.a1) {
      i$49.a1 = $t$53;
      i$49.w1.data = $t$53;
    }
  }, w: true, i: false, f: null }, [model$1.selected], $t$7, $t$9, { m: (item$54, position$55, cx$56) => {
    const r$57 = DomSelectorNearMiss$t127();
    const w$58 = r$57.firstChild;
    return { s: r$57, q: null, e: r$57, w0: r$57, w1: w$58, a0: undefined, a1: undefined, x: undefined };
  }, p: (i$59, item$60, position$61) => {
    const sel$8 = model$1.selected;
    const $t$62 = sel$8.$ === "Just" && sel$8.a === item$60.id ? "on" : "";
    if ($t$62 !== i$59.a0) {
      i$59.w0.setAttribute("class", $t$62);
      i$59.a0 = $t$62;
    }
    if (item$60 !== i$59.x) {
      const $t$63 = item$60.label;
      if ($t$63 !== i$59.a1) {
        i$59.a1 = $t$63;
        i$59.w1.data = $t$63;
      }
    }
  }, w: true, i: false, f: null }, [model$1.selected], $t$10, { m: (item$64, position$65, cx$66) => {
    const r$67 = DomSelectorNearMiss$t152();
    const w$68 = r$67.firstChild;
    return { s: r$67, q: null, e: r$67, w0: r$67, w1: w$68, a0: undefined, a1: undefined, x: undefined };
  }, p: (i$69, item$70, position$71) => {
    const $t$72 = model$1.selected.$ === "Just" && model$1.selected.a === item$70.id ? "on" : "";
    if ($t$72 !== i$69.a0) {
      i$69.w0.setAttribute("class", $t$72);
      i$69.a0 = $t$72;
    }
    if (item$70 !== i$69.x) {
      const $t$73 = item$70.label;
      if ($t$73 !== i$69.a1) {
        i$69.a1 = $t$73;
        i$69.w1.data = $t$73;
      }
    }
  }, w: true, i: false, f: null }, [model$1.selected], $t$11, $t$13, { m: (item$74, position$75, cx$76) => {
    const r$77 = DomSelectorNearMiss$t180();
    const w$78 = r$77.firstChild;
    return { s: r$77, q: null, e: r$77, w0: r$77, w1: w$78, a0: undefined, a1: undefined, x: undefined };
  }, p: (i$79, item$80, position$81) => {
    const $t$85 = DomSelectorNearMiss$eq$r$at(($p$82, $p$83, $p$84) => Maybe$Maybe$$eq(DomSelectorNearMiss$eq$prim, $p$82, $p$83, $p$84), { at: { $: "Just", a: item$80.id } }, model$1.pick) ? "on" : "";
    if ($t$85 !== i$79.a0) {
      i$79.w0.setAttribute("class", $t$85);
      i$79.a0 = $t$85;
    }
    if (item$80 !== i$79.x) {
      const $t$86 = item$80.label;
      if ($t$86 !== i$79.a1) {
        i$79.a1 = $t$86;
        i$79.w1.data = $t$86;
      }
    }
  }, w: true, i: false, f: null }, [model$1.pick], $t$14, $t$16, { m: (item$87, position$88, cx$89) => {
    const r$90 = DomSelectorNearMiss$t200();
    const w$91 = r$90.firstChild;
    return { s: r$90, q: null, e: r$90, w0: r$90, w1: w$91, a0: undefined, a1: undefined, x: undefined };
  }, p: (i$92, item$93, position$94) => {
    const $t$95 = DomSelectorNearMiss$isOn(model$1.selected, item$93.id + 1);
    if ($t$95 !== i$92.a0) {
      i$92.w0.setAttribute("class", $t$95);
      i$92.a0 = $t$95;
    }
    if (item$93 !== i$92.x) {
      const $t$96 = item$93.label;
      if ($t$96 !== i$92.a1) {
        i$92.a1 = $t$96;
        i$92.w1.data = $t$96;
      }
    }
  }, w: true, i: false, f: null }, [model$1.selected]] };
};
export { DomSelectorNearMiss$table };
