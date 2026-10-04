import { Rt$template, Rt$childHtml, Rt$slot, Rt$childMaybe, Rt$childList, Rt$text, Rt$insertText, Rt$map } from "./_platform/Rt.mjs";
import { String$fromInt } from "./_core/String.mjs";
const DomChildren$t9 = Rt$template("<b>on", 0);
const DomChildren$k9 = { m: (v$5, cx$6) => {
  const r$7 = DomChildren$t9();
  return { s: r$7, q: null, e: r$7 };
}, p: (i$8, v$9) => {
} };
const DomChildren$b9 = { t: DomChildren$k9, v: null };
const DomChildren$t13 = Rt$template("<i>off", 0);
const DomChildren$k13 = { m: (v$10, cx$11) => {
  const r$12 = DomChildren$t13();
  return { s: r$12, q: null, e: r$12 };
}, p: (i$13, v$14) => {
} };
const DomChildren$b13 = { t: DomChildren$k13, v: null };
const DomChildren$p16 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  const x$4 = $in$3;
  if (x$4 !== i$1.g0_0) {
    i$1.g0_0 = x$4;
    const $t$15 = $in$3 ? DomChildren$b9 : DomChildren$b13;
    Rt$childHtml(i$1.c0, $t$15);
  }
};
const DomChildren$t16 = Rt$template("<div>", 0);
const DomChildren$k16 = { m: (v$16, cx$17) => {
  const r$18 = DomChildren$t16();
  const c$19 = Rt$slot(r$18, null, cx$17);
  const i$20 = { s: r$18, q: null, e: r$18, c0: c$19, g0_0: undefined };
  DomChildren$p16(i$20, v$16);
  return i$20;
}, p: DomChildren$p16 };
const DomChildren$p42 = (i$21, v$22) => {
  const $in$23 = v$22[0];
  const x$24 = $in$23.one;
  if (x$24 !== i$21.g0_0) {
    i$21.g0_0 = x$24;
    const $t$25 = $in$23.one;
    Rt$childHtml(i$21.c0, $t$25);
  }
  const x$26 = $in$23.maybe;
  if (x$26 !== i$21.g1_0) {
    i$21.g1_0 = x$26;
    const $t$27 = $in$23.maybe;
    Rt$childMaybe(i$21.c1, $t$27.a);
  }
  const x$28 = $in$23.many;
  if (x$28 !== i$21.g2_0) {
    i$21.g2_0 = x$28;
    const $t$29 = $in$23.many;
    Rt$childList(i$21.c2, $t$29);
  }
};
const DomChildren$t42 = Rt$template("<section><h1>title</h1><!><ul>", 0);
const DomChildren$k42 = { m: (v$30, cx$31) => {
  const r$32 = DomChildren$t42();
  const w$33 = r$32.firstChild.nextSibling;
  const w$34 = w$33.nextSibling;
  const c$35 = Rt$slot(r$32, w$33, cx$31);
  const c$36 = Rt$slot(r$32, w$34, cx$31);
  const c$37 = Rt$slot(w$34, null, cx$31);
  const i$38 = { s: r$32, q: null, e: r$32, c0: c$35, c1: c$36, c2: c$37, g0_0: undefined, g1_0: undefined, g2_0: undefined };
  DomChildren$p42(i$38, v$30);
  return i$38;
}, p: DomChildren$p42 };
const DomChildren$p53 = (i$39, v$40) => {
  const $in$41 = v$40[0];
  const x$42 = $in$41;
  if (x$42 !== i$39.g0_0) {
    i$39.g0_0 = x$42;
    const $t$43 = Rt$text($in$41);
    i$39.x0.data = x$42;
    Rt$childHtml(i$39.c1, $t$43);
  }
};
const DomChildren$t53 = Rt$template("Hi <hr><!>", 4);
const DomChildren$k53 = { m: (v$44, cx$45) => {
  const r$46 = DomChildren$t53();
  const w$47 = r$46.firstChild;
  const w$48 = w$47.nextSibling;
  const w$49 = w$48.nextSibling;
  const c$50 = Rt$slot(null, w$49, cx$45);
  const x$51 = Rt$insertText(r$46, w$48, "");
  const i$52 = { s: w$47, q: null, e: w$49, x0: x$51, c1: c$50, g0_0: undefined };
  DomChildren$p53(i$52, v$44);
  return i$52;
}, p: DomChildren$p53 };
const DomChildren$p66 = (i$53, v$54) => {
  const $in$55 = v$54[0];
  const x$56 = $in$55;
  if (x$56 !== i$53.g0_0) {
    i$53.g0_0 = x$56;
    const $t$57 = Rt$map($in$55, String$fromInt);
    Rt$childHtml(i$53.c0, $t$57);
  }
};
const DomChildren$t66 = Rt$template("<div>", 0);
const DomChildren$k66 = { m: (v$58, cx$59) => {
  const r$60 = DomChildren$t66();
  const c$61 = Rt$slot(r$60, null, cx$59);
  const i$62 = { s: r$60, q: null, e: r$60, c0: c$61, g0_0: undefined };
  DomChildren$p66(i$62, v$58);
  return i$62;
}, p: DomChildren$p66 };
const DomChildren$branch = (on$1) => ({ t: DomChildren$k16, v: [on$1] });
const DomChildren$holes = (r$1) => ({ t: DomChildren$k42, v: [r$1] });
const DomChildren$fragment = (name$1) => ({ t: DomChildren$k53, v: [name$1] });
const DomChildren$mapped = (inner$1) => ({ t: DomChildren$k66, v: [inner$1] });
export { DomChildren$branch, DomChildren$holes, DomChildren$fragment, DomChildren$mapped };
//# sourceMappingURL=DomChildren.mjs.map
