import { deep as _derived$deep } from "./_core/_derived.mjs";
import { Rt$template, Rt$forKeyed, Rt$forPosition, Rt$slot } from "./_platform/Rt.mjs";
import { Maybe$withDefault, Maybe$Maybe$$eq } from "./_core/Maybe.mjs";
const DomSelectorNearMiss$t68 = Rt$template("<p> ", 0);
const DomSelectorNearMiss$t98 = Rt$template("<p> ", 0);
const DomSelectorNearMiss$t127 = Rt$template("<p> ", 0);
const DomSelectorNearMiss$t152 = Rt$template("<p> ", 0);
const DomSelectorNearMiss$t200 = Rt$template("<p> ", 0);
const DomSelectorNearMiss$t180 = Rt$template("<p> ", 0);
const DomSelectorNearMiss$p202 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if ($in$3.rows !== i$1.g0_0 || $in$3.selected !== i$1.g0_1) {
    i$1.g0_0 = $in$3.rows;
    i$1.g0_1 = $in$3.selected;
    const $t$4 = $in$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $t$7 = $in$3.rows;
    const $t$9 = ($p$8) => $p$8.id;
    const $t$10 = $in$3.rows;
    const $t$12 = ($p$11) => $p$11.id;
    const $t$13 = $in$3.rows;
    const $t$14 = $in$3.rows;
    const $t$16 = ($p$15) => $p$15.id;
    const made$17 = { m: (item$18, position$19, cx$20) => {
      const r$21 = DomSelectorNearMiss$t68();
      const w$22 = r$21.firstChild;
      return { s: r$21, q: null, e: r$21, w0: r$21, w1: w$22, a0: undefined, a1: undefined, x: undefined };
    }, p: (i$23, item$24, position$25) => {
      const $t$26 = $in$3.selected.$ === "Just" && $in$3.selected.a === item$24.parent ? "on" : "";
      if ($t$26 !== i$23.a0) {
        i$23.w0.setAttribute("class", $t$26);
        i$23.a0 = $t$26;
      }
      if (item$24 !== i$23.x) {
        const $t$27 = item$24.label;
        if ($t$27 !== i$23.a1) {
          i$23.a1 = $t$27;
          i$23.w1.data = $t$27;
        }
      }
    }, w: true, i: false, f: null };
    Rt$forKeyed(i$1.c0, $t$4, $t$6, made$17, [$in$3.selected]);
    const made$28 = { m: (item$29, position$30, cx$31) => {
      const r$32 = DomSelectorNearMiss$t98();
      const w$33 = r$32.firstChild;
      return { s: r$32, q: null, e: r$32, w0: r$32, w1: w$33, a0: undefined, a1: undefined, x: undefined };
    }, p: (i$34, item$35, position$36) => {
      const $t$37 = $in$3.selected.$ === "Just" && $in$3.selected.a === item$35.id ? "on" : "";
      const $t$38 = Maybe$withDefault($in$3.selected, 0);
      if ($t$37 !== i$34.a0) {
        i$34.w0.setAttribute("class", $t$37);
        i$34.a0 = $t$37;
      }
      if ($t$38 !== i$34.a1) {
        i$34.a1 = $t$38;
        i$34.w1.data = $t$38;
      }
    }, w: true, i: false, f: null };
    Rt$forKeyed(i$1.c1, $t$7, $t$9, made$28, [$in$3.selected]);
    const made$39 = { m: (item$40, position$41, cx$42) => {
      const r$43 = DomSelectorNearMiss$t127();
      const w$44 = r$43.firstChild;
      return { s: r$43, q: null, e: r$43, w0: r$43, w1: w$44, a0: undefined, a1: undefined, x: undefined };
    }, p: (i$45, item$46, position$47) => {
      const sel$8 = $in$3.selected;
      const $t$48 = sel$8.$ === "Just" && sel$8.a === item$46.id ? "on" : "";
      if ($t$48 !== i$45.a0) {
        i$45.w0.setAttribute("class", $t$48);
        i$45.a0 = $t$48;
      }
      if (item$46 !== i$45.x) {
        const $t$49 = item$46.label;
        if ($t$49 !== i$45.a1) {
          i$45.a1 = $t$49;
          i$45.w1.data = $t$49;
        }
      }
    }, w: true, i: false, f: null };
    Rt$forKeyed(i$1.c2, $t$10, $t$12, made$39, [$in$3.selected]);
    const made$50 = { m: (item$51, position$52, cx$53) => {
      const r$54 = DomSelectorNearMiss$t152();
      const w$55 = r$54.firstChild;
      return { s: r$54, q: null, e: r$54, w0: r$54, w1: w$55, a0: undefined, a1: undefined, x: undefined };
    }, p: (i$56, item$57, position$58) => {
      const $t$59 = $in$3.selected.$ === "Just" && $in$3.selected.a === item$57.id ? "on" : "";
      if ($t$59 !== i$56.a0) {
        i$56.w0.setAttribute("class", $t$59);
        i$56.a0 = $t$59;
      }
      if (item$57 !== i$56.x) {
        const $t$60 = item$57.label;
        if ($t$60 !== i$56.a1) {
          i$56.a1 = $t$60;
          i$56.w1.data = $t$60;
        }
      }
    }, w: true, i: false, f: null };
    Rt$forPosition(i$1.c3, $t$13, made$50, [$in$3.selected]);
    const made$61 = { m: (item$62, position$63, cx$64) => {
      const r$65 = DomSelectorNearMiss$t200();
      const w$66 = r$65.firstChild;
      return { s: r$65, q: null, e: r$65, w0: r$65, w1: w$66, a0: undefined, a1: undefined, x: undefined };
    }, p: (i$67, item$68, position$69) => {
      const $t$70 = DomSelectorNearMiss$isOn($in$3.selected, item$68.id + 1);
      if ($t$70 !== i$67.a0) {
        i$67.w0.setAttribute("class", $t$70);
        i$67.a0 = $t$70;
      }
      if (item$68 !== i$67.x) {
        const $t$71 = item$68.label;
        if ($t$71 !== i$67.a1) {
          i$67.a1 = $t$71;
          i$67.w1.data = $t$71;
        }
      }
    }, w: true, i: false, f: null };
    Rt$forKeyed(i$1.c5, $t$14, $t$16, made$61, [$in$3.selected]);
  }
  if ($in$3.rows !== i$1.g1_0 || $in$3.pick !== i$1.g1_1) {
    i$1.g1_0 = $in$3.rows;
    i$1.g1_1 = $in$3.pick;
    const $t$72 = $in$3.rows;
    const $t$74 = ($p$73) => $p$73.id;
    const made$75 = { m: (item$76, position$77, cx$78) => {
      const r$79 = DomSelectorNearMiss$t180();
      const w$80 = r$79.firstChild;
      return { s: r$79, q: null, e: r$79, w0: r$79, w1: w$80, a0: undefined, a1: undefined, x: undefined };
    }, p: (i$81, item$82, position$83) => {
      const $t$87 = DomSelectorNearMiss$eq$r$at(($p$84, $p$85, $p$86) => Maybe$Maybe$$eq(DomSelectorNearMiss$eq$prim, $p$84, $p$85, $p$86), { at: { $: "Just", a: item$82.id } }, $in$3.pick) ? "on" : "";
      if ($t$87 !== i$81.a0) {
        i$81.w0.setAttribute("class", $t$87);
        i$81.a0 = $t$87;
      }
      if (item$82 !== i$81.x) {
        const $t$88 = item$82.label;
        if ($t$88 !== i$81.a1) {
          i$81.a1 = $t$88;
          i$81.w1.data = $t$88;
        }
      }
    }, w: true, i: false, f: null };
    Rt$forKeyed(i$1.c4, $t$72, $t$74, made$75, [$in$3.pick]);
  }
};
const DomSelectorNearMiss$t202 = Rt$template("<div><!><!><!><!><!><!>", 0);
const DomSelectorNearMiss$k202 = { m: (v$89, cx$90) => {
  const r$91 = DomSelectorNearMiss$t202();
  const w$92 = r$91.firstChild;
  const w$93 = w$92.nextSibling;
  const w$94 = w$93.nextSibling;
  const w$95 = w$94.nextSibling;
  const w$96 = w$95.nextSibling;
  const w$97 = w$96.nextSibling;
  const c$98 = Rt$slot(r$91, w$92, cx$90);
  const c$99 = Rt$slot(r$91, w$93, cx$90);
  const c$100 = Rt$slot(r$91, w$94, cx$90);
  const c$101 = Rt$slot(r$91, w$95, cx$90);
  const c$102 = Rt$slot(r$91, w$96, cx$90);
  const c$103 = Rt$slot(r$91, w$97, cx$90);
  const i$104 = { s: r$91, q: null, e: r$91, c0: c$98, c1: c$99, c2: c$100, c3: c$101, c4: c$102, c5: c$103, g0_0: undefined, g0_1: undefined, g1_0: undefined, g1_1: undefined };
  DomSelectorNearMiss$p202(i$104, v$89);
  return i$104;
}, p: DomSelectorNearMiss$p202 };
const DomSelectorNearMiss$eq$prim = ($x, $y) => $x === $y;
const DomSelectorNearMiss$eq$r$at = ($m$0, $x, $y, $d = 0) => $d > 400 ? _derived$deep([$m$0, $x.at, $y.at], $d) : $m$0($x.at, $y.at, $d + 1);
const DomSelectorNearMiss$isOn = (selected$1, id$2) => selected$1.$ === "Just" && selected$1.a === id$2 ? "on" : "";
const DomSelectorNearMiss$table = (model$1) => ({ t: DomSelectorNearMiss$k202, v: [model$1] });
export { DomSelectorNearMiss$table };
//# sourceMappingURL=DomSelectorNearMiss.mjs.map
