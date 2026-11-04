import { Rt$empty, Rt$templateOf, Rt$template, Rt$childHtml, Rt$restate, Rt$slot, Rt$positionHead, Rt$positionTail, Rt$positionRestate, Rt$positionDispose, Rt$forPosition } from "./_platform/_browser/Rt.mjs";
import { Card$view } from "./_platform/Card.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomPacketRowsNoInputs$t8 = Rt$templateOf("<!>", 4);
const DomPacketRowsNoInputs$t8n2 = Rt$template("<b>static");
const DomPacketRowsNoInputs$k8n2 = { m: ($v$14, $cx$15) => {
  const $r$16 = DomPacketRowsNoInputs$t8n2();
  return { s: $r$16, q: Rt$empty, e: $r$16 };
}, p: ($i$17, $v$18) => {
} };
const DomPacketRowsNoInputs$b8n2 = { t: DomPacketRowsNoInputs$k8n2, v: null };
const DomPacketRowsNoInputs$domRowView = ($value$25) => $value$25;
const DomPacketRowsNoInputs$domRowItem = ($value$26) => $value$26.x;
const DomPacketRowsNoInputs$domRowSameItem = ($value$27, $value$28) => $value$27.x === $value$28;
const DomPacketRowsNoInputs$domRowSetItem = ($value$29, $value$30) => {
  $value$29.x = $value$30;
};
const DomPacketRowsNoInputs$domSameNone = ($value$31, $value$32) => true;
const DomPacketRowsNoInputs$domRememberAll = ($value$33) => $value$33;
const DomPacketRowsNoInputs$domNoProbe = ($value$34) => Rt$empty;
const DomPacketRowsNoInputs$domPositionSite = { head: ($scope$35, $data$36, $slot$37) => Rt$positionHead($scope$35, $data$36, $slot$37), tail: ($scope$39, $data$40, $slot$41) => Rt$positionTail($scope$39, $data$40, $slot$41), restate: ($scope$43, $data$44, $slot$45, $stamp$46) => Rt$positionRestate($scope$43, $data$44, $slot$45, $stamp$46), dispose: ($scope$47, $data$48, $slot$49) => Rt$positionDispose($scope$47, $data$48, $slot$49) };
const DomPacketRowsNoInputs$p10 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    const $t$5 = ["one"];
    const $made$6 = { m: ($item$7, $key$8, $position$9, $cx$19) => {
      const $r$20 = DomPacketRowsNoInputs$t8();
      const $w$21 = $r$20.firstChild;
      const $c$22 = Rt$slot(Rt$empty, $w$21, $cx$19);
      const $made$23 = DomPacketRowsNoInputs$b8n2;
      Rt$childHtml($c$22, Card$view($input$3, { children: $made$23 }));
      return { s: Rt$empty, q: $c$22, e: $w$21, x: $item$7, y: $position$9, k: $key$8, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, c0: $c$22, a0c: undefined, $l: $c$22.l };
    }, p: ($i$10, $item$11, $position$12) => {
      const $made$13 = DomPacketRowsNoInputs$b8n2;
      if (true) {
        Rt$childHtml($i$10.c0, Card$view($input$3, { children: $made$13 }));
      } else {
        Rt$restate($i$10.c0);
      }
      $i$10.$l = $i$10.c0.l;
      return $i$10;
    }, r: ($i$24) => {
      Rt$restate($i$24.c0);
    }, view: DomPacketRowsNoInputs$domRowView, item: DomPacketRowsNoInputs$domRowItem, sameItem: DomPacketRowsNoInputs$domRowSameItem, setItem: DomPacketRowsNoInputs$domRowSetItem, o: true, i: false, l: true, e: false, f: Rt$empty, j: $input$3, same: DomPacketRowsNoInputs$domSameNone, remember: DomPacketRowsNoInputs$domRememberAll, probe: DomPacketRowsNoInputs$domNoProbe };
    Rt$forPosition($i$1.c0, $t$5, $made$6, Rt$empty, DomPacketRowsNoInputs$domPositionSite, $made$6);
  } else {
    Rt$restate($i$1.c0);
  }
  $i$1.$l = $i$1.c0.w || $i$1.c0.l;
};
const DomPacketRowsNoInputs$t10 = Rt$templateOf("<!>", 4);
const DomPacketRowsNoInputs$k10 = { m: ($v$51, $cx$52) => {
  const $r$53 = DomPacketRowsNoInputs$t10();
  const $w$54 = $r$53.firstChild;
  const $c$55 = Rt$slot(Rt$empty, $w$54, $cx$52);
  const $i$56 = { s: Rt$empty, q: $c$55, e: $w$54, c0: $c$55, g0_0: NaN };
  DomPacketRowsNoInputs$p10($i$56, $v$51);
  return $i$56;
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
