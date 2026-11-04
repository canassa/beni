import { Rt$template, Rt$insertText, Rt$empty, Rt$childHtml, Rt$restate, Rt$slot, Rt$forKeyed, Rt$rowsHead, Rt$rowsTail, Rt$rowsRestate, Rt$rowsDispose, Rt$text } from "./_platform/Rt.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomHelpers$p10 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $input$4 = $v$2.b;
  const $x$5 = $input$3;
  if ($x$5 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$5;
    $i$1.x0.data = $x$5;
  }
  const $x$6 = $input$4;
  if ($x$6 !== $i$1.g1_0) {
    $i$1.g1_0 = $x$6;
    $i$1.x1.data = $x$6;
  }
};
const DomHelpers$t10 = Rt$template("<b> <!>");
const DomHelpers$k10 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomHelpers$t10();
  const $w$10 = $r$9.firstChild;
  const $w$11 = $w$10.nextSibling;
  const $x$12 = Rt$insertText($r$9, $w$10, "");
  const $x$13 = Rt$insertText($r$9, $w$11, "");
  const $i$14 = { s: $r$9, q: Rt$empty, e: $r$9, x0: $x$12, x1: $x$13, g0_0: NaN, g1_0: NaN };
  DomHelpers$p10($i$14, $v$7);
  return $i$14;
}, p: DomHelpers$p10 };
const DomHelpers$p27 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $input$4 = $v$2.b;
  if ($input$3 !== $i$1.g0_0 || $input$4 !== $i$1.g0_1) {
    $i$1.g0_0 = $input$3;
    $i$1.g0_1 = $input$4;
    if ($input$3 !== $i$1.a0_0 || $input$4 !== $i$1.a0_1) {
      $i$1.a0_0 = $input$3;
      $i$1.a0_1 = $input$4;
      Rt$childHtml($i$1.c0, DomHelpers$label($input$3, $input$4));
    } else {
      Rt$restate($i$1.c0);
    }
  } else {
    Rt$restate($i$1.c0);
  }
  if ($i$1.g1 === undefined) {
    $i$1.g1 = true;
    if ($i$1.a1 === undefined) {
      Rt$childHtml($i$1.c1, DomHelpers$label("fixed", 1));
      $i$1.a1 = true;
    } else {
      Rt$restate($i$1.c1);
    }
  } else {
    Rt$restate($i$1.c1);
  }
  $i$1.$l = $i$1.c0.l || $i$1.c1.l;
};
const DomHelpers$t27 = Rt$template("<div><!><!>");
const DomHelpers$k27 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomHelpers$t27();
  const $w$8 = $r$7.firstChild;
  const $w$9 = $w$8.nextSibling;
  const $c$10 = Rt$slot($r$7, $w$8, $cx$6);
  const $c$11 = Rt$slot($r$7, $w$9, $cx$6);
  const $i$12 = { s: $r$7, q: Rt$empty, e: $r$7, c0: $c$10, c1: $c$11, a0_0: undefined, a0_1: undefined, a1: undefined, g0_0: NaN, g0_1: NaN, g1: undefined };
  DomHelpers$p27($i$12, $v$5);
  return $i$12;
}, p: DomHelpers$p27, l: true };
const DomHelpers$t42 = Rt$template("<li>");
const DomHelpers$domRowView = ($value$15) => $value$15;
const DomHelpers$domRowItem = ($value$16) => $value$16.x;
const DomHelpers$domRowSameItem = ($value$17, $value$18) => $value$17.x === $value$18;
const DomHelpers$domRowSetItem = ($value$19, $value$20) => {
  $value$19.x = $value$20;
};
const DomHelpers$domSameNone = ($value$21, $value$22) => true;
const DomHelpers$domRememberAll = ($value$23) => $value$23;
const DomHelpers$domNoProbe = ($value$24) => Rt$empty;
const DomHelpers$domKeyIdentity = ($value$25) => $value$25;
const DomHelpers$domSite9 = { head: ($scope$26, $data$27, $slot$28) => Rt$rowsHead("core:String.String", $scope$26, $data$27, $slot$28), tail: ($scope$30, $data$31, $slot$32) => Rt$rowsTail("core:String.String", $scope$30, $data$31, $slot$32), restate: ($scope$34, $data$35, $slot$36, $stamp$37) => Rt$rowsRestate("core:String.String", $scope$34, $data$35, $slot$36, $stamp$37), dispose: ($scope$38, $data$39, $slot$40) => Rt$rowsDispose("core:String.String", $scope$38, $data$39, $slot$40) };
const DomHelpers$p44 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $made$4 = { m: ($item$5, $key$6, $position$7, $cx$11) => {
      const $r$12 = DomHelpers$t42();
      const $c$13 = Rt$slot($r$12, Rt$empty, $cx$11);
      Rt$childHtml($c$13, DomHelpers$label($item$5, 0));
      return { s: $r$12, q: Rt$empty, e: $r$12, x: $item$5, y: $position$7, k: $key$6, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, c0: $c$13, a0_0: $item$5, $l: $c$13.l };
    }, p: ($i$8, $item$9, $position$10) => {
      if ($item$9 !== $i$8.a0_0) {
        $i$8.a0_0 = $item$9;
        Rt$childHtml($i$8.c0, DomHelpers$label($item$9, 0));
      } else {
        Rt$restate($i$8.c0);
      }
      $i$8.$l = $i$8.c0.l;
      return $i$8;
    }, r: ($i$14) => {
      Rt$restate($i$14.c0);
    }, view: DomHelpers$domRowView, item: DomHelpers$domRowItem, sameItem: DomHelpers$domRowSameItem, setItem: DomHelpers$domRowSetItem, o: true, i: false, l: true, e: false, f: Rt$empty, j: Rt$empty, same: DomHelpers$domSameNone, remember: DomHelpers$domRememberAll, probe: DomHelpers$domNoProbe };
    Rt$forKeyed("core:String.String", $i$1.c0, $input$3, DomHelpers$domKeyIdentity, $made$4, Rt$empty, DomHelpers$domSite9, $made$4);
  }
  $i$1.$l = $i$1.c0.w || $i$1.c0.l;
};
const DomHelpers$t44 = Rt$template("<ul>");
const DomHelpers$k44 = { m: ($v$42, $cx$43) => {
  const $r$44 = DomHelpers$t44();
  const $c$45 = Rt$slot($r$44, Rt$empty, $cx$43);
  const $i$46 = { s: $r$44, q: Rt$empty, e: $r$44, c0: $c$45 };
  DomHelpers$p44($i$46, $v$42);
  return $i$46;
}, p: DomHelpers$p44, l: true };
const DomHelpers$t69 = Rt$template("<b> ");
const DomHelpers$k69 = { m: ($v$2, $cx$3) => {
  const $r$4 = DomHelpers$t69();
  const $w$5 = $r$4.firstChild;
  $w$5.data = $v$2[0];
  return { s: $r$4, q: Rt$empty, e: $r$4, w1: $w$5, a0: $v$2[0] };
}, p: ($i$6, $v$7) => {
  if ($v$7[0] !== $i$6.a0) {
    $i$6.a0 = $v$7[0];
    $i$6.w1.data = $v$7[0];
  }
} };
const DomHelpers$p85 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.x0.data = $x$4;
    $i$1.x1.data = $x$4;
  }
};
const DomHelpers$t85 = Rt$template("<i><!><!>");
const DomHelpers$k85 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomHelpers$t85();
  const $w$8 = $r$7.firstChild;
  const $w$9 = $w$8.nextSibling;
  const $x$10 = Rt$insertText($r$7, $w$8, "");
  const $x$11 = Rt$insertText($r$7, $w$9, "");
  const $i$12 = { s: $r$7, q: Rt$empty, e: $r$7, x0: $x$10, x1: $x$11, g0_0: NaN };
  DomHelpers$p85($i$12, $v$5);
  return $i$12;
}, p: DomHelpers$p85 };
const DomHelpers$p96 = ($i$13, $v$14) => {
  const $input$15 = $v$14.a;
  const $input$16 = $v$14.b;
  const $x$17 = $input$15;
  if ($x$17 !== $i$13.g0_0) {
    $i$13.g0_0 = $x$17;
    const $t$18 = DomHelpers$same(DomHelpers$eq$prim, "core:Basics.Int", $input$15, 1);
    Rt$childHtml($i$13.c0, $t$18);
  } else {
    Rt$restate($i$13.c0);
  }
  if ($input$15 !== $i$13.g1_0 || $input$16 !== $i$13.g1_1) {
    $i$13.g1_0 = $input$15;
    $i$13.g1_1 = $input$16;
    const $t$19 = $input$16($input$15);
    Rt$childHtml($i$13.c1, $t$19);
  } else {
    Rt$restate($i$13.c1);
  }
  if ($i$13.g2 === undefined) {
    $i$13.g2 = true;
    const $t$20 = Rt$text("t");
    Rt$childHtml($i$13.c2, $t$20);
  } else {
    Rt$restate($i$13.c2);
  }
  $i$13.$l = $i$13.c0.l || $i$13.c1.l || $i$13.c2.l;
};
const DomHelpers$t96 = Rt$template("<div><!><!><!>");
const DomHelpers$k96 = { m: ($v$21, $cx$22) => {
  const $r$23 = DomHelpers$t96();
  const $w$24 = $r$23.firstChild;
  const $w$25 = $w$24.nextSibling;
  const $w$26 = $w$25.nextSibling;
  const $c$27 = Rt$slot($r$23, $w$24, $cx$22);
  const $c$28 = Rt$slot($r$23, $w$25, $cx$22);
  const $c$29 = Rt$slot($r$23, $w$26, $cx$22);
  const $i$30 = { s: $r$23, q: Rt$empty, e: $r$23, c0: $c$27, c1: $c$28, c2: $c$29, g0_0: NaN, g1_0: NaN, g1_1: NaN, g2: undefined };
  DomHelpers$p96($i$30, $v$21);
  return $i$30;
}, p: DomHelpers$p96, l: true };
const DomHelpers$eq$prim = ($x, $y) => $x === $y;
const DomHelpers$label$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:String.String" + "," + "core:Basics.Int" + ")", a: undefined, b: undefined };
const DomHelpers$label = (name$1, n$2) => ({ t: DomHelpers$k10, v: { ...DomHelpers$label$$packet$1, a: name$1, b: n$2 } });
const DomHelpers$page$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:String.String" + "," + "core:Basics.Int" + ")", a: undefined, b: undefined };
const DomHelpers$page = ($m$0, name$1, n$2) => ({ t: DomHelpers$k27, v: { ...DomHelpers$page$$packet$1, a: name$1, b: n$2 } });
const DomHelpers$rows$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:List.List(core:String.String)" + ")", a: undefined };
const DomHelpers$rows = ($m$0, names$1) => ({ t: DomHelpers$k44, v: { ...DomHelpers$rows$$packet$1, a: names$1 } });
const DomHelpers$same = ($m$0, $m$1, x$1, y$2) => {
  const $t$1 = $m$0(x$1, y$2) ? "same" : "different";
  return { t: DomHelpers$k69, v: [$t$1] };
};
const DomHelpers$others$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:Basics.Int" + ")", a: undefined };
const DomHelpers$others = ($m$0, n$1) => {
  function twice$2(m$3) {
    return { t: DomHelpers$k85, v: { ...DomHelpers$others$$packet$1, a: m$3 } };
  }
  return { t: DomHelpers$k96, v: { a: n$1, b: twice$2, [Js$Any$pack.$packet.key]: "(" + "core:Basics.Int" + "," + ("(core:Basics.Int->platform:Html.Html(" + $m$0 + "))") + ")" } };
};
export { DomHelpers$page, DomHelpers$rows, DomHelpers$others };
//# sourceMappingURL=DomHelpers.mjs.map
