import { String$fromInt, String$toUpper } from "./_core/String.mjs";
import { Rt$control, Rt$template } from "./_platform/Rt.mjs";
const DomGrouped$p21 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  const $x$4 = $input$3.name;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.w0.setAttribute("class", $x$4);
    $i$1.w4.data = $x$4;
  }
  if ($i$1.g1 === undefined) {
    $i$1.g1 = true;
    const $t$5 = String$fromInt(7);
    if ($t$5 !== $i$1.a1) {
      $i$1.w1.setAttribute("title", $t$5);
      $i$1.a1 = $t$5;
    }
  }
  const $x$6 = $input$3.count;
  if ($x$6 !== $i$1.g2_0) {
    $i$1.g2_0 = $x$6;
    $i$1.w2.data = $x$6;
  }
  const $x$7 = $input$3.text;
  if ($x$7 !== $i$1.g3_0) {
    $i$1.g3_0 = $x$7;
    const $t$8 = $input$3.text;
    Rt$control($i$1.w5, "value", $t$8, true);
  }
};
const DomGrouped$t21 = Rt$template("<div><p> </p><b> </b><input>");
const DomGrouped$k21 = { m: ($v$9, $cx$10) => {
  const $r$11 = DomGrouped$t21();
  const $w$12 = $r$11.firstChild;
  const $w$13 = $w$12.firstChild;
  const $w$14 = $w$12.nextSibling;
  const $w$15 = $w$14.firstChild;
  const $w$16 = $w$14.nextSibling;
  const $i$17 = { s: $r$11, q: null, e: $r$11, w0: $r$11, w1: $w$12, w2: $w$13, w4: $w$15, w5: $w$16, a1: undefined, g0_0: NaN, g1: undefined, g2_0: NaN, g3_0: NaN };
  DomGrouped$p21($i$17, $v$9);
  return $i$17;
}, p: DomGrouped$p21 };
const DomGrouped$p36 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  if ($input$3.name !== $i$1.g0_0 || $input$3.count !== $i$1.g0_1) {
    $i$1.g0_0 = $input$3.name;
    $i$1.g0_1 = $input$3.count;
    const $t$4 = $input$3.name;
    const $t$5 = String$fromInt($input$3.count);
    const $t$6 = $input$3.name;
    if ($t$4 !== $i$1.a0) {
      $i$1.w0.setAttribute("class", $t$4);
      $i$1.a0 = $t$4;
    }
    if ($t$5 !== $i$1.a1) {
      $i$1.w1.setAttribute("title", $t$5);
      $i$1.a1 = $t$5;
    }
    if ($t$6 !== $i$1.a2) {
      $i$1.w1.setAttribute("class", $t$6);
      $i$1.a2 = $t$6;
    }
  }
};
const DomGrouped$t36 = Rt$template("<div><span>x");
const DomGrouped$k36 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomGrouped$t36();
  const $w$10 = $r$9.firstChild;
  const $i$11 = { s: $r$9, q: null, e: $r$9, w0: $r$9, w1: $w$10, a0: undefined, a1: undefined, a2: undefined, g0_0: NaN, g0_1: NaN };
  DomGrouped$p36($i$11, $v$7);
  return $i$11;
}, p: DomGrouped$p36 };
const DomGrouped$p50 = ($i$1, $v$2) => {
  const $input$3 = $v$2[0];
  if ($input$3.name !== $i$1.l0_0) {
    $i$1.l0_0 = $input$3.name;
    const $t$4 = String$toUpper($input$3.name);
    $i$1.d0 = $t$4;
  }
  const $let$5 = $i$1.d0;
  const $x$6 = $input$3.name;
  if ($x$6 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$6;
    if ($let$5 !== $i$1.a0) {
      $i$1.w0.setAttribute("title", $let$5);
      $i$1.a0 = $let$5;
    }
    if ($let$5 !== $i$1.a1) {
      $i$1.a1 = $let$5;
      $i$1.w1.data = $let$5;
    }
  }
};
const DomGrouped$t50 = Rt$template("<p> ");
const DomGrouped$k50 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomGrouped$t50();
  const $w$10 = $r$9.firstChild;
  const $i$11 = { s: $r$9, q: null, e: $r$9, w0: $r$9, w1: $w$10, a0: undefined, a1: undefined, l0_0: NaN, d0: undefined, g0_0: NaN };
  DomGrouped$p50($i$11, $v$7);
  return $i$11;
}, p: DomGrouped$p50 };
const DomGrouped$view = (model$1) => ({ t: DomGrouped$k21, v: [model$1] });
const DomGrouped$ordered = (model$1) => ({ t: DomGrouped$k36, v: [model$1] });
const DomGrouped$shouted = (model$1) => ({ t: DomGrouped$k50, v: [model$1] });
export { DomGrouped$view, DomGrouped$ordered, DomGrouped$shouted };
//# sourceMappingURL=DomGrouped.mjs.map
