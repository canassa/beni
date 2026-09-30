import { childMaybe as $markup$childMaybe, childList as $markup$childList, text as Html$text, insertText as $markup$insertText, map as Html$map } from "./_platform/runtime.foreign.mjs";
import { Rt$template, Rt$slot, Rt$childHtml } from "./_platform/Rt.mjs";
import { String$fromInt } from "./_core/String.mjs";
const DomChildren$t9 = Rt$template("<b>on", 0);
const DomChildren$k9 = { m: (v$1, cx$2) => {
  const r$3 = DomChildren$t9();
  return { s: r$3, q: null, e: r$3 };
}, p: (i$4, v$5) => {
} };
const DomChildren$b9 = { t: DomChildren$k9, v: null };
const DomChildren$t13 = Rt$template("<i>off", 0);
const DomChildren$k13 = { m: (v$6, cx$7) => {
  const r$8 = DomChildren$t13();
  return { s: r$8, q: null, e: r$8 };
}, p: (i$9, v$10) => {
} };
const DomChildren$b13 = { t: DomChildren$k13, v: null };
const DomChildren$t16 = Rt$template("<div>", 0);
const DomChildren$k16 = { m: (v$12, cx$13) => {
  const r$14 = DomChildren$t16();
  const c$15 = Rt$slot(r$14, null, cx$13);
  Rt$childHtml(c$15, v$12[0]);
  return { s: r$14, q: null, e: r$14, c0: c$15 };
}, p: (i$16, v$17) => {
  Rt$childHtml(i$16.c0, v$17[0]);
} };
const DomChildren$t42 = Rt$template("<section><h1>title</h1><!><ul>", 0);
const DomChildren$k42 = { m: (v$21, cx$22) => {
  const r$23 = DomChildren$t42();
  const w$24 = r$23.firstChild.nextSibling;
  const w$25 = w$24.nextSibling;
  const c$26 = Rt$slot(r$23, w$24, cx$22);
  const c$27 = Rt$slot(r$23, w$25, cx$22);
  const c$28 = Rt$slot(w$25, null, cx$22);
  Rt$childHtml(c$26, v$21[0]);
  $markup$childMaybe(c$27, v$21[1].a);
  $markup$childList(c$28, v$21[2]);
  return { s: r$23, q: null, e: r$23, c0: c$26, c1: c$27, c2: c$28 };
}, p: (i$29, v$30) => {
  Rt$childHtml(i$29.c0, v$30[0]);
  $markup$childMaybe(i$29.c1, v$30[1].a);
  $markup$childList(i$29.c2, v$30[2]);
} };
const DomChildren$t53 = Rt$template("Hi <hr><!>", 4);
const DomChildren$k53 = { m: (v$32, cx$33) => {
  const r$34 = DomChildren$t53();
  const w$35 = r$34.firstChild;
  const w$36 = w$35.nextSibling;
  const w$37 = w$36.nextSibling;
  const c$38 = Rt$slot(null, w$37, cx$33);
  const x$39 = $markup$insertText(r$34, w$36, v$32[0]);
  Rt$childHtml(c$38, v$32[1]);
  return { s: w$35, q: null, e: w$37, x0: x$39, c1: c$38, a0: v$32[0] };
}, p: (i$40, v$41) => {
  if (v$41[0] !== i$40.a0) {
    i$40.a0 = v$41[0];
    i$40.x0.data = v$41[0];
  }
  Rt$childHtml(i$40.c1, v$41[1]);
} };
const DomChildren$t66 = Rt$template("<div>", 0);
const DomChildren$k66 = { m: (v$43, cx$44) => {
  const r$45 = DomChildren$t66();
  const c$46 = Rt$slot(r$45, null, cx$44);
  Rt$childHtml(c$46, v$43[0]);
  return { s: r$45, q: null, e: r$45, c0: c$46 };
}, p: (i$47, v$48) => {
  Rt$childHtml(i$47.c0, v$48[0]);
} };
const DomChildren$branch = (on$1) => {
  const $t$11 = on$1 ? DomChildren$b9 : DomChildren$b13;
  return { t: DomChildren$k16, v: [$t$11] };
};
const DomChildren$holes = (r$1) => {
  const $t$18 = r$1.one;
  const $t$19 = r$1.maybe;
  const $t$20 = r$1.many;
  return { t: DomChildren$k42, v: [$t$18, $t$19, $t$20] };
};
const DomChildren$fragment = (name$1) => {
  const $t$31 = Html$text(name$1);
  return { t: DomChildren$k53, v: [name$1, $t$31] };
};
const DomChildren$mapped = (inner$1) => {
  const $t$42 = Html$map(inner$1, String$fromInt);
  return { t: DomChildren$k66, v: [$t$42] };
};
export { DomChildren$branch, DomChildren$holes, DomChildren$fragment, DomChildren$mapped };
