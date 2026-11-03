import { Rt$templateOf, Rt$slot, Rt$template, Rt$childHtml, Rt$restate, Rt$forPosition } from "./_platform/_browser/Rt.mjs";
import { Card$view } from "./_platform/Card.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomPacketRowsNoInputs$t8 = Rt$templateOf("<!>", 4);
const DomPacketRowsNoInputs$t8n2 = Rt$template("<b>static");
const DomPacketRowsNoInputs$k8n2 = { m: ($v$14, $cx$15) => {
  const $r$16 = DomPacketRowsNoInputs$t8n2();
  return { s: $r$16, q: null, e: $r$16 };
}, p: ($i$17, $v$18) => {
} };
const DomPacketRowsNoInputs$b8n2 = { t: DomPacketRowsNoInputs$k8n2, v: null };
const DomPacketRowsNoInputs$p10 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    const $t$5 = ["one"];
    const $made$6 = { j: $input$3, o: true, h: [], m: ($item$7, $position$8, $cx$9) => {
      const $r$10 = DomPacketRowsNoInputs$t8();
      const $w$11 = $r$10.firstChild;
      const $c$12 = Rt$slot(null, $w$11, $cx$9);
      const $made$13 = DomPacketRowsNoInputs$b8n2;
      Rt$childHtml($c$12, Card$view($input$3, { children: $made$13 }));
      return { s: null, q: $c$12, e: $w$11, c0: $c$12, a0c: undefined, l: $c$12.l };
    }, p: ($i$19, $item$20, $position$21) => {
      const $made$22 = DomPacketRowsNoInputs$b8n2;
      if (true) {
        Rt$childHtml($i$19.c0, Card$view($input$3, { children: $made$22 }));
      } else {
        Rt$restate($i$19.c0);
      }
      $i$19.l = $i$19.c0.l;
    }, l: true, r: ($i$23) => {
      Rt$restate($i$23.c0);
    }, i: false, f: null };
    Rt$forPosition($i$1.c0, $t$5, $made$6, null);
  } else {
    Rt$restate($i$1.c0);
  }
  $i$1.l = $i$1.c0.w || $i$1.c0.l;
};
const DomPacketRowsNoInputs$t10 = Rt$templateOf("<!>", 4);
const DomPacketRowsNoInputs$k10 = { m: ($v$24, $cx$25) => {
  const $r$26 = DomPacketRowsNoInputs$t10();
  const $w$27 = $r$26.firstChild;
  const $c$28 = Rt$slot(null, $w$27, $cx$25);
  const $i$29 = { s: null, q: $c$28, e: $w$27, c0: $c$28, g0_0: NaN };
  DomPacketRowsNoInputs$p10($i$29, $v$24);
  return $i$29;
}, p: DomPacketRowsNoInputs$p10, l: true };
let DomPacketRowsNoInputs$view$ev$k0;
let DomPacketRowsNoInputs$view$ev$v;
const DomPacketRowsNoInputs$view$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:String.String" + ")", a: undefined };
const DomPacketRowsNoInputs$view = ($m$0) => {
  if ($m$0 !== DomPacketRowsNoInputs$view$ev$k0) {
    DomPacketRowsNoInputs$view$ev$v = { t: DomPacketRowsNoInputs$k10, v: { ...DomPacketRowsNoInputs$view$$packet$1, a: $m$0 } };
    DomPacketRowsNoInputs$view$ev$k0 = $m$0;
  }
  return DomPacketRowsNoInputs$view$ev$v;
};
export { DomPacketRowsNoInputs$view };
//# sourceMappingURL=DomPacketRowsNoInputs.mjs.map
