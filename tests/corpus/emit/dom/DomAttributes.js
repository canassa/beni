import { Rt$template, Rt$classes, Rt$styles, Rt$safeUrl, Rt$control } from "./_platform/Rt.mjs";
const DomAttributes$p27 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3.danger;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    const $t$5 = $input$3.danger;
    if ($t$5 !== $i$1.a0) {
      $i$1.a0 = $t$5;
      $i$1.w0.classList.toggle("danger", $t$5);
    }
  }
  const $x$6 = $input$3.color;
  if ($x$6 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$6;
    $i$1.w0.style.setProperty("color", $x$6);
  }
};
const DomAttributes$t27 = Rt$template("<tr class=row style=font-size:12px><td>x");
const DomAttributes$k27 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomAttributes$t27();
  const $i$10 = { s: $r$9, q: null, e: $r$9, w0: $r$9, a0: false, g0_0: NaN, g1_0: NaN };
  DomAttributes$p27($i$10, $v$7);
  return $i$10;
}, p: DomAttributes$p27 };
const DomAttributes$p48 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3.classes;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    const $t$5 = $input$3.classes;
    if ($t$5 !== $i$1.a0) {
      Rt$classes($i$1.w0, $t$5, $i$1.a0);
      $i$1.a0 = $t$5;
    }
  }
  const $x$6 = $input$3.styles;
  if ($x$6 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$6;
    const $t$7 = $input$3.styles;
    if ($t$7 !== $i$1.a1) {
      Rt$styles($i$1.w0, $t$7, $i$1.a1);
      $i$1.a1 = $t$7;
    }
  }
};
const DomAttributes$t48 = Rt$template("<p>x");
const DomAttributes$k48 = { m: ($v$8, $cx$9) => {
  const $r$10 = DomAttributes$t48();
  const $i$11 = { s: $r$10, q: null, e: $r$10, w0: $r$10, a0: null, a1: null, g0_0: NaN, g1_0: NaN };
  DomAttributes$p48($i$11, $v$8);
  return $i$11;
}, p: DomAttributes$p48 };
const DomAttributes$p68 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3.url;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.w0.setAttribute("action", Rt$safeUrl($x$4));
    $i$1.w2.setAttribute("href", Rt$safeUrl($x$4));
    $i$1.w4.setAttribute("src", Rt$safeUrl($x$4));
  }
  const $x$5 = $input$3.text;
  if ($x$5 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$5;
    const $t$6 = $input$3.text;
    Rt$control($i$1.w1, "value", $t$6);
  }
  const $x$7 = $input$3.on;
  if ($x$7 !== $i$1.g2_0) {
    $i$1.g2_0 = $x$7;
    const $t$8 = $input$3.on;
    Rt$control($i$1.w1, "checked", $t$8);
  }
};
const DomAttributes$t68 = Rt$template("<form><input><a>link</a><b>");
const DomAttributes$k68 = { m: ($v$9, $cx$10) => {
  const $r$11 = DomAttributes$t68();
  const $w$12 = $r$11.firstChild;
  const $w$13 = $w$12.nextSibling;
  const $w$14 = $w$13.nextSibling;
  const $i$15 = { s: $r$11, q: null, e: $r$11, w0: $r$11, w1: $w$12, w2: $w$13, w4: $w$14, g0_0: NaN, g1_0: NaN, g2_0: NaN };
  DomAttributes$p68($i$15, $v$9);
  return $i$15;
}, p: DomAttributes$p68 };
const DomAttributes$inPlace = (r$1) => ({ t: DomAttributes$k27, v: [r$1] });
const DomAttributes$lists = (r$1) => ({ t: DomAttributes$k48, v: [r$1] });
const DomAttributes$fields = (r$1) => ({ t: DomAttributes$k68, v: [r$1] });
export { DomAttributes$inPlace, DomAttributes$lists, DomAttributes$fields };
//# sourceMappingURL=DomAttributes.mjs.map
