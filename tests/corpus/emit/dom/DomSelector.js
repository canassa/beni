import { template as $markup$template, slot as $markup$slot, forKeyed as $markup$forKeyed, delegate as $markup$delegate } from "./_platform/runtime.foreign.mjs";
const DomSelector$t173 = $markup$template("<div><!><!><!><!><!>", 0);
const DomSelector$k173 = { m: (v$13, cx$14) => {
  const r$15 = DomSelector$t173();
  const w$16 = r$15.firstChild;
  const w$17 = w$16.nextSibling;
  const w$18 = w$17.nextSibling;
  const w$19 = w$18.nextSibling;
  const w$20 = w$19.nextSibling;
  const c$21 = $markup$slot(r$15, w$16, cx$14);
  const c$22 = $markup$slot(r$15, w$17, cx$14);
  const c$23 = $markup$slot(r$15, w$18, cx$14);
  const c$24 = $markup$slot(r$15, w$19, cx$14);
  const c$25 = $markup$slot(r$15, w$20, cx$14);
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
const DomSelector$t83 = $markup$template("<p> ", 0);
const DomSelector$t108 = $markup$template("<p> ", 0);
const DomSelector$t127 = $markup$template("<p> ", 0);
const DomSelector$t154 = $markup$template("<p><b> ", 0);
const DomSelector$t171 = $markup$template("<p> ", 0);
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
    const $t$31 = DomSelector$rowClass(model$1, item$28);
    const $t$32 = { $: "Select", a: item$28.id };
    const $t$33 = item$28.label;
    const r$34 = DomSelector$t83();
    const w$35 = r$34.firstChild;
    $markup$delegate(["click"]);
    r$34.setAttribute("class", $t$31);
    r$34.$$click = $t$32;
    if (cx$30 !== null) {
      r$34.$$cx = cx$30;
    }
    w$35.data = $t$33;
    return { s: r$34, q: null, e: r$34, w0: r$34, w1: w$35, a0: $t$31, a1: $t$32, a2: $t$33 };
  }, p: (i$36, item$37, position$38) => {
    const $t$39 = DomSelector$rowClass(model$1, item$37);
    if ($t$39 !== i$36.a0) {
      i$36.w0.setAttribute("class", $t$39);
      i$36.a0 = $t$39;
    }
    if (item$37 !== i$36.x) {
      const $t$40 = { $: "Select", a: item$37.id };
      const $t$41 = item$37.label;
      if ($t$40 !== i$36.a1) {
        i$36.a1 = $t$40;
        i$36.w0.$$click = $t$40;
      }
      if ($t$41 !== i$36.a2) {
        i$36.a2 = $t$41;
        i$36.w1.data = $t$41;
      }
    }
  }, i: false, f: null, g: 0, z: model$1.selected.$ === "Just" ? model$1.selected.a : model$1.selected }, [model$1.selected], $t$4, $t$5, { m: (item$42, position$43, cx$44) => {
    const id$5 = item$42.id;
    const label$6 = item$42.label;
    const $t$45 = model$1.selected.$ === "Just" && model$1.selected.a === id$5 ? "on" : "";
    const r$46 = DomSelector$t108();
    const w$47 = r$46.firstChild;
    r$46.setAttribute("class", $t$45);
    w$47.data = label$6;
    return { s: r$46, q: null, e: r$46, w0: r$46, w1: w$47, a0: $t$45, a1: label$6 };
  }, p: (i$48, item$49, position$50) => {
    const id$5 = item$49.id;
    const label$6 = item$49.label;
    const $t$51 = model$1.selected.$ === "Just" && model$1.selected.a === id$5 ? "on" : "";
    if ($t$51 !== i$48.a0) {
      i$48.w0.setAttribute("class", $t$51);
      i$48.a0 = $t$51;
    }
    if (item$49 !== i$48.x) {
      if (label$6 !== i$48.a1) {
        i$48.a1 = label$6;
        i$48.w1.data = label$6;
      }
    }
  }, i: false, f: null, g: 0, z: model$1.selected.$ === "Just" ? model$1.selected.a : model$1.selected }, [model$1.selected], $t$6, { m: (item$52, position$53, cx$54) => {
    const $t$55 = item$52 !== model$1.cursor ? "" : "at";
    const r$56 = DomSelector$t127();
    const w$57 = r$56.firstChild;
    r$56.setAttribute("class", $t$55);
    w$57.data = item$52;
    return { s: r$56, q: null, e: r$56, w0: r$56, w1: w$57, a0: $t$55, a1: item$52 };
  }, p: (i$58, item$59, position$60) => {
    const $t$61 = item$59 !== model$1.cursor ? "" : "at";
    if ($t$61 !== i$58.a0) {
      i$58.w0.setAttribute("class", $t$61);
      i$58.a0 = $t$61;
    }
    if (item$59 !== i$58.x) {
      if (item$59 !== i$58.a1) {
        i$58.a1 = item$59;
        i$58.w1.data = item$59;
      }
    }
  }, i: false, f: null, g: 0, z: model$1.cursor }, [model$1.cursor], $t$7, $t$9, { m: (item$62, position$63, cx$64) => {
    const $t$65 = model$1.theme;
    const $t$66 = model$1.cursor === item$62.id ? "at" : "";
    const $t$67 = item$62.label;
    const r$68 = DomSelector$t154();
    const w$69 = r$68.firstChild;
    const w$70 = w$69.firstChild;
    r$68.setAttribute("class", $t$65);
    w$69.setAttribute("class", $t$66);
    w$70.data = $t$67;
    return { s: r$68, q: null, e: r$68, w0: r$68, w1: w$69, w2: w$70, a0: $t$65, a1: $t$66, a2: $t$67 };
  }, p: (i$71, item$72, position$73) => {
    const $t$74 = model$1.theme;
    const $t$75 = model$1.cursor === item$72.id ? "at" : "";
    if ($t$74 !== i$71.a0) {
      i$71.w0.setAttribute("class", $t$74);
      i$71.a0 = $t$74;
    }
    if ($t$75 !== i$71.a1) {
      i$71.w1.setAttribute("class", $t$75);
      i$71.a1 = $t$75;
    }
    if (item$72 !== i$71.x) {
      const $t$76 = item$72.label;
      if ($t$76 !== i$71.a2) {
        i$71.a2 = $t$76;
        i$71.w2.data = $t$76;
      }
    }
  }, i: false, f: null, g: 1, z: model$1.cursor }, [model$1.theme, model$1.cursor], $t$10, $t$12, { m: (item$77, position$78, cx$79) => {
    const $t$80 = DomSelector$isOn(model$1.selected, item$77.id);
    const $t$81 = item$77.label;
    const r$82 = DomSelector$t171();
    const w$83 = r$82.firstChild;
    r$82.setAttribute("class", $t$80);
    w$83.data = $t$81;
    return { s: r$82, q: null, e: r$82, w0: r$82, w1: w$83, a0: $t$80, a1: $t$81 };
  }, p: (i$84, item$85, position$86) => {
    const $t$87 = DomSelector$isOn(model$1.selected, item$85.id);
    if ($t$87 !== i$84.a0) {
      i$84.w0.setAttribute("class", $t$87);
      i$84.a0 = $t$87;
    }
    if (item$85 !== i$84.x) {
      const $t$88 = item$85.label;
      if ($t$88 !== i$84.a1) {
        i$84.a1 = $t$88;
        i$84.w1.data = $t$88;
      }
    }
  }, i: false, f: null, g: 0, z: model$1.selected.$ === "Just" ? model$1.selected.a : model$1.selected }, [model$1.selected]] };
};
export { DomSelector$Msg$$compare, DomSelector$Msg$$eq, DomSelector$table };
