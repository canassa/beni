import { deep as _derived$deep } from "./_core/_derived.mjs";
import { template as $markup$template, slot as $markup$slot, forKeyed as $markup$forKeyed, forPosition as $markup$forPosition } from "./_platform/runtime.foreign.mjs";
import { Maybe$withDefault, Maybe$Maybe$$eq } from "./_core/Maybe.mjs";
import { Basics$add } from "./_core/Basics.mjs";
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
    const $t$37 = model$1.selected.$ === "Just" && model$1.selected.a === item$34.parent ? "on" : "";
    const $t$38 = item$34.label;
    const r$39 = DomSelectorNearMiss$t68();
    const w$40 = r$39.firstChild;
    r$39.setAttribute("class", $t$37);
    w$40.data = $t$38;
    return { s: r$39, q: null, e: r$39, w0: r$39, w1: w$40, a0: $t$37, a1: $t$38 };
  }, p: (i$41, item$42, position$43) => {
    const $t$44 = model$1.selected.$ === "Just" && model$1.selected.a === item$42.parent ? "on" : "";
    if ($t$44 !== i$41.a0) {
      i$41.w0.setAttribute("class", $t$44);
      i$41.a0 = $t$44;
    }
    if (item$42 !== i$41.x) {
      const $t$45 = item$42.label;
      if ($t$45 !== i$41.a1) {
        i$41.a1 = $t$45;
        i$41.w1.data = $t$45;
      }
    }
  }, i: false, f: null }, [model$1.selected], $t$4, $t$6, { m: (item$46, position$47, cx$48) => {
    const $t$49 = model$1.selected.$ === "Just" && model$1.selected.a === item$46.id ? "on" : "";
    const $t$50 = Maybe$withDefault(model$1.selected, 0);
    const r$51 = DomSelectorNearMiss$t98();
    const w$52 = r$51.firstChild;
    r$51.setAttribute("class", $t$49);
    w$52.data = $t$50;
    return { s: r$51, q: null, e: r$51, w0: r$51, w1: w$52, a0: $t$49, a1: $t$50 };
  }, p: (i$53, item$54, position$55) => {
    const $t$56 = model$1.selected.$ === "Just" && model$1.selected.a === item$54.id ? "on" : "";
    const $t$57 = Maybe$withDefault(model$1.selected, 0);
    if ($t$56 !== i$53.a0) {
      i$53.w0.setAttribute("class", $t$56);
      i$53.a0 = $t$56;
    }
    if ($t$57 !== i$53.a1) {
      i$53.a1 = $t$57;
      i$53.w1.data = $t$57;
    }
  }, i: false, f: null }, [model$1.selected], $t$7, $t$9, { m: (item$58, position$59, cx$60) => {
    const sel$8 = model$1.selected;
    const $t$61 = sel$8.$ === "Just" && sel$8.a === item$58.id ? "on" : "";
    const $t$62 = item$58.label;
    const r$63 = DomSelectorNearMiss$t127();
    const w$64 = r$63.firstChild;
    r$63.setAttribute("class", $t$61);
    w$64.data = $t$62;
    return { s: r$63, q: null, e: r$63, w0: r$63, w1: w$64, a0: $t$61, a1: $t$62 };
  }, p: (i$65, item$66, position$67) => {
    const sel$8 = model$1.selected;
    const $t$68 = sel$8.$ === "Just" && sel$8.a === item$66.id ? "on" : "";
    if ($t$68 !== i$65.a0) {
      i$65.w0.setAttribute("class", $t$68);
      i$65.a0 = $t$68;
    }
    if (item$66 !== i$65.x) {
      const $t$69 = item$66.label;
      if ($t$69 !== i$65.a1) {
        i$65.a1 = $t$69;
        i$65.w1.data = $t$69;
      }
    }
  }, i: false, f: null }, [model$1.selected], $t$10, { m: (item$70, position$71, cx$72) => {
    const $t$73 = model$1.selected.$ === "Just" && model$1.selected.a === item$70.id ? "on" : "";
    const $t$74 = item$70.label;
    const r$75 = DomSelectorNearMiss$t152();
    const w$76 = r$75.firstChild;
    r$75.setAttribute("class", $t$73);
    w$76.data = $t$74;
    return { s: r$75, q: null, e: r$75, w0: r$75, w1: w$76, a0: $t$73, a1: $t$74 };
  }, p: (i$77, item$78, position$79) => {
    const $t$80 = model$1.selected.$ === "Just" && model$1.selected.a === item$78.id ? "on" : "";
    if ($t$80 !== i$77.a0) {
      i$77.w0.setAttribute("class", $t$80);
      i$77.a0 = $t$80;
    }
    if (item$78 !== i$77.x) {
      const $t$81 = item$78.label;
      if ($t$81 !== i$77.a1) {
        i$77.a1 = $t$81;
        i$77.w1.data = $t$81;
      }
    }
  }, i: false, f: null }, [model$1.selected], $t$11, $t$13, { m: (item$82, position$83, cx$84) => {
    const $t$88 = DomSelectorNearMiss$eq$r$at(($p$85, $p$86, $p$87) => Maybe$Maybe$$eq(DomSelectorNearMiss$eq$prim, $p$85, $p$86, $p$87), { at: { $: "Just", a: item$82.id } }, model$1.pick) ? "on" : "";
    const $t$89 = item$82.label;
    const r$90 = DomSelectorNearMiss$t180();
    const w$91 = r$90.firstChild;
    r$90.setAttribute("class", $t$88);
    w$91.data = $t$89;
    return { s: r$90, q: null, e: r$90, w0: r$90, w1: w$91, a0: $t$88, a1: $t$89 };
  }, p: (i$92, item$93, position$94) => {
    const $t$98 = DomSelectorNearMiss$eq$r$at(($p$95, $p$96, $p$97) => Maybe$Maybe$$eq(DomSelectorNearMiss$eq$prim, $p$95, $p$96, $p$97), { at: { $: "Just", a: item$93.id } }, model$1.pick) ? "on" : "";
    if ($t$98 !== i$92.a0) {
      i$92.w0.setAttribute("class", $t$98);
      i$92.a0 = $t$98;
    }
    if (item$93 !== i$92.x) {
      const $t$99 = item$93.label;
      if ($t$99 !== i$92.a1) {
        i$92.a1 = $t$99;
        i$92.w1.data = $t$99;
      }
    }
  }, i: false, f: null }, [model$1.pick], $t$14, $t$16, { m: (item$100, position$101, cx$102) => {
    const $t$103 = DomSelectorNearMiss$isOn(model$1.selected, Basics$add(item$100.id, 1));
    const $t$104 = item$100.label;
    const r$105 = DomSelectorNearMiss$t200();
    const w$106 = r$105.firstChild;
    r$105.setAttribute("class", $t$103);
    w$106.data = $t$104;
    return { s: r$105, q: null, e: r$105, w0: r$105, w1: w$106, a0: $t$103, a1: $t$104 };
  }, p: (i$107, item$108, position$109) => {
    const $t$110 = DomSelectorNearMiss$isOn(model$1.selected, Basics$add(item$108.id, 1));
    if ($t$110 !== i$107.a0) {
      i$107.w0.setAttribute("class", $t$110);
      i$107.a0 = $t$110;
    }
    if (item$108 !== i$107.x) {
      const $t$111 = item$108.label;
      if ($t$111 !== i$107.a1) {
        i$107.a1 = $t$111;
        i$107.w1.data = $t$111;
      }
    }
  }, i: false, f: null }, [model$1.selected]] };
};
export { DomSelectorNearMiss$table };
