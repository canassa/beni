import { String$fromInt, String$toUpper } from "./_core/String.mjs";
import { Rt$template } from "./_platform/Rt.mjs";
const DomGrouped$p21 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  const x$4 = $in$3.name;
  if (x$4 !== i$1.g0_0) {
    i$1.g0_0 = x$4;
    i$1.w0.setAttribute("class", x$4);
    i$1.w4.data = x$4;
  }
  if (i$1.g1 === undefined) {
    i$1.g1 = true;
    const $t$5 = String$fromInt(7);
    if ($t$5 !== i$1.a1) {
      i$1.w1.setAttribute("title", $t$5);
      i$1.a1 = $t$5;
    }
  }
  const x$6 = $in$3.count;
  if (x$6 !== i$1.g2_0) {
    i$1.g2_0 = x$6;
    i$1.w2.data = x$6;
  }
  {
    const $t$7 = $in$3.text;
    if (i$1.w5.value !== $t$7) {
      i$1.w5.value = $t$7;
    }
  }
};
const DomGrouped$t21 = Rt$template("<div><p> </p><b> </b><input>", 0);
const DomGrouped$k21 = { m: (v$8, cx$9) => {
  const r$10 = DomGrouped$t21();
  const w$11 = r$10.firstChild;
  const w$12 = w$11.firstChild;
  const w$13 = w$11.nextSibling;
  const w$14 = w$13.firstChild;
  const w$15 = w$13.nextSibling;
  const i$16 = { s: r$10, q: null, e: r$10, w0: r$10, w1: w$11, w2: w$12, w4: w$14, w5: w$15, a1: undefined, g0_0: NaN, g1: undefined, g2_0: NaN, l: true };
  DomGrouped$p21(i$16, v$8);
  return i$16;
}, p: DomGrouped$p21, l: true };
const DomGrouped$p36 = (i$17, v$18) => {
  const $in$19 = v$18[0];
  if ($in$19.name !== i$17.g0_0 || $in$19.count !== i$17.g0_1) {
    i$17.g0_0 = $in$19.name;
    i$17.g0_1 = $in$19.count;
    const $t$20 = $in$19.name;
    const $t$21 = String$fromInt($in$19.count);
    const $t$22 = $in$19.name;
    if ($t$20 !== i$17.a0) {
      i$17.w0.setAttribute("class", $t$20);
      i$17.a0 = $t$20;
    }
    if ($t$21 !== i$17.a1) {
      i$17.w1.setAttribute("title", $t$21);
      i$17.a1 = $t$21;
    }
    if ($t$22 !== i$17.a2) {
      i$17.w1.setAttribute("class", $t$22);
      i$17.a2 = $t$22;
    }
  }
};
const DomGrouped$t36 = Rt$template("<div><span>x", 0);
const DomGrouped$k36 = { m: (v$23, cx$24) => {
  const r$25 = DomGrouped$t36();
  const w$26 = r$25.firstChild;
  const i$27 = { s: r$25, q: null, e: r$25, w0: r$25, w1: w$26, a0: undefined, a1: undefined, a2: undefined, g0_0: NaN, g0_1: NaN };
  DomGrouped$p36(i$27, v$23);
  return i$27;
}, p: DomGrouped$p36 };
const DomGrouped$p50 = (i$28, v$29) => {
  const $in$30 = v$29[0];
  if ($in$30.name !== i$28.l0_0) {
    i$28.l0_0 = $in$30.name;
    const $t$31 = String$toUpper($in$30.name);
    i$28.d0 = $t$31;
  }
  const $let$32 = i$28.d0;
  const x$33 = $in$30.name;
  if (x$33 !== i$28.g0_0) {
    i$28.g0_0 = x$33;
    if ($let$32 !== i$28.a0) {
      i$28.w0.setAttribute("title", $let$32);
      i$28.a0 = $let$32;
    }
    if ($let$32 !== i$28.a1) {
      i$28.a1 = $let$32;
      i$28.w1.data = $let$32;
    }
  }
};
const DomGrouped$t50 = Rt$template("<p> ", 0);
const DomGrouped$k50 = { m: (v$34, cx$35) => {
  const r$36 = DomGrouped$t50();
  const w$37 = r$36.firstChild;
  const i$38 = { s: r$36, q: null, e: r$36, w0: r$36, w1: w$37, a0: undefined, a1: undefined, l0_0: NaN, d0: undefined, g0_0: NaN };
  DomGrouped$p50(i$38, v$34);
  return i$38;
}, p: DomGrouped$p50 };
const DomGrouped$view = (model$1) => ({ t: DomGrouped$k21, v: [model$1] });
const DomGrouped$ordered = (model$1) => ({ t: DomGrouped$k36, v: [model$1] });
const DomGrouped$shouted = (model$1) => ({ t: DomGrouped$k50, v: [model$1] });
export { DomGrouped$view, DomGrouped$ordered, DomGrouped$shouted };
//# sourceMappingURL=DomGrouped.mjs.map
