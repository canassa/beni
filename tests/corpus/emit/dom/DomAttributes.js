import { Rt$template, Rt$classes, Rt$styles, Rt$safeUrl, Rt$control } from "./_platform/Rt.mjs";
const DomAttributes$p27 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  const x$4 = $in$3.danger;
  if (x$4 !== i$1.g0_0) {
    i$1.g0_0 = x$4;
    const $t$5 = $in$3.danger;
    if ($t$5 !== i$1.a0) {
      i$1.a0 = $t$5;
      i$1.w0.classList.toggle("danger", $t$5);
    }
  }
  const x$6 = $in$3.color;
  if (x$6 !== i$1.g1_0) {
    i$1.g1_0 = x$6;
    i$1.w0.style.setProperty("color", x$6);
  }
};
const DomAttributes$t27 = Rt$template("<tr class=row style=font-size:12px><td>x", 0);
const DomAttributes$k27 = { m: (v$7, cx$8) => {
  const r$9 = DomAttributes$t27();
  const i$10 = { s: r$9, q: null, e: r$9, w0: r$9, a0: false, g0_0: NaN, g1_0: NaN };
  DomAttributes$p27(i$10, v$7);
  return i$10;
}, p: DomAttributes$p27 };
const DomAttributes$p48 = (i$11, v$12) => {
  const $in$13 = v$12[0];
  const x$14 = $in$13.classes;
  if (x$14 !== i$11.g0_0) {
    i$11.g0_0 = x$14;
    const $t$15 = $in$13.classes;
    if ($t$15 !== i$11.a0) {
      Rt$classes(i$11.w0, $t$15, i$11.a0);
      i$11.a0 = $t$15;
    }
  }
  const x$16 = $in$13.styles;
  if (x$16 !== i$11.g1_0) {
    i$11.g1_0 = x$16;
    const $t$17 = $in$13.styles;
    if ($t$17 !== i$11.a1) {
      Rt$styles(i$11.w0, $t$17, i$11.a1);
      i$11.a1 = $t$17;
    }
  }
};
const DomAttributes$t48 = Rt$template("<p>x", 0);
const DomAttributes$k48 = { m: (v$18, cx$19) => {
  const r$20 = DomAttributes$t48();
  const i$21 = { s: r$20, q: null, e: r$20, w0: r$20, a0: null, a1: null, g0_0: NaN, g1_0: NaN };
  DomAttributes$p48(i$21, v$18);
  return i$21;
}, p: DomAttributes$p48 };
const DomAttributes$p68 = (i$22, v$23) => {
  const $in$24 = v$23[0];
  const x$25 = $in$24.url;
  if (x$25 !== i$22.g0_0) {
    i$22.g0_0 = x$25;
    i$22.w0.setAttribute("action", Rt$safeUrl(x$25));
    i$22.w2.setAttribute("href", Rt$safeUrl(x$25));
    i$22.w4.setAttribute("src", Rt$safeUrl(x$25));
  }
  const x$26 = $in$24.text;
  if (x$26 !== i$22.g1_0) {
    i$22.g1_0 = x$26;
    const $t$27 = $in$24.text;
    Rt$control(i$22.w1, "value", $t$27);
  }
  const x$28 = $in$24.on;
  if (x$28 !== i$22.g2_0) {
    i$22.g2_0 = x$28;
    const $t$29 = $in$24.on;
    Rt$control(i$22.w1, "checked", $t$29);
  }
};
const DomAttributes$t68 = Rt$template("<form><input><a>link</a><b>", 0);
const DomAttributes$k68 = { m: (v$30, cx$31) => {
  const r$32 = DomAttributes$t68();
  const w$33 = r$32.firstChild;
  const w$34 = w$33.nextSibling;
  const w$35 = w$34.nextSibling;
  const i$36 = { s: r$32, q: null, e: r$32, w0: r$32, w1: w$33, w2: w$34, w4: w$35, g0_0: NaN, g1_0: NaN, g2_0: NaN };
  DomAttributes$p68(i$36, v$30);
  return i$36;
}, p: DomAttributes$p68 };
const DomAttributes$inPlace = (r$1) => ({ t: DomAttributes$k27, v: [r$1] });
const DomAttributes$lists = (r$1) => ({ t: DomAttributes$k48, v: [r$1] });
const DomAttributes$fields = (r$1) => ({ t: DomAttributes$k68, v: [r$1] });
export { DomAttributes$inPlace, DomAttributes$lists, DomAttributes$fields };
//# sourceMappingURL=DomAttributes.mjs.map
