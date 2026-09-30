import { forKeyed as $markup$forKeyed } from "./_platform/runtime.foreign.mjs";
import { Rt$template, Rt$slot, Rt$delegate } from "./_platform/Rt.mjs";
const DomSelector$t173 = Rt$template("<div><!><!><!><!><!>", 0);
const DomSelector$k173 = { m: (v$13, cx$14) => {
  const r$15 = DomSelector$t173();
  const w$16 = r$15.firstChild;
  const w$17 = w$16.nextSibling;
  const w$18 = w$17.nextSibling;
  const w$19 = w$18.nextSibling;
  const w$20 = w$19.nextSibling;
  const c$21 = Rt$slot(r$15, w$16, cx$14);
  const c$22 = Rt$slot(r$15, w$17, cx$14);
  const c$23 = Rt$slot(r$15, w$18, cx$14);
  const c$24 = Rt$slot(r$15, w$19, cx$14);
  const c$25 = Rt$slot(r$15, w$20, cx$14);
  $markup$forKeyed(c$21, v$13[0], v$13[1], v$13[2], v$13[3]);
  $markup$forKeyed(c$22, v$13[4], v$13[5], v$13[6], v$13[7]);
  $markup$forKeyed(c$23, v$13[8], null, v$13[9], v$13[10]);
  $markup$forKeyed(c$24, v$13[11], v$13[12], v$13[13], v$13[14]);
  $markup$forKeyed(c$25, v$13[15], v$13[16], v$13[17], v$13[18]);
  return { s: r$15, q: null, e: r$15, c0: c$21, c1: c$22, c2: c$23, c3: c$24, c4: c$25 };
}, p: (i$26, v$27) => {
  $markup$forKeyed(i$26.c0, v$27[0], v$27[1], v$27[2], v$27[3]);
  $markup$forKeyed(i$26.c1, v$27[4], v$27[5], v$27[6], v$27[7]);
  $markup$forKeyed(i$26.c2, v$27[8], null, v$27[9], v$27[10]);
  $markup$forKeyed(i$26.c3, v$27[11], v$27[12], v$27[13], v$27[14]);
  $markup$forKeyed(i$26.c4, v$27[15], v$27[16], v$27[17], v$27[18]);
} };
const DomSelector$t83 = Rt$template("<p> ", 0);
const DomSelector$t108 = Rt$template("<p> ", 0);
const DomSelector$t127 = Rt$template("<p> ", 0);
const DomSelector$t154 = Rt$template("<p><b> ", 0);
const DomSelector$t171 = Rt$template("<p> ", 0);
const DomSelector$Msg$$compare = ($x, $y) => $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
const DomSelector$Msg$$eq = ($x, $y) => $x.a === $y.a;
const DomSelector$rowClass = (model$1, row$2) => model$1.selected.$ === "Just" && model$1.selected.a === row$2.id ? "danger" : "";
const DomSelector$isOn = (selected$1, id$2) => selected$1.$ === "Just" && selected$1.a === id$2 ? "on" : "";
const DomSelector$table = (model$1) => {
  const $t$1 = model$1.rows;
  const $t$3 = ($p$2) => $p$2.id;
  const $t$4 = model$1.rows;
  const $t$5 = (r$4) => r$4.id;
  const $t$6 = model$1.ids;
  const $t$7 = model$1.rows;
  const $t$9 = ($p$8) => $p$8.id;
  const $t$10 = model$1.rows;
  const $t$12 = ($p$11) => $p$11.id;
  return { t: DomSelector$k173, v: [$t$1, $t$3, { m: (item$28, position$29, cx$30) => {
    const r$31 = DomSelector$t83();
    const w$32 = r$31.firstChild;
    Rt$delegate(["click"]);
    if (cx$30 !== null) {
      r$31.$$cx = cx$30;
    }
    return { s: r$31, q: null, e: r$31, w0: r$31, w1: w$32, a0: undefined, a1: undefined, a2: undefined, x: undefined };
  }, p: (i$33, item$34, position$35) => {
    const $t$36 = DomSelector$rowClass(model$1, item$34);
    if ($t$36 !== i$33.a0) {
      i$33.w0.setAttribute("class", $t$36);
      i$33.a0 = $t$36;
    }
    if (item$34 !== i$33.x) {
      const $t$37 = { $: "Select", a: item$34.id };
      const $t$38 = item$34.label;
      if ($t$37 !== i$33.a1) {
        i$33.a1 = $t$37;
        i$33.w0.$$click = $t$37;
      }
      if ($t$38 !== i$33.a2) {
        i$33.a2 = $t$38;
        i$33.w1.data = $t$38;
      }
    }
  }, w: true, i: false, f: null, g: 0, z: model$1.selected.$ === "Just" ? model$1.selected.a : model$1.selected }, [model$1.selected], $t$4, $t$5, { m: (item$39, position$40, cx$41) => {
    const r$42 = DomSelector$t108();
    const w$43 = r$42.firstChild;
    return { s: r$42, q: null, e: r$42, w0: r$42, w1: w$43, a0: undefined, a1: undefined, x: undefined };
  }, p: (i$44, item$45, position$46) => {
    const id$5 = item$45.id;
    const label$6 = item$45.label;
    const $t$47 = model$1.selected.$ === "Just" && model$1.selected.a === id$5 ? "on" : "";
    if ($t$47 !== i$44.a0) {
      i$44.w0.setAttribute("class", $t$47);
      i$44.a0 = $t$47;
    }
    if (item$45 !== i$44.x) {
      if (label$6 !== i$44.a1) {
        i$44.a1 = label$6;
        i$44.w1.data = label$6;
      }
    }
  }, w: true, i: false, f: null, g: 0, z: model$1.selected.$ === "Just" ? model$1.selected.a : model$1.selected }, [model$1.selected], $t$6, { m: (item$48, position$49, cx$50) => {
    const r$51 = DomSelector$t127();
    const w$52 = r$51.firstChild;
    return { s: r$51, q: null, e: r$51, w0: r$51, w1: w$52, a0: undefined, a1: undefined, x: undefined };
  }, p: (i$53, item$54, position$55) => {
    const $t$56 = item$54 !== model$1.cursor ? "" : "at";
    if ($t$56 !== i$53.a0) {
      i$53.w0.setAttribute("class", $t$56);
      i$53.a0 = $t$56;
    }
    if (item$54 !== i$53.x) {
      if (item$54 !== i$53.a1) {
        i$53.a1 = item$54;
        i$53.w1.data = item$54;
      }
    }
  }, w: true, i: false, f: null, g: 0, z: model$1.cursor }, [model$1.cursor], $t$7, $t$9, { m: (item$57, position$58, cx$59) => {
    const r$60 = DomSelector$t154();
    const w$61 = r$60.firstChild;
    const w$62 = w$61.firstChild;
    return { s: r$60, q: null, e: r$60, w0: r$60, w1: w$61, w2: w$62, a0: undefined, a1: undefined, a2: undefined, x: undefined };
  }, p: (i$63, item$64, position$65) => {
    const $t$66 = model$1.theme;
    const $t$67 = model$1.cursor === item$64.id ? "at" : "";
    if ($t$66 !== i$63.a0) {
      i$63.w0.setAttribute("class", $t$66);
      i$63.a0 = $t$66;
    }
    if ($t$67 !== i$63.a1) {
      i$63.w1.setAttribute("class", $t$67);
      i$63.a1 = $t$67;
    }
    if (item$64 !== i$63.x) {
      const $t$68 = item$64.label;
      if ($t$68 !== i$63.a2) {
        i$63.a2 = $t$68;
        i$63.w2.data = $t$68;
      }
    }
  }, w: true, i: false, f: null, g: 1, z: model$1.cursor }, [model$1.theme, model$1.cursor], $t$10, $t$12, { m: (item$69, position$70, cx$71) => {
    const r$72 = DomSelector$t171();
    const w$73 = r$72.firstChild;
    return { s: r$72, q: null, e: r$72, w0: r$72, w1: w$73, a0: undefined, a1: undefined, x: undefined };
  }, p: (i$74, item$75, position$76) => {
    const $t$77 = DomSelector$isOn(model$1.selected, item$75.id);
    if ($t$77 !== i$74.a0) {
      i$74.w0.setAttribute("class", $t$77);
      i$74.a0 = $t$77;
    }
    if (item$75 !== i$74.x) {
      const $t$78 = item$75.label;
      if ($t$78 !== i$74.a1) {
        i$74.a1 = $t$78;
        i$74.w1.data = $t$78;
      }
    }
  }, w: true, i: false, f: null, g: 0, z: model$1.selected.$ === "Just" ? model$1.selected.a : model$1.selected }, [model$1.selected]] };
};
export { DomSelector$Msg$$compare, DomSelector$Msg$$eq, DomSelector$table };
