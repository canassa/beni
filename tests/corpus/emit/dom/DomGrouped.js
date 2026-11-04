import { String$fromInt, String$toUpper } from "./_core/String.mjs";
import { Rt$control, Rt$template, Rt$empty } from "./_platform/Rt.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
function DomGrouped$domProperty_76616c7565_0_get($propertyNode$9) {
  return $propertyNode$9.value;
}
function DomGrouped$domProperty_76616c7565_0_set($propertyNode$9, $propertyValue$10) {
  $propertyNode$9.value = $propertyValue$10;
}
const DomGrouped$domProperty_76616c7565_0 = { name: "value", immutable: true, get: DomGrouped$domProperty_76616c7565_0_get, set: DomGrouped$domProperty_76616c7565_0_set };
const DomGrouped$p21 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
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
    Rt$control($i$1.w5, DomGrouped$domProperty_76616c7565_0, $t$8);
  }
};
const DomGrouped$t21 = Rt$template("<div><p> </p><b> </b><input>");
const DomGrouped$k21 = { m: ($v$11, $cx$12) => {
  const $r$13 = DomGrouped$t21();
  const $w$14 = $r$13.firstChild;
  const $w$15 = $w$14.firstChild;
  const $w$16 = $w$14.nextSibling;
  const $w$17 = $w$16.firstChild;
  const $w$18 = $w$16.nextSibling;
  const $i$19 = { s: $r$13, q: Rt$empty, e: $r$13, w0: $r$13, w1: $w$14, w2: $w$15, w4: $w$17, w5: $w$18, a1: undefined, g0_0: NaN, g1: undefined, g2_0: NaN, g3_0: NaN };
  DomGrouped$p21($i$19, $v$11);
  return $i$19;
}, p: DomGrouped$p21 };
const DomGrouped$p36 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
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
  const $i$11 = { s: $r$9, q: Rt$empty, e: $r$9, w0: $r$9, w1: $w$10, a0: undefined, a1: undefined, a2: undefined, g0_0: NaN, g0_1: NaN };
  DomGrouped$p36($i$11, $v$7);
  return $i$11;
}, p: DomGrouped$p36 };
const DomGrouped$p50 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
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
  const $i$11 = { s: $r$9, q: Rt$empty, e: $r$9, w0: $r$9, w1: $w$10, a0: undefined, a1: undefined, l0_0: NaN, d0: undefined, g0_0: NaN };
  DomGrouped$p50($i$11, $v$7);
  return $i$11;
}, p: DomGrouped$p50 };
const DomGrouped$view$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{count=core:Basics.Int,name=core:String.String,text=core:String.String}" + ")", a: undefined };
const DomGrouped$view = (model$1) => ({ t: DomGrouped$k21, v: { ...DomGrouped$view$$packet$1, a: model$1 } });
const DomGrouped$ordered$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{count=core:Basics.Int,name=core:String.String,text=core:String.String}" + ")", a: undefined };
const DomGrouped$ordered = (model$1) => ({ t: DomGrouped$k36, v: { ...DomGrouped$ordered$$packet$1, a: model$1 } });
const DomGrouped$shouted$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{count=core:Basics.Int,name=core:String.String,text=core:String.String}" + ")", a: undefined };
const DomGrouped$shouted = (model$1) => ({ t: DomGrouped$k50, v: { ...DomGrouped$shouted$$packet$1, a: model$1 } });
export { DomGrouped$view, DomGrouped$ordered, DomGrouped$shouted };
//# sourceMappingURL=DomGrouped.mjs.map
