import { Rt$template, Rt$delegate, Rt$empty, Rt$forKeyed, Rt$rowsHead, Rt$rowsTail, Rt$rowsRestate, Rt$rowsDispose, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { String$fromInt, String$compare } from "./_core/String.mjs";
import { Html$targetValue } from "./_platform/_html/Html.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomRowMount$t57 = Rt$template("<li><a> </a><input>");
const DomRowMount$domNoRestate = ($value$27) => {
};
const DomRowMount$domRowView = ($value$28) => $value$28;
const DomRowMount$domRowItem = ($value$29) => $value$29.x;
const DomRowMount$domRowSameItem = ($value$30, $value$31) => $value$30.x === $value$31;
const DomRowMount$domRowSetItem = ($value$32, $value$33) => {
  $value$32.x = $value$33;
};
const DomRowMount$domSame4 = ($was$34, $now$35) => $was$34 !== Rt$empty;
const DomRowMount$domRememberAll = ($value$36) => $value$36;
const DomRowMount$domProbe1 = ($inputs$37) => $inputs$37[1];
const DomRowMount$domSite4 = { head: ($scope$38, $data$39, $slot$40) => Rt$rowsHead("core:Basics.Int", $scope$38, $data$39, $slot$40), tail: ($scope$42, $data$43, $slot$44) => Rt$rowsTail("core:Basics.Int", $scope$42, $data$43, $slot$44), restate: ($scope$46, $data$47, $slot$48, $stamp$49) => Rt$rowsRestate("core:Basics.Int", $scope$46, $data$47, $slot$48, $stamp$49), dispose: ($scope$50, $data$51, $slot$52) => Rt$rowsDispose("core:Basics.Int", $scope$50, $data$51, $slot$52) };
const DomRowMount$p59 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $made$7 = (($patch$25) => ({ m: ($item$8, $key$9, $position$10, $cx$20) => {
      const $r$21 = DomRowMount$t57();
      const $w$22 = $r$21.firstChild;
      const $w$23 = $w$22.firstChild;
      const $w$24 = $w$22.nextSibling;
      Rt$delegate(["click", "input"]);
      if ($cx$20 !== null) {
        $w$22.$$cx = $cx$20;
      }
      $w$24.$$inputX = Html$targetValue;
      if ($cx$20 !== null) {
        $w$24.$$cx = $cx$20;
      }
      const $i$26 = { s: $r$21, q: Rt$empty, e: $r$21, x: undefined, y: $position$10, k: $key$9, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, w0: $r$21, w1: $w$22, w2: $w$23, w3: $w$24, a0: undefined, a1: undefined, a2: undefined, a3: undefined, a4: undefined };
      $patch$25($i$26, $item$8, $position$10);
      $i$26.x = $item$8;
      return $i$26;
    }, p: $patch$25, r: DomRowMount$domNoRestate, view: DomRowMount$domRowView, item: DomRowMount$domRowItem, sameItem: DomRowMount$domRowSameItem, setItem: DomRowMount$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomRowMount$domSame4, remember: DomRowMount$domRememberAll, probe: DomRowMount$domProbe1 }))(($i$11, $item$12, $position$13) => {
      const $t$14 = $input$3.picked === $item$12.id ? "on" : "";
      const $t$15 = String$fromInt($item$12.id);
      const $t$16 = { $: "Pick", a: $item$12.id, b: null };
      const $t$17 = $item$12.label;
      const $t$19 = ($p$18) => ({ $: "Typed", a: $item$12.id, b: $p$18 });
      if ($t$14 !== $i$11.a0) {
        $i$11.w0.setAttribute("class", $t$14);
        $i$11.a0 = $t$14;
      }
      if ($t$15 !== $i$11.a1) {
        $i$11.a1 = $t$15;
        $i$11.w0.style.setProperty("order", $t$15);
      }
      if ($t$16 !== $i$11.a2) {
        $i$11.a2 = $t$16;
        $i$11.w1.$$click = $t$16;
      }
      if ($t$17 !== $i$11.a3) {
        $i$11.a3 = $t$17;
        $i$11.w2.data = $t$17;
      }
      if ($t$19 !== $i$11.a4) {
        $i$11.a4 = $t$19;
        $i$11.w3.$$input = $t$19;
      }
      return $i$11;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.c0, $t$4, $t$6, $made$7, [$input$3.picked, $input$3.picked], DomRowMount$domSite4, $made$7);
  }
  $i$1.$l = $i$1.c0.w || $i$1.c0.l;
};
const DomRowMount$t59 = Rt$template("<ul>");
const DomRowMount$k59 = { m: ($v$54, $cx$55) => {
  const $r$56 = DomRowMount$t59();
  const $c$57 = Rt$slot($r$56, Rt$empty, $cx$55);
  const $i$58 = { s: $r$56, q: Rt$empty, e: $r$56, c0: $c$57 };
  DomRowMount$p59($i$58, $v$54);
  return $i$58;
}, p: DomRowMount$p59, l: true };
const DomRowMount$t89 = Rt$template("<li>");
const DomRowMount$domSame7 = ($was$20, $now$21) => $was$20 !== Rt$empty;
const DomRowMount$domSite7 = { head: ($scope$22, $data$23, $slot$24) => Rt$rowsHead("core:Basics.Int", $scope$22, $data$23, $slot$24), tail: ($scope$26, $data$27, $slot$28) => Rt$rowsTail("core:Basics.Int", $scope$26, $data$27, $slot$28), restate: ($scope$30, $data$31, $slot$32, $stamp$33) => Rt$rowsRestate("core:Basics.Int", $scope$30, $data$31, $slot$32, $stamp$33), dispose: ($scope$34, $data$35, $slot$36) => Rt$rowsDispose("core:Basics.Int", $scope$34, $data$35, $slot$36) };
const DomRowMount$p91 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $made$7 = (($patch$18) => ({ m: ($item$8, $key$9, $position$10, $cx$16) => {
      const $r$17 = DomRowMount$t89();
      const $i$19 = { s: $r$17, q: Rt$empty, e: $r$17, x: undefined, y: $position$10, k: $key$9, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, w0: $r$17, a0: undefined, a1: undefined };
      $patch$18($i$19, $item$8, $position$10);
      $i$19.x = $item$8;
      return $i$19;
    }, p: $patch$18, r: DomRowMount$domNoRestate, view: DomRowMount$domRowView, item: DomRowMount$domRowItem, sameItem: DomRowMount$domRowSameItem, setItem: DomRowMount$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomRowMount$domSame7, remember: DomRowMount$domRememberAll, probe: DomRowMount$domProbe1 }))(($i$11, $item$12, $position$13) => {
      const $t$14 = $item$12.label;
      const $t$15 = $input$3.picked === $item$12.id ? "on" : "";
      if ($t$14 !== $i$11.a0) {
        $i$11.w0.setAttribute("title", $t$14);
        $i$11.a0 = $t$14;
      }
      if ($t$15 !== $i$11.a1) {
        $i$11.w0.setAttribute("class", $t$15);
        $i$11.a1 = $t$15;
      }
      return $i$11;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.c0, $t$4, $t$6, $made$7, [$input$3.picked, $input$3.picked], DomRowMount$domSite7, $made$7);
  }
  $i$1.$l = $i$1.c0.w || $i$1.c0.l;
};
const DomRowMount$t91 = Rt$template("<ul>");
const DomRowMount$k91 = { m: ($v$38, $cx$39) => {
  const $r$40 = DomRowMount$t91();
  const $c$41 = Rt$slot($r$40, Rt$empty, $cx$39);
  const $i$42 = { s: $r$40, q: Rt$empty, e: $r$40, c0: $c$41 };
  DomRowMount$p91($i$42, $v$38);
  return $i$42;
}, p: DomRowMount$p91, l: true };
const DomRowMount$t115 = Rt$template("<li> ");
const DomRowMount$domSame11 = ($was$21, $now$22) => $was$21 !== Rt$empty;
const DomRowMount$domSite11 = { head: ($scope$23, $data$24, $slot$25) => Rt$rowsHead("core:Basics.Int", $scope$23, $data$24, $slot$25), tail: ($scope$27, $data$28, $slot$29) => Rt$rowsTail("core:Basics.Int", $scope$27, $data$28, $slot$29), restate: ($scope$31, $data$32, $slot$33, $stamp$34) => Rt$rowsRestate("core:Basics.Int", $scope$31, $data$32, $slot$33, $stamp$34), dispose: ($scope$35, $data$36, $slot$37) => Rt$rowsDispose("core:Basics.Int", $scope$35, $data$36, $slot$37) };
const DomRowMount$p117 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $made$7 = { m: ($item$8, $key$9, $position$10, $cx$16) => {
      const $t$17 = $input$3.picked === $item$8.id;
      const $t$18 = $item$8.label;
      const $r$19 = DomRowMount$t115();
      const $w$20 = $r$19.firstChild;
      if ($t$17) {
        $r$19.classList.toggle("on", true);
      }
      $w$20.data = $t$18;
      return { s: $r$19, q: Rt$empty, e: $r$19, x: $item$8, y: $position$10, k: $key$9, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, w0: $r$19, w1: $w$20, a0: $t$17, a1: $t$18 };
    }, p: ($i$11, $item$12, $position$13) => {
      const $t$14 = $input$3.picked === $item$12.id;
      const $t$15 = $item$12.label;
      if ($t$14 !== $i$11.a0) {
        $i$11.a0 = $t$14;
        $i$11.w0.classList.toggle("on", $t$14);
      }
      if ($t$15 !== $i$11.a1) {
        $i$11.a1 = $t$15;
        $i$11.w1.data = $t$15;
      }
      return $i$11;
    }, r: DomRowMount$domNoRestate, view: DomRowMount$domRowView, item: DomRowMount$domRowItem, sameItem: DomRowMount$domRowSameItem, setItem: DomRowMount$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomRowMount$domSame11, remember: DomRowMount$domRememberAll, probe: DomRowMount$domProbe1 };
    Rt$forKeyed("core:Basics.Int", $i$1.c0, $t$4, $t$6, $made$7, [$input$3.picked, $input$3.picked], DomRowMount$domSite11, $made$7);
  }
  $i$1.$l = $i$1.c0.w || $i$1.c0.l;
};
const DomRowMount$t117 = Rt$template("<ul>");
const DomRowMount$k117 = { m: ($v$39, $cx$40) => {
  const $r$41 = DomRowMount$t117();
  const $c$42 = Rt$slot($r$41, Rt$empty, $cx$40);
  const $i$43 = { s: $r$41, q: Rt$empty, e: $r$41, c0: $c$42 };
  DomRowMount$p117($i$43, $v$39);
  return $i$43;
}, p: DomRowMount$p117, l: true };
const DomRowMount$Msg$$order = { Pick: 0, Typed: 1 };
const DomRowMount$Msg$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return DomRowMount$Msg$$order[$x.$] < DomRowMount$Msg$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Pick":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    default:
      const $o$0 = $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
      if ($o$0 !== "EQ") {
        return $o$0;
      }
      return String$compare($x.b, $y.b);
  }
};
const DomRowMount$Msg$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Pick":
      return $x.a === $y.a;
    default:
      return $x.a === $y.a && $x.b === $y.b;
  }
};
const DomRowMount$after$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{picked=core:Basics.Int,rows=core:List.List({id=core:Basics.Int,label=core:String.String})}" + ")", a: undefined };
const DomRowMount$after = (model$1) => ({ t: DomRowMount$k59, v: { ...DomRowMount$after$$packet$1, a: model$1 } });
const DomRowMount$before$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{picked=core:Basics.Int,rows=core:List.List({id=core:Basics.Int,label=core:String.String})}" + ")", a: undefined };
const DomRowMount$before = (model$1) => ({ t: DomRowMount$k91, v: { ...DomRowMount$before$$packet$1, a: model$1 } });
const DomRowMount$toggled$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{picked=core:Basics.Int,rows=core:List.List({id=core:Basics.Int,label=core:String.String})}" + ")", a: undefined };
const DomRowMount$toggled = (model$1) => ({ t: DomRowMount$k117, v: { ...DomRowMount$toggled$$packet$1, a: model$1 } });
export { DomRowMount$Msg$$compare, DomRowMount$Msg$$eq, DomRowMount$after, DomRowMount$before, DomRowMount$toggled };
//# sourceMappingURL=DomRowMount.mjs.map
