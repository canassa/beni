import { Rt$template, Rt$delegate, Rt$identity, Rt$empty, Rt$childHtml, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomPacket$p19 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $input$4 = $v$2.b;
  const $x$5 = $input$3.emit;
  if ($x$5 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$5;
    $i$1.w0.$$click = $x$5;
  }
  if ($input$3.count !== $i$1.g1_0 || $input$4 !== $i$1.g1_1) {
    $i$1.g1_0 = $input$3.count;
    $i$1.g1_1 = $input$4;
    const $t$6 = $input$3.count + $input$4;
    if ($t$6 !== $i$1.a1) {
      $i$1.a1 = $t$6;
      $i$1.w1.data = $t$6;
    }
  }
};
const DomPacket$t19 = Rt$template("<button> ");
const DomPacket$k19 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomPacket$t19();
  const $w$10 = $r$9.firstChild;
  Rt$delegate(["click"]);
  $r$9.$$clickX = Rt$identity;
  if ($cx$8 !== null) {
    $r$9.$$cx = $cx$8;
  }
  const $i$11 = { s: $r$9, q: Rt$empty, e: $r$9, w0: $r$9, w1: $w$10, a1: undefined, g0_0: NaN, g1_0: NaN, g1_1: NaN };
  DomPacket$p19($i$11, $v$7);
  return $i$11;
}, p: DomPacket$p19 };
const DomPacket$p31 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = $input$3.inner;
    Rt$childHtml($i$1.c0, $t$4);
  }
  $i$1.$l = $i$1.c0.l;
};
const DomPacket$t31 = Rt$template("<section>");
const DomPacket$k31 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomPacket$t31();
  const $c$8 = Rt$slot($r$7, Rt$empty, $cx$6);
  const $i$9 = { s: $r$7, q: Rt$empty, e: $r$7, c0: $c$8 };
  DomPacket$p31($i$9, $v$5);
  return $i$9;
}, p: DomPacket$p31, l: true };
const DomPacket$view$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{count=core:Basics.Int,emit=(core:Browser.Host.Event.Event->core:Basics.Int)}" + "," + "core:Basics.Int" + ")", a: undefined, b: undefined };
const DomPacket$view = (model$1, delta$2) => ({ t: DomPacket$k19, v: { ...DomPacket$view$$packet$1, a: model$1, b: delta$2 } });
const DomPacket$generic = ($m$0, model$1) => ({ t: DomPacket$k31, v: { a: model$1, [Js$Any$pack.$packet.key]: "(" + ("{inner=platform:Html.Html(" + $m$0 + ")}") + ")" } });
export { DomPacket$view, DomPacket$generic };
//# sourceMappingURL=DomPacket.mjs.map
