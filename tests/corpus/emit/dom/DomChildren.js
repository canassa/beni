import { Rt$template, Rt$childHtml, Rt$slot, Rt$childMaybe, Rt$childList, Rt$text, Rt$insertText, Rt$map } from "./_platform/Rt.mjs";
import { String$fromInt } from "./_core/String.mjs";
const DomChildren$t9 = Rt$template("<b>on", 0);
const DomChildren$k9 = { m: (v$4, cx$5) => {
  const r$6 = DomChildren$t9();
  return { s: r$6, q: null, e: r$6 };
}, p: (i$7, v$8) => {
} };
const DomChildren$b9 = { t: DomChildren$k9, v: null };
const DomChildren$t13 = Rt$template("<i>off", 0);
const DomChildren$k13 = { m: (v$9, cx$10) => {
  const r$11 = DomChildren$t13();
  return { s: r$11, q: null, e: r$11 };
}, p: (i$12, v$13) => {
} };
const DomChildren$b13 = { t: DomChildren$k13, v: null };
const DomChildren$p16 = (i$1, v$2) => {
  const $in$3 = v$2[0];
  if ($in$3 !== i$1.g0_0) {
    i$1.g0_0 = $in$3;
    const $t$14 = $in$3 ? DomChildren$b9 : DomChildren$b13;
    Rt$childHtml(i$1.c0, $t$14);
  }
};
const DomChildren$t16 = Rt$template("<div>", 0);
const DomChildren$k16 = { m: (v$15, cx$16) => {
  const r$17 = DomChildren$t16();
  const c$18 = Rt$slot(r$17, null, cx$16);
  const i$19 = { s: r$17, q: null, e: r$17, c0: c$18, g0_0: undefined };
  DomChildren$p16(i$19, v$15);
  return i$19;
}, p: DomChildren$p16 };
const DomChildren$p42 = (i$20, v$21) => {
  const $in$22 = v$21[0];
  if ($in$22.one !== i$20.g0_0) {
    i$20.g0_0 = $in$22.one;
    const $t$23 = $in$22.one;
    Rt$childHtml(i$20.c0, $t$23);
  }
  if ($in$22.maybe !== i$20.g1_0) {
    i$20.g1_0 = $in$22.maybe;
    const $t$24 = $in$22.maybe;
    Rt$childMaybe(i$20.c1, $t$24.a);
  }
  if ($in$22.many !== i$20.g2_0) {
    i$20.g2_0 = $in$22.many;
    const $t$25 = $in$22.many;
    Rt$childList(i$20.c2, $t$25);
  }
};
const DomChildren$t42 = Rt$template("<section><h1>title</h1><!><ul>", 0);
const DomChildren$k42 = { m: (v$26, cx$27) => {
  const r$28 = DomChildren$t42();
  const w$29 = r$28.firstChild.nextSibling;
  const w$30 = w$29.nextSibling;
  const c$31 = Rt$slot(r$28, w$29, cx$27);
  const c$32 = Rt$slot(r$28, w$30, cx$27);
  const c$33 = Rt$slot(w$30, null, cx$27);
  const i$34 = { s: r$28, q: null, e: r$28, c0: c$31, c1: c$32, c2: c$33, g0_0: undefined, g1_0: undefined, g2_0: undefined };
  DomChildren$p42(i$34, v$26);
  return i$34;
}, p: DomChildren$p42 };
const DomChildren$p53 = (i$35, v$36) => {
  const $in$37 = v$36[0];
  if ($in$37 !== i$35.g0_0) {
    i$35.g0_0 = $in$37;
    const $t$38 = Rt$text($in$37);
    if ($in$37 !== i$35.a0) {
      i$35.a0 = $in$37;
      i$35.x0.data = $in$37;
    }
    Rt$childHtml(i$35.c1, $t$38);
  }
};
const DomChildren$t53 = Rt$template("Hi <hr><!>", 4);
const DomChildren$k53 = { m: (v$39, cx$40) => {
  const r$41 = DomChildren$t53();
  const w$42 = r$41.firstChild;
  const w$43 = w$42.nextSibling;
  const w$44 = w$43.nextSibling;
  const c$45 = Rt$slot(null, w$44, cx$40);
  const x$46 = Rt$insertText(r$41, w$43, "");
  const i$47 = { s: w$42, q: null, e: w$44, x0: x$46, c1: c$45, a0: undefined, g0_0: undefined };
  DomChildren$p53(i$47, v$39);
  return i$47;
}, p: DomChildren$p53 };
const DomChildren$p66 = (i$48, v$49) => {
  const $in$50 = v$49[0];
  if ($in$50 !== i$48.g0_0) {
    i$48.g0_0 = $in$50;
    const $t$51 = Rt$map($in$50, String$fromInt);
    Rt$childHtml(i$48.c0, $t$51);
  }
};
const DomChildren$t66 = Rt$template("<div>", 0);
const DomChildren$k66 = { m: (v$52, cx$53) => {
  const r$54 = DomChildren$t66();
  const c$55 = Rt$slot(r$54, null, cx$53);
  const i$56 = { s: r$54, q: null, e: r$54, c0: c$55, g0_0: undefined };
  DomChildren$p66(i$56, v$52);
  return i$56;
}, p: DomChildren$p66 };
const DomChildren$branch = (on$1) => ({ t: DomChildren$k16, v: [on$1] });
const DomChildren$holes = (r$1) => ({ t: DomChildren$k42, v: [r$1] });
const DomChildren$fragment = (name$1) => ({ t: DomChildren$k53, v: [name$1] });
const DomChildren$mapped = (inner$1) => ({ t: DomChildren$k66, v: [inner$1] });
export { DomChildren$branch, DomChildren$holes, DomChildren$fragment, DomChildren$mapped };
//# sourceMappingURL=DomChildren.mjs.map
