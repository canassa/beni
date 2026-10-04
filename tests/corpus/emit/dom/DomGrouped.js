import { String$fromInt, String$toUpper } from "./_core/String.mjs";
import { Rt$template } from "./_platform/Rt.mjs";
const DomGrouped$p21 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if ($in$3.name !== i$1.g0_0) {
    i$1.g0_0 = $in$3.name;
    const $t$4 = $in$3.name;
    const $t$5 = $in$3.name;
    if ($t$4 !== i$1.a0) {
      i$1.w0.setAttribute("class", $t$4);
      i$1.a0 = $t$4;
    }
    if ($t$5 !== i$1.a3) {
      i$1.a3 = $t$5;
      i$1.w4.data = $t$5;
    }
  }
  if (i$1.g1 === undefined) {
    i$1.g1 = true;
    const $t$6 = String$fromInt(7);
    if ($t$6 !== i$1.a1) {
      i$1.w1.setAttribute("title", $t$6);
      i$1.a1 = $t$6;
    }
  }
  if ($in$3.count !== i$1.g2_0) {
    i$1.g2_0 = $in$3.count;
    const $t$7 = $in$3.count;
    if ($t$7 !== i$1.a2) {
      i$1.a2 = $t$7;
      i$1.w2.data = $t$7;
    }
  }
  {
    const $t$8 = $in$3.text;
    if (i$1.w5.value !== $t$8) {
      i$1.w5.value = $t$8;
    }
  }
};
const DomGrouped$t21 = Rt$template("<div><p> </p><b> </b><input>", 0);
const DomGrouped$k21 = { m: (v$9, cx$10) => {
  const r$11 = DomGrouped$t21();
  const w$12 = r$11.firstChild;
  const w$13 = w$12.firstChild;
  const w$14 = w$12.nextSibling;
  const w$15 = w$14.firstChild;
  const w$16 = w$14.nextSibling;
  const i$17 = { s: r$11, q: null, e: r$11, w0: r$11, w1: w$12, w2: w$13, w4: w$15, w5: w$16, a0: undefined, a1: undefined, a2: undefined, a3: undefined, g0_0: undefined, g1: undefined, g2_0: undefined };
  DomGrouped$p21(i$17, v$9);
  return i$17;
}, p: DomGrouped$p21 };
const DomGrouped$p36 = (i$18, v$19) => {
  const $in$20 = v$19[0];
  if ($in$20.name !== i$18.g0_0 || $in$20.count !== i$18.g0_1) {
    i$18.g0_0 = $in$20.name;
    i$18.g0_1 = $in$20.count;
    const $t$21 = $in$20.name;
    const $t$22 = String$fromInt($in$20.count);
    const $t$23 = $in$20.name;
    if ($t$21 !== i$18.a0) {
      i$18.w0.setAttribute("class", $t$21);
      i$18.a0 = $t$21;
    }
    if ($t$22 !== i$18.a1) {
      i$18.w1.setAttribute("title", $t$22);
      i$18.a1 = $t$22;
    }
    if ($t$23 !== i$18.a2) {
      i$18.w1.setAttribute("class", $t$23);
      i$18.a2 = $t$23;
    }
  }
};
const DomGrouped$t36 = Rt$template("<div><span>x", 0);
const DomGrouped$k36 = { m: (v$24, cx$25) => {
  const r$26 = DomGrouped$t36();
  const w$27 = r$26.firstChild;
  const i$28 = { s: r$26, q: null, e: r$26, w0: r$26, w1: w$27, a0: undefined, a1: undefined, a2: undefined, g0_0: undefined, g0_1: undefined };
  DomGrouped$p36(i$28, v$24);
  return i$28;
}, p: DomGrouped$p36 };
const DomGrouped$p50 = (i$29, v$30) => {
  const $in$31 = v$30[0];
  if ($in$31.name !== i$29.l0_0) {
    i$29.l0_0 = $in$31.name;
    const $t$32 = String$toUpper($in$31.name);
    i$29.d0 = $t$32;
  }
  const $let$33 = i$29.d0;
  if ($in$31.name !== i$29.g0_0) {
    i$29.g0_0 = $in$31.name;
    if ($let$33 !== i$29.a0) {
      i$29.w0.setAttribute("title", $let$33);
      i$29.a0 = $let$33;
    }
    if ($let$33 !== i$29.a1) {
      i$29.a1 = $let$33;
      i$29.w1.data = $let$33;
    }
  }
};
const DomGrouped$t50 = Rt$template("<p> ", 0);
const DomGrouped$k50 = { m: (v$34, cx$35) => {
  const r$36 = DomGrouped$t50();
  const w$37 = r$36.firstChild;
  const i$38 = { s: r$36, q: null, e: r$36, w0: r$36, w1: w$37, a0: undefined, a1: undefined, l0_0: undefined, d0: undefined, g0_0: undefined };
  DomGrouped$p50(i$38, v$34);
  return i$38;
}, p: DomGrouped$p50 };
const DomGrouped$view = (model$1) => ({ t: DomGrouped$k21, v: [model$1] });
const DomGrouped$ordered = (model$1) => ({ t: DomGrouped$k36, v: [model$1] });
const DomGrouped$shouted = (model$1) => ({ t: DomGrouped$k50, v: [model$1] });
export { DomGrouped$view, DomGrouped$ordered, DomGrouped$shouted };
//# sourceMappingURL=DomGrouped.mjs.map
