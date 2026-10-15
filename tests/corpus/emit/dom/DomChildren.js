import { Rt$template, Rt$childHtml, Rt$restate, Rt$slot, Rt$childMaybe, Rt$childList, Rt$text, Rt$templateOf, Rt$insertText, Rt$map } from "./_platform/Rt.mjs";
import { String$fromInt } from "./_core/String.mjs";
const DomChildren$t9 = Rt$template("<b>on");
const DomChildren$k9 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomChildren$t9();
  return { s: $r$7, q: null, e: $r$7 };
}, p: ($i$8, $v$9) => {
} };
const DomChildren$b9 = { t: DomChildren$k9, v: null };
const DomChildren$t13 = Rt$template("<i>off");
const DomChildren$k13 = { m: ($v$10, $cx$11) => {
  const $r$12 = DomChildren$t13();
  return { s: $r$12, q: null, e: $r$12 };
}, p: ($i$13, $v$14) => {
} };
const DomChildren$b13 = { t: DomChildren$k13, v: null };
const DomChildren$p16 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    const $t$15 = $input$3 ? DomChildren$b9 : DomChildren$b13;
    Rt$childHtml($i$1.c0, $t$15);
  } else {
    Rt$restate($i$1.c0);
  }
  $i$1.l = $i$1.c0.l;
};
const DomChildren$t16 = Rt$template("<div>");
const DomChildren$k16 = { m: ($v$16, $cx$17) => {
  const $r$18 = DomChildren$t16();
  const $c$19 = Rt$slot($r$18, null, $cx$17);
  const $i$20 = { s: $r$18, q: null, e: $r$18, c0: $c$19, g0_0: NaN };
  DomChildren$p16($i$20, $v$16);
  return $i$20;
}, p: DomChildren$p16, l: true };
const DomChildren$p42 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3.one;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    const $t$5 = $input$3.one;
    Rt$childHtml($i$1.c0, $t$5);
  } else {
    Rt$restate($i$1.c0);
  }
  const $x$6 = $input$3.maybe;
  if ($x$6 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$6;
    const $t$7 = $input$3.maybe;
    Rt$childMaybe($i$1.c1, $t$7.a);
  } else {
    Rt$restate($i$1.c1);
  }
  const $x$8 = $input$3.many;
  if ($x$8 !== $i$1.g2_0) {
    $i$1.g2_0 = $x$8;
    const $t$9 = $input$3.many;
    Rt$childList($i$1.c2, $t$9);
  } else {
    Rt$restate($i$1.c2);
  }
  $i$1.l = $i$1.c0.l || $i$1.c1.l || $i$1.c2.w;
};
const DomChildren$t42 = Rt$template("<section><h1>title</h1><!><ul>");
const DomChildren$k42 = { m: ($v$10, $cx$11) => {
  const $r$12 = DomChildren$t42();
  const $w$13 = $r$12.firstChild.nextSibling;
  const $w$14 = $w$13.nextSibling;
  const $c$15 = Rt$slot($r$12, $w$13, $cx$11);
  const $c$16 = Rt$slot($r$12, $w$14, $cx$11);
  const $c$17 = Rt$slot($w$14, null, $cx$11);
  const $i$18 = { s: $r$12, q: null, e: $r$12, c0: $c$15, c1: $c$16, c2: $c$17, g0_0: NaN, g1_0: NaN, g2_0: NaN };
  DomChildren$p42($i$18, $v$10);
  return $i$18;
}, p: DomChildren$p42, l: true };
const DomChildren$p53 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    const $t$5 = Rt$text($input$3);
    $i$1.x0.data = $x$4;
    Rt$childHtml($i$1.c1, $t$5);
  } else {
    Rt$restate($i$1.c1);
  }
  $i$1.l = $i$1.c1.l;
};
const DomChildren$t53 = Rt$templateOf("Hi <hr><!>", 4);
const DomChildren$k53 = { m: ($v$6, $cx$7) => {
  const $r$8 = DomChildren$t53();
  const $w$9 = $r$8.firstChild;
  const $w$10 = $w$9.nextSibling;
  const $w$11 = $w$10.nextSibling;
  const $c$12 = Rt$slot(null, $w$11, $cx$7);
  const $x$13 = Rt$insertText($r$8, $w$10, "");
  const $i$14 = { s: $w$9, q: null, e: $w$11, x0: $x$13, c1: $c$12, g0_0: NaN };
  DomChildren$p53($i$14, $v$6);
  return $i$14;
}, p: DomChildren$p53, l: true };
const DomChildren$p66 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    const $t$5 = Rt$map($input$3, String$fromInt);
    Rt$childHtml($i$1.c0, $t$5);
  } else {
    Rt$restate($i$1.c0);
  }
  $i$1.l = $i$1.c0.l;
};
const DomChildren$t66 = Rt$template("<div>");
const DomChildren$k66 = { m: ($v$6, $cx$7) => {
  const $r$8 = DomChildren$t66();
  const $c$9 = Rt$slot($r$8, null, $cx$7);
  const $i$10 = { s: $r$8, q: null, e: $r$8, c0: $c$9, g0_0: NaN };
  DomChildren$p66($i$10, $v$6);
  return $i$10;
}, p: DomChildren$p66, l: true };
const DomChildren$branch = (on$1) => ({ t: DomChildren$k16, v: [on$1] });
const DomChildren$holes = (r$1) => ({ t: DomChildren$k42, v: [r$1] });
const DomChildren$fragment = (name$1) => ({ t: DomChildren$k53, v: [name$1] });
const DomChildren$mapped = (inner$1) => ({ t: DomChildren$k66, v: [inner$1] });
export { DomChildren$branch, DomChildren$holes, DomChildren$fragment, DomChildren$mapped };
//# sourceMappingURL=DomChildren.mjs.map
