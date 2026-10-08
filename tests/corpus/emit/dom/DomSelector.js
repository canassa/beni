import { Rt$template, Rt$delegate, Rt$forKeyed, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
const DomSelector$t83 = Rt$template("<p> ", 0);
const DomSelector$t108 = Rt$template("<p> ", 0);
const DomSelector$t171 = Rt$template("<p> ", 0);
const DomSelector$t127 = Rt$template("<p> ", 0);
const DomSelector$t154 = Rt$template("<p><b> ", 0);
const DomSelector$p173 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if ($in$3.rows !== i$1.g0_0 || $in$3.selected !== i$1.g0_1) {
    i$1.g0_0 = $in$3.rows;
    i$1.g0_1 = $in$3.selected;
    const $t$4 = $in$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $t$7 = $in$3.rows;
    const $t$8 = (r$4) => r$4.id;
    const $t$9 = $in$3.rows;
    const $t$11 = ($p$10) => $p$10.id;
    const made$12 = { m: (item$13, position$14, cx$15) => {
      const r$16 = DomSelector$t83();
      const w$17 = r$16.firstChild;
      Rt$delegate(["click"]);
      if (cx$15 !== null) {
        r$16.$$cx = cx$15;
        r$16.$$clickF = 4;
      }
      return { s: r$16, q: null, e: r$16, w0: r$16, w1: w$17, a0: undefined, a1: undefined, a2: undefined, x: undefined };
    }, p: (i$18, item$19, position$20) => {
      const $t$21 = DomSelector$rowClass($in$3, item$19);
      if ($t$21 !== i$18.a0) {
        i$18.w0.setAttribute("class", $t$21);
        i$18.a0 = $t$21;
      }
      if (item$19 !== i$18.x) {
        const $t$22 = { $: "Select", a: item$19.id };
        const $t$23 = item$19.label;
        if ($t$22 !== i$18.a1) {
          i$18.a1 = $t$22;
          i$18.w0.$$click = $t$22;
        }
        if ($t$23 !== i$18.a2) {
          i$18.a2 = $t$23;
          i$18.w1.data = $t$23;
        }
      }
    }, w: true, i: false, f: null, g: 0, z: $in$3.selected.$ === "Just" ? $in$3.selected.a : $in$3.selected };
    Rt$forKeyed(i$1.c0, $t$4, $t$6, made$12, [$in$3.selected]);
    const made$24 = { m: (item$25, position$26, cx$27) => {
      const r$28 = DomSelector$t108();
      const w$29 = r$28.firstChild;
      return { s: r$28, q: null, e: r$28, w0: r$28, w1: w$29, a0: undefined, a1: undefined, x: undefined };
    }, p: (i$30, item$31, position$32) => {
      const id$5 = item$31.id;
      const label$6 = item$31.label;
      const $t$33 = $in$3.selected.$ === "Just" && $in$3.selected.a === id$5 ? "on" : "";
      if ($t$33 !== i$30.a0) {
        i$30.w0.setAttribute("class", $t$33);
        i$30.a0 = $t$33;
      }
      if (item$31 !== i$30.x) {
        if (label$6 !== i$30.a1) {
          i$30.a1 = label$6;
          i$30.w1.data = label$6;
        }
      }
    }, w: true, i: false, f: null, g: 0, z: $in$3.selected.$ === "Just" ? $in$3.selected.a : $in$3.selected };
    Rt$forKeyed(i$1.c1, $t$7, $t$8, made$24, [$in$3.selected]);
    const made$34 = { m: (item$35, position$36, cx$37) => {
      const r$38 = DomSelector$t171();
      const w$39 = r$38.firstChild;
      return { s: r$38, q: null, e: r$38, w0: r$38, w1: w$39, a0: undefined, a1: undefined, x: undefined };
    }, p: (i$40, item$41, position$42) => {
      const $t$43 = DomSelector$isOn($in$3.selected, item$41.id);
      if ($t$43 !== i$40.a0) {
        i$40.w0.setAttribute("class", $t$43);
        i$40.a0 = $t$43;
      }
      if (item$41 !== i$40.x) {
        const $t$44 = item$41.label;
        if ($t$44 !== i$40.a1) {
          i$40.a1 = $t$44;
          i$40.w1.data = $t$44;
        }
      }
    }, w: true, i: false, f: null, g: 0, z: $in$3.selected.$ === "Just" ? $in$3.selected.a : $in$3.selected };
    Rt$forKeyed(i$1.c4, $t$9, $t$11, made$34, [$in$3.selected]);
  } else {
    Rt$restate(i$1.c0);
    Rt$restate(i$1.c1);
    Rt$restate(i$1.c4);
  }
  if ($in$3.ids !== i$1.g1_0 || $in$3.cursor !== i$1.g1_1) {
    i$1.g1_0 = $in$3.ids;
    i$1.g1_1 = $in$3.cursor;
    const $t$45 = $in$3.ids;
    const made$46 = { m: (item$47, position$48, cx$49) => {
      const r$50 = DomSelector$t127();
      const w$51 = r$50.firstChild;
      return { s: r$50, q: null, e: r$50, w0: r$50, w1: w$51, a0: undefined, a1: undefined, x: undefined };
    }, p: (i$52, item$53, position$54) => {
      const $t$55 = item$53 !== $in$3.cursor ? "" : "at";
      if ($t$55 !== i$52.a0) {
        i$52.w0.setAttribute("class", $t$55);
        i$52.a0 = $t$55;
      }
      if (item$53 !== i$52.x) {
        if (item$53 !== i$52.a1) {
          i$52.a1 = item$53;
          i$52.w1.data = item$53;
        }
      }
    }, w: true, i: false, f: null, g: 0, z: $in$3.cursor };
    Rt$forKeyed(i$1.c2, $t$45, null, made$46, [$in$3.cursor]);
  } else {
    Rt$restate(i$1.c2);
  }
  if ($in$3.rows !== i$1.g2_0 || $in$3.cursor !== i$1.g2_1 || $in$3.theme !== i$1.g2_2) {
    i$1.g2_0 = $in$3.rows;
    i$1.g2_1 = $in$3.cursor;
    i$1.g2_2 = $in$3.theme;
    const $t$56 = $in$3.rows;
    const $t$58 = ($p$57) => $p$57.id;
    const made$59 = { m: (item$60, position$61, cx$62) => {
      const r$63 = DomSelector$t154();
      const w$64 = r$63.firstChild;
      const w$65 = w$64.firstChild;
      return { s: r$63, q: null, e: r$63, w0: r$63, w1: w$64, w2: w$65, a0: undefined, a1: undefined, a2: undefined, x: undefined };
    }, p: (i$66, item$67, position$68) => {
      const $t$69 = $in$3.theme;
      const $t$70 = $in$3.cursor === item$67.id ? "at" : "";
      if ($t$69 !== i$66.a0) {
        i$66.w0.setAttribute("class", $t$69);
        i$66.a0 = $t$69;
      }
      if ($t$70 !== i$66.a1) {
        i$66.w1.setAttribute("class", $t$70);
        i$66.a1 = $t$70;
      }
      if (item$67 !== i$66.x) {
        const $t$71 = item$67.label;
        if ($t$71 !== i$66.a2) {
          i$66.a2 = $t$71;
          i$66.w2.data = $t$71;
        }
      }
    }, w: true, i: false, f: null, g: 1, z: $in$3.cursor };
    Rt$forKeyed(i$1.c3, $t$56, $t$58, made$59, [$in$3.theme, $in$3.cursor]);
  } else {
    Rt$restate(i$1.c3);
  }
  i$1.l = i$1.c0.w || i$1.c0.l || i$1.c1.w || i$1.c1.l || i$1.c2.w || i$1.c2.l || i$1.c3.w || i$1.c3.l || i$1.c4.w || i$1.c4.l;
};
const DomSelector$t173 = Rt$template("<div><!><!><!><!><!>", 0);
const DomSelector$k173 = { m: (v$72, cx$73) => {
  const r$74 = DomSelector$t173();
  const w$75 = r$74.firstChild;
  const w$76 = w$75.nextSibling;
  const w$77 = w$76.nextSibling;
  const w$78 = w$77.nextSibling;
  const w$79 = w$78.nextSibling;
  const c$80 = Rt$slot(r$74, w$75, cx$73);
  const c$81 = Rt$slot(r$74, w$76, cx$73);
  const c$82 = Rt$slot(r$74, w$77, cx$73);
  const c$83 = Rt$slot(r$74, w$78, cx$73);
  const c$84 = Rt$slot(r$74, w$79, cx$73);
  const i$85 = { s: r$74, q: null, e: r$74, c0: c$80, c1: c$81, c2: c$82, c3: c$83, c4: c$84, g0_0: NaN, g0_1: NaN, g1_0: NaN, g1_1: NaN, g2_0: NaN, g2_1: NaN, g2_2: NaN };
  DomSelector$p173(i$85, v$72);
  return i$85;
}, p: DomSelector$p173, l: true };
const DomSelector$Msg$$compare = ($x, $y) => $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
const DomSelector$Msg$$eq = ($x, $y) => $x.a === $y.a;
const DomSelector$rowClass = (model$1, row$2) => model$1.selected.$ === "Just" && model$1.selected.a === row$2.id ? "danger" : "";
const DomSelector$isOn = (selected$1, id$2) => selected$1.$ === "Just" && selected$1.a === id$2 ? "on" : "";
const DomSelector$table = (model$1) => ({ t: DomSelector$k173, v: [model$1] });
export { DomSelector$Msg$$compare, DomSelector$Msg$$eq, DomSelector$table };
//# sourceMappingURL=DomSelector.mjs.map
