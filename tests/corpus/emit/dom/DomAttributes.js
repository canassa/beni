import { classes as $markup$classes, styles as $markup$styles, safeUrl as $markup$safeUrl } from "./_platform/runtime.foreign.mjs";
import { Rt$template } from "./_platform/Rt.mjs";
const DomAttributes$t27 = Rt$template("<tr class=row style=font-size:12px><td>x", 0);
const DomAttributes$k27 = { m: (v$3, cx$4) => {
  const r$5 = DomAttributes$t27();
  if (v$3[0]) {
    r$5.classList.toggle("danger", true);
  }
  r$5.style.setProperty("color", v$3[1]);
  return { s: r$5, q: null, e: r$5, w0: r$5, a0: v$3[0], a1: v$3[1] };
}, p: (i$6, v$7) => {
  if (v$7[0] !== i$6.a0) {
    i$6.a0 = v$7[0];
    i$6.w0.classList.toggle("danger", v$7[0]);
  }
  if (v$7[1] !== i$6.a1) {
    i$6.a1 = v$7[1];
    i$6.w0.style.setProperty("color", v$7[1]);
  }
} };
const DomAttributes$t48 = Rt$template("<p>x", 0);
const DomAttributes$k48 = { m: (v$10, cx$11) => {
  const r$12 = DomAttributes$t48();
  $markup$classes(r$12, v$10[0], null);
  $markup$styles(r$12, v$10[1], null);
  return { s: r$12, q: null, e: r$12, w0: r$12, a0: v$10[0], a1: v$10[1] };
}, p: (i$13, v$14) => {
  if (v$14[0] !== i$13.a0) {
    $markup$classes(i$13.w0, v$14[0], i$13.a0);
    i$13.a0 = v$14[0];
  }
  if (v$14[1] !== i$13.a1) {
    $markup$styles(i$13.w0, v$14[1], i$13.a1);
    i$13.a1 = v$14[1];
  }
} };
const DomAttributes$t68 = Rt$template("<form><input><a>link</a><b>", 0);
const DomAttributes$k68 = { m: (v$20, cx$21) => {
  const r$22 = DomAttributes$t68();
  const w$23 = r$22.firstChild;
  const w$24 = w$23.nextSibling;
  const w$25 = w$24.nextSibling;
  r$22.setAttribute("action", $markup$safeUrl(v$20[0]));
  w$23.value = v$20[1];
  w$23.checked = v$20[2];
  w$24.setAttribute("href", $markup$safeUrl(v$20[3]));
  w$25.setAttribute("src", $markup$safeUrl(v$20[4]));
  return { s: r$22, q: null, e: r$22, w0: r$22, w1: w$23, w2: w$24, w4: w$25, a0: v$20[0], a1: v$20[1], a2: v$20[2], a3: v$20[3], a4: v$20[4] };
}, p: (i$26, v$27) => {
  if (v$27[0] !== i$26.a0) {
    i$26.w0.setAttribute("action", $markup$safeUrl(v$27[0]));
    i$26.a0 = v$27[0];
  }
  if (i$26.w1.value !== v$27[1]) {
    i$26.w1.value = v$27[1];
  }
  if (i$26.w1.checked !== v$27[2]) {
    i$26.w1.checked = v$27[2];
  }
  if (v$27[3] !== i$26.a3) {
    i$26.w2.setAttribute("href", $markup$safeUrl(v$27[3]));
    i$26.a3 = v$27[3];
  }
  if (v$27[4] !== i$26.a4) {
    i$26.w4.setAttribute("src", $markup$safeUrl(v$27[4]));
    i$26.a4 = v$27[4];
  }
} };
const DomAttributes$inPlace = (r$1) => {
  const $t$1 = r$1.danger;
  const $t$2 = r$1.color;
  return { t: DomAttributes$k27, v: [$t$1, $t$2] };
};
const DomAttributes$lists = (r$1) => {
  const $t$8 = r$1.classes;
  const $t$9 = r$1.styles;
  return { t: DomAttributes$k48, v: [$t$8, $t$9] };
};
const DomAttributes$fields = (r$1) => {
  const $t$15 = r$1.url;
  const $t$16 = r$1.text;
  const $t$17 = r$1.on;
  const $t$18 = r$1.url;
  const $t$19 = r$1.url;
  return { t: DomAttributes$k68, v: [$t$15, $t$16, $t$17, $t$18, $t$19] };
};
export { DomAttributes$inPlace, DomAttributes$lists, DomAttributes$fields };
