import { Rt$template, Rt$classes, Rt$styles, Rt$safeUrl } from "./_platform/Rt.mjs";
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
  const i$10 = { s: r$9, q: null, e: r$9, w0: r$9, a0: false, g0_0: undefined, g1_0: undefined };
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
  const i$21 = { s: r$20, q: null, e: r$20, w0: r$20, a0: null, a1: null, g0_0: undefined, g1_0: undefined };
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
  {
    const $t$26 = $in$24.text;
    if (i$22.w1.value !== $t$26) {
      i$22.w1.value = $t$26;
    }
  }
  {
    const $t$27 = $in$24.on;
    if (i$22.w1.checked !== $t$27) {
      i$22.w1.checked = $t$27;
    }
  }
};
const DomAttributes$t68 = Rt$template("<form><input><a>link</a><b>", 0);
const DomAttributes$k68 = { m: (v$28, cx$29) => {
  const r$30 = DomAttributes$t68();
  const w$31 = r$30.firstChild;
  const w$32 = w$31.nextSibling;
  const w$33 = w$32.nextSibling;
  const i$34 = { s: r$30, q: null, e: r$30, w0: r$30, w1: w$31, w2: w$32, w4: w$33, g0_0: undefined };
  DomAttributes$p68(i$34, v$28);
  return i$34;
}, p: DomAttributes$p68 };
const DomAttributes$inPlace = (r$1) => ({ t: DomAttributes$k27, v: [r$1] });
const DomAttributes$lists = (r$1) => ({ t: DomAttributes$k48, v: [r$1] });
const DomAttributes$fields = (r$1) => ({ t: DomAttributes$k68, v: [r$1] });
export { DomAttributes$inPlace, DomAttributes$lists, DomAttributes$fields };
//# sourceMappingURL=DomAttributes.mjs.map
