import { Rt$template, Rt$empty, Rt$classes, Rt$styles, Rt$safeUrl, Rt$control } from "./_platform/Rt.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomAttributes$p27 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
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
  const $i$10 = { s: $r$9, q: Rt$empty, e: $r$9, w0: $r$9, a0: false, g0_0: NaN, g1_0: NaN };
  DomAttributes$p27($i$10, $v$7);
  return $i$10;
}, p: DomAttributes$p27 };
const DomAttributes$p48 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = $input$3.classes;
    $i$1.a0 = Rt$classes($i$1.w0, $t$4, $i$1.a0);
  }
  {
    const $t$5 = $input$3.styles;
    $i$1.a1 = Rt$styles($i$1.w0, $t$5, $i$1.a1);
  }
};
const DomAttributes$t48 = Rt$template("<p>x");
const DomAttributes$k48 = { m: ($v$6, $cx$7) => {
  const $r$8 = DomAttributes$t48();
  const $i$9 = { s: $r$8, q: Rt$empty, e: $r$8, w0: $r$8, a0: null, a1: null };
  DomAttributes$p48($i$9, $v$6);
  return $i$9;
}, p: DomAttributes$p48 };
function DomAttributes$domProperty_76616c7565_0_get($propertyNode$7) {
  return $propertyNode$7.value;
}
function DomAttributes$domProperty_76616c7565_0_set($propertyNode$7, $propertyValue$8) {
  $propertyNode$7.value = $propertyValue$8;
}
const DomAttributes$domProperty_76616c7565_0 = { name: "value", immutable: true, get: DomAttributes$domProperty_76616c7565_0_get, set: DomAttributes$domProperty_76616c7565_0_set };
function DomAttributes$domProperty_636865636b6564_3_get($propertyNode$11) {
  return $propertyNode$11.checked;
}
function DomAttributes$domProperty_636865636b6564_3_set($propertyNode$11, $propertyValue$12) {
  $propertyNode$11.checked = $propertyValue$12;
}
const DomAttributes$domProperty_636865636b6564_3 = { name: "checked", immutable: true, get: DomAttributes$domProperty_636865636b6564_3_get, set: DomAttributes$domProperty_636865636b6564_3_set };
const DomAttributes$p68 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
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
    Rt$control($i$1.w1, DomAttributes$domProperty_76616c7565_0, $t$6);
  }
  const $x$9 = $input$3.on;
  if ($x$9 !== $i$1.g2_0) {
    $i$1.g2_0 = $x$9;
    const $t$10 = $input$3.on;
    Rt$control($i$1.w1, DomAttributes$domProperty_636865636b6564_3, $t$10);
  }
};
const DomAttributes$t68 = Rt$template("<form><input><a>link</a><b>");
const DomAttributes$k68 = { m: ($v$13, $cx$14) => {
  const $r$15 = DomAttributes$t68();
  const $w$16 = $r$15.firstChild;
  const $w$17 = $w$16.nextSibling;
  const $w$18 = $w$17.nextSibling;
  const $i$19 = { s: $r$15, q: Rt$empty, e: $r$15, w0: $r$15, w1: $w$16, w2: $w$17, w4: $w$18, g0_0: NaN, g1_0: NaN, g2_0: NaN };
  DomAttributes$p68($i$19, $v$13);
  return $i$19;
}, p: DomAttributes$p68 };
const DomAttributes$inPlace$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{color=core:String.String,danger=core:Basics.Bool}" + ")", a: undefined };
const DomAttributes$inPlace = (r$1) => ({ t: DomAttributes$k27, v: { ...DomAttributes$inPlace$$packet$1, a: r$1 } });
const DomAttributes$lists$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{classes=core:List.List((core:String.String,core:Basics.Bool)),styles=core:List.List((core:String.String,core:String.String))}" + ")", a: undefined };
const DomAttributes$lists = (r$1) => ({ t: DomAttributes$k48, v: { ...DomAttributes$lists$$packet$1, a: r$1 } });
const DomAttributes$fields$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{on=core:Basics.Bool,text=core:String.String,url=core:String.String}" + ")", a: undefined };
const DomAttributes$fields = (r$1) => ({ t: DomAttributes$k68, v: { ...DomAttributes$fields$$packet$1, a: r$1 } });
export { DomAttributes$inPlace, DomAttributes$lists, DomAttributes$fields };
//# sourceMappingURL=DomAttributes.mjs.map
