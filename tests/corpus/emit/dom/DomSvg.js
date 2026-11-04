import { Rt$safeUrl, Rt$attrNS, Rt$template, Rt$empty, Rt$templateOf, Rt$forKeyed, Rt$rowsHead, Rt$rowsTail, Rt$rowsRestate, Rt$rowsDispose, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
import { String$fromInt } from "./_core/String.mjs";
const DomSvg$p10 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $input$4 = $v$2.b;
  const $x$5 = $input$3;
  if ($x$5 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$5;
    $i$1.w0.setAttribute("viewBox", $x$5);
  }
  const $x$6 = $input$4;
  if ($x$6 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$6;
    Rt$attrNS($i$1.w3, "http://www.w3.org/1999/xlink", "xlink:href", Rt$safeUrl($x$6));
  }
};
const DomSvg$t10 = Rt$template("<svg><linearGradient id=fade><stop offset=0 stop-color=white></stop></linearGradient><use>");
const DomSvg$k10 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomSvg$t10();
  const $w$10 = $r$9.firstChild.nextSibling;
  const $i$11 = { s: $r$9, q: Rt$empty, e: $r$9, w0: $r$9, w3: $w$10, g0_0: NaN, g1_0: NaN };
  DomSvg$p10($i$11, $v$7);
  return $i$11;
}, p: DomSvg$p10 };
const DomSvg$p18 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.w0.setAttribute("cx", $x$4);
  }
};
const DomSvg$t18 = Rt$templateOf("<svg><circle r=2></svg>", 2);
const DomSvg$k18 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomSvg$t18();
  const $i$8 = { s: $r$7, q: Rt$empty, e: $r$7, w0: $r$7, g0_0: NaN };
  DomSvg$p18($i$8, $v$5);
  return $i$8;
}, p: DomSvg$p18 };
const DomSvg$t22 = Rt$templateOf("<svg><line x2=10 y2=10></line><text font-size=3>pair</svg>", 6);
const DomSvg$k22 = { m: ($v$1, $cx$2) => {
  const $r$3 = DomSvg$t22();
  const $w$4 = $r$3.firstChild;
  const $w$5 = $w$4.nextSibling;
  return { s: $w$4, q: Rt$empty, e: $w$5 };
}, p: ($i$6, $v$7) => {
} };
const DomSvg$b22 = { t: DomSvg$k22, v: null };
const DomSvg$t39 = Rt$templateOf("<svg><rect></svg>", 2);
const DomSvg$domNoRestate = ($value$17) => {
};
const DomSvg$domRowView = ($value$18) => $value$18;
const DomSvg$domRowItem = ($value$19) => $value$19.x;
const DomSvg$domRowSameItem = ($value$20, $value$21) => $value$20.x === $value$21;
const DomSvg$domRowSetItem = ($value$22, $value$23) => {
  $value$22.x = $value$23;
};
const DomSvg$domSameNone = ($value$24, $value$25) => true;
const DomSvg$domRememberAll = ($value$26) => $value$26;
const DomSvg$domNoProbe = ($value$27) => Rt$empty;
const DomSvg$domSite10 = { head: ($scope$28, $data$29, $slot$30) => Rt$rowsHead("core:Basics.Int", $scope$28, $data$29, $slot$30), tail: ($scope$32, $data$33, $slot$34) => Rt$rowsTail("core:Basics.Int", $scope$32, $data$33, $slot$34), restate: ($scope$36, $data$37, $slot$38, $stamp$39) => Rt$rowsRestate("core:Basics.Int", $scope$36, $data$37, $slot$38, $stamp$39), dispose: ($scope$40, $data$41, $slot$42) => Rt$rowsDispose("core:Basics.Int", $scope$40, $data$41, $slot$42) };
const DomSvg$p41 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = (n$2) => n$2;
    const $made$5 = (($patch$15) => ({ m: ($item$6, $key$7, $position$8, $cx$13) => {
      const $r$14 = DomSvg$t39();
      const $i$16 = { s: $r$14, q: Rt$empty, e: $r$14, x: undefined, y: $position$8, k: $key$7, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, w0: $r$14, a0: undefined };
      $patch$15($i$16, $item$6, $position$8);
      $i$16.x = $item$6;
      return $i$16;
    }, p: $patch$15, r: DomSvg$domNoRestate, view: DomSvg$domRowView, item: DomSvg$domRowItem, sameItem: DomSvg$domRowSameItem, setItem: DomSvg$domRowSetItem, o: true, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomSvg$domSameNone, remember: DomSvg$domRememberAll, probe: DomSvg$domNoProbe }))(($i$9, $item$10, $position$11) => {
      const $t$12 = String$fromInt($item$10);
      if ($t$12 !== $i$9.a0) {
        $i$9.w0.setAttribute("height", $t$12);
        $i$9.a0 = $t$12;
      }
      return $i$9;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.c0, $input$3, $t$4, $made$5, Rt$empty, DomSvg$domSite10, $made$5);
  }
  $i$1.$l = $i$1.c0.w || $i$1.c0.l;
};
const DomSvg$t41 = Rt$templateOf("<svg><g></svg>", 2);
const DomSvg$k41 = { m: ($v$44, $cx$45) => {
  const $r$46 = DomSvg$t41();
  const $c$47 = Rt$slot($r$46, Rt$empty, $cx$45);
  const $i$48 = { s: $r$46, q: Rt$empty, e: $r$46, c0: $c$47 };
  DomSvg$p41($i$48, $v$44);
  return $i$48;
}, p: DomSvg$p41, l: true };
const DomSvg$picture$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:String.String" + "," + "core:String.String" + ")", a: undefined, b: undefined };
const DomSvg$picture = (box$1, link$2) => ({ t: DomSvg$k10, v: { ...DomSvg$picture$$packet$1, a: box$1, b: link$2 } });
const DomSvg$dot$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:String.String" + ")", a: undefined };
const DomSvg$dot = (x$1) => ({ t: DomSvg$k18, v: { ...DomSvg$dot$$packet$1, a: x$1 } });
const DomSvg$pair = DomSvg$b22;
const DomSvg$bars$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:List.List(core:Basics.Int)" + ")", a: undefined };
const DomSvg$bars = ($m$0, ns$1) => ({ t: DomSvg$k41, v: { ...DomSvg$bars$$packet$1, a: ns$1 } });
export { DomSvg$picture, DomSvg$dot, DomSvg$pair, DomSvg$bars };
//# sourceMappingURL=DomSvg.mjs.map
