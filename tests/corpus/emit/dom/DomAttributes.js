import { Rt$template, Rt$classes, Rt$styles, Rt$safeUrl } from "./_platform/Rt.mjs";
const DomAttributes$p27 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if ($in$3.danger !== i$1.g0_0) {
    i$1.g0_0 = $in$3.danger;
    const $t$4 = $in$3.danger;
    if ($t$4 !== i$1.a0) {
      i$1.a0 = $t$4;
      i$1.w0.classList.toggle("danger", $t$4);
    }
  }
  if ($in$3.color !== i$1.g1_0) {
    i$1.g1_0 = $in$3.color;
    const $t$5 = $in$3.color;
    if ($t$5 !== i$1.a1) {
      i$1.a1 = $t$5;
      i$1.w0.style.setProperty("color", $t$5);
    }
  }
};
const DomAttributes$t27 = Rt$template("<tr class=row style=font-size:12px><td>x", 0);
const DomAttributes$k27 = { m: (v$6, cx$7) => {
  const r$8 = DomAttributes$t27();
  const i$9 = { s: r$8, q: null, e: r$8, w0: r$8, a0: false, a1: undefined, g0_0: undefined, g1_0: undefined };
  DomAttributes$p27(i$9, v$6);
  return i$9;
}, p: DomAttributes$p27 };
const DomAttributes$p48 = (i$10, v$11) => {
  const $in$12 = v$11[0];
  if ($in$12.classes !== i$10.g0_0) {
    i$10.g0_0 = $in$12.classes;
    const $t$13 = $in$12.classes;
    if ($t$13 !== i$10.a0) {
      Rt$classes(i$10.w0, $t$13, i$10.a0);
      i$10.a0 = $t$13;
    }
  }
  if ($in$12.styles !== i$10.g1_0) {
    i$10.g1_0 = $in$12.styles;
    const $t$14 = $in$12.styles;
    if ($t$14 !== i$10.a1) {
      Rt$styles(i$10.w0, $t$14, i$10.a1);
      i$10.a1 = $t$14;
    }
  }
};
const DomAttributes$t48 = Rt$template("<p>x", 0);
const DomAttributes$k48 = { m: (v$15, cx$16) => {
  const r$17 = DomAttributes$t48();
  const i$18 = { s: r$17, q: null, e: r$17, w0: r$17, a0: null, a1: null, g0_0: undefined, g1_0: undefined };
  DomAttributes$p48(i$18, v$15);
  return i$18;
}, p: DomAttributes$p48 };
const DomAttributes$p68 = (i$19, v$20) => {
  const $in$21 = v$20[0];
  if ($in$21.url !== i$19.g0_0) {
    i$19.g0_0 = $in$21.url;
    const $t$22 = $in$21.url;
    const $t$23 = $in$21.url;
    const $t$24 = $in$21.url;
    if ($t$22 !== i$19.a0) {
      i$19.w0.setAttribute("action", Rt$safeUrl($t$22));
      i$19.a0 = $t$22;
    }
    if ($t$23 !== i$19.a3) {
      i$19.w2.setAttribute("href", Rt$safeUrl($t$23));
      i$19.a3 = $t$23;
    }
    if ($t$24 !== i$19.a4) {
      i$19.w4.setAttribute("src", Rt$safeUrl($t$24));
      i$19.a4 = $t$24;
    }
  }
  {
    const $t$25 = $in$21.text;
    if (i$19.w1.value !== $t$25) {
      i$19.w1.value = $t$25;
    }
  }
  {
    const $t$26 = $in$21.on;
    if (i$19.w1.checked !== $t$26) {
      i$19.w1.checked = $t$26;
    }
  }
};
const DomAttributes$t68 = Rt$template("<form><input><a>link</a><b>", 0);
const DomAttributes$k68 = { m: (v$27, cx$28) => {
  const r$29 = DomAttributes$t68();
  const w$30 = r$29.firstChild;
  const w$31 = w$30.nextSibling;
  const w$32 = w$31.nextSibling;
  const i$33 = { s: r$29, q: null, e: r$29, w0: r$29, w1: w$30, w2: w$31, w4: w$32, a0: undefined, a3: undefined, a4: undefined, g0_0: undefined };
  DomAttributes$p68(i$33, v$27);
  return i$33;
}, p: DomAttributes$p68 };
const DomAttributes$inPlace = (r$1) => ({ t: DomAttributes$k27, v: [r$1] });
const DomAttributes$lists = (r$1) => ({ t: DomAttributes$k48, v: [r$1] });
const DomAttributes$fields = (r$1) => ({ t: DomAttributes$k68, v: [r$1] });
export { DomAttributes$inPlace, DomAttributes$lists, DomAttributes$fields };
//# sourceMappingURL=DomAttributes.mjs.map
