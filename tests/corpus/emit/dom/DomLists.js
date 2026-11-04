import { Rt$template, Rt$empty, Rt$forKeyed, Rt$rowsHead, Rt$rowsTail, Rt$rowsRestate, Rt$rowsDispose, Rt$restate, Rt$slot, Rt$insertText, Rt$positionHead, Rt$positionTail, Rt$positionRestate, Rt$positionDispose, Rt$forPosition, Rt$protocol, Rt$show, Rt$hide, Rt$templateOf } from "./_platform/Rt.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
import { List$head } from "./_core/List.mjs";
const DomLists$p18 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  const $x$4 = $input$3;
  if ($x$4 !== $i$1.g0_0) {
    $i$1.g0_0 = $x$4;
    $i$1.w1.data = $x$4;
  }
};
const DomLists$t18 = Rt$template("<li> ");
const DomLists$k18 = { m: ($v$5, $cx$6) => {
  const $r$7 = DomLists$t18();
  const $w$8 = $r$7.firstChild;
  const $i$9 = { s: $r$7, q: Rt$empty, e: $r$7, w1: $w$8, g0_0: NaN };
  DomLists$p18($i$9, $v$5);
  return $i$9;
}, p: DomLists$p18 };
const DomLists$t42 = Rt$template("<tr><td> ");
const DomLists$domNoRestate = ($value$22) => {
};
const DomLists$domRowView = ($value$23) => $value$23;
const DomLists$domRowItem = ($value$24) => $value$24.x;
const DomLists$domRowSameItem = ($value$25, $value$26) => $value$25.x === $value$26;
const DomLists$domRowSetItem = ($value$27, $value$28) => {
  $value$27.x = $value$28;
};
const DomLists$domSame5 = ($was$29, $now$30) => $was$29 !== Rt$empty;
const DomLists$domRememberAll = ($value$31) => $value$31;
const DomLists$domProbe1 = ($inputs$32) => $inputs$32[1];
const DomLists$domSite5 = { head: ($scope$33, $data$34, $slot$35) => Rt$rowsHead("core:Basics.Int", $scope$33, $data$34, $slot$35), tail: ($scope$37, $data$38, $slot$39) => Rt$rowsTail("core:Basics.Int", $scope$37, $data$38, $slot$39), restate: ($scope$41, $data$42, $slot$43, $stamp$44) => Rt$rowsRestate("core:Basics.Int", $scope$41, $data$42, $slot$43, $stamp$44), dispose: ($scope$45, $data$46, $slot$47) => Rt$rowsDispose("core:Basics.Int", $scope$45, $data$46, $slot$47) };
const DomLists$p44 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $made$7 = { m: ($item$8, $key$9, $position$10, $cx$16) => {
      const $t$17 = $item$8.id === $input$3.selected;
      const $t$18 = $item$8.label;
      const $r$19 = DomLists$t42();
      const $w$20 = $r$19.firstChild;
      const $w$21 = $w$20.firstChild;
      if ($t$17) {
        $r$19.classList.toggle("danger", true);
      }
      $w$21.data = $t$18;
      return { s: $r$19, q: Rt$empty, e: $r$19, x: $item$8, y: $position$10, k: $key$9, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, w0: $r$19, w2: $w$21, a0: $t$17, a1: $t$18 };
    }, p: ($i$11, $item$12, $position$13) => {
      const $t$14 = $item$12.id === $input$3.selected;
      const $t$15 = $item$12.label;
      if ($t$14 !== $i$11.a0) {
        $i$11.a0 = $t$14;
        $i$11.w0.classList.toggle("danger", $t$14);
      }
      if ($t$15 !== $i$11.a1) {
        $i$11.a1 = $t$15;
        $i$11.w2.data = $t$15;
      }
      return $i$11;
    }, r: DomLists$domNoRestate, view: DomLists$domRowView, item: DomLists$domRowItem, sameItem: DomLists$domRowSameItem, setItem: DomLists$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomLists$domSame5, remember: DomLists$domRememberAll, probe: DomLists$domProbe1 };
    Rt$forKeyed("core:Basics.Int", $i$1.c0, $t$4, $t$6, $made$7, [$input$3.selected, $input$3.selected], DomLists$domSite5, $made$7);
  }
  $i$1.$l = $i$1.c0.w || $i$1.c0.l;
};
const DomLists$t44 = Rt$template("<table><tbody>");
const DomLists$k44 = { m: ($v$49, $cx$50) => {
  const $r$51 = DomLists$t44();
  const $w$52 = $r$51.firstChild;
  const $c$53 = Rt$slot($w$52, Rt$empty, $cx$50);
  const $i$54 = { s: $r$51, q: Rt$empty, e: $r$51, c0: $c$53 };
  DomLists$p44($i$54, $v$49);
  return $i$54;
}, p: DomLists$p44, l: true };
const DomLists$t62 = Rt$template("<li>none");
const DomLists$k62 = { m: ($v$6, $cx$7) => {
  const $r$8 = DomLists$t62();
  return { s: $r$8, q: Rt$empty, e: $r$8 };
}, p: ($i$9, $v$10) => {
} };
const DomLists$b62 = { t: DomLists$k62, v: null };
const DomLists$t58 = Rt$template("<li>. <!>");
const DomLists$domSameNone = ($value$25, $value$26) => true;
const DomLists$domNoProbe = ($value$27) => Rt$empty;
const DomLists$domPositionSite = { head: ($scope$28, $data$29, $slot$30) => Rt$positionHead($scope$28, $data$29, $slot$30), tail: ($scope$32, $data$33, $slot$34) => Rt$positionTail($scope$32, $data$33, $slot$34), restate: ($scope$36, $data$37, $slot$38, $stamp$39) => Rt$positionRestate($scope$36, $data$37, $slot$38, $stamp$39), dispose: ($scope$40, $data$41, $slot$42) => Rt$positionDispose($scope$40, $data$41, $slot$42) };
const DomLists$domAgainRow = ($value$58) => {
  Rt$protocol.again($value$58);
};
const DomLists$domSame20 = ($was$59, $now$60) => $was$59 !== Rt$empty && $was$59[0] === $now$60[0];
const DomLists$domKeyIdentity = ($value$61) => $value$61;
const DomLists$domSite20 = { head: ($scope$62, $data$63, $slot$64) => Rt$rowsHead("core:String.String", $scope$62, $data$63, $slot$64), tail: ($scope$66, $data$67, $slot$68) => Rt$rowsTail("core:String.String", $scope$66, $data$67, $slot$68), restate: ($scope$70, $data$71, $slot$72, $stamp$73) => Rt$rowsRestate("core:String.String", $scope$70, $data$71, $slot$72, $stamp$73), dispose: ($scope$74, $data$75, $slot$76) => Rt$rowsDispose("core:String.String", $scope$74, $data$75, $slot$76) };
const DomLists$t72 = Rt$template("<li>blank");
const DomLists$k72 = { m: ($v$83, $cx$84) => {
  const $r$85 = DomLists$t72();
  return { s: $r$85, q: Rt$empty, e: $r$85 };
}, p: ($i$86, $v$87) => {
} };
const DomLists$b72 = { t: DomLists$k72, v: null };
const DomLists$p77 = ($i$88, $v$89) => {
  const $input$90 = $v$89.a;
  const $x$91 = $input$90;
  if ($x$91 !== $i$88.g0_0) {
    $i$88.g0_0 = $x$91;
    $i$88.w1.data = $x$91;
  }
};
const DomLists$t77 = Rt$template("<li> ");
const DomLists$k77 = { m: ($v$92, $cx$93) => {
  const $r$94 = DomLists$t77();
  const $w$95 = $r$94.firstChild;
  const $i$96 = { s: $r$94, q: Rt$empty, e: $r$94, w1: $w$95, g0_0: NaN };
  DomLists$p77($i$96, $v$92);
  return $i$96;
}, p: DomLists$p77 };
const DomLists$domSite22 = { head: ($scope$107, $data$108, $slot$109) => Rt$rowsHead("core:String.String", $scope$107, $data$108, $slot$109), tail: ($scope$111, $data$112, $slot$113) => Rt$rowsTail("core:String.String", $scope$111, $data$112, $slot$113), restate: ($scope$115, $data$116, $slot$117, $stamp$118) => Rt$rowsRestate("core:String.String", $scope$115, $data$116, $slot$117, $stamp$118), dispose: ($scope$119, $data$120, $slot$121) => Rt$rowsDispose("core:String.String", $scope$119, $data$120, $slot$121) };
const DomLists$p81 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = $input$3.names;
    const $t$5 = $input$3.names;
    const $t$11 = $input$3.names;
    const $made$12 = { m: ($item$13, $key$14, $position$15, $cx$19) => {
      const $r$20 = DomLists$t58();
      const $w$21 = $r$20.firstChild;
      const $w$22 = $w$21.nextSibling;
      const $x$23 = Rt$insertText($r$20, $w$21, "" + $position$15);
      const $x$24 = Rt$insertText($r$20, $w$22, $item$13);
      return { s: $r$20, q: Rt$empty, e: $r$20, x: $item$13, y: $position$15, k: $key$14, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, x0: $x$23, x1: $x$24, a0: $position$15, a1: $item$13 };
    }, p: ($i$16, $item$17, $position$18) => {
      if ($position$18 !== $i$16.a0) {
        $i$16.a0 = $position$18;
        $i$16.x0.data = $position$18;
      }
      if ($item$17 !== $i$16.x) {
        if ($item$17 !== $i$16.a1) {
          $i$16.a1 = $item$17;
          $i$16.x1.data = $item$17;
        }
      }
      return $i$16;
    }, r: DomLists$domNoRestate, view: DomLists$domRowView, item: DomLists$domRowItem, sameItem: DomLists$domRowSameItem, setItem: DomLists$domRowSetItem, o: true, i: true, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomLists$domSameNone, remember: DomLists$domRememberAll, probe: DomLists$domNoProbe };
    Rt$forPosition($i$1.c0, $t$4, $made$12, Rt$empty, DomLists$domPositionSite, $made$12);
    const $made$44 = (($block$48) => ({ m: ($item$49, $key$50, $position$51, $cx$52) => {
      const $i$53 = Rt$protocol.unit($block$48($item$49, $position$51), $cx$52);
      $i$53.$rc = $cx$52;
      $i$53.x = $item$49;
      $i$53.y = $position$51;
      $i$53.rs = 0;
      $i$53.k = $key$50;
      $i$53.kv = 0;
      $i$53.n = Rt$empty;
      $i$53.kc = Rt$empty;
      $i$53.kt = Rt$empty;
      return $i$53;
    }, p: ($i$54, $item$55, $position$56) => {
      const $next$57 = Rt$protocol.patch($i$54, $block$48($item$55, $position$56), $i$54.$rc);
      if ($next$57 !== $i$54) {
        $next$57.$rc = $i$54.$rc;
        $next$57.x = $item$55;
        $next$57.y = $position$56;
        $next$57.rs = 0;
      }
      return $next$57;
    }, r: DomLists$domAgainRow, view: DomLists$domRowView, item: DomLists$domRowItem, sameItem: DomLists$domRowSameItem, setItem: DomLists$domRowSetItem, o: true, i: false, l: true, e: false, f: DomLists$b62, j: Rt$empty, same: DomLists$domSame20, remember: DomLists$domRememberAll, probe: DomLists$domNoProbe }))(($item$45, $position$47) => DomLists$viewName($item$45));
    Rt$forKeyed("core:String.String", $i$1.c1, $t$5, DomLists$domKeyIdentity, $made$44, [DomLists$viewName], DomLists$domSite20, $made$44);
    const $made$78 = (($block$82) => ({ m: ($item$98, $key$99, $position$100, $cx$101) => {
      const $i$102 = Rt$protocol.unit($block$82($item$98, $position$100), $cx$101);
      $i$102.$rc = $cx$101;
      $i$102.x = $item$98;
      $i$102.y = $position$100;
      $i$102.rs = 0;
      $i$102.k = $key$99;
      $i$102.kv = 0;
      $i$102.n = Rt$empty;
      $i$102.kc = Rt$empty;
      $i$102.kt = Rt$empty;
      return $i$102;
    }, p: ($i$103, $item$104, $position$105) => {
      const $next$106 = Rt$protocol.patch($i$103, $block$82($item$104, $position$105), $i$103.$rc);
      if ($next$106 !== $i$103) {
        $next$106.$rc = $i$103.$rc;
        $next$106.x = $item$104;
        $next$106.y = $position$105;
        $next$106.rs = 0;
      }
      return $next$106;
    }, r: DomLists$domAgainRow, view: DomLists$domRowView, item: DomLists$domRowItem, sameItem: DomLists$domRowSameItem, setItem: DomLists$domRowSetItem, o: true, i: false, l: true, e: false, f: Rt$empty, j: Rt$empty, same: DomLists$domSameNone, remember: DomLists$domRememberAll, probe: DomLists$domNoProbe }))(($item$79, $position$81) => {
      const $t$97 = $item$79 === "" ? DomLists$b72 : { t: DomLists$k77, v: { ...DomLists$lists$$packet$1, a: $item$79 } };
      return $t$97;
    });
    Rt$forKeyed("core:String.String", $i$1.c2, $t$11, DomLists$domKeyIdentity, $made$78, Rt$empty, DomLists$domSite22, $made$78);
  }
  $i$1.$l = $i$1.c0.w || $i$1.c0.l || $i$1.c1.w || $i$1.c1.l || $i$1.c2.w || $i$1.c2.l;
};
const DomLists$t81 = Rt$template("<div><ol></ol><ul></ul><ul>");
const DomLists$k81 = { m: ($v$123, $cx$124) => {
  const $r$125 = DomLists$t81();
  const $w$126 = $r$125.firstChild;
  const $w$127 = $w$126.nextSibling;
  const $w$128 = $w$127.nextSibling;
  const $c$129 = Rt$slot($w$126, Rt$empty, $cx$124);
  const $c$130 = Rt$slot($w$127, Rt$empty, $cx$124);
  const $c$131 = Rt$slot($w$128, Rt$empty, $cx$124);
  const $i$132 = { s: $r$125, q: Rt$empty, e: $r$125, c0: $c$129, c1: $c$130, c2: $c$131 };
  DomLists$p81($i$132, $v$123);
  return $i$132;
}, p: DomLists$p81, l: true };
const DomLists$t96 = Rt$template("<p>none");
const DomLists$k96 = { m: ($v$7, $cx$8) => {
  const $r$9 = DomLists$t96();
  return { s: $r$9, q: Rt$empty, e: $r$9 };
}, p: ($i$10, $v$11) => {
} };
const DomLists$b96 = { t: DomLists$k96, v: null };
const DomLists$t102 = Rt$template("<p> of <!>");
const DomLists$k102 = { m: ($v$18, $cx$19) => {
  const $r$20 = DomLists$t102();
  const $w$21 = $r$20.firstChild;
  const $w$22 = $w$21.nextSibling;
  const $x$23 = Rt$insertText($r$20, $w$21, $v$18[0]);
  const $x$24 = Rt$insertText($r$20, $w$22, "" + $v$18[1]);
  return { s: $r$20, q: Rt$empty, e: $r$20, x0: $x$23, x1: $x$24, a0: $v$18[0], a1: $v$18[1] };
}, p: ($i$25, $v$26) => {
  if ($v$26[0] !== $i$25.a0) {
    $i$25.a0 = $v$26[0];
    $i$25.x0.data = $v$26[0];
  }
  if ($v$26[1] !== $i$25.a1) {
    $i$25.a1 = $v$26[1];
    $i$25.x1.data = $v$26[1];
  }
} };
const DomLists$domSite31 = { head: ($scope$27, $data$28, $slot$29) => Rt$rowsHead("core:Basics.Int", $scope$27, $data$28, $slot$29), tail: ($scope$31, $data$32, $slot$33) => Rt$rowsTail("core:Basics.Int", $scope$31, $data$32, $slot$33), restate: ($scope$35, $data$36, $slot$37, $stamp$38) => Rt$rowsRestate("core:Basics.Int", $scope$35, $data$36, $slot$37, $stamp$38), dispose: ($scope$39, $data$40, $slot$41) => Rt$rowsDispose("core:Basics.Int", $scope$39, $data$40, $slot$41) };
const DomLists$p104 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = List$head($input$3.rows);
    const $t$6 = ($p$5) => $p$5.id;
    const $made$14 = ($value$15) => {
      const $t$16 = $value$15.label;
      const $t$17 = $input$3.selected;
      return { t: DomLists$k102, v: [$t$16, $t$17] };
    };
    if ($t$4.$ === "Just") {
      const $value$12 = $t$4.a;
      const $key$13 = $t$6($value$12);
      if ($key$13 !== $i$1.a0k || true || $input$3.selected !== $i$1.a0i0) {
        $i$1.a0k = $key$13;
        $i$1.a0i0 = $input$3.selected;
        Rt$show("core:Basics.Int", $i$1.c0, $key$13, $made$14($value$12), Rt$empty, DomLists$domSite31, Rt$empty);
      } else {
        Rt$restate($i$1.c0);
      }
    } else {
      $i$1.a0k = $i$1.c0;
      Rt$hide($i$1.c0, DomLists$b96);
    }
  }
  $i$1.$l = $i$1.c0.l;
};
const DomLists$t104 = Rt$templateOf("<!>", 4);
const DomLists$k104 = { m: ($v$43, $cx$44) => {
  const $r$45 = DomLists$t104();
  const $w$46 = $r$45.firstChild;
  const $c$47 = Rt$slot(Rt$empty, $w$46, $cx$44);
  const $i$48 = { s: Rt$empty, q: $c$47, e: $w$46, c0: $c$47, a0k: undefined, a0v: undefined, a0i0: undefined };
  DomLists$p104($i$48, $v$43);
  return $i$48;
}, p: DomLists$p104, l: true };
const DomLists$viewName$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:String.String" + ")", a: undefined };
const DomLists$viewName = (name$1) => ({ t: DomLists$k18, v: { ...DomLists$viewName$$packet$1, a: name$1 } });
const DomLists$table$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{names=core:List.List(core:String.String),rows=core:List.List({id=core:Basics.Int,label=core:String.String}),selected=core:Basics.Int}" + ")", a: undefined };
const DomLists$table = ($m$0, model$1) => ({ t: DomLists$k44, v: { ...DomLists$table$$packet$1, a: model$1 } });
const DomLists$lists$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "core:String.String" + ")", a: undefined };
const DomLists$lists$$packet$2 = { [Js$Any$pack.$packet.key]: "(" + "{names=core:List.List(core:String.String),rows=core:List.List({id=core:Basics.Int,label=core:String.String}),selected=core:Basics.Int}" + ")", a: undefined };
const DomLists$lists = ($m$0, model$1) => ({ t: DomLists$k81, v: { ...DomLists$lists$$packet$2, a: model$1 } });
const DomLists$first$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{names=core:List.List(core:String.String),rows=core:List.List({id=core:Basics.Int,label=core:String.String}),selected=core:Basics.Int}" + ")", a: undefined };
const DomLists$first = ($m$0, model$1) => ({ t: DomLists$k104, v: { ...DomLists$first$$packet$1, a: model$1 } });
export { DomLists$table, DomLists$lists, DomLists$first };
//# sourceMappingURL=DomLists.mjs.map
