import { Rt$template, Rt$delegate, Rt$empty, Rt$forKeyed, Rt$rowsHead, Rt$rowsTail, Rt$rowsRestate, Rt$rowsDispose, Rt$restate, Rt$slot } from "./_platform/Rt.mjs";
import { Js$Any$pack } from "./_core/Js/Any.mjs";
const DomRowItemOnly$t51 = Rt$template("<tr><td> </td><td><a> </a></td><td><a>x");
const DomRowItemOnly$domNoRestate = ($value$30) => {
};
const DomRowItemOnly$domRowView = ($value$31) => $value$31;
const DomRowItemOnly$domRowItem = ($value$32) => $value$32.x;
const DomRowItemOnly$domRowSameItem = ($value$33, $value$34) => $value$33.x === $value$34;
const DomRowItemOnly$domRowSetItem = ($value$35, $value$36) => {
  $value$35.x = $value$36;
};
const DomRowItemOnly$domSame9 = ($was$37, $now$38) => $was$37 !== Rt$empty;
const DomRowItemOnly$domRememberAll = ($value$39) => $value$39;
const DomRowItemOnly$domProbe1 = ($inputs$40) => $inputs$40[1];
const DomRowItemOnly$domSite9 = { head: ($scope$41, $data$42, $slot$43) => Rt$rowsHead("core:Basics.Int", $scope$41, $data$42, $slot$43), tail: ($scope$45, $data$46, $slot$47) => Rt$rowsTail("core:Basics.Int", $scope$45, $data$46, $slot$47), restate: ($scope$49, $data$50, $slot$51, $stamp$52) => Rt$rowsRestate("core:Basics.Int", $scope$49, $data$50, $slot$51, $stamp$52), dispose: ($scope$53, $data$54, $slot$55) => Rt$rowsDispose("core:Basics.Int", $scope$53, $data$54, $slot$55) };
const DomRowItemOnly$p53 = ($i$1, $v$2) => {
  const $input$3 = $v$2.a;
  {
    const $t$4 = $input$3.rows;
    const $t$6 = ($p$5) => $p$5.id;
    const $made$7 = (($patch$28) => ({ m: ($item$8, $key$9, $position$10, $cx$19) => {
      const $r$20 = DomRowItemOnly$t51();
      const $w$21 = $r$20.firstChild;
      const $w$22 = $w$21.firstChild;
      const $w$23 = $w$21.nextSibling;
      const $w$24 = $w$23.firstChild;
      const $w$25 = $w$24.firstChild;
      const $w$26 = $w$23.nextSibling;
      const $w$27 = $w$26.firstChild;
      Rt$delegate(["click"]);
      if ($cx$19 !== null) {
        $w$24.$$cx = $cx$19;
      }
      if ($cx$19 !== null) {
        $w$27.$$cx = $cx$19;
      }
      const $i$29 = { s: $r$20, q: Rt$empty, e: $r$20, x: undefined, y: $position$10, k: $key$9, kv: 0, rs: 0, n: Rt$empty, kc: Rt$empty, kt: Rt$empty, $w0: $r$20, $w2: $w$22, $w4: $w$24, $w5: $w$25, $w7: $w$27, $a0: undefined, $a1: undefined, $a2: undefined, $a3: undefined, $a4: undefined };
      $patch$28($i$29, $item$8, $position$10);
      $i$29.x = $item$8;
      return $i$29;
    }, p: $patch$28, r: DomRowItemOnly$domNoRestate, view: DomRowItemOnly$domRowView, item: DomRowItemOnly$domRowItem, sameItem: DomRowItemOnly$domRowSameItem, setItem: DomRowItemOnly$domRowSetItem, o: false, i: false, l: false, e: false, f: Rt$empty, j: Rt$empty, same: DomRowItemOnly$domSame9, remember: DomRowItemOnly$domRememberAll, probe: DomRowItemOnly$domProbe1 }))(($i$11, $item$12, $position$13) => {
      const $t$14 = $input$3.selected.$ === "Just" && $input$3.selected.a === $item$12.id ? "danger" : "";
      const $t$15 = $item$12.id;
      const $t$16 = { $: "Select", a: $item$12.id };
      const $t$17 = $item$12.label;
      const $t$18 = { $: "Remove", a: $item$12.id };
      if ($t$14 !== $i$11.$a0) {
        $i$11.$w0.setAttribute("class", $t$14);
        $i$11.$a0 = $t$14;
      }
      if ($t$15 !== $i$11.$a1) {
        $i$11.$a1 = $t$15;
        $i$11.$w2.data = $t$15;
      }
      if ($t$16 !== $i$11.$a2) {
        $i$11.$a2 = $t$16;
        $i$11.$w4.$$click = $t$16;
      }
      if ($t$17 !== $i$11.$a3) {
        $i$11.$a3 = $t$17;
        $i$11.$w5.data = $t$17;
      }
      if ($t$18 !== $i$11.$a4) {
        $i$11.$a4 = $t$18;
        $i$11.$w7.$$click = $t$18;
      }
      return $i$11;
    });
    Rt$forKeyed("core:Basics.Int", $i$1.$c0, $t$4, $t$6, $made$7, [$input$3.selected, $input$3.selected.$ === "Just" ? $input$3.selected.a : $input$3.selected], DomRowItemOnly$domSite9, $made$7);
  }
  $i$1.$l = $i$1.$c0.w || $i$1.$c0.l;
};
const DomRowItemOnly$t53 = Rt$template("<table>");
const DomRowItemOnly$k53 = { m: ($v$57, $cx$58) => {
  const $r$59 = DomRowItemOnly$t53();
  const $c$60 = Rt$slot($r$59, Rt$empty, $cx$58);
  const $i$61 = { s: $r$59, q: Rt$empty, e: $r$59, $c0: $c$60 };
  DomRowItemOnly$p53($i$61, $v$57);
  return $i$61;
}, p: DomRowItemOnly$p53, l: true };
const DomRowItemOnly$Msg$$order = { Select: 0, Remove: 1 };
const DomRowItemOnly$Msg$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return DomRowItemOnly$Msg$$order[$x.$] < DomRowItemOnly$Msg$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Select":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    default:
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
  }
};
const DomRowItemOnly$Msg$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Select":
      return $x.a === $y.a;
    default:
      return $x.a === $y.a;
  }
};
const DomRowItemOnly$table$$packet$1 = { [Js$Any$pack.$packet.key]: "(" + "{rows=core:List.List({id=core:Basics.Int,label=core:String.String}),selected=core:Maybe.Maybe(core:Basics.Int)}" + ")", a: undefined };
const DomRowItemOnly$table = (model$1) => ({ t: DomRowItemOnly$k53, v: { ...DomRowItemOnly$table$$packet$1, a: model$1 } });
export { DomRowItemOnly$Msg$$compare, DomRowItemOnly$Msg$$eq, DomRowItemOnly$table };
//# sourceMappingURL=DomRowItemOnly.mjs.map
